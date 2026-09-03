-- Run after the full downstream core rebuild, not immediately after 03.
-- Read-only aggregate diagnostics: both checks must PASS.
-- Source IDs in the episode member array lack source_table. Limit that check
-- to excluded IDs absent from ALL current active SIGIZI sources, avoiding
-- false positives if independent source tables reuse an ID.
CREATE TEMP TABLE deletion_downstream_issues AS
WITH excluded_only_ids AS (
  SELECT DISTINCT source_record_id
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_deletion_exclusion_audit`
  WHERE source_record_id IS NOT NULL
  EXCEPT DISTINCT
  SELECT source_record_id
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_source_records`
), excluded_only_keys AS (
  SELECT source_table, source_record_id
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_deletion_exclusion_audit`
  WHERE source_table IS NOT NULL AND source_record_id IS NOT NULL
  EXCEPT DISTINCT
  SELECT source_table, source_record_id
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_source_records`
)
SELECT 'EXCLUDED_SOURCE_STILL_IN_SIGIZI_EPISODES' AS check_name,
  COUNT(*) AS exception_count
FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_v3_3` AS p,
UNNEST(p.sigizi_member_source_record_ids) AS member_id
JOIN excluded_only_ids AS x ON member_id = x.source_record_id
UNION ALL
SELECT 'EXCLUDED_SOURCE_STILL_IN_OUTCOME_EVIDENCE', COUNT(*)
FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_events_v3_3` AS e
JOIN excluded_only_keys AS x
  ON e.source_event_id = CONCAT('SIGIZI|', x.source_table, '|', x.source_record_id)
WHERE e.source_system = 'SIGIZI';

SELECT check_name, exception_count,
  IF(exception_count = 0, 'PASS', 'FAIL') AS validation_status
FROM deletion_downstream_issues ORDER BY check_name;

ASSERT NOT EXISTS (
  SELECT 1 FROM deletion_downstream_issues WHERE exception_count != 0
) AS 'Stale or reintroduced deleted SIGIZI evidence remains downstream';
