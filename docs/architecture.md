# Code Architecture

This document maps the pipeline, the module structure, and the data flow for
contributors and reviewers. Every file in `src/` is listed below with a
one-line role.

## The three layers

The rate engine is organized as three layers. Read them in this order:

1. **Parsers** (`03`–`05`) — pull raw facts out of the USITC HTS JSON: product
   codes and base rates, Chapter 99 program entries, and the per-authority
   policy parameters (IEEPA, fentanyl, §232, §122, USMCA).
2. **Adapter** (`authority_adapter.R`) — re-packages those parser outputs into a
   single uniform datatype, the **`AuthoritySpec`** (`authority_spec.R`). One
   spec per authority, same shape for all. This is the normalization seam.
3. **Calculator** (`06_calculate_rates.R`) — reads the spec set (scope, gates,
   rates) plus the legacy parser payloads and computes the `HTS-10 × country`
   rate panel, applying stacking rules (`stacking.R`) and the canonical output
   schema (`rate_schema.R`).

The adapter sits *downstream* of the parsers and does not re-implement them —
there is no duplicated calculation logic between the layers. Counterfactual
scenarios are authored as config overlays (`config/scenarios/<name>/overlay.yaml`,
deep-merged into the policy params), so the spec the calculator sees already
reflects the scenario.

## Pipeline stages (numbered)

```
src/
  00_build_timeseries.R      Orchestrator: loops HTS revisions, writes per-revision snapshots,
                             then runs downstream (daily series, quality report). Entry point.
  01_scrape_revision_dates.R Discovers new HTS revisions from the USITC API.
  02_download_hts.R          Downloads HTS JSON archives to data/hts_archives/.
  03_parse_chapter99.R       Parses Chapter 99 program entries (rate, country, authority class).
  04_parse_products.R        Parses HTS10 products (base MFN rate, Ch99 footnote refs).
  05_parse_policy_params.R   Extracts IEEPA / fentanyl / §232 / USMCA params from the JSON.
  06_calculate_rates.R       Core engine: calculate_rates_for_revision() — the stacked rate panel.
  07_validate_tpc.R          Optional TPC benchmark comparison (no-op without TPC data).
  revision_snapshot.R        Shared per-revision build unit used by baseline and scenarios.
  09_daily_series.R          Daily aggregates + weighted ETR + alternative-series runner.
```

## Model layer (the spec + calculation support)

```
  authority_spec.R     The AuthoritySpec datatype + validation (docs/authority_spec.md).
  authority_adapter.R  build_authority_specs(): parser outputs -> uniform spec set.
  stacking.R           Mutual-exclusion stacking rules + authority decomposition.
  rate_schema.R        Canonical rate_* columns, schema enforcement, authority classifier.
  scenario_inputs.R    Removes disabled-authority inputs before scenario calculation.
  policy_params.R      YAML config loader, country constants, scenario overlay deep-merge.
  data_loaders.R       Resource-file loaders (232 derivatives/annex, USMCA, metal, fentanyl).
  revisions.R          Revision-id parsing, JSON path resolution, archive/release naming.
  scenario_registry.R  Registry of config/scenarios/<name>/ (alternatives + counterfactuals).
  timeline.R           Schedule-boundary splitter.  STATUS: PARTIALLY WIRED (see note below).
```

## I/O and output

```
  write_output.R        write_build_output(): CSV + parquet, routed through output_paths.R.
  output_paths.R        Single source of truth for the output directory layout (actual/ + scenarios/).
  publish_git.R         --publish-git: dated public outputs into release/.
  build_import_weights.R Census import weights (HS10 x country x GTAP) for weighted ETRs.
```

## Core / infrastructure

```
  helpers.R            Facade: sources policy_params, revisions, stacking,
                       timeline, rate_schema, data_loaders, output_paths, scenario_registry,
                       and defines low-level HTS/rate utilities. Sourcing it grants the full set.
  logging.R            init_logging() + log_info/warn/error.
  parallel.R           Parallel build scaffolding (--parallel / --alt-workers).
  parity.R             Tolerance comparator used by the parity-gated refactor harness.
  dataweb_parser.R     Pure parser for USITC DataWeb API responses (unit-tested).
  build_config.R       load_build_config(): the single YAML input for the array build flow.
  preflight.R          Environment/readiness checker (packages, config, resources). Entry point.
  install_dependencies.R Package installer. Entry point.
  quality_report.R     Post-build schema/anomaly diagnostics. Entry point.
```

## Manual tools (run by hand; not part of a routine build)

These generate committed resources or configs and are run when their inputs
change, not on every build. (Candidate for a future `tools/` directory.)

```
  scrape_us_notes.R           Parses Ch99 PDF US Notes -> resources/*.csv (annex, floor, copper, derivatives).
  calibrate_s301_exclusions.R Calibrates §301 exclusion claim shares from realized collections.
  build_hts_concordance.R     Heuristic HTS10 cross-revision concordance.
  expand_ieepa_exempt.R       Expands the IEEPA exempt-product list (HTS8->10, Ch98/97/49).
  revision_changelog.R        Generates docs/revision_changelog.md from Ch99 diffs.
  generate_etrs_config.R      Exports tracker rates as Tariff-ETRs-compatible config.
  download_usmca_dataweb.R    Downloads USMCA utilization shares from DataWeb (--refresh-usmca).
  build_usmca_scenarios.R     Builds the USMCA-utilization scenario snapshots.
```

## Experimental / not wired

```
  load_adcvd_layer.R   AD/CVD statutory rung — scaffold only; NOT sourced by 06 (docs/adcvd_layer_design.md).
```

> Resolved one-off investigations (China-gap, ETR comparisons, EU-auto deal,
> etc.) live under `scripts/archive/`, not `src/`.

## Data flow

```
HTS JSON archives
       |
       v
  03_parse_chapter99  -->  ch99_data
  04_parse_products   -->  products
  05_parse_policy_params --> ieepa_rates, fentanyl_rates, s232_rates, usmca
       |
       v
  revision_snapshot   -->  one shared baseline/scenario build route
       |
       v
  authority_adapter   -->  authority_spec_set  (uniform per-authority specs)
       |
       v
  06_calculate_rates  -->  snapshot_<revision>.rds (HTS10 x country, all authority columns)
       |                   IEEPA reciprocal -> fentanyl -> 232 base -> 232 derivatives ->
       |                   232 annex -> 301 -> 122 -> MFN exemption -> USMCA -> stacking -> schema
       |
       +--> 09_daily_series   -->  daily aggregates (overall, by country, by authority) + weighted ETR
       +--> quality_report    -->  schema/revision/anomaly diagnostics
       +--> publish (array flow / --publish-git) --> dated vintage / release/
```

## Module dependencies

`helpers.R` sources the nine extracted modules listed under Core, so any file
that does `source(here('src', 'core', 'helpers.R'))` gets the full function set. Files
that only need a slice can source a module directly:

- `policy_params.R`, `stacking.R`, `rate_schema.R`, `output_paths.R`,
  `scenario_registry.R`, `timeline.R` — no internal dependencies.
- `revisions.R`, `data_loaders.R` — depend on `policy_params.R`.
- `authority_adapter.R` — depends on `authority_spec.R` and `policy_params.R`.

## Core mechanisms

Reviewers will notice two places worth understanding:

1. **Schedule boundaries (settled).** `timeline.R` is the single source of
   interval edges. The build mints synthetic snapshots through
   `discover_boundaries()` / `build_boundary_mints()` (called from `00`), using
   the canonical first-day-of-new-state convention (`E -> E+1` for expiries).
   Daily series and point queries consume those intervals directly. The Swiss
   snapshot fields preserve the underlying reciprocal rate, temporary floor,
   and dates, so its expiry recomputes correctly without a downstream editor.
   `test_mint_equals_zeroing.R`, `test_boundary_discovery.R`, and
   `test_timeline_realdata.R` pin the transition and geometry.

2. **Rate-table identity (settled).** `build_rate_grid()` creates the complete
   product × country table once at the start of calculation. Every authority
   mutates columns on that table, and the calculator asserts the natural key and
   row count before return. There are no per-program row builders or alternate
   stacking representations.

## How to add a new tariff authority

1. **Extract** (`05_parse_policy_params.R`): write `extract_section201_rates()`
   following `extract_section232_rates()` — filter ch99 by code range, return
   rates + country applicability.
2. **Adapt** (`authority_adapter.R`): map the new rates into an `AuthoritySpec`.
3. **Calculate** (`06_calculate_rates.R`): add a numbered step in
   `calculate_rates_for_revision()` that mutates the authority column on the
   existing canonical product-country table. Policy programs must not add rows.
4. **Stack** (`stacking.R`): if it interacts with mutual-exclusion rules, update
   `apply_stacking_rules()` and `compute_net_authority_contributions()`.
5. **Schema** (`rate_schema.R`): add any new `rate_*` column to `RATE_SCHEMA`
   and the defaults in `enforce_rate_schema()`.
6. **Test** (`tests/test_rate_calculation.R`): add fixture-based tests.

## Test infrastructure

Tests use `stopifnot()` assertions and synthetic fixtures. The CI smoke job
(`.github/workflows/ci.yml`) discovers every test file and runs each in an
isolated R process, after opting out of weighted outputs:

```bash
Rscript src/preflight.R
Rscript tests/run_all_tests.R
```

Optional-package tests are reported as skipped with the missing package name;
tests that pass while skipping artifact-dependent assertions are marked
`PASS*` and listed in the summary. They are never silently omitted from
discovery. Pass `--list` to print the exact discovered file set.

Refactors that must not change numbers (e.g. the in-progress migrations above)
are gated by the parity harness: `parity.R` + `scripts/submit_plank*` /
`scripts/run_parity_check.R` compare full-build outputs against a golden
reference.
