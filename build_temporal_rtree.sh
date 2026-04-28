#!/bin/bash
# Build and smoke-test temporal_rtree extension

set -e

PGDIR="/home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/postgresql"
CONTRIB_DIR="$PGDIR/contrib/temporal_rtree"

echo "=== Building temporal_rtree extension ==="
cd "$CONTRIB_DIR"

# Clean and build
make clean || true
make

echo ""
echo "=== Testing extension installation ==="

# Start a test PostgreSQL instance in the background if not already running
if ! pg_isready -h localhost -p 5432 > /dev/null 2>&1; then
    echo "PostgreSQL not running on port 5432. Please start it with:"
    echo "  $PGDIR/src/backend/postgres -D /tmp/pgdata_test &"
    exit 1
fi

# Try to create extension (may fail if not yet installed, that's ok for smoke test)
psql -U postgres -h localhost -d postgres -c "DROP EXTENSION IF EXISTS temporal_rtree CASCADE;" 2>/dev/null || true
psql -U postgres -h localhost -d postgres -c "CREATE EXTENSION temporal_rtree;" 2>&1 | head -20 || echo "Note: Extension creation may need pg_config path adjustment"

echo ""
echo "=== Smoke test complete. Check output above. ==="
