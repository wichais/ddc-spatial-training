-- ============================================================================
-- Workshop: Load Bulk Synthetic Data for Performance Benchmark Demo
-- ============================================================================
-- CONNECTION:    vsql -h <vertica_host> -p 5433 -U dbadmin -d ddc_training
-- PREREQUISITE:  Run course_2/sql/01_dimensional_model.sql first.
-- INPUT FILE:    ddc_patients.csv from data_generation/generate_ddc_data.py
--
-- PURPOSE: The projection demo (02_projection_performance.sql) needs millions
-- of rows to show meaningful speedup (47s -> 0.8s). This script loads the CSV
-- into staging, then transforms and inserts into the star schema.
--
-- USAGE:
--   1. python data_generation/generate_ddc_data.py --rows 5000000
--   2. vsql -h <host> -p 5433 -U dbadmin -d ddc_training \
--        -f workshop/load_bulk_data.sql
-- ============================================================================

-- STEP 1: Create staging table matching CSV columns exactly
\echo '>>> STEP 1: Creating staging table...'

DROP TABLE IF EXISTS stg_ddc_patients CASCADE;

CREATE TABLE stg_ddc_patients (
    patient_id        VARCHAR(40)   NOT NULL,   -- UUID from generator
    infection_date    DATE          NOT NULL,
    disease_code      VARCHAR(20)   NOT NULL,   -- 'Dengue', 'COVID-19', etc.
    severity_score    INT           NOT NULL,
    outcome           VARCHAR(20)   NOT NULL,   -- 'Recovered', 'Hospitalized', 'Deceased'
    age               INT           NOT NULL,
    gender            VARCHAR(10)   NOT NULL,   -- 'M', 'F', 'Other'
    latitude          NUMERIC(9,6),
    longitude         NUMERIC(9,6),
    province_code     VARCHAR(4),
    subdistrict_code  VARCHAR(10)
);

-- STEP 2: COPY the CSV using Vertica's client-side loader
-- COPY LOCAL reads from the vsql client machine (not the server).
-- fcsvparser() auto-handles quoting, headers, and delimiters.
\echo '>>> STEP 2: Loading CSV into staging (may take a few minutes)...'

COPY stg_ddc_patients
FROM LOCAL 'ddc_patients.csv'
PARSER fcsvparser()
ABORT ON ERROR
DIRECT;

\echo '>>> Staging row count:'
SELECT COUNT(*) AS staging_row_count FROM stg_ddc_patients;

-- STEP 3: Disease code mapping (generator names -> dim_disease short codes)
-- Generator uses 'Dengue','COVID-19',... but dim_disease uses 'DHF','COV19',...
\echo '>>> STEP 3: Creating disease code mapping...'

DROP TABLE IF EXISTS tmp_disease_map CASCADE;
CREATE LOCAL TEMPORARY TABLE tmp_disease_map (
    csv_disease_code   VARCHAR(20),
    dim_disease_code   VARCHAR(10)
) ON COMMIT PRESERVE ROWS;

INSERT INTO tmp_disease_map VALUES ('Dengue',        'DHF');
INSERT INTO tmp_disease_map VALUES ('COVID-19',      'COV19');
INSERT INTO tmp_disease_map VALUES ('TB',            'TB');
INSERT INTO tmp_disease_map VALUES ('Malaria',       'MAL');
INSERT INTO tmp_disease_map VALUES ('Leptospirosis', 'LEP');

-- STEP 4: Ensure a fallback "Unknown" location for unmatched records
-- Generator has ~20 hotspot regions but dim_location only has 5 subdistricts.
-- Most rows won't match, so we add a catch-all to preserve FK integrity.
\echo '>>> STEP 4: Ensuring default Unknown location...'

INSERT INTO dim_location (subdistrict_code, subdistrict_name_th,
                          district_code, district_name_th,
                          province_code, province_name_th,
                          start_date, end_date, is_current)
SELECT '000000', 'ไม่ทราบ', '0000', 'ไม่ทราบ', '00', 'ไม่ทราบ',
       '2023-01-01', '9999-12-31', TRUE
WHERE NOT EXISTS (
    SELECT 1 FROM dim_location
    WHERE subdistrict_code = '000000' AND is_current = TRUE
);

-- STEP 5: Clear previous bulk data (makes this script idempotent)
-- Hand-crafted rows from 01_dimensional_model.sql use 'PID-' prefix;
-- only generator rows (UUID format) are deleted.
\echo '>>> STEP 5: Clearing previous bulk-loaded rows...'
DELETE FROM fact_infection WHERE patient_id NOT LIKE 'PID-%';

-- STEP 6: Transform staging -> fact_infection with FK lookups
-- a) date_id = YYYYMMDD integer from infection_date
-- b) disease_sk via mapping table -> dim_disease
-- c) location_sk via province_code match; fallback to Unknown
-- d) Clamp severity 1-10 to 1-5; lowercase outcome; single-char gender
\echo '>>> STEP 6: Inserting into fact_infection (longest step)...'

INSERT /*+ DIRECT */ INTO fact_infection
    (patient_id, infection_date_id, diagnosis_date_id,
     location_sk, disease_sk, severity_score, outcome, age, gender)
SELECT
    s.patient_id,
    TO_NUMBER(TO_CHAR(s.infection_date, 'YYYYMMDD'))   AS infection_date_id,
    TO_NUMBER(TO_CHAR(s.infection_date, 'YYYYMMDD'))   AS diagnosis_date_id,
    COALESCE(loc.location_sk, unk.location_sk)         AS location_sk,
    dis.disease_sk,
    LEAST(GREATEST(s.severity_score, 1), 5)            AS severity_score,
    LOWER(s.outcome)                                   AS outcome,
    s.age,
    CASE WHEN s.gender IN ('M','F') THEN s.gender ELSE 'M' END AS gender
FROM stg_ddc_patients s
JOIN tmp_disease_map dm  ON s.disease_code      = dm.csv_disease_code
JOIN dim_disease     dis ON dm.dim_disease_code  = dis.disease_code
LEFT JOIN dim_location loc ON s.province_code   = loc.province_code
                          AND loc.is_current     = TRUE
LEFT JOIN dim_location unk ON unk.subdistrict_code = '000000'
                          AND unk.is_current       = TRUE;

-- STEP 7: Refresh projections and update optimizer statistics
-- Required after bulk loads so projections are up-to-date and the
-- optimizer has accurate cardinality estimates for fast query plans.
\echo '>>> STEP 7: Refreshing projections and analyzing statistics...'

SELECT REFRESH('dim_date, dim_disease, dim_location, fact_infection');
SELECT ANALYZE_STATISTICS('dim_date');
SELECT ANALYZE_STATISTICS('dim_disease');
SELECT ANALYZE_STATISTICS('dim_location');
SELECT ANALYZE_STATISTICS('fact_infection');

-- STEP 8: Verification -- row counts for all star schema tables
\echo '>>> STEP 8: Verification'

\echo '--- Row counts ---'
SELECT 'dim_date'       AS table_name, COUNT(*) AS rows FROM dim_date
UNION ALL SELECT 'dim_disease',    COUNT(*) FROM dim_disease
UNION ALL SELECT 'dim_location',   COUNT(*) FROM dim_location
UNION ALL SELECT 'fact_infection', COUNT(*) FROM fact_infection;

\echo '--- Fact breakdown by disease ---'
SELECT dis.disease_name_en, COUNT(*) AS cases
FROM fact_infection fi
JOIN dim_disease dis ON fi.disease_sk = dis.disease_sk
GROUP BY dis.disease_name_en ORDER BY cases DESC;

\echo '--- Fact breakdown by location ---'
SELECT loc.province_name_th, COUNT(*) AS cases
FROM fact_infection fi
JOIN dim_location loc ON fi.location_sk = loc.location_sk
GROUP BY loc.province_name_th ORDER BY cases DESC;

-- STEP 9: Clean up staging
DROP TABLE IF EXISTS stg_ddc_patients CASCADE;

\echo ''
\echo '============================================================'
\echo '  BULK LOAD COMPLETE'
\echo '  Run 02_projection_performance.sql to see the speedup.'
\echo '============================================================'
