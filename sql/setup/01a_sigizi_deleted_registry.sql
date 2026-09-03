-- One-time setup/redeployment. This is an exclusion registry, not a clinical source.
-- Recovered v2 deletion adapter, retargeted to v3; corrected missing comma after `no`.
-- Raw deletion exports must be refreshed before the recurring SIGIZI source build.
CREATE OR REPLACE VIEW
  `spheres-lombok-barat.kohort_bumil_v3.vs_sigizi_bumil_hapus`
AS
WITH
-- ============================================================
-- 1. RAW SOURCE
-- ============================================================
source AS (
  SELECT
   CAST(`no` AS STRING) AS `no`,
    CAST(nik AS STRING) AS nik_raw,
    CAST(nama AS STRING) AS nama_raw,
    CAST(tgl_lahir AS STRING) AS tgl_lahir_raw,
    CAST(tgl_hpht AS STRING) AS tgl_hpht_raw,

    CAST(prov AS STRING) AS prov_raw,
    CAST(kabkota AS STRING) AS kabkota_raw,
    CAST(kec AS STRING) AS kec_raw,
    CAST(puskesmas AS STRING) AS puskesmas_raw,
    CAST(desakel AS STRING) AS desakel_raw,
    CAST(posyandu AS STRING) AS posyandu_raw,

    CAST(tanggal_hapus AS STRING) AS tanggal_hapus_raw,
    CAST(dihapus_oleh AS STRING) AS dihapus_oleh_raw,
    CAST(tindakan AS STRING) AS tindakan_raw,

    CAST(puskesmas_name AS STRING) AS puskesmas_name_raw,
    CAST(puskesmas_id AS STRING) AS puskesmas_id,

    CAST(file_name AS STRING) AS file_name,
    CAST(file_date AS STRING) AS file_date_raw,
    CAST(ingestion_timestamp AS STRING) AS ingestion_timestamp_raw,

    CAST(uuid AS STRING) AS uuid,
    CAST(hash_code AS STRING) AS hash_code

  FROM
    `spheres-lombok-barat.raw_data.sigizi_bumil_hapus_new`
),


-- ============================================================
-- 2. BASIC STRING CLEANING
-- ============================================================
cleaned AS (
  SELECT
    *,

    -- --------------------------------------------------------
    -- NIK
    -- --------------------------------------------------------
    NULLIF(
      REGEXP_REPLACE(
        TRIM(COALESCE(nik_raw, '')),
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
          REGEXP_REPLACE(
            NORMALIZE_AND_CASEFOLD(
              TRIM(COALESCE(nama_raw, ''))
            ),
            r'[^a-z0-9 ]',
            ' '
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS nama_norm,


    -- --------------------------------------------------------
    -- LOCATION
    -- --------------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            TRIM(COALESCE(prov_raw, ''))
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS prov_norm,

    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            TRIM(COALESCE(kabkota_raw, ''))
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS kabkota_norm,

    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            TRIM(COALESCE(kec_raw, ''))
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS kec_norm,

    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            TRIM(
              COALESCE(
                NULLIF(puskesmas_raw, ''),
                NULLIF(puskesmas_name_raw, ''),
                ''
              )
            )
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS puskesmas_norm,

    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            TRIM(COALESCE(desakel_raw, ''))
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS desa_norm,

    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            TRIM(COALESCE(posyandu_raw, ''))
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS posyandu_norm

  FROM source
),


-- ============================================================
-- 3. DATE PARSING
-- ============================================================
parsed AS (
  SELECT
    *,

    -- --------------------------------------------------------
    -- DATE OF BIRTH
    -- --------------------------------------------------------
    COALESCE(
      SAFE_CAST(NULLIF(TRIM(tgl_lahir_raw), '') AS DATE),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        NULLIF(TRIM(tgl_lahir_raw), '')
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        NULLIF(TRIM(tgl_lahir_raw), '')
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        NULLIF(TRIM(tgl_lahir_raw), '')
      ),

      DATE(
        SAFE_CAST(
          NULLIF(TRIM(tgl_lahir_raw), '')
          AS TIMESTAMP
        ),
        'Asia/Makassar'
      )
    ) AS tanggal_lahir,


    -- --------------------------------------------------------
    -- HPHT
    -- --------------------------------------------------------
    COALESCE(
      SAFE_CAST(NULLIF(TRIM(tgl_hpht_raw), '') AS DATE),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        NULLIF(TRIM(tgl_hpht_raw), '')
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        NULLIF(TRIM(tgl_hpht_raw), '')
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        NULLIF(TRIM(tgl_hpht_raw), '')
      ),

      DATE(
        SAFE_CAST(
          NULLIF(TRIM(tgl_hpht_raw), '')
          AS TIMESTAMP
        ),
        'Asia/Makassar'
      )
    ) AS hpht_date,


    -- --------------------------------------------------------
    -- DELETION DATE
    -- --------------------------------------------------------
    COALESCE(
      SAFE_CAST(
        NULLIF(TRIM(tanggal_hapus_raw), '')
        AS DATE
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        NULLIF(TRIM(tanggal_hapus_raw), '')
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        NULLIF(TRIM(tanggal_hapus_raw), '')
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        NULLIF(TRIM(tanggal_hapus_raw), '')
      ),

      DATE(
        SAFE_CAST(
          NULLIF(TRIM(tanggal_hapus_raw), '')
          AS TIMESTAMP
        ),
        'Asia/Makassar'
      )
    ) AS tanggal_hapus_date,


    -- --------------------------------------------------------
    -- FILE DATE
    -- --------------------------------------------------------
    COALESCE(
      SAFE_CAST(
        NULLIF(TRIM(file_date_raw), '')
        AS DATE
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        NULLIF(TRIM(file_date_raw), '')
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        NULLIF(TRIM(file_date_raw), '')
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        NULLIF(TRIM(file_date_raw), '')
      )
    ) AS file_date_parsed,


    -- --------------------------------------------------------
    -- INGESTION TIMESTAMP
    -- --------------------------------------------------------
    COALESCE(
      SAFE_CAST(
        NULLIF(TRIM(ingestion_timestamp_raw), '')
        AS TIMESTAMP
      ),

      TIMESTAMP(
        SAFE_CAST(
          NULLIF(TRIM(ingestion_timestamp_raw), '')
          AS DATETIME
        ),
        'Asia/Makassar'
      )
    ) AS ingestion_ts

  FROM cleaned
),


-- ============================================================
-- 4. NIK VALIDATION + SOURCE ID
-- ============================================================
identity_prepared AS (
  SELECT
    *,

    CASE
      WHEN REGEXP_CONTAINS(
        COALESCE(nik_digits, ''),
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
        COALESCE(nik_digits, ''),
        r'^\d{16}$'
      )
      AND nik_digits NOT IN (
        '0000000000000000',
        '9999999999999999'
      )
      THEN TRUE
      ELSE FALSE
    END AS flag_nik_valid,

    COALESCE(
      NULLIF(TRIM(uuid), ''),
      NULLIF(TRIM(hash_code), ''),
      CAST(
        FARM_FINGERPRINT(
          TO_JSON_STRING(
            STRUCT(
              nik_raw,
              nama_raw,
              tgl_lahir_raw,
              tgl_hpht_raw,
              puskesmas_raw,
              desakel_raw,
              tanggal_hapus_raw,
              tindakan_raw,
              file_name
            )
          )
        )
        AS STRING
      )
    ) AS source_record_id

  FROM parsed
),


-- ============================================================
-- 5. CREATE MOTHER AND PREGNANCY MATCHING KEYS
-- ============================================================
matching_keys AS (
  SELECT
    *,

    -- ========================================================
    -- MOTHER MATCH KEY
    --
    -- Important:
    -- This is only a candidate matching key.
    -- NIK is strongest.
    -- Name + DOB + location is fallback.
    -- ========================================================
    CASE

      WHEN nik_clean IS NOT NULL
        THEN CONCAT(
          'NIK|',
          nik_clean
        )

      WHEN
        nama_norm IS NOT NULL
        AND tanggal_lahir IS NOT NULL
        AND desa_norm IS NOT NULL
        THEN CONCAT(
          'NAME_DOB_DESA|',
          nama_norm,
          '|',
          CAST(tanggal_lahir AS STRING),
          '|',
          desa_norm
        )

      WHEN
        nama_norm IS NOT NULL
        AND tanggal_lahir IS NOT NULL
        AND puskesmas_norm IS NOT NULL
        THEN CONCAT(
          'NAME_DOB_PKM|',
          nama_norm,
          '|',
          CAST(tanggal_lahir AS STRING),
          '|',
          puskesmas_norm
        )

      ELSE CONCAT(
        'SOURCE|',
        source_record_id
      )

    END AS mother_match_key,


    CASE

      WHEN nik_clean IS NOT NULL
        THEN 'NIK'

      WHEN
        nama_norm IS NOT NULL
        AND tanggal_lahir IS NOT NULL
        AND desa_norm IS NOT NULL
        THEN 'NAMA+DOB+DESA'

      WHEN
        nama_norm IS NOT NULL
        AND tanggal_lahir IS NOT NULL
        AND puskesmas_norm IS NOT NULL
        THEN 'NAMA+DOB+PUSKESMAS'

      ELSE 'SOURCE_RECORD'

    END AS mother_match_method,


    -- ========================================================
    -- PREGNANCY MATCH KEY
    --
    -- HPHT is the pregnancy anchor.
    --
    -- We intentionally DO NOT use NIK alone as pregnancy key,
    -- because one woman may have multiple pregnancies.
    -- ========================================================
    CASE

      WHEN
        nik_clean IS NOT NULL
        AND hpht_date IS NOT NULL
        THEN CONCAT(
          'NIK_HPHT|',
          nik_clean,
          '|',
          CAST(hpht_date AS STRING)
        )

      WHEN
        nama_norm IS NOT NULL
        AND tanggal_lahir IS NOT NULL
        AND hpht_date IS NOT NULL
        AND desa_norm IS NOT NULL
        THEN CONCAT(
          'NAME_DOB_HPHT_DESA|',
          nama_norm,
          '|',
          CAST(tanggal_lahir AS STRING),
          '|',
          CAST(hpht_date AS STRING),
          '|',
          desa_norm
        )

      WHEN
        nama_norm IS NOT NULL
        AND tanggal_lahir IS NOT NULL
        AND hpht_date IS NOT NULL
        AND puskesmas_norm IS NOT NULL
        THEN CONCAT(
          'NAME_DOB_HPHT_PKM|',
          nama_norm,
          '|',
          CAST(tanggal_lahir AS STRING),
          '|',
          CAST(hpht_date AS STRING),
          '|',
          puskesmas_norm
        )

      ELSE CONCAT(
        'SOURCE|',
        source_record_id
      )

    END AS deleted_pregnancy_match_key,


    CASE

      WHEN
        nik_clean IS NOT NULL
        AND hpht_date IS NOT NULL
        THEN 'NIK+HPHT'

      WHEN
        nama_norm IS NOT NULL
        AND tanggal_lahir IS NOT NULL
        AND hpht_date IS NOT NULL
        AND desa_norm IS NOT NULL
        THEN 'NAMA+DOB+HPHT+DESA'

      WHEN
        nama_norm IS NOT NULL
        AND tanggal_lahir IS NOT NULL
        AND hpht_date IS NOT NULL
        AND puskesmas_norm IS NOT NULL
        THEN 'NAMA+DOB+HPHT+PUSKESMAS'

      ELSE 'UNRESOLVED_NO_PREGNANCY_ID'

    END AS pregnancy_match_method,


    CASE

      WHEN
        nik_clean IS NOT NULL
        AND hpht_date IS NOT NULL
        THEN 'HIGH'

      WHEN
        nama_norm IS NOT NULL
        AND tanggal_lahir IS NOT NULL
        AND hpht_date IS NOT NULL
        THEN 'MEDIUM'

      ELSE 'LOW'

    END AS pregnancy_match_confidence

  FROM identity_prepared
),


-- ============================================================
-- 6. CREATE STABLE HASH KEYS
-- ============================================================
keyed AS (
  SELECT
    *,

    CONCAT(
      'SIGM_',
      TO_HEX(
        SHA256(mother_match_key)
      )
    ) AS sigizi_mother_key,

    CONCAT(
      'SIGDEL_',
      TO_HEX(
        SHA256(deleted_pregnancy_match_key)
      )
    ) AS deleted_sigizi_pregnancy_key

  FROM matching_keys
),


-- ============================================================
-- 7. DEDUPLICATION
--
-- For records with strong pregnancy identity:
--   one woman + one HPHT = one deleted pregnancy record.
--
-- For unresolved records:
--   source_record_id prevents unrelated pregnancies from
--   being incorrectly merged.
--
-- Most recently ingested record is retained.
-- ============================================================
ranked AS (
  SELECT
    *,

    COUNT(*) OVER (
      PARTITION BY deleted_pregnancy_match_key
    ) AS source_record_count,

    MIN(tanggal_hapus_date) OVER (
      PARTITION BY deleted_pregnancy_match_key
    ) AS first_tanggal_hapus,

    MAX(tanggal_hapus_date) OVER (
      PARTITION BY deleted_pregnancy_match_key
    ) AS last_tanggal_hapus,

    ROW_NUMBER() OVER (
      PARTITION BY deleted_pregnancy_match_key
      ORDER BY
        ingestion_ts DESC NULLS LAST,
        file_date_parsed DESC NULLS LAST,
        tanggal_hapus_date DESC NULLS LAST,
        source_record_id DESC
    ) AS row_priority

  FROM keyed
)


-- ============================================================
-- 8. FINAL VIEW
-- ============================================================
SELECT
  -- ----------------------------------------------------------
  -- SOURCE
  -- ----------------------------------------------------------
  'BUMIL_HAPUS' AS source_table,
  'SIGIZI_BUMIL_HAPUS' AS data_source,

  -- Audit metadata only; this registry must NOT be unioned into clinical sources.
  6 AS source_priority,

  source_record_id,
  `no`,

  uuid,
  hash_code,


  -- ----------------------------------------------------------
  -- MOTHER IDENTITY
  -- ----------------------------------------------------------
  nik_raw,
  nik_clean,
  flag_nik_valid,

  nama_raw AS nama,
  nama_norm,

  tanggal_lahir,

  sigizi_mother_key,
  mother_match_key,
  mother_match_method,


  -- ----------------------------------------------------------
  -- PREGNANCY
  -- ----------------------------------------------------------
  hpht_date,

  -- In this source HPHT is the available pregnancy anchor.
  hpht_date AS pregnancy_reference_date,

  deleted_sigizi_pregnancy_key,
  deleted_pregnancy_match_key,

  pregnancy_match_method,
  pregnancy_match_confidence,


  -- ----------------------------------------------------------
  -- LOCATION
  -- ----------------------------------------------------------
  prov_raw AS prov,
  prov_norm,

  kabkota_raw AS kabkota,
  kabkota_norm,

  kec_raw AS kec,
  kec_norm,

  puskesmas_raw AS puskesmas,
  puskesmas_name_raw AS puskesmas_name,
  puskesmas_id,
  puskesmas_norm,

  desakel_raw AS desakel,
  desa_norm,

  posyandu_raw AS posyandu,
  posyandu_norm,


  -- ----------------------------------------------------------
  -- DELETION INFORMATION
  -- ----------------------------------------------------------
  tanggal_hapus_raw,
  tanggal_hapus_date,

  first_tanggal_hapus,
  last_tanggal_hapus,

  dihapus_oleh_raw AS dihapus_oleh,
  tindakan_raw AS tindakan,

  TRUE AS is_deleted_from_sigizi,


  -- ----------------------------------------------------------
  -- INGESTION / FILE
  -- ----------------------------------------------------------
  file_name,
  file_date_raw,
  file_date_parsed,

  ingestion_timestamp_raw,
  ingestion_ts,


  -- ----------------------------------------------------------
  -- DEDUP QA
  -- ----------------------------------------------------------
  source_record_count,

  CASE
    WHEN source_record_count > 1
      THEN TRUE
    ELSE FALSE
  END AS flag_source_duplicate

FROM ranked

WHERE row_priority = 1;

