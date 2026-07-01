-- =============================================================
-- 01_nos_authorization.sql
-- Authorization object for NOS (Native Object Store) access to MinIO.
--
-- TD 20.00.28.81: WITH OVERRIDE LOCATION ENDPOINT is not supported.
-- The MinIO host:port is embedded directly in the LOCATION path
-- in 02_nos_foreign_table.sql as /s3/192.168.1.242:9000/bucket/...
-- =============================================================

REPLACE AUTHORIZATION lakehouse_demo.minio_nos_auth
  AS DEFINER TRUSTED
  USER     'minioadmin'
  PASSWORD 'minioadmin';

-- Verify
SELECT AuthorizationName
FROM   dbc.AuthorizationsV
WHERE  DatabaseName = 'lakehouse_demo'
  AND  AuthorizationName = 'minio_nos_auth';
