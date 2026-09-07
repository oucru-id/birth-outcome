-- ============================================================================
-- PURBALINGGA — FINAL DELIVERY-LEVEL BIRTH WEIGHT VIEW
--
-- Grain: 1 row = 1 FINAL post-ANC canonical dated delivery.
-- Current metric remains DELIVERY-level representative birth weight, not
-- a baby-level multiple-birth denominator.
-- ============================================================================

CREATE OR REPLACE VIEW
  `stellar-orb-451904-d9.kohort_bumil_v2.v_delivery_birth_weight`
AS

WITH delivery_base AS (
  SELECT d.*
  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.v_delivery_monitoring_integrated` d
),

weight_source_records AS (
  SELECT
    d.delivery_event_id,
    s.birth_weight_grams,
    s.source_system,
    s.source_table,
    s.source_priority,
    s.source_record_instance_key
  FROM delivery_base d
  CROSS JOIN UNNEST(d.source_record_instance_keys)
    AS source_record_instance_key
  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_source_records_v3_3` s
    USING (source_record_instance_key)
  WHERE s.birth_weight_grams IS NOT NULL
),

weight_support AS (
  SELECT
    delivery_event_id,
    birth_weight_grams,
    COUNT(*) AS supporting_records,
    COUNT(DISTINCT source_system) AS supporting_source_systems,
    MIN(source_priority) AS best_source_priority
  FROM weight_source_records
  GROUP BY delivery_event_id, birth_weight_grams
),

weight_ranked AS (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY delivery_event_id
      ORDER BY
        supporting_source_systems DESC,
        supporting_records DESC,
        best_source_priority ASC,
        birth_weight_grams
    ) AS weight_rank
  FROM weight_support
),

weight_summary AS (
  SELECT
    delivery_event_id,
    COUNT(*) AS distinct_birth_weight_value_count,
    ARRAY_AGG(birth_weight_grams ORDER BY birth_weight_grams)
      AS birth_weight_values_grams,
    MAX(IF(weight_rank = 1, birth_weight_grams, NULL))
      AS best_supported_birth_weight_grams
  FROM weight_ranked
  GROUP BY delivery_event_id
),

final_weight AS (
  SELECT
    d.*,
    COALESCE(
      d.representative_birth_weight_grams,
      w.best_supported_birth_weight_grams
    ) AS birth_weight_grams,

    COALESCE(w.distinct_birth_weight_value_count, 0)
      AS distinct_birth_weight_value_count,

    COALESCE(w.birth_weight_values_grams, ARRAY<INT64>[])
      AS birth_weight_values_grams,

    COALESCE(w.distinct_birth_weight_value_count, 0) > 1
      AS birth_weight_conflict_flag

  FROM delivery_base d
  LEFT JOIN weight_summary w USING (delivery_event_id)
),

classified AS (
  SELECT
    *,
    CASE
      WHEN birth_weight_grams IS NULL THEN 'Unknown'
      WHEN birth_weight_grams < 1500 THEN '<1500 g'
      WHEN birth_weight_grams < 2500 THEN '1500–2499 g'
      WHEN birth_weight_grams < 4000 THEN '2500–3999 g'
      ELSE '≥4000 g'
    END AS birth_weight_category,

    CASE
      WHEN birth_weight_grams < 1500 THEN 1
      WHEN birth_weight_grams >= 1500 AND birth_weight_grams < 2500 THEN 2
      WHEN birth_weight_grams >= 2500 AND birth_weight_grams < 4000 THEN 3
      WHEN birth_weight_grams >= 4000 THEN 4
      ELSE 5
    END AS birth_weight_category_order
  FROM final_weight
)

SELECT
  *,
  1 AS delivery_count,
  CAST(birth_weight_grams IS NOT NULL AS INT64)
    AS birth_weight_known_count,
  CAST(birth_weight_grams IS NULL AS INT64)
    AS birth_weight_unknown_count,
  CAST(birth_weight_grams IS NOT NULL AND birth_weight_grams < 2500 AS INT64)
    AS lbw_count,
  CAST(birth_weight_grams IS NOT NULL AND birth_weight_grams < 1500 AS INT64)
    AS vlbw_count,
  CAST(birth_weight_grams >= 4000 AS INT64)
    AS birth_weight_ge_4000_count,
  CAST(birth_weight_conflict_flag AS INT64)
    AS birth_weight_conflict_count,

  CASE
    WHEN birth_weight_grams IS NOT NULL
    THEN DIV(birth_weight_grams, 250) * 250
  END AS birth_weight_250g_bucket

FROM classified;
