-- ============================================================================
-- Course 2: Setup — Populate All Tables with Training Data
-- ============================================================================
-- PREREQUISITE: Run 01_dimensional_model.sql first to create tables (DDL).
-- This file only populates data (INSERT/UPDATE).
--
-- Data loaded:
--   dim_date       — 731 days (2023–2024) with Thai month names and holidays
--   dim_disease    — 5 DDC priority diseases with ICD-10 codes
--   dim_location   — 6 subdistricts with SCD Type 2 columns and GEOMETRY polygons
--   fact_infection — 13 sample infection events across locations and diseases
-- ============================================================================

SET SEARCH_PATH TO ddc_training, public, v_catalog, v_monitor;

-- ============================================================================
-- dim_date — 731 days (2023–2024)
-- ============================================================================

INSERT INTO dim_date
SELECT
    TO_NUMBER(TO_CHAR(d.day_date, 'YYYYMMDD'))          AS date_id,
    d.day_date                                           AS full_date,
    DAYOFWEEK(d.day_date)                                AS day_of_week,
    TRIM(TO_CHAR(d.day_date, 'Day'))                      AS day_name_en,
    WEEK_ISO(d.day_date)                                 AS week_of_year,
    MONTH(d.day_date)                                    AS month_num,
    CASE MONTH(d.day_date)
        WHEN  1 THEN 'มกราคม'      WHEN  2 THEN 'กุมภาพันธ์'
        WHEN  3 THEN 'มีนาคม'      WHEN  4 THEN 'เมษายน'
        WHEN  5 THEN 'พฤษภาคม'     WHEN  6 THEN 'มิถุนายน'
        WHEN  7 THEN 'กรกฎาคม'     WHEN  8 THEN 'สิงหาคม'
        WHEN  9 THEN 'กันยายน'     WHEN 10 THEN 'ตุลาคม'
        WHEN 11 THEN 'พฤศจิกายน'   WHEN 12 THEN 'ธันวาคม'
    END                                                  AS month_name_th,
    QUARTER(d.day_date)                                  AS quarter_num,
    YEAR(d.day_date)                                     AS year_num,
    CASE WHEN DAYOFWEEK(d.day_date) IN (1, 7) THEN TRUE ELSE FALSE END AS is_weekend,
    NULL                                                 AS thai_holiday_name
FROM (
    SELECT dt::DATE AS day_date
    FROM (
        SELECT '2023-01-01'::TIMESTAMP + INTERVAL '1 day' * row_number() OVER () - INTERVAL '1 day' AS dt
        FROM (
            SELECT 1
            FROM (SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5
                  UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10) a
            CROSS JOIN
                 (SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5
                  UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10) b
            CROSS JOIN
                 (SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5
                  UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8) c
        ) nums
    ) numbered
    WHERE dt::DATE <= '2024-12-31'::DATE
) d;

-- Mark key Thai holidays
UPDATE dim_date SET thai_holiday_name = 'วันขึ้นปีใหม่'         WHERE full_date IN ('2023-01-01','2024-01-01');
UPDATE dim_date SET thai_holiday_name = 'วันมาฆบูชา'           WHERE full_date IN ('2023-03-06','2024-02-24');
UPDATE dim_date SET thai_holiday_name = 'วันสงกรานต์'          WHERE full_date IN ('2023-04-13','2023-04-14','2023-04-15',
                                                                                    '2024-04-13','2024-04-14','2024-04-15');
UPDATE dim_date SET thai_holiday_name = 'วันฉัตรมงคล'          WHERE full_date IN ('2023-05-04','2024-05-04');
UPDATE dim_date SET thai_holiday_name = 'วันเฉลิมพระชนมพรรษา ร.10' WHERE full_date IN ('2023-07-28','2024-07-28');

\echo 'dim_date loaded:'
SELECT COUNT(*) AS total_days FROM dim_date;
-- Expected: 731 rows


-- ============================================================================
-- dim_disease — 5 DDC priority diseases
-- ============================================================================

INSERT INTO dim_disease (disease_code, disease_name_th, disease_name_en, pathogen_type, transmission_mode, icd10_code)
VALUES
    ('DHF',  'ไข้เลือดออก',              'Dengue Fever',   'virus',    'vector-borne',   'A90'),
    ('TB',   'วัณโรค',                   'Tuberculosis',   'bacteria', 'airborne',        'A15'),
    ('COV19','โควิด-19',                 'COVID-19',       'virus',    'airborne',        'U07.1'),
    ('MAL',  'มาลาเรีย',                 'Malaria',        'parasite', 'vector-borne',    'B50'),
    ('LEP',  'โรคเลปโตสไปโรซิส',          'Leptospirosis',  'bacteria', 'waterborne',      'A27');

\echo 'dim_disease loaded:'
SELECT * FROM dim_disease ORDER BY disease_sk;


-- ============================================================================
-- dim_location — 5 subdistricts with GEOMETRY polygons
-- ============================================================================
-- NOTE: Vertica does not support multi-row INSERT for spatial types.

-- 1. Bang Khen, Chatuchak, Bangkok (this one will be split in Module 3)
INSERT INTO dim_location (subdistrict_code, subdistrict_name_th, district_code, district_name_th,
                          province_code, province_name_th, latitude, longitude, subdistrict_geom,
                          start_date, end_date, is_current)
VALUES ('100901', 'บางเขน', '1009', 'จตุจักร', '10', 'กรุงเทพมหานคร',
        13.8731, 100.5665,
        ST_GeomFromText('POLYGON((100.55 13.86, 100.58 13.86, 100.58 13.89, 100.55 13.89, 100.55 13.86))'),
        '2023-01-01', '9999-12-31', TRUE);

-- 2. Tha Phra, Khlong San, Bangkok
INSERT INTO dim_location (subdistrict_code, subdistrict_name_th, district_code, district_name_th,
                          province_code, province_name_th, latitude, longitude, subdistrict_geom,
                          start_date, end_date, is_current)
VALUES ('100401', 'ท่าพระ', '1004', 'คลองสาน', '10', 'กรุงเทพมหานคร',
        13.7260, 100.4960,
        ST_GeomFromText('POLYGON((100.49 13.72, 100.51 13.72, 100.51 13.74, 100.49 13.74, 100.49 13.72))'),
        '2023-01-01', '9999-12-31', TRUE);

-- 3. Chang Khlan, Mueang Chiang Mai, Chiang Mai
INSERT INTO dim_location (subdistrict_code, subdistrict_name_th, district_code, district_name_th,
                          province_code, province_name_th, latitude, longitude, subdistrict_geom,
                          start_date, end_date, is_current)
VALUES ('500102', 'ช้างคลาน', '5001', 'เมืองเชียงใหม่', '50', 'เชียงใหม่',
        18.7813, 98.9935,
        ST_GeomFromText('POLYGON((98.98 18.77, 99.01 18.77, 99.01 18.80, 98.98 18.80, 98.98 18.77))'),
        '2023-01-01', '9999-12-31', TRUE);

-- 4. Talat, Mueang Nakhon Ratchasima, Nakhon Ratchasima (Korat)
INSERT INTO dim_location (subdistrict_code, subdistrict_name_th, district_code, district_name_th,
                          province_code, province_name_th, latitude, longitude, subdistrict_geom,
                          start_date, end_date, is_current)
VALUES ('300101', 'ในเมือง', '3001', 'เมืองนครราชสีมา', '30', 'นครราชสีมา',
        14.9742, 102.1005,
        ST_GeomFromText('POLYGON((102.09 14.96, 102.12 14.96, 102.12 14.99, 102.09 14.99, 102.09 14.96))'),
        '2023-01-01', '9999-12-31', TRUE);

-- 5. Hat Yai, Hat Yai, Songkhla
INSERT INTO dim_location (subdistrict_code, subdistrict_name_th, district_code, district_name_th,
                          province_code, province_name_th, latitude, longitude, subdistrict_geom,
                          start_date, end_date, is_current)
VALUES ('900101', 'หาดใหญ่', '9001', 'หาดใหญ่', '90', 'สงขลา',
        7.0056, 100.4747,
        ST_GeomFromText('POLYGON((100.46 6.99, 100.49 6.99, 100.49 7.02, 100.46 7.02, 100.46 6.99))'),
        '2023-01-01', '9999-12-31', TRUE);

-- 6. Khlong Toei, Khlong Toei, Bangkok (this one will be split in SCD Type 2 exercise)
INSERT INTO dim_location (subdistrict_code, subdistrict_name_th, district_code, district_name_th,
                          province_code, province_name_th, latitude, longitude, subdistrict_geom,
                          start_date, end_date, is_current)
VALUES ('101801', 'คลองเตย', '1018', 'คลองเตย', '10', 'กรุงเทพมหานคร',
        13.7190, 100.5530,
        ST_GeomFromText('POLYGON((100.54 13.70, 100.57 13.70, 100.57 13.74, 100.54 13.74, 100.54 13.70))'),
        '2023-01-01', '9999-12-31', TRUE);

\echo 'dim_location loaded:'
SELECT location_sk, subdistrict_name_th, province_name_th, is_current
FROM dim_location ORDER BY location_sk;


-- ============================================================================
-- fact_infection — 13 sample infection events
-- ============================================================================

-- Use INSERT...SELECT to look up location_sk and disease_sk dynamically
-- (IDENTITY values depend on insertion order, so we cannot hardcode them)

-- Dengue cluster in Bang Khen (Bangkok) during rainy season
INSERT INTO fact_infection (patient_id, infection_date_id, diagnosis_date_id, location_sk, disease_sk, severity_score, outcome, age, gender)
SELECT 'PID-2023-00001', 20230715, 20230717, l.location_sk, d.disease_sk, 2, 'recovered',    28, 'F'
FROM dim_location l, dim_disease d WHERE l.subdistrict_code='100901' AND l.is_current=TRUE AND d.disease_code='DHF';

INSERT INTO fact_infection (patient_id, infection_date_id, diagnosis_date_id, location_sk, disease_sk, severity_score, outcome, age, gender)
SELECT 'PID-2023-00002', 20230716, 20230719, l.location_sk, d.disease_sk, 3, 'hospitalized', 45, 'M'
FROM dim_location l, dim_disease d WHERE l.subdistrict_code='100901' AND l.is_current=TRUE AND d.disease_code='DHF';

INSERT INTO fact_infection (patient_id, infection_date_id, diagnosis_date_id, location_sk, disease_sk, severity_score, outcome, age, gender)
SELECT 'PID-2023-00003', 20230801, 20230803, l.location_sk, d.disease_sk, 1, 'recovered',     8, 'M'
FROM dim_location l, dim_disease d WHERE l.subdistrict_code='100901' AND l.is_current=TRUE AND d.disease_code='DHF';

-- TB case in Tha Phra (Bangkok)
INSERT INTO fact_infection (patient_id, infection_date_id, diagnosis_date_id, location_sk, disease_sk, severity_score, outcome, age, gender)
SELECT 'PID-2023-00004', 20230301, 20230315, l.location_sk, d.disease_sk, 3, 'hospitalized', 62, 'M'
FROM dim_location l, dim_disease d WHERE l.subdistrict_code='100401' AND l.is_current=TRUE AND d.disease_code='TB';

-- COVID-19 cases in Chiang Mai tourist area
INSERT INTO fact_infection (patient_id, infection_date_id, diagnosis_date_id, location_sk, disease_sk, severity_score, outcome, age, gender)
SELECT 'PID-2023-00005', 20230110, 20230112, l.location_sk, d.disease_sk, 1, 'recovered',    33, 'F'
FROM dim_location l, dim_disease d WHERE l.subdistrict_code='500102' AND l.is_current=TRUE AND d.disease_code='COV19';

INSERT INTO fact_infection (patient_id, infection_date_id, diagnosis_date_id, location_sk, disease_sk, severity_score, outcome, age, gender)
SELECT 'PID-2023-00006', 20230111, 20230114, l.location_sk, d.disease_sk, 2, 'recovered',    55, 'M'
FROM dim_location l, dim_disease d WHERE l.subdistrict_code='500102' AND l.is_current=TRUE AND d.disease_code='COV19';

-- Malaria in Songkhla (near Malaysian border)
INSERT INTO fact_infection (patient_id, infection_date_id, diagnosis_date_id, location_sk, disease_sk, severity_score, outcome, age, gender)
SELECT 'PID-2023-00007', 20230920, 20230922, l.location_sk, d.disease_sk, 4, 'hospitalized', 38, 'F'
FROM dim_location l, dim_disease d WHERE l.subdistrict_code='900101' AND l.is_current=TRUE AND d.disease_code='MAL';

-- Leptospirosis in Korat after flooding
INSERT INTO fact_infection (patient_id, infection_date_id, diagnosis_date_id, location_sk, disease_sk, severity_score, outcome, age, gender)
SELECT 'PID-2023-00008', 20231015, 20231018, l.location_sk, d.disease_sk, 2, 'recovered',    47, 'M'
FROM dim_location l, dim_disease d WHERE l.subdistrict_code='300101' AND l.is_current=TRUE AND d.disease_code='LEP';

INSERT INTO fact_infection (patient_id, infection_date_id, diagnosis_date_id, location_sk, disease_sk, severity_score, outcome, age, gender)
SELECT 'PID-2023-00009', 20231016, 20231020, l.location_sk, d.disease_sk, 3, 'hospitalized', 52, 'F'
FROM dim_location l, dim_disease d WHERE l.subdistrict_code='300101' AND l.is_current=TRUE AND d.disease_code='LEP';

-- 2024 dengue case in Bang Khen (will be used in SCD module)
INSERT INTO fact_infection (patient_id, infection_date_id, diagnosis_date_id, location_sk, disease_sk, severity_score, outcome, age, gender)
SELECT 'PID-2024-00001', 20240401, 20240403, l.location_sk, d.disease_sk, 2, 'recovered',    19, 'M'
FROM dim_location l, dim_disease d WHERE l.subdistrict_code='100901' AND l.is_current=TRUE AND d.disease_code='DHF';

-- Dengue cases in Khlong Toei (for SCD Type 2 exercise — split scenario)
INSERT INTO fact_infection (patient_id, infection_date_id, diagnosis_date_id, location_sk, disease_sk, severity_score, outcome, age, gender)
SELECT 'PID-2023-00010', 20230820, 20230822, l.location_sk, d.disease_sk, 2, 'recovered',    35, 'M'
FROM dim_location l, dim_disease d WHERE l.subdistrict_code='101801' AND l.is_current=TRUE AND d.disease_code='DHF';

INSERT INTO fact_infection (patient_id, infection_date_id, diagnosis_date_id, location_sk, disease_sk, severity_score, outcome, age, gender)
SELECT 'PID-2023-00011', 20230905, 20230907, l.location_sk, d.disease_sk, 3, 'hospitalized', 42, 'F'
FROM dim_location l, dim_disease d WHERE l.subdistrict_code='101801' AND l.is_current=TRUE AND d.disease_code='DHF';

INSERT INTO fact_infection (patient_id, infection_date_id, diagnosis_date_id, location_sk, disease_sk, severity_score, outcome, age, gender)
SELECT 'PID-2024-00002', 20240515, 20240517, l.location_sk, d.disease_sk, 1, 'recovered',    25, 'M'
FROM dim_location l, dim_disease d WHERE l.subdistrict_code='101801' AND l.is_current=TRUE AND d.disease_code='DHF';

COMMIT;

\echo 'fact_infection loaded:'
SELECT COUNT(*) AS total_infections FROM fact_infection;
-- Expected: 13 rows

-- ============================================================================
-- VERIFICATION: Star schema join test
-- ============================================================================
SELECT
    dd.full_date,
    dd.month_name_th,
    dis.disease_name_th,
    loc.subdistrict_name_th,
    loc.province_name_th,
    fi.patient_id,
    fi.severity_score,
    fi.outcome
FROM fact_infection fi
JOIN dim_date     dd  ON fi.infection_date_id = dd.date_id
JOIN dim_disease  dis ON fi.disease_sk        = dis.disease_sk
JOIN dim_location loc ON fi.location_sk       = loc.location_sk
ORDER BY dd.full_date;
-- Expected: 13 rows

\echo 'Setup complete. All tables ready for Course 2 modules.'
