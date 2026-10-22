-- StandardSQL
-- ============================================================================
-- READ-ONLY STAGING QA FOR MATERNAL PREGNANCY CANONICALIZATION (V3.3)
-- Baseline: kohort_bumil_v3_validation.pregnancy_spine_baseline_20261022
-- Candidate: kohort_bumil_v3_staging.t_pregnancy_episode_spine_v3_3
--
-- THIS FILE:
-- * reads baseline, staging, and current production canonical maps
-- * uses temporary query-session tables for comparisons only
-- * DOES NOT MODIFY PRODUCTION OR STAGING PERSISTENT TABLES
-- * never publishes staging to production, irrespective of QA result
--
-- Result set 1: pregnancy ID, membership and desa stability
-- Result set 2: within-source canonical map stability
-- Result set 3: examples of changed episodes (up to 100, no names/NIK)
-- ============================================================================

CREATE TEMP TABLE staging_spine_compare AS
WITH baseline AS (
  SELECT
    pregnancy_episode_id,
    desa,
    desa_norm,
    TO_JSON_STRING(STRUCT(
      sigizi_episode_id,
      epus_episode_id,
      pregnancy_source_combination,
      ARRAY(
        SELECT x
        FROM UNNEST(
          COALESCE(canonical_sigizi_episode_ids, ARRAY<STRING>[])
        ) x
        ORDER BY x
      ) AS sigizi_members,
      ARRAY(
        SELECT x
        FROM UNNEST(
          COALESCE(canonical_epus_episode_ids, ARRAY<STRING>[])
        ) x
        ORDER BY x
      ) AS epus_members,
      ARRAY(
        SELECT x
        FROM UNNEST(
          COALESCE(epus_episode_source_keys, ARRAY<STRING>[])
        ) x
        ORDER BY x
      ) AS epus_source_keys
    )) AS membership_signature
  FROM
    `spheres-lombok-barat.kohort_bumil_v3_validation.pregnancy_spine_baseline_20261022`
),
staging AS (
  SELECT
    pregnancy_episode_id,
    desa,
    desa_norm,
    TO_JSON_STRING(STRUCT(
      sigizi_episode_id,
      epus_episode_id,
      pregnancy_source_combination,
      ARRAY(
        SELECT x
        FROM UNNEST(
          COALESCE(canonical_sigizi_episode_ids, ARRAY<STRING>[])
        ) x
        ORDER BY x
      ) AS sigizi_members,
      ARRAY(
        SELECT x
        FROM UNNEST(
          COALESCE(canonical_epus_episode_ids, ARRAY<STRING>[])
        ) x
        ORDER BY x
      ) AS epus_members,
      ARRAY(
        SELECT x
        FROM UNNEST(
          COALESCE(epus_episode_source_keys, ARRAY<STRING>[])
        ) x
        ORDER BY x
      ) AS epus_source_keys
    )) AS membership_signature
  FROM
    `spheres-lombok-barat.kohort_bumil_v3_staging.t_pregnancy_episode_spine_v3_3`
)
SELECT
  b.pregnancy_episode_id AS baseline_id,
  s.pregnancy_episode_id AS staging_id,
  b.membership_signature AS baseline_membership,
  s.membership_signature AS staging_membership,
  b.desa AS baseline_desa,
  s.desa AS staging_desa,
  b.desa_norm AS baseline_desa_norm,
  s.desa_norm AS staging_desa_norm,
  CASE
    WHEN b.pregnancy_episode_id IS NULL THEN 'NEW_STAGING_EPISODE'
    WHEN s.pregnancy_episode_id IS NULL THEN 'MISSING_BASELINE_EPISODE'
    WHEN b.membership_signature IS DISTINCT FROM s.membership_signature
      THEN 'CHANGED_MEMBERSHIP'
    WHEN b.desa_norm IS NOT NULL
      AND (
        b.desa_norm IS DISTINCT FROM s.desa_norm
        OR b.desa IS DISTINCT FROM s.desa
      )
      THEN 'CHANGED_EXISTING_DESA'
    WHEN b.desa_norm IS NULL AND s.desa_norm IS NOT NULL
      THEN 'ADDITIONAL_DESA'
    ELSE 'UNCHANGED'
  END AS comparison_category
FROM baseline b
FULL OUTER JOIN staging s
  ON b.pregnancy_episode_id = s.pregnancy_episode_id;

-- Result 1: 2026-10-22 baseline target = 37,139 episodes,
-- with 31,704 having desa. Staging may legitimately contain NEW episodes,
-- but never auto-publish until new episodes are explicitly reviewed.
WITH counts AS (
  SELECT
    (SELECT COUNT(*)
     FROM `spheres-lombok-barat.kohort_bumil_v3_validation.pregnancy_spine_baseline_20261022`)
      AS baseline_rows,
    (SELECT COUNT(*)
     FROM `spheres-lombok-barat.kohort_bumil_v3_staging.t_pregnancy_episode_spine_v3_3`)
      AS staging_rows,
    (SELECT COUNT(DISTINCT pregnancy_episode_id)
     FROM `spheres-lombok-barat.kohort_bumil_v3_staging.t_pregnancy_episode_spine_v3_3`)
      AS staging_unique_ids,
    (SELECT COUNTIF(pregnancy_episode_id IS NULL)
     FROM `spheres-lombok-barat.kohort_bumil_v3_staging.t_pregnancy_episode_spine_v3_3`)
      AS staging_null_ids,
    (SELECT COUNTIF(desa IS NOT NULL AND desa_norm IS NOT NULL)
     FROM `spheres-lombok-barat.kohort_bumil_v3_staging.t_pregnancy_episode_spine_v3_3`)
      AS staging_complete_desa,
    COUNTIF(comparison_category = 'MISSING_BASELINE_EPISODE')
      AS missing_baseline_ids,
    COUNTIF(comparison_category = 'NEW_STAGING_EPISODE')
      AS new_episode_ids,
    COUNTIF(comparison_category = 'CHANGED_MEMBERSHIP')
      AS membership_changed,
    COUNTIF(comparison_category = 'CHANGED_EXISTING_DESA')
      AS existing_desa_changed,
    COUNTIF(comparison_category = 'ADDITIONAL_DESA')
      AS existing_episode_new_desa,
    COUNTIF(comparison_category = 'UNCHANGED')
      AS unchanged_episodes,
    COUNTIF(
      baseline_id IS NOT NULL AND staging_id IS NOT NULL
      AND baseline_desa_norm IS NOT NULL AND staging_desa_norm IS NULL
    ) AS desa_lost
  FROM staging_spine_compare
)
SELECT
  *,
  CASE
    WHEN staging_null_ids > 0 OR staging_rows != staging_unique_ids
      OR missing_baseline_ids > 0 OR membership_changed > 0
      OR existing_desa_changed > 0 OR desa_lost > 0
    THEN 'HOLD_ID_MEMBERSHIP_OR_DESA_DRIFT'
    WHEN new_episode_ids > 0 OR existing_episode_new_desa > 0
    THEN 'REVIEW_NEW_EPISODES_OR_DESA'
    ELSE 'PASS_NO_DRIFT'
  END AS staging_qa_status,
  'QA NEVER PUBLISHES OR REPLACES PRODUCTION TABLES' AS publish_policy
FROM counts;

-- Result 2: Compare within-source canonical member assignments
-- between CURRENT production maps and new staging maps.
WITH baseline_map AS (
  SELECT 'SIGIZI' AS source_system,
    member_sigizi_episode_id AS member_id,
    canonical_sigizi_episode_id AS canonical_id
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_episode_canonical_map_v3_3`
  UNION ALL
  SELECT 'EPUS',
    member_epus_episode_id,
    canonical_epus_episode_id
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_episode_canonical_map_v3_3`
),
staging_map AS (
  SELECT 'SIGIZI' AS source_system,
    member_sigizi_episode_id AS member_id,
    canonical_sigizi_episode_id AS canonical_id
  FROM `spheres-lombok-barat.kohort_bumil_v3_staging.t_sigizi_episode_canonical_map_v3_3`
  UNION ALL
  SELECT 'EPUS',
    member_epus_episode_id,
    canonical_epus_episode_id
  FROM `spheres-lombok-barat.kohort_bumil_v3_staging.t_epus_episode_canonical_map_v3_3`
)
SELECT
  COALESCE(b.source_system, s.source_system) AS source_system,
  COUNTIF(b.member_id IS NOT NULL) AS production_members,
  COUNTIF(s.member_id IS NOT NULL) AS staging_members,
  COUNTIF(b.member_id IS NOT NULL AND s.member_id IS NULL)
    AS missing_production_members,
  COUNTIF(b.member_id IS NULL AND s.member_id IS NOT NULL)
    AS new_staging_members,
  COUNTIF(
    b.member_id IS NOT NULL AND s.member_id IS NOT NULL
    AND b.canonical_id IS DISTINCT FROM s.canonical_id
  ) AS canonical_assignment_changed,
  COUNTIF(
    b.member_id IS NOT NULL AND s.member_id IS NOT NULL
    AND b.canonical_id IS NOT DISTINCT FROM s.canonical_id
  ) AS assignment_unchanged
FROM baseline_map b
FULL OUTER JOIN staging_map s
  ON b.source_system = s.source_system AND b.member_id = s.member_id
GROUP BY source_system
ORDER BY source_system;

-- Result 3: Up to 100 affected pregnancy episode IDs, for human review.
SELECT
  comparison_category,
  COALESCE(baseline_id, staging_id) AS pregnancy_episode_id,
  baseline_desa_norm,
  staging_desa_norm,
  baseline_membership IS DISTINCT FROM staging_membership AS membership_changed
FROM staging_spine_compare
WHERE comparison_category != 'UNCHANGED'
ORDER BY
  CASE comparison_category
    WHEN 'MISSING_BASELINE_EPISODE' THEN 1
    WHEN 'CHANGED_MEMBERSHIP' THEN 2
    WHEN 'CHANGED_EXISTING_DESA' THEN 3
    WHEN 'NEW_STAGING_EPISODE' THEN 4
    ELSE 5
  END,
  pregnancy_episode_id
LIMIT 100;
