-- ============================================================================
-- PURBALINGGA
-- 03_build_epus_source_records_v1.sql
--
-- OUTPUT:
--   stellar-orb-451904-d9.kohort_bumil_v2.t_epus_source_records
--
-- GRAIN:
--   One row = one normalized raw ePUS source record/event
--
-- INCLUDED:
--   1. epus_anc
--   2. epus_kunjungan_ibu_hamil
--   3. epus_inc
--   4. epus_pnc
--
-- CURRENTLY EXCLUDED:
--   epus_kunjungan_ibu_hamil_update
--   epus_pnc_copy
--   epus_kohort_kia
--
-- They are NOT deleted/ignored permanently. We will audit whether they are
-- incremental, historical, or duplicate extracts before adding them.
--
-- PREGNANCY DENOMINATOR CREATORS:
--   EPUS_ANC
--   EPUS_KUNJUNGAN_IBU_HAMIL
--
-- OUTCOME / SUPPORTING EVIDENCE ONLY:
--   EPUS_INC
--   EPUS_PNC
--
-- IMPORTANT:
--   The field "abortus" in ANC/INC/PNC is part of gravida/partus/abortus
--   obstetric history. It must NOT automatically be interpreted as the
--   outcome of the current pregnancy.
--
-- TIMEZONE:
--   Asia/Jakarta
-- ============================================================================


DECLARE analysis_date DATE
  DEFAULT CURRENT_DATE('Asia/Jakarta');

DECLARE minimum_valid_date DATE
  DEFAULT DATE '2010-01-01';

DECLARE maximum_hpl_date DATE
  DEFAULT DATE_ADD(
    analysis_date,
    INTERVAL 300 DAY
  );



-- ============================================================================
-- 1. TEXT NORMALIZATION
-- ============================================================================

CREATE TEMP FUNCTION norm_text(s STRING)
RETURNS STRING
AS (
  NULLIF(
    REGEXP_REPLACE(
      UPPER(
        TRIM(
          NORMALIZE(
            COALESCE(s, ''),
            NFKC
          )
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

    ELSE REGEXP_REPLACE(
      norm_text(s),
      r'^PUSKESMAS\s+',
      ''
    )

  END
);



-- ============================================================================
-- 2. NIK NORMALIZATION
-- ============================================================================

CREATE TEMP FUNCTION clean_nik(s STRING)
RETURNS STRING
AS (
  CASE

    WHEN REGEXP_CONTAINS(
      REGEXP_REPLACE(
        COALESCE(s, ''),
        r'[^0-9]',
        ''
      ),
      r'^\d{16}$'
    )

    AND REGEXP_REPLACE(
      COALESCE(s, ''),
      r'[^0-9]',
      ''
    ) NOT IN (
      '0000000000000000',
      '9999999999999999'
    )

    THEN REGEXP_REPLACE(
      COALESCE(s, ''),
      r'[^0-9]',
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



-- ============================================================================
-- 3. ROBUST DATE PARSER
--
-- ePUS is Indonesian operational data, therefore ambiguous numeric dates
-- are treated as DAY-MONTH-YEAR.
--
-- Two-digit years:
--   00–39 -> 2000–2039
--   40–99 -> 1940–1999
-- ============================================================================

CREATE TEMP FUNCTION parse_date_any(s STRING)
RETURNS DATE
AS (

  CASE

    WHEN NULLIF(TRIM(s), '') IS NULL
      THEN NULL


    -- YYYY-MM-DD
    WHEN REGEXP_CONTAINS(
      TRIM(s),
      r'^\d{4}-\d{1,2}-\d{1,2}$'
    )

    THEN SAFE.PARSE_DATE(
      '%Y-%m-%d',
      TRIM(s)
    )


    -- YYYY/MM/DD
    WHEN REGEXP_CONTAINS(
      TRIM(s),
      r'^\d{4}/\d{1,2}/\d{1,2}$'
    )

    THEN SAFE.PARSE_DATE(
      '%Y/%m/%d',
      TRIM(s)
    )


    -- DD-MM-YYYY
    WHEN REGEXP_CONTAINS(
      TRIM(s),
      r'^\d{1,2}-\d{1,2}-\d{4}$'
    )

    THEN SAFE.PARSE_DATE(
      '%d-%m-%Y',
      TRIM(s)
    )


    -- DD/MM/YYYY
    WHEN REGEXP_CONTAINS(
      TRIM(s),
      r'^\d{1,2}/\d{1,2}/\d{4}$'
    )

    THEN SAFE.PARSE_DATE(
      '%d/%m/%Y',
      TRIM(s)
    )


    -- DD-MM-YY
    WHEN REGEXP_CONTAINS(
      TRIM(s),
      r'^\d{1,2}-\d{1,2}-\d{2}$'
    )

    THEN SAFE.PARSE_DATE(
      '%d-%m-%Y',

      CONCAT(
        SPLIT(TRIM(s), '-')[SAFE_OFFSET(0)],
        '-',
        SPLIT(TRIM(s), '-')[SAFE_OFFSET(1)],
        '-',

        CAST(
          CASE

            WHEN SAFE_CAST(
              SPLIT(TRIM(s), '-')[SAFE_OFFSET(2)]
              AS INT64
            ) <= 39

            THEN 2000
              + SAFE_CAST(
                  SPLIT(TRIM(s), '-')[SAFE_OFFSET(2)]
                  AS INT64
                )

            ELSE 1900
              + SAFE_CAST(
                  SPLIT(TRIM(s), '-')[SAFE_OFFSET(2)]
                  AS INT64
                )

          END AS STRING
        )
      )
    )


    -- DD/MM/YY
    WHEN REGEXP_CONTAINS(
      TRIM(s),
      r'^\d{1,2}/\d{1,2}/\d{2}$'
    )

    THEN SAFE.PARSE_DATE(
      '%d/%m/%Y',

      CONCAT(
        SPLIT(TRIM(s), '/')[SAFE_OFFSET(0)],
        '/',
        SPLIT(TRIM(s), '/')[SAFE_OFFSET(1)],
        '/',

        CAST(
          CASE

            WHEN SAFE_CAST(
              SPLIT(TRIM(s), '/')[SAFE_OFFSET(2)]
              AS INT64
            ) <= 39

            THEN 2000
              + SAFE_CAST(
                  SPLIT(TRIM(s), '/')[SAFE_OFFSET(2)]
                  AS INT64
                )

            ELSE 1900
              + SAFE_CAST(
                  SPLIT(TRIM(s), '/')[SAFE_OFFSET(2)]
                  AS INT64
                )

          END AS STRING
        )
      )
    )


    -- Nov 15, 2024
    WHEN REGEXP_CONTAINS(
      TRIM(s),
      r'^[A-Za-z]{3}\s+\d{1,2},\s+\d{4}$'
    )

    THEN SAFE.PARSE_DATE(
      '%b %e, %Y',
      TRIM(s)
    )


    -- November 15, 2024
    WHEN REGEXP_CONTAINS(
      TRIM(s),
      r'^[A-Za-z]+\s+\d{1,2},\s+\d{4}$'
    )

    THEN SAFE.PARSE_DATE(
      '%B %e, %Y',
      TRIM(s)
    )


    -- ISO timestamp-like
    WHEN REGEXP_CONTAINS(
      TRIM(s),
      r'^\d{4}-\d{1,2}-\d{1,2}[ T]'
    )

    THEN SAFE.PARSE_DATE(
      '%Y-%m-%d',
      REGEXP_EXTRACT(
        TRIM(s),
        r'^(\d{4}-\d{1,2}-\d{1,2})'
      )
    )


    -- Excel serial
    WHEN REGEXP_CONTAINS(
      TRIM(s),
      r'^\d{5}(?:\.0+)?$'
    )

    THEN DATE_ADD(
      DATE '1899-12-30',

      INTERVAL SAFE_CAST(
        REGEXP_EXTRACT(
          TRIM(s),
          r'^\d+'
        )
        AS INT64
      ) DAY
    )


    ELSE NULL

  END
);



-- ============================================================================
-- 4. TIMESTAMP PARSER
-- ============================================================================

CREATE TEMP FUNCTION parse_timestamp_any(s STRING)
RETURNS TIMESTAMP
AS (
  COALESCE(

    SAFE_CAST(
      NULLIF(TRIM(s), '')
      AS TIMESTAMP
    ),

    SAFE.PARSE_TIMESTAMP(
      '%Y-%m-%dT%H:%M:%E*S',
      NULLIF(TRIM(s), '')
    ),

    SAFE.PARSE_TIMESTAMP(
      '%Y-%m-%d %H:%M:%E*S',
      NULLIF(TRIM(s), '')
    )

  )
);



-- ============================================================================
-- 5. UNION RAW EPUS SOURCES
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_source_records`

PARTITION BY event_date

CLUSTER BY
  source_table,
  event_type,
  nik_clean,
  puskesmas_norm

AS

WITH source_union AS (


  -- ==========================================================================
  -- EPUS ANC
  -- ==========================================================================

  SELECT

    'EPUS_ANC'
      AS source_table,

    1
      AS source_priority,

    'ANC'
      AS event_type,

    'ANC_VISIT'
      AS record_grain,

    TRUE
      AS pregnancy_episode_creator_flag,

    'PREGNANCY_SPINE'
      AS source_role,

    TO_JSON_STRING(t)
      AS source_json

  FROM
    `stellar-orb-451904-d9.raw_data.epus_anc` t



  UNION ALL



  -- ==========================================================================
  -- EPUS KUNJUNGAN IBU HAMIL
  -- ==========================================================================

  SELECT

    'EPUS_KUNJUNGAN_IBU_HAMIL'
      AS source_table,

    2
      AS source_priority,

    'ANC'
      AS event_type,

    'ANC_VISIT'
      AS record_grain,

    TRUE
      AS pregnancy_episode_creator_flag,

    'PREGNANCY_SPINE'
      AS source_role,

    TO_JSON_STRING(t)
      AS source_json

  FROM
    `stellar-orb-451904-d9.raw_data.epus_kunjungan_ibu_hamil` t



  UNION ALL



  -- ==========================================================================
  -- EPUS INC
  --
  -- Delivery/outcome evidence.
  --
  -- It does NOT independently create the ANC pregnancy denominator.
  -- ==========================================================================

  SELECT

    'EPUS_INC'
      AS source_table,

    3
      AS source_priority,

    'DELIVERY'
      AS event_type,

    'DELIVERY_RECORD'
      AS record_grain,

    FALSE
      AS pregnancy_episode_creator_flag,

    'OUTCOME_ENRICHMENT'
      AS source_role,

    TO_JSON_STRING(t)
      AS source_json

  FROM
    `stellar-orb-451904-d9.raw_data.epus_inc` t



  UNION ALL



  -- ==========================================================================
  -- EPUS PNC
  --
  -- Current Purbalingga PNC table provides postpartum visit date but not a
  -- reliable current delivery-date field.
  -- ==========================================================================

  SELECT

    'EPUS_PNC'
      AS source_table,

    4
      AS source_priority,

    'PNC'
      AS event_type,

    'PNC_VISIT'
      AS record_grain,

    FALSE
      AS pregnancy_episode_creator_flag,

    'OUTCOME_ENRICHMENT'
      AS source_role,

    TO_JSON_STRING(t)
      AS source_json

  FROM
    `stellar-orb-451904-d9.raw_data.epus_pnc` t

),



-- ============================================================================
-- 6. EXTRACT SOURCE-SPECIFIC RAW VALUES
-- ============================================================================

extracted AS (

  SELECT

    source_table,
    source_priority,

    event_type,
    record_grain,

    pregnancy_episode_creator_flag,
    source_role,


    -- ------------------------------------------------------------------------
    -- RECORD ID
    -- ------------------------------------------------------------------------

    COALESCE(

      NULLIF(
        JSON_VALUE(source_json, '$.uuid'),
        ''
      ),

      NULLIF(
        JSON_VALUE(source_json, '$.hash_code'),
        ''
      ),

      NULLIF(
        JSON_VALUE(source_json, '$.id'),
        ''
      ),

      NULLIF(
        JSON_VALUE(source_json, '$.no'),
        ''
      ),

      CAST(
        FARM_FINGERPRINT(source_json)
        AS STRING
      )

    ) AS source_record_id,


    -- ------------------------------------------------------------------------
    -- NIK
    -- ------------------------------------------------------------------------

    CASE source_table

      WHEN 'EPUS_KUNJUNGAN_IBU_HAMIL'
      THEN NULLIF(
        JSON_VALUE(
          source_json,
          '$.register_nik'
        ),
        ''
      )

      ELSE COALESCE(
        NULLIF(
          JSON_VALUE(source_json, '$.nik'),
          ''
        ),

        NULLIF(
          JSON_VALUE(source_json, '$.nik_ibu'),
          ''
        )
      )

    END AS nik_raw,


    -- ------------------------------------------------------------------------
    -- NAME
    -- ------------------------------------------------------------------------

    CASE source_table

      WHEN 'EPUS_KUNJUNGAN_IBU_HAMIL'
      THEN NULLIF(
        JSON_VALUE(
          source_json,
          '$.register_nama_ibu'
        ),
        ''
      )

      ELSE COALESCE(
        NULLIF(
          JSON_VALUE(source_json, '$.nama_pasien'),
          ''
        ),

        NULLIF(
          JSON_VALUE(source_json, '$.nama_ibu'),
          ''
        )
      )

    END AS nama_raw,


    -- ------------------------------------------------------------------------
    -- DOB
    -- ------------------------------------------------------------------------

    CASE source_table

      WHEN 'EPUS_KUNJUNGAN_IBU_HAMIL'
      THEN NULLIF(
        JSON_VALUE(
          source_json,
          '$.register_tanggal_lahir'
        ),
        ''
      )

      ELSE NULLIF(
        JSON_VALUE(
          source_json,
          '$.tanggal_lahir'
        ),
        ''
      )

    END AS dob_raw,


    -- ------------------------------------------------------------------------
    -- HPHT
    -- ------------------------------------------------------------------------

    CASE source_table

      WHEN 'EPUS_KUNJUNGAN_IBU_HAMIL'
      THEN NULLIF(
        JSON_VALUE(
          source_json,
          '$.register_tanggal_hpht'
        ),
        ''
      )

      ELSE NULLIF(
        JSON_VALUE(
          source_json,
          '$.tanggal_hpht'
        ),
        ''
      )

    END AS hpht_raw,


    -- ------------------------------------------------------------------------
    -- HPL
    -- ------------------------------------------------------------------------

    CASE source_table

      WHEN 'EPUS_KUNJUNGAN_IBU_HAMIL'
      THEN NULLIF(
        JSON_VALUE(
          source_json,
          '$.register_taksiran_persalinan'
        ),
        ''
      )

      ELSE NULLIF(
        JSON_VALUE(
          source_json,
          '$.tanggal_taksiran_persalinan'
        ),
        ''
      )

    END AS hpl_raw,


    -- ------------------------------------------------------------------------
    -- PREVIOUS DELIVERY DATE
    --
    -- This is historical obstetric history only.
    -- It is NOT the current pregnancy's delivery date.
    -- ------------------------------------------------------------------------

    NULLIF(
      JSON_VALUE(
        source_json,
        '$.tanggal_persalinan_sebelumnya'
      ),
      ''
    ) AS previous_delivery_raw,


    -- ------------------------------------------------------------------------
    -- ANC EVENT DATE
    -- ------------------------------------------------------------------------

    CASE source_table

      WHEN 'EPUS_ANC'
      THEN NULLIF(
        JSON_VALUE(
          source_json,
          '$.tanggal_antenatal'
        ),
        ''
      )


      WHEN 'EPUS_KUNJUNGAN_IBU_HAMIL'
      THEN COALESCE(

        NULLIF(
          JSON_VALUE(
            source_json,
            '$.register_tanggal'
          ),
          ''
        ),

        NULLIF(
          JSON_VALUE(
            source_json,
            '$.tanggal_kunjungan'
          ),
          ''
        ),

        NULLIF(
          JSON_VALUE(
            source_json,
            '$.tanggal_anc'
          ),
          ''
        )

      )


      ELSE NULL

    END AS anc_raw,


    -- ------------------------------------------------------------------------
    -- PNC DATE
    -- ------------------------------------------------------------------------

    CASE

      WHEN source_table = 'EPUS_PNC'

      THEN NULLIF(
        JSON_VALUE(
          source_json,
          '$.tanggal_pnc'
        ),
        ''
      )

    END AS pnc_raw,


    -- ------------------------------------------------------------------------
    -- INC DELIVERY DATES
    --
    -- Keep both dates before choosing a canonical value.
    -- ------------------------------------------------------------------------

    CASE

      WHEN source_table = 'EPUS_INC'

      THEN NULLIF(
        JSON_VALUE(
          source_json,
          '$.tanggal_persalinan'
        ),
        ''
      )

    END AS tanggal_persalinan_raw,


    CASE

      WHEN source_table = 'EPUS_INC'

      THEN NULLIF(
        JSON_VALUE(
          source_json,
          '$.bayi_lahir_tanggal'
        ),
        ''
      )

    END AS bayi_lahir_tanggal_raw,


    CASE

      WHEN source_table = 'EPUS_INC'

      THEN NULLIF(
        JSON_VALUE(
          source_json,
          '$.bayi_lahir_jam'
        ),
        ''
      )

    END AS bayi_lahir_jam_raw,


    -- ------------------------------------------------------------------------
    -- OBSTETRIC HISTORY: ABORTUS
    --
    -- DO NOT interpret this as current pregnancy outcome.
    -- ------------------------------------------------------------------------

    NULLIF(
      JSON_VALUE(
        source_json,
        '$.abortus'
      ),
      ''
    ) AS abortus_history_raw,


    -- ------------------------------------------------------------------------
    -- KUNJUNGAN: ABORTION COMPLICATION SIGNAL
    --
    -- Preserved only as raw supporting evidence.
    -- ------------------------------------------------------------------------

    CASE

      WHEN source_table = 'EPUS_KUNJUNGAN_IBU_HAMIL'

      THEN NULLIF(
        JSON_VALUE(
          source_json,
          '$.integrasi_program_komplikasi_abortus'
        ),
        ''
      )

    END AS abortus_complication_raw,


    -- ------------------------------------------------------------------------
    -- USG
    -- ------------------------------------------------------------------------

    CASE

      WHEN source_table = 'EPUS_ANC'

      THEN NULLIF(
        JSON_VALUE(
          source_json,
          '$.usg_usia_kehamilan'
        ),
        ''
      )

    END AS usg_usia_kehamilan_raw,


    CASE

      WHEN source_table = 'EPUS_ANC'

      THEN NULLIF(
        JSON_VALUE(
          source_json,
          '$.usg_perkiraan_lahir'
        ),
        ''
      )

    END AS usg_perkiraan_lahir_raw,


    -- ------------------------------------------------------------------------
    -- DELIVERY / OUTCOME CLINICAL FIELDS
    -- ------------------------------------------------------------------------

    CASE

      WHEN source_table = 'EPUS_INC'

      THEN NULLIF(
        JSON_VALUE(
          source_json,
          '$.usia_kehamilan'
        ),
        ''
      )

    END AS delivery_ga_raw,


    CASE

      WHEN source_table = 'EPUS_INC'

      THEN NULLIF(
        JSON_VALUE(
          source_json,
          '$.usia_hpht'
        ),
        ''
      )

    END AS delivery_ga_hpht_raw,


    CASE

      WHEN source_table = 'EPUS_INC'

      THEN NULLIF(
        JSON_VALUE(
          source_json,
          '$.bb_bayi'
        ),
        ''
      )

    END AS birth_weight_raw,


    CASE

      WHEN source_table = 'EPUS_INC'

      THEN NULLIF(
        JSON_VALUE(
          source_json,
          '$.cara_persalinan'
        ),
        ''
      )

    END AS delivery_mode_raw,


    CASE

      WHEN source_table = 'EPUS_INC'

      THEN COALESCE(

        NULLIF(
          JSON_VALUE(
            source_json,
            '$.keadaan_bayi'
          ),
          ''
        ),

        NULLIF(
          JSON_VALUE(
            source_json,
            '$.keterangan_kondisi_lahir'
          ),
          ''
        )

      )

    END AS baby_outcome_raw,


    CASE

      WHEN source_table = 'EPUS_INC'

      THEN COALESCE(

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
            '$.keadaan_pulang_persalinan'
          ),
          ''
        )

      )

    END AS maternal_outcome_raw,


    CASE

      WHEN source_table = 'EPUS_INC'

      THEN NULLIF(
        JSON_VALUE(
          source_json,
          '$.komplikasi_persalinan'
        ),
        ''
      )

    END AS delivery_complication_raw,


    -- ------------------------------------------------------------------------
    -- PUSKESMAS
    -- ------------------------------------------------------------------------

    COALESCE(

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.puskesmas_name'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.nama_faskes'
        ),
        ''
      )

    ) AS puskesmas_raw,


    NULLIF(
      JSON_VALUE(
        source_json,
        '$.puskesmas_id'
      ),
      ''
    ) AS puskesmas_id,


    -- ------------------------------------------------------------------------
    -- DESA / ADDRESS
    -- ------------------------------------------------------------------------

    COALESCE(

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.register_desa'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.desa'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.desakel'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.kelurahan'
        ),
        ''
      )

    ) AS desa_raw,


    COALESCE(

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.register_alamat'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.alamat'
        ),
        ''
      )

    ) AS alamat_raw,


    -- ------------------------------------------------------------------------
    -- PHONE
    -- ------------------------------------------------------------------------

    COALESCE(

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.no_hp'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.nomor_hp'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.register_no_hp'
        ),
        ''
      )

    ) AS no_hp_raw,


    -- ------------------------------------------------------------------------
    -- FILE PROVENANCE
    -- ------------------------------------------------------------------------

    NULLIF(
      JSON_VALUE(
        source_json,
        '$.file_name'
      ),
      ''
    ) AS file_name,


    NULLIF(
      JSON_VALUE(
        source_json,
        '$.file_date'
      ),
      ''
    ) AS file_date_raw,


    NULLIF(
      JSON_VALUE(
        source_json,
        '$.ingestion_timestamp'
      ),
      ''
    ) AS ingestion_timestamp_raw,


    NULLIF(
      JSON_VALUE(
        source_json,
        '$.uuid'
      ),
      ''
    ) AS source_uuid,


    NULLIF(
      JSON_VALUE(
        source_json,
        '$.hash_code'
      ),
      ''
    ) AS source_hash_code,


    source_json

  FROM source_union

),



-- ============================================================================
-- 7. PARSE
-- ============================================================================

parsed AS (

  SELECT

    *,

    clean_nik(nik_raw)
      AS nik_clean,

    norm_text(nama_raw)
      AS nama_norm,

    parse_date_any(dob_raw)
      AS tanggal_lahir_parsed,

    parse_date_any(hpht_raw)
      AS hpht_date_parsed,

    parse_date_any(hpl_raw)
      AS hpl_date_parsed,

    parse_date_any(previous_delivery_raw)
      AS previous_delivery_date_parsed,

    parse_date_any(anc_raw)
      AS anc_date_parsed,

    parse_date_any(pnc_raw)
      AS pnc_date_parsed,

    parse_date_any(tanggal_persalinan_raw)
      AS tanggal_persalinan_parsed,

    parse_date_any(bayi_lahir_tanggal_raw)
      AS bayi_lahir_tanggal_parsed,

    parse_date_any(usg_perkiraan_lahir_raw)
      AS usg_hpl_date_parsed,

    SAFE_CAST(
      REGEXP_EXTRACT(
        usg_usia_kehamilan_raw,
        r'(\d{1,2})'
      )
      AS INT64
    ) AS usg_ga_weeks,

    norm_puskesmas(puskesmas_raw)
      AS puskesmas_norm,

    norm_text(desa_raw)
      AS desa_norm,

    clean_phone(no_hp_raw)
      AS no_hp_clean,

    parse_date_any(file_date_raw)
      AS file_date,

    parse_timestamp_any(
      ingestion_timestamp_raw
    ) AS ingestion_timestamp

  FROM extracted

),



-- ============================================================================
-- 8. DATE VALIDATION
-- ============================================================================

validated AS (

  SELECT

    *,

    CASE
      WHEN tanggal_lahir_parsed
        BETWEEN DATE '1940-01-01'
            AND analysis_date
      THEN tanggal_lahir_parsed
    END AS tanggal_lahir,


    CASE
      WHEN hpht_date_parsed
        BETWEEN minimum_valid_date
            AND analysis_date
      THEN hpht_date_parsed
    END AS hpht_date,


    CASE
      WHEN hpl_date_parsed
        BETWEEN minimum_valid_date
            AND maximum_hpl_date
      THEN hpl_date_parsed
    END AS hpl_date,


    CASE
      WHEN previous_delivery_date_parsed
        BETWEEN minimum_valid_date
            AND analysis_date
      THEN previous_delivery_date_parsed
    END AS previous_delivery_date,


    CASE
      WHEN anc_date_parsed
        BETWEEN minimum_valid_date
            AND analysis_date
      THEN anc_date_parsed
    END AS anc_date,


    CASE
      WHEN pnc_date_parsed
        BETWEEN minimum_valid_date
            AND analysis_date
      THEN pnc_date_parsed
    END AS pnc_date,


    CASE
      WHEN tanggal_persalinan_parsed
        BETWEEN minimum_valid_date
            AND analysis_date
      THEN tanggal_persalinan_parsed
    END AS tanggal_persalinan_date,


    CASE
      WHEN bayi_lahir_tanggal_parsed
        BETWEEN minimum_valid_date
            AND analysis_date
      THEN bayi_lahir_tanggal_parsed
    END AS bayi_lahir_tanggal_date,


    CASE
      WHEN usg_hpl_date_parsed
        BETWEEN minimum_valid_date
            AND maximum_hpl_date
      THEN usg_hpl_date_parsed
    END AS usg_hpl_date

  FROM parsed

),



-- ============================================================================
-- 9. DERIVED EVENT FIELDS
-- ============================================================================

derived AS (

  SELECT
    *,

    -- ------------------------------------------------------------------------
    -- EPUS INC CANONICAL DELIVERY DATE
    --
    -- Keep the production-style priority:
    --
    --   tanggal_persalinan
    --   then bayi_lahir_tanggal
    --
    -- The disagreement is separately flagged.
    -- ------------------------------------------------------------------------

    CASE

      WHEN source_table = 'EPUS_INC'

      THEN COALESCE(
        tanggal_persalinan_date,
        bayi_lahir_tanggal_date
      )

    END AS delivery_date,


    CASE

      WHEN source_table = 'EPUS_INC'
       AND tanggal_persalinan_date IS NOT NULL

        THEN 'TANGGAL_PERSALINAN'

      WHEN source_table = 'EPUS_INC'
       AND bayi_lahir_tanggal_date IS NOT NULL

        THEN 'BAYI_LAHIR_TANGGAL'

    END AS delivery_date_source,


    CASE

      WHEN source_table = 'EPUS_ANC'
        THEN anc_date

      WHEN source_table = 'EPUS_KUNJUNGAN_IBU_HAMIL'
        THEN anc_date

      WHEN source_table = 'EPUS_INC'
        THEN COALESCE(
          tanggal_persalinan_date,
          bayi_lahir_tanggal_date
        )

      WHEN source_table = 'EPUS_PNC'
        THEN pnc_date

    END AS event_date,


    CASE

      WHEN source_table = 'EPUS_ANC'
        THEN 'TANGGAL_ANTENATAL'

      WHEN source_table = 'EPUS_KUNJUNGAN_IBU_HAMIL'
        THEN 'REGISTER_TANGGAL'

      WHEN source_table = 'EPUS_INC'
       AND tanggal_persalinan_date IS NOT NULL
        THEN 'TANGGAL_PERSALINAN'

      WHEN source_table = 'EPUS_INC'
       AND bayi_lahir_tanggal_date IS NOT NULL
        THEN 'BAYI_LAHIR_TANGGAL'

      WHEN source_table = 'EPUS_PNC'
        THEN 'TANGGAL_PNC'

    END AS event_date_source,


    -- ------------------------------------------------------------------------
    -- PREGNANCY ANCHOR
    -- ------------------------------------------------------------------------

    CASE

      WHEN pregnancy_episode_creator_flag

      THEN COALESCE(
        hpht_date,

        CASE
          WHEN hpl_date IS NOT NULL
          THEN DATE_SUB(
            hpl_date,
            INTERVAL 280 DAY
          )
        END
      )

    END AS pregnancy_anchor_date,


    -- ------------------------------------------------------------------------
    -- SOURCE HPL HELPER
    -- ------------------------------------------------------------------------

    COALESCE(
      hpl_date,

      CASE
        WHEN hpht_date IS NOT NULL
        THEN DATE_ADD(
          hpht_date,
          INTERVAL 280 DAY
        )
      END

    ) AS source_expected_delivery_date,


    CASE

      WHEN hpl_date IS NOT NULL
        THEN 'RECORDED_HPL_EPUS'

      WHEN hpht_date IS NOT NULL
        THEN 'HPHT_PLUS_280_EPUS'

    END AS source_expected_delivery_date_method,


    -- ------------------------------------------------------------------------
    -- DELIVERY-DATE AGREEMENT
    -- ------------------------------------------------------------------------

    CASE

      WHEN tanggal_persalinan_date IS NOT NULL
       AND bayi_lahir_tanggal_date IS NOT NULL

      THEN ABS(
        DATE_DIFF(
          tanggal_persalinan_date,
          bayi_lahir_tanggal_date,
          DAY
        )
      )

    END AS delivery_date_difference_days

  FROM validated

),



-- ============================================================================
-- 10. FINAL OUTPUT
-- ============================================================================

final AS (

  SELECT

    'EPUS'
      AS source_system,

    source_table,

    source_priority,

    source_role,

    event_type,

    record_grain,

    pregnancy_episode_creator_flag,

    source_record_id,


    CONCAT(
      'EPUS|',
      source_table,
      '|',
      source_record_id
    ) AS source_event_id,


    -- ------------------------------------------------------------------------
    -- IDENTITY
    -- ------------------------------------------------------------------------

    nik_raw,

    nik_clean,

    nik_clean IS NOT NULL
      AS flag_nik_valid,


    CASE

      WHEN nik_clean IS NULL
        THEN 'MISSING_OR_INVALID'

      WHEN RIGHT(nik_clean, 4) = '0000'
        THEN 'SUSPECT_ROUNDED'

      ELSE 'TRUSTED'

    END AS nik_reliability,


    nama_raw
      AS nama,

    nama_norm,

    tanggal_lahir,


    -- ------------------------------------------------------------------------
    -- PREGNANCY DATING
    -- ------------------------------------------------------------------------

    hpht_date,

    hpl_date,

    pregnancy_anchor_date,

    source_expected_delivery_date,

    source_expected_delivery_date_method,


    -- ------------------------------------------------------------------------
    -- EVENTS
    -- ------------------------------------------------------------------------

    event_date,

    event_date_source,

    anc_date,

    pnc_date,

    delivery_date,

    delivery_date_source,

    previous_delivery_date,


    -- ------------------------------------------------------------------------
    -- BOTH INC DELIVERY DATES
    -- ------------------------------------------------------------------------

    tanggal_persalinan_date,

    bayi_lahir_tanggal_date,

    bayi_lahir_jam_raw,

    delivery_date_difference_days,


    (
      delivery_date_difference_days > 1
    ) AS delivery_date_conflict_flag,


    -- ------------------------------------------------------------------------
    -- USG
    -- ------------------------------------------------------------------------

    usg_usia_kehamilan_raw,

    usg_ga_weeks,

    usg_perkiraan_lahir_raw,

    usg_hpl_date,


    (
      source_table = 'EPUS_ANC'
      AND usg_ga_weeks BETWEEN 1 AND 14
      AND usg_hpl_date IS NOT NULL
    ) AS early_usg_dating_flag,


    -- ------------------------------------------------------------------------
    -- OBSTETRIC HISTORY
    -- ------------------------------------------------------------------------

    abortus_history_raw,

    abortus_complication_raw,


    -- No current-pregnancy abortion date has been established
    -- from these four sources.
    CAST(NULL AS DATE)
      AS abortion_date,


    -- ------------------------------------------------------------------------
    -- DELIVERY CLINICAL DATA
    -- ------------------------------------------------------------------------

    delivery_ga_raw,

    delivery_ga_hpht_raw,

    birth_weight_raw,

    delivery_mode_raw,

    baby_outcome_raw,

    maternal_outcome_raw,

    delivery_complication_raw,


    -- ------------------------------------------------------------------------
    -- LOCATION
    -- ------------------------------------------------------------------------

    puskesmas_raw
      AS puskesmas,

    puskesmas_norm,

    puskesmas_id,

    desa_raw
      AS desa,

    desa_norm,

    alamat_raw
      AS alamat,


    -- ------------------------------------------------------------------------
    -- CONTACT
    -- ------------------------------------------------------------------------

    no_hp_raw
      AS no_hp,

    no_hp_clean,


    -- ------------------------------------------------------------------------
    -- PROVENANCE
    -- ------------------------------------------------------------------------

    file_name,

    file_date,

    ingestion_timestamp,

    ingestion_timestamp_raw,

    source_uuid,

    source_hash_code,


    -- ------------------------------------------------------------------------
    -- RAW DATES
    -- ------------------------------------------------------------------------

    dob_raw,

    hpht_raw,

    hpl_raw,

    anc_raw,

    pnc_raw,

    previous_delivery_raw,

    tanggal_persalinan_raw,

    bayi_lahir_tanggal_raw,


    -- ------------------------------------------------------------------------
    -- PARSED DATES BEFORE VALIDATION
    -- ------------------------------------------------------------------------

    tanggal_lahir_parsed,

    hpht_date_parsed,

    hpl_date_parsed,

    anc_date_parsed,

    pnc_date_parsed,

    previous_delivery_date_parsed,

    tanggal_persalinan_parsed,

    bayi_lahir_tanggal_parsed,

    usg_hpl_date_parsed,


    -- ------------------------------------------------------------------------
    -- DATE QA
    -- ------------------------------------------------------------------------

    (
      tanggal_lahir_parsed IS NOT NULL
      AND tanggal_lahir IS NULL
    ) AS dob_invalid_date_flag,


    (
      hpht_date_parsed IS NOT NULL
      AND hpht_date IS NULL
    ) AS hpht_invalid_date_flag,


    (
      hpl_date_parsed IS NOT NULL
      AND hpl_date IS NULL
    ) AS hpl_invalid_date_flag,


    (
      anc_date_parsed IS NOT NULL
      AND anc_date IS NULL
    ) AS anc_invalid_date_flag,


    (
      pnc_date_parsed IS NOT NULL
      AND pnc_date IS NULL
    ) AS pnc_invalid_date_flag,


    (
      tanggal_persalinan_parsed IS NOT NULL
      AND tanggal_persalinan_date IS NULL
    ) AS delivery_invalid_date_flag,


    (
      bayi_lahir_tanggal_parsed IS NOT NULL
      AND bayi_lahir_tanggal_date IS NULL
    ) AS baby_birth_invalid_date_flag,


    -- ------------------------------------------------------------------------
    -- PREGNANCY SPINE ELIGIBILITY
    -- ------------------------------------------------------------------------

    (
      pregnancy_episode_creator_flag
      AND pregnancy_anchor_date IS NOT NULL
    ) AS is_pregnancy_spine_record,


    source_json

  FROM derived

)


SELECT *
FROM final

WHERE

     nik_clean IS NOT NULL

  OR nama_norm IS NOT NULL

  OR hpht_date IS NOT NULL

  OR hpl_date IS NOT NULL

  OR anc_date IS NOT NULL

  OR pnc_date IS NOT NULL

  OR delivery_date IS NOT NULL;
