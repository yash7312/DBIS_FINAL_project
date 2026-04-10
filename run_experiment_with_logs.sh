#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project"
TS="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="$ROOT/experiment_logs/$TS"

mkdir -p "$LOG_DIR"

# Pass connection arguments through, e.g. -h localhost -p 5433 -U postgres -d test
psql "$@" \
  -v ON_ERROR_STOP=1 \
  -v log_dir="$LOG_DIR" \
  -f "$ROOT/run_experiment.sql" \
  >"$LOG_DIR/psql_stdout.log" \
  2>"$LOG_DIR/error_log.txt"

echo "Experiment logs written to: $LOG_DIR"
echo "stderr: $LOG_DIR/error_log.txt"
