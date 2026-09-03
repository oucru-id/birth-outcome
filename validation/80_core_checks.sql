-- READ ONLY. Run after the v3 build, against a consistent source refresh.
-- Counts and schemas are necessary checks, not full row/metric parity proof.
SELECT 'baseline_pregnancy' AS population, COUNT(*) AS row_count,
  COUNT(DISTINCT pregnancy_episode_id) AS distinct_ids,
  COUNTIF(pregnancy_episode_id IS NULL) AS missing_ids
FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_v_pregnancy_monitoring_integrated`
UNION ALL
SELECT 'rebuilt_pregnancy', COUNT(*), COUNT(DISTINCT pregnancy_episode_id),
  COUNTIF(pregnancy_episode_id IS NULL)
FROM `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_monitoring_integrated`
UNION ALL
SELECT 'baseline_delivery', COUNT(*), COUNT(DISTINCT delivery_event_id),
  COUNTIF(delivery_event_id IS NULL)
FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_t_delivery_event_master_v3`
UNION ALL
SELECT 'rebuilt_delivery', COUNT(*), COUNT(DISTINCT delivery_event_id),
  COUNTIF(delivery_event_id IS NULL)
FROM `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_v3`;

-- Expected: no rows. Otherwise investigate before counting pregnancies.
SELECT pregnancy_episode_id, COUNT(*) AS accepted_delivery_rows
FROM `spheres-lombok-barat.kohort_bumil_v3.v_delivery_event_master_validated`
WHERE valid_known_birth_flag AND successful_anc_link_flag
GROUP BY pregnancy_episode_id
HAVING COUNT(*) > 1 OR pregnancy_episode_id IS NULL;

SELECT 'baseline' AS version,
  COUNTIF(integrated_delivery_found_flag) AS linked_delivered_pregnancies,
  COUNTIF(integrated_pregnancy_outcome = 'ABORTUS') AS abortus_pregnancies,
  COUNTIF(integrated_monitoring_status_all_history = 'MISSING_BIRTH') AS missing_births,
  COUNTIF(monitoring_eligible_flag) AS operational_pregnancies,
  COUNTIF(has_phone) AS pregnancies_with_phone
FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_v_pregnancy_monitoring_integrated`
UNION ALL
SELECT 'rebuilt', COUNTIF(integrated_delivery_found_flag),
  COUNTIF(integrated_pregnancy_outcome = 'ABORTUS'),
  COUNTIF(integrated_monitoring_status_all_history = 'MISSING_BIRTH'),
  COUNTIF(monitoring_eligible_flag), COUNTIF(has_phone)
FROM `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_monitoring_integrated`;
