-- C2 TODO THREE: Write Workloads for Temporal Maintenance
-- Measure INSERT, UPDATE, DELETE performance across all index types
-- Including planning time, buffers, WAL bytes, and index size changes

-- Setup: Create measurement table for metrics collection
DROP TABLE IF EXISTS c2_write_metrics CASCADE;
CREATE TABLE c2_write_metrics (
    operation TEXT,
    index_type TEXT,
    batch_size INT,
    planning_ms FLOAT,
    execution_ms FLOAT,
    buffers_hit BIGINT,
    buffers_read BIGINT,
    wal_bytes BIGINT,
    index_size_bytes BIGINT,
    index_name TEXT,
    timestamp TIMESTAMP DEFAULT now()
);

-- ============================================================================
-- WORKLOAD 1: BULK INSERT (10000 rows)
-- ============================================================================

-- Query to capture INSERT metrics (template for each index type)
-- Replace :index_type and :index_expr with actual values

DO $$
DECLARE
    wal_before pg_lsn;
    wal_after pg_lsn;
    idx_size BIGINT;
    planning_ms FLOAT;
    execution_ms FLOAT;
    buffers_hit BIGINT;
    buffers_read BIGINT;
BEGIN
    -- Record WAL before
    wal_before := pg_current_wal_insert_lsn();
    
    -- Capture plan and execution time
    RAISE NOTICE 'INSERT batch started';
    
    -- INSERT 10000 rows
    INSERT INTO temporal_data(attr, valid_period, payload)
    SELECT (random()*100)::int,
           tsrange(timestamp '2024-01-01',
                   timestamp '2024-01-01' + ((random()*100+1)||' days')::interval,
                   '[)'),
           md5(random()::text)
    FROM generate_series(1, 10000);
    
    -- Record WAL after
    wal_after := pg_current_wal_insert_lsn();
    
    RAISE NOTICE 'INSERT batch completed. WAL bytes: %', 
        pg_wal_lsn_diff(wal_after, wal_before);
END $$;

-- INSERT with EXPLAIN ANALYZE
EXPLAIN (ANALYZE, BUFFERS)
INSERT INTO temporal_data(attr, valid_period, payload)
SELECT (random()*100)::int,
       tsrange(timestamp '2024-01-01',
               timestamp '2024-01-01' + ((random()*100+1)||' days')::interval,
               '[)'),
       md5(random()::text)
FROM generate_series(1, 10000);

-- ============================================================================
-- WORKLOAD 2: BULK UPDATE (close current versions for attrs 1-10)
-- ============================================================================

EXPLAIN (ANALYZE, BUFFERS)
UPDATE temporal_data
SET valid_period = tsrange(lower(valid_period), timestamp '2024-06-01', '[)')
WHERE upper_inf(valid_period)
  AND attr BETWEEN 1 AND 10;

-- ============================================================================
-- WORKLOAD 3: BULK DELETE (purge cold history from 2020-2021)
-- ============================================================================

EXPLAIN (ANALYZE, BUFFERS)
DELETE FROM temporal_data
WHERE NOT upper_inf(valid_period)
  AND valid_period && tsrange('2020-01-01'::timestamp, '2021-01-01'::timestamp, '[)');

-- ============================================================================
-- MAINTENANCE OPERATIONS
-- ============================================================================

-- VACUUM ANALYZE timing
\timing on

VACUUM ANALYZE temporal_data;

\timing off

-- Index size measurement
SELECT 
    'temporal_data'::TEXT AS table_name,
    indexrelname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_all_indexes
WHERE relname = 'temporal_data'
ORDER BY pg_relation_size(indexrelid) DESC;

-- Post-maintenance read query (representative: Query A from Family 2)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE temporalbox(attr, valid_period)
      @> temporalbox_point(10, timestamp '2024-02-01');

-- ============================================================================
-- DETAILED METRICS COLLECTION (for recording)
-- ============================================================================

-- Capture current index sizes
SELECT 
    indexrelname AS index_name,
    'index_size'::TEXT AS metric_type,
    pg_relation_size(indexrelid)::BIGINT AS metric_value,
    now() AS measurement_time
FROM pg_stat_all_indexes
WHERE relname = 'temporal_data'
ORDER BY indexrelname;

-- Capture scan and fetch stats
SELECT 
    indexrelname AS index_name,
    'idx_scan'::TEXT AS metric_type,
    idx_scan::BIGINT AS metric_value,
    now() AS measurement_time
FROM pg_stat_all_indexes
WHERE relname = 'temporal_data'
ORDER BY indexrelname;
