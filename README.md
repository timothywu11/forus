# Forus DS Take-Home: Part 1 (GTM specialty analysis)

## Run it

1. Open `part1_gtm.ipynb` in Google Colab.
2. In the **Configuration** cell, set:
   - `BILLING_PROJECT`: a GCP project you can run queries in
   - `TARGET`: `<that project>.forus_analytics` (created if missing)
   - `REPO_URL`: this repo's git URL (or upload the folder and set `REPO_DIR`)
   - `REBUILD = True` the first time in a new `TARGET`
3. Run all. You need read access to `tandem-interview.takehome_wu_timothy`.
   A full rebuild scans about 4 GB; after that every query hits small mart tables.

## Change a scenario

Edit the **Assumptions** cell (or pass overrides to any `forus_gtm` function) and
re-run from there. No SQL changes are needed: SQL produces volumes, and every price,
minute and cost is applied in `forus_gtm.py`.

```python
import forus_gtm as fg
fg.specialty_scorecard(segments, {**fg.DEFAULT_ASSUMPTIONS, "ops_hourly_cost": 60})
fg.sensitivity(segments, "capture_rate", [0.1, 0.25, 0.5])
```

To change which drugs count as the $200 tier, edit `biologic_ref` in
`sql/01_build_analytics_layer.sql` and rebuild.

## Layout

| File | What it does |
|---|---|
| `sql/00_data_checks.sql` | Source data checks, with the expected values in comments |
| `sql/01_build_analytics_layer.sql` | `biologic_ref`, `claims_enriched` (cleaned claims, same grain as source); documents every data caveat |
| `sql/02_npi_summary.sql` | `npi_summary`: one row per provider |
| `sql/03_specialty_segments.sql` | `specialty_segments` and `sales_targets` views |
| `forus_gtm.py` | Economics: unit economics, scorecard, capture curve, sensitivity, target ranking |
| `part1_gtm.ipynb` | Runs everything end to end, with validation asserts |

## Key caveats

- Claims volumes are **patient-drug pairs**, not scripts or unique patients.
- 7,919 providers (~5% of volume) have no NPPES specialty and are excluded from the comparison.
- `affiliation_npi_count` counts every provider at an institution, not only these specialties.
- The full list of source issues and how each is handled is in the header of `sql/01`.
