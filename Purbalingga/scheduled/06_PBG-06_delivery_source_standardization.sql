-- ============================================================================
-- PURBALINGGA
-- 04_BUILD_DELIVERY_SOURCE_RECORDS_V3_3_1
--
-- OUTPUT:
--   stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_source_records_v3_3
--
-- IMPORTANT CHANGES FROM v3.3
--
-- 1. event_date = clinical event only:
--      delivery_date / abortion_date
--    report_date is NEVER used as a clinical event date.
--
-- 2. eKohort:
--      canonical delivery date = tgl_persalinan
--      by_lahir_tgl = secondary baby-date evidence only
--
-- 3. Outcome mapping:
--      eKohort H   -> LIVE_BIRTH
--      eKohort M   -> STILLBIRTH
--      SIMRS BLH   -> LIVE_BIRTH
--      SIMRS BLM   -> STILLBIRTH
--
-- 4. Exact duplicate physical rows are removed ONLY by source_row_fingerprint.
--
-- 5. Reused source_record_key with different row content is preserved.
--
-- 6. Delivery/abortion conflicts remain explicitly visible.
-- ============================================================================


-- ============================================================================
-- PARAMETERS
-- ============================================================================

DECLARE analysis_date DATE
  DEFAULT CURRENT_DATE('Asia/Jakarta');

DECLARE minimum_valid_event_date DATE
  DEFAULT DATE '2010-01-01';

DECLARE minimum_valid_dob DATE
  DEFAULT DATE '1940-01-01';

DECLARE maximum_valid_hpl DATE
  DEFAULT DATE_ADD(
    analysis_date,
    INTERVAL 300 DAY
  );


-- ============================================================================
-- DROP TARGET
-- ============================================================================

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_source_records_v3_3`;


-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

CREATE TEMP FUNCTION clean_raw(s STRING)
RETURNS STRING
AS (
  CASE
    WHEN s IS NULL THEN NULL

    WHEN LOWER(TRIM(s)) IN (
      '',
      '-',
      '--',
      'nan',
      'null',
      'none',
      'n/a',
      'na'
    ) THEN NULL

    ELSE TRIM(s)
  END
);


CREATE TEMP FUNCTION norm_text(s STRING)
RETURNS STRING
AS (
  NULLIF(
    REGEXP_REPLACE(
      REGEXP_REPLACE(
        UPPER(
          TRIM(
            COALESCE(
              clean_raw(s),
              ''
            )
          )
        ),
        r'[^A-Z0-9 ]',
        ' '
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
  NULLIF(
    TRIM(
      REGEXP_REPLACE(
        norm_text(s),
        r'^PUSKESMAS\s+',
        ''
      )
    ),
    ''
  )
);


CREATE TEMP FUNCTION clean_nik(s STRING)
RETURNS STRING
AS (
  CASE
    WHEN LENGTH(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          TRIM(
            COALESCE(
              clean_raw(s),
              ''
            )
          ),
          r'\.0+$',
          ''
        ),
        r'[^0-9]',
        ''
      )
    ) = 16

    AND REGEXP_REPLACE(
      REGEXP_REPLACE(
        TRIM(
          COALESCE(
            clean_raw(s),
            ''
          )
        ),
        r'\.0+$',
        ''
      ),
      r'[^0-9]',
      ''
    ) NOT IN (
      '0000000000000000',
      '9999999999999999'
    )

    THEN REGEXP_REPLACE(
      REGEXP_REPLACE(
        TRIM(
          COALESCE(
            clean_raw(s),
            ''
          )
        ),
        r'\.0+$',
        ''
      ),
      r'[^0-9]',
      ''
    )
  END
);


CREATE TEMP FUNCTION nik_is_trusted(s STRING)
RETURNS BOOL
AS (
  s IS NOT NULL
  AND REGEXP_CONTAINS(s, r'^\d{16}$')
  AND s NOT IN (
    '0000000000000000',
    '9999999999999999'
  )
  AND RIGHT(s, 4) != '0000'
);


CREATE TEMP FUNCTION clean_phone(s STRING)
RETURNS STRING
AS (
  CASE
    WHEN NULLIF(
      REGEXP_REPLACE(
        COALESCE(
          clean_raw(s),
          ''
        ),
        r'[^0-9]',
        ''
      ),
      ''
    ) IS NULL
      THEN NULL

    WHEN STARTS_WITH(
      REGEXP_REPLACE(
        clean_raw(s),
        r'[^0-9]',
        ''
      ),
      '62'
    )
      THEN CONCAT(
        '0',
        SUBSTR(
          REGEXP_REPLACE(
            clean_raw(s),
            r'[^0-9]',
            ''
          ),
          3
        )
      )

    WHEN STARTS_WITH(
      REGEXP_REPLACE(
        clean_raw(s),
        r'[^0-9]',
        ''
      ),
      '8'
    )
      THEN CONCAT(
        '0',
        REGEXP_REPLACE(
          clean_raw(s),
          r'[^0-9]',
          ''
        )
      )

    ELSE REGEXP_REPLACE(
      clean_raw(s),
      r'[^0-9]',
      ''
    )
  END
);


CREATE TEMP FUNCTION parse_date_any(s STRING)
RETURNS DATE
AS (
  CASE
    WHEN clean_raw(s) IS NULL
      THEN NULL

    ELSE COALESCE(

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        SUBSTR(
          clean_raw(s),
          1,
          10
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        SUBSTR(
          clean_raw(s),
          1,
          10
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        clean_raw(s)
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        clean_raw(s)
      ),

      SAFE.PARSE_DATE(
        '%e/%m/%Y',
        clean_raw(s)
      ),

      SAFE.PARSE_DATE(
        '%e-%m-%Y',
        clean_raw(s)
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        clean_raw(s)
      ),

      SAFE.PARSE_DATE(
        '%b %e, %Y',
        clean_raw(s)
      ),

      SAFE.PARSE_DATE(
        '%B %e, %Y',
        clean_raw(s)
      ),

      SAFE_CAST(
        clean_raw(s)
        AS DATE
      ),

      CASE
        WHEN SAFE_CAST(
          clean_raw(s)
          AS INT64
        ) BETWEEN 20000 AND 70000

        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            clean_raw(s)
            AS INT64
          ) DAY
        )
      END
    )
  END
);


CREATE TEMP FUNCTION parse_timestamp_any(s STRING)
RETURNS TIMESTAMP
AS (
  COALESCE(
    SAFE_CAST(
      clean_raw(s)
      AS TIMESTAMP
    ),

    CASE
      WHEN parse_date_any(s) IS NOT NULL

      THEN TIMESTAMP(
        parse_date_any(s),
        'Asia/Jakarta'
      )
    END
  )
);


CREATE TEMP FUNCTION parse_number(s STRING)
RETURNS FLOAT64
AS (
  SAFE_CAST(
    REGEXP_EXTRACT(
      REPLACE(
        COALESCE(
          clean_raw(s),
          ''
        ),
        ',',
        '.'
      ),
      r'-?[0-9]+(?:\.[0-9]+)?'
    )
    AS FLOAT64
  )
);


CREATE TEMP FUNCTION parse_birth_weight_grams(s STRING)
RETURNS INT64
AS (
  CASE
    WHEN parse_number(s)
      BETWEEN 0.3 AND 20

      THEN CAST(
        ROUND(
          parse_number(s) * 1000
        )
        AS INT64
      )

    WHEN parse_number(s)
      BETWEEN 300 AND 6500

      THEN CAST(
        ROUND(
          parse_number(s)
        )
        AS INT64
      )
  END
);


CREATE TEMP FUNCTION parse_ga_weeks(s STRING)
RETURNS INT64
AS (
  CASE
    WHEN parse_number(s)
      BETWEEN 20 AND 45

    THEN CAST(
      FLOOR(
        parse_number(s)
      )
      AS INT64
    )
  END
);


CREATE TEMP FUNCTION generic_outcome(s STRING)
RETURNS STRING
AS (
  CASE
    WHEN norm_text(s) IS NULL
      THEN 'UNKNOWN'

    WHEN REGEXP_CONTAINS(
      norm_text(s),
      r'ABORT|KEGUGURAN|MISCARR'
    )
      THEN 'ABORTION'

    WHEN REGEXP_CONTAINS(
      norm_text(s),
      r'LAHIR MATI|STILLBIRTH|STILL BIRTH|IUFD|FETAL DEATH'
    )
      THEN 'STILLBIRTH'

    WHEN REGEXP_CONTAINS(
      norm_text(s),
      r'LAHIR HIDUP|LIVE BIRTH'
    )
      THEN 'LIVE_BIRTH'

    WHEN norm_text(s) IN (
      'HIDUP',
      'LIVE'
    )
      THEN 'LIVE_BIRTH'

    WHEN norm_text(s) IN (
      'MATI',
      'STILL'
    )
      THEN 'STILLBIRTH'

    ELSE 'UNKNOWN'
  END
);


CREATE TEMP FUNCTION has_abortion_signal(s STRING)
RETURNS BOOL
AS (
  REGEXP_CONTAINS(
    COALESCE(
      norm_text(s),
      ''
    ),
    r'ABORT|KEGUGURAN|MISCARR'
  )
);


CREATE TEMP FUNCTION has_delivery_signal(s STRING)
RETURNS BOOL
AS (
  CASE
    WHEN norm_text(s) IS NULL
      THEN FALSE

    WHEN REGEXP_CONTAINS(
      norm_text(s),
      r'BELUM.*MELAHIRKAN|BELUM.*BERSALIN|BELUM.*LAHIR'
    )
      THEN FALSE

    WHEN norm_text(s) IN (
      'SUDAH',
      'DELIVERED',
      'LAHIR'
    )
      THEN TRUE

    WHEN REGEXP_CONTAINS(
      norm_text(s),
      r'SUDAH.*MELAHIRKAN|TELAH.*MELAHIRKAN|MELAHIRKAN|BERSALIN'
    )
      THEN TRUE

    ELSE FALSE
  END
);


-- ############################################################################
-- SOURCE UNION
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_source_records_v3_3`

PARTITION BY event_date

CLUSTER BY
  source_system,
  source_table,
  nik_clean,
  nama_norm

AS

WITH source_union_raw AS (

  -- ==========================================================================
  -- SIGIZI — KOHORT_IBU + IBU_NIFAS
  -- ==========================================================================

  SELECT
    'SIGIZI'
      AS source_system,

    JSON_VALUE(
      source_json,
      '$.source_table'
    ) AS source_table,

    CASE
      WHEN JSON_VALUE(
        source_json,
        '$.source_table'
      ) = 'KOHORT_IBU'
        THEN 5

      WHEN JSON_VALUE(
        source_json,
        '$.source_table'
      ) = 'IBU_NIFAS'
        THEN 6

      ELSE 9
    END AS source_priority,

    source_json

  FROM (
    SELECT
      TO_JSON_STRING(t)
        AS source_json

    FROM
      `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_source_records` t
  )

  WHERE JSON_VALUE(
    source_json,
    '$.source_table'
  ) IN (
    'KOHORT_IBU',
    'IBU_NIFAS'
  )


  UNION ALL


  -- ==========================================================================
  -- EPUS INC
  -- ==========================================================================

  SELECT
    'EPUS',
    'EPUS_INC',
    2,
    source_json

  FROM (
    SELECT
      TO_JSON_STRING(t)
        AS source_json

    FROM
      `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_source_records` t
  )

  WHERE JSON_VALUE(
    source_json,
    '$.source_table'
  ) = 'EPUS_INC'


  UNION ALL


  -- ==========================================================================
  -- SIMRS INC
  -- ==========================================================================

  SELECT
    'SIMRS',
    'SIMRS_API_INC',
    1,
    TO_JSON_STRING(t)

  FROM
    `stellar-orb-451904-d9.raw_data.simrs_api_inc` t


  UNION ALL


  -- ==========================================================================
  -- EKOHORT PERSALINAN
  -- ==========================================================================

  SELECT
    'EKOHORT',
    'EKOHORT_PERSALINAN',
    3,
    TO_JSON_STRING(t)

  FROM
    `stellar-orb-451904-d9.raw_data.ekohort_persalinan` t


  UNION ALL


  -- ==========================================================================
  -- EKOHORT PELAYANAN BERSALIN FIXED
  -- ==========================================================================

  SELECT
    'EKOHORT',
    'EKOHORT_PELAYANAN_IBU_BERSALIN_FIXED',
    4,
    TO_JSON_STRING(t)

  FROM
    `stellar-orb-451904-d9.raw_data.ekohort_pelayanan_ibu_bersalin_fixed` t


  UNION ALL


  -- ==========================================================================
  -- BIRTH CONFIRMATION APP
  -- ==========================================================================

  SELECT
    'BIRTH_CONFIRMATION',
    'BIRTH_CONFIRMATION_APP',
    7,
    TO_JSON_STRING(t)

  FROM
    `stellar-orb-451904-d9.raw_data.birth_confirmation_app` t

  WHERE
    COALESCE(
      SAFE_CAST(
        JSON_VALUE(
          TO_JSON_STRING(t),
          '$.is_deleted'
        )
        AS BOOL
      ),
      FALSE
    ) = FALSE


  UNION ALL


  -- ==========================================================================
  -- BIRTH CONFIRMATION LEGACY
  -- ==========================================================================

  SELECT
    'BIRTH_CONFIRMATION',
    'BIRTH_CONFIRMATION_LEGACY',
    8,
    TO_JSON_STRING(t)

  FROM
    `stellar-orb-451904-d9.raw_data.birth_confirmation` t
),


-- ============================================================================
-- FINGERPRINT PHYSICAL ROWS
-- ============================================================================

fingerprinted AS (

  SELECT
    s.*,

    TO_HEX(
      SHA256(
        source_json
      )
    ) AS source_row_fingerprint

  FROM source_union_raw s
),


-- ============================================================================
-- REMOVE ONLY EXACT PHYSICAL DUPLICATES
--
-- Current QA:
--   EPUS_INC has 1 excess exact duplicate.
--   Repeated eKohort / legacy BC business IDs have different fingerprints
--   and therefore remain.
-- ============================================================================

source_union AS (

  SELECT
    * EXCEPT(exact_duplicate_rn)

  FROM (
    SELECT
      f.*,

      ROW_NUMBER() OVER (
        PARTITION BY
          source_system,
          source_table,
          source_row_fingerprint

        ORDER BY
          source_priority
      ) AS exact_duplicate_rn

    FROM fingerprinted f
  )

  WHERE exact_duplicate_rn = 1
),


-- ############################################################################
-- RAW FIELD EXTRACTION
-- ############################################################################

raw_extracted AS (

  SELECT

    source_system,
    source_table,
    source_priority,
    source_row_fingerprint,
    source_json,


    -- ------------------------------------------------------------------------
    -- BUSINESS / SOURCE RECORD ID
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.source_record_id'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.record_id'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.id_bersalinan'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.id'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.uuid'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.hash_code'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.case_id'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.identifier'
        )
      ),

      source_row_fingerprint
    ) AS source_record_id_raw,


    -- ------------------------------------------------------------------------
    -- MATERNAL NIK
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.nik_clean'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.nik_ibu'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.no_ktp'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.nik'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.no_ktp_ibu'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.identifier'
        )
      )
    ) AS nik_raw,


    -- ------------------------------------------------------------------------
    -- MATERNAL NAME
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.nama_ibu'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.nama_lengkap_ibu'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.nama_pasien'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$."Nama ibu"'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.nama'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$."Nama"'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.nama_ibu_1'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.nama_ibu1'
        )
      )
    ) AS nama_raw,


    -- ------------------------------------------------------------------------
    -- DOB
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.tanggal_lahir_ibu'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.tgl_lahir_ibu'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.tanggal_lahir'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.tgl_lahir'
        )
      )
    ) AS tanggal_lahir_raw,


    -- ------------------------------------------------------------------------
    -- PHONE
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.no_hp_clean'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.no_hp_ibu'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.nomor_hp_ibu'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.no_hp'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$."Phone Number Sasaran"'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$."Phone Number"'
        )
      )
    ) AS no_hp_raw,


    -- ------------------------------------------------------------------------
    -- HPHT
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.hpht_date'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.hpht_epus'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.hpht_sigizi'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.tanggal_hpht'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.tgl_hpht'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.hpht'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$."HPHT"'
        )
      )
    ) AS hpht_raw,


    -- ------------------------------------------------------------------------
    -- HPL
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.hpl_date'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.hpl_epus'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.hpl_sigizi'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.tanggal_taksiran_persalinan'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.hpl'
        )
      )
    ) AS hpl_raw,


    -- ========================================================================
    -- PRIMARY DELIVERY DATE
    -- ========================================================================

    CASE

      -- SIGIZI standardized source
      WHEN source_table IN (
        'KOHORT_IBU',
        'IBU_NIFAS'
      )
      THEN COALESCE(
        clean_raw(
          JSON_VALUE(
            source_json,
            '$.delivery_date'
          )
        ),

        clean_raw(
          JSON_VALUE(
            source_json,
            '$.tanggal_melahirkan'
          )
        ),

        clean_raw(
          JSON_VALUE(
            source_json,
            '$.tgl_melahirkan'
          )
        )
      )


      -- ePUS:
      -- maternal tanggal_persalinan is primary.
      WHEN source_table = 'EPUS_INC'
      THEN COALESCE(
        clean_raw(
          JSON_VALUE(
            source_json,
            '$.tanggal_persalinan_date'
          )
        ),

        clean_raw(
          JSON_VALUE(
            source_json,
            '$.tanggal_persalinan'
          )
        ),

        clean_raw(
          JSON_VALUE(
            source_json,
            '$.delivery_date'
          )
        )
      )


      -- SIMRS
      WHEN source_table = 'SIMRS_API_INC'
      THEN COALESCE(
        clean_raw(
          JSON_VALUE(
            source_json,
            '$.waktu_persalinan'
          )
        ),

        clean_raw(
          JSON_VALUE(
            source_json,
            '$.tanggal_persalinan'
          )
        ),

        clean_raw(
          JSON_VALUE(
            source_json,
            '$.tgl_inc_bayi'
          )
        )
      )


      -- eKohort:
      -- IMPORTANT: tgl_persalinan ONLY.
      WHEN source_table IN (
        'EKOHORT_PERSALINAN',
        'EKOHORT_PELAYANAN_IBU_BERSALIN_FIXED'
      )
      THEN clean_raw(
        JSON_VALUE(
          source_json,
          '$.tgl_persalinan'
        )
      )


      -- Birth Confirmation App
      WHEN source_table = 'BIRTH_CONFIRMATION_APP'
      THEN clean_raw(
        JSON_VALUE(
          source_json,
          '$.tanggal_melahirkan'
        )
      )


      -- Legacy Birth Confirmation
      WHEN source_table = 'BIRTH_CONFIRMATION_LEGACY'
      THEN clean_raw(
        JSON_VALUE(
          source_json,
          '$."tanggal persalinan"'
        )
      )

    END AS delivery_date_primary_raw,


    -- ========================================================================
    -- SECONDARY BABY DATE
    --
    -- NEVER automatically replaces eKohort tgl_persalinan.
    -- ========================================================================

    CASE

      WHEN source_table = 'EPUS_INC'
      THEN COALESCE(
        clean_raw(
          JSON_VALUE(
            source_json,
            '$.bayi_lahir_tanggal_date'
          )
        ),

        clean_raw(
          JSON_VALUE(
            source_json,
            '$.bayi_lahir_tanggal'
          )
        )
      )

      WHEN source_table IN (
        'EKOHORT_PERSALINAN',
        'EKOHORT_PELAYANAN_IBU_BERSALIN_FIXED'
      )
      THEN clean_raw(
        JSON_VALUE(
          source_json,
          '$.by_lahir_tgl'
        )
      )

      ELSE NULL

    END AS secondary_baby_date_raw,


    -- ------------------------------------------------------------------------
    -- PLACENTA DATE — QA ONLY
    -- ------------------------------------------------------------------------

    CASE
      WHEN source_table IN (
        'EKOHORT_PERSALINAN',
        'EKOHORT_PELAYANAN_IBU_BERSALIN_FIXED'
      )

      THEN clean_raw(
        JSON_VALUE(
          source_json,
          '$.plasenta_lahir_tgl'
        )
      )
    END AS secondary_placenta_date_raw,


    -- ------------------------------------------------------------------------
    -- ABORTION DATE
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.abortion_date'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.tanggal_abortus'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.tgl_abortus'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.tanggal_keguguran'
        )
      )
    ) AS abortion_date_raw,


    -- ========================================================================
    -- OUTCOME RAW
    -- ========================================================================

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.pregnancy_outcome_raw'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.outcome_raw'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.luaran_kehamilan'
        )
      ),

      -- eKohort
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.keadaan'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.status_persalinan_lahir_hidup_lahir_mati'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.status_kelahiran'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$."Status kelahiran"'
        )
      )
    ) AS outcome_raw,


    -- ------------------------------------------------------------------------
    -- DELIVERY STATUS
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.status_kelahiran'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.status_ceklist'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.status_persalinan'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$."Status kelahiran"'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$."Status"'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.luaran_kehamilan'
        )
      )
    ) AS delivery_status_raw,


    -- ------------------------------------------------------------------------
    -- BABY CONDITION
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.baby_outcome_raw'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.keadaan_bayi'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.kondisi_bayi_saat_lahir'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.keterangan_kondisi_lahir'
        )
      )
    ) AS baby_condition_raw,


    -- ------------------------------------------------------------------------
    -- MATERNAL CONDITION
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.maternal_outcome_raw'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.keadaan_ibu'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.keadaan_ibu_saat_ini'
        )
      )
    ) AS maternal_outcome_raw,


    -- ------------------------------------------------------------------------
    -- GA
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.delivery_ga_raw'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.gestasi_ketika_persalinan'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.usia_kehamilan'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.usia_hpht'
        )
      )
    ) AS gestational_age_raw,


    -- ------------------------------------------------------------------------
    -- BIRTH WEIGHT
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.birth_weight_raw'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.bb_bayi'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.berat_bayi_lahir'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.berat_badan_bayi'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.birth_weight'
        )
      )
    ) AS birth_weight_raw,


    -- ------------------------------------------------------------------------
    -- BABY SEX
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.jenis_kelamin_bayi'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.jenis_kelamin'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.sex'
        )
      )
    ) AS baby_sex_raw,


    -- ------------------------------------------------------------------------
    -- MODE
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.delivery_mode_raw'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.cara_persalinan'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.proses_persalinan'
        )
      )
    ) AS delivery_mode_raw,


    -- ------------------------------------------------------------------------
    -- PLACE
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.tempat_melahirkan'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.tempat_persalinan'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.tempat_pelayanan_inc'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.delivery_facility_raw'
        )
      )
    ) AS delivery_place_raw,


    -- ------------------------------------------------------------------------
    -- ATTENDANT
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.penolong_persalinan'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.nama_penolong'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.nama_penolong_persalinan'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.nama_nakes'
        )
      )
    ) AS birth_attendant_raw,


    -- ------------------------------------------------------------------------
    -- COMPLICATION
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.delivery_complication_raw'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.komplikasi_persalinan'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.komplikasi'
        )
      )
    ) AS delivery_complication_raw,


    -- ------------------------------------------------------------------------
    -- REFERRAL
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.rujuk'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.dirujuk_ya_tidak'
        )
      )
    ) AS referral_raw,


    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.nama_faskes_rujuk'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.faskes_rujukan'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.tujuan_rujukan'
        )
      )
    ) AS referral_destination_raw,


    -- ------------------------------------------------------------------------
    -- FACILITY
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.puskesmas'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.puskesmas_name'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.nama_lembaga_kesehatan'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.hospital_name'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.faskes'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$."Faskes"'
        )
      )
    ) AS puskesmas_raw,


    -- ------------------------------------------------------------------------
    -- DESA
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.desa'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.nama_desa'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.desakel'
        )
      )
    ) AS desa_raw,


    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.posyandu'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.nama_posyandu'
        )
      )
    ) AS posyandu_raw,


    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.alamat'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.alamat_ibu'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.alamat_persalinan'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.alamat_bersalin'
        )
      )
    ) AS alamat_raw,


    -- ------------------------------------------------------------------------
    -- REPORT TIMESTAMP
    -- ------------------------------------------------------------------------

    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.ingestion_timestamp'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.created_at'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.updated_at'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.file_date'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$."Tanggal Update BQ"'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$."Tanggal Input data"'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.tgl_input_ceklist'
        )
      )
    ) AS report_timestamp_raw,


    COALESCE(
      clean_raw(
        JSON_VALUE(
          source_json,
          '$.file_name'
        )
      ),

      clean_raw(
        JSON_VALUE(
          source_json,
          '$.source_file'
        )
      )
    ) AS source_file_name

  FROM source_union
),


-- ============================================================================
-- RECORD KEYS
-- ============================================================================

with_keys AS (

  SELECT
    r.*,

    clean_raw(
      source_record_id_raw
    ) AS source_record_id,


    CONCAT(
      source_table,
      '|',
      COALESCE(
        clean_raw(
          source_record_id_raw
        ),
        source_row_fingerprint
      )
    ) AS source_record_key,


    CONCAT(
      source_table,
      '|ROW|',
      source_row_fingerprint
    ) AS source_record_instance_key

  FROM raw_extracted r
),


-- ============================================================================
-- BUSINESS KEY REUSE QA
-- ============================================================================

with_key_stats AS (

  SELECT
    k.*,

    COUNT(*) OVER (
      PARTITION BY
        source_system,
        source_table,
        source_record_key
    ) AS source_record_key_row_count

  FROM with_keys k
),


-- ============================================================================
-- PARSE
-- ============================================================================

parsed AS (

  SELECT
    k.*,

    clean_nik(
      nik_raw
    ) AS nik_clean,

    norm_text(
      nama_raw
    ) AS nama_norm,

    norm_text(
      nama_raw
    ) AS nama_core_norm,

    clean_phone(
      no_hp_raw
    ) AS no_hp_clean,

    parse_date_any(
      tanggal_lahir_raw
    ) AS tanggal_lahir_parsed,

    parse_date_any(
      hpht_raw
    ) AS hpht_parsed,

    parse_date_any(
      hpl_raw
    ) AS hpl_parsed,

    parse_date_any(
      delivery_date_primary_raw
    ) AS delivery_date_primary_parsed,

    parse_date_any(
      secondary_baby_date_raw
    ) AS secondary_baby_date_parsed,

    parse_date_any(
      secondary_placenta_date_raw
    ) AS secondary_placenta_date_parsed,

    parse_date_any(
      abortion_date_raw
    ) AS abortion_date_parsed,

    parse_timestamp_any(
      report_timestamp_raw
    ) AS report_timestamp_parsed,

    parse_ga_weeks(
      gestational_age_raw
    ) AS gestational_age_weeks,

    parse_birth_weight_grams(
      birth_weight_raw
    ) AS birth_weight_grams,

    norm_puskesmas(
      puskesmas_raw
    ) AS puskesmas_norm,

    norm_text(
      desa_raw
    ) AS desa_norm,

    norm_text(
      posyandu_raw
    ) AS posyandu_norm

  FROM with_key_stats k
),


-- ============================================================================
-- DATE VALIDATION
-- ============================================================================

validated AS (

  SELECT
    p.*,

    CASE
      WHEN tanggal_lahir_parsed
        BETWEEN minimum_valid_dob
            AND analysis_date

      THEN tanggal_lahir_parsed
    END AS tanggal_lahir_ibu,


    CASE
      WHEN hpht_parsed
        BETWEEN minimum_valid_event_date
            AND analysis_date

      THEN hpht_parsed
    END AS hpht_date,


    CASE
      WHEN hpl_parsed
        BETWEEN minimum_valid_event_date
            AND maximum_valid_hpl

      THEN hpl_parsed
    END AS hpl_date,


    CASE
      WHEN delivery_date_primary_parsed
        BETWEEN minimum_valid_event_date
            AND analysis_date

      THEN delivery_date_primary_parsed
    END AS delivery_date,


    CASE
      WHEN secondary_baby_date_parsed
        BETWEEN minimum_valid_event_date
            AND analysis_date

      THEN secondary_baby_date_parsed
    END AS secondary_baby_date,


    CASE
      WHEN secondary_placenta_date_parsed
        BETWEEN minimum_valid_event_date
            AND analysis_date

      THEN secondary_placenta_date_parsed
    END AS secondary_placenta_date,


    CASE
      WHEN abortion_date_parsed
        BETWEEN minimum_valid_event_date
            AND analysis_date

      THEN abortion_date_parsed
    END AS abortion_date,


    CASE
      WHEN DATE(
        report_timestamp_parsed,
        'Asia/Jakarta'
      ) BETWEEN minimum_valid_event_date
          AND DATE_ADD(
            analysis_date,
            INTERVAL 1 DAY
          )

      THEN report_timestamp_parsed
    END AS report_timestamp,


    (
      delivery_date_primary_raw IS NOT NULL
      AND (
           delivery_date_primary_parsed IS NULL

        OR NOT (
          delivery_date_primary_parsed
            BETWEEN minimum_valid_event_date
                AND analysis_date
        )
      )
    ) AS delivery_invalid_date_flag,


    (
      abortion_date_raw IS NOT NULL
      AND (
           abortion_date_parsed IS NULL

        OR NOT (
          abortion_date_parsed
            BETWEEN minimum_valid_event_date
                AND analysis_date
        )
      )
    ) AS abortion_invalid_date_flag,


    (
      report_timestamp_raw IS NOT NULL
      AND (
           report_timestamp_parsed IS NULL

        OR NOT (
          DATE(
            report_timestamp_parsed,
            'Asia/Jakarta'
          )
          BETWEEN minimum_valid_event_date
              AND DATE_ADD(
                analysis_date,
                INTERVAL 1 DAY
              )
        )
      )
    ) AS report_timestamp_invalid_flag

  FROM parsed p
),


-- ============================================================================
-- SOURCE-SPECIFIC OUTCOME
-- ============================================================================

outcome_features AS (

  SELECT
    v.*,

    CASE

      -- ----------------------------------------------------------------------
      -- EKOHORT:
      -- observed vocabulary H/M
      -- ----------------------------------------------------------------------

      WHEN source_system = 'EKOHORT'
       AND norm_text(outcome_raw) = 'H'
        THEN 'LIVE_BIRTH'

      WHEN source_system = 'EKOHORT'
       AND norm_text(outcome_raw) = 'M'
        THEN 'STILLBIRTH'


      -- ----------------------------------------------------------------------
      -- SIMRS:
      -- observed vocabulary BLH / BLM
      -- ----------------------------------------------------------------------

      WHEN source_table = 'SIMRS_API_INC'
       AND norm_text(outcome_raw) = 'BLH'
        THEN 'LIVE_BIRTH'

      WHEN source_table = 'SIMRS_API_INC'
       AND norm_text(outcome_raw) = 'BLM'
        THEN 'STILLBIRTH'


      -- ----------------------------------------------------------------------
      -- Explicit abortion
      -- ----------------------------------------------------------------------

      WHEN has_abortion_signal(
        outcome_raw
      )
        THEN 'ABORTION'

      WHEN has_abortion_signal(
        delivery_status_raw
      )
        THEN 'ABORTION'


      -- ----------------------------------------------------------------------
      -- Generic explicit birth outcome
      -- ----------------------------------------------------------------------

      WHEN generic_outcome(
        outcome_raw
      ) != 'UNKNOWN'

        THEN generic_outcome(
          outcome_raw
        )


      WHEN generic_outcome(
        baby_condition_raw
      ) IN (
        'LIVE_BIRTH',
        'STILLBIRTH'
      )

        THEN generic_outcome(
          baby_condition_raw
        )


      ELSE 'UNKNOWN'

    END AS pregnancy_outcome_from_source,


    has_delivery_signal(
      delivery_status_raw
    ) AS delivery_status_signal_flag,


    (
      has_abortion_signal(
        delivery_status_raw
      )
      OR
      has_abortion_signal(
        outcome_raw
      )
    ) AS abortion_status_signal_flag,


    source_table IN (
      'EPUS_INC',
      'SIMRS_API_INC',
      'EKOHORT_PERSALINAN',
      'EKOHORT_PELAYANAN_IBU_BERSALIN_FIXED'
    ) AS inherent_delivery_source_flag

  FROM validated v
),


-- ============================================================================
-- SECONDARY DATE QA
-- ============================================================================

date_features AS (

  SELECT
    o.*,

    CASE
      WHEN delivery_date IS NOT NULL
       AND secondary_baby_date IS NOT NULL

      THEN ABS(
        DATE_DIFF(
          delivery_date,
          secondary_baby_date,
          DAY
        )
      )
    END AS secondary_baby_date_difference_days,


    CASE
      WHEN delivery_date IS NOT NULL
       AND secondary_placenta_date IS NOT NULL

      THEN ABS(
        DATE_DIFF(
          delivery_date,
          secondary_placenta_date,
          DAY
        )
      )
    END AS secondary_placenta_date_difference_days,


    (
      delivery_date IS NOT NULL
      AND secondary_baby_date IS NOT NULL
      AND ABS(
        DATE_DIFF(
          delivery_date,
          secondary_baby_date,
          DAY
        )
      ) > 1
    ) AS secondary_baby_date_conflict_flag,


    (
      delivery_date IS NOT NULL
      AND secondary_baby_date IS NOT NULL
      AND ABS(
        DATE_DIFF(
          delivery_date,
          secondary_baby_date,
          DAY
        )
      ) > 42
    ) AS secondary_baby_date_severe_conflict_flag

  FROM outcome_features o
),


-- ============================================================================
-- EVENT CLASSIFICATION
-- ============================================================================

classified AS (

  SELECT
    d.*,

    CASE

      -- delivery and abortion both explicitly dated
      WHEN delivery_date IS NOT NULL
       AND abortion_date IS NOT NULL

        THEN 'CONFLICT_DELIVERY_ABORTION'


      -- abortion
      WHEN abortion_date IS NOT NULL
        OR abortion_status_signal_flag

        THEN 'ABORTION'


      -- dated delivery
      WHEN delivery_date IS NOT NULL

        THEN 'DELIVERY'


      -- delivery known, date unavailable
      WHEN inherent_delivery_source_flag
        OR delivery_status_signal_flag
        OR pregnancy_outcome_from_source IN (
          'LIVE_BIRTH',
          'STILLBIRTH'
        )

        THEN 'DELIVERY_DATE_UNKNOWN'


      ELSE NULL

    END AS event_type,


    CASE

      WHEN delivery_date IS NOT NULL
       AND abortion_date IS NOT NULL
        THEN 'ABORTION'

      WHEN abortion_date IS NOT NULL
        OR abortion_status_signal_flag
        THEN 'ABORTION'

      ELSE pregnancy_outcome_from_source

    END AS pregnancy_outcome_norm

  FROM date_features d
),


-- ============================================================================
-- FINAL
-- ============================================================================

final AS (

  SELECT

    -- ------------------------------------------------------------------------
    -- PROVENANCE
    -- ------------------------------------------------------------------------

    source_system,
    source_table,
    source_priority,

    source_record_id,

    source_record_key,

    source_record_instance_key,

    source_record_key_row_count,

    source_record_key_row_count > 1
      AS source_record_key_reused_flag,

    source_row_fingerprint,

    source_file_name,


    -- ------------------------------------------------------------------------
    -- REPORT / INGESTION DATE
    -- ------------------------------------------------------------------------

    report_timestamp,

    CASE
      WHEN report_timestamp IS NOT NULL

      THEN DATE(
        report_timestamp,
        'Asia/Jakarta'
      )
    END AS report_date,

    report_timestamp_invalid_flag,


    -- ------------------------------------------------------------------------
    -- EVENT
    -- ------------------------------------------------------------------------

    event_type,

    pregnancy_outcome_norm,


    -- IMPORTANT:
    -- report_date is deliberately NOT included here.
    COALESCE(
      delivery_date,
      abortion_date
    ) AS event_date,


    delivery_date,

    abortion_date,


    -- ------------------------------------------------------------------------
    -- SECONDARY DELIVERY/BABY DATE
    -- ------------------------------------------------------------------------

    secondary_baby_date,

    secondary_placenta_date,

    secondary_baby_date_difference_days,

    secondary_placenta_date_difference_days,

    secondary_baby_date_conflict_flag,

    secondary_baby_date_severe_conflict_flag,


    -- ------------------------------------------------------------------------
    -- MATERNAL IDENTITY
    -- ------------------------------------------------------------------------

    nik_raw,

    clean_nik(
      nik_raw
    ) AS nik_clean,

    CASE
      WHEN clean_nik(
        nik_raw
      ) IS NULL
        THEN 'MISSING_OR_INVALID'

      WHEN RIGHT(
        clean_nik(
          nik_raw
        ),
        4
      ) = '0000'
        THEN 'SUSPECT_ROUNDED'

      ELSE 'TRUSTED'
    END AS nik_reliability,

    nik_is_trusted(
      clean_nik(
        nik_raw
      )
    ) AS trusted_nik_flag,


    nama_raw
      AS nama_ibu,

    nama_norm,

    nama_core_norm,


    tanggal_lahir_raw,

    tanggal_lahir_ibu,


    no_hp_raw,

    no_hp_clean,


    -- ------------------------------------------------------------------------
    -- PREGNANCY DATING
    -- ------------------------------------------------------------------------

    hpht_raw,

    hpht_date,

    hpl_raw,

    hpl_date,


    -- ------------------------------------------------------------------------
    -- LOCATION
    -- ------------------------------------------------------------------------

    puskesmas_raw
      AS puskesmas,

    puskesmas_norm,

    desa_raw
      AS desa,

    desa_norm,

    posyandu_raw
      AS posyandu,

    posyandu_norm,

    alamat_raw
      AS alamat,


    -- ------------------------------------------------------------------------
    -- CLINICAL
    -- ------------------------------------------------------------------------

    outcome_raw,

    baby_condition_raw,

    maternal_outcome_raw,

    gestational_age_raw,

    gestational_age_weeks,

    birth_weight_raw,

    birth_weight_grams,

    baby_sex_raw,

    delivery_mode_raw,

    delivery_place_raw,

    birth_attendant_raw,

    delivery_complication_raw,

    referral_raw,

    referral_destination_raw,


    -- ------------------------------------------------------------------------
    -- COMPLETENESS
    -- ------------------------------------------------------------------------

    clean_nik(
      nik_raw
    ) IS NOT NULL
      AS has_valid_nik,

    nama_norm IS NOT NULL
      AS has_name,

    tanggal_lahir_ibu IS NOT NULL
      AS has_dob,

    hpht_date IS NOT NULL
      AS has_hpht,

    hpl_date IS NOT NULL
      AS has_hpl,

    delivery_date IS NOT NULL
      AS has_delivery_date,

    abortion_date IS NOT NULL
      AS has_abortion_date,

    pregnancy_outcome_norm
      != 'UNKNOWN'
      AS has_known_outcome,

    gestational_age_weeks IS NOT NULL
      AS has_gestational_age,

    birth_weight_grams IS NOT NULL
      AS has_birth_weight,


    -- ------------------------------------------------------------------------
    -- EVENT SIGNALS / QA
    -- ------------------------------------------------------------------------

    inherent_delivery_source_flag,

    delivery_status_signal_flag,

    abortion_status_signal_flag,

    delivery_status_raw,

    delivery_invalid_date_flag,

    abortion_invalid_date_flag,


    (
      delivery_date IS NOT NULL
      AND abortion_date IS NOT NULL
    ) AS delivery_abortion_conflict_flag,


    -- raw JSON retained for full traceability
    source_json

  FROM classified

  WHERE
    event_type IS NOT NULL
)


SELECT *
FROM final;


-- ############################################################################
-- QA 1 — SOURCE SUMMARY
-- ############################################################################

SELECT

  source_system,
  source_table,

  COUNT(*) AS record_count,

  COUNTIF(
    event_type = 'DELIVERY'
  ) AS delivery_records,

  COUNTIF(
    event_type = 'DELIVERY_DATE_UNKNOWN'
  ) AS delivery_date_unknown_records,

  COUNTIF(
    event_type = 'ABORTION'
  ) AS abortion_records,

  COUNTIF(
    event_type = 'CONFLICT_DELIVERY_ABORTION'
  ) AS delivery_abortion_conflicts,

  COUNTIF(
    has_valid_nik
  ) AS valid_nik,

  COUNTIF(
    trusted_nik_flag
  ) AS trusted_nik,

  COUNTIF(
    has_name
  ) AS has_name,

  COUNTIF(
    has_dob
  ) AS has_dob,

  COUNTIF(
    has_hpht
  ) AS has_hpht,

  COUNTIF(
    has_hpl
  ) AS has_hpl,

  COUNTIF(
    has_delivery_date
  ) AS has_delivery_date,

  COUNTIF(
    has_known_outcome
  ) AS has_known_outcome,

  COUNTIF(
    has_gestational_age
  ) AS has_ga,

  COUNTIF(
    has_birth_weight
  ) AS has_birth_weight,

  COUNTIF(
    secondary_baby_date_conflict_flag
  ) AS secondary_date_conflicts,

  COUNTIF(
    secondary_baby_date_severe_conflict_flag
  ) AS secondary_date_severe_conflicts,

  COUNTIF(
    source_record_key_reused_flag
  ) AS records_with_reused_source_key

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_source_records_v3_3`

GROUP BY
  source_system,
  source_table

ORDER BY
  MIN(source_priority);


-- ############################################################################
-- QA 2 — OUTCOME DISTRIBUTION
-- ############################################################################

SELECT

  source_system,
  source_table,
  event_type,
  pregnancy_outcome_norm,

  COUNT(*) AS record_count

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_source_records_v3_3`

GROUP BY
  source_system,
  source_table,
  event_type,
  pregnancy_outcome_norm

ORDER BY
  source_system,
  source_table,
  event_type,
  pregnancy_outcome_norm;


-- ############################################################################
-- QA 3 — DATE RANGE
--
-- DELIVERY_DATE_UNKNOWN is allowed to have NULL event_date.
-- ############################################################################

SELECT

  source_system,
  source_table,

  MIN(delivery_date)
    AS min_delivery_date,

  MAX(delivery_date)
    AS max_delivery_date,

  MIN(abortion_date)
    AS min_abortion_date,

  MAX(abortion_date)
    AS max_abortion_date,

  MIN(event_date)
    AS min_event_date,

  MAX(event_date)
    AS max_event_date,

  MIN(report_date)
    AS min_report_date,

  MAX(report_date)
    AS max_report_date

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_source_records_v3_3`

GROUP BY
  source_system,
  source_table

ORDER BY
  source_system,
  source_table;


-- ############################################################################
-- QA 4 — EXACT DUPLICATES AFTER REBUILD
--
-- EXPECTED:
-- exact_duplicate_excess_rows = 0 for every source.
-- ############################################################################

SELECT

  source_table,

  COUNT(*) AS record_count,

  COUNT(
    DISTINCT source_record_instance_key
  ) AS distinct_record_instances,

  COUNT(*)
    - COUNT(
        DISTINCT source_record_instance_key
      )
      AS exact_duplicate_excess_rows

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_source_records_v3_3`

GROUP BY
  source_table

ORDER BY
  record_count DESC;


-- ############################################################################
-- QA 5 — REUSED BUSINESS KEYS
--
-- These are preserved intentionally.
-- ############################################################################

SELECT

  source_table,

  COUNT(
    DISTINCT IF(
      source_record_key_reused_flag,
      source_record_key,
      NULL
    )
  ) AS reused_business_keys,

  COUNTIF(
    source_record_key_reused_flag
  ) AS rows_under_reused_keys

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_source_records_v3_3`

GROUP BY
  source_table

ORDER BY
  rows_under_reused_keys DESC;


-- ############################################################################
-- QA 6 — EKOHORT SECONDARY DATE CONFLICT
-- ############################################################################

SELECT

  source_table,

  COUNT(*) AS delivery_records,

  COUNTIF(
    secondary_baby_date IS NOT NULL
  ) AS with_secondary_baby_date,

  COUNTIF(
    secondary_baby_date_difference_days <= 1
  ) AS secondary_within_1d,

  COUNTIF(
    secondary_baby_date_difference_days > 1
  ) AS secondary_gt_1d,

  COUNTIF(
    secondary_baby_date_difference_days > 42
  ) AS secondary_gt_42d,

  MAX(
    secondary_baby_date_difference_days
  ) AS max_secondary_difference_days

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_source_records_v3_3`

WHERE source_system = 'EKOHORT'

GROUP BY
  source_table;


-- ############################################################################
-- QA 7 — FINAL TOTAL
-- ############################################################################

SELECT

  COUNT(*) AS source_records,

  COUNTIF(
    event_type = 'DELIVERY'
  ) AS dated_delivery_records,

  COUNTIF(
    event_type = 'DELIVERY_DATE_UNKNOWN'
  ) AS delivery_date_unknown_records,

  COUNTIF(
    event_type = 'ABORTION'
  ) AS abortion_records,

  COUNTIF(
    event_type = 'CONFLICT_DELIVERY_ABORTION'
  ) AS delivery_abortion_conflict_records,

  COUNTIF(
    has_valid_nik
  ) AS records_with_valid_nik,

  COUNTIF(
    has_delivery_date
  ) AS records_with_delivery_date,

  COUNTIF(
    has_known_outcome
  ) AS records_with_known_outcome

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_source_records_v3_3`;
