-- Tiny smoke test: Executor DML hook detection
-- Verify that the executor hook fires on INSERT, UPDATE, DELETE on indexed table

LOAD 'temporal_rtree';
SET temporal_rtree.enable_hook_debug = on;

CREATE TABLE test_executor_hook (id int, attr int, valid_period tsrange);
CREATE INDEX idx_test_executor_hook ON test_executor_hook
  USING temporal_rtree (temporalbox(attr, valid_period) temporal_cube_ops);

-- Reset hook counters
SELECT temporal_rtree_hook_reset();

-- Baseline: no DML yet
SELECT (t.*).*
  FROM (SELECT temporal_rtree_hook_stats()) AS t;

-- Three DML statements that should each trigger executor hook
INSERT INTO test_executor_hook VALUES (1, 10, tsrange('2020-01-01', '2020-02-01'));
UPDATE test_executor_hook SET attr = 20 WHERE id = 1;
DELETE FROM test_executor_hook WHERE id = 1;

-- Verify executor hook saw all three DML statements
-- executor_dml_hits should be 3, executor_target_with_rtree_hits should be 3
SELECT (t.*).*
  FROM (SELECT temporal_rtree_hook_stats()) AS t;
