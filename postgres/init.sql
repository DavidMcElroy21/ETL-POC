-- Schemas the pipeline writes into.
--
-- PyAirbyte and dbt both create schemas on demand, but creating them here means
-- ownership and permissions are settled before the first sync rather than
-- depending on whichever process happens to arrive first.

-- Landing zone for raw extracted records. Written by PyAirbyte, read by dbt,
-- never modified by dbt.
CREATE SCHEMA IF NOT EXISTS airbyte_raw;

-- Synthetic data from source-faker, kept apart from the retail data so the two
-- can never be confused or accidentally joined.
CREATE SCHEMA IF NOT EXISTS airbyte_faker;

-- dbt output. The profile targets schema "retail" and dbt appends the per-layer
-- suffix configured in dbt_project.yml.
CREATE SCHEMA IF NOT EXISTS retail;
CREATE SCHEMA IF NOT EXISTS retail_staging;
CREATE SCHEMA IF NOT EXISTS retail_marts;

-- Rows that failed a dbt test, persisted by store_failures. This is the audit
-- trail behind each warning: the tests report counts, these tables hold the
-- offending rows.
CREATE SCHEMA IF NOT EXISTS retail_dq_failures;
