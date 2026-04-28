-- ============================================================================
-- CHECKPOINT C2 TODO THREE: Write and Maintenance Workloads
-- 
-- Stress tests for temporal index access methods:
--   1. Current-row closure: Open-ended → historical + new current versions
--   2. History widening: Expand bounds to trigger reinsertion and splits
--   3. History purge: Delete cold history, stress bulk delete and vacuum
--   4. Hot attribute update: Concentrated updates on popular attributes
--
-- Each workload is designed to test AM robustness under concurrent mutations,
-- page split quality, dead tuple handling, and recovery characteristics.
-- ============================================================================

-- ============================================================================
-- WORKLOAD 1: CURRENT-ROW CLOSURE
-- Purpose: Simulate temporal versioning workflow
--   - Close active (current) rows at a cutoff timestamp
--   - Insert new current versions starting from cutoff
--   - Tests: INSERT performance, page splits, concurrent structure evolution
-- ============================================================================

-- Baseline: Count current rows before closure
SELECT COUNT(*) as current_rows_before
FROM temporal_data
WHERE upper_inf(valid_period);

-- Capture closure timestamp
SELECT current_timestamp as closure_ts;

-- Step 1: Close current rows for hot attributes (attr 1-10)
-- This converts open-ended ranges to finite intervals
UPDATE temporal_data
SET valid_period = tsrange(lower(valid_period), timestamp '2024-06-01 00:00:00', '[)')
WHERE upper_inf(valid_period)
  AND attr BETWEEN 1 AND 10;

-- Measure: Check rows transitioned
SELECT COUNT(*) as transitioned_to_history
FROM temporal_data
WHERE NOT upper_inf(valid_period)
  AND attr BETWEEN 1 AND 10
  AND upper(valid_period) = timestamp '2024-06-01 00:00:00';

-- Step 2: Insert new current versions from closed rows
-- Simulates "version bump" in temporal applications
INSERT INTO temporal_data(attr, valid_period, payload)
SELECT 
  attr,
  tsrange(timestamp '2024-06-01 00:00:00', NULL, '[)') as valid_period,
  payload || '_v2' as payload
FROM temporal_data
WHERE attr BETWEEN 1 AND 10
  AND upper(valid_period) = timestamp '2024-06-01 00:00:00'
LIMIT 10000;

-- Verify: Check new current rows exist
SELECT COUNT(*) as new_current_rows
FROM temporal_data
WHERE upper_inf(valid_period)
  AND attr BETWEEN 1 AND 10
  AND lower(valid_period) = timestamp '2024-06-01 00:00:00';

-- ============================================================================
-- WORKLOAD 2: HISTORY WIDENING / OVERLAP CHURN
-- Purpose: Expand temporal intervals to create overlaps and reinsertion patterns
--   - Extend lower and upper bounds of finite intervals
--   - Tests: Page reinsertion, overlap complexity, split algorithm quality
-- ============================================================================

-- Baseline: Sample data before widening
SELECT COUNT(*) as finite_rows_before
FROM temporal_data
WHERE NOT upper_inf(valid_period)
  AND attr BETWEEN 20 AND 30;

-- Step 1: Widen lower bounds (retroactive effect)
-- Simulate scenario where historical record becomes relevant to earlier period
UPDATE temporal_data
SET valid_period = tsrange(
      lower(valid_period) - interval '3 days',
      upper(valid_period),
      '[)'
    )
WHERE NOT upper_inf(valid_period)
  AND attr BETWEEN 20 AND 30
  AND lower(valid_period) >= timestamp '2023-06-01'
  AND lower(valid_period) <= timestamp '2023-12-31';

-- Step 2: Widen upper bounds (extend history)
UPDATE temporal_data
SET valid_period = tsrange(
      lower(valid_period),
      upper(valid_period) + interval '3 days',
      '[)'
    )
WHERE NOT upper_inf(valid_period)
  AND attr BETWEEN 20 AND 30
  AND upper(valid_period) >= timestamp '2023-06-01'
  AND upper(valid_period) <= timestamp '2023-12-31';

-- Verify: Check widened intervals (should be longer)
SELECT 
  COUNT(*) as widened_rows,
  AVG(upper(valid_period) - lower(valid_period)) as avg_width_after
FROM temporal_data
WHERE NOT upper_inf(valid_period)
  AND attr BETWEEN 20 AND 30;

-- ============================================================================
-- WORKLOAD 3: HISTORY PURGE (Cold Data Deletion)
-- Purpose: Remove old historical rows outside retention window
--   - Delete rows closed before cutoff date
--   - Tests: ambulkdelete performance, page reuse, index pruning
-- ============================================================================

-- Baseline: Count rows to be deleted
SELECT COUNT(*) as rows_to_delete
FROM temporal_data
WHERE NOT upper_inf(valid_period)
  AND upper(valid_period) < timestamp '2022-06-01 00:00:00';

-- Delete cold history (old closed rows)
DELETE FROM temporal_data
WHERE NOT upper_inf(valid_period)
  AND upper(valid_period) < timestamp '2022-06-01 00:00:00';

-- Verify: Cold rows are gone
SELECT COUNT(*) as cold_rows_remaining
FROM temporal_data
WHERE NOT upper_inf(valid_period)
  AND upper(valid_period) < timestamp '2022-06-01 00:00:00';

-- ============================================================================
-- WORKLOAD 4: HOT ATTRIBUTE UPDATE (Concentrated Contention)
-- Purpose: Stress-test high-frequency attributes with concentrated updates
--   - Update bounds on hot attributes (1-5) heavily
--   - Tests: Hotspot splits, concurrent page access patterns, contention behavior
-- ============================================================================

-- Baseline: Count hot attribute rows
SELECT COUNT(*) as hot_attr_rows
FROM temporal_data
WHERE attr IN (1, 2, 3, 4, 5);

-- Step 1: Update lower bounds (time advancement)
-- Simulates moving "effective date" forward on popular entities
UPDATE temporal_data
SET valid_period = tsrange(
      lower(valid_period) + interval '1 day',
      upper(valid_period),
      '[)'
    )
WHERE attr IN (1, 2, 3, 4, 5)
  AND lower(valid_period) >= timestamp '2023-01-01'
  AND lower(valid_period) <= timestamp '2023-12-31';

-- Step 2: Update payloads (simulates data modifications)
UPDATE temporal_data
SET payload = 'updated_' || (random() * 10000)::int::text
WHERE attr IN (1, 2, 3, 4, 5)
  AND upper_inf(valid_period);

-- Verify: Check update count
SELECT COUNT(*) as hot_rows_updated
FROM temporal_data
WHERE attr IN (1, 2, 3, 4, 5)
  AND payload LIKE 'updated_%';

-- ============================================================================
-- MACRO PATTERNS: Multi-Step Bulk Operations
-- ============================================================================

-- Pattern A: Nightly batch closure (simulate daily version rollover)
-- This is run per night to close "today's" records as history
-- BEGIN;
-- UPDATE temporal_data SET valid_period = tsrange(...)
--   WHERE upper_inf(valid_period) AND lower(...) <= current_timestamp;
-- INSERT INTO temporal_data SELECT ... (new version);
-- COMMIT;

-- Pattern B: Weekly compaction (merge overlapping intervals)
-- Simulates temporal data consolidation
-- UPDATE temporal_data SET valid_period = simplified_range(...)
--   WHERE attr IN (SELECT attr FROM high_overlap_attrs);

-- Pattern C: Monthly purge (cold storage transition)
-- Simulates archive of old history
-- DELETE FROM temporal_data 
--   WHERE NOT upper_inf(valid_period) AND upper(...) < NOW() - interval '90 days';

-- ============================================================================
-- MAINTENANCE & MONITORING QUERIES
-- ============================================================================

-- 1. Index Bloat Assessment
-- Run after each workload batch to check index size growth
SELECT 
  schemaname,
  tablename,
  indexname,
  idx_scan as index_scans,
  idx_tup_read as tuples_read,
  idx_tup_fetch as tuples_fetched,
  pg_size_pretty(pg_relation_size(indexrelid)) as index_size,
  ROUND(100.0 * (pg_relation_size(indexrelid) - pg_total_relation_size(relid)) 
        / NULLIF(pg_relation_size(indexrelid), 0), 2) as dead_fraction_pct
FROM pg_stat_all_indexes
WHERE tablename = 'temporal_data'
ORDER BY indexname;

-- 2. Table Bloat Check
SELECT 
  schemaname,
  tablename,
  n_live_tup as live_tuples,
  n_dead_tup as dead_tuples,
  ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) as dead_pct,
  n_mod_since_analyze as rows_modified,
  pg_size_pretty(pg_total_relation_size(relid)) as total_size
FROM pg_stat_all_tables
WHERE tablename = 'temporal_data';

-- 3. Maintenance Impact: VACUUM Statistics
-- (Run after VACUUM to capture metrics)
SELECT 
  schemaname,
  relname,
  vacuum_count as full_vacuums,
  analyze_count as analyzes,
  last_vacuum,
  last_analyze,
  last_autovacuum
FROM pg_stat_all_tables
WHERE relname = 'temporal_data';

-- 4. Index Effectiveness (Query Performance Degradation Over Time)
-- Compare pre/post-workload for same query
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT COUNT(*) FROM temporal_data
WHERE valid_period @> timestamp '2023-06-01'
  AND attr IN (1, 2, 3, 4, 5);

-- 5. Dead Space Summary
-- Aggregate view for AM diagnosis
WITH bloat_analysis AS (
  SELECT 
    schemaname, tablename, indexname,
    pg_relation_size(indexrelid) as index_size,
    pg_total_relation_size(relid) as table_size
  FROM pg_stat_all_indexes
  WHERE tablename = 'temporal_data'
)
SELECT 
  SUM(index_size) as total_index_bytes,
  SUM(table_size) as total_table_bytes,
  ROUND(100.0 * SUM(index_size) / SUM(table_size), 2) as index_overhead_pct,
  COUNT(*) as num_indexes
FROM bloat_analysis;

-- 6. Page Distribution (for BRIN and internal structure analysis)
SELECT 
  COUNT(*) as num_pages,
  pg_size_pretty(COUNT(*) * 8192) as total_pages_size
FROM (
  SELECT ctid from temporal_data LIMIT 1000000
) t;

-- ============================================================================
-- WORKLOAD EXECUTION TEMPLATE
-- ============================================================================

-- RUN SEQUENCE (per index configuration):
--
-- 1. BASELINE QUERY PERFORMANCE (from TODO 2 Q1-Q7)
--    EXPLAIN (ANALYZE, BUFFERS) SELECT ... ;
--
-- 2. EXECUTE WORKLOAD 1: CURRENT-ROW CLOSURE
--    [Closure queries above]
--    VACUUM ANALYZE temporal_data;
--    EXPLAIN (ANALYZE, BUFFERS) SELECT ... ;  -- Re-measure Q1-Q7
--
-- 3. EXECUTE WORKLOAD 2: HISTORY WIDENING
--    [Widening queries above]
--    VACUUM ANALYZE temporal_data;
--    EXPLAIN (ANALYZE, BUFFERS) SELECT ... ;
--
-- 4. EXECUTE WORKLOAD 3: HISTORY PURGE
--    [Purge queries above]
--    VACUUM ANALYZE temporal_data;
--    REINDEX INDEX CONCURRENTLY idx_temporal_rtree;  (if applicable)
--    EXPLAIN (ANALYZE, BUFFERS) SELECT ... ;
--
-- 5. EXECUTE WORKLOAD 4: HOT ATTRIBUTE UPDATE
--    [Hot updates above]
--    VACUUM ANALYZE temporal_data;
--    EXPLAIN (ANALYZE, BUFFERS) SELECT ... ;
--
-- 6. COLLECT FINAL METRICS (bloat, maintenance)
--    [Bloat assessment queries above]

