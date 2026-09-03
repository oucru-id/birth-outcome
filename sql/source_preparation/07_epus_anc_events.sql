-- Recovered source builder; v3 target. Run the complete file.
-- StandardSQL
-- ============================================================
-- CANONICAL ePUSKESMAS ANC EVENTS - UPDATED
--
-- Output:
--   spheres-lombok-barat.kohort_bumil_v2
--   .t_epus_anc_canonical_events
--
-- Grain:
--   one row = one canonical real-world ANC encounter
--
-- Sources:
--   EPUS_ANC
--   EPUS_KUNJUNGAN_IBU_HAMIL
--
-- MAIN RULE
-- ============================================================
--
-- Same pregnancy + same ANC date:
--
-- A. 0 or 1 distinct known Puskesmas
--      -> ALL source records become ONE canonical ANC event
--
-- B. >1 distinct known Puskesmas
--      -> keep separate canonical events by known Puskesmas
--
-- C. >1 distinct known Puskesmas + source record has no PKM
--      -> keep that source record separately because we cannot
--         safely determine which facility encounter it belongs to
--
-- D. ANC date missing
--      -> keep source record separately
--
-- This removes multi-row cross-source duplicates without
-- incorrectly merging known different-facility encounters.
-- ============================================================


CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_epus_anc_canonical_events`

PARTITION BY anc_date

CLUSTER BY
  epus_pregnancy_key,
  epus_mother_key,
  canonical_source_table,
  puskesmas_norm

AS


WITH
-- ============================================================
-- 1. ANC-LIKE SOURCE RECORDS
-- ============================================================
anc_source AS (
  SELECT
    p.*

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_records` p

  WHERE
    event_type = 'ANC'

    AND source_table IN (
      'EPUS_ANC',
      'EPUS_KUNJUNGAN_IBU_HAMIL'
    )
),


-- ============================================================
-- 2. CONTEXT FOR EACH PREGNANCY + ANC DATE
--
-- This determines whether there is a genuine facility
-- disagreement on that date.
-- ============================================================
same_date_context AS (
  SELECT
    epus_pregnancy_key,
    anc_date,


    COUNT(*)
      AS same_date_source_record_count,


    COUNT(
      DISTINCT source_table
    ) AS same_date_source_table_count,


    -- BigQuery COUNT DISTINCT ignores NULL automatically.
    COUNT(
      DISTINCT puskesmas_norm
    ) AS same_date_distinct_puskesmas_count,


    COUNTIF(
      puskesmas_norm IS NULL
    ) AS same_date_missing_puskesmas_count,


    LOGICAL_OR(
      source_table = 'EPUS_ANC'
    ) AS same_date_has_epus_anc,


    LOGICAL_OR(
      source_table = 'EPUS_KUNJUNG_IBU_HAMIL'
    ) AS dummy_placeholder

  FROM anc_source

  WHERE
    anc_date IS NOT NULL

  GROUP BY
    epus_pregnancy_key,
    anc_date
),


-- ============================================================
-- 3. FIX THE EPUS_KUNJUNGAN FLAG
--
-- Kept separate to make the context logic explicit.
-- ============================================================
same_date_context_final AS (
  SELECT
    c.* EXCEPT(dummy_placeholder),

    EXISTS (
      SELECT 1
      FROM anc_source x

      WHERE
        x.epus_pregnancy_key = c.epus_pregnancy_key
        AND x.anc_date = c.anc_date
        AND x.source_table = 'EPUS_KUNJUNGAN_IBU_HAMIL'
    ) AS same_date_has_epus_kunjungan

  FROM same_date_context c
),


-- ============================================================
-- 4. ASSIGN CANONICAL GROUP
--
-- No conflicting known facility:
--   all same-date records collapse to one ANC encounter.
--
-- Conflicting known facilities:
--   split by known facility.
--
-- Missing PKM inside a conflicting date:
--   keep source-specific because facility cannot be resolved.
-- ============================================================
grouped_records_base AS (
  SELECT
    a.*,

    c.same_date_source_record_count,
    c.same_date_source_table_count,
    c.same_date_distinct_puskesmas_count,
    c.same_date_missing_puskesmas_count,

    c.same_date_has_epus_anc,
    c.same_date_has_epus_kunjungan,


    CASE
      -- ------------------------------------------------------
      -- Missing ANC date:
      -- never merge based only on mother/pregnancy.
      -- ------------------------------------------------------
      WHEN a.anc_date IS NULL
      THEN CONCAT(
        'SOURCE|',
        a.epus_source_record_key
      )


      -- ------------------------------------------------------
      -- Same date with no conflicting known Puskesmas.
      --
      -- This includes:
      --   all PKM same
      --   one known + some missing
      --   all PKM missing
      -- ------------------------------------------------------
      WHEN COALESCE(
        c.same_date_distinct_puskesmas_count,
        0
      ) <= 1
      THEN 'SAME_DATE_NO_PUSKESMAS_CONFLICT'


      -- ------------------------------------------------------
      -- Multiple known Puskesmas:
      -- separate by known facility.
      -- ------------------------------------------------------
      WHEN a.puskesmas_norm IS NOT NULL
      THEN CONCAT(
        'PKM|',
        a.puskesmas_norm
      )


      -- ------------------------------------------------------
      -- Multiple known PKM but this row has no PKM.
      --
      -- Cannot determine which real encounter it belongs to,
      -- therefore keep independently.
      -- ------------------------------------------------------
      ELSE CONCAT(
        'AMBIGUOUS_NULL_PKM|',
        a.epus_source_record_key
      )

    END AS canonical_facility_group

  FROM anc_source a

  LEFT JOIN same_date_context_final c
    ON a.epus_pregnancy_key = c.epus_pregnancy_key
   AND a.anc_date = c.anc_date
),


-- ============================================================
-- 5. CREATE CANONICAL ANC EVENT KEY
-- ============================================================
grouped_records AS (
  SELECT
    g.*,


    CONCAT(
      'EPANC_',
      TO_HEX(
        SHA256(
          CASE
            WHEN anc_date IS NULL
            THEN CONCAT(
              'SOURCE|',
              epus_source_record_key
            )

            ELSE CONCAT(
              epus_pregnancy_key,
              '|ANC_DATE|',
              CAST(anc_date AS STRING),
              '|GROUP|',
              canonical_facility_group
            )
          END
        )
      )
    ) AS canonical_anc_event_key

  FROM grouped_records_base g
),


-- ============================================================
-- 6. AGGREGATE ALL REPRESENTATIONS OF THE SAME ANC EVENT
-- ============================================================
canonical_event_raw AS (
  SELECT
    canonical_anc_event_key,


    -- --------------------------------------------------------
    -- Identity / pregnancy
    -- --------------------------------------------------------
    ANY_VALUE(epus_mother_key)
      AS epus_mother_key,

    ANY_VALUE(epus_pregnancy_key)
      AS epus_pregnancy_key,

    ANY_VALUE(pregnancy_episode_number)
      AS pregnancy_episode_number,

    ANY_VALUE(anc_date)
      AS anc_date,

    ANY_VALUE(canonical_facility_group)
      AS canonical_facility_group,


    -- --------------------------------------------------------
    -- Underlying source representation counts
    -- --------------------------------------------------------
    COUNT(*)
      AS source_record_count,

    COUNT(
      DISTINCT source_table
    ) AS source_table_count,


    COUNTIF(
      source_table = 'EPUS_ANC'
    ) AS epus_anc_source_record_count,


    COUNTIF(
      source_table = 'EPUS_KUNJUNGAN_IBU_HAMIL'
    ) AS epus_kunjungan_source_record_count,


    -- --------------------------------------------------------
    -- Presence
    -- --------------------------------------------------------
    LOGICAL_OR(
      source_table = 'EPUS_ANC'
    ) AS has_epus_anc_source,

    LOGICAL_OR(
      source_table = 'EPUS_KUNJUNGAN_IBU_HAMIL'
    ) AS has_epus_kunjungan_ibu_hamil_source,


    -- --------------------------------------------------------
    -- Facility within THIS canonical event
    -- --------------------------------------------------------
    COUNT(
      DISTINCT puskesmas_norm
    ) AS canonical_event_distinct_puskesmas_count,


    COUNTIF(
      puskesmas_norm IS NULL
    ) AS canonical_event_missing_puskesmas_count,


    -- --------------------------------------------------------
    -- Same-date context
    -- --------------------------------------------------------
    MAX(
      same_date_source_record_count
    ) AS same_date_source_record_count,

    MAX(
      same_date_source_table_count
    ) AS same_date_source_table_count,

    MAX(
      same_date_distinct_puskesmas_count
    ) AS same_date_distinct_puskesmas_count,

    MAX(
      same_date_missing_puskesmas_count
    ) AS same_date_missing_puskesmas_count,

    LOGICAL_OR(
      same_date_has_epus_anc
    ) AS same_date_has_epus_anc,

    LOGICAL_OR(
      same_date_has_epus_kunjungan
    ) AS same_date_has_epus_kunjungan,


    -- --------------------------------------------------------
    -- Provenance arrays
    -- --------------------------------------------------------
    ARRAY_AGG(
      epus_source_record_key
      ORDER BY
        same_event_source_priority ASC,
        source_table,
        epus_source_record_key
    ) AS source_record_keys,


    ARRAY_AGG(
      DISTINCT source_table
      ORDER BY source_table
    ) AS source_tables,


    ARRAY_AGG(
      DISTINCT puskesmas
      IGNORE NULLS
      ORDER BY puskesmas
    ) AS source_puskesmas_list,


    -- --------------------------------------------------------
    -- BEST OVERALL SOURCE RECORD
    --
    -- EPUS_ANC remains preferred over KIH when both represent
    -- the same real ANC visit.
    -- --------------------------------------------------------
    ARRAY_AGG(
      STRUCT(
        epus_source_record_key
          AS source_record_key,

        source_table
          AS source_table,

        same_event_source_priority
          AS source_priority,

        source_row_completeness_score
          AS completeness_score,

        source_recency_timestamp
          AS recency_timestamp,

        nik_clean
          AS nik_clean,

        nama
          AS nama,

        nama_norm
          AS nama_norm,

        tanggal_lahir
          AS tanggal_lahir,

        hpht_date
          AS hpht_date,

        hpl_date
          AS hpl_date,

        puskesmas
          AS puskesmas,

        puskesmas_norm
          AS puskesmas_norm,

        puskesmas_id
          AS puskesmas_id,

        visit_label
          AS visit_label
      )

      ORDER BY
        same_event_source_priority ASC,
        source_row_completeness_score DESC,
        source_recency_timestamp DESC,
        epus_source_record_key DESC

      LIMIT 1
    )[OFFSET(0)] AS best_source,


    -- --------------------------------------------------------
    -- BEST FACILITY SOURCE
    --
    -- Prefer a non-null facility even when best_source has
    -- missing Puskesmas.
    -- --------------------------------------------------------
    ARRAY_AGG(
      STRUCT(
        puskesmas
          AS puskesmas,

        puskesmas_norm
          AS puskesmas_norm,

        puskesmas_id
          AS puskesmas_id,

        source_table
          AS source_table,

        epus_source_record_key
          AS source_record_key
      )

      ORDER BY
        CASE
          WHEN puskesmas_norm IS NOT NULL
          THEN 0
          ELSE 1
        END,

        same_event_source_priority ASC,
        source_row_completeness_score DESC,
        source_recency_timestamp DESC,
        epus_source_record_key DESC

      LIMIT 1
    )[OFFSET(0)] AS best_facility

  FROM grouped_records

  GROUP BY
    canonical_anc_event_key
),


-- ============================================================
-- 7. DERIVE CROSS-SOURCE MATCH STATUS
-- ============================================================
canonical_classified AS (
  SELECT
    c.*,


    -- --------------------------------------------------------
    -- True whenever both ANC source tables contribute to this
    -- one canonical real-world ANC visit.
    -- --------------------------------------------------------
    CASE
      WHEN source_table_count > 1
      THEN TRUE
      ELSE FALSE
    END AS cross_source_overlap_flag,


    -- --------------------------------------------------------
    -- Matching method
    -- --------------------------------------------------------
    CASE
      WHEN source_table_count = 1
      THEN 'NO_CROSS_SOURCE_MATCH'


      -- Both sources, same known PKM, nothing missing
      WHEN
        source_table_count > 1
        AND canonical_event_distinct_puskesmas_count = 1
        AND canonical_event_missing_puskesmas_count = 0
      THEN 'EXACT_DATE_SAME_PUSKESMAS'


      -- Both sources; one known facility and some missing
      WHEN
        source_table_count > 1
        AND canonical_event_distinct_puskesmas_count = 1
        AND canonical_event_missing_puskesmas_count > 0
      THEN 'EXACT_DATE_NO_PUSKESMAS_CONFLICT'


      -- Both sources and every facility value missing
      WHEN
        source_table_count > 1
        AND canonical_event_distinct_puskesmas_count = 0
      THEN 'EXACT_DATE_PUSKESMAS_MISSING'


      ELSE 'NO_CROSS_SOURCE_MATCH'
    END AS cross_source_match_method,


    -- --------------------------------------------------------
    -- Compatibility score
    -- --------------------------------------------------------
    CASE
      WHEN
        source_table_count > 1
        AND canonical_event_distinct_puskesmas_count = 1
        AND canonical_event_missing_puskesmas_count = 0
      THEN 2

      WHEN source_table_count > 1
      THEN 1

      ELSE NULL
    END AS facility_match_score

  FROM canonical_event_raw c
),


-- ============================================================
-- 8. FINAL OUTPUT
-- ============================================================
final AS (
  SELECT
    c.canonical_anc_event_key,

    c.epus_mother_key,
    c.epus_pregnancy_key,
    c.pregnancy_episode_number,

    c.anc_date,


    -- --------------------------------------------------------
    -- Canonical selected source
    -- --------------------------------------------------------
    c.best_source.source_record_key
      AS canonical_source_record_key,

    c.best_source.source_table
      AS canonical_source_table,

    c.best_source.source_priority
      AS canonical_source_priority,

    c.best_source.completeness_score
      AS canonical_source_completeness_score,

    c.best_source.recency_timestamp
      AS canonical_source_recency_timestamp,


    -- --------------------------------------------------------
    -- Patient identity
    -- --------------------------------------------------------
    c.best_source.nik_clean
      AS nik_clean,

    c.best_source.nama
      AS nama,

    c.best_source.nama_norm
      AS nama_norm,

    c.best_source.tanggal_lahir
      AS tanggal_lahir,


    -- --------------------------------------------------------
    -- Pregnancy dating evidence from canonical source
    -- --------------------------------------------------------
    c.best_source.hpht_date
      AS hpht_date,

    c.best_source.hpl_date
      AS hpl_date,


    -- --------------------------------------------------------
    -- Facility
    --
    -- Prefer non-null source facility.
    -- --------------------------------------------------------
    COALESCE(
      c.best_source.puskesmas,
      c.best_facility.puskesmas
    ) AS puskesmas,

    COALESCE(
      c.best_source.puskesmas_norm,
      c.best_facility.puskesmas_norm
    ) AS puskesmas_norm,

    COALESCE(
      c.best_source.puskesmas_id,
      c.best_facility.puskesmas_id
    ) AS puskesmas_id,


    -- --------------------------------------------------------
    -- Visit K label
    -- --------------------------------------------------------
    c.best_source.visit_label
      AS visit_label,


    -- --------------------------------------------------------
    -- Canonical grouping information
    -- --------------------------------------------------------
    c.canonical_facility_group,


    -- --------------------------------------------------------
    -- Source provenance
    -- --------------------------------------------------------
    c.source_record_count,
    c.source_table_count,

    c.epus_anc_source_record_count,
    c.epus_kunjungan_source_record_count,

    c.has_epus_anc_source,
    c.has_epus_kunjungan_ibu_hamil_source,

    c.source_record_keys,
    c.source_tables,
    c.source_puskesmas_list,


    -- --------------------------------------------------------
    -- Cross-source overlap
    -- --------------------------------------------------------
    c.cross_source_overlap_flag,
    c.cross_source_match_method,
    c.facility_match_score,


    -- --------------------------------------------------------
    -- Facility information inside canonical group
    -- --------------------------------------------------------
    c.canonical_event_distinct_puskesmas_count,
    c.canonical_event_missing_puskesmas_count,


    -- --------------------------------------------------------
    -- Whole same-date context
    -- --------------------------------------------------------
    c.same_date_source_record_count,
    c.same_date_source_table_count,
    c.same_date_distinct_puskesmas_count,
    c.same_date_missing_puskesmas_count,


    -- --------------------------------------------------------
    -- Same-date but cross-source NOT merged.
    --
    -- After this update this should mainly happen when the
    -- same pregnancy/date has conflicting known Puskesmas.
    -- --------------------------------------------------------
    CASE
      WHEN
        c.anc_date IS NOT NULL
        AND c.same_date_has_epus_anc = TRUE
        AND c.same_date_has_epus_kunjungan = TRUE
        AND c.source_table_count = 1
      THEN TRUE

      ELSE FALSE
    END AS flag_same_date_cross_source_unmerged,


    -- --------------------------------------------------------
    -- Reason for unmerged same-date cross-source records
    -- --------------------------------------------------------
    CASE
      WHEN NOT (
        c.anc_date IS NOT NULL
        AND c.same_date_has_epus_anc = TRUE
        AND c.same_date_has_epus_kunjungan = TRUE
        AND c.source_table_count = 1
      )
      THEN NULL


      WHEN
        c.same_date_distinct_puskesmas_count > 1
        AND COALESCE(
          c.best_source.puskesmas_norm,
          c.best_facility.puskesmas_norm
        ) IS NOT NULL
      THEN 'DIFFERENT_KNOWN_PUSKESMAS'


      WHEN
        c.same_date_distinct_puskesmas_count > 1
        AND COALESCE(
          c.best_source.puskesmas_norm,
          c.best_facility.puskesmas_norm
        ) IS NULL
      THEN 'AMBIGUOUS_MISSING_PUSKESMAS_WITH_MULTIPLE_FACILITIES'


      ELSE 'OTHER'
    END AS same_date_unmerged_reason

  FROM canonical_classified c
)


SELECT
  *
FROM final;