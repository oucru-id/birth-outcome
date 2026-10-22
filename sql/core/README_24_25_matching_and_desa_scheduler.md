# Pregnancy v3.3 scheduled canonicalization & desa refresh (2026-10-22)

## User-approved policy

- **Correct matching is the priority.** Historical `pregnancy_episode_id` can change if a better match merges/rekeys records. Do **not** require a frozen 37,139 episodes.
- **Data-source conservation:** each current source episode (SiGizi/ePus) must be represented once in within-source canonical maps, and every canonical source episode must be represented exactly once in the final pregnancy spine.
- **Desa:** retain SiGizi residential village when present; fall back to enriched ePus LPP village. Final within-pregnancy village scalar selection prioritizes a SiGizi-bearing episode with populated village.
- The full historical matching hierarchy is retained; only the ePus canonical quality `+3 desa` bonus is removed, based on the A/B test of 24 anchor reassignments; village presence can remain corroborating evidence in higher-specificity matching rules.
- Identity/NIK conflicts should be reviewed, not silently claimed error-free. Date consistency and source history should be audited downstream.

## Files

1. [24_pregnancy_canonicalization_scheduled_candidate.sql](24_pregnancy_canonicalization_scheduled_candidate.sql): full v3.3 canonicalization with staging builds, integrity QA, optional production publish.
2. [25_epus_desa_refresh_after_canonicalization.sql](25_epus_desa_refresh_after_canonicalization.sql): only village enrichment via the latest stable source membership/source keys; NO frozen baseline guard. Requires current matching spine/tracking ID sets to be aligned.

**Obsolete for this new ID-change policy:** [23_epus_desa_scheduled_refresh_only.sql](23_epus_desa_scheduled_refresh_only.sql) checks frozen 2026-10-22 historic membership and thus is not the appropriate post-matching script.

## Trial before enabling the schedule

1. Keep the **old unguarded 3,289-line canonicalization scheduler paused** so it cannot overwrite this pipeline.
2. Run file **24** with `DECLARE publish_to_production BOOL DEFAULT FALSE;`. All six persistent results are written only into `kohort_bumil_v3_staging`; the QA at the end runs automatically. Inspect episode count, source coverage, conflict flags and desa completeness.
3. Review novel cross-source matches, rekeys/merges, and any increase in `final_trusted_nik_conflict_flag` or `final_match_qa_required`. A successful technical assertion establishes source conservation **not** clinical/person linkage accuracy.
4. Once QA and selected case review are satisfactory, set `publish_to_production = TRUE` in the same SQL and use that as the new scheduled canonicalization job (or replace the body of the existing job). The publish is sequential across six production tables, not an atomic transaction. Ensure no downstream job reads those tables while they are being replaced.
5. Run the **existing current production outcome-tracking scheduled SQL** (the full recent version, not any older file from GitHub), which rebuilds tracking from the latest pregnancy spine; then run file **25**, then allow the monitoring views to serve updated data.
6. Verify `COUNT(*) = COUNT(DISTINCT pregnancy_episode_id)`, every source episode is represented and latest spine/tracking IDs agree. Do not blindly schedule the preflight dry-run variant and expect it to update production.

## Scheduler order (same day, with completed-job dependencies)

```text
Source ingestion -> SiGizi/EPUS cleaning and pregnancy episode inputs
  -> 24 canonicalization: stage -> QA -> (approved) publish
  -> current t_pregnancy_outcome_tracking_v3_3 build
  -> 25 desa refresh (ePus LPP -> canonical ePus -> spine -> tracking)
  -> v_pregnancy_monitoring_integrated / Looker
```

All jobs must run after their upstream input has completed and use BigQuery location `asia-southeast2`. If scheduled SQL does not support explicit cross-job dependencies in your setup, use time separation plus job failure alerts, or an orchestrator; schedule times alone cannot guarantee dependency completion.

## Caveats

- ePus village completeness should **not** determine the maternal NIK: a source that happened to fill an address must not automatically win the canonical identity tie.
- Two sources disagreeing on residence does not mean either value is automatically correct. The SiGizi-first policy reflects the desired default; disagreements can be reported for data-quality follow-up.
- Historical consumers keyed by the old `pregnancy_episode_id` must be refreshed or mapped if IDs change, including birth/outcome linkage trackers and any external references.
- The source-conservation QA does **not** validate every pregnancy merge. Existing high-conflict identity override heuristics are retained, so review evidence in high-risk cases before enabling recurring production publish.
- If dataset refresh runs overlap, the non-atomic sequential publishing step can produce temporary inconsistency. Run only one canonicalization job at a time and schedule downstream materializations afterward.
