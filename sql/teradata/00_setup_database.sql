-- =============================================================
-- 00_setup_database.sql
-- Create the lakehouse_demo database on Teradata.
-- Run as DBC or a user with CREATE DATABASE privilege.
-- =============================================================

CREATE DATABASE lakehouse_demo
  FROM dbc
  AS PERM = 10e9;   -- 10 GB permanent space

-- Grant access if running demo as a non-DBC user (optional):
-- GRANT ALL ON lakehouse_demo TO <your_user>
