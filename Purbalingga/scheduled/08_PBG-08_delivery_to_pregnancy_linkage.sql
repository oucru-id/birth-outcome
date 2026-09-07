-- ============================================================================
-- PURBALINGGA
-- 06_LINK_CANONICAL_DELIVERY_TO_PREGNANCY_V3_3
--
-- INPUTS
--   t_delivery_event_canonical_v3_3
--   t_pregnancy_episode_spine_v3_3
--
-- OUTPUTS
--   t_delivery_pregnancy_link_candidates_v3_3
--   t_delivery_pregnancy_link_v3_3
--
-- GRAIN OF FINAL OUTPUT
--   1 row = 1 canonical delivery event
--
-- IMPORTANT
--
-- This stage DOES NOT consolidate nearby delivery events yet.
--
-- It first asks:
--   "Which canonical pregnancy does this delivery most plausibly belong to?"
--
-- Only after this linkage is established will we consolidate multiple
-- delivery events attached to the same pregnancy.
-- ============================================================================


DECLARE minimum_plausible_ga_days INT64 DEFAULT 126;  -- 18 weeks
DECLARE maximum_plausible_ga_days INT64 DEFAULT 322;  -- 46 weeks

DECLARE pregnancy_dating_tolerance_days INT64 DEFAULT 14;
DECLARE close_expected_delivery_days INT64 DEFAULT 14;


-- ============================================================================
-- HELPERS
-- ============================================================================

CREATE TEMP FUNCTION norm_text(s STRING)
RETURNS STRING
AS (
  NULLIF(
    REGEXP_REPLACE(
      REGEXP_REPLACE(
        UPPER(TRIM(COALESCE(s, ''))),
        r'[^A-Z0-9 ]',
        ' '
      ),
      r'\s+',
      ' '
    ),
    ''
  )
);


CREATE TEMP FUNCTION compact_name(s STRING)
RETURNS STRING
AS (
  NULLIF(
    REGEXP_REPLACE(
      REGEXP_REPLACE(
        COALESCE(
          REGEXP_REPLACE(
            norm_text(s),
            r'\b(NY|NYONYA|IBU|MRS|TN|TNY)\b',
            ' '
          ),
          ''
        ),
        r'\s+',
        ''
      ),
      r'[^A-Z0-9]',
      ''
    ),
    ''
  )
);


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
-- DROP DOWNSTREAM LINKAGE TABLES ONLY
-- ============================================================================

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_pregnancy_link_candidates_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_pregnancy_link_v3_3`;


-- ############################################################################
-- BUILD CANDIDATE PAIRS
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_pregnancy_link_candidates_v3_3`

CLUSTER BY
  delivery_event_id,
  pregnancy_episode_id

AS

WITH pregnancies AS (

  SELECT

    pregnancy_episode_id,

    pregnancy_source_combination,

    nik_clean,

    nama_ibu,

    nama_norm,

    nama_core_norm,

    tanggal_lahir_ibu,

    no_hp_clean,

    puskesmas_norm,

    desa_norm,

    hpht_date,

    hpl_recorded_date,

    hpl_from_hpht_date,

    pregnancy_anchor_date,


    -- ------------------------------------------------------------------------
    -- LINKING EDD
    --
    -- This is for linkage ranking only.
    -- The full operational expected-delivery priority will still be built
    -- later in the monitoring layer.
    -- ------------------------------------------------------------------------

    COALESCE(
      hpl_epus,
      hpl_sigizi,
      hpl_recorded_date,
      hpl_from_epus_hpht,
      hpl_from_sigizi_hpht,
      hpl_from_hpht_date,
      DATE_ADD(
        hpht_date,
        INTERVAL 280 DAY
      )
    ) AS expected_delivery_date_link,


    COALESCE(
      pregnancy_anchor_date,
      hpht_date,

      DATE_SUB(
        COALESCE(
          hpl_epus,
          hpl_sigizi,
          hpl_recorded_date,
          hpl_from_epus_hpht,
          hpl_from_sigizi_hpht,
          hpl_from_hpht_date
        ),
        INTERVAL 280 DAY
      )
    ) AS pregnancy_anchor_date_link


  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3`
),


deliveries AS (

  SELECT
    *

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_v3_3`
),


-- ============================================================================
-- BLOCK 1
-- NIK
-- ============================================================================

nik_blocks AS (

  SELECT
    d.delivery_event_id,
    p.pregnancy_episode_id,
    'NIK_BLOCK' AS candidate_block

  FROM deliveries d

  JOIN pregnancies p

    ON d.nik_clean = p.nik_clean

  WHERE
    nik_is_trusted(d.nik_clean)
    AND nik_is_trusted(p.nik_clean)
),


-- ============================================================================
-- BLOCK 2
-- COMPACT NAME
-- ============================================================================

name_blocks AS (

  SELECT
    d.delivery_event_id,
    p.pregnancy_episode_id,
    'NAME_BLOCK' AS candidate_block

  FROM deliveries d

  JOIN pregnancies p

    ON compact_name(d.nama_ibu)
       = compact_name(p.nama_ibu)

  WHERE
    compact_name(d.nama_ibu) IS NOT NULL
    AND compact_name(p.nama_ibu) IS NOT NULL
),


-- ============================================================================
-- BLOCK 3
-- PHONE
-- ============================================================================

phone_blocks AS (

  SELECT
    d.delivery_event_id,
    p.pregnancy_episode_id,
    'PHONE_BLOCK' AS candidate_block

  FROM deliveries d

  JOIN pregnancies p

    ON d.no_hp_clean = p.no_hp_clean

  WHERE
    d.no_hp_clean IS NOT NULL
    AND p.no_hp_clean IS NOT NULL
    AND LENGTH(d.no_hp_clean) >= 8
),


candidate_blocks AS (

  SELECT * FROM nik_blocks

  UNION ALL

  SELECT * FROM name_blocks

  UNION ALL

  SELECT * FROM phone_blocks
),


distinct_pairs AS (

  SELECT
    delivery_event_id,
    pregnancy_episode_id,

    ARRAY_AGG(
      DISTINCT candidate_block
      ORDER BY candidate_block
    ) AS candidate_blocks

  FROM candidate_blocks

  GROUP BY
    delivery_event_id,
    pregnancy_episode_id
),


pair_features AS (

  SELECT

    x.delivery_event_id,

    x.pregnancy_episode_id,

    x.candidate_blocks,


    -- ------------------------------------------------------------------------
    -- DELIVERY
    -- ------------------------------------------------------------------------

    d.delivery_date,

    d.nik_clean
      AS delivery_nik,

    d.nama_ibu
      AS delivery_name,

    d.nama_norm
      AS delivery_name_norm,

    compact_name(d.nama_ibu)
      AS delivery_compact_name,

    d.tanggal_lahir_ibu
      AS delivery_dob,

    d.no_hp_clean
      AS delivery_phone,

    d.hpht_date
      AS delivery_hpht,

    d.hpl_date
      AS delivery_hpl,

    d.puskesmas_norm
      AS delivery_puskesmas,


    -- ------------------------------------------------------------------------
    -- PREGNANCY
    -- ------------------------------------------------------------------------

    p.pregnancy_source_combination,

    p.nik_clean
      AS pregnancy_nik,

    p.nama_ibu
      AS pregnancy_name,

    p.nama_norm
      AS pregnancy_name_norm,

    compact_name(p.nama_ibu)
      AS pregnancy_compact_name,

    p.tanggal_lahir_ibu
      AS pregnancy_dob,

    p.no_hp_clean
      AS pregnancy_phone,

    p.hpht_date
      AS pregnancy_hpht,

    p.hpl_recorded_date
      AS pregnancy_hpl,

    p.puskesmas_norm
      AS pregnancy_puskesmas,

    p.pregnancy_anchor_date_link,

    p.expected_delivery_date_link,


    -- ------------------------------------------------------------------------
    -- IDENTITY FEATURES
    -- ------------------------------------------------------------------------

    (
      nik_is_trusted(d.nik_clean)
      AND nik_is_trusted(p.nik_clean)
      AND d.nik_clean = p.nik_clean
    ) AS trusted_nik_exact,


    (
      nik_is_trusted(d.nik_clean)
      AND nik_is_trusted(p.nik_clean)
      AND d.nik_clean != p.nik_clean
    ) AS trusted_nik_conflict,


    (
      compact_name(d.nama_ibu) IS NOT NULL
      AND compact_name(p.nama_ibu) IS NOT NULL
      AND compact_name(d.nama_ibu)
          = compact_name(p.nama_ibu)
    ) AS compact_name_match,


    (
      compact_name(d.nama_ibu) IS NOT NULL
      AND compact_name(p.nama_ibu) IS NOT NULL
      AND compact_name(d.nama_ibu)
          != compact_name(p.nama_ibu)
    ) AS name_conflict,


    (
      d.tanggal_lahir_ibu IS NOT NULL
      AND p.tanggal_lahir_ibu IS NOT NULL
      AND d.tanggal_lahir_ibu
          = p.tanggal_lahir_ibu
    ) AS dob_match,


    (
      d.tanggal_lahir_ibu IS NOT NULL
      AND p.tanggal_lahir_ibu IS NOT NULL
      AND d.tanggal_lahir_ibu
          != p.tanggal_lahir_ibu
    ) AS dob_conflict,


    (
      d.no_hp_clean IS NOT NULL
      AND p.no_hp_clean IS NOT NULL
      AND d.no_hp_clean = p.no_hp_clean
    ) AS phone_match,


    (
      d.puskesmas_norm IS NOT NULL
      AND p.puskesmas_norm IS NOT NULL
      AND d.puskesmas_norm = p.puskesmas_norm
    ) AS puskesmas_match,


    -- ------------------------------------------------------------------------
    -- PREGNANCY DATING
    -- ------------------------------------------------------------------------

    CASE
      WHEN d.hpht_date IS NOT NULL
       AND p.hpht_date IS NOT NULL

      THEN ABS(
        DATE_DIFF(
          d.hpht_date,
          p.hpht_date,
          DAY
        )
      )
    END AS hpht_difference_days,


    CASE
      WHEN d.hpl_date IS NOT NULL
       AND p.hpl_recorded_date IS NOT NULL

      THEN ABS(
        DATE_DIFF(
          d.hpl_date,
          p.hpl_recorded_date,
          DAY
        )
      )
    END AS hpl_difference_days,


    CASE
      WHEN p.expected_delivery_date_link IS NOT NULL

      THEN ABS(
        DATE_DIFF(
          d.delivery_date,
          p.expected_delivery_date_link,
          DAY
        )
      )
    END AS expected_delivery_difference_days,


    CASE
      WHEN p.pregnancy_anchor_date_link IS NOT NULL

      THEN DATE_DIFF(
        d.delivery_date,
        p.pregnancy_anchor_date_link,
        DAY
      )
    END AS delivery_from_anchor_days,


    -- ------------------------------------------------------------------------
    -- BIOLOGICAL / TEMPORAL PLAUSIBILITY
    --
    -- Pregnancy anchor +126 to +322 days
    -- roughly 18–46 weeks.
    -- ------------------------------------------------------------------------

    CASE

      WHEN p.pregnancy_anchor_date_link IS NOT NULL

      THEN d.delivery_date
        BETWEEN
          DATE_ADD(
            p.pregnancy_anchor_date_link,
            INTERVAL minimum_plausible_ga_days DAY
          )

        AND
          DATE_ADD(
            p.pregnancy_anchor_date_link,
            INTERVAL maximum_plausible_ga_days DAY
          )


      WHEN p.expected_delivery_date_link IS NOT NULL

      THEN d.delivery_date
        BETWEEN
          DATE_SUB(
            p.expected_delivery_date_link,
            INTERVAL 154 DAY
          )

        AND
          DATE_ADD(
            p.expected_delivery_date_link,
            INTERVAL 42 DAY
          )


      ELSE FALSE

    END AS pregnancy_window_plausible


  FROM distinct_pairs x

  JOIN deliveries d
    USING (delivery_event_id)

  JOIN pregnancies p
    USING (pregnancy_episode_id)
),


with_corroborators AS (

  SELECT

    *,

    (
        CAST(dob_match AS INT64)
      + CAST(phone_match AS INT64)
      + CAST(
          COALESCE(
            hpht_difference_days <= pregnancy_dating_tolerance_days,
            FALSE
          )
          AS INT64
        )
      + CAST(
          COALESCE(
            hpl_difference_days <= pregnancy_dating_tolerance_days,
            FALSE
          )
          AS INT64
        )
      + CAST(puskesmas_match AS INT64)
    ) AS corroborator_count


  FROM pair_features
),


classified AS (

  SELECT

    *,

    CASE

      -- ======================================================================
      -- 1. TRUSTED NIK + BIOLOGICALLY PLAUSIBLE PREGNANCY
      --
      -- If both name and DOB explicitly disagree, do NOT auto-link.
      -- ======================================================================

      WHEN
        trusted_nik_exact

        AND pregnancy_window_plausible

        AND NOT (
          name_conflict
          AND dob_conflict
        )

      THEN 'NIK+PREGNANCY_WINDOW'


      -- ======================================================================
      -- 2. NAME + DOB
      -- ======================================================================

      WHEN
        compact_name_match

        AND dob_match

        AND pregnancy_window_plausible

        AND NOT trusted_nik_conflict

      THEN 'NAME+DOB+PREGNANCY_WINDOW'


      -- ======================================================================
      -- 3. NAME + HPHT
      -- ======================================================================

      WHEN
        compact_name_match

        AND hpht_difference_days
              <= pregnancy_dating_tolerance_days

        AND pregnancy_window_plausible

        AND NOT trusted_nik_conflict

      THEN 'NAME+HPHT_14D+PREGNANCY_WINDOW'


      -- ======================================================================
      -- 4. NAME + HPL
      -- ======================================================================

      WHEN
        compact_name_match

        AND hpl_difference_days
              <= pregnancy_dating_tolerance_days

        AND pregnancy_window_plausible

        AND NOT trusted_nik_conflict

      THEN 'NAME+HPL_14D+PREGNANCY_WINDOW'


      -- ======================================================================
      -- 5. PHONE + DOB
      -- ======================================================================

      WHEN
        phone_match

        AND dob_match

        AND pregnancy_window_plausible

        AND NOT trusted_nik_conflict

      THEN 'PHONE+DOB+PREGNANCY_WINDOW'


      -- ======================================================================
      -- 6. SAME NAME + SAME PUSKESMAS + DELIVERY VERY CLOSE TO EDD
      --
      -- deliberately restrictive because names may be common.
      -- ======================================================================

      WHEN
        compact_name_match

        AND puskesmas_match

        AND expected_delivery_difference_days
              <= close_expected_delivery_days

        AND pregnancy_window_plausible

        AND NOT trusted_nik_conflict

      THEN 'NAME+PKM+CLOSE_EDD'


      ELSE NULL

    END AS anc_match_method

  FROM with_corroborators
),


prioritized AS (

  SELECT

    *,

    CASE anc_match_method

      WHEN 'NIK+PREGNANCY_WINDOW'
        THEN 1

      WHEN 'NAME+DOB+PREGNANCY_WINDOW'
        THEN 2

      WHEN 'NAME+HPHT_14D+PREGNANCY_WINDOW'
        THEN 3

      WHEN 'NAME+HPL_14D+PREGNANCY_WINDOW'
        THEN 4

      WHEN 'PHONE+DOB+PREGNANCY_WINDOW'
        THEN 5

      WHEN 'NAME+PKM+CLOSE_EDD'
        THEN 6

    END AS anc_match_priority

  FROM classified
),


accepted_candidates AS (

  SELECT

    *,

    CASE

      WHEN anc_match_priority = 1
        THEN 'VERY_HIGH'

      WHEN anc_match_priority IN (2,3,4)
        THEN 'HIGH'

      ELSE 'MEDIUM'

    END AS anc_match_confidence

  FROM prioritized

  WHERE anc_match_method IS NOT NULL
)


SELECT *
FROM accepted_candidates;


-- ############################################################################
-- FINAL DELIVERY -> PREGNANCY LINK TABLE
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_pregnancy_link_v3_3`

CLUSTER BY
  anc_link_status,
  pregnancy_episode_id,
  delivery_event_id

AS

WITH ranked AS (

  SELECT

    c.*,

    DENSE_RANK() OVER (

      PARTITION BY c.delivery_event_id

      ORDER BY

        c.anc_match_priority,

        COALESCE(
          c.expected_delivery_difference_days,
          999999
        ),

        c.corroborator_count DESC,

        c.compact_name_match DESC,

        c.dob_match DESC

    ) AS candidate_rank

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_pregnancy_link_candidates_v3_3` c
),


best AS (

  SELECT *

  FROM ranked

  WHERE candidate_rank = 1
),


best_summary AS (

  SELECT

    delivery_event_id,

    COUNT(*) AS best_candidate_count,

    ANY_VALUE(pregnancy_episode_id)
      AS pregnancy_episode_id,

    ANY_VALUE(pregnancy_source_combination)
      AS pregnancy_source_combination,

    ANY_VALUE(anc_match_method)
      AS anc_match_method,

    ANY_VALUE(anc_match_priority)
      AS anc_match_priority,

    ANY_VALUE(anc_match_confidence)
      AS anc_match_confidence,

    ANY_VALUE(expected_delivery_difference_days)
      AS expected_delivery_difference_days,

    ANY_VALUE(delivery_from_anchor_days)
      AS delivery_from_anchor_days,

    ANY_VALUE(corroborator_count)
      AS corroborator_count,

    LOGICAL_OR(trusted_nik_exact)
      AS trusted_nik_exact,

    LOGICAL_OR(name_conflict)
      AS name_conflict,

    LOGICAL_OR(dob_conflict)
      AS dob_conflict

  FROM best

  GROUP BY delivery_event_id
),


-- ============================================================================
-- EXACT TRUSTED NIK PAIRS, INCLUDING IMPOSSIBLE DATES
--
-- Used only to distinguish:
--   NO_ANC_MATCH
-- from
--   ANC_LINK_DATE_IMPLAUSIBLE
-- ============================================================================

direct_nik_stats AS (

  SELECT

    d.delivery_event_id,

    COUNT(*) AS exact_nik_pregnancy_count,

    COUNTIF(

      CASE
        WHEN p.pregnancy_anchor_date IS NOT NULL

        THEN d.delivery_date BETWEEN
          DATE_ADD(
            p.pregnancy_anchor_date,
            INTERVAL minimum_plausible_ga_days DAY
          )
          AND
          DATE_ADD(
            p.pregnancy_anchor_date,
            INTERVAL maximum_plausible_ga_days DAY
          )

        ELSE FALSE
      END

    ) AS plausible_exact_nik_pregnancy_count


  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_v3_3` d

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3` p

    ON d.nik_clean = p.nik_clean

  WHERE
    nik_is_trusted(d.nik_clean)
    AND nik_is_trusted(p.nik_clean)

  GROUP BY d.delivery_event_id
)


SELECT

  d.delivery_event_id,

  d.delivery_date,

  d.nik_clean,

  d.nama_ibu,

  d.tanggal_lahir_ibu,

  d.hpht_date,

  d.hpl_date,

  d.puskesmas_norm,

  d.pregnancy_outcome_final,

  d.source_systems,

  d.source_tables,

  d.source_record_count,


  CASE

    -- ------------------------------------------------------------------------
    -- UNIQUE ACCEPTED PREGNANCY
    -- ------------------------------------------------------------------------

    WHEN b.best_candidate_count = 1

    THEN CASE

      WHEN b.pregnancy_source_combination
        = 'SIGIZI + EPUS'

        THEN 'MATCHED_SIGIZI_EPUS'

      WHEN b.pregnancy_source_combination
        = 'SIGIZI ONLY'

        THEN 'MATCHED_SIGIZI_ONLY'

      WHEN b.pregnancy_source_combination
        = 'EPUS ONLY'

        THEN 'MATCHED_EPUS_ONLY'

      ELSE 'MATCHED_ANC_OTHER'

    END


    -- ------------------------------------------------------------------------
    -- MORE THAN ONE EQUALLY GOOD PREGNANCY
    -- ------------------------------------------------------------------------

    WHEN b.best_candidate_count > 1

      THEN 'AMBIGUOUS_ANC_MATCH'


    -- ------------------------------------------------------------------------
    -- SAME TRUSTED NIK EXISTS IN ANC BUT DATE IS IMPOSSIBLE
    -- ------------------------------------------------------------------------

    WHEN n.exact_nik_pregnancy_count > 0
     AND COALESCE(
           n.plausible_exact_nik_pregnancy_count,
           0
         ) = 0

      THEN 'ANC_LINK_DATE_IMPLAUSIBLE'


    ELSE 'NO_ANC_MATCH'

  END AS anc_link_status,


  CASE
    WHEN b.best_candidate_count = 1
      THEN b.pregnancy_episode_id
  END AS pregnancy_episode_id,


  CASE
    WHEN b.best_candidate_count = 1
      THEN b.pregnancy_source_combination
  END AS pregnancy_source_combination,


  CASE
    WHEN b.best_candidate_count = 1
      THEN b.anc_match_method
  END AS anc_match_method,


  CASE
    WHEN b.best_candidate_count = 1
      THEN b.anc_match_priority
  END AS anc_match_priority,


  CASE
    WHEN b.best_candidate_count = 1
      THEN b.anc_match_confidence
  END AS anc_match_confidence,


  CASE
    WHEN b.best_candidate_count = 1
      THEN b.expected_delivery_difference_days
  END AS expected_delivery_difference_days,


  CASE
    WHEN b.best_candidate_count = 1
      THEN b.delivery_from_anchor_days
  END AS delivery_from_anchor_days,


  CASE
    WHEN b.best_candidate_count = 1
      THEN b.corroborator_count
  END AS linkage_corroborator_count,


  COALESCE(
    b.name_conflict,
    FALSE
  ) AS linkage_name_conflict_flag,


  COALESCE(
    b.dob_conflict,
    FALSE
  ) AS linkage_dob_conflict_flag,


  COALESCE(
    n.exact_nik_pregnancy_count,
    0
  ) AS exact_nik_pregnancy_candidates,


  COALESCE(
    n.plausible_exact_nik_pregnancy_count,
    0
  ) AS plausible_exact_nik_pregnancy_candidates,


  COALESCE(
    b.best_candidate_count,
    0
  ) AS best_candidate_count


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_v3_3` d

LEFT JOIN best_summary b
  USING (delivery_event_id)

LEFT JOIN direct_nik_stats n
  USING (delivery_event_id);
