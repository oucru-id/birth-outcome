-- ============================================================================
-- PURBALINGGA
-- 02_build_sigizi_pregnancy_episode_v3_3.sql
--
-- INPUT:
--   stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_source_records
--
-- OUTPUT:
--   stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_pregnancy_episode_v3_3
--
-- PURPOSE:
--   Construct one preliminary SIGIZI pregnancy episode from repeated
--   individual-level SIGIZI source records.
--
-- IMPORTANT:
--
--   Pregnancy-episode creators:
--     DAFTAR_BUMIL
--     KESGA_BUMIL_ANC
--     KOHORT_IBU
--     KESGA_BUMIL
--
--   Outcome enrichment only:
--     IBU_NIFAS
--
--   Rather than hard-coding that list below, the build uses:
--
--       pregnancy_episode_creator_flag = TRUE
--
--   from t_sigizi_source_records.
--
-- IMPORTANT ARCHITECTURE:
--
--   This is NOT yet the final canonical pregnancy table.
--
--   t_sigizi_pregnancy_episode_v3_3
--          ↓
--   03C_v4_1 within-SIGIZI canonicalization
--          ↓
--   SIGIZI <-> EPUS matching
--          ↓
--   final canonical pregnancy_episode_id
--
-- TIMEZONE:
--   Asia/Jakarta
--
-- PREGNANCY ANCHOR:
--   HPHT
--   otherwise HPL - 280 days
--
-- INITIAL EPISODE SPLIT:
--   >120 days between successive pregnancy anchors for the resolved mother
--
-- PLAUSIBILITY FLOOR:
--   2018-01-01
-- ============================================================================


-- ============================================================================
-- 1. PARAMETERS
-- ============================================================================

DECLARE sigizi_episode_anchor_tolerance_days INT64 DEFAULT 120;

DECLARE plausible_pregnancy_floor DATE
  DEFAULT DATE '2018-01-01';

DECLARE analysis_date DATE
  DEFAULT CURRENT_DATE('Asia/Jakarta');



-- ============================================================================
-- 2. TEMP FUNCTIONS
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Generic text normalization
-- ----------------------------------------------------------------------------

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



-- ----------------------------------------------------------------------------
-- Name normalization
-- ----------------------------------------------------------------------------

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



-- ----------------------------------------------------------------------------
-- Name-core normalization
--
-- Remove selected titles / suffixes so:
--
--   IBU SITI AMINAH
--   SITI AMINAH
--
-- can produce the same core identity string.
-- ----------------------------------------------------------------------------

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
        r'\s+(SE|S E|SPD|S PD|SST|S ST|SKM|S KM|M KES|MKES|M KEB|MKEB|S KEP|SKEP|NERS|A MD KEB|AMD KEB)$',
        ''
      )
    ),
    ''
  )
);



-- ----------------------------------------------------------------------------
-- Trusted and plausible maternal NIK
--
-- Indonesian female NIK encodes the birth day as day + 40. The birth date
-- derived from the NIK must also represent a plausible maternal age at the
-- pregnancy reference date. This prevents child or male patient NIKs from
-- creating pregnancy episodes when the maternal name is absent.
-- ----------------------------------------------------------------------------

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


CREATE TEMP FUNCTION maternal_nik_birth_date(
  s STRING,
  reference_date DATE
)
RETURNS DATE
AS (
  CASE
    WHEN nik_is_trusted(s)
     AND reference_date IS NOT NULL
     AND SAFE_CAST(SUBSTR(s, 7, 2) AS INT64) BETWEEN 41 AND 71
     AND SAFE_CAST(SUBSTR(s, 9, 2) AS INT64) BETWEEN 1 AND 12

    THEN SAFE.PARSE_DATE(
      '%Y%m%d',
      CONCAT(
        CASE
          WHEN SAFE_CAST(SUBSTR(s, 11, 2) AS INT64)
                 <= MOD(EXTRACT(YEAR FROM reference_date), 100)
            THEN '20'
          ELSE '19'
        END,
        SUBSTR(s, 11, 2),
        SUBSTR(s, 9, 2),
        LPAD(
          CAST(
            SAFE_CAST(SUBSTR(s, 7, 2) AS INT64) - 40
            AS STRING
          ),
          2,
          '0'
        )
      )
    )
  END
);


CREATE TEMP FUNCTION maternal_nik_is_plausible(
  s STRING,
  reference_date DATE
)
RETURNS BOOL
AS (
  maternal_nik_birth_date(s, reference_date) IS NOT NULL
  AND DATE_DIFF(
        reference_date,
        maternal_nik_birth_date(s, reference_date),
        YEAR
      ) BETWEEN 10 AND 60
);



-- ----------------------------------------------------------------------------
-- Generic Puskesmas normalization
--
-- IMPORTANT:
-- There are NO Lombok-specific aliases here.
--
-- We only remove the generic leading word:
--
--   PUSKESMAS SERAYU LARANGAN
--          ↓
--   SERAYU LARANGAN
--
-- This will also make future EPUS/SIMRS geography matching easier.
-- ----------------------------------------------------------------------------

CREATE TEMP FUNCTION norm_puskesmas(s STRING)
RETURNS STRING
AS (
  CASE

    WHEN norm_text(s) IS NULL
      THEN NULL

    ELSE REGEXP_REPLACE(
      norm_text(s),
      r'^PUSKESMAS\s+',
      ''
    )

  END
);



-- ----------------------------------------------------------------------------
-- Anonymous placeholder exclusion
-- ----------------------------------------------------------------------------

CREATE TEMP FUNCTION is_sigizi_anon_placeholder(s STRING)
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
-- 3. BUILD TABLE
-- ============================================================================

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_pregnancy_episode_v3_3`

CLUSTER BY
  nik_clean,
  puskesmas_norm,
  sigizi_episode_id

AS


WITH


-- ============================================================================
-- A. SOURCE BASE
--
-- CRITICAL:
-- Only rows explicitly marked as pregnancy episode creators are allowed here.
--
-- Therefore:
--   IBU_NIFAS remains in t_sigizi_source_records
--   but does NOT create denominator pregnancies.
-- ============================================================================

source_base AS (

  SELECT

    source_table,
    source_priority,
    source_role,

    source_record_id,

    nik_clean,

    nama,
    norm_name(nama) AS nama_episode_norm,
    norm_name_core(nama) AS nama_core_norm,

    tanggal_lahir,

    hpht_date,
    hpl_date,
    anc_date,
    delivery_date,

    norm_puskesmas(
      COALESCE(
        puskesmas_norm,
        puskesmas
      )
    ) AS puskesmas,

    norm_puskesmas(
      COALESCE(
        puskesmas_norm,
        puskesmas
      )
    ) AS puskesmas_norm,

    norm_text(
      COALESCE(
        desa_norm,
        desa
      )
    ) AS desa,

    norm_text(
      COALESCE(
        desa_norm,
        desa
      )
    ) AS desa_norm,

    posyandu,
    alamat,

    no_hp_clean

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_sigizi_source_records`

  WHERE
    pregnancy_episode_creator_flag = TRUE

    AND NOT (
         is_sigizi_anon_placeholder(nama)
      OR is_sigizi_anon_placeholder(nama_norm)
    )

    -- A pregnancy-denominator record must have either a usable maternal name
    -- or a NIK that is plausible for a female of reproductive age at the
    -- pregnancy date. Date-only, child-NIK, and male-NIK rows remain available
    -- in t_sigizi_source_records for audit but cannot create pregnancies.
    AND (
         norm_name_core(nama) IS NOT NULL

      OR maternal_nik_is_plausible(
           nik_clean,
           COALESCE(
             hpht_date,
             DATE_SUB(hpl_date, INTERVAL 280 DAY),
             anc_date,
             analysis_date
           )
         )
    )

),



-- ============================================================================
-- B. DATE VALIDATION FOR EPISODE CONSTRUCTION
--
-- t_sigizi_source_records already performs date QA.
--
-- This provides an additional analytical guard:
--
-- HPHT:
--   2018-01-01 through today
--
-- HPL:
--   2018-01-01 through today + 300 days
--
-- DELIVERY:
--   2018-01-01 through today
--
-- ANC:
--   2018-01-01 through today
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

    END AS hpl_valid,


    CASE

      WHEN delivery_date
        BETWEEN plausible_pregnancy_floor
            AND analysis_date

      THEN delivery_date

    END AS delivery_valid,


    CASE

      WHEN anc_date
        BETWEEN plausible_pregnancy_floor
            AND analysis_date

      THEN anc_date

    END AS anc_valid

  FROM source_base

),



-- ============================================================================
-- C. DEFINE PREGNANCY ANCHOR
--
-- Priority:
--
--   1. HPHT
--   2. HPL - 280 days
--
-- Delivery does NOT create the pregnancy anchor.
--
-- Therefore a row with only a delivery date cannot independently create a
-- pregnancy episode.
-- ============================================================================

identity_base AS (

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

    ) AS pregnancy_anchor_date

  FROM prepared

),



-- ============================================================================
-- D. STRICT PREGNANCY SIGNATURE
--
-- Used only for conservative weak-identity rescue.
--
-- Requires:
--
--   exact normalized core name
--   exact Puskesmas
--   exact Desa
--   exact pregnancy anchor
--
-- This is intentionally strict.
-- ============================================================================

signature_base AS (

  SELECT
    *,

    CASE

      WHEN nama_core_norm IS NOT NULL

       AND puskesmas_norm IS NOT NULL

       AND desa_norm IS NOT NULL

       AND pregnancy_anchor_date IS NOT NULL

      THEN CONCAT(
        'PREGSIG|',
        nama_core_norm,
        '|',
        puskesmas_norm,
        '|',
        desa_norm,
        '|',
        CAST(
          pregnancy_anchor_date
          AS STRING
        )
      )

    END AS pregnancy_signature_key

  FROM identity_base

),



-- ============================================================================
-- E. SIGNATURE STATISTICS
--
-- Determine whether a weak pregnancy signature points to:
--
--   exactly one NIK
--   exactly one DOB
--   conflicting NIKs
--   conflicting DOBs
--
-- Do not blindly propagate ambiguous identity.
-- ============================================================================

signature_stats AS (

  SELECT

    pregnancy_signature_key,


    COUNT(*)
      AS signature_row_count,


    COUNT(
      DISTINCT nik_clean
    ) AS signature_distinct_nik_count,


    ARRAY_AGG(
      DISTINCT nik_clean
      IGNORE NULLS
      ORDER BY nik_clean
      LIMIT 1
    )[SAFE_OFFSET(0)]
      AS signature_unique_nik,


    COUNT(
      DISTINCT tanggal_lahir
    ) AS signature_distinct_dob_count,


    ARRAY_AGG(
      DISTINCT tanggal_lahir
      IGNORE NULLS
      ORDER BY tanggal_lahir
      LIMIT 1
    )[SAFE_OFFSET(0)]
      AS signature_unique_dob

  FROM signature_base

  WHERE
    pregnancy_signature_key IS NOT NULL

  GROUP BY
    pregnancy_signature_key

),



-- ============================================================================
-- F. RESOLVE PRELIMINARY MATERNAL IDENTITY
--
-- Hierarchy:
--
-- 1. Own NIK
--
-- 2. Exact pregnancy signature maps to exactly one NIK
--
-- 3. Name core + DOB + Puskesmas
--
-- 4. Name core + DOB + Desa
--
-- 5. Name core + DOB
--
-- 6. Exact pregnancy signature maps to exactly one DOB
--
-- 7. Pure weak pregnancy signature
--
-- 8. Keep source record separate
--
-- NOTE:
-- This is PRELIMINARY identity construction.
--
-- 03C v4.1 will later perform conservative within-SIGIZI canonicalization
-- and specifically handles suspect/rounded NIK and other residual conflicts.
-- ============================================================================

identified AS (

  SELECT

    b.*,


    COALESCE(
      s.signature_row_count,
      1
    ) AS signature_row_count,


    COALESCE(
      s.signature_distinct_nik_count,
      0
    ) AS signature_distinct_nik_count,


    s.signature_unique_nik,


    COALESCE(
      s.signature_distinct_dob_count,
      0
    ) AS signature_distinct_dob_count,


    s.signature_unique_dob,


    -- ------------------------------------------------------------------------
    -- MATERNAL IDENTITY KEY
    -- ------------------------------------------------------------------------

    CASE


      -- ======================================================================
      -- 1. OWN NIK
      -- ======================================================================

      WHEN b.nik_clean IS NOT NULL

      THEN CONCAT(
        'NIK|',
        b.nik_clean
      )


      -- ======================================================================
      -- 2. STRICT SIGNATURE -> UNIQUE NIK
      -- ======================================================================

      WHEN b.pregnancy_signature_key IS NOT NULL

       AND COALESCE(
             s.signature_distinct_nik_count,
             0
           ) = 1

       AND s.signature_unique_nik IS NOT NULL

      THEN CONCAT(
        'NIK|',
        s.signature_unique_nik
      )


      -- ======================================================================
      -- 3. NAME + DOB + PUSKESMAS
      -- ======================================================================

      WHEN b.nama_core_norm IS NOT NULL

       AND b.tanggal_lahir IS NOT NULL

       AND b.puskesmas_norm IS NOT NULL

      THEN CONCAT(
        'NAME_DOB_PKM|',
        b.nama_core_norm,
        '|',
        CAST(
          b.tanggal_lahir
          AS STRING
        ),
        '|',
        b.puskesmas_norm
      )


      -- ======================================================================
      -- 4. NAME + DOB + DESA
      -- ======================================================================

      WHEN b.nama_core_norm IS NOT NULL

       AND b.tanggal_lahir IS NOT NULL

       AND b.desa_norm IS NOT NULL

      THEN CONCAT(
        'NAME_DOB_DESA|',
        b.nama_core_norm,
        '|',
        CAST(
          b.tanggal_lahir
          AS STRING
        ),
        '|',
        b.desa_norm
      )


      -- ======================================================================
      -- 5. NAME + DOB
      -- ======================================================================

      WHEN b.nama_core_norm IS NOT NULL

       AND b.tanggal_lahir IS NOT NULL

      THEN CONCAT(
        'NAME_DOB|',
        b.nama_core_norm,
        '|',
        CAST(
          b.tanggal_lahir
          AS STRING
        )
      )


      -- ======================================================================
      -- 6. STRICT SIGNATURE -> UNIQUE DOB
      --
      -- Only when the signature has no known NIK.
      -- ======================================================================

      WHEN b.pregnancy_signature_key IS NOT NULL

       AND COALESCE(
             s.signature_distinct_nik_count,
             0
           ) = 0

       AND COALESCE(
             s.signature_distinct_dob_count,
             0
           ) = 1

       AND s.signature_unique_dob IS NOT NULL

      THEN CONCAT(
        'NAME_DOB_PKM|',
        b.nama_core_norm,
        '|',
        CAST(
          s.signature_unique_dob
          AS STRING
        ),
        '|',
        b.puskesmas_norm
      )


      -- ======================================================================
      -- 7. WEAK PREGNANCY SIGNATURE
      --
      -- No NIK and no DOB available.
      -- ======================================================================

      WHEN b.pregnancy_signature_key IS NOT NULL

       AND COALESCE(
             s.signature_distinct_nik_count,
             0
           ) = 0

       AND COALESCE(
             s.signature_distinct_dob_count,
             0
           ) = 0

      THEN b.pregnancy_signature_key


      -- ======================================================================
      -- 8. SOURCE RECORD
      --
      -- Do not force weak records together.
      -- ======================================================================

      ELSE CONCAT(
        'SOURCE|',
        b.source_table,
        '|',
        b.source_record_id
      )

    END AS mother_identity_key,



    -- ------------------------------------------------------------------------
    -- MATERNAL IDENTITY METHOD
    -- ------------------------------------------------------------------------

    CASE

      WHEN b.nik_clean IS NOT NULL

        THEN 'NIK'


      WHEN b.pregnancy_signature_key IS NOT NULL

       AND COALESCE(
             s.signature_distinct_nik_count,
             0
           ) = 1

       AND s.signature_unique_nik IS NOT NULL

        THEN 'PREG_SIGNATURE_TO_UNIQUE_NIK'


      WHEN b.nama_core_norm IS NOT NULL

       AND b.tanggal_lahir IS NOT NULL

       AND b.puskesmas_norm IS NOT NULL

        THEN 'NAMA_CORE+DOB+PUSKESMAS'


      WHEN b.nama_core_norm IS NOT NULL

       AND b.tanggal_lahir IS NOT NULL

       AND b.desa_norm IS NOT NULL

        THEN 'NAMA_CORE+DOB+DESA'


      WHEN b.nama_core_norm IS NOT NULL

       AND b.tanggal_lahir IS NOT NULL

        THEN 'NAMA_CORE+DOB'


      WHEN b.pregnancy_signature_key IS NOT NULL

       AND COALESCE(
             s.signature_distinct_nik_count,
             0
           ) = 0

       AND COALESCE(
             s.signature_distinct_dob_count,
             0
           ) = 1

       AND s.signature_unique_dob IS NOT NULL

        THEN 'PREG_SIGNATURE_TO_UNIQUE_DOB'


      WHEN b.pregnancy_signature_key IS NOT NULL

       AND COALESCE(
             s.signature_distinct_nik_count,
             0
           ) = 0

       AND COALESCE(
             s.signature_distinct_dob_count,
             0
           ) = 0

        THEN 'WEAK_PREG_SIGNATURE'


      ELSE 'SOURCE_RECORD'

    END AS mother_identity_method,



    -- ------------------------------------------------------------------------
    -- IDENTITY PROPAGATION FLAG
    -- ------------------------------------------------------------------------

    (
      b.nik_clean IS NULL

      AND (

        (
          b.pregnancy_signature_key IS NOT NULL

          AND COALESCE(
                s.signature_distinct_nik_count,
                0
              ) = 1

          AND s.signature_unique_nik IS NOT NULL
        )

        OR

        (
          b.tanggal_lahir IS NULL

          AND b.pregnancy_signature_key IS NOT NULL

          AND COALESCE(
                s.signature_distinct_nik_count,
                0
              ) = 0

          AND COALESCE(
                s.signature_distinct_dob_count,
                0
              ) = 1

          AND s.signature_unique_dob IS NOT NULL
        )

      )

    ) AS identity_propagated_flag,



    -- ------------------------------------------------------------------------
    -- AMBIGUOUS WEAK SIGNATURE FLAG
    -- ------------------------------------------------------------------------

    (
      b.nik_clean IS NULL

      AND b.tanggal_lahir IS NULL

      AND b.pregnancy_signature_key IS NOT NULL

      AND (

           COALESCE(
             s.signature_distinct_nik_count,
             0
           ) > 1

        OR

           COALESCE(
             s.signature_distinct_dob_count,
             0
           ) > 1

      )

    ) AS weak_signature_ambiguous_flag


  FROM signature_base b

  LEFT JOIN signature_stats s
    USING (pregnancy_signature_key)

),



-- ============================================================================
-- G. ONLY DATED PREGNANCY RECORDS CREATE EPISODES
-- ============================================================================

anchor_records AS (

  SELECT *
  FROM identified

  WHERE
    pregnancy_anchor_date IS NOT NULL

),



-- ============================================================================
-- H. ORDER PREGNANCY ANCHORS FOR EACH PRELIMINARY MOTHER
-- ============================================================================

ordered AS (

  SELECT
    *,

    LAG(
      pregnancy_anchor_date
    ) OVER (

      PARTITION BY
        mother_identity_key

      ORDER BY
        pregnancy_anchor_date,
        source_priority,
        source_record_id

    ) AS previous_anchor_date

  FROM anchor_records

),



-- ============================================================================
-- I. START NEW EPISODE IF GAP > 120 DAYS
-- ============================================================================

marked AS (

  SELECT
    *,

    CASE

      WHEN previous_anchor_date IS NULL
        THEN 1


      WHEN DATE_DIFF(
        pregnancy_anchor_date,
        previous_anchor_date,
        DAY
      ) > sigizi_episode_anchor_tolerance_days

        THEN 1


      ELSE 0

    END AS starts_new_episode

  FROM ordered

),



-- ============================================================================
-- J. NUMBER EPISODES WITHIN EACH PRELIMINARY MATERNAL IDENTITY
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
        pregnancy_anchor_date,
        source_priority,
        source_record_id

      ROWS BETWEEN
        UNBOUNDED PRECEDING
        AND CURRENT ROW

    ) AS episode_number

  FROM marked

),



-- ============================================================================
-- K. COLLAPSE SOURCE ROWS TO ONE PRELIMINARY SIGIZI PREGNANCY EPISODE
-- ============================================================================

aggregated AS (

  SELECT

    mother_identity_key,
    episode_number,


    -- ------------------------------------------------------------------------
    -- BEST / REPRESENTATIVE IDENTITY METHOD
    -- ------------------------------------------------------------------------

    ARRAY_AGG(

      mother_identity_method

      ORDER BY

        CASE mother_identity_method

          WHEN 'NIK'
            THEN 1

          WHEN 'PREG_SIGNATURE_TO_UNIQUE_NIK'
            THEN 2

          WHEN 'NAMA_CORE+DOB+PUSKESMAS'
            THEN 3

          WHEN 'NAMA_CORE+DOB+DESA'
            THEN 4

          WHEN 'PREG_SIGNATURE_TO_UNIQUE_DOB'
            THEN 5

          WHEN 'NAMA_CORE+DOB'
            THEN 6

          WHEN 'WEAK_PREG_SIGNATURE'
            THEN 7

          ELSE 9

        END,

        source_priority,
        source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS mother_identity_method,



    -- ------------------------------------------------------------------------
    -- ALL IDENTITY METHODS PRESENT
    -- ------------------------------------------------------------------------

    ARRAY_AGG(
      DISTINCT mother_identity_method
      ORDER BY mother_identity_method
    ) AS mother_identity_methods,



    -- ------------------------------------------------------------------------
    -- PREGNANCY ANCHOR RANGE
    -- ------------------------------------------------------------------------

    MIN(
      pregnancy_anchor_date
    ) AS pregnancy_anchor_min_date,


    MAX(
      pregnancy_anchor_date
    ) AS pregnancy_anchor_max_date,


    DATE_DIFF(

      MAX(
        pregnancy_anchor_date
      ),

      MIN(
        pregnancy_anchor_date
      ),

      DAY

    ) AS pregnancy_anchor_spread_days,



    -- ------------------------------------------------------------------------
    -- MEMBER COUNTS / QA
    -- ------------------------------------------------------------------------

    COUNT(*)
      AS sigizi_member_record_count,


    COUNTIF(
      identity_propagated_flag
    ) AS sigizi_identity_propagated_record_count,


    COUNTIF(
      weak_signature_ambiguous_flag
    ) AS sigizi_ambiguous_identity_record_count,


    MAX(
      signature_row_count
    ) AS sigizi_max_signature_row_count,


    COUNT(
      DISTINCT pregnancy_signature_key
    ) AS sigizi_distinct_pregnancy_signature_count,



    -- ------------------------------------------------------------------------
    -- SOURCE TABLES
    -- ------------------------------------------------------------------------

    ARRAY_AGG(
      DISTINCT source_table
      ORDER BY source_table
    ) AS sigizi_source_tables,



    -- ------------------------------------------------------------------------
    -- SOURCE RECORD IDS
    -- ------------------------------------------------------------------------

    ARRAY_AGG(
      source_record_id

      ORDER BY
        source_priority,
        source_record_id

    ) AS sigizi_member_source_record_ids,



    -- ------------------------------------------------------------------------
    -- NIK PICK
    --
    -- Source priority provides deterministic preliminary selection.
    --
    -- 03C v4.1 later prefers trusted NIK and handles rounded/suspect NIK.
    -- ------------------------------------------------------------------------

    ARRAY_AGG(

      STRUCT(

        nik_clean
          AS value,

        source_priority
          AS priority,

        source_record_id
          AS source_record_id

      )

      ORDER BY
        nik_clean IS NULL,
        source_priority,
        source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS nik_pick,



    -- ------------------------------------------------------------------------
    -- NAME PICK
    -- ------------------------------------------------------------------------

    ARRAY_AGG(

      STRUCT(

        nama
          AS value,

        nama_episode_norm
          AS value_norm,

        nama_core_norm
          AS value_core_norm,

        source_priority
          AS priority,

        source_record_id
          AS source_record_id

      )

      ORDER BY
        nama_core_norm IS NULL,
        source_priority,
        source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS nama_pick,



    -- ------------------------------------------------------------------------
    -- DOB PICK
    -- ------------------------------------------------------------------------

    ARRAY_AGG(

      STRUCT(

        tanggal_lahir
          AS value,

        source_priority
          AS priority,

        source_record_id
          AS source_record_id

      )

      ORDER BY
        tanggal_lahir IS NULL,
        source_priority,
        source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS dob_pick,



    -- ------------------------------------------------------------------------
    -- PHONE PICK
    --
    -- Prefer a non-null and longer normalized phone.
    -- ------------------------------------------------------------------------

    ARRAY_AGG(

      STRUCT(

        no_hp_clean
          AS value,

        source_priority
          AS priority,

        source_record_id
          AS source_record_id

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
    -- CRITICAL:
    -- Puskesmas / Desa / Posyandu / Alamat are selected from ONE member row.
    --
    -- Do not independently combine:
    --   Puskesmas from record A
    --   Desa from record B
    --   Posyandu from record C
    --
    -- because that can produce impossible geography.
    -- ------------------------------------------------------------------------

    ARRAY_AGG(

      STRUCT(

        puskesmas
          AS puskesmas,

        puskesmas_norm
          AS puskesmas_norm,

        desa
          AS desa,

        desa_norm
          AS desa_norm,

        posyandu
          AS posyandu,

        alamat
          AS alamat,


        CASE

          WHEN puskesmas_norm IS NOT NULL
           AND desa_norm IS NOT NULL
           AND posyandu IS NOT NULL

            THEN 'SOURCE_BUNDLE_PKM+DESA+POSYANDU'


          WHEN puskesmas_norm IS NOT NULL
           AND desa_norm IS NOT NULL

            THEN 'SOURCE_BUNDLE_PKM+DESA'


          WHEN puskesmas_norm IS NOT NULL

            THEN 'SOURCE_BUNDLE_PKM'


          ELSE 'UNRESOLVED'

        END AS resolution_method,


        CASE

          WHEN puskesmas_norm IS NOT NULL
           AND desa_norm IS NOT NULL

            THEN 'VERY_HIGH'


          WHEN puskesmas_norm IS NOT NULL

            THEN 'HIGH'


          ELSE 'UNRESOLVED'

        END AS resolution_confidence,


        (
            IF(
              puskesmas_norm IS NOT NULL,
              10,
              0
            )

          + IF(
              desa_norm IS NOT NULL,
              5,
              0
            )

          + IF(
              posyandu IS NOT NULL,
              2,
              0
            )

          + IF(
              alamat IS NOT NULL,
              1,
              0
            )

        ) AS resolution_score,


        source_table
          AS source_table,

        source_record_id
          AS source_record_id,

        source_priority
          AS source_priority

      )

      ORDER BY

        puskesmas_norm IS NULL,

        desa_norm IS NULL,

        posyandu IS NULL,

        (
            IF(
              puskesmas_norm IS NOT NULL,
              10,
              0
            )

          + IF(
              desa_norm IS NOT NULL,
              5,
              0
            )

          + IF(
              posyandu IS NOT NULL,
              2,
              0
            )

          + IF(
              alamat IS NOT NULL,
              1,
              0
            )
        ) DESC,

        source_priority,

        source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS location_pick,



    -- ------------------------------------------------------------------------
    -- HPHT PICK
    -- ------------------------------------------------------------------------

    ARRAY_AGG(

      STRUCT(

        hpht_valid
          AS value,

        source_table
          AS source_table,

        source_priority
          AS priority,

        source_record_id
          AS source_record_id

      )

      ORDER BY

        hpht_valid IS NULL,

        source_priority,

        source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS hpht_pick,



    -- ------------------------------------------------------------------------
    -- HPL PICK
    -- ------------------------------------------------------------------------

    ARRAY_AGG(

      STRUCT(

        hpl_valid
          AS value,

        source_table
          AS source_table,

        source_priority
          AS priority,

        source_record_id
          AS source_record_id

      )

      ORDER BY

        hpl_valid IS NULL,

        source_priority,

        source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS hpl_pick,



    -- ------------------------------------------------------------------------
    -- DELIVERY PICK
    --
    -- Only pregnancy-episode-creator records are in this table.
    --
    -- KOHORT_IBU can therefore contribute delivery_sigizi.
    -- IBU_NIFAS does not enter here and will be used later as outcome evidence.
    -- ------------------------------------------------------------------------

    ARRAY_AGG(

      STRUCT(

        delivery_valid
          AS value,

        source_table
          AS source_table,

        source_priority
          AS priority,

        source_record_id
          AS source_record_id

      )

      ORDER BY

        delivery_valid IS NULL,

        source_priority,

        source_record_id

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS delivery_pick,



    -- ------------------------------------------------------------------------
    -- ANC WINDOW
    -- ------------------------------------------------------------------------

    MIN(
      anc_valid
    ) AS first_anc_date,


    MAX(
      anc_valid
    ) AS last_anc_date


  FROM numbered

  GROUP BY
    mother_identity_key,
    episode_number

)



-- ============================================================================
-- L. FINAL STAGE-1 SIGIZI EPISODE TABLE
-- ============================================================================

SELECT


  -- --------------------------------------------------------------------------
  -- EPISODE ID
  -- --------------------------------------------------------------------------

  CONCAT(

    'SIGEP_',

    TO_HEX(

      SHA256(

        CONCAT(

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

        )

      )

    )

  ) AS sigizi_episode_id,



  -- --------------------------------------------------------------------------
  -- PRELIMINARY MATERNAL IDENTITY
  -- --------------------------------------------------------------------------

  mother_identity_key,

  mother_identity_method,

  episode_number,



  -- --------------------------------------------------------------------------
  -- IDENTITY
  -- --------------------------------------------------------------------------

  nik_pick.value
    AS nik_clean,


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



  -- --------------------------------------------------------------------------
  -- GEOGRAPHY
  -- --------------------------------------------------------------------------

  location_pick.puskesmas
    AS puskesmas,


  location_pick.puskesmas_norm
    AS puskesmas_norm,


  location_pick.desa
    AS desa,


  location_pick.desa_norm
    AS desa_norm,


  location_pick.posyandu
    AS posyandu,


  location_pick.alamat
    AS alamat,


  location_pick.resolution_method
    AS location_resolution_method,


  location_pick.resolution_confidence
    AS location_resolution_confidence,


  location_pick.resolution_score
    AS location_resolution_score,


  location_pick.source_table
    AS location_source_table,


  location_pick.source_record_id
    AS location_source_record_id,



  -- --------------------------------------------------------------------------
  -- SIGIZI PREGNANCY DATING
  -- --------------------------------------------------------------------------

  hpht_pick.value
    AS hpht_sigizi,


  CASE

    WHEN hpht_pick.value IS NOT NULL

      THEN hpht_pick.source_table

  END AS hpht_sigizi_source_table,



  hpl_pick.value
    AS hpl_sigizi,


  CASE

    WHEN hpl_pick.value IS NOT NULL

      THEN hpl_pick.source_table

  END AS hpl_sigizi_source_table,



  delivery_pick.value
    AS delivery_sigizi,


  CASE

    WHEN delivery_pick.value IS NOT NULL

      THEN delivery_pick.source_table

  END AS delivery_sigizi_source_table,



  -- --------------------------------------------------------------------------
  -- HPL CALCULATED FROM HPHT
  -- --------------------------------------------------------------------------

  CASE

    WHEN hpht_pick.value IS NOT NULL

    THEN DATE_ADD(
      hpht_pick.value,
      INTERVAL 280 DAY
    )

  END AS hpl_from_sigizi_hpht,



  -- --------------------------------------------------------------------------
  -- ANC RANGE
  -- --------------------------------------------------------------------------

  first_anc_date,

  last_anc_date,



  -- --------------------------------------------------------------------------
  -- PREGNANCY ANCHOR
  -- --------------------------------------------------------------------------

  pregnancy_anchor_min_date,

  pregnancy_anchor_max_date,

  pregnancy_anchor_spread_days,



  -- --------------------------------------------------------------------------
  -- EPISODE QA
  --
  -- Because episode formation is based on consecutive gaps <=120 days,
  -- chained records can occasionally produce an overall episode span >120d.
  -- Those are retained but flagged for review.
  -- --------------------------------------------------------------------------

  (
    pregnancy_anchor_spread_days
      > sigizi_episode_anchor_tolerance_days
  ) AS sigizi_episode_review_flag,



  -- --------------------------------------------------------------------------
  -- SOURCE PROVENANCE
  -- --------------------------------------------------------------------------

  sigizi_member_record_count,

  sigizi_source_tables,

  sigizi_member_source_record_ids,

  mother_identity_methods,



  -- --------------------------------------------------------------------------
  -- IDENTITY QA
  -- --------------------------------------------------------------------------

  sigizi_identity_propagated_record_count,

  sigizi_ambiguous_identity_record_count,

  sigizi_max_signature_row_count,

  sigizi_distinct_pregnancy_signature_count


FROM aggregated;
