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
```

## Architecture

```
For each HTS revision (basic, rev_1, ..., rev_32, 2026_basic):
  JSON -> Parse Ch99 -> Parse Products -> Extract Policy Params -> Calculate Rates -> Snapshot
All snapshots -> rate_timeseries.rds
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
10. `10_weighted_etr.R`: Import-weighted effective tariff rates

**Key Configuration:**
- `config/policy_params.yaml`: All policy constants (country codes, authority ranges, 232 chapters, floor rates, 301 rates, etc.)
- `config/revision_dates.csv`: revision -> effective_date -> tpc_date mapping
- `config/scenarios.yaml`: Counterfactual scenario definitions

**Shared Infrastructure:**
- `RATE_SCHEMA` in helpers.R: Canonical column order for rate output
- `enforce_rate_schema()`: Ensures all rate dataframes have consistent columns
- `apply_stacking_rules()`: Single vectorized implementation of tariff stacking
- `classify_authority()`: Unified Ch99 authority classifier
- `load_policy_params()`: Reads config/policy_params.yaml, unpacks convenience fields

**Legacy (v1, config-driven):**
- `v1_run_daily.R`, `v1_ingest_hts.R` through `v1_write_outputs.R`
- `config/authority_mapping.yaml`, `config/country_rules.yaml`

## Stacking Rules

```r
# China (5700)
total = max(232, reciprocal) + fentanyl + 301

# Canada/Mexico (1220, 2010)
total = 232 + (reciprocal + fentanyl) * usmca_factor

# All Others
total = (232 > 0 ? 232 : reciprocal + fentanyl)
```

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
