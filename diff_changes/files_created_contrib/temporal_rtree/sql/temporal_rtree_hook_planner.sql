-- Tiny smoke test: Planner hook detection
-- Verify that the planner hook fires when running EXPLAIN on a temporalbox query

LOAD 'temporal_rtree';
SET temporal_rtree.enable_hook_debug = on;

CREATE TABLE test_planner_hook (id int, attr int, valid_period tsrange);
CREATE INDEX idx_test_planner_hook ON test_planner_hook
  USING temporal_rtree (temporalbox(attr, valid_period) temporal_cube_ops);

-- Reset hook counters
SELECT temporal_rtree_hook_reset();

-- Baseline: no queries yet
SELECT (t.*).*
  FROM (SELECT temporal_rtree_hook_stats()) AS t;

-- Planner hook should fire on EXPLAIN of temporalbox query
EXPLAIN (ANALYZE OFF)
  SELECT * FROM test_planner_hook
  WHERE temporalbox(attr, valid_period) && temporalbox_range(10, '2020-01-01', '2020-12-31');

-- Verify planner hook fired (planner_hits should be > 0)
SELECT (t.*).*
  FROM (SELECT temporal_rtree_hook_stats()) AS t;
