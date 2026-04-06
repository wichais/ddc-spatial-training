-- ============================================================================
-- Course 2, Module 3: SCD Type 2 — Handling Boundary Changes
-- ============================================================================
-- CONNECTION: vsql -h <vertica_host> -p 5433 -U dbadmin -d VMart
-- PREREQUISITE: Run 01_dimensional_model.sql first (we modify dim_location).
-- ============================================================================
--
-- SCENARIO: In March 2024, the Thai government splits subdistrict "บางเขน"
-- (Bang Khen, code 100901) in Chatuchak district, Bangkok, into TWO new
-- subdistricts:
--
--   "บางเขนเหนือ" (Bang Khen Nuea) — code 100901  (keeps the old code)
--   "บางเขนใต้"   (Bang Khen Tai)  — code 100902  (new code)
--
-- THE CHALLENGE:
--   - 3 dengue cases from 2023 were diagnosed in the OLD Bang Khen boundary.
--     Those historical records must STILL link to the old polygon.
--   - 1 dengue case from April 2024 happened in the NEW northern half.
--     It must link to the new "Bang Khen Nuea" boundary.
--   - DDC dashboards must show BOTH old and new data correctly.
--
-- THE SOLUTION: SCD Type 2 on dim_location.
--   - We EXPIRE the old Bang Khen row (set end_date, is_current=FALSE)
--   - We INSERT two new rows for the split subdistricts
--   - Historical fact rows still join via location_sk to the OLD row
--   - New fact rows join via location_sk to the NEW rows
--
-- WHY NOT just UPDATE the old row?
--   Because that would rewrite history. The old polygon covered a different
--   geographic area. Dengue cases diagnosed in 2023 were geocoded to the
--   OLD boundary. If we overwrite it, spatial queries on 2023 data give
--   wrong results.
-- ============================================================================

SET SEARCH_PATH TO ddc_training, public, v_catalog, v_monitor;

-- ============================================================================
-- STEP 0: Check the current state of Bang Khen
-- ============================================================================

SELECT location_sk, subdistrict_code, subdistrict_name_th,
       district_name_th, province_name_th,
       start_date, end_date, is_current,
       ST_AsText(subdistrict_geom) AS geom_wkt
FROM dim_location
WHERE subdistrict_code = '100901';

-- Expected: 1 row, is_current=TRUE, end_date='9999-12-31'
-- This is the row that 2023 dengue cases reference via location_sk.

-- Check historical infections linked to Bang Khen
SELECT fi.patient_id, fi.infection_date_id, loc.subdistrict_name_th, loc.is_current
FROM fact_infection fi
JOIN dim_location loc ON fi.location_sk = loc.location_sk
WHERE loc.subdistrict_code = '100901';

-- Expected: 4 rows (PID-2023-00001, -00002, -00003, and PID-2024-00001)


-- ============================================================================
-- STEP 1: Create staging table with the new boundary data
-- ============================================================================
-- In production, this would come from the Department of Provincial
-- Administration (DOPA) via an automated ETL pipeline.
-- The staging table represents the "incoming change" data.
-- ============================================================================

DROP TABLE IF EXISTS stg_subdistrict_update;

CREATE TABLE stg_subdistrict_update (
    action            VARCHAR(10) NOT NULL,   -- 'SPLIT', 'MERGE', 'RENAME'
    old_subdistrict_code VARCHAR(8) NOT NULL,
    new_subdistrict_code VARCHAR(8) NOT NULL,
    new_subdistrict_name_th VARCHAR(60) NOT NULL,
    new_district_code VARCHAR(6) NOT NULL,
    new_district_name_th VARCHAR(60) NOT NULL,
    new_province_code VARCHAR(4) NOT NULL,
    new_province_name_th VARCHAR(60) NOT NULL,
    new_latitude      NUMERIC(9,6),
    new_longitude     NUMERIC(9,6),
    new_geom          GEOMETRY(1000),
    effective_date    DATE NOT NULL
);

-- The SPLIT: Bang Khen → Bang Khen Nuea (north half) + Bang Khen Tai (south half)
-- NOTE: Vertica does not support multi-row INSERT for spatial types.
INSERT INTO stg_subdistrict_update VALUES
    ('SPLIT', '100901', '100901', 'บางเขนเหนือ', '1009', 'จตุจักร', '10', 'กรุงเทพมหานคร',
     13.8800, 100.5665,
     ST_GeomFromText('POLYGON((100.55 13.875, 100.58 13.875, 100.58 13.89, 100.55 13.89, 100.55 13.875))'),
     '2024-03-01');
INSERT INTO stg_subdistrict_update VALUES
    ('SPLIT', '100901', '100902', 'บางเขนใต้', '1009', 'จตุจักร', '10', 'กรุงเทพมหานคร',
     13.8650, 100.5665,
     ST_GeomFromText('POLYGON((100.55 13.86, 100.58 13.86, 100.58 13.875, 100.55 13.875, 100.55 13.86))'),
     '2024-03-01');

SELECT * FROM stg_subdistrict_update;


-- ============================================================================
-- STEP 2: EXPIRE the old Bang Khen record (the 2-step SCD approach)
-- ============================================================================
-- We set end_date to one day before the effective_date of the split.
-- We set is_current = FALSE.
-- The old row remains in dim_location — it is NOT deleted.
-- Historical facts still join to it via location_sk (surrogate key).
-- ============================================================================

\echo '=== Step 2: Expiring old Bang Khen record ==='

UPDATE dim_location
SET end_date   = (SELECT effective_date - 1 FROM stg_subdistrict_update WHERE new_subdistrict_code = '100901' LIMIT 1),
    is_current = FALSE
WHERE subdistrict_code = '100901'
  AND is_current = TRUE;

-- Verify: old row now shows end_date = '2024-02-29', is_current = FALSE
SELECT location_sk, subdistrict_name_th, start_date, end_date, is_current
FROM dim_location
WHERE subdistrict_code = '100901';


-- ============================================================================
-- STEP 3: INSERT new versions for the split subdistricts
-- ============================================================================
-- Each new subdistrict gets its own location_sk (via IDENTITY).
-- start_date = the effective_date from the staging table.
-- end_date = '9999-12-31' (current version).
-- ============================================================================

\echo '=== Step 3: Inserting new Bang Khen Nuea and Bang Khen Tai ==='

INSERT INTO dim_location (subdistrict_code, subdistrict_name_th, district_code, district_name_th,
                          province_code, province_name_th, latitude, longitude, subdistrict_geom,
                          start_date, end_date, is_current)
SELECT
    stg.new_subdistrict_code,
    stg.new_subdistrict_name_th,
    stg.new_district_code,
    stg.new_district_name_th,
    stg.new_province_code,
    stg.new_province_name_th,
    stg.new_latitude,
    stg.new_longitude,
    stg.new_geom,
    stg.effective_date       AS start_date,
    '9999-12-31'::DATE       AS end_date,
    TRUE                     AS is_current
FROM stg_subdistrict_update stg
WHERE stg.old_subdistrict_code = '100901';


-- ============================================================================
-- STEP 4: VERIFICATION — The audit trail
-- ============================================================================
-- dim_location now has 3 rows related to Bang Khen:
--   1. Old "บางเขน"       (expired: 2023-01-01 to 2024-02-29)
--   2. New "บางเขนเหนือ"  (current: 2024-03-01 to 9999-12-31)
--   3. New "บางเขนใต้"    (current: 2024-03-01 to 9999-12-31)
-- ============================================================================

\echo '=== Verification: SCD Type 2 audit trail ==='

SELECT location_sk, subdistrict_code, subdistrict_name_th,
       start_date, end_date, is_current,
       ST_AsText(subdistrict_geom) AS geom_wkt
FROM dim_location
WHERE subdistrict_code IN ('100901', '100902')
ORDER BY start_date, subdistrict_code;

-- Expected output:
-- location_sk | code   | name          | start_date | end_date   | is_current
-- -----------+--------+---------------+------------+------------+-----------
--          1 | 100901 | บางเขน        | 2023-01-01 | 2024-02-29 | FALSE
--          6 | 100901 | บางเขนเหนือ   | 2024-03-01 | 9999-12-31 | TRUE
--          7 | 100902 | บางเขนใต้      | 2024-03-01 | 9999-12-31 | TRUE


-- ============================================================================
-- STEP 5: Prove historical facts still join to the OLD boundary
-- ============================================================================
-- The 2023 dengue cases still reference location_sk=1 (the old Bang Khen row).
-- The old row's polygon is the ORIGINAL undivided area — correct for 2023 data.
-- ============================================================================

\echo '=== Historical query: 2023 dengue cases link to OLD Bang Khen ==='

SELECT
    fi.patient_id,
    dd.full_date           AS infection_date,
    loc.subdistrict_name_th,
    loc.start_date         AS boundary_valid_from,
    loc.end_date           AS boundary_valid_until,
    loc.is_current         AS is_current_boundary,
    dis.disease_name_th
FROM fact_infection fi
JOIN dim_date     dd  ON fi.infection_date_id = dd.date_id
JOIN dim_location loc ON fi.location_sk       = loc.location_sk
JOIN dim_disease  dis ON fi.disease_sk        = dis.disease_sk
WHERE loc.subdistrict_code = '100901'
  AND dd.year_num = 2023;

-- Expected: 3 rows, all showing "บางเขน" with is_current=FALSE
-- The historical boundary is preserved. No data was lost or distorted.


-- ============================================================================
-- STEP 6: Assign new facts to NEW boundaries
-- ============================================================================
-- The PID-2024-00001 patient (April 2024) was originally linked to the old
-- Bang Khen (location_sk=1). After the split, we need to reassign it to
-- the correct new subdistrict based on the patient's geocoded location.
--
-- In production, DDC would geocode the patient address and use ST_Intersects
-- to determine which new polygon it falls within (ST_Intersects).
-- ============================================================================

\echo '=== Reassigning 2024 infection to new Bang Khen Nuea ==='

-- Simulate: patient PID-2024-00001 lives in the northern half
-- Find the location_sk for Bang Khen Nuea
UPDATE fact_infection
SET location_sk = (
    SELECT location_sk FROM dim_location
    WHERE subdistrict_name_th = 'บางเขนเหนือ'
      AND is_current = TRUE
)
WHERE patient_id = 'PID-2024-00001';

-- Verify: new fact now links to the new boundary
SELECT
    fi.patient_id,
    dd.full_date           AS infection_date,
    loc.subdistrict_name_th,
    loc.start_date         AS boundary_valid_from,
    loc.is_current,
    dis.disease_name_th
FROM fact_infection fi
JOIN dim_date     dd  ON fi.infection_date_id = dd.date_id
JOIN dim_location loc ON fi.location_sk       = loc.location_sk
JOIN dim_disease  dis ON fi.disease_sk        = dis.disease_sk
WHERE fi.patient_id = 'PID-2024-00001';

-- Expected: 1 row showing "บางเขนเหนือ" with is_current=TRUE


-- ============================================================================
-- STEP 7: MERGE approach (alternative — for reference)
-- ============================================================================
-- Vertica supports MERGE (UPSERT), which can handle SCD in a single statement.
-- However, there is a limitation:
--
--   MERGE ... WHEN MATCHED THEN UPDATE ... WHEN NOT MATCHED THEN INSERT ...
--
-- For SCD Type 2, we need to BOTH update the old row AND insert new rows.
-- MERGE's WHEN MATCHED can only UPDATE (not INSERT additional rows).
-- This means MERGE alone cannot fully handle a SPLIT scenario.
--
-- NOTE: In Vertica CE, MERGE does not support tables with IDENTITY columns.
-- We demonstrate the same pattern using UPDATE + INSERT instead:
-- ============================================================================

\echo '=== MERGE example: renaming a subdistrict (simpler SCD case) ==='

-- Example: Suppose "หาดใหญ่" changes its official romanized name
-- We demonstrate MERGE for this simpler attribute-change scenario.

DROP TABLE IF EXISTS stg_rename_update;

CREATE TABLE stg_rename_update (
    subdistrict_code     VARCHAR(8),
    new_subdistrict_name_th VARCHAR(60),
    effective_date       DATE
);

INSERT INTO stg_rename_update VALUES ('900101', 'หาดใหญ่ (ปรับปรุง)', '2024-06-01');

-- Step 7a: First expire the old row (UPDATE)
UPDATE dim_location loc
SET end_date   = stg.effective_date - 1,
    is_current = FALSE
FROM stg_rename_update stg
WHERE loc.subdistrict_code = stg.subdistrict_code
  AND loc.is_current = TRUE;

-- Step 7b: Insert the new version
-- NOTE: MERGE INTO does not support tables with IDENTITY columns in Vertica CE.
-- We use INSERT ... SELECT instead, which is equally effective for SCD Type 2.
INSERT INTO dim_location (subdistrict_code, subdistrict_name_th, district_code, district_name_th,
                          province_code, province_name_th, latitude, longitude, subdistrict_geom,
                          start_date, end_date, is_current)
SELECT
    stg.subdistrict_code,
    stg.new_subdistrict_name_th,
    loc.district_code,
    loc.district_name_th,
    loc.province_code,
    loc.province_name_th,
    loc.latitude,
    loc.longitude,
    loc.subdistrict_geom,
    stg.effective_date       AS start_date,
    '9999-12-31'::DATE       AS end_date,
    TRUE                     AS is_current
FROM stg_rename_update stg
JOIN dim_location loc ON stg.subdistrict_code = loc.subdistrict_code
WHERE loc.is_current = FALSE
  AND loc.end_date = stg.effective_date - 1;

-- Verify the rename audit trail
SELECT location_sk, subdistrict_code, subdistrict_name_th, start_date, end_date, is_current
FROM dim_location
WHERE subdistrict_code = '900101'
ORDER BY start_date;

-- Expected: 2 rows:
--   "หาดใหญ่"           2023-01-01 to 2024-05-31  is_current=FALSE
--   "หาดใหญ่ (ปรับปรุง)" 2024-06-01 to 9999-12-31  is_current=TRUE


-- ============================================================================
-- RECOMMENDATION FOR DDC:
-- ============================================================================
-- Use the 2-step approach (UPDATE then INSERT) for SPLIT/MERGE operations.
-- Use MERGE for simpler changes (rename, attribute correction).
--
-- The 2-step approach is:
--   1. Clearer for code review and debugging
--   2. Easier to audit (each step can be verified independently)
--   3. More flexible (handles 1-to-many splits)
--
-- Always wrap both steps in a transaction in production:
--   BEGIN;
--     UPDATE dim_location SET ... ;   -- expire old
--     INSERT INTO dim_location ... ;  -- insert new versions
--   COMMIT;
-- ============================================================================

COMMIT;

-- Cleanup staging tables
DROP TABLE IF EXISTS stg_subdistrict_update;
DROP TABLE IF EXISTS stg_rename_update;

-- ============================================================================
-- END OF MODULE 3
-- You now have a complete SCD Type 2 workflow for Thai administrative changes.
-- ============================================================================
