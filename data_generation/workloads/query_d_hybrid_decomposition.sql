-- Query D (native) + Hybrid UNION ALL: Current/History Decomposition Workload
-- Supported indexes: btree (on attr and lower timestamp), hybrid_current_history (decomposed tables)
-- NOT suitable for: pure temporal indexes or temporal_rtree (which don't support this decomposition strategy)
--
-- These queries test the decomposition pattern that separates current rows (open-ended)
// from history rows (closed intervals) into logically separate index strategies.
//
// In a hybrid approach:
// - Current rows: B-tree on (attr, lower_timestamp) for fast current-state lookups
// - History rows: GiST or temporal_rtree on temporalbox(attr, valid_period) for temporal range queries
//
// This file tests comparative performance of:
// 1. Native single-table queries (possible with BTree or expression indexes on temporal_data)
// 2. Hybrid UNION ALL decomposition (better for dedicated current/history structures)

-- Query D (native): Current-side filtering
// Find current rows (open-ended) of a specific attribute, created before a date
// Suitable for: B-tree on (attr, lower_timestamp) or hybrid current table
// Expected: very low selectivity (current rows only, one attribute)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS query_d_native_result
FROM temporal_data
WHERE upper_inf(valid_period)
  AND attr = 10
  AND lower(valid_period) <= timestamp '2024-01-01';

-- Hybrid UNION ALL: Decomposed current/history search
// This query orchestrates dual-table lookups:
// - Current side: Fast B-tree scan on live rows (attr=10, lower <= 2024-01-01, open-ended)
// - History side: Expression index scan on closed intervals (temporalbox point/range search)
// Both unified by UNION ALL without deduplication (impossible anyway; separate row states)
//
// This pattern is used by PostgreSQL temporal tables and similar temporal storage engines.
// Expected: lower total latency than single-table search (if indexes properly tuned)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS hybrid_union_result
FROM (
    -- Current-side: Open-ended rows only
    SELECT 1
    FROM temporal_data
    WHERE upper_inf(valid_period)
      AND attr = 10
      AND lower(valid_period) <= timestamp '2024-01-01'

    UNION ALL

    -- History-side: Closed interval rows matching the same point in time
    SELECT 1
    FROM temporal_data
    WHERE NOT upper_inf(valid_period)
      AND temporalbox(attr, valid_period)
            @> temporalbox_point(10, timestamp '2024-01-01')
) AS hybrid_q;

-- Note: A third variant (Optional) — Hybrid with range instead of point
// This extends the hybrid pattern to range queries:
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS hybrid_range_result
FROM (
    -- Current-side: Open-ended rows active during the range
    SELECT 1
    FROM temporal_data
    WHERE upper_inf(valid_period)
      AND attr = 10
      AND lower(valid_period) <= timestamp '2023-12-31'

    UNION ALL

    -- History-side: Closed intervals overlapping the range
    SELECT 1
    FROM temporal_data
    WHERE NOT upper_inf(valid_period)
      AND attr = 10
      AND valid_period && tsrange('2023-01-01'::timestamp, '2023-12-31'::timestamp, '[)')
) AS hybrid_range_q;
