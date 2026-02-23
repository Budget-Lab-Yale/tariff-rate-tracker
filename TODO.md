# Tariff Rate Tracker: To-Do List

## High Priority

### 1. Scrape US Note 20/21/31 product lists
The single largest source of TPC discrepancy. ~5,000 China products are defined by US Note product lists but lack individual footnote references to 9903.88-89.xx/9903.91.xx entries. Parsing these product lists from the USITC HTS General Notes would close the ~22K product-country 301 gap.

- **US Note 20**: Original Section 301 lists (Lists 1-4)
- **US Note 21**: List 4A (additional products)
- **US Note 31**: Biden acceleration (Lists b-j with phased effective dates)
- Source: HTS General Notes or USITC online subchapter notes
- Would add ~5,000 products to Section 301 coverage

### 2. Section 232 derivative products (metal content)
Currently, Section 232 coverage uses hardcoded chapter matching (72-73 = steel, 76 = aluminum). Derivative products in other chapters containing steel/aluminum components are missed. TPC assumes 50% metal share for derivatives.

- Ch99 entries reference "note 16(a)(ii)" for derivative products
- Options: (a) parse the HTS note for the product list, (b) use a configurable metal content share (e.g., X = 0.5), or (c) per-product/country file
- ~2,000 additional products affected

### 3. Map dates of HTS revision updates
Build a verified timeline of policy changes mapped to HTS revisions. Currently `config/revision_dates.csv` has effective dates but doesn't track *what changed* at each revision. Needed for:

- Correct TPC comparison (currently rev_18 effective 2025-08-07 is paired with TPC date 2025-10-17, a 2+ month gap)
- Building a daily rate dataset with proper interpolation between revision points
- Documenting when Phase 1 terminated, Phase 2 started, 232 increased, etc.

## Medium Priority

### 4. Floor country rate investigation
EU, Japan, and South Korea use a floor rate structure (15% minimum) but match rates are only 37-42% for EU and 24% for Japan. Investigation needed:

- Are base rates being parsed correctly for all products?
- Is the floor calculation `max(0, 15% - base_rate)` correct for all product types?
- Why is Japan (24%) so much worse than S. Korea (42%)?
- Switzerland shows 0% match with mean_our 39% vs mean_tpc 13% -- investigate

### 5. Countries with 0% match rate
Several countries show 0% exact match: Dominican Republic, Finland, Belgium, Slovakia, Spain, Slovenia, Romania, Singapore. Common pattern: our mean rate is ~24% while TPC shows 37-47%.

- These are likely EU member states where our rate is passthrough (0 IEEPA additional) but TPC shows a positive rate
- Could indicate an issue with how floor/passthrough is applied to EU members
- Switzerland (mean_our 39% vs mean_tpc 13%) is opposite direction -- we're higher

### 6. China IEEPA reciprocal rate: 34% vs 25%
HTS statutory rate is +34% (9903.01.63), but TPC data implies +25%. The May 2025 US-China bilateral agreement likely reduced the effective rate. The HTS hasn't been updated to reflect this.

- Monitor future HTS revisions for updated China rate
- Consider adding a date-conditional override once the negotiated rate is confirmed
- Current impact: +9pp systematic overestimate on ~14K China products

## Low Priority / Future

### 7. USMCA utilization rate adjustment
USMCA eligibility is binary (from HTS `special` field). A utilization-rate adjustment would improve accuracy for Canada/Mexico. Requires external data on USMCA claim rates by product.

### 8. Clean up legacy v1 pipeline
The v1 pipeline files (`01_ingest_hts.R` through `05_write_outputs.R`, `run_daily.R`) are superseded by the v2 timeseries pipeline. Consider:

- Moving to a `legacy/` subdirectory
- Removing entirely if no longer referenced
- Removing `config/authority_mapping.yaml` and `config/country_rules.yaml` (v1 only)

### 9. Counterfactual scenario validation
`07_apply_scenarios.R` exists but hasn't been tested against the full timeseries. Verify:

- `apply_scenario(ts, 'baseline')` equals raw rates
- `apply_scenario(ts, 'no_ieepa')` zeros IEEPA columns
- Scenario totals are internally consistent after re-stacking

### 10. Automated HTS revision detection
Currently new revisions are manually downloaded and added to `config/revision_dates.csv`. Consider:

- Scraping `hts.usitc.gov` for new revision notifications
- Auto-downloading JSON when new revisions appear
- Running incremental pipeline on detection
