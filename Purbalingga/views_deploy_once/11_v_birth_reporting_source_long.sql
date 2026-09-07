-- ============================================================================
-- PURBALINGGA
-- REPORTING COMPLETENESS + TIMELINESS BY SOURCE
--
-- OUTPUT:
--   v_birth_reporting_source_long
--
-- GRAIN:
--   1 row = 1 FINAL canonical dated delivery x 1 source_system
--
-- PURPOSE:
--   Completeness: was the canonical delivery captured by the source?
--   Timeliness : if captured and report date is valid, how long after the
--                clinical delivery date did the record become available?
--
-- IMPORTANT:
--   A report/ingestion date is NOT a clinical delivery date.
-- ============================================================================

CREATE OR REPLACE VIEW
  `stellar-orb-451904-d9.kohort_bumil_v2.v_birth_reporting_source_long`
AS

WITH source_list AS (
  SELECT 'SIGIZI' AS source_system
  UNION ALL SELECT 'EPUS'
  UNION ALL SELECT 'SIMRS'
  UNION ALL SELECT 'EKOHORT'
  UNION ALL SELECT 'BIRTH_CONFIRMATION'
),

delivery_base AS (
  SELECT
    delivery_event_id,
    pregnancy_episode_id,
    delivery_date,
    puskesmas_norm,
    desa_norm,
    pregnancy_linkage_summary,
    pregnancy_linkage_group,
    linked_pregnancy_source_combination,
    canonical_delivery_count,
    linked_delivery_count,
    unlinked_delivery_count,
    source_record_instance_keys
  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.v_delivery_monitoring_integrated`
),

source_members AS (
  SELECT
    d.delivery_event_id,
    s.source_system,
    MIN(s.report_date) AS first_report_date,
    MIN(s.report_timestamp) AS first_report_timestamp,
    COUNT(*) AS source_records
  FROM delivery_base d
  CROSS JOIN UNNEST(d.source_record_instance_keys) AS source_record_instance_key
  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_source_records_v3_3` s
    USING (source_record_instance_key)
  WHERE
    s.event_type = 'DELIVERY'
  GROUP BY
    d.delivery_event_id,
    s.source_system
),

delivery_source_grid AS (
  SELECT
    d.*,
    x.source_system
  FROM delivery_base d
  CROSS JOIN source_list x
),

combined AS (
  SELECT
    g.*,
    m.first_report_date,
    m.first_report_timestamp,
    COALESCE(m.source_records, 0) AS source_records,
    CAST(m.delivery_event_id IS NOT NULL AS INT64) AS reported_in_source_count,
    CAST(m.delivery_event_id IS NULL AS INT64) AS not_reported_in_source_count
  FROM delivery_source_grid g
  LEFT JOIN source_members m
    ON g.delivery_event_id = m.delivery_event_id
   AND g.source_system = m.source_system
),

timeliness AS (
  SELECT
    *,
    CASE
      WHEN first_report_date IS NULL THEN NULL
      ELSE DATE_DIFF(first_report_date, delivery_date, DAY)
    END AS reporting_delay_days
  FROM combined
)

SELECT
  *,

  CAST(first_report_date IS NOT NULL AS INT64)
    AS report_date_available_count,

  CAST(first_report_date IS NULL AS INT64)
    AS report_date_missing_count,

  CAST(reporting_delay_days < 0 AS INT64)
    AS negative_reporting_delay_count,

  CAST(
    first_report_date IS NOT NULL
    AND reporting_delay_days >= 0
    AS INT64
  ) AS valid_report_date_available_count,

  CAST(reporting_delay_days = 0 AS INT64)
    AS reported_h0_count,

  CAST(reporting_delay_days = 1 AS INT64)
    AS reported_h1_exact_count,

  CAST(reporting_delay_days BETWEEN 0 AND 1 AS INT64)
    AS reported_by_h1_count,

  CAST(reporting_delay_days BETWEEN 0 AND 7 AS INT64)
    AS reported_within_7d_count,

  CASE
    WHEN reported_in_source_count = 0
      THEN 'Not captured in source'
    WHEN first_report_date IS NULL
      THEN 'Report date unavailable'
    WHEN reporting_delay_days < 0
      THEN 'Invalid / negative delay'
    WHEN reporting_delay_days = 0
      THEN 'H+0 — Same day'
    WHEN reporting_delay_days = 1
      THEN 'H+1'
    WHEN reporting_delay_days BETWEEN 2 AND 7
      THEN 'H+2–H+7'
    ELSE '>H+7'
  END AS reporting_timeliness_category,

  DATE_TRUNC(delivery_date, WEEK(MONDAY))
    AS delivery_week,

  DATE_TRUNC(delivery_date, MONTH)
    AS delivery_month

FROM timeliness;
