"""Run an ingestion step as its own Container Apps job execution.

This is the Azure counterpart to ``PipesSubprocessClient``. Locally, Dagster
launches the ingest virtualenv as a child process and reads Pipes messages off
its file descriptors. In Azure the ingest image is a separate container in a
separate job, so neither of those is available:

  * **No socket.** Container Apps jobs have no ingress, so there is nothing for
    the run worker to connect to and nothing the job can connect back to. Both
    the context going out and the messages coming back travel through blob
    storage, which is what ``dagster-azure`` already implements.
  * **No shared filesystem.** The two containers share nothing but the storage
    account, so the blob container is the entire channel.

Both halves of that transport are ``dagster-azure``'s. What is written here is
only the launch-and-wait half: start the execution, poll it to a terminal
state, and let Dagster reconstruct the materializations from whatever the job
wrote to blob storage.
"""

from __future__ import annotations

import time
from typing import Any

from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
from dagster import (
    OpExecutionContext,
    PipesClient,
    PipesClientCompletedInvocation,
    open_pipes_session,
)
from dagster._core.definitions.resource_annotation import TreatAsResourceParam
from dagster_azure.pipes import (
    PipesAzureBlobStorageContextInjector,
    PipesAzureBlobStorageMessageReader,
)

from pipeline.azure.aca_client import (
    AZURE_ENTRYPOINT,
    FAILED_STATUSES,
    TERMINAL_STATUSES,
    build_client,
    build_execution_template,
    get_execution_status,
    start_job_execution,
    stop_execution,
)


class PipesAcaJobClient(PipesClient, TreatAsResourceParam):
    """Launch the ingest image as a Container Apps job and stream its results.

    Args:
        resource_group: resource group holding the job.
        job_name: the Container Apps job built from the ingest image.
        storage_account_url: ``https://<account>.blob.core.windows.net``, used
            for the Pipes context and message blobs.
        blob_container: container the two processes exchange messages through.
        poll_interval: seconds between execution status checks.
        timeout: seconds to wait before giving up and stopping the execution.
            Keep this below the job's ``replicaTimeout`` so Dagster is the one
            that reports the timeout, with a message that says so.
    """

    def __init__(
        self,
        resource_group: str,
        job_name: str,
        storage_account_url: str,
        blob_container: str,
        subscription_id: str | None = None,
        container_name: str = "main",
        poll_interval: float = 5.0,
        timeout: float = 3600.0,
    ):
        self._resource_group = resource_group
        self._job_name = job_name
        self._container_name = container_name
        self._subscription_id = subscription_id
        self._poll_interval = poll_interval
        self._timeout = timeout

        credential = DefaultAzureCredential()
        blob_client = BlobServiceClient(
            account_url=storage_account_url, credential=credential
        )

        self._context_injector = PipesAzureBlobStorageContextInjector(
            container=blob_container, client=blob_client
        )
        self._message_reader = PipesAzureBlobStorageMessageReader(
            container=blob_container, client=blob_client
        )
        self._aca_client = None

    @property
    def _client(self):
        if self._aca_client is None:
            self._aca_client = build_client(self._subscription_id)
        return self._aca_client

    @classmethod
    def _is_dagster_maintained(cls) -> bool:
        return False

    def run(
        self,
        *,
        context: OpExecutionContext,
        module: str,
        extras: dict[str, Any] | None = None,
        args: list[str] | None = None,
        env: dict[str, str] | None = None,
    ) -> PipesClientCompletedInvocation:
        """Run ``python -m <module>`` in the ingest job and wait for it.

        `module` is the ingest entry point, e.g. ``ingest.run_sftp_sync``. The
        ingest image puts its own virtualenv first on PATH, so plain ``python``
        is already the right interpreter.
        """
        with open_pipes_session(
            context=context,
            context_injector=self._context_injector,
            message_reader=self._message_reader,
            extras=extras,
        ) as session:
            # These carry the blob locations of the context and message
            # streams. The ingest container reads them via dagster-pipes and
            # never needs to know it is talking to Dagster over storage.
            bootstrap_env = session.get_bootstrap_env_vars()

            template = build_execution_template(
                self._client,
                self._resource_group,
                self._job_name,
                command=[AZURE_ENTRYPOINT, "python", "-m", module, *(args or [])],
                env={**bootstrap_env, **(env or {})},
                container_name=self._container_name,
            )

            execution_name = start_job_execution(
                self._client, self._resource_group, self._job_name, template
            )
            context.log.info(
                f"Started ingest job execution {execution_name} running {module}"
            )

            status = self._wait_for_execution(context, execution_name)

            if status in FAILED_STATUSES:
                raise RuntimeError(
                    f"Ingest job execution {execution_name} reported {status}. "
                    "Container logs are in Log Analytics under "
                    f"ContainerAppConsoleLogs_CL where ContainerGroupName_s == '{execution_name}'."
                )

        return PipesClientCompletedInvocation(session)

    def _wait_for_execution(self, context: OpExecutionContext, execution_name: str) -> str:
        deadline = time.monotonic() + self._timeout
        last_status: str | None = None

        while True:
            status = get_execution_status(
                self._client, self._resource_group, self._job_name, execution_name
            )

            if status != last_status and status is not None:
                context.log.debug(f"Ingest execution {execution_name}: {status}")
                last_status = status

            if status in TERMINAL_STATUSES:
                return str(status)

            if status is None:
                # Not yet listed, or already aged out of the retained history.
                # Treat it as pending; the timeout below is what stops this
                # becoming an infinite wait.
                pass

            if time.monotonic() >= deadline:
                # Stop the execution rather than orphan a container that keeps
                # burning CPU after Dagster has stopped caring about it.
                stop_execution(
                    self._client, self._resource_group, self._job_name, execution_name
                )
                raise TimeoutError(
                    f"Ingest job execution {execution_name} did not finish within "
                    f"{self._timeout:.0f}s and was stopped."
                )

            time.sleep(self._poll_interval)
