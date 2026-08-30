# Getting data in, locally

This project ingests over SFTP because file transfer is what most retail and
finance integrations still look like. But SFTP is one option among many, and it
is not the right one for every kind of testing.

This is a survey of ways to feed a pipeline entirely from your own machine, with
what each is actually good for.

Options 1 and 2 are implemented. **Options 3, 4 and 5 have their infrastructure
running and every library installed, but no connection code** -- building those
is left as an exercise, and is expected to be done offline against what is
already in the image. The rest are sketched with enough detail to stand up in an
afternoon.

## Choosing by what you are testing

Different goals want different sources. The most common mistake is reaching for
the most realistic option when a synthetic one would isolate the problem better.

| If you are testing… | Reach for | Why |
|---|---|---|
| Connector and parser behaviour | SFTP, S3/MinIO, format-variety harness | Exercises real transport, globbing, encodings and malformed input |
| Transformation logic | Small curated fixtures with seeded defects | Deterministic, reviewable, fast; you can assert exact row counts |
| Scale and performance | `source-faker`, TPC-H/TPC-DS, open Parquet | Volume on demand without hand-authoring anything |
| Incremental and CDC correctness | Postgres logical replication, dated file batches | The only way to exercise state between runs |
| Data-quality detection | Curated fixtures with a documented defect catalogue | You know the answer, so you can verify the detector |
| Schema evolution | Any source you control, changed between runs | Add, drop and retype columns and watch what breaks |

For model testing and training specifically, the split that matters most is
**deterministic small fixtures** for anything where you need to check a specific
answer, and **synthetic volume** for anything where you need scale. Real-world
open data sits between them: realistic, but you do not know the ground truth.

---

## 1. SFTP — *implemented here*

A stock `atmoz/sftp` container serving CSV files from a read-only bind mount,
read by `source-sftp-bulk`.

Good for the things file-based integration actually breaks on: glob patterns,
multiple files per stream, partial batches, encoding, headers, and the file
metadata (`_ab_source_file_url`, `_ab_source_file_last_modified`) that
incremental sync depends on.

Cost to stand up: one compose service. See
[`docker-compose.yml`](../docker-compose.yml) and
[`ingest/run_sftp_sync.py`](../ingest/run_sftp_sync.py).

## 2. `source-faker` — *implemented here*

Synthetic records generated in-process. No server, no files, no network.

This is the one to reach for when you need volume. `--count 500000` is a
one-word change, the seed makes it reproducible, and there is nothing to stand
up first. That combination is hard to beat for load-testing a warehouse, filling
a cache, or generating training rows where the content matters less than the
shape.

```bash
docker compose exec app /opt/venv/ingest/bin/python -m ingest.run_faker_sync --count 500000
```

See [`ingest/run_faker_sync.py`](../ingest/run_faker_sync.py).

---

## Options 3, 4 and 5 — build these yourself

The three options below are **deliberately not implemented**. The infrastructure
is running and seeded, every library needed is already installed in the image,
and the connection code is left as the exercise.

That is the point: this repository is used for model testing, and building a
working ingestion path against a live endpoint — offline, from the libraries at
hand — is a more useful task than reading someone else's finished version of it.

Everything needed is present in the image. **No downloads are required and none
will succeed**; all dependencies are installed at image build time, and the
container is expected to run without network access.

### What is installed and where

The ingest virtualenv at `/opt/venv/ingest` holds everything these three paths
need. Use that interpreter, not the orchestrator one:

```bash
/opt/venv/ingest/bin/python -c "import boto3, psycopg2, pandas, pyarrow; print('all present')"
```

| Library | Version | Use |
|---|---|---|
| `boto3` / `botocore` | 1.43.83 | S3 API client — option 4 |
| `psycopg2-binary` | 2.9.12 | Postgres, including `psycopg2.extras.LogicalReplicationConnection` — option 5 |
| `sqlalchemy` | 2.0.43 | Engine and `DataFrame.to_sql` for writing results |
| `pandas` | bundled with PyAirbyte | CSV / JSON / Parquet readers — options 3, 4 |
| `pyarrow` | bundled with PyAirbyte | Parquet engine |
| `dagster-pipes` | 1.13.20 | Report logs and materializations back to Dagster |

`airbyte` (PyAirbyte) is also present, but see the note on broken connector
packaging below before reaching for it.

### Where to write results

Follow what the SFTP path does, so everything in the warehouse has a consistent
shape regardless of how it arrived. Each landed table carries:

```
_airbyte_raw_id         per-record surrogate key
_airbyte_extracted_at   when the run read the record
_ab_source_file_url     where it came from (path, S3 key, or LSN)
```

Land each option in its own schema — `local_files`, `s3_raw`, `cdc_raw` — so it
cannot be confused with the retail data. Connection details for the warehouse
are in `POSTGRES_*`; see `ingest/cache.py` for how the SFTP path reads them.

To surface a path in Dagster, follow the pattern in
[`pipeline/assets/sftp_ingest.py`](../pipeline/assets/sftp_ingest.py): a
`@multi_asset` that runs the ingest interpreter through `PipesSubprocessClient`.
[`ingest/pipes.py`](../ingest/pipes.py) already wraps the reporting side and
works standalone too.

### A trap worth knowing about first

**`airbyte-source-file` and `airbyte-source-s3` cannot be installed from PyPI.**
Every published version declares `smart-open[...]==<the connector's own
version>` — the release tooling substituted the connector version into an
unrelated dependency's pin, and no such `smart-open` release exists:

```
Because there is no version of smart-open[s3]==4.15.20 and
airbyte-source-s3==4.15.20 depends on smart-open[s3]==4.15.20, we can
conclude that airbyte-source-s3==4.15.20 cannot be used.
```

Verified against `airbyte-source-file` 0.5.42–0.6.0 and the newest 25 releases of
`airbyte-source-s3`. Both are fine as Docker images; only the PyPI packaging is
broken. Do not spend time trying to install them — read the sources directly with
`pandas` and `boto3` instead. For options 3 and 4 that is arguably the better
demonstration anyway: the point of reading local files is to take the transport
out of the loop, and the point of MinIO is to exercise S3 semantics, neither of
which needs a connector.

---

## 3. Local filesystem

No transport at all: a bind-mounted directory read straight into Postgres. The
fastest edit-run cycle available, and the right default when the thing under test
is a transformation rather than an integration.

**Already running.** `./data/sftp/retail` is mounted read-only inside the app
container at `/data/local`, and `LOCAL_FILES_PATH` points there.

```bash
docker compose exec app ls /data/local
```

**Libraries:** `pandas` for the readers, `pyarrow` behind `read_parquet`,
`sqlalchemy` to write.

Worth extending into a small version of the format-variety harness (option 11):
re-emit the same records as CSV, JSONL and Parquet, read all three in one run,
and compare. A value that survives one encoding but not another shows up
immediately as a difference between tables that ought to be identical.

## 4. MinIO — S3-compatible object storage

MinIO speaks the S3 API, so this exercises what actually differs between a
filesystem and an object store: an endpoint and credentials, prefix-based
organisation, paginated listing, and per-object reads. The same code runs against
real S3 by changing the endpoint and credentials.

**Already running and seeded.** The seven retail CSVs are in the bucket:

```bash
docker compose exec app /opt/venv/ingest/bin/python - <<'PY'
import boto3, os
from botocore.client import Config
s3 = boto3.client(
    "s3",
    endpoint_url=os.environ["S3_ENDPOINT_URL"],
    aws_access_key_id=os.environ["S3_ACCESS_KEY"],
    aws_secret_access_key=os.environ["S3_SECRET_KEY"],
    config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
)
print([o["Key"] for o in s3.list_objects_v2(Bucket=os.environ["S3_BUCKET"])["Contents"]])
PY
```

Environment: `S3_ENDPOINT_URL=http://minio:9000`, `S3_ACCESS_KEY`,
`S3_SECRET_KEY`, `S3_BUCKET=etl-poc`, `S3_PREFIX=retail/`. Console at
<http://localhost:9001>.

**Libraries:** `boto3` with `botocore.client.Config`.

Two things that will bite:

- **`addressing_style: "path"` is required.** The default virtual-host style
  resolves `bucket.minio`, which does not exist on the compose network.
- **Paginate the listing.** A bare `list_objects_v2` silently truncates at 1000
  keys. Use `get_paginator("list_objects_v2")`. You will not notice in a
  seven-object bucket and you will certainly notice in production.

## 5. Postgres logical replication (CDC)

The only option here that exercises state between runs. A run returns *what
changed since the last run* rather than the current contents of a table — which
is why nothing else in this repository will catch a broken incremental cursor or
a snapshot-to-stream handoff that drops rows in the gap.

**Already running.** A second Postgres, separate from the warehouse, started with
`wal_level=logical` and seeded with `customers` and `orders`:

```bash
docker compose exec postgres-source psql -U cdc -d shop -c "\dt"
```

Environment: `CDC_SOURCE_HOST=postgres-source`, `CDC_SOURCE_DB=shop`,
`CDC_SOURCE_USER=cdc`, `CDC_SOURCE_PASSWORD`. Also reachable on host port 5434.

Both tables are set to `REPLICA IDENTITY FULL`, so `UPDATE` and `DELETE` emit the
whole old row rather than just the primary key — without it a delete tells you an
id vanished but not what it contained.

**Libraries:** `psycopg2.extras.LogicalReplicationConnection`,
`cursor.create_replication_slot`, `cursor.start_replication`,
`cursor.consume_stream`.

Use the `test_decoding` output plugin. It ships with Postgres and emits readable
text like:

```
table public.customers: INSERT: id[integer]:5 email[text]:'linus@example.com'
```

`pgoutput` is also available and is what production uses, but it is binary and
needs a protocol decoder. `wal2json` is *not* installed.

The shape of the task:

1. Create the slot — **before** the snapshot, since creating it is what starts
   change retention. Changes made in between are otherwise lost.
2. Snapshot the current table contents as the initial load.
3. On later runs, consume the slot and receive only what changed.
4. Call `send_feedback(flush_lsn=...)` on each message. That acknowledgement is
   what advances the slot; skip it and every run replays the same changes.

Two traps that cost real time:

- **`consume_stream` blocks forever by default.** It is built for a long-lived
  streaming consumer, not a batch run. `keepalive_interval` does not make it
  return when the stream goes idle. For a run that must terminate, raise
  `psycopg2.extras.StopReplication` from your consumer once you have caught up
  (compare against `pg_current_wal_lsn()`), or use `read_message()` in a loop
  with your own idle timeout.
- **An unconsumed slot retains WAL indefinitely** and will eventually fill the
  source disk. This is the classic production CDC outage. Watch it with:

  ```sql
  SELECT slot_name, active,
         pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
  FROM pg_replication_slots;
  ```

To generate changes to capture:

```bash
docker compose exec postgres-source psql -U cdc -d shop -c "
  INSERT INTO customers (email, full_name, city) VALUES ('linus@example.com','Linus Torvalds','Helsinki');
  UPDATE customers SET city = 'Cambridge' WHERE email = 'ada@example.com';
  DELETE FROM orders WHERE id = 3;"
```

Airbyte's own `source-postgres` wraps Debezium over this same mechanism. It is a
Java connector, not on PyPI at all, and running it would mean giving the app
container access to the Docker socket — hence talking to the replication protocol
directly.

---

## 6. Mock REST API

`json-server`, WireMock or a small FastAPI app, read by a declarative low-code
connector or a custom one.

The value is in the failure modes you can script deliberately: cursor and
offset pagination, token refresh mid-sync, 429 with `Retry-After`, a 500 on page
7 of 20, a field that changes type between pages. These are difficult to
provoke against a real API and are exactly where connectors break.

## 7. Kafka or Redpanda

Redpanda is a single container and speaks the Kafka protocol, so it is the
lighter way to get a local broker.

Reach for it when the workload is genuinely event-shaped — when ordering,
partitioning, consumer groups and at-least-once redelivery are part of what you
are testing. If you only need "many rows", `source-faker` is far less work.

## 8. DuckDB TPC-H / TPC-DS

```sql
INSTALL tpch; LOAD tpch;
CALL dbt_tpch(sf=10);   -- ~60M rows, generated in seconds
```

Benchmark data at any scale factor, with a published schema, a known
distribution, and 22 reference queries with known-correct answers.

This is the best source of *large structured data where you know the right
answer*. Synthetic generators give you volume; TPC gives you volume plus a
ground truth you can assert against. For performance work and for validating
that a transformation is correct at scale, it is hard to beat.

## 9. Open public datasets

- **NYC TLC trip records** — monthly Parquet, hundreds of millions of rows,
  genuinely messy (negative fares, impossible timestamps, coordinates in the
  Atlantic). Excellent for data-quality work precisely because the defects are
  real rather than seeded.
- **GDELT** — very large, wide, frequently updated.
- **Hugging Face `datasets`** — a huge catalogue with clear licensing, which
  matters if the output is going anywhere public.
- **data.gov / EU Open Data** — domain-specific and usually small.

Real-world messiness without a licensing problem. The trade-off is that you do
not know the ground truth, so these are poor for verifying a detector and good
for discovering what a detector misses.

## 10. Synthetic generators

- **Faker / Mimesis** — realistic-looking values, no statistical fidelity.
  Right when you need shape and volume, wrong when distributions matter.
- **SDV (Synthetic Data Vault)** — fits a model to a real sample and generates
  new rows with similar distributions and correlations. This is the one for
  "we cannot publish the real data but the statistics need to survive."
- **Hand-written generators** — like
  [`scripts/generate_retail_data.py`](../scripts/generate_retail_data.py) here.
  More work, but total control: you decide exactly which defects exist and how
  many, which is what makes the results assertable.

The choice is really about whether you need to *know* the answer. A hand-written
generator with a documented defect catalogue is the only option that lets you
write `assert warnings == 13`.

## 11. Format-variety harness

Emit the same logical records as CSV, TSV, JSONL, Parquet, Avro, Excel,
fixed-width and gzipped variants, then run each through the same pipeline.

This tests the parser rather than the semantics, and it finds a specific class of
bug that nothing else on this list will: type inference differing between
formats, nulls surviving a Parquet round-trip but not a CSV one, Excel silently
coercing a long numeric id to a float, BOM handling, and CRLF versus LF.

Cheap to build — one generator, many writers — and disproportionately effective.

## 12. Other file transports

**WebDAV**, **SMB/CIFS** and **rsync over SSH** all have connectors or trivial
mounts, and behave differently from SFTP in ways that matter: locking semantics,
partial-write visibility, and whether a file appears in a listing before it has
finished being written. That last one is the source of a genuinely common
production bug — reading a file mid-upload — and is easy to reproduce locally
once you have the transport running.

---

## A note on determinism

Whatever you pick, the property that matters most for testing is that it produces
the same thing twice. This project gets there by seeding the generator, pinning
every dependency by hash, and asserting the defect counts in the generator
itself.

Without that, a failing test tells you something changed but not what — and the
first thing you will suspect is the pipeline, when it was the data.
