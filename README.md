# Tariff Rate Tracker

Daily statutory U.S. tariff rates at the HTS-10 × country level, built from USITC Harmonized Tariff Schedule JSON archives. Produced by [The Budget Lab at Yale](https://budgetlab.yale.edu/).

The tracker processes 39 HTS revisions (January 2025 through February 2026) to construct a panel of ~4.5 million product-country tariff rates per revision. This process uses HTS data sources, combined with ancillary data and economic assumptions detailed below, to estimate tariff rates. Outputs are designed for use with The Budget Lab at Yale [Tariff-Model](https://github.com/Budget-Lab-Yale/Tariff-Model).

---

## Table of Contents

1. [The U.S. Tariff Regime (2025–2026)](#the-us-tariff-regime-20252026)
2. [Data](#data)
3. [Approach](#approach)
4. [Code Guide](#code-guide)
5. [Usage](#usage)
6. [Methodological Details](#methodological-details)
7. [Validation](#validation)
8. [Current Issues](#current-issues)
9. [Acknowledgments](#acknowledgments)
10. [Related Projects](#related-projects)

---

## The U.S. Tariff Regime (2025–2026)

### Tariff Authorities

| Authority | Legal Basis | Scope | Rate Range |
|-----------|-------------|-------|------------|
| **Section 232** | Trade Expansion Act §232 | Steel, aluminum, autos, copper, derivatives | 25–50% |
| **Section 301** | Trade Act §301 | China (Lists 1–4B, Biden acceleration, cranes) | 7.5–100% |
| **IEEPA Reciprocal** | International Emergency Economic Powers Act | ~60 countries (Phases 1 & 2) | 10–50% (surcharge or floor) |
| **IEEPA Fentanyl** | International Emergency Economic Powers Act | Canada, Mexico | 25–35% |
| **Section 122** | Trade Act §122 | All countries (150-day statutory limit) | 10–25% |

### Pre-2025 Baseline

The tariff regime inherited at the start of 2025 included:

- **MFN base rates**: ~2% import-weighted average (after FTA/GSP preference adjustment; ~4% statutory)
- **Section 232 steel/aluminum** (2018/2020): 25% on chapters 72–73 (steel) and 76 (aluminum)
- **Section 301 China** (2018–2024): 7.5–25% across Lists 1–4A, plus Biden-era accelerations on minerals, semiconductors, solar, EVs, and batteries (25–100%)

### Timeline: 2025 Through Early 2026

**January 2025.** [Executive Order 14195](https://www.federalregister.gov/documents/2025/02/07/2025-02408/imposing-duties-to-address-the-synthetic-opioid-supply-chain-in-the-peoples-republic-of-china) imposes IEEPA fentanyl surcharges on China and Hong Kong (+10%).

**February 2025.** [EO 14193](https://www.federalregister.gov/documents/2025/02/07/2025-02406/imposing-duties-to-address-the-flow-of-illicit-drugs-across-our-northern-border)/[14194](https://www.federalregister.gov/documents/2025/02/07/2025-02407/imposing-duties-to-address-the-situation-at-our-southern-border) extend fentanyl surcharges to Canada (+25%) and Mexico (+25%). China's fentanyl surcharge increases to +20% cumulative.

**March 2025.** [Proclamation 10908](https://www.federalregister.gov/documents/2025/04/03/2025-05930/adjusting-imports-of-automobiles-and-automobile-parts-into-the-united-states) imposes Section 232 tariffs on automobiles (25%, effective April 3). [Proclamation 10896](https://www.federalregister.gov/documents/2025/02/18/2025-02833/adjusting-imports-of-steel-into-the-united-states) revokes all pre-2025 Section 232 country exemptions (TRQ agreements expire March 12). Section 232 derivative products (aluminum-containing articles outside chapter 76) are added at 25%.

**April 2, 2025 — "Liberation Day."** [EO 14257](https://www.federalregister.gov/documents/2025/04/07/2025-06063/regulating-imports-with-a-reciprocal-tariff-to-rectify-trade-practices-that-contribute-to-large-and) announces IEEPA Phase 1 reciprocal tariffs: a universal 10% baseline on all countries plus country-specific surcharges on ~60 countries (11–50%). China receives +34%.

**April 3–5, 2025 — China escalation.** China's reciprocal rate escalates rapidly: +34% → +84% → +125%. All non-China Phase 1 country-specific rates are suspended for a 90-day pause. The universal 10% baseline remains active.

**April 14, 2025 — [Geneva Agreement](https://www.whitehouse.gov/briefings-statements/2025/05/joint-statement-on-u-s-china-economic-and-trade-meeting-in-geneva/).** US-China bilateral agreement de-escalates: China's reciprocal rate returns to +34%, then is suspended. China falls back to the universal 10% baseline.

**May 2025.** Section 232 rates on steel and aluminum derivatives [doubled from 25% to 50%](https://www.federalregister.gov/documents/2025/06/09/2025-10524/adjusting-imports-of-aluminum-and-steel-into-the-united-states). Auto parts added to 232 coverage.

**July 2025.** Canada fentanyl surcharge increased from 25% to 35%. Copper added to Section 232 coverage (headings 7406–7419).

**August 7, 2025 — IEEPA Phase 2.** [EO 14323](https://www.federalregister.gov/documents/2025/08/06/2025-15010/further-modifying-the-reciprocal-tariff-rates) reinstates country-specific reciprocal tariffs with individually negotiated rates. Phase 1 entries are unsuspended; Phase 2 rates stack on top. Key rates: Brazil +10%, UK +10%, EU 15% floor, India +25%, Switzerland +39%. Brazil also receives a [country-specific EO surcharge](https://www.federalregister.gov/documents/2025/08/05/2025-14896/addressing-threats-to-the-united-states-by-the-government-of-brazil) (+40%). India later receives its own EO (+25%, August 20), bringing its total to +50%.

**September–November 2025.** Floor rate structures negotiated with Japan (September 12), South Korea (November 15): 15% minimum rate, with passthrough for products whose base rate already exceeds 15%. Section 301 crane tariffs added (100%). China fentanyl rate reduced to +10% (post-Geneva). Semiconductor tariffs introduced (25%, January 2026).

**January 1, 2026.** [Swiss framework](https://www.federalregister.gov/documents/2025/12/18/2025-23316/implementing-certain-tariff-related-elements-of-the-framework-for-a-united-states-switzerland-liechtenstein) (EO 14346): Switzerland and Liechtenstein receive floor rate structure (15% minimum). Biden-era Section 301 acceleration: minerals, semiconductors, EVs, batteries.

### SCOTUS and Section 122

**February 20, 2026 — [*Learning Resources, Inc. v. Trump*](https://www.supremecourt.gov/opinions/25pdf/24-1287_4gcj.pdf), 607 U.S. ___ (2026).** In a 6–3 decision, the Supreme Court rules that IEEPA does not authorize tariffs (Roberts, writing for the majority). All IEEPA reciprocal and fentanyl tariffs are vacated.

The administration immediately [reimplements tariffs under Section 122](https://www.whitehouse.gov/presidential-actions/2026/02/imposing-a-temporary-import-surcharge-to-address-fundamental-international-payments-problems/) of the Trade Act of 1974, which authorizes blanket surcharges for up to 150 days without Congressional approval. A 10% blanket tariff on all countries takes effect February 25, 2026 (HTS 9903.03.xx), with exemptions for products already subject to Section 232, IEEPA-exempt products, civil aircraft, CA/MX, CAFTA-DR, donations, and informational materials.

**The 150-day clock:** Section 122 authority expires approximately July 25, 2026. The tracker enforces this statutory limit at three levels: (1) revisions after the expiry date get `rate_s122 = 0`, (2) daily aggregates split at the expiry boundary, and (3) `get_rates_at_date()` zeroes Section 122 for post-expiry queries. A `finalized` flag in `config/policy_params.yaml` controls this behavior — set to `true` if Congress extends the authority.

Section 232 and Section 301 tariffs are unaffected by the SCOTUS ruling (separate statutory authority).

---

## Data

### Inputs

| Data | Location | Description | Source |
|------|----------|-------------|--------|
| HTS JSON archives | `data/hts_archives/` | 39 files (~13–14 MB each). Not committed to git. | [USITC](https://hts.usitc.gov/) |
| TPC benchmark | `data/tpc/tariff_by_flow_day.csv` | ~250K rows across 42 countries and 5 dates. **Validation only.** Not publicly available. | [Tax Policy Center](https://www.taxpolicycenter.org/) |
| Census country codes | `resources/census_codes.csv` | 240 country codes | [Census Bureau](https://www.census.gov/foreign-trade/schedules/b/countrycodes.html) |
| Import weights | `resources/hs10_gtap_crosswalk.csv` | 18,700-row HTS-10 to GTAP sector crosswalk | [GTAP](https://www.gtap.agecon.purdue.edu/) |
| Partner mapping | `resources/country_partner_mapping.csv` | 50-row Census-to-partner aggregation | Authors |
| IEEPA exempt products | `resources/ieepa_exempt_products.csv` | 1,087 HTS-10 codes (Annex A / US Note 2) | [Tariff-ETRs](https://github.com/Budget-Lab-Yale/Tariff-ETRs) |
| 301 product lists | `resources/s301_product_lists.csv` | ~12,200 entries (~11,000 unique HTS-8 codes) | [USITC](https://hts.usitc.gov/) |
| 232 derivative products | `resources/s232_derivative_products.csv` | ~129 aluminum-containing article prefixes | [Tariff-ETRs](https://github.com/Budget-Lab-Yale/Tariff-ETRs) |
| MFN exemption shares | `resources/mfn_exemption_shares.csv` | 4,695 HS2 × country FTA/GSP preference shares | [Tariff-ETRs](https://github.com/Budget-Lab-Yale/Tariff-ETRs) |
| Fentanyl carve-outs | `resources/fentanyl_carveout_products.csv` | 308 HTS-8 prefixes (energy/minerals/potash) | [Tariff-ETRs](https://github.com/Budget-Lab-Yale/Tariff-ETRs) |
| Floor exemptions | `data/us_notes/floor_exempt_{revision}.csv` (fallback: `resources/floor_exempt_products.csv`) | Per-revision country-product floor exemptions | [USITC](https://hts.usitc.gov/) |
| CBO metal content | `resources/cbo/` | Product-level metal content buckets | [CBO](https://www.cbo.gov/) |

### Configuration

| File | Purpose |
|------|---------|
| `config/policy_params.yaml` | All policy constants: country codes, authority ranges, 232 coverage, floor rates, 301 rates, Section 122 expiry. Single source of truth. |
| `config/revision_dates.csv` | Maps 39 HTS revisions to effective dates and TPC validation dates. Manually curated. |
| `config/scenarios.yaml` | Counterfactual scenario definitions (baseline, no_ieepa, no_301, no_232, pre_2025, etc.). |

### Outputs

**Time series** (`data/timeseries/`):

| File | Description |
|------|-------------|
| `rate_timeseries.rds` | Combined long-format panel (all revisions) |
| `metadata.rds` | Last revision, build time |
| `snapshot_*.rds` | Per-revision rate snapshots |
| `delta_*.rds` | Changes between consecutive revisions |
| `validation_*.rds` | TPC comparison at matched dates |

**Daily aggregates** (`output/daily/`): per-day overall, by-country, and by-authority ETRs.

**Weighted ETRs** (`output/etr/`): import-weighted effective tariff rates by partner, authority, and GTAP sector, with TPC overlay plots.

**Quality reports** (`output/quality/`): schema checks, per-revision quality metrics, anomaly detection.

### Rate Schema

Each row in the snapshot/timeseries contains:

| Column | Type | Description |
|--------|------|-------------|
| `hts10` | chr | 10-digit HTS code |
| `country` | chr | Census country code |
| `base_rate` | dbl | Effective MFN base rate (after FTA/GSP exemption adjustment) |
| `statutory_base_rate` | dbl | Original statutory MFN rate (before adjustment) |
| `rate_232` | dbl | Section 232 |
| `rate_301` | dbl | Section 301 |
| `rate_ieepa_recip` | dbl | IEEPA reciprocal |
| `rate_ieepa_fent` | dbl | IEEPA fentanyl |
| `rate_s122` | dbl | Section 122 |
| `rate_other` | dbl | Other (Section 201, etc.) |
| `metal_share` | dbl | Metal content share (1.0 for non-derivatives) |
| `total_additional` | dbl | Sum of additional duties (after stacking) |
| `total_rate` | dbl | base_rate + total_additional |
| `usmca_eligible` | lgl | USMCA eligibility flag |
| `revision` | chr | e.g., `rev_7` |
| `effective_date` | Date | From revision_dates.csv |
| `valid_from` | Date | Interval start (timeseries only) |
| `valid_until` | Date | Interval end (timeseries only) |

---

## Approach

### Pipeline Overview

For each of the 39 HTS revisions, the pipeline:

1. **Parses Chapter 99 entries** — extracts additional duty rates, authority type, and country scope
2. **Parses product lines** — extracts base MFN rates and Chapter 99 footnote references
3. **Extracts policy parameters** — IEEPA reciprocal/fentanyl rates, Section 232 rates, USMCA eligibility
4. **Calculates total rates** per HTS-10 × country using stacking rules
5. **Validates** against TPC benchmark (where a matching TPC date exists)

The orchestrator repeats these steps for each revision, producing per-revision snapshots and tracking deltas. After building, it combines snapshots into a long-format time series with temporal intervals and runs downstream scripts (daily series, weighted ETR, quality report).

### How Tariffs Link to Products

The 2025–2026 tariff measures are encoded as Chapter 99 provisions in the HTS. They link to product lines through four distinct mechanisms:

1. **Footnote references** (Section 301, IEEPA fentanyl): Product lines contain footnotes like "See 9903.88.15" that point to Ch99 subheadings specifying the duty rate and country scope.

2. **Chapter-based coverage** (Section 232): Ch99 entries reference HTS notes rather than individual product lines. Products are identified by chapter — Ch. 72–73 for steel, Ch. 76 for aluminum — or by heading prefix (8703 for autos, 7406–7419 for copper).

3. **Universal application** (IEEPA reciprocal/fentanyl): Entries in 9903.01–02.xx apply to *all* products from a given country. Each entry names the countries in its description and encodes the rate in the `general` field.

4. **Blanket non-discriminatory tariff** (Section 122): A uniform tariff on all products and all countries, with product exemptions from an Annex II list. Gated by a 150-day statutory expiry window.

A simple diff of base rates across HTS revisions would miss all four mechanisms.

### Stacking Rules Overview

Tariff authorities overlap. Section 232 and IEEPA reciprocal are **mutually exclusive** — 232 takes precedence. For derivative 232 products (metal content < 100%), IEEPA applies to the non-metal portion of customs value. See [Stacking Formulas](#stacking-formulas) for full detail.

### MFN Exemption Shares

Statutory MFN rates overstate actual base-rate collections because many imports enter under preferential trade agreements (FTAs) or programs like GSP. The tracker adjusts base rates using HS2 × country exemption shares derived from Census calculated duty data:

```
effective_base_rate = statutory_mfn_rate × (1 - exemption_share)
```

This reduces the import-weighted average base rate from ~4% (statutory) to ~2% (effective). Canada and Mexico are excluded from this adjustment — their preferences are handled at HTS-10 granularity via USMCA utilization shares. Both effective and statutory base rates are preserved in the output. Configurable via `mfn_exemption` in `config/policy_params.yaml`.

---

## Code Guide

### Orchestrator

| File | Purpose |
|------|---------|
| `00_build_timeseries.R` | Main entry point. Iterates over all HTS revisions, builds per-revision rate snapshots, computes deltas, runs TPC validation, and combines into a long-format time series. Supports `--full` (clean rebuild), `--start-from` (incremental), `--build-only` (skip downstream), and auto-update (default). |

### Build Pipeline (sourced by `00_build`)

| File | Purpose |
|------|---------|
| `01_scrape_revision_dates.R` | Scrapes USITC for revision effective dates |
| `02_download_hts.R` | Downloads missing HTS JSON archives from USITC; standalone with `--dry-run` |
| `03_parse_chapter99.R` | Parses Chapter 99 entries: rates from `general` field, authority type from subheading range, country scope from `description` |
| `04_parse_products.R` | Parses HTS-10 product lines: base MFN rates and Chapter 99 footnote references |
| `05_parse_policy_params.R` | Extracts policy parameters from HTS JSON: IEEPA rates (with rate_type classification), fentanyl rates, Section 232 rates (including autos), USMCA eligibility |
| `06_calculate_rates.R` | Joins products to authorities. Applies IEEPA/fentanyl as blanket country-level tariffs. Identifies 232 products by chapter/heading prefix. Gates Section 122 on statutory expiry. Adjusts base rates for FTA/GSP preferences. Applies stacking rules. Expands to country dimension. |
| `07_validate_tpc.R` | Compares calculated rates against TPC benchmark at HTS-10 × country × date level |

### Downstream (run automatically by `00_build`, or standalone)

| File | Purpose |
|------|---------|
| `08_weighted_etr.R` | Import-weighted ETR analysis by authority/partner/sector with TPC overlay plots. Callable via `run_weighted_etr()`. |
| `09_daily_series.R` | Daily rate series with Section 122 expiry interval splitting. Callable via `run_daily_series()`. |
| `quality_report.R` | Schema checks, per-revision quality metrics, anomaly detection. Callable via `run_quality_report()`. |

### Shared Infrastructure

| File | Purpose |
|------|---------|
| `helpers.R` | Shared utilities: rate parsing, HTS normalization, footnote extraction, file I/O, policy params loading, stacking rules, `get_rates_at_date()`, revision management |
| `logging.R` | Structured logging (`init_logging`, `log_info`/`warn`/`error`/`debug`) |

### Standalone Tools

| File | Purpose |
|------|---------|
| `scrape_us_notes.R` | Parses US Note 20/21/31 product lists and floor exemptions from Chapter 99 PDF. Generates static resource files. Run manually when USITC updates PDFs. |
| `apply_scenarios.R` | Counterfactual scenario system: zeros out selected authority columns, recomputes totals. Config in `config/scenarios.yaml`. |
| `diagnostics.R` | Validation utilities: 301 coverage gaps, China IEEPA tracking, per-revision summary, `decompose_tpc_discrepancies()` |
| `revision_changelog.R` | Diffs Ch99 entries across all revisions, builds policy timeline |
| `test_tpc_comparison.R` | Standalone TPC comparison across all 5 validation dates with detailed diagnostics |

---

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
Rscript src/09_daily_series.R
Rscript src/08_weighted_etr.R
Rscript src/quality_report.R
```

The default mode checks for a previous build, identifies new revisions, downloads missing JSON, builds the timeseries incrementally, and runs all downstream scripts.

### Manual Data-Prep Workflow

When USITC publishes new Chapter 99 PDFs, regenerate static resource files before building:

```bash
# 1. Check for new revisions via USITC API
curl -s "https://hts.usitc.gov/reststop/releaseList" | head -c 500

# 2. Download new JSON
Rscript src/02_download_hts.R --dry-run    # Check what's missing
Rscript src/02_download_hts.R              # Download missing files

# 3. Regenerate 301 product lists and floor exemptions from Ch99 PDF
Rscript src/scrape_us_notes.R --all

# 4. Add rows to config/revision_dates.csv for new revisions

# 5. Run full pipeline
Rscript src/00_build_timeseries.R
```

---

## Methodological Details

### Stacking Formulas

Tariff authorities overlap. Section 232 and IEEPA reciprocal are **mutually exclusive** (232 takes precedence). For derivative 232 products (`metal_share < 1.0`), IEEPA reciprocal/fentanyl apply to the non-metal portion of customs value. Implemented in `helpers.R:apply_stacking_rules()` and `06_calculate_rates.R`.

**China with 232 product:**
```
total = rate_232 + rate_ieepa_recip × nonmetal_share + rate_ieepa_fent + rate_301 + rate_s122 + rate_other
```

**China without 232 product:**
```
total = rate_ieepa_recip + rate_ieepa_fent + rate_301 + rate_s122 + rate_other
```

**Other countries with 232 product:**
```
total = rate_232 + (rate_ieepa_recip + rate_ieepa_fent) × nonmetal_share + rate_s122 + rate_other
```

**Other countries without 232 product:**
```
total = rate_ieepa_recip + rate_ieepa_fent + rate_s122 + rate_other
```

Where `nonmetal_share = 1 - metal_share` when `rate_232 > 0` and `metal_share < 1.0`, else `0`. For base 232 products (steel, aluminum, autos, copper), `metal_share = 1.0` so `nonmetal_share = 0`, preserving the mutual exclusion. For derivative products (~130 aluminum-containing articles), `metal_share < 1.0` (default 0.50) so IEEPA/fentanyl apply to the remaining portion.

**USMCA exemption:** Products with "S"/"S+" in `special` field get IEEPA reciprocal and fentanyl zeroed out. Section 232 still applies regardless of USMCA status.

**China fentanyl exclusion:** China/Hong Kong are excluded from blanket fentanyl application because their 9903.90.xx footnote rates already incorporate fentanyl — adding it would double-count ~10pp.

### Section 232 Coverage

| Product Scope | Ch99 Range | Identification | Coverage |
|--------------|-----------|----------------|----------|
| Steel (Ch. 72–73) | 9903.80–82.xx | Blanket chapter match | ~1,800 products |
| Aluminum (Ch. 76) | 9903.85.xx | Blanket chapter match | ~600 products |
| Autos (heading 8703 + light trucks) | 9903.94.xx | Heading-level prefix match (17 prefixes) | USMCA-exempt |
| Copper (headings 7406–7419) | 9903.78.xx | Heading-level prefix match (11 prefixes) | Not USMCA-exempt |
| Aluminum derivatives (~130 products) | 9903.85.04/.07/.08 | Blanket product match from `s232_derivative_products.csv` | Metal content share applies |

**Metal content for derivatives:** The tariff applies only to the metal content portion of customs value. Configurable share methods: flat (default 50%), CBO (product-level buckets from `resources/cbo/`), BEA (future). See `config/policy_params.yaml:metal_content`.

**232 country exemptions (pre-March 2025):** Before Proclamation 10896, CA/MX, EU-27, UK, Japan, South Korea, Australia, Brazil, Argentina, and Ukraine had TRQ/quota agreements at 0%. Russia had a permanent 200% override. These are not encoded in the HTS JSON and are configured in `section_232_country_exemptions` in `policy_params.yaml`. Modeled as binary (0% or override), matching Tariff-ETRs methodology.

### Section 301 Product Lists and Aggregation

| Ch99 Range | HTS Note | Linkage | Products |
|-----------|----------|---------|----------|
| 9903.86–88.xx | US Note 20 | Footnotes + blanket list (Lists 1–4B) | ~10,200 via `s301_product_lists.csv` |
| 9903.89.xx | US Note 21 | Description-defined (List 4A exclusions) | Not yet captured |
| 9903.91.xx | US Note 31 | Footnotes + blanket list (Biden acceleration) | ~390 via `s301_product_lists.csv` |
| 9903.92.xx | US Note 31 | Footnotes + blanket list (crane duties) | ~20 via `s301_product_lists.csv` |

**Generation-based rate stacking:** MAX within each generation (original Trump 9903.88.xx / Biden 9903.91–92.xx), SUM across generations. This correctly handles products on both Trump and Biden lists (e.g., Trump List 3 at 25% + Biden at 25% = 50% total).

**Biden-only 301 steel products** (ch72/73/76) are genuinely not on Trump lists; their 301 rate is 25%, not 50%.

### IEEPA Rate Type Classification

When both surcharge and floor entries exist for the same country/phase, floor entries take priority (`type_priority` in summarization):

- **Surcharge** (most countries): flat additional duty (e.g., +20%)
- **Floor** (EU, Japan, S. Korea, Switzerland, Liechtenstein): minimum rate — only adds duty if `base_rate < floor_rate`. Formula: `max(0, floor_rate - base_rate)`
- **Passthrough** (`base_rate >= floor_rate`): no additional duty

### IEEPA Duty-Free Treatment

Configurable via `ieepa_duty_free_treatment` in `policy_params.yaml`. Options: `'all'` (default, apply IEEPA to all products) or `'nonzero_base_only'` (skip products with zero MFN base rate, matching TPC methodology; adds ~8.5pp exact match at rev_32).

### Floor Country Product Exemptions

Per-revision floor exemptions loaded via `load_revision_floor_exemptions()` in `helpers.R`, with fallback for revisions without specific exemption files. Stored in `data/us_notes/floor_exempt_{revision}.csv` (with fallback to `resources/floor_exempt_products.csv`).

### Swiss Framework Override

EO 14346: date-bounded override in `swiss_framework` config. Switzerland and Liechtenstein receive a 15% floor structure. `finalized: false` until confirmed; originally set to expire March 31, 2026.

### Section 122 Expiry Enforcement

The Trade Act §122 limits blanket tariffs to 150 days. Enforcement at three levels:

1. **Build time** (`06_calculate_rates.R`): revisions after expiry date get `rate_s122 = 0`
2. **Daily aggregates** (`09_daily_series.R`): interval splitting at the expiry boundary
3. **Queries** (`get_rates_at_date()` in `helpers.R`): zeroes Section 122 for post-expiry dates

Controlled by `section_122` config in `policy_params.yaml` with `effective`, `expiry`, and `finalized` fields.

### USMCA Eligibility

USMCA eligibility is determined from the HTS `special` field: products with "S" or "S+" in any parenthesized group are flagged as eligible. `extract_usmca_eligibility()` checks all parenthesized groups (fixed: S+ in secondary groups is now detected). ~24% of products are USMCA-eligible.

USMCA-eligible products for Canada/Mexico get IEEPA reciprocal and fentanyl zeroed out. Section 232 still applies. This is a binary classification — no utilization-rate adjustment (see [Current Issues](#current-issues)).

### Fentanyl Carve-Outs

`extract_ieepa_fentanyl_rates()` returns all entries with an `entry_type` column (`'general'`/`'carveout'`). Rates: Mexico +25%, Canada +35% (raised from 25% at ~rev_17). Carve-outs: Canada energy/minerals +10%, Canada/Mexico potash +10%. Product list in `resources/fentanyl_carveout_products.csv` (308 HTS-8 prefixes).

For countries with multiple fentanyl entries, the first entry per country (by Ch99 code order) is the general rate; later entries are exceptions.

### IEEPA Phase/Rate Selection

- **Phase 2 over Phase 1:** When both phases exist for a country, prefer Phase 2 (supersedes with updated rates)
- **Within a phase:** Pick best entry — floor > surcharge > highest rate
- **Across phases:** Phase 2 + country-specific EO rates sum (e.g., India Phase 2 +25% + EO +25% = +50%)

### Hardcoded Elements

| Constant | Location | Value | Used For |
|----------|----------|-------|----------|
| `CTY_CHINA` | `policy_params.yaml` | `'5700'` | Stacking rules, fentanyl exclusion |
| `CTY_CANADA` | `policy_params.yaml` | `'1220'` | USMCA exemption |
| `CTY_MEXICO` | `policy_params.yaml` | `'2010'` | USMCA exemption |
| `CTY_HK` | `policy_params.yaml` | `'5820'` | Fentanyl exclusion |
| `EU27_CODES` | `policy_params.yaml` | 27 Census codes | Expanding "European Union" Ch99 entries |
| `ISO_TO_CENSUS` | `policy_params.yaml` | 12 mappings | Converting Ch99 country descriptions to Census codes |

---

## Validation

Comparison against TPC benchmark data, matched by revision-to-TPC-date:

| Revision | TPC Date | N Comparisons | Exact (<0.5pp) | Within 2pp | Mean Abs Diff | Mean Diff |
|----------|----------|---------------|----------------|------------|---------------|-----------|
| rev_6 | 2025-03-17 | 62,205 | 61.4% | 61.6% | 5.0 pp | -1.5 pp |
| rev_10 | 2025-04-17 | 300,126 | 86.4% | 86.4% | 2.0 pp | +0.4 pp |
| rev_17 | 2025-07-17 | 299,211 | 77.1% | 77.5% | 3.4 pp | -1.3 pp |
| rev_18 | 2025-10-17 | 298,368 | 61.0% | 61.8% | 5.8 pp | -1.9 pp |
| rev_32 | 2025-11-17 | 298,341 | 66.1% | 67.0% | 4.9 pp | -0.2 pp |

Regenerate with: `Rscript src/test_tpc_comparison.R`

**Best-matching countries** (rev_32, surcharge IEEPA): Madagascar 94%, Bangladesh 94%, Tunisia 92%, Nepal 91%, Pakistan 89%, Mauritius 89%, Armenia 88%, Morocco 87%, Kenya 87%, Sri Lanka 87%.

**Discrepancy patterns** (rev_32):
- **We exceed TPC** (19.9% of products, mean +11.8pp): Mostly IEEPA reciprocal for countries where our rate exceeds TPC's.
- **TPC exceeds us** (13.1% of products, mean -19.6pp): ~16K products with shortfall near 25pp; ~2,031 China products (mean -23pp).

**Key gap sources:** (1) China+232 reciprocal stacking methodology; (2) EU/Japan/Korea floor residual; (3) USMCA classification mismatch for CA/MX.

---

## Current Issues

### 1. China+232 reciprocal stacking (~920 products, ~25pp gap)

For Chinese products subject to Section 232 (steel, aluminum, copper), TPC stacks IEEPA reciprocal on top of 232 (e.g., 232(25%) + recip(25%) + fent(10%) + 301(25%) = 85%). We apply mutual exclusion per Tariff-ETRs methodology: 232 takes precedence, so reciprocal contributes 0pp. This is a methodological difference, not a data gap — our approach follows the legal structure (Section 232 and IEEPA are separate authorities).

### 2. Section 301 exclusions (9903.89.xx)

Some 9903.89.xx exclusions reference US Note product lists and are not captured. Excluded products may incorrectly receive the base 301 rate. Low impact (~61 products).

### 3. China IEEPA reciprocal rate discrepancy

China's IEEPA reciprocal is parsed from 9903.01.63 (Phase 1, +34%). TPC data implies a 25% rate, likely reflecting the May 2025 Geneva agreement. The HTS still encodes the pre-negotiation statutory rate.

### 4. EU floor rate residual (~4pp systematic)

EU countries show ~35–42% exact match with ~4pp mean excess. The floor formula is correct, but residual discrepancies remain — possibly from TPC using different floor mechanics or base rate differences.

### 5. USMCA binary vs. utilization-adjusted

USMCA eligibility from the HTS `special` field is binary. In practice, not all trade in an eligible product claims the preference (TPC uses product-level utilization rates, median ~50% for CA/MX). A utilization-rate adjustment would improve accuracy.

### 6. Section 122 expiry uncertainty

The 150-day statutory limit expires approximately July 25, 2026. Whether Congress extends the authority or the administration shifts to an alternative legal basis is unknown. The `finalized` flag controls behavior.

---

## Acknowledgments

We thank the [Urban-Brookings Tax Policy Center](https://www.taxpolicycenter.org/) for generously providing a snapshot of their tariff rate data for validation purposes.

---

## Related Projects

- [Tariff-Model](https://github.com/Budget-Lab-Yale/Tariff-Model) — Economic impact modeling
- [Tariff-ETRs](https://github.com/Budget-Lab-Yale/Tariff-ETRs) — Effective tariff rate calculations
