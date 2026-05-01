-- Final hook regression: planner and executor hooks detect temporal_rtree usage.

CREATE EXTENSION IF NOT EXISTS cube;
CREATE EXTENSION IF NOT EXISTS temporalbox;
CREATE EXTENSION IF NOT EXISTS temporal_rtree;

CREATE TABLE hook_test (
    id int PRIMARY KEY,
    attr int NOT NULL,
    valid_period tsrange NOT NULL,
    data text
);

CREATE INDEX hook_idx ON hook_test
  USING temporal_rtree (temporalbox(attr, valid_period) temporal_cube_ops);

SELECT temporal_rtree_hook_reset();

SELECT * FROM temporal_rtree_hook_stats();

SET enable_seqscan = off;
SET enable_bitmapscan = off;

EXPLAIN (COSTS OFF)
SELECT *
FROM hook_test
WHERE temporalbox(attr, valid_period)
      && temporalbox_range(10, timestamp '2020-01-01', timestamp '2020-12-31');

RESET enable_seqscan;
RESET enable_bitmapscan;

SELECT * FROM temporal_rtree_hook_stats();

INSERT INTO hook_test VALUES
  (1, 10, tsrange('2020-01-01', '2020-01-02'), 'test1');

UPDATE hook_test
SET valid_period = tsrange(lower(valid_period), upper(valid_period) + interval '1 day')
WHERE id = 1;

DELETE FROM hook_test WHERE id = 1;

SELECT * FROM temporal_rtree_hook_stats();

DROP INDEX hook_idx;
DROP TABLE hook_test;