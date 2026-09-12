-- ============================================================================
-- PURBALINGGA
-- STAGE 08 V3.3.1
-- BUILD VALIDATED OUTCOME EVIDENCE + FINAL PREGNANCY MONITORING
--
-- INPUTS
--   t_pregnancy_episode_spine_v3_3
--   t_delivery_source_records_v3_3
--   t_delivery_event_canonical_post_anc_v3_3
--   raw_data.epus_anc
--   raw_data.epus_laporan_pelayanan_pasien_update
--
-- OUTPUTS
--   t_pregnancy_usg_dating_v3_3
--   t_outcome_evidence_source_v3_3
--   t_outcome_evidence_link_candidates_v3_3
--   t_outcome_evidence_link_v3_3
--   t_pregnancy_monitoring_integrated_v3_3
--
-- FINAL GRAIN
--   1 ROW = 1 CANONICAL PREGNANCY
--
-- FINAL STATUS PRECEDENCE
--
--   1. DELIVERED
--   2. ABORTUS
--   3. DELIVERED_DATE_UNKNOWN
--   4. DATE_UNKNOWN
--   5. MISSING_BIRTH
--   6. ACTIVE_PREGNANCY
--
-- IMPORTANT V3.3.1 CHANGE
--
-- SIGIZI IBU_NIFAS:
--
--   tgl_abortus alone is NOT sufficient to confirm current abortion.
--
--   Confirm abortion only if:
--       status explicitly indicates Abortus / Keguguran / Miscarriage.
--
--   Rows containing tgl_abortus but no explicit abortion status:
--       retained in t_outcome_evidence_source_v3_3
--       flagged as unconfirmed
--       excluded from pregnancy-outcome determination.
--
-- HPL TODAY IS NOT OVERDUE:
--       expected_delivery_date < analysis_date
--
-- PHONE ENRICHMENT:
--
--   raw_data.epus_laporan_pelayanan_pasien_update is linked only by trusted
--   NIK after canonical pregnancy creation. It fills missing phone numbers
--   and does not create, merge, or rematch pregnancy episodes.
-- ============================================================================


-- ============================================================================
-- PARAMETERS
-- ============================================================================

DECLARE analysis_date DATE
  DEFAULT CURRENT_DATE('Asia/Jakarta');

DECLARE monitoring_start_date DATE
  DEFAULT DATE '2025-01-01';

DECLARE plausible_pregnancy_floor DATE
  DEFAULT DATE '2018-01-01';

DECLARE dating_match_days INT64
  DEFAULT 30;

DECLARE strong_dating_match_days INT64
  DEFAULT 14;


-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

CREATE TEMP FUNCTION clean_raw(s STRING)
RETURNS STRING
AS (
  CASE

    WHEN s IS NULL
      THEN NULL

    WHEN LOWER(TRIM(s)) IN (
      '',
      '-',
      '--',
      'nan',
      'null',
      'none',
      'n/a',
      'na'
    )
      THEN NULL

    ELSE TRIM(s)

  END
);


CREATE TEMP FUNCTION norm_text(s STRING)
RETURNS STRING
AS (
  NULLIF(
    REGEXP_REPLACE(
      REGEXP_REPLACE(
        UPPER(
          TRIM(
            COALESCE(
              clean_raw(s),
              ''
            )
          )
        ),
        r'[^A-Z0-9 ]',
        ' '
      ),
      r'\s+',
      ' '
    ),
    ''
  )
);


CREATE TEMP FUNCTION compact_name(s STRING)
RETURNS STRING
AS (
  NULLIF(
    REGEXP_REPLACE(
      COALESCE(
        norm_text(s),
        ''
      ),
      r'[^A-Z0-9]',
      ''
    ),
    ''
  )
);


CREATE TEMP FUNCTION clean_nik(s STRING)
RETURNS STRING
AS (
  CASE

    WHEN LENGTH(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          TRIM(
            COALESCE(
              clean_raw(s),
              ''
            )
          ),
          r'\.0+$',
          ''
        ),
        r'[^0-9]',
        ''
      )
    ) = 16

    AND REGEXP_REPLACE(
      REGEXP_REPLACE(
        TRIM(
          COALESCE(
            clean_raw(s),
            ''
          )
        ),
        r'\.0+$',
        ''
      ),
      r'[^0-9]',
      ''
    ) NOT IN (
      '0000000000000000',
      '9999999999999999'
    )

    THEN REGEXP_REPLACE(
      REGEXP_REPLACE(
        TRIM(
          COALESCE(
            clean_raw(s),
            ''
          )
        ),
        r'\.0+$',
        ''
      ),
      r'[^0-9]',
      ''
    )

  END
);


CREATE TEMP FUNCTION clean_phone(s STRING)
RETURNS STRING
AS (
  NULLIF(
    REGEXP_REPLACE(
      COALESCE(
        clean_raw(s),
        ''
      ),
      r'[^0-9]',
      ''
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


CREATE TEMP FUNCTION parse_date_any(s STRING)
RETURNS DATE
AS (
  CASE

    WHEN clean_raw(s) IS NULL
      THEN NULL

    ELSE COALESCE(

      SAFE.PARSE_DATE(
        '%Y-%m-%d',
        SUBSTR(
          clean_raw(s),
          1,
          10
        )
      ),

      SAFE.PARSE_DATE(
        '%Y/%m/%d',
        SUBSTR(
          clean_raw(s),
          1,
          10
        )
      ),

      SAFE.PARSE_DATE(
        '%d/%m/%Y',
        clean_raw(s)
      ),

      SAFE.PARSE_DATE(
        '%d-%m-%Y',
        clean_raw(s)
      ),

      SAFE.PARSE_DATE(
        '%d.%m.%Y',
        clean_raw(s)
      ),

      SAFE_CAST(
        clean_raw(s)
        AS DATE
      ),

      CASE

        WHEN SAFE_CAST(
          clean_raw(s)
          AS INT64
        ) BETWEEN 20000 AND 70000

        THEN DATE_ADD(
          DATE '1899-12-30',
          INTERVAL SAFE_CAST(
            clean_raw(s)
            AS INT64
          ) DAY
        )

      END

    )

  END
);


CREATE TEMP FUNCTION parse_ga_weeks(s STRING)
RETURNS FLOAT64
AS (
  CASE

    WHEN SAFE_CAST(
      REGEXP_EXTRACT(
        REPLACE(
          COALESCE(
            clean_raw(s),
            ''
          ),
          ',',
          '.'
        ),
        r'([0-9]+(?:\.[0-9]+)?)'
      )
      AS FLOAT64
    ) BETWEEN 4 AND 42

    THEN SAFE_CAST(
      REGEXP_EXTRACT(
        REPLACE(
          COALESCE(
            clean_raw(s),
            ''
          ),
          ',',
          '.'
        ),
        r'([0-9]+(?:\.[0-9]+)?)'
      )
      AS FLOAT64
    )

  END
);


-- ============================================================================
-- DROP DOWNSTREAM TABLES
-- ============================================================================

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_usg_dating_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_source_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_link_candidates_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_link_v3_3`;

DROP TABLE IF EXISTS
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_monitoring_integrated_v3_3`;


-- ############################################################################
-- 08A
-- EPUS USG DATING
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_usg_dating_v3_3`

CLUSTER BY
  pregnancy_episode_id,
  nik_clean

AS

WITH raw_usg AS (

  SELECT
    TO_JSON_STRING(t) AS j

  FROM
    `stellar-orb-451904-d9.raw_data.epus_anc` t
),


parsed AS (

  SELECT

    COALESCE(

      clean_raw(
        JSON_VALUE(
          j,
          '$.uuid'
        )
      ),

      clean_raw(
        JSON_VALUE(
          j,
          '$.hash_code'
        )
      ),

      CAST(
        FARM_FINGERPRINT(j)
        AS STRING
      )

    ) AS usg_record_id,


    clean_nik(
      COALESCE(
        JSON_VALUE(
          j,
          '$.nik'
        ),
        JSON_VALUE(
          j,
          '$.nik_clean'
        )
      )
    ) AS nik_clean,


    COALESCE(

      clean_raw(
        JSON_VALUE(
          j,
          '$.nama_pasien'
        )
      ),

      clean_raw(
        JSON_VALUE(
          j,
          '$.nama_ibu'
        )
      )

    ) AS nama_ibu,


    compact_name(
      COALESCE(
        JSON_VALUE(
          j,
          '$.nama_pasien'
        ),
        JSON_VALUE(
          j,
          '$.nama_ibu'
        )
      )
    ) AS nama_compact,


    parse_date_any(
      COALESCE(
        JSON_VALUE(
          j,
          '$.tanggal_lahir'
        ),
        JSON_VALUE(
          j,
          '$.tanggal_lahir_date'
        )
      )
    ) AS tanggal_lahir_ibu,


    parse_date_any(
      COALESCE(
        JSON_VALUE(
          j,
          '$.tanggal_antenatal'
        ),
        JSON_VALUE(
          j,
          '$.tanggal_antenatal_date'
        )
      )
    ) AS usg_date,


    parse_ga_weeks(
      JSON_VALUE(
        j,
        '$.usg_usia_kehamilan'
      )
    ) AS usg_ga_weeks,


    parse_date_any(
      JSON_VALUE(
        j,
        '$.usg_perkiraan_lahir'
      )
    ) AS usg_recorded_hpl_date,


    clean_raw(
      JSON_VALUE(
        j,
        '$.puskesmas_name'
      )
    ) AS puskesmas_raw,


    j AS source_json

  FROM raw_usg
),


dated AS (

  SELECT
    *,

    CASE

      WHEN usg_date IS NOT NULL
       AND usg_ga_weeks BETWEEN 4 AND 42

      THEN DATE_ADD(
        usg_date,

        INTERVAL (
          280
          - CAST(
              ROUND(
                usg_ga_weeks * 7
              )
              AS INT64
            )
        ) DAY
      )

    END AS hpl_from_usg_ga_date,


    CASE

      WHEN usg_ga_weeks BETWEEN 4 AND 14
        THEN 1

      WHEN usg_ga_weeks > 14
       AND usg_ga_weeks <= 22
        THEN 2

      WHEN usg_ga_weeks > 22
       AND usg_ga_weeks <= 42
        THEN 3

      WHEN usg_recorded_hpl_date IS NOT NULL
        THEN 4

      ELSE 9

    END AS usg_quality_priority,


    CASE

      WHEN usg_ga_weeks BETWEEN 4 AND 14
        THEN 'EARLY_USG_LE_14W'

      WHEN usg_ga_weeks > 14
       AND usg_ga_weeks <= 22
        THEN 'USG_14_22W'

      WHEN usg_ga_weeks > 22
       AND usg_ga_weeks <= 42
        THEN 'LATE_USG_GT_22W'

      WHEN usg_recorded_hpl_date IS NOT NULL
        THEN 'RECORDED_USG_EDD_GA_UNKNOWN'

      ELSE 'NO_USABLE_USG_DATING'

    END AS usg_dating_quality

  FROM parsed
),


usable AS (

  SELECT *

  FROM dated

  WHERE
    usg_date IS NOT NULL

    AND (
         hpl_from_usg_ga_date IS NOT NULL
      OR usg_recorded_hpl_date IS NOT NULL
    )
),


candidate_blocks AS (

  -- --------------------------------------------------------------------------
  -- Trusted NIK
  -- --------------------------------------------------------------------------

  SELECT

    u.usg_record_id,

    p.pregnancy_episode_id,

    'NIK+VISIT_WINDOW'
      AS usg_match_method,

    1
      AS usg_match_priority,

    ABS(
      DATE_DIFF(
        u.usg_date,
        COALESCE(
          p.pregnancy_anchor_date,
          p.hpht_date
        ),
        DAY
      )
    ) AS anchor_difference_days

  FROM usable u

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3` p

    ON u.nik_clean = p.nik_clean

  WHERE
    nik_is_trusted(
      u.nik_clean
    )

    AND nik_is_trusted(
      p.nik_clean
    )

    AND COALESCE(
      p.pregnancy_anchor_date,
      p.hpht_date
    ) IS NOT NULL

    AND u.usg_date BETWEEN

      DATE_SUB(
        COALESCE(
          p.pregnancy_anchor_date,
          p.hpht_date
        ),
        INTERVAL 30 DAY
      )

      AND

      DATE_ADD(
        COALESCE(
          p.pregnancy_anchor_date,
          p.hpht_date
        ),
        INTERVAL 300 DAY
      )


  UNION ALL


  -- --------------------------------------------------------------------------
  -- Name + DOB
  -- --------------------------------------------------------------------------

  SELECT

    u.usg_record_id,

    p.pregnancy_episode_id,

    'NAME+DOB+VISIT_WINDOW'
      AS usg_match_method,

    2
      AS usg_match_priority,

    ABS(
      DATE_DIFF(
        u.usg_date,
        COALESCE(
          p.pregnancy_anchor_date,
          p.hpht_date
        ),
        DAY
      )
    ) AS anchor_difference_days

  FROM usable u

  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3` p

    ON u.nama_compact
       = compact_name(
           p.nama_ibu
         )

   AND u.tanggal_lahir_ibu
       = p.tanggal_lahir_ibu

  WHERE
    u.nama_compact IS NOT NULL

    AND u.tanggal_lahir_ibu IS NOT NULL

    AND COALESCE(
      p.pregnancy_anchor_date,
      p.hpht_date
    ) IS NOT NULL

    AND NOT (
      nik_is_trusted(
        u.nik_clean
      )

      AND nik_is_trusted(
        p.nik_clean
      )

      AND u.nik_clean
          != p.nik_clean
    )

    AND u.usg_date BETWEEN

      DATE_SUB(
        COALESCE(
          p.pregnancy_anchor_date,
          p.hpht_date
        ),
        INTERVAL 30 DAY
      )

      AND

      DATE_ADD(
        COALESCE(
          p.pregnancy_anchor_date,
          p.hpht_date
        ),
        INTERVAL 300 DAY
      )
),


distinct_candidates AS (

  SELECT

    usg_record_id,

    pregnancy_episode_id,

    MIN(
      usg_match_priority
    ) AS usg_match_priority,


    ARRAY_AGG(
      usg_match_method
      ORDER BY usg_match_priority
      LIMIT 1
    )[SAFE_OFFSET(0)]
      AS usg_match_method,


    MIN(
      anchor_difference_days
    ) AS anchor_difference_days

  FROM candidate_blocks

  GROUP BY
    usg_record_id,
    pregnancy_episode_id
),


candidate_ranked AS (

  SELECT
    *,

    DENSE_RANK() OVER (

      PARTITION BY usg_record_id

      ORDER BY
        usg_match_priority,
        anchor_difference_days

    ) AS candidate_rank

  FROM distinct_candidates
),


best_candidate_count AS (

  SELECT

    usg_record_id,

    COUNTIF(
      candidate_rank = 1
    ) AS best_candidate_count

  FROM candidate_ranked

  GROUP BY usg_record_id
),


assigned AS (

  SELECT
    r.*

  FROM candidate_ranked r

  JOIN best_candidate_count b
    USING (usg_record_id)

  WHERE
    r.candidate_rank = 1
    AND b.best_candidate_count = 1
),


pregnancy_ranked AS (

  SELECT

    a.pregnancy_episode_id,

    u.*,

    a.usg_match_method,

    a.usg_match_priority,

    a.anchor_difference_days,


    ROW_NUMBER() OVER (

      PARTITION BY a.pregnancy_episode_id

      ORDER BY
        u.usg_quality_priority,
        u.usg_date,
        u.usg_record_id

    ) AS pregnancy_usg_rank

  FROM assigned a

  JOIN usable u
    USING (usg_record_id)
)


SELECT

  pregnancy_episode_id,

  nik_clean,

  usg_record_id,

  usg_match_method,

  usg_match_priority,

  anchor_difference_days,

  usg_date,

  usg_ga_weeks,


  CAST(
    ROUND(
      usg_ga_weeks * 7
    )
    AS INT64
  ) AS usg_ga_days,


  usg_recorded_hpl_date,

  hpl_from_usg_ga_date,


  COALESCE(
    hpl_from_usg_ga_date,
    usg_recorded_hpl_date
  ) AS hpl_from_usg_date,


  usg_dating_quality,

  usg_quality_priority

FROM pregnancy_ranked

WHERE pregnancy_usg_rank = 1;


-- ############################################################################
-- 08A2
-- VALIDATE OUTCOME-EVIDENCE SOURCE
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_source_v3_3`

CLUSTER BY
  event_type,
  source_system,
  source_table,
  nik_clean

AS

WITH x AS (

  SELECT

    s.*,


    COALESCE(

      NULLIF(
        JSON_VALUE(
          s.source_json,
          '$.outcome_raw'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          s.source_json,
          '$.pregnancy_outcome_raw'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          s.source_json,
          '$.status'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          JSON_VALUE(
            s.source_json,
            '$.source_json'
          ),
          '$.status'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          JSON_VALUE(
            s.source_json,
            '$.source_json'
          ),
          '$.outcome_status_raw'
        ),
        ''
      )

    ) AS outcome_status_validation_raw


  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_source_records_v3_3` s

  WHERE s.event_type IN (
    'ABORTION',
    'DELIVERY_DATE_UNKNOWN',
    'CONFLICT_DELIVERY_ABORTION'
  )
),


classified AS (

  SELECT
    *,


    -- ------------------------------------------------------------------------
    -- CONFIRMED ABORTION FLAG
    -- ------------------------------------------------------------------------

    CASE

      -- SIGIZI IBU_NIFAS requires explicit abortion status.
      WHEN source_system = 'SIGIZI'
       AND source_table = 'IBU_NIFAS'
       AND event_type = 'ABORTION'

      THEN REGEXP_CONTAINS(
        UPPER(
          COALESCE(
            outcome_status_validation_raw,
            ''
          )
        ),
        r'ABORT|KEGUGUR|MISCARR'
      )


      -- Birth Confirmation abortion rows are already based on explicit
      -- miscarriage / abortion outcome reporting.
      WHEN source_system = 'BIRTH_CONFIRMATION'
       AND event_type = 'ABORTION'

        THEN TRUE


      -- Other standardized abortion source
      WHEN event_type = 'ABORTION'

        THEN TRUE


      ELSE FALSE

    END AS confirmed_abortion_evidence_flag,


    -- ------------------------------------------------------------------------
    -- VALIDATION CLASS
    -- ------------------------------------------------------------------------

    CASE

      WHEN event_type = 'DELIVERY_DATE_UNKNOWN'

        THEN 'DELIVERY_DATE_UNKNOWN_EVIDENCE'


      WHEN event_type = 'CONFLICT_DELIVERY_ABORTION'

        THEN 'DELIVERY_ABORTION_CONFLICT_QA_ONLY'


      WHEN source_system = 'SIGIZI'
       AND source_table = 'IBU_NIFAS'
       AND event_type = 'ABORTION'

       AND REGEXP_CONTAINS(
         UPPER(
           COALESCE(
             outcome_status_validation_raw,
             ''
           )
         ),
         r'ABORT|KEGUGUR|MISCARR'
       )

        THEN 'IBU_NIFAS_EXPLICIT_ABORTION_STATUS'


      WHEN source_system = 'SIGIZI'
       AND source_table = 'IBU_NIFAS'
       AND event_type = 'ABORTION'

        THEN 'IBU_NIFAS_ABORTION_DATE_ONLY_UNCONFIRMED'


      WHEN event_type = 'ABORTION'

        THEN 'OTHER_CONFIRMED_ABORTION_SOURCE'


      ELSE 'OTHER'

    END AS outcome_evidence_validation_class


  FROM x
)


SELECT *
FROM classified;


-- ############################################################################
-- 08B
-- LINK VALIDATED OUTCOME EVIDENCE TO CANONICAL PREGNANCIES
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_link_candidates_v3_3`

CLUSTER BY
  source_record_instance_key,
  pregnancy_episode_id

AS

WITH pregnancies AS (

  SELECT

    p.*,

    u.usg_date,

    u.usg_ga_weeks,

    u.hpl_from_usg_ga_date,

    u.hpl_from_usg_date,

    u.usg_dating_quality,


    -- ------------------------------------------------------------------------
    -- EXPECTED DELIVERY DATE FOR LINKAGE
    -- ------------------------------------------------------------------------

    COALESCE(

      p.hpl_epus,

      p.hpl_sigizi,

      p.hpl_recorded_date,

      CASE

        WHEN u.usg_ga_weeks
          BETWEEN 4 AND 14

        THEN u.hpl_from_usg_ga_date

      END,

      p.hpl_from_epus_hpht,

      p.hpl_from_sigizi_hpht,

      p.hpl_from_hpht_date,

      CASE

        WHEN p.hpht_date IS NOT NULL

        THEN DATE_ADD(
          p.hpht_date,
          INTERVAL 280 DAY
        )

      END

    ) AS expected_delivery_date_link,


    COALESCE(

      p.pregnancy_anchor_date,

      p.hpht_date,

      DATE_SUB(
        COALESCE(
          p.hpl_epus,
          p.hpl_sigizi,
          p.hpl_recorded_date
        ),
        INTERVAL 280 DAY
      )

    ) AS pregnancy_anchor_date_link


  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3` p

  LEFT JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_usg_dating_v3_3` u

    USING (pregnancy_episode_id)
),


-- ============================================================================
-- ONLY ELIGIBLE OUTCOME EVIDENCE
-- ============================================================================

evidence AS (

  SELECT *

  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_source_v3_3`

  WHERE

       event_type = 'DELIVERY_DATE_UNKNOWN'

    OR (
         event_type = 'ABORTION'

         AND confirmed_abortion_evidence_flag = TRUE
       )

    OR event_type = 'CONFLICT_DELIVERY_ABORTION'
),


candidate_blocks AS (

  -- --------------------------------------------------------------------------
  -- NIK BLOCK
  -- --------------------------------------------------------------------------

  SELECT
    e.source_record_instance_key,
    p.pregnancy_episode_id

  FROM evidence e

  JOIN pregnancies p
    ON e.nik_clean = p.nik_clean

  WHERE
    nik_is_trusted(
      e.nik_clean
    )

    AND nik_is_trusted(
      p.nik_clean
    )


  UNION DISTINCT


  -- --------------------------------------------------------------------------
  -- NAME BLOCK
  -- --------------------------------------------------------------------------

  SELECT
    e.source_record_instance_key,
    p.pregnancy_episode_id

  FROM evidence e

  JOIN pregnancies p

    ON compact_name(
         e.nama_ibu
       )
       =
       compact_name(
         p.nama_ibu
       )

  WHERE
    compact_name(
      e.nama_ibu
    ) IS NOT NULL

    AND compact_name(
      p.nama_ibu
    ) IS NOT NULL


  UNION DISTINCT


  -- --------------------------------------------------------------------------
  -- PHONE BLOCK
  -- --------------------------------------------------------------------------

  SELECT
    e.source_record_instance_key,
    p.pregnancy_episode_id

  FROM evidence e

  JOIN pregnancies p

    ON e.no_hp_clean
       = p.no_hp_clean

  WHERE
    e.no_hp_clean IS NOT NULL

    AND p.no_hp_clean IS NOT NULL

    AND LENGTH(
      e.no_hp_clean
    ) >= 8
),


pair_features_1 AS (

  SELECT

    x.source_record_instance_key,

    x.pregnancy_episode_id,


    -- ------------------------------------------------------------------------
    -- EVIDENCE
    -- ------------------------------------------------------------------------

    e.event_type,

    e.source_system,

    e.source_table,

    e.source_priority,

    e.confirmed_abortion_evidence_flag,

    e.outcome_evidence_validation_class,

    e.outcome_status_validation_raw,


    e.nik_clean
      AS evidence_nik,

    e.nama_ibu
      AS evidence_name,

    e.tanggal_lahir_ibu
      AS evidence_dob,

    e.no_hp_clean
      AS evidence_phone,

    e.hpht_date
      AS evidence_hpht,

    e.hpl_date
      AS evidence_hpl,

    e.abortion_date,

    e.pregnancy_outcome_norm
      AS evidence_outcome,

    e.puskesmas_norm
      AS evidence_puskesmas,


    -- ------------------------------------------------------------------------
    -- PREGNANCY
    -- ------------------------------------------------------------------------

    p.pregnancy_source_combination,

    p.nik_clean
      AS pregnancy_nik,

    p.nama_ibu
      AS pregnancy_name,

    p.tanggal_lahir_ibu
      AS pregnancy_dob,

    p.no_hp_clean
      AS pregnancy_phone,

    p.hpht_date
      AS pregnancy_hpht,

    p.hpl_recorded_date
      AS pregnancy_hpl,

    p.puskesmas_norm
      AS pregnancy_puskesmas,

    p.pregnancy_anchor_date_link,

    p.expected_delivery_date_link,


    -- ------------------------------------------------------------------------
    -- IDENTITY FEATURES
    -- ------------------------------------------------------------------------

    (
      nik_is_trusted(
        e.nik_clean
      )

      AND nik_is_trusted(
        p.nik_clean
      )

      AND e.nik_clean
          = p.nik_clean

    ) AS trusted_nik_exact,


    (
      nik_is_trusted(
        e.nik_clean
      )

      AND nik_is_trusted(
        p.nik_clean
      )

      AND e.nik_clean
          != p.nik_clean

    ) AS trusted_nik_conflict,


    (
      compact_name(
        e.nama_ibu
      ) IS NOT NULL

      AND compact_name(
        p.nama_ibu
      ) IS NOT NULL

      AND compact_name(
        e.nama_ibu
      )
      =
      compact_name(
        p.nama_ibu
      )

    ) AS name_match,


    (
      compact_name(
        e.nama_ibu
      ) IS NOT NULL

      AND compact_name(
        p.nama_ibu
      ) IS NOT NULL

      AND compact_name(
        e.nama_ibu
      )
      !=
      compact_name(
        p.nama_ibu
      )

    ) AS name_conflict,


    (
      e.tanggal_lahir_ibu IS NOT NULL

      AND p.tanggal_lahir_ibu IS NOT NULL

      AND e.tanggal_lahir_ibu
          = p.tanggal_lahir_ibu

    ) AS dob_match,


    (
      e.tanggal_lahir_ibu IS NOT NULL

      AND p.tanggal_lahir_ibu IS NOT NULL

      AND e.tanggal_lahir_ibu
          != p.tanggal_lahir_ibu

    ) AS dob_conflict,


    (
      e.no_hp_clean IS NOT NULL

      AND p.no_hp_clean IS NOT NULL

      AND e.no_hp_clean
          = p.no_hp_clean

    ) AS phone_match,


    (
      e.puskesmas_norm IS NOT NULL

      AND p.puskesmas_norm IS NOT NULL

      AND e.puskesmas_norm
          = p.puskesmas_norm

    ) AS puskesmas_match,


    -- ------------------------------------------------------------------------
    -- PREGNANCY DATING
    -- ------------------------------------------------------------------------

    CASE

      WHEN e.hpht_date IS NOT NULL
       AND p.hpht_date IS NOT NULL

      THEN ABS(
        DATE_DIFF(
          e.hpht_date,
          p.hpht_date,
          DAY
        )
      )

    END AS hpht_difference_days,


    CASE

      WHEN e.hpl_date IS NOT NULL
       AND p.hpl_recorded_date IS NOT NULL

      THEN ABS(
        DATE_DIFF(
          e.hpl_date,
          p.hpl_recorded_date,
          DAY
        )
      )

    END AS hpl_difference_days,


    CASE

      WHEN e.abortion_date IS NOT NULL
       AND p.pregnancy_anchor_date_link IS NOT NULL

      THEN DATE_DIFF(
        e.abortion_date,
        p.pregnancy_anchor_date_link,
        DAY
      )

    END AS abortion_from_anchor_days,


    -- ------------------------------------------------------------------------
    -- ABORTION TEMPORAL PLAUSIBILITY
    -- ------------------------------------------------------------------------

    CASE

      WHEN e.abortion_date IS NOT NULL

       AND p.pregnancy_anchor_date_link IS NOT NULL

      THEN e.abortion_date BETWEEN

        DATE_SUB(
          p.pregnancy_anchor_date_link,
          INTERVAL 30 DAY
        )

        AND

        COALESCE(

          DATE_ADD(
            p.expected_delivery_date_link,
            INTERVAL 28 DAY
          ),

          DATE_ADD(
            p.pregnancy_anchor_date_link,
            INTERVAL 300 DAY
          )

        )

      ELSE FALSE

    END AS abortion_window_plausible


  FROM candidate_blocks x

  JOIN evidence e
    USING (source_record_instance_key)

  JOIN pregnancies p
    USING (pregnancy_episode_id)
),


pair_features_2 AS (

  SELECT
    *,


    COUNTIF(
      trusted_nik_exact
    ) OVER (
      PARTITION BY source_record_instance_key
    ) AS exact_nik_candidate_count,


    (
      name_conflict
      AND dob_conflict
    ) AS strong_identity_conflict,


    (
        CAST(
          dob_match
          AS INT64
        )

      + CAST(
          phone_match
          AS INT64
        )

      + CAST(
          puskesmas_match
          AS INT64
        )

      + CAST(
          COALESCE(
            hpht_difference_days
              <= strong_dating_match_days,
            FALSE
          )
          AS INT64
        )

      + CAST(
          COALESCE(
            hpl_difference_days
              <= strong_dating_match_days,
            FALSE
          )
          AS INT64
        )

      + CAST(
          abortion_window_plausible
          AS INT64
        )

    ) AS corroborator_count


  FROM pair_features_1
),


classified AS (

  SELECT
    *,


    CASE

      -- ======================================================================
      -- 1. TRUSTED NIK + PREGNANCY DATING
      -- ======================================================================

      WHEN trusted_nik_exact

       AND NOT strong_identity_conflict

       AND (
            hpht_difference_days
              <= dating_match_days

         OR hpl_difference_days
              <= dating_match_days
       )

        THEN 'TRUSTED_NIK+PREGNANCY_DATING_30D'


      -- ======================================================================
      -- 2. TRUSTED NIK + ABORTION WINDOW
      -- ======================================================================

      WHEN trusted_nik_exact

       AND NOT strong_identity_conflict

       AND event_type IN (
         'ABORTION',
         'CONFLICT_DELIVERY_ABORTION'
       )

       AND abortion_window_plausible

        THEN 'TRUSTED_NIK+ABORTION_WINDOW'


      -- ======================================================================
      -- 3. UNIQUE TRUSTED NIK
      -- ======================================================================

      WHEN trusted_nik_exact

       AND exact_nik_candidate_count = 1

       AND NOT strong_identity_conflict

       AND (
            NOT name_conflict

         OR dob_match

         OR phone_match

         OR hpht_difference_days
              <= dating_match_days

         OR hpl_difference_days
              <= dating_match_days

         OR abortion_window_plausible
       )

        THEN 'UNIQUE_TRUSTED_NIK'


      -- ======================================================================
      -- 4. NAME + DOB + HPHT
      -- ======================================================================

      WHEN name_match

       AND dob_match

       AND hpht_difference_days
            <= dating_match_days

       AND NOT trusted_nik_conflict

        THEN 'NAME+DOB+HPHT_30D'


      -- ======================================================================
      -- 5. NAME + DOB + HPL
      -- ======================================================================

      WHEN name_match

       AND dob_match

       AND hpl_difference_days
            <= dating_match_days

       AND NOT trusted_nik_conflict

        THEN 'NAME+DOB+HPL_30D'


      -- ======================================================================
      -- 6. NAME + HPHT
      -- ======================================================================

      WHEN name_match

       AND hpht_difference_days
            <= strong_dating_match_days

       AND NOT trusted_nik_conflict

        THEN 'NAME+HPHT_14D'


      -- ======================================================================
      -- 7. NAME + HPL
      -- ======================================================================

      WHEN name_match

       AND hpl_difference_days
            <= strong_dating_match_days

       AND NOT trusted_nik_conflict

        THEN 'NAME+HPL_14D'


      -- ======================================================================
      -- 8. PHONE + DOB
      -- ======================================================================

      WHEN phone_match

       AND dob_match

       AND NOT trusted_nik_conflict

        THEN 'PHONE+DOB'


      -- ======================================================================
      -- 9. PHONE + PREGNANCY DATING
      -- ======================================================================

      WHEN phone_match

       AND (
            hpht_difference_days
              <= dating_match_days

         OR hpl_difference_days
              <= dating_match_days
       )

       AND NOT trusted_nik_conflict

        THEN 'PHONE+PREGNANCY_DATING_30D'


      ELSE NULL

    END AS evidence_match_method


  FROM pair_features_2
),


prioritized AS (

  SELECT
    *,


    CASE evidence_match_method

      WHEN 'TRUSTED_NIK+PREGNANCY_DATING_30D'
        THEN 1

      WHEN 'TRUSTED_NIK+ABORTION_WINDOW'
        THEN 2

      WHEN 'UNIQUE_TRUSTED_NIK'
        THEN 3

      WHEN 'NAME+DOB+HPHT_30D'
        THEN 4

      WHEN 'NAME+DOB+HPL_30D'
        THEN 5

      WHEN 'NAME+HPHT_14D'
        THEN 6

      WHEN 'NAME+HPL_14D'
        THEN 7

      WHEN 'PHONE+DOB'
        THEN 8

      WHEN 'PHONE+PREGNANCY_DATING_30D'
        THEN 9

    END AS evidence_match_priority,


    LEAST(

      COALESCE(
        hpht_difference_days,
        999999
      ),

      COALESCE(
        hpl_difference_days,
        999999
      )

    ) AS pregnancy_dating_difference_score


  FROM classified

  WHERE evidence_match_method IS NOT NULL
)


SELECT
  *,


  CASE

    WHEN evidence_match_priority <= 2
      THEN 'VERY_HIGH'

    WHEN evidence_match_priority <= 5
      THEN 'HIGH'

    ELSE 'MEDIUM'

  END AS evidence_match_confidence


FROM prioritized;


-- ############################################################################
-- 08C
-- CHOOSE UNIQUE BEST PREGNANCY FOR EACH OUTCOME-EVIDENCE RECORD
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_link_v3_3`

CLUSTER BY
  evidence_link_status,
  event_type,
  pregnancy_episode_id

AS

WITH ranked AS (

  SELECT
    c.*,


    DENSE_RANK() OVER (

      PARTITION BY source_record_instance_key

      ORDER BY
        evidence_match_priority,

        pregnancy_dating_difference_score,

        corroborator_count DESC

    ) AS candidate_rank


  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_link_candidates_v3_3` c
),


best AS (

  SELECT *

  FROM ranked

  WHERE candidate_rank = 1
),


best_summary AS (

  SELECT

    source_record_instance_key,

    COUNT(*) AS best_candidate_count,


    ANY_VALUE(
      pregnancy_episode_id
    ) AS pregnancy_episode_id,


    ANY_VALUE(
      pregnancy_source_combination
    ) AS pregnancy_source_combination,


    ANY_VALUE(
      evidence_match_method
    ) AS evidence_match_method,


    ANY_VALUE(
      evidence_match_priority
    ) AS evidence_match_priority,


    ANY_VALUE(
      evidence_match_confidence
    ) AS evidence_match_confidence,


    ANY_VALUE(
      corroborator_count
    ) AS corroborator_count,


    LOGICAL_OR(
      name_conflict
    ) AS name_conflict,


    LOGICAL_OR(
      dob_conflict
    ) AS dob_conflict


  FROM best

  GROUP BY source_record_instance_key
),


direct_nik AS (

  SELECT

    e.source_record_instance_key,


    COUNT(
      DISTINCT p.pregnancy_episode_id
    ) AS exact_nik_pregnancy_count


  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_source_v3_3` e


  LEFT JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3` p

    ON e.nik_clean = p.nik_clean

   AND nik_is_trusted(
         e.nik_clean
       )

   AND nik_is_trusted(
         p.nik_clean
       )


  WHERE

       e.event_type = 'DELIVERY_DATE_UNKNOWN'

    OR (
         e.event_type = 'ABORTION'

         AND e.confirmed_abortion_evidence_flag = TRUE
       )

    OR e.event_type = 'CONFLICT_DELIVERY_ABORTION'


  GROUP BY
    e.source_record_instance_key
)


SELECT

  e.source_record_instance_key,

  e.source_record_key,

  e.source_system,

  e.source_table,

  e.source_priority,

  e.event_type,

  e.confirmed_abortion_evidence_flag,

  e.outcome_evidence_validation_class,

  e.outcome_status_validation_raw,

  e.abortion_date,

  e.pregnancy_outcome_norm,

  e.nik_clean,

  e.nama_ibu,

  e.tanggal_lahir_ibu,

  e.no_hp_clean,

  e.hpht_date,

  e.hpl_date,

  e.puskesmas_norm,

  e.report_date,


  CASE

    WHEN b.best_candidate_count = 1
      THEN 'MATCHED'


    WHEN b.best_candidate_count > 1
      THEN 'AMBIGUOUS_PREGNANCY_MATCH'


    WHEN COALESCE(
      n.exact_nik_pregnancy_count,
      0
    ) > 1

      THEN 'UNRESOLVED_MULTIPLE_NIK_PREGNANCIES'


    WHEN COALESCE(
      n.exact_nik_pregnancy_count,
      0
    ) = 1

      THEN 'NIK_IDENTITY_OR_DATING_CONFLICT'


    ELSE 'NO_PREGNANCY_MATCH'

  END AS evidence_link_status,


  CASE

    WHEN b.best_candidate_count = 1

      THEN b.pregnancy_episode_id

  END AS pregnancy_episode_id,


  CASE

    WHEN b.best_candidate_count = 1

      THEN b.pregnancy_source_combination

  END AS pregnancy_source_combination,


  CASE

    WHEN b.best_candidate_count = 1

      THEN b.evidence_match_method

  END AS evidence_match_method,


  CASE

    WHEN b.best_candidate_count = 1

      THEN b.evidence_match_confidence

  END AS evidence_match_confidence,


  CASE

    WHEN b.best_candidate_count = 1

      THEN b.corroborator_count

  END AS evidence_link_corroborator_count,


  COALESCE(
    b.name_conflict,
    FALSE
  ) AS evidence_name_conflict_flag,


  COALESCE(
    b.dob_conflict,
    FALSE
  ) AS evidence_dob_conflict_flag,


  COALESCE(
    b.best_candidate_count,
    0
  ) AS best_candidate_count,


  COALESCE(
    n.exact_nik_pregnancy_count,
    0
  ) AS exact_nik_pregnancy_candidates


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_source_v3_3` e


LEFT JOIN best_summary b
  USING (source_record_instance_key)


LEFT JOIN direct_nik n
  USING (source_record_instance_key)


WHERE

     e.event_type = 'DELIVERY_DATE_UNKNOWN'

  OR (
       e.event_type = 'ABORTION'

       AND e.confirmed_abortion_evidence_flag = TRUE
     )

  OR e.event_type = 'CONFLICT_DELIVERY_ABORTION';


-- ############################################################################
-- 08D
-- FINAL PREGNANCY MONITORING TABLE
-- ############################################################################

CREATE OR REPLACE TABLE
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_monitoring_integrated_v3_3`

PARTITION BY expected_delivery_date

CLUSTER BY
  monitoring_status_all_history,
  pregnancy_source_combination,
  puskesmas_norm,
  pregnancy_episode_id

AS

WITH epus_patient_phone_ranked AS (

  -- ------------------------------------------------------------------------
  -- GENERAL ePUS PATIENT-REPORT PHONE ENRICHMENT
  --
  -- This source is not a pregnancy-membership source. It is used only to
  -- fill a missing phone after canonical pregnancy creation. Restricting the
  -- linkage to trusted NIK prevents general patient visits from creating or
  -- rematching pregnancy episodes.
  -- ------------------------------------------------------------------------

  SELECT

    clean_nik(nik) AS nik_clean,

    clean_phone(no_telp)
      AS epus_patient_no_hp_clean,

    NULLIF(
      TRIM(file_name),
      ''
    ) AS file_name,

    parse_date_any(file_date)
      AS file_date,

    SAFE_CAST(
      NULLIF(
        TRIM(ingestion_timestamp),
        ''
      )
      AS TIMESTAMP
    ) AS ingestion_timestamp,

    parse_date_any(tanggal_pemeriksaan)
      AS service_date,

    NULLIF(
      TRIM(uuid),
      ''
    ) AS source_uuid,

    NULLIF(
      TRIM(hash_code),
      ''
    ) AS source_hash_code,


    ROW_NUMBER() OVER (

      PARTITION BY clean_nik(nik)

      ORDER BY
        SAFE_CAST(
          NULLIF(
            TRIM(ingestion_timestamp),
            ''
          )
          AS TIMESTAMP
        ) DESC,

        parse_date_any(tanggal_pemeriksaan) DESC,

        parse_date_any(file_date) DESC,

        NULLIF(
          TRIM(file_name),
          ''
        ) DESC,

        NULLIF(
          TRIM(uuid),
          ''
        ) DESC,

        NULLIF(
          TRIM(hash_code),
          ''
        ) DESC

    ) AS phone_rank


  FROM
    `stellar-orb-451904-d9.raw_data.epus_laporan_pelayanan_pasien_update`


  WHERE
    nik_is_trusted(
      clean_nik(nik)
    )

    AND LENGTH(
      COALESCE(
        clean_phone(no_telp),
        ''
      )
    ) BETWEEN 8 AND 15

    AND clean_phone(no_telp) NOT IN (
      '00000000',
      '081111',
      '0810000',
      '081234567',
      '080000'
    )
),


epus_patient_phone AS (

  SELECT
    * EXCEPT (phone_rank)

  FROM epus_patient_phone_ranked

  WHERE phone_rank = 1
),


abortion_date_votes AS (

  SELECT

    pregnancy_episode_id,

    abortion_date,

    COUNT(*) AS supporting_records,

    COUNT(
      DISTINCT source_system
    ) AS supporting_systems,

    MIN(
      source_priority
    ) AS best_source_priority


  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_link_v3_3`


  WHERE
    evidence_link_status = 'MATCHED'

    AND event_type = 'ABORTION'

    AND confirmed_abortion_evidence_flag = TRUE

    AND abortion_date IS NOT NULL


  GROUP BY
    pregnancy_episode_id,
    abortion_date
),


abortion_date_ranked AS (

  SELECT
    *,


    ROW_NUMBER() OVER (

      PARTITION BY pregnancy_episode_id

      ORDER BY
        supporting_systems DESC,
        supporting_records DESC,
        best_source_priority ASC,
        abortion_date ASC

    ) AS abortion_date_rank


  FROM abortion_date_votes
),


abortion_agg AS (

  SELECT

    pregnancy_episode_id,


    COUNT(*) AS abortion_evidence_record_count,


    COUNT(
      DISTINCT source_system
    ) AS abortion_source_system_count,


    STRING_AGG(
      DISTINCT source_system,
      ' + '
      ORDER BY source_system
    ) AS abortion_source_combination,


    COUNT(
      DISTINCT abortion_date
    ) AS abortion_date_distinct_count,


    MIN(
      abortion_date
    ) AS abortion_date_min,


    MAX(
      abortion_date
    ) AS abortion_date_max,


    COUNTIF(
      evidence_name_conflict_flag
    ) AS abortion_name_conflict_records,


    COUNTIF(
      evidence_dob_conflict_flag
    ) AS abortion_dob_conflict_records,


    COUNTIF(
      source_system = 'SIGIZI'
    ) > 0 AS has_abortion_sigizi,


    COUNTIF(
      source_system = 'EPUS'
    ) > 0 AS has_abortion_epus,


    COUNTIF(
      source_system = 'BIRTH_CONFIRMATION'
    ) > 0 AS has_abortion_birth_confirmation


  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_link_v3_3`


  WHERE
    evidence_link_status = 'MATCHED'

    AND event_type = 'ABORTION'

    AND confirmed_abortion_evidence_flag = TRUE


  GROUP BY pregnancy_episode_id
),


abortion_final AS (

  SELECT

    a.*,

    d.abortion_date
      AS abortion_date


  FROM abortion_agg a


  LEFT JOIN abortion_date_ranked d

    ON a.pregnancy_episode_id
       = d.pregnancy_episode_id

   AND d.abortion_date_rank = 1
),


unknown_delivery_agg AS (

  SELECT

    pregnancy_episode_id,


    COUNT(*) AS delivery_date_unknown_evidence_count,


    COUNT(
      DISTINCT source_system
    ) AS delivery_date_unknown_source_count,


    STRING_AGG(
      DISTINCT source_system,
      ' + '
      ORDER BY source_system
    ) AS delivery_date_unknown_source_combination,


    COUNTIF(
      pregnancy_outcome_norm = 'LIVE_BIRTH'
    ) AS unknown_date_live_birth_evidence_count,


    COUNTIF(
      pregnancy_outcome_norm = 'STILLBIRTH'
    ) AS unknown_date_stillbirth_evidence_count,


    COUNTIF(
      pregnancy_outcome_norm = 'UNKNOWN'
    ) AS unknown_date_unknown_outcome_evidence_count,


    COUNTIF(
      source_system = 'SIGIZI'
    ) > 0 AS has_unknown_delivery_sigizi,


    COUNTIF(
      source_system = 'EPUS'
    ) > 0 AS has_unknown_delivery_epus,


    COUNTIF(
      source_system = 'SIMRS'
    ) > 0 AS has_unknown_delivery_simrs,


    COUNTIF(
      source_system = 'EKOHORT'
    ) > 0 AS has_unknown_delivery_ekohort,


    COUNTIF(
      source_system = 'BIRTH_CONFIRMATION'
    ) > 0 AS has_unknown_delivery_birth_confirmation,


    COUNTIF(
      evidence_name_conflict_flag
    ) AS unknown_delivery_name_conflict_records,


    COUNTIF(
      evidence_dob_conflict_flag
    ) AS unknown_delivery_dob_conflict_records


  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_link_v3_3`


  WHERE
    evidence_link_status = 'MATCHED'

    AND event_type = 'DELIVERY_DATE_UNKNOWN'


  GROUP BY pregnancy_episode_id
),


unknown_delivery_final AS (

  SELECT
    *,


    CASE

      WHEN unknown_date_live_birth_evidence_count > 0
       AND unknown_date_stillbirth_evidence_count > 0

        THEN 'MIXED_LIVE_STILLBIRTH'


      WHEN unknown_date_live_birth_evidence_count > 0

        THEN 'LIVE_BIRTH'


      WHEN unknown_date_stillbirth_evidence_count > 0

        THEN 'STILLBIRTH'


      ELSE 'UNKNOWN'

    END AS delivery_date_unknown_outcome_final


  FROM unknown_delivery_agg
),


conflict_agg AS (

  SELECT

    pregnancy_episode_id,


    COUNT(*) AS delivery_abortion_conflict_evidence_count,


    STRING_AGG(
      DISTINCT source_system,
      ' + '
      ORDER BY source_system
    ) AS delivery_abortion_conflict_source_combination


  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_link_v3_3`


  WHERE
    evidence_link_status = 'MATCHED'

    AND event_type = 'CONFLICT_DELIVERY_ABORTION'


  GROUP BY pregnancy_episode_id
),


-- ============================================================================
-- QA ONLY:
-- UNCONFIRMED IBU_NIFAS ABORTION-DATE RECORDS BY PREGNANCY
--
-- These do NOT determine final abortion status.
-- ============================================================================

unconfirmed_abortion_qa AS (

  SELECT

    p.pregnancy_episode_id,


    COUNT(*) AS unconfirmed_ibu_nifas_abortion_record_count,


    COUNT(
      DISTINCT e.abortion_date
    ) AS unconfirmed_ibu_nifas_abortion_date_count,


    MIN(
      e.abortion_date
    ) AS unconfirmed_ibu_nifas_abortion_date_min,


    MAX(
      e.abortion_date
    ) AS unconfirmed_ibu_nifas_abortion_date_max


  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_source_v3_3` e


  JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3` p

    ON e.nik_clean = p.nik_clean


  WHERE
    e.outcome_evidence_validation_class
      = 'IBU_NIFAS_ABORTION_DATE_ONLY_UNCONFIRMED'

    AND nik_is_trusted(
      e.nik_clean
    )

    AND nik_is_trusted(
      p.nik_clean
    )


    -- Avoid assigning an unconfirmed date field freely across
    -- multiple historical pregnancies for the same woman.
    AND (
         e.hpht_date IS NULL

      OR p.hpht_date IS NULL

      OR ABS(
           DATE_DIFF(
             e.hpht_date,
             p.hpht_date,
             DAY
           )
         ) <= dating_match_days
    )


  GROUP BY p.pregnancy_episode_id
),


pregnancy_base AS (

  SELECT

    p.pregnancy_episode_id,

    p.pregnancy_source_combination,

    p.nik_clean,

    p.nama_ibu,

    p.nama_norm,

    p.nama_core_norm,

    p.tanggal_lahir_ibu,

    COALESCE(
      p.no_hp_clean,
      eph.epus_patient_no_hp_clean
    ) AS no_hp_clean,


    p.no_hp_clean
      AS pregnancy_source_no_hp_clean,

    eph.epus_patient_no_hp_clean
      AS epus_patient_report_no_hp_clean,


    CASE

      WHEN p.no_hp_clean IS NOT NULL
        THEN 'PREGNANCY_SOURCE'

      WHEN eph.epus_patient_no_hp_clean IS NOT NULL
        THEN 'EPUS_LAPORAN_PELAYANAN_PASIEN_UPDATE'

      ELSE 'MISSING'

    END AS no_hp_selected_source,


    eph.file_name
      AS no_hp_source_file_name,

    eph.file_date
      AS no_hp_source_file_date,

    eph.ingestion_timestamp
      AS no_hp_source_ingestion_timestamp,

    eph.service_date
      AS no_hp_source_service_date,

    eph.source_uuid
      AS no_hp_source_uuid,

    eph.source_hash_code
      AS no_hp_source_hash_code,


    p.puskesmas,

    p.puskesmas_norm,

    p.desa,

    p.desa_norm,

    p.posyandu,


    -- posyandu_norm does not exist in final pregnancy spine;
    -- derive here.
    norm_text(
      p.posyandu
    ) AS posyandu_norm,


    p.hpht_date,

    p.hpl_recorded_date,

    p.hpl_epus,

    p.hpl_sigizi,

    p.hpl_from_epus_hpht,

    p.hpl_from_sigizi_hpht,

    p.hpl_from_hpht_date,

    p.pregnancy_anchor_date,

    p.final_match_qa_required,


    -- ------------------------------------------------------------------------
    -- USG DATING
    -- ------------------------------------------------------------------------

    u.usg_date
      AS dating_usg_date,

    u.usg_ga_weeks
      AS dating_usg_ga_weeks,

    u.usg_ga_days
      AS dating_usg_ga_days,

    u.usg_recorded_hpl_date,

    u.hpl_from_usg_ga_date,

    u.hpl_from_usg_date,

    u.usg_dating_quality,


    -- ------------------------------------------------------------------------
    -- EXPECTED DELIVERY DATE
    --
    -- PRIORITY
    --
    -- 1 RECORDED HPL EPUS
    -- 2 RECORDED HPL SIGIZI
    -- 3 CANONICAL RECORDED HPL
    -- 4 EARLY USG <=14 WEEKS
    -- 5 HPHT+280 EPUS
    -- 6 HPHT+280 SIGIZI
    -- 7 CANONICAL HPHT+280
    -- 8 FALLBACK HPHT+280
    -- ------------------------------------------------------------------------

    COALESCE(

      p.hpl_epus,

      p.hpl_sigizi,

      p.hpl_recorded_date,

      CASE

        WHEN u.usg_ga_weeks BETWEEN 4 AND 14

        THEN u.hpl_from_usg_ga_date

      END,

      p.hpl_from_epus_hpht,

      p.hpl_from_sigizi_hpht,

      p.hpl_from_hpht_date,

      CASE

        WHEN p.hpht_date IS NOT NULL

        THEN DATE_ADD(
          p.hpht_date,
          INTERVAL 280 DAY
        )

      END

    ) AS expected_delivery_date,


    CASE

      WHEN p.hpl_epus IS NOT NULL
        THEN 'RECORDED_HPL_EPUS'


      WHEN p.hpl_sigizi IS NOT NULL
        THEN 'RECORDED_HPL_SIGIZI'


      WHEN p.hpl_recorded_date IS NOT NULL
        THEN 'RECORDED_HPL_CANONICAL'


      WHEN u.usg_ga_weeks BETWEEN 4 AND 14
       AND u.hpl_from_usg_ga_date IS NOT NULL

        THEN 'EARLY_USG_GA_LE_14W'


      WHEN p.hpl_from_epus_hpht IS NOT NULL
        THEN 'HPHT_PLUS_280D_EPUS'


      WHEN p.hpl_from_sigizi_hpht IS NOT NULL
        THEN 'HPHT_PLUS_280D_SIGIZI'


      WHEN p.hpl_from_hpht_date IS NOT NULL
        THEN 'HPHT_PLUS_280D_CANONICAL'


      WHEN p.hpht_date IS NOT NULL
        THEN 'HPHT_PLUS_280D_FALLBACK'

    END AS expected_delivery_date_source,


    -- ------------------------------------------------------------------------
    -- ACCEPTED DATED DELIVERY
    -- ------------------------------------------------------------------------

    d.delivery_event_id
      AS actual_delivery_event_id,

    d.delivery_date
      AS actual_delivery_date,

    d.pregnancy_outcome_final
      AS dated_delivery_outcome,

    d.anc_link_status,

    d.source_systems
      AS dated_delivery_source_systems,

    d.source_system_count
      AS dated_delivery_source_count,


    ARRAY_TO_STRING(
      d.source_systems,
      ' + '
    ) AS dated_delivery_source_combination,


    d.distinct_source_record_count
      AS dated_delivery_source_record_count,


    d.post_anc_consolidation_applied,

    d.events_collapsed_post_anc,

    d.post_anc_consolidation_qa_flag,


    -- ------------------------------------------------------------------------
    -- CONFIRMED ABORTION
    -- ------------------------------------------------------------------------

    COALESCE(
      a.abortion_evidence_record_count,
      0
    ) AS abortion_evidence_record_count,


    a.abortion_date,

    a.abortion_source_combination,


    COALESCE(
      a.abortion_date_distinct_count,
      0
    ) AS abortion_date_distinct_count,


    a.abortion_date_min,

    a.abortion_date_max,


    COALESCE(
      a.abortion_name_conflict_records,
      0
    ) AS abortion_name_conflict_records,


    COALESCE(
      a.abortion_dob_conflict_records,
      0
    ) AS abortion_dob_conflict_records,


    -- ------------------------------------------------------------------------
    -- UNCONFIRMED IBU_NIFAS ABORTION FIELD — QA ONLY
    -- ------------------------------------------------------------------------

    COALESCE(
      uq.unconfirmed_ibu_nifas_abortion_record_count,
      0
    ) AS unconfirmed_ibu_nifas_abortion_record_count,


    COALESCE(
      uq.unconfirmed_ibu_nifas_abortion_date_count,
      0
    ) AS unconfirmed_ibu_nifas_abortion_date_count,


    uq.unconfirmed_ibu_nifas_abortion_date_min,

    uq.unconfirmed_ibu_nifas_abortion_date_max,


    -- ------------------------------------------------------------------------
    -- DELIVERY DATE UNKNOWN
    -- ------------------------------------------------------------------------

    COALESCE(
      uo.delivery_date_unknown_evidence_count,
      0
    ) AS delivery_date_unknown_evidence_count,


    uo.delivery_date_unknown_source_combination,


    uo.delivery_date_unknown_outcome_final,


    COALESCE(
      uo.unknown_date_live_birth_evidence_count,
      0
    ) AS unknown_date_live_birth_evidence_count,


    COALESCE(
      uo.unknown_date_stillbirth_evidence_count,
      0
    ) AS unknown_date_stillbirth_evidence_count,


    COALESCE(
      uo.unknown_date_unknown_outcome_evidence_count,
      0
    ) AS unknown_date_unknown_outcome_evidence_count,


    -- ------------------------------------------------------------------------
    -- RAW CONFLICT EVIDENCE
    -- ------------------------------------------------------------------------

    COALESCE(
      c.delivery_abortion_conflict_evidence_count,
      0
    ) AS delivery_abortion_conflict_evidence_count,


    c.delivery_abortion_conflict_source_combination,


    -- ------------------------------------------------------------------------
    -- BIRTH SOURCE FLAGS
    -- ------------------------------------------------------------------------

    (
      d.delivery_event_id IS NOT NULL

      AND 'SIGIZI'
        IN UNNEST(
          d.source_systems
        )
    )

    OR COALESCE(
      uo.has_unknown_delivery_sigizi,
      FALSE
    ) AS has_birth_sigizi,


    (
      d.delivery_event_id IS NOT NULL

      AND 'EPUS'
        IN UNNEST(
          d.source_systems
        )
    )

    OR COALESCE(
      uo.has_unknown_delivery_epus,
      FALSE
    ) AS has_birth_epus,


    (
      d.delivery_event_id IS NOT NULL

      AND 'SIMRS'
        IN UNNEST(
          d.source_systems
        )
    )

    OR COALESCE(
      uo.has_unknown_delivery_simrs,
      FALSE
    ) AS has_birth_simrs,


    (
      d.delivery_event_id IS NOT NULL

      AND 'EKOHORT'
        IN UNNEST(
          d.source_systems
        )
    )

    OR COALESCE(
      uo.has_unknown_delivery_ekohort,
      FALSE
    ) AS has_birth_ekohort,


    (
      d.delivery_event_id IS NOT NULL

      AND 'BIRTH_CONFIRMATION'
        IN UNNEST(
          d.source_systems
        )
    )

    OR COALESCE(
      uo.has_unknown_delivery_birth_confirmation,
      FALSE
    ) AS has_birth_birth_confirmation


  FROM
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_episode_spine_v3_3` p


  LEFT JOIN epus_patient_phone eph
    ON eph.nik_clean = p.nik_clean

   AND maternal_nik_is_plausible(
         p.nik_clean,
         COALESCE(
           p.pregnancy_anchor_date,
           p.hpht_date,
           DATE_SUB(
             p.hpl_recorded_date,
             INTERVAL 280 DAY
           ),
           analysis_date
         )
       )


  LEFT JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_usg_dating_v3_3` u

    USING (pregnancy_episode_id)


  LEFT JOIN
    `stellar-orb-451904-d9.kohort_bumil_v2.t_delivery_event_canonical_post_anc_v3_3` d

    USING (pregnancy_episode_id)


  LEFT JOIN abortion_final a
    USING (pregnancy_episode_id)


  LEFT JOIN unknown_delivery_final uo
    USING (pregnancy_episode_id)


  LEFT JOIN conflict_agg c
    USING (pregnancy_episode_id)


  LEFT JOIN unconfirmed_abortion_qa uq
    USING (pregnancy_episode_id)
),


with_monitoring_window AS (

  SELECT
    *,


    (
      expected_delivery_date
        BETWEEN plausible_pregnancy_floor

        AND DATE_ADD(
          analysis_date,
          INTERVAL 300 DAY
        )
    ) AS pregnancy_date_valid_flag,


    (
      expected_delivery_date
        BETWEEN monitoring_start_date

        AND DATE_ADD(
          analysis_date,
          INTERVAL 300 DAY
        )
    ) AS monitoring_eligible_flag,


    LENGTH(
      COALESCE(
        no_hp_clean,
        ''
      )
    ) >= 8
      AS has_phone,


    expected_delivery_date
      = analysis_date
      AS hpl_today_flag


  FROM pregnancy_base
),


with_status AS (

  SELECT
    *,


    -- ========================================================================
    -- FINAL STATUS
    --
    -- DELIVERED
    -- > CONFIRMED ABORTUS
    -- > DELIVERY DATE UNKNOWN
    -- > DATE UNKNOWN
    -- > MISSING
    -- > ACTIVE
    -- ========================================================================

    CASE

      WHEN actual_delivery_event_id IS NOT NULL

        THEN 'DELIVERED'


      WHEN abortion_evidence_record_count > 0

        THEN 'ABORTUS'


      WHEN delivery_date_unknown_evidence_count > 0

        THEN 'DELIVERED_DATE_UNKNOWN'


      WHEN expected_delivery_date IS NULL

        THEN 'DATE_UNKNOWN'


      -- STRICT RULE:
      -- HPL TODAY IS NOT OVERDUE.
      WHEN expected_delivery_date
        < analysis_date

        THEN 'MISSING_BIRTH'


      ELSE 'ACTIVE_PREGNANCY'

    END AS monitoring_status_all_history,


    -- ------------------------------------------------------------------------
    -- CONFLICT:
    -- confirmed abortion + birth evidence
    -- ------------------------------------------------------------------------

    (
      abortion_evidence_record_count > 0

      AND (
           actual_delivery_event_id IS NOT NULL

        OR delivery_date_unknown_evidence_count > 0
      )

    ) AS abortion_birth_conflict_flag,


    (
      abortion_date_distinct_count > 1
    ) AS abortion_date_conflict_flag,


    (
      delivery_abortion_conflict_evidence_count > 0
    ) AS raw_delivery_abortion_conflict_flag,


    (
      unconfirmed_ibu_nifas_abortion_record_count > 0
    ) AS unconfirmed_ibu_nifas_abortion_field_flag


  FROM with_monitoring_window
),


with_outcome AS (

  SELECT
    *,


    CASE

      -- ----------------------------------------------------------------------
      -- DATED DELIVERY
      -- ----------------------------------------------------------------------

      WHEN actual_delivery_event_id IS NOT NULL

      THEN CASE

        WHEN dated_delivery_outcome
          = 'LIVE_BIRTH'

          THEN 'LIVE_BIRTH'


        WHEN dated_delivery_outcome
          = 'STILLBIRTH'

          THEN 'STILLBIRTH'


        WHEN dated_delivery_outcome
          = 'MIXED_LIVE_STILLBIRTH'

          THEN 'MIXED_LIVE_STILLBIRTH'


        ELSE 'DELIVERY_OUTCOME_UNCLEAR'

      END


      -- ----------------------------------------------------------------------
      -- CONFIRMED ABORTION
      -- ----------------------------------------------------------------------

      WHEN abortion_evidence_record_count > 0

        THEN 'ABORTUS'


      -- ----------------------------------------------------------------------
      -- DELIVERY DATE UNKNOWN
      -- ----------------------------------------------------------------------

      WHEN delivery_date_unknown_evidence_count > 0

      THEN CASE

        WHEN delivery_date_unknown_outcome_final
          = 'LIVE_BIRTH'

          THEN 'LIVE_BIRTH'


        WHEN delivery_date_unknown_outcome_final
          = 'STILLBIRTH'

          THEN 'STILLBIRTH'


        WHEN delivery_date_unknown_outcome_final
          = 'MIXED_LIVE_STILLBIRTH'

          THEN 'MIXED_LIVE_STILLBIRTH'


        ELSE 'DELIVERY_OUTCOME_UNCLEAR'

      END


      ELSE NULL

    END AS pregnancy_outcome_final,


    -- ------------------------------------------------------------------------
    -- PRIMARY BIRTH SOURCE
    -- ------------------------------------------------------------------------

    CASE

      WHEN actual_delivery_event_id IS NOT NULL

      THEN CASE

        WHEN 'SIMRS'
          IN UNNEST(
            dated_delivery_source_systems
          )

          THEN 'SIMRS'


        WHEN 'EPUS'
          IN UNNEST(
            dated_delivery_source_systems
          )

          THEN 'EPUS'


        WHEN 'EKOHORT'
          IN UNNEST(
            dated_delivery_source_systems
          )

          THEN 'EKOHORT'


        WHEN 'SIGIZI'
          IN UNNEST(
            dated_delivery_source_systems
          )

          THEN 'SIGIZI'


        WHEN 'BIRTH_CONFIRMATION'
          IN UNNEST(
            dated_delivery_source_systems
          )

          THEN 'BIRTH_CONFIRMATION'

      END


      WHEN delivery_date_unknown_evidence_count > 0

      THEN CASE

        WHEN has_birth_epus
          THEN 'EPUS'

        WHEN has_birth_sigizi
          THEN 'SIGIZI'

        WHEN has_birth_birth_confirmation
          THEN 'BIRTH_CONFIRMATION'

        ELSE 'OTHER'

      END


    END AS primary_birth_source


  FROM with_status
),


with_metrics AS (

  SELECT
    *,


    monitoring_status_all_history
      IN (
        'DELIVERED',
        'DELIVERED_DATE_UNKNOWN'
      )
      AS birth_found_flag,


    monitoring_status_all_history
      = 'DELIVERED'
      AS birth_date_known_flag,


    pregnancy_outcome_final
      IN (
        'LIVE_BIRTH',
        'STILLBIRTH',
        'MIXED_LIVE_STILLBIRTH'
      )
      AS birth_outcome_known_flag,


    (
      monitoring_eligible_flag

      AND monitoring_status_all_history
          != 'ABORTUS'
    ) AS expected_birth_flag,


    (
      monitoring_eligible_flag

      AND monitoring_status_all_history
          != 'ABORTUS'

      AND expected_delivery_date
          < analysis_date
    ) AS expected_to_have_delivered_flag,


    (
      expected_delivery_date IS NOT NULL

      AND monitoring_status_all_history
          != 'ABORTUS'
    ) AS expected_birth_all_history_flag,


    (
      expected_delivery_date IS NOT NULL

      AND monitoring_status_all_history
          != 'ABORTUS'

      AND expected_delivery_date
          < analysis_date
    ) AS expected_to_have_delivered_all_history_flag,


    monitoring_status_all_history
      = 'MISSING_BIRTH'
      AS missing_birth_flag,


    monitoring_status_all_history
      = 'ACTIVE_PREGNANCY'
      AS currently_still_pregnant_flag,


    CASE

      WHEN monitoring_status_all_history
        = 'MISSING_BIRTH'

      THEN DATE_DIFF(
        analysis_date,
        expected_delivery_date,
        DAY
      )

    END AS missing_birth_days_overdue,


    -- ------------------------------------------------------------------------
    -- OPERATIONAL-SCOPE FLAGS
    -- ------------------------------------------------------------------------

    (
      monitoring_eligible_flag

      AND monitoring_status_all_history
          IN (
            'DELIVERED',
            'DELIVERED_DATE_UNKNOWN'
          )
    ) AS birth_found_operational_flag,


    (
      monitoring_eligible_flag

      AND monitoring_status_all_history
          = 'DELIVERED'
    ) AS delivered_operational_flag,


    (
      monitoring_eligible_flag

      AND monitoring_status_all_history
          = 'DELIVERED_DATE_UNKNOWN'
    ) AS delivered_date_unknown_operational_flag,


    (
      monitoring_eligible_flag

      AND monitoring_status_all_history
          = 'ABORTUS'
    ) AS abortion_operational_flag,


    (
      monitoring_eligible_flag

      AND monitoring_status_all_history
          = 'MISSING_BIRTH'
    ) AS missing_birth_operational_flag,


    (
      monitoring_eligible_flag

      AND monitoring_status_all_history
          = 'ACTIVE_PREGNANCY'
    ) AS active_pregnancy_operational_flag,


    -- ------------------------------------------------------------------------
    -- INTEGRATED QA
    -- ------------------------------------------------------------------------

    (
         abortion_birth_conflict_flag

      OR abortion_date_conflict_flag

      OR raw_delivery_abortion_conflict_flag

      OR COALESCE(
           post_anc_consolidation_qa_flag,
           FALSE
         )

      OR COALESCE(
           final_match_qa_required,
           FALSE
         )

    ) AS integrated_qa_required


  FROM with_outcome
),


final AS (

  SELECT
    *,


    CASE

      WHEN NOT COALESCE(
        pregnancy_date_valid_flag,
        FALSE
      )

        THEN 'EXCLUDED_INVALID_PREGNANCY_DATE'


      WHEN NOT COALESCE(
        monitoring_eligible_flag,
        FALSE
      )

        THEN 'OUTSIDE_OPERATIONAL_MONITORING_WINDOW'


      ELSE monitoring_status_all_history

    END AS monitoring_status_operational,


    DATE_TRUNC(
      expected_delivery_date,
      WEEK(MONDAY)
    ) AS expected_delivery_week,


    DATE_TRUNC(
      expected_delivery_date,
      MONTH
    ) AS expected_delivery_month,


    DATE_TRUNC(
      expected_delivery_date,
      QUARTER
    ) AS expected_delivery_quarter,


    DATE_TRUNC(
      expected_delivery_date,
      YEAR
    ) AS expected_delivery_year,


    DATE_TRUNC(
      actual_delivery_date,
      MONTH
    ) AS actual_delivery_month,


    1 AS pregnancy_count,


    CAST(
      monitoring_status_all_history
        = 'DELIVERED'
      AS INT64
    ) AS delivered_with_date_count,


    CAST(
      monitoring_status_all_history
        = 'DELIVERED_DATE_UNKNOWN'
      AS INT64
    ) AS delivered_date_unknown_count,


    CAST(
      monitoring_status_all_history
        IN (
          'DELIVERED',
          'DELIVERED_DATE_UNKNOWN'
        )
      AS INT64
    ) AS delivered_total_count,


    CAST(
      monitoring_status_all_history
        = 'ABORTUS'
      AS INT64
    ) AS abortion_count,


    CAST(
      monitoring_status_all_history
        = 'MISSING_BIRTH'
      AS INT64
    ) AS missing_birth_count,


    CAST(
      monitoring_status_all_history
        = 'ACTIVE_PREGNANCY'
      AS INT64
    ) AS active_pregnancy_count,


    CAST(
      monitoring_status_all_history
        = 'DATE_UNKNOWN'
      AS INT64
    ) AS date_unknown_count


  FROM with_metrics
)


SELECT *
FROM final;


-- ############################################################################
-- QA 0
-- VALIDATED SOURCE CLASSIFICATION
-- ############################################################################

SELECT

  event_type,

  source_system,

  source_table,

  outcome_evidence_validation_class,

  confirmed_abortion_evidence_flag,

  COUNT(*) AS source_records,


  COUNT(
    DISTINCT nik_clean
  ) AS distinct_valid_nik


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_source_v3_3`


GROUP BY
  event_type,
  source_system,
  source_table,
  outcome_evidence_validation_class,
  confirmed_abortion_evidence_flag


ORDER BY
  event_type,
  source_system,
  source_table,
  source_records DESC;


-- ############################################################################
-- QA 1
-- OUTCOME-EVIDENCE LINKAGE
-- ############################################################################

SELECT

  event_type,

  evidence_link_status,

  COUNT(*) AS evidence_records


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_link_v3_3`


GROUP BY
  event_type,
  evidence_link_status


ORDER BY
  event_type,
  evidence_records DESC;


-- ############################################################################
-- QA 2
-- ELIGIBLE OUTCOME EVIDENCE ACCOUNTING
--
-- EXPECTED INPUT TO LINKAGE:
--
--   confirmed abortions:
--       791 SIGIZI explicit
--        41 BC app
--        65 BC legacy
--       ----------------
--       897
--
--   delivery-date-unknown = 3485
--   delivery/abortion conflict = 6
--
--   TOTAL = 4388
--
-- 2203 unconfirmed SIGIZI tgl_abortus rows remain in source QA
-- but are deliberately excluded from this linkage table.
-- ############################################################################

SELECT

  COUNT(*) AS total_eligible_evidence_records,


  COUNTIF(
    event_type = 'ABORTION'
  ) AS confirmed_abortion_records,


  COUNTIF(
    event_type = 'DELIVERY_DATE_UNKNOWN'
  ) AS delivery_date_unknown_records,


  COUNTIF(
    event_type = 'CONFLICT_DELIVERY_ABORTION'
  ) AS conflict_records


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_link_v3_3`;


-- ############################################################################
-- QA 2B
-- UNCONFIRMED IBU_NIFAS ABORTION DATE FIELD
--
-- EXPECTED AROUND 2203 SOURCE RECORDS
-- ############################################################################

SELECT

  COUNT(*) AS unconfirmed_ibu_nifas_abortion_records,


  COUNT(
    DISTINCT nik_clean
  ) AS distinct_valid_nik,


  MIN(
    abortion_date
  ) AS min_abortion_date_field,


  MAX(
    abortion_date
  ) AS max_abortion_date_field


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_source_v3_3`


WHERE
  outcome_evidence_validation_class
    = 'IBU_NIFAS_ABORTION_DATE_ONLY_UNCONFIRMED';


-- ############################################################################
-- QA 3
-- MATCH METHOD
-- ############################################################################

SELECT

  event_type,

  evidence_match_method,

  evidence_match_confidence,

  COUNT(*) AS matched_records


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_link_v3_3`


WHERE
  evidence_link_status = 'MATCHED'


GROUP BY
  event_type,
  evidence_match_method,
  evidence_match_confidence


ORDER BY
  event_type,
  matched_records DESC;


-- ############################################################################
-- QA 4
-- FINAL PREGNANCY PRIMARY KEY
--
-- EXPECTED:
-- 26057 / 26057
-- ############################################################################

SELECT

  COUNT(*) AS final_pregnancy_rows,


  COUNT(
    DISTINCT pregnancy_episode_id
  ) AS distinct_pregnancy_episode_ids


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_monitoring_integrated_v3_3`;


-- ############################################################################
-- QA 5
-- ALL HISTORY MONITORING STATUS
-- ############################################################################

SELECT

  monitoring_status_all_history,

  COUNT(*) AS pregnancies


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_monitoring_integrated_v3_3`


GROUP BY monitoring_status_all_history


ORDER BY pregnancies DESC;


-- ############################################################################
-- QA 6
-- OPERATIONAL MONITORING STATUS
-- ############################################################################

SELECT

  monitoring_status_operational,

  COUNT(*) AS pregnancies


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_monitoring_integrated_v3_3`


GROUP BY monitoring_status_operational


ORDER BY pregnancies DESC;


-- ############################################################################
-- QA 7
-- MAIN DASHBOARD COUNTERS
--
-- Includes both all-history and operational-scope versions.
-- ############################################################################

SELECT

  COUNT(*) AS canonical_pregnancies,


  COUNTIF(
    monitoring_eligible_flag
  ) AS monitoring_eligible,


  COUNTIF(
    expected_birth_flag
  ) AS expected_births,


  COUNTIF(
    expected_to_have_delivered_flag
  ) AS expected_to_have_delivered,


  -- --------------------------------------------------------------------------
  -- ALL HISTORY
  -- --------------------------------------------------------------------------

  COUNTIF(
    birth_found_flag
  ) AS birth_found_all_history,


  COUNTIF(
    birth_date_known_flag
  ) AS birth_with_date_known_all_history,


  COUNTIF(
    monitoring_status_all_history
      = 'DELIVERED_DATE_UNKNOWN'
  ) AS birth_date_unknown_all_history,


  COUNTIF(
    monitoring_status_all_history
      = 'ABORTUS'
  ) AS abortion_all_history,


  COUNTIF(
    missing_birth_flag
  ) AS missing_birth_all_history,


  COUNTIF(
    currently_still_pregnant_flag
  ) AS active_pregnancy_all_history,


  -- --------------------------------------------------------------------------
  -- OPERATIONAL SCOPE
  -- --------------------------------------------------------------------------

  COUNTIF(
    birth_found_operational_flag
  ) AS birth_found_operational,


  COUNTIF(
    delivered_operational_flag
  ) AS birth_with_date_known_operational,


  COUNTIF(
    delivered_date_unknown_operational_flag
  ) AS birth_date_unknown_operational,


  COUNTIF(
    abortion_operational_flag
  ) AS abortion_operational,


  COUNTIF(
    missing_birth_operational_flag
  ) AS missing_birth_operational,


  COUNTIF(
    active_pregnancy_operational_flag
  ) AS active_pregnancy_operational,


  COUNTIF(
    monitoring_status_all_history
      = 'DATE_UNKNOWN'
  ) AS date_unknown,


  COUNTIF(
    hpl_today_flag
  ) AS hpl_today,


  COUNTIF(
    birth_outcome_known_flag
  ) AS birth_outcome_known


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_monitoring_integrated_v3_3`;


-- ############################################################################
-- QA 8
-- FINAL PREGNANCY OUTCOME
-- ############################################################################

SELECT

  COALESCE(
    pregnancy_outcome_final,
    'NO_OUTCOME_YET'
  ) AS pregnancy_outcome_final,


  COUNT(*) AS pregnancies


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_monitoring_integrated_v3_3`


GROUP BY pregnancy_outcome_final


ORDER BY pregnancies DESC;


-- ############################################################################
-- QA 9
-- CONFLICTS / QA
--
-- EXPECTED:
-- abortion_birth_conflict should now be dramatically lower than 1850.
-- ############################################################################

SELECT

  COUNT(*) AS pregnancies,


  COUNTIF(
    abortion_birth_conflict_flag
  ) AS abortion_birth_conflict,


  COUNTIF(
    abortion_date_conflict_flag
  ) AS abortion_date_conflict,


  COUNTIF(
    raw_delivery_abortion_conflict_flag
  ) AS raw_delivery_abortion_conflict,


  COUNTIF(
    post_anc_consolidation_qa_flag
  ) AS post_anc_delivery_qa,


  COUNTIF(
    unconfirmed_ibu_nifas_abortion_field_flag
  ) AS pregnancies_with_unconfirmed_ibu_nifas_abortion_field,


  COUNTIF(
    integrated_qa_required
  ) AS integrated_qa_required


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_monitoring_integrated_v3_3`;


-- ############################################################################
-- QA 10
-- UNMATCHED ELIGIBLE OUTCOME EVIDENCE
-- ############################################################################

SELECT

  event_type,

  source_system,

  evidence_link_status,

  COUNT(*) AS evidence_records


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_outcome_evidence_link_v3_3`


WHERE
  evidence_link_status != 'MATCHED'


GROUP BY
  event_type,
  source_system,
  evidence_link_status


ORDER BY
  event_type,
  evidence_records DESC;


-- ############################################################################
-- QA 11
-- EXPECTED DELIVERY YEAR × FINAL STATUS
-- ############################################################################

SELECT

  EXTRACT(
    YEAR
    FROM expected_delivery_date
  ) AS expected_delivery_year,


  monitoring_status_all_history,


  COUNT(*) AS pregnancies


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_monitoring_integrated_v3_3`


GROUP BY
  expected_delivery_year,
  monitoring_status_all_history


ORDER BY
  expected_delivery_year,
  pregnancies DESC;


-- ############################################################################
-- QA 12
-- HPL TODAY MUST NOT BE MISSING
--
-- EXPECTED:
-- hpl_today_and_missing = 0
-- ############################################################################

SELECT

  COUNTIF(
    hpl_today_flag
  ) AS hpl_today,


  COUNTIF(
    hpl_today_flag
    AND missing_birth_flag
  ) AS hpl_today_and_missing


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_monitoring_integrated_v3_3`;


-- ############################################################################
-- QA 13
-- CONFIRMED ABORTION VS BIRTH CONFLICT DETAIL
--
-- This should now represent genuine contradictions rather than systematic
-- IBU_NIFAS tgl_abortus artefacts.
-- ############################################################################

SELECT

  CASE

    WHEN actual_delivery_event_id IS NOT NULL
      THEN 'DATED_DELIVERY'

    WHEN delivery_date_unknown_evidence_count > 0
      THEN 'DELIVERY_DATE_UNKNOWN'

    ELSE 'NO_BIRTH_EVIDENCE'

  END AS birth_evidence_type,


  COUNT(*) AS pregnancies,


  COUNTIF(
    abortion_date = actual_delivery_date
  ) AS abortion_date_equals_delivery_date


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_monitoring_integrated_v3_3`


WHERE
  abortion_birth_conflict_flag = TRUE


GROUP BY birth_evidence_type


ORDER BY pregnancies DESC;


-- ############################################################################
-- QA 14
-- PHONE ENRICHMENT COVERAGE AND FINAL-GRAIN SAFETY
--
-- EXPECTED:
-- pregnancy_rows = distinct_pregnancy_episode_ids
-- ############################################################################

SELECT

  COUNT(*) AS pregnancy_rows,

  COUNT(
    DISTINCT pregnancy_episode_id
  ) AS distinct_pregnancy_episode_ids,

  COUNTIF(
    no_hp_clean IS NOT NULL
  ) AS pregnancies_with_phone,

  COUNTIF(
    no_hp_selected_source = 'PREGNANCY_SOURCE'
  ) AS phone_from_pregnancy_source,

  COUNTIF(
    no_hp_selected_source
      = 'EPUS_LAPORAN_PELAYANAN_PASIEN_UPDATE'
  ) AS phone_filled_from_epus_patient_report,

  COUNTIF(
    no_hp_selected_source = 'MISSING'
  ) AS pregnancies_still_without_phone


FROM
  `stellar-orb-451904-d9.kohort_bumil_v2.t_pregnancy_monitoring_integrated_v3_3`;
