#!/usr/bin/env python3
"""Generate synthetic records with source-faker and load them into Postgres.

This is the second, deliberately contrasting ingestion path. Where the SFTP
route exercises file transport, globbing, CSV parsing and incremental file
discovery, this one exercises none of that -- it needs no server, no files and
no network, and it produces as many rows as you ask for.

That combination is what makes it useful for model testing and training work:
volume on demand, reproducible from a seed, and nothing to stand up first. See
docs/local-ingestion-options.md for where it sits among the alternatives.

    /opt/venv/ingest/bin/python -m ingest.run_faker_sync --count 50000
"""

from __future__ import annotations

import argparse
import sys

from airbyte import get_source

from ingest.cache import build_cache
from ingest.connectors import CONNECTOR_ROOT, FAKER
from ingest.pipes import PipesReporter
from ingest.streams import FAKER_SCHEMA, FAKER_STREAM_NAMES

DEFAULT_COUNT = 10_000
DEFAULT_SEED = 42


def build_source(count: int, seed: int):
    return get_source(
        FAKER.name,
        config={
            "count": count,
            "seed": seed,
            "parallelism": 1,
        },
        streams=list(FAKER_STREAM_NAMES),
        pip_url=FAKER.pip_url,
        install_root=CONNECTOR_ROOT,
        install_if_missing=False,
    )


def sync(count: int, seed: int, reporter: PipesReporter) -> int:
    source = build_source(count, seed)
    source.check()

    cache = build_cache(FAKER_SCHEMA)
    reporter.log(f"generating {count} synthetic records (seed {seed}) ...")

    result = source.read(cache=cache, write_strategy="replace")

    for name in FAKER_STREAM_NAMES:
        row_count = len(result[name])
        reporter.report_stream(
            stream_name=name,
            metadata={
                "rows_loaded": row_count,
                "destination_table": f"{FAKER_SCHEMA}.{name}",
                "requested_count": count,
                "seed": seed,
                "connector": f"{FAKER.name} {FAKER.version}",
            },
        )
        reporter.log(f"  {name}: {row_count} rows")

    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--count",
        type=int,
        default=DEFAULT_COUNT,
        help=f"records to generate for the users stream (default: {DEFAULT_COUNT})",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=DEFAULT_SEED,
        help=f"generator seed; the same seed reproduces the same data (default: {DEFAULT_SEED})",
    )
    args = parser.parse_args(argv)

    with PipesReporter.open(asset_key_prefix=FAKER_SCHEMA) as reporter:
        count = reporter.get_extra("count", args.count)
        seed = reporter.get_extra("seed", args.seed)
        return sync(int(count), int(seed), reporter)


if __name__ == "__main__":
    sys.exit(main())
