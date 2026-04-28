#!/bin/bash
# Generate all benchmark datasets for Checkpoint C2

set -e

OUTPUT_DIR="${1:-.}"
mkdir -p "$OUTPUT_DIR"

# Dataset sizes
SIZES=(100000 1000000 5000000 10000000)

# Configurations to generate
CONFIGS=(
    "history_skew"
    "current_skew"
    "balanced"
    "long_tailed"
    "zipf_uniform"
    "zipf_hotcurrent"
)

echo "[*] Generating temporal datasets to $OUTPUT_DIR"
echo ""

for size in "${SIZES[@]}"; do
    for config in "${CONFIGS[@]}"; do
        size_name=$(printf "%dk\n" $((size / 1000)))
        output_file="$OUTPUT_DIR/temporal_data_${size_name}_${config}.sql"
        
        echo "[*] Generating: size=$size, config=$config"
        python3 temporal_generator.py \
            --size "$size" \
            --config "$config" \
            --output "$output_file" \
            --seed 42
        
        lines=$(wc -l < "$output_file")
        echo "    Output: $output_file ($lines lines)"
    done
    echo ""
done

echo "[+] All datasets generated successfully to $OUTPUT_DIR"
