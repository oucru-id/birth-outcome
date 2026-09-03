-- Run after correction, and again after rebuilding downstream core.
CREATE TEMP FUNCTION facility_key(s STRING) AS (
  REGEXP_REPLACE(REGEXP_REPLACE(UPPER(TRIM(s)),
    r'^(?:(?:UPTD|UPT|PUSKESMAS|PKM)\s+)+',''),r'\s+','')
);
WITH populations AS (
 SELECT 'v3_source' AS population, puskesmas FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_source_records`
 UNION ALL SELECT 'v3_sigizi_episode',puskesmas FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_pregnancy_episode_v3_3`
 UNION ALL SELECT 'v3_spine',puskesmas FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3`
), ref AS (
 SELECT DISTINCT facility_key(puskesmas_key) AS k FROM
  `spheres-lombok-barat.kohort_bumil_v3.ref_step_wedge_lombok_barat`
)
SELECT p.population,p.puskesmas,COUNT(*) AS affected_rows
FROM populations p LEFT JOIN ref r ON facility_key(p.puskesmas)=r.k
WHERE NULLIF(TRIM(p.puskesmas),'') IS NOT NULL AND r.k IS NULL
GROUP BY p.population,p.puskesmas ORDER BY p.population,affected_rows DESC;

-- Selected operational cohort: retain unknown/outside labels for review, not exclusion.
SELECT puskesmas, integrated_monitoring_status_all_history AS monitoring_status,
 COUNT(*) AS row_count,COUNT(DISTINCT pregnancy_episode_id) AS pregnancy_count
FROM `spheres-lombok-barat.kohort_bumil_v3.v_pregnancy_monitoring_integrated`
WHERE monitoring_eligible_flag IS TRUE
GROUP BY puskesmas,monitoring_status ORDER BY puskesmas,monitoring_status;

-- These two core integrity diagnostics should return zero rows.
SELECT pregnancy_episode_id,COUNT(*) AS row_count
FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3`
GROUP BY pregnancy_episode_id HAVING pregnancy_episode_id IS NULL OR COUNT(*) > 1;
SELECT delivery_event_id,COUNT(*) AS row_count
FROM `spheres-lombok-barat.kohort_bumil_v3.t_delivery_event_master_v3`
GROUP BY delivery_event_id HAVING delivery_event_id IS NULL OR COUNT(*) > 1;
