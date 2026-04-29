# Data Generation and Workload Framework (Checkpoint C2)

This directory contains the standardized dataset generation and workload specification for Checkpoint C2 of the temporal_rtree benchmarking campaign.

## Quick Start

### 1. Generate a Dataset

```bash
python temporal_generator.py \
  --size 1000000 \
  --ratio-open-ended 0.7 \
  --interval-mode long_tailed \
  --attr-mode zipf \
  --order-mode chrono \
  --output temporal_1m_balanced_70c_chrono.sql
```

**Parameters:**
- `--size`: Total rows (100k, 1M, 5M, 10M)
- `--ratio-open-ended`: Fraction with open-ended (current) intervals (0.7 = 70%)
- `--interval-mode`: short, medium, long_tailed
- `--attr-mode`: uniform (random), zipf (skewed)
- `--order-mode`: chrono, reverse, random
- `--output`: SQL file to generate

### 2. Load Dataset

```bash
createdb temporal_bench
psql -d temporal_bench -f schema.sql
psql -d temporal_bench -f temporal_1m_balanced_70c_chrono.sql
```

### 3. Create Index and Run Workload

```bash
# View available workloads
ls workloads/*.sql

# Create index (example: temporal_rtree)
psql -d temporal_bench <<'SQL'
CREATE EXTENSION IF NOT EXISTS cube;
CREATE EXTENSION IF NOT EXISTS temporalbox;
CREATE EXTENSION IF NOT EXISTS temporal_rtree;

CREATE INDEX idx_temporal_rtree ON temporal_data
  USING temporal_rtree (temporalbox(attr, valid_period) temporal_cube_ops);
SQL

# Run appropriate workload
psql -d temporal_bench -f workloads/query_a_b_d_attr_time.sql > results.txt
```

## Directory Structure

```
data_generation/
├── README.md                     (this file)
├── C2_STANDARDIZED_DATASETS.md  (high-level overview and recommendations)
├── CONFIGURATIONS.md             (existing C1 configurations)
│
├── schema.sql                    (temporal_data table definition)
├── temporal_generator.py          (Python data generator)
├── generate_scripts/
│   ├── generate_100k.sh          (Quick: 100k row dataset)
│   ├── generate_1m.sh            (Standard: 1M row dataset)
│   ├── generate_5m.sh            (Large: 5M row dataset)
│   └── generate_all.sh           (Full matrix: all sizes+configs)
│
├── workloads/
│   ├── q1_q7_plain_temporal.sql             (Plain tsrange queries)
│   ├── query_a_b_d_attr_time.sql            (4D attr×time queries)
│   ├── query_d_hybrid_decomposition.sql     (Current/history decomposition)
│   ├── COMPARISON_RULES.md                  (Fair comparison methodology)
│   └── RESULTS_TEMPLATE.md                  (CSV templates for logging)
│
├── benchmark_campaigns/
│   ├── PHASE_1_baseline.sh       (Generate + run small datasets)
│   ├── PHASE_2_main.sh           (1M/5M matrix with all families)
│   ├── PHASE_3_extended.sh       (10M + edge cases)
│   └── results/
│       ├── q1_q7_results.csv
│       ├── query_a_b_d_results.csv
│       └── query_d_hybrid_results.csv
│
├── collect_experiment_metrics.py (existing C1 metric collector)
├── quick_start.sh                (existing C1 quick start)
└── run_benchmark_matrix.sh       (existing C1 benchmark runner)
```

## Workload Families

### Family 1: Plain Temporal (Q1–Q7)
**File:** `workloads/q1_q7_plain_temporal.sql`

Seven temporal range queries using pure tsrange predicates:
- Q1: Point containment (present)
- Q2: Point containment (future)
- Q3–Q5: Range overlaps (short, medium, long)
- Q6: Range contains
- Q7: Range contained-by

**Fair Comparison:** [none, brin, gist_period]
**Excluded:** temporal_rtree (expression-only AM)

### Family 2: Attribute×Time Expression (Query A/B/D)
**File:** `workloads/query_a_b_d_attr_time.sql`

Three queries combining attribute and temporal dimensions:
- A: Attribute point + temporal point (4D point lookup)
- B: Attribute value + temporal range (4D range query)
- D: Current-side filter (special case, works with both expressions and btree)

**Fair Comparison:** [gist_attr_period, temporal_rtree]
**Excluded:** Plain temporal indexes

### Family 3: Hybrid Current/History Decomposition
**File:** `workloads/query_d_hybrid_decomposition.sql`

Three query variants using current/history decomposition:
- Query D (native): Single-table current-side lookup
- Hybrid UNION ALL (point): Current + history via union
- Hybrid UNION ALL (range): Current + history for range queries

**Fair Comparison:** [btree, hybrid_current_history, temporal_rtree_history (experimental)]
**Excluded:** Single-table temporal_rtree (different strategy)

## Dataset Generation Combinations (Recommended)

### Phase 1: Quick Testing (100k)
```bash
python temporal_generator.py --size 100000 --ratio-open-ended 0.7 \
  --interval-mode long_tailed --attr-mode zipf --order-mode chrono \
  --output temporal_100k_balanced_70c_chrono.sql

python temporal_generator.py --size 100000 --ratio-open-ended 0.5 \
  --interval-mode medium --attr-mode uniform --order-mode random \
  --output temporal_100k_balanced_50c_random.sql
```

### Phase 2: Full Comparison (1M)
Recommended matrix: 6 datasets × 3 workload families × 2–3 indexes each

```bash
# Distribution variations
python temporal_generator.py --size 1000000 --ratio-open-ended 0.7 \
  --interval-mode long_tailed --attr-mode zipf --order-mode chrono \
  --output temporal_1m_balanced_70c_chrono.sql

python temporal_generator.py --size 1000000 --ratio-open-ended 0.5 \
  --interval-mode medium --attr-mode uniform --order-mode random \
  --output temporal_1m_balanced_50c_random.sql

python temporal_generator.py --size 1000000 --ratio-open-ended 0.2 \
  --interval-mode short --attr-mode zipf --order-mode reverse \
  --output temporal_1m_history_skew_20c_reverse.sql

# ... (3 more combinations for variety)
```

### Phase 3: Scaling Study (5M)
Selected datasets at larger scale for cost model validation:

```bash
python temporal_generator.py --size 5000000 --ratio-open-ended 0.7 \
  --interval-mode long_tailed --attr-mode zipf --order-mode chrono \
  --output temporal_5m_balanced_70c_chrono.sql

python temporal_generator.py --size 5000000 --ratio-open-ended 0.2 \
  --interval-mode short --attr-mode uniform --order-mode random \
  --output temporal_5m_history_skew_20c_random.sql
```

## Running a Complete Benchmark Campaign

### Manual Workflow

```bash
# 1. Generate datasets
for size in 100k 1m 5m; do
  python temporal_generator.py --size $size --output temporal_${size}_balanced_70c_chrono.sql
done

# 2. Load baseline dataset
psql -d temporal_bench -f schema.sql
psql -d temporal_bench -f temporal_1m_balanced_70c_chrono.sql

# 3. Run Q1–Q7 family (plain temporal)
for index in none brin gist_period; do
  psql -d temporal_bench -c "CREATE INDEX idx_$index ON temporal_data USING $index (valid_period);" 2>/dev/null
  psql -d temporal_bench -f workloads/q1_q7_plain_temporal.sql >> results/q1_q7_${index}.txt
  psql -d temporal_bench -c "DROP INDEX idx_$index;" 2>/dev/null
done

# 4. Run Query A/B/D family (attr×time expression)
for index in gist_attr_period temporal_rtree; do
  psql -d temporal_bench -c "CREATE INDEX idx_$index ON temporal_data USING $index (temporalbox(attr, valid_period));"
  psql -d temporal_bench -f workloads/query_a_b_d_attr_time.sql >> results/query_abd_${index}.txt
  psql -d temporal_bench -c "DROP INDEX idx_$index;" 2>/dev/null
done

# 5. Run Query D family (hybrid decomposition)
# ... (similar pattern)
```

### Automated Workflow (Bash Script)

Use `benchmark_campaigns/PHASE_2_main.sh` for automated setup:

```bash
bash benchmark_campaigns/PHASE_2_main.sh \
  --database temporal_bench \
  --datasets temporal_1m_balanced_70c_chrono.sql \
  --output-dir results/
```

## Important: Fair Comparison Rules

**Do NOT:** Mix query families in result comparison tables
**Do NOT:** Compare temporal_rtree on Q1–Q7 without explicit conversion
**Do NOT:** Compare expression indexes on plain temporal queries

**DO:** Keep three separate result tables (one per family)
**DO:** Document exclusions in result headers
**DO:** Use CSV templates from `workloads/RESULTS_TEMPLATE.md`

See `workloads/COMPARISON_RULES.md` for detailed guidelines.

## Output Format

Each workload run produces EXPLAIN ANALYZE output. Example:

```
QUERY PLAN
──────────────────────────────────────────────────────────────────
Aggregate  (cost=2000.00..2000.01 rows=1 width=8)
  ->  Index Scan using idx_temporal_rtree on temporal_data
        Index Cond: (temporalbox(attr, valid_period) @> temporalbox_point(10, '2023-06-01'))
        Buffers: shared hit=600 read=2
Planning Time: 0.234 ms
Execution Time: 23.456 ms
```

The `temporal_analyzer.py` script can parse these outputs into CSV format.

## Reproducibility

All datasets use `seed=42` for Python RNG. To reproduce:

```bash
# Same dataset, same seed → identical results
python temporal_generator.py --size 1000000 --seed 42 --output v1.sql
python temporal_generator.py --size 1000000 --seed 42 --output v2.sql

# Verify identical
diff v1.sql v2.sql  # Should be empty
```

## Next Steps (C2 TODO Three and Beyond)

1. **TODO three:** Run full benchmark matrix and collect results
2. **TODO four:** Analyze performance differences and cost model fit
3. **C3:** Optimize temporal_rtree based on benchmark findings
4. **C3+:** Extend to 10M datasets and multi-core scans

## References

- Temporal Data Model: ISO/IEC 19075-2
- Benchmarking: TPC-H, Database Workload Characterization papers
- Fair Index Comparison: "Indexing Temporal Data" (Nascimento & Silva)

## Support

For questions about:
- Dataset generation: See `temporal_generator.py` docstring
- Workload families: See `workloads/COMPARISON_RULES.md`
- Results analysis: See `workloads/RESULTS_TEMPLATE.md`
