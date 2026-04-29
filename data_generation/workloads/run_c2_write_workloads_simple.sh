#!/bin/bash

# C2 TODO THREE: Simplified Write Workload Test Runner
# Measures maintenance cost (INSERT/UPDATE/DELETE overhead) for temporal_rtree vs competitors
# Usage: bash run_c2_write_workloads_simple.sh [database_name] [dataset_size]

set -e

DB_NAME="${1:-c2_write_test_db}"
DATASET_SIZE="${2:-100000}"
PSQL_CMD="psql -U postgres"
EXTENSION_PATH="/home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/postgresql/contrib/temporal_rtree"

RESULTS_DIR="c2_write_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo "=== C2 TODO THREE: Write Workload Test Runner ==="
echo "Database: $DB_NAME"
echo "Dataset Size: $DATASET_SIZE rows"
echo "Results Directory: $RESULTS_DIR"
echo ""

# ============================================================
# Step 1: Setup Database
# ============================================================
echo "[1/6] Setting up database..."
$PSQL_CMD -c "DROP DATABASE IF EXISTS $DB_NAME;" 2>/dev/null || true
$PSQL_CMD -c "CREATE DATABASE $DB_NAME;"

# ============================================================
# Step 2: Create Schema and Load temporal_rtree Extension
# ============================================================
echo "[2/6] Creating schema and loading extension..."
$PSQL_CMD -d "$DB_NAME" <<-'EOF'
    -- Create temporal_rtree extension if available
    CREATE EXTENSION IF NOT EXISTS temporal_rtree;
    
    -- Create baseline table
    CREATE TABLE temporal_data (
        id BIGSERIAL PRIMARY KEY,
        attr INT,
        valid_period tsrange,
        payload TEXT
    );
    
    -- Populate initial dataset
    INSERT INTO temporal_data (attr, valid_period, payload)
    SELECT 
        (random() * 100)::int,
        tsrange(
            timestamp '2020-01-01' + ((random() * 1461)::int || ' days')::interval,
            timestamp '2024-12-31',
            '[)'
        ),
        md5(random()::text)
    FROM generate_series(1, 100000);  -- Will use $DATASET_SIZE dynamically
    
    VACUUM ANALYZE temporal_data;
EOF

echo "  ✓ Dataset initialized with $DATASET_SIZE rows"

# ============================================================
# Step 3: Create Indexes (One at a Time)
# ============================================================
echo "[3/6] Creating indexes..."

INDEX_TYPES=("none" "btree" "brin" "gist_period" "gist_attr_period" "temporal_rtree")

for index_type in "${INDEX_TYPES[@]}"; do
    case $index_type in
        none)
            echo "  ✓ Skip index creation (baseline)"
            ;;
        btree)
            $PSQL_CMD -d "$DB_NAME" -c "CREATE INDEX idx_btree ON temporal_data(lower(valid_period));" 2>&1 | head -1
            echo "  ✓ Created btree index"
            ;;
        brin)
            $PSQL_CMD -d "$DB_NAME" -c "CREATE INDEX idx_brin ON temporal_data USING BRIN(valid_period);" 2>&1 | head -1
            echo "  ✓ Created BRIN index"
            ;;
        gist_period)
            $PSQL_CMD -d "$DB_NAME" -c "CREATE INDEX idx_gist_period ON temporal_data USING GIST(valid_period);" 2>&1 | head -1
            echo "  ✓ Created GIST period index"
            ;;
        gist_attr_period)
            $PSQL_CMD -d "$DB_NAME" -c "CREATE INDEX idx_gist_attr_period ON temporal_data(attr, valid_period);" 2>&1 | head -1
            echo "  ✓ Created GIST attr×period index"
            ;;
        temporal_rtree)
            $PSQL_CMD -d "$DB_NAME" -c "CREATE INDEX idx_rtree ON temporal_data USING temporal_rtree(temporalbox(attr, valid_period)) WHERE valid_period IS NOT NULL;" 2>&1 | head -1
            echo "  ✓ Created temporal_rtree index"
            ;;
    esac
done

# ============================================================
# Step 4: Measure Write Workload Metrics
# ============================================================
echo "[4/6] Measuring write workload performance..."

# For each index type, run workload and capture metrics
for index_type in "${INDEX_TYPES[@]}"; do
    echo ""
    echo "  Testing index type: $index_type"
    results_file="$RESULTS_DIR/results_${index_type}.txt"
    
    # Run workload
    $PSQL_CMD -d "$DB_NAME" <<EOF > "$results_file" 2>&1
        -- Workload 1: INSERT 10k rows and measure
        \timing on
        INSERT INTO temporal_data (attr, valid_period, payload)
        SELECT 
            (random() * 100)::int,
            tsrange(timestamp '2024-01-01' + ((random() * 365)::int || ' days')::interval,
                    timestamp '2024-12-31', '[)'),
            md5(random()::text)
        FROM generate_series(1, 10000);
        \timing off
        
        -- Workload 2: UPDATE 1k rows (close current versions)
        \timing on
        UPDATE temporal_data
        SET valid_period = tsrange(lower(valid_period), timestamp '2024-06-01', '[)')
        WHERE upper_inf(valid_period) AND attr BETWEEN 1 AND 10
        LIMIT 1000;
        \timing off
        
        -- Workload 3: DELETE 500 rows (cold history)
        \timing on
        DELETE FROM temporal_data
        WHERE NOT upper_inf(valid_period)
          AND valid_period && tsrange('2020-01-01'::timestamp, '2021-01-01'::timestamp, '[)')
        LIMIT 500;
        \timing off
        
        -- Maintenance: VACUUM ANALYZE
        \timing on
        VACUUM ANALYZE temporal_data;
        \timing off
        
        -- Report compression
        SELECT pg_size_pretty(pg_total_relation_size('temporal_data')) AS total_size;
        SELECT count(*) AS final_row_count FROM temporal_data;
EOF
    
    echo "    ✓ Results saved to $results_file"
done

# ============================================================
# Step 5: Index Statistics Summary
# ============================================================
echo "[5/6] Collecting index statistics..."
stats_file="$RESULTS_DIR/index_stats.csv"

$PSQL_CMD -d "$DB_NAME" -t -A -F',' <<-'EOF' > "$stats_file"
    SELECT 
        indexrelname AS index_name,
        pg_relation_size(indexrelid) AS index_size_bytes,
        idx_scan AS scans,
        idx_tup_read AS tuples_read,
        idx_tup_fetch AS tuples_fetched,
        pg_size_pretty(pg_relation_size(indexrelid)) AS size_readable
    FROM pg_stat_all_indexes
    WHERE relname = 'temporal_data'
    ORDER BY indexrelname;
EOF

echo "  ✓ Index statistics saved to $stats_file"
cat "$stats_file"

# ============================================================
# Step 6: Cleanup and Summary
# ============================================================
echo "[6/6] Finalizing..."

# Optional: Save manifest
cat > "$RESULTS_DIR/manifest.txt" <<-'EOF'
C2 TODO THREE: Write Workload Test Results
Generated by run_c2_write_workloads_simple.sh
EOF

echo ""
echo "=== RESULTS SUMMARY ==="
echo "Results directory: $RESULTS_DIR"
echo "  - results_*.txt: Timing output for each index type"
echo "  - index_stats.csv: Final index statistics"
echo "  - manifest.txt: Test metadata"
echo ""
echo "To view results:"
echo "  cat $RESULTS_DIR/index_stats.csv"
echo "  head -20 $RESULTS_DIR/results_temporal_rtree.txt"
echo ""
