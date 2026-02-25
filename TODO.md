# Tariff Rate Tracker: To-Do List

## High Priority

### ~~1. Scrape US Note 20/21/31 product lists~~ (Implemented)
See Done section.

## Medium Priority

### 2. Map dates of HTS revision updates
Build a verified timeline of policy changes mapped to HTS revisions. Currently `config/revision_dates.csv` has effective dates but doesn't track *what changed* at each revision. Needed for:

- Correct TPC comparison (currently rev_18 effective 2025-08-07 is paired with TPC date 2025-10-17, a 2+ month gap)
- Building a daily rate dataset with proper interpolation between revision points
- Documenting when Phase 1 terminated, Phase 2 started, 232 increased, etc.

### ~~3. 2026 HTS revision naming convention~~ (Implemented)
See Done section.

### 4. EU floor rate residual (~4pp systematic)
EU countries show 35-42% exact match with ~4pp mean excess. The floor formula `max(0, 15% - base_rate)` is correct, but residual discrepancies remain. Possible causes: TPC using slightly different floor mechanics, base rate parsing differences, or passthrough classification.

### ~~5. Switzerland IEEPA over-application (+24pp)~~ (Fixed)
See Done section.

### 6. USMCA classification mismatch (~2,855 products per direction)
Our USMCA flag (from HTS `special` field "S"/"S+") disagrees with TPC for ~5,700 CA/MX products:

| Direction | CA | MX | Our rate | TPC rate |
|-----------|-----|-----|----------|----------|
| We say USMCA, TPC says tariffed | 1,590 | 1,264 | 0% | ~18% |
| We say non-USMCA, TPC says free | 1,330 | 1,525 | 35%/25% | 0% |

Almost exactly symmetric, suggesting a systematic classification difference rather than random noise. TPC likely uses a different USMCA eligibility source or methodology.

### ~~7. CA/MX fentanyl product-level carve-outs~~ (Implemented)
See Done section.

## Low Priority / Future

### 8. USMCA utilization rate adjustment
USMCA eligibility is binary (from HTS `special` field). A utilization-rate adjustment would improve accuracy for Canada/Mexico. Requires external data on USMCA claim rates by product.

### 9. Clean up legacy v1 pipeline
The v1 pipeline files (prefixed `v1_*`) are superseded by the v2 timeseries pipeline. Consider:

- Removing entirely if no longer referenced
- Removing `config/authority_mapping.yaml` and `config/country_rules.yaml` (v1 only)

### 10. Counterfactual scenario validation
`08_apply_scenarios.R` exists but hasn't been tested against the full timeseries. Verify:

- `apply_scenario(ts, 'baseline')` equals raw rates
- `apply_scenario(ts, 'no_ieepa')` zeros IEEPA columns
- Scenario totals are internally consistent after re-stacking

### 11. Automated HTS revision detection
Currently new revisions are manually downloaded and added to `config/revision_dates.csv`. Consider:

- Scraping `hts.usitc.gov` for new revision notifications
- Auto-downloading JSON when new revisions appear
- Running incremental pipeline on detection

## Done

### ~~Switzerland IEEPA over-application (+24pp)~~ (Fixed)
Per [90 FR 59281](https://www.federalregister.gov/documents/2025/12/18/2025-23316) (FR Doc. 2025-23316, Dec 18, 2025): EO 14346 implements the US-Switzerland-Liechtenstein trade framework, effective Nov 14, 2025 (retroactive). Terminates 9903.02.36 (Liechtenstein +15% surcharge) and 9903.02.58 (Switzerland +39% surcharge). New entries 9903.02.82-91 establish a 15% floor structure matching EU/Japan/S. Korea pattern: products with base rate >= 15% get no additional duty; products with base rate < 15% are raised to 15%. Also exempts PTAAP agricultural/natural resources, civil aircraft, and non-patented pharmaceuticals.

Fix: Added Switzerland (4419) and Liechtenstein (4411) to `floor_countries` in `config/policy_params.yaml`. Added override logic in `06_calculate_rates.R` that converts surcharge → floor for countries listed in `floor_countries` when the HTS JSON hasn't yet been updated. Created `docs/active_hts_changes.md` to track Federal Register changes not yet reflected in HTS JSON. Conditional expiry: framework must be finalized by March 31, 2026.

### ~~China IEEPA reciprocal rate: 34% vs ~20%~~ (Fixed)
Post-Geneva (rev_17+), 9903.01.63 is marked `[Compiler's note: provision suspended.]` in HTS JSON. Suspension detection in `extract_ieepa_rates()` was not triggering due to encoding/format variation. Added robust secondary regex check (`\\[Compiler.*suspended`). China's Phase 1 rate now correctly caps to the 10% universal baseline. Expected impact: ~17K China products drop from 34% to 10% IEEPA reciprocal.

### ~~Phantom IEEPA countries (~95K false positive pairs)~~ (Fixed)
Countries with legitimate IEEPA entries that TPC doesn't model — Syria (5020), Moldova (4641), Laos (5530), Falkland Islands (3720), DR Congo (7660) — were inflating validation discrepancies. Added `tpc_excluded_countries` list to `config/policy_params.yaml` and exclusion filters in `test_tpc_comparison.R` and `07_validate_tpc.R`. Actual calculated rates unchanged; only validation comparisons affected.

### ~~Section 232 derivative products~~ (Implemented)
~130 aluminum-containing articles outside chapter 76 now covered via blanket matching using `resources/s232_derivative_products.csv`. Metal content scaling configurable (flat 50% default, CBO product-level buckets). Stacking rules updated for non-metal portion.

### ~~Floor country IEEPA rate selection (Japan/S. Korea)~~ (Fixed)
When both surcharge and floor entries existed for the same country/phase, tie-breaking now correctly prefers floor entries. Products with base_rate > 15% correctly get `rate_ieepa_recip = 0`.

### ~~India & Brazil rate discrepancy~~ (Fixed)
Both countries had country-specific Executive Order entries in 9903.01.76-89 (outside extraction range 43-75) that stack with Phase 2 rates. Brazil: EO 14323 at +40% (9903.01.77) + Phase 2 +10% (9903.02.09) = 50%. India: +25% (9903.01.84) + Phase 2 +25% (9903.02.26) = 50%. Expanded extraction range to 43-89, added `country_eo` phase label, updated rate selection to sum across phases but pick best within phase. India: 84.4% exact match. Brazil: 73.6%.

### ~~Universal IEEPA baseline for unlisted countries~~ (Fixed)
~143 countries with no individual IEEPA entries were getting 0% reciprocal instead of the 10% universal baseline (9903.01.25). Now apply universal baseline as default for all countries not in any IEEPA entry, excluding CA/MX (fentanyl-only regime). Fixed Tunisia from 0.2% to 91.6% exact match (within-phase dedup: take best entry per phase, not sum). Overall rev_32 exact match: 52% → 60.3%.

### ~~Section 301 blanket coverage~~ (Implemented)
~10,400 HTS8 product codes now applied as blanket tariff for China, closing most of the 301 product gap.

### ~~232+fentanyl stacking for CA/MX~~ (Fixed)
Fentanyl was being multiplied by `nonmetal_share` (which is 0 for base 232 products), effectively zeroing it out. Fentanyl is a separate IEEPA authority that applies to full customs value regardless of 232 status. Changed `apply_stacking_rules()` in `helpers.R` to add `rate_ieepa_fent` directly instead of scaling by `nonmetal_share`. Mexico 232 exact match: ~5% → 80.2%. Canada 232: 0.2% (remaining gap is CA fentanyl 35% vs TPC 25%, see analysis below).

**CA 232 fentanyl rate discrepancy (not a bug)**: Our CA fentanyl = 35% (from 9903.01.10 in HTS JSON), producing 60% for 232 products (25%+35%). TPC shows 50% (25%+25%). TPC updated non-232 CA products from 25% to 35% (between July and October 2025 dates) but appears not to have updated 232 products. Our rate is correct per the HTS source data.

### ~~CA/MX fentanyl product-level carve-outs~~ (Implemented)
Product-specific fentanyl carve-outs for CA (energy/minerals +10%, potash +10%) and MX (potash +10%). `extract_ieepa_fentanyl_rates()` now returns all entries with `entry_type` column ('general' vs 'carveout'). Product lists in `resources/fentanyl_carveout_products.csv` (308 HTS8 prefixes sourced from Tariff-ETRs config). Step 3 in `calculate_rates_for_revision()` applies carve-out rates to matching products, falling back to the general blanket rate. Expected impact: ~915 CA and ~850 MX products drop from 35%/25% to 10%.

### ~~2026 HTS revision naming convention~~ (Implemented)
Added `parse_revision_id()` helper in `helpers.R` that extracts year + revision type from any revision ID (e.g., `'2026_rev_3'` -> `year=2026, rev='rev_3'`; `'rev_32'` -> `year=2025, rev='rev_32'`). Replaced hardcoded 2025/2026 year checks in `resolve_json_path()`, `build_download_url()`, `download_missing_revisions()`, `build_full_timeseries()`, `run_update()`, and `01_scrape_revision_dates.R` cross-reference. All year scanning is now dynamic — derived from `revision_dates.csv` entries. Supports `2026_rev_1`, `2027_basic`, etc. without code changes.

### ~~US Note 20/31 product lists~~ (Implemented)
New script `src/12_scrape_us_notes.R` downloads Chapter 99 PDF from USITC, finds "Heading 9903.XX.XX applies to" anchors, extracts HTS subheading codes from each product list section. Covers Note 20 (Lists 1-3 + 4A: 9903.88.01/.02/.03/.15) and Note 31 (Biden acceleration: 9903.91.01-.11). Note 21 doesn't exist as a separate note — List 4A modifications are embedded in Note 20 subdivision (u). Parser found 10,587 codes with 10,132 matching existing CSV (strong validation), adding 296 new entries (mostly List 3). Run with `Rscript src/12_scrape_us_notes.R` (or `--dry-run` to preview). Requires `pdftools` package.
