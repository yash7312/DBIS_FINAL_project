-- Query A/B/D: Attribute×Time Workload
-- Supported indexes: gist_attr_period (GiST on temporalbox expression), temporal_rtree
-- NOT suitable for: plain temporal indexes (none, brin, gist_period) which don't support expressions
--
-- These queries combine attribute filtering with temporal range predicates.
-- Suitable for: multi-dimensional indexing, entity timelines with attribute-specific queries.
-- Index expression: temporalbox(attr, valid_period) → 4D cube in space=(attr, time_lower, attr, time_upper)

-- Query A: Attribute point + temporal point
-- Find a specific attribute value at a specific point in time
-- This is a 2D point search in (attr, time) space
-- Expected: very low selectivity (one or few rows at exact attr and time)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS query_a_result
FROM temporal_data
WHERE temporalbox(attr, valid_period)
      @> temporalbox_point(10, timestamp '2023-06-01');

-- Query B: Attribute range (single attr) + temporal range
-- Find all versions of a specific attribute during a 5-month period
-- This is a 2D range search: attr=[X,X], time=[t1,t2)
-- Expected: moderate selectivity (depends on attr distribution and interval widths)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS query_b_result
FROM temporal_data
WHERE temporalbox(attr, valid_period)
      && temporalbox_range(10, timestamp '2023-01-01', timestamp '2023-06-01');

-- Query D: Current-side query (special case for hybrid index strategies)
-- Find current (open-ended) rows of a specific attribute before a date
-- This query is compatible with both:
//   - GiST on temporalbox (attr filtering + temporal range)
//   - Plain B-tree on (attr, lower) (for hybrid current/history decomposition)
// Expected: moderate selectivity (depends on current/history ratio and dates)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS query_d_result
FROM temporal_data
WHERE upper_inf(valid_period)
  AND attr = 10
  AND lower(valid_period) <= timestamp '2024-01-01';
