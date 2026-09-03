-- Independent source layer: references redirected to v3; original logic retained.
-- V3 CORE DRAFT: not executed in BigQuery; production compatibility not yet validated.
-- Run this entire file as one job. Existing v2 inputs are read only.
-- Original comments below describe recovered historical scripts, not current counts.

-- ============================================================================
-- REBUILD t_sigizi_pregnancy_episode_v3_3
-- GEO-CORRECTED STAGE 1
--
-- INPUT:
--   spheres-lombok-barat.kohort_bumil_v3.t_sigizi_source_records
--
-- IMPORTANT:
--   t_sigizi_source_records is assumed to already contain the resolved
--   geography from the SIGIZI geography resolver.
--
-- LOCATION CANONICALIZATION:
--   GUNUNG SARI / GUNUNGSARI -> GUNUNGSARI
--   LABU API / LABUAPI       -> LABUAPI
--   PUSKESMAS <name>          -> <name>
--
-- LOCATION BUNDLE:
--   Puskesmas + Desa + Posyandu + Alamat are selected from ONE source row
--   per pregnancy episode to prevent mixed-source geography.
-- ============================================================================

DECLARE sigizi_episode_anchor_tolerance_days INT64 DEFAULT 120;
DECLARE plausible_pregnancy_floor DATE DEFAULT DATE '2018-01-01';

CREATE TEMP FUNCTION parse_date_any(s STRING)
RETURNS DATE
AS (
  COALESCE(
    SAFE_CAST(NULLIF(TRIM(s), '') AS DATE),
    SAFE_CAST(SUBSTR(NULLIF(TRIM(s), ''), 1, 10) AS DATE),
    SAFE.PARSE_DATE('%Y-%m-%d', REGEXP_EXTRACT(NULLIF(TRIM(s), ''), r'(\d{4}-\d{1,2}-\d{1,2})')),
    SAFE.PARSE_DATE('%Y/%m/%d', REGEXP_EXTRACT(NULLIF(TRIM(s), ''), r'(\d{4}/\d{1,2}/\d{1,2})')),
    SAFE.PARSE_DATE('%d/%m/%Y', REGEXP_EXTRACT(NULLIF(TRIM(s), ''), r'(\d{1,2}/\d{1,2}/\d{4})')),
    SAFE.PARSE_DATE('%d-%m-%Y', REGEXP_EXTRACT(NULLIF(TRIM(s), ''), r'(\d{1,2}-\d{1,2}-\d{4})')),
    SAFE.PARSE_DATE('%d.%m.%Y', REGEXP_EXTRACT(NULLIF(TRIM(s), ''), r'(\d{1,2}\.\d{1,2}\.\d{4})')),
    CASE
      WHEN REGEXP_CONTAINS(NULLIF(TRIM(s), ''), r'^\d{5}(?:\.0+)?$')
      THEN DATE_ADD(
        DATE '1899-12-30',
        INTERVAL SAFE_CAST(REGEXP_EXTRACT(TRIM(s), r'^\d+') AS INT64) DAY
      )
    END
  )
);

CREATE TEMP FUNCTION clean_nik(s STRING)
RETURNS STRING
AS (
  CASE
    WHEN REGEXP_CONTAINS(
      NULLIF(REGEXP_REPLACE(COALESCE(s, ''), r'[^0-9]', ''), ''),
      r'^\d{16}$'
    )
    AND NULLIF(REGEXP_REPLACE(COALESCE(s, ''), r'[^0-9]', ''), '')
      NOT IN ('0000000000000000', '9999999999999999')
    THEN NULLIF(REGEXP_REPLACE(COALESCE(s, ''), r'[^0-9]', ''), '')
  END
);

CREATE TEMP FUNCTION norm_text(s STRING)
RETURNS STRING
AS (
  NULLIF(
    REGEXP_REPLACE(
      UPPER(TRIM(NORMALIZE(COALESCE(s, ''), NFKC))),
      r'\s+',
      ' '
    ),
    ''
  )
);

CREATE TEMP FUNCTION norm_name(s STRING)
RETURNS STRING
AS (
  NULLIF(
    TRIM(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          UPPER(TRIM(NORMALIZE(COALESCE(s, ''), NFKC))),
          r'[^A-Z0-9 ]',
          ' '
        ),
        r'\s+',
        ' '
      )
    ),
    ''
  )
);

CREATE TEMP FUNCTION norm_name_core(s STRING)
RETURNS STRING
AS (
  NULLIF(
    TRIM(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          COALESCE(norm_name(s), ''),
          r'^(IBU|NY|NYONYA|HJ|HJH|HAJAH)\s+',
          ''
        ),
        r'\s+(SE|S E|SPD|S PD|SST|S ST|SKM|S KM|M KES|MKES|M KEB|MKEB|S KEP|SKEP|NERS|A MD KEB|AMD KEB)$',
        ''
      )
    ),
    ''
  )
);

CREATE TEMP FUNCTION clean_phone(s STRING)
RETURNS STRING
AS (
  NULLIF(REGEXP_REPLACE(COALESCE(s, ''), r'[^0-9]', ''), '')
);

CREATE TEMP FUNCTION is_sigizi_anon_placeholder(s STRING)
RETURNS BOOL
AS (
  REGEXP_CONTAINS(
    UPPER(TRIM(COALESCE(s, ''))),
    r'^ANON[_ -]?[0-9]+$'
  )
);

CREATE TEMP FUNCTION norm_puskesmas(s STRING)
RETURNS STRING
AS (
  CASE
    WHEN norm_text(s) IS NULL THEN NULL
    WHEN REGEXP_REPLACE(norm_text(s), r'^PUSKESMAS\s+', '')
      IN ('GUNUNG SARI', 'GUNUNGSARI')
      THEN 'GUNUNGSARI'
    WHEN REGEXP_REPLACE(norm_text(s), r'^PUSKESMAS\s+', '')
      IN ('LABU API', 'LABUAPI')
      THEN 'LABUAPI'
    ELSE REGEXP_REPLACE(norm_text(s), r'^PUSKESMAS\s+', '')
  END
);

CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_v3_3`
CLUSTER BY nik_clean, puskesmas_norm, sigizi_episode_id
AS

WITH sigizi_source_json AS (
  SELECT TO_JSON_STRING(t) AS row_json
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_source_records` t
  WHERE NOT (
    is_sigizi_anon_placeholder(t.nama)
    OR is_sigizi_anon_placeholder(t.nama_norm)
  )
),

sigizi_standardized AS (
  SELECT
    COALESCE(
      NULLIF(JSON_VALUE(row_json, '$.source_table'), ''),
      NULLIF(JSON_VALUE(row_json, '$.data_source'), ''),
      'UNKNOWN'
    ) AS source_table,

    COALESCE(
      SAFE_CAST(JSON_VALUE(row_json, '$.source_priority') AS INT64),
      5
    ) AS source_priority,

    COALESCE(
      NULLIF(JSON_VALUE(row_json, '$.source_record_id'), ''),
      NULLIF(JSON_VALUE(row_json, '$.dedup_key'), ''),
      NULLIF(JSON_VALUE(row_json, '$.uuid'), ''),
      NULLIF(JSON_VALUE(row_json, '$.hash_code'), ''),
      CAST(FARM_FINGERPRINT(row_json) AS STRING)
    ) AS source_record_id,

    clean_nik(
      COALESCE(
        JSON_VALUE(row_json, '$.nik_clean'),
        JSON_VALUE(row_json, '$.nik_raw'),
        JSON_VALUE(row_json, '$.nik'),
        JSON_VALUE(row_json, '$.nik_ibu'),
        JSON_VALUE(row_json, '$.nik_ibu_clean')
      )
    ) AS nik_clean,

    COALESCE(
      NULLIF(JSON_VALUE(row_json, '$.nama'), ''),
      NULLIF(JSON_VALUE(row_json, '$.nama_ibu'), ''),
      NULLIF(JSON_VALUE(row_json, '$.nama_pasien'), ''),
      NULLIF(JSON_VALUE(row_json, '$.nama_raw'), ''),
      NULLIF(JSON_VALUE(row_json, '$.nama_norm'), '')
    ) AS nama,

    norm_name(
      COALESCE(
        JSON_VALUE(row_json, '$.nama'),
        JSON_VALUE(row_json, '$.nama_ibu'),
        JSON_VALUE(row_json, '$.nama_pasien'),
        JSON_VALUE(row_json, '$.nama_raw'),
        JSON_VALUE(row_json, '$.nama_norm')
      )
    ) AS nama_norm,

    norm_name_core(
      COALESCE(
        JSON_VALUE(row_json, '$.nama'),
        JSON_VALUE(row_json, '$.nama_ibu'),
        JSON_VALUE(row_json, '$.nama_pasien'),
        JSON_VALUE(row_json, '$.nama_raw'),
        JSON_VALUE(row_json, '$.nama_norm')
      )
    ) AS nama_core_norm,

    parse_date_any(
      COALESCE(
        JSON_VALUE(row_json, '$.tanggal_lahir'),
        JSON_VALUE(row_json, '$.tanggal_lahir_date'),
        JSON_VALUE(row_json, '$.tgl_lahir_date'),
        JSON_VALUE(row_json, '$.tgl_lahir')
      )
    ) AS tanggal_lahir,

    parse_date_any(
      COALESCE(
        JSON_VALUE(row_json, '$.hpht_date'),
        JSON_VALUE(row_json, '$.tanggal_hpht_date'),
        JSON_VALUE(row_json, '$.tanggal_hpht_std'),
        JSON_VALUE(row_json, '$.tanggal_hpht'),
        JSON_VALUE(row_json, '$.tgl_hpht_date'),
        JSON_VALUE(row_json, '$.tgl_hpht'),
        JSON_VALUE(row_json, '$.hpht')
      )
    ) AS hpht_date,

    parse_date_any(
      COALESCE(
        JSON_VALUE(row_json, '$.hpl_date'),
        JSON_VALUE(row_json, '$.hpl_recorded_date'),
        JSON_VALUE(row_json, '$.tanggal_hpl_std'),
        JSON_VALUE(row_json, '$.tanggal_hpl'),
        JSON_VALUE(row_json, '$.tgl_hpl_date'),
        JSON_VALUE(row_json, '$.tgl_hpl'),
        JSON_VALUE(row_json, '$.hpl'),
        JSON_VALUE(row_json, '$.tanggal_taksiran_persalinan_date')
      )
    ) AS hpl_date,

    parse_date_any(
      COALESCE(
        JSON_VALUE(row_json, '$.anc_date'),
        JSON_VALUE(row_json, '$.tanggal_anc_std'),
        JSON_VALUE(row_json, '$.tanggal_anc'),
        JSON_VALUE(row_json, '$.tanggal_antenatal_date')
      )
    ) AS anc_date,

    parse_date_any(
      COALESCE(
        JSON_VALUE(row_json, '$.delivery_date'),
        JSON_VALUE(row_json, '$.actual_delivery_date'),
        JSON_VALUE(row_json, '$.tanggal_melahirkan_date'),
        JSON_VALUE(row_json, '$.tanggal_melahirkan_std'),
        JSON_VALUE(row_json, '$.tanggal_melahirkan'),
        JSON_VALUE(row_json, '$.tgl_melahirkan'),
        JSON_VALUE(row_json, '$.tanggal_persalinan_date'),
        JSON_VALUE(row_json, '$.tanggal_persalinan')
      )
    ) AS delivery_date,

    parse_date_any(
      COALESCE(
        JSON_VALUE(row_json, '$.abortion_date'),
        JSON_VALUE(row_json, '$.tanggal_abortus_date'),
        JSON_VALUE(row_json, '$.tanggal_abortus_std'),
        JSON_VALUE(row_json, '$.tanggal_abortus'),
        JSON_VALUE(row_json, '$.tgl_abortus')
      )
    ) AS abortion_date,

    -- Use ONLY resolved geography. No old/raw geography fallback.
    norm_puskesmas(
      COALESCE(
        NULLIF(JSON_VALUE(row_json, '$.puskesmas_norm'), ''),
        NULLIF(JSON_VALUE(row_json, '$.puskesmas'), '')
      )
    ) AS puskesmas,

    norm_puskesmas(
      COALESCE(
        NULLIF(JSON_VALUE(row_json, '$.puskesmas_norm'), ''),
        NULLIF(JSON_VALUE(row_json, '$.puskesmas'), '')
      )
    ) AS puskesmas_norm,

    norm_text(
      COALESCE(
        NULLIF(JSON_VALUE(row_json, '$.desa_norm'), ''),
        NULLIF(JSON_VALUE(row_json, '$.desa'), '')
      )
    ) AS desa,

    norm_text(
      COALESCE(
        NULLIF(JSON_VALUE(row_json, '$.desa_norm'), ''),
        NULLIF(JSON_VALUE(row_json, '$.desa'), '')
      )
    ) AS desa_norm,

    NULLIF(JSON_VALUE(row_json, '$.posyandu'), '') AS posyandu,
    NULLIF(JSON_VALUE(row_json, '$.alamat'), '') AS alamat,

    COALESCE(
      NULLIF(JSON_VALUE(row_json, '$.location_resolution_method'), ''),
      'LEGACY_OR_UNSPECIFIED'
    ) AS location_resolution_method,

    COALESCE(
      NULLIF(JSON_VALUE(row_json, '$.location_resolution_confidence'), ''),
      CASE
        WHEN COALESCE(
          NULLIF(JSON_VALUE(row_json, '$.puskesmas_norm'), ''),
          NULLIF(JSON_VALUE(row_json, '$.puskesmas'), '')
        ) IS NOT NULL
          THEN 'UNSPECIFIED'
        ELSE 'UNRESOLVED'
      END
    ) AS location_resolution_confidence,

    COALESCE(
      SAFE_CAST(JSON_VALUE(row_json, '$.location_resolution_score') AS INT64),
      0
    ) AS location_resolution_score,

    clean_phone(
      COALESCE(
        JSON_VALUE(row_json, '$.no_hp_clean'),
        JSON_VALUE(row_json, '$.nomor_hp_clean'),
        JSON_VALUE(row_json, '$.phone_normalized'),
        JSON_VALUE(row_json, '$.no_hp'),
        JSON_VALUE(row_json, '$.nomor_hp'),
        JSON_VALUE(row_json, '$.no_telepon_ibu'),
        JSON_VALUE(row_json, '$.no_telepon')
      )
    ) AS no_hp_clean

  FROM sigizi_source_json
),

prepared AS (
  SELECT
    *,
    CASE
      WHEN hpht_date BETWEEN plausible_pregnancy_floor
        AND CURRENT_DATE('Asia/Makassar')
      THEN hpht_date
    END AS hpht_valid,

    CASE
      WHEN hpl_date BETWEEN plausible_pregnancy_floor
        AND DATE_ADD(CURRENT_DATE('Asia/Makassar'), INTERVAL 300 DAY)
      THEN hpl_date
    END AS hpl_valid,

    CASE
      WHEN delivery_date BETWEEN plausible_pregnancy_floor
        AND DATE_ADD(CURRENT_DATE('Asia/Makassar'), INTERVAL 30 DAY)
      THEN delivery_date
    END AS delivery_valid,

    CASE location_resolution_confidence
      WHEN 'VERY_HIGH' THEN 1
      WHEN 'HIGH' THEN 2
      WHEN 'MEDIUM_HIGH' THEN 3
      WHEN 'MEDIUM' THEN 4
      WHEN 'UNSPECIFIED' THEN 5
      WHEN 'LOW' THEN 6
      WHEN 'AMBIGUOUS' THEN 7
      WHEN 'UNRESOLVED' THEN 9
      ELSE 8
    END AS location_confidence_rank
  FROM sigizi_standardized
),

identity_base AS (
  SELECT
    *,
    COALESCE(
      hpht_valid,
      DATE_SUB(hpl_valid, INTERVAL 280 DAY)
    ) AS pregnancy_anchor_date
  FROM prepared
),

signature_base AS (
  SELECT
    *,
    CASE
      WHEN nama_core_norm IS NOT NULL
       AND puskesmas_norm IS NOT NULL
       AND desa_norm IS NOT NULL
       AND pregnancy_anchor_date IS NOT NULL
      THEN CONCAT(
        'PREGSIG|',
        nama_core_norm, '|',
        puskesmas_norm, '|',
        desa_norm, '|',
        CAST(pregnancy_anchor_date AS STRING)
      )
    END AS pregnancy_signature_key
  FROM identity_base
),

signature_stats AS (
  SELECT
    pregnancy_signature_key,
    COUNT(*) AS signature_row_count,
    COUNT(DISTINCT nik_clean) AS signature_distinct_nik_count,
    ARRAY_AGG(
      DISTINCT nik_clean IGNORE NULLS
      ORDER BY nik_clean
      LIMIT 1
    )[SAFE_OFFSET(0)] AS signature_unique_nik,
    COUNT(DISTINCT tanggal_lahir) AS signature_distinct_dob_count,
    ARRAY_AGG(
      DISTINCT tanggal_lahir IGNORE NULLS
      ORDER BY tanggal_lahir
      LIMIT 1
    )[SAFE_OFFSET(0)] AS signature_unique_dob
  FROM signature_base
  WHERE pregnancy_signature_key IS NOT NULL
  GROUP BY pregnancy_signature_key
),

identified AS (
  SELECT
    b.*,
    COALESCE(s.signature_row_count, 1) AS signature_row_count,
    COALESCE(s.signature_distinct_nik_count, 0) AS signature_distinct_nik_count,
    s.signature_unique_nik,
    COALESCE(s.signature_distinct_dob_count, 0) AS signature_distinct_dob_count,
    s.signature_unique_dob,

    CASE
      WHEN b.nik_clean IS NOT NULL
        THEN CONCAT('NIK|', b.nik_clean)

      WHEN b.pregnancy_signature_key IS NOT NULL
       AND COALESCE(s.signature_distinct_nik_count, 0) = 1
       AND s.signature_unique_nik IS NOT NULL
        THEN CONCAT('NIK|', s.signature_unique_nik)

      WHEN b.nama_core_norm IS NOT NULL
       AND b.tanggal_lahir IS NOT NULL
       AND b.puskesmas_norm IS NOT NULL
        THEN CONCAT(
          'NAME_DOB_PKM|',
          b.nama_core_norm, '|',
          CAST(b.tanggal_lahir AS STRING), '|',
          b.puskesmas_norm
        )

      WHEN b.nama_core_norm IS NOT NULL
       AND b.tanggal_lahir IS NOT NULL
       AND b.desa_norm IS NOT NULL
        THEN CONCAT(
          'NAME_DOB_DESA|',
          b.nama_core_norm, '|',
          CAST(b.tanggal_lahir AS STRING), '|',
          b.desa_norm
        )

      WHEN b.nama_core_norm IS NOT NULL
       AND b.tanggal_lahir IS NOT NULL
        THEN CONCAT(
          'NAME_DOB|',
          b.nama_core_norm, '|',
          CAST(b.tanggal_lahir AS STRING)
        )

      WHEN b.pregnancy_signature_key IS NOT NULL
       AND COALESCE(s.signature_distinct_nik_count, 0) = 0
       AND COALESCE(s.signature_distinct_dob_count, 0) = 1
       AND s.signature_unique_dob IS NOT NULL
        THEN CONCAT(
          'NAME_DOB_PKM|',
          b.nama_core_norm, '|',
          CAST(s.signature_unique_dob AS STRING), '|',
          b.puskesmas_norm
        )

      WHEN b.pregnancy_signature_key IS NOT NULL
       AND COALESCE(s.signature_distinct_nik_count, 0) = 0
       AND COALESCE(s.signature_distinct_dob_count, 0) = 0
        THEN b.pregnancy_signature_key

      ELSE CONCAT(
        'SOURCE|',
        b.source_table, '|',
        b.source_record_id
      )
    END AS mother_identity_key,

    CASE
      WHEN b.nik_clean IS NOT NULL
        THEN 'NIK'
      WHEN b.pregnancy_signature_key IS NOT NULL
       AND COALESCE(s.signature_distinct_nik_count, 0) = 1
       AND s.signature_unique_nik IS NOT NULL
        THEN 'PREG_SIGNATURE_TO_UNIQUE_NIK'
      WHEN b.nama_core_norm IS NOT NULL
       AND b.tanggal_lahir IS NOT NULL
       AND b.puskesmas_norm IS NOT NULL
        THEN 'NAMA_CORE+DOB+PUSKESMAS'
      WHEN b.nama_core_norm IS NOT NULL
       AND b.tanggal_lahir IS NOT NULL
       AND b.desa_norm IS NOT NULL
        THEN 'NAMA_CORE+DOB+DESA'
      WHEN b.nama_core_norm IS NOT NULL
       AND b.tanggal_lahir IS NOT NULL
        THEN 'NAMA_CORE+DOB'
      WHEN b.pregnancy_signature_key IS NOT NULL
       AND COALESCE(s.signature_distinct_nik_count, 0) = 0
       AND COALESCE(s.signature_distinct_dob_count, 0) = 1
       AND s.signature_unique_dob IS NOT NULL
        THEN 'PREG_SIGNATURE_TO_UNIQUE_DOB'
      WHEN b.pregnancy_signature_key IS NOT NULL
       AND COALESCE(s.signature_distinct_nik_count, 0) = 0
       AND COALESCE(s.signature_distinct_dob_count, 0) = 0
        THEN 'WEAK_PREG_SIGNATURE'
      ELSE 'SOURCE_RECORD'
    END AS mother_identity_method,

    (
      b.nik_clean IS NULL
      AND (
        (
          b.pregnancy_signature_key IS NOT NULL
          AND COALESCE(s.signature_distinct_nik_count, 0) = 1
          AND s.signature_unique_nik IS NOT NULL
        )
        OR
        (
          b.tanggal_lahir IS NULL
          AND b.pregnancy_signature_key IS NOT NULL
          AND COALESCE(s.signature_distinct_nik_count, 0) = 0
          AND COALESCE(s.signature_distinct_dob_count, 0) = 1
          AND s.signature_unique_dob IS NOT NULL
        )
      )
    ) AS identity_propagated_flag,

    (
      b.nik_clean IS NULL
      AND b.tanggal_lahir IS NULL
      AND b.pregnancy_signature_key IS NOT NULL
      AND (
        COALESCE(s.signature_distinct_nik_count, 0) > 1
        OR COALESCE(s.signature_distinct_dob_count, 0) > 1
      )
    ) AS weak_signature_ambiguous_flag

  FROM signature_base b
  LEFT JOIN signature_stats s
    USING (pregnancy_signature_key)
),

anchor_records AS (
  SELECT *
  FROM identified
  WHERE pregnancy_anchor_date IS NOT NULL
),

ordered AS (
  SELECT
    *,
    LAG(pregnancy_anchor_date) OVER (
      PARTITION BY mother_identity_key
      ORDER BY pregnancy_anchor_date, source_priority, source_record_id
    ) AS previous_anchor_date
  FROM anchor_records
),

marked AS (
  SELECT
    *,
    CASE
      WHEN previous_anchor_date IS NULL THEN 1
      WHEN DATE_DIFF(
        pregnancy_anchor_date,
        previous_anchor_date,
        DAY
      ) > sigizi_episode_anchor_tolerance_days
        THEN 1
      ELSE 0
    END AS starts_new_episode
  FROM ordered
),

numbered AS (
  SELECT
    *,
    SUM(starts_new_episode) OVER (
      PARTITION BY mother_identity_key
      ORDER BY pregnancy_anchor_date, source_priority, source_record_id
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS episode_number
  FROM marked
),

aggregated AS (
  SELECT
    mother_identity_key,
    episode_number,

    ARRAY_AGG(
      mother_identity_method
      ORDER BY
        CASE mother_identity_method
          WHEN 'NIK' THEN 1
          WHEN 'PREG_SIGNATURE_TO_UNIQUE_NIK' THEN 2
          WHEN 'NAMA_CORE+DOB+PUSKESMAS' THEN 3
          WHEN 'NAMA_CORE+DOB+DESA' THEN 4
          WHEN 'PREG_SIGNATURE_TO_UNIQUE_DOB' THEN 5
          WHEN 'NAMA_CORE+DOB' THEN 6
          WHEN 'WEAK_PREG_SIGNATURE' THEN 7
          ELSE 9
        END,
        source_priority,
        source_record_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS mother_identity_method,

    ARRAY_AGG(
      DISTINCT mother_identity_method
      ORDER BY mother_identity_method
    ) AS mother_identity_methods,

    MIN(pregnancy_anchor_date) AS pregnancy_anchor_min_date,
    MAX(pregnancy_anchor_date) AS pregnancy_anchor_max_date,

    DATE_DIFF(
      MAX(pregnancy_anchor_date),
      MIN(pregnancy_anchor_date),
      DAY
    ) AS pregnancy_anchor_spread_days,

    COUNT(*) AS sigizi_member_record_count,
    COUNTIF(identity_propagated_flag)
      AS sigizi_identity_propagated_record_count,
    COUNTIF(weak_signature_ambiguous_flag)
      AS sigizi_ambiguous_identity_record_count,
    MAX(signature_row_count)
      AS sigizi_max_signature_row_count,
    COUNT(DISTINCT pregnancy_signature_key)
      AS sigizi_distinct_pregnancy_signature_count,

    ARRAY_AGG(
      DISTINCT source_table
      ORDER BY source_table
    ) AS sigizi_source_tables,

    ARRAY_AGG(
      source_record_id
      ORDER BY source_priority, source_record_id
    ) AS sigizi_member_source_record_ids,

    ARRAY_AGG(
      STRUCT(
        nik_clean AS value,
        source_priority AS priority
      )
      ORDER BY nik_clean IS NULL, source_priority, source_record_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS nik_pick,

    ARRAY_AGG(
      STRUCT(
        nama AS value,
        nama_norm AS value_norm,
        nama_core_norm AS value_core_norm,
        source_priority AS priority
      )
      ORDER BY nama_core_norm IS NULL, source_priority, source_record_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS nama_pick,

    ARRAY_AGG(
      STRUCT(
        tanggal_lahir AS value,
        source_priority AS priority
      )
      ORDER BY tanggal_lahir IS NULL, source_priority, source_record_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS dob_pick,

    ARRAY_AGG(
      STRUCT(
        no_hp_clean AS value,
        source_priority AS priority
      )
      ORDER BY
        no_hp_clean IS NULL,
        LENGTH(COALESCE(no_hp_clean, '')) DESC,
        source_priority,
        source_record_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS phone_pick,

    -- Coherent location bundle from ONE member row.
    ARRAY_AGG(
      STRUCT(
        puskesmas AS puskesmas,
        puskesmas_norm AS puskesmas_norm,
        desa AS desa,
        desa_norm AS desa_norm,
        posyandu AS posyandu,
        alamat AS alamat,
        location_resolution_method AS resolution_method,
        location_resolution_confidence AS resolution_confidence,
        location_resolution_score AS resolution_score,
        source_table AS source_table,
        source_record_id AS source_record_id,
        source_priority AS source_priority
      )
      ORDER BY
        puskesmas_norm IS NULL,
        desa_norm IS NULL,
        posyandu IS NULL,
        location_confidence_rank,
        location_resolution_score DESC,
        source_priority,
        source_record_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS location_pick,

    ARRAY_AGG(
      STRUCT(
        hpht_valid AS value,
        source_table AS source_table,
        source_priority AS priority
      )
      ORDER BY hpht_valid IS NULL, source_priority, source_record_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS hpht_pick,

    ARRAY_AGG(
      STRUCT(
        hpl_valid AS value,
        source_table AS source_table,
        source_priority AS priority
      )
      ORDER BY hpl_valid IS NULL, source_priority, source_record_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS hpl_pick,

    ARRAY_AGG(
      STRUCT(
        delivery_valid AS value,
        source_table AS source_table,
        source_priority AS priority
      )
      ORDER BY delivery_valid IS NULL, source_priority, source_record_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS delivery_pick,

    MIN(anc_date) AS first_anc_date,
    MAX(anc_date) AS last_anc_date

  FROM numbered
  GROUP BY mother_identity_key, episode_number
)

SELECT
  CONCAT(
    'SIGEP_',
    TO_HEX(
      SHA256(
        CONCAT(
          mother_identity_key,
          '|',
          CAST(pregnancy_anchor_min_date AS STRING),
          '|',
          CAST(episode_number AS STRING)
        )
      )
    )
  ) AS sigizi_episode_id,

  mother_identity_key,
  mother_identity_method,
  episode_number,

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
  CASE
    WHEN hpht_pick.value IS NOT NULL THEN hpht_pick.source_table
  END AS hpht_sigizi_source_table,

  hpl_pick.value AS hpl_sigizi,
  CASE
    WHEN hpl_pick.value IS NOT NULL THEN hpl_pick.source_table
  END AS hpl_sigizi_source_table,

  delivery_pick.value AS delivery_sigizi,
  CASE
    WHEN delivery_pick.value IS NOT NULL THEN delivery_pick.source_table
  END AS delivery_sigizi_source_table,

  CASE
    WHEN hpht_pick.value IS NOT NULL
      THEN DATE_ADD(hpht_pick.value, INTERVAL 280 DAY)
  END AS hpl_from_sigizi_hpht,

  first_anc_date,
  last_anc_date,

  pregnancy_anchor_min_date,
  pregnancy_anchor_max_date,
  pregnancy_anchor_spread_days,

  pregnancy_anchor_spread_days > sigizi_episode_anchor_tolerance_days
    AS sigizi_episode_review_flag,

  sigizi_member_record_count,
  sigizi_source_tables,
  sigizi_member_source_record_ids,
  mother_identity_methods,

  sigizi_identity_propagated_record_count,
  sigizi_ambiguous_identity_record_count,
  sigizi_max_signature_row_count,
  sigizi_distinct_pregnancy_signature_count

FROM aggregated;


-- ============================================================================
-- QA 1 - SUMMARY
-- ============================================================================

SELECT
  COUNT(*) AS sigizi_pregnancy_episodes,

  COUNTIF(puskesmas_norm IS NOT NULL) AS episodes_with_puskesmas,
  COUNTIF(desa_norm IS NOT NULL) AS episodes_with_desa,
  COUNTIF(posyandu IS NOT NULL) AS episodes_with_posyandu,

  COUNTIF(location_resolution_confidence = 'VERY_HIGH')
    AS location_very_high,
  COUNTIF(location_resolution_confidence = 'HIGH')
    AS location_high,
  COUNTIF(location_resolution_confidence = 'MEDIUM')
    AS location_medium,
  COUNTIF(location_resolution_confidence = 'UNRESOLVED')
    AS location_unresolved

FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_v3_3`;


-- ============================================================================
-- QA 2 - PUSKESMAS LIST
-- ============================================================================

SELECT
  puskesmas_norm,
  COUNT(*) AS episodes
FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_v3_3`
WHERE puskesmas_norm IS NOT NULL
GROUP BY puskesmas_norm
ORDER BY episodes DESC, puskesmas_norm;


-- ============================================================================
-- QA 3 - OLD BAD PUSKESMAS VALUES SHOULD NOT REAPPEAR
-- ============================================================================

SELECT
  puskesmas_norm,
  COUNT(*) AS episodes
FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_v3_3`
WHERE puskesmas_norm IN (
  'DINAS KESEHATAN',
  'BAGIK POLAK',
  'BAGIK POLAK BARAT',
  'BANYU URIP',
  'BENGKEL',
  'DASAN TERENG',
  'GELOGOR',
  'GERUNG SELATAN',
  'GERUNG UTARA',
  'JAGARAGA',
  'KURIPAN DESA',
  'KURIPAN SELATAN',
  'KURIPAN TIMUR',
  'KURIPAN UTARA',
  'MEKAR SARI',
  'OMBE BARU',
  'PERESAK',
  'SEMBUNG',
  'TELAGE WARU',
  'TERONG TAWAH'
)
GROUP BY puskesmas_norm
ORDER BY episodes DESC;


-- ============================================================================
-- QA 4 - CANONICAL ALIASES
-- ============================================================================

SELECT
  puskesmas_norm,
  COUNT(*) AS episodes
FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_v3_3`
WHERE puskesmas_norm IN (
  'GUNUNG SARI',
  'GUNUNGSARI',
  'LABU API',
  'LABUAPI',
  'PUSKESMAS NARMADA',
  'NARMADA'
)
GROUP BY puskesmas_norm
ORDER BY puskesmas_norm;


-- ============================================================================
-- QA 5 - SAMPLE HIERARCHY
-- ============================================================================

SELECT
  puskesmas_norm,
  desa_norm,
  posyandu,
  COUNT(*) AS episodes
FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_v3_3`
WHERE puskesmas_norm IN (
  'KURIPAN',
  'LABUAPI',
  'NARMADA',
  'PERAMPUAN'
)
GROUP BY puskesmas_norm, desa_norm, posyandu
ORDER BY puskesmas_norm, desa_norm, episodes DESC;