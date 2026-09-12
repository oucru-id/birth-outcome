-- ============================================================================
-- PBG-05C - PREGNANCY FIRST-SEEN / NEW-PREGNANCY LINEAGE
--
-- Purpose
--   Determine when each final canonical Purbalingga pregnancy first became
--   observable in retained source-file history. The first observed visit may
--   be K1, K3, or any other retained pregnancy-creating record.
--
-- Run after
--   PBG-05 canonical pregnancy succeeds.
--
-- Outputs
--   t_pregnancy_source_upload_lineage_v3_3
--     one canonical pregnancy x one contributing pregnancy-source record;
--     pregnancies with no traceable record receive one explicit unresolved row.
--
--   t_pregnancy_upload_summary_v3_3
--     one row per final canonical pregnancy.
--
-- Important architecture rule
--   Purbalingga pregnancy membership is created by SIGIZI and ePUS pregnancy
--   sources. eKohort, SIMRS, Birth Confirmation, SIGIZI IBU_NIFAS, and ePUS
--   INC/PNC are outcome or delivery evidence; they must not create or backdate
--   a pregnancy's first appearance.
--
-- Timestamp priority
--   1. Earliest upload timestamp parsed from a retained file name.
--   2. Earliest warehouse ingestion timestamp, only if no upload timestamp
--      exists anywhere in the pregnancy lineage.
--   3. Cleaned file_date at midnight Asia/Jakarta, only as an auditable final
--      timestamp fallback when raw history has no usable timestamp.
--
-- BigQuery execution note
--   This script uses temporary UDFs and creates the two permanent tables only.
--   Deploy the permanent views from views_deploy_once/15_... in a separate job.
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
    'Asia/Jakarta'
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
      'Asia/Jakarta'
    )
  )
);


-- ============================================================================
-- A. EARLIEST RETAINED RAW HISTORY BY STABLE SOURCE IDENTIFIER
--
-- Only source families that create pregnancy membership are included here.
-- TO_JSON_STRING / JSON_VALUE deliberately tolerate minor raw-schema variation.
-- Rows whose cleaned source_record_id was produced from a full-row fingerprint
-- cannot be safely joined across repeated exports and use the cleaned fallback.
-- ============================================================================

CREATE OR REPLACE TEMP TABLE `_SESSION.t_raw_pregnancy_source_history_v3_3`
CLUSTER BY source_system, source_table, stable_source_record_id
AS
WITH raw_union AS (
  SELECT
    'SIGIZI' AS source_system,
    'DAFTAR_BUMIL' AS source_table,
    TO_JSON_STRING(t) AS raw_json
  FROM `stellar-orb-451904-d9.raw_data.sigizi_daftar_bumil` t

  UNION ALL

  SELECT 'SIGIZI', 'KESGA_BUMIL_ANC', TO_JSON_STRING(t)
  FROM `stellar-orb-451904-d9.raw_data.sigizi_kesga_bumil_anc` t

  UNION ALL

  SELECT 'SIGIZI', 'KOHORT_IBU', TO_JSON_STRING(t)
  FROM `stellar-orb-451904-d9.raw_data.sigizi_kohort_ibu` t

  UNION ALL

  SELECT 'SIGIZI', 'KESGA_BUMIL', TO_JSON_STRING(t)
  FROM `stellar-orb-451904-d9.raw_data.sigizi_kesga_bumil` t

  UNION ALL

  SELECT 'EPUS', 'EPUS_ANC', TO_JSON_STRING(t)
  FROM `stellar-orb-451904-d9.raw_data.epus_anc` t

  UNION ALL

  SELECT 'EPUS', 'EPUS_KUNJUNGAN_IBU_HAMIL', TO_JSON_STRING(t)
  FROM `stellar-orb-451904-d9.raw_data.epus_kunjungan_ibu_hamil` t
),
parsed AS (
  SELECT
    source_system,
    source_table,
    COALESCE(
      NULLIF(TRIM(JSON_VALUE(raw_json, '$.uuid')), ''),
      NULLIF(TRIM(JSON_VALUE(raw_json, '$.hash_code')), ''),
      NULLIF(TRIM(JSON_VALUE(raw_json, '$.id')), ''),
      NULLIF(TRIM(JSON_VALUE(raw_json, '$.no')), '')
    ) AS stable_source_record_id,
    COALESCE(
      NULLIF(TRIM(JSON_VALUE(raw_json, '$.file_name')), ''),
      NULLIF(TRIM(JSON_VALUE(raw_json, '$.nama_file')), '')
    ) AS file_name,
    parse_filename_upload_timestamp(
      COALESCE(
        JSON_VALUE(raw_json, '$.file_name'),
        JSON_VALUE(raw_json, '$.nama_file')
      )
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
    ORDER BY
      file_upload_timestamp IS NULL,
      file_upload_timestamp,
      ingestion_timestamp IS NULL,
      ingestion_timestamp,
      file_name
    LIMIT 1
  )[SAFE_OFFSET(0)] AS first_file_name,
  ARRAY_AGG(
    file_name IGNORE NULLS
    ORDER BY
      file_upload_timestamp IS NULL,
      file_upload_timestamp DESC,
      ingestion_timestamp IS NULL,
      ingestion_timestamp DESC,
      file_name DESC
    LIMIT 1
  )[SAFE_OFFSET(0)] AS last_file_name,
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
-- B. FINAL PREGNANCY -> SIGIZI PREGNANCY-CREATING SOURCE RECORDS
-- ============================================================================

CREATE OR REPLACE TEMP TABLE `_SESSION.t_sigizi_selected_lineage_v3_3`
CLUSTER BY pregnancy_episode_id, source_table
AS
WITH final_episodes AS (
  SELECT DISTINCT
    p.pregnancy_episode_id,
    p.pregnancy_source_combination,
    sigizi_episode_id
  FROM `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3` p
  CROSS JOIN UNNEST(
    COALESCE(p.canonical_sigizi_episode_ids, ARRAY<STRING>[])
  ) sigizi_episode_id
),
member_records AS (
  SELECT DISTINCT
    f.pregnancy_episode_id,
    f.pregnancy_source_combination,
    f.sigizi_episode_id,
    source_record_id
  FROM final_episodes f
  JOIN `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_pregnancy_episode_v3_3` e
    USING (sigizi_episode_id)
  CROSS JOIN UNNEST(
    COALESCE(e.sigizi_member_source_record_ids, ARRAY<STRING>[])
  ) source_record_id
)
SELECT
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
  ARRAY_AGG(
    DISTINCT m.sigizi_episode_id IGNORE NULLS
    ORDER BY m.sigizi_episode_id
  )[SAFE_OFFSET(0)] AS source_episode_id,
  ARRAY_AGG(
    DISTINCT m.sigizi_episode_id IGNORE NULLS
    ORDER BY m.sigizi_episode_id
  ) AS source_episode_ids,
  ARRAY_AGG(
    s.file_name IGNORE NULLS
    ORDER BY
      parse_filename_upload_timestamp(s.file_name) IS NULL,
      parse_filename_upload_timestamp(s.file_name),
      s.ingestion_timestamp IS NULL,
      s.ingestion_timestamp,
      s.file_name
    LIMIT 1
  )[SAFE_OFFSET(0)] AS selected_file_name,
  MIN(parse_filename_upload_timestamp(s.file_name))
    AS selected_file_upload_timestamp,
  MIN(s.ingestion_timestamp) AS selected_ingestion_timestamp,
  MIN(IF(
    s.file_date IS NULL, NULL, TIMESTAMP(s.file_date, 'Asia/Jakarta')
  )) AS selected_file_date_timestamp
FROM member_records m
JOIN `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_source_records` s
  ON s.source_record_id = m.source_record_id
WHERE s.pregnancy_episode_creator_flag = TRUE
GROUP BY
  m.pregnancy_episode_id,
  m.pregnancy_source_combination,
  s.source_table,
  s.source_record_id;


-- ============================================================================
-- C. FINAL PREGNANCY -> EPUS PREGNANCY-CREATING SOURCE RECORDS
-- ============================================================================

CREATE OR REPLACE TEMP TABLE `_SESSION.t_epus_selected_lineage_v3_3`
CLUSTER BY pregnancy_episode_id, source_table
AS
WITH final_episodes AS (
  SELECT DISTINCT
    p.pregnancy_episode_id,
    p.pregnancy_source_combination,
    epus_episode_id
  FROM `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3` p
  CROSS JOIN UNNEST(
    COALESCE(p.canonical_epus_episode_ids, ARRAY<STRING>[])
  ) epus_episode_id
),
member_records AS (
  SELECT DISTINCT
    f.pregnancy_episode_id,
    f.pregnancy_source_combination,
    f.epus_episode_id,
    source_record_id
  FROM final_episodes f
  JOIN `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_pregnancy_episode_adapter_v3_3` e
    USING (epus_episode_id)
  CROSS JOIN UNNEST(
    COALESCE(e.epus_member_source_record_ids, ARRAY<STRING>[])
  ) source_record_id
)
SELECT
  m.pregnancy_episode_id,
  m.pregnancy_source_combination,
  'EPUS' AS source_system,
  s.source_table,
  CONCAT(
    'EPUS|',
    COALESCE(s.source_table, 'UNKNOWN'),
    '|',
    COALESCE(s.source_record_id, 'UNKNOWN')
  ) AS source_record_key,
  s.source_record_id,
  ARRAY_AGG(
    DISTINCT m.epus_episode_id IGNORE NULLS
    ORDER BY m.epus_episode_id
  )[SAFE_OFFSET(0)] AS source_episode_id,
  ARRAY_AGG(
    DISTINCT m.epus_episode_id IGNORE NULLS
    ORDER BY m.epus_episode_id
  ) AS source_episode_ids,
  ARRAY_AGG(
    s.file_name IGNORE NULLS
    ORDER BY
      parse_filename_upload_timestamp(s.file_name) IS NULL,
      parse_filename_upload_timestamp(s.file_name),
      s.ingestion_timestamp IS NULL,
      s.ingestion_timestamp,
      s.file_name
    LIMIT 1
  )[SAFE_OFFSET(0)] AS selected_file_name,
  MIN(parse_filename_upload_timestamp(s.file_name))
    AS selected_file_upload_timestamp,
  MIN(s.ingestion_timestamp) AS selected_ingestion_timestamp,
  MIN(IF(
    s.file_date IS NULL, NULL, TIMESTAMP(s.file_date, 'Asia/Jakarta')
  )) AS selected_file_date_timestamp
FROM member_records m
JOIN `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_source_records` s
  ON s.source_record_id = m.source_record_id
WHERE s.pregnancy_episode_creator_flag = TRUE
GROUP BY
  m.pregnancy_episode_id,
  m.pregnancy_source_combination,
  s.source_table,
  s.source_record_id;


-- ============================================================================
-- D. RESOLVE RAW HISTORY, FALLBACKS, AND SOURCE-ID COLLISIONS
-- ============================================================================

CREATE OR REPLACE TEMP TABLE `_SESSION.t_selected_pregnancy_lineage_v3_3`
CLUSTER BY pregnancy_episode_id, source_system, source_table
AS
SELECT * FROM `_SESSION.t_sigizi_selected_lineage_v3_3`
UNION ALL
SELECT * FROM `_SESSION.t_epus_selected_lineage_v3_3`;


CREATE OR REPLACE TEMP TABLE `_SESSION.t_selected_source_id_collisions_v3_3`
CLUSTER BY pregnancy_episode_id, source_system, source_record_id
AS
SELECT
  pregnancy_episode_id,
  source_system,
  source_record_id,
  COUNT(DISTINCT source_table) AS matching_source_table_count
FROM `_SESSION.t_selected_pregnancy_lineage_v3_3`
GROUP BY
  pregnancy_episode_id,
  source_system,
  source_record_id;


CREATE OR REPLACE TEMP TABLE `_SESSION.t_resolved_pregnancy_lineage_v3_3`
CLUSTER BY pregnancy_episode_id, source_system, source_table
AS
WITH resolved_base AS (
  SELECT
    l.*,
    IF(
      r.stable_source_record_id IS NOT NULL,
      r.first_file_name,
      l.selected_file_name
    ) AS first_file_name,
    IF(
      r.stable_source_record_id IS NOT NULL,
      r.last_file_name,
      l.selected_file_name
    ) AS last_file_name,
    IF(
      r.stable_source_record_id IS NOT NULL,
      r.first_file_upload_timestamp,
      l.selected_file_upload_timestamp
    ) AS record_first_upload_timestamp,
    IF(
      r.stable_source_record_id IS NOT NULL,
      r.last_file_upload_timestamp,
      l.selected_file_upload_timestamp
    ) AS record_last_upload_timestamp,
    IF(
      r.stable_source_record_id IS NOT NULL,
      r.first_ingestion_timestamp,
      l.selected_ingestion_timestamp
    ) AS record_first_ingestion_timestamp,
    IF(
      r.stable_source_record_id IS NOT NULL,
      r.last_ingestion_timestamp,
      l.selected_ingestion_timestamp
    ) AS record_last_ingestion_timestamp,
    COALESCE(r.raw_version_count, 0) AS raw_version_count,
    r.stable_source_record_id IS NOT NULL AS raw_history_match_flag,
    COALESCE(c.matching_source_table_count, 1) > 1
      AS source_record_id_collision_flag,
    CASE
      WHEN r.first_file_upload_timestamp IS NOT NULL
        THEN 'RAW_HISTORY_UPLOAD_TIMESTAMP'
      WHEN r.first_ingestion_timestamp IS NOT NULL
        THEN 'RAW_HISTORY_INGESTION_FALLBACK'
      WHEN r.stable_source_record_id IS NOT NULL
        THEN 'RAW_HISTORY_MATCH_NO_TIMESTAMP'
      WHEN l.selected_file_upload_timestamp IS NOT NULL
        THEN 'CLEANED_FILE_NAME_UPLOAD_FALLBACK'
      WHEN l.selected_ingestion_timestamp IS NOT NULL
        THEN 'CLEANED_INGESTION_FALLBACK'
      WHEN l.selected_file_date_timestamp IS NOT NULL
        THEN 'CLEANED_FILE_DATE_FALLBACK'
      ELSE 'UNRESOLVED_NO_TIMESTAMP'
    END AS first_seen_resolution_method
  FROM `_SESSION.t_selected_pregnancy_lineage_v3_3` l
  LEFT JOIN `_SESSION.t_raw_pregnancy_source_history_v3_3` r
    ON r.source_system = l.source_system
   AND r.source_table = l.source_table
   AND r.stable_source_record_id = l.source_record_id
  LEFT JOIN `_SESSION.t_selected_source_id_collisions_v3_3` c
    ON c.pregnancy_episode_id = l.pregnancy_episode_id
   AND c.source_system = l.source_system
   AND c.source_record_id = l.source_record_id
),
with_seen AS (
  SELECT
    *,
    COALESCE(
      record_first_upload_timestamp,
      record_first_ingestion_timestamp,
      IF(raw_history_match_flag, NULL, selected_file_date_timestamp)
    ) AS record_first_seen_timestamp,
    (
      SELECT MAX(ts)
      FROM UNNEST([
        record_last_upload_timestamp,
        record_last_ingestion_timestamp,
        IF(raw_history_match_flag, NULL, selected_file_date_timestamp)
      ]) ts
      WHERE ts IS NOT NULL
    ) AS record_last_seen_timestamp
  FROM resolved_base
)
SELECT
  *,
  CASE
    WHEN record_first_upload_timestamp IS NOT NULL THEN 1
    WHEN record_first_ingestion_timestamp IS NOT NULL THEN 2
    WHEN NOT raw_history_match_flag
      AND selected_file_date_timestamp IS NOT NULL THEN 3
    ELSE 9
  END AS first_seen_preference,
  record_first_upload_timestamp IS NULL
    AS first_seen_fallback_flag,
  STARTS_WITH(first_seen_resolution_method, 'CLEANED_')
    AS cleaned_row_fallback_flag,
  TRUE AS source_lineage_resolved_flag,
  CASE
    WHEN STARTS_WITH(first_seen_resolution_method, 'RAW_HISTORY_')
      THEN 'RESOLVED_RAW_HISTORY'
    WHEN STARTS_WITH(first_seen_resolution_method, 'CLEANED_')
      THEN 'RESOLVED_CLEANED_ROW_FALLBACK'
    ELSE 'RESOLVED_SOURCE_RECORD_TIMESTAMP_UNAVAILABLE'
  END AS lineage_status
FROM with_seen;


-- ============================================================================
-- E. PERMANENT SOURCE-LINEAGE TABLE
--
-- An explicit unresolved row preserves one-to-one pregnancy coverage even if a
-- future schema change breaks the path from the final spine to source records.
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_source_upload_lineage_v3_3`
CLUSTER BY pregnancy_episode_id, source_system, source_table
AS
SELECT
  pregnancy_episode_id,
  pregnancy_source_combination,
  source_system,
  source_table,
  source_record_key,
  source_record_id,
  source_episode_id,
  source_episode_ids,
  selected_file_name,
  selected_file_upload_timestamp,
  selected_ingestion_timestamp,
  selected_file_date_timestamp,
  first_file_name AS file_name,
  last_file_name,
  record_first_upload_timestamp,
  record_last_upload_timestamp,
  record_first_ingestion_timestamp,
  record_last_ingestion_timestamp,
  record_first_seen_timestamp,
  record_last_seen_timestamp,
  raw_version_count,
  raw_history_match_flag,
  source_record_id_collision_flag,
  first_seen_preference,
  first_seen_resolution_method,
  first_seen_fallback_flag,
  cleaned_row_fallback_flag,
  source_lineage_resolved_flag,
  lineage_status
FROM `_SESSION.t_resolved_pregnancy_lineage_v3_3`

UNION ALL

SELECT
  p.pregnancy_episode_id,
  p.pregnancy_source_combination,
  'UNRESOLVED' AS source_system,
  'UNRESOLVED' AS source_table,
  CONCAT('UNRESOLVED|', p.pregnancy_episode_id) AS source_record_key,
  CAST(NULL AS STRING) AS source_record_id,
  CAST(NULL AS STRING) AS source_episode_id,
  ARRAY<STRING>[] AS source_episode_ids,
  CAST(NULL AS STRING) AS selected_file_name,
  CAST(NULL AS TIMESTAMP) AS selected_file_upload_timestamp,
  CAST(NULL AS TIMESTAMP) AS selected_ingestion_timestamp,
  CAST(NULL AS TIMESTAMP) AS selected_file_date_timestamp,
  CAST(NULL AS STRING) AS file_name,
  CAST(NULL AS STRING) AS last_file_name,
  CAST(NULL AS TIMESTAMP) AS record_first_upload_timestamp,
  CAST(NULL AS TIMESTAMP) AS record_last_upload_timestamp,
  CAST(NULL AS TIMESTAMP) AS record_first_ingestion_timestamp,
  CAST(NULL AS TIMESTAMP) AS record_last_ingestion_timestamp,
  CAST(NULL AS TIMESTAMP) AS record_first_seen_timestamp,
  CAST(NULL AS TIMESTAMP) AS record_last_seen_timestamp,
  0 AS raw_version_count,
  FALSE AS raw_history_match_flag,
  FALSE AS source_record_id_collision_flag,
  9 AS first_seen_preference,
  'UNRESOLVED_NO_SOURCE_LINEAGE' AS first_seen_resolution_method,
  TRUE AS first_seen_fallback_flag,
  FALSE AS cleaned_row_fallback_flag,
  FALSE AS source_lineage_resolved_flag,
  'UNRESOLVED_NO_CONTRIBUTING_SOURCE_RECORD' AS lineage_status
FROM `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3` p
WHERE NOT EXISTS (
  SELECT 1
  FROM `_SESSION.t_resolved_pregnancy_lineage_v3_3` l
  WHERE l.pregnancy_episode_id = p.pregnancy_episode_id
);


-- ============================================================================
-- F. ONE ROW PER FINAL CANONICAL PREGNANCY
--
-- Pregnancy-level first seen deliberately selects any upload timestamp before
-- considering any ingestion timestamp. Thus an earlier ingestion cannot outrank
-- a retained upload timestamp belonging to another contributing record.
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_upload_summary_v3_3`
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
    MAX(record_last_seen_timestamp)
      AS pregnancy_last_seen_timestamp,
    ARRAY_AGG(
      STRUCT(
        record_first_seen_timestamp AS first_seen_timestamp,
        source_system,
        source_table,
        source_record_id,
        source_episode_id,
        source_episode_ids,
        first_seen_resolution_method,
        first_seen_fallback_flag,
        cleaned_row_fallback_flag,
        first_seen_preference
      )
      ORDER BY
        first_seen_preference,
        record_first_seen_timestamp IS NULL,
        record_first_seen_timestamp,
        source_system,
        source_table,
        source_record_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS first_seen_pick,
    COUNT(DISTINCT IF(
      source_lineage_resolved_flag,
      source_record_key,
      NULL
    )) AS source_lineage_record_count,
    COUNT(DISTINCT IF(
      source_lineage_resolved_flag AND source_system = 'SIGIZI',
      source_record_key,
      NULL
    )) AS sigizi_source_record_count,
    COUNT(DISTINCT IF(
      source_lineage_resolved_flag AND source_system = 'EPUS',
      source_record_key,
      NULL
    )) AS epus_source_record_count,
    COUNTIF(source_lineage_resolved_flag AND file_name IS NOT NULL)
      AS records_with_file_name,
    COUNTIF(
      source_lineage_resolved_flag
      AND record_first_upload_timestamp IS NOT NULL
    ) AS source_records_with_upload_timestamp,
    COUNTIF(
      source_lineage_resolved_flag
      AND record_first_ingestion_timestamp IS NOT NULL
    ) AS source_records_with_ingestion_timestamp,
    COUNTIF(
      source_lineage_resolved_flag
      AND record_first_seen_timestamp IS NULL
    ) AS source_records_without_any_timestamp,
    COUNTIF(
      source_lineage_resolved_flag
      AND first_seen_fallback_flag
    ) AS source_records_using_first_seen_fallback,
    LOGICAL_OR(
      source_lineage_resolved_flag
      AND first_seen_fallback_flag
    ) AS any_first_seen_fallback_flag,
    LOGICAL_OR(
      source_lineage_resolved_flag
      AND cleaned_row_fallback_flag
    ) AS any_cleaned_row_fallback_flag,
    COUNTIF(source_record_id_collision_flag)
      AS source_record_id_collision_rows,
    COUNTIF(NOT source_lineage_resolved_flag)
      AS unresolved_lineage_row_count,
    LOGICAL_OR(source_lineage_resolved_flag)
      AS any_source_lineage_resolved_flag
  FROM `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_source_upload_lineage_v3_3`
  GROUP BY pregnancy_episode_id
)
SELECT
  pregnancy_episode_id,
  pregnancy_source_combination,
  pregnancy_first_upload_timestamp,
  pregnancy_last_upload_timestamp,
  pregnancy_first_ingestion_timestamp,
  pregnancy_last_ingestion_timestamp,
  first_seen_pick.first_seen_timestamp AS pregnancy_first_seen_timestamp,
  DATE(first_seen_pick.first_seen_timestamp, 'Asia/Jakarta')
    AS pregnancy_first_seen_date,
  pregnancy_last_seen_timestamp,
  DATE(pregnancy_last_seen_timestamp, 'Asia/Jakarta')
    AS pregnancy_last_seen_date,
  first_seen_pick.source_system AS pregnancy_first_seen_source_system,
  first_seen_pick.source_table AS pregnancy_first_seen_source_table,
  first_seen_pick.source_record_id AS pregnancy_first_seen_source_record_id,
  first_seen_pick.source_episode_id AS pregnancy_first_seen_source_episode_id,
  first_seen_pick.source_episode_ids
    AS pregnancy_first_seen_source_episode_ids,
  first_seen_pick.first_seen_resolution_method
    AS pregnancy_first_seen_resolution_method,
  first_seen_pick.first_seen_fallback_flag
    AS pregnancy_first_seen_fallback_flag,
  first_seen_pick.cleaned_row_fallback_flag
    AS pregnancy_first_seen_cleaned_row_fallback_flag,
  source_lineage_record_count,
  sigizi_source_record_count,
  epus_source_record_count,
  records_with_file_name,
  source_records_with_upload_timestamp,
  source_records_with_ingestion_timestamp,
  source_records_without_any_timestamp,
  source_records_using_first_seen_fallback,
  any_first_seen_fallback_flag,
  any_cleaned_row_fallback_flag,
  source_record_id_collision_rows,
  unresolved_lineage_row_count,
  any_source_lineage_resolved_flag,
  IF(
    any_source_lineage_resolved_flag,
    'RESOLVED',
    'UNRESOLVED_NO_SOURCE_LINEAGE'
  ) AS pregnancy_lineage_status
FROM aggregated;


-- Compact completion result for Scheduled Query history.
SELECT
  COUNT(*) AS pregnancies,
  COUNT(DISTINCT pregnancy_episode_id) AS distinct_pregnancies,
  COUNTIF(pregnancy_first_seen_timestamp IS NOT NULL)
    AS pregnancies_with_first_seen_timestamp,
  COUNTIF(pregnancy_lineage_status != 'RESOLVED')
    AS pregnancies_with_unresolved_lineage
FROM `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_upload_summary_v3_3`;
