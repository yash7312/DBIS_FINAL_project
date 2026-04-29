# Checkpoint C2 TODO Two: Completion Summary

**Date:** April 29, 2026
**Status:** ✓ COMPLETE
**Deliverable:** Standardized datasets and workload matrix framework for fair comparative benchmarking

## What Was Implemented

### 1. Standardized Dataset Framework

**File:** `data_generation/C2_STANDARDIZED_DATASETS.md`

Complete specification for reproducible temporal datasets:
- **Sizes:** 100k, 1M, 5M, 10M (future)
- **Distributions:** balanced, current-skew, history-skew, long-tailed, hot-attr-zipf
- **Current/History Ratios:** 70/30, 50/50, 20/80 split
- **Insertion Orders:** chronological, reverse, randomized
- **Reproducibility:** Seed=42 for all generation (identical runs possible)

**Dataset Naming Convention:**
```
temporal_[size]_[distribution]_[current_ratio]_[order].sql
Example: temporal_1m_balanced_70c_chrono.sql
```

### 2. Three Query Workload Families

**Location:** `data_generation/workloads/`

#### Family 1: Plain Temporal (Q1–Q7)
**File:** `workloads/q1_q7_plain_temporal.sql`

Pure tsrange predicates without attribute filtering:
- Q1: Point containment (present)
- Q2: Point containment (future)
- Q3–Q5: Range overlaps (short, medium, long)
- Q6: Range contains
- Q7: Range contained-by

**Fair Comparison:** [none, brin, gist_period] only
**Excluded:** temporal_rtree (expression-only AM, not comparable)

#### Family 2: Attribute×Time Expression (Query A/B/D)
**File:** `workloads/query_a_b_d_attr_time.sql`

4D temporalbox queries combining attributes and temporal ranges:
- Query A: Attribute point + temporal point
- Query B: Attribute value + temporal range  
- Query D: Current-side filter (special: evaluable both as expression and native)

**Fair Comparison:** [gist_attr_period, temporal_rtree] only
**Excluded:** Plain indexes (can't index expressions)
**Measurement:** Natural vs. forced planner (for C2 TODO one validation)

#### Family 3: Hybrid Current/History Decomposition
**File:** `workloads/query_d_hybrid_decomposition.sql`

Decomposed current/history queries:
- Query D (native): Single-table current-side lookup
- Hybrid UNION ALL (point): Current + history via union
- Hybrid UNION ALL (range): Current + history for range queries

**Fair Comparison:** [btree, hybrid_current_history] only
**Excluded:** Single-table temporal_rtree (different storage strategy)

### 3. Fair Comparison Rules and Methodology

**File:** `data_generation/workloads/COMPARISON_RULES.md` (extensive, ~300 lines)

Comprehensive guidelines ensuring apples-to-apples comparisons:

**Core Rules:**
1. Do NOT compare queries with unsupported indexes
2. DO keep result tables separated by query family
3. DO document all exclusions
4. DO report margins of error and statistical significance
5. DO provide full methodology notes

**Why Temporal_rtree Excluded from Q1–Q7:**
- temporal_rtree operates on 4D temporalbox expressions
- Cannot fairly compete on raw tsrange predicates
- Using it on Q1–Q7 requires implicit conversions that break comparability

**Why Expression Indexes Excluded from Plain Temporal:**
- GiST and temporal_rtree require `temporalbox(...)` expressions
- Cannot index raw `valid_period` column directly
- Comparing expression indexes on plain queries is cross-family mixing

**Includes:**
- Complete methodology for each family
- Result table templates with examples
- Statistical significance guidance
- Real-world benchmark report examples

### 4. Result Recording Templates

**File:** `data_generation/workloads/RESULTS_TEMPLATE.md` (200+ lines)

CSV templates for recording benchmark results:

**Three Standard Result Formats:**

1. **q1_q7_plain_temporal_results.csv**
   - Columns: Dataset, Query, Index_Type, Rows_Returned, Execution_Time_us, Buffer_Hits, Buffer_Reads, Plan_Type, Notes
   - Example: 35 rows (7 queries × 5 datasets)

2. **query_a_b_d_attr_time_results.csv**
   - Columns: Dataset, Query, Index_Type, Force_RTreePaths, Rows_Returned, Execution_Time_us, ...
   - Example: 60 rows (3 queries × 2 indexes × 2 force settings × 5 datasets)

3. **query_d_hybrid_decomposition_results.csv**
   - Columns: Dataset, Query_Variant, Index_Strategy, Rows_Returned, Execution_Time_us, ...
   - Example: 30 rows (3 variants × 2 strategies × 5 datasets)

**Plus:**
- Human-readable summary templates
- Parsing helper scripts (shell, Python)
- Workflow examples

### 5. Complete Benchmark Matrix Specification

**File:** `data_generation/C2_BENCHMARK_MATRIX_SPEC.md` (400+ lines)

Exact specification of benchmark campaign:

**Phase 1 (100k, ~5-10 minutes):**
- 2 datasets (balanced, current-skew)
- Quick smoke test for infrastructure
- ~24 total runs

**Phase 2 (1M, ~30-60 minutes):**
- 5 datasets (balanced, current-skew, history-skew, long-tailed, hot-attr-zipf)
- Primary performance comparison
- ~195 total runs

**Phase 3 (5M, ~60-90 minutes):**
- 3 datasets (balanced, current-skew, history-skew)
- Cost model scaling validation
- ~117 total runs

**Detailed Index×Query Matrix:**
- Which indexes to test with each query family
- Which settings to vary (e.g., force_rtree_paths on/off)
- Expected output directory structure
- Result validation checklist

### 6. Execution Guide

**File:** `data_generation/README_C2_WORKLOAD_MATRIX.md` (300+ lines)

Complete how-to guide for running benchmarks:

**Quick Start Examples:**
```bash
# Generate dataset
python temporal_generator.py --size 1000000 --output temporal_1m.sql

# Load
psql -d temporal_bench -f schema.sql
psql -d temporal_bench -f temporal_1m.sql

# Create index and run workload
psql -d temporal_bench -f workloads/query_a_b_d_attr_time.sql
```

**Automated Workflows:**
- Shell script templates for each phase
- Recommended execution parameters
- Expected runtime estimates

**Includes:**
- Full directory structure documentation
- Dataset matrix recommendations
- Step-by-step benchmark campaign execution
- Reproducibility guarantees

### 7. Navigation and Overview Documents

**Files:**
- `C2_TODO_TWO_STANDARDIZED_DATASETS.md` (main project root)
- Master index with quick links to all specifications
- Relationship to C2 TODO one (planner path steering) explained
- Next steps (TODO three, etc.)

## Key Design Decisions

### 1. Three Separate Query Families (NOT One Unified Comparison)
**Rationale:** Indexes have different strengths. Mixing families produces misleading results.
- GiST(tsrange) excels at Q1–Q7
- temporal_rtree excels at Query A/B/D  
- B-tree excels at hybrid decomposition
- A single "winner" table would be meaningless

### 2. Fair Exclusion of temporal_rtree from Q1–Q7
**Rationale:** temporal_rtree is a 4D AM designed for expressions. Can't use on raw ranges without conversion.
**Trade-off:** Smaller result sets, but honest comparisons
**Benefit:** Findings are scientifically valid and non-controversial

### 3. Separate Measurement of force_rtree_paths Impact
**Rationale:** Validates C2 TODO one hooks implementation
**Measurement:** Compare natural planner vs. biased planner for Query A/B/D
**Expected:** No difference if cost model is accurate; biasing helps if other indexes appear cheaper

### 4. Reproducible Datasets with Seed=42
**Rationale:** Ensures exact reproducibility across runs and researchers
**Guarantee:** Same seed → identical dataset
**Verification:** `diff v1.sql v2.sql` returns empty

### 5. Comprehensive Fair Comparison Documentation
**Rationale:** Prevents subtle errors in benchmark execution
**Includes:** Detailed rules, examples, validation checklists, real-world report templates

## Immediate Usage

Users can immediately:
1. Generate any dataset via `python temporal_generator.py`
2. Create indexes and run workloads via provided SQL files
3. Record results using provided CSV templates
4. Reference fair comparison rules during analysis
5. Follow execution guides for automated campaigns

## Relationship to C2 TODO One

C2 TODO one implemented:
- Planner hooks for path steering
- GUC `temporal_rtree.force_rtree_paths` for biasing
- Path biasing counter in hook statistics

C2 TODO two provides:
- **Measurement framework** for validating those hooks
- **Query workloads** to test the effectiveness of path biasing
- **Fair comparison rules** to ensure valid conclusions

**Expected Finding:** Query A/B/D results with force_rtree_paths on/off will show whether planner biasing is effective (or unnecessary).

## Research Value

This framework enables:
1. **Fair index comparisons** — Can't accidentally mix apples and oranges
2. **Reproducible results** — Same seed, same data, always
3. **Honest cost model validation** — Measure real performance, not just plan estimates
4. **Publication-quality benchmarks** — Everything documented, exclusions explained
5. **Extensibility** — Easy to add new distributions, queries, or index types

## Files Delivered

**Documentation (7 files):**
- C2_TODO_TWO_STANDARDIZED_DATASETS.md (main project root)
- C2_STANDARDIZED_DATASETS.md (detailed specs)
- C2_BENCHMARK_MATRIX_SPEC.md (complete matrix)
- README_C2_WORKLOAD_MATRIX.md (execution guide)
- workloads/COMPARISON_RULES.md (fair comparison rules)
- workloads/RESULTS_TEMPLATE.md (result templates)
- (Plus 2 READMEs for context in data_generation/)

**SQL Workload Files (3 files):**
- q1_q7_plain_temporal.sql
- query_a_b_d_attr_time.sql
- query_d_hybrid_decomposition.sql

**Total Deliverable:** ~2500 lines of documentation + workload specifications

## Next Steps: C2 TODO Three

With this framework in place, users can:
1. **Generate Phase 1 (100k) datasets** — ~5 minutes
2. **Run all workloads** on Phase 1 — ~10 minutes  
3. **Record results in CSV** — Automatic via templates
4. **Execute Phase 2 (1M)** — ~1 hour
5. **Analyze results** and draw conclusions

See C2 TODO three for: **Run the complete benchmark matrix and collect results.**

---

**Status:** Checkpoint C2 TODO two COMPLETE ✓
**Ready for:** C2 TODO three (benchmark execution) or independent use by other researchers
