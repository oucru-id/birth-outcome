# Purbalingga data pipeline diagram

This diagram traces the Purbalingga pipeline from retained raw sources through
canonical pregnancy and delivery processing, first-seen lineage, integrated
monitoring, QA, and the deploy-once reporting views.

The editable Mermaid source is available in
[`PURBALINGGA_PIPELINE_DIAGRAM.mmd`](PURBALINGGA_PIPELINE_DIAGRAM.mmd).

```mermaid
flowchart TB
  subgraph R1["Pregnancy raw sources"]
    SRAW["SIGIZI\nDAFTAR_BUMIL\nKESGA_BUMIL_ANC\nKOHORT_IBU\nKESGA_BUMIL\nIBU_NIFAS"]
    ERAW["ePUS\nepus_anc\nepus_kunjungan_ibu_hamil\nepus_inc\nepus_pnc"]
  end

  SRAW --> P01["PBG-01\nSIGIZI standardization"]
  P01 --> TSR["t_sigizi_source_records"]
  TSR --> P02["PBG-02\nSIGIZI pregnancy episodes"]
  P02 --> SEP["t_sigizi_pregnancy_episode_v3_3"]

  ERAW --> P03["PBG-03\nePUS standardization"]
  P03 --> TER["t_epus_source_records"]
  TER --> P04["PBG-04\nePUS pregnancy episodes"]
  P04 --> EEP["t_epus_pregnancy_episode_adapter_v3_3"]

  SEP --> P05["PBG-05\nCanonical pregnancy identity resolution"]
  EEP --> P05
  P05 --> SPINE["t_pregnancy_episode_spine_v3_3"]

  subgraph FS["Pregnancy first-seen branch"]
    P05C["PBG-05C\nUpload lineage and first-seen summary"]
    LINEAGE["t_pregnancy_source_upload_lineage_v3_3"]
    SUMMARY["t_pregnancy_upload_summary_v3_3"]
  end

  SPINE --> P05C
  TSR --> P05C
  TER --> P05C
  SRAW -. "retained raw history" .-> P05C
  ERAW -. "retained raw history" .-> P05C
  P05C --> LINEAGE
  P05C --> SUMMARY

  subgraph R2["Delivery raw sources"]
    DRAW["SIGIZI and ePUS\nstandardized evidence"]
    SIMRS["SIMRS\nsimrs_api_inc"]
    EK["eKohort\nekohort_persalinan\nekohort_pelayanan_ibu_bersalin_fixed"]
    BC["Birth confirmation\nbirth_confirmation_app\nbirth_confirmation"]
  end

  TSR --> DRAW
  TER --> DRAW
  DRAW --> P06["PBG-06\nDelivery source standardization"]
  SIMRS --> P06
  EK --> P06
  BC --> P06
  P06 --> DSR["t_delivery_source_records_v3_3"]
  DSR --> P07["PBG-07\nDelivery deduplication"]
  P07 --> DEC["t_delivery_event_canonical_v3_3"]

  SPINE --> P08["PBG-08\nDelivery-to-pregnancy linkage"]
  DEC --> P08
  P08 --> LINK["t_delivery_pregnancy_link_v3_3"]
  LINK --> P09["PBG-09\nPost-ANC delivery consolidation"]
  P09 --> POST["t_delivery_event_canonical_post_anc_v3_3"]

  subgraph ENRICH["PBG-10 enrichment inputs"]
    EANC["raw_data.epus_anc"]
    ELPP["raw_data.epus_laporan_pelayanan_pasien_update\nphone fallback only"]
  end

  SPINE --> P10["PBG-10\nIntegrated pregnancy monitoring"]
  POST --> P10
  DSR --> P10
  EANC --> P10
  ELPP --> P10
  P10 --> HELPERS["USG and outcome-evidence helper tables"]
  P10 --> MON["t_pregnancy_monitoring_integrated_v3_3"]
  MON --> VMON["v_pregnancy_monitoring_integrated"]

  subgraph VIEWS["Deploy-once reporting views"]
    VDEL["v_delivery_monitoring_integrated\nexisting delivery view"]
    VLONG["v_birth_reporting_source_long"]
    VTREND["v_birth_reporting_daily_trend"]
    VGA["v_delivery_gestational_age"]
    VBW["v_delivery_birth_weight"]
    VREG["v_pregnancy_registry_v3_3"]
    VNEW["v_new_pregnancy_metrics_daily_v3_3"]
  end

  VDEL --> VLONG
  DSR --> VLONG
  VLONG --> VTREND
  VDEL --> VGA
  MON --> VGA
  VDEL --> VBW
  DSR --> VBW
  VMON --> VREG
  SPINE --> VREG
  SUMMARY --> VREG
  VREG --> VNEW

  MON --> QA["Daily QA after PBG-10"]
  LINEAGE --> FSQA["First-seen validation"]
  SUMMARY --> FSQA
```

## Scheduling interpretation

- PBG-01 → PBG-02 and PBG-03 → PBG-04 may run as parallel source branches.
- PBG-05 starts only after PBG-02 and PBG-04 succeed.
- PBG-05C starts after PBG-05 and can run in parallel with the delivery branch.
- PBG-06 → PBG-07 prepares canonical delivery evidence.
- PBG-08 starts after PBG-05 and PBG-07, followed by PBG-09 and PBG-10.
- PBG-10 and its QA run daily. Its operational status uses the current Jakarta date.
- Files in `views_deploy_once/` are deployed when definitions change; they are
  not daily scheduled queries.

## Important source roles

- `IBU_NIFAS`, `epus_inc`, and `epus_pnc` provide supporting pregnancy or
  delivery evidence; they do not independently create a new pregnancy episode.
- `raw_data.epus_laporan_pelayanan_pasien_update` is a phone-enrichment fallback
  through a trusted maternal NIK. It does not create pregnancy membership.
- First-seen scope records the system where the final canonical pregnancy first
  became observable. It is different from the final pregnancy source combination.
