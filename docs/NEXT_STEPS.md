# Next Steps for Improving Tariff Rate Accuracy

*Updated 2026-02-28 from TPC validation analysis of rev_32*

## Current Validation Status (rev_32 → TPC 2025-11-17)

| Metric | Value |
|--------|-------|
| Total comparisons | 298,341 |
| Exact match (<0.5pp) | 66.1% |
| Within 2pp | 67.0% |
| Within 5pp | 71.3% |
| Mean abs diff | 4.9 pp |

**CA/MX breakdown (rev_32):**

| Group | N | Our rate | TPC rate | Match% |
|-------|---|----------|----------|--------|
| CA non-USMCA, no 232 | 7,556 | 35% | 23.6% | 51.3% |
| CA non-USMCA, 232 | 1,060 | 60% | 47.5% | 0.2% |
| CA USMCA | 2,522 | ~1% | 11.9% | 36.7% |
| MX non-USMCA, no 232 | 6,254 | 25% | 16.2% | 48.9% |
| MX non-USMCA, 232 | 932 | 50% | 46.7% | 80.2% |
| MX USMCA | 2,230 | ~1% | 9.3% | 43.3% |

## Tier 1: High Impact

### 1. USMCA Classification Mismatch (~5,700 CA/MX products)
- **Gap**: ~2,855 products per direction: we classify as USMCA (rate=0%) but TPC applies tariffs (~18%), and vice versa (we apply 35%/25% fentanyl, TPC shows 0%). Almost exactly symmetric.
- **Root cause**: Our USMCA flag comes from the HTS `special` field ("S"/"S+"). TPC likely uses a different USMCA eligibility source or methodology.
- **Impact**: CA non-USMCA non-232: 51.3% match (7,556 products). MX non-USMCA non-232: 48.9% match (6,254 products).
- **Fix**: Investigate alternative USMCA classification sources. May require external USMCA utilization data.

### ~~2. Switzerland IEEPA Over-Application (5,544 products, +24.6pp)~~ (RESOLVED)
Fixed via Swiss framework implementation (EO 14346). Switzerland (4419) and Liechtenstein (4411) now use 15% floor structure matching EU/Japan/S. Korea. HTS 2026_basic has native floor entries (9903.02.82-91). Surcharge-to-floor override applies to pre-2026 revisions within the framework window (Nov 14, 2025 → March 31, 2026). Product exemptions (PTAAP, civil aircraft, pharma) in `resources/floor_exempt_products.csv`.

### 3. EU Floor Rate Residual (~4pp systematic, ~33-40% exact match)
- **Gap**: EU countries average 33-40% exact match with ~3-5pp mean excess
- **Root cause**: Floor formula `max(0, floor_rate - base_rate)` is correct. Residual gap may be from TPC using slightly different floor mechanics or base rate parsing differences.
- **Note**: Japan/S. Korea floor selection bug has been **fixed**. S. Korea now at 40.1% exact match, in line with EU countries.

### ~~4. CA/MX Fentanyl Product-Level Carve-Outs (~1,765 products)~~ (RESOLVED)
Fixed via product-level carve-out implementation. `extract_ieepa_fentanyl_rates()` now returns all entries with `entry_type` column ('general' vs 'carveout'). Product lists in `resources/fentanyl_carveout_products.csv` (308 HTS8 prefixes). Step 3 in `calculate_rates_for_revision()` applies carve-out rates (10%) to matching products, falling back to the general blanket rate (CA 35%, MX 25%).

## Tier 2: Refinement (product-level accuracy)

### 5. China+232 Reciprocal Stacking (~920 products, ~25pp gap)
- **Gap**: TPC=85-92%, ours=60-67% for China steel/aluminum/copper (ch72-76)
- **Root cause**: **TPC stacks IEEPA reciprocal on top of Section 232 unconditionally.** Our model applies mutual exclusion (232 takes precedence, recip × nonmetal_share = 0 for base 232 products). Confirmed: adding 25pp reciprocal to our rates produces near-zero residual vs TPC.
- **Status**: **Methodological difference, not a bug.** Our approach follows the Tariff-ETRs legal authority structure. TPC sums all authorities without mutual exclusion. No fix planned — this is a documented analytical choice.

### 6. Section 301 Exclusions (9903.89.xx) -- 61 remaining products
- **Gap**: 61 China products where TPC > us and our rate_301 = 0
- **Root cause**: Products excluded from 301 via 9903.89.xx US Note lists but still in our blanket list, OR products at 10-digit specificity not captured by our 8-digit matching
- **Fix**: Lower priority since only 61 products.

## Tier 3: Structural / Data Quality

### 7. TPC Country Coverage Alignment
- We generate rates for 240 countries; TPC covers ~209. Products for the ~31 countries TPC doesn't cover contribute to the "extra in ours" count but don't affect match rates.
- **Fix**: Low priority — our broader coverage is correct by design.

### ~~8. 2026 HTS Revision Support~~ (RESOLVED)
Pipeline fully supports 2026 revisions via `parse_revision_id()` which dynamically extracts year from revision IDs (e.g., `2026_rev_3` → year=2026, rev=rev_3). All infrastructure (`resolve_json_path`, `list_available_revisions`, `build_download_url`) handles multi-year data. Currently processing 2026_basic + 2026_rev_1-4 (through Feb 25, 2026). USITC API change: `build_download_url()` updated to use `www.usitc.gov/sites/default/files/tata/hts/` after the old `getJSON` endpoint was deprecated.

## Priority Ordering

| Priority | Item | Status |
|----------|------|--------|
| ~~P1~~ | ~~#1 USMCA classification mismatch~~ | Partially resolved (Census SPI: 66.4% match) |
| ~~P1~~ | ~~#2 Switzerland~~ | RESOLVED |
| P2 | #3 EU floor residual | Open (patterns B, C) |
| ~~P2~~ | ~~#4 Fentanyl product carve-outs~~ | RESOLVED |
| P3 | #5-6 Refinements | Open (<0.5pp each) |

## Recently Resolved

- **232+fentanyl stacking for CA/MX**: Fentanyl was multiplied by `nonmetal_share` (0 for base 232 products), zeroing it out. Fixed to add `rate_ieepa_fent` directly. Mexico 232 exact match: ~5% → 80.2%. Canada 232 gap remains at 10pp (our 60% vs TPC 50%) because TPC appears to use 25% CA fentanyl for 232 products while HTS JSON shows 35%.
- **India & Brazil rate discrepancy**: Both countries had country-specific EO entries in 9903.01.76-89 (outside extraction range) that stack with Phase 2. Brazil: +40% (EO 14323, 9903.01.77) + 10% (Phase 2) = 50%. India: +25% (9903.01.84) + 25% (Phase 2) = 50%. Expanded extraction range to 43-89, added `country_eo` phase label, updated rate selection to sum across phases. India 84.4%, Brazil 73.6% exact match.
- **Universal IEEPA baseline for unlisted countries**: ~143 countries with no individual entries now get the 10% universal baseline (9903.01.25) as default. CA/MX excluded (fentanyl-only regime). Also fixed within-phase dedup (take best entry, not sum) — fixed Tunisia from 0.2% to 91.6%.
- **China IEEPA reciprocal rate (34% → 10%)**: Post-Geneva suspension of 9903.01.63 not detected due to encoding variation. Added robust secondary regex check. China now 79.7% exact match.
- **Phantom IEEPA countries**: Syria, Moldova, Laos, Falkland Islands, DR Congo excluded from TPC validation. Removes ~95K false-positive pairs.
- **Section 232 derivative products**: ~130 aluminum-containing articles now covered with metal content scaling.
- **Floor country IEEPA selection (Japan/S. Korea)**: Fixed tie-breaking to prefer floor over surcharge.
- **Section 301 blanket coverage and generation stacking**: Expanded from ~10,400 to ~11,000 unique HTS8 codes (~12,200 entries) by adding List 4B (9903.88.16, 1,519 products). Rate aggregation changed from `max()` to generation-based stacking (MAX within generation, SUM across). Added missing ch99 rates: 9903.91.06 (25%), 9903.91.07 (50%), 9903.91.08 (100%), 9903.92.10 (25%). Rev_32 overall improvement: 60.5% → 66.1% exact match; China: 72.4% exact.
- **Switzerland IEEPA over-application (+24pp)**: Fixed via Swiss framework (EO 14346). 15% floor structure replaces +39% surcharge, with product exemptions. See `docs/active_hts_changes.md`.
- **CA/MX fentanyl product-level carve-outs**: Implemented via `resources/fentanyl_carveout_products.csv` (308 HTS8 prefixes). Carve-out products get 10% instead of general rate.
- **2026 HTS revision support**: Pipeline extended through 2026_rev_4 (Feb 25, 2026). USITC download URL updated after `getJSON` deprecation. 4 new policy milestones: semiconductor tariffs (rev_1), Argentina beef quota (rev_3), Section 122 Phase 3 (rev_4).
- **USMCA utilization rates**: Census SPI product-level shares implemented. Rev_32 overall: 63.6% → 66.4% exact match. CA: 44.3% → 79.4%, MX: 44.5% → 83.9%.
