-- ============================================================================
-- PURBALINGGA
-- 07_POST_ANC_DELIVERY_CONSOLIDATION_V3_3
--
-- INPUTS
--   t_delivery_event_canonical_v3_3
--   t_delivery_pregnancy_link_v3_3
--
-- OUTPUTS
--   t_delivery_post_anc_map_v3_3
--   t_delivery_event_canonical_post_anc_v3_3
--
-- PRINCIPLE
--
-- For each canonical pregnancy:
--
--   1. Select the strongest delivery event as the pregnancy winner.
--
--   2. Other delivery events linked to that same pregnancy:
--
--        <= 42 days from winner
--             -> consolidate into winner
--
--        > 42 days from winner
--             -> do NOT merge
--             -> reject this pregnancy linkage
--             -> retain as standalone known delivery
--
-- Thus:
--
--   one pregnancy -> max one accepted delivery
--
-- while:
--
--   rejected/unlinked births are NEVER discarded.
-- ============================================================================


DECLARE post_anc_consolidation_days INT64 DEFAULT 42;


-- ============================================================================
-- CLEAN DOWNSTREAM TABLES
-- ============================================================================

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_post_anc_map_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_post_anc_v3_3`;


-- ############################################################################
-- STAGE 07A
-- CHOOSE ONE WINNER DELIVERY EVENT PER PREGNANCY
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_post_anc_map_v3_3`

CLUSTER BY
  post_anc_action,
  final_pregnancy_episode_id,
  final_delivery_event_id

AS

WITH event_link AS (

  SELECT

    l.*,

    d.source_system_count,
    d.source_table_count,

    d.live_birth_evidence_count,
    d.stillbirth_evidence_count,
    d.unknown_outcome_evidence_count,

    d.delivery_date_span_days
      AS pre_anc_delivery_date_span_days,

    d.delivery_date_chain_span_gt_3d_flag,

    d.gestational_age_conflict_flag,
    d.birth_weight_multi_value_flag

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_pregnancy_link_v3_3` l

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_v3_3` d

  USING (delivery_event_id)
),


-- ============================================================================
-- ONLY SUCCESSFULLY LINKED EVENTS
-- ============================================================================

accepted_links AS (

  SELECT *

  FROM event_link

  WHERE anc_link_status IN (
    'MATCHED_SIGIZI_EPUS',
    'MATCHED_SIGIZI_ONLY',
    'MATCHED_EPUS_ONLY',
    'MATCHED_ANC_OTHER'
  )

  AND pregnancy_episode_id IS NOT NULL
),


-- ============================================================================
-- WINNER RANKING
--
-- Priority:
--
-- 1. strongest linkage method
-- 2. closest to pregnancy EDD
-- 3. more corroborators
-- 4. more independent source systems
-- 5. more source records
-- 6. known outcome preferred
-- 7. deterministic tie break
-- ============================================================================

ranked AS (

  SELECT

    a.*,

    ROW_NUMBER() OVER (

      PARTITION BY pregnancy_episode_id

      ORDER BY

        COALESCE(
          anc_match_priority,
          999
        ) ASC,

        COALESCE(
          expected_delivery_difference_days,
          999999
        ) ASC,

        COALESCE(
          linkage_corroborator_count,
          0
        ) DESC,

        COALESCE(
          source_system_count,
          0
        ) DESC,

        COALESCE(
          source_record_count,
          0
        ) DESC,

        CASE
          WHEN pregnancy_outcome_final
            != 'UNKNOWN'
            THEN 0
          ELSE 1
        END ASC,

        delivery_date ASC,

        delivery_event_id ASC

    ) AS pregnancy_delivery_rank

  FROM accepted_links a
),


winner AS (

  SELECT

    pregnancy_episode_id,

    delivery_event_id
      AS winner_delivery_event_id,

    delivery_date
      AS winner_delivery_date,

    anc_link_status
      AS winner_anc_link_status,

    anc_match_method
      AS winner_anc_match_method,

    anc_match_priority
      AS winner_anc_match_priority,

    anc_match_confidence
      AS winner_anc_match_confidence,

    expected_delivery_difference_days
      AS winner_expected_delivery_difference_days,

    source_system_count
      AS winner_source_system_count,

    source_record_count
      AS winner_source_record_count

  FROM ranked

  WHERE pregnancy_delivery_rank = 1
),


-- ============================================================================
-- CLASSIFY ALL ORIGINALLY LINKED EVENTS
-- ============================================================================

matched_actions AS (

  SELECT

    a.delivery_event_id,

    a.anc_link_status
      AS pre_anc_link_status,

    a.pregnancy_episode_id
      AS pre_anc_pregnancy_episode_id,

    a.anc_match_method
      AS pre_anc_match_method,

    a.anc_match_confidence
      AS pre_anc_match_confidence,

    a.anc_match_priority
      AS pre_anc_match_priority,

    a.expected_delivery_difference_days,

    a.delivery_from_anchor_days,

    a.linkage_corroborator_count,

    a.linkage_name_conflict_flag,

    a.linkage_dob_conflict_flag,

    a.delivery_date,

    w.winner_delivery_event_id,

    w.winner_delivery_date,


    ABS(
      DATE_DIFF(
        a.delivery_date,
        w.winner_delivery_date,
        DAY
      )
    ) AS days_from_pregnancy_winner,


    CASE

      -- ----------------------------------------------------------------------
      -- WINNER
      -- ----------------------------------------------------------------------

      WHEN a.delivery_event_id
        = w.winner_delivery_event_id

        THEN 'PREGNANCY_WINNER'


      -- ----------------------------------------------------------------------
      -- SAME PREGNANCY, CLOSE ENOUGH TO REPRESENT
      -- THE SAME DELIVERY EVENT
      -- ----------------------------------------------------------------------

      WHEN ABS(
        DATE_DIFF(
          a.delivery_date,
          w.winner_delivery_date,
          DAY
        )
      ) <= post_anc_consolidation_days

        THEN 'CONSOLIDATED_TO_PREGNANCY_WINNER'


      -- ----------------------------------------------------------------------
      -- TOO FAR FROM WINNER
      --
      -- Do not delete.
      -- Remove pregnancy linkage and retain as known birth.
      -- ----------------------------------------------------------------------

      ELSE 'REJECTED_PREGNANCY_COLLISION_GT42D'

    END AS post_anc_action,


    CASE

      WHEN a.delivery_event_id
        = w.winner_delivery_event_id

        THEN w.winner_delivery_event_id


      WHEN ABS(
        DATE_DIFF(
          a.delivery_date,
          w.winner_delivery_date,
          DAY
        )
      ) <= post_anc_consolidation_days

        THEN w.winner_delivery_event_id


      ELSE a.delivery_event_id

    END AS final_delivery_event_id,


    CASE

      WHEN a.delivery_event_id
        = w.winner_delivery_event_id

        THEN a.pregnancy_episode_id


      WHEN ABS(
        DATE_DIFF(
          a.delivery_date,
          w.winner_delivery_date,
          DAY
        )
      ) <= post_anc_consolidation_days

        THEN a.pregnancy_episode_id


      ELSE NULL

    END AS final_pregnancy_episode_id,


    CASE

      WHEN a.delivery_event_id
        = w.winner_delivery_event_id

        THEN a.anc_link_status


      WHEN ABS(
        DATE_DIFF(
          a.delivery_date,
          w.winner_delivery_date,
          DAY
        )
      ) <= post_anc_consolidation_days

        THEN a.anc_link_status


      ELSE 'REJECTED_PREGNANCY_COLLISION'

    END AS final_anc_link_status,


    -- ------------------------------------------------------------------------
    -- Consolidation QA
    --
    -- Still consolidate <=42d because both independently linked to
    -- the same canonical pregnancy, but expose weaker/conflicting cases.
    -- ------------------------------------------------------------------------

    (
      a.delivery_event_id
        != w.winner_delivery_event_id

      AND ABS(
        DATE_DIFF(
          a.delivery_date,
          w.winner_delivery_date,
          DAY
        )
      ) <= post_anc_consolidation_days

      AND (
           a.linkage_name_conflict_flag
        OR a.linkage_dob_conflict_flag
        OR a.anc_match_confidence = 'MEDIUM'
      )
    ) AS post_anc_consolidation_qa_flag


  FROM accepted_links a

  JOIN winner w
    USING (pregnancy_episode_id)
),


-- ============================================================================
-- DELIVERY EVENTS THAT WERE NEVER ACCEPTED TO A PREGNANCY
-- ============================================================================

unlinked_actions AS (

  SELECT

    l.delivery_event_id,

    l.anc_link_status
      AS pre_anc_link_status,

    l.pregnancy_episode_id
      AS pre_anc_pregnancy_episode_id,

    l.anc_match_method
      AS pre_anc_match_method,

    l.anc_match_confidence
      AS pre_anc_match_confidence,

    l.anc_match_priority
      AS pre_anc_match_priority,

    l.expected_delivery_difference_days,

    l.delivery_from_anchor_days,

    l.linkage_corroborator_count,

    l.linkage_name_conflict_flag,

    l.linkage_dob_conflict_flag,

    l.delivery_date,

    CAST(NULL AS STRING)
      AS winner_delivery_event_id,

    CAST(NULL AS DATE)
      AS winner_delivery_date,

    CAST(NULL AS INT64)
      AS days_from_pregnancy_winner,


    CASE l.anc_link_status

      WHEN 'NO_ANC_MATCH'
        THEN 'RETAINED_NO_ANC_MATCH'

      WHEN 'ANC_LINK_DATE_IMPLAUSIBLE'
        THEN 'RETAINED_DATE_IMPLAUSIBLE'

      WHEN 'AMBIGUOUS_ANC_MATCH'
        THEN 'RETAINED_AMBIGUOUS'

      ELSE 'RETAINED_UNLINKED'

    END AS post_anc_action,


    l.delivery_event_id
      AS final_delivery_event_id,

    CAST(NULL AS STRING)
      AS final_pregnancy_episode_id,

    l.anc_link_status
      AS final_anc_link_status,

    FALSE
      AS post_anc_consolidation_qa_flag


  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_pregnancy_link_v3_3` l

  WHERE l.anc_link_status NOT IN (
    'MATCHED_SIGIZI_EPUS',
    'MATCHED_SIGIZI_ONLY',
    'MATCHED_EPUS_ONLY',
    'MATCHED_ANC_OTHER'
  )
)


SELECT *
FROM matched_actions

UNION ALL

SELECT *
FROM unlinked_actions;


-- ############################################################################
-- STAGE 07B
-- BUILD FINAL POST-ANC CANONICAL DATED DELIVERY TABLE
--
-- Representative identity/date is taken from the winning event.
--
-- Evidence from nearby consolidated events is aggregated into it.
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_post_anc_v3_3`

PARTITION BY delivery_date

CLUSTER BY
  pregnancy_episode_id,
  anc_link_status,
  nik_clean

AS

WITH members AS (

  SELECT

    m.final_delivery_event_id,

    m.final_pregnancy_episode_id,

    m.final_anc_link_status,

    m.post_anc_action,

    m.post_anc_consolidation_qa_flag,

    m.days_from_pregnancy_winner,

    m.delivery_event_id
      AS pre_anc_delivery_event_id,

    d.*

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_post_anc_map_v3_3` m

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_v3_3` d

  ON d.delivery_event_id
     = m.delivery_event_id
),


-- ============================================================================
-- ONE REPRESENTATIVE ROW PER FINAL EVENT
--
-- final_delivery_event_id always points to an existing canonical event.
-- ============================================================================

representative AS (

  SELECT
    *

  FROM members

  WHERE delivery_event_id
    = final_delivery_event_id

  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY final_delivery_event_id
    ORDER BY pre_anc_delivery_event_id
  ) = 1
),


-- ============================================================================
-- GROUP STATS
-- ============================================================================

group_stats AS (

  SELECT

    final_delivery_event_id,

    ANY_VALUE(
      final_pregnancy_episode_id
    ) AS final_pregnancy_episode_id,

    ANY_VALUE(
      final_anc_link_status
    ) AS final_anc_link_status,


    COUNT(*) AS preconsolidation_event_count,


    COUNTIF(
      post_anc_action
        = 'CONSOLIDATED_TO_PREGNANCY_WINNER'
    ) AS events_collapsed_post_anc,


    COUNTIF(
      post_anc_consolidation_qa_flag
    ) AS consolidation_qa_member_count,


    MIN(delivery_date)
      AS min_member_delivery_date,

    MAX(delivery_date)
      AS max_member_delivery_date,


    DATE_DIFF(
      MAX(delivery_date),
      MIN(delivery_date),
      DAY
    ) AS member_delivery_date_span_days,


    SUM(source_record_count)
      AS represented_source_record_count,


    SUM(
      live_birth_evidence_count
    ) AS live_birth_evidence_count,


    SUM(
      stillbirth_evidence_count
    ) AS stillbirth_evidence_count,


    SUM(
      unknown_outcome_evidence_count
    ) AS unknown_outcome_evidence_count,


    LOGICAL_OR(
      post_anc_consolidation_qa_flag
    ) AS post_anc_consolidation_qa_flag,


    ARRAY_AGG(
      pre_anc_delivery_event_id
      ORDER BY
        delivery_date,
        pre_anc_delivery_event_id
    ) AS pre_anc_delivery_event_ids,


    ARRAY_AGG(
      DISTINCT post_anc_action
      ORDER BY post_anc_action
    ) AS post_anc_actions


  FROM members

  GROUP BY final_delivery_event_id
),


-- ============================================================================
-- SOURCE SYSTEM UNION
-- ============================================================================

source_system_flat AS (

  SELECT
    m.final_delivery_event_id,
    source_system

  FROM members m

  CROSS JOIN UNNEST(
    m.source_systems
  ) AS source_system

  GROUP BY
    m.final_delivery_event_id,
    source_system
),


source_system_agg AS (

  SELECT

    final_delivery_event_id,

    ARRAY_AGG(
      source_system
      ORDER BY source_system
    ) AS source_systems,

    COUNT(*)
      AS source_system_count

  FROM source_system_flat

  GROUP BY final_delivery_event_id
),


-- ============================================================================
-- SOURCE TABLE UNION
-- ============================================================================

source_table_flat AS (

  SELECT
    m.final_delivery_event_id,
    source_table

  FROM members m

  CROSS JOIN UNNEST(
    m.source_tables
  ) AS source_table

  GROUP BY
    m.final_delivery_event_id,
    source_table
),


source_table_agg AS (

  SELECT

    final_delivery_event_id,

    ARRAY_AGG(
      source_table
      ORDER BY source_table
    ) AS source_tables,

    COUNT(*)
      AS source_table_count

  FROM source_table_flat

  GROUP BY final_delivery_event_id
),


-- ============================================================================
-- RAW SOURCE RECORD INSTANCE KEYS
-- ============================================================================

source_record_flat AS (

  SELECT
    m.final_delivery_event_id,
    source_record_instance_key

  FROM members m

  CROSS JOIN UNNEST(
    m.source_record_instance_keys
  ) AS source_record_instance_key

  GROUP BY
    m.final_delivery_event_id,
    source_record_instance_key
),


source_record_agg AS (

  SELECT

    final_delivery_event_id,

    ARRAY_AGG(
      source_record_instance_key
      ORDER BY source_record_instance_key
    ) AS source_record_instance_keys,

    COUNT(*)
      AS distinct_source_record_count

  FROM source_record_flat

  GROUP BY final_delivery_event_id
),


assembled AS (

  SELECT

    r.final_delivery_event_id
      AS delivery_event_id,


    -- ------------------------------------------------------------------------
    -- FINAL PREGNANCY LINK
    -- ------------------------------------------------------------------------

    g.final_pregnancy_episode_id
      AS pregnancy_episode_id,

    g.final_anc_link_status
      AS anc_link_status,


    -- ------------------------------------------------------------------------
    -- REPRESENTATIVE DELIVERY
    -- ------------------------------------------------------------------------

    r.delivery_date,

    r.nik_clean,

    r.nama_ibu,

    r.nama_norm,

    r.nama_core_norm,

    r.tanggal_lahir_ibu,

    r.no_hp_clean,

    r.hpht_date,

    r.hpl_date,

    r.puskesmas,

    r.puskesmas_norm,

    r.desa,

    r.desa_norm,

    r.posyandu,

    r.posyandu_norm,

    r.alamat,

    r.delivery_mode_raw,

    r.delivery_place_raw,

    r.representative_gestational_age_weeks,

    r.representative_birth_weight_grams,


    -- ------------------------------------------------------------------------
    -- FINAL OUTCOME CONSENSUS
    -- ------------------------------------------------------------------------

    CASE

      WHEN g.live_birth_evidence_count > 0
       AND g.stillbirth_evidence_count > 0

        THEN 'MIXED_LIVE_STILLBIRTH'


      WHEN g.live_birth_evidence_count > 0

        THEN 'LIVE_BIRTH'


      WHEN g.stillbirth_evidence_count > 0

        THEN 'STILLBIRTH'


      ELSE 'UNKNOWN'

    END AS pregnancy_outcome_final,


    -- ------------------------------------------------------------------------
    -- POST-ANC CONSOLIDATION
    -- ------------------------------------------------------------------------

    g.preconsolidation_event_count,

    g.events_collapsed_post_anc,

    g.preconsolidation_event_count > 1
      AS post_anc_consolidation_applied,

    g.min_member_delivery_date,

    g.max_member_delivery_date,

    g.member_delivery_date_span_days,

    g.post_anc_consolidation_qa_flag,

    g.consolidation_qa_member_count,

    g.pre_anc_delivery_event_ids,

    g.post_anc_actions,


    -- ------------------------------------------------------------------------
    -- SOURCE PROVENANCE
    -- ------------------------------------------------------------------------

    s.source_systems,

    s.source_system_count,

    t.source_tables,

    t.source_table_count,

    sr.source_record_instance_keys,

    sr.distinct_source_record_count,

    g.represented_source_record_count,


    -- ------------------------------------------------------------------------
    -- OUTCOME EVIDENCE
    -- ------------------------------------------------------------------------

    g.live_birth_evidence_count,

    g.stillbirth_evidence_count,

    g.unknown_outcome_evidence_count,


    (
      g.live_birth_evidence_count > 0
      AND g.stillbirth_evidence_count > 0
    ) AS live_stillbirth_mixed_flag,


    -- ------------------------------------------------------------------------
    -- FINAL LINK FLAGS
    -- ------------------------------------------------------------------------

    g.final_pregnancy_episode_id IS NOT NULL
      AS pregnancy_linked_flag,


    g.final_anc_link_status
      = 'REJECTED_PREGNANCY_COLLISION'
      AS rejected_pregnancy_collision_flag,


    g.final_anc_link_status
      = 'NO_ANC_MATCH'
      AS no_anc_match_flag,


    g.final_anc_link_status
      = 'ANC_LINK_DATE_IMPLAUSIBLE'
      AS anc_link_date_implausible_flag,


    g.final_anc_link_status
      = 'AMBIGUOUS_ANC_MATCH'
      AS ambiguous_anc_match_flag


  FROM representative r

  JOIN group_stats g
    USING (final_delivery_event_id)

  JOIN source_system_agg s
    USING (final_delivery_event_id)

  JOIN source_table_agg t
    USING (final_delivery_event_id)

  JOIN source_record_agg sr
    USING (final_delivery_event_id)
)


SELECT *
FROM assembled;


-- ############################################################################
-- QA 1
-- POST-ANC ACTIONS
-- ############################################################################

SELECT

  post_anc_action,

  COUNT(*) AS pre_anc_delivery_events

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_post_anc_map_v3_3`

GROUP BY post_anc_action

ORDER BY pre_anc_delivery_events DESC;


-- ############################################################################
-- QA 2
-- PRE -> POST COUNTS
-- ############################################################################

SELECT

  (
    SELECT COUNT(*)
    FROM
      `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_v3_3`
  ) AS pre_anc_delivery_events,


  (
    SELECT COUNT(*)
    FROM
      `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_post_anc_v3_3`
  ) AS final_delivery_events,


  (
    SELECT COUNTIF(
      post_anc_action
        = 'CONSOLIDATED_TO_PREGNANCY_WINNER'
    )
    FROM
      `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_post_anc_map_v3_3`
  ) AS events_collapsed_post_anc,


  (
    SELECT COUNTIF(
      post_anc_action
        = 'REJECTED_PREGNANCY_COLLISION_GT42D'
    )
    FROM
      `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_post_anc_map_v3_3`
  ) AS rejected_collision_events;


-- ############################################################################
-- QA 3
-- CRITICAL INVARIANT
--
-- One pregnancy may have at most one ACCEPTED final delivery.
--
-- EXPECTED:
-- pregnancies_with_multiple_accepted_deliveries = 0
-- ############################################################################

WITH x AS (

  SELECT

    pregnancy_episode_id,

    COUNT(*) AS accepted_deliveries

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_post_anc_v3_3`

  WHERE pregnancy_episode_id IS NOT NULL

  GROUP BY pregnancy_episode_id
)

SELECT

  COUNT(*) AS pregnancies_with_delivery,

  COUNTIF(
    accepted_deliveries = 1
  ) AS pregnancies_with_one_accepted_delivery,

  COUNTIF(
    accepted_deliveries > 1
  ) AS pregnancies_with_multiple_accepted_deliveries,

  MAX(
    accepted_deliveries
  ) AS max_accepted_deliveries_one_pregnancy

FROM x;


-- ############################################################################
-- QA 4
-- FINAL LINKAGE STATUS
-- ############################################################################

SELECT

  anc_link_status,

  COUNT(*) AS final_delivery_events

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_post_anc_v3_3`

GROUP BY anc_link_status

ORDER BY final_delivery_events DESC;


-- ############################################################################
-- QA 5
-- COLLISION DETAIL
-- ############################################################################

SELECT

  CASE

    WHEN days_from_pregnancy_winner = 0
      THEN 'WINNER / SAME DATE'

    WHEN days_from_pregnancy_winner
      BETWEEN 1 AND 3
      THEN '01-03 DAYS'

    WHEN days_from_pregnancy_winner
      BETWEEN 4 AND 14
      THEN '04-14 DAYS'

    WHEN days_from_pregnancy_winner
      BETWEEN 15 AND 42
      THEN '15-42 DAYS'

    ELSE '>42 DAYS'

  END AS distance_from_winner,

  post_anc_action,

  COUNT(*) AS delivery_events

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_post_anc_map_v3_3`

WHERE winner_delivery_event_id IS NOT NULL

GROUP BY
  distance_from_winner,
  post_anc_action

ORDER BY
  CASE distance_from_winner
    WHEN 'WINNER / SAME DATE' THEN 1
    WHEN '01-03 DAYS' THEN 2
    WHEN '04-14 DAYS' THEN 3
    WHEN '15-42 DAYS' THEN 4
    ELSE 5
  END;


-- ############################################################################
-- QA 6
-- CONSOLIDATION QA FLAGS
-- ############################################################################

SELECT

  COUNT(*) AS final_delivery_events,

  COUNTIF(
    post_anc_consolidation_applied
  ) AS final_events_with_post_anc_consolidation,

  SUM(
    events_collapsed_post_anc
  ) AS total_events_collapsed_post_anc,

  COUNTIF(
    post_anc_consolidation_qa_flag
  ) AS consolidated_groups_requiring_qa,

  COUNTIF(
    rejected_pregnancy_collision_flag
  ) AS rejected_collision_events

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_post_anc_v3_3`;


-- ############################################################################
-- QA 7
-- FINAL OUTCOME
-- ############################################################################

SELECT

  pregnancy_outcome_final,

  COUNT(*) AS final_delivery_events

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_post_anc_v3_3`

GROUP BY pregnancy_outcome_final

ORDER BY final_delivery_events DESC;


-- ############################################################################
-- QA 8
-- FINAL DELIVERY EVENT ID UNIQUENESS
--
-- EXPECTED: no rows
-- ############################################################################

SELECT

  delivery_event_id,

  COUNT(*) AS n

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_post_anc_v3_3`

GROUP BY delivery_event_id

HAVING COUNT(*) > 1

ORDER BY n DESC;
