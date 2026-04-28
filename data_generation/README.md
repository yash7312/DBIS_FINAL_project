# Temporal Data Generation for Checkpoint C2

## Overview

Generates reproducible, parameterizable temporal datasets for benchmarking R-tree, GiST, and BRIN index access methods against temporal range queries.

## Motivation

The data generator must answer three key questions:
1. **Does the AM help history lookups?** (predominantly finite intervals)
2. **Does the AM help current lookups?** (predominantly open-ended rows)
3. **How does it perform under skew?** (concentrated attributes, mixed interval widths)

This is essential because:
- **BRIN** benefits from physical clustering; temporal order matters
- **GiST** split quality depends on interval width distribution and class mixing
- **Temporal R-tree (hybrid)** is optimized for current/history separation

## Dataset Parameters

### Size
- 100k, 1M, 5M, 10M rows (support all four)
- Enable testing across memory/disk boundaries

### Open-Ended Ratio (finite vs current)
- **70/30**: History-heavy (70% finite → past, 30% open → current)
- **50/50**: Balanced distribution
- **20/80**: Current-heavy (20% finite, 80% open-ended)

### Interval Width Distribution
- **short**: 1–24 hours (tight temporal windows)
- **medium**: 1 day–1 year (realistic business history)
- **long_tailed**: Pareto-like (70% short, 15% medium, 15% very long)

### Insertion Order
- **chronological**: Rows sorted by lower_ts (best for BRIN, favors sequential scans)
- **reverse**: Opposite insertion order (worst for BRIN)
- **mixed**: Random order (realistic, tests all AMs similarly)

### Attribute Skew
- **uniform**: attr ∈ [1, 100] uniformly
- **zipf**: Zipf distribution (power-law; concentrates queries on popular attrs)

### Hot-Current Fraction
- Percentage of open-ended rows concentrated in small attr subset [1–10]
- Simulates real-world "active tenant" or "hot data" patterns (e.g., 15% of current rows on 10% of attributes)

## Predefined Configurations

```
history_skew:    70% finite, short intervals, uniform attrs, chronological
current_skew:    80% open-ended, short intervals, uniform attrs, mixed order
balanced:        50% open-ended, medium intervals, uniform attrs, chronological
long_tailed:     30% open-ended, long-tailed intervals, uniform attrs, mixed order
zipf_uniform:    50% open-ended, medium intervals, zipf attrs, chronological
zipf_hotcurrent: 70% open-ended, medium intervals, zipf attrs, mixed order, hot-current
```

## Usage

### Generate Single Dataset

```bash
python3 temporal_generator.py \
  --size 1000000 \
  --config history_skew \
  --output temporal_data_1m_history.sql \
  --seed 42
```

### Generate All Benchmark Datasets

```bash
bash generate_all.sh "/path/to/output"
```

This generates **24 datasets** (4 sizes × 6 configs):
- `temporal_data_100k_history_skew.sql`
- `temporal_data_100k_current_skew.sql`
- `temporal_data_100k_balanced.sql`
- ... (and so on for 1M, 5M, 10M)

### Load Dataset into PostgreSQL

```bash
psql -U postgres -d mydb -c "$(cat schema.sql)"
psql -U postgres -d mydb -f temporal_data_1m_history_skew.sql
```

## Output Format

Each SQL file contains:
- Comment header with generation metadata
- Batch INSERT statements (1000 rows per statement, for efficiency)
- Valid `tsrange` values with proper PostgreSQL syntax

Example:
```sql
-- Generated temporal dataset: 1000000 rows
-- Timestamp: 2024-04-28T14:23:45.123456

INSERT INTO temporal_data (id, attr, valid_period, payload) VALUES
  (1, 45, '[2023-01-01 00:00:00,2023-01-02 12:00:00)'::tsrange, 'payload_0'),
  (2, 12, '[2023-01-01 01:00:00,)'::tsrange, 'payload_1'),
  ...
```

## Reproducibility

All generators use a **fixed seed (default: 42)** to ensure reproducible output across runs. Override with `--seed` if needed.

## Reproducible Experiments

Use the pinned wrapper at the repository root to rebuild, start, run, and collect metrics in one command:

```bash
cd ..
./run_reproducible_experiments.sh
```

This produces:
- `experiment_logs/results_*.txt` for EXPLAIN output
- `experiment_logs/metrics_*.csv` for index size and usage counters
- `experiment_logs/experiment_metrics.csv` as the normalized final table
- `experiment_logs/wallclock.log` for optional `/usr/bin/time -v` output

The normalized CSV records the fields needed to distinguish success from failure:
- planning time
- execution time
- estimated rows vs. actual rows
- shared hit and shared read buffers
- index size
- `pg_stat_all_indexes` usage counters
- plan family and a success/failure classification

## Files

```
data_generation/
├── temporal_generator.py    # Main generator (Python 3)
├── generate_all.sh          # Batch generation orchestrator
├── schema.sql               # Table schema for temporal_data
├── load_dataset.sh          # Convenience loader script
└── README.md                # This file
```

## Query Workloads (for benchmarking)

Typical queries answered by this data:

```sql
-- Q1: Find all active rows (current rows for an attribute)
SELECT * FROM temporal_data 
  WHERE attr = 42 
    AND valid_period @> now();

-- Q2: Find all history rows overlapping a period
SELECT * FROM temporal_data 
  WHERE valid_period && tsrange('2023-06-01', '2023-12-31');

-- Q3: Find rows containing a point in time
SELECT * FROM temporal_data 
  WHERE valid_period @> '2023-03-15'::timestamp;

-- Q4: Range scan (2D: attr and time)
SELECT * FROM temporal_data 
  WHERE attr BETWEEN 10 AND 20 
    AND valid_period && tsrange('2023-01-01', '2023-12-31');

-- Q5: Current rows with attribute predicate
SELECT COUNT(*) FROM temporal_data 
  WHERE upper_inf(valid_period) 
    AND attr IN (1, 2, 3);
```

## Testing Strategy

For each (size, config) pair:

1. **Baseline (no index)**: Sequential scan
2. **GiST index**: PostgreSQL built-in range GiST
3. **BRIN index** (if applicable): Physical-order-dependent
4. **Temporal R-tree**: Your new AM

Measure:
- Query execution time
- Index vs. sequential scan selectivity
- Memory usage
- Index build time

## Notes

- Timestamps are all within 2023 (arbitrary but fixed for reproducibility)
- `valid_period` uses PostgreSQL's native `tsrange` type
- Attribute values are clamped to [1, 100] for consistency
- Payload is MD5-like dummy data; can be expanded for realistic size testing
