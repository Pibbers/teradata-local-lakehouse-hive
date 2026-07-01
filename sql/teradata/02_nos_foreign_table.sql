-- =============================================================
-- 02_nos_foreign_table.sql
-- NOS foreign table over raw Parquet files in MinIO.
--
-- LOCATION uses /s3/host:port/bucket/ format because
-- WITH OVERRIDE LOCATION ENDPOINT is not supported on TD 20.00.28.81.
--
-- PATHPATTERN maps 5 path levels to virtual columns auto-injected
-- by the NOS engine (NOT declared in the column list):
--   dir1 = 'sales_events'  (sub-prefix, filter not needed)
--   dir2 = year  (2024)
--   dir3 = month (06)
--   dir4 = day   (29)
--   var5 = hour  (08)
-- =============================================================

.SET ERRORLEVEL 3807 SEVERITY 0

DATABASE lakehouse_demo;

DROP TABLE lakehouse_demo.sales_events_nos;

.SET ERRORLEVEL 3807 SEVERITY 8

CREATE FOREIGN TABLE lakehouse_demo.sales_events_nos
  , EXTERNAL SECURITY DEFINER TRUSTED minio_nos_auth
(
  event_id    BIGINT,
  event_ts    TIMESTAMP(6),
  event_date  DATE FORMAT 'YYYY-MM-DD',
  event_hour  SMALLINT,
  customer_id INTEGER,
  product_id  INTEGER,
  amount      DECIMAL(10,2),
  channel     VARCHAR(20) CHARACTER SET LATIN,
  region      VARCHAR(20) CHARACTER SET LATIN
)
USING
(
  LOCATION    ('/s3/192.168.1.242:9000/raw/')
  PATHPATTERN ('$dir1/$dir2/$dir3/$dir4/$var5')
  STOREDAS    ('PARQUET')
);

-- Verify: shows all columns including PATHPATTERN virtual columns
HELP TABLE lakehouse_demo.sales_events_nos;
