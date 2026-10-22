-- SCHEDULE-SAFE V3.3 DESA-ONLY JOB | as of 2026-10-22
-- To use: replace the BODY of the unsafe canonicalization scheduled job with
-- THIS file, and rename that scheduled task to DESA_REFRESH_ONLY.
-- IMPORTANT: this DOES NOT build new pregnancy episodes. A separate,
-- guarded identity-pipeline scheduler is required for new pregnancies.
-- Schedule only AFTER ePus source/master/adapter refresh.
-- DO NOT RUN original 3289-line canonicalization script unattended.
-- Historical baseline references a permanently frozen 2026-10-22 table.
-- The script is idempotent; every UPDATE affects only desa and desa_norm.
-- ========================================================================

-- StandardSQL
-- EPUS LPP RESIDENTIAL-VILLAGE REFRESH, WITHOUT PREGNANCY REMATCHING
-- Input: refreshed t_epus_pregnancy_episode_adapter_v3_3,
--        t_epus_pregnancy_master, existing immutable episode mappings.
-- Mutates ONLY desa and desa_norm in:
--   1. t_epus_pregnancy_episode_canonical_v3_3
--   2. t_pregnancy_episode_spine_v3_3
--   3. t_pregnancy_outcome_tracking_v3_3
--
-- IMPORTANT: This is NOT a substitute for the canonicalization scheduler.
-- Do not run the full canonicalization scheduler unattended after new desa
-- is incorporated into matching scores/rules: it can change episode IDs.
-- This enrichment job cannot prevent an independent CREATE OR REPLACE TABLE
-- issued by that other scheduler. Control upstream schedule separately.


-- Historical baseline guard. New pregnancy IDs may appear, but none of the
-- 37,139 baseline IDs or their matching/source memberships may disappear/change.
-- This prevents silent propagation if the old rematching scheduler was rerun.
CREATE TEMP TABLE baseline_membership_guard AS
WITH baseline AS (
  SELECT
    pregnancy_episode_id,
    TO_JSON_STRING(STRUCT(
      sigizi_episode_id,
      epus_episode_id,
      pregnancy_source_combination,
      ARRAY(SELECT x FROM UNNEST(COALESCE(canonical_sigizi_episode_ids, ARRAY<STRING>[])) x ORDER BY x) AS sigizi_members,
      ARRAY(SELECT x FROM UNNEST(COALESCE(canonical_epus_episode_ids, ARRAY<STRING>[])) x ORDER BY x) AS epus_members,
      ARRAY(SELECT x FROM UNNEST(COALESCE(epus_episode_source_keys, ARRAY<STRING>[])) x ORDER BY x) AS epus_source_keys
    )) AS membership_signature
  FROM `spheres-lombok-barat.kohort_bumil_v3_validation.pregnancy_spine_baseline_20261022`
),
current_spine AS (
  SELECT
    pregnancy_episode_id,
    TO_JSON_STRING(STRUCT(
      sigizi_episode_id,
      epus_episode_id,
      pregnancy_source_combination,
      ARRAY(SELECT x FROM UNNEST(COALESCE(canonical_sigizi_episode_ids, ARRAY<STRING>[])) x ORDER BY x) AS sigizi_members,
      ARRAY(SELECT x FROM UNNEST(COALESCE(canonical_epus_episode_ids, ARRAY<STRING>[])) x ORDER BY x) AS epus_members,
      ARRAY(SELECT x FROM UNNEST(COALESCE(epus_episode_source_keys, ARRAY<STRING>[])) x ORDER BY x) AS epus_source_keys
    )) AS membership_signature
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3`
)
SELECT
  b.pregnancy_episode_id,
  c.pregnancy_episode_id IS NULL AS missing_baseline_id,
  b.membership_signature IS DISTINCT FROM c.membership_signature AS changed_membership
FROM baseline b
LEFT JOIN current_spine c
  USING (pregnancy_episode_id);

ASSERT (
  SELECT COUNT(*) = 37139
    AND COUNTIF(missing_baseline_id OR changed_membership) = 0
  FROM baseline_membership_guard
) AS 'STOP: baseline pregnancy ID or membership drift. Do not refresh villages until identity linkage is reviewed';

CREATE TEMP TABLE before_desa AS
SELECT 'EPUS_CANONICAL' AS stage, epus_episode_id AS episode_id, desa, desa_norm
FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3`
UNION ALL
SELECT 'SPINE', pregnancy_episode_id, desa, desa_norm
FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3`
UNION ALL
SELECT 'TRACKING', pregnancy_episode_id, desa, desa_norm
FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_tracking_v3_3`;

-- Preflight: one row per episode in each target table.
ASSERT (
  SELECT COUNT(*) = COUNT(DISTINCT CONCAT(stage, '|', episode_id))
  FROM before_desa
) AS 'STOP: duplicate or NULL episode ID in target tables';

ASSERT (
  SELECT COUNT(*) = COUNT(DISTINCT epus_pregnancy_key)
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_master`
) AS 'STOP: duplicate or NULL ePus master source keys';

ASSERT (
  SELECT COUNT(*) = COUNT(DISTINCT epus_episode_id)
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_adapter_v3_3`
) AS 'STOP: duplicate or NULL adapter episode IDs';

ASSERT (
  SELECT COUNT(*) = COUNT(DISTINCT member_epus_episode_id)
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_episode_canonical_map_v3_3`
) AS 'STOP: duplicate or NULL ePus canonical-map members';

ASSERT (
  SELECT COUNT(*) = 0
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` s
  FULL OUTER JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_tracking_v3_3` t
    USING (pregnancy_episode_id)
  WHERE s.pregnancy_episode_id IS NULL OR t.pregnancy_episode_id IS NULL
) AS 'STOP: pregnancy spine and outcome tracking have different episode IDs';

-- Resolve strictly within the pre-existing ePus canonical map.
CREATE TEMP TABLE epus_canonical_desa AS
WITH evidence AS (
  SELECT m.canonical_epus_episode_id AS epus_episode_id,
         a.epus_episode_id AS adapter_episode_id,
         a.desa, a.desa_norm, a.desa_match_status
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_episode_canonical_map_v3_3` m
  LEFT JOIN `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_adapter_v3_3` a
    ON m.member_epus_episode_id = a.epus_episode_id
)
SELECT
  epus_episode_id,
  COUNTIF(adapter_episode_id IS NULL) AS missing_adapter_members,
  COUNT(DISTINCT desa_norm) AS distinct_desa,
  COUNTIF(desa_match_status = 'MULTIPLE_DESA_REVIEW') AS conflict_members,
  MAX(desa) AS candidate_desa,
  MAX(desa_norm) AS candidate_desa_norm
FROM evidence
GROUP BY epus_episode_id;

ASSERT (
  SELECT COUNTIF(missing_adapter_members > 0) = 0
  FROM epus_canonical_desa
) AS 'STOP: unresolved canonical map members';

ASSERT (
  SELECT COUNT(*) = 0
  FROM epus_canonical_desa e
  FULL OUTER JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` c
    USING (epus_episode_id)
  WHERE e.epus_episode_id IS NULL OR c.epus_episode_id IS NULL
) AS 'STOP: ePus canonical map disagrees with current canonical episode IDs';

-- Resolve ePus LPP residential village across ALL source keys of a final spine episode.
CREATE TEMP TABLE spine_desa_evidence AS
WITH evidence AS (
  SELECT
    s.pregnancy_episode_id,
    e.epus_pregnancy_key,
    e.desa,
    e.desa_norm,
    e.desa_match_status
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` s
  CROSS JOIN UNNEST(COALESCE(s.epus_episode_source_keys, ARRAY<STRING>[])) AS source_key
  LEFT JOIN `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_master` e
    ON source_key = e.epus_pregnancy_key
)
SELECT
  pregnancy_episode_id,
  COUNTIF(epus_pregnancy_key IS NULL) AS missing_master_keys,
  COUNT(DISTINCT desa_norm) AS distinct_desa,
  COUNTIF(desa_match_status = 'MULTIPLE_DESA_REVIEW') AS conflict_members,
  MAX(desa) AS candidate_desa,
  MAX(desa_norm) AS candidate_desa_norm
FROM evidence
GROUP BY pregnancy_episode_id;

ASSERT (
  SELECT COUNTIF(missing_master_keys > 0) = 0
  FROM spine_desa_evidence
) AS 'STOP: some ePus source keys are not found in the master';

-- Existing non-empty villages have priority; disagreements from newly
-- refreshed ePus are intentionally skipped, not overwritten or fatal.
-- Post-transaction invariants still forbid changes to existing values.

-- All three updates are transactional and idempotent.
BEGIN TRANSACTION;

UPDATE `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` c
SET desa = e.candidate_desa,
    desa_norm = e.candidate_desa_norm
FROM epus_canonical_desa e
WHERE c.epus_episode_id = e.epus_episode_id
  AND c.desa IS NULL AND c.desa_norm IS NULL
  AND e.missing_adapter_members = 0
  AND e.distinct_desa = 1 AND e.conflict_members = 0
  AND e.candidate_desa IS NOT NULL AND e.candidate_desa_norm IS NOT NULL;

UPDATE `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` s
SET desa = e.candidate_desa,
    desa_norm = e.candidate_desa_norm
FROM spine_desa_evidence e
WHERE s.pregnancy_episode_id = e.pregnancy_episode_id
  AND s.desa IS NULL AND s.desa_norm IS NULL
  AND e.missing_master_keys = 0
  AND e.distinct_desa = 1 AND e.conflict_members = 0
  AND e.candidate_desa IS NOT NULL AND e.candidate_desa_norm IS NOT NULL;

UPDATE `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_tracking_v3_3` t
SET desa = s.desa,
    desa_norm = s.desa_norm
FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` s
WHERE t.pregnancy_episode_id = s.pregnancy_episode_id
  AND t.desa IS NULL AND t.desa_norm IS NULL
  AND s.desa IS NOT NULL AND s.desa_norm IS NOT NULL;

-- Invariant: all original populated villages are unchanged.
ASSERT (
  SELECT COUNT(*) = 0
  FROM before_desa b
  JOIN (
    SELECT 'EPUS_CANONICAL' AS stage, epus_episode_id AS episode_id, desa, desa_norm
    FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3`
    UNION ALL
    SELECT 'SPINE', pregnancy_episode_id, desa, desa_norm
    FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3`
    UNION ALL
    SELECT 'TRACKING', pregnancy_episode_id, desa, desa_norm
    FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_tracking_v3_3`
  ) a USING (stage, episode_id)
  WHERE (b.desa IS NOT NULL OR b.desa_norm IS NOT NULL)
    AND (b.desa IS DISTINCT FROM a.desa OR b.desa_norm IS DISTINCT FROM a.desa_norm)
) AS 'STOP: an existing populated desa has changed';

ASSERT (
  SELECT COUNT(*) = 0
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` s
  JOIN `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_tracking_v3_3` t
    USING (pregnancy_episode_id)
  WHERE s.desa IS DISTINCT FROM t.desa OR s.desa_norm IS DISTINCT FROM t.desa_norm
) AS 'STOP: outcome tracking village still disagrees with spine';

COMMIT TRANSACTION;

-- QA: counts of newly completed desa pairs (after enrichment).
WITH after_desa AS (
  SELECT 'EPUS_CANONICAL' AS stage, epus_episode_id AS episode_id, desa, desa_norm
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3`
  UNION ALL
  SELECT 'SPINE', pregnancy_episode_id, desa, desa_norm
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3`
  UNION ALL
  SELECT 'TRACKING', pregnancy_episode_id, desa, desa_norm
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_tracking_v3_3`
)
SELECT
  a.stage,
  COUNT(*) AS episode_rows,
  COUNTIF(a.desa IS NOT NULL AND a.desa_norm IS NOT NULL) AS complete_desa_after,
  COUNTIF(b.desa IS NULL AND b.desa_norm IS NULL
          AND a.desa IS NOT NULL AND a.desa_norm IS NOT NULL)
    AS newly_enriched,
  COUNTIF((b.desa IS NOT NULL OR b.desa_norm IS NOT NULL)
          AND (b.desa IS DISTINCT FROM a.desa
               OR b.desa_norm IS DISTINCT FROM a.desa_norm))
    AS existing_desas_changed,
  CASE WHEN COUNT(*) = COUNT(DISTINCT a.episode_id)
    AND COUNTIF((b.desa IS NOT NULL OR b.desa_norm IS NOT NULL)
      AND (b.desa IS DISTINCT FROM a.desa
        OR b.desa_norm IS DISTINCT FROM a.desa_norm)) = 0
    THEN 'PASS' ELSE 'FAIL' END AS qa_status
FROM after_desa a
JOIN before_desa b USING (stage, episode_id)
GROUP BY stage ORDER BY stage;
