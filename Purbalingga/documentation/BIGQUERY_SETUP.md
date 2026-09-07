# BigQuery Scheduled Query setup

Create one Scheduled Query for each file under `scheduled/`, in numeric order.

Important:
- PBG-01 waits for SIGIZI ingestion.
- PBG-03 waits for ePUS ingestion.
- PBG-06 waits for all delivery feeds used by the pipeline.
- PBG-05 must run after both PBG-02 and PBG-04.
- PBG-08 must run only after both PBG-05 and PBG-07.
- PBG-10 runs daily.
- Run the QA query after PBG-10.

Do not schedule the `views_deploy_once/` files daily.

The SQL uses `CREATE OR REPLACE TABLE`, so no destination-table setting is needed in the Scheduled Query configuration.
