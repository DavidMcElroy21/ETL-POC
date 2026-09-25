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
from typing import Any

from dagster import (
    AssetExecutionContext,
    AssetSpec,
    ResourceParam,
    multi_asset,
)

from ingest.streams import RAW_SCHEMA, RETAIL_STREAMS
from pipeline.ingest_launch import launch_ingest

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


# ingest_client is annotated ResourceParam[Any] rather than with a concrete
# class. Dagster decides whether a parameter is a resource or an upstream
# asset from its annotation, and an unannotated one becomes an asset input --
# which fails at load time with a message about missing AssetDeps. A concrete
# annotation is not available here: the resource is a PipesSubprocessClient
# locally and a PipesAcaJobClient in Azure, and the asset must not care which.
@multi_asset(
    specs=RAW_ASSET_SPECS,
    # Materializing a subset in the UI syncs only those streams: the selection
    # is forwarded to the connector through Pipes extras.
    can_subset=True,
)
def sftp_retail_ingest(
    context: AssetExecutionContext,
    ingest_client: ResourceParam[Any],
):
    """Extract the retail CSV files from SFTP into the raw Postgres schema."""
    selected = sorted(key.path[-1] for key in context.selected_asset_keys)
    context.log.info(f"syncing {len(selected)} stream(s): {', '.join(selected)}")

    return launch_ingest(
        context=context,
        client=ingest_client,
        module="ingest.run_sftp_sync",
        extras={"streams": selected},
    )
