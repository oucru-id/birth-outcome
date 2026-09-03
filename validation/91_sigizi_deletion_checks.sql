-- Run after 03 + 03a. Run 92 separately after the downstream core rebuild.
-- Does not alter production data. Summary rows are expected; FAIL is not a pass.
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


CREATE TEMP TABLE deletion_validation_issues AS
SELECT 'ACTIVE_SOURCE_STILL_MATCHES_DELETION' AS check_name, COUNT(*) AS exception_count
FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_source_records` AS s
JOIN `spheres-lombok-barat.kohort_bumil_v3.vs_sigizi_bumil_hapus` AS d
  ON COALESCE(s.hpht_date, DATE_SUB(s.hpl_date, INTERVAL 280 DAY)) = d.hpht_date
  AND deletion_match_rule(
    s.nik_clean, deletion_name_key(COALESCE(NULLIF(s.nama_norm, ''), s.nama)),
    s.tanggal_lahir, COALESCE(s.hpht_date, DATE_SUB(s.hpl_date, INTERVAL 280 DAY)),
    d.nik_clean, deletion_name_key(COALESCE(NULLIF(d.nama_norm, ''), d.nama)),
    d.tanggal_lahir, d.hpht_date
  ) IS NOT NULL
UNION ALL
SELECT 'REGISTRY_UNIONED_INTO_CLINICAL_SOURCE', COUNT(*)
FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_source_records`
WHERE source_table = 'BUMIL_HAPUS'
UNION ALL
SELECT 'AUDIT_ROWS_WITHOUT_MATCH', COUNT(*)
FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_deletion_exclusion_audit`
WHERE IFNULL(ARRAY_LENGTH(deletion_matches), 0) = 0
UNION ALL
SELECT 'AUDIT_RUN_MISMATCH', COUNT(*)
FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_deletion_exclusion_audit` AS a
WHERE NOT EXISTS (
  SELECT 1 FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_deletion_exclusion_summary` AS r
  WHERE a.exclusion_run_id = r.exclusion_run_id
)
UNION ALL
SELECT 'SUMMARY_CARDINALITY', IF(COUNT(*) = 1, 0, 1)
FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_deletion_exclusion_summary`
UNION ALL
SELECT 'SUMMARY_OR_PARTITION_MISMATCH', COUNT(*)
FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_deletion_exclusion_summary` AS r
WHERE r.source_rows_before_exclusion != r.active_source_rows + r.excluded_source_rows
  OR r.active_source_rows !=
    (SELECT COUNT(*) FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_source_records`)
  OR r.excluded_source_rows !=
    (SELECT COUNT(*) FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_deletion_exclusion_audit`);

SELECT check_name, exception_count,
  IF(exception_count = 0, 'PASS', 'FAIL') AS validation_status
FROM deletion_validation_issues ORDER BY check_name;

ASSERT NOT EXISTS (
  SELECT 1 FROM deletion_validation_issues WHERE exception_count != 0
) AS 'SIGIZI deletion validation failed; stop downstream execution';

-- Informational latest-run summary. Missing anchors/identities require review.
SELECT * FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_deletion_exclusion_summary`;

-- Count each excluded source row once per rule, even with multiple registry matches.
SELECT source_table, match_rule, COUNT(*) AS excluded_source_records
FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_deletion_exclusion_audit` AS a,
UNNEST(ARRAY(
  SELECT DISTINCT m.exclusion_match_rule
  FROM UNNEST(a.deletion_matches) AS m
)) AS match_rule
GROUP BY source_table, match_rule ORDER BY source_table, match_rule;
