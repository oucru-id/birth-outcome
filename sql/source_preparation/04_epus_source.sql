-- Recovered source builder; v3 target. Run the complete file.
-- StandardSQL
-- ============================================================
-- ePUSKESMAS CORE SOURCE RECORDS
--
-- Grain:
--   one row = one normalized source event
--
-- Sources:
--   1. EPUS_ANC
--   2. EPUS_KUNJUNGAN_IBU_HAMIL
--   3. EPUS_INC
--   4. EPUS_PNC
--
-- IMPORTANT:
-- This table does NOT yet:
--   - merge mothers across sources
--   - assign pregnancy episodes
--   - deduplicate ANC across EPUS_ANC vs EPUS_KUNJUNGAN
--
-- Those happen in the next layers.
-- ============================================================

CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_epus_source_records`

PARTITION BY event_date

CLUSTER BY
  source_table,
  event_type,
  nik_clean,
  puskesmas_norm

AS


WITH source_union AS (

  -- ==========================================================
  -- 1. EPUS ANC
  --
  -- Grain:
  -- one row = one ANC encounter
  -- ==========================================================
  SELECT
    'EPUS_ANC'
      AS source_table,

    'spheres-lombok-barat.raw_data.epus_anc'
      AS raw_source_table,

    'spheres-lombok-barat.kohort_bumil_v3.vs_epus_anc'
      AS source_view,

    'ANC'
      AS event_type,

    'ANC_VISIT'
      AS record_grain,

    -- Priority only intended for resolving the same ANC event
    -- across EPUS_ANC and EPUS_KUNJUNGAN later.
    1
      AS same_event_source_priority,

    CAST(a.kunjungan_k_clean AS STRING)
      AS visit_label,


    -- --------------------------------------------------------
    -- Source lineage
    -- --------------------------------------------------------
    CAST(a.source_record_id AS STRING)
      AS source_record_id,

    CAST(a.anc_encounter_key AS STRING)
      AS source_event_identity,

    CAST(a.dedup_method AS STRING)
      AS source_dedup_method,

    CAST(a.raw_encounter_record_count AS INT64)
      AS source_raw_record_count,

    CAST(a.exact_duplicate_count AS INT64)
      AS source_exact_duplicate_count,

    CAST(a.encounter_variant_count AS INT64)
      AS source_encounter_variant_count,

    CAST(a.is_duplicate_group AS BOOL)
      AS source_is_duplicate_group,

    CAST(a.row_completeness_score AS INT64)
      AS source_row_completeness_score,

    CAST(a.source_row_hash AS INT64)
      AS source_row_hash,

    CAST(a.clinical_content_hash AS STRING)
      AS clinical_content_hash,


    -- --------------------------------------------------------
    -- Source recency / ingestion
    -- --------------------------------------------------------
    CAST(a.file_name AS STRING)
      AS file_name,

    CAST(a.file_date_parsed AS DATE)
      AS file_date_parsed,

    CAST(a.ingestion_timestamp_parsed AS TIMESTAMP)
      AS ingestion_timestamp_parsed,

    CAST(a.source_recency_timestamp AS TIMESTAMP)
      AS source_recency_timestamp,

    CAST(a.uuid AS STRING)
      AS source_uuid,

    CAST(a.hash_code AS STRING)
      AS source_hash_code,


    -- --------------------------------------------------------
    -- Identity
    -- --------------------------------------------------------
    CAST(a.nik AS STRING)
      AS nik_raw,

    CAST(a.nik_clean AS STRING)
      AS nik_candidate,

    CAST(a.flag_nik_valid_16_digit AS BOOL)
      AS flag_nik_valid,

    CAST(a.nama_pasien AS STRING)
      AS nama_raw,

    CAST(a.nama_pasien_clean AS STRING)
      AS nama_clean_source,

    CAST(a.tanggal_lahir_date AS DATE)
      AS tanggal_lahir,


    -- --------------------------------------------------------
    -- Pregnancy dating evidence
    -- --------------------------------------------------------
    CAST(a.tanggal_hpht_date AS DATE)
      AS hpht_date,

    CAST(a.tanggal_taksiran_persalinan_date AS DATE)
      AS hpl_date,

    CAST(a.tanggal_persalinan_sebelumnya_date AS DATE)
      AS previous_delivery_date,


    -- --------------------------------------------------------
    -- Event date
    -- --------------------------------------------------------
    CAST(a.tanggal_antenatal_date AS DATE)
      AS event_date,

    'TANGGAL_ANTENATAL'
      AS event_date_source,

    CAST(a.tanggal_antenatal_date AS DATE)
      AS anc_date,

    CAST(NULL AS DATE)
      AS delivery_date,

    CAST(NULL AS STRING)
      AS delivery_date_source,

    CAST(NULL AS DATE)
      AS pnc_date,


    -- --------------------------------------------------------
    -- Location/contact
    -- --------------------------------------------------------
    CAST(a.puskesmas_name AS STRING)
      AS puskesmas_raw,

    CAST(a.puskesmas_name_clean AS STRING)
      AS puskesmas_clean_source,

    CAST(a.puskesmas_id_clean AS STRING)
      AS puskesmas_id,

    CAST(NULL AS STRING)
      AS alamat,

    CAST(NULL AS STRING)
      AS no_hp_raw

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_epus_anc` a



  UNION ALL



  -- ==========================================================
  -- 2. EPUS KUNJUNGAN IBU HAMIL
  --
  -- Grain:
  -- one row = one ANC-like pregnancy visit
  --
  -- This may overlap with EPUS_ANC.
  -- Cross-source overlap is NOT removed here.
  -- ==========================================================
  SELECT
    'EPUS_KUNJUNGAN_IBU_HAMIL'
      AS source_table,

    'spheres-lombok-barat.raw_data.epus_kunjungan_ibu_hamil'
      AS raw_source_table,

    'spheres-lombok-barat.kohort_bumil_v3.vs_kohort_epus_kunjungan_ibu_hamil'
      AS source_view,

    'ANC'
      AS event_type,

    'ANC_VISIT'
      AS record_grain,

    2
      AS same_event_source_priority,

    CAST(NULL AS STRING)
      AS visit_label,


    -- --------------------------------------------------------
    -- Source lineage
    -- --------------------------------------------------------
    CAST(k.source_record_id AS STRING)
      AS source_record_id,

    CAST(k.anc_encounter_key AS STRING)
      AS source_event_identity,

    CAST(k.dedup_method AS STRING)
      AS source_dedup_method,

    CAST(k.raw_encounter_record_count AS INT64)
      AS source_raw_record_count,

    CAST(k.exact_duplicate_count AS INT64)
      AS source_exact_duplicate_count,

    CAST(k.encounter_variant_count AS INT64)
      AS source_encounter_variant_count,

    CAST(k.is_duplicate_group AS BOOL)
      AS source_is_duplicate_group,

    CAST(k.row_completeness_score AS INT64)
      AS source_row_completeness_score,

    CAST(k.source_row_hash AS INT64)
      AS source_row_hash,

    CAST(k.clinical_content_hash AS STRING)
      AS clinical_content_hash,


    -- --------------------------------------------------------
    -- Source recency / ingestion
    -- --------------------------------------------------------
    CAST(k.file_name AS STRING)
      AS file_name,

    CAST(k.file_date_parsed AS DATE)
      AS file_date_parsed,

    CAST(k.ingestion_timestamp_parsed AS TIMESTAMP)
      AS ingestion_timestamp_parsed,

    CAST(k.source_recency_timestamp AS TIMESTAMP)
      AS source_recency_timestamp,

    CAST(k.uuid AS STRING)
      AS source_uuid,

    CAST(k.hash_code AS STRING)
      AS source_hash_code,


    -- --------------------------------------------------------
    -- Identity
    -- --------------------------------------------------------
    CAST(k.register_nik AS STRING)
      AS nik_raw,

    CAST(k.nik_clean AS STRING)
      AS nik_candidate,

    CAST(k.flag_nik_valid_16_digit AS BOOL)
      AS flag_nik_valid,

    CAST(k.register_nama_ibu AS STRING)
      AS nama_raw,

    CAST(k.nama_ibu_clean AS STRING)
      AS nama_clean_source,

    CAST(k.tanggal_lahir_date AS DATE)
      AS tanggal_lahir,


    -- --------------------------------------------------------
    -- Pregnancy dating evidence
    -- --------------------------------------------------------
    CAST(k.tanggal_hpht_date AS DATE)
      AS hpht_date,

    CAST(k.tanggal_hpl_date AS DATE)
      AS hpl_date,

    CAST(NULL AS DATE)
      AS previous_delivery_date,


    -- --------------------------------------------------------
    -- Event
    -- --------------------------------------------------------
    CAST(k.anc_visit_date AS DATE)
      AS event_date,

    'REGISTER_TANGGAL'
      AS event_date_source,

    CAST(k.anc_visit_date AS DATE)
      AS anc_date,

    CAST(NULL AS DATE)
      AS delivery_date,

    CAST(NULL AS STRING)
      AS delivery_date_source,

    CAST(NULL AS DATE)
      AS pnc_date,


    -- --------------------------------------------------------
    -- Location/contact
    -- --------------------------------------------------------
    CAST(k.puskesmas_name AS STRING)
      AS puskesmas_raw,

    CAST(k.puskesmas_name_clean AS STRING)
      AS puskesmas_clean_source,

    CAST(k.puskesmas_id_clean AS STRING)
      AS puskesmas_id,

    CAST(k.register_alamat AS STRING)
      AS alamat,

    CAST(k.register_no_telp AS STRING)
      AS no_hp_raw

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_kohort_epus_kunjungan_ibu_hamil` k



  UNION ALL



  -- ==========================================================
  -- 3. EPUS INC
  --
  -- Grain:
  -- one row = one safely distinguishable delivery/baby record
  -- ==========================================================
  SELECT
    'EPUS_INC'
      AS source_table,

    'spheres-lombok-barat.raw_data.epus_inc'
      AS raw_source_table,

    'spheres-lombok-barat.kohort_bumil_v3.vs_epus_inc'
      AS source_view,

    'DELIVERY'
      AS event_type,

    'DELIVERY_BABY_RECORD'
      AS record_grain,

    1
      AS same_event_source_priority,

    CAST(NULL AS STRING)
      AS visit_label,


    -- --------------------------------------------------------
    -- Source lineage
    -- --------------------------------------------------------
    CAST(i.source_record_id AS STRING)
      AS source_record_id,

    CAST(i.inc_encounter_key AS STRING)
      AS source_event_identity,

    CAST(i.dedup_method AS STRING)
      AS source_dedup_method,

    CAST(i.raw_encounter_record_count AS INT64)
      AS source_raw_record_count,

    CAST(i.exact_duplicate_count AS INT64)
      AS source_exact_duplicate_count,

    CAST(i.encounter_variant_count AS INT64)
      AS source_encounter_variant_count,

    CAST(i.is_duplicate_group AS BOOL)
      AS source_is_duplicate_group,

    CAST(i.row_completeness_score AS INT64)
      AS source_row_completeness_score,

    CAST(i.source_row_hash AS INT64)
      AS source_row_hash,

    CAST(i.clinical_content_hash AS STRING)
      AS clinical_content_hash,


    -- --------------------------------------------------------
    -- Source recency / ingestion
    -- --------------------------------------------------------
    CAST(i.file_name AS STRING)
      AS file_name,

    CAST(i.file_date_parsed AS DATE)
      AS file_date_parsed,

    CAST(i.ingestion_timestamp_parsed AS TIMESTAMP)
      AS ingestion_timestamp_parsed,

    CAST(i.source_recency_timestamp AS TIMESTAMP)
      AS source_recency_timestamp,

    CAST(i.uuid AS STRING)
      AS source_uuid,

    CAST(i.hash_code AS STRING)
      AS source_hash_code,


    -- --------------------------------------------------------
    -- Identity
    -- --------------------------------------------------------
    CAST(i.nik AS STRING)
      AS nik_raw,

    CAST(i.nik_clean AS STRING)
      AS nik_candidate,

    CAST(i.flag_nik_valid_16_digit AS BOOL)
      AS flag_nik_valid,

    CAST(i.nama_pasien AS STRING)
      AS nama_raw,

    CAST(i.nama_pasien_clean AS STRING)
      AS nama_clean_source,

    CAST(i.tanggal_lahir_date AS DATE)
      AS tanggal_lahir,


    -- --------------------------------------------------------
    -- Pregnancy dating evidence
    -- --------------------------------------------------------
    CAST(i.tanggal_hpht_date AS DATE)
      AS hpht_date,

    CAST(i.tanggal_taksiran_persalinan_date AS DATE)
      AS hpl_date,

    CAST(i.tanggal_persalinan_sebelumnya_date AS DATE)
      AS previous_delivery_date,


    -- --------------------------------------------------------
    -- Delivery event
    -- --------------------------------------------------------
    CAST(i.delivery_event_date AS DATE)
      AS event_date,

    CAST(i.delivery_event_date_source AS STRING)
      AS event_date_source,

    CAST(NULL AS DATE)
      AS anc_date,

    CAST(i.delivery_event_date AS DATE)
      AS delivery_date,

    CAST(i.delivery_event_date_source AS STRING)
      AS delivery_date_source,

    CAST(NULL AS DATE)
      AS pnc_date,


    -- --------------------------------------------------------
    -- Location/contact
    -- --------------------------------------------------------
    CAST(i.puskesmas_name AS STRING)
      AS puskesmas_raw,

    CAST(i.puskesmas_name_clean AS STRING)
      AS puskesmas_clean_source,

    CAST(i.puskesmas_id_clean AS STRING)
      AS puskesmas_id,

    CAST(NULL AS STRING)
      AS alamat,

    CAST(NULL AS STRING)
      AS no_hp_raw

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_epus_inc` i



  UNION ALL



  -- ==========================================================
  -- 4. EPUS PNC
  --
  -- Grain:
  -- one row = one PNC/KF visit
  -- ==========================================================
  SELECT
    'EPUS_PNC'
      AS source_table,

    'spheres-lombok-barat.raw_data.epus_pnc'
      AS raw_source_table,

    'spheres-lombok-barat.kohort_bumil_v3.vs_epus_pnc'
      AS source_view,

    'PNC'
      AS event_type,

    'PNC_VISIT'
      AS record_grain,

    1
      AS same_event_source_priority,

    CAST(p.kunjungan_kf_clean AS STRING)
      AS visit_label,


    -- --------------------------------------------------------
    -- Source lineage
    -- --------------------------------------------------------
    CAST(p.source_record_id AS STRING)
      AS source_record_id,

    CAST(p.pnc_encounter_key AS STRING)
      AS source_event_identity,

    CAST(p.dedup_method AS STRING)
      AS source_dedup_method,

    CAST(p.raw_encounter_record_count AS INT64)
      AS source_raw_record_count,

    CAST(p.exact_duplicate_count AS INT64)
      AS source_exact_duplicate_count,

    CAST(p.encounter_variant_count AS INT64)
      AS source_encounter_variant_count,

    CAST(p.is_duplicate_group AS BOOL)
      AS source_is_duplicate_group,

    CAST(p.row_completeness_score AS INT64)
      AS source_row_completeness_score,

    CAST(p.source_row_hash AS INT64)
      AS source_row_hash,

    CAST(p.clinical_content_hash AS STRING)
      AS clinical_content_hash,


    -- --------------------------------------------------------
    -- Source recency / ingestion
    -- --------------------------------------------------------
    CAST(p.file_name AS STRING)
      AS file_name,

    CAST(p.file_date_parsed AS DATE)
      AS file_date_parsed,

    CAST(p.ingestion_timestamp_parsed AS TIMESTAMP)
      AS ingestion_timestamp_parsed,

    CAST(p.source_recency_timestamp AS TIMESTAMP)
      AS source_recency_timestamp,

    CAST(p.uuid AS STRING)
      AS source_uuid,

    CAST(p.hash_code AS STRING)
      AS source_hash_code,


    -- --------------------------------------------------------
    -- Identity
    -- --------------------------------------------------------
    CAST(p.nik AS STRING)
      AS nik_raw,

    CAST(p.nik_clean AS STRING)
      AS nik_candidate,

    CAST(p.flag_nik_valid_16_digit AS BOOL)
      AS flag_nik_valid,

    CAST(p.nama_pasien AS STRING)
      AS nama_raw,

    CAST(p.nama_pasien_clean AS STRING)
      AS nama_clean_source,

    CAST(p.tanggal_lahir_date AS DATE)
      AS tanggal_lahir,


    -- --------------------------------------------------------
    -- Pregnancy dating evidence
    -- --------------------------------------------------------
    CAST(p.tanggal_hpht_date AS DATE)
      AS hpht_date,

    CAST(p.tanggal_taksiran_persalinan_date AS DATE)
      AS hpl_date,

    CAST(p.tanggal_persalinan_sebelumnya_date AS DATE)
      AS previous_delivery_date,


    -- --------------------------------------------------------
    -- PNC event
    --
    -- event_date = actual PNC visit date.
    -- delivery_date remains separate.
    -- --------------------------------------------------------
    CAST(p.pnc_visit_date AS DATE)
      AS event_date,

    'TANGGAL_PNC'
      AS event_date_source,

    CAST(NULL AS DATE)
      AS anc_date,

    CAST(p.delivery_event_date AS DATE)
      AS delivery_date,

    CAST(p.delivery_event_date_source AS STRING)
      AS delivery_date_source,

    CAST(p.pnc_visit_date AS DATE)
      AS pnc_date,


    -- --------------------------------------------------------
    -- Location/contact
    -- --------------------------------------------------------
    CAST(p.puskesmas_name AS STRING)
      AS puskesmas_raw,

    CAST(p.puskesmas_name_clean AS STRING)
      AS puskesmas_clean_source,

    CAST(p.puskesmas_id_clean AS STRING)
      AS puskesmas_id,

    CAST(NULL AS STRING)
      AS alamat,

    CAST(NULL AS STRING)
      AS no_hp_raw

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_epus_pnc` p
),


-- ============================================================
-- 5. COMMON NORMALIZATION
-- ============================================================
normalized AS (
  SELECT
    s.*,


    -- --------------------------------------------------------
    -- Final common NIK
    --
    -- Invalid structural NIK is retained in nik_raw but is not
    -- permitted to become the cross-source identity key.
    -- --------------------------------------------------------
    CASE
      WHEN flag_nik_valid = TRUE
      THEN nik_candidate
      ELSE NULL
    END AS nik_clean,


    -- --------------------------------------------------------
    -- Common normalized mother name
    --
    -- Used in the next mother-identity layer.
    -- --------------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(
              nama_clean_source,
              nama_raw,
              ''
            )
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS nama_norm,


    -- --------------------------------------------------------
    -- Common display Puskesmas
    -- --------------------------------------------------------
    COALESCE(
      NULLIF(
        TRIM(puskesmas_clean_source),
        ''
      ),
      NULLIF(
        TRIM(puskesmas_raw),
        ''
      )
    ) AS puskesmas,


    -- --------------------------------------------------------
    -- Common Puskesmas matching key
    -- --------------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(
              puskesmas_clean_source,
              puskesmas_raw,
              ''
            )
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS puskesmas_norm,


    -- --------------------------------------------------------
    -- Basic phone normalization
    -- Keep digits only.
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        COALESCE(no_hp_raw, ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS no_hp_clean

  FROM source_union s
),


-- ============================================================
-- 6. FINAL SOURCE RECORD KEY
--
-- Stable inside this standardized ePuskesmas layer.
--
-- It identifies the retained normalized source encounter,
-- NOT the mother and NOT the pregnancy.
-- ============================================================
finalized AS (
  SELECT
    n.*,

    CONCAT(
      'EPSRC_',
      TO_HEX(
        SHA256(
          CONCAT(
            source_table,
            '|',
            COALESCE(
              source_event_identity,
              source_record_id,
              CAST(source_row_hash AS STRING)
            )
          )
        )
      )
    ) AS epus_source_record_key

  FROM normalized n
)


-- ============================================================
-- 7. FINAL OUTPUT
-- ============================================================
SELECT
  -- ----------------------------------------------------------
  -- Standard identifiers
  -- ----------------------------------------------------------
  epus_source_record_key,

  'EPUS'
    AS data_source,

  source_table,
  raw_source_table,
  source_view,

  event_type,
  record_grain,
  same_event_source_priority,
  visit_label,


  -- ----------------------------------------------------------
  -- Source lineage
  -- ----------------------------------------------------------
  source_record_id,
  source_event_identity,

  source_dedup_method,

  source_raw_record_count,
  source_exact_duplicate_count,
  source_encounter_variant_count,
  source_is_duplicate_group,

  source_row_completeness_score,

  source_row_hash,
  clinical_content_hash,

  source_uuid,
  source_hash_code,

  file_name,
  file_date_parsed,
  ingestion_timestamp_parsed,
  source_recency_timestamp,


  -- ----------------------------------------------------------
  -- Mother identity
  -- ----------------------------------------------------------
  nik_raw,
  nik_candidate,
  nik_clean,
  flag_nik_valid,

  nama_raw AS nama,
  nama_clean_source,
  nama_norm,

  tanggal_lahir,


  -- ----------------------------------------------------------
  -- Pregnancy evidence
  -- ----------------------------------------------------------
  hpht_date,
  hpl_date,
  previous_delivery_date,


  -- ----------------------------------------------------------
  -- Event dates
  -- ----------------------------------------------------------
  event_date,
  event_date_source,

  anc_date,

  delivery_date,
  delivery_date_source,

  pnc_date,


  -- ----------------------------------------------------------
  -- Location/contact
  -- ----------------------------------------------------------
  puskesmas_raw,
  puskesmas,
  puskesmas_norm,
  puskesmas_id,

  alamat,

  no_hp_raw,
  no_hp_clean

FROM finalized;