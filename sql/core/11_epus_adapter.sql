-- Rebuild from v3 EPUS pregnancy master; replaces the old copy bridge.
-- Pregnancy-date plausibility bound recovered from original combined script.
DECLARE plausible_pregnancy_floor DATE DEFAULT DATE '2018-01-01';

-- Recovered source builder; v3 target. Run the complete file.
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
CREATE TEMP FUNCTION norm_name(s STRING)
RETURNS STRING
AS (
  NULLIF(
    TRIM(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          UPPER(
            TRIM(
              NORMALIZE(COALESCE(s, ''), NFKC)
            )
          ),
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
  NULLIF(
    REGEXP_REPLACE(
      COALESCE(s, ''),
      r'[^0-9]',
      ''
    ),
    ''
  )
);
CREATE TEMP FUNCTION is_sigizi_anon_placeholder(s STRING)
RETURNS BOOL
AS (
  REGEXP_CONTAINS(
    UPPER(TRIM(COALESCE(s, ''))),
    r'^ANON[_ -]?[0-9]+$'
  )
);
CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_adapter_v3_3`
CLUSTER BY nik_clean, epus_episode_id
AS

WITH src AS (
  SELECT
    TO_JSON_STRING(t) AS j
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_master` t
),

parsed AS (
  SELECT
    COALESCE(
      NULLIF(JSON_VALUE(j, '$.epus_pregnancy_key'), ''),
      NULLIF(JSON_VALUE(j, '$.pregnancy_key'), ''),
      NULLIF(JSON_VALUE(j, '$.pregnancy_episode_id'), ''),
      CAST(FARM_FINGERPRINT(j) AS STRING)
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
      NULLIF(JSON_VALUE(j, '$.nama'), ''),
      NULLIF(JSON_VALUE(j, '$.nama_pasien_clean'), ''),
      NULLIF(JSON_VALUE(j, '$.nama_norm'), '')
    ) AS nama_ibu,

    norm_name(
      COALESCE(
        JSON_VALUE(j, '$.nama_ibu'),
        JSON_VALUE(j, '$.nama_pasien'),
        JSON_VALUE(j, '$.nama'),
        JSON_VALUE(j, '$.nama_pasien_clean'),
        JSON_VALUE(j, '$.nama_norm')
      )
    ) AS nama_norm,

    norm_name_core(
      COALESCE(
        JSON_VALUE(j, '$.nama_ibu'),
        JSON_VALUE(j, '$.nama_pasien'),
        JSON_VALUE(j, '$.nama'),
        JSON_VALUE(j, '$.nama_pasien_clean'),
        JSON_VALUE(j, '$.nama_norm')
      )
    ) AS nama_core_norm,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.tanggal_lahir_ibu'),
        JSON_VALUE(j, '$.tanggal_lahir_date'),
        JSON_VALUE(j, '$.tanggal_lahir'),
        JSON_VALUE(j, '$.tgl_lahir_date')
      )
    ) AS tanggal_lahir_ibu,

    clean_phone(
      COALESCE(
        JSON_VALUE(j, '$.no_hp_clean'),
        JSON_VALUE(j, '$.nomor_hp_clean'),
        JSON_VALUE(j, '$.phone_normalized'),
        JSON_VALUE(j, '$.nomor_hp'),
        JSON_VALUE(j, '$.no_hp'),
        JSON_VALUE(j, '$.no_telepon_ibu')
      )
    ) AS no_hp_clean,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.puskesmas'), ''),
      NULLIF(JSON_VALUE(j, '$.puskesmas_name'), ''),
      NULLIF(JSON_VALUE(j, '$.anc_puskesmas_name'), ''),
      NULLIF(JSON_VALUE(j, '$.puskesmas_norm'), '')
    ) AS puskesmas,

    norm_text(
      COALESCE(
        JSON_VALUE(j, '$.puskesmas'),
        JSON_VALUE(j, '$.puskesmas_name'),
        JSON_VALUE(j, '$.anc_puskesmas_name'),
        JSON_VALUE(j, '$.puskesmas_norm')
      )
    ) AS puskesmas_norm,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.desa'), ''),
      NULLIF(JSON_VALUE(j, '$.desakel'), ''),
      NULLIF(JSON_VALUE(j, '$.kelurahan'), ''),
      NULLIF(JSON_VALUE(j, '$.desa_norm'), '')
    ) AS desa,

    norm_text(
      COALESCE(
        JSON_VALUE(j, '$.desa'),
        JSON_VALUE(j, '$.desakel'),
        JSON_VALUE(j, '$.kelurahan'),
        JSON_VALUE(j, '$.desa_norm')
      )
    ) AS desa_norm,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.posyandu'), ''),
      NULLIF(JSON_VALUE(j, '$.posyandu_domisili'), '')
    ) AS posyandu,

    COALESCE(
      NULLIF(JSON_VALUE(j, '$.alamat'), ''),
      NULLIF(JSON_VALUE(j, '$.alamat_domisili'), '')
    ) AS alamat,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.hpht_date'),
        JSON_VALUE(j, '$.tanggal_hpht_date'),
        JSON_VALUE(j, '$.anc_tanggal_hpht_date'),
        JSON_VALUE(j, '$.inc_tanggal_hpht_date'),
        JSON_VALUE(j, '$.tanggal_hpht')
      )
    ) AS hpht_epus_raw,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.hpl_date'),
        JSON_VALUE(j, '$.hpl_recorded_date'),
        JSON_VALUE(j, '$.tanggal_taksiran_persalinan_date'),
        JSON_VALUE(j, '$.anc_tanggal_taksiran_persalinan_date'),
        JSON_VALUE(j, '$.inc_tanggal_taksiran_persalinan_date')
      )
    ) AS hpl_epus_raw,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.actual_delivery_date'),
        JSON_VALUE(j, '$.delivery_date'),
        JSON_VALUE(j, '$.inc_delivery_date'),
        JSON_VALUE(j, '$.tanggal_melahirkan_date'),
        JSON_VALUE(j, '$.tanggal_melahirkan'),
        JSON_VALUE(j, '$.tanggal_persalinan_date'),
        JSON_VALUE(j, '$.tanggal_persalinan')
      )
    ) AS delivery_epus_raw,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.first_anc_date'),
        JSON_VALUE(j, '$.earliest_anc_date'),
        JSON_VALUE(j, '$.anc_date')
      )
    ) AS first_anc_date,

    parse_date_any(
      COALESCE(
        JSON_VALUE(j, '$.latest_anc_date'),
        JSON_VALUE(j, '$.last_anc_date')
      )
    ) AS last_anc_date,

    j

  FROM src
),

validated AS (
  SELECT
    *,

    CASE
      WHEN hpht_epus_raw BETWEEN
        plausible_pregnancy_floor
        AND CURRENT_DATE('Asia/Makassar')
      THEN hpht_epus_raw
    END AS hpht_epus,

    CASE
      WHEN hpl_epus_raw BETWEEN
        plausible_pregnancy_floor
        AND DATE_ADD(CURRENT_DATE('Asia/Makassar'), INTERVAL 300 DAY)
      THEN hpl_epus_raw
    END AS hpl_epus,

    CASE
      WHEN delivery_epus_raw BETWEEN
        plausible_pregnancy_floor
        AND DATE_ADD(CURRENT_DATE('Asia/Makassar'), INTERVAL 30 DAY)
      THEN delivery_epus_raw
    END AS delivery_epus

  FROM parsed
)

SELECT
  CONCAT(
    'EPUSEP_',
    TO_HEX(
      SHA256(epus_episode_source_key)
    )
  ) AS epus_episode_id,

  epus_episode_source_key,

  nik_clean,
  nama_ibu,
  nama_norm,
  nama_core_norm,
  tanggal_lahir_ibu,
  no_hp_clean,

  puskesmas,
  puskesmas_norm,
  desa,
  desa_norm,
  posyandu,
  alamat,

  hpht_epus,
  hpl_epus,
  delivery_epus,

  CASE
    WHEN hpht_epus IS NOT NULL
      THEN DATE_ADD(hpht_epus, INTERVAL 280 DAY)
  END AS hpl_from_epus_hpht,

  first_anc_date,
  last_anc_date,

  COALESCE(
    hpht_epus,
    DATE_SUB(hpl_epus, INTERVAL 280 DAY)
  ) AS pregnancy_anchor_date,

  j AS source_json

FROM validated
WHERE COALESCE(hpht_epus, hpl_epus) IS NOT NULL