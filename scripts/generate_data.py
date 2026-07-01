"""
Generate sales_events sample data and upload to MinIO raw bucket.

Layout:  raw/sales_events/YYYY/MM/DD/HH/sales_events_YYYYMMDD_HH.parquet

Usage:
    pip install -r requirements.txt
    python scripts/generate_data.py

Environment variables (falls back to .env defaults):
    HOST_IP              host running MinIO  (default: 192.168.1.242)
    MINIO_ROOT_USER      MinIO access key    (default: minioadmin)
    MINIO_ROOT_PASSWORD  MinIO secret key    (default: minioadmin)
    MINIO_API_PORT       MinIO API port      (default: 9000)
"""

import os
import io
import random
from datetime import datetime, timedelta

from decimal import Decimal

import pyarrow as pa
import pyarrow.parquet as pq
from faker import Faker
from minio import Minio
from minio.error import S3Error

fake = Faker()
random.seed(42)

HOST_IP   = os.getenv("HOST_IP",              "192.168.1.242")
MINIO_USER = os.getenv("MINIO_ROOT_USER",     "minioadmin")
MINIO_PASS = os.getenv("MINIO_ROOT_PASSWORD", "minioadmin")
MINIO_PORT = os.getenv("MINIO_API_PORT",      "9000")

BUCKET     = "raw"
PREFIX     = "sales_events"
ROWS_PER_FILE = 5000

CHANNELS = ["ONLINE", "STORE", "APP"]
REGIONS  = ["NORTH", "SOUTH", "EAST", "WEST"]

# 7 date/hour slots across 3 days
SLOTS = [
    (2024, 6, 29,  8),
    (2024, 6, 29, 12),
    (2024, 6, 29, 16),
    (2024, 6, 30,  9),
    (2024, 6, 30, 14),
    (2024, 7,  1, 10),
    (2024, 7,  1, 15),
]

SCHEMA = pa.schema([
    ("event_id",    pa.int64()),
    ("event_ts",    pa.timestamp("us")),
    ("event_date",  pa.date32()),
    ("event_hour",  pa.int16()),
    ("customer_id", pa.int32()),
    ("product_id",  pa.int32()),
    ("amount",      pa.decimal128(10, 2)),
    ("channel",     pa.string()),
    ("region",      pa.string()),
])


def generate_batch(slot_index: int, year: int, month: int, day: int, hour: int) -> pa.Table:
    base_ts = datetime(year, month, day, hour, 0, 0)
    event_id_start = slot_index * ROWS_PER_FILE + 1

    rows = {col: [] for col in SCHEMA.names}
    for i in range(ROWS_PER_FILE):
        ts = base_ts + timedelta(seconds=random.randint(0, 3599))
        rows["event_id"].append(event_id_start + i)
        rows["event_ts"].append(ts)
        rows["event_date"].append(ts.date())
        rows["event_hour"].append(hour)
        rows["customer_id"].append(random.randint(1, 5000))
        rows["product_id"].append(random.randint(1, 200))
        rows["amount"].append(Decimal(str(round(random.uniform(0.01, 999.99), 2))))
        rows["channel"].append(random.choice(CHANNELS))
        rows["region"].append(random.choice(REGIONS))

    return pa.table(
        {k: pa.array(v, type=SCHEMA.field(k).type) for k, v in rows.items()},
        schema=SCHEMA,
    )


def table_to_parquet_bytes(table: pa.Table) -> bytes:
    buf = io.BytesIO()
    pq.write_table(table, buf, compression="snappy")
    buf.seek(0)
    return buf.read()


def main():
    client = Minio(
        f"{HOST_IP}:{MINIO_PORT}",
        access_key=MINIO_USER,
        secret_key=MINIO_PASS,
        secure=False,
    )

    if not client.bucket_exists(BUCKET):
        client.make_bucket(BUCKET)
        print(f"Created bucket: {BUCKET}")

    total_rows = 0
    for idx, (year, month, day, hour) in enumerate(SLOTS):
        table = generate_batch(idx, year, month, day, hour)
        data = table_to_parquet_bytes(table)

        object_name = (
            f"{PREFIX}/{year:04d}/{month:02d}/{day:02d}/{hour:02d}/"
            f"sales_events_{year:04d}{month:02d}{day:02d}_{hour:02d}.parquet"
        )

        client.put_object(
            BUCKET,
            object_name,
            io.BytesIO(data),
            length=len(data),
            content_type="application/octet-stream",
        )
        total_rows += len(table)
        print(f"  uploaded  s3://{BUCKET}/{object_name}  ({len(table):,} rows, {len(data):,} bytes)")

    print(f"\nDone — {total_rows:,} rows across {len(SLOTS)} files in s3://{BUCKET}/{PREFIX}/")


if __name__ == "__main__":
    main()
