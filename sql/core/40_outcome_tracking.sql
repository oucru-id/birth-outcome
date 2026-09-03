-- Independent source layer: references redirected to v3; original logic retained.
-- V3 CORE DRAFT: not executed in BigQuery; production compatibility not yet validated.
-- Run this entire file as one job. Existing v2 inputs are read only.
-- Original comments below describe recovered historical scripts, not current counts.

-- ============================================================================
-- PREGNANCY OUTCOME TRACKING v3.3
-- STAGE 6 ONLY — PHONE-VALIDATED VERSION v2
--
-- INPUTS:
--   t_pregnancy_episode_spine_v3_3
--   t_pregnancy_outcome_events_v3_3
--   t_pregnancy_usg_dating_v3_3
--
-- OUTPUT:
--   t_pregnancy_outcome_tracking_v3_3
--
-- PHONE FIX:
--   * no_hp_raw_clean preserves the original pregnancy-source value
--   * no_hp_clean and no_hp_final contain only a plausible Indonesian mobile number
--   * 62xxxxxxxxxx and 8xxxxxxxxxx are normalized to 08xxxxxxxxxx
--   * invalid / placeholder values do not count as having a phone
--   * invalid pregnancy-source phone no longer blocks a valid outcome-source phone
--   * has_phone is derived from validated no_hp_final
--   * missing_birth_has_phone_flag / missing_birth_no_phone_flag follow has_phone
-- ============================================================================


-- ============================================================================
-- PARAMETERS
-- ============================================================================

DECLARE monitoring_start_date DATE DEFAULT DATE '2025-12-01';
DECLARE plausible_pregnancy_floor DATE DEFAULT DATE '2018-01-01';


-- ============================================================================
-- PHONE FUNCTIONS
-- ============================================================================

CREATE TEMP FUNCTION normalize_mobile_phone(s STRING)
RETURNS STRING
AS (
  CASE
    WHEN NULLIF(
      REGEXP_REPLACE(
        COALESCE(s, ''),
        r'[^0-9]',
        ''
      ),
      ''
    ) IS NULL
      THEN NULL

    -- +62 / 62 format -> 08 format
    WHEN STARTS_WITH(
      REGEXP_REPLACE(COALESCE(s, ''), r'[^0-9]', ''),
      '62'
    )
      THEN CONCAT(
        '0',
        SUBSTR(
          REGEXP_REPLACE(COALESCE(s, ''), r'[^0-9]', ''),
          3
        )
      )

    -- Missing leading zero: 8xxxxxxxxxx -> 08xxxxxxxxxx
    WHEN STARTS_WITH(
      REGEXP_REPLACE(COALESCE(s, ''), r'[^0-9]', ''),
      '8'
    )
      THEN CONCAT(
        '0',
        REGEXP_REPLACE(COALESCE(s, ''), r'[^0-9]', '')
      )

    ELSE REGEXP_REPLACE(
      COALESCE(s, ''),
      r'[^0-9]',
      ''
    )
  END
);


CREATE TEMP FUNCTION is_valid_mobile_phone(s STRING)
RETURNS BOOL
AS (
  -- Plausible Indonesian mobile number in national format:
  -- starts 08, third digit 1-9, total length 10-13 digits.
  REGEXP_CONTAINS(
    COALESCE(normalize_mobile_phone(s), ''),
    r'^08[1-9][0-9]{7,10}$'
  )

  -- Reject obvious repeated-digit placeholders such as:
  -- 0811111111, 0810000000, 0822222222, etc.
  AND NOT REGEXP_CONTAINS(
    COALESCE(normalize_mobile_phone(s), ''),
    r'^08[1-9](?:0{7,10}|1{7,10}|2{7,10}|3{7,10}|4{7,10}|5{7,10}|6{7,10}|7{7,10}|8{7,10}|9{7,10})$'
  )

  -- Reject known sequential / test placeholders.
  -- These satisfy the basic length/prefix rule but are not treated as
  -- usable contact numbers for operational follow-up.
  AND COALESCE(normalize_mobile_phone(s), '') NOT IN (
    '0812345678',
    '08123456789',
    '081234567890',
    '0812345678901'
  )
);


-- ============================================================================
-- STAGE 6
-- MATCH OUTCOME EVENTS TO THE CANONICAL PREGNANCY SPINE
-- ============================================================================

CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_tracking_v3_3`
PARTITION BY expected_delivery_date
CLUSTER BY puskesmas_norm, pregnancy_tracking_status, nik_clean
AS

WITH spine AS (
  SELECT
    p.*,

    COUNT(*) OVER (
      PARTITION BY nik_clean
    ) AS nik_episode_count

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` p
),

events AS (
  SELECT *
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_events_v3_3`
),


-- --------------------------------------------------------------------------
-- MATCH 0: DIRECT EPUS EPISODE KEY
-- --------------------------------------------------------------------------
direct_epus_matches AS (
  SELECT
    p.pregnancy_episode_id,
    e.*,

    'DIRECT_EPUS_EPISODE_KEY'
      AS outcome_match_method,

    0 AS outcome_match_priority,

    0 AS match_distance_days

  FROM spine p

  JOIN events e
    ON e.source_system = 'EPUS'

   AND e.epus_episode_source_key IS NOT NULL

   AND (
     e.epus_episode_source_key = p.epus_episode_source_key
     OR e.epus_episode_source_key IN UNNEST(
       COALESCE(
         p.epus_episode_source_keys,
         ARRAY<STRING>[]
       )
     )
   )
),


-- --------------------------------------------------------------------------
-- MATCH 1: NIK + PREGNANCY WINDOW
-- --------------------------------------------------------------------------
nik_date_matches AS (
  SELECT
    p.pregnancy_episode_id,
    e.*,

    'NIK+PREGNANCY_WINDOW'
      AS outcome_match_method,

    1 AS outcome_match_priority,

    ABS(
      DATE_DIFF(
        e.match_reference_date,
        COALESCE(
          p.hpl_recorded_date,
          p.hpl_from_hpht_date,
          DATE_ADD(
            p.pregnancy_anchor_date,
            INTERVAL 280 DAY
          )
        ),
        DAY
      )
    ) AS match_distance_days

  FROM spine p

  JOIN events e
    ON p.nik_clean IS NOT NULL
   AND e.nik_clean IS NOT NULL
   AND p.nik_clean = e.nik_clean

   AND e.match_reference_date IS NOT NULL

   AND e.match_reference_date BETWEEN
     DATE_SUB(
       p.pregnancy_anchor_date,
       INTERVAL 30 DAY
     )
     AND DATE_ADD(
       p.pregnancy_anchor_date,
       INTERVAL 350 DAY
     )

  WHERE NOT (
    e.source_system = 'EPUS'
    AND e.epus_episode_source_key IS NOT NULL
    AND (
      e.epus_episode_source_key = p.epus_episode_source_key
      OR e.epus_episode_source_key IN UNNEST(
        COALESCE(
          p.epus_episode_source_keys,
          ARRAY<STRING>[]
        )
      )
    )
  )
),


-- --------------------------------------------------------------------------
-- MATCH 2: NAME + DOB + PREGNANCY WINDOW
-- --------------------------------------------------------------------------
name_dob_date_matches AS (
  SELECT
    p.pregnancy_episode_id,
    e.*,

    'NAMA+DOB+PREGNANCY_WINDOW'
      AS outcome_match_method,

    2 AS outcome_match_priority,

    ABS(
      DATE_DIFF(
        e.match_reference_date,
        COALESCE(
          p.hpl_recorded_date,
          p.hpl_from_hpht_date,
          DATE_ADD(
            p.pregnancy_anchor_date,
            INTERVAL 280 DAY
          )
        ),
        DAY
      )
    ) AS match_distance_days

  FROM spine p

  JOIN events e
    ON p.nama_norm IS NOT NULL
   AND e.nama_norm IS NOT NULL
   AND p.nama_norm = e.nama_norm

   AND p.tanggal_lahir_ibu IS NOT NULL
   AND e.tanggal_lahir IS NOT NULL
   AND p.tanggal_lahir_ibu = e.tanggal_lahir

   AND (
     p.nik_clean IS NULL
     OR e.nik_clean IS NULL
   )

   AND e.match_reference_date IS NOT NULL

   AND e.match_reference_date BETWEEN
     DATE_SUB(
       p.pregnancy_anchor_date,
       INTERVAL 30 DAY
     )
     AND DATE_ADD(
       p.pregnancy_anchor_date,
       INTERVAL 350 DAY
     )
),


-- --------------------------------------------------------------------------
-- MATCH 3: UNIQUE NIK EPISODE WITH NO EVENT DATE
-- --------------------------------------------------------------------------
no_date_unique_nik_matches AS (
  SELECT
    p.pregnancy_episode_id,
    e.*,

    'UNIQUE_NIK_EPISODE_NO_DATE'
      AS outcome_match_method,

    3 AS outcome_match_priority,

    9999 AS match_distance_days

  FROM spine p

  JOIN events e
    ON p.nik_clean IS NOT NULL
   AND e.nik_clean IS NOT NULL
   AND p.nik_clean = e.nik_clean

   AND p.nik_episode_count = 1

   AND e.match_reference_date IS NULL
   AND e.pregnancy_outcome_norm IS NOT NULL
),


all_candidates AS (
  SELECT * FROM direct_epus_matches
  UNION ALL
  SELECT * FROM nik_date_matches
  UNION ALL
  SELECT * FROM name_dob_date_matches
  UNION ALL
  SELECT * FROM no_date_unique_nik_matches
),


ranked AS (
  SELECT
    *,

    ROW_NUMBER() OVER (
      PARTITION BY source_event_id
      ORDER BY
        outcome_match_priority,
        match_distance_days,
        pregnancy_episode_id
    ) AS rn

  FROM all_candidates
),


matched_events AS (
  SELECT * EXCEPT(rn)
  FROM ranked
  WHERE rn = 1
),


-- ============================================================================
-- AGGREGATE MATCHED OUTCOME EVENTS TO PREGNANCY LEVEL
-- ============================================================================
outcome_agg AS (
  SELECT
    pregnancy_episode_id,

    COUNT(*) AS matched_outcome_event_count,

    COUNT(
      DISTINCT source_system
    ) AS matched_outcome_source_count,

    ARRAY_AGG(
      DISTINCT outcome_match_method
      ORDER BY outcome_match_method
    ) AS outcome_match_methods,

    MIN(
      outcome_match_priority
    ) AS best_outcome_match_priority,


    -- ========================================================================
    -- DELIVERY SOURCE FLAGS
    -- ========================================================================

    LOGICAL_OR(
      source_system = 'SIGIZI'
      AND delivery_date IS NOT NULL
    ) AS has_delivery_sigizi,

    LOGICAL_OR(
      source_system = 'EPUS'
      AND delivery_date IS NOT NULL
    ) AS has_delivery_epus,

    LOGICAL_OR(
      source_system = 'SIMRS'
      AND delivery_date IS NOT NULL
    ) AS has_delivery_simrs,

    LOGICAL_OR(
      source_system = 'KOBO_INC'
      AND delivery_date IS NOT NULL
    ) AS has_delivery_kobo_inc,

    LOGICAL_OR(
      source_system = 'NEONATAL_OUTCOME'
      AND delivery_date IS NOT NULL
    ) AS has_delivery_neonatal,

    LOGICAL_OR(
      source_system = 'INC_REPORT_TRACKER'
      AND delivery_date IS NOT NULL
    ) AS has_delivery_inc_report,


    -- ========================================================================
    -- OUTCOME EVIDENCE
    -- ========================================================================

    LOGICAL_OR(
      pregnancy_outcome_norm = 'LAHIR HIDUP'
    ) AS has_live_birth_evidence,

    LOGICAL_OR(
      pregnancy_outcome_norm = 'LAHIR MATI'
    ) AS has_stillbirth_evidence,

    LOGICAL_OR(
      pregnancy_outcome_norm = 'ABORTUS'
    ) AS has_abortus_evidence,

    LOGICAL_OR(
      source_system = 'SIGIZI'
      AND pregnancy_outcome_norm IS NOT NULL
    ) AS has_outcome_sigizi,

    LOGICAL_OR(
      source_system = 'EPUS'
      AND pregnancy_outcome_norm IS NOT NULL
    ) AS has_outcome_epus,

    LOGICAL_OR(
      source_system = 'SIMRS'
      AND pregnancy_outcome_norm IS NOT NULL
    ) AS has_outcome_simrs,

    LOGICAL_OR(
      source_system = 'KOBO_INC'
      AND pregnancy_outcome_norm IS NOT NULL
    ) AS has_outcome_kobo_inc,

    LOGICAL_OR(
      source_system = 'NEONATAL_OUTCOME'
      AND pregnancy_outcome_norm IS NOT NULL
    ) AS has_outcome_neonatal,

    LOGICAL_OR(
      source_system = 'INC_REPORT_TRACKER'
      AND pregnancy_outcome_norm IS NOT NULL
    ) AS has_outcome_inc_report,


    -- ========================================================================
    -- SOURCE-SPECIFIC DELIVERY DATES
    -- ========================================================================

    MIN(
      IF(
        source_system = 'SIGIZI',
        delivery_date,
        NULL
      )
    ) AS delivery_date_sigizi,

    MIN(
      IF(
        source_system = 'EPUS',
        delivery_date,
        NULL
      )
    ) AS delivery_date_epus,

    MIN(
      IF(
        source_system = 'SIMRS',
        delivery_date,
        NULL
      )
    ) AS delivery_date_simrs,

    MIN(
      IF(
        source_system = 'KOBO_INC',
        delivery_date,
        NULL
      )
    ) AS delivery_date_kobo_inc,

    MIN(
      IF(
        source_system = 'NEONATAL_OUTCOME',
        delivery_date,
        NULL
      )
    ) AS delivery_date_neonatal,

    MIN(
      IF(
        source_system = 'INC_REPORT_TRACKER',
        delivery_date,
        NULL
      )
    ) AS delivery_date_inc_report,

    COUNT(
      DISTINCT delivery_date
    ) AS delivery_date_distinct_count,

    ARRAY_AGG(
      DISTINCT CAST(
        delivery_date
        AS STRING
      )
      IGNORE NULLS
      ORDER BY
        CAST(
          delivery_date
          AS STRING
        )
    ) AS all_delivery_dates,


    -- ========================================================================
    -- PRIMARY DELIVERY
    -- ========================================================================

    ARRAY_AGG(
      IF(
        delivery_date IS NOT NULL,
        STRUCT(
          delivery_date AS delivery_date,
          source_system AS source_system,
          source_subtype AS source_subtype,
          source_priority AS source_priority,
          source_record_id AS source_record_id
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY
        source_priority,
        delivery_date,
        source_record_id
      LIMIT 1
    )[SAFE_OFFSET(0)]
      AS primary_delivery_pick,


    -- ========================================================================
    -- PRIMARY EXPLICIT OUTCOME
    -- ========================================================================

    ARRAY_AGG(
      IF(
        pregnancy_outcome_norm IS NOT NULL,
        STRUCT(
          pregnancy_outcome_norm AS pregnancy_outcome,
          source_system AS source_system,
          source_subtype AS source_subtype,
          source_priority AS source_priority,
          source_record_id AS source_record_id
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY
        source_priority,
        source_record_id
      LIMIT 1
    )[SAFE_OFFSET(0)]
      AS primary_outcome_pick,


    -- ========================================================================
    -- ABORTION PICK
    -- ========================================================================

    ARRAY_AGG(
      IF(
        abortion_date IS NOT NULL,
        STRUCT(
          abortion_date AS abortion_date,
          source_system AS source_system,
          source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY
        source_priority,
        abortion_date
      LIMIT 1
    )[SAFE_OFFSET(0)]
      AS abortion_pick,


    -- ========================================================================
    -- VALID OUTCOME-SOURCE PHONE PICK
    --
    -- IMPORTANT:
    -- Invalid values are filtered here before ranking.
    -- ========================================================================

    ARRAY_AGG(
      IF(
        is_valid_mobile_phone(no_hp_clean),
        STRUCT(
          normalize_mobile_phone(no_hp_clean)
            AS no_hp_clean,
          source_system
            AS source_system,
          source_priority
            AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY
        source_priority,
        LENGTH(normalize_mobile_phone(no_hp_clean)) DESC
      LIMIT 1
    )[SAFE_OFFSET(0)]
      AS outcome_phone_pick,


    -- ========================================================================
    -- OTHER DELIVERY ATTRIBUTES
    -- ========================================================================

    ARRAY_AGG(
      IF(
        maternal_outcome_norm IS NOT NULL,
        STRUCT(
          maternal_outcome_norm AS value,
          source_system AS source_system,
          source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY source_priority
      LIMIT 1
    )[SAFE_OFFSET(0)]
      AS maternal_outcome_pick,

    ARRAY_AGG(
      IF(
        delivery_mode_norm IS NOT NULL,
        STRUCT(
          delivery_mode_norm AS value,
          source_system AS source_system,
          source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY source_priority
      LIMIT 1
    )[SAFE_OFFSET(0)]
      AS delivery_mode_pick,

    ARRAY_AGG(
      IF(
        delivery_facility_norm IS NOT NULL,
        STRUCT(
          delivery_facility_norm AS value,
          source_system AS source_system,
          source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY source_priority
      LIMIT 1
    )[SAFE_OFFSET(0)]
      AS delivery_facility_pick

  FROM matched_events

  GROUP BY pregnancy_episode_id
),


-- ============================================================================
-- JOIN PREGNANCY SPINE + USG + OUTCOME AGGREGATE
-- ============================================================================
joined AS (
  SELECT
    -- Preserve the original pregnancy-source phone for QA, but do not expose
    -- it as the canonical no_hp_clean field. The canonical no_hp_clean below
    -- contains only a validated usable phone.
    p.* EXCEPT(no_hp_clean),
    p.no_hp_clean AS no_hp_raw_clean,

    u.dating_usg_record_id,
    u.usg_match_method,
    u.usg_match_priority,
    u.dating_usg_date,
    u.dating_usg_ga_weeks,
    u.dating_usg_ga_days,

    u.usg_recorded_hpl_date,
    u.hpl_from_usg_ga_date,
    u.hpl_from_usg_date,
    u.usg_recorded_minus_calculated_hpl_days,
    u.usg_dating_quality,
    u.usg_dating_quality_priority,

    COALESCE(
      o.matched_outcome_event_count,
      0
    ) AS matched_outcome_event_count,

    COALESCE(
      o.matched_outcome_source_count,
      0
    ) AS matched_outcome_source_count,

    o.outcome_match_methods,
    o.best_outcome_match_priority,

    COALESCE(o.has_delivery_sigizi, FALSE)
      AS has_delivery_sigizi,

    COALESCE(o.has_delivery_epus, FALSE)
      AS has_delivery_epus,

    COALESCE(o.has_delivery_simrs, FALSE)
      AS has_delivery_simrs,

    COALESCE(o.has_delivery_kobo_inc, FALSE)
      AS has_delivery_kobo_inc,

    COALESCE(o.has_delivery_neonatal, FALSE)
      AS has_delivery_neonatal,

    COALESCE(o.has_delivery_inc_report, FALSE)
      AS has_delivery_inc_report,

    COALESCE(o.has_outcome_sigizi, FALSE)
      AS has_outcome_sigizi,

    COALESCE(o.has_outcome_epus, FALSE)
      AS has_outcome_epus,

    COALESCE(o.has_outcome_simrs, FALSE)
      AS has_outcome_simrs,

    COALESCE(o.has_outcome_kobo_inc, FALSE)
      AS has_outcome_kobo_inc,

    COALESCE(o.has_outcome_neonatal, FALSE)
      AS has_outcome_neonatal,

    COALESCE(o.has_outcome_inc_report, FALSE)
      AS has_outcome_inc_report,

    COALESCE(o.has_live_birth_evidence, FALSE)
      AS has_live_birth_evidence,

    COALESCE(o.has_stillbirth_evidence, FALSE)
      AS has_stillbirth_evidence,

    COALESCE(o.has_abortus_evidence, FALSE)
      AS has_abortus_evidence,

    o.delivery_date_sigizi,
    o.delivery_date_epus,
    o.delivery_date_simrs,
    o.delivery_date_kobo_inc,
    o.delivery_date_neonatal,
    o.delivery_date_inc_report,

    COALESCE(
      o.delivery_date_distinct_count,
      0
    ) AS delivery_date_distinct_count,

    o.all_delivery_dates,

    o.primary_delivery_pick.delivery_date
      AS actual_delivery_date,

    o.primary_delivery_pick.source_system
      AS primary_delivery_source,

    o.primary_delivery_pick.source_subtype
      AS primary_delivery_source_subtype,

    o.primary_outcome_pick.pregnancy_outcome
      AS primary_explicit_outcome,

    o.primary_outcome_pick.source_system
      AS primary_outcome_source,

    o.abortion_pick.abortion_date
      AS abortion_date,

    o.abortion_pick.source_system
      AS abortion_source,


    -- ========================================================================
    -- CANONICAL PHONE — VALIDATED
    --
    -- Pregnancy-source phone has priority only when it is valid.
    -- Otherwise use a valid matched outcome-source phone.
    -- ========================================================================

    -- Canonical validated phone. This replaces the old meaning of
    -- no_hp_clean in the final table. Invalid values become NULL; if the
    -- pregnancy-source phone is invalid, a valid matched outcome-source phone
    -- can still be used.
    COALESCE(
      CASE
        WHEN is_valid_mobile_phone(p.no_hp_clean)
          THEN normalize_mobile_phone(p.no_hp_clean)
      END,
      o.outcome_phone_pick.no_hp_clean
    ) AS no_hp_clean,

    -- Backward-compatible alias used by downstream queries.
    COALESCE(
      CASE
        WHEN is_valid_mobile_phone(p.no_hp_clean)
          THEN normalize_mobile_phone(p.no_hp_clean)
      END,
      o.outcome_phone_pick.no_hp_clean
    ) AS no_hp_final,

    CASE
      WHEN is_valid_mobile_phone(p.no_hp_clean)
        THEN p.phone_source

      WHEN o.outcome_phone_pick.no_hp_clean IS NOT NULL
        THEN o.outcome_phone_pick.source_system
    END AS phone_source_final,


    o.maternal_outcome_pick.value
      AS maternal_outcome_final,

    o.maternal_outcome_pick.source_system
      AS maternal_outcome_source,

    o.delivery_mode_pick.value
      AS delivery_mode_final,

    o.delivery_mode_pick.source_system
      AS delivery_mode_source,

    o.delivery_facility_pick.value
      AS delivery_facility_final,

    o.delivery_facility_pick.source_system
      AS delivery_facility_source

  FROM spine p

  LEFT JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_usg_dating_v3_3` u
    USING (pregnancy_episode_id)

  LEFT JOIN outcome_agg o
    USING (pregnancy_episode_id)
),


-- ============================================================================
-- SOURCE OVERLAP
-- ============================================================================
with_source_overlap AS (
  SELECT
    *,

    (
      CAST(has_delivery_sigizi AS INT64)
      + CAST(has_delivery_epus AS INT64)
      + CAST(has_delivery_simrs AS INT64)
      + CAST(has_delivery_kobo_inc AS INT64)
      + CAST(has_delivery_neonatal AS INT64)
      + CAST(has_delivery_inc_report AS INT64)
    ) AS delivery_source_count,

    ARRAY_TO_STRING(
      ARRAY(
        SELECT src
        FROM UNNEST([
          IF(has_delivery_sigizi, 'SIGIZI', NULL),
          IF(has_delivery_epus, 'EPUS', NULL),
          IF(has_delivery_simrs, 'SIMRS', NULL),
          IF(has_delivery_kobo_inc, 'KOBO_INC', NULL),
          IF(has_delivery_neonatal, 'NEONATAL_OUTCOME', NULL),
          IF(has_delivery_inc_report, 'INC_REPORT_TRACKER', NULL)
        ]) AS src
        WHERE src IS NOT NULL
      ),
      ' + '
    ) AS delivery_source_combination,

    delivery_date_distinct_count > 1
      AS delivery_date_conflict_flag

  FROM joined
),


-- ============================================================================
-- EXPECTED DELIVERY DATE + PHONE STATUS
-- ============================================================================
with_expected_delivery AS (
  SELECT
    *,

    -- Operational canonical HPL:
    --   1) Early USG GA-based dating
    --   2) Recorded HPL
    --   3) HPHT + 280 days
    --   4) Later USG fallback
    CASE
      WHEN hpl_from_usg_ga_date IS NOT NULL
       AND dating_usg_ga_weeks BETWEEN 4 AND 14
        THEN hpl_from_usg_ga_date

      WHEN hpl_recorded_date IS NOT NULL
        THEN hpl_recorded_date

      WHEN hpl_from_hpht_date IS NOT NULL
        THEN hpl_from_hpht_date

      WHEN hpl_from_usg_date IS NOT NULL
        THEN hpl_from_usg_date
    END AS expected_delivery_date,

    CASE
      WHEN hpl_from_usg_ga_date IS NOT NULL
       AND dating_usg_ga_weeks BETWEEN 4 AND 14
        THEN 'EARLY_USG_GA_LE_14W'

      WHEN hpl_recorded_date IS NOT NULL
        THEN CONCAT(
          'RECORDED_HPL_',
          COALESCE(
            hpl_recorded_source,
            'UNKNOWN'
          )
        )

      WHEN hpl_from_hpht_date IS NOT NULL
        THEN CONCAT(
          'HPHT_PLUS_280D_',
          COALESCE(
            hpht_source,
            'UNKNOWN'
          )
        )

      WHEN hpl_from_usg_date IS NOT NULL
        THEN 'LATER_USG_FALLBACK'
    END AS expected_delivery_date_source,


    -- ========================================================================
    -- UPDATED HAS_PHONE LOGIC
    --
    -- no_hp_clean / no_hp_final are already validated above.
    -- ========================================================================

    no_hp_clean IS NOT NULL
      AS has_phone,


    -- QA label for the canonical phone state.
    CASE
      WHEN no_hp_clean IS NOT NULL
        THEN 'VALID_PHONE'

      WHEN NULLIF(TRIM(COALESCE(no_hp_raw_clean, '')), '') IS NULL
        THEN 'MISSING_PHONE'

      ELSE 'INVALID_OR_PLACEHOLDER_PHONE'
    END AS phone_quality_status,


    has_live_birth_evidence
      AND has_stillbirth_evidence
      AS live_still_mixed_evidence_flag,

    has_abortus_evidence
      AND (
        has_live_birth_evidence
        OR has_stillbirth_evidence
        OR actual_delivery_date IS NOT NULL
      )
      AS pregnancy_outcome_conflict_flag

  FROM with_source_overlap
),


-- ============================================================================
-- FINAL PREGNANCY OUTCOME
-- ============================================================================
with_outcome AS (
  SELECT
    *,

    CASE
      WHEN has_live_birth_evidence
       AND has_stillbirth_evidence
        THEN 'CAMPURAN LAHIR HIDUP + LAHIR MATI'

      WHEN has_abortus_evidence
       AND NOT has_live_birth_evidence
       AND NOT has_stillbirth_evidence
       AND actual_delivery_date IS NULL
        THEN 'ABORTUS'

      WHEN has_stillbirth_evidence
       AND NOT has_live_birth_evidence
        THEN 'LAHIR MATI'

      WHEN has_live_birth_evidence
        THEN 'LAHIR HIDUP'

      WHEN actual_delivery_date IS NOT NULL
        THEN 'DELIVERY DITEMUKAN - LUARAN BELUM JELAS'

      ELSE NULL
    END AS pregnancy_outcome_final

  FROM with_expected_delivery
),


-- ============================================================================
-- MONITORING ELIGIBILITY
-- ============================================================================
with_monitoring AS (
  SELECT
    *,

    expected_delivery_date BETWEEN
      plausible_pregnancy_floor
      AND DATE_ADD(
        CURRENT_DATE('Asia/Makassar'),
        INTERVAL 300 DAY
      )
      AS pregnancy_date_valid_flag,

    expected_delivery_date BETWEEN
      monitoring_start_date
      AND DATE_ADD(
        CURRENT_DATE('Asia/Makassar'),
        INTERVAL 300 DAY
      )
      AS monitoring_eligible_flag

  FROM with_outcome
),


-- ============================================================================
-- CORE METRICS
-- ============================================================================
metrics AS (
  SELECT
    *,

    (
      pregnancy_date_valid_flag
      AND expected_delivery_date IS NOT NULL
    ) AS due_cohort_flag,

    (
      monitoring_eligible_flag
      AND NOT (
        pregnancy_outcome_final = 'ABORTUS'
        AND abortion_date IS NOT NULL
        AND abortion_date < expected_delivery_date
      )
    ) AS expected_to_deliver_flag,

    (
      monitoring_eligible_flag
      AND expected_delivery_date <= CURRENT_DATE('Asia/Makassar')
      AND NOT (
        pregnancy_outcome_final = 'ABORTUS'
        AND abortion_date IS NOT NULL
        AND abortion_date < expected_delivery_date
      )
    ) AS expected_to_have_delivered_by_today_flag,

    actual_delivery_date IS NOT NULL
      AS delivery_found_flag,

    pregnancy_outcome_final IS NOT NULL
      AS outcome_found_flag,

    (
      monitoring_eligible_flag
      AND expected_delivery_date > CURRENT_DATE('Asia/Makassar')
      AND actual_delivery_date IS NULL
      AND pregnancy_outcome_final IS NULL
    ) AS currently_still_pregnant_flag,

    (
      monitoring_eligible_flag
      AND expected_delivery_date <= CURRENT_DATE('Asia/Makassar')
      AND actual_delivery_date IS NULL
      AND pregnancy_outcome_final IS NULL
    ) AS missing_birth_flag,

    CASE
      WHEN actual_delivery_date IS NOT NULL
       AND hpl_recorded_date IS NOT NULL
      THEN DATE_DIFF(
        actual_delivery_date,
        hpl_recorded_date,
        DAY
      )
    END AS delivery_minus_recorded_hpl_days,

    CASE
      WHEN actual_delivery_date IS NOT NULL
       AND hpl_from_hpht_date IS NOT NULL
      THEN DATE_DIFF(
        actual_delivery_date,
        hpl_from_hpht_date,
        DAY
      )
    END AS delivery_minus_hpht_hpl_days,

    CASE
      WHEN actual_delivery_date IS NOT NULL
       AND hpl_from_usg_ga_date IS NOT NULL
      THEN DATE_DIFF(
        actual_delivery_date,
        hpl_from_usg_ga_date,
        DAY
      )
    END AS delivery_minus_usg_ga_hpl_days,

    CASE
      WHEN actual_delivery_date IS NOT NULL
       AND usg_recorded_hpl_date IS NOT NULL
      THEN DATE_DIFF(
        actual_delivery_date,
        usg_recorded_hpl_date,
        DAY
      )
    END AS delivery_minus_usg_recorded_hpl_days,

    CASE
      WHEN actual_delivery_date IS NOT NULL
       AND expected_delivery_date IS NOT NULL
      THEN DATE_DIFF(
        actual_delivery_date,
        expected_delivery_date,
        DAY
      )
    END AS delivery_minus_canonical_hpl_days,

    CASE
      WHEN hpl_from_usg_ga_date IS NOT NULL
       AND hpl_from_hpht_date IS NOT NULL
      THEN DATE_DIFF(
        hpl_from_usg_ga_date,
        hpl_from_hpht_date,
        DAY
      )
    END AS usg_ga_minus_hpht_hpl_days

  FROM with_monitoring
),


-- ============================================================================
-- FINAL DERIVED FIELDS
-- ============================================================================
final AS (
  SELECT
    *,

    DATE_TRUNC(
      expected_delivery_date,
      MONTH
    ) AS expected_delivery_month,

    DATE_TRUNC(
      actual_delivery_date,
      MONTH
    ) AS actual_delivery_month,

    ABS(
      delivery_minus_recorded_hpl_days
    ) AS abs_delivery_minus_recorded_hpl_days,

    ABS(
      delivery_minus_hpht_hpl_days
    ) AS abs_delivery_minus_hpht_hpl_days,

    ABS(
      delivery_minus_usg_ga_hpl_days
    ) AS abs_delivery_minus_usg_ga_hpl_days,

    ABS(
      delivery_minus_usg_recorded_hpl_days
    ) AS abs_delivery_minus_usg_recorded_hpl_days,

    ABS(
      delivery_minus_canonical_hpl_days
    ) AS abs_delivery_minus_canonical_hpl_days,

    ABS(
      usg_ga_minus_hpht_hpl_days
    ) AS abs_usg_ga_minus_hpht_hpl_days,


    -- ========================================================================
    -- UPDATED MISSING-BIRTH PHONE FLAGS
    -- ========================================================================

    missing_birth_flag
      AND has_phone
      AS missing_birth_has_phone_flag,

    missing_birth_flag
      AND NOT has_phone
      AS missing_birth_no_phone_flag,


    CASE
      WHEN pregnancy_outcome_final = 'ABORTUS'
        THEN 'ABORTUS'

      WHEN pregnancy_outcome_final
        = 'CAMPURAN LAHIR HIDUP + LAHIR MATI'
        THEN 'OUTCOME CAMPURAN - LIVE + STILLBIRTH'

      WHEN pregnancy_outcome_final = 'LAHIR MATI'
        THEN 'LAHIR MATI'

      WHEN pregnancy_outcome_final = 'LAHIR HIDUP'
        THEN 'LAHIR HIDUP'

      WHEN pregnancy_outcome_final
        = 'DELIVERY DITEMUKAN - LUARAN BELUM JELAS'
        THEN 'DELIVERY DITEMUKAN - LUARAN BELUM JELAS'

      WHEN NOT pregnancy_date_valid_flag
        THEN 'EXCLUDED - INVALID PREGNANCY DATE'

      WHEN NOT monitoring_eligible_flag
        THEN 'OUTSIDE OPERATIONAL MONITORING WINDOW'

      WHEN missing_birth_flag
       AND has_phone
        THEN 'MISSING BIRTH - >=40 MINGGU - ADA NO HP'

      WHEN missing_birth_flag
       AND NOT has_phone
        THEN 'MISSING BIRTH - >=40 MINGGU - TANPA NO HP'

      WHEN currently_still_pregnant_flag
        THEN 'MASIH HAMIL - BELUM 40 MINGGU'

      ELSE 'STATUS BELUM DAPAT DITENTUKAN'
    END AS pregnancy_tracking_status,


    CASE
      WHEN actual_delivery_date IS NULL
        OR expected_delivery_date IS NULL
        THEN NULL

      WHEN DATE_TRUNC(
        actual_delivery_date,
        MONTH
      ) < DATE_TRUNC(
        expected_delivery_date,
        MONTH
      )
        THEN 'DELIVERED BEFORE EXPECTED MONTH'

      WHEN DATE_TRUNC(
        actual_delivery_date,
        MONTH
      ) = DATE_TRUNC(
        expected_delivery_date,
        MONTH
      )
        THEN 'DELIVERED WITHIN EXPECTED MONTH'

      ELSE 'DELIVERED AFTER EXPECTED MONTH'
    END AS delivery_timing_vs_expected_month,


    CASE
      WHEN delivery_minus_canonical_hpl_days IS NULL
        THEN NULL

      WHEN delivery_minus_canonical_hpl_days < -14
        THEN '>14 DAYS BEFORE HPL'

      WHEN delivery_minus_canonical_hpl_days BETWEEN -14 AND -8
        THEN '8-14 DAYS BEFORE HPL'

      WHEN delivery_minus_canonical_hpl_days BETWEEN -7 AND 7
        THEN 'WITHIN +/-7 DAYS OF HPL'

      WHEN delivery_minus_canonical_hpl_days BETWEEN 8 AND 14
        THEN '8-14 DAYS AFTER HPL'

      ELSE '>14 DAYS AFTER HPL'
    END AS delivery_vs_hpl_category,


    CASE
      WHEN usg_ga_minus_hpht_hpl_days IS NULL
        THEN NULL

      WHEN ABS(
        usg_ga_minus_hpht_hpl_days
      ) <= 3
        THEN 'SAME / +/-3 DAYS'

      WHEN ABS(
        usg_ga_minus_hpht_hpl_days
      ) <= 7
        THEN '4-7 DAYS DIFFERENCE'

      WHEN ABS(
        usg_ga_minus_hpht_hpl_days
      ) <= 14
        THEN '8-14 DAYS DIFFERENCE'

      ELSE '>14 DAYS DIFFERENCE'
    END AS usg_vs_hpht_hpl_difference_category,


    CASE
      WHEN missing_birth_flag
      THEN GREATEST(
        DATE_DIFF(
          CURRENT_DATE('Asia/Makassar'),
          expected_delivery_date,
          DAY
        ),
        0
      )
    END AS missing_birth_days_overdue,

    monitoring_start_date
      AS monitoring_start_date,

    CURRENT_DATE('Asia/Makassar')
      AS cohort_refresh_date

  FROM metrics
)

SELECT *
FROM final;