-- ============================================================================
-- PURBALINGGA PBG-02 | PRODUCTION | 2026-10-26
-- Writes to the ORIGINAL downstream reference:
--   stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_pregnancy_episode_v3_3
-- Reads PBG-01 production:
--   stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_source_records
--
-- Identity/episode grouping uses corrected puskesmas_norm (CONTROL B).
-- Post-episode override selects a unique valid ANC facility for DINAS
-- KESEHATAN episodes (180 corrected in the controlled 24,892 baseline).
-- Ambiguities are held for review. Do NOT hard-code baseline counts after
-- upstream source refreshes: newer records may legitimately change outputs.
--
-- DANGER: CREATE OR REPLACE TABLE overwrites production.
-- Run PBG-01 first, after backups and candidate QA; pause schedules.
-- ============================================================================

DECLARE sigizi_episode_anchor_tolerance_days INT64 DEFAULT 120;
DECLARE plausible_pregnancy_floor DATE DEFAULT DATE '2018-01-01';
DECLARE analysis_date DATE DEFAULT CURRENT_DATE('Asia/Jakarta');

CREATE TEMP FUNCTION norm_text(s STRING) RETURNS STRING AS (
  NULLIF(REGEXP_REPLACE(UPPER(TRIM(NORMALIZE(COALESCE(s, ''), NFKC))), r'\s+', ' '), '')
);
CREATE TEMP FUNCTION norm_name(s STRING) RETURNS STRING AS (
  NULLIF(TRIM(REGEXP_REPLACE(REGEXP_REPLACE(UPPER(TRIM(NORMALIZE(COALESCE(s, ''), NFKC))), r'[^A-Z0-9 ]', ' '), r'\s+', ' ')), '')
);
CREATE TEMP FUNCTION norm_name_core(s STRING) RETURNS STRING AS (
  NULLIF(TRIM(REGEXP_REPLACE(REGEXP_REPLACE(COALESCE(norm_name(s), ''), r'^(IBU|NY|NYONYA|HJ|HJH|HAJAH)\s+', ''), r'\s+(SE|S E|SPD|S PD|SST|S ST|SKM|S KM|M KES|MKES|M KEB|MKEB|S KEP|SKEP|NERS|A MD KEB|AMD KEB)$', '')), '')
);
CREATE TEMP FUNCTION nik_is_trusted(s STRING) RETURNS BOOL AS (
  s IS NOT NULL AND REGEXP_CONTAINS(s, r'^\d{16}$')
  AND s NOT IN ('0000000000000000', '9999999999999999')
  AND RIGHT(s, 4) != '0000'
);
CREATE TEMP FUNCTION maternal_nik_birth_date(s STRING, reference_date DATE)
RETURNS DATE AS (
  CASE WHEN nik_is_trusted(s) AND reference_date IS NOT NULL
   AND SAFE_CAST(SUBSTR(s, 7, 2) AS INT64) BETWEEN 41 AND 71
   AND SAFE_CAST(SUBSTR(s, 9, 2) AS INT64) BETWEEN 1 AND 12
  THEN SAFE.PARSE_DATE('%Y%m%d', CONCAT(
    CASE WHEN SAFE_CAST(SUBSTR(s, 11, 2) AS INT64) <= MOD(EXTRACT(YEAR FROM reference_date), 100)
      THEN '20' ELSE '19' END,
    SUBSTR(s, 11, 2), SUBSTR(s, 9, 2),
    LPAD(CAST(SAFE_CAST(SUBSTR(s, 7, 2) AS INT64) - 40 AS STRING), 2, '0')
  )) END
);
CREATE TEMP FUNCTION maternal_nik_is_plausible(s STRING, reference_date DATE)
RETURNS BOOL AS (
  maternal_nik_birth_date(s, reference_date) IS NOT NULL
  AND DATE_DIFF(reference_date, maternal_nik_birth_date(s, reference_date), YEAR) BETWEEN 10 AND 60
);
CREATE TEMP FUNCTION norm_puskesmas(s STRING) RETURNS STRING AS (
  CASE WHEN norm_text(s) IS NULL THEN NULL
    ELSE REGEXP_REPLACE(norm_text(s), r'^PUSKESMAS\s+', '') END
);
CREATE TEMP FUNCTION is_sigizi_anon_placeholder(s STRING) RETURNS BOOL AS (
  REGEXP_CONTAINS(UPPER(TRIM(COALESCE(s, ''))), r'^ANON[_ -]?[0-9]+$')
);

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_pregnancy_episode_v3_3`
CLUSTER BY nik_clean, puskesmas_norm, sigizi_episode_id
AS
WITH source_base AS (
  SELECT
    source_table, source_priority, source_role, source_record_id,
    nik_clean, nama,
    norm_name(nama) AS nama_episode_norm,
    norm_name_core(nama) AS nama_core_norm,
    tanggal_lahir, hpht_date, hpl_date, anc_date, delivery_date,
    norm_puskesmas(COALESCE(puskesmas_norm, puskesmas)) AS puskesmas,
    norm_puskesmas(COALESCE(puskesmas_norm, puskesmas)) AS puskesmas_norm,
    norm_text(COALESCE(desa_norm, desa)) AS desa,
    norm_text(COALESCE(desa_norm, desa)) AS desa_norm,
    posyandu, alamat, no_hp_clean
  FROM `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_source_records`
  WHERE pregnancy_episode_creator_flag = TRUE
    AND NOT (
      is_sigizi_anon_placeholder(nama)
      OR is_sigizi_anon_placeholder(nama_norm)
    )
    AND (
      norm_name_core(nama) IS NOT NULL
      OR maternal_nik_is_plausible(
        nik_clean,
        COALESCE(hpht_date, DATE_SUB(hpl_date, INTERVAL 280 DAY), anc_date, analysis_date)
      )
    )
),
prepared AS (
  SELECT *,
    CASE WHEN hpht_date BETWEEN plausible_pregnancy_floor AND analysis_date THEN hpht_date END AS hpht_valid,
    CASE WHEN hpl_date BETWEEN plausible_pregnancy_floor AND DATE_ADD(analysis_date, INTERVAL 300 DAY) THEN hpl_date END AS hpl_valid,
    CASE WHEN delivery_date BETWEEN plausible_pregnancy_floor AND analysis_date THEN delivery_date END AS delivery_valid,
    CASE WHEN anc_date BETWEEN plausible_pregnancy_floor AND analysis_date THEN anc_date END AS anc_valid
  FROM source_base
),
identity_base AS (
  SELECT *,
    COALESCE(hpht_valid, CASE WHEN hpl_valid IS NOT NULL THEN DATE_SUB(hpl_valid, INTERVAL 280 DAY) END)
      AS pregnancy_anchor_date
  FROM prepared
),
signature_base AS (
  SELECT *,
    CASE WHEN nama_core_norm IS NOT NULL AND puskesmas_norm IS NOT NULL
       AND desa_norm IS NOT NULL AND pregnancy_anchor_date IS NOT NULL
    THEN CONCAT('PREGSIG|', nama_core_norm, '|', puskesmas_norm, '|',
      desa_norm, '|', CAST(pregnancy_anchor_date AS STRING)) END AS pregnancy_signature_key
  FROM identity_base
),
signature_stats AS (
  SELECT pregnancy_signature_key,
    COUNT(*) AS signature_row_count,
    COUNT(DISTINCT nik_clean) AS signature_distinct_nik_count,
    ARRAY_AGG(DISTINCT nik_clean IGNORE NULLS ORDER BY nik_clean LIMIT 1)[SAFE_OFFSET(0)] AS signature_unique_nik,
    COUNT(DISTINCT tanggal_lahir) AS signature_distinct_dob_count,
    ARRAY_AGG(DISTINCT tanggal_lahir IGNORE NULLS ORDER BY tanggal_lahir LIMIT 1)[SAFE_OFFSET(0)] AS signature_unique_dob
  FROM signature_base WHERE pregnancy_signature_key IS NOT NULL
  GROUP BY pregnancy_signature_key
),
identified AS (
  SELECT b.*,
    COALESCE(s.signature_row_count, 1) AS signature_row_count,
    COALESCE(s.signature_distinct_nik_count, 0) AS signature_distinct_nik_count,
    s.signature_unique_nik,
    COALESCE(s.signature_distinct_dob_count, 0) AS signature_distinct_dob_count,
    s.signature_unique_dob,
    CASE
      WHEN b.nik_clean IS NOT NULL THEN CONCAT('NIK|', b.nik_clean)
      WHEN b.pregnancy_signature_key IS NOT NULL
        AND COALESCE(s.signature_distinct_nik_count, 0) = 1
        AND s.signature_unique_nik IS NOT NULL THEN CONCAT('NIK|', s.signature_unique_nik)
      WHEN b.nama_core_norm IS NOT NULL AND b.tanggal_lahir IS NOT NULL AND b.puskesmas_norm IS NOT NULL
        THEN CONCAT('NAME_DOB_PKM|', b.nama_core_norm, '|', CAST(b.tanggal_lahir AS STRING), '|', b.puskesmas_norm)
      WHEN b.nama_core_norm IS NOT NULL AND b.tanggal_lahir IS NOT NULL AND b.desa_norm IS NOT NULL
        THEN CONCAT('NAME_DOB_DESA|', b.nama_core_norm, '|', CAST(b.tanggal_lahir AS STRING), '|', b.desa_norm)
      WHEN b.nama_core_norm IS NOT NULL AND b.tanggal_lahir IS NOT NULL
        THEN CONCAT('NAME_DOB|', b.nama_core_norm, '|', CAST(b.tanggal_lahir AS STRING))
      WHEN b.pregnancy_signature_key IS NOT NULL AND COALESCE(s.signature_distinct_nik_count, 0) = 0
        AND COALESCE(s.signature_distinct_dob_count, 0) = 1 AND s.signature_unique_dob IS NOT NULL
        THEN CONCAT('NAME_DOB_PKM|', b.nama_core_norm, '|', CAST(s.signature_unique_dob AS STRING), '|', b.puskesmas_norm)
      WHEN b.pregnancy_signature_key IS NOT NULL AND COALESCE(s.signature_distinct_nik_count, 0) = 0
        AND COALESCE(s.signature_distinct_dob_count, 0) = 0 THEN b.pregnancy_signature_key
      ELSE CONCAT('SOURCE|', b.source_table, '|', b.source_record_id)
    END AS mother_identity_key,
    CASE
      WHEN b.nik_clean IS NOT NULL THEN 'NIK'
      WHEN b.pregnancy_signature_key IS NOT NULL AND COALESCE(s.signature_distinct_nik_count, 0) = 1
        AND s.signature_unique_nik IS NOT NULL THEN 'PREG_SIGNATURE_TO_UNIQUE_NIK'
      WHEN b.nama_core_norm IS NOT NULL AND b.tanggal_lahir IS NOT NULL AND b.puskesmas_norm IS NOT NULL
        THEN 'NAMA_CORE+DOB+PUSKESMAS'
      WHEN b.nama_core_norm IS NOT NULL AND b.tanggal_lahir IS NOT NULL AND b.desa_norm IS NOT NULL
        THEN 'NAMA_CORE+DOB+DESA'
      WHEN b.nama_core_norm IS NOT NULL AND b.tanggal_lahir IS NOT NULL THEN 'NAMA_CORE+DOB'
      WHEN b.pregnancy_signature_key IS NOT NULL AND COALESCE(s.signature_distinct_nik_count, 0) = 0
        AND COALESCE(s.signature_distinct_dob_count, 0) = 1 AND s.signature_unique_dob IS NOT NULL
        THEN 'PREG_SIGNATURE_TO_UNIQUE_DOB'
      WHEN b.pregnancy_signature_key IS NOT NULL AND COALESCE(s.signature_distinct_nik_count, 0) = 0
        AND COALESCE(s.signature_distinct_dob_count, 0) = 0 THEN 'WEAK_PREG_SIGNATURE'
      ELSE 'SOURCE_RECORD'
    END AS mother_identity_method,
    (b.nik_clean IS NULL AND (
      (b.pregnancy_signature_key IS NOT NULL AND COALESCE(s.signature_distinct_nik_count, 0) = 1
        AND s.signature_unique_nik IS NOT NULL)
      OR (b.tanggal_lahir IS NULL AND b.pregnancy_signature_key IS NOT NULL
        AND COALESCE(s.signature_distinct_nik_count, 0) = 0
        AND COALESCE(s.signature_distinct_dob_count, 0) = 1
        AND s.signature_unique_dob IS NOT NULL)
    )) AS identity_propagated_flag,
    (b.nik_clean IS NULL AND b.tanggal_lahir IS NULL AND b.pregnancy_signature_key IS NOT NULL
      AND (COALESCE(s.signature_distinct_nik_count, 0) > 1
        OR COALESCE(s.signature_distinct_dob_count, 0) > 1)) AS weak_signature_ambiguous_flag
  FROM signature_base b
  LEFT JOIN signature_stats s USING (pregnancy_signature_key)
),
anchor_records AS (
  SELECT * FROM identified WHERE pregnancy_anchor_date IS NOT NULL
),
ordered AS (
  SELECT *,
    LAG(pregnancy_anchor_date) OVER (
      PARTITION BY mother_identity_key
      ORDER BY pregnancy_anchor_date, source_priority, source_record_id
    ) AS previous_anchor_date
  FROM anchor_records
),
marked AS (
  SELECT *, CASE
    WHEN previous_anchor_date IS NULL THEN 1
    WHEN DATE_DIFF(pregnancy_anchor_date, previous_anchor_date, DAY)
      > sigizi_episode_anchor_tolerance_days THEN 1
    ELSE 0 END AS starts_new_episode
  FROM ordered
),
numbered AS (
  SELECT *,
    SUM(starts_new_episode) OVER (
      PARTITION BY mother_identity_key
      ORDER BY pregnancy_anchor_date, source_priority, source_record_id
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS episode_number
  FROM marked
),
aggregated AS (
  SELECT mother_identity_key, episode_number,
    ARRAY_AGG(mother_identity_method ORDER BY
      CASE mother_identity_method
        WHEN 'NIK' THEN 1
        WHEN 'PREG_SIGNATURE_TO_UNIQUE_NIK' THEN 2
        WHEN 'NAMA_CORE+DOB+PUSKESMAS' THEN 3
        WHEN 'NAMA_CORE+DOB+DESA' THEN 4
        WHEN 'PREG_SIGNATURE_TO_UNIQUE_DOB' THEN 5
        WHEN 'NAMA_CORE+DOB' THEN 6
        WHEN 'WEAK_PREG_SIGNATURE' THEN 7
        ELSE 9 END, source_priority, source_record_id LIMIT 1
    )[SAFE_OFFSET(0)] AS mother_identity_method,
    ARRAY_AGG(DISTINCT mother_identity_method ORDER BY mother_identity_method) AS mother_identity_methods,
    MIN(pregnancy_anchor_date) AS pregnancy_anchor_min_date,
    MAX(pregnancy_anchor_date) AS pregnancy_anchor_max_date,
    DATE_DIFF(MAX(pregnancy_anchor_date), MIN(pregnancy_anchor_date), DAY) AS pregnancy_anchor_spread_days,
    COUNT(*) AS sigizi_member_record_count,
    COUNTIF(identity_propagated_flag) AS sigizi_identity_propagated_record_count,
    COUNTIF(weak_signature_ambiguous_flag) AS sigizi_ambiguous_identity_record_count,
    MAX(signature_row_count) AS sigizi_max_signature_row_count,
    COUNT(DISTINCT pregnancy_signature_key) AS sigizi_distinct_pregnancy_signature_count,
    ARRAY_AGG(DISTINCT source_table ORDER BY source_table) AS sigizi_source_tables,
    ARRAY_AGG(source_record_id ORDER BY source_priority, source_record_id) AS sigizi_member_source_record_ids,
    ARRAY_AGG(STRUCT(nik_clean AS value, source_priority AS priority, source_record_id AS source_record_id)
      ORDER BY nik_clean IS NULL, source_priority, source_record_id LIMIT 1)[SAFE_OFFSET(0)] AS nik_pick,
    ARRAY_AGG(STRUCT(nama AS value, nama_episode_norm AS value_norm,
      nama_core_norm AS value_core_norm, source_priority AS priority,
      source_record_id AS source_record_id)
      ORDER BY nama_core_norm IS NULL, source_priority, source_record_id LIMIT 1)[SAFE_OFFSET(0)] AS nama_pick,
    ARRAY_AGG(STRUCT(tanggal_lahir AS value, source_priority AS priority,
      source_record_id AS source_record_id)
      ORDER BY tanggal_lahir IS NULL, source_priority, source_record_id LIMIT 1)[SAFE_OFFSET(0)] AS dob_pick,
    ARRAY_AGG(STRUCT(no_hp_clean AS value, source_priority AS priority,
      source_record_id AS source_record_id)
      ORDER BY no_hp_clean IS NULL, LENGTH(COALESCE(no_hp_clean, '')) DESC,
      source_priority, source_record_id LIMIT 1)[SAFE_OFFSET(0)] AS phone_pick,
    ARRAY_AGG(STRUCT(
      puskesmas AS puskesmas,
      puskesmas_norm AS puskesmas_norm,
      desa AS desa,
      desa_norm AS desa_norm,
      posyandu AS posyandu,
      alamat AS alamat,
      CASE
        WHEN puskesmas_norm IS NOT NULL AND desa_norm IS NOT NULL AND posyandu IS NOT NULL
          THEN 'SOURCE_BUNDLE_PKM+DESA+POSYANDU'
        WHEN puskesmas_norm IS NOT NULL AND desa_norm IS NOT NULL
          THEN 'SOURCE_BUNDLE_PKM+DESA'
        WHEN puskesmas_norm IS NOT NULL THEN 'SOURCE_BUNDLE_PKM'
        ELSE 'UNRESOLVED' END AS resolution_method,
      CASE
        WHEN puskesmas_norm IS NOT NULL AND desa_norm IS NOT NULL THEN 'VERY_HIGH'
        WHEN puskesmas_norm IS NOT NULL THEN 'HIGH'
        ELSE 'UNRESOLVED' END AS resolution_confidence,
      (IF(puskesmas_norm IS NOT NULL, 10, 0)
        + IF(desa_norm IS NOT NULL, 5, 0)
        + IF(posyandu IS NOT NULL, 2, 0)
        + IF(alamat IS NOT NULL, 1, 0)) AS resolution_score,
      source_table AS source_table,
      source_record_id AS source_record_id,
      source_priority AS source_priority
    ) ORDER BY
      puskesmas_norm IS NULL,
      desa_norm IS NULL,
      posyandu IS NULL,
      (IF(puskesmas_norm IS NOT NULL, 10, 0)
        + IF(desa_norm IS NOT NULL, 5, 0)
        + IF(posyandu IS NOT NULL, 2, 0)
        + IF(alamat IS NOT NULL, 1, 0)) DESC,
      source_priority, source_record_id LIMIT 1)[SAFE_OFFSET(0)] AS location_pick,
    ARRAY_AGG(STRUCT(hpht_valid AS value, source_table AS source_table,
      source_priority AS priority, source_record_id AS source_record_id)
      ORDER BY hpht_valid IS NULL, source_priority, source_record_id LIMIT 1)[SAFE_OFFSET(0)] AS hpht_pick,
    ARRAY_AGG(STRUCT(hpl_valid AS value, source_table AS source_table,
      source_priority AS priority, source_record_id AS source_record_id)
      ORDER BY hpl_valid IS NULL, source_priority, source_record_id LIMIT 1)[SAFE_OFFSET(0)] AS hpl_pick,
    ARRAY_AGG(STRUCT(delivery_valid AS value, source_table AS source_table,
      source_priority AS priority, source_record_id AS source_record_id)
      ORDER BY delivery_valid IS NULL, source_priority, source_record_id LIMIT 1)[SAFE_OFFSET(0)] AS delivery_pick,
    MIN(anc_valid) AS first_anc_date,
    MAX(anc_valid) AS last_anc_date
  FROM numbered
  GROUP BY mother_identity_key, episode_number
),
base_episodes AS (
SELECT
  CONCAT('SIGEP_', TO_HEX(SHA256(CONCAT(mother_identity_key, '|',
    CAST(pregnancy_anchor_min_date AS STRING), '|', CAST(episode_number AS STRING))))) AS sigizi_episode_id,
  mother_identity_key, mother_identity_method, episode_number,
  nik_pick.value AS nik_clean,
  nama_pick.value AS nama_ibu,
  nama_pick.value_norm AS nama_norm,
  nama_pick.value_core_norm AS nama_core_norm,
  dob_pick.value AS tanggal_lahir_ibu,
  phone_pick.value AS no_hp_clean,
  location_pick.puskesmas AS puskesmas,
  location_pick.puskesmas_norm AS puskesmas_norm,
  location_pick.desa AS desa,
  location_pick.desa_norm AS desa_norm,
  location_pick.posyandu AS posyandu,
  location_pick.alamat AS alamat,
  location_pick.resolution_method AS location_resolution_method,
  location_pick.resolution_confidence AS location_resolution_confidence,
  location_pick.resolution_score AS location_resolution_score,
  location_pick.source_table AS location_source_table,
  location_pick.source_record_id AS location_source_record_id,
  hpht_pick.value AS hpht_sigizi,
  CASE WHEN hpht_pick.value IS NOT NULL THEN hpht_pick.source_table END AS hpht_sigizi_source_table,
  hpl_pick.value AS hpl_sigizi,
  CASE WHEN hpl_pick.value IS NOT NULL THEN hpl_pick.source_table END AS hpl_sigizi_source_table,
  delivery_pick.value AS delivery_sigizi,
  CASE WHEN delivery_pick.value IS NOT NULL THEN delivery_pick.source_table END AS delivery_sigizi_source_table,
  CASE WHEN hpht_pick.value IS NOT NULL THEN DATE_ADD(hpht_pick.value, INTERVAL 280 DAY) END AS hpl_from_sigizi_hpht,
  first_anc_date, last_anc_date,
  pregnancy_anchor_min_date, pregnancy_anchor_max_date, pregnancy_anchor_spread_days,
  (pregnancy_anchor_spread_days > sigizi_episode_anchor_tolerance_days) AS sigizi_episode_review_flag,
  sigizi_member_record_count, sigizi_source_tables, sigizi_member_source_record_ids,
  mother_identity_methods, sigizi_identity_propagated_record_count,
  sigizi_ambiguous_identity_record_count, sigizi_max_signature_row_count,
  sigizi_distinct_pregnancy_signature_count
FROM aggregated
),
source_id_quality AS (
  SELECT source_record_id, COUNT(*) AS id_occurrences
  FROM `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_source_records`
  GROUP BY source_record_id
),
anc_evidence AS (
  SELECT DISTINCT
    e.sigizi_episode_id,
    r.source_record_id,
    r.source_table,
    r.desa,
    r.desa_norm,
    r.posyandu,
    r.alamat,
    NULLIF(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          UPPER(TRIM(COALESCE(r.puskesmas_norm, ''))),
          r'^(UPTD?\s+)?(PUSKESMAS|PKM|PUSK)\s+',
          ''
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS facility_key
  FROM base_episodes e
  CROSS JOIN UNNEST(
    IFNULL(e.sigizi_member_source_record_ids, ARRAY<STRING>[])
  ) AS member_id
  JOIN `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_source_records` r
    ON member_id = r.source_record_id
   AND r.source_table = 'KESGA_BUMIL_ANC'
  JOIN source_id_quality q
    ON r.source_record_id = q.source_record_id
   AND q.id_occurrences = 1
  WHERE e.puskesmas_norm = 'DINAS KESEHATAN'
),
canonical_anc_facility AS (
  SELECT
    *,
    CASE
      WHEN facility_key = 'KARANG TENGAH' THEN 'KARANGTENGAH'
      WHEN facility_key IN ('KEMANGKON I', 'KEMANGKON 01') THEN 'KEMANGKON 1'
      WHEN facility_key IN ('KEMANGKON II', 'KEMANGKON 02') THEN 'KEMANGKON 2'
      ELSE facility_key
    END AS facility
  FROM anc_evidence
),
validated_anc_facility AS (
  SELECT
    *,
    facility IN (
      'SERAYU LARANGAN',
      'KARANGJAMBU', 'KALIGONDANG', 'BOBOTSARI',
      'BOJONG', 'KARANGTENGAH',
      'PURBALINGGA', 'BOJONGSARI', 'PADAMARA',
      'KARANGANYAR', 'PENGADEGAN', 'REMBANG',
      'KEMANGKON', 'KEMANGKON 1', 'KEMANGKON 2',
      'KALIKAJAR', 'KUTASARI', 'BUKATEJA', 'MREBET',
      'KARANGMONCOL', 'KARANGREJA', 'KEJOBONG',
      'KUTAWIS', 'KALIMANAH'
    ) AS is_project_facility
  FROM canonical_anc_facility
),
episode_facility_summary AS (
  SELECT
    sigizi_episode_id,
    COUNT(DISTINCT IF(is_project_facility, facility, NULL)) AS facility_count,
    COUNTIF(
      facility IS NOT NULL
      AND facility != 'DINAS KESEHATAN'
      AND NOT is_project_facility
    ) AS unmapped_records,
    ARRAY_AGG(
      IF(
        is_project_facility,
        STRUCT(
          facility AS puskesmas,
          facility AS puskesmas_norm,
          desa,
          desa_norm,
          posyandu,
          alamat,
          source_table,
          source_record_id
        ),
        NULL
      ) IGNORE NULLS
      ORDER BY source_record_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS selected_anc
  FROM validated_anc_facility
  GROUP BY sigizi_episode_id
),
location_resolution AS (
  SELECT
    b.*,
    s.selected_anc,
    (
      b.puskesmas_norm = 'DINAS KESEHATAN'
      AND s.facility_count = 1
      AND s.unmapped_records = 0
      AND s.selected_anc.puskesmas_norm IS NOT NULL
      AND s.selected_anc.puskesmas_norm != 'KEMANGKON'
    ) AS apply_location_fix
  FROM base_episodes b
  LEFT JOIN episode_facility_summary s
    USING (sigizi_episode_id)
)
SELECT
  * EXCEPT(selected_anc, apply_location_fix)
  REPLACE (
    IF(apply_location_fix, selected_anc.puskesmas, puskesmas)
      AS puskesmas,
    IF(apply_location_fix, selected_anc.puskesmas_norm, puskesmas_norm)
      AS puskesmas_norm,
    IF(apply_location_fix, selected_anc.desa, desa)
      AS desa,
    IF(apply_location_fix, selected_anc.desa_norm, desa_norm)
      AS desa_norm,
    IF(apply_location_fix, selected_anc.posyandu, posyandu)
      AS posyandu,
    IF(apply_location_fix, selected_anc.alamat, alamat)
      AS alamat,
    IF(
      apply_location_fix,
      'ANC_SINGLE_VALID_FACILITY_OVERRIDE',
      location_resolution_method
    ) AS location_resolution_method,
    IF(
      apply_location_fix,
      IF(selected_anc.desa_norm IS NOT NULL, 'VERY_HIGH', 'HIGH'),
      location_resolution_confidence
    ) AS location_resolution_confidence,
    IF(
      apply_location_fix,
      10 + IF(selected_anc.desa_norm IS NOT NULL, 5, 0)
         + IF(selected_anc.posyandu IS NOT NULL, 2, 0)
         + IF(selected_anc.alamat IS NOT NULL, 1, 0),
      location_resolution_score
    ) AS location_resolution_score,
    IF(apply_location_fix, selected_anc.source_table, location_source_table)
      AS location_source_table,
    IF(apply_location_fix, selected_anc.source_record_id, location_source_record_id)
      AS location_source_record_id
  )
FROM location_resolution;