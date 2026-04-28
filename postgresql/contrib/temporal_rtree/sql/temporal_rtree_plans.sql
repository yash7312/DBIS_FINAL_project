-- Test planner integration with temporal_rtree AM
CREATE EXTENSION IF NOT EXISTS temporal_rtree;

CREATE TABLE temporal_data (
    id int PRIMARY KEY,
    valid_period tsrange NOT NULL,
    attr int,
    data text
);

INSERT INTO temporal_data VALUES
  (1, tsrange(now(), NULL), 10, 'current'),
  (2, tsrange('2020-01-01', '2021-01-01'), 20, 'history'),
  (3, tsrange(now(), NULL), 30, 'current2'),
  (4, tsrange('2019-01-01', '2020-01-01'), 40, 'old history');

CREATE INDEX temporal_idx ON temporal_data USING temporal_rtree (valid_period);

-- Run a simple query and show the plan (with enable_seqscan off to force index usage)
EXPLAIN (COSTS OFF) SELECT * FROM temporal_data WHERE valid_period @> now();

-- Simple query: overlaps
EXPLAIN (COSTS OFF) SELECT * FROM temporal_data WHERE valid_period && tsrange('2020-06-01', '2020-12-31');

-- Test plan with planner costs
EXPLAIN SELECT * FROM temporal_data WHERE valid_period @> now();

-- Cleanup
DROP INDEX temporal_idx;
DROP TABLE temporal_data;
