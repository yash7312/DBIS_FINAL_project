# DBIS Assignment

This repository contains a PostgreSQL source tree with the temporal R-tree extension, the data generator used for the benchmark dataset, and the scripts that reproduce the experiment logs.

## How To Run

1. Set up PostgreSQL from the `postgresql/` directory first, using the normal first-time build and install flow for a source checkout.
2. Make sure the PostgreSQL binaries and libraries are available to the shell session that will run the experiment scripts.
3. From the repository root, run `bash run_reproducible_experiments.sh`.

The top-level script runs the full pipeline and writes fresh artifacts into `experiment_logs/`.

## What `run_reproducible_experiments.sh` Does

1. Rebuilds PostgreSQL core.
2. Builds and installs the `temporal_rtree` extension.
3. Initializes or reuses the dedicated PostgreSQL data directory and starts the server.
4. Creates the `test` database, loads the schema, and generates the benchmark dataset.
5. Runs the benchmark matrix across all supported index configurations.
6. Collects normalized metrics and writes the final reproducibility outputs.

## Database Generator

The dataset generator is [data_generation/temporal_generator.py](data_generation/temporal_generator.py). It creates SQL insert statements for a temporal table with these columns:

- `id`: sequential row identifier.
- `attr`: integer attribute used by the composite benchmarks.
- `valid_period`: `tsrange` interval, either finite or open-ended.
- `payload`: synthetic text payload.

The script accepts four main options:

- `--size`: number of rows to generate. The reproducible run uses `100000`.
- `--config`: preset that controls temporal shape, attribute distribution, and row ordering.
- `--output`: destination SQL file.
- `--seed`: random seed for deterministic output.

### Generator Presets

- `balanced`: 50% open-ended rows, medium interval widths, uniform attributes, chronological order.
- `history_skew`: 30% open-ended rows, short intervals, uniform attributes, chronological order.
- `current_skew`: 80% open-ended rows, short intervals, uniform attributes, mixed order.
- `long_tailed`: 30% open-ended rows, long-tailed interval widths, uniform attributes, mixed order.
- `zipf_uniform`: 50% open-ended rows, medium intervals, Zipf-distributed attributes, chronological order.
- `zipf_hotcurrent`: 70% open-ended rows, medium intervals, Zipf-distributed attributes, mixed order, with a hot-current concentration for some open-ended rows.

### How the Generator Works

The generator builds each row from a base timestamp of 2023-01-01 and advances lower bounds across a 10-year window. Depending on the preset, the upper bound is either omitted to represent a current row or set using short, medium, or long-tailed widths. Attribute values are either uniform or Zipf-like, and some presets bias current rows toward a small hot set of attribute values.

The repository's reproducible run uses:

```bash
python3 data_generation/temporal_generator.py --size 100000 --config balanced --output experiment_logs/benchmark_dataset.sql --seed 42
```

## Benchmark Inputs And Outputs

The main reproducible run produces these artifacts:

- `experiment_logs/reproducibility_manifest.txt`
- `experiment_logs/wallclock.log`
- `experiment_logs/experiment_metrics.csv`
- `experiment_logs/benchmark_matrix/results_*.txt`
- `experiment_logs/benchmark_matrix/read_results_*.txt`
- `experiment_logs/benchmark_matrix/metrics_*.csv`

## Notes

- The benchmark scripts assume the PostgreSQL server is reachable on `localhost`.
- The top-level script defaults to PostgreSQL port `5543`.
