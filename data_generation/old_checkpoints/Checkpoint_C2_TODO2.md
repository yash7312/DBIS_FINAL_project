# Checkpoint C2 TODO Two: Workload Benchmark Execution Guide

## Overview

This document describes the exact read workloads (Q1–Q7) and the **critical hybrid decomposition strategy** required to properly benchmark temporal index access methods against a current/history partitioned dataset.

---

## Core Read Workload (Q1–Q7)

### Design Rationale

The seven queries target specific **selectivity bands** and **operator patterns**:

| Query | Operator | Range | Selectivity | Purpose |
|-------|----------|-------|-------------|---------|
| **Q1** | `@>` (contains) | `2023-06-01` | ~5-15% | History effectiveness (past date) |
| **Q2** | `@>` (contains) | `2027-01-01` | ~80-90% | Current effectiveness (future date) |
| **Q3** | `&&` (overlap) | 10 days (2023-05-01 to -10) | ~1-2% | Tight selectivity test |
| **Q4** | `&&` (overlap) | 5 months (2023-01-01 to 2023-06-01) | ~20-30% | Broad coverage; mixed |
| **Q5** | `&&` (overlap) | 3 years (2022-01-01 to 2025-01-01) | ~60-80% | Full scan tendencies |
| **Q6** | `@>` (contains) | 10-day range (2023-03-01 to -10) | ~1-3% | Verify full containment |
| **Q7** | `<@` (contained-by) | 2023 year range | ~5-8% | Reverse operator |

### Expected Selectivity Patterns

- **Low selectivity (Q1, Q3, Q6, Q7):** ~1-15% rows returned
  - Index advantage most visible
  - Test case for efficient B-tree/GiST pruning

- **Medium selectivity (Q4):** ~20-30% rows
  - Mixed current/history access
  - Good test for plan quality

- **High selectivity (Q2, Q5):** ~60-90% rows
  - Seq scan may be competitive
  - Test cache locality vs. index overhead

---

## The Decomposition Strategy

### Problem: Partial Indexes & Planner Incompleteness

Your schema uses **hybrid current-history indexing**:

```sql
CREATE INDEX idx_current_attr_start ON temporal_data (attr, lower(valid_period))
  WHERE upper_inf(valid_period);

CREATE INDEX idx_hst_gist ON temporal_data USING gist (valid_period)
  WHERE NOT upper_inf(valid_period);
```

**Without decomposition**, a query like:
```sql
SELECT count(*) FROM temporal_data
WHERE attr = 10
  AND lower(valid_period) <= timestamp '2024-01-01';
```

**Cannot** use either index because:
1. The planner sees `WHERE attr = 10 AND lower(...)` without explicit `upper_inf()`
2. The partial index filter `WHERE upper_inf(valid_period)` is a **WHERE clause condition**, not a predicate hint
3. The planner cannot safely assume the row is "current" without checking

**Result:** Full table scan, even though:
- Current rows (80% of data) could use `idx_current_attr_start`
- History rows (20% of data) could use partial scans

### Solution: Explicit Decomposition

By explicitly splitting the query with `UNION ALL`, you make the logical separation transparent:

```sql
SELECT count(*) FROM (
    -- Current rows branch: explicitly marked upper_inf = TRUE
    SELECT 1 FROM temporal_data
    WHERE upper_inf(valid_period)
      AND attr = 10
      AND lower(valid_period) <= timestamp '2024-01-01'

    UNION ALL

    -- History rows branch: explicitly marked upper_inf = FALSE
    SELECT 1 FROM temporal_data
    WHERE NOT upper_inf(valid_period)
      AND temporalbox(attr, valid_period)
            @> temporalbox_point(10, timestamp '2024-01-01')
) AS q;
```

### Why This Works

1. **Explicit filter enables partial index matching:**
   - First branch explicitly states `upper_inf(valid_period)`
   - Planner sees the WHERE clause filter matches the partial index condition
   - **Can use** `idx_current_attr_start`

2. **Clear history strategy:**
   - Second branch explicitly states `NOT upper_inf(valid_period)`
   - Planner knows only history rows are being scanned
   - **Can use** `idx_hst_gist`

3. **Conservative correctness:**
   - UNION ALL preserves all qualifying rows from both branches
   - No risk of double-counting or missing rows

### Expected Query Plans

#### Without Decomposition (❌ Poor)
```
Aggregate (Cost=1234.56)
  -> Seq Scan on temporal_data (Cost=0..1234 Rows=50000)
        Filter: (attr = 10) AND (lower(valid_period) <= 2024-01-01)
```

#### With Decomposition (✅ Good)
```
Aggregate
  -> Append
        -> Index Scan using idx_current_attr_start on temporal_data
              Index Cond: (attr = 10) AND (lower(valid_period) <= 2024-01-01)
              Filter: upper_inf(valid_period)

        -> Index Scan using idx_hst_gist on temporal_data
              Index Cond: temporalbox(...) @> temporalbox_point(...)
              Filter: NOT upper_inf(valid_period)
```

---

## Workload Structure

### File: `workload_queries.sql`

Contains three groups:

#### Section 1: Core Read Workload (Q1–Q7)
- 7 queries with `EXPLAIN (ANALYZE, BUFFERS)`
- Run **for each index configuration**
- Captures timing, row counts, and buffer access

#### Section 2: Composite Workload (Query A, B, D)
- **Query A:** `temporalbox_point` containment (2D)
- **Query B:** `temporalbox_range` overlap (2D)
- **Query D:** Current rows by attribute + start bound
- Used for temporalbox extension evaluation

#### Section 3: Decomposed Hybrid Query
- **CRITICAL:** Explicitly demonstrates index utilization
- Two branches: current (partial) + history (partial)
- Key for validating hybrid strategy effectiveness

#### Section 4: Baseline Statistics
- Data composition (current vs. history split)
- Attribute distribution (Zipf validation)
- Insertion order (chronological correlation for BRIN)

---

## Running the Benchmarks

### Step 1: Generate & Load Data

```bash
cd data_generation

# Generate dataset
python3 temporal_generator.py \
  --size 1000000 \
  --config balanced \
  --output temporal_1m.sql

# Create schema and load
psql -f schema.sql
psql -f temporal_1m.sql

# Verify composition
psql -c "SELECT 
  count(*) FILTER (WHERE upper_inf(valid_period)) as current,
  count(*) FILTER (WHERE NOT upper_inf(valid_period)) as history
FROM temporal_data;"
```

### Step 2: Run Workload Benchmark

```bash
bash run_workloads.sh temporal_bench ./benchmark_results
```

This executes:
1. **Config 1:** No index (baseline)
2. **Config 2:** B-tree on (attr, lower)
3. **Config 3:** GiST on valid_period
4. **Config 4:** BRIN on valid_period
5. **Config 5:** Hybrid current-history split
6. **Config 6:** Temporal R-tree (if available)

Output: `benchmark_results/results_*.txt` files with EXPLAIN ANALYZE output per config

### Step 3: Extract Timing Metrics

```bash
# By index config
for f in benchmark_results/results_*.txt; do
  echo "=== $(basename $f) ==="
  grep "Execution Time:" $f
done

# By query
grep -A1 "^EXPLAIN" benchmark_results/results_hybrid_current_history.txt | 
grep "Execution Time" | tail -7 | nl
```

---

## Interpreting Results

### Key Metrics from EXPLAIN ANALYZE

```
EXPLAIN (ANALYZE, BUFFERS)
...
Planning Time: X.XXX ms           <- Planner cost
Execution Time: X.XXX ms          <- Actual wall-clock time
Rows=N                            <- Estimated vs. actual match
Buffers: shared hit=K shared read=M  <- Cache efficiency
```

### Metrics Interpretation

| Metric | Low | High | Diagnosis |
|--------|-----|------|-----------|
| **Execution Time** | Good index selectivity | Poor selectivity or full scan | Check query selectivity (Q) |
| **shared hit** | Index not used (seq scan) | Good cache locality | Prefer non-sequential access |
| **shared read** | Async I/O minimized | High disk traffic | Index may be thrashing |
| **Rows** | Plan accuracy high | Planner error | Update statistics or add hints |
| **Planning Time** | Lower → simpler plans | Higher → complex planner decisions | Partial indexes may be confusing |

### Expected Patterns

#### No Index (Sequential Scan Baseline)
- **High Execution Time** for all queries
- **Constant Rows** regardless of selectivity
- **High shared read** proportional to selectivity
- Use as **baseline for speedup calculation**

#### B-tree on (attr, lower)
- **Q1-Q7:** Index used if `attr` predicate present
- **Standalone temporal queries (Q1, Q2):** Falls back to seq scan
- **Advantage:** Fast attribute lookups with time filtering

#### GiST on valid_period
- **Q1-Q7:** Effective for all range queries
- **Q2 (future point):** May still scan many rows (high selectivity)
- **Advantage:** Uniform effectiveness across query types

#### BRIN on valid_period
- **Depends on insertion order:**
  - **Chronological (ordered):** Excellent; 5-10× speedup
  - **Random (unordered):** Similar to seq scan
- **Advantage:** Smallest index size; cache-friendly

#### Hybrid Current-History (with decomposition)
- **Current-heavy queries (Q2):** Fast via `idx_current_attr_start`
- **History-heavy queries (Q1, Q3):** Fast via `idx_hst_gist`
- **Mixed queries (Q4, Q5):** Append plan with two branches
- **Advantage:** Targets each subset optimally

#### Temporal R-tree (if available)
- **Q1-Q7:** Specialized 2D range tree
- **Expected:** Better than GiST on large ranges; comparable on small
- **Advantage:** Tunable split strategy for temporal/spatial balance

---

## Analysis Strategy

### 1. Validate Decomposition Works

Check that decomposed query produces two indexes:

```sql
EXPLAIN (ANALYZE)
SELECT count(*)
FROM (
    SELECT 1 FROM temporal_data
    WHERE upper_inf(valid_period) AND attr = 10
          AND lower(valid_period) <= timestamp '2024-01-01'
    UNION ALL
    SELECT 1 FROM temporal_data
    WHERE NOT upper_inf(valid_period)
          AND temporalbox(attr, valid_period)
                @> temporalbox_point(10, timestamp '2024-01-01')
) AS q;
```

Look for:
- `Index Scan` on **both** branches (not `Seq Scan`)
- Filter conditions matched to partial indexes
- No "Filter: NOT ..." removing index benefits

### 2. Compare Index Effectiveness Across Queries

```bash
# Extract all execution times
grep "Execution Time" benchmark_results/results_*.txt | \
  awk -F: '{print $1, $4}' | \
  awk '{print $1, $NF}' | sort -k2 -nr
```

Expected ranking (for 1M balanced dataset):
1. BRIN (if ordered): ~20-50 ms
2. GiST: ~40-100 ms
3. Hybrid-decomposed: ~30-80 ms (best for current-heavy)
4. B-tree: ~50-150 ms (varies with selectivity)
5. No index: ~500-2000 ms

### 3. Validate Per-Configuration Speedups

```bash
# Baseline (no index)
baseline_ms=$(grep "Execution Time" benchmark_results/results_no_index.txt | 
              head -1 | awk '{print $NF}')

# Per config speedup
for f in benchmark_results/results_*.txt; do
  config=$(basename $f .txt | sed 's/results_//')
  mean_time=$(grep "Execution Time" $f | \
              awk '{sum+=$NF} END {print sum/NR}')
  speedup=$(echo "scale=2; $baseline_ms / $mean_time" | bc)
  echo "$config: ${speedup}x speedup"
done
```

### 4. Decomposition Efficiency Gain

Compare:
- **Without decomposition:** Hybrid config forced to seq scan
- **With decomposition:** Hybrid config uses two indexes

Expected improvement: **10-50× on current/history-biased queries**

---

## Common Issues & Fixes

### Issue: Hybrid Decomposition Shows Seq Scan

**Symptom:** EXPLAIN shows `Seq Scan` instead of `Append` with two indexes

**Cause:** Partial index not recognized by planner

**Fix:** Ensure partial index filter exactly matches WHERE clause:
```sql
-- ❌ Doesn't work
CREATE INDEX idx_current ON temporal_data (...)
  WHERE upper_inf(valid_period) AND attr > 0;

-- ✅ Works
CREATE INDEX idx_current ON temporal_data (...)
  WHERE upper_inf(valid_period);
```

### Issue: BRIN Slower Than Expected

**Symptom:** BRIN similar speed to seq scan

**Cause:** Data not ordered; BRIN relies on physical correlation

**Fix:** Use insertion order from generator:
```bash
python3 temporal_generator.py --config balanced --order chronological
```

Check correlation:
```sql
SELECT correlation FROM (
  SELECT n.nspname, t.relname,
    CORR(a.attnum::float, t.oid::float) as correlation
  FROM pg_attribute a JOIN pg_class t ON a.attrelid = t.oid
  WHERE t.relname = 'temporal_data'
) q;
```

### Issue: GiST Slower Than B-tree

**Symptom:** GiST timing worse than B-tree despite better selectivity

**Cause:** GiST page format or missing tuples

**Fix:** Reindex and update statistics:
```sql
REINDEX INDEX idx_gist;
VACUUM ANALYZE;
```

Then re-bench.

---

## Files in This Checkpoint

```
data_generation/
├── workload_queries.sql              [UPDATED] Exact Q1-Q7 + decomposed hybrid
├── run_workloads.sh                  [NEW] Benchmark driver (6 configs)
├── Checkpoint_C2_TODO2.md            [NEW] This file
└── benchmark_results/                [OUTPUT] results_*.txt (created on run)
```

---

## Next Steps (Checkpoint C2 TODO Three)

1. Run `bash run_workloads.sh` on full dataset (1M, 5M, 10M rows)
2. Aggregate results from all 6 configurations
3. Compare speedups across query patterns
4. Diagnose planner behavior via `EXPLAIN (ANALYZE, VERBOSE)`
5. Prepare for Checkpoint C3: Optimize AM based on benchmark findings

