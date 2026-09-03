-- Independent source layer: references redirected to v3; original logic retained.
-- V3 CORE DRAFT: not executed in BigQuery; production compatibility not yet validated.
-- Run this entire file as one job. Existing v2 inputs are read only.
-- Original comments below describe recovered historical scripts, not current counts.

-- ============================================================================
-- 03C v4 - CANONICAL WITHIN-SOURCE + CROSS-SOURCE + FINAL ALL-EPISODE MATCHING
-- v3.3 / strong pregnancy identity resolution with conflict-preserving overrides
--
-- PURPOSE
--   Fix residual duplicate pregnancies that survive cross-source matching,
--   especially the pattern:
--
--     SIGIZI + EPUS   (valid NIK)
--     SIGIZI ONLY     (same mother / DOB / HPHT, invalid or scientific NIK)
--
--   The script first canonicalizes duplicate pregnancy episodes WITHIN SIGIZI
--   and WITHIN ePUS.  It then reruns the existing hierarchical SIGIZI<->ePUS
--   matching using those canonical source episodes.  Finally, it applies a
--   final all-episode canonicalization layer that compares every plausible
--   residual pair, including SIGIZI+EPUS <-> SIGIZI+EPUS.
--
-- IMPORTANT
--   This script assumes these two Stage-1/2 tables already exist:
--     t_sigizi_pregnancy_episode_v3_3
--     t_epus_pregnancy_episode_adapter_v3_3
--
--   It MATERIALIZES every major step to reduce BigQuery planner complexity.
--
-- MATCHING PRINCIPLE
--   One real pregnancy should resolve to one pregnancy_episode_id.
--
--   NIK and DOB are maternal-identity evidence, but source errors can occur.
--   HPHT/HPL/delivery are pregnancy-episode evidence. Therefore a NIK or DOB
--   disagreement is retained as a QA conflict, but it does not automatically
--   force a separate pregnancy when the pregnancy fingerprint is exceptionally
--   strong.
--
--   Final rescue hierarchy adds:
--     * exact / compact / controlled fuzzy-name matching
--     * missing-DOB rescue (missing is not a conflict)
--     * phone + DOB + pregnancy-date rescue
--     * strong pregnancy-fingerprint override of NIK/DOB disagreement
--     * high-conflict UNIQUE fingerprint rescue
--     * all-to-all final comparison, including matched <-> matched episodes
--
--   Weak rules still block conflicting TRUSTED NIKs. Scientific notation,
--   malformed values, and 16-digit values ending 0000 are not trusted NIKs.
-- ============================================================================

DECLARE within_source_anchor_tolerance_days INT64 DEFAULT 30;
DECLARE sigizi_episode_anchor_tolerance_days INT64 DEFAULT 120;

DECLARE cross_source_anchor_tolerance_days INT64 DEFAULT 90;
DECLARE hpht_tolerance_days INT64 DEFAULT 7;
DECLARE delivery_tolerance_days INT64 DEFAULT 3;
DECLARE hpl_tolerance_days INT64 DEFAULT 7;

-- Strong-identity override tolerances. These are only used when name + DOB
-- identity is strong and another corroborator is present.
DECLARE strong_hpht_tolerance_days INT64 DEFAULT 14;
DECLARE strong_hpl_tolerance_days INT64 DEFAULT 14;
DECLARE phone_anchor_tolerance_days INT64 DEFAULT 30;

DECLARE final_guard_anchor_tolerance_days INT64 DEFAULT 30;


-- --------------------------------------------------------------------------
-- NIK reliability helpers
-- --------------------------------------------------------------------------
-- A value is TRUSTED only when it is an ordinary 16-digit NIK and is not a
-- known rounded placeholder. Scientific notation (for example 5.20131E+15),
-- malformed strings, all-zero/all-nine values, and 16-digit values ending 0000
-- are treated as UNTRUSTED clues rather than hard identity contradictions.
CREATE TEMP FUNCTION nik_is_suspect_rounding(s STRING)
RETURNS BOOL
AS (
  s IS NOT NULL
  AND REGEXP_CONTAINS(s, r'^\d{16}$')
  AND RIGHT(s, 4) = '0000'
);

CREATE TEMP FUNCTION nik_is_trusted(s STRING)
RETURNS BOOL
AS (
  s IS NOT NULL
  AND REGEXP_CONTAINS(s, r'^\d{16}$')
  AND s NOT IN ('0000000000000000', '9999999999999999')
  AND RIGHT(s, 4) != '0000'
);

CREATE TEMP FUNCTION nik_hard_conflict(a STRING, b STRING)
RETURNS BOOL
AS (
  a IS NOT NULL
  AND b IS NOT NULL
  AND a != b
  AND REGEXP_CONTAINS(a, r'^\d{16}$')
  AND REGEXP_CONTAINS(b, r'^\d{16}$')
  AND a NOT IN ('0000000000000000', '9999999999999999')
  AND b NOT IN ('0000000000000000', '9999999999999999')
  AND RIGHT(a, 4) != '0000'
  AND RIGHT(b, 4) != '0000'
);


-- Compact comparison removes spacing/punctuation differences such as:
--   ZARRATUL AINI  vs  ZARRATULAINI
CREATE TEMP FUNCTION compact_name(s STRING)
RETURNS STRING
AS (
  NULLIF(
    REGEXP_REPLACE(
      UPPER(TRIM(COALESCE(s, ''))),
      r'[^A-Z0-9]',
      ''
    ),
    ''
  )
);

CREATE TEMP FUNCTION norm_key(s STRING)
RETURNS STRING
AS (
  NULLIF(
    REGEXP_REPLACE(
      UPPER(TRIM(COALESCE(s, ''))),
      r'[^A-Z0-9]',
      ''
    ),
    ''
  )
);


-- ============================================================================
-- STAGE 2.5A - WITHIN-SIGIZI CANONICALIZATION
-- ============================================================================

CREATE OR REPLACE TEMP TABLE `_SESSION.t_sigizi_episode_quality_v3_3`
CLUSTER BY nik_clean, puskesmas_norm, sigizi_episode_id
AS
SELECT
  s.*,
  (
      IF(nik_is_trusted(nik_clean), 100, IF(nik_clean IS NOT NULL, 5, 0))
    + IF(tanggal_lahir_ibu IS NOT NULL, 25, 0)
    + IF(hpht_sigizi IS NOT NULL, 30, 0)
    + IF(hpl_sigizi IS NOT NULL, 15, 0)
    + IF(delivery_sigizi IS NOT NULL, 15, 0)
    + IF(no_hp_clean IS NOT NULL AND LENGTH(no_hp_clean) >= 8, 8, 0)
    + IF(puskesmas_norm IS NOT NULL, 5, 0)
    + IF(desa_norm IS NOT NULL, 3, 0)
    + LEAST(COALESCE(sigizi_member_record_count, 0), 10)
  ) AS episode_quality_score
FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_v3_3` s;

CREATE OR REPLACE TEMP TABLE `_SESSION.t_sigizi_within_source_candidates_v3_3`
CLUSTER BY member_episode_id, candidate_anchor_episode_id
AS
-- 1. Exact NIK + compatible pregnancy anchor
SELECT
  a.sigizi_episode_id AS member_episode_id,
  b.sigizi_episode_id AS candidate_anchor_episode_id,
  'NIK+ANCHOR' AS within_source_match_method,
  1 AS within_source_match_priority,
  'VERY_HIGH' AS within_source_match_confidence,
  ABS(DATE_DIFF(a.pregnancy_anchor_min_date, b.pregnancy_anchor_min_date, DAY)) AS anchor_difference_days,
  ABS(DATE_DIFF(a.pregnancy_anchor_min_date, b.pregnancy_anchor_min_date, DAY)) AS match_date_difference_days,
  a.episode_quality_score AS member_quality_score,
  b.episode_quality_score AS candidate_anchor_quality_score
FROM `_SESSION.t_sigizi_episode_quality_v3_3` a
JOIN `_SESSION.t_sigizi_episode_quality_v3_3` b
  ON a.sigizi_episode_id != b.sigizi_episode_id
 AND a.nik_clean IS NOT NULL
 AND b.nik_clean IS NOT NULL
 AND a.nik_clean = b.nik_clean
 AND a.pregnancy_anchor_min_date IS NOT NULL
 AND b.pregnancy_anchor_min_date IS NOT NULL
 AND ABS(DATE_DIFF(a.pregnancy_anchor_min_date, b.pregnancy_anchor_min_date, DAY)) <= within_source_anchor_tolerance_days
;

-- 2. STRONG IDENTITY OVERRIDE: name/core-or-compact + exact DOB + HPHT <=14d
--    + at least one corroborator. Different trusted NIKs are allowed here.
INSERT INTO `_SESSION.t_sigizi_within_source_candidates_v3_3`
SELECT
  a.sigizi_episode_id,
  b.sigizi_episode_id,
  'STRONG_NAME+DOB+HPHT_14D+CORROBORATOR',
  2,
  'VERY_HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_min_date, b.pregnancy_anchor_min_date, DAY)),
  ABS(DATE_DIFF(a.hpht_sigizi, b.hpht_sigizi, DAY)),
  a.episode_quality_score,
  b.episode_quality_score
FROM `_SESSION.t_sigizi_episode_quality_v3_3` a
JOIN `_SESSION.t_sigizi_episode_quality_v3_3` b
  ON a.sigizi_episode_id != b.sigizi_episode_id
 AND a.nama_core_norm IS NOT NULL
 AND b.nama_core_norm IS NOT NULL
 AND (
      a.nama_core_norm = b.nama_core_norm
      OR compact_name(a.nama_core_norm) = compact_name(b.nama_core_norm)
 )
 AND a.tanggal_lahir_ibu IS NOT NULL
 AND a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
 AND a.hpht_sigizi IS NOT NULL
 AND b.hpht_sigizi IS NOT NULL
 AND ABS(DATE_DIFF(a.hpht_sigizi, b.hpht_sigizi, DAY)) <= strong_hpht_tolerance_days
 AND (
      (a.hpl_sigizi IS NOT NULL AND b.hpl_sigizi IS NOT NULL
       AND ABS(DATE_DIFF(a.hpl_sigizi, b.hpl_sigizi, DAY)) <= strong_hpl_tolerance_days)
   OR (a.delivery_sigizi IS NOT NULL AND b.delivery_sigizi IS NOT NULL
       AND ABS(DATE_DIFF(a.delivery_sigizi, b.delivery_sigizi, DAY)) <= delivery_tolerance_days)
   OR (a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm)
   OR (a.desa_norm IS NOT NULL AND a.desa_norm = b.desa_norm)
   OR (norm_key(a.posyandu) IS NOT NULL AND norm_key(a.posyandu) = norm_key(b.posyandu))
   OR (a.no_hp_clean IS NOT NULL AND LENGTH(a.no_hp_clean) >= 8 AND a.no_hp_clean = b.no_hp_clean)
 )
;

-- 3. STRONG IDENTITY OVERRIDE when HPHT is unavailable/less usable:
--    name + exact DOB + HPL <=14d + another corroborator.
INSERT INTO `_SESSION.t_sigizi_within_source_candidates_v3_3`
SELECT
  a.sigizi_episode_id,
  b.sigizi_episode_id,
  'STRONG_NAME+DOB+HPL_14D+CORROBORATOR',
  3,
  'HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_min_date, b.pregnancy_anchor_min_date, DAY)),
  ABS(DATE_DIFF(a.hpl_sigizi, b.hpl_sigizi, DAY)),
  a.episode_quality_score,
  b.episode_quality_score
FROM `_SESSION.t_sigizi_episode_quality_v3_3` a
JOIN `_SESSION.t_sigizi_episode_quality_v3_3` b
  ON a.sigizi_episode_id != b.sigizi_episode_id
 AND a.nama_core_norm IS NOT NULL
 AND b.nama_core_norm IS NOT NULL
 AND (
      a.nama_core_norm = b.nama_core_norm
      OR compact_name(a.nama_core_norm) = compact_name(b.nama_core_norm)
 )
 AND a.tanggal_lahir_ibu IS NOT NULL
 AND a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
 AND a.hpl_sigizi IS NOT NULL
 AND b.hpl_sigizi IS NOT NULL
 AND ABS(DATE_DIFF(a.hpl_sigizi, b.hpl_sigizi, DAY)) <= strong_hpl_tolerance_days
 AND (
      (a.delivery_sigizi IS NOT NULL AND b.delivery_sigizi IS NOT NULL
       AND ABS(DATE_DIFF(a.delivery_sigizi, b.delivery_sigizi, DAY)) <= delivery_tolerance_days)
   OR (a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm)
   OR (a.desa_norm IS NOT NULL AND a.desa_norm = b.desa_norm)
   OR (norm_key(a.posyandu) IS NOT NULL AND norm_key(a.posyandu) = norm_key(b.posyandu))
   OR (a.no_hp_clean IS NOT NULL AND LENGTH(a.no_hp_clean) >= 8 AND a.no_hp_clean = b.no_hp_clean)
 )
;

-- 4. STRONG IDENTITY OVERRIDE: name + exact DOB + delivery <=3d
--    + location/phone/HPL corroboration.
INSERT INTO `_SESSION.t_sigizi_within_source_candidates_v3_3`
SELECT
  a.sigizi_episode_id,
  b.sigizi_episode_id,
  'STRONG_NAME+DOB+DELIVERY_3D+CORROBORATOR',
  4,
  'HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_min_date, b.pregnancy_anchor_min_date, DAY)),
  ABS(DATE_DIFF(a.delivery_sigizi, b.delivery_sigizi, DAY)),
  a.episode_quality_score,
  b.episode_quality_score
FROM `_SESSION.t_sigizi_episode_quality_v3_3` a
JOIN `_SESSION.t_sigizi_episode_quality_v3_3` b
  ON a.sigizi_episode_id != b.sigizi_episode_id
 AND a.nama_core_norm IS NOT NULL
 AND b.nama_core_norm IS NOT NULL
 AND (
      a.nama_core_norm = b.nama_core_norm
      OR compact_name(a.nama_core_norm) = compact_name(b.nama_core_norm)
 )
 AND a.tanggal_lahir_ibu IS NOT NULL
 AND a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
 AND a.delivery_sigizi IS NOT NULL
 AND b.delivery_sigizi IS NOT NULL
 AND ABS(DATE_DIFF(a.delivery_sigizi, b.delivery_sigizi, DAY)) <= delivery_tolerance_days
 AND (
      (a.hpl_sigizi IS NOT NULL AND b.hpl_sigizi IS NOT NULL
       AND ABS(DATE_DIFF(a.hpl_sigizi, b.hpl_sigizi, DAY)) <= strong_hpl_tolerance_days)
   OR (a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm)
   OR (a.desa_norm IS NOT NULL AND a.desa_norm = b.desa_norm)
   OR (norm_key(a.posyandu) IS NOT NULL AND norm_key(a.posyandu) = norm_key(b.posyandu))
   OR (a.no_hp_clean IS NOT NULL AND LENGTH(a.no_hp_clean) >= 8 AND a.no_hp_clean = b.no_hp_clean)
 )
;

-- --------------------------------------------------------------------------
-- WEAKER FALLBACK RULES.
-- Trusted-NIK conflicts remain blocked here.
-- --------------------------------------------------------------------------
INSERT INTO `_SESSION.t_sigizi_within_source_candidates_v3_3`
SELECT a.sigizi_episode_id, b.sigizi_episode_id,
  'NAMA_CORE+DOB+HPHT_EXACT', 10, 'VERY_HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_min_date, b.pregnancy_anchor_min_date, DAY)), 0,
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_sigizi_episode_quality_v3_3` a
JOIN `_SESSION.t_sigizi_episode_quality_v3_3` b
  ON a.sigizi_episode_id != b.sigizi_episode_id
 AND a.nama_core_norm IS NOT NULL AND a.nama_core_norm = b.nama_core_norm
 AND a.tanggal_lahir_ibu IS NOT NULL AND a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
 AND a.hpht_sigizi IS NOT NULL AND a.hpht_sigizi = b.hpht_sigizi
 AND NOT nik_hard_conflict(a.nik_clean, b.nik_clean)
;

INSERT INTO `_SESSION.t_sigizi_within_source_candidates_v3_3`
SELECT a.sigizi_episode_id, b.sigizi_episode_id,
  'NAMA_CORE+DOB+HPHT_7D', 11, 'HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_min_date, b.pregnancy_anchor_min_date, DAY)),
  ABS(DATE_DIFF(a.hpht_sigizi, b.hpht_sigizi, DAY)),
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_sigizi_episode_quality_v3_3` a
JOIN `_SESSION.t_sigizi_episode_quality_v3_3` b
  ON a.sigizi_episode_id != b.sigizi_episode_id
 AND a.nama_core_norm IS NOT NULL AND a.nama_core_norm = b.nama_core_norm
 AND a.tanggal_lahir_ibu IS NOT NULL AND a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
 AND a.hpht_sigizi IS NOT NULL AND b.hpht_sigizi IS NOT NULL
 AND ABS(DATE_DIFF(a.hpht_sigizi, b.hpht_sigizi, DAY)) BETWEEN 1 AND hpht_tolerance_days
 AND NOT nik_hard_conflict(a.nik_clean, b.nik_clean)
;

INSERT INTO `_SESSION.t_sigizi_within_source_candidates_v3_3`
SELECT a.sigizi_episode_id, b.sigizi_episode_id,
  'NAMA_CORE+DOB+PUSKESMAS+ANCHOR', 12, 'HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_min_date, b.pregnancy_anchor_min_date, DAY)),
  ABS(DATE_DIFF(a.pregnancy_anchor_min_date, b.pregnancy_anchor_min_date, DAY)),
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_sigizi_episode_quality_v3_3` a
JOIN `_SESSION.t_sigizi_episode_quality_v3_3` b
  ON a.sigizi_episode_id != b.sigizi_episode_id
 AND a.nama_core_norm IS NOT NULL AND a.nama_core_norm = b.nama_core_norm
 AND a.tanggal_lahir_ibu IS NOT NULL AND a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
 AND a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm
 AND a.pregnancy_anchor_min_date IS NOT NULL AND b.pregnancy_anchor_min_date IS NOT NULL
 AND ABS(DATE_DIFF(a.pregnancy_anchor_min_date, b.pregnancy_anchor_min_date, DAY)) <= within_source_anchor_tolerance_days
 AND NOT nik_hard_conflict(a.nik_clean, b.nik_clean)
;

INSERT INTO `_SESSION.t_sigizi_within_source_candidates_v3_3`
SELECT a.sigizi_episode_id, b.sigizi_episode_id,
  'NAMA_CORE+HPHT_EXACT+PUSKESMAS', 13, 'HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_min_date, b.pregnancy_anchor_min_date, DAY)), 0,
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_sigizi_episode_quality_v3_3` a
JOIN `_SESSION.t_sigizi_episode_quality_v3_3` b
  ON a.sigizi_episode_id != b.sigizi_episode_id
 AND a.nama_core_norm IS NOT NULL AND a.nama_core_norm = b.nama_core_norm
 AND a.hpht_sigizi IS NOT NULL AND a.hpht_sigizi = b.hpht_sigizi
 AND a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm
 AND NOT nik_hard_conflict(a.nik_clean, b.nik_clean)
;

INSERT INTO `_SESSION.t_sigizi_within_source_candidates_v3_3`
SELECT a.sigizi_episode_id, b.sigizi_episode_id,
  'NAMA_CORE+HPHT_7D+PUSKESMAS', 14, 'HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_min_date, b.pregnancy_anchor_min_date, DAY)),
  ABS(DATE_DIFF(a.hpht_sigizi, b.hpht_sigizi, DAY)),
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_sigizi_episode_quality_v3_3` a
JOIN `_SESSION.t_sigizi_episode_quality_v3_3` b
  ON a.sigizi_episode_id != b.sigizi_episode_id
 AND a.nama_core_norm IS NOT NULL AND a.nama_core_norm = b.nama_core_norm
 AND a.hpht_sigizi IS NOT NULL AND b.hpht_sigizi IS NOT NULL
 AND ABS(DATE_DIFF(a.hpht_sigizi, b.hpht_sigizi, DAY)) BETWEEN 1 AND hpht_tolerance_days
 AND a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm
 AND NOT nik_hard_conflict(a.nik_clean, b.nik_clean)
;

INSERT INTO `_SESSION.t_sigizi_within_source_candidates_v3_3`
SELECT a.sigizi_episode_id, b.sigizi_episode_id,
  'NAMA_CORE+DELIVERY_3D+PUSKESMAS', 15, 'MEDIUM_HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_min_date, b.pregnancy_anchor_min_date, DAY)),
  ABS(DATE_DIFF(a.delivery_sigizi, b.delivery_sigizi, DAY)),
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_sigizi_episode_quality_v3_3` a
JOIN `_SESSION.t_sigizi_episode_quality_v3_3` b
  ON a.sigizi_episode_id != b.sigizi_episode_id
 AND a.nama_core_norm IS NOT NULL AND a.nama_core_norm = b.nama_core_norm
 AND a.delivery_sigizi IS NOT NULL AND b.delivery_sigizi IS NOT NULL
 AND ABS(DATE_DIFF(a.delivery_sigizi, b.delivery_sigizi, DAY)) <= delivery_tolerance_days
 AND a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm
 AND NOT nik_hard_conflict(a.nik_clean, b.nik_clean)
;

INSERT INTO `_SESSION.t_sigizi_within_source_candidates_v3_3`
SELECT a.sigizi_episode_id, b.sigizi_episode_id,
  'NAMA_CORE+DOB+HPL_7D', 16, 'MEDIUM_HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_min_date, b.pregnancy_anchor_min_date, DAY)),
  ABS(DATE_DIFF(a.hpl_sigizi, b.hpl_sigizi, DAY)),
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_sigizi_episode_quality_v3_3` a
JOIN `_SESSION.t_sigizi_episode_quality_v3_3` b
  ON a.sigizi_episode_id != b.sigizi_episode_id
 AND a.nama_core_norm IS NOT NULL AND a.nama_core_norm = b.nama_core_norm
 AND a.tanggal_lahir_ibu IS NOT NULL AND a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
 AND a.hpl_sigizi IS NOT NULL AND b.hpl_sigizi IS NOT NULL
 AND ABS(DATE_DIFF(a.hpl_sigizi, b.hpl_sigizi, DAY)) <= hpl_tolerance_days
 AND NOT nik_hard_conflict(a.nik_clean, b.nik_clean)
;

INSERT INTO `_SESSION.t_sigizi_within_source_candidates_v3_3`
SELECT a.sigizi_episode_id, b.sigizi_episode_id,
  'NAMA_CORE+PHONE+PUSKESMAS+ANCHOR_30D', 17, 'MEDIUM',
  ABS(DATE_DIFF(a.pregnancy_anchor_min_date, b.pregnancy_anchor_min_date, DAY)),
  ABS(DATE_DIFF(a.pregnancy_anchor_min_date, b.pregnancy_anchor_min_date, DAY)),
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_sigizi_episode_quality_v3_3` a
JOIN `_SESSION.t_sigizi_episode_quality_v3_3` b
  ON a.sigizi_episode_id != b.sigizi_episode_id
 AND a.nama_core_norm IS NOT NULL AND a.nama_core_norm = b.nama_core_norm
 AND a.no_hp_clean IS NOT NULL AND LENGTH(a.no_hp_clean) >= 8 AND a.no_hp_clean = b.no_hp_clean
 AND a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm
 AND a.pregnancy_anchor_min_date IS NOT NULL AND b.pregnancy_anchor_min_date IS NOT NULL
 AND ABS(DATE_DIFF(a.pregnancy_anchor_min_date, b.pregnancy_anchor_min_date, DAY)) <= phone_anchor_tolerance_days
 AND NOT nik_hard_conflict(a.nik_clean, b.nik_clean)
;

CREATE OR REPLACE TEMP TABLE `_SESSION.t_sigizi_within_source_candidates_best_v3_3`
CLUSTER BY member_episode_id, candidate_anchor_episode_id
AS
SELECT * EXCEPT(pair_rn)
FROM (
  SELECT
    c.*,
    ROW_NUMBER() OVER (
      PARTITION BY member_episode_id, candidate_anchor_episode_id
      ORDER BY
        within_source_match_priority,
        match_date_difference_days,
        anchor_difference_days,
        candidate_anchor_episode_id
    ) AS pair_rn
  FROM `_SESSION.t_sigizi_within_source_candidates_v3_3` c
)
WHERE pair_rn = 1;


CREATE OR REPLACE TEMP TABLE `_SESSION.t_sigizi_within_source_anchors_v3_3`
CLUSTER BY sigizi_episode_id
AS
SELECT q.*
FROM `_SESSION.t_sigizi_episode_quality_v3_3` q
WHERE NOT EXISTS (
  SELECT 1
  FROM `_SESSION.t_sigizi_within_source_candidates_best_v3_3` c
  JOIN `_SESSION.t_sigizi_episode_quality_v3_3` b
    ON b.sigizi_episode_id = c.candidate_anchor_episode_id
  WHERE c.member_episode_id = q.sigizi_episode_id
    AND (
      b.episode_quality_score > q.episode_quality_score
      OR (
        b.episode_quality_score = q.episode_quality_score
        AND b.sigizi_episode_id < q.sigizi_episode_id
      )
    )
);


CREATE OR REPLACE TEMP TABLE `_SESSION.t_sigizi_within_source_anchor_candidates_v3_3`
CLUSTER BY member_episode_id, candidate_anchor_episode_id
AS
SELECT
  c.*,
  a.episode_quality_score AS eligible_anchor_quality_score
FROM `_SESSION.t_sigizi_within_source_candidates_best_v3_3` c
JOIN `_SESSION.t_sigizi_within_source_anchors_v3_3` a
  ON a.sigizi_episode_id = c.candidate_anchor_episode_id;


CREATE OR REPLACE TABLE `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_episode_canonical_map_v3_3`
CLUSTER BY member_sigizi_episode_id, canonical_sigizi_episode_id
AS
SELECT
  member_sigizi_episode_id,
  canonical_sigizi_episode_id,
  within_source_match_method,
  within_source_match_priority,
  within_source_match_confidence,
  anchor_difference_days,
  match_date_difference_days
FROM (
  SELECT
    q.sigizi_episode_id AS member_sigizi_episode_id,
    COALESCE(c.candidate_anchor_episode_id, q.sigizi_episode_id)
      AS canonical_sigizi_episode_id,
    c.within_source_match_method,
    c.within_source_match_priority,
    c.within_source_match_confidence,
    c.anchor_difference_days,
    c.match_date_difference_days,

    ROW_NUMBER() OVER (
      PARTITION BY q.sigizi_episode_id
      ORDER BY
        c.within_source_match_priority IS NULL,
        c.within_source_match_priority,
        c.match_date_difference_days,
        c.anchor_difference_days,
        c.eligible_anchor_quality_score DESC,
        c.candidate_anchor_episode_id
    ) AS rn
  FROM `_SESSION.t_sigizi_episode_quality_v3_3` q
  LEFT JOIN `_SESSION.t_sigizi_within_source_anchor_candidates_v3_3` c
    ON c.member_episode_id = q.sigizi_episode_id
)
WHERE rn = 1;


CREATE OR REPLACE TABLE `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_canonical_v3_3`
CLUSTER BY nik_clean, puskesmas_norm, sigizi_episode_id
AS
WITH members AS (
  SELECT
    m.canonical_sigizi_episode_id,
    q.*
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_episode_canonical_map_v3_3` m
  JOIN `_SESSION.t_sigizi_episode_quality_v3_3` q
    ON q.sigizi_episode_id = m.member_sigizi_episode_id
),

scalar_agg AS (
  SELECT
    canonical_sigizi_episode_id,

    ARRAY_AGG(
      STRUCT(nik_clean AS value, episode_quality_score AS q, sigizi_episode_id AS id)
      ORDER BY nik_clean IS NULL, episode_quality_score DESC, sigizi_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS nik_pick,

    ARRAY_AGG(
      STRUCT(
        nama_ibu AS value,
        nama_norm AS value_norm,
        nama_core_norm AS value_core,
        episode_quality_score AS q,
        sigizi_episode_id AS id
      )
      ORDER BY nama_core_norm IS NULL, nik_clean IS NULL, episode_quality_score DESC, sigizi_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS name_pick,

    ARRAY_AGG(
      STRUCT(tanggal_lahir_ibu AS value, episode_quality_score AS q, sigizi_episode_id AS id)
      ORDER BY tanggal_lahir_ibu IS NULL, episode_quality_score DESC, sigizi_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS dob_pick,

    ARRAY_AGG(
      STRUCT(no_hp_clean AS value, episode_quality_score AS q, sigizi_episode_id AS id)
      ORDER BY no_hp_clean IS NULL, LENGTH(COALESCE(no_hp_clean, '')) DESC, episode_quality_score DESC, sigizi_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS phone_pick,

    ARRAY_AGG(
      STRUCT(puskesmas AS value, puskesmas_norm AS value_norm, episode_quality_score AS q, sigizi_episode_id AS id)
      ORDER BY puskesmas_norm IS NULL, episode_quality_score DESC, sigizi_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS puskesmas_pick,

    ARRAY_AGG(
      STRUCT(desa AS value, desa_norm AS value_norm, episode_quality_score AS q, sigizi_episode_id AS id)
      ORDER BY desa_norm IS NULL, episode_quality_score DESC, sigizi_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS desa_pick,

    ARRAY_AGG(
      STRUCT(posyandu AS value, episode_quality_score AS q, sigizi_episode_id AS id)
      ORDER BY posyandu IS NULL, episode_quality_score DESC, sigizi_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS posyandu_pick,

    ARRAY_AGG(
      STRUCT(alamat AS value, episode_quality_score AS q, sigizi_episode_id AS id)
      ORDER BY alamat IS NULL, episode_quality_score DESC, sigizi_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS alamat_pick,

    ARRAY_AGG(
      STRUCT(hpht_sigizi AS value, hpht_sigizi_source_table AS source_table, episode_quality_score AS q, sigizi_episode_id AS id)
      ORDER BY hpht_sigizi IS NULL, episode_quality_score DESC, sigizi_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS hpht_pick,

    ARRAY_AGG(
      STRUCT(hpl_sigizi AS value, hpl_sigizi_source_table AS source_table, episode_quality_score AS q, sigizi_episode_id AS id)
      ORDER BY hpl_sigizi IS NULL, episode_quality_score DESC, sigizi_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS hpl_pick,

    ARRAY_AGG(
      STRUCT(delivery_sigizi AS value, delivery_sigizi_source_table AS source_table, episode_quality_score AS q, sigizi_episode_id AS id)
      ORDER BY delivery_sigizi IS NULL, episode_quality_score DESC, sigizi_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS delivery_pick,

    MIN(first_anc_date) AS first_anc_date,
    MAX(last_anc_date) AS last_anc_date,

    MIN(pregnancy_anchor_min_date) AS pregnancy_anchor_min_date,
    MAX(pregnancy_anchor_max_date) AS pregnancy_anchor_max_date,

    LOGICAL_OR(COALESCE(sigizi_episode_review_flag, FALSE)) AS any_review_flag,

    SUM(COALESCE(sigizi_member_record_count, 1)) AS sigizi_member_record_count,
    SUM(COALESCE(sigizi_identity_propagated_record_count, 0)) AS sigizi_identity_propagated_record_count,
    SUM(COALESCE(sigizi_ambiguous_identity_record_count, 0)) AS sigizi_ambiguous_identity_record_count,
    MAX(COALESCE(sigizi_max_signature_row_count, 0)) AS sigizi_max_signature_row_count,
    SUM(COALESCE(sigizi_distinct_pregnancy_signature_count, 0)) AS sigizi_distinct_pregnancy_signature_count,

    COUNT(*) AS within_sigizi_episode_count

  FROM members
  GROUP BY canonical_sigizi_episode_id
),

source_tables AS (
  SELECT
    canonical_sigizi_episode_id,
    ARRAY_AGG(DISTINCT x ORDER BY x) AS sigizi_source_tables
  FROM members,
  UNNEST(COALESCE(sigizi_source_tables, ARRAY<STRING>[])) x
  WHERE x IS NOT NULL
  GROUP BY canonical_sigizi_episode_id
),

member_source_ids AS (
  SELECT
    canonical_sigizi_episode_id,
    ARRAY_AGG(DISTINCT x ORDER BY x) AS sigizi_member_source_record_ids
  FROM members,
  UNNEST(COALESCE(sigizi_member_source_record_ids, ARRAY<STRING>[])) x
  WHERE x IS NOT NULL
  GROUP BY canonical_sigizi_episode_id
),

identity_methods AS (
  SELECT
    canonical_sigizi_episode_id,
    ARRAY_AGG(DISTINCT x ORDER BY x) AS mother_identity_methods
  FROM members,
  UNNEST(COALESCE(mother_identity_methods, ARRAY<STRING>[])) x
  WHERE x IS NOT NULL
  GROUP BY canonical_sigizi_episode_id
),

member_episode_ids AS (
  SELECT
    canonical_sigizi_episode_id,
    ARRAY_AGG(
      member_sigizi_episode_id
      ORDER BY member_sigizi_episode_id
    ) AS within_sigizi_member_episode_ids
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_episode_canonical_map_v3_3`
  GROUP BY canonical_sigizi_episode_id
)

SELECT
  a.canonical_sigizi_episode_id AS sigizi_episode_id,

  anchor.mother_identity_key,
  anchor.mother_identity_method,
  anchor.episode_number,

  a.nik_pick.value AS nik_clean,

  a.name_pick.value AS nama_ibu,
  a.name_pick.value_norm AS nama_norm,
  a.name_pick.value_core AS nama_core_norm,

  a.dob_pick.value AS tanggal_lahir_ibu,
  a.phone_pick.value AS no_hp_clean,

  a.puskesmas_pick.value AS puskesmas,
  a.puskesmas_pick.value_norm AS puskesmas_norm,

  a.desa_pick.value AS desa,
  a.desa_pick.value_norm AS desa_norm,

  a.posyandu_pick.value AS posyandu,
  a.alamat_pick.value AS alamat,

  a.hpht_pick.value AS hpht_sigizi,
  CASE WHEN a.hpht_pick.value IS NOT NULL THEN a.hpht_pick.source_table END AS hpht_sigizi_source_table,

  a.hpl_pick.value AS hpl_sigizi,
  CASE WHEN a.hpl_pick.value IS NOT NULL THEN a.hpl_pick.source_table END AS hpl_sigizi_source_table,

  a.delivery_pick.value AS delivery_sigizi,
  CASE WHEN a.delivery_pick.value IS NOT NULL THEN a.delivery_pick.source_table END AS delivery_sigizi_source_table,

  CASE
    WHEN a.hpht_pick.value IS NOT NULL
      THEN DATE_ADD(a.hpht_pick.value, INTERVAL 280 DAY)
  END AS hpl_from_sigizi_hpht,

  a.first_anc_date,
  a.last_anc_date,

  a.pregnancy_anchor_min_date,
  a.pregnancy_anchor_max_date,
  DATE_DIFF(a.pregnancy_anchor_max_date, a.pregnancy_anchor_min_date, DAY)
    AS pregnancy_anchor_spread_days,

  (
    a.any_review_flag
    OR DATE_DIFF(a.pregnancy_anchor_max_date, a.pregnancy_anchor_min_date, DAY)
       > sigizi_episode_anchor_tolerance_days
  ) AS sigizi_episode_review_flag,

  a.sigizi_member_record_count,
  COALESCE(st.sigizi_source_tables, ARRAY<STRING>[]) AS sigizi_source_tables,
  COALESCE(ms.sigizi_member_source_record_ids, ARRAY<STRING>[]) AS sigizi_member_source_record_ids,

  COALESCE(im.mother_identity_methods, ARRAY<STRING>[]) AS mother_identity_methods,
  a.sigizi_identity_propagated_record_count,
  a.sigizi_ambiguous_identity_record_count,
  a.sigizi_max_signature_row_count,
  a.sigizi_distinct_pregnancy_signature_count,

  a.within_sigizi_episode_count,

  COALESCE(
    mei.within_sigizi_member_episode_ids,
    ARRAY<STRING>[]
  ) AS within_sigizi_member_episode_ids

FROM scalar_agg a
JOIN `_SESSION.t_sigizi_episode_quality_v3_3` anchor
  ON anchor.sigizi_episode_id = a.canonical_sigizi_episode_id
LEFT JOIN source_tables st
  USING (canonical_sigizi_episode_id)
LEFT JOIN member_source_ids ms
  USING (canonical_sigizi_episode_id)
LEFT JOIN identity_methods im
  USING (canonical_sigizi_episode_id)
LEFT JOIN member_episode_ids mei
  USING (canonical_sigizi_episode_id);


-- ============================================================================
-- STAGE 2.5B - WITHIN-ePUS CANONICALIZATION
-- ============================================================================

CREATE OR REPLACE TEMP TABLE `_SESSION.t_epus_episode_quality_v3_3`
CLUSTER BY nik_clean, puskesmas_norm, epus_episode_id
AS
SELECT
  e.*,
  (
      IF(nik_is_trusted(nik_clean), 100, IF(nik_clean IS NOT NULL, 5, 0))
    + IF(tanggal_lahir_ibu IS NOT NULL, 25, 0)
    + IF(hpht_epus IS NOT NULL, 30, 0)
    + IF(hpl_epus IS NOT NULL, 15, 0)
    + IF(delivery_epus IS NOT NULL, 15, 0)
    + IF(no_hp_clean IS NOT NULL AND LENGTH(no_hp_clean) >= 8, 8, 0)
    + IF(puskesmas_norm IS NOT NULL, 5, 0)
    + IF(desa_norm IS NOT NULL, 3, 0)
  ) AS episode_quality_score
FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_adapter_v3_3` e;

CREATE OR REPLACE TEMP TABLE `_SESSION.t_epus_within_source_candidates_v3_3`
CLUSTER BY member_episode_id, candidate_anchor_episode_id
AS
-- 1. Exact NIK + compatible pregnancy anchor
SELECT
  a.epus_episode_id AS member_episode_id,
  b.epus_episode_id AS candidate_anchor_episode_id,
  'NIK+ANCHOR' AS within_source_match_method,
  1 AS within_source_match_priority,
  'VERY_HIGH' AS within_source_match_confidence,
  ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY)) AS anchor_difference_days,
  ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY)) AS match_date_difference_days,
  a.episode_quality_score AS member_quality_score,
  b.episode_quality_score AS candidate_anchor_quality_score
FROM `_SESSION.t_epus_episode_quality_v3_3` a
JOIN `_SESSION.t_epus_episode_quality_v3_3` b
  ON a.epus_episode_id != b.epus_episode_id
 AND a.nik_clean IS NOT NULL
 AND b.nik_clean IS NOT NULL
 AND a.nik_clean = b.nik_clean
 AND a.pregnancy_anchor_date IS NOT NULL
 AND b.pregnancy_anchor_date IS NOT NULL
 AND ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY)) <= within_source_anchor_tolerance_days
;

-- 2. Strong identity override; different NIKs allowed only here.
INSERT INTO `_SESSION.t_epus_within_source_candidates_v3_3`
SELECT
  a.epus_episode_id, b.epus_episode_id,
  'STRONG_NAME+DOB+HPHT_14D+CORROBORATOR', 2, 'VERY_HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY)),
  ABS(DATE_DIFF(a.hpht_epus, b.hpht_epus, DAY)),
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_epus_episode_quality_v3_3` a
JOIN `_SESSION.t_epus_episode_quality_v3_3` b
  ON a.epus_episode_id != b.epus_episode_id
 AND a.nama_core_norm IS NOT NULL AND b.nama_core_norm IS NOT NULL
 AND (a.nama_core_norm = b.nama_core_norm OR compact_name(a.nama_core_norm) = compact_name(b.nama_core_norm))
 AND a.tanggal_lahir_ibu IS NOT NULL AND a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
 AND a.hpht_epus IS NOT NULL AND b.hpht_epus IS NOT NULL
 AND ABS(DATE_DIFF(a.hpht_epus, b.hpht_epus, DAY)) <= strong_hpht_tolerance_days
 AND (
      (a.hpl_epus IS NOT NULL AND b.hpl_epus IS NOT NULL
       AND ABS(DATE_DIFF(a.hpl_epus, b.hpl_epus, DAY)) <= strong_hpl_tolerance_days)
   OR (a.delivery_epus IS NOT NULL AND b.delivery_epus IS NOT NULL
       AND ABS(DATE_DIFF(a.delivery_epus, b.delivery_epus, DAY)) <= delivery_tolerance_days)
   OR (a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm)
   OR (a.desa_norm IS NOT NULL AND a.desa_norm = b.desa_norm)
   OR (norm_key(a.posyandu) IS NOT NULL AND norm_key(a.posyandu) = norm_key(b.posyandu))
   OR (a.no_hp_clean IS NOT NULL AND LENGTH(a.no_hp_clean) >= 8 AND a.no_hp_clean = b.no_hp_clean)
 )
;

INSERT INTO `_SESSION.t_epus_within_source_candidates_v3_3`
SELECT
  a.epus_episode_id, b.epus_episode_id,
  'STRONG_NAME+DOB+HPL_14D+CORROBORATOR', 3, 'HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY)),
  ABS(DATE_DIFF(a.hpl_epus, b.hpl_epus, DAY)),
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_epus_episode_quality_v3_3` a
JOIN `_SESSION.t_epus_episode_quality_v3_3` b
  ON a.epus_episode_id != b.epus_episode_id
 AND a.nama_core_norm IS NOT NULL AND b.nama_core_norm IS NOT NULL
 AND (a.nama_core_norm = b.nama_core_norm OR compact_name(a.nama_core_norm) = compact_name(b.nama_core_norm))
 AND a.tanggal_lahir_ibu IS NOT NULL AND a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
 AND a.hpl_epus IS NOT NULL AND b.hpl_epus IS NOT NULL
 AND ABS(DATE_DIFF(a.hpl_epus, b.hpl_epus, DAY)) <= strong_hpl_tolerance_days
 AND (
      (a.delivery_epus IS NOT NULL AND b.delivery_epus IS NOT NULL
       AND ABS(DATE_DIFF(a.delivery_epus, b.delivery_epus, DAY)) <= delivery_tolerance_days)
   OR (a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm)
   OR (a.desa_norm IS NOT NULL AND a.desa_norm = b.desa_norm)
   OR (norm_key(a.posyandu) IS NOT NULL AND norm_key(a.posyandu) = norm_key(b.posyandu))
   OR (a.no_hp_clean IS NOT NULL AND LENGTH(a.no_hp_clean) >= 8 AND a.no_hp_clean = b.no_hp_clean)
 )
;

INSERT INTO `_SESSION.t_epus_within_source_candidates_v3_3`
SELECT
  a.epus_episode_id, b.epus_episode_id,
  'STRONG_NAME+DOB+DELIVERY_3D+CORROBORATOR', 4, 'HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY)),
  ABS(DATE_DIFF(a.delivery_epus, b.delivery_epus, DAY)),
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_epus_episode_quality_v3_3` a
JOIN `_SESSION.t_epus_episode_quality_v3_3` b
  ON a.epus_episode_id != b.epus_episode_id
 AND a.nama_core_norm IS NOT NULL AND b.nama_core_norm IS NOT NULL
 AND (a.nama_core_norm = b.nama_core_norm OR compact_name(a.nama_core_norm) = compact_name(b.nama_core_norm))
 AND a.tanggal_lahir_ibu IS NOT NULL AND a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
 AND a.delivery_epus IS NOT NULL AND b.delivery_epus IS NOT NULL
 AND ABS(DATE_DIFF(a.delivery_epus, b.delivery_epus, DAY)) <= delivery_tolerance_days
 AND (
      (a.hpl_epus IS NOT NULL AND b.hpl_epus IS NOT NULL
       AND ABS(DATE_DIFF(a.hpl_epus, b.hpl_epus, DAY)) <= strong_hpl_tolerance_days)
   OR (a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm)
   OR (a.desa_norm IS NOT NULL AND a.desa_norm = b.desa_norm)
   OR (norm_key(a.posyandu) IS NOT NULL AND norm_key(a.posyandu) = norm_key(b.posyandu))
   OR (a.no_hp_clean IS NOT NULL AND LENGTH(a.no_hp_clean) >= 8 AND a.no_hp_clean = b.no_hp_clean)
 )
;

-- Weaker rules: trusted-NIK conflict is still a blocker.
INSERT INTO `_SESSION.t_epus_within_source_candidates_v3_3`
SELECT a.epus_episode_id, b.epus_episode_id,
  'NAMA_CORE+DOB+HPHT_EXACT', 10, 'VERY_HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY)), 0,
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_epus_episode_quality_v3_3` a
JOIN `_SESSION.t_epus_episode_quality_v3_3` b
  ON a.epus_episode_id != b.epus_episode_id
 AND a.nama_core_norm IS NOT NULL AND a.nama_core_norm = b.nama_core_norm
 AND a.tanggal_lahir_ibu IS NOT NULL AND a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
 AND a.hpht_epus IS NOT NULL AND a.hpht_epus = b.hpht_epus
 AND NOT nik_hard_conflict(a.nik_clean, b.nik_clean)
;

INSERT INTO `_SESSION.t_epus_within_source_candidates_v3_3`
SELECT a.epus_episode_id, b.epus_episode_id,
  'NAMA_CORE+DOB+HPHT_7D', 11, 'HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY)),
  ABS(DATE_DIFF(a.hpht_epus, b.hpht_epus, DAY)),
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_epus_episode_quality_v3_3` a
JOIN `_SESSION.t_epus_episode_quality_v3_3` b
  ON a.epus_episode_id != b.epus_episode_id
 AND a.nama_core_norm IS NOT NULL AND a.nama_core_norm = b.nama_core_norm
 AND a.tanggal_lahir_ibu IS NOT NULL AND a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
 AND a.hpht_epus IS NOT NULL AND b.hpht_epus IS NOT NULL
 AND ABS(DATE_DIFF(a.hpht_epus, b.hpht_epus, DAY)) BETWEEN 1 AND hpht_tolerance_days
 AND NOT nik_hard_conflict(a.nik_clean, b.nik_clean)
;

INSERT INTO `_SESSION.t_epus_within_source_candidates_v3_3`
SELECT a.epus_episode_id, b.epus_episode_id,
  'NAMA_CORE+DOB+PUSKESMAS+ANCHOR', 12, 'HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY)),
  ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY)),
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_epus_episode_quality_v3_3` a
JOIN `_SESSION.t_epus_episode_quality_v3_3` b
  ON a.epus_episode_id != b.epus_episode_id
 AND a.nama_core_norm IS NOT NULL AND a.nama_core_norm = b.nama_core_norm
 AND a.tanggal_lahir_ibu IS NOT NULL AND a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
 AND a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm
 AND a.pregnancy_anchor_date IS NOT NULL AND b.pregnancy_anchor_date IS NOT NULL
 AND ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY)) <= within_source_anchor_tolerance_days
 AND NOT nik_hard_conflict(a.nik_clean, b.nik_clean)
;

INSERT INTO `_SESSION.t_epus_within_source_candidates_v3_3`
SELECT a.epus_episode_id, b.epus_episode_id,
  'NAMA_CORE+HPHT_EXACT+PUSKESMAS', 13, 'HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY)), 0,
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_epus_episode_quality_v3_3` a
JOIN `_SESSION.t_epus_episode_quality_v3_3` b
  ON a.epus_episode_id != b.epus_episode_id
 AND a.nama_core_norm IS NOT NULL AND a.nama_core_norm = b.nama_core_norm
 AND a.hpht_epus IS NOT NULL AND a.hpht_epus = b.hpht_epus
 AND a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm
 AND NOT nik_hard_conflict(a.nik_clean, b.nik_clean)
;

INSERT INTO `_SESSION.t_epus_within_source_candidates_v3_3`
SELECT a.epus_episode_id, b.epus_episode_id,
  'NAMA_CORE+HPHT_7D+PUSKESMAS', 14, 'HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY)),
  ABS(DATE_DIFF(a.hpht_epus, b.hpht_epus, DAY)),
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_epus_episode_quality_v3_3` a
JOIN `_SESSION.t_epus_episode_quality_v3_3` b
  ON a.epus_episode_id != b.epus_episode_id
 AND a.nama_core_norm IS NOT NULL AND a.nama_core_norm = b.nama_core_norm
 AND a.hpht_epus IS NOT NULL AND b.hpht_epus IS NOT NULL
 AND ABS(DATE_DIFF(a.hpht_epus, b.hpht_epus, DAY)) BETWEEN 1 AND hpht_tolerance_days
 AND a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm
 AND NOT nik_hard_conflict(a.nik_clean, b.nik_clean)
;

INSERT INTO `_SESSION.t_epus_within_source_candidates_v3_3`
SELECT a.epus_episode_id, b.epus_episode_id,
  'NAMA_CORE+DELIVERY_3D+PUSKESMAS', 15, 'MEDIUM_HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY)),
  ABS(DATE_DIFF(a.delivery_epus, b.delivery_epus, DAY)),
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_epus_episode_quality_v3_3` a
JOIN `_SESSION.t_epus_episode_quality_v3_3` b
  ON a.epus_episode_id != b.epus_episode_id
 AND a.nama_core_norm IS NOT NULL AND a.nama_core_norm = b.nama_core_norm
 AND a.delivery_epus IS NOT NULL AND b.delivery_epus IS NOT NULL
 AND ABS(DATE_DIFF(a.delivery_epus, b.delivery_epus, DAY)) <= delivery_tolerance_days
 AND a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm
 AND NOT nik_hard_conflict(a.nik_clean, b.nik_clean)
;

INSERT INTO `_SESSION.t_epus_within_source_candidates_v3_3`
SELECT a.epus_episode_id, b.epus_episode_id,
  'NAMA_CORE+DOB+HPL_7D', 16, 'MEDIUM_HIGH',
  ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY)),
  ABS(DATE_DIFF(a.hpl_epus, b.hpl_epus, DAY)),
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_epus_episode_quality_v3_3` a
JOIN `_SESSION.t_epus_episode_quality_v3_3` b
  ON a.epus_episode_id != b.epus_episode_id
 AND a.nama_core_norm IS NOT NULL AND a.nama_core_norm = b.nama_core_norm
 AND a.tanggal_lahir_ibu IS NOT NULL AND a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
 AND a.hpl_epus IS NOT NULL AND b.hpl_epus IS NOT NULL
 AND ABS(DATE_DIFF(a.hpl_epus, b.hpl_epus, DAY)) <= hpl_tolerance_days
 AND NOT nik_hard_conflict(a.nik_clean, b.nik_clean)
;

INSERT INTO `_SESSION.t_epus_within_source_candidates_v3_3`
SELECT a.epus_episode_id, b.epus_episode_id,
  'NAMA_CORE+PHONE+PUSKESMAS+ANCHOR_30D', 17, 'MEDIUM',
  ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY)),
  ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY)),
  a.episode_quality_score, b.episode_quality_score
FROM `_SESSION.t_epus_episode_quality_v3_3` a
JOIN `_SESSION.t_epus_episode_quality_v3_3` b
  ON a.epus_episode_id != b.epus_episode_id
 AND a.nama_core_norm IS NOT NULL AND a.nama_core_norm = b.nama_core_norm
 AND a.no_hp_clean IS NOT NULL AND LENGTH(a.no_hp_clean) >= 8 AND a.no_hp_clean = b.no_hp_clean
 AND a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm
 AND a.pregnancy_anchor_date IS NOT NULL AND b.pregnancy_anchor_date IS NOT NULL
 AND ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY)) <= phone_anchor_tolerance_days
 AND NOT nik_hard_conflict(a.nik_clean, b.nik_clean)
;

CREATE OR REPLACE TEMP TABLE `_SESSION.t_epus_within_source_candidates_best_v3_3`
CLUSTER BY member_episode_id, candidate_anchor_episode_id
AS
SELECT * EXCEPT(pair_rn)
FROM (
  SELECT
    c.*,
    ROW_NUMBER() OVER (
      PARTITION BY member_episode_id, candidate_anchor_episode_id
      ORDER BY
        within_source_match_priority,
        match_date_difference_days,
        anchor_difference_days,
        candidate_anchor_episode_id
    ) AS pair_rn
  FROM `_SESSION.t_epus_within_source_candidates_v3_3` c
)
WHERE pair_rn = 1;


CREATE OR REPLACE TEMP TABLE `_SESSION.t_epus_within_source_anchors_v3_3`
CLUSTER BY epus_episode_id
AS
SELECT q.*
FROM `_SESSION.t_epus_episode_quality_v3_3` q
WHERE NOT EXISTS (
  SELECT 1
  FROM `_SESSION.t_epus_within_source_candidates_best_v3_3` c
  JOIN `_SESSION.t_epus_episode_quality_v3_3` b
    ON b.epus_episode_id = c.candidate_anchor_episode_id
  WHERE c.member_episode_id = q.epus_episode_id
    AND (
      b.episode_quality_score > q.episode_quality_score
      OR (
        b.episode_quality_score = q.episode_quality_score
        AND b.epus_episode_id < q.epus_episode_id
      )
    )
);


CREATE OR REPLACE TEMP TABLE `_SESSION.t_epus_within_source_anchor_candidates_v3_3`
CLUSTER BY member_episode_id, candidate_anchor_episode_id
AS
SELECT
  c.*,
  a.episode_quality_score AS eligible_anchor_quality_score
FROM `_SESSION.t_epus_within_source_candidates_best_v3_3` c
JOIN `_SESSION.t_epus_within_source_anchors_v3_3` a
  ON a.epus_episode_id = c.candidate_anchor_episode_id;


CREATE OR REPLACE TABLE `spheres-lombok-barat.kohort_bumil_v3.t_epus_episode_canonical_map_v3_3`
CLUSTER BY member_epus_episode_id, canonical_epus_episode_id
AS
SELECT
  member_epus_episode_id,
  canonical_epus_episode_id,
  within_source_match_method,
  within_source_match_priority,
  within_source_match_confidence,
  anchor_difference_days,
  match_date_difference_days
FROM (
  SELECT
    q.epus_episode_id AS member_epus_episode_id,
    COALESCE(c.candidate_anchor_episode_id, q.epus_episode_id)
      AS canonical_epus_episode_id,
    c.within_source_match_method,
    c.within_source_match_priority,
    c.within_source_match_confidence,
    c.anchor_difference_days,
    c.match_date_difference_days,

    ROW_NUMBER() OVER (
      PARTITION BY q.epus_episode_id
      ORDER BY
        c.within_source_match_priority IS NULL,
        c.within_source_match_priority,
        c.match_date_difference_days,
        c.anchor_difference_days,
        c.eligible_anchor_quality_score DESC,
        c.candidate_anchor_episode_id
    ) AS rn
  FROM `_SESSION.t_epus_episode_quality_v3_3` q
  LEFT JOIN `_SESSION.t_epus_within_source_anchor_candidates_v3_3` c
    ON c.member_episode_id = q.epus_episode_id
)
WHERE rn = 1;


CREATE OR REPLACE TABLE `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3`
CLUSTER BY nik_clean, puskesmas_norm, epus_episode_id
AS
WITH members AS (
  SELECT
    m.canonical_epus_episode_id,
    q.*
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_episode_canonical_map_v3_3` m
  JOIN `_SESSION.t_epus_episode_quality_v3_3` q
    ON q.epus_episode_id = m.member_epus_episode_id
),

agg AS (
  SELECT
    canonical_epus_episode_id,

    ARRAY_AGG(
      STRUCT(nik_clean AS value, episode_quality_score AS q, epus_episode_id AS id)
      ORDER BY nik_clean IS NULL, episode_quality_score DESC, epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS nik_pick,

    ARRAY_AGG(
      STRUCT(
        nama_ibu AS value,
        nama_norm AS value_norm,
        nama_core_norm AS value_core,
        episode_quality_score AS q,
        epus_episode_id AS id
      )
      ORDER BY nama_core_norm IS NULL, nik_clean IS NULL, episode_quality_score DESC, epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS name_pick,

    ARRAY_AGG(
      STRUCT(tanggal_lahir_ibu AS value, episode_quality_score AS q, epus_episode_id AS id)
      ORDER BY tanggal_lahir_ibu IS NULL, episode_quality_score DESC, epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS dob_pick,

    ARRAY_AGG(
      STRUCT(no_hp_clean AS value, episode_quality_score AS q, epus_episode_id AS id)
      ORDER BY no_hp_clean IS NULL, LENGTH(COALESCE(no_hp_clean, '')) DESC, episode_quality_score DESC, epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS phone_pick,

    ARRAY_AGG(
      STRUCT(puskesmas AS value, puskesmas_norm AS value_norm, episode_quality_score AS q, epus_episode_id AS id)
      ORDER BY puskesmas_norm IS NULL, episode_quality_score DESC, epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS puskesmas_pick,

    ARRAY_AGG(
      STRUCT(desa AS value, desa_norm AS value_norm, episode_quality_score AS q, epus_episode_id AS id)
      ORDER BY desa_norm IS NULL, episode_quality_score DESC, epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS desa_pick,

    ARRAY_AGG(
      STRUCT(posyandu AS value, episode_quality_score AS q, epus_episode_id AS id)
      ORDER BY posyandu IS NULL, episode_quality_score DESC, epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS posyandu_pick,

    ARRAY_AGG(
      STRUCT(alamat AS value, episode_quality_score AS q, epus_episode_id AS id)
      ORDER BY alamat IS NULL, episode_quality_score DESC, epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS alamat_pick,

    ARRAY_AGG(
      STRUCT(hpht_epus AS value, episode_quality_score AS q, epus_episode_id AS id)
      ORDER BY hpht_epus IS NULL, episode_quality_score DESC, epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS hpht_pick,

    ARRAY_AGG(
      STRUCT(hpl_epus AS value, episode_quality_score AS q, epus_episode_id AS id)
      ORDER BY hpl_epus IS NULL, episode_quality_score DESC, epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS hpl_pick,

    ARRAY_AGG(
      STRUCT(delivery_epus AS value, episode_quality_score AS q, epus_episode_id AS id)
      ORDER BY delivery_epus IS NULL, episode_quality_score DESC, epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS delivery_pick,

    ARRAY_AGG(
      STRUCT(epus_episode_source_key AS value, episode_quality_score AS q, epus_episode_id AS id)
      ORDER BY epus_episode_source_key IS NULL, episode_quality_score DESC, epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS source_key_pick,

    ARRAY_AGG(
      STRUCT(source_json AS value, episode_quality_score AS q, epus_episode_id AS id)
      ORDER BY episode_quality_score DESC, epus_episode_id
      LIMIT 1
    )[SAFE_OFFSET(0)] AS source_json_pick,

    MIN(first_anc_date) AS first_anc_date,
    MAX(last_anc_date) AS last_anc_date,

    COUNT(*) AS within_epus_episode_count

  FROM members
  GROUP BY canonical_epus_episode_id
),

member_episode_ids AS (
  SELECT
    canonical_epus_episode_id,
    ARRAY_AGG(
      member_epus_episode_id
      ORDER BY member_epus_episode_id
    ) AS within_epus_member_episode_ids
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_episode_canonical_map_v3_3`
  GROUP BY canonical_epus_episode_id
),

source_keys AS (
  SELECT
    m.canonical_epus_episode_id,
    ARRAY_AGG(
      DISTINCT q.epus_episode_source_key
      ORDER BY q.epus_episode_source_key
    ) AS epus_episode_source_keys
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_episode_canonical_map_v3_3` m
  JOIN `_SESSION.t_epus_episode_quality_v3_3` q
    ON q.epus_episode_id = m.member_epus_episode_id
  WHERE q.epus_episode_source_key IS NOT NULL
  GROUP BY m.canonical_epus_episode_id
)

SELECT
  a.canonical_epus_episode_id AS epus_episode_id,
  a.source_key_pick.value AS epus_episode_source_key,

  a.nik_pick.value AS nik_clean,

  a.name_pick.value AS nama_ibu,
  a.name_pick.value_norm AS nama_norm,
  a.name_pick.value_core AS nama_core_norm,

  a.dob_pick.value AS tanggal_lahir_ibu,
  a.phone_pick.value AS no_hp_clean,

  a.puskesmas_pick.value AS puskesmas,
  a.puskesmas_pick.value_norm AS puskesmas_norm,

  a.desa_pick.value AS desa,
  a.desa_pick.value_norm AS desa_norm,

  a.posyandu_pick.value AS posyandu,
  a.alamat_pick.value AS alamat,

  a.hpht_pick.value AS hpht_epus,
  a.hpl_pick.value AS hpl_epus,
  a.delivery_pick.value AS delivery_epus,

  CASE
    WHEN a.hpht_pick.value IS NOT NULL
      THEN DATE_ADD(a.hpht_pick.value, INTERVAL 280 DAY)
  END AS hpl_from_epus_hpht,

  a.first_anc_date,
  a.last_anc_date,

  COALESCE(
    a.hpht_pick.value,
    DATE_SUB(a.hpl_pick.value, INTERVAL 280 DAY)
  ) AS pregnancy_anchor_date,

  a.source_json_pick.value AS source_json,

  a.within_epus_episode_count,

  COALESCE(
    mei.within_epus_member_episode_ids,
    ARRAY<STRING>[]
  ) AS within_epus_member_episode_ids,

  COALESCE(
    sk.epus_episode_source_keys,
    ARRAY<STRING>[]
  ) AS epus_episode_source_keys

FROM agg a
LEFT JOIN member_episode_ids mei
  USING (canonical_epus_episode_id)
LEFT JOIN source_keys sk
  USING (canonical_epus_episode_id);

-- ============================================================================
-- STAGE 3 - CROSS-SOURCE MATCHING ON CANONICAL SOURCE EPISODES
-- ============================================================================
-- ============================================================================
-- A. MATERIALIZE ALL CROSS-SOURCE CANDIDATE PAIRS
--    Each matching rule is a separate statement to prevent planner explosion.
-- ============================================================================

CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_cross_source_candidates_v3_3`
CLUSTER BY epus_episode_id, sigizi_episode_id
AS
-- 1. Exact NIK + compatible pregnancy anchor
SELECT
  e.epus_episode_id,
  s.sigizi_episode_id,
  'NIK+ANCHOR' AS cross_source_match_method,
  1 AS cross_source_match_priority,
  'VERY_HIGH' AS cross_source_match_confidence,
  ABS(DATE_DIFF(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date, DAY)) AS anchor_difference_days,
  ABS(DATE_DIFF(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date, DAY)) AS match_date_difference_days
FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` e
JOIN `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_canonical_v3_3` s
  ON e.nik_clean IS NOT NULL
 AND s.nik_clean IS NOT NULL
 AND e.nik_clean = s.nik_clean
 AND e.pregnancy_anchor_date IS NOT NULL
 AND s.pregnancy_anchor_min_date IS NOT NULL
 AND ABS(DATE_DIFF(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date, DAY)) <= cross_source_anchor_tolerance_days
;

-- 2. STRONG IDENTITY OVERRIDE.
--    Different trusted NIKs are allowed when mother identity + pregnancy evidence
--    is sufficiently strong. This directly covers cases like SURYA, YULI and
--    ZARRATUL where NIK conflicts but the same pregnancy is evident.
INSERT INTO `_SESSION.t_pregnancy_cross_source_candidates_v3_3`
SELECT
  e.epus_episode_id,
  s.sigizi_episode_id,
  'STRONG_NAME+DOB+HPHT_14D+CORROBORATOR',
  2,
  'VERY_HIGH',
  ABS(DATE_DIFF(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date, DAY)),
  ABS(DATE_DIFF(e.hpht_epus, s.hpht_sigizi, DAY))
FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` e
JOIN `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_canonical_v3_3` s
  ON e.nama_core_norm IS NOT NULL
 AND s.nama_core_norm IS NOT NULL
 AND (
      e.nama_core_norm = s.nama_core_norm
      OR compact_name(e.nama_core_norm) = compact_name(s.nama_core_norm)
 )
 AND e.tanggal_lahir_ibu IS NOT NULL
 AND e.tanggal_lahir_ibu = s.tanggal_lahir_ibu
 AND e.hpht_epus IS NOT NULL
 AND s.hpht_sigizi IS NOT NULL
 AND ABS(DATE_DIFF(e.hpht_epus, s.hpht_sigizi, DAY)) <= strong_hpht_tolerance_days
 AND (
      (e.hpl_epus IS NOT NULL AND s.hpl_sigizi IS NOT NULL
       AND ABS(DATE_DIFF(e.hpl_epus, s.hpl_sigizi, DAY)) <= strong_hpl_tolerance_days)
   OR (e.delivery_epus IS NOT NULL AND s.delivery_sigizi IS NOT NULL
       AND ABS(DATE_DIFF(e.delivery_epus, s.delivery_sigizi, DAY)) <= delivery_tolerance_days)
   OR (e.puskesmas_norm IS NOT NULL AND e.puskesmas_norm = s.puskesmas_norm)
   OR (e.desa_norm IS NOT NULL AND e.desa_norm = s.desa_norm)
   OR (norm_key(e.posyandu) IS NOT NULL AND norm_key(e.posyandu) = norm_key(s.posyandu))
   OR (e.no_hp_clean IS NOT NULL AND LENGTH(e.no_hp_clean) >= 8 AND e.no_hp_clean = s.no_hp_clean)
 )
;

-- 3. Strong HPL-based identity override
INSERT INTO `_SESSION.t_pregnancy_cross_source_candidates_v3_3`
SELECT
  e.epus_episode_id, s.sigizi_episode_id,
  'STRONG_NAME+DOB+HPL_14D+CORROBORATOR', 3, 'HIGH',
  ABS(DATE_DIFF(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date, DAY)),
  ABS(DATE_DIFF(e.hpl_epus, s.hpl_sigizi, DAY))
FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` e
JOIN `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_canonical_v3_3` s
  ON e.nama_core_norm IS NOT NULL AND s.nama_core_norm IS NOT NULL
 AND (e.nama_core_norm = s.nama_core_norm OR compact_name(e.nama_core_norm) = compact_name(s.nama_core_norm))
 AND e.tanggal_lahir_ibu IS NOT NULL AND e.tanggal_lahir_ibu = s.tanggal_lahir_ibu
 AND e.hpl_epus IS NOT NULL AND s.hpl_sigizi IS NOT NULL
 AND ABS(DATE_DIFF(e.hpl_epus, s.hpl_sigizi, DAY)) <= strong_hpl_tolerance_days
 AND (
      (e.delivery_epus IS NOT NULL AND s.delivery_sigizi IS NOT NULL
       AND ABS(DATE_DIFF(e.delivery_epus, s.delivery_sigizi, DAY)) <= delivery_tolerance_days)
   OR (e.puskesmas_norm IS NOT NULL AND e.puskesmas_norm = s.puskesmas_norm)
   OR (e.desa_norm IS NOT NULL AND e.desa_norm = s.desa_norm)
   OR (norm_key(e.posyandu) IS NOT NULL AND norm_key(e.posyandu) = norm_key(s.posyandu))
   OR (e.no_hp_clean IS NOT NULL AND LENGTH(e.no_hp_clean) >= 8 AND e.no_hp_clean = s.no_hp_clean)
 )
;

-- 4. Strong delivery-based identity override
INSERT INTO `_SESSION.t_pregnancy_cross_source_candidates_v3_3`
SELECT
  e.epus_episode_id, s.sigizi_episode_id,
  'STRONG_NAME+DOB+DELIVERY_3D+CORROBORATOR', 4, 'HIGH',
  ABS(DATE_DIFF(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date, DAY)),
  ABS(DATE_DIFF(e.delivery_epus, s.delivery_sigizi, DAY))
FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` e
JOIN `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_canonical_v3_3` s
  ON e.nama_core_norm IS NOT NULL AND s.nama_core_norm IS NOT NULL
 AND (e.nama_core_norm = s.nama_core_norm OR compact_name(e.nama_core_norm) = compact_name(s.nama_core_norm))
 AND e.tanggal_lahir_ibu IS NOT NULL AND e.tanggal_lahir_ibu = s.tanggal_lahir_ibu
 AND e.delivery_epus IS NOT NULL AND s.delivery_sigizi IS NOT NULL
 AND ABS(DATE_DIFF(e.delivery_epus, s.delivery_sigizi, DAY)) <= delivery_tolerance_days
 AND (
      (e.hpl_epus IS NOT NULL AND s.hpl_sigizi IS NOT NULL
       AND ABS(DATE_DIFF(e.hpl_epus, s.hpl_sigizi, DAY)) <= strong_hpl_tolerance_days)
   OR (e.puskesmas_norm IS NOT NULL AND e.puskesmas_norm = s.puskesmas_norm)
   OR (e.desa_norm IS NOT NULL AND e.desa_norm = s.desa_norm)
   OR (norm_key(e.posyandu) IS NOT NULL AND norm_key(e.posyandu) = norm_key(s.posyandu))
   OR (e.no_hp_clean IS NOT NULL AND LENGTH(e.no_hp_clean) >= 8 AND e.no_hp_clean = s.no_hp_clean)
 )
;

-- --------------------------------------------------------------------------
-- Weaker fallback rules. These continue to block trusted-NIK conflicts.
-- --------------------------------------------------------------------------
INSERT INTO `_SESSION.t_pregnancy_cross_source_candidates_v3_3`
SELECT e.epus_episode_id, s.sigizi_episode_id,
  'NAMA_CORE+DOB+HPHT_EXACT', 10, 'VERY_HIGH',
  ABS(DATE_DIFF(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date, DAY)), 0
FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` e
JOIN `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_canonical_v3_3` s
  ON e.nama_core_norm IS NOT NULL AND e.nama_core_norm = s.nama_core_norm
 AND e.tanggal_lahir_ibu IS NOT NULL AND e.tanggal_lahir_ibu = s.tanggal_lahir_ibu
 AND e.hpht_epus IS NOT NULL AND e.hpht_epus = s.hpht_sigizi
 AND NOT nik_hard_conflict(e.nik_clean, s.nik_clean)
;

INSERT INTO `_SESSION.t_pregnancy_cross_source_candidates_v3_3`
SELECT e.epus_episode_id, s.sigizi_episode_id,
  'NAMA_CORE+DOB+HPHT_7D', 11, 'HIGH',
  ABS(DATE_DIFF(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date, DAY)),
  ABS(DATE_DIFF(e.hpht_epus, s.hpht_sigizi, DAY))
FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` e
JOIN `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_canonical_v3_3` s
  ON e.nama_core_norm IS NOT NULL AND e.nama_core_norm = s.nama_core_norm
 AND e.tanggal_lahir_ibu IS NOT NULL AND e.tanggal_lahir_ibu = s.tanggal_lahir_ibu
 AND e.hpht_epus IS NOT NULL AND s.hpht_sigizi IS NOT NULL
 AND ABS(DATE_DIFF(e.hpht_epus, s.hpht_sigizi, DAY)) BETWEEN 1 AND hpht_tolerance_days
 AND NOT nik_hard_conflict(e.nik_clean, s.nik_clean)
;

INSERT INTO `_SESSION.t_pregnancy_cross_source_candidates_v3_3`
SELECT e.epus_episode_id, s.sigizi_episode_id,
  'NAMA_CORE+DOB+PUSKESMAS+ANCHOR', 12, 'HIGH',
  ABS(DATE_DIFF(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date, DAY)),
  ABS(DATE_DIFF(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date, DAY))
FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` e
JOIN `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_canonical_v3_3` s
  ON e.nama_core_norm IS NOT NULL AND e.nama_core_norm = s.nama_core_norm
 AND e.tanggal_lahir_ibu IS NOT NULL AND e.tanggal_lahir_ibu = s.tanggal_lahir_ibu
 AND e.puskesmas_norm IS NOT NULL AND e.puskesmas_norm = s.puskesmas_norm
 AND e.pregnancy_anchor_date IS NOT NULL AND s.pregnancy_anchor_min_date IS NOT NULL
 AND ABS(DATE_DIFF(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date, DAY)) <= cross_source_anchor_tolerance_days
 AND NOT nik_hard_conflict(e.nik_clean, s.nik_clean)
;

INSERT INTO `_SESSION.t_pregnancy_cross_source_candidates_v3_3`
SELECT e.epus_episode_id, s.sigizi_episode_id,
  'NAMA_CORE+HPHT_EXACT+PUSKESMAS', 13, 'HIGH',
  ABS(DATE_DIFF(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date, DAY)), 0
FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` e
JOIN `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_canonical_v3_3` s
  ON e.nama_core_norm IS NOT NULL AND e.nama_core_norm = s.nama_core_norm
 AND e.hpht_epus IS NOT NULL AND e.hpht_epus = s.hpht_sigizi
 AND e.puskesmas_norm IS NOT NULL AND e.puskesmas_norm = s.puskesmas_norm
 AND NOT nik_hard_conflict(e.nik_clean, s.nik_clean)
;

INSERT INTO `_SESSION.t_pregnancy_cross_source_candidates_v3_3`
SELECT e.epus_episode_id, s.sigizi_episode_id,
  'NAMA_CORE+HPHT_7D+PUSKESMAS', 14, 'HIGH',
  ABS(DATE_DIFF(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date, DAY)),
  ABS(DATE_DIFF(e.hpht_epus, s.hpht_sigizi, DAY))
FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` e
JOIN `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_canonical_v3_3` s
  ON e.nama_core_norm IS NOT NULL AND e.nama_core_norm = s.nama_core_norm
 AND e.hpht_epus IS NOT NULL AND s.hpht_sigizi IS NOT NULL
 AND ABS(DATE_DIFF(e.hpht_epus, s.hpht_sigizi, DAY)) BETWEEN 1 AND hpht_tolerance_days
 AND e.puskesmas_norm IS NOT NULL AND e.puskesmas_norm = s.puskesmas_norm
 AND NOT nik_hard_conflict(e.nik_clean, s.nik_clean)
;

INSERT INTO `_SESSION.t_pregnancy_cross_source_candidates_v3_3`
SELECT e.epus_episode_id, s.sigizi_episode_id,
  'NAMA_CORE+DELIVERY_3D+PUSKESMAS', 15, 'MEDIUM_HIGH',
  ABS(DATE_DIFF(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date, DAY)),
  ABS(DATE_DIFF(e.delivery_epus, s.delivery_sigizi, DAY))
FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` e
JOIN `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_canonical_v3_3` s
  ON e.nama_core_norm IS NOT NULL AND e.nama_core_norm = s.nama_core_norm
 AND e.delivery_epus IS NOT NULL AND s.delivery_sigizi IS NOT NULL
 AND ABS(DATE_DIFF(e.delivery_epus, s.delivery_sigizi, DAY)) <= delivery_tolerance_days
 AND e.puskesmas_norm IS NOT NULL AND e.puskesmas_norm = s.puskesmas_norm
 AND NOT nik_hard_conflict(e.nik_clean, s.nik_clean)
;

INSERT INTO `_SESSION.t_pregnancy_cross_source_candidates_v3_3`
SELECT e.epus_episode_id, s.sigizi_episode_id,
  'NAMA_CORE+DOB+HPL_7D', 16, 'MEDIUM_HIGH',
  ABS(DATE_DIFF(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date, DAY)),
  ABS(DATE_DIFF(e.hpl_epus, s.hpl_sigizi, DAY))
FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` e
JOIN `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_canonical_v3_3` s
  ON e.nama_core_norm IS NOT NULL AND e.nama_core_norm = s.nama_core_norm
 AND e.tanggal_lahir_ibu IS NOT NULL AND e.tanggal_lahir_ibu = s.tanggal_lahir_ibu
 AND e.hpl_epus IS NOT NULL AND s.hpl_sigizi IS NOT NULL
 AND ABS(DATE_DIFF(e.hpl_epus, s.hpl_sigizi, DAY)) <= hpl_tolerance_days
 AND NOT nik_hard_conflict(e.nik_clean, s.nik_clean)
;

INSERT INTO `_SESSION.t_pregnancy_cross_source_candidates_v3_3`
SELECT e.epus_episode_id, s.sigizi_episode_id,
  'NAMA_CORE+PHONE+PUSKESMAS+ANCHOR_30D', 17, 'MEDIUM',
  ABS(DATE_DIFF(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date, DAY)),
  ABS(DATE_DIFF(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date, DAY))
FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` e
JOIN `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_canonical_v3_3` s
  ON e.nama_core_norm IS NOT NULL AND e.nama_core_norm = s.nama_core_norm
 AND e.no_hp_clean IS NOT NULL AND LENGTH(e.no_hp_clean) >= 8 AND e.no_hp_clean = s.no_hp_clean
 AND e.puskesmas_norm IS NOT NULL AND e.puskesmas_norm = s.puskesmas_norm
 AND e.pregnancy_anchor_date IS NOT NULL AND s.pregnancy_anchor_min_date IS NOT NULL
 AND ABS(DATE_DIFF(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date, DAY)) <= phone_anchor_tolerance_days
 AND NOT nik_hard_conflict(e.nik_clean, s.nik_clean)
;

-- ============================================================================
-- B. KEEP ONLY THE STRONGEST RULE FOR EACH ePUS-SIGIZI PAIR
-- ============================================================================

CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_cross_source_candidates_best_v3_3`
CLUSTER BY epus_episode_id, sigizi_episode_id
AS
SELECT * EXCEPT(pair_rn)
FROM (
  SELECT
    c.*,
    ROW_NUMBER() OVER (
      PARTITION BY epus_episode_id, sigizi_episode_id
      ORDER BY
        cross_source_match_priority,
        match_date_difference_days,
        anchor_difference_days,
        cross_source_match_method
    ) AS pair_rn
  FROM `_SESSION.t_pregnancy_cross_source_candidates_v3_3` c
)
WHERE pair_rn = 1;


-- ============================================================================
-- C. GREEDY ONE-TO-ONE ASSIGNMENT - MATERIALIZED BETWEEN ROUNDS
-- ============================================================================

-- Round 1
CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_cross_source_matches_v3_3`
CLUSTER BY epus_episode_id, sigizi_episode_id
AS
SELECT
  epus_episode_id,
  sigizi_episode_id,
  cross_source_match_method,
  cross_source_match_priority,
  cross_source_match_confidence,
  anchor_difference_days,
  match_date_difference_days,
  1 AS assignment_round
FROM (
  SELECT
    c.*,
    ROW_NUMBER() OVER (
      PARTITION BY epus_episode_id
      ORDER BY
        cross_source_match_priority,
        match_date_difference_days,
        anchor_difference_days,
        sigizi_episode_id
    ) AS epus_rank,
    ROW_NUMBER() OVER (
      PARTITION BY sigizi_episode_id
      ORDER BY
        cross_source_match_priority,
        match_date_difference_days,
        anchor_difference_days,
        epus_episode_id
    ) AS sigizi_rank
  FROM `_SESSION.t_pregnancy_cross_source_candidates_best_v3_3` c
)
WHERE epus_rank = 1
  AND sigizi_rank = 1;

-- Round 2
CREATE TEMP TABLE round2_ranked AS
SELECT
  c.*,
  ROW_NUMBER() OVER (
    PARTITION BY c.epus_episode_id
    ORDER BY
      c.cross_source_match_priority,
      c.match_date_difference_days,
      c.anchor_difference_days,
      c.sigizi_episode_id
  ) AS epus_rank,
  ROW_NUMBER() OVER (
    PARTITION BY c.sigizi_episode_id
    ORDER BY
      c.cross_source_match_priority,
      c.match_date_difference_days,
      c.anchor_difference_days,
      c.epus_episode_id
  ) AS sigizi_rank
FROM `_SESSION.t_pregnancy_cross_source_candidates_best_v3_3` c
WHERE NOT EXISTS (
  SELECT 1
  FROM `_SESSION.t_pregnancy_cross_source_matches_v3_3` a
  WHERE a.epus_episode_id = c.epus_episode_id
)
AND NOT EXISTS (
  SELECT 1
  FROM `_SESSION.t_pregnancy_cross_source_matches_v3_3` a
  WHERE a.sigizi_episode_id = c.sigizi_episode_id
);

INSERT INTO `_SESSION.t_pregnancy_cross_source_matches_v3_3`
(
  epus_episode_id,
  sigizi_episode_id,
  cross_source_match_method,
  cross_source_match_priority,
  cross_source_match_confidence,
  anchor_difference_days,
  match_date_difference_days,
  assignment_round
)
SELECT
  epus_episode_id,
  sigizi_episode_id,
  cross_source_match_method,
  cross_source_match_priority,
  cross_source_match_confidence,
  anchor_difference_days,
  match_date_difference_days,
  2 AS assignment_round
FROM round2_ranked
WHERE epus_rank = 1
  AND sigizi_rank = 1;


-- Round 3
CREATE TEMP TABLE round3_ranked AS
SELECT
  c.*,
  ROW_NUMBER() OVER (
    PARTITION BY c.epus_episode_id
    ORDER BY
      c.cross_source_match_priority,
      c.match_date_difference_days,
      c.anchor_difference_days,
      c.sigizi_episode_id
  ) AS epus_rank,
  ROW_NUMBER() OVER (
    PARTITION BY c.sigizi_episode_id
    ORDER BY
      c.cross_source_match_priority,
      c.match_date_difference_days,
      c.anchor_difference_days,
      c.epus_episode_id
  ) AS sigizi_rank
FROM `_SESSION.t_pregnancy_cross_source_candidates_best_v3_3` c
WHERE NOT EXISTS (
  SELECT 1
  FROM `_SESSION.t_pregnancy_cross_source_matches_v3_3` a
  WHERE a.epus_episode_id = c.epus_episode_id
)
AND NOT EXISTS (
  SELECT 1
  FROM `_SESSION.t_pregnancy_cross_source_matches_v3_3` a
  WHERE a.sigizi_episode_id = c.sigizi_episode_id
);

INSERT INTO `_SESSION.t_pregnancy_cross_source_matches_v3_3`
(
  epus_episode_id,
  sigizi_episode_id,
  cross_source_match_method,
  cross_source_match_priority,
  cross_source_match_confidence,
  anchor_difference_days,
  match_date_difference_days,
  assignment_round
)
SELECT
  epus_episode_id,
  sigizi_episode_id,
  cross_source_match_method,
  cross_source_match_priority,
  cross_source_match_confidence,
  anchor_difference_days,
  match_date_difference_days,
  3 AS assignment_round
FROM round3_ranked
WHERE epus_rank = 1
  AND sigizi_rank = 1;


-- Round 4
CREATE TEMP TABLE round4_ranked AS
SELECT
  c.*,
  ROW_NUMBER() OVER (
    PARTITION BY c.epus_episode_id
    ORDER BY
      c.cross_source_match_priority,
      c.match_date_difference_days,
      c.anchor_difference_days,
      c.sigizi_episode_id
  ) AS epus_rank,
  ROW_NUMBER() OVER (
    PARTITION BY c.sigizi_episode_id
    ORDER BY
      c.cross_source_match_priority,
      c.match_date_difference_days,
      c.anchor_difference_days,
      c.epus_episode_id
  ) AS sigizi_rank
FROM `_SESSION.t_pregnancy_cross_source_candidates_best_v3_3` c
WHERE NOT EXISTS (
  SELECT 1
  FROM `_SESSION.t_pregnancy_cross_source_matches_v3_3` a
  WHERE a.epus_episode_id = c.epus_episode_id
)
AND NOT EXISTS (
  SELECT 1
  FROM `_SESSION.t_pregnancy_cross_source_matches_v3_3` a
  WHERE a.sigizi_episode_id = c.sigizi_episode_id
);

INSERT INTO `_SESSION.t_pregnancy_cross_source_matches_v3_3`
(
  epus_episode_id,
  sigizi_episode_id,
  cross_source_match_method,
  cross_source_match_priority,
  cross_source_match_confidence,
  anchor_difference_days,
  match_date_difference_days,
  assignment_round
)
SELECT
  epus_episode_id,
  sigizi_episode_id,
  cross_source_match_method,
  cross_source_match_priority,
  cross_source_match_confidence,
  anchor_difference_days,
  match_date_difference_days,
  4 AS assignment_round
FROM round4_ranked
WHERE epus_rank = 1
  AND sigizi_rank = 1;


-- Round 5
CREATE TEMP TABLE round5_ranked AS
SELECT
  c.*,
  ROW_NUMBER() OVER (
    PARTITION BY c.epus_episode_id
    ORDER BY
      c.cross_source_match_priority,
      c.match_date_difference_days,
      c.anchor_difference_days,
      c.sigizi_episode_id
  ) AS epus_rank,
  ROW_NUMBER() OVER (
    PARTITION BY c.sigizi_episode_id
    ORDER BY
      c.cross_source_match_priority,
      c.match_date_difference_days,
      c.anchor_difference_days,
      c.epus_episode_id
  ) AS sigizi_rank
FROM `_SESSION.t_pregnancy_cross_source_candidates_best_v3_3` c
WHERE NOT EXISTS (
  SELECT 1
  FROM `_SESSION.t_pregnancy_cross_source_matches_v3_3` a
  WHERE a.epus_episode_id = c.epus_episode_id
)
AND NOT EXISTS (
  SELECT 1
  FROM `_SESSION.t_pregnancy_cross_source_matches_v3_3` a
  WHERE a.sigizi_episode_id = c.sigizi_episode_id
);

INSERT INTO `_SESSION.t_pregnancy_cross_source_matches_v3_3`
(
  epus_episode_id,
  sigizi_episode_id,
  cross_source_match_method,
  cross_source_match_priority,
  cross_source_match_confidence,
  anchor_difference_days,
  match_date_difference_days,
  assignment_round
)
SELECT
  epus_episode_id,
  sigizi_episode_id,
  cross_source_match_method,
  cross_source_match_priority,
  cross_source_match_confidence,
  anchor_difference_days,
  match_date_difference_days,
  5 AS assignment_round
FROM round5_ranked
WHERE epus_rank = 1
  AND sigizi_rank = 1;


-- ============================================================================
-- D. BUILD FINAL PREGNANCY SPINE
--    First create MATCHED rows, then INSERT SIGIZI-only and ePUS-only rows.
--    This avoids one large three-branch UNION plan.
-- ============================================================================

CREATE OR REPLACE TABLE `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3`
CLUSTER BY nik_clean, puskesmas_norm, pregnancy_episode_id
AS
SELECT
  CONCAT(
    'PREG_',
    TO_HEX(SHA256(CONCAT('SIGIZI|', s.sigizi_episode_id)))
  ) AS pregnancy_episode_id,

  s.sigizi_episode_id,
  e.epus_episode_id,
  e.epus_episode_source_key,
  e.epus_episode_source_keys,

  m.cross_source_match_method,
  m.cross_source_match_priority,
  m.cross_source_match_confidence,
  m.anchor_difference_days,
  m.match_date_difference_days,
  m.assignment_round AS cross_source_assignment_round,

  'SIGIZI + EPUS' AS pregnancy_source_combination,

  TRUE AS has_pregnancy_sigizi,
  TRUE AS has_pregnancy_epus,

  COALESCE(s.nik_clean, e.nik_clean) AS nik_clean,

  COALESCE(e.nama_ibu, s.nama_ibu) AS nama_ibu,
  COALESCE(e.nama_norm, s.nama_norm) AS nama_norm,
  COALESCE(e.nama_core_norm, s.nama_core_norm) AS nama_core_norm,

  COALESCE(e.tanggal_lahir_ibu, s.tanggal_lahir_ibu) AS tanggal_lahir_ibu,

  COALESCE(e.no_hp_clean, s.no_hp_clean) AS no_hp_clean,

  CASE
    WHEN e.no_hp_clean IS NOT NULL THEN 'EPUS'
    WHEN s.no_hp_clean IS NOT NULL THEN 'SIGIZI'
  END AS phone_source,

  COALESCE(e.puskesmas, s.puskesmas) AS puskesmas,
  COALESCE(e.puskesmas_norm, s.puskesmas_norm) AS puskesmas_norm,

  COALESCE(e.desa, s.desa) AS desa,
  COALESCE(e.desa_norm, s.desa_norm) AS desa_norm,

  COALESCE(e.posyandu, s.posyandu) AS posyandu,
  COALESCE(e.alamat, s.alamat) AS alamat,

  s.hpht_sigizi,
  e.hpht_epus,

  s.hpl_sigizi,
  e.hpl_epus,

  s.delivery_sigizi,
  e.delivery_epus,

  s.hpl_from_sigizi_hpht,
  e.hpl_from_epus_hpht,

  COALESCE(e.hpht_epus, s.hpht_sigizi) AS hpht_date,

  CASE
    WHEN e.hpht_epus IS NOT NULL THEN 'EPUS'
    WHEN s.hpht_sigizi IS NOT NULL THEN 'SIGIZI'
  END AS hpht_source,

  COALESCE(e.hpl_epus, s.hpl_sigizi) AS hpl_recorded_date,

  CASE
    WHEN e.hpl_epus IS NOT NULL THEN 'EPUS'
    WHEN s.hpl_sigizi IS NOT NULL THEN 'SIGIZI'
  END AS hpl_recorded_source,

  COALESCE(e.hpl_from_epus_hpht, s.hpl_from_sigizi_hpht)
    AS hpl_from_hpht_date,

  NULLIF(
    LEAST(
      COALESCE(e.first_anc_date, DATE '9999-12-31'),
      COALESCE(s.first_anc_date, DATE '9999-12-31')
    ),
    DATE '9999-12-31'
  ) AS first_anc_date,

  NULLIF(
    GREATEST(
      COALESCE(e.last_anc_date, DATE '0001-01-01'),
      COALESCE(s.last_anc_date, DATE '0001-01-01')
    ),
    DATE '0001-01-01'
  ) AS last_anc_date,

  COALESCE(e.pregnancy_anchor_date, s.pregnancy_anchor_min_date)
    AS pregnancy_anchor_date,

  s.pregnancy_anchor_min_date AS sigizi_anchor_date,
  e.pregnancy_anchor_date AS epus_anchor_date,

  s.pregnancy_anchor_spread_days AS sigizi_anchor_spread_days,
  s.sigizi_episode_review_flag,

  s.sigizi_member_record_count,
  s.sigizi_source_tables,

  s.mother_identity_methods AS sigizi_mother_identity_methods,
  s.sigizi_identity_propagated_record_count,
  s.sigizi_ambiguous_identity_record_count,
  s.sigizi_max_signature_row_count,
  s.sigizi_distinct_pregnancy_signature_count,

  LENGTH(COALESCE(COALESCE(e.no_hp_clean, s.no_hp_clean), '')) >= 8
    AS has_phone_pregnancy_source,

  CASE
    WHEN s.hpl_sigizi IS NOT NULL
     AND e.hpl_epus IS NOT NULL
    THEN DATE_DIFF(e.hpl_epus, s.hpl_sigizi, DAY)
  END AS epus_minus_sigizi_hpl_days,

  CASE
    WHEN s.hpht_sigizi IS NOT NULL
     AND e.hpht_epus IS NOT NULL
    THEN DATE_DIFF(e.hpht_epus, s.hpht_sigizi, DAY)
  END AS epus_minus_sigizi_hpht_days,

  (
    s.nik_clean IS NOT NULL
    AND e.nik_clean IS NOT NULL
    AND s.nik_clean != e.nik_clean
  ) AS cross_source_nik_conflict_flag

FROM `_SESSION.t_pregnancy_cross_source_matches_v3_3` m
JOIN `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_canonical_v3_3` s
  USING (sigizi_episode_id)
JOIN `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` e
  USING (epus_episode_id);


-- --------------------------------------------------------------------------
-- INSERT SIGIZI ONLY
-- --------------------------------------------------------------------------

INSERT INTO `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3`
SELECT
  CONCAT(
    'PREG_',
    TO_HEX(SHA256(CONCAT('SIGIZI|', s.sigizi_episode_id)))
  ) AS pregnancy_episode_id,

  s.sigizi_episode_id,
  CAST(NULL AS STRING) AS epus_episode_id,
  CAST(NULL AS STRING) AS epus_episode_source_key,
  CAST(NULL AS ARRAY<STRING>) AS epus_episode_source_keys,

  CAST(NULL AS STRING) AS cross_source_match_method,
  CAST(NULL AS INT64) AS cross_source_match_priority,
  CAST(NULL AS STRING) AS cross_source_match_confidence,
  CAST(NULL AS INT64) AS anchor_difference_days,
  CAST(NULL AS INT64) AS match_date_difference_days,
  CAST(NULL AS INT64) AS cross_source_assignment_round,

  'SIGIZI ONLY' AS pregnancy_source_combination,

  TRUE AS has_pregnancy_sigizi,
  FALSE AS has_pregnancy_epus,

  s.nik_clean,
  s.nama_ibu,
  s.nama_norm,
  s.nama_core_norm,
  s.tanggal_lahir_ibu,
  s.no_hp_clean,

  CASE
    WHEN s.no_hp_clean IS NOT NULL THEN 'SIGIZI'
  END AS phone_source,

  s.puskesmas,
  s.puskesmas_norm,
  s.desa,
  s.desa_norm,
  s.posyandu,
  s.alamat,

  s.hpht_sigizi,
  CAST(NULL AS DATE) AS hpht_epus,

  s.hpl_sigizi,
  CAST(NULL AS DATE) AS hpl_epus,

  s.delivery_sigizi,
  CAST(NULL AS DATE) AS delivery_epus,

  s.hpl_from_sigizi_hpht,
  CAST(NULL AS DATE) AS hpl_from_epus_hpht,

  s.hpht_sigizi AS hpht_date,

  CASE
    WHEN s.hpht_sigizi IS NOT NULL THEN 'SIGIZI'
  END AS hpht_source,

  s.hpl_sigizi AS hpl_recorded_date,

  CASE
    WHEN s.hpl_sigizi IS NOT NULL THEN 'SIGIZI'
  END AS hpl_recorded_source,

  s.hpl_from_sigizi_hpht AS hpl_from_hpht_date,

  s.first_anc_date,
  s.last_anc_date,

  s.pregnancy_anchor_min_date AS pregnancy_anchor_date,
  s.pregnancy_anchor_min_date AS sigizi_anchor_date,
  CAST(NULL AS DATE) AS epus_anchor_date,

  s.pregnancy_anchor_spread_days AS sigizi_anchor_spread_days,
  s.sigizi_episode_review_flag,

  s.sigizi_member_record_count,
  s.sigizi_source_tables,

  s.mother_identity_methods AS sigizi_mother_identity_methods,
  s.sigizi_identity_propagated_record_count,
  s.sigizi_ambiguous_identity_record_count,
  s.sigizi_max_signature_row_count,
  s.sigizi_distinct_pregnancy_signature_count,

  LENGTH(COALESCE(s.no_hp_clean, '')) >= 8
    AS has_phone_pregnancy_source,

  CAST(NULL AS INT64) AS epus_minus_sigizi_hpl_days,
  CAST(NULL AS INT64) AS epus_minus_sigizi_hpht_days,

  FALSE AS cross_source_nik_conflict_flag

FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_canonical_v3_3` s
WHERE NOT EXISTS (
  SELECT 1
  FROM `_SESSION.t_pregnancy_cross_source_matches_v3_3` m
  WHERE m.sigizi_episode_id = s.sigizi_episode_id
);


-- --------------------------------------------------------------------------
-- INSERT ePUS ONLY
-- --------------------------------------------------------------------------

INSERT INTO `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3`
SELECT
  CONCAT(
    'PREG_',
    TO_HEX(SHA256(CONCAT('EPUS|', e.epus_episode_id)))
  ) AS pregnancy_episode_id,

  CAST(NULL AS STRING) AS sigizi_episode_id,
  e.epus_episode_id,
  e.epus_episode_source_key,
  e.epus_episode_source_keys,

  CAST(NULL AS STRING) AS cross_source_match_method,
  CAST(NULL AS INT64) AS cross_source_match_priority,
  CAST(NULL AS STRING) AS cross_source_match_confidence,
  CAST(NULL AS INT64) AS anchor_difference_days,
  CAST(NULL AS INT64) AS match_date_difference_days,
  CAST(NULL AS INT64) AS cross_source_assignment_round,

  'EPUS ONLY' AS pregnancy_source_combination,

  FALSE AS has_pregnancy_sigizi,
  TRUE AS has_pregnancy_epus,

  e.nik_clean,
  e.nama_ibu,
  e.nama_norm,
  e.nama_core_norm,
  e.tanggal_lahir_ibu,
  e.no_hp_clean,

  CASE
    WHEN e.no_hp_clean IS NOT NULL THEN 'EPUS'
  END AS phone_source,

  e.puskesmas,
  e.puskesmas_norm,
  e.desa,
  e.desa_norm,
  e.posyandu,
  e.alamat,

  CAST(NULL AS DATE) AS hpht_sigizi,
  e.hpht_epus,

  CAST(NULL AS DATE) AS hpl_sigizi,
  e.hpl_epus,

  CAST(NULL AS DATE) AS delivery_sigizi,
  e.delivery_epus,

  CAST(NULL AS DATE) AS hpl_from_sigizi_hpht,
  e.hpl_from_epus_hpht,

  e.hpht_epus AS hpht_date,

  CASE
    WHEN e.hpht_epus IS NOT NULL THEN 'EPUS'
  END AS hpht_source,

  e.hpl_epus AS hpl_recorded_date,

  CASE
    WHEN e.hpl_epus IS NOT NULL THEN 'EPUS'
  END AS hpl_recorded_source,

  e.hpl_from_epus_hpht AS hpl_from_hpht_date,

  e.first_anc_date,
  e.last_anc_date,

  e.pregnancy_anchor_date AS pregnancy_anchor_date,
  CAST(NULL AS DATE) AS sigizi_anchor_date,
  e.pregnancy_anchor_date AS epus_anchor_date,

  CAST(NULL AS INT64) AS sigizi_anchor_spread_days,
  FALSE AS sigizi_episode_review_flag,

  CAST(NULL AS INT64) AS sigizi_member_record_count,
  CAST(NULL AS ARRAY<STRING>) AS sigizi_source_tables,

  CAST(NULL AS ARRAY<STRING>) AS sigizi_mother_identity_methods,
  CAST(NULL AS INT64) AS sigizi_identity_propagated_record_count,
  CAST(NULL AS INT64) AS sigizi_ambiguous_identity_record_count,
  CAST(NULL AS INT64) AS sigizi_max_signature_row_count,
  CAST(NULL AS INT64) AS sigizi_distinct_pregnancy_signature_count,

  LENGTH(COALESCE(e.no_hp_clean, '')) >= 8
    AS has_phone_pregnancy_source,

  CAST(NULL AS INT64) AS epus_minus_sigizi_hpl_days,
  CAST(NULL AS INT64) AS epus_minus_sigizi_hpht_days,

  FALSE AS cross_source_nik_conflict_flag

FROM `spheres-lombok-barat.kohort_bumil_v3.t_epus_pregnancy_episode_canonical_v3_3` e
WHERE NOT EXISTS (
  SELECT 1
  FROM `_SESSION.t_pregnancy_cross_source_matches_v3_3` m
  WHERE m.epus_episode_id = e.epus_episode_id
);




-- ============================================================================
-- STAGE 3E - FINAL ALL-EPISODE CANONICALIZATION
--
-- IMPORTANT CHANGE FROM v3
--   The previous final guard only compared a leftover single-source row against
--   a SIGIZI+EPUS row. That cannot resolve patterns such as:
--       SIGIZI+EPUS  <->  SIGIZI+EPUS
--   or some EPUS ONLY <-> SIGIZI ONLY pairs with data-quality conflicts.
--
--   v4 compares ALL plausibly related spine episodes using blocking keys, then
--   applies high-specificity deterministic rescue rules. Candidate direction is
--   always from the lower-quality row to the higher-quality row, preventing
--   cycles. Ambiguous best targets are not auto-merged.
-- ============================================================================

CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_episode_spine_precanonical_v3_3`
CLUSTER BY nik_clean, puskesmas_norm, pregnancy_episode_id
AS
SELECT *
FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3`;


-- --------------------------------------------------------------------------
-- A. Enrich each precanonical episode with normalized comparison fields and a
--    deterministic quality score. Combined-source episodes are preferred as
--    canonical anchors, followed by trusted identity and clinical completeness.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_final_guard_base_raw_v3_3`
CLUSTER BY puskesmas_norm, pregnancy_episode_id
AS
SELECT
  p.*,

  COALESCE(delivery_epus, delivery_sigizi) AS source_delivery_date,
  COALESCE(hpl_recorded_date, hpl_from_hpht_date) AS effective_hpl_date,

  compact_name(nama_core_norm) AS nama_compact_norm,
  norm_key(posyandu) AS posyandu_norm_key,

  CASE
    WHEN nik_is_trusted(nik_clean) THEN 'TRUSTED'
    WHEN nik_clean IS NULL THEN 'MISSING'
    ELSE 'UNTRUSTED'
  END AS nik_trust_status,

  CASE pregnancy_source_combination
    WHEN 'SIGIZI + EPUS' THEN 3
    WHEN 'EPUS ONLY' THEN 2
    WHEN 'SIGIZI ONLY' THEN 1
    ELSE 0
  END AS final_source_strength,

  (
      CASE pregnancy_source_combination
        WHEN 'SIGIZI + EPUS' THEN 200
        WHEN 'EPUS ONLY' THEN 70
        WHEN 'SIGIZI ONLY' THEN 60
        ELSE 0
      END
    + IF(nik_is_trusted(nik_clean), 100, IF(nik_clean IS NOT NULL, 5, 0))
    + IF(tanggal_lahir_ibu IS NOT NULL, 30, 0)
    + IF(no_hp_clean IS NOT NULL AND LENGTH(no_hp_clean) >= 8, 25, 0)
    + IF(hpht_date IS NOT NULL, 25, 0)
    + IF(COALESCE(hpl_recorded_date, hpl_from_hpht_date) IS NOT NULL, 20, 0)
    + IF(COALESCE(delivery_epus, delivery_sigizi) IS NOT NULL, 25, 0)
    + IF(puskesmas_norm IS NOT NULL, 8, 0)
    + IF(desa_norm IS NOT NULL, 5, 0)
    + IF(norm_key(posyandu) IS NOT NULL, 3, 0)
  ) AS final_episode_quality_score,

  CASE
    WHEN compact_name(nama_core_norm) IS NOT NULL
     AND puskesmas_norm IS NOT NULL
     AND hpht_date IS NOT NULL
     AND COALESCE(hpl_recorded_date, hpl_from_hpht_date) IS NOT NULL
    THEN CONCAT(
      compact_name(nama_core_norm), '|',
      puskesmas_norm, '|',
      CAST(hpht_date AS STRING), '|',
      CAST(COALESCE(hpl_recorded_date, hpl_from_hpht_date) AS STRING)
    )
  END AS strict_pregnancy_fingerprint_key

FROM `_SESSION.t_pregnancy_episode_spine_precanonical_v3_3` p;


CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_final_fingerprint_stats_v3_3`
CLUSTER BY strict_pregnancy_fingerprint_key
AS
SELECT
  strict_pregnancy_fingerprint_key,
  COUNT(*) AS fingerprint_episode_count,
  COUNTIF(has_pregnancy_sigizi) AS fingerprint_sigizi_episode_count,
  COUNTIF(has_pregnancy_epus) AS fingerprint_epus_episode_count
FROM `_SESSION.t_pregnancy_final_guard_base_raw_v3_3`
WHERE strict_pregnancy_fingerprint_key IS NOT NULL
GROUP BY strict_pregnancy_fingerprint_key;


CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_final_guard_base_v3_3`
CLUSTER BY nik_clean, puskesmas_norm, pregnancy_episode_id
AS
SELECT
  b.*,
  COALESCE(f.fingerprint_episode_count, 0) AS fingerprint_episode_count
FROM `_SESSION.t_pregnancy_final_guard_base_raw_v3_3` b
LEFT JOIN `_SESSION.t_pregnancy_final_fingerprint_stats_v3_3` f
  USING (strict_pregnancy_fingerprint_key);


-- --------------------------------------------------------------------------
-- B. Materialize pair-level evidence.
--
-- The JOIN is deliberately BLOCKED rather than a full cartesian self join.
-- A pair is considered only when at least one strong blocking signal exists:
--   exact NIK; compact name; exact phone; DOB + nearby HPHT/HPL; or exact
--   pregnancy fingerprint components.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_final_pair_features_v3_3`
CLUSTER BY member_pregnancy_episode_id, canonical_pregnancy_episode_id
AS
SELECT
  a.pregnancy_episode_id AS episode_a_id,
  b.pregnancy_episode_id AS episode_b_id,

  -- Always orient lower-quality -> higher-quality. If quality ties, keep the
  -- lexicographically smaller ID as canonical. This prevents cycles.
  CASE
    WHEN a.final_episode_quality_score > b.final_episode_quality_score THEN b.pregnancy_episode_id
    WHEN a.final_episode_quality_score < b.final_episode_quality_score THEN a.pregnancy_episode_id
    ELSE b.pregnancy_episode_id
  END AS member_pregnancy_episode_id,

  CASE
    WHEN a.final_episode_quality_score > b.final_episode_quality_score THEN a.pregnancy_episode_id
    WHEN a.final_episode_quality_score < b.final_episode_quality_score THEN b.pregnancy_episode_id
    ELSE a.pregnancy_episode_id
  END AS canonical_pregnancy_episode_id,

  GREATEST(a.final_episode_quality_score, b.final_episode_quality_score)
    AS canonical_quality_score,

  -- Name evidence
  a.nama_core_norm IS NOT NULL
    AND b.nama_core_norm IS NOT NULL
    AND a.nama_core_norm = b.nama_core_norm
    AS exact_name_match,

  a.nama_compact_norm IS NOT NULL
    AND b.nama_compact_norm IS NOT NULL
    AND a.nama_compact_norm = b.nama_compact_norm
    AS compact_name_match,

  CASE
    WHEN a.nama_compact_norm IS NOT NULL AND b.nama_compact_norm IS NOT NULL
      THEN EDIT_DISTANCE(a.nama_compact_norm, b.nama_compact_norm)
  END AS name_edit_distance,

  (
    a.nama_compact_norm IS NOT NULL
    AND b.nama_compact_norm IS NOT NULL
    AND LEAST(LENGTH(a.nama_compact_norm), LENGTH(b.nama_compact_norm)) >= 5
    AND EDIT_DISTANCE(a.nama_compact_norm, b.nama_compact_norm)
        <= CASE
             WHEN GREATEST(LENGTH(a.nama_compact_norm), LENGTH(b.nama_compact_norm)) <= 8 THEN 1
             ELSE 2
           END
  ) AS fuzzy_name_match,

  -- DOB state: missing on one side is explicitly different from conflict.
  CASE
    WHEN a.tanggal_lahir_ibu IS NULL AND b.tanggal_lahir_ibu IS NULL THEN 'BOTH_MISSING'
    WHEN a.tanggal_lahir_ibu IS NULL OR b.tanggal_lahir_ibu IS NULL THEN 'MISSING_ONE_SIDE'
    WHEN a.tanggal_lahir_ibu = b.tanggal_lahir_ibu THEN 'MATCH'
    ELSE 'CONFLICT'
  END AS dob_match_state,

  -- NIK state: preserve disagreement, but only trusted-vs-trusted disagreement
  -- is considered a hard conflict for weak rules.
  CASE
    WHEN a.nik_clean IS NULL AND b.nik_clean IS NULL THEN 'BOTH_MISSING'
    WHEN a.nik_clean IS NULL OR b.nik_clean IS NULL THEN 'MISSING_ONE_SIDE'
    WHEN a.nik_clean = b.nik_clean THEN 'MATCH'
    WHEN nik_hard_conflict(a.nik_clean, b.nik_clean) THEN 'TRUSTED_CONFLICT'
    ELSE 'UNTRUSTED_CONFLICT'
  END AS nik_match_state,

  nik_hard_conflict(a.nik_clean, b.nik_clean) AS trusted_nik_conflict_flag,
  (a.nik_clean IS NOT NULL AND b.nik_clean IS NOT NULL AND a.nik_clean != b.nik_clean)
    AS any_nik_conflict_flag,

  -- Pregnancy date evidence
  CASE
    WHEN a.hpht_date IS NOT NULL AND b.hpht_date IS NOT NULL
      THEN ABS(DATE_DIFF(a.hpht_date, b.hpht_date, DAY))
  END AS hpht_difference_days,

  CASE
    WHEN a.effective_hpl_date IS NOT NULL AND b.effective_hpl_date IS NOT NULL
      THEN ABS(DATE_DIFF(a.effective_hpl_date, b.effective_hpl_date, DAY))
  END AS hpl_difference_days,

  CASE
    WHEN a.source_delivery_date IS NOT NULL AND b.source_delivery_date IS NOT NULL
      THEN ABS(DATE_DIFF(a.source_delivery_date, b.source_delivery_date, DAY))
  END AS delivery_difference_days,

  CASE
    WHEN a.pregnancy_anchor_date IS NOT NULL AND b.pregnancy_anchor_date IS NOT NULL
      THEN ABS(DATE_DIFF(a.pregnancy_anchor_date, b.pregnancy_anchor_date, DAY))
  END AS anchor_difference_days,

  -- Corroborating evidence
  (a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm)
    AS puskesmas_match,
  (a.desa_norm IS NOT NULL AND a.desa_norm = b.desa_norm)
    AS desa_match,
  (a.posyandu_norm_key IS NOT NULL AND a.posyandu_norm_key = b.posyandu_norm_key)
    AS posyandu_match,
  (
    a.no_hp_clean IS NOT NULL
    AND b.no_hp_clean IS NOT NULL
    AND LENGTH(a.no_hp_clean) >= 8
    AND LENGTH(b.no_hp_clean) >= 8
    AND a.no_hp_clean = b.no_hp_clean
  ) AS phone_match,

  (
      CAST(a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm AS INT64)
    + CAST(a.desa_norm IS NOT NULL AND a.desa_norm = b.desa_norm AS INT64)
    + CAST(a.posyandu_norm_key IS NOT NULL AND a.posyandu_norm_key = b.posyandu_norm_key AS INT64)
  ) AS location_corroborator_count,

  (
      CAST(a.puskesmas_norm IS NOT NULL AND a.puskesmas_norm = b.puskesmas_norm AS INT64)
    + CAST(a.desa_norm IS NOT NULL AND a.desa_norm = b.desa_norm AS INT64)
    + CAST(a.posyandu_norm_key IS NOT NULL AND a.posyandu_norm_key = b.posyandu_norm_key AS INT64)
    + CAST(
        a.no_hp_clean IS NOT NULL AND b.no_hp_clean IS NOT NULL
        AND LENGTH(a.no_hp_clean) >= 8 AND LENGTH(b.no_hp_clean) >= 8
        AND a.no_hp_clean = b.no_hp_clean
      AS INT64)
    + CAST(
        a.source_delivery_date IS NOT NULL AND b.source_delivery_date IS NOT NULL
        AND ABS(DATE_DIFF(a.source_delivery_date, b.source_delivery_date, DAY)) <= delivery_tolerance_days
      AS INT64)
  ) AS corroborator_count,

  -- Strict fingerprint is used only for the high-conflict UNIQUE rescue.
  (
    a.strict_pregnancy_fingerprint_key IS NOT NULL
    AND a.strict_pregnancy_fingerprint_key = b.strict_pregnancy_fingerprint_key
    AND a.fingerprint_episode_count = 2
    AND b.fingerprint_episode_count = 2
  ) AS unique_strict_fingerprint_pair

FROM `_SESSION.t_pregnancy_final_guard_base_v3_3` a
JOIN `_SESSION.t_pregnancy_final_guard_base_v3_3` b
  ON a.pregnancy_episode_id < b.pregnancy_episode_id
 AND (
      -- Exact NIK block
      (a.nik_clean IS NOT NULL AND a.nik_clean = b.nik_clean)

      -- Exact compact-name block
   OR (a.nama_compact_norm IS NOT NULL AND a.nama_compact_norm = b.nama_compact_norm)

      -- Exact phone block
   OR (
        a.no_hp_clean IS NOT NULL AND b.no_hp_clean IS NOT NULL
        AND LENGTH(a.no_hp_clean) >= 8 AND LENGTH(b.no_hp_clean) >= 8
        AND a.no_hp_clean = b.no_hp_clean
      )

      -- DOB + nearby HPHT block catches controlled fuzzy-name variants such as
      -- BUDIAH/BUDIAJ and NIDAATURRAHMANI/NIDATURRAHMANI.
   OR (
        a.tanggal_lahir_ibu IS NOT NULL
        AND a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
        AND a.hpht_date IS NOT NULL AND b.hpht_date IS NOT NULL
        AND ABS(DATE_DIFF(a.hpht_date, b.hpht_date, DAY)) <= strong_hpht_tolerance_days
      )

      -- DOB + nearby HPL block when HPHT is unavailable.
   OR (
        a.tanggal_lahir_ibu IS NOT NULL
        AND a.tanggal_lahir_ibu = b.tanggal_lahir_ibu
        AND a.effective_hpl_date IS NOT NULL AND b.effective_hpl_date IS NOT NULL
        AND ABS(DATE_DIFF(a.effective_hpl_date, b.effective_hpl_date, DAY)) <= strong_hpl_tolerance_days
      )

      -- Exact pregnancy fingerprint block can rescue DOB/NIK conflict, but only
      -- after later deterministic rules validate the pair.
   OR (
        a.hpht_date IS NOT NULL AND a.hpht_date = b.hpht_date
        AND a.effective_hpl_date IS NOT NULL
        AND a.effective_hpl_date = b.effective_hpl_date
        AND a.puskesmas_norm IS NOT NULL
        AND a.puskesmas_norm = b.puskesmas_norm
      )
 );


-- --------------------------------------------------------------------------
-- C. Candidate rules. Each rule is a separate statement to keep BigQuery
--    planning manageable and to make QA by rule straightforward.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_final_guard_candidates_v3_3`
CLUSTER BY member_pregnancy_episode_id, canonical_pregnancy_episode_id
AS
-- 1. Exact NIK + compatible pregnancy anchor
SELECT
  member_pregnancy_episode_id,
  canonical_pregnancy_episode_id,
  'FINAL_NIK+ANCHOR_30D' AS final_merge_method,
  1 AS final_merge_priority,
  'VERY_HIGH' AS final_merge_confidence,
  anchor_difference_days,
  anchor_difference_days AS match_date_difference_days,
  name_edit_distance,
  any_nik_conflict_flag,
  dob_match_state = 'CONFLICT' AS dob_conflict_flag,
  any_nik_conflict_flag OR dob_match_state = 'CONFLICT' AS identity_conflict_flag,
  corroborator_count,
  unique_strict_fingerprint_pair,
  canonical_quality_score
FROM `_SESSION.t_pregnancy_final_pair_features_v3_3`
WHERE nik_match_state = 'MATCH'
  AND anchor_difference_days IS NOT NULL
  AND anchor_difference_days <= final_guard_anchor_tolerance_days;


-- 2. Strong exact/compact maternal identity + DOB + HPHT <=14d.
--    NIK disagreement is allowed and retained as QA.
INSERT INTO `_SESSION.t_pregnancy_final_guard_candidates_v3_3`
SELECT
  member_pregnancy_episode_id,
  canonical_pregnancy_episode_id,
  'FINAL_STRONG_NAME+DOB+HPHT_14D+CORROBORATOR',
  2,
  'VERY_HIGH',
  anchor_difference_days,
  hpht_difference_days,
  name_edit_distance,
  any_nik_conflict_flag,
  FALSE,
  any_nik_conflict_flag,
  corroborator_count,
  unique_strict_fingerprint_pair,
  canonical_quality_score
FROM `_SESSION.t_pregnancy_final_pair_features_v3_3`
WHERE (exact_name_match OR compact_name_match)
  AND dob_match_state = 'MATCH'
  AND hpht_difference_days IS NOT NULL
  AND hpht_difference_days <= strong_hpht_tolerance_days
  AND corroborator_count >= 1;


-- 3. Controlled FUZZY-NAME rescue.
--    Fuzzy name alone is NEVER enough: exact DOB + close HPHT + >=2 independent
--    corroborators are required. Covers BUDIAH/BUDIAJ and similar typos.
INSERT INTO `_SESSION.t_pregnancy_final_guard_candidates_v3_3`
SELECT
  member_pregnancy_episode_id,
  canonical_pregnancy_episode_id,
  'FINAL_FUZZY_NAME+DOB+HPHT_14D+2_CORROBORATORS',
  3,
  'VERY_HIGH',
  anchor_difference_days,
  hpht_difference_days,
  name_edit_distance,
  any_nik_conflict_flag,
  FALSE,
  any_nik_conflict_flag,
  corroborator_count,
  unique_strict_fingerprint_pair,
  canonical_quality_score
FROM `_SESSION.t_pregnancy_final_pair_features_v3_3`
WHERE fuzzy_name_match
  AND NOT compact_name_match
  AND dob_match_state = 'MATCH'
  AND hpht_difference_days IS NOT NULL
  AND hpht_difference_days <= strong_hpht_tolerance_days
  AND corroborator_count >= 2;


-- 4. PHONE identity rescue.
--    Exact DOB + exact phone + coherent HPHT/HPL can override name/NIK errors.
--    Covers INDRAWATI / INDRI WATI type cases.
INSERT INTO `_SESSION.t_pregnancy_final_guard_candidates_v3_3`
SELECT
  member_pregnancy_episode_id,
  canonical_pregnancy_episode_id,
  'FINAL_PHONE+DOB+HPHT_HPL',
  4,
  'VERY_HIGH',
  anchor_difference_days,
  LEAST(COALESCE(hpht_difference_days, 9999), COALESCE(hpl_difference_days, 9999)),
  name_edit_distance,
  any_nik_conflict_flag,
  FALSE,
  any_nik_conflict_flag,
  corroborator_count,
  unique_strict_fingerprint_pair,
  canonical_quality_score
FROM `_SESSION.t_pregnancy_final_pair_features_v3_3`
WHERE phone_match
  AND dob_match_state = 'MATCH'
  AND hpht_difference_days IS NOT NULL
  AND hpht_difference_days <= strong_hpht_tolerance_days
  AND hpl_difference_days IS NOT NULL
  AND hpl_difference_days <= strong_hpl_tolerance_days;


-- 5. Missing-DOB rescue. Missing is not a conflict.
--    Exact/compact name + exact HPHT/HPL + >=2 matching location components.
--    Covers HALIMATUSAKDIAH where one source has DOB and the other does not.
INSERT INTO `_SESSION.t_pregnancy_final_guard_candidates_v3_3`
SELECT
  member_pregnancy_episode_id,
  canonical_pregnancy_episode_id,
  'FINAL_NAME+DOB_MISSING+EXACT_PREGNANCY+2_LOCATION',
  5,
  'VERY_HIGH',
  anchor_difference_days,
  0,
  name_edit_distance,
  any_nik_conflict_flag,
  FALSE,
  any_nik_conflict_flag,
  corroborator_count,
  unique_strict_fingerprint_pair,
  canonical_quality_score
FROM `_SESSION.t_pregnancy_final_pair_features_v3_3`
WHERE (exact_name_match OR compact_name_match)
  AND dob_match_state = 'MISSING_ONE_SIDE'
  AND hpht_difference_days = 0
  AND hpl_difference_days = 0
  AND location_corroborator_count >= 2;


-- 6. STRONG PREGNANCY FINGERPRINT OVERRIDE.
--    NIK AND DOB conflicts may both be overridden when the same/compact name,
--    exact HPHT, exact HPL, and >=2 corroborators identify the pregnancy.
--    Covers MAHRANI-like cases.
INSERT INTO `_SESSION.t_pregnancy_final_guard_candidates_v3_3`
SELECT
  member_pregnancy_episode_id,
  canonical_pregnancy_episode_id,
  'FINAL_STRONG_PREGNANCY_FINGERPRINT_OVERRIDE',
  6,
  'VERY_HIGH_CONFLICT',
  anchor_difference_days,
  0,
  name_edit_distance,
  any_nik_conflict_flag,
  dob_match_state = 'CONFLICT',
  any_nik_conflict_flag OR dob_match_state = 'CONFLICT',
  corroborator_count,
  unique_strict_fingerprint_pair,
  canonical_quality_score
FROM `_SESSION.t_pregnancy_final_pair_features_v3_3`
WHERE (exact_name_match OR compact_name_match)
  AND hpht_difference_days = 0
  AND hpl_difference_days = 0
  AND corroborator_count >= 2;


-- 7. HIGH-CONFLICT UNIQUE fingerprint rescue.
--    Used only when the strict compact-name + puskesmas + HPHT + HPL fingerprint
--    contains exactly TWO episodes. This allows a MISRAH-like pair with NIK/DOB
--    disagreement to merge while avoiding automatic merging of ambiguous common
--    names that have >2 candidate episodes.
INSERT INTO `_SESSION.t_pregnancy_final_guard_candidates_v3_3`
SELECT
  member_pregnancy_episode_id,
  canonical_pregnancy_episode_id,
  'FINAL_HIGH_CONFLICT_UNIQUE_FINGERPRINT',
  7,
  'HIGH_CONFLICT',
  anchor_difference_days,
  0,
  name_edit_distance,
  any_nik_conflict_flag,
  dob_match_state = 'CONFLICT',
  any_nik_conflict_flag OR dob_match_state = 'CONFLICT',
  corroborator_count,
  TRUE,
  canonical_quality_score
FROM `_SESSION.t_pregnancy_final_pair_features_v3_3`
WHERE (exact_name_match OR compact_name_match)
  AND hpht_difference_days = 0
  AND hpl_difference_days = 0
  AND puskesmas_match
  AND unique_strict_fingerprint_pair;


-- 8. HPL-based strong identity rescue when HPHT is absent/unusable.
INSERT INTO `_SESSION.t_pregnancy_final_guard_candidates_v3_3`
SELECT
  member_pregnancy_episode_id,
  canonical_pregnancy_episode_id,
  'FINAL_STRONG_NAME+DOB+HPL_14D+CORROBORATOR',
  8,
  'HIGH',
  anchor_difference_days,
  hpl_difference_days,
  name_edit_distance,
  any_nik_conflict_flag,
  FALSE,
  any_nik_conflict_flag,
  corroborator_count,
  unique_strict_fingerprint_pair,
  canonical_quality_score
FROM `_SESSION.t_pregnancy_final_pair_features_v3_3`
WHERE (exact_name_match OR compact_name_match)
  AND dob_match_state = 'MATCH'
  AND hpl_difference_days IS NOT NULL
  AND hpl_difference_days <= strong_hpl_tolerance_days
  AND corroborator_count >= 1;


-- 9. Delivery-date strong identity rescue.
INSERT INTO `_SESSION.t_pregnancy_final_guard_candidates_v3_3`
SELECT
  member_pregnancy_episode_id,
  canonical_pregnancy_episode_id,
  'FINAL_STRONG_NAME+DOB+DELIVERY_3D+CORROBORATOR',
  9,
  'HIGH',
  anchor_difference_days,
  delivery_difference_days,
  name_edit_distance,
  any_nik_conflict_flag,
  FALSE,
  any_nik_conflict_flag,
  corroborator_count,
  unique_strict_fingerprint_pair,
  canonical_quality_score
FROM `_SESSION.t_pregnancy_final_pair_features_v3_3`
WHERE (exact_name_match OR compact_name_match)
  AND dob_match_state = 'MATCH'
  AND delivery_difference_days IS NOT NULL
  AND delivery_difference_days <= delivery_tolerance_days
  AND corroborator_count >= 1;


-- 10. Conservative exact-name fallback. Trusted NIK conflicts remain blocked.
INSERT INTO `_SESSION.t_pregnancy_final_guard_candidates_v3_3`
SELECT
  member_pregnancy_episode_id,
  canonical_pregnancy_episode_id,
  'FINAL_NAMA_CORE+DOB+HPHT_7D',
  10,
  'HIGH',
  anchor_difference_days,
  hpht_difference_days,
  name_edit_distance,
  any_nik_conflict_flag,
  FALSE,
  FALSE,
  corroborator_count,
  unique_strict_fingerprint_pair,
  canonical_quality_score
FROM `_SESSION.t_pregnancy_final_pair_features_v3_3`
WHERE exact_name_match
  AND dob_match_state = 'MATCH'
  AND hpht_difference_days IS NOT NULL
  AND hpht_difference_days <= hpht_tolerance_days
  AND NOT trusted_nik_conflict_flag;


-- --------------------------------------------------------------------------
-- D. Keep strongest rule per pair, then choose a unique best target per member.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_final_guard_candidates_best_v3_3`
CLUSTER BY member_pregnancy_episode_id, canonical_pregnancy_episode_id
AS
SELECT * EXCEPT(pair_rn)
FROM (
  SELECT
    c.*,
    ROW_NUMBER() OVER (
      PARTITION BY member_pregnancy_episode_id, canonical_pregnancy_episode_id
      ORDER BY
        final_merge_priority,
        match_date_difference_days,
        anchor_difference_days,
        final_merge_method
    ) AS pair_rn
  FROM `_SESSION.t_pregnancy_final_guard_candidates_v3_3` c
)
WHERE pair_rn = 1;


CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_final_guard_ranked_v3_3`
CLUSTER BY member_pregnancy_episode_id, canonical_pregnancy_episode_id
AS
SELECT
  c.*,
  DENSE_RANK() OVER (
    PARTITION BY member_pregnancy_episode_id
    ORDER BY
      final_merge_priority,
      COALESCE(match_date_difference_days, 999999),
      COALESCE(anchor_difference_days, 999999),
      canonical_quality_score DESC
  ) AS candidate_rank
FROM `_SESSION.t_pregnancy_final_guard_candidates_best_v3_3` c;


-- Auto-merge only when the best evidence tuple points to ONE target.
CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_final_guard_chosen_v3_3`
CLUSTER BY member_pregnancy_episode_id, canonical_pregnancy_episode_id
AS
SELECT
  member_pregnancy_episode_id,
  ANY_VALUE(canonical_pregnancy_episode_id) AS canonical_pregnancy_episode_id,
  ANY_VALUE(final_merge_method) AS final_merge_method,
  ANY_VALUE(final_merge_priority) AS final_merge_priority,
  ANY_VALUE(final_merge_confidence) AS final_merge_confidence,
  ANY_VALUE(anchor_difference_days) AS anchor_difference_days,
  ANY_VALUE(match_date_difference_days) AS match_date_difference_days,
  ANY_VALUE(any_nik_conflict_flag) AS any_nik_conflict_flag,
  ANY_VALUE(dob_conflict_flag) AS dob_conflict_flag,
  ANY_VALUE(identity_conflict_flag) AS identity_conflict_flag,
  ANY_VALUE(name_edit_distance) AS name_edit_distance,
  ANY_VALUE(corroborator_count) AS corroborator_count,
  ANY_VALUE(unique_strict_fingerprint_pair) AS unique_strict_fingerprint_pair
FROM `_SESSION.t_pregnancy_final_guard_ranked_v3_3`
WHERE candidate_rank = 1
GROUP BY member_pregnancy_episode_id
HAVING COUNT(*) = 1;


-- --------------------------------------------------------------------------
-- E. Build and flatten the directed canonical map. Five lightweight passes are
--    used instead of a recursive graph query to keep query planning predictable.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_final_canonical_map_step0_v3_3`
CLUSTER BY member_pregnancy_episode_id, canonical_pregnancy_episode_id
AS
SELECT
  p.pregnancy_episode_id AS member_pregnancy_episode_id,
  COALESCE(c.canonical_pregnancy_episode_id, p.pregnancy_episode_id)
    AS canonical_pregnancy_episode_id,
  c.final_merge_method,
  c.final_merge_priority,
  c.final_merge_confidence,
  c.anchor_difference_days,
  c.match_date_difference_days,
  c.any_nik_conflict_flag,
  c.dob_conflict_flag,
  c.identity_conflict_flag,
  c.name_edit_distance,
  c.corroborator_count,
  c.unique_strict_fingerprint_pair
FROM `_SESSION.t_pregnancy_episode_spine_precanonical_v3_3` p
LEFT JOIN `_SESSION.t_pregnancy_final_guard_chosen_v3_3` c
  ON c.member_pregnancy_episode_id = p.pregnancy_episode_id;


CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_final_canonical_map_step1_v3_3` AS
SELECT
  m.* EXCEPT(canonical_pregnancy_episode_id),
  COALESCE(n.canonical_pregnancy_episode_id, m.canonical_pregnancy_episode_id)
    AS canonical_pregnancy_episode_id
FROM `_SESSION.t_pregnancy_final_canonical_map_step0_v3_3` m
LEFT JOIN `_SESSION.t_pregnancy_final_guard_chosen_v3_3` n
  ON n.member_pregnancy_episode_id = m.canonical_pregnancy_episode_id;

CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_final_canonical_map_step2_v3_3` AS
SELECT
  m.* EXCEPT(canonical_pregnancy_episode_id),
  COALESCE(n.canonical_pregnancy_episode_id, m.canonical_pregnancy_episode_id)
    AS canonical_pregnancy_episode_id
FROM `_SESSION.t_pregnancy_final_canonical_map_step1_v3_3` m
LEFT JOIN `_SESSION.t_pregnancy_final_guard_chosen_v3_3` n
  ON n.member_pregnancy_episode_id = m.canonical_pregnancy_episode_id;

CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_final_canonical_map_step3_v3_3` AS
SELECT
  m.* EXCEPT(canonical_pregnancy_episode_id),
  COALESCE(n.canonical_pregnancy_episode_id, m.canonical_pregnancy_episode_id)
    AS canonical_pregnancy_episode_id
FROM `_SESSION.t_pregnancy_final_canonical_map_step2_v3_3` m
LEFT JOIN `_SESSION.t_pregnancy_final_guard_chosen_v3_3` n
  ON n.member_pregnancy_episode_id = m.canonical_pregnancy_episode_id;

CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_final_canonical_map_step4_v3_3` AS
SELECT
  m.* EXCEPT(canonical_pregnancy_episode_id),
  COALESCE(n.canonical_pregnancy_episode_id, m.canonical_pregnancy_episode_id)
    AS canonical_pregnancy_episode_id
FROM `_SESSION.t_pregnancy_final_canonical_map_step3_v3_3` m
LEFT JOIN `_SESSION.t_pregnancy_final_guard_chosen_v3_3` n
  ON n.member_pregnancy_episode_id = m.canonical_pregnancy_episode_id;

CREATE OR REPLACE TABLE `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_final_canonical_map_v3_3`
CLUSTER BY member_pregnancy_episode_id, canonical_pregnancy_episode_id
AS
SELECT
  m.* EXCEPT(canonical_pregnancy_episode_id),
  COALESCE(n.canonical_pregnancy_episode_id, m.canonical_pregnancy_episode_id)
    AS canonical_pregnancy_episode_id
FROM `_SESSION.t_pregnancy_final_canonical_map_step4_v3_3` m
LEFT JOIN `_SESSION.t_pregnancy_final_guard_chosen_v3_3` n
  ON n.member_pregnancy_episode_id = m.canonical_pregnancy_episode_id;


-- --------------------------------------------------------------------------
-- F. Group-level audit, source membership, and canonical scalar picks.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_final_canonical_groups_v3_3`
CLUSTER BY canonical_pregnancy_episode_id
AS
SELECT
  m.canonical_pregnancy_episode_id,
  COUNT(*) AS canonical_episode_member_count,

  ARRAY_AGG(m.member_pregnancy_episode_id ORDER BY m.member_pregnancy_episode_id)
    AS canonical_episode_member_ids,

  ARRAY_AGG(
    COALESCE(m.final_merge_method, 'SELF')
    ORDER BY COALESCE(m.final_merge_priority, 0), COALESCE(m.final_merge_method, 'SELF')
  ) AS canonical_episode_merge_methods,

  COUNTIF(p.has_pregnancy_sigizi) > 0 AS group_has_pregnancy_sigizi,
  COUNTIF(p.has_pregnancy_epus) > 0 AS group_has_pregnancy_epus,

  ARRAY_AGG(DISTINCT p.sigizi_episode_id IGNORE NULLS ORDER BY p.sigizi_episode_id)
    AS canonical_sigizi_episode_ids,
  ARRAY_AGG(DISTINCT p.epus_episode_id IGNORE NULLS ORDER BY p.epus_episode_id)
    AS canonical_epus_episode_ids,

  ARRAY_AGG(DISTINCT p.nik_clean IGNORE NULLS ORDER BY p.nik_clean)
    AS final_nik_values,
  ARRAY_AGG(DISTINCT p.tanggal_lahir_ibu IGNORE NULLS ORDER BY p.tanggal_lahir_ibu)
    AS final_dob_values,
  ARRAY_AGG(DISTINCT p.nama_ibu IGNORE NULLS ORDER BY p.nama_ibu)
    AS final_name_values,
  ARRAY_AGG(DISTINCT p.puskesmas IGNORE NULLS ORDER BY p.puskesmas)
    AS final_puskesmas_values,

  COUNT(DISTINCT p.nik_clean) > 1 AS final_nik_conflict_flag,
  COUNT(DISTINCT IF(nik_is_trusted(p.nik_clean), p.nik_clean, NULL)) > 1
    AS final_trusted_nik_conflict_flag,
  COUNT(DISTINCT p.tanggal_lahir_ibu) > 1 AS final_dob_conflict_flag,
  COUNT(DISTINCT compact_name(p.nama_core_norm)) > 1 AS final_name_variant_flag,

  (
       COUNT(DISTINCT p.nik_clean) > 1
    OR COUNT(DISTINCT p.tanggal_lahir_ibu) > 1
    OR COUNT(DISTINCT compact_name(p.nama_core_norm)) > 1
  ) AS final_identity_conflict_flag,

  COUNTIF(m.final_merge_method = 'FINAL_HIGH_CONFLICT_UNIQUE_FINGERPRINT') > 0
    AS final_high_conflict_unique_fingerprint_applied,

  MIN(p.first_anc_date) AS group_first_anc_date,
  MAX(p.last_anc_date) AS group_last_anc_date,
  COUNTIF(p.has_phone_pregnancy_source) > 0 AS group_has_phone,
  COUNTIF(p.sigizi_episode_review_flag) > 0 AS group_sigizi_review_flag,
  SUM(COALESCE(p.sigizi_member_record_count, 0)) AS group_sigizi_member_record_count,
  SUM(COALESCE(p.sigizi_identity_propagated_record_count, 0))
    AS group_sigizi_identity_propagated_record_count,
  SUM(COALESCE(p.sigizi_ambiguous_identity_record_count, 0))
    AS group_sigizi_ambiguous_identity_record_count,
  MAX(p.sigizi_max_signature_row_count) AS group_sigizi_max_signature_row_count,
  SUM(COALESCE(p.sigizi_distinct_pregnancy_signature_count, 0))
    AS group_sigizi_distinct_pregnancy_signature_count,
  MAX(p.sigizi_anchor_spread_days) AS group_sigizi_anchor_spread_days,

  ARRAY_AGG(
    IF(
      m.final_merge_method IS NULL,
      NULL,
      STRUCT(
        m.final_merge_method AS method,
        m.final_merge_priority AS priority,
        m.final_merge_confidence AS confidence,
        m.anchor_difference_days AS anchor_difference_days,
        m.match_date_difference_days AS match_date_difference_days
      )
    )
    IGNORE NULLS
    ORDER BY m.final_merge_priority, m.match_date_difference_days, m.anchor_difference_days
    LIMIT 1
  )[SAFE_OFFSET(0)] AS best_final_merge_pick

FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_final_canonical_map_v3_3` m
JOIN `_SESSION.t_pregnancy_episode_spine_precanonical_v3_3` p
  ON p.pregnancy_episode_id = m.member_pregnancy_episode_id
GROUP BY m.canonical_pregnancy_episode_id;


CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_final_group_scalar_picks_v3_3`
CLUSTER BY canonical_pregnancy_episode_id
AS
WITH members AS (
  SELECT
    m.canonical_pregnancy_episode_id,
    b.*
  FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_final_canonical_map_v3_3` m
  JOIN `_SESSION.t_pregnancy_final_guard_base_v3_3` b
    ON b.pregnancy_episode_id = m.member_pregnancy_episode_id
)
SELECT
  canonical_pregnancy_episode_id,

  ARRAY_AGG(
    STRUCT(nik_clean AS value, final_episode_quality_score AS q)
    ORDER BY nik_clean IS NULL, NOT nik_is_trusted(nik_clean), final_episode_quality_score DESC, pregnancy_episode_id
    LIMIT 1
  )[SAFE_OFFSET(0)] AS nik_pick,

  ARRAY_AGG(
    STRUCT(nama_ibu AS value, nama_norm AS value_norm, nama_core_norm AS value_core,
           final_episode_quality_score AS q)
    ORDER BY nama_core_norm IS NULL, final_episode_quality_score DESC, pregnancy_episode_id
    LIMIT 1
  )[SAFE_OFFSET(0)] AS name_pick,

  ARRAY_AGG(
    STRUCT(tanggal_lahir_ibu AS value, final_episode_quality_score AS q)
    ORDER BY tanggal_lahir_ibu IS NULL, final_episode_quality_score DESC, pregnancy_episode_id
    LIMIT 1
  )[SAFE_OFFSET(0)] AS dob_pick,

  ARRAY_AGG(
    STRUCT(no_hp_clean AS value, phone_source AS source, final_episode_quality_score AS q)
    ORDER BY no_hp_clean IS NULL, LENGTH(COALESCE(no_hp_clean, '')) DESC, final_episode_quality_score DESC, pregnancy_episode_id
    LIMIT 1
  )[SAFE_OFFSET(0)] AS phone_pick,

  ARRAY_AGG(
    STRUCT(puskesmas AS value, puskesmas_norm AS value_norm, final_episode_quality_score AS q)
    ORDER BY puskesmas_norm IS NULL, final_episode_quality_score DESC, pregnancy_episode_id
    LIMIT 1
  )[SAFE_OFFSET(0)] AS puskesmas_pick,

  ARRAY_AGG(
    STRUCT(desa AS value, desa_norm AS value_norm, final_episode_quality_score AS q)
    ORDER BY desa_norm IS NULL, final_episode_quality_score DESC, pregnancy_episode_id
    LIMIT 1
  )[SAFE_OFFSET(0)] AS desa_pick,

  ARRAY_AGG(
    STRUCT(posyandu AS value, final_episode_quality_score AS q)
    ORDER BY posyandu IS NULL, final_episode_quality_score DESC, pregnancy_episode_id
    LIMIT 1
  )[SAFE_OFFSET(0)] AS posyandu_pick,

  ARRAY_AGG(
    STRUCT(alamat AS value, final_episode_quality_score AS q)
    ORDER BY alamat IS NULL, final_episode_quality_score DESC, pregnancy_episode_id
    LIMIT 1
  )[SAFE_OFFSET(0)] AS alamat_pick,

  ARRAY_AGG(
    STRUCT(hpht_sigizi AS value, final_episode_quality_score AS q)
    ORDER BY hpht_sigizi IS NULL, final_episode_quality_score DESC, pregnancy_episode_id
    LIMIT 1
  )[SAFE_OFFSET(0)] AS hpht_sigizi_pick,

  ARRAY_AGG(
    STRUCT(hpht_epus AS value, final_episode_quality_score AS q)
    ORDER BY hpht_epus IS NULL, final_episode_quality_score DESC, pregnancy_episode_id
    LIMIT 1
  )[SAFE_OFFSET(0)] AS hpht_epus_pick,

  ARRAY_AGG(
    STRUCT(hpl_sigizi AS value, final_episode_quality_score AS q)
    ORDER BY hpl_sigizi IS NULL, final_episode_quality_score DESC, pregnancy_episode_id
    LIMIT 1
  )[SAFE_OFFSET(0)] AS hpl_sigizi_pick,

  ARRAY_AGG(
    STRUCT(hpl_epus AS value, final_episode_quality_score AS q)
    ORDER BY hpl_epus IS NULL, final_episode_quality_score DESC, pregnancy_episode_id
    LIMIT 1
  )[SAFE_OFFSET(0)] AS hpl_epus_pick,

  ARRAY_AGG(
    STRUCT(delivery_sigizi AS value, final_episode_quality_score AS q)
    ORDER BY delivery_sigizi IS NULL, final_episode_quality_score DESC, pregnancy_episode_id
    LIMIT 1
  )[SAFE_OFFSET(0)] AS delivery_sigizi_pick,

  ARRAY_AGG(
    STRUCT(delivery_epus AS value, final_episode_quality_score AS q)
    ORDER BY delivery_epus IS NULL, final_episode_quality_score DESC, pregnancy_episode_id
    LIMIT 1
  )[SAFE_OFFSET(0)] AS delivery_epus_pick,

  ARRAY_AGG(
    STRUCT(hpl_from_sigizi_hpht AS value, final_episode_quality_score AS q)
    ORDER BY hpl_from_sigizi_hpht IS NULL, final_episode_quality_score DESC, pregnancy_episode_id
    LIMIT 1
  )[SAFE_OFFSET(0)] AS hpl_from_sigizi_hpht_pick,

  ARRAY_AGG(
    STRUCT(hpl_from_epus_hpht AS value, final_episode_quality_score AS q)
    ORDER BY hpl_from_epus_hpht IS NULL, final_episode_quality_score DESC, pregnancy_episode_id
    LIMIT 1
  )[SAFE_OFFSET(0)] AS hpl_from_epus_hpht_pick

FROM members
GROUP BY canonical_pregnancy_episode_id;


-- Union all ePUS source keys from every member so Stage 6 can still direct-match
-- outcomes belonging to any ePUS episode absorbed into the canonical pregnancy.
CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_final_group_epus_keys_v3_3`
CLUSTER BY canonical_pregnancy_episode_id
AS
SELECT
  m.canonical_pregnancy_episode_id,
  ARRAY_AGG(DISTINCT k ORDER BY k) AS epus_episode_source_keys
FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_final_canonical_map_v3_3` m
JOIN `_SESSION.t_pregnancy_episode_spine_precanonical_v3_3` p
  ON p.pregnancy_episode_id = m.member_pregnancy_episode_id
CROSS JOIN UNNEST(
  ARRAY_CONCAT(
    COALESCE(p.epus_episode_source_keys, ARRAY<STRING>[]),
    IF(p.epus_episode_source_key IS NULL, ARRAY<STRING>[], [p.epus_episode_source_key])
  )
) AS k
GROUP BY m.canonical_pregnancy_episode_id;


CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_final_group_sigizi_sources_v3_3`
CLUSTER BY canonical_pregnancy_episode_id
AS
SELECT
  m.canonical_pregnancy_episode_id,
  ARRAY_AGG(DISTINCT src ORDER BY src) AS sigizi_source_tables
FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_final_canonical_map_v3_3` m
JOIN `_SESSION.t_pregnancy_episode_spine_precanonical_v3_3` p
  ON p.pregnancy_episode_id = m.member_pregnancy_episode_id
CROSS JOIN UNNEST(COALESCE(p.sigizi_source_tables, ARRAY<STRING>[])) AS src
GROUP BY m.canonical_pregnancy_episode_id;


CREATE OR REPLACE TEMP TABLE `_SESSION.t_pregnancy_final_group_sigizi_identity_methods_v3_3`
CLUSTER BY canonical_pregnancy_episode_id
AS
SELECT
  m.canonical_pregnancy_episode_id,
  ARRAY_AGG(DISTINCT method ORDER BY method) AS sigizi_mother_identity_methods
FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_final_canonical_map_v3_3` m
JOIN `_SESSION.t_pregnancy_episode_spine_precanonical_v3_3` p
  ON p.pregnancy_episode_id = m.member_pregnancy_episode_id
CROSS JOIN UNNEST(COALESCE(p.sigizi_mother_identity_methods, ARRAY<STRING>[])) AS method
GROUP BY m.canonical_pregnancy_episode_id;


-- --------------------------------------------------------------------------
-- G. Rebuild the final pregnancy spine: ONE canonical row per real pregnancy.
--    Existing schema is preserved, with extra QA/audit columns appended.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3`
CLUSTER BY nik_clean, puskesmas_norm, pregnancy_episode_id
AS
SELECT
  p.* REPLACE(
    COALESCE(g.canonical_sigizi_episode_ids, ARRAY<STRING>[])[SAFE_OFFSET(0)] AS sigizi_episode_id,
    COALESCE(g.canonical_epus_episode_ids, ARRAY<STRING>[])[SAFE_OFFSET(0)] AS epus_episode_id,
    COALESCE(ek.epus_episode_source_keys, ARRAY<STRING>[])[SAFE_OFFSET(0)] AS epus_episode_source_key,
    COALESCE(ek.epus_episode_source_keys, ARRAY<STRING>[]) AS epus_episode_source_keys,

    COALESCE(p.cross_source_match_method, g.best_final_merge_pick.method)
      AS cross_source_match_method,
    COALESCE(p.cross_source_match_priority, g.best_final_merge_pick.priority)
      AS cross_source_match_priority,
    COALESCE(p.cross_source_match_confidence, g.best_final_merge_pick.confidence)
      AS cross_source_match_confidence,
    COALESCE(p.anchor_difference_days, g.best_final_merge_pick.anchor_difference_days)
      AS anchor_difference_days,
    COALESCE(p.match_date_difference_days, g.best_final_merge_pick.match_date_difference_days)
      AS match_date_difference_days,

    CASE
      WHEN g.group_has_pregnancy_sigizi AND g.group_has_pregnancy_epus THEN 'SIGIZI + EPUS'
      WHEN g.group_has_pregnancy_sigizi THEN 'SIGIZI ONLY'
      WHEN g.group_has_pregnancy_epus THEN 'EPUS ONLY'
      ELSE p.pregnancy_source_combination
    END AS pregnancy_source_combination,

    g.group_has_pregnancy_sigizi AS has_pregnancy_sigizi,
    g.group_has_pregnancy_epus AS has_pregnancy_epus,

    sp.nik_pick.value AS nik_clean,
    sp.name_pick.value AS nama_ibu,
    sp.name_pick.value_norm AS nama_norm,
    sp.name_pick.value_core AS nama_core_norm,
    sp.dob_pick.value AS tanggal_lahir_ibu,
    sp.phone_pick.value AS no_hp_clean,
    sp.phone_pick.source AS phone_source,

    sp.puskesmas_pick.value AS puskesmas,
    sp.puskesmas_pick.value_norm AS puskesmas_norm,
    sp.desa_pick.value AS desa,
    sp.desa_pick.value_norm AS desa_norm,
    sp.posyandu_pick.value AS posyandu,
    sp.alamat_pick.value AS alamat,

    sp.hpht_sigizi_pick.value AS hpht_sigizi,
    sp.hpht_epus_pick.value AS hpht_epus,
    sp.hpl_sigizi_pick.value AS hpl_sigizi,
    sp.hpl_epus_pick.value AS hpl_epus,
    sp.delivery_sigizi_pick.value AS delivery_sigizi,
    sp.delivery_epus_pick.value AS delivery_epus,
    sp.hpl_from_sigizi_hpht_pick.value AS hpl_from_sigizi_hpht,
    sp.hpl_from_epus_hpht_pick.value AS hpl_from_epus_hpht,

    COALESCE(sp.hpht_epus_pick.value, sp.hpht_sigizi_pick.value, p.hpht_date)
      AS hpht_date,
    CASE
      WHEN sp.hpht_epus_pick.value IS NOT NULL THEN 'EPUS'
      WHEN sp.hpht_sigizi_pick.value IS NOT NULL THEN 'SIGIZI'
      ELSE p.hpht_source
    END AS hpht_source,

    COALESCE(sp.hpl_epus_pick.value, sp.hpl_sigizi_pick.value, p.hpl_recorded_date)
      AS hpl_recorded_date,
    CASE
      WHEN sp.hpl_epus_pick.value IS NOT NULL THEN 'EPUS'
      WHEN sp.hpl_sigizi_pick.value IS NOT NULL THEN 'SIGIZI'
      ELSE p.hpl_recorded_source
    END AS hpl_recorded_source,

    COALESCE(
      sp.hpl_from_epus_hpht_pick.value,
      sp.hpl_from_sigizi_hpht_pick.value,
      p.hpl_from_hpht_date
    ) AS hpl_from_hpht_date,

    g.group_first_anc_date AS first_anc_date,
    g.group_last_anc_date AS last_anc_date,

    COALESCE(
      sp.hpht_epus_pick.value,
      sp.hpht_sigizi_pick.value,
      DATE_SUB(COALESCE(sp.hpl_epus_pick.value, sp.hpl_sigizi_pick.value), INTERVAL 280 DAY),
      p.pregnancy_anchor_date
    ) AS pregnancy_anchor_date,

    COALESCE(
      sp.hpht_sigizi_pick.value,
      DATE_SUB(sp.hpl_sigizi_pick.value, INTERVAL 280 DAY),
      p.sigizi_anchor_date
    ) AS sigizi_anchor_date,

    COALESCE(
      sp.hpht_epus_pick.value,
      DATE_SUB(sp.hpl_epus_pick.value, INTERVAL 280 DAY),
      p.epus_anchor_date
    ) AS epus_anchor_date,

    g.group_sigizi_anchor_spread_days AS sigizi_anchor_spread_days,
    g.group_sigizi_review_flag AS sigizi_episode_review_flag,
    g.group_sigizi_member_record_count AS sigizi_member_record_count,
    COALESCE(ss.sigizi_source_tables, ARRAY<STRING>[]) AS sigizi_source_tables,
    COALESCE(si.sigizi_mother_identity_methods, ARRAY<STRING>[]) AS sigizi_mother_identity_methods,
    g.group_sigizi_identity_propagated_record_count AS sigizi_identity_propagated_record_count,
    g.group_sigizi_ambiguous_identity_record_count AS sigizi_ambiguous_identity_record_count,
    g.group_sigizi_max_signature_row_count AS sigizi_max_signature_row_count,
    g.group_sigizi_distinct_pregnancy_signature_count AS sigizi_distinct_pregnancy_signature_count,

    g.group_has_phone AS has_phone_pregnancy_source,

    CASE
      WHEN sp.hpl_sigizi_pick.value IS NOT NULL AND sp.hpl_epus_pick.value IS NOT NULL
        THEN DATE_DIFF(sp.hpl_epus_pick.value, sp.hpl_sigizi_pick.value, DAY)
    END AS epus_minus_sigizi_hpl_days,

    CASE
      WHEN sp.hpht_sigizi_pick.value IS NOT NULL AND sp.hpht_epus_pick.value IS NOT NULL
        THEN DATE_DIFF(sp.hpht_epus_pick.value, sp.hpht_sigizi_pick.value, DAY)
    END AS epus_minus_sigizi_hpht_days,

    (p.cross_source_nik_conflict_flag OR g.final_nik_conflict_flag)
      AS cross_source_nik_conflict_flag
  ),

  g.canonical_episode_member_count,
  g.canonical_episode_member_ids,
  g.canonical_episode_merge_methods,
  g.canonical_episode_member_count > 1 AS final_canonicalization_applied,

  -- New explicit QA fields
  g.final_nik_values,
  g.final_dob_values,
  g.final_name_values,
  g.final_puskesmas_values,
  g.final_nik_conflict_flag,
  g.final_trusted_nik_conflict_flag,
  g.final_dob_conflict_flag,
  g.final_name_variant_flag,
  g.final_identity_conflict_flag,
  g.final_high_conflict_unique_fingerprint_applied,
  (
    g.final_identity_conflict_flag
    OR g.final_high_conflict_unique_fingerprint_applied
  ) AS final_match_qa_required,
  g.canonical_sigizi_episode_ids,
  g.canonical_epus_episode_ids

FROM `_SESSION.t_pregnancy_final_canonical_groups_v3_3` g
JOIN `_SESSION.t_pregnancy_episode_spine_precanonical_v3_3` p
  ON p.pregnancy_episode_id = g.canonical_pregnancy_episode_id
JOIN `_SESSION.t_pregnancy_final_group_scalar_picks_v3_3` sp
  USING (canonical_pregnancy_episode_id)
LEFT JOIN `_SESSION.t_pregnancy_final_group_epus_keys_v3_3` ek
  USING (canonical_pregnancy_episode_id)
LEFT JOIN `_SESSION.t_pregnancy_final_group_sigizi_sources_v3_3` ss
  USING (canonical_pregnancy_episode_id)
LEFT JOIN `_SESSION.t_pregnancy_final_group_sigizi_identity_methods_v3_3` si
  USING (canonical_pregnancy_episode_id);
