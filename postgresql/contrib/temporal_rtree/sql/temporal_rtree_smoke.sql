-- Smoke test: verify extension loads and the cube-based temporalbox path works
CREATE EXTENSION IF NOT EXISTS cube;
CREATE EXTENSION IF NOT EXISTS temporalbox;
CREATE EXTENSION IF NOT EXISTS temporal_rtree;

-- Check that the access method exists
SELECT amname, amtype, amhandler::regprocedure
FROM pg_am
WHERE amname = 'temporal_rtree';

-- Check operator family
SELECT opfname, opfnamespace::regnamespace
FROM pg_opfamily
WHERE opfname = 'temporal_cube_ops';

-- Check operator class
SELECT opcname, opcnamespace::regnamespace, opcintype::regtype
FROM pg_opclass
WHERE opcname = 'temporal_cube_ops';

-- Create a simple test table
CREATE TABLE temporal_data (
    id int PRIMARY KEY,
    attr int NOT NULL,
    valid_period tsrange NOT NULL,
    data text
);

-- Insert test data
INSERT INTO temporal_data VALUES
  (1, 10, tsrange('2020-01-01', '2020-01-02', '[)'), 'history'),
  (2, 10, tsrange('2020-01-02', '2020-01-03', '[)'), 'history'),
  (3, 10, tsrange('2020-01-03', '2020-01-04', '[)'), 'history'),
  (4, 11, tsrange('2020-01-01', '2020-01-05', '[)'), 'other');

CREATE INDEX temporal_idx ON temporal_data USING temporal_rtree (temporalbox(attr, valid_period) temporal_cube_ops);

-- Reset hook statistics before testing
SELECT temporal_rtree_hook_reset();

-- Post-build verification: compare seq-scan truth count to forced custom-index count
SELECT count(*) AS truth_count
FROM temporal_data
WHERE temporalbox(attr, valid_period)
      && temporalbox_range(10, timestamp '2020-01-01', timestamp '2020-01-04');

SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT count(*) AS indexed_count
FROM temporal_data
WHERE temporalbox(attr, valid_period)
      && temporalbox_range(10, timestamp '2020-01-01', timestamp '2020-01-04');
SET enable_seqscan = on;
SET enable_bitmapscan = on;

SELECT CASE
         WHEN (SELECT count(*)
               FROM temporal_data
               WHERE temporalbox(attr, valid_period)
                     && temporalbox_range(10, timestamp '2020-01-01', timestamp '2020-01-04'))
              = (SELECT count(*)
               FROM temporal_data
               WHERE attr = 10
                 AND valid_period && tsrange('2020-01-01', '2020-01-04', '[)'))
         THEN 'PASS'
         ELSE 'FAIL'
       END AS correctness;

-- Verify planner hook was triggered
SELECT * FROM temporal_rtree_hook_stats();

-- Test DML hooks
INSERT INTO temporal_data VALUES (5, 12, tsrange('2020-01-05', '2020-01-06', '[)'), 'new');
UPDATE temporal_data SET valid_period = tsrange(lower(valid_period), upper(valid_period) + interval '1 day') WHERE id = 1;
DELETE FROM temporal_data WHERE id IN (2, 3);

-- Verify DML hook counters incremented
SELECT * FROM temporal_rtree_hook_stats();

SELECT indexname, indexdef
FROM pg_indexes
WHERE indexname = 'temporal_idx';

-- Cleanup
DROP INDEX temporal_idx;
DROP TABLE temporal_data;
