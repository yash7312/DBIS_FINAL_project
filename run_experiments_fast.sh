#!/bin/bash
################################################################################
# Fast Reproducible Experiment Runner
# Assumes PostgreSQL is already built; just runs the benchmarks
################################################################################

set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PGROOT="${PGROOT:-$ROOT_DIR/postgresql}"
PGPORT="${PGPORT:-5433}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/experiment_logs}"
PG_CONFIG_BIN="$PGROOT/install/bin/pg_config"
PSQL_BIN="$PGROOT/install/bin/psql"
PG_CTL_BIN="$PGROOT/install/bin/pg_ctl"
INITDB_BIN="$PGROOT/install/bin/initdb"

PGDATA="${PGDATA:-$PGROOT/pgdata}"
export PATH="$PGROOT/install/bin:$PATH"
export LD_LIBRARY_PATH="$PGROOT/install/lib:${LD_LIBRARY_PATH:-}"
export PGHOST="${PGHOST:-localhost}"
export PGPORT="$PGPORT"
export PGUSER="${PGUSER:-postgres}"
export PGDATABASE="test"

mkdir -p "$LOG_DIR"

rm -f "$LOG_DIR"/results_*.txt "$LOG_DIR"/metrics_*.csv "$LOG_DIR"/wallclock.log

echo "[1/4] Building temporal_rtree extension"
cd "$PGROOT/contrib/temporal_rtree"
make clean
make PG_CONFIG="$PG_CONFIG_BIN"
make install PG_CONFIG="$PG_CONFIG_BIN"

echo "[2/4] Starting PostgreSQL server on port $PGPORT"
if [ ! -d "$PGDATA/base" ]; then
  "$INITDB_BIN" -D "$PGDATA"
fi

if ! "$PG_CTL_BIN" -D "$PGDATA" status >/dev/null 2>&1; then
  "$PG_CTL_BIN" -D "$PGDATA" -o "-p $PGPORT" -l "$PGROOT/server.log" start
  sleep 3
fi

echo "[3/4] Preparing benchmark database"
$PSQL_BIN -p $PGPORT -d postgres -tAc "SELECT 1" >/dev/null 2>&1 || { echo "Server not responding"; exit 1; }

if ! $PSQL_BIN -p $PGPORT -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'test'" | grep -q 1; then
  $PSQL_BIN -p $PGPORT -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE test;"
fi

$PSQL_BIN -p $PGPORT -d test -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS cube;"
$PSQL_BIN -p $PGPORT -d test -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS btree_gist;"
$PSQL_BIN -p $PGPORT -d test -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS temporal_rtree;"

echo "[*] Generating dataset"
python3 "$ROOT_DIR/data_generation/temporal_generator.py" \
  --size 100000 \
  --config balanced \
  --output "$LOG_DIR/benchmark_dataset.sql" \
  --seed 42

echo "[*] Loading schema"
$PSQL_BIN -p $PGPORT -d test -v ON_ERROR_STOP=1 -f "$ROOT_DIR/data_generation/schema.sql" >/dev/null

echo "[*] Loading data"
$PSQL_BIN -p $PGPORT -d test -v ON_ERROR_STOP=1 -f "$LOG_DIR/benchmark_dataset.sql" >/dev/null

echo "[4/4] Running benchmark matrix"
export PGHOST PGPORT PGUSER PGDATABASE
bash "$ROOT_DIR/data_generation/run_benchmark_matrix.sh" test "$LOG_DIR/benchmark_dataset.sql" "$LOG_DIR"

echo ""
echo "✓ Benchmark artifacts written to: $LOG_DIR"
echo "✓ Results files:"
ls -lh "$LOG_DIR"/results_*.txt "$LOG_DIR"/metrics_*.csv 2>/dev/null | awk '{print "  " $9, "(" $5 ")"}'
