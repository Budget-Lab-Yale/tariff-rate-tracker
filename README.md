# Tariff Rate Tracker

An R-based system for constructing statutory U.S. tariff rates at the HTS-10 x country level, using the USITC Harmonized Tariff Schedule JSON archives as the primary source. Processes all HTS revisions sequentially to build a time series of tariff rates across 2025. Designed to produce outputs compatible with the Yale Budget Lab Tariff-Model.

## Status

**In development.** The pipeline processes 34 HTS JSON archives (basic + revisions 1-32 + 2026 basic) to build per-revision rate snapshots and a combined time series. All rates are derived from HTS source data -- no external rate inputs. Current validation against TPC benchmark data shows 76% exact match at rev_10 (post-Liberation Day), declining to 46% at rev_32 as the gap from missing Section 301 product lists grows. Best-matching countries (surcharge IEEPA) hit 80-92%. See [Validation Status](#validation-status) and [Known Issues](#known-issues).

## How It Works

The tracker builds a panel of statutory tariff rates from HTS JSON archives. The 2025 tariff measures (Section 232, 301, IEEPA reciprocal/fentanyl) are encoded as **Chapter 99 provisions** in the HTS. These link to product lines in three ways:

1. **Footnote references** (Section 301, IEEPA fentanyl): Product lines contain footnotes like "See 9903.88.15" that point to Ch99 subheadings specifying the additional duty rate and country scope.
2. **Chapter-based coverage** (Section 232): Ch99 entries describe which products they cover by referencing HTS notes (e.g., "note 16 to this subchapter") rather than individual product lines. Products are identified by HTS chapter -- Ch. 72-73 for steel, Ch. 76 for aluminum.
3. **Universal application with country-specific rates** (IEEPA reciprocal/fentanyl): Entries in 9903.01-02.xx apply to all products from a given country. Each entry's description names the countries and the `general` field encodes the rate. Some countries (EU, Japan, South Korea) use a floor structure instead of a surcharge.

A simple diff of base rates across HTS revisions would miss all three mechanisms.

### Pipeline Steps (per revision)

1. **Parse Chapter 99 entries** -- extracts additional duty rates, authority type, and country scope from each subheading
2. **Parse product lines** -- extracts base MFN rates and Chapter 99 footnote references
3. **Extract policy parameters** -- IEEPA reciprocal rates, fentanyl rates, Section 232 rates, and USMCA eligibility directly from the JSON
4. **Calculate total rates** per HTS-10 x country using stacking rules
5. **Validate** against TPC benchmark data (for revisions with a matching TPC date)

The orchestrator repeats these steps for each HTS revision, producing per-revision snapshots and tracking deltas between revisions.

## Code Guide

### Timeseries Pipeline (active)

| File | Purpose |
|------|---------|
| `00_build_timeseries.R` | **Main orchestrator.** Iterates over all HTS revisions, builds per-revision rate snapshots, computes deltas, runs TPC validation, and combines into a long-format time series. Supports incremental updates via `--start-from`. |
| `01_scrape_revision_dates.R` | Scrapes USITC for revision effective dates. |
| `02_download_hts.R` | Downloads missing HTS JSON archives from USITC. |
| `03_parse_chapter99.R` | Parses all Chapter 99 entries from HTS JSON. Extracts rates from the `general` field, infers authority type from the subheading range, and parses country scope from the `description` field. |
| `04_parse_products.R` | Parses HTS-10 product lines. Extracts base MFN rates and Chapter 99 footnote references. |
| `05_parse_policy_params.R` | Extracts policy parameters directly from HTS JSON: IEEPA country-specific reciprocal rates (with rate_type classification and EU expansion), IEEPA fentanyl rates, Section 232 rates (including 9903.94 autos), and USMCA eligibility. |
| `06_calculate_rates.R` | Joins products to Chapter 99 authorities via footnote refs. Applies IEEPA reciprocal/fentanyl as blanket country-level tariffs (with product exemptions). Identifies Section 232 products by chapter and heading prefix. Applies stacking rules. Expands to the country dimension. |
| `07_validate_tpc.R` | Compares calculated rates against TPC benchmark data at the HTS-10 x country x date level. Reports match rates and identifies systematic discrepancies. |
| `08_apply_scenarios.R` | Counterfactual scenario system. Zeros out selected authority columns and recomputes totals. Config in `config/scenarios.yaml`. |
| `09_diagnostics.R` | Validation and debugging utilities: Section 301 coverage gap report, China IEEPA tracking, per-revision summary. |
| `helpers.R` | Shared utility functions (rate parsing, HTS normalization, footnote extraction, file I/O). |
| `10_weighted_etr.R` | Import-weighted effective tariff rate analysis. Uses `get_rates_at_date()` from `11_daily_series.R` to query the built timeseries, calculates weighted average ETRs by authority/partner/sector, produces comparison plots with TPC overlays. |
| `11_daily_series.R` | Daily rate series: `get_rates_at_date(ts, date)` for point-in-time queries, `build_daily_aggregates()` for pre-computed daily ETRs, `expand_to_daily()` for on-demand expansion. |

### Single-Revision Pipeline

| File | Purpose |
|------|---------|
| `run_pipeline.R` | Runs steps 1-4 for a single revision. Useful for quick checks. |
| `calculate_rates_v3.R` | Streamlined single-revision rate calculator. Handles surcharge/floor/passthrough countries, China Phase 1 reciprocal, and Biden Section 301 acceleration. |
| `test_tpc_comparison.R` | Standalone TPC comparison across all 5 validation dates. Produces detailed diagnostics by revision, country, and discrepancy pattern. |

### Legacy (v1, config-driven)

| File | Purpose |
|------|---------|
| `run_daily.R` | Original orchestrator using manual authority mapping. |
| `01_ingest_hts.R` - `05_write_outputs.R` | v1 numbered pipeline steps. |
| `calculate_rates_v2.R`, `calculate_rates_from_csv.R`, `calculate_rates_timeseries.R` | Earlier calculator iterations. |
| `compare_revisions.R` | Standalone revision comparison (functionality now in `00_build_timeseries.R`). |

## Usage

```bash
# Full backfill: process all 34 HTS revisions
Rscript src/00_build_timeseries.R

# Incremental: process only revisions after rev_31
Rscript src/00_build_timeseries.R --start-from rev_31

# Single-revision rate calculation
Rscript src/run_pipeline.R
```

### Incremental Update Workflow

```bash
# 1. Download new JSON
# hts.usitc.gov/export?format=json → data/hts_archives/hts_2025_rev_33.json

# 2. Add row to config/revision_dates.csv
# rev_33,2025-12-15,

# 3. Run incremental (loads cached state from rev_32, processes only rev_33)
Rscript src/00_build_timeseries.R --start-from rev_32
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
| **Section 201 (safeguards)** | `rate_other` | Varies | Entire year; predates 2025 | Varies (washing machines, solar) |

**Key transitions visible across revisions:**
- `basic` -> `rev_6`: Only 232, 301, and early fentanyl entries. No IEEPA reciprocal yet.
- `rev_7`: IEEPA reciprocal Phase 1 appears (~60 countries with "Liberation Day" rates).
- `~rev_17`: 232 rate increase (25% -> 50%), Canada fentanyl increase (25% -> 35%).
- `rev_18`: Phase 1 terminated (except China); Phase 2 reinstated with updated rates.

### 2. HTS-to-Authority Mapping

Each authority has a different mechanism for linking Ch99 entries to products:

#### Section 301 -- Footnote references (partial coverage)

| Ch99 Range | HTS Note | Linkage | Products |
|-----------|----------|---------|----------|
| 9903.86-88.xx | US Note 20 | Product footnotes "See 9903.88.xx" | ~7,200 via footnotes |
| 9903.89.xx | US Note 21 | Description-defined (List 4A) | 0 with footnotes; ~5,000 in US Note list |
| 9903.91.xx | US Note 31 | Product footnotes | ~382 (Biden acceleration) |
| 9903.92.xx | US Note 31 | Product footnotes | ~20 (crane duties) |

**Extraction:** `03_parse_chapter99.R` parses each 9903.xx.xx entry's `general` field for the rate and `description` for country scope. `04_parse_products.R` extracts footnote references from each product's `footnotes` field. `06_calculate_rates.R` joins on the Ch99 code.

**Gap:** Products defined by US Note 20/21 product lists (~5,000) are not captured because those products lack direct footnote references to Ch99 entries. The linkage is implicit via the Note.

#### Section 232 -- Chapter/heading-based identification

| Ch99 Range | Product Scope | Linkage |
|-----------|---------------|---------|
| 9903.80-82.xx | Steel (HTS Ch. 72-73) | **Blanket chapter match**: chapters 72-73 |
| 9903.85.xx | Aluminum (HTS Ch. 76) | **Blanket chapter match**: chapter 76 |
| 9903.83-84.xx | Autos (footnote-linked) | Product footnotes |
| 9903.94.xx | Autos (HTS heading 8703 + light trucks) | **Blanket heading match**: 13 passenger auto prefixes + 4 light truck prefixes |
| (copper) | Copper (HTS headings 7406-7419) | **Blanket heading match**: 11 heading prefixes |

**Extraction:** `05_parse_policy_params.R:extract_section232_rates()` reads 9903.80-85.xx and 9903.94.xx entries and returns rates + country exemptions per revision. `06_calculate_rates.R` applies blanket 232 tariffs using variable-length prefix matching from `config/policy_params.yaml:section_232_chapters` (steel/aluminum) and `section_232_headings` (autos, copper). USMCA exemptions are configured per heading group (`usmca_exempt: true` for autos, `false` for copper).

**Gap:** Derivative products -- goods in other chapters containing steel/aluminum components (referenced via "note 16(a)(ii)") -- are captured when linked via product footnotes, but not yet covered by blanket matching. TPC assumes 50% metal content for these.

#### IEEPA Reciprocal -- Blanket country-level tariff

| Ch99 Range | Phase | Linkage |
|-----------|-------|---------|
| 9903.01.43-75 | Phase 1 ("Liberation Day") | **Blanket**: applies to ALL products for named countries |
| 9903.01.63 | Phase 1 (China only) | **Blanket**: never terminated; +34% on all Chinese products |
| 9903.02.02-81 | Phase 2 (reinstated) | **Blanket**: applies to ALL products for named countries |

**Extraction:** `05_parse_policy_params.R:extract_ieepa_rates()` parses each entry's description for country names and `general` field for the rate. "European Union" entries are expanded to 27 member states. Rate types are classified:
- **Surcharge** (most countries): flat additional duty (e.g., +20%)
- **Floor** (EU, Japan, S. Korea): minimum rate (e.g., 15% floor -- only adds duty if base_rate < 15%)
- **Passthrough** (base_rate >= floor): no additional duty

`06_calculate_rates.R` applies these rates to all products for each country, with no footnote linkage needed. ~1,087 products are exempt from IEEPA reciprocal (Annex A / US Note 2 subdivision (v)(iii)); the exempt list is maintained in `resources/ieepa_exempt_products.csv`.

#### IEEPA Fentanyl -- Blanket country-level tariff

| Ch99 Range | Scope | Linkage |
|-----------|-------|---------|
| 9903.01.01-24 | Canada, Mexico, China, Hong Kong | **Blanket** for CA/MX; China/HK **excluded** from blanket (see Hardcoded Elements) |

**Extraction:** `05_parse_policy_params.R:extract_ieepa_fentanyl_rates()` parses 9903.01.01-24 entries. For countries with multiple entries (general rate + anti-transshipment penalties), takes the FIRST entry per country (by Ch99 code order), which is the general rate.

`06_calculate_rates.R` applies fentanyl as a blanket tariff to all products for Canada/Mexico. USMCA-eligible products are exempt.

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
| Steel = Ch. 72-73 | `06_calculate_rates.R` | Chapter-level prefix match | Covers ~1,800 products |
| Aluminum = Ch. 76 | `06_calculate_rates.R` | Chapter-level prefix match | Covers ~600 products |
| Autos = heading 8703 + light trucks | `06_calculate_rates.R` | Heading-level prefix match (13+4 prefixes) | USMCA-exempt; from `policy_params.yaml` |
| Copper = headings 7406-7419 | `06_calculate_rates.R` | Heading-level prefix match (11 prefixes) | Not USMCA-exempt; from `policy_params.yaml` |
| IEEPA exempt products | `06_calculate_rates.R` | HTS10 in `resources/ieepa_exempt_products.csv` | ~1,087 Annex A products; IEEPA recip zeroed out |
| USMCA eligibility | `05_parse_policy_params.R` | `special` field contains "S" or "S+" | Binary flag; no utilization-rate adjustment |

#### Stacking Rules

| Rule | Location | Logic | Notes |
|------|----------|-------|-------|
| 232/IEEPA mutual exclusion | `helpers.R:apply_stacking_rules()` | 232 > 0 → use 232, else use IEEPA recip | 232 takes precedence over IEEPA reciprocal |
| China stacking | `helpers.R:apply_stacking_rules()` | `232 + fent + 301 + s122 + other` (or `recip + fent + 301 + s122 + other`) | Only China gets 301 added to stack |
| Others stacking (with 232) | `helpers.R:apply_stacking_rules()` | `232 + s122 + other` | Fentanyl does NOT stack on 232 for non-China |
| Others stacking (no 232) | `helpers.R:apply_stacking_rules()` | `recip + fent + s122 + other` | Full IEEPA stack applies |
| USMCA exemption | `06_calculate_rates.R` | CA/MX USMCA products: `rate_ieepa_recip = 0`, `rate_ieepa_fent = 0` | 232 still applies to USMCA products |
| IEEPA product exemptions | `06_calculate_rates.R` | ~1,087 products exempt from IEEPA reciprocal | From `resources/ieepa_exempt_products.csv` (Annex A) |
| China fentanyl exclusion | `06_calculate_rates.R` | China/HK excluded from blanket fentanyl | 9903.90.xx rates already incorporate fentanyl |

#### Phase/Rate Selection

| Rule | Location | Logic | Notes |
|------|----------|-------|-------|
| Phase 2 over Phase 1 | `03_calculate_rates.R:485-491` | When both phases exist for a country, prefer Phase 2 | Phase 2 supersedes Phase 1 with updated rates |
| Fentanyl: first entry wins | `05_parse_policy_params.R` | `arrange(ch99_code) %>% summarise(rate = first(rate))` | First entry = general rate; later entries = exceptions (anti-transshipment) |
| 232 "all" over "all_except" | `05_parse_policy_params.R:574-580` | Prefer `country_type == 'all'` entry | 9903.80.61 (exemptions revoked) takes precedence over 9903.80.01 |

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

Tariff authorities overlap. Section 232 and IEEPA reciprocal are **mutually exclusive** (232 takes precedence). Fentanyl only stacks on 232 for China.

**China with 232 product:**
```
total = rate_232 + rate_ieepa_fent + rate_301 + rate_s122 + rate_other
```

**China without 232 product:**
```
total = rate_ieepa_recip + rate_ieepa_fent + rate_301 + rate_s122 + rate_other
```

**Other countries with 232 product:**
```
total = rate_232 + rate_s122 + rate_other
# Fentanyl does NOT stack on 232 for non-China countries
```

**Other countries without 232 product:**
```
total = rate_ieepa_recip + rate_ieepa_fent + rate_s122 + rate_other
```

**Canada/Mexico USMCA exemption:** Products with "S"/"S+" in `special` field get IEEPA reciprocal and fentanyl zeroed out. Section 232 still applies regardless of USMCA status.

**China fentanyl exclusion:** China/Hong Kong are excluded from blanket fentanyl application because their 9903.90.xx footnote rates already incorporate fentanyl -- adding it would double-count ~10pp.

## Data

### Input

- **HTS JSON archives** (`data/hts_archives/`): Downloaded from `hts.usitc.gov/export?format=json`. Currently holds the 2025 basic edition plus revisions 1-32 and the 2026 basic edition. Not committed to git due to size (~80MB each).
- **TPC benchmark data** (`data/tpc/tariff_by_flow_day.csv`): Tariff-Model team's estimated tariff rate changes by HTS-10, country, and date. ~250K rows across 42 countries and 5 snapshot dates (2025-03-17, 2025-04-17, 2025-07-17, 2025-10-17, 2025-11-17). **Used for validation only, never as rate input.** See `data/tpc/tpc_notes.txt` for assumptions (50% metal share for derivatives, 40% generic drug share, USMCA share adjustment for Canada/Mexico).

### Configuration

- `config/policy_params.yaml`: All policy constants (country codes, authority ranges, 232 chapter/heading coverage, floor rates, 301 rates). Single source of truth loaded by `helpers.R::load_policy_params()`.
- `config/revision_dates.csv`: Maps each HTS revision to its effective date and (where applicable) the corresponding TPC validation date. 37 rows covering basic through 2026_basic.
- `config/scenarios.yaml`: Counterfactual scenario definitions (baseline, no_ieepa, no_301, no_232, pre_2025, etc.). Used by `07_apply_scenarios.R`.
- `config/authority_mapping.yaml`: Manual mapping of ~28 key Chapter 99 subheadings. Used by v1 pipeline only.
- `config/country_rules.yaml`: Country groups and stacking rules. Used by v1 pipeline only.

### Reference

- `resources/census_codes.csv`: 240 Census country codes.
- `resources/hs10_gtap_crosswalk.csv`: 18,700-row crosswalk from HTS-10 to GTAP sectors.
- `resources/country_partner_mapping.csv`: 50-row mapping from Census codes to partner aggregation.
- `resources/ieepa_exempt_products.csv`: 1,087 HTS-10 codes exempt from IEEPA reciprocal (Annex A / US Note 2 subdivision (v)(iii)). Derived from Tariff-ETRs config.

## Validation Status

Comparison of timeseries pipeline output against TPC benchmark, matched by revision-to-TPC-date mapping:

| Revision | TPC Date | N Comparisons | Exact (<0.5pp) | Within 2pp | Mean Abs Diff | Mean Diff |
|----------|----------|---------------|----------------|------------|---------------|-----------|
| rev_6 | 2025-03-17 | 45,756 | 54.5% | 55.9% | 9.4 pp | +1.1 pp |
| rev_10 | 2025-04-17 | 240,469 | 80.1% | 80.4% | 4.2 pp | -0.6 pp |
| rev_17 | 2025-07-17 | 239,928 | 70.2% | 70.5% | 5.1 pp | -1.3 pp |
| rev_18 | 2025-10-17 | 267,603 | 49.2% | 50.2% | 8.2 pp | -1.6 pp |
| rev_32 | 2025-11-17 | 267,603 | 45.8% | 47.2% | 9.0 pp | -0.2 pp |

Regenerate with: `Rscript test_tpc_comparison.R`

**Best-matching countries** (rev_32): Madagascar 94%, Bangladesh 94%, Tunisia 90%, Pakistan 88%, Mauritius 88%, Sri Lanka 86%, Cambodia 83%, Indonesia 82%, Vietnam 79%, Turkey 79%.

**Worst-matching countries** (rev_32): Switzerland 0.1%, Hong Kong 3.3%, India 2.9%, Singapore 1.9%, Brazil 7.5%.

**Discrepancy patterns** (rev_32):
- **We are higher than TPC** (32.3% of products, mean +13.6pp): Mostly IEEPA reciprocal for countries where our rate exceeds TPC's. Includes 79K products with IEEPA recip > 0.
- **TPC is higher than us** (20.6% of products, mean -22.1pp): ~26K products with shortfall near 25pp -- consistent with missing Section 301 coverage. ~5,800 China products where TPC > us, of which ~4,900 have our rate_301 = 0.
- **China match**: At rev_32, our mean rate (40.4%) vs TPC (42.2%), diff -1.8pp. Exact match is 0% due to China IEEPA reciprocal discrepancy (34% statutory vs 25% TPC) offsetting missing 301 coverage at the product level.

The largest gap source is **missing Section 301 coverage**: ~22K product-country pairs (most from ~5,000 China products) where TPC shows +25% that we don't capture. These products are defined by US Note 20/21/31 product lists, referenced by description text rather than individual product footnotes.

## Known Issues

### 1. Section 301 coverage gap (~5,000 China products)

Section 301 tariffs on China are defined by US Note 20 (original lists), US Note 21 (List 4A), and US Note 31 (Biden acceleration). The HTS encodes this via description references ("articles the product of China, as provided for in U.S. note 20") rather than per-product footnotes. Our parser captures products that have direct footnote references to 9903.88.xx/9903.91.xx entries (~7,200 products) but misses products defined only by the US Note product lists (~5,000 additional products). This is the single largest TPC gap source.

### 2. China's IEEPA reciprocal rate discrepancy with TPC

China's IEEPA reciprocal is parsed from 9903.01.63 (Phase 1, +34%). TPC data implies a 25% rate. The discrepancy likely reflects the May 2025 US-China bilateral agreement that reduced the effective rate. The HTS Rev 32 still encodes the pre-negotiation statutory rate.

### 3. EU/Japan/South Korea floor rate structure

These countries have a split rate structure: products with base rates >= 15% get no additional duty (passthrough), while products with base rates < 15% get a floor to 15%. The code handles this via the `rate_type` field, but some floor calculations may be inaccurate when the product base rate is missing or incorrectly parsed.

### 4. Section 232 derivative products partially handled

Steel (Ch. 72-73), aluminum (Ch. 76), autos (heading 8703 + light trucks), and copper (headings 7406-7419) are covered by blanket prefix matching. Derivative products in other chapters containing steel/aluminum components are captured when linked via product footnotes but not by blanket matching. TPC assumes a 50% metal share for derivatives. The Ch99 entries reference these via "note 16(a)(ii)" in the HTS.

### 5. USMCA eligibility is binary, not utilization-adjusted

USMCA eligibility from the HTS `special` field gives a binary flag. In practice, not all trade in an eligible product claims USMCA preference. A utilization-rate adjustment would improve accuracy for Canada/Mexico.

## Resolved Issues

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

- **HTS Archives**: [USITC HTS Online](https://hts.usitc.gov/)
- **Census Country Codes**: [Census Bureau](https://www.census.gov/foreign-trade/schedules/b/countrycodes.html)
- **Federal Register**: Proclamations and executive orders (manual curation)

## Acknowledgments

We thank the [Urban-Brookings Tax Policy Center](https://www.taxpolicycenter.org/) for generously providing a snapshot of their tariff rate data for validation purposes.

## Related Projects

- [Tariff-Model](https://github.com/Budget-Lab-Yale/Tariff-Model) - Economic impact modeling
- [Tariff-ETRs](https://github.com/Budget-Lab-Yale/Tariff-ETRs) - ETR calculations
