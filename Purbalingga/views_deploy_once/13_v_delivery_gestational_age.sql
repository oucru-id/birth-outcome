-- ============================================================================
-- PURBALINGGA — GESTATIONAL AGE AT DELIVERY
-- Validated logic: canonical recorded GA first, HPHT-derived fallback.
-- ============================================================================

CREATE OR REPLACE VIEW
  `stellar-orb-451904-d9.kohort_bumil_v2.v_delivery_gestational_age`
AS

WITH base AS (
  SELECT
    d.*,
    p.hpht_date AS pregnancy_hpht_date
  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.v_delivery_monitoring_integrated` d
  LEFT JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_monitoring_integrated_v3_3` p
    USING (pregnancy_episode_id)
),

ga_inputs AS (
  SELECT
    *,
    CASE
      WHEN representative_gestational_age_weeks BETWEEN 18 AND 46
      THEN CAST(representative_gestational_age_weeks AS FLOAT64)
    END AS recorded_ga_weeks,

    CASE
      WHEN pregnancy_hpht_date IS NOT NULL
       AND delivery_date IS NOT NULL
       AND DATE_DIFF(delivery_date, pregnancy_hpht_date, DAY) BETWEEN 126 AND 322
      THEN SAFE_DIVIDE(
        DATE_DIFF(delivery_date, pregnancy_hpht_date, DAY),
        7.0
      )
    END AS derived_ga_weeks
  FROM base
),

ga_final AS (
  SELECT
    *,
    COALESCE(recorded_ga_weeks, derived_ga_weeks) AS ga_final_weeks,

    CASE
      WHEN recorded_ga_weeks IS NOT NULL THEN 'RECORDED'
      WHEN derived_ga_weeks IS NOT NULL THEN 'DERIVED_HPHT'
      ELSE 'UNKNOWN'
    END AS ga_source
  FROM ga_inputs
)

SELECT
  *,

  CAST(FLOOR(ga_final_weeks) AS INT64) AS ga_completed_weeks,

  CASE
    WHEN ga_final_weeks IS NULL THEN 'Unknown'
    WHEN ga_final_weeks < 37 THEN 'Preterm (<37 weeks)'
    WHEN ga_final_weeks < 42 THEN 'Term (37–41 weeks)'
    ELSE 'Post-term (≥42 weeks)'
  END AS ga_category,

  CASE
    WHEN ga_final_weeks < 37 THEN 1
    WHEN ga_final_weeks >= 37 AND ga_final_weeks < 42 THEN 2
    WHEN ga_final_weeks >= 42 THEN 3
    ELSE 4
  END AS ga_category_order,

  1 AS delivery_count,
  CAST(recorded_ga_weeks IS NOT NULL AS INT64) AS ga_recorded_count,
  CAST(recorded_ga_weeks IS NULL AND derived_ga_weeks IS NOT NULL AS INT64)
    AS ga_derived_count,
  CAST(ga_final_weeks IS NOT NULL AS INT64) AS ga_known_count,
  CAST(ga_final_weeks IS NULL AS INT64) AS ga_unknown_count,
  CAST(ga_final_weeks IS NOT NULL AND ga_final_weeks < 37 AS INT64)
    AS preterm_count,
  CAST(ga_final_weeks >= 37 AND ga_final_weeks < 42 AS INT64)
    AS term_count,
  CAST(ga_final_weeks >= 42 AS INT64) AS postterm_count

FROM ga_final;
