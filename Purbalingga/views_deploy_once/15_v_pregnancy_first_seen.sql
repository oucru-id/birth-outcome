-- ============================================================================
-- Purbalingga pregnancy first-seen reporting views
--
-- Deploy once, in a separate BigQuery job after PBG-05C has created its two
-- tables. Do not schedule this file daily: permanent views automatically
-- reflect every successful refresh of their underlying tables.
-- ============================================================================

CREATE OR REPLACE VIEW
  `stellar-orb-451904-d9.kohort_bumil_v2.v_pregnancy_registry_v3_3`
AS
SELECT
  p.pregnancy_episode_id,
  p.nama_ibu AS nama,
  p.nik_clean AS nik,
  p.no_hp_clean AS no_hp,
  s.pregnancy_source_combination,
  COALESCE(s.has_pregnancy_sigizi, FALSE) AS in_sigizi_pregnancy,
  COALESCE(s.has_pregnancy_epus, FALSE) AS in_epus_pregnancy,
  p.monitoring_status_all_history AS status_kehamilan,
  p.monitoring_status_operational AS operational_pregnancy_status,
  p.pregnancy_outcome_final AS pregnancy_outcome,
  p.hpht_date AS hpht,
  s.hpht_source AS hpht_selected_source,
  p.expected_delivery_date AS hpl,
  p.expected_delivery_date_source AS hpl_selected_source,
  u.pregnancy_first_seen_timestamp,
  u.pregnancy_first_seen_date,
  u.pregnancy_first_upload_timestamp,
  u.pregnancy_first_ingestion_timestamp,
  u.pregnancy_first_seen_source_system,
  u.pregnancy_first_seen_source_table,
  u.pregnancy_first_seen_source_record_id,
  u.pregnancy_first_seen_source_episode_id,
  u.pregnancy_first_seen_source_episode_ids,
  u.pregnancy_first_seen_resolution_method,
  u.pregnancy_first_seen_fallback_flag,
  u.pregnancy_first_seen_cleaned_row_fallback_flag,
  u.pregnancy_last_seen_timestamp,
  u.pregnancy_last_seen_date,
  u.pregnancy_last_upload_timestamp,
  u.pregnancy_last_ingestion_timestamp,
  u.pregnancy_lineage_status,
  p.actual_delivery_date,
  p.dated_delivery_outcome AS validated_delivery_outcome,
  p.primary_birth_source AS primary_delivery_source,
  p.puskesmas,
  p.puskesmas_norm,
  p.desa,
  p.desa_norm,
  p.posyandu,
  p.posyandu_norm,
  u.source_lineage_record_count AS contributing_source_record_count,
  u.sigizi_source_record_count,
  u.epus_source_record_count,
  u.records_with_file_name,
  u.source_records_with_upload_timestamp,
  u.source_records_with_ingestion_timestamp,
  u.source_records_without_any_timestamp,
  u.source_records_using_first_seen_fallback,
  u.any_first_seen_fallback_flag,
  u.any_cleaned_row_fallback_flag,
  u.source_record_id_collision_rows,
  u.unresolved_lineage_row_count,
  u.any_source_lineage_resolved_flag,
  COALESCE(
    u.pregnancy_first_seen_date = CURRENT_DATE('Asia/Jakarta'), FALSE
  ) AS first_seen_today_flag,
  COALESCE(
    u.pregnancy_first_seen_date BETWEEN
      DATE_SUB(CURRENT_DATE('Asia/Jakarta'), INTERVAL 6 DAY)
      AND CURRENT_DATE('Asia/Jakarta'), FALSE
  ) AS first_seen_rolling_7_days_flag,
  COALESCE(
    u.pregnancy_first_seen_date BETWEEN
      DATE_SUB(CURRENT_DATE('Asia/Jakarta'), INTERVAL 29 DAY)
      AND CURRENT_DATE('Asia/Jakarta'), FALSE
  ) AS first_seen_rolling_30_days_flag
FROM `stellar-orb-451904-d9.kohort_bumil_v2.v_pregnancy_monitoring_integrated` p
JOIN `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3` s
  USING (pregnancy_episode_id)
LEFT JOIN `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_upload_summary_v3_3` u
  USING (pregnancy_episode_id);


-- One row per metric date x first-seen source scope. ALL is unduplicated.
CREATE OR REPLACE VIEW
  `stellar-orb-451904-d9.kohort_bumil_v2.v_new_pregnancy_metrics_daily_v3_3`
AS
WITH registry AS (
  SELECT
    pregnancy_episode_id,
    pregnancy_first_seen_date,
    pregnancy_first_seen_source_system
  FROM `stellar-orb-451904-d9.kohort_bumil_v2.v_pregnancy_registry_v3_3`
  WHERE pregnancy_first_seen_date IS NOT NULL
),
date_bounds AS (
  SELECT
    MIN(pregnancy_first_seen_date) AS first_metric_date,
    GREATEST(MAX(pregnancy_first_seen_date), CURRENT_DATE('Asia/Jakarta'))
      AS last_metric_date
  FROM registry
),
calendar AS (
  SELECT metric_date
  FROM date_bounds,
  UNNEST(
    IF(
      first_metric_date IS NULL,
      ARRAY<DATE>[],
      GENERATE_DATE_ARRAY(first_metric_date, last_metric_date)
    )
  ) metric_date
),
scopes AS (
  SELECT source_scope
  FROM UNNEST(['ALL', 'SIGIZI', 'EPUS']) source_scope
  UNION DISTINCT
  SELECT pregnancy_first_seen_source_system
  FROM registry
  WHERE pregnancy_first_seen_source_system IS NOT NULL
),
scoped_registry AS (
  SELECT pregnancy_episode_id, pregnancy_first_seen_date, 'ALL' AS source_scope
  FROM registry
  UNION ALL
  SELECT
    pregnancy_episode_id,
    pregnancy_first_seen_date,
    pregnancy_first_seen_source_system AS source_scope
  FROM registry
  WHERE pregnancy_first_seen_source_system IS NOT NULL
),
daily AS (
  SELECT
    c.metric_date,
    s.source_scope,
    COUNT(DISTINCT r.pregnancy_episode_id) AS new_pregnancies_daily
  FROM calendar c
  CROSS JOIN scopes s
  LEFT JOIN scoped_registry r
    ON r.pregnancy_first_seen_date = c.metric_date
   AND r.source_scope = s.source_scope
  GROUP BY c.metric_date, s.source_scope
)
SELECT
  metric_date,
  DATE_TRUNC(metric_date, WEEK(MONDAY)) AS metric_week,
  DATE_TRUNC(metric_date, MONTH) AS metric_month,
  source_scope AS first_seen_source_scope,
  new_pregnancies_daily,
  SUM(new_pregnancies_daily) OVER (
    PARTITION BY source_scope ORDER BY metric_date
    ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
  ) AS new_pregnancies_rolling_7_days,
  SUM(new_pregnancies_daily) OVER (
    PARTITION BY source_scope ORDER BY metric_date
    ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
  ) AS new_pregnancies_rolling_30_days
FROM daily;
