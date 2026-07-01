-- =============================================================
-- 04_nos_writeback.sql
-- Write from a native Teradata table back to MinIO as Parquet.
--
-- In TD 20.x, NOS write-back uses the WRITE_NOS TVF (Table Value Function):
--   SELECT * FROM WRITE_NOS (ON (SELECT ...) USING LOCATION ... AUTHORIZATION ...) AS d
--
-- WRITE_NOS requires a SIMPLIFIED authorization object (no AS DEFINER/INVOKER TRUSTED).
-- This is different from the DEFINER TRUSTED auth used for CREATE FOREIGN TABLE reads.
--
-- Output:  4 Parquet files (one per AMP) at:
--   s3://raw/sales_events_north_export/object_33_X_1.parquet
-- =============================================================

DATABASE lakehouse_demo;

-- Simplified auth for WRITE_NOS (plain USER/PASSWORD, no DEFINER/INVOKER TRUSTED)
REPLACE AUTHORIZATION lakehouse_demo.minio_write_auth
  USER     'minioadmin'
  PASSWORD 'minioadmin';

-- Write NORTH region rows to MinIO using WRITE_NOS TVF.
-- Returns one row per Parquet file written with NodeId, AmpId, Sequence,
-- ObjectName (full S3 path), ObjectSize (bytes), RecordCount.
SELECT * FROM WRITE_NOS (
  ON (
    SELECT event_id, event_ts, event_date, event_hour,
           customer_id, product_id, amount, channel, region
    FROM   lakehouse_demo.sales_events_td
    WHERE  region = 'NORTH'
  )
  USING
  LOCATION   ('/s3/192.168.1.242:9000/raw/sales_events_north_export/')
  AUTHORIZATION (minio_write_auth)
  STOREDAS   ('PARQUET')
  COMPRESSION ('SNAPPY')
) AS d;

-- Verify: create a NOS foreign table over the exported files and count rows.
-- (NOS read uses DEFINER TRUSTED auth with host:port in LOCATION.)
CREATE FOREIGN TABLE lakehouse_demo.sales_events_nos_out_verify
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
  LOCATION ('/s3/192.168.1.242:9000/raw/sales_events_north_export/')
  STOREDAS ('PARQUET')
);

SELECT COUNT(*) AS exported_rows FROM lakehouse_demo.sales_events_nos_out_verify;
