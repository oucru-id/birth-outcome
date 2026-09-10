-- Run as a separate BigQuery job after 21_pregnancy_first_seen.sql.
-- This script contains no temporary UDFs.

CREATE OR REPLACE VIEW
  `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_registry_v3_3`
AS
SELECT
  p.pregnancy_episode_id,
  p.nama_ibu AS nama,
  p.nik_clean AS nik,
  p.no_hp_clean AS no_hp,
  p.pregnancy_source_combination,
  p.in_sigizi_pregnancy,
  p.in_epus_pregnancy,
  p.integrated_monitoring_status_all_history AS status_kehamilan,
  p.integrated_monitoring_status_operational AS status_kehamilan_operasional,
  p.integrated_pregnancy_outcome AS luaran_kehamilan,
  p.hpht_date AS hpht,
  p.hpht_source,
  p.expected_delivery_date AS hpl,
  p.expected_delivery_date_source AS hpl_source,
  u.pregnancy_first_seen_timestamp,
  u.pregnancy_first_seen_date,
  u.pregnancy_first_upload_timestamp,
  u.pregnancy_first_ingestion_timestamp,
  u.pregnancy_first_seen_source_system,
  u.pregnancy_first_seen_source_table,
  u.pregnancy_first_seen_resolution_method,
  u.any_first_seen_fallback_flag,
  u.pregnancy_last_seen_timestamp,
  u.pregnancy_last_seen_date,
  p.integrated_delivery_date AS tanggal_actual_melahirkan,
  p.integrated_delivery_outcome AS luaran_persalinan_tervalidasi,
  p.integrated_primary_delivery_source AS sumber_persalinan_utama,
  p.puskesmas,
  p.puskesmas_norm,
  p.desa,
  p.desa_norm,
  p.posyandu,
  u.source_lineage_record_count,
  u.sigizi_source_record_count,
  u.epus_source_record_count,
  DATE_DIFF(
    CURRENT_DATE('Asia/Makassar'),
    u.pregnancy_first_seen_date,
    DAY
  ) AS days_since_first_seen,
  u.pregnancy_first_seen_date = CURRENT_DATE('Asia/Makassar')
    AS new_pregnancy_today_flag,
  u.pregnancy_first_seen_date BETWEEN
    DATE_SUB(CURRENT_DATE('Asia/Makassar'), INTERVAL 6 DAY)
    AND CURRENT_DATE('Asia/Makassar')
    AS new_pregnancy_last_7_days_flag,
  u.pregnancy_first_seen_date BETWEEN
    DATE_SUB(CURRENT_DATE('Asia/Makassar'), INTERVAL 29 DAY)
    AND CURRENT_DATE('Asia/Makassar')
    AS new_pregnancy_last_30_days_flag
FROM `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_monitoring_integrated` p
LEFT JOIN `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_upload_summary_v3_3` u
  USING (pregnancy_episode_id);


CREATE OR REPLACE VIEW
  `spheres-lombok-barat.kohort_bumil_v3.v_new_pregnancy_metrics_daily_v3_3`
AS
WITH first_seen AS (
  SELECT
    pregnancy_episode_id,
    pregnancy_first_seen_date,
    COALESCE(pregnancy_first_seen_source_system, 'UNKNOWN')
      AS pregnancy_first_seen_source_system
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_upload_summary_v3_3`
  WHERE pregnancy_first_seen_date IS NOT NULL
),
scoped AS (
  SELECT
    pregnancy_episode_id,
    pregnancy_first_seen_date,
    'ALL' AS source_scope
  FROM first_seen

  UNION ALL

  SELECT
    pregnancy_episode_id,
    pregnancy_first_seen_date,
    pregnancy_first_seen_source_system AS source_scope
  FROM first_seen
),
calendar AS (
  SELECT metric_date
  FROM UNNEST(
    GENERATE_DATE_ARRAY(
      (SELECT MIN(pregnancy_first_seen_date) FROM first_seen),
      CURRENT_DATE('Asia/Makassar')
    )
  ) metric_date
),
scopes AS (
  SELECT DISTINCT source_scope
  FROM scoped
)
SELECT
  c.metric_date,
  s.source_scope,
  COUNT(DISTINCT IF(
    p.pregnancy_first_seen_date = c.metric_date,
    p.pregnancy_episode_id,
    NULL
  )) AS new_pregnancies_daily,
  COUNT(DISTINCT IF(
    p.pregnancy_first_seen_date BETWEEN
      DATE_SUB(c.metric_date, INTERVAL 6 DAY)
      AND c.metric_date,
    p.pregnancy_episode_id,
    NULL
  )) AS new_pregnancies_rolling_7_days,
  COUNT(DISTINCT IF(
    p.pregnancy_first_seen_date BETWEEN
      DATE_SUB(c.metric_date, INTERVAL 29 DAY)
      AND c.metric_date,
    p.pregnancy_episode_id,
    NULL
  )) AS new_pregnancies_rolling_30_days
FROM calendar c
CROSS JOIN scopes s
LEFT JOIN scoped p
  ON p.source_scope = s.source_scope
 AND p.pregnancy_first_seen_date BETWEEN
       DATE_SUB(c.metric_date, INTERVAL 29 DAY)
       AND c.metric_date
GROUP BY
  c.metric_date,
  s.source_scope;


SELECT *
FROM `spheres-lombok-barat.kohort_bumil_v3.v_new_pregnancy_metrics_daily_v3_3`
WHERE metric_date = CURRENT_DATE('Asia/Makassar')
ORDER BY source_scope;
