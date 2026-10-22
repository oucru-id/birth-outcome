# MATNEO v3.3 — staging canonicalization (22 October 2026)

## Context and frozen baseline

- Production pregnancy spine: `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3`
- Frozen baseline: `spheres-lombok-barat.kohort_bumil_v3_validation.pregnancy_spine_baseline_20261022`
- Baseline: **37,139** unique pregnancy episodes; **31,704** with `desa_norm`.
- Production canonicalization scheduler name: `t_sigizi_pregnancy_episode_canonical_v3_3`.
- Production monitoring, spine, canonical ePus, and outcome tracking have already passed desa-enrichment QA.
- **Do not enable/rerun the original production canonicalization scheduler during this staging test.**

## Execute in BigQuery (location `asia-southeast2`)

1. Confirm `kohort_bumil_v3_staging` exists and that the original production scheduler is paused.
2. Run **[20_pregnancy_canonicalization_staging_20261022.sql](20_pregnancy_canonicalization_staging_20261022.sql)** as one BigQuery multi-statement job. It contains the entire 3,289-line original matching script plus a staging header.
3. On successful completion, run **[21_pregnancy_canonicalization_staging_qa.sql](21_pregnancy_canonicalization_staging_qa.sql)** as one job. It emits three result sets:
   - pregnancy episode ID, membership and village stability against frozen baseline;
   - within-source canonical map reassignment compared with current production;
   - up to 100 changed pregnancy episode IDs for review.

## Static write-target audit

The staging canonicalization SQL redirects all references to six persistent intermediate/final outputs into `kohort_bumil_v3_staging`:

1. `t_sigizi_episode_canonical_map_v3_3`
2. `t_sigizi_pregnancy_episode_canonical_v3_3`
3. `t_epus_episode_canonical_map_v3_3`
4. `t_epus_pregnancy_episode_canonical_v3_3`
5. `t_pregnancy_episode_spine_v3_3`
6. `t_pregnancy_final_canonical_map_v3_3`

Only two production input tables are read: `t_sigizi_pregnancy_episode_v3_3` and `t_epus_pregnancy_episode_adapter_v3_3`. All temporary `_SESSION` tables are scoped to the staging job. Automated static audit found **no production persistent write targets**.

## Decision rules

- **`PASS_NO_DRIFT`**: no missing historical episode IDs, no change to membership, no changed existing populated desa, and no new episodes or new desa. This verifies baseline stability in staging but does **not** automatically publish.
- **`REVIEW_NEW_EPISODES_OR_DESA`**: historical IDs/memberships remain stable, but new episodes or newly filled village data exist. Review and approve.
- **`HOLD_ID_MEMBERSHIP_OR_DESA_DRIFT`**: historical IDs have vanished, memberships differ, populated baseline villages changed/lost, or duplicate/null staged IDs exist. Never publish without investigation.

Also inspect the **second QA result set** for any source canonical assignment changes, including newly added members. The first summary status does not automatically encode those source-map checks. Any change in existing source canonical map membership requires explicit review.

**No output of either script is auto-published to production.** A separate guarded publishing design is required after a review of the staging results and the prospective scheduler changes.

## Caveats

- The production canonicalization logic treats `desa_norm` as a score and/or corroborator. Enriching desa **can change** matching results and canonical ID selection, so a simple `CREATE OR REPLACE TABLE` on production would be unsafe.
- The older `sql/core/40_outcome_tracking.sql` in GitHub lacks the ePus patient-phone enrichment present in the user's actual production scheduled query. Do not replace production outcome tracking from that older GitHub file.
- If input data change during staging testing, new legitimate episodes may appear; assess that independently from historical ID drift.
