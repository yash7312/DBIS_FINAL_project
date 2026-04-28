-- ============================================================================
-- CORE READ WORKLOAD: Q1–Q7
-- Exact baseline queries from checkpoint specification
-- Coverage: point containment, low-selectivity, ranges, containment operators
-- ============================================================================

-- Q1: Point containment (past date) - tests history index effectiveness
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> timestamp '2023-06-01';

-- Q2: Point containment (future date) - tests current index effectiveness
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> timestamp '2027-01-01';

-- Q3: Short range overlap (10 days) - tight selectivity test
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2023-05-01','2023-05-10','[)');

-- Q4: Medium range overlap (5 months) - broader coverage test
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2023-01-01','2023-06-01','[)');

-- Q5: Large range overlap (3 years) - full dataset scan tendencies
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2022-01-01','2025-01-01','[)');

-- Q6: Temporal containment (10-day range) - AM must verify full containment
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> tsrange('2023-03-01','2023-03-10','[)');

-- Q7: Contained-by (2023 year) - reverse containment operator
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period <@ tsrange('2023-01-01','2024-01-01','[)');

-- ============================================================================
-- COMPOSITE WORKLOAD: Query A, B, D (Hybrid Current-History Indexing)
-- Requires temporalbox extension for 2D temporal indexing
-- ============================================================================

-- Query A: NEGATIVE CONTROL (whole-table temporalbox predicate)
-- This intentionally omits NOT upper_inf(valid_period) and may not imply
-- the history-side partial index predicate.
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE temporalbox(attr, valid_period)
      @> temporalbox_point(10, timestamp '2023-06-01');

-- Query B: NEGATIVE CONTROL (whole-table temporalbox overlap)
-- This intentionally omits NOT upper_inf(valid_period).
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE temporalbox(attr, valid_period)
      && temporalbox_range(10, timestamp '2023-01-01', timestamp '2023-06-01');

-- Query H: History-only temporalbox point containment (partial-index compatible)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE NOT upper_inf(valid_period)
  AND temporalbox(attr, valid_period)
  @> temporalbox_point(10, timestamp '2023-06-01');

-- Query I: History-only temporalbox overlap (partial-index compatible)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE NOT upper_inf(valid_period)
  AND temporalbox(attr, valid_period)
  && temporalbox_range(10, timestamp '2023-01-01', timestamp '2023-06-01');

-- Query D: Current rows by attribute and lower bound
-- Index: idx_current_attr_start on (attr, lower(valid_period)) for current rows only
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE upper_inf(valid_period)
  AND attr = 10
  AND lower(valid_period) <= timestamp '2024-01-01';

-- ============================================================================
-- CRITICAL DECOMPOSITION: Hybrid Query with Separate Index Paths
-- Key insight: Planner cannot use partial indexes without explicit UNION
-- This query allows:
--   1. idx_current_attr_start on current rows (upper_inf = TRUE)
--   2. idx_hst_gist on history rows (NOT upper_inf = TRUE)
-- Without decomposition, planner must scan entire table
-- ============================================================================

-- Query HYBRID_DECOMPOSED: Separated current/history union for index optimization
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM (
    -- History rows: indexed by idx_hst_gist (temporalbox(attr, valid_period))
    SELECT 1
    FROM temporal_data
    WHERE NOT upper_inf(valid_period)
      AND temporalbox(attr, valid_period)
            @> temporalbox_point(10, timestamp '2023-06-01')

    UNION ALL

    -- Current rows: indexed by idx_current_attr_start (attr, lower)
    SELECT 1
    FROM temporal_data
    WHERE upper_inf(valid_period)
      AND attr = 10
      AND lower(valid_period) <= timestamp '2023-06-01'
) AS q;

-- ============================================================================
-- BASELINE STATISTICS (for validation post-load)
-- ============================================================================

-- Dataset composition
SELECT 
    COUNT(*) as total_rows,
    COUNT(*) FILTER (WHERE upper_inf(valid_period)) as current_rows,
    COUNT(*) FILTER (WHERE NOT upper_inf(valid_period)) as history_rows,
    COUNT(DISTINCT attr) as attr_cardinality,
    pg_size_pretty(pg_total_relation_size('temporal_data')) as table_size
FROM temporal_data;

-- Attribute distribution (Top 20, for Zipf validation)
SELECT 
    attr,
    COUNT(*) as count,
    COUNT(*) FILTER (WHERE upper_inf(valid_period)) as current,
    COUNT(*) FILTER (WHERE NOT upper_inf(valid_period)) as history,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM temporal_data), 2) as pct
FROM temporal_data
GROUP BY attr
ORDER BY count DESC
LIMIT 20;

-- Temporal distribution (verify chronological insertion order where expected)
SELECT 
    lower(valid_period) as period_start,
    COUNT(*) as count
FROM temporal_data
GROUP BY lower(valid_period)
ORDER BY lower(valid_period)
LIMIT 10;
