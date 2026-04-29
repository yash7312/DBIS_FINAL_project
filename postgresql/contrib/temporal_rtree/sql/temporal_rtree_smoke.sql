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
  (1, 10, tsrange(now(), now() + interval '1 day'), 'current'),
  (2, 10, tsrange('2020-01-01', '2021-01-01'), 'history');

-- Attempt to create an index using the new AM
CREATE INDEX temporal_idx ON temporal_data USING temporal_rtree (temporalbox(attr, valid_period) temporal_cube_ops);

-- Post-build verification: compare seq-scan truth count to forced custom-index count
SELECT count(*) AS truth_count
FROM temporal_data
WHERE temporalbox(attr, valid_period)
  && temporalbox_range(10, timestamp '2019-01-01', timestamp '2025-01-01');

SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT count(*) AS indexed_count
FROM temporal_data
WHERE temporalbox(attr, valid_period)
  && temporalbox_range(10, timestamp '2019-01-01', timestamp '2025-01-01');
SET enable_seqscan = on;
SET enable_bitmapscan = on;

-- Verifying index was created
SELECT indexname, indexdef
FROM pg_indexes
WHERE indexname = 'temporal_idx';

-- Cleanup
DROP INDEX temporal_idx;
DROP TABLE temporal_data;
