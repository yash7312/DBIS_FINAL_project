#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_NAME="${1:-temporal_bench}"
DATASET_FILE="${2:-$SCRIPT_DIR/../experiment_logs/benchmark_dataset.sql}"
OUTPUT_DIR="${3:-$SCRIPT_DIR/benchmark_matrix_results}"

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGDATABASE="$DB_NAME"

mkdir -p "$OUTPUT_DIR"

reset_secondary_indexes() {
    psql -v ON_ERROR_STOP=1 -d "$DB_NAME" <<'EOF' >/dev/null
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT indexname
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'temporal_data'
      AND indexname <> 'temporal_data_pkey'
  LOOP
    EXECUTE format('DROP INDEX IF EXISTS %I CASCADE', r.indexname);
  END LOOP;
END$$;

VACUUM ANALYZE temporal_data;
EOF
}

reload_dataset() {
    "$SCRIPT_DIR/load_dataset.sh" "$DATASET_FILE" none >/dev/null
}

ensure_extensions() {
    psql -v ON_ERROR_STOP=1 -d "$DB_NAME" <<'EOF' >/dev/null
DROP EXTENSION IF EXISTS temporal_rtree CASCADE;
DROP FUNCTION IF EXISTS temporalbox(integer, tsrange) CASCADE;
DROP FUNCTION IF EXISTS temporalbox_point(integer, timestamp) CASCADE;
DROP FUNCTION IF EXISTS temporalbox_range(integer, timestamp, timestamp) CASCADE;
EOF

    psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -f "$SCRIPT_DIR/../postgresql/contrib/temporalbox/temporalbox--1.0.sql" >/dev/null
    psql -v ON_ERROR_STOP=1 -d "$DB_NAME" <<'EOF' >/dev/null
CREATE EXTENSION temporal_rtree;
EOF
}

setup_config() {
    local config="$1"

    reset_secondary_indexes

    case "$config" in
        none)
            psql -v ON_ERROR_STOP=1 -d "$DB_NAME" <<'EOF' >/dev/null
SET enable_indexscan = off;
SET enable_bitmapscan = off;
SET enable_indexonlyscan = off;
EOF
            ;;
        btree)
            psql -v ON_ERROR_STOP=1 -d "$DB_NAME" <<'EOF' >/dev/null
CREATE INDEX idx_btree ON temporal_data (attr, lower(valid_period));
VACUUM ANALYZE temporal_data;
EOF
            ;;
        brin)
            psql -v ON_ERROR_STOP=1 -d "$DB_NAME" <<'EOF' >/dev/null
CREATE INDEX idx_brin ON temporal_data USING brin (valid_period);
VACUUM ANALYZE temporal_data;
EOF
            ;;
        gist_period)
            psql -v ON_ERROR_STOP=1 -d "$DB_NAME" <<'EOF' >/dev/null
CREATE INDEX idx_gist_period ON temporal_data USING gist (valid_period);
VACUUM ANALYZE temporal_data;
EOF
            ;;
        gist_attr_period)
            ensure_extensions
            psql -v ON_ERROR_STOP=1 -d "$DB_NAME" <<'EOF' >/dev/null
CREATE INDEX idx_gist_attr_period ON temporal_data USING gist (temporalbox(attr, valid_period));
VACUUM ANALYZE temporal_data;
EOF
            ;;
        hst_gist)
            psql -v ON_ERROR_STOP=1 -d "$DB_NAME" <<'EOF' >/dev/null
CREATE INDEX idx_hst_gist ON temporal_data USING gist (valid_period)
  WHERE NOT upper_inf(valid_period);
VACUUM ANALYZE temporal_data;
EOF
            ;;
        hybrid_current_history)
            psql -v ON_ERROR_STOP=1 -d "$DB_NAME" <<'EOF' >/dev/null
CREATE INDEX idx_current_attr_start ON temporal_data (attr, lower(valid_period))
  WHERE upper_inf(valid_period);
CREATE INDEX idx_hst_gist ON temporal_data USING gist (valid_period)
  WHERE NOT upper_inf(valid_period);
VACUUM ANALYZE temporal_data;
EOF
            ;;
        temporal_rtree)
            ensure_extensions
            psql -v ON_ERROR_STOP=1 -d "$DB_NAME" <<'EOF' >/dev/null
CREATE INDEX idx_rtree_temporalbox ON temporal_data
USING temporal_rtree (temporalbox(attr, valid_period) temporal_cube_ops);
VACUUM ANALYZE temporal_data;
EOF
            ;;
        *)
            echo "Unknown config: $config" >&2
            exit 1
            ;;
    esac
}

select_sql_for_config() {
    case "$1" in
        gist_attr_period|temporal_rtree)
            cat <<'EOF'
SELECT count(*)
FROM temporal_data
WHERE temporalbox(attr, valid_period)
      && temporalbox_range(10, timestamp '2023-01-01', timestamp '2023-06-01');
EOF
            ;;
        *)
            cat <<'EOF'
SELECT count(*)
FROM temporal_data
WHERE valid_period && tsrange('2023-01-01','2023-06-01','[)');
EOF
            ;;
    esac
}

run_explain_with_wal() {
    local label="$1"
    local sql_text="$2"
    local output_file="$3"

    psql -v ON_ERROR_STOP=1 -d "$DB_NAME" >> "$output_file" 2>&1 <<ENDSQL
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
$sql_text;
ENDSQL

    echo "" >> "$output_file"
    echo "-- END $label" >> "$output_file"
    echo "" >> "$output_file"
}

run_config() {
    local config="$1"
    local output_file="$OUTPUT_DIR/${config}.txt"

    reload_dataset
    setup_config "$config"

    {
        echo "================================================================================"
        echo "CONFIG: $config"
        echo "Timestamp: $(date)"
        echo "Dataset: $DATASET_FILE"
        echo "================================================================================"
        echo
        echo "-- Indexes present"
    } > "$output_file"

    psql -v ON_ERROR_STOP=1 -d "$DB_NAME" >> "$output_file" 2>&1 <<'EOF'
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'temporal_data'
ORDER BY indexname;
EOF

    {
        echo 'index_config,index_names,index_count,total_index_size_bytes,total_index_size_pretty,total_idx_scan,total_idx_tup_read,total_idx_tup_fetch,n_live_tup,n_dead_tup,n_mod_since_analyze,table_size_bytes,table_size_pretty,snapshot_ts'
        psql -v ON_ERROR_STOP=1 -At -F ',' -d "$DB_NAME" <<EOF
SELECT
    '$config'::text AS index_config,
    COALESCE(string_agg(i.indexname, '; ' ORDER BY i.indexname), '') AS index_names,
    COUNT(*)::int AS index_count,
    COALESCE(SUM(pg_relation_size(c.oid)), 0)::bigint AS total_index_size_bytes,
    pg_size_pretty(COALESCE(SUM(pg_relation_size(c.oid)), 0))::text AS total_index_size_pretty,
    COALESCE(SUM(s.idx_scan), 0)::bigint AS total_idx_scan,
    COALESCE(SUM(s.idx_tup_read), 0)::bigint AS total_idx_tup_read,
    COALESCE(SUM(s.idx_tup_fetch), 0)::bigint AS total_idx_tup_fetch,
    (SELECT reltuples::bigint FROM pg_class WHERE oid = 'temporal_data'::regclass) AS n_live_tup,
    COALESCE((SELECT n_dead_tup FROM pg_stat_all_tables WHERE relname = 'temporal_data'), 0)::bigint AS n_dead_tup,
    COALESCE((SELECT n_mod_since_analyze FROM pg_stat_all_tables WHERE relname = 'temporal_data'), 0)::bigint AS n_mod_since_analyze,
    pg_total_relation_size('temporal_data')::bigint AS table_size_bytes,
    pg_size_pretty(pg_total_relation_size('temporal_data'))::text AS table_size_pretty,
    to_char(clock_timestamp(), 'YYYY-MM-DD"T"HH24:MI:SS.US') AS snapshot_ts
FROM pg_indexes i
JOIN pg_class c ON c.relname = i.indexname
LEFT JOIN pg_stat_all_indexes s ON s.indexrelid = c.oid
WHERE i.tablename = 'temporal_data';
EOF
    } > "$OUTPUT_DIR/metrics_${config}.csv"

    {
        echo
        echo "-- SELECT"
    } >> "$output_file"
    run_explain_with_wal "SELECT" "$(select_sql_for_config "$config")" "$output_file"

    {
        echo "-- INSERT"
    } >> "$output_file"
    # First set the sequence to start after existing data
    psql -v ON_ERROR_STOP=1 -d "$DB_NAME" >> "$output_file" 2>&1 <<'SEQSQL'
SELECT setval('temporal_data_id_seq', (SELECT MAX(id) FROM temporal_data) + 1);
SEQSQL
    
    run_explain_with_wal "INSERT" "INSERT INTO temporal_data(attr, valid_period, payload)
SELECT
  (random()*100)::int,
  tsrange(timestamp '2024-01-01',
          timestamp '2024-01-01' + ((random()*100+1)||' days')::interval,
          '[)'),
  md5(random()::text)
FROM generate_series(1, 10000)" "$output_file"

    {
        echo "-- UPDATE"
    } >> "$output_file"
    run_explain_with_wal "UPDATE" "UPDATE temporal_data
SET valid_period = tsrange(lower(valid_period), timestamp '2030-12-31', '[)')
WHERE upper_inf(valid_period)
  AND lower(valid_period) < timestamp '2030-12-31'
  AND attr BETWEEN 1 AND 10" "$output_file"

    {
        echo "-- DELETE"
    } >> "$output_file"
    run_explain_with_wal "DELETE" "DELETE FROM temporal_data
WHERE NOT upper_inf(valid_period)
  AND valid_period && tsrange('2020-01-01','2021-01-01','[)')" "$output_file"
}

configs=(
    none
    btree
    brin
    gist_period
    gist_attr_period
    hst_gist
    hybrid_current_history
    temporal_rtree
)

for config in "${configs[@]}"; do
    run_config "$config"
done

echo "Benchmark matrix complete. Results written to $OUTPUT_DIR"
