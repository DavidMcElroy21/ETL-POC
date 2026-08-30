#!/usr/bin/env python3
"""Install the Airbyte connector virtualenvs at image build time.

PyAirbyte runs each connector in its own virtualenv. Left to itself it creates
that virtualenv on first use, which makes the first pipeline run slow and, worse,
dependent on PyPI being reachable at the moment someone runs the demo. Doing it
here bakes the connectors into an image layer instead.

Runs inside the ingest virtualenv. See ingest/connectors.py for the pins.
"""

from __future__ import annotations

import sys

from airbyte import get_source

from ingest.connectors import ALL_CONNECTORS, CONNECTOR_ROOT


def main() -> int:
    CONNECTOR_ROOT.mkdir(parents=True, exist_ok=True)

    for connector in ALL_CONNECTORS:
        print(f"Installing {connector.name} from {connector.pip_url} ...", flush=True)
        source = get_source(
            connector.name,
            pip_url=connector.pip_url,
            install_root=CONNECTOR_ROOT,
            install_if_missing=True,
        )

        # Reading the spec actually executes the connector, so it proves the
        # virtualenv is runnable rather than merely present -- and it fails the
        # image build rather than the first pipeline run.
        top_level = sorted(source.config_spec.get("properties", {}))
        installed = source.connector_version or "unknown"

        print(f"  ok: {connector.name} {installed}", flush=True)
        print(f"      config keys: {', '.join(top_level)}", flush=True)

    print(f"\nConnector root: {CONNECTOR_ROOT}")
    for path in sorted(CONNECTOR_ROOT.iterdir()):
        print(f"  {path.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
