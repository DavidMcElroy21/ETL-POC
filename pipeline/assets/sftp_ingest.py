"""SFTP ingestion assets.

One Dagster asset per retail stream, all produced by a single subprocess run of
the PyAirbyte connector. The asset keys are ``["airbyte_raw", "<stream>"]``,
which is exactly what dagster-dbt derives for a dbt source named
``airbyte_raw``. That correspondence is what stitches extraction and
transformation into one lineage graph instead of two disconnected islands.
"""

# Dagster resolves the `context`, `config` and resource parameter annotations on
# this function at runtime to build the op definition, so this module must not
# use `from __future__ import annotations` -- PEP 563 would turn them into
# strings that Dagster cannot resolve.
from dagster import (
    AssetExecutionContext,
    AssetSpec,
    PipesSubprocessClient,
    multi_asset,
)

from ingest.streams import RAW_SCHEMA, RETAIL_STREAMS
from pipeline.config import INGEST_PYTHON, ingest_env

GROUP_NAME = "sftp_ingest"

RAW_ASSET_SPECS = [
    AssetSpec(
        key=[RAW_SCHEMA, stream.name],
        group_name=GROUP_NAME,
        description=stream.description,
        kinds={"airbyte", "postgres"},
        metadata={
            "file_glob": stream.glob,
            "primary_key": stream.primary_key,
            "destination_table": f"{RAW_SCHEMA}.{stream.name}",
        },
    )
    for stream in RETAIL_STREAMS
]


@multi_asset(
    specs=RAW_ASSET_SPECS,
    # Materializing a subset in the UI syncs only those streams: the selection
    # is forwarded to the connector through Pipes extras.
    can_subset=True,
)
def sftp_retail_ingest(
    context: AssetExecutionContext,
    pipes_subprocess_client: PipesSubprocessClient,
):
    """Extract the retail CSV files from SFTP into the raw Postgres schema."""
    selected = sorted(key.path[-1] for key in context.selected_asset_keys)
    context.log.info(f"syncing {len(selected)} stream(s): {', '.join(selected)}")

    return pipes_subprocess_client.run(
        command=[str(INGEST_PYTHON), "-m", "ingest.run_sftp_sync"],
        context=context,
        extras={"streams": selected},
        env=ingest_env(),
    ).get_results()
