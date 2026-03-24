# Build Guide

This guide covers first-run setup, required and optional inputs, build modes, and expected outputs.

## System requirements

- **R 4.3+** with packages listed in `src/install_dependencies.R`
- **RAM**: The full pipeline (`--full`) expands a product × country matrix of roughly 19,000 products × 240 countries during rate calculation. **32 GB RAM is recommended.** Machines with 16 GB may run out of memory during the IEEPA broadcasting step in `06_calculate_rates.R`. If you are memory-constrained, you can build individual revisions rather than running `--full`, since each revision is processed independently.
- **Disk**: The `data/` directory (HTS JSON archives + processed snapshots) requires approximately 2 GB.
- **OS**: Tested on Windows 10/11, macOS, and Linux. No platform-specific dependencies.

## Build modes

The repo is designed to run in progressively richer modes depending on what local data you have.

| Mode | Requires | Produces |
|---|---|---|
| `core` | repo resources, config files, HTS JSON archives, required R packages | tariff timeseries, unweighted daily outputs, quality report |
| `core_plus_weights` | core + import weights in `config/local_paths.yaml` | core outputs + weighted daily fields + weighted ETR outputs |
| `compare_tpc` | core + TPC benchmark CSV | comparison outputs against TPC |
| `compare_etrs` | core + Tariff-ETRs repo path | standalone script (`src/compare_etrs.R`); wrapper in `run_comparisons.R` not yet complete |

The core series is the production dataset. Comparison inputs are optional.

## First-run checklist

### 1. Verify the environment

```bash
Rscript src/preflight.R
```

This checks packages, config files, committed resources, HTS JSON availability, and optional local benchmark paths.

### 2. Install packages

```bash
Rscript src/install_dependencies.R
Rscript src/install_dependencies.R --all
```

Required packages:

- `tidyverse`
- `jsonlite`
- `yaml`
- `here`

Optional packages:

- `pdftools`
- `digest`
- `arrow`
- `httr`

### 3. Download HTS JSON archives

```bash
Rscript src/02_download_hts.R --dry-run
Rscript src/02_download_hts.R
```

### 4. Configure optional local paths

If you want weighted outputs or benchmark comparisons:

```bash
copy config\\local_paths.yaml.example config\\local_paths.yaml
```

Set whichever paths you have:

- `import_weights`
- `tpc_benchmark`
- `tariff_etrs_repo`

The core build does not require this file.

### 5. Run the build

```bash
Rscript src/00_build_timeseries.R --full --core-only
```

Useful variants:

```bash
Rscript src/00_build_timeseries.R
Rscript src/00_build_timeseries.R --full
Rscript src/00_build_timeseries.R --build-only
Rscript src/00_build_timeseries.R --with-alternatives
Rscript src/00_build_timeseries.R --full --use-policy-dates
```

The `--use-policy-dates` flag uses legal policy effective dates instead of HTS revision dates where they differ. This affects 7 revisions (e.g., SCOTUS ruling effective Feb 20 vs. HTS revision Feb 24). See [docs/policy_timing.md](policy_timing.md) for the full list and legal sources. Note: some revisions bundle multiple policy changes with different timing gaps; the flag shifts the entire revision date, which is an approximation.

## Input inventory

### Required for the core build

| Input | Path | Status | Role | Regeneration |
|---|---|---|---|---|
| HTS JSON archives | `data/hts_archives/*.json` | auto-download | official tariff schedule by revision | `src/02_download_hts.R` |
| Policy config | `config/policy_params.yaml` | committed | tariff logic, dates, and assumptions | manual update when policy changes |
| Revision schedule | `config/revision_dates.csv` | committed | HTS effective dates and benchmark alignment | `src/01_scrape_revision_dates.R` discovers new revisions via USITC API; placeholder dates require manual review |
| Census country codes | `resources/census_codes.csv` | committed | country dimension | manual refresh |
| Country-partner mapping | `resources/country_partner_mapping.csv` | committed | partner aggregates for reporting | manual refresh |
| Section 301 product list | `resources/s301_product_lists.csv` | committed | blanket 301 coverage | `src/scrape_us_notes.R` (validates anchor coverage; refuses partial writes) |
| IEEPA exempt products | `resources/ieepa_exempt_products.csv` | committed | reciprocal exemptions | regenerate when exemption logic changes |
| Section 232 derivative products | `resources/s232_derivative_products.csv` | committed | derivative 232 coverage | manual / documented refresh |
| Copper 232 product list | `resources/s232_copper_products.csv` | committed | copper 232 coverage | `src/scrape_us_notes.R --copper` (validates >= 60 codes; refuses reduced overwrites) |
| Auto and MHD product lists | `resources/s232_auto_parts.txt`, `resources/s232_mhd_parts.txt` | committed | 232 auto and MHD coverage | manual refresh from official notes |
| Fentanyl carve-outs | `resources/fentanyl_carveout_products.csv` | committed | reduced fentanyl rates for carve-out products | manual / documented refresh |
| USMCA product shares | `resources/usmca_product_shares_2024.csv`, `resources/usmca_product_shares_2025.csv` | committed | product-level USMCA utilization | `src/download_usmca_dataweb.R` |
| MFN exemption shares | `resources/mfn_exemption_shares.csv` | committed | effective MFN base-rate adjustment | regenerate from source trade data if methodology changes |
| Metal content shares | `resources/metal_content_shares_bea_hs10.csv` | committed | derivative 232 metal-share estimation | regenerate from BEA workflow if needed |
| Floor exemptions | `resources/floor_exempt_products.csv` plus revision-specific `data/us_notes/floor_exempt_{revision}.csv` | committed plus auto-scrape | floor-country exemptions | `src/scrape_us_notes.R --floor-exemptions` (validates anchor coverage; refuses partial overwrites) |
| Section 122 exemptions | `resources/s122_exempt_products.csv` | committed | Annex II exemptions | manual refresh when authority changes |

### Optional inputs

| Input | Path | Status | Role |
|---|---|---|---|
| Import weights | local path via `config/local_paths.yaml` | private/local | weighted daily outputs and weighted ETRs |
| TPC benchmark | local path via `config/local_paths.yaml` | private/local | validation only |
| Tariff-ETRs repo | local path via `config/local_paths.yaml` | optional/local | comparison only |
| Chapter 99 PDFs | `data/us_notes/*.pdf` | auto-download via `scrape_us_notes.R`; hash-checked by `01_scrape_revision_dates.R` | regenerate resource files from US Notes |

## What runs without what

| Scenario | Timeseries | Daily aggregates | Weighted ETR | TPC comparison |
|---|---|---|---|---|
| Core only | Yes | Yes | No | No |
| Core + weights | Yes | Yes | Yes | No |
| Core + TPC | Yes | Yes | No | Yes |
| Core + weights + TPC | Yes | Yes | Yes | Yes |

## Expected outputs

### Core outputs

| Path | Description |
|---|---|
| `data/timeseries/rate_timeseries.rds` | interval-encoded product-country tariff panel |
| `data/timeseries/snapshot_*.rds` | per-revision rate snapshots |
| `data/timeseries/delta_*.rds` | revision-to-revision diffs |
| `output/daily/daily_overall.csv` | daily aggregate mean and weighted ETR series |
| `output/daily/daily_by_country.csv` | daily country-level aggregate rates |
| `output/daily/daily_by_authority.csv` | daily authority decomposition |
| `output/quality/` | build diagnostics and quality checks |

### Optional outputs

| Path | Description |
|---|---|
| `output/etr/` | weighted ETR tables and plots |
| `output/comparisons/` | benchmark comparison artifacts |
| `output/alternative/` | sensitivity variants |

## Comparison workflows

TPC and Tariff-ETRs are comparison tools, not production inputs.

```bash
Rscript src/run_comparisons.R
Rscript src/run_comparisons.R --tpc
Rscript src/run_comparisons.R --etr
```

`--etrs` is currently a placeholder in the wrapper. For Tariff-ETRs comparison, run `src/compare_etrs.R` directly (requires `tariff_etrs_repo` in `config/local_paths.yaml`).

## Updating when a new HTS revision is published

1. Run `Rscript src/01_scrape_revision_dates.R` or update `config/revision_dates.csv`.
2. Download the new JSON with `src/02_download_hts.R`.
3. If the Chapter 99 PDF changed, regenerate affected resource files.
4. Re-run the build, usually without `--full`.

## Troubleshooting

- If `preflight.R` reports missing packages, run `src/install_dependencies.R --all`.
- If weighted outputs are skipped, check `config/local_paths.yaml`.
- If benchmark comparisons are skipped, confirm the configured TPC path exists.
- If no HTS JSON archives are found, run `src/02_download_hts.R`.

## Querying built data

Point-in-time queries:

```r
source('src/helpers.R')
ts <- readRDS('data/timeseries/rate_timeseries.rds')
snapshot <- get_rates_at_date(ts, as.Date('2026-06-15'))
```

Filtered daily extracts:

```r
source('src/helpers.R')
source('src/09_daily_series.R')
ts <- readRDS('data/timeseries/rate_timeseries.rds')
pp <- load_policy_params()

result <- export_daily_slice(
  ts,
  date_range = c('2026-06-01', '2026-06-30'),
  countries = c('5700'),
  products = c('8471'),
  policy_params = pp
)
```
