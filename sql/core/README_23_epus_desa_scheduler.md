# Scheduled ePus LPP desa enrichment — MATNEO pregnancy v3.3

## What this replaces (and what it does not)

The user-provided 3,289-line canonicalization SQL performs within-source/cross-source/final pregnancy **rematching**, creates or replaces six production tables, and **is not safe to schedule to enrich village alone**. Its staging rerun changed old IDs, canonical memberships and existing desa.

For village-only updates, create a **new BigQuery scheduled query** with the full content of [23_epus_desa_scheduled_refresh_only.sql](23_epus_desa_scheduled_refresh_only.sql). Pause/disable the old canonicalization scheduled query pending a separate guarded incremental pregnancy refresh solution. Do not accidentally leave that old scheduler running: it may overwrite village enrichment or change identities.

**The new desa-only job does not discover or append pregnancy episodes.** Keeping the legacy canonicalization job paused means new pregnancy registrations will need a separate identity-safe scheduled pipeline.

## Job configuration

- BigQuery project: `spheres-lombok-barat`.
- Location: `asia-southeast2`.
- Scheduled-query name: `kohort_v3_3_epus_desa_only`.
- Query type: multi-statement Standard SQL, not `CREATE OR REPLACE TABLE`; **no destination table**.
- Schedule **after successful refresh** of the upstream ePus LPP/ANC source preparation, `t_epus_pregnancy_master`, and `t_epus_pregnancy_episode_adapter_v3_3`, with sufficient time for completion.
- Ensure `t_pregnancy_episode_spine_v3_3` and `t_pregnancy_outcome_tracking_v3_3` have the same IDs before this scheduled query runs. Refresh tracking first if an independently approved pregnancy-update workflow introduces new episodes.
- The scheduled-query principal needs read permissions on all sources and validation baseline, update privileges for the 3 `kohort_bumil_v3` target tables, and BigQuery job permission.
- Disable overlapping runs and make errors/ASSERT failures visible in scheduled-query logs/alerts.

## Input and output safety

Read-only inputs:
- `kohort_bumil_v3_validation.pregnancy_spine_baseline_20261022`
- `kohort_bumil_v3.t_epus_pregnancy_master`
- `kohort_bumil_v3.t_epus_pregnancy_episode_adapter_v3_3`
- `kohort_bumil_v3.t_epus_episode_canonical_map_v3_3`
- Current canonical ePus, spine and tracking

The job updates **only `desa` and `desa_norm`**, and only where *both columns are currently NULL*, in:
1. `t_epus_pregnancy_episode_canonical_v3_3`
2. `t_pregnancy_episode_spine_v3_3`
3. `t_pregnancy_outcome_tracking_v3_3`

It uses existing episode membership/source keys. It never recomputes NIK, `pregnancy_episode_id`, matching or outcome. Conflicting/multiple village candidates are excluded from updates; an existing nonempty village is never overwritten. The updates are transactional.

## Guard and QA

The job checks:
- All **37,139** baseline pregnancy IDs from 2026-10-22 still exist with unchanged canonical membership signatures (new episodes are permitted).
- Unique episode IDs, adapter IDs and source keys, complete referenced ePus source keys, and spine/tracking ID set equality.
- After updating, no populated village changed and spine/tracking village fields are identical.

It emits three QA rows (`EPUS_CANONICAL`, `SPINE`, `TRACKING`), each with `qa_status='PASS'`. Initial reference after approved enrichment: ePus 18,286 rows, 14,489 complete desa; spine/tracking 37,139 rows, 31,704 complete desa. Future legitimate new episodes may change these counts.

If the first job runs on the already enriched data it should normally show `newly_enriched=0`. New values can appear after upstream source refresh.

If an ASSERT fails, **do not bypass it** by removing the guard: review the upstream data and/or running scheduler ordering first.

## Verification without touching matching

```sql
SELECT 'SPINE' AS stage, COUNT(*) AS episodes,
       COUNTIF(desa IS NOT NULL AND desa_norm IS NOT NULL) AS complete_desa
FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_episode_spine_v3_3`
UNION ALL
SELECT 'TRACKING', COUNT(*),
       COUNTIF(desa IS NOT NULL AND desa_norm IS NOT NULL)
FROM `spheres-lombok-barat.kohort_bumil_v3.t_pregnancy_outcome_tracking_v3_3`;
```

The integrated monitoring view reads from tracking and has already passed village consistency QA. No view recreation is required if its current projection exposes village fields.

## Safe scheduler order

Source ingestion/cleaning -> ePus maternal master and adapter -> approved stable pregnancy spine/tracking -> **23_epus_desa_scheduled_refresh_only.sql** -> monitoring (view, automatically refreshed on read).

**Future improvement (separate workstream):** incremental pregnancy matching with frozen historic source memberships, staging QA and approval before any legacy-episode reassignment; do not bundle this work into village enrichment.
