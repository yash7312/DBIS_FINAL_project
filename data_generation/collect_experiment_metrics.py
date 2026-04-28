#!/usr/bin/env python3
"""Collect reproducible experiment metrics from benchmark logs.

This parser combines:
- EXPLAIN (ANALYZE, BUFFERS) text output from results_*.txt
- maintenance snapshots from metrics_*.csv

It emits one CSV row per query block with the exact fields needed to
separate success from failure during temporal index evaluation.
"""

from __future__ import annotations

import argparse
import csv
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


QUERY_LABEL_RE = re.compile(r'^(Q\d+\b.*|Query [A-Z]\b.*|Query HYBRID_DECOMPOSED\b.*)')
PLAN_LINE_RE = re.compile(
    r'^(?P<indent>\s*)(?P<node>Append|Seq Scan|Index Only Scan|Index Scan|Bitmap Heap Scan|Bitmap Index Scan)\b.*?'
    r'cost=(?P<est_start>[0-9.]+)\.\.(?P<est_end>[0-9.]+)\s+rows=(?P<est_rows>[0-9]+).*?'
    r'actual time=(?P<act_start>[0-9.]+)\.\.(?P<act_end>[0-9.]+)\s+rows=(?P<act_rows>[0-9]+)',
    re.IGNORECASE,
)
PLANNING_RE = re.compile(r'Planning Time:\s+([0-9.]+) ms')
EXECUTION_RE = re.compile(r'Execution Time:\s+([0-9.]+) ms')
BUFFERS_RE = re.compile(r'Buffers:\s+shared hit=([0-9]+)(?:\s+read=([0-9]+))?')
INDEX_NAME_RE = re.compile(r'(?:using|on)\s+(idx[a-zA-Z0-9_]+)')


@dataclass
class MetricsSnapshot:
    index_config: str
    index_names: str
    index_count: int
    total_index_size_bytes: int
    total_index_size_pretty: str
    total_idx_scan: int
    total_idx_tup_read: int
    total_idx_tup_fetch: int
    n_live_tup: int
    n_dead_tup: int
    n_mod_since_analyze: int
    table_size_bytes: int
    table_size_pretty: str
    snapshot_ts: str


def normalize_label(label: str) -> str:
    return label.split('—', 1)[0].strip()


def classify_plan(block_text: str) -> tuple[str, str]:
    lines = block_text.splitlines()
    observed = 'Unknown'
    for line in lines:
        match = PLAN_LINE_RE.match(line)
        if match:
            observed = match.group('node')
            break

    if observed == 'Unknown':
        if 'Seq Scan' in block_text:
            observed = 'Seq Scan'
        elif 'Index Only Scan' in block_text:
            observed = 'Index Only Scan'
        elif 'Index Scan' in block_text:
            observed = 'Index Scan'
        elif 'Bitmap Index Scan' in block_text or 'Bitmap Heap Scan' in block_text:
            observed = 'Bitmap'
        elif 'Append' in block_text:
            observed = 'Append'

    if observed == 'Append':
        scan_count = len(re.findall(r'\b(?:Index Only Scan|Index Scan|Bitmap Index Scan|Bitmap Heap Scan|Seq Scan)\b', block_text))
        if scan_count >= 2:
            return observed, 'two-index-branches'

    return observed, ''


def extract_first(regex: re.Pattern[str], text: str, default: str = '') -> str:
    match = regex.search(text)
    return match.group(1) if match else default


def extract_last(regex: re.Pattern[str], text: str, default: str = '') -> str:
    matches = regex.findall(text)
    if not matches:
        return default
    last = matches[-1]
    if isinstance(last, tuple):
        # For optional capture groups, keep the non-empty value.
        for value in reversed(last):
            if value:
                return value
        return default
    return last


def parse_metrics_snapshot(path: Path) -> MetricsSnapshot | None:
    if not path.exists():
        return None

    with path.open(newline='') as handle:
        reader = csv.DictReader(handle)
        rows = list(reader)

    if not rows:
        return None

    row = rows[0]
    return MetricsSnapshot(
        index_config=row['index_config'],
        index_names=row['index_names'],
        index_count=int(row['index_count']),
        total_index_size_bytes=int(row['total_index_size_bytes']),
        total_index_size_pretty=row['total_index_size_pretty'],
        total_idx_scan=int(row['total_idx_scan']),
        total_idx_tup_read=int(row['total_idx_tup_read']),
        total_idx_tup_fetch=int(row['total_idx_tup_fetch']),
        n_live_tup=int(row['n_live_tup']),
        n_dead_tup=int(row['n_dead_tup']),
        n_mod_since_analyze=int(row['n_mod_since_analyze']),
        table_size_bytes=int(row['table_size_bytes']),
        table_size_pretty=row['table_size_pretty'],
        snapshot_ts=row['snapshot_ts'],
    )


def iter_query_blocks(path: Path) -> Iterable[tuple[str, str]]:
    current_label = None
    current_lines: list[str] = []

    with path.open() as handle:
        for line in handle:
            stripped = line.rstrip('\n')
            match = QUERY_LABEL_RE.match(stripped)
            if match:
                if current_label and current_lines:
                    yield current_label, '\n'.join(current_lines)
                current_label = normalize_label(match.group(1))
                current_lines = []
                continue

            if current_label:
                current_lines.append(stripped)

    if current_label and current_lines:
        yield current_label, '\n'.join(current_lines)


def expected_plan_family(config: str, query_label: str) -> str:
    base = normalize_label(query_label)

    if config == 'no_index':
        return 'Seq Scan'

    if base in {'Q1', 'Q2', 'Q3', 'Q4', 'Q6', 'Q7'}:
        return 'Index/Bitmap'

    if base == 'Q5':
        return 'Seq Scan or Index'

    if base == 'Query D':
        return 'Bitmap Index Scan'

    if base == 'Query G':
        return 'two index branches'

    if base in {'Query A', 'Query B'}:
        return 'Index/Bitmap'

    return 'Index/Bitmap'


def classify_status(config: str, query_label: str, observed: str, notes: str) -> str:
    base = normalize_label(query_label)

    if config == 'no_index':
        return 'success' if observed == 'Seq Scan' else 'failure'

    if base == 'Q5':
        return 'acceptable' if observed == 'Seq Scan' else 'success'

    if base == 'Query G':
        return 'success' if observed == 'Append' and notes == 'two-index-branches' else 'failure'

    if base == 'Query D':
        return 'success' if 'Index' in observed or 'Bitmap' in observed else 'failure'

    if base in {'Query A', 'Query B'}:
        return 'success' if observed in {'Index Scan', 'Index Only Scan', 'Bitmap'} else 'failure'

    return 'success' if observed != 'Seq Scan' else 'failure'


def main() -> int:
    parser = argparse.ArgumentParser(description='Collect benchmark metrics into a CSV file.')
    parser.add_argument('--log-dir', required=True, help='Directory containing results_*.txt and metrics_*.csv')
    parser.add_argument('--output', required=True, help='Output CSV path')
    args = parser.parse_args()

    log_dir = Path(args.log_dir)
    output = Path(args.output)

    rows = []
    for result_file in sorted(log_dir.glob('results_*.txt')):
        config = result_file.stem.replace('results_', '')
        snapshot = parse_metrics_snapshot(log_dir / f'metrics_{config}.csv')

        for query_label, block_text in iter_query_blocks(result_file):
            plan_match = PLAN_LINE_RE.search(block_text)
            observed, notes = classify_plan(block_text)
            est_rows = plan_match.group('est_rows') if plan_match else ''
            actual_rows = plan_match.group('act_rows') if plan_match else ''
            planning_ms = extract_last(PLANNING_RE, block_text)
            execution_ms = extract_last(EXECUTION_RE, block_text)
            buffer_matches = BUFFERS_RE.findall(block_text)
            shared_hit = buffer_matches[-1][0] if buffer_matches else ''
            shared_read = buffer_matches[-1][1] if buffer_matches and buffer_matches[-1][1] else '0' if buffer_matches else ''
            index_name_match = INDEX_NAME_RE.search(block_text)
            index_name = index_name_match.group(1) if index_name_match else ''

            row = {
                'index_config': config,
                'query': query_label,
                'expected_plan_family': expected_plan_family(config, query_label),
                'observed_plan_family': observed,
                'index_name': index_name,
                'est_rows': est_rows,
                'actual_rows': actual_rows,
                'planning_ms': planning_ms,
                'execution_ms': execution_ms,
                'shared_hit': shared_hit,
                'shared_read': shared_read,
                'status': classify_status(config, query_label, observed, notes),
                'notes': notes,
            }

            if snapshot is not None:
                row.update({
                    'index_names': snapshot.index_names,
                    'index_count': snapshot.index_count,
                    'total_index_size_bytes': snapshot.total_index_size_bytes,
                    'total_index_size_pretty': snapshot.total_index_size_pretty,
                    'total_idx_scan': snapshot.total_idx_scan,
                    'total_idx_tup_read': snapshot.total_idx_tup_read,
                    'total_idx_tup_fetch': snapshot.total_idx_tup_fetch,
                    'n_live_tup': snapshot.n_live_tup,
                    'n_dead_tup': snapshot.n_dead_tup,
                    'n_mod_since_analyze': snapshot.n_mod_since_analyze,
                    'table_size_bytes': snapshot.table_size_bytes,
                    'table_size_pretty': snapshot.table_size_pretty,
                    'snapshot_ts': snapshot.snapshot_ts,
                })
            else:
                row.update({
                    'index_names': '',
                    'index_count': '',
                    'total_index_size_bytes': '',
                    'total_index_size_pretty': '',
                    'total_idx_scan': '',
                    'total_idx_tup_read': '',
                    'total_idx_tup_fetch': '',
                    'n_live_tup': '',
                    'n_dead_tup': '',
                    'n_mod_since_analyze': '',
                    'table_size_bytes': '',
                    'table_size_pretty': '',
                    'snapshot_ts': '',
                })

            rows.append(row)

    fieldnames = [
        'index_config',
        'query',
        'expected_plan_family',
        'observed_plan_family',
        'index_name',
        'est_rows',
        'actual_rows',
        'planning_ms',
        'execution_ms',
        'shared_hit',
        'shared_read',
        'index_names',
        'index_count',
        'total_index_size_bytes',
        'total_index_size_pretty',
        'total_idx_scan',
        'total_idx_tup_read',
        'total_idx_tup_fetch',
        'n_live_tup',
        'n_dead_tup',
        'n_mod_since_analyze',
        'table_size_bytes',
        'table_size_pretty',
        'snapshot_ts',
        'status',
        'notes',
    ]

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('w', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    print(f'Wrote {len(rows)} rows to {output}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
