#!/usr/bin/env python3
"""Generate the synthetic retail CSV files that are served over SFTP.

The output is deterministic: a fixed seed and no third-party dependencies, so
regenerating the files reproduces them byte for byte. The row counts and the
per-defect counts asserted at the bottom of this module are the same numbers
quoted in docs/data-quality.md, and the dbt tests are written against them.

Defects are injected deliberately. Each is tagged with the DQ-nn identifier used
in docs/data-quality.md and in the dbt schema YAML, so a reader can trace a
warning in the dbt output back to the exact line of code that created it.

    python scripts/generate_retail_data.py [--out data/sftp/retail]
"""

from __future__ import annotations

import argparse
import csv
import random
from dataclasses import dataclass
from datetime import date, timedelta
from pathlib import Path

SEED = 20260115

# Two daily batches. The transactional entities are split across both, which is
# what proves the connector glob picks up more than one file per stream.
BATCH_DATES = (date(2026, 1, 15), date(2026, 1, 16))

DEFAULT_OUT = Path("data/sftp/retail")

N_CUSTOMERS = 200
N_PRODUCTS = 60
N_ORDERS = 800
ITEMS_PER_ORDER = (1, 5)

FIRST_NAMES = [
    "Aisha", "Brendan", "Camila", "Dmitri", "Elena", "Farid", "Grace", "Hugo",
    "Imani", "Jonas", "Keiko", "Liam", "Marisol", "Nikhil", "Olive", "Priya",
    "Quentin", "Rosa", "Samuel", "Tarek", "Ursula", "Viktor", "Wren", "Ximena",
    "Yusuf", "Zoe", "Anders", "Beatriz", "Cormac", "Delphine", "Ezra", "Freya",
]
LAST_NAMES = [
    "Abara", "Bergstrom", "Castellanos", "Dvorak", "Eriksen", "Fontaine",
    "Gallagher", "Haddad", "Ishikawa", "Jovanovic", "Kowalski", "Lindqvist",
    "Moreau", "Nakamura", "Okonkwo", "Pereira", "Quintero", "Rasmussen",
    "Silva", "Thibault", "Ueda", "Vasquez", "Whitfield", "Yilmaz", "Zambrano",
]
CITIES = [
    ("Portland", "US"), ("Austin", "US"), ("Chicago", "US"), ("Denver", "US"),
    ("Toronto", "CA"), ("Vancouver", "CA"), ("Manchester", "GB"),
    ("Bristol", "GB"), ("Lyon", "FR"), ("Hamburg", "DE"),
]
LOYALTY_TIERS = ["bronze", "silver", "gold", "platinum"]

CATEGORIES = {
    "Grocery": ["Pantry", "Produce", "Bakery", "Frozen"],
    "Household": ["Cleaning", "Laundry", "Paper Goods"],
    "Beverages": ["Coffee", "Tea", "Juice", "Soft Drinks"],
    "Personal Care": ["Haircare", "Skincare", "Oral Care"],
    "Pet": ["Dog", "Cat"],
}
PRODUCT_NOUNS = [
    "Olive Oil", "Sourdough Loaf", "Almond Butter", "Basmati Rice",
    "Dish Soap", "Laundry Pods", "Paper Towels", "Glass Cleaner",
    "Dark Roast Beans", "Green Tea", "Orange Juice", "Sparkling Water",
    "Shampoo", "Face Cream", "Toothpaste", "Dog Biscuits", "Cat Litter",
    "Tomato Passata", "Maple Syrup", "Sea Salt",
]
PRODUCT_QUALIFIERS = ["Organic", "Value", "Premium", "House", "Classic", "Bulk"]

ORDER_STATUSES = ["placed", "picked", "shipped", "delivered", "returned"]
CHANNELS = ["web", "mobile", "in_store", "phone"]

Row = dict[str, object]


@dataclass
class Table:
    """A CSV table: an ordered header plus its rows."""

    name: str
    header: list[str]
    rows: list[Row]


# ---------------------------------------------------------------------------
# Clean generation
# ---------------------------------------------------------------------------

def build_stores() -> Table:
    """Stores are kept defect-free on purpose.

    The error-severity dbt tests run against this entity and must pass. That is
    what demonstrates the warn severity used elsewhere is a deliberate setting
    rather than testing being switched off wholesale.
    """
    header = [
        "store_id", "store_name", "city", "country", "region",
        "opened_date", "square_feet",
    ]
    specs = [
        ("ST-001", "Pearl District", "Portland", "US", "West", date(2018, 3, 12), 14200),
        ("ST-002", "South Congress", "Austin", "US", "South", date(2019, 7, 1), 11800),
        ("ST-003", "Wicker Park", "Chicago", "US", "Midwest", date(2017, 11, 20), 16500),
        ("ST-004", "LoDo", "Denver", "US", "West", date(2020, 2, 14), 9900),
        ("ST-005", "Queen West", "Toronto", "CA", "East", date(2019, 5, 6), 12400),
        ("ST-006", "Gastown", "Vancouver", "CA", "West", date(2021, 9, 30), 8700),
        ("ST-007", "Northern Quarter", "Manchester", "GB", "North", date(2018, 8, 8), 10250),
        ("ST-008", "Harbourside", "Bristol", "GB", "South", date(2022, 4, 25), 7600),
    ]
    rows: list[Row] = [
        {
            "store_id": store_id,
            "store_name": store_name,
            "city": city,
            "country": country,
            "region": region,
            "opened_date": opened.isoformat(),
            "square_feet": square_feet,
        }
        for store_id, store_name, city, country, region, opened, square_feet in specs
    ]
    return Table("stores", header, rows)


def build_customers(rng: random.Random) -> Table:
    header = [
        "customer_id", "first_name", "last_name", "email", "phone",
        "city", "country", "signup_date", "loyalty_tier",
    ]
    rows: list[Row] = []
    for i in range(1, N_CUSTOMERS + 1):
        first = rng.choice(FIRST_NAMES)
        last = rng.choice(LAST_NAMES)
        city, country = rng.choice(CITIES)
        signup = date(2023, 1, 1) + timedelta(days=rng.randint(0, 1000))
        rows.append(
            {
                "customer_id": f"CU-{i:05d}",
                "first_name": first,
                "last_name": last,
                "email": f"{first.lower()}.{last.lower()}{i}@example.com",
                "phone": f"+1-555-{rng.randint(1000, 9999)}",
                "city": city,
                "country": country,
                "signup_date": signup.isoformat(),
                "loyalty_tier": rng.choice(LOYALTY_TIERS),
            }
        )
    return Table("customers", header, rows)


def build_products(rng: random.Random) -> Table:
    header = [
        "product_id", "product_name", "category", "subcategory",
        "unit_price", "cost_price", "supplier",
    ]
    rows: list[Row] = []
    for i in range(1, N_PRODUCTS + 1):
        category = rng.choice(list(CATEGORIES))
        subcategory = rng.choice(CATEGORIES[category])
        name = f"{rng.choice(PRODUCT_QUALIFIERS)} {rng.choice(PRODUCT_NOUNS)}"
        unit_price = round(rng.uniform(1.75, 48.0), 2)
        cost_price = round(unit_price * rng.uniform(0.45, 0.72), 2)
        rows.append(
            {
                "product_id": f"SKU-{i:04d}",
                "product_name": name,
                "category": category,
                "subcategory": subcategory,
                "unit_price": f"{unit_price:.2f}",
                "cost_price": f"{cost_price:.2f}",
                "supplier": f"Supplier {rng.randint(1, 12):02d}",
            }
        )
    return Table("products", header, rows)


def build_orders(rng: random.Random, customer_ids: list[str], store_ids: list[str]) -> Table:
    header = [
        "order_id", "customer_id", "store_id", "order_date",
        "status", "channel", "currency",
    ]
    rows: list[Row] = []
    for i in range(1, N_ORDERS + 1):
        order_date = BATCH_DATES[0] + timedelta(days=rng.randint(0, 1))
        rows.append(
            {
                "order_id": f"OR-{i:06d}",
                "customer_id": rng.choice(customer_ids),
                "store_id": rng.choice(store_ids),
                "order_date": order_date.isoformat(),
                "status": rng.choice(ORDER_STATUSES),
                "channel": rng.choice(CHANNELS),
                "currency": "USD",
            }
        )
    return Table("orders", header, rows)


def build_order_items(rng: random.Random, orders: list[Row], products: list[Row]) -> Table:
    header = [
        "order_item_id", "order_id", "product_id", "quantity",
        "unit_price", "discount_pct", "line_total",
    ]
    price_by_sku = {row["product_id"]: float(str(row["unit_price"])) for row in products}
    rows: list[Row] = []
    counter = 0
    for order in orders:
        for _ in range(rng.randint(*ITEMS_PER_ORDER)):
            counter += 1
            product = rng.choice(products)
            sku = product["product_id"]
            quantity = rng.randint(1, 6)
            unit_price = price_by_sku[sku]
            discount = rng.choice([0.0, 0.0, 0.0, 0.05, 0.10, 0.15])
            line_total = round(quantity * unit_price * (1 - discount), 2)
            rows.append(
                {
                    "order_item_id": f"OI-{counter:07d}",
                    "order_id": order["order_id"],
                    "product_id": sku,
                    "quantity": quantity,
                    "unit_price": f"{unit_price:.2f}",
                    "discount_pct": f"{discount:.2f}",
                    "line_total": f"{line_total:.2f}",
                }
            )
    return Table("order_items", header, rows)


# ---------------------------------------------------------------------------
# Defect injection
#
# Every mutation below is intentional and is matched by a warn-severity dbt
# test. Keep the DQ-nn tags in sync with docs/data-quality.md.
# ---------------------------------------------------------------------------

def inject_customer_defects(customers: Table) -> None:
    rows = customers.rows

    # DQ-02: four customers with a missing email address. An empty CSV field is
    # mapped to SQL NULL by the null_values setting on the connector stream.
    for index in (7, 42, 118, 173):
        rows[index]["email"] = None

    # DQ-03: the same country recorded four different ways. Only the two-letter
    # uppercase form is valid, so the other three are the ones that get flagged.
    rows[3]["country"] = "usa"
    rows[19]["country"] = "USA"
    rows[57]["country"] = "Usa"
    rows[91]["country"] = "United States"

    # DQ-04: a signup date in the future, which no real record should ever have.
    rows[64]["signup_date"] = "2027-11-02"

    # DQ-01: two duplicated customer_id values, appended so the originals stay
    # intact and the duplicate is the second occurrence.
    for source_index in (11, 88):
        duplicate = dict(rows[source_index])
        duplicate["phone"] = "+1-555-0000"
        rows.append(duplicate)


def inject_product_defects(products: Table) -> None:
    rows = products.rows

    # DQ-05: a negative unit price, the classic sign-flip data entry error.
    rows[22]["unit_price"] = "-12.99"

    # DQ-06: three products with no category assigned.
    for index in (5, 31, 48):
        rows[index]["category"] = None


def inject_order_defects(orders: Table, rng: random.Random) -> None:
    rows = orders.rows

    # DQ-07: five orders pointing at customers that do not exist. This is what a
    # late-arriving or partially-extracted dimension looks like in practice.
    for offset, index in enumerate((15, 140, 301, 522, 733)):
        rows[index]["customer_id"] = f"CU-9{offset:04d}"

    # DQ-08: status values that break the controlled vocabulary. Note the
    # trailing space on one of them, which is invisible in most viewers.
    rows[27]["status"] = "SHIPPED"
    rows[203]["status"] = "shipped "
    rows[418]["status"] = "unknown"
    rows[655]["status"] = "Delivered"

    # DQ-10: two orders with no order date.
    for index in (88, 470):
        rows[index]["order_date"] = None

    # DQ-09: one duplicated order_id.
    duplicate = dict(rows[250])
    duplicate["channel"] = "phone"
    rows.append(duplicate)


def inject_order_item_defects(order_items: Table) -> None:
    rows = order_items.rows

    # DQ-11: a zero quantity and a negative quantity. line_total is recomputed
    # to stay arithmetically consistent, so these rows trip the quantity range
    # test and nothing else -- each seeded defect maps to exactly one dbt test.
    for index, quantity in ((12, 0), (900, -2)):
        row = rows[index]
        row["quantity"] = quantity
        consistent = round(
            quantity
            * float(str(row["unit_price"]))
            * (1 - float(str(row["discount_pct"]))),
            2,
        )
        row["line_total"] = f"{consistent:.2f}"

    # DQ-12: six lines where line_total disagrees with quantity * unit_price
    # after discount. Arithmetic drift like this usually means an upstream
    # rounding or currency-conversion bug.
    for index in (44, 210, 655, 1180, 1712, 2043):
        current = float(str(rows[index]["line_total"]))
        rows[index]["line_total"] = f"{round(current + 3.17, 2):.2f}"

    # DQ-13: four line items whose parent order does not exist.
    for offset, index in enumerate((30, 777, 1500, 2200)):
        rows[index]["order_id"] = f"OR-99{offset:04d}"


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def write_csv(path: Path, header: list[str], rows: list[Row]) -> None:
    # newline="" with an explicit LF terminator keeps output identical on
    # Windows; .gitattributes pins the checkout side of the same guarantee.
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle, fieldnames=header, lineterminator="\n", extrasaction="raise"
        )
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {key: ("" if row.get(key) is None else row[key]) for key in header}
            )


def split_by_order_date(orders: Table, order_items: Table) -> dict[str, list[Row]]:
    """Assign every transactional row to one of the two batch files.

    Orders are split on their own order_date; order_items follow their parent so
    a parent and its children always land in the same batch. Rows whose date is
    missing (DQ-10) or whose parent is missing (DQ-13) go into the first batch.
    """
    first, second = (d.isoformat() for d in BATCH_DATES)
    batch_of_order: dict[str, str] = {}
    buckets: dict[str, list[Row]] = {
        f"orders::{first}": [], f"orders::{second}": [],
        f"order_items::{first}": [], f"order_items::{second}": [],
    }

    for row in orders.rows:
        batch = second if row.get("order_date") == second else first
        batch_of_order[str(row["order_id"])] = batch
        buckets[f"orders::{batch}"].append(row)

    for row in order_items.rows:
        batch = batch_of_order.get(str(row["order_id"]), first)
        buckets[f"order_items::{batch}"].append(row)

    return buckets


def verify(tables: dict[str, Table]) -> None:
    """Assert the defect counts documented in docs/data-quality.md.

    Generation is seeded, so any drift here means the generator changed and the
    documentation plus the dbt test expectations need to change with it.
    """
    customers = tables["customers"].rows
    products = tables["products"].rows
    orders = tables["orders"].rows
    items = tables["order_items"].rows

    customer_ids = {str(r["customer_id"]) for r in customers}
    order_ids = {str(r["order_id"]) for r in orders}

    checks: list[tuple[str, int, int]] = [
        ("DQ-01 duplicate customer_id",
         len(customers) - len(customer_ids), 2),
        ("DQ-02 null email",
         sum(1 for r in customers if not r["email"]), 4),
        ("DQ-03 invalid country",
         sum(1 for r in customers if r["country"] not in {"US", "CA", "GB", "FR", "DE"}), 4),
        ("DQ-04 future signup_date",
         sum(1 for r in customers if str(r["signup_date"]) > "2026-08-30"), 1),
        ("DQ-05 negative unit_price",
         sum(1 for r in products if float(str(r["unit_price"])) < 0), 1),
        ("DQ-06 null category",
         sum(1 for r in products if not r["category"]), 3),
        ("DQ-07 orphan customer_id on orders",
         sum(1 for r in orders if r["customer_id"] not in customer_ids), 5),
        ("DQ-08 invalid status",
         sum(1 for r in orders if r["status"] not in ORDER_STATUSES), 4),
        ("DQ-09 duplicate order_id",
         len(orders) - len(order_ids), 1),
        ("DQ-10 null order_date",
         sum(1 for r in orders if not r["order_date"]), 2),
        ("DQ-11 quantity out of range",
         sum(1 for r in items if int(str(r["quantity"])) < 1), 2),
        ("DQ-12 line_total disagrees with quantity * unit_price",
         sum(
             1
             for r in items
             if abs(
                 float(str(r["line_total"]))
                 - round(
                     int(str(r["quantity"]))
                     * float(str(r["unit_price"]))
                     * (1 - float(str(r["discount_pct"]))),
                     2,
                 )
             )
             > 0.01
         ), 6),
        ("DQ-13 orphan order_id on order_items",
         sum(1 for r in items if r["order_id"] not in order_ids), 4),
    ]

    mismatched = 0
    for label, actual, expected in [(c[0], c[1], c[2]) for c in checks]:
        status = "ok" if actual == expected else "MISMATCH"
        if actual != expected:
            mismatched += 1
        print(f"  {status:8} {label}: {actual} (expected {expected})")

    if mismatched:
        raise SystemExit(
            f"{mismatched} defect count(s) do not match docs/data-quality.md"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    out_dir: Path = args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    rng = random.Random(SEED)

    stores = build_stores()
    customers = build_customers(rng)
    products = build_products(rng)
    orders = build_orders(
        rng,
        [str(r["customer_id"]) for r in customers.rows],
        [str(r["store_id"]) for r in stores.rows],
    )
    order_items = build_order_items(rng, orders.rows, products.rows)

    inject_customer_defects(customers)
    inject_product_defects(products)
    inject_order_defects(orders, rng)
    inject_order_item_defects(order_items)

    tables = {
        "stores": stores,
        "customers": customers,
        "products": products,
        "orders": orders,
        "order_items": order_items,
    }

    for old in out_dir.glob("*.csv"):
        old.unlink()

    # Reference entities arrive as a single file on the first batch date.
    stamp = BATCH_DATES[0].isoformat()
    for name in ("stores", "customers", "products"):
        table = tables[name]
        path = out_dir / f"{name}_{stamp}.csv"
        write_csv(path, table.header, table.rows)
        print(f"  wrote {path}  ({len(table.rows)} rows)")

    # Transactional entities are split across both batch dates.
    buckets = split_by_order_date(orders, order_items)
    for key, rows in buckets.items():
        name, batch = key.split("::")
        path = out_dir / f"{name}_{batch}.csv"
        write_csv(path, tables[name].header, rows)
        print(f"  wrote {path}  ({len(rows)} rows)")

    print("\nSeeded data quality defects:")
    verify(tables)
    print("\nAll defect counts match docs/data-quality.md.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
