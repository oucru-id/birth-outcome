# Execution and maintenance runbook

## Scope

These files target the existing `spheres-lombok-barat.kohort_bumil_v3` deployment in `asia-southeast2`. They retain the supplied SQL logic. The repository is not an empty-project bootstrap: raw inputs, datasets, permissions, reference data and the saved reporting contract must already be available or separately established.

The import manifest records the original recovered SQL. Reviewed changes after import include the SIGIZI deletion exclusion described in `migrations/sigizi_deletion/README.md`; changed files no longer have their original import checksums. Historical header comments may mention v2, but comments are not executable dependencies. The current recurring builders address v3 preparation/core objects; the deliberate one-time location-reference seed still reads v2.

Uploading this repository does not configure or run any scheduled query. No automatic BigQuery deployment is enabled.

## One-time setup and deliberate redeployment

| File | Purpose | Caution |
|---|---|---|
| `sql/setup/01_source_adapter_views.sql` | Create or replace source cleaning/adapter views | Requires original raw, Kobo and adjudication inputs |
| `sql/setup/01a_sigizi_deleted_registry.sql` | Create the v3 SIGIZI pregnancy-deletion registry view | Requires `raw_data.sigizi_bumil_hapus_new`; deploy before the updated SIGIZI source builder |
| `sql/setup/02_reference.sql` | Build the stepped-wedge reference from recovered inline definitions | Uses replacement semantics; do not overwrite maintained changes as a daily job |
| `sql/setup/01_seed_location_reference.sql` | Seed the v3 location reference from the maintained v2 reference | One-time v2 dependency; preserves an existing v3 table; does not establish historical reference equivalence |
| `sql/reporting/70_reporting_views.sql` | Deploy reporting views using saved explicit field projections | Requires the retained schema-contract table described below |

The setup folder is a classification, not an instruction to execute every file alphabetically. Review the purpose and prerequisites of each file first.

## Recurring full-refresh order

Run each file as a complete standalone query job. Wait for success before starting the next dependent job. Do not simply concatenate scripts: declarations, temporary functions and temporary tables can conflict across standalone files.

| Run order | File | Main role |
|---|---|---|
| First | `sql/source_preparation/03_sigizi_source.sql` | Rebuild SIGIZI source records, excluding matched deleted pregnancies and publishing the exclusion audit |
| Immediately afterward | `sql/source_preparation/03a_sigizi_geography.sql` | Repair geography and publish the corrected source table |
| Next | `sql/source_preparation/04_epus_source.sql` | Rebuild EPUS source records |
| Next | `sql/source_preparation/05_epus_mother.sql` | Assign mother identities |
| Next | `sql/source_preparation/06_epus_pregnancy_records.sql` | Assign pregnancy episodes to source records |
| Next | `sql/source_preparation/07_epus_anc_events.sql` | Canonicalize ANC visits |
| Next | `sql/source_preparation/08_epus_master.sql` | Build the EPUS pregnancy master |
| Next | `sql/core/10_sigizi_episodes.sql` | Build SIGIZI pregnancy episodes |
| Next | `sql/core/11_epus_adapter.sql` | Adapt the v3 EPUS master; do not run an older v2-copy bridge |
| Next | `sql/core/20_pregnancy_canonicalization.sql` | Canonicalize and match pregnancy episodes |
| Next | `sql/core/30_usg_and_outcome_evidence.sql` | Build USG dating and outcome evidence |
| Next | `sql/core/40_outcome_tracking.sql` | Build pregnancy outcome tracking |
| Next | `sql/core/50_delivery_canonicalization.sql` | Deduplicate deliveries and apply ANC linkage |
| Last build | `sql/core/60_source_first_report.sql` | Build native first-report evidence |
| After successful builds | Relevant checks under `validation/` | Review integrity, geography and reporting behavior |

This sequential order is a conservative valid schedule. An orchestrator may parallelize independent work only after encoding the actual dependencies. Do not schedule files at fixed offsets and assume upstream success.

The operational `monitoring_start_date` is currently declared as `2025-12-01` in `40_outcome_tracking.sql`. It is a cohort rule, not the lower bound for every analysis. Review it separately from other source/reporting date windows.

Views do not need daily recreation solely because their underlying tables were rebuilt. Redeploy view definitions deliberately when the SQL or reporting contract changes.

## SIGIZI deletion dependency

Refresh and retain the raw SIGIZI deletion registry before each SIGIZI source build. The `vs_sigizi_bumil_hapus` view is an exclusion reference, never an additional clinical source. The updated source builder matches a pregnancy by usable NIK plus exact HPHT, or by normalized name, birth date and exact HPHT when either NIK is unavailable. Source HPL minus the gestation interval is used only when source HPHT is absent. Conflicting usable NIKs do not fall back to names.

This excludes matching SIGIZI records, not independent EPUS or hospital records, and not every pregnancy belonging to a mother. Missing dates or insufficient identity remain unresolved for review, rather than triggering broad exclusions. The audit and summary tables describe the latest build, not an immutable event history. Protect access as for the clinical source data.

Run `validation/91_sigizi_deletion_checks.sql` after source preparation plus geography correction, and `validation/92_sigizi_deletion_downstream_checks.sql` after rebuilding the core. Replace the deployed scheduled text for `03_sigizi_source.sql`; creating the registry view by itself does not activate exclusions. Registry setup, audit and summary tables need no separate daily schedule.

## Geography dependency

Always run SIGIZI source preparation and geography correction together. The source rebuild temporarily exposes the uncorrected geography until the correction succeeds; do not allow downstream builders between these steps.

The correction reads `kohort_bumil_v3.t_sigizi_location_reference`, writes `t_sigizi_location_resolved_v1`, and updates the existing `t_sigizi_source_records` without adding geography audit fields to its reporting contract. Do not infer new reference mappings from contaminated fields.

An all-history nonlocal facility label is not automatically an error to delete. Compare operational scope, reference membership and the resolver evidence. Retained ambiguity/low-confidence handling follows the supplied compatibility logic and requires deliberate review before changing it.

## Reporting schema contract

`70_reporting_views.sql` requires:

`spheres-lombok-barat.kohort_bumil_v3_validation.independent_20260903_view_columns`

It uses that saved metadata at deployment to construct explicit column projections. The deployed views contain static SELECT definitions and do not consult the metadata table at query time. Retain the saved contract for redeployment.

The historical capture script under `migrations/independent_20260903/` captures an existing set of reporting views; it cannot create the first reporting contract in an empty dataset. Do not run it after a schema change and assume it reconstructs the old contract. If the contract is missing, stop and recover the approved metadata or approved deployed definitions before deploying reporting SQL.

## Failure and change handling

- Stop downstream execution when a builder or assertion fails. Keep the error and job identifier for investigation.
- Avoid overlapping full refreshes and preserve a reviewed rollback plan before changing production logic.
- These jobs are not atomic as a group; tables can temporarily represent different refreshes. Baseline CTAS scripts do not preserve all metadata, policies or clustering details.
- For a new migration, create a deliberately named new baseline procedure. Do not reuse the historical snapshot prefixes or overwrite their original meaning.
- Check source membership and canonical maps when identifiers change. An old ID disappearing is not proof that its source records were lost.
- Test reporting schemas and chart filters as well as metrics. Equal schemas do not establish equal values or correct matching.
- Update the deployed scheduled-query text through the approved process after a code review. GitHub commits alone do not synchronize BigQuery schedules or Looker data sources.

## Data handling

Run row-level diagnostics only in the approved data environment. Keep patient exports, row-level screenshots, service-account JSON, API tokens and connection files out of commits. Use code and de-identified descriptions in review discussions.
