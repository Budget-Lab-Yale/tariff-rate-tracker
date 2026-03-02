# Tariff Rate Tracker: To-Do List

## High Priority

### ~~1. Scrape US Note 20/21/31 product lists~~ (Implemented)
See Done section.

## Medium Priority

### ~~2. Map dates of HTS revision updates~~ (Implemented)
See Done section.

### ~~3. 2026 HTS revision naming convention~~ (Implemented)
See Done section.

### ~~4. EU floor rate residual (~4pp systematic)~~ (Investigated)
See Done section.

### ~~5. Switzerland IEEPA over-application (+24pp)~~ (Fixed)
See Done section.

### ~~6. USMCA classification mismatch~~ (Investigated — utilization rate issue)
See Done section.

### ~~7. CA/MX fentanyl product-level carve-outs~~ (Implemented)
See Done section.

## ~~Tariff-ETRs Alignment (Feb 2026)~~ (Completed)

Tasks to align tariff-rate-tracker with the updated Tariff-ETRs stacking rules and data architecture (commit b144391). All items investigated/resolved.

### ~~12. Update stacking rules: add S301 to all branches~~ (Fixed)
See Done section.

### ~~13. Add MFN rate support to rate schema and stacking~~ (Verified — already aligned)
See Done section.

### ~~14. Add target_total floor rule support for 232 and reciprocal~~ (N/A)
See Done section.

### ~~15. Align nonmetal_share computation for non-China fentanyl~~ (Verified — already aligned)
See Done section.

### ~~16. Add MFN exemption shares support (FTA/GSP preferences)~~ (N/A)
See Done section.

### ~~17. Update CLAUDE.md stacking rules documentation~~ (Updated)
See Done section.

### ~~18. Verify import cache compatibility with updated Tariff-ETRs~~ (Verified — already compatible)
See Done section.

## Low Priority / Future

### ~~8. USMCA utilization rate adjustment~~ (Implemented)
See Done section.

### ~~9. Clean up legacy v1 pipeline~~ (Done)
See Done section.

### 10. Counterfactual scenario validation
`08_apply_scenarios.R` exists but hasn't been tested against the full timeseries. Verify:

- `apply_scenario(ts, 'baseline')` equals raw rates
- `apply_scenario(ts, 'no_ieepa')` zeros IEEPA columns
- Scenario totals are internally consistent after re-stacking

### ~~11. Automated HTS revision detection~~ (Partially implemented)
See Done section.

### 19. Investigate 2026_rev_4 Section 122 Phase 3 (9903.03.01-11)
Rev_4 (2026-02-25) added 11 new ch99 entries under 9903.03.xx with a 10% blanket on all countries (US Note 2 subdivision (aa)). This appears to be a new Section 122 phase. Need to:

- Verify classification in `classify_authority()` — currently classified as "other"
- Check if these should be treated as a distinct authority (rate_s122 expansion or new column)
- Validate stacking behavior with existing IEEPA/232/301

### 20. Swiss framework finalization deadline (March 31, 2026)
The US-Switzerland-Liechtenstein framework (EO 14346) must be finalized by March 31, 2026. If confirmed, set `swiss_framework.finalized: true` in `policy_params.yaml`. If it lapses, rates revert to surcharges. Monitor Federal Register and USITC revisions around this date.

## Done

### ~~Clean up legacy v1 pipeline~~ (Done)
Removed 11 v1 pipeline scripts (`src/v1_*.R`) and 2 v1-only config files (`config/authority_mapping.yaml`, `config/country_rules.yaml`). Verified zero references from v2 pipeline — v1 files only referenced each other. Updated CLAUDE.md and README.md to remove v1 documentation sections.

### ~~Map dates of HTS revision updates~~ (Implemented)
New script `src/13_revision_changelog.R` diffs Ch99 entries across all 35 consecutive revision pairs, detecting additions, removals, rate changes, and suspensions (via description text matching). Outputs `output/changelog/revision_diffs.csv` (467 diff entries) and `output/changelog/revision_summary.csv`. Comprehensive timeline documented in `docs/revision_changelog.md` with key milestones: Liberation Day (rev_7), Phase 1 pause (rev_9), Geneva Agreement (rev_12), 232 doubling (rev_14), Phase 2 (rev_18), floor country frameworks (rev_23/32/2026_basic). Added `policy_event` column to `config/revision_dates.csv` linking each revision to its policy change.

### ~~USMCA classification mismatch~~ (Investigated)
Diagnostic revealed two findings:

1. **S+ parsing bug (165 products)**: `extract_usmca_eligibility()` only matched program codes from the first parenthesized group in the HTS `special` field. Products with `S+` in a secondary group (e.g., `"Free (BH,CL,...) See 9823.xx.xx (S+)"`) were missed. Fixed by using `str_extract_all()` to check all parenthesized groups. USMCA-eligible products: 4,787 → 4,952.

2. **Utilization rate (main cause, ~5,700 products)**: TPC uses product-level USMCA utilization rates, not binary eligibility. For products we mark USMCA-eligible (rate = 0%), TPC charges a fraction of the full tariff: `TPC_rate = (1 - utilization_rate) * full_tariff`. Implied utilization rates span 0-100% (median ~55% CA, ~44% MX). The symmetric mismatch pattern (Type 1: we say 0%, TPC says ~18%; Type 2: we say 35/25%, TPC says 0%) is driven by this methodological difference. Our binary approach is correct per HTS data; improvement requires external USMCA claim rate data. See TODO #8.

CA/MX exact match: 44.3% / 44.5% — primarily limited by the utilization rate issue.

### ~~USMCA utilization rate adjustment~~ (Implemented — Census SPI data)
Per-product USMCA utilization shares derived from Census IMP_DETL.TXT RATE_PROV field (code 18 = USMCA preferential entry). For each HTS10 x country: `usmca_share = sum(value where RATE_PROV=18) / sum(total_value)`. Applied to all CA/MX products as `rate * (1 - usmca_share)`. Script: `src/compute_usmca_shares.R` reads Census ZIP files (IMDB2401-2412.ZIP), extracts RATE_PROV at positions 21-22 of IMP_DETL.TXT. Output: `resources/usmca_product_shares.csv` (22,449 product-country pairs). Results: CA 44.3%→79.4%, MX 44.5%→83.9% exact match (rev_32). Overall rev_32: 63.6%→66.4%.

Earlier failed approaches: (1) Tariff-ETRs sector-level shares applied blanket (CA→8%), (2) sector shares on eligible-only (CA→38%), (3) derived shares from eligibility + sector + imports (CA→43.5%, 96% capped at 1.0). The breakthrough was discovering RATE_PROV in the Census fixed-width data — the same files we already download contain per-record SPI codes, giving true product-level USMCA claiming rates.

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

### ~~EU floor rate residual~~ (Partially fixed — floor country product exemptions implemented)
Diagnostic on rev_32 for 27 EU floor countries + Japan + S. Korea. Floor formula `max(0, 15% - base_rate)` is correctly implemented (all 8,831 Germany floor-active products match expected). Three distinct error patterns identified:

1. **EU-specific product exemptions (~1,600 products/country, ~16% of TPC-matched products)**:
   Ch99 entries 9903.02.74/75/77 define product categories exempt from the EU floor (agricultural/natural resources, civil aircraft, non-patented pharmaceuticals). These are blanket exemptions — NOT referenced via product footnotes. Product lists are defined in US Notes to Chapter 99, not parseable from HTS JSON API. We incorrectly apply the 15% floor to these products. Consistent across EU countries (82-86% overlap DE-FR-IT). Chapter distribution: ch98 (special provisions, 100% TPC=0), ch61/62 (apparel, ~50-60% TPC=0), ch30 (pharma, ~88% TPC=0). These exempt products are entirely distinct from the ~1,087 general IEEPA Annex A exempt products (zero overlap).

2. **Continuous rate distribution (~2,700 base=0 products with TPC rates between 1-14%)**:
   For products where we apply the full 15% floor, TPC assigns rates spanning 1-14% — a continuous distribution, not binary (0% or 15%). This mirrors the USMCA utilization rate pattern and suggests TPC uses trade-weighted or other product-level methodology beyond a simple floor formula. Contributes ~3-4pp of average excess.

3. **232 products under-counted (-12pp mean diff, 1,172 products)**:
   EU 232 products have only 3.2% exact match with -12pp mean diff. Separate issue from the floor — likely related to EU-specific 232 exemption/exclusion patterns.

**Net result**: Germany 41.5% exact match, mean diff +1.55pp. Floor countries range 32-44% exact match.

**Update**: Pattern A (product exemptions) now addressed. Extended `12_scrape_us_notes.R` to parse floor country product exemptions from US Note 2 subdivisions (v)(xx)-(xxiv) and Note 3. Product lists for PTAAP (agricultural/natural resources), civil aircraft, non-patented pharmaceuticals, and particular articles extracted from Chapter 99 PDF for EU, S. Korea, Switzerland/Liechtenstein, and Japan. Output in `resources/floor_exempt_products.csv`. Applied in `06_calculate_rates.R` — exempt products get `rate_ieepa_recip = 0` instead of the 15% floor. Patterns B (continuous rates) and C (232 interaction) remain open.

### ~~US Note 20/31 product lists~~ (Implemented)
New script `src/12_scrape_us_notes.R` downloads Chapter 99 PDF from USITC, finds "Heading 9903.XX.XX applies to" anchors, extracts HTS subheading codes from each product list section. Covers Note 20 (Lists 1-3 + 4A: 9903.88.01/.02/.03/.15) and Note 31 (Biden acceleration: 9903.91.01-.11). Note 21 doesn't exist as a separate note — List 4A modifications are embedded in Note 20 subdivision (u). Parser found 10,587 codes with 10,132 matching existing CSV (strong validation), adding 296 new entries (mostly List 3). Run with `Rscript src/12_scrape_us_notes.R` (or `--dry-run` to preview). Requires `pdftools` package.

### ~~S301 in all stacking branches~~ (Fixed — #12)
Added `+ rate_301` to the Others+232 and Others-no-232 branches in `apply_stacking_rules()` (`src/helpers.R`). S301 is unconditionally cumulative — applies to full customs value regardless of 232 status, with no `nonmetal_share` scaling. China branches already included `rate_301` correctly. Currently zero impact for non-China countries (S301 only targets China), but correct for forward-compatibility. No TPC validation change expected.

### ~~MFN rate support~~ (Verified — #13)
`base_rate` (from HTS JSON product `general` field) is functionally equivalent to `mfn_rate` in Tariff-ETRs (from separate `mfn_rates_2025.csv`). Both are additive: tracker uses `total_rate = base_rate + total_additional`, Tariff-ETRs uses `final_rate = mfn_rate + stacked_policy_tariffs`. Different source granularity (HTS10 vs HS8) but same semantics. No code change needed.

### ~~target_total floor rule for 232~~ (N/A — #14)
Tracker parses 232 rates from HTS JSON Chapter 99 entries directly, not from config YAML. The `target_total` concept in Tariff-ETRs is a config-level abstraction where `effective_add_on = max(target_total - MFN, 0)`. The tracker doesn't need this — it reads the actual statutory rates from HTS JSON. Floor rates are handled in the IEEPA context (floor country framework), not 232.

### ~~Nonmetal fentanyl alignment~~ (Verified — #15)
Both systems scale fentanyl by `nonmetal_share` for non-China 232 products: `(recip + fent + s122) * nonmetal_share`. China exception (fentanyl at full value regardless of 232 status) is also aligned. No code change needed.

### ~~MFN exemption shares~~ (N/A — #16)
Tracker computes statutory rates (not effective preferential rates). MFN exemption shares (`effective_mfn = mfn_rate * (1 - exemption_share)`) are a Tariff-ETRs ETR concept for adjusting FTA/GSP duty-free provisions at HS2×country granularity. Not relevant to statutory rate tracking.

### ~~CLAUDE.md stacking rules~~ (Updated — #17)
Updated stacking rules comments in CLAUDE.md to show `+ 301` in all 4 branches (Others+232 and Others-no-232 were missing it).

### ~~Import cache compatibility~~ (Verified — #18)
Cache at `../Tariff-ETRs/cache/hs10_by_country_gtap_2024_con.rds` exists with correct schema: `hs10`, `cty_code`, `gtap_code`, `imports`. No format changes from Tariff-ETRs restructuring.

### ~~Automated HTS revision detection~~ (Partially implemented — #11)
USITC deprecated the `hts.usitc.gov/reststop/getJSON` endpoint in early 2026. Discovery now uses two sources:
1. **Release metadata**: `hts.usitc.gov/reststop/releaseList` returns all releases with effective dates, status, and creator info. Used to detect new 2026 revisions.
2. **Bulk JSON download**: Files now hosted at `www.usitc.gov/sites/default/files/tata/hts/hts_{year}_{edition}_json.json` (e.g., `hts_2026_revision_4_json.json`).

`02_download_hts.R:build_download_url()` updated to use the new URL pattern. `update_pipeline.R` handles the full check-download-process workflow. Remaining manual step: adding rows to `revision_dates.csv` with effective dates (could be automated from `releaseList` API response).
