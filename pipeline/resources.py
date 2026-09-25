"""Dagster resources: the dbt CLI and the Pipes subprocess client."""

from __future__ import annotations

import os

from dagster import PipesSubprocessClient
from dagster_dbt import DbtCliResource, DbtProject

from pipeline.config import DBT_PROFILES_DIR, DBT_PROJECT_DIR

# DbtProject points Dagster at the project and its compiled manifest. The image
# runs `dbt parse` at build time, so manifest.json already exists and the asset
# graph loads without shelling out to dbt first.
dbt_project = DbtProject(
    project_dir=DBT_PROJECT_DIR,
    profiles_dir=DBT_PROFILES_DIR,
    target="dev",
)

# Deliberately no dbt_project.prepare_if_dev() here.
#
# `dagster dev` sets DAGSTER_IS_DEV_CLI, so that call would run on every start
# and re-run `dbt deps` -- which needs the network, and which empties
# dbt_packages/ when it cannot reach the package hub. The image already resolves
# packages and compiles the manifest at build time, so the call buys nothing and
# breaks the offline guarantee.
#
# It would earn its place if the project directory were bind-mounted for live
# editing. It is not: the image is the unit of deployment here, so a model change
# means a rebuild either way.


def _build_ingest_client() -> object:
    """Pick the Pipes client for wherever this code location is running.

    Locally the ingest virtualenv sits in the same image, so a subprocess is
    both the simplest and the fastest thing. In Azure it is a separate image in
    a separate Container Apps job, so the client has to start that job and read
    its messages out of blob storage instead.

    The switch is the presence of ACA_INGEST_JOB_NAME, which only the Azure
    deployment sets. Importing the Azure client lazily matters: it pulls in the
    Azure SDKs, which the orchestrator image has but a local checkout does not
    need in order to run the compose stack.
    """
    ingest_job = os.environ.get("ACA_INGEST_JOB_NAME")
    if not ingest_job:
        return PipesSubprocessClient()

    from pipeline.azure.pipes import PipesAcaJobClient

    return PipesAcaJobClient(
        resource_group=os.environ["AZURE_RESOURCE_GROUP"],
        job_name=ingest_job,
        storage_account_url=os.environ["AZURE_STORAGE_ACCOUNT_URL"],
        blob_container=os.environ.get("AZURE_PIPES_CONTAINER", "dagster"),
        subscription_id=os.environ.get("AZURE_SUBSCRIPTION_ID"),
        timeout=float(os.environ.get("ACA_INGEST_TIMEOUT_SECONDS", "3600")),
    )


def build_resources() -> dict[str, object]:
    return {
        "dbt": DbtCliResource(project_dir=dbt_project),
        # Runs an ingest module and relays its logs and asset materializations
        # back into the Dagster run -- as a subprocess locally, as a Container
        # Apps job in Azure. pipeline/ingest_launch.py hides the difference
        # from the assets so they read the same either way.
        "ingest_client": _build_ingest_client(),
    }
