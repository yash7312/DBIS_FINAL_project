#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PGROOT="${PGROOT:-$ROOT_DIR/postgresql}"
PGDATA="${PGDATA:-$PGROOT/pgdata-crash-restart}"
PGPORT="${PGPORT:-5540}"
PSQL_BIN="$PGROOT/install/bin/psql"
PG_CTL_BIN="$PGROOT/install/bin/pg_ctl"
INITDB_BIN="$PGROOT/install/bin/initdb"

export PATH="$PGROOT/install/bin:$PATH"
export LD_LIBRARY_PATH="$PGROOT/install/lib:${LD_LIBRARY_PATH:-}"
export PGHOST=localhost
export PGPORT="$PGPORT"
export PGUSER="${PGUSER:-${USER:-$(id -un)}}"

cleanup() {
  if [ -d "$PGDATA" ]; then
    "$PG_CTL_BIN" -D "$PGDATA" stop -m fast >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

run_psql() {
  "$PSQL_BIN" -p "$PGPORT" -d postgres -v ON_ERROR_STOP=1 "$@"
}

rm -rf "$PGDATA"
"$INITDB_BIN" -D "$PGDATA" >/dev/null
"$PG_CTL_BIN" -D "$PGDATA" -o "-p $PGPORT" -l "$ROOT_DIR/temporal_rtree_crash_restart.log" start >/dev/null
sleep 2

run_psql <<'SQL'
CREATE EXTENSION IF NOT EXISTS cube;
CREATE EXTENSION IF NOT EXISTS temporalbox;
CREATE EXTENSION IF NOT EXISTS temporal_rtree;

DROP TABLE IF EXISTS temporal_data;
CREATE TABLE temporal_data (
    id int PRIMARY KEY,
    attr int NOT NULL,
    valid_period tsrange NOT NULL,
    data text
);

INSERT INTO temporal_data
SELECT g,
       10,
       tsrange(timestamp '2020-01-01' + ((g || ' hours')::interval),
               timestamp '2020-01-02' + ((g || ' hours')::interval),
               '[)'),
       md5(g::text)
FROM generate_series(1, 2000) AS g;

CREATE INDEX temporal_idx ON temporal_data USING temporal_rtree (temporalbox(attr, valid_period) temporal_cube_ops);
SQL

baseline_seq="$($PSQL_BIN -p "$PGPORT" -d postgres -Atq -v ON_ERROR_STOP=1 <<'SQL'
SET enable_seqscan = on;
SET enable_bitmapscan = on;
SET enable_indexscan = off;
SELECT count(*)
FROM temporal_data
WHERE temporalbox(attr, valid_period)
      && temporalbox_range(10, timestamp '2020-01-01', timestamp '2020-12-31');
SQL
)"

baseline_idx="$($PSQL_BIN -p "$PGPORT" -d postgres -Atq -v ON_ERROR_STOP=1 <<'SQL'
SET enable_seqscan = off;
SET enable_bitmapscan = off;
SET enable_indexscan = on;
SELECT count(*)
FROM temporal_data
WHERE temporalbox(attr, valid_period)
      && temporalbox_range(10, timestamp '2020-01-01', timestamp '2020-12-31');
SQL
)"

if [ "$baseline_seq" != "$baseline_idx" ]; then
  echo "Baseline count mismatch before crash: seq=$baseline_seq idx=$baseline_idx" >&2
  exit 1
fi

"$PG_CTL_BIN" -D "$PGDATA" stop -m immediate >/dev/null
sleep 2
"$PG_CTL_BIN" -D "$PGDATA" -o "-p $PGPORT" -l "$ROOT_DIR/temporal_rtree_crash_restart.log" start >/dev/null
sleep 2

after_seq="$($PSQL_BIN -p "$PGPORT" -d postgres -Atq -v ON_ERROR_STOP=1 <<'SQL'
SET enable_seqscan = on;
SET enable_bitmapscan = on;
SET enable_indexscan = off;
SELECT count(*)
FROM temporal_data
WHERE temporalbox(attr, valid_period)
      && temporalbox_range(10, timestamp '2020-01-01', timestamp '2020-12-31');
SQL
)"

after_idx="$($PSQL_BIN -p "$PGPORT" -d postgres -Atq -v ON_ERROR_STOP=1 <<'SQL'
SET enable_seqscan = off;
SET enable_bitmapscan = off;
SET enable_indexscan = on;
SELECT count(*)
FROM temporal_data
WHERE temporalbox(attr, valid_period)
      && temporalbox_range(10, timestamp '2020-01-01', timestamp '2020-12-31');
SQL
)"

echo "baseline_seq=$baseline_seq"
echo "baseline_idx=$baseline_idx"
echo "after_seq=$after_seq"
echo "after_idx=$after_idx"

if [ "$after_seq" != "$after_idx" ] || [ "$baseline_seq" != "$after_seq" ]; then
  echo "Recovery check failed after immediate crash/restart" >&2
  exit 1
fi

echo "Crash/restart verification passed"