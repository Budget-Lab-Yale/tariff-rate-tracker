# Tariff Rate Tracker

An R-based system for constructing statutory U.S. tariff rates at the HTS-10 x country level, using the USITC Harmonized Tariff Schedule JSON archives as the primary source. Processes all HTS revisions sequentially to build a time series of tariff rates across 2025-2026. Designed to produce outputs compatible with the Yale Budget Lab Tariff-Model.

## Status

**In development.** The pipeline processes 39 HTS JSON archives (2025 basic + revisions 1-32 + 2026 basic + 2026 revisions 1-4) to build per-revision rate snapshots and a combined time series. All rates are derived from HTS source data -- no external rate inputs. Current validation against TPC benchmark data shows 86% exact match at rev_10 (post-Liberation Day), 66% at rev_32. Best-matching countries (surcharge IEEPA) hit 87-94%. See [Validation Status](#validation-status) and [Known Issues](#known-issues).

## How It Works

The tracker builds a panel of statutory tariff rates from HTS JSON archives. The 2025 tariff measures (Section 232, 301, IEEPA reciprocal/fentanyl) are encoded as **Chapter 99 provisions** in the HTS. These link to product lines in three ways:

1. **Footnote references** (Section 301, IEEPA fentanyl): Product lines contain footnotes like "See 9903.88.15" that point to Ch99 subheadings specifying the additional duty rate and country scope.
2. **Chapter-based coverage** (Section 232): Ch99 entries describe which products they cover by referencing HTS notes (e.g., "note 16 to this subchapter") rather than individual product lines. Products are identified by HTS chapter -- Ch. 72-73 for steel, Ch. 76 for aluminum.
3. **Universal application with country-specific rates** (IEEPA reciprocal/fentanyl): Entries in 9903.01-02.xx apply to all products from a given country. Each entry's description names the countries and the `general` field encodes the rate. Some countries (EU, Japan, South Korea) use a floor structure instead of a surcharge.
4. **Blanket non-discriminatory tariff** (Section 122): A uniform tariff applied to all products and all countries, with product exemptions from an Annex II list. Gated by a 150-day statutory expiry window (Trade Act §122).

A simple diff of base rates across HTS revisions would miss all four mechanisms.

### Pipeline Steps (per revision)

1. **Parse Chapter 99 entries** -- extracts additional duty rates, authority type, and country scope from each subheading
2. **Parse product lines** -- extracts base MFN rates and Chapter 99 footnote references
3. **Extract policy parameters** -- IEEPA reciprocal rates, fentanyl rates, Section 232 rates, and USMCA eligibility directly from the JSON
4. **Calculate total rates** per HTS-10 x country using stacking rules
5. **Validate** against TPC benchmark data (for revisions with a matching TPC date)

The orchestrator repeats these steps for each HTS revision, producing per-revision snapshots and tracking deltas between revisions.

## Code Guide

### Main Entry Point

| File | Purpose |
|------|---------|
| `00_build_timeseries.R` | **Main orchestrator.** Iterates over all HTS revisions, builds per-revision rate snapshots, computes deltas, runs TPC validation, and combines into a long-format time series. Supports full rebuild (`--full`), incremental (`--start-from`), and auto-update (default). After building, runs downstream scripts (daily series, weighted ETR, quality report) unless `--build-only`. |

### Build Pipeline (sourced by `00_build`)

| File | Purpose |
|------|---------|
| `01_scrape_revision_dates.R` | Scrapes USITC for revision effective dates. |
| `02_download_hts.R` | Downloads missing HTS JSON archives from USITC. |
| `04_parse_chapter99.R` | Parses all Chapter 99 entries from HTS JSON. Extracts rates from the `general` field, infers authority type from the subheading range, and parses country scope from the `description` field. |
| `05_parse_products.R` | Parses HTS-10 product lines. Extracts base MFN rates and Chapter 99 footnote references. |
| `06_parse_policy_params.R` | Extracts policy parameters directly from HTS JSON: IEEPA country-specific reciprocal rates (with rate_type classification and EU expansion), IEEPA fentanyl rates, Section 232 rates (including 9903.94 autos), and USMCA eligibility. |
| `07_calculate_rates.R` | Joins products to Chapter 99 authorities via footnote refs. Applies IEEPA reciprocal/fentanyl as blanket country-level tariffs (with product exemptions). Identifies Section 232 products by chapter and heading prefix. Gates Section 122 on statutory expiry. Applies stacking rules. Expands to the country dimension. |
| `08_validate_tpc.R` | Compares calculated rates against TPC benchmark data at the HTS-10 x country x date level. Reports match rates and identifies systematic discrepancies. |

### Downstream (run automatically by `00_build`, or standalone)

| File | Purpose |
|------|---------|
| `11_weighted_etr.R` | Import-weighted effective tariff rate analysis. Uses `get_rates_at_date()` from `helpers.R` to query the built timeseries, calculates weighted average ETRs by authority/partner/sector, produces comparison plots with TPC overlays. Callable via `run_weighted_etr()`. |
| `12_daily_series.R` | Daily rate series: `build_daily_aggregates()` for pre-computed daily ETRs (with Section 122 expiry interval splitting), `expand_to_daily()` for on-demand expansion. Callable via `run_daily_series()`. |
| `quality_report.R` | Schema checks, per-revision quality metrics, anomaly detection. Callable via `run_quality_report()`. |

### Shared Infrastructure

| File | Purpose |
|------|---------|
| `helpers.R` | Shared utility functions (rate parsing, HTS normalization, footnote extraction, file I/O, policy params, stacking rules, `get_rates_at_date()`). |
| `logging.R` | Structured logging module (`init_logging`, `log_info`/`warn`/`error`/`debug`). |

### Standalone Tools (not part of build)

| File | Purpose |
|------|---------|
| `03_scrape_us_notes.R` | Data-prep tool: parses US Note 20/21/31 product lists and floor country exemptions from Chapter 99 PDF. Generates static resource files consumed by the build. Run manually when USITC updates PDFs. |
| `09_apply_scenarios.R` | Counterfactual scenario system. Zeros out selected authority columns and recomputes totals. Config in `config/scenarios.yaml`. |
| `10_diagnostics.R` | Validation and debugging utilities: Section 301 coverage gap report, China IEEPA tracking, per-revision summary. |
| `13_revision_changelog.R` | Diffs Ch99 entries across all revisions, builds policy timeline. |
| `test_tpc_comparison.R` | Standalone TPC comparison across all 5 validation dates. Produces detailed diagnostics by revision, country, and discrepancy pattern. |

### Deprecated

| File | Purpose |
|------|---------|
| `run_pipeline.R` | Single-revision orchestrator. **Deprecated** — use `00_build_timeseries.R`. |
| `update_pipeline.R` | Automated incremental update. **Deprecated** — auto-detect logic folded into `00_build_timeseries.R`. |

## Usage

```bash
# Auto-update (default): detect new revisions → download → build → daily → ETR → quality
Rscript src/00_build_timeseries.R

# Full rebuild from scratch
Rscript src/00_build_timeseries.R --full

# Incremental from a specific revision
Rscript src/00_build_timeseries.R --start-from rev_25

# Build only (skip downstream: daily series, ETR, quality report)
Rscript src/00_build_timeseries.R --build-only

# Standalone downstream scripts (also run automatically by 00_build)
Rscript src/12_daily_series.R
Rscript src/11_weighted_etr.R
Rscript src/quality_report.R
```

The default mode (`Rscript src/00_build_timeseries.R` with no flags) checks for a previous build, identifies new revisions, downloads missing JSON, builds the timeseries incrementally, and then runs all downstream scripts. Use `--full` for a clean rebuild or `--build-only` to skip downstream steps.

### Manual Data-Prep Workflow

When USITC publishes new Chapter 99 PDFs, regenerate the static resource files before building:

```bash
# 1. Check for new revisions via USITC API
curl -s "https://hts.usitc.gov/reststop/releaseList" | head -c 500

# 2. Download new JSON
Rscript src/02_download_hts.R --dry-run    # Check what's missing
Rscript src/02_download_hts.R              # Download missing files

# 3. Regenerate 301 product lists and floor exemptions from Ch99 PDF
Rscript src/03_scrape_us_notes.R --all

# 4. Add rows to config/revision_dates.csv for new revisions

# 5. Run full pipeline
Rscript src/00_build_timeseries.R
```

### Output

```
data/timeseries/
  rate_timeseries.rds         # Combined long-format: all revisions
  metadata.rds                # Last revision, build time
  snapshot_basic.rds          # Rates at each revision point
  snapshot_rev_1.rds
  ...
  delta_rev_1.rds             # Changes from basic -> rev_1
  ...
  ch99_rev_32.rds             # Cached parse state (for incremental)
  products_rev_32.rds
  validation_rev_6.rds        # TPC comparison at matched dates

output/daily/                   # From 12_daily_series.R
  daily_overall.csv             # Per-day aggregate ETRs
  daily_by_country.csv          # Per-day x country ETRs
  daily_by_authority.csv        # Per-day x authority ETRs
  daily_aggregates.rds          # All daily aggregates (list)

output/etr/                     # From 11_weighted_etr.R
  etr_overall.csv               # Import-weighted ETR by policy date
  etr_by_partner.csv            # ETR by partner group
  etr_by_authority.csv          # Authority decomposition
  etr_by_gtap.csv               # ETR by GTAP sector
  etr_*.png                     # Comparison plots with TPC overlay

output/quality/                 # From quality_report.R
  schema_check.csv              # Column presence and NA counts
  revision_quality.csv          # Per-revision stats
  anomalies.csv                 # Suspicious jumps or values
```

### Rate Schema

Each snapshot/timeseries row contains:

| Column | Type | Description |
|--------|------|-------------|
| `hts10` | chr | 10-digit HTS code |
| `country` | chr | Census country code |
| `base_rate` | dbl | MFN base rate |
| `rate_232` | dbl | Section 232 |
| `rate_301` | dbl | Section 301 |
| `rate_ieepa_recip` | dbl | IEEPA reciprocal |
| `rate_ieepa_fent` | dbl | IEEPA fentanyl |
| `rate_s122` | dbl | Section 122 |
| `rate_other` | dbl | Other (Section 201, etc.) |
| `metal_share` | dbl | Metal content share (1.0 for non-derivatives) |
| `total_additional` | dbl | After stacking |
| `total_rate` | dbl | base + additional |
| `usmca_eligible` | lgl | USMCA flag |
| `revision` | chr | e.g., 'rev_7' |
| `effective_date` | Date | From revision_dates.csv |
| `valid_from` | Date | Interval start (timeseries only) |
| `valid_until` | Date | Interval end (timeseries only) |

## Tariff Authorities

### 1. Authorities and Active Periods

| Authority | Rate Column | Countries | Active Period (2025) | Rates |
|-----------|-------------|-----------|---------------------|-------|
| **Section 232 (steel)** | `rate_232` | All (some exemptions early 2025) | Entire year; predates 2025 | 25% through ~rev_17, then 50% |
| **Section 232 (aluminum)** | `rate_232` | All (some exemptions early 2025) | Entire year; predates 2025 | 25% through ~rev_17, then 50% |
| **Section 232 (autos)** | `rate_232` | All (USMCA-exempt) | From ~rev_8 (Apr 3) | 25% |
| **Section 232 (copper)** | `rate_232` | All | From config | 25% |
| **Section 301 (original, China)** | `rate_301` | China only | Entire year; predates 2025 | 7.5-25% by list |
| **Section 301 (Biden acceleration)** | `rate_301` | China only | Phased: Sep 2024, Jan 2025, Jan 2026 | +25% (minerals), +50% (semicon/solar), +100% (EVs) |
| **Section 301 (cranes)** | `rate_301` | China only | From ~rev_16 (Jun 2025) | 25% |
| **IEEPA fentanyl** | `rate_ieepa_fent` | Canada, Mexico | From ~rev_3 (Feb 4) | MX +25%; CA +25%, raised to +35% at ~rev_17 |
| **IEEPA reciprocal (Phase 1)** | `rate_ieepa_recip` | ~60 countries | rev_7 (Apr 2) to ~rev_18 (Aug 7) | Country-specific: 10-50% |
| **IEEPA reciprocal (China)** | `rate_ieepa_recip` | China | From rev_7 (Apr 2); never terminated | +34% (9903.01.63) |
| **IEEPA reciprocal (Phase 2)** | `rate_ieepa_recip` | ~60 countries | From rev_18 (Aug 7) | Country-specific surcharges/floors |
| **Section 122 (blanket)** | `rate_s122` | All (Annex II exempt) | From 2026-02-25; **expires 2026-07-25** (150-day statutory limit) | 25% (from HTS 9903.03.xx) |
| **Section 201 (safeguards)** | `rate_other` | Varies | Entire year; predates 2025 | Varies (washing machines, solar) |

**Section 122 expiry:** The Trade Act §122 limits blanket tariffs to 150 days. The `section_122` config in `policy_params.yaml` encodes the effective/expiry window and a `finalized` flag. When `finalized: false`, revisions after the expiry date get `rate_s122 = 0`, daily aggregates split at the expiry boundary, and `get_rates_at_date()` zeroes s122 for post-expiry queries. Set `finalized: true` if Congress extends the authority.

**Key transitions visible across revisions:**
- `basic` -> `rev_6`: Only 232, 301, and early fentanyl entries. No IEEPA reciprocal yet.
- `rev_7`: IEEPA reciprocal Phase 1 appears (~60 countries with "Liberation Day" rates).
- `~rev_17`: 232 rate increase (25% -> 50%), Canada fentanyl increase (25% -> 35%).
- `rev_18`: Phase 1 terminated (except China); Phase 2 reinstated with updated rates.

### 2. HTS-to-Authority Mapping

Each authority has a different mechanism for linking Ch99 entries to products:

#### Section 301 -- Footnote references + blanket product lists

| Ch99 Range | HTS Note | Linkage | Products |
|-----------|----------|---------|----------|
| 9903.86-88.xx | US Note 20 | Footnotes + blanket product list (Lists 1-4B) | ~10,200 via `s301_product_lists.csv` |
| 9903.89.xx | US Note 21 | Description-defined (List 4A exclusions) | Exclusion list (not yet captured) |
| 9903.91.xx | US Note 31 | Footnotes + blanket product list (Biden acceleration) | ~390 via `s301_product_lists.csv` |
| 9903.92.xx | US Note 31 | Footnotes + blanket product list (crane duties) | ~20 via `s301_product_lists.csv` |

**Extraction:** `04_parse_chapter99.R` parses each 9903.xx.xx entry's `general` field for the rate and `description` for country scope. `03_scrape_us_notes.R` parses the Chapter 99 PDF to extract product lists from US Notes 20 and 31, outputting `resources/s301_product_lists.csv` (~12,200 entries across ~11,000 unique HTS8 codes). `07_calculate_rates.R` applies these as a blanket tariff for China, using generation-based rate stacking: MAX within generation (original Trump 9903.88.xx / Biden 9903.91-92.xx), SUM across generations.

**Gap:** Some 9903.89.xx exclusions reference US Note product lists and are not captured — excluded products may incorrectly receive the base 301 rate.

#### Section 232 -- Chapter/heading-based identification

| Ch99 Range | Product Scope | Linkage |
|-----------|---------------|---------|
| 9903.80-82.xx | Steel (HTS Ch. 72-73) | **Blanket chapter match**: chapters 72-73 |
| 9903.85.xx | Aluminum (HTS Ch. 76) | **Blanket chapter match**: chapter 76 |
| 9903.83-84.xx | Autos (footnote-linked) | Product footnotes |
| 9903.94.xx | Autos (HTS heading 8703 + light trucks) | **Blanket heading match**: 13 passenger auto prefixes + 4 light truck prefixes |
| (copper) | Copper (HTS headings 7406-7419) | **Blanket heading match**: 11 heading prefixes |
| 9903.85.04/.07/.08 | Aluminum derivatives (~130 products) | **Blanket product match** from `resources/s232_derivative_products.csv` |

**Extraction:** `06_parse_policy_params.R:extract_section232_rates()` reads 9903.80-85.xx and 9903.94.xx entries and returns rates + country exemptions per revision. `07_calculate_rates.R` applies blanket 232 tariffs using variable-length prefix matching from `config/policy_params.yaml:section_232_chapters` (steel/aluminum) and `section_232_headings` (autos, copper). USMCA exemptions are configured per heading group (`usmca_exempt: true` for autos, `false` for copper).

**Derivatives:** Aluminum-containing articles outside chapter 76 (~130 products) are covered by 9903.85.04/.07/.08. The product list is in `resources/s232_derivative_products.csv` (sourced from Tariff-ETRs config). The tariff applies only to the metal content portion of customs value, with configurable share methods: flat (default 50%), CBO (product-level buckets), BEA (future). See `config/policy_params.yaml:metal_content`.

#### IEEPA Reciprocal -- Blanket country-level tariff

| Ch99 Range | Phase | Linkage |
|-----------|-------|---------|
| 9903.01.43-75 | Phase 1 ("Liberation Day") | **Blanket**: applies to ALL products for named countries |
| 9903.01.63 | Phase 1 (China only) | **Blanket**: never terminated; +34% on all Chinese products |
| 9903.02.02-81 | Phase 2 (reinstated) | **Blanket**: applies to ALL products for named countries |

**Extraction:** `06_parse_policy_params.R:extract_ieepa_rates()` parses each entry's description for country names and `general` field for the rate. "European Union" entries are expanded to 27 member states. Rate types are classified:
- **Surcharge** (most countries): flat additional duty (e.g., +20%)
- **Floor** (EU, Japan, S. Korea): minimum rate (e.g., 15% floor -- only adds duty if base_rate < 15%)
- **Passthrough** (base_rate >= floor): no additional duty

`07_calculate_rates.R` applies these rates to all products for each country, with no footnote linkage needed. ~1,087 products are exempt from IEEPA reciprocal (Annex A / US Note 2 subdivision (v)(iii)); the exempt list is maintained in `resources/ieepa_exempt_products.csv`.

#### IEEPA Fentanyl -- Blanket country-level tariff

| Ch99 Range | Scope | Linkage |
|-----------|-------|---------|
| 9903.01.01-24 | Canada, Mexico, China, Hong Kong | **Blanket** for CA/MX; China/HK **excluded** from blanket (see Hardcoded Elements) |

**Extraction:** `06_parse_policy_params.R:extract_ieepa_fentanyl_rates()` parses 9903.01.01-24 entries. For countries with multiple entries (general rate + anti-transshipment penalties), takes the FIRST entry per country (by Ch99 code order), which is the general rate.

`07_calculate_rates.R` applies fentanyl as a blanket tariff to all products for Canada/Mexico. USMCA-eligible products are exempt.

### 3. Hardcoded Elements and Magic Numbers

#### Country Codes and Groups

| Constant | Location | Value | Used For |
|----------|----------|-------|----------|
| `CTY_CHINA` | `config/policy_params.yaml` | `'5700'` | Stacking rules, fentanyl exclusion |
| `CTY_CANADA` | `config/policy_params.yaml` | `'1220'` | USMCA exemption |
| `CTY_MEXICO` | `config/policy_params.yaml` | `'2010'` | USMCA exemption |
| `CTY_HK` | `config/policy_params.yaml` | `'5820'` | Fentanyl exclusion (alongside China) |
| `EU27_CODES` | `config/policy_params.yaml` | 27 Census codes | Expanding "European Union" Ch99 entries to member states |
| `ISO_TO_CENSUS` | `config/policy_params.yaml` | 12 mappings | Converting Ch99 country descriptions (ISO-style) to Census codes |

#### Product Coverage Rules

| Rule | Location | Logic | Notes |
|------|----------|-------|-------|
| Steel = Ch. 72-73 | `07_calculate_rates.R` | Chapter-level prefix match | Covers ~1,800 products |
| Aluminum = Ch. 76 | `07_calculate_rates.R` | Chapter-level prefix match | Covers ~600 products |
| Autos = heading 8703 + light trucks | `07_calculate_rates.R` | Heading-level prefix match (13+4 prefixes) | USMCA-exempt; from `policy_params.yaml` |
| Copper = headings 7406-7419 | `07_calculate_rates.R` | Heading-level prefix match (11 prefixes) | Not USMCA-exempt; from `policy_params.yaml` |
| IEEPA exempt products | `07_calculate_rates.R` | HTS10 in `resources/ieepa_exempt_products.csv` | ~1,087 Annex A products; IEEPA recip zeroed out |
| USMCA eligibility | `06_parse_policy_params.R` | `special` field contains "S" or "S+" | Binary flag; no utilization-rate adjustment |

#### Stacking Rules

See the standalone [Stacking Rules](#stacking-rules) section below for full formulas. Key rules implemented in `helpers.R:apply_stacking_rules()` and `07_calculate_rates.R`:
- 232/IEEPA mutual exclusion (232 takes precedence; IEEPA applies to non-metal portion for derivatives)
- USMCA exemption (CA/MX USMCA products: IEEPA recip and fentanyl zeroed; 232 still applies)
- IEEPA product exemptions (~1,087 Annex A products from `resources/ieepa_exempt_products.csv`)
- China fentanyl exclusion (China/HK excluded from blanket fentanyl; 9903.90.xx already incorporates it)

#### Phase/Rate Selection

| Rule | Location | Logic | Notes |
|------|----------|-------|-------|
| Phase 2 over Phase 1 | `07_calculate_rates.R` | When both phases exist for a country, prefer Phase 2 | Phase 2 supersedes Phase 1 with updated rates |
| Fentanyl: first entry wins | `06_parse_policy_params.R` | `arrange(ch99_code) %>% summarise(rate = first(rate))` | First entry = general rate; later entries = exceptions (anti-transshipment) |
| 232 "all" over "all_except" | `06_parse_policy_params.R:574-580` | Prefer `country_type == 'all'` entry | 9903.80.61 (exemptions revoked) takes precedence over 9903.80.01 |

#### Revision Date Mapping

`config/revision_dates.csv` is **manually curated**. Effective dates are sourced from USITC revision history; TPC date assignments are manual:

| Revision | Effective Date | TPC Date | Why This Pairing |
|----------|---------------|----------|------------------|
| rev_6 | 2025-03-12 | 2025-03-17 | Closest revision before TPC snapshot |
| rev_10 | 2025-04-09 | 2025-04-17 | Post-Liberation Day |
| rev_17 | 2025-07-01 | 2025-07-17 | Post-232 increase |
| rev_18 | 2025-08-07 | 2025-10-17 | Phase 2 start; TPC date is 2+ months later |
| rev_32 | 2025-11-15 | 2025-11-17 | Latest revision vs latest TPC date |

## Stacking Rules

Tariff authorities overlap. Section 232 and IEEPA reciprocal are **mutually exclusive** (232 takes precedence). For derivative 232 products (metal_share < 1.0), IEEPA reciprocal/fentanyl apply to the non-metal portion of customs value.

**China with 232 product:**
```
total = rate_232 + rate_ieepa_recip * nonmetal_share + rate_ieepa_fent + rate_301 + rate_s122 + rate_other
```

**China without 232 product:**
```
total = rate_ieepa_recip + rate_ieepa_fent + rate_301 + rate_s122 + rate_other
```

**Other countries with 232 product:**
```
total = rate_232 + (rate_ieepa_recip + rate_ieepa_fent) * nonmetal_share + rate_s122 + rate_other
```

**Other countries without 232 product:**
```
total = rate_ieepa_recip + rate_ieepa_fent + rate_s122 + rate_other
```

Where `nonmetal_share = 1 - metal_share` when `rate_232 > 0` and `metal_share < 1.0`, else `0`. For base 232 products (steel, aluminum, autos, copper), `metal_share = 1.0` so `nonmetal_share = 0`, preserving the mutual exclusion. For derivative 232 products (~130 aluminum-containing articles), `metal_share < 1.0` (default 0.50) so IEEPA/fentanyl apply to the remaining portion.

**Canada/Mexico USMCA exemption:** Products with "S"/"S+" in `special` field get IEEPA reciprocal and fentanyl zeroed out. Section 232 still applies regardless of USMCA status.

**China fentanyl exclusion:** China/Hong Kong are excluded from blanket fentanyl application because their 9903.90.xx footnote rates already incorporate fentanyl -- adding it would double-count ~10pp.

## Data

### Input

- **HTS JSON archives** (`data/hts_archives/`): Downloaded from `www.usitc.gov/sites/default/files/tata/hts/` (the old `hts.usitc.gov/reststop/getJSON` endpoint was deprecated in early 2026). Currently holds 39 files: 2025 basic + revisions 1-32 + 2026 basic + 2026 revisions 1-4. ~13-14 MB each, not committed to git.
- **TPC benchmark data** (`data/tpc/tariff_by_flow_day.csv`): Tariff-Model team's estimated tariff rate changes by HTS-10, country, and date. ~250K rows across 42 countries and 5 snapshot dates (2025-03-17, 2025-04-17, 2025-07-17, 2025-10-17, 2025-11-17). **Used for validation only, never as rate input.** See `data/tpc/tpc_notes.txt` for assumptions (50% metal share for derivatives, 40% generic drug share, USMCA share adjustment for Canada/Mexico).

### Configuration

- `config/policy_params.yaml`: All policy constants (country codes, authority ranges, 232 chapter/heading coverage, floor rates, 301 rates, Section 122 expiry). Single source of truth loaded by `helpers.R::load_policy_params()`.
- `config/revision_dates.csv`: Maps each HTS revision to its effective date and (where applicable) the corresponding TPC validation date. 39 rows covering basic through 2026_rev_4.
- `config/scenarios.yaml`: Counterfactual scenario definitions (baseline, no_ieepa, no_301, no_232, pre_2025, etc.). Used by `09_apply_scenarios.R`.

### Reference

- `resources/census_codes.csv`: 240 Census country codes.
- `resources/hs10_gtap_crosswalk.csv`: 18,700-row crosswalk from HTS-10 to GTAP sectors.
- `resources/country_partner_mapping.csv`: 50-row mapping from Census codes to partner aggregation.
- `resources/ieepa_exempt_products.csv`: 1,087 HTS-10 codes exempt from IEEPA reciprocal (Annex A / US Note 2 subdivision (v)(iii)). Derived from Tariff-ETRs config.
- `resources/s301_product_lists.csv`: ~12,200 entries (~11,000 unique HTS-8 codes) covered by Section 301 tariffs on China (Lists 1-4B + Biden modifications). Sourced from USITC "China Tariffs" reference document and US Notes 20/31 PDF parsing via `03_scrape_us_notes.R`. Products on multiple lists have separate entries per ch99 code for generation-based rate stacking.
- `resources/s232_derivative_products.csv`: ~129 aluminum-containing derivative product prefixes (from US Note 19 via Tariff-ETRs config).
- `resources/cbo/`: CBO metal content bucket files for derivative products (high/low aluminum, copper).

## Validation Status

Comparison of timeseries pipeline output against TPC benchmark, matched by revision-to-TPC-date mapping:

| Revision | TPC Date | N Comparisons | Exact (<0.5pp) | Within 2pp | Mean Abs Diff | Mean Diff |
|----------|----------|---------------|----------------|------------|---------------|-----------|
| rev_6 | 2025-03-17 | 62,205 | 61.4% | 61.6% | 5.0 pp | -1.5 pp |
| rev_10 | 2025-04-17 | 300,126 | 86.4% | 86.4% | 2.0 pp | +0.4 pp |
| rev_17 | 2025-07-17 | 299,211 | 77.1% | 77.5% | 3.4 pp | -1.3 pp |
| rev_18 | 2025-10-17 | 298,368 | 61.0% | 61.8% | 5.8 pp | -1.9 pp |
| rev_32 | 2025-11-17 | 298,341 | 66.1% | 67.0% | 4.9 pp | -0.2 pp |

Regenerate with: `Rscript test_tpc_comparison.R`

**Best-matching countries** (rev_32): Madagascar 94%, Bangladesh 94%, Tunisia 92%, Nepal 91%, Pakistan 89%, Mauritius 89%, Armenia 88%, Morocco 87%, Kenya 87%, Sri Lanka 87%.

**Discrepancy patterns** (rev_32):
- **We are higher than TPC** (19.9% of products, mean +11.8pp): Mostly IEEPA reciprocal for countries where our rate exceeds TPC's. Includes 57K products with IEEPA recip > 0.
- **TPC is higher than us** (13.1% of products, mean -19.6pp): ~16K products with shortfall near 25pp. ~2,031 China products where TPC > us (mean -23pp).
- **China match**: At rev_32, China exact match is 72.4%. Mean rate ours (40.2%) vs TPC (41.7%), diff -1.5pp.

Key remaining gap sources: (1) **China+232 reciprocal stacking** (~920 steel/aluminum products; TPC stacks IEEPA reciprocal on top of 232, we apply mutual exclusion per Tariff-ETRs); (2) **EU/Japan/Korea floor residual** (~4pp systematic excess); (3) **USMCA classification mismatch** (~5,700 CA/MX products).

## Known Issues

### 1. China+232 reciprocal stacking (~920 products, ~25pp gap)

For China products subject to Section 232 (steel ch72-73, aluminum ch76, copper ch74), TPC stacks the IEEPA reciprocal tariff on top of 232 (e.g., 232(25%) + recip(25%) + fent(10%) + 301(25%) = 85%). Our model applies mutual exclusion per Tariff-ETRs methodology: 232 takes precedence over IEEPA reciprocal for base 232 products, so recip contributes 0pp. This is a fundamental methodological difference, not a data gap. Our approach follows the legal structure (Section 232 and IEEPA are separate authorities), while TPC appears to sum all authorities unconditionally.

### 2. Section 301 exclusions (9903.89.xx)

Some 9903.89.xx exclusions reference US Note product lists and are not captured — excluded products may incorrectly receive the base 301 rate. Low impact (~61 products).

### 3. China's IEEPA reciprocal rate discrepancy with TPC

China's IEEPA reciprocal is parsed from 9903.01.63 (Phase 1, +34%). TPC data implies a 25% rate. The discrepancy likely reflects the May 2025 US-China bilateral agreement that reduced the effective rate. The HTS Rev 32 still encodes the pre-negotiation statutory rate.

### 4. EU floor rate residual (~4pp systematic)

EU, Japan, and South Korea use a floor rate structure (15% minimum). Japan and South Korea floor selection was fixed (previously mis-selected as surcharge). EU countries show ~35-42% exact match with ~4pp mean excess -- the floor formula is correct but residual discrepancies remain, possibly from TPC using slightly different floor mechanics or base rate differences.

### 5. USMCA eligibility is binary, not utilization-adjusted

USMCA eligibility from the HTS `special` field gives a binary flag. In practice, not all trade in an eligible product claims USMCA preference. A utilization-rate adjustment would improve accuracy for Canada/Mexico.

## Resolved Issues

### Section 301 coverage gap (Fixed)

Section 301 product lists expanded from ~10,400 to ~11,000 unique HTS8 codes (~12,200 entries) by adding List 4B (9903.88.16, 1,519 products) from the Chapter 99 PDF. Rate aggregation changed from `max()` to generation-based stacking: MAX within each generation (original Trump 9903.88.xx / Biden 9903.91-92.xx), SUM across generations. This correctly handles products on both Trump and Biden lists (e.g., Trump List 3 at 25% + Biden at 25% = 50% total). Missing ch99 rate entries added: 9903.91.06 (25%), 9903.91.07 (50%), 9903.91.08 (100%), 9903.92.10 (25%).

### Section 232 derivative products (Fixed)

Aluminum-containing articles outside chapter 76 (~130 products) are now covered via blanket matching using `resources/s232_derivative_products.csv`. The tariff applies only to the metal content portion (configurable: flat 50% default, CBO product-level buckets, BEA future). Stacking rules updated so IEEPA reciprocal/fentanyl apply to the non-metal portion.

### Floor country IEEPA rate selection for Japan/S. Korea (Fixed)

When both surcharge and floor entries exist for the same country/phase, the arbitrary tie-breaking previously picked surcharge, applying a flat +15% instead of the correct floor formula `max(0, 15% - base_rate)`. Fixed by adding `type_priority` to the `country_ieepa` summarization so floor entries are preferred.

### IEEPA fentanyl/initial rates (Fixed)

Fentanyl tariffs (9903.01.01-24) are now extracted as a separate authority and applied as blanket country-level tariffs. Mexico gets +25%, Canada gets +35% (increased from 25% at rev_17). China/Hong Kong are excluded from blanket fentanyl application because their 9903.90.xx footnote rates already incorporate fentanyl -- adding it would double-count ~10pp. USMCA-eligible products are exempt from fentanyl (per 9903.01.14).

### Authority classification corrected (Fixed)

`infer_authority()` and `classify_authority()` now correctly classify: 9903.91.xx as Section 301 (was misclassified as IEEPA), 9903.92.xx as Section 301 crane duties (was IEEPA), 9903.94.xx as Section 232 autos (was IEEPA). US Note 21 and US Note 31 description patterns are now detected as China-specific.

### China IEEPA reciprocal and Biden 301 acceleration (Fixed)

China's IEEPA reciprocal is parsed from 9903.01.63 (Phase 1, +34%). China was never suspended during the Phase 1 -> Phase 2 transition. Biden Section 301 acceleration rates (9903.91.xx) are included via product footnote references -- ~382 products with rates of +25% (critical minerals), +50% (semiconductors/solar), and +100% (EVs/batteries).

### IEEPA country-specific reciprocal rates (Fixed)

Country-specific rates parsed directly from HTS Ch99 entries: 9903.01.43-75 (Phase 1, terminated) and 9903.02.02-81 (Phase 2, active). "European Union" entries expanded to 27 member states. Rate types classified as surcharge (+X%), floor (X%), or passthrough.

### USMCA exemptions for Canada/Mexico (Fixed)

Products with "S" or "S+" program codes exempt from IEEPA tariffs (both fentanyl and reciprocal) but not Section 232. ~24% of products are USMCA-eligible.

### Section 232 duties (Fixed)

Products identified by chapter (72-73 = steel, 76 = aluminum) and heading-level prefixes (8703 = autos, 7406-7419 = copper). Rates parsed from Ch99 entries per revision (25% early 2025, 50% after mid-2025 increase). Coverage expanded beyond steel/aluminum to include autos (9903.94.xx) and copper via `config/policy_params.yaml:section_232_headings`.

## Data Sources

- **HTS Archives**: [USITC HTS Online](https://hts.usitc.gov/) — bulk JSON via [data.gov catalog](https://catalog.data.gov/dataset/harmonized-tariff-schedule-of-the-united-states-2024); release metadata via `hts.usitc.gov/reststop/releaseList`
- **Census Country Codes**: [Census Bureau](https://www.census.gov/foreign-trade/schedules/b/countrycodes.html)
- **Federal Register**: Proclamations and executive orders (manual curation)

## Acknowledgments

We thank the [Urban-Brookings Tax Policy Center](https://www.taxpolicycenter.org/) for generously providing a snapshot of their tariff rate data for validation purposes.

## Related Projects

- [Tariff-Model](https://github.com/Budget-Lab-Yale/Tariff-Model) - Economic impact modeling
- [Tariff-ETRs](https://github.com/Budget-Lab-Yale/Tariff-ETRs) - ETR calculations
