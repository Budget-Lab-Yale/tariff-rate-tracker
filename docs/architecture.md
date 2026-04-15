# Code Architecture

This document maps the pipeline, the module structure, and the data flow for contributors.

## Source layout

```
src/
  00_build_timeseries.R      Orchestrator: loops over HTS revisions, builds interval-encoded panel
  01_scrape_revision_dates.R Discovers new HTS revisions from USITC API
  02_download_hts.R          Downloads HTS JSON archives to data/hts_archives/
  03_parse_chapter99.R       Extracts Chapter 99 entries (tariff programs) from JSON
  04_parse_products.R        Extracts product codes, base rates, footnotes from JSON
  05_parse_policy_params.R   Extracts IEEPA/fentanyl/232/122/USMCA rates from JSON
  06_calculate_rates.R       Core: 17-step rate calculation per revision
  07_validate_tpc.R          Optional TPC benchmark comparison
  08_weighted_etr.R          Weighted ETR outputs (requires import weights)
  09_daily_series.R          Daily aggregates from interval-encoded panel

  policy_params.R            YAML config loader: load_policy_params(), get_country_constants()
  revisions.R                Revision lifecycle: dates, JSON paths, release names
  stacking.R                 Mutual-exclusion stacking rules and authority decomposition
  rate_schema.R              Canonical rate columns, schema enforcement, authority classifier
  data_loaders.R             Resource file loaders (USMCA, MFN, metal, 232, annex, fentanyl)
  helpers.R                  Rate parsing, HTS utilities, concordance, expiry, point-in-time query
  logging.R                  Simple log-to-file wrapper

config/
  policy_params.yaml         Single source of truth for tariff logic parameters
  revision_dates.csv         HTS revision schedule and effective dates
  local_paths.yaml           User-specific file locations (gitignored)

resources/                   Committed lookup tables and product lists
tests/
  run_tests_daily_series.R   79 tests: daily series, expiry, decomposition, schema, annex
  test_rate_calculation.R    50 tests: extract_* functions, invariants, stacking, parsing
```

## Data flow

```
HTS JSON archives
       |
       v
  03_parse_chapter99  -->  ch99_data (Chapter 99 entries with rates/countries)
  04_parse_products   -->  products (HTS10 codes with base rates and footnotes)
  05_parse_policy_params --> ieepa_rates, fentanyl_rates, s232_rates, usmca
       |
       v
  06_calculate_rates  -->  rates (HTS10 x country, all authority columns)
       |                   Steps: IEEPA reciprocal -> fentanyl -> 232 base ->
       |                   232 derivatives -> 232 annex -> 301 -> 122 ->
       |                   MFN exemption -> USMCA -> stacking -> schema
       v
  rate_timeseries.rds (interval-encoded: valid_from / valid_until)
       |
       +--> 09_daily_series  -->  daily aggregates (overall, by country, by authority)
       +--> 08_weighted_etr  -->  weighted ETR outputs (with import weights)
```

## Module dependencies

`helpers.R` sources all five extracted modules for backward compatibility. Any file that does `source(here('src', 'helpers.R'))` gets the full function set. Files that only need specific functionality can source the modules directly:

- `policy_params.R` has no internal dependencies
- `revisions.R` depends on `policy_params.R` (for `parse_revision_id` used in path resolution)
- `stacking.R` has no internal dependencies
- `rate_schema.R` has no internal dependencies
- `data_loaders.R` depends on `policy_params.R` (for path resolution via `here`)

## How to add a new tariff authority

A new tariff authority (e.g., a Section 201 safeguard expansion) requires changes in three layers:

### 1. Extraction (`05_parse_policy_params.R`)

Write an `extract_section201_rates()` function (or extend the existing one) that parses the new Ch99 entries from the HTS JSON. Follow the pattern of `extract_section232_rates()`: filter ch99_data by code range, extract rates and country applicability, return a structured list.

### 2. Rate calculation (`06_calculate_rates.R`)

Add a numbered step inside `calculate_rates_for_revision()`. The existing steps are numbered 1-9 with substeps (4b, 6c, etc.). Your step should:
- Apply the rate to existing rows in `rates` (update the relevant `rate_*` column)
- Add new product-country pairs for products not yet in `rates` (use `add_blanket_pairs()`)
- Use `relationship = 'many-to-one'` on all lookup joins

### 3. Stacking (`stacking.R`)

If the new authority interacts with existing mutual-exclusion rules (e.g., stacks differently with Section 232), update `apply_stacking_rules()` and `compute_net_authority_contributions()`. Both call `compute_nonmetal_share()` for the shared metal-content logic.

### 4. Schema (`rate_schema.R`)

If you add a new `rate_*` column, add it to `RATE_SCHEMA` and the defaults in `enforce_rate_schema()`.

### 5. Tests

Add fixture-based tests to `tests/test_rate_calculation.R` for the new extraction function and any new stacking behavior.

## Test infrastructure

Tests use `stopifnot()` assertions with no external framework. Run:

```bash
Rscript tests/run_tests_daily_series.R       # 79 tests: daily series infrastructure
Rscript tests/test_rate_calculation.R         # 50 tests: rate engine, extraction, stacking
```

Both are CI-safe (synthetic fixtures only, no external data).
