-- ============================================================================
-- PURBALINGGA
-- 03C v4.1.1 CONSERVATIVE FINAL CANONICALIZATION PATCH
--
-- STARTS FROM:
--   t_pregnancy_final_pair_features_v3_3
--   t_pregnancy_episode_spine_precanonical_v3_3
--   t_pregnancy_final_guard_base_v3_3
--
-- DOES NOT RERUN:
--   SIGIZI source build
--   EPUS source build
--   preliminary pregnancy episodes
--   within-source canonicalization
--   SIGIZI <-> EPUS matching
--
-- MAIN CHANGE:
--
-- Do NOT auto-merge when BOTH are true:
--   1. trusted NIK conflict
--   2. DOB conflict
--
-- specifically for:
--   FINAL_STRONG_PREGNANCY_FINGERPRINT_OVERRIDE
--   FINAL_HIGH_CONFLICT_UNIQUE_FINGERPRINT
--
-- RATIONALE:
--   exact/similar pregnancy dating is not sufficient by itself to override
--   disagreement in BOTH strong maternal identifiers.
-- ============================================================================



-- ============================================================================
-- PARAMETERS
-- ============================================================================

DECLARE delivery_tolerance_days INT64 DEFAULT 3;
DECLARE strong_hpht_tolerance_days INT64 DEFAULT 14;
DECLARE strong_hpl_tolerance_days INT64 DEFAULT 14;
DECLARE hpl_tolerance_days INT64 DEFAULT 7;
DECLARE final_guard_anchor_tolerance_days INT64 DEFAULT 30;



-- ============================================================================
-- FUNCTIONS
-- ============================================================================

CREATE TEMP FUNCTION nik_is_trusted(s STRING)
RETURNS BOOL
AS (
  s IS NOT NULL
  AND REGEXP_CONTAINS(s, r'^\d{16}$')
  AND s NOT IN (
    '0000000000000000',
    '9999999999999999'
  )
  AND RIGHT(s, 4) != '0000'
);



-- ============================================================================
-- CLEAN ONLY THE DOWNSTREAM PATCH TABLES
-- ============================================================================

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_candidates_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_anchors_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_ranked_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_chosen_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step0_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step1_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step2_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step3_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step4_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3`;



-- ############################################################################
-- STAGE E4
-- RECLASSIFY FINAL RESIDUAL PAIRS
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_candidates_v3_3`

CLUSTER BY
  member_pregnancy_episode_id,
  canonical_pregnancy_episode_id

AS

WITH classified AS (

  SELECT
    f.*,

    CASE

      -- ======================================================================
      -- 1. EXACT TRUSTED NIK + CLOSE PREGNANCY ANCHOR
      -- ======================================================================

      WHEN
        nik_is_trusted(nik_1)
        AND nik_is_trusted(nik_2)
        AND nik_1 = nik_2

        AND anchor_difference_days IS NOT NULL

        AND anchor_difference_days
              <= final_guard_anchor_tolerance_days

      THEN 'FINAL_NIK+ANCHOR_30D'


      -- ======================================================================
      -- 2. STRONG NAME + DOB + HPHT + CORROBORATOR
      --
      -- Different NIK is still allowed here if DOB is the same.
      -- This is intentional.
      -- ======================================================================

      WHEN
        compact_name_exact_flag

        AND dob_1 IS NOT NULL
        AND dob_2 IS NOT NULL
        AND dob_1 = dob_2

        AND hpht_difference_days IS NOT NULL

        AND hpht_difference_days
              <= strong_hpht_tolerance_days

        AND corroborator_count >= 1

      THEN 'FINAL_STRONG_NAME+DOB+HPHT_14D+CORROBORATOR'


      -- ======================================================================
      -- 3. CONTROLLED FUZZY NAME
      -- ======================================================================

      WHEN
        name_edit_distance IS NOT NULL

        AND (
             (
               LEAST(
                 LENGTH(COALESCE(name_1, '')),
                 LENGTH(COALESCE(name_2, ''))
               ) < 8

               AND name_edit_distance <= 1
             )

          OR (
               LEAST(
                 LENGTH(COALESCE(name_1, '')),
                 LENGTH(COALESCE(name_2, ''))
               ) >= 8

               AND name_edit_distance <= 2
             )
        )

        AND dob_1 IS NOT NULL
        AND dob_2 IS NOT NULL
        AND dob_1 = dob_2

        AND hpht_difference_days IS NOT NULL

        AND hpht_difference_days
              <= strong_hpht_tolerance_days

        AND corroborator_count >= 2

        AND NOT trusted_nik_conflict_flag

      THEN 'FINAL_FUZZY_NAME+DOB+HPHT_14D+2_CORROBORATORS'


      -- ======================================================================
      -- 4. PHONE + DOB + PREGNANCY DATING
      -- ======================================================================

      WHEN
        phone_1 IS NOT NULL

        AND phone_2 IS NOT NULL

        AND LENGTH(phone_1) >= 8

        AND LENGTH(phone_2) >= 8

        AND phone_1 = phone_2

        AND dob_1 IS NOT NULL

        AND dob_2 IS NOT NULL

        AND dob_1 = dob_2

        AND (

             (
               hpht_difference_days IS NOT NULL

               AND hpht_difference_days
                     <= strong_hpht_tolerance_days
             )

          OR (
               hpl_difference_days IS NOT NULL

               AND hpl_difference_days
                     <= strong_hpl_tolerance_days
             )

        )

      THEN 'FINAL_PHONE+DOB+HPHT_HPL'


      -- ======================================================================
      -- 5. DOB MISSING ON ONE SIDE
      --
      -- Requires exact pregnancy dating and >=2 location corroborators.
      -- Trusted NIK conflict is NOT allowed here.
      -- ======================================================================

      WHEN
        compact_name_exact_flag

        AND dob_missing_one_side_flag

        AND NOT dob_conflict_flag

        AND hpht_difference_days = 0

        AND hpl_difference_days = 0

        AND (

              CAST(
                puskesmas_1 IS NOT NULL
                AND puskesmas_1 = puskesmas_2
                AS INT64
              )

            + CAST(
                desa_1 IS NOT NULL
                AND desa_1 = desa_2
                AS INT64
              )

            + CAST(
                posyandu_1 IS NOT NULL
                AND posyandu_1 = posyandu_2
                AS INT64
              )

        ) >= 2

        AND NOT trusted_nik_conflict_flag

      THEN 'FINAL_NAME+DOB_MISSING+EXACT_PREGNANCY+2_LOCATION'


      -- ======================================================================
      -- 6. STRONG PREGNANCY FINGERPRINT OVERRIDE
      --
      -- v4.1.1 CHANGE:
      --
      -- Do NOT allow this rule when BOTH trusted NIK and DOB disagree.
      --
      -- NIK conflict alone may still be a typo.
      -- DOB conflict alone may still be a source error.
      -- BOTH together => keep separate.
      -- ======================================================================

      WHEN
        compact_name_exact_flag

        AND hpht_difference_days = 0

        AND hpl_difference_days = 0

        AND corroborator_count >= 2

        AND NOT (
          COALESCE(
            trusted_nik_conflict_flag,
            FALSE
          )

          AND COALESCE(
            dob_conflict_flag,
            FALSE
          )
        )

      THEN 'FINAL_STRONG_PREGNANCY_FINGERPRINT_OVERRIDE'


      -- ======================================================================
      -- 7. UNIQUE HIGH-CONFLICT FINGERPRINT
      --
      -- v4.1.1 CHANGE:
      --
      -- Also cannot override simultaneous trusted NIK + DOB disagreement.
      -- ======================================================================

      WHEN
        fingerprint_1 IS NOT NULL

        AND fingerprint_2 IS NOT NULL

        AND fingerprint_1 = fingerprint_2

        AND fingerprint_count_1 = 2

        AND fingerprint_count_2 = 2

        AND NOT (
          COALESCE(
            trusted_nik_conflict_flag,
            FALSE
          )

          AND COALESCE(
            dob_conflict_flag,
            FALSE
          )
        )

      THEN 'FINAL_HIGH_CONFLICT_UNIQUE_FINGERPRINT'


      -- ======================================================================
      -- 10. EXACT NAME + DOB + CLOSE HPL
      -- ======================================================================

      WHEN
        compact_name_exact_flag

        AND dob_1 IS NOT NULL

        AND dob_2 IS NOT NULL

        AND dob_1 = dob_2

        AND hpl_difference_days IS NOT NULL

        AND hpl_difference_days
              <= hpl_tolerance_days

        AND NOT trusted_nik_conflict_flag

      THEN 'FINAL_NAME+DOB+HPL_7D'


      ELSE NULL

    END AS final_merge_method


  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_pair_features_v3_3` f

),


prioritized AS (

  SELECT

    *,

    CASE final_merge_method

      WHEN 'FINAL_NIK+ANCHOR_30D'
        THEN 1

      WHEN 'FINAL_STRONG_NAME+DOB+HPHT_14D+CORROBORATOR'
        THEN 2

      WHEN 'FINAL_FUZZY_NAME+DOB+HPHT_14D+2_CORROBORATORS'
        THEN 3

      WHEN 'FINAL_PHONE+DOB+HPHT_HPL'
        THEN 4

      WHEN 'FINAL_NAME+DOB_MISSING+EXACT_PREGNANCY+2_LOCATION'
        THEN 5

      WHEN 'FINAL_STRONG_PREGNANCY_FINGERPRINT_OVERRIDE'
        THEN 6

      WHEN 'FINAL_HIGH_CONFLICT_UNIQUE_FINGERPRINT'
        THEN 7

      WHEN 'FINAL_NAME+DOB+HPL_7D'
        THEN 10

    END AS final_merge_priority


  FROM classified

  WHERE
    final_merge_method IS NOT NULL

)


SELECT

  -- ========================================================================
  -- LOWER-QUALITY EPISODE BECOMES MEMBER
  -- ========================================================================

  CASE

    WHEN quality_1 < quality_2
      THEN pregnancy_episode_id_1

    WHEN quality_1 > quality_2
      THEN pregnancy_episode_id_2

    WHEN pregnancy_episode_id_1
           > pregnancy_episode_id_2
      THEN pregnancy_episode_id_1

    ELSE pregnancy_episode_id_2

  END AS member_pregnancy_episode_id,


  -- ========================================================================
  -- HIGHER-QUALITY EPISODE BECOMES CANONICAL TARGET
  -- ========================================================================

  CASE

    WHEN quality_1 < quality_2
      THEN pregnancy_episode_id_2

    WHEN quality_1 > quality_2
      THEN pregnancy_episode_id_1

    WHEN pregnancy_episode_id_1
           > pregnancy_episode_id_2
      THEN pregnancy_episode_id_2

    ELSE pregnancy_episode_id_1

  END AS canonical_pregnancy_episode_id,


  final_merge_method,

  final_merge_priority,


  CASE

    WHEN final_merge_priority IN (1, 2, 4)
      THEN 'VERY_HIGH'

    WHEN final_merge_priority IN (3, 5)
      THEN 'HIGH'

    WHEN final_merge_priority IN (6, 7)
      THEN 'HIGH_CONFLICT'

    ELSE 'HIGH'

  END AS final_merge_confidence,


  anchor_difference_days,


  COALESCE(
    hpht_difference_days,
    hpl_difference_days,
    anchor_difference_days
  ) AS match_date_difference_days,


  trusted_nik_conflict_flag,

  dob_conflict_flag


FROM prioritized;



-- ############################################################################
-- STAGE E5
-- TERMINAL FINAL ANCHORS
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_anchors_v3_3`

CLUSTER BY pregnancy_episode_id

AS

SELECT
  b.*

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_base_v3_3` b

WHERE NOT EXISTS (

  SELECT 1

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_candidates_v3_3` c

  WHERE
    c.member_pregnancy_episode_id
      = b.pregnancy_episode_id

);



-- ############################################################################
-- STAGE E6
-- RANK CANDIDATES POINTING TO TERMINAL ANCHORS
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_ranked_v3_3`

CLUSTER BY
  member_pregnancy_episode_id,
  canonical_pregnancy_episode_id

AS

SELECT

  c.*,

  a.final_quality_score
    AS canonical_quality_score,


  DENSE_RANK() OVER (

    PARTITION BY
      c.member_pregnancy_episode_id

    ORDER BY

      c.final_merge_priority,

      COALESCE(
        c.match_date_difference_days,
        999999
      ),

      COALESCE(
        c.anchor_difference_days,
        999999
      ),

      a.final_quality_score DESC

  ) AS candidate_rank


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_candidates_v3_3` c

JOIN
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_anchors_v3_3` a

  ON a.pregnancy_episode_id
       = c.canonical_pregnancy_episode_id;



-- ############################################################################
-- STAGE E7
-- ACCEPT ONLY A UNIQUE BEST TARGET
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_chosen_v3_3`

CLUSTER BY
  member_pregnancy_episode_id,
  canonical_pregnancy_episode_id

AS

SELECT

  member_pregnancy_episode_id,


  ANY_VALUE(
    canonical_pregnancy_episode_id
  ) AS canonical_pregnancy_episode_id,


  ANY_VALUE(
    final_merge_method
  ) AS final_merge_method,


  ANY_VALUE(
    final_merge_priority
  ) AS final_merge_priority,


  ANY_VALUE(
    final_merge_confidence
  ) AS final_merge_confidence,


  ANY_VALUE(
    anchor_difference_days
  ) AS anchor_difference_days,


  ANY_VALUE(
    match_date_difference_days
  ) AS match_date_difference_days,


  LOGICAL_OR(
    trusted_nik_conflict_flag
  ) AS trusted_nik_conflict_flag,


  LOGICAL_OR(
    dob_conflict_flag
  ) AS dob_conflict_flag


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_ranked_v3_3`

WHERE
  candidate_rank = 1

GROUP BY
  member_pregnancy_episode_id

HAVING
  COUNT(*) = 1;



-- ############################################################################
-- STAGE E8
-- INITIAL MEMBER -> CANONICAL MAP
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step0_v3_3`

AS

SELECT

  p.pregnancy_episode_id
    AS member_pregnancy_episode_id,


  COALESCE(
    c.canonical_pregnancy_episode_id,
    p.pregnancy_episode_id
  ) AS canonical_pregnancy_episode_id,


  c.final_merge_method,

  c.final_merge_priority,

  c.final_merge_confidence,

  c.trusted_nik_conflict_flag,

  c.dob_conflict_flag


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_precanonical_v3_3` p

LEFT JOIN
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_chosen_v3_3` c

  ON c.member_pregnancy_episode_id
       = p.pregnancy_episode_id;



-- ############################################################################
-- STAGE E9
-- FOLLOW CANONICAL CHAINS
-- ############################################################################


-- ============================================================================
-- STEP 1
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step1_v3_3`

AS

SELECT

  m.* EXCEPT(
    canonical_pregnancy_episode_id
  ),


  COALESCE(
    n.canonical_pregnancy_episode_id,
    m.canonical_pregnancy_episode_id
  ) AS canonical_pregnancy_episode_id


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step0_v3_3` m

LEFT JOIN
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_chosen_v3_3` n

  ON n.member_pregnancy_episode_id
       = m.canonical_pregnancy_episode_id;



-- ============================================================================
-- STEP 2
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step2_v3_3`

AS

SELECT

  m.* EXCEPT(
    canonical_pregnancy_episode_id
  ),


  COALESCE(
    n.canonical_pregnancy_episode_id,
    m.canonical_pregnancy_episode_id
  ) AS canonical_pregnancy_episode_id


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step1_v3_3` m

LEFT JOIN
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_chosen_v3_3` n

  ON n.member_pregnancy_episode_id
       = m.canonical_pregnancy_episode_id;



-- ============================================================================
-- STEP 3
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step3_v3_3`

AS

SELECT

  m.* EXCEPT(
    canonical_pregnancy_episode_id
  ),


  COALESCE(
    n.canonical_pregnancy_episode_id,
    m.canonical_pregnancy_episode_id
  ) AS canonical_pregnancy_episode_id


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step2_v3_3` m

LEFT JOIN
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_chosen_v3_3` n

  ON n.member_pregnancy_episode_id
       = m.canonical_pregnancy_episode_id;



-- ============================================================================
-- STEP 4
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step4_v3_3`

AS

SELECT

  m.* EXCEPT(
    canonical_pregnancy_episode_id
  ),


  COALESCE(
    n.canonical_pregnancy_episode_id,
    m.canonical_pregnancy_episode_id
  ) AS canonical_pregnancy_episode_id


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step3_v3_3` m

LEFT JOIN
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_chosen_v3_3` n

  ON n.member_pregnancy_episode_id
       = m.canonical_pregnancy_episode_id;



-- ============================================================================
-- FINAL CANONICAL MAP
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_v3_3`

CLUSTER BY
  member_pregnancy_episode_id,
  canonical_pregnancy_episode_id

AS

SELECT

  m.* EXCEPT(
    canonical_pregnancy_episode_id
  ),


  COALESCE(
    n.canonical_pregnancy_episode_id,
    m.canonical_pregnancy_episode_id
  ) AS canonical_pregnancy_episode_id


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step4_v3_3` m

LEFT JOIN
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_chosen_v3_3` n

  ON n.member_pregnancy_episode_id
       = m.canonical_pregnancy_episode_id;



-- ############################################################################
-- STAGE F
-- REBUILD FINAL PREGNANCY SPINE
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3`

CLUSTER BY
  nik_clean,
  puskesmas_norm,
  pregnancy_episode_id

AS

WITH members AS (

  SELECT

    m.canonical_pregnancy_episode_id,

    m.member_pregnancy_episode_id,

    m.final_merge_method,

    m.final_merge_priority,

    m.final_merge_confidence,


    m.trusted_nik_conflict_flag
      AS final_link_trusted_nik_conflict_flag,


    m.dob_conflict_flag
      AS final_link_dob_conflict_flag,


    g.final_quality_score,


    p.*


  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_v3_3` m


  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_precanonical_v3_3` p

    ON p.pregnancy_episode_id
       = m.member_pregnancy_episode_id


  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_base_v3_3` g

    ON g.pregnancy_episode_id
       = m.member_pregnancy_episode_id

),


-- ============================================================================
-- GROUP-LEVEL STATS
-- ============================================================================

group_stats AS (

  SELECT

    canonical_pregnancy_episode_id,


    COUNT(*)
      AS canonical_episode_member_count,


    LOGICAL_OR(
      has_pregnancy_sigizi
    ) AS group_has_pregnancy_sigizi,


    LOGICAL_OR(
      has_pregnancy_epus
    ) AS group_has_pregnancy_epus,


    MIN(first_anc_date)
      AS group_first_anc_date,


    MAX(last_anc_date)
      AS group_last_anc_date,


    COUNT(
      DISTINCT nik_clean
    ) AS nik_value_count,


    COUNT(
      DISTINCT IF(
        nik_is_trusted(nik_clean),
        nik_clean,
        NULL
      )
    ) AS trusted_nik_value_count,


    COUNT(
      DISTINCT tanggal_lahir_ibu
    ) AS dob_value_count,


    COUNT(
      DISTINCT nama_core_norm
    ) AS name_variant_count,


    LOGICAL_OR(
      COALESCE(
        final_link_trusted_nik_conflict_flag,
        FALSE
      )
    ) AS final_link_trusted_nik_conflict_flag,


    LOGICAL_OR(
      COALESCE(
        final_link_dob_conflict_flag,
        FALSE
      )
    ) AS final_link_dob_conflict_flag,


    LOGICAL_OR(
      final_merge_method
        = 'FINAL_STRONG_PREGNANCY_FINGERPRINT_OVERRIDE'
    ) AS final_strong_pregnancy_fingerprint_override_applied,


    LOGICAL_OR(
      final_merge_method
        = 'FINAL_HIGH_CONFLICT_UNIQUE_FINGERPRINT'
    ) AS final_high_conflict_unique_fingerprint_applied


  FROM members

  GROUP BY
    canonical_pregnancy_episode_id

),


-- ============================================================================
-- PICK BEST SCALAR VALUES
-- ============================================================================

scalar_picks AS (

  SELECT

    canonical_pregnancy_episode_id,


    ARRAY_AGG(
      STRUCT(
        nik_clean AS value,
        final_quality_score AS quality
      )
      ORDER BY
        nik_is_trusted(nik_clean) DESC,
        nik_clean IS NULL,
        final_quality_score DESC,
        member_pregnancy_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS nik_pick,


    ARRAY_AGG(
      STRUCT(
        nama_ibu AS value,
        nama_norm AS value_norm,
        nama_core_norm AS value_core,
        final_quality_score AS quality
      )
      ORDER BY
        nama_core_norm IS NULL,
        final_quality_score DESC,
        member_pregnancy_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS name_pick,


    ARRAY_AGG(
      STRUCT(
        tanggal_lahir_ibu AS value,
        final_quality_score AS quality
      )
      ORDER BY
        tanggal_lahir_ibu IS NULL,
        final_quality_score DESC,
        member_pregnancy_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS dob_pick,


    ARRAY_AGG(
      STRUCT(
        no_hp_clean AS value,
        phone_source AS source,
        final_quality_score AS quality
      )
      ORDER BY
        no_hp_clean IS NULL,
        LENGTH(COALESCE(no_hp_clean, '')) DESC,
        final_quality_score DESC,
        member_pregnancy_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS phone_pick,


    ARRAY_AGG(
      STRUCT(
        puskesmas AS puskesmas,
        puskesmas_norm AS puskesmas_norm,
        desa AS desa,
        desa_norm AS desa_norm,
        posyandu AS posyandu,
        alamat AS alamat,
        final_quality_score AS quality
      )
      ORDER BY
        puskesmas_norm IS NULL,
        desa_norm IS NULL,
        posyandu IS NULL,
        final_quality_score DESC,
        member_pregnancy_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS location_pick,


    ARRAY_AGG(
      STRUCT(
        hpht_sigizi AS value,
        final_quality_score AS quality
      )
      ORDER BY
        hpht_sigizi IS NULL,
        final_quality_score DESC,
        member_pregnancy_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS hpht_sigizi_pick,


    ARRAY_AGG(
      STRUCT(
        hpht_epus AS value,
        final_quality_score AS quality
      )
      ORDER BY
        hpht_epus IS NULL,
        final_quality_score DESC,
        member_pregnancy_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS hpht_epus_pick,


    ARRAY_AGG(
      STRUCT(
        hpl_sigizi AS value,
        final_quality_score AS quality
      )
      ORDER BY
        hpl_sigizi IS NULL,
        final_quality_score DESC,
        member_pregnancy_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS hpl_sigizi_pick,


    ARRAY_AGG(
      STRUCT(
        hpl_epus AS value,
        final_quality_score AS quality
      )
      ORDER BY
        hpl_epus IS NULL,
        final_quality_score DESC,
        member_pregnancy_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS hpl_epus_pick,


    ARRAY_AGG(
      STRUCT(
        delivery_sigizi AS value,
        final_quality_score AS quality
      )
      ORDER BY
        delivery_sigizi IS NULL,
        final_quality_score DESC,
        member_pregnancy_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS delivery_sigizi_pick,


    ARRAY_AGG(
      STRUCT(
        delivery_epus AS value,
        final_quality_score AS quality
      )
      ORDER BY
        delivery_epus IS NULL,
        final_quality_score DESC,
        member_pregnancy_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS delivery_epus_pick,


    ARRAY_AGG(
      STRUCT(
        hpl_from_sigizi_hpht AS value,
        final_quality_score AS quality
      )
      ORDER BY
        hpl_from_sigizi_hpht IS NULL,
        final_quality_score DESC,
        member_pregnancy_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS hpl_from_sigizi_pick,


    ARRAY_AGG(
      STRUCT(
        hpl_from_epus_hpht AS value,
        final_quality_score AS quality
      )
      ORDER BY
        hpl_from_epus_hpht IS NULL,
        final_quality_score DESC,
        member_pregnancy_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS hpl_from_epus_pick,


    ARRAY_AGG(
      STRUCT(
        cross_source_match_method AS method,
        cross_source_match_priority AS priority,
        cross_source_match_confidence AS confidence,
        cross_source_assignment_round AS assignment_round
      )
      ORDER BY
        cross_source_match_priority IS NULL,
        cross_source_match_priority,
        member_pregnancy_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS cross_match_pick


  FROM members

  GROUP BY
    canonical_pregnancy_episode_id

),


-- ============================================================================
-- CANONICAL MEMBER IDS
-- ============================================================================

member_ids AS (

  SELECT

    canonical_pregnancy_episode_id,

    ARRAY_AGG(
      member_pregnancy_episode_id
      ORDER BY member_pregnancy_episode_id
    ) AS canonical_episode_member_ids

  FROM members

  GROUP BY
    canonical_pregnancy_episode_id

),


-- ============================================================================
-- MERGE METHODS
-- ============================================================================

merge_methods AS (

  SELECT

    canonical_pregnancy_episode_id,

    ARRAY_AGG(
      DISTINCT COALESCE(
        final_merge_method,
        'SELF'
      )
      ORDER BY COALESCE(
        final_merge_method,
        'SELF'
      )
    ) AS canonical_episode_merge_methods

  FROM members

  GROUP BY
    canonical_pregnancy_episode_id

),


-- ============================================================================
-- SIGIZI MEMBER IDS
-- ============================================================================

sigizi_ids AS (

  SELECT

    canonical_pregnancy_episode_id,

    ARRAY_AGG(
      DISTINCT x
      ORDER BY x
    ) AS canonical_sigizi_episode_ids

  FROM members,

  UNNEST(
    COALESCE(
      sigizi_episode_ids,
      ARRAY<STRING>[]
    )
  ) AS x

  GROUP BY
    canonical_pregnancy_episode_id

),


-- ============================================================================
-- EPUS MEMBER IDS
-- ============================================================================

epus_ids AS (

  SELECT

    canonical_pregnancy_episode_id,

    ARRAY_AGG(
      DISTINCT x
      ORDER BY x
    ) AS canonical_epus_episode_ids

  FROM members,

  UNNEST(
    COALESCE(
      epus_episode_ids,
      ARRAY<STRING>[]
    )
  ) AS x

  GROUP BY
    canonical_pregnancy_episode_id

),


-- ============================================================================
-- EPUS SOURCE KEYS
-- ============================================================================

epus_keys AS (

  SELECT

    canonical_pregnancy_episode_id,

    ARRAY_AGG(
      DISTINCT x
      ORDER BY x
    ) AS epus_episode_source_keys

  FROM members,

  UNNEST(
    COALESCE(
      epus_episode_source_keys,
      ARRAY<STRING>[]
    )
  ) AS x

  GROUP BY
    canonical_pregnancy_episode_id

),


-- ============================================================================
-- AUDIT VALUE ARRAYS
-- ============================================================================

value_arrays AS (

  SELECT

    canonical_pregnancy_episode_id,


    ARRAY_AGG(
      DISTINCT nik_clean
      IGNORE NULLS
      ORDER BY nik_clean
    ) AS final_nik_values,


    ARRAY_AGG(
      DISTINCT tanggal_lahir_ibu
      IGNORE NULLS
      ORDER BY tanggal_lahir_ibu
    ) AS final_dob_values,


    ARRAY_AGG(
      DISTINCT nama_ibu
      IGNORE NULLS
      ORDER BY nama_ibu
    ) AS final_name_values,


    ARRAY_AGG(
      DISTINCT puskesmas
      IGNORE NULLS
      ORDER BY puskesmas
    ) AS final_puskesmas_values


  FROM members

  GROUP BY
    canonical_pregnancy_episode_id

),


-- ============================================================================
-- CROSS-SOURCE CONFLICT
-- ============================================================================

cross_conflict AS (

  SELECT

    canonical_pregnancy_episode_id,


    LOGICAL_OR(
      COALESCE(
        cross_source_nik_conflict_flag,
        FALSE
      )
    ) AS cross_source_nik_conflict_flag


  FROM members

  GROUP BY
    canonical_pregnancy_episode_id

)


-- ============================================================================
-- FINAL OUTPUT
-- ============================================================================

SELECT

  g.canonical_pregnancy_episode_id
    AS pregnancy_episode_id,


  si.canonical_sigizi_episode_ids[SAFE_OFFSET(0)]
    AS sigizi_episode_id,


  ei.canonical_epus_episode_ids[SAFE_OFFSET(0)]
    AS epus_episode_id,


  ek.epus_episode_source_keys[SAFE_OFFSET(0)]
    AS epus_episode_source_key,


  CASE

    WHEN g.group_has_pregnancy_sigizi
     AND g.group_has_pregnancy_epus
      THEN 'SIGIZI + EPUS'

    WHEN g.group_has_pregnancy_sigizi
      THEN 'SIGIZI ONLY'

    WHEN g.group_has_pregnancy_epus
      THEN 'EPUS ONLY'

    ELSE 'UNKNOWN'

  END AS pregnancy_source_combination,


  g.group_has_pregnancy_sigizi
    AS has_pregnancy_sigizi,


  g.group_has_pregnancy_epus
    AS has_pregnancy_epus,


  sp.cross_match_pick.method
    AS cross_source_match_method,


  sp.cross_match_pick.priority
    AS cross_source_match_priority,


  sp.cross_match_pick.confidence
    AS cross_source_match_confidence,


  sp.cross_match_pick.assignment_round
    AS cross_source_assignment_round,


  sp.nik_pick.value
    AS nik_clean,


  sp.name_pick.value
    AS nama_ibu,


  sp.name_pick.value_norm
    AS nama_norm,


  sp.name_pick.value_core
    AS nama_core_norm,


  sp.dob_pick.value
    AS tanggal_lahir_ibu,


  sp.phone_pick.value
    AS no_hp_clean,


  sp.phone_pick.source
    AS phone_source,


  sp.location_pick.puskesmas,

  sp.location_pick.puskesmas_norm,

  sp.location_pick.desa,

  sp.location_pick.desa_norm,

  sp.location_pick.posyandu,

  sp.location_pick.alamat,


  sp.hpht_sigizi_pick.value
    AS hpht_sigizi,


  sp.hpht_epus_pick.value
    AS hpht_epus,


  sp.hpl_sigizi_pick.value
    AS hpl_sigizi,


  sp.hpl_epus_pick.value
    AS hpl_epus,


  sp.delivery_sigizi_pick.value
    AS delivery_sigizi,


  sp.delivery_epus_pick.value
    AS delivery_epus,


  sp.hpl_from_sigizi_pick.value
    AS hpl_from_sigizi_hpht,


  sp.hpl_from_epus_pick.value
    AS hpl_from_epus_hpht,


  COALESCE(
    sp.hpht_epus_pick.value,
    sp.hpht_sigizi_pick.value
  ) AS hpht_date,


  CASE

    WHEN sp.hpht_epus_pick.value IS NOT NULL
      THEN 'EPUS'

    WHEN sp.hpht_sigizi_pick.value IS NOT NULL
      THEN 'SIGIZI'

  END AS hpht_source,


  COALESCE(
    sp.hpl_epus_pick.value,
    sp.hpl_sigizi_pick.value
  ) AS hpl_recorded_date,


  CASE

    WHEN sp.hpl_epus_pick.value IS NOT NULL
      THEN 'EPUS'

    WHEN sp.hpl_sigizi_pick.value IS NOT NULL
      THEN 'SIGIZI'

  END AS hpl_recorded_source,


  COALESCE(
    sp.hpl_from_epus_pick.value,
    sp.hpl_from_sigizi_pick.value
  ) AS hpl_from_hpht_date,


  g.group_first_anc_date
    AS first_anc_date,


  g.group_last_anc_date
    AS last_anc_date,


  COALESCE(

    sp.hpht_epus_pick.value,

    sp.hpht_sigizi_pick.value,

    DATE_SUB(
      COALESCE(
        sp.hpl_epus_pick.value,
        sp.hpl_sigizi_pick.value
      ),
      INTERVAL 280 DAY
    )

  ) AS pregnancy_anchor_date,


  COALESCE(
    sp.hpht_sigizi_pick.value,
    DATE_SUB(
      sp.hpl_sigizi_pick.value,
      INTERVAL 280 DAY
    )
  ) AS sigizi_anchor_date,


  COALESCE(
    sp.hpht_epus_pick.value,
    DATE_SUB(
      sp.hpl_epus_pick.value,
      INTERVAL 280 DAY
    )
  ) AS epus_anchor_date,


  LENGTH(
    COALESCE(
      sp.phone_pick.value,
      ''
    )
  ) >= 8 AS has_phone_pregnancy_source,


  CASE

    WHEN sp.hpl_epus_pick.value IS NOT NULL
     AND sp.hpl_sigizi_pick.value IS NOT NULL

    THEN DATE_DIFF(
      sp.hpl_epus_pick.value,
      sp.hpl_sigizi_pick.value,
      DAY
    )

  END AS epus_minus_sigizi_hpl_days,


  CASE

    WHEN sp.hpht_epus_pick.value IS NOT NULL
     AND sp.hpht_sigizi_pick.value IS NOT NULL

    THEN DATE_DIFF(
      sp.hpht_epus_pick.value,
      sp.hpht_sigizi_pick.value,
      DAY
    )

  END AS epus_minus_sigizi_hpht_days,


  g.canonical_episode_member_count,


  COALESCE(
    mi.canonical_episode_member_ids,
    ARRAY<STRING>[]
  ) AS canonical_episode_member_ids,


  COALESCE(
    mm.canonical_episode_merge_methods,
    ARRAY<STRING>[]
  ) AS canonical_episode_merge_methods,


  COALESCE(
    si.canonical_sigizi_episode_ids,
    ARRAY<STRING>[]
  ) AS canonical_sigizi_episode_ids,


  COALESCE(
    ei.canonical_epus_episode_ids,
    ARRAY<STRING>[]
  ) AS canonical_epus_episode_ids,


  COALESCE(
    ek.epus_episode_source_keys,
    ARRAY<STRING>[]
  ) AS epus_episode_source_keys,


  COALESCE(
    va.final_nik_values,
    ARRAY<STRING>[]
  ) AS final_nik_values,


  COALESCE(
    va.final_dob_values,
    ARRAY<DATE>[]
  ) AS final_dob_values,


  COALESCE(
    va.final_name_values,
    ARRAY<STRING>[]
  ) AS final_name_values,


  COALESCE(
    va.final_puskesmas_values,
    ARRAY<STRING>[]
  ) AS final_puskesmas_values,


  g.nik_value_count > 1
    AS final_nik_conflict_flag,


  g.trusted_nik_value_count > 1
    AS final_trusted_nik_conflict_flag,


  g.dob_value_count > 1
    AS final_dob_conflict_flag,


  g.name_variant_count > 1
    AS final_name_variant_flag,


  (
       g.nik_value_count > 1

    OR g.dob_value_count > 1

    OR g.name_variant_count > 1

  ) AS final_identity_conflict_flag,


  g.final_strong_pregnancy_fingerprint_override_applied,


  g.final_high_conflict_unique_fingerprint_applied,


  g.canonical_episode_member_count > 1
    AS final_canonicalization_applied,


  (
       g.nik_value_count > 1

    OR g.dob_value_count > 1

    OR g.name_variant_count > 1

    OR g.final_strong_pregnancy_fingerprint_override_applied

    OR g.final_high_conflict_unique_fingerprint_applied

  ) AS final_match_qa_required,


  COALESCE(
    cc.cross_source_nik_conflict_flag,
    FALSE
  ) AS cross_source_nik_conflict_flag


FROM group_stats g

JOIN scalar_picks sp
  USING (canonical_pregnancy_episode_id)

LEFT JOIN member_ids mi
  USING (canonical_pregnancy_episode_id)

LEFT JOIN merge_methods mm
  USING (canonical_pregnancy_episode_id)

LEFT JOIN sigizi_ids si
  USING (canonical_pregnancy_episode_id)

LEFT JOIN epus_ids ei
  USING (canonical_pregnancy_episode_id)

LEFT JOIN epus_keys ek
  USING (canonical_pregnancy_episode_id)

LEFT JOIN value_arrays va
  USING (canonical_pregnancy_episode_id)

LEFT JOIN cross_conflict cc
  USING (canonical_pregnancy_episode_id);
