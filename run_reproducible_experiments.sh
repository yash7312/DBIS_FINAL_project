#!/bin/bash
################################################################################
# Reproducible Experiment Envelope - Checkpoint C2 TODO Four
#
# Pin the build/runtime environment, rebuild PostgreSQL + extension, start a
# dedicated server, run the benchmark SQL driver, and collect exact metrics.
#
# Environment variables:
#   PGROOT   - PostgreSQL source/build root (default: $ROOT_DIR/postgresql)
#   PGDATA   - Data directory (default: $PGROOT/pgdata)
#   PGPORT   - Server port (default: 5543)
#
# Optional overrides:
#   ROOT_DIR  - Repository root (default: directory of this script)
#   LOG_DIR   - Experiment log directory (default: $ROOT_DIR/experiment_logs)
################################################################################

set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PGROOT="${PGROOT:-$ROOT_DIR/postgresql}"
PGPORT="${PGPORT:-5543}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/experiment_logs}"
PG_CONFIG_BIN="$PGROOT/install/bin/pg_config"
PSQL_BIN="$PGROOT/install/bin/psql"
PG_CTL_BIN="$PGROOT/install/bin/pg_ctl"
INITDB_BIN="$PGROOT/install/bin/initdb"
TIME_BIN="/usr/bin/time"
INSTALL_CORE="${INSTALL_CORE:-0}"

RUN_USER="${SUDO_USER:-${USER:-$(id -un)}}"
if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  PGDATA="${PGDATA:-$PGROOT/pgdata-c2-$RUN_USER}"
else
  PGDATA="${PGDATA:-$PGROOT/pgdata-c2}"
fi

export PATH="$PGROOT/install/bin:$PATH"
export LD_LIBRARY_PATH="$PGROOT/install/lib:${LD_LIBRARY_PATH:-}"
export PGHOST="${PGHOST:-localhost}"
export PGPORT="$PGPORT"
export PGUSER="${PGUSER:-$RUN_USER}"

if [ ! -d "$PGROOT" ]; then
  echo "[!] PGROOT does not exist: $PGROOT"
  echo "    Set PGROOT to your PostgreSQL source tree, for example:"
  echo "    PGROOT=\"$ROOT_DIR/postgresql\" bash run_reproducible_experiments.sh"
  exit 1
fi

run_as_bench_user() {
  if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    sudo -u "$RUN_USER" -- "$@"
  else
    "$@"
  fi
}

run_psql() {
  run_as_bench_user "$PSQL_BIN" -p "$PGPORT" "$@"
}

mkdir -p "$LOG_DIR"

RAW_LOG_DIR="$LOG_DIR/benchmark_matrix"

rm -rf "$RAW_LOG_DIR"
rm -f \
  "$LOG_DIR"/wallclock.log \
  "$LOG_DIR"/experiment_metrics.csv \
  "$LOG_DIR"/reproducibility_manifest.txt \
  "$LOG_DIR"/error_log.txt

MANIFEST_FILE="$LOG_DIR/reproducibility_manifest.txt"
WALLCLOCK_FILE="$LOG_DIR/wallclock.log"
METRICS_FILE="$LOG_DIR/experiment_metrics.csv"
DATASET_FILE="$LOG_DIR/benchmark_dataset.sql"

cat > "$MANIFEST_FILE" <<EOF
Reproducible Experiment Manifest
================================
Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)
ROOT_DIR: $ROOT_DIR
PGROOT: $PGROOT
PGDATA: $PGDATA
PGPORT: $PGPORT
PATH: $PATH
LD_LIBRARY_PATH: ${LD_LIBRARY_PATH:-}

Exact build commands:
  cd "$PGROOT"
  make -j"$(nproc)"
  if INSTALL_CORE=1, also make install

Exact extension commands:
  cd "$PGROOT/contrib/temporal_rtree"
  make PG_CONFIG="$PG_CONFIG_BIN"
  make install PG_CONFIG="$PG_CONFIG_BIN"

Exact server commands:
  initdb -D "$PGDATA"
  pg_ctl -D "$PGDATA" -o "-p $PGPORT" -l "$PGROOT/server.log" start

Exact SQL install command:
  psql -p "$PGPORT" -d test -c "CREATE EXTENSION temporal_rtree;"

Benchmark driver:
  bash "$ROOT_DIR/data_generation/run_benchmark_matrix.sh" test "$LOG_DIR/benchmark_dataset.sql" "$RAW_LOG_DIR"
EOF

echo "[1/6] Rebuilding PostgreSQL core"
cd "$PGROOT"
make -j"$(nproc)"
if [ "$INSTALL_CORE" = "1" ]; then
  make install
else
  echo "    skipping core install (set INSTALL_CORE=1 to enable privileged install)"
fi

echo "[2/6] Building temporal_rtree extension"
cd "$PGROOT/contrib/temporal_rtree"
make clean
make PG_CONFIG="$PG_CONFIG_BIN"
make install PG_CONFIG="$PG_CONFIG_BIN"

echo "[3/6] Initializing or reusing server data directory"
if [ ! -d "$PGDATA/base" ]; then
  run_as_bench_user "$INITDB_BIN" -D "$PGDATA"
fi

if ! run_as_bench_user "$PG_CTL_BIN" -D "$PGDATA" status >/dev/null 2>&1; then
  run_as_bench_user "$PG_CTL_BIN" -D "$PGDATA" -o "-p $PGPORT" -l "$PGROOT/server.log" start
fi

sleep 2

echo "[4/6] Preparing benchmark database"
if ! run_psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'test'" | grep -q 1; then
  run_psql -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE test;"
fi

run_psql -d test -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS cube;"
run_psql -d test -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS btree_gist;"
run_psql -d test -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS temporal_rtree;"

python3 "$ROOT_DIR/data_generation/temporal_generator.py" \
  --size 100000 \
  --config balanced \
  --output "$DATASET_FILE" \
  --seed 42

run_psql -d test -v ON_ERROR_STOP=1 -f "$ROOT_DIR/data_generation/schema.sql"
run_psql -d test -v ON_ERROR_STOP=1 -f "$DATASET_FILE"

echo "[5/6] Running benchmark matrix driver"
run_as_bench_user "$TIME_BIN" bash "$ROOT_DIR/data_generation/run_benchmark_matrix.sh" \
  test "$DATASET_FILE" "$RAW_LOG_DIR" \
  > "$WALLCLOCK_FILE" 2>&1

echo "[6/6] Collecting normalized metrics"
python3 "$ROOT_DIR/data_generation/collect_experiment_metrics.py" \
    --log-dir "$RAW_LOG_DIR" \
    --output "$METRICS_FILE"

echo ""
echo "Benchmark artifacts written to: $LOG_DIR"
echo "  - $MANIFEST_FILE"
echo "  - $WALLCLOCK_FILE"
echo "  - $METRICS_FILE"
echo "  - $RAW_LOG_DIR/results_*.txt"
echo "  - $RAW_LOG_DIR/metrics_*.csv"
