# Next Steps for Improving Tariff Rate Accuracy

*Updated 2026-02-24 from TPC validation analysis of rev_32*

## Current Validation Status (rev_32 → TPC 2025-11-17)

| Metric | Value |
|--------|-------|
| Total comparisons | 268,742 |
| Exact match (<0.5pp) | 52.0% |
| Within 2pp | 53.3% |
| Within 5pp | 58.6% |
| Mean abs diff | 8.1 pp |

## Tier 1: High Impact (affects 10,000+ product-country pairs)

### 1. China IEEPA Reciprocal Rate Calibration
- **Gap**: +14pp systematic excess on **16,924 China products** (85% of China comparisons)
- **Pattern**: Our rate 59%, TPC rate 45%; Our rate 42%, TPC 28%; Our rate 34%, TPC 20%
- **Root cause**: We use the statutory 34% from 9903.01.63, TPC uses ~20%. This likely reflects the Geneva trade deal (May 2025) reducing China's IEEPA rate, which may not be fully captured in HTS revision text.
- **Fix**: Investigate whether rev_32's ch99 data reflects the Geneva reduction. If not, this may need a temporal override -- the 34% entry was never formally "terminated" in the HTS JSON, but the effective rate changed via executive action.
- **Note**: At rev_32, China exact match is 79.7% — the 301 product list gap has been largely closed by the blanket approach. The remaining China gap is dominated by this rate discrepancy.

### 2. Phantom IEEPA Countries (5+ countries, ~95K excess pairs)
- **Gap**: We assign 15-25% IEEPA rates to countries TPC shows at 0%
- **Countries**: DR Congo (7660), Laos (5530), Brunei (5020), Belarus (4641), Thailand (3720) -- 18,945 products each
- **Root cause**: Our country extraction from ch99 descriptions is over-inclusive, or these countries are classified as "passthrough" (rate = 0) in TPC but we still apply a rate
- **Fix**: Audit the 110 "passthrough" countries from Phase 2 extraction. Cross-reference with TPC's country list. Passthrough countries should get rate 0, not the universal 10% baseline.

### 3. India Rate Discrepancy (9,595 products, -25pp)
- **Gap**: TPC shows 50%, we show 25%
- **Root cause**: India's reciprocal rate may have been raised from 26% to 50% in a later executive action or Phase 2 update, and our extraction isn't capturing the update.
- **Fix**: Check India's Phase 2 rate in the ch99 description text. May also need to verify Phase 1 vs Phase 2 rate precedence logic for India specifically.

### 4. Brazil Specific Tariff (4,300 products, -40pp)
- **Gap**: TPC shows 50%, we show 10%
- **Pattern**: 12,306 products where TPC=0% and ours=10% (we over-apply); 4,300 where TPC=50% and ours=10% (we under-apply)
- **Root cause**: Brazil's IEEPA rate should be ~40-50% (CBO model confirms 40% Brazil surcharge). We're extracting only the 10% universal baseline rather than Brazil's country-specific rate.
- **Fix**: Debug `extract_ieepa_rates()` for Brazil (census code 3510). The Phase 2 ch99 entry for Brazil may use a different description format.

## Tier 2: Medium Impact (1,000-10,000 pairs)

### 5. Canada/Mexico Non-USMCA Stacking (~1,700 products, -25pp)
- **Gap**: TPC shows 50%, we show 25% (917 CA + 798 MX products)
- **Also**: 310 CA products where TPC=35% but ours=0%
- **Root cause**: For non-USMCA products, fentanyl (35% CA, 25% MX) should stack with IEEPA reciprocal. Our stacking may be zeroing out fentanyl when USMCA doesn't apply, or there's a missing IEEPA component for CA/MX.
- **Fix**: Verify stacking rules for CA/MX non-USMCA products. The 35% gap for Canada suggests fentanyl is being zeroed out when it shouldn't be.

### 6. Singapore & Small Trading Partners (~2,000 products, -20pp+)
- **Gap**: Singapore TPC=10-30%, ours=0%; similar for Dominican Republic, UAE, Colombia, Australia
- **Root cause**: These countries may have IEEPA Phase 2 rates that our extraction classifies as "passthrough" (no rate applied).
- **Fix**: Review Phase 2 extraction for these countries. The "passthrough" classification may be too aggressive.

### 7. Switzerland IEEPA Over-Application (5,543 products, +24pp)
- **Gap**: Our rate 39%, TPC 13.6%
- **Root cause**: We apply a +39% IEEPA surcharge (9903.02.58). TPC shows much lower. Switzerland is EFTA, not EU -- not a floor/surcharge selection issue (Switzerland has only surcharge entries). May reflect a rate reduction not yet in our revision data.
- **Fix**: Check Switzerland (4419) in IEEPA extraction. Verify its Phase 2 rate against executive order text.

## Tier 3: Refinement (product-level accuracy)

### 8. China 301 Biden + 232 Stacking (~550 products, -43pp)
- **Gap**: TPC=93%, ours=50%
- **Root cause**: Products subject to both Biden 301 (50%) and 232 (25%) where stacking should produce ~93%. Our stacking rules may not correctly combine all components for these products.
- **Fix**: Check `apply_stacking_rules()` for China products with both rate_301 > 0 and rate_232 > 0.

### 9. Section 301 Exclusions (9903.89.xx) -- 61 remaining products
- **Gap**: 61 China products where TPC > us and our rate_301 = 0
- **Root cause**: Products excluded from 301 via 9903.89.xx US Note lists but still in our blanket list, OR products at 10-digit specificity not captured by our 8-digit matching
- **Fix**: Lower priority since only 61 products.

### 10. EU Floor Rate Residual (~4pp systematic, ~35-42% exact match)
- **Gap**: EU countries average 35-42% exact match with ~4pp mean excess
- **Root cause**: Floor formula `max(0, floor_rate - base_rate)` is correct. Residual gap may be from TPC using slightly different floor mechanics or base rate parsing differences.
- **Note**: Japan/S. Korea floor selection bug has been **fixed** (was picking surcharge instead of floor when both existed). Japan now at 42.1%, S. Korea at 40.1% exact match, in line with EU countries.

## Tier 4: Structural / Data Quality

### 11. TPC Country Coverage Alignment
- We generate rates for 240 countries; TPC covers ~209. Products for the ~31 countries TPC doesn't cover contribute to the "extra in ours" count but don't affect match rates.
- **Fix**: Low priority -- our broader coverage is correct by design.

### 12. 2026 HTS Revision Support
- Pipeline handles `2026_basic` as a special case but has no support for `2026_rev_1`, `2026_rev_2`, etc.
- `resolve_json_path()` and `list_available_revisions()` need updating before 2026 revisions appear.

## Priority Ordering

| Priority | Item | Est. Impact on rev_32 Exact Match |
|----------|------|-----------------------------------|
| P0 | #1 China IEEPA calibration | +15-20pp (16,924 products) |
| P0 | #2 Phantom IEEPA countries | removes ~95K false positives |
| P1 | #3 India rate | +3-4pp |
| P1 | #4 Brazil rate | +1-2pp |
| P1 | #5 CA/MX stacking | +0.5-1pp |
| P2 | #6 Singapore et al. | +0.5pp |
| P2 | #7 Switzerland | removes false positives |
| P3 | #8-10 Refinements | <0.5pp each |

Items #1 and #2 are the biggest levers -- fixing the China IEEPA rate alone would flip ~85% of China products from "14pp too high" to near-exact match.

## Recently Resolved

- **Section 232 derivative products**: ~130 aluminum-containing articles now covered with metal content scaling (flat 50% default, CBO buckets available). Stacking rules updated for non-metal portion.
- **Floor country IEEPA selection (Japan/S. Korea)**: Fixed tie-breaking to prefer floor over surcharge when both exist. S. Korea mean diff dropped to 0.1pp.
- **Section 301 blanket coverage**: ~10,400 HTS8 product codes now applied as blanket tariff for China, closing most of the 301 product gap.
