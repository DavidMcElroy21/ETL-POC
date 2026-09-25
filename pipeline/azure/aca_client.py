"""Shared Container Apps plumbing for the run launcher and the Pipes client.

The one genuinely surprising thing about starting a Container Apps job with an
override is this, from the Azure docs:

    When you override a configuration, the job's entire template configuration
    is replaced with the new configuration. Ensure that the new configuration
    includes all required settings.

It is not a patch. Send a template containing only a command and the image,
resource limits and environment variables the job was created with are gone for
that execution, and the container fails in ways that look nothing like the
cause. So every override here is built by reading the job's current template
and copying it forward -- see `build_execution_template`.

Job-level configuration (registry credentials, managed identity bindings,
secrets) lives outside `template` and is not affected.
"""

from __future__ import annotations

import os
from typing import Any

from azure.identity import DefaultAzureCredential
from azure.mgmt.appcontainers import ContainerAppsAPIClient
from azure.mgmt.appcontainers.models import (
    EnvironmentVar,
    JobExecutionContainer,
    JobExecutionTemplate,
)


# Every override below prepends this. Container Apps' `command` maps to the
# image's ENTRYPOINT, not to CMD, so overriding the command to run Dagster or
# an ingest module would otherwise skip the entrypoint entirely -- and with it
# the Entra token that becomes POSTGRES_PASSWORD. Prepending keeps the wrapper
# in the chain while still choosing what it execs.
AZURE_ENTRYPOINT = "/opt/etl/scripts/azure/entrypoint.sh"


def _require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(
            f"environment variable {name} is required to talk to Container Apps; "
            "it is set on every app and job by infra/modules/aca-apps.bicep"
        )
    return value


def build_client(subscription_id: str | None = None) -> ContainerAppsAPIClient:
    """Management client authenticated as the workload's managed identity.

    DefaultAzureCredential picks up the user-assigned identity from the
    container's environment, so no key or connection string is ever passed in.
    Locally it falls back to the Azure CLI login, which makes the launcher
    testable from a developer machine without changing code.
    """
    return ContainerAppsAPIClient(
        credential=DefaultAzureCredential(),
        subscription_id=subscription_id or _require_env("AZURE_SUBSCRIPTION_ID"),
    )


def _as_dict(value: Any) -> dict[str, Any]:
    """Normalise an SDK model to a plain dict.

    The newer appcontainers models are MutableMapping, but older ones only
    expose attributes. Handling both keeps this working across SDK minor
    versions rather than failing on an attribute that quietly moved.
    """
    if isinstance(value, dict):
        return dict(value)
    if hasattr(value, "as_dict"):
        return value.as_dict()
    return {k: v for k, v in vars(value).items() if not k.startswith("_")}


def build_execution_template(
    client: ContainerAppsAPIClient,
    resource_group: str,
    job_name: str,
    *,
    command: list[str] | None = None,
    args: list[str] | None = None,
    env: dict[str, str] | None = None,
    container_name: str | None = None,
) -> JobExecutionTemplate:
    """Clone the job's template, overriding only what the caller asked for.

    Reading the job first is what keeps the override safe: the image, CPU and
    memory limits, and any secret-backed environment variables the job was
    deployed with are carried into the execution untouched.

    `env` is merged by name, so a caller can add DAGSTER_RUN_ID without
    disturbing a secretRef entry that happens to sit next to it.
    """
    job = client.jobs.get(resource_group, job_name)
    template = _as_dict(_as_dict(job).get("template") or {})
    source_containers = template.get("containers") or []

    if not source_containers:
        raise RuntimeError(
            f"Container Apps job {job_name!r} has no containers in its template; "
            "the deployment is incomplete"
        )

    containers: list[JobExecutionContainer] = []
    for raw in source_containers:
        container = _as_dict(raw)
        name = container.get("name")

        # Only the named container is overridden. A job with a sidecar keeps
        # the sidecar exactly as deployed.
        targeted = container_name is None or name == container_name

        merged_env: dict[str, EnvironmentVar] = {}
        for entry in container.get("env") or []:
            item = _as_dict(entry)
            merged_env[item["name"]] = EnvironmentVar(
                name=item["name"],
                value=item.get("value"),
                secret_ref=item.get("secretRef") or item.get("secret_ref"),
            )
        if targeted and env:
            for key, value in env.items():
                merged_env[key] = EnvironmentVar(name=key, value=value)

        # A container's final argv is command + args, so a new command has to
        # clear the deployed args as well. Carrying them forward would append
        # the job's default arguments after `dagster api execute_run <json>`,
        # which is a confusing failure a long way from its cause.
        if targeted and command is not None:
            resolved_args = args if args is not None else []
        elif targeted and args is not None:
            resolved_args = args
        else:
            resolved_args = container.get("args")

        containers.append(
            JobExecutionContainer(
                image=container.get("image"),
                name=name,
                command=(command if targeted and command is not None else container.get("command")),
                args=resolved_args,
                env=list(merged_env.values()),
                resources=container.get("resources"),
            )
        )

    return JobExecutionTemplate(containers=containers)


def start_job_execution(
    client: ContainerAppsAPIClient,
    resource_group: str,
    job_name: str,
    template: JobExecutionTemplate,
) -> str:
    """Start one execution and return its name.

    The name is the handle for everything afterwards -- polling status,
    terminating, and correlating container logs in Log Analytics -- so callers
    persist it rather than trying to find the execution again by time.
    """
    poller = client.jobs.begin_start(resource_group, job_name, template=template)
    execution = poller.result()
    name = _as_dict(execution).get("name")
    if not name:
        raise RuntimeError(
            f"Container Apps returned no execution name when starting {job_name!r}"
        )
    return str(name)


def get_execution_status(
    client: ContainerAppsAPIClient,
    resource_group: str,
    job_name: str,
    execution_name: str,
) -> str | None:
    """Return the execution's status, or None if it is not listed.

    Azure reports Running, Succeeded, Failed, Cancelled or Degraded. None means
    the execution has aged out of the job's retained history -- Container Apps
    keeps only the most recent 100 for scheduled and event jobs -- which is not
    the same as "still running" and is why callers must handle it explicitly.
    """
    for raw in client.jobs_executions.list(resource_group, job_name):
        execution = _as_dict(raw)
        if execution.get("name") == execution_name:
            properties = _as_dict(execution.get("properties") or execution)
            return properties.get("status") or execution.get("status")
    return None


def stop_execution(
    client: ContainerAppsAPIClient,
    resource_group: str,
    job_name: str,
    execution_name: str,
) -> None:
    client.jobs.begin_stop_execution(resource_group, job_name, execution_name).result()


# Azure's terminal states. Anything else means the execution is still going.
TERMINAL_STATUSES = frozenset({"Succeeded", "Failed", "Cancelled", "Degraded"})
FAILED_STATUSES = frozenset({"Failed", "Cancelled", "Degraded"})
