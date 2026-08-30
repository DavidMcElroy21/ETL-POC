"""Paths and environment wiring for the Dagster code location."""

from __future__ import annotations

import os
from pathlib import Path

APP_HOME = Path(os.environ.get("APP_HOME", "/opt/etl"))

# The ingestion virtualenv. Dagster never imports from it -- PyAirbyte and
# dbt/Dagster have genuinely conflicting dependency sets, so they are kept in
# separate virtualenvs and talk over Dagster Pipes instead. This is the
# interpreter that gets executed as a subprocess.
INGEST_PYTHON = Path(os.environ.get("INGEST_VENV", "/opt/venv/ingest")) / "bin" / "python"

DBT_PROJECT_DIR = Path(os.environ.get("DBT_PROJECT_DIR", str(APP_HOME / "dbt" / "retail")))
DBT_PROFILES_DIR = Path(os.environ.get("DBT_PROFILES_DIR", str(DBT_PROJECT_DIR)))

# Environment the ingest subprocess needs. Passed explicitly rather than
# inherited wholesale, so it is obvious what the connector actually depends on.
INGEST_ENV_VARS = (
    "POSTGRES_HOST",
    "POSTGRES_PORT",
    "POSTGRES_USER",
    "POSTGRES_PASSWORD",
    "POSTGRES_DB",
    "SFTP_HOST",
    "SFTP_PORT",
    "SFTP_USER",
    "SFTP_PASSWORD",
    "SFTP_FOLDER_PATH",
    "AIRBYTE_CONNECTOR_ROOT",
    "PYTHONPATH",
    # Alternative ingestion paths -- see docs/local-ingestion-options.md.
    "S3_ENDPOINT_URL",
    "S3_ACCESS_KEY",
    "S3_SECRET_KEY",
    "S3_BUCKET",
    "S3_PREFIX",
    "S3_REGION",
    "CDC_SOURCE_HOST",
    "CDC_SOURCE_PORT",
    "CDC_SOURCE_USER",
    "CDC_SOURCE_PASSWORD",
    "CDC_SOURCE_DB",
    "CDC_SLOT_NAME",
    "LOCAL_FILES_PATH",
)


def ingest_env() -> dict[str, str]:
    """Collect the subset of the environment the ingest subprocess needs."""
    env = {name: os.environ[name] for name in INGEST_ENV_VARS if name in os.environ}
    # PyAirbyte otherwise prints progress with terminal control codes, which are
    # noise in captured Dagster logs.
    env.setdefault("NO_COLOR", "1")
    env.setdefault("PYTHONPATH", str(APP_HOME))
    return env
