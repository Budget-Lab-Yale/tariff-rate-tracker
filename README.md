# Tariff Rate Tracker

An R-based system for constructing statutory U.S. tariff rates at the HTS-10 x country level, using the USITC Harmonized Tariff Schedule JSON archives as the primary source. Designed to produce outputs compatible with the Yale Budget Lab Tariff-Model.

## Status

**In development.** The core pipeline parses HTS data, extracts Chapter 99 additional duties, and calculates effective tariff rates by product and country. All rates are derived from HTS source data — no external rate inputs. Current validation against benchmark data (TPC/Tariff-Model) shows 90% match for early-2025 tariff levels and 52-55% for late 2025 (see [Validation Status](#validation-status) and [Known Issues](#known-issues)).

## How It Works

The tracker builds a panel of statutory tariff rates from HTS JSON archives. The 2025 tariff measures (Section 232, 301, IEEPA reciprocal/fentanyl) are encoded as **Chapter 99 provisions** in the HTS. These link to product lines in two ways:

1. **Footnote references** (Section 301, IEEPA fentanyl): Product lines contain footnotes like "See 9903.88.15" that point to Ch99 subheadings specifying the additional duty rate and country scope.
2. **Chapter-based coverage** (Section 232): Ch99 entries describe which products they cover by referencing HTS notes (e.g., "note 16 to this subchapter") rather than individual product lines. Products are identified by HTS chapter — Ch. 72-73 for steel, Ch. 76 for aluminum.
3. **Universal application with country-specific rates** (IEEPA reciprocal): Entries in 9903.01-02.xx apply to all products from a given country. Each entry's description names the countries and the `general` field encodes the rate. Some countries (EU, Japan, South Korea) use a floor structure instead of a surcharge.

A simple diff of base rates across HTS revisions would miss all three mechanisms.

### Pipeline Steps

1. **Parse Chapter 99 entries** from the HTS JSON — extracts additional duty rates, authority type, and country scope from each subheading
2. **Parse product lines** (non-Chapter 99) — extracts base MFN rates and Chapter 99 footnote references
3. **Link products to authorities** — matches footnote references to Ch99 entries, and identifies Section 232 products by HTS chapter
4. **Calculate total rates** per HTS-10 x country using stacking rules from Tariff-ETRs
5. **Validate** against TPC benchmark data

## Code Guide

There are two generations of code in `src/`. The **v2 pipeline** (newer) is the active one.

### v2 Pipeline (active)

| File | Purpose |
|------|---------|
| `run_pipeline.R` | Orchestrator. Runs steps 1-4 sequentially. |
| `01_parse_chapter99.R` | Parses all Chapter 99 entries from HTS JSON. Extracts rates from the `general` field (e.g., "the duty + 25%" -> 0.25), infers authority type from the subheading range (9903.80-82 = steel 232, 9903.83-84 = auto 232, 9903.85 = aluminum 232, 9903.86-89 = Section 301, 9903.90-96 = IEEPA), and parses country scope from the `description` field. |
| `02_parse_products.R` | Parses HTS-10 product lines. Extracts base MFN rates and Chapter 99 footnote references (the `footnotes` field contains "See 9903.xx.xx" cross-references). |
| `03_calculate_rates.R` | Joins products to Chapter 99 authorities via footnote refs. Applies stacking rules (see below). Expands to the country dimension. |
| `04_validate_tpc.R` | Compares calculated rates against TPC benchmark data at the HTS-10 x country x date level. Reports match rates and identifies systematic discrepancies. |
| `05_parse_policy_params.R` | Extracts policy parameters directly from HTS JSON: (1) IEEPA country-specific reciprocal rates from 9903.01-02.xx entries, with rate_type classification (surcharge vs floor vs passthrough), EU expansion to 27 member states; (2) USMCA eligibility from the `special` field ("S"/"S+" program codes). |
| `calculate_rates_v3.R` | Streamlined rate calculator that loads HTS-derived IEEPA rates and USMCA eligibility from `05_parse_policy_params.R` outputs. Handles surcharge countries (most: +X% additional) and floor countries (EU/Japan/S. Korea: 15% minimum). Used for TPC comparison. |

### v1 Pipeline (original, config-driven)

| File | Purpose |
|------|---------|
| `run_daily.R` | Original orchestrator. Runs the 01-05 numbered steps. |
| `01_ingest_hts.R` | Parses full HTS JSON into a single tibble with rates and footnotes. |
| `02_extract_authorities.R` | Maps Chapter 99 refs to authorities using `config/authority_mapping.yaml`. |
| `03_expand_countries.R` | Expands product-authority rows to the full country dimension using `config/country_rules.yaml`. |
| `04_calculate_rates.R` | Applies stacking rules and computes effective rates. |
| `05_write_outputs.R` | Writes YAML snapshots, change logs, and Tariff-Model exports. |
| `helpers.R` | Shared utility functions (rate parsing, HTS normalization, file I/O). |

### Utilities

| File | Purpose |
|------|---------|
| `compare_revisions.R` | Compares Chapter 99 references and rates across HTS revisions. Tracks when new Ch99 subheadings first appear. |
| `calculate_rates_from_csv.R` | Rate calculator that works from the CSV intermediates. |
| `calculate_rates_timeseries.R` | Computes rates across multiple dates for time-series validation. |
| `calculate_rates_v2.R` | Earlier iteration of the streamlined rate calculator. |

## Authority Classification

Chapter 99 subheadings are classified into authorities by their numeric range:

| Range | Authority | Notes |
|-------|-----------|-------|
| 9903.01.xx | IEEPA reciprocal (Phase 1) | "Liberation Day" rates, terminated |
| 9903.02.xx | IEEPA reciprocal (Phase 2) | Reinstated Aug 7, country-specific surcharges/floors |
| 9903.40.xx - 9903.45.xx | Section 201 | Safeguards |
| 9903.80.xx - 9903.82.xx | Section 232 (steel) | 25% baseline, raised to 50% mid-2025 |
| 9903.83.xx - 9903.84.xx | Section 232 (autos) | |
| 9903.85.xx | Section 232 (aluminum) | 25% baseline, raised to 50% mid-2025 |
| 9903.86.xx - 9903.89.xx | Section 301 (China) | Multiple lists at 7.5-25% |
| 9903.90.xx - 9903.96.xx | IEEPA (other) | Fentanyl, China reciprocal, Russia sanctions |

### Product-to-Authority Linkage

**Section 301 and IEEPA** use footnote references: product lines have footnotes like "See 9903.88.03" that point to the Ch99 entry. The parser extracts these and joins on the Ch99 code.

**Section 232** works differently: Ch99 entries describe covered products via references to HTS notes (e.g., "products enumerated in note 16 to this subchapter") rather than products having footnotes pointing to them. The code identifies 232 products by HTS chapter:
- Chapters 72-73: Iron and steel
- Chapter 76: Aluminum

## Stacking Rules

Tariff authorities overlap. The stacking rules (from Tariff-ETRs) determine how they combine:

**China (Census 5700):**
```
total = max(section_232, ieepa_reciprocal) + ieepa_fentanyl + section_301
```

**Canada/Mexico (Census 1220, 2010):**
```
total = section_232 + (ieepa_reciprocal + ieepa_fentanyl) * usmca_factor
# usmca_factor = 0 if product is USMCA-eligible ("S"/"S+" in special field), 1 otherwise
# Section 232 applies regardless of USMCA status
```

**All other countries:**
```
total = (section_232 > 0 ? section_232 : ieepa_reciprocal + ieepa_fentanyl)
```

## Data

### Input

- **HTS JSON archives** (`data/hts_archives/`): Downloaded from `hts.usitc.gov/export?format=json`. Currently holds the 2025 basic edition plus revisions 1-32 and the 2026 basic edition. Not committed to git due to size.
- **TPC benchmark data** (`data/tpc/tariff_by_flow_day.csv`): Tariff-Model team's estimated tariff rate changes by HTS-10, country, and date. ~250K rows across 42 countries and 5 snapshot dates (2025-03-17, 2025-04-17, 2025-07-17, 2025-10-17, 2025-11-17). Used for validation. See `data/tpc/tpc_notes.txt` for assumptions (50% metal share for derivatives, 40% generic drug share, USMCA share adjustment for Canada/Mexico).

### Intermediate

- `data/processed/chapter99_raw.csv`: All 680 Chapter 99 entries from Rev 32, with parsed rates, authority classification, and country scope.
- `data/processed/products_raw.csv`: ~19,700 HTS-10 product lines with base rates and Chapter 99 footnote references.
- `data/processed/ieepa_country_rates.csv`: IEEPA reciprocal rates by country, parsed from 9903.01-02.xx Ch99 entries. Includes rate, rate_type (surcharge/floor/passthrough), phase, and Census code.
- `data/processed/usmca_products.csv`: USMCA eligibility per HTS-10 product, derived from the `special` field.
- `data/processed/rates_calculated.csv`: Calculated rates for ~18,200 product-country pairs.
- `data/processed/revision_analysis.csv`: Tracks the evolution of Chapter 99 entries across all 32 HTS revisions.

### Configuration

- `config/authority_mapping.yaml`: Manual mapping of ~28 key Chapter 99 subheadings to authority/sub-authority/rate/countries. Used by v1 pipeline.
- `config/country_rules.yaml`: Country groups (USMCA, EU-27, FTA partners), Section 232 exemptions, and stacking rules.

### Reference

- `resources/census_codes.csv`: 240 Census country codes.
- `resources/hs10_gtap_crosswalk.csv`: 18,700-row crosswalk from HTS-10 to GTAP sectors.
- `resources/country_partner_mapping.csv`: 50-row mapping from Census codes to partner aggregation.

## Validation Status

Comparison of `calculate_rates_v3.R` output against TPC benchmark (`output/tpc_comparison_v3.csv`):

| Date | Match Rate (within 2pp) | Mean Abs Diff |
|------|------------------------|---------------|
| 2025-03-17 | 90% | 1.9 pp |
| 2025-04-17 | 80% | 7.4 pp |
| 2025-07-17 | 78% | 3.5 pp |
| 2025-10-17 | 55% | 7.6 pp |
| 2025-11-17 | 52% | 8.5 pp |

All rates are now derived from HTS source data (no TPC-derived inputs). IEEPA country-specific rates are parsed from Ch99 entries (9903.01-02.xx), USMCA eligibility from the product `special` field, and Section 301/232 from footnote references and chapter identification. The March regression vs. the prior version (which calibrated USMCA shares against TPC March data) is expected. The Oct/Nov improvement (+26pp) reflects HTS-derived country-specific reciprocal rates replacing the old binary cutoff.

## Known Issues

### 1. China's IEEPA reciprocal rate not yet parsed from HTS

China's IEEPA reciprocal tariffs are encoded in the 9903.90.xx range, separately from the country-specific entries in 9903.01-02.xx. The current code hardcodes China's reciprocal rate at 25%. This should be parsed from the HTS Ch99 entries for consistency.

### 2. EU/Japan/South Korea floor rate structure

These three countries have a split rate structure in the HTS: products with base rates >= 15% get no additional duty (passthrough), while products with base rates < 15% get a 15% floor. The code handles this via the `rate_type` field (floor vs surcharge), but the product-level base rate is missing for some HTS-10 lines, causing some floor calculations to use 0 as the base rate.

### 3. Section 232 derivative products not yet handled

Steel and aluminum are identified by HTS chapter (72-73 for steel, 76 for aluminum), but derivative products — goods in other chapters containing steel/aluminum components — are not yet covered. The TPC benchmark assumes a 50% metal share for derivatives. The Ch99 entries reference these via "note 16(a)(ii)" in the HTS, which lists specific subheadings outside the core chapters.

### 4. USMCA eligibility is binary, not utilization-adjusted

USMCA eligibility is parsed from the HTS `special` field ("S"/"S+" program codes). This gives a binary eligible/not-eligible flag per product. In practice, not all trade in an eligible product claims USMCA preference, so the binary approach overstates the exemption for some products and understates it for others. A utilization-rate adjustment would improve accuracy for Canada/Mexico.

## Resolved Issues

### IEEPA country-specific reciprocal rates (Fixed)

Country-specific rates are now parsed directly from HTS Ch99 entries: 9903.01.43-75 (Phase 1 "Liberation Day" rates, terminated) and 9903.02.02-81 (Phase 2 reinstated rates, active). Each entry's description names the countries it covers, and the `general` field encodes the rate. "European Union" entries are expanded to 27 individual member states. Rate types are classified as surcharge (+X%), floor (X%), or passthrough.

### USMCA exemptions for Canada/Mexico (Fixed)

USMCA eligibility is parsed from the HTS product `special` field. Products with "S" or "S+" program codes qualify for USMCA preferential treatment. USMCA-eligible products from Canada/Mexico are exempt from IEEPA tariffs (both fentanyl and reciprocal) but not from Section 232. Formula: `CA/MX rate = s232 + (reciprocal + fentanyl) * usmca_factor`, where `usmca_factor = 0` for eligible products, `1` otherwise. ~24% of products are USMCA-eligible.

### Section 232 duties (Fixed)

Section 232 Ch99 entries (9903.80.xx for steel, 9903.85.xx for aluminum) don't use footnote references like Section 301/IEEPA — they describe covered products via HTS note references instead. Products are now identified by chapter (72-73 = steel, 76 = aluminum) and assigned date-dependent 232 rates (25% through mid-2025, 50% after). The `infer_authority()` function was also corrected: 9903.85.xx was misclassified as Section 301 but is actually aluminum 232.

## Data Sources

- **HTS Archives**: [USITC HTS Online](https://hts.usitc.gov/)
- **Census Country Codes**: [Census Bureau](https://www.census.gov/foreign-trade/schedules/b/countrycodes.html)
- **Federal Register**: Proclamations and executive orders (manual curation)

## Related Projects

- [Tariff-Model](https://github.com/Budget-Lab-Yale/Tariff-Model) - Economic impact modeling
- [Tariff-ETRs](https://github.com/Budget-Lab-Yale/Tariff-ETRs) - ETR calculations
