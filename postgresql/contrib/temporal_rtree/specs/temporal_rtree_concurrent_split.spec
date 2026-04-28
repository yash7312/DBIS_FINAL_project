# Isolation test: concurrent inserts with split behavior
# Tests that concurrent inserts on temporal_rtree don't cause corruption

setup
{
    CREATE EXTENSION IF NOT EXISTS temporal_rtree;
    CREATE TABLE temporal_data (
        id int,
        valid_period tsrange NOT NULL,
        data text
    );
    CREATE INDEX temporal_idx ON temporal_data USING temporal_rtree (valid_period);
}

teardown
{
    DROP TABLE temporal_data;
}

session "s1"
step "s1_insert1"  { INSERT INTO temporal_data VALUES (1, tsrange(now(), NULL), 'current'); }
step "s1_insert2"  { INSERT INTO temporal_data VALUES (2, tsrange('2020-01-01', '2021-01-01'), 'history'); }

session "s2"
step "s2_insert1"  { INSERT INTO temporal_data VALUES (3, tsrange(now(), NULL), 'concurrent_current'); }
step "s2_insert2"  { INSERT INTO temporal_data VALUES (4, tsrange('2019-01-01', '2020-01-01'), 'concurrent_old'); }

session "s3"
step "s3_select"   { SELECT COUNT(*) FROM temporal_data; }

# Concurrent insertions should complete without corruption
permutation "s1_insert1" "s2_insert1" "s1_insert2" "s2_insert2" "s3_select"
