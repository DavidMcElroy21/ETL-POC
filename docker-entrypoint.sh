#!/usr/bin/env bash
# Container entrypoint.
#
# Dagster reads its instance configuration from $DAGSTER_HOME/dagster.yaml, and
# DAGSTER_HOME is a named volume so run history survives a restart. Copying the
# config in on every start means edits to dagster.yaml take effect on the next
# `docker compose up` rather than only when the volume is first created.
set -euo pipefail

: "${DAGSTER_HOME:=/opt/dagster/home}"
: "${APP_HOME:=/opt/etl}"
: "${DBT_LOG_PATH:=/tmp/dbt/logs}"

mkdir -p "${DAGSTER_HOME}"
cp "${APP_HOME}/dagster.yaml" "${DAGSTER_HOME}/dagster.yaml"

# The image creates this owned by the runtime user, but a tmpfs or bind mount
# over /tmp would replace it. Recreating here keeps `dbt` runnable either way.
mkdir -p "${DBT_LOG_PATH}"

exec "$@"
