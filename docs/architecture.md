# Architecture

```
┌─────────────────┐
│  SFTP server    │  atmoz/sftp -- 7 CSV files, read-only mount
│  /upload/retail │
└────────┬────────┘
         │  source-sftp-bulk (PyAirbyte, embedded)
         ▼
┌─────────────────────────────────────────────┐
│  Postgres                                   │
│    airbyte_raw.*        raw, all text       │
│    retail_staging.*     typed, defects kept │
│    retail_marts.*       cleaned             │
│    retail_dq_failures.* failing rows        │
└─────────────────────────────────────────────┘
         ▲                  ▲
         │  dbt             │
         └──────────────────┘

    Dagster orchestrates both halves as one asset graph.
```

Three containers for the core pipeline: one built here, two stock upstream
images. Two more (MinIO and a CDC Postgres) back the ingestion exercises in
docs/local-ingestion-options.md and are not needed to run the pipeline.

## Why PyAirbyte instead of the Airbyte platform

Airbyte OSS is a distributed application — a control plane, a workload launcher,
temporal, its own database, and `abctl` provisioning a local Kubernetes cluster
to hold it. That is a reasonable thing to run in production and an unreasonable
thing to ask of someone evaluating a pipeline.

PyAirbyte runs the same connectors as a Python library. `get_source()` installs
the connector into a virtualenv and speaks the Airbyte protocol to it over a
subprocess. Same connector code, same config schema, no platform.

The trade-off is real and worth stating: there is no connection UI, no scheduler,
no connector registry sync, and no built-in state store beyond what the cache
provides. For a pipeline that Dagster is already orchestrating, none of that is
missed — Dagster supplies the scheduling and observability that the Airbyte
platform would otherwise provide.

## Why two virtualenvs in one image

The requirement was a single image so PyAirbyte could be used. It is a single
image. But PyAirbyte and dbt/Dagster do not share a virtualenv inside it, because
their dependency sets genuinely conflict:

| Package | Ingest venv | Orchestrator venv |
|---|---|---|
| `protobuf` | 7.36.0 | 6.33.6 |
| `rich` | 13.9.4 | 15.0.0 |
| `sqlalchemy` | 2.0.43 (hard-pinned by PyAirbyte) | 2.0.52 |

These are not near misses. `protobuf` is a major version apart, and PyAirbyte
pins `sqlalchemy` and `rich` with `==` and `<14` respectively. A single
resolution would mean downgrading something load-bearing on one side.

So each half gets its own virtualenv and its own independently compiled lock
file, and Dagster invokes the ingest interpreter as a subprocess. That is a
process boundary, not a container boundary.

PyAirbyte also brings in `snowflake-connector-python`, `google-cloud-bigquery`
and `duckdb` whether you want them or not — it ships cache backends for all five
warehouses it supports and offers no extras to opt out. This project uses the
Postgres backend only; the rest sit unused in the ingest venv. Isolating them
there keeps them out of the environment dbt and Dagster run in.

### Dagster Pipes across the boundary

[`dagster-pipes`](https://docs.dagster.io/guides/build/external-pipelines) is the
zero-dependency client half of the Dagster protocol. The ingest venv has it; it
does not have Dagster. The subprocess streams logs and reports asset
materializations with real metadata — row counts, destination tables, which
source files contributed — and they appear in the Dagster UI as if the work had
run in-process.

[`ingest/pipes.py`](../ingest/pipes.py) wraps it so the same scripts stay usable
standalone, which is the fastest way to debug a connection problem:

```bash
docker compose exec app /opt/venv/ingest/bin/python -m ingest.run_sftp_sync --check
```

## Why Python 3.11

Not a preference — the only version that satisfies everything:

| Package | Requires |
|---|---|
| `airbyte` (PyAirbyte) | `>=3.10,<3.13` |
| `airbyte-source-sftp-bulk` | `>=3.10,<3.12` |
| `dagster-dbt` | `<3.14` |

The intersection is 3.10 and 3.11. 3.11 is the newer of the two.

A related pin: `dagster-dbt` requires `dbt-core<1.12`, so dbt is held on the 1.11
line even though 1.12 is released. Both constraints are recorded in
[`requirements/orchestrator.txt`](../requirements/orchestrator.txt).

## How the lineage graph connects

dagster-dbt derives the asset key for a dbt **source** as
`[source_name, table_name]`. The dbt source is named `airbyte_raw`, so
`airbyte_raw.customers` becomes `AssetKey(["airbyte_raw", "customers"])`.

The ingest assets emit exactly those keys. Neither side references the other; they
agree because [`ingest/streams.py`](../ingest/streams.py) — standard library only,
imported by both virtualenvs — is the single definition of what the streams are.

The result is one connected graph: `airbyte_raw/customers → staging/stg_customers
→ marts/dim_customers → marts/fct_orders → marts/agg_daily_store_sales`.

dbt tests become Dagster **asset checks** (54 of them), so a warn-severity test
shows up as a warning attached to the asset it concerns rather than buried in run
logs.

## Reproducibility

Nothing resolves at build time:

- Base image pinned by `sha256` digest, not tag.
- `apt` packages pinned to exact Debian point releases.
- `pip`, `setuptools`, `wheel` pinned before they install anything else.
- Python dependencies installed from hash-pinned `requirements/*.lock` with
  `--require-hashes`, which also implies `--no-deps`. Every transitive package is
  fixed and verified.
- Airbyte connectors installed with an explicit `pip_url` rather than resolved
  from the connector registry.
- `dbt_utils` pinned exactly, with `package-lock.yml` committed.
- Compose images pinned by digest.
- The application source itself is cloned from the published repository at a
  pinned commit and verified after checkout, rather than copied from the build
  context.

Locks are regenerated deliberately with
[`scripts/lock_requirements.sh`](../scripts/lock_requirements.sh), which runs
`uv pip compile` inside the same digest-pinned base image the Dockerfile uses, so
the locks match the interpreter that installs them.

## Offline operation

Because every download happens during the build, the container runs with no
internet access. `docker-compose.offline.yml` marks the network `internal` to
make that enforceable rather than merely claimed.

Two things had to change to get there, and both are worth knowing about:

- **`AIRBYTE_OFFLINE_MODE=1`.** PyAirbyte contacts the Airbyte connector registry
  on every `get_source()` call, even for a connector already installed locally,
  and raises `AirbyteConnectorRegistryError` when it cannot reach it. The
  connector virtualenvs are baked in and every version is pinned explicitly, so
  the registry has nothing to tell us.

- **No `DbtProject.prepare_if_dev()`.** `dagster dev` sets `DAGSTER_IS_DEV_CLI`,
  so that call ran on every container start and re-ran `dbt deps` — which needs
  the network, and which *empties* `dbt_packages/` when it cannot reach the
  package hub. The image already resolves packages and compiles the manifest at
  build time. It would earn its place if the project directory were bind-mounted
  for live editing; it is not.

### Keeping the source pin honest

The pin has to stay in step with the source, which
[`scripts/pin_source_commit.sh`](../scripts/pin_source_commit.sh) enforces in CI.

It treats a pin as current when the commit it names has the *same source tree* as
HEAD for every path the image copies, rather than requiring it to equal HEAD.
That is the property that actually matters — it is what makes the built image
identical — and it also resolves the ordering problem: the commit that updates
the pin touches only the Dockerfile, which is never copied into the image, so
pinning to HEAD before making that commit leaves the pin correct afterwards.

The one place this bites: pinned `apt` versions disappear from the Debian mirror
when a point release is superseded, and the build then fails. That is the
intended behaviour — a loud failure beats silent drift — and the Dockerfile
records the command to refresh them.

## Trade-offs taken

**SQLite for Dagster storage.** Run history lives in a named volume. Adequate for
a POC, and it avoids a second database dependency. Swap in `dagster-postgres` for
anything real.

**`write_strategy="replace"` on every sync.** Full refresh each run, which keeps
the demo predictable. Real incremental sync would use the connector's file
metadata cursor and `write_strategy="merge"`.

**Credentials in the compose file.** They are throwaway values for containers on
a private network, and stating that plainly is better than a secret-management
story that implies a security posture this repository does not have.

**The schedule is off by default.** A demo that starts firing jobs the moment
someone runs `docker compose up` is a surprise, not a feature. Enable it from the
Automation tab.
