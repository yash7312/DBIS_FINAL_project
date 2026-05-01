-- Tiny smoke test: Index presence recognition
-- Verify that hooks recognize when a table has a temporal_rtree index

LOAD 'temporal_rtree';
SET temporal_rtree.enable_hook_debug = on;

CREATE TABLE test_presence_hook (id int, attr int, valid_period tsrange);

-- Reset hook counters
SELECT temporal_rtree_hook_reset();

-- Before index: INSERT should not set executor_target_with_rtree counter
INSERT INTO test_presence_hook VALUES (1, 10, tsrange('2020-01-01', '2020-02-01'));

SELECT (t.*).*
  FROM (SELECT temporal_rtree_hook_stats()) AS t;

-- Now create the temporal_rtree index
CREATE INDEX idx_test_presence_hook ON test_presence_hook
  USING temporal_rtree (temporalbox(attr, valid_period) temporal_cube_ops);

-- Reset counters
SELECT temporal_rtree_hook_reset();

-- After index: INSERT should now set executor_target_with_rtree_hits
INSERT INTO test_presence_hook VALUES (2, 20, tsrange('2020-02-01', '2020-03-01'));

-- Verify executor hook recognized the temporal_rtree index
-- executor_dml_hits should be 1, executor_target_with_rtree_hits should be 1
SELECT (t.*).*
  FROM (SELECT temporal_rtree_hook_stats()) AS t;
