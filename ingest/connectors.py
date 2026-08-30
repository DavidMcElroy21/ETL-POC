"""Shared definitions for the Airbyte connectors this project uses.

Both the build-time installer (scripts/install_connectors.py) and the runtime
sync scripts import from here, so a connector is pinned in exactly one place.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

# Where the connector virtualenvs live. The Dockerfile creates these at build
# time so that nothing has to be downloaded on first run.
CONNECTOR_ROOT = Path(os.environ.get("AIRBYTE_CONNECTOR_ROOT", "/opt/airbyte/connectors"))


@dataclass(frozen=True)
class Connector:
    """An Airbyte source pinned to an exact PyPI release.

    pip_url is always explicit. Left unset, PyAirbyte resolves the version from
    the Airbyte connector registry at call time, which would make the build
    non-reproducible.
    """

    name: str
    version: str

    @property
    def pip_url(self) -> str:
        # Connectors publish to PyPI as "airbyte-<connector-name>", e.g.
        # source-sftp-bulk -> airbyte-source-sftp-bulk.
        return f"airbyte-{self.name}=={self.version}"


SFTP_BULK = Connector(name="source-sftp-bulk", version="1.9.2")
FAKER = Connector(name="source-faker", version="7.2.1")

# Installed into the image at build time so that everything works offline.
ALL_CONNECTORS = (SFTP_BULK, FAKER)

# ---------------------------------------------------------------------------
# Why source-file and source-s3 are absent
#
# Both are unusable from PyPI. Every published version declares
# `smart-open[...]==<the connector's own version>` -- the release tooling
# substituted the connector version into an unrelated dependency's pin, and no
# such smart-open release exists, so the install can never resolve:
#
#   Because there is no version of smart-open[s3]==4.15.20 and
#   airbyte-source-s3==4.15.20 depends on smart-open[s3]==4.15.20, we can
#   conclude that airbyte-source-s3==4.15.20 cannot be used.
#
# Verified against airbyte-source-file 0.5.42-0.6.0 and the newest 25 releases
# of airbyte-source-s3. Both connectors are fine as Docker images; it is only
# the PyPI packaging that is broken.
#
# The local-file and S3 ingestion paths therefore read their sources directly
# (pandas and boto3 respectively) instead of going through a connector. For
# those two options that is arguably the better demonstration anyway: the point
# of reading local files is to take the transport out of the loop, and the point
# of MinIO is to exercise S3 semantics, neither of which needs a connector.
#
# See ingest/run_local_file_sync.py and ingest/run_s3_sync.py.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Why there is no source-postgres entry
#
# Airbyte's Postgres source is a Java connector. It is not on PyPI at all and
# can only be run as a Docker image, which would mean giving the app container
# access to the Docker socket.
#
# The CDC path here uses Postgres logical replication directly instead --
# psycopg2 against a replication slot, which is the same mechanism the connector
# wraps. Pure Python, no Java, no Docker socket, and it works offline.
#
# See ingest/run_postgres_cdc_sync.py.
# ---------------------------------------------------------------------------
