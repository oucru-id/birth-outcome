-- Independent source layer: references redirected to v3; original logic retained.
-- V3 CORE DRAFT: not executed in BigQuery; production compatibility not yet validated.
-- Run this entire file as one job. Existing v2 inputs are read only.
-- Original comments below describe recovered historical scripts, not current counts.

CREATE OR REPLACE TABLE `spheres-lombok-barat.kohort_bumil_v3.t_delivery_source_first_report_native` AS

WITH

-- =============================================================================
-- 0. CANONICAL DELIVERY MEMBERS
-- =============================================================================

canonical_members AS (

  SELECT
    d.delivery_event_id,
    d.pregnancy_episode_id,
    d.delivery_date,

    b.source_system,
    b.source_subtype,
    b.source_event_id,
    b.source_record_id

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_v3` d

  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_member_map_v3` m
      ON d.delivery_event_id = m.delivery_event_id

  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_delivery_dedup_base` b
      ON m.source_event_id = b.source_event_id

  WHERE
    d.strict_birth_count_eligible_flag

    AND d.delivery_date IS NOT NULL
),


-- =============================================================================
-- =============================================================================
-- 1. SIGIZI
-- =============================================================================
-- =============================================================================

sigizi_rows AS (

  SELECT
    TO_JSON_STRING(t) AS row_json

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_source_records` t
),


sigizi_prepared AS (

  SELECT

    -- -------------------------------------------------------------------------
    -- SOURCE TABLE
    -- -------------------------------------------------------------------------

    COALESCE(

      NULLIF(
        JSON_VALUE(
          row_json,
          '$.source_table'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          row_json,
          '$.data_source'
        ),
        ''
      ),

      'UNKNOWN'

    ) AS source_table,


    -- -------------------------------------------------------------------------
    -- SOURCE RECORD ID
    -- -------------------------------------------------------------------------

    COALESCE(

      NULLIF(
        JSON_VALUE(
          row_json,
          '$.source_record_id'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          row_json,
          '$.dedup_key'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          row_json,
          '$.uuid'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          row_json,
          '$.hash_code'
        ),
        ''
      ),

      CAST(
        FARM_FINGERPRINT(row_json)
        AS STRING
      )

    ) AS source_record_id,


    -- -------------------------------------------------------------------------
    -- ORIGINAL SOURCE JSON
    -- -------------------------------------------------------------------------

    COALESCE(

      NULLIF(
        JSON_VALUE(
          row_json,
          '$.source_json'
        ),
        ''
      ),

      row_json

    ) AS original_source_json,


    row_json

  FROM sigizi_rows
),


sigizi_metadata_raw AS (

  SELECT

    'SIGIZI'
      AS source_system,


    CONCAT(
      'SIGIZI|',
      source_table,
      '|',
      source_record_id
    ) AS source_event_id,


    -- -------------------------------------------------------------------------
    -- FILE NAME
    -- -------------------------------------------------------------------------

    COALESCE(

      NULLIF(
        JSON_VALUE(
          row_json,
          '$.file_name'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          row_json,
          '$.source_file_name'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          original_source_json,
          '$.file_name'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          original_source_json,
          '$.source_file_name'
        ),
        ''
      )

    ) AS source_file_name,


    -- -------------------------------------------------------------------------
    -- FILE DATE FALLBACK
    -- -------------------------------------------------------------------------

    COALESCE(

      SAFE_CAST(
        JSON_VALUE(
          row_json,
          '$.file_date_parsed'
        )
        AS DATE
      ),

      SAFE_CAST(
        JSON_VALUE(
          original_source_json,
          '$.file_date_parsed'
        )
        AS DATE
      ),

      SAFE.PARSE_DATE(

        '%Y-%m-%d',

        REGEXP_EXTRACT(

          COALESCE(

            NULLIF(
              JSON_VALUE(
                row_json,
                '$.file_date'
              ),
              ''
            ),

            NULLIF(
              JSON_VALUE(
                original_source_json,
                '$.file_date'
              ),
              ''
            )

          ),

          r'(\d{4}-\d{2}-\d{2})'
        )
      )

    ) AS fallback_file_date,


    -- -------------------------------------------------------------------------
    -- INGESTION FALLBACK
    -- -------------------------------------------------------------------------

    COALESCE(

      SAFE_CAST(
        JSON_VALUE(
          row_json,
          '$.ingestion_timestamp_parsed'
        )
        AS TIMESTAMP
      ),

      SAFE_CAST(
        JSON_VALUE(
          original_source_json,
          '$.ingestion_timestamp_parsed'
        )
        AS TIMESTAMP
      ),

      SAFE_CAST(
        JSON_VALUE(
          row_json,
          '$.ingestion_timestamp'
        )
        AS TIMESTAMP
      ),

      SAFE_CAST(
        JSON_VALUE(
          original_source_json,
          '$.ingestion_timestamp'
        )
        AS TIMESTAMP
      ),

      SAFE_CAST(
        JSON_VALUE(
          row_json,
          '$.loaded_at'
        )
        AS TIMESTAMP
      ),

      SAFE_CAST(
        JSON_VALUE(
          original_source_json,
          '$.loaded_at'
        )
        AS TIMESTAMP
      )

    ) AS ingestion_timestamp

  FROM sigizi_prepared
),


-- =============================================================================
-- SIGIZI FILE-NAME PARSER
--
-- FORMAT A
--   2026-02-08 18:58:02.805
--
-- FORMAT B
--   2026-07-20 13.35.50
--
-- FORMAT C
--   20260720-133252
-- =============================================================================

sigizi_parsed AS (

  SELECT
    *,


    SAFE.PARSE_DATETIME(

      '%Y-%m-%d %H:%M:%E*S',

      REGEXP_EXTRACT(
        source_file_name,
        r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
      )

    ) AS filename_datetime_colon,


    SAFE.PARSE_DATETIME(

      '%Y-%m-%d %H.%M.%E*S',

      REGEXP_EXTRACT(
        source_file_name,
        r'(\d{4}-\d{2}-\d{2}\s+\d{2}\.\d{2}\.\d{2}(?:\.\d+)?)'
      )

    ) AS filename_datetime_dot,


    SAFE.PARSE_DATETIME(

      '%Y%m%d-%H%M%S',

      REGEXP_EXTRACT(
        source_file_name,
        r'(\d{8}-\d{6})'
      )

    ) AS filename_datetime_compact

  FROM sigizi_metadata_raw
),


sigizi_meta AS (

  SELECT
    source_system,
    source_event_id,
    source_file_name,


    COALESCE(

      TIMESTAMP(
        filename_datetime_colon,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        filename_datetime_dot,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        filename_datetime_compact,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        fallback_file_date,
        'Asia/Makassar'
      ),

      ingestion_timestamp

    ) AS report_timestamp,


    COALESCE(

      DATE(
        filename_datetime_colon
      ),

      DATE(
        filename_datetime_dot
      ),

      DATE(
        filename_datetime_compact
      ),

      fallback_file_date,

      DATE(
        ingestion_timestamp,
        'Asia/Makassar'
      )

    ) AS report_date,


    CASE

      WHEN filename_datetime_colon IS NOT NULL
        THEN 'FILE_NAME_TIMESTAMP'

      WHEN filename_datetime_dot IS NOT NULL
        THEN 'FILE_NAME_TIMESTAMP'

      WHEN filename_datetime_compact IS NOT NULL
        THEN 'FILE_NAME_COMPACT_TIMESTAMP'

      WHEN fallback_file_date IS NOT NULL
        THEN 'FILE_DATE'

      WHEN ingestion_timestamp IS NOT NULL
        THEN 'INGESTION_FALLBACK'

      ELSE 'MISSING'

    END AS report_timestamp_source,


    CASE

      WHEN filename_datetime_colon IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN filename_datetime_dot IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN filename_datetime_compact IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN fallback_file_date IS NOT NULL
        THEN 'DATE_ONLY'

      WHEN ingestion_timestamp IS NOT NULL
        THEN 'FALLBACK_TIMESTAMP'

      ELSE 'MISSING'

    END AS report_timestamp_quality

  FROM sigizi_parsed
),


-- =============================================================================
-- =============================================================================
-- 2. EPUS
-- =============================================================================
-- =============================================================================

epus_same_delivery AS (

  SELECT
    p.epus_pregnancy_key,

    r.file_name,
    r.file_date_parsed,
    r.ingestion_timestamp_parsed

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_master` p

  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_mother_records` r

    ON p.epus_mother_key
       = r.epus_mother_key

    AND p.delivery_date
        = r.delivery_date

  WHERE
    p.epus_pregnancy_key IS NOT NULL

    AND p.delivery_date IS NOT NULL

    AND r.delivery_date IS NOT NULL
),


epus_direct_delivery AS (

  SELECT
    p.epus_pregnancy_key,

    r.file_name,
    r.file_date_parsed,
    r.ingestion_timestamp_parsed

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_master` p

  JOIN
    `spheres-lombok-barat.kohort_bumil_v3.t_epus_mother_records` r

    ON p.delivery_source_record_key
       = r.epus_source_record_key

  WHERE
    p.epus_pregnancy_key IS NOT NULL

    AND p.delivery_date IS NOT NULL
),


epus_candidates AS (

  SELECT *
  FROM epus_same_delivery


  UNION DISTINCT


  SELECT *
  FROM epus_direct_delivery
),


epus_parsed AS (

  SELECT

    'EPUS'
      AS source_system,


    CONCAT(
      'EPUS|',
      epus_pregnancy_key
    ) AS source_event_id,


    file_name
      AS source_file_name,


    SAFE.PARSE_DATETIME(

      '%Y-%m-%d %H:%M:%E*S',

      REGEXP_EXTRACT(
        file_name,
        r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
      )

    ) AS filename_datetime_colon,


    SAFE.PARSE_DATETIME(

      '%Y-%m-%d %H.%M.%E*S',

      REGEXP_EXTRACT(
        file_name,
        r'(\d{4}-\d{2}-\d{2}\s+\d{2}\.\d{2}\.\d{2}(?:\.\d+)?)'
      )

    ) AS filename_datetime_dot,


    SAFE.PARSE_DATETIME(

      '%Y%m%d-%H%M%S',

      REGEXP_EXTRACT(
        file_name,
        r'(\d{8}-\d{6})'
      )

    ) AS filename_datetime_compact,


    file_date_parsed
      AS fallback_file_date,


    ingestion_timestamp_parsed
      AS ingestion_timestamp

  FROM epus_candidates
),


epus_meta AS (

  SELECT
    source_system,
    source_event_id,
    source_file_name,


    COALESCE(

      TIMESTAMP(
        filename_datetime_colon,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        filename_datetime_dot,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        filename_datetime_compact,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        fallback_file_date,
        'Asia/Makassar'
      ),

      ingestion_timestamp

    ) AS report_timestamp,


    COALESCE(

      DATE(
        filename_datetime_colon
      ),

      DATE(
        filename_datetime_dot
      ),

      DATE(
        filename_datetime_compact
      ),

      fallback_file_date,

      DATE(
        ingestion_timestamp,
        'Asia/Makassar'
      )

    ) AS report_date,


    CASE

      WHEN filename_datetime_colon IS NOT NULL
        THEN 'FILE_NAME_TIMESTAMP'

      WHEN filename_datetime_dot IS NOT NULL
        THEN 'FILE_NAME_TIMESTAMP'

      WHEN filename_datetime_compact IS NOT NULL
        THEN 'FILE_NAME_COMPACT_TIMESTAMP'

      WHEN fallback_file_date IS NOT NULL
        THEN 'FILE_DATE'

      WHEN ingestion_timestamp IS NOT NULL
        THEN 'INGESTION_FALLBACK'

      ELSE 'MISSING'

    END AS report_timestamp_source,


    CASE

      WHEN filename_datetime_colon IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN filename_datetime_dot IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN filename_datetime_compact IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN fallback_file_date IS NOT NULL
        THEN 'DATE_ONLY'

      WHEN ingestion_timestamp IS NOT NULL
        THEN 'FALLBACK_TIMESTAMP'

      ELSE 'MISSING'

    END AS report_timestamp_quality

  FROM epus_parsed
),


-- =============================================================================
-- =============================================================================
-- 3. SIMRS
-- =============================================================================
-- =============================================================================

simrs_json AS (

  SELECT
    TO_JSON_STRING(t) AS j

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_simrs_patut_patuh_inc` t
),


simrs_raw AS (

  SELECT

    'SIMRS'
      AS source_system,


    CONCAT(

      'SIMRS|',

      COALESCE(

        NULLIF(
          JSON_VALUE(
            j,
            '$.source_record_id'
          ),
          ''
        ),

        NULLIF(
          JSON_VALUE(
            j,
            '$.dedup_key'
          ),
          ''
        ),

        NULLIF(
          JSON_VALUE(
            j,
            '$.source_row_hash'
          ),
          ''
        ),

        CAST(
          FARM_FINGERPRINT(j)
          AS STRING
        )

      )

    ) AS source_event_id,


    NULLIF(
      JSON_VALUE(
        j,
        '$.file_name'
      ),
      ''
    ) AS source_file_name,


    SAFE_CAST(
      JSON_VALUE(
        j,
        '$.reference_upload_date'
      )
      AS DATE
    ) AS reference_upload_date,


    COALESCE(

      SAFE_CAST(
        JSON_VALUE(
          j,
          '$.file_date_parsed'
        )
        AS DATE
      ),

      SAFE.PARSE_DATE(

        '%Y-%m-%d',

        REGEXP_EXTRACT(
          JSON_VALUE(
            j,
            '$.file_date'
          ),
          r'(\d{4}-\d{2}-\d{2})'
        )
      )

    ) AS fallback_file_date,


    COALESCE(

      SAFE_CAST(
        JSON_VALUE(
          j,
          '$.ingestion_ts'
        )
        AS TIMESTAMP
      ),

      SAFE_CAST(
        JSON_VALUE(
          j,
          '$.ingestion_timestamp'
        )
        AS TIMESTAMP
      )

    ) AS ingestion_timestamp

  FROM simrs_json
),


simrs_parsed AS (

  SELECT
    *,


    SAFE.PARSE_DATETIME(

      '%Y-%m-%d %H:%M:%E*S',

      REGEXP_EXTRACT(
        source_file_name,
        r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
      )

    ) AS filename_datetime_colon,


    SAFE.PARSE_DATETIME(

      '%Y-%m-%d %H.%M.%E*S',

      REGEXP_EXTRACT(
        source_file_name,
        r'(\d{4}-\d{2}-\d{2}\s+\d{2}\.\d{2}\.\d{2}(?:\.\d+)?)'
      )

    ) AS filename_datetime_dot,


    SAFE.PARSE_DATETIME(

      '%Y%m%d-%H%M%S',

      REGEXP_EXTRACT(
        source_file_name,
        r'(\d{8}-\d{6})'
      )

    ) AS filename_datetime_compact

  FROM simrs_raw
),


simrs_meta AS (

  SELECT
    source_system,
    source_event_id,
    source_file_name,


    COALESCE(

      TIMESTAMP(
        filename_datetime_colon,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        filename_datetime_dot,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        filename_datetime_compact,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        reference_upload_date,
        'Asia/Makassar'
      ),

      TIMESTAMP(
        fallback_file_date,
        'Asia/Makassar'
      ),

      ingestion_timestamp

    ) AS report_timestamp,


    COALESCE(

      DATE(
        filename_datetime_colon
      ),

      DATE(
        filename_datetime_dot
      ),

      DATE(
        filename_datetime_compact
      ),

      reference_upload_date,

      fallback_file_date,

      DATE(
        ingestion_timestamp,
        'Asia/Makassar'
      )

    ) AS report_date,


    CASE

      WHEN filename_datetime_colon IS NOT NULL
        THEN 'FILE_NAME_TIMESTAMP'

      WHEN filename_datetime_dot IS NOT NULL
        THEN 'FILE_NAME_TIMESTAMP'

      WHEN filename_datetime_compact IS NOT NULL
        THEN 'FILE_NAME_COMPACT_TIMESTAMP'

      WHEN reference_upload_date IS NOT NULL
        THEN 'REFERENCE_UPLOAD_DATE'

      WHEN fallback_file_date IS NOT NULL
        THEN 'FILE_DATE'

      WHEN ingestion_timestamp IS NOT NULL
        THEN 'INGESTION_FALLBACK'

      ELSE 'MISSING'

    END AS report_timestamp_source,


    CASE

      WHEN filename_datetime_colon IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN filename_datetime_dot IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN filename_datetime_compact IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN reference_upload_date IS NOT NULL
        THEN 'DATE_ONLY'

      WHEN fallback_file_date IS NOT NULL
        THEN 'DATE_ONLY'

      WHEN ingestion_timestamp IS NOT NULL
        THEN 'FALLBACK_TIMESTAMP'

      ELSE 'MISSING'

    END AS report_timestamp_quality

  FROM simrs_parsed
),


-- =============================================================================
-- =============================================================================
-- 4. KOBO INC
-- =============================================================================
-- =============================================================================

kobo_case_master_json AS (

  SELECT
    TO_JSON_STRING(t) AS j

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_kobo_inc_case_master` t
),


kobo_case_keys AS (

  SELECT

    CONCAT(

      'KOBO_INC|',

      COALESCE(

        NULLIF(
          JSON_VALUE(
            j,
            '$.case_id'
          ),
          ''
        ),

        NULLIF(
          JSON_VALUE(
            j,
            '$.source_submission_id'
          ),
          ''
        ),

        CAST(
          FARM_FINGERPRINT(j)
          AS STRING
        )

      )

    ) AS source_event_id,


    NULLIF(
      JSON_VALUE(
        j,
        '$.case_id'
      ),
      ''
    ) AS case_id,


    NULLIF(
      JSON_VALUE(
        j,
        '$.source_submission_id'
      ),
      ''
    ) AS source_submission_id

  FROM kobo_case_master_json
),


kobo_raw_json AS (

  SELECT
    TO_JSON_STRING(t) AS j

  FROM
    `spheres-lombok-barat.data_kobo_form.e-form_pencatatan_pelayanan_intranatal_care` t
),


kobo_raw_metadata AS (

  SELECT

    NULLIF(
      JSON_VALUE(
        j,
        '$.case_id'
      ),
      ''
    ) AS case_id,


    COALESCE(

      NULLIF(
        JSON_VALUE(
          j,
          '$.source_submission_id'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          j,
          '$._uuid'
        ),
        ''
      ),

      NULLIF(
        JSON_VALUE(
          j,
          '$._id'
        ),
        ''
      )

    ) AS source_submission_id,


    NULLIF(
      TRIM(
        JSON_VALUE(
          j,
          '$.end'
        )
      ),
      ''
    ) AS end_string,


    NULLIF(
      TRIM(
        JSON_VALUE(
          j,
          '$.start'
        )
      ),
      ''
    ) AS start_string

  FROM kobo_raw_json
),


kobo_joined AS (

  SELECT

    'KOBO_INC'
      AS source_system,


    c.source_event_id,


    CAST(NULL AS STRING)
      AS source_file_name,


    r.end_string,

    r.start_string

  FROM kobo_case_keys c

  LEFT JOIN kobo_raw_metadata r

    ON (

      c.case_id IS NOT NULL

      AND r.case_id IS NOT NULL

      AND c.case_id = r.case_id

    )

    OR (

      c.case_id IS NULL

      AND c.source_submission_id IS NOT NULL

      AND r.source_submission_id IS NOT NULL

      AND c.source_submission_id
          = r.source_submission_id

    )
),


kobo_parsed AS (

  SELECT
    source_system,
    source_event_id,
    source_file_name,


    CASE

      WHEN end_string IS NULL
        THEN NULL


      WHEN REGEXP_CONTAINS(
        end_string,
        r'(?:Z|[+-]\d{2}:\d{2})$'
      )
        THEN SAFE_CAST(
          end_string
          AS TIMESTAMP
        )


      ELSE TIMESTAMP(

        SAFE_CAST(
          end_string
          AS DATETIME
        ),

        'Asia/Makassar'
      )

    END AS end_timestamp,


    CASE

      WHEN start_string IS NULL
        THEN NULL


      WHEN REGEXP_CONTAINS(
        start_string,
        r'(?:Z|[+-]\d{2}:\d{2})$'
      )
        THEN SAFE_CAST(
          start_string
          AS TIMESTAMP
        )


      ELSE TIMESTAMP(

        SAFE_CAST(
          start_string
          AS DATETIME
        ),

        'Asia/Makassar'
      )

    END AS start_timestamp

  FROM kobo_joined
),


kobo_meta AS (

  SELECT
    source_system,
    source_event_id,
    source_file_name,


    COALESCE(
      end_timestamp,
      start_timestamp
    ) AS report_timestamp,


    DATE(
      COALESCE(
        end_timestamp,
        start_timestamp
      ),
      'Asia/Makassar'
    ) AS report_date,


    CASE

      WHEN end_timestamp IS NOT NULL
        THEN 'KOBO_END_TIMESTAMP'

      WHEN start_timestamp IS NOT NULL
        THEN 'KOBO_START_FALLBACK'

      ELSE 'MISSING'

    END AS report_timestamp_source,


    CASE

      WHEN end_timestamp IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN start_timestamp IS NOT NULL
        THEN 'FALLBACK_TIMESTAMP'

      ELSE 'MISSING'

    END AS report_timestamp_quality

  FROM kobo_parsed
),


-- =============================================================================
-- =============================================================================
-- 5. NEONATAL OUTCOME
-- =============================================================================
-- =============================================================================

neonatal_json AS (

  SELECT
    TO_JSON_STRING(t) AS j

  FROM
    `spheres-lombok-barat.kohort_bumil_v3.vs_kobo_neonatus_outcome_v2_baby` t
),


neonatal_raw AS (

  SELECT

    'NEONATAL_OUTCOME'
      AS source_system,


    CONCAT(

      'NEONATAL|',

      COALESCE(

        NULLIF(
          JSON_VALUE(
            j,
            '$.source_submission_id'
          ),
          ''
        ),

        CAST(
          FARM_FINGERPRINT(j)
          AS STRING
        )

      ),

      '|',

      COALESCE(

        NULLIF(
          JSON_VALUE(
            j,
            '$.baby_number'
          ),
          ''
        ),

        '1'

      )

    ) AS source_event_id,


    CAST(NULL AS STRING)
      AS source_file_name,


    NULLIF(
      TRIM(
        JSON_VALUE(
          j,
          '$.end_time'
        )
      ),
      ''
    ) AS end_string,


    NULLIF(
      TRIM(
        JSON_VALUE(
          j,
          '$.start_time'
        )
      ),
      ''
    ) AS start_string

  FROM neonatal_json
),


neonatal_parsed AS (

  SELECT
    source_system,
    source_event_id,
    source_file_name,


    CASE

      WHEN end_string IS NULL
        THEN NULL


      WHEN REGEXP_CONTAINS(
        end_string,
        r'(?:Z|[+-]\d{2}:\d{2})$'
      )
        THEN SAFE_CAST(
          end_string
          AS TIMESTAMP
        )


      ELSE TIMESTAMP(

        SAFE_CAST(
          end_string
          AS DATETIME
        ),

        'Asia/Makassar'
      )

    END AS end_timestamp,


    CASE

      WHEN start_string IS NULL
        THEN NULL


      WHEN REGEXP_CONTAINS(
        start_string,
        r'(?:Z|[+-]\d{2}:\d{2})$'
      )
        THEN SAFE_CAST(
          start_string
          AS TIMESTAMP
        )


      ELSE TIMESTAMP(

        SAFE_CAST(
          start_string
          AS DATETIME
        ),

        'Asia/Makassar'
      )

    END AS start_timestamp

  FROM neonatal_raw
),


neonatal_meta AS (

  SELECT
    source_system,
    source_event_id,
    source_file_name,


    COALESCE(
      end_timestamp,
      start_timestamp
    ) AS report_timestamp,


    DATE(
      COALESCE(
        end_timestamp,
        start_timestamp
      ),
      'Asia/Makassar'
    ) AS report_date,


    CASE

      WHEN end_timestamp IS NOT NULL
        THEN 'NEONATAL_END_TIMESTAMP'

      WHEN start_timestamp IS NOT NULL
        THEN 'NEONATAL_START_FALLBACK'

      ELSE 'MISSING'

    END AS report_timestamp_source,


    CASE

      WHEN end_timestamp IS NOT NULL
        THEN 'EXACT_TIMESTAMP'

      WHEN start_timestamp IS NOT NULL
        THEN 'FALLBACK_TIMESTAMP'

      ELSE 'MISSING'

    END AS report_timestamp_quality

  FROM neonatal_parsed
),


-- =============================================================================
-- =============================================================================
-- 6. BIRTH REPORT FASKES
-- =============================================================================
-- =============================================================================

tracker_json AS (

  SELECT
    TO_JSON_STRING(t) AS j

  FROM
    `spheres-lombok-barat.birth_report_faskes.v_inc_report_tracker` t
),


tracker_meta AS (

  SELECT

    'INC_REPORT_TRACKER'
      AS source_system,


    CONCAT(

      'INC_REPORT|',

      COALESCE(

        NULLIF(
          JSON_VALUE(
            j,
            '$.row_hash'
          ),
          ''
        ),

        CAST(
          FARM_FINGERPRINT(j)
          AS STRING
        )

      )

    ) AS source_event_id,


    CAST(NULL AS STRING)
      AS source_file_name,


    TIMESTAMP(

      SAFE_CAST(
        JSON_VALUE(
          j,
          '$.date'
        )
        AS DATE
      ),

      'Asia/Makassar'

    ) AS report_timestamp,


    SAFE_CAST(
      JSON_VALUE(
        j,
        '$.date'
      )
      AS DATE
    ) AS report_date,


    CASE

      WHEN SAFE_CAST(
        JSON_VALUE(
          j,
          '$.date'
        )
        AS DATE
      ) IS NOT NULL

        THEN 'BIRTH_REPORT_DATE'

      ELSE 'MISSING'

    END AS report_timestamp_source,


    CASE

      WHEN SAFE_CAST(
        JSON_VALUE(
          j,
          '$.date'
        )
        AS DATE
      ) IS NOT NULL

        THEN 'DATE_ONLY'

      ELSE 'MISSING'

    END AS report_timestamp_quality

  FROM tracker_json
),


-- =============================================================================
-- =============================================================================
-- 7. ALL SOURCE METADATA
-- =============================================================================
-- =============================================================================

source_metadata AS (

  SELECT *
  FROM sigizi_meta


  UNION ALL


  SELECT *
  FROM epus_meta


  UNION ALL


  SELECT *
  FROM simrs_meta


  UNION ALL


  SELECT *
  FROM kobo_meta


  UNION ALL


  SELECT *
  FROM neonatal_meta


  UNION ALL


  SELECT *
  FROM tracker_meta
),


-- =============================================================================
-- 8. ATTACH NATIVE REPORTING METADATA TO CANONICAL DELIVERY MEMBERS
-- =============================================================================

member_reporting AS (

  SELECT

    c.delivery_event_id,

    c.pregnancy_episode_id,

    c.delivery_date,

    c.source_system,

    c.source_subtype,

    c.source_event_id,

    c.source_record_id,


    s.source_file_name,

    s.report_timestamp,

    s.report_date,

    s.report_timestamp_source,

    s.report_timestamp_quality

  FROM canonical_members c

  LEFT JOIN source_metadata s

    ON c.source_system
       = s.source_system

   AND c.source_event_id
       = s.source_event_id
),


-- =============================================================================
-- 9. EARLIEST RAW / VALID / STRICT-NATIVE REPORT
--    PER DELIVERY x SOURCE
-- =============================================================================

source_grouped AS (

  SELECT

    delivery_event_id,

    pregnancy_episode_id,

    delivery_date,

    source_system,


    COUNT(
      DISTINCT source_event_id
    ) AS source_event_count,


    COUNT(
      DISTINCT IF(
        report_date IS NOT NULL,
        source_event_id,
        NULL
      )
    ) AS native_metadata_matched_event_count,


    COUNTIF(
      report_date IS NOT NULL
    ) AS native_report_candidate_count,


    COUNT(
      DISTINCT source_file_name
    ) AS source_file_count,


    -- =========================================================================
    -- FIRST RAW REPORT
    -- =========================================================================

    ARRAY_AGG(

      IF(

        report_date IS NOT NULL,

        STRUCT(

          report_timestamp
            AS report_timestamp,

          report_date
            AS report_date,

          report_timestamp_source
            AS timestamp_source,

          report_timestamp_quality
            AS timestamp_quality,

          source_file_name
            AS source_file_name

        ),

        NULL

      )

      IGNORE NULLS

      ORDER BY
        report_date,
        report_timestamp,
        source_file_name

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS first_raw_pick,


    -- =========================================================================
    -- FIRST VALID REPORT
    --
    -- May include ingestion fallback.
    -- =========================================================================

    ARRAY_AGG(

      IF(

        report_date IS NOT NULL

        AND report_date >= delivery_date,

        STRUCT(

          report_timestamp
            AS report_timestamp,

          report_date
            AS report_date,

          report_timestamp_source
            AS timestamp_source,

          report_timestamp_quality
            AS timestamp_quality,

          source_file_name
            AS source_file_name

        ),

        NULL

      )

      IGNORE NULLS

      ORDER BY
        report_date,
        report_timestamp,
        source_file_name

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS first_valid_pick,


    -- =========================================================================
    -- FIRST STRICT-NATIVE VALID REPORT
    --
    -- Explicitly excludes INGESTION_FALLBACK.
    --
    -- This is the preferred reporting evidence for headline timeliness.
    -- =========================================================================

    ARRAY_AGG(

      IF(

        report_date IS NOT NULL

        AND report_date >= delivery_date

        AND COALESCE(
          report_timestamp_source,
          ''
        ) != 'INGESTION_FALLBACK',

        STRUCT(

          report_timestamp
            AS report_timestamp,

          report_date
            AS report_date,

          report_timestamp_source
            AS timestamp_source,

          report_timestamp_quality
            AS timestamp_quality,

          source_file_name
            AS source_file_name

        ),

        NULL

      )

      IGNORE NULLS

      ORDER BY
        report_date,
        report_timestamp,
        source_file_name

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS first_strict_native_pick


  FROM member_reporting


  GROUP BY

    delivery_event_id,

    pregnancy_episode_id,

    delivery_date,

    source_system
),


-- =============================================================================
-- =============================================================================
-- 10. INDIVIDUAL SOURCE FINAL
-- =============================================================================
-- =============================================================================

source_final AS (

  SELECT

    delivery_event_id,

    pregnancy_episode_id,

    delivery_date,

    source_system,


    CASE source_system

      WHEN 'SIGIZI'
        THEN 'SIGIZI'

      WHEN 'EPUS'
        THEN 'ePuskesmas'

      WHEN 'SIMRS'
        THEN 'SIMRS'

      WHEN 'KOBO_INC'
        THEN 'Kobo INC'

      WHEN 'NEONATAL_OUTCOME'
        THEN 'Neonatal Outcome'

      WHEN 'INC_REPORT_TRACKER'
        THEN 'Birth Report Faskes'

      ELSE source_system

    END AS source_system_display,


    CASE source_system

      WHEN 'INC_REPORT_TRACKER'
        THEN 1

      WHEN 'SIGIZI'
        THEN 2

      WHEN 'EPUS'
        THEN 3

      WHEN 'SIMRS'
        THEN 4

      WHEN 'KOBO_INC'
        THEN 5

      WHEN 'NEONATAL_OUTCOME'
        THEN 6

      ELSE 99

    END AS source_order,


    1 AS source_system_count,


    source_event_count,

    native_metadata_matched_event_count,

    native_report_candidate_count,

    source_file_count,


    -- =========================================================================
    -- FIRST RAW REPORT
    -- =========================================================================

    source_system
      AS first_report_source_system,


    first_raw_pick.report_timestamp
      AS first_report_timestamp,


    first_raw_pick.report_date
      AS first_report_date,


    first_raw_pick.timestamp_source
      AS first_report_timestamp_source,


    first_raw_pick.timestamp_quality
      AS first_report_timestamp_quality,


    first_raw_pick.source_file_name
      AS first_report_source_file_name,


    -- =========================================================================
    -- FIRST VALID REPORT
    -- =========================================================================

    source_system
      AS first_valid_report_source_system,


    first_valid_pick.report_timestamp
      AS first_valid_report_timestamp,


    first_valid_pick.report_date
      AS first_valid_report_date,


    first_valid_pick.timestamp_source
      AS first_valid_report_timestamp_source,


    first_valid_pick.timestamp_quality
      AS first_valid_report_timestamp_quality,


    first_valid_pick.source_file_name
      AS first_valid_report_source_file_name,


    -- =========================================================================
    -- FIRST STRICT-NATIVE REPORT
    -- =========================================================================

    CASE

      WHEN first_strict_native_pick.report_date IS NOT NULL

        THEN source_system

    END
      AS first_strict_native_report_source_system,


    first_strict_native_pick.report_timestamp
      AS first_strict_native_report_timestamp,


    first_strict_native_pick.report_date
      AS first_strict_native_report_date,


    first_strict_native_pick.timestamp_source
      AS first_strict_native_report_timestamp_source,


    first_strict_native_pick.timestamp_quality
      AS first_strict_native_report_timestamp_quality,


    first_strict_native_pick.source_file_name
      AS first_strict_native_report_source_file_name,


    -- =========================================================================
    -- RAW REPORTING DELAY
    -- =========================================================================

    CASE

      WHEN first_raw_pick.report_date IS NOT NULL

      THEN DATE_DIFF(
        first_raw_pick.report_date,
        delivery_date,
        DAY
      )

    END AS raw_reporting_delay_days,


    -- =========================================================================
    -- VALID REPORTING DELAY
    --
    -- May include ingestion fallback.
    -- =========================================================================

    CASE

      WHEN first_valid_pick.report_date IS NOT NULL

      THEN DATE_DIFF(
        first_valid_pick.report_date,
        delivery_date,
        DAY
      )

    END AS reporting_delay_days,


    -- =========================================================================
    -- STRICT-NATIVE REPORTING DELAY
    --
    -- Recommended for headline timeliness.
    -- =========================================================================

    CASE

      WHEN first_strict_native_pick.report_date IS NOT NULL

      THEN DATE_DIFF(
        first_strict_native_pick.report_date,
        delivery_date,
        DAY
      )

    END AS strict_native_reporting_delay_days,


    -- =========================================================================
    -- QA FLAGS
    -- =========================================================================

    (
      first_raw_pick.report_date
        < delivery_date
    ) AS negative_reporting_delay_flag,


    first_raw_pick.report_date IS NULL
      AS report_timestamp_missing_flag,


    first_valid_pick.report_date IS NULL
      AS valid_report_missing_flag,


    first_strict_native_pick.report_date IS NULL
      AS strict_native_report_missing_flag,


    first_valid_pick.report_date IS NOT NULL
      AS timeliness_evaluable_flag,


    first_strict_native_pick.report_date IS NOT NULL
      AS strict_native_timeliness_evaluable_flag,


    1 AS source_capture_count

  FROM source_grouped
),


-- =============================================================================
-- =============================================================================
-- 11. TOTAL ANY SOURCE
-- =============================================================================
-- =============================================================================

total_grouped AS (

  SELECT

    delivery_event_id,

    pregnancy_episode_id,

    delivery_date,


    COUNT(
      DISTINCT source_system
    ) AS source_system_count,


    SUM(
      source_event_count
    ) AS source_event_count,


    SUM(
      native_metadata_matched_event_count
    ) AS native_metadata_matched_event_count,


    SUM(
      native_report_candidate_count
    ) AS native_report_candidate_count,


    SUM(
      source_file_count
    ) AS source_file_count,


    -- =========================================================================
    -- FIRST RAW REPORT FROM ANY SOURCE
    -- =========================================================================

    ARRAY_AGG(

      IF(

        first_report_date IS NOT NULL,

        STRUCT(

          first_report_source_system
            AS report_source_system,

          first_report_timestamp
            AS report_timestamp,

          first_report_date
            AS report_date,

          first_report_timestamp_source
            AS timestamp_source,

          first_report_timestamp_quality
            AS timestamp_quality,

          first_report_source_file_name
            AS source_file_name

        ),

        NULL

      )

      IGNORE NULLS

      ORDER BY
        first_report_date,
        first_report_timestamp,
        first_report_source_system

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS first_raw_pick,


    -- =========================================================================
    -- FIRST VALID REPORT FROM ANY SOURCE
    -- =========================================================================

    ARRAY_AGG(

      IF(

        first_valid_report_date IS NOT NULL,

        STRUCT(

          first_valid_report_source_system
            AS report_source_system,

          first_valid_report_timestamp
            AS report_timestamp,

          first_valid_report_date
            AS report_date,

          first_valid_report_timestamp_source
            AS timestamp_source,

          first_valid_report_timestamp_quality
            AS timestamp_quality,

          first_valid_report_source_file_name
            AS source_file_name

        ),

        NULL

      )

      IGNORE NULLS

      ORDER BY
        first_valid_report_date,
        first_valid_report_timestamp,
        first_valid_report_source_system

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS first_valid_pick,


    -- =========================================================================
    -- FIRST STRICT-NATIVE REPORT FROM ANY SOURCE
    --
    -- Uses the already-derived strict-native report for each source.
    -- =========================================================================

    ARRAY_AGG(

      IF(

        first_strict_native_report_date IS NOT NULL,

        STRUCT(

          first_strict_native_report_source_system
            AS report_source_system,

          first_strict_native_report_timestamp
            AS report_timestamp,

          first_strict_native_report_date
            AS report_date,

          first_strict_native_report_timestamp_source
            AS timestamp_source,

          first_strict_native_report_timestamp_quality
            AS timestamp_quality,

          first_strict_native_report_source_file_name
            AS source_file_name

        ),

        NULL

      )

      IGNORE NULLS

      ORDER BY
        first_strict_native_report_date,
        first_strict_native_report_timestamp,
        first_strict_native_report_source_system

      LIMIT 1

    )[SAFE_OFFSET(0)]
      AS first_strict_native_pick


  FROM source_final


  GROUP BY

    delivery_event_id,

    pregnancy_episode_id,

    delivery_date
),


total_final AS (

  SELECT

    delivery_event_id,

    pregnancy_episode_id,

    delivery_date,


    'TOTAL_ANY_SOURCE'
      AS source_system,


    'Total (Any Source)'
      AS source_system_display,


    0 AS source_order,


    source_system_count,

    source_event_count,

    native_metadata_matched_event_count,

    native_report_candidate_count,

    source_file_count,


    -- =========================================================================
    -- FIRST RAW REPORT
    -- =========================================================================

    first_raw_pick.report_source_system
      AS first_report_source_system,


    first_raw_pick.report_timestamp
      AS first_report_timestamp,


    first_raw_pick.report_date
      AS first_report_date,


    first_raw_pick.timestamp_source
      AS first_report_timestamp_source,


    first_raw_pick.timestamp_quality
      AS first_report_timestamp_quality,


    first_raw_pick.source_file_name
      AS first_report_source_file_name,


    -- =========================================================================
    -- FIRST VALID REPORT
    -- =========================================================================

    first_valid_pick.report_source_system
      AS first_valid_report_source_system,


    first_valid_pick.report_timestamp
      AS first_valid_report_timestamp,


    first_valid_pick.report_date
      AS first_valid_report_date,


    first_valid_pick.timestamp_source
      AS first_valid_report_timestamp_source,


    first_valid_pick.timestamp_quality
      AS first_valid_report_timestamp_quality,


    first_valid_pick.source_file_name
      AS first_valid_report_source_file_name,


    -- =========================================================================
    -- FIRST STRICT-NATIVE REPORT
    -- =========================================================================

    first_strict_native_pick.report_source_system
      AS first_strict_native_report_source_system,


    first_strict_native_pick.report_timestamp
      AS first_strict_native_report_timestamp,


    first_strict_native_pick.report_date
      AS first_strict_native_report_date,


    first_strict_native_pick.timestamp_source
      AS first_strict_native_report_timestamp_source,


    first_strict_native_pick.timestamp_quality
      AS first_strict_native_report_timestamp_quality,


    first_strict_native_pick.source_file_name
      AS first_strict_native_report_source_file_name,


    -- =========================================================================
    -- RAW REPORTING DELAY
    -- =========================================================================

    CASE

      WHEN first_raw_pick.report_date IS NOT NULL

      THEN DATE_DIFF(
        first_raw_pick.report_date,
        delivery_date,
        DAY
      )

    END AS raw_reporting_delay_days,


    -- =========================================================================
    -- VALID REPORTING DELAY
    -- =========================================================================

    CASE

      WHEN first_valid_pick.report_date IS NOT NULL

      THEN DATE_DIFF(
        first_valid_pick.report_date,
        delivery_date,
        DAY
      )

    END AS reporting_delay_days,


    -- =========================================================================
    -- STRICT-NATIVE REPORTING DELAY
    -- =========================================================================

    CASE

      WHEN first_strict_native_pick.report_date IS NOT NULL

      THEN DATE_DIFF(
        first_strict_native_pick.report_date,
        delivery_date,
        DAY
      )

    END AS strict_native_reporting_delay_days,


    -- =========================================================================
    -- QA FLAGS
    -- =========================================================================

    (
      first_raw_pick.report_date
        < delivery_date
    ) AS negative_reporting_delay_flag,


    first_raw_pick.report_date IS NULL
      AS report_timestamp_missing_flag,


    first_valid_pick.report_date IS NULL
      AS valid_report_missing_flag,


    first_strict_native_pick.report_date IS NULL
      AS strict_native_report_missing_flag,


    first_valid_pick.report_date IS NOT NULL
      AS timeliness_evaluable_flag,


    first_strict_native_pick.report_date IS NOT NULL
      AS strict_native_timeliness_evaluable_flag,


    1 AS source_capture_count

  FROM total_grouped
),


-- =============================================================================
-- 12. INDIVIDUAL SOURCES + TOTAL
-- =============================================================================

all_results AS (

  SELECT *
  FROM source_final


  UNION ALL


  SELECT *
  FROM total_final
)


-- =============================================================================
-- =============================================================================
-- FINAL OUTPUT
-- =============================================================================
-- =============================================================================

SELECT
  *,


  -- ===========================================================================
  -- STANDARD DELAY CATEGORY
  --
  -- May include fallback reporting metadata.
  -- ===========================================================================

  CASE

    WHEN reporting_delay_days IS NULL
      THEN 'UNKNOWN'

    WHEN reporting_delay_days = 0
      THEN 'H+0'

    WHEN reporting_delay_days = 1
      THEN 'H+1'

    WHEN reporting_delay_days = 2
      THEN 'H+2'

    WHEN reporting_delay_days = 3
      THEN 'H+3'

    WHEN reporting_delay_days = 4
      THEN 'H+4'

    WHEN reporting_delay_days = 5
      THEN 'H+5'

    WHEN reporting_delay_days = 6
      THEN 'H+6'

    WHEN reporting_delay_days = 7
      THEN 'H+7'

    WHEN reporting_delay_days BETWEEN 8 AND 14
      THEN 'H+8–H+14'

    WHEN reporting_delay_days BETWEEN 15 AND 30
      THEN 'H+15–H+30'

    WHEN reporting_delay_days > 30
      THEN '>H+30'

  END AS reporting_delay_group,


  CASE

    WHEN reporting_delay_days = 0
      THEN 1

    WHEN reporting_delay_days = 1
      THEN 2

    WHEN reporting_delay_days = 2
      THEN 3

    WHEN reporting_delay_days = 3
      THEN 4

    WHEN reporting_delay_days = 4
      THEN 5

    WHEN reporting_delay_days = 5
      THEN 6

    WHEN reporting_delay_days = 6
      THEN 7

    WHEN reporting_delay_days = 7
      THEN 8

    WHEN reporting_delay_days BETWEEN 8 AND 14
      THEN 9

    WHEN reporting_delay_days BETWEEN 15 AND 30
      THEN 10

    WHEN reporting_delay_days > 30
      THEN 11

    ELSE 99

  END AS reporting_delay_group_order,


  -- ===========================================================================
  -- STRICT-NATIVE DELAY CATEGORY
  --
  -- Recommended for headline timeliness.
  -- ===========================================================================

  CASE

    WHEN strict_native_reporting_delay_days IS NULL
      THEN 'UNKNOWN'

    WHEN strict_native_reporting_delay_days = 0
      THEN 'H+0'

    WHEN strict_native_reporting_delay_days = 1
      THEN 'H+1'

    WHEN strict_native_reporting_delay_days = 2
      THEN 'H+2'

    WHEN strict_native_reporting_delay_days = 3
      THEN 'H+3'

    WHEN strict_native_reporting_delay_days = 4
      THEN 'H+4'

    WHEN strict_native_reporting_delay_days = 5
      THEN 'H+5'

    WHEN strict_native_reporting_delay_days = 6
      THEN 'H+6'

    WHEN strict_native_reporting_delay_days = 7
      THEN 'H+7'

    WHEN strict_native_reporting_delay_days
         BETWEEN 8 AND 14
      THEN 'H+8–H+14'

    WHEN strict_native_reporting_delay_days
         BETWEEN 15 AND 30
      THEN 'H+15–H+30'

    WHEN strict_native_reporting_delay_days > 30
      THEN '>H+30'

  END AS strict_native_reporting_delay_group,


  CASE

    WHEN strict_native_reporting_delay_days = 0
      THEN 1

    WHEN strict_native_reporting_delay_days = 1
      THEN 2

    WHEN strict_native_reporting_delay_days = 2
      THEN 3

    WHEN strict_native_reporting_delay_days = 3
      THEN 4

    WHEN strict_native_reporting_delay_days = 4
      THEN 5

    WHEN strict_native_reporting_delay_days = 5
      THEN 6

    WHEN strict_native_reporting_delay_days = 6
      THEN 7

    WHEN strict_native_reporting_delay_days = 7
      THEN 8

    WHEN strict_native_reporting_delay_days
         BETWEEN 8 AND 14
      THEN 9

    WHEN strict_native_reporting_delay_days
         BETWEEN 15 AND 30
      THEN 10

    WHEN strict_native_reporting_delay_days > 30
      THEN 11

    ELSE 99

  END AS strict_native_reporting_delay_group_order,


  -- ===========================================================================
  -- STANDARD TIMELINESS COUNTS
  -- ===========================================================================

  CAST(
    reporting_delay_days = 0
    AS INT64
  ) AS reported_h0_count,


  CAST(
    reporting_delay_days BETWEEN 0 AND 1
    AS INT64
  ) AS reported_by_h1_count,


  CAST(
    reporting_delay_days BETWEEN 0 AND 3
    AS INT64
  ) AS reported_by_h3_count,


  CAST(
    reporting_delay_days BETWEEN 0 AND 7
    AS INT64
  ) AS reported_by_h7_count,


  CAST(
    reporting_delay_days BETWEEN 0 AND 14
    AS INT64
  ) AS reported_by_h14_count,


  CAST(
    reporting_delay_days BETWEEN 0 AND 30
    AS INT64
  ) AS reported_by_h30_count,


  -- ===========================================================================
  -- STRICT-NATIVE DENOMINATOR
  -- ===========================================================================

  CAST(
    strict_native_timeliness_evaluable_flag
    AS INT64
  ) AS strict_native_timeliness_evaluable_count,


  -- ===========================================================================
  -- STRICT-NATIVE CUMULATIVE TIMELINESS COUNTS
  -- ===========================================================================

  CAST(
    strict_native_reporting_delay_days = 0
    AS INT64
  ) AS strict_native_reported_h0_count,


  CAST(
    strict_native_reporting_delay_days
      BETWEEN 0 AND 1
    AS INT64
  ) AS strict_native_reported_by_h1_count,


  CAST(
    strict_native_reporting_delay_days
      BETWEEN 0 AND 3
    AS INT64
  ) AS strict_native_reported_by_h3_count,


  CAST(
    strict_native_reporting_delay_days
      BETWEEN 0 AND 7
    AS INT64
  ) AS strict_native_reported_by_h7_count,


  CAST(
    strict_native_reporting_delay_days
      BETWEEN 0 AND 14
    AS INT64
  ) AS strict_native_reported_by_h14_count,


  CAST(
    strict_native_reporting_delay_days
      BETWEEN 0 AND 30
    AS INT64
  ) AS strict_native_reported_by_h30_count


FROM all_results