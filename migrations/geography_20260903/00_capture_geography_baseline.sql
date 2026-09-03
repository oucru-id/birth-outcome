-- ONCE for this geography migration, before PREP 03 or the repair.
-- Pause conflicting source/core scheduled runs first. Location: asia-southeast2.
-- These CTAS backups preserve rows, not all physical metadata or access policies.
CREATE SCHEMA IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation`
OPTIONS(location='asia-southeast2');
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_sigizi_source_records` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_source_records`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_sigizi_pregnancy_episode_v3_3` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_v3_3`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_epus_pregnancy_episode_adapter_v3_3` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_adapter_v3_3`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_sigizi_episode_canonical_map_v3_3` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_episode_canonical_map_v3_3`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_sigizi_pregnancy_episode_canonical_v3_3` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_canonical_v3_3`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_epus_episode_canonical_map_v3_3` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_episode_canonical_map_v3_3`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_epus_pregnancy_episode_canonical_v3_3` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_pregnancy_episode_spine_v3_3` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_pregnancy_final_canonical_map_v3_3` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_final_canonical_map_v3_3`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_pregnancy_usg_dating_v3_3` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_usg_dating_v3_3`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_pregnancy_outcome_events_v3_3` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_events_v3_3`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_pregnancy_outcome_tracking_v3_3` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_tracking_v3_3`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_delivery_source_records` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_delivery_source_records`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_delivery_dedup_base` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_delivery_dedup_base`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_delivery_event_member_map` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_member_map`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_delivery_event_master_unlinked` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_unlinked`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_delivery_sigizi_direct_rescue_v3` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_delivery_sigizi_direct_rescue_v3`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_delivery_event_member_map_v3` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_member_map_v3`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_delivery_event_master_v3` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_v3`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_t_delivery_source_first_report_native` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_delivery_source_first_report_native`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_v_pregnancy_monitoring_integrated` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_monitoring_integrated`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_v_delivery_monitoring_integrated` AS SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.v_delivery_monitoring_integrated`;
CREATE TABLE IF NOT EXISTS `spheres-lombok-barat.kohort_bumil_v3_validation.geo_20260903_columns` AS
SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.INFORMATION_SCHEMA.COLUMNS`;
