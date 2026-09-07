# Purbalingga Production SQL Package — FINAL v1.6

Project: `stellar-orb-451904-d9`  
Dataset: `kohort_bumil_v2`  
Timezone: `Asia/Jakarta`

## Final scheduling decision

The newly recovered BigQuery parent job confirms that the entire pregnancy identity-resolution bridge is already contained in one script:

`03C_v4_1_FULL_FINAL_IDENTITY_RESOLUTION`

It starts from:
- `t_sigizi_pregnancy_episode_v3_3`
- `t_epus_pregnancy_episode_adapter_v3_3`

and rebuilds:
- within-SIGIZI canonicalization,
- within-ePUS canonicalization,
- SIGIZI ↔ ePUS one-to-one matching,
- precanonical pregnancy spine,
- final pair blocks/features,
- final canonical pregnancy spine.

Therefore the previously separate PBG-05P / PBG-05A child statements should **not** be scheduled individually.

## PBG-05 safety patch

The recovered full script is v4.1. The later recovered v4.1.1 patch contains an important safety change:
the two strong pregnancy-fingerprint override rules cannot merge when **both trusted NIK and DOB disagree**.

For production scheduling, `scheduled/05_PBG-05_canonical_pregnancy_FULL_v4_1_plus_v4_1_1_patch.sql`
runs both in sequence:

1. FULL v4.1 rebuild
2. v4.1.1 conservative patch

This makes PBG-05 self-contained from the PBG-02/PBG-04 outputs.

## Final scheduled-query chain

PBG-01 → PBG-02  
PBG-03 → PBG-04  
PBG-02 + PBG-04 → PBG-05  
PBG-01 + PBG-03 + delivery raw feeds → PBG-06  
PBG-05 + PBG-07 → PBG-08 → PBG-09 → PBG-10 → QA

## Daily requirement

PBG-10 must run daily even when raw inputs did not change, because operational pregnancy status depends on `CURRENT_DATE('Asia/Jakarta')`.

## Reporting views

Objects under `views_deploy_once/` are views. Do not schedule them daily.
Re-run only when their SQL logic changes.

## Scheduling method

If using BigQuery Scheduled Queries only, use separate schedules with enough time between dependent jobs.
If a stage fails, downstream stages should be considered stale and rerun after the failed stage succeeds.
