#!/bin/bash
set -e

INIT_FLAG="/app/.state/.init_done"
CSV_DIR="/app/.state"
DATA_GEN="/app/data_generation/generate_ddc_data.py"
SQL_RUNNER="python /app/run_sql.py"

# ------------------------------------------------------------------
# Skip init if already done (persistent volume or re-run)
# ------------------------------------------------------------------
if [ -f "$INIT_FLAG" ]; then
    echo "=============================================="
    echo "  DDC Training: already initialized"
    echo "  Starting Jupyter Lab..."
    echo "=============================================="
    exec jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root \
        --notebook-dir=/app/notebooks --NotebookApp.token=''
fi

echo "=============================================="
echo "  DDC Training: First-time initialization"
echo "=============================================="

# ------------------------------------------------------------------
# Step 1: Generate synthetic patient data
# ------------------------------------------------------------------
echo ""
echo "[1/4] Generating synthetic patient data..."
mkdir -p "$CSV_DIR"
python "$DATA_GEN" \
    --rows "${DDC_ROW_COUNT:-5000000}" \
    --output "$CSV_DIR/ddc_patients.csv"

# ------------------------------------------------------------------
# Step 2: Run Course 1 SQL scripts
# ------------------------------------------------------------------
echo ""
echo "[2/4] Running Course 1 SQL scripts..."
$SQL_RUNNER \
    /app/sql/course_1/00_setup_data.sql \
    /app/sql/course_1/01_wow_then_geography.sql \
    /app/sql/course_1/02_risk_buffers.sql \
    /app/sql/course_1/03_hexbin_heatmap.sql

# ------------------------------------------------------------------
# Step 3: Run Course 2 SQL scripts + bulk load
# ------------------------------------------------------------------
echo ""
echo "[3/4] Running Course 2 SQL scripts + bulk data load..."
$SQL_RUNNER --csv-dir "$CSV_DIR" \
    /app/sql/course_2/00_setup_data.sql \
    /app/sql/workshop/load_bulk_data.sql \
    /app/sql/course_2/02_projection_performance.sql \
    /app/sql/course_2/03_scd_type2.sql

# ------------------------------------------------------------------
# Step 4: Generate visualization
# ------------------------------------------------------------------
echo ""
echo "[4/4] Generating outbreak visualization..."
cd /app/output
python /app/notebooks/course_1/notebooks/visualize_outbreak.py || \
    echo "  [WARN] Visualization skipped (non-critical)"

# ------------------------------------------------------------------
# Mark init complete and start Jupyter
# ------------------------------------------------------------------
touch "$INIT_FLAG"

echo ""
echo "=============================================="
echo "  Initialization complete!"
echo "  Starting Jupyter Lab on port 8888..."
echo "=============================================="

exec jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root \
    --notebook-dir=/app/notebooks --NotebookApp.token=''
