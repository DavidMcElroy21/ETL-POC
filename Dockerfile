# syntax=docker/dockerfile:1.7
#
# One application image containing the whole pipeline: PyAirbyte for extraction,
# dbt for transformation, Dagster for orchestration. Postgres and the SFTP
# server are stock upstream images supplied by docker-compose.yml.
#
# Two virtualenvs, one image
# --------------------------
# PyAirbyte and dbt/Dagster cannot share a virtualenv. Their resolved
# dependency sets genuinely conflict -- protobuf 7.x vs 6.x, rich 13.x vs 15.x,
# and PyAirbyte hard-pins sqlalchemy==2.0.43. Forcing one resolution would mean
# downgrading something load-bearing in one half or the other.
#
# So each gets its own virtualenv and its own independently compiled lock file,
# and Dagster invokes the ingestion venv as a subprocess over Dagster Pipes.
# That is a process boundary, not a container boundary: still a single image.
#
# Pinning
# -------
# Nothing resolves at build time. The base image is pinned by digest, apt
# packages by exact version, and Python dependencies by the hash-pinned
# requirements/*.lock files installed with --require-hashes. Regenerate the
# locks with scripts/lock_requirements.sh.

# python:3.11-slim-bookworm
#
# 3.11 is not a preference, it is the only version that works: PyAirbyte
# requires >=3.10,<3.13 and the sftp-bulk connector requires >=3.10,<3.12.
ARG BASE_IMAGE=python@sha256:0bee7276f83efd4a1ee05bbbf4281d95ed28e079220a9457f25a93e3f1e3c31b


# ---------------------------------------------------------------------------
# Stage: base -- OS packages shared by every later stage.
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS base

# Exact apt versions, per the pinning policy. These are Debian bookworm point
# releases; when Debian rotates them out of the mirror this build fails loudly
# rather than silently drifting. Refresh them with:
#   docker run --rm <base> sh -c 'apt-get update -qq; apt-cache policy git libpq5'
ARG APT_GIT_VERSION=1:2.39.5-0+deb12u3
ARG APT_LIBPQ_VERSION=15.19-0+deb12u1
ARG APT_CA_CERTIFICATES_VERSION=20250419~deb12u1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git="${APT_GIT_VERSION}" \
        libpq5="${APT_LIBPQ_VERSION}" \
        ca-certificates="${APT_CA_CERTIFICATES_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

# Pin the build toolchain before it is used to install anything else.
ARG PIP_VERSION=24.0
ARG SETUPTOOLS_VERSION=79.0.1
ARG WHEEL_VERSION=0.46.3
RUN pip install --no-cache-dir --upgrade \
        "pip==${PIP_VERSION}" \
        "setuptools==${SETUPTOOLS_VERSION}" \
        "wheel==${WHEEL_VERSION}"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1


# ---------------------------------------------------------------------------
# Stage: ingest-venv -- PyAirbyte, plus the connector virtualenvs it will use.
# ---------------------------------------------------------------------------
FROM base AS ingest-venv

ENV INGEST_VENV=/opt/venv/ingest \
    AIRBYTE_CONNECTOR_ROOT=/opt/airbyte/connectors

RUN python -m venv "${INGEST_VENV}"

COPY requirements/ingest.lock /tmp/ingest.lock
# --require-hashes verifies every artifact and implies --no-deps, so the lock is
# the complete and only input to this install.
RUN "${INGEST_VENV}/bin/pip" install \
        --no-cache-dir \
        --require-hashes \
        --requirement /tmp/ingest.lock \
    && rm /tmp/ingest.lock

# Bake the Airbyte connector virtualenvs into the image. Without this, PyAirbyte
# would download and install each connector on first run, making container start
# slow and dependent on network access at exactly the wrong moment.
COPY ingest /tmp/build/ingest
COPY scripts/install_connectors.py /tmp/build/install_connectors.py
# PyAirbyte builds each connector virtualenv by shelling out to `uv` by name, so
# the ingest venv's bin directory has to be on PATH -- uv is installed into that
# venv as one of PyAirbyte's own dependencies.
RUN PATH="${INGEST_VENV}/bin:${PATH}" \
    PYTHONPATH=/tmp/build \
    "${INGEST_VENV}/bin/python" /tmp/build/install_connectors.py \
    && rm -rf /tmp/build


# ---------------------------------------------------------------------------
# Stage: orchestrator-venv -- Dagster, dagster-dbt and dbt-postgres.
# ---------------------------------------------------------------------------
FROM base AS orchestrator-venv

ENV ORCHESTRATOR_VENV=/opt/venv/orchestrator

RUN python -m venv "${ORCHESTRATOR_VENV}"

COPY requirements/orchestrator.lock /tmp/orchestrator.lock
RUN "${ORCHESTRATOR_VENV}/bin/pip" install \
        --no-cache-dir \
        --require-hashes \
        --requirement /tmp/orchestrator.lock \
    && rm /tmp/orchestrator.lock

# Resolve dbt packages at build time and commit the result into the image.
# package-lock.yml pins the exact dbt_utils revision, so this is reproducible.
WORKDIR /opt/etl/dbt/retail
# dbt deps reads dbt_project.yml for the project name and package install path,
# so it has to be here too -- packages.yml alone is not enough.
COPY dbt/retail/dbt_project.yml dbt/retail/packages.yml dbt/retail/package-lock.yml ./
RUN "${ORCHESTRATOR_VENV}/bin/dbt" deps --project-dir /opt/etl/dbt/retail


# ---------------------------------------------------------------------------
# Stage: runtime
# ---------------------------------------------------------------------------
FROM base AS runtime

ENV INGEST_VENV=/opt/venv/ingest \
    ORCHESTRATOR_VENV=/opt/venv/orchestrator \
    AIRBYTE_CONNECTOR_ROOT=/opt/airbyte/connectors \
    APP_HOME=/opt/etl \
    DAGSTER_HOME=/opt/dagster/home \
    DBT_PROJECT_DIR=/opt/etl/dbt/retail \
    DBT_PROFILES_DIR=/opt/etl/dbt/retail

# dbt opens a rotating log file on every invocation. Keeping it outside the
# project directory lets the image run with the app tree read-only, and avoids
# the runtime user inheriting a logs/ directory created by root at build time.
ENV DBT_LOG_PATH=/tmp/dbt/logs

# PyAirbyte reports anonymous usage statistics by default. Off here: this is a
# demo people will run without reading the source first, and sending telemetry
# on their behalf is not a decision this project should make for them.
# Dagster telemetry is disabled separately, in dagster.yaml.
ENV DO_NOT_TRACK=1

# The orchestrator venv is first on PATH: `dagster` and `dbt` resolve without
# qualification, while the ingest venv is addressed explicitly by full path so
# there is never any doubt about which interpreter is running the connector.
ENV PATH="${ORCHESTRATOR_VENV}/bin:${PATH}"

RUN groupadd --system --gid 1000 etl \
    && useradd --system --uid 1000 --gid etl --create-home --home-dir /home/etl etl \
    && mkdir -p "${APP_HOME}" "${DAGSTER_HOME}" \
    && chown -R etl:etl "${APP_HOME}" "${DAGSTER_HOME}" /opt/venv 2>/dev/null || true

COPY --from=ingest-venv --chown=etl:etl /opt/venv/ingest /opt/venv/ingest
COPY --from=ingest-venv --chown=etl:etl /opt/airbyte /opt/airbyte
COPY --from=orchestrator-venv --chown=etl:etl /opt/venv/orchestrator /opt/venv/orchestrator
COPY --from=orchestrator-venv --chown=etl:etl /opt/etl/dbt/retail/dbt_packages /opt/etl/dbt/retail/dbt_packages

WORKDIR ${APP_HOME}

COPY --chown=etl:etl dagster.yaml workspace.yaml docker-entrypoint.sh ./
RUN chmod +x ./docker-entrypoint.sh
COPY --chown=etl:etl pipeline ./pipeline
COPY --chown=etl:etl ingest ./ingest
COPY --chown=etl:etl dbt ./dbt
COPY --chown=etl:etl scripts ./scripts

# Compile the dbt manifest into the image. Dagster needs manifest.json to build
# its asset graph at code-load time; producing it here means an unparseable dbt
# project fails the build instead of the first run.
RUN "${ORCHESTRATOR_VENV}/bin/dbt" parse \
        --project-dir "${DBT_PROJECT_DIR}" \
        --profiles-dir "${DBT_PROFILES_DIR}" \
        --target build \
    && rm -rf "${DBT_PROJECT_DIR}/logs" \
    && chown -R etl:etl "${DBT_PROJECT_DIR}" \
    && mkdir -p "${DBT_LOG_PATH}" \
    && chown -R etl:etl "${DBT_LOG_PATH}"

USER etl

# Both venvs must be importable from the app root for `python -m pipeline...`
# and `python -m ingest...` to work.
ENV PYTHONPATH=${APP_HOME}

EXPOSE 3000

HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=5 \
    CMD python -c "import urllib.request;urllib.request.urlopen('http://localhost:3000/server_info').read()" || exit 1

ENTRYPOINT ["/opt/etl/docker-entrypoint.sh"]
CMD ["dagster", "dev", "--host", "0.0.0.0", "--port", "3000", "--workspace", "/opt/etl/workspace.yaml"]
