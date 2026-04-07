-- ============================================================================
-- Course 1: Practical Spatial Analytics for Disease Surveillance
-- Module 1: The WOW Moment, Then the Spatial Backstory
-- Database: Vertica
-- ============================================================================
--
-- Teaching approach: We start with the ANSWER, then explain how it works.
-- DDC staff don't need a textbook lecture on coordinate systems first.
-- They need to see what Vertica can do for them RIGHT NOW.
--
-- All tables use GEOMETRY with SRID 4326 (WGS84 lon/lat).
-- Distance is in degrees. At Thai latitude: 1 degree ~ 111 km.
-- To convert: ST_Distance(a, b) * 111000 = approximate meters.
--
-- Prerequisites: Run 00_setup_data.sql first.
-- ============================================================================

SET SEARCH_PATH TO ddc_training, public, v_catalog, v_monitor;

-- ############################################################################
-- PART 1: THE WOW MOMENT
-- ############################################################################

-- QUESTION: Which schools in Bangkok have the most dengue cases within 1 km?
-- 1 km ~ 0.009 degrees at Thai latitude (1000 / 111000)

SELECT
    s.name                                  AS school_name,
    s.district,
    COUNT(*)                                AS cases_within_1km,
    SUM(CASE WHEN d.severity = 'DHF' THEN 1 ELSE 0 END) AS severe_cases,
    ROUND(MIN(ST_Distance(s.geom, d.geom)) * 111000, 0) AS nearest_case_meters
FROM schools s
JOIN dengue_cases d
    ON ST_Distance(s.geom, d.geom) <= 1000.0 / 111000  -- 1 km in degrees
GROUP BY s.name, s.district
ORDER BY cases_within_1km DESC;

-- That's it. One query. No GIS software needed.
-- Try doing THAT in Excel.
--
-- KEY INSIGHT: ST_Distance on GEOMETRY returns degrees.
-- Multiply by 111000 to get approximate meters at Thai latitude.
-- 1000m / 111000 ~ 0.009 degrees is our 1km radius.


-- ############################################################################
-- PART 2: UNDERSTANDING THE SPATIAL TYPE
-- ############################################################################

-- We use GEOMETRY with SRID 4326 (WGS84 = standard GPS coordinates).
-- Coordinates are (longitude, latitude) in degrees.
--
-- Distance returns DEGREES. To get meters:
--   degrees * 111000 = meters (approximate, good enough for Thailand)
--
-- Advantages of GEOMETRY in Vertica CE:
--   - ST_Intersects works directly (no conversion needed)
--   - ST_Buffer works directly
--   - ST_Union works directly
--   - Simpler queries, fewer function calls
--
-- Trade-off: distance is approximate (flat-Earth), not geodesic.
-- For Thailand (~580 km span), the error is <1%. Acceptable for training.

-- DEMONSTRATION: Distance between Bangkok and Chiang Mai
SELECT
    ROUND(
        ST_Distance(
            ST_GeomFromText('POINT(100.4856 13.7590)', 4326),  -- Siriraj, Bangkok
            ST_GeomFromText('POINT(98.9720  18.7880)', 4326)   -- Maharaj, Chiang Mai
        )::NUMERIC,
        4
    ) AS distance_degrees,
    ROUND(
        ST_Distance(
            ST_GeomFromText('POINT(100.4856 13.7590)', 4326),
            ST_GeomFromText('POINT(98.9720  18.7880)', 4326)
        )::NUMERIC * 111000,
        0
    ) AS approx_meters;

-- Result: ~5.36 degrees = ~595 km (actual geodesic: 583 km, ~2% error)


-- ############################################################################
-- PART 3: MORE DISTANCE QUERIES -- BUILDING YOUR INTUITION
-- ############################################################################

-- How far is each dengue case from the nearest hospital?
-- Uses CROSS JOIN + ROW_NUMBER to find the closest match.

SELECT
    case_id,
    patient_age,
    severity,
    nearest_hospital,
    distance_meters
FROM (
    SELECT
        d.case_id,
        d.patient_age,
        d.severity,
        h.name AS nearest_hospital,
        ROUND(ST_Distance(d.geom, h.geom) * 111000, 0) AS distance_meters,
        ROW_NUMBER() OVER (PARTITION BY d.case_id ORDER BY ST_Distance(d.geom, h.geom)) AS rn
    FROM dengue_cases d
    CROSS JOIN hospitals h
) ranked
WHERE rn = 1
ORDER BY distance_meters DESC;

-- WHY THIS MATTERS:
-- If severe dengue cases (DHF, DSS) are far from hospitals, DDC needs
-- to deploy mobile treatment units. This query identifies those gaps.


-- Which hospitals serve the most cases within 5 km?
-- 5 km ~ 0.045 degrees (5000 / 111000)

SELECT
    h.name        AS hospital_name,
    h.province,
    COUNT(d.case_id) AS cases_within_5km,
    SUM(CASE WHEN d.severity IN ('DHF','DSS') THEN 1 ELSE 0 END) AS severe_cases
FROM hospitals h
LEFT JOIN dengue_cases d
    ON ST_Distance(h.geom, d.geom) <= 5000.0 / 111000
GROUP BY h.name, h.province
HAVING COUNT(d.case_id) > 0
ORDER BY cases_within_5km DESC;


-- ############################################################################
-- PART 4: KEY VERTICA FUNCTIONS INTRODUCED IN THIS MODULE
-- ############################################################################

-- +-----------------------------+--------------------------------------------+
-- | Function                    | What it does                               |
-- +-----------------------------+--------------------------------------------+
-- | ST_GeomFromText(wkt, 4326)  | Creates GEOMETRY point from WKT            |
-- | ST_Distance(a, b)           | Distance in DEGREES between two geometries |
-- | ST_Distance(a, b) * 111000  | Approximate distance in METERS             |
-- | ST_AsText(geom)             | Converts spatial object to readable WKT    |
-- | ST_X(geom) / ST_Y(geom)    | Extract longitude / latitude               |
-- | ST_Intersects(a, b)         | TRUE if two geometries overlap             |
-- +-----------------------------+--------------------------------------------+
--
-- Distance conversion: degrees * 111000 = meters (at Thai latitude ~14N)
-- Radius conversion:   meters / 111000 = degrees


-- ############################################################################
-- EXERCISE: Find the 3 hospitals closest to the Khlong Toei cluster
-- ############################################################################
--
-- Cluster center: POINT(100.554 13.723)
--
-- Hints:
--   1. Use ST_GeomFromText('POINT(100.554 13.723)', 4326)
--   2. Use ST_Distance(h.geom, cluster_point) * 111000 for meters
--   3. ORDER BY distance, LIMIT 3
-- ============================================================================
