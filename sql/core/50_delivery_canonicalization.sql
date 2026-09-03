-- Independent source layer: references redirected to v3; original logic retained.
-- V3 CORE DRAFT: not executed in BigQuery; production compatibility not yet validated.
-- Run this entire file as one job. Existing v2 inputs are read only.
-- Original comments below describe recovered historical scripts, not current counts.

-- ============================================================================
-- FULL DELIVERY REBUILD AFTER GEO-CORRECTED PREGNANCY CANONICALIZATION
-- Project: spheres-lombok-barat
-- Dataset: kohort_bumil_v2
--
-- RUN AFTER:
--   t_pregnancy_episode_spine_v3_3            = 38,497 current canonical rows
--   t_pregnancy_outcome_events_v3_3           = rebuilt geo-fixed Stage 5
--   t_pregnancy_outcome_tracking_v3_3         = rebuilt geo-fixed Stage 6
--
-- THIS SINGLE BIGQUERY SCRIPT:
--   STEP 2  rebuilds t_delivery_source_records
--   STEP 3A–3I performs ANC-independent delivery deduplication
--   STEP 3 v3 applies strict ANC linkage + safe direct-SIGIZI rescue + post-ANC consolidation
--
-- FINAL OUTPUT:
--   t_delivery_event_master_v3
--
-- IMPORTANT:
--   This script DOES NOT automatically promote v3 to t_delivery_event_master.
--   Review the QA results first.
-- ============================================================================





-- ============================================================================
-- SCRIPT PARAMETERS
-- BigQuery requires every DECLARE statement before the first executable
-- statement in the script.
-- ============================================================================

DECLARE delivery_tolerance_days INT64 DEFAULT 3;
DECLARE fuzzy_delivery_tolerance_days INT64 DEFAULT 1;

DECLARE anc_window_before_days INT64 DEFAULT 30;
DECLARE anc_window_after_days INT64 DEFAULT 350;

DECLARE max_component_iterations INT64 DEFAULT 30;
DECLARE changed_labels INT64 DEFAULT 1;
DECLARE component_iteration INT64 DEFAULT 0;

DECLARE anc_min_days_from_anchor INT64 DEFAULT 126;  -- 18 weeks
DECLARE anc_max_days_from_anchor INT64 DEFAULT 322;  -- 46 weeks
DECLARE post_anc_cluster_span_days INT64 DEFAULT 42;


-- ============================================================================
-- STEP 2 GEO-FIXED
-- REBUILD ONE-ROW-PER-SOURCE DELIVERY RECORDS
--
-- INPUT:
--   t_pregnancy_outcome_events_v3_3
--
-- WHY THIS IS SAFE NOW:
--   Stage 5 was already rebuilt after the SIGIZI geography correction.
--   Therefore SIGIZI puskesmas/desa fields in this event pool use only the
--   resolved geography and do not fall back to the shifted raw fields.
--
-- DELIVERY SPINE RULE:
--   * Keep only rows with a delivery_date.
--   * Abortus-only events are excluded from the delivery-event spine.
--   * A source event may exist without a SIGIZI/ePUS ANC match.
--
-- OUTPUT:
--   t_delivery_source_records
-- ============================================================================

CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_source_records`
PARTITION BY delivery_date
CLUSTER BY
  source_system,
  nik_clean,
  nama_norm
AS

WITH base AS (
  SELECT
    source_system,
    source_subtype,
    source_priority,

    source_event_id,
    source_record_id,
    epus_episode_source_key,

    nik_clean,

    nama AS nama_ibu,
    nama_norm,

    tanggal_lahir AS tanggal_lahir_ibu,
    no_hp_clean,

    -- Re-apply only harmless alias canonicalization.
    CASE
      WHEN UPPER(TRIM(COALESCE(puskesmas_norm, puskesmas, '')))
        IN ('GUNUNG SARI', 'GUNUNGSARI')
        THEN 'GUNUNGSARI'

      WHEN UPPER(TRIM(COALESCE(puskesmas_norm, puskesmas, '')))
        IN ('LABU API', 'LABUAPI')
        THEN 'LABUAPI'

      WHEN REGEXP_CONTAINS(
        UPPER(TRIM(COALESCE(puskesmas_norm, puskesmas, ''))),
        r'^PUSKESMAS\s+'
      )
        THEN REGEXP_REPLACE(
          UPPER(TRIM(COALESCE(puskesmas_norm, puskesmas, ''))),
          r'^PUSKESMAS\s+',
          ''
        )

      ELSE NULLIF(
        UPPER(TRIM(COALESCE(puskesmas_norm, puskesmas, ''))),
        ''
      )
    END AS puskesmas,

    CASE
      WHEN UPPER(TRIM(COALESCE(puskesmas_norm, puskesmas, '')))
        IN ('GUNUNG SARI', 'GUNUNGSARI')
        THEN 'GUNUNGSARI'

      WHEN UPPER(TRIM(COALESCE(puskesmas_norm, puskesmas, '')))
        IN ('LABU API', 'LABUAPI')
        THEN 'LABUAPI'

      WHEN REGEXP_CONTAINS(
        UPPER(TRIM(COALESCE(puskesmas_norm, puskesmas, ''))),
        r'^PUSKESMAS\s+'
      )
        THEN REGEXP_REPLACE(
          UPPER(TRIM(COALESCE(puskesmas_norm, puskesmas, ''))),
          r'^PUSKESMAS\s+',
          ''
        )

      ELSE NULLIF(
        UPPER(TRIM(COALESCE(puskesmas_norm, puskesmas, ''))),
        ''
      )
    END AS puskesmas_norm,

    NULLIF(
      UPPER(TRIM(COALESCE(desa_norm, desa, ''))),
      ''
    ) AS desa,

    NULLIF(
      UPPER(TRIM(COALESCE(desa_norm, desa, ''))),
      ''
    ) AS desa_norm,

    delivery_date,

    CASE
      WHEN pregnancy_outcome_norm IN (
        'LAHIR HIDUP',
        'LAHIR MATI'
      )
        THEN pregnancy_outcome_norm
      ELSE NULL
    END AS delivery_outcome,

    maternal_outcome_norm,
    delivery_mode_norm,
    delivery_facility_norm,

    record_date AS source_reference_date

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_events_v3_3`

  WHERE delivery_date IS NOT NULL

    -- Abortus is not a birth/delivery-event record.
    AND COALESCE(pregnancy_outcome_norm, '') != 'ABORTUS'
)

SELECT *
FROM base;


-- ============================================================================
-- STEP 2 QA
-- ============================================================================

-- QA 2A. Technical source-event keys must be unique.
ASSERT (
  SELECT COUNT(*) = COUNT(DISTINCT source_event_id)
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_delivery_source_records`
)
AS 'Duplicate source_event_id in t_delivery_source_records. Inspect Stage-5 event keys before continuing.';


ASSERT (
  SELECT COUNTIF(source_event_id IS NULL) = 0
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_delivery_source_records`
)
AS 'NULL source_event_id in t_delivery_source_records.';


-- QA 2B. Count source delivery records before canonical delivery dedup.
SELECT
  source_system,
  COUNT(*) AS source_delivery_records,
  COUNTIF(delivery_outcome = 'LAHIR HIDUP') AS live_birth_records,
  COUNTIF(delivery_outcome = 'LAHIR MATI') AS stillbirth_records,
  COUNTIF(delivery_outcome IS NULL) AS outcome_unclear_records
FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_source_records`
GROUP BY source_system
ORDER BY source_delivery_records DESC;


-- QA 2C. Geo-fixed SIGIZI source delivery records must not resurrect the
-- known village/posyandu values as Puskesmas.
SELECT
  puskesmas_norm,
  COUNT(*) AS records
FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_source_records`
WHERE source_system = 'SIGIZI'
  AND puskesmas_norm IN (
    'DINAS KESEHATAN',
    'BAGIK POLAK',
    'BAGIK POLAK BARAT',
    'BANYU URIP',
    'BENGKEL',
    'DASAN TERENG',
    'GELOGOR',
    'GERUNG SELATAN',
    'GERUNG UTARA',
    'JAGARAGA',
    'KURIPAN DESA',
    'KURIPAN SELATAN',
    'KURIPAN TIMUR',
    'KURIPAN UTARA',
    'MEKAR SARI',
    'OMBE BARU',
    'PERESAK',
    'SEMBUNG',
    'TELAGE WARU',
    'TERONG TAWAH'
  )
GROUP BY puskesmas_norm
ORDER BY records DESC;


-- ============================================================================
-- STEP 3A–3I
-- INITIAL DELIVERY DEDUPLICATION, INDEPENDENT OF ANC
--
-- This is the current v2 initial-dedup implementation.
-- It creates:
--   t_delivery_dedup_base
--   t_delivery_pair_features
--   t_delivery_candidate_edges
--   connected-component tables
--   t_delivery_event_member_map
--   t_delivery_event_master_unlinked
--
-- The old broad ANC-linking part of v2 is intentionally NOT run.
-- The stricter v3 ANC linkage follows immediately afterward.
-- ============================================================================

-- ============================================================================
-- STEP 3 - CANONICAL DELIVERY EVENT MASTER + ANC LINKAGE
-- Project: spheres-lombok-barat
-- Dataset: kohort_bumil_v2
--
-- INPUT:
--   t_delivery_source_records
--   t_pregnancy_episode_spine_v3_3
--
-- OUTPUT:
--   t_delivery_event_master
--
-- UNIT OF OUTPUT:
--   1 row = 1 canonical maternal delivery event
--
-- IMPORTANT:
--   * A delivery does NOT need a SIGIZI/ePUS ANC match to exist in this table.
--   * Same-name alone never merges.
--   * Trusted-NIK conflicts block weak delivery deduplication.
--   * Ambiguous ANC links are retained as AMBIGUOUS_ANC_MATCH, not forced.
--   * Abortus is intentionally excluded from this delivery-event spine.
-- ============================================================================


-- ============================================================================
-- PARAMETERS
-- ============================================================================

-- HELPERS
-- ============================================================================

CREATE TEMP FUNCTION nik_is_trusted(s STRING)
RETURNS BOOL
AS (
  s IS NOT NULL
  AND REGEXP_CONTAINS(s, r'^\d{16}$')
  AND s NOT IN ('0000000000000000', '9999999999999999')
  AND RIGHT(s, 4) != '0000'
);

CREATE TEMP FUNCTION nik_hard_conflict(a STRING, b STRING)
RETURNS BOOL
AS (
  nik_is_trusted(a)
  AND nik_is_trusted(b)
  AND a != b
);

CREATE TEMP FUNCTION compact_name(s STRING)
RETURNS STRING
AS (
  NULLIF(
    REGEXP_REPLACE(
      UPPER(TRIM(NORMALIZE(COALESCE(s, ''), NFKC))),
      r'[^A-Z0-9]',
      ''
    ),
    ''
  )
);


-- ============================================================================
-- 3A. PREPARE DELIVERY RECORDS FOR DEDUPLICATION
-- ============================================================================

CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_dedup_base`
CLUSTER BY nik_clean, puskesmas_norm, delivery_date
AS

SELECT
  d.*,

  compact_name(
    COALESCE(
      nama_norm,
      nama_ibu
    )
  ) AS nama_compact_norm,

  nik_is_trusted(nik_clean)
    AS nik_trusted_flag,

  (
      IF(nik_is_trusted(nik_clean), 100, IF(nik_clean IS NOT NULL, 5, 0))
    + IF(tanggal_lahir_ibu IS NOT NULL, 25, 0)
    + IF(no_hp_clean IS NOT NULL AND LENGTH(no_hp_clean) >= 8, 20, 0)
    + IF(nama_norm IS NOT NULL, 10, 0)
    + IF(puskesmas_norm IS NOT NULL, 5, 0)
    + IF(desa_norm IS NOT NULL, 3, 0)
    + IF(delivery_outcome IS NOT NULL, 5, 0)
    + GREATEST(0, 15 - COALESCE(source_priority, 15))
  ) AS delivery_record_quality_score

FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_source_records` d

WHERE delivery_date IS NOT NULL;


-- Do not silently continue if the technical event key is not unique.
ASSERT (
  SELECT COUNT(*) = COUNT(DISTINCT source_event_id)
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_delivery_dedup_base`
)
AS 't_delivery_source_records has duplicate source_event_id values. Fix Step 2 before running delivery canonicalization.';

ASSERT (
  SELECT COUNTIF(source_event_id IS NULL) = 0
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_delivery_dedup_base`
)
AS 't_delivery_source_records contains NULL source_event_id values. Fix Step 2 before running delivery canonicalization.';


-- ============================================================================
-- 3B. MATERIALIZE PAIR-LEVEL DELIVERY EVIDENCE
--
-- The self-join is blocked by:
--   * close delivery date, AND
--   * exact NIK / compact name / phone / DOB+location signal.
--
-- This avoids a full cartesian comparison.
-- ============================================================================

CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_pair_features`
CLUSTER BY event_a_id, event_b_id
AS

SELECT
  a.source_event_id AS event_a_id,
  b.source_event_id AS event_b_id,

  a.source_system AS source_system_a,
  b.source_system AS source_system_b,

  a.nik_clean AS nik_a,
  b.nik_clean AS nik_b,

  a.nama_ibu AS nama_a,
  b.nama_ibu AS nama_b,

  a.nama_norm AS nama_norm_a,
  b.nama_norm AS nama_norm_b,

  a.nama_compact_norm AS nama_compact_a,
  b.nama_compact_norm AS nama_compact_b,

  a.tanggal_lahir_ibu AS dob_a,
  b.tanggal_lahir_ibu AS dob_b,

  a.no_hp_clean AS phone_a,
  b.no_hp_clean AS phone_b,

  a.puskesmas_norm AS puskesmas_a,
  b.puskesmas_norm AS puskesmas_b,

  a.desa_norm AS desa_a,
  b.desa_norm AS desa_b,

  a.delivery_date AS delivery_date_a,
  b.delivery_date AS delivery_date_b,

  ABS(
    DATE_DIFF(
      a.delivery_date,
      b.delivery_date,
      DAY
    )
  ) AS delivery_difference_days,

  -- NIK evidence
  CASE
    WHEN a.nik_clean IS NULL AND b.nik_clean IS NULL
      THEN 'BOTH_MISSING'
    WHEN a.nik_clean IS NULL OR b.nik_clean IS NULL
      THEN 'MISSING_ONE_SIDE'
    WHEN a.nik_clean = b.nik_clean
      THEN 'MATCH'
    WHEN nik_hard_conflict(a.nik_clean, b.nik_clean)
      THEN 'TRUSTED_CONFLICT'
    ELSE 'UNTRUSTED_CONFLICT'
  END AS nik_match_state,

  nik_hard_conflict(a.nik_clean, b.nik_clean)
    AS trusted_nik_conflict_flag,

  -- Name evidence
  (
    a.nama_norm IS NOT NULL
    AND b.nama_norm IS NOT NULL
    AND a.nama_norm = b.nama_norm
  ) AS exact_name_match,

  (
    a.nama_compact_norm IS NOT NULL
    AND b.nama_compact_norm IS NOT NULL
    AND a.nama_compact_norm = b.nama_compact_norm
  ) AS compact_name_match,

  CASE
    WHEN
      a.nama_compact_norm IS NOT NULL
      AND b.nama_compact_norm IS NOT NULL
    THEN EDIT_DISTANCE(
      a.nama_compact_norm,
      b.nama_compact_norm
    )
  END AS name_edit_distance,

  (
    a.nama_compact_norm IS NOT NULL
    AND b.nama_compact_norm IS NOT NULL

    AND LEAST(
      LENGTH(a.nama_compact_norm),
      LENGTH(b.nama_compact_norm)
    ) >= 5

    AND EDIT_DISTANCE(
      a.nama_compact_norm,
      b.nama_compact_norm
    )
    <= CASE
         WHEN GREATEST(
           LENGTH(a.nama_compact_norm),
           LENGTH(b.nama_compact_norm)
         ) <= 8
           THEN 1
         ELSE 2
       END
  ) AS fuzzy_name_match,

  -- DOB evidence
  CASE
    WHEN
      a.tanggal_lahir_ibu IS NULL
      AND b.tanggal_lahir_ibu IS NULL
      THEN 'BOTH_MISSING'

    WHEN
      a.tanggal_lahir_ibu IS NULL
      OR b.tanggal_lahir_ibu IS NULL
      THEN 'MISSING_ONE_SIDE'

    WHEN
      a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
      THEN 'MATCH'

    ELSE 'CONFLICT'
  END AS dob_match_state,

  (
    a.no_hp_clean IS NOT NULL
    AND LENGTH(a.no_hp_clean) >= 8
    AND a.no_hp_clean = b.no_hp_clean
  ) AS phone_match,

  (
    a.puskesmas_norm IS NOT NULL
    AND a.puskesmas_norm = b.puskesmas_norm
  ) AS puskesmas_match,

  (
    a.desa_norm IS NOT NULL
    AND a.desa_norm = b.desa_norm
  ) AS desa_match,

  (
      IF(
        a.no_hp_clean IS NOT NULL
        AND LENGTH(a.no_hp_clean) >= 8
        AND a.no_hp_clean = b.no_hp_clean,
        1,
        0
      )
    + IF(
        a.puskesmas_norm IS NOT NULL
        AND a.puskesmas_norm = b.puskesmas_norm,
        1,
        0
      )
    + IF(
        a.desa_norm IS NOT NULL
        AND a.desa_norm = b.desa_norm,
        1,
        0
      )
  ) AS corroborator_count

FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_dedup_base` a

JOIN
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_dedup_base` b

  ON a.source_event_id < b.source_event_id

 AND ABS(
   DATE_DIFF(
     a.delivery_date,
     b.delivery_date,
     DAY
   )
 ) <= delivery_tolerance_days

 AND (
      (
        a.nik_clean IS NOT NULL
        AND a.nik_clean = b.nik_clean
      )

   OR (
        a.nama_compact_norm IS NOT NULL
        AND a.nama_compact_norm = b.nama_compact_norm
      )

   OR (
        a.no_hp_clean IS NOT NULL
        AND LENGTH(a.no_hp_clean) >= 8
        AND a.no_hp_clean = b.no_hp_clean
      )

   OR (
        a.tanggal_lahir_ibu IS NOT NULL
        AND a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
        AND (
             (
               a.puskesmas_norm IS NOT NULL
               AND a.puskesmas_norm = b.puskesmas_norm
             )
          OR (
               a.desa_norm IS NOT NULL
               AND a.desa_norm = b.desa_norm
             )
        )
      )
 );


-- ============================================================================
-- 3C. ACCEPT ONLY HIGH-SPECIFICITY DELIVERY-DUPLICATE EDGES
--
-- No rule below is allowed to override a trusted-vs-trusted NIK conflict.
-- We do NOT have HPHT/HPL in the delivery-event dedup layer, so this layer is
-- intentionally more conservative than pregnancy-episode canonicalization.
-- ============================================================================

CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_candidate_edges`
CLUSTER BY event_a_id, event_b_id
AS

WITH classified AS (
  SELECT
    f.*,

    CASE

      -- ------------------------------------------------------
      -- 1. Exact trusted NIK + close delivery date
      -- ------------------------------------------------------
      WHEN
        nik_match_state = 'MATCH'
        AND nik_is_trusted(nik_a)
        AND delivery_difference_days <= delivery_tolerance_days
      THEN 'DELIVERY_NIK_EXACT_TRUSTED+DATE_3D'


      -- ------------------------------------------------------
      -- 2. Exact but untrusted NIK needs supporting identity
      -- ------------------------------------------------------
      WHEN
        nik_match_state = 'MATCH'
        AND NOT nik_is_trusted(nik_a)
        AND delivery_difference_days <= delivery_tolerance_days
        AND (
          exact_name_match
          OR compact_name_match
          OR dob_match_state = 'MATCH'
          OR phone_match
        )
      THEN 'DELIVERY_NIK_EXACT_UNTRUSTED+CORROBORATOR+DATE_3D'


      -- ------------------------------------------------------
      -- 3. Strong maternal identity: name + DOB
      -- ------------------------------------------------------
      WHEN
        NOT trusted_nik_conflict_flag
        AND (exact_name_match OR compact_name_match)
        AND dob_match_state = 'MATCH'
        AND delivery_difference_days <= delivery_tolerance_days
      THEN 'DELIVERY_NAME+DOB+DATE_3D'


      -- ------------------------------------------------------
      -- 4. Phone + DOB + compatible/fuzzy name
      -- ------------------------------------------------------
      WHEN
        NOT trusted_nik_conflict_flag
        AND phone_match
        AND dob_match_state = 'MATCH'
        AND (
          exact_name_match
          OR compact_name_match
          OR fuzzy_name_match
        )
        AND delivery_difference_days <= delivery_tolerance_days
      THEN 'DELIVERY_PHONE+DOB+NAME+DATE_3D'


      -- ------------------------------------------------------
      -- 5. Missing DOB rescue: name + phone
      -- ------------------------------------------------------
      WHEN
        NOT trusted_nik_conflict_flag
        AND (exact_name_match OR compact_name_match)
        AND dob_match_state IN ('MISSING_ONE_SIDE', 'BOTH_MISSING')
        AND phone_match
        AND delivery_difference_days <= delivery_tolerance_days
      THEN 'DELIVERY_NAME+PHONE+DOB_MISSING+DATE_3D'


      -- ------------------------------------------------------
      -- 6. Missing DOB rescue: exact date + location
      -- ------------------------------------------------------
      WHEN
        NOT trusted_nik_conflict_flag
        AND (exact_name_match OR compact_name_match)
        AND dob_match_state IN ('MISSING_ONE_SIDE', 'BOTH_MISSING')
        AND delivery_difference_days = 0
        AND (
          puskesmas_match
          OR desa_match
        )
      THEN 'DELIVERY_NAME+DOB_MISSING+DATE_EXACT+LOCATION'


      -- ------------------------------------------------------
      -- 7. Controlled fuzzy-name rescue
      -- ------------------------------------------------------
      WHEN
        NOT trusted_nik_conflict_flag
        AND fuzzy_name_match
        AND dob_match_state = 'MATCH'
        AND delivery_difference_days <= fuzzy_delivery_tolerance_days
        AND corroborator_count >= 1
      THEN 'DELIVERY_FUZZY_NAME+DOB+DATE_1D+CORROBORATOR'

    END AS delivery_merge_method,

    CASE
      WHEN
        nik_match_state = 'MATCH'
        AND nik_is_trusted(nik_a)
        AND delivery_difference_days <= delivery_tolerance_days
        THEN 1

      WHEN
        nik_match_state = 'MATCH'
        AND NOT nik_is_trusted(nik_a)
        AND delivery_difference_days <= delivery_tolerance_days
        AND (
          exact_name_match
          OR compact_name_match
          OR dob_match_state = 'MATCH'
          OR phone_match
        )
        THEN 2

      WHEN
        NOT trusted_nik_conflict_flag
        AND (exact_name_match OR compact_name_match)
        AND dob_match_state = 'MATCH'
        AND delivery_difference_days <= delivery_tolerance_days
        THEN 3

      WHEN
        NOT trusted_nik_conflict_flag
        AND phone_match
        AND dob_match_state = 'MATCH'
        AND (
          exact_name_match
          OR compact_name_match
          OR fuzzy_name_match
        )
        AND delivery_difference_days <= delivery_tolerance_days
        THEN 4

      WHEN
        NOT trusted_nik_conflict_flag
        AND (exact_name_match OR compact_name_match)
        AND dob_match_state IN ('MISSING_ONE_SIDE', 'BOTH_MISSING')
        AND phone_match
        AND delivery_difference_days <= delivery_tolerance_days
        THEN 5

      WHEN
        NOT trusted_nik_conflict_flag
        AND (exact_name_match OR compact_name_match)
        AND dob_match_state IN ('MISSING_ONE_SIDE', 'BOTH_MISSING')
        AND delivery_difference_days = 0
        AND (
          puskesmas_match
          OR desa_match
        )
        THEN 6

      WHEN
        NOT trusted_nik_conflict_flag
        AND fuzzy_name_match
        AND dob_match_state = 'MATCH'
        AND delivery_difference_days <= fuzzy_delivery_tolerance_days
        AND corroborator_count >= 1
        THEN 7
    END AS delivery_merge_priority,

    CASE
      WHEN
        nik_match_state = 'MATCH'
        AND nik_is_trusted(nik_a)
        THEN 'VERY_HIGH'

      WHEN
        (exact_name_match OR compact_name_match)
        AND dob_match_state = 'MATCH'
        THEN 'VERY_HIGH'

      WHEN
        phone_match
        AND dob_match_state = 'MATCH'
        THEN 'VERY_HIGH'

      WHEN fuzzy_name_match
        THEN 'HIGH'

      ELSE 'HIGH'
    END AS delivery_merge_confidence,

    (
      fuzzy_name_match
      OR dob_match_state IN ('MISSING_ONE_SIDE', 'BOTH_MISSING')
      OR nik_match_state = 'UNTRUSTED_CONFLICT'
    ) AS delivery_merge_qa_required

  FROM
    `_SESSION.t_delivery_pair_features` f
)

SELECT
  *
FROM classified
WHERE delivery_merge_method IS NOT NULL;


-- ============================================================================
-- 3D. BUILD UNDIRECTED EDGE LIST
-- ============================================================================

CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_component_edges`
CLUSTER BY source_event_id, neighbor_event_id
AS

SELECT
  event_a_id AS source_event_id,
  event_b_id AS neighbor_event_id,
  delivery_merge_method,
  delivery_merge_priority,
  delivery_merge_confidence,
  delivery_merge_qa_required
FROM
  `_SESSION.t_delivery_candidate_edges`

UNION ALL

SELECT
  event_b_id,
  event_a_id,
  delivery_merge_method,
  delivery_merge_priority,
  delivery_merge_confidence,
  delivery_merge_qa_required
FROM
  `_SESSION.t_delivery_candidate_edges`;


-- ============================================================================
-- 3E. CONNECTED-COMPONENT LABEL PROPAGATION
--
-- This resolves transitive duplicates:
--   SIMRS <-> Tracker <-> ePUS
-- even when every source pair is not directly comparable.
-- ============================================================================

CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_component_labels`
CLUSTER BY source_event_id
AS

SELECT
  source_event_id,
  source_event_id AS component_label
FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_dedup_base`;


LOOP

  SET component_iteration = component_iteration + 1;

  CREATE OR REPLACE TEMP TABLE
    `_SESSION.t_delivery_component_labels_next`
  CLUSTER BY source_event_id
  AS

  SELECT
    l.source_event_id,

    LEAST(
      l.component_label,
      COALESCE(
        MIN(n.component_label),
        l.component_label
      )
    ) AS component_label

  FROM
    `_SESSION.t_delivery_component_labels` l

  LEFT JOIN
    `_SESSION.t_delivery_component_edges` e
    ON e.source_event_id = l.source_event_id

  LEFT JOIN
    `_SESSION.t_delivery_component_labels` n
    ON n.source_event_id = e.neighbor_event_id

  GROUP BY
    l.source_event_id,
    l.component_label;


  SET changed_labels = (
    SELECT COUNTIF(previous_component_label != updated_component_label)
    FROM (
      SELECT
        a.source_event_id,
        a.component_label AS previous_component_label,
        b.component_label AS updated_component_label
      FROM
        `_SESSION.t_delivery_component_labels` AS a
      INNER JOIN
        `_SESSION.t_delivery_component_labels_next` AS b
        USING (source_event_id)
    )
  );


  CREATE OR REPLACE TEMP TABLE
    `_SESSION.t_delivery_component_labels`
  CLUSTER BY source_event_id
  AS

  SELECT *
  FROM
    `_SESSION.t_delivery_component_labels_next`;


  IF changed_labels = 0
     OR component_iteration >= max_component_iterations
  THEN
    LEAVE;
  END IF;

END LOOP;


ASSERT changed_labels = 0
AS 'Delivery connected-component propagation did not converge within max_component_iterations. Increase the limit or inspect unusually large duplicate components.';


-- ============================================================================
-- 3F. COMPONENT SAFETY GUARD
--
-- Pairwise weak rules already block trusted NIK conflict, but a transitive
-- bridge could theoretically connect:
--
--   trusted NIK A <-> missing NIK <-> trusted NIK B
--
-- Therefore, any resulting component containing >1 distinct TRUSTED NIK is
-- NOT auto-collapsed. Its members remain separate delivery events for QA.
-- ============================================================================

CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_component_stats`
CLUSTER BY component_label
AS

SELECT
  l.component_label,

  COUNT(*) AS component_member_count,

  COUNT(
    DISTINCT IF(
      b.nik_trusted_flag,
      b.nik_clean,
      NULL
    )
  ) AS trusted_nik_count,

  ARRAY_AGG(
    DISTINCT IF(
      b.nik_trusted_flag,
      b.nik_clean,
      NULL
    )
    IGNORE NULLS
    ORDER BY IF(
      b.nik_trusted_flag,
      b.nik_clean,
      NULL
    )
  ) AS trusted_nik_values

FROM
  `_SESSION.t_delivery_component_labels` l

JOIN
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_dedup_base` b
  USING (source_event_id)

GROUP BY
  l.component_label;


-- ============================================================================
-- 3G. SOURCE RECORD -> CANONICAL DELIVERY EVENT MAP
-- ============================================================================

CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_member_map`
CLUSTER BY delivery_event_id, source_event_id
AS

WITH mapped AS (
  SELECT
    l.source_event_id,

    l.component_label
      AS raw_component_label,

    s.component_member_count,
    s.trusted_nik_count,
    s.trusted_nik_values,

    s.trusted_nik_count > 1
      AS component_trusted_nik_conflict_flag,

    CASE
      WHEN s.trusted_nik_count > 1
        THEN CONCAT(
          'SELF|',
          l.source_event_id
        )
      ELSE l.component_label
    END AS final_component_label

  FROM
    `_SESSION.t_delivery_component_labels` l

  JOIN
    `_SESSION.t_delivery_component_stats` s
    USING (component_label)
)

SELECT
  source_event_id,

  raw_component_label,
  final_component_label,

  CONCAT(
    'BIRTH_',
    TO_HEX(
      SHA256(final_component_label)
    )
  ) AS delivery_event_id,

  component_member_count
    AS raw_component_member_count,

  trusted_nik_count
    AS raw_component_trusted_nik_count,

  trusted_nik_values
    AS raw_component_trusted_nik_values,

  component_trusted_nik_conflict_flag

FROM mapped;


-- ============================================================================
-- 3H. MERGE METHODS USED INSIDE EACH SAFE FINAL EVENT
-- ============================================================================

CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_event_merge_methods`
CLUSTER BY delivery_event_id
AS

SELECT
  ma.delivery_event_id,

  ARRAY_AGG(
    DISTINCT e.delivery_merge_method
    ORDER BY e.delivery_merge_method
  ) AS delivery_merge_methods,

  MIN(e.delivery_merge_priority)
    AS best_delivery_merge_priority,

  LOGICAL_OR(e.delivery_merge_qa_required)
    AS any_delivery_merge_qa_required

FROM
  `_SESSION.t_delivery_candidate_edges` e

JOIN
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_member_map` ma
  ON ma.source_event_id = e.event_a_id

JOIN
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_member_map` mb
  ON mb.source_event_id = e.event_b_id

WHERE
  ma.delivery_event_id = mb.delivery_event_id

GROUP BY
  ma.delivery_event_id;


-- ============================================================================
-- 3I. BUILD CANONICAL DELIVERY EVENT - UNLINKED TO ANC
-- ============================================================================

CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_unlinked`
PARTITION BY delivery_date
CLUSTER BY nik_clean, puskesmas_norm, delivery_event_id
AS

WITH grouped AS (
  SELECT
    m.delivery_event_id,

    COUNT(*) AS source_record_count,
    COUNT(DISTINCT b.source_system) AS source_system_count,

    ARRAY_AGG(
      b.source_event_id
      ORDER BY b.source_system, b.source_event_id
    ) AS source_event_ids,

    ARRAY_AGG(
      DISTINCT b.source_record_id
      IGNORE NULLS
      ORDER BY b.source_record_id
    ) AS source_record_ids,

    ARRAY_AGG(
      DISTINCT b.source_system
      ORDER BY b.source_system
    ) AS delivery_source_systems,

    STRING_AGG(
      DISTINCT b.source_system,
      ' + '
      ORDER BY b.source_system
    ) AS delivery_source_combination,

    ARRAY_AGG(
      DISTINCT b.source_subtype
      IGNORE NULLS
      ORDER BY b.source_subtype
    ) AS delivery_source_subtypes,

    ARRAY_AGG(
      DISTINCT b.epus_episode_source_key
      IGNORE NULLS
      ORDER BY b.epus_episode_source_key
    ) AS epus_episode_source_keys,

    -- --------------------------------------------------------
    -- Canonical identity picks
    -- --------------------------------------------------------

    ARRAY_AGG(
      IF(
        b.nik_clean IS NOT NULL,
        STRUCT(
          b.nik_clean AS value,
          b.source_system AS source_system,
          b.source_priority AS source_priority,
          nik_is_trusted(b.nik_clean) AS trusted
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY
        IF(nik_is_trusted(b.nik_clean), 0, 1),
        b.source_priority,
        b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS nik_pick,

    ARRAY_AGG(
      IF(
        b.nama_ibu IS NOT NULL,
        STRUCT(
          b.nama_ibu AS value,
          b.nama_norm AS value_norm,
          b.nama_compact_norm AS value_compact,
          b.source_system AS source_system,
          b.source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY
        b.delivery_record_quality_score DESC,
        b.source_priority,
        b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS name_pick,

    ARRAY_AGG(
      IF(
        b.tanggal_lahir_ibu IS NOT NULL,
        STRUCT(
          b.tanggal_lahir_ibu AS value,
          b.source_system AS source_system,
          b.source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY
        b.delivery_record_quality_score DESC,
        b.source_priority,
        b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS dob_pick,

    ARRAY_AGG(
      IF(
        b.no_hp_clean IS NOT NULL
        AND LENGTH(b.no_hp_clean) >= 8,
        STRUCT(
          b.no_hp_clean AS value,
          b.source_system AS source_system,
          b.source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY
        b.delivery_record_quality_score DESC,
        b.source_priority,
        b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS phone_pick,

    ARRAY_AGG(
      IF(
        b.puskesmas IS NOT NULL,
        STRUCT(
          b.puskesmas AS value,
          b.puskesmas_norm AS value_norm,
          b.source_system AS source_system,
          b.source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY
        b.source_priority,
        b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS puskesmas_pick,

    ARRAY_AGG(
      IF(
        b.desa IS NOT NULL,
        STRUCT(
          b.desa AS value,
          b.desa_norm AS value_norm,
          b.source_system AS source_system,
          b.source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY
        b.source_priority,
        b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS desa_pick,

    -- --------------------------------------------------------
    -- Canonical delivery date
    -- Follow existing source_priority hierarchy.
    -- --------------------------------------------------------

    ARRAY_AGG(
      STRUCT(
        b.delivery_date AS value,
        b.source_system AS source_system,
        b.source_subtype AS source_subtype,
        b.source_priority AS source_priority,
        b.source_event_id AS source_event_id
      )
      ORDER BY
        b.source_priority,
        b.delivery_date,
        b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS delivery_pick,

    -- --------------------------------------------------------
    -- Canonical explicit outcome source
    -- Overall outcome classification below uses all evidence.
    -- --------------------------------------------------------

    ARRAY_AGG(
      IF(
        b.delivery_outcome IS NOT NULL,
        STRUCT(
          b.delivery_outcome AS value,
          b.source_system AS source_system,
          b.source_subtype AS source_subtype,
          b.source_priority AS source_priority,
          b.source_event_id AS source_event_id
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY
        b.source_priority,
        b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS outcome_pick,

    -- --------------------------------------------------------
    -- Canonical maternal/delivery descriptors
    -- --------------------------------------------------------

    ARRAY_AGG(
      IF(
        b.maternal_outcome_norm IS NOT NULL,
        STRUCT(
          b.maternal_outcome_norm AS value,
          b.source_system AS source_system,
          b.source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY b.source_priority, b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS maternal_outcome_pick,

    ARRAY_AGG(
      IF(
        b.delivery_mode_norm IS NOT NULL,
        STRUCT(
          b.delivery_mode_norm AS value,
          b.source_system AS source_system,
          b.source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY b.source_priority, b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS delivery_mode_pick,

    ARRAY_AGG(
      IF(
        b.delivery_facility_norm IS NOT NULL,
        STRUCT(
          b.delivery_facility_norm AS value,
          b.source_system AS source_system,
          b.source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY b.source_priority, b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS delivery_facility_pick,

    -- --------------------------------------------------------
    -- All observed values / conflict metadata
    -- --------------------------------------------------------

    ARRAY_AGG(
      DISTINCT b.nik_clean
      IGNORE NULLS
      ORDER BY b.nik_clean
    ) AS all_nik_values,

    ARRAY_AGG(
      DISTINCT CAST(b.tanggal_lahir_ibu AS STRING)
      IGNORE NULLS
      ORDER BY CAST(b.tanggal_lahir_ibu AS STRING)
    ) AS all_dob_values,

    ARRAY_AGG(
      DISTINCT b.nama_ibu
      IGNORE NULLS
      ORDER BY b.nama_ibu
    ) AS all_name_values,

    ARRAY_AGG(
      DISTINCT b.nama_compact_norm
      IGNORE NULLS
      ORDER BY b.nama_compact_norm
    ) AS all_compact_name_values,

    ARRAY_AGG(
      DISTINCT CAST(b.delivery_date AS STRING)
      ORDER BY CAST(b.delivery_date AS STRING)
    ) AS all_delivery_dates,

    COUNT(DISTINCT b.delivery_date)
      AS delivery_date_distinct_count,

    MIN(b.delivery_date)
      AS min_delivery_date,

    MAX(b.delivery_date)
      AS max_delivery_date,

    COUNT(
      DISTINCT IF(
        b.nik_trusted_flag,
        b.nik_clean,
        NULL
      )
    ) AS trusted_nik_distinct_count,

    COUNT(DISTINCT b.tanggal_lahir_ibu)
      AS dob_distinct_count,

    COUNT(DISTINCT b.nama_compact_norm)
      AS compact_name_distinct_count,

    -- --------------------------------------------------------
    -- Overall outcome evidence
    -- --------------------------------------------------------

    LOGICAL_OR(
      b.delivery_outcome = 'LAHIR HIDUP'
    ) AS has_live_birth_evidence,

    LOGICAL_OR(
      b.delivery_outcome = 'LAHIR MATI'
    ) AS has_stillbirth_evidence,

    -- --------------------------------------------------------
    -- Presence by source
    -- --------------------------------------------------------

    LOGICAL_OR(b.source_system = 'SIGIZI')
      AS has_delivery_sigizi,

    LOGICAL_OR(b.source_system = 'EPUS')
      AS has_delivery_epus,

    LOGICAL_OR(b.source_system = 'SIMRS')
      AS has_delivery_simrs,

    LOGICAL_OR(b.source_system = 'KOBO_INC')
      AS has_delivery_kobo_inc,

    LOGICAL_OR(b.source_system = 'NEONATAL_OUTCOME')
      AS has_delivery_neonatal,

    LOGICAL_OR(b.source_system = 'INC_REPORT_TRACKER')
      AS has_delivery_inc_report,

    -- --------------------------------------------------------
    -- Source-specific outcome evidence
    -- --------------------------------------------------------

    LOGICAL_OR(
      b.source_system = 'SIGIZI'
      AND b.delivery_outcome = 'LAHIR HIDUP'
    ) AS sigizi_live_evidence,

    LOGICAL_OR(
      b.source_system = 'SIGIZI'
      AND b.delivery_outcome = 'LAHIR MATI'
    ) AS sigizi_still_evidence,

    LOGICAL_OR(
      b.source_system = 'EPUS'
      AND b.delivery_outcome = 'LAHIR HIDUP'
    ) AS epus_live_evidence,

    LOGICAL_OR(
      b.source_system = 'EPUS'
      AND b.delivery_outcome = 'LAHIR MATI'
    ) AS epus_still_evidence,

    LOGICAL_OR(
      b.source_system = 'SIMRS'
      AND b.delivery_outcome = 'LAHIR HIDUP'
    ) AS simrs_live_evidence,

    LOGICAL_OR(
      b.source_system = 'SIMRS'
      AND b.delivery_outcome = 'LAHIR MATI'
    ) AS simrs_still_evidence,

    LOGICAL_OR(
      b.source_system = 'KOBO_INC'
      AND b.delivery_outcome = 'LAHIR HIDUP'
    ) AS kobo_live_evidence,

    LOGICAL_OR(
      b.source_system = 'KOBO_INC'
      AND b.delivery_outcome = 'LAHIR MATI'
    ) AS kobo_still_evidence,

    LOGICAL_OR(
      b.source_system = 'NEONATAL_OUTCOME'
      AND b.delivery_outcome = 'LAHIR HIDUP'
    ) AS neonatal_live_evidence,

    LOGICAL_OR(
      b.source_system = 'NEONATAL_OUTCOME'
      AND b.delivery_outcome = 'LAHIR MATI'
    ) AS neonatal_still_evidence,

    LOGICAL_OR(
      b.source_system = 'INC_REPORT_TRACKER'
      AND b.delivery_outcome = 'LAHIR HIDUP'
    ) AS tracker_live_evidence,

    LOGICAL_OR(
      b.source_system = 'INC_REPORT_TRACKER'
      AND b.delivery_outcome = 'LAHIR MATI'
    ) AS tracker_still_evidence,

    -- --------------------------------------------------------
    -- Earliest source reference date for future timeliness work
    -- NOT treated as a true source input timestamp.
    -- --------------------------------------------------------

    MIN(b.source_reference_date)
      AS earliest_source_reference_date

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_member_map` m

  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_dedup_base` b
    USING (source_event_id)

  GROUP BY
    m.delivery_event_id
),

projected AS (
  SELECT
    g.delivery_event_id,

    g.source_record_count,
    g.source_system_count,
    g.source_event_ids,
    g.source_record_ids,

    g.delivery_source_systems,
    g.delivery_source_combination,
    g.delivery_source_subtypes,
    g.epus_episode_source_keys,

    g.nik_pick.value
      AS nik_clean,

    g.nik_pick.source_system
      AS nik_source,

    g.name_pick.value
      AS nama_ibu,

    g.name_pick.value_norm
      AS nama_norm,

    g.name_pick.value_compact
      AS nama_compact_norm,

    g.name_pick.source_system
      AS nama_source,

    g.dob_pick.value
      AS tanggal_lahir_ibu,

    g.dob_pick.source_system
      AS dob_source,

    g.phone_pick.value
      AS no_hp_clean,

    g.phone_pick.source_system
      AS phone_source,

    g.puskesmas_pick.value
      AS puskesmas,

    g.puskesmas_pick.value_norm
      AS puskesmas_norm,

    g.puskesmas_pick.source_system
      AS puskesmas_source,

    g.desa_pick.value
      AS desa,

    g.desa_pick.value_norm
      AS desa_norm,

    g.desa_pick.source_system
      AS desa_source,

    g.delivery_pick.value
      AS delivery_date,

    g.delivery_pick.source_system
      AS primary_delivery_source,

    g.delivery_pick.source_subtype
      AS primary_delivery_source_subtype,

    g.delivery_pick.source_event_id
      AS primary_delivery_source_event_id,

    CASE
      WHEN
        g.has_live_birth_evidence
        AND g.has_stillbirth_evidence
        THEN 'MIXED_LIVE_STILLBIRTH'

      WHEN g.has_stillbirth_evidence
        THEN 'LAHIR MATI'

      WHEN g.has_live_birth_evidence
        THEN 'LAHIR HIDUP'

      ELSE 'DELIVERY_OUTCOME_UNCLEAR'
    END AS delivery_outcome_final,

    g.outcome_pick.value
      AS primary_explicit_outcome,

    g.outcome_pick.source_system
      AS primary_outcome_source,

    g.maternal_outcome_pick.value
      AS maternal_outcome_final,

    g.maternal_outcome_pick.source_system
      AS maternal_outcome_source,

    g.delivery_mode_pick.value
      AS delivery_mode_final,

    g.delivery_mode_pick.source_system
      AS delivery_mode_source,

    g.delivery_facility_pick.value
      AS delivery_facility_final,

    g.delivery_facility_pick.source_system
      AS delivery_facility_source,

    g.has_live_birth_evidence,
    g.has_stillbirth_evidence,

    g.has_delivery_sigizi,
    g.has_delivery_epus,
    g.has_delivery_simrs,
    g.has_delivery_kobo_inc,
    g.has_delivery_neonatal,
    g.has_delivery_inc_report,

    CASE
      WHEN NOT g.has_delivery_sigizi
        THEN NULL
      WHEN g.sigizi_live_evidence AND g.sigizi_still_evidence
        THEN 'MIXED_LIVE_STILLBIRTH'
      WHEN g.sigizi_still_evidence
        THEN 'LAHIR MATI'
      WHEN g.sigizi_live_evidence
        THEN 'LAHIR HIDUP'
      ELSE 'DELIVERY_OUTCOME_UNCLEAR'
    END AS sigizi_delivery_outcome,

    CASE
      WHEN NOT g.has_delivery_epus
        THEN NULL
      WHEN g.epus_live_evidence AND g.epus_still_evidence
        THEN 'MIXED_LIVE_STILLBIRTH'
      WHEN g.epus_still_evidence
        THEN 'LAHIR MATI'
      WHEN g.epus_live_evidence
        THEN 'LAHIR HIDUP'
      ELSE 'DELIVERY_OUTCOME_UNCLEAR'
    END AS epus_delivery_outcome,

    CASE
      WHEN NOT g.has_delivery_simrs
        THEN NULL
      WHEN g.simrs_live_evidence AND g.simrs_still_evidence
        THEN 'MIXED_LIVE_STILLBIRTH'
      WHEN g.simrs_still_evidence
        THEN 'LAHIR MATI'
      WHEN g.simrs_live_evidence
        THEN 'LAHIR HIDUP'
      ELSE 'DELIVERY_OUTCOME_UNCLEAR'
    END AS simrs_delivery_outcome,

    CASE
      WHEN NOT g.has_delivery_kobo_inc
        THEN NULL
      WHEN g.kobo_live_evidence AND g.kobo_still_evidence
        THEN 'MIXED_LIVE_STILLBIRTH'
      WHEN g.kobo_still_evidence
        THEN 'LAHIR MATI'
      WHEN g.kobo_live_evidence
        THEN 'LAHIR HIDUP'
      ELSE 'DELIVERY_OUTCOME_UNCLEAR'
    END AS kobo_delivery_outcome,

    CASE
      WHEN NOT g.has_delivery_neonatal
        THEN NULL
      WHEN g.neonatal_live_evidence AND g.neonatal_still_evidence
        THEN 'MIXED_LIVE_STILLBIRTH'
      WHEN g.neonatal_still_evidence
        THEN 'LAHIR MATI'
      WHEN g.neonatal_live_evidence
        THEN 'LAHIR HIDUP'
      ELSE 'DELIVERY_OUTCOME_UNCLEAR'
    END AS neonatal_delivery_outcome,

    CASE
      WHEN NOT g.has_delivery_inc_report
        THEN NULL
      WHEN g.tracker_live_evidence AND g.tracker_still_evidence
        THEN 'MIXED_LIVE_STILLBIRTH'
      WHEN g.tracker_still_evidence
        THEN 'LAHIR MATI'
      WHEN g.tracker_live_evidence
        THEN 'LAHIR HIDUP'
      ELSE 'DELIVERY_OUTCOME_UNCLEAR'
    END AS inc_report_delivery_outcome,

    g.all_nik_values,
    g.all_dob_values,
    g.all_name_values,
    g.all_compact_name_values,
    g.all_delivery_dates,

    g.delivery_date_distinct_count,
    g.min_delivery_date,
    g.max_delivery_date,

    g.trusted_nik_distinct_count,
    g.dob_distinct_count,
    g.compact_name_distinct_count,

    g.trusted_nik_distinct_count > 1
      AS trusted_nik_conflict_flag,

    g.dob_distinct_count > 1
      AS dob_conflict_flag,

    g.compact_name_distinct_count > 1
      AS name_variant_flag,

    DATE_DIFF(
      g.max_delivery_date,
      g.min_delivery_date,
      DAY
    ) AS delivery_date_range_days,

    g.earliest_source_reference_date

  FROM grouped g
)

SELECT
  p.*,

  COALESCE(
    mm.delivery_merge_methods,
    ARRAY<STRING>[]
  ) AS delivery_merge_methods,

  mm.best_delivery_merge_priority,

  COALESCE(
    mm.any_delivery_merge_qa_required,
    FALSE
  )
  OR p.trusted_nik_conflict_flag
  OR p.dob_conflict_flag
  OR p.name_variant_flag
  OR p.delivery_date_range_days > delivery_tolerance_days
    AS delivery_dedup_qa_required

FROM projected p

LEFT JOIN
  `_SESSION.t_delivery_event_merge_methods` mm
  USING (delivery_event_id);

-- ============================================================================
-- STEP 3 v3 - STRICT ANC LINKAGE + POST-ANC CONSOLIDATION
-- Uses the CURRENT geo-corrected t_pregnancy_episode_spine_v3_3.
-- ============================================================================

-- ============================================================================
-- PARAMETERS
-- ============================================================================

-- They are intentionally not redeclared in this combined single-job script.

-- ============================================================================
-- A. REBUILD EPUS SOURCE-KEY MAPS
-- ============================================================================

CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_event_epus_key_map_v3`
CLUSTER BY epus_episode_source_key, delivery_event_id
AS

SELECT DISTINCT
  d.delivery_event_id,
  k AS epus_episode_source_key
FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_unlinked` d,
UNNEST(COALESCE(d.epus_episode_source_keys, ARRAY<STRING>[])) AS k
WHERE k IS NOT NULL;


CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_pregnancy_epus_key_map_v3`
CLUSTER BY epus_episode_source_key, pregnancy_episode_id
AS

WITH keys AS (
  SELECT
    pregnancy_episode_id,
    epus_episode_source_key
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3`
  WHERE epus_episode_source_key IS NOT NULL

  UNION DISTINCT

  SELECT
    p.pregnancy_episode_id,
    k AS epus_episode_source_key
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` p,
  UNNEST(COALESCE(p.epus_episode_source_keys, ARRAY<STRING>[])) AS k
  WHERE k IS NOT NULL
)
SELECT * FROM keys;


-- ============================================================================
-- B. STRICTER DELIVERY -> ANC CANDIDATES
--
-- Non-direct rules MUST be inside the broad 18-46 week plausibility window.
-- Direct ePUS episode-key candidates are retained even when implausible so the
-- disagreement is auditable, but implausible direct links do not auto-link.
-- ============================================================================

CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_anc_candidates_v3`
CLUSTER BY delivery_event_id, pregnancy_episode_id
AS

-- --------------------------------------------------------------------------
-- 0. DIRECT EPUS EPISODE SOURCE KEY
-- --------------------------------------------------------------------------
SELECT
  d.delivery_event_id,
  p.pregnancy_episode_id,

  'DIRECT_EPUS_EPISODE_SOURCE_KEY' AS anc_match_method,
  0 AS anc_match_priority,
  'VERY_HIGH' AS anc_match_confidence,

  DATE_DIFF(d.delivery_date, p.pregnancy_anchor_date, DAY)
    AS days_from_pregnancy_anchor,

  DATE_DIFF(
    d.delivery_date,
    COALESCE(
      p.hpl_recorded_date,
      p.hpl_from_hpht_date,
      DATE_ADD(p.pregnancy_anchor_date, INTERVAL 280 DAY)
    ),
    DAY
  ) AS days_from_expected_delivery,

  ABS(
    DATE_DIFF(
      d.delivery_date,
      COALESCE(
        p.hpl_recorded_date,
        p.hpl_from_hpht_date,
        DATE_ADD(p.pregnancy_anchor_date, INTERVAL 280 DAY)
      ),
      DAY
    )
  ) AS match_distance_days,

  (
    p.pregnancy_anchor_date IS NOT NULL
    AND DATE_DIFF(d.delivery_date, p.pregnancy_anchor_date, DAY)
        BETWEEN anc_min_days_from_anchor AND anc_max_days_from_anchor
  ) AS date_plausible_flag

FROM
  `_SESSION.t_delivery_event_epus_key_map_v3` dk
JOIN
  `_SESSION.t_pregnancy_epus_key_map_v3` pk
  USING (epus_episode_source_key)
JOIN
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_unlinked` d
  USING (delivery_event_id)
JOIN
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` p
  USING (pregnancy_episode_id)

UNION ALL

-- --------------------------------------------------------------------------
-- 1. EXACT NIK + PLAUSIBLE PREGNANCY WINDOW
-- --------------------------------------------------------------------------
SELECT
  d.delivery_event_id,
  p.pregnancy_episode_id,

  'NIK+PREGNANCY_WINDOW',
  1,
  'VERY_HIGH',

  DATE_DIFF(d.delivery_date, p.pregnancy_anchor_date, DAY),

  DATE_DIFF(
    d.delivery_date,
    COALESCE(
      p.hpl_recorded_date,
      p.hpl_from_hpht_date,
      DATE_ADD(p.pregnancy_anchor_date, INTERVAL 280 DAY)
    ),
    DAY
  ),

  ABS(
    DATE_DIFF(
      d.delivery_date,
      COALESCE(
        p.hpl_recorded_date,
        p.hpl_from_hpht_date,
        DATE_ADD(p.pregnancy_anchor_date, INTERVAL 280 DAY)
      ),
      DAY
    )
  ),

  TRUE

FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_unlinked` d
JOIN
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` p
  ON d.nik_clean IS NOT NULL
 AND p.nik_clean IS NOT NULL
 AND d.nik_clean = p.nik_clean
 AND p.pregnancy_anchor_date IS NOT NULL
 AND DATE_DIFF(d.delivery_date, p.pregnancy_anchor_date, DAY)
     BETWEEN anc_min_days_from_anchor AND anc_max_days_from_anchor

UNION ALL

-- --------------------------------------------------------------------------
-- 2. EXACT NAME + DOB + PLAUSIBLE PREGNANCY WINDOW
-- --------------------------------------------------------------------------
SELECT
  d.delivery_event_id,
  p.pregnancy_episode_id,

  'NAMA+DOB+PREGNANCY_WINDOW',
  2,
  'VERY_HIGH',

  DATE_DIFF(d.delivery_date, p.pregnancy_anchor_date, DAY),

  DATE_DIFF(
    d.delivery_date,
    COALESCE(
      p.hpl_recorded_date,
      p.hpl_from_hpht_date,
      DATE_ADD(p.pregnancy_anchor_date, INTERVAL 280 DAY)
    ),
    DAY
  ),

  ABS(
    DATE_DIFF(
      d.delivery_date,
      COALESCE(
        p.hpl_recorded_date,
        p.hpl_from_hpht_date,
        DATE_ADD(p.pregnancy_anchor_date, INTERVAL 280 DAY)
      ),
      DAY
    )
  ),

  TRUE

FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_unlinked` d
JOIN
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` p
  ON d.nama_norm IS NOT NULL
 AND p.nama_norm IS NOT NULL
 AND d.nama_norm = p.nama_norm
 AND d.tanggal_lahir_ibu IS NOT NULL
 AND p.tanggal_lahir_ibu IS NOT NULL
 AND d.tanggal_lahir_ibu = p.tanggal_lahir_ibu
 AND NOT nik_hard_conflict(d.nik_clean, p.nik_clean)
 AND p.pregnancy_anchor_date IS NOT NULL
 AND DATE_DIFF(d.delivery_date, p.pregnancy_anchor_date, DAY)
     BETWEEN anc_min_days_from_anchor AND anc_max_days_from_anchor

UNION ALL

-- --------------------------------------------------------------------------
-- 3. COMPACT NAME + DOB + PLAUSIBLE PREGNANCY WINDOW
-- --------------------------------------------------------------------------
SELECT
  d.delivery_event_id,
  p.pregnancy_episode_id,

  'COMPACT_NAME+DOB+PREGNANCY_WINDOW',
  3,
  'HIGH',

  DATE_DIFF(d.delivery_date, p.pregnancy_anchor_date, DAY),

  DATE_DIFF(
    d.delivery_date,
    COALESCE(
      p.hpl_recorded_date,
      p.hpl_from_hpht_date,
      DATE_ADD(p.pregnancy_anchor_date, INTERVAL 280 DAY)
    ),
    DAY
  ),

  ABS(
    DATE_DIFF(
      d.delivery_date,
      COALESCE(
        p.hpl_recorded_date,
        p.hpl_from_hpht_date,
        DATE_ADD(p.pregnancy_anchor_date, INTERVAL 280 DAY)
      ),
      DAY
    )
  ),

  TRUE

FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_unlinked` d
JOIN
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` p
  ON d.nama_compact_norm IS NOT NULL
 AND d.nama_compact_norm = compact_name(
   COALESCE(p.nama_core_norm, p.nama_norm, p.nama_ibu)
 )
 AND d.tanggal_lahir_ibu IS NOT NULL
 AND p.tanggal_lahir_ibu IS NOT NULL
 AND d.tanggal_lahir_ibu = p.tanggal_lahir_ibu
 AND NOT nik_hard_conflict(d.nik_clean, p.nik_clean)
 AND p.pregnancy_anchor_date IS NOT NULL
 AND DATE_DIFF(d.delivery_date, p.pregnancy_anchor_date, DAY)
     BETWEEN anc_min_days_from_anchor AND anc_max_days_from_anchor

UNION ALL

-- --------------------------------------------------------------------------
-- 4. PHONE + DOB + PLAUSIBLE PREGNANCY WINDOW
-- --------------------------------------------------------------------------
SELECT
  d.delivery_event_id,
  p.pregnancy_episode_id,

  'PHONE+DOB+PREGNANCY_WINDOW',
  4,
  'HIGH',

  DATE_DIFF(d.delivery_date, p.pregnancy_anchor_date, DAY),

  DATE_DIFF(
    d.delivery_date,
    COALESCE(
      p.hpl_recorded_date,
      p.hpl_from_hpht_date,
      DATE_ADD(p.pregnancy_anchor_date, INTERVAL 280 DAY)
    ),
    DAY
  ),

  ABS(
    DATE_DIFF(
      d.delivery_date,
      COALESCE(
        p.hpl_recorded_date,
        p.hpl_from_hpht_date,
        DATE_ADD(p.pregnancy_anchor_date, INTERVAL 280 DAY)
      ),
      DAY
    )
  ),

  TRUE

FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_unlinked` d
JOIN
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` p
  ON d.no_hp_clean IS NOT NULL
 AND LENGTH(d.no_hp_clean) >= 8
 AND p.no_hp_clean IS NOT NULL
 AND d.no_hp_clean = p.no_hp_clean
 AND d.tanggal_lahir_ibu IS NOT NULL
 AND p.tanggal_lahir_ibu IS NOT NULL
 AND d.tanggal_lahir_ibu = p.tanggal_lahir_ibu
 AND NOT nik_hard_conflict(d.nik_clean, p.nik_clean)
 AND p.pregnancy_anchor_date IS NOT NULL
 AND DATE_DIFF(d.delivery_date, p.pregnancy_anchor_date, DAY)
     BETWEEN anc_min_days_from_anchor AND anc_max_days_from_anchor;


-- ============================================================================
-- C. BEST METHOD PER DELIVERY/PREGNANCY PAIR
-- ============================================================================

CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_anc_candidates_best_v3`
CLUSTER BY delivery_event_id, pregnancy_episode_id
AS

SELECT * EXCEPT(pair_rn)
FROM (
  SELECT
    c.*,
    ROW_NUMBER() OVER (
      PARTITION BY delivery_event_id, pregnancy_episode_id
      ORDER BY
        IF(date_plausible_flag, 0, 1),
        anc_match_priority,
        match_distance_days,
        anc_match_method
    ) AS pair_rn
  FROM
    `_SESSION.t_delivery_anc_candidates_v3` c
)
WHERE pair_rn = 1;




-- ============================================================================
-- C2. SAFE DIRECT SIGIZI SOURCE-RECORD RESCUE
-- ============================================================================

-- ============================================================================
-- PATCH C2 - DIRECT SIGIZI SOURCE-RECORD RESCUE
-- Insert AFTER section C (t_delivery_anc_candidates_best_v3 is created)
-- and BEFORE section D (t_delivery_anc_ranked_v3 is created)
-- in 05_full_delivery_rebuild_geo_fixed_v3_FIX_DECLARE_CLUSTER.sql.
--
-- PURPOSE
--   Rescue only delivery events that currently have NO ANC candidate at all,
--   when the same SIGIZI source_record_id belongs to exactly one pregnancy
--   candidate with temporally plausible source-level dating.
--
-- IMPORTANT
--   * Does NOT change existing matched / ambiguous / implausible candidates.
--   * Does NOT auto-link borderline (HPL +43..+56d) or date-conflict cases.
--   * Uses source-level SIGIZI HPHT/HPL for rescue eligibility.
--   * Standard candidate diagnostics remain measured against the final
--     pregnancy spine for downstream compatibility.
-- ============================================================================

CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_sigizi_direct_rescue_v3`
CLUSTER BY delivery_event_id, pregnancy_episode_id
AS

WITH existing_candidate_events AS (
  SELECT DISTINCT delivery_event_id
  FROM
    `_SESSION.t_delivery_anc_candidates_best_v3`
),

-- --------------------------------------------------------------------------
-- SIGIZI source records that belong to PRE-ANC canonical delivery events.
-- Use the initial member map because delivery_event_master_unlinked uses these
-- pre-ANC delivery_event_id values.
-- --------------------------------------------------------------------------
delivery_sigizi_records AS (
  SELECT DISTINCT
    m.delivery_event_id,
    b.source_record_id AS sigizi_source_record_id
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_member_map` m
  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_dedup_base` b
    USING (source_event_id)
  WHERE b.source_system = 'SIGIZI'
    AND b.source_record_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM existing_candidate_events e
      WHERE e.delivery_event_id = m.delivery_event_id
    )
),

-- --------------------------------------------------------------------------
-- Final pregnancy -> canonical SIGIZI episode -> original SIGIZI source record
-- --------------------------------------------------------------------------
pregnancy_sigizi_source_records AS (
  SELECT DISTINCT
    p.pregnancy_episode_id,
    source_record_id AS sigizi_source_record_id
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` p
  CROSS JOIN UNNEST(
    COALESCE(p.canonical_sigizi_episode_ids, ARRAY<STRING>[])
  ) AS sigizi_episode_id
  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_canonical_v3_3` c
    ON c.sigizi_episode_id = sigizi_episode_id
  CROSS JOIN UNNEST(
    COALESCE(c.sigizi_member_source_record_ids, ARRAY<STRING>[])
  ) AS source_record_id
),

-- --------------------------------------------------------------------------
-- Exact shared provenance candidates.
-- --------------------------------------------------------------------------
shared_provenance AS (
  SELECT DISTINCT
    d.delivery_event_id,
    d.sigizi_source_record_id,
    ps.pregnancy_episode_id,

    u.delivery_date,

    s.source_table,
    s.hpht_date AS source_hpht_date,
    s.hpl_date AS source_hpl_date,

    p.pregnancy_anchor_date,
    COALESCE(
      p.hpl_recorded_date,
      p.hpl_from_hpht_date,
      DATE_ADD(p.pregnancy_anchor_date, INTERVAL 280 DAY)
    ) AS final_expected_delivery_date

  FROM delivery_sigizi_records d
  JOIN pregnancy_sigizi_source_records ps
    USING (sigizi_source_record_id)
  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_unlinked` u
    USING (delivery_event_id)
  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_source_records` s
    ON s.source_record_id = d.sigizi_source_record_id
  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` p
    USING (pregnancy_episode_id)
),

-- --------------------------------------------------------------------------
-- Temporal evaluation of the SAME shared SIGIZI source record.
--
-- Plausible rule:
--   A) source HPL available: canonical delivery is within +/-42 days of HPL
--   B) source HPL absent but HPHT available: delivery is 126..322 days after HPHT
--
-- Explicit impossible case (delivery before source HPHT) is never rescued.
-- Borderline HPL +43..+56d is preserved separately for QA only.
-- --------------------------------------------------------------------------
evaluated AS (
  SELECT
    *,

    CASE
      WHEN source_hpht_date IS NOT NULL
       AND delivery_date < source_hpht_date
        THEN 'IMPOSSIBLE_BEFORE_HPHT'

      WHEN source_hpl_date IS NOT NULL
       AND DATE_DIFF(delivery_date, source_hpl_date, DAY)
           BETWEEN -42 AND 42
        THEN 'PLAUSIBLE_HPL_42D'

      WHEN source_hpl_date IS NULL
       AND source_hpht_date IS NOT NULL
       AND DATE_DIFF(delivery_date, source_hpht_date, DAY)
           BETWEEN 126 AND 322
        THEN 'PLAUSIBLE_HPHT_WINDOW'

      WHEN source_hpl_date IS NOT NULL
       AND DATE_DIFF(delivery_date, source_hpl_date, DAY)
           BETWEEN 43 AND 56
        THEN 'BORDERLINE_HPL_43_56D'

      WHEN source_hpht_date IS NULL
       AND source_hpl_date IS NULL
        THEN 'NO_DATING_EVIDENCE'

      ELSE 'DATE_CONFLICT'
    END AS source_temporal_status

  FROM shared_provenance
),

-- --------------------------------------------------------------------------
-- Collapse multiple shared source records into one delivery/pregnancy candidate.
-- --------------------------------------------------------------------------
pregnancy_candidate_summary AS (
  SELECT
    delivery_event_id,
    pregnancy_episode_id,

    COUNT(DISTINCT sigizi_source_record_id)
      AS shared_sigizi_source_record_count,

    COUNTIF(
      source_temporal_status IN (
        'PLAUSIBLE_HPL_42D',
        'PLAUSIBLE_HPHT_WINDOW'
      )
    ) AS plausible_shared_source_record_count,

    COUNTIF(
      source_temporal_status = 'BORDERLINE_HPL_43_56D'
    ) AS borderline_shared_source_record_count,

    COUNTIF(
      source_temporal_status IN (
        'IMPOSSIBLE_BEFORE_HPHT',
        'DATE_CONFLICT'
      )
    ) AS conflicting_shared_source_record_count,

    ARRAY_AGG(
      STRUCT(
        sigizi_source_record_id,
        source_table,
        source_hpht_date,
        source_hpl_date,
        source_temporal_status
      )
      ORDER BY
        CASE
          WHEN source_temporal_status = 'PLAUSIBLE_HPL_42D' THEN 0
          WHEN source_temporal_status = 'PLAUSIBLE_HPHT_WINDOW' THEN 1
          WHEN source_temporal_status = 'BORDERLINE_HPL_43_56D' THEN 2
          ELSE 3
        END,
        sigizi_source_record_id
    ) AS shared_source_evidence

  FROM evaluated
  GROUP BY delivery_event_id, pregnancy_episode_id
),

-- Only pregnancies with >=1 temporally plausible shared source record qualify.
plausible_candidates AS (
  SELECT *
  FROM pregnancy_candidate_summary
  WHERE plausible_shared_source_record_count > 0
),

-- Require exactly one plausible pregnancy per delivery event.
event_summary AS (
  SELECT
    delivery_event_id,
    COUNT(DISTINCT pregnancy_episode_id) AS plausible_direct_pregnancy_count
  FROM plausible_candidates
  GROUP BY delivery_event_id
),

unique_plausible AS (
  SELECT
    pc.*
  FROM plausible_candidates pc
  JOIN event_summary es
    USING (delivery_event_id)
  WHERE es.plausible_direct_pregnancy_count = 1
)

SELECT
  up.delivery_event_id,
  up.pregnancy_episode_id,

  'DIRECT_SIGIZI_SOURCE_RECORD_TEMPORALLY_PLAUSIBLE'
    AS anc_match_method,
  0 AS anc_match_priority,
  'VERY_HIGH' AS anc_match_confidence,

  DATE_DIFF(
    d.delivery_date,
    p.pregnancy_anchor_date,
    DAY
  ) AS days_from_pregnancy_anchor,

  DATE_DIFF(
    d.delivery_date,
    COALESCE(
      p.hpl_recorded_date,
      p.hpl_from_hpht_date,
      DATE_ADD(p.pregnancy_anchor_date, INTERVAL 280 DAY)
    ),
    DAY
  ) AS days_from_expected_delivery,

  ABS(
    DATE_DIFF(
      d.delivery_date,
      COALESCE(
        p.hpl_recorded_date,
        p.hpl_from_hpht_date,
        DATE_ADD(p.pregnancy_anchor_date, INTERVAL 280 DAY)
      ),
      DAY
    )
  ) AS match_distance_days,

  TRUE AS date_plausible_flag,

  -- Extra audit columns kept in the rescue helper table only.
  up.shared_sigizi_source_record_count,
  up.plausible_shared_source_record_count,
  up.borderline_shared_source_record_count,
  up.conflicting_shared_source_record_count,
  up.shared_source_evidence

FROM unique_plausible up
JOIN
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_unlinked` d
  USING (delivery_event_id)
JOIN
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` p
  USING (pregnancy_episode_id);


-- ============================================================================
-- C2 QA BEFORE INSERT
-- ============================================================================

-- All-history rescue candidates.
SELECT
  COUNT(*) AS rescue_delivery_events_all_history,
  COUNT(DISTINCT pregnancy_episode_id) AS rescue_pregnancies_all_history
FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_sigizi_direct_rescue_v3`;

-- Operational dashboard period. This was 194 in the audit performed before
-- this patch; it may change if new source data have arrived.
SELECT
  COUNT(*) AS rescue_delivery_events_2025_to_today
FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_sigizi_direct_rescue_v3` r
JOIN
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_unlinked` d
  USING (delivery_event_id)
WHERE d.delivery_date BETWEEN DATE '2025-01-01'
                          AND CURRENT_DATE('Asia/Makassar');


-- ============================================================================
-- INSERT THE SAFE RESCUE CANDIDATES INTO THE EXISTING BEST-CANDIDATE TABLE.
-- Downstream sections D-N can remain unchanged.
-- ============================================================================

INSERT INTO
  `_SESSION.t_delivery_anc_candidates_best_v3`
(
  delivery_event_id,
  pregnancy_episode_id,
  anc_match_method,
  anc_match_priority,
  anc_match_confidence,
  days_from_pregnancy_anchor,
  days_from_expected_delivery,
  match_distance_days,
  date_plausible_flag
)
SELECT
  delivery_event_id,
  pregnancy_episode_id,
  anc_match_method,
  anc_match_priority,
  anc_match_confidence,
  days_from_pregnancy_anchor,
  days_from_expected_delivery,
  match_distance_days,
  date_plausible_flag
FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_sigizi_direct_rescue_v3`;


-- ============================================================================
-- SAFETY ASSERTS
-- ============================================================================

-- Every rescue event must have exactly one rescue pregnancy.
ASSERT (
  SELECT COUNT(*) = COUNT(DISTINCT delivery_event_id)
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_sigizi_direct_rescue_v3`
)
AS 'Direct SIGIZI rescue produced >1 accepted pregnancy for a delivery event.';

-- Rescue events must not have existed in the original candidate table before
-- the rescue injection. Because section C was recreated immediately before
-- this block, there must now be exactly one best candidate row per rescue event.
ASSERT (
  SELECT COUNT(*) = 0
  FROM (
    SELECT
      r.delivery_event_id,
      COUNTIF(
        b.anc_match_method !=
          'DIRECT_SIGIZI_SOURCE_RECORD_TEMPORALLY_PLAUSIBLE'
      ) AS non_rescue_candidate_rows
    FROM
      `spheres-lombok-barat.kohort_bumil_v3.t_delivery_sigizi_direct_rescue_v3` r
    JOIN
      `_SESSION.t_delivery_anc_candidates_best_v3` b
      USING (delivery_event_id)
    GROUP BY r.delivery_event_id
    HAVING non_rescue_candidate_rows > 0
  )
)
AS 'A direct SIGIZI rescue event already had another ANC candidate; abort.';

-- ============================================================================
-- Continue with the existing Section D onward unchanged:
--   D. t_delivery_anc_ranked_v3
--   E. t_delivery_anc_map_v3
--   F-N post-ANC consolidation and t_delivery_event_master_v3
-- ============================================================================

-- ============================================================================
-- D. RANK ANC CANDIDATES; PLAUSIBLE CANDIDATES WIN OVER IMPLAUSIBLE DIRECT KEY
-- ============================================================================

CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_anc_ranked_v3`
CLUSTER BY delivery_event_id, pregnancy_episode_id
AS

WITH r1 AS (
  SELECT
    c.*,

    DENSE_RANK() OVER (
      PARTITION BY delivery_event_id
      ORDER BY
        IF(date_plausible_flag, 0, 1),
        anc_match_priority,
        match_distance_days
    ) AS candidate_score_rank,

    ROW_NUMBER() OVER (
      PARTITION BY delivery_event_id
      ORDER BY
        IF(date_plausible_flag, 0, 1),
        anc_match_priority,
        match_distance_days,
        pregnancy_episode_id
    ) AS candidate_row_number

  FROM
    `_SESSION.t_delivery_anc_candidates_best_v3` c
),

r2 AS (
  SELECT
    r1.*,
    COUNT(*) OVER (PARTITION BY delivery_event_id) AS anc_candidate_count,
    COUNTIF(candidate_score_rank = 1) OVER (PARTITION BY delivery_event_id)
      AS anc_top_candidate_count
  FROM r1
)
SELECT * FROM r2;


-- ============================================================================
-- E. PROVISIONAL DELIVERY -> ANC MAP
-- ============================================================================

CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_anc_map_v3`
CLUSTER BY delivery_event_id, pregnancy_episode_id
AS

WITH best AS (
  SELECT
    delivery_event_id,
    pregnancy_episode_id AS best_candidate_pregnancy_episode_id,
    anc_match_method AS best_candidate_anc_match_method,
    anc_match_priority AS best_candidate_anc_match_priority,
    anc_match_confidence AS best_candidate_anc_match_confidence,
    match_distance_days AS best_candidate_match_distance_days,
    days_from_pregnancy_anchor AS best_candidate_days_from_pregnancy_anchor,
    days_from_expected_delivery AS best_candidate_days_from_expected_delivery,
    date_plausible_flag AS best_candidate_date_plausible_flag,
    anc_candidate_count,
    anc_top_candidate_count
  FROM
    `_SESSION.t_delivery_anc_ranked_v3`
  WHERE candidate_row_number = 1
)

SELECT
  d.delivery_event_id,

  CASE
    WHEN COALESCE(b.anc_candidate_count, 0) = 0 THEN NULL
    WHEN b.anc_top_candidate_count > 1 THEN NULL
    WHEN NOT COALESCE(b.best_candidate_date_plausible_flag, FALSE) THEN NULL
    ELSE b.best_candidate_pregnancy_episode_id
  END AS pregnancy_episode_id,

  COALESCE(b.anc_candidate_count, 0) AS anc_candidate_count,
  COALESCE(b.anc_top_candidate_count, 0) AS anc_top_candidate_count,

  b.best_candidate_pregnancy_episode_id,
  b.best_candidate_anc_match_method,
  b.best_candidate_anc_match_priority,
  b.best_candidate_anc_match_confidence,
  b.best_candidate_match_distance_days,
  b.best_candidate_days_from_pregnancy_anchor,
  b.best_candidate_days_from_expected_delivery,
  b.best_candidate_date_plausible_flag

FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_unlinked` d
LEFT JOIN best b
  USING (delivery_event_id);


-- ============================================================================
-- F. PROVISIONAL EVENT-LEVEL ANC STATUS BEFORE POST-ANC CONSOLIDATION
-- ============================================================================

CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_event_anc_provisional_v3`
CLUSTER BY pregnancy_episode_id, delivery_event_id
AS

SELECT
  d.*,
  m.pregnancy_episode_id,

  CASE
    WHEN m.anc_candidate_count = 0
      THEN 'NO_ANC_MATCH'
    WHEN m.anc_top_candidate_count > 1
      THEN 'AMBIGUOUS_ANC_MATCH'
    WHEN NOT COALESCE(m.best_candidate_date_plausible_flag, FALSE)
      THEN 'ANC_LINK_DATE_IMPLAUSIBLE'
    WHEN p.pregnancy_source_combination = 'SIGIZI + EPUS'
      THEN 'MATCHED_SIGIZI_EPUS'
    WHEN p.pregnancy_source_combination = 'SIGIZI ONLY'
      THEN 'MATCHED_SIGIZI_ONLY'
    WHEN p.pregnancy_source_combination = 'EPUS ONLY'
      THEN 'MATCHED_EPUS_ONLY'
    WHEN m.pregnancy_episode_id IS NOT NULL
      THEN 'MATCHED_ANC_OTHER'
    ELSE 'NO_ANC_MATCH'
  END AS provisional_anc_link_status,

  m.anc_candidate_count,
  m.anc_top_candidate_count,

  CASE WHEN m.pregnancy_episode_id IS NOT NULL
    THEN m.best_candidate_anc_match_method END AS anc_link_method,
  CASE WHEN m.pregnancy_episode_id IS NOT NULL
    THEN m.best_candidate_anc_match_priority END AS anc_link_priority,
  CASE WHEN m.pregnancy_episode_id IS NOT NULL
    THEN m.best_candidate_anc_match_confidence END AS anc_link_confidence,
  CASE WHEN m.pregnancy_episode_id IS NOT NULL
    THEN m.best_candidate_match_distance_days END AS anc_match_distance_days,
  CASE WHEN m.pregnancy_episode_id IS NOT NULL
    THEN m.best_candidate_days_from_pregnancy_anchor END
      AS anc_days_from_pregnancy_anchor,
  CASE WHEN m.pregnancy_episode_id IS NOT NULL
    THEN m.best_candidate_days_from_expected_delivery END
      AS anc_days_from_expected_delivery,

  m.best_candidate_pregnancy_episode_id,
  m.best_candidate_anc_match_method,
  m.best_candidate_anc_match_priority,
  m.best_candidate_anc_match_confidence,
  m.best_candidate_match_distance_days,
  m.best_candidate_days_from_pregnancy_anchor,
  m.best_candidate_days_from_expected_delivery,
  m.best_candidate_date_plausible_flag,

  p.pregnancy_source_combination AS anc_pregnancy_source_combination,

  COALESCE(
    p.hpl_recorded_date,
    p.hpl_from_hpht_date,
    DATE_ADD(p.pregnancy_anchor_date, INTERVAL 280 DAY)
  ) AS anc_expected_delivery_date

FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_unlinked` d
LEFT JOIN
  `_SESSION.t_delivery_anc_map_v3` m
  USING (delivery_event_id)
LEFT JOIN
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` p
  ON p.pregnancy_episode_id = m.pregnancy_episode_id;


-- ============================================================================
-- G. ASSIGN <=42-DAY POST-ANC DELIVERY CLUSTERS
--
-- We anchor cluster buckets to the earliest linked delivery for each pregnancy.
-- Bucket width = 43 days, so each cluster's internal calendar span is <=42d.
-- This intentionally avoids transitive chaining that could produce >42d spans.
-- ============================================================================

CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_postanc_cluster_assignment_v3`
CLUSTER BY pregnancy_episode_id, postanc_cluster_number, delivery_event_id
AS

WITH linked_min AS (
  SELECT
    pregnancy_episode_id,
    MIN(delivery_date) AS pregnancy_min_delivery_date
  FROM
    `_SESSION.t_delivery_event_anc_provisional_v3`
  WHERE pregnancy_episode_id IS NOT NULL
  GROUP BY pregnancy_episode_id
)

SELECT
  d.delivery_event_id,
  d.pregnancy_episode_id,
  d.delivery_date,

  CASE
    WHEN d.pregnancy_episode_id IS NULL THEN NULL
    ELSE DIV(
      DATE_DIFF(d.delivery_date, m.pregnancy_min_delivery_date, DAY),
      post_anc_cluster_span_days + 1
    )
  END AS postanc_cluster_number,

  CASE
    WHEN d.pregnancy_episode_id IS NULL
      THEN CONCAT('EVENT|', d.delivery_event_id)
    ELSE CONCAT(
      'PREG|', d.pregnancy_episode_id,
      '|CLUSTER|',
      CAST(
        DIV(
          DATE_DIFF(d.delivery_date, m.pregnancy_min_delivery_date, DAY),
          post_anc_cluster_span_days + 1
        ) AS STRING
      )
    )
  END AS postanc_group_key

FROM
  `_SESSION.t_delivery_event_anc_provisional_v3` d
LEFT JOIN linked_min m
  USING (pregnancy_episode_id);


-- ============================================================================
-- H. SOURCE-SYSTEM SUPPORT PER POST-ANC CLUSTER
-- ============================================================================

CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_postanc_cluster_source_support_v3`
CLUSTER BY pregnancy_episode_id, postanc_cluster_number
AS

SELECT
  a.pregnancy_episode_id,
  a.postanc_cluster_number,
  COUNT(DISTINCT src) AS independent_source_system_count,
  ARRAY_AGG(DISTINCT src ORDER BY src) AS source_systems
FROM
  `_SESSION.t_delivery_postanc_cluster_assignment_v3` a
JOIN
  `_SESSION.t_delivery_event_anc_provisional_v3` d
  USING (delivery_event_id),
UNNEST(COALESCE(d.delivery_source_systems, ARRAY<STRING>[])) AS src
WHERE a.pregnancy_episode_id IS NOT NULL
GROUP BY
  a.pregnancy_episode_id,
  a.postanc_cluster_number;


-- ============================================================================
-- I. POST-ANC CLUSTER STATS + WINNER PER PREGNANCY
--
-- Ranking priority:
--   1) more independent source systems
--   2) more underlying source records
--   3) stronger ANC link method
--   4) closer to expected delivery date
--   5) earlier cluster date (deterministic final tie-break)
-- ============================================================================

CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_postanc_cluster_stats_v3`
CLUSTER BY pregnancy_episode_id, postanc_cluster_number
AS

WITH base AS (
  SELECT
    a.pregnancy_episode_id,
    a.postanc_cluster_number,
    a.postanc_group_key,

    COUNT(*) AS preconsolidation_event_count,
    SUM(d.source_record_count) AS source_record_count,

    MIN(d.delivery_date) AS cluster_min_delivery_date,
    MAX(d.delivery_date) AS cluster_max_delivery_date,
    DATE_DIFF(MAX(d.delivery_date), MIN(d.delivery_date), DAY)
      AS cluster_delivery_date_span_days,

    MIN(d.anc_link_priority) AS best_anc_link_priority,
    MIN(d.anc_match_distance_days) AS best_anc_match_distance_days,

    MIN(
      ABS(
        DATE_DIFF(
          d.delivery_date,
          d.anc_expected_delivery_date,
          DAY
        )
      )
    ) AS min_abs_days_from_expected_delivery,

    LOGICAL_OR(d.anc_link_method = 'DIRECT_EPUS_EPISODE_SOURCE_KEY')
      AS has_direct_epus_episode_link,

    ARRAY_AGG(d.delivery_event_id ORDER BY d.delivery_date, d.delivery_event_id)
      AS preconsolidation_delivery_event_ids

  FROM
    `_SESSION.t_delivery_postanc_cluster_assignment_v3` a
  JOIN
    `_SESSION.t_delivery_event_anc_provisional_v3` d
    USING (delivery_event_id)
  WHERE a.pregnancy_episode_id IS NOT NULL
  GROUP BY
    a.pregnancy_episode_id,
    a.postanc_cluster_number,
    a.postanc_group_key
),

with_support AS (
  SELECT
    b.*,
    COALESCE(s.independent_source_system_count, 0)
      AS independent_source_system_count,
    COALESCE(s.source_systems, ARRAY<STRING>[])
      AS source_systems
  FROM base b
  LEFT JOIN
    `_SESSION.t_delivery_postanc_cluster_source_support_v3` s
    USING (pregnancy_episode_id, postanc_cluster_number)
),

ranked AS (
  SELECT
    w.*,

    COUNT(*) OVER (PARTITION BY pregnancy_episode_id)
      AS pregnancy_delivery_cluster_count,

    ROW_NUMBER() OVER (
      PARTITION BY pregnancy_episode_id
      ORDER BY
        independent_source_system_count DESC,
        source_record_count DESC,
        best_anc_link_priority ASC,
        COALESCE(min_abs_days_from_expected_delivery, 999999) ASC,
        cluster_min_delivery_date ASC,
        postanc_cluster_number ASC
    ) AS pregnancy_cluster_rank

  FROM with_support w
)
SELECT * FROM ranked;


-- ============================================================================
-- J. MAP PRE-CONSOLIDATION EVENTS -> FINAL v3 DELIVERY EVENT GROUPS
-- ============================================================================

CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_postanc_group_map_v3`
CLUSTER BY final_delivery_event_id, pre_delivery_event_id
AS

WITH linked AS (
  SELECT
    a.delivery_event_id AS pre_delivery_event_id,
    a.pregnancy_episode_id AS provisional_pregnancy_episode_id,
    a.postanc_cluster_number,
    a.postanc_group_key,

    s.preconsolidation_event_count,
    s.pregnancy_delivery_cluster_count,
    s.pregnancy_cluster_rank,
    s.independent_source_system_count,
    s.cluster_delivery_date_span_days,

    CASE
      WHEN s.preconsolidation_event_count = 1
        THEN a.delivery_event_id
      ELSE CONCAT(
        'BIRTH_',
        TO_HEX(SHA256(s.postanc_group_key))
      )
    END AS final_delivery_event_id,

    CASE
      WHEN s.pregnancy_cluster_rank = 1
        THEN a.pregnancy_episode_id
      ELSE NULL
    END AS final_pregnancy_episode_id,

    CASE
      WHEN s.pregnancy_delivery_cluster_count = 1
        THEN 'NO_COLLISION'
      WHEN s.pregnancy_cluster_rank = 1
        THEN 'WINNER_WITH_OTHER_COLLISION_CLUSTER'
      ELSE 'REJECTED_COLLISION_CLUSTER'
    END AS delivery_collision_status

  FROM
    `_SESSION.t_delivery_postanc_cluster_assignment_v3` a
  JOIN
    `_SESSION.t_delivery_postanc_cluster_stats_v3` s
    USING (pregnancy_episode_id, postanc_cluster_number)
  WHERE a.pregnancy_episode_id IS NOT NULL
),

unlinked AS (
  SELECT
    d.delivery_event_id AS pre_delivery_event_id,
    CAST(NULL AS STRING) AS provisional_pregnancy_episode_id,
    CAST(NULL AS INT64) AS postanc_cluster_number,
    CONCAT('EVENT|', d.delivery_event_id) AS postanc_group_key,
    1 AS preconsolidation_event_count,
    0 AS pregnancy_delivery_cluster_count,
    CAST(NULL AS INT64) AS pregnancy_cluster_rank,
    d.source_system_count AS independent_source_system_count,
    d.delivery_date_range_days AS cluster_delivery_date_span_days,
    d.delivery_event_id AS final_delivery_event_id,
    CAST(NULL AS STRING) AS final_pregnancy_episode_id,
    'NOT_APPLICABLE' AS delivery_collision_status
  FROM
    `_SESSION.t_delivery_event_anc_provisional_v3` d
  WHERE d.pregnancy_episode_id IS NULL
)

SELECT * FROM linked
UNION ALL
SELECT * FROM unlinked;


-- ============================================================================
-- K. RAW SOURCE RECORD -> FINAL v3 DELIVERY EVENT MAP
-- ============================================================================

CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_member_map_v3`
CLUSTER BY delivery_event_id, source_event_id
AS

SELECT
  m.source_event_id,
  m.delivery_event_id AS pre_delivery_event_id,
  g.final_delivery_event_id AS delivery_event_id,
  g.final_pregnancy_episode_id AS pregnancy_episode_id,
  g.delivery_collision_status
FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_member_map` m
JOIN
  `_SESSION.t_delivery_postanc_group_map_v3` g
  ON g.pre_delivery_event_id = m.delivery_event_id;


-- ============================================================================
-- L. CANONICAL DELIVERY-DATE SUPPORT
--
-- Consensus hierarchy:
--   1) most independent source systems supporting exact date
--   2) most source records supporting date
--   3) best source priority
--   4) closest to expected delivery date, if ANC-linked
--   5) earliest date for deterministic final tie-break
-- ============================================================================

CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_date_support_v3`
CLUSTER BY delivery_event_id, delivery_date
AS

WITH support AS (
  SELECT
    m.delivery_event_id,
    b.delivery_date,

    COUNT(DISTINCT b.source_system) AS independent_source_system_count,
    COUNT(*) AS source_record_count,
    MIN(b.source_priority) AS best_source_priority,

    ARRAY_AGG(DISTINCT b.source_system ORDER BY b.source_system)
      AS supporting_source_systems

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_member_map_v3` m
  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_dedup_base` b
    USING (source_event_id)
  GROUP BY
    m.delivery_event_id,
    b.delivery_date
),

meta AS (
  SELECT DISTINCT
    delivery_event_id,
    pregnancy_episode_id
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_member_map_v3`
),

ranked AS (
  SELECT
    s.*,
    meta.pregnancy_episode_id,

    COALESCE(
      p.hpl_recorded_date,
      p.hpl_from_hpht_date,
      DATE_ADD(p.pregnancy_anchor_date, INTERVAL 280 DAY)
    ) AS anc_expected_delivery_date,

    ROW_NUMBER() OVER (
      PARTITION BY s.delivery_event_id
      ORDER BY
        s.independent_source_system_count DESC,
        s.source_record_count DESC,
        s.best_source_priority ASC,
        CASE
          WHEN p.pregnancy_episode_id IS NULL THEN 999999
          ELSE ABS(
            DATE_DIFF(
              s.delivery_date,
              COALESCE(
                p.hpl_recorded_date,
                p.hpl_from_hpht_date,
                DATE_ADD(p.pregnancy_anchor_date, INTERVAL 280 DAY)
              ),
              DAY
            )
          )
        END ASC,
        s.delivery_date ASC
    ) AS date_rank

  FROM support s
  LEFT JOIN meta
    USING (delivery_event_id)
  LEFT JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` p
    ON p.pregnancy_episode_id = meta.pregnancy_episode_id
)
SELECT * FROM ranked;


CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_date_pick_v3`
CLUSTER BY delivery_event_id
AS

SELECT
  delivery_event_id,
  delivery_date,
  independent_source_system_count AS canonical_date_source_system_count,
  source_record_count AS canonical_date_source_record_count,
  best_source_priority AS canonical_date_best_source_priority,
  supporting_source_systems AS canonical_date_supporting_sources,
  anc_expected_delivery_date
FROM
  `_SESSION.t_delivery_date_support_v3`
WHERE date_rank = 1;


-- ============================================================================
-- M. FINAL GROUP-LEVEL ANC / COLLISION METADATA
-- ============================================================================

CREATE OR REPLACE TEMP TABLE
  `_SESSION.t_delivery_event_group_meta_v3`
CLUSTER BY delivery_event_id, pregnancy_episode_id
AS

WITH group_pre AS (
  SELECT
    g.final_delivery_event_id AS delivery_event_id,
    g.final_pregnancy_episode_id AS pregnancy_episode_id,

    ARRAY_AGG(
      DISTINCT g.pre_delivery_event_id
      ORDER BY g.pre_delivery_event_id
    ) AS preconsolidation_delivery_event_ids,

    COUNT(DISTINCT g.pre_delivery_event_id)
      AS preconsolidation_event_count,

    MAX(g.pregnancy_delivery_cluster_count)
      AS pregnancy_delivery_cluster_count,

    MIN(g.pregnancy_cluster_rank)
      AS pregnancy_cluster_rank,

    MAX(g.delivery_collision_status)
      AS delivery_collision_status,

    MAX(g.independent_source_system_count)
      AS postanc_cluster_independent_source_count,

    MAX(g.cluster_delivery_date_span_days)
      AS postanc_cluster_delivery_date_span_days

  FROM
    `_SESSION.t_delivery_postanc_group_map_v3` g
  GROUP BY
    g.final_delivery_event_id,
    g.final_pregnancy_episode_id
),

best_pre_link AS (
  SELECT
    g.final_delivery_event_id AS delivery_event_id,

    ARRAY_AGG(
      STRUCT(
        d.best_candidate_pregnancy_episode_id AS pregnancy_episode_id,
        d.best_candidate_anc_match_method AS method,
        d.best_candidate_anc_match_priority AS priority,
        d.best_candidate_anc_match_confidence AS confidence,
        d.best_candidate_match_distance_days AS distance_days,
        d.best_candidate_days_from_pregnancy_anchor AS days_from_anchor,
        d.best_candidate_days_from_expected_delivery AS days_from_expected,
        d.best_candidate_date_plausible_flag AS date_plausible,
        d.anc_candidate_count AS candidate_count,
        d.anc_top_candidate_count AS top_candidate_count,
        d.provisional_anc_link_status AS provisional_status
      )
      ORDER BY
        IF(d.best_candidate_date_plausible_flag, 0, 1),
        COALESCE(d.best_candidate_anc_match_priority, 999),
        COALESCE(d.best_candidate_match_distance_days, 999999),
        d.delivery_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS pick

  FROM
    `_SESSION.t_delivery_postanc_group_map_v3` g
  JOIN
    `_SESSION.t_delivery_event_anc_provisional_v3` d
    ON d.delivery_event_id = g.pre_delivery_event_id
  GROUP BY g.final_delivery_event_id
)

SELECT
  gp.*,

  CASE
    WHEN gp.delivery_collision_status = 'REJECTED_COLLISION_CLUSTER'
      THEN 'ANC_LINK_COLLISION_REJECTED'

    WHEN gp.pregnancy_episode_id IS NOT NULL
      AND p.pregnancy_source_combination = 'SIGIZI + EPUS'
      THEN 'MATCHED_SIGIZI_EPUS'

    WHEN gp.pregnancy_episode_id IS NOT NULL
      AND p.pregnancy_source_combination = 'SIGIZI ONLY'
      THEN 'MATCHED_SIGIZI_ONLY'

    WHEN gp.pregnancy_episode_id IS NOT NULL
      AND p.pregnancy_source_combination = 'EPUS ONLY'
      THEN 'MATCHED_EPUS_ONLY'

    WHEN gp.pregnancy_episode_id IS NOT NULL
      THEN 'MATCHED_ANC_OTHER'

    WHEN b.pick.provisional_status = 'AMBIGUOUS_ANC_MATCH'
      THEN 'AMBIGUOUS_ANC_MATCH'

    WHEN b.pick.provisional_status = 'ANC_LINK_DATE_IMPLAUSIBLE'
      THEN 'ANC_LINK_DATE_IMPLAUSIBLE'

    ELSE 'NO_ANC_MATCH'
  END AS anc_link_status,

  CASE WHEN gp.pregnancy_episode_id IS NOT NULL
    THEN b.pick.method END AS anc_link_method,
  CASE WHEN gp.pregnancy_episode_id IS NOT NULL
    THEN b.pick.priority END AS anc_link_priority,
  CASE WHEN gp.pregnancy_episode_id IS NOT NULL
    THEN b.pick.confidence END AS anc_link_confidence,
  CASE WHEN gp.pregnancy_episode_id IS NOT NULL
    THEN b.pick.distance_days END AS anc_match_distance_days,
  CASE WHEN gp.pregnancy_episode_id IS NOT NULL
    THEN b.pick.days_from_anchor END AS anc_days_from_pregnancy_anchor,
  CASE WHEN gp.pregnancy_episode_id IS NOT NULL
    THEN b.pick.days_from_expected END AS anc_days_from_expected_delivery,

  b.pick.pregnancy_episode_id AS best_candidate_pregnancy_episode_id,
  b.pick.method AS best_candidate_anc_match_method,
  b.pick.priority AS best_candidate_anc_match_priority,
  b.pick.confidence AS best_candidate_anc_match_confidence,
  b.pick.distance_days AS best_candidate_match_distance_days,
  b.pick.days_from_anchor AS best_candidate_days_from_pregnancy_anchor,
  b.pick.days_from_expected AS best_candidate_days_from_expected_delivery,
  b.pick.date_plausible AS best_candidate_date_plausible_flag,
  b.pick.candidate_count AS anc_candidate_count,
  b.pick.top_candidate_count AS anc_top_candidate_count,

  p.pregnancy_source_combination AS anc_pregnancy_source_combination,
  p.nik_clean AS anc_nik_clean,
  p.nama_ibu AS anc_nama_ibu,
  p.tanggal_lahir_ibu AS anc_tanggal_lahir_ibu,
  p.no_hp_clean AS anc_no_hp_clean,
  p.puskesmas AS anc_puskesmas,
  p.puskesmas_norm AS anc_puskesmas_norm,
  p.desa AS anc_desa,
  p.desa_norm AS anc_desa_norm,
  p.posyandu AS anc_posyandu,
  p.hpht_date AS anc_hpht_date,
  p.hpl_recorded_date AS anc_hpl_recorded_date,
  p.hpl_from_hpht_date AS anc_hpl_from_hpht_date,
  p.pregnancy_anchor_date AS anc_pregnancy_anchor_date,

  COALESCE(
    p.hpl_recorded_date,
    p.hpl_from_hpht_date,
    DATE_ADD(p.pregnancy_anchor_date, INTERVAL 280 DAY)
  ) AS anc_expected_delivery_date,

  gp.pregnancy_episode_id IS NOT NULL AS has_anc_match,

  (
    gp.delivery_collision_status IN (
      'WINNER_WITH_OTHER_COLLISION_CLUSTER',
      'REJECTED_COLLISION_CLUSTER'
    )
    OR b.pick.provisional_status IN (
      'AMBIGUOUS_ANC_MATCH',
      'ANC_LINK_DATE_IMPLAUSIBLE'
    )

    -- Direct-SIGIZI rescue is accepted from source-level provenance + dating,
    -- but retain a QA flag when the FINAL canonical pregnancy dating disagrees.
    OR (
      b.pick.method = 'DIRECT_SIGIZI_SOURCE_RECORD_TEMPORALLY_PLAUSIBLE'
      AND (
        b.pick.days_from_anchor IS NULL
        OR b.pick.days_from_anchor NOT BETWEEN anc_min_days_from_anchor
                                           AND anc_max_days_from_anchor
        OR ABS(COALESCE(b.pick.days_from_expected, 999999)) > 42
      )
    )
  ) AS anc_link_qa_required

FROM group_pre gp
LEFT JOIN best_pre_link b
  USING (delivery_event_id)
LEFT JOIN
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3` p
  USING (pregnancy_episode_id);


-- ============================================================================
-- N. FINAL v3 DELIVERY EVENT MASTER
-- ============================================================================

CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_v3`
PARTITION BY delivery_date
CLUSTER BY anc_link_status, nik_clean, puskesmas_norm, delivery_event_id
AS

WITH grouped AS (
  SELECT
    m.delivery_event_id,

    COUNT(*) AS source_record_count,
    COUNT(DISTINCT b.source_system) AS source_system_count,

    ARRAY_AGG(b.source_event_id ORDER BY b.source_system, b.source_event_id)
      AS source_event_ids,

    ARRAY_AGG(
      DISTINCT b.source_record_id
      IGNORE NULLS
      ORDER BY b.source_record_id
    ) AS source_record_ids,

    ARRAY_AGG(DISTINCT b.source_system ORDER BY b.source_system)
      AS delivery_source_systems,

    STRING_AGG(DISTINCT b.source_system, ' + ' ORDER BY b.source_system)
      AS delivery_source_combination,

    ARRAY_AGG(
      DISTINCT b.source_subtype
      IGNORE NULLS
      ORDER BY b.source_subtype
    ) AS delivery_source_subtypes,

    ARRAY_AGG(
      DISTINCT b.epus_episode_source_key
      IGNORE NULLS
      ORDER BY b.epus_episode_source_key
    ) AS epus_episode_source_keys,

    -- ----------------------------------------------------------------------
    -- Canonical identity picks
    -- ----------------------------------------------------------------------
    ARRAY_AGG(
      IF(
        b.nik_clean IS NOT NULL,
        STRUCT(
          b.nik_clean AS value,
          b.source_system AS source_system,
          b.source_priority AS source_priority,
          nik_is_trusted(b.nik_clean) AS trusted
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY
        IF(nik_is_trusted(b.nik_clean), 0, 1),
        b.source_priority,
        b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS nik_pick,

    ARRAY_AGG(
      IF(
        b.nama_ibu IS NOT NULL,
        STRUCT(
          b.nama_ibu AS value,
          b.nama_norm AS value_norm,
          b.nama_compact_norm AS value_compact,
          b.source_system AS source_system,
          b.source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY
        b.delivery_record_quality_score DESC,
        b.source_priority,
        b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS name_pick,

    ARRAY_AGG(
      IF(
        b.tanggal_lahir_ibu IS NOT NULL,
        STRUCT(
          b.tanggal_lahir_ibu AS value,
          b.source_system AS source_system,
          b.source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY
        b.delivery_record_quality_score DESC,
        b.source_priority,
        b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS dob_pick,

    ARRAY_AGG(
      IF(
        b.no_hp_clean IS NOT NULL AND LENGTH(b.no_hp_clean) >= 8,
        STRUCT(
          b.no_hp_clean AS value,
          b.source_system AS source_system,
          b.source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY
        b.delivery_record_quality_score DESC,
        b.source_priority,
        b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS phone_pick,

    ARRAY_AGG(
      IF(
        b.puskesmas IS NOT NULL,
        STRUCT(
          b.puskesmas AS value,
          b.puskesmas_norm AS value_norm,
          b.source_system AS source_system,
          b.source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY b.source_priority, b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS puskesmas_pick,

    ARRAY_AGG(
      IF(
        b.desa IS NOT NULL,
        STRUCT(
          b.desa AS value,
          b.desa_norm AS value_norm,
          b.source_system AS source_system,
          b.source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY b.source_priority, b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS desa_pick,

    -- Best raw record supporting the later consensus canonical date is joined
    -- after aggregation. This pick is only used as fallback metadata.
    ARRAY_AGG(
      STRUCT(
        b.delivery_date AS value,
        b.source_system AS source_system,
        b.source_subtype AS source_subtype,
        b.source_priority AS source_priority,
        b.source_event_id AS source_event_id
      )
      ORDER BY b.source_priority, b.delivery_date, b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS fallback_delivery_pick,

    ARRAY_AGG(
      IF(
        b.delivery_outcome IS NOT NULL,
        STRUCT(
          b.delivery_outcome AS value,
          b.source_system AS source_system,
          b.source_subtype AS source_subtype,
          b.source_priority AS source_priority,
          b.source_event_id AS source_event_id
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY b.source_priority, b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS outcome_pick,

    ARRAY_AGG(
      IF(
        b.maternal_outcome_norm IS NOT NULL,
        STRUCT(
          b.maternal_outcome_norm AS value,
          b.source_system AS source_system,
          b.source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY b.source_priority, b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS maternal_outcome_pick,

    ARRAY_AGG(
      IF(
        b.delivery_mode_norm IS NOT NULL,
        STRUCT(
          b.delivery_mode_norm AS value,
          b.source_system AS source_system,
          b.source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY b.source_priority, b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS delivery_mode_pick,

    ARRAY_AGG(
      IF(
        b.delivery_facility_norm IS NOT NULL,
        STRUCT(
          b.delivery_facility_norm AS value,
          b.source_system AS source_system,
          b.source_priority AS source_priority
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY b.source_priority, b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS delivery_facility_pick,

    -- ----------------------------------------------------------------------
    -- All observed values / conflicts
    -- ----------------------------------------------------------------------
    ARRAY_AGG(DISTINCT b.nik_clean IGNORE NULLS ORDER BY b.nik_clean)
      AS all_nik_values,

    ARRAY_AGG(
      DISTINCT CAST(b.tanggal_lahir_ibu AS STRING)
      IGNORE NULLS
      ORDER BY CAST(b.tanggal_lahir_ibu AS STRING)
    ) AS all_dob_values,

    ARRAY_AGG(DISTINCT b.nama_ibu IGNORE NULLS ORDER BY b.nama_ibu)
      AS all_name_values,

    ARRAY_AGG(
      DISTINCT b.nama_compact_norm
      IGNORE NULLS
      ORDER BY b.nama_compact_norm
    ) AS all_compact_name_values,

    ARRAY_AGG(
      DISTINCT CAST(b.delivery_date AS STRING)
      ORDER BY CAST(b.delivery_date AS STRING)
    ) AS all_delivery_dates,

    COUNT(DISTINCT b.delivery_date) AS delivery_date_distinct_count,
    MIN(b.delivery_date) AS min_delivery_date,
    MAX(b.delivery_date) AS max_delivery_date,

    COUNT(DISTINCT IF(b.nik_trusted_flag, b.nik_clean, NULL))
      AS trusted_nik_distinct_count,

    COUNT(DISTINCT b.tanggal_lahir_ibu) AS dob_distinct_count,
    COUNT(DISTINCT b.nama_compact_norm) AS compact_name_distinct_count,

    -- ----------------------------------------------------------------------
    -- Outcome evidence
    -- ----------------------------------------------------------------------
    LOGICAL_OR(b.delivery_outcome = 'LAHIR HIDUP') AS has_live_birth_evidence,
    LOGICAL_OR(b.delivery_outcome = 'LAHIR MATI') AS has_stillbirth_evidence,

    -- ----------------------------------------------------------------------
    -- Presence by source
    -- ----------------------------------------------------------------------
    LOGICAL_OR(b.source_system = 'SIGIZI') AS has_delivery_sigizi,
    LOGICAL_OR(b.source_system = 'EPUS') AS has_delivery_epus,
    LOGICAL_OR(b.source_system = 'SIMRS') AS has_delivery_simrs,
    LOGICAL_OR(b.source_system = 'KOBO_INC') AS has_delivery_kobo_inc,
    LOGICAL_OR(b.source_system = 'NEONATAL_OUTCOME') AS has_delivery_neonatal,
    LOGICAL_OR(b.source_system = 'INC_REPORT_TRACKER') AS has_delivery_inc_report,

    -- ----------------------------------------------------------------------
    -- Source-specific outcome evidence
    -- ----------------------------------------------------------------------
    LOGICAL_OR(b.source_system = 'SIGIZI' AND b.delivery_outcome = 'LAHIR HIDUP')
      AS sigizi_live_evidence,
    LOGICAL_OR(b.source_system = 'SIGIZI' AND b.delivery_outcome = 'LAHIR MATI')
      AS sigizi_still_evidence,

    LOGICAL_OR(b.source_system = 'EPUS' AND b.delivery_outcome = 'LAHIR HIDUP')
      AS epus_live_evidence,
    LOGICAL_OR(b.source_system = 'EPUS' AND b.delivery_outcome = 'LAHIR MATI')
      AS epus_still_evidence,

    LOGICAL_OR(b.source_system = 'SIMRS' AND b.delivery_outcome = 'LAHIR HIDUP')
      AS simrs_live_evidence,
    LOGICAL_OR(b.source_system = 'SIMRS' AND b.delivery_outcome = 'LAHIR MATI')
      AS simrs_still_evidence,

    LOGICAL_OR(b.source_system = 'KOBO_INC' AND b.delivery_outcome = 'LAHIR HIDUP')
      AS kobo_live_evidence,
    LOGICAL_OR(b.source_system = 'KOBO_INC' AND b.delivery_outcome = 'LAHIR MATI')
      AS kobo_still_evidence,

    LOGICAL_OR(
      b.source_system = 'NEONATAL_OUTCOME'
      AND b.delivery_outcome = 'LAHIR HIDUP'
    ) AS neonatal_live_evidence,

    LOGICAL_OR(
      b.source_system = 'NEONATAL_OUTCOME'
      AND b.delivery_outcome = 'LAHIR MATI'
    ) AS neonatal_still_evidence,

    LOGICAL_OR(
      b.source_system = 'INC_REPORT_TRACKER'
      AND b.delivery_outcome = 'LAHIR HIDUP'
    ) AS tracker_live_evidence,

    LOGICAL_OR(
      b.source_system = 'INC_REPORT_TRACKER'
      AND b.delivery_outcome = 'LAHIR MATI'
    ) AS tracker_still_evidence,

    MIN(b.source_reference_date) AS earliest_source_reference_date

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_member_map_v3` m
  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_dedup_base` b
    USING (source_event_id)
  GROUP BY m.delivery_event_id
),

primary_date_source AS (
  SELECT
    m.delivery_event_id,
    ARRAY_AGG(
      STRUCT(
        b.source_system AS source_system,
        b.source_subtype AS source_subtype,
        b.source_priority AS source_priority,
        b.source_event_id AS source_event_id
      )
      ORDER BY b.source_priority, b.source_event_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS pick
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_member_map_v3` m
  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_dedup_base` b
    USING (source_event_id)
  JOIN
    `_SESSION.t_delivery_date_pick_v3` dp
    ON dp.delivery_event_id = m.delivery_event_id
   AND dp.delivery_date = b.delivery_date
  GROUP BY m.delivery_event_id
)

SELECT
  g.delivery_event_id,

  g.source_record_count,
  g.source_system_count,
  g.source_event_ids,
  g.source_record_ids,
  g.delivery_source_systems,
  g.delivery_source_combination,
  g.delivery_source_subtypes,
  g.epus_episode_source_keys,

  g.nik_pick.value AS nik_clean,
  g.nik_pick.source_system AS nik_source,

  g.name_pick.value AS nama_ibu,
  g.name_pick.value_norm AS nama_norm,
  g.name_pick.value_compact AS nama_compact_norm,
  g.name_pick.source_system AS nama_source,

  g.dob_pick.value AS tanggal_lahir_ibu,
  g.dob_pick.source_system AS dob_source,

  g.phone_pick.value AS no_hp_clean,
  g.phone_pick.source_system AS phone_source,

  g.puskesmas_pick.value AS puskesmas,
  g.puskesmas_pick.value_norm AS puskesmas_norm,
  g.puskesmas_pick.source_system AS puskesmas_source,

  g.desa_pick.value AS desa,
  g.desa_pick.value_norm AS desa_norm,
  g.desa_pick.source_system AS desa_source,

  dp.delivery_date,
  pds.pick.source_system AS primary_delivery_source,
  pds.pick.source_subtype AS primary_delivery_source_subtype,
  pds.pick.source_event_id AS primary_delivery_source_event_id,

  dp.canonical_date_source_system_count,
  dp.canonical_date_source_record_count,
  dp.canonical_date_best_source_priority,
  dp.canonical_date_supporting_sources,

  CASE
    WHEN g.has_live_birth_evidence AND g.has_stillbirth_evidence
      THEN 'MIXED_LIVE_STILLBIRTH'
    WHEN g.has_stillbirth_evidence
      THEN 'LAHIR MATI'
    WHEN g.has_live_birth_evidence
      THEN 'LAHIR HIDUP'
    ELSE 'DELIVERY_OUTCOME_UNCLEAR'
  END AS delivery_outcome_final,

  g.outcome_pick.value AS primary_explicit_outcome,
  g.outcome_pick.source_system AS primary_outcome_source,

  g.maternal_outcome_pick.value AS maternal_outcome_final,
  g.maternal_outcome_pick.source_system AS maternal_outcome_source,

  g.delivery_mode_pick.value AS delivery_mode_final,
  g.delivery_mode_pick.source_system AS delivery_mode_source,

  g.delivery_facility_pick.value AS delivery_facility_final,
  g.delivery_facility_pick.source_system AS delivery_facility_source,

  g.has_live_birth_evidence,
  g.has_stillbirth_evidence,

  g.has_delivery_sigizi,
  g.has_delivery_epus,
  g.has_delivery_simrs,
  g.has_delivery_kobo_inc,
  g.has_delivery_neonatal,
  g.has_delivery_inc_report,

  CASE
    WHEN NOT g.has_delivery_sigizi THEN NULL
    WHEN g.sigizi_live_evidence AND g.sigizi_still_evidence
      THEN 'MIXED_LIVE_STILLBIRTH'
    WHEN g.sigizi_still_evidence THEN 'LAHIR MATI'
    WHEN g.sigizi_live_evidence THEN 'LAHIR HIDUP'
    ELSE 'DELIVERY_OUTCOME_UNCLEAR'
  END AS sigizi_delivery_outcome,

  CASE
    WHEN NOT g.has_delivery_epus THEN NULL
    WHEN g.epus_live_evidence AND g.epus_still_evidence
      THEN 'MIXED_LIVE_STILLBIRTH'
    WHEN g.epus_still_evidence THEN 'LAHIR MATI'
    WHEN g.epus_live_evidence THEN 'LAHIR HIDUP'
    ELSE 'DELIVERY_OUTCOME_UNCLEAR'
  END AS epus_delivery_outcome,

  CASE
    WHEN NOT g.has_delivery_simrs THEN NULL
    WHEN g.simrs_live_evidence AND g.simrs_still_evidence
      THEN 'MIXED_LIVE_STILLBIRTH'
    WHEN g.simrs_still_evidence THEN 'LAHIR MATI'
    WHEN g.simrs_live_evidence THEN 'LAHIR HIDUP'
    ELSE 'DELIVERY_OUTCOME_UNCLEAR'
  END AS simrs_delivery_outcome,

  CASE
    WHEN NOT g.has_delivery_kobo_inc THEN NULL
    WHEN g.kobo_live_evidence AND g.kobo_still_evidence
      THEN 'MIXED_LIVE_STILLBIRTH'
    WHEN g.kobo_still_evidence THEN 'LAHIR MATI'
    WHEN g.kobo_live_evidence THEN 'LAHIR HIDUP'
    ELSE 'DELIVERY_OUTCOME_UNCLEAR'
  END AS kobo_delivery_outcome,

  CASE
    WHEN NOT g.has_delivery_neonatal THEN NULL
    WHEN g.neonatal_live_evidence AND g.neonatal_still_evidence
      THEN 'MIXED_LIVE_STILLBIRTH'
    WHEN g.neonatal_still_evidence THEN 'LAHIR MATI'
    WHEN g.neonatal_live_evidence THEN 'LAHIR HIDUP'
    ELSE 'DELIVERY_OUTCOME_UNCLEAR'
  END AS neonatal_delivery_outcome,

  CASE
    WHEN NOT g.has_delivery_inc_report THEN NULL
    WHEN g.tracker_live_evidence AND g.tracker_still_evidence
      THEN 'MIXED_LIVE_STILLBIRTH'
    WHEN g.tracker_still_evidence THEN 'LAHIR MATI'
    WHEN g.tracker_live_evidence THEN 'LAHIR HIDUP'
    ELSE 'DELIVERY_OUTCOME_UNCLEAR'
  END AS inc_report_delivery_outcome,

  g.all_nik_values,
  g.all_dob_values,
  g.all_name_values,
  g.all_compact_name_values,
  g.all_delivery_dates,

  g.delivery_date_distinct_count,
  g.min_delivery_date,
  g.max_delivery_date,

  DATE_DIFF(g.max_delivery_date, g.min_delivery_date, DAY)
    AS delivery_date_range_days,

  g.delivery_date_distinct_count > 1 AS delivery_date_conflict_flag,

  g.trusted_nik_distinct_count,
  g.dob_distinct_count,
  g.compact_name_distinct_count,

  g.trusted_nik_distinct_count > 1 AS trusted_nik_conflict_flag,
  g.dob_distinct_count > 1 AS dob_conflict_flag,
  g.compact_name_distinct_count > 1 AS name_variant_flag,

  g.earliest_source_reference_date,

  gm.preconsolidation_delivery_event_ids,
  gm.preconsolidation_event_count,
  gm.pregnancy_delivery_cluster_count,
  gm.pregnancy_cluster_rank,
  gm.delivery_collision_status,
  gm.postanc_cluster_independent_source_count,
  gm.postanc_cluster_delivery_date_span_days,

  gm.pregnancy_episode_id,
  gm.anc_link_status,
  gm.anc_link_method,
  gm.anc_link_priority,
  gm.anc_link_confidence,
  gm.anc_match_distance_days,
  gm.anc_days_from_pregnancy_anchor,
  gm.anc_days_from_expected_delivery,

  gm.anc_candidate_count,
  gm.anc_top_candidate_count,

  gm.best_candidate_pregnancy_episode_id,
  gm.best_candidate_anc_match_method,
  gm.best_candidate_anc_match_priority,
  gm.best_candidate_anc_match_confidence,
  gm.best_candidate_match_distance_days,
  gm.best_candidate_days_from_pregnancy_anchor,
  gm.best_candidate_days_from_expected_delivery,
  gm.best_candidate_date_plausible_flag,

  gm.anc_pregnancy_source_combination,
  gm.anc_nik_clean,
  gm.anc_nama_ibu,
  gm.anc_tanggal_lahir_ibu,
  gm.anc_no_hp_clean,
  gm.anc_puskesmas,
  gm.anc_puskesmas_norm,
  gm.anc_desa,
  gm.anc_desa_norm,
  gm.anc_posyandu,
  gm.anc_hpht_date,
  gm.anc_hpl_recorded_date,
  gm.anc_hpl_from_hpht_date,
  gm.anc_pregnancy_anchor_date,
  gm.anc_expected_delivery_date,
  gm.has_anc_match,
  gm.anc_link_qa_required,

  -- Primary dashboard denominator flag:
  -- collision-rejected records remain visible but are separated from the strict
  -- canonical birth denominator until adjudicated.
  gm.anc_link_status != 'ANC_LINK_COLLISION_REJECTED'
    AS strict_birth_count_eligible_flag,

  (
    gm.anc_link_qa_required
    OR g.trusted_nik_distinct_count > 1
    OR g.dob_distinct_count > 1
    OR g.delivery_date_distinct_count > 1
  ) AS delivery_qa_required

FROM grouped g
JOIN
  `_SESSION.t_delivery_date_pick_v3` dp
  USING (delivery_event_id)
LEFT JOIN primary_date_source pds
  USING (delivery_event_id)
JOIN
  `_SESSION.t_delivery_event_group_meta_v3` gm
  USING (delivery_event_id);
