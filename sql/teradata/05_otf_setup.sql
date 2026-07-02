-- =============================================================
-- 05_otf_setup.sql
-- Configure OTF (Open Table Format) Datalake access to the
-- Iceberg table registered in the Hive Metastore.
--
-- DATALAKE objects live in TD_SERVER_DB.
-- EXTERNAL SECURITY DEFINER TRUSTED resolves auth objects from
-- the DATALAKE's owner database — which is always TD_SERVER_DB.
-- Auth objects MUST be created in TD_SERVER_DB, NOT in the
-- session user's home database.
--
-- Contrast with FOREIGN TABLE (NOS in 01/02): those auth objects
-- live in lakehouse_demo because DEFINER TRUSTED resolves from
-- the foreign table's owner database.
--
-- Table reference after setup: lakehouse_iceberg.demo.sales_events
-- =============================================================

-- Suppress "object not found" on DROP DATALAKE so re-runs are safe
.SET ERRORLEVEL 3807 SEVERITY 0

-- Auth objects for DATALAKE must be in TD_SERVER_DB
DATABASE TD_SERVER_DB;

-- HMS Thrift auth: HMS does not authenticate client connections on port 9083,
-- so these credentials are never checked.  Teradata requires non-empty values
-- (empty → error 3706), so 'anonymous'/'anonymous' is the conventional placeholder.
-- Note: HIVE_DB_USER/HIVE_DB_PASSWORD in .env are unrelated — those are the
-- MySQL credentials the HMS Java service uses for its own backend connection.
REPLACE AUTHORIZATION hms_catalog_auth
  AS DEFINER TRUSTED
  USER     'anonymous'
  PASSWORD 'anonymous';

-- MinIO storage credentials
REPLACE AUTHORIZATION minio_storage_auth
  AS DEFINER TRUSTED
  USER     'minioadmin'
  PASSWORD 'minioadmin';

-- Switch back to user database before DROP/CREATE DATALAKE
DATABASE lakehouse_demo;

DROP DATALAKE lakehouse_iceberg;

-- Restore normal error handling after the DROP
.SET ERRORLEVEL 3807 SEVERITY 8

-- Need to grant CREATE SERVER to DBC so that the DATALAKE can create a server object in TD_SERVER_DB.
GRANT CREATE SERVER ON TD_SERVER_DB TO DBC WITH GRANT OPTION;

CREATE DATALAKE lakehouse_iceberg
  EXTERNAL SECURITY DEFINER TRUSTED CATALOG hms_catalog_auth,
  EXTERNAL SECURITY DEFINER TRUSTED STORAGE minio_storage_auth
USING
  CATALOG_TYPE         ('hive')
  CATALOG_LOCATION     ('thrift://192.168.1.210:9083')
  STORAGE_LOCATION     ('s3://iceberg/warehouse/')
  STORAGE_ENDPOINT     ('http://192.168.1.210:9000')
  S3_PATH_STYLE_ACCESS ('true')
  S3_SSL_ENABLED       ('false')
  STORAGE_REGION       ('us-east-1')
  S3_MAX_TASK          ('1000')
  S3_MAX_THREADS       ('1000')
  S3_MAX_CONNECTIONS   ('5000')
TABLE FORMAT iceberg;

-- Verify: lists HMS namespaces visible in the Hive catalog.
-- 'demo' appears after create_iceberg.py has run successfully.
HELP DATALAKE lakehouse_iceberg;
