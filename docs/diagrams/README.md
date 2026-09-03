# Source-group diagrams

The [workflow overview](../workflow.md) includes an editable Mermaid diagram. The SVG diagrams are zoomable companions; the Word guide uses the PNG panels.

| Diagram | Purpose |
|---|---|
| `raw_sources_to_reporting` | Full path from separate SIGIZI, EPUS, SIMRS, Kobo and facility groups to reporting |
| `pregnancy_sources` | Raw SIGIZI/EPUS inputs, cleaning views and prepared sources |
| `sigizi_sources`, `epus_sources` | Separate Word panels for readable source-family detail |
| `sigizi_deletion_exclusion` | Deletion registry, pregnancy-specific exclusion, retained sources and excluded-row audit |
| `simrs_facility_sources` | Hospital and external facility-report inputs |
| `kobo_sources` | INC submissions, adjudication and neonatal records |
| `other_sources` | Combined SIMRS/Kobo/facility detail for screen viewing |
| `core_reporting` | Pregnancy/evidence inputs through matching and reporting |

Grey boxes are raw inputs, blue boxes are views, green boxes are stored tables, and amber boxes group processing steps. A dashed facility edge identifies an external boundary; it does not assert a verified raw-table dependency. Diagram groups omit some intermediate tables, maps and audit reads. See the guide for the expanded preparation path and exact reporting dependencies.

## Rebuild

Use Python 3 and Node.js with `@viz-js/viz` and `sharp` available:

```bash
python docs/diagrams/build_diagrams.py
node docs/diagrams/render_diagrams.cjs
```

The Python source generates editable `.dot` files. The Node renderer creates `.svg` and `.png` companions. Rendering reads no patient data, connects to no database and does not schedule or run pipeline SQL. Keep the Mermaid overview in `workflow.md` consistent when changing a dependency.
