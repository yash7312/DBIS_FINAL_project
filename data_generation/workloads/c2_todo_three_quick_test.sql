-- C2 TODO THREE: Quick Write Workload Test
-- Standalone SQL to verify write performance measurement approach
-- Run against existing temporal_data table

-- Drop old metrics if exists
DROP TABLE IF EXISTS c2_write_metrics CASCADE;

-- Create metrics table for recording results
CREATE TABLE c2_write_metrics (
    test_id SERIAL PRIMARY KEY,
    operation VARCHAR(50),          -- INSERT, UPDATE, DELETE, VACUUM, REINDEX
    index_type VARCHAR(100),        -- none, btree, brin, gist_period, gist_attr_period, temporal_rtree
    batch_size INT,
    planning_time_ms FLOAT,
    execution_time_ms FLOAT,
    buffers_shared_hit BIGINT,
    buffers_shared_read BIGINT,
    wal_bytes_generated BIGINT,
    index_size_before_bytes BIGINT,
    index_size_after_bytes BIGINT,
    table_rows_before BIGINT,
    table_rows_after BIGINT,
    measured_at TIMESTAMP DEFAULT now()
);

-- Setup: Get baseline measurements
\set on_error_rollback on

-- Show current table size
SELECT count(*) AS total_rows FROM temporal_data;

-- Show current index sizes
SELECT 
    indexrelname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_all_indexes
WHERE relname = 'temporal_data'
ORDER BY indexrelname;

-- ============================================================
-- Workload 1: INSERT Batch (10k rows)
-- ============================================================

EXPLAIN (ANALYZE, BUFFERS, TIMING)
INSERT INTO temporal_data(attr, valid_period, payload)
SELECT (random()*100)::int,
       tsrange(timestamp '2024-01-01',
               timestamp '2024-01-01' + ((random()*100+1)||' days')::interval,
               '[)'),
       md5(random()::text)
FROM generate_series(1, 10000);

-- Verify insertion succeeded
SELECT count(*) AS total_rows_after_insert FROM temporal_data;

-- ============================================================
-- Workload 2: UPDATE Batch (close current versions for attr 1-10)
-- ============================================================

EXPLAIN (ANALYZE, BUFFERS, TIMING)
UPDATE temporal_data
SET valid_period = tsrange(lower(valid_period), timestamp '2024-06-01', '[)')
WHERE upper_inf(valid_period)
  AND attr BETWEEN 1 AND 10
LIMIT 5000;

-- Verify update succeeded
SELECT count(*) AS rows_with_closed_period 
FROM temporal_data 
WHERE NOT upper_inf(valid_period);

-- ============================================================
-- Workload 3: DELETE Batch (purge cold history 2020-2021)
-- ============================================================

EXPLAIN (ANALYZE, BUFFERS, TIMING)
DELETE FROM temporal_data
WHERE NOT upper_inf(valid_period)
  AND valid_period && tsrange('2020-01-01'::timestamp, '2021-01-01'::timestamp, '[)');

-- Verify deletion succeeded
SELECT count(*) AS remaining_rows FROM temporal_data;

-- ============================================================
-- Maintenance: VACUUM ANALYZE
-- ============================================================

\timing on
VACUUM ANALYZE temporal_data;
\timing off

-- Show index statistics after maintenance
SELECT 
    indexrelname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_all_indexes
WHERE relname = 'temporal_data'
ORDER BY indexrelname;

-- ============================================================
-- Post-maintenance read query (Query A from workload family 2)
-- ============================================================

EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT count(*)
FROM temporal_data
WHERE temporalbox(attr, valid_period)
      @> temporalbox_point(10, timestamp '2024-02-01');

-- ============================================================
-- Index Statistics Summary
-- ============================================================

SELECT 
    'pg_stat_all_indexes' AS source,
    indexrelname AS index_name,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size_readable,
    pg_relation_size(indexrelid) AS index_size_bytes,
    idx_scan AS total_scans,
    idx_tup_read AS tuples_read,
    idx_tup_fetch AS tuples_fetched,
    now() AS measured_at
FROM pg_stat_all_indexes
WHERE relname = 'temporal_data'
ORDER BY pg_relation_size(indexrelid) DESC;

-- Show results in CSV format for easy import
.mode csv
SELECT 
    indexrelname,
    pg_relation_size(indexrelid),
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_all_indexes
WHERE relname = 'temporal_data'
ORDER BY indexrelname;
