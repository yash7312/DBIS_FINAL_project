# Results Recording Templates

Use these CSV templates to record benchmark results. Separate files for each query family to maintain fair comparison boundaries.

## q1_q7_plain_temporal_results.csv

Temporal range queries (Q1–Q7) compared across indexes that support pure tsrange predicates.

```
Dataset,Dataset_Size,Query,Index_Type,Rows_Returned,Execution_Time_us,Buffer_Hits,Buffer_Reads,ANALYZE_Time_us,Planning_Time_us,Notes
temporal_1m_balanced_70c,1000000,Q1,none,250000,1542,4200,0,1450,92,Seq scan baseline
temporal_1m_balanced_70c,1000000,Q1,brin,250000,156,800,15,140,5,BRIN lossy pages
temporal_1m_balanced_70c,1000000,Q1,gist_period,250000,89,600,2,78,8,Direct GiST on tsrange
temporal_1m_balanced_70c,1000000,Q2,none,12000,1401,4200,0,1380,92,Future point
temporal_1m_balanced_70c,1000000,Q2,brin,12000,142,800,1,130,5,BRIN scan
temporal_1m_balanced_70c,1000000,Q2,gist_period,12000,78,600,0,72,8,GiST index active
...
```

**Columns:**
- Dataset: Name of generated dataset (e.g., temporal_1m_balanced_70c)
- Dataset_Size: Total rows in dataset
- Query: Q1, Q2, ..., Q7
- Index_Type: none, brin, or gist_period
- Rows_Returned: Query result count
- Execution_Time_us: Wall-clock time in microseconds (from EXPLAIN ANALYZE)
- Buffer_Hits: Number of buffer hits (from Buffers)
- Buffer_Reads: Number of buffer reads
- ANALYZE_Time_us: Execution time from EXPLAIN output
- Planning_Time_us: Planning time from EXPLAIN output
- Notes: Any observations (e.g., "cold cache", "full table scan")

---

## query_a_b_d_attr_time_results.csv

Attribute×time queries (Query A/B/D) compared across GiST expression index and temporal_rtree.

```
Dataset,Dataset_Size,Query,Index_Type,Force_RtreePaths,Rows_Returned,Execution_Time_us,Buffer_Hits,Buffer_Reads,Plan_Type,Notes
temporal_1m_balanced_70c,1000000,A,gist_attr_period,FALSE,1200,45,600,8,Index Scan,Natural planner choice
temporal_1m_balanced_70c,1000000,A,gist_attr_period,TRUE,1200,43,600,8,Index Scan,With force_rtree_paths
temporal_1m_balanced_70c,1000000,A,temporal_rtree,FALSE,1200,23,180,2,Index Scan,Natural planner (good cost)
temporal_1m_balanced_70c,1000000,A,temporal_rtree,TRUE,1200,23,180,2,Index Scan,Forced path (same result)
temporal_1m_balanced_70c,1000000,B,gist_attr_period,FALSE,45000,156,1200,25,Index Scan,Multi-row result
temporal_1m_balanced_70c,1000000,B,gist_attr_period,TRUE,45000,149,1200,25,Index Scan,Slightly better with forcing
temporal_1m_balanced_70c,1000000,B,temporal_rtree,FALSE,45000,78,600,12,Index Scan,Significant speedup
temporal_1m_balanced_70c,1000000,B,temporal_rtree,TRUE,45000,75,600,12,Index Scan,Minimal change (already chosen)
...
```

**Columns:**
- Dataset: Dataset name
- Dataset_Size: Total rows
- Query: A, B, or D
- Index_Type: gist_attr_period or temporal_rtree
- Force_RtreePaths: FALSE (natural) or TRUE (with force_rtree_paths GUC)
- Rows_Returned: Query result count
- Execution_Time_us: Wall-clock time in microseconds
- Buffer_Hits: Buffer hit count
- Buffer_Reads: Buffer read count
- Plan_Type: "Index Scan", "Seq Scan", etc. (from EXPLAIN)
- Notes: "Natural planner choice", "Biased path", "Slow baseline", etc.

---

## query_d_hybrid_decomposition_results.csv

Hybrid decomposition query (D native and UNION ALL variants) compared across btree and hybrid strategies.

```
Dataset,Dataset_Size,Query_Variant,Index_Strategy,Rows_Returned,Execution_Time_us,Buffer_Hits,Buffer_Reads,Plan_Components,Notes
temporal_1m_balanced_70c,1000000,Query D (native),btree,720,18,300,1,Index Scan (current-only),Fast single-target lookup
temporal_1m_balanced_70c,1000000,Query D (hybrid),hybrid_current_history,900,22,350,2,Btree + GiST union,Current + history split
temporal_1m_balanced_70c,1000000,Query D (hybrid),temporal_rtree_history,900,28,450,4,Hybrid with rtree history,Experimental: temporal_rtree for history
temporal_1m_balanced_70c,1000000,Query D (hybrid range),hybrid_current_history,1200,34,500,5,Btree + GiST union,Range version more selective
...
```

**Columns:**
- Dataset: Dataset name
- Dataset_Size: Total rows
- Query_Variant: "Query D (native)", "Query D (hybrid)", "Query D (hybrid range)"
- Index_Strategy: "btree", "hybrid_current_history", "temporal_rtree_history", etc.
- Rows_Returned: Total rows from query
- Execution_Time_us: Wall-clock time
- Buffer_Hits: Buffer hit count
- Buffer_Reads: Buffer read count
- Plan_Components: Description of plan nodes (e.g., "Btree Scan + GiST Scan")
- Notes: Strategy-specific notes

---

## summary_comparative_results.txt

A human-readable summary across all three families.

```
BENCHMARK CAMPAIGN: Temporal Index Comparison
Dataset: temporal_1m_balanced_70c (1million rows, balanced distribution, 70% current)
Date: 2026-04-29
Environment: PostgreSQL 14, temporal_rtree extension (C2 TODO one complete)

=== FAMILY 1: PLAIN TEMPORAL (Q1–Q7) ===
Indexes Tested: none (seq scan), brin, GiST(tsrange)
Note: temporal_rtree EXCLUDED (operates only on temporalbox expressions)

Results:
  Q1 (point containment):    GiST wins by 20% over BRIN
  Q2 (future point):         GiST wins by 26% over BRIN
  Q3 (short range):          GiST wins by 18% over BRIN
  Q4 (medium range):         GiST wins by 22% over BRIN
  Q5 (long range):           GiST wins (all scans are seq-like)
  Q6 (range containment):    GiST wins by 15% over BRIN
  Q7 (contained-by):         GiST wins by 19% over BRIN

Winner: GiST(tsrange) – consistent advantage across all queries

=== FAMILY 2: ATTR×TIME EXPRESSION (Query A/B/D) ===
Indexes Tested: GiST(temporalbox), temporal_rtree
Note: Not compared with [none, brin, gist_period] (can't index expressions)

Results (force_rtree_paths = FALSE):
  Query A (point lookup):   temporal_rtree 49% faster
  Query B (range lookup):   temporal_rtree 50% faster
  Query D (current filter): temporal_rtree 33% faster

Results (force_rtree_paths = TRUE):
  Query A:                  No change (naturally chosen)
  Query B:                  No change (naturally chosen)
  Query D:                  No change (path already selected)

Winner: temporal_rtree – 1.5–2x speedup, even without path forcing

=== FAMILY 3: HYBRID CURRENT/HISTORY (Query D variants) ===
Indexes Tested: B-tree(attr,lower), hybrid_current_history, experimental temporal_rtree(history)
Note: Not compared with single-table temporal_rtree (different strategy)

Results:
  Query D (native):         B-tree wins (fastest single-table approach)
  Query D (hybrid union):   hybrid_current_history 22% slower (requires 2 index scans)
  Query D (hybrid range):   hybrid_current_history 89% slower (full GiST history scan)

Winner: B-tree for current-state queries, but hybrid remains viable for current-heavy workloads

=== CROSS-FAMILY OBSERVATIONS ===
1. Query family selection matters: Different indexes excel at different query patterns
2. temporal_rtree shines on 4D attr×time predicates (Family 2)
3. Plain temporal queries still better served by GiST(tsrange) (Family 1)
4. Hybrid decomposition is viable but not always faster than single-table approaches (Family 3)

=== Recommendations for Further Work ===
- Investigate why Query D sees 33% improvement: Cost model differences?
- Test temporal_rtree on 5M dataset for cost model scaling
- Benchmark with force_rtree_paths enabled earlier in planning (currently mid-planner)
- Extend comparison to 10M dataset for memory saturation effects
```

---

## How to Use These Templates

1. **During benchmark run:** Record EXPLAIN ANALYZE output to q1_q7.txt, query_a_b_d.txt, etc.
2. **Parse results:** Extract execution times, buffer statistics
3. **Fill CSV:** Use scripts or manual entry to populate result files
4. **Summarize:** Create summary_*.txt for qualitative observations
5. **Archive:** Save all result files with timestamp (e.g., results_20260429_session1/)

### Script Helper (Optional)

Create a shell script to automate parsing EXPLAIN output:

```bash
#!/bin/bash
# Parse EXPLAIN ANALYZE output and extract key metrics

DATABASE=$1
QUERY_FILE=$2
INDEX_NAME=$3
OUTPUT_CSV=$4

psql -d $DATABASE -c "CREATE INDEX $INDEX_NAME ..." 2>&1 | tee -a $OUTPUT_CSV

psql -d $DATABASE <<SQL | grep "Execution Time" >> $OUTPUT_CSV
\pset format csv
EXPLAIN (ANALYZE, BUFFERS) $(cat $QUERY_FILE);
SQL
```

---

## Comparison Workflow

```bash
# 1. Generate dataset
python temporal_generator.py --size 1000000 --output temporal_1m_balanced_70c.sql

# 2. Load dataset
psql -d temporal_bench -f temporal_1m_balanced_70c.sql

# 3. Create indexes (one at a time)
psql -d temporal_bench <<'SQL'
CREATE INDEX idx_none ON temporal_data (id);  -- Dummy
DROP INDEX IF EXISTS idx_none;
SQL

# 4. Create BRIN index
psql -d temporal_bench <<'SQL'
CREATE INDEX idx_brin ON temporal_data USING BRIN (valid_period);
SQL

# 5. Run Q1–Q7 and record to CSV
for q in q1 q2 q3 q4 q5 q6 q7; do
  psql -d temporal_bench -f workloads/q1_q7_plain_temporal.sql >> results.txt
done

# 6. Repeat for other indexes and families
```
