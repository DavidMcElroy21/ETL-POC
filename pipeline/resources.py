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

# Regenerates the manifest when DAGSTER_IS_DEV_CLI is set, so editing a model
# locally is reflected without an image rebuild. A no-op in production.
dbt_project.prepare_if_dev()


def build_resources() -> dict[str, object]:
    return {
        "dbt": DbtCliResource(project_dir=dbt_project),
        # Launches the ingest virtualenv and relays its logs and asset
        # materializations back into the Dagster run.
        "pipes_subprocess_client": PipesSubprocessClient(),
    }
