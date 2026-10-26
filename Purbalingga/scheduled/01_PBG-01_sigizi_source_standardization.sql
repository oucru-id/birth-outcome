-- ============================================================================
-- PURBALINGGA PBG-01 | PRODUCTION | 2026-10-26
-- Writes to the ORIGINAL downstream reference:
--   stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_source_records
--
-- Retains original raw SiGizi JSON and Puskesmas name/ID provenance.
-- Only KESGA_BUMIL_ANC rows with administrative DINAS KESEHATAN
-- and a project-mapped puskesmas_domisili get corrected puskesmas_norm.
-- puskesmas_identity_raw/norm are audit fields ONLY; the downstream
-- PBG-02 identity uses corrected puskesmas_norm (validated CONTROL B).
--
-- DANGER: CREATE OR REPLACE TABLE overwrites production.
-- Take backups, pause scheduled queries, and validate candidates first.
-- ============================================================================

DECLARE analysis_date DATE DEFAULT CURRENT_DATE('Asia/Jakarta');
DECLARE minimum_valid_date DATE DEFAULT DATE '2010-01-01';
DECLARE maximum_hpl_date DATE DEFAULT DATE_ADD(analysis_date, INTERVAL 300 DAY);
CREATE TEMP FUNCTION norm_text(s STRING)
RETURNS STRING AS (
  NULLIF(REGEXP_REPLACE(UPPER(TRIM(NORMALIZE(COALESCE(s, ''), NFKC))), r'\s+', ' '), '')
);
CREATE TEMP FUNCTION clean_nik(s STRING)
RETURNS STRING AS (
  CASE WHEN REGEXP_CONTAINS(REGEXP_REPLACE(COALESCE(s,''), r'[^0-9]', ''), r'^\d{16}$')
    AND REGEXP_REPLACE(COALESCE(s,''), r'[^0-9]', '') NOT IN
      ('0000000000000000', '9999999999999999')
    THEN REGEXP_REPLACE(COALESCE(s,''), r'[^0-9]', '') END
);
CREATE TEMP FUNCTION clean_phone(s STRING)
RETURNS STRING AS (
  NULLIF(REGEXP_REPLACE(COALESCE(s, ''), r'[^0-9]', ''), '')
);
CREATE TEMP FUNCTION parse_date_any(s STRING)
RETURNS DATE AS (
CASE
 WHEN NULLIF(TRIM(s), '') IS NULL THEN NULL
 WHEN REGEXP_CONTAINS(TRIM(s), r'^\d{4}-\d{1,2}-\d{1,2}$')
   THEN SAFE.PARSE_DATE('%Y-%m-%d', TRIM(s))
 WHEN REGEXP_CONTAINS(TRIM(s), r'^\d{4}/\d{1,2}/\d{1,2}$')
   THEN SAFE.PARSE_DATE('%Y/%m/%d', TRIM(s))
 WHEN REGEXP_CONTAINS(TRIM(s), r'^\d{1,2}-\d{1,2}-\d{4}$')
   THEN SAFE.PARSE_DATE('%d-%m-%Y', TRIM(s))
 WHEN REGEXP_CONTAINS(TRIM(s), r'^\d{1,2}/\d{1,2}/\d{4}$')
   THEN SAFE.PARSE_DATE('%d/%m/%Y', TRIM(s))
 WHEN REGEXP_CONTAINS(TRIM(s), r'^\d{1,2}-\d{1,2}-\d{2}$')
   THEN SAFE.PARSE_DATE('%d-%m-%Y', CONCAT(
     SPLIT(TRIM(s), '-')[SAFE_OFFSET(0)], '-',
     SPLIT(TRIM(s), '-')[SAFE_OFFSET(1)], '-',
     CAST(CASE WHEN SAFE_CAST(SPLIT(TRIM(s), '-')[SAFE_OFFSET(2)] AS INT64) <= 39
       THEN 2000 + SAFE_CAST(SPLIT(TRIM(s), '-')[SAFE_OFFSET(2)] AS INT64)
       ELSE 1900 + SAFE_CAST(SPLIT(TRIM(s), '-')[SAFE_OFFSET(2)] AS INT64)
     END AS STRING)))
 WHEN REGEXP_CONTAINS(TRIM(s), r'^\d{1,2}/\d{1,2}/\d{2}$')
   THEN SAFE.PARSE_DATE('%d/%m/%Y', CONCAT(
     SPLIT(TRIM(s), '/')[SAFE_OFFSET(0)], '/',
     SPLIT(TRIM(s), '/')[SAFE_OFFSET(1)], '/',
     CAST(CASE WHEN SAFE_CAST(SPLIT(TRIM(s), '/')[SAFE_OFFSET(2)] AS INT64) <= 39
       THEN 2000 + SAFE_CAST(SPLIT(TRIM(s), '/')[SAFE_OFFSET(2)] AS INT64)
       ELSE 1900 + SAFE_CAST(SPLIT(TRIM(s), '/')[SAFE_OFFSET(2)] AS INT64)
     END AS STRING)))
 WHEN REGEXP_CONTAINS(TRIM(s), r'^[A-Za-z]{3}\s+\d{1,2},\s+\d{4}$')
   THEN SAFE.PARSE_DATE('%b %e, %Y', TRIM(s))
 WHEN REGEXP_CONTAINS(TRIM(s), r'^[A-Za-z]+\s+\d{1,2},\s+\d{4}$')
   THEN SAFE.PARSE_DATE('%B %e, %Y', TRIM(s))
 WHEN REGEXP_CONTAINS(TRIM(s), r'^\d{4}-\d{1,2}-\d{1,2}[ T]')
   THEN SAFE.PARSE_DATE('%Y-%m-%d', REGEXP_EXTRACT(TRIM(s), r'^(\d{4}-\d{1,2}-\d{1,2})'))
 WHEN REGEXP_CONTAINS(TRIM(s), r'^\d{5}(?:\.0+)?$')
   THEN DATE_ADD(DATE '1899-12-30', INTERVAL SAFE_CAST(REGEXP_EXTRACT(TRIM(s), r'^\d+') AS INT64) DAY)
 ELSE NULL
END
);
CREATE TEMP FUNCTION parse_timestamp_any(s STRING)
RETURNS TIMESTAMP AS (
  COALESCE(
    SAFE_CAST(NULLIF(TRIM(s), '') AS TIMESTAMP),
    SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S', NULLIF(TRIM(s), '')),
    SAFE.PARSE_TIMESTAMP('%Y-%m-%d %H:%M:%E*S', NULLIF(TRIM(s), ''))
  )
);
CREATE OR REPLACE TABLE `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_source_records`
CLUSTER BY source_table, nik_clean, puskesmas_norm AS
WITH source_union AS (
  SELECT 'DAFTAR_BUMIL' AS source_table, 1 AS source_priority,
    TRUE AS pregnancy_episode_creator_flag, 'PREGNANCY_SPINE' AS source_role,
    TO_JSON_STRING(t) AS source_json
  FROM `stellar-orb-451904-d9.raw_data.sigizi_daftar_bumil` t
  UNION ALL
  SELECT 'KESGA_BUMIL_ANC', 2, TRUE, 'PREGNANCY_SPINE', TO_JSON_STRING(t)
  FROM `stellar-orb-451904-d9.raw_data.sigizi_kesga_bumil_anc` t
  UNION ALL
  SELECT 'KOHORT_IBU', 3, TRUE, 'PREGNANCY_AND_OUTCOME', TO_JSON_STRING(t)
  FROM `stellar-orb-451904-d9.raw_data.sigizi_kohort_ibu` t
  UNION ALL
  SELECT 'KESGA_BUMIL', 4, TRUE, 'PREGNANCY_SPINE', TO_JSON_STRING(t)
  FROM `stellar-orb-451904-d9.raw_data.sigizi_kesga_bumil` t
  UNION ALL
  SELECT 'IBU_NIFAS', 5, FALSE, 'OUTCOME_ENRICHMENT', TO_JSON_STRING(t)
  FROM `stellar-orb-451904-d9.raw_data.sigizi_ibu_nifas` t
),
extracted AS (
 SELECT source_table, source_priority, pregnancy_episode_creator_flag, source_role,
   CONCAT('SIGIZI_', source_table) AS data_source,
   COALESCE(
     NULLIF(JSON_VALUE(source_json, '$.uuid'), ''),
     NULLIF(JSON_VALUE(source_json, '$.hash_code'), ''),
     NULLIF(JSON_VALUE(source_json, '$.id'), ''),
     NULLIF(JSON_VALUE(source_json, '$.no'), ''),
     CAST(FARM_FINGERPRINT(source_json) AS STRING)
   ) AS source_record_id,
   COALESCE(
     NULLIF(JSON_VALUE(source_json, '$.nik'), ''),
     NULLIF(JSON_VALUE(source_json, '$.nik_ibu'), ''),
     NULLIF(JSON_VALUE(source_json, '$.no_ktp'), ''),
     NULLIF(JSON_VALUE(source_json, '$.nik_nik'), ''),
     NULLIF(JSON_VALUE(source_json, '$.nik_nik_nik'), '')
   ) AS nik_raw,
   COALESCE(
     NULLIF(JSON_VALUE(source_json, '$.nama'), ''),
     NULLIF(JSON_VALUE(source_json, '$.nama_ibu'), ''),
     NULLIF(JSON_VALUE(source_json, '$.nama_pasien'), ''),
     NULLIF(JSON_VALUE(source_json, '$.nama_nama'), ''),
     NULLIF(JSON_VALUE(source_json, '$.nama_nama_nama'), '')
   ) AS nama_raw,
   COALESCE(
     NULLIF(JSON_VALUE(source_json, '$.tanggal_lahir'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tgl_lahir'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tanggal_lahir_tanggal_lahir'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tanggal_lahir_tanggal_lahir_tanggal_lahir'), '')
   ) AS dob_raw,
   COALESCE(
     NULLIF(JSON_VALUE(source_json, '$.hpht'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tgl_hpht'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tanggal_hpht'), ''),
     NULLIF(JSON_VALUE(source_json, '$.hpht_hpht'), ''),
     NULLIF(JSON_VALUE(source_json, '$.hpht_hpht_hpht'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tanggal_hpht_tanggal_hpht'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tanggal_hpht_tanggal_hpht_tanggal_hpht'), '')
   ) AS hpht_raw,
   COALESCE(
     NULLIF(JSON_VALUE(source_json, '$.hpl'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tanggal_perkiraan_persalinan'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tanggal_taksiran_persalinan'), ''),
     NULLIF(JSON_VALUE(source_json, '$.pemeriksaan_anc_tanggal_perkiraan_persalinan'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tanggal_perkiraan_persalinan_tanggal_perkiraan_persalinan'), '')
   ) AS hpl_raw,
   COALESCE(
     NULLIF(JSON_VALUE(source_json, '$.tanggal_anc'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tgl_anc'), ''),
     NULLIF(JSON_VALUE(source_json, '$.pemeriksaan_anc_tanggal_anc'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tanggal_anc_tanggal_anc'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tanggal_anc_tanggal_anc_tanggal_anc'), '')
   ) AS anc_raw,
   COALESCE(
     NULLIF(JSON_VALUE(source_json, '$.status_persalinan_tanggal_melahirkan'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tgl_melahirkan'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tanggal_melahirkan'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tanggal_persalinan'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tgl_persalinan'), '')
   ) AS delivery_raw,
   COALESCE(
     NULLIF(JSON_VALUE(source_json, '$.tgl_abortus'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tanggal_abortus'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tanggal_keguguran'), '')
   ) AS abortion_raw,
   COALESCE(
     NULLIF(JSON_VALUE(source_json, '$.puskesmas_name'), ''),
     NULLIF(JSON_VALUE(source_json, '$.puskesmas'), ''),
     NULLIF(JSON_VALUE(source_json, '$.puskesmas_domisili'), ''),
     NULLIF(JSON_VALUE(source_json, '$.puskesmas_domisili_puskesmas_domisili'), ''),
     NULLIF(JSON_VALUE(source_json, '$.puskesmas_domisili_puskesmas_domisili_puskesmas_domisili'), ''),
     NULLIF(JSON_VALUE(source_json, '$.faskes_yang_melayani_anc'), '')
   ) AS puskesmas_raw,
   COALESCE(
     NULLIF(JSON_VALUE(source_json, '$.puskesmas_id'), ''),
     NULLIF(JSON_VALUE(source_json, '$.id_puskesmas'), '')
   ) AS puskesmas_id_raw,
   COALESCE(
     NULLIF(JSON_VALUE(source_json, '$.desa'), ''),
     NULLIF(JSON_VALUE(source_json, '$.nama_desa'), ''),
     NULLIF(JSON_VALUE(source_json, '$.desakel'), ''),
     NULLIF(JSON_VALUE(source_json, '$.desakelurahan'), ''),
     NULLIF(JSON_VALUE(source_json, '$.desa_domisili'), ''),
     NULLIF(JSON_VALUE(source_json, '$.desakel_domisili'), ''),
     NULLIF(JSON_VALUE(source_json, '$.desakel_domisili_desakel_domisili'), ''),
     NULLIF(JSON_VALUE(source_json, '$.desakel_domisili_desakel_domisili_desakel_domisili'), '')
   ) AS desa_raw,
   COALESCE(
     NULLIF(JSON_VALUE(source_json, '$.posyandu'), ''),
     NULLIF(JSON_VALUE(source_json, '$.posyandu_domisili'), ''),
     NULLIF(JSON_VALUE(source_json, '$.posyandu_domisili_posyandu_domisili'), ''),
     NULLIF(JSON_VALUE(source_json, '$.posyandu_domisili_posyandu_domisili_posyandu_domisili'), '')
   ) AS posyandu_raw,
   COALESCE(
     NULLIF(JSON_VALUE(source_json, '$.alamat'), ''),
     NULLIF(JSON_VALUE(source_json, '$.alamat_domisili'), ''),
     NULLIF(JSON_VALUE(source_json, '$.alamat_domisili_alamat_domisili'), ''),
     NULLIF(JSON_VALUE(source_json, '$.alamat_domisili_alamat_domisili_alamat_domisili'), '')
   ) AS alamat_raw,
   COALESCE(
     NULLIF(JSON_VALUE(source_json, '$.no_hp'), ''),
     NULLIF(JSON_VALUE(source_json, '$.nomor_hp'), ''),
     NULLIF(JSON_VALUE(source_json, '$.no_telepon_ibu'), ''),
     NULLIF(JSON_VALUE(source_json, '$.no_telepon'), ''),
     NULLIF(JSON_VALUE(source_json, '$.telepon'), '')
   ) AS no_hp_raw,
   COALESCE(
     NULLIF(JSON_VALUE(source_json, '$.status_persalinan_lahir_hidup_lahir_mati'), ''),
     NULLIF(JSON_VALUE(source_json, '$.luaran_kehamilan'), ''),
     NULLIF(JSON_VALUE(source_json, '$.luaran'), ''),
     NULLIF(JSON_VALUE(source_json, '$.status_kelahiran'), ''),
     NULLIF(JSON_VALUE(source_json, '$.status'), '')
   ) AS outcome_raw,
   COALESCE(
     NULLIF(JSON_VALUE(source_json, '$.file_name'), ''),
     NULLIF(JSON_VALUE(source_json, '$.nama_file'), '')
   ) AS file_name,
   COALESCE(
     NULLIF(JSON_VALUE(source_json, '$.file_date'), ''),
     NULLIF(JSON_VALUE(source_json, '$.tanggal_file'), '')
   ) AS file_date_raw,
   NULLIF(JSON_VALUE(source_json, '$.ingestion_timestamp'), '') AS ingestion_timestamp_raw,
   source_json
 FROM source_union
),
-- INSERTED CTEs: Only administrative DINAS KESEHATAN on KESGA_BUMIL_ANC.
location_base AS (
 SELECT
   e.*,
   e.puskesmas_raw AS puskesmas_identity_raw,
   REGEXP_REPLACE(
     norm_text(COALESCE(
       NULLIF(TRIM(JSON_VALUE(e.source_json, '$.puskesmas_domisili')), ''),
       NULLIF(TRIM(JSON_VALUE(e.source_json, '$.puskesmas_domisili_puskesmas_domisili')), ''),
       NULLIF(TRIM(JSON_VALUE(e.source_json,
         '$.puskesmas_domisili_puskesmas_domisili_puskesmas_domisili')), '')
     )),
     r'^(UPTD?\s+)?(PUSKESMAS|PKM|PUSK)\s+',
     ''
   ) AS domicile_key
 FROM extracted e
),
location_corrected AS (
 SELECT
   * EXCEPT(puskesmas_raw, domicile_key),
   CASE
     WHEN source_table = 'KESGA_BUMIL_ANC'
       AND norm_text(puskesmas_raw) = 'DINAS KESEHATAN'
       AND domicile_key IN (
         'SERAYU LARANGAN', 'KARANGJAMBU', 'KALIGONDANG',
         'BOBOTSARI', 'BOJONG', 'KARANGTENGAH', 'KARANG TENGAH',
         'PURBALINGGA', 'BOJONGSARI', 'PADAMARA', 'KARANGANYAR',
         'PENGADEGAN', 'REMBANG', 'KEMANGKON', 'KEMANGKON 1',
         'KEMANGKON 2', 'KEMANGKON I', 'KEMANGKON II',
         'KEMANGKON 01', 'KEMANGKON 02', 'KALIKAJAR',
         'KUTASARI', 'BUKATEJA', 'MREBET', 'KARANGMONCOL',
         'KARANGREJA', 'KEJOBONG', 'KUTAWIS', 'KALIMANAH'
       )
     THEN CASE
       WHEN domicile_key = 'KARANG TENGAH' THEN 'KARANGTENGAH'
       WHEN domicile_key IN ('KEMANGKON I', 'KEMANGKON 01') THEN 'KEMANGKON 1'
       WHEN domicile_key IN ('KEMANGKON II', 'KEMANGKON 02') THEN 'KEMANGKON 2'
       ELSE domicile_key
     END
     ELSE puskesmas_raw
   END AS puskesmas_raw
 FROM location_base
),
parsed AS (
 SELECT *,
   clean_nik(nik_raw) AS nik_clean_parsed,
   norm_text(nama_raw) AS nama_norm,
   parse_date_any(dob_raw) AS tanggal_lahir_parsed,
   parse_date_any(hpht_raw) AS hpht_date_parsed,
   parse_date_any(hpl_raw) AS hpl_date_parsed,
   parse_date_any(anc_raw) AS anc_date_parsed,
   parse_date_any(delivery_raw) AS delivery_date_parsed,
   parse_date_any(abortion_raw) AS abortion_date_parsed,
   norm_text(puskesmas_raw) AS puskesmas_norm,
   norm_text(puskesmas_identity_raw) AS puskesmas_identity_norm,
   norm_text(desa_raw) AS desa_norm,
   norm_text(posyandu_raw) AS posyandu_norm,
   clean_phone(no_hp_raw) AS no_hp_clean,
   parse_date_any(file_date_raw) AS file_date,
   parse_timestamp_any(ingestion_timestamp_raw) AS ingestion_timestamp
 FROM location_corrected
),
validated AS (
 SELECT *,
   CASE WHEN tanggal_lahir_parsed BETWEEN DATE '1940-01-01' AND analysis_date
     THEN tanggal_lahir_parsed END AS tanggal_lahir,
   CASE WHEN hpht_date_parsed BETWEEN minimum_valid_date AND analysis_date
     THEN hpht_date_parsed END AS hpht_date,
   CASE WHEN hpl_date_parsed BETWEEN minimum_valid_date AND maximum_hpl_date
     THEN hpl_date_parsed END AS hpl_date,
   CASE WHEN anc_date_parsed BETWEEN minimum_valid_date AND analysis_date
     THEN anc_date_parsed END AS anc_date,
   CASE WHEN delivery_date_parsed BETWEEN minimum_valid_date AND analysis_date
     THEN delivery_date_parsed END AS delivery_date,
   CASE WHEN abortion_date_parsed BETWEEN minimum_valid_date AND analysis_date
     THEN abortion_date_parsed END AS abortion_date
 FROM parsed
),
final AS (
 SELECT
   'SIGIZI' AS source_system,
   source_table,
   source_priority,
   data_source,
   source_role,
   pregnancy_episode_creator_flag,
   source_record_id,
   nik_raw,
   nik_clean_parsed AS nik_clean,
   nik_clean_parsed IS NOT NULL AS flag_nik_valid,
   nama_raw AS nama,
   nama_norm,
   tanggal_lahir,
   hpht_date,
   hpl_date,
   anc_date,
   delivery_date,
   abortion_date,
   puskesmas_raw AS puskesmas,
   puskesmas_norm,
   puskesmas_identity_raw,
   puskesmas_identity_norm,
   puskesmas_id_raw AS puskesmas_id,
   desa_raw AS desa,
   desa_norm,
   posyandu_raw AS posyandu,
   posyandu_norm,
   alamat_raw AS alamat,
   no_hp_raw AS no_hp,
   no_hp_clean,
   outcome_raw,
   file_name,
   file_date,
   ingestion_timestamp,
   ingestion_timestamp_raw,
   dob_raw,
   hpht_raw,
   hpl_raw,
   anc_raw,
   delivery_raw,
   abortion_raw,
   file_date_raw,
   tanggal_lahir_parsed,
   hpht_date_parsed,
   hpl_date_parsed,
   anc_date_parsed,
   delivery_date_parsed,
   abortion_date_parsed,
   (tanggal_lahir_parsed IS NOT NULL AND tanggal_lahir IS NULL) AS dob_invalid_date_flag,
   (hpht_date_parsed IS NOT NULL AND hpht_date IS NULL) AS hpht_invalid_date_flag,
   (hpl_date_parsed IS NOT NULL AND hpl_date IS NULL) AS hpl_invalid_date_flag,
   (anc_date_parsed IS NOT NULL AND anc_date IS NULL) AS anc_invalid_date_flag,
   (delivery_date_parsed IS NOT NULL AND delivery_date IS NULL) AS delivery_invalid_date_flag,
   (abortion_date_parsed IS NOT NULL AND abortion_date IS NULL) AS abortion_invalid_date_flag,
   (hpht_date_parsed > analysis_date) AS hpht_future_flag,
   (anc_date_parsed > analysis_date) AS anc_future_flag,
   (delivery_date_parsed > analysis_date) AS delivery_future_flag,
   (abortion_date_parsed > analysis_date) AS abortion_future_flag,
   (hpht_date IS NOT NULL OR hpl_date IS NOT NULL) AS has_pregnancy_dating_flag,
   CASE
     WHEN hpl_date IS NOT NULL THEN 'RECORDED_HPL'
     WHEN hpht_date IS NOT NULL THEN 'HPHT'
     ELSE NULL
   END AS pregnancy_dating_available_source,
   CASE
     WHEN hpl_date IS NOT NULL THEN hpl_date
     WHEN hpht_date IS NOT NULL THEN DATE_ADD(hpht_date, INTERVAL 280 DAY)
     ELSE NULL
   END AS source_expected_delivery_date,
   CASE
     WHEN hpl_date IS NOT NULL THEN 'RECORDED_HPL_SIGIZI'
     WHEN hpht_date IS NOT NULL THEN 'HPHT_PLUS_280_SIGIZI'
     ELSE NULL
   END AS source_expected_delivery_date_method,
   (delivery_date IS NOT NULL) AS has_delivery_date_flag,
   (abortion_date IS NOT NULL) AS has_abortion_date_flag,
   (outcome_raw IS NOT NULL) AS has_outcome_evidence_flag,
   CAST(NULL AS STRING) AS source_dedup_method,
   CAST(NULL AS STRING) AS source_mother_match_method,
   source_json
 FROM validated
)
SELECT * FROM final
WHERE nik_clean IS NOT NULL
 OR nama_norm IS NOT NULL
 OR hpht_date IS NOT NULL
 OR hpl_date IS NOT NULL
 OR anc_date IS NOT NULL
 OR delivery_date IS NOT NULL
 OR abortion_date IS NOT NULL
 OR outcome_raw IS NOT NULL;