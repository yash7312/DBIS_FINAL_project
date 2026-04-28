#!/bin/bash
# Load temporal dataset and optionally create indexes for benchmarking

set -e

# Parameters
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"
DATASET_FILE="${1:?ERROR: Usage: load_dataset.sh <sql_file> [--indexes none|all|gist|temporal_rtree|brin]}"
INDEX_OPTION="${2:-none}"

export PGHOST PGPORT PGUSER PGDATABASE

# Verify file exists
if [[ ! -f "$DATASET_FILE" ]]; then
    echo "ERROR: Dataset file not found: $DATASET_FILE" >&2
    exit 1
fi

echo "[*] Loading dataset from: $DATASET_FILE"
echo "[*] PostgreSQL: $PGHOST:$PGPORT/$PGDATABASE (user: $PGUSER)"
echo ""

# Create schema
echo "[*] Creating schema..."
psql -v ON_ERROR_STOP=1 << 'EOF' > /dev/null
DROP TABLE IF EXISTS temporal_data CASCADE;

CREATE TABLE temporal_data (
    id           bigserial PRIMARY KEY,
    attr         integer NOT NULL,
    valid_period tsrange NOT NULL,
    payload      text,
    created_at   timestamp DEFAULT now()
);
EOF

echo "[+] Schema created"

# Load data
echo "[*] Loading data..."
start_time=$(date +%s)

psql -v ON_ERROR_STOP=1 -f "$DATASET_FILE" > /dev/null

end_time=$(date +%s)
load_time=$((end_time - start_time))

row_count=$(psql -t -c "SELECT COUNT(*) FROM temporal_data;")
echo "[+] Loaded $row_count rows in ${load_time}s"

# Optional: Create indexes
case "$INDEX_OPTION" in
    none|all|gist|temporal_rtree|brin)
        ;;
    *)
        echo "ERROR: invalid index option '$INDEX_OPTION' (use one of: none|all|gist|temporal_rtree|brin)" >&2
        exit 1
        ;;
esac

case "$INDEX_OPTION" in
    gist|all)
        echo "[*] Creating GiST index on valid_period..."
        start_time=$(date +%s)
        psql -v ON_ERROR_STOP=1 << 'EOF' > /dev/null
CREATE INDEX IF NOT EXISTS temporal_gist_idx 
    ON temporal_data USING gist (valid_period)
    WHERE id > 0;  -- Dummy WHERE to refresh
EOF
        end_time=$(date +%s)
        echo "[+] GiST index built in $((end_time - start_time))s"
        ;;
esac

case "$INDEX_OPTION" in
    temporal_rtree|all)
        echo "[*] Creating Temporal R-tree index (if available)..."
        if psql -t -c "SELECT 1 FROM pg_am WHERE amname='temporal_rtree';" 2>/dev/null | grep -q 1; then
            start_time=$(date +%s)
            psql -v ON_ERROR_STOP=1 << 'EOF' > /dev/null
CREATE INDEX IF NOT EXISTS temporal_rtree_idx 
    ON temporal_data USING temporal_rtree (valid_period);
EOF
            end_time=$(date +%s)
            echo "[+] Temporal R-tree index built in $((end_time - start_time))s"
        else
            echo "[!] Temporal R-tree AM not available (extension may not be loaded)"
        fi
        ;;
esac

case "$INDEX_OPTION" in
    brin|all)
        echo "[*] Creating BRIN index on valid_period..."
        start_time=$(date +%s)
        psql -v ON_ERROR_STOP=1 << 'EOF' > /dev/null
CREATE INDEX IF NOT EXISTS temporal_brin_idx 
    ON temporal_data USING brin (valid_period);
EOF
        end_time=$(date +%s)
        echo "[+] BRIN index built in $((end_time - start_time))s"
        ;;
esac

if [[ "$INDEX_OPTION" == "none" ]]; then
    echo "[*] No secondary indexes requested (INDEX_OPTION=none)"
fi

# Display table stats
echo ""
echo "[*] Table statistics:"
psql -t << 'EOF'
SELECT 
    'Rows' as metric,
    COUNT(*) as value
FROM temporal_data
UNION ALL
SELECT 
    'Current rows (open-ended)',
    COUNT(*)
FROM temporal_data
WHERE upper_inf(valid_period)
UNION ALL
SELECT 
    'History rows (finite)',
    COUNT(*)
FROM temporal_data
WHERE NOT upper_inf(valid_period)
UNION ALL
SELECT
    'Attr cardinality',
    COUNT(DISTINCT attr)
FROM temporal_data;
EOF

echo ""
echo "[+] Dataset loaded and ready for benchmarking"
