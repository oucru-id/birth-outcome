-- v3 source builder with pregnancy-specific deletion exclusion. Run the complete file.
-- Prerequisite: sql/setup/01a_sigizi_deleted_registry.sql.
-- Follow immediately with 03a_sigizi_geography.sql before downstream core builds.
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

CREATE TEMP TABLE sigizi_source_unfiltered AS

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

-- BEGIN DELETION MATCH FUNCTIONS (also exercised by the regression tests).
-- Match-only normalization; do not change the published nama/nama_norm fields.
CREATE TEMP FUNCTION deletion_name_key(value STRING) AS (
  NULLIF(TRIM(REGEXP_REPLACE(
    REGEXP_REPLACE(NORMALIZE_AND_CASEFOLD(COALESCE(value, '')),
      r'[^a-z0-9 ]', ' '), r'\s+', ' ')), '')
);

CREATE TEMP FUNCTION deletion_match_rule(
  s_nik STRING, s_name STRING, s_dob DATE, s_anchor DATE,
  d_nik STRING, d_name STRING, d_dob DATE, d_anchor DATE
) RETURNS STRING AS (
  CASE
    WHEN s_anchor IS NULL OR d_anchor IS NULL OR s_anchor != d_anchor
      THEN NULL
    WHEN s_nik IS NOT NULL AND d_nik IS NOT NULL AND s_nik = d_nik
      THEN 'NIK_AND_PREGNANCY_ANCHOR'
    WHEN (s_nik IS NULL OR d_nik IS NULL)
      AND s_name IS NOT NULL AND d_name IS NOT NULL AND s_name = d_name
      AND s_dob IS NOT NULL AND d_dob IS NOT NULL AND s_dob = d_dob
      THEN 'NAME_DOB_AND_PREGNANCY_ANCHOR'
    ELSE NULL
  END
);
-- END DELETION MATCH FUNCTIONS

-- Read the deletion registry once. A missing/inaccessible view stops this build;
-- it must never silently disable exclusions. Raw registry retention is required.
CREATE TEMP TABLE sigizi_deletion_registry AS
SELECT
  d.*,
  deletion_name_key(COALESCE(NULLIF(nama_norm, ''), nama)) AS deletion_name_norm
FROM `spheres-lombok-barat.kohort_bumil_v3.vs_sigizi_bumil_hapus` AS d;

CREATE TEMP TABLE sigizi_deletion_features AS
SELECT
  ROW_NUMBER() OVER () AS source_row_instance,
  s AS source_record,
  COALESCE(hpht_date, DATE_SUB(hpl_date, INTERVAL 280 DAY))
    AS deletion_pregnancy_anchor_date,
  CASE WHEN hpht_date IS NOT NULL THEN 'HPHT'
       WHEN hpl_date IS NOT NULL THEN 'HPL_MINUS_280_DAYS'
       ELSE 'NO_PREGNANCY_ANCHOR' END AS deletion_anchor_method,
  deletion_name_key(COALESCE(NULLIF(nama_norm, ''), nama)) AS deletion_name_norm
FROM sigizi_source_unfiltered AS s;

-- An array preserves all matching registry references without multiplying rows.
-- Deletions are applied across the five SIGIZI clinical sources only.
CREATE TEMP TABLE sigizi_deletion_matches AS
SELECT
  s.source_row_instance,
  ARRAY_AGG(STRUCT(
      d.source_record_id AS registry_source_record_id,
      d.deleted_sigizi_pregnancy_key,
      d.hpht_date AS registry_hpht_date,
      d.tanggal_hapus_date,
      deletion_match_rule(
        s.source_record.nik_clean, s.deletion_name_norm,
        s.source_record.tanggal_lahir, s.deletion_pregnancy_anchor_date,
        d.nik_clean, d.deletion_name_norm, d.tanggal_lahir, d.hpht_date
      ) AS exclusion_match_rule
    ) ORDER BY d.deleted_sigizi_pregnancy_key, d.source_record_id
  ) AS deletion_matches
FROM sigizi_deletion_features AS s
JOIN sigizi_deletion_registry AS d
  ON s.deletion_pregnancy_anchor_date = d.hpht_date
  AND deletion_match_rule(
      s.source_record.nik_clean, s.deletion_name_norm,
      s.source_record.tanggal_lahir, s.deletion_pregnancy_anchor_date,
      d.nik_clean, d.deletion_name_norm, d.tanggal_lahir, d.hpht_date
    ) IS NOT NULL
GROUP BY s.source_row_instance;

CREATE TEMP TABLE sigizi_deletion_decisions AS
SELECT s.*, IFNULL(m.deletion_matches, []) AS deletion_matches
FROM sigizi_deletion_features AS s
LEFT JOIN sigizi_deletion_matches AS m USING (source_row_instance);

CREATE TEMP TABLE sigizi_deletion_run AS
SELECT
  GENERATE_UUID() AS exclusion_run_id,
  CURRENT_TIMESTAMP() AS exclusion_refreshed_at,
  'SIGIZI_PREGNANCY_DELETION_V1' AS exclusion_rule_version,
  (SELECT COUNT(*) FROM sigizi_deletion_registry) AS registry_rows,
  (SELECT COUNTIF(hpht_date IS NULL) FROM sigizi_deletion_registry)
    AS registry_rows_without_hpht,
  (SELECT COUNTIF(hpht_date IS NOT NULL AND nik_clean IS NULL
      AND (deletion_name_norm IS NULL OR tanggal_lahir IS NULL))
    FROM sigizi_deletion_registry) AS registry_rows_without_usable_identity,
  (SELECT COUNT(*) FROM sigizi_source_unfiltered) AS source_rows_before_exclusion,
  COUNTIF(ARRAY_LENGTH(deletion_matches) > 0) AS excluded_source_rows,
  COUNTIF(ARRAY_LENGTH(deletion_matches) = 0) AS active_source_rows,
  COUNTIF(deletion_pregnancy_anchor_date IS NULL) AS source_rows_without_anchor
FROM sigizi_deletion_decisions;

ASSERT (SELECT source_rows_before_exclusion = excluded_source_rows + active_source_rows
  FROM sigizi_deletion_run) AS 'Deletion gate changed source row multiplicity';

ASSERT NOT EXISTS (
  SELECT 1 FROM sigizi_source_unfiltered WHERE source_table = 'BUMIL_HAPUS'
) AS 'The deletion registry must not be a clinical source';

-- Latest-build audit, NOT an append-only history. Raw data are never deleted.
-- Contains sensitive source data; keep it inside the approved BigQuery dataset.
CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_deletion_exclusion_audit`
CLUSTER BY source_table, nik_clean AS
SELECT
  d.source_record.*,
  d.deletion_pregnancy_anchor_date,
  d.deletion_anchor_method,
  d.deletion_matches,
  r.exclusion_run_id,
  r.exclusion_refreshed_at,
  r.exclusion_rule_version
FROM sigizi_deletion_decisions AS d
CROSS JOIN sigizi_deletion_run AS r
WHERE ARRAY_LENGTH(d.deletion_matches) > 0;

-- Preserve the complete original public schema: no helper/audit columns leak.
CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_source_records`
CLUSTER BY source_table, nik_clean AS
SELECT source_record.*
FROM sigizi_deletion_decisions
WHERE ARRAY_LENGTH(deletion_matches) = 0;

-- Published last. A failed multi-statement job must block downstream execution.
CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_deletion_exclusion_summary`
AS SELECT * FROM sigizi_deletion_run;

SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_deletion_exclusion_summary`;
