# Historical migration procedures

These scripts preserve the baseline-capture procedures used for the independent-v3 migration and the subsequent geography repair. They are included for provenance and controlled maintenance, not as recurring refresh jobs.

- `independent_20260903/00_capture_baseline.sql` captures existing v3 core tables, reporting populations, view definitions and the reporting schema contract.
- `geography_20260903/00_capture_geography_baseline.sql` captures the separate pre-geography-repair state.

They use historical prefixes and `IF NOT EXISTS`. Re-running them after later changes does not refresh or reconstruct the original baseline. New migrations need separately reviewed snapshot names and comparison targets.

These scripts perform writes if executed. They require existing production objects and cannot bootstrap an empty v3 deployment. CTAS copies are not metadata-complete backups. Only the procedure text is versioned here; no snapshot data is uploaded.
