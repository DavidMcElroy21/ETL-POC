"""Dagster resources: the dbt CLI and the Pipes subprocess client."""

from __future__ import annotations

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


def build_resources() -> dict[str, object]:
    return {
        "dbt": DbtCliResource(project_dir=dbt_project),
        # Launches the ingest virtualenv and relays its logs and asset
        # materializations back into the Dagster run.
        "pipes_subprocess_client": PipesSubprocessClient(),
    }
