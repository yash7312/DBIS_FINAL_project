CREATE EXTENSION IF NOT EXISTS cube;

CREATE OR REPLACE FUNCTION temporalbox(attr integer, period tsrange)
RETURNS cube
LANGUAGE SQL
IMMUTABLE
STRICT
AS $$
    SELECT public.cube(
        ARRAY[
            attr::float8,
            EXTRACT(EPOCH FROM lower(period))::float8
        ]::float8[],
        ARRAY[
            attr::float8,
            CASE
                WHEN upper_inf(period) THEN 'Infinity'::float8
                ELSE EXTRACT(EPOCH FROM upper(period))::float8
            END
        ]::float8[]
    );
$$;

CREATE OR REPLACE FUNCTION temporalbox_point(attr integer, t timestamp)
RETURNS cube
LANGUAGE SQL
IMMUTABLE
STRICT
AS $$
    SELECT public.cube(
        ARRAY[
            attr::float8,
            EXTRACT(EPOCH FROM t)::float8
        ]::float8[]
    );
$$;

CREATE OR REPLACE FUNCTION temporalbox_range(attr integer, t1 timestamp, t2 timestamp)
RETURNS cube
LANGUAGE SQL
IMMUTABLE
STRICT
AS $$
    SELECT public.cube(
        ARRAY[
            attr::float8,
            EXTRACT(EPOCH FROM t1)::float8
        ]::float8[],
        ARRAY[
            attr::float8,
            EXTRACT(EPOCH FROM t2)::float8
        ]::float8[]
    );
$$;
