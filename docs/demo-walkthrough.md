# Demo Walkthrough

This document explains each step of the end-to-end lakehouse demo, what it does, and what to look for in the output.

## Overview

The demo shows two ways Teradata can access data stored in object storage:

- **NOS (Native Object Store)** — Teradata reads raw Parquet files directly using a foreign table, and writes back using the `WRITE_NOS` table value function.
- **OTF (Open Table Format)** — Teradata reads an Iceberg table registered in Hive Metastore via a `DATALAKE` object, including metadata inspection and time travel.

Running `./run_demo.sh` executes all six stages in order. Each stage is described below.

---

## Running the Demo

```bash
# Ensure Docker services are up
docker compose up -d

# Run the full demo
./run_demo.sh

# Reset all Teradata objects and MinIO data to re-run cleanly
./reset_demo.sh
```

---

## Stage 1 — Docker Service Health

`run_demo.sh` checks that `minio` and `hive-metastore` containers are healthy before proceeding. If either is not running, start it with:

```bash
docker compose up -d minio hive-metastore
```

---

## Stage 2 — Connectivity Checks

The script verifies network reachability for all three systems the demo depends on:

| Endpoint | Port | Purpose |
|---|---|---|
| `HOST_IP` | 9000 | MinIO API (NOS and OTF storage) |
| `HOST_IP` | 9083 | Hive Metastore Thrift (OTF catalog) |
| `TD_HOST` | 1025 | Teradata database |

If any check fails, verify the relevant `.env` variable (`HOST_IP`, `TD_HOST`) and that firewall rules allow connections from the Teradata system to your Docker host.

> Important: Several Teradata SQL scripts in this demo hardcode the MinIO host and port because this Teradata version does not support endpoint override. Before running, ensure `HOST_IP` in `.env` matches the Docker host IP and update the following files if needed:
> - `sql/teradata/02_nos_foreign_table.sql`
> - `sql/teradata/04_nos_writeback.sql`
> - `sql/teradata/05_otf_setup.sql`

---

## Stage 3 — TPT Container

The Teradata Parallel Transporter (`tpt`) container provides the `bteq` binary used to run all SQL scripts. The demo starts it automatically if it is not already running.

---

## Stage 4 — Generate Raw Sample Data (NOS path)

**Script:** `scripts/generate_data.py`

Generates synthetic `sales_events` data and uploads it to MinIO as Parquet files under the path `s3://raw/sales_events/`. Files are partitioned by date and hour:

```
raw/
└── sales_events/
    └── 2024/
        ├── 06/29/<hour>/  ← ~5,000 rows per file
        ├── 06/30/<hour>/
        └── ...            (7 files total, ~35,000 rows)
```

The `PATHPATTERN` on the NOS foreign table maps these folder levels to virtual columns (`dir2`=year, `dir3`=month, `dir4`=day, `var5`=hour) used for partition pruning in Demo 03.

---

## Stage 5 — Create Iceberg Table in Hive Metastore (OTF path)

**Script:** `scripts/create_iceberg.py`

Creates an Iceberg table `demo.sales_events` in the Hive Metastore and writes data files to the Iceberg warehouse in MinIO at `s3://iceberg/warehouse/demo/sales_events/`. The table contains 7 snapshots (one per append batch) covering events for `2024-07-01` (~10,000 rows total).

This table is accessed by Teradata through the `DATALAKE` object created in Demo 05.

---

## Stage 6 — Teradata SQL Scripts via BTEQ

All SQL scripts run inside the `tpt` container via BTEQ, connected to the external Teradata system.

### Demo 00 — Create Database

**File:** `sql/teradata/00_setup_database.sql`

Creates the `lakehouse_demo` database with 10 GB of permanent space. All NOS objects are stored here.

```
Object created: lakehouse_demo (database)
```

---

### Demo 01 — NOS Authorization

**File:** `sql/teradata/01_nos_authorization.sql`

Creates a `DEFINER TRUSTED` authorization object (`minio_nos_auth`) in `lakehouse_demo` that holds the MinIO credentials used by `CREATE FOREIGN TABLE` to authenticate NOS reads.

> **Note:** The Teradata version in use (TD 20.00.28.81) does not support `WITH OVERRIDE LOCATION ENDPOINT`, so the MinIO host and port are embedded directly in the `LOCATION` path in Demo 02.

```
Object created: lakehouse_demo.minio_nos_auth
```

---

### Demo 02 — NOS Foreign Table

**File:** `sql/teradata/02_nos_foreign_table.sql`

Creates a foreign table `sales_events_nos` that points directly at the raw Parquet files in MinIO. No data is copied — queries run against the files in place.

The `PATHPATTERN` clause exposes folder levels as virtual columns:

| Virtual column | Path level | Example value |
|---|---|---|
| `dir2` | Year | `2024` (SMALLINT) |
| `dir3` | Month | `'06'` (VARCHAR) |
| `dir4` | Day | `'29'` (VARCHAR) |
| `var5` | Hour | `'08'` (VARCHAR) |

These columns do not appear in the `CREATE FOREIGN TABLE` column list — they are injected by the NOS engine and visible via `HELP TABLE`.

```
Object created: lakehouse_demo.sales_events_nos
```

---

### Demo 03 — NOS Read Validation

**File:** `sql/teradata/03_nos_read_validation.sql`

Validates that NOS reads work correctly and loads data into a native Teradata table. Runs five queries in sequence:

1. **Full scan count** — expects ~35,000 rows across all 7 files.
2. **Partition pruning** — filters using `dir2`/`dir3`/`dir4` virtual columns to read only a single day's file.
3. **Spot check** — fetches 10 sample rows from a specific day.
4. **Region summary** — aggregates revenue and event count by region across all files.
5. **Load to native table** — runs `CREATE TABLE AS SELECT` from the foreign table into `sales_events_td`, a permanent Teradata table with `event_id` as the primary index. Expects ~35,000 rows loaded.

```
Objects created: lakehouse_demo.sales_events_td
```

---

### Demo 04 — NOS Write-back

**File:** `sql/teradata/04_nos_writeback.sql`

Writes rows from the native table back to MinIO as Parquet using the `WRITE_NOS` table value function. Demonstrates the **reverse** data flow: Teradata → object store.

Key implementation detail: `WRITE_NOS` requires a *simplified* authorization object (plain `USER`/`PASSWORD`, no `AS DEFINER TRUSTED` clause). A second auth object `minio_write_auth` is created for this purpose.

The export filters `sales_events_td` to the `NORTH` region and writes Snappy-compressed Parquet files to:

```
s3://raw/sales_events_north_export/
```

BTEQ output shows one row per Parquet file written (one per AMP), including the full S3 path, file size in bytes, and row count. A verification foreign table is then created over the export path to confirm the row count.

```
Objects created: lakehouse_demo.minio_write_auth
                 lakehouse_demo.sales_events_nos_out_verify
MinIO path:      raw/sales_events_north_export/
```

---

### Demo 05 — OTF DATALAKE Setup

**File:** `sql/teradata/05_otf_setup.sql`

Creates a `DATALAKE` object that connects Teradata to the Hive Metastore catalog and the Iceberg data in MinIO. This is the OTF equivalent of the NOS foreign table — a single object that provides access to any Iceberg table registered in the catalog.

Two authorization objects are required, and they **must** be created in `TD_SERVER_DB` (not in `lakehouse_demo`):

| Auth object | Purpose |
|---|---|
| `hms_catalog_auth` | Hive Metastore Thrift connection (credentials are `anonymous`/`anonymous` — HMS does not authenticate client connections on port 9083) |
| `minio_storage_auth` | MinIO storage access for reading Iceberg data files |

After setup, the Iceberg table is referenced using a three-part name:

```sql
lakehouse_iceberg.demo.sales_events
--  ↑ DATALAKE    ↑ HMS namespace  ↑ table name
```

`HELP DATALAKE lakehouse_iceberg` lists the HMS namespaces visible through the catalog. `demo` should appear after `create_iceberg.py` has run.

```
Objects created: TD_SERVER_DB.hms_catalog_auth
                 TD_SERVER_DB.minio_storage_auth
                 lakehouse_demo.lakehouse_iceberg (DATALAKE)
```

---

### Demo 06 — OTF Read Validation

**File:** `sql/teradata/06_otf_read_validation.sql`

Validates OTF access and demonstrates Iceberg-specific features not available with raw NOS reads.

Runs seven queries in sequence:

1. **Row count** — counts all rows in the Iceberg table via OTF. Expects ~10,000 rows (July-01 data only).
2. **Filtered aggregate** — queries by `event_date` range. Unlike NOS partition pruning (which uses folder names), Iceberg uses manifest files and column statistics for efficient predicate pushdown.
3. **Load July-01 data into native table** — inserts the Iceberg rows into `sales_events_td` (which already holds ~35,000 NOS rows). After this step, `sales_events_td` contains ~45,000 rows. An explicit column list is required because `sales_events_td` was originally created from the NOS foreign table and includes virtual path columns (`Location`, `dir1`–`dir4`, `var5`) that do not exist in the Iceberg table.
4. **Snapshot history** — queries `TD_SNAPSHOTS()` to list all available Iceberg snapshots. Expects 7 snapshots (one per batch written by `create_iceberg.py`).
5. **Operation history** — queries `TD_HISTORY()` to show the table operation log.
6. **Time travel** — queries the table `FOR SNAPSHOT AS OF TIMESTAMP` targeting the point in time after the 5th snapshot. Expects 25,000 rows (5 × 5,000 rows per batch).
7. **Cross-source comparison** — union of NOS and Iceberg row counts in a single result. Note that the NOS table (`/raw/`) covers both the original `sales_events/` files and the `sales_events_north_export/` write-back directory, so its count will be higher than the raw 35,000.

---

## Objects Created by the Demo

| Object | Type | Location |
|---|---|---|
| `lakehouse_demo` | Teradata database | Teradata |
| `lakehouse_demo.minio_nos_auth` | Authorization | Teradata |
| `lakehouse_demo.minio_write_auth` | Authorization | Teradata |
| `lakehouse_demo.sales_events_nos` | NOS foreign table | Teradata → MinIO `raw/` |
| `lakehouse_demo.sales_events_nos_out_verify` | NOS foreign table | Teradata → MinIO `raw/sales_events_north_export/` |
| `lakehouse_demo.sales_events_td` | Native table | Teradata |
| `TD_SERVER_DB.hms_catalog_auth` | Authorization | Teradata |
| `TD_SERVER_DB.minio_storage_auth` | Authorization | Teradata |
| `lakehouse_iceberg` | DATALAKE | Teradata → HMS + MinIO `iceberg/` |
| `demo.sales_events` | Iceberg table | HMS catalog, data in MinIO |
| `raw/sales_events/` | Parquet files | MinIO (7 files, ~35,000 rows) |
| `raw/sales_events_north_export/` | Parquet files | MinIO (NOS write-back, NORTH region) |
| `iceberg/warehouse/demo/sales_events/` | Iceberg data + metadata | MinIO |

---

## Known Limitations

- **OTF write-back is not supported** in this environment (TD 20.00.28.81). Writing from Teradata into an Iceberg table via `INSERT INTO lakehouse_iceberg.demo.sales_events` triggers a database engine bug. NOS write-back (`WRITE_NOS`) works correctly.
- The MinIO host and port are hardcoded in `sql/teradata/02_nos_foreign_table.sql`, `04_nos_writeback.sql`, and `05_otf_setup.sql` because `WITH OVERRIDE LOCATION ENDPOINT` is not supported on this version. Update these files if `HOST_IP` changes.
- If the demo fails in step 04, verify the MinIO host:port embedded in `sql/teradata/04_nos_writeback.sql` matches the Docker host IP configured in `.env`.
- The time travel query in Demo 06 uses a hardcoded timestamp. If you regenerate the Iceberg table, update the timestamp in `06_otf_read_validation.sql` to match the new snapshot times shown by `TD_SNAPSHOTS()`.
