-- ============================================================================
-- Course 1: Practical Spatial Analytics for Disease Surveillance
-- Module 3: Spatial Heatmaps -- DDC Weekly Situation Report
-- Database: Vertica
-- ============================================================================
--
-- SPATIAL BINNING: grouping nearby cases into grid cells for heatmaps.
--
-- ST_GeoHash assigns each point a string code representing a rectangular
-- cell on the map. Truncating the hash controls cell size (resolution).
-- ST_GeomFromGeoHash converts a hash back to a cell polygon for visualization.
--
-- GeoHash precision (characters -> approximate cell size at Thai latitudes):
--   5 chars  ~ 4.9 km x 4.9 km  (province-level overview)
--   6 chars  ~ 1.2 km x 0.6 km  (city-level, a few blocks)
--   7 chars  ~ 153 m x 153 m    (neighborhood-level)
--
-- All tables use GEOMETRY with SRID 4326.
--
-- Prerequisites: Run 00_setup_data.sql first.
-- Creates: dengue_hexbin_report (persists for visualization notebook).
-- ============================================================================

SET SEARCH_PATH TO ddc_training, public, v_catalog, v_monitor;


-- ############################################################################
-- PART 1: ASSIGN EACH CASE TO A GRID CELL
-- ############################################################################

SELECT
    case_id,
    SUBSTR(ST_GeoHash(geom), 1, 5) AS cell_5,
    SUBSTR(ST_GeoHash(geom), 1, 6) AS cell_6,
    SUBSTR(ST_GeoHash(geom), 1, 7) AS cell_7
FROM dengue_cases
ORDER BY cell_6, case_id;


-- ############################################################################
-- PART 2: COUNT CASES PER GRID CELL (THE HEATMAP)
-- ############################################################################

SELECT
    SUBSTR(ST_GeoHash(geom), 1, 6) AS cell_id,
    COUNT(*)                   AS case_count,
    SUM(CASE WHEN severity IN ('DHF','DSS') THEN 1 ELSE 0 END) AS severe_count,
    MIN(infection_date)        AS first_case_date,
    MAX(infection_date)        AS last_case_date,
    DATEDIFF('day', MIN(infection_date), MAX(infection_date)) AS outbreak_duration_days
FROM dengue_cases
GROUP BY SUBSTR(ST_GeoHash(geom), 1, 6)
ORDER BY case_count DESC;


-- ############################################################################
-- PART 3: RETRIEVE CELL POLYGONS FOR VISUALIZATION
-- ############################################################################

SELECT
    cell_id,
    case_count,
    severe_count,
    first_case_date,
    last_case_date,
    ST_AsText(ST_GeomFromGeoHash(cell_id)) AS cell_polygon_wkt
FROM (
    SELECT
        SUBSTR(ST_GeoHash(geom), 1, 6) AS cell_id,
        COUNT(*)                   AS case_count,
        SUM(CASE WHEN severity IN ('DHF','DSS') THEN 1 ELSE 0 END) AS severe_count,
        MIN(infection_date)        AS first_case_date,
        MAX(infection_date)        AS last_case_date
    FROM dengue_cases
    GROUP BY SUBSTR(ST_GeoHash(geom), 1, 6)
) bins
ORDER BY case_count DESC;


-- ############################################################################
-- PART 4: COMPARING RESOLUTIONS
-- ############################################################################

SELECT 'Precision 5' AS level, SUBSTR(ST_GeoHash(geom), 1, 5) AS cell_id, COUNT(*) AS case_count
FROM dengue_cases GROUP BY cell_id ORDER BY case_count DESC;

SELECT 'Precision 6' AS level, SUBSTR(ST_GeoHash(geom), 1, 6) AS cell_id, COUNT(*) AS case_count
FROM dengue_cases GROUP BY cell_id ORDER BY case_count DESC;

SELECT 'Precision 7' AS level, SUBSTR(ST_GeoHash(geom), 1, 7) AS cell_id, COUNT(*) AS case_count
FROM dengue_cases GROUP BY cell_id ORDER BY case_count DESC;


-- ############################################################################
-- PART 5: TIME DIMENSION -- OUTBREAK PROGRESSION BY MONTH
-- ############################################################################

SELECT
    DATE_TRUNC('month', infection_date) AS report_month,
    SUBSTR(ST_GeoHash(geom), 1, 6)     AS cell_id,
    COUNT(*)                            AS case_count,
    SUM(CASE WHEN severity IN ('DHF','DSS') THEN 1 ELSE 0 END) AS severe_count,
    ST_AsText(ST_GeomFromGeoHash(
        SUBSTR(ST_GeoHash(geom), 1, 6)
    )) AS cell_polygon_wkt
FROM dengue_cases
GROUP BY DATE_TRUNC('month', infection_date),
         SUBSTR(ST_GeoHash(geom), 1, 6)
ORDER BY report_month, case_count DESC;


-- ############################################################################
-- PART 6: STORE RESULTS FOR VISUALIZATION
-- ############################################################################

DROP TABLE IF EXISTS dengue_hexbin_report;

CREATE TABLE dengue_hexbin_report AS
SELECT
    DATE_TRUNC('month', d.infection_date) AS report_month,
    6                                      AS grid_precision,
    SUBSTR(ST_GeoHash(d.geom), 1, 6)      AS cell_id,
    COUNT(*)                               AS case_count,
    SUM(CASE WHEN d.severity = 'DF'  THEN 1 ELSE 0 END) AS df_count,
    SUM(CASE WHEN d.severity = 'DHF' THEN 1 ELSE 0 END) AS dhf_count,
    SUM(CASE WHEN d.severity = 'DSS' THEN 1 ELSE 0 END) AS dss_count,
    ROUND(AVG(d.patient_age), 1)           AS avg_age,
    ST_GeomFromGeoHash(
        SUBSTR(ST_GeoHash(d.geom), 1, 6)
    ) AS hex_geom
FROM dengue_cases d
GROUP BY DATE_TRUNC('month', d.infection_date),
         SUBSTR(ST_GeoHash(d.geom), 1, 6);

COMMIT;

SELECT report_month, cell_id, case_count,
    dhf_count + dss_count AS severe_count, avg_age,
    ST_AsText(hex_geom) AS cell_polygon_wkt
FROM dengue_hexbin_report
ORDER BY report_month, case_count DESC;


-- ############################################################################
-- PART 7: COMBINING GRID CELLS WITH RISK ZONES (CROSS-MODULE)
-- ############################################################################

SELECT
    hr.report_month,
    hr.case_count      AS cell_cases,
    rz.risk_tier,
    rz.province_name,
    rz.area_sq_km
FROM dengue_hexbin_report hr
JOIN dengue_risk_zones rz
    ON ST_Intersects(rz.zone_geom, hr.hex_geom)
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
-- | ST_Intersects(a, b)                    | Check if geometries overlap        |
-- +----------------------------------------+------------------------------------+
-- ============================================================================
