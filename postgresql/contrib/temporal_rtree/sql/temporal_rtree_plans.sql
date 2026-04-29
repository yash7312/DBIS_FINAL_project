-- Test planner integration with temporal_rtree AM
CREATE EXTENSION IF NOT EXISTS temporal_rtree;

CREATE TABLE temporal_data (
    id int PRIMARY KEY,
    attr int NOT NULL,
    valid_period tsrange NOT NULL,
    data text
);

INSERT INTO temporal_data VALUES
  (1, 10, tsrange('2020-01-01', '2020-01-02', '[)'), 'history'),
  (2, 10, tsrange('2020-01-02', '2020-01-03', '[)'), 'history'),
  (3, 11, tsrange('2020-01-01', '2020-01-04', '[)'), 'other'),
  (4, 12, tsrange('2020-01-03', '2020-01-04', '[)'), 'other');

CREATE INDEX temporal_idx ON temporal_data USING temporal_rtree (temporalbox(attr, valid_period) temporal_cube_ops);

-- Reset statistics before testing
SELECT temporal_rtree_hook_reset();

SET enable_seqscan = off;
SET enable_bitmapscan = off;

EXPLAIN (COSTS OFF)
SELECT *
FROM temporal_data
WHERE temporalbox(attr, valid_period)
      && temporalbox_range(10, timestamp '2020-01-01', timestamp '2020-01-04');

-- Verify planner hook fired during plan phase
SELECT planner_hits, planner_rtree_eligible_hits FROM temporal_rtree_hook_stats();

EXPLAIN (COSTS OFF)
SELECT *
FROM temporal_data
WHERE temporalbox(attr, valid_period)
      @> temporalbox_point(10, timestamp '2020-01-02');

-- Verify second query also triggered planner hook
SELECT planner_hits FROM temporal_rtree_hook_stats();

RESET enable_seqscan;
RESET enable_bitmapscan;

DROP INDEX temporal_idx;
DROP TABLE temporal_data;
