# Checkpoint C2 TODO TWO: Benchmark Matrix Configuration

Complete specification of datasets, distributions, and query families for C2 benchmarking campaign.

## Dataset Matrix

### Size × Distribution × Current/History Ratio × Insertion Order

#### 100k Datasets (Phase 1: Quick Smoke Tests)
- **100k_balanced_70c_chrono** — balanced dist, 70% current, chrono order
- **100k_current_skew_50c_random** — current-skew dist, 50% current, random order

#### 1M Datasets (Phase 2: Primary Comparison)
**Distribution:** balanced, current-skew, history-skew, long-tailed, hot-attr-zipf
**Current/History:** 70/30, 50/50, 20/80
**Order:** chrono, reverse, random

**Recommended 1M Combinations** (5 datasets):
1. `temporal_1m_balanced_70c_chrono`
2. `temporal_1m_current_skew_50c_random`
3. `temporal_1m_history_skew_20c_reverse`
4. `temporal_1m_long_tailed_70c_random`
5. `temporal_1m_hot_attr_zipf_50c_random`

#### 5M Datasets (Phase 3: Cost Model Validation)
**Recommended 5M Combinations** (3 datasets):
1. `temporal_5m_balanced_70c_random`
2. `temporal_5m_current_skew_50c_random`
3. `temporal_5m_history_skew_20c_random`

#### 10M Datasets (Future: Memory/Scaling Study)
- `temporal_10m_balanced_70c_random` (optional Phase 4)

---

## Query Workload × Index Combinations

### Family 1: Plain Temporal (Q1–Q7)

**Workload File:** `workloads/q1_q7_plain_temporal.sql`

**Index Chart:**
| Index Type | Strategy | Q1 | Q2 | Q3 | Q4 | Q5 | Q6 | Q7 | Notes |
|-----------|----------|----|----|----|----|----|----|----|---------  |
| none | seq scan | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | Baseline |
| brin | lossy range | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | Fast bitmap scan |
| gist_period | direct GiST | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | Best for ranges |
| temporal_rtree | 4D AM | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | Incompatible (expression-only) |

**Fair Comparison Formula:**
```
For each dataset (1m_balanced_70c, 1m_current_skew_50c, ...):
  For each index in [none, brin, gist_period]:
    Create index
    Run Q1–Q7
    Record results
    Drop index
Results: 3 tables × 7 queries × 2–5 datasets = 42–70 result rows
```

---

### Family 2: Attribute×Time Expression (Query A/B/D)

**Workload File:** `workloads/query_a_b_d_attr_time.sql`

**Index Chart:**
| Index Type | Strategy | Query A | Query B | Query D | Plan Type | force_rtree_paths | Notes |
|-----------|----------|---------|---------|---------|-----------|----------|----------|
| gist_attr_period | GiST expr | ✓ | ✓ | ✓ | Idx Scan | N/A | Direct expression indexing |
| temporal_rtree | 4D AM | ✓ | ✓ | ✓ | Idx Scan | yes/no | Path can be biased |
| none | seq scan | ✗ (too slow) | ✗ | ✗ | Seq Scan | N/A | Deliberately excluded |
| brin, gist_period | plain temporal | ✗ | ✗ | ✓ (only D) | N/A | Can't index expressions |

**Fair Comparison Formula:**
```
For each dataset (1m_balanced_70c, 1m_current_skew_50c, ...):
  For each combo of (index, force_rtree_paths) where index in [gist_attr_period, temporal_rtree]:
    Create index
    For each force_rtree_paths in [FALSE, TRUE]:
      SET temporal_rtree.force_rtree_paths = force_rtree_paths;
      Run Query A, Query B, Query D
      Record results
    Drop index
Results: 2 indexes × 2 settings × 3 queries × 5 datasets = 60 result rows
```

**Plan Bias Measurement:**
- Query A/B/D run with force_rtree_paths=off (natural planner)
- Query A/B/D run with force_rtree_paths=on (biased planner)
- Compare wall-clock times to measure planner bias effectiveness

---

### Family 3: Hybrid Current/History Decomposition

**Workload File:** `workloads/query_d_hybrid_decomposition.sql`

**Index Chart:**
| Index Strategy | Query D (native) | Hybrid Union (point) | Hybrid Union (range) | Notes |
|---------|---------|---------|---------|----------|
| btree(attr, lower) | ✓ | Part (current side) | Part | Native btree lookup |
| hybrid_current_history | Part | ✓ | ✓ | Decomposed tables |
| temporal_rtree (history-only) | ✗ | Part (history side) | Part | Experimental variant |
| single-table temporal_rtree | ✗ | ✗ | ✗ | Different strategy |

**Fair Comparison Formula:**
```
For each dataset (1m_balanced_70c, ...):
  For Query D (native):
    Create btree(attr, lower_timestamp)
    Run Query D (native)
    Record results
  
  For Hybrid Union queries:
    Create btree(attr, lower_timestamp) current side
    Create GiST/temporal_rtree history side
    Run Hybrid Union (point) and Hybrid Union (range)
    Record results (different from single-table)
Results: 1 simple + 2 hybrid × 5 datasets = 15 result rows
```

---

## Complete Benchmark Matrix Specification

### Phase 1: Quick Tests (100k, ~5 minutes total)

**Goal:** Verify test infrastructure, detect obvious regressions

**Datasets:** 2 (100k each)
**Query Families:** All 3
**Total Runs:** ~24

```
Phase 1 Commands:
  Generate 100k_balanced_70c_chrono
  Generate 100k_current_skew_50c_random
  Load both into test database
  Run Family 1 (Q1–Q7) on [none, brin, gist_period]
  Run Family 2 (Query A/B/D) on [gist_attr_period, temporal_rtree] with both force settings
  Run Family 3 (hybrid) on [btree, hybrid_current_history]
  Expected runtime: 5–10 minutes
```

### Phase 2: Main Comparison (1M, ~30–60 minutes)

**Goal:** Primary performance comparison, cost model evaluation

**Datasets:** 5 (1M each)
**Query Families:** All 3
**Total Runs:** ~100–150

```
Phase 2 Matrix:
  Datasets: balanced_70c_chrono, current_skew_50c_random, 
            history_skew_20c_reverse, long_tailed_70c_random, 
            hot_attr_zipf_50c_random

  Results per dataset:
    Family 1 (Q1–Q7):    7 queries × 3 indexes = 21 runs
    Family 2 (Query A/B/D): 3 queries × 2 indexes × 2 force settings = 12 runs
    Family 3 (hybrid):   3 variants × 2 strategies = 6 runs
  
  Per dataset: 39 runs
  Total: 39 × 5 datasets = 195 runs (~30–60 minutes)
```

### Phase 3: Scaling Study (5M, ~60–90 minutes)

**Goal:** Cost model scaling validation, memory effects

**Datasets:** 3 (5M each)
**Query Families:** All 3
**Total Runs:** ~60

```
Phase 3 Matrix:
  Datasets: balanced_70c_random, current_skew_50c_random, 
            history_skew_20c_random

  Per dataset: 39 runs (same as Phase 2)
  Total: 39 × 3 datasets = 117 runs (~60–90 minutes)
```

---

## Result Organization

### Directory Structure

```
results/
├── phase_1_100k/
│   ├── q1_q7_results.csv                 (7 queries × 3 indexes × 2 datasets)
│   ├── query_a_b_d_results.csv           (3 queries × 2 indexes × 2 force × 2 datasets)
│   ├── query_d_hybrid_results.csv        (3 variants × 2 strategies × 2 datasets)
│   └── summary_phase1.txt
│
├── phase_2_1m/
│   ├── q1_q7_results.csv                 (7 queries × 3 indexes × 5 datasets = 105 rows)
│   ├── query_a_b_d_results.csv           (3 queries × 2 indexes × 2 force × 5 datasets = 60 rows)
│   ├── query_d_hybrid_results.csv        (3 variants × 2 strategies × 5 datasets = 30 rows)
│   └── summary_phase2.txt
│
├── phase_3_5m/
│   ├── q1_q7_results.csv                 (7 queries × 3 indexes × 3 datasets = 63 rows)
│   ├── query_a_b_d_results.csv           (3 queries × 2 indexes × 2 force × 3 datasets = 36 rows)
│   ├── query_d_hybrid_results.csv        (3 variants × 2 strategies × 3 datasets = 18 rows)
│   └── summary_phase3.txt
│
└── comparative_analysis.md               (Cross-phase insights)
```

### Result File Format

**CSV Format (uniform across all families):**
```
Dataset,Dataset_Size,Query_ID,Index_Type,Force_RTreePaths,Rows_Returned,Wall_Time_us,Buffers_Hit,Buffers_Read,Plan_Nodes,Notes
temporal_1m_balanced_70c,1000000,Q1,none,N/A,250000,1542,4200,0,Seq Scan,Baseline
temporal_1m_balanced_70c,1000000,Q1,brin,N/A,250000,156,800,15,Bitmap Index Scan,Good performance
temporal_1m_balanced_70c,1000000,Q1,gist_period,N/A,250000,89,600,2,Index Scan,Best
```

Columns:
- Dataset: Name (e.g., temporal_1m_balanced_70c)
- Dataset_Size: Row count
- Query_ID: Q1, Q2, ..., Query A, Query B, etc.
- Index_Type: none, brin, gist_period, gist_attr_period, temporal_rtree
- Force_RTreePaths: N/A, off, on (relevant for Family 2 only)
- Rows_Returned: Result count
- Wall_Time_us: Total execution time (microseconds)
- Buffers_Hit/Read: Cache statistics
- Plan_Nodes: Query plan node type(s)
- Notes: Observations, anomalies

---

## Fair Comparison Validation Checklist

Before accepting C2 TODO two results:

- [ ] **Family 1 (Q1–Q7):** Only compared [none, brin, gist_period]; temporal_rtree excluded
- [ ] **Family 2 (Query A/B/D):** Only compared [gist_attr_period, temporal_rtree]; plain indexes excluded
- [ ] **Family 3 (Hybrid):** Only compared [btree, hybrid]; single-table temporal_rtree excluded
- [ ] **CSV columns:** Consistent across all result files (Dataset, Size, Query_ID, Index_Type, ...)
- [ ] **Reproducibility:** All datasets generated with seed=42
- [ ] **Documentation:** Each result file includes dataset and index descriptions
- [ ] **Exclusion Notes:** Comments explain why certain indexes weren't tested
- [ ] **Cross-validation:** Repeated runs (N≥2) show <5% variance for stability

---

## Commands to Execute Phase Matrix

### Phase 1 (100k)
```bash
# Generate datasets
python temporal_generator.py --size 100000 --ratio-open-ended 0.7 \
  --interval-mode long_tailed --attr-mode zipf --order-mode chrono \
  --output temporal_100k_balanced_70c_chrono.sql

python temporal_generator.py --size 100000 --ratio-open-ended 0.5 \
  --interval-mode medium --attr-mode uniform --order-mode random \
  --output temporal_100k_current_skew_50c_random.sql

# Load and run (see bash script in benchmark_campaigns/PHASE_1_baseline.sh)
```

### Phase 2 (1M)
```bash
# Generated 5 datasets with script:
bash benchmark_campaigns/PHASE_2_main.sh --size 1000000

# Runs automatically generate Phase 2 results (see PHASE_2_baseline.sh)
```

### Phase 3 (5M)
```bash
# Generate 3 datasets at 5M scale:
bash benchmark_campaigns/PHASE_3_extended.sh --size 5000000

# Runs automatically (30–90 minutes)
```

---

## Expected C2 TODO Two Output

Upon completion, deliver:
1. **Generated SQL files:** All datasets from all phases (timestamped, reproducible)
2. **Result CSVs:** Three per phase (q1_q7, query_a_b_d, query_d_hybrid), 6 files total
3. **Summary reports:** Comparative analysis and insights
4. **Workload definitions:** Finalized SQL files (included in this repo)
5. **Fair comparison documentation:** COMPARISON_RULES.md (above)
