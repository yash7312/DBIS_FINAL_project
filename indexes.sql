CREATE OR REPLACE PROCEDURE drop_temporal_indexes()
LANGUAGE plpgsql
AS $$
BEGIN
    DROP INDEX IF EXISTS idx_btree_attr_lower;
    DROP INDEX IF EXISTS idx_gist_period;
    DROP INDEX IF EXISTS idx_gist_attr_period;
    DROP INDEX IF EXISTS idx_brin_lower;
END;
$$;


CREATE OR REPLACE PROCEDURE create_no_index()
LANGUAGE plpgsql
AS $$
BEGIN
    CALL drop_temporal_indexes();
END;
$$;


CREATE OR REPLACE PROCEDURE create_btree_baseline()
LANGUAGE plpgsql
AS $$
BEGIN
    CALL drop_temporal_indexes();
    CREATE INDEX idx_btree_attr_lower
    ON temporal_data (attr, lower(valid_period));
END;
$$;


CREATE OR REPLACE PROCEDURE create_gist_period()
LANGUAGE plpgsql
AS $$
BEGIN
    CALL drop_temporal_indexes();
    CREATE INDEX idx_gist_period
    ON temporal_data USING GIST (valid_period);
END;
$$;


CREATE OR REPLACE PROCEDURE create_gist_attr_period()
LANGUAGE plpgsql
AS $$
BEGIN
    CALL drop_temporal_indexes();
    CREATE INDEX idx_gist_attr_period
    ON temporal_data USING GIST (attr, valid_period);
END;
$$;


CREATE OR REPLACE PROCEDURE create_brin_lower()
LANGUAGE plpgsql
AS $$
BEGIN
    CALL drop_temporal_indexes();
    CREATE INDEX idx_brin_lower
    ON temporal_data USING BRIN ((lower(valid_period)));
END;
$$;