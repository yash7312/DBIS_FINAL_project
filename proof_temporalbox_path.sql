\echo '=== Stage 1: Non-partial diagnostic expression index ==='
CREATE EXTENSION IF NOT EXISTS cube;
DROP INDEX IF EXISTS idx_temporalbox_all_gist;
CREATE INDEX idx_temporalbox_all_gist
ON temporal_data
USING gist (temporalbox(attr, valid_period));
VACUUM ANALYZE temporal_data;
SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE temporalbox(attr, valid_period)
      @> temporalbox_point(10, timestamp '2023-06-01');
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE temporalbox(attr, valid_period)
      && temporalbox_range(10, timestamp '2023-01-01', timestamp '2023-06-01');

\echo '=== Stage 2: Partial hybrid production indexes + history predicate ==='
DROP INDEX IF EXISTS idx_temporalbox_all_gist;
DROP INDEX IF EXISTS idx_hst_gist;
DROP INDEX IF EXISTS idx_current_attr_start;
DROP INDEX IF EXISTS idx_current_start;
CREATE INDEX idx_hst_gist
ON temporal_data
USING gist (temporalbox(attr, valid_period))
WHERE NOT upper_inf(valid_period);
CREATE INDEX idx_current_attr_start
ON temporal_data (attr, lower(valid_period))
WHERE upper_inf(valid_period);
CREATE INDEX idx_current_start
ON temporal_data (lower(valid_period))
WHERE upper_inf(valid_period);
VACUUM ANALYZE temporal_data;
SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE NOT upper_inf(valid_period)
  AND temporalbox(attr, valid_period)
      @> temporalbox_point(10, timestamp '2023-06-01');
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temporal_data
WHERE NOT upper_inf(valid_period)
  AND temporalbox(attr, valid_period)
      && temporalbox_range(10, timestamp '2023-01-01', timestamp '2023-06-01');

\echo '=== Stage 2b: Canonical decomposed hybrid query ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM (
    SELECT 1
    FROM temporal_data
    WHERE NOT upper_inf(valid_period)
      AND temporalbox(attr, valid_period)
          @> temporalbox_point(10, timestamp '2023-06-01')
    UNION ALL
    SELECT 1
    FROM temporal_data
    WHERE upper_inf(valid_period)
      AND attr = 10
      AND lower(valid_period) <= timestamp '2023-06-01'
) AS q;
