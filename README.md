# ETL-POC

An end-to-end ELT pipeline that runs on your machine: **SFTP → PyAirbyte →
Postgres → dbt**, orchestrated by **Dagster**.

The sample retail data contains thirteen deliberate defects. Every one is caught
by a dbt test set to **warn rather than fail**, so the pipeline completes
successfully and reports them. That behaviour is the point of the project.

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

```
┌─────────────────┐
│  SFTP server    │  7 CSV files, read-only
└────────┬────────┘
         │  PyAirbyte  ·  source-sftp-bulk
         ▼
┌─────────────────────────────────────────────┐
│  Postgres                                   │
│    airbyte_raw.*        raw, all text       │
│    retail_staging.*     typed, defects kept │
│    retail_marts.*       cleaned             │
│    retail_dq_failures.* failing rows        │
└─────────────────────────────────────────────┘
         ▲                  ▲
         │       dbt        │
         └──────────────────┘

     Dagster orchestrates both halves as one asset graph.
```

There is **no Airbyte platform deployment** here — no `abctl`, no Kubernetes, no
Airbyte web UI. PyAirbyte runs the connectors as an embedded library, which is
what keeps the application side down to a single image.

## Quickstart

Requires Docker with Compose. Nothing else — no local Python, no dbt install.

```bash
docker compose up -d --build
```

First build takes a few minutes; it compiles two virtualenvs and bakes the
Airbyte connectors in. Then open **<http://localhost:3000>**.

In the Dagster UI: **Assets → View global asset lineage → Materialize all**.

Or from the command line:

```bash
docker compose exec app dagster job execute -m pipeline.definitions -j retail_pipeline
```

Either way the run succeeds, and ends with:

```
Done. PASS=52 WARN=13 ERROR=0 SKIP=0 NO-OP=0 TOTAL=65
```

## What to look at

**The thirteen warnings.** Each is tagged `DQ-nn` and traceable to the line that
created it. [`docs/data-quality.md`](docs/data-quality.md) has the full
catalogue.

**The lineage graph.** Extraction and transformation appear as one connected
DAG, not two islands — `airbyte_raw/customers → staging/stg_customers →
marts/dim_customers → marts/fct_orders → marts/agg_daily_store_sales`.

**The asset checks.** All 54 dbt tests surface as Dagster asset checks, so
warnings attach to the asset they concern.

**Proof the tests are real:**

```bash
docker compose exec app dbt build --project-dir /opt/etl/dbt/retail --warn-error
```

Same thirteen findings, now `ERROR=13` and exit code 1. The only difference is
the severity setting.

**The marts:**

```bash
docker compose exec postgres psql -U etl -d retail \
  -c "select * from retail_marts.agg_daily_store_sales order by 1,2 limit 10;"
```

**The failing rows** — the warnings say how many, these tables say which:

```bash
docker compose exec postgres psql -U etl -d retail \
  -c "select * from retail_dq_failures.dq_08_order_status_is_known;"
```

## Synthetic data on demand

A second ingestion path with no server, no files and no network — useful when you
need volume rather than realism:

```bash
docker compose exec app /opt/venv/ingest/bin/python -m ingest.run_faker_sync --count 500000
```

## Other ways to ingest data locally

[`docs/local-ingestion-options.md`](docs/local-ingestion-options.md) surveys
twelve ways to feed a pipeline entirely from your own machine, and which one to
reach for depending on whether you are testing connector behaviour,
transformation logic, scale, incremental correctness, or data-quality detection.

Three of them ship as an **exercise rather than an implementation**:

| Option | Target | Status |
|---|---|---|
| 3. Local filesystem | `/data/local` in the app container | running, no reader |
| 4. MinIO (S3 API) | `http://minio:9000`, bucket `etl-poc`, seeded | running, no reader |
| 5. Postgres CDC | `postgres-source`, `wal_level=logical`, seeded | running, no reader |

The infrastructure is up and seeded and every library needed is installed in the
image — `boto3`, `psycopg2` with `LogicalReplicationConnection`, `pandas`,
`pyarrow`, `sqlalchemy`. The connection code is not written, on purpose: building
it offline against what is already there is the task.

```bash
docker compose exec app /opt/venv/ingest/bin/python -c "import boto3, psycopg2, pandas, pyarrow; print('ready')"
```

The doc names the libraries, the endpoints, the environment variables, and the
traps worth knowing before you start — including two Airbyte connectors that
cannot be installed from PyPI at all, and the `consume_stream` call that never
returns.

To run the core pipeline without those extra services:

```bash
docker compose up -d --build postgres sftp app
```

## Layout

```
data/sftp/retail/     the CSV files, served over SFTP
ingest/               PyAirbyte extraction (runs in its own virtualenv)
pipeline/             Dagster assets, resources and definitions
dbt/retail/           dbt project: staging -> marts, with the tests
scripts/              data generator, connector installer, lock and guard scripts
docs/                 architecture, data quality, ingestion options
```

## Design decisions

Three are worth knowing before reading the code:

**One image, two virtualenvs.** PyAirbyte and dbt/Dagster have genuinely
conflicting dependencies — `protobuf` 7 vs 6, `rich` 13 vs 15, and PyAirbyte
hard-pins `sqlalchemy==2.0.43`. They get separate virtualenvs inside the one
image and talk over Dagster Pipes. A process boundary, not a container boundary.

**Python 3.11, not by preference.** PyAirbyte needs `<3.13`, the sftp-bulk
connector needs `<3.12`. 3.11 is the only version that satisfies everything.

**Staging preserves defects; marts resolve them.** Cleaning in staging would
leave the tests with nothing to find. Every correction in the marts is additive —
the original survives in a `_raw` column or a boolean flag.

Full reasoning in [`docs/architecture.md`](docs/architecture.md).

## Reproducibility

Nothing resolves at build time. The base image and every compose image are pinned
by `sha256` digest, `apt` packages by exact version, and Python dependencies come
from hash-pinned lock files installed with `--require-hashes`. Airbyte connectors
are installed from an explicit `pip_url` rather than the connector registry.

Regenerate the locks deliberately:

```bash
./scripts/lock_requirements.sh
```

## Regenerating the sample data

```bash
python scripts/generate_retail_data.py
```

Deterministic, standard library only. The script asserts all thirteen defect
counts before exiting, so the data and the documentation cannot drift apart.

## Notes

The credentials in `docker-compose.yml` are throwaway values for containers on a
private network. This repository has no secret-management story and should not be
used as a template for one.

Telemetry is off: PyAirbyte's via `DO_NOT_TRACK`, Dagster's in `dagster.yaml`.

## License

Apache 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

The sample data is synthetic and describes no real person or business.
