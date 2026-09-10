# BigQuery Scheduled Query setup

Create one Scheduled Query for each file under `scheduled/`, in numeric order.

Important:
- PBG-01 waits for SIGIZI ingestion.
- PBG-03 waits for ePUS ingestion.
- PBG-06 waits for all delivery feeds used by the pipeline.
- PBG-05 must run after both PBG-02 and PBG-04.
- PBG-05C pregnancy first-seen must run after PBG-05. It can run in parallel
  with the delivery branch and must finish before first-seen reporting is used.
- PBG-08 must run only after both PBG-05 and PBG-07.
- PBG-10 runs daily.
- Run the QA query after PBG-10.

Do not schedule the `views_deploy_once/` files daily.

Deploy `views_deploy_once/15_v_pregnancy_first_seen.sql` as a separate job after
the first successful PBG-05C run. BigQuery temporary parsing UDFs exist only in
the PBG-05C table-building script, so the permanent views are intentionally
created separately.

The SQL uses `CREATE OR REPLACE TABLE`, so no destination-table setting is needed in the Scheduled Query configuration.

After deployment, run `utilities/12_validate_pregnancy_first_seen.sql` and
review every failed invariant plus all fallback/unresolved result rows.
