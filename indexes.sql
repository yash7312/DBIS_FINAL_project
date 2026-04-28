CREATE OR REPLACE PROCEDURE drop_temporal_indexes()
LANGUAGE plpgsql
AS $$
BEGIN
    DROP INDEX IF EXISTS idx_btree_attr_lower;
    DROP INDEX IF EXISTS idx_gist_period;
    DROP INDEX IF EXISTS idx_gist_attr_period;
    DROP INDEX IF EXISTS idx_brin_lower;
    DROP INDEX IF EXISTS idx_hist_gist;
    DROP INDEX IF EXISTS idx_hist_attr_gist;
    DROP INDEX IF EXISTS idx_current_attr_start;
    DROP INDEX IF EXISTS idx_current_start;
    DROP INDEX IF EXISTS idx_hst_gist;
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


CREATE OR REPLACE PROCEDURE create_hybrid_current_history()
LANGUAGE plpgsql
AS $$
BEGIN
    CALL drop_temporal_indexes();

    CREATE INDEX idx_hist_attr_gist
    ON temporal_data USING GIST (attr, valid_period)
    WHERE NOT upper_inf(valid_period);

    CREATE INDEX idx_hist_gist
    ON temporal_data USING GIST (valid_period)
    WHERE NOT upper_inf(valid_period);

    CREATE INDEX idx_current_attr_start
    ON temporal_data (attr, lower(valid_period))
    WHERE upper_inf(valid_period);

    CREATE INDEX idx_current_start
    ON temporal_data (lower(valid_period))
    WHERE upper_inf(valid_period);
END;
$$;


CREATE OR REPLACE PROCEDURE create_hst_gist()
LANGUAGE plpgsql
AS $$
BEGIN
    CALL drop_temporal_indexes();

    CREATE INDEX idx_hst_gist
    ON temporal_data USING GIST (temporalbox(attr, valid_period))
    WHERE NOT upper_inf(valid_period);

    CREATE INDEX idx_current_attr_start
    ON temporal_data (attr, lower(valid_period))
    WHERE upper_inf(valid_period);

    CREATE INDEX idx_current_start
    ON temporal_data (lower(valid_period))
    WHERE upper_inf(valid_period);
END;
$$;