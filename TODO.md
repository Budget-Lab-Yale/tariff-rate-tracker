# Tariff Rate Tracker: To-Do List

## High Priority

### 1. China IEEPA reciprocal rate: 34% vs ~20%
HTS statutory rate is +34% (9903.01.63), but TPC data implies ~20%. The May 2025 US-China bilateral agreement (Geneva deal) likely reduced the effective rate. The HTS hasn't been formally updated to reflect this.

- Monitor future HTS revisions for updated China rate
- Consider adding a date-conditional override once the negotiated rate is confirmed
- Current impact: +14pp systematic overestimate on ~17K China products
- This is the single largest lever for improving match rates at rev_18+

### 2. Phantom IEEPA countries (~95K false positive pairs)
We assign 15-25% IEEPA rates to countries where TPC shows 0%. Countries include DR Congo (7660), Laos (5530), Brunei (5020), Belarus (4641), Thailand (3720) — 18,945 products each.

- Root cause: Country extraction from Ch99 descriptions is over-inclusive, or these countries are classified as "passthrough" (rate = 0) in TPC but we still apply a rate
- Fix: Audit the 110 "passthrough" countries from Phase 2 extraction. Cross-reference with TPC's country list.

### 3. India and Brazil rate discrepancies
- **India**: TPC shows 50%, we show 25% (-25pp on 9,595 products). India's Phase 2 rate may have been raised.
- **Brazil**: TPC shows 50%, we show 10% (-40pp on 4,300 products). We're extracting only the 10% universal baseline rather than Brazil's country-specific rate.
- Fix: Debug `extract_ieepa_rates()` for these countries' Phase 2 ch99 entries.

### 4. Scrape US Note 20/21/31 product lists
~5,000 China products are defined by US Note product lists but lack individual footnote references to 9903.88-89.xx/9903.91.xx entries. Parsing these product lists from the USITC HTS General Notes would close the remaining ~22K product-country 301 gap.

- **US Note 20**: Original Section 301 lists (Lists 1-4)
- **US Note 21**: List 4A (additional products)
- **US Note 31**: Biden acceleration (Lists b-j with phased effective dates)
- Source: HTS General Notes or USITC online subchapter notes

## Medium Priority

### 5. Map dates of HTS revision updates
Build a verified timeline of policy changes mapped to HTS revisions. Currently `config/revision_dates.csv` has effective dates but doesn't track *what changed* at each revision. Needed for:

- Correct TPC comparison (currently rev_18 effective 2025-08-07 is paired with TPC date 2025-10-17, a 2+ month gap)
- Building a daily rate dataset with proper interpolation between revision points
- Documenting when Phase 1 terminated, Phase 2 started, 232 increased, etc.

### 6. 2026 HTS revision naming convention
The pipeline handles `2026_basic` as a special case but has no support for `2026_rev_1`, `2026_rev_2`, etc. Before 2026 revisions appear:

- Update `resolve_json_path()` and `list_available_revisions()` to handle 2026 naming
- Add logic to `update_pipeline.R` to detect and download 2026 revisions
- Ensure `revision_dates.csv` format accommodates the year prefix

### 7. EU floor rate residual (~4pp systematic)
EU countries show 35-42% exact match with ~4pp mean excess. The floor formula `max(0, 15% - base_rate)` is correct, but residual discrepancies remain. Possible causes: TPC using slightly different floor mechanics, base rate parsing differences, or passthrough classification.

### 8. Switzerland IEEPA over-application (+24pp)
Our rate 39%, TPC 13.6% for 5,543 products. Switzerland has a +39% surcharge (9903.02.58) but TPC shows much lower. May be a rate reduction not yet reflected in our revision data, or different TPC methodology. Not a floor/surcharge selection issue — Switzerland genuinely has only surcharge entries.

### 9. CA/MX non-USMCA stacking (~1,700 products)
TPC shows 50%, we show 25% for non-USMCA Canada/Mexico products. Fentanyl (35% CA, 25% MX) should stack with IEEPA reciprocal. Our stacking may be zeroing out fentanyl when USMCA doesn't apply.

## Low Priority / Future

### 10. USMCA utilization rate adjustment
USMCA eligibility is binary (from HTS `special` field). A utilization-rate adjustment would improve accuracy for Canada/Mexico. Requires external data on USMCA claim rates by product.

### 11. Clean up legacy v1 pipeline
The v1 pipeline files (prefixed `v1_*`) are superseded by the v2 timeseries pipeline. Consider:

- Removing entirely if no longer referenced
- Removing `config/authority_mapping.yaml` and `config/country_rules.yaml` (v1 only)

### 12. Counterfactual scenario validation
`08_apply_scenarios.R` exists but hasn't been tested against the full timeseries. Verify:

- `apply_scenario(ts, 'baseline')` equals raw rates
- `apply_scenario(ts, 'no_ieepa')` zeros IEEPA columns
- Scenario totals are internally consistent after re-stacking

### 13. Automated HTS revision detection
Currently new revisions are manually downloaded and added to `config/revision_dates.csv`. Consider:

- Scraping `hts.usitc.gov` for new revision notifications
- Auto-downloading JSON when new revisions appear
- Running incremental pipeline on detection

## Done

### ~~Section 232 derivative products~~ (Implemented)
~130 aluminum-containing articles outside chapter 76 now covered via blanket matching using `resources/s232_derivative_products.csv`. Metal content scaling configurable (flat 50% default, CBO product-level buckets). Stacking rules updated for non-metal portion.

### ~~Floor country IEEPA rate selection (Japan/S. Korea)~~ (Fixed)
When both surcharge and floor entries existed for the same country/phase, tie-breaking now correctly prefers floor entries. Products with base_rate > 15% correctly get `rate_ieepa_recip = 0`.
