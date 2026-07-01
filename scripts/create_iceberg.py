"""
Create the sales_events Iceberg table in Hive Metastore (HMS) and populate it.

Table:    demo.sales_events
Catalog:  Hive Metastore at thrift://localhost:9083
Storage:  s3://iceberg/warehouse/demo/sales_events/

Table properties:
  write.object-storage.enabled = true   (avoids Hive-style key=value partition paths)
  write.format.default          = parquet
  write.parquet.compression-codec = snappy

Usage:
    pip install -r requirements.txt
    python scripts/create_iceberg.py

Environment variables:
    HOST_IP              host running MinIO + HMS  (default: 192.168.1.242)
    MINIO_ROOT_USER      MinIO access key          (default: minioadmin)
    MINIO_ROOT_PASSWORD  MinIO secret key          (default: minioadmin)
    MINIO_API_PORT       MinIO API port            (default: 9000)
    HMS_PORT             Hive Metastore port       (default: 9083)
"""

import os
import random
from datetime import datetime, timedelta
from decimal import Decimal

import pyarrow as pa
from pyiceberg.catalog.hive import HiveCatalog
from pyiceberg.schema import Schema
from pyiceberg.types import (
    LongType, TimestampType, DateType, IntegerType,
    DecimalType, StringType, NestedField,
)
from pyiceberg.partitioning import PartitionSpec
from pyiceberg.table.sorting import SortOrder

random.seed(42)

HOST_IP    = os.getenv("HOST_IP",              "192.168.1.242")
MINIO_USER = os.getenv("MINIO_ROOT_USER",     "minioadmin")
MINIO_PASS = os.getenv("MINIO_ROOT_PASSWORD", "minioadmin")
MINIO_PORT = os.getenv("MINIO_API_PORT",      "9000")
HMS_PORT   = os.getenv("HMS_PORT",            "9083")

NAMESPACE  = "demo"
TABLE_NAME = "sales_events"
ROWS_PER_SLOT = 5000

CHANNELS = ["ONLINE", "STORE", "APP"]
REGIONS  = ["NORTH", "SOUTH", "EAST", "WEST"]

SLOTS = [
    (2024, 6, 29,  8),
    (2024, 6, 29, 12),
    (2024, 6, 29, 16),
    (2024, 6, 30,  9),
    (2024, 6, 30, 14),
    (2024, 7,  1, 10),
    (2024, 7,  1, 15),
]

ICEBERG_SCHEMA = Schema(
    NestedField(1,  "event_id",    LongType(),           required=True),
    NestedField(2,  "event_ts",    TimestampType(),      required=True),
    NestedField(3,  "event_date",  DateType(),           required=True),
    NestedField(4,  "event_hour",  IntegerType(),         required=True),
    NestedField(5,  "customer_id", IntegerType(),        required=False),
    NestedField(6,  "product_id",  IntegerType(),        required=False),
    NestedField(7,  "amount",      DecimalType(10, 2),   required=False),
    NestedField(8,  "channel",     StringType(),         required=False),
    NestedField(9,  "region",      StringType(),         required=False),
)

ARROW_SCHEMA = pa.schema([
    pa.field("event_id",    pa.int64(),         nullable=False),
    pa.field("event_ts",    pa.timestamp("us"), nullable=False),
    pa.field("event_date",  pa.date32(),        nullable=False),
    pa.field("event_hour",  pa.int32(),         nullable=False),
    pa.field("customer_id", pa.int32()),
    pa.field("product_id",  pa.int32()),
    pa.field("amount",      pa.decimal128(10, 2)),
    pa.field("channel",     pa.large_string()),
    pa.field("region",      pa.large_string()),
])


def generate_arrow_batch(slot_index: int, year: int, month: int, day: int, hour: int) -> pa.Table:
    base_ts = datetime(year, month, day, hour, 0, 0)
    event_id_start = slot_index * ROWS_PER_SLOT + 1

    cols: dict = {k: [] for k in ARROW_SCHEMA.names}
    for i in range(ROWS_PER_SLOT):
        ts = base_ts + timedelta(seconds=random.randint(0, 3599))
        cols["event_id"].append(event_id_start + i)
        cols["event_ts"].append(ts)
        cols["event_date"].append(ts.date())
        cols["event_hour"].append(hour)
        cols["customer_id"].append(random.randint(1, 5000))
        cols["product_id"].append(random.randint(1, 200))
        cols["amount"].append(Decimal(str(round(random.uniform(0.01, 999.99), 2))))
        cols["channel"].append(random.choice(CHANNELS))
        cols["region"].append(random.choice(REGIONS))

    return pa.table(
        {k: pa.array(v, type=ARROW_SCHEMA.field(k).type) for k, v in cols.items()},
        schema=ARROW_SCHEMA,
    )


def main():
    catalog = HiveCatalog(
        name="hive",
        **{
            "uri":                      f"thrift://localhost:{HMS_PORT}",
            "s3.endpoint":              f"http://{HOST_IP}:{MINIO_PORT}",
            "s3.access-key-id":         MINIO_USER,
            "s3.secret-access-key":     MINIO_PASS,
            "s3.path-style-access":     "true",
            "s3.ssl-enabled":           "false",
            "warehouse":                f"s3://iceberg/warehouse",
            "py-io-impl":               "pyiceberg.io.pyarrow.PyArrowFileIO",
        },
    )

    if (NAMESPACE,) not in catalog.list_namespaces():
        catalog.create_namespace(
            NAMESPACE,
            properties={"location": f"s3://iceberg/warehouse/{NAMESPACE}"},
        )
        print(f"Created namespace: {NAMESPACE}")
    else:
        print(f"Namespace exists: {NAMESPACE}")

    identifier = f"{NAMESPACE}.{TABLE_NAME}"
    if catalog.table_exists(identifier):
        print(f"Dropping existing table: {identifier}")
        catalog.drop_table(identifier)

    table = catalog.create_table(
        identifier=identifier,
        schema=ICEBERG_SCHEMA,
        location=f"s3://iceberg/warehouse/{NAMESPACE}/{TABLE_NAME}",
        partition_spec=PartitionSpec(),
        sort_order=SortOrder(),
        properties={
            "write.format.default":               "parquet",
            "write.parquet.compression-codec":    "snappy",
            "write.target-file-size-bytes":       "134217728",
            "format-version":                     "2",
        },
    )
    print(f"Created table: {identifier}")
    print(f"  location: {table.location()}")

    total_rows = 0
    for idx, (year, month, day, hour) in enumerate(SLOTS):
        batch = generate_arrow_batch(idx, year, month, day, hour)
        table.append(batch)
        total_rows += len(batch)
        print(f"  appended slot {year:04d}/{month:02d}/{day:02d}/{hour:02d}  ({len(batch):,} rows)")

    snapshot = table.current_snapshot()
    print(f"\nDone — {total_rows:,} rows written")
    print(f"  snapshot id : {snapshot.snapshot_id}")
    print(f"  committed at: {datetime.fromtimestamp(snapshot.timestamp_ms / 1000)}")

    stats = table.inspect.snapshots()
    print(f"  total snapshots: {len(stats)}")


if __name__ == "__main__":
    main()
