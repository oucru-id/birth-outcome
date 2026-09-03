# Validation queries

The files here are diagnostic SQL, not result exports. They do not certify the pipeline merely by existing in the repository.

| File | Checks | Prerequisites |
|---|---|---|
| `80_core_checks.sql` | Population ID integrity, accepted-link conflicts and summary comparisons | Current v3 outputs plus retained `independent_20260903_*` snapshots |
| `81_reporting_schema_and_dependencies.sql` | Reporting-view presence, saved-schema comparison and v2 references in deployed view SQL | Current v3 views plus `independent_20260903_view_columns` |
| `82_dashboard_comparison.sql` | Pregnancy and delivery dashboard definitions against the frozen baseline | Current v3 outputs plus retained independent-migration reporting snapshots |
| `90_geography_checks.sql` | Facility labels across source/episode/spine, operational geography and duplicate/missing IDs | Current v3 tables/views and the stepped-wedge reference; no historical baseline is required |

The independent-migration comparisons do not automatically compare against the later geography-repair snapshots. Do not relabel one baseline as another.

Some result sets are exception lists, where no rows is the expected outcome. Other result sets are summaries that should contain rows. Interpret each query separately rather than treating every empty result as a pass.

Use consistent source inputs, date rules and filters for comparisons. Population differences can arise from refreshed sources, date-sensitive logic or changed grouping; investigate the contributing source records before drawing conclusions. These checks do not replace patient-level adjudication of uncertain matches.

Do not commit the result files when they contain identifiable records.
