# Final dependency flow

```text
SIGIZI raw
   ↓
PBG-01 t_sigizi_source_records
   ↓
PBG-02 t_sigizi_pregnancy_episode_v3_3
   │
   ├──────────────────────────────────────┐
   │                                      │
ePUS raw                                  │
   ↓                                      │
PBG-03 t_epus_source_records              │
   ↓                                      │
PBG-04 t_epus_pregnancy_episode_adapter   │
   │                                      │
   └────────────────┬─────────────────────┘
                    ↓
PBG-05 FULL pregnancy identity resolution
  - within SIGIZI
  - within ePUS
  - SIGIZI ↔ ePUS
  - precanonical spine
  - final canonicalization
  - v4.1.1 safety patch
                    ↓
       t_pregnancy_episode_spine_v3_3
                    │
                    │
delivery raw feeds  │
(SIGIZI/ePUS/SIMRS/eKohort/BC)
         ↓          │
       PBG-06       │
         ↓          │
       PBG-07       │
         └──────┬───┘
                ↓
              PBG-08
                ↓
              PBG-09
                ↓
              PBG-10
                ↓
                QA
                ↓
         Reporting Views
                ↓
          Looker Studio
```
