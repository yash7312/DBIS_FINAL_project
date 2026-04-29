-- Q1–Q7: Plain Temporal Workload
-- Supported indexes: none, brin, gist_period (direct tsrange AM paths)
-- NOT comparable with temporal_rtree (which requires temporalbox expressions)
--
-- These queries test pure temporal range predicates without attribute filtering.
-- Suitable for: general-purpose temporal tables, event logs, audit trails.

-- Q1: Point containment (present day)
-- Count rows where the current timestamp is within their validity period
-- Expected: moderate selectivity (depends on current/history ratio and interval widths)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS q1_result
FROM temporal_data
WHERE valid_period @> timestamp '2023-06-01';

-- Q2: Point containment (future)
-- Count rows where a future timestamp is within their validity period
-- Expected: low selectivity (most rows closed by then)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS q2_result
FROM temporal_data
WHERE valid_period @> timestamp '2027-06-01';

-- Q3: Short range overlap
-- Find rows that overlap a 10-day window (short-range query)
-- Expected: low-to-moderate selectivity
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS q3_result
FROM temporal_data
WHERE valid_period && tsrange('2023-05-01'::timestamp, '2023-05-10'::timestamp, '[)');

-- Q4: Medium range overlap
-- Find rows that overlap a 5-month window (medium-range query)
-- Expected: moderate selectivity
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS q4_result
FROM temporal_data
WHERE valid_period && tsrange('2023-01-01'::timestamp, '2023-06-01'::timestamp, '[)');

-- Q5: Long range overlap
-- Find rows that overlap a 3-year window (long-range query)
-- Expected: high selectivity (most rows overlap a large window)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS q5_result
FROM temporal_data
WHERE valid_period && tsrange('2022-01-01'::timestamp, '2025-01-01'::timestamp, '[)');

-- Q6: Range contains interval
-- Find rows whose period contains a specific interval
-- This is a converse containment query (inverse of Q1 logic)
-- Expected: low selectivity (rare for a row to fully contain a specific range)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS q6_result
FROM temporal_data
WHERE valid_period @> tsrange('2023-03-01'::timestamp, '2023-03-10'::timestamp, '[)');

-- Q7: Range contained-by interval
-- Find rows whose period is fully contained within a year
-- Expected: moderate-to-high selectivity (many rows created/closed within a year)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS q7_result
FROM temporal_data
WHERE valid_period <@ tsrange('2023-01-01'::timestamp, '2024-01-01'::timestamp, '[)');
