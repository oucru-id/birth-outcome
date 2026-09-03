-- Recovered source builder; v3 target. Run the complete file.
-- StandardSQL
-- ============================================================
-- ePUSKESMAS PREGNANCY MASTER
--
-- Output:
--   spheres-lombok-barat.kohort_bumil_v2
--   .t_epus_pregnancy_master
--
-- Grain:
--   ONE ROW = ONE MOTHER + ONE PREGNANCY
--
-- Core sources:
--   EPUS_ANC
--   EPUS_KUNJUNGAN_IBU_HAMIL
--   EPUS_INC
--   EPUS_PNC
--
-- ANC count uses:
--   t_epus_anc_canonical_events
--
-- so EPUS_ANC vs EPUS_KUNJUNGAN overlap is NOT double-counted.
--
-- IMPORTANT:
-- - Gravida/partus/abortus fields are NOT used to infer
--   current pregnancy outcome.
-- - Pregnancy outcome comes from current INC evidence.
-- - Multiple INC baby records can belong to one pregnancy.
-- ============================================================


CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_master`

PARTITION BY pregnancy_episode_anchor_date

CLUSTER BY
  puskesmas_norm,
  pregnancy_status_inferred,
  epus_mother_key

AS


WITH
-- ============================================================
-- 1. PREGNANCY-ASSIGNED SOURCE RECORDS
-- ============================================================
pr AS (
  SELECT
    *
  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_records`
),


-- ============================================================
-- 2. BASIC PREGNANCY EPISODE SUMMARY
-- ============================================================
episode_core AS (
  SELECT
    epus_pregnancy_key,
    epus_mother_key,

    ANY_VALUE(pregnancy_episode_number)
      AS pregnancy_episode_number,

    ANY_VALUE(pregnancy_episode_anchor_date)
      AS pregnancy_episode_anchor_date,


    -- --------------------------------------------------------
    -- Canonical pregnancy reference from episode assignment
    -- --------------------------------------------------------
    ANY_VALUE(pregnancy_reference_date)
      AS pregnancy_reference_date,

    ANY_VALUE(pregnancy_reference_method)
      AS pregnancy_reference_method,

    ANY_VALUE(pregnancy_reference_confidence)
      AS pregnancy_reference_confidence,

    ANY_VALUE(pregnancy_reference_source_record_key)
      AS pregnancy_reference_source_record_key,

    ANY_VALUE(pregnancy_reference_source_table)
      AS pregnancy_reference_source_table,


    -- --------------------------------------------------------
    -- Anchor QA
    -- --------------------------------------------------------
    MIN(anchor_reference_min_date)
      AS anchor_reference_min_date,

    MAX(anchor_reference_max_date)
      AS anchor_reference_max_date,

    MAX(pregnancy_anchor_span_days)
      AS pregnancy_anchor_span_days,


    -- --------------------------------------------------------
    -- Event timeline
    -- --------------------------------------------------------
    MIN(event_date)
      AS pregnancy_first_event_date,

    MAX(event_date)
      AS pregnancy_latest_event_date,


    -- --------------------------------------------------------
    -- Pregnancy assignment QA
    -- --------------------------------------------------------
    COUNT(*)
      AS source_record_count,

    COUNTIF(
      pregnancy_match_confidence = 'LOW'
    ) AS low_confidence_assignment_record_count,

    LOGICAL_OR(
      pregnancy_match_confidence = 'LOW'
    ) AS has_low_confidence_assignment,

    LOGICAL_OR(
      pregnancy_assignment_method =
        'UNRESOLVED_NO_PREGNANCY_DATE'
    ) AS has_unresolved_pregnancy_assignment,


    ARRAY_AGG(
      DISTINCT pregnancy_assignment_method
      IGNORE NULLS
      ORDER BY pregnancy_assignment_method
    ) AS pregnancy_assignment_methods

  FROM pr

  GROUP BY
    epus_pregnancy_key,
    epus_mother_key
),


-- ============================================================
-- 3. BEST IDENTITY RECORD PER PREGNANCY
--
-- Prefer records containing:
--   resolved NIK
--   name
--   DOB
--   phone
--   address
-- ============================================================
identity_scored AS (
  SELECT
    p.*,

    (
      IF(
        COALESCE(
          resolved_nik,
          nik_clean
        ) IS NOT NULL,
        10,
        0
      )

      + IF(nama_norm IS NOT NULL, 4, 0)
      + IF(tanggal_lahir IS NOT NULL, 4, 0)
      + IF(no_hp_norm IS NOT NULL, 2, 0)
      + IF(alamat IS NOT NULL, 1, 0)
      + IF(puskesmas_norm IS NOT NULL, 1, 0)

    ) AS identity_completeness_score

  FROM pr p
),


identity_best AS (
  SELECT
    epus_pregnancy_key,

    COALESCE(
      resolved_nik,
      nik_clean
    ) AS nik,

    nama,
    nama_norm,

    tanggal_lahir,

    no_hp_raw,
    no_hp_clean,
    no_hp_norm,

    alamat,

    mother_match_method,
    mother_match_confidence

  FROM identity_scored

  QUALIFY
    ROW_NUMBER() OVER (
      PARTITION BY epus_pregnancy_key

      ORDER BY
        identity_completeness_score DESC,
        source_recency_timestamp DESC,
        epus_source_record_key DESC
    ) = 1
),


-- ============================================================
-- 4. FACILITY COUNTS
--
-- Pick the most frequently represented Puskesmas within the
-- pregnancy. Latest record breaks ties.
-- ============================================================
facility_counts AS (
  SELECT
    epus_pregnancy_key,
    puskesmas_norm,

    COUNT(*) AS facility_record_count,

    MAX(source_recency_timestamp)
      AS facility_latest_source_timestamp,


    ARRAY_AGG(
      STRUCT(
        puskesmas AS puskesmas,
        puskesmas_id AS puskesmas_id,
        source_recency_timestamp AS recency
      )

      ORDER BY
        source_recency_timestamp DESC,
        epus_source_record_key DESC

      LIMIT 1
    )[OFFSET(0)] AS latest_facility

  FROM pr

  WHERE
    puskesmas_norm IS NOT NULL

  GROUP BY
    epus_pregnancy_key,
    puskesmas_norm
),


facility_summary AS (
  SELECT
    epus_pregnancy_key,


    ARRAY_AGG(
      STRUCT(
        puskesmas_norm AS puskesmas_norm,

        latest_facility.puskesmas
          AS puskesmas,

        latest_facility.puskesmas_id
          AS puskesmas_id,

        facility_record_count
          AS facility_record_count,

        facility_latest_source_timestamp
          AS latest_source_timestamp
      )

      ORDER BY
        facility_record_count DESC,
        facility_latest_source_timestamp DESC,
        puskesmas_norm

      LIMIT 1
    )[OFFSET(0)] AS primary_facility,


    COUNT(*)
      AS pregnancy_puskesmas_count,


    ARRAY_AGG(
      latest_facility.puskesmas
      ORDER BY latest_facility.puskesmas
    ) AS pregnancy_puskesmas_list

  FROM facility_counts

  GROUP BY
    epus_pregnancy_key
),


-- ============================================================
-- 5. REPORTED HPL
--
-- HPHT itself is represented by pregnancy_reference_date
-- whenever pregnancy_reference_method = HPHT_REPORTED.
--
-- HPL remains source-reported, not recalculated here.
-- ============================================================
hpl_best AS (
  SELECT
    epus_pregnancy_key,

    hpl_date

  FROM pr

  WHERE
    hpl_date IS NOT NULL

  QUALIFY
    ROW_NUMBER() OVER (
      PARTITION BY epus_pregnancy_key

      ORDER BY
        source_recency_timestamp DESC,
        source_row_completeness_score DESC,
        epus_source_record_key DESC
    ) = 1
),


-- ============================================================
-- 6. DELIVERY DATE
--
-- Keep current logic:
--
-- EPUS_INC delivery_date already represents:
--
-- COALESCE(
--   bayi_lahir_tanggal,
--   tanggal_persalinan,
--   plasenta_lahir_tanggal
-- )
--
-- Pregnancy-level source priority:
--   INC first
--   PNC second
-- ============================================================
delivery_candidates AS (
  SELECT
    epus_pregnancy_key,

    delivery_date,
    delivery_date_source,

    source_table,
    source_recency_timestamp,

    epus_source_record_key,

    CASE
      WHEN source_table = 'EPUS_INC'
      THEN 1

      WHEN source_table = 'EPUS_PNC'
      THEN 2

      ELSE 9
    END AS delivery_source_priority

  FROM pr

  WHERE
    delivery_date IS NOT NULL
),


delivery_best AS (
  SELECT
    epus_pregnancy_key,

    delivery_date,

    delivery_date_source,

    source_table
      AS delivery_source_table,

    epus_source_record_key
      AS delivery_source_record_key

  FROM delivery_candidates

  QUALIFY
    ROW_NUMBER() OVER (
      PARTITION BY epus_pregnancy_key

      ORDER BY
        delivery_source_priority ASC,
        source_recency_timestamp DESC,
        epus_source_record_key DESC
    ) = 1
),


delivery_qa AS (
  SELECT
    epus_pregnancy_key,

    MIN(delivery_date)
      AS delivery_date_min,

    MAX(delivery_date)
      AS delivery_date_max,

    COUNT(
      DISTINCT delivery_date
    ) AS distinct_delivery_date_count

  FROM delivery_candidates

  GROUP BY
    epus_pregnancy_key
),


-- ============================================================
-- 7. SOURCE PRESENCE / COUNTS
-- ============================================================
source_summary AS (
  SELECT
    epus_pregnancy_key,


    -- --------------------------------------------------------
    -- Source-specific retained event records
    -- --------------------------------------------------------
    COUNTIF(
      source_table = 'EPUS_ANC'
    ) AS epus_anc_source_record_count,

    COUNTIF(
      source_table = 'EPUS_KUNJUNGAN_IBU_HAMIL'
    ) AS epus_kunjungan_source_record_count,

    COUNTIF(
      source_table = 'EPUS_INC'
    ) AS epus_inc_source_record_count,

    COUNTIF(
      source_table = 'EPUS_PNC'
    ) AS epus_pnc_source_record_count,


    -- --------------------------------------------------------
    -- ANC raw source representations before cross-source
    -- canonicalization
    -- --------------------------------------------------------
    COUNTIF(
      event_type = 'ANC'
    ) AS raw_anc_source_record_count,


    -- --------------------------------------------------------
    -- Source presence
    -- --------------------------------------------------------
    LOGICAL_OR(
      source_table = 'EPUS_ANC'
    ) AS has_epus_anc,

    LOGICAL_OR(
      source_table = 'EPUS_KUNJUNGAN_IBU_HAMIL'
    ) AS has_epus_kunjungan_ibu_hamil,

    LOGICAL_OR(
      source_table = 'EPUS_INC'
    ) AS has_epus_inc,

    LOGICAL_OR(
      source_table = 'EPUS_PNC'
    ) AS has_epus_pnc,


    COUNT(
      DISTINCT source_table
    ) AS source_table_count

  FROM pr

  GROUP BY
    epus_pregnancy_key
),


-- ============================================================
-- 8. CANONICAL ANC SUMMARY
--
-- IMPORTANT:
-- This uses the deduplicated/canonical ANC encounter table,
-- NOT raw ANC source-record count.
-- ============================================================
anc_summary AS (
  SELECT
    epus_pregnancy_key,


    COUNT(*)
      AS anc_visit_count,


    MIN(anc_date)
      AS first_anc_date,

    MAX(anc_date)
      AS latest_anc_date,


    -- --------------------------------------------------------
    -- K visit labels
    -- --------------------------------------------------------
    COUNTIF(
      UPPER(TRIM(visit_label)) = 'K1'
    ) AS anc_k1_count,

    COUNTIF(
      UPPER(TRIM(visit_label)) = 'K2'
    ) AS anc_k2_count,

    COUNTIF(
      UPPER(TRIM(visit_label)) = 'K3'
    ) AS anc_k3_count,

    COUNTIF(
      UPPER(TRIM(visit_label)) = 'K4'
    ) AS anc_k4_count,

    COUNTIF(
      UPPER(TRIM(visit_label)) = 'K5'
    ) AS anc_k5_count,

    COUNTIF(
      UPPER(TRIM(visit_label)) = 'K6'
    ) AS anc_k6_count,


    ARRAY_AGG(
      DISTINCT visit_label
      IGNORE NULLS
      ORDER BY visit_label
    ) AS anc_visit_labels,


    -- --------------------------------------------------------
    -- Source overlap
    -- --------------------------------------------------------
    COUNTIF(
      cross_source_overlap_flag = TRUE
    ) AS anc_cross_source_overlap_event_count,


    COUNTIF(
      flag_same_date_cross_source_unmerged = TRUE
    ) AS anc_same_date_different_facility_event_count,


    LOGICAL_OR(
      has_epus_anc_source
    ) AS anc_has_epus_anc_source,


    LOGICAL_OR(
      has_epus_kunjungan_ibu_hamil_source
    ) AS anc_has_epus_kunjungan_source

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_anc_canonical_events`

  GROUP BY
    epus_pregnancy_key
),


-- ============================================================
-- 9. PNC SUMMARY
-- ============================================================
pnc_summary AS (
  SELECT
    epus_pregnancy_key,


    COUNT(*)
      AS pnc_visit_count,


    MIN(pnc_date)
      AS first_pnc_date,

    MAX(pnc_date)
      AS latest_pnc_date,


    COUNTIF(
      UPPER(TRIM(visit_label)) = 'KF1'
    ) AS pnc_kf1_count,

    COUNTIF(
      UPPER(TRIM(visit_label)) = 'KF2'
    ) AS pnc_kf2_count,

    COUNTIF(
      UPPER(TRIM(visit_label)) = 'KF3'
    ) AS pnc_kf3_count,

    COUNTIF(
      UPPER(TRIM(visit_label)) = 'KF4'
    ) AS pnc_kf4_count,


    ARRAY_AGG(
      DISTINCT visit_label
      IGNORE NULLS
      ORDER BY visit_label
    ) AS pnc_visit_labels

  FROM pr

  WHERE
    event_type = 'PNC'

  GROUP BY
    epus_pregnancy_key
),


-- ============================================================
-- 10. ASSIGN INC SOURCE ROWS BACK TO FULL vs_epus_inc
--
-- source_event_identity from t_epus_source_records contains
-- inc_encounter_key, so this gives us pregnancy assignment
-- while retaining the rich INC clinical fields.
-- ============================================================
inc_assigned AS (
  SELECT
    p.epus_pregnancy_key,
    p.epus_mother_key,
    p.epus_source_record_key,

    i.*

  FROM pr p

  INNER JOIN
    `spheres-lombok-barat.kohort_bumil_v3.vs_epus_inc` i

    ON p.source_event_identity
       = i.inc_encounter_key

  WHERE
    p.source_table = 'EPUS_INC'
),


-- ============================================================
-- 11. BEST INC RECORD
--
-- Used for pregnancy-level clinical variables that should not
-- simply be added across babies.
-- ============================================================
inc_best_record AS (
  SELECT
    epus_pregnancy_key,

    epus_inc_record_key,

    usia_kehamilan_numeric
      AS gestational_age_at_delivery_weeks,

    cara_persalinan_clean
      AS delivery_mode,

    penolong_clean
      AS birth_attendant,

    presentasi_clean
      AS birth_presentation,

    komplikasi_persalinan_clean
      AS delivery_complication,

    komplikasi_clean
      AS complication_general,

    keadaan_ibu_saat_ini_clean
      AS maternal_current_condition,

    birth_outcome_supporting_text

  FROM inc_assigned

  QUALIFY
    ROW_NUMBER() OVER (
      PARTITION BY epus_pregnancy_key

      ORDER BY
        row_completeness_score DESC,
        source_recency_timestamp DESC,
        epus_inc_record_key DESC
    ) = 1
),


-- ============================================================
-- 12. INC / BABY / MATERNAL OUTCOME SUMMARY
-- ============================================================
inc_summary AS (
  SELECT
    epus_pregnancy_key,


    -- --------------------------------------------------------
    -- INC baby/source records
    -- --------------------------------------------------------
    COUNT(*)
      AS inc_baby_record_count,


    -- --------------------------------------------------------
    -- Baby outcome counts
    -- --------------------------------------------------------
    COUNTIF(
      birth_outcome_category = 'LAHIR HIDUP'
    ) AS live_birth_baby_record_count,


    COUNTIF(
      birth_outcome_category = 'LAHIR MATI'
    ) AS stillbirth_baby_record_count,


    COUNTIF(
      birth_outcome_category = 'UNKNOWN'
    ) AS unknown_birth_outcome_baby_record_count,


    COUNTIF(
      birth_outcome_category != 'UNKNOWN'
    ) AS known_birth_outcome_baby_record_count,


    -- --------------------------------------------------------
    -- Pregnancy-level baby outcome
    --
    -- One pregnancy can have mixed outcome in multiple birth.
    -- --------------------------------------------------------
    CASE
      WHEN
        COUNTIF(
          birth_outcome_category = 'LAHIR HIDUP'
        ) > 0

        AND

        COUNTIF(
          birth_outcome_category = 'LAHIR MATI'
        ) > 0
      THEN 'CAMPURAN'


      WHEN COUNTIF(
        birth_outcome_category = 'LAHIR HIDUP'
      ) > 0
      THEN 'LAHIR HIDUP'


      WHEN COUNTIF(
        birth_outcome_category = 'LAHIR MATI'
      ) > 0
      THEN 'LAHIR MATI'


      ELSE 'UNKNOWN'
    END AS birth_outcome_category,


    -- --------------------------------------------------------
    -- Is every baby's birth outcome resolved?
    -- --------------------------------------------------------
    CASE
      WHEN COUNT(*) > 0
       AND COUNTIF(
         birth_outcome_category = 'UNKNOWN'
       ) = 0
      THEN TRUE

      ELSE FALSE
    END AS birth_outcome_complete_flag,


    -- --------------------------------------------------------
    -- Outcome confidence
    -- --------------------------------------------------------
    CASE
      WHEN
        COUNTIF(
          birth_outcome_category != 'UNKNOWN'
        ) = 0
      THEN 'LOW'

      WHEN
        COUNTIF(
          birth_outcome_category = 'UNKNOWN'
        ) = 0

        AND

        COUNTIF(
          birth_outcome_confidence != 'HIGH'
        ) = 0
      THEN 'HIGH'

      ELSE 'MEDIUM'
    END AS birth_outcome_confidence,


    'EPUS_INC'
      AS birth_outcome_source,


    -- --------------------------------------------------------
    -- Death evidence
    -- --------------------------------------------------------
    LOGICAL_OR(
      baby_death_recorded
    ) AS baby_death_recorded,


    COUNTIF(
      baby_death_recorded
    ) AS baby_death_record_count,


    -- --------------------------------------------------------
    -- Baby identity / sex
    -- --------------------------------------------------------
    ARRAY_AGG(
      DISTINCT nama_bayi_clean
      IGNORE NULLS
      ORDER BY nama_bayi_clean
    ) AS baby_name_list,


    ARRAY_AGG(
      DISTINCT jenis_kelamin_bayi_clean
      IGNORE NULLS
      ORDER BY jenis_kelamin_bayi_clean
    ) AS baby_sex_list,


    -- --------------------------------------------------------
    -- Birth weight
    -- --------------------------------------------------------
    MIN(bb_bayi_numeric)
      AS birth_weight_min_gram,

    MAX(bb_bayi_numeric)
      AS birth_weight_max_gram,


    COUNTIF(
      bb_bayi_numeric IS NOT NULL
    ) AS birth_weight_record_count,


    COUNTIF(
      bb_bayi_numeric > 0
      AND bb_bayi_numeric < 2500
    ) AS bblr_baby_record_count,


    -- --------------------------------------------------------
    -- Maternal vital outcome
    --
    -- Death has priority across INC rows.
    -- --------------------------------------------------------
    CASE
      WHEN COUNTIF(
        maternal_outcome_category = 'MENINGGAL'
      ) > 0
      THEN 'MENINGGAL'

      WHEN COUNTIF(
        maternal_outcome_category = 'HIDUP'
      ) > 0
      THEN 'HIDUP'

      ELSE 'UNKNOWN'
    END AS maternal_outcome_category,


    LOGICAL_OR(
      maternal_death_recorded
    ) AS maternal_death_recorded,


    -- --------------------------------------------------------
    -- Maternal post-delivery condition
    --
    -- Severity priority:
    -- MENINGGAL
    -- TIDAK STABIL
    -- DIRUJUK
    -- STABIL
    -- UNKNOWN
    -- --------------------------------------------------------
    CASE
      WHEN COUNTIF(
        maternal_postdelivery_status = 'MENINGGAL'
      ) > 0
      THEN 'MENINGGAL'

      WHEN COUNTIF(
        maternal_postdelivery_status = 'TIDAK STABIL'
      ) > 0
      THEN 'TIDAK STABIL'

      WHEN COUNTIF(
        maternal_postdelivery_status = 'DIRUJUK'
      ) > 0
      THEN 'DIRUJUK'

      WHEN COUNTIF(
        maternal_postdelivery_status = 'STABIL'
      ) > 0
      THEN 'STABIL'

      ELSE 'UNKNOWN'
    END AS maternal_postdelivery_status,


    LOGICAL_OR(
      flag_maternal_outcome_conflict
    ) AS flag_maternal_outcome_conflict,


    -- --------------------------------------------------------
    -- Maternal outcome cross-row contradiction
    -- --------------------------------------------------------
    CASE
      WHEN
        COUNTIF(
          maternal_outcome_category = 'MENINGGAL'
        ) > 0

        AND

        COUNTIF(
          maternal_outcome_category = 'HIDUP'
        ) > 0
      THEN TRUE

      ELSE FALSE
    END AS flag_maternal_outcome_cross_record_difference,


    -- --------------------------------------------------------
    -- Delivery modes / attendants across multiple INC rows
    -- --------------------------------------------------------
    ARRAY_AGG(
      DISTINCT cara_persalinan_clean
      IGNORE NULLS
      ORDER BY cara_persalinan_clean
    ) AS delivery_mode_list,


    ARRAY_AGG(
      DISTINCT penolong_clean
      IGNORE NULLS
      ORDER BY penolong_clean
    ) AS birth_attendant_list,


    ARRAY_AGG(
      DISTINCT komplikasi_persalinan_clean
      IGNORE NULLS
      ORDER BY komplikasi_persalinan_clean
    ) AS delivery_complication_list

  FROM inc_assigned

  GROUP BY
    epus_pregnancy_key
),


-- ============================================================
-- 13. BUILD MASTER
-- ============================================================
master_pre AS (
  SELECT
    e.epus_pregnancy_key,
    e.epus_mother_key,

    e.pregnancy_episode_number,


    -- ========================================================
    -- IDENTITY
    -- ========================================================
    i.nik,

    i.nama,
    i.nama_norm,

    i.tanggal_lahir,

    i.no_hp_raw,
    i.no_hp_clean,
    i.no_hp_norm,

    i.alamat,

    i.mother_match_method,
    i.mother_match_confidence,


    -- ========================================================
    -- FACILITY
    -- ========================================================
    f.primary_facility.puskesmas
      AS puskesmas,

    f.primary_facility.puskesmas_norm
      AS puskesmas_norm,

    f.primary_facility.puskesmas_id
      AS puskesmas_id,

    COALESCE(
      f.pregnancy_puskesmas_count,
      0
    ) AS pregnancy_puskesmas_count,

    f.pregnancy_puskesmas_list,


    -- ========================================================
    -- PREGNANCY REFERENCE / DATING
    -- ========================================================
    e.pregnancy_episode_anchor_date,

    e.pregnancy_reference_date,
    e.pregnancy_reference_method,
    e.pregnancy_reference_confidence,


    CASE
      WHEN e.pregnancy_reference_method = 'HPHT_REPORTED'
      THEN e.pregnancy_reference_date

      ELSE NULL
    END AS hpht_date,


    h.hpl_date,


    e.pregnancy_reference_source_record_key,
    e.pregnancy_reference_source_table,


    e.anchor_reference_min_date,
    e.anchor_reference_max_date,
    e.pregnancy_anchor_span_days,


    -- ========================================================
    -- PREGNANCY TIMELINE
    -- ========================================================
    e.pregnancy_first_event_date,
    e.pregnancy_latest_event_date,


    -- ========================================================
    -- DELIVERY
    -- ========================================================
    d.delivery_date,

    d.delivery_date_source,

    d.delivery_source_table,

    d.delivery_source_record_key,


    dq.delivery_date_min,
    dq.delivery_date_max,

    COALESCE(
      dq.distinct_delivery_date_count,
      0
    ) AS distinct_delivery_date_count,


    CASE
      WHEN COALESCE(
        dq.distinct_delivery_date_count,
        0
      ) > 1
      THEN TRUE

      ELSE FALSE
    END AS flag_delivery_date_conflict,


    -- ========================================================
    -- PREGNANCY STATUS
    --
    -- Do NOT infer abortus from historical G/P/A.
    -- ========================================================
    CASE
      WHEN
        d.delivery_date IS NOT NULL
        OR COALESCE(s.has_epus_inc, FALSE) = TRUE
        OR COALESCE(s.has_epus_pnc, FALSE) = TRUE
      THEN 'MELAHIRKAN'

      ELSE 'BELUM ADA DATA PERSALINAN'
    END AS pregnancy_status_inferred,


    -- ========================================================
    -- ANC
    -- ========================================================
    COALESCE(
      a.anc_visit_count,
      0
    ) AS anc_visit_count,

    a.first_anc_date,
    a.latest_anc_date,


    COALESCE(a.anc_k1_count, 0)
      AS anc_k1_count,

    COALESCE(a.anc_k2_count, 0)
      AS anc_k2_count,

    COALESCE(a.anc_k3_count, 0)
      AS anc_k3_count,

    COALESCE(a.anc_k4_count, 0)
      AS anc_k4_count,

    COALESCE(a.anc_k5_count, 0)
      AS anc_k5_count,

    COALESCE(a.anc_k6_count, 0)
      AS anc_k6_count,

    a.anc_visit_labels,


    COALESCE(
      s.raw_anc_source_record_count,
      0
    ) AS raw_anc_source_record_count,


    COALESCE(
      s.raw_anc_source_record_count,
      0
    )
    -
    COALESCE(
      a.anc_visit_count,
      0
    ) AS anc_source_duplicates_removed,


    COALESCE(
      a.anc_cross_source_overlap_event_count,
      0
    ) AS anc_cross_source_overlap_event_count,


    COALESCE(
      a.anc_same_date_different_facility_event_count,
      0
    ) AS anc_same_date_different_facility_event_count,


    -- ========================================================
    -- INC / BABY OUTCOME
    -- ========================================================
    COALESCE(
      inc.inc_baby_record_count,
      0
    ) AS inc_baby_record_count,


    COALESCE(
      inc.live_birth_baby_record_count,
      0
    ) AS live_birth_baby_record_count,


    COALESCE(
      inc.stillbirth_baby_record_count,
      0
    ) AS stillbirth_baby_record_count,


    COALESCE(
      inc.unknown_birth_outcome_baby_record_count,
      0
    ) AS unknown_birth_outcome_baby_record_count,


    COALESCE(
      inc.known_birth_outcome_baby_record_count,
      0
    ) AS known_birth_outcome_baby_record_count,


    COALESCE(
      inc.birth_outcome_category,
      'UNKNOWN'
    ) AS birth_outcome_category,


    COALESCE(
      inc.birth_outcome_complete_flag,
      FALSE
    ) AS birth_outcome_complete_flag,


    COALESCE(
      inc.birth_outcome_confidence,
      'LOW'
    ) AS birth_outcome_confidence,


    inc.birth_outcome_source,


    COALESCE(
      inc.baby_death_recorded,
      FALSE
    ) AS baby_death_recorded,


    COALESCE(
      inc.baby_death_record_count,
      0
    ) AS baby_death_record_count,


    inc.baby_name_list,
    inc.baby_sex_list,


    inc.birth_weight_min_gram,
    inc.birth_weight_max_gram,

    COALESCE(
      inc.birth_weight_record_count,
      0
    ) AS birth_weight_record_count,


    COALESCE(
      inc.bblr_baby_record_count,
      0
    ) AS bblr_baby_record_count,


    -- --------------------------------------------------------
    -- Multiple birth indicator
    --
    -- This uses retained INC baby records as the evidence.
    -- --------------------------------------------------------
    CASE
      WHEN COALESCE(
        inc.inc_baby_record_count,
        0
      ) > 1
      THEN TRUE

      ELSE FALSE
    END AS has_multiple_inc_baby_records,


    -- ========================================================
    -- DELIVERY CLINICAL DETAILS
    -- ========================================================
    ib.gestational_age_at_delivery_weeks,


    CASE
      WHEN ib.gestational_age_at_delivery_weeks IS NULL
      THEN 'UNKNOWN'

      WHEN ib.gestational_age_at_delivery_weeks < 37
      THEN 'PRETERM'

      WHEN ib.gestational_age_at_delivery_weeks <= 42
      THEN 'ATERM'

      WHEN ib.gestational_age_at_delivery_weeks > 42
      THEN 'POSTTERM'

      ELSE 'UNKNOWN'
    END AS gestational_age_category,


    ib.delivery_mode,
    inc.delivery_mode_list,

    ib.birth_attendant,
    inc.birth_attendant_list,

    ib.birth_presentation,

    ib.delivery_complication,
    inc.delivery_complication_list,

    ib.complication_general,


    -- ========================================================
    -- MATERNAL OUTCOME
    -- ========================================================
    COALESCE(
      inc.maternal_outcome_category,
      'UNKNOWN'
    ) AS maternal_outcome_category,


    COALESCE(
      inc.maternal_death_recorded,
      FALSE
    ) AS maternal_death_recorded,


    COALESCE(
      inc.maternal_postdelivery_status,
      'UNKNOWN'
    ) AS maternal_postdelivery_status,


    ib.maternal_current_condition,


    COALESCE(
      inc.flag_maternal_outcome_conflict,
      FALSE
    ) AS flag_maternal_outcome_conflict,


    COALESCE(
      inc.flag_maternal_outcome_cross_record_difference,
      FALSE
    ) AS flag_maternal_outcome_cross_record_difference,


    -- ========================================================
    -- PNC
    -- ========================================================
    COALESCE(
      p.pnc_visit_count,
      0
    ) AS pnc_visit_count,

    p.first_pnc_date,
    p.latest_pnc_date,


    COALESCE(p.pnc_kf1_count, 0)
      AS pnc_kf1_count,

    COALESCE(p.pnc_kf2_count, 0)
      AS pnc_kf2_count,

    COALESCE(p.pnc_kf3_count, 0)
      AS pnc_kf3_count,

    COALESCE(p.pnc_kf4_count, 0)
      AS pnc_kf4_count,

    p.pnc_visit_labels,


    -- ========================================================
    -- SOURCE COVERAGE
    -- ========================================================
    COALESCE(
      s.source_table_count,
      0
    ) AS source_table_count,


    COALESCE(
      s.epus_anc_source_record_count,
      0
    ) AS epus_anc_source_record_count,

    COALESCE(
      s.epus_kunjungan_source_record_count,
      0
    ) AS epus_kunjungan_source_record_count,

    COALESCE(
      s.epus_inc_source_record_count,
      0
    ) AS epus_inc_source_record_count,

    COALESCE(
      s.epus_pnc_source_record_count,
      0
    ) AS epus_pnc_source_record_count,


    COALESCE(
      s.has_epus_anc,
      FALSE
    ) AS has_epus_anc,

    COALESCE(
      s.has_epus_kunjungan_ibu_hamil,
      FALSE
    ) AS has_epus_kunjungan_ibu_hamil,

    COALESCE(
      s.has_epus_inc,
      FALSE
    ) AS has_epus_inc,

    COALESCE(
      s.has_epus_pnc,
      FALSE
    ) AS has_epus_pnc,


    -- ========================================================
    -- ASSIGNMENT QA
    -- ========================================================
    e.source_record_count,

    e.low_confidence_assignment_record_count,

    e.has_low_confidence_assignment,

    e.has_unresolved_pregnancy_assignment,

    e.pregnancy_assignment_methods

  FROM episode_core e


  LEFT JOIN identity_best i
    USING (epus_pregnancy_key)


  LEFT JOIN facility_summary f
    USING (epus_pregnancy_key)


  LEFT JOIN hpl_best h
    USING (epus_pregnancy_key)


  LEFT JOIN delivery_best d
    USING (epus_pregnancy_key)


  LEFT JOIN delivery_qa dq
    USING (epus_pregnancy_key)


  LEFT JOIN source_summary s
    USING (epus_pregnancy_key)


  LEFT JOIN anc_summary a
    USING (epus_pregnancy_key)


  LEFT JOIN pnc_summary p
    USING (epus_pregnancy_key)


  LEFT JOIN inc_summary inc
    USING (epus_pregnancy_key)


  LEFT JOIN inc_best_record ib
    USING (epus_pregnancy_key)
),


-- ============================================================
-- 14. FINAL
--
-- Add number of pregnancy episodes observed per mother.
-- ============================================================
final AS (
  SELECT
    m.*,


    COUNT(*) OVER (
      PARTITION BY epus_mother_key
    ) AS mother_pregnancy_count,


    CASE
      WHEN COUNT(*) OVER (
        PARTITION BY epus_mother_key
      ) > 1
      THEN TRUE

      ELSE FALSE
    END AS mother_has_multiple_pregnancies

  FROM master_pre m
)


SELECT
  *
FROM final;