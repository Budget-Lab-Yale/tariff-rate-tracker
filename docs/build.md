# Build Guide

This guide covers first-run setup, required and optional inputs, build modes, and expected outputs.

## System requirements

- **R 4.3+** with packages listed in `tools/install_dependencies.R`
- **RAM**: The full pipeline (`--full`) expands a product × country matrix of roughly 19,000 products × 240 countries during rate calculation. **32 GB RAM is recommended.** Machines with 16 GB may run out of memory during the IEEPA broadcasting step in `06_calculate_rates.R`. If you are memory-constrained, you can build individual revisions rather than running `--full`, since each revision is processed independently.
- **Disk**: The `data/` directory (HTS JSON archives + processed snapshots) requires approximately 2 GB.
- **OS**: Tested on Windows 10/11, macOS, and Linux. No platform-specific dependencies.

## Build modes

The repo is designed to run in progressively richer modes depending on what local data you have.

| Mode | Requires | Produces |
|---|---|---|
| `core_plus_weights` (default) | core + import weights at `data/weights/hs10_by_country_gtap_<year>_con.rds` (or path set in `config/local_paths.yaml`) | per-revision rate snapshots + weighted daily fields + quality report |
| `core` (opt-in via `--unweighted` or `weight_mode: unweighted`) | repo resources, config files, HTS JSON archives, required R packages | per-revision rate snapshots, unweighted daily outputs, quality report |
| `compare_tpc` | core + TPC benchmark CSV | comparison outputs against TPC |
| `compare_etrs` | core + Tariff-ETRs repo path | standalone script (`src/compare_etrs.R`); wrapper in `run_comparisons.R` not yet complete |
| `generate_etrs_config` | core (built timeseries) | ETRs-compatible config: `statutory_rates.csv.gz` + `other_params.yaml` per revision date |

The core series is the production dataset. Comparison inputs are optional.

> **Weights are required by default and auto-built when missing.** If neither `config/local_paths.yaml:import_weights` is set nor a file is found at `data/weights/hs10_by_country_gtap_<year>_con.rds`, `00_build_timeseries.R` invokes `src/io/build_import_weights.R` as a pre-run step (~15-20 min one-time download from the Census Bureau). Skip with `--unweighted` or `weight_mode: unweighted`.

## First-run checklist

### 1. Install packages

```bash
Rscript tools/install_dependencies.R
Rscript tools/install_dependencies.R --all
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

### 2. Download HTS JSON archives

```bash
Rscript src/pipeline/02_download_hts.R --dry-run
Rscript src/pipeline/02_download_hts.R
```

### 3. Import weights — automatic on first build

Weighted outputs are required by default, but you don't need to fetch them
manually. The first `Rscript src/pipeline/00_build_timeseries.R` invocation runs a
pre-run step that checks for `data/weights/hs10_by_country_gtap_<year>_con.rds`
and, if missing, invokes `src/io/build_import_weights.R` to fetch and parse
Census Bureau monthly imports (~15-20 min one-time). Subsequent builds find
the cached file via auto-detect and skip this step.

If you want to build the file ahead of time:

```bash
Rscript src/io/build_import_weights.R --year 2024
```

If you do not need weighted outputs, opt out:

```bash
copy config\\local_paths.yaml.example config\\local_paths.yaml
# then edit local_paths.yaml and set: weight_mode: unweighted
```

Or pass `--unweighted` to a single build invocation.

### 3b. Configure other optional local paths

For TPC validation or Tariff-ETRs comparison, create `config/local_paths.yaml`
from the example and set whichever paths you have:

```bash
copy config\\local_paths.yaml.example config\\local_paths.yaml
```

- `import_weights` — override the auto-detected weight file
- `tpc_benchmark` — TPC validation input
- `tariff_etrs_repo` — Tariff-ETRs cross-repo comparison
- `weight_mode` — `required` (default) or `unweighted` (opt out)

### 4. Verify the environment

```bash
Rscript src/preflight.R
```

This checks packages, config files, committed resources, HTS JSON availability, and optional local benchmark paths.

### 5. Run the build

```bash
Rscript src/pipeline/00_build_timeseries.R --full
```

For an unweighted run (no weight file built):

```bash
Rscript src/pipeline/00_build_timeseries.R --full --unweighted
# or equivalently --core-only
```

Useful variants:

```bash
Rscript src/pipeline/00_build_timeseries.R
Rscript src/pipeline/00_build_timeseries.R --full
Rscript src/pipeline/00_build_timeseries.R --build-only
Rscript src/pipeline/00_build_timeseries.R --with-alternatives
Rscript src/pipeline/00_build_timeseries.R --with-alternatives --rebuild-alts metal_flat,usmca_2024
Rscript src/pipeline/00_build_timeseries.R --full --use-hts-dates
Rscript src/pipeline/00_build_timeseries.R --full --refresh-usmca
```

The `--rebuild-alts` flag subsets the slow rebuild alternatives (each is roughly comparable to a full daily-series build). Available scenario names: `usmca_annual`, `usmca_monthly`, `usmca_2024`, `usmca_dec2025`, `metal_flat`, `dutyfree_nonzero`, `subdivision_r_mid`. Pass a comma-separated list. Omit the flag to run all of them (default). Has no effect without `--with-alternatives` or `--alternatives-only`.

The `--refresh-usmca` flag re-downloads USMCA utilization shares from the USITC DataWeb API before building. This updates the monthly and annual share CSVs in `resources/` with the latest available data. Requires a DataWeb API token in `.env` (see `tools/download_usmca_dataweb.R` for setup). The flag is optional — without it, the build uses the committed share files.

By default, the pipeline uses **legal policy effective dates** where they differ from HTS revision dates (e.g., SCOTUS ruling effective Feb 20 vs. HTS revision Feb 24). Pass `--use-hts-dates` to use raw HTS revision dates instead. See [docs/policy_timing.md](policy_timing.md) for the full list of affected revisions and legal sources.

### 6. Run the smoke tests

```bash
Rscript tests/run_tests_daily_series.R
```

Pass `--with-artifacts` to include the heavier artifact-dependent integration checks when local built outputs are available.

## Input inventory

### Required for the core build

| Input | Path | Status | Role | Regeneration |
|---|---|---|---|---|
| HTS JSON archives | `data/hts_archives/*.json` | auto-download | official tariff schedule by revision | `src/pipeline/02_download_hts.R` |
| Policy config | `config/policy_params.yaml` | committed | tariff logic, dates, and assumptions | manual update when policy changes |
| Revision schedule | `config/revision_dates.csv` | committed | HTS effective dates and benchmark alignment | `src/pipeline/01_scrape_revision_dates.R` discovers new revisions via USITC API; placeholder dates require manual review |
| Census country codes | `resources/census_codes.csv` | committed | country dimension | manual refresh |
| Country-partner mapping | `resources/country_partner_mapping.csv` | committed | partner aggregates for reporting | manual refresh |
| Section 301 product list | `resources/s301_product_lists.csv` | committed | blanket 301 coverage | `tools/scrape_us_notes.R` (validates anchor coverage; refuses partial writes) |
| IEEPA exempt products | `resources/ieepa_exempt_products.csv` | committed | reciprocal exemptions | regenerate when exemption logic changes |
| Section 232 derivative products | `resources/s232_derivative_products.csv` | committed | derivative 232 coverage (aluminum + steel, 568 HTS8 prefixes) | manual / FR 2025-15819; future: `scrape_us_notes.R --232-derivatives` |
| Section 232 annex products (post-2026-04-06) | `resources/s232_annex_products.csv` | committed | annex tier mapping (1a/1b/2/3) for the four-annex regime | `Rscript tools/scrape_us_notes.R --annex` (auto-detects latest revision; merges parser output with curator overrides). See [docs/s232/annex_parser.md](s232/annex_parser.md). |
| Copper 232 product list | `resources/s232_copper_products.csv` | committed | copper 232 coverage (80 HTS8 prefixes) | `tools/scrape_us_notes.R --copper` (validates >= 60 codes; refuses reduced overwrites) |
| Auto and MHD product lists | `resources/s232_auto_parts.txt`, `resources/s232_mhd_parts.txt` | committed | 232 auto and MHD coverage | manual refresh from official notes |
| Fentanyl carve-outs | `resources/fentanyl_carveout_products.csv` | committed | reduced fentanyl rates for carve-out products | manual / documented refresh |
| USMCA product shares | `resources/usmca_product_shares_2024.csv`, `resources/usmca_product_shares_2025.csv` | committed | product-level USMCA utilization | `tools/download_usmca_dataweb.R` |
| MFN exemption shares | `resources/mfn_exemption_shares.csv` | committed | effective MFN base-rate adjustment | regenerate from source trade data if methodology changes |
| Metal content shares | `resources/metal_content_shares_bea_hs10.csv` | committed | derivative 232 metal-share estimation | regenerate from BEA workflow if needed |
| Floor exemptions | `resources/floor_exempt_products.csv` plus revision-specific `data/us_notes/floor_exempt_{revision}.csv` | committed plus auto-scrape | floor-country exemptions | `tools/scrape_us_notes.R --floor-exemptions` (validates anchor coverage; refuses partial overwrites) |
| Section 122 exemptions | `resources/s122_exempt_products.csv` | committed | Annex II exemptions | manual refresh when authority changes |
| Import weights | `data/weights/hs10_by_country_gtap_<year>_con.rds` (gitignored) or path set in `config/local_paths.yaml` | built locally; auto-detected | HS10×country import value for weighted ETRs, weighted daily series, sector aggregates | `Rscript src/io/build_import_weights.R --year 2024` — see [docs/weights.md](weights.md) |

> Required by default. Skip with `--unweighted` or `weight_mode: unweighted` in `config/local_paths.yaml`.

### Optional inputs

| Input | Path | Status | Role |
|---|---|---|---|
| TPC benchmark | local path via `config/local_paths.yaml` | private/local | validation only |
| Tariff-ETRs repo | local path via `config/local_paths.yaml` | optional/local | comparison only |
| Chapter 99 PDFs | `data/us_notes/*.pdf` | auto-download via `scrape_us_notes.R`; hash-checked by `01_scrape_revision_dates.R` | regenerate resource files from US Notes |

## What runs without what

| Scenario | Build runs? | Rate snapshots | Daily aggregates | By-category aggregates | TPC comparison |
|---|---|---|---|---|---|
| No weights, default `weight_mode: required` | Yes — pre-run auto-builds weights (~15-20 min one-time) | Yes | weighted | weighted | No |
| No weights, `--unweighted` (or `weight_mode: unweighted`) | Yes | Yes | unweighted only | unweighted only | No |
| Weights + no TPC (default) | Yes | Yes | weighted | weighted | No |
| Weights + TPC | Yes | Yes | weighted | weighted | Yes |

## Expected outputs

### Core outputs

| Path | Description |
|---|---|
| `data/timeseries/snapshot_*.rds` | per-revision product-country rate snapshots; canonical build panel |
| `data/timeseries/daily_part_*.rds` | per-revision daily aggregate cache written by the Slurm array tasks; gather validates and binds these when complete, otherwise falls back to snapshot streaming |
| `data/timeseries/metadata.rds` | finalized-build marker and data-as-of metadata |
| `data/timeseries/delta_*.rds` | revision-to-revision diffs |
| `output/actual/daily/daily_overall.csv` | daily aggregate mean and weighted ETR series |
| `output/actual/daily/daily_by_country.csv` | daily country-level aggregate rates |
| `output/actual/daily/daily_by_authority.csv` | daily authority decomposition |
| `output/actual/daily/daily_by_category.csv` | daily by-GTAP-sector aggregate rates (only when import weights available) |
| `output/actual/quality/` | build diagnostics and quality checks |

### Optional outputs

| Path | Description |
|---|---|
| `output/comparisons/` | benchmark comparison artifacts |
| `output/alternative/` | rebuild-alternative variants (USMCA-share pp_override rebuilds) — one file per variant × output type (`daily_overall_<variant>.csv`, `by_authority_<variant>.csv`, `by_country_<variant>.csv`, `by_category_<variant>.csv`). AuthoritySpec scenarios: see [docs/scenarios.md](scenarios.md). |
| `output/etrs_config/{date}/` | ETRs-compatible config directories (from `generate_etrs_config.R`) |

## Scenarios and counterfactuals

Counterfactual scenarios are **AuthoritySpec operations** applied to the policy
spec before the calculator runs (the legacy `config/scenarios.yaml` patch engine
was removed in Phase 7). A scenario is a list of operations
(`set_rate`/`set_exempt`/`disable`/`set_country_scope`/`set_active`/`add_program`);
"baseline = the empty scenario." See [docs/scenarios.md](scenarios.md) for the
authoring guide and [`src/scenario_ops.R`](../src/scenario_ops.R) for the verbs.

Separately, the build can re-run the series under alternative **policy-parameter**
variants (the USMCA-share rebuilds: `usmca_annual`, `usmca_monthly`, `usmca_2024`,
`usmca_dec2025`, …) with `--with-alternatives`; outputs land in
`output/alternative/`.

```bash
Rscript src/pipeline/00_build_timeseries.R --alternatives-only   # rebuild alternatives only
```

## Comparison workflows

TPC and Tariff-ETRs are comparison tools, not production inputs.

```bash
Rscript src/run_comparisons.R
Rscript src/run_comparisons.R --tpc
Rscript src/run_comparisons.R --etr
```

`--etrs` is currently a placeholder in the wrapper. For Tariff-ETRs comparison, run `src/compare_etrs.R` directly (requires `tariff_etrs_repo` in `config/local_paths.yaml`).

### Generating ETRs config

To export tracker rates into Tariff-ETRs-compatible config format:

```bash
Rscript tools/generate_etrs_config.R 2026-04-01 ../Tariff-ETRs/config/baseline/2026-04-01
```

This writes `statutory_rates.csv.gz` (dense per-authority statutory rates at HTS10 × country level) and `other_params.yaml` (adjustment parameters: metal content, USMCA, auto rebate). The CSV is the primary lossless interface — ETRs reads it directly and applies all adjustments (USMCA scaling, metal content, stacking). Legacy per-authority YAML generators are also available for backward compatibility.

To generate configs for all revision dates at once, use `generate_etrs_configs_all_revisions()` from R.

## Publishing

There are two publication destinations. Pick whichever fits the audience.

| Mode | How | Destination | Audience | History |
|------|------|-------------|----------|---------|
| Internal | array flow (`scripts/submit_build_array.sh --config …`) | Shared NFS tree (`<model_data_root>/<vintage>/`) | Other Budget Lab models on the same NFS share | Immutable dated vintages, all preserved on disk |
| Git | `--publish-git` | `release/` in the repo | Public consumers reading via GitHub | Only latest on disk; history via `git log -- release/` |

Git publish refuses to ship outputs that predate the current build (it skips
stale daily CSVs) and requires `digest` (`arrow` only if a parquet output is
reintroduced). A failed publish logs a warning but does not fail the build.

---

### Internal shared NFS vintage (array flow)

The internal shared tree is written by the config-driven array build, not by a
flag on `00_build_timeseries.R`. Each run writes an immutable, dated vintage; a
`latest` symlink points at the most recent one.

#### Trigger

```bash
sbatch scripts/submit_build_array.sh --config config/build/<name>.yaml
```

The build config names the `model_data_root`, the scenarios to build, and the
verify/`update_latest` behaviour (see `src/core/build_config.R` and
[scripts/README.md](../scripts/README.md)). The gather + finalize steps
(`scripts/build_gather.R`, `scripts/publish_vintage.R`) write the vintage below
and repoint `latest`.

#### Shared layout

```
Tariff-Rate-Tracker/
  2026-05-08/
    actual/
      snapshots/
        valid_from=2025-01-01/rates.parquet
        valid_from=2025-01-27/rates.parquet
        ...
        metadata.rds
      daily/                     # output/actual/daily/*.csv
      quality/                   # output/actual/quality/*
      etrs_config/               # output/actual/etrs_config/*      (if built)
    scenarios/
      <name>/                    # output/scenarios/<name>/*        (if built)
    manifest.json
  2026-05-09/
    ...
  latest -> 2026-05-09
```

#### Vintage rules

- Default vintage is today's date (`YYYY-MM-DD`). A second publish on the same day uses `_2`, then `_3`, etc.
- Vintages are immutable. A scenarios-only re-run writes a new vintage with the panel re-copied (each vintage is self-contained).
- Files older than the build start are not copied — a vintage only contains files written during the build that produced it.
- The `latest` symlink is updated atomically (write `.latest.tmp`, then rename).

#### What gets published (internal)

The shared tree is for downstream consumers, so only canonical products are mirrored — not intermediates:

- ✅ `data/timeseries/snapshot_*.rds` → `actual/snapshots/valid_from=*/rates.parquet`, plus `metadata.rds`
- ✅ `output/actual/daily/`, `output/actual/quality/`, `output/actual/etrs_config/`, `output/scenarios/`
- ❌ `data/timeseries/delta_*.rds`, `ch99_*.rds`, `products_*.rds` (intermediates)
- ❌ `data/processed/`, `data/hts_archives/` (intermediates / re-downloadable raw inputs)
- ❌ `output/comparisons/` (validation, not a product)

#### Manifest (internal)

Every vintage includes `manifest.json` recording: vintage id, build start + publish timestamps, git commit + branch + dirty bit, the build flags actually used, R + key package versions, and `{path, size_bytes, sha256}` for every published file.

---

### `--publish-git` (in-repo release/)

Writes a smaller, public-facing subset of outputs into `release/` with publication-date suffixes on every filename. Each `--publish-git` run replaces the previous publication's files; historical publications are recoverable via `git log -- release/`.

#### Trigger

```bash
Rscript src/pipeline/00_build_timeseries.R --full --core-only --publish-git
```

Or publish whatever is on disk in a separate step:

```bash
Rscript src/io/publish_git.R                   # publish current local outputs
Rscript src/io/publish_git.R --dry-run         # plan only, no writes
Rscript src/io/publish_git.R --date 2026-05-21 # override the publication date in filenames
```

After a successful `--publish-git`, the new `release/` files are written to disk but **not auto-committed**. Review with `git status release/`, then commit deliberately so each publication is a reviewable git commit.

#### Release layout

```
release/
  README.md                                    # tracked, hand-written
  MANIFEST.json                                # overwritten each run
  data/
    daily_overall_2026-05-21.csv               # csv for small daily aggregates
    daily_by_country_2026-05-21.csv
    daily_by_authority_2026-05-21.csv
    daily_by_category_2026-05-21.csv
```

#### What gets published (git)

A deliberately narrow, public-facing subset — defined explicitly in `RELEASE_OUTPUTS` at the top of `src/io/publish_git.R`:

- ✅ `output/actual/daily/daily_overall.csv`, `daily_by_country.csv`, `daily_by_authority.csv`, `daily_by_category.csv` → `<name>_<date>.csv`
- ❌ Full rate panel, quality, ETRs config, alternatives — internal tree only for now

CSV vs parquet is decided per output. The current git release uses CSV for the
small daily aggregates (grep-friendly, diff-readable); the full rate panel is
published only through the internal per-interval snapshot layout.

#### Manifest (git)

`release/MANIFEST.json` records: publication date, `published_at` timestamp, `data_as_of` (last revision id + last build time from `metadata.rds`), git commit + branch + dirty bit, build flags actually used, R + key package versions, and `{name, source, path, format, n_rows, size_bytes, sha256}` for every published file.

## Updating when a new HTS revision is published

1. Run `Rscript src/pipeline/01_scrape_revision_dates.R` or update `config/revision_dates.csv`.
2. Download the new JSON with `src/pipeline/02_download_hts.R`.
3. If the Chapter 99 PDF changed, regenerate affected resource files.
4. Re-run the build, usually without `--full`.

## Troubleshooting

- If `preflight.R` reports missing packages, run `tools/install_dependencies.R --all`.
- If the pre-run import-weights auto-build fails (Census URL change, network issues), run `src/io/build_import_weights.R` manually with override flags or set `weight_mode: unweighted` (see [docs/weights.md](weights.md)).
- If benchmark comparisons are skipped, confirm the configured TPC path exists.
- If no HTS JSON archives are found, run `src/pipeline/02_download_hts.R`.

## Querying built data

Point-in-time queries:

```r
source('src/core/helpers.R')
ts <- readRDS('data/timeseries/rate_timeseries.rds')
snapshot <- get_rates_at_date(ts, as.Date('2026-06-15'))
```

Filtered daily extracts:

```r
source('src/core/helpers.R')
source('src/pipeline/09_daily_series.R')
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
