#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project"
POSTGRES_INSTALLDIR="/home/yash7312/Desktop/Sem6/DBIS/LAB/DBIS_project/postgresql/install"
export POSTGRES_INSTALLDIR
export LD_LIBRARY_PATH="${POSTGRES_INSTALLDIR}/lib:${LD_LIBRARY_PATH:-}"
export PATH="${POSTGRES_INSTALLDIR}/bin:${PATH}"
export PGDATA="${POSTGRES_INSTALLDIR}/data"


LOG_DIR="$ROOT/logs/experiment_logs"
mkdir -p "$LOG_DIR"

# Start server only if it is not already running.
if ! pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
  pg_ctl -D "$PGDATA" -l "$POSTGRES_INSTALLDIR/logfile" start
fi

echo "psql stderr log: $LOG_DIR/error_log.txt"
exec psql -p 5433 test "$@" 2> >(tee -a "$LOG_DIR/error_log.txt" >&2)
