#!/usr/bin/env python3
"""Extract the retail CSV files from SFTP into Postgres.

Runs in the ingest virtualenv, launched by Dagster as a subprocess. Progress and
per-stream row counts are reported back over Dagster Pipes, so the Dagster UI
shows real materialization metadata rather than just a wall of subprocess logs.

Also runnable standalone, which is the quickest way to debug a connection
problem without going through the orchestrator:

    /opt/venv/ingest/bin/python -m ingest.run_sftp_sync --check
    /opt/venv/ingest/bin/python -m ingest.run_sftp_sync --streams customers,orders
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Any

from airbyte import get_source

from ingest.cache import build_cache
from ingest.connectors import CONNECTOR_ROOT, SFTP_BULK
from ingest.pipes import PipesReporter
from ingest.streams import RAW_SCHEMA, RETAIL_STREAM_NAMES, RETAIL_STREAMS, stream_by_name

# Far enough in the past to sweep up every file on the server. The connector
# uses this as the lower bound of its file-modification-time window.
START_DATE = "2020-01-01T00:00:00.000000Z"


def build_config(stream_names: list[str]) -> dict[str, Any]:
    """Build the source-sftp-bulk configuration.

    The shape here follows AbstractFileBasedSpec: connection details at the top
    level, then one entry in `streams` per logical entity, each with its own file
    glob and parsing rules.
    """
    selected = [stream_by_name(name) for name in stream_names]

    return {
        "host": os.environ.get("SFTP_HOST", "sftp"),
        "port": int(os.environ.get("SFTP_PORT", "22")),
        "username": os.environ.get("SFTP_USER", "etl"),
        "credentials": {
            # `auth_type` is the discriminator for the credentials union; the
            # alternative branch is "private_key".
            "auth_type": "password",
            "password": os.environ.get("SFTP_PASSWORD", ""),
        },
        "folder_path": os.environ.get("SFTP_FOLDER_PATH", "/upload/retail"),
        "start_date": START_DATE,
        "delivery_method": {"delivery_type": "use_records_transfer"},
        "streams": [
            {
                "name": stream.name,
                "globs": [stream.glob],
                # "Emit Record" keeps rows that do not match the inferred schema
                # instead of discarding them. That matters here: the whole point
                # is to carry defects downstream so dbt can flag them, not to
                # silently drop the interesting rows at the front door.
                "validation_policy": "Emit Record",
                "format": {
                    "filetype": "csv",
                    "delimiter": ",",
                    "quote_char": '"',
                    "double_quote": True,
                    "encoding": "utf8",
                    "header_definition": {"header_definition_type": "From CSV"},
                    # Defaults to empty, which would leave blank fields as ""
                    # rather than NULL and quietly defeat every not_null test.
                    "null_values": ["", "NULL", "null", "N/A", "n/a"],
                    "strings_can_be_null": True,
                    # "None" means no type inference: every column arrives as
                    # text and dbt does the casting in the staging layer, where
                    # it is visible and reviewable.
                    "inference_type": "None",
                },
            }
            for stream in selected
        ],
    }


def build_source(stream_names: list[str]):
    return get_source(
        SFTP_BULK.name,
        config=build_config(stream_names),
        streams=stream_names,
        pip_url=SFTP_BULK.pip_url,
        install_root=CONNECTOR_ROOT,
        # The connector venv is baked into the image. If it is missing something
        # is wrong with the build, and installing it silently here would hide
        # that.
        install_if_missing=False,
    )


def check() -> int:
    """Verify SFTP connectivity without moving any data.

    `check()` raises on failure and returns nothing on success, so reaching the
    print statement is itself the result.
    """
    source = build_source(list(RETAIL_STREAM_NAMES))
    source.check()
    host = os.environ.get("SFTP_HOST", "sftp")
    folder = os.environ.get("SFTP_FOLDER_PATH", "/upload/retail")
    print(f"check OK: connected to {host} and read {folder}")
    return 0


def sync(stream_names: list[str], reporter: PipesReporter) -> int:
    source = build_source(stream_names)

    reporter.log(f"checking connection to {os.environ.get('SFTP_HOST', 'sftp')} ...")
    source.check()

    cache = build_cache(RAW_SCHEMA)
    reporter.log(f"reading {len(stream_names)} stream(s) into {RAW_SCHEMA} ...")

    result = source.read(cache=cache, write_strategy="replace")

    for name in stream_names:
        stream = stream_by_name(name)
        dataset = result[name]
        row_count = len(dataset)

        # Which files actually contributed. This is the lineage detail that gets
        # asked for first when a number looks wrong downstream.
        source_files = sorted(
            {
                str(record.get("_ab_source_file_url", ""))
                for record in dataset
                if record.get("_ab_source_file_url")
            }
        )

        reporter.report_stream(
            stream_name=name,
            metadata={
                "rows_loaded": row_count,
                "destination_table": f"{RAW_SCHEMA}.{name}",
                "primary_key": stream.primary_key,
                "source_files": source_files or ["(none reported)"],
                "file_glob": stream.glob,
                "connector": f"{SFTP_BULK.name} {SFTP_BULK.version}",
            },
        )
        reporter.log(f"  {name}: {row_count} rows from {len(source_files)} file(s)")

    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="run the connector check and exit without syncing",
    )
    parser.add_argument(
        "--streams",
        default=",".join(RETAIL_STREAM_NAMES),
        help="comma-separated stream names (default: all)",
    )
    args = parser.parse_args(argv)

    if args.check:
        return check()

    requested = [name.strip() for name in args.streams.split(",") if name.strip()]
    unknown = sorted(set(requested) - set(RETAIL_STREAM_NAMES))
    if unknown:
        parser.error(f"unknown stream(s): {', '.join(unknown)}")

    with PipesReporter.open(
        asset_key_prefix=RAW_SCHEMA, default_streams=requested
    ) as reporter:
        return sync(reporter.streams or requested, reporter)


if __name__ == "__main__":
    sys.exit(main())
