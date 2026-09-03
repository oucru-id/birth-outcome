-- 13 recovered adapter definitions redirected to v3.

CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.vs_epus_anc` AS
WITH
-- ============================================================
-- 1. RAW SOURCE
--
-- Keep all source fields except `no`.
--
-- Two hashes are created:
--
-- source_row_hash
--   = fingerprint of the complete raw row, including ingestion
--     metadata.
--
-- clinical_content_hash
--   = hash of clinical content excluding ingestion metadata.
--     This allows the same ANC record appearing in multiple
--     exports/files to be recognized as the same clinical row.
-- ============================================================
source AS (
  SELECT
    t.* EXCEPT (`no`),

    FARM_FINGERPRINT(
      TO_JSON_STRING(
        (
          SELECT AS STRUCT
            t.* EXCEPT (`no`)
        )
      )
    ) AS source_row_hash,

    TO_HEX(
      SHA256(
        TO_JSON_STRING(
          (
            SELECT AS STRUCT
              t.* EXCEPT (
                `no`,
                file_name,
                file_date,
                ingestion_timestamp,
                uuid,
                hash_code
              )
          )
        )
      )
    ) AS clinical_content_hash

  FROM
    `spheres-lombok-barat.raw_data.epus_anc` t
),


-- ============================================================
-- 2. BASIC CLEANING
-- ============================================================
cleaned AS (
  SELECT
    s.*,

    -- --------------------------------------------------------
    -- Source record identifier
    -- --------------------------------------------------------
    COALESCE(
      NULLIF(TRIM(uuid), ''),
      NULLIF(TRIM(hash_code), ''),
      CAST(source_row_hash AS STRING)
    ) AS source_record_id,


    -- --------------------------------------------------------
    -- NIK
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        COALESCE(TRIM(nik), ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS nik_clean,


    -- --------------------------------------------------------
    -- Patient name
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          UPPER(TRIM(COALESCE(nama_pasien, ''))),
          r'[^A-Z0-9 ]',
          ' '
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS nama_pasien_clean,


    -- --------------------------------------------------------
    -- Puskesmas
    --
    -- Basic normalization:
    --   PUSKESMAS LABUAPI
    --   PKM LABUAPI
    --   Labuapi
    --
    -- become:
    --   LABUAPI
    -- --------------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            UPPER(
              TRIM(
                COALESCE(
                  puskesmas_name,
                  ''
                )
              )
            ),
            r'\s+',
            ' '
          ),
          r'^(PUSKESMAS|PKM)\s+',
          ''
        )
      ),
      ''
    ) AS puskesmas_name_clean,


    NULLIF(
      TRIM(puskesmas_id),
      ''
    ) AS puskesmas_id_clean,


    -- --------------------------------------------------------
    -- Common categorical fields
    -- --------------------------------------------------------
    NULLIF(
      UPPER(
        TRIM(kunjungan_k)
      ),
      ''
    ) AS kunjungan_k_clean,

    NULLIF(
      UPPER(
        TRIM(trimester_ke)
      ),
      ''
    ) AS trimester_ke_clean,

    NULLIF(
      UPPER(
        TRIM(usg)
      ),
      ''
    ) AS usg_clean,

    NULLIF(
      UPPER(
        TRIM(status)
      ),
      ''
    ) AS status_clean,


    -- --------------------------------------------------------
    -- Raw date strings
    -- --------------------------------------------------------
    NULLIF(
      TRIM(tanggal_lahir),
      ''
    ) AS tanggal_lahir_raw_clean,

    NULLIF(
      TRIM(tanggal_hpht),
      ''
    ) AS tanggal_hpht_raw_clean,

    NULLIF(
      TRIM(tanggal_antenatal),
      ''
    ) AS tanggal_antenatal_raw_clean,

    NULLIF(
      TRIM(tanggal_taksiran_persalinan),
      ''
    ) AS tanggal_taksiran_persalinan_raw_clean,

    NULLIF(
      TRIM(tanggal_persalinan_sebelumnya),
      ''
    ) AS tanggal_persalinan_sebelumnya_raw_clean,

    NULLIF(
      TRIM(usg_perkiraan_lahir),
      ''
    ) AS usg_perkiraan_lahir_raw_clean,

    NULLIF(
      TRIM(file_date),
      ''
    ) AS file_date_raw_clean,

    NULLIF(
      TRIM(ingestion_timestamp),
      ''
    ) AS ingestion_timestamp_raw_clean

  FROM source s
),


-- ============================================================
-- 3. NIK VALIDATION
-- ============================================================
identity_cleaned AS (
  SELECT
    c.*,

    CASE
      WHEN REGEXP_CONTAINS(
        nik_clean,
        r'^\d{16}$'
      )
      AND nik_clean NOT IN (
        '0000000000000000',
        '9999999999999999'
      )
      THEN TRUE
      ELSE FALSE
    END AS flag_nik_valid_16_digit

  FROM cleaned c
),


-- ============================================================
-- 4. DATE PARSING
-- ============================================================
parsed_dates AS (
  SELECT
    i.*,

    -- --------------------------------------------------------
    -- Date of birth
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_lahir_raw_clean,
          r'^\d{5}$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            tanggal_lahir_raw_clean
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_lahir_date,


    -- --------------------------------------------------------
    -- HPHT
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_hpht_raw_clean,
          r'^\d{5}$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            tanggal_hpht_raw_clean
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_hpht_date,


    -- --------------------------------------------------------
    -- ANC date
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_antenatal_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_antenatal_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_antenatal_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_antenatal_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_antenatal_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_antenatal_raw_clean,
          r'^\d{5}$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            tanggal_antenatal_raw_clean
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_antenatal_date,


    -- --------------------------------------------------------
    -- Estimated delivery date
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_taksiran_persalinan_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_taksiran_persalinan_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_taksiran_persalinan_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_taksiran_persalinan_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_taksiran_persalinan_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_taksiran_persalinan_raw_clean,
          r'^\d{5}$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            tanggal_taksiran_persalinan_raw_clean
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_taksiran_persalinan_date,


    -- --------------------------------------------------------
    -- Previous delivery date
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_persalinan_sebelumnya_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_persalinan_sebelumnya_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_persalinan_sebelumnya_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_persalinan_sebelumnya_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_persalinan_sebelumnya_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_persalinan_sebelumnya_raw_clean,
          r'^\d{5}$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            tanggal_persalinan_sebelumnya_raw_clean
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_persalinan_sebelumnya_date,


    -- --------------------------------------------------------
    -- USG estimated delivery date
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          usg_perkiraan_lahir_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          usg_perkiraan_lahir_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          usg_perkiraan_lahir_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          usg_perkiraan_lahir_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          usg_perkiraan_lahir_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          usg_perkiraan_lahir_raw_clean,
          r'^\d{5}$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            usg_perkiraan_lahir_raw_clean
            AS INT64
          ) DAY
        )
      END
    ) AS usg_perkiraan_lahir_date,


    -- --------------------------------------------------------
    -- Source file date
    -- --------------------------------------------------------
    COALESCE(
      SAFE_CAST(
        file_date_raw_clean
        AS DATE
      ),

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          file_date_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          file_date_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          file_date_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          file_date_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      )
    ) AS file_date_parsed,


    -- --------------------------------------------------------
    -- Ingestion timestamp
    -- --------------------------------------------------------
    SAFE_CAST(
      ingestion_timestamp_raw_clean
      AS TIMESTAMP
    ) AS ingestion_timestamp_parsed

  FROM identity_cleaned i
),


-- ============================================================
-- 5. NUMERIC NORMALIZATION
--
-- Raw STRING fields remain untouched.
-- These typed fields are additional.
-- ============================================================
typed AS (
  SELECT
    p.*,

    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(gravida),
        r'-?\d+'
      )
      AS INT64
    ) AS gravida_numeric,

    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(partus),
        r'-?\d+'
      )
      AS INT64
    ) AS partus_numeric,

    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(abortus),
        r'-?\d+'
      )
      AS INT64
    ) AS abortus_numeric,

    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(jumlah_bayi_idup),
        r'-?\d+'
      )
      AS INT64
    ) AS jumlah_bayi_hidup_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(bb_sebelum_hamil),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS bb_sebelum_hamil_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(berat_badan_saat_ini),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS berat_badan_saat_ini_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(tinggi_badan_saat_hamil),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS tinggi_badan_saat_hamil_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(lila),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS lila_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(sistole),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS sistole_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(diastole),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS diastole_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(frekuensi_nadi),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS frekuensi_nadi_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(suhu),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS suhu_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(respiratory),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS respiratory_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(`map`),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS map_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(tinggi_fundus),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS tinggi_fundus_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(usg_gs),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS usg_gs_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(usg_crl),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS usg_crl_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(usg_djj),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS usg_djj_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(usg_bpd),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS usg_bpd_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(usg_hc),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS usg_hc_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(usg_ac),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS usg_ac_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(usg_fl),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS usg_fl_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(usg_sdp_ketuban),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS usg_sdp_ketuban_numeric,


    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(jumlah_janin),
        r'-?\d+'
      )
      AS INT64
    ) AS jumlah_janin_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(denyut_jantung_janin),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS denyut_jantung_janin_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(tbj),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS tbj_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(usg_usia_kehamilan),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS usg_usia_kehamilan_numeric

  FROM parsed_dates p
),


-- ============================================================
-- 6. RECORD COMPLETENESS + RECENCY
-- ============================================================
scored AS (
  SELECT
    t.*,

    (
      IF(flag_nik_valid_16_digit, 1, 0)
      + IF(nama_pasien_clean IS NOT NULL, 1, 0)
      + IF(tanggal_lahir_date IS NOT NULL, 1, 0)
      + IF(tanggal_hpht_date IS NOT NULL, 1, 0)
      + IF(tanggal_antenatal_date IS NOT NULL, 1, 0)
      + IF(
          tanggal_taksiran_persalinan_date IS NOT NULL,
          1,
          0
        )
      + IF(kunjungan_k_clean IS NOT NULL, 1, 0)
      + IF(
          NULLIF(
            TRIM(usia_kehamilan),
            ''
          ) IS NOT NULL,
          1,
          0
        )
      + IF(
          NULLIF(
            TRIM(diagnosis),
            ''
          ) IS NOT NULL,
          1,
          0
        )
      + IF(
          berat_badan_saat_ini_numeric IS NOT NULL,
          1,
          0
        )
      + IF(sistole_numeric IS NOT NULL, 1, 0)
      + IF(diastole_numeric IS NOT NULL, 1, 0)
      + IF(usg_clean IS NOT NULL, 1, 0)
      + IF(usg_gs_numeric IS NOT NULL, 1, 0)
      + IF(usg_crl_numeric IS NOT NULL, 1, 0)
      + IF(usg_bpd_numeric IS NOT NULL, 1, 0)
      + IF(usg_hc_numeric IS NOT NULL, 1, 0)
      + IF(usg_ac_numeric IS NOT NULL, 1, 0)
      + IF(usg_fl_numeric IS NOT NULL, 1, 0)
      + IF(tbj_numeric IS NOT NULL, 1, 0)
      + IF(puskesmas_name_clean IS NOT NULL, 1, 0)
    ) AS row_completeness_score,


    COALESCE(
      ingestion_timestamp_parsed,

      CASE
        WHEN file_date_parsed IS NOT NULL
        THEN TIMESTAMP(file_date_parsed)
      END,

      TIMESTAMP '1900-01-01 00:00:00+00'
    ) AS source_recency_timestamp

  FROM typed t
),


-- ============================================================
-- 7. EXACT CLINICAL DUPLICATE DETECTION
--
-- Same clinical_content_hash means the clinical row itself
-- is identical, even if it appeared in multiple uploaded files.
--
-- Keep the latest imported copy.
-- ============================================================
exact_ranked AS (
  SELECT
    s.*,

    COUNT(*) OVER (
      PARTITION BY clinical_content_hash
    ) AS exact_duplicate_count,

    ROW_NUMBER() OVER (
      PARTITION BY clinical_content_hash
      ORDER BY
        source_recency_timestamp DESC,
        source_row_hash DESC
    ) AS exact_dedup_rank

  FROM scored s
),


exact_deduplicated AS (
  SELECT
    *
  FROM exact_ranked
  WHERE exact_dedup_rank = 1
),


-- ============================================================
-- 8. ANC ENCOUNTER IDENTITY
--
-- IMPORTANT:
-- HPHT is NOT part of the primary ANC encounter key.
--
-- Hierarchy:
--
-- 1. Valid NIK + ANC date
-- 2. Name + DOB + Puskesmas + ANC date
-- 3. Name + HPHT + Puskesmas + ANC date
-- 4. Weak identifier → keep separately
--
-- Weak records may still have already undergone safe exact
-- clinical duplicate removal above.
-- ============================================================
encounter_keyed AS (
  SELECT
    e.*,

    CASE
      WHEN
        flag_nik_valid_16_digit = TRUE
        AND tanggal_antenatal_date IS NOT NULL
      THEN 'NIK+ANC_DATE'

      WHEN
        nama_pasien_clean IS NOT NULL
        AND tanggal_lahir_date IS NOT NULL
        AND puskesmas_name_clean IS NOT NULL
        AND tanggal_antenatal_date IS NOT NULL
      THEN 'NAME+DOB+PUSKESMAS+ANC_DATE'

      WHEN
        nama_pasien_clean IS NOT NULL
        AND tanggal_hpht_date IS NOT NULL
        AND puskesmas_name_clean IS NOT NULL
        AND tanggal_antenatal_date IS NOT NULL
      THEN 'NAME+HPHT+PUSKESMAS+ANC_DATE'

      ELSE 'WEAK_KEY_DO_NOT_ENCOUNTER_DEDUP'
    END AS dedup_method,


    CASE
      -- ------------------------------------------------------
      -- Strongest identity: valid NIK + ANC date
      -- ------------------------------------------------------
      WHEN
        flag_nik_valid_16_digit = TRUE
        AND tanggal_antenatal_date IS NOT NULL
      THEN CONCAT(
        'NIK|',
        nik_clean,
        '|ANC|',
        CAST(
          tanggal_antenatal_date
          AS STRING
        )
      )


      -- ------------------------------------------------------
      -- Fallback: name + DOB + facility + ANC date
      -- ------------------------------------------------------
      WHEN
        nama_pasien_clean IS NOT NULL
        AND tanggal_lahir_date IS NOT NULL
        AND puskesmas_name_clean IS NOT NULL
        AND tanggal_antenatal_date IS NOT NULL
      THEN CONCAT(
        'NAME_DOB_PKM|',
        nama_pasien_clean,
        '|',
        CAST(
          tanggal_lahir_date
          AS STRING
        ),
        '|',
        puskesmas_name_clean,
        '|ANC|',
        CAST(
          tanggal_antenatal_date
          AS STRING
        )
      )


      -- ------------------------------------------------------
      -- Fallback: name + HPHT + facility + ANC date
      -- ------------------------------------------------------
      WHEN
        nama_pasien_clean IS NOT NULL
        AND tanggal_hpht_date IS NOT NULL
        AND puskesmas_name_clean IS NOT NULL
        AND tanggal_antenatal_date IS NOT NULL
      THEN CONCAT(
        'NAME_HPHT_PKM|',
        nama_pasien_clean,
        '|',
        CAST(
          tanggal_hpht_date
          AS STRING
        ),
        '|',
        puskesmas_name_clean,
        '|ANC|',
        CAST(
          tanggal_antenatal_date
          AS STRING
        )
      )


      -- ------------------------------------------------------
      -- Weak identity:
      -- make every remaining clinical row unique so it cannot
      -- accidentally merge with another patient.
      -- ------------------------------------------------------
      ELSE CONCAT(
        'SOURCE|',
        source_record_id,
        '|',
        clinical_content_hash
      )

    END AS anc_encounter_key

  FROM exact_deduplicated e
),


-- ============================================================
-- 9. ENCOUNTER DEDUPLICATION
--
-- If multiple clinical variants represent the same ANC
-- encounter, prefer:
--
--   1. latest source snapshot
--   2. most complete row
--   3. deterministic hash
--
-- raw_encounter_record_count includes repeated copies removed
-- during exact-dedup as well.
-- ============================================================
encounter_ranked AS (
  SELECT
    e.*,

    COUNT(*) OVER (
      PARTITION BY anc_encounter_key
    ) AS encounter_variant_count,


    SUM(exact_duplicate_count) OVER (
      PARTITION BY anc_encounter_key
    ) AS raw_encounter_record_count,


    ROW_NUMBER() OVER (
      PARTITION BY anc_encounter_key
      ORDER BY
        source_recency_timestamp DESC,
        row_completeness_score DESC,
        source_row_hash DESC
    ) AS encounter_dedup_rank

  FROM encounter_keyed e
)


-- ============================================================
-- 10. FINAL OUTPUT
-- ============================================================
SELECT
  * EXCEPT (
    exact_dedup_rank,
    encounter_dedup_rank
  ),


  -- ----------------------------------------------------------
  -- Exact duplicate indicator
  -- ----------------------------------------------------------
  CASE
    WHEN exact_duplicate_count > 1
    THEN TRUE
    ELSE FALSE
  END AS is_exact_duplicate_group,


  -- ----------------------------------------------------------
  -- Same-encounter duplicate indicator
  -- ----------------------------------------------------------
  CASE
    WHEN
      dedup_method != 'WEAK_KEY_DO_NOT_ENCOUNTER_DEDUP'
      AND raw_encounter_record_count > 1
    THEN TRUE
    ELSE FALSE
  END AS is_duplicate_group,


  -- ----------------------------------------------------------
  -- Human-readable deduplication status
  -- ----------------------------------------------------------
  CASE

    WHEN
      dedup_method = 'WEAK_KEY_DO_NOT_ENCOUNTER_DEDUP'
      AND exact_duplicate_count > 1
    THEN
      'Exact duplicate removed; encounter kept separately because identifier is too weak'


    WHEN
      dedup_method = 'WEAK_KEY_DO_NOT_ENCOUNTER_DEDUP'
    THEN
      'Kept separately because identifier is too weak for safe encounter deduplication'


    WHEN raw_encounter_record_count > 1
    THEN
      'Deduplicated: latest/best version retained for the same ANC encounter'


    ELSE
      'Unique ANC encounter'

  END AS deduplication_status


FROM encounter_ranked

WHERE
  encounter_dedup_rank = 1;

CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.vs_epus_inc` AS
WITH
-- ============================================================
-- 1. RAW SOURCE
-- ============================================================
source AS (
  SELECT
    t.* EXCEPT (`no`),

    FARM_FINGERPRINT(
      TO_JSON_STRING(
        (
          SELECT AS STRUCT
            t.* EXCEPT (`no`)
        )
      )
    ) AS source_row_hash,

    TO_HEX(
      SHA256(
        TO_JSON_STRING(
          (
            SELECT AS STRUCT
              t.* EXCEPT (
                `no`,
                file_name,
                file_date,
                ingestion_timestamp,
                uuid,
                hash_code
              )
          )
        )
      )
    ) AS clinical_content_hash

  FROM
    `spheres-lombok-barat.raw_data.epus_inc` t
),


-- ============================================================
-- 2. BASIC CLEANING
-- ============================================================
cleaned AS (
  SELECT
    s.*,

    -- --------------------------------------------------------
    -- Source record ID
    -- --------------------------------------------------------
    COALESCE(
      NULLIF(TRIM(uuid), ''),
      NULLIF(TRIM(hash_code), ''),
      CAST(source_row_hash AS STRING)
    ) AS source_record_id,


    -- --------------------------------------------------------
    -- NIK
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        COALESCE(TRIM(nik), ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS nik_clean,


    -- --------------------------------------------------------
    -- Mother name
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          UPPER(TRIM(COALESCE(nama_pasien, ''))),
          r'[^A-Z0-9 ]',
          ' '
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS nama_pasien_clean,


    -- --------------------------------------------------------
    -- Baby name
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          UPPER(TRIM(COALESCE(nama_bayi, ''))),
          r'[^A-Z0-9 ]',
          ' '
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS nama_bayi_clean,


    -- --------------------------------------------------------
    -- Puskesmas
    -- --------------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            UPPER(
              TRIM(
                COALESCE(
                  puskesmas_name,
                  ''
                )
              )
            ),
            r'\s+',
            ' '
          ),
          r'^(PUSKESMAS|PKM)\s+',
          ''
        )
      ),
      ''
    ) AS puskesmas_name_clean,

    NULLIF(
      TRIM(puskesmas_id),
      ''
    ) AS puskesmas_id_clean,


    -- --------------------------------------------------------
    -- Maternal / baby status
    -- --------------------------------------------------------
    NULLIF(
      UPPER(TRIM(keadaan_ibu)),
      ''
    ) AS keadaan_ibu_clean,

    NULLIF(
      UPPER(TRIM(keadaan_ibu_saat_ini)),
      ''
    ) AS keadaan_ibu_saat_ini_clean,

    NULLIF(
      UPPER(TRIM(keadaan_bayi)),
      ''
    ) AS keadaan_bayi_clean,

    NULLIF(
      UPPER(TRIM(keadaan_tiba)),
      ''
    ) AS keadaan_tiba_clean,

    NULLIF(
      UPPER(TRIM(keadaan_pulang)),
      ''
    ) AS keadaan_pulang_clean,

    NULLIF(
      UPPER(TRIM(keadaan_pulang_persalinan)),
      ''
    ) AS keadaan_pulang_persalinan_clean,


    -- --------------------------------------------------------
    -- Delivery variables
    -- --------------------------------------------------------
    NULLIF(
      UPPER(TRIM(jenis_kelamin_bayi)),
      ''
    ) AS jenis_kelamin_bayi_clean,

    NULLIF(
      UPPER(TRIM(cara_persalinan)),
      ''
    ) AS cara_persalinan_clean,

    NULLIF(
      UPPER(TRIM(penolong)),
      ''
    ) AS penolong_clean,

    NULLIF(
      UPPER(TRIM(komplikasi)),
      ''
    ) AS komplikasi_clean,

    NULLIF(
      UPPER(TRIM(komplikasi_persalinan)),
      ''
    ) AS komplikasi_persalinan_clean,

    NULLIF(
      UPPER(TRIM(presentasi)),
      ''
    ) AS presentasi_clean,

    NULLIF(
      UPPER(TRIM(presentasi_awal)),
      ''
    ) AS presentasi_awal_clean,

    NULLIF(
      UPPER(TRIM(letak_janin)),
      ''
    ) AS letak_janin_clean,

    NULLIF(
      UPPER(TRIM(kondisi_ketuban)),
      ''
    ) AS kondisi_ketuban_clean,


    -- --------------------------------------------------------
    -- Raw dates
    -- --------------------------------------------------------
    NULLIF(
      TRIM(tanggal_lahir),
      ''
    ) AS tanggal_lahir_raw_clean,

    NULLIF(
      TRIM(tanggal_hpht),
      ''
    ) AS tanggal_hpht_raw_clean,

    NULLIF(
      TRIM(tanggal_taksiran_persalinan),
      ''
    ) AS tanggal_taksiran_persalinan_raw_clean,

    NULLIF(
      TRIM(tanggal_persalinan_sebelumnya),
      ''
    ) AS tanggal_persalinan_sebelumnya_raw_clean,

    NULLIF(
      TRIM(tanggal_persalinan),
      ''
    ) AS tanggal_persalinan_raw_clean,

    NULLIF(
      TRIM(tanggal_kala_aktif),
      ''
    ) AS tanggal_kala_aktif_raw_clean,

    NULLIF(
      TRIM(bayi_lahir_tanggal),
      ''
    ) AS bayi_lahir_tanggal_raw_clean,

    NULLIF(
      TRIM(plasenta_lahir_tanggal),
      ''
    ) AS plasenta_lahir_tanggal_raw_clean,


    -- --------------------------------------------------------
    -- Times
    -- --------------------------------------------------------
    NULLIF(
      TRIM(jam_kala_aktif),
      ''
    ) AS jam_kala_aktif_raw_clean,

    NULLIF(
      TRIM(bayi_lahir_jam),
      ''
    ) AS bayi_lahir_jam_raw_clean,

    NULLIF(
      TRIM(plasenta_lahir_jam),
      ''
    ) AS plasenta_lahir_jam_raw_clean,


    -- --------------------------------------------------------
    -- Source metadata
    -- --------------------------------------------------------
    NULLIF(
      TRIM(file_date),
      ''
    ) AS file_date_raw_clean,

    NULLIF(
      TRIM(ingestion_timestamp),
      ''
    ) AS ingestion_timestamp_raw_clean

  FROM source s
),


-- ============================================================
-- 3. NIK VALIDATION
-- ============================================================
identity_cleaned AS (
  SELECT
    c.*,

    CASE
      WHEN
        REGEXP_CONTAINS(
          nik_clean,
          r'^\d{16}$'
        )
        AND nik_clean NOT IN (
          '0000000000000000',
          '9999999999999999'
        )
      THEN TRUE
      ELSE FALSE
    END AS flag_nik_valid_16_digit

  FROM cleaned c
),


-- ============================================================
-- 4. DATE + TIME PARSING
-- ============================================================
parsed AS (
  SELECT
    i.*,


    -- --------------------------------------------------------
    -- DOB
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_lahir_raw_clean,
          r'^\d{5}(\.0+)?$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            REGEXP_EXTRACT(
              tanggal_lahir_raw_clean,
              r'^\d+'
            )
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_lahir_date,


    -- --------------------------------------------------------
    -- HPHT
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_hpht_raw_clean,
          r'^\d{5}(\.0+)?$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            REGEXP_EXTRACT(
              tanggal_hpht_raw_clean,
              r'^\d+'
            )
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_hpht_date,


    -- --------------------------------------------------------
    -- HPL
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_taksiran_persalinan_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_taksiran_persalinan_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_taksiran_persalinan_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_taksiran_persalinan_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_taksiran_persalinan_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_taksiran_persalinan_raw_clean,
          r'^\d{5}(\.0+)?$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            REGEXP_EXTRACT(
              tanggal_taksiran_persalinan_raw_clean,
              r'^\d+'
            )
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_taksiran_persalinan_date,


    -- --------------------------------------------------------
    -- Previous delivery
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_persalinan_sebelumnya_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_persalinan_sebelumnya_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_persalinan_sebelumnya_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_persalinan_sebelumnya_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_persalinan_sebelumnya_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_persalinan_sebelumnya_raw_clean,
          r'^\d{5}(\.0+)?$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            REGEXP_EXTRACT(
              tanggal_persalinan_sebelumnya_raw_clean,
              r'^\d+'
            )
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_persalinan_sebelumnya_date,


    -- --------------------------------------------------------
    -- Maternal delivery date
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_persalinan_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_persalinan_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_persalinan_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_persalinan_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_persalinan_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_persalinan_raw_clean,
          r'^\d{5}(\.0+)?$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            REGEXP_EXTRACT(
              tanggal_persalinan_raw_clean,
              r'^\d+'
            )
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_persalinan_date,


    -- --------------------------------------------------------
    -- Active labour date
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_kala_aktif_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_kala_aktif_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_kala_aktif_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_kala_aktif_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_kala_aktif_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      )
    ) AS tanggal_kala_aktif_date,


    -- --------------------------------------------------------
    -- Baby birth date
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          bayi_lahir_tanggal_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          bayi_lahir_tanggal_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          bayi_lahir_tanggal_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          bayi_lahir_tanggal_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          bayi_lahir_tanggal_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      )
    ) AS bayi_lahir_tanggal_date,


    -- --------------------------------------------------------
    -- Placenta delivery date
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          plasenta_lahir_tanggal_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          plasenta_lahir_tanggal_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          plasenta_lahir_tanggal_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          plasenta_lahir_tanggal_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          plasenta_lahir_tanggal_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      )
    ) AS plasenta_lahir_tanggal_date,


    -- --------------------------------------------------------
    -- Times
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_TIME(
        '%H:%M:%S',
        REGEXP_EXTRACT(
          jam_kala_aktif_raw_clean,
          r'\d{1,2}:\d{2}:\d{2}'
        )
      ),
      SAFE.PARSE_TIME(
        '%H:%M',
        REGEXP_EXTRACT(
          jam_kala_aktif_raw_clean,
          r'\d{1,2}:\d{2}'
        )
      )
    ) AS jam_kala_aktif_time,


    COALESCE(
      SAFE.PARSE_TIME(
        '%H:%M:%S',
        REGEXP_EXTRACT(
          bayi_lahir_jam_raw_clean,
          r'\d{1,2}:\d{2}:\d{2}'
        )
      ),
      SAFE.PARSE_TIME(
        '%H:%M',
        REGEXP_EXTRACT(
          bayi_lahir_jam_raw_clean,
          r'\d{1,2}:\d{2}'
        )
      )
    ) AS bayi_lahir_jam_time,


    COALESCE(
      SAFE.PARSE_TIME(
        '%H:%M:%S',
        REGEXP_EXTRACT(
          plasenta_lahir_jam_raw_clean,
          r'\d{1,2}:\d{2}:\d{2}'
        )
      ),
      SAFE.PARSE_TIME(
        '%H:%M',
        REGEXP_EXTRACT(
          plasenta_lahir_jam_raw_clean,
          r'\d{1,2}:\d{2}'
        )
      )
    ) AS plasenta_lahir_jam_time,


    -- --------------------------------------------------------
    -- File date
    -- --------------------------------------------------------
    COALESCE(
      SAFE_CAST(
        file_date_raw_clean AS DATE
      ),

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          file_date_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          file_date_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          file_date_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          file_date_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      )
    ) AS file_date_parsed,


    SAFE_CAST(
      ingestion_timestamp_raw_clean
      AS TIMESTAMP
    ) AS ingestion_timestamp_parsed

  FROM identity_cleaned i
),


-- ============================================================
-- 5. NUMERIC NORMALIZATION
-- ============================================================
typed AS (
  SELECT
    p.*,

    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(gravida),
        r'-?\d+'
      )
      AS INT64
    ) AS gravida_numeric,

    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(partus),
        r'-?\d+'
      )
      AS INT64
    ) AS partus_numeric,

    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(abortus),
        r'-?\d+'
      )
      AS INT64
    ) AS abortus_numeric,

    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(hidup),
        r'-?\d+'
      )
      AS INT64
    ) AS hidup_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(bb_sebelum_hamil),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS bb_sebelum_hamil_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(bb_bayi),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS bb_bayi_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(usia_kehamilan),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS usia_kehamilan_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(usia_hpht),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS usia_hpht_numeric,


    -- --------------------------------------------------------
    -- Blood pressure
    -- --------------------------------------------------------
    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(tekanan_darah),
        r'^\s*(\d{2,3})\s*/'
      )
      AS FLOAT64
    ) AS sistole_numeric,

    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(tekanan_darah),
        r'/\s*(\d{2,3})'
      )
      AS FLOAT64
    ) AS diastole_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(nadi),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS nadi_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(nafas),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS nafas_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(suhu),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS suhu_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(tinggi_fundus),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS tinggi_fundus_numeric,


    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(detak_jantung_janin),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS detak_jantung_janin_numeric

  FROM parsed p
),


-- ============================================================
-- 6. DELIVERY + BABY + MATERNAL OUTCOME STANDARDIZATION
-- ============================================================
standardized AS (
  SELECT
    t.*,


    -- ========================================================
    -- DELIVERY DATE
    --
    -- CURRENT LOGIC RETAINED
    -- ========================================================
    COALESCE(
      bayi_lahir_tanggal_date,
      tanggal_persalinan_date,
      plasenta_lahir_tanggal_date
    ) AS delivery_event_date,


    CASE
      WHEN bayi_lahir_tanggal_date IS NOT NULL
      THEN 'BAYI_LAHIR_TANGGAL'

      WHEN tanggal_persalinan_date IS NOT NULL
      THEN 'TANGGAL_PERSALINAN'

      WHEN plasenta_lahir_tanggal_date IS NOT NULL
      THEN 'PLASENTA_LAHIR_TANGGAL'

      ELSE NULL
    END AS delivery_event_date_source,


    -- ========================================================
    -- BABY / BIRTH OUTCOME
    -- ========================================================

    CASE
      -- ------------------------------------------------------
      -- Explicit live birth
      -- ------------------------------------------------------
      WHEN keadaan_bayi_clean = 'HIDUP'
      THEN 'LAHIR HIDUP'


      -- ------------------------------------------------------
      -- Explicit stillbirth terminology if it appears
      -- ------------------------------------------------------
      WHEN keadaan_bayi_clean IN (
        'LAHIR MATI',
        'STILLBIRTH',
        'IUFD'
      )
      THEN 'LAHIR MATI'


      -- ------------------------------------------------------
      -- "MENINGGAL" alone does not distinguish stillbirth
      -- from live birth followed by neonatal death.
      -- ------------------------------------------------------
      WHEN keadaan_bayi_clean = 'MENINGGAL'
      THEN 'UNKNOWN'


      -- ------------------------------------------------------
      -- keadaan_bayi missing but narrative explicitly says
      -- stillbirth
      -- ------------------------------------------------------
      WHEN
        keadaan_bayi_clean IS NULL
        AND REGEXP_CONTAINS(
          UPPER(
            COALESCE(
              keterangan_kondisi_lahir,
              ''
            )
          ),
          r'\b(LAHIR MATI|STILLBIRTH|IUFD)\b'
        )
      THEN 'LAHIR MATI'


      -- ------------------------------------------------------
      -- keadaan_bayi missing + convincing live-birth evidence
      --
      -- Includes:
      -- SEHAT
      -- BAIK
      -- NORMAL
      -- LAHIR HIDUP
      -- HIDUP
      -- MENANGIS
      -- KEMERAHAN
      -- GERAK AKTIF
      -- BERGERAK AKTIF
      -- ------------------------------------------------------
      WHEN
        keadaan_bayi_clean IS NULL

        -- death terminology gets precedence
        AND NOT REGEXP_CONTAINS(
          UPPER(
            COALESCE(
              keterangan_kondisi_lahir,
              ''
            )
          ),
          r'\b(MENINGGAL|LAHIR MATI|STILLBIRTH|IUFD)\b'
        )

        AND REGEXP_CONTAINS(
          UPPER(
            COALESCE(
              keterangan_kondisi_lahir,
              ''
            )
          ),
          r'\b(LAHIR HIDUP|HIDUP|MENANGIS|SEHAT|BAIK|NORMAL|KEMERAHAN|GERAK AKTIF|BERGERAK AKTIF)\b'
        )
      THEN 'LAHIR HIDUP'


      ELSE 'UNKNOWN'
    END AS birth_outcome_category,


    NULLIF(
      TRIM(keadaan_bayi),
      ''
    ) AS birth_outcome_raw,


    NULLIF(
      TRIM(keterangan_kondisi_lahir),
      ''
    ) AS birth_outcome_supporting_text,


    -- --------------------------------------------------------
    -- Birth outcome source
    -- --------------------------------------------------------
    CASE
      WHEN keadaan_bayi_clean = 'HIDUP'
      THEN 'EPUS_INC_KEADAAN_BAYI'

      WHEN keadaan_bayi_clean IN (
        'LAHIR MATI',
        'STILLBIRTH',
        'IUFD'
      )
      THEN 'EPUS_INC_KEADAAN_BAYI'

      WHEN keadaan_bayi_clean = 'MENINGGAL'
      THEN 'EPUS_INC_KEADAAN_BAYI_DEATH_UNRESOLVED'

      WHEN
        keadaan_bayi_clean IS NULL
        AND REGEXP_CONTAINS(
          UPPER(
            COALESCE(
              keterangan_kondisi_lahir,
              ''
            )
          ),
          r'\b(LAHIR MATI|STILLBIRTH|IUFD)\b'
        )
      THEN 'EPUS_INC_KETERANGAN_KONDISI_LAHIR'

      WHEN
        keadaan_bayi_clean IS NULL
        AND NOT REGEXP_CONTAINS(
          UPPER(
            COALESCE(
              keterangan_kondisi_lahir,
              ''
            )
          ),
          r'\b(MENINGGAL|LAHIR MATI|STILLBIRTH|IUFD)\b'
        )
        AND REGEXP_CONTAINS(
          UPPER(
            COALESCE(
              keterangan_kondisi_lahir,
              ''
            )
          ),
          r'\b(LAHIR HIDUP|HIDUP|MENANGIS|SEHAT|BAIK|NORMAL|KEMERAHAN|GERAK AKTIF|BERGERAK AKTIF)\b'
        )
      THEN 'EPUS_INC_KETERANGAN_KONDISI_LAHIR'

      ELSE NULL
    END AS birth_outcome_source,


    -- --------------------------------------------------------
    -- Birth outcome confidence
    -- --------------------------------------------------------
    CASE
      WHEN keadaan_bayi_clean = 'HIDUP'
      THEN 'HIGH'

      WHEN keadaan_bayi_clean IN (
        'LAHIR MATI',
        'STILLBIRTH',
        'IUFD'
      )
      THEN 'HIGH'

      WHEN
        keadaan_bayi_clean IS NULL
        AND REGEXP_CONTAINS(
          UPPER(
            COALESCE(
              keterangan_kondisi_lahir,
              ''
            )
          ),
          r'\b(LAHIR MATI|STILLBIRTH|IUFD)\b'
        )
      THEN 'MEDIUM'

      WHEN
        keadaan_bayi_clean IS NULL
        AND NOT REGEXP_CONTAINS(
          UPPER(
            COALESCE(
              keterangan_kondisi_lahir,
              ''
            )
          ),
          r'\b(MENINGGAL|LAHIR MATI|STILLBIRTH|IUFD)\b'
        )
        AND REGEXP_CONTAINS(
          UPPER(
            COALESCE(
              keterangan_kondisi_lahir,
              ''
            )
          ),
          r'\b(LAHIR HIDUP|HIDUP|MENANGIS|SEHAT|BAIK|NORMAL|KEMERAHAN|GERAK AKTIF|BERGERAK AKTIF)\b'
        )
      THEN 'MEDIUM'

      ELSE 'LOW'
    END AS birth_outcome_confidence,


    -- --------------------------------------------------------
    -- Baby death recorded
    --
    -- Does NOT automatically mean stillbirth.
    -- --------------------------------------------------------
    CASE
      WHEN keadaan_bayi_clean = 'MENINGGAL'
      THEN TRUE

      WHEN REGEXP_CONTAINS(
        UPPER(
          COALESCE(
            keterangan_kondisi_lahir,
            ''
          )
        ),
        r'\b(MENINGGAL|LAHIR MATI|STILLBIRTH|IUFD)\b'
      )
      THEN TRUE

      ELSE FALSE
    END AS baby_death_recorded,


    -- ========================================================
    -- MATERNAL OUTCOME
    --
    -- This represents the best observed vital outcome.
    --
    -- Death evidence has priority over earlier "HIDUP"
    -- because a woman may be alive during delivery and die
    -- later in the postpartum period.
    -- ========================================================
    CASE
      -- explicit maternal death
      WHEN keadaan_ibu_clean = 'MENINGGAL'
      THEN 'MENINGGAL'

      -- postpartum/discharge death
      WHEN REGEXP_CONTAINS(
        COALESCE(
          keadaan_pulang_persalinan_clean,
          ''
        ),
        r'\bMENINGGAL\b'
      )
      THEN 'MENINGGAL'

      -- meaningful recorded death time
      WHEN
        NULLIF(TRIM(waktu_kematian), '') IS NOT NULL
        AND UPPER(TRIM(waktu_kematian)) NOT IN (
          '-',
          '0',
          '00:00',
          '00:00:00',
          'TIDAK',
          'TIDAK ADA'
        )
      THEN 'MENINGGAL'

      -- explicit alive status
      WHEN keadaan_ibu_clean = 'HIDUP'
      THEN 'HIDUP'

      -- discharge status implies mother still alive
      WHEN keadaan_pulang_persalinan_clean IN (
        'STABIL',
        'TIDAK STABIL',
        'DIRUJUK'
      )
      THEN 'HIDUP'

      ELSE 'UNKNOWN'
    END AS maternal_outcome_category,


    -- --------------------------------------------------------
    -- Primary raw maternal outcome
    -- --------------------------------------------------------
    NULLIF(
      TRIM(keadaan_ibu),
      ''
    ) AS maternal_outcome_raw,


    -- --------------------------------------------------------
    -- Maternal outcome source
    -- --------------------------------------------------------
    CASE
      WHEN keadaan_ibu_clean = 'MENINGGAL'
      THEN 'EPUS_INC_KEADAAN_IBU'

      WHEN REGEXP_CONTAINS(
        COALESCE(
          keadaan_pulang_persalinan_clean,
          ''
        ),
        r'\bMENINGGAL\b'
      )
      THEN 'EPUS_INC_KEADAAN_PULANG_PERSALINAN'

      WHEN
        NULLIF(TRIM(waktu_kematian), '') IS NOT NULL
        AND UPPER(TRIM(waktu_kematian)) NOT IN (
          '-',
          '0',
          '00:00',
          '00:00:00',
          'TIDAK',
          'TIDAK ADA'
        )
      THEN 'EPUS_INC_WAKTU_KEMATIAN'

      WHEN keadaan_ibu_clean = 'HIDUP'
      THEN 'EPUS_INC_KEADAAN_IBU'

      WHEN keadaan_pulang_persalinan_clean IN (
        'STABIL',
        'TIDAK STABIL',
        'DIRUJUK'
      )
      THEN 'EPUS_INC_KEADAAN_PULANG_PERSALINAN'

      ELSE NULL
    END AS maternal_outcome_source,


    -- --------------------------------------------------------
    -- Maternal outcome confidence
    -- --------------------------------------------------------
    CASE
      WHEN keadaan_ibu_clean IN (
        'HIDUP',
        'MENINGGAL'
      )
      THEN 'HIGH'

      WHEN REGEXP_CONTAINS(
        COALESCE(
          keadaan_pulang_persalinan_clean,
          ''
        ),
        r'\bMENINGGAL\b'
      )
      THEN 'HIGH'

      WHEN
        NULLIF(TRIM(waktu_kematian), '') IS NOT NULL
        AND UPPER(TRIM(waktu_kematian)) NOT IN (
          '-',
          '0',
          '00:00',
          '00:00:00',
          'TIDAK',
          'TIDAK ADA'
        )
      THEN 'MEDIUM'

      WHEN keadaan_pulang_persalinan_clean IN (
        'STABIL',
        'TIDAK STABIL',
        'DIRUJUK'
      )
      THEN 'MEDIUM'

      ELSE 'LOW'
    END AS maternal_outcome_confidence,


    -- --------------------------------------------------------
    -- Maternal death indicator
    -- --------------------------------------------------------
    CASE
      WHEN keadaan_ibu_clean = 'MENINGGAL'
      THEN TRUE

      WHEN REGEXP_CONTAINS(
        COALESCE(
          keadaan_pulang_persalinan_clean,
          ''
        ),
        r'\bMENINGGAL\b'
      )
      THEN TRUE

      WHEN
        NULLIF(TRIM(waktu_kematian), '') IS NOT NULL
        AND UPPER(TRIM(waktu_kematian)) NOT IN (
          '-',
          '0',
          '00:00',
          '00:00:00',
          'TIDAK',
          'TIDAK ADA'
        )
      THEN TRUE

      ELSE FALSE
    END AS maternal_death_recorded,


    -- ========================================================
    -- MATERNAL POST-DELIVERY CONDITION
    --
    -- Separate from vital outcome.
    -- ========================================================
    CASE
      WHEN keadaan_pulang_persalinan_clean = 'STABIL'
      THEN 'STABIL'

      WHEN keadaan_pulang_persalinan_clean = 'TIDAK STABIL'
      THEN 'TIDAK STABIL'

      WHEN keadaan_pulang_persalinan_clean = 'DIRUJUK'
      THEN 'DIRUJUK'

      WHEN REGEXP_CONTAINS(
        COALESCE(
          keadaan_pulang_persalinan_clean,
          ''
        ),
        r'\bMENINGGAL\b'
      )
      THEN 'MENINGGAL'

      ELSE 'UNKNOWN'
    END AS maternal_postdelivery_status,


    -- Current clinical condition as recorded
    keadaan_ibu_saat_ini_clean
      AS maternal_current_condition,


    -- ========================================================
    -- MATERNAL DATA-CONFLICT FLAG
    --
    -- Important:
    -- HIDUP + MENINGGAL <48 JAM is NOT a conflict.
    -- The statuses can represent different time points.
    --
    -- This only flags the more suspicious reverse pattern:
    -- primary status already says MENINGGAL, but later
    -- discharge field says STABIL/TIDAK STABIL/DIRUJUK.
    -- ========================================================
    CASE
      WHEN
        keadaan_ibu_clean = 'MENINGGAL'
        AND keadaan_pulang_persalinan_clean IN (
          'STABIL',
          'TIDAK STABIL',
          'DIRUJUK'
        )
      THEN TRUE

      ELSE FALSE
    END AS flag_maternal_outcome_conflict,


    -- ========================================================
    -- DATETIME FIELDS
    -- ========================================================
    CASE
      WHEN
        tanggal_kala_aktif_date IS NOT NULL
        AND jam_kala_aktif_time IS NOT NULL
      THEN DATETIME(
        tanggal_kala_aktif_date,
        jam_kala_aktif_time
      )
    END AS kala_aktif_datetime,


    CASE
      WHEN
        bayi_lahir_tanggal_date IS NOT NULL
        AND bayi_lahir_jam_time IS NOT NULL
      THEN DATETIME(
        bayi_lahir_tanggal_date,
        bayi_lahir_jam_time
      )
    END AS bayi_lahir_datetime,


    CASE
      WHEN
        plasenta_lahir_tanggal_date IS NOT NULL
        AND plasenta_lahir_jam_time IS NOT NULL
      THEN DATETIME(
        plasenta_lahir_tanggal_date,
        plasenta_lahir_jam_time
      )
    END AS plasenta_lahir_datetime,


    -- ========================================================
    -- DELIVERY DATE QA
    -- ========================================================
    CASE
      WHEN
        tanggal_persalinan_date IS NOT NULL
        AND bayi_lahir_tanggal_date IS NOT NULL
        AND tanggal_persalinan_date
            != bayi_lahir_tanggal_date
      THEN TRUE
      ELSE FALSE
    END AS flag_delivery_date_discrepancy,


    CASE
      WHEN
        tanggal_persalinan_date IS NOT NULL
        AND bayi_lahir_tanggal_date IS NOT NULL
      THEN DATE_DIFF(
        bayi_lahir_tanggal_date,
        tanggal_persalinan_date,
        DAY
      )
    END AS delivery_date_difference_days,


    -- ========================================================
    -- SOURCE RECENCY
    -- ========================================================
    COALESCE(
      ingestion_timestamp_parsed,

      CASE
        WHEN file_date_parsed IS NOT NULL
        THEN TIMESTAMP(file_date_parsed)
      END,

      TIMESTAMP '1900-01-01 00:00:00+00'
    ) AS source_recency_timestamp

  FROM typed t
),


-- ============================================================
-- 7. COMPLETENESS SCORE
-- ============================================================
scored AS (
  SELECT
    s.*,

    (
      IF(flag_nik_valid_16_digit, 1, 0)
      + IF(nama_pasien_clean IS NOT NULL, 1, 0)
      + IF(tanggal_lahir_date IS NOT NULL, 1, 0)
      + IF(tanggal_hpht_date IS NOT NULL, 1, 0)
      + IF(
          tanggal_taksiran_persalinan_date IS NOT NULL,
          1,
          0
        )
      + IF(delivery_event_date IS NOT NULL, 1, 0)
      + IF(tanggal_persalinan_date IS NOT NULL, 1, 0)
      + IF(bayi_lahir_tanggal_date IS NOT NULL, 1, 0)
      + IF(bayi_lahir_jam_time IS NOT NULL, 1, 0)
      + IF(nama_bayi_clean IS NOT NULL, 1, 0)
      + IF(jenis_kelamin_bayi_clean IS NOT NULL, 1, 0)
      + IF(bb_bayi_numeric IS NOT NULL, 1, 0)
      + IF(usia_kehamilan_numeric IS NOT NULL, 1, 0)
      + IF(keadaan_ibu_clean IS NOT NULL, 1, 0)
      + IF(keadaan_bayi_clean IS NOT NULL, 1, 0)
      + IF(
          birth_outcome_category != 'UNKNOWN',
          1,
          0
        )
      + IF(
          maternal_outcome_category != 'UNKNOWN',
          1,
          0
        )
      + IF(
          maternal_postdelivery_status != 'UNKNOWN',
          1,
          0
        )
      + IF(cara_persalinan_clean IS NOT NULL, 1, 0)
      + IF(penolong_clean IS NOT NULL, 1, 0)
      + IF(
          komplikasi_persalinan_clean IS NOT NULL,
          1,
          0
        )
      + IF(puskesmas_name_clean IS NOT NULL, 1, 0)
    ) AS row_completeness_score

  FROM standardized s
),


-- ============================================================
-- 8. EXACT CLINICAL DUPLICATES
-- ============================================================
exact_ranked AS (
  SELECT
    s.*,

    COUNT(*) OVER (
      PARTITION BY clinical_content_hash
    ) AS exact_duplicate_count,

    ROW_NUMBER() OVER (
      PARTITION BY clinical_content_hash
      ORDER BY
        source_recency_timestamp DESC,
        source_row_hash DESC
    ) AS exact_dedup_rank

  FROM scored s
),


exact_deduplicated AS (
  SELECT
    *
  FROM exact_ranked
  WHERE exact_dedup_rank = 1
),


-- ============================================================
-- 9. MOTHER + BABY IDENTITY
-- ============================================================
mother_baby_keyed AS (
  SELECT
    e.*,

    -- --------------------------------------------------------
    -- Mother identity
    -- --------------------------------------------------------
    CASE
      WHEN flag_nik_valid_16_digit = TRUE
      THEN 'NIK'

      WHEN
        nama_pasien_clean IS NOT NULL
        AND tanggal_lahir_date IS NOT NULL
        AND puskesmas_name_clean IS NOT NULL
      THEN 'NAME+DOB+PUSKESMAS'

      WHEN
        nama_pasien_clean IS NOT NULL
        AND tanggal_hpht_date IS NOT NULL
        AND puskesmas_name_clean IS NOT NULL
      THEN 'NAME+HPHT+PUSKESMAS'

      ELSE 'WEAK_MOTHER_IDENTITY'
    END AS mother_identity_method,


    CASE
      WHEN flag_nik_valid_16_digit = TRUE
      THEN CONCAT(
        'NIK|',
        nik_clean
      )

      WHEN
        nama_pasien_clean IS NOT NULL
        AND tanggal_lahir_date IS NOT NULL
        AND puskesmas_name_clean IS NOT NULL
      THEN CONCAT(
        'NAME_DOB_PKM|',
        nama_pasien_clean,
        '|',
        CAST(tanggal_lahir_date AS STRING),
        '|',
        puskesmas_name_clean
      )

      WHEN
        nama_pasien_clean IS NOT NULL
        AND tanggal_hpht_date IS NOT NULL
        AND puskesmas_name_clean IS NOT NULL
      THEN CONCAT(
        'NAME_HPHT_PKM|',
        nama_pasien_clean,
        '|',
        CAST(tanggal_hpht_date AS STRING),
        '|',
        puskesmas_name_clean
      )

      ELSE NULL
    END AS mother_identity_key,


    -- --------------------------------------------------------
    -- Baby discriminator
    -- --------------------------------------------------------
    CASE
      WHEN bayi_lahir_jam_time IS NOT NULL
      THEN 'BIRTH_TIME_WITH_AVAILABLE_BABY_DETAIL'

      WHEN
        nama_bayi_clean IS NOT NULL
        AND jenis_kelamin_bayi_clean IS NOT NULL
        AND bb_bayi_numeric IS NOT NULL
      THEN 'BABY_NAME+SEX+BIRTH_WEIGHT'

      ELSE 'INSUFFICIENT_BABY_IDENTITY'
    END AS baby_discriminator_method,


    CASE
      WHEN bayi_lahir_jam_time IS NOT NULL
      THEN CONCAT(
        'TIME|',
        CAST(bayi_lahir_jam_time AS STRING),
        '|NAME|',
        COALESCE(nama_bayi_clean, ''),
        '|SEX|',
        COALESCE(jenis_kelamin_bayi_clean, ''),
        '|BW|',
        COALESCE(
          CAST(bb_bayi_numeric AS STRING),
          ''
        )
      )

      WHEN
        nama_bayi_clean IS NOT NULL
        AND jenis_kelamin_bayi_clean IS NOT NULL
        AND bb_bayi_numeric IS NOT NULL
      THEN CONCAT(
        'NAME_SEX_BW|',
        nama_bayi_clean,
        '|',
        jenis_kelamin_bayi_clean,
        '|',
        CAST(bb_bayi_numeric AS STRING)
      )

      ELSE NULL
    END AS baby_discriminator_key

  FROM exact_deduplicated e
),


-- ============================================================
-- 10. INC ENCOUNTER KEY
-- ============================================================
encounter_keyed AS (
  SELECT
    m.*,

    CASE
      WHEN
        mother_identity_method = 'NIK'
        AND delivery_event_date IS NOT NULL
        AND baby_discriminator_key IS NOT NULL
      THEN 'NIK+DELIVERY+BABY'

      WHEN
        mother_identity_method = 'NAME+DOB+PUSKESMAS'
        AND delivery_event_date IS NOT NULL
        AND baby_discriminator_key IS NOT NULL
      THEN 'NAME+DOB+PUSKESMAS+DELIVERY+BABY'

      WHEN
        mother_identity_method = 'NAME+HPHT+PUSKESMAS'
        AND delivery_event_date IS NOT NULL
        AND baby_discriminator_key IS NOT NULL
      THEN 'NAME+HPHT+PUSKESMAS+DELIVERY+BABY'

      ELSE 'WEAK_KEY_DO_NOT_ENCOUNTER_DEDUP'
    END AS dedup_method,


    CASE
      WHEN
        mother_identity_key IS NOT NULL
        AND delivery_event_date IS NOT NULL
        AND baby_discriminator_key IS NOT NULL
      THEN CONCAT(
        mother_identity_key,
        '|DELIVERY|',
        CAST(delivery_event_date AS STRING),
        '|BABY|',
        baby_discriminator_key
      )

      ELSE CONCAT(
        'SOURCE|',
        source_record_id,
        '|',
        clinical_content_hash
      )
    END AS inc_encounter_key

  FROM mother_baby_keyed m
),


-- ============================================================
-- 11. ENCOUNTER DEDUPLICATION
-- ============================================================
encounter_ranked AS (
  SELECT
    e.*,

    COUNT(*) OVER (
      PARTITION BY inc_encounter_key
    ) AS encounter_variant_count,

    SUM(exact_duplicate_count) OVER (
      PARTITION BY inc_encounter_key
    ) AS raw_encounter_record_count,

    ROW_NUMBER() OVER (
      PARTITION BY inc_encounter_key
      ORDER BY
        source_recency_timestamp DESC,
        row_completeness_score DESC,
        source_row_hash DESC
    ) AS encounter_dedup_rank

  FROM encounter_keyed e
),


final_deduplicated AS (
  SELECT
    *
  FROM encounter_ranked
  WHERE encounter_dedup_rank = 1
)


-- ============================================================
-- 12. FINAL OUTPUT
-- ============================================================
SELECT
  * EXCEPT (
    exact_dedup_rank,
    encounter_dedup_rank
  ),


  -- ----------------------------------------------------------
  -- Stable INC source record key
  -- ----------------------------------------------------------
  CONCAT(
    'EPINC_',
    TO_HEX(
      SHA256(inc_encounter_key)
    )
  ) AS epus_inc_record_key,


  -- ----------------------------------------------------------
  -- Duplicate QA
  -- ----------------------------------------------------------
  raw_encounter_record_count
    AS duplicate_key_count,


  CASE
    WHEN exact_duplicate_count > 1
    THEN TRUE
    ELSE FALSE
  END AS is_exact_duplicate_group,


  CASE
    WHEN
      dedup_method != 'WEAK_KEY_DO_NOT_ENCOUNTER_DEDUP'
      AND raw_encounter_record_count > 1
    THEN TRUE
    ELSE FALSE
  END AS is_duplicate_group,


  CASE
    WHEN
      dedup_method = 'WEAK_KEY_DO_NOT_ENCOUNTER_DEDUP'
      AND exact_duplicate_count > 1
    THEN
      'Exact duplicate removed; INC record kept separately because mother/baby identity is insufficient for safe encounter deduplication'

    WHEN
      dedup_method = 'WEAK_KEY_DO_NOT_ENCOUNTER_DEDUP'
    THEN
      'Kept separately because mother/baby identity is insufficient for safe encounter deduplication'

    WHEN raw_encounter_record_count > 1
    THEN
      'Deduplicated: latest/best version retained for the same INC delivery/baby record'

    ELSE
      'Unique INC delivery/baby record'
  END AS deduplication_status

FROM final_deduplicated;

CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.vs_kobo_inc_submission_clean` AS
WITH source AS (
  SELECT
    t.*,
    CAST(
      FARM_FINGERPRINT(TO_JSON_STRING(t))
      AS STRING
    ) AS source_row_hash

  FROM
    `spheres-lombok-barat.data_kobo_form.e-form_pencatatan_pelayanan_intranatal_care` t
),

raw_clean AS (
  SELECT
    -- =====================================================
    -- PROVENANCE
    -- =====================================================
    NULLIF(TRIM(case_id), '') AS case_id,

    COALESCE(
      NULLIF(TRIM(`_uuid`), ''),
      NULLIF(TRIM(`_id`), ''),
      source_row_hash
    ) AS submission_id,

    source_row_hash,

    SAFE_CAST(
      NULLIF(TRIM(`_submission_time`), '')
      AS TIMESTAMP
    ) AS submission_time,

    NULLIF(TRIM(username), '') AS username,
    NULLIF(TRIM(data_entry_clerk_type), '') AS data_entry_clerk_type,
    NULLIF(TRIM(data_entry_clerk_staff_id), '') AS data_entry_clerk_staff_id,

    NULLIF(TRIM(healthworker_name), '') AS healthworker_name,
    NULLIF(TRIM(healthworker_id), '') AS healthworker_id,

    NULLIF(TRIM(sumber_data), '') AS sumber_data,
    NULLIF(TRIM(link_file_original), '') AS link_file_original,


    -- =====================================================
    -- FACILITY
    -- =====================================================
    NULLIF(TRIM(Jenis_Fasilitas_Kesehatan), '') AS facility_type_raw,

    COALESCE(
      NULLIF(TRIM(Pilih_Nama_Puskesmas), ''),
      NULLIF(TRIM(Tuliskan_nama_Rumah_Sakit), ''),
      NULLIF(TRIM(Tuliskan_nama_Praktik_Mandiri_Bidan_PMB), ''),
      NULLIF(TRIM(Tuliskan_nama_Klinik), '')
    ) AS facility_name_raw,

    NULLIF(TRIM(Pilih_Nama_Puskesmas), '') AS puskesmas_raw,
    NULLIF(TRIM(Tuliskan_nama_Rumah_Sakit), '') AS rumah_sakit_raw,
    NULLIF(TRIM(Tuliskan_nama_Praktik_Mandiri_Bidan_PMB), '') AS pmb_raw,
    NULLIF(TRIM(Tuliskan_nama_Klinik), '') AS klinik_raw,


    -- =====================================================
    -- MOTHER IDENTITY
    -- =====================================================
    NULLIF(TRIM(first_name), '') AS mother_name_raw,
    NULLIF(TRIM(nik_mother), '') AS mother_nik_raw,
    NULLIF(TRIM(birth_date), '') AS mother_birth_date_raw,
    NULLIF(TRIM(age), '') AS mother_age_raw,

    NULLIF(TRIM(address_street), '') AS address_street,
    NULLIF(TRIM(Kabupaten), '') AS kabupaten,
    NULLIF(TRIM(Kecamatan), '') AS kecamatan,
    NULLIF(TRIM(Kelurahan), '') AS kelurahan,

    NULLIF(TRIM(contact_number), '') AS contact_number_raw,


    -- =====================================================
    -- PREGNANCY
    -- =====================================================
    NULLIF(TRIM(HPHT), '') AS hpht_raw,

    NULLIF(TRIM(Gravida), '') AS gravida_raw,
    NULLIF(TRIM(Partus), '') AS partus_raw,
    NULLIF(TRIM(Abortus), '') AS abortus_raw,

    NULLIF(TRIM(Tanggal_masuk_INC), '') AS tanggal_masuk_inc_raw,

    NULLIF(
      TRIM(Usia_Kehamilan_Gest_alinan_dalam_minggu),
      ''
    ) AS gestational_age_delivery_week_raw,

    NULLIF(
      TRIM(Usia_Kehamilan_Gesta_rsalinan_dalam_hari),
      ''
    ) AS gestational_age_delivery_day_raw,


    -- =====================================================
    -- DELIVERY
    -- =====================================================
    NULLIF(TRIM(Tempat_Melahirkan), '') AS delivery_place,
    NULLIF(TRIM(Alamat_Bersalin), '') AS delivery_address,

    NULLIF(
      TRIM(Tanggal_dan_Jam_Persalinan),
      ''
    ) AS delivery_datetime_raw,

    NULLIF(TRIM(Penolong_Persalinan_1), '') AS birth_attendant_1,
    NULLIF(TRIM(Nama_Penolong_Persalinan_1), '') AS birth_attendant_name_1,

    NULLIF(TRIM(Penolong_Persalinan_2), '') AS birth_attendant_2,
    NULLIF(TRIM(Nama_Penolong_Persalinan_2), '') AS birth_attendant_name_2,

    NULLIF(TRIM(Cara_Persalinan), '') AS delivery_method_raw,
    NULLIF(TRIM(Keadaan_ibu), '') AS mother_condition_raw,

    NULLIF(
      TRIM(Komplikasi_persalinan),
      ''
    ) AS delivery_complication_raw,

    NULLIF(TRIM(Luaran_kehamilan), '') AS pregnancy_outcome_raw,

    NULLIF(TRIM(Apakah_pasien_dirujuk), '') AS maternal_referral_raw,

    COALESCE(
      NULLIF(TRIM(Nama_fasilitas_kesehatan_rujukan), ''),
      NULLIF(TRIM(Fasilitas_kesehatan_tujuan_rujukan), '')
    ) AS maternal_referral_facility,

    NULLIF(TRIM(waktu_keguguran), '') AS abortion_datetime_raw,


    -- =====================================================
    -- BABY 1
    -- =====================================================
    NULLIF(TRIM(first_nameb1), '') AS baby1_name,
    NULLIF(TRIM(Jenis_Kelaminb1), '') AS baby1_sex_raw,

    NULLIF(TRIM(birth_dateb1), '') AS baby1_birth_date_raw,
    NULLIF(TRIM(Jam_lahirb1), '') AS baby1_birth_time,

    NULLIF(
      TRIM(Usia_Gestasi_Saat_Lahir_minggub1),
      ''
    ) AS baby1_ga_week_raw,

    NULLIF(
      TRIM(Usia_Gestasi_Saat_Lahir_hari),
      ''
    ) AS baby1_ga_day_raw,

    NULLIF(
      TRIM(Berat_badan_saat_lahir_gb1),
      ''
    ) AS baby1_birth_weight_raw,

    NULLIF(
      TRIM(Panjang_badan_saat_lahir_cmb1),
      ''
    ) AS baby1_birth_length_raw,

    NULLIF(
      TRIM(Lingkar_kepala_saat_lahir_cmb1),
      ''
    ) AS baby1_head_circumference_raw,

    NULLIF(
      TRIM(Kelainan_bawaan_bayib1),
      ''
    ) AS baby1_congenital_anomaly,

    NULLIF(
      TRIM(Apakah_pasien_dirujukb1),
      ''
    ) AS baby1_referral_raw,

    COALESCE(
      NULLIF(TRIM(Nama_Faskes_Rujukanb1), ''),
      NULLIF(TRIM(Fasilitas_kesehatan_tujuan_rujukanb1), '')
    ) AS baby1_referral_facility,


    -- =====================================================
    -- BABY 2
    -- =====================================================
    NULLIF(TRIM(first_nameb2), '') AS baby2_name,
    NULLIF(TRIM(Jenis_Kelaminb2), '') AS baby2_sex_raw,

    NULLIF(TRIM(birth_dateb2), '') AS baby2_birth_date_raw,
    NULLIF(TRIM(Jam_lahirb2), '') AS baby2_birth_time,

    NULLIF(
      TRIM(Usia_Gestasi_Saat_Lahir_minggub2),
      ''
    ) AS baby2_ga_week_raw,

    NULLIF(
      TRIM(Usia_Gestasi_Saat_Lahir_hari2),
      ''
    ) AS baby2_ga_day_raw,

    NULLIF(
      TRIM(Berat_badan_saat_lahir_gb2),
      ''
    ) AS baby2_birth_weight_raw,

    NULLIF(
      TRIM(Panjang_badan_saat_lahir_cmb2),
      ''
    ) AS baby2_birth_length_raw,

    NULLIF(
      TRIM(Lingkar_kepala_saat_lahir_cmb2),
      ''
    ) AS baby2_head_circumference_raw,

    NULLIF(
      TRIM(Kelainan_bawaan_bayib2),
      ''
    ) AS baby2_congenital_anomaly,

    NULLIF(
      TRIM(Apakah_pasien_dirujukb2),
      ''
    ) AS baby2_referral_raw,

    COALESCE(
      NULLIF(TRIM(Nama_Faskes_Rujukanb2), ''),
      NULLIF(TRIM(Fasilitas_kesehatan_tujuan_rujukanb2), '')
    ) AS baby2_referral_facility,


    -- =====================================================
    -- DEATH
    -- =====================================================
    NULLIF(
      TRIM(Waktu_meninggal_bayi),
      ''
    ) AS baby_death_datetime_raw,

    NULLIF(
      TRIM(Diagnosis_dugaan_sebab_kematian_bayi),
      ''
    ) AS suspected_cause_of_baby_death

  FROM source
),

parsed AS (
  SELECT
    *,

    -- =====================================================
    -- IDENTITY NORMALIZATION
    -- =====================================================
    NULLIF(
      REGEXP_REPLACE(
        COALESCE(mother_nik_raw, ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS mother_nik_digits,

    NULLIF(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          UPPER(TRIM(COALESCE(mother_name_raw, ''))),
          r'[^A-Z0-9 ]',
          ' '
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS mother_name_norm,

    NULLIF(
      REGEXP_REPLACE(
        UPPER(TRIM(COALESCE(facility_name_raw, ''))),
        r'\s+',
        ' '
      ),
      ''
    ) AS facility_name_norm,

    NULLIF(
      REGEXP_REPLACE(
        COALESCE(contact_number_raw, ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS contact_number_clean,


    -- =====================================================
    -- DATE PARSING
    -- =====================================================
    COALESCE(
      SAFE_CAST(
        SUBSTR(mother_birth_date_raw, 1, 10)
        AS DATE
      ),
      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        SUBSTR(mother_birth_date_raw, 1, 10)
      ),
      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        SUBSTR(mother_birth_date_raw, 1, 10)
      )
    ) AS mother_birth_date,

    COALESCE(
      SAFE_CAST(
        SUBSTR(hpht_raw, 1, 10)
        AS DATE
      ),
      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        SUBSTR(hpht_raw, 1, 10)
      ),
      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        SUBSTR(hpht_raw, 1, 10)
      )
    ) AS hpht_date,

    COALESCE(
      SAFE_CAST(
        SUBSTR(tanggal_masuk_inc_raw, 1, 10)
        AS DATE
      ),
      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        SUBSTR(tanggal_masuk_inc_raw, 1, 10)
      ),
      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        SUBSTR(tanggal_masuk_inc_raw, 1, 10)
      )
    ) AS tanggal_masuk_inc,

    COALESCE(
      SAFE_CAST(
        SUBSTR(delivery_datetime_raw, 1, 10)
        AS DATE
      ),
      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        SUBSTR(delivery_datetime_raw, 1, 10)
      ),
      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        SUBSTR(delivery_datetime_raw, 1, 10)
      )
    ) AS delivery_date,

    COALESCE(
      SAFE_CAST(
        SUBSTR(abortion_datetime_raw, 1, 10)
        AS DATE
      ),
      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        SUBSTR(abortion_datetime_raw, 1, 10)
      ),
      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        SUBSTR(abortion_datetime_raw, 1, 10)
      )
    ) AS abortion_date,

    COALESCE(
      SAFE_CAST(
        SUBSTR(baby1_birth_date_raw, 1, 10)
        AS DATE
      ),
      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        SUBSTR(baby1_birth_date_raw, 1, 10)
      ),
      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        SUBSTR(baby1_birth_date_raw, 1, 10)
      )
    ) AS baby1_birth_date,

    COALESCE(
      SAFE_CAST(
        SUBSTR(baby2_birth_date_raw, 1, 10)
        AS DATE
      ),
      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        SUBSTR(baby2_birth_date_raw, 1, 10)
      ),
      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        SUBSTR(baby2_birth_date_raw, 1, 10)
      )
    ) AS baby2_birth_date,


    -- =====================================================
    -- NUMERIC PARSING
    -- =====================================================
    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(mother_age_raw, r'-?\d+(?:[.,]\d+)?'),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS mother_age_numeric,

    SAFE_CAST(
      REGEXP_EXTRACT(gravida_raw, r'\d+')
      AS INT64
    ) AS gravida,

    SAFE_CAST(
      REGEXP_EXTRACT(partus_raw, r'\d+')
      AS INT64
    ) AS partus,

    SAFE_CAST(
      REGEXP_EXTRACT(abortus_raw, r'\d+')
      AS INT64
    ) AS abortus,

    SAFE_CAST(
      REGEXP_EXTRACT(
        gestational_age_delivery_week_raw,
        r'\d+'
      )
      AS INT64
    ) AS gestational_age_delivery_weeks,

    SAFE_CAST(
      REGEXP_EXTRACT(
        gestational_age_delivery_day_raw,
        r'\d+'
      )
      AS INT64
    ) AS gestational_age_delivery_days,

    SAFE_CAST(
      REGEXP_EXTRACT(
        baby1_ga_week_raw,
        r'\d+'
      )
      AS INT64
    ) AS baby1_ga_weeks,

    SAFE_CAST(
      REGEXP_EXTRACT(
        baby1_ga_day_raw,
        r'\d+'
      )
      AS INT64
    ) AS baby1_ga_days,

    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          baby1_birth_weight_raw,
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS baby1_birth_weight_numeric,

    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          baby1_birth_length_raw,
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS baby1_birth_length_numeric,

    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          baby1_head_circumference_raw,
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS baby1_head_circumference_numeric,

    SAFE_CAST(
      REGEXP_EXTRACT(
        baby2_ga_week_raw,
        r'\d+'
      )
      AS INT64
    ) AS baby2_ga_weeks,

    SAFE_CAST(
      REGEXP_EXTRACT(
        baby2_ga_day_raw,
        r'\d+'
      )
      AS INT64
    ) AS baby2_ga_days,

    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          baby2_birth_weight_raw,
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS baby2_birth_weight_numeric,

    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          baby2_birth_length_raw,
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS baby2_birth_length_numeric,

    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          baby2_head_circumference_raw,
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS baby2_head_circumference_numeric

  FROM raw_clean
),

normalized AS (
  SELECT
    *,

    CASE
      WHEN
        LENGTH(mother_nik_digits) = 16
        AND mother_nik_digits NOT IN (
          '0000000000000000',
          '9999999999999999'
        )
      THEN mother_nik_digits
    END AS mother_nik_clean,

    CASE
      WHEN
        LENGTH(mother_nik_digits) = 16
        AND mother_nik_digits NOT IN (
          '0000000000000000',
          '9999999999999999'
        )
      THEN TRUE
      ELSE FALSE
    END AS flag_nik_valid,

    CASE
      WHEN pregnancy_outcome_raw IS NULL
        THEN NULL

      WHEN REGEXP_CONTAINS(
        UPPER(
          REGEXP_REPLACE(
            pregnancy_outcome_raw,
            r'[_-]+',
            ' '
          )
        ),
        r'ABORT|KEGUG'
      )
        THEN 'ABORTUS'

      WHEN REGEXP_CONTAINS(
        UPPER(
          REGEXP_REPLACE(
            pregnancy_outcome_raw,
            r'[_-]+',
            ' '
          )
        ),
        r'LAHIR +MATI|STILLBIRTH|IUFD'
      )
        THEN 'LAHIR MATI'

      WHEN REGEXP_CONTAINS(
        UPPER(
          REGEXP_REPLACE(
            pregnancy_outcome_raw,
            r'[_-]+',
            ' '
          )
        ),
        r'LAHIR +HIDUP|LIVE +BIRTH'
      )
        THEN 'LAHIR HIDUP'

      ELSE UPPER(
        REGEXP_REPLACE(
          TRIM(pregnancy_outcome_raw),
          r'[_-]+',
          ' '
        )
      )
    END AS pregnancy_outcome_norm,

    NULLIF(
      UPPER(
        REGEXP_REPLACE(
          TRIM(COALESCE(delivery_method_raw, '')),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS delivery_method_norm,

    NULLIF(
      UPPER(
        REGEXP_REPLACE(
          TRIM(COALESCE(mother_condition_raw, '')),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS mother_condition_norm,

    CASE
      WHEN REGEXP_CONTAINS(
        UPPER(COALESCE(baby1_sex_raw, '')),
        r'PEREMPUAN|FEMALE'
      )
        THEN 'PEREMPUAN'

      WHEN REGEXP_CONTAINS(
        UPPER(COALESCE(baby1_sex_raw, '')),
        r'LAKI|MALE'
      )
        THEN 'LAKI-LAKI'

      ELSE NULLIF(
        UPPER(
          REGEXP_REPLACE(
            TRIM(COALESCE(baby1_sex_raw, '')),
            r'[_-]+',
            ' '
          )
        ),
        ''
      )
    END AS baby1_sex_norm,

    CASE
      WHEN REGEXP_CONTAINS(
        UPPER(COALESCE(baby2_sex_raw, '')),
        r'PEREMPUAN|FEMALE'
      )
        THEN 'PEREMPUAN'

      WHEN REGEXP_CONTAINS(
        UPPER(COALESCE(baby2_sex_raw, '')),
        r'LAKI|MALE'
      )
        THEN 'LAKI-LAKI'

      ELSE NULLIF(
        UPPER(
          REGEXP_REPLACE(
            TRIM(COALESCE(baby2_sex_raw, '')),
            r'[_-]+',
            ' '
          )
        ),
        ''
      )
    END AS baby2_sex_norm,

    CASE
      WHEN baby1_birth_weight_numeric BETWEEN 300 AND 7000
      THEN baby1_birth_weight_numeric
    END AS baby1_birth_weight_g,

    CASE
      WHEN baby1_birth_length_numeric BETWEEN 20 AND 70
      THEN baby1_birth_length_numeric
    END AS baby1_birth_length_cm,

    CASE
      WHEN baby1_head_circumference_numeric BETWEEN 20 AND 60
      THEN baby1_head_circumference_numeric
    END AS baby1_head_circumference_cm,

    CASE
      WHEN baby2_birth_weight_numeric BETWEEN 300 AND 7000
      THEN baby2_birth_weight_numeric
    END AS baby2_birth_weight_g,

    CASE
      WHEN baby2_birth_length_numeric BETWEEN 20 AND 70
      THEN baby2_birth_length_numeric
    END AS baby2_birth_length_cm,

    CASE
      WHEN baby2_head_circumference_numeric BETWEEN 20 AND 60
      THEN baby2_head_circumference_numeric
    END AS baby2_head_circumference_cm,

    COALESCE(
      case_id,
      CONCAT(
        'NO_CASE_ID|',
        submission_id
      )
    ) AS case_key

  FROM parsed
),

scored AS (
  SELECT
    *,

    (
      IF(mother_nik_clean IS NOT NULL, 10, 0)
      + IF(mother_name_norm IS NOT NULL, 5, 0)
      + IF(mother_birth_date IS NOT NULL, 3, 0)
      + IF(facility_name_norm IS NOT NULL, 3, 0)

      + IF(hpht_date IS NOT NULL, 3, 0)

      + IF(delivery_date IS NOT NULL, 10, 0)
      + IF(pregnancy_outcome_norm IS NOT NULL, 8, 0)
      + IF(delivery_method_norm IS NOT NULL, 5, 0)
      + IF(mother_condition_norm IS NOT NULL, 2, 0)

      + IF(baby1_birth_date IS NOT NULL, 5, 0)
      + IF(baby1_sex_norm IS NOT NULL, 3, 0)
      + IF(baby1_birth_weight_g IS NOT NULL, 8, 0)
      + IF(baby1_birth_length_cm IS NOT NULL, 3, 0)

      + IF(
          delivery_date IS NOT NULL
          AND baby1_birth_date IS NOT NULL
          AND delivery_date = baby1_birth_date,
          8,
          0
        )

      + IF(
          pregnancy_outcome_norm = 'ABORTUS'
          AND abortion_date IS NOT NULL,
          5,
          0
        )
    ) AS submission_quality_score

  FROM normalized
)

SELECT
  *
FROM scored;

CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.vs_kobo_inc_case_master` AS
WITH

-- =====================================================================
-- 1. KOBO SUBMISSION BASE
-- =====================================================================
kobo_base AS (
  SELECT
    s.*,

    -- Desa / kelurahan
    NULLIF(
      REGEXP_REPLACE(
        UPPER(TRIM(COALESCE(s.kelurahan, ''))),
        r'\s+',
        ' '
      ),
      ''
    ) AS desa_norm,

    -- Puskesmas
    NULLIF(
      REGEXP_REPLACE(
        UPPER(TRIM(COALESCE(s.puskesmas_raw, ''))),
        r'\s+',
        ' '
      ),
      ''
    ) AS puskesmas_norm,

    -- Address
    NULLIF(
      REGEXP_REPLACE(
        UPPER(TRIM(COALESCE(s.address_street, ''))),
        r'\s+',
        ' '
      ),
      ''
    ) AS alamat_norm,

    -- Kabupaten
    NULLIF(
      REGEXP_REPLACE(
        UPPER(TRIM(COALESCE(s.kabupaten, ''))),
        r'\s+',
        ' '
      ),
      ''
    ) AS kabupaten_norm,

    -- Kecamatan
    NULLIF(
      REGEXP_REPLACE(
        UPPER(TRIM(COALESCE(s.kecamatan, ''))),
        r'\s+',
        ' '
      ),
      ''
    ) AS kecamatan_norm

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_kobo_inc_submission_clean` s
),


-- =====================================================================
-- 2. RANK SUBMISSIONS
--
-- Preferred submission is NOT treated as truth.
-- It is only retained for manual verification / operational display.
-- =====================================================================
kobo_ranked AS (
  SELECT
    b.*,

    ROW_NUMBER() OVER (
      PARTITION BY case_key
      ORDER BY
        submission_quality_score DESC,
        submission_time DESC,
        submission_id DESC
    ) AS submission_rank

  FROM kobo_base b
),


-- =====================================================================
-- 3. PREFERRED KOBO SUBMISSION FOR MANUAL REVIEW
-- =====================================================================
kobo_preferred AS (
  SELECT
    case_key,

    submission_id AS preferred_submission_id,
    submission_time AS preferred_submission_time,
    submission_quality_score
      AS preferred_submission_quality_score,

    username AS preferred_username,

    data_entry_clerk_staff_id
      AS preferred_data_entry_clerk_staff_id,

    mother_name_raw
      AS preferred_nama,

    mother_nik_clean
      AS preferred_nik,

    mother_birth_date
      AS preferred_tanggal_lahir_ibu,

    desa_norm
      AS preferred_desa,

    puskesmas_norm
      AS preferred_puskesmas,

    facility_name_norm
      AS preferred_faskes,

    contact_number_clean
      AS preferred_no_hp,

    hpht_date
      AS preferred_hpht,

    delivery_date
      AS preferred_delivery_date,

    abortion_date
      AS preferred_abortion_date,

    pregnancy_outcome_norm
      AS preferred_luaran,

    mother_condition_norm
      AS preferred_keadaan_ibu,

    delivery_method_norm
      AS preferred_cara_persalinan,

    baby1_birth_date
      AS preferred_tanggal_lahir_bayi_1,

    baby1_sex_norm
      AS preferred_jenis_kelamin_bayi_1,

    baby1_birth_weight_g
      AS preferred_berat_badan_bayi_1_gram,

    baby1_birth_length_cm
      AS preferred_panjang_badan_bayi_1_cm,

    baby1_head_circumference_cm
      AS preferred_lingkar_kepala_bayi_1_cm

  FROM kobo_ranked

  WHERE submission_rank = 1
),


-- =====================================================================
-- 4. CASE METADATA
-- =====================================================================
kobo_case_meta AS (
  SELECT
    case_key,

    ANY_VALUE(case_id) AS case_id,

    COUNT(*) AS source_entry_count,

    STRING_AGG(
      submission_id,
      ' | '
      ORDER BY
        submission_time,
        submission_id
    ) AS source_submission_ids,

    MIN(submission_time)
      AS first_submission_time,

    MAX(submission_time)
      AS latest_submission_time

  FROM kobo_ranked

  GROUP BY case_key
),


-- =====================================================================
-- 5. IMPORTANT KOBO FIELDS -> LONG FORMAT
-- =====================================================================
kobo_field_long AS (
  SELECT
    r.case_key,
    r.case_id,
    r.submission_id,

    f.field_name,
    f.field_value

  FROM kobo_ranked r,

  UNNEST([

    -- -----------------------------------------------------------------
    -- MATERNAL IDENTITY
    -- -----------------------------------------------------------------
    STRUCT(
      'NIK' AS field_name,
      CAST(r.mother_nik_clean AS STRING) AS field_value
    ),

    STRUCT(
      'NAMA',
      CAST(r.mother_name_norm AS STRING)
    ),

    STRUCT(
      'TANGGAL_LAHIR_IBU',
      CAST(r.mother_birth_date AS STRING)
    ),

    STRUCT(
      'NO_HP',
      CAST(r.contact_number_clean AS STRING)
    ),


    -- -----------------------------------------------------------------
    -- LOCATION / FACILITY
    -- -----------------------------------------------------------------
    STRUCT(
      'DESA',
      CAST(r.desa_norm AS STRING)
    ),

    STRUCT(
      'PUSKESMAS',
      CAST(r.puskesmas_norm AS STRING)
    ),

    STRUCT(
      'FASKES',
      CAST(r.facility_name_norm AS STRING)
    ),

    STRUCT(
      'ALAMAT',
      CAST(r.alamat_norm AS STRING)
    ),

    STRUCT(
      'KABUPATEN',
      CAST(r.kabupaten_norm AS STRING)
    ),

    STRUCT(
      'KECAMATAN',
      CAST(r.kecamatan_norm AS STRING)
    ),


    -- -----------------------------------------------------------------
    -- PREGNANCY
    -- -----------------------------------------------------------------
    STRUCT(
      'HPHT',
      CAST(r.hpht_date AS STRING)
    ),

    STRUCT(
      'GRAVIDA',
      CAST(r.gravida AS STRING)
    ),

    STRUCT(
      'PARTUS',
      CAST(r.partus AS STRING)
    ),

    STRUCT(
      'ABORTUS',
      CAST(r.abortus AS STRING)
    ),

    STRUCT(
      'TANGGAL_MASUK_INC',
      CAST(r.tanggal_masuk_inc AS STRING)
    ),

    STRUCT(
      'USIA_KEHAMILAN_MINGGU',
      CAST(r.gestational_age_delivery_weeks AS STRING)
    ),

    STRUCT(
      'USIA_KEHAMILAN_HARI',
      CAST(r.gestational_age_delivery_days AS STRING)
    ),


    -- -----------------------------------------------------------------
    -- DELIVERY / PREGNANCY EPISODE
    -- -----------------------------------------------------------------
    STRUCT(
      'TANGGAL_PERSALINAN',
      CAST(r.delivery_date AS STRING)
    ),

    STRUCT(
      'TANGGAL_ABORTUS',
      CAST(r.abortion_date AS STRING)
    ),

    STRUCT(
      'TEMPAT_MELAHIRKAN',
      CAST(r.delivery_place AS STRING)
    ),

    STRUCT(
      'ALAMAT_BERSALIN',
      CAST(r.delivery_address AS STRING)
    ),

    STRUCT(
      'LUARAN',
      CAST(r.pregnancy_outcome_norm AS STRING)
    ),

    STRUCT(
      'KEADAAN_IBU',
      CAST(r.mother_condition_norm AS STRING)
    ),

    STRUCT(
      'CARA_PERSALINAN',
      CAST(r.delivery_method_norm AS STRING)
    ),

    STRUCT(
      'KOMPLIKASI_PERSALINAN',
      CAST(r.delivery_complication_raw AS STRING)
    ),

    STRUCT(
      'PENOLONG_PERSALINAN_1',
      CAST(r.birth_attendant_1 AS STRING)
    ),

    STRUCT(
      'NAMA_PENOLONG_PERSALINAN_1',
      CAST(r.birth_attendant_name_1 AS STRING)
    ),

    STRUCT(
      'DIRUJUK_IBU',
      CAST(r.maternal_referral_raw AS STRING)
    ),

    STRUCT(
      'FASILITAS_RUJUKAN_IBU',
      CAST(r.maternal_referral_facility AS STRING)
    ),


    -- -----------------------------------------------------------------
    -- BABY 1
    -- -----------------------------------------------------------------
    STRUCT(
      'TGL_LAHIR_BAYI_1',
      CAST(r.baby1_birth_date AS STRING)
    ),

    STRUCT(
      'JK_BAYI_1',
      CAST(r.baby1_sex_norm AS STRING)
    ),

    STRUCT(
      'BB_BAYI_1',
      CAST(r.baby1_birth_weight_g AS STRING)
    ),

    STRUCT(
      'PB_BAYI_1',
      CAST(r.baby1_birth_length_cm AS STRING)
    ),

    STRUCT(
      'LK_BAYI_1',
      CAST(r.baby1_head_circumference_cm AS STRING)
    ),

    STRUCT(
      'KELAINAN_BAWAAN_BAYI_1',
      CAST(r.baby1_congenital_anomaly AS STRING)
    ),

    STRUCT(
      'DIRUJUK_BAYI_1',
      CAST(r.baby1_referral_raw AS STRING)
    ),

    STRUCT(
      'FASILITAS_RUJUKAN_BAYI_1',
      CAST(r.baby1_referral_facility AS STRING)
    ),


    -- -----------------------------------------------------------------
    -- BABY 2
    -- -----------------------------------------------------------------
    STRUCT(
      'TGL_LAHIR_BAYI_2',
      CAST(r.baby2_birth_date AS STRING)
    ),

    STRUCT(
      'JK_BAYI_2',
      CAST(r.baby2_sex_norm AS STRING)
    ),

    STRUCT(
      'BB_BAYI_2',
      CAST(r.baby2_birth_weight_g AS STRING)
    ),

    STRUCT(
      'PB_BAYI_2',
      CAST(r.baby2_birth_length_cm AS STRING)
    ),

    STRUCT(
      'LK_BAYI_2',
      CAST(r.baby2_head_circumference_cm AS STRING)
    ),

    STRUCT(
      'KELAINAN_BAWAAN_BAYI_2',
      CAST(r.baby2_congenital_anomaly AS STRING)
    ),

    STRUCT(
      'DIRUJUK_BAYI_2',
      CAST(r.baby2_referral_raw AS STRING)
    ),

    STRUCT(
      'FASILITAS_RUJUKAN_BAYI_2',
      CAST(r.baby2_referral_facility AS STRING)
    )

  ]) f
),


-- =====================================================================
-- 6. FIELD PROFILE
-- =====================================================================
kobo_field_profile AS (
  SELECT
    case_key,
    field_name,

    COUNT(*) AS total_entry_count,

    COUNTIF(field_value IS NOT NULL)
      AS populated_entry_count,

    COUNT(DISTINCT field_value)
      AS distinct_nonnull_value_count

  FROM kobo_field_long

  GROUP BY
    case_key,
    field_name
),


-- =====================================================================
-- 7. COUNT EACH OBSERVED VALUE
-- =====================================================================
kobo_value_counts AS (
  SELECT
    case_key,
    field_name,
    field_value,

    COUNT(*) AS value_count

  FROM kobo_field_long

  WHERE field_value IS NOT NULL

  GROUP BY
    case_key,
    field_name,
    field_value
),


kobo_value_ranked AS (
  SELECT
    *,

    MAX(value_count) OVER (
      PARTITION BY
        case_key,
        field_name
    ) AS max_value_count

  FROM kobo_value_counts
),


-- =====================================================================
-- 8. TOP VALUE / MODE
-- =====================================================================
kobo_top_value AS (
  SELECT
    case_key,
    field_name,

    MAX(max_value_count)
      AS max_value_count,

    COUNTIF(
      value_count = max_value_count
    ) AS top_value_tie_count,

    ARRAY_AGG(
      IF(
        value_count = max_value_count,
        field_value,
        NULL
      )
      IGNORE NULLS
      ORDER BY field_value
      LIMIT 1
    )[SAFE_OFFSET(0)]
      AS top_field_value

  FROM kobo_value_ranked

  GROUP BY
    case_key,
    field_name
),


-- =====================================================================
-- 9. OBSERVED VALUES
-- =====================================================================
kobo_observed_values AS (
  SELECT
    case_key,
    field_name,

    STRING_AGG(
      CONCAT(
        field_value,
        ' [n=',
        CAST(value_count AS STRING),
        ']'
      ),
      ' | '
      ORDER BY
        value_count DESC,
        field_value
    ) AS observed_values

  FROM kobo_value_counts

  GROUP BY
    case_key,
    field_name
),


-- =====================================================================
-- 10. KOBO FIELD-LEVEL RECONCILIATION
-- =====================================================================
kobo_field_resolution AS (
  SELECT
    fp.case_key,
    fp.field_name,

    fp.total_entry_count,
    fp.populated_entry_count,
    fp.distinct_nonnull_value_count,

    COALESCE(tv.max_value_count, 0)
      AS max_value_count,

    COALESCE(tv.top_value_tie_count, 0)
      AS top_value_tie_count,

    ov.observed_values,


    -- -----------------------------------------------------------------
    -- RECONCILED VALUE
    -- -----------------------------------------------------------------
    CASE

      -- No value
      WHEN fp.populated_entry_count = 0
        THEN NULL


      -- Single entry
      WHEN fp.total_entry_count = 1
        THEN tv.top_field_value


      -- All populated values agree.
      --
      -- Also includes complementary:
      -- value + NULL.
      WHEN fp.distinct_nonnull_value_count = 1
        THEN tv.top_field_value


      -- Exactly 2 entries disagree
      WHEN fp.total_entry_count = 2
           AND fp.distinct_nonnull_value_count > 1
        THEN NULL


      -- >=3 entries: unique strict majority among populated entries
      WHEN fp.total_entry_count >= 3
           AND tv.top_value_tie_count = 1
           AND tv.max_value_count >
               (fp.populated_entry_count / 2.0)
        THEN tv.top_field_value


      -- Tie / no majority
      ELSE NULL

    END AS resolved_value,


    -- -----------------------------------------------------------------
    -- METHOD
    -- -----------------------------------------------------------------
    CASE

      WHEN fp.populated_entry_count = 0
        THEN 'NO_DATA'

      WHEN fp.total_entry_count = 1
        THEN 'SINGLE_ENTRY_DIRECT'

      WHEN fp.distinct_nonnull_value_count = 1
           AND fp.populated_entry_count =
               fp.total_entry_count
        THEN 'AGREED'

      WHEN fp.distinct_nonnull_value_count = 1
           AND fp.populated_entry_count <
               fp.total_entry_count
        THEN 'COMPLEMENTARY'

      WHEN fp.total_entry_count = 2
           AND fp.distinct_nonnull_value_count > 1
        THEN 'DOUBLE_ENTRY_CONFLICT_UNRESOLVED'

      WHEN fp.total_entry_count >= 3
           AND fp.distinct_nonnull_value_count > 1
           AND tv.top_value_tie_count = 1
           AND tv.max_value_count >
               (fp.populated_entry_count / 2.0)
        THEN 'MULTI_ENTRY_MAJORITY'

      ELSE
        'MULTI_ENTRY_NO_MAJORITY_UNRESOLVED'

    END AS resolution_method,


    -- -----------------------------------------------------------------
    -- QA FLAGS
    -- -----------------------------------------------------------------
    fp.distinct_nonnull_value_count > 1
      AS has_disagreement,


    (
      fp.distinct_nonnull_value_count = 1
      AND fp.populated_entry_count <
          fp.total_entry_count
    ) AS has_complementary_data,


    (
      fp.distinct_nonnull_value_count > 1

      AND (

        fp.total_entry_count = 2

        OR (

          fp.total_entry_count >= 3

          AND NOT (
            tv.top_value_tie_count = 1
            AND tv.max_value_count >
                (fp.populated_entry_count / 2.0)
          )

        )

      )

    ) AS is_unresolved

  FROM kobo_field_profile fp

  LEFT JOIN kobo_top_value tv
    USING (
      case_key,
      field_name
    )

  LEFT JOIN kobo_observed_values ov
    USING (
      case_key,
      field_name
    )
),


-- =====================================================================
-- 11. CASE RECONCILIATION SUMMARY
-- =====================================================================
kobo_reconciliation_summary AS (
  SELECT
    case_key,

    COUNTIF(has_disagreement)
      AS disagreement_field_count,

    COUNTIF(is_unresolved)
      AS unresolved_field_count,

    COUNTIF(has_complementary_data)
      AS complementary_field_count,

    STRING_AGG(
      IF(
        has_disagreement,
        field_name,
        NULL
      ),
      ', '
      ORDER BY field_name
    ) AS conflict_fields,

    STRING_AGG(
      IF(
        is_unresolved,
        field_name,
        NULL
      ),
      ', '
      ORDER BY field_name
    ) AS unresolved_fields,

    STRING_AGG(
      IF(
        has_complementary_data,
        field_name,
        NULL
      ),
      ', '
      ORDER BY field_name
    ) AS complementary_fields

  FROM kobo_field_resolution

  GROUP BY case_key
),


-- =====================================================================
-- 12. PIVOT RECONCILED KOBO VALUES
-- =====================================================================
kobo_pivot AS (
  SELECT
    case_key,


    -- -----------------------------------------------------------------
    -- IDENTITY
    -- -----------------------------------------------------------------
    MAX(
      IF(field_name = 'NIK', resolved_value, NULL)
    ) AS kobo_nik_clean,

    MAX(
      IF(field_name = 'NAMA', resolved_value, NULL)
    ) AS kobo_nama,

    SAFE_CAST(
      MAX(
        IF(
          field_name = 'TANGGAL_LAHIR_IBU',
          resolved_value,
          NULL
        )
      ) AS DATE
    ) AS kobo_tanggal_lahir_ibu,

    MAX(
      IF(field_name = 'NO_HP', resolved_value, NULL)
    ) AS kobo_no_hp,


    -- -----------------------------------------------------------------
    -- LOCATION
    -- -----------------------------------------------------------------
    MAX(
      IF(field_name = 'DESA', resolved_value, NULL)
    ) AS kobo_desa,

    MAX(
      IF(field_name = 'PUSKESMAS', resolved_value, NULL)
    ) AS kobo_puskesmas,

    MAX(
      IF(field_name = 'FASKES', resolved_value, NULL)
    ) AS kobo_faskes,

    MAX(
      IF(field_name = 'ALAMAT', resolved_value, NULL)
    ) AS kobo_alamat,

    MAX(
      IF(field_name = 'KABUPATEN', resolved_value, NULL)
    ) AS kobo_kabupaten,

    MAX(
      IF(field_name = 'KECAMATAN', resolved_value, NULL)
    ) AS kobo_kecamatan,


    -- -----------------------------------------------------------------
    -- PREGNANCY
    -- -----------------------------------------------------------------
    SAFE_CAST(
      MAX(
        IF(field_name = 'HPHT', resolved_value, NULL)
      ) AS DATE
    ) AS kobo_hpht_date,

    SAFE_CAST(
      MAX(
        IF(field_name = 'GRAVIDA', resolved_value, NULL)
      ) AS INT64
    ) AS kobo_gravida,

    SAFE_CAST(
      MAX(
        IF(field_name = 'PARTUS', resolved_value, NULL)
      ) AS INT64
    ) AS kobo_partus,

    SAFE_CAST(
      MAX(
        IF(field_name = 'ABORTUS', resolved_value, NULL)
      ) AS INT64
    ) AS kobo_abortus,

    SAFE_CAST(
      MAX(
        IF(
          field_name = 'TANGGAL_MASUK_INC',
          resolved_value,
          NULL
        )
      ) AS DATE
    ) AS kobo_tanggal_masuk_inc,

    SAFE_CAST(
      MAX(
        IF(
          field_name = 'USIA_KEHAMILAN_MINGGU',
          resolved_value,
          NULL
        )
      ) AS INT64
    ) AS kobo_usia_kehamilan_minggu,

    SAFE_CAST(
      MAX(
        IF(
          field_name = 'USIA_KEHAMILAN_HARI',
          resolved_value,
          NULL
        )
      ) AS INT64
    ) AS kobo_usia_kehamilan_hari,


    -- -----------------------------------------------------------------
    -- DELIVERY
    -- -----------------------------------------------------------------
    SAFE_CAST(
      MAX(
        IF(
          field_name = 'TANGGAL_PERSALINAN',
          resolved_value,
          NULL
        )
      ) AS DATE
    ) AS kobo_delivery_date,

    SAFE_CAST(
      MAX(
        IF(
          field_name = 'TANGGAL_ABORTUS',
          resolved_value,
          NULL
        )
      ) AS DATE
    ) AS kobo_abortion_date,

    MAX(
      IF(
        field_name = 'TEMPAT_MELAHIRKAN',
        resolved_value,
        NULL
      )
    ) AS kobo_tempat_melahirkan,

    MAX(
      IF(
        field_name = 'ALAMAT_BERSALIN',
        resolved_value,
        NULL
      )
    ) AS kobo_alamat_bersalin,

    MAX(
      IF(field_name = 'LUARAN', resolved_value, NULL)
    ) AS kobo_luaran_kehamilan,

    MAX(
      IF(
        field_name = 'KEADAAN_IBU',
        resolved_value,
        NULL
      )
    ) AS kobo_keadaan_ibu,

    MAX(
      IF(
        field_name = 'CARA_PERSALINAN',
        resolved_value,
        NULL
      )
    ) AS kobo_cara_persalinan,

    MAX(
      IF(
        field_name = 'KOMPLIKASI_PERSALINAN',
        resolved_value,
        NULL
      )
    ) AS kobo_komplikasi_persalinan,

    MAX(
      IF(
        field_name = 'PENOLONG_PERSALINAN_1',
        resolved_value,
        NULL
      )
    ) AS kobo_penolong_persalinan_1,

    MAX(
      IF(
        field_name = 'NAMA_PENOLONG_PERSALINAN_1',
        resolved_value,
        NULL
      )
    ) AS kobo_nama_penolong_persalinan_1,

    MAX(
      IF(
        field_name = 'DIRUJUK_IBU',
        resolved_value,
        NULL
      )
    ) AS kobo_dirujuk_ibu,

    MAX(
      IF(
        field_name = 'FASILITAS_RUJUKAN_IBU',
        resolved_value,
        NULL
      )
    ) AS kobo_fasilitas_rujukan_ibu,


    -- -----------------------------------------------------------------
    -- BABY 1
    -- -----------------------------------------------------------------
    SAFE_CAST(
      MAX(
        IF(
          field_name = 'TGL_LAHIR_BAYI_1',
          resolved_value,
          NULL
        )
      ) AS DATE
    ) AS kobo_tanggal_lahir_bayi_1,

    MAX(
      IF(
        field_name = 'JK_BAYI_1',
        resolved_value,
        NULL
      )
    ) AS kobo_jenis_kelamin_bayi_1,

    SAFE_CAST(
      MAX(
        IF(field_name = 'BB_BAYI_1', resolved_value, NULL)
      ) AS FLOAT64
    ) AS kobo_berat_badan_bayi_1_gram,

    SAFE_CAST(
      MAX(
        IF(field_name = 'PB_BAYI_1', resolved_value, NULL)
      ) AS FLOAT64
    ) AS kobo_panjang_badan_bayi_1_cm,

    SAFE_CAST(
      MAX(
        IF(field_name = 'LK_BAYI_1', resolved_value, NULL)
      ) AS FLOAT64
    ) AS kobo_lingkar_kepala_bayi_1_cm,

    MAX(
      IF(
        field_name = 'KELAINAN_BAWAAN_BAYI_1',
        resolved_value,
        NULL
      )
    ) AS kobo_kelainan_bawaan_bayi_1,

    MAX(
      IF(
        field_name = 'DIRUJUK_BAYI_1',
        resolved_value,
        NULL
      )
    ) AS kobo_dirujuk_bayi_1,

    MAX(
      IF(
        field_name = 'FASILITAS_RUJUKAN_BAYI_1',
        resolved_value,
        NULL
      )
    ) AS kobo_fasilitas_rujukan_bayi_1,


    -- -----------------------------------------------------------------
    -- BABY 2
    -- -----------------------------------------------------------------
    SAFE_CAST(
      MAX(
        IF(
          field_name = 'TGL_LAHIR_BAYI_2',
          resolved_value,
          NULL
        )
      ) AS DATE
    ) AS kobo_tanggal_lahir_bayi_2,

    MAX(
      IF(
        field_name = 'JK_BAYI_2',
        resolved_value,
        NULL
      )
    ) AS kobo_jenis_kelamin_bayi_2,

    SAFE_CAST(
      MAX(
        IF(field_name = 'BB_BAYI_2', resolved_value, NULL)
      ) AS FLOAT64
    ) AS kobo_berat_badan_bayi_2_gram,

    SAFE_CAST(
      MAX(
        IF(field_name = 'PB_BAYI_2', resolved_value, NULL)
      ) AS FLOAT64
    ) AS kobo_panjang_badan_bayi_2_cm,

    SAFE_CAST(
      MAX(
        IF(field_name = 'LK_BAYI_2', resolved_value, NULL)
      ) AS FLOAT64
    ) AS kobo_lingkar_kepala_bayi_2_cm,

    MAX(
      IF(
        field_name = 'KELAINAN_BAWAAN_BAYI_2',
        resolved_value,
        NULL
      )
    ) AS kobo_kelainan_bawaan_bayi_2,

    MAX(
      IF(
        field_name = 'DIRUJUK_BAYI_2',
        resolved_value,
        NULL
      )
    ) AS kobo_dirujuk_bayi_2,

    MAX(
      IF(
        field_name = 'FASILITAS_RUJUKAN_BAYI_2',
        resolved_value,
        NULL
      )
    ) AS kobo_fasilitas_rujukan_bayi_2,


    -- =================================================================
    -- KOBO CONFLICT FLAGS
    -- =================================================================

    COUNTIF(
      field_name = 'NIK'
      AND has_disagreement
    ) > 0 AS kobo_conflict_nik,

    COUNTIF(
      field_name = 'NIK'
      AND is_unresolved
    ) > 0 AS kobo_unresolved_nik,


    COUNTIF(
      field_name = 'NAMA'
      AND has_disagreement
    ) > 0 AS kobo_conflict_nama,

    COUNTIF(
      field_name = 'NAMA'
      AND is_unresolved
    ) > 0 AS kobo_unresolved_nama,


    COUNTIF(
      field_name = 'TANGGAL_LAHIR_IBU'
      AND has_disagreement
    ) > 0 AS kobo_conflict_tanggal_lahir_ibu,

    COUNTIF(
      field_name = 'TANGGAL_LAHIR_IBU'
      AND is_unresolved
    ) > 0 AS kobo_unresolved_tanggal_lahir_ibu,


    COUNTIF(
      field_name = 'DESA'
      AND has_disagreement
    ) > 0 AS kobo_conflict_desa,

    COUNTIF(
      field_name = 'DESA'
      AND is_unresolved
    ) > 0 AS kobo_unresolved_desa,


    COUNTIF(
      field_name = 'PUSKESMAS'
      AND has_disagreement
    ) > 0 AS kobo_conflict_puskesmas,

    COUNTIF(
      field_name = 'PUSKESMAS'
      AND is_unresolved
    ) > 0 AS kobo_unresolved_puskesmas,


    COUNTIF(
      field_name = 'FASKES'
      AND has_disagreement
    ) > 0 AS kobo_conflict_faskes,

    COUNTIF(
      field_name = 'FASKES'
      AND is_unresolved
    ) > 0 AS kobo_unresolved_faskes,


    COUNTIF(
      field_name = 'HPHT'
      AND has_disagreement
    ) > 0 AS kobo_conflict_hpht,

    COUNTIF(
      field_name = 'HPHT'
      AND is_unresolved
    ) > 0 AS kobo_unresolved_hpht,


    COUNTIF(
      field_name = 'TANGGAL_PERSALINAN'
      AND has_disagreement
    ) > 0 AS kobo_conflict_delivery_date,

    COUNTIF(
      field_name = 'TANGGAL_PERSALINAN'
      AND is_unresolved
    ) > 0 AS kobo_unresolved_delivery_date,


    COUNTIF(
      field_name = 'TANGGAL_ABORTUS'
      AND has_disagreement
    ) > 0 AS kobo_conflict_abortion_date,

    COUNTIF(
      field_name = 'TANGGAL_ABORTUS'
      AND is_unresolved
    ) > 0 AS kobo_unresolved_abortion_date,


    COUNTIF(
      field_name = 'LUARAN'
      AND has_disagreement
    ) > 0 AS kobo_conflict_luaran,

    COUNTIF(
      field_name = 'LUARAN'
      AND is_unresolved
    ) > 0 AS kobo_unresolved_luaran,


    COUNTIF(
      field_name = 'KEADAAN_IBU'
      AND has_disagreement
    ) > 0 AS kobo_conflict_keadaan_ibu,

    COUNTIF(
      field_name = 'KEADAAN_IBU'
      AND is_unresolved
    ) > 0 AS kobo_unresolved_keadaan_ibu,


    COUNTIF(
      field_name = 'CARA_PERSALINAN'
      AND has_disagreement
    ) > 0 AS kobo_conflict_cara_persalinan,

    COUNTIF(
      field_name = 'CARA_PERSALINAN'
      AND is_unresolved
    ) > 0 AS kobo_unresolved_cara_persalinan,


    COUNTIF(
      field_name = 'TGL_LAHIR_BAYI_1'
      AND has_disagreement
    ) > 0 AS kobo_conflict_baby1_birth_date,

    COUNTIF(
      field_name = 'TGL_LAHIR_BAYI_1'
      AND is_unresolved
    ) > 0 AS kobo_unresolved_baby1_birth_date,


    COUNTIF(
      field_name = 'JK_BAYI_1'
      AND has_disagreement
    ) > 0 AS kobo_conflict_baby1_sex,

    COUNTIF(
      field_name = 'JK_BAYI_1'
      AND is_unresolved
    ) > 0 AS kobo_unresolved_baby1_sex,


    COUNTIF(
      field_name = 'BB_BAYI_1'
      AND has_disagreement
    ) > 0 AS kobo_conflict_baby1_birth_weight,

    COUNTIF(
      field_name = 'BB_BAYI_1'
      AND is_unresolved
    ) > 0 AS kobo_unresolved_baby1_birth_weight,


    COUNTIF(
      field_name = 'PB_BAYI_1'
      AND has_disagreement
    ) > 0 AS kobo_conflict_baby1_birth_length,

    COUNTIF(
      field_name = 'PB_BAYI_1'
      AND is_unresolved
    ) > 0 AS kobo_unresolved_baby1_birth_length,


    -- =================================================================
    -- OBSERVED VALUES
    -- =================================================================
    MAX(
      IF(field_name = 'NIK', observed_values, NULL)
    ) AS nik_observed_values,

    MAX(
      IF(field_name = 'NAMA', observed_values, NULL)
    ) AS nama_observed_values,

    MAX(
      IF(
        field_name = 'TANGGAL_LAHIR_IBU',
        observed_values,
        NULL
      )
    ) AS tanggal_lahir_ibu_observed_values,

    MAX(
      IF(field_name = 'DESA', observed_values, NULL)
    ) AS desa_observed_values,

    MAX(
      IF(field_name = 'PUSKESMAS', observed_values, NULL)
    ) AS puskesmas_observed_values,

    MAX(
      IF(field_name = 'FASKES', observed_values, NULL)
    ) AS faskes_observed_values,

    MAX(
      IF(field_name = 'HPHT', observed_values, NULL)
    ) AS hpht_observed_values,

    MAX(
      IF(
        field_name = 'TANGGAL_PERSALINAN',
        observed_values,
        NULL
      )
    ) AS delivery_date_observed_values,

    MAX(
      IF(
        field_name = 'TANGGAL_ABORTUS',
        observed_values,
        NULL
      )
    ) AS abortion_date_observed_values,

    MAX(
      IF(field_name = 'LUARAN', observed_values, NULL)
    ) AS luaran_observed_values,

    MAX(
      IF(
        field_name = 'KEADAAN_IBU',
        observed_values,
        NULL
      )
    ) AS keadaan_ibu_observed_values,

    MAX(
      IF(
        field_name = 'CARA_PERSALINAN',
        observed_values,
        NULL
      )
    ) AS cara_persalinan_observed_values,

    MAX(
      IF(
        field_name = 'TGL_LAHIR_BAYI_1',
        observed_values,
        NULL
      )
    ) AS baby1_birth_date_observed_values,

    MAX(
      IF(
        field_name = 'JK_BAYI_1',
        observed_values,
        NULL
      )
    ) AS baby1_sex_observed_values,

    MAX(
      IF(
        field_name = 'BB_BAYI_1',
        observed_values,
        NULL
      )
    ) AS baby1_birth_weight_observed_values,

    MAX(
      IF(
        field_name = 'PB_BAYI_1',
        observed_values,
        NULL
      )
    ) AS baby1_birth_length_observed_values,


    -- =================================================================
    -- IMPORTANT FIELD RESOLUTION METHODS
    -- =================================================================
    MAX(
      IF(field_name = 'NIK', resolution_method, NULL)
    ) AS nik_reconciliation_method,

    MAX(
      IF(field_name = 'NAMA', resolution_method, NULL)
    ) AS nama_reconciliation_method,

    MAX(
      IF(
        field_name = 'TANGGAL_LAHIR_IBU',
        resolution_method,
        NULL
      )
    ) AS tanggal_lahir_ibu_reconciliation_method,

    MAX(
      IF(field_name = 'DESA', resolution_method, NULL)
    ) AS desa_reconciliation_method,

    MAX(
      IF(field_name = 'PUSKESMAS', resolution_method, NULL)
    ) AS puskesmas_reconciliation_method,

    MAX(
      IF(field_name = 'FASKES', resolution_method, NULL)
    ) AS faskes_reconciliation_method,

    MAX(
      IF(field_name = 'HPHT', resolution_method, NULL)
    ) AS hpht_reconciliation_method,

    MAX(
      IF(
        field_name = 'TANGGAL_PERSALINAN',
        resolution_method,
        NULL
      )
    ) AS delivery_date_reconciliation_method,

    MAX(
      IF(field_name = 'LUARAN', resolution_method, NULL)
    ) AS luaran_reconciliation_method,

    MAX(
      IF(
        field_name = 'KEADAAN_IBU',
        resolution_method,
        NULL
      )
    ) AS keadaan_ibu_reconciliation_method,

    MAX(
      IF(
        field_name = 'CARA_PERSALINAN',
        resolution_method,
        NULL
      )
    ) AS cara_persalinan_reconciliation_method,

    MAX(
      IF(
        field_name = 'BB_BAYI_1',
        resolution_method,
        NULL
      )
    ) AS baby1_birth_weight_reconciliation_method

  FROM kobo_field_resolution

  GROUP BY case_key
),


-- =====================================================================
-- 13. KOBO DOMAIN FLAGS
-- =====================================================================
kobo_domain_flags AS (
  SELECT
    p.*,

    -- -----------------------------------------------------------------
    -- Any historical disagreement
    -- -----------------------------------------------------------------
    (
      kobo_conflict_nik
      OR kobo_conflict_nama
      OR kobo_conflict_tanggal_lahir_ibu
    ) AS kobo_has_identity_conflict,


    (
      kobo_conflict_desa
      OR kobo_conflict_puskesmas
      OR kobo_conflict_faskes
    ) AS kobo_has_location_conflict,


    (
      kobo_conflict_hpht
      OR kobo_conflict_delivery_date
      OR kobo_conflict_abortion_date
      OR kobo_conflict_baby1_birth_date
    ) AS kobo_has_pregnancy_episode_conflict,


    (
      kobo_conflict_luaran
      OR kobo_conflict_keadaan_ibu
      OR kobo_conflict_cara_persalinan
      OR kobo_conflict_baby1_sex
      OR kobo_conflict_baby1_birth_weight
      OR kobo_conflict_baby1_birth_length
    ) AS kobo_has_clinical_outcome_conflict,


    -- -----------------------------------------------------------------
    -- Unresolved conflict
    -- -----------------------------------------------------------------
    (
      kobo_unresolved_nik
      OR kobo_unresolved_nama
      OR kobo_unresolved_tanggal_lahir_ibu
    ) AS kobo_has_unresolved_identity_conflict,


    (
      kobo_unresolved_desa
      OR kobo_unresolved_puskesmas
      OR kobo_unresolved_faskes
    ) AS kobo_has_unresolved_location_conflict,


    (
      kobo_unresolved_hpht
      OR kobo_unresolved_delivery_date
      OR kobo_unresolved_abortion_date
      OR kobo_unresolved_baby1_birth_date
    ) AS kobo_has_unresolved_pregnancy_episode_conflict,


    (
      kobo_unresolved_luaran
      OR kobo_unresolved_keadaan_ibu
      OR kobo_unresolved_cara_persalinan
      OR kobo_unresolved_baby1_sex
      OR kobo_unresolved_baby1_birth_weight
      OR kobo_unresolved_baby1_birth_length
    ) AS kobo_has_unresolved_clinical_outcome_conflict

  FROM kobo_pivot p
),


-- =====================================================================
-- 14. KOBO MATCHING FLAGS
-- =====================================================================
kobo_matching_flags AS (
  SELECT
    k.*,


    -- -----------------------------------------------------------------
    -- Identity availability
    --
    -- Strong:
    --    NIK
    --
    -- Fallback:
    --    name + DOB + location/facility
    -- -----------------------------------------------------------------
    (
      kobo_nik_clean IS NOT NULL

      OR (

        kobo_nama IS NOT NULL

        AND kobo_tanggal_lahir_ibu IS NOT NULL

        AND (
          kobo_desa IS NOT NULL
          OR kobo_puskesmas IS NOT NULL
          OR kobo_faskes IS NOT NULL
        )

      )
    ) AS kobo_has_sufficient_identity_for_matching,


    -- -----------------------------------------------------------------
    -- Pregnancy episode anchor
    -- -----------------------------------------------------------------
    (
      kobo_hpht_date IS NOT NULL
      OR kobo_delivery_date IS NOT NULL
      OR kobo_abortion_date IS NOT NULL
      OR kobo_tanggal_lahir_bayi_1 IS NOT NULL
    ) AS kobo_has_pregnancy_anchor,


    -- -----------------------------------------------------------------
    -- Identity blocking conflict
    -- -----------------------------------------------------------------
    (
      kobo_unresolved_nik

      OR kobo_unresolved_tanggal_lahir_ibu

      OR (
        kobo_nik_clean IS NULL
        AND kobo_unresolved_nama
      )

    ) AS kobo_has_identity_blocking_conflict,


    -- -----------------------------------------------------------------
    -- Location blocking conflict
    --
    -- Location alone does not block strong NIK matching.
    -- -----------------------------------------------------------------
    (
      kobo_nik_clean IS NULL

      AND (
        kobo_unresolved_desa
        OR kobo_unresolved_puskesmas
        OR kobo_unresolved_faskes
      )

      AND kobo_desa IS NULL
      AND kobo_puskesmas IS NULL
      AND kobo_faskes IS NULL

    ) AS kobo_has_location_blocking_conflict,


    -- -----------------------------------------------------------------
    -- Episode blocking conflict
    -- -----------------------------------------------------------------
    (
      kobo_unresolved_delivery_date

      OR kobo_unresolved_abortion_date

      OR (
        kobo_unresolved_hpht
        AND kobo_delivery_date IS NULL
        AND kobo_abortion_date IS NULL
        AND kobo_tanggal_lahir_bayi_1 IS NULL
      )

      OR (
        kobo_unresolved_baby1_birth_date
        AND kobo_delivery_date IS NULL
        AND kobo_abortion_date IS NULL
        AND kobo_hpht_date IS NULL
      )

    ) AS kobo_has_episode_blocking_conflict

  FROM kobo_domain_flags k
),


-- =====================================================================
-- 15. KOBO CASE-LEVEL STATUS
-- =====================================================================
kobo_case AS (
  SELECT
    k.*,

    m.case_id,
    m.source_entry_count,
    m.source_submission_ids,
    m.first_submission_time,
    m.latest_submission_time,

    s.disagreement_field_count,
    s.unresolved_field_count,
    s.complementary_field_count,

    s.conflict_fields,
    s.unresolved_fields,
    s.complementary_fields,


    CASE

      WHEN m.source_entry_count = 1
        THEN 'SINGLE_ENTRY_DIRECT'

      WHEN m.source_entry_count = 2
           AND s.unresolved_field_count > 0
        THEN 'DOUBLE_ENTRY_CONFLICT_MANUAL_REVIEW'

      WHEN m.source_entry_count = 2
           AND s.complementary_field_count > 0
           AND s.unresolved_field_count = 0
        THEN 'DOUBLE_ENTRY_COMPLEMENTARY'

      WHEN m.source_entry_count = 2
           AND s.disagreement_field_count = 0
           AND s.unresolved_field_count = 0
        THEN 'DOUBLE_ENTRY_AGREED'

      WHEN m.source_entry_count >= 3
           AND s.unresolved_field_count > 0
        THEN 'MULTI_ENTRY_NO_MAJORITY_MANUAL_REVIEW'

      WHEN m.source_entry_count >= 3
           AND s.disagreement_field_count > 0
           AND s.unresolved_field_count = 0
        THEN 'MULTI_ENTRY_MAJORITY'

      WHEN m.source_entry_count >= 3
           AND s.complementary_field_count > 0
           AND s.unresolved_field_count = 0
        THEN 'MULTI_ENTRY_COMPLEMENTARY'

      WHEN m.source_entry_count >= 3
        THEN 'MULTI_ENTRY_AGREED'

      ELSE 'UNKNOWN'

    END AS kobo_reconciliation_status,


    (
      kobo_has_sufficient_identity_for_matching

      AND kobo_has_pregnancy_anchor

      AND NOT kobo_has_identity_blocking_conflict

      AND NOT kobo_has_location_blocking_conflict

      AND NOT kobo_has_episode_blocking_conflict
    ) AS kobo_eligible_for_matching

  FROM kobo_matching_flags k

  JOIN kobo_case_meta m
    USING (case_key)

  JOIN kobo_reconciliation_summary s
    USING (case_key)
),


-- =====================================================================
-- 16. RAW ADJUDICATION
-- =====================================================================
adj_raw AS (
  SELECT
    a.*,

    NULLIF(TRIM(case_id), '')
      AS adj_case_id,

    COALESCE(
      NULLIF(TRIM(`_uuid`), ''),
      NULLIF(TRIM(`_id`), '')
    ) AS adjudication_record_id,

    SAFE_CAST(
      NULLIF(TRIM(`_submission_time`), '')
      AS TIMESTAMP
    ) AS adjudication_submission_time

  FROM
    `spheres-lombok-barat.data_adjudication.adj_final` a

  WHERE NULLIF(TRIM(case_id), '') IS NOT NULL
),


-- =====================================================================
-- 17. NORMALIZE ADJUDICATION
-- =====================================================================
adj_normalized AS (
  SELECT
    adj_case_id AS adjudication_case_id,

    adjudication_record_id,
    adjudication_submission_time,


    -- -----------------------------------------------------------------
    -- IDENTITY
    -- -----------------------------------------------------------------
    CASE
      WHEN LENGTH(
        NULLIF(
          REGEXP_REPLACE(
            COALESCE(nik_mother, ''),
            r'[^0-9]',
            ''
          ),
          ''
        )
      ) = 16

      AND NULLIF(
        REGEXP_REPLACE(
          COALESCE(nik_mother, ''),
          r'[^0-9]',
          ''
        ),
        ''
      ) NOT IN (
        '0000000000000000',
        '9999999999999999'
      )

      THEN NULLIF(
        REGEXP_REPLACE(
          COALESCE(nik_mother, ''),
          r'[^0-9]',
          ''
        ),
        ''
      )
    END AS adj_nik_clean,


    NULLIF(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          UPPER(
            TRIM(
              COALESCE(first_name, '')
            )
          ),
          r'[^A-Z0-9 ]',
          ' '
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS adj_nama,


    COALESCE(
      SAFE_CAST(
        SUBSTR(
          NULLIF(TRIM(birth_date), ''),
          1,
          10
        ) AS DATE
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        SUBSTR(
          NULLIF(TRIM(birth_date), ''),
          1,
          10
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        SUBSTR(
          NULLIF(TRIM(birth_date), ''),
          1,
          10
        )
      )
    ) AS adj_tanggal_lahir_ibu,


    NULLIF(
      REGEXP_REPLACE(
        COALESCE(contact_number, ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS adj_no_hp,


    -- -----------------------------------------------------------------
    -- LOCATION
    -- -----------------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        UPPER(TRIM(COALESCE(Kelurahan, ''))),
        r'\s+',
        ' '
      ),
      ''
    ) AS adj_desa,


    NULLIF(
      REGEXP_REPLACE(
        UPPER(
          TRIM(
            COALESCE(
              Pilih_Nama_Puskesmas,
              ''
            )
          )
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS adj_puskesmas,


    NULLIF(
      REGEXP_REPLACE(
        UPPER(
          TRIM(
            COALESCE(
              NULLIF(TRIM(Pilih_Nama_Puskesmas), ''),
              NULLIF(TRIM(Tuliskan_nama_Rumah_Sakit), ''),
              NULLIF(TRIM(Tuliskan_nama_Praktik_Mandiri_Bidan_PMB), ''),
              NULLIF(TRIM(Tuliskan_nama_Klinik), ''),
              ''
            )
          )
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS adj_faskes,


    NULLIF(
      REGEXP_REPLACE(
        UPPER(TRIM(COALESCE(address_street, ''))),
        r'\s+',
        ' '
      ),
      ''
    ) AS adj_alamat,


    NULLIF(
      REGEXP_REPLACE(
        UPPER(TRIM(COALESCE(Kabupaten, ''))),
        r'\s+',
        ' '
      ),
      ''
    ) AS adj_kabupaten,


    NULLIF(
      REGEXP_REPLACE(
        UPPER(TRIM(COALESCE(Kecamatan, ''))),
        r'\s+',
        ' '
      ),
      ''
    ) AS adj_kecamatan,


    -- -----------------------------------------------------------------
    -- PREGNANCY
    -- -----------------------------------------------------------------
    COALESCE(
      SAFE_CAST(
        SUBSTR(NULLIF(TRIM(HPHT), ''), 1, 10)
        AS DATE
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        SUBSTR(NULLIF(TRIM(HPHT), ''), 1, 10)
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        SUBSTR(NULLIF(TRIM(HPHT), ''), 1, 10)
      )
    ) AS adj_hpht_date,


    SAFE_CAST(
      REGEXP_EXTRACT(
        NULLIF(TRIM(Gravida), ''),
        r'\d+'
      )
      AS INT64
    ) AS adj_gravida,


    SAFE_CAST(
      REGEXP_EXTRACT(
        NULLIF(TRIM(Partus), ''),
        r'\d+'
      )
      AS INT64
    ) AS adj_partus,


    SAFE_CAST(
      REGEXP_EXTRACT(
        NULLIF(TRIM(Abortus), ''),
        r'\d+'
      )
      AS INT64
    ) AS adj_abortus,


    COALESCE(
      SAFE_CAST(
        SUBSTR(
          NULLIF(TRIM(Tanggal_masuk_INC), ''),
          1,
          10
        ) AS DATE
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        SUBSTR(
          NULLIF(TRIM(Tanggal_masuk_INC), ''),
          1,
          10
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        SUBSTR(
          NULLIF(TRIM(Tanggal_masuk_INC), ''),
          1,
          10
        )
      )
    ) AS adj_tanggal_masuk_inc,


    SAFE_CAST(
      REGEXP_EXTRACT(
        NULLIF(
          TRIM(
            Usia_Kehamilan_Gest_alinan_dalam_minggu
          ),
          ''
        ),
        r'\d+'
      )
      AS INT64
    ) AS adj_usia_kehamilan_minggu,


    SAFE_CAST(
      REGEXP_EXTRACT(
        NULLIF(
          TRIM(
            Usia_Kehamilan_Gesta_rsalinan_dalam_hari
          ),
          ''
        ),
        r'\d+'
      )
      AS INT64
    ) AS adj_usia_kehamilan_hari,


    -- -----------------------------------------------------------------
    -- DELIVERY
    -- -----------------------------------------------------------------
    COALESCE(
      SAFE_CAST(
        SUBSTR(
          NULLIF(
            TRIM(Tanggal_dan_Jam_Persalinan),
            ''
          ),
          1,
          10
        ) AS DATE
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        SUBSTR(
          NULLIF(
            TRIM(Tanggal_dan_Jam_Persalinan),
            ''
          ),
          1,
          10
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        SUBSTR(
          NULLIF(
            TRIM(Tanggal_dan_Jam_Persalinan),
            ''
          ),
          1,
          10
        )
      )
    ) AS adj_delivery_date,


    COALESCE(
      SAFE_CAST(
        SUBSTR(
          NULLIF(TRIM(waktu_keguguran), ''),
          1,
          10
        ) AS DATE
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        SUBSTR(
          NULLIF(TRIM(waktu_keguguran), ''),
          1,
          10
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        SUBSTR(
          NULLIF(TRIM(waktu_keguguran), ''),
          1,
          10
        )
      )
    ) AS adj_abortion_date,


    NULLIF(
      TRIM(Tempat_Melahirkan),
      ''
    ) AS adj_tempat_melahirkan,


    NULLIF(
      TRIM(Alamat_Bersalin),
      ''
    ) AS adj_alamat_bersalin,


    -- -----------------------------------------------------------------
    -- LUARAN
    -- -----------------------------------------------------------------
    CASE

      WHEN NULLIF(TRIM(Luaran_kehamilan), '') IS NULL
        THEN NULL

      WHEN REGEXP_CONTAINS(
        UPPER(
          REGEXP_REPLACE(
            TRIM(Luaran_kehamilan),
            r'[_-]+',
            ' '
          )
        ),
        r'ABORT|KEGUG'
      )
        THEN 'ABORTUS'

      WHEN REGEXP_CONTAINS(
        UPPER(
          REGEXP_REPLACE(
            TRIM(Luaran_kehamilan),
            r'[_-]+',
            ' '
          )
        ),
        r'LAHIR +MATI|STILLBIRTH|IUFD'
      )
        THEN 'LAHIR MATI'

      WHEN REGEXP_CONTAINS(
        UPPER(
          REGEXP_REPLACE(
            TRIM(Luaran_kehamilan),
            r'[_-]+',
            ' '
          )
        ),
        r'LAHIR +HIDUP|LIVE +BIRTH'
      )
        THEN 'LAHIR HIDUP'

      ELSE
        UPPER(
          REGEXP_REPLACE(
            TRIM(Luaran_kehamilan),
            r'[_-]+',
            ' '
          )
        )

    END AS adj_luaran_kehamilan,


    NULLIF(
      UPPER(
        REGEXP_REPLACE(
          TRIM(COALESCE(Keadaan_ibu, '')),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS adj_keadaan_ibu,


    NULLIF(
      UPPER(
        REGEXP_REPLACE(
          TRIM(COALESCE(Cara_Persalinan, '')),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS adj_cara_persalinan,


    NULLIF(
      TRIM(Komplikasi_persalinan),
      ''
    ) AS adj_komplikasi_persalinan,


    NULLIF(
      TRIM(Penolong_Persalinan_1),
      ''
    ) AS adj_penolong_persalinan_1,


    NULLIF(
      TRIM(Nama_Penolong_Persalinan_1),
      ''
    ) AS adj_nama_penolong_persalinan_1,


    NULLIF(
      TRIM(Apakah_pasien_dirujuk),
      ''
    ) AS adj_dirujuk_ibu,


    COALESCE(
      NULLIF(
        TRIM(Nama_fasilitas_kesehatan_rujukan),
        ''
      ),
      NULLIF(
        TRIM(Fasilitas_kesehatan_tujuan_rujukan),
        ''
      )
    ) AS adj_fasilitas_rujukan_ibu,


    -- -----------------------------------------------------------------
    -- BABY 1
    -- -----------------------------------------------------------------
    COALESCE(
      SAFE_CAST(
        SUBSTR(
          NULLIF(TRIM(birth_dateb1), ''),
          1,
          10
        ) AS DATE
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        SUBSTR(
          NULLIF(TRIM(birth_dateb1), ''),
          1,
          10
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        SUBSTR(
          NULLIF(TRIM(birth_dateb1), ''),
          1,
          10
        )
      )
    ) AS adj_tanggal_lahir_bayi_1,


    CASE
      WHEN REGEXP_CONTAINS(
        UPPER(COALESCE(Jenis_Kelaminb1, '')),
        r'PEREMPUAN|FEMALE'
      )
        THEN 'PEREMPUAN'

      WHEN REGEXP_CONTAINS(
        UPPER(COALESCE(Jenis_Kelaminb1, '')),
        r'LAKI|MALE'
      )
        THEN 'LAKI-LAKI'

      ELSE NULLIF(
        UPPER(
          REGEXP_REPLACE(
            TRIM(COALESCE(Jenis_Kelaminb1, '')),
            r'[_-]+',
            ' '
          )
        ),
        ''
      )
    END AS adj_jenis_kelamin_bayi_1,


    CASE
      WHEN SAFE_CAST(
        REPLACE(
          REGEXP_EXTRACT(
            NULLIF(
              TRIM(Berat_badan_saat_lahir_gb1),
              ''
            ),
            r'-?\d+(?:[.,]\d+)?'
          ),
          ',',
          '.'
        )
        AS FLOAT64
      ) BETWEEN 300 AND 7000

      THEN SAFE_CAST(
        REPLACE(
          REGEXP_EXTRACT(
            NULLIF(
              TRIM(Berat_badan_saat_lahir_gb1),
              ''
            ),
            r'-?\d+(?:[.,]\d+)?'
          ),
          ',',
          '.'
        )
        AS FLOAT64
      )
    END AS adj_berat_badan_bayi_1_gram,


    CASE
      WHEN SAFE_CAST(
        REPLACE(
          REGEXP_EXTRACT(
            NULLIF(
              TRIM(Panjang_badan_saat_lahir_cmb1),
              ''
            ),
            r'-?\d+(?:[.,]\d+)?'
          ),
          ',',
          '.'
        )
        AS FLOAT64
      ) BETWEEN 20 AND 70

      THEN SAFE_CAST(
        REPLACE(
          REGEXP_EXTRACT(
            NULLIF(
              TRIM(Panjang_badan_saat_lahir_cmb1),
              ''
            ),
            r'-?\d+(?:[.,]\d+)?'
          ),
          ',',
          '.'
        )
        AS FLOAT64
      )
    END AS adj_panjang_badan_bayi_1_cm,


    CASE
      WHEN SAFE_CAST(
        REPLACE(
          REGEXP_EXTRACT(
            NULLIF(
              TRIM(Lingkar_kepala_saat_lahir_cmb1),
              ''
            ),
            r'-?\d+(?:[.,]\d+)?'
          ),
          ',',
          '.'
        )
        AS FLOAT64
      ) BETWEEN 20 AND 60

      THEN SAFE_CAST(
        REPLACE(
          REGEXP_EXTRACT(
            NULLIF(
              TRIM(Lingkar_kepala_saat_lahir_cmb1),
              ''
            ),
            r'-?\d+(?:[.,]\d+)?'
          ),
          ',',
          '.'
        )
        AS FLOAT64
      )
    END AS adj_lingkar_kepala_bayi_1_cm,


    NULLIF(
      TRIM(Kelainan_bawaan_bayib1),
      ''
    ) AS adj_kelainan_bawaan_bayi_1,


    NULLIF(
      TRIM(Apakah_pasien_dirujukb1),
      ''
    ) AS adj_dirujuk_bayi_1,


    COALESCE(
      NULLIF(TRIM(Nama_Faskes_Rujukanb1), ''),
      NULLIF(
        TRIM(Fasilitas_kesehatan_tujuan_rujukanb1),
        ''
      )
    ) AS adj_fasilitas_rujukan_bayi_1,


    -- -----------------------------------------------------------------
    -- BABY 2
    -- -----------------------------------------------------------------
    COALESCE(
      SAFE_CAST(
        SUBSTR(
          NULLIF(TRIM(birth_dateb2), ''),
          1,
          10
        ) AS DATE
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        SUBSTR(
          NULLIF(TRIM(birth_dateb2), ''),
          1,
          10
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        SUBSTR(
          NULLIF(TRIM(birth_dateb2), ''),
          1,
          10
        )
      )
    ) AS adj_tanggal_lahir_bayi_2,


    CASE
      WHEN REGEXP_CONTAINS(
        UPPER(COALESCE(Jenis_Kelaminb2, '')),
        r'PEREMPUAN|FEMALE'
      )
        THEN 'PEREMPUAN'

      WHEN REGEXP_CONTAINS(
        UPPER(COALESCE(Jenis_Kelaminb2, '')),
        r'LAKI|MALE'
      )
        THEN 'LAKI-LAKI'

      ELSE NULLIF(
        UPPER(
          REGEXP_REPLACE(
            TRIM(COALESCE(Jenis_Kelaminb2, '')),
            r'[_-]+',
            ' '
          )
        ),
        ''
      )
    END AS adj_jenis_kelamin_bayi_2,


    CASE
      WHEN SAFE_CAST(
        REPLACE(
          REGEXP_EXTRACT(
            NULLIF(
              TRIM(Berat_badan_saat_lahir_gb2),
              ''
            ),
            r'-?\d+(?:[.,]\d+)?'
          ),
          ',',
          '.'
        )
        AS FLOAT64
      ) BETWEEN 300 AND 7000

      THEN SAFE_CAST(
        REPLACE(
          REGEXP_EXTRACT(
            NULLIF(
              TRIM(Berat_badan_saat_lahir_gb2),
              ''
            ),
            r'-?\d+(?:[.,]\d+)?'
          ),
          ',',
          '.'
        )
        AS FLOAT64
      )
    END AS adj_berat_badan_bayi_2_gram,


    CASE
      WHEN SAFE_CAST(
        REPLACE(
          REGEXP_EXTRACT(
            NULLIF(
              TRIM(Panjang_badan_saat_lahir_cmb2),
              ''
            ),
            r'-?\d+(?:[.,]\d+)?'
          ),
          ',',
          '.'
        )
        AS FLOAT64
      ) BETWEEN 20 AND 70

      THEN SAFE_CAST(
        REPLACE(
          REGEXP_EXTRACT(
            NULLIF(
              TRIM(Panjang_badan_saat_lahir_cmb2),
              ''
            ),
            r'-?\d+(?:[.,]\d+)?'
          ),
          ',',
          '.'
        )
        AS FLOAT64
      )
    END AS adj_panjang_badan_bayi_2_cm,


    CASE
      WHEN SAFE_CAST(
        REPLACE(
          REGEXP_EXTRACT(
            NULLIF(
              TRIM(Lingkar_kepala_saat_lahir_cmb2),
              ''
            ),
            r'-?\d+(?:[.,]\d+)?'
          ),
          ',',
          '.'
        )
        AS FLOAT64
      ) BETWEEN 20 AND 60

      THEN SAFE_CAST(
        REPLACE(
          REGEXP_EXTRACT(
            NULLIF(
              TRIM(Lingkar_kepala_saat_lahir_cmb2),
              ''
            ),
            r'-?\d+(?:[.,]\d+)?'
          ),
          ',',
          '.'
        )
        AS FLOAT64
      )
    END AS adj_lingkar_kepala_bayi_2_cm,


    NULLIF(
      TRIM(Kelainan_bawaan_bayib2),
      ''
    ) AS adj_kelainan_bawaan_bayi_2,


    NULLIF(
      TRIM(Apakah_pasien_dirujukb2),
      ''
    ) AS adj_dirujuk_bayi_2,


    COALESCE(
      NULLIF(TRIM(Nama_Faskes_Rujukanb2), ''),
      NULLIF(
        TRIM(Fasilitas_kesehatan_tujuan_rujukanb2),
        ''
      )
    ) AS adj_fasilitas_rujukan_bayi_2

  FROM adj_raw
),


-- =====================================================================
-- 18. JOIN ADJUDICATION TO KOBO
-- =====================================================================
joined AS (
  SELECT
    k.*,

    -- adjudication exists for this Kobo case
    a.adjudication_case_id IS NOT NULL
      AS has_adjudication,

    -- keep adjudication identifier separately
    a.adjudication_case_id,

    -- adjudication metadata
    a.adjudication_record_id,
    a.adjudication_submission_time,

    -- identity
    a.adj_nik_clean,
    a.adj_nama,
    a.adj_tanggal_lahir_ibu,
    a.adj_no_hp,

    -- location
    a.adj_desa,
    a.adj_puskesmas,
    a.adj_faskes,
    a.adj_alamat,
    a.adj_kabupaten,
    a.adj_kecamatan,

    -- pregnancy
    a.adj_hpht_date,
    a.adj_gravida,
    a.adj_partus,
    a.adj_abortus,
    a.adj_tanggal_masuk_inc,
    a.adj_usia_kehamilan_minggu,
    a.adj_usia_kehamilan_hari,

    -- delivery
    a.adj_delivery_date,
    a.adj_abortion_date,
    a.adj_tempat_melahirkan,
    a.adj_alamat_bersalin,
    a.adj_luaran_kehamilan,
    a.adj_keadaan_ibu,
    a.adj_cara_persalinan,
    a.adj_komplikasi_persalinan,
    a.adj_penolong_persalinan_1,
    a.adj_nama_penolong_persalinan_1,
    a.adj_dirujuk_ibu,
    a.adj_fasilitas_rujukan_ibu,

    -- baby 1
    a.adj_tanggal_lahir_bayi_1,
    a.adj_jenis_kelamin_bayi_1,
    a.adj_berat_badan_bayi_1_gram,
    a.adj_panjang_badan_bayi_1_cm,
    a.adj_lingkar_kepala_bayi_1_cm,
    a.adj_kelainan_bawaan_bayi_1,
    a.adj_dirujuk_bayi_1,
    a.adj_fasilitas_rujukan_bayi_1,

    -- baby 2
    a.adj_tanggal_lahir_bayi_2,
    a.adj_jenis_kelamin_bayi_2,
    a.adj_berat_badan_bayi_2_gram,
    a.adj_panjang_badan_bayi_2_cm,
    a.adj_lingkar_kepala_bayi_2_cm,
    a.adj_kelainan_bawaan_bayi_2,
    a.adj_dirujuk_bayi_2,
    a.adj_fasilitas_rujukan_bayi_2

  FROM kobo_case k

  LEFT JOIN adj_normalized a
    ON k.case_id = a.adjudication_case_id
),

-- =====================================================================
-- 19. FINAL VALUES
--
-- IMPORTANT:
--
-- CASE has adjudication:
--     use adjudication value, including NULL
--
-- CASE has no adjudication:
--     use reconciled Kobo value
--
-- =====================================================================
final_values AS (
  SELECT
    j.*,


    -- -----------------------------------------------------------------
    -- IDENTITY
    -- -----------------------------------------------------------------
    CASE
      WHEN has_adjudication
        THEN adj_nik_clean
      ELSE kobo_nik_clean
    END AS final_nik_clean,


    CASE
      WHEN has_adjudication
        THEN adj_nama
      ELSE kobo_nama
    END AS final_nama,


    CASE
      WHEN has_adjudication
        THEN adj_tanggal_lahir_ibu
      ELSE kobo_tanggal_lahir_ibu
    END AS final_tanggal_lahir_ibu,


    CASE
      WHEN has_adjudication
        THEN adj_no_hp
      ELSE kobo_no_hp
    END AS final_no_hp,


    -- -----------------------------------------------------------------
    -- LOCATION
    -- -----------------------------------------------------------------
    CASE
      WHEN has_adjudication
        THEN adj_desa
      ELSE kobo_desa
    END AS final_desa,


    CASE
      WHEN has_adjudication
        THEN adj_puskesmas
      ELSE kobo_puskesmas
    END AS final_puskesmas,


    CASE
      WHEN has_adjudication
        THEN adj_faskes
      ELSE kobo_faskes
    END AS final_faskes,


    CASE
      WHEN has_adjudication
        THEN adj_alamat
      ELSE kobo_alamat
    END AS final_alamat,


    CASE
      WHEN has_adjudication
        THEN adj_kabupaten
      ELSE kobo_kabupaten
    END AS final_kabupaten,


    CASE
      WHEN has_adjudication
        THEN adj_kecamatan
      ELSE kobo_kecamatan
    END AS final_kecamatan,


    -- -----------------------------------------------------------------
    -- PREGNANCY
    -- -----------------------------------------------------------------
    CASE
      WHEN has_adjudication
        THEN adj_hpht_date
      ELSE kobo_hpht_date
    END AS final_hpht_date,


    CASE
      WHEN has_adjudication
        THEN adj_gravida
      ELSE kobo_gravida
    END AS final_gravida,


    CASE
      WHEN has_adjudication
        THEN adj_partus
      ELSE kobo_partus
    END AS final_partus,


    CASE
      WHEN has_adjudication
        THEN adj_abortus
      ELSE kobo_abortus
    END AS final_abortus,


    CASE
      WHEN has_adjudication
        THEN adj_tanggal_masuk_inc
      ELSE kobo_tanggal_masuk_inc
    END AS final_tanggal_masuk_inc,


    CASE
      WHEN has_adjudication
        THEN adj_usia_kehamilan_minggu
      ELSE kobo_usia_kehamilan_minggu
    END AS final_usia_kehamilan_minggu,


    CASE
      WHEN has_adjudication
        THEN adj_usia_kehamilan_hari
      ELSE kobo_usia_kehamilan_hari
    END AS final_usia_kehamilan_hari,


    -- -----------------------------------------------------------------
    -- DELIVERY
    -- -----------------------------------------------------------------
    CASE
      WHEN has_adjudication
        THEN adj_delivery_date
      ELSE kobo_delivery_date
    END AS final_delivery_date,


    CASE
      WHEN has_adjudication
        THEN adj_abortion_date
      ELSE kobo_abortion_date
    END AS final_abortion_date,


    CASE
      WHEN has_adjudication
        THEN adj_tempat_melahirkan
      ELSE kobo_tempat_melahirkan
    END AS final_tempat_melahirkan,


    CASE
      WHEN has_adjudication
        THEN adj_alamat_bersalin
      ELSE kobo_alamat_bersalin
    END AS final_alamat_bersalin,


    CASE
      WHEN has_adjudication
        THEN adj_luaran_kehamilan
      ELSE kobo_luaran_kehamilan
    END AS final_luaran_kehamilan,


    CASE
      WHEN has_adjudication
        THEN adj_keadaan_ibu
      ELSE kobo_keadaan_ibu
    END AS final_keadaan_ibu,


    CASE
      WHEN has_adjudication
        THEN adj_cara_persalinan
      ELSE kobo_cara_persalinan
    END AS final_cara_persalinan,


    CASE
      WHEN has_adjudication
        THEN adj_komplikasi_persalinan
      ELSE kobo_komplikasi_persalinan
    END AS final_komplikasi_persalinan,


    CASE
      WHEN has_adjudication
        THEN adj_penolong_persalinan_1
      ELSE kobo_penolong_persalinan_1
    END AS final_penolong_persalinan_1,


    CASE
      WHEN has_adjudication
        THEN adj_nama_penolong_persalinan_1
      ELSE kobo_nama_penolong_persalinan_1
    END AS final_nama_penolong_persalinan_1,


    CASE
      WHEN has_adjudication
        THEN adj_dirujuk_ibu
      ELSE kobo_dirujuk_ibu
    END AS final_dirujuk_ibu,


    CASE
      WHEN has_adjudication
        THEN adj_fasilitas_rujukan_ibu
      ELSE kobo_fasilitas_rujukan_ibu
    END AS final_fasilitas_rujukan_ibu,


    -- -----------------------------------------------------------------
    -- BABY 1
    -- -----------------------------------------------------------------
    CASE
      WHEN has_adjudication
        THEN adj_tanggal_lahir_bayi_1
      ELSE kobo_tanggal_lahir_bayi_1
    END AS final_tanggal_lahir_bayi_1,


    CASE
      WHEN has_adjudication
        THEN adj_jenis_kelamin_bayi_1
      ELSE kobo_jenis_kelamin_bayi_1
    END AS final_jenis_kelamin_bayi_1,


    CASE
      WHEN has_adjudication
        THEN adj_berat_badan_bayi_1_gram
      ELSE kobo_berat_badan_bayi_1_gram
    END AS final_berat_badan_bayi_1_gram,


    CASE
      WHEN has_adjudication
        THEN adj_panjang_badan_bayi_1_cm
      ELSE kobo_panjang_badan_bayi_1_cm
    END AS final_panjang_badan_bayi_1_cm,


    CASE
      WHEN has_adjudication
        THEN adj_lingkar_kepala_bayi_1_cm
      ELSE kobo_lingkar_kepala_bayi_1_cm
    END AS final_lingkar_kepala_bayi_1_cm,


    CASE
      WHEN has_adjudication
        THEN adj_kelainan_bawaan_bayi_1
      ELSE kobo_kelainan_bawaan_bayi_1
    END AS final_kelainan_bawaan_bayi_1,


    CASE
      WHEN has_adjudication
        THEN adj_dirujuk_bayi_1
      ELSE kobo_dirujuk_bayi_1
    END AS final_dirujuk_bayi_1,


    CASE
      WHEN has_adjudication
        THEN adj_fasilitas_rujukan_bayi_1
      ELSE kobo_fasilitas_rujukan_bayi_1
    END AS final_fasilitas_rujukan_bayi_1,


    -- -----------------------------------------------------------------
    -- BABY 2
    -- -----------------------------------------------------------------
    CASE
      WHEN has_adjudication
        THEN adj_tanggal_lahir_bayi_2
      ELSE kobo_tanggal_lahir_bayi_2
    END AS final_tanggal_lahir_bayi_2,


    CASE
      WHEN has_adjudication
        THEN adj_jenis_kelamin_bayi_2
      ELSE kobo_jenis_kelamin_bayi_2
    END AS final_jenis_kelamin_bayi_2,


    CASE
      WHEN has_adjudication
        THEN adj_berat_badan_bayi_2_gram
      ELSE kobo_berat_badan_bayi_2_gram
    END AS final_berat_badan_bayi_2_gram,


    CASE
      WHEN has_adjudication
        THEN adj_panjang_badan_bayi_2_cm
      ELSE kobo_panjang_badan_bayi_2_cm
    END AS final_panjang_badan_bayi_2_cm,


    CASE
      WHEN has_adjudication
        THEN adj_lingkar_kepala_bayi_2_cm
      ELSE kobo_lingkar_kepala_bayi_2_cm
    END AS final_lingkar_kepala_bayi_2_cm,


    CASE
      WHEN has_adjudication
        THEN adj_kelainan_bawaan_bayi_2
      ELSE kobo_kelainan_bawaan_bayi_2
    END AS final_kelainan_bawaan_bayi_2,


    CASE
      WHEN has_adjudication
        THEN adj_dirujuk_bayi_2
      ELSE kobo_dirujuk_bayi_2
    END AS final_dirujuk_bayi_2,


    CASE
      WHEN has_adjudication
        THEN adj_fasilitas_rujukan_bayi_2
      ELSE kobo_fasilitas_rujukan_bayi_2
    END AS final_fasilitas_rujukan_bayi_2

  FROM joined j
),


-- =====================================================================
-- 20. FINAL MATCHING / USABILITY FLAGS
-- =====================================================================
final_flags AS (
  SELECT
    f.*,


    -- -----------------------------------------------------------------
    -- Final identity availability
    -- -----------------------------------------------------------------
    (
      final_nik_clean IS NOT NULL

      OR (

        final_nama IS NOT NULL

        AND final_tanggal_lahir_ibu IS NOT NULL

        AND (
          final_desa IS NOT NULL
          OR final_puskesmas IS NOT NULL
          OR final_faskes IS NOT NULL
        )

      )

    ) AS has_sufficient_identity_for_matching,


    -- -----------------------------------------------------------------
    -- Final pregnancy anchor
    -- -----------------------------------------------------------------
    (
      final_hpht_date IS NOT NULL
      OR final_delivery_date IS NOT NULL
      OR final_abortion_date IS NOT NULL
      OR final_tanggal_lahir_bayi_1 IS NOT NULL
    ) AS has_pregnancy_anchor,


    -- -----------------------------------------------------------------
    -- FINAL unresolved flags
    --
    -- Once adjudicated, previous Kobo disagreement is considered
    -- resolved by adjudication.
    -- -----------------------------------------------------------------
    (
      NOT has_adjudication
      AND kobo_has_identity_blocking_conflict
    ) AS final_has_identity_blocking_conflict,


    (
      NOT has_adjudication
      AND kobo_has_location_blocking_conflict
    ) AS final_has_location_blocking_conflict,


    (
      NOT has_adjudication
      AND kobo_has_episode_blocking_conflict
    ) AS final_has_episode_blocking_conflict,


    (
      NOT has_adjudication
      AND kobo_has_unresolved_clinical_outcome_conflict
    ) AS final_has_unresolved_clinical_outcome_conflict

  FROM final_values f
),


-- =====================================================================
-- 21. FINAL ELIGIBILITY
-- =====================================================================
eligibility AS (
  SELECT
    f.*,


    (
      has_sufficient_identity_for_matching

      AND has_pregnancy_anchor

      AND NOT final_has_identity_blocking_conflict

      AND NOT final_has_location_blocking_conflict

      AND NOT final_has_episode_blocking_conflict
    ) AS eligible_for_matching,


    (
      NOT final_has_unresolved_clinical_outcome_conflict
    ) AS eligible_for_outcome_use,


    -- -----------------------------------------------------------------
    -- Manual verification
    -- -----------------------------------------------------------------
    (
      NOT has_adjudication

      AND (
        final_has_identity_blocking_conflict
        OR final_has_location_blocking_conflict
      )
    ) AS requires_manual_identity_verification,


    (
      NOT has_adjudication
      AND final_has_episode_blocking_conflict
    ) AS requires_manual_episode_verification,


    (
      NOT has_adjudication
      AND kobo_has_unresolved_location_conflict
    ) AS requires_manual_location_verification,


    (
      NOT has_adjudication
      AND final_has_unresolved_clinical_outcome_conflict
    ) AS requires_manual_outcome_verification,


    -- -----------------------------------------------------------------
    -- Field-specific clinical usability
    -- -----------------------------------------------------------------
    (
      final_luaran_kehamilan IS NOT NULL

      AND (
        has_adjudication
        OR NOT kobo_unresolved_luaran
      )
    ) AS usable_luaran,


    (
      final_keadaan_ibu IS NOT NULL

      AND (
        has_adjudication
        OR NOT kobo_unresolved_keadaan_ibu
      )
    ) AS usable_keadaan_ibu,


    (
      final_cara_persalinan IS NOT NULL

      AND (
        has_adjudication
        OR NOT kobo_unresolved_cara_persalinan
      )
    ) AS usable_cara_persalinan,


    (
      final_jenis_kelamin_bayi_1 IS NOT NULL

      AND (
        has_adjudication
        OR NOT kobo_unresolved_baby1_sex
      )
    ) AS usable_jenis_kelamin_bayi_1,


    (
      final_berat_badan_bayi_1_gram IS NOT NULL

      AND (
        has_adjudication
        OR NOT kobo_unresolved_baby1_birth_weight
      )
    ) AS usable_berat_badan_bayi_1,


    (
      final_panjang_badan_bayi_1_cm IS NOT NULL

      AND (
        has_adjudication
        OR NOT kobo_unresolved_baby1_birth_length
      )
    ) AS usable_panjang_badan_bayi_1

  FROM final_flags f
),


-- =====================================================================
-- 22. FINAL STATUS / SOURCE
-- =====================================================================
final_status AS (
  SELECT
    e.*,


    CASE

      WHEN has_adjudication
        THEN 'ADJUDICATED'

      ELSE kobo_reconciliation_status

    END AS reconciliation_status,


    CASE

      WHEN has_adjudication
        THEN 'ADJUDICATION'

      WHEN kobo_reconciliation_status = 'SINGLE_ENTRY_DIRECT'
        THEN 'KOBO_SINGLE_ENTRY'

      WHEN kobo_reconciliation_status = 'DOUBLE_ENTRY_AGREED'
        THEN 'KOBO_DOUBLE_AGREED'

      WHEN kobo_reconciliation_status = 'DOUBLE_ENTRY_COMPLEMENTARY'
        THEN 'KOBO_DOUBLE_COMPLEMENTARY'

      WHEN kobo_reconciliation_status = 'MULTI_ENTRY_MAJORITY'
        THEN 'KOBO_MULTI_MAJORITY'

      WHEN kobo_reconciliation_status IN (
        'MULTI_ENTRY_COMPLEMENTARY',
        'MULTI_ENTRY_AGREED'
      )
        THEN 'KOBO_MULTI_RECONCILED'

      ELSE 'KOBO_UNRESOLVED'

    END AS case_record_source,


    (
      requires_manual_identity_verification
      OR requires_manual_episode_verification
      OR requires_manual_location_verification
      OR requires_manual_outcome_verification
    ) AS requires_manual_verification,


    ARRAY_TO_STRING(
      ARRAY(
        SELECT reason

        FROM UNNEST([

          IF(
            NOT has_sufficient_identity_for_matching,
            'INSUFFICIENT_IDENTITY',
            NULL
          ),

          IF(
            NOT has_pregnancy_anchor,
            'NO_PREGNANCY_ANCHOR',
            NULL
          ),

          IF(
            final_has_identity_blocking_conflict,
            'UNRESOLVED_IDENTITY_CONFLICT',
            NULL
          ),

          IF(
            final_has_location_blocking_conflict,
            'UNRESOLVED_LOCATION_CONFLICT',
            NULL
          ),

          IF(
            final_has_episode_blocking_conflict,
            'UNRESOLVED_PREGNANCY_EPISODE_CONFLICT',
            NULL
          )

        ]) reason

        WHERE reason IS NOT NULL
      ),
      ', '
    ) AS matching_ineligibility_reason

  FROM eligibility e
)


-- =====================================================================
-- 23. FINAL OUTPUT
-- =====================================================================
SELECT
  'KOBO_INC' AS data_source,

  case_key,
  case_id,


  -- ===================================================================
  -- ADJUDICATION / PROVENANCE
  -- ===================================================================
  has_adjudication,

  case_record_source,
  reconciliation_status,

  adjudication_record_id,
  adjudication_submission_time,


  -- ===================================================================
  -- KOBO SOURCE METADATA
  -- ===================================================================
  source_entry_count,

  source_entry_count = 2
    AS flag_expected_double_entry,

  source_entry_count != 2
    AS flag_entry_count_anomaly,

  source_submission_ids,

  first_submission_time,
  latest_submission_time,

  disagreement_field_count,
  unresolved_field_count,
  complementary_field_count,

  conflict_fields,
  unresolved_fields,
  complementary_fields,


  -- ===================================================================
  -- FINAL IDENTITY
  -- ===================================================================
  final_nik_clean
    AS nik_clean,

  final_nama
    AS nama,

  final_tanggal_lahir_ibu
    AS tanggal_lahir_ibu,

  final_no_hp
    AS no_hp,


  -- ===================================================================
  -- FINAL LOCATION
  -- ===================================================================
  final_desa
    AS desa,

  final_puskesmas
    AS puskesmas,

  final_faskes
    AS facility_name,

  final_alamat
    AS alamat,

  final_kabupaten
    AS kabupaten,

  final_kecamatan
    AS kecamatan,


  -- ===================================================================
  -- FINAL PREGNANCY
  -- ===================================================================
  final_hpht_date
    AS hpht_date,

  final_gravida
    AS gravida,

  final_partus
    AS partus,

  final_abortus
    AS abortus,

  final_tanggal_masuk_inc
    AS tanggal_masuk_inc,

  final_usia_kehamilan_minggu
    AS usia_kehamilan_minggu,

  final_usia_kehamilan_hari
    AS usia_kehamilan_hari,


  -- ===================================================================
  -- FINAL DELIVERY / MATERNAL OUTCOME
  -- ===================================================================
  final_delivery_date
    AS delivery_date,

  final_abortion_date
    AS abortion_date,

  final_tempat_melahirkan
    AS tempat_melahirkan,

  final_alamat_bersalin
    AS alamat_bersalin,

  final_luaran_kehamilan
    AS luaran_kehamilan,

  final_keadaan_ibu
    AS keadaan_ibu,

  final_cara_persalinan
    AS cara_persalinan,

  final_komplikasi_persalinan
    AS komplikasi_persalinan,

  final_penolong_persalinan_1
    AS penolong_persalinan_1,

  final_nama_penolong_persalinan_1
    AS nama_penolong_persalinan_1,

  final_dirujuk_ibu
    AS dirujuk_ibu,

  final_fasilitas_rujukan_ibu
    AS fasilitas_rujukan_ibu,


  -- ===================================================================
  -- FINAL BABY 1
  -- ===================================================================
  final_tanggal_lahir_bayi_1
    AS tanggal_lahir_bayi_1,

  final_jenis_kelamin_bayi_1
    AS jenis_kelamin_bayi_1,

  final_berat_badan_bayi_1_gram
    AS berat_badan_bayi_1_gram,

  final_panjang_badan_bayi_1_cm
    AS panjang_badan_bayi_1_cm,

  final_lingkar_kepala_bayi_1_cm
    AS lingkar_kepala_bayi_1_cm,

  final_kelainan_bawaan_bayi_1
    AS kelainan_bawaan_bayi_1,

  final_dirujuk_bayi_1
    AS dirujuk_bayi_1,

  final_fasilitas_rujukan_bayi_1
    AS fasilitas_rujukan_bayi_1,


  -- ===================================================================
  -- FINAL BABY 2
  -- ===================================================================
  final_tanggal_lahir_bayi_2
    AS tanggal_lahir_bayi_2,

  final_jenis_kelamin_bayi_2
    AS jenis_kelamin_bayi_2,

  final_berat_badan_bayi_2_gram
    AS berat_badan_bayi_2_gram,

  final_panjang_badan_bayi_2_cm
    AS panjang_badan_bayi_2_cm,

  final_lingkar_kepala_bayi_2_cm
    AS lingkar_kepala_bayi_2_cm,

  final_kelainan_bawaan_bayi_2
    AS kelainan_bawaan_bayi_2,

  final_dirujuk_bayi_2
    AS dirujuk_bayi_2,

  final_fasilitas_rujukan_bayi_2
    AS fasilitas_rujukan_bayi_2,


  -- ===================================================================
  -- FINAL ELIGIBILITY
  -- ===================================================================
  has_sufficient_identity_for_matching,
  has_pregnancy_anchor,

  eligible_for_matching,
  eligible_for_outcome_use,

  requires_manual_identity_verification,
  requires_manual_episode_verification,
  requires_manual_location_verification,
  requires_manual_outcome_verification,
  requires_manual_verification,

  matching_ineligibility_reason,


  -- ===================================================================
  -- FIELD-SPECIFIC USABILITY
  -- ===================================================================
  usable_luaran,
  usable_keadaan_ibu,
  usable_cara_persalinan,
  usable_jenis_kelamin_bayi_1,
  usable_berat_badan_bayi_1,
  usable_panjang_badan_bayi_1,


  -- ===================================================================
  -- HISTORICAL KOBO CONFLICT DOMAINS
  --
  -- These remain TRUE even if adjudication later resolved the case.
  -- ===================================================================
  kobo_has_identity_conflict,
  kobo_has_location_conflict,
  kobo_has_pregnancy_episode_conflict,
  kobo_has_clinical_outcome_conflict,

  kobo_has_unresolved_identity_conflict,
  kobo_has_unresolved_location_conflict,
  kobo_has_unresolved_pregnancy_episode_conflict,
  kobo_has_unresolved_clinical_outcome_conflict,


  -- ===================================================================
  -- HISTORICAL FIELD-LEVEL KOBO CONFLICTS
  -- ===================================================================
  kobo_conflict_nik,
  kobo_unresolved_nik,

  kobo_conflict_nama,
  kobo_unresolved_nama,

  kobo_conflict_tanggal_lahir_ibu,
  kobo_unresolved_tanggal_lahir_ibu,

  kobo_conflict_desa,
  kobo_unresolved_desa,

  kobo_conflict_puskesmas,
  kobo_unresolved_puskesmas,

  kobo_conflict_faskes,
  kobo_unresolved_faskes,

  kobo_conflict_hpht,
  kobo_unresolved_hpht,

  kobo_conflict_delivery_date,
  kobo_unresolved_delivery_date,

  kobo_conflict_abortion_date,
  kobo_unresolved_abortion_date,

  kobo_conflict_luaran,
  kobo_unresolved_luaran,

  kobo_conflict_keadaan_ibu,
  kobo_unresolved_keadaan_ibu,

  kobo_conflict_cara_persalinan,
  kobo_unresolved_cara_persalinan,

  kobo_conflict_baby1_birth_date,
  kobo_unresolved_baby1_birth_date,

  kobo_conflict_baby1_sex,
  kobo_unresolved_baby1_sex,

  kobo_conflict_baby1_birth_weight,
  kobo_unresolved_baby1_birth_weight,

  kobo_conflict_baby1_birth_length,
  kobo_unresolved_baby1_birth_length,


  -- ===================================================================
  -- OBSERVED KOBO VALUES FOR MANUAL QA
  -- ===================================================================
  nik_observed_values,
  nama_observed_values,
  tanggal_lahir_ibu_observed_values,

  desa_observed_values,
  puskesmas_observed_values,
  faskes_observed_values,

  hpht_observed_values,
  delivery_date_observed_values,
  abortion_date_observed_values,

  luaran_observed_values,
  keadaan_ibu_observed_values,
  cara_persalinan_observed_values,

  baby1_birth_date_observed_values,
  baby1_sex_observed_values,
  baby1_birth_weight_observed_values,
  baby1_birth_length_observed_values,


  -- ===================================================================
  -- RECONCILIATION METHODS
  -- ===================================================================
  nik_reconciliation_method,
  nama_reconciliation_method,
  tanggal_lahir_ibu_reconciliation_method,

  desa_reconciliation_method,
  puskesmas_reconciliation_method,
  faskes_reconciliation_method,

  hpht_reconciliation_method,
  delivery_date_reconciliation_method,

  luaran_reconciliation_method,
  keadaan_ibu_reconciliation_method,
  cara_persalinan_reconciliation_method,

  baby1_birth_weight_reconciliation_method,


  -- ===================================================================
  -- PREFERRED ORIGINAL KOBO VALUES
  --
  -- FOR MANUAL VERIFICATION ONLY.
  -- DO NOT USE THESE FOR AUTOMATIC MATCHING.
  -- ===================================================================
  p.preferred_submission_id,
  p.preferred_submission_time,
  p.preferred_submission_quality_score,

  p.preferred_username,
  p.preferred_data_entry_clerk_staff_id,

  p.preferred_nik,
  p.preferred_nama,
  p.preferred_tanggal_lahir_ibu,

  p.preferred_desa,
  p.preferred_puskesmas,
  p.preferred_faskes,
  p.preferred_no_hp,

  p.preferred_hpht,
  p.preferred_delivery_date,
  p.preferred_abortion_date,

  p.preferred_luaran,
  p.preferred_keadaan_ibu,
  p.preferred_cara_persalinan,

  p.preferred_tanggal_lahir_bayi_1,
  p.preferred_jenis_kelamin_bayi_1,
  p.preferred_berat_badan_bayi_1_gram,
  p.preferred_panjang_badan_bayi_1_cm,
  p.preferred_lingkar_kepala_bayi_1_cm

FROM final_status f

LEFT JOIN kobo_preferred p
  USING (case_key);

CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.vs_kobo_neonatus_outcome_v2_baby` AS
WITH source AS (
  SELECT
    t.*,

    COALESCE(
      NULLIF(TRIM(uuid), ''),
      NULLIF(TRIM(id), ''),
      CAST(
        FARM_FINGERPRINT(
          TO_JSON_STRING(t)
        ) AS STRING
      )
    ) AS source_submission_id,

    NULLIF(
      REGEXP_REPLACE(
        COALESCE(nik_ibu, ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS nik_ibu_digits,

    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(nama_ibu, '')
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS nama_ibu_norm,

    NULLIF(
      REGEXP_REPLACE(
        COALESCE(
          NULLIF(TRIM(tulis_nomor_hp), ''),
          NULLIF(TRIM(nomor_hp), ''),
          ''
        ),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS nomor_hp_clean

  FROM
    `spheres-lombok-barat.data_kobo_form.neonatus_outcome_v2` t
),


-- ==========================================================
-- Expand baby 1 / baby 2 / baby 3 into separate rows
-- ==========================================================
baby_long AS (

  -- ========================================================
  -- BABY 1
  -- ========================================================
  SELECT
    source_submission_id,
    uuid,
    id,
    task_id,

`start` AS start_time,
`end` AS end_time,
submission_time,
    username,
    submitted_by,
    validation_status,
    status,
    notes,

    data_entry_clerk_type,
    data_entry_clerk_staff_id,
    nik_yang_melakukan_entry_data,
    id_sahabat_sehat,

    lokasi_pemeriksaan_neonatal_outcome,

    jenis_fasilitas_kesehatan,
    pilih_nama_puskesmas,
    tuliskan_nama_rumah_sakit,
    tuliskan_nama_praktik_mandiri_bidan_pmb,
    tuliskan_nama_klinik,
    alamat_email_faskes,

    nama_ibu,
    nik_ibu,
    nik_ibu_digits,
    nama_ibu_norm,

    nomor_hp,
    tulis_nomor_hp,
    nomor_hp_clean,
    alasan,

    nama_ayah,
    nik_ayah,
    nomor_hp_002,
    tulis_nomor_hp_002,
    alasan_002,

    apakah_bayi_kembar,
    jumlah_bayi_kembar,

    1 AS baby_number,

    first_name AS nama_bayi,
    nik_ownership AS nik_ownership_bayi,
    nik_bayi,

    jenis_kelamin,

    address_street AS alamat_bayi,
    kecamatan AS kecamatan_bayi,
    kelurahan AS kelurahan_bayi,

    birth_place_known_001 AS tempat_lahir_diketahui,
    tempat_lahir,
    nama_tempat_lahir,

    birth_date_known AS tanggal_lahir_diketahui,
    birth_date AS birth_date_raw,

    outcome_001 AS neonatal_outcome,

    tanggal_meninggal AS tanggal_meninggal_raw,
    lokasi_meninggal,
    sebab_meninggal,
    diagnosis_sakit,

    age,
    age_001,
    age_death,
    age_death_day,

    jenis_tenaga_kesehat_pelayanan_kesehatan,
    healthworker_name,
    healthworker_id,

    jenis_fasilitas_kesehatan_001 AS jenis_fasilitas_kesehatan_bayi,
    pilih_nama_puskesmas_001 AS pilih_nama_puskesmas_bayi,
    tuliskan_nama_rumah_sakit_001 AS tuliskan_nama_rumah_sakit_bayi,
    tuliskan_nama_praktik_mandiri_bidan_pmb_001
      AS tuliskan_nama_praktik_mandiri_bidan_pmb_bayi,
    tuliskan_nama_klinik_001 AS tuliskan_nama_klinik_bayi,
    alamat_email_faskes_001 AS alamat_email_faskes_bayi

  FROM source


  UNION ALL


  -- ========================================================
  -- BABY 2
  -- ========================================================
  SELECT
    source_submission_id,
    uuid,
    id,
    task_id,

`start` AS start_time,
`end` AS end_time,
submission_time,
    username,
    submitted_by,
    validation_status,
    status,
    notes,

    data_entry_clerk_type,
    data_entry_clerk_staff_id,
    nik_yang_melakukan_entry_data,
    id_sahabat_sehat,

    lokasi_pemeriksaan_neonatal_outcome,

    jenis_fasilitas_kesehatan,
    pilih_nama_puskesmas,
    tuliskan_nama_rumah_sakit,
    tuliskan_nama_praktik_mandiri_bidan_pmb,
    tuliskan_nama_klinik,
    alamat_email_faskes,

    nama_ibu,
    nik_ibu,
    nik_ibu_digits,
    nama_ibu_norm,

    nomor_hp,
    tulis_nomor_hp,
    nomor_hp_clean,
    alasan,

    nama_ayah,
    nik_ayah,
    nomor_hp_002,
    tulis_nomor_hp_002,
    alasan_002,

    apakah_bayi_kembar,
    jumlah_bayi_kembar,

    2 AS baby_number,

    first_name2 AS nama_bayi,
    nik_ownership2 AS nik_ownership_bayi,
    nik_bayi2 AS nik_bayi,

    jenis_kelamin2 AS jenis_kelamin,

    address_street2 AS alamat_bayi,
    kecamatan2 AS kecamatan_bayi,
    kelurahan2 AS kelurahan_bayi,

    birth_place_known_002 AS tempat_lahir_diketahui,
    tempat_lahir2 AS tempat_lahir,
    nama_tempat_lahir2 AS nama_tempat_lahir,

    birth_date_known2 AS tanggal_lahir_diketahui,
    birth_date2 AS birth_date_raw,

    outcome_002 AS neonatal_outcome,

    tanggal_meninggal2 AS tanggal_meninggal_raw,
    lokasi_meninggal2 AS lokasi_meninggal,
    sebab_meninggal2 AS sebab_meninggal,
    diagnosis_sakit2 AS diagnosis_sakit,

    age2 AS age,
    age_002 AS age_001,
    age_death2 AS age_death,
    age_death_day2 AS age_death_day,

    jenis_tenaga_kesehat_pelayanan_kesehatan2
      AS jenis_tenaga_kesehat_pelayanan_kesehatan,
    healthworker_name2 AS healthworker_name,
    healthworker_id2 AS healthworker_id,

    jenis_fasilitas_kesehatan_002 AS jenis_fasilitas_kesehatan_bayi,
    pilih_nama_puskesmas_002 AS pilih_nama_puskesmas_bayi,
    tuliskan_nama_rumah_sakit_002 AS tuliskan_nama_rumah_sakit_bayi,
    tuliskan_nama_praktik_mandiri_bidan_pmb_002
      AS tuliskan_nama_praktik_mandiri_bidan_pmb_bayi,
    tuliskan_nama_klinik_002 AS tuliskan_nama_klinik_bayi,
    alamat_email_faskes_002 AS alamat_email_faskes_bayi

  FROM source


  UNION ALL


  -- ========================================================
  -- BABY 3
  -- ========================================================
  SELECT
    source_submission_id,
    uuid,
    id,
    task_id,
`start` AS start_time,
`end` AS end_time,
submission_time,
    username,
    submitted_by,
    validation_status,
    status,
    notes,

    data_entry_clerk_type,
    data_entry_clerk_staff_id,
    nik_yang_melakukan_entry_data,
    id_sahabat_sehat,

    lokasi_pemeriksaan_neonatal_outcome,

    jenis_fasilitas_kesehatan,
    pilih_nama_puskesmas,
    tuliskan_nama_rumah_sakit,
    tuliskan_nama_praktik_mandiri_bidan_pmb,
    tuliskan_nama_klinik,
    alamat_email_faskes,

    nama_ibu,
    nik_ibu,
    nik_ibu_digits,
    nama_ibu_norm,

    nomor_hp,
    tulis_nomor_hp,
    nomor_hp_clean,
    alasan,

    nama_ayah,
    nik_ayah,
    nomor_hp_002,
    tulis_nomor_hp_002,
    alasan_002,

    apakah_bayi_kembar,
    jumlah_bayi_kembar,

    3 AS baby_number,

    first_name3 AS nama_bayi,
    nik_ownership3 AS nik_ownership_bayi,
    nik_bayi3 AS nik_bayi,

    jenis_kelamin3 AS jenis_kelamin,

    address_street3 AS alamat_bayi,
    kecamatan3 AS kecamatan_bayi,
    kelurahan3 AS kelurahan_bayi,

    birth_place_known_003 AS tempat_lahir_diketahui,
    tempat_lahir3 AS tempat_lahir,
    nama_tempat_lahir3 AS nama_tempat_lahir,

    birth_date_known3 AS tanggal_lahir_diketahui,
    birth_date3 AS birth_date_raw,

    outcome_003 AS neonatal_outcome,

    tanggal_meninggal3 AS tanggal_meninggal_raw,
    lokasi_meninggal3 AS lokasi_meninggal,
    sebab_meninggal3 AS sebab_meninggal,
    diagnosis_sakit3 AS diagnosis_sakit,

    age3 AS age,
    age_003 AS age_001,
    age_death3 AS age_death,
    age_death_day3 AS age_death_day,

    jenis_tenaga_kesehat_pelayanan_kesehatan3
      AS jenis_tenaga_kesehat_pelayanan_kesehatan,
    healthworker_name3 AS healthworker_name,
    healthworker_id3 AS healthworker_id,

    jenis_fasilitas_kesehatan_003 AS jenis_fasilitas_kesehatan_bayi,
    pilih_nama_puskesmas_003 AS pilih_nama_puskesmas_bayi,
    tuliskan_nama_rumah_sakit_003 AS tuliskan_nama_rumah_sakit_bayi,
    tuliskan_nama_praktik_mandiri_bidan_pmb_003
      AS tuliskan_nama_praktik_mandiri_bidan_pmb_bayi,
    tuliskan_nama_klinik_003 AS tuliskan_nama_klinik_bayi,
    alamat_email_faskes_003 AS alamat_email_faskes_bayi

  FROM source
),


-- ==========================================================
-- Normalize identity and dates
-- ==========================================================
normalized AS (
  SELECT
    *,

    CASE
      WHEN REGEXP_CONTAINS(
        nik_ibu_digits,
        r'^\d{16}$'
      )
      AND nik_ibu_digits NOT IN (
        '0000000000000000',
        '9999999999999999'
      )
      THEN nik_ibu_digits
    END AS nik_ibu_clean,

    CASE
      WHEN REGEXP_CONTAINS(
        REGEXP_REPLACE(COALESCE(nik_bayi, ''), r'[^0-9]', ''),
        r'^\d{16}$'
      )
      THEN REGEXP_REPLACE(
        nik_bayi,
        r'[^0-9]',
        ''
      )
    END AS nik_bayi_clean,

    COALESCE(
      SAFE.PARSE_DATE('%Y-%m-%d', NULLIF(TRIM(birth_date_raw), '')),
      SAFE.PARSE_DATE('%d/%m/%Y', NULLIF(TRIM(birth_date_raw), '')),
      SAFE.PARSE_DATE('%d-%m-%Y', NULLIF(TRIM(birth_date_raw), ''))
    ) AS birth_date,

    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        NULLIF(TRIM(tanggal_meninggal_raw), '')
      ),
      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        NULLIF(TRIM(tanggal_meninggal_raw), '')
      ),
      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        NULLIF(TRIM(tanggal_meninggal_raw), '')
      )
    ) AS tanggal_meninggal,

    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(nama_bayi, '')
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS nama_bayi_norm,

    -- Normalize neonatal outcome:
    -- sehat / sakit / meninggal / NULL
    NULLIF(
      LOWER(TRIM(neonatal_outcome)),
      ''
    ) AS neonatal_outcome_clean

  FROM baby_long
)


SELECT
  *,

  -- Useful pregnancy/delivery matching key
  CASE
    WHEN nik_ibu_clean IS NOT NULL
      AND birth_date IS NOT NULL
    THEN CONCAT(
      nik_ibu_clean,
      '|',
      CAST(birth_date AS STRING)
    )
  END AS mother_birth_date_key,

  -- Baby-specific identity
  CASE
    WHEN nik_bayi_clean IS NOT NULL
    THEN CONCAT(
      'NIK_BAYI|',
      nik_bayi_clean
    )

    WHEN nik_ibu_clean IS NOT NULL
      AND birth_date IS NOT NULL
      AND baby_number IS NOT NULL
    THEN CONCAT(
      'IBU_DOB_SLOT|',
      nik_ibu_clean,
      '|',
      CAST(birth_date AS STRING),
      '|',
      CAST(baby_number AS STRING)
    )

    WHEN nama_ibu_norm IS NOT NULL
      AND birth_date IS NOT NULL
      AND baby_number IS NOT NULL
    THEN CONCAT(
      'NAMA_DOB_SLOT|',
      nama_ibu_norm,
      '|',
      CAST(birth_date AS STRING),
      '|',
      CAST(baby_number AS STRING)
    )
  END AS neonatal_baby_key

FROM normalized

-- Remove unused baby slots
WHERE
  NULLIF(TRIM(nama_bayi), '') IS NOT NULL
  OR NULLIF(TRIM(nik_bayi), '') IS NOT NULL
  OR NULLIF(TRIM(birth_date_raw), '') IS NOT NULL
  OR neonatal_outcome_clean IS NOT NULL
  OR NULLIF(TRIM(jenis_kelamin), '') IS NOT NULL;

CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.vs_sigizi_anc` AS
WITH

-- =========================================================
-- 1. SOURCE
-- =========================================================
src AS (
  SELECT
    s.*,

    /*
      Fingerprint of the exact source row.

      IMPORTANT:
      This is a version-specific row hash.
      If any source field changes, including file_name,
      the hash may also change.

      Therefore this is NOT used as the primary ANC encounter
      identifier when mother + ANC date are available.
    */
    FARM_FINGERPRINT(
      TO_JSON_STRING(
        (SELECT AS STRUCT s.*)
      )
    ) AS source_row_hash,


    -- -----------------------------------------------------
    -- Raw NIK
    -- -----------------------------------------------------
    NULLIF(
      TRIM(
        CAST(s.nik AS STRING)
      ),
      ''
    ) AS nik_raw,


    -- -----------------------------------------------------
    -- Digits-only NIK
    -- -----------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        COALESCE(
          CAST(s.nik AS STRING),
          ''
        ),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS nik_digits,


    -- -----------------------------------------------------
    -- Extract file upload datetime from file_name
    -- -----------------------------------------------------
    COALESCE(

      SAFE.PARSE_DATETIME(
        '%Y-%m-%d %H:%M:%E*S',
        REPLACE(
          REGEXP_EXTRACT(
            CAST(s.file_name AS STRING),
            r'(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
          ),
          'T',
          ' '
        )
      ),

      DATETIME(
        SAFE.PARSE_DATE(
          '%Y-%m-%d',
          REGEXP_EXTRACT(
            CAST(s.file_name AS STRING),
            r'(\d{4}-\d{2}-\d{2})'
          )
        )
      )

    ) AS file_dt_from_name

  FROM
    `spheres-lombok-barat.raw_data.sigizi_kesga_bumil_anc` s
),



-- =========================================================
-- 2. CLEAN / NORMALIZE
-- =========================================================
cleaned AS (
  SELECT
    src.*,


    -- -----------------------------------------------------
    -- Valid 16-digit NIK
    -- -----------------------------------------------------
    CASE
      WHEN REGEXP_CONTAINS(
        nik_digits,
        r'^\d{16}$'
      )
      AND nik_digits NOT IN (
        '0000000000000000',
        '9999999999999999'
      )
      THEN nik_digits

      ELSE NULL
    END AS nik_clean,


    CASE
      WHEN REGEXP_CONTAINS(
        nik_digits,
        r'^\d{16}$'
      )
      AND nik_digits NOT IN (
        '0000000000000000',
        '9999999999999999'
      )
      THEN TRUE

      ELSE FALSE
    END AS flag_nik_valid,


    -- -----------------------------------------------------
    -- Normalize mother name
    -- -----------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(
              CAST(nama AS STRING),
              ''
            )
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS nama_norm,


    -- -----------------------------------------------------
    -- Normalize desa
    -- -----------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(
              CAST(desakel_domisili AS STRING),
              ''
            )
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS desa_norm,


    -- -----------------------------------------------------
    -- Normalize puskesmas
    -- -----------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(
              CAST(puskesmas_domisili AS STRING),
              ''
            )
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS puskesmas_norm,


    -- -----------------------------------------------------
    -- Date of birth
    -- -----------------------------------------------------
    COALESCE(

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          TRIM(
            CAST(tanggal_lahir AS STRING)
          ),
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          TRIM(
            CAST(tanggal_lahir AS STRING)
          ),
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          TRIM(
            CAST(tanggal_lahir AS STRING)
          ),
          r'(\d{2}-\d{2}-\d{4})'
        )
      )

    ) AS tanggal_lahir_std,


    -- -----------------------------------------------------
    -- HPHT
    --
    -- IMPORTANT:
    -- Only use HPHT actually provided by SIGIZI.
    -- HPL is NOT converted into HPHT here.
    -- -----------------------------------------------------
    COALESCE(

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          TRIM(
            CAST(tanggal_hpht AS STRING)
          ),
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          TRIM(
            CAST(tanggal_hpht AS STRING)
          ),
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          TRIM(
            CAST(tanggal_hpht AS STRING)
          ),
          r'(\d{2}-\d{2}-\d{4})'
        )
      )

    ) AS tanggal_hpht_std,


    -- -----------------------------------------------------
    -- ANC visit date
    -- -----------------------------------------------------
    COALESCE(

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          TRIM(
            CAST(
              pemeriksaan_anc_tanggal_anc
              AS STRING
            )
          ),
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          TRIM(
            CAST(
              pemeriksaan_anc_tanggal_anc
              AS STRING
            )
          ),
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          TRIM(
            CAST(
              pemeriksaan_anc_tanggal_anc
              AS STRING
            )
          ),
          r'(\d{2}-\d{2}-\d{4})'
        )
      )

    ) AS tanggal_anc_std,


    -- -----------------------------------------------------
    -- HPL
    --
    -- Keep this as its own source fact.
    -- Do NOT convert this into HPHT.
    -- -----------------------------------------------------
    COALESCE(

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          TRIM(
            CAST(
              pemeriksaan_anc_tanggal_perkiraan_persalinan
              AS STRING
            )
          ),
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          TRIM(
            CAST(
              pemeriksaan_anc_tanggal_perkiraan_persalinan
              AS STRING
            )
          ),
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          TRIM(
            CAST(
              pemeriksaan_anc_tanggal_perkiraan_persalinan
              AS STRING
            )
          ),
          r'(\d{2}-\d{2}-\d{4})'
        )
      )

    ) AS hpl_std

  FROM src
),



-- =========================================================
-- 3. MOTHER IDENTITY
-- =========================================================
identity AS (
  SELECT
    c.*,


    /*
      Mother identity hierarchy:

      1. Valid NIK
      2. Name + DOB + desa
      3. Name + DOB + puskesmas
      4. Individual source row

      Weak identities are deliberately NOT aggressively merged.
    */
    CASE

      -- ---------------------------------------------------
      -- Highest confidence: valid NIK
      -- ---------------------------------------------------
      WHEN flag_nik_valid
      THEN CONCAT(
        'NIK|',
        nik_clean
      )


      -- ---------------------------------------------------
      -- Fallback: name + DOB + desa
      -- ---------------------------------------------------
      WHEN nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND desa_norm IS NOT NULL
      THEN CONCAT(
        'NAME_DOB_DESA|',
        nama_norm,
        '|',
        CAST(tanggal_lahir_std AS STRING),
        '|',
        desa_norm
      )


      -- ---------------------------------------------------
      -- Fallback: name + DOB + puskesmas
      -- ---------------------------------------------------
      WHEN nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND puskesmas_norm IS NOT NULL
      THEN CONCAT(
        'NAME_DOB_PKM|',
        nama_norm,
        '|',
        CAST(tanggal_lahir_std AS STRING),
        '|',
        puskesmas_norm
      )


      -- ---------------------------------------------------
      -- Weak identity:
      -- preserve as individual source row
      -- ---------------------------------------------------
      ELSE CONCAT(
        'ROW|',
        CAST(source_row_hash AS STRING)
      )

    END AS mother_source_key,


    CASE

      WHEN flag_nik_valid
        THEN 'NIK'

      WHEN nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND desa_norm IS NOT NULL
        THEN 'NAMA+DOB+DESA'

      WHEN nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND puskesmas_norm IS NOT NULL
        THEN 'NAMA+DOB+PUSKESMAS'

      ELSE 'ROW_FALLBACK'

    END AS mother_match_method,


    -- -----------------------------------------------------
    -- Pregnancy anchor
    --
    -- Only actual HPHT is allowed here.
    -- HPL-derived HPHT has been removed.
    -- -----------------------------------------------------
    tanggal_hpht_std AS pregnancy_anchor_date,


    CASE
      WHEN tanggal_hpht_std IS NOT NULL
        THEN 'HPHT'
      ELSE 'NO_HPHT_RECORDED'
    END AS pregnancy_anchor_type

  FROM cleaned c
),



-- =========================================================
-- 4. PREPARE ANC ENCOUNTER DEDUPLICATION
-- =========================================================
dedup_prep AS (
  SELECT
    i.*,


    /*
      IMPORTANT CHANGE:

      The source-level ANC encounter is identified using:

          mother + ANC date

      HPHT/HPL are NOT part of this key.

      This means if HPHT is corrected in a later SIGIZI
      upload, the corrected row replaces the older version
      rather than creating a second ANC encounter.
    */
    CASE

      -- ---------------------------------------------------
      -- Cannot safely identify an ANC encounter without
      -- an ANC date.
      -- ---------------------------------------------------
      WHEN tanggal_anc_std IS NULL
      THEN CONCAT(
        'ROW|',
        CAST(source_row_hash AS STRING)
      )


      -- ---------------------------------------------------
      -- Cannot safely merge records when mother identity
      -- itself is weak.
      -- ---------------------------------------------------
      WHEN mother_match_method = 'ROW_FALLBACK'
      THEN CONCAT(
        'ROW|',
        CAST(source_row_hash AS STRING)
      )


      -- ---------------------------------------------------
      -- Normal ANC encounter:
      -- one mother + one ANC date
      -- ---------------------------------------------------
      ELSE CONCAT(
        mother_source_key,
        '|ANC|',
        CAST(tanggal_anc_std AS STRING)
      )

    END AS dedup_key,


    CASE

      WHEN tanggal_anc_std IS NULL
        THEN 'NO_DEDUP_NO_ANC_DATE'

      WHEN mother_match_method = 'ROW_FALLBACK'
        THEN 'NO_DEDUP_WEAK_IDENTITY'

      ELSE CONCAT(
        mother_match_method,
        '+ANC_DATE'
      )

    END AS dedup_method,


    -- -----------------------------------------------------
    -- Convert upload datetime to WITA timestamp
    -- -----------------------------------------------------
    TIMESTAMP(
      file_dt_from_name,
      'Asia/Makassar'
    ) AS file_upload_ts

  FROM identity i
),



-- =========================================================
-- 5. CREATE STABLE ANC ENCOUNTER KEY
-- =========================================================
encounter_keyed AS (
  SELECT
    d.*,


    /*
      Stable ANC visit identifier.

      For normal records this remains stable when:
      - HPHT is corrected
      - HPL is corrected
      - weight/lab/USG values change
      - the same visit appears in another upload

      because the key is based on mother + ANC date.
    */
    CONCAT(
      'SIGANC_',
      TO_HEX(
        SHA256(
          dedup_key
        )
      )
    ) AS sigizi_anc_visit_key

  FROM dedup_prep d
),



-- =========================================================
-- 6. RANK DUPLICATE SNAPSHOTS
-- =========================================================
ranked AS (
  SELECT
    e.*,


    /*
      Same ANC encounter may appear repeatedly across
      SIGIZI exports.

      Keep the newest uploaded version.
    */
    ROW_NUMBER() OVER (
      PARTITION BY dedup_key

      ORDER BY
        file_upload_ts DESC NULLS LAST,
        file_name DESC,
        source_row_hash DESC
    ) AS rn

  FROM encounter_keyed e
)



-- =========================================================
-- 7. FINAL OUTPUT
-- =========================================================
SELECT

  -- -------------------------------------------------------
  -- Mother identity
  -- -------------------------------------------------------
  nama,

  nik_raw,
  nik,
  nik_clean,
  flag_nik_valid,

  nama_norm,

  tanggal_lahir_std AS tanggal_lahir,

  umur,

  CAST(NULL AS STRING) AS no_telepon_ibu,


  -- -------------------------------------------------------
  -- Domicile
  -- -------------------------------------------------------
  prov_domisili,
  kabkota_domisili,
  kec_domisili,
  puskesmas_domisili,
  desakel_domisili,
  posyandu_domisili,
  alamat_domisili,

  puskesmas_norm,
  desa_norm,


  -- -------------------------------------------------------
  -- ANC service
  -- -------------------------------------------------------
  faskes_yang_melayani_anc,
  pemeriksaan_pertama,


  -- -------------------------------------------------------
  -- Pregnancy dates
  -- -------------------------------------------------------
  tanggal_hpht_std
    AS tanggal_hpht,

  tanggal_anc_std
    AS pemeriksaan_anc_tanggal_anc,


  -- -------------------------------------------------------
  -- ANC clinical information
  -- -------------------------------------------------------
  pemeriksaan_anc_usia_kehamilan,
  pemeriksaan_anc_tenaga_pemeriksa,
  pemeriksaan_anc_riwayat_imun_tt_terakhir,
  pemeriksaan_anc_berat,
  pemeriksaan_anc_tinggi,
  pemeriksaan_anc_lila,
  pemeriksaan_anc_tekanan_darah,
  pemeriksaan_anc_tfu,
  pemeriksaan_anc_presentasi_janin,
  pemeriksaan_anc_djj,
  pemeriksaan_anc_diperiksa_usg,
  pemeriksaan_anc_imt_sebelum_hamil,
  pemeriksaan_anc_jumlah_ttd_diterima,
  pemeriksaan_anc_jumlah_mms_diterima,
  pemeriksaan_anc_lab_golongan_darah,
  pemeriksaan_anc_lab_rhesus,
  pemeriksaan_anc_lab_hiv,
  pemeriksaan_anc_lab_hepatitis,
  pemeriksaan_anc_lab_siphilis,
  pemeriksaan_anc_lab_protein_urine,
  pemeriksaan_anc_lab_hb,
  pemeriksaan_anc_lab_gula_sewaktu,
  pemeriksaan_anc_lab_lainnya,
  pemeriksaan_anc_tatalaksana_anemia,
  pemeriksaan_anc_pre_eklampsia,
  pemeriksaan_anc_tatalaksana_pre_eklampsia,
  pemeriksaan_anc_status_gizi_kektidak_kek,
  pemeriksaan_anc_tatalaksana_kek,
  pemeriksaan_anc_risiko_masalah_kesehatan_lainnya,
  pemeriksaan_anc_diberikan_tatalaksana_masalah_kesehatan_lainnya,
  pemeriksaan_anc_konseling,
  pemeriksaan_anc_skrinning_keswa,


  -- -------------------------------------------------------
  -- HPL kept independently.
  --
  -- IMPORTANT:
  -- It is NOT used to derive HPHT in this view.
  -- -------------------------------------------------------
  hpl_std
    AS pemeriksaan_anc_tanggal_perkiraan_persalinan,


  pemeriksaan_anc_aksi,

  puskesmas_name,
  puskesmas_id,


  -- -------------------------------------------------------
  -- Mother matching metadata
  -- -------------------------------------------------------
  mother_source_key,
  mother_match_method,


  -- -------------------------------------------------------
  -- Pregnancy metadata
  --
  -- This is informational only at this source layer.
  -- Final pregnancy assignment should happen downstream.
  -- -------------------------------------------------------
  pregnancy_anchor_date,
  pregnancy_anchor_type,


  -- -------------------------------------------------------
  -- ANC encounter metadata
  -- -------------------------------------------------------
  sigizi_anc_visit_key,

  dedup_key,
  dedup_method,


  /*
    Stable source record identifier for the cleaned ANC
    encounter.

    For normal identifiable ANC records this remains stable
    across repeated SIGIZI file uploads.
  */
  sigizi_anc_visit_key AS source_record_id,


  /*
    Exact raw-row version fingerprint.

    Useful for QA and identifying whether the underlying
    source row itself changed between uploads.
  */
  CAST(source_row_hash AS STRING)
    AS source_row_hash,


  -- -------------------------------------------------------
  -- File metadata
  -- -------------------------------------------------------
  file_name,

  file_dt_from_name
    AS file_date_upload,

  file_upload_ts,


  -- -------------------------------------------------------
  -- Source
  -- -------------------------------------------------------
  'Sigizi Kesga Bumil ANC'
    AS data_source,


  -- -------------------------------------------------------
  -- QA flags
  -- -------------------------------------------------------
  tanggal_lahir_std IS NOT NULL
    AS flag_tanggal_lahir_valid,

  tanggal_hpht_std IS NOT NULL
    AS flag_tanggal_hpht_valid,

  tanggal_anc_std IS NOT NULL
    AS flag_tanggal_anc_valid,

  hpl_std IS NOT NULL
    AS flag_tanggal_perkiraan_persalinan_valid


FROM ranked

WHERE rn = 1;

CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.vs_sigizi_daftar_ibu` AS
-- StandardSQL (BigQuery)
--
-- Purpose:
--   Normalize SIGIZI Daftar Ibu and deduplicate to:
--   ONE MOTHER + ONE RECORDED HPHT = ONE PREGNANCY
--
-- Important:
--   - Pregnancy identity uses ONLY HPHT provided in the source.
--   - HPL is NOT converted to HPHT.
--   - Delivery date is NOT converted to HPHT.
--   - Abortion date is NOT converted to HPHT.
--   - Records without HPHT are NOT automatically merged into a pregnancy.
--     They remain source-record level to avoid false pregnancy assignment.


WITH src AS (
  SELECT
    s.*,

    -- Preserve the complete original source row
    TO_JSON_STRING(s) AS source_json,

    -- Stable fallback identifier when UUID is unavailable
    FARM_FINGERPRINT(
      TO_JSON_STRING((SELECT AS STRUCT s.*))
    ) AS source_row_hash

  FROM
    `spheres-lombok-barat.raw_data.sigizi_daftar_ibu` s
),


-- =========================================================
-- 1. REMOVE ESSENTIALLY EMPTY RECORDS
-- =========================================================
filtered AS (
  SELECT
    *
  FROM src

  WHERE NOT (
    -- No identifiable mother
    (
      NULLIF(TRIM(CAST(nik AS STRING)), '') IS NULL
      AND
      NULLIF(TRIM(CAST(nama AS STRING)), '') IS NULL
    )

    AND

    -- No pregnancy/outcome date
    (
      NULLIF(TRIM(CAST(tgl_hpht AS STRING)), '') IS NULL
      AND
      NULLIF(TRIM(CAST(tanggal_melahirkan AS STRING)), '') IS NULL
      AND
      NULLIF(TRIM(CAST(tanggal_abortus AS STRING)), '') IS NULL
    )
  )
),


-- =========================================================
-- 2. BASIC NORMALIZATION
-- =========================================================
cleaned AS (
  SELECT
    s.*,

    -- -----------------------------------------------------
    -- NIK: digits only
    -- -----------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        COALESCE(CAST(nik AS STRING), ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS nik_digits,


    -- -----------------------------------------------------
    -- Mother name normalization
    -- -----------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(CAST(nama AS STRING), '')
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS nama_norm,


    -- -----------------------------------------------------
    -- Desa normalization
    -- -----------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(CAST(desakel AS STRING), '')
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS desa_norm,


    -- -----------------------------------------------------
    -- Puskesmas normalization
    --
    -- Supports both:
    --   puskesmas
    --   pukesmas
    -- -----------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(
              JSON_VALUE(source_json, '$.puskesmas'),
              JSON_VALUE(source_json, '$.pukesmas'),
              ''
            )
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS puskesmas_norm

  FROM filtered s
),


-- =========================================================
-- 3. PARSE IDENTIFIERS, DATES, AND SOURCE TIMESTAMPS
-- =========================================================
parsed AS (
  SELECT
    c.*,


    -- =====================================================
    -- VALIDATED NIK
    -- =====================================================
    CASE
      WHEN REGEXP_CONTAINS(
        nik_digits,
        r'^\d{16}$'
      )
      AND nik_digits NOT IN (
        '0000000000000000',
        '9999999999999999'
      )
      THEN nik_digits

      ELSE NULL
    END AS nik_clean,


    -- =====================================================
    -- DATE OF BIRTH
    -- =====================================================
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          CAST(tgl_lahir AS STRING),
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          CAST(tgl_lahir AS STRING),
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          CAST(tgl_lahir AS STRING),
          r'(\d{2}-\d{2}-\d{4})'
        )
      )
    ) AS tanggal_lahir_std,


    -- =====================================================
    -- HPHT
    --
    -- This is the ONLY date used later for pregnancy
    -- identification.
    -- =====================================================
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          CAST(tgl_hpht AS STRING),
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          CAST(tgl_hpht AS STRING),
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          CAST(tgl_hpht AS STRING),
          r'(\d{2}-\d{2}-\d{4})'
        )
      )
    ) AS tanggal_hpht_std,


    -- =====================================================
    -- DELIVERY DATE
    --
    -- Kept as outcome information.
    -- NOT used to derive HPHT.
    -- =====================================================
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          CAST(tanggal_melahirkan AS STRING),
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          CAST(tanggal_melahirkan AS STRING),
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          CAST(tanggal_melahirkan AS STRING),
          r'(\d{2}-\d{2}-\d{4})'
        )
      )
    ) AS tanggal_melahirkan_date,


    -- =====================================================
    -- ABORTION DATE
    --
    -- Kept as outcome information.
    -- NOT used as pregnancy anchor.
    -- =====================================================
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          CAST(tanggal_abortus AS STRING),
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          CAST(tanggal_abortus AS STRING),
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          CAST(tanggal_abortus AS STRING),
          r'(\d{2}-\d{2}-\d{4})'
        )
      )
    ) AS tanggal_abortus_date,


    -- =====================================================
    -- HPL
    --
    -- Retained as a normalized source variable.
    -- It is NOT converted to HPHT.
    -- =====================================================
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(source_json, '$.tgl_hpl'),
            JSON_VALUE(source_json, '$.tanggal_hpl'),
            JSON_VALUE(source_json, '$.hpl')
          ),
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(source_json, '$.tgl_hpl'),
            JSON_VALUE(source_json, '$.tanggal_hpl'),
            JSON_VALUE(source_json, '$.hpl')
          ),
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(source_json, '$.tgl_hpl'),
            JSON_VALUE(source_json, '$.tanggal_hpl'),
            JSON_VALUE(source_json, '$.hpl')
          ),
          r'(\d{2}-\d{2}-\d{4})'
        )
      )
    ) AS tanggal_hpl_std,


    -- =====================================================
    -- INGESTION TIMESTAMP
    -- =====================================================
    COALESCE(
      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%d %H:%M:%E*S',
        NULLIF(
          TRIM(CAST(ingestion_timestamp AS STRING)),
          ''
        )
      ),

      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%dT%H:%M:%E*S',
        NULLIF(
          TRIM(CAST(ingestion_timestamp AS STRING)),
          ''
        )
      ),

      SAFE_CAST(
        NULLIF(
          TRIM(CAST(ingestion_timestamp AS STRING)),
          ''
        )
        AS TIMESTAMP
      )
    ) AS ingestion_ts,


    -- =====================================================
    -- FILE DATETIME FROM FILE NAME
    -- =====================================================
    COALESCE(
      SAFE.PARSE_DATETIME(
        '%Y-%m-%d %H:%M:%E*S',
        REPLACE(
          REGEXP_EXTRACT(
            CAST(file_name AS STRING),
            r'(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
          ),
          'T',
          ' '
        )
      ),

      DATETIME(
        SAFE.PARSE_DATE(
          '%Y-%m-%d',
          REGEXP_EXTRACT(
            CAST(file_name AS STRING),
            r'(\d{4}-\d{2}-\d{2})'
          )
        )
      )
    ) AS file_dt_from_name,


    -- =====================================================
    -- FILE DATE
    -- =====================================================
    COALESCE(
      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%d %H:%M:%E*S',
        NULLIF(
          TRIM(CAST(file_date AS STRING)),
          ''
        )
      ),

      TIMESTAMP(
        SAFE.PARSE_DATE(
          '%Y-%m-%d',
          REGEXP_EXTRACT(
            CAST(file_date AS STRING),
            r'(\d{4}-\d{2}-\d{2})'
          )
        )
      )
    ) AS file_date_ts

  FROM cleaned c
),


-- =========================================================
-- 4. STATUS + MOTHER IDENTITY
-- =========================================================
status_and_identity AS (
  SELECT
    p.*,


    -- =====================================================
    -- NIK QUALITY FLAG
    -- =====================================================
    nik_clean IS NOT NULL AS flag_nik_valid,


    -- =====================================================
    -- SOURCE RECORD IDENTIFIER
    -- =====================================================
    COALESCE(
      NULLIF(
        TRIM(CAST(uuid AS STRING)),
        ''
      ),

      CAST(source_row_hash AS STRING)
    ) AS source_record_id,


    -- =====================================================
    -- PREGNANCY OUTCOME STATUS
    --
    -- Delivery has priority if both dates are populated.
    -- =====================================================
    CASE
      WHEN tanggal_melahirkan_date IS NOT NULL
        THEN 'Melahirkan'

      WHEN tanggal_abortus_date IS NOT NULL
        THEN 'Abortus'

      ELSE NULL
    END AS status,


    -- =====================================================
    -- MOTHER IDENTITY
    --
    -- Priority:
    --   1. Valid NIK
    --   2. Name + DOB + Desa
    --   3. Name + DOB + Puskesmas
    --   4. Individual source record
    -- =====================================================
    CASE

      -- ---------------------------------------------------
      -- 1. NIK
      -- ---------------------------------------------------
      WHEN nik_clean IS NOT NULL
      THEN CONCAT(
        'NIK|',
        nik_clean
      )


      -- ---------------------------------------------------
      -- 2. Name + DOB + Desa
      -- ---------------------------------------------------
      WHEN nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND desa_norm IS NOT NULL

      THEN CONCAT(
        'NAME_DOB_DESA|',
        nama_norm,
        '|',
        CAST(tanggal_lahir_std AS STRING),
        '|',
        desa_norm
      )


      -- ---------------------------------------------------
      -- 3. Name + DOB + Puskesmas
      -- ---------------------------------------------------
      WHEN nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND puskesmas_norm IS NOT NULL

      THEN CONCAT(
        'NAME_DOB_PKM|',
        nama_norm,
        '|',
        CAST(tanggal_lahir_std AS STRING),
        '|',
        puskesmas_norm
      )


      -- ---------------------------------------------------
      -- 4. Weak identity:
      --    keep as separate source record
      -- ---------------------------------------------------
      ELSE CONCAT(
        'SOURCE|',
        COALESCE(
          NULLIF(
            TRIM(CAST(uuid AS STRING)),
            ''
          ),
          CAST(source_row_hash AS STRING)
        )
      )

    END AS mother_source_key,


    -- =====================================================
    -- IDENTITY MATCH METHOD
    -- =====================================================
    CASE
      WHEN nik_clean IS NOT NULL
        THEN 'NIK'

      WHEN nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND desa_norm IS NOT NULL
        THEN 'NAMA+DOB+DESA'

      WHEN nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND puskesmas_norm IS NOT NULL
        THEN 'NAMA+DOB+PUSKESMAS'

      ELSE 'SOURCE_RECORD'
    END AS mother_match_method

  FROM parsed p
),


-- =========================================================
-- 5. PREGNANCY DEFINITION
--
-- IMPORTANT:
-- Pregnancy anchor is ONLY the provided HPHT.
--
-- Do not derive HPHT from:
--   - HPL
--   - delivery date
--   - abortion date
-- =========================================================
pregnancy AS (
  SELECT
    s.*,


    -- Actual recorded HPHT only
    tanggal_hpht_std AS pregnancy_anchor_date,


    CASE
      WHEN tanggal_hpht_std IS NOT NULL
        THEN 'HPHT'

      ELSE 'NO_HPHT'
    END AS pregnancy_anchor_type

  FROM status_and_identity s
),


-- =========================================================
-- 6. CREATE DEDUPLICATION KEY
--
-- ONE MOTHER + ONE RECORDED HPHT = ONE PREGNANCY
--
-- Records without HPHT are intentionally NOT merged.
-- =========================================================
dedup_prep AS (
  SELECT
    p.*,


    -- =====================================================
    -- DEDUP KEY
    -- =====================================================
    CASE

      -- ---------------------------------------------------
      -- Strong enough mother identity + actual HPHT
      -- ---------------------------------------------------
      WHEN tanggal_hpht_std IS NOT NULL
        AND mother_match_method != 'SOURCE_RECORD'

      THEN CONCAT(
        mother_source_key,
        '|HPHT|',
        CAST(tanggal_hpht_std AS STRING)
      )


      -- ---------------------------------------------------
      -- No HPHT or weak mother identity:
      -- preserve the source record separately.
      --
      -- This prevents incorrectly merging different
      -- pregnancies.
      -- ---------------------------------------------------
      ELSE CONCAT(
        'SOURCE|',
        source_record_id
      )

    END AS dedup_key,


    -- =====================================================
    -- DEDUP METHOD
    -- =====================================================
    CASE

      WHEN tanggal_hpht_std IS NOT NULL
        AND mother_match_method != 'SOURCE_RECORD'

      THEN CONCAT(
        mother_match_method,
        '+HPHT'
      )

      WHEN tanggal_hpht_std IS NULL
      THEN 'SOURCE_RECORD_FALLBACK_NO_HPHT'

      ELSE 'SOURCE_RECORD_FALLBACK_WEAK_IDENTITY'

    END AS dedup_method,


    -- =====================================================
    -- FILE UPLOAD TIMESTAMP
    -- =====================================================
    TIMESTAMP(
      file_dt_from_name,
      'Asia/Makassar'
    ) AS file_upload_ts

  FROM pregnancy p
),


-- =========================================================
-- 7. SELECT THE MOST RECENT VERSION OF EACH
--    MOTHER + HPHT PREGNANCY
-- =========================================================
ranked AS (
  SELECT
    d.*,

    ROW_NUMBER() OVER (
      PARTITION BY dedup_key

      ORDER BY
        ingestion_ts DESC NULLS LAST,
        file_upload_ts DESC NULLS LAST,
        file_date_ts DESC NULLS LAST,
        file_name DESC NULLS LAST,
        source_record_id DESC
    ) AS rn

  FROM dedup_prep d
)


-- =========================================================
-- 8. FINAL OUTPUT
-- =========================================================
SELECT
  * EXCEPT(
    rn,
    source_json,
    source_row_hash,
    file_dt_from_name
  ),


  -- =======================================================
  -- NORMALIZED DATE STRINGS
  -- =======================================================
  FORMAT_DATE(
    '%Y-%m-%d',
    tanggal_lahir_std
  ) AS tgl_lahir_norm,


  FORMAT_DATE(
    '%Y-%m-%d',
    tanggal_hpht_std
  ) AS tgl_hpht_norm,


  FORMAT_DATE(
    '%Y-%m-%d',
    tanggal_hpl_std
  ) AS tgl_hpl_norm,


  FORMAT_DATE(
    '%Y-%m-%d',
    tanggal_melahirkan_date
  ) AS tanggal_melahirkan_norm,


  FORMAT_DATE(
    '%Y-%m-%d',
    tanggal_abortus_date
  ) AS tanggal_abortus_norm,


  -- =======================================================
  -- SOURCE LABEL
  -- =======================================================
  'Sigizi Daftar Ibu' AS data_source

FROM ranked

WHERE rn = 1;

CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.vs_sigizi_daftar_ibu_hamil` AS
-- StandardSQL (BigQuery)
--
-- Purpose:
--   Clean, normalize, and deduplicate raw SIGIZI daftar ibu hamil.
--
-- Deduplication concept:
--   ONE MOTHER + ONE PROVIDED HPHT = ONE PREGNANCY
--
-- Mother identity hierarchy:
--   1. Valid 16-digit NIK
--   2. Nama + tanggal lahir + desa
--   3. Nama + tanggal lahir + puskesmas
--   4. Source record fallback
--
-- IMPORTANT:
--   - Pregnancy identity uses ONLY HPHT actually provided in the source.
--   - HPL is normalized and retained, but HPL - 280 days is NOT used
--     to infer pregnancy identity.
--   - If HPHT is unavailable, records are NOT automatically merged into
--     one pregnancy. Each source record remains separate.
--
-- Dedup winner:
--   1. Most recent file_date
--   2. Most recent ingestion_timestamp
--   3. Most complete record
--   4. Deterministic tie-breakers


WITH src AS (
  SELECT
    s.*,

    -- Stable fallback row hash
    FARM_FINGERPRINT(
      TO_JSON_STRING((SELECT AS STRUCT s.*))
    ) AS source_row_hash

  FROM
    `spheres-lombok-barat.raw_data.sigizi_daftar_ibu_hamil` s
),


-- ============================================================
-- 1. BASIC CLEANING
-- ============================================================
cleaned AS (
  SELECT
    s.*,

    -- --------------------------------------------------------
    -- NIK: digits only
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        COALESCE(CAST(nik AS STRING), ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS nik_digits,


    -- --------------------------------------------------------
    -- Name normalization
    --
    -- Examples:
    --   "SITI AMINAH"
    --   "Siti. Aminah"
    --   "SITI-AMINAH"
    --
    -- normalize toward:
    --   "siti aminah"
    -- --------------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            NORMALIZE_AND_CASEFOLD(
              COALESCE(CAST(nama AS STRING), '')
            ),
            r'[^\p{L}\p{N} ]',
            ' '
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS nama_norm,


    -- --------------------------------------------------------
    -- Desa normalization
    -- --------------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            NORMALIZE_AND_CASEFOLD(
              COALESCE(CAST(desakel AS STRING), '')
            ),
            r'[^\p{L}\p{N} ]',
            ' '
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS desa_norm,


    -- --------------------------------------------------------
    -- Puskesmas normalization
    -- --------------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            NORMALIZE_AND_CASEFOLD(
              COALESCE(CAST(puskesmas AS STRING), '')
            ),
            r'[^\p{L}\p{N} ]',
            ' '
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS puskesmas_norm,


    -- --------------------------------------------------------
    -- Preserve raw date strings before parsing
    -- --------------------------------------------------------
    NULLIF(
      TRIM(CAST(tgl_lahir AS STRING)),
      ''
    ) AS dob_raw,

    NULLIF(
      TRIM(CAST(tgl_hpht AS STRING)),
      ''
    ) AS hpht_raw,

    NULLIF(
      TRIM(CAST(tgl_hpl AS STRING)),
      ''
    ) AS hpl_raw

  FROM src s
),


-- ============================================================
-- 2. VALIDATE NIK + PARSE DATES
-- ============================================================
parsed AS (
  SELECT
    c.*,

    -- --------------------------------------------------------
    -- Valid NIK:
    --   exactly 16 digits
    --   reject obvious placeholder values
    -- --------------------------------------------------------
    CASE
      WHEN REGEXP_CONTAINS(
        nik_digits,
        r'^\d{16}$'
      )
      AND nik_digits NOT IN (
        '0000000000000000',
        '9999999999999999'
      )
      THEN nik_digits

      ELSE NULL
    END AS nik_clean,


    -- ========================================================
    -- DATE OF BIRTH
    -- ========================================================
    CASE

      -- Excel serial date
      WHEN REGEXP_CONTAINS(
        dob_raw,
        r'^\d{5}$'
      )
      THEN DATE_ADD(
        DATE '1899-12-30',
        INTERVAL SAFE_CAST(dob_raw AS INT64) DAY
      )

      ELSE COALESCE(

        -- YYYY-MM-DD
        SAFE.PARSE_DATE(
          '%Y-%m-%d',
          REGEXP_EXTRACT(
            dob_raw,
            r'(\d{4}-\d{2}-\d{2})'
          )
        ),

        -- YYYY/MM/DD
        SAFE.PARSE_DATE(
          '%Y/%m/%d',
          REGEXP_EXTRACT(
            dob_raw,
            r'(\d{4}/\d{2}/\d{2})'
          )
        ),

        -- DD/MM/YYYY
        SAFE.PARSE_DATE(
          '%d/%m/%Y',
          REGEXP_EXTRACT(
            dob_raw,
            r'(\d{2}/\d{2}/\d{4})'
          )
        ),

        -- DD-MM-YYYY
        SAFE.PARSE_DATE(
          '%d-%m-%Y',
          REGEXP_EXTRACT(
            dob_raw,
            r'(\d{2}-\d{2}-\d{4})'
          )
        ),

        -- DD.MM.YYYY
        SAFE.PARSE_DATE(
          '%d.%m.%Y',
          REGEXP_EXTRACT(
            dob_raw,
            r'(\d{2}\.\d{2}\.\d{4})'
          )
        )
      )

    END AS tanggal_lahir_std,


    -- ========================================================
    -- HPHT
    -- ========================================================
    CASE

      -- Excel serial date
      WHEN REGEXP_CONTAINS(
        hpht_raw,
        r'^\d{5}$'
      )
      THEN DATE_ADD(
        DATE '1899-12-30',
        INTERVAL SAFE_CAST(hpht_raw AS INT64) DAY
      )

      ELSE COALESCE(

        SAFE.PARSE_DATE(
          '%Y-%m-%d',
          REGEXP_EXTRACT(
            hpht_raw,
            r'(\d{4}-\d{2}-\d{2})'
          )
        ),

        SAFE.PARSE_DATE(
          '%Y/%m/%d',
          REGEXP_EXTRACT(
            hpht_raw,
            r'(\d{4}/\d{2}/\d{2})'
          )
        ),

        SAFE.PARSE_DATE(
          '%d/%m/%Y',
          REGEXP_EXTRACT(
            hpht_raw,
            r'(\d{2}/\d{2}/\d{4})'
          )
        ),

        SAFE.PARSE_DATE(
          '%d-%m-%Y',
          REGEXP_EXTRACT(
            hpht_raw,
            r'(\d{2}-\d{2}-\d{4})'
          )
        ),

        SAFE.PARSE_DATE(
          '%d.%m.%Y',
          REGEXP_EXTRACT(
            hpht_raw,
            r'(\d{2}\.\d{2}\.\d{4})'
          )
        )
      )

    END AS tanggal_hpht_std,


    -- ========================================================
    -- HPL
    --
    -- HPL is normalized for information/reporting only.
    -- It is NOT used to derive pregnancy HPHT.
    -- ========================================================
    CASE

      -- Excel serial date
      WHEN REGEXP_CONTAINS(
        hpl_raw,
        r'^\d{5}$'
      )
      THEN DATE_ADD(
        DATE '1899-12-30',
        INTERVAL SAFE_CAST(hpl_raw AS INT64) DAY
      )

      ELSE COALESCE(

        SAFE.PARSE_DATE(
          '%Y-%m-%d',
          REGEXP_EXTRACT(
            hpl_raw,
            r'(\d{4}-\d{2}-\d{2})'
          )
        ),

        SAFE.PARSE_DATE(
          '%Y/%m/%d',
          REGEXP_EXTRACT(
            hpl_raw,
            r'(\d{4}/\d{2}/\d{2})'
          )
        ),

        SAFE.PARSE_DATE(
          '%d/%m/%Y',
          REGEXP_EXTRACT(
            hpl_raw,
            r'(\d{2}/\d{2}/\d{4})'
          )
        ),

        SAFE.PARSE_DATE(
          '%d-%m-%Y',
          REGEXP_EXTRACT(
            hpl_raw,
            r'(\d{2}-\d{2}-\d{4})'
          )
        ),

        SAFE.PARSE_DATE(
          '%d.%m.%Y',
          REGEXP_EXTRACT(
            hpl_raw,
            r'(\d{2}\.\d{2}\.\d{4})'
          )
        )
      )

    END AS tanggal_hpl_std,


    -- ========================================================
    -- SOURCE FILE DATE
    -- ========================================================
    COALESCE(

      SAFE_CAST(
        NULLIF(
          TRIM(CAST(file_date AS STRING)),
          ''
        )
        AS DATE
      ),

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          CAST(file_date AS STRING),
          r'(\d{4}-\d{2}-\d{2})'
        )
      )

    ) AS file_date_date,


    -- ========================================================
    -- INGESTION TIMESTAMP
    -- ========================================================
    COALESCE(

      SAFE_CAST(
        NULLIF(
          TRIM(CAST(ingestion_timestamp AS STRING)),
          ''
        )
        AS TIMESTAMP
      ),

      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%d %H:%M:%E*S',
        NULLIF(
          TRIM(CAST(ingestion_timestamp AS STRING)),
          ''
        )
      ),

      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%dT%H:%M:%E*S',
        NULLIF(
          TRIM(CAST(ingestion_timestamp AS STRING)),
          ''
        )
      )

    ) AS ingestion_ts

  FROM cleaned c
),


-- ============================================================
-- 3. IDENTIFY MOTHER
-- ============================================================
identity AS (
  SELECT
    p.*,

    -- --------------------------------------------------------
    -- NIK validity flag
    -- --------------------------------------------------------
    nik_clean IS NOT NULL AS flag_nik_valid,


    -- --------------------------------------------------------
    -- Stable source record identifier
    --
    -- Preference:
    --   UUID
    --   hash_code
    --   source row fingerprint
    -- --------------------------------------------------------
    COALESCE(
      NULLIF(
        TRIM(CAST(uuid AS STRING)),
        ''
      ),
      NULLIF(
        TRIM(CAST(hash_code AS STRING)),
        ''
      ),
      CAST(source_row_hash AS STRING)
    ) AS source_record_id,


    -- ========================================================
    -- MOTHER IDENTITY KEY
    -- ========================================================
    CASE

      -- ------------------------------------------------------
      -- 1. Valid NIK
      -- ------------------------------------------------------
      WHEN nik_clean IS NOT NULL
      THEN CONCAT(
        'NIK|',
        nik_clean
      )


      -- ------------------------------------------------------
      -- 2. Name + DOB + Desa
      -- ------------------------------------------------------
      WHEN
        nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND desa_norm IS NOT NULL

      THEN CONCAT(
        'NAME_DOB_DESA|',
        nama_norm,
        '|',
        CAST(tanggal_lahir_std AS STRING),
        '|',
        desa_norm
      )


      -- ------------------------------------------------------
      -- 3. Name + DOB + Puskesmas
      -- ------------------------------------------------------
      WHEN
        nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND puskesmas_norm IS NOT NULL

      THEN CONCAT(
        'NAME_DOB_PKM|',
        nama_norm,
        '|',
        CAST(tanggal_lahir_std AS STRING),
        '|',
        puskesmas_norm
      )


      -- ------------------------------------------------------
      -- 4. Weak identity:
      --    do not merge with other source records
      -- ------------------------------------------------------
      ELSE CONCAT(
        'SOURCE|',
        COALESCE(
          NULLIF(
            TRIM(CAST(uuid AS STRING)),
            ''
          ),
          NULLIF(
            TRIM(CAST(hash_code AS STRING)),
            ''
          ),
          CAST(source_row_hash AS STRING)
        )
      )

    END AS mother_source_key,


    -- ========================================================
    -- MOTHER MATCH METHOD
    -- ========================================================
    CASE

      WHEN nik_clean IS NOT NULL
        THEN 'NIK'

      WHEN
        nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND desa_norm IS NOT NULL
        THEN 'NAMA+DOB+DESA'

      WHEN
        nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND puskesmas_norm IS NOT NULL
        THEN 'NAMA+DOB+PUSKESMAS'

      ELSE 'SOURCE_RECORD'

    END AS mother_match_method,


    -- ========================================================
    -- PREGNANCY ANCHOR
    --
    -- IMPORTANT:
    -- Only actual HPHT provided by SIGIZI is allowed.
    --
    -- DO NOT derive HPHT from HPL.
    -- ========================================================
    tanggal_hpht_std AS pregnancy_anchor_date,


    CASE
      WHEN tanggal_hpht_std IS NOT NULL
        THEN 'HPHT'

      ELSE 'NO_PREGNANCY_DATE'
    END AS pregnancy_anchor_type

  FROM parsed p
),


-- ============================================================
-- 4. BUILD PREGNANCY DEDUP KEY + COMPLETENESS SCORE
-- ============================================================
scored AS (
  SELECT
    i.*,


    -- ========================================================
    -- DEDUP KEY
    --
    -- Known mother + provided HPHT:
    --   same mother + same exact HPHT = same pregnancy
    --
    -- Missing HPHT:
    --   retain individual source record
    -- ========================================================
    CASE

      WHEN
        pregnancy_anchor_date IS NOT NULL
        AND mother_match_method != 'SOURCE_RECORD'

      THEN CONCAT(
        mother_source_key,
        '|PREG|',
        CAST(pregnancy_anchor_date AS STRING)
      )

      ELSE CONCAT(
        'SOURCE|',
        source_record_id
      )

    END AS dedup_key,


    -- ========================================================
    -- DEDUP METHOD
    -- ========================================================
    CASE

      WHEN
        pregnancy_anchor_date IS NOT NULL
        AND mother_match_method != 'SOURCE_RECORD'

      THEN CONCAT(
        mother_match_method,
        '+HPHT'
      )

      WHEN
        pregnancy_anchor_date IS NULL
        AND mother_match_method != 'SOURCE_RECORD'

      THEN CONCAT(
        mother_match_method,
        '+NO_HPHT_SOURCE_RECORD_FALLBACK'
      )

      ELSE 'SOURCE_RECORD_FALLBACK'

    END AS dedup_method,


    -- ========================================================
    -- COMPLETENESS SCORE
    --
    -- Used only after source recency when selecting among
    -- duplicate records for the exact same pregnancy.
    -- ========================================================
    (
      IF(
        nik_clean IS NOT NULL,
        3,
        0
      )

      + IF(
          nama_norm IS NOT NULL,
          3,
          0
        )

      + IF(
          tanggal_lahir_std IS NOT NULL,
          2,
          0
        )

      + IF(
          tanggal_hpht_std IS NOT NULL,
          3,
          0
        )

      + IF(
          tanggal_hpl_std IS NOT NULL,
          2,
          0
        )

      + IF(
          NULLIF(
            TRIM(CAST(nama_suami AS STRING)),
            ''
          ) IS NOT NULL,
          1,
          0
        )

      + IF(
          NULLIF(
            TRIM(CAST(usia_saat_hamil AS STRING)),
            ''
          ) IS NOT NULL,
          1,
          0
        )

      + IF(
          NULLIF(
            TRIM(CAST(kehamilan_ke_berapa_g AS STRING)),
            ''
          ) IS NOT NULL,
          1,
          0
        )

      + IF(
          NULLIF(
            TRIM(CAST(paritas_p AS STRING)),
            ''
          ) IS NOT NULL,
          1,
          0
        )

      + IF(
          NULLIF(
            TRIM(CAST(abortus_a AS STRING)),
            ''
          ) IS NOT NULL,
          1,
          0
        )

      + IF(
          NULLIF(
            TRIM(
              CAST(
                berat_badan_sebelum_hamil_kg
                AS STRING
              )
            ),
            ''
          ) IS NOT NULL,
          1,
          0
        )

      + IF(
          NULLIF(
            TRIM(
              CAST(
                tinggi_badan_sebelum_hamil_cm
                AS STRING
              )
            ),
            ''
          ) IS NOT NULL,
          1,
          0
        )

      + IF(
          NULLIF(
            TRIM(CAST(imt AS STRING)),
            ''
          ) IS NOT NULL,
          1,
          0
        )

      + IF(
          NULLIF(
            TRIM(CAST(lila AS STRING)),
            ''
          ) IS NOT NULL,
          1,
          0
        )

      + IF(
          NULLIF(
            TRIM(
              CAST(
                status_kek_tidak_kek
                AS STRING
              )
            ),
            ''
          ) IS NOT NULL,
          1,
          0
        )

      + IF(
          puskesmas_norm IS NOT NULL,
          1,
          0
        )

      + IF(
          desa_norm IS NOT NULL,
          1,
          0
        )

      + IF(
          NULLIF(
            TRIM(CAST(posyandu AS STRING)),
            ''
          ) IS NOT NULL,
          1,
          0
        )

      + IF(
          NULLIF(
            TRIM(CAST(tindakan AS STRING)),
            ''
          ) IS NOT NULL,
          1,
          0
        )

    ) AS completeness_score

  FROM identity i
),


-- ============================================================
-- 5. SELECT BEST RECORD PER MOTHER + PREGNANCY
-- ============================================================
ranked AS (
  SELECT
    s.*,

    ROW_NUMBER() OVER (
      PARTITION BY dedup_key

      ORDER BY

        -- ----------------------------------------------------
        -- Prefer latest source snapshot
        -- ----------------------------------------------------
        file_date_date DESC NULLS LAST,

        ingestion_ts DESC NULLS LAST,


        -- ----------------------------------------------------
        -- If same snapshot, prefer more complete record
        -- ----------------------------------------------------
        completeness_score DESC,


        -- ----------------------------------------------------
        -- Deterministic tie-breakers
        -- ----------------------------------------------------
        file_name DESC,

        source_record_id DESC

    ) AS rn

  FROM scored s
)


-- ============================================================
-- 6. FINAL OUTPUT
-- ============================================================
SELECT
  * EXCEPT(
    rn,
    source_row_hash,
    nik_digits,
    dob_raw,
    hpht_raw,
    hpl_raw
  ),


  -- Stable HPHT text key for downstream joins/debugging
  FORMAT_DATE(
    '%Y-%m-%d',
    tanggal_hpht_std
  ) AS tgl_hpht_key,


  'Sigizi Daftar Ibu Hamil' AS data_source

FROM ranked

WHERE rn = 1;

CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.vs_sigizi_kohort_ibu` AS
-- StandardSQL
-- CREATE OR REPLACE VIEW
-- `spheres-lombok-barat.kohort_bumil_v3.vs_sigizi_kohort_ibu` AS


WITH src AS (
  SELECT
    t.* EXCEPT(
      file_date,
      status_persalinan_lahir_hidup_lahir_mati
    ),


    -- =====================================================
    -- CLEAN BIRTH OUTCOME
    --
    -- "-"   -> NULL
    -- blank -> NULL
    -- otherwise preserve the original value
    -- =====================================================
    CASE
      WHEN NULLIF(
        TRIM(
          CAST(
            t.status_persalinan_lahir_hidup_lahir_mati
            AS STRING
          )
        ),
        ''
      ) IS NULL
        THEN NULL

      WHEN TRIM(
        CAST(
          t.status_persalinan_lahir_hidup_lahir_mati
          AS STRING
        )
      ) = '-'
        THEN NULL

      ELSE TRIM(
        CAST(
          t.status_persalinan_lahir_hidup_lahir_mati
          AS STRING
        )
      )
    END AS status_persalinan_lahir_hidup_lahir_mati,


    -- =====================================================
    -- ORIGINAL FILE METADATA
    -- =====================================================
    NULLIF(
      TRIM(CAST(t.file_date AS STRING)),
      ''
    ) AS file_date_raw,


    -- Keep original row for flexible field extraction
    TO_JSON_STRING(t) AS source_json,


    -- Stable row hash fallback
    FARM_FINGERPRINT(
      TO_JSON_STRING(
        (SELECT AS STRUCT t.*)
      )
    ) AS source_row_hash,


    -- =====================================================
    -- INGESTION TIMESTAMP
    -- =====================================================
    COALESCE(
      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%d %H:%M:%E*S',
        NULLIF(
          TRIM(CAST(ingestion_timestamp AS STRING)),
          ''
        )
      ),

      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%dT%H:%M:%E*S',
        NULLIF(
          TRIM(CAST(ingestion_timestamp AS STRING)),
          ''
        )
      ),

      SAFE_CAST(
        NULLIF(
          TRIM(CAST(ingestion_timestamp AS STRING)),
          ''
        )
        AS TIMESTAMP
      )
    ) AS ingestion_ts,


    -- =====================================================
    -- FILE DATETIME FROM FILE NAME
    -- =====================================================
    COALESCE(
      SAFE.PARSE_DATETIME(
        '%Y-%m-%d %H:%M:%E*S',
        REPLACE(
          REGEXP_EXTRACT(
            CAST(file_name AS STRING),
            r'(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
          ),
          'T',
          ' '
        )
      ),

      DATETIME(
        SAFE.PARSE_DATE(
          '%Y-%m-%d',
          REGEXP_EXTRACT(
            CAST(file_name AS STRING),
            r'(\d{4}-\d{2}-\d{2})'
          )
        )
      )
    ) AS file_dt_from_name

  FROM
    `spheres-lombok-barat.raw_data.sigizi_kohort_ibu` t
),



-- =========================================================
-- 1. EXTRACT RAW VALUES
-- =========================================================
raw_values AS (
  SELECT
    s.*,


    -- =====================================================
    -- NIK
    -- =====================================================
    COALESCE(
      NULLIF(
        TRIM(JSON_VALUE(source_json, '$.nik')),
        ''
      ),

      NULLIF(
        TRIM(JSON_VALUE(source_json, '$.nik_ibu')),
        ''
      )
    ) AS nik_raw_std,


    -- =====================================================
    -- NAME
    -- =====================================================
    NULLIF(
      TRIM(CAST(nama AS STRING)),
      ''
    ) AS nama_raw_std,


    -- =====================================================
    -- DATE OF BIRTH
    -- =====================================================
    COALESCE(
      NULLIF(
        TRIM(JSON_VALUE(source_json, '$.tgl_lahir')),
        ''
      ),

      NULLIF(
        TRIM(JSON_VALUE(source_json, '$.tanggal_lahir')),
        ''
      ),

      NULLIF(
        TRIM(JSON_VALUE(source_json, '$.tanggal_lahir_ibu')),
        ''
      )
    ) AS dob_raw,


    -- =====================================================
    -- HPHT
    --
    -- IMPORTANT:
    -- Only the HPHT actually provided by SIGIZI is used.
    -- No HPHT will be calculated from HPL or delivery date.
    -- =====================================================
    COALESCE(
      NULLIF(
        TRIM(JSON_VALUE(source_json, '$.tgl_hpht')),
        ''
      ),

      NULLIF(
        TRIM(JSON_VALUE(source_json, '$.tanggal_hpht')),
        ''
      ),

      NULLIF(
        TRIM(JSON_VALUE(source_json, '$.hpht')),
        ''
      )
    ) AS hpht_raw,


    -- =====================================================
    -- HPL
    --
    -- Retained as an independent normalized date.
    -- It is NOT converted into HPHT in this view.
    -- =====================================================
    COALESCE(
      NULLIF(
        TRIM(JSON_VALUE(source_json, '$.tgl_hpl')),
        ''
      ),

      NULLIF(
        TRIM(JSON_VALUE(source_json, '$.tanggal_hpl')),
        ''
      ),

      NULLIF(
        TRIM(JSON_VALUE(source_json, '$.hpl')),
        ''
      ),

      NULLIF(
        TRIM(
          JSON_VALUE(
            source_json,
            '$.tanggal_perkiraan_persalinan'
          )
        ),
        ''
      )
    ) AS hpl_raw,


    -- =====================================================
    -- DELIVERY DATE
    --
    -- status_persalinan_tanggal_melahirkan is the primary
    -- delivery-date field in SIGIZI Kohort Ibu.
    -- =====================================================
    COALESCE(

      NULLIF(
        TRIM(
          CAST(
            status_persalinan_tanggal_melahirkan
            AS STRING
          )
        ),
        ''
      ),

      NULLIF(
        TRIM(
          JSON_VALUE(
            source_json,
            '$.tanggal_melahirkan'
          )
        ),
        ''
      ),

      NULLIF(
        TRIM(
          JSON_VALUE(
            source_json,
            '$.tgl_melahirkan'
          )
        ),
        ''
      ),

      NULLIF(
        TRIM(
          JSON_VALUE(
            source_json,
            '$.tanggal_persalinan'
          )
        ),
        ''
      )

    ) AS delivery_raw,


    -- =====================================================
    -- ABORTUS DATE
    --
    -- Retained as its own actual source date.
    -- It is NOT transformed into an estimated HPHT.
    -- =====================================================
    COALESCE(
      NULLIF(
        TRIM(
          JSON_VALUE(
            source_json,
            '$.tanggal_abortus'
          )
        ),
        ''
      ),

      NULLIF(
        TRIM(
          JSON_VALUE(
            source_json,
            '$.tgl_abortus'
          )
        ),
        ''
      )
    ) AS abortion_raw,


    -- =====================================================
    -- LOCATION: DESA
    -- =====================================================
    COALESCE(
      NULLIF(
        TRIM(CAST(desakel AS STRING)),
        ''
      ),

      NULLIF(
        TRIM(JSON_VALUE(source_json, '$.desakel')),
        ''
      ),

      NULLIF(
        TRIM(JSON_VALUE(source_json, '$.desa')),
        ''
      )
    ) AS desa_raw_std,


    -- =====================================================
    -- LOCATION: PUSKESMAS
    --
    -- Extract through JSON so either:
    --   pukesmas
    --   puskesmas
    -- can be handled without hardcoding the typo.
    -- =====================================================
    COALESCE(
      NULLIF(
        TRIM(JSON_VALUE(source_json, '$.pukesmas')),
        ''
      ),

      NULLIF(
        TRIM(JSON_VALUE(source_json, '$.puskesmas')),
        ''
      )
    ) AS puskesmas_raw_std

  FROM src s
),



-- =========================================================
-- 2. CLEAN IDENTITY / LOCATION
-- =========================================================
cleaned AS (
  SELECT
    r.*,


    -- =====================================================
    -- NIK DIGITS ONLY
    -- =====================================================
    NULLIF(
      REGEXP_REPLACE(
        COALESCE(nik_raw_std, ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS nik_digits,


    -- =====================================================
    -- NORMALIZED NAME
    -- =====================================================
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(nama_raw_std, '')
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS nama_norm,


    -- =====================================================
    -- NORMALIZED DESA
    -- =====================================================
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(desa_raw_std, '')
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS desa_norm,


    -- =====================================================
    -- NORMALIZED PUSKESMAS
    -- =====================================================
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(puskesmas_raw_std, '')
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS puskesmas_norm

  FROM raw_values r
),



-- =========================================================
-- 3. PARSE DATES
-- =========================================================
parsed AS (
  SELECT
    c.*,


    -- =====================================================
    -- VALID NIK
    -- =====================================================
    CASE
      WHEN REGEXP_CONTAINS(
        nik_digits,
        r'^\d{16}$'
      )
      AND nik_digits NOT IN (
        '0000000000000000',
        '9999999999999999'
      )
      THEN nik_digits

      ELSE NULL
    END AS nik_clean,


    -- =====================================================
    -- DOB
    -- =====================================================
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          dob_raw,
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          dob_raw,
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          dob_raw,
          r'(\d{2}-\d{2}-\d{4})'
        )
      )
    ) AS tanggal_lahir_std,


    -- =====================================================
    -- HPHT
    --
    -- Actual provided HPHT only.
    -- =====================================================
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          hpht_raw,
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          hpht_raw,
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          hpht_raw,
          r'(\d{2}-\d{2}-\d{4})'
        )
      )
    ) AS tanggal_hpht_std,


    -- =====================================================
    -- HPL
    -- =====================================================
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          hpl_raw,
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          hpl_raw,
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          hpl_raw,
          r'(\d{2}-\d{2}-\d{4})'
        )
      )
    ) AS tanggal_hpl_std,


    -- =====================================================
    -- DELIVERY DATE
    --
    -- Handles:
    -- 2026-02-24
    -- 2025-08-09 00:00:00
    -- 09/08/2025
    -- 09-08-2025
    -- =====================================================
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          delivery_raw,
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          delivery_raw,
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          delivery_raw,
          r'(\d{2}-\d{2}-\d{4})'
        )
      )
    ) AS tanggal_melahirkan_std,


    -- =====================================================
    -- ABORTUS DATE
    -- =====================================================
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          abortion_raw,
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          abortion_raw,
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          abortion_raw,
          r'(\d{2}-\d{2}-\d{4})'
        )
      )
    ) AS tanggal_abortus_std,


    -- =====================================================
    -- ORIGINAL FILE DATE AS TIMESTAMP
    --
    -- Used only as an additional recency/order signal.
    -- =====================================================
    COALESCE(
      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%d %H:%M:%E*S',
        file_date_raw,
        'Asia/Makassar'
      ),

      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%dT%H:%M:%E*S',
        file_date_raw,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        SAFE.PARSE_DATE(
          '%Y-%m-%d',
          REGEXP_EXTRACT(
            file_date_raw,
            r'(\d{4}-\d{2}-\d{2})'
          )
        ),
        'Asia/Makassar'
      ),

      SAFE_CAST(
        file_date_raw
        AS TIMESTAMP
      )
    ) AS file_date_ts

  FROM cleaned c
),



-- =========================================================
-- 4. IDENTITY + PREGNANCY INFORMATION
-- =========================================================
identity AS (
  SELECT
    p.*,


    -- =====================================================
    -- NIK QUALITY FLAG
    -- =====================================================
    nik_clean IS NOT NULL AS flag_nik_valid,


    -- =====================================================
    -- SOURCE RECORD ID
    -- =====================================================
    COALESCE(
      NULLIF(
        TRIM(CAST(uuid AS STRING)),
        ''
      ),

      CAST(source_row_hash AS STRING)
    ) AS source_record_id,


    -- =====================================================
    -- MOTHER IDENTITY
    --
    -- Priority:
    -- 1. NIK
    -- 2. Name + DOB + Desa
    -- 3. Name + DOB + Puskesmas
    -- 4. Individual source record
    --
    -- Weak-identity records are NOT discarded.
    -- =====================================================
    CASE

      WHEN nik_clean IS NOT NULL
      THEN CONCAT(
        'NIK|',
        nik_clean
      )


      WHEN nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND desa_norm IS NOT NULL

      THEN CONCAT(
        'NAME_DOB_DESA|',
        nama_norm,
        '|',
        CAST(tanggal_lahir_std AS STRING),
        '|',
        desa_norm
      )


      WHEN nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND puskesmas_norm IS NOT NULL

      THEN CONCAT(
        'NAME_DOB_PKM|',
        nama_norm,
        '|',
        CAST(tanggal_lahir_std AS STRING),
        '|',
        puskesmas_norm
      )


      ELSE CONCAT(
        'SOURCE|',
        COALESCE(
          NULLIF(
            TRIM(CAST(uuid AS STRING)),
            ''
          ),

          CAST(source_row_hash AS STRING)
        )
      )

    END AS mother_source_key,


    -- =====================================================
    -- MOTHER MATCH METHOD
    -- =====================================================
    CASE
      WHEN nik_clean IS NOT NULL
        THEN 'NIK'

      WHEN nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND desa_norm IS NOT NULL
        THEN 'NAMA+DOB+DESA'

      WHEN nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND puskesmas_norm IS NOT NULL
        THEN 'NAMA+DOB+PUSKESMAS'

      ELSE 'SOURCE_RECORD'
    END AS mother_match_method,


    -- =====================================================
    -- PREGNANCY ANCHOR
    --
    -- IMPORTANT:
    -- ONLY actual source HPHT is allowed to become the
    -- pregnancy anchor in this normalized source view.
    --
    -- HPL / delivery / abortion remain independent fields
    -- for later cross-source pregnancy assignment.
    -- =====================================================
    tanggal_hpht_std AS pregnancy_anchor_date,


    CASE
      WHEN tanggal_hpht_std IS NOT NULL
        THEN 'HPHT'

      ELSE 'NO_HPHT'
    END AS pregnancy_anchor_type,


    -- =====================================================
    -- STANDARDIZED PREGNANCY / OUTCOME EVENT
    --
    -- This does NOT infer dates or outcome.
    -- It only describes the actual event date available.
    -- =====================================================
    CASE
      WHEN tanggal_melahirkan_std IS NOT NULL
        THEN 'Melahirkan'

      WHEN tanggal_abortus_std IS NOT NULL
        THEN 'Abortus'

      ELSE NULL
    END AS pregnancy_event_status

  FROM parsed p
),



-- =========================================================
-- 5. SOURCE-LEVEL PREGNANCY DEDUP
--
-- RULE:
--
-- known mother + actual HPHT
--     -> deduplicate by mother + HPHT
--
-- no actual HPHT
--     -> keep as separate source record
--
-- We DO NOT derive pregnancy identity from:
--   HPL - 280 days
--   delivery - 280 days
--   abortus date
--
-- These will be handled by the later pregnancy-assignment
-- layer across SIGIZI sources.
-- =========================================================
dedup_prep AS (
  SELECT
    i.*,


    -- =====================================================
    -- DEDUP KEY
    -- =====================================================
    CASE
      WHEN pregnancy_anchor_date IS NOT NULL
        AND mother_match_method != 'SOURCE_RECORD'

      THEN CONCAT(
        mother_source_key,
        '|HPHT|',
        CAST(
          pregnancy_anchor_date
          AS STRING
        )
      )

      ELSE CONCAT(
        'SOURCE|',
        source_record_id
      )

    END AS dedup_key,


    -- =====================================================
    -- DEDUP METHOD
    -- =====================================================
    CASE
      WHEN pregnancy_anchor_date IS NOT NULL
        AND mother_match_method != 'SOURCE_RECORD'

      THEN CONCAT(
        mother_match_method,
        '+HPHT'
      )

      ELSE 'SOURCE_RECORD_FALLBACK'
    END AS dedup_method,


    -- =====================================================
    -- STANDARDIZED FILE DATE
    --
    -- Prefer datetime extracted from filename.
    -- Fall back to original file_date value.
    -- =====================================================
    COALESCE(
      FORMAT_DATETIME(
        '%Y-%m-%dT%H:%M:%E6S',
        file_dt_from_name
      ),

      file_date_raw
    ) AS file_date,


    -- =====================================================
    -- FILE UPLOAD TIMESTAMP FROM FILE NAME
    -- =====================================================
    TIMESTAMP(
      file_dt_from_name,
      'Asia/Makassar'
    ) AS file_upload_ts

  FROM identity i
),



-- =========================================================
-- 6. SELECT LATEST DUPLICATE
-- =========================================================
ranked AS (
  SELECT
    d.*,


    ROW_NUMBER() OVER (
      PARTITION BY dedup_key

      ORDER BY
        ingestion_ts DESC NULLS LAST,
        file_upload_ts DESC NULLS LAST,
        file_date_ts DESC NULLS LAST,
        file_name DESC NULLS LAST,
        source_record_id DESC
    ) AS rn

  FROM dedup_prep d
)



-- =========================================================
-- 7. FINAL
-- =========================================================
SELECT
  * EXCEPT(
    rn,

    source_json,
    source_row_hash,

    file_dt_from_name,
    file_date_ts,

    file_date_raw,

    nik_raw_std,
    nama_raw_std,

    dob_raw,
    hpht_raw,
    hpl_raw,
    delivery_raw,
    abortion_raw,

    desa_raw_std,
    puskesmas_raw_std
  ),


  'Sigizi Kohort Ibu' AS data_source

FROM ranked

WHERE rn = 1;

CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.vs_sigizi_kohort_nifas` AS
WITH src AS (
  SELECT
    s.*,

    TO_JSON_STRING(s) AS source_json,

    FARM_FINGERPRINT(
      TO_JSON_STRING(
        (SELECT AS STRUCT s.*)
      )
    ) AS source_row_hash

  FROM
    `spheres-lombok-barat.raw_data.sigizi_ibu_nifas` s
),


-- ============================================================
-- 1. STANDARDIZE RAW VALUES
-- ============================================================
raw_values AS (
  SELECT
    s.*,

    NULLIF(
      TRIM(CAST(nik AS STRING)),
      ''
    ) AS nik_raw_std,

    NULLIF(
      TRIM(CAST(nama AS STRING)),
      ''
    ) AS nama_raw_std,

    NULLIF(
      TRIM(CAST(desakel AS STRING)),
      ''
    ) AS desa_raw_std,

    COALESCE(
      NULLIF(
        TRIM(CAST(puskesmas AS STRING)),
        ''
      ),
      NULLIF(
        TRIM(CAST(puskesmas_name AS STRING)),
        ''
      ),
      NULLIF(
        JSON_VALUE(source_json, '$.pukesmas'),
        ''
      )
    ) AS puskesmas_raw_std,


    -- ========================================================
    -- DATE RAW VALUES
    -- ========================================================

    COALESCE(
      NULLIF(
        TRIM(CAST(tgl_lahir AS STRING)),
        ''
      ),
      NULLIF(
        JSON_VALUE(source_json, '$.tanggal_lahir'),
        ''
      )
    ) AS dob_raw,


    -- HPHT IS THE ONLY PREGNANCY IDENTITY DATE
    NULLIF(
      TRIM(CAST(tgl_hpht AS STRING)),
      ''
    ) AS hpht_raw,


    -- Kept for schema compatibility if it appears in source
    COALESCE(
      NULLIF(
        JSON_VALUE(source_json, '$.tgl_hpl'),
        ''
      ),
      NULLIF(
        JSON_VALUE(source_json, '$.tanggal_hpl'),
        ''
      ),
      NULLIF(
        JSON_VALUE(source_json, '$.hpl'),
        ''
      )
    ) AS hpl_raw,


    COALESCE(
      NULLIF(
        TRIM(CAST(tgl_melahirkan AS STRING)),
        ''
      ),
      NULLIF(
        JSON_VALUE(source_json, '$.tanggal_melahirkan'),
        ''
      ),
      NULLIF(
        JSON_VALUE(source_json, '$.tanggal_persalinan'),
        ''
      )
    ) AS delivery_raw,


    COALESCE(
      NULLIF(
        TRIM(CAST(tgl_abortus AS STRING)),
        ''
      ),
      NULLIF(
        JSON_VALUE(source_json, '$.tanggal_abortus'),
        ''
      )
    ) AS abortion_raw,


    NULLIF(
      TRIM(CAST(status AS STRING)),
      ''
    ) AS status_raw_std

  FROM src s
),


-- ============================================================
-- 2. NORMALIZE IDENTITY / LOCATION
-- ============================================================
cleaned AS (
  SELECT
    r.*,

    -- --------------------------------------------------------
    -- NIK: digits only
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        COALESCE(nik_raw_std, ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS nik_digits,


    -- --------------------------------------------------------
    -- NAME
    -- --------------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(nama_raw_std, '')
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS nama_norm,


    -- --------------------------------------------------------
    -- DESA
    -- --------------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(desa_raw_std, '')
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS desa_norm,


    -- --------------------------------------------------------
    -- PUSKESMAS
    -- --------------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(puskesmas_raw_std, '')
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS puskesmas_norm

  FROM raw_values r
),


-- ============================================================
-- 3. PARSE DATES
-- ============================================================
parsed AS (
  SELECT
    c.*,

    -- --------------------------------------------------------
    -- VALID NIK
    -- --------------------------------------------------------
    CASE
      WHEN REGEXP_CONTAINS(
        nik_digits,
        r'^\d{16}$'
      )
      AND nik_digits NOT IN (
        '0000000000000000',
        '9999999999999999'
      )
      THEN nik_digits

      ELSE NULL
    END AS nik_clean,


    -- --------------------------------------------------------
    -- DATE OF BIRTH
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          dob_raw,
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          dob_raw,
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          dob_raw,
          r'(\d{2}-\d{2}-\d{4})'
        )
      )
    ) AS tanggal_lahir_std,


    -- --------------------------------------------------------
    -- HPHT
    --
    -- IMPORTANT:
    -- This is the ONLY date used to define pregnancy identity.
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          hpht_raw,
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          hpht_raw,
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          hpht_raw,
          r'(\d{2}-\d{2}-\d{4})'
        )
      )
    ) AS tanggal_hpht_std,


    -- --------------------------------------------------------
    -- HPL
    --
    -- Normalized only.
    -- NOT used for pregnancy matching.
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          hpl_raw,
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          hpl_raw,
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          hpl_raw,
          r'(\d{2}-\d{2}-\d{4})'
        )
      )
    ) AS tanggal_hpl_std,


    -- --------------------------------------------------------
    -- DELIVERY DATE
    --
    -- Normalized only.
    -- NOT used to calculate pregnancy identity.
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          delivery_raw,
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          delivery_raw,
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          delivery_raw,
          r'(\d{2}-\d{2}-\d{4})'
        )
      )
    ) AS tanggal_melahirkan_std,


    -- --------------------------------------------------------
    -- ABORTUS DATE
    --
    -- Normalized only.
    -- NOT used for pregnancy identity.
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          abortion_raw,
          r'(\d{4}-\d{2}-\d{2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          abortion_raw,
          r'(\d{2}/\d{2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          abortion_raw,
          r'(\d{2}-\d{2}-\d{4})'
        )
      )
    ) AS tanggal_abortus_std,


    -- --------------------------------------------------------
    -- INGESTION TIMESTAMP
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%d %H:%M:%E*S',
        NULLIF(
          TRIM(
            CAST(
              ingestion_timestamp AS STRING
            )
          ),
          ''
        )
      ),

      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%dT%H:%M:%E*S',
        NULLIF(
          TRIM(
            CAST(
              ingestion_timestamp AS STRING
            )
          ),
          ''
        )
      ),

      SAFE_CAST(
        NULLIF(
          TRIM(
            CAST(
              ingestion_timestamp AS STRING
            )
          ),
          ''
        )
        AS TIMESTAMP
      )
    ) AS ingestion_ts,


    -- --------------------------------------------------------
    -- FILE DATETIME FROM FILE NAME
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATETIME(
        '%Y-%m-%d %H:%M:%E*S',
        REPLACE(
          REGEXP_EXTRACT(
            CAST(file_name AS STRING),
            r'(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
          ),
          'T',
          ' '
        )
      ),

      DATETIME(
        SAFE.PARSE_DATE(
          '%Y-%m-%d',
          REGEXP_EXTRACT(
            CAST(file_name AS STRING),
            r'(\d{4}-\d{2}-\d{2})'
          )
        )
      )
    ) AS file_dt_from_name

  FROM cleaned c
),


-- ============================================================
-- 4. MOTHER IDENTITY
-- ============================================================
identity AS (
  SELECT
    p.*,

    nik_clean IS NOT NULL
      AS flag_nik_valid,


    -- --------------------------------------------------------
    -- SOURCE RECORD ID
    -- --------------------------------------------------------
    COALESCE(
      NULLIF(
        TRIM(CAST(uuid AS STRING)),
        ''
      ),

      CAST(
        source_row_hash AS STRING
      )
    ) AS source_record_id,


    -- --------------------------------------------------------
    -- MOTHER IDENTITY KEY
    --
    -- Priority:
    -- 1. NIK
    -- 2. Name + DOB + Desa
    -- 3. Name + DOB + Puskesmas
    -- 4. Source record
    -- --------------------------------------------------------
    CASE

      WHEN nik_clean IS NOT NULL
      THEN CONCAT(
        'NIK|',
        nik_clean
      )


      WHEN nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND desa_norm IS NOT NULL
      THEN CONCAT(
        'NAME_DOB_DESA|',
        nama_norm,
        '|',
        CAST(
          tanggal_lahir_std AS STRING
        ),
        '|',
        desa_norm
      )


      WHEN nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND puskesmas_norm IS NOT NULL
      THEN CONCAT(
        'NAME_DOB_PKM|',
        nama_norm,
        '|',
        CAST(
          tanggal_lahir_std AS STRING
        ),
        '|',
        puskesmas_norm
      )


      ELSE CONCAT(
        'SOURCE|',
        COALESCE(
          NULLIF(
            TRIM(CAST(uuid AS STRING)),
            ''
          ),
          CAST(
            source_row_hash AS STRING
          )
        )
      )

    END AS mother_source_key,


    -- --------------------------------------------------------
    -- MOTHER MATCH METHOD
    -- --------------------------------------------------------
    CASE

      WHEN nik_clean IS NOT NULL
      THEN 'NIK'


      WHEN nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND desa_norm IS NOT NULL
      THEN 'NAMA+DOB+DESA'


      WHEN nama_norm IS NOT NULL
        AND tanggal_lahir_std IS NOT NULL
        AND puskesmas_norm IS NOT NULL
      THEN 'NAMA+DOB+PUSKESMAS'


      ELSE 'SOURCE_RECORD'

    END AS mother_match_method,


    -- ========================================================
    -- PREGNANCY REFERENCE
    --
    -- IMPORTANT:
    -- No derived HPHT.
    -- No delivery - 280 days.
    -- No HPL - 280 days.
    -- No abortus-derived pregnancy date.
    --
    -- Pregnancy identity uses ONLY provided HPHT.
    -- ========================================================
    tanggal_hpht_std
      AS pregnancy_anchor_date,


    CASE
      WHEN tanggal_hpht_std IS NOT NULL
      THEN 'HPHT'

      ELSE 'NO_HPHT'
    END AS pregnancy_anchor_type

  FROM parsed p

  WHERE
    (
      nik_clean IS NOT NULL
      OR nama_norm IS NOT NULL
    )

    AND

    (
      tanggal_hpht_std IS NOT NULL
      OR tanggal_hpl_std IS NOT NULL
      OR tanggal_melahirkan_std IS NOT NULL
      OR tanggal_abortus_std IS NOT NULL
      OR status_raw_std IS NOT NULL
    )
),


-- ============================================================
-- 5. CREATE MOTHER + PREGNANCY DEDUP KEY
-- ============================================================
dedup_prep AS (
  SELECT
    i.*,


    -- --------------------------------------------------------
    -- PREGNANCY KEY
    --
    -- Same mother + same provided HPHT
    -- = same pregnancy
    --
    -- If HPHT is missing:
    -- do NOT merge the records.
    -- --------------------------------------------------------
    CASE

      WHEN tanggal_hpht_std IS NOT NULL
        AND mother_match_method != 'SOURCE_RECORD'

      THEN CONCAT(
        mother_source_key,
        '|PREG|HPHT|',
        CAST(
          tanggal_hpht_std AS STRING
        )
      )


      ELSE CONCAT(
        'SOURCE|',
        source_record_id
      )

    END AS dedup_key,


    -- --------------------------------------------------------
    -- DEDUP METHOD
    -- --------------------------------------------------------
    CASE

      WHEN tanggal_hpht_std IS NOT NULL
        AND mother_match_method != 'SOURCE_RECORD'

      THEN CONCAT(
        mother_match_method,
        '+HPHT'
      )


      WHEN tanggal_hpht_std IS NULL
      THEN 'SOURCE_RECORD_FALLBACK_NO_HPHT'


      ELSE 'SOURCE_RECORD_FALLBACK'

    END AS dedup_method,


    -- --------------------------------------------------------
    -- FILE UPLOAD TIMESTAMP
    -- --------------------------------------------------------
    TIMESTAMP(
      file_dt_from_name,
      'Asia/Makassar'
    ) AS file_upload_ts

  FROM identity i
),


-- ============================================================
-- 6. RANK DUPLICATE RECORDS
--
-- Within same mother + same HPHT:
-- keep the latest available record.
-- ============================================================
ranked AS (
  SELECT
    d.*,


    COUNT(*) OVER (
      PARTITION BY dedup_key
    ) AS source_record_count,


    ROW_NUMBER() OVER (
      PARTITION BY dedup_key

      ORDER BY
        ingestion_ts DESC NULLS LAST,
        file_upload_ts DESC NULLS LAST,
        file_name DESC NULLS LAST,
        source_record_id DESC
    ) AS rn

  FROM dedup_prep d
)


-- ============================================================
-- 7. FINAL
--
-- ONE ROW =
-- ONE MOTHER + ONE PROVIDED HPHT
--
-- Records without HPHT remain source-level records.
-- ============================================================
SELECT

  * EXCEPT(
    rn,
    source_json,
    source_row_hash,
    file_dt_from_name,

    nik_raw_std,
    nama_raw_std,
    desa_raw_std,
    puskesmas_raw_std,

    dob_raw,
    hpht_raw,
    hpl_raw,
    delivery_raw,
    abortion_raw,

    status_raw_std
  ),

  'Sigizi Ibu Nifas'
    AS data_source

FROM ranked

WHERE rn = 1;

CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.vs_simrs_patut_patuh_inc` AS
WITH

-- ============================================================
-- 1. RAW SOURCE
-- ============================================================
source AS (
  SELECT
    t.*,

    /*
      Hash the business / clinical payload while excluding
      ingestion metadata.

      This helps identify the same SIMRS row being loaded
      repeatedly through different files / ingestion runs.
    */
    FARM_FINGERPRINT(
      TO_JSON_STRING(
        (
          SELECT AS STRUCT
            t.* EXCEPT(
              file_name,
              file_date,
              ingestion_timestamp,
              uuid,
              hash_code
            )
        )
      )
    ) AS source_row_hash

  FROM
    `spheres-lombok-barat.raw_data.simrs_patut_patuh_inc` t
),


-- ============================================================
-- 2. PARSE RAW DATE / TIME / NUMERIC FIELDS
-- ============================================================
parsed AS (
  SELECT
    s.*,


    -- --------------------------------------------------------
    -- FILE DATE
    -- Supports:
    -- YYYY-MM-DD
    -- YYYY-MM-DD HH:MM:SS
    -- DD/MM/YYYY
    -- DD-MM-YYYY
    -- YYYY/MM/DD
    -- --------------------------------------------------------
    COALESCE(

      SAFE_CAST(
        NULLIF(TRIM(file_date), '')
        AS DATE
      ),

      DATE(
        SAFE_CAST(
          NULLIF(TRIM(file_date), '')
          AS DATETIME
        )
      ),

      DATE(
        SAFE_CAST(
          NULLIF(TRIM(file_date), '')
          AS TIMESTAMP
        ),
        'Asia/Makassar'
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        NULLIF(TRIM(file_date), '')
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        NULLIF(TRIM(file_date), '')
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        NULLIF(TRIM(file_date), '')
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        NULLIF(TRIM(file_date), '')
      )

    ) AS file_date_parsed,


    -- --------------------------------------------------------
    -- INGESTION TIMESTAMP
    --
    -- Handles:
    -- 2026-03-07 00:42:31.657000
    -- 2025-12-15 20:00:20.881+08
    -- 2025-12-15 20:00:20.881+08:00
    -- 2025-12-15 20:00:20.881+0800
    -- --------------------------------------------------------
    CASE

      WHEN NULLIF(
        TRIM(ingestion_timestamp),
        ''
      ) IS NULL
      THEN NULL


      -- Timestamp contains timezone
      WHEN REGEXP_CONTAINS(
        TRIM(ingestion_timestamp),
        r'(Z|[+-][0-9]{2}(:[0-9]{2}|[0-9]{2})?)$'
      )
      THEN SAFE_CAST(
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            TRIM(ingestion_timestamp),

            -- +0800 -> +08:00
            r'([+-][0-9]{2})([0-9]{2})$',
            r'\1:\2'
          ),

          -- +08 -> +08:00
          r'([+-][0-9]{2})$',
          r'\1:00'
        )
        AS TIMESTAMP
      )


      -- No timezone:
      -- interpret source datetime as WITA / Asia-Makassar
      ELSE TIMESTAMP(
        SAFE_CAST(
          TRIM(ingestion_timestamp)
          AS DATETIME
        ),
        'Asia/Makassar'
      )

    END AS ingestion_ts,


    -- --------------------------------------------------------
    -- TGL LAHIR
    --
    -- Source observed as:
    -- 2026-03-07 00:00:00
    -- 2026-07-24 00:00:00
    -- 1988-09-10
    --
    -- Keep the parsed value regardless of quality.
    -- Quality assessment happens later.
    -- --------------------------------------------------------
    COALESCE(

      SAFE_CAST(
        NULLIF(TRIM(tgl_lahir), '')
        AS DATE
      ),

      DATE(
        SAFE_CAST(
          NULLIF(TRIM(tgl_lahir), '')
          AS DATETIME
        )
      ),

      DATE(
        SAFE_CAST(
          NULLIF(TRIM(tgl_lahir), '')
          AS TIMESTAMP
        ),
        'Asia/Makassar'
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        NULLIF(TRIM(tgl_lahir), '')
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        NULLIF(TRIM(tgl_lahir), '')
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        NULLIF(TRIM(tgl_lahir), '')
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        NULLIF(TRIM(tgl_lahir), '')
      )

    ) AS tgl_lahir_date,


    -- --------------------------------------------------------
    -- TGL INC BAYI TIMESTAMP
    --
    -- Observed formats:
    --
    -- 2025-12-15 20:00:20.881+08
    -- 2026-01-22 02:49:43.174+08
    -- 2026-03-07 00:42:31.657000
    -- 2026-07-24 12:17:05.728000
    --
    -- Values without timezone are interpreted as WITA.
    -- --------------------------------------------------------
    CASE

      WHEN NULLIF(
        TRIM(tgl_inc_bayi),
        ''
      ) IS NULL
      THEN NULL


      -- Has timezone
      WHEN REGEXP_CONTAINS(
        TRIM(tgl_inc_bayi),
        r'(Z|[+-][0-9]{2}(:[0-9]{2}|[0-9]{2})?)$'
      )
      THEN SAFE_CAST(
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            TRIM(tgl_inc_bayi),

            -- +0800 -> +08:00
            r'([+-][0-9]{2})([0-9]{2})$',
            r'\1:\2'
          ),

          -- +08 -> +08:00
          r'([+-][0-9]{2})$',
          r'\1:00'
        )
        AS TIMESTAMP
      )


      -- No timezone:
      -- assume local WITA time
      ELSE TIMESTAMP(
        SAFE_CAST(
          TRIM(tgl_inc_bayi)
          AS DATETIME
        ),
        'Asia/Makassar'
      )

    END AS tgl_inc_bayi_timestamp,


    -- --------------------------------------------------------
    -- JAM LAHIR
    -- --------------------------------------------------------
    COALESCE(

      SAFE_CAST(
        NULLIF(TRIM(jam_lahir), '')
        AS TIME
      ),

      SAFE.PARSE_TIME(
        '%H:%M',
        NULLIF(TRIM(jam_lahir), '')
      ),

      SAFE.PARSE_TIME(
        '%H.%M',
        NULLIF(TRIM(jam_lahir), '')
      ),

      SAFE.PARSE_TIME(
        '%H:%M:%S',
        NULLIF(TRIM(jam_lahir), '')
      )

    ) AS jam_lahir_time,


    -- --------------------------------------------------------
    -- USIA GESTASI
    --
    -- Examples:
    -- 39
    -- 39 minggu
    -- 38,5
    -- --------------------------------------------------------
    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          NULLIF(
            TRIM(usia_gestasi),
            ''
          ),
          r'\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS usia_gestasi_numeric,


    -- --------------------------------------------------------
    -- BERAT BADAN LAHIR
    -- --------------------------------------------------------
    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          NULLIF(
            TRIM(berat_badan_lahir),
            ''
          ),
          r'\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS berat_badan_lahir_numeric,


    -- --------------------------------------------------------
    -- PANJANG BADAN LAHIR
    -- --------------------------------------------------------
    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          NULLIF(
            TRIM(panjang_badan_lahir),
            ''
          ),
          r'\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS panjang_badan_lahir_numeric,


    -- --------------------------------------------------------
    -- LINGKAR KEPALA
    -- --------------------------------------------------------
    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          NULLIF(
            TRIM(lingkar_kepala_lahir),
            ''
          ),
          r'\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS lingkar_kepala_lahir_numeric,


    -- --------------------------------------------------------
    -- SUHU
    -- --------------------------------------------------------
    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          NULLIF(
            TRIM(suhu),
            ''
          ),
          r'\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS suhu_numeric,


    -- --------------------------------------------------------
    -- RESPIRATORY RATE
    -- --------------------------------------------------------
    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          NULLIF(
            TRIM(pernapasan),
            ''
          ),
          r'\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS pernapasan_numeric,


    -- --------------------------------------------------------
    -- HEART RATE
    -- --------------------------------------------------------
    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          NULLIF(
            TRIM(frekuensi_denyut_jantung),
            ''
          ),
          r'\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS frekuensi_denyut_jantung_numeric

  FROM source s
),


-- ============================================================
-- 3. DERIVE TGL INC BAYI DATE
-- ============================================================
parsed_dates AS (
  SELECT
    p.*,

    CASE
      WHEN tgl_inc_bayi_timestamp IS NOT NULL
      THEN DATE(
        tgl_inc_bayi_timestamp,
        'Asia/Makassar'
      )

      ELSE NULL
    END AS tgl_inc_bayi_date

  FROM parsed p
),


-- ============================================================
-- 4. BASIC TEXT / ID NORMALIZATION
-- ============================================================
cleaned AS (
  SELECT
    p.*,


    -- --------------------------------------------------------
    -- Registration number
    -- --------------------------------------------------------
    NULLIF(
      UPPER(
        TRIM(no_pendaftaran)
      ),
      ''
    ) AS no_pendaftaran_clean,


    -- --------------------------------------------------------
    -- NIK ibu: digits only
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        COALESCE(nik_ibu, ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS nik_ibu_digits,


    -- --------------------------------------------------------
    -- Parent phone: digits only
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        COALESCE(no_hp_ortu, ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS no_hp_digits,


    -- --------------------------------------------------------
    -- Mother name
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            TRIM(
              COALESCE(
                nama_ibu,
                ''
              )
            )
          ),
          r'[^\p{L}\p{N} ]',
          ' '
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS nama_ibu_norm,


    -- --------------------------------------------------------
    -- Baby name
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            TRIM(
              COALESCE(
                nama_bayi,
                ''
              )
            )
          ),
          r'[^\p{L}\p{N} ]',
          ' '
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS nama_bayi_norm,


    -- --------------------------------------------------------
    -- Father name
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            TRIM(
              COALESCE(
                nama_ayah,
                ''
              )
            )
          ),
          r'[^\p{L}\p{N} ]',
          ' '
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS nama_ayah_norm,


    -- --------------------------------------------------------
    -- Address
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        NORMALIZE_AND_CASEFOLD(
          TRIM(
            COALESCE(
              alamat,
              ''
            )
          )
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS alamat_norm,


    -- --------------------------------------------------------
    -- Province
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          UPPER(
            TRIM(
              COALESCE(
                nama_propinsi,
                ''
              )
            )
          ),
          r'^PROVINSI\s+',
          ''
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS provinsi_norm,


    -- --------------------------------------------------------
    -- Kabupaten / Kota
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          UPPER(
            TRIM(
              COALESCE(
                keterangan_kota_kabupaten,
                ''
              )
            )
          ),
          r'^(KABUPATEN|KAB\.?|KOTA)\s+',
          ''
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS kabupaten_norm,


    -- --------------------------------------------------------
    -- Kecamatan
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          UPPER(
            TRIM(
              COALESCE(
                keterangan_kecamatan,
                ''
              )
            )
          ),
          r'^(KECAMATAN|KEC\.?)\s+',
          ''
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS kecamatan_norm,


    -- --------------------------------------------------------
    -- Desa / Kelurahan
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          UPPER(
            TRIM(
              COALESCE(
                keterangan_kelurahan,
                ''
              )
            )
          ),
          r'^(DESA|KELURAHAN|KEL\.?)\s+',
          ''
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS desa_norm,


    -- --------------------------------------------------------
    -- Faskes
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        UPPER(
          TRIM(
            COALESCE(
              faskes,
              ''
            )
          )
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS faskes_norm,


    -- --------------------------------------------------------
    -- Tempat INC
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        UPPER(
          TRIM(
            COALESCE(
              tempat_inc,
              ''
            )
          )
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS tempat_inc_norm,


    -- --------------------------------------------------------
    -- Tempat lahir
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        UPPER(
          TRIM(
            COALESCE(
              tempat_lahir,
              ''
            )
          )
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS tempat_lahir_norm,


    -- --------------------------------------------------------
    -- Puskesmas
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          UPPER(
            TRIM(
              COALESCE(
                puskesmas_name,
                ''
              )
            )
          ),
          r'^(UPTD?\s+)?(BLUD\s+)?(PUSKESMAS|PKM)\s+',
          ''
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS puskesmas_norm_raw,


    -- --------------------------------------------------------
    -- Examiner name
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        NORMALIZE_AND_CASEFOLD(
          TRIM(
            COALESCE(
              nama_tenaga_pemeriksa,
              ''
            )
          )
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS nama_tenaga_pemeriksa_norm,


    -- --------------------------------------------------------
    -- Doctor
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        NORMALIZE_AND_CASEFOLD(
          TRIM(
            COALESCE(
              dokter,
              ''
            )
          )
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS dokter_norm,


    -- --------------------------------------------------------
    -- Pregnancy / clinical text normalization
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        UPPER(
          TRIM(
            COALESCE(
              kehamilan,
              ''
            )
          )
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS kehamilan_norm,


    NULLIF(
      REGEXP_REPLACE(
        UPPER(
          TRIM(
            COALESCE(
              kelainan_bawaan,
              ''
            )
          )
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS kelainan_bawaan_norm,


    NULLIF(
      REGEXP_REPLACE(
        UPPER(
          TRIM(
            COALESCE(
              riwayat_resusitasi,
              ''
            )
          )
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS riwayat_resusitasi_norm,


    NULLIF(
      REGEXP_REPLACE(
        UPPER(
          TRIM(
            COALESCE(
              inisiasi_menyusui_dini,
              ''
            )
          )
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS inisiasi_menyusui_dini_norm,


    NULLIF(
      REGEXP_REPLACE(
        UPPER(
          TRIM(
            COALESCE(
              nama_icdx,
              ''
            )
          )
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS nama_icdx_norm,


    NULLIF(
      TRIM(uuid),
      ''
    ) AS uuid_clean,


    NULLIF(
      TRIM(hash_code),
      ''
    ) AS hash_code_clean

  FROM parsed_dates p
),


-- ============================================================
-- 5. STANDARDIZE IDENTIFIERS
-- ============================================================
standardized AS (
  SELECT
    c.*,


    -- --------------------------------------------------------
    -- Valid maternal NIK
    -- --------------------------------------------------------
    CASE

      WHEN REGEXP_CONTAINS(
        nik_ibu_digits,
        r'^\d{16}$'
      )
      AND nik_ibu_digits NOT IN (
        '0000000000000000',
        '9999999999999999'
      )

      THEN nik_ibu_digits

      ELSE NULL

    END AS nik_ibu_clean,


    CASE

      WHEN REGEXP_CONTAINS(
        nik_ibu_digits,
        r'^\d{16}$'
      )
      AND nik_ibu_digits NOT IN (
        '0000000000000000',
        '9999999999999999'
      )

      THEN TRUE

      ELSE FALSE

    END AS flag_nik_ibu_valid_16_digit,


    -- --------------------------------------------------------
    -- Canonical phone
    --
    -- 62812... -> 0812...
    -- 812...   -> 0812...
    -- 0812...  -> unchanged
    -- --------------------------------------------------------
    CASE

      WHEN no_hp_digits IS NULL
        THEN NULL

      WHEN STARTS_WITH(
        no_hp_digits,
        '62'
      )
        THEN CONCAT(
          '0',
          SUBSTR(
            no_hp_digits,
            3
          )
        )

      WHEN STARTS_WITH(
        no_hp_digits,
        '8'
      )
        THEN CONCAT(
          '0',
          no_hp_digits
        )

      ELSE no_hp_digits

    END AS no_hp_ortu_clean,


    -- --------------------------------------------------------
    -- Canonical Puskesmas
    -- --------------------------------------------------------
    CASE

      WHEN puskesmas_norm_raw = 'GUNUNG SARI'
        THEN 'GUNUNGSARI'

      ELSE puskesmas_norm_raw

    END AS puskesmas_norm,


    -- --------------------------------------------------------
    -- Reference date of source extraction / ingestion
    -- --------------------------------------------------------
    COALESCE(
      file_date_parsed,
      DATE(
        ingestion_ts,
        'Asia/Makassar'
      )
    ) AS reference_upload_date

  FROM cleaned c
),


-- ============================================================
-- 6. DETERMINE BEST DELIVERY DATE
-- ============================================================
delivery_date_logic AS (
  SELECT
    s.*,


    -- --------------------------------------------------------
    -- Difference between INC date and raw tgl_lahir
    -- --------------------------------------------------------
    CASE

      WHEN tgl_inc_bayi_date IS NOT NULL
       AND tgl_lahir_date IS NOT NULL

      THEN DATE_DIFF(
        tgl_inc_bayi_date,
        tgl_lahir_date,
        DAY
      )

      ELSE NULL

    END AS inc_vs_tgl_lahir_diff_days,


    -- --------------------------------------------------------
    -- Quality of raw tgl_lahir
    -- --------------------------------------------------------
    CASE

      WHEN tgl_lahir_date IS NULL
        THEN 'MISSING'


      WHEN tgl_inc_bayi_date IS NOT NULL
       AND tgl_lahir_date = tgl_inc_bayi_date
        THEN 'MATCH_INC_DATE'


      WHEN tgl_inc_bayi_date IS NOT NULL
       AND tgl_lahir_date != tgl_inc_bayi_date
        THEN 'DIFFERENT_FROM_INC_DATE'


      WHEN tgl_inc_bayi_date IS NULL
       AND reference_upload_date IS NOT NULL
       AND ABS(
             DATE_DIFF(
               reference_upload_date,
               tgl_lahir_date,
               DAY
             )
           ) > 365
        THEN 'HISTORICAL_SUSPECT'


      ELSE 'TGL_LAHIR_ONLY'

    END AS tgl_lahir_quality,


    -- --------------------------------------------------------
    -- Best date representing the birth / INC episode
    --
    -- Priority:
    --
    -- 1. tgl_inc_bayi_date
    -- 2. tgl_lahir_date if reasonably consistent with
    --    source extraction / ingestion
    --
    -- This prevents old dates such as 1988 / 1995 / 2001
    -- from automatically becoming delivery dates when the
    -- record appears to be incomplete / anomalous.
    -- --------------------------------------------------------
    CASE

      WHEN tgl_inc_bayi_date IS NOT NULL
        THEN tgl_inc_bayi_date


      WHEN tgl_lahir_date IS NOT NULL
       AND reference_upload_date IS NOT NULL
       AND ABS(
             DATE_DIFF(
               reference_upload_date,
               tgl_lahir_date,
               DAY
             )
           ) <= 365
        THEN tgl_lahir_date


      ELSE NULL

    END AS delivery_date,


    -- --------------------------------------------------------
    -- Provenance of best delivery date
    -- --------------------------------------------------------
    CASE

      WHEN tgl_inc_bayi_date IS NOT NULL
        THEN 'TGL_INC_BAYI'


      WHEN tgl_lahir_date IS NOT NULL
       AND reference_upload_date IS NOT NULL
       AND ABS(
             DATE_DIFF(
               reference_upload_date,
               tgl_lahir_date,
               DAY
             )
           ) <= 365
        THEN 'TGL_LAHIR'


      WHEN tgl_lahir_date IS NOT NULL
        THEN 'UNRESOLVED_TGL_LAHIR_SUSPECT'


      ELSE 'NO_DATE'

    END AS delivery_date_source

  FROM standardized s
),


-- ============================================================
-- 7. DERIVED CLINICAL / DATE VARIABLES
-- ============================================================
derived AS (
  SELECT
    d.*,


    -- --------------------------------------------------------
    -- Birth datetime
    --
    -- Uses chosen delivery date + explicit jam_lahir.
    -- We do NOT treat tgl_inc_bayi timestamp itself as the
    -- exact birth time because it may represent INC recording.
    -- --------------------------------------------------------
    CASE

      WHEN delivery_date IS NOT NULL
       AND jam_lahir_time IS NOT NULL

      THEN DATETIME(
        delivery_date,
        jam_lahir_time
      )

      ELSE NULL

    END AS birth_datetime,


    -- --------------------------------------------------------
    -- Source event date
    -- --------------------------------------------------------
    delivery_date AS source_event_date,


    -- --------------------------------------------------------
    -- BBLR
    -- --------------------------------------------------------
    CASE

      WHEN berat_badan_lahir_numeric IS NULL
        THEN NULL

      WHEN berat_badan_lahir_numeric < 2500
        THEN 'BBLR'

      ELSE 'TIDAK BBLR'

    END AS bblr_status,


    -- --------------------------------------------------------
    -- Gestational age category
    -- --------------------------------------------------------
    CASE

      WHEN usia_gestasi_numeric IS NULL
        THEN NULL

      WHEN usia_gestasi_numeric < 37
        THEN 'PRETERM'

      WHEN usia_gestasi_numeric BETWEEN 37 AND 42
        THEN 'ATERM'

      WHEN usia_gestasi_numeric > 42
        THEN 'POSTTERM'

      ELSE NULL

    END AS gestational_age_category

  FROM delivery_date_logic d
),


-- ============================================================
-- 8. COMPLETENESS SCORE
--
-- Used only as a tie-breaker when multiple versions of the
-- same logical SIMRS record exist.
-- ============================================================
scored AS (
  SELECT
    d.*,

    (
        CAST(
          nik_ibu_clean IS NOT NULL
          AS INT64
        )

      + CAST(
          nama_ibu_norm IS NOT NULL
          AS INT64
        )

      + CAST(
          nama_bayi_norm IS NOT NULL
          AS INT64
        )

      + CAST(
          delivery_date IS NOT NULL
          AS INT64
        )

      + CAST(
          jam_lahir_time IS NOT NULL
          AS INT64
        )

      + CAST(
          no_hp_ortu_clean IS NOT NULL
          AS INT64
        )

      + CAST(
          alamat_norm IS NOT NULL
          AS INT64
        )

      + CAST(
          puskesmas_norm IS NOT NULL
          AS INT64
        )

      + CAST(
          usia_gestasi_numeric IS NOT NULL
          AS INT64
        )

      + CAST(
          berat_badan_lahir_numeric IS NOT NULL
          AS INT64
        )

      + CAST(
          panjang_badan_lahir_numeric IS NOT NULL
          AS INT64
        )

      + CAST(
          lingkar_kepala_lahir_numeric IS NOT NULL
          AS INT64
        )

      + CAST(
          NULLIF(
            TRIM(apgar_score),
            ''
          ) IS NOT NULL
          AS INT64
        )

      + CAST(
          nama_icdx_norm IS NOT NULL
          AS INT64
        )

    ) AS data_completeness_score

  FROM derived d
),


-- ============================================================
-- 9. REMOVE EXACT RE-INGESTED DUPLICATES
-- ============================================================
exact_duplicate_ranked AS (
  SELECT
    s.*,


    COUNT(*) OVER (
      PARTITION BY source_row_hash
    ) AS exact_duplicate_source_count,


    ROW_NUMBER() OVER (
      PARTITION BY source_row_hash

      ORDER BY

        ingestion_ts DESC NULLS LAST,

        file_date_parsed DESC NULLS LAST,

        data_completeness_score DESC,

        uuid_clean DESC,

        hash_code_clean DESC

    ) AS exact_duplicate_rank

  FROM scored s
),


exact_dedup AS (
  SELECT
    *

  FROM exact_duplicate_ranked

  WHERE exact_duplicate_rank = 1
),


-- ============================================================
-- 10. CREATE LOGICAL SIMRS RECORD KEY
-- ============================================================
keyed AS (
  SELECT
    e.*,


    /*
      Logical record identity priority:

      1. no_pendaftaran
      2. uuid
      3. hash_code
      4. maternal NIK + delivery date + baby identity
      5. mother name + delivery date + baby identity
      6. physical row hash

      IMPORTANT:
      We deliberately DO NOT deduplicate only by:

          nik_ibu + delivery_date

      because twins / multiple births could otherwise collapse
      into one record.
    */
    CASE


      -- ======================================================
      -- 1. Hospital registration
      -- ======================================================
      WHEN no_pendaftaran_clean IS NOT NULL

      THEN CONCAT(
        'REG|',
        no_pendaftaran_clean
      )


      -- ======================================================
      -- 2. UUID
      -- ======================================================
      WHEN uuid_clean IS NOT NULL

      THEN CONCAT(
        'UUID|',
        uuid_clean
      )


      -- ======================================================
      -- 3. Source hash code
      -- ======================================================
      WHEN hash_code_clean IS NOT NULL

      THEN CONCAT(
        'HASH|',
        hash_code_clean
      )


      -- ======================================================
      -- 4. Maternal NIK + birth + baby identity
      -- ======================================================
      WHEN nik_ibu_clean IS NOT NULL
       AND delivery_date IS NOT NULL

      THEN CONCAT(
        'NIK_BIRTH|',

        nik_ibu_clean,

        '|',

        CAST(
          delivery_date
          AS STRING
        ),

        '|',

        COALESCE(
          nama_bayi_norm,
          'NO_BABY_NAME'
        ),

        '|',

        COALESCE(
          CAST(
            jam_lahir_time
            AS STRING
          ),
          'NO_BIRTH_TIME'
        )
      )


      -- ======================================================
      -- 5. Mother name + birth + baby identity
      -- ======================================================
      WHEN nama_ibu_norm IS NOT NULL
       AND delivery_date IS NOT NULL

      THEN CONCAT(
        'NAME_BIRTH|',

        nama_ibu_norm,

        '|',

        CAST(
          delivery_date
          AS STRING
        ),

        '|',

        COALESCE(
          nama_bayi_norm,
          'NO_BABY_NAME'
        ),

        '|',

        COALESCE(
          CAST(
            jam_lahir_time
            AS STRING
          ),
          'NO_BIRTH_TIME'
        )
      )


      -- ======================================================
      -- 6. Never merge weak / unresolved records
      -- ======================================================
      ELSE CONCAT(
        'ROW|',
        CAST(
          source_row_hash
          AS STRING
        )
      )

    END AS dedup_key,


    CASE

      WHEN no_pendaftaran_clean IS NOT NULL
        THEN 'NO_PENDAFTARAN'

      WHEN uuid_clean IS NOT NULL
        THEN 'UUID'

      WHEN hash_code_clean IS NOT NULL
        THEN 'HASH_CODE'

      WHEN nik_ibu_clean IS NOT NULL
       AND delivery_date IS NOT NULL
        THEN 'NIK_IBU+DELIVERY_DATE+BAYI'

      WHEN nama_ibu_norm IS NOT NULL
       AND delivery_date IS NOT NULL
        THEN 'NAMA_IBU+DELIVERY_DATE+BAYI'

      ELSE 'SOURCE_ROW_HASH'

    END AS dedup_method

  FROM exact_dedup e
),


-- ============================================================
-- 11. LOGICAL DEDUPLICATION
--
-- If the same hospital registration appears in multiple
-- exports, keep the most recently ingested / most complete
-- version.
-- ============================================================
logical_ranked AS (
  SELECT
    k.*,


    -- Number of unique versions after exact duplicate removal
    COUNT(*) OVER (
      PARTITION BY dedup_key
    ) AS logical_duplicate_source_count,


    -- Number of original raw rows represented by this
    -- logical SIMRS record.
    SUM(
      exact_duplicate_source_count
    ) OVER (
      PARTITION BY dedup_key
    ) AS source_record_count_before_dedup,


    ROW_NUMBER() OVER (
      PARTITION BY dedup_key

      ORDER BY

        ingestion_ts DESC NULLS LAST,

        file_date_parsed DESC NULLS LAST,

        data_completeness_score DESC,

        uuid_clean DESC,

        hash_code_clean DESC,

        source_row_hash DESC

    ) AS logical_row_priority

  FROM keyed k
),


-- ============================================================
-- 12. FINAL DEDUPLICATED RECORD
-- ============================================================
final AS (
  SELECT
    l.*,


    -- --------------------------------------------------------
    -- Standard source name
    -- --------------------------------------------------------
    'SIMRS_PATUT_PATUH_INC'
      AS data_source,


    -- --------------------------------------------------------
    -- Stable source record ID
    -- --------------------------------------------------------
    COALESCE(

      uuid_clean,

      hash_code_clean,

      no_pendaftaran_clean,

      CAST(
        source_row_hash
        AS STRING
      )

    ) AS source_record_id,


    -- --------------------------------------------------------
    -- Stable cleaned SIMRS INC key
    -- --------------------------------------------------------
    CONCAT(
      'SIMRSINC_',
      TO_HEX(
        SHA256(
          dedup_key
        )
      )
    ) AS simrs_inc_record_key

  FROM logical_ranked l

  WHERE logical_row_priority = 1
)


-- ============================================================
-- 13. FINAL OUTPUT
--
-- Keep all original source fields plus cleaned / parsed /
-- derived / deduplication variables.
-- ============================================================
SELECT
  * EXCEPT(

    -- intermediate variables
    nik_ibu_digits,
    no_hp_digits,
    puskesmas_norm_raw,

    -- ranking-only fields
    exact_duplicate_rank,
    logical_row_priority

  )

FROM final;

CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.vs_epus_pnc` AS
WITH
-- ============================================================
-- 1. RAW SOURCE
--
-- source_row_hash:
--   complete physical source row
--
-- clinical_content_hash:
--   clinical content excluding file/ingestion metadata.
--   Used to identify identical records repeated across exports.
-- ============================================================
source AS (
  SELECT
    t.* EXCEPT (`no`),

    FARM_FINGERPRINT(
      TO_JSON_STRING(
        (
          SELECT AS STRUCT
            t.* EXCEPT (`no`)
        )
      )
    ) AS source_row_hash,

    TO_HEX(
      SHA256(
        TO_JSON_STRING(
          (
            SELECT AS STRUCT
              t.* EXCEPT (
                `no`,
                file_name,
                file_date,
                ingestion_timestamp,
                uuid,
                hash_code
              )
          )
        )
      )
    ) AS clinical_content_hash

  FROM
    `spheres-lombok-barat.raw_data.epus_pnc` t
),


-- ============================================================
-- 2. BASIC CLEANING
-- ============================================================
cleaned AS (
  SELECT
    s.*,

    -- --------------------------------------------------------
    -- Source record ID
    -- --------------------------------------------------------
    COALESCE(
      NULLIF(TRIM(uuid), ''),
      NULLIF(TRIM(hash_code), ''),
      CAST(source_row_hash AS STRING)
    ) AS source_record_id,


    -- --------------------------------------------------------
    -- NIK
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        COALESCE(TRIM(nik), ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS nik_clean,


    -- --------------------------------------------------------
    -- Mother name
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          UPPER(
            TRIM(
              COALESCE(nama_pasien, '')
            )
          ),
          r'[^A-Z0-9 ]',
          ' '
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS nama_pasien_clean,


    -- --------------------------------------------------------
    -- Puskesmas normalization
    --
    -- PUSKESMAS LABUAPI
    -- PKM LABUAPI
    -- Labuapi
    --
    -- -> LABUAPI
    -- --------------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            UPPER(
              TRIM(
                COALESCE(
                  puskesmas_name,
                  ''
                )
              )
            ),
            r'\s+',
            ' '
          ),
          r'^(PUSKESMAS|PKM)\s+',
          ''
        )
      ),
      ''
    ) AS puskesmas_name_clean,

    NULLIF(
      TRIM(puskesmas_id),
      ''
    ) AS puskesmas_id_clean,


    -- --------------------------------------------------------
    -- Important categorical variables
    -- --------------------------------------------------------
    NULLIF(
      UPPER(TRIM(kunjungan_kf)),
      ''
    ) AS kunjungan_kf_clean,

    NULLIF(
      UPPER(TRIM(komplikasi)),
      ''
    ) AS komplikasi_clean,

    NULLIF(
      UPPER(TRIM(pendarahan_pervaginam)),
      ''
    ) AS pendarahan_pervaginam_clean,

    NULLIF(
      UPPER(TRIM(kondisi_perineum)),
      ''
    ) AS kondisi_perineum_clean,

    NULLIF(
      UPPER(TRIM(kontraksi_uteri)),
      ''
    ) AS kontraksi_uteri_clean,

    NULLIF(
      UPPER(TRIM(pemeriksaan_jalan_lahir)),
      ''
    ) AS pemeriksaan_jalan_lahir_clean,

    NULLIF(
      UPPER(TRIM(pemeriksaan_payudara)),
      ''
    ) AS pemeriksaan_payudara_clean,

    NULLIF(
      UPPER(TRIM(produksi_asi)),
      ''
    ) AS produksi_asi_clean,

    NULLIF(
      UPPER(TRIM(keadaan_tiba)),
      ''
    ) AS keadaan_tiba_clean,

    NULLIF(
      UPPER(TRIM(keadaan_pulang)),
      ''
    ) AS keadaan_pulang_clean,

    NULLIF(
      UPPER(
        TRIM(
          metode_kontrasepsi_kb_pasca_persalinan
        )
      ),
      ''
    ) AS metode_kontrasepsi_kb_pasca_persalinan_clean,

    NULLIF(
      UPPER(TRIM(kb_pasca_plasenta)),
      ''
    ) AS kb_pasca_plasenta_clean,

    NULLIF(
      UPPER(
        TRIM(
          metode_kontrasepsi_kb_pasca_plasenta
        )
      ),
      ''
    ) AS metode_kontrasepsi_kb_pasca_plasenta_clean,

    NULLIF(
      UPPER(TRIM(kb_pasca_persalinan)),
      ''
    ) AS kb_pasca_persalinan_clean,

    NULLIF(
      UPPER(TRIM(tanda_infeksi_perineum)),
      ''
    ) AS tanda_infeksi_perineum_clean,

    NULLIF(
      UPPER(TRIM(tanda_infeksi_luka_jahitan)),
      ''
    ) AS tanda_infeksi_luka_jahitan_clean,

    NULLIF(
      UPPER(TRIM(warna_lokia)),
      ''
    ) AS warna_lokia_clean,

    NULLIF(
      UPPER(TRIM(bau_lokia)),
      ''
    ) AS bau_lokia_clean,


    -- --------------------------------------------------------
    -- Raw source dates
    -- --------------------------------------------------------
    NULLIF(
      TRIM(tanggal_lahir),
      ''
    ) AS tanggal_lahir_raw_clean,

    NULLIF(
      TRIM(tanggal_hpht),
      ''
    ) AS tanggal_hpht_raw_clean,

    NULLIF(
      TRIM(tanggal_taksiran_persalinan),
      ''
    ) AS tanggal_taksiran_persalinan_raw_clean,

    NULLIF(
      TRIM(tanggal_persalinan_sebelumnya),
      ''
    ) AS tanggal_persalinan_sebelumnya_raw_clean,

    NULLIF(
      TRIM(tanggal_pnc),
      ''
    ) AS tanggal_pnc_raw_clean,

    NULLIF(
      TRIM(tanggal_bersalin),
      ''
    ) AS tanggal_bersalin_raw_clean,


    -- --------------------------------------------------------
    -- Source metadata
    -- --------------------------------------------------------
    NULLIF(
      TRIM(file_date),
      ''
    ) AS file_date_raw_clean,

    NULLIF(
      TRIM(ingestion_timestamp),
      ''
    ) AS ingestion_timestamp_raw_clean

  FROM source s
),


-- ============================================================
-- 3. NIK VALIDATION
-- ============================================================
identity_cleaned AS (
  SELECT
    c.*,

    CASE
      WHEN
        REGEXP_CONTAINS(
          nik_clean,
          r'^\d{16}$'
        )
        AND nik_clean NOT IN (
          '0000000000000000',
          '9999999999999999'
        )
      THEN TRUE
      ELSE FALSE
    END AS flag_nik_valid_16_digit

  FROM cleaned c
),


-- ============================================================
-- 4. DATE PARSING
-- ============================================================
parsed AS (
  SELECT
    i.*,


    -- --------------------------------------------------------
    -- Date of birth
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_lahir_raw_clean,
          r'^\d{5}(\.0+)?$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            REGEXP_EXTRACT(
              tanggal_lahir_raw_clean,
              r'^\d+'
            )
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_lahir_date,


    -- --------------------------------------------------------
    -- HPHT
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_hpht_raw_clean,
          r'^\d{5}(\.0+)?$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            REGEXP_EXTRACT(
              tanggal_hpht_raw_clean,
              r'^\d+'
            )
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_hpht_date,


    -- --------------------------------------------------------
    -- Estimated delivery date / HPL
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_taksiran_persalinan_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_taksiran_persalinan_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_taksiran_persalinan_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_taksiran_persalinan_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_taksiran_persalinan_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_taksiran_persalinan_raw_clean,
          r'^\d{5}(\.0+)?$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            REGEXP_EXTRACT(
              tanggal_taksiran_persalinan_raw_clean,
              r'^\d+'
            )
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_taksiran_persalinan_date,


    -- --------------------------------------------------------
    -- Previous pregnancy delivery date
    --
    -- IMPORTANT:
    -- This remains obstetric history.
    -- It is NOT treated as the current delivery date.
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_persalinan_sebelumnya_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_persalinan_sebelumnya_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_persalinan_sebelumnya_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_persalinan_sebelumnya_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_persalinan_sebelumnya_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_persalinan_sebelumnya_raw_clean,
          r'^\d{5}(\.0+)?$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            REGEXP_EXTRACT(
              tanggal_persalinan_sebelumnya_raw_clean,
              r'^\d+'
            )
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_persalinan_sebelumnya_date,


    -- --------------------------------------------------------
    -- PNC visit date
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_pnc_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_pnc_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_pnc_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_pnc_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_pnc_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_pnc_raw_clean,
          r'^\d{5}(\.0+)?$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            REGEXP_EXTRACT(
              tanggal_pnc_raw_clean,
              r'^\d+'
            )
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_pnc_date,


    -- --------------------------------------------------------
    -- Current delivery date as explicitly recorded in PNC
    --
    -- NO fallback to HPHT or previous delivery.
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_bersalin_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_bersalin_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_bersalin_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_bersalin_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_bersalin_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_bersalin_raw_clean,
          r'^\d{5}(\.0+)?$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            REGEXP_EXTRACT(
              tanggal_bersalin_raw_clean,
              r'^\d+'
            )
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_bersalin_date,


    -- --------------------------------------------------------
    -- File date
    -- --------------------------------------------------------
    COALESCE(
      SAFE_CAST(
        file_date_raw_clean
        AS DATE
      ),

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          file_date_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          file_date_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          file_date_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          file_date_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          file_date_raw_clean,
          r'^\d{5}(\.0+)?$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            REGEXP_EXTRACT(
              file_date_raw_clean,
              r'^\d+'
            )
            AS INT64
          ) DAY
        )
      END
    ) AS file_date_parsed,


    -- --------------------------------------------------------
    -- Ingestion timestamp
    -- --------------------------------------------------------
    SAFE_CAST(
      ingestion_timestamp_raw_clean
      AS TIMESTAMP
    ) AS ingestion_timestamp_parsed

  FROM identity_cleaned i
),


-- ============================================================
-- 5. NUMERIC NORMALIZATION
--
-- Original STRING values remain unchanged.
-- ============================================================
typed AS (
  SELECT
    p.*,

    -- --------------------------------------------------------
    -- Obstetric history
    -- --------------------------------------------------------
    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(gravida),
        r'-?\d+'
      )
      AS INT64
    ) AS gravida_numeric,

    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(partus),
        r'-?\d+'
      )
      AS INT64
    ) AS partus_numeric,

    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(abortus),
        r'-?\d+'
      )
      AS INT64
    ) AS abortus_numeric,

    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(hidup),
        r'-?\d+'
      )
      AS INT64
    ) AS hidup_numeric,


    -- --------------------------------------------------------
    -- Anthropometry
    -- --------------------------------------------------------
    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(bb_sebelum_hamil),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS bb_sebelum_hamil_numeric,

    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(bb),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS bb_numeric,

    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(tb),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS tb_numeric,

    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(lila),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS lila_numeric,


    -- --------------------------------------------------------
    -- Postpartum day
    -- --------------------------------------------------------
    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(hari_sejak_melahirkan),
        r'-?\d+'
      )
      AS INT64
    ) AS hari_sejak_melahirkan_numeric,


    -- --------------------------------------------------------
    -- Blood pressure
    -- Example:
    -- 120/80
    -- --------------------------------------------------------
    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(tekanan_darah),
        r'^\s*(\d{2,3})\s*/'
      )
      AS FLOAT64
    ) AS sistole_numeric,

    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(tekanan_darah),
        r'/\s*(\d{2,3})'
      )
      AS FLOAT64
    ) AS diastole_numeric,


    -- --------------------------------------------------------
    -- Vital signs
    -- --------------------------------------------------------
    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(suhu),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS suhu_numeric,

    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(respirasi),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS respirasi_numeric,

    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(nadi),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS nadi_numeric,


    -- --------------------------------------------------------
    -- Vaginal bleeding
    -- --------------------------------------------------------
    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(jumlah_pendarahan_pervaginam),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS jumlah_pendarahan_pervaginam_numeric,


    -- --------------------------------------------------------
    -- Iron tablets
    -- --------------------------------------------------------
    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(jumlah_tablet_fe_yang_didapatkan),
        r'-?\d+'
      )
      AS INT64
    ) AS jumlah_tablet_fe_yang_didapatkan_numeric,

    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(jumlah_tablet_fe_yang_sudah_dikonsumsi),
        r'-?\d+'
      )
      AS INT64
    ) AS jumlah_tablet_fe_yang_sudah_dikonsumsi_numeric,


    -- --------------------------------------------------------
    -- Vitamin A
    -- --------------------------------------------------------
    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(dosis_vit_a),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS dosis_vit_a_numeric

  FROM parsed p
),


-- ============================================================
-- 6. STANDARDIZED VISIT / DELIVERY FIELDS
--
-- IMPORTANT:
--
-- pnc_visit_date
--   = actual PNC visit date
--
-- delivery_event_date
--   = ONLY tanggal_bersalin_date reported in this PNC record
--
-- No fallback to HPHT.
-- No fallback to tanggal_persalinan_sebelumnya.
-- ============================================================
standardized AS (
  SELECT
    t.*,

    tanggal_pnc_date
      AS pnc_visit_date,

    tanggal_bersalin_date
      AS delivery_event_date,

    CASE
      WHEN tanggal_bersalin_date IS NOT NULL
        THEN 'TANGGAL_BERSALIN'
      ELSE NULL
    END AS delivery_event_date_source,


    -- --------------------------------------------------------
    -- Basic QA relationship between current delivery
    -- and PNC visit.
    --
    -- Flag only; record is not deleted.
    -- --------------------------------------------------------
    CASE
      WHEN
        tanggal_bersalin_date IS NOT NULL
        AND tanggal_pnc_date IS NOT NULL
        AND tanggal_pnc_date < tanggal_bersalin_date
      THEN TRUE
      ELSE FALSE
    END AS flag_pnc_before_delivery,


    -- --------------------------------------------------------
    -- Source recency
    -- --------------------------------------------------------
    COALESCE(
      ingestion_timestamp_parsed,

      CASE
        WHEN file_date_parsed IS NOT NULL
        THEN TIMESTAMP(file_date_parsed)
      END,

      TIMESTAMP '1900-01-01 00:00:00+00'
    ) AS source_recency_timestamp

  FROM typed t
),


-- ============================================================
-- 7. RECORD COMPLETENESS SCORE
-- ============================================================
scored AS (
  SELECT
    s.*,

    (
      IF(flag_nik_valid_16_digit, 1, 0)
      + IF(nama_pasien_clean IS NOT NULL, 1, 0)
      + IF(tanggal_lahir_date IS NOT NULL, 1, 0)
      + IF(tanggal_hpht_date IS NOT NULL, 1, 0)
      + IF(
          tanggal_taksiran_persalinan_date IS NOT NULL,
          1,
          0
        )
      + IF(delivery_event_date IS NOT NULL, 1, 0)
      + IF(pnc_visit_date IS NOT NULL, 1, 0)
      + IF(kunjungan_kf_clean IS NOT NULL, 1, 0)
      + IF(
          hari_sejak_melahirkan_numeric IS NOT NULL,
          1,
          0
        )
      + IF(sistole_numeric IS NOT NULL, 1, 0)
      + IF(diastole_numeric IS NOT NULL, 1, 0)
      + IF(suhu_numeric IS NOT NULL, 1, 0)
      + IF(respirasi_numeric IS NOT NULL, 1, 0)
      + IF(nadi_numeric IS NOT NULL, 1, 0)
      + IF(komplikasi_clean IS NOT NULL, 1, 0)
      + IF(
          pendarahan_pervaginam_clean IS NOT NULL,
          1,
          0
        )
      + IF(kondisi_perineum_clean IS NOT NULL, 1, 0)
      + IF(produksi_asi_clean IS NOT NULL, 1, 0)
      + IF(keadaan_tiba_clean IS NOT NULL, 1, 0)
      + IF(keadaan_pulang_clean IS NOT NULL, 1, 0)
      + IF(puskesmas_name_clean IS NOT NULL, 1, 0)
    ) AS row_completeness_score

  FROM standardized s
),


-- ============================================================
-- 8. EXACT CLINICAL DUPLICATE DETECTION
--
-- Identical clinical record repeated across files/exports.
--
-- Keep the latest imported version.
-- ============================================================
exact_ranked AS (
  SELECT
    s.*,

    COUNT(*) OVER (
      PARTITION BY clinical_content_hash
    ) AS exact_duplicate_count,

    ROW_NUMBER() OVER (
      PARTITION BY clinical_content_hash
      ORDER BY
        source_recency_timestamp DESC,
        source_row_hash DESC
    ) AS exact_dedup_rank

  FROM scored s
),


exact_deduplicated AS (
  SELECT
    *
  FROM exact_ranked
  WHERE exact_dedup_rank = 1
),


-- ============================================================
-- 9. MOTHER IDENTITY
--
-- Hierarchy:
--
-- 1. Valid NIK
-- 2. Name + DOB + Puskesmas
-- 3. Name + HPHT + Puskesmas
-- 4. Weak identity
--
-- HPHT is only used as a fallback identity attribute.
-- It does NOT define the PNC encounter itself.
-- ============================================================
mother_keyed AS (
  SELECT
    e.*,

    CASE
      WHEN flag_nik_valid_16_digit = TRUE
        THEN 'NIK'

      WHEN
        nama_pasien_clean IS NOT NULL
        AND tanggal_lahir_date IS NOT NULL
        AND puskesmas_name_clean IS NOT NULL
        THEN 'NAME+DOB+PUSKESMAS'

      WHEN
        nama_pasien_clean IS NOT NULL
        AND tanggal_hpht_date IS NOT NULL
        AND puskesmas_name_clean IS NOT NULL
        THEN 'NAME+HPHT+PUSKESMAS'

      ELSE 'WEAK_MOTHER_IDENTITY'
    END AS mother_identity_method,


    CASE
      WHEN flag_nik_valid_16_digit = TRUE
      THEN CONCAT(
        'NIK|',
        nik_clean
      )

      WHEN
        nama_pasien_clean IS NOT NULL
        AND tanggal_lahir_date IS NOT NULL
        AND puskesmas_name_clean IS NOT NULL
      THEN CONCAT(
        'NAME_DOB_PKM|',
        nama_pasien_clean,
        '|',
        CAST(tanggal_lahir_date AS STRING),
        '|',
        puskesmas_name_clean
      )

      WHEN
        nama_pasien_clean IS NOT NULL
        AND tanggal_hpht_date IS NOT NULL
        AND puskesmas_name_clean IS NOT NULL
      THEN CONCAT(
        'NAME_HPHT_PKM|',
        nama_pasien_clean,
        '|',
        CAST(tanggal_hpht_date AS STRING),
        '|',
        puskesmas_name_clean
      )

      ELSE NULL
    END AS mother_identity_key

  FROM exact_deduplicated e
),


-- ============================================================
-- 10. PNC ENCOUNTER KEY
--
-- One PNC encounter =
--
-- strong enough mother identity
-- +
-- PNC visit date
--
-- Delivery date is NOT included.
-- KF label is NOT included.
--
-- This allows corrections to delivery date / KF label across
-- later exports to remain the same PNC visit.
--
-- If PNC date is missing, do not perform encounter-level
-- deduplication.
-- ============================================================
encounter_keyed AS (
  SELECT
    m.*,

    CASE
      WHEN
        mother_identity_method = 'NIK'
        AND pnc_visit_date IS NOT NULL
      THEN 'NIK+PNC_DATE'

      WHEN
        mother_identity_method = 'NAME+DOB+PUSKESMAS'
        AND pnc_visit_date IS NOT NULL
      THEN 'NAME+DOB+PUSKESMAS+PNC_DATE'

      WHEN
        mother_identity_method = 'NAME+HPHT+PUSKESMAS'
        AND pnc_visit_date IS NOT NULL
      THEN 'NAME+HPHT+PUSKESMAS+PNC_DATE'

      ELSE 'WEAK_KEY_DO_NOT_ENCOUNTER_DEDUP'
    END AS dedup_method,


    CASE
      WHEN
        mother_identity_key IS NOT NULL
        AND pnc_visit_date IS NOT NULL
      THEN CONCAT(
        mother_identity_key,
        '|PNC|',
        CAST(
          pnc_visit_date
          AS STRING
        )
      )

      ELSE CONCAT(
        'SOURCE|',
        source_record_id,
        '|',
        clinical_content_hash
      )
    END AS pnc_encounter_key

  FROM mother_keyed m
),


-- ============================================================
-- 11. PNC ENCOUNTER DEDUPLICATION
--
-- If multiple clinical variants represent the same encounter:
--
-- 1. latest source snapshot
-- 2. highest completeness
-- 3. deterministic source hash
-- ============================================================
encounter_ranked AS (
  SELECT
    e.*,

    COUNT(*) OVER (
      PARTITION BY pnc_encounter_key
    ) AS encounter_variant_count,


    -- Includes rows removed during exact-dedup stage.
    SUM(exact_duplicate_count) OVER (
      PARTITION BY pnc_encounter_key
    ) AS raw_encounter_record_count,


    ROW_NUMBER() OVER (
      PARTITION BY pnc_encounter_key
      ORDER BY
        source_recency_timestamp DESC,
        row_completeness_score DESC,
        source_row_hash DESC
    ) AS encounter_dedup_rank

  FROM encounter_keyed e
),


-- ============================================================
-- 12. RETAIN ONE ROW PER SAFE PNC ENCOUNTER
-- ============================================================
final_deduplicated AS (
  SELECT
    *
  FROM encounter_ranked
  WHERE encounter_dedup_rank = 1
)


-- ============================================================
-- 13. FINAL OUTPUT
-- ============================================================
SELECT
  * EXCEPT (
    exact_dedup_rank,
    encounter_dedup_rank
  ),


  -- ----------------------------------------------------------
  -- Stable standardized source-record key
  -- ----------------------------------------------------------
  CONCAT(
    'EPPNC_',
    TO_HEX(
      SHA256(pnc_encounter_key)
    )
  ) AS epus_pnc_record_key,


  -- ----------------------------------------------------------
  -- Compatibility / QA count
  -- ----------------------------------------------------------
  raw_encounter_record_count
    AS duplicate_key_count,


  -- ----------------------------------------------------------
  -- Identical clinical record repeated through export
  -- ----------------------------------------------------------
  CASE
    WHEN exact_duplicate_count > 1
      THEN TRUE
    ELSE FALSE
  END AS is_exact_duplicate_group,


  -- ----------------------------------------------------------
  -- Same PNC encounter appeared multiple times
  -- ----------------------------------------------------------
  CASE
    WHEN
      dedup_method != 'WEAK_KEY_DO_NOT_ENCOUNTER_DEDUP'
      AND raw_encounter_record_count > 1
    THEN TRUE
    ELSE FALSE
  END AS is_duplicate_group,


  -- ----------------------------------------------------------
  -- Deduplication explanation
  -- ----------------------------------------------------------
  CASE
    WHEN
      dedup_method = 'WEAK_KEY_DO_NOT_ENCOUNTER_DEDUP'
      AND exact_duplicate_count > 1
    THEN
      'Exact duplicate removed; PNC record kept separately because identity or PNC date is insufficient for safe encounter deduplication'

    WHEN
      dedup_method = 'WEAK_KEY_DO_NOT_ENCOUNTER_DEDUP'
    THEN
      'Kept separately because identity or PNC date is insufficient for safe encounter deduplication'

    WHEN raw_encounter_record_count > 1
    THEN
      'Deduplicated: latest/best version retained for the same PNC encounter'

    ELSE
      'Unique PNC encounter'
  END AS deduplication_status

FROM final_deduplicated;

CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.vs_kohort_epus_kunjungan_ibu_hamil` AS
WITH
-- ============================================================
-- 1. RAW SOURCE
--
-- source_row_hash:
--   complete physical source row
--
-- clinical_content_hash:
--   clinical content excluding ingestion/export metadata
-- ============================================================
source AS (
  SELECT
    t.* EXCEPT (`no`),

    FARM_FINGERPRINT(
      TO_JSON_STRING(
        (
          SELECT AS STRUCT
            t.* EXCEPT (`no`)
        )
      )
    ) AS source_row_hash,

    TO_HEX(
      SHA256(
        TO_JSON_STRING(
          (
            SELECT AS STRUCT
              t.* EXCEPT (
                `no`,
                file_name,
                file_date,
                ingestion_timestamp,
                uuid,
                hash_code
              )
          )
        )
      )
    ) AS clinical_content_hash

  FROM
    `spheres-lombok-barat.raw_data.epus_kunjungan_ibu_hamil` t
),


-- ============================================================
-- 2. BASIC CLEANING
-- ============================================================
cleaned AS (
  SELECT
    s.*,

    -- --------------------------------------------------------
    -- Stable source record ID
    -- --------------------------------------------------------
    COALESCE(
      NULLIF(TRIM(uuid), ''),
      NULLIF(TRIM(hash_code), ''),
      CAST(source_row_hash AS STRING)
    ) AS source_record_id,


    -- --------------------------------------------------------
    -- NIK
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        COALESCE(TRIM(register_nik), ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS nik_clean,


    -- --------------------------------------------------------
    -- Mother name
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          UPPER(
            TRIM(
              COALESCE(register_nama_ibu, '')
            )
          ),
          r'[^A-Z0-9 ]',
          ' '
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS nama_ibu_clean,


    -- --------------------------------------------------------
    -- Phone
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        COALESCE(TRIM(register_no_telp), ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS no_telp_clean,


    -- --------------------------------------------------------
    -- Address
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        UPPER(
          TRIM(
            COALESCE(register_alamat, '')
          )
        ),
        r'\s+',
        ' '
      ),
      ''
    ) AS alamat_clean,


    -- --------------------------------------------------------
    -- Puskesmas
    --
    -- PUSKESMAS LABUAPI
    -- PKM LABUAPI
    -- Labuapi
    --
    -- -> LABUAPI
    -- --------------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            UPPER(
              TRIM(
                COALESCE(puskesmas_name, '')
              )
            ),
            r'\s+',
            ' '
          ),
          r'^(PUSKESMAS|PKM)\s+',
          ''
        )
      ),
      ''
    ) AS puskesmas_name_clean,

    NULLIF(
      TRIM(puskesmas_id),
      ''
    ) AS puskesmas_id_clean,


    -- --------------------------------------------------------
    -- Other useful cleaned categorical variables
    -- --------------------------------------------------------
    NULLIF(
      UPPER(TRIM(register_trisemester_ke)),
      ''
    ) AS trimester_clean,

    NULLIF(
      UPPER(TRIM(register_faskes_asal)),
      ''
    ) AS faskes_asal_clean,

    NULLIF(
      UPPER(TRIM(pemeriksaan_ibu_status_gizi2)),
      ''
    ) AS status_gizi_clean,

    NULLIF(
      UPPER(TRIM(konseling)),
      ''
    ) AS konseling_clean,

    NULLIF(
      UPPER(TRIM(status_imunasi_tt)),
      ''
    ) AS status_imunasi_tt_clean,


    -- --------------------------------------------------------
    -- Raw date strings
    -- --------------------------------------------------------
    NULLIF(
      TRIM(register_tanggal),
      ''
    ) AS register_tanggal_raw_clean,

    NULLIF(
      TRIM(register_tanggal_lahir),
      ''
    ) AS tanggal_lahir_raw_clean,

    NULLIF(
      TRIM(register_tanggal_hpht),
      ''
    ) AS tanggal_hpht_raw_clean,

    NULLIF(
      TRIM(register_taksiran_persalinan),
      ''
    ) AS tanggal_hpl_raw_clean,


    -- --------------------------------------------------------
    -- Source metadata
    -- --------------------------------------------------------
    NULLIF(
      TRIM(file_date),
      ''
    ) AS file_date_raw_clean,

    NULLIF(
      TRIM(ingestion_timestamp),
      ''
    ) AS ingestion_timestamp_raw_clean

  FROM source s
),


-- ============================================================
-- 3. NIK VALIDATION
-- ============================================================
identity_cleaned AS (
  SELECT
    c.*,

    CASE
      WHEN
        REGEXP_CONTAINS(
          nik_clean,
          r'^\d{16}$'
        )
        AND nik_clean NOT IN (
          '0000000000000000',
          '9999999999999999'
        )
      THEN TRUE
      ELSE FALSE
    END AS flag_nik_valid_16_digit

  FROM cleaned c
),


-- ============================================================
-- 4. DATE + SOURCE METADATA PARSING
-- ============================================================
parsed AS (
  SELECT
    i.*,

    -- --------------------------------------------------------
    -- Mother DOB
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_lahir_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_lahir_raw_clean,
          r'^\d{5}(\.0+)?$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            REGEXP_EXTRACT(
              tanggal_lahir_raw_clean,
              r'^\d+'
            )
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_lahir_date,


    -- --------------------------------------------------------
    -- Visit date
    -- register_tanggal may contain DATE or DATETIME
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          register_tanggal_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          register_tanggal_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          register_tanggal_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          register_tanggal_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          register_tanggal_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          register_tanggal_raw_clean,
          r'^\d{5}(\.0+)?$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            REGEXP_EXTRACT(
              register_tanggal_raw_clean,
              r'^\d+'
            )
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_kunjungan_date,


    -- --------------------------------------------------------
    -- Visit DATETIME when available
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATETIME(
        '%Y-%m-%d %H:%M:%E*S',
        register_tanggal_raw_clean
      ),

      SAFE.PARSE_DATETIME(
        '%d/%m/%Y %H:%M:%E*S',
        register_tanggal_raw_clean
      ),

      SAFE.PARSE_DATETIME(
        '%d-%m-%Y %H:%M:%E*S',
        register_tanggal_raw_clean
      )
    ) AS tanggal_kunjungan_datetime,


    -- --------------------------------------------------------
    -- HPHT
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_hpht_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_hpht_raw_clean,
          r'^\d{5}(\.0+)?$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            REGEXP_EXTRACT(
              tanggal_hpht_raw_clean,
              r'^\d+'
            )
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_hpht_date,


    -- --------------------------------------------------------
    -- HPL
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          tanggal_hpl_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          tanggal_hpl_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          tanggal_hpl_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          tanggal_hpl_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        REGEXP_EXTRACT(
          tanggal_hpl_raw_clean,
          r'\d{1,2}\.\d{1,2}\.\d{4}'
        )
      ),

      CASE
        WHEN REGEXP_CONTAINS(
          tanggal_hpl_raw_clean,
          r'^\d{5}(\.0+)?$'
        )
        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            REGEXP_EXTRACT(
              tanggal_hpl_raw_clean,
              r'^\d+'
            )
            AS INT64
          ) DAY
        )
      END
    ) AS tanggal_hpl_date,


    -- --------------------------------------------------------
    -- Actual file_date column
    -- --------------------------------------------------------
    COALESCE(
      SAFE_CAST(
        file_date_raw_clean AS DATE
      ),

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          file_date_raw_clean,
          r'\d{4}-\d{1,2}-\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        REGEXP_EXTRACT(
          file_date_raw_clean,
          r'\d{4}/\d{1,2}/\d{1,2}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          file_date_raw_clean,
          r'\d{1,2}/\d{1,2}/\d{4}'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          file_date_raw_clean,
          r'\d{1,2}-\d{1,2}-\d{4}'
        )
      )
    ) AS file_date_parsed,


    -- --------------------------------------------------------
    -- Actual ingestion timestamp
    -- --------------------------------------------------------
    SAFE_CAST(
      ingestion_timestamp_raw_clean
      AS TIMESTAMP
    ) AS ingestion_timestamp_parsed,


    -- --------------------------------------------------------
    -- Filename datetime fallback
    --
    -- e.g.
    -- ..._2025-08-01 09:17:49.981.xlsx
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATETIME(
        '%Y-%m-%d %H:%M:%E*S',
        REGEXP_EXTRACT(
          file_name,
          r'_(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?)'
        )
      ),

      DATETIME(
        SAFE.PARSE_DATE(
          '%Y-%m-%d',
          REGEXP_EXTRACT(
            file_name,
            r'(\d{4}-\d{2}-\d{2})'
          )
        )
      )
    ) AS file_datetime_from_name

  FROM identity_cleaned i
),


-- ============================================================
-- 5. NUMERIC NORMALIZATION
--
-- All raw STRING columns are retained.
-- ============================================================
typed AS (
  SELECT
    p.*,


    -- --------------------------------------------------------
    -- Age
    -- --------------------------------------------------------
    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(register_umur),
        r'-?\d+'
      )
      AS INT64
    ) AS umur_numeric,


    -- --------------------------------------------------------
    -- Gestational age as recorded by source
    -- --------------------------------------------------------
    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(register_usia_kehamilan),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS usia_kehamilan_numeric,


    -- --------------------------------------------------------
    -- Maternal anthropometry
    -- --------------------------------------------------------
    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(pemeriksaan_ibu_bbkg),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS bb_kg,

    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(pemeriksaan_ibu_tinggi_badan),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS tb_cm,

    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(pemeriksaan_ibu_lilacm),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS lila_cm,

    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(pemeriksaan_ibu_tfucm),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS tfu_cm,


    -- --------------------------------------------------------
    -- Blood pressure
    -- e.g. 120/80
    -- --------------------------------------------------------
    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(pemeriksaan_ibu_tdmmhg),
        r'^\s*(\d{2,3})\s*/'
      )
      AS FLOAT64
    ) AS sistole_numeric,

    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(pemeriksaan_ibu_tdmmhg),
        r'/\s*(\d{2,3})'
      )
      AS FLOAT64
    ) AS diastole_numeric,


    -- --------------------------------------------------------
    -- Number of fetuses
    -- --------------------------------------------------------
    SAFE_CAST(
      REGEXP_EXTRACT(
        TRIM(pemeriksaan_jumlah_janin),
        r'-?\d+'
      )
      AS INT64
    ) AS jumlah_janin_numeric,


    -- --------------------------------------------------------
    -- Singleton fetal measurements
    -- --------------------------------------------------------
    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(pemeriksaan_bayi_tunggal_djjxmenit),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS djj_tunggal_numeric,

    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(pemeriksaan_bayi_tunggal_tbjgr),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS tbj_tunggal_numeric,


    -- --------------------------------------------------------
    -- Multiple gestation fetal measurements
    -- --------------------------------------------------------
    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(pemeriksaan_bayi_jamak_djjxmenit),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS djj_jamak_numeric,

    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(pemeriksaan_bayi_jamak_tbjgr),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS tbj_jamak_numeric,


    -- --------------------------------------------------------
    -- Hb
    -- --------------------------------------------------------
    SAFE_CAST(
      REPLACE(
        REGEXP_EXTRACT(
          TRIM(laboratorium_periksa_hb_hasilgrdl),
          r'-?\d+(?:[.,]\d+)?'
        ),
        ',',
        '.'
      )
      AS FLOAT64
    ) AS hb_numeric

  FROM parsed p
),


-- ============================================================
-- 6. STANDARDIZATION
-- ============================================================
standardized AS (
  SELECT
    t.*,

    -- --------------------------------------------------------
    -- Visit
    -- --------------------------------------------------------
    tanggal_kunjungan_date AS anc_visit_date,


    -- --------------------------------------------------------
    -- Combined fetal fields for compatibility
    --
    -- Original tunggal/jamak values remain separately present.
    -- --------------------------------------------------------
    COALESCE(
      djj_tunggal_numeric,
      djj_jamak_numeric
    ) AS djj_combined_numeric,

    COALESCE(
      tbj_tunggal_numeric,
      tbj_jamak_numeric
    ) AS tbj_combined_numeric,

    COALESCE(
      NULLIF(
        TRIM(pemeriksaan_bayi_tunggal_presentasi4),
        ''
      ),
      NULLIF(
        TRIM(pemeriksaan_bayi_jamak_presentasi4),
        ''
      )
    ) AS presentasi_janin_combined,


    -- --------------------------------------------------------
    -- File/upload DATETIME for backward compatibility
    --
    -- Prefer actual ingestion metadata.
    -- --------------------------------------------------------
    COALESCE(
      CASE
        WHEN ingestion_timestamp_parsed IS NOT NULL
        THEN DATETIME(
          ingestion_timestamp_parsed,
          'Asia/Makassar'
        )
      END,

      CASE
        WHEN file_date_parsed IS NOT NULL
        THEN DATETIME(file_date_parsed)
      END,

      file_datetime_from_name
    ) AS file_date_upload,


    -- --------------------------------------------------------
    -- Recency timestamp used for dedup selection
    -- --------------------------------------------------------
    COALESCE(
      ingestion_timestamp_parsed,

      CASE
        WHEN file_date_parsed IS NOT NULL
        THEN TIMESTAMP(file_date_parsed)
      END,

      CASE
        WHEN file_datetime_from_name IS NOT NULL
        THEN TIMESTAMP(
          file_datetime_from_name,
          'Asia/Makassar'
        )
      END,

      TIMESTAMP '1900-01-01 00:00:00+00'
    ) AS source_recency_timestamp

  FROM typed t
),


-- ============================================================
-- 7. RECORD COMPLETENESS SCORE
-- ============================================================
scored AS (
  SELECT
    s.*,

    (
      IF(flag_nik_valid_16_digit, 1, 0)
      + IF(nama_ibu_clean IS NOT NULL, 1, 0)
      + IF(tanggal_lahir_date IS NOT NULL, 1, 0)
      + IF(tanggal_hpht_date IS NOT NULL, 1, 0)
      + IF(tanggal_hpl_date IS NOT NULL, 1, 0)
      + IF(anc_visit_date IS NOT NULL, 1, 0)
      + IF(usia_kehamilan_numeric IS NOT NULL, 1, 0)
      + IF(bb_kg IS NOT NULL, 1, 0)
      + IF(tb_cm IS NOT NULL, 1, 0)
      + IF(lila_cm IS NOT NULL, 1, 0)
      + IF(tfu_cm IS NOT NULL, 1, 0)
      + IF(sistole_numeric IS NOT NULL, 1, 0)
      + IF(diastole_numeric IS NOT NULL, 1, 0)
      + IF(jumlah_janin_numeric IS NOT NULL, 1, 0)
      + IF(djj_tunggal_numeric IS NOT NULL, 1, 0)
      + IF(djj_jamak_numeric IS NOT NULL, 1, 0)
      + IF(tbj_tunggal_numeric IS NOT NULL, 1, 0)
      + IF(tbj_jamak_numeric IS NOT NULL, 1, 0)
      + IF(hb_numeric IS NOT NULL, 1, 0)
      + IF(puskesmas_name_clean IS NOT NULL, 1, 0)
      + IF(NULLIF(TRIM(konseling), '') IS NOT NULL, 1, 0)
    ) AS row_completeness_score

  FROM standardized s
),


-- ============================================================
-- 8. EXACT CLINICAL DUPLICATE REMOVAL
--
-- Identical clinical data repeated across multiple exports.
--
-- This is safe even when NIK/name are missing.
-- ============================================================
exact_ranked AS (
  SELECT
    s.*,

    COUNT(*) OVER (
      PARTITION BY clinical_content_hash
    ) AS exact_duplicate_count,

    ROW_NUMBER() OVER (
      PARTITION BY clinical_content_hash
      ORDER BY
        source_recency_timestamp DESC,
        source_row_hash DESC
    ) AS exact_dedup_rank

  FROM scored s
),


exact_deduplicated AS (
  SELECT
    *
  FROM exact_ranked
  WHERE exact_dedup_rank = 1
),


-- ============================================================
-- 9. MOTHER IDENTITY
--
-- Hierarchy:
--
-- 1. Valid NIK
-- 2. Name + DOB + Puskesmas
-- 3. Name + HPHT + Puskesmas
-- 4. Weak identity
--
-- HPHT is only fallback identity evidence.
-- It does NOT define the ANC visit.
-- ============================================================
mother_keyed AS (
  SELECT
    e.*,

    CASE
      WHEN flag_nik_valid_16_digit = TRUE
        THEN 'NIK'

      WHEN
        nama_ibu_clean IS NOT NULL
        AND tanggal_lahir_date IS NOT NULL
        AND puskesmas_name_clean IS NOT NULL
        THEN 'NAME+DOB+PUSKESMAS'

      WHEN
        nama_ibu_clean IS NOT NULL
        AND tanggal_hpht_date IS NOT NULL
        AND puskesmas_name_clean IS NOT NULL
        THEN 'NAME+HPHT+PUSKESMAS'

      ELSE 'WEAK_MOTHER_IDENTITY'
    END AS mother_identity_method,


    CASE
      WHEN flag_nik_valid_16_digit = TRUE
      THEN CONCAT(
        'NIK|',
        nik_clean
      )

      WHEN
        nama_ibu_clean IS NOT NULL
        AND tanggal_lahir_date IS NOT NULL
        AND puskesmas_name_clean IS NOT NULL
      THEN CONCAT(
        'NAME_DOB_PKM|',
        nama_ibu_clean,
        '|',
        CAST(tanggal_lahir_date AS STRING),
        '|',
        puskesmas_name_clean
      )

      WHEN
        nama_ibu_clean IS NOT NULL
        AND tanggal_hpht_date IS NOT NULL
        AND puskesmas_name_clean IS NOT NULL
      THEN CONCAT(
        'NAME_HPHT_PKM|',
        nama_ibu_clean,
        '|',
        CAST(tanggal_hpht_date AS STRING),
        '|',
        puskesmas_name_clean
      )

      ELSE NULL
    END AS mother_identity_key

  FROM exact_deduplicated e
),


-- ============================================================
-- 10. VISIT ENCOUNTER KEY
--
-- One visit =
-- strong mother identity + visit date
--
-- IMPORTANT:
-- HPHT is NOT part of the primary encounter key.
--
-- If visit date is missing, do not encounter-deduplicate.
-- ============================================================
encounter_keyed AS (
  SELECT
    m.*,

    CASE
      WHEN
        mother_identity_method = 'NIK'
        AND anc_visit_date IS NOT NULL
      THEN 'NIK+VISIT_DATE'

      WHEN
        mother_identity_method = 'NAME+DOB+PUSKESMAS'
        AND anc_visit_date IS NOT NULL
      THEN 'NAME+DOB+PUSKESMAS+VISIT_DATE'

      WHEN
        mother_identity_method = 'NAME+HPHT+PUSKESMAS'
        AND anc_visit_date IS NOT NULL
      THEN 'NAME+HPHT+PUSKESMAS+VISIT_DATE'

      ELSE 'WEAK_KEY_DO_NOT_ENCOUNTER_DEDUP'
    END AS dedup_method,


    CASE
      WHEN
        mother_identity_key IS NOT NULL
        AND anc_visit_date IS NOT NULL
      THEN CONCAT(
        mother_identity_key,
        '|VISIT|',
        CAST(
          anc_visit_date
          AS STRING
        )
      )

      ELSE CONCAT(
        'SOURCE|',
        source_record_id,
        '|',
        clinical_content_hash
      )
    END AS anc_encounter_key

  FROM mother_keyed m
),


-- ============================================================
-- 11. VISIT-LEVEL DEDUPLICATION
--
-- If several source variants represent the same visit:
--
-- 1. latest source snapshot
-- 2. highest completeness
-- 3. deterministic row hash
-- ============================================================
encounter_ranked AS (
  SELECT
    e.*,

    COUNT(*) OVER (
      PARTITION BY anc_encounter_key
    ) AS encounter_variant_count,


    -- Includes exact duplicate source copies that were already
    -- collapsed in the previous stage.
    SUM(exact_duplicate_count) OVER (
      PARTITION BY anc_encounter_key
    ) AS raw_encounter_record_count,


    ROW_NUMBER() OVER (
      PARTITION BY anc_encounter_key
      ORDER BY
        source_recency_timestamp DESC,
        row_completeness_score DESC,
        source_row_hash DESC
    ) AS encounter_dedup_rank

  FROM encounter_keyed e
),


final_deduplicated AS (
  SELECT
    *
  FROM encounter_ranked
  WHERE encounter_dedup_rank = 1
)


-- ============================================================
-- 12. FINAL OUTPUT
--
-- Preserve original ePuskesmas fields AND add standardized
-- fields / ANC-compatible aliases.
-- ============================================================
SELECT
  f.* EXCEPT (
    exact_dedup_rank,
    encounter_dedup_rank
  ),


  -- ==========================================================
  -- STANDARDIZED SOURCE KEY
  -- ==========================================================
  CONCAT(
    'EPKIH_',
    TO_HEX(
      SHA256(anc_encounter_key)
    )
  ) AS epus_kunjungan_ibu_hamil_record_key,


  -- ==========================================================
  -- ANC-COMPATIBLE IDENTITY FIELDS
  -- ==========================================================
  CAST(register_nama_ibu AS STRING)
    AS nama,

  CAST(register_nik AS STRING)
    AS nik,

  CAST(register_no_ibu AS STRING)
    AS no_rm,

  tanggal_lahir_date
    AS tanggal_lahir,

  CAST(register_umur AS STRING)
    AS umur,


  -- ==========================================================
  -- CONTACT / LOCATION
  -- ==========================================================
  CAST(NULL AS STRING)
    AS prov_domisili,

  CAST(NULL AS STRING)
    AS kabkota_domisili,

  CAST(NULL AS STRING)
    AS kec_domisili,

  puskesmas_name_clean
    AS puskesmas,

  CAST(NULL AS STRING)
    AS desakel_domisili,

  CAST(NULL AS STRING)
    AS posyandu_domisili,

  CAST(register_alamat AS STRING)
    AS alamat_domisili,

  puskesmas_name_clean
    AS faskes_yang_melayani_anc,


  -- ==========================================================
  -- ANC CORE
  -- ==========================================================
  CAST(NULL AS STRING)
    AS pemeriksaan_pertama,

  tanggal_hpht_date
    AS tanggal_hpht,

  anc_visit_date
    AS pemeriksaan_anc_tanggal_anc,

  CAST(register_usia_kehamilan AS STRING)
    AS pemeriksaan_anc_usia_kehamilan,

  CAST(NULL AS STRING)
    AS pemeriksaan_anc_tenaga_pemeriksa,


  -- ==========================================================
  -- TT
  -- ==========================================================
  CAST(status_imunasi_tt AS STRING)
    AS pemeriksaan_anc_riwayat_imun_tt_terakhir,


  -- ==========================================================
  -- MATERNAL MEASUREMENTS
  -- ==========================================================
  bb_kg
    AS pemeriksaan_anc_berat,

  tb_cm
    AS pemeriksaan_anc_tinggi,

  lila_cm
    AS pemeriksaan_anc_lila,

  CAST(pemeriksaan_ibu_tdmmhg AS STRING)
    AS pemeriksaan_anc_tekanan_darah,

  tfu_cm
    AS pemeriksaan_anc_tfu,


  -- ==========================================================
  -- FETAL ASSESSMENT
  --
  -- Combined convenience fields.
  -- Original tunggal/jamak fields remain available in f.*.
  -- ==========================================================
  CAST(presentasi_janin_combined AS STRING)
    AS pemeriksaan_anc_presentasi_janin,

  djj_combined_numeric
    AS pemeriksaan_anc_djj,

  CAST(NULL AS STRING)
    AS pemeriksaan_anc_diperiksa_usg,

  CAST(NULL AS FLOAT64)
    AS pemeriksaan_anc_imt_sebelum_hamil,


  -- ==========================================================
  -- SUPPLEMENTS
  -- ==========================================================
  CAST(NULL AS STRING)
    AS pemeriksaan_anc_jumlah_ttd_diterima,

  CAST(NULL AS STRING)
    AS pemeriksaan_anc_jumlah_mms_diterima,


  -- ==========================================================
  -- LAB
  -- ==========================================================
  CAST(NULL AS STRING)
    AS pemeriksaan_anc_lab_golongan_darah,

  CAST(NULL AS STRING)
    AS pemeriksaan_anc_lab_rhesus,

  CAST(NULL AS STRING)
    AS pemeriksaan_anc_lab_hiv,

  NULLIF(
    TRIM(laboratorium_hbsag),
    ''
  ) AS pemeriksaan_anc_lab_hepatitis,

  CAST(laboratorium_sifilis AS STRING)
    AS pemeriksaan_anc_lab_siphilis,

  CAST(laboratorium_protein_uria AS STRING)
    AS pemeriksaan_anc_lab_protein_urine,

  hb_numeric
    AS pemeriksaan_anc_lab_hb,

  CAST(laboratorium_gula_darah AS STRING)
    AS pemeriksaan_anc_lab_gula_sewaktu,

  CAST(NULL AS STRING)
    AS pemeriksaan_anc_lab_lainnya,


  -- ==========================================================
  -- RISK / MANAGEMENT
  -- ==========================================================
  CAST(NULL AS STRING)
    AS pemeriksaan_anc_tatalaksana_anemia,

  CAST(integrasi_program_komplikasi_hdk AS STRING)
    AS pemeriksaan_anc_pre_eklampsia,

  CAST(NULL AS STRING)
    AS pemeriksaan_anc_tatalaksana_pre_eklampsia,

  CAST(pemeriksaan_ibu_status_gizi2 AS STRING)
    AS pemeriksaan_anc_status_gizi_kektidak_kek,

  CAST(NULL AS STRING)
    AS pemeriksaan_anc_tatalaksana_kek,

  CAST(NULL AS STRING)
    AS pemeriksaan_anc_risiko_masalah_kesehatan_lainnya,

  CAST(NULL AS STRING)
    AS pemeriksaan_anc_diberikan_tatalaksana_masalah_kesehatan_lainnya,

  CAST(konseling AS STRING)
    AS pemeriksaan_anc_konseling,

  CAST(NULL AS STRING)
    AS pemeriksaan_anc_skrinning_keswa,


  -- ==========================================================
  -- HPL
  -- ==========================================================
  tanggal_hpl_date
    AS pemeriksaan_anc_tanggal_perkiraan_persalinan,

  CAST(NULL AS STRING)
    AS pemeriksaan_anc_aksi,


  -- ==========================================================
  -- SOURCE
  -- ==========================================================
  'ePuskesmas Kunjungan Ibu Hamil'
    AS data_source,


  -- ==========================================================
  -- VALIDITY FLAGS
  -- ==========================================================
  flag_nik_valid_16_digit
    AS flag_nik_valid,

  tanggal_lahir_date IS NOT NULL
    AS flag_tanggal_lahir_valid,

  tanggal_hpht_date IS NOT NULL
    AS flag_tanggal_hpht_valid,

  anc_visit_date IS NOT NULL
    AS flag_tanggal_anc_valid,

  tanggal_hpl_date IS NOT NULL
    AS flag_tanggal_perkiraan_persalinan_valid,


  -- ==========================================================
  -- DUPLICATION QA
  -- ==========================================================
  raw_encounter_record_count
    AS duplicate_key_count,


  CASE
    WHEN exact_duplicate_count > 1
    THEN TRUE
    ELSE FALSE
  END AS is_exact_duplicate_group,


  CASE
    WHEN
      dedup_method != 'WEAK_KEY_DO_NOT_ENCOUNTER_DEDUP'
      AND raw_encounter_record_count > 1
    THEN TRUE
    ELSE FALSE
  END AS is_duplicate_group,


  CASE
    WHEN
      dedup_method = 'WEAK_KEY_DO_NOT_ENCOUNTER_DEDUP'
      AND exact_duplicate_count > 1
    THEN
      'Exact duplicate removed; visit retained separately because identity or visit date is insufficient for safe encounter deduplication'

    WHEN
      dedup_method = 'WEAK_KEY_DO_NOT_ENCOUNTER_DEDUP'
    THEN
      'Kept separately because identity or visit date is insufficient for safe encounter deduplication'

    WHEN raw_encounter_record_count > 1
    THEN
      'Deduplicated: latest/best version retained for the same pregnancy visit'

    ELSE
      'Unique pregnancy visit'
  END AS deduplication_status

FROM final_deduplicated f;
