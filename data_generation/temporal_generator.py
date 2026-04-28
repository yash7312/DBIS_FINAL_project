#!/usr/bin/env python3
"""
Temporal Data Generator for R-tree Indexing Benchmarks

Generates configurable temporal datasets with:
- Finite vs open-ended ratios (70/30, 50/50, 20/80)
- Interval width distributions (short, medium, long-tailed)
- Insertion order patterns (chronological, reverse, mixed)
- Attribute skew (uniform, Zipf-like)
- Hot-current fraction (concentrated attrs with many current rows)

Usage:
    python temporal_generator.py --size 100000 --config history_skew \
        --output temporal_data_100k_history.sql
"""

import argparse
import sys
from datetime import datetime, timedelta
import random
import math
from collections import defaultdict

class TemporalDataGenerator:
    def __init__(self, size, seed=42):
        self.size = size
        self.seed = seed
        random.seed(seed)
        
        # Base timestamp: 2023-01-01
        self.base_ts = datetime(2023, 1, 1)
        
    def generate_timestamp_pair(self, ratio_open_ended, interval_mode, position):
        """
        Generate a (lower, upper) timestamp pair.
        
        ratio_open_ended: float in (0, 1) — fraction of rows with NULL upper bound
        interval_mode: 'short' | 'medium' | 'long_tailed'
        position: index in sequence (for chronological/reverse ordering)
        """
        # Lower bound progresses through 10 years starting at base_ts
        days_total = 10 * 365
        lower_days = (position % days_total)
        lower_ts = self.base_ts + timedelta(days=lower_days)
        
        is_open_ended = random.random() < ratio_open_ended
        
        if is_open_ended:
            return (lower_ts, None)
        
        # Generate width based on mode
        if interval_mode == 'short':
            width_hours = random.randint(1, 24)
        elif interval_mode == 'medium':
            width_hours = random.randint(24, 365 * 24)
        elif interval_mode == 'long_tailed':
            # Pareto-like: most short, some very long
            u = random.random()
            if u < 0.7:
                width_hours = random.randint(1, 72)
            elif u < 0.95:
                width_hours = random.randint(72, 30 * 24)
            else:
                width_hours = random.randint(30 * 24, 5 * 365 * 24)
        else:
            width_hours = 24
        
        upper_ts = lower_ts + timedelta(hours=width_hours)
        return (lower_ts, upper_ts)
    
    def generate_attribute(self, attr_mode, position, hot_current_frac=0.1, is_current=False):
        """
        Generate an attribute value.
        
        attr_mode: 'uniform' | 'zipf'
        position: index in sequence
        hot_current_frac: fraction of attrs that get concentrated current rows
        is_current: whether this is an open-ended (current) row
        """
        if attr_mode == 'uniform':
            return random.randint(1, 100)
        
        elif attr_mode == 'zipf':
            # Zipf distribution: rank^(-1.5)
            # For current rows with hot-current fraction, concentrate attrs
            if is_current and random.random() < hot_current_frac:
                # Hot attrs: 1-10
                return random.choices(range(1, 11), weights=[1/i for i in range(1, 11)])[0]
            else:
                # Standard Zipf over 1-100
                rank = random.randint(1, 100)
                return int(rank ** (-1.5))
        
        return random.randint(1, 100)
    
    def generate_dataset(self, row_count, ratio_open_ended, interval_mode, 
                        attr_mode, order_mode, hot_current_frac=0.1):
        """
        Generate a full dataset with specified parameters.
        """
        rows = []
        
        for i in range(row_count):
            # Position for ordering
            if order_mode == 'chronological':
                pos = i
            elif order_mode == 'reverse':
                pos = row_count - 1 - i
            elif order_mode == 'mixed':
                pos = random.randint(0, row_count - 1)
            else:
                pos = i
            
            # Generate temporal bounds
            lower_ts, upper_ts = self.generate_timestamp_pair(
                ratio_open_ended, interval_mode, pos
            )
            is_current = (upper_ts is None)
            
            # Generate attribute
            attr = self.generate_attribute(attr_mode, pos, hot_current_frac, is_current)
            
            # Create row
            lower_str = lower_ts.isoformat()
            upper_str = upper_ts.isoformat() if upper_ts else None
            
            if upper_str:
                period_str = f"'[{lower_str},{upper_str})'::tsrange"
            else:
                period_str = f"'[{lower_str},)'::tsrange"
            
            payload = f"'payload_{i}'"
            
            rows.append({
                'id': i + 1,
                'attr': attr,
                'valid_period': period_str,
                'payload': payload,
            })
        
        return rows
    
    def generate_sql_insert(self, rows, table_name='temporal_data'):
        """
        Generate SQL INSERT statements.
        """
        sql_lines = []
        
        sql_lines.append(f"-- Generated temporal dataset: {len(rows)} rows")
        sql_lines.append(f"-- Timestamp: {datetime.now().isoformat()}\n")
        
        # Insert in batches
        batch_size = 1000
        for batch_start in range(0, len(rows), batch_size):
            batch_end = min(batch_start + batch_size, len(rows))
            batch = rows[batch_start:batch_end]
            
            insert_stmt = f"INSERT INTO {table_name} (id, attr, valid_period, payload) VALUES\n"
            value_parts = []
            
            for row in batch:
                value_str = f"  ({row['id']}, {row['attr']}, {row['valid_period']}, {row['payload']})"
                value_parts.append(value_str)
            
            insert_stmt += ",\n".join(value_parts) + ";\n"
            sql_lines.append(insert_stmt)
        
        return "\n".join(sql_lines)

def main():
    parser = argparse.ArgumentParser(
        description='Generate temporal datasets for R-tree benchmarking'
    )
    parser.add_argument('--size', type=int, default=100000,
                       help='Dataset size (number of rows); common: 100000, 1000000, 5000000, 10000000')
    parser.add_argument('--config', type=str, default='balanced',
                       choices=[
                           'history_skew',      # 70% finite, short intervals
                           'current_skew',      # 80% open-ended, short intervals
                           'balanced',          # 50% open-ended, medium intervals
                           'long_tailed',       # 30% open-ended, long-tailed widths
                           'zipf_uniform',      # Uniform attrs
                           'zipf_hotcurrent',   # Zipf with hot-current concentration
                       ],
                       help='Configuration preset')
    parser.add_argument('--output', type=str, required=True,
                       help='Output SQL file path')
    parser.add_argument('--seed', type=int, default=42,
                       help='Random seed for reproducibility')
    
    args = parser.parse_args()
    
    # Map config to parameters
    configs = {
        'history_skew': {
            'ratio_open_ended': 0.30,
            'interval_mode': 'short',
            'attr_mode': 'uniform',
            'order_mode': 'chronological',
            'hot_current_frac': 0.0,
        },
        'current_skew': {
            'ratio_open_ended': 0.80,
            'interval_mode': 'short',
            'attr_mode': 'uniform',
            'order_mode': 'mixed',
            'hot_current_frac': 0.0,
        },
        'balanced': {
            'ratio_open_ended': 0.50,
            'interval_mode': 'medium',
            'attr_mode': 'uniform',
            'order_mode': 'chronological',
            'hot_current_frac': 0.0,
        },
        'long_tailed': {
            'ratio_open_ended': 0.30,
            'interval_mode': 'long_tailed',
            'attr_mode': 'uniform',
            'order_mode': 'mixed',
            'hot_current_frac': 0.0,
        },
        'zipf_uniform': {
            'ratio_open_ended': 0.50,
            'interval_mode': 'medium',
            'attr_mode': 'zipf',
            'order_mode': 'chronological',
            'hot_current_frac': 0.0,
        },
        'zipf_hotcurrent': {
            'ratio_open_ended': 0.70,
            'interval_mode': 'medium',
            'attr_mode': 'zipf',
            'order_mode': 'mixed',
            'hot_current_frac': 0.15,
        },
    }
    
    config = configs.get(args.config, configs['balanced'])
    
    print(f"[*] Generating {args.size} rows with config '{args.config}'", file=sys.stderr)
    print(f"[*] Parameters: {config}", file=sys.stderr)
    
    gen = TemporalDataGenerator(args.size, seed=args.seed)
    rows = gen.generate_dataset(
        row_count=args.size,
        **config
    )
    
    print(f"[*] Generated {len(rows)} rows", file=sys.stderr)
    
    # Write SQL
    sql = gen.generate_sql_insert(rows)
    
    with open(args.output, 'w') as f:
        f.write(sql)
    
    print(f"[+] Wrote SQL to {args.output}", file=sys.stderr)
    print(f"[*] Metadata:")
    print(f"    Size: {args.size}")
    print(f"    Config: {args.config}")
    print(f"    Open-ended ratio: {config['ratio_open_ended']}")
    print(f"    Interval mode: {config['interval_mode']}")
    print(f"    Attribute mode: {config['attr_mode']}")
    print(f"    Order mode: {config['order_mode']}")
    print(f"    Hot-current fraction: {config['hot_current_frac']}")

if __name__ == '__main__':
    main()
