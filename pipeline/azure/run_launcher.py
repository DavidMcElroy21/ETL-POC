"""Run one Dagster run per Azure Container Apps job execution.

Dagster ships launchers for Kubernetes, Docker and ECS. Container Apps is not
among them, so this is the piece that gives each run its own container instead
of executing it inside whichever process happened to launch it.

Wired up in ``dagster.azure.yaml``:

    run_launcher:
      module: pipeline.azure.run_launcher
      class: AcaJobRunLauncher
      config:
        resource_group:
          env: AZURE_RESOURCE_GROUP
        job_name:
          env: ACA_RUN_JOB_NAME
"""

from __future__ import annotations

from typing import Any

from dagster import DagsterRun, _check as check
from dagster._core.launcher.base import (
    CheckRunHealthResult,
    LaunchRunContext,
    RunLauncher,
    WorkerStatus,
)
from dagster._grpc.types import ExecuteRunArgs
from dagster._serdes import ConfigurableClass, ConfigurableClassData

from pipeline.azure.aca_client import (
    AZURE_ENTRYPOINT,
    FAILED_STATUSES,
    build_client,
    build_execution_template,
    get_execution_status,
    start_job_execution,
    stop_execution,
)

# The execution name is written back onto the run as a tag. It is the only
# durable link between a Dagster run and the Azure resource actually running
# it, and it is what terminate and the health check both look up.
EXECUTION_NAME_TAG = "azure/aca_job_execution"


class AcaJobRunLauncher(RunLauncher, ConfigurableClass):
    """Launch each run as an execution of a Container Apps job."""

    def __init__(
        self,
        resource_group: str,
        job_name: str,
        subscription_id: str | None = None,
        container_name: str = "main",
        inst_data: ConfigurableClassData | None = None,
    ):
        self._inst_data = inst_data
        self._resource_group = check.str_param(resource_group, "resource_group")
        self._job_name = check.str_param(job_name, "job_name")
        self._subscription_id = check.opt_str_param(subscription_id, "subscription_id")
        self._container_name = check.str_param(container_name, "container_name")
        self._client_instance = None
        super().__init__()

    @property
    def _client(self):
        # Built lazily so importing this module never requires Azure
        # credentials -- `dagster instance info` and the test suite both load
        # the launcher without talking to Azure.
        if self._client_instance is None:
            self._client_instance = build_client(self._subscription_id)
        return self._client_instance

    # -- ConfigurableClass ---------------------------------------------------

    @property
    def inst_data(self) -> ConfigurableClassData | None:
        return self._inst_data

    @classmethod
    def config_type(cls) -> dict[str, Any]:
        from dagster import Field, StringSource

        return {
            "resource_group": Field(StringSource, is_required=True),
            "job_name": Field(
                StringSource,
                is_required=True,
                description="Container Apps job that runs the orchestrator image.",
            ),
            "subscription_id": Field(
                StringSource,
                is_required=False,
                description="Defaults to the AZURE_SUBSCRIPTION_ID environment variable.",
            ),
            "container_name": Field(
                StringSource,
                is_required=False,
                default_value="main",
                description="Which container in the job template to override.",
            ),
        }

    @classmethod
    def from_config_value(
        cls, inst_data: ConfigurableClassData, config_value: dict[str, Any]
    ) -> AcaJobRunLauncher:
        return cls(inst_data=inst_data, **config_value)

    # -- RunLauncher ---------------------------------------------------------

    def launch_run(self, context: LaunchRunContext) -> None:
        run = context.dagster_run
        job_code_origin = check.not_none(
            context.job_code_origin,
            "AcaJobRunLauncher requires a job code origin; the run must come from a"
            " code location, not an ephemeral in-process job.",
        )

        # The standard hand-off every out-of-process launcher uses: serialize
        # what the worker needs and let `dagster api execute_run` rehydrate it.
        # The instance ref inside carries the Postgres storage config, which is
        # how the worker reaches the same event log as the daemon.
        args = ExecuteRunArgs(
            job_origin=job_code_origin,
            run_id=run.run_id,
            instance_ref=self._instance.get_ref(),
        )

        template = build_execution_template(
            self._client,
            self._resource_group,
            self._job_name,
            # Through the entrypoint rather than straight to dagster: the
            # override replaces ENTRYPOINT, and the run worker needs the
            # Postgres token and the instance config it sets up.
            command=[AZURE_ENTRYPOINT, *args.get_command_args()],
            env={"DAGSTER_RUN_ID": run.run_id},
            container_name=self._container_name,
        )

        execution_name = start_job_execution(
            self._client, self._resource_group, self._job_name, template
        )

        self._instance.report_engine_event(
            f"Started Container Apps job execution {execution_name}",
            run,
            cls=self.__class__,
        )
        self._instance.add_run_tags(run.run_id, {EXECUTION_NAME_TAG: execution_name})

    def terminate(self, run_id: str) -> bool:
        run = self._instance.get_run_by_id(run_id)
        if not run:
            return False

        execution_name = run.tags.get(EXECUTION_NAME_TAG)
        if not execution_name:
            # The run was never launched, or was launched by a different
            # launcher. Saying so beats reporting a successful termination that
            # did nothing.
            self._instance.report_engine_event(
                "Cannot terminate: no Container Apps execution is recorded for this run.",
                run,
                cls=self.__class__,
            )
            return False

        self._instance.report_run_canceling(run)
        stop_execution(
            self._client, self._resource_group, self._job_name, execution_name
        )
        return True

    @property
    def supports_check_run_worker_health(self) -> bool:
        return True

    def check_run_worker_health(self, run: DagsterRun) -> CheckRunHealthResult:
        """Let the daemon notice a worker that died without reporting.

        Without this a container that is OOM-killed, evicted by a platform
        upgrade, or fails to pull its image leaves the run STARTED forever,
        because nothing is left alive to mark it failed.
        """
        execution_name = run.tags.get(EXECUTION_NAME_TAG)
        if not execution_name:
            return CheckRunHealthResult(
                WorkerStatus.UNKNOWN, "No Container Apps execution recorded for this run."
            )

        status = get_execution_status(
            self._client, self._resource_group, self._job_name, execution_name
        )

        if status is None:
            # Aged out of the retained execution history. Unknown rather than
            # failed: the run may well have finished correctly, and claiming a
            # failure we cannot see would be worse than admitting ignorance.
            return CheckRunHealthResult(
                WorkerStatus.UNKNOWN,
                f"Execution {execution_name} is no longer in the job's retained history.",
            )
        if status in FAILED_STATUSES:
            return CheckRunHealthResult(
                WorkerStatus.FAILED,
                f"Container Apps execution {execution_name} reported {status}.",
            )
        if status == "Succeeded":
            # The container exited cleanly. If the run is still marked started,
            # the process died between its last event and reporting success.
            return CheckRunHealthResult(WorkerStatus.SUCCESS)
        return CheckRunHealthResult(WorkerStatus.RUNNING)
