-- Recovered source builder; v3 target. Run the complete file.
-- StandardSQL
-- ============================================================
-- ePUSKESMAS PREGNANCY EPISODE ASSIGNMENT
--
-- Output:
--   spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_records
--
-- Grain:
--   one row = one ePuskesmas source event
--             + assigned epus_mother_key
--             + assigned epus_pregnancy_key
--
-- IMPORTANT:
-- This table DOES NOT collapse events.
--
-- Example:
-- one pregnancy may still have:
--   ANC
--   ANC
--   ANC
--   DELIVERY
--   PNC
--   PNC
--
-- All those rows receive the same epus_pregnancy_key.
--
-- ============================================================

CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_records`

PARTITION BY event_date

CLUSTER BY
  epus_pregnancy_key,
  epus_mother_key,
  source_table,
  event_type

AS


WITH
-- ============================================================
-- 1. BASE RECORDS
--
-- Build one pregnancy reference candidate per source event.
--
-- Priority:
--
-- 1. Reported HPHT
-- 2. HPL - 280 days
-- 3. Delivery date - 280 days
--
-- These derived dates are ONLY matching anchors.
-- They do not replace source-reported HPHT.
-- ============================================================
base AS (
  SELECT
    m.*,


    -- --------------------------------------------------------
    -- Pregnancy reference candidate
    -- --------------------------------------------------------
    CASE
      WHEN hpht_date IS NOT NULL
      THEN hpht_date

      WHEN hpl_date IS NOT NULL
      THEN DATE_SUB(
        hpl_date,
        INTERVAL 280 DAY
      )

      WHEN delivery_date IS NOT NULL
      THEN DATE_SUB(
        delivery_date,
        INTERVAL 280 DAY
      )

      ELSE NULL
    END AS pregnancy_reference_candidate_date,


    -- --------------------------------------------------------
    -- How the reference candidate was obtained
    -- --------------------------------------------------------
    CASE
      WHEN hpht_date IS NOT NULL
      THEN 'HPHT_REPORTED'

      WHEN hpl_date IS NOT NULL
      THEN 'HPL_MINUS_280D'

      WHEN delivery_date IS NOT NULL
      THEN 'DELIVERY_MINUS_280D'

      ELSE 'NO_REFERENCE_DATE'
    END AS pregnancy_reference_candidate_method,


    -- --------------------------------------------------------
    -- Priority
    -- lower = preferred
    -- --------------------------------------------------------
    CASE
      WHEN hpht_date IS NOT NULL
      THEN 1

      WHEN hpl_date IS NOT NULL
      THEN 2

      WHEN delivery_date IS NOT NULL
      THEN 3

      ELSE 99
    END AS pregnancy_reference_candidate_priority,


    -- --------------------------------------------------------
    -- Reference confidence
    -- --------------------------------------------------------
    CASE
      WHEN hpht_date IS NOT NULL
      THEN 'HIGH'

      WHEN hpl_date IS NOT NULL
      THEN 'MEDIUM'

      WHEN delivery_date IS NOT NULL
      THEN 'MEDIUM'

      ELSE 'LOW'
    END AS pregnancy_reference_candidate_confidence

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_mother_records` m
),


-- ============================================================
-- 2. STRONG/AVAILABLE PREGNANCY ANCHORS
--
-- Only records having HPHT/HPL/delivery evidence participate
-- in initial episode construction.
-- ============================================================
anchor_lagged AS (
  SELECT
    b.*,

    LAG(
      pregnancy_reference_candidate_date
    ) OVER (
      PARTITION BY epus_mother_key

      ORDER BY
        pregnancy_reference_candidate_date,
        epus_source_record_key
    ) AS previous_reference_candidate_date

  FROM base b

  WHERE
    pregnancy_reference_candidate_date IS NOT NULL
),


-- ============================================================
-- 3. DETECT NEW PREGNANCY REFERENCE CLUSTERS
--
-- Reference dates ≤84 days apart are allowed to belong to the
-- same pregnancy episode.
--
-- Why 84 days?
-- Delivery - 280 days can differ substantially from true HPHT
-- in preterm birth. This gives a deliberately broad tolerance.
-- ============================================================
anchor_cluster_seed AS (
  SELECT
    a.*,

    CASE
      WHEN previous_reference_candidate_date IS NULL
      THEN 1

      WHEN DATE_DIFF(
        pregnancy_reference_candidate_date,
        previous_reference_candidate_date,
        DAY
      ) > 84
      THEN 1

      ELSE 0
    END AS starts_new_anchor_cluster

  FROM anchor_lagged a
),


-- ============================================================
-- 4. ASSIGN ANCHOR CLUSTER NUMBER
-- ============================================================
anchor_clustered AS (
  SELECT
    a.*,

    SUM(
      starts_new_anchor_cluster
    ) OVER (
      PARTITION BY epus_mother_key

      ORDER BY
        pregnancy_reference_candidate_date,
        epus_source_record_key

      ROWS BETWEEN UNBOUNDED PRECEDING
      AND CURRENT ROW
    ) AS anchor_cluster_number

  FROM anchor_cluster_seed a
),


-- ============================================================
-- 5. SUMMARIZE EACH ANCHORED PREGNANCY EPISODE
--
-- Select canonical pregnancy reference:
--
-- reported HPHT preferred
-- then HPL-derived
-- then delivery-derived
--
-- Within same priority, latest source snapshot wins.
-- ============================================================
anchor_episode_summary_raw AS (
  SELECT
    epus_mother_key,
    anchor_cluster_number,


    MIN(
      pregnancy_reference_candidate_date
    ) AS anchor_reference_min_date,

    MAX(
      pregnancy_reference_candidate_date
    ) AS anchor_reference_max_date,


    COUNT(*) AS anchor_source_record_count,


    COUNTIF(
      pregnancy_reference_candidate_method
        = 'HPHT_REPORTED'
    ) AS reported_hpht_anchor_count,


    COUNTIF(
      pregnancy_reference_candidate_method
        = 'HPL_MINUS_280D'
    ) AS hpl_anchor_count,


    COUNTIF(
      pregnancy_reference_candidate_method
        = 'DELIVERY_MINUS_280D'
    ) AS delivery_anchor_count,


    -- --------------------------------------------------------
    -- Actual delivery evidence inside this anchor cluster
    --
    -- MIN/MAX retained because twins around midnight or
    -- inconsistent source dates can differ slightly.
    -- --------------------------------------------------------
    MIN(delivery_date)
      AS episode_delivery_date_min,

    MAX(delivery_date)
      AS episode_delivery_date_max,


    -- --------------------------------------------------------
    -- Best pregnancy reference evidence
    -- --------------------------------------------------------
    ARRAY_AGG(
      STRUCT(
        pregnancy_reference_candidate_date
          AS reference_date,

        pregnancy_reference_candidate_method
          AS reference_method,

        pregnancy_reference_candidate_priority
          AS reference_priority,

        pregnancy_reference_candidate_confidence
          AS reference_confidence,

        source_recency_timestamp
          AS reference_source_recency,

        epus_source_record_key
          AS reference_source_record_key,

        source_table
          AS reference_source_table
      )

      ORDER BY
        pregnancy_reference_candidate_priority ASC,
        source_recency_timestamp DESC,
        epus_source_record_key DESC

      LIMIT 1
    )[OFFSET(0)] AS best_reference

  FROM anchor_clustered

  GROUP BY
    epus_mother_key,
    anchor_cluster_number
),


-- ============================================================
-- 6. FINAL ANCHORED EPISODE CATALOG
-- ============================================================
anchor_episode_catalog AS (
  SELECT
    epus_mother_key,
    anchor_cluster_number,

    best_reference.reference_date
      AS pregnancy_reference_date,

    best_reference.reference_method
      AS pregnancy_reference_method,

    best_reference.reference_confidence
      AS pregnancy_reference_confidence,

    best_reference.reference_source_record_key
      AS pregnancy_reference_source_record_key,

    best_reference.reference_source_table
      AS pregnancy_reference_source_table,


    anchor_reference_min_date,
    anchor_reference_max_date,

    DATE_DIFF(
      anchor_reference_max_date,
      anchor_reference_min_date,
      DAY
    ) AS pregnancy_anchor_span_days,


    anchor_source_record_count,
    reported_hpht_anchor_count,
    hpl_anchor_count,
    delivery_anchor_count,

    episode_delivery_date_min,
    episode_delivery_date_max,


    -- --------------------------------------------------------
    -- Episode anchor date
    --
    -- For anchored pregnancies this is the canonical pregnancy
    -- reference date.
    -- --------------------------------------------------------
    best_reference.reference_date
      AS pregnancy_episode_anchor_date,


    -- --------------------------------------------------------
    -- Pregnancy key
    -- --------------------------------------------------------
    CONCAT(
      'EPREG_',
      TO_HEX(
        SHA256(
          CONCAT(
            epus_mother_key,
            '|REFERENCE|',
            CAST(
              best_reference.reference_date
              AS STRING
            )
          )
        )
      )
    ) AS epus_pregnancy_key

  FROM anchor_episode_summary_raw
),


-- ============================================================
-- 7. DIRECTLY ANCHORED RECORD ASSIGNMENT
--
-- Records that supplied HPHT/HPL/delivery evidence already
-- belong to the anchor cluster constructed above.
-- ============================================================
anchored_assignments AS (
  SELECT
    a.epus_source_record_key,
    a.epus_mother_key,

    e.epus_pregnancy_key,

    e.pregnancy_episode_anchor_date,

    e.pregnancy_reference_date,
    e.pregnancy_reference_method,
    e.pregnancy_reference_confidence,

    e.pregnancy_reference_source_record_key,
    e.pregnancy_reference_source_table,

    e.anchor_reference_min_date,
    e.anchor_reference_max_date,
    e.pregnancy_anchor_span_days,

    e.anchor_source_record_count,
    e.reported_hpht_anchor_count,
    e.hpl_anchor_count,
    e.delivery_anchor_count,

    e.episode_delivery_date_min,
    e.episode_delivery_date_max,


    CONCAT(
      'ANCHOR_',
      a.pregnancy_reference_candidate_method
    ) AS pregnancy_assignment_method,


    a.pregnancy_reference_candidate_confidence
      AS pregnancy_match_confidence,


    ABS(
      DATE_DIFF(
        a.pregnancy_reference_candidate_date,
        e.pregnancy_reference_date,
        DAY
      )
    ) AS pregnancy_match_distance_days,


    1 AS pregnancy_candidate_episode_count

  FROM anchor_clustered a

  INNER JOIN anchor_episode_catalog e
    ON a.epus_mother_key = e.epus_mother_key
   AND a.anchor_cluster_number = e.anchor_cluster_number
),


-- ============================================================
-- 8. RECORDS WITHOUT HPHT/HPL/DELIVERY ANCHOR
-- ============================================================
unanchored_records AS (
  SELECT
    b.*

  FROM base b

  WHERE
    pregnancy_reference_candidate_date IS NULL
),


-- ============================================================
-- 9. TRY TO MATCH UNANCHORED EVENTS TO EXISTING PREGNANCIES
--
-- ANC:
--   event should occur approximately from HPHT through
--   pregnancy end.
--
-- PNC:
--   if delivery date exists in episode:
--       -7 to +90 days around delivery
--
--   otherwise:
--       approximately 120–390 days after reference date
--
-- DELIVERY:
--   mainly defensive; normally a DELIVERY record already
--   provides delivery_date and therefore has an anchor.
-- ============================================================
weak_candidate_raw AS (
  SELECT
    u.epus_source_record_key,
    u.epus_mother_key,

    u.event_type,
    u.event_date,


    e.epus_pregnancy_key,

    e.pregnancy_episode_anchor_date,

    e.pregnancy_reference_date,
    e.pregnancy_reference_method,
    e.pregnancy_reference_confidence,

    e.pregnancy_reference_source_record_key,
    e.pregnancy_reference_source_table,

    e.anchor_reference_min_date,
    e.anchor_reference_max_date,
    e.pregnancy_anchor_span_days,

    e.anchor_source_record_count,
    e.reported_hpht_anchor_count,
    e.hpl_anchor_count,
    e.delivery_anchor_count,

    e.episode_delivery_date_min,
    e.episode_delivery_date_max,


    -- --------------------------------------------------------
    -- Distance used for candidate ranking
    -- --------------------------------------------------------
    CASE
      WHEN u.event_type = 'PNC'
      THEN ABS(
        DATE_DIFF(
          u.event_date,

          COALESCE(
            e.episode_delivery_date_min,

            DATE_ADD(
              e.pregnancy_reference_date,
              INTERVAL 280 DAY
            )
          ),

          DAY
        )
      )


      WHEN u.event_type = 'DELIVERY'
      THEN ABS(
        DATE_DIFF(
          u.event_date,

          COALESCE(
            e.episode_delivery_date_min,

            DATE_ADD(
              e.pregnancy_reference_date,
              INTERVAL 280 DAY
            )
          ),

          DAY
        )
      )


      ELSE
        ABS(
          DATE_DIFF(
            u.event_date,
            e.pregnancy_reference_date,
            DAY
          )
        )
    END AS pregnancy_match_distance_days


  FROM unanchored_records u

  INNER JOIN anchor_episode_catalog e
    ON u.epus_mother_key = e.epus_mother_key

  WHERE
    u.event_date IS NOT NULL

    AND (

      -- ======================================================
      -- ANC
      -- ======================================================
      (
        u.event_type = 'ANC'

        AND u.event_date >= DATE_SUB(
          e.pregnancy_reference_date,
          INTERVAL 14 DAY
        )

        AND u.event_date <=
          CASE
            WHEN e.episode_delivery_date_max IS NOT NULL
            THEN DATE_ADD(
              e.episode_delivery_date_max,
              INTERVAL 14 DAY
            )

            ELSE DATE_ADD(
              e.pregnancy_reference_date,
              INTERVAL 330 DAY
            )
          END
      )


      OR


      -- ======================================================
      -- PNC
      -- ======================================================
      (
        u.event_type = 'PNC'

        AND (

          -- Known delivery date
          (
            e.episode_delivery_date_min IS NOT NULL

            AND u.event_date BETWEEN
              DATE_SUB(
                e.episode_delivery_date_min,
                INTERVAL 7 DAY
              )
              AND
              DATE_ADD(
                e.episode_delivery_date_max,
                INTERVAL 90 DAY
              )
          )


          OR


          -- No known delivery date
          (
            e.episode_delivery_date_min IS NULL

            AND u.event_date BETWEEN
              DATE_ADD(
                e.pregnancy_reference_date,
                INTERVAL 120 DAY
              )
              AND
              DATE_ADD(
                e.pregnancy_reference_date,
                INTERVAL 390 DAY
              )
          )
        )
      )


      OR


      -- ======================================================
      -- DELIVERY
      -- ======================================================
      (
        u.event_type = 'DELIVERY'

        AND u.event_date BETWEEN
          DATE_ADD(
            e.pregnancy_reference_date,
            INTERVAL 120 DAY
          )
          AND
          DATE_ADD(
            e.pregnancy_reference_date,
            INTERVAL 330 DAY
          )
      )
    )
),


-- ============================================================
-- 10. RANK POSSIBLE EPISODES FOR UNANCHORED RECORDS
--
-- ANC:
-- Prefer the most recent plausible pregnancy reference before
-- the visit.
--
-- PNC/DELIVERY:
-- Prefer closest delivery/expected-delivery date.
-- ============================================================
weak_candidate_ranked AS (
  SELECT
    w.*,


    COUNT(*) OVER (
      PARTITION BY epus_source_record_key
    ) AS pregnancy_candidate_episode_count,


    ROW_NUMBER() OVER (
      PARTITION BY epus_source_record_key

      ORDER BY

        -- ANC should preferentially attach to an anchor
        -- occurring before the visit.
        CASE
          WHEN event_type = 'ANC'
           AND pregnancy_reference_date <= event_date
          THEN 0

          WHEN event_type = 'ANC'
          THEN 1

          ELSE 0
        END ASC,


        -- For ANC choose the latest plausible pregnancy start.
        CASE
          WHEN event_type = 'ANC'
          THEN pregnancy_reference_date
        END DESC,


        -- For PNC / delivery use date proximity.
        pregnancy_match_distance_days ASC,


        pregnancy_episode_anchor_date DESC,

        epus_pregnancy_key

    ) AS pregnancy_candidate_rank

  FROM weak_candidate_raw w
),


-- ============================================================
-- 11. RETAIN BEST EVENT-DATE MATCH
-- ============================================================
weak_assignments AS (
  SELECT
    epus_source_record_key,
    epus_mother_key,

    epus_pregnancy_key,

    pregnancy_episode_anchor_date,

    pregnancy_reference_date,
    pregnancy_reference_method,
    pregnancy_reference_confidence,

    pregnancy_reference_source_record_key,
    pregnancy_reference_source_table,

    anchor_reference_min_date,
    anchor_reference_max_date,
    pregnancy_anchor_span_days,

    anchor_source_record_count,
    reported_hpht_anchor_count,
    hpl_anchor_count,
    delivery_anchor_count,

    episode_delivery_date_min,
    episode_delivery_date_max,


    'EVENT_DATE_TO_EXISTING_EPISODE'
      AS pregnancy_assignment_method,


    CASE
      WHEN pregnancy_candidate_episode_count = 1
      THEN 'MEDIUM'

      ELSE 'LOW'
    END AS pregnancy_match_confidence,


    pregnancy_match_distance_days,

    pregnancy_candidate_episode_count

  FROM weak_candidate_ranked

  WHERE
    pregnancy_candidate_rank = 1
),


-- ============================================================
-- 12. FIND RECORDS STILL UNASSIGNED
-- ============================================================
unmatched_records AS (
  SELECT
    u.*

  FROM unanchored_records u

  LEFT JOIN weak_assignments w
    USING (epus_source_record_key)

  WHERE
    w.epus_source_record_key IS NULL
),


-- ============================================================
-- 13. FALLBACK TIMELINE CLUSTER
--
-- For remaining records with event dates, cluster consecutive
-- events for the same mother.
--
-- A gap >210 days starts another fallback pregnancy.
--
-- This is LOW-confidence by design because no HPHT/HPL/
-- delivery anchor exists.
-- ============================================================
fallback_event_lagged AS (
  SELECT
    u.*,

    LAG(event_date) OVER (
      PARTITION BY epus_mother_key

      ORDER BY
        event_date,
        epus_source_record_key
    ) AS previous_unmatched_event_date

  FROM unmatched_records u

  WHERE
    event_date IS NOT NULL
),


fallback_event_seed AS (
  SELECT
    f.*,

    CASE
      WHEN previous_unmatched_event_date IS NULL
      THEN 1

      WHEN DATE_DIFF(
        event_date,
        previous_unmatched_event_date,
        DAY
      ) > 210
      THEN 1

      ELSE 0
    END AS starts_new_fallback_cluster

  FROM fallback_event_lagged f
),


fallback_event_clustered AS (
  SELECT
    f.*,

    SUM(
      starts_new_fallback_cluster
    ) OVER (
      PARTITION BY epus_mother_key

      ORDER BY
        event_date,
        epus_source_record_key

      ROWS BETWEEN UNBOUNDED PRECEDING
      AND CURRENT ROW
    ) AS fallback_cluster_number

  FROM fallback_event_seed f
),


fallback_event_with_dates AS (
  SELECT
    f.*,

    MIN(event_date) OVER (
      PARTITION BY
        epus_mother_key,
        fallback_cluster_number
    ) AS fallback_cluster_first_event_date,


    MAX(event_date) OVER (
      PARTITION BY
        epus_mother_key,
        fallback_cluster_number
    ) AS fallback_cluster_last_event_date

  FROM fallback_event_clustered f
),


-- ============================================================
-- 14. ASSIGN FALLBACK EVENT-TIMELINE PREGNANCIES
--
-- Notice:
-- pregnancy_reference_date remains NULL because we do NOT have
-- HPHT/HPL/delivery evidence.
--
-- The first event is only an episode anchor for grouping.
-- ============================================================
fallback_event_assignments AS (
  SELECT
    epus_source_record_key,
    epus_mother_key,


    CONCAT(
      'EPREG_',
      TO_HEX(
        SHA256(
          CONCAT(
            epus_mother_key,
            '|FALLBACK_EVENT|',
            CAST(
              fallback_cluster_first_event_date
              AS STRING
            )
          )
        )
      )
    ) AS epus_pregnancy_key,


    fallback_cluster_first_event_date
      AS pregnancy_episode_anchor_date,


    CAST(NULL AS DATE)
      AS pregnancy_reference_date,

    'NO_REFERENCE_DATE'
      AS pregnancy_reference_method,

    'LOW'
      AS pregnancy_reference_confidence,

    CAST(NULL AS STRING)
      AS pregnancy_reference_source_record_key,

    CAST(NULL AS STRING)
      AS pregnancy_reference_source_table,


    fallback_cluster_first_event_date
      AS anchor_reference_min_date,

    fallback_cluster_last_event_date
      AS anchor_reference_max_date,

    DATE_DIFF(
      fallback_cluster_last_event_date,
      fallback_cluster_first_event_date,
      DAY
    ) AS pregnancy_anchor_span_days,


    COUNT(*) OVER (
      PARTITION BY
        epus_mother_key,
        fallback_cluster_number
    ) AS anchor_source_record_count,


    0 AS reported_hpht_anchor_count,
    0 AS hpl_anchor_count,
    0 AS delivery_anchor_count,


    CAST(NULL AS DATE)
      AS episode_delivery_date_min,

    CAST(NULL AS DATE)
      AS episode_delivery_date_max,


    'FALLBACK_EVENT_TIMELINE_CLUSTER'
      AS pregnancy_assignment_method,

    'LOW'
      AS pregnancy_match_confidence,

    CAST(NULL AS INT64)
      AS pregnancy_match_distance_days,

    0 AS pregnancy_candidate_episode_count

  FROM fallback_event_with_dates
),


-- ============================================================
-- 15. RECORDS WITH NO PREGNANCY DATE AND NO EVENT DATE
--
-- Do not merge them.
--
-- Each remains a separate unresolved pregnancy assignment.
-- ============================================================
no_date_assignments AS (
  SELECT
    u.epus_source_record_key,
    u.epus_mother_key,


    CONCAT(
      'EPREG_',
      TO_HEX(
        SHA256(
          CONCAT(
            epus_mother_key,
            '|UNRESOLVED_SOURCE|',
            epus_source_record_key
          )
        )
      )
    ) AS epus_pregnancy_key,


    CAST(NULL AS DATE)
      AS pregnancy_episode_anchor_date,

    CAST(NULL AS DATE)
      AS pregnancy_reference_date,

    'NO_REFERENCE_DATE'
      AS pregnancy_reference_method,

    'LOW'
      AS pregnancy_reference_confidence,

    CAST(NULL AS STRING)
      AS pregnancy_reference_source_record_key,

    CAST(NULL AS STRING)
      AS pregnancy_reference_source_table,


    CAST(NULL AS DATE)
      AS anchor_reference_min_date,

    CAST(NULL AS DATE)
      AS anchor_reference_max_date,

    CAST(NULL AS INT64)
      AS pregnancy_anchor_span_days,


    1 AS anchor_source_record_count,

    0 AS reported_hpht_anchor_count,
    0 AS hpl_anchor_count,
    0 AS delivery_anchor_count,

    CAST(NULL AS DATE)
      AS episode_delivery_date_min,

    CAST(NULL AS DATE)
      AS episode_delivery_date_max,


    'UNRESOLVED_NO_PREGNANCY_DATE'
      AS pregnancy_assignment_method,

    'LOW'
      AS pregnancy_match_confidence,

    CAST(NULL AS INT64)
      AS pregnancy_match_distance_days,

    0 AS pregnancy_candidate_episode_count

  FROM unmatched_records u

  WHERE
    event_date IS NULL
),


-- ============================================================
-- 16. COMBINE ALL ASSIGNMENT METHODS
-- ============================================================
all_assignments AS (
  SELECT * FROM anchored_assignments

  UNION ALL

  SELECT * FROM weak_assignments

  UNION ALL

  SELECT * FROM fallback_event_assignments

  UNION ALL

  SELECT * FROM no_date_assignments
),


-- ============================================================
-- 17. BUILD UNIQUE EPISODE CATALOG
--
-- Needed to assign chronological pregnancy_episode_number
-- within each mother.
-- ============================================================
episode_catalog AS (
  SELECT
    epus_mother_key,
    epus_pregnancy_key,


    MIN(
      pregnancy_episode_anchor_date
    ) AS pregnancy_episode_anchor_date,


    ANY_VALUE(
      pregnancy_reference_date
    ) AS pregnancy_reference_date,

    ANY_VALUE(
      pregnancy_reference_method
    ) AS pregnancy_reference_method,

    ANY_VALUE(
      pregnancy_reference_confidence
    ) AS pregnancy_reference_confidence,

    ANY_VALUE(
      pregnancy_reference_source_record_key
    ) AS pregnancy_reference_source_record_key,

    ANY_VALUE(
      pregnancy_reference_source_table
    ) AS pregnancy_reference_source_table,


    MIN(anchor_reference_min_date)
      AS anchor_reference_min_date,

    MAX(anchor_reference_max_date)
      AS anchor_reference_max_date,


    MIN(episode_delivery_date_min)
      AS episode_delivery_date_min,

    MAX(episode_delivery_date_max)
      AS episode_delivery_date_max

  FROM all_assignments

  GROUP BY
    epus_mother_key,
    epus_pregnancy_key
),


-- ============================================================
-- 18. NUMBER PREGNANCIES CHRONOLOGICALLY WITHIN MOTHER
-- ============================================================
episode_numbered AS (
  SELECT
    e.*,

    ROW_NUMBER() OVER (
      PARTITION BY epus_mother_key

      ORDER BY

        -- episodes with dates first
        CASE
          WHEN pregnancy_episode_anchor_date IS NULL
          THEN 1
          ELSE 0
        END,

        pregnancy_episode_anchor_date,

        epus_pregnancy_key
    ) AS pregnancy_episode_number

  FROM episode_catalog e
),


-- ============================================================
-- 19. JOIN ASSIGNMENT BACK TO SOURCE EVENTS
-- ============================================================
assigned_records AS (
  SELECT
    b.*,


    -- --------------------------------------------------------
    -- Pregnancy identity
    -- --------------------------------------------------------
    a.epus_pregnancy_key,

    e.pregnancy_episode_number,

    a.pregnancy_episode_anchor_date,


    -- --------------------------------------------------------
    -- Canonical pregnancy reference
    -- --------------------------------------------------------
    a.pregnancy_reference_date,
    a.pregnancy_reference_method,
    a.pregnancy_reference_confidence,

    a.pregnancy_reference_source_record_key,
    a.pregnancy_reference_source_table,


    -- --------------------------------------------------------
    -- Anchor diagnostics
    -- --------------------------------------------------------
    a.anchor_reference_min_date,
    a.anchor_reference_max_date,
    a.pregnancy_anchor_span_days,

    a.anchor_source_record_count,

    a.reported_hpht_anchor_count,
    a.hpl_anchor_count,
    a.delivery_anchor_count,

    a.episode_delivery_date_min,
    a.episode_delivery_date_max,


    -- --------------------------------------------------------
    -- Per-record assignment diagnostics
    -- --------------------------------------------------------
    a.pregnancy_assignment_method,
    a.pregnancy_match_confidence,
    a.pregnancy_match_distance_days,
    a.pregnancy_candidate_episode_count

  FROM base b

  INNER JOIN all_assignments a
    USING (
      epus_source_record_key,
      epus_mother_key
    )

  INNER JOIN episode_numbered e
    USING (
      epus_mother_key,
      epus_pregnancy_key
    )
),


-- ============================================================
-- 20. PREGNANCY-LEVEL EVENT COUNTS
--
-- Joined onto every event for convenient QA.
-- ============================================================
final AS (
  SELECT
    a.*,


    COUNT(*) OVER (
      PARTITION BY epus_pregnancy_key
    ) AS pregnancy_source_record_count,


    COUNTIF(
      event_type = 'ANC'
    ) OVER (
      PARTITION BY epus_pregnancy_key
    ) AS pregnancy_anc_source_record_count,


    COUNTIF(
      event_type = 'DELIVERY'
    ) OVER (
      PARTITION BY epus_pregnancy_key
    ) AS pregnancy_delivery_source_record_count,


    COUNTIF(
      event_type = 'PNC'
    ) OVER (
      PARTITION BY epus_pregnancy_key
    ) AS pregnancy_pnc_source_record_count,


    MIN(event_date) OVER (
      PARTITION BY epus_pregnancy_key
    ) AS pregnancy_first_event_date,


    MAX(event_date) OVER (
      PARTITION BY epus_pregnancy_key
    ) AS pregnancy_latest_event_date,


    LOGICAL_OR(
      source_table = 'EPUS_ANC'
    ) OVER (
      PARTITION BY epus_pregnancy_key
    ) AS pregnancy_has_epus_anc,


    LOGICAL_OR(
      source_table = 'EPUS_KUNJUNGAN_IBU_HAMIL'
    ) OVER (
      PARTITION BY epus_pregnancy_key
    ) AS pregnancy_has_epus_kunjungan_ibu_hamil,


    LOGICAL_OR(
      source_table = 'EPUS_INC'
    ) OVER (
      PARTITION BY epus_pregnancy_key
    ) AS pregnancy_has_epus_inc,


    LOGICAL_OR(
      source_table = 'EPUS_PNC'
    ) OVER (
      PARTITION BY epus_pregnancy_key
    ) AS pregnancy_has_epus_pnc

  FROM assigned_records a
)


SELECT
  *
FROM final;