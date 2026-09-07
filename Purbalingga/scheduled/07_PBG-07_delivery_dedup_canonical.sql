-- ============================================================================
-- PURBALINGGA
-- 05_BUILD_CANONICAL_DELIVERY_EVENTS_V3_3
--
-- INPUT:
--   t_delivery_source_records_v3_3
--
-- OUTPUT:
--   t_delivery_event_canonical_v3_3
--
-- GRAIN:
--   ONE ROW = ONE CANONICAL DATED DELIVERY EVENT
--
-- EXCLUDED FROM THIS STAGE:
--   ABORTION
--   CONFLICT_DELIVERY_ABORTION
--   DELIVERY_DATE_UNKNOWN
--
-- These are handled later during pregnancy outcome integration.
-- ============================================================================


DECLARE delivery_date_tolerance_days INT64 DEFAULT 3;
DECLARE pregnancy_date_tolerance_days INT64 DEFAULT 14;


-- ============================================================================
-- DROP INTERMEDIATE / FINAL TABLES
-- ============================================================================

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_dedup_base_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_trusted_nik_date_map_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_trusted_nik_cluster_map_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_trusted_nik_clusters_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_nontrusted_to_nik_candidates_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_nontrusted_to_nik_chosen_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_residual_date_map_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_residual_cluster_map_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_member_map_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_v3_3`;


-- ############################################################################
-- STAGE 05A
-- BASE DATED DELIVERY RECORDS
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_dedup_base_v3_3`

PARTITION BY delivery_date

CLUSTER BY
  nik_clean,
  nama_norm,
  delivery_date

AS

SELECT

  *,

  (
      CASE WHEN trusted_nik_flag THEN 50 ELSE 0 END
    + CASE WHEN has_name THEN 15 ELSE 0 END
    + CASE WHEN has_dob THEN 10 ELSE 0 END
    + CASE WHEN no_hp_clean IS NOT NULL THEN 8 ELSE 0 END
    + CASE WHEN has_hpht THEN 7 ELSE 0 END
    + CASE WHEN has_hpl THEN 7 ELSE 0 END
    + CASE WHEN has_known_outcome THEN 5 ELSE 0 END
    + CASE WHEN has_gestational_age THEN 3 ELSE 0 END
    + CASE WHEN has_birth_weight THEN 3 ELSE 0 END

    + CASE source_priority
        WHEN 1 THEN 20
        WHEN 2 THEN 18
        WHEN 3 THEN 16
        WHEN 4 THEN 14
        WHEN 5 THEN 12
        WHEN 6 THEN 10
        WHEN 7 THEN 8
        WHEN 8 THEN 6
        ELSE 0
      END
  ) AS delivery_record_quality_score

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_source_records_v3_3`

WHERE
  event_type = 'DELIVERY'
  AND delivery_date IS NOT NULL;


-- ############################################################################
-- STAGE 05B
-- DISTINCT DELIVERY DATES FOR EACH TRUSTED NIK
--
-- We cluster consecutive delivery dates when the gap is <=3 days.
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_trusted_nik_date_map_v3_3`

CLUSTER BY nik_clean

AS

WITH dates AS (

  SELECT DISTINCT
    nik_clean,
    delivery_date

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_dedup_base_v3_3`

  WHERE trusted_nik_flag = TRUE

),

lagged AS (

  SELECT
    *,

    LAG(delivery_date) OVER (
      PARTITION BY nik_clean
      ORDER BY delivery_date
    ) AS previous_delivery_date

  FROM dates

),

marked AS (

  SELECT
    *,

    CASE
      WHEN previous_delivery_date IS NULL
        THEN 1

      WHEN DATE_DIFF(
        delivery_date,
        previous_delivery_date,
        DAY
      ) > delivery_date_tolerance_days
        THEN 1

      ELSE 0
    END AS new_cluster_flag

  FROM lagged
),

numbered AS (

  SELECT
    *,

    SUM(new_cluster_flag) OVER (
      PARTITION BY nik_clean
      ORDER BY delivery_date
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS nik_cluster_number

  FROM marked
)

SELECT *
FROM numbered;


-- ############################################################################
-- STAGE 05C
-- TRUSTED NIK SOURCE-RECORD -> CLUSTER MAP
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_trusted_nik_cluster_map_v3_3`

CLUSTER BY
  trusted_nik_cluster_id,
  source_record_instance_key

AS

WITH joined AS (

  SELECT
    b.source_record_instance_key,
    b.nik_clean,
    b.delivery_date,
    d.nik_cluster_number

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_dedup_base_v3_3` b

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_trusted_nik_date_map_v3_3` d

    USING (
      nik_clean,
      delivery_date
    )

  WHERE b.trusted_nik_flag = TRUE

),

cluster_start AS (

  SELECT
    nik_clean,
    nik_cluster_number,

    MIN(delivery_date)
      AS cluster_start_date,

    MAX(delivery_date)
      AS cluster_end_date

  FROM joined

  GROUP BY
    nik_clean,
    nik_cluster_number
)

SELECT
  j.source_record_instance_key,

  CONCAT(
    'NIK|',
    j.nik_clean,
    '|',
    CAST(c.cluster_start_date AS STRING)
  ) AS trusted_nik_cluster_id,

  j.nik_clean,

  j.nik_cluster_number,

  c.cluster_start_date,

  c.cluster_end_date,

  DATE_DIFF(
    c.cluster_end_date,
    c.cluster_start_date,
    DAY
  ) AS cluster_date_span_days

FROM joined j

JOIN cluster_start c
  USING (
    nik_clean,
    nik_cluster_number
  );


-- ############################################################################
-- STAGE 05D
-- TRUSTED NIK CLUSTER SUMMARY
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_trusted_nik_clusters_v3_3`

CLUSTER BY trusted_nik_cluster_id

AS

SELECT

  m.trusted_nik_cluster_id,

  ANY_VALUE(m.nik_clean)
    AS trusted_nik,

  MIN(b.delivery_date)
    AS min_delivery_date,

  MAX(b.delivery_date)
    AS max_delivery_date,

  DATE_DIFF(
    MAX(b.delivery_date),
    MIN(b.delivery_date),
    DAY
  ) AS delivery_date_span_days,

  COUNT(*) AS trusted_member_records,

  COUNT(DISTINCT b.source_system)
    AS trusted_source_system_count,

  MAX(b.delivery_record_quality_score)
    AS max_quality_score

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_trusted_nik_cluster_map_v3_3` m

JOIN
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_dedup_base_v3_3` b

  USING (source_record_instance_key)

GROUP BY
  m.trusted_nik_cluster_id;


-- ############################################################################
-- STAGE 05E
-- NON-TRUSTED RECORDS -> TRUSTED NIK CLUSTER CANDIDATES
--
-- This attaches records without a trusted NIK to an already-established
-- maternal delivery event.
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_nontrusted_to_nik_candidates_v3_3`

CLUSTER BY
  source_record_instance_key,
  trusted_nik_cluster_id

AS

WITH candidates AS (

  SELECT

    u.source_record_instance_key,

    tm.trusted_nik_cluster_id,

    ABS(
      DATE_DIFF(
        u.delivery_date,
        t.delivery_date,
        DAY
      )
    ) AS delivery_date_difference_days,


    CASE

      -- ----------------------------------------------------------------------
      -- NAME + DOB
      -- ----------------------------------------------------------------------

      WHEN
        u.nama_norm IS NOT NULL
        AND t.nama_norm IS NOT NULL
        AND u.nama_norm = t.nama_norm

        AND u.tanggal_lahir_ibu IS NOT NULL
        AND t.tanggal_lahir_ibu IS NOT NULL
        AND u.tanggal_lahir_ibu = t.tanggal_lahir_ibu

        THEN 'NAME+DOB+DELIVERY_3D'


      -- ----------------------------------------------------------------------
      -- NAME + PHONE
      -- ----------------------------------------------------------------------

      WHEN
        u.nama_norm IS NOT NULL
        AND t.nama_norm IS NOT NULL
        AND u.nama_norm = t.nama_norm

        AND u.no_hp_clean IS NOT NULL
        AND t.no_hp_clean IS NOT NULL
        AND u.no_hp_clean = t.no_hp_clean

        THEN 'NAME+PHONE+DELIVERY_3D'


      -- ----------------------------------------------------------------------
      -- NAME + HPHT
      -- ----------------------------------------------------------------------

      WHEN
        u.nama_norm IS NOT NULL
        AND t.nama_norm IS NOT NULL
        AND u.nama_norm = t.nama_norm

        AND u.hpht_date IS NOT NULL
        AND t.hpht_date IS NOT NULL

        AND ABS(
          DATE_DIFF(
            u.hpht_date,
            t.hpht_date,
            DAY
          )
        ) <= pregnancy_date_tolerance_days

        THEN 'NAME+HPHT_14D+DELIVERY_3D'


      -- ----------------------------------------------------------------------
      -- NAME + HPL
      -- ----------------------------------------------------------------------

      WHEN
        u.nama_norm IS NOT NULL
        AND t.nama_norm IS NOT NULL
        AND u.nama_norm = t.nama_norm

        AND u.hpl_date IS NOT NULL
        AND t.hpl_date IS NOT NULL

        AND ABS(
          DATE_DIFF(
            u.hpl_date,
            t.hpl_date,
            DAY
          )
        ) <= pregnancy_date_tolerance_days

        THEN 'NAME+HPL_14D+DELIVERY_3D'


      -- ----------------------------------------------------------------------
      -- SAME NAME + EXACT DELIVERY DATE + SAME PUSKESMAS
      -- ----------------------------------------------------------------------

      WHEN
        u.nama_norm IS NOT NULL
        AND t.nama_norm IS NOT NULL
        AND u.nama_norm = t.nama_norm

        AND u.delivery_date = t.delivery_date

        AND u.puskesmas_norm IS NOT NULL
        AND t.puskesmas_norm IS NOT NULL
        AND u.puskesmas_norm = t.puskesmas_norm

        THEN 'NAME+DATE+PUSKESMAS'


    END AS attachment_method

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_dedup_base_v3_3` u

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_trusted_nik_cluster_map_v3_3` tm
    ON TRUE

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_dedup_base_v3_3` t
    ON t.source_record_instance_key
       = tm.source_record_instance_key

  WHERE
    u.trusted_nik_flag = FALSE

    AND ABS(
      DATE_DIFF(
        u.delivery_date,
        t.delivery_date,
        DAY
      )
    ) <= delivery_date_tolerance_days

    AND u.nama_norm IS NOT NULL
    AND t.nama_norm IS NOT NULL
    AND u.nama_norm = t.nama_norm
),

classified AS (

  SELECT
    *,

    CASE attachment_method
      WHEN 'NAME+DOB+DELIVERY_3D'
        THEN 1

      WHEN 'NAME+PHONE+DELIVERY_3D'
        THEN 2

      WHEN 'NAME+HPHT_14D+DELIVERY_3D'
        THEN 3

      WHEN 'NAME+HPL_14D+DELIVERY_3D'
        THEN 4

      WHEN 'NAME+DATE+PUSKESMAS'
        THEN 5
    END AS attachment_priority

  FROM candidates

  WHERE attachment_method IS NOT NULL
)

SELECT
  source_record_instance_key,
  trusted_nik_cluster_id,

  MIN(attachment_priority)
    AS attachment_priority,

  ARRAY_AGG(
    attachment_method
    ORDER BY attachment_priority
    LIMIT 1
  )[SAFE_OFFSET(0)] AS attachment_method,

  MIN(delivery_date_difference_days)
    AS delivery_date_difference_days

FROM classified

GROUP BY
  source_record_instance_key,
  trusted_nik_cluster_id;


-- ############################################################################
-- STAGE 05F
-- CHOOSE UNIQUE BEST TRUSTED-NIK TARGET
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_nontrusted_to_nik_chosen_v3_3`

CLUSTER BY source_record_instance_key

AS

WITH ranked AS (

  SELECT
    c.*,

    tc.max_quality_score,

    DENSE_RANK() OVER (
      PARTITION BY c.source_record_instance_key

      ORDER BY
        c.attachment_priority,
        c.delivery_date_difference_days,
        tc.max_quality_score DESC,
        c.trusted_nik_cluster_id
    ) AS candidate_rank

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_nontrusted_to_nik_candidates_v3_3` c

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_trusted_nik_clusters_v3_3` tc

  USING (trusted_nik_cluster_id)
),

best AS (

  SELECT *

  FROM ranked

  WHERE candidate_rank = 1
),

unique_best AS (

  SELECT
    source_record_instance_key,

    COUNT(*) AS best_target_count,

    ANY_VALUE(trusted_nik_cluster_id)
      AS trusted_nik_cluster_id,

    ANY_VALUE(attachment_method)
      AS attachment_method,

    ANY_VALUE(attachment_priority)
      AS attachment_priority,

    ANY_VALUE(delivery_date_difference_days)
      AS delivery_date_difference_days

  FROM best

  GROUP BY source_record_instance_key
)

SELECT
  source_record_instance_key,

  trusted_nik_cluster_id,

  attachment_method,

  attachment_priority,

  delivery_date_difference_days

FROM unique_best

WHERE best_target_count = 1;


-- ############################################################################
-- STAGE 05G
-- RESIDUAL NON-TRUSTED RECORDS
--
-- These could not be attached confidently to a trusted NIK event.
-- Build conservative composite identity keys.
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_residual_date_map_v3_3`

CLUSTER BY residual_identity_key

AS

WITH residual AS (

  SELECT
    b.*,

    CASE

      WHEN b.nama_norm IS NOT NULL
       AND b.tanggal_lahir_ibu IS NOT NULL

        THEN CONCAT(
          'NAME_DOB|',
          b.nama_norm,
          '|',
          CAST(
            b.tanggal_lahir_ibu
            AS STRING
          )
        )


      WHEN b.nama_norm IS NOT NULL
       AND b.no_hp_clean IS NOT NULL
       AND LENGTH(b.no_hp_clean) >= 8

        THEN CONCAT(
          'NAME_PHONE|',
          b.nama_norm,
          '|',
          b.no_hp_clean
        )


      WHEN b.nama_norm IS NOT NULL
       AND b.hpht_date IS NOT NULL

        THEN CONCAT(
          'NAME_HPHT|',
          b.nama_norm,
          '|',
          CAST(
            b.hpht_date
            AS STRING
          )
        )


      WHEN b.nama_norm IS NOT NULL
       AND b.hpl_date IS NOT NULL

        THEN CONCAT(
          'NAME_HPL|',
          b.nama_norm,
          '|',
          CAST(
            b.hpl_date
            AS STRING
          )
        )


      WHEN b.nama_norm IS NOT NULL
       AND b.puskesmas_norm IS NOT NULL

        THEN CONCAT(
          'NAME_PKM|',
          b.nama_norm,
          '|',
          b.puskesmas_norm
        )


      ELSE CONCAT(
        'ROW|',
        b.source_record_instance_key
      )

    END AS residual_identity_key

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_dedup_base_v3_3` b

  LEFT JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_nontrusted_to_nik_chosen_v3_3` x

    USING (source_record_instance_key)

  WHERE
    b.trusted_nik_flag = FALSE
    AND x.source_record_instance_key IS NULL
),

dates AS (

  SELECT DISTINCT
    residual_identity_key,
    delivery_date

  FROM residual
),

lagged AS (

  SELECT
    *,

    LAG(delivery_date) OVER (
      PARTITION BY residual_identity_key
      ORDER BY delivery_date
    ) AS previous_delivery_date

  FROM dates
),

marked AS (

  SELECT
    *,

    CASE
      WHEN previous_delivery_date IS NULL
        THEN 1

      WHEN DATE_DIFF(
        delivery_date,
        previous_delivery_date,
        DAY
      ) > delivery_date_tolerance_days
        THEN 1

      ELSE 0
    END AS new_cluster_flag

  FROM lagged
)

SELECT
  *,

  SUM(new_cluster_flag) OVER (
    PARTITION BY residual_identity_key
    ORDER BY delivery_date
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS residual_cluster_number

FROM marked;


-- ############################################################################
-- STAGE 05H
-- RESIDUAL SOURCE RECORD -> CLUSTER MAP
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_residual_cluster_map_v3_3`

CLUSTER BY
  residual_cluster_id,
  source_record_instance_key

AS

WITH residual_records AS (

  SELECT
    b.source_record_instance_key,
    b.delivery_date,

    CASE

      WHEN b.nama_norm IS NOT NULL
       AND b.tanggal_lahir_ibu IS NOT NULL

        THEN CONCAT(
          'NAME_DOB|',
          b.nama_norm,
          '|',
          CAST(
            b.tanggal_lahir_ibu
            AS STRING
          )
        )


      WHEN b.nama_norm IS NOT NULL
       AND b.no_hp_clean IS NOT NULL
       AND LENGTH(b.no_hp_clean) >= 8

        THEN CONCAT(
          'NAME_PHONE|',
          b.nama_norm,
          '|',
          b.no_hp_clean
        )


      WHEN b.nama_norm IS NOT NULL
       AND b.hpht_date IS NOT NULL

        THEN CONCAT(
          'NAME_HPHT|',
          b.nama_norm,
          '|',
          CAST(
            b.hpht_date
            AS STRING
          )
        )


      WHEN b.nama_norm IS NOT NULL
       AND b.hpl_date IS NOT NULL

        THEN CONCAT(
          'NAME_HPL|',
          b.nama_norm,
          '|',
          CAST(
            b.hpl_date
            AS STRING
          )
        )


      WHEN b.nama_norm IS NOT NULL
       AND b.puskesmas_norm IS NOT NULL

        THEN CONCAT(
          'NAME_PKM|',
          b.nama_norm,
          '|',
          b.puskesmas_norm
        )


      ELSE CONCAT(
        'ROW|',
        b.source_record_instance_key
      )

    END AS residual_identity_key

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_dedup_base_v3_3` b

  LEFT JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_nontrusted_to_nik_chosen_v3_3` x

    USING (source_record_instance_key)

  WHERE
    b.trusted_nik_flag = FALSE
    AND x.source_record_instance_key IS NULL
),

joined AS (

  SELECT
    r.*,
    d.residual_cluster_number

  FROM residual_records r

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_residual_date_map_v3_3` d

  USING (
    residual_identity_key,
    delivery_date
  )
),

cluster_start AS (

  SELECT
    residual_identity_key,
    residual_cluster_number,

    MIN(delivery_date)
      AS cluster_start_date

  FROM joined

  GROUP BY
    residual_identity_key,
    residual_cluster_number
)

SELECT
  j.source_record_instance_key,

  CONCAT(
    'RESIDUAL|',
    TO_HEX(
      SHA256(
        CONCAT(
          j.residual_identity_key,
          '|',
          CAST(
            c.cluster_start_date
            AS STRING
          )
        )
      )
    )
  ) AS residual_cluster_id,

  j.residual_identity_key,

  j.residual_cluster_number,

  c.cluster_start_date

FROM joined j

JOIN cluster_start c

USING (
  residual_identity_key,
  residual_cluster_number
);


-- ############################################################################
-- STAGE 05I
-- MASTER MEMBER -> DELIVERY CLUSTER MAP
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_member_map_v3_3`

CLUSTER BY
  delivery_cluster_id,
  source_record_instance_key

AS

-- ============================================================================
-- 1. TRUSTED NIK MEMBERS
-- ============================================================================

SELECT

  m.source_record_instance_key,

  m.trusted_nik_cluster_id
    AS delivery_cluster_id,

  'TRUSTED_NIK_DATE_CHAIN_3D'
    AS delivery_dedup_method,

  'VERY_HIGH'
    AS delivery_dedup_confidence

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_trusted_nik_cluster_map_v3_3` m


UNION ALL


-- ============================================================================
-- 2. NON-TRUSTED RECORD ATTACHED TO TRUSTED NIK CLUSTER
-- ============================================================================

SELECT

  x.source_record_instance_key,

  x.trusted_nik_cluster_id
    AS delivery_cluster_id,

  CONCAT(
    'ATTACH_',
    x.attachment_method
  ) AS delivery_dedup_method,

  CASE
    WHEN x.attachment_priority IN (1,2)
      THEN 'HIGH'

    WHEN x.attachment_priority IN (3,4)
      THEN 'HIGH'

    ELSE 'MEDIUM'
  END AS delivery_dedup_confidence

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_nontrusted_to_nik_chosen_v3_3` x


UNION ALL


-- ============================================================================
-- 3. RESIDUAL CLUSTERS
-- ============================================================================

SELECT

  r.source_record_instance_key,

  r.residual_cluster_id
    AS delivery_cluster_id,

  CASE

    WHEN STARTS_WITH(
      r.residual_identity_key,
      'NAME_DOB|'
    )
      THEN 'RESIDUAL_NAME+DOB+DATE_3D'

    WHEN STARTS_WITH(
      r.residual_identity_key,
      'NAME_PHONE|'
    )
      THEN 'RESIDUAL_NAME+PHONE+DATE_3D'

    WHEN STARTS_WITH(
      r.residual_identity_key,
      'NAME_HPHT|'
    )
      THEN 'RESIDUAL_NAME+HPHT+DATE_3D'

    WHEN STARTS_WITH(
      r.residual_identity_key,
      'NAME_HPL|'
    )
      THEN 'RESIDUAL_NAME+HPL+DATE_3D'

    WHEN STARTS_WITH(
      r.residual_identity_key,
      'NAME_PKM|'
    )
      THEN 'RESIDUAL_NAME+PKM+DATE_3D'

    ELSE 'RESIDUAL_UNMATCHED_SINGLETON'

  END AS delivery_dedup_method,

  CASE

    WHEN STARTS_WITH(
      r.residual_identity_key,
      'NAME_DOB|'
    )
      THEN 'HIGH'

    WHEN STARTS_WITH(
      r.residual_identity_key,
      'NAME_PHONE|'
    )
      THEN 'HIGH'

    WHEN STARTS_WITH(
      r.residual_identity_key,
      'NAME_HPHT|'
    )
      THEN 'MEDIUM'

    WHEN STARTS_WITH(
      r.residual_identity_key,
      'NAME_HPL|'
    )
      THEN 'MEDIUM'

    WHEN STARTS_WITH(
      r.residual_identity_key,
      'NAME_PKM|'
    )
      THEN 'MEDIUM'

    ELSE 'LOW'

  END AS delivery_dedup_confidence

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_residual_cluster_map_v3_3` r;


-- ############################################################################
-- STAGE 05J
-- CANONICAL EVENT DATE
--
-- Date choice:
--   1. supported by most distinct source systems
--   2. then most source records
--   3. then best source priority
--   4. deterministic date tie-break
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_v3_3`

PARTITION BY delivery_date

CLUSTER BY
  nik_clean,
  delivery_date,
  delivery_event_id

AS

WITH members AS (

  SELECT

    m.delivery_cluster_id,

    m.delivery_dedup_method,

    m.delivery_dedup_confidence,

    b.*

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_member_map_v3_3` m

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_dedup_base_v3_3` b

  USING (source_record_instance_key)
),

date_votes AS (

  SELECT

    delivery_cluster_id,

    delivery_date,

    COUNT(*) AS records_supporting_date,

    COUNT(
      DISTINCT source_system
    ) AS systems_supporting_date,

    MIN(source_priority)
      AS best_source_priority,

    MAX(delivery_record_quality_score)
      AS best_quality_score

  FROM members

  GROUP BY
    delivery_cluster_id,
    delivery_date
),

ranked_dates AS (

  SELECT
    *,

    ROW_NUMBER() OVER (
      PARTITION BY delivery_cluster_id

      ORDER BY
        systems_supporting_date DESC,
        records_supporting_date DESC,
        best_source_priority ASC,
        best_quality_score DESC,
        delivery_date ASC
    ) AS date_rank

  FROM date_votes
),

canonical_dates AS (

  SELECT
    delivery_cluster_id,
    delivery_date AS canonical_delivery_date

  FROM ranked_dates

  WHERE date_rank = 1
),

group_stats AS (

  SELECT

    delivery_cluster_id,

    COUNT(*) AS source_record_count,

    COUNT(
      DISTINCT source_system
    ) AS source_system_count,

    COUNT(
      DISTINCT source_table
    ) AS source_table_count,

    MIN(delivery_date)
      AS min_source_delivery_date,

    MAX(delivery_date)
      AS max_source_delivery_date,

    DATE_DIFF(
      MAX(delivery_date),
      MIN(delivery_date),
      DAY
    ) AS delivery_date_span_days,


    COUNT(
      DISTINCT IF(
        trusted_nik_flag,
        nik_clean,
        NULL
      )
    ) AS trusted_nik_count,


    COUNT(
      DISTINCT nik_clean
    ) AS valid_nik_count,


    COUNT(
      DISTINCT nama_norm
    ) AS name_variant_count,


    COUNTIF(
      pregnancy_outcome_norm = 'LIVE_BIRTH'
    ) AS live_birth_evidence_count,


    COUNTIF(
      pregnancy_outcome_norm = 'STILLBIRTH'
    ) AS stillbirth_evidence_count,


    COUNTIF(
      pregnancy_outcome_norm = 'UNKNOWN'
    ) AS unknown_outcome_evidence_count,


    ARRAY_AGG(
      DISTINCT source_system
      ORDER BY source_system
    ) AS source_systems,


    ARRAY_AGG(
      DISTINCT source_table
      ORDER BY source_table
    ) AS source_tables,


    ARRAY_AGG(
      DISTINCT source_record_instance_key
      ORDER BY source_record_instance_key
    ) AS source_record_instance_keys,


    ARRAY_AGG(
      DISTINCT delivery_dedup_method
      ORDER BY delivery_dedup_method
    ) AS delivery_dedup_methods,


    ARRAY_AGG(
      DISTINCT gestational_age_weeks
      IGNORE NULLS
      ORDER BY gestational_age_weeks
    ) AS gestational_age_values,


    ARRAY_AGG(
      DISTINCT birth_weight_grams
      IGNORE NULLS
      ORDER BY birth_weight_grams
    ) AS birth_weight_values_grams


  FROM members

  GROUP BY delivery_cluster_id
),

picks AS (

  SELECT

    delivery_cluster_id,


    ARRAY_AGG(
      STRUCT(
        nik_clean AS value,
        trusted_nik_flag AS trusted,
        delivery_record_quality_score AS quality
      )

      ORDER BY
        trusted_nik_flag DESC,
        nik_clean IS NULL,
        delivery_record_quality_score DESC,
        source_priority ASC,
        source_record_instance_key

      LIMIT 1
    )[SAFE_OFFSET(0)] AS nik_pick,


    ARRAY_AGG(
      STRUCT(
        nama_ibu AS value,
        nama_norm AS value_norm,
        nama_core_norm AS value_core,
        delivery_record_quality_score AS quality
      )

      ORDER BY
        nama_norm IS NULL,
        delivery_record_quality_score DESC,
        source_priority ASC,
        source_record_instance_key

      LIMIT 1
    )[SAFE_OFFSET(0)] AS name_pick,


    ARRAY_AGG(
      STRUCT(
        tanggal_lahir_ibu AS value,
        delivery_record_quality_score AS quality
      )

      ORDER BY
        tanggal_lahir_ibu IS NULL,
        delivery_record_quality_score DESC,
        source_priority ASC,
        source_record_instance_key

      LIMIT 1
    )[SAFE_OFFSET(0)] AS dob_pick,


    ARRAY_AGG(
      STRUCT(
        no_hp_clean AS value,
        delivery_record_quality_score AS quality
      )

      ORDER BY
        no_hp_clean IS NULL,
        LENGTH(
          COALESCE(
            no_hp_clean,
            ''
          )
        ) DESC,
        delivery_record_quality_score DESC,
        source_priority ASC,
        source_record_instance_key

      LIMIT 1
    )[SAFE_OFFSET(0)] AS phone_pick,


    ARRAY_AGG(
      STRUCT(
        hpht_date AS value,
        delivery_record_quality_score AS quality
      )

      ORDER BY
        hpht_date IS NULL,
        delivery_record_quality_score DESC,
        source_priority ASC,
        source_record_instance_key

      LIMIT 1
    )[SAFE_OFFSET(0)] AS hpht_pick,


    ARRAY_AGG(
      STRUCT(
        hpl_date AS value,
        delivery_record_quality_score AS quality
      )

      ORDER BY
        hpl_date IS NULL,
        delivery_record_quality_score DESC,
        source_priority ASC,
        source_record_instance_key

      LIMIT 1
    )[SAFE_OFFSET(0)] AS hpl_pick,


    ARRAY_AGG(
      STRUCT(
        puskesmas AS value,
        puskesmas_norm AS value_norm,
        desa AS desa,
        desa_norm AS desa_norm,
        posyandu AS posyandu,
        posyandu_norm AS posyandu_norm,
        alamat AS alamat,
        delivery_record_quality_score AS quality
      )

      ORDER BY
        puskesmas_norm IS NULL,
        desa_norm IS NULL,
        delivery_record_quality_score DESC,
        source_priority ASC,
        source_record_instance_key

      LIMIT 1
    )[SAFE_OFFSET(0)] AS location_pick,


    ARRAY_AGG(
      STRUCT(
        delivery_mode_raw AS value,
        delivery_record_quality_score AS quality
      )

      ORDER BY
        delivery_mode_raw IS NULL,
        delivery_record_quality_score DESC,
        source_priority ASC,
        source_record_instance_key

      LIMIT 1
    )[SAFE_OFFSET(0)] AS delivery_mode_pick,


    ARRAY_AGG(
      STRUCT(
        delivery_place_raw AS value,
        delivery_record_quality_score AS quality
      )

      ORDER BY
        delivery_place_raw IS NULL,
        delivery_record_quality_score DESC,
        source_priority ASC,
        source_record_instance_key

      LIMIT 1
    )[SAFE_OFFSET(0)] AS delivery_place_pick,


    ARRAY_AGG(
      STRUCT(
        gestational_age_weeks AS value,
        delivery_record_quality_score AS quality
      )

      ORDER BY
        gestational_age_weeks IS NULL,
        delivery_record_quality_score DESC,
        source_priority ASC,
        source_record_instance_key

      LIMIT 1
    )[SAFE_OFFSET(0)] AS ga_pick,


    ARRAY_AGG(
      STRUCT(
        birth_weight_grams AS value,
        delivery_record_quality_score AS quality
      )

      ORDER BY
        birth_weight_grams IS NULL,
        delivery_record_quality_score DESC,
        source_priority ASC,
        source_record_instance_key

      LIMIT 1
    )[SAFE_OFFSET(0)] AS weight_pick


  FROM members

  GROUP BY delivery_cluster_id
),

assembled AS (

  SELECT

    g.delivery_cluster_id,

    c.canonical_delivery_date
      AS delivery_date,


    p.nik_pick.value
      AS nik_clean,


    p.name_pick.value
      AS nama_ibu,

    p.name_pick.value_norm
      AS nama_norm,

    p.name_pick.value_core
      AS nama_core_norm,


    p.dob_pick.value
      AS tanggal_lahir_ibu,


    p.phone_pick.value
      AS no_hp_clean,


    p.hpht_pick.value
      AS hpht_date,


    p.hpl_pick.value
      AS hpl_date,


    p.location_pick.value
      AS puskesmas,

    p.location_pick.value_norm
      AS puskesmas_norm,

    p.location_pick.desa
      AS desa,

    p.location_pick.desa_norm
      AS desa_norm,

    p.location_pick.posyandu
      AS posyandu,

    p.location_pick.posyandu_norm
      AS posyandu_norm,

    p.location_pick.alamat
      AS alamat,


    p.delivery_mode_pick.value
      AS delivery_mode_raw,

    p.delivery_place_pick.value
      AS delivery_place_raw,


    p.ga_pick.value
      AS representative_gestational_age_weeks,

    p.weight_pick.value
      AS representative_birth_weight_grams,


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


    g.source_record_count,

    g.source_system_count,

    g.source_table_count,

    g.min_source_delivery_date,

    g.max_source_delivery_date,

    g.delivery_date_span_days,


    g.trusted_nik_count,

    g.valid_nik_count,

    g.name_variant_count,


    g.live_birth_evidence_count,

    g.stillbirth_evidence_count,

    g.unknown_outcome_evidence_count,


    g.source_systems,

    g.source_tables,

    g.source_record_instance_keys,

    g.delivery_dedup_methods,

    g.gestational_age_values,

    g.birth_weight_values_grams,


    ARRAY_LENGTH(
      g.gestational_age_values
    ) > 1 AS gestational_age_conflict_flag,


    ARRAY_LENGTH(
      g.birth_weight_values_grams
    ) > 1 AS birth_weight_multi_value_flag,


    g.delivery_date_span_days
      > delivery_date_tolerance_days
      AS delivery_date_chain_span_gt_3d_flag,


    g.trusted_nik_count > 1
      AS trusted_nik_conflict_flag,


    g.valid_nik_count > 1
      AS nik_variant_flag,


    g.name_variant_count > 1
      AS name_variant_flag,


    (
      g.live_birth_evidence_count > 0
      AND g.stillbirth_evidence_count > 0
    ) AS live_stillbirth_mixed_flag


  FROM group_stats g

  JOIN canonical_dates c
    USING (delivery_cluster_id)

  JOIN picks p
    USING (delivery_cluster_id)
)


SELECT

  CONCAT(
    'DELIV_',
    SUBSTR(
      TO_HEX(
        SHA256(
          CONCAT(
            COALESCE(
              nik_clean,
              nama_norm,
              delivery_cluster_id
            ),
            '|',
            CAST(
              delivery_date
              AS STRING
            ),
            '|',
            delivery_cluster_id
          )
        )
      ),
      1,
      24
    )
  ) AS delivery_event_id,

  *

FROM assembled;


-- ############################################################################
-- QA 1
-- SOURCE RECORD -> EVENT REDUCTION
-- ############################################################################

SELECT

  (SELECT COUNT(*)
   FROM
     `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_dedup_base_v3_3`)
    AS dated_source_records,

  (SELECT COUNT(*)
   FROM
     `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_v3_3`)
    AS canonical_delivery_events,

  (
    (SELECT COUNT(*)
     FROM
       `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_dedup_base_v3_3`)
    -
    (SELECT COUNT(*)
     FROM
       `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_v3_3`)
  ) AS source_records_collapsed;


-- ############################################################################
-- QA 2
-- MEMBER MAP INVARIANT
--
-- Every dated source record should appear exactly once.
-- ############################################################################

SELECT

  (SELECT COUNT(*)
   FROM
     `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_dedup_base_v3_3`)
    AS dated_source_records,

  (SELECT COUNT(*)
   FROM
     `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_member_map_v3_3`)
    AS mapped_source_records,

  (SELECT COUNT(DISTINCT source_record_instance_key)
   FROM
     `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_member_map_v3_3`)
    AS distinct_mapped_source_records;


-- ############################################################################
-- QA 3
-- DUPLICATE DELIVERY EVENT IDS
--
-- EXPECTED: zero rows
-- ############################################################################

SELECT

  delivery_event_id,

  COUNT(*) AS n

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_v3_3`

GROUP BY delivery_event_id

HAVING COUNT(*) > 1

ORDER BY n DESC;


-- ############################################################################
-- QA 4
-- EVENT SOURCE COVERAGE
-- ############################################################################

SELECT

  ARRAY_TO_STRING(
    source_systems,
    ' + '
  ) AS delivery_source_combination,

  COUNT(*) AS delivery_events,

  SUM(source_record_count)
    AS represented_source_records

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_v3_3`

GROUP BY delivery_source_combination

ORDER BY delivery_events DESC;


-- ############################################################################
-- QA 5
-- OUTCOME
-- ############################################################################

SELECT

  pregnancy_outcome_final,

  COUNT(*) AS delivery_events

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_v3_3`

GROUP BY pregnancy_outcome_final

ORDER BY delivery_events DESC;


-- ############################################################################
-- QA 6
-- RISK / CONFLICT FLAGS
-- ############################################################################

SELECT

  COUNT(*) AS delivery_events,

  COUNTIF(
    trusted_nik_conflict_flag
  ) AS trusted_nik_conflicts,

  COUNTIF(
    delivery_date_chain_span_gt_3d_flag
  ) AS date_chain_span_gt_3d,

  COUNTIF(
    live_stillbirth_mixed_flag
  ) AS mixed_live_stillbirth,

  COUNTIF(
    gestational_age_conflict_flag
  ) AS gestational_age_multi_value,

  COUNTIF(
    birth_weight_multi_value_flag
  ) AS birth_weight_multi_value

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_v3_3`;


-- ############################################################################
-- QA 7
-- DELIVERY EVENTS BY YEAR
-- ############################################################################

SELECT

  EXTRACT(
    YEAR FROM delivery_date
  ) AS delivery_year,

  COUNT(*) AS delivery_events,

  COUNTIF(
    pregnancy_outcome_final = 'LIVE_BIRTH'
  ) AS live_birth,

  COUNTIF(
    pregnancy_outcome_final = 'STILLBIRTH'
  ) AS stillbirth,

  COUNTIF(
    pregnancy_outcome_final = 'MIXED_LIVE_STILLBIRTH'
  ) AS mixed_live_stillbirth,

  COUNTIF(
    pregnancy_outcome_final = 'UNKNOWN'
  ) AS outcome_unknown

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_v3_3`

GROUP BY delivery_year

ORDER BY delivery_year;


-- ############################################################################
-- QA 8
-- SUSPICIOUS SAME NIK WITH NEARBY CANONICAL DELIVERY EVENTS
--
-- We do not automatically merge these here.
-- ############################################################################

WITH x AS (

  SELECT

    delivery_event_id,

    nik_clean,

    delivery_date,

    LAG(delivery_date) OVER (
      PARTITION BY nik_clean
      ORDER BY delivery_date
    ) AS previous_delivery_date

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_v3_3`

  WHERE nik_clean IS NOT NULL
)

SELECT

  COUNT(*) AS suspicious_events_with_previous_delivery_within_42d

FROM x

WHERE
  previous_delivery_date IS NOT NULL

  AND DATE_DIFF(
    delivery_date,
    previous_delivery_date,
    DAY
  ) BETWEEN 0 AND 42;
