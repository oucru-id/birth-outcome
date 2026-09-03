-- Recovered source builder; v3 target. Run the complete file.
CREATE OR REPLACE TABLE
  `spheres-lombok-barat.kohort_bumil_v3.ref_step_wedge_lombok_barat`
AS

SELECT *
FROM UNNEST([

  -- ==========================================================================
  -- FLAGSHIP
  -- Baseline / outside randomization
  -- ==========================================================================

  STRUCT(
    'LABUAPI' AS puskesmas_key,
    'Flagship' AS step_wedge_group,
    0 AS step_wedge_order,
    CAST(NULL AS DATE) AS intervention_date,
    'Baseline / outside randomization' AS notes
  ),


  -- ==========================================================================
  -- STEP WEDGE 1
  -- Intervention: 20 August 2025
  -- ==========================================================================

  STRUCT('GERUNG',      'Step Wedge 1', 1, DATE '2025-08-20', CAST(NULL AS STRING)),
  STRUCT('PELANGAN',    'Step Wedge 1', 1, DATE '2025-08-20', CAST(NULL AS STRING)),
  STRUCT('SEDAU',       'Step Wedge 1', 1, DATE '2025-08-20', CAST(NULL AS STRING)),
  STRUCT('SIGERONGAN',  'Step Wedge 1', 1, DATE '2025-08-20', CAST(NULL AS STRING)),
  STRUCT('SURANADI',    'Step Wedge 1', 1, DATE '2025-08-20', CAST(NULL AS STRING)),


  -- ==========================================================================
  -- STEP WEDGE 2
  -- Intervention: 30 December 2025
  -- ==========================================================================

  STRUCT('BANYUMULEK',  'Step Wedge 2', 2, DATE '2025-12-30', CAST(NULL AS STRING)),
  STRUCT('DASAN TAPEN', 'Step Wedge 2', 2, DATE '2025-12-30', CAST(NULL AS STRING)),
  STRUCT('EYAT MAYANG', 'Step Wedge 2', 2, DATE '2025-12-30', CAST(NULL AS STRING)),
  STRUCT('KEDIRI',      'Step Wedge 2', 2, DATE '2025-12-30', CAST(NULL AS STRING)),
  STRUCT('NARMADA',     'Step Wedge 2', 2, DATE '2025-12-30', CAST(NULL AS STRING)),


  -- ==========================================================================
  -- STEP WEDGE 3
  -- Intervention: 23 April 2026
  -- ==========================================================================

  STRUCT('KURIPAN',   'Step Wedge 3', 3, DATE '2026-04-23', CAST(NULL AS STRING)),
  STRUCT('LINGSAR',   'Step Wedge 3', 3, DATE '2026-04-23', CAST(NULL AS STRING)),
  STRUCT('PENIMBUNG', 'Step Wedge 3', 3, DATE '2026-04-23', CAST(NULL AS STRING)),
  STRUCT('SEKOTONG',  'Step Wedge 3', 3, DATE '2026-04-23', CAST(NULL AS STRING)),
  STRUCT('SESELA',    'Step Wedge 3', 3, DATE '2026-04-23', CAST(NULL AS STRING)),


  -- ==========================================================================
  -- NON-INTERVENTIONS
  -- ==========================================================================

  STRUCT(
    'GUNUNGSARI',
    'Non-Interventions',
    4,
    CAST(NULL AS DATE),
    'Non-intervention group'
  ),

  STRUCT(
    'JEMBATAN KEMBAR',
    'Non-Interventions',
    4,
    CAST(NULL AS DATE),
    'Non-intervention group'
  ),

  STRUCT(
    'MENINTING',
    'Non-Interventions',
    4,
    CAST(NULL AS DATE),
    'Non-intervention group'
  ),

  STRUCT(
    'PERAMPUAN',
    'Non-Interventions',
    4,
    CAST(NULL AS DATE),
    'Non-intervention group'
  )

]);