# birth-outcome

Lombok Barat birth outcome pipeline: BigQuery SQL, data flow, matching logic and documentation.

This repository holds the reviewed `kohort_bumil_v3` source-preparation, geography, independent-core and reporting SQL. It is a version-controlled copy of the supplied implementation, **not a fresh export of live BigQuery or a fully self-contained empty-project installer**.

## Start here

- [Data-flow overview](docs/workflow.md): where source records enter and how they reach Looker.
- [Detailed Word guide](docs/Lombok_Barat_v3_Data_Flow_and_Matching.docx): simple summary, detailed cleaning/deduplication/matching logic, and appendix.
- [Execution and maintenance runbook](docs/runbook.md): refresh order, setup dependencies and deployment cautions.
- [Validation guide](validation/README.md): which checks need the retained migration baseline.
- [Import provenance](docs/import_manifest.json): original package paths and file checksums.

## Repository layout

| Location | Purpose | Execution role |
|---|---|---|
| `sql/setup/` | Source adapter views and reference initialization | Deliberate setup/deployment; not a daily blanket refresh |
| `sql/source_preparation/` | SIGIZI and EPUS preparation, including geography correction | Recurring builds |
| `sql/core/` | Pregnancy episodes, canonicalization, dating, outcome tracking, delivery linkage and first-report evidence | Recurring builds |
| `sql/reporting/` | Reporting-view definitions with explicit saved field projections | Deploy when definitions change |
| `validation/` | Integrity, schema, dashboard and geography diagnostics | Checks after relevant builds; some require historical snapshots |
| `migrations/` | Preserved migration baseline-capture scripts | Historical controlled procedures, not recurring jobs |
| `docs/` | Workflow, operating notes and detailed guide | Documentation only |

## Important operating rules

The target project is `spheres-lombok-barat`, production dataset is `kohort_bumil_v3`, and BigQuery location is `asia-southeast2`. Date logic uses the timezone/configuration in each script; the current operational monitoring start is pinned in `40_outcome_tracking.sql`.

Run complete standalone SQL files in dependency order. Source preparation must finish before its consumers. In particular, always run `03a_sigizi_geography.sql` after `03_sigizi_source.sql` and before SIGIZI episode generation. Do not also run an older EPUS adapter copy bridge over the independent adapter.

The reporting deployment reads its field contract from `kohort_bumil_v3_validation.independent_20260903_view_columns`. Preserve that metadata. The one-time geography seed reads the maintained v2 location reference; recurring geography correction reads v3. Raw, Kobo, adjudication and facility-reporting inputs remain external to this repository.

## Scope and safety

- No patient-level exports, dashboard result dumps, credentials or service-account keys are included.
- SQL contains patient-field names because it processes authorized clinical data; those field names are not exported patient records.
- No GitHub Actions workflow, BigQuery scheduled query, ingestion schedule or Looker connection is created by this import.
- Uploading or editing a file here does not deploy it to BigQuery. Existing scheduled-query SQL must be updated separately through the approved deployment process.
- Some SQL uses `CREATE OR REPLACE` and materializes sensitive data when executed. Review changes, permissions, backups and downstream effects before running it.
- Static inspection is not a claim of live execution, exact historical parity or clinical matching correctness.

Keep this repository private. Do not commit row-level troubleshooting outputs or identifiable screenshots. Preserve reporting field names, types, grain and filter meaning when updating logic.
