-- ============================================================================
-- BACK UP CURRENT REPORTING VIEW DEFINITIONS
-- Run whenever you want to archive the exact deployed definitions.
-- These views do NOT require daily scheduling.
-- ============================================================================

SELECT
  table_name AS view_name,
  view_definition
FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.INFORMATION_SCHEMA.VIEWS`
WHERE table_name IN (
  'v_pregnancy_monitoring_integrated',
  'v_pregnancy_monitoring_kpi',
  'v_delivery_monitoring_integrated',
  'v_delivery_gestational_age',
  'v_delivery_birth_weight',
  'v_birth_reporting_source_long',
  'v_birth_reporting_daily_trend'
)
ORDER BY view_name;
