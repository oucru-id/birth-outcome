-- ONE-TIME reference migration. This reads v2 only during initial setup.
-- Copies the CURRENT reference, not a proven historical snapshot from August 18.
-- Do not rebuild reference mappings from the contaminated source fields.
CREATE TABLE IF NOT EXISTS
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_location_reference`
AS SELECT DISTINCT puskesmas_norm, desa_norm, posyandu_norm
FROM `spheres-lombok-barat.kohort_bumil_v2.t_sigizi_location_reference`;

ASSERT (SELECT COUNT(*) > 0 FROM
  `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_location_reference`)
AS 'Location reference is empty. Stop; recover the maintained reference.';

SELECT puskesmas_norm, COUNT(*) AS reference_triplets,
  COUNT(DISTINCT desa_norm) AS distinct_desa
FROM `spheres-lombok-barat.kohort_bumil_v3.t_sigizi_location_reference`
GROUP BY puskesmas_norm ORDER BY puskesmas_norm;
