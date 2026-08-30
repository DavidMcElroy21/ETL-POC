"""dbt transformation assets.

Every dbt model becomes a Dagster asset and every dbt test becomes a Dagster
asset check, so the warn-severity results are visible in the UI as warnings
attached to the asset they concern rather than buried in run logs.

The lineage join
----------------
dagster-dbt derives the asset key for a dbt source as
``[source_name, table_name]``, which for this project is
``["airbyte_raw", "customers"]`` -- the same keys the SFTP ingest assets emit.
Extraction and transformation therefore land on a single connected graph without
either side needing to know about the other.
"""

# Dagster resolves the `context`, `config` and resource parameter annotations on
# this function at runtime to build the op definition, so this module must not
# use `from __future__ import annotations` -- PEP 563 would turn them into
# strings that Dagster cannot resolve.
from typing import Any

from dagster import AssetExecutionContext
from dagster_dbt import (
    DagsterDbtTranslator,
    DagsterDbtTranslatorSettings,
    DbtCliResource,
    dbt_assets,
)

from pipeline.resources import dbt_project


class RetailDbtTranslator(DagsterDbtTranslator):
    """Default key mapping, with groups derived from the dbt folder layout."""

    def get_group_name(self, dbt_resource_props: dict[str, Any]) -> str | None:
        if dbt_resource_props["resource_type"] == "source":
            # Sources are owned by the ingestion assets, which set their own
            # group. Returning None here avoids fighting over it.
            return None

        fqn = dbt_resource_props.get("fqn", [])
        if "staging" in fqn:
            return "dbt_staging"
        if "marts" in fqn:
            return "dbt_marts"
        return None


dagster_dbt_translator = RetailDbtTranslator(
    settings=DagsterDbtTranslatorSettings(
        # Surface dbt tests as Dagster asset checks. A warn-severity dbt test
        # then shows up as a WARN check result and the run still succeeds --
        # which is the behaviour this whole project is built to demonstrate.
        enable_asset_checks=True,
    )
)


@dbt_assets(
    manifest=dbt_project.manifest_path,
    dagster_dbt_translator=dagster_dbt_translator,
)
def retail_dbt_assets(context: AssetExecutionContext, dbt: DbtCliResource):
    """Run the dbt project: build every model, then run every test.

    `dbt build` interleaves the two, so a model is tested as soon as it is
    built. Warn-severity failures are reported and the command still exits 0;
    only an error-severity failure stops the run.
    """
    yield from (
        dbt.cli(["build"], context=context)
        .stream()
        # Attach row counts to each materialized model. Cheap, and the first
        # thing anyone wants when a downstream number looks wrong.
        .fetch_row_counts()
    )
