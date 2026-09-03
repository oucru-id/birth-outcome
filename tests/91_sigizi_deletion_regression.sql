-- Synthetic fixtures only; no production tables read or written.
CREATE TEMP FUNCTION deletion_name_key(value STRING) AS (
  NULLIF(TRIM(REGEXP_REPLACE(
    REGEXP_REPLACE(NORMALIZE_AND_CASEFOLD(COALESCE(value, '')),
      r'[^a-z0-9 ]', ' '), r'\s+', ' ')), '')
);

CREATE TEMP FUNCTION deletion_match_rule(
  s_nik STRING, s_name STRING, s_dob DATE, s_anchor DATE,
  d_nik STRING, d_name STRING, d_dob DATE, d_anchor DATE
) RETURNS STRING AS (
  CASE
    WHEN s_anchor IS NULL OR d_anchor IS NULL OR s_anchor != d_anchor
      THEN NULL
    WHEN s_nik IS NOT NULL AND d_nik IS NOT NULL AND s_nik = d_nik
      THEN 'NIK_AND_PREGNANCY_ANCHOR'
    WHEN (s_nik IS NULL OR d_nik IS NULL)
      AND s_name IS NOT NULL AND d_name IS NOT NULL AND s_name = d_name
      AND s_dob IS NOT NULL AND d_dob IS NOT NULL AND s_dob = d_dob
      THEN 'NAME_DOB_AND_PREGNANCY_ANCHOR'
    ELSE NULL
  END
);

CREATE TEMP TABLE deletion_test_results AS
WITH fixtures AS (
SELECT "exact_nik_and_anchor" AS test_name, CAST("1111222233334444" AS STRING) AS s_nik, CAST("synthetic mother" AS STRING) AS s_name, CAST("1990-01-01" AS DATE) AS s_dob, CAST("2025-12-01" AS DATE) AS s_anchor, CAST("1111222233334444" AS STRING) AS d_nik, CAST("synthetic mother" AS STRING) AS d_name, CAST("1990-01-01" AS DATE) AS d_dob, CAST("2025-12-01" AS DATE) AS d_anchor, CAST("NIK_AND_PREGNANCY_ANCHOR" AS STRING) AS expected
UNION ALL SELECT "same_mother_other_pregnancy" AS test_name, CAST("1111222233334444" AS STRING) AS s_nik, CAST("synthetic mother" AS STRING) AS s_name, CAST("1990-01-01" AS DATE) AS s_dob, CAST("2026-12-01" AS DATE) AS s_anchor, CAST("1111222233334444" AS STRING) AS d_nik, CAST("synthetic mother" AS STRING) AS d_name, CAST("1990-01-01" AS DATE) AS d_dob, CAST("2025-12-01" AS DATE) AS d_anchor, CAST(NULL AS STRING) AS expected
UNION ALL SELECT "no_fuzzy_date_matching" AS test_name, CAST("1111222233334444" AS STRING) AS s_nik, CAST("synthetic mother" AS STRING) AS s_name, CAST("1990-01-01" AS DATE) AS s_dob, CAST("2025-12-02" AS DATE) AS s_anchor, CAST("1111222233334444" AS STRING) AS d_nik, CAST("synthetic mother" AS STRING) AS d_name, CAST("1990-01-01" AS DATE) AS d_dob, CAST("2025-12-01" AS DATE) AS d_anchor, CAST(NULL AS STRING) AS expected
UNION ALL SELECT "missing_source_anchor" AS test_name, CAST("1111222233334444" AS STRING) AS s_nik, CAST("synthetic mother" AS STRING) AS s_name, CAST("1990-01-01" AS DATE) AS s_dob, CAST(NULL AS DATE) AS s_anchor, CAST("1111222233334444" AS STRING) AS d_nik, CAST("synthetic mother" AS STRING) AS d_name, CAST("1990-01-01" AS DATE) AS d_dob, CAST("2025-12-01" AS DATE) AS d_anchor, CAST(NULL AS STRING) AS expected
UNION ALL SELECT "missing_registry_anchor" AS test_name, CAST("1111222233334444" AS STRING) AS s_nik, CAST("synthetic mother" AS STRING) AS s_name, CAST("1990-01-01" AS DATE) AS s_dob, CAST("2025-12-01" AS DATE) AS s_anchor, CAST("1111222233334444" AS STRING) AS d_nik, CAST("synthetic mother" AS STRING) AS d_name, CAST("1990-01-01" AS DATE) AS d_dob, CAST(NULL AS DATE) AS d_anchor, CAST(NULL AS STRING) AS expected
UNION ALL SELECT "both_anchors_missing" AS test_name, CAST("1111222233334444" AS STRING) AS s_nik, CAST("synthetic mother" AS STRING) AS s_name, CAST("1990-01-01" AS DATE) AS s_dob, CAST(NULL AS DATE) AS s_anchor, CAST("1111222233334444" AS STRING) AS d_nik, CAST("synthetic mother" AS STRING) AS d_name, CAST("1990-01-01" AS DATE) AS d_dob, CAST(NULL AS DATE) AS d_anchor, CAST(NULL AS STRING) AS expected
UNION ALL SELECT "source_nik_missing" AS test_name, CAST(NULL AS STRING) AS s_nik, CAST("synthetic mother" AS STRING) AS s_name, CAST("1990-01-01" AS DATE) AS s_dob, CAST("2025-12-01" AS DATE) AS s_anchor, CAST("1111222233334444" AS STRING) AS d_nik, CAST("synthetic mother" AS STRING) AS d_name, CAST("1990-01-01" AS DATE) AS d_dob, CAST("2025-12-01" AS DATE) AS d_anchor, CAST("NAME_DOB_AND_PREGNANCY_ANCHOR" AS STRING) AS expected
UNION ALL SELECT "registry_nik_missing" AS test_name, CAST("1111222233334444" AS STRING) AS s_nik, CAST("synthetic mother" AS STRING) AS s_name, CAST("1990-01-01" AS DATE) AS s_dob, CAST("2025-12-01" AS DATE) AS s_anchor, CAST(NULL AS STRING) AS d_nik, CAST("synthetic mother" AS STRING) AS d_name, CAST("1990-01-01" AS DATE) AS d_dob, CAST("2025-12-01" AS DATE) AS d_anchor, CAST("NAME_DOB_AND_PREGNANCY_ANCHOR" AS STRING) AS expected
UNION ALL SELECT "both_niks_missing" AS test_name, CAST(NULL AS STRING) AS s_nik, CAST("synthetic mother" AS STRING) AS s_name, CAST("1990-01-01" AS DATE) AS s_dob, CAST("2025-12-01" AS DATE) AS s_anchor, CAST(NULL AS STRING) AS d_nik, CAST("synthetic mother" AS STRING) AS d_name, CAST("1990-01-01" AS DATE) AS d_dob, CAST("2025-12-01" AS DATE) AS d_anchor, CAST("NAME_DOB_AND_PREGNANCY_ANCHOR" AS STRING) AS expected
UNION ALL SELECT "conflicting_usable_niks" AS test_name, CAST("1111222233334444" AS STRING) AS s_nik, CAST("synthetic mother" AS STRING) AS s_name, CAST("1990-01-01" AS DATE) AS s_dob, CAST("2025-12-01" AS DATE) AS s_anchor, CAST("5555666677778888" AS STRING) AS d_nik, CAST("synthetic mother" AS STRING) AS d_name, CAST("1990-01-01" AS DATE) AS d_dob, CAST("2025-12-01" AS DATE) AS d_anchor, CAST(NULL AS STRING) AS expected
UNION ALL SELECT "fallback_wrong_birth_date" AS test_name, CAST(NULL AS STRING) AS s_nik, CAST("synthetic mother" AS STRING) AS s_name, CAST("1991-01-01" AS DATE) AS s_dob, CAST("2025-12-01" AS DATE) AS s_anchor, CAST("1111222233334444" AS STRING) AS d_nik, CAST("synthetic mother" AS STRING) AS d_name, CAST("1990-01-01" AS DATE) AS d_dob, CAST("2025-12-01" AS DATE) AS d_anchor, CAST(NULL AS STRING) AS expected
UNION ALL SELECT "fallback_missing_birth_date" AS test_name, CAST(NULL AS STRING) AS s_nik, CAST("synthetic mother" AS STRING) AS s_name, CAST(NULL AS DATE) AS s_dob, CAST("2025-12-01" AS DATE) AS s_anchor, CAST("1111222233334444" AS STRING) AS d_nik, CAST("synthetic mother" AS STRING) AS d_name, CAST("1990-01-01" AS DATE) AS d_dob, CAST("2025-12-01" AS DATE) AS d_anchor, CAST(NULL AS STRING) AS expected
UNION ALL SELECT "fallback_missing_registry_birth_date" AS test_name, CAST(NULL AS STRING) AS s_nik, CAST("synthetic mother" AS STRING) AS s_name, CAST("1990-01-01" AS DATE) AS s_dob, CAST("2025-12-01" AS DATE) AS s_anchor, CAST("1111222233334444" AS STRING) AS d_nik, CAST("synthetic mother" AS STRING) AS d_name, CAST(NULL AS DATE) AS d_dob, CAST("2025-12-01" AS DATE) AS d_anchor, CAST(NULL AS STRING) AS expected
UNION ALL SELECT "fallback_wrong_name" AS test_name, CAST(NULL AS STRING) AS s_nik, CAST("other synthetic mother" AS STRING) AS s_name, CAST("1990-01-01" AS DATE) AS s_dob, CAST("2025-12-01" AS DATE) AS s_anchor, CAST("1111222233334444" AS STRING) AS d_nik, CAST("synthetic mother" AS STRING) AS d_name, CAST("1990-01-01" AS DATE) AS d_dob, CAST("2025-12-01" AS DATE) AS d_anchor, CAST(NULL AS STRING) AS expected
UNION ALL SELECT "fallback_missing_name" AS test_name, CAST(NULL AS STRING) AS s_nik, CAST(NULL AS STRING) AS s_name, CAST("1990-01-01" AS DATE) AS s_dob, CAST("2025-12-01" AS DATE) AS s_anchor, CAST("1111222233334444" AS STRING) AS d_nik, CAST("synthetic mother" AS STRING) AS d_name, CAST("1990-01-01" AS DATE) AS d_dob, CAST("2025-12-01" AS DATE) AS d_anchor, CAST(NULL AS STRING) AS expected
UNION ALL SELECT "fallback_missing_registry_name" AS test_name, CAST(NULL AS STRING) AS s_nik, CAST("synthetic mother" AS STRING) AS s_name, CAST("1990-01-01" AS DATE) AS s_dob, CAST("2025-12-01" AS DATE) AS s_anchor, CAST("1111222233334444" AS STRING) AS d_nik, CAST(NULL AS STRING) AS d_name, CAST("1990-01-01" AS DATE) AS d_dob, CAST("2025-12-01" AS DATE) AS d_anchor, CAST(NULL AS STRING) AS expected
UNION ALL SELECT "nik_match_does_not_require_name" AS test_name, CAST("1111222233334444" AS STRING) AS s_nik, CAST(NULL AS STRING) AS s_name, CAST("1990-01-01" AS DATE) AS s_dob, CAST("2025-12-01" AS DATE) AS s_anchor, CAST("1111222233334444" AS STRING) AS d_nik, CAST(NULL AS STRING) AS d_name, CAST("1990-01-01" AS DATE) AS d_dob, CAST("2025-12-01" AS DATE) AS d_anchor, CAST("NIK_AND_PREGNANCY_ANCHOR" AS STRING) AS expected
UNION ALL SELECT "nik_match_does_not_require_dob" AS test_name, CAST("1111222233334444" AS STRING) AS s_nik, CAST("synthetic mother" AS STRING) AS s_name, CAST(NULL AS DATE) AS s_dob, CAST("2025-12-01" AS DATE) AS s_anchor, CAST("1111222233334444" AS STRING) AS d_nik, CAST("synthetic mother" AS STRING) AS d_name, CAST(NULL AS DATE) AS d_dob, CAST("2025-12-01" AS DATE) AS d_anchor, CAST("NIK_AND_PREGNANCY_ANCHOR" AS STRING) AS expected
) SELECT *, deletion_match_rule(s_nik, s_name, s_dob, s_anchor, d_nik, d_name, d_dob, d_anchor) AS actual FROM fixtures;
SELECT test_name, expected, actual FROM deletion_test_results WHERE actual IS DISTINCT FROM expected;
ASSERT NOT EXISTS (SELECT 1 FROM deletion_test_results WHERE actual IS DISTINCT FROM expected) AS 'Deletion predicate regression';
ASSERT deletion_name_key('  SYNTHETIC-Mother.  ') = 'synthetic mother' AS 'Name normalization';
ASSERT deletion_name_key('   ') IS NULL AS 'Empty name';
ASSERT deletion_name_key(NULL) IS NULL AS 'Null name';
ASSERT COALESCE(CAST(NULL AS DATE), DATE_SUB(DATE '2026-09-07', INTERVAL 280 DAY)) = DATE '2025-12-01' AS 'HPL fallback';
ASSERT COALESCE(DATE '2025-12-02', DATE_SUB(DATE '2026-09-07', INTERVAL 280 DAY)) = DATE '2025-12-02' AS 'HPHT takes precedence';

-- Execute the production row-decision stages with duplicate registry hits and
-- duplicate source IDs. Matching must not multiply or silently deduplicate rows.
CREATE TEMP TABLE sigizi_source_unfiltered AS
SELECT 'DUPLICATED_SOURCE_ID' AS source_record_id,
  '1111222233334444' AS nik_clean, 'synthetic mother' AS nama_norm,
  'Synthetic Mother' AS nama, DATE '1990-01-01' AS tanggal_lahir,
  DATE '2025-12-01' AS hpht_date, CAST(NULL AS DATE) AS hpl_date
UNION ALL SELECT 'DUPLICATED_SOURCE_ID', '1111222233334444', 'synthetic mother',
  'Synthetic Mother', DATE '1990-01-01', DATE '2025-12-01', NULL
UNION ALL SELECT 'KEEP_OTHER_PREGNANCY', '1111222233334444', 'synthetic mother',
  'Synthetic Mother', DATE '1990-01-01', DATE '2026-12-01', NULL;
CREATE TEMP TABLE sigizi_deletion_registry AS
SELECT 'REGISTRY_A' AS source_record_id, 'DELETION_A' AS deleted_sigizi_pregnancy_key,
  '1111222233334444' AS nik_clean, 'synthetic mother' AS deletion_name_norm,
  DATE '1990-01-01' AS tanggal_lahir, DATE '2025-12-01' AS hpht_date,
  DATE '2026-01-01' AS tanggal_hapus_date
UNION ALL SELECT 'REGISTRY_B', 'DELETION_B', '1111222233334444',
  'synthetic mother', DATE '1990-01-01', DATE '2025-12-01', DATE '2026-01-02';

CREATE TEMP TABLE sigizi_deletion_features AS
SELECT
  ROW_NUMBER() OVER () AS source_row_instance,
  s AS source_record,
  COALESCE(hpht_date, DATE_SUB(hpl_date, INTERVAL 280 DAY))
    AS deletion_pregnancy_anchor_date,
  CASE WHEN hpht_date IS NOT NULL THEN 'HPHT'
       WHEN hpl_date IS NOT NULL THEN 'HPL_MINUS_280_DAYS'
       ELSE 'NO_PREGNANCY_ANCHOR' END AS deletion_anchor_method,
  deletion_name_key(COALESCE(NULLIF(nama_norm, ''), nama)) AS deletion_name_norm
FROM sigizi_source_unfiltered AS s;

-- An array preserves all matching registry references without multiplying rows.
-- Deletions are applied across the five SIGIZI clinical sources only.
CREATE TEMP TABLE sigizi_deletion_matches AS
SELECT
  s.source_row_instance,
  ARRAY_AGG(STRUCT(
      d.source_record_id AS registry_source_record_id,
      d.deleted_sigizi_pregnancy_key,
      d.hpht_date AS registry_hpht_date,
      d.tanggal_hapus_date,
      deletion_match_rule(
        s.source_record.nik_clean, s.deletion_name_norm,
        s.source_record.tanggal_lahir, s.deletion_pregnancy_anchor_date,
        d.nik_clean, d.deletion_name_norm, d.tanggal_lahir, d.hpht_date
      ) AS exclusion_match_rule
    ) ORDER BY d.deleted_sigizi_pregnancy_key, d.source_record_id
  ) AS deletion_matches
FROM sigizi_deletion_features AS s
JOIN sigizi_deletion_registry AS d
  ON s.deletion_pregnancy_anchor_date = d.hpht_date
  AND deletion_match_rule(
      s.source_record.nik_clean, s.deletion_name_norm,
      s.source_record.tanggal_lahir, s.deletion_pregnancy_anchor_date,
      d.nik_clean, d.deletion_name_norm, d.tanggal_lahir, d.hpht_date
    ) IS NOT NULL
GROUP BY s.source_row_instance;

CREATE TEMP TABLE sigizi_deletion_decisions AS
SELECT s.*, IFNULL(m.deletion_matches, []) AS deletion_matches
FROM sigizi_deletion_features AS s
LEFT JOIN sigizi_deletion_matches AS m USING (source_row_instance);


ASSERT (SELECT COUNT(*) FROM sigizi_deletion_decisions) = 3 AS 'Source multiplicity';
ASSERT (SELECT COUNTIF(ARRAY_LENGTH(deletion_matches) = 2) FROM sigizi_deletion_decisions) = 2 AS 'All duplicate registry references preserved';
ASSERT (SELECT COUNTIF(source_record.source_record_id = 'KEEP_OTHER_PREGNANCY' AND ARRAY_LENGTH(deletion_matches) = 0) FROM sigizi_deletion_decisions) = 1 AS 'Other pregnancy retained';
SELECT 'PASS' AS regression_status;
