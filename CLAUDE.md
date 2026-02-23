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

# Single-revision pipeline (quick check)
Rscript src/run_pipeline.R

# TPC validation across all 5 dates
Rscript test_tpc_comparison.R
```

## Architecture

```
For each HTS revision (basic, rev_1, ..., rev_32, 2026_basic):
  JSON -> Parse Ch99 -> Parse Products -> Extract Policy Params -> Calculate Rates -> Snapshot
All snapshots -> rate_timeseries.rds
```

**Active Pipeline (v2 timeseries):**
1. `00_build_timeseries.R`: Main orchestrator (iterates revisions)
2. `01_parse_chapter99.R`: Extract Ch99 entries (rates, authority, countries)
3. `02_parse_products.R`: Extract product lines (base rates, footnote refs)
4. `03_calculate_rates.R`: Join products to authorities, apply stacking
5. `04_validate_tpc.R`: TPC benchmark comparison
6. `05_parse_policy_params.R`: Extract IEEPA, fentanyl, 232, USMCA from JSON
7. `06_scrape_revision_dates.R`: Revision date metadata
8. `07_apply_scenarios.R`: Counterfactual scenarios (zero out authorities)
9. `08_diagnostics.R`: Debugging and validation utilities

**Key Configuration:**
- `config/revision_dates.csv`: revision -> effective_date -> tpc_date mapping
- `config/scenarios.yaml`: Counterfactual scenario definitions

**Legacy (v1, config-driven):**
- `run_daily.R`, `01_ingest_hts.R` through `05_write_outputs.R`
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
