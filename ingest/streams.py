"""The retail streams, and the schemas they land in.

Standard library only, deliberately. This module is imported from both
virtualenvs -- by the ingest scripts running under PyAirbyte, and by the Dagster
code building the asset graph -- so the stream list and the Dagster asset keys
can never drift apart.
"""

from __future__ import annotations

from dataclasses import dataclass

# Schema that PyAirbyte writes its extracted records into. dbt reads from here
# and never writes to it: raw stays raw.
RAW_SCHEMA = "airbyte_raw"

# The synthetic source lands separately so it can never be confused with, or
# accidentally joined to, the retail data.
FAKER_SCHEMA = "airbyte_faker"


@dataclass(frozen=True)
class RetailStream:
    """One retail entity, and the SFTP files that make it up."""

    name: str
    glob: str
    primary_key: str
    description: str


RETAIL_STREAMS: tuple[RetailStream, ...] = (
    RetailStream(
        name="customers",
        glob="**/customers_*.csv",
        primary_key="customer_id",
        description="Customer master data. One file per batch date.",
    ),
    RetailStream(
        name="products",
        glob="**/products_*.csv",
        primary_key="product_id",
        description="Product catalogue including price and cost.",
    ),
    RetailStream(
        name="stores",
        glob="**/stores_*.csv",
        primary_key="store_id",
        description="Physical store locations. Held defect-free as a control.",
    ),
    RetailStream(
        name="orders",
        glob="**/orders_*.csv",
        primary_key="order_id",
        description="Order headers, split across two batch dates.",
    ),
    RetailStream(
        name="order_items",
        glob="**/order_items_*.csv",
        primary_key="order_item_id",
        description="Order line items, split across two batch dates.",
    ),
)

RETAIL_STREAM_NAMES: tuple[str, ...] = tuple(s.name for s in RETAIL_STREAMS)

# Streams produced by source-faker. The connector defines these; they are listed
# here so the Dagster asset graph can be built without running the connector.
FAKER_STREAM_NAMES: tuple[str, ...] = ("users", "products", "purchases")


def stream_by_name(name: str) -> RetailStream:
    for stream in RETAIL_STREAMS:
        if stream.name == name:
            return stream
    raise KeyError(f"unknown retail stream: {name!r}")
