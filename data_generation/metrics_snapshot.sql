\set ON_ERROR_STOP on
\o :log_dir/metrics_:current_config.csv
COPY (
    WITH index_stats AS (
        SELECT
            COALESCE(string_agg(indexrelname, ' | ' ORDER BY indexrelname), '(none)') AS index_names,
            COUNT(*)::int AS index_count,
            COALESCE(SUM(pg_relation_size(indexrelid)), 0)::bigint AS total_index_size_bytes,
            COALESCE(pg_size_pretty(SUM(pg_relation_size(indexrelid))), '0 bytes') AS total_index_size_pretty,
            COALESCE(SUM(idx_scan), 0)::bigint AS total_idx_scan,
            COALESCE(SUM(idx_tup_read), 0)::bigint AS total_idx_tup_read,
            COALESCE(SUM(idx_tup_fetch), 0)::bigint AS total_idx_tup_fetch
        FROM pg_stat_all_indexes
        WHERE relname = 'temporal_data'
    ),
    table_stats AS (
        SELECT
            COALESCE(n_live_tup, 0)::bigint AS n_live_tup,
            COALESCE(n_dead_tup, 0)::bigint AS n_dead_tup,
            COALESCE(n_mod_since_analyze, 0)::bigint AS n_mod_since_analyze,
            COALESCE(pg_total_relation_size('temporal_data'), 0)::bigint AS table_size_bytes,
            COALESCE(pg_size_pretty(pg_total_relation_size('temporal_data')), '0 bytes') AS table_size_pretty
        FROM pg_stat_all_tables
        WHERE relname = 'temporal_data'
    )
    SELECT
        :'current_config' AS index_config,
        index_stats.index_names,
        index_stats.index_count,
        index_stats.total_index_size_bytes,
        index_stats.total_index_size_pretty,
        index_stats.total_idx_scan,
        index_stats.total_idx_tup_read,
        index_stats.total_idx_tup_fetch,
        table_stats.n_live_tup,
        table_stats.n_dead_tup,
        table_stats.n_mod_since_analyze,
        table_stats.table_size_bytes,
        table_stats.table_size_pretty,
        to_char(clock_timestamp(), 'YYYY-MM-DD"T"HH24:MI:SS.US') AS snapshot_ts
    FROM index_stats
    CROSS JOIN table_stats
) TO STDOUT WITH CSV HEADER;
\o
