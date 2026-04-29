# Fair Comparison Guidelines for Temporal Index Benchmarking

## Core Principle

**Do not compare queries with indexes that cannot support them.**

This document establishes rules to ensure apples-to-apples comparisons in temporal index benchmarking.

## Query Family Definitions

### Family 1: Plain Temporal (Q1–Q7)
**What:** Pure tsrange predicates without attribute filtering
```sql
WHERE valid_period @> timestamp '2023-06-01'
WHERE valid_period && tsrange(...)
WHERE valid_period <@ tsrange(...)
```

**Supported Index Types:**
- None (seq scan baseline)
- BRIN (lossy range index)
- GiST with opclass for tsrange (direct range indexing; note: NOT gist_attr_period)
- Any direct-range AM path that doesn't require expression evaluation

**NOT Supported:**
- ❌ temporal_rtree (requires temporalbox expression; can't use raw tsrange)
- ❌ Expression-based indexes (GiST on temporalbox, etc.)

**Why Temporal_rtree is excluded:** 
The `temporal_rtree` custom AM is designed for 4D queries on temporalbox expressions. Using it on raw tsrange queries requires:
1. Automatic conversion of WHERE `valid_period @> ts` → WHERE `temporalbox(attr, valid_period) @> ???`
2. But there's no corresponding cube value for the RHS; the query becomes incomparable

**Correct comparison:** Q1–Q7 against [none, brin, gist_period only]

---

### Family 2: Attribute×Time Expression (Query A/B/D)
**What:** 4D queries on composite temporalbox expressions
```sql
WHERE temporalbox(attr, valid_period) @> temporalbox_point(...)
WHERE temporalbox(attr, valid_period) && temporalbox_range(...)
WHERE upper_inf(valid_period) AND attr = 10 AND lower(...) <= ...  -- Special case: query D
```

**Supported Index Types:**
- GiST with operator class for temporalbox (expression-based indexing)
- temporal_rtree (native 4D custom AM)

**NOT Supported:**
- ❌ Plain temporal indexes (brin, gist_period) — can't index expressions
- ❌ B-tree on single columns (can't index composite 4D boxes)
- ❌ Seq scan (unfair baseline; intentionally slow)

**Special case: Query D**
Query D can be executed both ways:
1. **Expression-based:** `temporalbox(...) @> temporalbox_point(...)` — GiST or temporal_rtree
2. **Native range:** `upper_inf(...) AND attr = X AND lower(...) <= ...` — B-tree or regular filters

For Family 2 comparisons, use expression form (temporalbox).
For Family 3 (hybrid decomposition), use native form.

**Correct comparison:** Query A/B/D against [gist_attr_period, temporal_rtree only]

---

### Family 3: Hybrid Current/History Decomposition
**What:** Decomposed queries separating current rows from history
```sql
SELECT ... FROM temporal_data WHERE upper_inf(...) AND attr=X AND lower(...)<= ...  -- Current side
UNION ALL
SELECT ... FROM temporal_data WHERE NOT upper_inf(...) AND temporalbox(...) @> ...   -- History side
```

**Supported Index Strategies:**
- B-tree on (attr, lower_timestamp) for current-side filtering
- hybrid_current_history (dedicated table separation with optimized current lookup)
- History-side expression index (GiST or temporal_rtree) for closed intervals

**NOT Supported:**
- ❌ Array temporal_rtree on entire temporal_data (not the intended use case)
- ❌ BRIN or other range-only indexes (can't decompose current/history efficiently)

**Why Separate:** 
The hybrid decomposition represents a specific storage and indexing strategy that optimizes for current-state queries. Comparing it against single-table strategies on the same data is unfair because:
- Hybrid benefits from table partitioning/clustering by row state
- Single-table temporal_rtree hasn't had any such optimization

**Correct comparison:** Query D (hybrid form) against [btree, hybrid_current_history, dedicated current/history indexes only]

---

## Comparison Rules Checklist

### Rule 1: Respect Query-Index Affinity
- ✓ Use Q1–Q7 only with: none, brin, gist_period
- ✓ Use Query A/B/D (expression form) only with: gist_attr_period, temporal_rtree
- ✓ Use Query D (hybrid form) with: btree, hybrid_current_history
- ✗ Never mix families (e.g., don't run Q1–Q7 on temporal_rtree to "test it")

### Rule 2: Separate Result Tables by Family
- Keep Q1–Q7 results in their own table
- Keep Query A/B/D results separate
- Keep Query D hybrid results separate
- Do NOT merge into one "unified comparison" table

### Rule 3: Fair Baselines
- Seq scan baseline only used within its family (e.g., Q1–Q7: none vs. brin)
- Do NOT compare seq scan on different queries as a measure of query cost
- Measure per-query selectivity and cost, not cross-query performance

### Rule 4: Document Exclusions
Every benchmark result should note:
- Which queries were compared
- Which indexes were tested
- Why other indexes were excluded
- Example: "Q1–Q7 on 1M balanced dataset: none, brin, gist_period; temporal_rtree excluded (expression-only AM)"

### Rule 5: Optional Extended Comparisons
For research purposes, you may create marked comparisons that break the above rules, but clearly label them:
- "CROSS-FAMILY EXPERIMENT: Q1–Q7 on temporal_rtree with implicit temporalbox conversion"
- Document the conversion procedure
- Mark results as "not comparable" in comparisons with native queries

---

## Result Table Templates

### Template 1: Q1–Q7 Plain Temporal

```
Query Family: Plain Temporal (Q1–Q7)
Dataset: temporal_1m_balanced_70c_random
Indexes Tested: none, brin, gist_period
Note: Temporal_rtree excluded (operates only on temporalbox expressions, not raw tsrange)

| Query | Rows | none_wall_us | none_buffers | brin_wall_us | brin_buffers | gist_period_wall_us | gist_period_buffers | Winner |
|-------|------|-------------|--------------|-------------|--------------|---------------------|---------------------|--------|
| Q1    | 250K | 1,542       | 4,200        | 156         | 800          | 89                  | 600                 | gist   |
| Q2    | 12K  | 1,401       | 4,200        | 142         | 800          | 78                  | 600                 | gist   |
| ...   |      |             |              |             |              |                     |                     |        |
```

### Template 2: Query A/B/D Attribute×Time

```
Query Family: Attribute×Time Expression (Query A/B/D)
Dataset: temporal_1m_balanced_70c_random
Indexes Tested: gist_attr_period, temporal_rtree
Note: Not compared with [none, brin, gist_period] (can't index expressions)

| Query | Rows | gist_attr_period (force_rtree=off) | gist_attr_period (force_rtree=on) | temporal_rtree_wall_us | temporal_rtree_buffers | Winner (off) | Winner (on) |
|-------|------|----------------------------------|------------------------------------|------------------------|------------------------|---------|---------|
| A     | 1.2K | 45                               | 43                                | 23                    | 180                    | rtree   | rtree   |
| B     | 45K  | 156                              | 149                               | 78                    | 600                    | rtree   | rtree   |
| D     | 720  | 12                               | 11                                | 8                     | 120                    | rtree   | rtree   |
```

### Template 3: Query D Hybrid Decomposition

```
Query Family: Hybrid Current/History Decomposition
Dataset: temporal_1m_balanced_70c_random
Indexes Tested: btree, hybrid_current_history, temporal_rtree (history-side only)
Note: Not compared with single-table temporal_rtree (different strategy)

| Query Variant | Rows | btree_wall_us | hybrid_union_wall_us | history_gist_wall_us | Winner |
|---------------|------|----------------|----------------------|----------------------|--------|
| Query D (native) | 720     | 18             | -                    | -                    | btree  |
| Hybrid Union   | 750     | -              | 22                   | 28                   | hybrid |
| Hybrid Range   | 1.2K    | -              | 34                   | 42                   | hybrid |
```

---

## Statistical Significance and Reporting

### Margin of Error
- Report measurements in microseconds, not milliseconds (for precision)
- Run each query 3–5 times, report median and stddev
- Queries with <1% difference are "statistically equivalent"

### Reporting Format
```
Query A on temporal_1m_balanced_70c:
  gist_attr_period: 45.2 ± 1.8 μs (3 runs)
  temporal_rtree:   23.1 ± 0.9 μs (3 runs)
  Improvement: 48.8% faster (significant)
```

### Caveats to Document
- System load during test (if noisy)
- Cache behavior (cold start vs. warm)
- Whether results were from installcheck (isolated) or production database
- Any concurrent activity

---

## Example: A Correct Benchmark Report

**Title:** Comparative Performance of Temporal Indexes on 1M-row Balanced Dataset

**Data:** 1M rows, balanced distribution, 70% current (open-ended), random insertion order

**Query Families Tested:**
1. Q1–Q7 (plain temporal): Seq scan vs. BRIN vs. GiST(tsrange)
   - Temporal_rtree **excluded** (expression-only AM, not comparable)
2. Query A/B/D (attr×time): GiST(temporalbox) vs. temporal_rtree
   - Seq scan, BRIN **excluded** (can't index expressions)
3. Query D (hybrid): B-tree vs. hybrid_current_history
   - Single-table temporal_rtree **excluded** (separate strategy)

**Results:**
[Three separate result tables for each family]

**Summary:**
- Q1–Q7: GiST(tsrange) performs best for all queries
- Query A/B/D: temporal_rtree achieves 2x speedup over GiST(temporalbox) on majority of queries
- Query D: Hybrid decomposition competitive with native B-tree

**Conclusions:**
✓ temporal_rtree is NOT competitive for plain temporal queries (different design goal)
✓ temporal_rtree shows promise for 4D attr×time queries (1.5–2x better than GiST)
✓ Hybrid decomposition is viable for current-heavy workloads

---

## References

- Temporal table design: ISO/IEC 19075-2 (Temporal Tables)
- Temporal query semantics: [User] specifications
- Fair benchmarking: TPC-H, academic database benchmarking guidelines
