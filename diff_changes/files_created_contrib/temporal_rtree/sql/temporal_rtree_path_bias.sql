-- Test: Planner path biasing with force_rtree_paths GUC
-- Verify that temporal_rtree paths are biased downward in cost when force_rtree_paths is enabled

LOAD 'temporal_rtree';
SET temporal_rtree.enable_hook_debug = on;
SET temporal_rtree.force_rtree_paths = off;

CREATE TABLE test_path_bias (id int, attr int, valid_period tsrange);
CREATE INDEX idx_test_path_bias ON test_path_bias
  USING temporal_rtree (temporalbox(attr, valid_period) temporal_cube_ops);

-- Insert test data
INSERT INTO test_path_bias
SELECT g, 10 + g % 50, tsrange(timestamp '2020-01-01' + (g || ' hours')::interval,
                                 timestamp '2020-01-02' + (g || ' hours')::interval, '[)')
FROM generate_series(1, 100) AS g;

-- Reset hook counters
SELECT temporal_rtree_hook_reset();

-- Baseline: Without forced paths, planner chooses naturally
EXPLAIN (ANALYZE OFF)
  SELECT * FROM test_path_bias
  WHERE temporalbox(attr, valid_period) && temporalbox_range(10, '2020-01-01', '2020-12-31');

-- Check stats: path_bias_applied should be 0
SELECT (t.*).*
  FROM (SELECT temporal_rtree_hook_stats()) AS t;

-- Reset and enable forced path biasing
SELECT temporal_rtree_hook_reset();
SET temporal_rtree.force_rtree_paths = on;

-- With forced paths: temporal_rtree index should be biased cheaper
EXPLAIN (ANALYZE OFF)
  SELECT * FROM test_path_bias
  WHERE temporalbox(attr, valid_period) && temporalbox_range(10, '2020-01-01', '2020-12-31');

-- Check stats: path_bias_applied should be > 0
SELECT (t.*).*
  FROM (SELECT temporal_rtree_hook_stats()) AS t;

-- Disable for cleanup
SET temporal_rtree.force_rtree_paths = off;
