-- ============================================================================
-- Validation suite: Purbalingga pregnancy first-seen extension
-- Run after PBG-05C and views_deploy_once/15_v_pregnancy_first_seen.sql.
-- ============================================================================

-- 1. Upload summary: exactly one row per final pregnancy.
SELECT
  'upload_summary_one_row_per_pregnancy' AS qa_check,
  COUNT(*) AS count_rows,
  COUNT(DISTINCT pregnancy_episode_id) AS distinct_ids,
  COUNT(*) = COUNT(DISTINCT pregnancy_episode_id) AS passed
FROM `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_upload_summary_v3_3`;

-- 2. Registry: exactly one row per final pregnancy.
SELECT
  'registry_one_row_per_pregnancy' AS qa_check,
  COUNT(*) AS count_rows,
  COUNT(DISTINCT pregnancy_episode_id) AS distinct_ids,
  COUNT(*) = COUNT(DISTINCT pregnancy_episode_id) AS passed
FROM `stellar-orb-451904-d9.kohort_bumil_v2.v_pregnancy_registry_v3_3`;

-- 3. Final-spine coverage and explicit unresolved classification.
SELECT
  'every_final_pregnancy_summarized' AS qa_check,
  COUNT(*) AS final_pregnancies,
  COUNT(u.pregnancy_episode_id) AS summarized_pregnancies,
  COUNTIF(
    u.pregnancy_lineage_status IN ('RESOLVED', 'UNRESOLVED_NO_SOURCE_LINEAGE')
  ) AS explicitly_classified_pregnancies,
  COUNT(*) = COUNT(u.pregnancy_episode_id)
    AND COUNT(*) = COUNTIF(
      u.pregnancy_lineage_status IN ('RESOLVED', 'UNRESOLVED_NO_SOURCE_LINEAGE')
    ) AS passed
FROM `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3` p
LEFT JOIN `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_upload_summary_v3_3` u
  USING (pregnancy_episode_id);

-- 4. Upload and ingestion coverage by source family and source table.
SELECT
  source_system,
  source_table,
  COUNT(*) AS contributing_source_records,
  COUNTIF(record_first_upload_timestamp IS NOT NULL) AS with_upload_timestamp,
  ROUND(100 * SAFE_DIVIDE(
    COUNTIF(record_first_upload_timestamp IS NOT NULL), COUNT(*)), 2
  ) AS upload_timestamp_coverage_pct,
  COUNTIF(record_first_ingestion_timestamp IS NOT NULL) AS with_ingestion_timestamp,
  ROUND(100 * SAFE_DIVIDE(
    COUNTIF(record_first_ingestion_timestamp IS NOT NULL), COUNT(*)), 2
  ) AS ingestion_timestamp_coverage_pct,
  COUNTIF(raw_history_match_flag) AS matched_to_retained_raw_history,
  COUNTIF(cleaned_row_fallback_flag) AS cleaned_row_fallback_records,
  COUNTIF(record_first_seen_timestamp IS NULL) AS unresolved_timestamp_records
FROM `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_source_upload_lineage_v3_3`
WHERE source_lineage_resolved_flag
GROUP BY source_system, source_table
ORDER BY source_system, source_table;

-- 5. Review fallback, unresolved, and source-ID collision records separately.
SELECT
  pregnancy_episode_id,
  pregnancy_source_combination,
  source_system,
  source_table,
  source_record_id,
  source_episode_id,
  source_episode_ids,
  file_name,
  record_first_upload_timestamp,
  record_first_ingestion_timestamp,
  selected_file_date_timestamp,
  record_first_seen_timestamp,
  first_seen_resolution_method,
  first_seen_fallback_flag,
  cleaned_row_fallback_flag,
  raw_history_match_flag,
  source_record_id_collision_flag,
  lineage_status
FROM `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_source_upload_lineage_v3_3`
WHERE first_seen_fallback_flag
   OR NOT source_lineage_resolved_flag
   OR source_record_id_collision_flag
ORDER BY source_system, source_table, pregnancy_episode_id, source_record_id;

-- 6. Repeated exports remain one lineage record per canonical pregnancy.
SELECT
  'repeated_exports_do_not_duplicate_lineage_key' AS qa_check,
  COUNT(*) AS duplicate_keys,
  COUNT(*) = 0 AS passed
FROM (
  SELECT pregnancy_episode_id, source_record_key
  FROM `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_source_upload_lineage_v3_3`
  WHERE source_lineage_resolved_flag
  GROUP BY pregnancy_episode_id, source_record_key
  HAVING COUNT(*) > 1
);

-- 7. A later source cannot create a second first-seen assignment.
SELECT
  'later_source_does_not_recount_pregnancy' AS qa_check,
  COUNT(*) AS duplicate_summary_ids,
  COUNT(*) = 0 AS passed
FROM (
  SELECT pregnancy_episode_id
  FROM `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_upload_summary_v3_3`
  GROUP BY pregnancy_episode_id
  HAVING COUNT(*) > 1
);

-- 8. Diagnostic: later pregnancies for one trusted NIK remain separate IDs.
SELECT
  nik,
  COUNT(DISTINCT pregnancy_episode_id) AS pregnancy_episode_count,
  ARRAY_AGG(STRUCT(
    pregnancy_episode_id, hpht, hpl, pregnancy_first_seen_date
  ) ORDER BY COALESCE(hpht, hpl, pregnancy_first_seen_date), pregnancy_episode_id)
    AS episodes
FROM `stellar-orb-451904-d9.kohort_bumil_v2.v_pregnancy_registry_v3_3`
WHERE REGEXP_CONTAINS(COALESCE(nik, ''), r'^\d{16}$')
GROUP BY nik
HAVING COUNT(DISTINCT pregnancy_episode_id) > 1
ORDER BY pregnancy_episode_count DESC, nik;

-- 9. ALL daily equals the unduplicated pregnancy total by first-seen date.
SELECT
  'all_scope_is_unduplicated' AS qa_check,
  COUNTIF(m.new_pregnancies_daily != COALESCE(r.expected_daily, 0))
    AS mismatching_dates,
  COUNTIF(m.new_pregnancies_daily != COALESCE(r.expected_daily, 0)) = 0
    AS passed
FROM `stellar-orb-451904-d9.kohort_bumil_v2.v_new_pregnancy_metrics_daily_v3_3` m
LEFT JOIN (
  SELECT pregnancy_first_seen_date AS metric_date,
    COUNT(DISTINCT pregnancy_episode_id) AS expected_daily
  FROM `stellar-orb-451904-d9.kohort_bumil_v2.v_pregnancy_registry_v3_3`
  WHERE pregnancy_first_seen_date IS NOT NULL
  GROUP BY pregnancy_first_seen_date
) r USING (metric_date)
WHERE m.first_seen_source_scope = 'ALL';

-- 10. Source scopes use the selected first-seen system, not final combination.
SELECT
  'source_scope_uses_first_seen_source' AS qa_check,
  COUNTIF(m.new_pregnancies_daily != COALESCE(r.expected_daily, 0))
    AS mismatching_date_scopes,
  COUNTIF(m.new_pregnancies_daily != COALESCE(r.expected_daily, 0)) = 0
    AS passed
FROM `stellar-orb-451904-d9.kohort_bumil_v2.v_new_pregnancy_metrics_daily_v3_3` m
LEFT JOIN (
  SELECT pregnancy_first_seen_date AS metric_date,
    pregnancy_first_seen_source_system AS first_seen_source_scope,
    COUNT(DISTINCT pregnancy_episode_id) AS expected_daily
  FROM `stellar-orb-451904-d9.kohort_bumil_v2.v_pregnancy_registry_v3_3`
  WHERE pregnancy_first_seen_date IS NOT NULL
    AND pregnancy_first_seen_source_system IS NOT NULL
  GROUP BY pregnancy_first_seen_date, pregnancy_first_seen_source_system
) r USING (metric_date, first_seen_source_scope)
WHERE m.first_seen_source_scope != 'ALL';

-- 11. Independent recomputation of 7- and 30-day windows.
SELECT
  'rolling_windows_use_first_seen_date' AS qa_check,
  COUNTIF(new_pregnancies_rolling_7_days != expected_7
       OR new_pregnancies_rolling_30_days != expected_30)
    AS mismatching_date_scopes,
  COUNTIF(new_pregnancies_rolling_7_days != expected_7
       OR new_pregnancies_rolling_30_days != expected_30) = 0 AS passed
FROM (
  SELECT *,
    SUM(new_pregnancies_daily) OVER (
      PARTITION BY first_seen_source_scope ORDER BY metric_date
      ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS expected_7,
    SUM(new_pregnancies_daily) OVER (
      PARTITION BY first_seen_source_scope ORDER BY metric_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS expected_30
  FROM `stellar-orb-451904-d9.kohort_bumil_v2.v_new_pregnancy_metrics_daily_v3_3`
);

-- 12. Audit multi-source pregnancies and their single first-seen source.
SELECT
  pregnancy_episode_id,
  pregnancy_source_combination,
  pregnancy_first_seen_timestamp,
  pregnancy_first_seen_source_system,
  pregnancy_first_seen_source_table,
  sigizi_source_record_count,
  epus_source_record_count
FROM `stellar-orb-451904-d9.kohort_bumil_v2.v_pregnancy_registry_v3_3`
WHERE in_sigizi_pregnancy AND in_epus_pregnancy
ORDER BY pregnancy_first_seen_timestamp DESC
LIMIT 100;
