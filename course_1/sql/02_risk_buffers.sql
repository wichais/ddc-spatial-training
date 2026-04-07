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
-- All tables use GEOMETRY with SRID 4326.
-- Buffer distances in degrees: meters / 111000.
-- ST_Buffer, ST_Intersects, ST_Union all work directly on GEOMETRY.
--
-- Prerequisites: Run 00_setup_data.sql first.
-- This module creates: dengue_risk_zones (persists for later modules).
-- ============================================================================

SET SEARCH_PATH TO ddc_training, public, v_catalog, v_monitor;


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
        ST_Buffer(geom, 500.0 / 111000)
    ) AS buffer_500m_wkt
FROM dengue_cases
WHERE case_id = 1;

-- That WKT polygon is a circle with ~500m radius around case #1.


-- Now create all three tiers for every case:

SELECT
    case_id, severity, infection_date,
    'RED' AS risk_tier, 500 AS radius_meters,
    ST_Buffer(geom, 500.0 / 111000) AS zone_geom
FROM dengue_cases
UNION ALL
SELECT
    case_id, severity, infection_date,
    'ORANGE', 1000,
    ST_Buffer(geom, 1000.0 / 111000)
FROM dengue_cases
UNION ALL
SELECT
    case_id, severity, infection_date,
    'YELLOW', 2000,
    ST_Buffer(geom, 2000.0 / 111000)
FROM dengue_cases
ORDER BY case_id, radius_meters;


-- ############################################################################
-- PART 2: WHICH SCHOOLS ARE IN THE DANGER ZONE?
-- ############################################################################

-- Distance in degrees, convert to meters for display.

SELECT
    s.name          AS school_name,
    s.district,
    d.case_id,
    d.severity,
    ROUND(ST_Distance(s.geom, d.geom) * 111000, 0) AS distance_meters,
    CASE
        WHEN ST_Distance(s.geom, d.geom) <=  500.0 / 111000 THEN 'RED (0-500m)'
        WHEN ST_Distance(s.geom, d.geom) <= 1000.0 / 111000 THEN 'ORANGE (500m-1km)'
        WHEN ST_Distance(s.geom, d.geom) <= 2000.0 / 111000 THEN 'YELLOW (1-2km)'
    END AS risk_tier
FROM schools s
JOIN dengue_cases d
    ON ST_Distance(s.geom, d.geom) <= 2000.0 / 111000
ORDER BY s.name, distance_meters;

-- Aggregate: how many cases threaten each school?
SELECT
    s.name          AS school_name,
    s.district,
    COUNT(*)        AS threatening_cases,
    SUM(CASE WHEN d.severity IN ('DHF','DSS') THEN 1 ELSE 0 END) AS severe_nearby,
    ROUND(MIN(ST_Distance(s.geom, d.geom)) * 111000, 0) AS nearest_case_meters
FROM schools s
JOIN dengue_cases d
    ON ST_Distance(s.geom, d.geom) <= 2000.0 / 111000
GROUP BY s.name, s.district
ORDER BY threatening_cases DESC;


-- ############################################################################
-- PART 3: MERGING OVERLAPPING BUFFERS WITH ST_Union
-- ############################################################################

-- When cases cluster, their buffers overlap. ST_Union merges them.

SELECT
    pb.province_name,
    COUNT(d.case_id) AS total_cases,
    ST_AsText(
        ST_Union(ST_Buffer(d.geom, 500.0 / 111000))
    ) AS merged_red_zone_wkt
FROM dengue_cases d
JOIN province_boundaries pb
    ON ST_Intersects(pb.boundary, d.geom)
GROUP BY pb.province_name;


-- ############################################################################
-- PART 4: CALCULATING TOTAL AREA NEEDING TREATMENT
-- ############################################################################

-- ST_Area returns square degrees.
-- 1 sq degree ~ 11,988 sq km at Thai latitude.

SELECT
    pb.province_name,
    COUNT(d.case_id) AS total_cases,
    ROUND(ST_Area(ST_Union(ST_Buffer(d.geom, 500.0  / 111000))) * 11988, 2) AS red_zone_sq_km,
    ROUND(ST_Area(ST_Union(ST_Buffer(d.geom, 1000.0 / 111000))) * 11988, 2) AS orange_zone_sq_km,
    ROUND(ST_Area(ST_Union(ST_Buffer(d.geom, 2000.0 / 111000))) * 11988, 2) AS yellow_zone_sq_km
FROM dengue_cases d
JOIN province_boundaries pb
    ON ST_Intersects(pb.boundary, d.geom)
GROUP BY pb.province_name
ORDER BY total_cases DESC;

-- Overlap savings:
SELECT
    pb.province_name,
    ROUND(SUM(ST_Area(ST_Buffer(d.geom, 500.0 / 111000))) * 11988, 3) AS naive_sum_sq_km,
    ROUND(ST_Area(ST_Union(ST_Buffer(d.geom, 500.0 / 111000))) * 11988, 3) AS merged_sq_km,
    ROUND(
        (1 - ST_Area(ST_Union(ST_Buffer(d.geom, 500.0 / 111000)))
             / NULLIFZERO(SUM(ST_Area(ST_Buffer(d.geom, 500.0 / 111000))))) * 100,
        1
    ) AS overlap_savings_pct
FROM dengue_cases d
JOIN province_boundaries pb
    ON ST_Intersects(pb.boundary, d.geom)
GROUP BY pb.province_name
ORDER BY overlap_savings_pct DESC;


-- ############################################################################
-- PART 5: STORE RESULTS FOR LATER MODULES
-- ############################################################################

DROP TABLE IF EXISTS dengue_risk_zones;

CREATE TABLE dengue_risk_zones AS
SELECT
    pb.province_name,
    tier.risk_tier,
    tier.radius_meters,
    COUNT(DISTINCT d.case_id) AS case_count,
    ST_Union(ST_Buffer(d.geom, tier.radius_meters / 111000.0)) AS zone_geom,
    ROUND(ST_Area(
        ST_Union(ST_Buffer(d.geom, tier.radius_meters / 111000.0))
    ) * 11988, 3) AS area_sq_km
FROM dengue_cases d
JOIN province_boundaries pb
    ON ST_Intersects(pb.boundary, d.geom)
CROSS JOIN (
    SELECT 'RED'    AS risk_tier, 500  AS radius_meters
    UNION ALL SELECT 'ORANGE',   1000
    UNION ALL SELECT 'YELLOW',   2000
) tier
GROUP BY pb.province_name, tier.risk_tier, tier.radius_meters;

COMMIT;

SELECT province_name, risk_tier, case_count, area_sq_km
FROM dengue_risk_zones
ORDER BY province_name, radius_meters;


-- ############################################################################
-- KEY VERTICA FUNCTIONS INTRODUCED IN THIS MODULE
-- ############################################################################

-- +----------------------------------+------------------------------------------+
-- | Function                         | What it does                             |
-- +----------------------------------+------------------------------------------+
-- | ST_Buffer(geom, degrees)         | Creates a circle polygon at given radius |
-- | ST_Intersects(a, b)              | TRUE if two geometries overlap           |
-- | ST_Union(geom) [aggregate]       | Merges multiple polygons, removes overlap|
-- | ST_Area(geom)                    | Area in square degrees                   |
-- | ST_Distance(a, b) * 111000      | Approximate distance in meters           |
-- +----------------------------------+------------------------------------------+
-- ============================================================================
