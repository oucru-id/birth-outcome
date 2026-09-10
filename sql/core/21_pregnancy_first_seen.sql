-- ============================================================================
-- STAGE 21 - PREGNANCY FIRST-SEEN / NEW-PREGNANCY LINEAGE
--
-- Purpose
--   Determine when each canonical pregnancy was first observable in the data
--   system, independently of ANC visit number (K1/V1 is not required).
--
-- Run after
--   20_pregnancy_canonicalization.sql
--
-- Grain
--   t_pregnancy_source_upload_lineage_v3_3:
--     one canonical pregnancy x one contributing source record
--
--   t_pregnancy_upload_summary_v3_3:
--     one canonical pregnancy
--
-- Definitions
--   pregnancy_first_upload_timestamp:
--     earliest export/upload timestamp found in a contributing file name.
--
--   pregnancy_first_ingestion_timestamp:
--     earliest warehouse ingestion timestamp found for a contributing record.
--
--   pregnancy_first_seen_timestamp:
--     first-upload timestamp, with first-ingestion timestamp as fallback.
--
-- Important
--   Raw history is inspected before the latest-row source deduplication whenever
--   a stable UUID/hash is available. Records without a stable raw identifier use
--   the timestamp retained by the cleaned source row and are explicitly flagged.
-- ============================================================================


CREATE TEMP FUNCTION parse_filename_upload_timestamp(file_name STRING)
RETURNS TIMESTAMP
AS (
  SAFE.PARSE_TIMESTAMP(
    '%Y-%m-%d %H:%M:%E*S',
    REGEXP_REPLACE(
      REGEXP_EXTRACT(
        file_name,
        r'(\d{4}-\d{2}-\d{2}[ T_]\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
      ),
      r'[T_]',
      ' '
    ),
    'Asia/Makassar'
  )
);


CREATE TEMP FUNCTION parse_ingestion_timestamp(value STRING)
RETURNS TIMESTAMP
AS (
  COALESCE(
    SAFE_CAST(NULLIF(TRIM(value), '') AS TIMESTAMP),
    SAFE.PARSE_TIMESTAMP(
      '%Y-%m-%d %H:%M:%E*S',
      NULLIF(TRIM(value), ''),
      'Asia/Makassar'
    )
  )
);


-- ============================================================================
-- A. RAW HISTORY BY STABLE SOURCE IDENTIFIER
--
-- TO_JSON_STRING/JSON_VALUE are intentional. They keep this audit resilient to
-- minor schema differences between the nine raw source tables.
-- ============================================================================

CREATE OR REPLACE TEMP TABLE `_SESSION.t_raw_source_first_seen_v3_3`
CLUSTER BY source_system, source_table, stable_source_record_id
AS
WITH raw_union AS (
  SELECT 'SIGIZI' AS source_system, 'ANC' AS source_table,
         TO_JSON_STRING(t) AS raw_json
  FROM `spheres-lombok-barat.raw_data.sigizi_kesga_bumil_anc` t

  UNION ALL
  SELECT 'SIGIZI', 'DAFTAR_IBU', TO_JSON_STRING(t)
  FROM `spheres-lombok-barat.raw_data.sigizi_daftar_ibu` t

  UNION ALL
  SELECT 'SIGIZI', 'DAFTAR_IBU_HAMIL', TO_JSON_STRING(t)
  FROM `spheres-lombok-barat.raw_data.sigizi_daftar_ibu_hamil` t

  UNION ALL
  SELECT 'SIGIZI', 'KOHORT_IBU', TO_JSON_STRING(t)
  FROM `spheres-lombok-barat.raw_data.sigizi_kohort_ibu` t

  UNION ALL
  SELECT 'SIGIZI', 'KOHORT_NIFAS', TO_JSON_STRING(t)
  FROM `spheres-lombok-barat.raw_data.sigizi_ibu_nifas` t

  UNION ALL
  SELECT 'EPUS', 'EPUS_ANC', TO_JSON_STRING(t)
  FROM `spheres-lombok-barat.raw_data.epus_anc` t

  UNION ALL
  SELECT 'EPUS', 'EPUS_INC', TO_JSON_STRING(t)
  FROM `spheres-lombok-barat.raw_data.epus_inc` t

  UNION ALL
  SELECT 'EPUS', 'EPUS_PNC', TO_JSON_STRING(t)
  FROM `spheres-lombok-barat.raw_data.epus_pnc` t

  UNION ALL
  SELECT 'EPUS', 'EPUS_KUNJUNGAN_IBU_HAMIL', TO_JSON_STRING(t)
  FROM `spheres-lombok-barat.raw_data.epus_kunjungan_ibu_hamil` t
),

parsed AS (
  SELECT
    source_system,
    source_table,

    COALESCE(
      NULLIF(TRIM(JSON_VALUE(raw_json, '$.uuid')), ''),
      NULLIF(TRIM(JSON_VALUE(raw_json, '$.hash_code')), '')
    ) AS stable_source_record_id,

    JSON_VALUE(raw_json, '$.file_name') AS file_name,

    parse_filename_upload_timestamp(
      JSON_VALUE(raw_json, '$.file_name')
    ) AS file_upload_timestamp,

    parse_ingestion_timestamp(
      COALESCE(
        JSON_VALUE(raw_json, '$.ingestion_timestamp'),
        JSON_VALUE(raw_json, '$.ingestion_ts')
      )
    ) AS ingestion_timestamp

  FROM raw_union
),

eligible AS (
  SELECT *
  FROM parsed
  WHERE stable_source_record_id IS NOT NULL
)

SELECT
  source_system,
  source_table,
  stable_source_record_id,

  ARRAY_AGG(
    file_name IGNORE NULLS
    ORDER BY file_upload_timestamp, file_name
    LIMIT 1
  )[SAFE_OFFSET(0)] AS first_file_name,

  MIN(file_upload_timestamp) AS first_file_upload_timestamp,
  MAX(file_upload_timestamp) AS last_file_upload_timestamp,
  MIN(ingestion_timestamp) AS first_ingestion_timestamp,
  MAX(ingestion_timestamp) AS last_ingestion_timestamp,
  COUNT(*) AS raw_version_count

FROM eligible
GROUP BY
  source_system,
  source_table,
  stable_source_record_id;


-- ============================================================================
-- B. FINAL PREGNANCY -> SIGIZI SOURCE RECORDS
-- ============================================================================

CREATE OR REPLACE TEMP TABLE `_SESSION.t_sigizi_selected_lineage_v3_3`
CLUSTER BY pregnancy_episode_id, source_table
AS
WITH final_episodes AS (
  SELECT DISTINCT
    p.pregnancy_episode_id,
    p.pregnancy_source_combination,
    episode_id AS sigizi_episode_id

  FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` p

  CROSS JOIN UNNEST(
    ARRAY(
      SELECT DISTINCT x
      FROM UNNEST(
        ARRAY_CONCAT(
          COALESCE(p.canonical_sigizi_episode_ids, ARRAY<STRING>[]),
          IF(
            p.sigizi_episode_id IS NULL,
            ARRAY<STRING>[],
            [p.sigizi_episode_id]
          )
        )
      ) x
      WHERE x IS NOT NULL
    )
  ) episode_id
),

member_records AS (
  SELECT DISTINCT
    f.pregnancy_episode_id,
    f.pregnancy_source_combination,
    f.sigizi_episode_id,
    source_record_id

  FROM final_episodes f

  JOIN `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_canonical_v3_3` c
    ON c.sigizi_episode_id = f.sigizi_episode_id

  CROSS JOIN UNNEST(
    COALESCE(c.sigizi_member_source_record_ids, ARRAY<STRING>[])
  ) source_record_id
)

SELECT DISTINCT
  m.pregnancy_episode_id,
  m.pregnancy_source_combination,
  'SIGIZI' AS source_system,
  s.source_table,

  CONCAT(
    'SIGIZI|',
    COALESCE(s.source_table, 'UNKNOWN'),
    '|',
    COALESCE(s.source_record_id, 'UNKNOWN')
  ) AS source_record_key,

  s.source_record_id,
  m.sigizi_episode_id AS source_episode_id,
  s.file_name AS selected_file_name,
  parse_filename_upload_timestamp(s.file_name)
    AS selected_file_upload_timestamp,
  s.ingestion_timestamp AS selected_ingestion_timestamp,
  COALESCE(
    s.ingestion_timestamp,
    parse_filename_upload_timestamp(s.file_name)
  ) AS selected_source_observed_timestamp

FROM member_records m
JOIN `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_source_records` s
  ON s.source_record_id = m.source_record_id;


-- ============================================================================
-- C. FINAL PREGNANCY -> EPUS SOURCE RECORDS
-- ============================================================================

CREATE OR REPLACE TEMP TABLE `_SESSION.t_epus_selected_lineage_v3_3`
CLUSTER BY pregnancy_episode_id, source_table
AS
WITH final_keys AS (
  SELECT DISTINCT
    p.pregnancy_episode_id,
    p.pregnancy_source_combination,
    source_key AS epus_pregnancy_key

  FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` p

  CROSS JOIN UNNEST(
    ARRAY(
      SELECT DISTINCT x
      FROM UNNEST(
        ARRAY_CONCAT(
          COALESCE(p.epus_episode_source_keys, ARRAY<STRING>[]),
          IF(
            p.epus_episode_source_key IS NULL,
            ARRAY<STRING>[],
            [p.epus_episode_source_key]
          )
        )
      ) x
      WHERE x IS NOT NULL
    )
  ) source_key
),

member_records AS (
  SELECT DISTINCT
    f.pregnancy_episode_id,
    f.pregnancy_source_combination,
    f.epus_pregnancy_key,
    r.epus_source_record_key

  FROM final_keys f

  JOIN `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_records` r
    ON r.epus_pregnancy_key = f.epus_pregnancy_key
)

SELECT DISTINCT
  m.pregnancy_episode_id,
  m.pregnancy_source_combination,
  'EPUS' AS source_system,
  s.source_table,
  s.epus_source_record_key AS source_record_key,
  s.source_record_id,
  m.epus_pregnancy_key AS source_episode_id,
  s.file_name AS selected_file_name,

  COALESCE(
    parse_filename_upload_timestamp(s.file_name),
    TIMESTAMP(s.file_date_parsed, 'Asia/Makassar')
  ) AS selected_file_upload_timestamp,

  s.ingestion_timestamp_parsed AS selected_ingestion_timestamp,

  COALESCE(
    s.source_recency_timestamp,
    s.ingestion_timestamp_parsed,
    parse_filename_upload_timestamp(s.file_name),
    TIMESTAMP(s.file_date_parsed, 'Asia/Makassar')
  ) AS selected_source_observed_timestamp

FROM member_records m
JOIN `spheres-lombok-barat.kohort_bumil_v3.t_epus_source_records` s
  ON s.epus_source_record_key = m.epus_source_record_key;


-- ============================================================================
-- D. ANC-SPECIFIC RETAINED FIRST FILE
--
-- vs_sigizi_anc already retains the earliest repeated-file occurrence for its
-- cleaned ANC encounter key. This also covers ANC keys that are not raw UUIDs.
-- ============================================================================

CREATE OR REPLACE TEMP TABLE `_SESSION.t_sigizi_anc_first_seen_v3_3`
CLUSTER BY source_record_id
AS
SELECT
  CAST(source_record_id AS STRING) AS source_record_id,
  CAST(first_file_name AS STRING) AS first_file_name,
  CAST(first_file_upload_ts AS TIMESTAMP) AS first_file_upload_timestamp
FROM `spheres-lombok-barat.kohort_bumil_v3.vs_sigizi_anc`;


-- ============================================================================
-- E. CORRECTED SOURCE-RECORD LINEAGE
-- ============================================================================

CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_source_upload_lineage_v3_3`
CLUSTER BY pregnancy_episode_id, source_system, source_table
AS
WITH selected_lineage AS (
  SELECT * FROM `_SESSION.t_sigizi_selected_lineage_v3_3`
  UNION ALL
  SELECT * FROM `_SESSION.t_epus_selected_lineage_v3_3`
),

resolved AS (
  SELECT
    l.*,

    COALESCE(
      a.first_file_name,
      r.first_file_name,
      l.selected_file_name
    ) AS first_file_name,

    COALESCE(
      a.first_file_upload_timestamp,
      r.first_file_upload_timestamp,
      l.selected_file_upload_timestamp
    ) AS record_first_upload_timestamp,

    COALESCE(
      r.last_file_upload_timestamp,
      l.selected_file_upload_timestamp
    ) AS record_last_upload_timestamp,

    COALESCE(
      r.first_ingestion_timestamp,
      l.selected_ingestion_timestamp
    ) AS record_first_ingestion_timestamp,

    COALESCE(
      r.last_ingestion_timestamp,
      l.selected_ingestion_timestamp
    ) AS record_last_ingestion_timestamp,

    COALESCE(r.raw_version_count, 1) AS raw_version_count,

    CASE
      WHEN a.first_file_upload_timestamp IS NOT NULL
        THEN 'SOURCE_VIEW_RETAINED_FIRST_FILE'
      WHEN r.stable_source_record_id IS NOT NULL
        THEN 'RAW_HISTORY_STABLE_ID'
      ELSE 'CLEANED_ROW_FALLBACK'
    END AS first_seen_resolution_method

  FROM selected_lineage l

  LEFT JOIN `_SESSION.t_raw_source_first_seen_v3_3` r
    ON r.source_system = l.source_system
   AND r.source_table = l.source_table
   AND r.stable_source_record_id = l.source_record_id

  LEFT JOIN `_SESSION.t_sigizi_anc_first_seen_v3_3` a
    ON l.source_system = 'SIGIZI'
   AND l.source_table = 'ANC'
   AND a.source_record_id = l.source_record_id
),

with_first_seen AS (
  SELECT
    *,

    COALESCE(
      record_first_upload_timestamp,
      record_first_ingestion_timestamp
    ) AS record_first_seen_timestamp,

    (
      SELECT MAX(ts)
      FROM UNNEST([
        record_last_upload_timestamp,
        record_last_ingestion_timestamp,
        selected_source_observed_timestamp
      ]) ts
      WHERE ts IS NOT NULL
    ) AS record_last_seen_timestamp

  FROM resolved
)

SELECT
  pregnancy_episode_id,
  pregnancy_source_combination,
  source_system,
  source_table,
  source_record_key,
  source_record_id,
  source_episode_id,

  selected_file_name,
  selected_file_upload_timestamp,
  selected_ingestion_timestamp,
  selected_source_observed_timestamp,

  first_file_name AS file_name,
  DATE(record_first_upload_timestamp, 'Asia/Makassar') AS date_upload,
  record_first_upload_timestamp AS file_upload_timestamp,
  record_first_ingestion_timestamp AS source_ingestion_timestamp,
  record_first_seen_timestamp AS source_observed_timestamp,

  record_first_upload_timestamp,
  record_last_upload_timestamp,
  record_first_ingestion_timestamp,
  record_last_ingestion_timestamp,
  record_first_seen_timestamp,
  record_last_seen_timestamp,

  raw_version_count,
  first_seen_resolution_method,
  first_seen_resolution_method = 'CLEANED_ROW_FALLBACK'
    AS first_seen_fallback_flag

FROM with_first_seen;


-- ============================================================================
-- F. ONE ROW PER CANONICAL PREGNANCY
-- ============================================================================

CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_upload_summary_v3_3`
CLUSTER BY pregnancy_episode_id
AS
WITH aggregated AS (
  SELECT
    pregnancy_episode_id,
    ANY_VALUE(pregnancy_source_combination)
      AS pregnancy_source_combination,

    MIN(record_first_upload_timestamp)
      AS pregnancy_first_upload_timestamp,
    MAX(record_last_upload_timestamp)
      AS pregnancy_last_upload_timestamp,

    MIN(record_first_ingestion_timestamp)
      AS pregnancy_first_ingestion_timestamp,
    MAX(record_last_ingestion_timestamp)
      AS pregnancy_last_ingestion_timestamp,

    MIN(record_first_seen_timestamp)
      AS pregnancy_first_seen_timestamp,
    MAX(record_last_seen_timestamp)
      AS pregnancy_last_seen_timestamp,

    ARRAY_AGG(
      STRUCT(
        record_first_seen_timestamp AS first_seen_timestamp,
        source_system,
        source_table,
        source_record_id,
        first_seen_resolution_method
      )
      ORDER BY
        record_first_seen_timestamp IS NULL,
        record_first_seen_timestamp,
        source_system,
        source_table,
        source_record_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS first_seen_pick,

    COUNT(DISTINCT source_record_key)
      AS source_lineage_record_count,

    COUNT(DISTINCT IF(
      source_system = 'SIGIZI', source_record_key, NULL
    )) AS sigizi_source_record_count,

    COUNT(DISTINCT IF(
      source_system = 'EPUS', source_record_key, NULL
    )) AS epus_source_record_count,

    COUNTIF(file_name IS NOT NULL)
      AS records_with_file_name,

    COUNTIF(record_first_upload_timestamp IS NOT NULL)
      AS source_records_with_upload_timestamp,

    COUNTIF(record_first_ingestion_timestamp IS NOT NULL)
      AS source_records_with_ingestion_timestamp,

    COUNTIF(record_first_seen_timestamp IS NULL)
      AS source_records_without_any_timestamp,

    COUNTIF(first_seen_fallback_flag)
      AS source_records_using_first_seen_fallback,

    LOGICAL_OR(first_seen_fallback_flag)
      AS any_first_seen_fallback_flag

  FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_source_upload_lineage_v3_3`
  GROUP BY pregnancy_episode_id
)

SELECT
  pregnancy_episode_id,
  pregnancy_source_combination,

  DATE(pregnancy_first_upload_timestamp, 'Asia/Makassar')
    AS date_upload,
  DATE(pregnancy_last_upload_timestamp, 'Asia/Makassar')
    AS latest_date_upload,

  pregnancy_first_upload_timestamp AS first_upload_timestamp,
  pregnancy_last_upload_timestamp AS latest_upload_timestamp,

  pregnancy_first_ingestion_timestamp AS first_ingestion_timestamp,
  pregnancy_last_ingestion_timestamp AS latest_ingestion_timestamp,
  pregnancy_first_ingestion_timestamp AS ingestion_time,
  pregnancy_last_ingestion_timestamp AS latest_ingestion_time,

  pregnancy_first_seen_timestamp AS first_source_observed_timestamp,
  pregnancy_last_seen_timestamp AS latest_source_observed_timestamp,

  pregnancy_first_upload_timestamp,
  pregnancy_last_upload_timestamp,
  pregnancy_first_ingestion_timestamp,
  pregnancy_last_ingestion_timestamp,
  pregnancy_first_seen_timestamp,
  DATE(pregnancy_first_seen_timestamp, 'Asia/Makassar')
    AS pregnancy_first_seen_date,
  pregnancy_last_seen_timestamp,
  DATE(pregnancy_last_seen_timestamp, 'Asia/Makassar')
    AS pregnancy_last_seen_date,

  first_seen_pick.source_system AS pregnancy_first_seen_source_system,
  first_seen_pick.source_table AS pregnancy_first_seen_source_table,
  first_seen_pick.source_record_id AS pregnancy_first_seen_source_record_id,
  first_seen_pick.first_seen_resolution_method
    AS pregnancy_first_seen_resolution_method,

  source_lineage_record_count,
  sigizi_source_record_count,
  epus_source_record_count,
  records_with_file_name,
  source_records_with_upload_timestamp,
  source_records_with_ingestion_timestamp,
  source_records_without_any_timestamp,
  source_records_using_first_seen_fallback,
  any_first_seen_fallback_flag

FROM aggregated;
