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
    INSERT INTO temporal_data VALUES
      (1, 10, tsrange('2020-01-01', '2020-01-02', '[)'), 'a1'),
      (2, 10, tsrange('2020-01-02', '2020-01-03', '[)'), 'a2'),
      (3, 10, tsrange('2020-01-03', '2020-01-04', '[)'), 'a3');
}

session "s2"
step "s2_insert_b" {
    INSERT INTO temporal_data VALUES
      (101, 10, tsrange('2020-01-01 12:00', '2020-01-02 12:00', '[)'), 'b1'),
      (102, 10, tsrange('2020-01-02 12:00', '2020-01-03 12:00', '[)'), 'b2'),
      (103, 10, tsrange('2020-01-03 12:00', '2020-01-04 12:00', '[)'), 'b3');
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
         WHERE valid_period && tsrange('2020-01-01', '2020-01-04', '[)')) AS truth_hits;
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
