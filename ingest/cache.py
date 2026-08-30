"""The PyAirbyte destination cache.

PyAirbyte ships cache backends for DuckDB, Postgres, Snowflake, BigQuery and
MotherDuck. This project uses Postgres and only Postgres -- the other drivers
are present in the virtualenv purely because PyAirbyte declares them as
unconditional dependencies, and nothing here touches them.
"""

from __future__ import annotations

import os

from airbyte.caches import PostgresCache


def _require(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(
            f"environment variable {name} is required but was not set; "
            "see .env.example"
        )
    return value


def build_cache(schema_name: str) -> PostgresCache:
    """Build a Postgres-backed cache writing into ``schema_name``.

    PyAirbyte creates the schema if it does not exist, but postgres/init.sql
    creates all three up front so permissions are settled before any sync runs.
    """
    return PostgresCache(
        host=os.environ.get("POSTGRES_HOST", "postgres"),
        port=int(os.environ.get("POSTGRES_PORT", "5432")),
        username=_require("POSTGRES_USER"),
        password=_require("POSTGRES_PASSWORD"),
        database=_require("POSTGRES_DB"),
        schema_name=schema_name,
    )
