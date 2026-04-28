#!/bin/bash
################################################################################
# Write and Maintenance Workload Executor - Checkpoint C2 TODO Three
#
# Comprehensive write/update/delete test suite that stresses:
#   1. Current-row closure (temporal versioning workflow)
#   2. History widening (overlap churn and reinsertion)
#   3. History purge (cold data deletion for retention policies)
#   4. Hot attribute updates (concentrated contention)
#
# Measures:
#   - Build cost (index creation time)
#   - Per-workload query performance degradation
#   - Maintenance overhead (VACUUM, REINDEX)
#   - Index bloat (dead tuples, page reuse)
#   - Recovery characteristics (as % of original)
#
# Output: Detailed report with metrics per workload per index config
################################################################################

set -e

DB_NAME="${1:-temporal_bench}"
OUTPUT_DIR="${2:-./write_workload_results}"
WRITE_WLOAD_FILE="${3:-./write_workloads.sql}"
READ_WLOAD_FILE="${4:-./workload_queries.sql}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$OUTPUT_DIR"
REPORT_FILE="$OUTPUT_DIR/write_workload_report.txt"
METRICS_FILE="$OUTPUT_DIR/write_workload_metrics.csv"

echo -e "${GREEN}[*]${NC} Write Workload Test Suite"
echo -e "${GREEN}[*]${NC} Database: $DB_NAME"
echo -e "${GREEN}[*]${NC} Output directory: $OUTPUT_DIR"

# Verify database and table exist
if ! psql -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
    echo -e "${RED}[!]${NC} Database '$DB_NAME' not found"
    exit 1
fi

if ! psql -d "$DB_NAME" -tc "SELECT 1 FROM temporal_data LIMIT 1" >/dev/null 2>&1; then
    echo -e "${RED}[!]${NC} Table 'temporal_data' not found or empty"
    exit 1
fi

################################################################################
# Helper Functions
################################################################################

init_report() {
    cat > "$REPORT_FILE" << EOF
================================================================================
             WRITE AND MAINTENANCE WORKLOAD TEST REPORT
================================================================================
Date: $(date)
Database: $DB_NAME
Dataset: $(psql -d "$DB_NAME" -tc "SELECT COUNT(*) FROM temporal_data" | tr -d ' ') rows

================================================================================
                           BASELINE METRICS
================================================================================

EOF
    
    # Capture baseline dataset info
    psql -d "$DB_NAME" >> "$REPORT_FILE" << 'EOF'
-- Dataset composition
SELECT 
  'Dataset Stats' as metric,
  COUNT(*) as total_rows,
  COUNT(*) FILTER (WHERE upper_inf(valid_period)) as current_rows,
  COUNT(*) FILTER (WHERE NOT upper_inf(valid_period)) as history_rows
FROM temporal_data;

-- Index baseline
SELECT 
  indexname,
  pg_size_pretty(pg_relation_size(indexrelid)) as size,
  idx_scan as scans,
  idx_tup_read as tup_read,
  idx_tup_fetch as tup_fetch
FROM pg_stat_all_indexes
WHERE tablename = 'temporal_data'
ORDER BY indexname;

-- Table stats baseline
SELECT 
  n_live_tup as live_tuples,
  n_dead_tup as dead_tuples,
  n_mod_since_analyze as mods_since_analyze,
  pg_size_pretty(pg_total_relation_size('temporal_data')) as total_size
FROM pg_stat_all_tables
WHERE tablename = 'temporal_data';

EOF
}

init_metrics_csv() {
    cat > "$METRICS_FILE" << 'EOF'
index_config,workload_step,operation,elapsed_ms,rows_affected,dead_tuples,index_size_mb,query_time_ms,buffers_hit,buffers_read
EOF
}

run_query_with_timing() {
    local query="$1"
    local label="$2"
    local output_file="$3"
    local planner_guc_sql=""

    if [[ "${INDEX_CONFIG:-}" == "no_index" ]]; then
        planner_guc_sql=$'SET enable_indexscan = off;\nSET enable_bitmapscan = off;\nSET enable_indexonlyscan = off;'
    fi
    
    echo " $label..." >> "$output_file"
    
    # Capture EXPLAIN and timing
    psql -d "$DB_NAME" > /tmp/query_result.txt 2>&1 << QUERY_END || true
\\timing on
$planner_guc_sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
$query
\\timing off
QUERY_END
    
    cat /tmp/query_result.txt >> "$output_file"
    echo "" >> "$output_file"
    
    # Extract execution time for metrics
    grep "Execution Time:" /tmp/query_result.txt | tail -1 | awk '{print $3}' || echo "0"
}

capture_bloat_metrics() {
    local label="$1"
    local output_file="$2"
    
    echo -e "\n${BLUE}[Bloat Metrics] $label${NC}" >> "$output_file"
    
    psql -d "$DB_NAME" >> "$output_file" 2>&1 << 'EOF'

-- Dead tuple count
SELECT 
  'Dead Tuples' as metric,
  n_dead_tup,
  ROUND(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 2) as dead_pct
FROM pg_stat_all_tables
WHERE tablename = 'temporal_data';

-- Index sizes
SELECT 
  indexname,
  pg_size_pretty(pg_relation_size(indexrelid)) as size
FROM pg_stat_all_indexes
WHERE tablename = 'temporal_data'
ORDER BY indexname;

-- Table size
SELECT 
  pg_size_pretty(pg_total_relation_size('temporal_data')) as total_size;

EOF
}

reset_secondary_indexes() {
    psql -d "$DB_NAME" << 'EOF'
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

################################################################################
# Main Test Loop: Per-Index Configuration
################################################################################

for INDEX_CONFIG in no_index btree gist brin hybrid; do
    
    echo ""
    echo -e "${GREEN}========== $INDEX_CONFIG ===========${NC}"
    CONFIG_REPORT="$OUTPUT_DIR/write_${INDEX_CONFIG}_report.txt"
    
    cat > "$CONFIG_REPORT" << EOF
========================================
WRITE WORKLOAD: $INDEX_CONFIG
Timestamp: $(date)
========================================

EOF
    
    # Setup indexes for this configuration
    echo -e "${YELLOW}[~]${NC} Setting up $INDEX_CONFIG indexes..."
    
    setup_query=""
    case "$INDEX_CONFIG" in
        no_index)
          setup_query="SET enable_indexscan = off; SET enable_bitmapscan = off; SET enable_indexonlyscan = off;"
            ;;
        btree)
            setup_query="
CREATE INDEX idx_test_btree ON temporal_data (attr, lower(valid_period));
VACUUM ANALYZE temporal_data;
"
            ;;
        gist)
            setup_query="
CREATE INDEX idx_test_gist ON temporal_data USING gist (valid_period);
VACUUM ANALYZE temporal_data;
"
            ;;
        brin)
            setup_query="
CREATE INDEX idx_test_brin ON temporal_data USING brin (valid_period);
VACUUM ANALYZE temporal_data;
"
            ;;
        hybrid)
            setup_query="
CREATE INDEX idx_test_current ON temporal_data (attr, lower(valid_period))
  WHERE upper_inf(valid_period);
CREATE INDEX idx_test_history ON temporal_data USING gist (valid_period)
  WHERE NOT upper_inf(valid_period);
VACUUM ANALYZE temporal_data;
"
            ;;
    esac

          reset_secondary_indexes >> "$CONFIG_REPORT" 2>&1
    psql -d "$DB_NAME" -c "$setup_query" >> "$CONFIG_REPORT" 2>&1
    
    ############################################################################
    # PHASE 1: BASELINE QUERY PERFORMANCE
    ############################################################################
    
    echo -e "\n${BLUE}=== PHASE 1: Baseline Queries ===${NC}" >> "$CONFIG_REPORT"
    
    cat >> "$CONFIG_REPORT" << 'EOF'

-- Q1: History point lookup (2023-06-01 is in history)
EOF
    run_query_with_timing "SELECT COUNT(*) FROM temporal_data WHERE valid_period @> timestamp '2023-06-01';" "Q1" "$CONFIG_REPORT"
    
    cat >> "$CONFIG_REPORT" << 'EOF'

-- Q2: Current point lookup (2027-01-01 is in future, mostly current)
EOF
    run_query_with_timing "SELECT COUNT(*) FROM temporal_data WHERE valid_period @> timestamp '2027-01-01';" "Q2" "$CONFIG_REPORT"
    
    cat >> "$CONFIG_REPORT" << 'EOF'

-- Q4: Medium range (5 months, mixed current/history)
EOF
    run_query_with_timing "SELECT COUNT(*) FROM temporal_data WHERE valid_period && tsrange('2023-01-01','2023-06-01','[)');" "Q4" "$CONFIG_REPORT"
    
    capture_bloat_metrics "After Baseline" "$CONFIG_REPORT"
    
    ############################################################################
    # PHASE 2: CURRENT-ROW CLOSURE WORKLOAD
    ############################################################################
    
    echo -e "\n${BLUE}=== PHASE 2: Current-Row Closure ===${NC}" >> "$CONFIG_REPORT"
    cat >> "$CONFIG_REPORT" << 'EOF'

-- Close current rows for hot attributes (convert open-ended to finite)
UPDATE temporal_data
SET valid_period = tsrange(lower(valid_period), timestamp '2024-06-01 00:00:00', '[)')
WHERE upper_inf(valid_period) AND attr BETWEEN 1 AND 10;

-- Insert new current versions
INSERT INTO temporal_data(attr, valid_period, payload)
SELECT 
  attr,
  tsrange(timestamp '2024-06-01 00:00:00', NULL, '[)'),
  payload || '_v2'
FROM temporal_data
WHERE attr BETWEEN 1 AND 10
  AND upper(valid_period) = timestamp '2024-06-01 00:00:00'
LIMIT 10000;

-- Maintenance
VACUUM ANALYZE temporal_data;

EOF
    
    psql -d "$DB_NAME" >> "$CONFIG_REPORT" 2>&1 << 'SQL'
UPDATE temporal_data
SET valid_period = tsrange(lower(valid_period), timestamp '2024-06-01 00:00:00', '[)')
WHERE upper_inf(valid_period) AND attr BETWEEN 1 AND 10;

INSERT INTO temporal_data(attr, valid_period, payload)
SELECT 
  attr,
  tsrange(timestamp '2024-06-01 00:00:00', NULL, '[)'),
  payload || '_v2'
FROM temporal_data
WHERE attr BETWEEN 1 AND 10
  AND upper(valid_period) = timestamp '2024-06-01 00:00:00'
LIMIT 10000;

VACUUM ANALYZE temporal_data;
SQL
    
    cat >> "$CONFIG_REPORT" << 'EOF'

-- Re-measure: Q1 (should now hit both old closed history + GiST)
EOF
    run_query_with_timing "SELECT COUNT(*) FROM temporal_data WHERE valid_period @> timestamp '2023-06-01';" "Q1-After-Closure" "$CONFIG_REPORT"
    
    cat >> "$CONFIG_REPORT" << 'EOF'

-- Re-measure: Q2 (should now include new versions)
EOF
    run_query_with_timing "SELECT COUNT(*) FROM temporal_data WHERE valid_period @> timestamp '2027-01-01';" "Q2-After-Closure" "$CONFIG_REPORT"
    
    capture_bloat_metrics "After Current-Row Closure" "$CONFIG_REPORT"
    
    ############################################################################
    # PHASE 3: HISTORY WIDENING WORKLOAD
    ############################################################################
    
    echo -e "\n${BLUE}=== PHASE 3: History Widening ===${NC}" >> "$CONFIG_REPORT"
    cat >> "$CONFIG_REPORT" << 'EOF'

-- Widen lower bounds (retroactive effect)
UPDATE temporal_data
SET valid_period = tsrange(
      lower(valid_period) - interval '3 days',
      upper(valid_period),
      '[)'
    )
WHERE NOT upper_inf(valid_period)
  AND attr BETWEEN 20 AND 30
  AND lower(valid_period) >= timestamp '2023-06-01'
  AND lower(valid_period) <= timestamp '2023-12-31';

-- Widen upper bounds (extend) 
UPDATE temporal_data
SET valid_period = tsrange(
      lower(valid_period),
      upper(valid_period) + interval '3 days',
      '[)'
    )
WHERE NOT upper_inf(valid_period)
  AND attr BETWEEN 20 AND 30
  AND upper(valid_period) >= timestamp '2023-06-01'
  AND upper(valid_period) <= timestamp '2023-12-31';

-- Maintenance
VACUUM ANALYZE temporal_data;

EOF
    
    psql -d "$DB_NAME" >> "$CONFIG_REPORT" 2>&1 << 'SQL'
UPDATE temporal_data
SET valid_period = tsrange(
      lower(valid_period) - interval '3 days',
      upper(valid_period),
      '[)'
    )
WHERE NOT upper_inf(valid_period)
  AND attr BETWEEN 20 AND 30
  AND lower(valid_period) >= timestamp '2023-06-01'
  AND lower(valid_period) <= timestamp '2023-12-31';

UPDATE temporal_data
SET valid_period = tsrange(
      lower(valid_period),
      upper(valid_period) + interval '3 days',
      '[)'
    )
WHERE NOT upper_inf(valid_period)
  AND attr BETWEEN 20 AND 30
  AND upper(valid_period) >= timestamp '2023-06-01'
  AND upper(valid_period) <= timestamp '2023-12-31';

VACUUM ANALYZE temporal_data;
SQL
    
    cat >> "$CONFIG_REPORT" << 'EOF'

-- Re-measure: Q4 (widened intervals may increase selectivity)
EOF
    run_query_with_timing "SELECT COUNT(*) FROM temporal_data WHERE valid_period && tsrange('2023-01-01','2023-06-01','[)');" "Q4-After-Widening" "$CONFIG_REPORT"
    
    capture_bloat_metrics "After History Widening" "$CONFIG_REPORT"
    
    ############################################################################
    # PHASE 4: HISTORY PURGE WORKLOAD
    ############################################################################
    
    echo -e "\n${BLUE}=== PHASE 4: History Purge ===${NC}" >> "$CONFIG_REPORT"
    cat >> "$CONFIG_REPORT" << 'EOF'

-- Delete old history (retention policy)
DELETE FROM temporal_data
WHERE NOT upper_inf(valid_period)
  AND upper(valid_period) < timestamp '2022-06-01 00:00:00';

-- Maintenance + optional REINDEX
VACUUM ANALYZE temporal_data;
EOF
    
    psql -d "$DB_NAME" >> "$CONFIG_REPORT" 2>&1 << 'SQL'
DELETE FROM temporal_data
WHERE NOT upper_inf(valid_period)
  AND upper(valid_period) < timestamp '2022-06-01 00:00:00';

VACUUM ANALYZE temporal_data;
SQL
    
    # Optional reindex (only if not seq scan / no index)
    if [ "$INDEX_CONFIG" != "no_index" ]; then
        echo "REINDEX INDEX CONCURRENTLY idx_test_${INDEX_CONFIG};" >> "$CONFIG_REPORT"
        psql -d "$DB_NAME" -c "REINDEX INDEX CONCURRENTLY idx_test_${INDEX_CONFIG};" >> "$CONFIG_REPORT" 2>&1 || true
    fi
    
    cat >> "$CONFIG_REPORT" << 'EOF'

-- Re-measure: Q4 (after purge, selectivity may decrease)
EOF
    run_query_with_timing "SELECT COUNT(*) FROM temporal_data WHERE valid_period && tsrange('2023-01-01','2023-06-01','[)');" "Q4-After-Purge" "$CONFIG_REPORT"
    
    capture_bloat_metrics "After History Purge" "$CONFIG_REPORT"
    
    ############################################################################
    # PHASE 5: HOT ATTRIBUTE UPDATE WORKLOAD
    ############################################################################
    
    echo -e "\n${BLUE}=== PHASE 5: Hot Attribute Updates ===${NC}" >> "$CONFIG_REPORT"
    cat >> "$CONFIG_REPORT" << 'EOF'

-- Update lower bounds on hot attributes
UPDATE temporal_data
SET valid_period = tsrange(
      lower(valid_period) + interval '1 day',
      upper(valid_period),
      '[)'
    )
WHERE attr IN (1, 2, 3, 4, 5)
  AND lower(valid_period) >= timestamp '2023-01-01'
  AND lower(valid_period) <= timestamp '2023-12-31';

-- Update payloads (causes tuple modification)
UPDATE temporal_data
SET payload = 'updated_' || (random() * 10000)::int::text
WHERE attr IN (1, 2, 3, 4, 5)
  AND upper_inf(valid_period);

-- Maintenance
VACUUM ANALYZE temporal_data;

EOF
    
    psql -d "$DB_NAME" >> "$CONFIG_REPORT" 2>&1 << 'SQL'
UPDATE temporal_data
SET valid_period = tsrange(
      lower(valid_period) + interval '1 day',
      upper(valid_period),
      '[)'
    )
WHERE attr IN (1, 2, 3, 4, 5)
  AND lower(valid_period) >= timestamp '2023-01-01'
  AND lower(valid_period) <= timestamp '2023-12-31';

UPDATE temporal_data
SET payload = 'updated_' || (random() * 10000)::int::text
WHERE attr IN (1, 2, 3, 4, 5)
  AND upper_inf(valid_period);

VACUUM ANALYZE temporal_data;
SQL
    
    cat >> "$CONFIG_REPORT" << 'EOF'

-- Re-measure: Q1 (check if hot attributes impact history lookups)
EOF
    run_query_with_timing "SELECT COUNT(*) FROM temporal_data WHERE valid_period @> timestamp '2023-06-01' AND attr IN (1,2,3,4,5);" "Q1-Hot-Subset-After-Updates" "$CONFIG_REPORT"
    
    capture_bloat_metrics "After Hot Attribute Updates" "$CONFIG_REPORT"
    
    ############################################################################
    # FINAL METRICS COLLECTION
    ############################################################################
    
    echo -e "\n${BLUE}=== FINAL METRICS ===${NC}" >> "$CONFIG_REPORT"
    psql -d "$DB_NAME" >> "$CONFIG_REPORT" 2>&1 << 'EOF'

-- Final dataset state
SELECT 
  'Final' as phase,
  COUNT(*) as total_rows,
  COUNT(*) FILTER (WHERE upper_inf(valid_period)) as current_rows,
  COUNT(*) FILTER (WHERE NOT upper_inf(valid_period)) as history_rows
FROM temporal_data;

-- Final index bloat
SELECT 
  indexname,
  pg_size_pretty(pg_relation_size(indexrelid)) as final_size,
  idx_scan as final_scans
FROM pg_stat_all_indexes
WHERE tablename = 'temporal_data'
ORDER BY indexname;

-- Table bloat
SELECT 
  n_live_tup as live,
  n_dead_tup as dead,
  ROUND(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 2) as dead_pct
FROM pg_stat_all_tables
WHERE tablename = 'temporal_data';

EOF

    echo -e "${GREEN}[+]${NC} $INDEX_CONFIG complete: $CONFIG_REPORT"
    
done

################################################################################
# SUMMARY REPORT
################################################################################

echo -e "\n${GREEN}========== SUMMARY ==========${NC}"
echo ""
echo "Report files:"
ls -lh "$OUTPUT_DIR"/write_*.txt | awk '{print "  " $9 " (" $5 ")"}'

echo ""
echo -e "${GREEN}[+]${NC} Write workload testing complete!"
echo ""
echo "Next steps:"
echo "  1. Review all phases in each report"
echo "  2. Compare query time degradation: grep 'Execution Time' $OUTPUT_DIR/write_*.txt"
echo "  3. Analyze bloat recovery: grep 'Dead Tuples\\|dead_pct' $OUTPUT_DIR/write_*.txt"
echo "  4. Check maintenance cost: grep 'REINDEX\\|VACUUM' $OUTPUT_DIR/write_*.txt"
echo ""
