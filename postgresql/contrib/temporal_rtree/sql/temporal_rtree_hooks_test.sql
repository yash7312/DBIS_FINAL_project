-- Test: Verify temporal_rtree hooks are firing correctly
-- Purpose: Checkpoint C1 - Confirm planner and executor hooks detect temporal_rtree usage

SET temporal_rtree.enable_hook_debug = on;
SET temporal_rtree.log_dml = on;

\echo --- Test 1: Create table and index ---
CREATE TABLE hook_test (
    id int PRIMARY KEY,
    attr int NOT NULL,
    valid_period tsrange NOT NULL,
    data text
);

\echo --- Test 2: Planner hook should NOT fire (no temporal_rtree index yet) ---
SELECT schema_name, table_name, index_name
FROM information_schema.tables t
  LEFT JOIN information_schema.schemata s ON t.table_schema = s.schema_name
WHERE t.table_name = 'hook_test';

\echo --- Test 3: Create temporal_rtree index (extension must be loaded) ---
CREATE EXTENSION IF NOT EXISTS cube;
CREATE EXTENSION IF NOT EXISTS temporalbox;
CREATE EXTENSION IF NOT EXISTS temporal_rtree;

CREATE INDEX hook_idx ON hook_test
  USING temporal_rtree (temporalbox(attr, valid_period) temporal_cube_ops);

\echo --- Test 4: Planner hook SHOULD fire on this query (has temporalbox in WHERE) ---
-- Expected log: temporal_rtree planner hook: has_temporalbox=1 has_rtree_idx=1
EXPLAIN (COSTS OFF)
SELECT *
FROM hook_test
WHERE temporalbox(attr, valid_period)
      && temporalbox_range(10, timestamp '2020-01-01', timestamp '2020-12-31');

\echo --- Test 5: Executor hook SHOULD fire on INSERT ---
-- Expected log: temporal_rtree executor hook: INSERT statement on temporal_rtree-indexed relation
INSERT INTO hook_test VALUES
  (1, 10, tsrange('2020-01-01', '2020-01-02'), 'test1'),
  (2, 10, tsrange('2020-01-02', '2020-01-03'), 'test2');

\echo --- Test 6: Executor hook SHOULD fire on UPDATE ---
-- Expected log: temporal_rtree executor hook: UPDATE statement on temporal_rtree-indexed relation
UPDATE hook_test
SET valid_period = tsrange(lower(valid_period), upper(valid_period) + interval '1 day')
WHERE id = 1;

\echo --- Test 7: Executor hook SHOULD fire on DELETE ---
-- Expected log: temporal_rtree executor hook: DELETE statement on temporal_rtree-indexed relation
DELETE FROM hook_test WHERE id = 2;

\echo --- Test 8: Cleanup ---
DROP INDEX hook_idx;
DROP TABLE hook_test;

\echo --- Hook test complete. Check PostgreSQL logs for hook messages. ---
