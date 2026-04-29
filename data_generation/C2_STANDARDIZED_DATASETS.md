# Checkpoint C2 TODO Two: Standardized Datasets and Workload Matrix

## Overview

This directory contains standardized datasets and workload queries for fair comparative benchmarking across multiple index types and query families.

## Dataset Standardization

### Sizes
- **100k** — Small dataset for quick testing
- **1M** — Medium dataset for repeatability
- **5M** — Large dataset for cost model evaluation
- **10M** — Extra-large (future, optional)

### Distribution Configurations
- **balanced** — Uniform attr distribution, mixed interval widths
- **current-skew** — 70/30 current/history split with hot-current attributes (Zipfian)
- **history-skew** — 20/80 current/history split, more history pruning scenarios
- **long-tailed** — Pareto-like interval widths (most short, few very long)
- **hot-attr-zipf** — High skew on low attr values (simulates real workloads)

### Current/History Ratios
- **70-current** (70% open-ended, 30% finite intervals)
- **50-current** (50/50 split)
- **20-current** (20% open-ended, 80% closed intervals)

### Insertion Order Patterns
- **chrono** — Chronologically ordered by lower timestamp
- **reverse** — Reverse chronological order
- **random** — Randomized order

### Example Dataset Names
```
temporal_100k_balanced_70current_chrono.sql
temporal_1m_current_skew_50current_random.sql
temporal_5m_history_skew_20current_reverse.sql
temporal_5m_long_tailed_70current_random.sql
```

## Query Workload Families

### Q1–Q7: Plain Temporal (tsrange only)
**Supported Indexes:** none (seq scan), brin, gist_period (tsrange AM), direct-range paths

**Queries:**
- Q1: Point containment — `valid_period @> timestamp`
- Q2: Point containment future — `valid_period @> timestamp (future)`
- Q3: Short range overlap — `valid_period && tsrange(..., ..., '[)')`
- Q4: Medium range overlap — `valid_period && tsrange(..., ..., '[)')`
- Q5: Long range overlap — `valid_period && tsrange(..., ..., '[)')`
- Q6: Range contained by — `valid_period @> tsrange(..., ..., '[)')`
- Q7: Range is contained-by — `valid_period <@ tsrange(..., ..., '[)')`

**File:** `workloads/q1_q7_plain_temporal.sql`
**Comparison Method:** Run each query on none, brin, gist_period; temporal_rtree excluded (not comparable family)

### Query A/B/D: Attr×Time (temporalbox expressions)
**Supported Indexes:** gist_attr_period (GiST on expression), temporal_rtree

**Queries:**
- A: Point lookup on attribute + temporal point — `temporalbox(...) @> temporalbox_point(...)`
- B: Attribute range + temporal range — `temporalbox(...) && temporalbox_range(...)`
- D: Current-side query — `upper_inf(valid_period) AND attr = X AND lower(...)`

**File:** `workloads/query_a_b_d_attr_time.sql`
**Comparison Method:** Run on gist_attr_period vs. temporal_rtree only

### Query D + Hybrid: Current/History Decomposition
**Supported Indexes:** btree (on attr), hybrid_current_history (in-table decomposition), history-side expression indexes

**Queries:**
- D-native: Current-side btree filter
- Hybrid-union: UNION ALL decomposition of current vs. history

**File:** `workloads/query_d_hybrid_decomposition.sql`
**Comparison Method:** Run on btree, hybrid_current_history; temporal_rtree excluded

## Fair Comparison Methodology

### Key Rules

1. **Never mix query families in one result table**
   - Q1–Q7 results are separate from Query A/B/D results
   - Hybrid results are separate again

2. **Only compare compatible index types to query predicates**
   - Plain temporal queries: none, brin, gist_period only
   - Attr×time queries: gist_attr_period vs. temporal_rtree only
   - Hybrid decomposition: btree, hybrid_current_history only

3. **Exclude temporal_rtree from Q1–Q7 comparisons**
   - Reason: temporal_rtree only supports temporalbox expressions, not raw tsrange
   - temporal_rtree cannot fairly compete on Q1–Q7

4. **Exclude plain-AM paths from Query A/B/D comparisons**
   - Reason: GiST and temporal_rtree support expressions; btree and BRIN do not
   - Results would be biased toward expression AMs

### Result Table Template

**Example: Q1–Q7 Plain Temporal**
```
| Dataset        | Query | Size | Rows Returned | none_ms | brin_ms | gist_period_ms | Notes       |
|----------------|-------|------|---------------|---------|---------|----------------|-------------|
| balanced_70c   | Q1    | 1M   | 450123        | 1842    | 234     | 189            | Hot period  |
| ...            |       |      |               |         |         |                |             |
```

**Example: Query A/B/D Attr×Time**
```
| Dataset        | Query | Size | Rows Returned | gist_attr_period_ms | temporal_rtree_ms | Winner |
|----------------|-------|------|---------------|---------------------|-------------------|--------|
| balanced_70c   | A     | 1M   | 45123         | 45                  | 23                | rtree  |
| ...            |       |      |               |                     |                   |        |
```

## Configuration: Dataset and Workload Combinations

### Recommended Matrix (Phase 1)
1. **100k datasets** (quick smoke tests)
   - balanced_70c_chrono
   - current_skew_50c_random

2. **1M datasets** (primary comparison)
   - balanced_70c_chrono
   - balanced_70c_random
   - current_skew_50c_random
   - history_skew_20c_reverse
   - long_tailed_70c_random
   - hot_attr_zipf_50c_random

3. **5M datasets** (cost model validation)
   - balanced_70c_random
   - current_skew_70c_random
   - history_skew_20c_random

### Workload Combinations

For each dataset:
1. Run Q1–Q7 on [none, brin, gist_period]
2. Run Query A/B/D on [gist_attr_period, temporal_rtree]
3. Run Query D + Hybrid on [btree, hybrid_current_history]
4. Optionally: Run Query A/B with force_rtree_paths=on vs. off to measure planner bias impact

## Files in This Directory

- `DATASETS.md` — Dataset generation commands and parameters
- `q1_q7_plain_temporal.sql` — Plain temporal queries
- `query_a_b_d_attr_time.sql` — Attribute×time queries
- `query_d_hybrid_decomposition.sql` — Current/history decomposition queries
- `COMPARISON_RULES.md` — Detailed fair comparison methodology
- `generate_datasets.sh` — Bash script to generate all datasets
- `run_workloads.sh` — Run workloads with proper index setup
- `RESULTS_TEMPLATE.csv` — Template for recording results

## Running a Benchmark Campaign

```bash
# Generate dataset (example: 1M balanced with 70/30 current/history split, chronological order)
python temporal_generator.py --size 1000000 \
  --ratio-open-ended 0.7 \
  --interval-mode long_tailed \
  --attr-mode zipf \
  --order-mode chrono \
  --output temporal_1m_balanced_70c_chrono.sql

# Load dataset
psql -d temporal_bench -f temporal_1m_balanced_70c_chrono.sql

# Create temporal_rtree index (with force_rtree_paths off by default)
psql -d temporal_bench <<'SQL'
SET temporal_rtree.force_rtree_paths = off;
CREATE INDEX idx_temporal_rtree ON temporal_data 
  USING temporal_rtree (temporalbox(attr, valid_period) temporal_cube_ops);
SQL

# Run workloads
psql -d temporal_bench -f workloads/q1_q7_plain_temporal.sql > results/q1_q7_balanced_70c_500k.txt
psql -d temporal_bench -f workloads/query_a_b_d_attr_time.sql > results/query_abd_balanced_70c_1m.txt

# Optionally: Repeat with force_rtree_paths on to measure planner bias
```

## Notes on Dataset Generation

- All datasets use seed=42 for reproducibility
- Base timestamp: 2023-01-01 for consistency
- attr values: [1, 100] for meaningful 2D queries
- valid_period: 10-year span enables long-tail interval testing
- Payload: md5(id) for realistic memory footprint without I/O overhead

## Future Extensions

- 10M datasets for memory stress testing
- Parallel dataset generation for faster setup
- Automated result comparison and statistical significance testing
- Timeline plots of cost vs. dataset size
