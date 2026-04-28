-- Smoke test: verify extension loads and AM is registered
CREATE EXTENSION IF NOT EXISTS temporal_rtree;

-- Check that the access method exists
SELECT amname, amtype, amhandler::regprocedure
FROM pg_am
WHERE amname = 'temporal_rtree';

-- Check operator family
SELECT opfname, opfnamespace::regnamespace
FROM pg_opfamily
WHERE opfname = 'temporal_tsrange_ops';

-- Check operator class
SELECT opcname, opcnamespace::regnamespace, opcintype::regtype
FROM pg_opclass
WHERE opcname = 'temporal_tsrange_ops';

-- Create a simple test table
CREATE TABLE temporal_data (
    id int PRIMARY KEY,
    valid_period tsrange NOT NULL,
    data text
);

-- Insert test data
INSERT INTO temporal_data VALUES
  (1, tsrange(now(), now() + interval '1 day'), 'current'),
  (2, tsrange('2020-01-01', '2021-01-01'), 'history');

-- Attempt to create an index using the new AM
CREATE INDEX temporal_idx ON temporal_data USING temporal_rtree (valid_period);

-- Verifying index was created
SELECT indexname, indexdef
FROM pg_indexes
WHERE indexname = 'temporal_idx';

-- Cleanup
DROP INDEX temporal_idx;
DROP TABLE temporal_data;
