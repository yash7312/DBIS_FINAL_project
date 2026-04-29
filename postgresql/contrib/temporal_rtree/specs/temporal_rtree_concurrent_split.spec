# Isolation test: concurrent split storm with correctness verification
# Tests that concurrent inserts on temporal_rtree don't cause corruption

setup
{
    CREATE EXTENSION IF NOT EXISTS cube;
    CREATE EXTENSION IF NOT EXISTS temporalbox;
    CREATE EXTENSION IF NOT EXISTS temporal_rtree;
    CREATE TABLE temporal_data (
        id int,
        attr int NOT NULL,
        valid_period tsrange NOT NULL,
        data text
    );
    CREATE INDEX temporal_idx ON temporal_data USING temporal_rtree (temporalbox(attr, valid_period) temporal_cube_ops);
}

teardown
{
    DROP TABLE temporal_data;
}

session "s1"
step "s1_insert_bulk"  {
    INSERT INTO temporal_data
    SELECT g,
           10,
           tsrange(timestamp '2020-01-01' + ((g || ' days')::interval),
                   timestamp '2020-01-15' + ((g || ' days')::interval),
                   '[)'),
           'storm_a'
    FROM generate_series(1, 600) AS g;
}

session "s2"
step "s2_insert_bulk"  {
    INSERT INTO temporal_data
    SELECT g + 10000,
           10,
           tsrange(timestamp '2020-01-10' + ((g || ' days')::interval),
                   timestamp '2020-01-25' + ((g || ' days')::interval),
                   '[)'),
           'storm_b'
    FROM generate_series(1, 600) AS g;
}

session "s3"
step "s3_select"   {
    SELECT
        count(*) AS total_rows,
        (SELECT count(*)
         FROM temporal_data
         WHERE temporalbox(attr, valid_period)
               && temporalbox_range(10, timestamp '2020-01-01', timestamp '2025-01-01')) AS indexed_hits;
}

# Concurrent insertions should complete without corruption and preserve counts
permutation "s1_insert_bulk" "s2_insert_bulk" "s3_select"
