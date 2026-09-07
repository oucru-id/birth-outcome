-- ============================================================================
-- PURBALINGGA
-- 04_build_epus_pregnancy_episode_adapter_v3_3.sql
--
-- INPUT:
--   stellar-orb-451904-d9.kohort_bumil_v2.t_epus_source_records
--
-- OUTPUT:
--   stellar-orb-451904-d9.kohort_bumil_v2
--     .t_epus_pregnancy_episode_adapter_v3_3
--
-- PURPOSE:
--   Build preliminary ePUS pregnancy episodes from:
--
--     EPUS_ANC
--     EPUS_KUNJUNGAN_IBU_HAMIL
--
--   and conservatively enrich those episodes with EPUS_INC delivery evidence.
--
-- IMPORTANT:
--
--   Pregnancy creators:
--     EPUS_ANC
--     EPUS_KUNJUNGAN_IBU_HAMIL
--
--   Outcome enrichment only:
--     EPUS_INC
--     EPUS_PNC
--
--   EPUS_INC does NOT create a new denominator pregnancy.
--
--   The output contract is compatible with the later
--   03C_v4_1 canonicalization:
--
--     epus_episode_id
--     epus_episode_source_key
--     nik_clean
--     nama_ibu
--     nama_norm
--     nama_core_norm
--     tanggal_lahir_ibu
--     no_hp_clean
--     puskesmas
--     puskesmas_norm
--     desa
--     desa_norm
--     posyandu
--     alamat
--     hpht_epus
--     hpl_epus
--     delivery_epus
--     hpl_from_epus_hpht
--     first_anc_date
--     last_anc_date
--     pregnancy_anchor_date
--     source_json
--
-- TIMEZONE:
--   Asia/Jakarta
--
-- PRELIMINARY EPISODE SPLIT:
--   >120 days between consecutive pregnancy anchors.
--
-- ANALYTICAL PREGNANCY FLOOR:
--   2018-01-01
--
-- NOTE:
--   This is NOT yet the final ePUS canonicalization.
--   03C_v4_1 will subsequently perform within-ePUS canonicalization.
-- ============================================================================


-- ============================================================================
-- 1. PARAMETERS
-- ============================================================================

DECLARE analysis_date DATE
  DEFAULT CURRENT_DATE('Asia/Jakarta');

DECLARE plausible_pregnancy_floor DATE
  DEFAULT DATE '2018-01-01';

DECLARE epus_episode_anchor_tolerance_days INT64
  DEFAULT 120;

DECLARE inc_nik_anchor_tolerance_days INT64
  DEFAULT 120;

DECLARE inc_weak_anchor_tolerance_days INT64
  DEFAULT 60;



-- ============================================================================
-- 2. TEMP FUNCTIONS
-- ============================================================================


CREATE TEMP FUNCTION norm_text(s STRING)
RETURNS STRING
AS (
  NULLIF(
    REGEXP_REPLACE(
      UPPER(
        TRIM(
          NORMALIZE(
            COALESCE(s, ''),
            NFKC
          )
        )
      ),
      r'\s+',
      ' '
    ),
    ''
  )
);



CREATE TEMP FUNCTION norm_name(s STRING)
RETURNS STRING
AS (
  NULLIF(
    TRIM(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          UPPER(
            TRIM(
              NORMALIZE(
                COALESCE(s, ''),
                NFKC
              )
            )
          ),
          r'[^A-Z0-9 ]',
          ' '
        ),
        r'\s+',
        ' '
      )
    ),
    ''
  )
);



CREATE TEMP FUNCTION norm_name_core(s STRING)
RETURNS STRING
AS (
  NULLIF(
    TRIM(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          COALESCE(
            norm_name(s),
            ''
          ),
          r'^(IBU|NY|NYONYA|HJ|HJH|HAJAH)\s+',
          ''
        ),
        r'\s+(SE|S E|SPD|S PD|SST|S ST|SKM|S KM|MKES|M KES|MKEB|M KEB|SKEP|S KEP|NERS|AMD KEB|A MD KEB)$',
        ''
      )
    ),
    ''
  )
);



CREATE TEMP FUNCTION nik_is_trusted(s STRING)
RETURNS BOOL
AS (
  s IS NOT NULL
  AND REGEXP_CONTAINS(
    s,
    r'^\d{16}$'
  )
  AND s NOT IN (
    '0000000000000000',
    '9999999999999999'
  )
  AND RIGHT(s, 4) != '0000'
);



CREATE TEMP FUNCTION is_anon_placeholder(s STRING)
RETURNS BOOL
AS (
  REGEXP_CONTAINS(
    UPPER(
      TRIM(
        COALESCE(s, '')
      )
    ),
    r'^ANON[_ -]?[0-9]+$'
  )
);



-- ============================================================================
-- 3. BUILD PRELIMINARY ePUS PREGNANCY EPISODES
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_pregnancy_episode_adapter_v3_3`

CLUSTER BY
  nik_clean,
  puskesmas_norm,
  epus_episode_id

AS

WITH


-- ============================================================================
-- A. PREGNANCY-CREATOR RECORDS ONLY
-- ============================================================================

source_base AS (

  SELECT

    source_table,
    source_priority,
    source_role,

    source_record_id,
    source_event_id,

    nik_clean,
    nik_reliability,

    nama,
    nama_norm,

    norm_name_core(nama)
      AS nama_core_norm,

    tanggal_lahir,

    hpht_date,
    hpl_date,

    pregnancy_anchor_date,

    anc_date,

    puskesmas,
    puskesmas_norm,
    puskesmas_id,

    desa,
    desa_norm,

    alamat,

    no_hp_clean,

    early_usg_dating_flag,

    usg_ga_weeks,
    usg_hpl_date,

    source_json

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_source_records`

  WHERE
    pregnancy_episode_creator_flag = TRUE

    AND pregnancy_anchor_date IS NOT NULL

    AND NOT is_anon_placeholder(nama)

),



-- ============================================================================
-- B. ANALYTICAL PREGNANCY DATE GUARD
--
-- Raw staging keeps older history.
-- Only plausible pregnancy periods participate in this denominator layer.
-- ============================================================================

prepared AS (

  SELECT

    *,

    CASE

      WHEN hpht_date
        BETWEEN plausible_pregnancy_floor
            AND analysis_date

      THEN hpht_date

    END AS hpht_valid,


    CASE

      WHEN hpl_date
        BETWEEN plausible_pregnancy_floor
            AND DATE_ADD(
              analysis_date,
              INTERVAL 300 DAY
            )

      THEN hpl_date

    END AS hpl_valid

  FROM source_base

),



-- ============================================================================
-- C. RECOMPUTE EPISODE ANCHOR
--
-- Priority:
--   HPHT
--   otherwise HPL - 280
-- ============================================================================

anchored AS (

  SELECT

    *,

    COALESCE(
      hpht_valid,

      CASE

        WHEN hpl_valid IS NOT NULL

        THEN DATE_SUB(
          hpl_valid,
          INTERVAL 280 DAY
        )

      END

    ) AS episode_anchor_date

  FROM prepared

),



-- ============================================================================
-- D. PRELIMINARY MATERNAL IDENTITY
--
-- Trusted NIK is strongest.
--
-- Rounded NIK (ending 0000) is intentionally NOT treated as trusted.
-- ============================================================================

identified AS (

  SELECT

    *,

    CASE


      -- ----------------------------------------------------------------------
      -- TRUSTED NIK
      -- ----------------------------------------------------------------------

      WHEN nik_is_trusted(nik_clean)

      THEN CONCAT(
        'NIK|',
        nik_clean
      )


      -- ----------------------------------------------------------------------
      -- NAME + DOB + PUSKESMAS
      -- ----------------------------------------------------------------------

      WHEN nama_core_norm IS NOT NULL
       AND tanggal_lahir IS NOT NULL
       AND puskesmas_norm IS NOT NULL

      THEN CONCAT(
        'NAME_DOB_PKM|',
        nama_core_norm,
        '|',
        CAST(
          tanggal_lahir
          AS STRING
        ),
        '|',
        puskesmas_norm
      )


      -- ----------------------------------------------------------------------
      -- NAME + DOB
      -- ----------------------------------------------------------------------

      WHEN nama_core_norm IS NOT NULL
       AND tanggal_lahir IS NOT NULL

      THEN CONCAT(
        'NAME_DOB|',
        nama_core_norm,
        '|',
        CAST(
          tanggal_lahir
          AS STRING
        )
      )


      -- ----------------------------------------------------------------------
      -- DO NOT FORCE WEAK ROWS TOGETHER
      -- ----------------------------------------------------------------------

      ELSE CONCAT(
        'SOURCE|',
        source_table,
        '|',
        source_record_id
      )

    END AS mother_identity_key,


    CASE

      WHEN nik_is_trusted(nik_clean)
        THEN 'TRUSTED_NIK'

      WHEN nama_core_norm IS NOT NULL
       AND tanggal_lahir IS NOT NULL
       AND puskesmas_norm IS NOT NULL
        THEN 'NAMA_CORE+DOB+PUSKESMAS'

      WHEN nama_core_norm IS NOT NULL
       AND tanggal_lahir IS NOT NULL
        THEN 'NAMA_CORE+DOB'

      ELSE 'SOURCE_RECORD'

    END AS mother_identity_method

  FROM anchored

  WHERE
    episode_anchor_date IS NOT NULL

),



-- ============================================================================
-- E. ORDER PREGNANCY ANCHORS WITHIN MOTHER
-- ============================================================================

ordered AS (

  SELECT

    *,

    LAG(
      episode_anchor_date
    ) OVER (

      PARTITION BY
        mother_identity_key

      ORDER BY
        episode_anchor_date,
        source_priority,
        source_record_id

    ) AS previous_anchor_date

  FROM identified

),



-- ============================================================================
-- F. MARK NEW PREGNANCY
-- ============================================================================

marked AS (

  SELECT

    *,

    CASE

      WHEN previous_anchor_date IS NULL
        THEN 1

      WHEN DATE_DIFF(
        episode_anchor_date,
        previous_anchor_date,
        DAY
      ) > epus_episode_anchor_tolerance_days
        THEN 1

      ELSE 0

    END AS starts_new_episode

  FROM ordered

),



-- ============================================================================
-- G. NUMBER PREGNANCY EPISODES
-- ============================================================================

numbered AS (

  SELECT

    *,

    SUM(
      starts_new_episode
    ) OVER (

      PARTITION BY
        mother_identity_key

      ORDER BY
        episode_anchor_date,
        source_priority,
        source_record_id

      ROWS BETWEEN
        UNBOUNDED PRECEDING
        AND CURRENT ROW

    ) AS episode_number

  FROM marked

),



-- ============================================================================
-- H. COLLAPSE REPEATED ePUS RECORDS
-- ============================================================================

aggregated AS (

  SELECT

    mother_identity_key,
    episode_number,


    -- ------------------------------------------------------------------------
    -- IDENTITY METHOD
    -- ------------------------------------------------------------------------

    ARRAY_AGG(
      mother_identity_method

      ORDER BY

        CASE mother_identity_method

          WHEN 'TRUSTED_NIK'
            THEN 1

          WHEN 'NAMA_CORE+DOB+PUSKESMAS'
            THEN 2

          WHEN 'NAMA_CORE+DOB'
            THEN 3

          ELSE 9

        END,

        source_priority,
        source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS mother_identity_method,


    ARRAY_AGG(
      DISTINCT mother_identity_method
      ORDER BY mother_identity_method
    ) AS mother_identity_methods,


    -- ------------------------------------------------------------------------
    -- EPISODE ANCHOR RANGE
    -- ------------------------------------------------------------------------

    MIN(
      episode_anchor_date
    ) AS pregnancy_anchor_min_date,


    MAX(
      episode_anchor_date
    ) AS pregnancy_anchor_max_date,


    DATE_DIFF(
      MAX(episode_anchor_date),
      MIN(episode_anchor_date),
      DAY
    ) AS pregnancy_anchor_spread_days,


    -- ------------------------------------------------------------------------
    -- SOURCE PROVENANCE
    -- ------------------------------------------------------------------------

    COUNT(*)
      AS epus_member_record_count,


    ARRAY_AGG(
      DISTINCT source_table
      ORDER BY source_table
    ) AS epus_source_tables,


    ARRAY_AGG(
      source_record_id
      ORDER BY
        source_priority,
        source_record_id
    ) AS epus_member_source_record_ids,


    -- ------------------------------------------------------------------------
    -- NIK
    --
    -- Trusted NIK first.
    -- Preserve suspect NIK only if no trusted NIK is available.
    -- ------------------------------------------------------------------------

    ARRAY_AGG(

      STRUCT(
        nik_clean AS value,
        nik_reliability AS reliability,
        source_table AS source_table,
        source_record_id AS source_record_id
      )

      ORDER BY

        CASE
          WHEN nik_is_trusted(nik_clean)
            THEN 1
          WHEN nik_clean IS NOT NULL
            THEN 2
          ELSE 9
        END,

        source_priority,
        source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS nik_pick,


    -- ------------------------------------------------------------------------
    -- NAME
    -- ------------------------------------------------------------------------

    ARRAY_AGG(

      STRUCT(
        nama AS value,
        nama_norm AS value_norm,
        nama_core_norm AS value_core_norm,
        source_table AS source_table,
        source_record_id AS source_record_id
      )

      ORDER BY
        nama_core_norm IS NULL,
        source_priority,
        source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS nama_pick,


    -- ------------------------------------------------------------------------
    -- DOB
    -- ------------------------------------------------------------------------

    ARRAY_AGG(

      STRUCT(
        tanggal_lahir AS value,
        source_table AS source_table,
        source_record_id AS source_record_id
      )

      ORDER BY
        tanggal_lahir IS NULL,
        source_priority,
        source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS dob_pick,


    -- ------------------------------------------------------------------------
    -- PHONE
    -- ------------------------------------------------------------------------

    ARRAY_AGG(

      STRUCT(
        no_hp_clean AS value,
        source_table AS source_table,
        source_record_id AS source_record_id
      )

      ORDER BY
        no_hp_clean IS NULL,
        LENGTH(
          COALESCE(
            no_hp_clean,
            ''
          )
        ) DESC,
        source_priority,
        source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS phone_pick,


    -- ------------------------------------------------------------------------
    -- LOCATION BUNDLE
    --
    -- Pick geography from one record.
    -- ------------------------------------------------------------------------

    ARRAY_AGG(

      STRUCT(
        puskesmas AS puskesmas,
        puskesmas_norm AS puskesmas_norm,
        puskesmas_id AS puskesmas_id,

        desa AS desa,
        desa_norm AS desa_norm,

        alamat AS alamat,

        source_table AS source_table,
        source_record_id AS source_record_id
      )

      ORDER BY
        puskesmas_norm IS NULL,
        desa_norm IS NULL,
        alamat IS NULL,
        source_priority,
        source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS location_pick,


    -- ------------------------------------------------------------------------
    -- HPHT
    -- ------------------------------------------------------------------------

    ARRAY_AGG(

      STRUCT(
        hpht_valid AS value,
        source_table AS source_table,
        source_record_id AS source_record_id
      )

      ORDER BY
        hpht_valid IS NULL,
        source_priority,
        source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS hpht_pick,


    -- ------------------------------------------------------------------------
    -- HPL
    -- ------------------------------------------------------------------------

    ARRAY_AGG(

      STRUCT(
        hpl_valid AS value,
        source_table AS source_table,
        source_record_id AS source_record_id
      )

      ORDER BY
        hpl_valid IS NULL,
        source_priority,
        source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS hpl_pick,


    -- ------------------------------------------------------------------------
    -- ANC WINDOW
    -- ------------------------------------------------------------------------

    MIN(anc_date)
      AS first_anc_date,


    MAX(anc_date)
      AS last_anc_date,


    -- ------------------------------------------------------------------------
    -- EARLY USG DATING
    -- ------------------------------------------------------------------------

    LOGICAL_OR(
      early_usg_dating_flag
    ) AS has_early_usg_dating,


    ARRAY_AGG(

      STRUCT(
        usg_hpl_date AS usg_hpl_date,
        usg_ga_weeks AS usg_ga_weeks,
        anc_date AS anc_date,
        source_record_id AS source_record_id
      )

      ORDER BY
        (
          early_usg_dating_flag
          AND usg_hpl_date IS NOT NULL
        ) DESC,

        usg_ga_weeks IS NULL,

        usg_ga_weeks,

        anc_date,

        source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS usg_pick


  FROM numbered

  GROUP BY
    mother_identity_key,
    episode_number

),



-- ============================================================================
-- I. CREATE PRELIMINARY EPISODE KEY
-- ============================================================================

episode_pre AS (

  SELECT

    CONCAT(

      'EPUSPRE|',

      mother_identity_key,

      '|',

      CAST(
        pregnancy_anchor_min_date
        AS STRING
      ),

      '|',

      CAST(
        episode_number
        AS STRING
      )

    ) AS epus_episode_source_key,


    mother_identity_key,
    mother_identity_method,
    mother_identity_methods,

    episode_number,


    nik_pick.value
      AS nik_clean,

    nik_pick.reliability
      AS nik_reliability,


    nama_pick.value
      AS nama_ibu,

    nama_pick.value_norm
      AS nama_norm,

    nama_pick.value_core_norm
      AS nama_core_norm,


    dob_pick.value
      AS tanggal_lahir_ibu,


    phone_pick.value
      AS no_hp_clean,


    location_pick.puskesmas
      AS puskesmas,

    location_pick.puskesmas_norm
      AS puskesmas_norm,

    location_pick.puskesmas_id
      AS puskesmas_id,

    location_pick.desa
      AS desa,

    location_pick.desa_norm
      AS desa_norm,

    CAST(NULL AS STRING)
      AS posyandu,

    location_pick.alamat
      AS alamat,


    hpht_pick.value
      AS hpht_epus,

    hpl_pick.value
      AS hpl_epus,


    CASE

      WHEN hpht_pick.value IS NOT NULL

      THEN DATE_ADD(
        hpht_pick.value,
        INTERVAL 280 DAY
      )

    END AS hpl_from_epus_hpht,


    first_anc_date,
    last_anc_date,


    COALESCE(

      hpht_pick.value,

      CASE

        WHEN hpl_pick.value IS NOT NULL

        THEN DATE_SUB(
          hpl_pick.value,
          INTERVAL 280 DAY
        )

      END

    ) AS pregnancy_anchor_date,


    pregnancy_anchor_min_date,
    pregnancy_anchor_max_date,
    pregnancy_anchor_spread_days,


    (
      pregnancy_anchor_spread_days
        > epus_episode_anchor_tolerance_days
    ) AS epus_episode_review_flag,


    epus_member_record_count,
    epus_source_tables,
    epus_member_source_record_ids,


    has_early_usg_dating,

    usg_pick.usg_hpl_date
      AS early_usg_hpl_date,

    usg_pick.usg_ga_weeks
      AS early_usg_ga_weeks,

    usg_pick.anc_date
      AS early_usg_anc_date

  FROM aggregated

),



-- ============================================================================
-- J. GIVE THE PRELIMINARY EPISODE A STABLE ID
-- ============================================================================

episodes AS (

  SELECT

    CONCAT(
      'EPUSEP_',
      TO_HEX(
        SHA256(
          epus_episode_source_key
        )
      )
    ) AS epus_episode_id,

    *

  FROM episode_pre

),



-- ============================================================================
-- K. EPUS INC RECORDS
--
-- INC cannot create the denominator.
-- It can enrich an existing ePUS pregnancy with delivery evidence.
-- ============================================================================

inc_base AS (

  SELECT

    source_record_id,

    nik_clean,
    nik_reliability,

    nama,
    nama_norm,

    norm_name_core(nama)
      AS nama_core_norm,

    tanggal_lahir,

    hpht_date,
    hpl_date,

    COALESCE(
      hpht_date,

      CASE
        WHEN hpl_date IS NOT NULL
        THEN DATE_SUB(
          hpl_date,
          INTERVAL 280 DAY
        )
      END

    ) AS inc_pregnancy_anchor_date,

    delivery_date,

    puskesmas,
    puskesmas_norm,

    desa,
    desa_norm,

    no_hp_clean,

    source_json

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_epus_source_records`

  WHERE
    source_table = 'EPUS_INC'

),



-- ============================================================================
-- L. INC -> EPUS EPISODE CANDIDATES
-- ============================================================================

inc_candidates AS (


  -- --------------------------------------------------------------------------
  -- 1. TRUSTED NIK + COMPATIBLE PREGNANCY ANCHOR
  -- --------------------------------------------------------------------------

  SELECT

    i.source_record_id
      AS inc_source_record_id,

    e.epus_episode_id,

    'TRUSTED_NIK+ANCHOR'
      AS inc_match_method,

    1
      AS inc_match_priority,

    ABS(
      DATE_DIFF(
        i.inc_pregnancy_anchor_date,
        e.pregnancy_anchor_date,
        DAY
      )
    ) AS anchor_difference_days

  FROM inc_base i

  JOIN episodes e

    ON nik_is_trusted(i.nik_clean)

   AND nik_is_trusted(e.nik_clean)

   AND i.nik_clean = e.nik_clean

   AND i.inc_pregnancy_anchor_date IS NOT NULL

   AND e.pregnancy_anchor_date IS NOT NULL

   AND ABS(
     DATE_DIFF(
       i.inc_pregnancy_anchor_date,
       e.pregnancy_anchor_date,
       DAY
     )
   ) <= inc_nik_anchor_tolerance_days



  UNION ALL



  -- --------------------------------------------------------------------------
  -- 2. NAME CORE + DOB + PUSKESMAS + CLOSE ANCHOR
  --
  -- Used only where at least one side lacks a trusted NIK.
  -- --------------------------------------------------------------------------

  SELECT

    i.source_record_id
      AS inc_source_record_id,

    e.epus_episode_id,

    'NAME_CORE+DOB+PUSKESMAS+ANCHOR'
      AS inc_match_method,

    2
      AS inc_match_priority,

    ABS(
      DATE_DIFF(
        i.inc_pregnancy_anchor_date,
        e.pregnancy_anchor_date,
        DAY
      )
    ) AS anchor_difference_days

  FROM inc_base i

  JOIN episodes e

    ON i.nama_core_norm IS NOT NULL

   AND e.nama_core_norm IS NOT NULL

   AND i.nama_core_norm = e.nama_core_norm

   AND i.tanggal_lahir IS NOT NULL

   AND e.tanggal_lahir_ibu IS NOT NULL

   AND i.tanggal_lahir = e.tanggal_lahir_ibu

   AND i.puskesmas_norm IS NOT NULL

   AND e.puskesmas_norm IS NOT NULL

   AND i.puskesmas_norm = e.puskesmas_norm

   AND i.inc_pregnancy_anchor_date IS NOT NULL

   AND e.pregnancy_anchor_date IS NOT NULL

   AND ABS(
     DATE_DIFF(
       i.inc_pregnancy_anchor_date,
       e.pregnancy_anchor_date,
       DAY
     )
   ) <= inc_weak_anchor_tolerance_days

   AND (
        NOT nik_is_trusted(i.nik_clean)
        OR NOT nik_is_trusted(e.nik_clean)
   )

),



-- ============================================================================
-- M. KEEP BEST EPISODE FOR EACH INC RECORD
-- ============================================================================

inc_best AS (

  SELECT
    *
  FROM (

    SELECT

      c.*,

      ROW_NUMBER() OVER (

        PARTITION BY
          inc_source_record_id

        ORDER BY
          inc_match_priority,
          anchor_difference_days,
          epus_episode_id

      ) AS rn

    FROM inc_candidates c

  )

  WHERE rn = 1

),



-- ============================================================================
-- N. ATTACH INC CONTENT
-- ============================================================================

inc_attached AS (

  SELECT

    b.epus_episode_id,

    b.inc_source_record_id,

    b.inc_match_method,

    b.inc_match_priority,

    b.anchor_difference_days,

    i.delivery_date,

    i.hpht_date
      AS inc_hpht_date,

    i.hpl_date
      AS inc_hpl_date,

    i.no_hp_clean
      AS inc_no_hp_clean,

    i.source_json
      AS inc_source_json

  FROM inc_best b

  JOIN inc_base i
    ON i.source_record_id
       = b.inc_source_record_id

),



-- ============================================================================
-- O. COLLAPSE INC ENRICHMENT TO EPISODE LEVEL
-- ============================================================================

inc_episode_agg AS (

  SELECT

    epus_episode_id,


    COUNT(*)
      AS epus_inc_match_count,


    ARRAY_AGG(
      inc_source_record_id
      ORDER BY inc_source_record_id
    ) AS epus_inc_source_record_ids,


    COUNT(
      DISTINCT delivery_date
    ) AS epus_inc_distinct_delivery_dates,


    ARRAY_AGG(

      STRUCT(
        delivery_date AS value,
        inc_source_record_id AS source_record_id,
        inc_match_method AS match_method,
        inc_match_priority AS match_priority,
        anchor_difference_days AS anchor_difference_days
      )

      ORDER BY
        delivery_date IS NULL,
        inc_match_priority,
        anchor_difference_days,
        inc_source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS delivery_pick,


    ARRAY_AGG(

      STRUCT(
        inc_no_hp_clean AS value,
        inc_source_record_id AS source_record_id
      )

      ORDER BY
        inc_no_hp_clean IS NULL,
        LENGTH(
          COALESCE(
            inc_no_hp_clean,
            ''
          )
        ) DESC,
        inc_source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS inc_phone_pick

  FROM inc_attached

  GROUP BY epus_episode_id

),



-- ============================================================================
-- P. FINAL ADAPTER CONTRACT
-- ============================================================================

final AS (

  SELECT

    e.epus_episode_id,

    e.epus_episode_source_key,


    -- ------------------------------------------------------------------------
    -- IDENTITY
    -- ------------------------------------------------------------------------

    e.nik_clean,

    e.nik_reliability,

    e.nama_ibu,

    e.nama_norm,

    e.nama_core_norm,

    e.tanggal_lahir_ibu,


    COALESCE(
      e.no_hp_clean,
      ia.inc_phone_pick.value
    ) AS no_hp_clean,


    -- ------------------------------------------------------------------------
    -- LOCATION
    -- ------------------------------------------------------------------------

    e.puskesmas,

    e.puskesmas_norm,

    e.puskesmas_id,

    e.desa,

    e.desa_norm,

    e.posyandu,

    e.alamat,


    -- ------------------------------------------------------------------------
    -- PREGNANCY DATING
    -- ------------------------------------------------------------------------

    e.hpht_epus,

    e.hpl_epus,


    COALESCE(
      ia.delivery_pick.value,
      CAST(NULL AS DATE)
    ) AS delivery_epus,


    CASE

      WHEN ia.delivery_pick.value IS NOT NULL
        THEN 'EPUS_INC'

    END AS delivery_epus_source,


    CASE

      WHEN ia.delivery_pick.value IS NOT NULL
        THEN ia.delivery_pick.source_record_id

    END AS delivery_epus_source_record_id,


    CASE

      WHEN ia.delivery_pick.value IS NOT NULL
        THEN ia.delivery_pick.match_method

    END AS delivery_epus_match_method,


    CASE

      WHEN ia.delivery_pick.value IS NOT NULL
        THEN ia.delivery_pick.anchor_difference_days

    END AS delivery_epus_match_anchor_difference_days,


    e.hpl_from_epus_hpht,


    -- ------------------------------------------------------------------------
    -- ANC DATES
    -- ------------------------------------------------------------------------

    e.first_anc_date,

    e.last_anc_date,


    -- ------------------------------------------------------------------------
    -- CANONICAL PRELIMINARY PREGNANCY ANCHOR
    -- ------------------------------------------------------------------------

    e.pregnancy_anchor_date,


    -- ------------------------------------------------------------------------
    -- EPISODE QA
    -- ------------------------------------------------------------------------

    e.pregnancy_anchor_min_date,

    e.pregnancy_anchor_max_date,

    e.pregnancy_anchor_spread_days,

    e.epus_episode_review_flag,


    -- ------------------------------------------------------------------------
    -- EARLY USG
    -- ------------------------------------------------------------------------

    e.has_early_usg_dating,

    e.early_usg_hpl_date,

    e.early_usg_ga_weeks,

    e.early_usg_anc_date,


    -- ------------------------------------------------------------------------
    -- SOURCE PROVENANCE
    -- ------------------------------------------------------------------------

    e.epus_member_record_count,

    e.epus_source_tables,

    e.epus_member_source_record_ids,

    e.mother_identity_key,

    e.mother_identity_method,

    e.mother_identity_methods,


    -- ------------------------------------------------------------------------
    -- INC QA
    -- ------------------------------------------------------------------------

    COALESCE(
      ia.epus_inc_match_count,
      0
    ) AS epus_inc_match_count,


    COALESCE(
      ia.epus_inc_source_record_ids,
      ARRAY<STRING>[]
    ) AS epus_inc_source_record_ids,


    COALESCE(
      ia.epus_inc_distinct_delivery_dates,
      0
    ) AS epus_inc_distinct_delivery_dates,


    (
      COALESCE(
        ia.epus_inc_distinct_delivery_dates,
        0
      ) > 1
    ) AS epus_inc_delivery_conflict_flag,


    -- ------------------------------------------------------------------------
    -- JSON PROVENANCE
    --
    -- This is mainly for debugging / traceability.
    -- ------------------------------------------------------------------------

    TO_JSON_STRING(

      STRUCT(

        e.epus_episode_source_key
          AS epus_episode_source_key,

        e.epus_source_tables
          AS pregnancy_source_tables,

        e.epus_member_source_record_ids
          AS pregnancy_member_record_ids,

        COALESCE(
          ia.epus_inc_source_record_ids,
          ARRAY<STRING>[]
        ) AS inc_member_record_ids

      )

    ) AS source_json


  FROM episodes e

  LEFT JOIN inc_episode_agg ia
    USING (epus_episode_id)

)


SELECT *
FROM final;
