-- ============================================================================
-- Course 1: Practical Spatial Analytics for Disease Surveillance
-- Module 2: Risk Buffers -- Where Should DDC Deploy Fogging Teams?
-- Database: Vertica
-- ============================================================================
--
-- SCENARIO: DDC has confirmed 30 dengue cases across three provinces.
-- Mosquito fogging teams need deployment zones. Budget is limited.
-- We need to answer:
--   1. Where are the risk rings around each case?
--   2. Which schools and hospitals fall inside those rings?
--   3. What is the total area that needs fogging?
--   4. How do we prioritize by severity tier?
--
-- Prerequisites: Run 00_setup_data.sql first.
-- This module creates: dengue_risk_zones (persists for later modules).
--
-- NOTE ON ST_Buffer IN VERTICA:
-- ST_Buffer only works with GEOMETRY (flat coordinates), not GEOGRAPHY.
-- Since our data is stored as GEOGRAPHY (lat/lon on Earth's surface), we
-- convert to GEOMETRY for buffering using ST_GeomFromText(ST_AsText(geog)).
-- Buffer distances in GEOMETRY are in degrees; at Thai latitudes (~14°N),
-- 1 degree ≈ 111,000 meters. We define a helper ratio for conversion.
-- For precise distance checks, we still use ST_Distance on GEOGRAPHY.
-- ============================================================================

SET SEARCH_PATH TO ddc_training, public, v_catalog, v_monitor;

-- Approximate conversion: meters to degrees at Thai latitude (~14°N)
-- 1 degree latitude  ≈ 111,000 m
-- 1 degree longitude ≈ 108,000 m at 14°N (cos(14°) * 111,000)
-- We use 111,000 as a simple approximation (good enough for visualization).


-- ############################################################################
-- PART 1: CREATING RISK BUFFERS AROUND DENGUE CASES
-- ############################################################################

-- DDC uses three risk tiers for vector control:
--   RED:    0 - 500m   (immediate fogging, larval survey)
--   ORANGE: 500m - 1km (fogging within 48 hours)
--   YELLOW: 1km - 2km  (enhanced surveillance, community awareness)

-- Let's see what a single 500m buffer looks like:

SELECT
    case_id,
    severity,
    ST_AsText(
        ST_Buffer(ST_GeomFromText(ST_AsText(geog)), 500.0 / 111000)
    ) AS buffer_500m_wkt
FROM dengue_cases
WHERE case_id = 1;

-- That WKT polygon is a circle with ~500m radius around case #1.
-- In a GIS viewer, this would appear as a red ring around the patient's location.


-- Now create all three tiers for every case:

SELECT
    case_id,
    severity,
    infection_date,
    'RED'    AS risk_tier,
    500      AS radius_meters,
    ST_Buffer(ST_GeomFromText(ST_AsText(geog)), 500.0 / 111000) AS zone_geom
FROM dengue_cases

UNION ALL

SELECT
    case_id,
    severity,
    infection_date,
    'ORANGE' AS risk_tier,
    1000     AS radius_meters,
    ST_Buffer(ST_GeomFromText(ST_AsText(geog)), 1000.0 / 111000) AS zone_geom
FROM dengue_cases

UNION ALL

SELECT
    case_id,
    severity,
    infection_date,
    'YELLOW' AS risk_tier,
    2000     AS radius_meters,
    ST_Buffer(ST_GeomFromText(ST_AsText(geog)), 2000.0 / 111000) AS zone_geom
FROM dengue_cases
ORDER BY case_id, radius_meters;


-- ############################################################################
-- PART 2: WHICH SCHOOLS ARE IN THE DANGER ZONE?
-- ############################################################################

-- DDC sends inspectors to schools inside risk buffers to check for
-- Aedes aegypti breeding containers (water jars, tires, flower pots).
-- We use ST_Distance on GEOGRAPHY for accurate meter-based distances.

SELECT
    s.name          AS school_name,
    s.district,
    d.case_id,
    d.severity,
    d.infection_date,
    ROUND(ST_Distance(s.geog, d.geog), 0) AS distance_meters,
    CASE
        WHEN ST_Distance(s.geog, d.geog) <=  500 THEN 'RED (0-500m)'
        WHEN ST_Distance(s.geog, d.geog) <= 1000 THEN 'ORANGE (500m-1km)'
        WHEN ST_Distance(s.geog, d.geog) <= 2000 THEN 'YELLOW (1-2km)'
    END AS risk_tier
FROM schools s
JOIN dengue_cases d
    ON ST_Distance(s.geog, d.geog) <= 2000  -- within 2km of any case
ORDER BY s.name, distance_meters;

-- INSIGHT: Schools that appear multiple times are near MULTIPLE cases.
-- These are highest priority for DDC inspection teams.

-- Aggregate: how many cases threaten each school?
SELECT
    s.name          AS school_name,
    s.district,
    COUNT(*)        AS threatening_cases,
    SUM(CASE WHEN d.severity IN ('DHF','DSS') THEN 1 ELSE 0 END) AS severe_nearby,
    MIN(ROUND(ST_Distance(s.geog, d.geog), 0)) AS nearest_case_meters
FROM schools s
JOIN dengue_cases d
    ON ST_Distance(s.geog, d.geog) <= 2000
GROUP BY s.name, s.district
ORDER BY threatening_cases DESC;


-- ############################################################################
-- PART 3: MERGING OVERLAPPING BUFFERS WITH ST_Union
-- ############################################################################

-- Problem: When cases are clustered, their 500m buffers overlap.
-- Fogging teams don't need to spray the same area twice.
-- ST_Union merges overlapping polygons into a single shape.

-- Merge all RED-tier (500m) buffers into one fogging zone per province:
SELECT
    pb.province_name,
    COUNT(d.case_id) AS total_cases,
    ST_AsText(
        ST_Union(ST_Buffer(ST_GeomFromText(ST_AsText(d.geog)), 500.0 / 111000))
    ) AS merged_red_zone_wkt
FROM dengue_cases d
JOIN province_boundaries pb
    ON ST_Intersects(ST_GeomFromText(ST_AsText(pb.boundary)),
                     ST_GeomFromText(ST_AsText(d.geog)))
GROUP BY pb.province_name;


-- ############################################################################
-- PART 4: CALCULATING TOTAL AREA NEEDING TREATMENT
-- ############################################################################

-- ST_Area on the merged GEOMETRY buffers gives us square degrees.
-- We convert to approximate square kilometers using the degree-to-km ratio.
-- (1 degree ≈ 111 km, so 1 sq degree ≈ 111 * 108 ≈ 11,988 sq km at 14°N)

SELECT
    pb.province_name,
    COUNT(d.case_id) AS total_cases,
    ROUND(ST_Area(
        ST_Union(ST_Buffer(ST_GeomFromText(ST_AsText(d.geog)), 500.0 / 111000))
    ) * 11988, 2)  AS red_zone_sq_km,
    ROUND(ST_Area(
        ST_Union(ST_Buffer(ST_GeomFromText(ST_AsText(d.geog)), 1000.0 / 111000))
    ) * 11988, 2)  AS orange_zone_sq_km,
    ROUND(ST_Area(
        ST_Union(ST_Buffer(ST_GeomFromText(ST_AsText(d.geog)), 2000.0 / 111000))
    ) * 11988, 2)  AS yellow_zone_sq_km
FROM dengue_cases d
JOIN province_boundaries pb
    ON ST_Intersects(ST_GeomFromText(ST_AsText(pb.boundary)),
                     ST_GeomFromText(ST_AsText(d.geog)))
GROUP BY pb.province_name
ORDER BY total_cases DESC;

-- OPERATIONAL INSIGHT: Compare merged vs. naive area to see overlap savings.

SELECT
    pb.province_name,
    ROUND(SUM(ST_Area(ST_Buffer(ST_GeomFromText(ST_AsText(d.geog)), 500.0 / 111000))) * 11988, 3) AS naive_sum_sq_km,
    ROUND(ST_Area(ST_Union(ST_Buffer(ST_GeomFromText(ST_AsText(d.geog)), 500.0 / 111000))) * 11988, 3) AS merged_sq_km,
    ROUND(
        (1 - ST_Area(ST_Union(ST_Buffer(ST_GeomFromText(ST_AsText(d.geog)), 500.0 / 111000)))
             / NULLIFZERO(SUM(ST_Area(ST_Buffer(ST_GeomFromText(ST_AsText(d.geog)), 500.0 / 111000))))) * 100,
        1
    ) AS overlap_savings_pct
FROM dengue_cases d
JOIN province_boundaries pb
    ON ST_Intersects(ST_GeomFromText(ST_AsText(pb.boundary)),
                     ST_GeomFromText(ST_AsText(d.geog)))
GROUP BY pb.province_name
ORDER BY overlap_savings_pct DESC;


-- ############################################################################
-- PART 5: STORE RESULTS FOR LATER MODULES
-- ############################################################################

-- Save the risk zone analysis so Module 3 (hexbin) and the visualization
-- notebook can reference it. This table persists -- we do NOT drop it.

DROP TABLE IF EXISTS dengue_risk_zones;

CREATE TABLE dengue_risk_zones AS
SELECT
    pb.province_name,
    tier.risk_tier,
    tier.radius_meters,
    COUNT(DISTINCT d.case_id) AS case_count,
    ST_Union(
        ST_Buffer(ST_GeomFromText(ST_AsText(d.geog)), tier.radius_meters / 111000.0)
    ) AS zone_geom,
    ROUND(ST_Area(
        ST_Union(ST_Buffer(ST_GeomFromText(ST_AsText(d.geog)), tier.radius_meters / 111000.0))
    ) * 11988, 3) AS area_sq_km
FROM dengue_cases d
JOIN province_boundaries pb
    ON ST_Intersects(ST_GeomFromText(ST_AsText(pb.boundary)),
                     ST_GeomFromText(ST_AsText(d.geog)))
CROSS JOIN (
    SELECT 'RED'    AS risk_tier, 500  AS radius_meters
    UNION ALL
    SELECT 'ORANGE',              1000
    UNION ALL
    SELECT 'YELLOW',              2000
) tier
GROUP BY pb.province_name, tier.risk_tier, tier.radius_meters;

COMMIT;

-- Verify stored results:
SELECT
    province_name,
    risk_tier,
    case_count,
    area_sq_km
FROM dengue_risk_zones
ORDER BY province_name, radius_meters;


-- ############################################################################
-- KEY VERTICA FUNCTIONS INTRODUCED IN THIS MODULE
-- ############################################################################

-- +----------------------------------+------------------------------------------+
-- | Function                         | What it does                             |
-- +----------------------------------+------------------------------------------+
-- | ST_Buffer(geom, degrees)         | Creates a circle polygon at given radius |
-- | ST_Intersects(a, b)              | TRUE if two spatial objects overlap      |
-- | ST_Union(geom) [aggregate]       | Merges multiple polygons, removes overlap|
-- | ST_Area(geom)                    | Area in square degrees (GEOMETRY)        |
-- | ST_Distance(geog, geog) <= m     | Proximity check in meters (GEOGRAPHY)   |
-- | ST_GeomFromText(ST_AsText(geog)) | Convert GEOGRAPHY to GEOMETRY for buffer |
-- +----------------------------------+------------------------------------------+
--
-- EXERCISE: Create a priority ranking for fogging deployment
-- ============================================================================
-- Calculate a "risk score" per school:
--   - 3 points for each RED-tier case nearby (< 500m)
--   - 2 points for each ORANGE-tier case (500m - 1km)
--   - 1 point for each YELLOW-tier case (1km - 2km)
--   - Double points if case severity is DHF or DSS
-- Rank schools by risk score. Which 3 schools get fogging first?
-- ============================================================================
