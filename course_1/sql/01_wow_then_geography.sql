-- ============================================================================
-- Course 1: Practical Spatial Analytics for Disease Surveillance
-- Module 1: The WOW Moment, Then the Geography Backstory
-- Database: Vertica
-- ============================================================================
--
-- Teaching approach: We start with the ANSWER, then explain how it works.
-- DDC staff don't need a textbook lecture on coordinate systems first.
-- They need to see what Vertica can do for them RIGHT NOW.
--
-- Prerequisites: Run 00_setup_data.sql first.
-- ============================================================================

SET SEARCH_PATH TO ddc_training, public, v_catalog, v_monitor;

-- ############################################################################
-- PART 1: THE WOW MOMENT
-- ############################################################################

-- QUESTION: Which schools in Bangkok have the most dengue cases within 1 km?
-- In Vertica, this is ONE query:

SELECT
    s.name                                  AS school_name,
    s.district,
    COUNT(*)                                AS cases_within_1km,
    SUM(CASE WHEN d.severity = 'DHF' THEN 1 ELSE 0 END) AS severe_cases,
    ROUND(MIN(ST_Distance(s.geog, d.geog)), 0) AS nearest_case_meters
FROM schools s
JOIN dengue_cases d
    ON ST_Distance(s.geog, d.geog) <= 1000 -- 1000 meters = 1 km
GROUP BY s.name, s.district
ORDER BY cases_within_1km DESC;

-- That's it. One query. Real distances in meters. No projections to configure.
-- Try doing THAT in Excel.
--
-- KEY INSIGHT: ST_DWithin(geog, geog, 1000) means "within 1000 METERS"
-- because we used the GEOGRAPHY type. Vertica knows these are points on
-- Earth and calculates distance on the curved surface automatically.


-- ############################################################################
-- PART 2: THE BACKSTORY -- WHY GEOGRAPHY MATTERS
-- ############################################################################

-- Now that you've seen the power, let's understand WHY it works.
-- Vertica has TWO spatial types. Choosing the right one matters.

-- ---------------------------------------------------------
-- GEOGRAPHY: Coordinates on the Earth's curved surface
--   - Units: degrees (lon/lat), but calculations return METERS
--   - Distance: follows the curve of the Earth (geodesic)
--   - Best for: anything spanning more than a single city
--   - DDC use: disease surveillance across Thailand = GEOGRAPHY
-- ---------------------------------------------------------
-- GEOMETRY: Coordinates on a flat plane
--   - Units: whatever the coordinate system says (often degrees!)
--   - Distance: straight-line on a flat plane (Euclidean)
--   - Best for: small areas with a local projection (UTM)
--   - DDC use: detailed building-level mapping in one district
-- ---------------------------------------------------------


-- DEMONSTRATION: The same two points, measured both ways.
-- Siriraj Hospital to Chiang Mai Hospital -- roughly 580 km apart.

-- Using GEOGRAPHY: gives you METERS (correct answer)
SELECT
    'GEOGRAPHY (meters)' AS method,
    ROUND(
        ST_Distance(
            ST_GeographyFromText('POINT(100.4856 13.7590)'),   -- Siriraj, Bangkok
            ST_GeographyFromText('POINT(98.9720  18.7880)')    -- Maharaj, Chiang Mai
        ),
        0
    ) AS distance_value,
    'meters' AS unit;

-- Using GEOMETRY with SRID 4326: gives you DEGREES (useless for DDC!)
SELECT
    'GEOMETRY (degrees)' AS method,
    ROUND(
        ST_Distance(
            ST_GeomFromText('POINT(100.4856 13.7590)', 4326),   -- same points
            ST_GeomFromText('POINT(98.9720  18.7880)', 4326)
        )::NUMERIC,
        4
    ) AS distance_value,
    'degrees -- not useful!' AS unit;

-- RESULT COMPARISON:
--   GEOGRAPHY:  ~583,000 (meters)  = 583 km  -- this is correct!
--   GEOMETRY:   ~5.36 (degrees)               -- meaningless for fieldwork
--
-- When a DDC officer asks "how far is the outbreak from the hospital?"
-- they need METERS, not degrees. That is why we use GEOGRAPHY.


-- ############################################################################
-- PART 3: WHAT IF YOU NEED GEOMETRY? USE ST_Transform
-- ############################################################################

-- Sometimes external data arrives in GEOMETRY (e.g., shapefiles with UTM zone 47N).
-- Thailand uses UTM Zone 47N (SRID 32647) for national mapping.
-- Here's how to convert:

-- Step 1: Create a geometry point in UTM Zone 47N
-- Step 2: Transform it to WGS84 (SRID 4326)
-- Step 3: Cast to GEOGRAPHY for distance calculations

-- NOTE: ST_Transform with UTM projections (e.g., SRID 32647) is not available
-- in Vertica Community Edition. In production Vertica, you would use:
--   ST_Transform(ST_GeomFromText('POINT(662000 1524000)', 32647), 4326)
--
-- For this training, we demonstrate the concept with a direct WKT cast instead:

SELECT
    ST_AsText(
        ST_GeomFromText('POINT(100.49 13.76)', 4326)  -- already WGS84
    ) AS wgs84_point,
    'In production, use ST_Transform(geom, 4326) to convert from UTM' AS note;

-- PRACTICAL RULE FOR DDC:
-- If your data comes from Thai government GIS (DOPA, GISTDA):
--   1. Check the SRID (usually 32647 for UTM 47N, or 4326 for WGS84)
--   2. Transform to 4326 if needed
--   3. Cast to GEOGRAPHY for all distance/area calculations
--
-- For this course, everything is already in GEOGRAPHY. In production,
-- you will need ST_Transform when importing shapefiles from GADM or DOPA.


-- ############################################################################
-- PART 4: MORE DISTANCE QUERIES -- BUILDING YOUR INTUITION
-- ############################################################################

-- How far is each dengue case from the nearest hospital?
-- This uses a CROSS JOIN with ROW_NUMBER to find the closest match.

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
        ROUND(ST_Distance(d.geog, h.geog), 0) AS distance_meters,
        ROW_NUMBER() OVER (PARTITION BY d.case_id ORDER BY ST_Distance(d.geog, h.geog)) AS rn
    FROM dengue_cases d
    CROSS JOIN hospitals h
) ranked
WHERE rn = 1
ORDER BY distance_meters DESC;

-- WHY THIS MATTERS:
-- If severe dengue cases (DHF, DSS) are far from hospitals, DDC needs
-- to deploy mobile treatment units. This query identifies those gaps.


-- Which hospitals serve the most cases within 5 km?
-- This tells DDC which facilities need extra dengue supplies.

SELECT
    h.name        AS hospital_name,
    h.province,
    COUNT(d.case_id) AS cases_within_5km,
    SUM(CASE WHEN d.severity IN ('DHF','DSS') THEN 1 ELSE 0 END) AS severe_cases
FROM hospitals h
LEFT JOIN dengue_cases d
    ON ST_Distance(h.geog, d.geog) <= 5000 -- 5 km radius
GROUP BY h.name, h.province
HAVING COUNT(d.case_id) > 0
ORDER BY cases_within_5km DESC;


-- ############################################################################
-- PART 5: KEY VERTICA FUNCTIONS INTRODUCED IN THIS MODULE
-- ############################################################################

-- +-----------------------------+--------------------------------------------+
-- | Function                    | What it does                               |
-- +-----------------------------+--------------------------------------------+
-- | ST_GeographyFromText()      | Creates GEOGRAPHY from WKT string          |
-- | ST_Distance(geog, geog)     | Distance in METERS between two geographies |
-- | ST_Distance(g,g) <= meters  | TRUE if two geographies are within m meters|
-- | ST_GeomFromText(wkt, srid)  | Creates GEOMETRY with a coordinate system  |
-- | ST_Transform(geom, srid)    | Reprojects GEOMETRY to a different SRID    |
-- | ST_AsText(geog or geom)     | Converts spatial object to readable WKT    |
-- +-----------------------------+--------------------------------------------+


-- ############################################################################
-- EXERCISE: Find the 3 hospitals closest to each dengue cluster centroid
-- ############################################################################
--
-- Hints:
--   1. Use GROUP BY to define clusters (e.g., by province or by proximity)
--   2. Use ST_Centroid or simply pick a representative case per cluster
--   3. Use ROW_NUMBER() OVER (PARTITION BY cluster ORDER BY distance)
--   4. Filter WHERE rn <= 3
--
-- Bonus: Which cluster has the worst hospital access (farthest nearest hospital)?
-- ============================================================================
