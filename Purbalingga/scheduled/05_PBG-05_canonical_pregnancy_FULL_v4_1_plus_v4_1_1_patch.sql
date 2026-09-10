-- ============================================================================
-- PURBALINGGA — PBG-05 FINAL CANONICAL PREGNANCY BUILD
--
-- SCHEDULE THIS FILE AS ONE BIGQUERY SCHEDULED QUERY.
--
-- PART A
--   Exact recovered parent script:
--   03C_v4_1_FULL_FINAL_IDENTITY_RESOLUTION
--
-- PART B
--   Exact recovered v4.1.1 conservative final canonicalization patch.
--
-- WHY BOTH ARE REQUIRED
--   The full v4.1 script rebuilds within-SIGIZI canonicalization,
--   within-ePUS canonicalization, SIGIZI↔ePUS matching, precanonical spine,
--   pair blocks/features, and the first final pregnancy spine.
--
--   The v4.1.1 patch then applies the later safety change that prevents
--   the strong-pregnancy-fingerprint rules from auto-merging records when
--   BOTH trusted NIK and DOB disagree.
--
-- FINAL OUTPUT
--   stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3
--
-- ============================================================================

-- ###########################################################################
-- PART A — EXACT RECOVERED FULL 03C v4.1 SCRIPT
-- ###########################################################################

-- ============================================================================
-- PURBALINGGA
-- 03C_v4_1_FULL_FINAL_IDENTITY_RESOLUTION
-- CLEAN / REBUILT VERSION
--
-- PROJECT:
--   stellar-orb-451904-d9
--
-- DATASET:
--   kohort_bumil_v2
--
-- INPUT:
--   t_sigizi_pregnancy_episode_v3_3
--   t_epus_pregnancy_episode_adapter_v3_3
--
-- FINAL OUTPUT:
--   t_pregnancy_episode_spine_v3_3
--
-- PRINCIPLE:
--   ONE REAL PREGNANCY = ONE pregnancy_episode_id
--
-- IMPORTANT:
--   - trusted NIK exact match is strong evidence
--   - trusted NIK disagreement blocks weak rules
--   - NIK ending 0000 is NOT trusted
--   - fuzzy name is never sufficient alone
--   - missing value is not treated as conflict
--   - strong pregnancy fingerprint may override identity disagreement
--   - all original disagreement values remain auditable
-- ============================================================================



-- ============================================================================
-- PARAMETERS
-- ============================================================================

DECLARE within_source_anchor_tolerance_days INT64 DEFAULT 30;

DECLARE cross_source_anchor_tolerance_days INT64 DEFAULT 90;

DECLARE hpht_tolerance_days INT64 DEFAULT 7;

DECLARE hpl_tolerance_days INT64 DEFAULT 7;

DECLARE delivery_tolerance_days INT64 DEFAULT 3;

DECLARE strong_hpht_tolerance_days INT64 DEFAULT 14;

DECLARE strong_hpl_tolerance_days INT64 DEFAULT 14;

DECLARE phone_anchor_tolerance_days INT64 DEFAULT 30;

DECLARE final_guard_anchor_tolerance_days INT64 DEFAULT 30;

DECLARE assignment_round INT64 DEFAULT 1;



-- ============================================================================
-- FUNCTIONS
-- ============================================================================

CREATE TEMP FUNCTION compact_name(s STRING)
RETURNS STRING
AS (
  NULLIF(
    REGEXP_REPLACE(
      UPPER(TRIM(COALESCE(s, ''))),
      r'[^A-Z0-9]',
      ''
    ),
    ''
  )
);


CREATE TEMP FUNCTION norm_key(s STRING)
RETURNS STRING
AS (
  NULLIF(
    REGEXP_REPLACE(
      UPPER(TRIM(COALESCE(s, ''))),
      r'[^A-Z0-9]',
      ''
    ),
    ''
  )
);


CREATE TEMP FUNCTION nik_is_suspect_rounding(s STRING)
RETURNS BOOL
AS (
  s IS NOT NULL
  AND REGEXP_CONTAINS(s, r'^\d{16}$')
  AND RIGHT(s, 4) = '0000'
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


CREATE TEMP FUNCTION nik_hard_conflict(
  a STRING,
  b STRING
)
RETURNS BOOL
AS (
  nik_is_trusted(a)
  AND nik_is_trusted(b)
  AND a != b
);


CREATE TEMP FUNCTION levenshtein(
  a STRING,
  b STRING
)
RETURNS INT64
LANGUAGE js
AS """
if (a === null || b === null) return 999;

a = String(a);
b = String(b);

const m = a.length;
const n = b.length;

const dp = [];

for (let j = 0; j <= n; j++) {
  dp[j] = j;
}

for (let i = 1; i <= m; i++) {

  let previous = dp[0];
  dp[0] = i;

  for (let j = 1; j <= n; j++) {

    const old = dp[j];

    if (a[i - 1] === b[j - 1]) {
      dp[j] = previous;
    } else {
      dp[j] = Math.min(
        previous + 1,
        dp[j] + 1,
        dp[j - 1] + 1
      );
    }

    previous = old;
  }
}

return dp[n];
""";



-- ############################################################################
-- ############################################################################
--
-- STAGE A
-- WITHIN-SIGIZI CANONICALIZATION
--
-- ############################################################################
-- ############################################################################



-- ============================================================================
-- A1. QUALITY
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_episode_quality_v3_3`

CLUSTER BY
  nik_clean,
  puskesmas_norm,
  sigizi_episode_id

AS

SELECT
  s.*,

  (
      IF(
        nik_is_trusted(nik_clean),
        100,
        IF(nik_clean IS NOT NULL, 5, 0)
      )

    + IF(tanggal_lahir_ibu IS NOT NULL, 25, 0)

    + IF(hpht_sigizi IS NOT NULL, 30, 0)

    + IF(hpl_sigizi IS NOT NULL, 15, 0)

    + IF(delivery_sigizi IS NOT NULL, 15, 0)

    + IF(
        no_hp_clean IS NOT NULL
        AND LENGTH(no_hp_clean) >= 8,
        8,
        0
      )

    + IF(puskesmas_norm IS NOT NULL, 5, 0)

    + IF(desa_norm IS NOT NULL, 3, 0)

    + LEAST(
        COALESCE(sigizi_member_record_count, 0),
        10
      )
  ) AS episode_quality_score

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_pregnancy_episode_v3_3` s;



-- ============================================================================
-- A2. PAIR FEATURES
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_within_pair_features_v3_3`

CLUSTER BY
  episode_id_1,
  episode_id_2

AS

WITH candidate_pairs AS (

  SELECT
    a.sigizi_episode_id AS episode_id_1,
    b.sigizi_episode_id AS episode_id_2

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_episode_quality_v3_3` a

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_episode_quality_v3_3` b

    ON a.sigizi_episode_id < b.sigizi_episode_id

   AND (

        (
          nik_is_trusted(a.nik_clean)
          AND nik_is_trusted(b.nik_clean)
          AND a.nik_clean = b.nik_clean
          AND ABS(
            DATE_DIFF(
              a.pregnancy_anchor_min_date,
              b.pregnancy_anchor_min_date,
              DAY
            )
          ) <= within_source_anchor_tolerance_days
        )

     OR (
          compact_name(a.nama_core_norm) IS NOT NULL
          AND compact_name(a.nama_core_norm)
                = compact_name(b.nama_core_norm)

          AND ABS(
            DATE_DIFF(
              a.pregnancy_anchor_min_date,
              b.pregnancy_anchor_min_date,
              DAY
            )
          ) <= within_source_anchor_tolerance_days
        )

     OR (
          a.tanggal_lahir_ibu IS NOT NULL
          AND a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
          AND a.hpht_sigizi IS NOT NULL
          AND b.hpht_sigizi IS NOT NULL
          AND ABS(
            DATE_DIFF(
              a.hpht_sigizi,
              b.hpht_sigizi,
              DAY
            )
          ) <= strong_hpht_tolerance_days
        )

     OR (
          a.no_hp_clean IS NOT NULL
          AND b.no_hp_clean IS NOT NULL
          AND LENGTH(a.no_hp_clean) >= 8
          AND a.no_hp_clean = b.no_hp_clean

          AND ABS(
            DATE_DIFF(
              a.pregnancy_anchor_min_date,
              b.pregnancy_anchor_min_date,
              DAY
            )
          ) <= phone_anchor_tolerance_days
        )

   )
),

features AS (

  SELECT
    a.*,

    b.nik_clean
      AS b_nik,

    b.nama_core_norm
      AS b_name,

    b.tanggal_lahir_ibu
      AS b_dob,

    b.no_hp_clean
      AS b_phone,

    b.puskesmas_norm
      AS b_puskesmas,

    b.desa_norm
      AS b_desa,

    b.posyandu
      AS b_posyandu,

    b.hpht_sigizi
      AS b_hpht,

    b.hpl_sigizi
      AS b_hpl,

    b.delivery_sigizi
      AS b_delivery,

    b.pregnancy_anchor_min_date
      AS b_anchor,

    b.episode_quality_score
      AS b_quality,

    p.episode_id_1,

    p.episode_id_2

  FROM candidate_pairs p

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_episode_quality_v3_3` a
    ON a.sigizi_episode_id = p.episode_id_1

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_episode_quality_v3_3` b
    ON b.sigizi_episode_id = p.episode_id_2

)

SELECT

  episode_id_1,
  episode_id_2,

  nik_clean AS a_nik,
  b_nik,

  nama_core_norm AS a_name,
  b_name,

  tanggal_lahir_ibu AS a_dob,
  b_dob,

  no_hp_clean AS a_phone,
  b_phone,

  puskesmas_norm AS a_puskesmas,
  b_puskesmas,

  desa_norm AS a_desa,
  b_desa,

  norm_key(posyandu) AS a_posyandu,
  norm_key(b_posyandu) AS b_posyandu,

  hpht_sigizi AS a_hpht,
  b_hpht,

  hpl_sigizi AS a_hpl,
  b_hpl,

  delivery_sigizi AS a_delivery,
  b_delivery,

  pregnancy_anchor_min_date AS a_anchor,
  b_anchor,

  episode_quality_score AS a_quality,
  b_quality,

  nik_hard_conflict(
    nik_clean,
    b_nik
  ) AS trusted_nik_conflict_flag,

  (
    tanggal_lahir_ibu IS NOT NULL
    AND b_dob IS NOT NULL
    AND tanggal_lahir_ibu != b_dob
  ) AS dob_conflict_flag,

  (
    compact_name(nama_core_norm) IS NOT NULL
    AND compact_name(nama_core_norm)
          = compact_name(b_name)
  ) AS compact_name_exact_flag,

  ABS(
    DATE_DIFF(
      pregnancy_anchor_min_date,
      b_anchor,
      DAY
    )
  ) AS anchor_difference_days,

  CASE
    WHEN hpht_sigizi IS NOT NULL
     AND b_hpht IS NOT NULL
    THEN ABS(
      DATE_DIFF(
        hpht_sigizi,
        b_hpht,
        DAY
      )
    )
  END AS hpht_difference_days,

  CASE
    WHEN hpl_sigizi IS NOT NULL
     AND b_hpl IS NOT NULL
    THEN ABS(
      DATE_DIFF(
        hpl_sigizi,
        b_hpl,
        DAY
      )
    )
  END AS hpl_difference_days,

  CASE
    WHEN delivery_sigizi IS NOT NULL
     AND b_delivery IS NOT NULL
    THEN ABS(
      DATE_DIFF(
        delivery_sigizi,
        b_delivery,
        DAY
      )
    )
  END AS delivery_difference_days,

  (
      CAST(
        puskesmas_norm IS NOT NULL
        AND puskesmas_norm = b_puskesmas
        AS INT64
      )

    + CAST(
        desa_norm IS NOT NULL
        AND desa_norm = b_desa
        AS INT64
      )

    + CAST(
        norm_key(posyandu) IS NOT NULL
        AND norm_key(posyandu)
              = norm_key(b_posyandu)
        AS INT64
      )

    + CAST(
        no_hp_clean IS NOT NULL
        AND b_phone IS NOT NULL
        AND LENGTH(no_hp_clean) >= 8
        AND no_hp_clean = b_phone
        AS INT64
      )

    + CAST(
        delivery_sigizi IS NOT NULL
        AND b_delivery IS NOT NULL
        AND ABS(
          DATE_DIFF(
            delivery_sigizi,
            b_delivery,
            DAY
          )
        ) <= delivery_tolerance_days
        AS INT64
      )
  ) AS corroborator_count

FROM features;



-- ============================================================================
-- A3. ASSIGN WITHIN-SIGIZI MATCH RULE
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_within_source_candidates_v3_3`

CLUSTER BY
  member_episode_id,
  candidate_anchor_episode_id

AS

WITH scored AS (

  SELECT
    f.*,

    CASE

      WHEN
        nik_is_trusted(a_nik)
        AND nik_is_trusted(b_nik)
        AND a_nik = b_nik
        AND anchor_difference_days
              <= within_source_anchor_tolerance_days

        THEN 'NIK+ANCHOR'


      WHEN
        compact_name_exact_flag
        AND a_dob IS NOT NULL
        AND a_dob = b_dob
        AND hpht_difference_days IS NOT NULL
        AND hpht_difference_days
              <= strong_hpht_tolerance_days
        AND corroborator_count >= 1

        THEN 'STRONG_NAME+DOB+HPHT_14D+CORROBORATOR'


      WHEN
        compact_name_exact_flag
        AND a_dob IS NOT NULL
        AND a_dob = b_dob
        AND hpl_difference_days IS NOT NULL
        AND hpl_difference_days
              <= strong_hpl_tolerance_days
        AND corroborator_count >= 1

        THEN 'STRONG_NAME+DOB+HPL_14D+CORROBORATOR'


      WHEN
        compact_name_exact_flag
        AND a_dob IS NOT NULL
        AND a_dob = b_dob
        AND hpht_difference_days = 0
        AND NOT trusted_nik_conflict_flag

        THEN 'NAMA_CORE+DOB+HPHT_EXACT'


      WHEN
        compact_name_exact_flag
        AND a_dob IS NOT NULL
        AND a_dob = b_dob
        AND hpht_difference_days BETWEEN 1 AND hpht_tolerance_days
        AND NOT trusted_nik_conflict_flag

        THEN 'NAMA_CORE+DOB+HPHT_7D'


      WHEN
        compact_name_exact_flag
        AND a_dob IS NOT NULL
        AND a_dob = b_dob
        AND hpl_difference_days IS NOT NULL
        AND hpl_difference_days <= hpl_tolerance_days
        AND NOT trusted_nik_conflict_flag

        THEN 'NAMA_CORE+DOB+HPL_7D'


      WHEN
        compact_name_exact_flag
        AND a_puskesmas IS NOT NULL
        AND a_puskesmas = b_puskesmas
        AND hpht_difference_days = 0
        AND NOT trusted_nik_conflict_flag

        THEN 'NAMA_CORE+HPHT_EXACT+PUSKESMAS'


      ELSE NULL

    END AS match_method

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_within_pair_features_v3_3` f

),

prioritized AS (

  SELECT
    *,

    CASE match_method
      WHEN 'NIK+ANCHOR' THEN 1
      WHEN 'STRONG_NAME+DOB+HPHT_14D+CORROBORATOR' THEN 2
      WHEN 'STRONG_NAME+DOB+HPL_14D+CORROBORATOR' THEN 3
      WHEN 'NAMA_CORE+DOB+HPHT_EXACT' THEN 10
      WHEN 'NAMA_CORE+DOB+HPHT_7D' THEN 11
      WHEN 'NAMA_CORE+DOB+HPL_7D' THEN 12
      WHEN 'NAMA_CORE+HPHT_EXACT+PUSKESMAS' THEN 13
    END AS match_priority

  FROM scored

  WHERE
    match_method IS NOT NULL
)

SELECT

  CASE
    WHEN a_quality < b_quality
      THEN episode_id_1

    WHEN a_quality > b_quality
      THEN episode_id_2

    WHEN episode_id_1 > episode_id_2
      THEN episode_id_1

    ELSE episode_id_2
  END AS member_episode_id,


  CASE
    WHEN a_quality < b_quality
      THEN episode_id_2

    WHEN a_quality > b_quality
      THEN episode_id_1

    WHEN episode_id_1 > episode_id_2
      THEN episode_id_2

    ELSE episode_id_1
  END AS candidate_anchor_episode_id,


  match_method
    AS within_source_match_method,

  match_priority
    AS within_source_match_priority,

  CASE
    WHEN match_priority <= 2
      THEN 'VERY_HIGH'
    WHEN match_priority <= 11
      THEN 'HIGH'
    ELSE 'MEDIUM_HIGH'
  END AS within_source_match_confidence,

  anchor_difference_days,

  COALESCE(
    hpht_difference_days,
    hpl_difference_days,
    anchor_difference_days
  ) AS match_date_difference_days,

  LEAST(
    a_quality,
    b_quality
  ) AS member_quality_score,

  GREATEST(
    a_quality,
    b_quality
  ) AS candidate_anchor_quality_score

FROM prioritized;



-- ============================================================================
-- A4. TERMINAL SIGIZI ANCHORS
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_within_source_anchors_v3_3`

CLUSTER BY sigizi_episode_id

AS

SELECT q.*

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_episode_quality_v3_3` q

WHERE NOT EXISTS (

  SELECT 1

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_within_source_candidates_v3_3` c

  WHERE
    c.member_episode_id = q.sigizi_episode_id

);



-- ============================================================================
-- A5. CANDIDATES TO TERMINAL ANCHORS ONLY
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_within_source_anchor_candidates_v3_3`

CLUSTER BY
  member_episode_id,
  candidate_anchor_episode_id

AS

SELECT
  c.*,

  a.episode_quality_score
    AS eligible_anchor_quality_score

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_within_source_candidates_v3_3` c

JOIN
  `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_within_source_anchors_v3_3` a

  ON a.sigizi_episode_id
     = c.candidate_anchor_episode_id;



-- ============================================================================
-- A6. SIGIZI MEMBER -> CANONICAL MAP
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_episode_canonical_map_v3_3`

CLUSTER BY
  member_sigizi_episode_id,
  canonical_sigizi_episode_id

AS

SELECT
  member_sigizi_episode_id,
  canonical_sigizi_episode_id,
  within_source_match_method,
  within_source_match_priority,
  within_source_match_confidence,
  anchor_difference_days,
  match_date_difference_days

FROM (

  SELECT

    q.sigizi_episode_id
      AS member_sigizi_episode_id,

    COALESCE(
      c.candidate_anchor_episode_id,
      q.sigizi_episode_id
    ) AS canonical_sigizi_episode_id,

    c.within_source_match_method,
    c.within_source_match_priority,
    c.within_source_match_confidence,
    c.anchor_difference_days,
    c.match_date_difference_days,

    ROW_NUMBER() OVER (
      PARTITION BY q.sigizi_episode_id
      ORDER BY
        c.within_source_match_priority IS NULL,
        c.within_source_match_priority,
        c.match_date_difference_days,
        c.anchor_difference_days,
        c.eligible_anchor_quality_score DESC,
        c.candidate_anchor_episode_id
    ) AS rn

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_episode_quality_v3_3` q

  LEFT JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_within_source_anchor_candidates_v3_3` c

    ON c.member_episode_id = q.sigizi_episode_id

)

WHERE rn = 1;



-- ============================================================================
-- A7. CANONICAL SIGIZI EPISODES
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_pregnancy_episode_canonical_v3_3`

CLUSTER BY
  nik_clean,
  puskesmas_norm,
  sigizi_episode_id

AS

WITH members AS (

  SELECT
    m.canonical_sigizi_episode_id,
    q.*

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_episode_canonical_map_v3_3` m

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_episode_quality_v3_3` q

    ON q.sigizi_episode_id
       = m.member_sigizi_episode_id
),

agg AS (

  SELECT
    canonical_sigizi_episode_id,

    ARRAY_AGG(
      STRUCT(
        nik_clean AS value,
        episode_quality_score AS quality
      )
      ORDER BY
        nik_is_trusted(nik_clean) DESC,
        nik_clean IS NULL,
        episode_quality_score DESC,
        sigizi_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS nik_pick,

    ARRAY_AGG(
      STRUCT(
        nama_ibu AS value,
        nama_norm AS value_norm,
        nama_core_norm AS value_core,
        episode_quality_score AS quality
      )
      ORDER BY
        nama_core_norm IS NULL,
        episode_quality_score DESC,
        sigizi_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS name_pick,

    ARRAY_AGG(
      STRUCT(
        tanggal_lahir_ibu AS value,
        episode_quality_score AS quality
      )
      ORDER BY
        tanggal_lahir_ibu IS NULL,
        episode_quality_score DESC,
        sigizi_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS dob_pick,

    ARRAY_AGG(
      STRUCT(
        no_hp_clean AS value,
        episode_quality_score AS quality
      )
      ORDER BY
        no_hp_clean IS NULL,
        LENGTH(COALESCE(no_hp_clean, '')) DESC,
        episode_quality_score DESC,
        sigizi_episode_id
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
        episode_quality_score AS quality
      )
      ORDER BY
        puskesmas_norm IS NULL,
        desa_norm IS NULL,
        posyandu IS NULL,
        episode_quality_score DESC,
        sigizi_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS location_pick,

    ARRAY_AGG(
      STRUCT(
        hpht_sigizi AS value,
        hpht_sigizi_source_table AS source_table,
        episode_quality_score AS quality
      )
      ORDER BY
        hpht_sigizi IS NULL,
        episode_quality_score DESC,
        sigizi_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS hpht_pick,

    ARRAY_AGG(
      STRUCT(
        hpl_sigizi AS value,
        hpl_sigizi_source_table AS source_table,
        episode_quality_score AS quality
      )
      ORDER BY
        hpl_sigizi IS NULL,
        episode_quality_score DESC,
        sigizi_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS hpl_pick,

    ARRAY_AGG(
      STRUCT(
        delivery_sigizi AS value,
        delivery_sigizi_source_table AS source_table,
        episode_quality_score AS quality
      )
      ORDER BY
        delivery_sigizi IS NULL,
        episode_quality_score DESC,
        sigizi_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS delivery_pick,

    MIN(first_anc_date)
      AS first_anc_date,

    MAX(last_anc_date)
      AS last_anc_date,

    MIN(pregnancy_anchor_min_date)
      AS pregnancy_anchor_min_date,

    MAX(pregnancy_anchor_max_date)
      AS pregnancy_anchor_max_date,

    COUNT(*)
      AS within_sigizi_episode_count,

    SUM(
      COALESCE(sigizi_member_record_count, 1)
    ) AS sigizi_member_record_count,

    LOGICAL_OR(
      COALESCE(sigizi_episode_review_flag, FALSE)
    ) AS sigizi_episode_review_flag,

    SUM(
      COALESCE(
        sigizi_identity_propagated_record_count,
        0
      )
    ) AS sigizi_identity_propagated_record_count,

    SUM(
      COALESCE(
        sigizi_ambiguous_identity_record_count,
        0
      )
    ) AS sigizi_ambiguous_identity_record_count,

    MAX(
      COALESCE(
        sigizi_max_signature_row_count,
        0
      )
    ) AS sigizi_max_signature_row_count,

    SUM(
      COALESCE(
        sigizi_distinct_pregnancy_signature_count,
        0
      )
    ) AS sigizi_distinct_pregnancy_signature_count

  FROM members

  GROUP BY
    canonical_sigizi_episode_id
),

source_tables AS (

  SELECT
    canonical_sigizi_episode_id,

    ARRAY_AGG(
      DISTINCT x
      ORDER BY x
    ) AS sigizi_source_tables

  FROM members,
  UNNEST(
    COALESCE(
      sigizi_source_tables,
      ARRAY<STRING>[]
    )
  ) AS x

  GROUP BY
    canonical_sigizi_episode_id
),

identity_methods AS (

  SELECT
    canonical_sigizi_episode_id,

    ARRAY_AGG(
      DISTINCT x
      ORDER BY x
    ) AS sigizi_mother_identity_methods

  FROM members,
  UNNEST(
    COALESCE(
      mother_identity_methods,
      ARRAY<STRING>[]
    )
  ) AS x

  GROUP BY
    canonical_sigizi_episode_id
),

member_ids AS (

  SELECT
    canonical_sigizi_episode_id,

    ARRAY_AGG(
      member_sigizi_episode_id
      ORDER BY member_sigizi_episode_id
    ) AS within_sigizi_member_episode_ids

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_episode_canonical_map_v3_3`

  GROUP BY
    canonical_sigizi_episode_id
)

SELECT

  a.canonical_sigizi_episode_id
    AS sigizi_episode_id,

  a.nik_pick.value
    AS nik_clean,

  a.name_pick.value
    AS nama_ibu,

  a.name_pick.value_norm
    AS nama_norm,

  a.name_pick.value_core
    AS nama_core_norm,

  a.dob_pick.value
    AS tanggal_lahir_ibu,

  a.phone_pick.value
    AS no_hp_clean,

  a.location_pick.puskesmas,
  a.location_pick.puskesmas_norm,
  a.location_pick.desa,
  a.location_pick.desa_norm,
  a.location_pick.posyandu,
  a.location_pick.alamat,

  a.hpht_pick.value
    AS hpht_sigizi,

  a.hpht_pick.source_table
    AS hpht_sigizi_source_table,

  a.hpl_pick.value
    AS hpl_sigizi,

  a.hpl_pick.source_table
    AS hpl_sigizi_source_table,

  a.delivery_pick.value
    AS delivery_sigizi,

  a.delivery_pick.source_table
    AS delivery_sigizi_source_table,

  CASE
    WHEN a.hpht_pick.value IS NOT NULL
      THEN DATE_ADD(
        a.hpht_pick.value,
        INTERVAL 280 DAY
      )
  END AS hpl_from_sigizi_hpht,

  a.first_anc_date,
  a.last_anc_date,

  a.pregnancy_anchor_min_date,
  a.pregnancy_anchor_max_date,

  DATE_DIFF(
    a.pregnancy_anchor_max_date,
    a.pregnancy_anchor_min_date,
    DAY
  ) AS pregnancy_anchor_spread_days,

  a.sigizi_episode_review_flag,

  a.sigizi_member_record_count,

  COALESCE(
    st.sigizi_source_tables,
    ARRAY<STRING>[]
  ) AS sigizi_source_tables,

  COALESCE(
    im.sigizi_mother_identity_methods,
    ARRAY<STRING>[]
  ) AS sigizi_mother_identity_methods,

  a.sigizi_identity_propagated_record_count,

  a.sigizi_ambiguous_identity_record_count,

  a.sigizi_max_signature_row_count,

  a.sigizi_distinct_pregnancy_signature_count,

  a.within_sigizi_episode_count,

  COALESCE(
    mi.within_sigizi_member_episode_ids,
    ARRAY<STRING>[]
  ) AS within_sigizi_member_episode_ids

FROM agg a

LEFT JOIN source_tables st
  USING (canonical_sigizi_episode_id)

LEFT JOIN identity_methods im
  USING (canonical_sigizi_episode_id)

LEFT JOIN member_ids mi
  USING (canonical_sigizi_episode_id);



-- ############################################################################
-- ############################################################################
--
-- STAGE B
-- WITHIN-EPUS CANONICALIZATION
--
-- ############################################################################
-- ############################################################################



-- ============================================================================
-- B1. EPUS QUALITY
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_episode_quality_v3_3`

CLUSTER BY
  nik_clean,
  puskesmas_norm,
  epus_episode_id

AS

SELECT
  e.*,

  (
      IF(
        nik_is_trusted(nik_clean),
        100,
        IF(nik_clean IS NOT NULL, 5, 0)
      )

    + IF(tanggal_lahir_ibu IS NOT NULL, 25, 0)

    + IF(hpht_epus IS NOT NULL, 30, 0)

    + IF(hpl_epus IS NOT NULL, 15, 0)

    + IF(delivery_epus IS NOT NULL, 15, 0)

    + IF(
        no_hp_clean IS NOT NULL
        AND LENGTH(no_hp_clean) >= 8,
        8,
        0
      )

    + IF(puskesmas_norm IS NOT NULL, 5, 0)

    + IF(desa_norm IS NOT NULL, 3, 0)

    + IF(
        COALESCE(has_early_usg_dating, FALSE),
        5,
        0
      )

    + LEAST(
        COALESCE(epus_member_record_count, 0),
        10
      )

  ) AS episode_quality_score

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_pregnancy_episode_adapter_v3_3` e;



-- ============================================================================
-- B2. EPUS PAIR FEATURES
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_within_pair_features_v3_3`

CLUSTER BY
  episode_id_1,
  episode_id_2

AS

WITH candidate_pairs AS (

  SELECT
    a.epus_episode_id AS episode_id_1,
    b.epus_episode_id AS episode_id_2

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_episode_quality_v3_3` a

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_episode_quality_v3_3` b

    ON a.epus_episode_id < b.epus_episode_id

   AND (

        (
          nik_is_trusted(a.nik_clean)
          AND nik_is_trusted(b.nik_clean)
          AND a.nik_clean = b.nik_clean

          AND ABS(
            DATE_DIFF(
              a.pregnancy_anchor_date,
              b.pregnancy_anchor_date,
              DAY
            )
          ) <= within_source_anchor_tolerance_days
        )

     OR (
          compact_name(a.nama_core_norm) IS NOT NULL
          AND compact_name(a.nama_core_norm)
                = compact_name(b.nama_core_norm)

          AND ABS(
            DATE_DIFF(
              a.pregnancy_anchor_date,
              b.pregnancy_anchor_date,
              DAY
            )
          ) <= within_source_anchor_tolerance_days
        )

   )
)

SELECT

  p.episode_id_1,
  p.episode_id_2,

  a.nik_clean AS a_nik,
  b.nik_clean AS b_nik,

  a.nama_core_norm AS a_name,
  b.nama_core_norm AS b_name,

  a.tanggal_lahir_ibu AS a_dob,
  b.tanggal_lahir_ibu AS b_dob,

  a.hpht_epus AS a_hpht,
  b.hpht_epus AS b_hpht,

  a.hpl_epus AS a_hpl,
  b.hpl_epus AS b_hpl,

  a.pregnancy_anchor_date AS a_anchor,
  b.pregnancy_anchor_date AS b_anchor,

  a.episode_quality_score AS a_quality,
  b.episode_quality_score AS b_quality,

  nik_hard_conflict(
    a.nik_clean,
    b.nik_clean
  ) AS trusted_nik_conflict_flag,

  (
    compact_name(a.nama_core_norm) IS NOT NULL
    AND compact_name(a.nama_core_norm)
          = compact_name(b.nama_core_norm)
  ) AS compact_name_exact_flag,

  ABS(
    DATE_DIFF(
      a.pregnancy_anchor_date,
      b.pregnancy_anchor_date,
      DAY
    )
  ) AS anchor_difference_days,

  CASE
    WHEN a.hpht_epus IS NOT NULL
     AND b.hpht_epus IS NOT NULL

    THEN ABS(
      DATE_DIFF(
        a.hpht_epus,
        b.hpht_epus,
        DAY
      )
    )
  END AS hpht_difference_days,

  CASE
    WHEN a.hpl_epus IS NOT NULL
     AND b.hpl_epus IS NOT NULL

    THEN ABS(
      DATE_DIFF(
        a.hpl_epus,
        b.hpl_epus,
        DAY
      )
    )
  END AS hpl_difference_days

FROM candidate_pairs p

JOIN
  `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_episode_quality_v3_3` a

  ON a.epus_episode_id = p.episode_id_1

JOIN
  `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_episode_quality_v3_3` b

  ON b.epus_episode_id = p.episode_id_2;



-- ============================================================================
-- B3. EPUS CANDIDATES
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_within_source_candidates_v3_3`

CLUSTER BY
  member_episode_id,
  candidate_anchor_episode_id

AS

WITH scored AS (

  SELECT
    f.*,

    CASE

      WHEN
        nik_is_trusted(a_nik)
        AND nik_is_trusted(b_nik)
        AND a_nik = b_nik
        AND anchor_difference_days
              <= within_source_anchor_tolerance_days

      THEN 'NIK+ANCHOR'


      WHEN
        compact_name_exact_flag
        AND a_dob IS NOT NULL
        AND a_dob = b_dob
        AND hpht_difference_days = 0
        AND NOT trusted_nik_conflict_flag

      THEN 'NAMA_CORE+DOB+HPHT_EXACT'


      WHEN
        compact_name_exact_flag
        AND a_dob IS NOT NULL
        AND a_dob = b_dob
        AND hpht_difference_days BETWEEN 1 AND hpht_tolerance_days
        AND NOT trusted_nik_conflict_flag

      THEN 'NAMA_CORE+DOB+HPHT_7D'


      WHEN
        compact_name_exact_flag
        AND a_dob IS NOT NULL
        AND a_dob = b_dob
        AND hpl_difference_days IS NOT NULL
        AND hpl_difference_days <= hpl_tolerance_days
        AND NOT trusted_nik_conflict_flag

      THEN 'NAMA_CORE+DOB+HPL_7D'


      ELSE NULL

    END AS match_method

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_within_pair_features_v3_3` f

),

prioritized AS (

  SELECT
    *,

    CASE match_method
      WHEN 'NIK+ANCHOR' THEN 1
      WHEN 'NAMA_CORE+DOB+HPHT_EXACT' THEN 10
      WHEN 'NAMA_CORE+DOB+HPHT_7D' THEN 11
      WHEN 'NAMA_CORE+DOB+HPL_7D' THEN 12
    END AS match_priority

  FROM scored

  WHERE match_method IS NOT NULL
)

SELECT

  CASE
    WHEN a_quality < b_quality
      THEN episode_id_1

    WHEN a_quality > b_quality
      THEN episode_id_2

    WHEN episode_id_1 > episode_id_2
      THEN episode_id_1

    ELSE episode_id_2
  END AS member_episode_id,


  CASE
    WHEN a_quality < b_quality
      THEN episode_id_2

    WHEN a_quality > b_quality
      THEN episode_id_1

    WHEN episode_id_1 > episode_id_2
      THEN episode_id_2

    ELSE episode_id_1
  END AS candidate_anchor_episode_id,


  match_method
    AS within_source_match_method,

  match_priority
    AS within_source_match_priority,

  CASE
    WHEN match_priority = 1
      THEN 'VERY_HIGH'
    WHEN match_priority <= 11
      THEN 'HIGH'
    ELSE 'MEDIUM_HIGH'
  END AS within_source_match_confidence,

  anchor_difference_days,

  COALESCE(
    hpht_difference_days,
    hpl_difference_days,
    anchor_difference_days
  ) AS match_date_difference_days,

  LEAST(a_quality, b_quality)
    AS member_quality_score,

  GREATEST(a_quality, b_quality)
    AS candidate_anchor_quality_score

FROM prioritized;



-- ============================================================================
-- B4. EPUS TERMINAL ANCHORS
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_within_source_anchors_v3_3`

CLUSTER BY epus_episode_id

AS

SELECT q.*

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_episode_quality_v3_3` q

WHERE NOT EXISTS (

  SELECT 1

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_within_source_candidates_v3_3` c

  WHERE
    c.member_episode_id = q.epus_episode_id

);



-- ============================================================================
-- B5. EPUS CANDIDATES TO TERMINAL ANCHORS
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_within_source_anchor_candidates_v3_3`

CLUSTER BY
  member_episode_id,
  candidate_anchor_episode_id

AS

SELECT
  c.*,

  a.episode_quality_score
    AS eligible_anchor_quality_score

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_within_source_candidates_v3_3` c

JOIN
  `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_within_source_anchors_v3_3` a

  ON a.epus_episode_id
     = c.candidate_anchor_episode_id;



-- ============================================================================
-- B6. EPUS CANONICAL MAP
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_episode_canonical_map_v3_3`

CLUSTER BY
  member_epus_episode_id,
  canonical_epus_episode_id

AS

SELECT
  member_epus_episode_id,
  canonical_epus_episode_id,
  within_source_match_method,
  within_source_match_priority,
  within_source_match_confidence,
  anchor_difference_days,
  match_date_difference_days

FROM (

  SELECT

    q.epus_episode_id
      AS member_epus_episode_id,

    COALESCE(
      c.candidate_anchor_episode_id,
      q.epus_episode_id
    ) AS canonical_epus_episode_id,

    c.within_source_match_method,
    c.within_source_match_priority,
    c.within_source_match_confidence,
    c.anchor_difference_days,
    c.match_date_difference_days,

    ROW_NUMBER() OVER (
      PARTITION BY q.epus_episode_id
      ORDER BY
        c.within_source_match_priority IS NULL,
        c.within_source_match_priority,
        c.match_date_difference_days,
        c.anchor_difference_days,
        c.eligible_anchor_quality_score DESC,
        c.candidate_anchor_episode_id
    ) AS rn

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_episode_quality_v3_3` q

  LEFT JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_within_source_anchor_candidates_v3_3` c

    ON c.member_episode_id = q.epus_episode_id

)

WHERE rn = 1;



-- ============================================================================
-- B7. CANONICAL EPUS EPISODES
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_pregnancy_episode_canonical_v3_3`

CLUSTER BY
  nik_clean,
  puskesmas_norm,
  epus_episode_id

AS

WITH members AS (

  SELECT
    m.canonical_epus_episode_id,
    q.*

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_episode_canonical_map_v3_3` m

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_episode_quality_v3_3` q

    ON q.epus_episode_id
       = m.member_epus_episode_id
),

agg AS (

  SELECT
    canonical_epus_episode_id,

    ARRAY_AGG(
      STRUCT(
        nik_clean AS value,
        episode_quality_score AS quality
      )
      ORDER BY
        nik_is_trusted(nik_clean) DESC,
        nik_clean IS NULL,
        episode_quality_score DESC,
        epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS nik_pick,

    ARRAY_AGG(
      STRUCT(
        nama_ibu AS value,
        nama_norm AS value_norm,
        nama_core_norm AS value_core,
        episode_quality_score AS quality
      )
      ORDER BY
        nama_core_norm IS NULL,
        episode_quality_score DESC,
        epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS name_pick,

    ARRAY_AGG(
      STRUCT(
        tanggal_lahir_ibu AS value,
        episode_quality_score AS quality
      )
      ORDER BY
        tanggal_lahir_ibu IS NULL,
        episode_quality_score DESC,
        epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS dob_pick,

    ARRAY_AGG(
      STRUCT(
        no_hp_clean AS value,
        episode_quality_score AS quality
      )
      ORDER BY
        no_hp_clean IS NULL,
        LENGTH(COALESCE(no_hp_clean, '')) DESC,
        episode_quality_score DESC,
        epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS phone_pick,

    ARRAY_AGG(
      STRUCT(
        puskesmas AS puskesmas,
        puskesmas_norm AS puskesmas_norm,
        puskesmas_id AS puskesmas_id,
        desa AS desa,
        desa_norm AS desa_norm,
        posyandu AS posyandu,
        alamat AS alamat,
        episode_quality_score AS quality
      )
      ORDER BY
        puskesmas_norm IS NULL,
        desa_norm IS NULL,
        episode_quality_score DESC,
        epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS location_pick,

    ARRAY_AGG(
      STRUCT(
        hpht_epus AS value,
        episode_quality_score AS quality
      )
      ORDER BY
        hpht_epus IS NULL,
        episode_quality_score DESC,
        epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS hpht_pick,

    ARRAY_AGG(
      STRUCT(
        hpl_epus AS value,
        episode_quality_score AS quality
      )
      ORDER BY
        hpl_epus IS NULL,
        episode_quality_score DESC,
        epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS hpl_pick,

    ARRAY_AGG(
      STRUCT(
        delivery_epus AS value,
        delivery_epus_source AS source,
        delivery_epus_source_record_id AS source_record_id,
        episode_quality_score AS quality
      )
      ORDER BY
        delivery_epus IS NULL,
        episode_quality_score DESC,
        epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS delivery_pick,

    ARRAY_AGG(
      STRUCT(
        epus_episode_source_key AS value,
        episode_quality_score AS quality
      )
      ORDER BY
        epus_episode_source_key IS NULL,
        episode_quality_score DESC,
        epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS source_key_pick,

    MIN(first_anc_date)
      AS first_anc_date,

    MAX(last_anc_date)
      AS last_anc_date,

    MIN(pregnancy_anchor_min_date)
      AS pregnancy_anchor_min_date,

    MAX(pregnancy_anchor_max_date)
      AS pregnancy_anchor_max_date,

    COUNT(*)
      AS within_epus_episode_count,

    SUM(
      COALESCE(epus_member_record_count, 1)
    ) AS epus_member_record_count,

    LOGICAL_OR(
      COALESCE(has_early_usg_dating, FALSE)
    ) AS has_early_usg_dating,

    ARRAY_AGG(
      STRUCT(
        early_usg_hpl_date AS hpl,
        early_usg_ga_weeks AS ga,
        early_usg_anc_date AS anc_date,
        episode_quality_score AS quality
      )
      ORDER BY
        COALESCE(has_early_usg_dating, FALSE) DESC,
        early_usg_hpl_date IS NULL,
        episode_quality_score DESC,
        epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS usg_pick

  FROM members

  GROUP BY canonical_epus_episode_id
),

member_ids AS (

  SELECT
    canonical_epus_episode_id,

    ARRAY_AGG(
      member_epus_episode_id
      ORDER BY member_epus_episode_id
    ) AS within_epus_member_episode_ids

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_episode_canonical_map_v3_3`

  GROUP BY canonical_epus_episode_id
),

source_keys AS (

  SELECT
    canonical_epus_episode_id,

    ARRAY_AGG(
      DISTINCT epus_episode_source_key
      IGNORE NULLS
      ORDER BY epus_episode_source_key
    ) AS epus_episode_source_keys

  FROM members

  GROUP BY canonical_epus_episode_id
),

source_tables AS (

  SELECT
    canonical_epus_episode_id,

    ARRAY_AGG(
      DISTINCT x
      ORDER BY x
    ) AS epus_source_tables

  FROM members,
  UNNEST(
    COALESCE(
      epus_source_tables,
      ARRAY<STRING>[]
    )
  ) x

  GROUP BY canonical_epus_episode_id
),

source_record_ids AS (

  SELECT
    canonical_epus_episode_id,

    ARRAY_AGG(
      DISTINCT x
      ORDER BY x
    ) AS epus_member_source_record_ids

  FROM members,
  UNNEST(
    COALESCE(
      epus_member_source_record_ids,
      ARRAY<STRING>[]
    )
  ) x

  GROUP BY canonical_epus_episode_id
)

SELECT

  a.canonical_epus_episode_id
    AS epus_episode_id,

  a.source_key_pick.value
    AS epus_episode_source_key,

  COALESCE(
    sk.epus_episode_source_keys,
    ARRAY<STRING>[]
  ) AS epus_episode_source_keys,

  a.nik_pick.value
    AS nik_clean,

  CASE
    WHEN nik_is_trusted(a.nik_pick.value)
      THEN 'TRUSTED'
    WHEN a.nik_pick.value IS NULL
      THEN 'MISSING_OR_INVALID'
    ELSE 'SUSPECT_ROUNDED'
  END AS nik_reliability,

  a.name_pick.value
    AS nama_ibu,

  a.name_pick.value_norm
    AS nama_norm,

  a.name_pick.value_core
    AS nama_core_norm,

  a.dob_pick.value
    AS tanggal_lahir_ibu,

  a.phone_pick.value
    AS no_hp_clean,

  a.location_pick.puskesmas,
  a.location_pick.puskesmas_norm,
  a.location_pick.puskesmas_id,
  a.location_pick.desa,
  a.location_pick.desa_norm,
  a.location_pick.posyandu,
  a.location_pick.alamat,

  a.hpht_pick.value
    AS hpht_epus,

  a.hpl_pick.value
    AS hpl_epus,

  a.delivery_pick.value
    AS delivery_epus,

  a.delivery_pick.source
    AS delivery_epus_source,

  a.delivery_pick.source_record_id
    AS delivery_epus_source_record_id,

  CASE
    WHEN a.hpht_pick.value IS NOT NULL
    THEN DATE_ADD(
      a.hpht_pick.value,
      INTERVAL 280 DAY
    )
  END AS hpl_from_epus_hpht,

  a.first_anc_date,
  a.last_anc_date,

  COALESCE(
    a.hpht_pick.value,
    DATE_SUB(
      a.hpl_pick.value,
      INTERVAL 280 DAY
    )
  ) AS pregnancy_anchor_date,

  a.pregnancy_anchor_min_date,
  a.pregnancy_anchor_max_date,

  DATE_DIFF(
    a.pregnancy_anchor_max_date,
    a.pregnancy_anchor_min_date,
    DAY
  ) AS pregnancy_anchor_spread_days,

  a.has_early_usg_dating,

  a.usg_pick.hpl
    AS early_usg_hpl_date,

  a.usg_pick.ga
    AS early_usg_ga_weeks,

  a.usg_pick.anc_date
    AS early_usg_anc_date,

  a.epus_member_record_count,

  a.within_epus_episode_count,

  COALESCE(
    st.epus_source_tables,
    ARRAY<STRING>[]
  ) AS epus_source_tables,

  COALESCE(
    sr.epus_member_source_record_ids,
    ARRAY<STRING>[]
  ) AS epus_member_source_record_ids,

  COALESCE(
    mi.within_epus_member_episode_ids,
    ARRAY<STRING>[]
  ) AS within_epus_member_episode_ids

FROM agg a

LEFT JOIN member_ids mi
  USING (canonical_epus_episode_id)

LEFT JOIN source_keys sk
  USING (canonical_epus_episode_id)

LEFT JOIN source_tables st
  USING (canonical_epus_episode_id)

LEFT JOIN source_record_ids sr
  USING (canonical_epus_episode_id);



-- ############################################################################
-- ############################################################################
--
-- STAGE C
-- CROSS-SOURCE SIGIZI <-> EPUS MATCHING
--
-- ############################################################################
-- ############################################################################



-- ============================================================================
-- C1. CROSS-SOURCE PAIR FEATURES
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_cross_source_pair_features_v3_3`

CLUSTER BY
  epus_episode_id,
  sigizi_episode_id

AS

SELECT

  e.epus_episode_id,
  s.sigizi_episode_id,

  e.nik_clean AS epus_nik,
  s.nik_clean AS sigizi_nik,

  e.nama_core_norm AS epus_name,
  s.nama_core_norm AS sigizi_name,

  e.tanggal_lahir_ibu AS epus_dob,
  s.tanggal_lahir_ibu AS sigizi_dob,

  e.no_hp_clean AS epus_phone,
  s.no_hp_clean AS sigizi_phone,

  e.puskesmas_norm AS epus_puskesmas,
  s.puskesmas_norm AS sigizi_puskesmas,

  e.desa_norm AS epus_desa,
  s.desa_norm AS sigizi_desa,

  norm_key(e.posyandu) AS epus_posyandu,
  norm_key(s.posyandu) AS sigizi_posyandu,

  e.hpht_epus,
  s.hpht_sigizi,

  e.hpl_epus,
  s.hpl_sigizi,

  e.delivery_epus,
  s.delivery_sigizi,

  e.pregnancy_anchor_date AS epus_anchor,
  s.pregnancy_anchor_min_date AS sigizi_anchor,

  nik_hard_conflict(
    e.nik_clean,
    s.nik_clean
  ) AS trusted_nik_conflict_flag,

  (
    e.tanggal_lahir_ibu IS NOT NULL
    AND s.tanggal_lahir_ibu IS NOT NULL
    AND e.tanggal_lahir_ibu != s.tanggal_lahir_ibu
  ) AS dob_conflict_flag,

  (
    compact_name(e.nama_core_norm) IS NOT NULL
    AND compact_name(e.nama_core_norm)
          = compact_name(s.nama_core_norm)
  ) AS compact_name_exact_flag,

  CASE
    WHEN compact_name(e.nama_core_norm) IS NOT NULL
     AND compact_name(s.nama_core_norm) IS NOT NULL

    THEN levenshtein(
      compact_name(e.nama_core_norm),
      compact_name(s.nama_core_norm)
    )
  END AS name_edit_distance,

  ABS(
    DATE_DIFF(
      e.pregnancy_anchor_date,
      s.pregnancy_anchor_min_date,
      DAY
    )
  ) AS anchor_difference_days,

  CASE
    WHEN e.hpht_epus IS NOT NULL
     AND s.hpht_sigizi IS NOT NULL

    THEN ABS(
      DATE_DIFF(
        e.hpht_epus,
        s.hpht_sigizi,
        DAY
      )
    )
  END AS hpht_difference_days,

  CASE
    WHEN e.hpl_epus IS NOT NULL
     AND s.hpl_sigizi IS NOT NULL

    THEN ABS(
      DATE_DIFF(
        e.hpl_epus,
        s.hpl_sigizi,
        DAY
      )
    )
  END AS hpl_difference_days,

  CASE
    WHEN e.delivery_epus IS NOT NULL
     AND s.delivery_sigizi IS NOT NULL

    THEN ABS(
      DATE_DIFF(
        e.delivery_epus,
        s.delivery_sigizi,
        DAY
      )
    )
  END AS delivery_difference_days,

  (
      CAST(
        e.puskesmas_norm IS NOT NULL
        AND e.puskesmas_norm = s.puskesmas_norm
        AS INT64
      )

    + CAST(
        e.desa_norm IS NOT NULL
        AND e.desa_norm = s.desa_norm
        AS INT64
      )

    + CAST(
        norm_key(e.posyandu) IS NOT NULL
        AND norm_key(e.posyandu)
              = norm_key(s.posyandu)
        AS INT64
      )

    + CAST(
        e.no_hp_clean IS NOT NULL
        AND s.no_hp_clean IS NOT NULL
        AND LENGTH(e.no_hp_clean) >= 8
        AND e.no_hp_clean = s.no_hp_clean
        AS INT64
      )

    + CAST(
        e.delivery_epus IS NOT NULL
        AND s.delivery_sigizi IS NOT NULL
        AND ABS(
          DATE_DIFF(
            e.delivery_epus,
            s.delivery_sigizi,
            DAY
          )
        ) <= delivery_tolerance_days
        AS INT64
      )
  ) AS corroborator_count

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_pregnancy_episode_canonical_v3_3` e

JOIN
  `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_pregnancy_episode_canonical_v3_3` s

ON (

     (
       nik_is_trusted(e.nik_clean)
       AND nik_is_trusted(s.nik_clean)
       AND e.nik_clean = s.nik_clean
       AND ABS(
         DATE_DIFF(
           e.pregnancy_anchor_date,
           s.pregnancy_anchor_min_date,
           DAY
         )
       ) <= cross_source_anchor_tolerance_days
     )

  OR (
       compact_name(e.nama_core_norm) IS NOT NULL
       AND compact_name(e.nama_core_norm)
             = compact_name(s.nama_core_norm)

       AND ABS(
         DATE_DIFF(
           e.pregnancy_anchor_date,
           s.pregnancy_anchor_min_date,
           DAY
         )
       ) <= cross_source_anchor_tolerance_days
     )

  OR (
       e.tanggal_lahir_ibu IS NOT NULL
       AND e.tanggal_lahir_ibu = s.tanggal_lahir_ibu
       AND e.hpht_epus IS NOT NULL
       AND s.hpht_sigizi IS NOT NULL

       AND ABS(
         DATE_DIFF(
           e.hpht_epus,
           s.hpht_sigizi,
           DAY
         )
       ) <= strong_hpht_tolerance_days
     )

  OR (
       e.no_hp_clean IS NOT NULL
       AND s.no_hp_clean IS NOT NULL
       AND LENGTH(e.no_hp_clean) >= 8
       AND e.no_hp_clean = s.no_hp_clean

       AND ABS(
         DATE_DIFF(
           e.pregnancy_anchor_date,
           s.pregnancy_anchor_min_date,
           DAY
         )
       ) <= phone_anchor_tolerance_days
     )

);



-- ============================================================================
-- C2. CROSS-SOURCE CANDIDATE RULE
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_cross_source_candidates_v3_3`

CLUSTER BY
  epus_episode_id,
  sigizi_episode_id

AS

WITH scored AS (

  SELECT
    f.*,

    CASE

      WHEN
        nik_is_trusted(epus_nik)
        AND nik_is_trusted(sigizi_nik)
        AND epus_nik = sigizi_nik
        AND anchor_difference_days
              <= cross_source_anchor_tolerance_days

      THEN 'NIK+ANCHOR'


      WHEN
        compact_name_exact_flag
        AND epus_dob IS NOT NULL
        AND epus_dob = sigizi_dob
        AND hpht_difference_days IS NOT NULL
        AND hpht_difference_days
              <= strong_hpht_tolerance_days
        AND corroborator_count >= 1

      THEN 'STRONG_NAME+DOB+HPHT_14D+CORROBORATOR'


      WHEN
        epus_phone IS NOT NULL
        AND sigizi_phone IS NOT NULL
        AND LENGTH(epus_phone) >= 8
        AND epus_phone = sigizi_phone
        AND epus_dob IS NOT NULL
        AND epus_dob = sigizi_dob
        AND anchor_difference_days
              <= phone_anchor_tolerance_days

      THEN 'PHONE+DOB+ANCHOR_30D'


      WHEN
        compact_name_exact_flag
        AND hpht_difference_days = 0
        AND hpl_difference_days = 0
        AND corroborator_count >= 2

      THEN 'STRONG_PREGNANCY_FINGERPRINT_OVERRIDE'


      WHEN
        compact_name_exact_flag
        AND epus_dob IS NOT NULL
        AND epus_dob = sigizi_dob
        AND hpht_difference_days = 0
        AND NOT trusted_nik_conflict_flag

      THEN 'NAMA_CORE+DOB+HPHT_EXACT'


      WHEN
        compact_name_exact_flag
        AND epus_dob IS NOT NULL
        AND epus_dob = sigizi_dob
        AND hpht_difference_days BETWEEN 1 AND hpht_tolerance_days
        AND NOT trusted_nik_conflict_flag

      THEN 'NAMA_CORE+DOB+HPHT_7D'


      WHEN
        compact_name_exact_flag
        AND epus_dob IS NOT NULL
        AND epus_dob = sigizi_dob
        AND hpl_difference_days IS NOT NULL
        AND hpl_difference_days <= hpl_tolerance_days
        AND NOT trusted_nik_conflict_flag

      THEN 'NAMA_CORE+DOB+HPL_7D'


      WHEN
        compact_name_exact_flag
        AND hpht_difference_days = 0
        AND epus_puskesmas IS NOT NULL
        AND epus_puskesmas = sigizi_puskesmas
        AND NOT trusted_nik_conflict_flag

      THEN 'NAMA_CORE+HPHT_EXACT+PUSKESMAS'


      ELSE NULL

    END AS cross_source_match_method

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_cross_source_pair_features_v3_3` f

)

SELECT

  epus_episode_id,
  sigizi_episode_id,

  cross_source_match_method,

  CASE cross_source_match_method
    WHEN 'NIK+ANCHOR' THEN 1
    WHEN 'STRONG_NAME+DOB+HPHT_14D+CORROBORATOR' THEN 2
    WHEN 'PHONE+DOB+ANCHOR_30D' THEN 7
    WHEN 'STRONG_PREGNANCY_FINGERPRINT_OVERRIDE' THEN 8
    WHEN 'NAMA_CORE+DOB+HPHT_EXACT' THEN 10
    WHEN 'NAMA_CORE+DOB+HPHT_7D' THEN 11
    WHEN 'NAMA_CORE+DOB+HPL_7D' THEN 12
    WHEN 'NAMA_CORE+HPHT_EXACT+PUSKESMAS' THEN 13
  END AS cross_source_match_priority,

  CASE
    WHEN cross_source_match_method IN (
      'NIK+ANCHOR',
      'STRONG_NAME+DOB+HPHT_14D+CORROBORATOR',
      'PHONE+DOB+ANCHOR_30D',
      'NAMA_CORE+DOB+HPHT_EXACT'
    )
      THEN 'VERY_HIGH'

    WHEN cross_source_match_method
      = 'STRONG_PREGNANCY_FINGERPRINT_OVERRIDE'
      THEN 'HIGH_CONFLICT'

    ELSE 'HIGH'
  END AS cross_source_match_confidence,

  anchor_difference_days,

  COALESCE(
    hpht_difference_days,
    hpl_difference_days,
    delivery_difference_days,
    anchor_difference_days
  ) AS match_date_difference_days

FROM scored

WHERE
  cross_source_match_method IS NOT NULL;



-- ============================================================================
-- C3. ONE-TO-ONE ASSIGNMENT
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_cross_source_matches_v3_3`

CLUSTER BY
  epus_episode_id,
  sigizi_episode_id

AS

SELECT
  epus_episode_id,
  sigizi_episode_id,
  cross_source_match_method,
  cross_source_match_priority,
  cross_source_match_confidence,
  anchor_difference_days,
  match_date_difference_days,
  CAST(NULL AS INT64) AS assignment_round

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_cross_source_candidates_v3_3`

WHERE FALSE;



SET assignment_round = 1;


WHILE assignment_round <= 5 DO

  INSERT INTO
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_cross_source_matches_v3_3`
  (
    epus_episode_id,
    sigizi_episode_id,
    cross_source_match_method,
    cross_source_match_priority,
    cross_source_match_confidence,
    anchor_difference_days,
    match_date_difference_days,
    assignment_round
  )

  WITH remaining AS (

    SELECT c.*

    FROM
      `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_cross_source_candidates_v3_3` c

    WHERE NOT EXISTS (

      SELECT 1

      FROM
        `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_cross_source_matches_v3_3` m

      WHERE
        m.epus_episode_id = c.epus_episode_id
    )

    AND NOT EXISTS (

      SELECT 1

      FROM
        `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_cross_source_matches_v3_3` m

      WHERE
        m.sigizi_episode_id = c.sigizi_episode_id
    )

  ),

  ranked AS (

    SELECT
      r.*,

      ROW_NUMBER() OVER (
        PARTITION BY epus_episode_id
        ORDER BY
          cross_source_match_priority,
          match_date_difference_days,
          anchor_difference_days,
          sigizi_episode_id
      ) AS epus_rank,

      ROW_NUMBER() OVER (
        PARTITION BY sigizi_episode_id
        ORDER BY
          cross_source_match_priority,
          match_date_difference_days,
          anchor_difference_days,
          epus_episode_id
      ) AS sigizi_rank

    FROM remaining r
  )

  SELECT
    epus_episode_id,
    sigizi_episode_id,
    cross_source_match_method,
    cross_source_match_priority,
    cross_source_match_confidence,
    anchor_difference_days,
    match_date_difference_days,
    assignment_round

  FROM ranked

  WHERE
    epus_rank = 1
    AND sigizi_rank = 1;


  SET assignment_round = assignment_round + 1;

END WHILE;



-- ############################################################################
-- ############################################################################
--
-- STAGE D
-- PRECANONICAL SPINE
--
-- ############################################################################
-- ############################################################################



CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_precanonical_v3_3`

CLUSTER BY
  nik_clean,
  puskesmas_norm,
  pregnancy_episode_id

AS

WITH matched AS (

  SELECT

    CONCAT(
      'PREG_',
      TO_HEX(
        SHA256(
          CONCAT(
            'SIGIZI|',
            s.sigizi_episode_id,
            '|EPUS|',
            e.epus_episode_id
          )
        )
      )
    ) AS pregnancy_episode_id,

    s.sigizi_episode_id,

    e.epus_episode_id,

    e.epus_episode_source_key,

    e.epus_episode_source_keys,

    'SIGIZI + EPUS'
      AS pregnancy_source_combination,

    TRUE
      AS has_pregnancy_sigizi,

    TRUE
      AS has_pregnancy_epus,

    m.cross_source_match_method,
    m.cross_source_match_priority,
    m.cross_source_match_confidence,

    m.anchor_difference_days,

    m.match_date_difference_days,

    m.assignment_round
      AS cross_source_assignment_round,

    nik_hard_conflict(
      e.nik_clean,
      s.nik_clean
    ) AS cross_source_nik_conflict_flag,

    COALESCE(
      IF(
        nik_is_trusted(e.nik_clean),
        e.nik_clean,
        NULL
      ),
      IF(
        nik_is_trusted(s.nik_clean),
        s.nik_clean,
        NULL
      ),
      e.nik_clean,
      s.nik_clean
    ) AS nik_clean,

    COALESCE(
      e.nama_ibu,
      s.nama_ibu
    ) AS nama_ibu,

    COALESCE(
      e.nama_norm,
      s.nama_norm
    ) AS nama_norm,

    COALESCE(
      e.nama_core_norm,
      s.nama_core_norm
    ) AS nama_core_norm,

    COALESCE(
      e.tanggal_lahir_ibu,
      s.tanggal_lahir_ibu
    ) AS tanggal_lahir_ibu,

    COALESCE(
      e.no_hp_clean,
      s.no_hp_clean
    ) AS no_hp_clean,

    CASE
      WHEN e.no_hp_clean IS NOT NULL
        THEN 'EPUS'
      WHEN s.no_hp_clean IS NOT NULL
        THEN 'SIGIZI'
    END AS phone_source,

    COALESCE(
      e.puskesmas,
      s.puskesmas
    ) AS puskesmas,

    COALESCE(
      e.puskesmas_norm,
      s.puskesmas_norm
    ) AS puskesmas_norm,

    COALESCE(
      e.desa,
      s.desa
    ) AS desa,

    COALESCE(
      e.desa_norm,
      s.desa_norm
    ) AS desa_norm,

    COALESCE(
      e.posyandu,
      s.posyandu
    ) AS posyandu,

    COALESCE(
      e.alamat,
      s.alamat
    ) AS alamat,

    s.hpht_sigizi,
    e.hpht_epus,

    s.hpl_sigizi,
    e.hpl_epus,

    s.delivery_sigizi,
    e.delivery_epus,

    s.hpl_from_sigizi_hpht,
    e.hpl_from_epus_hpht,

    COALESCE(
      e.hpht_epus,
      s.hpht_sigizi
    ) AS hpht_date,

    CASE
      WHEN e.hpht_epus IS NOT NULL
        THEN 'EPUS'
      WHEN s.hpht_sigizi IS NOT NULL
        THEN 'SIGIZI'
    END AS hpht_source,

    COALESCE(
      e.hpl_epus,
      s.hpl_sigizi
    ) AS hpl_recorded_date,

    CASE
      WHEN e.hpl_epus IS NOT NULL
        THEN 'EPUS'
      WHEN s.hpl_sigizi IS NOT NULL
        THEN 'SIGIZI'
    END AS hpl_recorded_source,

    COALESCE(
      e.hpl_from_epus_hpht,
      s.hpl_from_sigizi_hpht
    ) AS hpl_from_hpht_date,

    CASE
      WHEN e.first_anc_date IS NULL
        THEN s.first_anc_date
      WHEN s.first_anc_date IS NULL
        THEN e.first_anc_date
      ELSE LEAST(
        e.first_anc_date,
        s.first_anc_date
      )
    END AS first_anc_date,

    CASE
      WHEN e.last_anc_date IS NULL
        THEN s.last_anc_date
      WHEN s.last_anc_date IS NULL
        THEN e.last_anc_date
      ELSE GREATEST(
        e.last_anc_date,
        s.last_anc_date
      )
    END AS last_anc_date,

    COALESCE(
      e.pregnancy_anchor_date,
      s.pregnancy_anchor_min_date
    ) AS pregnancy_anchor_date,

    s.pregnancy_anchor_min_date
      AS sigizi_anchor_date,

    e.pregnancy_anchor_date
      AS epus_anchor_date,

    s.pregnancy_anchor_spread_days
      AS sigizi_anchor_spread_days,

    s.sigizi_episode_review_flag,

    s.sigizi_member_record_count,

    s.sigizi_source_tables,

    s.sigizi_mother_identity_methods,

    s.sigizi_identity_propagated_record_count,

    s.sigizi_ambiguous_identity_record_count,

    s.sigizi_max_signature_row_count,

    s.sigizi_distinct_pregnancy_signature_count,

    LENGTH(
      COALESCE(
        e.no_hp_clean,
        s.no_hp_clean,
        ''
      )
    ) >= 8 AS has_phone_pregnancy_source,

    CASE
      WHEN e.hpl_epus IS NOT NULL
       AND s.hpl_sigizi IS NOT NULL

      THEN DATE_DIFF(
        e.hpl_epus,
        s.hpl_sigizi,
        DAY
      )
    END AS epus_minus_sigizi_hpl_days,

    CASE
      WHEN e.hpht_epus IS NOT NULL
       AND s.hpht_sigizi IS NOT NULL

      THEN DATE_DIFF(
        e.hpht_epus,
        s.hpht_sigizi,
        DAY
      )
    END AS epus_minus_sigizi_hpht_days,

    s.within_sigizi_member_episode_ids
      AS sigizi_episode_ids,

    e.within_epus_member_episode_ids
      AS epus_episode_ids

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_cross_source_matches_v3_3` m

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_pregnancy_episode_canonical_v3_3` s

    USING (sigizi_episode_id)

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_pregnancy_episode_canonical_v3_3` e

    USING (epus_episode_id)
),

sigizi_only AS (

  SELECT

    CONCAT(
      'PREG_',
      TO_HEX(
        SHA256(
          CONCAT(
            'SIGIZI_ONLY|',
            s.sigizi_episode_id
          )
        )
      )
    ) AS pregnancy_episode_id,

    s.sigizi_episode_id,

    CAST(NULL AS STRING)
      AS epus_episode_id,

    CAST(NULL AS STRING)
      AS epus_episode_source_key,

    ARRAY<STRING>[]
      AS epus_episode_source_keys,

    'SIGIZI ONLY'
      AS pregnancy_source_combination,

    TRUE
      AS has_pregnancy_sigizi,

    FALSE
      AS has_pregnancy_epus,

    CAST(NULL AS STRING)
      AS cross_source_match_method,

    CAST(NULL AS INT64)
      AS cross_source_match_priority,

    CAST(NULL AS STRING)
      AS cross_source_match_confidence,

    CAST(NULL AS INT64)
      AS anchor_difference_days,

    CAST(NULL AS INT64)
      AS match_date_difference_days,

    CAST(NULL AS INT64)
      AS cross_source_assignment_round,

    FALSE
      AS cross_source_nik_conflict_flag,

    s.nik_clean,

    s.nama_ibu,

    s.nama_norm,

    s.nama_core_norm,

    s.tanggal_lahir_ibu,

    s.no_hp_clean,

    CASE
      WHEN s.no_hp_clean IS NOT NULL
      THEN 'SIGIZI'
    END AS phone_source,

    s.puskesmas,
    s.puskesmas_norm,
    s.desa,
    s.desa_norm,
    s.posyandu,
    s.alamat,

    s.hpht_sigizi,

    CAST(NULL AS DATE)
      AS hpht_epus,

    s.hpl_sigizi,

    CAST(NULL AS DATE)
      AS hpl_epus,

    s.delivery_sigizi,

    CAST(NULL AS DATE)
      AS delivery_epus,

    s.hpl_from_sigizi_hpht,

    CAST(NULL AS DATE)
      AS hpl_from_epus_hpht,

    s.hpht_sigizi
      AS hpht_date,

    CASE
      WHEN s.hpht_sigizi IS NOT NULL
      THEN 'SIGIZI'
    END AS hpht_source,

    s.hpl_sigizi
      AS hpl_recorded_date,

    CASE
      WHEN s.hpl_sigizi IS NOT NULL
      THEN 'SIGIZI'
    END AS hpl_recorded_source,

    s.hpl_from_sigizi_hpht
      AS hpl_from_hpht_date,

    s.first_anc_date,
    s.last_anc_date,

    s.pregnancy_anchor_min_date
      AS pregnancy_anchor_date,

    s.pregnancy_anchor_min_date
      AS sigizi_anchor_date,

    CAST(NULL AS DATE)
      AS epus_anchor_date,

    s.pregnancy_anchor_spread_days
      AS sigizi_anchor_spread_days,

    s.sigizi_episode_review_flag,

    s.sigizi_member_record_count,

    s.sigizi_source_tables,

    s.sigizi_mother_identity_methods,

    s.sigizi_identity_propagated_record_count,

    s.sigizi_ambiguous_identity_record_count,

    s.sigizi_max_signature_row_count,

    s.sigizi_distinct_pregnancy_signature_count,

    LENGTH(
      COALESCE(
        s.no_hp_clean,
        ''
      )
    ) >= 8 AS has_phone_pregnancy_source,

    CAST(NULL AS INT64)
      AS epus_minus_sigizi_hpl_days,

    CAST(NULL AS INT64)
      AS epus_minus_sigizi_hpht_days,

    s.within_sigizi_member_episode_ids
      AS sigizi_episode_ids,

    ARRAY<STRING>[]
      AS epus_episode_ids

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_pregnancy_episode_canonical_v3_3` s

  WHERE NOT EXISTS (

    SELECT 1

    FROM
      `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_cross_source_matches_v3_3` m

    WHERE
      m.sigizi_episode_id = s.sigizi_episode_id
  )
),

epus_only AS (

  SELECT

    CONCAT(
      'PREG_',
      TO_HEX(
        SHA256(
          CONCAT(
            'EPUS_ONLY|',
            e.epus_episode_id
          )
        )
      )
    ) AS pregnancy_episode_id,

    CAST(NULL AS STRING)
      AS sigizi_episode_id,

    e.epus_episode_id,

    e.epus_episode_source_key,

    e.epus_episode_source_keys,

    'EPUS ONLY'
      AS pregnancy_source_combination,

    FALSE
      AS has_pregnancy_sigizi,

    TRUE
      AS has_pregnancy_epus,

    CAST(NULL AS STRING)
      AS cross_source_match_method,

    CAST(NULL AS INT64)
      AS cross_source_match_priority,

    CAST(NULL AS STRING)
      AS cross_source_match_confidence,

    CAST(NULL AS INT64)
      AS anchor_difference_days,

    CAST(NULL AS INT64)
      AS match_date_difference_days,

    CAST(NULL AS INT64)
      AS cross_source_assignment_round,

    FALSE
      AS cross_source_nik_conflict_flag,

    e.nik_clean,

    e.nama_ibu,

    e.nama_norm,

    e.nama_core_norm,

    e.tanggal_lahir_ibu,

    e.no_hp_clean,

    CASE
      WHEN e.no_hp_clean IS NOT NULL
      THEN 'EPUS'
    END AS phone_source,

    e.puskesmas,
    e.puskesmas_norm,
    e.desa,
    e.desa_norm,
    e.posyandu,
    e.alamat,

    CAST(NULL AS DATE)
      AS hpht_sigizi,

    e.hpht_epus,

    CAST(NULL AS DATE)
      AS hpl_sigizi,

    e.hpl_epus,

    CAST(NULL AS DATE)
      AS delivery_sigizi,

    e.delivery_epus,

    CAST(NULL AS DATE)
      AS hpl_from_sigizi_hpht,

    e.hpl_from_epus_hpht,

    e.hpht_epus
      AS hpht_date,

    CASE
      WHEN e.hpht_epus IS NOT NULL
      THEN 'EPUS'
    END AS hpht_source,

    e.hpl_epus
      AS hpl_recorded_date,

    CASE
      WHEN e.hpl_epus IS NOT NULL
      THEN 'EPUS'
    END AS hpl_recorded_source,

    e.hpl_from_epus_hpht
      AS hpl_from_hpht_date,

    e.first_anc_date,
    e.last_anc_date,

    e.pregnancy_anchor_date,

    CAST(NULL AS DATE)
      AS sigizi_anchor_date,

    e.pregnancy_anchor_date
      AS epus_anchor_date,

    CAST(NULL AS INT64)
      AS sigizi_anchor_spread_days,

    FALSE
      AS sigizi_episode_review_flag,

    CAST(NULL AS INT64)
      AS sigizi_member_record_count,

    ARRAY<STRING>[]
      AS sigizi_source_tables,

    ARRAY<STRING>[]
      AS sigizi_mother_identity_methods,

    CAST(NULL AS INT64)
      AS sigizi_identity_propagated_record_count,

    CAST(NULL AS INT64)
      AS sigizi_ambiguous_identity_record_count,

    CAST(NULL AS INT64)
      AS sigizi_max_signature_row_count,

    CAST(NULL AS INT64)
      AS sigizi_distinct_pregnancy_signature_count,

    LENGTH(
      COALESCE(
        e.no_hp_clean,
        ''
      )
    ) >= 8 AS has_phone_pregnancy_source,

    CAST(NULL AS INT64)
      AS epus_minus_sigizi_hpl_days,

    CAST(NULL AS INT64)
      AS epus_minus_sigizi_hpht_days,

    ARRAY<STRING>[]
      AS sigizi_episode_ids,

    e.within_epus_member_episode_ids
      AS epus_episode_ids

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_pregnancy_episode_canonical_v3_3` e

  WHERE NOT EXISTS (

    SELECT 1

    FROM
      `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_cross_source_matches_v3_3` m

    WHERE
      m.epus_episode_id = e.epus_episode_id
  )
)

SELECT * FROM matched

UNION ALL

SELECT * FROM sigizi_only

UNION ALL

SELECT * FROM epus_only;



-- ############################################################################
-- ############################################################################
--
-- STAGE E
-- FINAL ALL-EPISODE CANONICALIZATION
--
-- ############################################################################
-- ############################################################################



-- ============================================================================
-- E1. FINAL GUARD BASE
--
-- IMPORTANT:
-- aliases are created in base_1, then reused in base_2.
-- This fixes the earlier source_delivery_date error.
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_base_v3_3`

CLUSTER BY
  puskesmas_norm,
  pregnancy_episode_id

AS

WITH base_1 AS (

  SELECT
    p.*,

    COALESCE(
      delivery_epus,
      delivery_sigizi
    ) AS source_delivery_date,

    COALESCE(
      hpl_recorded_date,
      hpl_from_hpht_date
    ) AS effective_hpl_date,

    compact_name(
      nama_core_norm
    ) AS nama_compact_norm,

    norm_key(
      posyandu
    ) AS posyandu_norm_key

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_precanonical_v3_3` p
),

base_2 AS (

  SELECT
    b.*,

    (
        CASE pregnancy_source_combination
          WHEN 'SIGIZI + EPUS' THEN 300
          WHEN 'EPUS ONLY' THEN 200
          WHEN 'SIGIZI ONLY' THEN 100
          ELSE 0
        END

      + IF(
          nik_is_trusted(nik_clean),
          100,
          0
        )

      + IF(
          tanggal_lahir_ibu IS NOT NULL,
          25,
          0
        )

      + IF(
          hpht_date IS NOT NULL,
          30,
          0
        )

      + IF(
          hpl_recorded_date IS NOT NULL,
          20,
          0
        )

      + IF(
          source_delivery_date IS NOT NULL,
          15,
          0
        )

      + IF(
          no_hp_clean IS NOT NULL
          AND LENGTH(no_hp_clean) >= 8,
          8,
          0
        )

      + IF(
          puskesmas_norm IS NOT NULL,
          5,
          0
        )

      + IF(
          desa_norm IS NOT NULL,
          3,
          0
        )
    ) AS final_quality_score,

    CASE

      WHEN nama_compact_norm IS NOT NULL
       AND hpht_date IS NOT NULL
       AND effective_hpl_date IS NOT NULL
       AND puskesmas_norm IS NOT NULL

      THEN CONCAT(
        nama_compact_norm,
        '|',
        CAST(hpht_date AS STRING),
        '|',
        CAST(effective_hpl_date AS STRING),
        '|',
        puskesmas_norm
      )

    END AS strict_pregnancy_fingerprint_key

  FROM base_1 b
)

SELECT
  b.*,

  CASE
    WHEN strict_pregnancy_fingerprint_key IS NOT NULL

    THEN COUNT(*) OVER (
      PARTITION BY strict_pregnancy_fingerprint_key
    )
  END AS fingerprint_episode_count

FROM base_2 b;



-- ============================================================================
-- E2. FINAL PAIR BLOCKS
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_pair_blocks_v3_3`

CLUSTER BY
  pregnancy_episode_id_1,
  pregnancy_episode_id_2

AS

SELECT
  a.pregnancy_episode_id
    AS pregnancy_episode_id_1,

  b.pregnancy_episode_id
    AS pregnancy_episode_id_2

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_base_v3_3` a

JOIN
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_base_v3_3` b

  ON a.pregnancy_episode_id
       < b.pregnancy_episode_id

 AND (

      (
        nik_is_trusted(a.nik_clean)
        AND nik_is_trusted(b.nik_clean)
        AND a.nik_clean = b.nik_clean
      )

   OR (
        a.nama_compact_norm IS NOT NULL
        AND a.nama_compact_norm
              = b.nama_compact_norm
      )

   OR (
        a.no_hp_clean IS NOT NULL
        AND b.no_hp_clean IS NOT NULL
        AND LENGTH(a.no_hp_clean) >= 8
        AND LENGTH(b.no_hp_clean) >= 8
        AND a.no_hp_clean = b.no_hp_clean
      )

   OR (
        a.tanggal_lahir_ibu IS NOT NULL
        AND b.tanggal_lahir_ibu IS NOT NULL
        AND a.tanggal_lahir_ibu
              = b.tanggal_lahir_ibu

        AND a.hpht_date IS NOT NULL
        AND b.hpht_date IS NOT NULL

        AND ABS(
          DATE_DIFF(
            a.hpht_date,
            b.hpht_date,
            DAY
          )
        ) <= strong_hpht_tolerance_days
      )

   OR (
        a.strict_pregnancy_fingerprint_key IS NOT NULL
        AND a.strict_pregnancy_fingerprint_key
              = b.strict_pregnancy_fingerprint_key
      )
 );



-- ============================================================================
-- E3. FINAL PAIR FEATURES
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_pair_features_v3_3`

CLUSTER BY
  pregnancy_episode_id_1,
  pregnancy_episode_id_2

AS

SELECT

  a.pregnancy_episode_id
    AS pregnancy_episode_id_1,

  b.pregnancy_episode_id
    AS pregnancy_episode_id_2,

  a.final_quality_score
    AS quality_1,

  b.final_quality_score
    AS quality_2,

  a.nik_clean
    AS nik_1,

  b.nik_clean
    AS nik_2,

  a.nama_compact_norm
    AS name_1,

  b.nama_compact_norm
    AS name_2,

  a.tanggal_lahir_ibu
    AS dob_1,

  b.tanggal_lahir_ibu
    AS dob_2,

  a.no_hp_clean
    AS phone_1,

  b.no_hp_clean
    AS phone_2,

  a.puskesmas_norm
    AS puskesmas_1,

  b.puskesmas_norm
    AS puskesmas_2,

  a.desa_norm
    AS desa_1,

  b.desa_norm
    AS desa_2,

  a.posyandu_norm_key
    AS posyandu_1,

  b.posyandu_norm_key
    AS posyandu_2,

  a.hpht_date
    AS hpht_1,

  b.hpht_date
    AS hpht_2,

  a.effective_hpl_date
    AS hpl_1,

  b.effective_hpl_date
    AS hpl_2,

  a.source_delivery_date
    AS delivery_1,

  b.source_delivery_date
    AS delivery_2,

  a.pregnancy_anchor_date
    AS anchor_1,

  b.pregnancy_anchor_date
    AS anchor_2,

  a.strict_pregnancy_fingerprint_key
    AS fingerprint_1,

  b.strict_pregnancy_fingerprint_key
    AS fingerprint_2,

  a.fingerprint_episode_count
    AS fingerprint_count_1,

  b.fingerprint_episode_count
    AS fingerprint_count_2,

  nik_hard_conflict(
    a.nik_clean,
    b.nik_clean
  ) AS trusted_nik_conflict_flag,

  (
    a.tanggal_lahir_ibu IS NOT NULL
    AND b.tanggal_lahir_ibu IS NOT NULL
    AND a.tanggal_lahir_ibu
          != b.tanggal_lahir_ibu
  ) AS dob_conflict_flag,

  (
    a.tanggal_lahir_ibu IS NULL
    OR b.tanggal_lahir_ibu IS NULL
  ) AS dob_missing_one_side_flag,

  (
    a.nama_compact_norm IS NOT NULL
    AND a.nama_compact_norm
          = b.nama_compact_norm
  ) AS compact_name_exact_flag,

  CASE
    WHEN a.nama_compact_norm IS NOT NULL
     AND b.nama_compact_norm IS NOT NULL

    THEN levenshtein(
      a.nama_compact_norm,
      b.nama_compact_norm
    )
  END AS name_edit_distance,

  CASE
    WHEN a.pregnancy_anchor_date IS NOT NULL
     AND b.pregnancy_anchor_date IS NOT NULL

    THEN ABS(
      DATE_DIFF(
        a.pregnancy_anchor_date,
        b.pregnancy_anchor_date,
        DAY
      )
    )
  END AS anchor_difference_days,

  CASE
    WHEN a.hpht_date IS NOT NULL
     AND b.hpht_date IS NOT NULL

    THEN ABS(
      DATE_DIFF(
        a.hpht_date,
        b.hpht_date,
        DAY
      )
    )
  END AS hpht_difference_days,

  CASE
    WHEN a.effective_hpl_date IS NOT NULL
     AND b.effective_hpl_date IS NOT NULL

    THEN ABS(
      DATE_DIFF(
        a.effective_hpl_date,
        b.effective_hpl_date,
        DAY
      )
    )
  END AS hpl_difference_days,

  CASE
    WHEN a.source_delivery_date IS NOT NULL
     AND b.source_delivery_date IS NOT NULL

    THEN ABS(
      DATE_DIFF(
        a.source_delivery_date,
        b.source_delivery_date,
        DAY
      )
    )
  END AS delivery_difference_days,

  (
      CAST(
        a.puskesmas_norm IS NOT NULL
        AND a.puskesmas_norm
              = b.puskesmas_norm
        AS INT64
      )

    + CAST(
        a.desa_norm IS NOT NULL
        AND a.desa_norm
              = b.desa_norm
        AS INT64
      )

    + CAST(
        a.posyandu_norm_key IS NOT NULL
        AND a.posyandu_norm_key
              = b.posyandu_norm_key
        AS INT64
      )

    + CAST(
        a.no_hp_clean IS NOT NULL
        AND b.no_hp_clean IS NOT NULL
        AND LENGTH(a.no_hp_clean) >= 8
        AND LENGTH(b.no_hp_clean) >= 8
        AND a.no_hp_clean
              = b.no_hp_clean
        AS INT64
      )

    + CAST(
        a.source_delivery_date IS NOT NULL
        AND b.source_delivery_date IS NOT NULL
        AND ABS(
          DATE_DIFF(
            a.source_delivery_date,
            b.source_delivery_date,
            DAY
          )
        ) <= delivery_tolerance_days
        AS INT64
      )
  ) AS corroborator_count

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_pair_blocks_v3_3` x

JOIN
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_base_v3_3` a

  ON a.pregnancy_episode_id
       = x.pregnancy_episode_id_1

JOIN
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_base_v3_3` b

  ON b.pregnancy_episode_id
       = x.pregnancy_episode_id_2;



-- ============================================================================
-- E4. FINAL MERGE RULES + DIRECTION
-- ============================================================================

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

      WHEN
        nik_is_trusted(nik_1)
        AND nik_is_trusted(nik_2)
        AND nik_1 = nik_2
        AND anchor_difference_days IS NOT NULL
        AND anchor_difference_days
              <= final_guard_anchor_tolerance_days

      THEN 'FINAL_NIK+ANCHOR_30D'


      WHEN
        compact_name_exact_flag
        AND dob_1 IS NOT NULL
        AND dob_1 = dob_2
        AND hpht_difference_days IS NOT NULL
        AND hpht_difference_days
              <= strong_hpht_tolerance_days
        AND corroborator_count >= 1

      THEN 'FINAL_STRONG_NAME+DOB+HPHT_14D+CORROBORATOR'


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
        AND dob_1 = dob_2
        AND hpht_difference_days IS NOT NULL
        AND hpht_difference_days
              <= strong_hpht_tolerance_days
        AND corroborator_count >= 2
        AND NOT trusted_nik_conflict_flag

      THEN 'FINAL_FUZZY_NAME+DOB+HPHT_14D+2_CORROBORATORS'


      WHEN
        phone_1 IS NOT NULL
        AND phone_2 IS NOT NULL
        AND LENGTH(phone_1) >= 8
        AND phone_1 = phone_2
        AND dob_1 IS NOT NULL
        AND dob_1 = dob_2
        AND (
             hpht_difference_days
               <= strong_hpht_tolerance_days

          OR hpl_difference_days
               <= strong_hpl_tolerance_days
        )

      THEN 'FINAL_PHONE+DOB+HPHT_HPL'


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


      WHEN
        compact_name_exact_flag
        AND hpht_difference_days = 0
        AND hpl_difference_days = 0
        AND corroborator_count >= 2

      THEN 'FINAL_STRONG_PREGNANCY_FINGERPRINT_OVERRIDE'


      WHEN
        fingerprint_1 IS NOT NULL
        AND fingerprint_1 = fingerprint_2
        AND fingerprint_count_1 = 2
        AND fingerprint_count_2 = 2

      THEN 'FINAL_HIGH_CONFLICT_UNIQUE_FINGERPRINT'


      WHEN
        compact_name_exact_flag
        AND dob_1 IS NOT NULL
        AND dob_1 = dob_2
        AND hpl_difference_days IS NOT NULL
        AND hpl_difference_days <= hpl_tolerance_days
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



-- ============================================================================
-- E5. TERMINAL FINAL ANCHORS
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_guard_anchors_v3_3`

CLUSTER BY pregnancy_episode_id

AS

SELECT b.*

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



-- ============================================================================
-- E6. RANK ONLY CANDIDATES POINTING TO TERMINAL ANCHORS
-- ============================================================================

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



-- ============================================================================
-- E7. UNIQUE BEST TARGET ONLY
-- ============================================================================

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



-- ============================================================================
-- E8. INITIAL CANONICAL MAP
-- ============================================================================

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



-- ============================================================================
-- E9. FOLLOW CANONICAL CHAINS
--
-- Five materialized steps prevent:
--
-- A -> B -> C
--
-- from leaving A mapped only to B.
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step1_v3_3`

AS

SELECT
  m.* EXCEPT(canonical_pregnancy_episode_id),

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



CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step2_v3_3`

AS

SELECT
  m.* EXCEPT(canonical_pregnancy_episode_id),

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



CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step3_v3_3`

AS

SELECT
  m.* EXCEPT(canonical_pregnancy_episode_id),

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



CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_step4_v3_3`

AS

SELECT
  m.* EXCEPT(canonical_pregnancy_episode_id),

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



CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_v3_3`

CLUSTER BY
  member_pregnancy_episode_id,
  canonical_pregnancy_episode_id

AS

SELECT
  m.* EXCEPT(canonical_pregnancy_episode_id),

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
-- ############################################################################
--
-- STAGE F
-- FINAL CANONICAL PREGNANCY SPINE
--
-- ############################################################################
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
      DISTINCT compact_name(nama_core_norm)
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

member_ids AS (

  SELECT
    canonical_pregnancy_episode_id,

    ARRAY_AGG(
      member_pregnancy_episode_id
      ORDER BY member_pregnancy_episode_id
    ) AS canonical_episode_member_ids

  FROM members

  GROUP BY canonical_pregnancy_episode_id
),

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

  GROUP BY canonical_pregnancy_episode_id
),

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
  ) x

  GROUP BY canonical_pregnancy_episode_id
),

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
  ) x

  GROUP BY canonical_pregnancy_episode_id
),

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
  ) x

  GROUP BY canonical_pregnancy_episode_id
),

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

  GROUP BY canonical_pregnancy_episode_id
),

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

  GROUP BY canonical_pregnancy_episode_id
)

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



-- ############################################################################
-- ############################################################################
--
-- FINAL QA
--
-- ############################################################################
-- ############################################################################



-- ============================================================================
-- QA 1. SOURCE EPISODE REDUCTION
-- ============================================================================

SELECT
  'SIGIZI' AS source_system,

  (
    SELECT COUNT(*)
    FROM
      `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_pregnancy_episode_v3_3`
  ) AS before_canonicalization,

  (
    SELECT COUNT(*)
    FROM
      `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_pregnancy_episode_canonical_v3_3`
  ) AS after_canonicalization

UNION ALL

SELECT
  'EPUS',

  (
    SELECT COUNT(*)
    FROM
      `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_pregnancy_episode_adapter_v3_3`
  ),

  (
    SELECT COUNT(*)
    FROM
      `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_pregnancy_episode_canonical_v3_3`
  );



-- ============================================================================
-- QA 2. CROSS-SOURCE MATCHES
-- ============================================================================

SELECT
  cross_source_match_method,
  cross_source_match_confidence,
  assignment_round,

  COUNT(*) AS matched_pregnancies

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_cross_source_matches_v3_3`

GROUP BY
  cross_source_match_method,
  cross_source_match_confidence,
  assignment_round

ORDER BY
  MIN(cross_source_match_priority),
  assignment_round;



-- ============================================================================
-- QA 3. FINAL SOURCE COMBINATION
-- ============================================================================

SELECT

  pregnancy_source_combination,

  COUNT(*) AS pregnancies,

  COUNTIF(
    final_canonicalization_applied
  ) AS final_canonicalization_applied,

  COUNTIF(
    final_nik_conflict_flag
  ) AS nik_conflict,

  COUNTIF(
    final_trusted_nik_conflict_flag
  ) AS trusted_nik_conflict,

  COUNTIF(
    final_dob_conflict_flag
  ) AS dob_conflict,

  COUNTIF(
    final_match_qa_required
  ) AS qa_required

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3`

GROUP BY
  pregnancy_source_combination

ORDER BY
  pregnancies DESC;



-- ============================================================================
-- QA 4. FINAL PRIMARY KEY INVARIANT
-- ============================================================================

SELECT

  COUNT(*) AS final_rows,

  COUNT(
    DISTINCT pregnancy_episode_id
  ) AS distinct_pregnancy_episode_ids

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3`;



-- ============================================================================
-- QA 5. FINAL MERGE METHOD
-- ============================================================================

SELECT

  COALESCE(
    final_merge_method,
    'SELF'
  ) AS final_merge_method,

  COUNT(*) AS member_rows

FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_final_canonical_map_v3_3`

GROUP BY
  final_merge_method

ORDER BY
  member_rows DESC;



-- ============================================================================
-- QA 6. 2025+ EXPECTED DELIVERY
-- ============================================================================

WITH x AS (

  SELECT
    *,

    COALESCE(
      hpl_recorded_date,
      hpl_from_hpht_date
    ) AS expected_delivery_date

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3`

)

SELECT

  EXTRACT(
    YEAR FROM expected_delivery_date
  ) AS expected_delivery_year,

  pregnancy_source_combination,

  COUNT(*) AS pregnancies

FROM x

WHERE
  expected_delivery_date >= DATE '2025-01-01'

GROUP BY
  1,
  2

ORDER BY
  1,
  2;


-- ###########################################################################
-- PART B — EXACT RECOVERED v4.1.1 CONSERVATIVE PATCH
-- ###########################################################################

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
-- PART B REUSES THE PARAMETERS AND FUNCTIONS DECLARED IN PART A
--
-- BigQuery permits DECLARE statements only before the first executable
-- statement in a script. The values required by this patch are already
-- declared at the beginning of Part A, and nik_is_trusted() is also already
-- defined there.
-- ============================================================================


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
