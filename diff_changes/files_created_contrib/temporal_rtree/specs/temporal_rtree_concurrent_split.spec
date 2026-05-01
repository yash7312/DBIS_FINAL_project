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
step "s1_insert_a" {
    INSERT INTO temporal_data (id, attr, valid_period, data)
    SELECT g, 10, tsrange('2020-01-01', '2020-01-02', '[)'), 'a' || g
    FROM generate_series(1, 1000) g;
}

session "s2"
step "s2_insert_b" {
    INSERT INTO temporal_data (id, attr, valid_period, data)
    SELECT g, 10, tsrange('2020-01-01', '2020-01-02', '[)'), 'b' || g
    FROM generate_series(1001, 2000) g;
}

session "s3"
step "s3_correctness" {
    SELECT
        count(*) AS total_rows,
        (SELECT count(*)
         FROM temporal_data
         WHERE temporalbox(attr, valid_period)
               && temporalbox_range(10, timestamp '2020-01-01', timestamp '2020-01-04')) AS indexed_hits,
                (SELECT count(*)
                 FROM temporal_data
                 WHERE attr = 10
                     AND valid_period && tsrange('2020-01-01', '2020-01-04', '[)')) AS truth_hits;
}

session "s4"
step "s4_hot_update" {
    UPDATE temporal_data
    SET valid_period = tsrange(lower(valid_period), upper(valid_period) + interval '1 day', '[)')
    WHERE id IN (1, 101);
}

session "s5"
step "s5_purge" {
    DELETE FROM temporal_data
    WHERE id = 3 OR id = 103;
}

permutation "s1_insert_a" "s2_insert_b" "s3_correctness" "s4_hot_update" "s5_purge"
