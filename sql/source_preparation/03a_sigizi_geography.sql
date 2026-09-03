-- RECURRING: run immediately after PREP 03_sigizi_source.sql and before CORE 10.
-- Run as a separate complete job. No v2 runtime dependency.
-- Restores the recovered resolver's decisions, including AMBIGUOUS/LOW acceptance.
-- Source schema is preserved; originals and decisions are stored in the audit table.
-- ============================================================================
-- SIGIZI LOCATION RESOLVER v1
--
-- PURPOSE
--   Resolve Puskesmas / Desa / Posyandu coherently across the five SIGIZI
--   source families without globally shifting fields.
--
-- INPUTS
--   t_sigizi_source_records
--   t_sigizi_location_reference
--
-- OUTPUT
--   t_sigizi_location_resolved_v1
--
-- IMPORTANT
--   This does NOT overwrite t_sigizi_source_records yet.
--   Review the QA outputs first.
-- ============================================================================


CREATE TEMP FUNCTION norm_loc(s STRING)
RETURNS STRING
AS (
  CASE
    WHEN NULLIF(
      REGEXP_REPLACE(
        UPPER(TRIM(NORMALIZE(COALESCE(s, ''), NFKC))),
        r'\s+',
        ' '
      ),
      ''
    ) IN ('GUNUNGSARI', 'GUNUNG SARI')
      THEN 'GUNUNG SARI'

    WHEN NULLIF(
      REGEXP_REPLACE(
        UPPER(TRIM(NORMALIZE(COALESCE(s, ''), NFKC))),
        r'\s+',
        ' '
      ),
      ''
    ) IN ('LABUAPI', 'LABU API')
      THEN 'LABU API'

    WHEN NULLIF(
      REGEXP_REPLACE(
        UPPER(TRIM(NORMALIZE(COALESCE(s, ''), NFKC))),
        r'\s+',
        ' '
      ),
      ''
    ) IN ('PEREMPUAN', 'PERAMPUAN')
      THEN 'PERAMPUAN'

    ELSE NULLIF(
      REGEXP_REPLACE(
        UPPER(TRIM(NORMALIZE(COALESCE(s, ''), NFKC))),
        r'\s+',
        ' '
      ),
      ''
    )
  END
);


-- ============================================================================
-- Guard the source grain before the recovered resolver's joins.
CREATE TEMP TABLE geo_input AS SELECT * FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_source_records`;
ASSERT NOT EXISTS (
  SELECT 1 FROM geo_input
  WHERE NULLIF(TRIM(source_table), '') IS NULL
     OR NULLIF(TRIM(source_record_id), '') IS NULL
) AS 'Missing SIGIZI source key; stop before geography joins.';
ASSERT NOT EXISTS (
  SELECT 1 FROM geo_input GROUP BY source_table, source_record_id HAVING COUNT(*) > 1
) AS 'Duplicate SIGIZI source key; stop before geography joins.';
ASSERT NOT EXISTS (
  SELECT 1 FROM geo_input WHERE source_table NOT IN
    ('ANC','DAFTAR_IBU_HAMIL','KOHORT_IBU','DAFTAR_IBU','KOHORT_NIFAS')
) AS 'Unexpected SIGIZI source family; resolver must be reviewed.';
ASSERT (SELECT COUNT(*) > 0 FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_location_reference`)
AS 'Location reference is empty.';

-- 1. TRUSTED REFERENCE
-- ============================================================================

CREATE TEMP TABLE ref_location AS
SELECT DISTINCT
  norm_loc(puskesmas_norm) AS puskesmas_norm,
  norm_loc(desa_norm) AS desa_norm,
  norm_loc(posyandu_norm) AS posyandu_norm
FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_location_reference`
WHERE puskesmas_norm IS NOT NULL;


CREATE TEMP TABLE ref_puskesmas AS
SELECT DISTINCT puskesmas_norm
FROM ref_location
WHERE puskesmas_norm IS NOT NULL;


CREATE TEMP TABLE ref_pkm_desa AS
SELECT DISTINCT
  puskesmas_norm,
  desa_norm
FROM ref_location
WHERE
  puskesmas_norm IS NOT NULL
  AND desa_norm IS NOT NULL;


CREATE TEMP TABLE ref_pkm_desa_pos AS
SELECT DISTINCT
  puskesmas_norm,
  desa_norm,
  posyandu_norm
FROM ref_location
WHERE
  puskesmas_norm IS NOT NULL
  AND desa_norm IS NOT NULL
  AND posyandu_norm IS NOT NULL;


CREATE TEMP TABLE ref_unique_desa_parent AS
SELECT
  desa_norm,

  COUNT(DISTINCT puskesmas_norm)
    AS parent_puskesmas_count,

  ARRAY_AGG(
    DISTINCT puskesmas_norm
    ORDER BY puskesmas_norm
    LIMIT 1
  )[SAFE_OFFSET(0)] AS unique_parent_puskesmas

FROM ref_pkm_desa

GROUP BY desa_norm;


-- ============================================================================
-- 2. PARSE SOURCE-SPECIFIC RAW LOCATION FIELDS
-- ============================================================================

CREATE TEMP TABLE parsed AS
SELECT
  s.source_table,
  s.source_record_id,

  norm_loc(s.puskesmas) AS current_puskesmas_norm,
  norm_loc(s.desa) AS current_desa_norm,
  norm_loc(s.posyandu) AS current_posyandu_norm,

  CASE
    WHEN REGEXP_CONTAINS(
      UPPER(
        TRIM(
          COALESCE(
            JSON_VALUE(s.source_json, '$.puskesmas_name'),
            ''
          )
        )
      ),
      r'^PUSKESMAS\s+'
    )
    THEN norm_loc(
      REGEXP_REPLACE(
        TRIM(JSON_VALUE(s.source_json, '$.puskesmas_name')),
        r'(?i)^Puskesmas\s+',
        ''
      )
    )
  END AS metadata_puskesmas_norm,

  CASE
    WHEN s.source_table = 'ANC'
      THEN norm_loc(
        JSON_VALUE(s.source_json, '$.puskesmas_domisili')
      )

    WHEN s.source_table = 'KOHORT_IBU'
      THEN norm_loc(
        JSON_VALUE(s.source_json, '$.pukesmas')
      )

    ELSE norm_loc(
      JSON_VALUE(s.source_json, '$.puskesmas')
    )
  END AS raw_puskesmas_norm,

  CASE
    WHEN s.source_table = 'ANC'
      THEN norm_loc(
        JSON_VALUE(s.source_json, '$.desakel_domisili')
      )

    ELSE norm_loc(
      JSON_VALUE(s.source_json, '$.desakel')
    )
  END AS raw_desa_norm,

  CASE
    WHEN s.source_table = 'ANC'
      THEN norm_loc(
        JSON_VALUE(s.source_json, '$.posyandu_domisili')
      )

    ELSE norm_loc(
      JSON_VALUE(s.source_json, '$.posyandu')
    )
  END AS raw_posyandu_norm,

  s.source_json

FROM
  _SESSION.geo_input s;


-- ============================================================================
-- 3. DIRECT CLEAN SOURCES
-- ============================================================================

CREATE TEMP TABLE clean_source_resolution AS
SELECT
  p.source_table,
  p.source_record_id,

  p.raw_puskesmas_norm AS resolved_puskesmas_norm,
  p.raw_desa_norm AS resolved_desa_norm,
  p.raw_posyandu_norm AS resolved_posyandu_norm,

  CONCAT('DIRECT_', p.source_table)
    AS location_resolution_method,

  'VERY_HIGH' AS location_resolution_confidence,

  500 AS location_resolution_score,

  1 AS best_score_candidate_count

FROM parsed p

WHERE p.source_table IN (
  'ANC',
  'DAFTAR_IBU_HAMIL',
  'KOHORT_IBU'
);


-- ============================================================================
-- 4. CANDIDATES FOR DAFTAR_IBU + KOHORT_NIFAS
-- ============================================================================

CREATE TEMP TABLE candidate_resolution AS

-- A. Valid facility metadata + raw desa interpreted directly
SELECT
  p.source_table,
  p.source_record_id,

  'META_PKM+RAW_DESA' AS candidate_method,

  p.metadata_puskesmas_norm AS candidate_puskesmas_norm,
  p.raw_desa_norm AS candidate_desa_norm,
  p.raw_posyandu_norm AS candidate_posyandu_norm,

  300
  + IF(
      EXISTS (
        SELECT 1
        FROM ref_pkm_desa r
        WHERE r.puskesmas_norm = p.metadata_puskesmas_norm
          AND r.desa_norm = p.raw_desa_norm
      ),
      100,
      0
    )
  + IF(
      EXISTS (
        SELECT 1
        FROM ref_pkm_desa_pos r
        WHERE r.puskesmas_norm = p.metadata_puskesmas_norm
          AND r.desa_norm = p.raw_desa_norm
          AND r.posyandu_norm = p.raw_posyandu_norm
      ),
      40,
      0
    ) AS candidate_score

FROM parsed p

WHERE
  p.source_table IN ('DAFTAR_IBU', 'KOHORT_NIFAS')
  AND p.metadata_puskesmas_norm IS NOT NULL
  AND EXISTS (
    SELECT 1
    FROM ref_puskesmas r
    WHERE r.puskesmas_norm = p.metadata_puskesmas_norm
  )


UNION ALL


-- B. Valid facility metadata + raw puskesmas field interpreted as desa
SELECT
  p.source_table,
  p.source_record_id,

  'META_PKM+SHIFTED_DESA' AS candidate_method,

  p.metadata_puskesmas_norm AS candidate_puskesmas_norm,
  p.raw_puskesmas_norm AS candidate_desa_norm,

  CASE
    WHEN EXISTS (
      SELECT 1
      FROM ref_pkm_desa_pos r
      WHERE r.puskesmas_norm = p.metadata_puskesmas_norm
        AND r.desa_norm = p.raw_puskesmas_norm
        AND r.posyandu_norm = p.raw_desa_norm
    )
      THEN p.raw_desa_norm

    WHEN EXISTS (
      SELECT 1
      FROM ref_pkm_desa_pos r
      WHERE r.puskesmas_norm = p.metadata_puskesmas_norm
        AND r.desa_norm = p.raw_puskesmas_norm
        AND r.posyandu_norm = p.raw_posyandu_norm
    )
      THEN p.raw_posyandu_norm

    ELSE NULL
  END AS candidate_posyandu_norm,

  300
  + 120
  + IF(
      EXISTS (
        SELECT 1
        FROM ref_pkm_desa_pos r
        WHERE r.puskesmas_norm = p.metadata_puskesmas_norm
          AND r.desa_norm = p.raw_puskesmas_norm
          AND r.posyandu_norm = p.raw_desa_norm
      ),
      60,
      0
    ) AS candidate_score

FROM parsed p

WHERE
  p.source_table IN ('DAFTAR_IBU', 'KOHORT_NIFAS')
  AND p.metadata_puskesmas_norm IS NOT NULL
  AND EXISTS (
    SELECT 1
    FROM ref_pkm_desa r
    WHERE r.puskesmas_norm = p.metadata_puskesmas_norm
      AND r.desa_norm = p.raw_puskesmas_norm
  )


UNION ALL


-- C. Generic fields interpreted directly
SELECT
  p.source_table,
  p.source_record_id,

  'RAW_DIRECT' AS candidate_method,

  p.raw_puskesmas_norm AS candidate_puskesmas_norm,
  p.raw_desa_norm AS candidate_desa_norm,
  p.raw_posyandu_norm AS candidate_posyandu_norm,

  200
  + 50
  + IF(
      EXISTS (
        SELECT 1
        FROM ref_pkm_desa r
        WHERE r.puskesmas_norm = p.raw_puskesmas_norm
          AND r.desa_norm = p.raw_desa_norm
      ),
      120,
      0
    )
  + IF(
      EXISTS (
        SELECT 1
        FROM ref_pkm_desa_pos r
        WHERE r.puskesmas_norm = p.raw_puskesmas_norm
          AND r.desa_norm = p.raw_desa_norm
          AND r.posyandu_norm = p.raw_posyandu_norm
      ),
      50,
      0
    ) AS candidate_score

FROM parsed p

WHERE
  p.source_table IN ('DAFTAR_IBU', 'KOHORT_NIFAS')
  AND p.raw_puskesmas_norm IS NOT NULL
  AND EXISTS (
    SELECT 1
    FROM ref_puskesmas r
    WHERE r.puskesmas_norm = p.raw_puskesmas_norm
  )


UNION ALL


-- D. Generic puskesmas field interpreted as desa; infer unique parent PKM
SELECT
  p.source_table,
  p.source_record_id,

  'RAW_SHIFTED_UNIQUE_DESA_PARENT' AS candidate_method,

  d.unique_parent_puskesmas AS candidate_puskesmas_norm,
  p.raw_puskesmas_norm AS candidate_desa_norm,

  CASE
    WHEN EXISTS (
      SELECT 1
      FROM ref_pkm_desa_pos r
      WHERE r.puskesmas_norm = d.unique_parent_puskesmas
        AND r.desa_norm = p.raw_puskesmas_norm
        AND r.posyandu_norm = p.raw_desa_norm
    )
      THEN p.raw_desa_norm

    WHEN EXISTS (
      SELECT 1
      FROM ref_pkm_desa_pos r
      WHERE r.puskesmas_norm = d.unique_parent_puskesmas
        AND r.desa_norm = p.raw_puskesmas_norm
        AND r.posyandu_norm = p.raw_posyandu_norm
    )
      THEN p.raw_posyandu_norm

    ELSE NULL
  END AS candidate_posyandu_norm,

  220
  + IF(
      EXISTS (
        SELECT 1
        FROM ref_pkm_desa_pos r
        WHERE r.puskesmas_norm = d.unique_parent_puskesmas
          AND r.desa_norm = p.raw_puskesmas_norm
          AND r.posyandu_norm = p.raw_desa_norm
      ),
      100,
      0
    )
  + IF(
      p.metadata_puskesmas_norm = d.unique_parent_puskesmas,
      100,
      0
    ) AS candidate_score

FROM parsed p

JOIN ref_unique_desa_parent d
  ON d.desa_norm = p.raw_puskesmas_norm
 AND d.parent_puskesmas_count = 1

WHERE
  p.source_table IN ('DAFTAR_IBU', 'KOHORT_NIFAS');


-- ============================================================================
-- 5. RANK CANDIDATES
-- ============================================================================

CREATE TEMP TABLE candidate_with_best AS
SELECT
  c.*,

  MAX(candidate_score) OVER (
    PARTITION BY source_table, source_record_id
  ) AS best_score

FROM candidate_resolution c;


CREATE TEMP TABLE ranked_candidates AS
SELECT
  c.*,

  COUNTIF(candidate_score = best_score) OVER (
    PARTITION BY source_table, source_record_id
  ) AS best_score_candidate_count

FROM candidate_with_best c;


CREATE TEMP TABLE best_problematic AS
SELECT
  source_table,
  source_record_id,

  candidate_puskesmas_norm
    AS resolved_puskesmas_norm,

  candidate_desa_norm
    AS resolved_desa_norm,

  candidate_posyandu_norm
    AS resolved_posyandu_norm,

  candidate_method
    AS location_resolution_method,

  CASE
    WHEN best_score_candidate_count > 1
      THEN 'AMBIGUOUS'

    WHEN candidate_score >= 400
      THEN 'VERY_HIGH'

    WHEN candidate_score >= 320
      THEN 'HIGH'

    WHEN candidate_score >= 250
      THEN 'MEDIUM'

    ELSE 'LOW'
  END AS location_resolution_confidence,

  candidate_score AS location_resolution_score,

  best_score_candidate_count

FROM ranked_candidates

WHERE candidate_score = best_score

QUALIFY
  ROW_NUMBER() OVER (
    PARTITION BY source_table, source_record_id
    ORDER BY
      candidate_score DESC,
      candidate_method
  ) = 1;


-- ============================================================================
-- 6. FINAL RESOLVER TABLE
-- ============================================================================

CREATE TEMP TABLE geo_resolved
CLUSTER BY
  source_table,
  resolved_puskesmas_norm,
  resolved_desa_norm
AS

SELECT
  p.source_table,
  p.source_record_id,

  p.current_puskesmas_norm,
  p.current_desa_norm,
  p.current_posyandu_norm,

  p.metadata_puskesmas_norm,
  p.raw_puskesmas_norm,
  p.raw_desa_norm,
  p.raw_posyandu_norm,

  COALESCE(
    c.resolved_puskesmas_norm,
    b.resolved_puskesmas_norm
  ) AS resolved_puskesmas_norm,

  COALESCE(
    c.resolved_desa_norm,
    b.resolved_desa_norm
  ) AS resolved_desa_norm,

  COALESCE(
    c.resolved_posyandu_norm,
    b.resolved_posyandu_norm
  ) AS resolved_posyandu_norm,

  COALESCE(
    c.location_resolution_method,
    b.location_resolution_method,
    'UNRESOLVED'
  ) AS location_resolution_method,

  COALESCE(
    c.location_resolution_confidence,
    b.location_resolution_confidence,
    'UNRESOLVED'
  ) AS location_resolution_confidence,

  COALESCE(
    c.location_resolution_score,
    b.location_resolution_score
  ) AS location_resolution_score,

  COALESCE(
    c.best_score_candidate_count,
    b.best_score_candidate_count,
    0
  ) AS best_score_candidate_count,

  (
    COALESCE(
      c.resolved_puskesmas_norm,
      b.resolved_puskesmas_norm
    )
    IS DISTINCT FROM p.current_puskesmas_norm
  ) AS puskesmas_changed_flag,

  (
    COALESCE(
      c.resolved_desa_norm,
      b.resolved_desa_norm
    )
    IS DISTINCT FROM p.current_desa_norm
  ) AS desa_changed_flag,

  (
    COALESCE(
      c.resolved_posyandu_norm,
      b.resolved_posyandu_norm
    )
    IS DISTINCT FROM p.current_posyandu_norm
  ) AS posyandu_changed_flag

FROM parsed p

LEFT JOIN clean_source_resolution c
  USING (source_table, source_record_id)

LEFT JOIN best_problematic b
  USING (source_table, source_record_id);


-- ============================================================================

ASSERT NOT EXISTS (
  SELECT 1 FROM geo_resolved GROUP BY source_table, source_record_id HAVING COUNT(*) > 1
) AS 'Resolver multiplied source keys; do not publish.';
ASSERT (SELECT COUNT(*) FROM geo_resolved) = (SELECT COUNT(*) FROM geo_input)
AS 'Resolver row count differs from source.';

CREATE TEMP TABLE geo_corrected AS
SELECT s.* REPLACE (
  CASE WHEN r.location_resolution_confidence != 'UNRESOLVED'
    THEN r.resolved_puskesmas_norm ELSE NULL END AS puskesmas,
  CASE WHEN r.location_resolution_confidence != 'UNRESOLVED'
    THEN r.resolved_puskesmas_norm ELSE NULL END AS puskesmas_norm,
  CASE WHEN r.location_resolution_confidence != 'UNRESOLVED'
    THEN r.resolved_desa_norm ELSE NULL END AS desa,
  CASE WHEN r.location_resolution_confidence != 'UNRESOLVED'
    THEN r.resolved_desa_norm ELSE NULL END AS desa_norm,
  CASE WHEN r.location_resolution_confidence != 'UNRESOLVED'
    THEN r.resolved_posyandu_norm ELSE NULL END AS posyandu
)
FROM geo_input s
LEFT JOIN geo_resolved r USING(source_table, source_record_id);

ASSERT (SELECT COUNT(*) FROM geo_corrected) = (SELECT COUNT(*) FROM geo_input)
AS 'Corrected source row count differs from input.';

-- Exact multiset comparison of all non-geography fields, including source_json.
ASSERT NOT EXISTS (
  WITH old_values AS (
    SELECT TO_JSON_STRING((SELECT AS STRUCT s.* EXCEPT(
      puskesmas,puskesmas_norm,desa,desa_norm,posyandu))) AS row_json,
      COUNT(*) AS n FROM geo_input s GROUP BY row_json
  ), new_values AS (
    SELECT TO_JSON_STRING((SELECT AS STRUCT s.* EXCEPT(
      puskesmas,puskesmas_norm,desa,desa_norm,posyandu))) AS row_json,
      COUNT(*) AS n FROM geo_corrected s GROUP BY row_json
  )
  SELECT 1 FROM old_values a FULL OUTER JOIN new_values b USING(row_json)
  WHERE IFNULL(a.n,0) != IFNULL(b.n,0)
) AS 'Non-geography fields changed; do not publish.';

-- Persist raw originals and resolution diagnostics separately: no extra source columns.
CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_location_resolved_v1`
CLUSTER BY source_table, resolved_puskesmas_norm, resolved_desa_norm AS
SELECT r.*, s.puskesmas AS puskesmas_original,
  s.puskesmas_norm AS puskesmas_norm_original,
  s.desa AS desa_original, s.desa_norm AS desa_norm_original,
  s.posyandu AS posyandu_original,
  CURRENT_TIMESTAMP() AS resolver_refreshed_at
FROM geo_resolved r JOIN geo_input s USING(source_table,source_record_id);

-- Publish only after the structural checks above pass.
CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_source_records`
CLUSTER BY source_table, nik_clean AS SELECT * FROM geo_corrected;

SELECT source_table,location_resolution_method,location_resolution_confidence,
  COUNT(*) AS source_record_count,
  COUNTIF(puskesmas_changed_flag) AS puskesmas_changed,
  COUNTIF(desa_changed_flag) AS desa_changed,
  COUNTIF(posyandu_changed_flag) AS posyandu_changed
FROM geo_resolved
GROUP BY source_table,location_resolution_method,location_resolution_confidence
ORDER BY source_table,source_record_count DESC;

SELECT COUNT(*) AS source_record_count,
  COUNTIF(puskesmas IS NULL) AS null_puskesmas_count,
  COUNT(DISTINCT puskesmas) AS distinct_puskesmas_count
FROM geo_corrected;
