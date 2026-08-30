# Convenience targets. Every one is a thin wrapper over a docker compose command
# that the README also spells out in full, so make is never required.

DBT := dbt --project-dir /opt/etl/dbt/retail --profiles-dir /opt/etl/dbt/retail
COMPOSE := docker compose

# One-liner used by the `libs` target. Kept here so the recipe stays readable.
LIBS_SCRIPT := import boto3, psycopg2, pandas, pyarrow, sqlalchemy; \
print('boto3     ', boto3.__version__); \
print('psycopg2  ', psycopg2.__version__.split()[0]); \
print('pandas    ', pandas.__version__); \
print('pyarrow   ', pyarrow.__version__); \
print('sqlalchemy', sqlalchemy.__version__)

.DEFAULT_GOAL := help
.PHONY: help up up-core down logs build run dbt-build dbt-warn-error dbt-docs \
        check-sftp faker psql psql-source libs data lock guard clean

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

up:  ## Build and start everything, including the option 4/5 targets
	$(COMPOSE) up -d --build
	@echo "Dagster UI: http://localhost:$${DAGSTER_PORT:-3000}"

up-core:  ## Start only the SFTP pipeline, without the alternative sources
	$(COMPOSE) up -d --build postgres sftp app
	@echo "Dagster UI: http://localhost:$${DAGSTER_PORT:-3000}"

down:  ## Stop the stack, keeping volumes
	$(COMPOSE) down

build:  ## Rebuild the application image
	$(COMPOSE) build app

logs:  ## Follow the application logs
	$(COMPOSE) logs -f app

run:  ## Run the full pipeline: SFTP extraction through to dbt marts
	$(COMPOSE) exec app dagster job execute -m pipeline.definitions -j retail_pipeline

check-sftp:  ## Verify SFTP connectivity without moving any data
	$(COMPOSE) exec app /opt/venv/ingest/bin/python -m ingest.run_sftp_sync --check

dbt-build:  ## Run dbt: models plus tests. Succeeds with 13 warnings.
	$(COMPOSE) exec app $(DBT) build

dbt-warn-error:  ## Same run with warnings promoted to errors. Expected to fail.
	$(COMPOSE) exec app $(DBT) build --warn-error

dbt-docs:  ## Generate the dbt documentation site inside the container
	$(COMPOSE) exec app $(DBT) docs generate

faker:  ## Generate synthetic data. Override rows: make faker COUNT=500000
	$(COMPOSE) exec app /opt/venv/ingest/bin/python -m ingest.run_faker_sync \
		--count $(or $(COUNT),10000)

psql:  ## Open a psql shell against the warehouse
	$(COMPOSE) exec postgres psql -U $${POSTGRES_USER:-etl} -d $${POSTGRES_DB:-retail}

psql-source:  ## Open a psql shell against the CDC source database (option 5)
	$(COMPOSE) exec postgres-source psql -U $${CDC_SOURCE_USER:-cdc} -d $${CDC_SOURCE_DB:-shop}

libs:  ## Show the libraries available for building options 3, 4 and 5 offline
	$(COMPOSE) exec app /opt/venv/ingest/bin/python -c "$(LIBS_SCRIPT)"

data:  ## Regenerate the sample CSV files and re-assert the defect counts
	python scripts/generate_retail_data.py

lock:  ## Regenerate the hash-pinned dependency lock files
	./scripts/lock_requirements.sh

guard:  ## Fail if any agent instruction file is tracked by git
	python scripts/check_no_agent_files.py

clean:  ## Stop the stack and delete its volumes. Destroys all warehouse data.
	$(COMPOSE) down --volumes
