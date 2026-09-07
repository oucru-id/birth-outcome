-- ============================================================================
-- PURBALINGGA DAILY QA GATE
-- Run AFTER PBG-10.
-- ============================================================================

-- 1. Pregnancy uniqueness
SELECT
  'pregnancy_uniqueness' AS qa_check,
  COUNT(*) AS rows,
  COUNT(DISTINCT pregnancy_episode_id) AS distinct_ids,
  COUNT(*) = COUNT(DISTINCT pregnancy_episode_id) AS passed
FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3`;

-- 2. Final delivery uniqueness
SELECT
  'delivery_uniqueness' AS qa_check,
  COUNT(*) AS rows,
  COUNT(DISTINCT delivery_event_id) AS distinct_ids,
  COUNT(*) = COUNT(DISTINCT delivery_event_id) AS passed
FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_post_anc_v3_3`;

-- 3. No pregnancy may have >1 accepted final delivery
SELECT
  pregnancy_episode_id,
  COUNT(*) AS accepted_final_deliveries
FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_post_anc_v3_3`
WHERE pregnancy_episode_id IS NOT NULL
GROUP BY pregnancy_episode_id
HAVING COUNT(*) > 1
ORDER BY accepted_final_deliveries DESC;

-- 4. Operational due reconciliation
SELECT
  SUM(expected_to_have_delivered_count) AS expected_due,
  SUM(birth_found_due_count) AS birth_found_due,
  SUM(missing_birth_due_count) AS missing_birth_due,
  SUM(expected_to_have_delivered_count)
    = SUM(birth_found_due_count) + SUM(missing_birth_due_count)
    AS passed
FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.v_pregnancy_monitoring_kpi`;

-- 5. Delivery linkage reconciliation
SELECT
  SUM(canonical_delivery_count) AS final_deliveries,
  SUM(linked_delivery_count) AS linked,
  SUM(unlinked_delivery_count) AS unlinked,
  SUM(canonical_delivery_count)
    = SUM(linked_delivery_count) + SUM(unlinked_delivery_count)
    AS passed
FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.v_delivery_monitoring_integrated`;

-- 6. Reporting source-long uniqueness
SELECT
  COUNT(*) AS rows,
  COUNT(
    DISTINCT CONCAT(delivery_event_id, '|', source_system)
  ) AS distinct_delivery_source_pairs,
  COUNT(*) = COUNT(
    DISTINCT CONCAT(delivery_event_id, '|', source_system)
  ) AS passed
FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.v_birth_reporting_source_long`;

-- 7. Timeliness arithmetic
SELECT
  source_system,
  SUM(reported_h0_count) AS h0,
  SUM(reported_h1_exact_count) AS h1_exact,
  SUM(reported_by_h1_count) AS by_h1,
  SUM(reported_h0_count) + SUM(reported_h1_exact_count)
    = SUM(reported_by_h1_count) AS passed,
  SUM(negative_reporting_delay_count) AS negative_delay_rows
FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.v_birth_reporting_source_long`
GROUP BY source_system
ORDER BY source_system;
