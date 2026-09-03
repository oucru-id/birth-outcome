-- Recovered source builder; v3 target. Run the complete file.
-- ============================================================
-- STEP 1
-- STANDARDIZE THE 5 CLEANED SIGIZI VIEWS
--
-- Output:
--   t_sigizi_source_records
--
-- Grain:
--   one row = one already-deduplicated source record
--
-- IMPORTANT:
--   This layer does NOT redo source-level deduplication.
--   It consumes the cleaned fields already produced by each view.
-- ============================================================

CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_source_records`

CLUSTER BY
  source_table,
  nik_clean

AS

WITH source_union AS (

  -- ==========================================================
  -- ANC
  -- ==========================================================
  SELECT
    'ANC' AS source_table,
    2 AS source_priority,
    TO_JSON_STRING(t) AS source_json

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_sigizi_anc` t


  UNION ALL


  -- ==========================================================
  -- DAFTAR IBU
  -- ==========================================================
  SELECT
    'DAFTAR_IBU' AS source_table,
    4 AS source_priority,
    TO_JSON_STRING(t) AS source_json

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_sigizi_daftar_ibu` t


  UNION ALL


  -- ==========================================================
  -- DAFTAR IBU HAMIL
  -- ==========================================================
  SELECT
    'DAFTAR_IBU_HAMIL' AS source_table,
    1 AS source_priority,
    TO_JSON_STRING(t) AS source_json

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_sigizi_daftar_ibu_hamil` t


  UNION ALL


  -- ==========================================================
  -- KOHORT IBU
  -- ==========================================================
  SELECT
    'KOHORT_IBU' AS source_table,
    3 AS source_priority,
    TO_JSON_STRING(t) AS source_json

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_sigizi_kohort_ibu` t


  UNION ALL


  -- ==========================================================
  -- KOHORT NIFAS
  -- ==========================================================
  SELECT
    'KOHORT_NIFAS' AS source_table,
    5 AS source_priority,
    TO_JSON_STRING(t) AS source_json

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_sigizi_kohort_nifas` t
),


-- ============================================================
-- EXTRACT THE COMMON FIELDS
-- ============================================================
extracted AS (

  SELECT
    source_table,
    source_priority,


    -- ========================================================
    -- DATA SOURCE
    -- ========================================================
    COALESCE(
      NULLIF(
        JSON_VALUE(source_json, '$.data_source'),
        ''
      ),
      CONCAT('SIGIZI_', source_table)
    ) AS data_source,


    -- ========================================================
    -- SOURCE RECORD ID
    -- ========================================================
    COALESCE(
      NULLIF(
        JSON_VALUE(source_json, '$.source_record_id'),
        ''
      ),

      NULLIF(
        JSON_VALUE(source_json, '$.dedup_key'),
        ''
      ),

      NULLIF(
        JSON_VALUE(source_json, '$.uuid'),
        ''
      ),

      NULLIF(
        JSON_VALUE(source_json, '$.hash_code'),
        ''
      ),

      CAST(
        FARM_FINGERPRINT(source_json)
        AS STRING
      )
    ) AS source_record_id,


    -- ========================================================
    -- SOURCE-LEVEL LINKAGE FIELDS
    -- ========================================================
    NULLIF(
      JSON_VALUE(source_json, '$.mother_source_key'),
      ''
    ) AS source_mother_key,

    NULLIF(
      JSON_VALUE(source_json, '$.mother_match_method'),
      ''
    ) AS source_mother_match_method,

    COALESCE(
      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.pregnancy_anchor_date'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.pregnancy_hpht_date'
        )
        AS DATE
      )
    ) AS source_pregnancy_anchor_date,

    NULLIF(
      JSON_VALUE(
        source_json,
        '$.pregnancy_anchor_type'
      ),
      ''
    ) AS source_pregnancy_anchor_type,

    NULLIF(
      JSON_VALUE(source_json, '$.dedup_key'),
      ''
    ) AS source_dedup_key,

    NULLIF(
      JSON_VALUE(source_json, '$.dedup_method'),
      ''
    ) AS source_dedup_method,


    -- ========================================================
    -- NIK
    -- ========================================================
    COALESCE(
      NULLIF(
        JSON_VALUE(source_json, '$.nik_clean'),
        ''
      ),

      NULLIF(
        JSON_VALUE(source_json, '$.nik'),
        ''
      ),

      NULLIF(
        JSON_VALUE(source_json, '$.nik_ibu'),
        ''
      )
    ) AS nik_candidate,


    -- ========================================================
    -- NAME
    -- ========================================================
    COALESCE(
      NULLIF(
        JSON_VALUE(source_json, '$.nama'),
        ''
      ),

      NULLIF(
        JSON_VALUE(source_json, '$.nama_ibu'),
        ''
      ),

      NULLIF(
        JSON_VALUE(source_json, '$.nama_pasien'),
        ''
      )
    ) AS nama,

    NULLIF(
      JSON_VALUE(source_json, '$.nama_norm'),
      ''
    ) AS nama_norm_source,


    -- ========================================================
    -- DATE OF BIRTH
    -- ========================================================
    COALESCE(
      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tanggal_lahir'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tanggal_lahir_std'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tgl_lahir_date'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tgl_lahir'
        )
        AS DATE
      )
    ) AS tanggal_lahir,


    -- ========================================================
    -- DIRECT HPHT
    -- ========================================================
    COALESCE(
      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tanggal_hpht'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tanggal_hpht_std'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tgl_hpht_date'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tgl_hpht'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.hpht'
        )
        AS DATE
      )
    ) AS hpht_date,


    -- ========================================================
    -- HPL
    -- ========================================================
    COALESCE(
      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.pemeriksaan_anc_tanggal_perkiraan_persalinan'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tanggal_hpl_std'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tanggal_hpl'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tgl_hpl_date'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tgl_hpl'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.hpl'
        )
        AS DATE
      )
    ) AS hpl_date,


    -- ========================================================
    -- ANC DATE
    -- ========================================================
    COALESCE(
      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.pemeriksaan_anc_tanggal_anc'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tanggal_anc_std'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tanggal_anc'
        )
        AS DATE
      )
    ) AS anc_date,


    -- ========================================================
    -- DELIVERY DATE
    -- ========================================================
    COALESCE(
      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tanggal_melahirkan_std'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tanggal_melahirkan_date'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tgl_melahirkan_date'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tanggal_melahirkan'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tgl_melahirkan'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.status_persalinan_tanggal_melahirkan'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tanggal_persalinan'
        )
        AS DATE
      )
    ) AS delivery_date,


    -- ========================================================
    -- ABORTUS DATE
    -- ========================================================
    COALESCE(
      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tanggal_abortus_std'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tanggal_abortus_date'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tgl_abortus_date'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tanggal_abortus'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          source_json,
          '$.tgl_abortus'
        )
        AS DATE
      )
    ) AS abortion_date,


    -- ========================================================
    -- PUSKESMAS
    -- ========================================================
    COALESCE(
      NULLIF(
        JSON_VALUE(
          source_json,
          '$.puskesmas_domisili'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.puskesmas'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.pukesmas'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.puskesmas_name'
        ),
        ''
      )
    ) AS puskesmas,

    NULLIF(
      JSON_VALUE(source_json, '$.puskesmas_norm'),
      ''
    ) AS puskesmas_norm_source,


    -- ========================================================
    -- DESA
    -- ========================================================
    COALESCE(
      NULLIF(
        JSON_VALUE(
          source_json,
          '$.desakel_domisili'
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
          '$.desa'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.desa_kel'
        ),
        ''
      )
    ) AS desa,

    NULLIF(
      JSON_VALUE(source_json, '$.desa_norm'),
      ''
    ) AS desa_norm_source,


    -- ========================================================
    -- POSYANDU
    -- ========================================================
    COALESCE(
      NULLIF(
        JSON_VALUE(
          source_json,
          '$.posyandu_domisili'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.posyandu'
        ),
        ''
      )
    ) AS posyandu,


    -- ========================================================
    -- ADDRESS
    -- ========================================================
    COALESCE(
      NULLIF(
        JSON_VALUE(
          source_json,
          '$.alamat_domisili'
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
    ) AS alamat,


    -- ========================================================
    -- PHONE
    -- ========================================================
    COALESCE(
      NULLIF(
        JSON_VALUE(
          source_json,
          '$.no_hp_clean'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.no_telepon_ibu'
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
          '$.no_hp'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.no_telepon'
        ),
        ''
      )
    ) AS no_hp_candidate,


    -- ========================================================
    -- OUTCOME / STATUS
    -- ========================================================
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
        JSON_VALUE(
          source_json,
          '$.status'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          source_json,
          '$.outcome'
        ),
        ''
      )
    ) AS outcome_status,


    -- Keep original cleaned source row
    source_json

  FROM source_union
),


-- ============================================================
-- MINIMAL CROSS-SOURCE NORMALIZATION
-- ============================================================
normalized AS (

  SELECT
    e.*,

    NULLIF(
      REGEXP_REPLACE(
        COALESCE(nik_candidate, ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS nik_digits,

    COALESCE(
      nama_norm_source,

      NULLIF(
        TRIM(
          REGEXP_REPLACE(
            NORMALIZE_AND_CASEFOLD(
              COALESCE(nama, '')
            ),
            r'\s+',
            ' '
          )
        ),
        ''
      )
    ) AS nama_norm,

    COALESCE(
      puskesmas_norm_source,

      NULLIF(
        TRIM(
          REGEXP_REPLACE(
            NORMALIZE_AND_CASEFOLD(
              COALESCE(puskesmas, '')
            ),
            r'\s+',
            ' '
          )
        ),
        ''
      )
    ) AS puskesmas_norm,

    COALESCE(
      desa_norm_source,

      NULLIF(
        TRIM(
          REGEXP_REPLACE(
            NORMALIZE_AND_CASEFOLD(
              COALESCE(desa, '')
            ),
            r'\s+',
            ' '
          )
        ),
        ''
      )
    ) AS desa_norm,

    NULLIF(
      REGEXP_REPLACE(
        COALESCE(no_hp_candidate, ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) AS no_hp_clean

  FROM extracted e
)


-- ============================================================
-- FINAL STANDARDIZED SOURCE TABLE
-- ============================================================
SELECT
  source_table,
  source_priority,
  data_source,

  source_record_id,

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

  nama,
  nama_norm,
  tanggal_lahir,

  hpht_date,
  hpl_date,
  anc_date,
  delivery_date,
  abortion_date,

  source_pregnancy_anchor_date AS pregnancy_anchor_date,
  source_pregnancy_anchor_type AS pregnancy_anchor_type,

  puskesmas,
  puskesmas_norm,

  desa,
  desa_norm,

  posyandu,
  alamat,

  no_hp_clean AS no_hp,

  outcome_status,

  source_mother_key,
  source_mother_match_method,

  source_dedup_key,
  source_dedup_method,

  source_json

FROM normalized;