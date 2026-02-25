# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

Tariff Rate Tracker - An R-based system for constructing statutory U.S. tariff rates at the HTS-10 x country level. Parses HTS JSON archives iteratively across all revisions to build a time series of tariff rates. All rates derived from HTS source data -- TPC benchmark data is for validation only.

## Key Commands

```bash
# Full backfill: process all 34 HTS revisions
Rscript src/00_build_timeseries.R

# Incremental: process only new revisions after rev_32
Rscript src/00_build_timeseries.R --start-from rev_32

# Automated incremental update (checks for new revisions)
Rscript src/update_pipeline.R

# Single-revision pipeline (quick check)
Rscript src/run_pipeline.R

# TPC validation across all 5 dates (saves to output/validation/)
Rscript test_tpc_comparison.R

# Quality report (saves to output/quality/)
Rscript src/quality_report.R

# Diagnostics (saves to output/diagnostics/)
Rscript src/09_diagnostics.R

# Daily rate series (saves to output/daily/)
Rscript src/11_daily_series.R

# Import-weighted ETRs (requires built timeseries; saves to output/etr/)
Rscript src/10_weighted_etr.R

# Parse US Note 301 product lists from Chapter 99 PDF
Rscript src/12_scrape_us_notes.R
Rscript src/12_scrape_us_notes.R --dry-run    # Report without writing
```

## Architecture

```
For each HTS revision (basic, rev_1, ..., rev_32, 2026_basic):
  JSON -> Parse Ch99 -> Parse Products -> Extract Policy Params -> Calculate Rates -> Snapshot
All snapshots -> rate_timeseries.rds (with valid_from/valid_until intervals)
rate_timeseries.rds -> daily aggregates (11_daily_series.R)
rate_timeseries.rds -> import-weighted ETRs (10_weighted_etr.R via get_rates_at_date())
```

**Active Pipeline (v2 timeseries):**
- `helpers.R`: Shared utilities (rate parsing, HTS codes, schema enforcement, stacking rules, policy params loader)
- `logging.R`: Structured logging module (init_logging, log_info/warn/error/debug)
- `00_build_timeseries.R`: Multi-revision orchestrator with error recovery
- `run_pipeline.R`: Single-revision orchestrator
- `update_pipeline.R`: Automated incremental update (detects new revisions)
- `quality_report.R`: Schema checks, per-revision quality, anomaly detection

1. `01_scrape_revision_dates.R`: Scrape USITC for revision effective dates
2. `02_download_hts.R`: Download missing HTS JSON archives from USITC
3. `03_parse_chapter99.R`: Extract Ch99 entries (rates, authority, countries)
4. `04_parse_products.R`: Extract product lines (base rates, footnote refs)
5. `05_parse_policy_params.R`: Extract IEEPA, fentanyl, 232, USMCA from JSON
6. `06_calculate_rates.R`: Join products to authorities, apply stacking
7. `07_validate_tpc.R`: TPC benchmark comparison
8. `08_apply_scenarios.R`: Counterfactual scenarios (zero out authorities)
9. `09_diagnostics.R`: Debugging and validation utilities
10. `10_weighted_etr.R`: Import-weighted effective tariff rates (uses timeseries via `get_rates_at_date()`)
11. `11_daily_series.R`: Daily rate series, point-in-time queries, daily aggregates
12. `12_scrape_us_notes.R`: Parse US Note 20/21/31 product lists from Chapter 99 PDF

**Key Configuration:**
- `config/policy_params.yaml`: All policy constants (country codes, authority ranges, 232 chapters, floor rates, 301 rates, etc.)
- `config/revision_dates.csv`: revision -> effective_date -> tpc_date mapping
- `config/scenarios.yaml`: Counterfactual scenario definitions
- `docs/active_hts_changes.md`: Federal Register changes not yet in HTS JSON (manual overrides)

**Shared Infrastructure:**
- `RATE_SCHEMA` in helpers.R: Canonical column order for rate output (includes `metal_share`, `valid_from`/`valid_until`)
- `enforce_rate_schema()`: Ensures all rate dataframes have consistent columns
- `apply_stacking_rules()`: Single vectorized implementation of tariff stacking
- `classify_authority()`: Unified Ch99 authority classifier
- `load_policy_params()`: Reads config/policy_params.yaml, unpacks convenience fields
- `load_232_derivative_products()`: Reads derivative product list from resources/
- `load_metal_content()`: Computes per-product metal shares (flat/CBO/BEA methods)
- `parse_revision_id()`: Extracts year + revision type from any revision ID (e.g., '2026_rev_3' -> year=2026, rev='rev_3')
- `get_rates_at_date(ts, date)`: Point-in-time rate query (in 11_daily_series.R) — preferred way to get rates at any date

**Legacy (v1, config-driven):**
- `v1_run_daily.R`, `v1_ingest_hts.R` through `v1_write_outputs.R`
- `config/authority_mapping.yaml`, `config/country_rules.yaml`

## Stacking Rules

Mutual exclusion between 232 and IEEPA reciprocal (aligned with Tariff-ETRs):

```r
# China with 232:    232 + recip*nonmetal + fentanyl + 301 + s122*nonmetal + other
# China without 232: reciprocal + fentanyl + 301 + s122 + other  (10% recip + 10% fent post-Geneva)
# Others with 232:   232 + (recip + fentanyl + s122)*nonmetal + other
# Others without 232: reciprocal + fentanyl + s122 + other

# USMCA (CA/MX): binary exemption — eligible products get IEEPA/fentanyl zeroed out
```

Key: 232 takes precedence over IEEPA reciprocal. For base 232 products (metal_share = 1.0), nonmetal_share = 0, preserving full mutual exclusion. For derivative 232 products (metal_share < 1.0), non-232 authorities apply to the non-metal portion. China exception: fentanyl stacks at full value (separate IEEPA authority) regardless of 232 status.

## Section 232 Coverage

- Steel: chapters 72-73 (blanket via 9903.80-84)
- Aluminum: chapter 76 (blanket via 9903.85)
- Autos: heading 8703 + light trucks (blanket via 9903.94, config prefixes)
- Copper: headings 7406-7419 (config prefixes)
- Derivatives: ~130 aluminum-containing articles outside ch76 (blanket via 9903.85.04/.07/.08)
  - Product list in `resources/s232_derivative_products.csv` (sourced from Tariff-ETRs config)
  - Tariff applies only to the metal content portion of customs value
  - Metal content share configurable: flat (default 50%), CBO (product-level buckets), BEA (future)
  - Config: `metal_content` block in `config/policy_params.yaml`
  - CBO files in `resources/cbo/` (alst_deriv_h.csv, alst_deriv_l.csv, copper.csv)
  - Product list should be re-derived from US Note 19 when USITC API provides US Notes data

## Section 301 Product Coverage

~10,400+ HTS8 product codes covered by Section 301 tariffs on China (Lists 1-4A + Biden modifications).
List in `resources/s301_product_lists.csv`. Two sources:
1. USITC "China Tariffs" reference document (hts.usitc.gov, ~10,400 codes)
2. US Notes 20/21/31 from Chapter 99 PDF (`12_scrape_us_notes.R`, ~additional codes from Note text)

Applied as blanket tariff for China (country 5700) in `06_calculate_rates.R` step 3b, mirroring the
Section 232 blanket pattern.

Known limitation: Some 9903.89.xx exclusions reference US Note product lists (not footnotes) and are
not captured — excluded products may incorrectly receive the base 301 rate.

## IEEPA Fentanyl Product Carve-outs

Fentanyl rates (9903.01.01-24) have product-specific carve-outs with lower rates:
- 9903.01.13 (CA): Energy, critical minerals → +10% (vs general +35%)
- 9903.01.15 (CA): Potash → +10% (vs general +35%)
- 9903.01.05 (MX): Potash → +10% (vs general +25%)

Product lists in `resources/fentanyl_carveout_products.csv` (308 HTS8 prefixes, sourced from Tariff-ETRs).
Applied in `06_calculate_rates.R` step 3: products matching carve-out HTS8 get the carve-out rate;
all others get the general blanket rate. `extract_ieepa_fentanyl_rates()` returns all entries with
`entry_type` column ('general' vs 'carveout').

## IEEPA Product Exemptions

~1,087 products exempt from IEEPA reciprocal (Annex A / US Note 2 subdivision (v)(iii)).
List in `resources/ieepa_exempt_products.csv`. Not parseable from HTS JSON (US Notes text unavailable via API).

## Census Country Codes

Key codes: 5700 (China), 1220 (Canada), 2010 (Mexico), 4120 (UK), 5880 (Japan), 5820 (Hong Kong)

Full list: `resources/census_codes.csv`

## Style Guidelines

- Single quotes for strings
- Tidyverse-first (dplyr/tidyr over base R)
- Never use `na.rm = TRUE` - missing values indicate bugs
- Use `%>%` pipes
- Explicit `return()` at function end
- 2-space indentation
- Main orchestrator files use `00_` prefix (never "master")

## Related Repositories

- [Tariff-Model](../Tariff-Model) - Economic impact modeling
- [Tariff-ETRs](../Tariff-ETRs) - ETR calculations
