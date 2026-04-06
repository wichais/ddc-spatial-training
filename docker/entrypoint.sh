#!/bin/bash
set -e

INIT_FLAG="/app/.state/.init_done"
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
# Step 1: Run Course 1 SQL scripts
# ------------------------------------------------------------------
echo ""
echo "[1/2] Running Course 1 SQL scripts..."
mkdir -p /app/.state
$SQL_RUNNER \
    /app/sql/course_1/00_setup_data.sql \
    /app/sql/course_1/01_wow_then_geography.sql \
    /app/sql/course_1/02_risk_buffers.sql \
    /app/sql/course_1/03_hexbin_heatmap.sql

# ------------------------------------------------------------------
# Step 2: Generate visualization
# ------------------------------------------------------------------
echo ""
echo "[2/2] Generating outbreak visualization..."
mkdir -p /app/output
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
