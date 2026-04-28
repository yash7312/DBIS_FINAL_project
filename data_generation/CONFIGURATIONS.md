# Configuration Reference for Temporal Data Generator

## Overview

Each configuration preset tests a specific aspect of index AM performance on temporal data.

---

## Configuration Matrix

| Config | Open-Ended % | Width | Attrs | Order | Hot-Current | Purpose |
|--------|-------------|-------|-------|-------|-------------|---------|
| **history_skew** | 30% | short | uniform | chrono | none | History-heavy: test AM on finite intervals with good physical order |
| **current_skew** | 80% | short | uniform | mixed | none | Current-heavy: test AM on open-ended rows with random order |
| **balanced** | 50% | medium | uniform | chrono | none | Realistic: balanced mix of current/history |
| **long_tailed** | 30% | long-tail | uniform | mixed | none | Interval width diversity: test split quality under heterogeneous widths |
| **zipf_uniform** | 50% | medium | zipf | chrono | none | Attribute skew: power-law attrs, chronological order |
| **zipf_hotcurrent** | 70% | medium | zipf | mixed | 15% | Real-world: skewed attrs, concentrated current rows, random order |

---

## Detailed Descriptions

### 1. **history_skew**
- **Open-ended ratio:** 30% (mostly history)
- **Interval width:** Short (1–24 hours)
- **Attribute mode:** Uniform [1, 100]
- **Insertion order:** Chronological (best physical locality)
- **Hot-current:** None

**What it tests:**
- Index effectiveness on finite-interval history queries
- Sequential scan efficiency (good physical order favors BRIN+scan)
- Whether R-tree split quality matters for tight temporal windows
- GiST baseline performance on history-heavy workloads

**Expected winner:** BRIN (physical order), GiST (tight intervals)

---

### 2. **current_skew**
- **Open-ended ratio:** 80% (mostly current/active)
- **Interval width:** Short (1–24 hours; irrelevant for open-ended)
- **Attribute mode:** Uniform [1, 100]
- **Insertion order:** Mixed/random (disrupted locality)
- **Hot-current:** None

**What it tests:**
- Index effectiveness on current/active-only queries
- How well AM handles high fraction of unbounded rows
- Random insertion order (worst for BRIN)
- Whether temporal-aware split strategy helps (vs. time-unaware GiST)

**Expected winner:** Temporal R-tree (optimized for current separation)

---

### 3. **balanced**
- **Open-ended ratio:** 50% (realistic split)
- **Interval width:** Medium (1 day–1 year)
- **Attribute mode:** Uniform [1, 100]
- **Insertion order:** Chronological
- **Hot-current:** None

**What it tests:**
- General-purpose real-world workload
- AM behavior on mixed current/history data
- Medium interval widths (realistic business data)
- Baseline for comparison

**Expected winner:** Varies by query mix

---

### 4. **long_tailed**
- **Open-ended ratio:** 30%
- **Interval width:** Pareto-like (70% short, 15% medium, 15% very long)
- **Attribute mode:** Uniform [1, 100]
- **Insertion order:** Mixed/random
- **Hot-current:** None

**What it tests:**
- Index split quality under heterogeneous interval widths
- GiST "range class separation" heuristic effectiveness
- How R-tree handles mixed current/history with diverse widths
- Stress test for split algorithms

**Expected winner:** GiST (range-aware split), Temporal R-tree (class separation)

---

### 5. **zipf_uniform**
- **Open-ended ratio:** 50%
- **Interval width:** Medium (moderate intervals)
- **Attribute mode:** Zipf/power-law (skewed to small attr values)
- **Insertion order:** Chronological
- **Hot-current:** None

**What it tests:**
- AM behavior under skewed attribute distribution
- Whether AM exploits clustering of high-frequency attributes
- Physics-order dependency (chronological order helps skewed queries)
- Query selectivity under realistic 80/20 rule

**Expected winner:** BRIN (good order + concentrated queries), Temporal R-tree

---

### 6. **zipf_hotcurrent**
- **Open-ended ratio:** 70%
- **Interval width:** Medium
- **Attribute mode:** Zipf (power-law, with hot-current concentration)
- **Insertion order:** Mixed/random
- **Hot-current fraction:** 15% (current rows concentrated in attrs 1–10)

**What it tests:**
- Real-world scenario: active/current rows concentrated on "hot" attributes (e.g., popular tenants, hot data)
- AM effectiveness under realistic skew + current row concentration
- Random insertion order (worst-case for BRIN)
- Whether temporal R-tree hybrid strategy pays off

**Expected winner:** Temporal R-tree (combines current separation + attr skew awareness)

---

## Dataset Sizes

All configurations are generated at 4 scales:

| Size | Rows | Approx. Table Size | Purpose |
|------|------|-------------------|---------|
| **100k** | 100,000 | ~10 MB | Quick development/testing |
| **1M** | 1,000,000 | ~100 MB | Standard benchmark |
| **5M** | 5,000,000 | ~500 MB | Large-scale (disk-bound testing) |
| **10M** | 10,000,000 | ~1 GB | Stress test |

---

## Typical Benchmark Matrix

```
For each (size, config) pair:

Sizes:      [100k, 1M, 5M, 10M]
Configs:    [history_skew, current_skew, balanced, long_tailed, zipf_uniform, zipf_hotcurrent]
↓
24 datasets total
↓
For each dataset, measure:
  - Seq scan (baseline)
  - GiST index
  - BRIN index (if applicable)
  - Temporal R-tree (new AM)
↓
Report: Time, I/O, selectivity, cache efficiency
```

---

## Recommended Query Distribution by Config

### history_skew
- Q1a, Q1b, Q1c (history range queries)
- 80% of workload on finite intervals
- 20% on current rows for completeness

### current_skew
- Q2a, Q2b, Q2c, Q2d (current/active row queries)
- 80% of workload on open-ended rows
- 20% on history for baseline

### balanced
- Q1, Q2, Q3 (mixed)
- 40–50% history, 40–50% current

### long_tailed
- Q1c, Q3c (range containment, heterogeneous widths)
- Emphasize interval diversity

### zipf_uniform
- Q4a, Q4b, Q4c, Q4d (hot/warm/cold attributes)
- Aggregate queries (Q5c)
- Measure selectivity variance

### zipf_hotcurrent
- Q4a (hot attrs + current)
- Q2c (current rows with Zipf distribution)
- Q3d (complex predicate under skew)

---

## Reproducibility Notes

- **Seed:** Fixed at 42 by default (override with `--seed` for variations)
- **Timestamps:** All within 2023 (arbitrary but fixed)
- **Attributes:** Always [1, 100] (scaled from config parameters)
- **Insertion order:** Is part of the dataset SQL file (immutable once generated)
- **Ratios:** Float down to exact row counts (deterministic given seed)

---

## Example: Generating Custom Configurations

To create a custom configuration not in the presets, modify `temporal_generator.py`:

```python
# In main() configs dict:
'my_custom_config': {
    'ratio_open_ended': 0.40,      # 40% open-ended
    'interval_mode': 'long_tailed',
    'attr_mode': 'zipf',
    'order_mode': 'reverse',
    'hot_current_frac': 0.20,      # 20% of current rows concentrated
},
```

Then generate:
```bash
python3 temporal_generator.py --size 1000000 --config my_custom_config \
    --output temporal_data_1m_custom.sql
```

---

## Interpreting Results

### BRIN Wins When
- Dataset is chronologically ordered
- Attribute distribution is uniform
- Scans are large (sequential efficiency dominates)

### GiST Wins When
- Interval widths are diverse (split quality matters)
- Attribute distribution is moderate
- Mixed current/history workload

### Temporal R-tree Wins When
- High percentage of open-ended current rows
- Attribute skew (Zipf) with hot-current concentration
- Mixed workload requiring both current and history separation
