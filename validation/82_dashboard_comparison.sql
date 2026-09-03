-- Compare to frozen pre-rebuild v3 outputs. Current-date flags in baseline are frozen at capture.
-- PAGE 1 VALIDATION: run the WHOLE script in BigQuery, asia-southeast2.
-- Reads v2/v3 views and creates session-only TEMP tables. No persistent changes.
-- Before comparing in Looker: clear geography/status/source-combination selections;
-- use source_scope ALL and monitoring_eligible_flag TRUE for Block A.
-- Keep Block B on its delivery population (no pregnancy eligibility restriction).
-- NULL bounds below mean all dates; set each pair to match each block's actual
-- date-range settings. Block A uses EDD; Block B uses delivery_date.
-- Dashboard calculated fields/filter definitions are not available in screenshots.
-- These are source-defined candidate metrics, not a claim of exact chart parity.
-- Views use live CURRENT_DATE('Asia/Makassar'): compare on the same WITA day.
-- An old screenshot can differ even without a core refresh.
DECLARE edd_start DATE DEFAULT NULL;
DECLARE edd_end DATE DEFAULT NULL;
DECLARE delivery_start DATE DEFAULT NULL;
DECLARE delivery_end DATE DEFAULT NULL;

CREATE TEMP TABLE pregnancy_page1 AS
SELECT 'baseline' AS version, pregnancy_episode_id, expected_delivery_date, integrated_monitoring_status_all_history, primary_delivery_source, integrated_primary_delivery_source
FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_v_pregnancy_monitoring_integrated`
WHERE monitoring_eligible_flag IS TRUE
  AND (edd_start IS NULL OR expected_delivery_date >= edd_start)
  AND (edd_end IS NULL OR expected_delivery_date <= edd_end)
UNION ALL
SELECT 'rebuilt' AS version, pregnancy_episode_id, expected_delivery_date, integrated_monitoring_status_all_history, primary_delivery_source, integrated_primary_delivery_source
FROM `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_monitoring_by_source_scope`
WHERE source_scope = 'ALL' AND monitoring_eligible_flag IS TRUE
  AND (edd_start IS NULL OR expected_delivery_date >= edd_start)
  AND (edd_end IS NULL OR expected_delivery_date <= edd_end);

CREATE TEMP TABLE delivery_page1 AS
SELECT 'baseline' AS version, delivery_event_id, delivery_date, valid_known_birth_count, anc_linked_birth_count, not_successfully_linked_birth_count, no_anc_match_birth_count, ambiguous_anc_match_birth_count, anc_link_date_implausible_birth_count, inc_report_all_birth_capture_count, has_delivery_inc_report, pregnancy_linkage_reporting_status, anc_link_status
FROM `spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_v_delivery_monitoring_integrated`
WHERE (delivery_start IS NULL OR delivery_date >= delivery_start)
  AND (delivery_end IS NULL OR delivery_date <= delivery_end)
UNION ALL
SELECT 'rebuilt' AS version, delivery_event_id, delivery_date, valid_known_birth_count, anc_linked_birth_count, not_successfully_linked_birth_count, no_anc_match_birth_count, ambiguous_anc_match_birth_count, anc_link_date_implausible_birth_count, inc_report_all_birth_capture_count, has_delivery_inc_report, pregnancy_linkage_reporting_status, anc_link_status
FROM `spheres-lombok-barat.kohort_bumil_v3.v_delivery_monitoring_integrated`
WHERE (delivery_start IS NULL OR delivery_date >= delivery_start)
  AND (delivery_end IS NULL OR delivery_date <= delivery_end);

-- RESULT 1: Block A top scorecards, COUNT DISTINCT pregnancy IDs.
-- Sudah Melahirkan includes DELIVERED_DATE_UNKNOWN, per source view logic.
SELECT version,
  CURRENT_DATE('Asia/Makassar') AS validation_date_wita,
  COUNT(*) AS row_count,
  COUNT(DISTINCT pregnancy_episode_id) AS kehamilan_terpantau,
  COUNTIF(pregnancy_episode_id IS NULL) AS missing_ids,
  COUNT(DISTINCT IF(integrated_monitoring_status_all_history IN
    ('DELIVERED','DELIVERED_DATE_UNKNOWN'), pregnancy_episode_id, NULL)) AS sudah_melahirkan,
  COUNT(DISTINCT IF(integrated_monitoring_status_all_history = 'DELIVERED',
    pregnancy_episode_id, NULL)) AS delivered_with_date,
  COUNT(DISTINCT IF(integrated_monitoring_status_all_history = 'DELIVERED_DATE_UNKNOWN',
    pregnancy_episode_id, NULL)) AS delivered_date_unknown,
  COUNT(DISTINCT IF(integrated_monitoring_status_all_history = 'ABORTUS',
    pregnancy_episode_id, NULL)) AS abortus,
  COUNT(DISTINCT IF(integrated_monitoring_status_all_history = 'MISSING_BIRTH',
    pregnancy_episode_id, NULL)) AS status_kelahiran_belum_diketahui,
  COUNT(DISTINCT IF(integrated_monitoring_status_all_history = 'ACTIVE_PREGNANCY',
    pregnancy_episode_id, NULL)) AS masih_hamil,
  COUNT(DISTINCT IF(integrated_monitoring_status_all_history IS NULL OR
    integrated_monitoring_status_all_history NOT IN ('DELIVERED','DELIVERED_DATE_UNKNOWN',
      'ABORTUS','MISSING_BIRTH','ACTIVE_PREGNANCY'), pregnancy_episode_id, NULL)) AS other_status
FROM pregnancy_page1 GROUP BY version ORDER BY version;

-- RESULT 2: status bar chart; row_count vs IDs exposes duplication.
SELECT version, integrated_monitoring_status_all_history AS monitoring_status,
  COUNT(*) AS row_count, COUNT(DISTINCT pregnancy_episode_id) AS pregnancy_count
FROM pregnancy_page1 GROUP BY 1,2 ORDER BY 2,1;

-- RESULT 3: source bar chart. Screenshot uses primary_delivery_source.
-- Both fields are included to expose legacy vs integrated-source differences.
-- No additional delivered-only filter assumed; NULL source remains visible.
SELECT version, primary_delivery_source, integrated_primary_delivery_source,
  integrated_monitoring_status_all_history AS monitoring_status,
  COUNT(*) AS row_count, COUNT(DISTINCT pregnancy_episode_id) AS pregnancy_count
FROM pregnancy_page1 GROUP BY 1,2,3,4 ORDER BY 2,3,4,1;

-- RESULT 4: weekly status chart grouped by Monday EDD week, not delivery week.
SELECT version, DATE_TRUNC(expected_delivery_date, WEEK(MONDAY)) AS edd_week,
  integrated_monitoring_status_all_history AS monitoring_status,
  COUNT(*) AS row_count, COUNT(DISTINCT pregnancy_episode_id) AS pregnancy_count
FROM pregnancy_page1 GROUP BY 1,2,3 ORDER BY 2,3,1;

-- RESULT 5: Block B scorecards. Counts are the view's valid-birth counters.
-- Not linked includes no match, ambiguity and implausible dates.
-- INC_REPORT_TRACKER capture is the existing has_delivery_inc_report flag,
-- which can overlap with other delivery sources.
SELECT version,
  COUNT(*) AS technical_row_count,
  COUNT(DISTINCT delivery_event_id) AS distinct_delivery_ids,
  COUNTIF(delivery_event_id IS NULL) AS missing_ids,
  SUM(valid_known_birth_count) AS jumlah_persalinan_dilaporkan,
  SUM(anc_linked_birth_count) AS ada_catatan_anc,
  SUM(not_successfully_linked_birth_count) AS tidak_berhasil_terhubung_anc,
  SUM(no_anc_match_birth_count) AS no_anc_match,
  SUM(ambiguous_anc_match_birth_count) AS ambiguous_anc_match,
  SUM(anc_link_date_implausible_birth_count) AS implausible_anc_date,
  SUM(valid_known_birth_count) - SUM(anc_linked_birth_count)
    - SUM(not_successfully_linked_birth_count) AS linkage_partition_gap,
  SUM(inc_report_all_birth_capture_count) AS persalinan_birth_report_faskes,
  SUM(IF(has_delivery_inc_report, anc_linked_birth_count, 0)) AS faskes_ada_anc,
  SUM(IF(has_delivery_inc_report, not_successfully_linked_birth_count, 0)) AS faskes_tidak_terhubung_anc,
  100 * SAFE_DIVIDE(SUM(anc_linked_birth_count), SUM(valid_known_birth_count)) AS anc_linked_pct
FROM delivery_page1 GROUP BY version ORDER BY version;

-- RESULT 6: doughnut chart (valid births only); total must equal denominator.
SELECT version, pregnancy_linkage_reporting_status,
  COUNT(*) AS row_count, COUNT(DISTINCT delivery_event_id) AS delivery_count
FROM delivery_page1 WHERE valid_known_birth_count = 1
GROUP BY 1,2 ORDER BY 2,1;

-- RESULT 7: detailed ANC source-linkage chart, valid births only.
SELECT version, anc_link_status,
  COUNT(*) AS row_count, COUNT(DISTINCT delivery_event_id) AS delivery_count
FROM delivery_page1 WHERE valid_known_birth_count = 1
GROUP BY 1,2 ORDER BY 2,1;

-- INTERPRETATION:
-- First compare result 1 and 5 v2 values with the live Looker page.
-- If they differ, check date filters, hidden selections, calculated metrics,
-- chart filters, and whether the Looker connector points to this exact dataset.
-- Do not alter v3 clinical/matching logic to force historical screenshot totals.
-- HPL and >37-week subcards are intentionally pending their exact formulas.
