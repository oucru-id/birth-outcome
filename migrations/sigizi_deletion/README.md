# SIGIZI deleted-pregnancy exclusion patch

## Purpose and behavior

The v3 package previously omitted both `vs_sigizi_bumil_hapus` and the deletion filter. The recovered older v2 source builder had the filter; the later scheduled writer used for migration did not. Creating a view alone would not restore exclusions.

This patch restores a pregnancy-specific exclusion gate before geography repair, episode construction and outcome evidence. It does not erase raw source data and does not add deletion records to the clinical source union.

| Match situation | Action |
| --- | --- |
| Usable NIK agrees and pregnancy anchor equals registry HPHT | Exclude the matching SIGIZI source record |
| Either NIK is unavailable, but normalized name, birth date and pregnancy anchor agree | Exclude the matching SIGIZI source record |
| Both usable NIKs exist and disagree | Do not exclude using name fallback |
| Same mother but different pregnancy anchor | Retain that pregnancy's source record |
| Registry HPHT missing, source anchor missing or identity insufficient | Do not guess; retain the source record unless another registry row matches, and review unresolved cases |
| Independent EPUS or hospital evidence exists | Keep that evidence; a SIGIZI deletion is not a cross-system cancellation |

The source anchor is HPHT, falling back to HPL minus 280 days only when HPHT is absent. Matching is exact, not date-tolerant or fuzzy. Names are case-folded, punctuation-separated and whitespace-normalized for this match only. Public source fields and column order are unchanged. A usable NIK here is a formatted identifier, not independently verified identity.

The source gate is record-based. An undated SIGIZI record cannot safely be excluded solely because the same mother has a dated deletion. Consequently, an unresolved record or independent-source evidence can still contribute an episode; this patch does not certify that every registry entry disappears from the integrated cohort.

The recovered registry view keeps the latest row per deletion matching key. This preserves its previous parsing and deduplication logic, with the missing comma after the `no` output field corrected. Its legacy `source_priority` field is audit metadata, not an instruction to union it into clinical sources. The raw registry must retain historical deletion notices. If exports are replaced with a partial list, old exclusions can disappear on refresh. Restoration/reinstatement actions, if introduced, need an explicit approved business rule; this patch treats registry membership as deletion evidence, as the recovered v2 filter did.

## Files and deployment

Run in the existing approved BigQuery location, `asia-southeast2`, as separate complete query jobs. This patch does not change a live database or scheduled query simply by being downloaded or committed.

| Order | File/action | Frequency |
| --- | --- | --- |
| Before changing production | Pause overlapping refreshes; preserve current source/core outputs and deployed scheduled SQL using your approved backup procedure | Deployment |
| Setup | Run `sql/setup/01a_sigizi_deleted_registry.sql` after the existing source-adapter setup | Once, then only on definition changes |
| Test | Run `tests/91_sigizi_deletion_regression.sql` and verify PASS | Deployment/regression |
| Input dependency | Confirm active SIGIZI inputs and retained deletion exports have finished loading | Every refresh |
| Source rebuild | Replace the old scheduled query text with the complete updated `sql/source_preparation/03_sigizi_source.sql`, then run it | Every refresh |
| Geography | Run the existing `sql/source_preparation/03a_sigizi_geography.sql` immediately afterward | Every refresh |
| Source validation | Run `validation/91_sigizi_deletion_checks.sql`; all checks must PASS | Every refresh |
| Downstream rebuild | Rebuild SIGIZI episodes, pregnancy canonicalization, USG/outcome evidence, outcome tracking, delivery canonicalization and first-report evidence, in the existing dependency order | Every refresh |
| Downstream validation | Run `validation/92_sigizi_deletion_downstream_checks.sql` and the existing core, geography and reporting checks | Every refresh |

For a deletion-only deployment with unchanged current EPUS preparation and adapter, the downstream files are `10_sigizi_episodes.sql`, `20_pregnancy_canonicalization.sql`, `30_usg_and_outcome_evidence.sql`, `40_outcome_tracking.sql`, `50_delivery_canonicalization.sql`, then `60_source_first_report.sql`. If EPUS inputs also refreshed, retain the complete existing schedule, including EPUS preparation and `11_epus_adapter.sql`. No Independent Core SQL definition changes are required for this gate; materialized core tables do need rebuilding.

Reporting views read the rebuilt tables and do not need recreation for this patch. Keep the geography step: the deletion gate does not replace it. Preserve the existing monitoring start date and other cohort parameters so comparisons are not confounded by configuration changes.

Use the [BigQuery multi-statement query workflow](https://docs.cloud.google.com/bigquery/docs/multi-statement-queries) to run the complete builder. Statements share temporary tables and functions; do not schedule its fragments independently. Permanent table replacements are not one atomic pipeline transaction: stop dependent work on any error. Audit, source and summary can disagree after a partially failed job; resolve the error and rerun the complete builder before continuing.

## Audit, review and verification limits

The builder publishes these outputs in `kohort_bumil_v3`:

- `t_sigizi_source_records`: active, nonmatched clinical source records, with the original public schema.
- `t_sigizi_deletion_exclusion_audit`: excluded source rows, original source payload, pregnancy-anchor method, all matching deletion references, match rules and run identity.
- `t_sigizi_deletion_exclusion_summary`: latest-run input, active, excluded and unresolved counts for reconciliation.

The audit and summary are replaced each run, not append-only history. Archive them inside the approved data environment if historical build audits are required. Never commit patient-level outputs or registry exports to GitHub.

Review exclusion rules and unresolved inputs before accepting changed dashboard totals. Audit records without a reliable pregnancy anchor must not be converted into a mother-wide blacklist. The episode-membership downstream check is conservative because that table stores source IDs without source-table qualification; it cannot prove every possible ambiguous identity has been resolved.

Local regression tests execute the actual matching CASE expression and check the source schema-projection wiring. The BigQuery-native fixture script additionally tests name normalization and HPHT/HPL precedence. Local success is not BigQuery compilation or live-data validation: run the supplied SQL tests and checks in your environment before declaring the deployment complete.

The Word guide and source-flow diagrams now describe this exclusion gate. Repository publication does not establish that the revised SQL is deployed in BigQuery.
