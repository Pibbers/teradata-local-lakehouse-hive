-- =============================================================
-- 06_otf_read_validation.sql
-- Validate OTF read access to the Iceberg table and demonstrate
-- Iceberg-specific capabilities: metadata inspection, time travel.
--
-- Table reference: lakehouse_iceberg.demo.sales_events
-- Prerequisite:   05_otf_setup.sql must have run successfully
--                 sales_events_td must exist (from 03_nos_read_validation.sql)
-- =============================================================

-- 1. Row count via OTF
SELECT COUNT(*) AS iceberg_row_count
FROM   lakehouse_iceberg.demo.sales_events;

-- 2. Filtered query — Iceberg manifest files enable efficient
--    pruning without requiring folder-level partition names
SELECT region,
       SUM(amount)  AS total_amount,
       COUNT(*)     AS event_count,
       AVG(amount)  AS avg_amount
FROM   lakehouse_iceberg.demo.sales_events
WHERE  event_date BETWEEN DATE '2024-06-29' AND DATE '2024-06-30'
GROUP BY region
ORDER BY total_amount DESC;

-- 3. Load a partition into native Teradata table
--    (sales_events_td must exist from 03_nos_read_validation.sql)
--    Explicit column list required: sales_events_td was created from NOS and
--    includes virtual path columns (Location, dir1-dir4, var5) not in Iceberg.
INSERT INTO lakehouse_demo.sales_events_td
  (event_id, event_ts, event_date, event_hour, customer_id, product_id, amount, channel, region)
SELECT event_id, event_ts, event_date, event_hour, customer_id, product_id, amount, channel, region
FROM   lakehouse_iceberg.demo.sales_events
WHERE  event_date = DATE '2024-07-01';

-- Verify row count increased (35,000 NOS rows + 10,000 July-01 Iceberg rows = 45,000)
SELECT COUNT(*) AS td_rows_after_otf_load
FROM   lakehouse_demo.sales_events_td;

-- 4. Snapshot history — list all available snapshots
SELECT * FROM TD_SNAPSHOTS(ON lakehouse_iceberg.demo.sales_events) AS snapshots;

-- 5. Table operation history
SELECT * FROM TD_HISTORY(ON lakehouse_iceberg.demo.sales_events) AS history;

-- 6. Time travel — query as of the 5th snapshot (first 5 of 7 appends = 25,000 rows).
--    Snapshots were written at 15:04:02–15:04:04 today; at 15:04:03 the 5th snapshot
--    is the latest one AT OR BEFORE that second, so we expect 25,000 rows.
SELECT COUNT(*) AS rows_at_snapshot_5
FROM   lakehouse_iceberg.demo.sales_events
FOR SNAPSHOT AS OF TIMESTAMP '2026-06-30 15:04:03';

-- 7. Cross-source comparison: NOS count vs Iceberg count
--    Note: NOS table covers /raw/ root so picks up sales_events_north_export/ too.
SELECT 'ICEBERG' AS source, COUNT(*) AS cnt FROM lakehouse_iceberg.demo.sales_events
UNION ALL
SELECT 'NOS'     AS source, COUNT(*) AS cnt FROM lakehouse_demo.sales_events_nos;
