#!/bin/bash
# Quick Start Guide for Checkpoint C2 Data Generation and Loading
# This demonstrates the entire workflow from data generation through benchmarking

set -e

echo "================================================================================"
echo "Checkpoint C2: Temporal Data Generation and Benchmarking Setup"
echo "================================================================================"
echo ""

# Configuration
SIZES=(100000 1000000)  # Start with 2 sizes for quick demo; expand to 5M, 10M later
CONFIGS=("history_skew" "current_skew" "balanced" "zipf_hotcurrent")
DATA_DIR="./generated_datasets"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"

mkdir -p "$DATA_DIR"

# ============================================================================
# Step 1: Generate Datasets
# ============================================================================

echo "STEP 1: Generating Temporal Datasets"
echo "────────────────────────────────────"
echo ""

for size in "${SIZES[@]}"; do
    for config in "${CONFIGS[@]}"; do
        size_name=$(printf "%dk\n" $((size / 1000)))
        output_file="$DATA_DIR/temporal_data_${size_name}_${config}.sql"
        
        if [[ -f "$output_file" ]]; then
            echo "[!] Skipping (already exists): $output_file"
        else
            echo "[*] Generating: $size rows, $config"
            python3 temporal_generator.py \
                --size "$size" \
                --config "$config" \
                --output "$output_file" \
                --seed 42
        fi
    done
done

echo ""
echo "[+] All datasets generated in $DATA_DIR"
echo ""

# ============================================================================
# Step 2: Load First Dataset and Create Indexes
# ============================================================================

echo "STEP 2: Loading First Dataset and Creating Indexes"
echo "───────────────────────────────────────────────────"
echo ""

# Pick first dataset
FIRST_DATASET="$DATA_DIR/temporal_data_100k_history_skew.sql"

if [[ ! -f "$FIRST_DATASET" ]]; then
    echo "ERROR: First dataset not found" >&2
    exit 1
fi

# Create schema
echo "[*] Creating temporal_data table..."
export PGHOST PGPORT PGUSER PGDATABASE

psql -v ON_ERROR_STOP=1 << 'SQL' > /dev/null
DROP TABLE IF EXISTS temporal_data CASCADE;

CREATE TABLE temporal_data (
    id           bigserial PRIMARY KEY,
    attr         integer NOT NULL,
    valid_period tsrange NOT NULL,
    payload      text,
    created_at   timestamp DEFAULT now()
);

CREATE INDEX temporal_gist_idx 
    ON temporal_data USING gist (valid_period);
SQL

echo "[+] Schema created"
echo ""

# Load data
echo "[*] Loading data from $FIRST_DATASET..."
start=$(date +%s)
psql -v ON_ERROR_STOP=1 -f "$FIRST_DATASET" > /dev/null 2>&1
end=$(date +%s)
load_time=$((end - start))

row_count=$(psql -t -c "SELECT COUNT(*) FROM temporal_data;")
echo "[+] Loaded $row_count rows in ${load_time}s"
echo ""

# ============================================================================
# Step 3: Display Table Statistics
# ============================================================================

echo "STEP 3: Table Statistics"
echo "───────────────────────"
echo ""

psql << 'SQL'
SELECT 
    'Total rows' as metric,
    COUNT(*)::text as value
FROM temporal_data
UNION ALL
SELECT 
    'Current rows (open-ended)',
    COUNT(*)::text
FROM temporal_data
WHERE upper_inf(valid_period)
UNION ALL
SELECT 
    'History rows (finite)',
    COUNT(*)::text
FROM temporal_data
WHERE NOT upper_inf(valid_period)
UNION ALL
SELECT
    'Attr cardinality',
    COUNT(DISTINCT attr)::text
FROM temporal_data
UNION ALL
SELECT
    'Table size (on disk)',
    pg_size_pretty(pg_total_relation_size('temporal_data'))
FROM (SELECT 1);
SQL

echo ""

# ============================================================================
# Step 4: Sample Queries
# ============================================================================

echo "STEP 4: Sample Query Execution"
echo "──────────────────────────────"
echo ""

echo "[*] Q1: History rows overlapping '2023-06-01' to '2023-12-31'"
psql -c "SELECT COUNT(*) FROM temporal_data WHERE valid_period && tsrange('2023-06-01'::timestamp, '2023-12-31'::timestamp) AND NOT upper_inf(valid_period);"
echo ""

echo "[*] Q2: Current active rows for attr=42"
psql -c "SELECT COUNT(*) FROM temporal_data WHERE attr = 42 AND upper_inf(valid_period);"
echo ""

echo "[*] Q3: All rows (current and history) containing '2023-03-15'"
psql -c "SELECT COUNT(*) FROM temporal_data WHERE valid_period @> '2023-03-15'::timestamp;"
echo ""

echo "[*] Q4: 2D range query: attr in [10,20], time in 2023"
psql -c "SELECT COUNT(*) FROM temporal_data WHERE attr BETWEEN 10 AND 20 AND valid_period && tsrange('2023-01-01'::timestamp, '2023-12-31'::timestamp);"
echo ""

# ============================================================================
# Step 5: Check Index Usage
# ============================================================================

echo "STEP 5: Verify Index Usage"
echo "──────────────────────────"
echo ""

echo "[*] EXPLAIN plan for a temporal query:"
psql << 'SQL'
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*) FROM temporal_data
WHERE valid_period && tsrange('2023-06-01'::timestamp, '2023-12-31'::timestamp);
SQL

echo ""

# ============================================================================
# Done
# ============================================================================

echo "================================================================================"
echo "Setup Complete!"
echo "================================================================================"
echo ""
echo "Next steps:"
echo "1. Load additional datasets:"
echo "   bash quick_start.sh load  # (if extended)"
echo ""
echo "2. Run full workload queries:"
echo "   psql -f workload_queries.sql"
echo ""
echo "3. Try Temporal R-tree index (if extension loaded):"
echo "   CREATE INDEX temporal_rtree_idx ON temporal_data USING temporal_rtree (valid_period);"
echo ""
echo "4. Regenerate with different sizes:"
echo "   python3 temporal_generator.py --size 5000000 --config balanced --output temporal_5m_balanced.sql"
echo ""
