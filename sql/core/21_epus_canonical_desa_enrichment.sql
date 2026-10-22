-- StandardSQL
-- ============================================================
-- SAFE EPUS CANONICAL PREGNANCY VILLAGE ENRICHMENT
--
-- Input:
--   kohort_bumil_v3.t_epus_episode_canonical_map_v3_3
--   kohort_bumil_v3.t_epus_pregnancy_episode_adapter_v3_3
-- Target:
--   kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3
--
-- Purpose:
--   Fill currently NULL desa/desa_norm only when all canonical
--   episode member evidence consistently supports ONE village.
--
-- This script DOES NOT:
--   - regenerate canonical source matching or maps
--   - change epus_episode_id, source membership or any other field
--   - populate conflicting or multiple-village episodes
--
-- IMPORTANT:
--   Run AFTER the adapter and canonical tables already exist.
--   Do NOT rerun sql/core/20_pregnancy_canonicalization.sql
--   merely for village enrichment; that is a full rematching
--   pipeline which can change pregnancy_episode_id.
-- ============================================================

CREATE TEMP TABLE epus_canonical_desa_candidates AS
WITH member_evidence AS (
  SELECT
    m.canonical_epus_episode_id AS epus_episode_id,
    a.epus_episode_id AS adapter_episode_id,
    a.desa,
    a.desa_norm,
    a.desa_match_status
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_episode_canonical_map_v3_3` m
  LEFT JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_adapter_v3_3` a
    ON m.member_epus_episode_id = a.epus_episode_id
),
member_summary AS (
  SELECT
    epus_episode_id,
    COUNT(*) AS member_count,
    COUNTIF(adapter_episode_id IS NULL) AS missing_adapter_members,
    COUNT(DISTINCT desa_norm) AS distinct_member_desa,
    COUNTIF(desa_match_status = 'MULTIPLE_DESA_REVIEW')
      AS conflict_member_count,
    MAX(desa) AS candidate_desa,
    MAX(desa_norm) AS candidate_desa_norm
  FROM member_evidence
  GROUP BY epus_episode_id
)
SELECT
  *,
  IF(
    missing_adapter_members = 0
    AND distinct_member_desa = 1
    AND conflict_member_count = 0,
    candidate_desa,
    NULL
  ) AS resolved_desa,
  IF(
    missing_adapter_members = 0
    AND distinct_member_desa = 1
    AND conflict_member_count = 0,
    candidate_desa_norm,
    NULL
  ) AS resolved_desa_norm
FROM member_summary;

-- Refuse a destructive/incomplete update if membership is not 1:1.
ASSERT (
  SELECT COUNT(*) = COUNT(DISTINCT epus_episode_id)
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3`
) AS 'STOP: duplicate epus_episode_id in existing canonical table';

ASSERT (
  SELECT COUNTIF(missing_adapter_members > 0) = 0
  FROM epus_canonical_desa_candidates
) AS 'STOP: canonical map references missing adapter members';

ASSERT (
  SELECT
    (SELECT COUNT(*) FROM epus_canonical_desa_candidates)
    =
    (SELECT COUNT(*) FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3`)
) AS 'STOP: canonical map and canonical table contain different episode counts';

ASSERT (
  SELECT COUNT(*) = 0
  FROM epus_canonical_desa_candidates e
  LEFT JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` c
    USING (epus_episode_id)
  WHERE c.epus_episode_id IS NULL
) AS 'STOP: canonical map has episode IDs missing in canonical table';

-- Existing populated locations must never be silently overwritten.
ASSERT (
  SELECT COUNT(*) = 0
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` c
  JOIN epus_canonical_desa_candidates e USING (epus_episode_id)
  WHERE e.resolved_desa_norm IS NOT NULL
    AND c.desa_norm IS NOT NULL
    AND c.desa_norm != e.resolved_desa_norm
) AS 'STOP: an existing canonical desa_norm disagrees with new evidence';

-- Idempotent enrichment: fill only previously empty village fields.
UPDATE
  `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` AS c
SET
  desa = e.resolved_desa,
  desa_norm = e.resolved_desa_norm
FROM epus_canonical_desa_candidates AS e
WHERE c.epus_episode_id = e.epus_episode_id
  AND c.desa IS NULL
  AND c.desa_norm IS NULL
  AND e.resolved_desa IS NOT NULL
  AND e.resolved_desa_norm IS NOT NULL;

-- Post-update QA. Expected snapshot (2026-10-22):
-- 18,286 canonical episodes; 14,489 safe villages;
-- 933 conflict episodes; 2 multiple-village; 2,862 no village.
SELECT
  COUNT(*) AS canonical_episodes,
  SUM(e.member_count) AS mapped_adapter_members,
  COUNTIF(c.desa IS NOT NULL AND c.desa_norm IS NOT NULL)
    AS canonical_episodes_with_desa,
  COUNTIF(e.resolved_desa_norm IS NOT NULL)
    AS safe_desa_candidates,
  COUNTIF(e.conflict_member_count > 0)
    AS member_desa_review,
  COUNTIF(
    e.conflict_member_count = 0
    AND e.distinct_member_desa > 1
  ) AS multiple_member_desa,
  COUNTIF(
    e.conflict_member_count = 0
    AND e.distinct_member_desa = 0
  ) AS no_member_desa,
  COUNTIF(
    e.resolved_desa_norm IS NOT NULL
    AND (
      c.desa IS DISTINCT FROM e.resolved_desa
      OR c.desa_norm IS DISTINCT FROM e.resolved_desa_norm
    )
  ) AS desa_mismatch,
  COUNTIF(
    (e.conflict_member_count > 0 OR e.distinct_member_desa > 1)
    AND (c.desa IS NOT NULL OR c.desa_norm IS NOT NULL)
  ) AS conflict_episodes_with_desa,
  CASE
    WHEN COUNT(*) = COUNT(DISTINCT c.epus_episode_id)
     AND COUNTIF(e.resolved_desa_norm IS NOT NULL AND (
          c.desa IS DISTINCT FROM e.resolved_desa
       OR c.desa_norm IS DISTINCT FROM e.resolved_desa_norm
     )) = 0
     AND COUNTIF(
       (e.conflict_member_count > 0 OR e.distinct_member_desa > 1)
       AND (c.desa IS NOT NULL OR c.desa_norm IS NOT NULL)
     ) = 0
    THEN 'PASS'
    ELSE 'FAIL'
  END AS qa_status
FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` c
JOIN epus_canonical_desa_candidates e USING (epus_episode_id);
