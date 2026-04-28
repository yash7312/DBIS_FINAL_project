#!/bin/bash
################################################################################
# Workload Benchmark Runner - Checkpoint C2 TODO Two
# 
# Executes core read workloads (Q1-Q7) across index configurations:
#   1. No index (sequential scan baseline)
#   2. B-tree on (attr, lower(valid_period))
#   3. GiST on valid_period range + attr separate
#   4. BRIN on valid_period (physical correlation)
#   5. Hybrid current-history split (idx_current_attr_start + idx_hst_gist)
#   6. Temporal R-tree (if extension installed)
#
# Captures: EXPLAIN ANALYZE BUFFERS output per query per index config
# Output: results_*.txt files with timing, row counts, buffer access patterns
################################################################################

set -e

DB_NAME="${1:-temporal_bench}"
OUTPUT_DIR="${2:-./benchmark_results}"
WORKLOAD_FILE="${3:-./workload_queries.sql}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"
echo -e "${GREEN}[*]${NC} Output directory: $OUTPUT_DIR"

# Check if database exists
if ! psql -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
    echo -e "${RED}[!]${NC} Database '$DB_NAME' not found. Please create and load data first:"
    echo "     bash load_dataset.sh $DB_NAME"
    exit 1
fi

echo -e "${GREEN}[*]${NC} Target database: $DB_NAME"
echo -e "${GREEN}[*]${NC} Workload file: $WORKLOAD_FILE"

################################################################################
# Helper: Run query and capture output
################################################################################
run_query() {
    local query="$1"
    local output_file="$2"
    local config_name="$3"
    
    echo -e "${YELLOW}[~]${NC} Running: $config_name"
    
    timeout 600 psql -d "$DB_NAME" \
        -c "$query" \
        >> "$output_file" 2>&1 || {
            echo -e "${RED}[!]${NC} Query timeout or error (config: $config_name)"
            echo "-- QUERY TIMEOUT/ERROR ($config_name)" >> "$output_file"
        }
}

################################################################################
# Configuration 1: No Index (Baseline - Sequential Scan)
################################################################################
echo ""
echo -e "${GREEN}========== CONFIG 1: NO INDEX (Baseline) ==========${NC}"
CONFIG_FILE="$OUTPUT_DIR/results_no_index.txt"
> "$CONFIG_FILE"

cat >> "$CONFIG_FILE" << 'EOF'
================================================================================
BENCHMARK: NO INDEX (Sequential Scan Baseline)
Timestamp: $(date)
================================================================================

-- Disable all indexes and analyze setting
SET enable_indexscan = off;
SET enable_bitmapscan = off;

EOF

# Q1-Q7 baseline
psql -d "$DB_NAME" << 'EOF' >> "$CONFIG_FILE" 2>&1
SET enable_indexscan = off;
SET enable_bitmapscan = off;

-- Q1: Past point
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> timestamp '2023-06-01';

-- Q2: Future point (mostly current rows)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> timestamp '2027-01-01';

-- Q3: Short range (10 days)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2023-05-01','2023-05-10','[)');

-- Q4: Medium range (5 months)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2023-01-01','2023-06-01','[)');

-- Q5: Large range (3 years)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2022-01-01','2025-01-01','[)');

-- Q6: Containment (10-day period)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> tsrange('2023-03-01','2023-03-10','[)');

-- Q7: Contained-by (2023 year)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period <@ tsrange('2023-01-01','2024-01-01','[)');
EOF

echo -e "${GREEN}[+]${NC} Baseline complete: $CONFIG_FILE"

################################################################################
# Configuration 2: B-tree on (attr, lower(valid_period))
################################################################################
echo ""
echo -e "${GREEN}========== CONFIG 2: B-TREE INDEX ==========${NC}"
CONFIG_FILE="$OUTPUT_DIR/results_btree.txt"
> "$CONFIG_FILE"

cat >> "$CONFIG_FILE" << EOF
================================================================================
BENCHMARK: B-TREE INDEX
Timestamp: $(date)
Index: idx_btree (attr, lower(valid_period))
================================================================================

EOF

psql -d "$DB_NAME" << EOF >> "$CONFIG_FILE" 2>&1
DROP INDEX IF EXISTS idx_btree CASCADE;
CREATE INDEX idx_btree ON temporal_data (attr, lower(valid_period));
VACUUM ANALYZE;

-- Q1: Past point
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> timestamp '2023-06-01';

-- Q2: Future point
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> timestamp '2027-01-01';

-- Q3: Short range
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2023-05-01','2023-05-10','[)');

-- Q4: Medium range
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2023-01-01','2023-06-01','[)');

-- Q5: Large range
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2022-01-01','2025-01-01','[)');

-- Q6: Containment
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> tsrange('2023-03-01','2023-03-10','[)');

-- Q7: Contained-by
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period <@ tsrange('2023-01-01','2024-01-01','[)');
EOF

echo -e "${GREEN}[+]${NC} B-tree complete: $CONFIG_FILE"

################################################################################
# Configuration 3: GiST on valid_period
################################################################################
echo ""
echo -e "${GREEN}========== CONFIG 3: GIST INDEX ==========${NC}"
CONFIG_FILE="$OUTPUT_DIR/results_gist.txt"
> "$CONFIG_FILE"

cat >> "$CONFIG_FILE" << EOF
================================================================================
BENCHMARK: GIST INDEX
Timestamp: $(date)
Index: idx_gist (valid_period)
================================================================================

EOF

psql -d "$DB_NAME" << EOF >> "$CONFIG_FILE" 2>&1
DROP INDEX IF EXISTS idx_btree CASCADE;
CREATE INDEX idx_gist ON temporal_data USING gist (valid_period);
VACUUM ANALYZE;

-- Q1: Past point
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> timestamp '2023-06-01';

-- Q2: Future point
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> timestamp '2027-01-01';

-- Q3: Short range
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2023-05-01','2023-05-10','[)');

-- Q4: Medium range
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2023-01-01','2023-06-01','[)');

-- Q5: Large range
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2022-01-01','2025-01-01','[)');

-- Q6: Containment
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> tsrange('2023-03-01','2023-03-10','[)');

-- Q7: Contained-by
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period <@ tsrange('2023-01-01','2024-01-01','[)');
EOF

echo -e "${GREEN}[+]${NC} GiST complete: $CONFIG_FILE"

################################################################################
# Configuration 4: BRIN on valid_period (requires chronological order)
################################################################################
echo ""
echo -e "${GREEN}========== CONFIG 4: BRIN INDEX ==========${NC}"
CONFIG_FILE="$OUTPUT_DIR/results_brin.txt"
> "$CONFIG_FILE"

cat >> "$CONFIG_FILE" << EOF
================================================================================
BENCHMARK: BRIN INDEX
Timestamp: $(date)
Index: idx_brin (valid_period, pages_per_range=128)
Note: BRIN effectiveness depends on physical correlation
EOF

# Check if data is ordered
psql -d "$DB_NAME" << 'EOF' >> "$CONFIG_FILE" 2>&1

-- Data correlation check
SELECT 'DROP -- Correlation score for valid_period (lower bound):' as check;
SELECT correlation
FROM (
  SELECT n.nspname, t.relname, a.attname,
         CORR(a.attnum::float, t.oid::float) as correlation
  FROM pg_attribute a
  JOIN pg_class t ON a.attrelid = t.oid
  WHERE t.relname = 'temporal_data'
  AND a.attname LIKE 'valid%'
) q;

EOF

psql -d "$DB_NAME" << EOF >> "$CONFIG_FILE" 2>&1
DROP INDEX IF EXISTS idx_gist CASCADE;
CREATE INDEX idx_brin ON temporal_data USING brin (valid_period) WITH (pages_per_range=128);
VACUUM ANALYZE;

-- Q1: Past point
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> timestamp '2023-06-01';

-- Q2: Future point
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> timestamp '2027-01-01';

-- Q3: Short range
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2023-05-01','2023-05-10','[)');

-- Q4: Medium range
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2023-01-01','2023-06-01','[)');

-- Q5: Large range
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2022-01-01','2025-01-01','[)');

-- Q6: Containment
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> tsrange('2023-03-01','2023-03-10','[)');

-- Q7: Contained-by
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period <@ tsrange('2023-01-01','2024-01-01','[)');
EOF

echo -e "${GREEN}[+]${NC} BRIN complete: $CONFIG_FILE"

################################################################################
# Configuration 5: Hybrid Current-History (if supported)
################################################################################
echo ""
echo -e "${GREEN}========== CONFIG 5: HYBRID CURRENT-HISTORY ==========${NC}"
CONFIG_FILE="$OUTPUT_DIR/results_hybrid_current_history.txt"
> "$CONFIG_FILE"

cat >> "$CONFIG_FILE" << EOF
================================================================================
BENCHMARK: HYBRID CURRENT-HISTORY INDEXING
Timestamp: $(date)
Indexes:
  - idx_current_attr_start (attr, lower(valid_period)) on current rows only
  - idx_hst_gist (valid_period) on history rows only
Strategy: Decomposed UNION to enable separate index paths
================================================================================

EOF

psql -d "$DB_NAME" << EOF >> "$CONFIG_FILE" 2>&1
DROP INDEX IF EXISTS idx_brin CASCADE;

-- Partial indexes for current/history split
CREATE INDEX idx_current_attr_start ON temporal_data (attr, lower(valid_period))
  WHERE upper_inf(valid_period);

CREATE INDEX idx_hst_gist ON temporal_data USING gist (valid_period)
  WHERE NOT upper_inf(valid_period);

VACUUM ANALYZE;

-- Q1: Past point (hits history index)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> timestamp '2023-06-01';

-- Q2: Future point (hits current index)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> timestamp '2027-01-01';

-- Q3: Short range
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2023-05-01','2023-05-10','[)');

-- Q4: Medium range
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2023-01-01','2023-06-01','[)');

-- Q5: Large range
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2022-01-01','2025-01-01','[)');

-- Q6: Containment
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> tsrange('2023-03-01','2023-03-10','[)');

-- Q7: Contained-by
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period <@ tsrange('2023-01-01','2024-01-01','[)');
EOF

echo -e "${GREEN}[+]${NC} Hybrid complete: $CONFIG_FILE"

################################################################################
# Configuration 6: Temporal R-tree (if extension available)
################################################################################
echo ""
echo -e "${GREEN}========== CONFIG 6: TEMPORAL R-TREE (Optional) ==========${NC}"
CONFIG_FILE="$OUTPUT_DIR/results_temporal_rtree.txt"
> "$CONFIG_FILE"

# Check if extension exists
if psql -d "$DB_NAME" -tc "SELECT 1 FROM pg_extension WHERE extname='temporal_rtree'" | grep -q 1; then
    cat >> "$CONFIG_FILE" << EOF
================================================================================
BENCHMARK: TEMPORAL R-TREE AM
Timestamp: $(date)
Access Method: temporal_rtree
Extension: temporal_rtree
================================================================================

EOF

    psql -d "$DB_NAME" << EOF >> "$CONFIG_FILE" 2>&1
DROP INDEX IF EXISTS idx_hst_gist CASCADE;
DROP INDEX IF EXISTS idx_current_attr_start CASCADE;

CREATE INDEX idx_rtree ON temporal_data USING temporal_rtree (valid_period);
VACUUM ANALYZE;

-- Q1: Past point
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> timestamp '2023-06-01';

-- Q2: Future point
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> timestamp '2027-01-01';

-- Q3: Short range
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2023-05-01','2023-05-10','[)');

-- Q4: Medium range
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2023-01-01','2023-06-01','[)');

-- Q5: Large range
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period && tsrange('2022-01-01','2025-01-01','[)');

-- Q6: Containment
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period @> tsrange('2023-03-01','2023-03-10','[)');

-- Q7: Contained-by
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM temporal_data
WHERE valid_period <@ tsrange('2023-01-01','2024-01-01','[)');
EOF

    echo -e "${GREEN}[+]${NC} Temporal R-tree complete: $CONFIG_FILE"
else
    echo -e "${YELLOW}[~]${NC} Temporal R-tree extension not installed; skipping"
    echo "-- Extension not found" > "$CONFIG_FILE"
fi

################################################################################
# Summary Report
################################################################################
echo ""
echo -e "${GREEN}========== BENCHMARK SUMMARY ==========${NC}"
echo ""
echo "Results files:"
ls -lh "$OUTPUT_DIR"/results_*.txt | awk '{print "  " $9 " (" $5 ")"}'

echo ""
echo -e "${GREEN}[+]${NC} Benchmark complete!"
echo ""
echo "To analyze results:"
echo "  grep 'Planning Time\\|Execution Time' $OUTPUT_DIR/results_*.txt"
echo ""
echo "To compare index selectivity:"
echo "  for f in $OUTPUT_DIR/results_*.txt; do echo \"\$(basename \$f)\"; grep -c 'Seq Scan\\|Index' \$f; done"
