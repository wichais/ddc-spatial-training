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
        --NotebookApp.token=''
fi

echo "=============================================="
echo "  DDC Training: First-time initialization"
echo "=============================================="

# ------------------------------------------------------------------
# Wait for Vertica spatial extension (Place) to be ready
# ------------------------------------------------------------------
echo ""
echo "Waiting for Vertica spatial functions..."
for i in $(seq 1 30); do
    if python -c "
import vertica_python, os
conn = vertica_python.connect(
    host=os.environ.get('VERTICA_HOST','ddc-vertica'),
    port=int(os.environ.get('VERTICA_PORT','5433')),
    user=os.environ.get('VERTICA_USER','dbadmin'),
    password=os.environ.get('VERTICA_PASSWORD',''),
    database=os.environ.get('VERTICA_DATABASE','VMart'))
cur = conn.cursor()
cur.execute(\"SELECT ST_GeographyFromText('POINT(0 0)')\")
cur.fetchone()
print('  Spatial functions ready!')
conn.close()
" 2>/dev/null; then
        break
    fi
    echo "  Attempt $i/30 - waiting 5s..."
    sleep 5
done

# ------------------------------------------------------------------
# Run Course 1 SQL scripts
# ------------------------------------------------------------------
echo ""
echo "Running Course 1 SQL scripts..."
mkdir -p /app/.state
$SQL_RUNNER \
    /app/sql/course_1/00_setup_data.sql \
    /app/sql/course_1/01_wow_then_geography.sql \
    /app/sql/course_1/02_risk_buffers.sql \
    /app/sql/course_1/03_hexbin_heatmap.sql

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
    --NotebookApp.token=''
