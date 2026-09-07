-- ============================================================================
-- PURBALINGGA
-- DAILY / 7-DAY / 30-DAY REPORTING TREND
--
-- OUTPUT:
--   v_birth_reporting_daily_trend
--
-- This is a VIEW: deploy once; do not schedule daily.
--
-- Completeness denominator retains reported=0 and reported=1.
-- Timeliness denominator is captured records with a valid non-negative
-- report-date delay.
-- ============================================================================

CREATE OR REPLACE VIEW
  `stellar-orb-451904-d9.kohort_bumil_v2.v_birth_reporting_daily_trend`
AS

WITH params AS (
  SELECT
    DATE '2025-01-01' AS start_date,
    CURRENT_DATE('Asia/Jakarta') AS end_date
),

sources AS (
  SELECT 'SIGIZI' AS source_system
  UNION ALL SELECT 'EPUS'
  UNION ALL SELECT 'SIMRS'
  UNION ALL SELECT 'EKOHORT'
  UNION ALL SELECT 'BIRTH_CONFIRMATION'
),

calendar AS (
  SELECT d AS delivery_date
  FROM params,
  UNNEST(GENERATE_DATE_ARRAY(start_date, end_date)) AS d
),

calendar_source AS (
  SELECT
    c.delivery_date,
    s.source_system
  FROM calendar c
  CROSS JOIN sources s
),

daily AS (
  SELECT
    delivery_date,
    source_system,

    SUM(canonical_delivery_count) AS daily_deliveries,
    SUM(reported_in_source_count) AS daily_reported,

    SUM(valid_report_date_available_count)
      AS daily_valid_timeliness_denominator,

    SUM(reported_h0_count) AS daily_reported_h0,
    SUM(reported_h1_exact_count) AS daily_reported_h1_exact,
    SUM(reported_by_h1_count) AS daily_reported_by_h1,

    SUM(
      CASE
        WHEN valid_report_date_available_count = 1
        THEN reporting_delay_days
        ELSE 0
      END
    ) AS daily_valid_delay_days_sum

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.v_birth_reporting_source_long`

  WHERE delivery_date >= DATE '2025-01-01'

  GROUP BY
    delivery_date,
    source_system
),

complete_calendar AS (
  SELECT
    c.delivery_date,
    c.source_system,

    COALESCE(d.daily_deliveries, 0) AS daily_deliveries,
    COALESCE(d.daily_reported, 0) AS daily_reported,

    COALESCE(d.daily_valid_timeliness_denominator, 0)
      AS daily_valid_timeliness_denominator,

    COALESCE(d.daily_reported_h0, 0) AS daily_reported_h0,
    COALESCE(d.daily_reported_h1_exact, 0) AS daily_reported_h1_exact,
    COALESCE(d.daily_reported_by_h1, 0) AS daily_reported_by_h1,

    COALESCE(d.daily_valid_delay_days_sum, 0)
      AS daily_valid_delay_days_sum

  FROM calendar_source c
  LEFT JOIN daily d
    USING (delivery_date, source_system)
),

rolling AS (
  SELECT
    *,

    SUM(daily_deliveries) OVER (
      PARTITION BY source_system
      ORDER BY delivery_date
      ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS deliveries_7d,

    SUM(daily_reported) OVER (
      PARTITION BY source_system
      ORDER BY delivery_date
      ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS reported_7d,

    SUM(daily_valid_timeliness_denominator) OVER (
      PARTITION BY source_system
      ORDER BY delivery_date
      ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS valid_timeliness_denominator_7d,

    SUM(daily_reported_by_h1) OVER (
      PARTITION BY source_system
      ORDER BY delivery_date
      ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS reported_by_h1_7d,

    SUM(daily_valid_delay_days_sum) OVER (
      PARTITION BY source_system
      ORDER BY delivery_date
      ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS valid_delay_days_sum_7d,

    SUM(daily_deliveries) OVER (
      PARTITION BY source_system
      ORDER BY delivery_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS deliveries_30d,

    SUM(daily_reported) OVER (
      PARTITION BY source_system
      ORDER BY delivery_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS reported_30d

  FROM complete_calendar
)

SELECT
  *,

  DATE_TRUNC(delivery_date, WEEK(MONDAY)) AS delivery_week,
  DATE_TRUNC(delivery_date, MONTH) AS delivery_month,

  SAFE_DIVIDE(daily_reported, daily_deliveries)
    AS completeness_daily,

  SAFE_DIVIDE(reported_7d, deliveries_7d)
    AS completeness_7d,

  SAFE_DIVIDE(reported_30d, deliveries_30d)
    AS completeness_30d,

  SAFE_DIVIDE(
    reported_by_h1_7d,
    valid_timeliness_denominator_7d
  ) AS timeliness_h1_7d,

  SAFE_DIVIDE(
    valid_delay_days_sum_7d,
    valid_timeliness_denominator_7d
  ) AS average_reporting_delay_days_7d

FROM rolling;
