# Static dependency audit

The recovered full parent job proves that the previously missing pregnancy bridge is part of one script.

## PBG-05 parent job

- Job ID: `bquxjob_add6d03_1a02c9c7fa4`
- Statement type: `SCRIPT`
- Query hash: `5af2b848404d34a13bfc7ba54915f4c79fe38549ebb569add4c62a29bdb8cc4a`
- Created tables in the full parent script: **32**

The full parent creates all canonical-pregnancy bridge objects, including:
- `t_sigizi_pregnancy_episode_canonical_v3_3`
- `t_epus_pregnancy_episode_canonical_v3_3`
- `t_pregnancy_cross_source_matches_v3_3`
- `t_pregnancy_episode_spine_precanonical_v3_3`
- `t_pregnancy_final_guard_base_v3_3`
- `t_pregnancy_final_pair_blocks_v3_3`
- `t_pregnancy_final_pair_features_v3_3`
- `t_pregnancy_episode_spine_v3_3`

The production schedule should therefore use the full parent script plus the later v4.1.1 patch as one PBG-05 job.
