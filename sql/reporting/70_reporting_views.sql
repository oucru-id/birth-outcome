-- Run AFTER core stages 10-60. Explicit field projections preserve captured v3 schemas.
-- A missing exposed field causes failure rather than silent removal.
DECLARE projection STRING;
DECLARE deployed_sql STRING;

-- v_birth_source_delay_category_long
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_birth_source_delay_category_long');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_birth_source_delay_category_long';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_birth_source_delay_category_long` AS SELECT ',
 projection, ' FROM (', r"""WITH base AS (

  SELECT
    delivery_date,

    DATE_TRUNC(
      delivery_date,
      MONTH
    ) AS delivery_month,

    DATE_TRUNC(
      delivery_date,
      WEEK(MONDAY)
    ) AS delivery_week,

    EXTRACT(
      YEAR FROM delivery_date
    ) AS delivery_year,

    source_system,
    source_system_display,
    source_order,

    delivery_event_id,

    strict_native_reporting_delay_days,

    strict_native_timeliness_evaluable_flag

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_source_first_report_native`

  WHERE
    delivery_date >= DATE '2025-01-01'
),


classified AS (

  SELECT
    *,

    CASE

      WHEN strict_native_reporting_delay_days
           BETWEEN 0 AND 1
        THEN '1. Tepat Waktu (H+0 to H+1)'

      WHEN strict_native_reporting_delay_days
           BETWEEN 2 AND 7
        THEN '2. Terlambat (H+2 to H+7)'

      WHEN strict_native_reporting_delay_days > 7
        THEN '3. Sangat Terlambat (> H+7)'

      ELSE 'Not evaluable'

    END AS reporting_delay_category,


    CASE

      WHEN strict_native_reporting_delay_days
           BETWEEN 0 AND 1
        THEN 1

      WHEN strict_native_reporting_delay_days
           BETWEEN 2 AND 7
        THEN 2

      WHEN strict_native_reporting_delay_days > 7
        THEN 3

      ELSE 4

    END AS reporting_delay_category_order

  FROM base
),


aggregated AS (

  SELECT
    delivery_month,
    delivery_week,
    delivery_year,

    source_system,
    source_system_display,
    source_order,

    reporting_delay_category,
    reporting_delay_category_order,

    COUNT(
      DISTINCT delivery_event_id
    ) AS event_count

  FROM classified

  WHERE
    strict_native_timeliness_evaluable_flag

  GROUP BY
    delivery_month,
    delivery_week,
    delivery_year,
    source_system,
    source_system_display,
    source_order,
    reporting_delay_category,
    reporting_delay_category_order
),


with_denominator AS (

  SELECT
    *,

    SUM(
      event_count
    ) OVER (
      PARTITION BY
        delivery_month,
        source_system
    ) AS timeliness_evaluable_events_month

  FROM aggregated
)

SELECT
  *,

  SAFE_DIVIDE(
    event_count,
    timeliness_evaluable_events_month
  ) AS event_share

FROM with_denominator""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_birth_source_export_observations
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_birth_source_export_observations');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_birth_source_export_observations';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_birth_source_export_observations` AS SELECT ',
 projection, ' FROM (', r"""WITH raw_exports AS (

  -- ========================================================================
  -- EPUS INC
  -- ========================================================================
  SELECT DISTINCT
    'EPUS' AS source_system,
    'EPUS_INC' AS source_table,

    file_name,

    REGEXP_EXTRACT(
      CAST(file_name AS STRING),
      r'^(.*?)_ePuskesmas_'
    ) AS facility_file

  FROM
    `spheres-lombok-barat.raw_data.epus_inc`

  WHERE file_name IS NOT NULL


  UNION ALL


  -- ========================================================================
  -- SIGIZI KOHORT IBU
  -- ========================================================================
  SELECT DISTINCT
    'SIGIZI' AS source_system,
    'KOHORT_IBU' AS source_table,

    file_name,

    REGEXP_EXTRACT(
      CAST(file_name AS STRING),
      r'^(.*?)_SIGIZI_'
    ) AS facility_file

  FROM
    `spheres-lombok-barat.raw_data.sigizi_kohort_ibu`

  WHERE file_name IS NOT NULL


  UNION ALL


  -- ========================================================================
  -- SIGIZI DAFTAR IBU
  -- ========================================================================
  SELECT DISTINCT
    'SIGIZI' AS source_system,
    'DAFTAR_IBU' AS source_table,

    file_name,

    REGEXP_EXTRACT(
      CAST(file_name AS STRING),
      r'^(.*?)_SIGIZI_'
    ) AS facility_file

  FROM
    `spheres-lombok-barat.raw_data.sigizi_daftar_ibu`

  WHERE file_name IS NOT NULL


  UNION ALL


  -- ========================================================================
  -- SIGIZI KOHORT NIFAS
  -- ========================================================================
  SELECT DISTINCT
    'SIGIZI' AS source_system,
    'KOHORT_NIFAS' AS source_table,

    file_name,

    REGEXP_EXTRACT(
      CAST(file_name AS STRING),
      r'^(.*?)_SIGIZI_'
    ) AS facility_file

  FROM
    `spheres-lombok-barat.raw_data.sigizi_ibu_nifas`

  WHERE file_name IS NOT NULL
),


parsed AS (
  SELECT
    *,

    SAFE.PARSE_DATETIME(
      '%Y-%m-%d %H:%M:%E*S',

      REPLACE(
        REGEXP_EXTRACT(
          CAST(file_name AS STRING),
          r'(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
        ),
        'T',
        ' '
      )
    ) AS export_datetime,

    REGEXP_REPLACE(
      REGEXP_REPLACE(
        UPPER(
          TRIM(
            COALESCE(
              facility_file,
              ''
            )
          )
        ),
        r'^PUSKESMAS\s+',
        ''
      ),
      r'[^A-Z0-9]',
      ''
    ) AS facility_compact

  FROM raw_exports
),


normalized AS (
  SELECT
    source_system,
    source_table,

    facility_file,

    -- ----------------------------------------------------------------------
    -- Known facility spelling normalization
    -- ----------------------------------------------------------------------
    CASE

      WHEN facility_compact IN (
        'PERAMPUAN',
        'PEREMPUAN'
      )
      THEN 'PERAMPUAN'

      ELSE facility_compact

    END AS facility_key,

    file_name,

    export_datetime,

    DATE(export_datetime)
      AS export_date

  FROM parsed

  WHERE export_datetime IS NOT NULL
)


SELECT DISTINCT
  source_system,
  source_table,

  facility_file,
  facility_key,

  file_name,

  export_datetime,
  export_date

FROM normalized""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_birth_source_performance_daily_long
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_birth_source_performance_daily_long');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_birth_source_performance_daily_long';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_birth_source_performance_daily_long` AS SELECT ',
 projection, ' FROM (', r"""WITH

-- =============================================================================
-- PARAMETERS
-- =============================================================================

params AS (
  SELECT
    DATE '2025-01-01' AS analysis_start_date,

    CURRENT_DATE(
      'Asia/Makassar'
    ) AS analysis_date
),


-- =============================================================================
-- SOURCE LIST
-- =============================================================================

source_list AS (
  SELECT *
  FROM UNNEST([

    STRUCT(
      'TOTAL_ANY_SOURCE' AS source_system,
      'Total (Any Source)' AS source_system_display,
      0 AS source_order
    ),

    STRUCT(
      'INC_REPORT_TRACKER',
      'Birth Report Faskes',
      1
    ),

    STRUCT(
      'SIGIZI',
      'SIGIZI',
      2
    ),

    STRUCT(
      'EPUS',
      'ePuskesmas',
      3
    ),

    STRUCT(
      'SIMRS',
      'SIMRS',
      4
    ),

    STRUCT(
      'KOBO_INC',
      'Kobo INC',
      5
    ),

    STRUCT(
      'NEONATAL_OUTCOME',
      'Neonatal Outcome',
      6
    )

  ])
),


-- =============================================================================
-- COMPLETE CALENDAR
-- =============================================================================

calendar AS (
  SELECT
    metric_date

  FROM params,

  UNNEST(
    GENERATE_DATE_ARRAY(
      analysis_start_date,
      analysis_date
    )
  ) AS metric_date
),


-- =============================================================================
-- CANONICAL KNOWN-BIRTH DENOMINATOR
--
-- Grain:
--   actual delivery date
--
-- Used for:
--   source capture completeness
-- =============================================================================

canonical_daily AS (
  SELECT
    delivery_date AS metric_date,

    COUNT(*) AS known_births_daily

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_v3`,
    params

  WHERE
    strict_birth_count_eligible_flag

    AND delivery_date BETWEEN
      analysis_start_date
      AND analysis_date

  GROUP BY
    delivery_date
),


-- =============================================================================
-- SOURCE DAILY COUNTERS
--
-- IMPORTANT:
--
-- Timeliness is based ONLY on:
--
--   strict_native_reporting_delay_days
--
-- NOT:
--
--   reporting_delay_days
--   snapshot_date
--   ingestion fallback
--
-- =============================================================================

source_daily AS (

  SELECT
    delivery_date AS metric_date,

    source_system,


    -- =========================================================================
    -- SOURCE CAPTURE
    -- =========================================================================

    COUNT(*) AS source_births_recorded_daily,


    -- =========================================================================
    -- REPORT-DATE QA
    -- =========================================================================

    COUNTIF(
      first_report_date IS NOT NULL
    ) AS report_date_available_daily,


    COUNTIF(
      report_timestamp_missing_flag
    ) AS report_timestamp_missing_daily,


    COUNTIF(
      negative_reporting_delay_flag
    ) AS negative_delay_daily,


    -- =========================================================================
    -- STRICT-NATIVE TIMELINESS DENOMINATOR
    -- =========================================================================

    COUNTIF(
      strict_native_timeliness_evaluable_flag
    ) AS timeliness_evaluable_daily,


    COUNTIF(
      strict_native_report_missing_flag
    ) AS valid_report_missing_daily,


    -- =========================================================================
    -- FALLBACK-ONLY QA
    --
    -- A valid report exists, but no strict-native valid report exists.
    -- =========================================================================

    COUNTIF(
      timeliness_evaluable_flag

      AND NOT
        strict_native_timeliness_evaluable_flag
    ) AS fallback_only_daily,


    -- =========================================================================
    -- STRICT-NATIVE DELAY DISTRIBUTION
    -- =========================================================================

    COUNTIF(
      strict_native_reporting_delay_days = 0
    ) AS delay_h0_daily,


    COUNTIF(
      strict_native_reporting_delay_days = 1
    ) AS delay_h1_daily,


    COUNTIF(
      strict_native_reporting_delay_days = 2
    ) AS delay_h2_daily,


    COUNTIF(
      strict_native_reporting_delay_days = 3
    ) AS delay_h3_daily,


    COUNTIF(
      strict_native_reporting_delay_days = 4
    ) AS delay_h4_daily,


    COUNTIF(
      strict_native_reporting_delay_days = 5
    ) AS delay_h5_daily,


    COUNTIF(
      strict_native_reporting_delay_days = 6
    ) AS delay_h6_daily,


    COUNTIF(
      strict_native_reporting_delay_days = 7
    ) AS delay_h7_daily,


    COUNTIF(
      strict_native_reporting_delay_days
        BETWEEN 8 AND 14
    ) AS delay_h8_h14_daily,


    COUNTIF(
      strict_native_reporting_delay_days
        BETWEEN 15 AND 30
    ) AS delay_h15_h30_daily,


    COUNTIF(
      strict_native_reporting_delay_days > 30
    ) AS delay_gt_h30_daily,


    -- =========================================================================
    -- STRICT-NATIVE CUMULATIVE TIMELINESS
    -- =========================================================================

    COUNTIF(
      strict_native_reporting_delay_days = 0
    ) AS reported_h0_daily,


    COUNTIF(
      strict_native_reporting_delay_days
        BETWEEN 0 AND 1
    ) AS reported_by_h1_daily,


    COUNTIF(
      strict_native_reporting_delay_days
        BETWEEN 0 AND 3
    ) AS reported_by_h3_daily,


    COUNTIF(
      strict_native_reporting_delay_days
        BETWEEN 0 AND 7
    ) AS reported_by_h7_daily,


    COUNTIF(
      strict_native_reporting_delay_days
        BETWEEN 0 AND 14
    ) AS reported_by_h14_daily,


    COUNTIF(
      strict_native_reporting_delay_days
        BETWEEN 0 AND 30
    ) AS reported_by_h30_daily


  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_source_first_report_native`,
    params


  WHERE
    delivery_date BETWEEN
      analysis_start_date
      AND analysis_date


  GROUP BY
    metric_date,
    source_system
),


-- =============================================================================
-- COMPLETE DATE × SOURCE GRID
--
-- This is important so:
--
-- ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
--
-- really represents 30 CALENDAR DAYS.
-- =============================================================================

complete_grid AS (

  SELECT
    c.metric_date,


    DATE_TRUNC(
      c.metric_date,
      WEEK(MONDAY)
    ) AS metric_week,


    DATE_TRUNC(
      c.metric_date,
      MONTH
    ) AS metric_month,


    FORMAT_DATE(
      '%b %Y',
      c.metric_date
    ) AS metric_month_label,


    DATE_TRUNC(
      c.metric_date,
      QUARTER
    ) AS metric_quarter,


    EXTRACT(
      YEAR
      FROM c.metric_date
    ) AS metric_year,


    s.source_system,
    s.source_system_display,
    s.source_order,


    -- =========================================================================
    -- CANONICAL DENOMINATOR
    -- =========================================================================

    COALESCE(
      b.known_births_daily,
      0
    ) AS known_births_daily,


    -- =========================================================================
    -- SOURCE CAPTURE
    -- =========================================================================

    COALESCE(
      d.source_births_recorded_daily,
      0
    ) AS source_births_recorded_daily,


    -- =========================================================================
    -- QA
    -- =========================================================================

    COALESCE(
      d.report_date_available_daily,
      0
    ) AS report_date_available_daily,


    COALESCE(
      d.report_timestamp_missing_daily,
      0
    ) AS report_timestamp_missing_daily,


    COALESCE(
      d.negative_delay_daily,
      0
    ) AS negative_delay_daily,


    COALESCE(
      d.timeliness_evaluable_daily,
      0
    ) AS timeliness_evaluable_daily,


    COALESCE(
      d.valid_report_missing_daily,
      0
    ) AS valid_report_missing_daily,


    COALESCE(
      d.fallback_only_daily,
      0
    ) AS fallback_only_daily,


    -- =========================================================================
    -- DELAY DISTRIBUTION
    -- =========================================================================

    COALESCE(
      d.delay_h0_daily,
      0
    ) AS delay_h0_daily,


    COALESCE(
      d.delay_h1_daily,
      0
    ) AS delay_h1_daily,


    COALESCE(
      d.delay_h2_daily,
      0
    ) AS delay_h2_daily,


    COALESCE(
      d.delay_h3_daily,
      0
    ) AS delay_h3_daily,


    COALESCE(
      d.delay_h4_daily,
      0
    ) AS delay_h4_daily,


    COALESCE(
      d.delay_h5_daily,
      0
    ) AS delay_h5_daily,


    COALESCE(
      d.delay_h6_daily,
      0
    ) AS delay_h6_daily,


    COALESCE(
      d.delay_h7_daily,
      0
    ) AS delay_h7_daily,


    COALESCE(
      d.delay_h8_h14_daily,
      0
    ) AS delay_h8_h14_daily,


    COALESCE(
      d.delay_h15_h30_daily,
      0
    ) AS delay_h15_h30_daily,


    COALESCE(
      d.delay_gt_h30_daily,
      0
    ) AS delay_gt_h30_daily,


    -- =========================================================================
    -- CUMULATIVE TIMELINESS
    -- =========================================================================

    COALESCE(
      d.reported_h0_daily,
      0
    ) AS reported_h0_daily,


    COALESCE(
      d.reported_by_h1_daily,
      0
    ) AS reported_by_h1_daily,


    COALESCE(
      d.reported_by_h3_daily,
      0
    ) AS reported_by_h3_daily,


    COALESCE(
      d.reported_by_h7_daily,
      0
    ) AS reported_by_h7_daily,


    COALESCE(
      d.reported_by_h14_daily,
      0
    ) AS reported_by_h14_daily,


    COALESCE(
      d.reported_by_h30_daily,
      0
    ) AS reported_by_h30_daily


  FROM calendar c

  CROSS JOIN source_list s


  LEFT JOIN canonical_daily b
    ON c.metric_date = b.metric_date


  LEFT JOIN source_daily d
    ON c.metric_date = d.metric_date
   AND s.source_system = d.source_system
),


-- =============================================================================
-- 30-DAY + MONTHLY WINDOWS
-- =============================================================================

windowed AS (

  SELECT
    *,


    -- =========================================================================
    -- MONTH ANCHOR
    -- =========================================================================

    MAX(
      metric_date
    ) OVER (

      PARTITION BY
        source_system,
        metric_month

    ) AS month_anchor_date,


    -- =========================================================================
    -- 30-DAY — SOURCE CAPTURE
    -- =========================================================================

    SUM(
      known_births_daily
    ) OVER (

      PARTITION BY source_system

      ORDER BY metric_date

      ROWS BETWEEN
        29 PRECEDING
        AND CURRENT ROW

    ) AS known_births_30d,


    SUM(
      source_births_recorded_daily
    ) OVER (

      PARTITION BY source_system

      ORDER BY metric_date

      ROWS BETWEEN
        29 PRECEDING
        AND CURRENT ROW

    ) AS source_births_recorded_30d,


    -- =========================================================================
    -- 30-DAY — QA / DENOMINATORS
    -- =========================================================================

    SUM(
      report_date_available_daily
    ) OVER (

      PARTITION BY source_system

      ORDER BY metric_date

      ROWS BETWEEN
        29 PRECEDING
        AND CURRENT ROW

    ) AS report_date_available_30d,


    SUM(
      timeliness_evaluable_daily
    ) OVER (

      PARTITION BY source_system

      ORDER BY metric_date

      ROWS BETWEEN
        29 PRECEDING
        AND CURRENT ROW

    ) AS timeliness_evaluable_30d,


    SUM(
      negative_delay_daily
    ) OVER (

      PARTITION BY source_system

      ORDER BY metric_date

      ROWS BETWEEN
        29 PRECEDING
        AND CURRENT ROW

    ) AS negative_delay_30d,


    SUM(
      report_timestamp_missing_daily
    ) OVER (

      PARTITION BY source_system

      ORDER BY metric_date

      ROWS BETWEEN
        29 PRECEDING
        AND CURRENT ROW

    ) AS report_timestamp_missing_30d,


    SUM(
      valid_report_missing_daily
    ) OVER (

      PARTITION BY source_system

      ORDER BY metric_date

      ROWS BETWEEN
        29 PRECEDING
        AND CURRENT ROW

    ) AS valid_report_missing_30d,


    SUM(
      fallback_only_daily
    ) OVER (

      PARTITION BY source_system

      ORDER BY metric_date

      ROWS BETWEEN
        29 PRECEDING
        AND CURRENT ROW

    ) AS fallback_only_30d,


    -- =========================================================================
    -- 30-DAY — CUMULATIVE TIMELINESS
    -- =========================================================================

    SUM(
      reported_h0_daily
    ) OVER (

      PARTITION BY source_system

      ORDER BY metric_date

      ROWS BETWEEN
        29 PRECEDING
        AND CURRENT ROW

    ) AS reported_h0_30d,


    SUM(
      reported_by_h1_daily
    ) OVER (

      PARTITION BY source_system

      ORDER BY metric_date

      ROWS BETWEEN
        29 PRECEDING
        AND CURRENT ROW

    ) AS reported_by_h1_30d,


    SUM(
      reported_by_h3_daily
    ) OVER (

      PARTITION BY source_system

      ORDER BY metric_date

      ROWS BETWEEN
        29 PRECEDING
        AND CURRENT ROW

    ) AS reported_by_h3_30d,


    SUM(
      reported_by_h7_daily
    ) OVER (

      PARTITION BY source_system

      ORDER BY metric_date

      ROWS BETWEEN
        29 PRECEDING
        AND CURRENT ROW

    ) AS reported_by_h7_30d,


    SUM(
      reported_by_h14_daily
    ) OVER (

      PARTITION BY source_system

      ORDER BY metric_date

      ROWS BETWEEN
        29 PRECEDING
        AND CURRENT ROW

    ) AS reported_by_h14_30d,


    SUM(
      reported_by_h30_daily
    ) OVER (

      PARTITION BY source_system

      ORDER BY metric_date

      ROWS BETWEEN
        29 PRECEDING
        AND CURRENT ROW

    ) AS reported_by_h30_30d,


    -- =========================================================================
    -- 30-DAY — DELAY DISTRIBUTION
    -- =========================================================================

    SUM(delay_h0_daily) OVER (
      PARTITION BY source_system
      ORDER BY metric_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS delay_h0_30d,


    SUM(delay_h1_daily) OVER (
      PARTITION BY source_system
      ORDER BY metric_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS delay_h1_30d,


    SUM(delay_h2_daily) OVER (
      PARTITION BY source_system
      ORDER BY metric_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS delay_h2_30d,


    SUM(delay_h3_daily) OVER (
      PARTITION BY source_system
      ORDER BY metric_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS delay_h3_30d,


    SUM(delay_h4_daily) OVER (
      PARTITION BY source_system
      ORDER BY metric_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS delay_h4_30d,


    SUM(delay_h5_daily) OVER (
      PARTITION BY source_system
      ORDER BY metric_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS delay_h5_30d,


    SUM(delay_h6_daily) OVER (
      PARTITION BY source_system
      ORDER BY metric_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS delay_h6_30d,


    SUM(delay_h7_daily) OVER (
      PARTITION BY source_system
      ORDER BY metric_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS delay_h7_30d,


    SUM(delay_h8_h14_daily) OVER (
      PARTITION BY source_system
      ORDER BY metric_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS delay_h8_h14_30d,


    SUM(delay_h15_h30_daily) OVER (
      PARTITION BY source_system
      ORDER BY metric_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS delay_h15_h30_30d,


    SUM(delay_gt_h30_daily) OVER (
      PARTITION BY source_system
      ORDER BY metric_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS delay_gt_h30_30d,


    -- =========================================================================
    -- MONTHLY — SOURCE CAPTURE
    -- =========================================================================

    SUM(
      known_births_daily
    ) OVER (

      PARTITION BY
        source_system,
        metric_month

    ) AS known_births_month,


    SUM(
      source_births_recorded_daily
    ) OVER (

      PARTITION BY
        source_system,
        metric_month

    ) AS source_births_recorded_month,


    -- =========================================================================
    -- MONTHLY — QA / DENOMINATORS
    -- =========================================================================

    SUM(
      report_date_available_daily
    ) OVER (

      PARTITION BY
        source_system,
        metric_month

    ) AS report_date_available_month,


    SUM(
      timeliness_evaluable_daily
    ) OVER (

      PARTITION BY
        source_system,
        metric_month

    ) AS timeliness_evaluable_month,


    SUM(
      negative_delay_daily
    ) OVER (

      PARTITION BY
        source_system,
        metric_month

    ) AS negative_delay_month,


    SUM(
      report_timestamp_missing_daily
    ) OVER (

      PARTITION BY
        source_system,
        metric_month

    ) AS report_timestamp_missing_month,


    SUM(
      valid_report_missing_daily
    ) OVER (

      PARTITION BY
        source_system,
        metric_month

    ) AS valid_report_missing_month,


    SUM(
      fallback_only_daily
    ) OVER (

      PARTITION BY
        source_system,
        metric_month

    ) AS fallback_only_month,


    -- =========================================================================
    -- MONTHLY — CUMULATIVE TIMELINESS
    -- =========================================================================

    SUM(reported_h0_daily) OVER (
      PARTITION BY source_system, metric_month
    ) AS reported_h0_month,


    SUM(reported_by_h1_daily) OVER (
      PARTITION BY source_system, metric_month
    ) AS reported_by_h1_month,


    SUM(reported_by_h3_daily) OVER (
      PARTITION BY source_system, metric_month
    ) AS reported_by_h3_month,


    SUM(reported_by_h7_daily) OVER (
      PARTITION BY source_system, metric_month
    ) AS reported_by_h7_month,


    SUM(reported_by_h14_daily) OVER (
      PARTITION BY source_system, metric_month
    ) AS reported_by_h14_month,


    SUM(reported_by_h30_daily) OVER (
      PARTITION BY source_system, metric_month
    ) AS reported_by_h30_month,


    -- =========================================================================
    -- MONTHLY — DELAY DISTRIBUTION
    -- =========================================================================

    SUM(delay_h0_daily) OVER (
      PARTITION BY source_system, metric_month
    ) AS delay_h0_month,


    SUM(delay_h1_daily) OVER (
      PARTITION BY source_system, metric_month
    ) AS delay_h1_month,


    SUM(delay_h2_daily) OVER (
      PARTITION BY source_system, metric_month
    ) AS delay_h2_month,


    SUM(delay_h3_daily) OVER (
      PARTITION BY source_system, metric_month
    ) AS delay_h3_month,


    SUM(delay_h4_daily) OVER (
      PARTITION BY source_system, metric_month
    ) AS delay_h4_month,


    SUM(delay_h5_daily) OVER (
      PARTITION BY source_system, metric_month
    ) AS delay_h5_month,


    SUM(delay_h6_daily) OVER (
      PARTITION BY source_system, metric_month
    ) AS delay_h6_month,


    SUM(delay_h7_daily) OVER (
      PARTITION BY source_system, metric_month
    ) AS delay_h7_month,


    SUM(delay_h8_h14_daily) OVER (
      PARTITION BY source_system, metric_month
    ) AS delay_h8_h14_month,


    SUM(delay_h15_h30_daily) OVER (
      PARTITION BY source_system, metric_month
    ) AS delay_h15_h30_month,


    SUM(delay_gt_h30_daily) OVER (
      PARTITION BY source_system, metric_month
    ) AS delay_gt_h30_month


  FROM complete_grid
),


-- =============================================================================
-- FINAL RATES
-- =============================================================================

final AS (

  SELECT
    *,


    CAST(
      metric_date = month_anchor_date
      AS INT64
    ) AS month_anchor_flag,


    -- =========================================================================
    -- SOURCE CAPTURE
    -- =========================================================================

    SAFE_DIVIDE(
      source_births_recorded_daily,
      known_births_daily
    ) AS capture_rate_daily,


    SAFE_DIVIDE(
      source_births_recorded_30d,
      known_births_30d
    ) AS capture_rate_30d,


    SAFE_DIVIDE(
      source_births_recorded_month,
      known_births_month
    ) AS capture_rate_monthly,


    -- =========================================================================
    -- STRICT-NATIVE REPORT-DATE COVERAGE
    -- =========================================================================

    SAFE_DIVIDE(
      timeliness_evaluable_30d,
      source_births_recorded_30d
    ) AS native_timeliness_coverage_rate_30d,


    SAFE_DIVIDE(
      timeliness_evaluable_month,
      source_births_recorded_month
    ) AS native_timeliness_coverage_rate_monthly,


    -- =========================================================================
    -- TIMELINESS — DAILY
    -- =========================================================================

    SAFE_DIVIDE(
      reported_h0_daily,
      timeliness_evaluable_daily
    ) AS timeliness_h0_rate_daily,


    SAFE_DIVIDE(
      reported_by_h1_daily,
      timeliness_evaluable_daily
    ) AS timeliness_h1_rate_daily,


    SAFE_DIVIDE(
      reported_by_h7_daily,
      timeliness_evaluable_daily
    ) AS timeliness_h7_rate_daily,


    -- =========================================================================
    -- TIMELINESS — 30 DAY
    -- =========================================================================

    SAFE_DIVIDE(
      reported_h0_30d,
      timeliness_evaluable_30d
    ) AS timeliness_h0_rate_30d,


    SAFE_DIVIDE(
      reported_by_h1_30d,
      timeliness_evaluable_30d
    ) AS timeliness_h1_rate_30d,


    SAFE_DIVIDE(
      reported_by_h3_30d,
      timeliness_evaluable_30d
    ) AS timeliness_h3_rate_30d,


    SAFE_DIVIDE(
      reported_by_h7_30d,
      timeliness_evaluable_30d
    ) AS timeliness_h7_rate_30d,


    SAFE_DIVIDE(
      reported_by_h14_30d,
      timeliness_evaluable_30d
    ) AS timeliness_h14_rate_30d,


    SAFE_DIVIDE(
      reported_by_h30_30d,
      timeliness_evaluable_30d
    ) AS timeliness_h30_rate_30d,


    -- =========================================================================
    -- TIMELINESS — MONTHLY
    -- =========================================================================

    SAFE_DIVIDE(
      reported_h0_month,
      timeliness_evaluable_month
    ) AS timeliness_h0_rate_monthly,


    SAFE_DIVIDE(
      reported_by_h1_month,
      timeliness_evaluable_month
    ) AS timeliness_h1_rate_monthly,


    SAFE_DIVIDE(
      reported_by_h3_month,
      timeliness_evaluable_month
    ) AS timeliness_h3_rate_monthly,


    SAFE_DIVIDE(
      reported_by_h7_month,
      timeliness_evaluable_month
    ) AS timeliness_h7_rate_monthly,


    SAFE_DIVIDE(
      reported_by_h14_month,
      timeliness_evaluable_month
    ) AS timeliness_h14_rate_monthly,


    SAFE_DIVIDE(
      reported_by_h30_month,
      timeliness_evaluable_month
    ) AS timeliness_h30_rate_monthly,


    -- =========================================================================
    -- DELAY DISTRIBUTION — MONTHLY
    -- =========================================================================

    SAFE_DIVIDE(
      delay_h0_month,
      timeliness_evaluable_month
    ) AS delay_h0_share_monthly,


    SAFE_DIVIDE(
      delay_h1_month,
      timeliness_evaluable_month
    ) AS delay_h1_share_monthly,


    SAFE_DIVIDE(
      delay_h2_month,
      timeliness_evaluable_month
    ) AS delay_h2_share_monthly,


    SAFE_DIVIDE(
      delay_h3_month,
      timeliness_evaluable_month
    ) AS delay_h3_share_monthly,


    SAFE_DIVIDE(
      delay_h4_month,
      timeliness_evaluable_month
    ) AS delay_h4_share_monthly,


    SAFE_DIVIDE(
      delay_h5_month,
      timeliness_evaluable_month
    ) AS delay_h5_share_monthly,


    SAFE_DIVIDE(
      delay_h6_month,
      timeliness_evaluable_month
    ) AS delay_h6_share_monthly,


    SAFE_DIVIDE(
      delay_h7_month,
      timeliness_evaluable_month
    ) AS delay_h7_share_monthly,


    SAFE_DIVIDE(
      delay_h8_h14_month,
      timeliness_evaluable_month
    ) AS delay_h8_h14_share_monthly,


    SAFE_DIVIDE(
      delay_h15_h30_month,
      timeliness_evaluable_month
    ) AS delay_h15_h30_share_monthly,


    SAFE_DIVIDE(
      delay_gt_h30_month,
      timeliness_evaluable_month
    ) AS delay_gt_h30_share_monthly,


    -- =========================================================================
    -- DELAY DISTRIBUTION — 30 DAY
    -- =========================================================================

    SAFE_DIVIDE(
      delay_h0_30d,
      timeliness_evaluable_30d
    ) AS delay_h0_share_30d,


    SAFE_DIVIDE(
      delay_h1_30d,
      timeliness_evaluable_30d
    ) AS delay_h1_share_30d,


    SAFE_DIVIDE(
      delay_h2_30d,
      timeliness_evaluable_30d
    ) AS delay_h2_share_30d,


    SAFE_DIVIDE(
      delay_h3_30d,
      timeliness_evaluable_30d
    ) AS delay_h3_share_30d,


    SAFE_DIVIDE(
      delay_h4_30d,
      timeliness_evaluable_30d
    ) AS delay_h4_share_30d,


    SAFE_DIVIDE(
      delay_h5_30d,
      timeliness_evaluable_30d
    ) AS delay_h5_share_30d,


    SAFE_DIVIDE(
      delay_h6_30d,
      timeliness_evaluable_30d
    ) AS delay_h6_share_30d,


    SAFE_DIVIDE(
      delay_h7_30d,
      timeliness_evaluable_30d
    ) AS delay_h7_share_30d,


    SAFE_DIVIDE(
      delay_h8_h14_30d,
      timeliness_evaluable_30d
    ) AS delay_h8_h14_share_30d,


    SAFE_DIVIDE(
      delay_h15_h30_30d,
      timeliness_evaluable_30d
    ) AS delay_h15_h30_share_30d,


    SAFE_DIVIDE(
      delay_gt_h30_30d,
      timeliness_evaluable_30d
    ) AS delay_gt_h30_share_30d


  FROM windowed
)


-- =============================================================================
-- FINAL OUTPUT
-- =============================================================================

SELECT
  *,


  -- ===========================================================================
  -- OPTIONAL 0–100 CONVENIENCE VARIABLES
  --
  -- In Looker Studio, I recommend using the *_rate_* variables and formatting
  -- them as Percent.
  -- ===========================================================================

  100 * capture_rate_30d
    AS capture_pct_30d,


  100 * capture_rate_monthly
    AS capture_pct_monthly,


  100 * timeliness_h1_rate_30d
    AS timeliness_h1_pct_30d,


  100 * timeliness_h1_rate_monthly
    AS timeliness_h1_pct_monthly,


  100 * timeliness_h7_rate_30d
    AS timeliness_h7_pct_30d,


  100 * timeliness_h7_rate_monthly
    AS timeliness_h7_pct_monthly


FROM final""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_birth_weight_observations
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_birth_weight_observations');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_birth_weight_observations';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_birth_weight_observations` AS SELECT ',
 projection, ' FROM (', r"""WITH

-- ============================================================================
-- 0. FINAL SOURCE -> CANONICAL DELIVERY MEMBER MAP
-- ============================================================================

members AS (
  SELECT
    m.delivery_event_id,
    m.pregnancy_episode_id,

    b.source_system,
    b.source_subtype,
    b.source_event_id,
    b.source_record_id

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_member_map_v3` m

  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_dedup_base` b
    USING (source_event_id)

  WHERE b.source_system IN (
    'EPUS',
    'SIMRS',
    'KOBO_INC',
    'INC_REPORT_TRACKER'
  )
),


-- ============================================================================
-- 1. INC REPORT TRACKER / BIRTH FU
--
-- No explicit baby number.
-- Use sex + weight + length as conservative clinical signature.
-- Exact duplicate signatures inside the same delivery can later collapse
-- to the same baby.
-- ============================================================================

tracker_raw AS (
  SELECT
    CONCAT(
      'INC_REPORT|',
      row_hash
    ) AS source_event_id,

    row_hash AS source_baby_record_id,

    tanggal_melahirkan AS source_delivery_date,

    CASE
      WHEN UPPER(TRIM(COALESCE(jenis_kelamin_bayi, ''))) IN (
        '',
        '-',
        '<NA>',
        'NA',
        'N/A',
        'NULL',
        'UNKNOWN',
        'TIDAK DIKETAHUI'
      )
        THEN NULL

      WHEN REGEXP_CONTAINS(
        UPPER(jenis_kelamin_bayi),
        r'LAKI'
      )
        THEN 'Laki-laki'

      WHEN REGEXP_CONTAINS(
        UPPER(jenis_kelamin_bayi),
        r'PEREMPUAN'
      )
        THEN 'Perempuan'

      ELSE NULLIF(
        TRIM(jenis_kelamin_bayi),
        ''
      )
    END AS baby_sex,

    SAFE_CAST(
      berat_badan_bayi_gram AS FLOAT64
    ) AS birth_weight_gram,

    SAFE_CAST(
      panjang_bayi_cm AS FLOAT64
    ) AS birth_length_cm

  FROM
    `spheres-lombok-barat.birth_report_faskes.birth_fu_faskes`

  WHERE row_hash IS NOT NULL
),


tracker_mapped AS (
  SELECT
    m.delivery_event_id,
    m.pregnancy_episode_id,

    'INC_REPORT_TRACKER' AS weight_source,

    r.source_event_id,
    r.source_baby_record_id,

    CONCAT(
      'TRACKER|SEX=',
      COALESCE(r.baby_sex, 'UNKNOWN'),
      '|WT=',
      COALESCE(
        CAST(r.birth_weight_gram AS STRING),
        'NULL'
      ),
      '|LEN=',
      COALESCE(
        CAST(r.birth_length_cm AS STRING),
        'NULL'
      )
    ) AS source_baby_key,

    'CLINICAL_SIGNATURE'
      AS source_baby_key_method,

    r.source_delivery_date,

    CAST(NULL AS STRING)
      AS baby_name,

    r.baby_sex,

    CAST(NULL AS TIME)
      AS birth_time,

    r.birth_weight_gram,

    r.birth_length_cm,

    r.birth_weight_gram
      AS source_weight_min_gram,

    r.birth_weight_gram
      AS source_weight_max_gram,

    1 AS source_weight_record_count,

    FALSE AS source_internal_conflict,

    FALSE AS source_multi_weight_unresolved_flag,

    'TRACKER_RAW_RECORD'
      AS source_record_class,

    'BABY_OBSERVATION'
      AS observation_scope

  FROM members m

  JOIN tracker_raw r
    ON m.source_event_id = r.source_event_id

  WHERE m.source_system = 'INC_REPORT_TRACKER'
),


-- ============================================================================
-- 2. KOBO INC
--
-- Baby 1 / Baby 2 are explicit fields.
-- ============================================================================

kobo_json AS (
  SELECT
    TO_JSON_STRING(t) AS j

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_kobo_inc_case_master` t
),


kobo_base AS (
  SELECT
    CONCAT(
      'KOBO_INC|',
      COALESCE(
        NULLIF(
          JSON_VALUE(j, '$.case_id'),
          ''
        ),
        NULLIF(
          JSON_VALUE(j, '$.source_submission_id'),
          ''
        ),
        CAST(
          FARM_FINGERPRINT(j)
          AS STRING
        )
      )
    ) AS source_event_id,

    COALESCE(
      SAFE_CAST(
        JSON_VALUE(
          j,
          '$.preferred_berat_badan_bayi_1_gram'
        )
        AS FLOAT64
      ),
      SAFE_CAST(
        JSON_VALUE(
          j,
          '$.berat_badan_bayi_1_gram'
        )
        AS FLOAT64
      )
    ) AS baby1_weight,

    SAFE_CAST(
      JSON_VALUE(
        j,
        '$.berat_badan_bayi_2_gram'
      )
      AS FLOAT64
    ) AS baby2_weight,

    COALESCE(
      SAFE_CAST(
        JSON_VALUE(
          j,
          '$.kobo_conflict_baby1_birth_weight'
        )
        AS BOOL
      ),
      FALSE
    ) AS baby1_conflict

  FROM kobo_json
),


kobo_long AS (

  SELECT
    source_event_id,

    '1' AS baby_number,

    baby1_weight AS birth_weight_gram,

    baby1_conflict
      AS source_internal_conflict

  FROM kobo_base

  WHERE baby1_weight IS NOT NULL


  UNION ALL


  SELECT
    source_event_id,

    '2' AS baby_number,

    baby2_weight AS birth_weight_gram,

    FALSE AS source_internal_conflict

  FROM kobo_base

  WHERE baby2_weight IS NOT NULL
),


kobo_mapped AS (
  SELECT
    m.delivery_event_id,
    m.pregnancy_episode_id,

    'KOBO_INC'
      AS weight_source,

    k.source_event_id,

    CONCAT(
      k.source_event_id,
      '|BABY|',
      k.baby_number
    ) AS source_baby_record_id,

    CONCAT(
      'KOBO|BABY|',
      k.baby_number
    ) AS source_baby_key,

    'EXPLICIT_BABY_NUMBER'
      AS source_baby_key_method,

    CAST(NULL AS DATE)
      AS source_delivery_date,

    CAST(NULL AS STRING)
      AS baby_name,

    CAST(NULL AS STRING)
      AS baby_sex,

    CAST(NULL AS TIME)
      AS birth_time,

    k.birth_weight_gram,

    CAST(NULL AS FLOAT64)
      AS birth_length_cm,

    k.birth_weight_gram
      AS source_weight_min_gram,

    k.birth_weight_gram
      AS source_weight_max_gram,

    1 AS source_weight_record_count,

    k.source_internal_conflict,

    FALSE
      AS source_multi_weight_unresolved_flag,

    'KOBO_EXPLICIT_BABY'
      AS source_record_class,

    'BABY_OBSERVATION'
      AS observation_scope

  FROM members m

  JOIN kobo_long k
    ON m.source_event_id = k.source_event_id

  WHERE m.source_system = 'KOBO_INC'
),


-- ============================================================================
-- 3. SIMRS
--
-- IMPORTANT:
-- kelahiran_ke is NOT used as baby identity.
--
-- First normalize weight.
-- Then classify each canonical delivery:
--
-- SINGLE_RECORD
-- LIKELY_DUPLICATE_OR_UPDATE
-- STRONG_MULTIPLE_EXPLICIT_ORDINAL
-- STRONG_MULTIPLE_CLINICAL
-- AMBIGUOUS_MULTIPLE_RECORDS
--
-- Only strong multiple classes create >1 SIMRS baby slot.
-- ============================================================================

simrs_raw AS (
  SELECT
    CONCAT(
      'SIMRS|',
      COALESCE(
        NULLIF(
          TRIM(
            CAST(source_record_id AS STRING)
          ),
          ''
        ),
        NULLIF(
          TRIM(
            CAST(dedup_key AS STRING)
          ),
          ''
        ),
        NULLIF(
          TRIM(
            CAST(source_row_hash AS STRING)
          ),
          ''
        )
      )
    ) AS source_event_id,

    CAST(
      COALESCE(
        NULLIF(
          TRIM(
            CAST(source_record_id AS STRING)
          ),
          ''
        ),
        NULLIF(
          TRIM(
            CAST(dedup_key AS STRING)
          ),
          ''
        ),
        NULLIF(
          TRIM(
            CAST(source_row_hash AS STRING)
          ),
          ''
        )
      )
      AS STRING
    ) AS source_baby_record_id,

    NULLIF(
      LOWER(
        TRIM(
          CAST(nama_bayi_norm AS STRING)
        )
      ),
      ''
    ) AS baby_name,

    jam_lahir_time
      AS birth_time,

    CASE
      WHEN berat_badan_lahir_numeric
        BETWEEN 0.5 AND 10

        THEN ROUND(
          berat_badan_lahir_numeric * 1000
        )

      ELSE
        berat_badan_lahir_numeric
    END AS birth_weight_gram,

    panjang_badan_lahir_numeric
      AS birth_length_cm

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_simrs_patut_patuh_inc`
),


simrs_mapped_base AS (
  SELECT
    m.delivery_event_id,
    m.pregnancy_episode_id,

    s.*

  FROM simrs_raw s

  JOIN members m
    ON s.source_event_id = m.source_event_id

  WHERE m.source_system = 'SIMRS'
),


simrs_with_hint AS (
  SELECT
    *,

    CASE

      WHEN REGEXP_CONTAINS(
        baby_name,
        r'(^|[\s\-_])(1|i)$'
      )
        THEN 1

      WHEN REGEXP_CONTAINS(
        baby_name,
        r'(^|[\s\-_])(2|ii)$'
      )
        THEN 2

      WHEN REGEXP_CONTAINS(
        baby_name,
        r'(^|[\s\-_])(3|iii)$'
      )
        THEN 3

      ELSE NULL

    END AS baby_ordinal_hint,

    CASE
      WHEN birth_time IS NOT NULL
      THEN TIME_DIFF(
        birth_time,
        TIME '00:00:00',
        MINUTE
      )
    END AS birth_minute

  FROM simrs_mapped_base
),


simrs_delivery_stats AS (
  SELECT
    delivery_event_id,

    COUNT(*) AS source_rows,

    COUNT(
      DISTINCT baby_name
    ) AS distinct_names,

    COUNT(
      DISTINCT birth_weight_gram
    ) AS distinct_weights,

    COUNT(
      DISTINCT birth_length_cm
    ) AS distinct_lengths,

    COUNT(
      DISTINCT baby_ordinal_hint
    ) AS distinct_ordinal_hints,

    MIN(birth_minute)
      AS first_birth_minute,

    MAX(birth_minute)
      AS last_birth_minute,

    MAX(birth_minute)
      - MIN(birth_minute)
      AS birth_time_span_minutes

  FROM simrs_with_hint

  GROUP BY delivery_event_id
),


simrs_delivery_class AS (
  SELECT
    *,

    CASE

      -- ------------------------------------------------------
      -- Explicit "baby 1 / baby 2", "I / II", etc.
      -- ------------------------------------------------------
      WHEN distinct_ordinal_hints >= 2
        THEN 'STRONG_MULTIPLE_EXPLICIT_ORDINAL'


      -- ------------------------------------------------------
      -- Different baby names + different anthropometry
      -- + birth times within 2 hours.
      -- ------------------------------------------------------
      WHEN distinct_names >= 2

       AND (
         distinct_weights >= 2
         OR distinct_lengths >= 2
       )

       AND birth_time_span_minutes
         BETWEEN 0 AND 120

        THEN 'STRONG_MULTIPLE_CLINICAL'


      -- ------------------------------------------------------
      -- Repeated records with identical anthropometry.
      -- Conservative assumption = same baby update/duplicate.
      -- ------------------------------------------------------
      WHEN source_rows > 1
       AND distinct_weights = 1
       AND distinct_lengths = 1

        THEN 'LIKELY_DUPLICATE_OR_UPDATE'


      WHEN source_rows > 1
        THEN 'AMBIGUOUS_MULTIPLE_RECORDS'


      ELSE 'SINGLE_RECORD'

    END AS simrs_baby_record_class

  FROM simrs_delivery_stats
),


simrs_classified_rows AS (
  SELECT
    s.*,

    c.simrs_baby_record_class,

    -- --------------------------------------------------------
    -- SOURCE BABY KEY
    --
    -- Only strong multiple evidence is allowed to create
    -- multiple baby slots.
    -- --------------------------------------------------------
    CASE

      WHEN c.simrs_baby_record_class
        = 'STRONG_MULTIPLE_EXPLICIT_ORDINAL'

       AND s.baby_ordinal_hint IS NOT NULL

        THEN CONCAT(
          'SIMRS|ORDINAL|',
          CAST(
            s.baby_ordinal_hint
            AS STRING
          )
        )


      WHEN c.simrs_baby_record_class
        = 'STRONG_MULTIPLE_EXPLICIT_ORDINAL'

        THEN 'SIMRS|MULTIPLE|UNASSIGNED'


      WHEN c.simrs_baby_record_class
        = 'STRONG_MULTIPLE_CLINICAL'

       AND s.baby_name IS NOT NULL

        THEN CONCAT(
          'SIMRS|NAME|',
          s.baby_name
        )


      -- Single, duplicate/update, and ambiguous:
      -- collapse to ONE conservative baby slot.
      ELSE
        'SIMRS|SINGLE_SLOT'

    END AS source_baby_key,


    CASE

      WHEN c.simrs_baby_record_class
        = 'STRONG_MULTIPLE_EXPLICIT_ORDINAL'

       AND s.baby_ordinal_hint IS NOT NULL

        THEN 'EXPLICIT_ORDINAL_IN_NAME'


      WHEN c.simrs_baby_record_class
        = 'STRONG_MULTIPLE_EXPLICIT_ORDINAL'

        THEN 'UNASSIGNED_IN_STRONG_MULTIPLE'


      WHEN c.simrs_baby_record_class
        = 'STRONG_MULTIPLE_CLINICAL'

        THEN 'BABY_NAME_CLINICAL_MULTIPLE'


      WHEN c.simrs_baby_record_class
        = 'LIKELY_DUPLICATE_OR_UPDATE'

        THEN 'CONSERVATIVE_SINGLE_DUPLICATE_UPDATE'


      WHEN c.simrs_baby_record_class
        = 'AMBIGUOUS_MULTIPLE_RECORDS'

        THEN 'CONSERVATIVE_SINGLE_AMBIGUOUS'


      ELSE 'SINGLE_SLOT'

    END AS source_baby_key_method

  FROM simrs_with_hint s

  JOIN simrs_delivery_class c
    USING (delivery_event_id)
),


simrs_final AS (
  SELECT
    delivery_event_id,
    pregnancy_episode_id,

    'SIMRS'
      AS weight_source,

    source_event_id,

    source_baby_record_id,

    source_baby_key,

    source_baby_key_method,

    CAST(NULL AS DATE)
      AS source_delivery_date,

    baby_name,

    CAST(NULL AS STRING)
      AS baby_sex,

    birth_time,

    birth_weight_gram,

    birth_length_cm,

    birth_weight_gram
      AS source_weight_min_gram,

    birth_weight_gram
      AS source_weight_max_gram,

    1 AS source_weight_record_count,

    FALSE AS source_internal_conflict,

    FALSE AS source_multi_weight_unresolved_flag,

    simrs_baby_record_class
      AS source_record_class,

    CASE
      WHEN source_baby_key
        = 'SIMRS|MULTIPLE|UNASSIGNED'

        THEN 'UNASSIGNED_MULTIPLE_OBSERVATION'

      ELSE 'BABY_OBSERVATION'
    END AS observation_scope

  FROM simrs_classified_rows
),


-- ============================================================================
-- 4. EPUS
--
-- EPUS pregnancy master already reconciles individual INC weight evidence.
--
-- Current audit:
--   744 pregnancies have birth weight
--   all 744 bridge to INC
--   only 2 have >1 birth-weight record
--
-- Therefore:
--   birth_weight_record_count = 1
--       -> safe scalar baby observation
--
--   birth_weight_record_count > 1
--       -> retain as unresolved delivery-level weight summary
--          DO NOT create multiple babies automatically
-- ============================================================================

epus_base AS (
  SELECT
    epus_pregnancy_key,

    birth_weight_min_gram,
    birth_weight_max_gram,

    birth_weight_record_count,

    bblr_baby_record_count,

    inc_baby_record_count,

    has_multiple_inc_baby_records

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_master`

  WHERE
    birth_weight_record_count > 0
),


epus_mapped AS (
  SELECT
    m.delivery_event_id,
    m.pregnancy_episode_id,

    'EPUS'
      AS weight_source,

    CONCAT(
      'EPUS|',
      e.epus_pregnancy_key
    ) AS source_event_id,

    CONCAT(
      'EPUS|',
      e.epus_pregnancy_key,
      '|WEIGHT'
    ) AS source_baby_record_id,


    CASE

      WHEN e.birth_weight_record_count = 1
        THEN 'EPUS|SINGLE_WEIGHT'

      ELSE
        'EPUS|MULTI_WEIGHT_UNRESOLVED'

    END AS source_baby_key,


    CASE

      WHEN e.birth_weight_record_count = 1
        THEN 'EPUS_SINGLE_BIRTH_WEIGHT'

      ELSE
        'EPUS_MULTI_WEIGHT_UNRESOLVED'

    END AS source_baby_key_method,


    CAST(NULL AS DATE)
      AS source_delivery_date,

    CAST(NULL AS STRING)
      AS baby_name,

    CAST(NULL AS STRING)
      AS baby_sex,

    CAST(NULL AS TIME)
      AS birth_time,


    -- --------------------------------------------------------
    -- Only use scalar weight when EPUS has exactly one
    -- birth-weight record.
    -- --------------------------------------------------------
    CASE
      WHEN e.birth_weight_record_count = 1

      THEN COALESCE(
        e.birth_weight_min_gram,
        e.birth_weight_max_gram
      )

      ELSE NULL
    END AS birth_weight_gram,


    CAST(NULL AS FLOAT64)
      AS birth_length_cm,


    e.birth_weight_min_gram
      AS source_weight_min_gram,

    e.birth_weight_max_gram
      AS source_weight_max_gram,

    e.birth_weight_record_count
      AS source_weight_record_count,


    FALSE
      AS source_internal_conflict,


    (
      e.birth_weight_record_count > 1
    ) AS source_multi_weight_unresolved_flag,


    CASE
      WHEN e.birth_weight_record_count = 1
        THEN 'EPUS_SINGLE_WEIGHT_RECORD'

      ELSE 'EPUS_MULTIPLE_WEIGHT_RECORDS'
    END AS source_record_class,


    CASE
      WHEN e.birth_weight_record_count = 1
        THEN 'BABY_OBSERVATION'

      ELSE 'DELIVERY_WEIGHT_SUMMARY_UNRESOLVED'
    END AS observation_scope

  FROM epus_base e

  JOIN members m

    ON m.source_event_id
       = CONCAT(
           'EPUS|',
           e.epus_pregnancy_key
         )

  WHERE m.source_system = 'EPUS'
),


-- ============================================================================
-- 5. UNION ALL SOURCE OBSERVATIONS
-- ============================================================================

all_observations AS (

  SELECT * FROM tracker_mapped

  UNION ALL

  SELECT * FROM kobo_mapped

  UNION ALL

  SELECT * FROM simrs_final

  UNION ALL

  SELECT * FROM epus_mapped
),


-- ============================================================================
-- 6. WEIGHT QUALITY + OBSERVED BBLR CLASSIFICATION
--
-- 500-6000 g = plausible dashboard weight range
--
-- <500 or >6000 remains visible for QA but does not enter
-- the BBLR denominator.
-- ============================================================================

classified AS (
  SELECT
    *,

    CASE

      WHEN birth_weight_gram IS NULL
        THEN 'MISSING_OR_UNRESOLVED'

      WHEN birth_weight_gram < 500
        OR birth_weight_gram > 6000
        THEN 'NEEDS_VALIDATION'

      ELSE 'USABLE'

    END AS birth_weight_quality,


    CASE

      WHEN birth_weight_gram
        BETWEEN 500 AND 2499.999
        THEN TRUE

      WHEN birth_weight_gram
        BETWEEN 2500 AND 6000
        THEN FALSE

      ELSE NULL

    END AS observed_bblr_flag

  FROM all_observations
)


-- ============================================================================
-- FINAL
-- ============================================================================

SELECT *
FROM classified""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_birth_weight_source_audit
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_birth_weight_source_audit');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_birth_weight_source_audit';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_birth_weight_source_audit` AS SELECT ',
 projection, ' FROM (', r"""WITH

-- ============================================================================
-- CANONICAL SOURCE MEMBERS
-- ============================================================================

members AS (
  SELECT
    m.delivery_event_id,
    m.pregnancy_episode_id,

    b.source_system,
    b.source_subtype,
    b.source_event_id,
    b.source_record_id

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_member_map_v3` m

  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_dedup_base` b
    USING (source_event_id)

  WHERE b.source_system IN (
    'EPUS',
    'SIMRS',
    'KOBO_INC',
    'INC_REPORT_TRACKER'
  )
),


-- ============================================================================
-- 1. INC REPORT TRACKER / BIRTH FU
--
-- source_event_id in pipeline:
-- INC_REPORT|row_hash
-- ============================================================================

tracker_raw AS (
  SELECT
    CONCAT(
      'INC_REPORT|',
      row_hash
    ) AS source_event_id,

    SAFE_CAST(
      berat_badan_bayi_gram
      AS FLOAT64
    ) AS birth_weight_gram,

    jenis_kelamin_bayi,

    SAFE_CAST(
      panjang_bayi_cm
      AS FLOAT64
    ) AS birth_length_cm

  FROM
    `spheres-lombok-barat.birth_report_faskes.birth_fu_faskes`

  WHERE row_hash IS NOT NULL
),

tracker AS (
  SELECT
    m.delivery_event_id,

    COUNT(*) AS tracker_rows,

    COUNTIF(
      r.birth_weight_gram IS NOT NULL
    ) AS tracker_weight_records,

    ARRAY_AGG(
      DISTINCT r.birth_weight_gram
      IGNORE NULLS
      ORDER BY r.birth_weight_gram
    ) AS tracker_weights

  FROM members m

  JOIN tracker_raw r
    ON m.source_event_id = r.source_event_id

  WHERE m.source_system = 'INC_REPORT_TRACKER'

  GROUP BY m.delivery_event_id
),


-- ============================================================================
-- 2. KOBO INC
--
-- Kobo source_event_id:
-- KOBO_INC|case_id
-- fallback source_submission_id
-- ============================================================================

kobo_src AS (
  SELECT
    TO_JSON_STRING(t) AS j
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_kobo_inc_case_master` t
),

kobo_raw AS (
  SELECT
    CONCAT(
      'KOBO_INC|',
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.case_id'), ''),
        NULLIF(JSON_VALUE(j, '$.source_submission_id'), ''),
        CAST(FARM_FINGERPRINT(j) AS STRING)
      )
    ) AS source_event_id,

    COALESCE(
      SAFE_CAST(
        JSON_VALUE(
          j,
          '$.preferred_berat_badan_bayi_1_gram'
        )
        AS FLOAT64
      ),
      SAFE_CAST(
        JSON_VALUE(
          j,
          '$.berat_badan_bayi_1_gram'
        )
        AS FLOAT64
      )
    ) AS baby1_weight,

    SAFE_CAST(
      JSON_VALUE(
        j,
        '$.berat_badan_bayi_2_gram'
      )
      AS FLOAT64
    ) AS baby2_weight,

    SAFE_CAST(
      JSON_VALUE(
        j,
        '$.kobo_conflict_baby1_birth_weight'
      )
      AS BOOL
    ) AS baby1_weight_conflict

  FROM kobo_src
),

kobo_long AS (
  SELECT
    source_event_id,
    1 AS baby_number,
    baby1_weight AS birth_weight_gram,
    baby1_weight_conflict

  FROM kobo_raw

  UNION ALL

  SELECT
    source_event_id,
    2 AS baby_number,
    baby2_weight AS birth_weight_gram,
    FALSE AS baby1_weight_conflict

  FROM kobo_raw

  WHERE baby2_weight IS NOT NULL
),

kobo AS (
  SELECT
    m.delivery_event_id,

    COUNT(*) AS kobo_baby_rows,

    COUNTIF(
      k.birth_weight_gram IS NOT NULL
    ) AS kobo_weight_records,

    ARRAY_AGG(
      DISTINCT k.birth_weight_gram
      IGNORE NULLS
      ORDER BY k.birth_weight_gram
    ) AS kobo_weights,

    LOGICAL_OR(
      COALESCE(k.baby1_weight_conflict, FALSE)
    ) AS kobo_internal_weight_conflict

  FROM members m

  JOIN kobo_long k
    ON m.source_event_id = k.source_event_id

  WHERE m.source_system = 'KOBO_INC'

  GROUP BY m.delivery_event_id
),


-- ============================================================================
-- 3. SIMRS
-- ============================================================================

simrs_src AS (
  SELECT
    TO_JSON_STRING(t) AS j
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_simrs_patut_patuh_inc` t
),

simrs_raw AS (
  SELECT
    CONCAT(
      'SIMRS|',
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.source_record_id'), ''),
        NULLIF(JSON_VALUE(j, '$.dedup_key'), ''),
        NULLIF(JSON_VALUE(j, '$.source_row_hash'), ''),
        CAST(FARM_FINGERPRINT(j) AS STRING)
      )
    ) AS source_event_id,

    SAFE_CAST(
      JSON_VALUE(
        j,
        '$.berat_badan_lahir_numeric'
      )
      AS FLOAT64
    ) AS birth_weight_gram

  FROM simrs_src
),

simrs AS (
  SELECT
    m.delivery_event_id,

    COUNT(*) AS simrs_rows,

    COUNTIF(
      s.birth_weight_gram IS NOT NULL
    ) AS simrs_weight_records,

    ARRAY_AGG(
      DISTINCT s.birth_weight_gram
      IGNORE NULLS
      ORDER BY s.birth_weight_gram
    ) AS simrs_weights

  FROM members m

  JOIN simrs_raw s
    ON m.source_event_id = s.source_event_id

  WHERE m.source_system = 'SIMRS'

  GROUP BY m.delivery_event_id
),


-- ============================================================================
-- 4. EPUS
--
-- Current delivery pipeline uses EPUS_PREGNANCY_MASTER as the source event.
-- Therefore EPUS is currently delivery/pregnancy aggregated here rather
-- than individual baby rows.
-- ============================================================================

epus_src AS (
  SELECT
    TO_JSON_STRING(t) AS j
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_master` t
),

epus_raw AS (
  SELECT
    CONCAT(
      'EPUS|',
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.epus_pregnancy_key'), ''),
        NULLIF(JSON_VALUE(j, '$.pregnancy_key'), ''),
        CAST(FARM_FINGERPRINT(j) AS STRING)
      )
    ) AS source_event_id,

    SAFE_CAST(
      JSON_VALUE(
        j,
        '$.birth_weight_min_gram'
      )
      AS FLOAT64
    ) AS birth_weight_min_gram,

    SAFE_CAST(
      JSON_VALUE(
        j,
        '$.birth_weight_max_gram'
      )
      AS FLOAT64
    ) AS birth_weight_max_gram,

    SAFE_CAST(
      JSON_VALUE(
        j,
        '$.birth_weight_record_count'
      )
      AS INT64
    ) AS birth_weight_record_count,

    SAFE_CAST(
      JSON_VALUE(
        j,
        '$.bblr_baby_record_count'
      )
      AS INT64
    ) AS bblr_baby_record_count,

    SAFE_CAST(
      JSON_VALUE(
        j,
        '$.has_multiple_inc_baby_records'
      )
      AS BOOL
    ) AS has_multiple_inc_baby_records

  FROM epus_src
),

epus AS (
  SELECT
    m.delivery_event_id,

    MAX(
      e.birth_weight_record_count
    ) AS epus_weight_records,

    MIN(
      e.birth_weight_min_gram
    ) AS epus_weight_min,

    MAX(
      e.birth_weight_max_gram
    ) AS epus_weight_max,

    MAX(
      e.bblr_baby_record_count
    ) AS epus_bblr_baby_records,

    LOGICAL_OR(
      COALESCE(
        e.has_multiple_inc_baby_records,
        FALSE
      )
    ) AS epus_multiple_baby_records

  FROM members m

  JOIN epus_raw e
    ON m.source_event_id = e.source_event_id

  WHERE m.source_system = 'EPUS'

  GROUP BY m.delivery_event_id
),


-- ============================================================================
-- CANONICAL DELIVERY SET
-- ============================================================================

delivery AS (
  SELECT
    delivery_event_id,
    pregnancy_episode_id,
    delivery_date,
    delivery_source_combination,
    primary_delivery_source

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_v3`

  WHERE strict_birth_count_eligible_flag
)


-- ============================================================================
-- FINAL AUDIT
-- ============================================================================

SELECT
  d.delivery_event_id,
  d.pregnancy_episode_id,
  d.delivery_date,

  d.delivery_source_combination,
  d.primary_delivery_source,


  -- Birth FU
  COALESCE(
    t.tracker_weight_records,
    0
  ) AS tracker_weight_records,

  t.tracker_weights,


  -- Kobo INC
  COALESCE(
    k.kobo_weight_records,
    0
  ) AS kobo_weight_records,

  k.kobo_weights,

  COALESCE(
    k.kobo_internal_weight_conflict,
    FALSE
  ) AS kobo_internal_weight_conflict,


  -- SIMRS
  COALESCE(
    s.simrs_weight_records,
    0
  ) AS simrs_weight_records,

  s.simrs_weights,


  -- EPUS
  COALESCE(
    e.epus_weight_records,
    0
  ) AS epus_weight_records,

  e.epus_weight_min,
  e.epus_weight_max,
  e.epus_bblr_baby_records,
  e.epus_multiple_baby_records,


  -- ----------------------------------------------------------
  -- SOURCE COVERAGE
  -- ----------------------------------------------------------
  (
    CAST(
      COALESCE(t.tracker_weight_records, 0) > 0
      AS INT64
    )
    +
    CAST(
      COALESCE(k.kobo_weight_records, 0) > 0
      AS INT64
    )
    +
    CAST(
      COALESCE(s.simrs_weight_records, 0) > 0
      AS INT64
    )
    +
    CAST(
      COALESCE(e.epus_weight_records, 0) > 0
      AS INT64
    )
  ) AS weight_source_count,

  ARRAY_TO_STRING(
    ARRAY(
      SELECT src
      FROM UNNEST([
        IF(
          COALESCE(t.tracker_weight_records, 0) > 0,
          'INC_REPORT_TRACKER',
          NULL
        ),

        IF(
          COALESCE(k.kobo_weight_records, 0) > 0,
          'KOBO_INC',
          NULL
        ),

        IF(
          COALESCE(s.simrs_weight_records, 0) > 0,
          'SIMRS',
          NULL
        ),

        IF(
          COALESCE(e.epus_weight_records, 0) > 0,
          'EPUS',
          NULL
        )
      ]) src

      WHERE src IS NOT NULL
    ),
    ' + '
  ) AS weight_source_combination

FROM delivery d

LEFT JOIN tracker t
  USING (delivery_event_id)

LEFT JOIN kobo k
  USING (delivery_event_id)

LEFT JOIN simrs s
  USING (delivery_event_id)

LEFT JOIN epus e
  USING (delivery_event_id)""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_delivery_event_master_validated
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_delivery_event_master_validated');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_delivery_event_master_validated';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_delivery_event_master_validated` AS SELECT ',
 projection, ' FROM (', r"""WITH classified AS (
  SELECT
    d.*,

    -- ============================================================
    -- VALID KNOWN BIRTH
    --
    -- Requirements:
    -- 1. technically accepted canonical delivery event
    -- 2. delivery date exists
    -- 3. delivery is not in the future
    -- 4. at least one basic maternal identifier exists:
    --      NIK OR maternal name
    -- ============================================================
    (
      d.strict_birth_count_eligible_flag

      AND d.delivery_date IS NOT NULL

      AND d.delivery_date <= CURRENT_DATE('Asia/Makassar')

      AND (
        d.nik_clean IS NOT NULL
        OR NULLIF(TRIM(d.nama_ibu), '') IS NOT NULL
      )
    ) AS valid_known_birth_flag,


    -- ============================================================
    -- MUTU / EXCLUSION REASON
    -- Mutually exclusive classification
    -- ============================================================
    CASE
      WHEN NOT d.strict_birth_count_eligible_flag
        THEN 'EXCLUDED_TECHNICAL_EVENT'

      WHEN d.delivery_date IS NULL
        THEN 'EXCLUDED_NO_DELIVERY_DATE'

      WHEN d.delivery_date > CURRENT_DATE('Asia/Makassar')
        THEN 'EXCLUDED_FUTURE_DELIVERY_DATE'

      WHEN d.nik_clean IS NULL
       AND NULLIF(TRIM(d.nama_ibu), '') IS NULL
        THEN 'EXCLUDED_NO_MATERNAL_IDENTITY'

      ELSE 'VALID_KNOWN_BIRTH'
    END AS birth_validity_status

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_v3` d
)

SELECT
  *,

  -- ============================================================
  -- REPORTING LINKAGE FLAGS
  -- ============================================================

  (
    valid_known_birth_flag
    AND anc_link_status IN (
      'MATCHED_SIGIZI_EPUS',
      'MATCHED_SIGIZI_ONLY',
      'MATCHED_EPUS_ONLY',
      'MATCHED_ANC_OTHER'
    )
  ) AS successful_anc_link_flag,


  (
    valid_known_birth_flag
    AND anc_link_status = 'NO_ANC_MATCH'
  ) AS no_anc_match_valid_birth_flag,


  (
    valid_known_birth_flag
    AND anc_link_status = 'AMBIGUOUS_ANC_MATCH'
  ) AS ambiguous_anc_link_valid_birth_flag,


  (
    valid_known_birth_flag
    AND anc_link_status = 'ANC_LINK_DATE_IMPLAUSIBLE'
  ) AS date_implausible_anc_link_valid_birth_flag,


  (
    valid_known_birth_flag
    AND anc_link_status NOT IN (
      'MATCHED_SIGIZI_EPUS',
      'MATCHED_SIGIZI_ONLY',
      'MATCHED_EPUS_ONLY',
      'MATCHED_ANC_OTHER'
    )
  ) AS not_successfully_linked_flag,


  -- ============================================================
  -- SIMPLE REPORTING CATEGORY
  -- ============================================================
  CASE
    WHEN NOT valid_known_birth_flag
      THEN 'EXCLUDED_DATA_QUALITY'

    WHEN anc_link_status IN (
      'MATCHED_SIGIZI_EPUS',
      'MATCHED_SIGIZI_ONLY',
      'MATCHED_EPUS_ONLY',
      'MATCHED_ANC_OTHER'
    )
      THEN 'LINKED_TO_PREGNANCY'

    WHEN anc_link_status = 'NO_ANC_MATCH'
      THEN 'NO_PREGNANCY_MATCH'

    WHEN anc_link_status = 'AMBIGUOUS_ANC_MATCH'
      THEN 'AMBIGUOUS_LINK'

    WHEN anc_link_status = 'ANC_LINK_DATE_IMPLAUSIBLE'
      THEN 'DATE_IMPLAUSIBLE_LINK'

    ELSE 'OTHER_LINKAGE_STATUS'
  END AS pregnancy_linkage_reporting_status

FROM classified""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_delivery_source_first_report_native
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_delivery_source_first_report_native');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_delivery_source_first_report_native';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_delivery_source_first_report_native` AS SELECT ',
 projection, ' FROM (', r"""WITH

-- =============================================================================
-- 0. CANONICAL DELIVERY MEMBERS
-- =============================================================================

canonical_members AS (

  SELECT
    d.delivery_event_id,
    d.pregnancy_episode_id,
    d.delivery_date,

    b.source_system,
    b.source_subtype,
    b.source_event_id,
    b.source_record_id

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_v3` d

  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_member_map_v3` m
      ON d.delivery_event_id = m.delivery_event_id

  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_dedup_base` b
      ON m.source_event_id = b.source_event_id

  WHERE
    d.strict_birth_count_eligible_flag

    AND d.delivery_date IS NOT NULL
),


-- =============================================================================
-- =============================================================================
-- 1. SIGIZI
-- =============================================================================
-- =============================================================================

sigizi_rows AS (

  SELECT
    TO_JSON_STRING(t) AS row_json

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_source_records` t
),


sigizi_prepared AS (

  SELECT

    -- -------------------------------------------------------------------------
    -- SOURCE TABLE
    -- -------------------------------------------------------------------------

    COALESCE(

      NULLIF(
        JSON_VALUE(
          row_json,
          '$.source_table'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          row_json,
          '$.data_source'
        ),
        ''
      ),

      'UNKNOWN'

    ) AS source_table,


    -- -------------------------------------------------------------------------
    -- SOURCE RECORD ID
    -- -------------------------------------------------------------------------

    COALESCE(

      NULLIF(
        JSON_VALUE(
          row_json,
          '$.source_record_id'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          row_json,
          '$.dedup_key'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          row_json,
          '$.uuid'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          row_json,
          '$.hash_code'
        ),
        ''
      ),

      CAST(
        FARM_FINGERPRINT(row_json)
        AS STRING
      )

    ) AS source_record_id,


    -- -------------------------------------------------------------------------
    -- ORIGINAL SOURCE JSON
    -- -------------------------------------------------------------------------

    COALESCE(

      NULLIF(
        JSON_VALUE(
          row_json,
          '$.source_json'
        ),
        ''
      ),

      row_json

    ) AS original_source_json,


    row_json

  FROM sigizi_rows
),


sigizi_metadata_raw AS (

  SELECT

    'SIGIZI'
      AS source_system,


    CONCAT(
      'SIGIZI|',
      source_table,
      '|',
      source_record_id
    ) AS source_event_id,


    -- -------------------------------------------------------------------------
    -- FILE NAME
    -- -------------------------------------------------------------------------

    COALESCE(

      NULLIF(
        JSON_VALUE(
          row_json,
          '$.file_name'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          row_json,
          '$.source_file_name'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          original_source_json,
          '$.file_name'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          original_source_json,
          '$.source_file_name'
        ),
        ''
      )

    ) AS source_file_name,


    -- -------------------------------------------------------------------------
    -- FILE DATE FALLBACK
    -- -------------------------------------------------------------------------

    COALESCE(

      SAFE_CAST(
        JSON_VALUE(
          row_json,
          '$.file_date_parsed'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          original_source_json,
          '$.file_date_parsed'
        )
        AS DATE
      ),

      SAFE.PARSE_DATE(

        '%Y-%m-%d',

        REGEXP_EXTRACT(

          COALESCE(

            NULLIF(
              JSON_VALUE(
                row_json,
                '$.file_date'
              ),
              ''
            ),

            NULLIF(
              JSON_VALUE(
                original_source_json,
                '$.file_date'
              ),
              ''
            )

          ),

          r'(\d{4}-\d{2}-\d{2})'
        )
      )

    ) AS fallback_file_date,


    -- -------------------------------------------------------------------------
    -- INGESTION FALLBACK
    -- -------------------------------------------------------------------------

    COALESCE(

      SAFE_CAST(
        JSON_VALUE(
          row_json,
          '$.ingestion_timestamp_parsed'
        )
        AS TIMESTAMP
      ),

      SAFE_CAST(
        JSON_VALUE(
          original_source_json,
          '$.ingestion_timestamp_parsed'
        )
        AS TIMESTAMP
      ),

      SAFE_CAST(
        JSON_VALUE(
          row_json,
          '$.ingestion_timestamp'
        )
        AS TIMESTAMP
      ),

      SAFE_CAST(
        JSON_VALUE(
          original_source_json,
          '$.ingestion_timestamp'
        )
        AS TIMESTAMP
      ),

      SAFE_CAST(
        JSON_VALUE(
          row_json,
          '$.loaded_at'
        )
        AS TIMESTAMP
      ),

      SAFE_CAST(
        JSON_VALUE(
          original_source_json,
          '$.loaded_at'
        )
        AS TIMESTAMP
      )

    ) AS ingestion_timestamp

  FROM sigizi_prepared
),


-- =============================================================================
-- SIGIZI FILE-NAME PARSER
--
-- FORMAT A
--   2026-02-08 18:58:02.805
--
-- FORMAT B
--   2026-07-20 13.35.50
--
-- FORMAT C
--   20260720-133252
-- =============================================================================

sigizi_parsed AS (

  SELECT
    *,


    SAFE.PARSE_DATETIME(

      '%Y-%m-%d %H:%M:%E*S',

      REGEXP_EXTRACT(
        source_file_name,
        r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
      )

    ) AS filename_datetime_colon,


    SAFE.PARSE_DATETIME(

      '%Y-%m-%d %H.%M.%E*S',

      REGEXP_EXTRACT(
        source_file_name,
        r'(\d{4}-\d{2}-\d{2}\s+\d{2}\.\d{2}\.\d{2}(?:\.\d+)?)'
      )

    ) AS filename_datetime_dot,


    SAFE.PARSE_DATETIME(

      '%Y%m%d-%H%M%S',

      REGEXP_EXTRACT(
        source_file_name,
        r'(\d{8}-\d{6})'
      )

    ) AS filename_datetime_compact

  FROM sigizi_metadata_raw
),


sigizi_meta AS (

  SELECT
    source_system,
    source_event_id,
    source_file_name,


    COALESCE(

      TIMESTAMP(
        filename_datetime_colon,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        filename_datetime_dot,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        filename_datetime_compact,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        fallback_file_date,
        'Asia/Makassar'
      ),

      ingestion_timestamp

    ) AS report_timestamp,


    COALESCE(

      DATE(
        filename_datetime_colon
      ),

      DATE(
        filename_datetime_dot
      ),

      DATE(
        filename_datetime_compact
      ),

      fallback_file_date,

      DATE(
        ingestion_timestamp,
        'Asia/Makassar'
      )

    ) AS report_date,


    CASE

      WHEN filename_datetime_colon IS NOT NULL
        THEN 'FILE_NAME_TIMESTAMP'

      WHEN filename_datetime_dot IS NOT NULL
        THEN 'FILE_NAME_TIMESTAMP'

      WHEN filename_datetime_compact IS NOT NULL
        THEN 'FILE_NAME_COMPACT_TIMESTAMP'

      WHEN fallback_file_date IS NOT NULL
        THEN 'FILE_DATE'

      WHEN ingestion_timestamp IS NOT NULL
        THEN 'INGESTION_FALLBACK'

      ELSE 'MISSING'

    END AS report_timestamp_source,


    CASE

      WHEN filename_datetime_colon IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN filename_datetime_dot IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN filename_datetime_compact IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN fallback_file_date IS NOT NULL
        THEN 'DATE_ONLY'

      WHEN ingestion_timestamp IS NOT NULL
        THEN 'FALLBACK_TIMESTAMP'

      ELSE 'MISSING'

    END AS report_timestamp_quality

  FROM sigizi_parsed
),


-- =============================================================================
-- =============================================================================
-- 2. EPUS
-- =============================================================================
-- =============================================================================

epus_same_delivery AS (

  SELECT
    p.epus_pregnancy_key,

    r.file_name,
    r.file_date_parsed,
    r.ingestion_timestamp_parsed

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_master` p

  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_mother_records` r

    ON p.epus_mother_key
       = r.epus_mother_key

    AND p.delivery_date
        = r.delivery_date

  WHERE
    p.epus_pregnancy_key IS NOT NULL

    AND p.delivery_date IS NOT NULL

    AND r.delivery_date IS NOT NULL
),


epus_direct_delivery AS (

  SELECT
    p.epus_pregnancy_key,

    r.file_name,
    r.file_date_parsed,
    r.ingestion_timestamp_parsed

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_master` p

  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_mother_records` r

    ON p.delivery_source_record_key
       = r.epus_source_record_key

  WHERE
    p.epus_pregnancy_key IS NOT NULL

    AND p.delivery_date IS NOT NULL
),


epus_candidates AS (

  SELECT *
  FROM epus_same_delivery


  UNION DISTINCT


  SELECT *
  FROM epus_direct_delivery
),


epus_parsed AS (

  SELECT

    'EPUS'
      AS source_system,


    CONCAT(
      'EPUS|',
      epus_pregnancy_key
    ) AS source_event_id,


    file_name
      AS source_file_name,


    SAFE.PARSE_DATETIME(

      '%Y-%m-%d %H:%M:%E*S',

      REGEXP_EXTRACT(
        file_name,
        r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
      )

    ) AS filename_datetime_colon,


    SAFE.PARSE_DATETIME(

      '%Y-%m-%d %H.%M.%E*S',

      REGEXP_EXTRACT(
        file_name,
        r'(\d{4}-\d{2}-\d{2}\s+\d{2}\.\d{2}\.\d{2}(?:\.\d+)?)'
      )

    ) AS filename_datetime_dot,


    SAFE.PARSE_DATETIME(

      '%Y%m%d-%H%M%S',

      REGEXP_EXTRACT(
        file_name,
        r'(\d{8}-\d{6})'
      )

    ) AS filename_datetime_compact,


    file_date_parsed
      AS fallback_file_date,


    ingestion_timestamp_parsed
      AS ingestion_timestamp

  FROM epus_candidates
),


epus_meta AS (

  SELECT
    source_system,
    source_event_id,
    source_file_name,


    COALESCE(

      TIMESTAMP(
        filename_datetime_colon,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        filename_datetime_dot,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        filename_datetime_compact,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        fallback_file_date,
        'Asia/Makassar'
      ),

      ingestion_timestamp

    ) AS report_timestamp,


    COALESCE(

      DATE(
        filename_datetime_colon
      ),

      DATE(
        filename_datetime_dot
      ),

      DATE(
        filename_datetime_compact
      ),

      fallback_file_date,

      DATE(
        ingestion_timestamp,
        'Asia/Makassar'
      )

    ) AS report_date,


    CASE

      WHEN filename_datetime_colon IS NOT NULL
        THEN 'FILE_NAME_TIMESTAMP'

      WHEN filename_datetime_dot IS NOT NULL
        THEN 'FILE_NAME_TIMESTAMP'

      WHEN filename_datetime_compact IS NOT NULL
        THEN 'FILE_NAME_COMPACT_TIMESTAMP'

      WHEN fallback_file_date IS NOT NULL
        THEN 'FILE_DATE'

      WHEN ingestion_timestamp IS NOT NULL
        THEN 'INGESTION_FALLBACK'

      ELSE 'MISSING'

    END AS report_timestamp_source,


    CASE

      WHEN filename_datetime_colon IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN filename_datetime_dot IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN filename_datetime_compact IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN fallback_file_date IS NOT NULL
        THEN 'DATE_ONLY'

      WHEN ingestion_timestamp IS NOT NULL
        THEN 'FALLBACK_TIMESTAMP'

      ELSE 'MISSING'

    END AS report_timestamp_quality

  FROM epus_parsed
),


-- =============================================================================
-- =============================================================================
-- 3. SIMRS
-- =============================================================================
-- =============================================================================

simrs_json AS (

  SELECT
    TO_JSON_STRING(t) AS j

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_simrs_patut_patuh_inc` t
),


simrs_raw AS (

  SELECT

    'SIMRS'
      AS source_system,


    CONCAT(

      'SIMRS|',

      COALESCE(

        NULLIF(
          JSON_VALUE(
            j,
            '$.source_record_id'
          ),
          ''
        ),

        NULLIF(
          JSON_VALUE(
            j,
            '$.dedup_key'
          ),
          ''
        ),

        NULLIF(
          JSON_VALUE(
            j,
            '$.source_row_hash'
          ),
          ''
        ),

        CAST(
          FARM_FINGERPRINT(j)
          AS STRING
        )

      )

    ) AS source_event_id,


    NULLIF(
      JSON_VALUE(
        j,
        '$.file_name'
      ),
      ''
    ) AS source_file_name,


    SAFE_CAST(
      JSON_VALUE(
        j,
        '$.reference_upload_date'
      )
      AS DATE
    ) AS reference_upload_date,


    COALESCE(

      SAFE_CAST(
        JSON_VALUE(
          j,
          '$.file_date_parsed'
        )
        AS DATE
      ),

      SAFE.PARSE_DATE(

        '%Y-%m-%d',

        REGEXP_EXTRACT(
          JSON_VALUE(
            j,
            '$.file_date'
          ),
          r'(\d{4}-\d{2}-\d{2})'
        )
      )

    ) AS fallback_file_date,


    COALESCE(

      SAFE_CAST(
        JSON_VALUE(
          j,
          '$.ingestion_ts'
        )
        AS TIMESTAMP
      ),

      SAFE_CAST(
        JSON_VALUE(
          j,
          '$.ingestion_timestamp'
        )
        AS TIMESTAMP
      )

    ) AS ingestion_timestamp

  FROM simrs_json
),


simrs_parsed AS (

  SELECT
    *,


    SAFE.PARSE_DATETIME(

      '%Y-%m-%d %H:%M:%E*S',

      REGEXP_EXTRACT(
        source_file_name,
        r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
      )

    ) AS filename_datetime_colon,


    SAFE.PARSE_DATETIME(

      '%Y-%m-%d %H.%M.%E*S',

      REGEXP_EXTRACT(
        source_file_name,
        r'(\d{4}-\d{2}-\d{2}\s+\d{2}\.\d{2}\.\d{2}(?:\.\d+)?)'
      )

    ) AS filename_datetime_dot,


    SAFE.PARSE_DATETIME(

      '%Y%m%d-%H%M%S',

      REGEXP_EXTRACT(
        source_file_name,
        r'(\d{8}-\d{6})'
      )

    ) AS filename_datetime_compact

  FROM simrs_raw
),


simrs_meta AS (

  SELECT
    source_system,
    source_event_id,
    source_file_name,


    COALESCE(

      TIMESTAMP(
        filename_datetime_colon,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        filename_datetime_dot,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        filename_datetime_compact,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        reference_upload_date,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        fallback_file_date,
        'Asia/Makassar'
      ),

      ingestion_timestamp

    ) AS report_timestamp,


    COALESCE(

      DATE(
        filename_datetime_colon
      ),

      DATE(
        filename_datetime_dot
      ),

      DATE(
        filename_datetime_compact
      ),

      reference_upload_date,

      fallback_file_date,

      DATE(
        ingestion_timestamp,
        'Asia/Makassar'
      )

    ) AS report_date,


    CASE

      WHEN filename_datetime_colon IS NOT NULL
        THEN 'FILE_NAME_TIMESTAMP'

      WHEN filename_datetime_dot IS NOT NULL
        THEN 'FILE_NAME_TIMESTAMP'

      WHEN filename_datetime_compact IS NOT NULL
        THEN 'FILE_NAME_COMPACT_TIMESTAMP'

      WHEN reference_upload_date IS NOT NULL
        THEN 'REFERENCE_UPLOAD_DATE'

      WHEN fallback_file_date IS NOT NULL
        THEN 'FILE_DATE'

      WHEN ingestion_timestamp IS NOT NULL
        THEN 'INGESTION_FALLBACK'

      ELSE 'MISSING'

    END AS report_timestamp_source,


    CASE

      WHEN filename_datetime_colon IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN filename_datetime_dot IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN filename_datetime_compact IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN reference_upload_date IS NOT NULL
        THEN 'DATE_ONLY'

      WHEN fallback_file_date IS NOT NULL
        THEN 'DATE_ONLY'

      WHEN ingestion_timestamp IS NOT NULL
        THEN 'FALLBACK_TIMESTAMP'

      ELSE 'MISSING'

    END AS report_timestamp_quality

  FROM simrs_parsed
),


-- =============================================================================
-- =============================================================================
-- 4. KOBO INC
-- =============================================================================
-- =============================================================================

kobo_case_master_json AS (

  SELECT
    TO_JSON_STRING(t) AS j

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_kobo_inc_case_master` t
),


kobo_case_keys AS (

  SELECT

    CONCAT(

      'KOBO_INC|',

      COALESCE(

        NULLIF(
          JSON_VALUE(
            j,
            '$.case_id'
          ),
          ''
        ),

        NULLIF(
          JSON_VALUE(
            j,
            '$.source_submission_id'
          ),
          ''
        ),

        CAST(
          FARM_FINGERPRINT(j)
          AS STRING
        )

      )

    ) AS source_event_id,


    NULLIF(
      JSON_VALUE(
        j,
        '$.case_id'
      ),
      ''
    ) AS case_id,


    NULLIF(
      JSON_VALUE(
        j,
        '$.source_submission_id'
      ),
      ''
    ) AS source_submission_id

  FROM kobo_case_master_json
),


kobo_raw_json AS (

  SELECT
    TO_JSON_STRING(t) AS j

  FROM
    `spheres-lombok-barat.data_kobo_form.e-form_pencatatan_pelayanan_intranatal_care` t
),


kobo_raw_metadata AS (

  SELECT

    NULLIF(
      JSON_VALUE(
        j,
        '$.case_id'
      ),
      ''
    ) AS case_id,


    COALESCE(

      NULLIF(
        JSON_VALUE(
          j,
          '$.source_submission_id'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          j,
          '$._uuid'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          j,
          '$._id'
        ),
        ''
      )

    ) AS source_submission_id,


    NULLIF(
      TRIM(
        JSON_VALUE(
          j,
          '$.end'
        )
      ),
      ''
    ) AS end_string,


    NULLIF(
      TRIM(
        JSON_VALUE(
          j,
          '$.start'
        )
      ),
      ''
    ) AS start_string

  FROM kobo_raw_json
),


kobo_joined AS (

  SELECT

    'KOBO_INC'
      AS source_system,


    c.source_event_id,


    CAST(NULL AS STRING)
      AS source_file_name,


    r.end_string,

    r.start_string

  FROM kobo_case_keys c

  LEFT JOIN kobo_raw_metadata r

    ON (

      c.case_id IS NOT NULL

      AND r.case_id IS NOT NULL

      AND c.case_id = r.case_id

    )

    OR (

      c.case_id IS NULL

      AND c.source_submission_id IS NOT NULL

      AND r.source_submission_id IS NOT NULL

      AND c.source_submission_id
          = r.source_submission_id

    )
),


kobo_parsed AS (

  SELECT
    source_system,
    source_event_id,
    source_file_name,


    CASE

      WHEN end_string IS NULL
        THEN NULL


      WHEN REGEXP_CONTAINS(
        end_string,
        r'(?:Z|[+-]\d{2}:\d{2})$'
      )
        THEN SAFE_CAST(
          end_string
          AS TIMESTAMP
        )


      ELSE TIMESTAMP(

        SAFE_CAST(
          end_string
          AS DATETIME
        ),

        'Asia/Makassar'
      )

    END AS end_timestamp,


    CASE

      WHEN start_string IS NULL
        THEN NULL


      WHEN REGEXP_CONTAINS(
        start_string,
        r'(?:Z|[+-]\d{2}:\d{2})$'
      )
        THEN SAFE_CAST(
          start_string
          AS TIMESTAMP
        )


      ELSE TIMESTAMP(

        SAFE_CAST(
          start_string
          AS DATETIME
        ),

        'Asia/Makassar'
      )

    END AS start_timestamp

  FROM kobo_joined
),


kobo_meta AS (

  SELECT
    source_system,
    source_event_id,
    source_file_name,


    COALESCE(
      end_timestamp,
      start_timestamp
    ) AS report_timestamp,


    DATE(
      COALESCE(
        end_timestamp,
        start_timestamp
      ),
      'Asia/Makassar'
    ) AS report_date,


    CASE

      WHEN end_timestamp IS NOT NULL
        THEN 'KOBO_END_TIMESTAMP'

      WHEN start_timestamp IS NOT NULL
        THEN 'KOBO_START_FALLBACK'

      ELSE 'MISSING'

    END AS report_timestamp_source,


    CASE

      WHEN end_timestamp IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN start_timestamp IS NOT NULL
        THEN 'FALLBACK_TIMESTAMP'

      ELSE 'MISSING'

    END AS report_timestamp_quality

  FROM kobo_parsed
),


-- =============================================================================
-- =============================================================================
-- 5. NEONATAL OUTCOME
-- =============================================================================
-- =============================================================================

neonatal_json AS (

  SELECT
    TO_JSON_STRING(t) AS j

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_kobo_neonatus_outcome_v2_baby` t
),


neonatal_raw AS (

  SELECT

    'NEONATAL_OUTCOME'
      AS source_system,


    CONCAT(

      'NEONATAL|',

      COALESCE(

        NULLIF(
          JSON_VALUE(
            j,
            '$.source_submission_id'
          ),
          ''
        ),

        CAST(
          FARM_FINGERPRINT(j)
          AS STRING
        )

      ),

      '|',

      COALESCE(

        NULLIF(
          JSON_VALUE(
            j,
            '$.baby_number'
          ),
          ''
        ),

        '1'

      )

    ) AS source_event_id,


    CAST(NULL AS STRING)
      AS source_file_name,


    NULLIF(
      TRIM(
        JSON_VALUE(
          j,
          '$.end_time'
        )
      ),
      ''
    ) AS end_string,


    NULLIF(
      TRIM(
        JSON_VALUE(
          j,
          '$.start_time'
        )
      ),
      ''
    ) AS start_string

  FROM neonatal_json
),


neonatal_parsed AS (

  SELECT
    source_system,
    source_event_id,
    source_file_name,


    CASE

      WHEN end_string IS NULL
        THEN NULL


      WHEN REGEXP_CONTAINS(
        end_string,
        r'(?:Z|[+-]\d{2}:\d{2})$'
      )
        THEN SAFE_CAST(
          end_string
          AS TIMESTAMP
        )


      ELSE TIMESTAMP(

        SAFE_CAST(
          end_string
          AS DATETIME
        ),

        'Asia/Makassar'
      )

    END AS end_timestamp,


    CASE

      WHEN start_string IS NULL
        THEN NULL


      WHEN REGEXP_CONTAINS(
        start_string,
        r'(?:Z|[+-]\d{2}:\d{2})$'
      )
        THEN SAFE_CAST(
          start_string
          AS TIMESTAMP
        )


      ELSE TIMESTAMP(

        SAFE_CAST(
          start_string
          AS DATETIME
        ),

        'Asia/Makassar'
      )

    END AS start_timestamp

  FROM neonatal_raw
),


neonatal_meta AS (

  SELECT
    source_system,
    source_event_id,
    source_file_name,


    COALESCE(
      end_timestamp,
      start_timestamp
    ) AS report_timestamp,


    DATE(
      COALESCE(
        end_timestamp,
        start_timestamp
      ),
      'Asia/Makassar'
    ) AS report_date,


    CASE

      WHEN end_timestamp IS NOT NULL
        THEN 'NEONATAL_END_TIMESTAMP'

      WHEN start_timestamp IS NOT NULL
        THEN 'NEONATAL_START_FALLBACK'

      ELSE 'MISSING'

    END AS report_timestamp_source,


    CASE

      WHEN end_timestamp IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN start_timestamp IS NOT NULL
        THEN 'FALLBACK_TIMESTAMP'

      ELSE 'MISSING'

    END AS report_timestamp_quality

  FROM neonatal_parsed
),


-- =============================================================================
-- =============================================================================
-- 6. BIRTH REPORT FASKES
-- =============================================================================
-- =============================================================================

tracker_json AS (

  SELECT
    TO_JSON_STRING(t) AS j

  FROM
    `spheres-lombok-barat.birth_report_faskes.v_inc_report_tracker` t
),


tracker_meta AS (

  SELECT

    'INC_REPORT_TRACKER'
      AS source_system,


    CONCAT(

      'INC_REPORT|',

      COALESCE(

        NULLIF(
          JSON_VALUE(
            j,
            '$.row_hash'
          ),
          ''
        ),

        CAST(
          FARM_FINGERPRINT(j)
          AS STRING
        )

      )

    ) AS source_event_id,


    CAST(NULL AS STRING)
      AS source_file_name,


    TIMESTAMP(

      SAFE_CAST(
        JSON_VALUE(
          j,
          '$.date'
        )
        AS DATE
      ),

      'Asia/Makassar'

    ) AS report_timestamp,


    SAFE_CAST(
      JSON_VALUE(
        j,
        '$.date'
      )
      AS DATE
    ) AS report_date,


    CASE

      WHEN SAFE_CAST(
        JSON_VALUE(
          j,
          '$.date'
        )
        AS DATE
      ) IS NOT NULL

        THEN 'BIRTH_REPORT_DATE'

      ELSE 'MISSING'

    END AS report_timestamp_source,


    CASE

      WHEN SAFE_CAST(
        JSON_VALUE(
          j,
          '$.date'
        )
        AS DATE
      ) IS NOT NULL

        THEN 'DATE_ONLY'

      ELSE 'MISSING'

    END AS report_timestamp_quality

  FROM tracker_json
),


-- =============================================================================
-- =============================================================================
-- 7. ALL SOURCE METADATA
-- =============================================================================
-- =============================================================================

source_metadata AS (

  SELECT *
  FROM sigizi_meta


  UNION ALL


  SELECT *
  FROM epus_meta


  UNION ALL


  SELECT *
  FROM simrs_meta


  UNION ALL


  SELECT *
  FROM kobo_meta


  UNION ALL


  SELECT *
  FROM neonatal_meta


  UNION ALL


  SELECT *
  FROM tracker_meta
),


-- =============================================================================
-- 8. ATTACH NATIVE REPORTING METADATA TO CANONICAL DELIVERY MEMBERS
-- =============================================================================

member_reporting AS (

  SELECT

    c.delivery_event_id,

    c.pregnancy_episode_id,

    c.delivery_date,

    c.source_system,

    c.source_subtype,

    c.source_event_id,

    c.source_record_id,


    s.source_file_name,

    s.report_timestamp,

    s.report_date,

    s.report_timestamp_source,

    s.report_timestamp_quality

  FROM canonical_members c

  LEFT JOIN source_metadata s

    ON c.source_system
       = s.source_system

   AND c.source_event_id
       = s.source_event_id
),


-- =============================================================================
-- 9. EARLIEST RAW / VALID / STRICT-NATIVE REPORT
--    PER DELIVERY x SOURCE
-- =============================================================================

source_grouped AS (

  SELECT

    delivery_event_id,

    pregnancy_episode_id,

    delivery_date,

    source_system,


    COUNT(
      DISTINCT source_event_id
    ) AS source_event_count,


    COUNT(
      DISTINCT IF(
        report_date IS NOT NULL,
        source_event_id,
        NULL
      )
    ) AS native_metadata_matched_event_count,


    COUNTIF(
      report_date IS NOT NULL
    ) AS native_report_candidate_count,


    COUNT(
      DISTINCT source_file_name
    ) AS source_file_count,


    -- =========================================================================
    -- FIRST RAW REPORT
    -- =========================================================================

    ARRAY_AGG(

      IF(

        report_date IS NOT NULL,

        STRUCT(

          report_timestamp
            AS report_timestamp,

          report_date
            AS report_date,

          report_timestamp_source
            AS timestamp_source,

          report_timestamp_quality
            AS timestamp_quality,

          source_file_name
            AS source_file_name

        ),

        NULL

      )

      IGNORE NULLS

      ORDER BY
        report_date,
        report_timestamp,
        source_file_name

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS first_raw_pick,


    -- =========================================================================
    -- FIRST VALID REPORT
    --
    -- May include ingestion fallback.
    -- =========================================================================

    ARRAY_AGG(

      IF(

        report_date IS NOT NULL

        AND report_date >= delivery_date,

        STRUCT(

          report_timestamp
            AS report_timestamp,

          report_date
            AS report_date,

          report_timestamp_source
            AS timestamp_source,

          report_timestamp_quality
            AS timestamp_quality,

          source_file_name
            AS source_file_name

        ),

        NULL

      )

      IGNORE NULLS

      ORDER BY
        report_date,
        report_timestamp,
        source_file_name

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS first_valid_pick,


    -- =========================================================================
    -- FIRST STRICT-NATIVE VALID REPORT
    --
    -- Explicitly excludes INGESTION_FALLBACK.
    --
    -- This is the preferred reporting evidence for headline timeliness.
    -- =========================================================================

    ARRAY_AGG(

      IF(

        report_date IS NOT NULL

        AND report_date >= delivery_date

        AND COALESCE(
          report_timestamp_source,
          ''
        ) != 'INGESTION_FALLBACK',

        STRUCT(

          report_timestamp
            AS report_timestamp,

          report_date
            AS report_date,

          report_timestamp_source
            AS timestamp_source,

          report_timestamp_quality
            AS timestamp_quality,

          source_file_name
            AS source_file_name

        ),

        NULL

      )

      IGNORE NULLS

      ORDER BY
        report_date,
        report_timestamp,
        source_file_name

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS first_strict_native_pick


  FROM member_reporting


  GROUP BY

    delivery_event_id,

    pregnancy_episode_id,

    delivery_date,

    source_system
),


-- =============================================================================
-- =============================================================================
-- 10. INDIVIDUAL SOURCE FINAL
-- =============================================================================
-- =============================================================================

source_final AS (

  SELECT

    delivery_event_id,

    pregnancy_episode_id,

    delivery_date,

    source_system,


    CASE source_system

      WHEN 'SIGIZI'
        THEN 'SIGIZI'

      WHEN 'EPUS'
        THEN 'ePuskesmas'

      WHEN 'SIMRS'
        THEN 'SIMRS'

      WHEN 'KOBO_INC'
        THEN 'Kobo INC'

      WHEN 'NEONATAL_OUTCOME'
        THEN 'Neonatal Outcome'

      WHEN 'INC_REPORT_TRACKER'
        THEN 'Birth Report Faskes'

      ELSE source_system

    END AS source_system_display,


    CASE source_system

      WHEN 'INC_REPORT_TRACKER'
        THEN 1

      WHEN 'SIGIZI'
        THEN 2

      WHEN 'EPUS'
        THEN 3

      WHEN 'SIMRS'
        THEN 4

      WHEN 'KOBO_INC'
        THEN 5

      WHEN 'NEONATAL_OUTCOME'
        THEN 6

      ELSE 99

    END AS source_order,


    1 AS source_system_count,


    source_event_count,

    native_metadata_matched_event_count,

    native_report_candidate_count,

    source_file_count,


    -- =========================================================================
    -- FIRST RAW REPORT
    -- =========================================================================

    source_system
      AS first_report_source_system,


    first_raw_pick.report_timestamp
      AS first_report_timestamp,


    first_raw_pick.report_date
      AS first_report_date,


    first_raw_pick.timestamp_source
      AS first_report_timestamp_source,


    first_raw_pick.timestamp_quality
      AS first_report_timestamp_quality,


    first_raw_pick.source_file_name
      AS first_report_source_file_name,


    -- =========================================================================
    -- FIRST VALID REPORT
    -- =========================================================================

    source_system
      AS first_valid_report_source_system,


    first_valid_pick.report_timestamp
      AS first_valid_report_timestamp,


    first_valid_pick.report_date
      AS first_valid_report_date,


    first_valid_pick.timestamp_source
      AS first_valid_report_timestamp_source,


    first_valid_pick.timestamp_quality
      AS first_valid_report_timestamp_quality,


    first_valid_pick.source_file_name
      AS first_valid_report_source_file_name,


    -- =========================================================================
    -- FIRST STRICT-NATIVE REPORT
    -- =========================================================================

    CASE

      WHEN first_strict_native_pick.report_date IS NOT NULL

        THEN source_system

    END
      AS first_strict_native_report_source_system,


    first_strict_native_pick.report_timestamp
      AS first_strict_native_report_timestamp,


    first_strict_native_pick.report_date
      AS first_strict_native_report_date,


    first_strict_native_pick.timestamp_source
      AS first_strict_native_report_timestamp_source,


    first_strict_native_pick.timestamp_quality
      AS first_strict_native_report_timestamp_quality,


    first_strict_native_pick.source_file_name
      AS first_strict_native_report_source_file_name,


    -- =========================================================================
    -- RAW REPORTING DELAY
    -- =========================================================================

    CASE

      WHEN first_raw_pick.report_date IS NOT NULL

      THEN DATE_DIFF(
        first_raw_pick.report_date,
        delivery_date,
        DAY
      )

    END AS raw_reporting_delay_days,


    -- =========================================================================
    -- VALID REPORTING DELAY
    --
    -- May include ingestion fallback.
    -- =========================================================================

    CASE

      WHEN first_valid_pick.report_date IS NOT NULL

      THEN DATE_DIFF(
        first_valid_pick.report_date,
        delivery_date,
        DAY
      )

    END AS reporting_delay_days,


    -- =========================================================================
    -- STRICT-NATIVE REPORTING DELAY
    --
    -- Recommended for headline timeliness.
    -- =========================================================================

    CASE

      WHEN first_strict_native_pick.report_date IS NOT NULL

      THEN DATE_DIFF(
        first_strict_native_pick.report_date,
        delivery_date,
        DAY
      )

    END AS strict_native_reporting_delay_days,


    -- =========================================================================
    -- QA FLAGS
    -- =========================================================================

    (
      first_raw_pick.report_date
        < delivery_date
    ) AS negative_reporting_delay_flag,


    first_raw_pick.report_date IS NULL
      AS report_timestamp_missing_flag,


    first_valid_pick.report_date IS NULL
      AS valid_report_missing_flag,


    first_strict_native_pick.report_date IS NULL
      AS strict_native_report_missing_flag,


    first_valid_pick.report_date IS NOT NULL
      AS timeliness_evaluable_flag,


    first_strict_native_pick.report_date IS NOT NULL
      AS strict_native_timeliness_evaluable_flag,


    1 AS source_capture_count

  FROM source_grouped
),


-- =============================================================================
-- =============================================================================
-- 11. TOTAL ANY SOURCE
-- =============================================================================
-- =============================================================================

total_grouped AS (

  SELECT

    delivery_event_id,

    pregnancy_episode_id,

    delivery_date,


    COUNT(
      DISTINCT source_system
    ) AS source_system_count,


    SUM(
      source_event_count
    ) AS source_event_count,


    SUM(
      native_metadata_matched_event_count
    ) AS native_metadata_matched_event_count,


    SUM(
      native_report_candidate_count
    ) AS native_report_candidate_count,


    SUM(
      source_file_count
    ) AS source_file_count,


    -- =========================================================================
    -- FIRST RAW REPORT FROM ANY SOURCE
    -- =========================================================================

    ARRAY_AGG(

      IF(

        first_report_date IS NOT NULL,

        STRUCT(

          first_report_source_system
            AS report_source_system,

          first_report_timestamp
            AS report_timestamp,

          first_report_date
            AS report_date,

          first_report_timestamp_source
            AS timestamp_source,

          first_report_timestamp_quality
            AS timestamp_quality,

          first_report_source_file_name
            AS source_file_name

        ),

        NULL

      )

      IGNORE NULLS

      ORDER BY
        first_report_date,
        first_report_timestamp,
        first_report_source_system

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS first_raw_pick,


    -- =========================================================================
    -- FIRST VALID REPORT FROM ANY SOURCE
    -- =========================================================================

    ARRAY_AGG(

      IF(

        first_valid_report_date IS NOT NULL,

        STRUCT(

          first_valid_report_source_system
            AS report_source_system,

          first_valid_report_timestamp
            AS report_timestamp,

          first_valid_report_date
            AS report_date,

          first_valid_report_timestamp_source
            AS timestamp_source,

          first_valid_report_timestamp_quality
            AS timestamp_quality,

          first_valid_report_source_file_name
            AS source_file_name

        ),

        NULL

      )

      IGNORE NULLS

      ORDER BY
        first_valid_report_date,
        first_valid_report_timestamp,
        first_valid_report_source_system

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS first_valid_pick,


    -- =========================================================================
    -- FIRST STRICT-NATIVE REPORT FROM ANY SOURCE
    --
    -- Uses the already-derived strict-native report for each source.
    -- =========================================================================

    ARRAY_AGG(

      IF(

        first_strict_native_report_date IS NOT NULL,

        STRUCT(

          first_strict_native_report_source_system
            AS report_source_system,

          first_strict_native_report_timestamp
            AS report_timestamp,

          first_strict_native_report_date
            AS report_date,

          first_strict_native_report_timestamp_source
            AS timestamp_source,

          first_strict_native_report_timestamp_quality
            AS timestamp_quality,

          first_strict_native_report_source_file_name
            AS source_file_name

        ),

        NULL

      )

      IGNORE NULLS

      ORDER BY
        first_strict_native_report_date,
        first_strict_native_report_timestamp,
        first_strict_native_report_source_system

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS first_strict_native_pick


  FROM source_final


  GROUP BY

    delivery_event_id,

    pregnancy_episode_id,

    delivery_date
),


total_final AS (

  SELECT

    delivery_event_id,

    pregnancy_episode_id,

    delivery_date,


    'TOTAL_ANY_SOURCE'
      AS source_system,


    'Total (Any Source)'
      AS source_system_display,


    0 AS source_order,


    source_system_count,

    source_event_count,

    native_metadata_matched_event_count,

    native_report_candidate_count,

    source_file_count,


    -- =========================================================================
    -- FIRST RAW REPORT
    -- =========================================================================

    first_raw_pick.report_source_system
      AS first_report_source_system,


    first_raw_pick.report_timestamp
      AS first_report_timestamp,


    first_raw_pick.report_date
      AS first_report_date,


    first_raw_pick.timestamp_source
      AS first_report_timestamp_source,


    first_raw_pick.timestamp_quality
      AS first_report_timestamp_quality,


    first_raw_pick.source_file_name
      AS first_report_source_file_name,


    -- =========================================================================
    -- FIRST VALID REPORT
    -- =========================================================================

    first_valid_pick.report_source_system
      AS first_valid_report_source_system,


    first_valid_pick.report_timestamp
      AS first_valid_report_timestamp,


    first_valid_pick.report_date
      AS first_valid_report_date,


    first_valid_pick.timestamp_source
      AS first_valid_report_timestamp_source,


    first_valid_pick.timestamp_quality
      AS first_valid_report_timestamp_quality,


    first_valid_pick.source_file_name
      AS first_valid_report_source_file_name,


    -- =========================================================================
    -- FIRST STRICT-NATIVE REPORT
    -- =========================================================================

    first_strict_native_pick.report_source_system
      AS first_strict_native_report_source_system,


    first_strict_native_pick.report_timestamp
      AS first_strict_native_report_timestamp,


    first_strict_native_pick.report_date
      AS first_strict_native_report_date,


    first_strict_native_pick.timestamp_source
      AS first_strict_native_report_timestamp_source,


    first_strict_native_pick.timestamp_quality
      AS first_strict_native_report_timestamp_quality,


    first_strict_native_pick.source_file_name
      AS first_strict_native_report_source_file_name,


    -- =========================================================================
    -- RAW REPORTING DELAY
    -- =========================================================================

    CASE

      WHEN first_raw_pick.report_date IS NOT NULL

      THEN DATE_DIFF(
        first_raw_pick.report_date,
        delivery_date,
        DAY
      )

    END AS raw_reporting_delay_days,


    -- =========================================================================
    -- VALID REPORTING DELAY
    -- =========================================================================

    CASE

      WHEN first_valid_pick.report_date IS NOT NULL

      THEN DATE_DIFF(
        first_valid_pick.report_date,
        delivery_date,
        DAY
      )

    END AS reporting_delay_days,


    -- =========================================================================
    -- STRICT-NATIVE REPORTING DELAY
    -- =========================================================================

    CASE

      WHEN first_strict_native_pick.report_date IS NOT NULL

      THEN DATE_DIFF(
        first_strict_native_pick.report_date,
        delivery_date,
        DAY
      )

    END AS strict_native_reporting_delay_days,


    -- =========================================================================
    -- QA FLAGS
    -- =========================================================================

    (
      first_raw_pick.report_date
        < delivery_date
    ) AS negative_reporting_delay_flag,


    first_raw_pick.report_date IS NULL
      AS report_timestamp_missing_flag,


    first_valid_pick.report_date IS NULL
      AS valid_report_missing_flag,


    first_strict_native_pick.report_date IS NULL
      AS strict_native_report_missing_flag,


    first_valid_pick.report_date IS NOT NULL
      AS timeliness_evaluable_flag,


    first_strict_native_pick.report_date IS NOT NULL
      AS strict_native_timeliness_evaluable_flag,


    1 AS source_capture_count

  FROM total_grouped
),


-- =============================================================================
-- 12. INDIVIDUAL SOURCES + TOTAL
-- =============================================================================

all_results AS (

  SELECT *
  FROM source_final


  UNION ALL


  SELECT *
  FROM total_final
)


-- =============================================================================
-- =============================================================================
-- FINAL OUTPUT
-- =============================================================================
-- =============================================================================

SELECT
  *,


  -- ===========================================================================
  -- STANDARD DELAY CATEGORY
  --
  -- May include fallback reporting metadata.
  -- ===========================================================================

  CASE

    WHEN reporting_delay_days IS NULL
      THEN 'UNKNOWN'

    WHEN reporting_delay_days = 0
      THEN 'H+0'

    WHEN reporting_delay_days = 1
      THEN 'H+1'

    WHEN reporting_delay_days = 2
      THEN 'H+2'

    WHEN reporting_delay_days = 3
      THEN 'H+3'

    WHEN reporting_delay_days = 4
      THEN 'H+4'

    WHEN reporting_delay_days = 5
      THEN 'H+5'

    WHEN reporting_delay_days = 6
      THEN 'H+6'

    WHEN reporting_delay_days = 7
      THEN 'H+7'

    WHEN reporting_delay_days BETWEEN 8 AND 14
      THEN 'H+8–H+14'

    WHEN reporting_delay_days BETWEEN 15 AND 30
      THEN 'H+15–H+30'

    WHEN reporting_delay_days > 30
      THEN '>H+30'

  END AS reporting_delay_group,


  CASE

    WHEN reporting_delay_days = 0
      THEN 1

    WHEN reporting_delay_days = 1
      THEN 2

    WHEN reporting_delay_days = 2
      THEN 3

    WHEN reporting_delay_days = 3
      THEN 4

    WHEN reporting_delay_days = 4
      THEN 5

    WHEN reporting_delay_days = 5
      THEN 6

    WHEN reporting_delay_days = 6
      THEN 7

    WHEN reporting_delay_days = 7
      THEN 8

    WHEN reporting_delay_days BETWEEN 8 AND 14
      THEN 9

    WHEN reporting_delay_days BETWEEN 15 AND 30
      THEN 10

    WHEN reporting_delay_days > 30
      THEN 11

    ELSE 99

  END AS reporting_delay_group_order,


  -- ===========================================================================
  -- STRICT-NATIVE DELAY CATEGORY
  --
  -- Recommended for headline timeliness.
  -- ===========================================================================

  CASE

    WHEN strict_native_reporting_delay_days IS NULL
      THEN 'UNKNOWN'

    WHEN strict_native_reporting_delay_days = 0
      THEN 'H+0'

    WHEN strict_native_reporting_delay_days = 1
      THEN 'H+1'

    WHEN strict_native_reporting_delay_days = 2
      THEN 'H+2'

    WHEN strict_native_reporting_delay_days = 3
      THEN 'H+3'

    WHEN strict_native_reporting_delay_days = 4
      THEN 'H+4'

    WHEN strict_native_reporting_delay_days = 5
      THEN 'H+5'

    WHEN strict_native_reporting_delay_days = 6
      THEN 'H+6'

    WHEN strict_native_reporting_delay_days = 7
      THEN 'H+7'

    WHEN strict_native_reporting_delay_days
         BETWEEN 8 AND 14
      THEN 'H+8–H+14'

    WHEN strict_native_reporting_delay_days
         BETWEEN 15 AND 30
      THEN 'H+15–H+30'

    WHEN strict_native_reporting_delay_days > 30
      THEN '>H+30'

  END AS strict_native_reporting_delay_group,


  CASE

    WHEN strict_native_reporting_delay_days = 0
      THEN 1

    WHEN strict_native_reporting_delay_days = 1
      THEN 2

    WHEN strict_native_reporting_delay_days = 2
      THEN 3

    WHEN strict_native_reporting_delay_days = 3
      THEN 4

    WHEN strict_native_reporting_delay_days = 4
      THEN 5

    WHEN strict_native_reporting_delay_days = 5
      THEN 6

    WHEN strict_native_reporting_delay_days = 6
      THEN 7

    WHEN strict_native_reporting_delay_days = 7
      THEN 8

    WHEN strict_native_reporting_delay_days
         BETWEEN 8 AND 14
      THEN 9

    WHEN strict_native_reporting_delay_days
         BETWEEN 15 AND 30
      THEN 10

    WHEN strict_native_reporting_delay_days > 30
      THEN 11

    ELSE 99

  END AS strict_native_reporting_delay_group_order,


  -- ===========================================================================
  -- STANDARD TIMELINESS COUNTS
  -- ===========================================================================

  CAST(
    reporting_delay_days = 0
    AS INT64
  ) AS reported_h0_count,


  CAST(
    reporting_delay_days BETWEEN 0 AND 1
    AS INT64
  ) AS reported_by_h1_count,


  CAST(
    reporting_delay_days BETWEEN 0 AND 3
    AS INT64
  ) AS reported_by_h3_count,


  CAST(
    reporting_delay_days BETWEEN 0 AND 7
    AS INT64
  ) AS reported_by_h7_count,


  CAST(
    reporting_delay_days BETWEEN 0 AND 14
    AS INT64
  ) AS reported_by_h14_count,


  CAST(
    reporting_delay_days BETWEEN 0 AND 30
    AS INT64
  ) AS reported_by_h30_count,


  -- ===========================================================================
  -- STRICT-NATIVE DENOMINATOR
  -- ===========================================================================

  CAST(
    strict_native_timeliness_evaluable_flag
    AS INT64
  ) AS strict_native_timeliness_evaluable_count,


  -- ===========================================================================
  -- STRICT-NATIVE CUMULATIVE TIMELINESS COUNTS
  -- ===========================================================================

  CAST(
    strict_native_reporting_delay_days = 0
    AS INT64
  ) AS strict_native_reported_h0_count,


  CAST(
    strict_native_reporting_delay_days
      BETWEEN 0 AND 1
    AS INT64
  ) AS strict_native_reported_by_h1_count,


  CAST(
    strict_native_reporting_delay_days
      BETWEEN 0 AND 3
    AS INT64
  ) AS strict_native_reported_by_h3_count,


  CAST(
    strict_native_reporting_delay_days
      BETWEEN 0 AND 7
    AS INT64
  ) AS strict_native_reported_by_h7_count,


  CAST(
    strict_native_reporting_delay_days
      BETWEEN 0 AND 14
    AS INT64
  ) AS strict_native_reported_by_h14_count,


  CAST(
    strict_native_reporting_delay_days
      BETWEEN 0 AND 30
    AS INT64
  ) AS strict_native_reported_by_h30_count


FROM all_results""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_delivery_timing_analysis_v1
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_delivery_timing_analysis_v1');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_delivery_timing_analysis_v1';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_delivery_timing_analysis_v1` AS SELECT ',
 projection, ' FROM (', r"""WITH accepted_delivery AS (
  SELECT *
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_v3`
  WHERE
    strict_birth_count_eligible_flag
    AND anc_link_status IN (
      'MATCHED_SIGIZI_EPUS',
      'MATCHED_SIGIZI_ONLY',
      'MATCHED_EPUS_ONLY',
      'MATCHED_ANC_OTHER'
    )
),

base AS (
  SELECT
    p.pregnancy_episode_id,

    p.nik_clean,
    p.nama_ibu,

    p.puskesmas,
    p.puskesmas_norm,
    p.desa,

    p.pregnancy_source_combination,

    -- ------------------------------------------------------
    -- Dating information
    -- ------------------------------------------------------
    p.hpht_date,
    p.hpht_source,

    p.hpl_recorded_date,
    p.hpl_recorded_source,

    p.hpl_from_hpht_date,

    p.dating_usg_date,
    p.dating_usg_ga_weeks,
    p.usg_dating_quality,

    p.usg_recorded_hpl_date,
    p.hpl_from_usg_ga_date,
    p.hpl_from_usg_date,

    p.expected_delivery_date,
    p.expected_delivery_date_source,

    -- ------------------------------------------------------
    -- Accepted integrated actual delivery
    -- ------------------------------------------------------
    d.delivery_event_id
      AS integrated_delivery_event_id,

    d.delivery_date
      AS actual_delivery_date_integrated,

    d.delivery_outcome_final
      AS integrated_delivery_outcome,

    d.delivery_source_combination
      AS integrated_delivery_source_combination,

    d.primary_delivery_source
      AS integrated_primary_delivery_source,

    d.delivery_date_conflict_flag
      AS integrated_delivery_date_conflict_flag,

    d.delivery_date_range_days
      AS integrated_delivery_date_range_days,

    d.delivery_qa_required
      AS integrated_delivery_qa_required,

    d.anc_link_method
      AS integrated_anc_link_method,

    d.anc_link_confidence
      AS integrated_anc_link_confidence,

    p.pregnancy_date_valid_flag,
    p.monitoring_eligible_flag

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_tracking_v3_3` p

  LEFT JOIN accepted_delivery d
    USING (pregnancy_episode_id)
),

with_difference AS (
  SELECT
    *,

    DATE_DIFF(
      actual_delivery_date_integrated,
      expected_delivery_date,
      DAY
    ) AS delivery_vs_expected_days,

    ABS(
      DATE_DIFF(
        actual_delivery_date_integrated,
        expected_delivery_date,
        DAY
      )
    ) AS absolute_delivery_vs_expected_days

  FROM base
)

SELECT
  *,

  -- Main cohort recommended for statistical analysis
  (
    expected_delivery_date IS NOT NULL
    AND actual_delivery_date_integrated IS NOT NULL
    AND COALESCE(pregnancy_date_valid_flag, FALSE)
    AND NOT COALESCE(
      integrated_delivery_date_conflict_flag,
      FALSE
    )
    AND NOT COALESCE(
      integrated_delivery_qa_required,
      FALSE
    )
  ) AS timing_analysis_eligible_flag,

  -- Do NOT automatically exclude these.
  -- This is only a flag for examining extreme records.
  (
    delivery_vs_expected_days IS NOT NULL
    AND ABS(delivery_vs_expected_days) > 60
  ) AS extreme_difference_60d_qa_flag,

  CASE
    WHEN delivery_vs_expected_days IS NULL
      THEN 'UNKNOWN'

    WHEN delivery_vs_expected_days < -42
      THEN '< -42 DAYS'

    WHEN delivery_vs_expected_days BETWEEN -42 AND -15
      THEN '-42 TO -15 DAYS'

    WHEN delivery_vs_expected_days BETWEEN -14 AND -8
      THEN '-14 TO -8 DAYS'

    WHEN delivery_vs_expected_days BETWEEN -7 AND -4
      THEN '-7 TO -4 DAYS'

    WHEN delivery_vs_expected_days BETWEEN -3 AND -1
      THEN '-3 TO -1 DAYS'

    WHEN delivery_vs_expected_days = 0
      THEN 'ON EDD'

    WHEN delivery_vs_expected_days BETWEEN 1 AND 3
      THEN '+1 TO +3 DAYS'

    WHEN delivery_vs_expected_days BETWEEN 4 AND 7
      THEN '+4 TO +7 DAYS'

    WHEN delivery_vs_expected_days BETWEEN 8 AND 14
      THEN '+8 TO +14 DAYS'

    WHEN delivery_vs_expected_days BETWEEN 15 AND 21
      THEN '+15 TO +21 DAYS'

    ELSE '> +21 DAYS'
  END AS delivery_vs_expected_category

FROM with_difference""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_pregnancy_dating_accuracy_v3_3
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_pregnancy_dating_accuracy_v3_3');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_pregnancy_dating_accuracy_v3_3';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_dating_accuracy_v3_3` AS SELECT ',
 projection, ' FROM (', r"""SELECT
  pregnancy_episode_id,

  nik_clean,
  nama_ibu,

  puskesmas,
  puskesmas_norm,
  desa,

  pregnancy_source_combination,

  hpht_sigizi,
  hpht_epus,
  hpht_date,
  hpht_source,

  hpl_sigizi,
  hpl_epus,

  hpl_recorded_date,
  hpl_recorded_source,

  hpl_from_hpht_date,

  dating_usg_date,
  dating_usg_ga_weeks,
  usg_dating_quality,

  usg_recorded_hpl_date,
  hpl_from_usg_ga_date,
  hpl_from_usg_date,

  usg_recorded_minus_calculated_hpl_days,

  expected_delivery_date,
  expected_delivery_date_source,

  actual_delivery_date,
  pregnancy_outcome_final,

  delivery_minus_recorded_hpl_days,
  abs_delivery_minus_recorded_hpl_days,

  delivery_minus_hpht_hpl_days,
  abs_delivery_minus_hpht_hpl_days,

  delivery_minus_usg_ga_hpl_days,
  abs_delivery_minus_usg_ga_hpl_days,

  delivery_minus_usg_recorded_hpl_days,
  abs_delivery_minus_usg_recorded_hpl_days,

  delivery_minus_canonical_hpl_days,
  abs_delivery_minus_canonical_hpl_days,

  usg_ga_minus_hpht_hpl_days,
  abs_usg_ga_minus_hpht_hpl_days,

  usg_vs_hpht_hpl_difference_category,
  delivery_vs_hpl_category,

  primary_delivery_source,
  delivery_source_combination,

  delivery_date_conflict_flag

FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_tracking_v3_3`

WHERE actual_delivery_date IS NOT NULL""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_pregnancy_delivery_source_overlap_v3_3
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_pregnancy_delivery_source_overlap_v3_3');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_pregnancy_delivery_source_overlap_v3_3';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_delivery_source_overlap_v3_3` AS SELECT ',
 projection, ' FROM (', r"""SELECT
  expected_delivery_month,

  puskesmas,
  puskesmas_norm,

  delivery_source_combination,
  delivery_source_count,

  has_delivery_sigizi,
  has_delivery_epus,
  has_delivery_simrs,
  has_delivery_kobo_inc,
  has_delivery_neonatal,
  has_delivery_inc_report,

  COUNT(*) AS pregnancy_count

FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_tracking_v3_3`

WHERE delivery_found_flag = TRUE

GROUP BY
  expected_delivery_month,
  puskesmas,
  puskesmas_norm,
  delivery_source_combination,
  delivery_source_count,
  has_delivery_sigizi,
  has_delivery_epus,
  has_delivery_simrs,
  has_delivery_kobo_inc,
  has_delivery_neonatal,
  has_delivery_inc_report""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_pregnancy_outcome_tracking_dashboard_v3_3
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_pregnancy_outcome_tracking_dashboard_v3_3');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_pregnancy_outcome_tracking_dashboard_v3_3';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_outcome_tracking_dashboard_v3_3` AS SELECT ',
 projection, ' FROM (', r"""SELECT
  t.*,

  1 AS pregnancy_count,

  CAST(
    due_cohort_flag
    AS INT64
  ) AS due_cohort_count,

  CAST(
    monitoring_eligible_flag
    AS INT64
  ) AS monitoring_eligible_count,

  CAST(
    expected_to_deliver_flag
    AS INT64
  ) AS expected_to_deliver_count,

  CAST(
    expected_to_have_delivered_by_today_flag
    AS INT64
  ) AS expected_to_have_delivered_by_today_count,

  CAST(
    currently_still_pregnant_flag
    AS INT64
  ) AS currently_still_pregnant_count,

  CAST(
    delivery_found_flag
    AS INT64
  ) AS delivery_found_count,

  CAST(
    outcome_found_flag
    AS INT64
  ) AS outcome_found_count,

  CAST(
    COALESCE(
      pregnancy_outcome_final
        = 'LAHIR HIDUP',
      FALSE
    )
    AS INT64
  ) AS live_birth_count,

  CAST(
    COALESCE(
      pregnancy_outcome_final
        = 'LAHIR MATI',
      FALSE
    )
    AS INT64
  ) AS stillbirth_count,

  CAST(
    COALESCE(
      pregnancy_outcome_final
        = 'ABORTUS',
      FALSE
    )
    AS INT64
  ) AS abortion_count,

  CAST(
    missing_birth_flag
    AS INT64
  ) AS missing_birth_count,

  CAST(
    missing_birth_has_phone_flag
    AS INT64
  ) AS missing_birth_has_phone_count,

  CAST(
    missing_birth_no_phone_flag
    AS INT64
  ) AS missing_birth_no_phone_count

FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_tracking_v3_3` t""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_pregnancy_outcome_trend_monthly_v3_3
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_pregnancy_outcome_trend_monthly_v3_3');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_pregnancy_outcome_trend_monthly_v3_3';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_outcome_trend_monthly_v3_3` AS SELECT ',
 projection, ' FROM (', r"""SELECT
  expected_delivery_month,

  puskesmas,
  puskesmas_norm,

  COUNTIF(
    monitoring_eligible_flag
  ) AS monitoring_eligible_count,

  COUNTIF(
    expected_to_deliver_flag
  ) AS expected_to_deliver_count,

  COUNTIF(
    delivery_found_flag
  ) AS delivery_found_count,

  COUNTIF(
    outcome_found_flag
  ) AS outcome_found_count,

  COUNTIF(
    pregnancy_outcome_final
      = 'LAHIR HIDUP'
  ) AS live_birth_count,

  COUNTIF(
    pregnancy_outcome_final
      = 'LAHIR MATI'
  ) AS stillbirth_count,

  COUNTIF(
    pregnancy_outcome_final
      = 'ABORTUS'
  ) AS abortion_count,

  COUNTIF(
    missing_birth_flag
  ) AS missing_birth_count,

  COUNTIF(
    missing_birth_has_phone_flag
  ) AS missing_birth_has_phone_count,

  SAFE_MULTIPLY(
    100,
    SAFE_DIVIDE(
      COUNTIF(
        delivery_found_flag
      ),
      NULLIF(
        COUNTIF(
          expected_to_deliver_flag
        ),
        0
      )
    )
  ) AS delivery_capture_rate_pct,

  SAFE_MULTIPLY(
    100,
    SAFE_DIVIDE(
      COUNTIF(
        outcome_found_flag
      ),
      NULLIF(
        COUNTIF(
          expected_to_deliver_flag
        ),
        0
      )
    )
  ) AS outcome_capture_rate_pct

FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_tracking_v3_3`

WHERE expected_delivery_month IS NOT NULL
  AND monitoring_eligible_flag = TRUE

GROUP BY
  expected_delivery_month,
  puskesmas,
  puskesmas_norm""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_pregnancy_source_crosswalk_v3_3
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_pregnancy_source_crosswalk_v3_3');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_pregnancy_source_crosswalk_v3_3';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_source_crosswalk_v3_3` AS SELECT ',
 projection, ' FROM (', r"""SELECT
  pregnancy_episode_id,

  sigizi_episode_id,
  epus_episode_id,
  epus_episode_source_key,

  pregnancy_source_combination,

  cross_source_match_method,
  cross_source_match_priority,
  anchor_difference_days,

  nik_clean,
  nama_ibu,

  puskesmas,
  desa,

  hpht_sigizi,
  hpht_epus,

  hpl_sigizi,
  hpl_epus,

  epus_minus_sigizi_hpht_days,
  epus_minus_sigizi_hpl_days,

  pregnancy_anchor_date,

  sigizi_anchor_spread_days,
  sigizi_episode_review_flag,

  sigizi_member_record_count,
  sigizi_source_tables

FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3`""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_simrs_birth_weight_normalized
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_simrs_birth_weight_normalized');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_simrs_birth_weight_normalized';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_simrs_birth_weight_normalized` AS SELECT ',
 projection, ' FROM (', r"""WITH src AS (
  SELECT
    TO_JSON_STRING(t) AS j
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_simrs_patut_patuh_inc` t
),

extracted AS (
  SELECT
    CONCAT(
      'SIMRS|',
      COALESCE(
        NULLIF(JSON_VALUE(j, '$.source_record_id'), ''),
        NULLIF(JSON_VALUE(j, '$.dedup_key'), ''),
        NULLIF(JSON_VALUE(j, '$.source_row_hash'), ''),
        CAST(FARM_FINGERPRINT(j) AS STRING)
      )
    ) AS source_event_id,

    JSON_VALUE(
      j,
      '$.berat_badan_lahir'
    ) AS birth_weight_raw,

    SAFE_CAST(
      JSON_VALUE(
        j,
        '$.berat_badan_lahir_numeric'
      )
      AS FLOAT64
    ) AS birth_weight_numeric

  FROM src
),

normalized AS (
  SELECT
    *,

    CASE
      -- value entered in kilograms
      WHEN birth_weight_numeric BETWEEN 0.5 AND 10
        THEN ROUND(birth_weight_numeric * 1000)

      -- otherwise assume gram
      ELSE birth_weight_numeric
    END AS birth_weight_gram

  FROM extracted
)

SELECT
  *,

  CASE
    WHEN birth_weight_gram IS NULL
      THEN 'MISSING'

    WHEN birth_weight_gram < 500
      OR birth_weight_gram > 6000
      THEN 'NEEDS_VALIDATION'

    ELSE 'USABLE'
  END AS birth_weight_quality

FROM normalized""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_birth_source_performance_wide
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_birth_source_performance_wide');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_birth_source_performance_wide';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_birth_source_performance_wide` AS SELECT ',
 projection, ' FROM (', r"""SELECT

  -- ===========================================================================
  -- DATE DIMENSIONS
  -- ===========================================================================

  metric_date,

  metric_week,

  metric_month,

  MAX(
    metric_month_label
  ) AS metric_month_label,

  MAX(
    metric_quarter
  ) AS metric_quarter,

  metric_year,


  MAX(
    month_anchor_date
  ) AS month_anchor_date,


  MAX(
    month_anchor_flag
  ) AS month_anchor_flag,


  -- ===========================================================================
  -- COMMON CANONICAL DENOMINATORS
  -- ===========================================================================

  MAX(
    known_births_daily
  ) AS known_births_daily,


  MAX(
    known_births_30d
  ) AS known_births_30d,


  MAX(
    known_births_month
  ) AS known_births_month,


  -- ===========================================================================
  -- ===========================================================================
  -- TOTAL ANY SOURCE — CAPTURE
  --
  -- Mainly useful as QA / total volume.
  -- Since canonical deliveries originate from known delivery sources,
  -- the capture rate should normally be near 100%.
  -- ===========================================================================
  -- ===========================================================================

  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      source_births_recorded_daily,
      NULL
    )
  ) AS total_any_source_recorded_daily,


  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      source_births_recorded_30d,
      NULL
    )
  ) AS total_any_source_recorded_30d,


  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      source_births_recorded_month,
      NULL
    )
  ) AS total_any_source_recorded_month,


  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      capture_rate_30d,
      NULL
    )
  ) AS total_any_source_capture_rate_30d,


  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      capture_rate_monthly,
      NULL
    )
  ) AS total_any_source_capture_rate_monthly,


  -- ===========================================================================
  -- ===========================================================================
  -- BIRTH REPORT FASKES — CAPTURE
  -- ===========================================================================
  -- ===========================================================================

  MAX(
    IF(
      source_system = 'INC_REPORT_TRACKER',
      source_births_recorded_30d,
      NULL
    )
  ) AS birth_report_faskes_recorded_30d,


  MAX(
    IF(
      source_system = 'INC_REPORT_TRACKER',
      source_births_recorded_month,
      NULL
    )
  ) AS birth_report_faskes_recorded_month,


  MAX(
    IF(
      source_system = 'INC_REPORT_TRACKER',
      capture_rate_30d,
      NULL
    )
  ) AS birth_report_faskes_capture_rate_30d,


  MAX(
    IF(
      source_system = 'INC_REPORT_TRACKER',
      capture_rate_monthly,
      NULL
    )
  ) AS birth_report_faskes_capture_rate_monthly,


  -- ===========================================================================
  -- SIGIZI — CAPTURE
  -- ===========================================================================

  MAX(
    IF(
      source_system = 'SIGIZI',
      source_births_recorded_30d,
      NULL
    )
  ) AS sigizi_recorded_30d,


  MAX(
    IF(
      source_system = 'SIGIZI',
      source_births_recorded_month,
      NULL
    )
  ) AS sigizi_recorded_month,


  MAX(
    IF(
      source_system = 'SIGIZI',
      capture_rate_30d,
      NULL
    )
  ) AS sigizi_capture_rate_30d,


  MAX(
    IF(
      source_system = 'SIGIZI',
      capture_rate_monthly,
      NULL
    )
  ) AS sigizi_capture_rate_monthly,


  -- ===========================================================================
  -- EPUS — CAPTURE
  -- ===========================================================================

  MAX(
    IF(
      source_system = 'EPUS',
      source_births_recorded_30d,
      NULL
    )
  ) AS epus_recorded_30d,


  MAX(
    IF(
      source_system = 'EPUS',
      source_births_recorded_month,
      NULL
    )
  ) AS epus_recorded_month,


  MAX(
    IF(
      source_system = 'EPUS',
      capture_rate_30d,
      NULL
    )
  ) AS epus_capture_rate_30d,


  MAX(
    IF(
      source_system = 'EPUS',
      capture_rate_monthly,
      NULL
    )
  ) AS epus_capture_rate_monthly,


  -- ===========================================================================
  -- SIMRS — CAPTURE
  -- ===========================================================================

  MAX(
    IF(
      source_system = 'SIMRS',
      source_births_recorded_30d,
      NULL
    )
  ) AS simrs_recorded_30d,


  MAX(
    IF(
      source_system = 'SIMRS',
      source_births_recorded_month,
      NULL
    )
  ) AS simrs_recorded_month,


  MAX(
    IF(
      source_system = 'SIMRS',
      capture_rate_30d,
      NULL
    )
  ) AS simrs_capture_rate_30d,


  MAX(
    IF(
      source_system = 'SIMRS',
      capture_rate_monthly,
      NULL
    )
  ) AS simrs_capture_rate_monthly,


  -- ===========================================================================
  -- KOBO INC — CAPTURE
  -- ===========================================================================

  MAX(
    IF(
      source_system = 'KOBO_INC',
      source_births_recorded_30d,
      NULL
    )
  ) AS kobo_inc_recorded_30d,


  MAX(
    IF(
      source_system = 'KOBO_INC',
      source_births_recorded_month,
      NULL
    )
  ) AS kobo_inc_recorded_month,


  MAX(
    IF(
      source_system = 'KOBO_INC',
      capture_rate_30d,
      NULL
    )
  ) AS kobo_inc_capture_rate_30d,


  MAX(
    IF(
      source_system = 'KOBO_INC',
      capture_rate_monthly,
      NULL
    )
  ) AS kobo_inc_capture_rate_monthly,


  -- ===========================================================================
  -- NEONATAL OUTCOME — CAPTURE
  -- ===========================================================================

  MAX(
    IF(
      source_system = 'NEONATAL_OUTCOME',
      source_births_recorded_30d,
      NULL
    )
  ) AS neonatal_outcome_recorded_30d,


  MAX(
    IF(
      source_system = 'NEONATAL_OUTCOME',
      source_births_recorded_month,
      NULL
    )
  ) AS neonatal_outcome_recorded_month,


  MAX(
    IF(
      source_system = 'NEONATAL_OUTCOME',
      capture_rate_30d,
      NULL
    )
  ) AS neonatal_outcome_capture_rate_30d,


  MAX(
    IF(
      source_system = 'NEONATAL_OUTCOME',
      capture_rate_monthly,
      NULL
    )
  ) AS neonatal_outcome_capture_rate_monthly,


  -- ===========================================================================
  -- ===========================================================================
  -- H+1 TIMELINESS — MONTHLY
  -- ===========================================================================
  -- ===========================================================================

  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      timeliness_h1_rate_monthly,
      NULL
    )
  ) AS total_timeliness_h1_rate_monthly,


  MAX(
    IF(
      source_system = 'INC_REPORT_TRACKER',
      timeliness_h1_rate_monthly,
      NULL
    )
  ) AS birth_report_faskes_timeliness_h1_rate_monthly,


  MAX(
    IF(
      source_system = 'SIGIZI',
      timeliness_h1_rate_monthly,
      NULL
    )
  ) AS sigizi_timeliness_h1_rate_monthly,


  MAX(
    IF(
      source_system = 'EPUS',
      timeliness_h1_rate_monthly,
      NULL
    )
  ) AS epus_timeliness_h1_rate_monthly,


  MAX(
    IF(
      source_system = 'SIMRS',
      timeliness_h1_rate_monthly,
      NULL
    )
  ) AS simrs_timeliness_h1_rate_monthly,


  MAX(
    IF(
      source_system = 'KOBO_INC',
      timeliness_h1_rate_monthly,
      NULL
    )
  ) AS kobo_inc_timeliness_h1_rate_monthly,


  MAX(
    IF(
      source_system = 'NEONATAL_OUTCOME',
      timeliness_h1_rate_monthly,
      NULL
    )
  ) AS neonatal_outcome_timeliness_h1_rate_monthly,


  -- ===========================================================================
  -- H+7 TIMELINESS — MONTHLY
  -- ===========================================================================

  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      timeliness_h7_rate_monthly,
      NULL
    )
  ) AS total_timeliness_h7_rate_monthly,


  MAX(
    IF(
      source_system = 'INC_REPORT_TRACKER',
      timeliness_h7_rate_monthly,
      NULL
    )
  ) AS birth_report_faskes_timeliness_h7_rate_monthly,


  MAX(
    IF(
      source_system = 'SIGIZI',
      timeliness_h7_rate_monthly,
      NULL
    )
  ) AS sigizi_timeliness_h7_rate_monthly,


  MAX(
    IF(
      source_system = 'EPUS',
      timeliness_h7_rate_monthly,
      NULL
    )
  ) AS epus_timeliness_h7_rate_monthly,


  MAX(
    IF(
      source_system = 'SIMRS',
      timeliness_h7_rate_monthly,
      NULL
    )
  ) AS simrs_timeliness_h7_rate_monthly,


  MAX(
    IF(
      source_system = 'KOBO_INC',
      timeliness_h7_rate_monthly,
      NULL
    )
  ) AS kobo_inc_timeliness_h7_rate_monthly,


  MAX(
    IF(
      source_system = 'NEONATAL_OUTCOME',
      timeliness_h7_rate_monthly,
      NULL
    )
  ) AS neonatal_outcome_timeliness_h7_rate_monthly,


  -- ===========================================================================
  -- ===========================================================================
  -- H+1 TIMELINESS — 30-DAY ROLLING
  -- ===========================================================================
  -- ===========================================================================

  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      timeliness_h1_rate_30d,
      NULL
    )
  ) AS total_timeliness_h1_rate_30d,


  MAX(
    IF(
      source_system = 'INC_REPORT_TRACKER',
      timeliness_h1_rate_30d,
      NULL
    )
  ) AS birth_report_faskes_timeliness_h1_rate_30d,


  MAX(
    IF(
      source_system = 'SIGIZI',
      timeliness_h1_rate_30d,
      NULL
    )
  ) AS sigizi_timeliness_h1_rate_30d,


  MAX(
    IF(
      source_system = 'EPUS',
      timeliness_h1_rate_30d,
      NULL
    )
  ) AS epus_timeliness_h1_rate_30d,


  MAX(
    IF(
      source_system = 'SIMRS',
      timeliness_h1_rate_30d,
      NULL
    )
  ) AS simrs_timeliness_h1_rate_30d,


  MAX(
    IF(
      source_system = 'KOBO_INC',
      timeliness_h1_rate_30d,
      NULL
    )
  ) AS kobo_inc_timeliness_h1_rate_30d,


  MAX(
    IF(
      source_system = 'NEONATAL_OUTCOME',
      timeliness_h1_rate_30d,
      NULL
    )
  ) AS neonatal_outcome_timeliness_h1_rate_30d,


  -- ===========================================================================
  -- H+7 TIMELINESS — 30-DAY ROLLING
  -- ===========================================================================

  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      timeliness_h7_rate_30d,
      NULL
    )
  ) AS total_timeliness_h7_rate_30d,


  MAX(
    IF(
      source_system = 'INC_REPORT_TRACKER',
      timeliness_h7_rate_30d,
      NULL
    )
  ) AS birth_report_faskes_timeliness_h7_rate_30d,


  MAX(
    IF(
      source_system = 'SIGIZI',
      timeliness_h7_rate_30d,
      NULL
    )
  ) AS sigizi_timeliness_h7_rate_30d,


  MAX(
    IF(
      source_system = 'EPUS',
      timeliness_h7_rate_30d,
      NULL
    )
  ) AS epus_timeliness_h7_rate_30d,


  MAX(
    IF(
      source_system = 'SIMRS',
      timeliness_h7_rate_30d,
      NULL
    )
  ) AS simrs_timeliness_h7_rate_30d,


  MAX(
    IF(
      source_system = 'KOBO_INC',
      timeliness_h7_rate_30d,
      NULL
    )
  ) AS kobo_inc_timeliness_h7_rate_30d,


  MAX(
    IF(
      source_system = 'NEONATAL_OUTCOME',
      timeliness_h7_rate_30d,
      NULL
    )
  ) AS neonatal_outcome_timeliness_h7_rate_30d,


  -- ===========================================================================
  -- ===========================================================================
  -- TIMELINESS DENOMINATORS — MONTHLY
  -- ===========================================================================
  -- ===========================================================================

  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      timeliness_evaluable_month,
      NULL
    )
  ) AS total_timeliness_n_month,


  MAX(
    IF(
      source_system = 'INC_REPORT_TRACKER',
      timeliness_evaluable_month,
      NULL
    )
  ) AS birth_report_faskes_timeliness_n_month,


  MAX(
    IF(
      source_system = 'SIGIZI',
      timeliness_evaluable_month,
      NULL
    )
  ) AS sigizi_timeliness_n_month,


  MAX(
    IF(
      source_system = 'EPUS',
      timeliness_evaluable_month,
      NULL
    )
  ) AS epus_timeliness_n_month,


  MAX(
    IF(
      source_system = 'SIMRS',
      timeliness_evaluable_month,
      NULL
    )
  ) AS simrs_timeliness_n_month,


  MAX(
    IF(
      source_system = 'KOBO_INC',
      timeliness_evaluable_month,
      NULL
    )
  ) AS kobo_inc_timeliness_n_month,


  MAX(
    IF(
      source_system = 'NEONATAL_OUTCOME',
      timeliness_evaluable_month,
      NULL
    )
  ) AS neonatal_outcome_timeliness_n_month,


  -- ===========================================================================
  -- TIMELINESS DENOMINATORS — 30 DAY
  -- ===========================================================================

  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      timeliness_evaluable_30d,
      NULL
    )
  ) AS total_timeliness_n_30d,


  MAX(
    IF(
      source_system = 'INC_REPORT_TRACKER',
      timeliness_evaluable_30d,
      NULL
    )
  ) AS birth_report_faskes_timeliness_n_30d,


  MAX(
    IF(
      source_system = 'SIGIZI',
      timeliness_evaluable_30d,
      NULL
    )
  ) AS sigizi_timeliness_n_30d,


  MAX(
    IF(
      source_system = 'EPUS',
      timeliness_evaluable_30d,
      NULL
    )
  ) AS epus_timeliness_n_30d,


  MAX(
    IF(
      source_system = 'SIMRS',
      timeliness_evaluable_30d,
      NULL
    )
  ) AS simrs_timeliness_n_30d,


  MAX(
    IF(
      source_system = 'KOBO_INC',
      timeliness_evaluable_30d,
      NULL
    )
  ) AS kobo_inc_timeliness_n_30d,


  MAX(
    IF(
      source_system = 'NEONATAL_OUTCOME',
      timeliness_evaluable_30d,
      NULL
    )
  ) AS neonatal_outcome_timeliness_n_30d,


  -- ===========================================================================
  -- ===========================================================================
  -- TOTAL ANY SOURCE — MONTHLY DELAY DISTRIBUTION
  --
  -- Use these for the Purbalingga-style 100% stacked bars.
  -- ===========================================================================
  -- ===========================================================================

  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      delay_h0_share_monthly,
      NULL
    )
  ) AS total_delay_h0_share_monthly,


  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      delay_h1_share_monthly,
      NULL
    )
  ) AS total_delay_h1_share_monthly,


  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      delay_h2_share_monthly,
      NULL
    )
  ) AS total_delay_h2_share_monthly,


  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      delay_h3_share_monthly,
      NULL
    )
  ) AS total_delay_h3_share_monthly,


  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      delay_h4_share_monthly,
      NULL
    )
  ) AS total_delay_h4_share_monthly,


  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      delay_h5_share_monthly,
      NULL
    )
  ) AS total_delay_h5_share_monthly,


  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      delay_h6_share_monthly,
      NULL
    )
  ) AS total_delay_h6_share_monthly,


  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      delay_h7_share_monthly,
      NULL
    )
  ) AS total_delay_h7_share_monthly,


  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      delay_h8_h14_share_monthly,
      NULL
    )
  ) AS total_delay_h8_h14_share_monthly,


  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      delay_h15_h30_share_monthly,
      NULL
    )
  ) AS total_delay_h15_h30_share_monthly,


  MAX(
    IF(
      source_system = 'TOTAL_ANY_SOURCE',
      delay_gt_h30_share_monthly,
      NULL
    )
  ) AS total_delay_gt_h30_share_monthly


FROM
  `spheres-lombok-barat.kohort_bumil_v3.v_birth_source_performance_daily_long`


GROUP BY
  metric_date,
  metric_week,
  metric_month,
  metric_year""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_delivery_monitoring_integrated
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_delivery_monitoring_integrated');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_delivery_monitoring_integrated';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_delivery_monitoring_integrated` AS SELECT ',
 projection, ' FROM (', r"""SELECT
  d.*,

  -- ============================================================
  -- DATE DIMENSIONS
  -- ============================================================

  d.delivery_date AS delivery_day,

  DATE_TRUNC(
    d.delivery_date,
    WEEK(MONDAY)
  ) AS delivery_week,

  DATE_TRUNC(
    d.delivery_date,
    MONTH
  ) AS delivery_month,

  DATE_TRUNC(
    d.delivery_date,
    QUARTER
  ) AS delivery_quarter,

  DATE_TRUNC(
    d.delivery_date,
    YEAR
  ) AS delivery_year,


  -- ============================================================
  -- DENOMINATORS
  -- ============================================================

  -- Legacy / technical canonical delivery counter.
  -- KEEP FOR QA ONLY.
  CAST(
    d.strict_birth_count_eligible_flag
    AS INT64
  ) AS technical_canonical_delivery_count,


  -- MAIN DASHBOARD DENOMINATOR
  CAST(
    d.valid_known_birth_flag
    AS INT64
  ) AS valid_known_birth_count,


  -- ============================================================
  -- OUTCOME COUNTERS
  -- Only valid known births contribute.
  -- ============================================================

  CAST(
    d.valid_known_birth_flag
    AND d.delivery_outcome_final = 'LAHIR HIDUP'
    AS INT64
  ) AS live_birth_count,

  CAST(
    d.valid_known_birth_flag
    AND d.delivery_outcome_final = 'LAHIR MATI'
    AS INT64
  ) AS stillbirth_count,

  CAST(
    d.valid_known_birth_flag
    AND d.delivery_outcome_final = 'MIXED_LIVE_STILLBIRTH'
    AS INT64
  ) AS mixed_live_stillbirth_count,

  CAST(
    d.valid_known_birth_flag
    AND d.delivery_outcome_final = 'DELIVERY_OUTCOME_UNCLEAR'
    AS INT64
  ) AS delivery_outcome_unclear_count,


  -- ============================================================
  -- ANC / PREGNANCY LINKAGE
  -- ============================================================

  CAST(
    d.successful_anc_link_flag
    AS INT64
  ) AS anc_linked_birth_count,

  CAST(
    d.no_anc_match_valid_birth_flag
    AS INT64
  ) AS no_anc_match_birth_count,

  CAST(
    d.ambiguous_anc_link_valid_birth_flag
    AS INT64
  ) AS ambiguous_anc_match_birth_count,

  CAST(
    d.date_implausible_anc_link_valid_birth_flag
    AS INT64
  ) AS anc_link_date_implausible_birth_count,

  CAST(
    d.not_successfully_linked_flag
    AS INT64
  ) AS not_successfully_linked_birth_count,


  -- Technical review event; not part of valid-known-birth denominator.
  CAST(
    d.anc_link_status = 'ANC_LINK_COLLISION_REJECTED'
    AS INT64
  ) AS collision_review_birth_count,


  -- ============================================================
  -- DATA-QUALITY COUNTERS
  -- ============================================================

  CAST(
    d.birth_validity_status = 'EXCLUDED_NO_MATERNAL_IDENTITY'
    AS INT64
  ) AS excluded_no_maternal_identity_count,

  CAST(
    d.birth_validity_status = 'EXCLUDED_FUTURE_DELIVERY_DATE'
    AS INT64
  ) AS excluded_future_delivery_date_count,

  CAST(
    d.birth_validity_status = 'EXCLUDED_TECHNICAL_EVENT'
    AS INT64
  ) AS excluded_technical_event_count,


  -- ============================================================
  -- VALID KNOWN-BIRTH SOURCE CAPTURE
  -- ============================================================

  CAST(
    d.valid_known_birth_flag
    AND d.has_delivery_sigizi
    AS INT64
  ) AS sigizi_all_birth_capture_count,

  CAST(
    d.valid_known_birth_flag
    AND d.has_delivery_epus
    AS INT64
  ) AS epus_all_birth_capture_count,

  CAST(
    d.valid_known_birth_flag
    AND d.has_delivery_simrs
    AS INT64
  ) AS simrs_all_birth_capture_count,

  CAST(
    d.valid_known_birth_flag
    AND d.has_delivery_kobo_inc
    AS INT64
  ) AS kobo_all_birth_capture_count,

  CAST(
    d.valid_known_birth_flag
    AND d.has_delivery_inc_report
    AS INT64
  ) AS inc_report_all_birth_capture_count,

  CAST(
    d.valid_known_birth_flag
    AND d.has_delivery_neonatal
    AS INT64
  ) AS neonatal_all_birth_capture_count

FROM
  `spheres-lombok-barat.kohort_bumil_v3.v_delivery_event_master_validated` d""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_pregnancy_monitoring_integrated
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_pregnancy_monitoring_integrated');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_pregnancy_monitoring_integrated';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_monitoring_integrated` AS SELECT ',
 projection, ' FROM (', r"""WITH accepted_delivery AS (

  SELECT *
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.v_delivery_event_master_validated`

  WHERE
    valid_known_birth_flag

    AND anc_link_status IN (
      'MATCHED_SIGIZI_EPUS',
      'MATCHED_SIGIZI_ONLY',
      'MATCHED_EPUS_ONLY',
      'MATCHED_ANC_OTHER'
    )
),


-- ============================================================================
-- BASE
--
-- IMPORTANT:
-- t_pregnancy_outcome_tracking_v3_3 ALREADY CONTAINS:
--
--   hpht_date
--   dating_usg_date
--   dating_usg_ga_weeks
--   dating_usg_ga_days
--   usg_dating_quality
--   usg_recorded_hpl_date
--   hpl_from_usg_ga_date
--
-- Therefore NO join to v_pregnancy_monitoring_integrated is needed.
-- ============================================================================

base AS (

  SELECT
    p.*,


    -- ========================================================================
    -- PREGNANCY-SOURCE MEMBERSHIP
    -- ========================================================================

    (
      p.pregnancy_source_combination IN (
        'SIGIZI ONLY',
        'SIGIZI + EPUS'
      )
    ) AS in_sigizi_pregnancy,

    (
      p.pregnancy_source_combination IN (
        'EPUS ONLY',
        'SIGIZI + EPUS'
      )
    ) AS in_epus_pregnancy,


    -- ========================================================================
    -- VALIDATED CANONICAL DELIVERY
    -- ========================================================================

    d.delivery_event_id
      AS integrated_delivery_event_id,

    d.delivery_date
      AS integrated_delivery_date,

    d.delivery_outcome_final
      AS integrated_delivery_outcome,

    d.delivery_source_combination
      AS integrated_delivery_source_combination,

    d.primary_delivery_source
      AS integrated_primary_delivery_source,

    d.has_delivery_sigizi
      AS integrated_has_delivery_sigizi,

    d.has_delivery_epus
      AS integrated_has_delivery_epus,

    d.has_delivery_simrs
      AS integrated_has_delivery_simrs,

    d.has_delivery_kobo_inc
      AS integrated_has_delivery_kobo_inc,

    d.has_delivery_neonatal
      AS integrated_has_delivery_neonatal,

    d.has_delivery_inc_report
      AS integrated_has_delivery_inc_report,

    d.sigizi_delivery_outcome,

    d.epus_delivery_outcome,

    d.delivery_date_conflict_flag
      AS integrated_delivery_date_conflict_flag,

    d.delivery_date_range_days
      AS integrated_delivery_date_range_days,

    d.delivery_qa_required
      AS integrated_delivery_qa_required,

    d.anc_link_method
      AS integrated_anc_link_method,

    d.anc_link_confidence
      AS integrated_anc_link_confidence

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_tracking_v3_3` p

  LEFT JOIN accepted_delivery d
    USING (pregnancy_episode_id)
),


-- ============================================================================
-- GESTATIONAL AGE AT DELIVERY
--
-- DATING HIERARCHY
--
-- 1. USG <=14 weeks
-- 2. USG >14–22 weeks
-- 3. Recorded USG EDD/HPL
-- 4. HPHT
-- 5. Late USG >22 weeks
-- 6. Unknown
-- ============================================================================

ga_calculated AS (

  SELECT
    *,


    -- ========================================================================
    -- GA AT DELIVERY — DAYS
    -- ========================================================================

    CASE

      -- ----------------------------------------------------------------------
      -- PRIORITY 1
      -- FIRST TRIMESTER / EARLY USG <=14 WEEKS
      -- ----------------------------------------------------------------------

      WHEN usg_dating_quality = 'EARLY_USG_LE_14W'

       AND dating_usg_date IS NOT NULL

       AND dating_usg_ga_days IS NOT NULL

       AND integrated_delivery_date IS NOT NULL

       AND integrated_delivery_date >= dating_usg_date

      THEN
        dating_usg_ga_days
        +
        DATE_DIFF(
          integrated_delivery_date,
          dating_usg_date,
          DAY
        )


      -- ----------------------------------------------------------------------
      -- PRIORITY 2
      -- USG >14 TO 22 WEEKS
      -- ----------------------------------------------------------------------

      WHEN usg_dating_quality = 'USG_14_22W'

       AND dating_usg_date IS NOT NULL

       AND dating_usg_ga_days IS NOT NULL

       AND integrated_delivery_date IS NOT NULL

       AND integrated_delivery_date >= dating_usg_date

      THEN
        dating_usg_ga_days
        +
        DATE_DIFF(
          integrated_delivery_date,
          dating_usg_date,
          DAY
        )


      -- ----------------------------------------------------------------------
      -- PRIORITY 3
      -- RECORDED USG EDD / HPL
      --
      -- At HPL/EDD = 40w0d = 280 days
      -- ----------------------------------------------------------------------

      WHEN usg_dating_quality =
             'RECORDED_USG_EDD_GA_UNKNOWN'

       AND usg_recorded_hpl_date IS NOT NULL

       AND integrated_delivery_date IS NOT NULL

      THEN
        280
        +
        DATE_DIFF(
          integrated_delivery_date,
          usg_recorded_hpl_date,
          DAY
        )


      -- ----------------------------------------------------------------------
      -- PRIORITY 4
      -- HPHT
      -- ----------------------------------------------------------------------

      WHEN hpht_date IS NOT NULL

       AND integrated_delivery_date IS NOT NULL

       AND integrated_delivery_date >= hpht_date

      THEN
        DATE_DIFF(
          integrated_delivery_date,
          hpht_date,
          DAY
        )


      -- ----------------------------------------------------------------------
      -- PRIORITY 5
      -- LATE USG >22 WEEKS
      -- ----------------------------------------------------------------------

      WHEN usg_dating_quality = 'LATE_USG_GT_22W'

       AND dating_usg_date IS NOT NULL

       AND dating_usg_ga_days IS NOT NULL

       AND integrated_delivery_date IS NOT NULL

       AND integrated_delivery_date >= dating_usg_date

      THEN
        dating_usg_ga_days
        +
        DATE_DIFF(
          integrated_delivery_date,
          dating_usg_date,
          DAY
        )


      ELSE NULL

    END AS gestational_age_at_delivery_days,


    -- ========================================================================
    -- GA SOURCE
    -- ========================================================================

    CASE

      WHEN usg_dating_quality = 'EARLY_USG_LE_14W'

       AND dating_usg_date IS NOT NULL

       AND dating_usg_ga_days IS NOT NULL

       AND integrated_delivery_date IS NOT NULL

       AND integrated_delivery_date >= dating_usg_date

        THEN 'USG_LE_14W'


      WHEN usg_dating_quality = 'USG_14_22W'

       AND dating_usg_date IS NOT NULL

       AND dating_usg_ga_days IS NOT NULL

       AND integrated_delivery_date IS NOT NULL

       AND integrated_delivery_date >= dating_usg_date

        THEN 'USG_14_22W'


      WHEN usg_dating_quality =
             'RECORDED_USG_EDD_GA_UNKNOWN'

       AND usg_recorded_hpl_date IS NOT NULL

       AND integrated_delivery_date IS NOT NULL

        THEN 'USG_RECORDED_EDD'


      WHEN hpht_date IS NOT NULL

       AND integrated_delivery_date IS NOT NULL

       AND integrated_delivery_date >= hpht_date

        THEN 'HPHT'


      WHEN usg_dating_quality = 'LATE_USG_GT_22W'

       AND dating_usg_date IS NOT NULL

       AND dating_usg_ga_days IS NOT NULL

       AND integrated_delivery_date IS NOT NULL

       AND integrated_delivery_date >= dating_usg_date

        THEN 'LATE_USG_GT_22W'


      ELSE 'UNKNOWN'

    END AS gestational_age_at_delivery_source

  FROM base
),


-- ============================================================================
-- GA CLASSIFICATION
-- ============================================================================

ga_classified AS (

  SELECT
    *,


    -- ========================================================================
    -- COMPLETED WEEKS
    -- ========================================================================

    CASE

      WHEN gestational_age_at_delivery_days IS NOT NULL

      THEN CAST(
        FLOOR(
          gestational_age_at_delivery_days / 7.0
        )
        AS INT64
      )

    END AS gestational_age_at_delivery_weeks,


    -- ========================================================================
    -- DECIMAL WEEKS
    -- ========================================================================

    CASE

      WHEN gestational_age_at_delivery_days IS NOT NULL

      THEN ROUND(
        gestational_age_at_delivery_days / 7.0,
        1
      )

    END AS gestational_age_at_delivery_weeks_decimal,


    -- ========================================================================
    -- REMAINING DAYS
    -- ========================================================================

    CASE

      WHEN gestational_age_at_delivery_days IS NOT NULL

      THEN MOD(
        gestational_age_at_delivery_days,
        7
      )

    END AS gestational_age_at_delivery_remaining_days,


    -- ========================================================================
    -- CATEGORY
    --
    -- <37w0d       = Preterm
    -- 37w0d–41w6d  = Aterm
    -- 42w0d–42w6d  = Post-term
    -- >=43w0d      = QA required
    -- ========================================================================

    CASE

      WHEN gestational_age_at_delivery_days IS NULL
        THEN 'Tidak Diketahui'

      WHEN gestational_age_at_delivery_days < 259
        THEN 'Preterm'

      WHEN gestational_age_at_delivery_days < 294
        THEN 'Aterm'

      WHEN gestational_age_at_delivery_days < 301
        THEN 'Post-term'

      ELSE 'GA Ekstrem / Perlu Validasi'

    END AS gestational_age_at_delivery_category,


    -- ========================================================================
    -- GA QUALITY
    -- ========================================================================

    CASE

      WHEN gestational_age_at_delivery_days IS NULL
        THEN 'Tidak Diketahui'

      WHEN gestational_age_at_delivery_days >= 301
        THEN 'Perlu Validasi: >=43 minggu'

      ELSE 'Dapat Digunakan'

    END AS gestational_age_at_delivery_quality_category,


    -- ========================================================================
    -- DATING SOURCE QUALITY
    -- ========================================================================

    CASE

      WHEN gestational_age_at_delivery_source =
             'USG_LE_14W'
        THEN 'TINGGI'

      WHEN gestational_age_at_delivery_source =
             'USG_14_22W'
        THEN 'SEDANG'

      WHEN gestational_age_at_delivery_source =
             'USG_RECORDED_EDD'
        THEN 'SEDANG'

      WHEN gestational_age_at_delivery_source =
             'HPHT'
        THEN 'SEDANG'

      WHEN gestational_age_at_delivery_source =
             'LATE_USG_GT_22W'
        THEN 'RENDAH'

      ELSE 'TIDAK TERSEDIA'

    END AS gestational_age_at_delivery_source_quality

  FROM ga_calculated
),


-- ============================================================================
-- CLASSIFIED 1
-- ============================================================================

classified_1 AS (

  SELECT
    *,

    integrated_delivery_event_id IS NOT NULL
      AS integrated_delivery_found_flag,


    -- ========================================================================
    -- QA FLAGS
    -- ========================================================================

    (
      integrated_delivery_event_id IS NOT NULL
      AND COALESCE(
        has_abortus_evidence,
        FALSE
      )
    ) AS integrated_abortus_delivery_conflict_flag,


    (
      actual_delivery_date IS NOT NULL
      AND integrated_delivery_event_id IS NULL
    ) AS legacy_delivery_not_accepted_flag,


    -- ========================================================================
    -- CANONICAL ALL-HISTORY MONITORING STATUS
    -- ========================================================================

    CASE

      WHEN integrated_delivery_event_id IS NOT NULL
        THEN 'DELIVERED'

      WHEN pregnancy_outcome_final = 'ABORTUS'
        THEN 'ABORTUS'

      WHEN actual_delivery_date IS NULL

       AND pregnancy_outcome_final IN (
         'LAHIR HIDUP',
         'LAHIR MATI',
         'CAMPURAN LAHIR HIDUP + LAHIR MATI',
         'DELIVERY DITEMUKAN - LUARAN BELUM JELAS'
       )

        THEN 'DELIVERED_DATE_UNKNOWN'

      WHEN expected_delivery_date IS NULL
        THEN 'DATE_UNKNOWN'

      WHEN expected_delivery_date
           < CURRENT_DATE('Asia/Makassar')
        THEN 'MISSING_BIRTH'

      ELSE 'ACTIVE_PREGNANCY'

    END AS integrated_monitoring_status_all_history,


    -- ========================================================================
    -- CANONICAL PREGNANCY OUTCOME
    -- ========================================================================

    CASE

      WHEN integrated_delivery_event_id IS NOT NULL
        THEN integrated_delivery_outcome

      WHEN pregnancy_outcome_final = 'ABORTUS'
        THEN 'ABORTUS'

      WHEN actual_delivery_date IS NULL
       AND pregnancy_outcome_final = 'LAHIR HIDUP'
        THEN 'LAHIR HIDUP'

      WHEN actual_delivery_date IS NULL
       AND pregnancy_outcome_final = 'LAHIR MATI'
        THEN 'LAHIR MATI'

      WHEN actual_delivery_date IS NULL
       AND pregnancy_outcome_final =
             'CAMPURAN LAHIR HIDUP + LAHIR MATI'
        THEN 'MIXED_LIVE_STILLBIRTH'

      WHEN actual_delivery_date IS NULL
       AND pregnancy_outcome_final =
             'DELIVERY DITEMUKAN - LUARAN BELUM JELAS'
        THEN 'DELIVERY_OUTCOME_UNCLEAR'

      ELSE NULL

    END AS integrated_pregnancy_outcome,


    -- ========================================================================
    -- SIGIZI MONITORING STATUS
    -- ========================================================================

    CASE

      WHEN NOT in_sigizi_pregnancy
        THEN 'NOT_IN_SIGIZI_PREGNANCY'

      WHEN integrated_delivery_event_id IS NOT NULL

       AND COALESCE(
             integrated_has_delivery_sigizi,
             FALSE
           )

        THEN 'DELIVERED_RECORDED_IN_SIGIZI'

      WHEN integrated_delivery_event_id IS NOT NULL

       AND NOT COALESCE(
                 integrated_has_delivery_sigizi,
                 FALSE
               )

        THEN 'MISSING_BIRTH_IN_SIGIZI'

      WHEN pregnancy_outcome_final = 'ABORTUS'
       AND abortion_source = 'SIGIZI'
        THEN 'ABORTUS_RECORDED_IN_SIGIZI'

      WHEN pregnancy_outcome_final = 'ABORTUS'

       AND COALESCE(
             abortion_source,
             ''
           ) != 'SIGIZI'

        THEN 'ABORTUS_KNOWN_EXTERNALLY'

      WHEN actual_delivery_date IS NULL

       AND pregnancy_outcome_final IN (
         'LAHIR HIDUP',
         'LAHIR MATI',
         'CAMPURAN LAHIR HIDUP + LAHIR MATI',
         'DELIVERY DITEMUKAN - LUARAN BELUM JELAS'
       )

        THEN 'DELIVERY_OUTCOME_KNOWN_DATE_UNKNOWN'

      WHEN expected_delivery_date IS NOT NULL

       AND expected_delivery_date
           < CURRENT_DATE('Asia/Makassar')

        THEN 'EXPECTED_BIRTH_NOT_FOUND_ANYWHERE'

      WHEN expected_delivery_date IS NOT NULL
        THEN 'ACTIVE_PREGNANCY'

      ELSE 'DATE_UNKNOWN'

    END AS sigizi_monitoring_status_all_history,


    -- ========================================================================
    -- EPUS MONITORING STATUS
    -- ========================================================================

    CASE

      WHEN NOT in_epus_pregnancy
        THEN 'NOT_IN_EPUS_PREGNANCY'

      WHEN integrated_delivery_event_id IS NOT NULL

       AND COALESCE(
             integrated_has_delivery_epus,
             FALSE
           )

        THEN 'DELIVERED_RECORDED_IN_EPUS'

      WHEN integrated_delivery_event_id IS NOT NULL

       AND NOT COALESCE(
                 integrated_has_delivery_epus,
                 FALSE
               )

        THEN 'MISSING_BIRTH_IN_EPUS'

      WHEN pregnancy_outcome_final = 'ABORTUS'
       AND abortion_source = 'EPUS'
        THEN 'ABORTUS_RECORDED_IN_EPUS'

      WHEN pregnancy_outcome_final = 'ABORTUS'

       AND COALESCE(
             abortion_source,
             ''
           ) != 'EPUS'

        THEN 'ABORTUS_KNOWN_EXTERNALLY'

      WHEN actual_delivery_date IS NULL

       AND pregnancy_outcome_final IN (
         'LAHIR HIDUP',
         'LAHIR MATI',
         'CAMPURAN LAHIR HIDUP + LAHIR MATI',
         'DELIVERY DITEMUKAN - LUARAN BELUM JELAS'
       )

        THEN 'DELIVERY_OUTCOME_KNOWN_DATE_UNKNOWN'

      WHEN expected_delivery_date IS NOT NULL

       AND expected_delivery_date
           < CURRENT_DATE('Asia/Makassar')

        THEN 'EXPECTED_BIRTH_NOT_FOUND_ANYWHERE'

      WHEN expected_delivery_date IS NOT NULL
        THEN 'ACTIVE_PREGNANCY'

      ELSE 'DATE_UNKNOWN'

    END AS epus_monitoring_status_all_history

  FROM ga_classified
),


-- ============================================================================
-- CLASSIFIED 2
-- ============================================================================

classified_2 AS (

  SELECT
    *,

    CASE

      WHEN NOT COALESCE(
                 pregnancy_date_valid_flag,
                 FALSE
               )
        THEN 'EXCLUDED_INVALID_PREGNANCY_DATE'

      WHEN NOT COALESCE(
                 monitoring_eligible_flag,
                 FALSE
               )
        THEN 'OUTSIDE_OPERATIONAL_MONITORING_WINDOW'

      ELSE integrated_monitoring_status_all_history

    END AS integrated_monitoring_status_operational,


    CASE

      WHEN NOT COALESCE(
                 monitoring_eligible_flag,
                 FALSE
               )
        THEN 'OUTSIDE_OPERATIONAL_MONITORING_WINDOW'

      ELSE sigizi_monitoring_status_all_history

    END AS sigizi_monitoring_status_operational,


    CASE

      WHEN NOT COALESCE(
                 monitoring_eligible_flag,
                 FALSE
               )
        THEN 'OUTSIDE_OPERATIONAL_MONITORING_WINDOW'

      ELSE epus_monitoring_status_all_history

    END AS epus_monitoring_status_operational

  FROM classified_1
)


-- ============================================================================
-- FINAL
-- ============================================================================

SELECT
  *,


  -- ==========================================================================
  -- BACKWARD-COMPATIBLE ALIASES
  -- ==========================================================================

  integrated_monitoring_status_all_history
    AS integrated_monitoring_status,

  sigizi_monitoring_status_all_history
    AS sigizi_monitoring_status,

  epus_monitoring_status_all_history
    AS epus_monitoring_status,


  -- ==========================================================================
  -- EXPECTED DELIVERY DATE DIMENSIONS
  -- ==========================================================================

  expected_delivery_date
    AS expected_delivery_day,

  DATE_TRUNC(
    expected_delivery_date,
    WEEK(MONDAY)
  ) AS expected_delivery_week,

  DATE_TRUNC(
    expected_delivery_date,
    MONTH
  ) AS expected_delivery_month_integrated,

  DATE_TRUNC(
    expected_delivery_date,
    QUARTER
  ) AS expected_delivery_quarter,

  DATE_TRUNC(
    expected_delivery_date,
    YEAR
  ) AS expected_delivery_year,


  -- ==========================================================================
  -- ACTUAL DELIVERY DATE DIMENSIONS
  -- ==========================================================================

  integrated_delivery_date
    AS actual_delivery_day_integrated,

  DATE_TRUNC(
    integrated_delivery_date,
    WEEK(MONDAY)
  ) AS actual_delivery_week_integrated,

  DATE_TRUNC(
    integrated_delivery_date,
    MONTH
  ) AS actual_delivery_month_integrated,

  DATE_TRUNC(
    integrated_delivery_date,
    QUARTER
  ) AS actual_delivery_quarter_integrated,

  DATE_TRUNC(
    integrated_delivery_date,
    YEAR
  ) AS actual_delivery_year_integrated,


  -- ==========================================================================
  -- GESTATIONAL AGE COUNTERS
  -- ==========================================================================

  CAST(
    integrated_delivery_event_id IS NOT NULL
    AS INT64
  ) AS ga_delivery_denominator_count,


  CAST(
    integrated_delivery_event_id IS NOT NULL
    AND gestational_age_at_delivery_days IS NOT NULL
    AS INT64
  ) AS ga_known_count,


  CAST(
    integrated_delivery_event_id IS NOT NULL
    AND gestational_age_at_delivery_days IS NULL
    AS INT64
  ) AS ga_unknown_count,


  CAST(
    integrated_delivery_event_id IS NOT NULL

    AND gestational_age_at_delivery_category IN (
      'Preterm',
      'Aterm',
      'Post-term'
    )

    AS INT64
  ) AS ga_usable_for_rate_count,


  -- ==========================================================================
  -- GA SOURCE COUNTERS
  -- ==========================================================================

  CAST(
    gestational_age_at_delivery_source IN (
      'USG_LE_14W',
      'USG_14_22W',
      'USG_RECORDED_EDD',
      'LATE_USG_GT_22W'
    )
    AS INT64
  ) AS ga_usg_based_count,


  CAST(
    gestational_age_at_delivery_source =
      'USG_LE_14W'
    AS INT64
  ) AS ga_early_usg_count,


  CAST(
    gestational_age_at_delivery_source =
      'USG_14_22W'
    AS INT64
  ) AS ga_mid_usg_count,


  CAST(
    gestational_age_at_delivery_source =
      'USG_RECORDED_EDD'
    AS INT64
  ) AS ga_usg_edd_count,


  CAST(
    gestational_age_at_delivery_source =
      'HPHT'
    AS INT64
  ) AS ga_hpht_count,


  CAST(
    gestational_age_at_delivery_source =
      'LATE_USG_GT_22W'
    AS INT64
  ) AS ga_late_usg_count,


  -- ==========================================================================
  -- GA CATEGORY COUNTERS
  -- ==========================================================================

  CAST(
    gestational_age_at_delivery_category =
      'Preterm'
    AS INT64
  ) AS preterm_delivery_count,


  CAST(
    gestational_age_at_delivery_category =
      'Aterm'
    AS INT64
  ) AS term_delivery_count,


  CAST(
    gestational_age_at_delivery_category =
      'Post-term'
    AS INT64
  ) AS postterm_delivery_count,


  CAST(
    gestational_age_at_delivery_category =
      'GA Ekstrem / Perlu Validasi'
    AS INT64
  ) AS ga_extreme_delivery_count,


  -- ==========================================================================
  -- ALL-HISTORY PREGNANCY COUNTERS
  -- ==========================================================================

  1 AS pregnancy_count,


  CAST(
    integrated_monitoring_status_all_history =
      'ACTIVE_PREGNANCY'
    AS INT64
  ) AS active_pregnancy_count,


  CAST(
    integrated_monitoring_status_all_history =
      'MISSING_BIRTH'
    AS INT64
  ) AS missing_birth_count_integrated,


  CAST(
    integrated_monitoring_status_all_history IN (
      'DELIVERED',
      'DELIVERED_DATE_UNKNOWN'
    )
    AS INT64
  ) AS delivered_pregnancy_count,


  CAST(
    integrated_monitoring_status_all_history =
      'DELIVERED'
    AS INT64
  ) AS delivered_with_date_count,


  CAST(
    integrated_monitoring_status_all_history =
      'DELIVERED_DATE_UNKNOWN'
    AS INT64
  ) AS delivered_date_unknown_count,


  CAST(
    integrated_pregnancy_outcome =
      'LAHIR HIDUP'
    AS INT64
  ) AS live_birth_pregnancy_count,


  CAST(
    integrated_pregnancy_outcome =
      'LAHIR MATI'
    AS INT64
  ) AS stillbirth_pregnancy_count,


  CAST(
    integrated_pregnancy_outcome =
      'MIXED_LIVE_STILLBIRTH'
    AS INT64
  ) AS mixed_live_stillbirth_pregnancy_count,


  CAST(
    integrated_pregnancy_outcome =
      'DELIVERY_OUTCOME_UNCLEAR'
    AS INT64
  ) AS delivery_outcome_unclear_pregnancy_count,


  CAST(
    integrated_pregnancy_outcome =
      'ABORTUS'
    AS INT64
  ) AS abortion_pregnancy_count,


  -- ==========================================================================
  -- OPERATIONAL COUNTERS
  -- ==========================================================================

  CAST(
    monitoring_eligible_flag
    AS INT64
  ) AS operational_pregnancy_count,


  CAST(
    monitoring_eligible_flag
    AND integrated_monitoring_status_all_history =
        'ACTIVE_PREGNANCY'
    AS INT64
  ) AS operational_active_pregnancy_count,


  CAST(
    monitoring_eligible_flag
    AND integrated_monitoring_status_all_history =
        'MISSING_BIRTH'
    AS INT64
  ) AS operational_missing_birth_count,


  CAST(
    monitoring_eligible_flag
    AND integrated_monitoring_status_all_history IN (
      'DELIVERED',
      'DELIVERED_DATE_UNKNOWN'
    )
    AS INT64
  ) AS operational_delivered_pregnancy_count,


  CAST(
    monitoring_eligible_flag
    AND integrated_pregnancy_outcome =
        'ABORTUS'
    AS INT64
  ) AS operational_abortion_pregnancy_count,


  -- ==========================================================================
  -- COHORT SOURCE COUNTERS
  -- ==========================================================================

  CAST(
    in_sigizi_pregnancy
    AS INT64
  ) AS sigizi_pregnancy_count,


  CAST(
    in_epus_pregnancy
    AS INT64
  ) AS epus_pregnancy_count,


  CAST(
    in_sigizi_pregnancy
    AND in_epus_pregnancy
    AS INT64
  ) AS sigizi_epus_pregnancy_count,


  -- ==========================================================================
  -- SIGIZI COMPLETENESS — ALL HISTORY
  -- ==========================================================================

  CAST(
    in_sigizi_pregnancy
    AND integrated_delivery_event_id IS NOT NULL
    AS INT64
  ) AS sigizi_known_pregnancy_birth_denominator_count,


  CAST(
    in_sigizi_pregnancy
    AND integrated_delivery_event_id IS NOT NULL
    AND COALESCE(
          integrated_has_delivery_sigizi,
          FALSE
        )
    AS INT64
  ) AS sigizi_known_pregnancy_birth_numerator_count,


  CAST(
    in_sigizi_pregnancy
    AND integrated_delivery_event_id IS NOT NULL
    AND NOT COALESCE(
              integrated_has_delivery_sigizi,
              FALSE
            )
    AS INT64
  ) AS sigizi_missing_birth_in_source_count,


  -- ==========================================================================
  -- EPUS COMPLETENESS — ALL HISTORY
  -- ==========================================================================

  CAST(
    in_epus_pregnancy
    AND integrated_delivery_event_id IS NOT NULL
    AS INT64
  ) AS epus_known_pregnancy_birth_denominator_count,


  CAST(
    in_epus_pregnancy
    AND integrated_delivery_event_id IS NOT NULL
    AND COALESCE(
          integrated_has_delivery_epus,
          FALSE
        )
    AS INT64
  ) AS epus_known_pregnancy_birth_numerator_count,


  CAST(
    in_epus_pregnancy
    AND integrated_delivery_event_id IS NOT NULL
    AND NOT COALESCE(
              integrated_has_delivery_epus,
              FALSE
            )
    AS INT64
  ) AS epus_missing_birth_in_source_count,


  -- ==========================================================================
  -- SIGIZI COMPLETENESS — OPERATIONAL
  -- ==========================================================================

  CAST(
    monitoring_eligible_flag
    AND in_sigizi_pregnancy
    AND integrated_delivery_event_id IS NOT NULL
    AS INT64
  ) AS sigizi_operational_birth_denominator_count,


  CAST(
    monitoring_eligible_flag
    AND in_sigizi_pregnancy
    AND integrated_delivery_event_id IS NOT NULL
    AND COALESCE(
          integrated_has_delivery_sigizi,
          FALSE
        )
    AS INT64
  ) AS sigizi_operational_birth_numerator_count,


  CAST(
    monitoring_eligible_flag
    AND in_sigizi_pregnancy
    AND integrated_delivery_event_id IS NOT NULL
    AND NOT COALESCE(
              integrated_has_delivery_sigizi,
              FALSE
            )
    AS INT64
  ) AS sigizi_operational_missing_birth_in_source_count,


  -- ==========================================================================
  -- EPUS COMPLETENESS — OPERATIONAL
  -- ==========================================================================

  CAST(
    monitoring_eligible_flag
    AND in_epus_pregnancy
    AND integrated_delivery_event_id IS NOT NULL
    AS INT64
  ) AS epus_operational_birth_denominator_count,


  CAST(
    monitoring_eligible_flag
    AND in_epus_pregnancy
    AND integrated_delivery_event_id IS NOT NULL
    AND COALESCE(
          integrated_has_delivery_epus,
          FALSE
        )
    AS INT64
  ) AS epus_operational_birth_numerator_count,


  CAST(
    monitoring_eligible_flag
    AND in_epus_pregnancy
    AND integrated_delivery_event_id IS NOT NULL
    AND NOT COALESCE(
              integrated_has_delivery_epus,
              FALSE
            )
    AS INT64
  ) AS epus_operational_missing_birth_in_source_count


FROM classified_2""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_birth_capture_step_wedge_daily
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_birth_capture_step_wedge_daily');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_birth_capture_step_wedge_daily';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_birth_capture_step_wedge_daily` AS SELECT ',
 projection, ' FROM (', r"""WITH params AS (

  SELECT
    CURRENT_DATE('Asia/Makassar') AS analysis_date
),

-- =============================================================================
-- PREGNANCY BASE
-- =============================================================================

pregnancy_base AS (

  SELECT
    p.pregnancy_episode_id,

    p.expected_delivery_date,

    DATE_TRUNC(
      p.expected_delivery_date,
      WEEK(MONDAY)
    ) AS expected_delivery_week,

    DATE_TRUNC(
      p.expected_delivery_date,
      MONTH
    ) AS expected_delivery_month,

    p.puskesmas,
    p.puskesmas_norm,

    p.desa,
    p.desa_norm,

    p.posyandu,

    p.pregnancy_source_combination,

    p.monitoring_eligible_flag,

    p.integrated_delivery_found_flag,

    p.integrated_monitoring_status_all_history
      AS monitoring_status_all_history,

    prm.analysis_date,


    -- =========================================================================
    -- NORMALIZED PUSKESMAS KEY
    -- =========================================================================

    CASE

      -- -----------------------------------------------------------------------
      -- GUNUNGSARI
      -- -----------------------------------------------------------------------

      WHEN REGEXP_REPLACE(
        UPPER(
          TRIM(
            REGEXP_REPLACE(
              COALESCE(
                p.puskesmas_norm,
                p.puskesmas,
                ''
              ),
              r'\s+',
              ' '
            )
          )
        ),
        r'^(PUSKESMAS|PKM)\s+',
        ''
      ) IN (
        'GUNUNG SARI',
        'GUNUNGSARI'
      )
        THEN 'GUNUNGSARI'


      -- -----------------------------------------------------------------------
      -- LABUAPI
      -- -----------------------------------------------------------------------

      WHEN REGEXP_REPLACE(
        UPPER(
          TRIM(
            REGEXP_REPLACE(
              COALESCE(
                p.puskesmas_norm,
                p.puskesmas,
                ''
              ),
              r'\s+',
              ' '
            )
          )
        ),
        r'^(PUSKESMAS|PKM)\s+',
        ''
      ) IN (
        'LABU API',
        'LABUAPI'
      )
        THEN 'LABUAPI'


      -- -----------------------------------------------------------------------
      -- DASAN TAPEN
      -- -----------------------------------------------------------------------

      WHEN REGEXP_REPLACE(
        UPPER(
          TRIM(
            REGEXP_REPLACE(
              COALESCE(
                p.puskesmas_norm,
                p.puskesmas,
                ''
              ),
              r'\s+',
              ' '
            )
          )
        ),
        r'^(PUSKESMAS|PKM)\s+',
        ''
      ) IN (
        'DASANTAPEN',
        'DASAN TAPEN'
      )
        THEN 'DASAN TAPEN'


      -- -----------------------------------------------------------------------
      -- EYAT MAYANG
      -- -----------------------------------------------------------------------

      WHEN REGEXP_REPLACE(
        UPPER(
          TRIM(
            REGEXP_REPLACE(
              COALESCE(
                p.puskesmas_norm,
                p.puskesmas,
                ''
              ),
              r'\s+',
              ' '
            )
          )
        ),
        r'^(PUSKESMAS|PKM)\s+',
        ''
      ) IN (
        'EYATMAYANG',
        'EYAT MAYANG'
      )
        THEN 'EYAT MAYANG'


      -- -----------------------------------------------------------------------
      -- JEMBATAN KEMBAR
      -- -----------------------------------------------------------------------

      WHEN REGEXP_REPLACE(
        UPPER(
          TRIM(
            REGEXP_REPLACE(
              COALESCE(
                p.puskesmas_norm,
                p.puskesmas,
                ''
              ),
              r'\s+',
              ' '
            )
          )
        ),
        r'^(PUSKESMAS|PKM)\s+',
        ''
      ) IN (
        'JEMBATANKEMBAR',
        'JEMBATAN KEMBAR'
      )
        THEN 'JEMBATAN KEMBAR'


      -- -----------------------------------------------------------------------
      -- ALL OTHER PUSKESMAS
      -- -----------------------------------------------------------------------

      ELSE REGEXP_REPLACE(
        UPPER(
          TRIM(
            REGEXP_REPLACE(
              COALESCE(
                p.puskesmas_norm,
                p.puskesmas,
                ''
              ),
              r'\s+',
              ' '
            )
          )
        ),
        r'^(PUSKESMAS|PKM)\s+',
        ''
      )

    END AS puskesmas_key

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_monitoring_integrated` p

  CROSS JOIN params prm

  WHERE
    p.expected_delivery_date IS NOT NULL

    AND p.monitoring_eligible_flag
),

-- =============================================================================
-- STUDY-GROUP CLASSIFICATION
-- =============================================================================

classified AS (

  SELECT
    b.*,

    -- -------------------------------------------------------------------------
    -- GROUP LABEL
    -- -------------------------------------------------------------------------

    CASE
      WHEN r.puskesmas_key IS NOT NULL
        THEN r.step_wedge_group

      WHEN COALESCE(
        TRIM(b.puskesmas_key),
        ''
      ) = ''
        THEN 'Unknown Puskesmas'

      WHEN b.puskesmas_key = 'BANI-BANI'
        THEN 'Outside Lombok Barat / Verify'

      ELSE 'UNMAPPED / VERIFY'
    END AS step_wedge_group,


    -- -------------------------------------------------------------------------
    -- GROUP ORDER
    -- -------------------------------------------------------------------------

    CASE
      WHEN r.puskesmas_key IS NOT NULL
        THEN r.step_wedge_order

      ELSE 99
    END AS step_wedge_order,


    r.intervention_date,


    -- -------------------------------------------------------------------------
    -- CHART ELIGIBILITY
    --
    -- TRUE only for officially mapped Lombok Barat Puskesmas.
    -- -------------------------------------------------------------------------

    r.puskesmas_key IS NOT NULL
      AS step_wedge_chart_eligible_flag,


    -- -------------------------------------------------------------------------
    -- LOCATION QA STATUS
    -- -------------------------------------------------------------------------

    CASE
      WHEN r.puskesmas_key IS NOT NULL
        THEN 'MAPPED'

      WHEN COALESCE(
        TRIM(b.puskesmas_key),
        ''
      ) = ''
        THEN 'MISSING_PUSKESMAS'

      WHEN b.puskesmas_key = 'BANI-BANI'
        THEN 'OUTSIDE_LOMBOK_BARAT_OR_INVALID'

      ELSE 'UNMAPPED_PUSKESMAS'
    END AS puskesmas_mapping_status

  FROM pregnancy_base b

  LEFT JOIN
    `spheres-lombok-barat.kohort_bumil_v3.ref_step_wedge_lombok_barat` r

    USING (puskesmas_key)
),

-- =============================================================================
-- DAILY HPL COHORT
--
-- Only officially mapped study groups are included.
-- =============================================================================

daily AS (

  SELECT
    expected_delivery_date,

    step_wedge_group,

    step_wedge_order,

    intervention_date,

    analysis_date,


    -- =========================================================================
    -- DENOMINATOR
    --
    -- Expected to have delivered:
    --   HPL strictly before today
    --   monitoring eligible
    --   abortion excluded
    -- =========================================================================

    COUNTIF(

      expected_delivery_date < analysis_date

      AND COALESCE(
        monitoring_status_all_history,
        ''
      ) != 'ABORTUS'

    ) AS daily_expected_pregnancies,


    -- =========================================================================
    -- NUMERATOR
    --
    -- Same population as denominator
    -- AND birth evidence has been found.
    -- =========================================================================

    COUNTIF(

      expected_delivery_date < analysis_date

      AND COALESCE(
        monitoring_status_all_history,
        ''
      ) != 'ABORTUS'

      AND (

        COALESCE(
          integrated_delivery_found_flag,
          FALSE
        )

        OR monitoring_status_all_history
             = 'DELIVERED_DATE_UNKNOWN'

      )

    ) AS daily_births_found

  FROM classified

  WHERE
    step_wedge_chart_eligible_flag

  GROUP BY
    expected_delivery_date,
    step_wedge_group,
    step_wedge_order,
    intervention_date,
    analysis_date
),

-- =============================================================================
-- DATE BOUNDS
-- =============================================================================

bounds AS (

  SELECT

    MIN(
      expected_delivery_date
    ) AS min_date,

    LEAST(

      MAX(
        expected_delivery_date
      ),

      DATE_SUB(
        MAX(analysis_date),
        INTERVAL 1 DAY
      )

    ) AS max_date

  FROM daily
),

-- =============================================================================
-- COMPLETE DAILY CALENDAR
-- =============================================================================

calendar AS (

  SELECT
    calendar_date

  FROM bounds,

  UNNEST(
    GENERATE_DATE_ARRAY(
      min_date,
      max_date
    )
  ) AS calendar_date
),

-- =============================================================================
-- OFFICIAL GROUP LIST
--
-- Do not name this CTE "groups":
-- GROUPS is a reserved keyword in BigQuery.
-- =============================================================================

step_wedge_groups AS (

  SELECT
    step_wedge_group,

    step_wedge_order,

    MAX(
      intervention_date
    ) AS intervention_date

  FROM classified

  WHERE
    step_wedge_chart_eligible_flag

  GROUP BY
    step_wedge_group,
    step_wedge_order
),

-- =============================================================================
-- COMPLETE DATE × GROUP GRID
--
-- This guarantees one row for every calendar day per group.
--
-- It is important for:
--   7-day rolling windows
--   30-day rolling windows
-- =============================================================================

complete_calendar AS (

  SELECT

    c.calendar_date
      AS expected_delivery_date,

    g.step_wedge_group,

    g.step_wedge_order,

    g.intervention_date,

    COALESCE(
      d.daily_expected_pregnancies,
      0
    ) AS daily_expected_pregnancies,

    COALESCE(
      d.daily_births_found,
      0
    ) AS daily_births_found

  FROM calendar c

  CROSS JOIN step_wedge_groups g

  LEFT JOIN daily d

    ON c.calendar_date
       = d.expected_delivery_date

   AND g.step_wedge_group
       = d.step_wedge_group
),

-- =============================================================================
-- ROLLING + MONTHLY WINDOWS
-- =============================================================================

rolling AS (

  SELECT
    *,


    -- =========================================================================
    -- 7-DAY ROLLING DENOMINATOR
    -- =========================================================================

    SUM(
      daily_expected_pregnancies
    ) OVER (

      PARTITION BY
        step_wedge_group

      ORDER BY
        expected_delivery_date

      ROWS BETWEEN
        6 PRECEDING
        AND CURRENT ROW

    ) AS expected_pregnancies_7d,


    -- =========================================================================
    -- 7-DAY ROLLING NUMERATOR
    -- =========================================================================

    SUM(
      daily_births_found
    ) OVER (

      PARTITION BY
        step_wedge_group

      ORDER BY
        expected_delivery_date

      ROWS BETWEEN
        6 PRECEDING
        AND CURRENT ROW

    ) AS births_found_7d,


    -- =========================================================================
    -- 30-DAY ROLLING DENOMINATOR
    -- =========================================================================

    SUM(
      daily_expected_pregnancies
    ) OVER (

      PARTITION BY
        step_wedge_group

      ORDER BY
        expected_delivery_date

      ROWS BETWEEN
        29 PRECEDING
        AND CURRENT ROW

    ) AS expected_pregnancies_30d,


    -- =========================================================================
    -- 30-DAY ROLLING NUMERATOR
    -- =========================================================================

    SUM(
      daily_births_found
    ) OVER (

      PARTITION BY
        step_wedge_group

      ORDER BY
        expected_delivery_date

      ROWS BETWEEN
        29 PRECEDING
        AND CURRENT ROW

    ) AS births_found_30d,


    -- =========================================================================
    -- CUMULATIVE DENOMINATOR
    -- =========================================================================

    SUM(
      daily_expected_pregnancies
    ) OVER (

      PARTITION BY
        step_wedge_group

      ORDER BY
        expected_delivery_date

      ROWS BETWEEN
        UNBOUNDED PRECEDING
        AND CURRENT ROW

    ) AS expected_pregnancies_cumulative,


    -- =========================================================================
    -- CUMULATIVE NUMERATOR
    -- =========================================================================

    SUM(
      daily_births_found
    ) OVER (

      PARTITION BY
        step_wedge_group

      ORDER BY
        expected_delivery_date

      ROWS BETWEEN
        UNBOUNDED PRECEDING
        AND CURRENT ROW

    ) AS births_found_cumulative,


    -- =========================================================================
    -- TRUE MONTHLY DENOMINATOR
    --
    -- Total pregnancies with HPL in that calendar month.
    -- =========================================================================

    SUM(
      daily_expected_pregnancies
    ) OVER (

      PARTITION BY
        step_wedge_group,

        DATE_TRUNC(
          expected_delivery_date,
          MONTH
        )

    ) AS expected_pregnancies_month,


    -- =========================================================================
    -- TRUE MONTHLY NUMERATOR
    -- =========================================================================

    SUM(
      daily_births_found
    ) OVER (

      PARTITION BY
        step_wedge_group,

        DATE_TRUNC(
          expected_delivery_date,
          MONTH
        )

    ) AS births_found_month,


    -- =========================================================================
    -- MONTH ANCHOR DATE
    --
    -- Gives one selected daily row per group × month.
    --
    -- Completed month:
    --   normally last calendar date in month.
    --
    -- Current partial month:
    --   latest available date.
    -- =========================================================================

    MAX(
      expected_delivery_date
    ) OVER (

      PARTITION BY
        step_wedge_group,

        DATE_TRUNC(
          expected_delivery_date,
          MONTH
        )

    ) AS month_anchor_date

  FROM complete_calendar
),

-- =============================================================================
-- INTERVENTION MARKER DATES
-- =============================================================================

marker_dates AS (

  SELECT

    MAX(
      IF(
        step_wedge_group = 'Step Wedge 1',
        intervention_date,
        NULL
      )
    ) AS step_wedge_1_date,


    MAX(
      IF(
        step_wedge_group = 'Step Wedge 2',
        intervention_date,
        NULL
      )
    ) AS step_wedge_2_date,


    MAX(
      IF(
        step_wedge_group = 'Step Wedge 3',
        intervention_date,
        NULL
      )
    ) AS step_wedge_3_date

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.ref_step_wedge_lombok_barat`
)

-- =============================================================================
-- FINAL LOOKER-READY OUTPUT
-- =============================================================================

SELECT

  -- ===========================================================================
  -- DAILY DATE
  -- ===========================================================================

  r.expected_delivery_date,


  -- ===========================================================================
  -- WEEK
  -- ===========================================================================

  DATE_TRUNC(
    r.expected_delivery_date,
    WEEK(MONDAY)
  ) AS expected_delivery_week,


  -- ===========================================================================
  -- MONTH
  -- ===========================================================================

  DATE_TRUNC(
    r.expected_delivery_date,
    MONTH
  ) AS expected_delivery_month,


  FORMAT_DATE(
    '%b %Y',
    DATE_TRUNC(
      r.expected_delivery_date,
      MONTH
    )
  ) AS expected_delivery_month_label,


  -- ===========================================================================
  -- MONTH ANCHOR
  --
  -- Filter month_anchor_flag = 1 for a monthly chart.
  -- ===========================================================================

  r.month_anchor_date,

  CAST(
    r.expected_delivery_date
      = r.month_anchor_date
    AS INT64
  ) AS month_anchor_flag,


  -- ===========================================================================
  -- QUARTER
  -- ===========================================================================

  DATE_TRUNC(
    r.expected_delivery_date,
    QUARTER
  ) AS expected_delivery_quarter,


  -- ===========================================================================
  -- YEAR
  -- ===========================================================================

  EXTRACT(
    YEAR
    FROM r.expected_delivery_date
  ) AS expected_delivery_year,


  -- ===========================================================================
  -- GROUP
  -- ===========================================================================

  r.step_wedge_group,

  r.step_wedge_order,

  r.intervention_date,


  -- ===========================================================================
  -- DAILY COUNTERS
  -- ===========================================================================

  r.daily_expected_pregnancies,

  r.daily_births_found,


  -- ===========================================================================
  -- 7-DAY COUNTERS
  -- ===========================================================================

  r.expected_pregnancies_7d,

  r.births_found_7d,


  -- ===========================================================================
  -- 30-DAY COUNTERS
  -- ===========================================================================

  r.expected_pregnancies_30d,

  r.births_found_30d,


  -- ===========================================================================
  -- MONTHLY COUNTERS
  -- ===========================================================================

  r.expected_pregnancies_month,

  r.births_found_month,


  -- ===========================================================================
  -- CUMULATIVE COUNTERS
  -- ===========================================================================

  r.expected_pregnancies_cumulative,

  r.births_found_cumulative,


  -- ===========================================================================
  -- DAILY COMPLETENESS
  -- ===========================================================================

  SAFE_DIVIDE(
    r.daily_births_found,
    r.daily_expected_pregnancies
  ) AS completeness_daily,


  -- ===========================================================================
  -- 7-DAY ROLLING COMPLETENESS
  -- ===========================================================================

  SAFE_DIVIDE(
    r.births_found_7d,
    r.expected_pregnancies_7d
  ) AS completeness_7d,


  -- ===========================================================================
  -- 30-DAY ROLLING COMPLETENESS
  --
  -- Recommended for DAILY trend chart.
  -- ===========================================================================

  SAFE_DIVIDE(
    r.births_found_30d,
    r.expected_pregnancies_30d
  ) AS completeness_30d,


  -- ===========================================================================
  -- TRUE MONTHLY COMPLETENESS
  --
  -- Recommended for MONTHLY trend chart.
  --
  -- Use together with:
  --   month_anchor_flag = 1
  -- ===========================================================================

  SAFE_DIVIDE(
    r.births_found_month,
    r.expected_pregnancies_month
  ) AS completeness_monthly,


  -- ===========================================================================
  -- CUMULATIVE COMPLETENESS
  -- ===========================================================================

  SAFE_DIVIDE(
    r.births_found_cumulative,
    r.expected_pregnancies_cumulative
  ) AS completeness_cumulative,


  -- ===========================================================================
  -- INTERVENTION STATUS
  -- ===========================================================================

  CASE

    WHEN r.step_wedge_group = 'Flagship'
      THEN 'BASELINE / OUTSIDE RANDOMIZATION'


    WHEN r.step_wedge_group = 'Non-Interventions'
      THEN 'NON-INTERVENTION'


    WHEN r.intervention_date IS NULL
      THEN 'INTERVENTION DATE MISSING'


    WHEN r.expected_delivery_date
         < r.intervention_date
      THEN 'PRE-INTERVENTION'


    ELSE 'POST-INTERVENTION'

  END AS intervention_status,


  -- ===========================================================================
  -- INTERVENTION MARKER — STEP WEDGE 1
  -- ===========================================================================

  IF(
    r.expected_delivery_date
      = m.step_wedge_1_date,
    1.0,
    NULL
  ) AS step_wedge_1_marker,


  -- ===========================================================================
  -- INTERVENTION MARKER — STEP WEDGE 2
  -- ===========================================================================

  IF(
    r.expected_delivery_date
      = m.step_wedge_2_date,
    1.0,
    NULL
  ) AS step_wedge_2_marker,


  -- ===========================================================================
  -- INTERVENTION MARKER — STEP WEDGE 3
  -- ===========================================================================

  IF(
    r.expected_delivery_date
      = m.step_wedge_3_date,
    1.0,
    NULL
  ) AS step_wedge_3_marker

FROM rolling r

CROSS JOIN marker_dates m""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_birth_outcome_event_dashboard
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_birth_outcome_event_dashboard');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_birth_outcome_event_dashboard';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_birth_outcome_event_dashboard` AS SELECT ',
 projection, ' FROM (', r"""WITH

-- ============================================================================
-- 1. CANONICAL DELIVERY EVENTS
--    One row = one strict canonical delivery event
-- ============================================================================

delivery_raw AS (

  SELECT

    -- ------------------------------------------------------------------------
    -- EVENT IDENTITY
    -- ------------------------------------------------------------------------
    d.delivery_event_id AS outcome_event_id,

    'DELIVERY' AS event_type,

    d.pregnancy_episode_id,

    d.delivery_date AS outcome_event_date,

    DATE_TRUNC(
      d.delivery_date,
      MONTH
    ) AS outcome_month,


    -- ------------------------------------------------------------------------
    -- EXPECTED DELIVERY DATE / HPL
    -- ------------------------------------------------------------------------
    p.expected_delivery_date,


    -- ------------------------------------------------------------------------
    -- DASHBOARD LOCATION
    -- ------------------------------------------------------------------------
    COALESCE(
      p.puskesmas,
      d.puskesmas
    ) AS dashboard_puskesmas,

    COALESCE(
      p.desa,
      d.desa
    ) AS dashboard_desa,

    p.posyandu AS dashboard_posyandu,

    p.puskesmas AS pregnancy_puskesmas,

    p.desa AS pregnancy_desa,

    d.puskesmas AS delivery_puskesmas,

    d.desa AS delivery_desa,


    -- ------------------------------------------------------------------------
    -- SOURCE
    -- ------------------------------------------------------------------------
    p.pregnancy_source_combination,

    d.delivery_source_combination,

    d.primary_delivery_source,

    d.delivery_source_combination
      AS event_source_combination,


    -- ------------------------------------------------------------------------
    -- LINKAGE
    -- ------------------------------------------------------------------------
    d.anc_link_status AS linkage_status,

    d.anc_link_method AS linkage_method,

    d.anc_link_confidence AS linkage_confidence,


    -- ------------------------------------------------------------------------
    -- DELIVERY OUTCOME
    -- ------------------------------------------------------------------------
    d.delivery_outcome_final
      AS delivery_outcome_raw,


    -- ------------------------------------------------------------------------
    -- DELIVERY MODE
    -- ------------------------------------------------------------------------
    p.delivery_mode_final
      AS delivery_mode_raw,

    p.delivery_mode_source
      AS delivery_mode_source,


    -- ------------------------------------------------------------------------
    -- PREGNANCY DATING INPUTS
    -- ------------------------------------------------------------------------
    p.hpht_date,

    p.dating_usg_date,

    p.dating_usg_ga_weeks,

    p.dating_usg_ga_days,

    p.usg_dating_quality,

    p.usg_recorded_hpl_date,

    p.hpl_from_usg_ga_date

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_v3` d

  LEFT JOIN
    `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_monitoring_integrated` p

    ON d.pregnancy_episode_id = p.pregnancy_episode_id

  WHERE
    d.strict_birth_count_eligible_flag = TRUE
),


-- ============================================================================
-- 2. OUTCOME + DELIVERY MODE + GA AT BIRTH
--
-- SELECTED GA PRIORITY
--
-- 1. USG <=14 weeks
-- 2. USG >14 to 22 weeks
-- 3. Recorded USG EDD/HPL
-- 4. HPHT
-- 5. Late USG >22 weeks
-- 6. Unknown
--
-- In addition to the selected GA, this CTE independently calculates:
--
--   A. GA from USG
--   B. GA from HPHT
--
-- This permits a true paired USG-vs-HPHT comparison.
-- ============================================================================

delivery_with_ga AS (

  SELECT
    *,


    -- ------------------------------------------------------------------------
    -- OUTCOME CATEGORY
    -- ------------------------------------------------------------------------
    CASE

      WHEN delivery_outcome_raw = 'LAHIR HIDUP'
        THEN 'Lahir Hidup'

      WHEN delivery_outcome_raw = 'LAHIR MATI'
        THEN 'Lahir Mati'

      WHEN delivery_outcome_raw = 'MIXED_LIVE_STILLBIRTH'
        THEN 'Campuran Lahir Hidup + Lahir Mati'

      ELSE 'Luaran Belum Diketahui'

    END AS outcome_category,


    -- ------------------------------------------------------------------------
    -- DELIVERY MODE CATEGORY
    -- ------------------------------------------------------------------------
    CASE

      WHEN delivery_mode_raw IS NULL
        THEN 'Tidak Diketahui'

      WHEN TRIM(delivery_mode_raw) = ''
        THEN 'Tidak Diketahui'

      WHEN UPPER(TRIM(delivery_mode_raw)) IN (
        '-',
        'UNKNOWN',
        'TIDAK DIKETAHUI',
        'NA',
        'N/A',
        'NULL'
      )
        THEN 'Tidak Diketahui'


      WHEN REGEXP_CONTAINS(
        UPPER(delivery_mode_raw),
        r'(^|[^A-Z])(SC|SECTIO|SEKSIO|CESAR|CAESAR|CESAREAN|C-?SECTION)([^A-Z]|$)'
      )
        THEN 'Seksio Sesarea'


      WHEN REGEXP_CONTAINS(
        UPPER(delivery_mode_raw),
        r'(VAKUM|VACUUM|FORCEPS|EKSTRAKSI)'
      )
        THEN 'Vaginal dengan Tindakan'


      WHEN REGEXP_CONTAINS(
        UPPER(delivery_mode_raw),
        r'(PERVAGINAM|PER VAGINAM|VAGINAL|SPONTAN|NORMAL)'
      )
        THEN 'Pervaginam'


      ELSE 'Lainnya'

    END AS delivery_mode_category,


    -- ========================================================================
    -- SELECTED / CANONICAL GA AT BIRTH
    -- ========================================================================

    CASE

      -- ----------------------------------------------------------------------
      -- PRIORITY 1: EARLY USG <=14 WEEKS
      -- ----------------------------------------------------------------------
      WHEN usg_dating_quality = 'EARLY_USG_LE_14W'
       AND dating_usg_date IS NOT NULL
       AND dating_usg_ga_days IS NOT NULL
       AND outcome_event_date IS NOT NULL
       AND outcome_event_date >= dating_usg_date

      THEN
        dating_usg_ga_days
        +
        DATE_DIFF(
          outcome_event_date,
          dating_usg_date,
          DAY
        )


      -- ----------------------------------------------------------------------
      -- PRIORITY 2: USG 14–22 WEEKS
      -- ----------------------------------------------------------------------
      WHEN usg_dating_quality = 'USG_14_22W'
       AND dating_usg_date IS NOT NULL
       AND dating_usg_ga_days IS NOT NULL
       AND outcome_event_date IS NOT NULL
       AND outcome_event_date >= dating_usg_date

      THEN
        dating_usg_ga_days
        +
        DATE_DIFF(
          outcome_event_date,
          dating_usg_date,
          DAY
        )


      -- ----------------------------------------------------------------------
      -- PRIORITY 3: RECORDED USG EDD
      -- ----------------------------------------------------------------------
      WHEN usg_dating_quality = 'RECORDED_USG_EDD_GA_UNKNOWN'
       AND usg_recorded_hpl_date IS NOT NULL
       AND outcome_event_date IS NOT NULL

      THEN
        280
        +
        DATE_DIFF(
          outcome_event_date,
          usg_recorded_hpl_date,
          DAY
        )


      -- ----------------------------------------------------------------------
      -- PRIORITY 4: HPHT
      -- ----------------------------------------------------------------------
      WHEN hpht_date IS NOT NULL
       AND outcome_event_date IS NOT NULL
       AND outcome_event_date >= hpht_date

      THEN
        DATE_DIFF(
          outcome_event_date,
          hpht_date,
          DAY
        )


      -- ----------------------------------------------------------------------
      -- PRIORITY 5: LATE USG
      -- ----------------------------------------------------------------------
      WHEN usg_dating_quality = 'LATE_USG_GT_22W'
       AND dating_usg_date IS NOT NULL
       AND dating_usg_ga_days IS NOT NULL
       AND outcome_event_date IS NOT NULL
       AND outcome_event_date >= dating_usg_date

      THEN
        dating_usg_ga_days
        +
        DATE_DIFF(
          outcome_event_date,
          dating_usg_date,
          DAY
        )


      ELSE NULL

    END AS gestational_age_days,


    -- ========================================================================
    -- SELECTED GA SOURCE
    -- ========================================================================

    CASE

      WHEN usg_dating_quality = 'EARLY_USG_LE_14W'
       AND dating_usg_date IS NOT NULL
       AND dating_usg_ga_days IS NOT NULL
       AND outcome_event_date IS NOT NULL
       AND outcome_event_date >= dating_usg_date

        THEN 'USG_LE_14W'


      WHEN usg_dating_quality = 'USG_14_22W'
       AND dating_usg_date IS NOT NULL
       AND dating_usg_ga_days IS NOT NULL
       AND outcome_event_date IS NOT NULL
       AND outcome_event_date >= dating_usg_date

        THEN 'USG_14_22W'


      WHEN usg_dating_quality = 'RECORDED_USG_EDD_GA_UNKNOWN'
       AND usg_recorded_hpl_date IS NOT NULL
       AND outcome_event_date IS NOT NULL

        THEN 'USG_RECORDED_EDD'


      WHEN hpht_date IS NOT NULL
       AND outcome_event_date IS NOT NULL
       AND outcome_event_date >= hpht_date

        THEN 'HPHT'


      WHEN usg_dating_quality = 'LATE_USG_GT_22W'
       AND dating_usg_date IS NOT NULL
       AND dating_usg_ga_days IS NOT NULL
       AND outcome_event_date IS NOT NULL
       AND outcome_event_date >= dating_usg_date

        THEN 'LATE_USG_GT_22W'


      ELSE 'UNKNOWN'

    END AS gestational_age_source,


    -- ========================================================================
    -- INDEPENDENT USG GA
    --
    -- IMPORTANT:
    -- Unlike selected GA, this ignores HPHT entirely.
    -- It asks:
    --
    -- "If we calculate GA using USG only, what is GA at birth?"
    -- ========================================================================

    CASE

      WHEN usg_dating_quality = 'EARLY_USG_LE_14W'
       AND dating_usg_date IS NOT NULL
       AND dating_usg_ga_days IS NOT NULL
       AND outcome_event_date >= dating_usg_date

      THEN
        dating_usg_ga_days
        +
        DATE_DIFF(
          outcome_event_date,
          dating_usg_date,
          DAY
        )


      WHEN usg_dating_quality = 'USG_14_22W'
       AND dating_usg_date IS NOT NULL
       AND dating_usg_ga_days IS NOT NULL
       AND outcome_event_date >= dating_usg_date

      THEN
        dating_usg_ga_days
        +
        DATE_DIFF(
          outcome_event_date,
          dating_usg_date,
          DAY
        )


      WHEN usg_dating_quality = 'RECORDED_USG_EDD_GA_UNKNOWN'
       AND usg_recorded_hpl_date IS NOT NULL
       AND outcome_event_date IS NOT NULL

      THEN
        280
        +
        DATE_DIFF(
          outcome_event_date,
          usg_recorded_hpl_date,
          DAY
        )


      WHEN usg_dating_quality = 'LATE_USG_GT_22W'
       AND dating_usg_date IS NOT NULL
       AND dating_usg_ga_days IS NOT NULL
       AND outcome_event_date >= dating_usg_date

      THEN
        dating_usg_ga_days
        +
        DATE_DIFF(
          outcome_event_date,
          dating_usg_date,
          DAY
        )


      ELSE NULL

    END AS ga_usg_independent_days,


    -- ========================================================================
    -- INDEPENDENT HPHT GA
    --
    -- "If we calculate GA using HPHT only, what is GA at birth?"
    -- ========================================================================

    CASE

      WHEN hpht_date IS NOT NULL
       AND outcome_event_date IS NOT NULL
       AND outcome_event_date >= hpht_date

      THEN DATE_DIFF(
        outcome_event_date,
        hpht_date,
        DAY
      )

      ELSE NULL

    END AS ga_hpht_independent_days

  FROM delivery_raw
),


-- ============================================================================
-- 3. CLASSIFY SELECTED GA
-- ============================================================================

delivery_classified AS (

  SELECT
    *,


    -- ------------------------------------------------------------------------
    -- COMPLETED SELECTED GA WEEKS
    -- ------------------------------------------------------------------------
    CASE

      WHEN gestational_age_days IS NOT NULL

      THEN CAST(
        FLOOR(
          gestational_age_days / 7.0
        )
        AS INT64
      )

    END AS gestational_age_weeks,


    -- ------------------------------------------------------------------------
    -- DECIMAL SELECTED GA
    -- ------------------------------------------------------------------------
    CASE

      WHEN gestational_age_days IS NOT NULL

      THEN ROUND(
        gestational_age_days / 7.0,
        1
      )

    END AS gestational_age_weeks_decimal,


    -- ------------------------------------------------------------------------
    -- SELECTED GA CATEGORY
    -- ------------------------------------------------------------------------
    CASE

      WHEN gestational_age_days IS NULL
        THEN 'Tidak Diketahui'

      WHEN gestational_age_days < 259
        THEN 'Preterm'

      WHEN gestational_age_days < 294
        THEN 'Aterm'

      WHEN gestational_age_days < 301
        THEN 'Post-term'

      ELSE 'GA Ekstrem / Perlu Validasi'

    END AS gestational_age_category,


    -- ------------------------------------------------------------------------
    -- GA QA
    -- ------------------------------------------------------------------------
    CASE

      WHEN gestational_age_days IS NULL
        THEN 'Tidak Diketahui'

      WHEN gestational_age_days < 126
        THEN 'Perlu Validasi: <18 minggu'

      WHEN gestational_age_days > 322
        THEN 'Perlu Validasi: >46 minggu'

      ELSE 'Dapat Digunakan'

    END AS ga_quality_category,


    -- ------------------------------------------------------------------------
    -- DATING SOURCE QUALITY
    -- ------------------------------------------------------------------------
    CASE

      WHEN gestational_age_source = 'USG_LE_14W'
        THEN 'TINGGI'

      WHEN gestational_age_source = 'USG_14_22W'
        THEN 'SEDANG'

      WHEN gestational_age_source = 'USG_RECORDED_EDD'
        THEN 'SEDANG'

      WHEN gestational_age_source = 'HPHT'
        THEN 'SEDANG'

      WHEN gestational_age_source = 'LATE_USG_GT_22W'
        THEN 'RENDAH'

      ELSE 'TIDAK TERSEDIA'

    END AS gestational_age_source_quality,


    -- ========================================================================
    -- SIMPLE USG VS HPHT GROUP
    --
    -- Use this as the breakdown dimension for the main comparison chart.
    -- ========================================================================

    CASE

      WHEN gestational_age_source IN (
        'USG_LE_14W',
        'USG_14_22W',
        'USG_RECORDED_EDD',
        'LATE_USG_GT_22W'
      )
        THEN 'USG'

      WHEN gestational_age_source = 'HPHT'
        THEN 'HPHT'

      ELSE 'Tidak Diketahui'

    END AS gestational_age_source_group,


    -- ------------------------------------------------------------------------
    -- INDEPENDENT USG GA — DECIMAL WEEKS
    -- ------------------------------------------------------------------------
    CASE

      WHEN ga_usg_independent_days BETWEEN 126 AND 322

      THEN ROUND(
        ga_usg_independent_days / 7.0,
        1
      )

    END AS ga_usg_independent_weeks,


    -- ------------------------------------------------------------------------
    -- INDEPENDENT HPHT GA — DECIMAL WEEKS
    -- ------------------------------------------------------------------------
    CASE

      WHEN ga_hpht_independent_days BETWEEN 126 AND 322

      THEN ROUND(
        ga_hpht_independent_days / 7.0,
        1
      )

    END AS ga_hpht_independent_weeks

  FROM delivery_with_ga
),


-- ============================================================================
-- 4. PAIRED USG VS HPHT COMPARISON
--
-- Only pregnancies with BOTH plausible estimates are directly compared.
--
-- difference =
--   GA from USG - GA from HPHT
--
-- Positive:
--   USG estimates a higher gestational age than HPHT.
--
-- Negative:
--   USG estimates a lower gestational age than HPHT.
-- ============================================================================

delivery_ga_comparison AS (

  SELECT
    *,


    -- ------------------------------------------------------------------------
    -- PAIR QUALITY
    -- ------------------------------------------------------------------------
    CASE

      WHEN ga_usg_independent_days IS NULL
       AND ga_hpht_independent_days IS NULL
        THEN 'Keduanya Tidak Tersedia'

      WHEN ga_usg_independent_days IS NULL
        THEN 'USG Tidak Tersedia'

      WHEN ga_hpht_independent_days IS NULL
        THEN 'HPHT Tidak Tersedia'

      WHEN ga_usg_independent_days NOT BETWEEN 126 AND 322
        THEN 'USG Perlu Validasi'

      WHEN ga_hpht_independent_days NOT BETWEEN 126 AND 322
        THEN 'HPHT Perlu Validasi'

      ELSE 'Dapat Dibandingkan'

    END AS ga_usg_hpht_pair_quality,


    -- ------------------------------------------------------------------------
    -- DIFFERENCE IN DAYS
    -- ------------------------------------------------------------------------
    CASE

      WHEN ga_usg_independent_days BETWEEN 126 AND 322
       AND ga_hpht_independent_days BETWEEN 126 AND 322

      THEN
        ga_usg_independent_days
        -
        ga_hpht_independent_days

    END AS ga_usg_minus_hpht_days,


    -- ------------------------------------------------------------------------
    -- ABSOLUTE DIFFERENCE
    -- ------------------------------------------------------------------------
    CASE

      WHEN ga_usg_independent_days BETWEEN 126 AND 322
       AND ga_hpht_independent_days BETWEEN 126 AND 322

      THEN ABS(
        ga_usg_independent_days
        -
        ga_hpht_independent_days
      )

    END AS ga_usg_hpht_absolute_difference_days,


    -- ------------------------------------------------------------------------
    -- DIFFERENCE IN WEEKS
    -- ------------------------------------------------------------------------
    CASE

      WHEN ga_usg_independent_days BETWEEN 126 AND 322
       AND ga_hpht_independent_days BETWEEN 126 AND 322

      THEN ROUND(
        SAFE_DIVIDE(
          ga_usg_independent_days
          -
          ga_hpht_independent_days,
          7.0
        ),
        2
      )

    END AS ga_usg_minus_hpht_weeks

  FROM delivery_classified
),


-- ============================================================================
-- 5. CLASSIFY USG-HPHT AGREEMENT
-- ============================================================================

delivery_ga_comparison_classified AS (

  SELECT
    *,


    CASE

      WHEN ga_usg_hpht_pair_quality != 'Dapat Dibandingkan'
        THEN 'Tidak Dapat Dibandingkan'

      WHEN ga_usg_hpht_absolute_difference_days <= 7
        THEN 'Selisih ≤7 hari'

      WHEN ga_usg_hpht_absolute_difference_days <= 14
        THEN 'Selisih 8–14 hari'

      ELSE 'Selisih >14 hari'

    END AS ga_usg_hpht_difference_category,


    CASE

      WHEN ga_usg_hpht_pair_quality = 'Dapat Dibandingkan'
       AND ga_usg_minus_hpht_days < 0
        THEN 'USG Lebih Rendah'

      WHEN ga_usg_hpht_pair_quality = 'Dapat Dibandingkan'
       AND ga_usg_minus_hpht_days = 0
        THEN 'Sama'

      WHEN ga_usg_hpht_pair_quality = 'Dapat Dibandingkan'
       AND ga_usg_minus_hpht_days > 0
        THEN 'USG Lebih Tinggi'

      ELSE 'Tidak Dapat Dibandingkan'

    END AS ga_usg_hpht_difference_direction

  FROM delivery_ga_comparison
),


-- ============================================================================
-- 6. GA SOURCE GROUP SUMMARY
--
-- These window fields allow direct Looker scorecards for USG vs HPHT.
--
-- IMPORTANT:
-- Values repeat across records within each source group.
-- Therefore use MAX(), not SUM(), for these summary fields.
-- ============================================================================

delivery_ga_source_summary AS (

  SELECT
    *,


    -- ------------------------------------------------------------------------
    -- USABLE N PER SOURCE GROUP
    -- ------------------------------------------------------------------------
    COUNTIF(
      gestational_age_source_group IN ('USG', 'HPHT')
      AND ga_quality_category = 'Dapat Digunakan'
    ) OVER (
      PARTITION BY gestational_age_source_group
    ) AS ga_source_group_analysis_n,


    -- ------------------------------------------------------------------------
    -- MEAN GA
    -- ------------------------------------------------------------------------
    AVG(
      CASE

        WHEN ga_quality_category = 'Dapat Digunakan'

        THEN gestational_age_weeks_decimal

      END
    ) OVER (
      PARTITION BY gestational_age_source_group
    ) AS ga_source_group_mean_weeks,


    -- ------------------------------------------------------------------------
    -- MEDIAN GA
    -- ------------------------------------------------------------------------
    PERCENTILE_CONT(

      CASE

        WHEN ga_quality_category = 'Dapat Digunakan'

        THEN gestational_age_weeks_decimal

      END,

      0.50

    ) OVER (
      PARTITION BY gestational_age_source_group
    ) AS ga_source_group_median_weeks,


    -- ------------------------------------------------------------------------
    -- PRETERM %
    -- ------------------------------------------------------------------------
    100.0
    *
    SAFE_DIVIDE(

      COUNTIF(
        ga_quality_category = 'Dapat Digunakan'
        AND gestational_age_category = 'Preterm'
      ) OVER (
        PARTITION BY gestational_age_source_group
      ),

      COUNTIF(
        ga_quality_category = 'Dapat Digunakan'
      ) OVER (
        PARTITION BY gestational_age_source_group
      )

    ) AS ga_source_group_preterm_pct,


    -- ------------------------------------------------------------------------
    -- TERM %
    -- ------------------------------------------------------------------------
    100.0
    *
    SAFE_DIVIDE(

      COUNTIF(
        ga_quality_category = 'Dapat Digunakan'
        AND gestational_age_category = 'Aterm'
      ) OVER (
        PARTITION BY gestational_age_source_group
      ),

      COUNTIF(
        ga_quality_category = 'Dapat Digunakan'
      ) OVER (
        PARTITION BY gestational_age_source_group
      )

    ) AS ga_source_group_term_pct,


    -- ------------------------------------------------------------------------
    -- POST-TERM %
    -- ------------------------------------------------------------------------
    100.0
    *
    SAFE_DIVIDE(

      COUNTIF(
        ga_quality_category = 'Dapat Digunakan'
        AND gestational_age_category = 'Post-term'
      ) OVER (
        PARTITION BY gestational_age_source_group
      ),

      COUNTIF(
        ga_quality_category = 'Dapat Digunakan'
      ) OVER (
        PARTITION BY gestational_age_source_group
      )

    ) AS ga_source_group_postterm_pct,


    -- ------------------------------------------------------------------------
    -- NUMBER AT EACH COMPLETED GA WEEK
    -- ------------------------------------------------------------------------
    COUNTIF(
      ga_quality_category = 'Dapat Digunakan'
    ) OVER (
      PARTITION BY
        gestational_age_source_group,
        gestational_age_weeks
    ) AS ga_source_group_week_count,


    -- ------------------------------------------------------------------------
    -- % DISTRIBUTION WITHIN EACH SOURCE GROUP
    --
    -- Use MAX(ga_source_group_week_pct) in Looker when:
    --
    -- Dimension = gestational_age_weeks
    -- Breakdown = gestational_age_source_group
    -- ------------------------------------------------------------------------
    100.0
    *
    SAFE_DIVIDE(

      COUNTIF(
        ga_quality_category = 'Dapat Digunakan'
      ) OVER (
        PARTITION BY
          gestational_age_source_group,
          gestational_age_weeks
      ),

      COUNTIF(
        ga_quality_category = 'Dapat Digunakan'
      ) OVER (
        PARTITION BY
          gestational_age_source_group
      )

    ) AS ga_source_group_week_pct

  FROM delivery_ga_comparison_classified
),


-- ============================================================================
-- 7. ACTUAL DELIVERY DATE VS EXPECTED DELIVERY DATE
-- ============================================================================

delivery_deviation AS (

  SELECT
    *,

    CASE

      WHEN outcome_event_date IS NOT NULL
       AND expected_delivery_date IS NOT NULL

      THEN DATE_DIFF(
        outcome_event_date,
        expected_delivery_date,
        DAY
      )

    END AS delivery_date_deviation_days

  FROM delivery_ga_source_summary
),


-- ============================================================================
-- 8. DELIVERY DEVIATION DESCRIPTION
-- ============================================================================

delivery_deviation_classified AS (

  SELECT
    *,


    ABS(
      delivery_date_deviation_days
    ) AS absolute_delivery_date_deviation_days,


    CASE

      WHEN delivery_date_deviation_days IS NULL
        THEN 'Tidak Diketahui'

      WHEN delivery_date_deviation_days < 0
        THEN 'Sebelum HPL'

      WHEN delivery_date_deviation_days = 0
        THEN 'Tepat pada HPL'

      ELSE 'Setelah HPL'

    END AS delivery_date_deviation_direction,


    CASE

      WHEN delivery_date_deviation_days IS NULL
        THEN 'Tidak Diketahui'

      WHEN delivery_date_deviation_days <= -15
        THEN '≥15 hari sebelum'

      WHEN delivery_date_deviation_days BETWEEN -14 AND -8
        THEN '8–14 hari sebelum'

      WHEN delivery_date_deviation_days BETWEEN -7 AND -1
        THEN '1–7 hari sebelum'

      WHEN delivery_date_deviation_days = 0
        THEN 'Tepat pada HPL'

      WHEN delivery_date_deviation_days BETWEEN 1 AND 7
        THEN '1–7 hari setelah'

      WHEN delivery_date_deviation_days BETWEEN 8 AND 14
        THEN '8–14 hari setelah'

      ELSE '≥15 hari setelah'

    END AS delivery_date_deviation_category,


    CASE

      WHEN delivery_date_deviation_days <= -15
        THEN 1

      WHEN delivery_date_deviation_days BETWEEN -14 AND -8
        THEN 2

      WHEN delivery_date_deviation_days BETWEEN -7 AND -1
        THEN 3

      WHEN delivery_date_deviation_days = 0
        THEN 4

      WHEN delivery_date_deviation_days BETWEEN 1 AND 7
        THEN 5

      WHEN delivery_date_deviation_days BETWEEN 8 AND 14
        THEN 6

      WHEN delivery_date_deviation_days >= 15
        THEN 7

      ELSE 8

    END AS delivery_date_deviation_category_order

  FROM delivery_deviation
),


-- ============================================================================
-- 9. DELIVERY DEVIATION QA
-- ============================================================================

delivery_deviation_qa AS (

  SELECT
    *,


    CASE

      WHEN delivery_date_deviation_days IS NULL
        THEN 'Tidak Dapat Dinilai'

      WHEN delivery_date_deviation_days BETWEEN -154 AND 42
        THEN 'Plausibel'

      ELSE 'Perlu Validasi'

    END AS delivery_deviation_quality,


    CAST(
      delivery_date_deviation_days BETWEEN -154 AND 42
      AS INT64
    ) AS delivery_deviation_plausible_flag,


    CASE

      WHEN delivery_date_deviation_days IS NULL
        THEN 'HPL tidak tersedia'

      WHEN delivery_date_deviation_days < -154
        THEN 'Terlalu awal: <18 minggu tersirat'

      WHEN delivery_date_deviation_days > 42
        THEN 'Terlalu lambat: >46 minggu tersirat'

      ELSE 'Dalam rentang plausibel'

    END AS delivery_deviation_qa_reason

  FROM delivery_deviation_classified
),


-- ============================================================================
-- 10. DELIVERY DEVIATION DISTRIBUTION SUMMARY
-- ============================================================================

delivery_with_percentiles AS (

  SELECT
    *,


    AVG(
      CASE

        WHEN delivery_deviation_plausible_flag = 1

        THEN CAST(
          delivery_date_deviation_days
          AS FLOAT64
        )

      END
    ) OVER () AS deviation_mean,


    PERCENTILE_CONT(

      CASE

        WHEN delivery_deviation_plausible_flag = 1

        THEN CAST(
          delivery_date_deviation_days
          AS FLOAT64
        )

      END,

      0.05

    ) OVER () AS deviation_p05,


    PERCENTILE_CONT(

      CASE

        WHEN delivery_deviation_plausible_flag = 1

        THEN CAST(
          delivery_date_deviation_days
          AS FLOAT64
        )

      END,

      0.50

    ) OVER () AS deviation_median,


    PERCENTILE_CONT(

      CASE

        WHEN delivery_deviation_plausible_flag = 1

        THEN CAST(
          delivery_date_deviation_days
          AS FLOAT64
        )

      END,

      0.95

    ) OVER () AS deviation_p95,


    COUNTIF(
      delivery_deviation_plausible_flag = 1
    ) OVER () AS deviation_analysis_n

  FROM delivery_deviation_qa
),


-- ============================================================================
-- 11. CENTRAL 90% GROUP
-- ============================================================================

delivery_with_90pct_group AS (

  SELECT
    *,


    CASE

      WHEN delivery_date_deviation_days IS NULL
        THEN 'Tidak Dapat Dinilai'

      WHEN delivery_deviation_plausible_flag = 0
        THEN 'Perlu Validasi'

      WHEN delivery_date_deviation_days < deviation_p05
        THEN '5% Lower'

      WHEN delivery_date_deviation_days > deviation_p95
        THEN '5% Upper'

      ELSE '90% Central'

    END AS deviation_90pct_group,


    CASE

      WHEN delivery_deviation_plausible_flag = 1
       AND delivery_date_deviation_days < deviation_p05
        THEN 1

      WHEN delivery_deviation_plausible_flag = 1
       AND delivery_date_deviation_days <= deviation_p95
        THEN 2

      WHEN delivery_deviation_plausible_flag = 1
       AND delivery_date_deviation_days > deviation_p95
        THEN 3

      WHEN delivery_deviation_plausible_flag = 0
        THEN 4

      ELSE 5

    END AS deviation_90pct_group_order

  FROM delivery_with_percentiles
),


-- ============================================================================
-- 12. LOOKER-FRIENDLY COUNTERS
-- ============================================================================

delivery_final AS (

  SELECT
    *,


    -- ------------------------------------------------------------------------
    -- EVENTS
    -- ------------------------------------------------------------------------
    1 AS outcome_event_count,

    1 AS delivery_event_count,

    0 AS abortion_count,


    -- ------------------------------------------------------------------------
    -- OUTCOME
    -- ------------------------------------------------------------------------
    CAST(
      outcome_category = 'Lahir Hidup'
      AS INT64
    ) AS live_birth_count,


    CAST(
      outcome_category = 'Lahir Mati'
      AS INT64
    ) AS stillbirth_count,


    CAST(
      outcome_category =
        'Campuran Lahir Hidup + Lahir Mati'
      AS INT64
    ) AS mixed_birth_count,


    CAST(
      outcome_category =
        'Luaran Belum Diketahui'
      AS INT64
    ) AS outcome_unknown_count,


    CAST(
      outcome_category IN (
        'Lahir Hidup',
        'Lahir Mati',
        'Campuran Lahir Hidup + Lahir Mati'
      )
      AS INT64
    ) AS outcome_known_count,


    -- ------------------------------------------------------------------------
    -- GA
    -- ------------------------------------------------------------------------
    CAST(
      gestational_age_days IS NOT NULL
      AS INT64
    ) AS ga_known_count,


    CAST(
      ga_quality_category = 'Dapat Digunakan'
      AS INT64
    ) AS ga_usable_for_rate_count,


    CAST(
      gestational_age_source_group = 'USG'
      AS INT64
    ) AS ga_usg_based_count,


    CAST(
      gestational_age_source = 'USG_LE_14W'
      AS INT64
    ) AS ga_early_usg_count,


    CAST(
      gestational_age_source = 'USG_14_22W'
      AS INT64
    ) AS ga_mid_usg_count,


    CAST(
      gestational_age_source = 'USG_RECORDED_EDD'
      AS INT64
    ) AS ga_usg_edd_count,


    CAST(
      gestational_age_source = 'HPHT'
      AS INT64
    ) AS ga_hpht_count,


    CAST(
      gestational_age_source = 'LATE_USG_GT_22W'
      AS INT64
    ) AS ga_late_usg_count,


    CAST(
      gestational_age_category = 'Preterm'
      AND ga_quality_category = 'Dapat Digunakan'
      AS INT64
    ) AS preterm_count,


    CAST(
      gestational_age_category = 'Aterm'
      AND ga_quality_category = 'Dapat Digunakan'
      AS INT64
    ) AS term_count,


    CAST(
      gestational_age_category = 'Post-term'
      AND ga_quality_category = 'Dapat Digunakan'
      AS INT64
    ) AS postterm_count,


    CAST(
      ga_quality_category LIKE 'Perlu Validasi%'
      AS INT64
    ) AS ga_extreme_count,


    -- ------------------------------------------------------------------------
    -- TRUE USG VS HPHT PAIRED COMPARISON
    -- ------------------------------------------------------------------------
    CAST(
      ga_usg_hpht_pair_quality = 'Dapat Dibandingkan'
      AS INT64
    ) AS ga_usg_hpht_comparable_count,


    CAST(
      ga_usg_hpht_pair_quality = 'Dapat Dibandingkan'
      AND ga_usg_hpht_absolute_difference_days <= 7
      AS INT64
    ) AS ga_usg_hpht_within_7d_count,


    CAST(
      ga_usg_hpht_pair_quality = 'Dapat Dibandingkan'
      AND ga_usg_hpht_absolute_difference_days <= 14
      AS INT64
    ) AS ga_usg_hpht_within_14d_count,


    CAST(
      ga_usg_hpht_pair_quality = 'Dapat Dibandingkan'
      AND ga_usg_hpht_absolute_difference_days > 14
      AS INT64
    ) AS ga_usg_hpht_gt14d_count,


    -- ------------------------------------------------------------------------
    -- DELIVERY MODE
    -- ------------------------------------------------------------------------
    CAST(
      delivery_mode_category != 'Tidak Diketahui'
      AS INT64
    ) AS delivery_mode_known_count,


    CAST(
      delivery_mode_category = 'Seksio Sesarea'
      AS INT64
    ) AS cesarean_count,


    CAST(
      delivery_mode_category = 'Pervaginam'
      AS INT64
    ) AS vaginal_count,


    CAST(
      delivery_mode_category =
        'Vaginal dengan Tindakan'
      AS INT64
    ) AS assisted_vaginal_count,


    -- ------------------------------------------------------------------------
    -- DELIVERY DATE DEVIATION
    -- ------------------------------------------------------------------------
    CAST(
      delivery_date_deviation_days IS NOT NULL
      AS INT64
    ) AS delivery_deviation_known_count,


    CAST(
      delivery_date_deviation_days IS NULL
      AS INT64
    ) AS delivery_deviation_unknown_count,


    CAST(
      delivery_deviation_plausible_flag = 1
      AS INT64
    ) AS delivery_deviation_usable_count,


    CAST(
      delivery_date_deviation_days IS NOT NULL
      AND delivery_deviation_plausible_flag = 0
      AS INT64
    ) AS delivery_deviation_validation_count,


    CAST(
      delivery_deviation_plausible_flag = 1
      AND delivery_date_deviation_days < 0
      AS INT64
    ) AS delivered_before_expected_count,


    CAST(
      delivery_deviation_plausible_flag = 1
      AND delivery_date_deviation_days = 0
      AS INT64
    ) AS delivered_on_expected_count,


    CAST(
      delivery_deviation_plausible_flag = 1
      AND delivery_date_deviation_days > 0
      AS INT64
    ) AS delivered_after_expected_count,


    CAST(
      delivery_deviation_plausible_flag = 1
      AND delivery_date_deviation_days BETWEEN -7 AND 7
      AS INT64
    ) AS delivered_within_7d_expected_count,


    CAST(
      delivery_deviation_plausible_flag = 1
      AND delivery_date_deviation_days BETWEEN -14 AND 14
      AS INT64
    ) AS delivered_within_14d_expected_count,


    CAST(
      delivery_deviation_plausible_flag = 1
      AND delivery_date_deviation_days < -14
      AS INT64
    ) AS delivered_more_than_14d_before_count,


    CAST(
      delivery_deviation_plausible_flag = 1
      AND delivery_date_deviation_days > 14
      AS INT64
    ) AS delivered_more_than_14d_after_count,


    CAST(
      delivery_deviation_plausible_flag = 1
      AND delivery_date_deviation_days >= deviation_p05
      AND delivery_date_deviation_days <= deviation_p95
      AS INT64
    ) AS deviation_central_90_count,


    CAST(
      delivery_deviation_plausible_flag = 1
      AND delivery_date_deviation_days < deviation_p05
      AS INT64
    ) AS deviation_lower_5_count,


    CAST(
      delivery_deviation_plausible_flag = 1
      AND delivery_date_deviation_days > deviation_p95
      AS INT64
    ) AS deviation_upper_5_count

  FROM delivery_with_90pct_group
),


-- ============================================================================
-- 13. ABORTION EVENTS
-- ============================================================================

abortus AS (

  SELECT

    CONCAT(
      'ABORTUS|',
      pregnancy_episode_id
    ) AS outcome_event_id,

    'ABORTUS' AS event_type,

    pregnancy_episode_id,

    abortion_date AS outcome_event_date,

    DATE_TRUNC(
      abortion_date,
      MONTH
    ) AS outcome_month,

    expected_delivery_date,


    -- LOCATION
    puskesmas AS dashboard_puskesmas,

    desa AS dashboard_desa,

    posyandu AS dashboard_posyandu,

    puskesmas AS pregnancy_puskesmas,

    desa AS pregnancy_desa,

    CAST(NULL AS STRING)
      AS delivery_puskesmas,

    CAST(NULL AS STRING)
      AS delivery_desa,


    -- SOURCE
    pregnancy_source_combination,

    CAST(NULL AS STRING)
      AS delivery_source_combination,

    CAST(NULL AS STRING)
      AS primary_delivery_source,

    abortion_source
      AS event_source_combination,


    -- LINKAGE
    CAST(NULL AS STRING)
      AS linkage_status,

    CAST(NULL AS STRING)
      AS linkage_method,

    CAST(NULL AS STRING)
      AS linkage_confidence,


    -- OUTCOME / MODE
    'ABORTUS'
      AS delivery_outcome_raw,

    CAST(NULL AS STRING)
      AS delivery_mode_raw,

    CAST(NULL AS STRING)
      AS delivery_mode_source,


    -- DATING INPUTS
    CAST(NULL AS DATE)
      AS hpht_date,

    CAST(NULL AS DATE)
      AS dating_usg_date,

    CAST(NULL AS FLOAT64)
      AS dating_usg_ga_weeks,

    CAST(NULL AS INT64)
      AS dating_usg_ga_days,

    CAST(NULL AS STRING)
      AS usg_dating_quality,

    CAST(NULL AS DATE)
      AS usg_recorded_hpl_date,

    CAST(NULL AS DATE)
      AS hpl_from_usg_ga_date,


    -- OUTCOME
    'Abortus'
      AS outcome_category,

    'Tidak Berlaku'
      AS delivery_mode_category,


    -- SELECTED GA
    CAST(NULL AS INT64)
      AS gestational_age_days,

    'NOT_APPLICABLE'
      AS gestational_age_source,

    CAST(NULL AS INT64)
      AS ga_usg_independent_days,

    CAST(NULL AS INT64)
      AS ga_hpht_independent_days,

    CAST(NULL AS INT64)
      AS gestational_age_weeks,

    CAST(NULL AS FLOAT64)
      AS gestational_age_weeks_decimal,

    'Tidak Berlaku'
      AS gestational_age_category,

    'Tidak Berlaku'
      AS ga_quality_category,

    'TIDAK BERLAKU'
      AS gestational_age_source_quality,

    'Tidak Berlaku'
      AS gestational_age_source_group,

    CAST(NULL AS FLOAT64)
      AS ga_usg_independent_weeks,

    CAST(NULL AS FLOAT64)
      AS ga_hpht_independent_weeks,


    -- USG VS HPHT
    'Tidak Berlaku'
      AS ga_usg_hpht_pair_quality,

    CAST(NULL AS INT64)
      AS ga_usg_minus_hpht_days,

    CAST(NULL AS INT64)
      AS ga_usg_hpht_absolute_difference_days,

    CAST(NULL AS FLOAT64)
      AS ga_usg_minus_hpht_weeks,

    'Tidak Berlaku'
      AS ga_usg_hpht_difference_category,

    'Tidak Berlaku'
      AS ga_usg_hpht_difference_direction,


    -- SOURCE GROUP SUMMARY
    CAST(NULL AS INT64)
      AS ga_source_group_analysis_n,

    CAST(NULL AS FLOAT64)
      AS ga_source_group_mean_weeks,

    CAST(NULL AS FLOAT64)
      AS ga_source_group_median_weeks,

    CAST(NULL AS FLOAT64)
      AS ga_source_group_preterm_pct,

    CAST(NULL AS FLOAT64)
      AS ga_source_group_term_pct,

    CAST(NULL AS FLOAT64)
      AS ga_source_group_postterm_pct,

    CAST(NULL AS INT64)
      AS ga_source_group_week_count,

    CAST(NULL AS FLOAT64)
      AS ga_source_group_week_pct,


    -- DELIVERY DEVIATION
    CAST(NULL AS INT64)
      AS delivery_date_deviation_days,

    CAST(NULL AS INT64)
      AS absolute_delivery_date_deviation_days,

    'Tidak Berlaku'
      AS delivery_date_deviation_direction,

    'Tidak Berlaku'
      AS delivery_date_deviation_category,

    CAST(NULL AS INT64)
      AS delivery_date_deviation_category_order,

    'Tidak Berlaku'
      AS delivery_deviation_quality,

    0
      AS delivery_deviation_plausible_flag,

    'Tidak Berlaku'
      AS delivery_deviation_qa_reason,

    CAST(NULL AS FLOAT64)
      AS deviation_mean,

    CAST(NULL AS FLOAT64)
      AS deviation_p05,

    CAST(NULL AS FLOAT64)
      AS deviation_median,

    CAST(NULL AS FLOAT64)
      AS deviation_p95,

    CAST(NULL AS INT64)
      AS deviation_analysis_n,

    'Tidak Berlaku'
      AS deviation_90pct_group,

    CAST(NULL AS INT64)
      AS deviation_90pct_group_order,


    -- EVENT COUNTERS
    1 AS outcome_event_count,

    0 AS delivery_event_count,

    1 AS abortion_count,


    -- OUTCOME COUNTERS
    0 AS live_birth_count,

    0 AS stillbirth_count,

    0 AS mixed_birth_count,

    0 AS outcome_unknown_count,

    0 AS outcome_known_count,


    -- GA COUNTERS
    0 AS ga_known_count,

    0 AS ga_usable_for_rate_count,

    0 AS ga_usg_based_count,

    0 AS ga_early_usg_count,

    0 AS ga_mid_usg_count,

    0 AS ga_usg_edd_count,

    0 AS ga_hpht_count,

    0 AS ga_late_usg_count,

    0 AS preterm_count,

    0 AS term_count,

    0 AS postterm_count,

    0 AS ga_extreme_count,


    -- PAIRED USG/HPHT COUNTERS
    0 AS ga_usg_hpht_comparable_count,

    0 AS ga_usg_hpht_within_7d_count,

    0 AS ga_usg_hpht_within_14d_count,

    0 AS ga_usg_hpht_gt14d_count,


    -- DELIVERY MODE COUNTERS
    0 AS delivery_mode_known_count,

    0 AS cesarean_count,

    0 AS vaginal_count,

    0 AS assisted_vaginal_count,


    -- DEVIATION COUNTERS
    0 AS delivery_deviation_known_count,

    0 AS delivery_deviation_unknown_count,

    0 AS delivery_deviation_usable_count,

    0 AS delivery_deviation_validation_count,

    0 AS delivered_before_expected_count,

    0 AS delivered_on_expected_count,

    0 AS delivered_after_expected_count,

    0 AS delivered_within_7d_expected_count,

    0 AS delivered_within_14d_expected_count,

    0 AS delivered_more_than_14d_before_count,

    0 AS delivered_more_than_14d_after_count,

    0 AS deviation_central_90_count,

    0 AS deviation_lower_5_count,

    0 AS deviation_upper_5_count

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_monitoring_integrated`

  WHERE
    integrated_monitoring_status = 'ABORTUS'

    AND abortion_date IS NOT NULL
)


-- ============================================================================
-- 14. FINAL
--
-- BY NAME makes the UNION safer as the query now contains many analytical
-- fields and prevents accidental column-order mismatch.
-- ============================================================================

SELECT *
FROM delivery_final

UNION ALL BY NAME

SELECT *
FROM abortus""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_birth_outcome_period_comparison
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_birth_outcome_period_comparison');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_birth_outcome_period_comparison';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_birth_outcome_period_comparison` AS SELECT ',
 projection, ' FROM (', r"""WITH params AS (
  SELECT
    CURRENT_DATE('Asia/Makassar') AS today,

    DATE_TRUNC(
      CURRENT_DATE('Asia/Makassar'),
      MONTH
    ) AS current_month_start,

    DATE_SUB(
      DATE_TRUNC(
        CURRENT_DATE('Asia/Makassar'),
        MONTH
      ),
      INTERVAL 1 MONTH
    ) AS previous_month_start
),

-- ============================================================
-- 1. AUTOMATIC REPORTING PERIODS
-- ============================================================
periods AS (

  -- ----------------------------------------------------------
  -- TOTAL: JAN 2025 TO TODAY
  -- ----------------------------------------------------------
  SELECT
    1 AS period_order,
    '1. Jan 2025 - Today' AS period_label,
    DATE '2025-01-01' AS period_start,
    today AS period_end
  FROM params

  UNION ALL

  -- ----------------------------------------------------------
  -- JAN 2026 TO TODAY
  -- ----------------------------------------------------------
  SELECT
    2 AS period_order,
    '2. Jan 2026 - Today' AS period_label,
    DATE '2026-01-01' AS period_start,
    today AS period_end
  FROM params

  UNION ALL

  -- ----------------------------------------------------------
  -- PREVIOUS MONTH: COMPLETE MONTH
  -- ----------------------------------------------------------
  SELECT
    3 AS period_order,

    CONCAT(
      '3. ',
      FORMAT_DATE('%b %Y', previous_month_start)
    ) AS period_label,

    previous_month_start AS period_start,

    DATE_SUB(
      current_month_start,
      INTERVAL 1 DAY
    ) AS period_end

  FROM params

  UNION ALL

  -- ----------------------------------------------------------
  -- CURRENT MONTH TO TODAY
  -- ----------------------------------------------------------
  SELECT
    4 AS period_order,

    CONCAT(
      '4. ',
      FORMAT_DATE('%b %Y', current_month_start),
      ' - Today'
    ) AS period_label,

    current_month_start AS period_start,
    today AS period_end

  FROM params
),

-- ============================================================
-- 2. PREGNANCY BASE
--
-- One row = one canonical pregnancy episode
-- ============================================================
pregnancy_base AS (
  SELECT
    pregnancy_episode_id,
    expected_delivery_date,

    integrated_monitoring_status_all_history AS status,

    integrated_pregnancy_outcome AS outcome

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_monitoring_integrated`

  WHERE
    expected_delivery_date >= DATE '2025-01-01'

    AND COALESCE(
      pregnancy_date_valid_flag,
      FALSE
    )
),

-- ============================================================
-- 3. PREGNANCY SUMMARY
--
-- Period basis = Expected Delivery Date / HPL
--
-- IMPORTANT:
-- expected_delivery_date < TODAY
--
-- Therefore HPL today is NOT yet considered overdue.
-- ============================================================
pregnancy_summary AS (

  SELECT
    p.period_order,
    p.period_label,

    -- --------------------------------------------------------
    -- 01. EXPECTED TO HAVE DELIVERED
    --
    -- HPL has already passed.
    -- Abortions excluded.
    -- --------------------------------------------------------
    COUNTIF(
      b.expected_delivery_date < CURRENT_DATE('Asia/Makassar')

      AND b.status IN (
        'DELIVERED',
        'DELIVERED_DATE_UNKNOWN',
        'MISSING_BIRTH'
      )
    ) AS expected_to_have_delivered,


    -- --------------------------------------------------------
    -- 02. BIRTHS FOUND
    --
    -- Birth evidence exists.
    -- --------------------------------------------------------
    COUNTIF(
      b.expected_delivery_date < CURRENT_DATE('Asia/Makassar')

      AND b.status IN (
        'DELIVERED',
        'DELIVERED_DATE_UNKNOWN'
      )
    ) AS births_found,


    -- --------------------------------------------------------
    -- 03. BIRTH NOT FOUND
    --
    -- HPL passed but no accepted birth record found.
    -- --------------------------------------------------------
    COUNTIF(
      b.expected_delivery_date < CURRENT_DATE('Asia/Makassar')

      AND b.status = 'MISSING_BIRTH'
    ) AS birth_not_found,


    -- --------------------------------------------------------
    -- 05. KNOWN BIRTH OUTCOME
    -- --------------------------------------------------------
    COUNTIF(
      b.expected_delivery_date < CURRENT_DATE('Asia/Makassar')

      AND b.status IN (
        'DELIVERED',
        'DELIVERED_DATE_UNKNOWN'
      )

      AND b.outcome IN (
        'LAHIR HIDUP',
        'LAHIR MATI',
        'MIXED_LIVE_STILLBIRTH'
      )
    ) AS known_birth_outcome,


    -- --------------------------------------------------------
    -- 06. BIRTH OUTCOME UNKNOWN
    --
    -- Delivery found, but live/stillbirth outcome unclear.
    -- --------------------------------------------------------
    COUNTIF(
      b.expected_delivery_date < CURRENT_DATE('Asia/Makassar')

      AND b.status IN (
        'DELIVERED',
        'DELIVERED_DATE_UNKNOWN'
      )

      AND (
        b.outcome IS NULL

        OR b.outcome = 'DELIVERY_OUTCOME_UNCLEAR'

        OR b.outcome NOT IN (
          'LAHIR HIDUP',
          'LAHIR MATI',
          'MIXED_LIVE_STILLBIRTH'
        )
      )
    ) AS birth_outcome_unknown

  FROM periods p

  LEFT JOIN pregnancy_base b
    ON b.expected_delivery_date
       BETWEEN p.period_start AND p.period_end

  GROUP BY
    p.period_order,
    p.period_label
),

-- ============================================================
-- 4. DELIVERY / LINKAGE SUMMARY
--
-- Period basis = ACTUAL DELIVERY DATE
-- ============================================================
delivery_summary AS (

  SELECT
    p.period_order,
    p.period_label,

    -- All valid known birth events
    COALESCE(
      SUM(d.valid_known_birth_count),
      0
    ) AS valid_known_births,

    -- Valid known births linked to ANC/pregnancy
    COALESCE(
      SUM(d.anc_linked_birth_count),
      0
    ) AS births_linked_to_anc

  FROM periods p

  LEFT JOIN
    `spheres-lombok-barat.kohort_bumil_v3.v_delivery_monitoring_integrated` d

    ON d.delivery_date
       BETWEEN p.period_start AND p.period_end

  GROUP BY
    p.period_order,
    p.period_label
),

-- ============================================================
-- 5. FINAL REPORTING INDICATORS
--
-- ORDER:
-- Expected
--   ↓
-- Found
--   ↓
-- Missing
--   ↓
-- Capture %
--   ↓
-- Outcome known / unknown
--   ↓
-- Completeness %
--   ↓
-- Linkage
-- ============================================================
indicators AS (

  -- ========================================================
  -- 01. EXPECTED TO HAVE DELIVERED
  -- ========================================================
  SELECT
    1 AS indicator_order,

    'Expected to Have Delivered'
      AS indicator,

    'COUNT'
      AS value_type,

    period_order,
    period_label,

    CAST(
      expected_to_have_delivered
      AS FLOAT64
    ) AS value

  FROM pregnancy_summary


  UNION ALL


  -- ========================================================
  -- 02. BIRTHS FOUND
  -- ========================================================
  SELECT
    2,

    'Births Found',

    'COUNT',

    period_order,
    period_label,

    CAST(
      births_found
      AS FLOAT64
    )

  FROM pregnancy_summary


  UNION ALL


  -- ========================================================
  -- 03. BIRTH NOT FOUND / MISSING BIRTH
  -- ========================================================
  SELECT
    3,

    'Birth Not Found',

    'COUNT',

    period_order,
    period_label,

    CAST(
      birth_not_found
      AS FLOAT64
    )

  FROM pregnancy_summary


  UNION ALL


  -- ========================================================
  -- 04. BIRTH CAPTURE RATE
  --
  -- Births Found / Expected to Have Delivered
  -- ========================================================
  SELECT
    4,

    'Birth Capture Rate (%)',

    'PERCENT',

    period_order,
    period_label,

    ROUND(
      100 * SAFE_DIVIDE(
        births_found,
        expected_to_have_delivered
      ),
      1
    )

  FROM pregnancy_summary


  UNION ALL


  -- ========================================================
  -- 05. KNOWN BIRTH OUTCOME
  -- ========================================================
  SELECT
    5,

    'Known Birth Outcome',

    'COUNT',

    period_order,
    period_label,

    CAST(
      known_birth_outcome
      AS FLOAT64
    )

  FROM pregnancy_summary


  UNION ALL


  -- ========================================================
  -- 06. BIRTH OUTCOME UNKNOWN
  -- ========================================================
  SELECT
    6,

    'Birth Outcome Unknown',

    'COUNT',

    period_order,
    period_label,

    CAST(
      birth_outcome_unknown
      AS FLOAT64
    )

  FROM pregnancy_summary


  UNION ALL


  -- ========================================================
  -- 07. OUTCOME COMPLETENESS RATE
  --
  -- Known Outcome / Births Found
  -- ========================================================
  SELECT
    7,

    'Outcome Completeness Rate (%)',

    'PERCENT',

    period_order,
    period_label,

    ROUND(
      100 * SAFE_DIVIDE(
        known_birth_outcome,
        births_found
      ),
      1
    )

  FROM pregnancy_summary


  UNION ALL


  -- ========================================================
  -- 08. BIRTHS LINKED TO PREGNANCY / ANC
  -- ========================================================
  SELECT
    8,

    'Births Linked to Pregnancy/ANC',

    'COUNT',

    period_order,
    period_label,

    CAST(
      births_linked_to_anc
      AS FLOAT64
    )

  FROM delivery_summary


  UNION ALL


  -- ========================================================
  -- 09. LINKAGE RATE
  --
  -- ANC-linked births / all valid known birth events
  -- ========================================================
  SELECT
    9,

    'Linkage Rate (%)',

    'PERCENT',

    period_order,
    period_label,

    ROUND(
      100 * SAFE_DIVIDE(
        births_linked_to_anc,
        valid_known_births
      ),
      1
    )

  FROM delivery_summary
)

-- ============================================================
-- 6. FINAL OUTPUT
-- ============================================================
SELECT
  indicator_order,

  CONCAT(
    LPAD(
      CAST(indicator_order AS STRING),
      2,
      '0'
    ),
    '. ',
    indicator
  ) AS indicator,

  value_type,

  period_order,
  period_label,

  value

FROM indicators""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_birth_reporting_timeliness
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_birth_reporting_timeliness');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_birth_reporting_timeliness';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_birth_reporting_timeliness` AS SELECT ',
 projection, ' FROM (', r"""WITH

-- ============================================================================
-- 1. CANONICAL DELIVERED PREGNANCIES
--
-- Same pregnancy cohort used by the monitoring dashboard.
-- ============================================================================

pregnancy_cohort AS (
  SELECT
    pregnancy_episode_id,

    nik_clean,

    -- Normalized canonical name for historical matching
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(nama_ibu, '')
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS nama_norm,

    nama_ibu,
    tanggal_lahir_ibu,

    expected_delivery_date,
    expected_delivery_date_source,

    integrated_monitoring_status_all_history
      AS pregnancy_delivery_status,

    integrated_delivery_event_id
      AS delivery_event_id,

    integrated_delivery_date
      AS delivery_date,

    integrated_delivery_outcome
      AS delivery_outcome,

    integrated_delivery_source_combination
      AS delivery_source_combination,

    integrated_primary_delivery_source
      AS primary_delivery_source,

    COALESCE(
      integrated_has_delivery_epus,
      FALSE
    ) AS master_has_epus,

    COALESCE(
      integrated_has_delivery_sigizi,
      FALSE
    ) AS master_has_sigizi,

    puskesmas
      AS responsible_puskesmas,

    puskesmas_norm
      AS responsible_puskesmas_norm,

    desa
      AS responsible_desa,

    desa_norm
      AS responsible_desa_norm,

    posyandu
      AS responsible_posyandu,

    pregnancy_source_combination

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_monitoring_integrated`

  WHERE
    integrated_monitoring_status_all_history IN (
      'DELIVERED',
      'DELIVERED_DATE_UNKNOWN'
    )
),


-- ============================================================================
-- 2. RAW EPUS INC
--
-- No deduplication.
-- Every historical file remains available here.
-- ============================================================================

raw_epus_1 AS (
  SELECT
    file_name,

    -- --------------------------------------------------------
    -- filename datetime = primary capture time
    -- --------------------------------------------------------
    SAFE.PARSE_DATETIME(
      '%Y-%m-%d %H:%M:%E*S',
      REPLACE(
        REGEXP_EXTRACT(
          CAST(file_name AS STRING),
          r'(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
        ),
        'T',
        ' '
      )
    ) AS filename_datetime,

    COALESCE(
      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%d %H:%M:%E*S',
        NULLIF(TRIM(ingestion_timestamp), '')
      ),

      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%dT%H:%M:%E*S',
        NULLIF(TRIM(ingestion_timestamp), '')
      ),

      SAFE_CAST(
        NULLIF(TRIM(ingestion_timestamp), '')
        AS TIMESTAMP
      )
    ) AS ingestion_ts,

    -- --------------------------------------------------------
    -- Mother NIK
    -- --------------------------------------------------------
    CASE
      WHEN REGEXP_CONTAINS(
        REGEXP_REPLACE(
          COALESCE(nik, ''),
          r'[^0-9]',
          ''
        ),
        r'^\d{16}$'
      )
      THEN REGEXP_REPLACE(
        COALESCE(nik, ''),
        r'[^0-9]',
        ''
      )
    END AS nik_clean,

    -- --------------------------------------------------------
    -- Mother name
    -- --------------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(nama_pasien, '')
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS nama_norm,

    -- --------------------------------------------------------
    -- DOB
    -- --------------------------------------------------------
    COALESCE(
      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          CAST(tanggal_lahir AS STRING),
          r'(\d{4}-\d{1,2}-\d{1,2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          CAST(tanggal_lahir AS STRING),
          r'(\d{1,2}/\d{1,2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          CAST(tanggal_lahir AS STRING),
          r'(\d{1,2}-\d{1,2}-\d{4})'
        )
      )
    ) AS tanggal_lahir_ibu,

    -- --------------------------------------------------------
    -- Delivery date
    --
    -- Same priority as standardized EPUS INC:
    -- baby birth date -> maternal delivery date -> placenta
    -- --------------------------------------------------------
    COALESCE(

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          CAST(bayi_lahir_tanggal AS STRING),
          r'(\d{4}-\d{1,2}-\d{1,2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          CAST(bayi_lahir_tanggal AS STRING),
          r'(\d{1,2}/\d{1,2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          CAST(bayi_lahir_tanggal AS STRING),
          r'(\d{1,2}-\d{1,2}-\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          CAST(tanggal_persalinan AS STRING),
          r'(\d{4}-\d{1,2}-\d{1,2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          CAST(tanggal_persalinan AS STRING),
          r'(\d{1,2}/\d{1,2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          CAST(tanggal_persalinan AS STRING),
          r'(\d{1,2}-\d{1,2}-\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          CAST(plasenta_lahir_tanggal AS STRING),
          r'(\d{4}-\d{1,2}-\d{1,2})'
        )
      )

    ) AS raw_delivery_date,

    bayi_lahir_tanggal,
    bayi_lahir_jam

  FROM
    `spheres-lombok-barat.raw_data.epus_inc`
),


raw_epus AS (
  SELECT
    *,

    COALESCE(
      filename_datetime,

      DATETIME(
        ingestion_ts,
        'Asia/Makassar'
      )
    ) AS capture_datetime,

    CASE
      WHEN filename_datetime IS NOT NULL
        THEN 'FILE_DATETIME_FROM_NAME'

      WHEN ingestion_ts IS NOT NULL
        THEN 'INGESTION_TIMESTAMP_FALLBACK'

      ELSE 'TIMESTAMP_MISSING'
    END AS capture_timestamp_method

  FROM raw_epus_1

  WHERE raw_delivery_date IS NOT NULL
),


-- ============================================================================
-- 3. EPUS EXACT BIRTH DATETIME
-- ============================================================================

raw_epus_typed AS (
  SELECT
    *,

    COALESCE(

      SAFE.PARSE_TIME(
        '%H:%M:%S',
        REGEXP_EXTRACT(
          CAST(bayi_lahir_jam AS STRING),
          r'(\d{1,2}:\d{2}:\d{2})'
        )
      ),

      SAFE.PARSE_TIME(
        '%H:%M',
        REGEXP_EXTRACT(
          CAST(bayi_lahir_jam AS STRING),
          r'(\d{1,2}:\d{2})'
        )
      )

    ) AS birth_time

  FROM raw_epus
),


raw_epus_final AS (
  SELECT
    *,

    CASE
      WHEN raw_delivery_date IS NOT NULL
       AND birth_time IS NOT NULL
      THEN DATETIME(
        raw_delivery_date,
        birth_time
      )
    END AS raw_delivery_datetime

  FROM raw_epus_typed
),


-- ============================================================================
-- 4. MATCH CANONICAL PREGNANCY TO ALL RAW EPUS HISTORY
--
-- Priority:
--
-- 1 = exact NIK + exact delivery date
-- 2 = name + DOB + exact delivery date
-- 3 = name + exact delivery date
--
-- We are matching a maternal delivery event, not an individual baby.
-- ============================================================================

epus_candidates AS (
  SELECT
    p.pregnancy_episode_id,
    p.delivery_event_id,

    r.file_name,
    r.capture_datetime,
    r.capture_timestamp_method,

    r.raw_delivery_date,
    r.raw_delivery_datetime,

    CASE

      WHEN p.nik_clean IS NOT NULL
       AND r.nik_clean = p.nik_clean
       AND r.raw_delivery_date = p.delivery_date
        THEN 1

      WHEN p.nama_norm IS NOT NULL
       AND r.nama_norm = p.nama_norm
       AND p.tanggal_lahir_ibu IS NOT NULL
       AND r.tanggal_lahir_ibu = p.tanggal_lahir_ibu
       AND r.raw_delivery_date = p.delivery_date
        THEN 2

      WHEN p.nama_norm IS NOT NULL
       AND r.nama_norm = p.nama_norm
       AND r.raw_delivery_date = p.delivery_date
        THEN 3

      ELSE 99

    END AS history_match_priority

  FROM pregnancy_cohort p

  JOIN raw_epus_final r

    ON p.delivery_date IS NOT NULL

   AND (
        (
          p.nik_clean IS NOT NULL
          AND r.nik_clean = p.nik_clean
        )

        OR

        (
          p.nama_norm IS NOT NULL
          AND r.nama_norm = p.nama_norm
        )
      )

   AND r.raw_delivery_date = p.delivery_date

  WHERE
    p.master_has_epus
),


epus_first_capture AS (
  SELECT
    * EXCEPT(rn)

  FROM (
    SELECT
      *,

      ROW_NUMBER() OVER (
        PARTITION BY pregnancy_episode_id

        ORDER BY
          history_match_priority,
          capture_datetime IS NULL,
          capture_datetime,
          file_name
      ) AS rn

    FROM epus_candidates

    WHERE history_match_priority < 99
  )

  WHERE rn = 1
),


-- ============================================================================
-- 5. SIGIZI RAW HISTORY
--
-- We normalize all three delivery-bearing SIGIZI sources into the same schema.
-- ============================================================================

-- ============================================================================
-- 5. SIGIZI RAW HISTORY
--
-- Schema-tolerant:
-- use JSON so differences such as
--   tgl_lahir
--   tanggal_lahir
--   tanggal_lahir_ibu
-- do not cause query errors.
-- ============================================================================


-- ============================================================================
-- 5A. KOHORT IBU
-- ============================================================================

sigizi_kohort_ibu_json AS (
  SELECT
    TO_JSON_STRING(t) AS j
  FROM
    `spheres-lombok-barat.raw_data.sigizi_kohort_ibu` t
),


sigizi_kohort_ibu AS (
  SELECT
    'KOHORT_IBU' AS raw_source_table,

    JSON_VALUE(j, '$.file_name')
      AS file_name,


    -- ------------------------------------------------------------------------
    -- FILE DATETIME
    -- ------------------------------------------------------------------------
    SAFE.PARSE_DATETIME(
      '%Y-%m-%d %H:%M:%E*S',
      REPLACE(
        REGEXP_EXTRACT(
          JSON_VALUE(j, '$.file_name'),
          r'(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
        ),
        'T',
        ' '
      )
    ) AS filename_datetime,


    -- ------------------------------------------------------------------------
    -- INGESTION FALLBACK
    -- ------------------------------------------------------------------------
    COALESCE(
      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%d %H:%M:%E*S',
        NULLIF(
          TRIM(JSON_VALUE(j, '$.ingestion_timestamp')),
          ''
        )
      ),

      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%dT%H:%M:%E*S',
        NULLIF(
          TRIM(JSON_VALUE(j, '$.ingestion_timestamp')),
          ''
        )
      ),

      SAFE_CAST(
        NULLIF(
          TRIM(JSON_VALUE(j, '$.ingestion_timestamp')),
          ''
        )
        AS TIMESTAMP
      )
    ) AS ingestion_ts,


    -- ------------------------------------------------------------------------
    -- NIK
    -- ------------------------------------------------------------------------
    CASE
      WHEN REGEXP_CONTAINS(
        REGEXP_REPLACE(
          COALESCE(
            JSON_VALUE(j, '$.nik'),
            JSON_VALUE(j, '$.nik_ibu'),
            ''
          ),
          r'[^0-9]',
          ''
        ),
        r'^\d{16}$'
      )
      THEN REGEXP_REPLACE(
        COALESCE(
          JSON_VALUE(j, '$.nik'),
          JSON_VALUE(j, '$.nik_ibu'),
          ''
        ),
        r'[^0-9]',
        ''
      )
    END AS nik_clean,


    -- ------------------------------------------------------------------------
    -- NAME
    -- ------------------------------------------------------------------------
    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(
              JSON_VALUE(j, '$.nama'),
              JSON_VALUE(j, '$.nama_ibu'),
              ''
            )
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS nama_norm,


    -- ------------------------------------------------------------------------
    -- DOB
    -- schema tolerant
    -- ------------------------------------------------------------------------
    COALESCE(

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(j, '$.tgl_lahir'),
            JSON_VALUE(j, '$.tanggal_lahir'),
            JSON_VALUE(j, '$.tanggal_lahir_ibu')
          ),
          r'(\d{4}-\d{1,2}-\d{1,2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(j, '$.tgl_lahir'),
            JSON_VALUE(j, '$.tanggal_lahir'),
            JSON_VALUE(j, '$.tanggal_lahir_ibu')
          ),
          r'(\d{1,2}/\d{1,2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(j, '$.tgl_lahir'),
            JSON_VALUE(j, '$.tanggal_lahir'),
            JSON_VALUE(j, '$.tanggal_lahir_ibu')
          ),
          r'(\d{1,2}-\d{1,2}-\d{4})'
        )
      )

    ) AS tanggal_lahir_ibu,


    -- ------------------------------------------------------------------------
    -- DELIVERY DATE
    -- ------------------------------------------------------------------------
    COALESCE(

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(
              j,
              '$.status_persalinan_tanggal_melahirkan'
            ),
            JSON_VALUE(j, '$.tanggal_melahirkan'),
            JSON_VALUE(j, '$.tgl_melahirkan'),
            JSON_VALUE(j, '$.tanggal_persalinan')
          ),
          r'(\d{4}-\d{1,2}-\d{1,2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(
              j,
              '$.status_persalinan_tanggal_melahirkan'
            ),
            JSON_VALUE(j, '$.tanggal_melahirkan'),
            JSON_VALUE(j, '$.tgl_melahirkan'),
            JSON_VALUE(j, '$.tanggal_persalinan')
          ),
          r'(\d{1,2}/\d{1,2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(
              j,
              '$.status_persalinan_tanggal_melahirkan'
            ),
            JSON_VALUE(j, '$.tanggal_melahirkan'),
            JSON_VALUE(j, '$.tgl_melahirkan'),
            JSON_VALUE(j, '$.tanggal_persalinan')
          ),
          r'(\d{1,2}-\d{1,2}-\d{4})'
        )
      )

    ) AS raw_delivery_date

  FROM sigizi_kohort_ibu_json
),


-- ============================================================================
-- 5B. DAFTAR IBU
-- ============================================================================

sigizi_daftar_ibu_json AS (
  SELECT
    TO_JSON_STRING(t) AS j
  FROM
    `spheres-lombok-barat.raw_data.sigizi_daftar_ibu` t
),


sigizi_daftar_ibu AS (
  SELECT
    'DAFTAR_IBU' AS raw_source_table,

    JSON_VALUE(j, '$.file_name')
      AS file_name,


    SAFE.PARSE_DATETIME(
      '%Y-%m-%d %H:%M:%E*S',
      REPLACE(
        REGEXP_EXTRACT(
          JSON_VALUE(j, '$.file_name'),
          r'(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
        ),
        'T',
        ' '
      )
    ) AS filename_datetime,


    COALESCE(
      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%d %H:%M:%E*S',
        NULLIF(
          TRIM(JSON_VALUE(j, '$.ingestion_timestamp')),
          ''
        )
      ),

      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%dT%H:%M:%E*S',
        NULLIF(
          TRIM(JSON_VALUE(j, '$.ingestion_timestamp')),
          ''
        )
      ),

      SAFE_CAST(
        NULLIF(
          TRIM(JSON_VALUE(j, '$.ingestion_timestamp')),
          ''
        )
        AS TIMESTAMP
      )
    ) AS ingestion_ts,


    CASE
      WHEN REGEXP_CONTAINS(
        REGEXP_REPLACE(
          COALESCE(
            JSON_VALUE(j, '$.nik'),
            JSON_VALUE(j, '$.nik_ibu'),
            ''
          ),
          r'[^0-9]',
          ''
        ),
        r'^\d{16}$'
      )
      THEN REGEXP_REPLACE(
        COALESCE(
          JSON_VALUE(j, '$.nik'),
          JSON_VALUE(j, '$.nik_ibu'),
          ''
        ),
        r'[^0-9]',
        ''
      )
    END AS nik_clean,


    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(
              JSON_VALUE(j, '$.nama'),
              JSON_VALUE(j, '$.nama_ibu'),
              ''
            )
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS nama_norm,


    COALESCE(

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(j, '$.tgl_lahir'),
            JSON_VALUE(j, '$.tanggal_lahir'),
            JSON_VALUE(j, '$.tanggal_lahir_ibu')
          ),
          r'(\d{4}-\d{1,2}-\d{1,2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(j, '$.tgl_lahir'),
            JSON_VALUE(j, '$.tanggal_lahir'),
            JSON_VALUE(j, '$.tanggal_lahir_ibu')
          ),
          r'(\d{1,2}/\d{1,2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(j, '$.tgl_lahir'),
            JSON_VALUE(j, '$.tanggal_lahir'),
            JSON_VALUE(j, '$.tanggal_lahir_ibu')
          ),
          r'(\d{1,2}-\d{1,2}-\d{4})'
        )
      )

    ) AS tanggal_lahir_ibu,


    COALESCE(

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(j, '$.tanggal_melahirkan'),
            JSON_VALUE(j, '$.tgl_melahirkan'),
            JSON_VALUE(j, '$.tanggal_persalinan')
          ),
          r'(\d{4}-\d{1,2}-\d{1,2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(j, '$.tanggal_melahirkan'),
            JSON_VALUE(j, '$.tgl_melahirkan'),
            JSON_VALUE(j, '$.tanggal_persalinan')
          ),
          r'(\d{1,2}/\d{1,2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(j, '$.tanggal_melahirkan'),
            JSON_VALUE(j, '$.tgl_melahirkan'),
            JSON_VALUE(j, '$.tanggal_persalinan')
          ),
          r'(\d{1,2}-\d{1,2}-\d{4})'
        )
      )

    ) AS raw_delivery_date

  FROM sigizi_daftar_ibu_json
),


-- ============================================================================
-- 5C. KOHORT NIFAS
-- ============================================================================

sigizi_kohort_nifas_json AS (
  SELECT
    TO_JSON_STRING(t) AS j
  FROM
    `spheres-lombok-barat.raw_data.sigizi_ibu_nifas` t
),


sigizi_kohort_nifas AS (
  SELECT
    'KOHORT_NIFAS' AS raw_source_table,

    JSON_VALUE(j, '$.file_name')
      AS file_name,


    SAFE.PARSE_DATETIME(
      '%Y-%m-%d %H:%M:%E*S',
      REPLACE(
        REGEXP_EXTRACT(
          JSON_VALUE(j, '$.file_name'),
          r'(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
        ),
        'T',
        ' '
      )
    ) AS filename_datetime,


    COALESCE(
      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%d %H:%M:%E*S',
        NULLIF(
          TRIM(JSON_VALUE(j, '$.ingestion_timestamp')),
          ''
        )
      ),

      SAFE.PARSE_TIMESTAMP(
        '%Y-%m-%dT%H:%M:%E*S',
        NULLIF(
          TRIM(JSON_VALUE(j, '$.ingestion_timestamp')),
          ''
        )
      ),

      SAFE_CAST(
        NULLIF(
          TRIM(JSON_VALUE(j, '$.ingestion_timestamp')),
          ''
        )
        AS TIMESTAMP
      )
    ) AS ingestion_ts,


    CASE
      WHEN REGEXP_CONTAINS(
        REGEXP_REPLACE(
          COALESCE(
            JSON_VALUE(j, '$.nik'),
            JSON_VALUE(j, '$.nik_ibu'),
            ''
          ),
          r'[^0-9]',
          ''
        ),
        r'^\d{16}$'
      )
      THEN REGEXP_REPLACE(
        COALESCE(
          JSON_VALUE(j, '$.nik'),
          JSON_VALUE(j, '$.nik_ibu'),
          ''
        ),
        r'[^0-9]',
        ''
      )
    END AS nik_clean,


    NULLIF(
      TRIM(
        REGEXP_REPLACE(
          NORMALIZE_AND_CASEFOLD(
            COALESCE(
              JSON_VALUE(j, '$.nama'),
              JSON_VALUE(j, '$.nama_ibu'),
              ''
            )
          ),
          r'\s+',
          ' '
        )
      ),
      ''
    ) AS nama_norm,


    COALESCE(

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(j, '$.tgl_lahir'),
            JSON_VALUE(j, '$.tanggal_lahir'),
            JSON_VALUE(j, '$.tanggal_lahir_ibu')
          ),
          r'(\d{4}-\d{1,2}-\d{1,2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(j, '$.tgl_lahir'),
            JSON_VALUE(j, '$.tanggal_lahir'),
            JSON_VALUE(j, '$.tanggal_lahir_ibu')
          ),
          r'(\d{1,2}/\d{1,2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(j, '$.tgl_lahir'),
            JSON_VALUE(j, '$.tanggal_lahir'),
            JSON_VALUE(j, '$.tanggal_lahir_ibu')
          ),
          r'(\d{1,2}-\d{1,2}-\d{4})'
        )
      )

    ) AS tanggal_lahir_ibu,


    COALESCE(

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(j, '$.tgl_melahirkan'),
            JSON_VALUE(j, '$.tanggal_melahirkan'),
            JSON_VALUE(j, '$.tanggal_persalinan')
          ),
          r'(\d{4}-\d{1,2}-\d{1,2})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(j, '$.tgl_melahirkan'),
            JSON_VALUE(j, '$.tanggal_melahirkan'),
            JSON_VALUE(j, '$.tanggal_persalinan')
          ),
          r'(\d{1,2}/\d{1,2}/\d{4})'
        )
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        REGEXP_EXTRACT(
          COALESCE(
            JSON_VALUE(j, '$.tgl_melahirkan'),
            JSON_VALUE(j, '$.tanggal_melahirkan'),
            JSON_VALUE(j, '$.tanggal_persalinan')
          ),
          r'(\d{1,2}-\d{1,2}-\d{4})'
        )
      )

    ) AS raw_delivery_date

  FROM sigizi_kohort_nifas_json
),

-- ============================================================================
-- 6. COMBINE SIGIZI HISTORY
-- ============================================================================

sigizi_history_1 AS (

  SELECT * FROM sigizi_kohort_ibu

  UNION ALL

  SELECT * FROM sigizi_daftar_ibu

  UNION ALL

  SELECT * FROM sigizi_kohort_nifas
),


sigizi_history AS (
  SELECT
    *,

    COALESCE(
      filename_datetime,

      DATETIME(
        ingestion_ts,
        'Asia/Makassar'
      )
    ) AS capture_datetime,

    CASE
      WHEN filename_datetime IS NOT NULL
        THEN 'FILE_DATETIME_FROM_NAME'

      WHEN ingestion_ts IS NOT NULL
        THEN 'INGESTION_TIMESTAMP_FALLBACK'

      ELSE 'TIMESTAMP_MISSING'
    END AS capture_timestamp_method

  FROM sigizi_history_1

  WHERE raw_delivery_date IS NOT NULL
),


-- ============================================================================
-- 7. MATCH CANONICAL PREGNANCY TO ALL HISTORICAL SIGIZI FILES
-- ============================================================================

sigizi_candidates AS (
  SELECT
    p.pregnancy_episode_id,
    p.delivery_event_id,

    r.raw_source_table,

    r.file_name,
    r.capture_datetime,
    r.capture_timestamp_method,

    r.raw_delivery_date,

    CASE

      WHEN p.nik_clean IS NOT NULL
       AND r.nik_clean = p.nik_clean
       AND r.raw_delivery_date = p.delivery_date
        THEN 1

      WHEN p.nama_norm IS NOT NULL
       AND r.nama_norm = p.nama_norm
       AND p.tanggal_lahir_ibu IS NOT NULL
       AND r.tanggal_lahir_ibu = p.tanggal_lahir_ibu
       AND r.raw_delivery_date = p.delivery_date
        THEN 2

      WHEN p.nama_norm IS NOT NULL
       AND r.nama_norm = p.nama_norm
       AND r.raw_delivery_date = p.delivery_date
        THEN 3

      ELSE 99

    END AS history_match_priority

  FROM pregnancy_cohort p

  JOIN sigizi_history r

    ON p.delivery_date IS NOT NULL

   AND (
        (
          p.nik_clean IS NOT NULL
          AND r.nik_clean = p.nik_clean
        )

        OR

        (
          p.nama_norm IS NOT NULL
          AND r.nama_norm = p.nama_norm
        )
      )

   AND r.raw_delivery_date = p.delivery_date

  WHERE
    p.master_has_sigizi
),


sigizi_first_capture AS (
  SELECT
    * EXCEPT(rn)

  FROM (
    SELECT
      *,

      ROW_NUMBER() OVER (
        PARTITION BY pregnancy_episode_id

        ORDER BY
          history_match_priority,
          capture_datetime IS NULL,
          capture_datetime,
          raw_source_table,
          file_name
      ) AS rn

    FROM sigizi_candidates

    WHERE history_match_priority < 99
  )

  WHERE rn = 1
),


-- ============================================================================
-- 8. SOURCE SCAFFOLD
--
-- Every delivered pregnancy gets one EPUS row + one SIGIZI row.
-- ============================================================================

scaffold AS (
  SELECT
    p.*,
    evaluated_source

  FROM pregnancy_cohort p

  CROSS JOIN
    UNNEST(
      ['EPUS', 'SIGIZI']
    ) AS evaluated_source
),


-- ============================================================================
-- 9. ATTACH FIRST HISTORICAL CAPTURE
-- ============================================================================

attached AS (
  SELECT
    s.pregnancy_episode_id,
    s.delivery_event_id,

    s.nik_clean,
    s.nama_ibu,
    s.nama_norm,
    s.tanggal_lahir_ibu,

    s.expected_delivery_date,
    s.expected_delivery_date_source,

    DATE_TRUNC(
      s.expected_delivery_date,
      MONTH
    ) AS expected_delivery_month,

    s.pregnancy_delivery_status,

    s.delivery_date,

    DATE_TRUNC(
      s.delivery_date,
      MONTH
    ) AS delivery_month,

    s.delivery_outcome,

    s.delivery_source_combination,
    s.primary_delivery_source,

    s.pregnancy_source_combination,

    s.responsible_puskesmas,
    s.responsible_puskesmas_norm,

    s.responsible_desa,
    s.responsible_desa_norm,

    s.responsible_posyandu,

    s.evaluated_source,

    -- ------------------------------------------------------------------------
    -- Does canonical master say source captured birth?
    -- ------------------------------------------------------------------------
    CASE
      WHEN s.evaluated_source = 'EPUS'
        THEN s.master_has_epus

      WHEN s.evaluated_source = 'SIGIZI'
        THEN s.master_has_sigizi

      ELSE FALSE
    END AS source_recorded_master_flag,


    -- ------------------------------------------------------------------------
    -- History fields
    -- ------------------------------------------------------------------------
    CASE
      WHEN s.evaluated_source = 'EPUS'
        THEN e.file_name

      ELSE g.file_name
    END AS first_capture_file_name,


    CASE
      WHEN s.evaluated_source = 'EPUS'
        THEN e.capture_datetime

      ELSE g.capture_datetime
    END AS capture_datetime,


    CASE
      WHEN s.evaluated_source = 'EPUS'
        THEN e.capture_timestamp_method

      ELSE g.capture_timestamp_method
    END AS capture_timestamp_method,


    CASE
      WHEN s.evaluated_source = 'EPUS'
        THEN e.history_match_priority

      ELSE g.history_match_priority
    END AS history_match_priority,


    CASE
      WHEN s.evaluated_source = 'SIGIZI'
        THEN g.raw_source_table
    END AS first_sigizi_source_table,


    e.raw_delivery_datetime
      AS epus_delivery_datetime,


    -- ------------------------------------------------------------------------
    -- Was first history record actually found?
    -- ------------------------------------------------------------------------
    CASE
      WHEN s.evaluated_source = 'EPUS'
        THEN e.pregnancy_episode_id IS NOT NULL

      ELSE g.pregnancy_episode_id IS NOT NULL
    END AS historical_capture_found_flag

  FROM scaffold s

  LEFT JOIN epus_first_capture e

    ON s.evaluated_source = 'EPUS'

   AND s.pregnancy_episode_id
       = e.pregnancy_episode_id


  LEFT JOIN sigizi_first_capture g

    ON s.evaluated_source = 'SIGIZI'

   AND s.pregnancy_episode_id
       = g.pregnancy_episode_id
),


-- ============================================================================
-- 10. DELAYS
-- ============================================================================

delay_calc AS (
  SELECT
    *,

    DATE(capture_datetime)
      AS capture_date,

    CASE
      WHEN delivery_date IS NOT NULL
       AND capture_datetime IS NOT NULL

      THEN DATE_DIFF(
        DATE(capture_datetime),
        delivery_date,
        DAY
      )
    END AS capture_delay_days,


    -- Exact-hour calculation is EPUS only
    CASE
      WHEN evaluated_source = 'EPUS'

       AND delivery_date IS NOT NULL

       AND epus_delivery_datetime IS NOT NULL

       AND DATE(epus_delivery_datetime)
           = delivery_date

       AND capture_datetime IS NOT NULL

      THEN SAFE_DIVIDE(
        DATETIME_DIFF(
          capture_datetime,
          epus_delivery_datetime,
          MINUTE
        ),
        60.0
      )
    END AS capture_delay_hours

  FROM attached
),


-- ============================================================================
-- 11. CLASSIFICATION
-- ============================================================================

classified AS (
  SELECT
    *,

    (
      pregnancy_delivery_status = 'DELIVERED'
      AND delivery_date IS NOT NULL
    ) AS known_delivery_date_flag,


    CASE
      WHEN pregnancy_delivery_status
           != 'DELIVERED'
      THEN FALSE

      ELSE
        source_recorded_master_flag
        != historical_capture_found_flag
    END AS source_mapping_qa_flag,


    (
      pregnancy_delivery_status = 'DELIVERED'

      AND delivery_date IS NOT NULL

      AND source_recorded_master_flag

      AND historical_capture_found_flag

      AND capture_datetime IS NOT NULL

      AND capture_delay_days >= 0
    ) AS timeliness_eligible_flag,


    CASE

      WHEN pregnancy_delivery_status
           = 'DELIVERED_DATE_UNKNOWN'
        THEN 'DELIVERY_DATE_UNKNOWN'

      WHEN NOT source_recorded_master_flag
        THEN 'NOT_RECORDED_IN_SOURCE'

      WHEN NOT historical_capture_found_flag
        THEN 'HISTORICAL_CAPTURE_NOT_FOUND'

      WHEN capture_datetime IS NULL
        THEN 'CAPTURE_TIMESTAMP_MISSING'

      WHEN capture_delay_days < 0
        THEN 'QA_NEGATIVE_DELAY'

      WHEN capture_delay_days = 0
        THEN 'H0'

      WHEN capture_delay_days = 1
        THEN 'H+1'

      WHEN capture_delay_days BETWEEN 2 AND 3
        THEN 'H+2_TO_H+3'

      WHEN capture_delay_days BETWEEN 4 AND 7
        THEN 'H+4_TO_H+7'

      WHEN capture_delay_days >= 8
        THEN 'H+8_PLUS'

      ELSE 'UNKNOWN'

    END AS capture_delay_bucket,


    (
      pregnancy_delivery_status = 'DELIVERED'

      AND source_recorded_master_flag

      AND historical_capture_found_flag

      AND capture_delay_days BETWEEN 0 AND 1
    ) AS captured_by_hplus1_flag,


    (
      evaluated_source = 'EPUS'

      AND pregnancy_delivery_status = 'DELIVERED'

      AND source_recorded_master_flag

      AND historical_capture_found_flag

      AND epus_delivery_datetime IS NOT NULL

      AND capture_delay_hours >= 0
    ) AS exact_24h_eligible_flag,


    (
      evaluated_source = 'EPUS'

      AND pregnancy_delivery_status = 'DELIVERED'

      AND source_recorded_master_flag

      AND historical_capture_found_flag

      AND capture_delay_hours
          BETWEEN 0 AND 24
    ) AS captured_within_24h_flag

  FROM delay_calc
)


-- ============================================================================
-- FINAL
--
-- Grain:
--   pregnancy_episode_id × evaluated_source
-- ============================================================================

SELECT
  *,

  CAST(
    source_recorded_master_flag
    AS INT64
  ) AS recorded_in_source_count,

  CAST(
    NOT source_recorded_master_flag
    AS INT64
  ) AS not_recorded_in_source_count,

  CAST(
    known_delivery_date_flag
    AS INT64
  ) AS known_delivery_date_count,

  CAST(
    timeliness_eligible_flag
    AS INT64
  ) AS timeliness_eligible_count,

  CAST(
    captured_by_hplus1_flag
    AS INT64
  ) AS captured_by_hplus1_count,

  CAST(
    exact_24h_eligible_flag
    AS INT64
  ) AS exact_24h_eligible_count,

  CAST(
    captured_within_24h_flag
    AS INT64
  ) AS captured_within_24h_count,


  CASE capture_delay_bucket

    WHEN 'H0'
      THEN 1

    WHEN 'H+1'
      THEN 2

    WHEN 'H+2_TO_H+3'
      THEN 3

    WHEN 'H+4_TO_H+7'
      THEN 4

    WHEN 'H+8_PLUS'
      THEN 5

    WHEN 'NOT_RECORDED_IN_SOURCE'
      THEN 6

    WHEN 'DELIVERY_DATE_UNKNOWN'
      THEN 7

    WHEN 'HISTORICAL_CAPTURE_NOT_FOUND'
      THEN 8

    WHEN 'CAPTURE_TIMESTAMP_MISSING'
      THEN 9

    WHEN 'QA_NEGATIVE_DELAY'
      THEN 10

    ELSE 99

  END AS capture_delay_bucket_order

FROM classified""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_pregnancy_delivery_source_long
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_pregnancy_delivery_source_long');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_pregnancy_delivery_source_long';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_delivery_source_long` AS SELECT ',
 projection, ' FROM (', r"""WITH base AS (

  SELECT
    p.*

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_monitoring_integrated` p

  WHERE
    p.integrated_monitoring_status_all_history IN (
      'DELIVERED',
      'MISSING_BIRTH'
    )

),

source_long AS (

  SELECT
    p.*,

    source.delivery_source,
    source.source_recorded_flag,

    -- ========================================================================
    -- SOURCE-SPECIFIC DELIVERY STATUS
    --
    -- DELIVERED:
    --   Delivery is recorded in this particular source.
    --
    -- MISSING_BIRTH:
    --   Delivery is not recorded in this particular source.
    --
    -- This includes:
    --   1. pregnancy globally MISSING_BIRTH
    --   2. delivery known elsewhere but absent from this source
    -- ========================================================================

    CASE
      WHEN source.source_recorded_flag
        THEN 'DELIVERED'

      ELSE 'MISSING_BIRTH'

    END AS delivery_source_status,


    -- ========================================================================
    -- MORE DETAILED SOURCE STATUS
    -- ========================================================================

    CASE

      WHEN source.source_recorded_flag
        THEN 'DELIVERED_RECORDED_IN_SOURCE'

      WHEN p.integrated_monitoring_status_all_history = 'DELIVERED'
        THEN 'DELIVERED_KNOWN_ELSEWHERE_MISSING_IN_SOURCE'

      WHEN p.integrated_monitoring_status_all_history = 'MISSING_BIRTH'
        THEN 'DELIVERY_NOT_FOUND_ANYWHERE'

      ELSE 'OTHER'

    END AS delivery_source_status_detail,


    -- ========================================================================
    -- COUNTERS
    -- ========================================================================

    CAST(
      source.source_recorded_flag
      AS INT64
    ) AS source_delivered_count,


    CAST(
      NOT source.source_recorded_flag
      AS INT64
    ) AS source_missing_birth_count,


    1 AS source_denominator_count


  FROM base p

  CROSS JOIN UNNEST([

    STRUCT(
      'SIGIZI' AS delivery_source,
      COALESCE(
        p.integrated_has_delivery_sigizi,
        FALSE
      ) AS source_recorded_flag
    ),

    STRUCT(
      'EPUS' AS delivery_source,
      COALESCE(
        p.integrated_has_delivery_epus,
        FALSE
      ) AS source_recorded_flag
    ),

    STRUCT(
      'SIMRS' AS delivery_source,
      COALESCE(
        p.integrated_has_delivery_simrs,
        FALSE
      ) AS source_recorded_flag
    ),

    STRUCT(
      'NEONATAL_OUTCOME' AS delivery_source,
      COALESCE(
        p.integrated_has_delivery_neonatal,
        FALSE
      ) AS source_recorded_flag
    ),

    STRUCT(
      'INC_REPORT_TRACKER' AS delivery_source,
      COALESCE(
        p.integrated_has_delivery_inc_report,
        FALSE
      ) AS source_recorded_flag
    )

  ]) AS source

)

SELECT
  *
FROM source_long""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_pregnancy_monitoring_by_source_scope
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_pregnancy_monitoring_by_source_scope');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_pregnancy_monitoring_by_source_scope';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_monitoring_by_source_scope` AS SELECT ',
 projection, ' FROM (', r"""WITH base AS (

  SELECT
    *
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_monitoring_integrated`

)

SELECT
  source_scope,
  v.*

FROM base v

CROSS JOIN UNNEST(

  ARRAY_CONCAT(

    -- ========================================================================
    -- ALL
    -- Every pregnancy appears once in ALL
    -- ========================================================================

    ['ALL'],


    -- ========================================================================
    -- SIGIZI
    -- ========================================================================

    IF(
      COALESCE(v.in_sigizi_pregnancy, FALSE),
      ['SIGIZI'],
      CAST([] AS ARRAY<STRING>)
    ),


    -- ========================================================================
    -- EPUS
    -- ========================================================================

    IF(
      COALESCE(v.in_epus_pregnancy, FALSE),
      ['EPUS'],
      CAST([] AS ARRAY<STRING>)
    ),


    -- ========================================================================
    -- SIGIZI + EPUS
    -- ========================================================================

    IF(
      COALESCE(v.in_sigizi_pregnancy, FALSE)
      AND COALESCE(v.in_epus_pregnancy, FALSE),

      ['SIGIZI + EPUS'],

      CAST([] AS ARRAY<STRING>)
    ),


    -- ========================================================================
    -- SIGIZI ONLY
    -- ========================================================================

    IF(
      COALESCE(v.in_sigizi_pregnancy, FALSE)
      AND NOT COALESCE(v.in_epus_pregnancy, FALSE),

      ['SIGIZI ONLY'],

      CAST([] AS ARRAY<STRING>)
    ),


    -- ========================================================================
    -- EPUS ONLY
    -- ========================================================================

    IF(
      COALESCE(v.in_epus_pregnancy, FALSE)
      AND NOT COALESCE(v.in_sigizi_pregnancy, FALSE),

      ['EPUS ONLY'],

      CAST([] AS ARRAY<STRING>)
    )

  )

) AS source_scope""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_birth_capture_step_wedge_wide
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_birth_capture_step_wedge_wide');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_birth_capture_step_wedge_wide';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_birth_capture_step_wedge_wide` AS SELECT ',
 projection, ' FROM (', r"""WITH aggregated AS (

  SELECT

    expected_delivery_date,

    MAX(expected_delivery_week)
      AS expected_delivery_week,

    MAX(expected_delivery_month)
      AS expected_delivery_month,

    MAX(expected_delivery_quarter)
      AS expected_delivery_quarter,

    MAX(expected_delivery_year)
      AS expected_delivery_year,

    MAX(month_anchor_date)
      AS month_anchor_date,

    MAX(month_anchor_flag)
      AS month_anchor_flag,

    -- ========================================================================
    -- TOTAL
    --
    -- IMPORTANT:
    -- Total is calculated from SUM numerator / SUM denominator.
    -- It is NOT the average of group percentages.
    -- ========================================================================

    SUM(
      daily_expected_pregnancies
    ) AS total_expected_daily,

    SUM(
      daily_births_found
    ) AS total_births_found_daily,


    SUM(
      expected_pregnancies_7d
    ) AS total_expected_7d,

    SUM(
      births_found_7d
    ) AS total_births_found_7d,


    SUM(
      expected_pregnancies_30d
    ) AS total_expected_30d,

    SUM(
      births_found_30d
    ) AS total_births_found_30d,


    SUM(
      expected_pregnancies_month
    ) AS total_expected_month,

    SUM(
      births_found_month
    ) AS total_births_found_month,


    -- ========================================================================
    -- FLAGSHIP
    -- ========================================================================

    MAX(
      IF(
        step_wedge_group = 'Flagship',
        completeness_7d,
        NULL
      )
    ) AS flagship_completeness_7d,

    MAX(
      IF(
        step_wedge_group = 'Flagship',
        completeness_30d,
        NULL
      )
    ) AS flagship_completeness_30d,

    MAX(
      IF(
        step_wedge_group = 'Flagship',
        completeness_monthly,
        NULL
      )
    ) AS flagship_completeness_monthly,


    -- ========================================================================
    -- STEP WEDGE 1
    -- ========================================================================

    MAX(
      IF(
        step_wedge_group = 'Step Wedge 1',
        completeness_7d,
        NULL
      )
    ) AS step_wedge_1_completeness_7d,

    MAX(
      IF(
        step_wedge_group = 'Step Wedge 1',
        completeness_30d,
        NULL
      )
    ) AS step_wedge_1_completeness_30d,

    MAX(
      IF(
        step_wedge_group = 'Step Wedge 1',
        completeness_monthly,
        NULL
      )
    ) AS step_wedge_1_completeness_monthly,


    -- ========================================================================
    -- STEP WEDGE 2
    -- ========================================================================

    MAX(
      IF(
        step_wedge_group = 'Step Wedge 2',
        completeness_7d,
        NULL
      )
    ) AS step_wedge_2_completeness_7d,

    MAX(
      IF(
        step_wedge_group = 'Step Wedge 2',
        completeness_30d,
        NULL
      )
    ) AS step_wedge_2_completeness_30d,

    MAX(
      IF(
        step_wedge_group = 'Step Wedge 2',
        completeness_monthly,
        NULL
      )
    ) AS step_wedge_2_completeness_monthly,


    -- ========================================================================
    -- STEP WEDGE 3
    -- ========================================================================

    MAX(
      IF(
        step_wedge_group = 'Step Wedge 3',
        completeness_7d,
        NULL
      )
    ) AS step_wedge_3_completeness_7d,

    MAX(
      IF(
        step_wedge_group = 'Step Wedge 3',
        completeness_30d,
        NULL
      )
    ) AS step_wedge_3_completeness_30d,

    MAX(
      IF(
        step_wedge_group = 'Step Wedge 3',
        completeness_monthly,
        NULL
      )
    ) AS step_wedge_3_completeness_monthly,


    -- ========================================================================
    -- NON-INTERVENTIONS
    -- ========================================================================

    MAX(
      IF(
        step_wedge_group = 'Non-Interventions',
        completeness_7d,
        NULL
      )
    ) AS non_interventions_completeness_7d,

    MAX(
      IF(
        step_wedge_group = 'Non-Interventions',
        completeness_30d,
        NULL
      )
    ) AS non_interventions_completeness_30d,

    MAX(
      IF(
        step_wedge_group = 'Non-Interventions',
        completeness_monthly,
        NULL
      )
    ) AS non_interventions_completeness_monthly,


    -- ========================================================================
    -- INTERVENTION MARKERS
    -- ========================================================================

    MAX(step_wedge_1_marker)
      AS step_wedge_1_marker,

    MAX(step_wedge_2_marker)
      AS step_wedge_2_marker,

    MAX(step_wedge_3_marker)
      AS step_wedge_3_marker

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.v_birth_capture_step_wedge_daily`

  GROUP BY
    expected_delivery_date
)

SELECT

  *,

  -- ==========================================================================
  -- TOTAL DAILY
  -- ==========================================================================

  SAFE_DIVIDE(
    total_births_found_daily,
    total_expected_daily
  ) AS total_completeness_daily,


  -- ==========================================================================
  -- TOTAL 7-DAY
  -- ==========================================================================

  SAFE_DIVIDE(
    total_births_found_7d,
    total_expected_7d
  ) AS total_completeness_7d,


  -- ==========================================================================
  -- TOTAL 30-DAY
  -- ==========================================================================

  SAFE_DIVIDE(
    total_births_found_30d,
    total_expected_30d
  ) AS total_completeness_30d,


  -- ==========================================================================
  -- TOTAL MONTHLY
  -- ==========================================================================

  SAFE_DIVIDE(
    total_births_found_month,
    total_expected_month
  ) AS total_completeness_monthly

FROM aggregated""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_birth_reporting_timeliness_dashboard
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_birth_reporting_timeliness_dashboard');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_birth_reporting_timeliness_dashboard';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_birth_reporting_timeliness_dashboard` AS SELECT ',
 projection, ' FROM (', r"""SELECT
  *,

  CASE
    WHEN capture_delay_days < 0
      THEN 'QA: Negative'

    WHEN capture_delay_days = 0
      THEN 'Same Day'

    WHEN capture_delay_days = 1
      THEN '1 Day'

    WHEN capture_delay_days BETWEEN 2 AND 3
      THEN '2–3 Days'

    WHEN capture_delay_days BETWEEN 4 AND 7
      THEN '4–7 Days'

    WHEN capture_delay_days > 7
      THEN '>7 Days'

    ELSE 'Unknown'
  END AS reporting_delay_bucket,

  CASE
    WHEN capture_delay_days < 0 THEN 99
    WHEN capture_delay_days = 0 THEN 1
    WHEN capture_delay_days = 1 THEN 2
    WHEN capture_delay_days BETWEEN 2 AND 3 THEN 3
    WHEN capture_delay_days BETWEEN 4 AND 7 THEN 4
    WHEN capture_delay_days > 7 THEN 5
    ELSE 98
  END AS reporting_delay_bucket_order,

  capture_delay_days BETWEEN 0 AND 1
    AS within_1_day_flag,

  capture_delay_days BETWEEN 0 AND 3
    AS within_3_days_flag,

  capture_delay_days BETWEEN 0 AND 7
    AS within_7_days_flag,

  capture_delay_days > 7
    AS more_than_7_days_flag

FROM
  `spheres-lombok-barat.kohort_bumil_v3.v_birth_reporting_timeliness`""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_birth_reporting_timeliness_evidence
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_birth_reporting_timeliness_evidence');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_birth_reporting_timeliness_evidence';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_birth_reporting_timeliness_evidence` AS SELECT ',
 projection, ' FROM (', r"""WITH

-- ============================================================================
-- 1. BASE TIMELINESS RECORD
--
-- Existing grain:
-- pregnancy_episode_id × evaluated_source
-- ============================================================================

base_1 AS (
  SELECT
    b.*,

    -- ------------------------------------------------------------------------
    -- Which export family should be used for observation?
    -- ------------------------------------------------------------------------
    CASE

      WHEN evaluated_source = 'EPUS'
        THEN 'EPUS_INC'

      WHEN evaluated_source = 'SIGIZI'
        THEN first_sigizi_source_table

      ELSE NULL

    END AS observation_source_table,


    -- ------------------------------------------------------------------------
    -- Facility appearing in the file that first captured this birth
    -- ------------------------------------------------------------------------
    CASE

      WHEN evaluated_source = 'EPUS'
      THEN REGEXP_EXTRACT(
        first_capture_file_name,
        r'^(.*?)_ePuskesmas_'
      )

      WHEN evaluated_source = 'SIGIZI'
      THEN REGEXP_EXTRACT(
        first_capture_file_name,
        r'^(.*?)_SIGIZI_'
      )

    END AS observation_facility_file

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.v_birth_reporting_timeliness` b
),


-- ============================================================================
-- 2. NORMALIZE FACILITY NAME USED FOR EXPORT HISTORY
-- ============================================================================

base_2 AS (
  SELECT
    *,

    REGEXP_REPLACE(
      REGEXP_REPLACE(
        UPPER(
          TRIM(
            COALESCE(
              observation_facility_file,
              ''
            )
          )
        ),
        r'^PUSKESMAS\s+',
        ''
      ),
      r'[^A-Z0-9]',
      ''
    ) AS observation_facility_compact

  FROM base_1
),


base AS (
  SELECT
    * EXCEPT(observation_facility_compact),

    CASE

      WHEN observation_facility_compact IN (
        'PERAMPUAN',
        'PEREMPUAN'
      )
      THEN 'PERAMPUAN'

      ELSE observation_facility_compact

    END AS observation_facility_key

  FROM base_2
),


-- ============================================================================
-- 3. FIND PREVIOUS EXPORT
--
-- IMPORTANT:
-- Because capture_datetime is the EARLIEST file where this birth was found,
-- any earlier export for the SAME facility + SAME source table is an
-- observation in which this particular birth was not yet observed.
-- ============================================================================

previous_export_summary AS (
  SELECT
    b.pregnancy_episode_id,
    b.evaluated_source,

    MAX(e.export_datetime)
      AS previous_export_datetime,

    COUNT(e.export_datetime)
      AS exports_before_first_capture,

    COUNTIF(
      b.delivery_date IS NOT NULL

      AND e.export_datetime
          >= DATETIME(b.delivery_date)

      AND e.export_datetime
          < b.capture_datetime
    ) AS exports_between_delivery_and_capture

  FROM base b

  LEFT JOIN
    `spheres-lombok-barat.kohort_bumil_v3.v_birth_source_export_observations` e

    ON e.source_system
       = b.evaluated_source

   AND e.source_table
       = b.observation_source_table

   AND e.facility_key
       = b.observation_facility_key

   AND e.export_datetime
       < b.capture_datetime

  GROUP BY
    b.pregnancy_episode_id,
    b.evaluated_source
),


-- ============================================================================
-- 4. ATTACH PREVIOUS OBSERVATION
-- ============================================================================

observed AS (
  SELECT
    b.*,

    p.previous_export_datetime,

    DATE(
      p.previous_export_datetime
    ) AS previous_export_date,

    p.exports_before_first_capture,

    p.exports_between_delivery_and_capture,


    -- ------------------------------------------------------------------------
    -- H+1 calendar-day window
    --
    -- Delivery 10 July:
    -- H0 = 10 July
    -- H+1 = 11 July
    --
    -- End of allowed H+1 window is start of 12 July.
    -- ------------------------------------------------------------------------
    CASE
      WHEN b.delivery_date IS NOT NULL

      THEN DATETIME(
        DATE_ADD(
          b.delivery_date,
          INTERVAL 2 DAY
        )
      )
    END AS hplus1_end_exclusive,


    -- ------------------------------------------------------------------------
    -- Delay from delivery to previous export
    -- ------------------------------------------------------------------------
    CASE
      WHEN b.delivery_date IS NOT NULL
       AND p.previous_export_datetime IS NOT NULL

      THEN DATE_DIFF(
        DATE(p.previous_export_datetime),
        b.delivery_date,
        DAY
      )
    END AS previous_export_delay_days,


    -- ------------------------------------------------------------------------
    -- Observation gap immediately before first capture
    -- ------------------------------------------------------------------------
    CASE
      WHEN b.capture_datetime IS NOT NULL
       AND p.previous_export_datetime IS NOT NULL

      THEN DATETIME_DIFF(
        b.capture_datetime,
        p.previous_export_datetime,
        HOUR
      )
    END AS observation_gap_hours,


    CASE
      WHEN b.capture_datetime IS NOT NULL
       AND p.previous_export_datetime IS NOT NULL

      THEN SAFE_DIVIDE(
        DATETIME_DIFF(
          b.capture_datetime,
          p.previous_export_datetime,
          HOUR
        ),
        24.0
      )
    END AS observation_gap_days

  FROM base b

  LEFT JOIN previous_export_summary p
    USING (
      pregnancy_episode_id,
      evaluated_source
    )
),


-- ============================================================================
-- 5. H+1 EVIDENCE CLASSIFICATION
-- ============================================================================

hplus1_classified AS (
  SELECT
    *,

    -- ------------------------------------------------------------------------
    -- Is the record valid for evidence-based timeliness?
    -- ------------------------------------------------------------------------
    (
      pregnancy_delivery_status = 'DELIVERED'

      AND delivery_date IS NOT NULL

      AND source_recorded_master_flag

      AND historical_capture_found_flag

      AND capture_datetime IS NOT NULL

      AND capture_delay_days >= 0
    ) AS hplus1_evidence_eligible_flag,


    -- ------------------------------------------------------------------------
    -- Evidence classification
    -- ------------------------------------------------------------------------
    CASE

      WHEN pregnancy_delivery_status
           = 'DELIVERED_DATE_UNKNOWN'
        THEN 'DELIVERY_DATE_UNKNOWN'


      WHEN NOT source_recorded_master_flag
        THEN 'NOT_RECORDED_IN_SOURCE'


      WHEN NOT historical_capture_found_flag
        THEN 'HISTORICAL_CAPTURE_NOT_FOUND'


      WHEN capture_datetime IS NULL
        THEN 'CAPTURE_TIMESTAMP_MISSING'


      WHEN capture_delay_days < 0
        THEN 'QA_NEGATIVE_DELAY'


      -- ======================================================
      -- Guaranteed timely:
      -- birth itself was already observable during H0/H+1.
      -- ======================================================
      WHEN capture_datetime
           < hplus1_end_exclusive

        THEN 'GUARANTEED_BY_HPLUS1'


      -- ======================================================
      -- Definitely late:
      --
      -- We observed another export at/after the beginning
      -- of H+2, before the birth first appeared.
      --
      -- Therefore the birth was definitely not observable
      -- by the end of H+1.
      -- ======================================================
      WHEN previous_export_datetime IS NOT NULL

       AND previous_export_datetime
           >= hplus1_end_exclusive

        THEN 'DEFINITELY_AFTER_HPLUS1'


      -- ======================================================
      -- Could be entry delay OR export delay.
      -- ======================================================
      ELSE 'UNCERTAIN_EXPORT_GAP'

    END AS hplus1_evidence_status

  FROM observed
),


-- ============================================================================
-- 6. EXACT 24-HOUR EVIDENCE FOR EPUS
--
-- Only when exact baby birth datetime exists.
-- ============================================================================

exact24 AS (
  SELECT
    *,

    CASE
      WHEN evaluated_source = 'EPUS'

       AND epus_delivery_datetime IS NOT NULL

      THEN DATETIME_ADD(
        epus_delivery_datetime,
        INTERVAL 24 HOUR
      )
    END AS exact_24h_deadline,


    (
      evaluated_source = 'EPUS'

      AND pregnancy_delivery_status = 'DELIVERED'

      AND source_recorded_master_flag

      AND historical_capture_found_flag

      AND epus_delivery_datetime IS NOT NULL

      AND capture_datetime IS NOT NULL

      AND capture_datetime >= epus_delivery_datetime
    ) AS exact_24h_evidence_eligible_flag

  FROM hplus1_classified
),


exact24_classified AS (
  SELECT
    *,

    CASE

      WHEN evaluated_source != 'EPUS'
        THEN 'NOT_APPLICABLE'


      WHEN epus_delivery_datetime IS NULL
        THEN 'EXACT_BIRTH_TIME_UNAVAILABLE'


      WHEN NOT source_recorded_master_flag
        THEN 'NOT_RECORDED_IN_EPUS'


      WHEN NOT historical_capture_found_flag
        THEN 'HISTORICAL_CAPTURE_NOT_FOUND'


      WHEN capture_datetime IS NULL
        THEN 'CAPTURE_TIMESTAMP_MISSING'


      WHEN capture_datetime < epus_delivery_datetime
        THEN 'QA_NEGATIVE_DELAY'


      -- Observed within 24 hours
      WHEN capture_datetime
           <= exact_24h_deadline

        THEN 'GUARANTEED_WITHIN_24H'


      -- There was an export after the 24h deadline
      -- where the birth was still absent
      WHEN previous_export_datetime IS NOT NULL

       AND previous_export_datetime
           >= exact_24h_deadline

        THEN 'DEFINITELY_AFTER_24H'


      ELSE 'UNCERTAIN_EXPORT_GAP'

    END AS exact_24h_evidence_status

  FROM exact24
)


-- ============================================================================
-- FINAL
-- ============================================================================

SELECT
  *,

  -- ==========================================================================
  -- H+1 numeric flags for Looker
  -- ==========================================================================

  CAST(
    hplus1_evidence_eligible_flag
    AS INT64
  ) AS hplus1_evidence_eligible_count,


  CAST(
    hplus1_evidence_status
      = 'GUARANTEED_BY_HPLUS1'
    AS INT64
  ) AS guaranteed_by_hplus1_count,


  CAST(
    hplus1_evidence_status
      = 'DEFINITELY_AFTER_HPLUS1'
    AS INT64
  ) AS definitely_after_hplus1_count,


  CAST(
    hplus1_evidence_status
      = 'UNCERTAIN_EXPORT_GAP'
    AS INT64
  ) AS uncertain_export_gap_count,


  -- ==========================================================================
  -- Exact 24h numeric flags
  -- ==========================================================================

  CAST(
    exact_24h_evidence_eligible_flag
    AS INT64
  ) AS exact_24h_evidence_eligible_count,


  CAST(
    exact_24h_evidence_status
      = 'GUARANTEED_WITHIN_24H'
    AS INT64
  ) AS guaranteed_within_24h_count,


  CAST(
    exact_24h_evidence_status
      = 'DEFINITELY_AFTER_24H'
    AS INT64
  ) AS definitely_after_24h_count,


  CAST(
    exact_24h_evidence_status
      = 'UNCERTAIN_EXPORT_GAP'
    AS INT64
  ) AS uncertain_exact_24h_count,


  -- ==========================================================================
  -- Sort order
  -- ==========================================================================

  CASE hplus1_evidence_status

    WHEN 'GUARANTEED_BY_HPLUS1'
      THEN 1

    WHEN 'DEFINITELY_AFTER_HPLUS1'
      THEN 2

    WHEN 'UNCERTAIN_EXPORT_GAP'
      THEN 3

    WHEN 'NOT_RECORDED_IN_SOURCE'
      THEN 4

    WHEN 'HISTORICAL_CAPTURE_NOT_FOUND'
      THEN 5

    WHEN 'DELIVERY_DATE_UNKNOWN'
      THEN 6

    WHEN 'CAPTURE_TIMESTAMP_MISSING'
      THEN 7

    WHEN 'QA_NEGATIVE_DELAY'
      THEN 8

    ELSE 99

  END AS hplus1_evidence_status_order

FROM exact24_classified""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_edd_usg_hpht_paired
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_edd_usg_hpht_paired');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_edd_usg_hpht_paired';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_edd_usg_hpht_paired` AS SELECT ',
 projection, ' FROM (', r"""WITH base AS (

  SELECT

    -- ========================================================================
    -- IDENTIFIERS
    -- ========================================================================
    outcome_event_id,

    pregnancy_episode_id,

    outcome_event_date
      AS actual_delivery_date,

    outcome_month,

    dashboard_puskesmas,

    dashboard_desa,

    dashboard_posyandu,


    -- ========================================================================
    -- DATING INPUTS
    -- ========================================================================
    hpht_date,

    dating_usg_date,

    dating_usg_ga_days,

    dating_usg_ga_weeks,

    usg_dating_quality,

    usg_recorded_hpl_date,

    hpl_from_usg_ga_date,


    -- ========================================================================
    -- COMMON USG METHOD FILTER
    -- ========================================================================
    CASE

      WHEN usg_dating_quality = 'EARLY_USG_LE_14W'
       AND dating_usg_date IS NOT NULL
       AND dating_usg_ga_days IS NOT NULL
        THEN 'USG <=14 minggu'

      WHEN usg_dating_quality = 'USG_14_22W'
       AND dating_usg_date IS NOT NULL
       AND dating_usg_ga_days IS NOT NULL
        THEN 'USG 14–22 minggu'

      WHEN usg_dating_quality = 'RECORDED_USG_EDD_GA_UNKNOWN'
       AND usg_recorded_hpl_date IS NOT NULL
        THEN 'USG recorded EDD'

      WHEN usg_dating_quality = 'LATE_USG_GT_22W'
       AND dating_usg_date IS NOT NULL
       AND dating_usg_ga_days IS NOT NULL
        THEN 'USG >22 minggu'

      ELSE 'USG tidak tersedia'

    END AS usg_edd_method,


    CASE

      WHEN usg_dating_quality = 'EARLY_USG_LE_14W'
        THEN 1

      WHEN usg_dating_quality = 'USG_14_22W'
        THEN 2

      WHEN usg_dating_quality = 'RECORDED_USG_EDD_GA_UNKNOWN'
        THEN 3

      WHEN usg_dating_quality = 'LATE_USG_GT_22W'
        THEN 4

      ELSE 5

    END AS usg_edd_method_order,


    -- ========================================================================
    -- HPHT EDD
    -- ========================================================================
    CASE

      WHEN hpht_date IS NOT NULL

      THEN DATE_ADD(
        hpht_date,
        INTERVAL 280 DAY
      )

    END AS hpht_edd,


    -- ========================================================================
    -- USG EDD
    -- ========================================================================
    CASE

      -- EARLY USG
      WHEN usg_dating_quality = 'EARLY_USG_LE_14W'
       AND dating_usg_date IS NOT NULL
       AND dating_usg_ga_days IS NOT NULL

      THEN DATE_ADD(
        dating_usg_date,
        INTERVAL (
          280 - dating_usg_ga_days
        ) DAY
      )


      -- USG 14–22W
      WHEN usg_dating_quality = 'USG_14_22W'
       AND dating_usg_date IS NOT NULL
       AND dating_usg_ga_days IS NOT NULL

      THEN DATE_ADD(
        dating_usg_date,
        INTERVAL (
          280 - dating_usg_ga_days
        ) DAY
      )


      -- RECORDED USG EDD
      WHEN usg_dating_quality = 'RECORDED_USG_EDD_GA_UNKNOWN'
       AND usg_recorded_hpl_date IS NOT NULL

      THEN usg_recorded_hpl_date


      -- LATE USG
      WHEN usg_dating_quality = 'LATE_USG_GT_22W'
       AND dating_usg_date IS NOT NULL
       AND dating_usg_ga_days IS NOT NULL

      THEN DATE_ADD(
        dating_usg_date,
        INTERVAL (
          280 - dating_usg_ga_days
        ) DAY
      )


      ELSE NULL

    END AS usg_edd

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.v_birth_outcome_event_dashboard`

  WHERE
    event_type = 'DELIVERY'

    AND outcome_event_date IS NOT NULL
),


-- ============================================================================
-- DEVIATION
-- ============================================================================

deviation AS (

  SELECT
    *,


    CASE

      WHEN usg_edd IS NOT NULL

      THEN DATE_DIFF(
        actual_delivery_date,
        usg_edd,
        DAY
      )

    END AS usg_delivery_deviation_days,


    CASE

      WHEN hpht_edd IS NOT NULL

      THEN DATE_DIFF(
        actual_delivery_date,
        hpht_edd,
        DAY
      )

    END AS hpht_delivery_deviation_days

  FROM base
),


-- ============================================================================
-- ABSOLUTE DEVIATION + PLAUSIBILITY
-- ============================================================================

paired_candidates AS (

  SELECT
    *,


    ABS(
      usg_delivery_deviation_days
    ) AS usg_absolute_deviation_days,


    ABS(
      hpht_delivery_deviation_days
    ) AS hpht_absolute_deviation_days,


    CAST(
      usg_delivery_deviation_days
        BETWEEN -154 AND 42
      AS INT64
    ) AS usg_deviation_plausible_flag,


    CAST(
      hpht_delivery_deviation_days
        BETWEEN -154 AND 42
      AS INT64
    ) AS hpht_deviation_plausible_flag

  FROM deviation
),


-- ============================================================================
-- TRUE PAIRED SAMPLE
-- ============================================================================

paired AS (

  SELECT
    *

  FROM paired_candidates

  WHERE
    usg_edd IS NOT NULL

    AND hpht_edd IS NOT NULL

    AND usg_deviation_plausible_flag = 1

    AND hpht_deviation_plausible_flag = 1
),


-- ============================================================================
-- WHICH METHOD IS CLOSER?
-- ============================================================================

comparison AS (

  SELECT
    *,


    usg_absolute_deviation_days
      -
    hpht_absolute_deviation_days
      AS usg_minus_hpht_absolute_error_days,


    CASE

      WHEN usg_absolute_deviation_days
         <
           hpht_absolute_deviation_days

        THEN 'USG Closer'

      WHEN hpht_absolute_deviation_days
         <
           usg_absolute_deviation_days

        THEN 'LMP Closer'

      ELSE 'Same Distance'

    END AS closer_edd_method,


    CAST(
      usg_absolute_deviation_days <= 7
      AS INT64
    ) AS usg_within_7d_flag,


    CAST(
      hpht_absolute_deviation_days <= 7
      AS INT64
    ) AS hpht_within_7d_flag,


    CAST(
      usg_absolute_deviation_days <= 14
      AS INT64
    ) AS usg_within_14d_flag,


    CAST(
      hpht_absolute_deviation_days <= 14
      AS INT64
    ) AS hpht_within_14d_flag,


    1 AS paired_edd_count

  FROM paired
),


-- ============================================================================
-- GLOBAL SUMMARY
-- ============================================================================

summary AS (

  SELECT
    *,


    COUNT(*) OVER ()
      AS paired_edd_analysis_n,


    AVG(
      CAST(
        usg_delivery_deviation_days
        AS FLOAT64
      )
    ) OVER ()
      AS usg_mean_signed_deviation_days,


    PERCENTILE_CONT(
      CAST(
        usg_delivery_deviation_days
        AS FLOAT64
      ),
      0.50
    ) OVER ()
      AS usg_median_signed_deviation_days,


    AVG(
      CAST(
        hpht_delivery_deviation_days
        AS FLOAT64
      )
    ) OVER ()
      AS hpht_mean_signed_deviation_days,


    PERCENTILE_CONT(
      CAST(
        hpht_delivery_deviation_days
        AS FLOAT64
      ),
      0.50
    ) OVER ()
      AS hpht_median_signed_deviation_days,


    AVG(
      CAST(
        usg_absolute_deviation_days
        AS FLOAT64
      )
    ) OVER ()
      AS usg_mean_absolute_deviation_days,


    AVG(
      CAST(
        hpht_absolute_deviation_days
        AS FLOAT64
      )
    ) OVER ()
      AS hpht_mean_absolute_deviation_days,


    PERCENTILE_CONT(
      CAST(
        usg_absolute_deviation_days
        AS FLOAT64
      ),
      0.50
    ) OVER ()
      AS usg_median_absolute_deviation_days,


    PERCENTILE_CONT(
      CAST(
        hpht_absolute_deviation_days
        AS FLOAT64
      ),
      0.50
    ) OVER ()
      AS hpht_median_absolute_deviation_days,


    100.0
      *
    AVG(
      CAST(
        usg_within_7d_flag
        AS FLOAT64
      )
    ) OVER ()
      AS usg_within_7d_pct,


    100.0
      *
    AVG(
      CAST(
        hpht_within_7d_flag
        AS FLOAT64
      )
    ) OVER ()
      AS hpht_within_7d_pct,


    100.0
      *
    AVG(
      CAST(
        usg_within_14d_flag
        AS FLOAT64
      )
    ) OVER ()
      AS usg_within_14d_pct,


    100.0
      *
    AVG(
      CAST(
        hpht_within_14d_flag
        AS FLOAT64
      )
    ) OVER ()
      AS hpht_within_14d_pct,


    100.0
      *
    AVG(
      CAST(
        closer_edd_method = 'USG Lebih Dekat'
        AS INT64
      )
    ) OVER ()
      AS usg_closer_pct,


    100.0
      *
    AVG(
      CAST(
        closer_edd_method = 'HPHT Lebih Dekat'
        AS INT64
      )
    ) OVER ()
      AS hpht_closer_pct,


    100.0
      *
    AVG(
      CAST(
        closer_edd_method = 'Sama Jarak'
        AS INT64
      )
    ) OVER ()
      AS same_distance_pct,


    COUNTIF(
      closer_edd_method = 'USG Lebih Dekat'
    ) OVER ()
      AS usg_closer_count,


    COUNTIF(
      closer_edd_method = 'HPHT Lebih Dekat'
    ) OVER ()
      AS hpht_closer_count,


    COUNTIF(
      closer_edd_method = 'Sama Jarak'
    ) OVER ()
      AS same_distance_count

  FROM comparison
)


SELECT *
FROM summary""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_ga_usg_hpht_paired
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_ga_usg_hpht_paired');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_ga_usg_hpht_paired';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_ga_usg_hpht_paired` AS SELECT ',
 projection, ' FROM (', r"""WITH paired_base AS (

  SELECT

    -- ========================================================================
    -- IDENTIFIERS
    -- ========================================================================
    outcome_event_id,

    pregnancy_episode_id,

    outcome_event_date,

    outcome_month,

    dashboard_puskesmas,

    dashboard_desa,

    dashboard_posyandu,


    -- ========================================================================
    -- ORIGINAL DATING INPUTS
    -- ========================================================================
    hpht_date,

    dating_usg_date,

    dating_usg_ga_days,

    dating_usg_ga_weeks,

    usg_dating_quality,

    usg_recorded_hpl_date,

    hpl_from_usg_ga_date,


    -- ========================================================================
    -- COMMON USG METHOD FILTER
    --
    -- IMPORTANT:
    -- Keep these exact labels identical in all four views.
    -- ========================================================================
    CASE

      WHEN usg_dating_quality = 'EARLY_USG_LE_14W'
       AND dating_usg_date IS NOT NULL
       AND dating_usg_ga_days IS NOT NULL
        THEN 'USG <=14 minggu'

      WHEN usg_dating_quality = 'USG_14_22W'
       AND dating_usg_date IS NOT NULL
       AND dating_usg_ga_days IS NOT NULL
        THEN 'USG 14–22 minggu'

      WHEN usg_dating_quality = 'RECORDED_USG_EDD_GA_UNKNOWN'
       AND usg_recorded_hpl_date IS NOT NULL
        THEN 'USG recorded EDD'

      WHEN usg_dating_quality = 'LATE_USG_GT_22W'
       AND dating_usg_date IS NOT NULL
       AND dating_usg_ga_days IS NOT NULL
        THEN 'USG >22 minggu'

      ELSE 'USG tidak tersedia'

    END AS usg_edd_method,


    CASE

      WHEN usg_dating_quality = 'EARLY_USG_LE_14W'
        THEN 1

      WHEN usg_dating_quality = 'USG_14_22W'
        THEN 2

      WHEN usg_dating_quality = 'RECORDED_USG_EDD_GA_UNKNOWN'
        THEN 3

      WHEN usg_dating_quality = 'LATE_USG_GT_22W'
        THEN 4

      ELSE 5

    END AS usg_edd_method_order,


    -- ========================================================================
    -- INDEPENDENT GA
    -- ========================================================================
    ga_usg_independent_days,

    ga_hpht_independent_days,


    SAFE_DIVIDE(
      ga_usg_independent_days,
      7.0
    ) AS ga_usg_weeks,


    SAFE_DIVIDE(
      ga_hpht_independent_days,
      7.0
    ) AS ga_hpht_weeks,


    -- ========================================================================
    -- USG - HPHT DIFFERENCE
    -- ========================================================================
    ga_usg_independent_days
      -
    ga_hpht_independent_days
      AS ga_usg_minus_hpht_days,


    ABS(
      ga_usg_independent_days
        -
      ga_hpht_independent_days
    ) AS ga_usg_hpht_absolute_difference_days

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.v_birth_outcome_event_dashboard`

  WHERE
    event_type = 'DELIVERY'

    AND ga_usg_independent_days
      BETWEEN 126 AND 322

    AND ga_hpht_independent_days
      BETWEEN 126 AND 322
),


-- ============================================================================
-- CLASSIFICATION
-- ============================================================================

classified AS (

  SELECT
    *,


    -- ------------------------------------------------------------------------
    -- COMPLETED GA WEEKS
    -- ------------------------------------------------------------------------
    CAST(
      FLOOR(
        ga_usg_weeks
      )
      AS INT64
    ) AS ga_usg_completed_weeks,


    CAST(
      FLOOR(
        ga_hpht_weeks
      )
      AS INT64
    ) AS ga_hpht_completed_weeks,


    -- ------------------------------------------------------------------------
    -- USG CLINICAL CATEGORY
    -- ------------------------------------------------------------------------
    CASE

      WHEN ga_usg_independent_days < 259
        THEN 'Preterm'

      WHEN ga_usg_independent_days < 294
        THEN 'Aterm'

      WHEN ga_usg_independent_days < 301
        THEN 'Post-term'

      ELSE 'GA Ekstrem / Perlu Validasi'

    END AS ga_usg_category,


    -- ------------------------------------------------------------------------
    -- HPHT CLINICAL CATEGORY
    -- ------------------------------------------------------------------------
    CASE

      WHEN ga_hpht_independent_days < 259
        THEN 'Preterm'

      WHEN ga_hpht_independent_days < 294
        THEN 'Aterm'

      WHEN ga_hpht_independent_days < 301
        THEN 'Post-term'

      ELSE 'GA Ekstrem / Perlu Validasi'

    END AS ga_hpht_category,


    -- ------------------------------------------------------------------------
    -- CLINICALLY USABLE
    --
    -- <=42w6d = <=300 days
    -- ------------------------------------------------------------------------
    CAST(
      ga_usg_independent_days BETWEEN 126 AND 300
      AS INT64
    ) AS ga_usg_clinical_usable_flag,


    CAST(
      ga_hpht_independent_days BETWEEN 126 AND 300
      AS INT64
    ) AS ga_hpht_clinical_usable_flag,


    -- ------------------------------------------------------------------------
    -- DIFFERENCE DIRECTION
    -- ------------------------------------------------------------------------
    CASE

      WHEN ga_usg_independent_days
         -
           ga_hpht_independent_days < 0
        THEN 'USG Lebih Rendah'

      WHEN ga_usg_independent_days
         -
           ga_hpht_independent_days = 0
        THEN 'Sama'

      ELSE 'USG Lebih Tinggi'

    END AS ga_difference_direction,


    -- ------------------------------------------------------------------------
    -- AGREEMENT CATEGORY
    -- ------------------------------------------------------------------------
    CASE

      WHEN ABS(
        ga_usg_independent_days
          -
        ga_hpht_independent_days
      ) <= 7
        THEN 'Selisih ≤7 hari'

      WHEN ABS(
        ga_usg_independent_days
          -
        ga_hpht_independent_days
      ) <= 14
        THEN 'Selisih 8–14 hari'

      ELSE 'Selisih >14 hari'

    END AS ga_difference_category,


    -- ------------------------------------------------------------------------
    -- COUNTERS
    -- ------------------------------------------------------------------------
    1 AS paired_pregnancy_count,


    CAST(
      ABS(
        ga_usg_independent_days
          -
        ga_hpht_independent_days
      ) <= 7
      AS INT64
    ) AS agreement_within_7d_count,


    CAST(
      ABS(
        ga_usg_independent_days
          -
        ga_hpht_independent_days
      ) <= 14
      AS INT64
    ) AS agreement_within_14d_count,


    CAST(
      ABS(
        ga_usg_independent_days
          -
        ga_hpht_independent_days
      ) > 14
      AS INT64
    ) AS disagreement_gt14d_count

  FROM paired_base
),


-- ============================================================================
-- SUMMARY
--
-- Global summary fields.
-- For filter-responsive charts, use the raw row-level fields/counters.
-- ============================================================================

with_summary AS (

  SELECT
    *,


    COUNT(*) OVER ()
      AS paired_analysis_n,


    AVG(
      ga_usg_weeks
    ) OVER ()
      AS paired_usg_mean_weeks,


    PERCENTILE_CONT(
      ga_usg_weeks,
      0.50
    ) OVER ()
      AS paired_usg_median_weeks,


    AVG(
      ga_hpht_weeks
    ) OVER ()
      AS paired_hpht_mean_weeks,


    PERCENTILE_CONT(
      ga_hpht_weeks,
      0.50
    ) OVER ()
      AS paired_hpht_median_weeks,


    AVG(
      CAST(
        ga_usg_minus_hpht_days
        AS FLOAT64
      )
    ) OVER ()
      AS paired_mean_difference_days,


    PERCENTILE_CONT(
      CAST(
        ga_usg_minus_hpht_days
        AS FLOAT64
      ),
      0.50
    ) OVER ()
      AS paired_median_difference_days,


    PERCENTILE_CONT(
      CAST(
        ga_usg_minus_hpht_days
        AS FLOAT64
      ),
      0.05
    ) OVER ()
      AS paired_difference_p05_days,


    PERCENTILE_CONT(
      CAST(
        ga_usg_minus_hpht_days
        AS FLOAT64
      ),
      0.95
    ) OVER ()
      AS paired_difference_p95_days,


    AVG(
      CAST(
        ga_usg_hpht_absolute_difference_days
        AS FLOAT64
      )
    ) OVER ()
      AS paired_mean_absolute_difference_days,


    100.0
      *
    AVG(
      CAST(
        ga_usg_hpht_absolute_difference_days <= 7
        AS INT64
      )
    ) OVER ()
      AS paired_within_7d_pct,


    100.0
      *
    AVG(
      CAST(
        ga_usg_hpht_absolute_difference_days <= 14
        AS INT64
      )
    ) OVER ()
      AS paired_within_14d_pct,


    100.0
      *
    AVG(
      CAST(
        ga_usg_hpht_absolute_difference_days > 14
        AS INT64
      )
    ) OVER ()
      AS paired_gt14d_pct

  FROM classified
)


SELECT *
FROM with_summary""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_edd_usg_hpht_paired_distribution
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_edd_usg_hpht_paired_distribution');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_edd_usg_hpht_paired_distribution';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_edd_usg_hpht_paired_distribution` AS SELECT ',
 projection, ' FROM (', r"""WITH long_format AS (

  -- ==========================================================================
  -- USG
  -- ==========================================================================

  SELECT

    outcome_event_id,

    pregnancy_episode_id,

    actual_delivery_date,

    outcome_month,

    dashboard_puskesmas,

    dashboard_desa,

    dashboard_posyandu,


    -- ------------------------------------------------------------------------
    -- COMMON FILTER
    -- ------------------------------------------------------------------------
    usg_edd_method,

    usg_edd_method_order,


    -- ------------------------------------------------------------------------
    -- METHOD
    -- ------------------------------------------------------------------------
    'USG' AS dating_method,


    usg_edd
      AS expected_delivery_date,


    usg_delivery_deviation_days
      AS delivery_deviation_days,


    usg_absolute_deviation_days
      AS absolute_deviation_days,


    1 AS paired_distribution_count

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.v_edd_usg_hpht_paired`


  UNION ALL


  -- ==========================================================================
  -- HPHT
  -- ==========================================================================

  SELECT

    outcome_event_id,

    pregnancy_episode_id,

    actual_delivery_date,

    outcome_month,

    dashboard_puskesmas,

    dashboard_desa,

    dashboard_posyandu,


    -- ------------------------------------------------------------------------
    -- SAME USG METHOD FILTER
    -- ------------------------------------------------------------------------
    usg_edd_method,

    usg_edd_method_order,


    'HPHT' AS dating_method,


    hpht_edd
      AS expected_delivery_date,


    hpht_delivery_deviation_days
      AS delivery_deviation_days,


    hpht_absolute_deviation_days
      AS absolute_deviation_days,


    1 AS paired_distribution_count

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.v_edd_usg_hpht_paired`
),


distribution AS (

  SELECT
    *,


    -- ------------------------------------------------------------------------
    -- OVERALL N
    -- ------------------------------------------------------------------------
    COUNT(*) OVER (
      PARTITION BY dating_method
    ) AS method_n,


    -- ========================================================================
    -- SIGNED DEVIATION DISTRIBUTION
    -- ========================================================================

    COUNT(*) OVER (

      PARTITION BY
        dating_method,
        delivery_deviation_days

    ) AS method_deviation_count,


    100.0
      *
    SAFE_DIVIDE(

      COUNT(*) OVER (

        PARTITION BY
          dating_method,
          delivery_deviation_days

      ),

      COUNT(*) OVER (
        PARTITION BY dating_method
      )

    ) AS method_deviation_pct,


    -- ========================================================================
    -- ABSOLUTE DEVIATION DISTRIBUTION
    -- ========================================================================

    COUNT(*) OVER (

      PARTITION BY
        dating_method,
        absolute_deviation_days

    ) AS method_absolute_deviation_count,


    100.0
      *
    SAFE_DIVIDE(

      COUNT(*) OVER (

        PARTITION BY
          dating_method,
          absolute_deviation_days

      ),

      COUNT(*) OVER (
        PARTITION BY dating_method
      )

    ) AS method_absolute_deviation_pct,


    -- ========================================================================
    -- DISTRIBUTION WITHIN USG METHOD
    --
    -- Useful when using the shared usg_edd_method filter.
    -- ========================================================================

    COUNT(*) OVER (

      PARTITION BY
        usg_edd_method,
        dating_method

    ) AS method_n_within_usg_method,


    -- ------------------------------------------------------------------------
    -- SIGNED
    -- ------------------------------------------------------------------------
    COUNT(*) OVER (

      PARTITION BY
        usg_edd_method,
        dating_method,
        delivery_deviation_days

    ) AS method_deviation_count_within_usg_method,


    100.0
      *
    SAFE_DIVIDE(

      COUNT(*) OVER (

        PARTITION BY
          usg_edd_method,
          dating_method,
          delivery_deviation_days

      ),

      COUNT(*) OVER (

        PARTITION BY
          usg_edd_method,
          dating_method

      )

    ) AS method_deviation_pct_within_usg_method,


    -- ------------------------------------------------------------------------
    -- ABSOLUTE
    -- ------------------------------------------------------------------------
    COUNT(*) OVER (

      PARTITION BY
        usg_edd_method,
        dating_method,
        absolute_deviation_days

    ) AS method_absolute_deviation_count_within_usg_method,


    100.0
      *
    SAFE_DIVIDE(

      COUNT(*) OVER (

        PARTITION BY
          usg_edd_method,
          dating_method,
          absolute_deviation_days

      ),

      COUNT(*) OVER (

        PARTITION BY
          usg_edd_method,
          dating_method

      )

    ) AS method_absolute_deviation_pct_within_usg_method

  FROM long_format
)


SELECT *
FROM distribution""", ') q');
EXECUTE IMMEDIATE deployed_sql;

-- v_ga_usg_hpht_paired_distribution
SET projection = (SELECT STRING_AGG(CONCAT('q.`',column_name,'`'), ', ' ORDER BY ordinal_position)
 FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns` WHERE table_name = 'v_ga_usg_hpht_paired_distribution');
ASSERT projection IS NOT NULL AS 'Missing captured schema for v_ga_usg_hpht_paired_distribution';
SET deployed_sql = CONCAT('CREATE OR REPLACE VIEW `spheres-lombok-barat.kohort_bumil_v3.v_ga_usg_hpht_paired_distribution` AS SELECT ',
 projection, ' FROM (', r"""WITH long_format AS (

  -- ==========================================================================
  -- USG
  -- ==========================================================================

  SELECT

    outcome_event_id,

    pregnancy_episode_id,

    outcome_event_date,

    outcome_month,

    dashboard_puskesmas,

    dashboard_desa,

    dashboard_posyandu,


    -- ------------------------------------------------------------------------
    -- COMMON FILTER
    -- ------------------------------------------------------------------------
    usg_edd_method,

    usg_edd_method_order,


    -- ------------------------------------------------------------------------
    -- METHOD
    -- ------------------------------------------------------------------------
    'USG' AS dating_method,


    ga_usg_independent_days
      AS ga_at_birth_days,


    ga_usg_weeks
      AS ga_at_birth_weeks,


    ga_usg_completed_weeks
      AS ga_at_birth_completed_weeks,


    ga_usg_category
      AS ga_at_birth_category,


    ga_usg_clinical_usable_flag
      AS ga_clinical_usable_flag,


    1 AS ga_distribution_count

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.v_ga_usg_hpht_paired`


  UNION ALL


  -- ==========================================================================
  -- HPHT
  -- ==========================================================================

  SELECT

    outcome_event_id,

    pregnancy_episode_id,

    outcome_event_date,

    outcome_month,

    dashboard_puskesmas,

    dashboard_desa,

    dashboard_posyandu,


    -- ------------------------------------------------------------------------
    -- SAME USG METHOD FILTER
    --
    -- This is intentional.
    --
    -- Example:
    -- when selecting "USG <=14 minggu", both USG and HPHT estimates for
    -- pregnancies whose USG was <=14 weeks remain in the chart.
    -- ------------------------------------------------------------------------
    usg_edd_method,

    usg_edd_method_order,


    'HPHT' AS dating_method,


    ga_hpht_independent_days
      AS ga_at_birth_days,


    ga_hpht_weeks
      AS ga_at_birth_weeks,


    ga_hpht_completed_weeks
      AS ga_at_birth_completed_weeks,


    ga_hpht_category
      AS ga_at_birth_category,


    ga_hpht_clinical_usable_flag
      AS ga_clinical_usable_flag,


    1 AS ga_distribution_count

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.v_ga_usg_hpht_paired`
),


distribution AS (

  SELECT
    *,


    -- ------------------------------------------------------------------------
    -- OVERALL METHOD N
    -- ------------------------------------------------------------------------
    COUNT(*) OVER (
      PARTITION BY dating_method
    ) AS method_n,


    -- ------------------------------------------------------------------------
    -- COUNT PER WEEK
    -- ------------------------------------------------------------------------
    COUNT(*) OVER (

      PARTITION BY
        dating_method,
        ga_at_birth_completed_weeks

    ) AS method_week_count,


    -- ------------------------------------------------------------------------
    -- OVERALL % DISTRIBUTION
    -- ------------------------------------------------------------------------
    100.0
      *
    SAFE_DIVIDE(

      COUNT(*) OVER (

        PARTITION BY
          dating_method,
          ga_at_birth_completed_weeks

      ),

      COUNT(*) OVER (
        PARTITION BY dating_method
      )

    ) AS method_week_pct,


    -- ========================================================================
    -- USG-METHOD-SPECIFIC DISTRIBUTION
    --
    -- These are useful if exactly one usg_edd_method is selected.
    -- ========================================================================

    COUNT(*) OVER (

      PARTITION BY
        usg_edd_method,
        dating_method

    ) AS method_n_within_usg_method,


    COUNT(*) OVER (

      PARTITION BY
        usg_edd_method,
        dating_method,
        ga_at_birth_completed_weeks

    ) AS method_week_count_within_usg_method,


    100.0
      *
    SAFE_DIVIDE(

      COUNT(*) OVER (

        PARTITION BY
          usg_edd_method,
          dating_method,
          ga_at_birth_completed_weeks

      ),

      COUNT(*) OVER (

        PARTITION BY
          usg_edd_method,
          dating_method

      )

    ) AS method_week_pct_within_usg_method

  FROM long_format
)


SELECT *
FROM distribution""", ') q');
EXECUTE IMMEDIATE deployed_sql;

CREATE OR REPLACE TABLE `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_deployed_view_definitions` AS
 SELECT table_name,view_definition FROM `spheres-lombok-barat.kohort_bumil_v3.INFORMATION_SCHEMA.VIEWS`
 WHERE table_name IN ('v_birth_source_delay_category_long', 'v_birth_source_export_observations', 'v_birth_source_performance_daily_long', 'v_birth_weight_observations', 'v_birth_weight_source_audit', 'v_delivery_event_master_validated', 'v_delivery_source_first_report_native', 'v_delivery_timing_analysis_v1', 'v_pregnancy_dating_accuracy_v3_3', 'v_pregnancy_delivery_source_overlap_v3_3', 'v_pregnancy_outcome_tracking_dashboard_v3_3', 'v_pregnancy_outcome_trend_monthly_v3_3', 'v_pregnancy_source_crosswalk_v3_3', 'v_simrs_birth_weight_normalized', 'v_birth_source_performance_wide', 'v_delivery_monitoring_integrated', 'v_pregnancy_monitoring_integrated', 'v_birth_capture_step_wedge_daily', 'v_birth_outcome_event_dashboard', 'v_birth_outcome_period_comparison', 'v_birth_reporting_timeliness', 'v_pregnancy_delivery_source_long', 'v_pregnancy_monitoring_by_source_scope', 'v_birth_capture_step_wedge_wide', 'v_birth_reporting_timeliness_dashboard', 'v_birth_reporting_timeliness_evidence', 'v_edd_usg_hpht_paired', 'v_ga_usg_hpht_paired', 'v_edd_usg_hpht_paired_distribution', 'v_ga_usg_hpht_paired_distribution');
