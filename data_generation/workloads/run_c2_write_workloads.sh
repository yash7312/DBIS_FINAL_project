#!/bin/bash
# C2 TODO THREE: Write Workload Test Runner
# Measures temporal_rtree maintenance cost vs. other indexes
# Usage: bash run_c2_write_workloads.sh [database_name] [dataset_size]

set -euo pipefail

DATABASE="${1:-temporal_write_bench}"
DATASET_SIZE="${2:-100000}"
RESULTS_DIR="./c2_write_results_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$RESULTS_DIR"

echo "========================================="
echo "C2 TODO THREE: Write Workload Testing"
echo "========================================="
echo "Database: $DATABASE"
echo "Dataset size: $DATASET_SIZE"
echo "Results: $RESULTS_DIR"

# Create database
echo "[1/8] Creating database..."
dropdb "$DATABASE" 2>/dev/null || true
createdb "$DATABASE"

# Load schema
echo "[2/8] Loading schema..."
psql -d "$DATABASE" -f ../../data_generation/schema.sql > /dev/null 2>&1

# Generate dataset
echo "[3/8] Generating dataset..."
python3 ../../data_generation/temporal_generator.py \
    --size "$DATASET_SIZE" \
    --ratio-open-ended 0.7 \
    --interval-mode long_tailed \
    --attr-mode zipf \
    --order-mode chrono \
    --output "/tmp/c2_test_dataset.sql"

psql -d "$DATABASE" -f "/tmp/c2_test_dataset.sql" > /dev/null 2>&1

# Create helper function for WAL measurement
psql -d "$DATABASE" <<'HELPER'
CREATE OR REPLACE FUNCTION measure_wal()
RETURNS TABLE(wal_bytes BIGINT) AS $$
DECLARE
    wal_start pg_lsn;
BEGIN
    wal_start := pg_current_wal_insert_lsn();
    RETURN QUERY EXECUTE 'SELECT pg_wal_lsn_diff(pg_current_wal_insert_lsn(), $1)::BIGINT'
        USING wal_start;
END;
$$ LANGUAGE plpgsql;
HELPER

# Function to run workload for each index type
run_write_workload_for_index() {
    local index_type="$1"
    local index_expr="$2"
    local index_cmd="$3"
    
    echo ""
    echo "================================"
    echo "Testing with index: $index_type"
    echo "================================"
    
    # Create index
    echo "Creating $index_type index..."
    psql -d "$DATABASE" <<SQL > /dev/null 2>&1
        $index_cmd
SQL
    
    # Get index size before
    local idx_size_before=$(psql -d "$DATABASE" -tA -c "
        SELECT pg_relation_size(oid)
        FROM pg_class
        WHERE relname ~ 'idx_|idx [^ ]*'
        AND relkind = 'i'
        AND relname NOT LIKE '%pg_toast%'
        LIMIT 1
    ")
    if [ -z "$idx_size_before" ]; then idx_size_before=0; fi
    
    # Record metrics for INSERT
    echo "Running INSERT batch..."
    local insert_start=$(date +%s%N)
    (
        psql -d "$DATABASE" 2>&1 <<INSERTWORK
            \timing on
            INSERT INTO temporal_data(attr, valid_period, payload)
            SELECT (random()*100)::int,
                   tsrange(timestamp '2024-01-01',
                           timestamp '2024-01-01' + ((random()*100+1)||' days')::interval,
                           '[)'),
                   md5(random()::text)
            FROM generate_series(1, 10000);
            \timing off
INSERTWORK
    ) | tee -a "$RESULTS_DIR/${index_type}_insert.log"
    local insert_end=$(date +%s%N)
    local insert_time=$(( (insert_end - insert_start) / 1000000 ))
    
    # Record metrics for UPDATE
    echo "Running UPDATE batch..."
    local update_start=$(date +%s%N)
    (
        psql -d "$DATABASE" 2>&1 <<UPDATEWORK
            \timing on
            UPDATE temporal_data
            SET valid_period = tsrange(lower(valid_period), timestamp '2024-06-01', '[)')
            WHERE upper_inf(valid_period)
              AND attr BETWEEN 1 AND 10
            LIMIT 1000;
            \timing off
UPDATEWORK
    ) | tee -a "$RESULTS_DIR/${index_type}_update.log"
    local update_end=$(date +%s%N)
    local update_time=$(( (update_end - update_start) / 1000000 ))
    
    # Record metrics for DELETE
    echo "Running DELETE batch..."
    local delete_start=$(date +%s%N)
    (
        psql -d "$DATABASE" 2>&1 <<DELETEWORK
            \timing on
            DELETE FROM temporal_data
            WHERE NOT upper_inf(valid_period)
              AND valid_period && tsrange('2020-01-01'::timestamp, '2021-01-01'::timestamp, '[)')
            LIMIT 500;
            \timing off
DELETEWORK
    ) | tee -a "$RESULTS_DIR/${index_type}_delete.log"
    local delete_end=$(date +%s%N)
    local delete_time=$(( (delete_end - delete_start) / 1000000 ))
    
    # VACUUM timing
    echo "Running VACUUM..."
    local vacuum_start=$(date +%s%N)
    psql -d "$DATABASE" -c "VACUUM ANALYZE temporal_data;" > /dev/null 2>&1
    local vacuum_end=$(date +%s%N)
    local vacuum_time=$(( (vacuum_end - vacuum_start) / 1000000 ))
    
    # Get index size after
    local idx_size_after=$(psql -d "$DATABASE" -tA -c "
        SELECT COALESCE(SUM(pg_relation_size(oid)), 0)
        FROM pg_class
        WHERE relname ~ 'idx_|idx [^ ]*'
        AND relkind = 'i'
        AND relname NOT LIKE '%pg_toast%'
    ")
    if [ -z "$idx_size_after" ]; then idx_size_after=0; fi
    
    # Index statistics
    echo "Collecting index statistics..."
    psql -d "$DATABASE" -tA <<STATS >> "$RESULTS_DIR/index_stats.csv"
SELECT 
    '$index_type' AS index_type,
    indexrelname AS index_name,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_all_indexes
WHERE relname = 'temporal_data'
ORDER BY indexrelname;
STATS
    
    # Record summary
    echo "" | tee -a "$RESULTS_DIR/summary.txt"
    echo "Index Type: $index_type" | tee -a "$RESULTS_DIR/summary.txt"
    echo "  INSERT (10k rows):    ${insert_time} ms" | tee -a "$RESULTS_DIR/summary.txt"
    echo "  UPDATE (1k rows):     ${update_time} ms" | tee -a "$RESULTS_DIR/summary.txt"
    echo "  DELETE (500 rows):    ${delete_time} ms" | tee -a "$RESULTS_DIR/summary.txt"
    echo "  VACUUM:               ${vacuum_time} ms" | tee -a "$RESULTS_DIR/summary.txt"
    echo "  Index size:           ${idx_size_after} bytes" | tee -a "$RESULTS_DIR/summary.txt"
    
    # Drop index for next iteration
    psql -d "$DATABASE" -c "DROP INDEX IF EXISTS idx_test CASCADE;" > /dev/null 2>&1
}

# =========================================================================
# Run workloads for each index type
# =========================================================================

echo "[4/8] Running write workloads..."

# No index (baseline)
echo "[4a/8] Testing with no index (baseline)..."
run_write_workload_for_index "none" "" ""

# B-tree index
echo "[4b/8] Testing with B-tree index..."
run_write_workload_for_index "btree" "valid_period" \
    "CREATE INDEX idx_test ON temporal_data (valid_period);"

# BRIN index
echo "[4c/8] Testing with BRIN index..."
run_write_workload_for_index "brin" "valid_period" \
    "CREATE INDEX idx_test ON temporal_data USING BRIN (valid_period);"

# GiST on tsrange
echo "[4d/8] Testing with GiST(tsrange) index..."
run_write_workload_for_index "gist_period" "valid_period" \
    "CREATE INDEX idx_test ON temporal_data USING GiST (valid_period);"

# GiST on temporalbox
echo "[4e/8] Testing with GiST(temporalbox) index..."
run_write_workload_for_index "gist_attr_period" "temporalbox(attr, valid_period)" \
    "CREATE INDEX idx_test ON temporal_data USING GiST (temporalbox(attr, valid_period) temporal_cube_ops);"

# temporal_rtree
echo "[4f/8] Testing with temporal_rtree index..."
if (psql -d "$DATABASE" -c "CREATE EXTENSION IF NOT EXISTS cube;" > /dev/null 2>&1) && \
   (psql -d "$DATABASE" -c "CREATE EXTENSION IF NOT EXISTS temporalbox;" > /dev/null 2>&1) && \
   (psql -d "$DATABASE" -c "CREATE EXTENSION IF NOT EXISTS temporal_rtree;" > /dev/null 2>&1); then
    run_write_workload_for_index "temporal_rtree" "temporalbox(attr, valid_period)" \
        "CREATE INDEX idx_test ON temporal_data USING temporal_rtree (temporalbox(attr, valid_period) temporal_cube_ops);"
else
    echo "WARNING: temporal_rtree extension not available, skipping"
fi

# =========================================================================
# Post-workload measurements
# =========================================================================

echo ""
echo "[5/8] Measuring final WAL bytes..."
psql -d "$DATABASE" -c "SELECT pg_wal_lsn_diff(pg_current_wal_insert_lsn(), '0/0')::BIGINT AS total_wal_bytes;" >> "$RESULTS_DIR/wal_final.txt"

echo "[6/8] Collecting table statistics..."
psql -d "$DATABASE" -c "SELECT * FROM pg_stat_all_tables WHERE relname = 'temporal_data';" >> "$RESULTS_DIR/table_stats.txt"

echo "[7/8] Collecting relation sizes..."
psql -d "$DATABASE" -c "
    SELECT 
        schemaname,
        tablename,
        pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
        pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size
    FROM pg_tables
    WHERE tablename = 'temporal_data';
" >> "$RESULTS_DIR/relation_sizes.txt"

echo "[8/8] Cleanup..."
dropdb "$DATABASE"

# =========================================================================
# Summary
# =========================================================================

echo ""
echo "========================================="
echo "Write Workload Testing Complete"
echo "========================================="
echo ""
echo "Results saved to: $RESULTS_DIR"
echo ""
echo "Key files:"
echo "  - summary.txt              (execution times)"
echo "  - index_stats.csv          (index statistics)"
echo "  - *_insert.log             (INSERT metrics)"
echo "  - *_update.log             (UPDATE metrics)"
echo "  - *_delete.log             (DELETE metrics)"
echo "  - table_stats.txt          (final table statistics)"
echo "  - relation_sizes.txt       (sizes)"
echo ""

# Display summary
if [ -f "$RESULTS_DIR/summary.txt" ]; then
    echo "Summary of results:"
    cat "$RESULTS_DIR/summary.txt"
fi
