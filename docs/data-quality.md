# Data quality: the seeded defects

The sample retail data carries thirteen deliberate defects. Every one is caught
by a dbt test, every one of those tests is set to **warn** rather than error, and
the pipeline therefore completes successfully while reporting all thirteen.

That is the behaviour this project exists to demonstrate. A pipeline that halts
on the first imperfect row is not much use against real source data; a pipeline
that silently swallows problems is worse. Warning is the middle position: the
data lands, the marts get built, and the problems are recorded rather than
hidden.

## What a run looks like

```
Done. PASS=52 WARN=13 ERROR=0 SKIP=0 NO-OP=0 TOTAL=65
```

Exit code `0`. Thirteen warnings, no errors.

## The defect catalogue

Each defect has a `DQ-nn` identifier used in three places: the injection site in
[`scripts/generate_retail_data.py`](../scripts/generate_retail_data.py), the test
name in the dbt schema YAML, and this table. A warning in the dbt output can
therefore be traced back to the exact line of code that created it.

| ID | Entity | Defect | Rows | dbt test | Severity |
|----|--------|--------|-----:|----------|----------|
| DQ-01 | customers | Duplicated `customer_id` | 2 | `dq_01_customer_id_is_unique` | warn |
| DQ-02 | customers | Missing `email` | 4 | `dq_02_customer_email_is_present` | warn |
| DQ-03 | customers | `country` as `usa` / `USA` / `Usa` / `United States` | 4 | `dq_03_customer_country_is_iso_alpha2` | warn |
| DQ-04 | customers | `signup_date` in the future | 1 | `dq_04_customer_signup_date_not_in_future` | warn |
| DQ-05 | products | Negative `unit_price` | 1 | `dq_05_product_unit_price_is_not_negative` | warn |
| DQ-06 | products | Missing `category` | 3 | `dq_06_product_category_is_present` | warn |
| DQ-07 | orders | `customer_id` with no matching customer | 5 | `dq_07_order_customer_exists` | warn |
| DQ-08 | orders | `status` outside the vocabulary | 4 | `dq_08_order_status_is_known` | warn |
| DQ-09 | orders | Duplicated `order_id` | 1 | `dq_09_order_id_is_unique` | warn |
| DQ-10 | orders | Missing `order_date` | 2 | `dq_10_order_date_is_present` | warn |
| DQ-11 | order_items | `quantity` of `0` and `-2` | 2 | `dq_11_order_item_quantity_is_positive` | warn |
| DQ-12 | order_items | `line_total` disagrees with the arithmetic | 6 | `dq_12_order_item_line_total_matches_arithmetic` | warn |
| DQ-13 | order_items | `order_id` with no matching order | 4 | `dq_13_order_item_order_exists` | warn |
| — | stores | *(none — control group)* | 0 | `control_store_*` | **error** |

39 defective rows across 13 tests.

Two of these are worth a closer look:

**DQ-08** includes `"shipped "` — valid apart from a trailing space. It is
indistinguishable from `"shipped"` in almost every viewer, survives visual
review indefinitely, and silently splits a `GROUP BY` in two. The other three
variants are `SHIPPED`, `Delivered` and a genuinely unknown `unknown`.

**DQ-12** is arithmetic drift: `line_total` does not equal
`quantity × unit_price × (1 - discount)`. Nothing about these rows looks wrong
in isolation. Only the cross-column relationship gives it away, which is why the
staging model materialises `expected_line_total` alongside the reported value.

## The control group

`stores` carries no defects at all, and its tests run at **error** severity. They
pass.

This is deliberate. Without it, "13 warnings and exit 0" is equally consistent
with the tests being switched off. The passing error-severity tests show that
severity is a per-test decision being exercised in both directions.

The marts tests are the second half of that argument: 30 error-severity tests run
against the cleaned models and all pass, which is what confirms the cleaning
logic actually resolved the defects rather than merely hiding them.

## Proving the tests are real

```bash
docker compose exec app dbt build --project-dir /opt/etl/dbt/retail --warn-error
```

`--warn-error` promotes every warning to an error:

```
Done. PASS=23 WARN=0 ERROR=13 SKIP=29 NO-OP=0 TOTAL=65
```

Exit code `1`. The same thirteen findings, now fatal, and 29 downstream nodes
skipped because their parents failed. Run it both ways and the difference is
entirely attributable to the severity setting.

## Where the failing rows go

The project sets `store_failures: true`, so every test writes its failing rows to
a table in `retail_dq_failures`. The warning tells you how many; these tables
tell you which.

```sql
select * from retail_dq_failures.dq_08_order_status_is_known;
select * from retail_dq_failures.dq_12_order_item_line_total_matches_arithmetic;
```

The audit schema holds one table per test, including the passing ones (empty).

## How the layers treat defects differently

**Staging preserves them.** `stg_customers` still has 202 rows with 200 distinct
ids; `stg_orders` still has `"shipped "` with its trailing space. Cleaning here
would leave the tests with nothing to find, and would make the raw feed
unauditable.

**Marts resolve them.** `dim_customers` has 200 rows, one per customer.
`fct_orders` has a normalised `status` alongside the original in `status_raw`.
`dim_products` nulls the negative price but keeps it in `unit_price_raw`.

The corrections are additive: every model that changes a value keeps the original
in a `_raw` column or flags the row with a boolean. Nothing is quietly
overwritten.

**Aggregates exclude them, and say so.** `agg_daily_store_sales` drops orders
with no date, an unknown status, or a missing customer — and carries
`excluded_missing_date`, `excluded_orphaned_customer` and
`excluded_unknown_status` on every row, so the size of what was dropped travels
with the numbers instead of having to be taken on trust.

## Regenerating the data

```bash
python scripts/generate_retail_data.py
```

Deterministic: a fixed seed, no third-party dependencies, and the script asserts
all thirteen defect counts against the numbers in this table before it exits. If
the generator is changed in a way that moves a count, it fails rather than
letting this document drift out of date.

## Changing a severity

Project-wide default, in `dbt_project.yml`:

```yaml
data_tests:
  +severity: warn
```

Per test, in the schema YAML:

```yaml
- unique:
    config:
      severity: error
```

A useful middle setting is `error_if` / `warn_if`, which lets a small number of
bad rows warn while a large number fails:

```yaml
- not_null:
    config:
      severity: error
      error_if: ">100"
      warn_if: ">0"
```

That is often the right production posture: tolerate the long tail of
imperfection, stop the line when something breaks at scale.
