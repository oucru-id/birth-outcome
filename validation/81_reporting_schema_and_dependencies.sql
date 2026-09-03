-- RESULT 1: exactly 30 PRESENT views expected.
SELECT e AS view_name,IF(v.table_name IS NULL,'MISSING','PRESENT') AS creation_status
FROM UNNEST(['v_birth_source_delay_category_long', 'v_birth_source_export_observations', 'v_birth_source_performance_daily_long', 'v_birth_weight_observations', 'v_birth_weight_source_audit', 'v_delivery_event_master_validated', 'v_delivery_source_first_report_native', 'v_delivery_timing_analysis_v1', 'v_pregnancy_dating_accuracy_v3_3', 'v_pregnancy_delivery_source_overlap_v3_3', 'v_pregnancy_outcome_tracking_dashboard_v3_3', 'v_pregnancy_outcome_trend_monthly_v3_3', 'v_pregnancy_source_crosswalk_v3_3', 'v_simrs_birth_weight_normalized', 'v_birth_source_performance_wide', 'v_delivery_monitoring_integrated', 'v_pregnancy_monitoring_integrated', 'v_birth_capture_step_wedge_daily', 'v_birth_outcome_event_dashboard', 'v_birth_outcome_period_comparison', 'v_birth_reporting_timeliness', 'v_pregnancy_delivery_source_long', 'v_pregnancy_monitoring_by_source_scope', 'v_birth_capture_step_wedge_wide', 'v_birth_reporting_timeliness_dashboard', 'v_birth_reporting_timeliness_evidence', 'v_edd_usg_hpht_paired', 'v_ga_usg_hpht_paired', 'v_edd_usg_hpht_paired_distribution', 'v_ga_usg_hpht_paired_distribution']) e LEFT JOIN `spheres-lombok-barat.kohort_bumil_v3.INFORMATION_SCHEMA.VIEWS` v ON v.table_name=e
ORDER BY view_name;
-- RESULT 2: zero differences expected across all 30 reporting schemas.
WITH a AS (SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns`),
b AS (SELECT table_name,column_name,ordinal_position,data_type,is_nullable
 FROM `spheres-lombok-barat.kohort_bumil_v3.INFORMATION_SCHEMA.COLUMNS` WHERE table_name IN ('v_birth_source_delay_category_long', 'v_birth_source_export_observations', 'v_birth_source_performance_daily_long', 'v_birth_weight_observations', 'v_birth_weight_source_audit', 'v_delivery_event_master_validated', 'v_delivery_source_first_report_native', 'v_delivery_timing_analysis_v1', 'v_pregnancy_dating_accuracy_v3_3', 'v_pregnancy_delivery_source_overlap_v3_3', 'v_pregnancy_outcome_tracking_dashboard_v3_3', 'v_pregnancy_outcome_trend_monthly_v3_3', 'v_pregnancy_source_crosswalk_v3_3', 'v_simrs_birth_weight_normalized', 'v_birth_source_performance_wide', 'v_delivery_monitoring_integrated', 'v_pregnancy_monitoring_integrated', 'v_birth_capture_step_wedge_daily', 'v_birth_outcome_event_dashboard', 'v_birth_outcome_period_comparison', 'v_birth_reporting_timeliness', 'v_pregnancy_delivery_source_long', 'v_pregnancy_monitoring_by_source_scope', 'v_birth_capture_step_wedge_wide', 'v_birth_reporting_timeliness_dashboard', 'v_birth_reporting_timeliness_evidence', 'v_edd_usg_hpht_paired', 'v_ga_usg_hpht_paired', 'v_edd_usg_hpht_paired_distribution', 'v_ga_usg_hpht_paired_distribution'))
SELECT COALESCE(a.table_name,b.table_name) AS view_name,
 COALESCE(a.column_name,b.column_name) AS column_name,
 a.data_type AS baseline_type,b.data_type AS rebuilt_type,
 a.ordinal_position AS baseline_position,b.ordinal_position AS rebuilt_position,
 a.is_nullable AS baseline_nullable,b.is_nullable AS rebuilt_nullable
FROM a FULL OUTER JOIN b USING(table_name,column_name)
WHERE a.data_type IS DISTINCT FROM b.data_type OR a.ordinal_position IS DISTINCT FROM b.ordinal_position
 OR a.is_nullable IS DISTINCT FROM b.is_nullable
ORDER BY view_name,column_name;
-- RESULT 3: zero v2 references expected across all v3 view definitions.
SELECT table_name FROM `spheres-lombok-barat.kohort_bumil_v3.INFORMATION_SCHEMA.VIEWS`
WHERE REGEXP_CONTAINS(view_definition, r'(?i)kohort_bumil_v2');
