# syntax=docker/dockerfile:1.7
#
# One application image containing the whole pipeline: PyAirbyte for extraction,
# dbt for transformation, Dagster for orchestration. Postgres and the SFTP
# server are stock upstream images supplied by docker-compose.yml.
#
# Everything is fetched at build time
# -----------------------------------
# The application source is cloned from the published repository at an exact
# commit, not copied from the local build context. Together with the pinned
# dependency locks that means a build downloads everything it will ever need,
# and the resulting container runs with no network access at all.
#
# For local development, build from the working tree instead:
#   docker compose build --build-arg SOURCE_STAGE=local-source app
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
# Nothing resolves at build time. The source is pinned by commit, the base image
# by digest, apt packages by exact version, and Python dependencies by the
# hash-pinned requirements/*.lock files installed with --require-hashes.
# Regenerate the locks with scripts/lock_requirements.sh.

# python:3.11-slim-bookworm
#
# 3.11 is not a preference, it is the only version that works: PyAirbyte
# requires >=3.10,<3.13 and the sftp-bulk connector requires >=3.10,<3.12.
ARG BASE_IMAGE=python@sha256:0bee7276f83efd4a1ee05bbbf4281d95ed28e079220a9457f25a93e3f1e3c31b

# Which stage the application source comes from. Default is the pinned clone;
# override with `local-source` to build the working tree.
ARG SOURCE_STAGE=git-source


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
# Stage: git-source -- the application source, cloned at an exact commit.
#
# GIT_COMMIT must name a pushed commit whose source tree matches the one being
# built -- for pipeline/, ingest/, dbt/, scripts/, requirements/ and the YAML
# files below, which are all this image copies.
#
# It does not have to equal the tip of main. The commit that updates this pin
# edits only the Dockerfile, which is never copied into the image, so the pin
# stays valid across it.
#
#   ./scripts/pin_source_commit.sh           re-pin after changing source
#   ./scripts/pin_source_commit.sh --check   verify the pin (also runs in CI)
# ---------------------------------------------------------------------------
FROM base AS git-source

ARG GIT_REPO_URL=https://github.com/DavidMcElroy21/ETL-POC.git
ARG GIT_COMMIT=eb6693501951eb77815bbd87e7fd09040d8c56e7

WORKDIR /src
# Fetching the single commit rather than cloning the whole history keeps the
# download small, and checking out by full SHA means the result cannot change
# under us even if a branch or tag is later moved.
RUN git init --quiet . \
    && git remote add origin "${GIT_REPO_URL}" \
    && git fetch --quiet --depth 1 origin "${GIT_COMMIT}" \
    && git checkout --quiet FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "${GIT_COMMIT}" \
    && rm -rf /src/.git \
    && echo "${GIT_COMMIT}" > /src/GIT_COMMIT


# ---------------------------------------------------------------------------
# Stage: local-source -- the working tree, for development builds.
# ---------------------------------------------------------------------------
FROM base AS local-source

WORKDIR /src
COPY . /src
RUN echo "local-working-tree" > /src/GIT_COMMIT


# ---------------------------------------------------------------------------
# Stage: source -- whichever of the two was selected.
# ---------------------------------------------------------------------------
FROM ${SOURCE_STAGE} AS source


# ---------------------------------------------------------------------------
# Stage: ingest-venv -- PyAirbyte, plus the connector virtualenvs it will use.
# ---------------------------------------------------------------------------
FROM base AS ingest-venv

ENV INGEST_VENV=/opt/venv/ingest \
    AIRBYTE_CONNECTOR_ROOT=/opt/airbyte/connectors

RUN python -m venv "${INGEST_VENV}"

COPY --from=source /src/requirements/ingest.lock /tmp/ingest.lock
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
COPY --from=source /src/ingest /tmp/build/ingest
COPY --from=source /src/scripts/install_connectors.py /tmp/build/install_connectors.py
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

COPY --from=source /src/requirements/orchestrator.lock /tmp/orchestrator.lock
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
COPY --from=source /src/dbt/retail/dbt_project.yml ./
COPY --from=source /src/dbt/retail/packages.yml ./
COPY --from=source /src/dbt/retail/package-lock.yml ./
RUN "${ORCHESTRATOR_VENV}/bin/dbt" deps --project-dir /opt/etl/dbt/retail


# ---------------------------------------------------------------------------
# Stage: app-base -- settings and the runtime user, shared by every final image.
#
# Three images are built from this file, and they differ only in which
# virtualenv and which source they carry:
#
#   runtime       both venvs, everything. The local `docker compose` stack.
#   orchestrator  Dagster + dbt. Azure: webserver, daemon, code location, run worker.
#   ingest        PyAirbyte + connectors. Azure: the ingest job.
#
# Splitting them is the point of the Azure deployment: the ingestion half runs
# as its own container rather than a subprocess of whatever launched it. The
# venv boundary that made that possible already existed -- see the header.
# ---------------------------------------------------------------------------
FROM base AS app-base

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

# Without this, PyAirbyte contacts the Airbyte connector registry on every
# get_source() call -- even for a connector already installed locally -- and
# raises AirbyteConnectorRegistryError when it cannot reach it. The connector
# virtualenvs are baked into this image and every version is pinned explicitly
# in ingest/connectors.py, so there is nothing the registry can tell us.
# Setting it makes the container work with no internet access at all; see
# docker-compose.offline.yml.
ENV AIRBYTE_OFFLINE_MODE=1

# Both venvs must be importable from the app root for `python -m pipeline...`
# and `python -m ingest...` to work.
ENV PYTHONPATH=${APP_HOME}

RUN groupadd --system --gid 1000 etl \
    && useradd --system --uid 1000 --gid etl --create-home --home-dir /home/etl etl \
    && mkdir -p "${APP_HOME}" "${DAGSTER_HOME}" \
    && chown -R etl:etl "${APP_HOME}" "${DAGSTER_HOME}" /opt/venv 2>/dev/null || true


# ---------------------------------------------------------------------------
# Stage: runtime -- the combined image the local compose stack runs.
# ---------------------------------------------------------------------------
FROM app-base AS runtime

# The orchestrator venv is first on PATH: `dagster` and `dbt` resolve without
# qualification, while the ingest venv is addressed explicitly by full path so
# there is never any doubt about which interpreter is running the connector.
ENV PATH="${ORCHESTRATOR_VENV}/bin:${PATH}"

COPY --from=ingest-venv --chown=etl:etl /opt/venv/ingest /opt/venv/ingest
COPY --from=ingest-venv --chown=etl:etl /opt/airbyte /opt/airbyte
COPY --from=orchestrator-venv --chown=etl:etl /opt/venv/orchestrator /opt/venv/orchestrator
COPY --from=orchestrator-venv --chown=etl:etl /opt/etl/dbt/retail/dbt_packages /opt/etl/dbt/retail/dbt_packages

WORKDIR ${APP_HOME}

COPY --from=source --chown=etl:etl /src/dagster.yaml ./
COPY --from=source --chown=etl:etl /src/workspace.yaml ./
COPY --from=source --chown=etl:etl /src/docker-entrypoint.sh ./
COPY --from=source --chown=etl:etl /src/GIT_COMMIT ./
RUN chmod +x ./docker-entrypoint.sh
COPY --from=source --chown=etl:etl /src/pipeline ./pipeline
COPY --from=source --chown=etl:etl /src/ingest ./ingest
COPY --from=source --chown=etl:etl /src/dbt ./dbt
COPY --from=source --chown=etl:etl /src/scripts ./scripts

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

EXPOSE 3000

HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=5 \
    CMD python -c "import urllib.request;urllib.request.urlopen('http://localhost:3000/server_info').read()" || exit 1

ENTRYPOINT ["/opt/etl/docker-entrypoint.sh"]
CMD ["dagster", "dev", "--host", "0.0.0.0", "--port", "3000", "--workspace", "/opt/etl/workspace.yaml"]


# ---------------------------------------------------------------------------
# Stage: orchestrator -- Dagster and dbt, without PyAirbyte.
#
# Runs four of the five Azure workloads: the webserver, the daemon, the
# code-location gRPC server, and the per-run worker. They differ only in the
# command Container Apps gives them, so they share one image.
#
# No PyAirbyte here. That is the whole point: ingestion is a separate container
# now, so this image does not carry Snowflake, BigQuery and DuckDB drivers it
# will never load.
# ---------------------------------------------------------------------------
FROM app-base AS orchestrator

ENV PATH="${ORCHESTRATOR_VENV}/bin:${PATH}"

COPY --from=orchestrator-venv --chown=etl:etl /opt/venv/orchestrator /opt/venv/orchestrator
COPY --from=orchestrator-venv --chown=etl:etl /opt/etl/dbt/retail/dbt_packages /opt/etl/dbt/retail/dbt_packages

WORKDIR ${APP_HOME}

COPY --from=source --chown=etl:etl /src/GIT_COMMIT ./
COPY --from=source --chown=etl:etl /src/pipeline ./pipeline
COPY --from=source --chown=etl:etl /src/dbt ./dbt
COPY --from=source --chown=etl:etl /src/scripts ./scripts

# The Azure instance and workspace configuration. scripts/azure/entrypoint.sh
# copies dagster.azure.yaml into DAGSTER_HOME at start, and the webserver and
# daemon are given workspace.azure.yaml explicitly. Neither replaces the local
# dagster.yaml/workspace.yaml, which stay with the `runtime` stage.
COPY --from=source --chown=etl:etl /src/dagster.azure.yaml ./
COPY --from=source --chown=etl:etl /src/workspace.azure.yaml ./
RUN chmod +x ./scripts/azure/entrypoint.sh

# ingest/streams.py is the single definition of the stream list and the raw
# schema names. pipeline/ imports it to build asset keys, and the ingest image
# imports it to drive the connector, which is what stops the two drifting
# apart. It is standard library only, so it costs this image nothing.
COPY --from=source --chown=etl:etl /src/ingest/__init__.py ./ingest/
COPY --from=source --chown=etl:etl /src/ingest/streams.py ./ingest/

# Same reasoning as the combined image: bake the manifest so the asset graph
# loads without shelling out to dbt, and so an unparseable project fails the
# build rather than the first run.
RUN "${ORCHESTRATOR_VENV}/bin/dbt" parse \
        --project-dir "${DBT_PROJECT_DIR}" \
        --profiles-dir "${DBT_PROFILES_DIR}" \
        --target build \
    && rm -rf "${DBT_PROJECT_DIR}/logs" \
    && chown -R etl:etl "${DBT_PROJECT_DIR}" \
    && mkdir -p "${DBT_LOG_PATH}" \
    && chown -R etl:etl "${DBT_LOG_PATH}"

USER etl

# The code-location gRPC port. The webserver and daemon reach it over the
# Container Apps environment's internal ingress; nothing is published publicly.
EXPOSE 4000

# Everything goes through the shared Azure entrypoint, which mints the Postgres
# token and lays down the instance config. The webserver, daemon and run worker
# override the command -- and because a Container Apps command override
# replaces ENTRYPOINT rather than CMD, each of those overrides names this
# script itself as its first element. See pipeline/azure/aca_client.py.
ENTRYPOINT ["/opt/etl/scripts/azure/entrypoint.sh"]

# Default to the code-location server, the one workload that does not override.
CMD ["dagster", "api", "grpc", "--host", "0.0.0.0", "--port", "4000", \
     "--module-name", "pipeline.definitions"]


# ---------------------------------------------------------------------------
# Stage: ingest -- PyAirbyte and its connectors, without Dagster or dbt.
#
# Runs one Azure workload: the ingest job, started per sync by the Dagster run
# worker through Pipes. It talks back over blob storage rather than a socket,
# because Container Apps jobs have no ingress.
# ---------------------------------------------------------------------------
FROM app-base AS ingest

ENV PATH="${INGEST_VENV}/bin:${PATH}"

COPY --from=ingest-venv --chown=etl:etl /opt/venv/ingest /opt/venv/ingest
COPY --from=ingest-venv --chown=etl:etl /opt/airbyte /opt/airbyte

WORKDIR ${APP_HOME}

COPY --from=source --chown=etl:etl /src/GIT_COMMIT ./
COPY --from=source --chown=etl:etl /src/ingest ./ingest

# Only the Azure scripts, not all of scripts/ -- the rest of that directory is
# build and repo tooling with no business in a runtime image. These two are
# stdlib plus azure-identity, so they run under the ingest virtualenv as
# happily as under the orchestrator one.
COPY --from=source --chown=etl:etl /src/scripts/azure ./scripts/azure
RUN chmod +x ./scripts/azure/entrypoint.sh

USER etl

ENTRYPOINT ["/opt/etl/scripts/azure/entrypoint.sh"]

# No default command. Every execution names the module it wants -- the SFTP
# sync, the faker sync -- so leaving this unset makes a misconfigured job fail
# loudly instead of silently running the wrong sync.
CMD ["python", "-c", "import sys; sys.exit('ingest image: specify a module, e.g. -m ingest.run_sftp_sync')"]
