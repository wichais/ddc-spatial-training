-- ============================================================================
-- Course 1: Practical Spatial Analytics for Disease Surveillance
-- Setup: Shared Dataset for All Modules
-- Database: Vertica
-- ============================================================================
--
-- This script creates ALL base tables used throughout Course 1.
-- Run this ONCE before starting any module. Tables are never dropped --
-- each module builds on the previous one, just like real surveillance work.
--
-- Dataset covers three key provinces for DDC dengue surveillance:
--   - Bangkok (urban, high density)
--   - Chiang Mai (urban + peri-urban)
--   - Chiang Rai (border province, rural)
--
-- All spatial columns use GEOMETRY with SRID 4326 (WGS84 lon/lat).
-- Distance unit is DEGREES. At Thai latitude (~14N):
--   1 degree latitude  ~ 111,000 meters
--   1 degree longitude ~ 108,000 meters
--   Approximate conversion: degrees * 111000 = meters
--
-- NOTE: Vertica does not support multi-row INSERT for spatial types.
-- Each row is inserted individually.
-- ============================================================================

-- Use dedicated schema so training data stays separate from VMart
CREATE SCHEMA IF NOT EXISTS ddc_training;
SET SEARCH_PATH TO ddc_training, public, v_catalog, v_monitor;

-- ============================================================================
-- TABLE 1: hospitals
-- Key healthcare facilities where dengue patients are treated.
-- Mix of large Bangkok hospitals and regional facilities.
-- ============================================================================

DROP TABLE IF EXISTS hospitals;
CREATE TABLE hospitals (
    id            INT PRIMARY KEY,
    name          VARCHAR(200),
    province      VARCHAR(100),
    district      VARCHAR(100),
    geom          GEOMETRY
);

-- Bangkok: Major hospitals in different districts
INSERT INTO hospitals VALUES ( 1, 'Siriraj Hospital',                   'Bangkok', 'Bangkok Noi',        ST_GeomFromText('POINT(100.4856 13.7590)', 4326));
INSERT INTO hospitals VALUES ( 2, 'Ramathibodi Hospital',               'Bangkok', 'Ratchathewi',        ST_GeomFromText('POINT(100.5385 13.7649)', 4326));
INSERT INTO hospitals VALUES ( 3, 'King Chulalongkorn Memorial',        'Bangkok', 'Pathum Wan',         ST_GeomFromText('POINT(100.5347 13.7312)', 4326));
INSERT INTO hospitals VALUES ( 4, 'Bamrasnaradura Infectious Diseases', 'Bangkok', 'Mueang Nonthaburi',  ST_GeomFromText('POINT(100.5230 13.8480)', 4326));
INSERT INTO hospitals VALUES ( 5, 'Queen Sirikit National Institute',   'Bangkok', 'Ratchathewi',        ST_GeomFromText('POINT(100.5340 13.7680)', 4326));
INSERT INTO hospitals VALUES ( 6, 'Nopparat Rajathanee Hospital',       'Bangkok', 'Khannayao',          ST_GeomFromText('POINT(100.6780 13.7870)', 4326));
INSERT INTO hospitals VALUES ( 7, 'Charoen Krung Pracharak Hospital',   'Bangkok', 'Bang Kho Laem',      ST_GeomFromText('POINT(100.5080 13.6930)', 4326));
INSERT INTO hospitals VALUES ( 8, 'Taksin Hospital',                    'Bangkok', 'Thon Buri',          ST_GeomFromText('POINT(100.4870 13.7190)', 4326));
-- Chiang Mai: Regional and city hospitals
INSERT INTO hospitals VALUES ( 9, 'Maharaj Nakorn Chiang Mai',          'Chiang Mai', 'Mueang Chiang Mai', ST_GeomFromText('POINT(98.9720 18.7880)', 4326));
INSERT INTO hospitals VALUES (10, 'Chiang Mai Ram Hospital',            'Chiang Mai', 'Mueang Chiang Mai', ST_GeomFromText('POINT(98.9870 18.7920)', 4326));
INSERT INTO hospitals VALUES (11, 'Nakornping Hospital',                'Chiang Mai', 'Mae Rim',           ST_GeomFromText('POINT(98.9580 18.8900)', 4326));
INSERT INTO hospitals VALUES (12, 'San Sai Hospital',                   'Chiang Mai', 'San Sai',           ST_GeomFromText('POINT(99.0320 18.8370)', 4326));
-- Chiang Rai: Northern border province
INSERT INTO hospitals VALUES (13, 'Chiang Rai Prachanukroh Hospital',   'Chiang Rai', 'Mueang Chiang Rai', ST_GeomFromText('POINT(99.8310 19.9100)', 4326));
INSERT INTO hospitals VALUES (14, 'Overbrook Hospital',                 'Chiang Rai', 'Mueang Chiang Rai', ST_GeomFromText('POINT(99.8280 19.9050)', 4326));
INSERT INTO hospitals VALUES (15, 'Mae Sai Hospital',                   'Chiang Rai', 'Mae Sai',           ST_GeomFromText('POINT(99.8760 20.4280)', 4326));


-- ============================================================================
-- TABLE 2: dengue_cases
-- Simulated dengue fever notifications for 2024 season (June-October).
-- Cases are CLUSTERED (as real dengue outbreaks are) around:
--   - Bangkok: Khlong Toei, Din Daeng, Huai Khwang (dense slum areas)
--   - Chiang Mai: old city and university area
--   - Chiang Rai: border area near Mae Sai
-- ============================================================================

DROP TABLE IF EXISTS dengue_cases;
CREATE TABLE dengue_cases (
    case_id        INT PRIMARY KEY,
    patient_age    INT,
    gender         VARCHAR(10),
    infection_date DATE,
    severity       VARCHAR(20),    -- 'DF' (dengue fever), 'DHF' (hemorrhagic), 'DSS' (shock)
    geom           GEOMETRY
);

-- Cluster 1: Bangkok - Khlong Toei / Sukhumvit area (dense urban, ~12 cases)
INSERT INTO dengue_cases VALUES ( 1,  8, 'F', '2024-06-15', 'DF',  ST_GeomFromText('POINT(100.5530 13.7230)', 4326));
INSERT INTO dengue_cases VALUES ( 2, 25, 'M', '2024-06-18', 'DF',  ST_GeomFromText('POINT(100.5560 13.7210)', 4326));
INSERT INTO dengue_cases VALUES ( 3, 12, 'F', '2024-06-22', 'DHF', ST_GeomFromText('POINT(100.5510 13.7250)', 4326));
INSERT INTO dengue_cases VALUES ( 4, 45, 'M', '2024-07-01', 'DF',  ST_GeomFromText('POINT(100.5580 13.7200)', 4326));
INSERT INTO dengue_cases VALUES ( 5,  6, 'M', '2024-07-05', 'DSS', ST_GeomFromText('POINT(100.5540 13.7240)', 4326));
INSERT INTO dengue_cases VALUES ( 6, 33, 'F', '2024-07-08', 'DF',  ST_GeomFromText('POINT(100.5520 13.7220)', 4326));
INSERT INTO dengue_cases VALUES ( 7, 18, 'M', '2024-07-12', 'DHF', ST_GeomFromText('POINT(100.5570 13.7190)', 4326));
INSERT INTO dengue_cases VALUES ( 8,  9, 'F', '2024-07-15', 'DF',  ST_GeomFromText('POINT(100.5500 13.7260)', 4326));
INSERT INTO dengue_cases VALUES ( 9, 55, 'M', '2024-07-20', 'DF',  ST_GeomFromText('POINT(100.5550 13.7235)', 4326));
INSERT INTO dengue_cases VALUES (10, 14, 'F', '2024-08-01', 'DHF', ST_GeomFromText('POINT(100.5525 13.7215)', 4326));
INSERT INTO dengue_cases VALUES (11, 28, 'M', '2024-08-10', 'DF',  ST_GeomFromText('POINT(100.5590 13.7180)', 4326));
INSERT INTO dengue_cases VALUES (12,  7, 'F', '2024-08-15', 'DF',  ST_GeomFromText('POINT(100.5535 13.7245)', 4326));

-- Cluster 2: Bangkok - Din Daeng / Huai Khwang (another hotspot, ~8 cases)
INSERT INTO dengue_cases VALUES (13, 22, 'M', '2024-07-10', 'DF',  ST_GeomFromText('POINT(100.5580 13.7640)', 4326));
INSERT INTO dengue_cases VALUES (14, 10, 'F', '2024-07-15', 'DHF', ST_GeomFromText('POINT(100.5610 13.7620)', 4326));
INSERT INTO dengue_cases VALUES (15, 38, 'M', '2024-07-22', 'DF',  ST_GeomFromText('POINT(100.5570 13.7660)', 4326));
INSERT INTO dengue_cases VALUES (16,  5, 'F', '2024-08-01', 'DSS', ST_GeomFromText('POINT(100.5600 13.7650)', 4326));
INSERT INTO dengue_cases VALUES (17, 42, 'M', '2024-08-08', 'DF',  ST_GeomFromText('POINT(100.5590 13.7630)', 4326));
INSERT INTO dengue_cases VALUES (18, 15, 'F', '2024-08-12', 'DF',  ST_GeomFromText('POINT(100.5620 13.7610)', 4326));
INSERT INTO dengue_cases VALUES (19, 31, 'M', '2024-08-20', 'DHF', ST_GeomFromText('POINT(100.5575 13.7645)', 4326));
INSERT INTO dengue_cases VALUES (20, 19, 'F', '2024-09-01', 'DF',  ST_GeomFromText('POINT(100.5605 13.7635)', 4326));

-- Cluster 3: Chiang Mai - Old city and university area (~6 cases)
INSERT INTO dengue_cases VALUES (21, 20, 'M', '2024-07-05', 'DF',  ST_GeomFromText('POINT(98.9820 18.7870)', 4326));
INSERT INTO dengue_cases VALUES (22, 11, 'F', '2024-07-12', 'DHF', ST_GeomFromText('POINT(98.9780 18.7900)', 4326));
INSERT INTO dengue_cases VALUES (23, 35, 'M', '2024-07-25', 'DF',  ST_GeomFromText('POINT(98.9850 18.7850)', 4326));
INSERT INTO dengue_cases VALUES (24,  8, 'F', '2024-08-05', 'DF',  ST_GeomFromText('POINT(98.9800 18.7880)', 4326));
INSERT INTO dengue_cases VALUES (25, 48, 'M', '2024-08-18', 'DSS', ST_GeomFromText('POINT(98.9830 18.7860)', 4326));
INSERT INTO dengue_cases VALUES (26, 16, 'F', '2024-09-02', 'DF',  ST_GeomFromText('POINT(98.9810 18.7890)', 4326));

-- Cluster 4: Chiang Rai - Mae Sai border area (~4 cases)
INSERT INTO dengue_cases VALUES (27, 30, 'M', '2024-08-01', 'DF',  ST_GeomFromText('POINT(99.8800 20.4300)', 4326));
INSERT INTO dengue_cases VALUES (28, 13, 'F', '2024-08-15', 'DHF', ST_GeomFromText('POINT(99.8780 20.4320)', 4326));
INSERT INTO dengue_cases VALUES (29, 52, 'M', '2024-09-01', 'DF',  ST_GeomFromText('POINT(99.8820 20.4280)', 4326));
INSERT INTO dengue_cases VALUES (30,  9, 'F', '2024-09-10', 'DF',  ST_GeomFromText('POINT(99.8790 20.4310)', 4326));


-- ============================================================================
-- TABLE 3: schools
-- Primary and secondary schools in Bangkok districts where dengue clusters
-- are located. DDC prioritizes schools for Aedes mosquito inspections.
-- ============================================================================

DROP TABLE IF EXISTS schools;
CREATE TABLE schools (
    id       INT PRIMARY KEY,
    name     VARCHAR(200),
    district VARCHAR(100),
    geom     GEOMETRY
);

-- Schools near Khlong Toei cluster
INSERT INTO schools VALUES ( 1, 'Wat Khlong Toei School',           'Khlong Toei',   ST_GeomFromText('POINT(100.5545 13.7225)', 4326));
INSERT INTO schools VALUES ( 2, 'Khlong Toei Wittaya School',       'Khlong Toei',   ST_GeomFromText('POINT(100.5510 13.7195)', 4326));
INSERT INTO schools VALUES ( 3, 'Sukhumvit Pattana School',         'Watthana',      ST_GeomFromText('POINT(100.5620 13.7270)', 4326));
-- Schools near Din Daeng cluster
INSERT INTO schools VALUES ( 4, 'Din Daeng Wittaya School',         'Din Daeng',     ST_GeomFromText('POINT(100.5590 13.7670)', 4326));
INSERT INTO schools VALUES ( 5, 'Ratchadaphisek Wittayalai School', 'Din Daeng',     ST_GeomFromText('POINT(100.5640 13.7600)', 4326));
INSERT INTO schools VALUES ( 6, 'Huai Khwang School',               'Huai Khwang',   ST_GeomFromText('POINT(100.5730 13.7650)', 4326));
-- Schools in other Bangkok areas (further from clusters)
INSERT INTO schools VALUES ( 7, 'Satri Witthaya School',            'Dusit',         ST_GeomFromText('POINT(100.5130 13.7720)', 4326));
INSERT INTO schools VALUES ( 8, 'Benchama Rajalai School',          'Phra Nakhon',   ST_GeomFromText('POINT(100.5010 13.7530)', 4326));
INSERT INTO schools VALUES ( 9, 'Suankularb Wittayalai School',     'Phra Nakhon',   ST_GeomFromText('POINT(100.4960 13.7440)', 4326));
INSERT INTO schools VALUES (10, 'Triam Udom Suksa School',          'Pathum Wan',    ST_GeomFromText('POINT(100.5310 13.7370)', 4326));


-- ============================================================================
-- TABLE 4: province_boundaries
-- Simplified bounding-box polygons for the three focus provinces.
-- In production, DDC would load actual shapefile boundaries from GADM/DOPA.
-- These approximations are sufficient for training exercises.
-- ============================================================================

DROP TABLE IF EXISTS province_boundaries;
CREATE TABLE province_boundaries (
    province_code VARCHAR(10) PRIMARY KEY,
    province_name VARCHAR(100),
    boundary      GEOMETRY
);

-- Bangkok: roughly bounded by these coordinates
INSERT INTO province_boundaries VALUES ('10', 'Bangkok',
    ST_GeomFromText('POLYGON((100.3270 13.5800, 100.9380 13.5800, 100.9380 13.9550, 100.3270 13.9550, 100.3270 13.5800))', 4326));

-- Chiang Mai: larger province in the north
INSERT INTO province_boundaries VALUES ('50', 'Chiang Mai',
    ST_GeomFromText('POLYGON((98.0600 18.1000, 99.5400 18.1000, 99.5400 19.7600, 98.0600 19.7600, 98.0600 18.1000))', 4326));

-- Chiang Rai: northernmost province
INSERT INTO province_boundaries VALUES ('57', 'Chiang Rai',
    ST_GeomFromText('POLYGON((99.2000 19.5000, 100.6000 19.5000, 100.6000 20.5000, 99.2000 20.5000, 99.2000 19.5000))', 4326));


-- Commit all inserts (Vertica does not auto-commit DML by default)
COMMIT;

-- ============================================================================
-- Verify setup: quick row counts
-- ============================================================================
SELECT 'hospitals'          AS table_name, COUNT(*) AS row_count FROM hospitals
UNION ALL
SELECT 'dengue_cases',      COUNT(*) FROM dengue_cases
UNION ALL
SELECT 'schools',           COUNT(*) FROM schools
UNION ALL
SELECT 'province_boundaries', COUNT(*) FROM province_boundaries
ORDER BY table_name;

-- ============================================================================
-- Setup complete. You should see:
--   hospitals:           15
--   dengue_cases:        30
--   schools:             10
--   province_boundaries:  3
--
-- These tables persist across all modules. Do NOT drop them.
-- ============================================================================
