-- =============================================================
-- 03_nos_read_validation.sql
-- Validate NOS read access and load into a native Teradata table.
-- Expected total: ~35,000 rows across 7 files.
--
-- PATHPATTERN virtual column names (confirmed via HELP TABLE):
--   dir2 SMALLINT = year  | dir3 VARCHAR = month
--   dir4 VARCHAR  = day   | var5 VARCHAR = hour
-- =============================================================

DATABASE lakehouse_demo;

-- 1. Full scan row count
SELECT COUNT(*) AS total_rows
FROM   lakehouse_demo.sales_events_nos;

-- 2. Partition pruning via PATHPATTERN virtual columns
--    dir2 = year (SMALLINT, no quotes); dir3/dir4 = month/day (VARCHAR, quoted)
SELECT  dir2        AS yr,
        dir3        AS mo,
        dir4        AS dy,
        var5        AS hr,
        COUNT(*)    AS row_count,
        SUM(amount) AS total_amount
FROM    lakehouse_demo.sales_events_nos
WHERE   dir2 = 2024 AND dir3 = '06' AND dir4 = '29'
GROUP BY 1,2,3,4
ORDER BY 4;

-- 3. Spot-check 10 rows from a specific day
SELECT TOP 10 *
FROM   lakehouse_demo.sales_events_nos
WHERE  dir2 = 2024 AND dir3 = '06' AND dir4 = '30';

-- 4. Summary by region across all files
SELECT region,
       COUNT(*)    AS events,
       SUM(amount) AS revenue,
       AVG(amount) AS avg_order
FROM   lakehouse_demo.sales_events_nos
GROUP BY region
ORDER BY revenue DESC;

-- 5. Load into a native Teradata permanent table
.SET ERRORLEVEL 3807 SEVERITY 0
DROP TABLE lakehouse_demo.sales_events_td;
.SET ERRORLEVEL 3807 SEVERITY 8

CREATE MULTISET TABLE lakehouse_demo.sales_events_td AS (
  SELECT *
  FROM   lakehouse_demo.sales_events_nos
) WITH DATA
PRIMARY INDEX (event_id);

-- 6. Verify native table
SELECT COUNT(*) AS loaded_rows FROM lakehouse_demo.sales_events_td;
