#!/usr/bin/env bash
# Container entrypoint for the Azure deployment, shared by every image.
#
# The local docker-entrypoint.sh exists to copy dagster.yaml into DAGSTER_HOME.
# Azure needs that too, and two things besides:
#
#   1. A Postgres password that is an Entra token rather than a stored secret.
#   2. To still be the entrypoint when Container Apps overrides the command --
#      which is why the run launcher and the Pipes client both prepend this
#      script's path rather than replacing it. An ACA `command` override
#      replaces ENTRYPOINT outright, so an entrypoint alone would be bypassed
#      on exactly the two container types that matter most.
#
# Every step is conditional on the environment that asks for it, so the same
# script is correct in the webserver, the daemon, the code location, the run
# worker and the ingest job despite those needing different subsets of it.
set -euo pipefail

: "${APP_HOME:=/opt/etl}"
: "${DBT_LOG_PATH:=/tmp/dbt/logs}"

# ---------------------------------------------------------------------------
# Entra token as the Postgres password.
#
# Skipped when POSTGRES_PASSWORD is already set, so a password-based Postgres
# (a scratch deployment, or a local run of these images) keeps working without
# a code change.
# ---------------------------------------------------------------------------
if [ "${POSTGRES_ENTRA_AUTH:-0}" = "1" ] && [ -z "${POSTGRES_PASSWORD:-}" ]; then
  POSTGRES_PASSWORD="$(python "$(dirname "$0")/entra_pg_token.py")"
  export POSTGRES_PASSWORD
  # Tokens last about an hour. Every process this entrypoint starts is either
  # short-lived (a run worker, an ingest job) or holds pooled connections that
  # were authenticated at open time, so a single mint at start is enough. A
  # long-running process that reconnects after expiry would need a refresh; the
  # webserver and daemon reach Postgres through dagster-postgres[azure], which
  # does its own refreshing and never reads this variable.
  unset POSTGRES_ENTRA_AUTH
fi

# ---------------------------------------------------------------------------
# Dagster instance config. Only the images that run a Dagster process have one.
# ---------------------------------------------------------------------------
if [ -n "${DAGSTER_HOME:-}" ] && [ -f "${APP_HOME}/dagster.azure.yaml" ]; then
  mkdir -p "${DAGSTER_HOME}"
  cp "${APP_HOME}/dagster.azure.yaml" "${DAGSTER_HOME}/dagster.yaml"
fi

# dbt writes logs here. The image creates it, but a mounted /tmp would hide it.
mkdir -p "${DBT_LOG_PATH}"

exec "$@"
