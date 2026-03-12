# Tariff-Rate-Tracker vs Tariff-ETRs Comparison

**Last updated:** 2026-03-12
**Tariff-ETRs scenario:** 2-21_temp (3 dates: 2026-01-01, 2026-02-24, 2026-07-24)
**Tracker build:** Mar 11, 2026 (full R pipeline rebuild with S122 zeroing fix + copper 50% rate + parse_ch99_rate regex fix)

---

## Overall ETR Comparison

| Date | Tracker | Tariff-ETRs | Diff (pp) | Regime |
|------|---------|-------------|-----------|--------|
| 2026-01-01 | 16.02% | 14.25% | **+1.77** | IEEPA + fentanyl + 232 + 301 |
| 2026-02-24 | 12.01% | 10.49% | **+1.53** | S122 + 232 + 301 (IEEPA zeroed) |
| 2026-07-24 | 7.62% | 7.29% | **+0.33** | 232 + 301 + MFN only |

Both use total imports ($3,124B) as denominator, treating unmatched products as 0% tariff. All three dates show the tracker above ETRs. The Feb 24 gap (+1.53pp) is larger than Jul 24 (+0.33pp) because copper 232 products interact with S122 through metal_share stacking — copper's metal_share=1.0 means S122 applies only to the nonmetal share (zero), so S122 revenue on copper is zero in the tracker but nonzero in ETRs.

### Denominator note

The tracker snapshot only contains products with Ch99 tariff exposure. Unmatched products (27.5% of imports at 2026-01-01, 5.2% at 2026-02-24) have zero additional tariff. The correct ETR denominator is total imports across all products, not just the matched subset. Prior versions of this comparison used matched-only imports, which inflated the tracker ETR to 21.96% at 2026-01-01 — an artifact, not a real divergence.

The matched share rises from 72.5% to 94.8% between Jan 1 and Feb 24 because `2026_rev_4` adds S122 entries that cover nearly all products.

---

## IEEPA Period (2026-01-01): Tracker +1.77pp

### Country-level detail

| Country | Tracker | ETRs | Diff (pp) | Primary driver |
|---------|---------|------|-----------|----------------|
| China | 38.85% | 32.80% | +6.06 | 301 rate treatment |
| Canada | 17.16% | 7.21% | +9.95 | USMCA share granularity |
| Mexico | 13.05% | 11.37% | +1.68 | USMCA share granularity |
| Japan | 12.20% | 13.60% | -1.40 | 232 product coverage |
| UK | 6.63% | 6.29% | +0.33 | Near-match |
| EU | 8.91% | 9.30% | -0.38 | Near-match |

The +1.77pp overall gap reflects large offsetting country-level differences: China and Canada push the tracker up; Japan, EU, and others pull it down.

### Divergence source 1: USMCA share granularity (+9.7pp Canada, +1.6pp Mexico)

ETRs applies USMCA exemption rates from a 47-row GTAP sector file (~85-90% shares). The tracker uses product-level Census SPI data (~41% Canada, ~47% Mexico). TPC independently validates the tracker's approach:

| Source | Canada share | Mexico share |
|--------|-------------|-------------|
| TPC (benchmark) | 45.5% | 50.7% |
| Tracker (Census SPI) | 41.2% | 47.3% |
| ETRs (GTAP sectors) | ~85-90% | ~75-85% |

**Assessment:** Tracker is correct. ETRs over-exempts CA/MX by ~2x. Proposed ETRs fix: E1.

### Divergence source 2: Section 301 rate treatment (+4-6pp China)

ETRs applies a flat 301 rate per product. The tracker applies per-list rates (MAX across ch99 codes; Biden supersedes Trump on 8 overlapping products). TPC confirms multi-list rates — 85%+ rates require it:

| TPC rate cluster | Count | Decomposition |
|-----------------|-------|---------------|
| ~35% | 9,290 (64%) | fentanyl(10%) + 301_Trump(25%) |
| ~60% | 3,982 (28%) | 232(25%) + fentanyl(10%) + 301(25%) |
| ~85% | 421 (3%) | fentanyl(10%) + 301_Trump(25%) + 301_Biden(50%) |
| ~95% | 528 (4%) | recip(10%) + fentanyl(10%) + 301_Trump(25%) + 301_Biden(50%) |

**Assessment:** Tracker is correct. Proposed ETRs fix: E2.

### Divergence source 3: 232 product coverage (offsetting, ±1-4pp per country)

HTS2 chapter-level comparison reveals 232 product coverage differences between the two repos. These produce large offsetting gaps at the chapter level:

| Chapter | Tracker | ETRs | Diff | Revenue gap | Issue |
|---------|---------|------|------|-------------|-------|
| Ch87 (autos) | 4.51% | 16.41% | -11.9pp | -$46B | **Fixed:** tracker was applying full USMCA shares to 232 autos; now scales by `us_auto_content_share = 0.4` (T4) |
| Ch72 (base steel) | 40.75% | 0.39% | +40.4pp | +$13B | **ETRs missing ch72** — lists only ch73 steel articles |
| Ch76 (aluminum) | 32.71% | 47.99% | -15.3pp | -$4B | ETRs higher: copper-related derivatives? |
| Ch74 (copper) | 1.05% | 23.45% | -22.4pp | -$4B | Tracker was at 25%, should be 50% (now fixed) |

The ch72 gap is a confirmed ETRs bug: the `s232.yaml` steel product list starts at `73012010`, missing all chapter 72 base steel products (flat-rolled, bars, wire). The ch74 gap was a tracker bug: copper rate should be 50% (matching June 2025 proclamation, 9903.78.01), not 25%.

**Assessment:** Both repos have coverage gaps. Ch72 is ETRs-side; ch74 was tracker-side (now fixed). Ch87 (autos) root cause identified and fixed: see Divergence source 5 below.

### Divergence source 4: Copper 232 product coverage (tracker high, +1pp at Feb 24)

Both repos apply 50% copper 232 rate with identical stacking logic (metal_share scaling, IEEPA/S122 on nonmetal portion only). The difference is product coverage:

| | Tracker | ETRs |
|---|---------|------|
| **Method** | All products under heading prefixes (7406-7419) from `policy_params.yaml` | Curated list of 76 ch74 HTS10 codes + 6 ch8544 (insulated wire) codes in `s232.yaml` `copper_derivatives` section |
| **Headings** | 7406, 7407, 7408, 7409, 7410, 7411, 7412, 7413, 7415, 7418, 7419 | **Identical**: 7406, 7407, 7408, 7409, 7410, 7411, 7412, 7413, 7415, 7418, 7419 |
| **Excluded** | 7401-7405 (refined copper — phased tariffs planned per proclamation), 7414, 7416, 7417 | Same exclusions |
| **Metal share** | Ch74 = 1.0 (primary chapter), others via BEA detail I-O | Identical: ch74 = 1.0 (primary chapter), others via BEA detail I-O |
| **USMCA exempt** | No | No |
| **Ch8544** | Not covered (copper prefixes only) | 6 codes under 8544 (insulated wire with copper conductors) |

**Resolved (Mar 12):** Parsed the authoritative product list from US Note 36, subdivision (b) of Chapter 99 PDF using `scrape_us_notes.R --copper`. **80 HTS10 codes** (76 ch74 + 4 ch8544). This list matches the ETRs curated list exactly (80 for 80). The tracker's prefix approach previously captured 113 codes (33 extra statistical suffixes) and missed 4 ch8544 insulated wire codes. The tracker now uses the authoritative list via `resources/s232_copper_products.csv`.

**Proclamation 10962 (2025-08-05):** Covers "semi-finished copper products and intensive copper derivative products" at 50%. Explicitly defers tariffs on refined copper (headings 7401-7405): phased tariffs of 15% starting Jan 2027, 30% starting Jan 2028. The Annex is encoded in US Note 36(b) of the Chapter 99 PDF, not the Federal Register HTML text.

This contributes to the Feb 24 gap (+1.53pp): copper products interact with S122 through stacking — copper_share=1.0 means S122's nonmetal contribution is zero in the tracker, while ETRs may apply S122 to some ch74 products not in its copper_derivatives list (treating them as non-232).

### Divergence source 5: Auto USMCA content scaling (~4.7pp ch87)

ETRs applies `us_auto_content_share = 0.4` to scale USMCA exemptions for all 232 auto tariffs (passenger vehicles, auto parts, MHD vehicles). This reflects the fact that USMCA-eligible vehicles contain ~60% non-originating content under rules of origin — only 40% of the vehicle's value qualifies for USMCA exemption.

| | Tracker (before fix) | ETRs | Tracker (after fix) |
|---|---|---|---|
| CA USMCA share (90%) applied to 232 | 90% (full) | 36% (90% x 0.4) | 36% (90% x 0.4) |
| Fentanyl kept on CA autos | 10% of 25% = 2.5% | 64% of 25% = 16% | 64% of 25% = 16% |
| MX USMCA share (84%) applied to 232 | 84% (full) | 33.6% (84% x 0.4) | 33.6% (84% x 0.4) |

The scaling applies ONLY to the 232 USMCA exemption (step 7 in `06_calculate_rates.R`). IEEPA/fentanyl/S122 USMCA exemptions use the full product-level share, matching ETRs behavior.

**Resolution (Mar 12):** Added `us_auto_content_share: 0.40` to `policy_params.yaml` under `auto_rebate`. The parameter scales the USMCA share when applied to 232 auto/MHD products for CA/MX. This substantially closes the ch87 gap.

### Why the gap is small overall (+1.77pp)

The USMCA and 301 divergences (tracker high) are offset by 232 product coverage differences (tracker low on autos, ETRs low on base steel). The net effect is a modest +1.77pp.

---

## Non-IEEPA Period

### 2026-02-24: S122 + 232 + 301 (tracker +1.53pp)

| Country | Tracker | ETRs | Diff (pp) |
|---------|---------|------|-----------|
| China | 28.01% | 22.72% | +5.29 |
| Canada | 5.84% | 5.04% | +0.80 |
| Mexico | 8.09% | 9.29% | -1.21 |
| Japan | 14.96% | 11.85% | +3.12 |
| UK | 9.16% | 6.72% | +2.44 |
| EU | 9.72% | 8.05% | +1.66 |

The +1.53pp overall gap is driven by copper 232 stacking with S122. Copper products (ch74) have metal_share=1.0, so the tracker's S122 contribution for these products is zero (S122 applies to nonmetal share only). Non-copper countries show the copper effect clearly: Japan (+3.12pp), UK (+2.44pp), EU (+1.66pp) are all higher because their copper imports now carry 50% 232 rate without S122 offset. China's +5.29pp combines 301 rates and copper. Mexico (-1.21pp) reflects USMCA differences.

### 2026-07-24: 232 + 301 + MFN only (tracker +0.33pp)

| Country | Tracker | ETRs | Diff (pp) |
|---------|---------|------|-----------|
| China | 22.29% | 17.60% | +4.68 |
| Canada | 3.77% | 4.62% | -0.85 |
| Mexico | 5.62% | 8.43% | -2.81 |
| Japan | 7.87% | 8.23% | -0.35 |
| UK | 3.72% | 3.35% | +0.37 |
| EU | 4.56% | 4.12% | +0.44 |

With S122 expired and IEEPA zeroed, only 232, 301, and MFN remain. The overall gap is +0.33pp. China's +4.68pp (301 rates) is partially offset by Mexico -2.81pp and Canada -0.85pp (USMCA differences). Japan is -0.35pp (near-match), UK and EU are within 0.5pp.

Previous versions of this comparison showed a -0.90pp gap at Jul 24 with Japan at -4.20pp. This was caused by a bug in the S122 expiry logic: subtracting the nominal `rate_s122` from `total_additional` over-subtracted for 232 products where metal_share stacking reduced the effective S122 contribution to zero. The fix: reconstruct `total_additional` from remaining component rates after zeroing, rather than subtracting nominal rates.

---

## TPC Product-Level Validation

TPC benchmark provides product-level rates at 5 dates during the IEEPA period. Import-weighted comparison using total imports denominator:

| Date | Tracker | TPC | Diff (pp) | Rev |
|------|---------|-----|-----------|-----|
| 2025-03-17 | 10.43% | 8.00% | +2.43 | rev_6 |
| 2025-04-17 | 15.21% | 23.49% | -8.28 | rev_10 |
| 2025-07-17 | 16.54% | 15.37% | +1.17 | rev_17 |
| 2025-10-17 | 16.29% | 18.23% | -1.94 | rev_18 |
| 2025-11-17 | 16.03% | 16.16% | -0.13 | rev_32 |

The tracker is within ~1pp of TPC at the three non-Liberation-Day dates. The rev_10 outlier (-8.28pp) reflects an HTS encoding gap: country-specific Liberation Day reciprocal rates (EU 20%, Japan 24%, India 26%, etc.) were announced via EO on April 2 but never published as individual country entries in the USITC HTS JSON before being suspended on April 5. See the README [Validation section](../README.md#liberation-day-divergence--828pp-at-rev_10) for full details.

### Within-2pp product-level match rates

| Revision | TPC Date | Within 2pp |
|----------|----------|------------|
| rev_6 | 2025-03-17 | **82.3%** |
| rev_10 | 2025-04-17 | **93.1%** |
| rev_17 | 2025-07-17 | **90.6%** |
| rev_18 | 2025-10-17 | **79.9%** |
| rev_32 | 2025-11-17 | **84.9%** |

---

## Summary of Divergences

| # | Source | Direction | Magnitude | Who's right | Fix | Status |
|---|--------|-----------|-----------|-------------|-----|--------|
| 1 | USMCA share granularity | Tracker high (CA/MX) | +9.7pp CA, +1.6pp MX | **Tracker** (TPC validates) | ETRs E1 | Open |
| 2 | 301 rate treatment | Tracker high (China) | +4-6pp China | **Tracker** (Biden supersedes Trump via MAX) | ETRs E2 | Open |
| 3 | 232 product coverage (steel) | Offsetting | Ch72 ±40pp | ETRs missing ch72 | E3 | Open |
| 4 | Copper 232 product coverage | Was tracker high | ~1pp at Feb 24 | **Resolved** (80/80 match) | D1 | **Done** |
| 5 | Auto USMCA content scaling | Was tracker low (ch87) | ~4.7pp ch87 | **Aligned** (both use 0.4 content share) | T4 | **Done** |

Divergences #1 and #2 are ETRs-side issues confirmed by TPC. Divergence #3: ETRs missing ch72 base steel. Divergence #5 resolved: tracker now applies `us_auto_content_share = 0.4` to scale USMCA exemptions for 232 auto/MHD products, matching ETRs methodology.

---

## Proposed Changes

### Tariff-ETRs

| # | Change | Status | Est. impact |
|---|--------|--------|-------------|
| E1 | Replace GTAP-level USMCA shares with product-level Census SPI data | Open | +4-8pp Canada, +2-3pp Mexico |
| E2 | Implement per-list 301 rates (Biden supersedes Trump on overlap) | Open | +4-6pp China |
| E3 | Add chapter 72 base steel products to s232.yaml | Open | +40pp ch72 (partially offsets E1/E2) |
| D1 | Copper product list reconciled: parsed US Note 36(b), 80 HTS10 codes match ETRs exactly. Tracker now uses authoritative list via `s232_copper_products.csv` | **Done** | ~1pp at Feb 24 |

### Tracker

| # | Change | Status | Est. impact |
|---|--------|--------|-------------|
| T1 | Copper rate 25% → 50% (9903.78.01, June 2025 proclamation) | **Done** | +22pp ch74 |
| T2 | Fix S122 expiry zeroing (reconstruct from components, not subtract) | **Done** | +1.1pp overall at Jul 24 |
| T3 | Fix `parse_ch99_rate()` regex for "a duty of X%" pattern | **Done** | Enables automatic copper rate extraction |
| T4 | Add `us_auto_content_share` (0.4) to scale 232 auto USMCA exemptions | **Done** | ~4.7pp ch87 |

No remaining open tracker-side items. All known divergences are either resolved or confirmed ETRs-side.

---

## Resolved Issues

| Issue | Resolution | Date |
|-------|-----------|------|
| Auto USMCA content scaling | Added `us_auto_content_share = 0.4` to scale USMCA exemptions for 232 auto/MHD products. ETRs uses this parameter to reflect ~60% non-originating content in USMCA-eligible vehicles. Without it, tracker over-exempted CA/MX autos by ~4.7pp on ch87 | 2026-03-12 |
| S122 expiry zeroing | Reconstruct total_additional from remaining components instead of subtracting nominal rate_s122. The nominal rate differs from the effective contribution due to metal_share stacking (232 products). Bug inflated Jul 24 gap from +0.20pp to -0.90pp | 2026-03-11 |
| Copper 232 rate | Config default_rate updated from 0.25 to 0.50 per 9903.78.01 (June 2025 proclamation). Also fixed parse_ch99_rate() regex to handle "a duty of X%" text format | 2026-03-11 |
| ETR denominator | Use total imports ($3,124B), not matched-only. Matched-only inflated tracker ETR from 15.93% to 21.96% at 2026-01-01 | 2026-03-11 |
| Base rate inheritance | Statistical suffixes (~59% of HTS10) inherit MFN from parent indent. 11,558 products fixed | 2026-03-11 |
| 301 Biden supersession | Biden supersedes Trump on 8 overlapping products (MAX, not SUM) | 2026-03-11 |
| S122 timing alignment | Effective 2026-02-24, expiry 2026-07-23 (matching ETRs) | 2026-03-10 |
| IEEPA invalidation | Calendar-date zeroing in compare_etrs.R | 2026-03-10 |
| IEEPA exempt products | Expanded 1,087 to 4,325 HTS10 | 2026-03-09 |
| 232 USMCA shares | Product-level Census SPI replaces binary exemption | 2026-03-09 |
| 232 auto deal rates | 12 entries: UK surcharge/floor, JP/EU/KR 15% floor | 2026-03-09 |
| 232 auto/MHD parts lists | Auto: 130 codes (CBP, Note 33(g)). MHD: 182 codes (Note 34(i)) | 2026-03-10 |
| S122 exempt products | Confirmed identical (1,656 HTS8 codes) | 2026-03-09 |
| Swiss framework | EO 14346, 15% floor, date-bounded | 2026-02 |
| CA/MX fentanyl carve-outs | 308 prefixes | 2026-02 |
| China IEEPA (34% to 10%) | Post-Geneva suspension detection | 2026-02 |
| Universal IEEPA baseline | ~143 unlisted countries get 10% default | 2026-02 |
| 232 derivatives | ~130 aluminum articles with BEA metal content scaling | 2026-02 |
