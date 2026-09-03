-- Independent source layer: references redirected to v3; original logic retained.
-- V3 CORE DRAFT: not executed in BigQuery; production compatibility not yet validated.
-- Run this entire file as one job. Existing v2 inputs are read only.
-- Original comments below describe recovered historical scripts, not current counts.

-- ============================================================================
-- PREGNANCY OUTCOME TRACKING v3.3
-- STAGE 4 -> STAGE 6 STANDALONE RERUN
-- GEO-FIXED VERSION
--
-- RUN AFTER:
--   1. t_sigizi_pregnancy_episode_v3_3 has been rebuilt with resolved geography
--   2. 03C v4.1 canonicalization has rebuilt:
--        t_pregnancy_episode_spine_v3_3
--
-- OUTPUTS:
--   Stage 4: t_pregnancy_usg_dating_v3_3
--   Stage 5: t_pregnancy_outcome_events_v3_3
--   Stage 6: t_pregnancy_outcome_tracking_v3_3
--
-- GEO FIX:
--   SIGIZI Stage-5 outcome events use ONLY the already-resolved fields:
--     puskesmas / puskesmas_norm
--     desa / desa_norm
--
--   DO NOT fall back to:
--     puskesmas_raw
--     puskesmas_domisili
--     pukesmas
--     desa_raw
--     desakel
--     desakel_domisili
--
--   Canonical aliases:
--     GUNUNG SARI / GUNUNGSARI -> GUNUNGSARI
--     LABU API / LABUAPI       -> LABUAPI
--     PUSKESMAS <name>          -> <name>
-- ============================================================================


-- ============================================================================
-- PARAMETERS
-- ============================================================================

DECLARE monitoring_start_date DATE DEFAULT DATE '2025-01-01';
DECLARE plausible_pregnancy_floor DATE DEFAULT DATE '2018-01-01';


-- ============================================================================
-- TEMP FUNCTIONS
-- ============================================================================

CREATE TEMP FUNCTION parse_date_any(s STRING)
RETURNS DATE
AS (
  COALESCE(
    SAFE_CAST(NULLIF(TRIM(s), '') AS DATE),
    SAFE_CAST(SUBSTR(NULLIF(TRIM(s), ''), 1, 10) AS DATE),

    SAFE.PARSE_DATE(
      '%Y-%m-%d',
      REGEXP_EXTRACT(NULLIF(TRIM(s), ''), r'(\d{4}-\d{1,2}-\d{1,2})')
    ),

    SAFE.PARSE_DATE(
      '%Y/%m/%d',
      REGEXP_EXTRACT(NULLIF(TRIM(s), ''), r'(\d{4}/\d{1,2}/\d{1,2})')
    ),

    SAFE.PARSE_DATE(
      '%d/%m/%Y',
      REGEXP_EXTRACT(NULLIF(TRIM(s), ''), r'(\d{1,2}/\d{1,2}/\d{4})')
    ),

    SAFE.PARSE_DATE(
      '%d-%m-%Y',
      REGEXP_EXTRACT(NULLIF(TRIM(s), ''), r'(\d{1,2}-\d{1,2}-\d{4})')
    ),

    SAFE.PARSE_DATE(
      '%d.%m.%Y',
      REGEXP_EXTRACT(NULLIF(TRIM(s), ''), r'(\d{1,2}\.\d{1,2}\.\d{4})')
    ),

    CASE
      WHEN REGEXP_CONTAINS(
        NULLIF(TRIM(s), ''),
        r'^\d{5}(?:\.0+)?$'
      )
      THEN DATE_ADD(
        DATE '1899-12-30',
        INTERVAL SAFE_CAST(
          REGEXP_EXTRACT(TRIM(s), r'^\d+')
          AS INT64
        ) DAY
      )
    END
  )
);


CREATE TEMP FUNCTION clean_nik(s STRING)
RETURNS STRING
AS (
  CASE
    WHEN REGEXP_CONTAINS(
      NULLIF(
        REGEXP_REPLACE(COALESCE(s, ''), r'[^0-9]', ''),
        ''
      ),
      r'^\d{16}$'
    )
    AND NULLIF(
      REGEXP_REPLACE(COALESCE(s, ''), r'[^0-9]', ''),
      ''
    ) NOT IN (
      '0000000000000000',
      '9999999999999999'
    )
    THEN NULLIF(
      REGEXP_REPLACE(COALESCE(s, ''), r'[^0-9]', ''),
      ''
    )
  END
);


CREATE TEMP FUNCTION norm_text(s STRING)
RETURNS STRING
AS (
  NULLIF(
    REGEXP_REPLACE(
      UPPER(
        TRIM(
          NORMALIZE(COALESCE(s, ''), NFKC)
        )
      ),
      r'\s+',
      ' '
    ),
    ''
  )
);


CREATE TEMP FUNCTION norm_puskesmas(s STRING)
RETURNS STRING
AS (
  CASE
    WHEN norm_text(s) IS NULL
      THEN NULL

    WHEN REGEXP_REPLACE(
      norm_text(s),
      r'^PUSKESMAS\s+',
      ''
    ) IN ('GUNUNG SARI', 'GUNUNGSARI')
      THEN 'GUNUNGSARI'

    WHEN REGEXP_REPLACE(
      norm_text(s),
      r'^PUSKESMAS\s+',
      ''
    ) IN ('LABU API', 'LABUAPI')
      THEN 'LABUAPI'

    ELSE REGEXP_REPLACE(
      norm_text(s),
      r'^PUSKESMAS\s+',
      ''
    )
  END
);


CREATE TEMP FUNCTION clean_phone(s STRING)
RETURNS STRING
AS (
  NULLIF(
    REGEXP_REPLACE(
      COALESCE(s, ''),
      r'[^0-9]',
      ''
    ),
    ''
  )
);


CREATE TEMP FUNCTION classify_explicit_outcome(s STRING)
RETURNS STRING
AS (
  CASE
    WHEN norm_text(s) IN (
      'LAHIR HIDUP',
      'HIDUP',
      'LIVE BIRTH',
      'LIVEBIRTH'
    )
      THEN 'LAHIR HIDUP'

    WHEN norm_text(s) IN (
      'LAHIR MATI',
      'STILLBIRTH',
      'STILL BIRTH',
      'IUFD'
    )
      THEN 'LAHIR MATI'

    WHEN norm_text(s) IN (
      'ABORTUS',
      'KEGUGURAN',
      'ABORTION',
      'MISCARRIAGE'
    )
      THEN 'ABORTUS'

    ELSE NULL
  END
);


CREATE TEMP FUNCTION is_sigizi_anon_placeholder(s STRING)
RETURNS BOOL
AS (
  REGEXP_CONTAINS(
    UPPER(TRIM(COALESCE(s, ''))),
    r'^ANON[_ -]?[0-9]+$'
  )
);


-- ============================================================================
-- STAGE 4
-- BUILD PREGNANCY-LEVEL USG DATING
-- ============================================================================

CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_usg_dating_v3_3`
CLUSTER BY pregnancy_episode_id, nik_clean
AS

WITH src AS (
  SELECT
    TO_JSON_STRING(t) AS j
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_epus_anc` t
),

parsed AS (
  SELECT
    COALESCE(
      NULLIF(JSON_VALUE(j, '$.source_record_id'), ''),
      NULLIF(JSON_VALUE(j, '$.dedup_key'), ''),
      NULLIF(JSON_VALUE(j, '$.source_row_hash'), ''),
      CAST(FARM_FINGERPRINT(j) AS STRING)
    ) AS usg_record_id,

    clean_nik(
      COALESCE(
        JSON_VALUE(j, '$.nik_clean'),
        JSON_VALUE(j, '$.nik'),
        JSON_VALUE(j, '$.nik_ibu_clean')
      )
    ) AS nik_clean,

    norm_text(
      COALESCE(
        JSON_VALUE(j, '$.nama_pasien_clean'),
        JSON_VALUE(j, '$.nama_pasien'),
        JSON_VALUE(j, '$.nama_ibu')
      )
    ) AS nama_norm,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.tanggal_lahir_date'),
        JSON_VALUE(j, '$.tanggal_lahir'),
        JSON_VALUE(j, '$.tgl_lahir_date')
      )
    ) AS tanggal_lahir_ibu,

    parse_date_any(
      JSON_VALUE(j, '$.tanggal_antenatal_date')
    ) AS usg_date,

    SAFE_CAST(
      JSON_VALUE(
        j,
        '$.usg_usia_kehamilan_numeric'
      )
      AS FLOAT64
    ) AS usg_ga_weeks,

    parse_date_any(
      JSON_VALUE(
        j,
        '$.usg_perkiraan_lahir_date'
      )
    ) AS usg_recorded_hpl_date,

    norm_text(
      COALESCE(
        JSON_VALUE(j, '$.usg_clean'),
        JSON_VALUE(j, '$.usg')
      )
    ) AS usg_status,

    j AS source_json

  FROM src
),

dated AS (
  SELECT
    *,

    CASE
      WHEN usg_date IS NOT NULL
       AND usg_ga_weeks BETWEEN 4 AND 42
      THEN DATE_ADD(
        usg_date,
        INTERVAL (
          280
          - CAST(
              ROUND(
                usg_ga_weeks * 7
              )
              AS INT64
            )
        ) DAY
      )
    END AS hpl_from_usg_ga_date,

    CASE
      WHEN usg_ga_weeks BETWEEN 4 AND 14
        THEN 1

      WHEN usg_ga_weeks > 14
       AND usg_ga_weeks <= 22
        THEN 2

      WHEN usg_ga_weeks > 22
       AND usg_ga_weeks <= 42
        THEN 3

      WHEN usg_recorded_hpl_date IS NOT NULL
        THEN 4

      ELSE 9
    END AS usg_dating_quality_priority,

    CASE
      WHEN usg_ga_weeks BETWEEN 4 AND 14
        THEN 'EARLY_USG_LE_14W'

      WHEN usg_ga_weeks > 14
       AND usg_ga_weeks <= 22
        THEN 'USG_14_22W'

      WHEN usg_ga_weeks > 22
       AND usg_ga_weeks <= 42
        THEN 'LATE_USG_GT_22W'

      WHEN usg_recorded_hpl_date IS NOT NULL
        THEN 'RECORDED_USG_EDD_GA_UNKNOWN'

      ELSE 'NO_USABLE_USG_DATING'
    END AS usg_dating_quality

  FROM parsed
),

usable AS (
  SELECT *
  FROM dated
  WHERE usg_date IS NOT NULL
    AND (
      hpl_from_usg_ga_date IS NOT NULL
      OR usg_recorded_hpl_date IS NOT NULL
    )
),

match_candidates AS (

  SELECT
    p.pregnancy_episode_id,
    p.nik_clean AS pregnancy_nik,
    u.*,

    'NIK+VISIT_WINDOW'
      AS usg_match_method,

    1 AS usg_match_priority

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` p

  JOIN usable u
    ON p.nik_clean IS NOT NULL
   AND u.nik_clean IS NOT NULL
   AND p.nik_clean = u.nik_clean

   AND u.usg_date BETWEEN
     DATE_SUB(
       p.pregnancy_anchor_date,
       INTERVAL 30 DAY
     )
     AND DATE_ADD(
       p.pregnancy_anchor_date,
       INTERVAL 300 DAY
     )

  UNION ALL

  SELECT
    p.pregnancy_episode_id,
    p.nik_clean AS pregnancy_nik,
    u.*,

    'NAMA+DOB+VISIT_WINDOW'
      AS usg_match_method,

    2 AS usg_match_priority

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` p

  JOIN usable u
    ON p.nama_norm IS NOT NULL
   AND u.nama_norm IS NOT NULL
   AND p.nama_norm = u.nama_norm

   AND p.tanggal_lahir_ibu IS NOT NULL
   AND u.tanggal_lahir_ibu IS NOT NULL
   AND p.tanggal_lahir_ibu = u.tanggal_lahir_ibu

   AND (
     p.nik_clean IS NULL
     OR u.nik_clean IS NULL
   )

   AND u.usg_date BETWEEN
     DATE_SUB(
       p.pregnancy_anchor_date,
       INTERVAL 30 DAY
     )
     AND DATE_ADD(
       p.pregnancy_anchor_date,
       INTERVAL 300 DAY
     )
),

ranked AS (
  SELECT
    *,

    ROW_NUMBER() OVER (
      PARTITION BY pregnancy_episode_id
      ORDER BY
        usg_match_priority,
        usg_dating_quality_priority,
        usg_date,
        usg_record_id
    ) AS rn

  FROM match_candidates
)

SELECT
  pregnancy_episode_id,

  pregnancy_nik AS nik_clean,

  usg_record_id
    AS dating_usg_record_id,

  usg_match_method,
  usg_match_priority,

  usg_date
    AS dating_usg_date,

  usg_ga_weeks
    AS dating_usg_ga_weeks,

  CAST(
    ROUND(
      usg_ga_weeks * 7
    )
    AS INT64
  ) AS dating_usg_ga_days,

  usg_recorded_hpl_date,
  hpl_from_usg_ga_date,

  COALESCE(
    hpl_from_usg_ga_date,
    usg_recorded_hpl_date
  ) AS hpl_from_usg_date,

  CASE
    WHEN usg_recorded_hpl_date IS NOT NULL
     AND hpl_from_usg_ga_date IS NOT NULL
    THEN DATE_DIFF(
      usg_recorded_hpl_date,
      hpl_from_usg_ga_date,
      DAY
    )
  END AS usg_recorded_minus_calculated_hpl_days,

  usg_dating_quality,
  usg_dating_quality_priority

FROM ranked

WHERE rn = 1;


-- ============================================================================
-- STAGE 5
-- BUILD NORMALIZED DELIVERY / PREGNANCY-OUTCOME EVENTS
--
-- SOURCES:
--   1. SIGIZI
--   2. EPUS
--   3. SIMRS
--   4. KOBO INC
--   5. NEONATAL OUTCOME
--   6. INC REPORT TRACKER
-- ============================================================================

CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_events_v3_3`
CLUSTER BY source_system, nik_clean, match_reference_date
AS

WITH
-- --------------------------------------------------------------------------
-- SIGIZI
-- GEO-FIXED: resolved geography only.
-- --------------------------------------------------------------------------
sigizi_source_json AS (
  SELECT
    TO_JSON_STRING(t) AS row_json
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_source_records` t
  WHERE NOT (
    is_sigizi_anon_placeholder(t.nama)
    OR is_sigizi_anon_placeholder(t.nama_norm)
  )
),

sigizi_prepared AS (
  SELECT
    COALESCE(
      NULLIF(JSON_VALUE(row_json, '$.source_table'), ''),
      NULLIF(JSON_VALUE(row_json, '$.data_source'), ''),
      'UNKNOWN'
    ) AS source_table,

    COALESCE(
      NULLIF(JSON_VALUE(row_json, '$.source_record_id'), ''),
      NULLIF(JSON_VALUE(row_json, '$.dedup_key'), ''),
      NULLIF(JSON_VALUE(row_json, '$.uuid'), ''),
      CAST(FARM_FINGERPRINT(row_json) AS STRING)
    ) AS source_record_id,

    clean_nik(
      COALESCE(
        JSON_VALUE(row_json, '$.nik_clean'),
        JSON_VALUE(row_json, '$.nik_raw'),
        JSON_VALUE(row_json, '$.nik'),
        JSON_VALUE(row_json, '$.nik_ibu')
      )
    ) AS nik_clean,

    COALESCE(
      NULLIF(JSON_VALUE(row_json, '$.nama'), ''),
      NULLIF(JSON_VALUE(row_json, '$.nama_ibu'), ''),
      NULLIF(JSON_VALUE(row_json, '$.nama_pasien'), ''),
      NULLIF(JSON_VALUE(row_json, '$.nama_raw'), '')
    ) AS nama,

    COALESCE(
      NULLIF(JSON_VALUE(row_json, '$.nama_norm'), ''),
      norm_text(
        COALESCE(
          JSON_VALUE(row_json, '$.nama'),
          JSON_VALUE(row_json, '$.nama_ibu'),
          JSON_VALUE(row_json, '$.nama_pasien'),
          JSON_VALUE(row_json, '$.nama_raw')
        )
      )
    ) AS nama_norm,

    parse_date_any(
      COALESCE(
        JSON_VALUE(row_json, '$.tanggal_lahir'),
        JSON_VALUE(row_json, '$.tanggal_lahir_date'),
        JSON_VALUE(row_json, '$.tgl_lahir_date')
      )
    ) AS tanggal_lahir,

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
    ) AS no_hp_clean,

    -- GEO FIX: ONLY the resolved Puskesmas.
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

    -- GEO FIX: ONLY the resolved Desa.
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

    parse_date_any(
      COALESCE(
        JSON_VALUE(row_json, '$.abortion_date'),
        JSON_VALUE(row_json, '$.tanggal_abortus_date'),
        JSON_VALUE(row_json, '$.tanggal_abortus'),
        JSON_VALUE(row_json, '$.tgl_abortus')
      )
    ) AS abortion_date,

    parse_date_any(
      COALESCE(
        JSON_VALUE(row_json, '$.delivery_date'),
        JSON_VALUE(row_json, '$.actual_delivery_date'),
        JSON_VALUE(row_json, '$.tanggal_melahirkan_date'),
        JSON_VALUE(row_json, '$.tanggal_melahirkan'),
        JSON_VALUE(row_json, '$.tgl_melahirkan'),
        JSON_VALUE(row_json, '$.tanggal_persalinan')
      )
    ) AS delivery_date,

    parse_date_any(
      COALESCE(
        JSON_VALUE(row_json, '$.anc_date'),
        JSON_VALUE(row_json, '$.tanggal_anc'),
        JSON_VALUE(row_json, '$.tanggal_antenatal_date')
      )
    ) AS anc_date,

    parse_date_any(
      COALESCE(
        JSON_VALUE(row_json, '$.hpht_date'),
        JSON_VALUE(row_json, '$.tanggal_hpht_date'),
        JSON_VALUE(row_json, '$.tanggal_hpht'),
        JSON_VALUE(row_json, '$.tgl_hpht')
      )
    ) AS hpht_date,

    parse_date_any(
      COALESCE(
        JSON_VALUE(row_json, '$.hpl_date'),
        JSON_VALUE(row_json, '$.hpl_recorded_date'),
        JSON_VALUE(row_json, '$.tanggal_hpl'),
        JSON_VALUE(row_json, '$.tgl_hpl'),
        JSON_VALUE(row_json, '$.tanggal_taksiran_persalinan_date')
      )
    ) AS hpl_date,

    COALESCE(
      NULLIF(JSON_VALUE(row_json, '$.outcome_raw'), ''),
      NULLIF(JSON_VALUE(row_json, '$.luaran_kehamilan'), ''),
      NULLIF(JSON_VALUE(row_json, '$.luaran'), '')
    ) AS outcome_raw,

    COALESCE(
      NULLIF(JSON_VALUE(row_json, '$.source_json'), ''),
      row_json
    ) AS source_json

  FROM sigizi_source_json
),

sigizi AS (
  SELECT
    'SIGIZI' AS source_system,

    CONCAT(
      'SIGIZI_',
      source_table
    ) AS source_subtype,

    5 AS source_priority,

    CONCAT(
      'SIGIZI|',
      source_table,
      '|',
      source_record_id
    ) AS source_event_id,

    source_record_id,

    CAST(NULL AS STRING)
      AS epus_episode_source_key,

    nik_clean,
    nama,
    nama_norm,
    tanggal_lahir,
    no_hp_clean,

    puskesmas,
    puskesmas_norm,
    desa,
    desa_norm,

    abortion_date,
    delivery_date,

    COALESCE(
      abortion_date,
      delivery_date,
      anc_date,
      hpht_date,
      hpl_date
    ) AS record_date,

    COALESCE(
      NULLIF(
        JSON_VALUE(
          source_json,
          '$.status_persalinan_lahir_hidup_lahir_mati'
        ),
        ''
      ),
      NULLIF(
        JSON_VALUE(
          source_json,
          '$.luaran_kehamilan'
        ),
        ''
      ),
      NULLIF(
        JSON_VALUE(
          source_json,
          '$.luaran'
        ),
        ''
      ),
      NULLIF(
        outcome_raw,
        ''
      )
    ) AS explicit_outcome_raw,

    COALESCE(
      NULLIF(
        JSON_VALUE(
          source_json,
          '$.keadaan_ibu'
        ),
        ''
      ),
      NULLIF(
        JSON_VALUE(
          source_json,
          '$.status_ibu'
        ),
        ''
      )
    ) AS maternal_outcome_raw,

    COALESCE(
      NULLIF(
        JSON_VALUE(
          source_json,
          '$.proses_persalinan'
        ),
        ''
      ),
      NULLIF(
        JSON_VALUE(
          source_json,
          '$.cara_persalinan'
        ),
        ''
      )
    ) AS delivery_mode_raw,

    COALESCE(
      NULLIF(
        JSON_VALUE(
          source_json,
          '$.tempat_persalinan'
        ),
        ''
      ),
      NULLIF(
        JSON_VALUE(
          source_json,
          '$.faskes'
        ),
        ''
      )
    ) AS delivery_facility_raw

  FROM sigizi_prepared
),

-- --------------------------------------------------------------------------
-- EPUS
-- --------------------------------------------------------------------------
epus_src AS (
  SELECT
    TO_JSON_STRING(t) AS j
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_master` t
),

epus AS (
  SELECT
    'EPUS' AS source_system,

    'EPUS_PREGNANCY_MASTER'
      AS source_subtype,

    4 AS source_priority,

    CONCAT(
      'EPUS|',
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.epus_pregnancy_key'), ''),
        NULLIF(JSON_VALUE(j, '$.pregnancy_key'), ''),
        CAST(FARM_FINGERPRINT(j) AS STRING)
      )
    ) AS source_event_id,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.epus_pregnancy_key'), ''),
      NULLIF(JSON_VALUE(j, '$.pregnancy_key'), ''),
      CAST(FARM_FINGERPRINT(j) AS STRING)
    ) AS source_record_id,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.epus_pregnancy_key'), ''),
      NULLIF(JSON_VALUE(j, '$.pregnancy_key'), '')
    ) AS epus_episode_source_key,

    clean_nik(
      COALESCE(
        JSON_VALUE(j, '$.nik_clean'),
        JSON_VALUE(j, '$.nik'),
        JSON_VALUE(j, '$.nik_ibu_clean')
      )
    ) AS nik_clean,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.nama_ibu'), ''),
      NULLIF(JSON_VALUE(j, '$.nama_pasien'), ''),
      NULLIF(JSON_VALUE(j, '$.nama'), '')
    ) AS nama,

    norm_text(
      COALESCE(
        JSON_VALUE(j, '$.nama_ibu'),
        JSON_VALUE(j, '$.nama_pasien'),
        JSON_VALUE(j, '$.nama')
      )
    ) AS nama_norm,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.tanggal_lahir_ibu'),
        JSON_VALUE(j, '$.tanggal_lahir_date'),
        JSON_VALUE(j, '$.tanggal_lahir')
      )
    ) AS tanggal_lahir,

    clean_phone(
      COALESCE(
        JSON_VALUE(j, '$.no_hp_clean'),
        JSON_VALUE(j, '$.nomor_hp_clean'),
        JSON_VALUE(j, '$.nomor_hp'),
        JSON_VALUE(j, '$.no_hp')
      )
    ) AS no_hp_clean,

    norm_puskesmas(
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.puskesmas_norm'), ''),
        NULLIF(JSON_VALUE(j, '$.puskesmas'), ''),
        NULLIF(JSON_VALUE(j, '$.puskesmas_name'), '')
      )
    ) AS puskesmas,

    norm_puskesmas(
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.puskesmas_norm'), ''),
        NULLIF(JSON_VALUE(j, '$.puskesmas'), ''),
        NULLIF(JSON_VALUE(j, '$.puskesmas_name'), '')
      )
    ) AS puskesmas_norm,

    norm_text(
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.desa_norm'), ''),
        NULLIF(JSON_VALUE(j, '$.desa'), ''),
        NULLIF(JSON_VALUE(j, '$.desakel'), '')
      )
    ) AS desa,

    norm_text(
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.desa_norm'), ''),
        NULLIF(JSON_VALUE(j, '$.desa'), ''),
        NULLIF(JSON_VALUE(j, '$.desakel'), '')
      )
    ) AS desa_norm,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.abortion_date'),
        JSON_VALUE(j, '$.tanggal_abortus_date'),
        JSON_VALUE(j, '$.tanggal_abortus')
      )
    ) AS abortion_date,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.actual_delivery_date'),
        JSON_VALUE(j, '$.delivery_date'),
        JSON_VALUE(j, '$.latest_delivery_event_date'),
        JSON_VALUE(j, '$.first_delivery_event_date'),
        JSON_VALUE(j, '$.delivery_event_date'),
        JSON_VALUE(j, '$.inc_tanggal_persalinan_date'),
        JSON_VALUE(j, '$.tanggal_persalinan_date'),
        JSON_VALUE(j, '$.tanggal_melahirkan_date')
      )
    ) AS delivery_date,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.latest_inc_date'),
        JSON_VALUE(j, '$.latest_pnc_date'),
        JSON_VALUE(j, '$.last_anc_date'),
        JSON_VALUE(j, '$.latest_anc_date')
      )
    ) AS record_date,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.luaran_kehamilan'), ''),
      NULLIF(JSON_VALUE(j, '$.inc_luaran_kehamilan'), ''),
      NULLIF(JSON_VALUE(j, '$.keadaan_bayi'), ''),
      NULLIF(JSON_VALUE(j, '$.inc_keadaan_bayi'), '')
    ) AS explicit_outcome_raw,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.keadaan_ibu'), ''),
      NULLIF(JSON_VALUE(j, '$.inc_keadaan_ibu'), '')
    ) AS maternal_outcome_raw,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.proses_persalinan'), ''),
      NULLIF(JSON_VALUE(j, '$.cara_persalinan'), ''),
      NULLIF(JSON_VALUE(j, '$.inc_cara_persalinan'), '')
    ) AS delivery_mode_raw,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.tempat_persalinan'), ''),
      NULLIF(JSON_VALUE(j, '$.inc_tempat_persalinan'), ''),
      NULLIF(JSON_VALUE(j, '$.faskes'), '')
    ) AS delivery_facility_raw

  FROM epus_src
),

-- --------------------------------------------------------------------------
-- SIMRS
-- --------------------------------------------------------------------------
simrs_src AS (
  SELECT
    TO_JSON_STRING(t) AS j
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_simrs_patut_patuh_inc` t
),

simrs AS (
  SELECT
    'SIMRS' AS source_system,

    'SIMRS_INC'
      AS source_subtype,

    2 AS source_priority,

    CONCAT(
      'SIMRS|',
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.source_record_id'), ''),
        NULLIF(JSON_VALUE(j, '$.dedup_key'), ''),
        NULLIF(JSON_VALUE(j, '$.source_row_hash'), ''),
        CAST(FARM_FINGERPRINT(j) AS STRING)
      )
    ) AS source_event_id,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.source_record_id'), ''),
      NULLIF(JSON_VALUE(j, '$.dedup_key'), ''),
      NULLIF(JSON_VALUE(j, '$.source_row_hash'), ''),
      CAST(FARM_FINGERPRINT(j) AS STRING)
    ) AS source_record_id,

    CAST(NULL AS STRING)
      AS epus_episode_source_key,

    clean_nik(
      COALESCE(
        JSON_VALUE(j, '$.nik_clean'),
        JSON_VALUE(j, '$.nik'),
        JSON_VALUE(j, '$.nik_ibu_clean')
      )
    ) AS nik_clean,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.nama_ibu'), ''),
      NULLIF(JSON_VALUE(j, '$.nama_pasien'), ''),
      NULLIF(JSON_VALUE(j, '$.nama'), '')
    ) AS nama,

    norm_text(
      COALESCE(
        JSON_VALUE(j, '$.nama_ibu'),
        JSON_VALUE(j, '$.nama_pasien'),
        JSON_VALUE(j, '$.nama')
      )
    ) AS nama_norm,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.tanggal_lahir_ibu'),
        JSON_VALUE(j, '$.tanggal_lahir_date'),
        JSON_VALUE(j, '$.tgl_lahir_date')
      )
    ) AS tanggal_lahir,

    clean_phone(
      COALESCE(
        JSON_VALUE(j, '$.no_hp_clean'),
        JSON_VALUE(j, '$.nomor_hp_clean'),
        JSON_VALUE(j, '$.nomor_hp'),
        JSON_VALUE(j, '$.no_hp')
      )
    ) AS no_hp_clean,

    norm_puskesmas(
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.puskesmas'), ''),
        NULLIF(JSON_VALUE(j, '$.faskes'), '')
      )
    ) AS puskesmas,

    norm_puskesmas(
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.puskesmas'), ''),
        NULLIF(JSON_VALUE(j, '$.faskes'), '')
      )
    ) AS puskesmas_norm,

    norm_text(
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.desa'), ''),
        NULLIF(JSON_VALUE(j, '$.kelurahan'), '')
      )
    ) AS desa,

    norm_text(
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.desa'), ''),
        NULLIF(JSON_VALUE(j, '$.kelurahan'), '')
      )
    ) AS desa_norm,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.abortion_date'),
        JSON_VALUE(j, '$.tanggal_abortus_date')
      )
    ) AS abortion_date,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.usable_delivery_date'),
        JSON_VALUE(j, '$.actual_delivery_date'),
        JSON_VALUE(j, '$.delivery_date'),
        JSON_VALUE(j, '$.tanggal_melahirkan'),
        JSON_VALUE(j, '$.tanggal_persalinan_date'),
        JSON_VALUE(j, '$.tgl_inc_bayi_date'),
        JSON_VALUE(j, '$.tgl_inc_bayi')
      )
    ) AS delivery_date,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.usable_delivery_date'),
        JSON_VALUE(j, '$.tgl_inc_bayi_date'),
        JSON_VALUE(j, '$.tgl_inc_bayi'),
        JSON_VALUE(j, '$.file_date')
      )
    ) AS record_date,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.luaran_kehamilan'), ''),
      NULLIF(JSON_VALUE(j, '$.keadaan_bayi'), ''),
      NULLIF(JSON_VALUE(j, '$.status_bayi'), '')
    ) AS explicit_outcome_raw,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.keadaan_ibu'), ''),
      NULLIF(JSON_VALUE(j, '$.status_ibu'), '')
    ) AS maternal_outcome_raw,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.proses_persalinan'), ''),
      NULLIF(JSON_VALUE(j, '$.cara_persalinan'), '')
    ) AS delivery_mode_raw,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.faskes'), ''),
      NULLIF(JSON_VALUE(j, '$.rumah_sakit'), ''),
      NULLIF(JSON_VALUE(j, '$.facility_name'), '')
    ) AS delivery_facility_raw

  FROM simrs_src
),

-- --------------------------------------------------------------------------
-- KOBO INC CASE MASTER
-- --------------------------------------------------------------------------
kobo_src AS (
  SELECT
    TO_JSON_STRING(t) AS j
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_kobo_inc_case_master` t
),

kobo AS (
  SELECT
    'KOBO_INC' AS source_system,

    'KOBO_INC_CASE_MASTER'
      AS source_subtype,

    1 AS source_priority,

    CONCAT(
      'KOBO_INC|',
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.case_id'), ''),
        NULLIF(JSON_VALUE(j, '$.source_submission_id'), ''),
        CAST(FARM_FINGERPRINT(j) AS STRING)
      )
    ) AS source_event_id,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.case_id'), ''),
      NULLIF(JSON_VALUE(j, '$.source_submission_id'), ''),
      CAST(FARM_FINGERPRINT(j) AS STRING)
    ) AS source_record_id,

    CAST(NULL AS STRING)
      AS epus_episode_source_key,

    clean_nik(
      COALESCE(
        JSON_VALUE(j, '$.nik_ibu_clean'),
        JSON_VALUE(j, '$.nik_clean'),
        JSON_VALUE(j, '$.nik_ibu'),
        JSON_VALUE(j, '$.nik')
      )
    ) AS nik_clean,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.nama_ibu'), ''),
      NULLIF(JSON_VALUE(j, '$.nama_lengkap'), ''),
      NULLIF(JSON_VALUE(j, '$.nama'), '')
    ) AS nama,

    norm_text(
      COALESCE(
        JSON_VALUE(j, '$.nama_ibu'),
        JSON_VALUE(j, '$.nama_lengkap'),
        JSON_VALUE(j, '$.nama')
      )
    ) AS nama_norm,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.tanggal_lahir_ibu'),
        JSON_VALUE(j, '$.tanggal_lahir_date'),
        JSON_VALUE(j, '$.tgl_lahir_ibu')
      )
    ) AS tanggal_lahir,

    clean_phone(
      COALESCE(
        JSON_VALUE(j, '$.no_hp_clean'),
        JSON_VALUE(j, '$.nomor_hp_clean'),
        JSON_VALUE(j, '$.nomor_hp'),
        JSON_VALUE(j, '$.no_hp'),
        JSON_VALUE(j, '$.phone_number')
      )
    ) AS no_hp_clean,

    norm_puskesmas(
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.puskesmas'), ''),
        NULLIF(JSON_VALUE(j, '$.Pilih_Nama_Puskesmas'), ''),
        NULLIF(JSON_VALUE(j, '$.facility_name'), '')
      )
    ) AS puskesmas,

    norm_puskesmas(
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.puskesmas'), ''),
        NULLIF(JSON_VALUE(j, '$.Pilih_Nama_Puskesmas'), ''),
        NULLIF(JSON_VALUE(j, '$.facility_name'), '')
      )
    ) AS puskesmas_norm,

    norm_text(
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.desa'), ''),
        NULLIF(JSON_VALUE(j, '$.desakel'), '')
      )
    ) AS desa,

    norm_text(
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.desa'), ''),
        NULLIF(JSON_VALUE(j, '$.desakel'), '')
      )
    ) AS desa_norm,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.abortion_date'),
        JSON_VALUE(j, '$.tanggal_abortus'),
        JSON_VALUE(j, '$.tanggal_abortus_date')
      )
    ) AS abortion_date,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.delivery_date'),
        JSON_VALUE(j, '$.actual_delivery_date'),
        JSON_VALUE(j, '$.tanggal_melahirkan'),
        JSON_VALUE(j, '$.tanggal_melahirkan_date'),
        JSON_VALUE(j, '$.tanggal_persalinan'),
        JSON_VALUE(j, '$.tanggal_persalinan_date'),
        JSON_VALUE(j, '$.birth_date')
      )
    ) AS delivery_date,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.submitted_at'),
        JSON_VALUE(j, '$.end'),
        JSON_VALUE(j, '$.start'),
        JSON_VALUE(j, '$.submission_date'),
        JSON_VALUE(j, '$.created_at')
      )
    ) AS record_date,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.luaran_kehamilan'), ''),
      NULLIF(JSON_VALUE(j, '$.pregnancy_outcome'), ''),
      NULLIF(JSON_VALUE(j, '$.outcome_final'), '')
    ) AS explicit_outcome_raw,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.keadaan_ibu'), ''),
      NULLIF(JSON_VALUE(j, '$.maternal_outcome'), '')
    ) AS maternal_outcome_raw,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.proses_persalinan'), ''),
      NULLIF(JSON_VALUE(j, '$.cara_persalinan'), '')
    ) AS delivery_mode_raw,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.faskes'), ''),
      NULLIF(JSON_VALUE(j, '$.facility_name'), ''),
      NULLIF(JSON_VALUE(j, '$.tempat_persalinan'), '')
    ) AS delivery_facility_raw

  FROM kobo_src
),

-- --------------------------------------------------------------------------
-- NEONATAL OUTCOME
-- --------------------------------------------------------------------------
neo_src AS (
  SELECT
    TO_JSON_STRING(t) AS j
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_kobo_neonatus_outcome_v2_baby` t
),

neo AS (
  SELECT
    'NEONATAL_OUTCOME'
      AS source_system,

    'KOBO_NEONATAL_OUTCOME'
      AS source_subtype,

    6 AS source_priority,

    CONCAT(
      'NEONATAL|',
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.source_submission_id'), ''),
        CAST(FARM_FINGERPRINT(j) AS STRING)
      ),
      '|',
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.baby_number'), ''),
        '1'
      )
    ) AS source_event_id,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.source_submission_id'), ''),
      CAST(FARM_FINGERPRINT(j) AS STRING)
    ) AS source_record_id,

    CAST(NULL AS STRING)
      AS epus_episode_source_key,

    clean_nik(
      COALESCE(
        JSON_VALUE(j, '$.nik_ibu_clean'),
        JSON_VALUE(j, '$.nik_clean'),
        JSON_VALUE(j, '$.nik_ibu')
      )
    ) AS nik_clean,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.nama_ibu'), ''),
      NULLIF(JSON_VALUE(j, '$.nama_lengkap'), '')
    ) AS nama,

    norm_text(
      COALESCE(
        JSON_VALUE(j, '$.nama_ibu'),
        JSON_VALUE(j, '$.nama_lengkap')
      )
    ) AS nama_norm,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.tanggal_lahir_ibu'),
        JSON_VALUE(j, '$.tanggal_lahir_ibu_date')
      )
    ) AS tanggal_lahir,

    clean_phone(
      COALESCE(
        JSON_VALUE(j, '$.nomor_hp_clean'),
        JSON_VALUE(j, '$.no_hp_clean'),
        JSON_VALUE(j, '$.nomor_hp')
      )
    ) AS no_hp_clean,

    norm_puskesmas(
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.puskesmas_norm'), ''),
        NULLIF(JSON_VALUE(j, '$.puskesmas'), '')
      )
    ) AS puskesmas,

    norm_puskesmas(
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.puskesmas_norm'), ''),
        NULLIF(JSON_VALUE(j, '$.puskesmas'), '')
      )
    ) AS puskesmas_norm,

    norm_text(
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.desa_norm'), ''),
        NULLIF(JSON_VALUE(j, '$.desa'), '')
      )
    ) AS desa,

    norm_text(
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.desa_norm'), ''),
        NULLIF(JSON_VALUE(j, '$.desa'), '')
      )
    ) AS desa_norm,

    CAST(NULL AS DATE)
      AS abortion_date,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.birth_date'),
        JSON_VALUE(j, '$.birth_date_parsed'),
        JSON_VALUE(j, '$.tanggal_melahirkan')
      )
    ) AS delivery_date,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.birth_date'),
        JSON_VALUE(j, '$.birth_date_parsed'),
        JSON_VALUE(j, '$.submitted_at')
      )
    ) AS record_date,

    'LAHIR HIDUP'
      AS explicit_outcome_raw,

    CAST(NULL AS STRING)
      AS maternal_outcome_raw,

    CAST(NULL AS STRING)
      AS delivery_mode_raw,

    CAST(NULL AS STRING)
      AS delivery_facility_raw

  FROM neo_src
),

-- --------------------------------------------------------------------------
-- INC REPORT TRACKER
-- Outcome is intentionally read only from luaran_kehamilan_detail/report.
-- --------------------------------------------------------------------------
inc_report AS (
  SELECT
    'INC_REPORT_TRACKER'
      AS source_system,

    'INC_REPORT_TRACKER'
      AS source_subtype,

    3 AS source_priority,

    CONCAT(
      'INC_REPORT|',
      COALESCE(
        row_hash,
        CAST(
          FARM_FINGERPRINT(
            TO_JSON_STRING(t)
          )
          AS STRING
        )
      )
    ) AS source_event_id,

    COALESCE(
      row_hash,
      CAST(
        FARM_FINGERPRINT(
          TO_JSON_STRING(t)
        )
        AS STRING
      )
    ) AS source_record_id,

    CAST(NULL AS STRING)
      AS epus_episode_source_key,

    clean_nik(
      COALESCE(
        nik_clean,
        nik
      )
    ) AS nik_clean,

    nama_lengkap AS nama,

    norm_text(
      nama_lengkap
    ) AS nama_norm,

    CAST(NULL AS DATE)
      AS tanggal_lahir,

    clean_phone(
      nomor_hp
    ) AS no_hp_clean,

    norm_puskesmas(
      faskes
    ) AS puskesmas,

    norm_puskesmas(
      faskes
    ) AS puskesmas_norm,

    norm_text(desa)
      AS desa,

    norm_text(desa)
      AS desa_norm,

    CASE
      WHEN classify_explicit_outcome(
        COALESCE(
          NULLIF(
            luaran_kehamilan_detail,
            ''
          ),
          NULLIF(
            luaran_kehamilan_report,
            ''
          )
        )
      ) = 'ABORTUS'
      THEN tanggal_melahirkan
    END AS abortion_date,

    tanggal_melahirkan
      AS delivery_date,

    COALESCE(
      tanggal_melahirkan,
      date
    ) AS record_date,

    COALESCE(
      NULLIF(
        luaran_kehamilan_detail,
        ''
      ),
      NULLIF(
        luaran_kehamilan_report,
        ''
      )
    ) AS explicit_outcome_raw,

    keadaan_ibu
      AS maternal_outcome_raw,

    proses_persalinan
      AS delivery_mode_raw,

    faskes
      AS delivery_facility_raw

  FROM
    `spheres-lombok-barat.birth_report_faskes.v_inc_report_tracker` t
),

unioned AS (
  SELECT * FROM sigizi
  UNION ALL
  SELECT * FROM epus
  UNION ALL
  SELECT * FROM simrs
  UNION ALL
  SELECT * FROM kobo
  UNION ALL
  SELECT * FROM neo
  UNION ALL
  SELECT * FROM inc_report
),

classified AS (
  SELECT
    *,

    norm_text(
      maternal_outcome_raw
    ) AS maternal_outcome_norm,

    norm_text(
      delivery_mode_raw
    ) AS delivery_mode_norm,

    norm_text(
      delivery_facility_raw
    ) AS delivery_facility_norm,

    CASE
      WHEN source_system = 'NEONATAL_OUTCOME'
        THEN 'LAHIR HIDUP'

      WHEN abortion_date IS NOT NULL
        THEN 'ABORTUS'

      ELSE classify_explicit_outcome(
        explicit_outcome_raw
      )
    END AS pregnancy_outcome_norm,

    COALESCE(
      abortion_date,
      delivery_date,
      record_date
    ) AS match_reference_date

  FROM unioned
)

SELECT *
FROM classified

WHERE delivery_date IS NOT NULL
   OR abortion_date IS NOT NULL
   OR pregnancy_outcome_norm IS NOT NULL;


-- ============================================================================
-- STAGE 6
-- MATCH OUTCOME EVENTS TO THE CANONICAL PREGNANCY SPINE
-- ============================================================================

