-- ============================================================================
-- Course 1: Practical Spatial Analytics for Disease Surveillance
-- Module 3: Spatial Heatmaps -- DDC Weekly Situation Report
-- Database: Vertica
-- ============================================================================
--
-- SPATIAL BINNING: grouping nearby cases into grid cells for heatmaps.
--
-- We use GeoHash-based binning: ST_GeoHash assigns each point a string code
-- representing a rectangular cell on the map. Truncating the hash controls
-- the cell size (resolution). ST_GeomFromGeoHash converts a hash back to a
-- cell polygon for visualization.
--
-- GeoHash precision (characters → approximate cell size at Thai latitudes):
--   5 chars  ~ 4.9 km × 4.9 km  (province-level overview)
--   6 chars  ~ 1.2 km × 0.6 km  (city-level, a few blocks)
--   7 chars  ~ 153 m × 153 m    (neighborhood-level)
--
-- SCENARIO: DDC publishes a weekly dengue situation report.
-- We will generate spatial heatmaps at multiple resolutions, add a time
-- dimension for outbreak progression, and store results for visualization.
--
-- Prerequisites: Run 00_setup_data.sql first.
-- Creates: dengue_hexbin_report (persists for visualization notebook).
-- ============================================================================

SET SEARCH_PATH TO ddc_training, public, v_catalog, v_monitor;


-- ############################################################################
-- PART 1: ASSIGN EACH CASE TO A GRID CELL
-- ############################################################################

-- ST_GeoHash converts a point to a string address on a global grid.
-- Truncating to fewer characters gives a coarser (larger) cell.

-- Let's see how the same point maps to different resolutions:
SELECT
    case_id,
    SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(geog))), 1, 5) AS cell_5,
    SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(geog))), 1, 6) AS cell_6,
    SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(geog))), 1, 7) AS cell_7
FROM dengue_cases
ORDER BY cell_6, case_id;

-- NOTICE: Cases in the same cluster share the same cell_6 value.
-- This is spatial binning -- grouping nearby cases into a single cell.


-- ############################################################################
-- PART 2: COUNT CASES PER GRID CELL (THE HEATMAP)
-- ############################################################################

-- This is the core of a heatmap: how many cases per cell?

SELECT
    SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(geog))), 1, 6) AS cell_id,
    COUNT(*)                   AS case_count,
    SUM(CASE WHEN severity IN ('DHF','DSS') THEN 1 ELSE 0 END) AS severe_count,
    MIN(infection_date)        AS first_case_date,
    MAX(infection_date)        AS last_case_date,
    DATEDIFF('day', MIN(infection_date), MAX(infection_date)) AS outbreak_duration_days
FROM dengue_cases
GROUP BY SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(geog))), 1, 6)
ORDER BY case_count DESC;

-- INTERPRETATION:
-- The cell with the highest count is the primary hotspot.
-- DDC should prioritize this cell for immediate vector control.
-- Outbreak duration tells us if this is an ongoing or resolved cluster.


-- ############################################################################
-- PART 3: RETRIEVE CELL POLYGONS FOR VISUALIZATION
-- ############################################################################

-- ST_GeomFromGeoHash converts a hash back to its bounding-box polygon.
-- This is what you draw on the map. Each cell gets colored by case_count.

SELECT
    cell_id,
    case_count,
    severe_count,
    first_case_date,
    last_case_date,
    ST_AsText(ST_GeomFromGeoHash(cell_id)) AS cell_polygon_wkt
FROM (
    SELECT
        SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(geog))), 1, 6) AS cell_id,
        COUNT(*)                   AS case_count,
        SUM(CASE WHEN severity IN ('DHF','DSS') THEN 1 ELSE 0 END) AS severe_count,
        MIN(infection_date)        AS first_case_date,
        MAX(infection_date)        AS last_case_date
    FROM dengue_cases
    GROUP BY SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(geog))), 1, 6)
) bins
ORDER BY case_count DESC;

-- The cell_polygon_wkt column can be loaded into Folium, Kepler.gl, QGIS,
-- or any mapping library. The workflow is:
--   1. Run this query in Vertica
--   2. Export to CSV or read via JDBC/ODBC
--   3. Parse the WKT polygons in Python
--   4. Color each cell by case_count (red = high, yellow = low)


-- ############################################################################
-- PART 4: COMPARING RESOLUTIONS -- ZOOM IN AND OUT
-- ############################################################################

-- Precision 5: Province-level overview (coarse, ~5 km cells)
SELECT
    'Precision 5 (province)' AS level,
    SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(geog))), 1, 5) AS cell_id,
    COUNT(*) AS case_count
FROM dengue_cases
GROUP BY SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(geog))), 1, 5)
ORDER BY case_count DESC;

-- Precision 6: City-level (medium, ~1 km cells)
SELECT
    'Precision 6 (city)' AS level,
    SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(geog))), 1, 6) AS cell_id,
    COUNT(*) AS case_count
FROM dengue_cases
GROUP BY SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(geog))), 1, 6)
ORDER BY case_count DESC;

-- Precision 7: Neighborhood-level (fine, ~150 m cells)
SELECT
    'Precision 7 (neighborhood)' AS level,
    SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(geog))), 1, 7) AS cell_id,
    COUNT(*) AS case_count
FROM dengue_cases
GROUP BY SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(geog))), 1, 7)
ORDER BY case_count DESC;

-- OBSERVATION:
--   Precision 5: Most cases merge into 2-3 large cells (BKK, CM, CR)
--   Precision 6: Bangkok splits into 2 visible clusters
--   Precision 7: Individual blocks within each cluster become visible
--
-- DDC GUIDELINE: Use 5 for national reports, 6 for provincial, 7 for district.


-- ############################################################################
-- PART 5: TIME DIMENSION -- OUTBREAK PROGRESSION BY MONTH
-- ############################################################################

-- The situation report needs to show how the outbreak MOVES over time.
-- We add month binning on top of spatial grid cells.

SELECT
    DATE_TRUNC('month', infection_date)    AS report_month,
    SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(geog))), 1, 6) AS cell_id,
    COUNT(*)                               AS case_count,
    SUM(CASE WHEN severity IN ('DHF','DSS') THEN 1 ELSE 0 END) AS severe_count,
    ST_AsText(ST_GeomFromGeoHash(
        SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(geog))), 1, 6)
    )) AS cell_polygon_wkt
FROM dengue_cases
GROUP BY DATE_TRUNC('month', infection_date),
         SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(geog))), 1, 6)
ORDER BY report_month, case_count DESC;

-- READING THE OUTPUT:
--   June 2024:  Cases appear in Khlong Toei (Bangkok) only
--   July 2024:  Explosion -- Bangkok clusters grow, Chiang Mai appears
--   August 2024: All three provinces active, severe cases rising
--   September 2024: Chiang Rai border cluster emerges


-- ############################################################################
-- PART 6: STORE RESULTS FOR VISUALIZATION
-- ############################################################################

-- Save at precision 6 (city-level) with monthly breakdown.
-- This table feeds directly into the Python visualization notebook.

DROP TABLE IF EXISTS dengue_hexbin_report;

CREATE TABLE dengue_hexbin_report AS
SELECT
    DATE_TRUNC('month', d.infection_date)  AS report_month,
    6                                       AS grid_precision,
    SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(d.geog))), 1, 6) AS cell_id,
    COUNT(*)                                AS case_count,
    SUM(CASE WHEN d.severity = 'DF'  THEN 1 ELSE 0 END) AS df_count,
    SUM(CASE WHEN d.severity = 'DHF' THEN 1 ELSE 0 END) AS dhf_count,
    SUM(CASE WHEN d.severity = 'DSS' THEN 1 ELSE 0 END) AS dss_count,
    ROUND(AVG(d.patient_age), 1)            AS avg_age,
    ST_GeomFromGeoHash(
        SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(d.geog))), 1, 6)
    ) AS hex_geom
FROM dengue_cases d
GROUP BY DATE_TRUNC('month', d.infection_date),
         SUBSTR(ST_GeoHash(ST_GeomFromText(ST_AsText(d.geog))), 1, 6);

COMMIT;

-- Verify stored results:
SELECT
    report_month,
    cell_id,
    case_count,
    dhf_count + dss_count   AS severe_count,
    avg_age,
    ST_AsText(hex_geom)     AS cell_polygon_wkt
FROM dengue_hexbin_report
ORDER BY report_month, case_count DESC;


-- ############################################################################
-- PART 7: COMBINING GRID CELLS WITH RISK ZONES (CROSS-MODULE)
-- ############################################################################

-- Which heatmap hotspots overlap with our Module 2 risk zones?
-- This demonstrates how tables build on each other across modules.

SELECT
    hr.report_month,
    hr.case_count      AS cell_cases,
    rz.risk_tier,
    rz.province_name,
    rz.area_sq_km      AS risk_zone_area
FROM dengue_hexbin_report hr
JOIN dengue_risk_zones rz
    ON ST_Intersects(ST_GeomFromText(ST_AsText(rz.zone_geom)),
                     ST_GeomFromText(ST_AsText(hr.hex_geom)))
WHERE rz.risk_tier = 'RED'
ORDER BY hr.report_month, hr.case_count DESC;


-- ############################################################################
-- KEY VERTICA FUNCTIONS INTRODUCED IN THIS MODULE
-- ############################################################################

-- +----------------------------------------+------------------------------------+
-- | Function                               | What it does                       |
-- +----------------------------------------+------------------------------------+
-- | ST_GeoHash(geom)                       | Returns GeoHash string for a point |
-- | SUBSTR(hash, 1, N)                     | Controls cell size (precision)     |
-- | ST_GeomFromGeoHash(hash)               | Returns cell bounding-box polygon  |
-- | DATE_TRUNC('month', date)              | Truncates date for time binning    |
-- +----------------------------------------+------------------------------------+
--
-- NOTE: Vertica Enterprise also offers ST_HexagonCellId / ST_Hexagon for
-- native hexagonal binning. GeoHash uses rectangular cells but achieves
-- the same goal: spatial aggregation for heatmap visualization.


-- ############################################################################
-- SUMMARY: WHAT WE BUILT ACROSS ALL THREE MODULES
-- ############################################################################

-- Tables created (all persistent):
--   00_setup:    hospitals, dengue_cases, schools, province_boundaries
--   Module 2:    dengue_risk_zones  (buffers + area analysis)
--   Module 3:    dengue_hexbin_report (spatial heatmap data)
--
-- Next step: Load dengue_hexbin_report into a Python notebook for
-- interactive visualization with Folium or Kepler.gl.
-- See: course_1/notebooks/visualize_outbreak.py
