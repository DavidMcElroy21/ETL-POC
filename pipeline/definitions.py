"""The Dagster code location.

Wires the two ingestion paths and the dbt project into one asset graph, with a
job and a schedule over the retail path.
"""

from __future__ import annotations

from dagster import (
    AssetSelection,
    DefaultScheduleStatus,
    Definitions,
    ScheduleDefinition,
    define_asset_job,
)

from ingest.streams import FAKER_SCHEMA
from pipeline.assets.faker_ingest import synthetic_ingest
from pipeline.assets.sftp_ingest import sftp_retail_ingest
from pipeline.assets.transforms import retail_dbt_assets
from pipeline.resources import build_resources

# Everything except the synthetic path: SFTP extraction, then the whole dbt
# project. The synthetic assets are excluded because they exist to be run on
# demand with a chosen row count, not on a timer.
retail_selection = AssetSelection.all() - AssetSelection.groups("synthetic_ingest")

retail_job = define_asset_job(
    name="retail_pipeline",
    selection=retail_selection,
    description=(
        "SFTP extraction through to dbt marts. Completes successfully with "
        "warnings when the source data carries its seeded defects."
    ),
)

synthetic_job = define_asset_job(
    name="synthetic_ingest",
    selection=AssetSelection.groups("synthetic_ingest"),
    description=f"Generate synthetic records into the {FAKER_SCHEMA} schema.",
)

daily_schedule = ScheduleDefinition(
    job=retail_job,
    cron_schedule="0 6 * * *",
    execution_timezone="UTC",
    # Off by default: this is a demo repository, and a schedule that starts
    # firing the moment someone runs `docker compose up` is a surprise, not a
    # feature. Turn it on from the Automation tab.
    default_status=DefaultScheduleStatus.STOPPED,
)

defs = Definitions(
    assets=[sftp_retail_ingest, synthetic_ingest, retail_dbt_assets],
    jobs=[retail_job, synthetic_job],
    schedules=[daily_schedule],
    resources=build_resources(),
)
