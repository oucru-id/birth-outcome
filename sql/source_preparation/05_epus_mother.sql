-- Recovered source builder; v3 target. Run the complete file.
-- StandardSQL
-- ============================================================
-- ePUSKESMAS MOTHER IDENTITY ASSIGNMENT
--
-- Output:
--   spheres-lombok-barat.kohort_bumil_v3.t_epus_mother_records
--
-- Grain:
--   one row = one normalized ePuskesmas source event
--             + assigned epus_mother_key
--
-- IMPORTANT:
-- This table does NOT yet:
--   - assign pregnancy episodes
--   - merge ANC visits
--   - collapse to one row per mother
--
-- Mother matching hierarchy:
--
--   1. Valid NIK
--   2. Name + DOB -> unique known NIK
--   3. Name + phone -> unique known NIK
--   4. Name + DOB fallback
--   5. Name + phone fallback
--   6. Source-specific weak identity
--
-- HPHT/HPL are intentionally NOT used for mother identity.
-- ============================================================


CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_epus_mother_records`

PARTITION BY event_date

CLUSTER BY
  epus_mother_key,
  source_table,
  event_type,
  nik_clean

AS


WITH
-- ============================================================
-- 1. SOURCE
-- ============================================================
source AS (
  SELECT
    s.*,

    -- --------------------------------------------------------
    -- Standardize Indonesian phone number where possible.
    --
    -- Examples:
    -- 081234567890  -> 6281234567890
    -- 81234567890   -> 6281234567890
    -- 6281234567890 -> unchanged
    --
    -- Invalid/unusable formats remain NULL for matching.
    -- Original no_hp_clean remains available.
    -- --------------------------------------------------------
    CASE
      WHEN no_hp_clean IS NULL
      THEN NULL

      WHEN REGEXP_CONTAINS(
        no_hp_clean,
        r'^08\d{7,12}$'
      )
      THEN CONCAT(
        '62',
        SUBSTR(no_hp_clean, 2)
      )

      WHEN REGEXP_CONTAINS(
        no_hp_clean,
        r'^8\d{7,12}$'
      )
      THEN CONCAT(
        '62',
        no_hp_clean
      )

      WHEN REGEXP_CONTAINS(
        no_hp_clean,
        r'^628\d{7,12}$'
      )
      THEN no_hp_clean

      ELSE NULL
    END AS no_hp_norm

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_source_records` s
),


-- ============================================================
-- 2. VALID-NIK ANCHOR MAP: NAME + DOB
--
-- Purpose:
-- If a record has no valid NIK but exactly matches a name+DOB
-- combination which consistently belongs to ONE valid NIK,
-- we can safely attach it to that NIK.
--
-- If the same name+DOB is associated with >1 valid NIK,
-- it is ambiguous and will NOT be automatically linked.
-- ============================================================
name_dob_nik_anchor AS (
  SELECT
    nama_norm,
    tanggal_lahir,

    COUNT(
      DISTINCT nik_clean
    ) AS candidate_nik_count,

    MIN(nik_clean)
      AS unique_candidate_nik

  FROM source

  WHERE
    flag_nik_valid = TRUE
    AND nik_clean IS NOT NULL
    AND nama_norm IS NOT NULL
    AND tanggal_lahir IS NOT NULL

  GROUP BY
    nama_norm,
    tanggal_lahir
),


-- ============================================================
-- 3. VALID-NIK ANCHOR MAP: NAME + PHONE
--
-- Mainly useful when DOB is unavailable.
--
-- If the same name+phone points to multiple valid NIKs,
-- automatic linkage is disabled.
-- ============================================================
name_phone_nik_anchor AS (
  SELECT
    nama_norm,
    no_hp_norm,

    COUNT(
      DISTINCT nik_clean
    ) AS candidate_nik_count,

    MIN(nik_clean)
      AS unique_candidate_nik

  FROM source

  WHERE
    flag_nik_valid = TRUE
    AND nik_clean IS NOT NULL
    AND nama_norm IS NOT NULL
    AND no_hp_norm IS NOT NULL

  GROUP BY
    nama_norm,
    no_hp_norm
),


-- ============================================================
-- 4. ATTACH POSSIBLE NIK ANCHORS TO EACH SOURCE RECORD
-- ============================================================
candidate_matching AS (
  SELECT
    s.*,


    -- --------------------------------------------------------
    -- Name + DOB candidate
    -- --------------------------------------------------------
    COALESCE(
      nd.candidate_nik_count,
      0
    ) AS name_dob_candidate_nik_count,

    CASE
      WHEN nd.candidate_nik_count = 1
      THEN nd.unique_candidate_nik
      ELSE NULL
    END AS name_dob_candidate_nik,


    -- --------------------------------------------------------
    -- Name + phone candidate
    -- --------------------------------------------------------
    COALESCE(
      np.candidate_nik_count,
      0
    ) AS name_phone_candidate_nik_count,

    CASE
      WHEN np.candidate_nik_count = 1
      THEN np.unique_candidate_nik
      ELSE NULL
    END AS name_phone_candidate_nik


  FROM source s


  LEFT JOIN name_dob_nik_anchor nd
    ON s.nama_norm = nd.nama_norm
   AND s.tanggal_lahir = nd.tanggal_lahir


  LEFT JOIN name_phone_nik_anchor np
    ON s.nama_norm = np.nama_norm
   AND s.no_hp_norm = np.no_hp_norm
),


-- ============================================================
-- 5. IDENTITY QA
--
-- Detect ambiguous or contradictory fallback evidence.
-- ============================================================
identity_qa AS (
  SELECT
    c.*,


    -- --------------------------------------------------------
    -- Multiple valid NIKs share this exact name + DOB
    -- --------------------------------------------------------
    CASE
      WHEN name_dob_candidate_nik_count > 1
      THEN TRUE
      ELSE FALSE
    END AS flag_name_dob_multiple_nik,


    -- --------------------------------------------------------
    -- Multiple valid NIKs share this exact name + phone
    -- --------------------------------------------------------
    CASE
      WHEN name_phone_candidate_nik_count > 1
      THEN TRUE
      ELSE FALSE
    END AS flag_name_phone_multiple_nik,


    -- --------------------------------------------------------
    -- Both fallback methods individually resolve uniquely,
    -- but they resolve to DIFFERENT NIKs.
    --
    -- This should never be silently linked.
    -- --------------------------------------------------------
    CASE
      WHEN
        name_dob_candidate_nik_count = 1
        AND name_phone_candidate_nik_count = 1
        AND name_dob_candidate_nik
            != name_phone_candidate_nik
      THEN TRUE

      ELSE FALSE
    END AS flag_fallback_identity_conflict

  FROM candidate_matching c
),


-- ============================================================
-- 6. RESOLVE MOTHER IDENTITY METHOD
-- ============================================================
resolved AS (
  SELECT
    q.*,


    -- ========================================================
    -- RESOLVED NIK
    --
    -- A record with no NIK can inherit a valid NIK only when
    -- matching evidence is unique and non-conflicting.
    -- ========================================================
    CASE

      -- ------------------------------------------------------
      -- 1. Source itself has valid NIK
      -- ------------------------------------------------------
      WHEN
        flag_nik_valid = TRUE
        AND nik_clean IS NOT NULL
      THEN nik_clean


      -- ------------------------------------------------------
      -- Conflicting fallback evidence:
      -- do NOT inherit either NIK.
      -- ------------------------------------------------------
      WHEN flag_fallback_identity_conflict = TRUE
      THEN NULL


      -- ------------------------------------------------------
      -- 2. Unique name + DOB anchor
      -- ------------------------------------------------------
      WHEN name_dob_candidate_nik_count = 1
      THEN name_dob_candidate_nik


      -- ------------------------------------------------------
      -- 3. Unique name + phone anchor
      --
      -- This can also disambiguate a name+DOB combination
      -- that maps to >1 NIK.
      -- ------------------------------------------------------
      WHEN name_phone_candidate_nik_count = 1
      THEN name_phone_candidate_nik


      ELSE NULL
    END AS resolved_nik,


    -- ========================================================
    -- MATCH METHOD
    -- ========================================================
    CASE

      WHEN
        flag_nik_valid = TRUE
        AND nik_clean IS NOT NULL
      THEN 'NIK_VALID'


      WHEN flag_fallback_identity_conflict = TRUE
      THEN 'AMBIGUOUS_FALLBACK_CONFLICT'


      WHEN name_dob_candidate_nik_count = 1
      THEN 'NAME+DOB_TO_UNIQUE_NIK'


      WHEN name_phone_candidate_nik_count = 1
      THEN 'NAME+PHONE_TO_UNIQUE_NIK'


      -- ------------------------------------------------------
      -- No known NIK anchor exists, but name+DOB is available.
      -- Group these records together cautiously.
      -- ------------------------------------------------------
      WHEN
        nama_norm IS NOT NULL
        AND tanggal_lahir IS NOT NULL
        AND name_dob_candidate_nik_count = 0
      THEN 'NAME+DOB_FALLBACK'


      -- ------------------------------------------------------
      -- No NIK/name+DOB anchor, but name+phone is available.
      -- ------------------------------------------------------
      WHEN
        nama_norm IS NOT NULL
        AND no_hp_norm IS NOT NULL
        AND name_phone_candidate_nik_count = 0
      THEN 'NAME+PHONE_FALLBACK'


      -- ------------------------------------------------------
      -- Too ambiguous or too weak to safely merge.
      -- ------------------------------------------------------
      ELSE 'SOURCE_SPECIFIC_WEAK'

    END AS mother_match_method,


    -- ========================================================
    -- MATCH CONFIDENCE
    -- ========================================================
    CASE

      WHEN
        flag_nik_valid = TRUE
        AND nik_clean IS NOT NULL
      THEN 'HIGH'


      WHEN flag_fallback_identity_conflict = TRUE
      THEN 'LOW'


      WHEN name_dob_candidate_nik_count = 1
      THEN 'MEDIUM'


      WHEN name_phone_candidate_nik_count = 1
      THEN 'MEDIUM'


      WHEN
        nama_norm IS NOT NULL
        AND tanggal_lahir IS NOT NULL
        AND name_dob_candidate_nik_count = 0
      THEN 'MEDIUM'


      WHEN
        nama_norm IS NOT NULL
        AND no_hp_norm IS NOT NULL
        AND name_phone_candidate_nik_count = 0
      THEN 'MEDIUM'


      ELSE 'LOW'

    END AS mother_match_confidence

  FROM identity_qa q
),


-- ============================================================
-- 7. CREATE STABLE MOTHER KEY
--
-- NIK-linked records use exactly the same key whether the NIK
-- came directly from the source or was inherited through a
-- unique fallback match.
-- ============================================================
mother_keyed AS (
  SELECT
    r.*,


    CASE

      -- ------------------------------------------------------
      -- NIK-based mother
      -- ------------------------------------------------------
      WHEN resolved_nik IS NOT NULL
      THEN CONCAT(
        'EPMOM_',
        TO_HEX(
          SHA256(
            CONCAT(
              'NIK|',
              resolved_nik
            )
          )
        )
      )


      -- ------------------------------------------------------
      -- Unanchored name + DOB fallback
      -- ------------------------------------------------------
      WHEN mother_match_method = 'NAME+DOB_FALLBACK'
      THEN CONCAT(
        'EPMOM_',
        TO_HEX(
          SHA256(
            CONCAT(
              'NAME_DOB|',
              nama_norm,
              '|',
              CAST(
                tanggal_lahir
                AS STRING
              )
            )
          )
        )
      )


      -- ------------------------------------------------------
      -- Unanchored name + phone fallback
      -- ------------------------------------------------------
      WHEN mother_match_method = 'NAME+PHONE_FALLBACK'
      THEN CONCAT(
        'EPMOM_',
        TO_HEX(
          SHA256(
            CONCAT(
              'NAME_PHONE|',
              nama_norm,
              '|',
              no_hp_norm
            )
          )
        )
      )


      -- ------------------------------------------------------
      -- Ambiguous / weak identity:
      -- keep source record separate.
      -- ------------------------------------------------------
      ELSE CONCAT(
        'EPMOM_',
        TO_HEX(
          SHA256(
            CONCAT(
              'SOURCE|',
              epus_source_record_key
            )
          )
        )
      )

    END AS epus_mother_key,


    -- --------------------------------------------------------
    -- Useful explanation of what actually anchors this key
    -- --------------------------------------------------------
    CASE

      WHEN resolved_nik IS NOT NULL
      THEN 'NIK'

      WHEN mother_match_method = 'NAME+DOB_FALLBACK'
      THEN 'NAME+DOB'

      WHEN mother_match_method = 'NAME+PHONE_FALLBACK'
      THEN 'NAME+PHONE'

      ELSE 'SOURCE_RECORD'

    END AS mother_key_basis

  FROM resolved r
),


-- ============================================================
-- 8. MOTHER-LEVEL SUMMARY
--
-- These fields are joined back onto every event.
-- They are useful for QA and for the next pregnancy layer.
-- ============================================================
mother_summary AS (
  SELECT
    epus_mother_key,


    COUNT(*)
      AS mother_source_record_count,


    COUNT(
      DISTINCT source_table
    ) AS mother_source_table_count,


    COUNT(
      DISTINCT event_type
    ) AS mother_event_type_count,


    MIN(event_date)
      AS mother_first_event_date,

    MAX(event_date)
      AS mother_latest_event_date,


    COUNTIF(
      event_type = 'ANC'
    ) AS mother_anc_record_count,


    COUNTIF(
      event_type = 'DELIVERY'
    ) AS mother_delivery_record_count,


    COUNTIF(
      event_type = 'PNC'
    ) AS mother_pnc_record_count,


    LOGICAL_OR(
      flag_nik_valid = TRUE
    ) AS mother_has_direct_valid_nik_record,


    LOGICAL_OR(
      source_table = 'EPUS_ANC'
    ) AS mother_has_epus_anc,


    LOGICAL_OR(
      source_table = 'EPUS_KUNJUNGAN_IBU_HAMIL'
    ) AS mother_has_epus_kunjungan_ibu_hamil,


    LOGICAL_OR(
      source_table = 'EPUS_INC'
    ) AS mother_has_epus_inc,


    LOGICAL_OR(
      source_table = 'EPUS_PNC'
    ) AS mother_has_epus_pnc


  FROM mother_keyed

  GROUP BY
    epus_mother_key
),


-- ============================================================
-- 9. FINAL
-- ============================================================
final AS (
  SELECT
    m.*,

    s.mother_source_record_count,
    s.mother_source_table_count,
    s.mother_event_type_count,

    s.mother_first_event_date,
    s.mother_latest_event_date,

    s.mother_anc_record_count,
    s.mother_delivery_record_count,
    s.mother_pnc_record_count,

    s.mother_has_direct_valid_nik_record,

    s.mother_has_epus_anc,
    s.mother_has_epus_kunjungan_ibu_hamil,
    s.mother_has_epus_inc,
    s.mother_has_epus_pnc

  FROM mother_keyed m

  LEFT JOIN mother_summary s
    USING (epus_mother_key)
)


SELECT
  *
FROM final;