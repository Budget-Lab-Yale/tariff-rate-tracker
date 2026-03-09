# Tariff-Rate-Tracker vs Tariff-ETRs (2-21_temp) Comparison

**Date:** 2026-03-09
**Tariff-ETRs scenario:** 2-21_temp (3 dates: 2026-01-01, 2026-02-24, 2026-07-24)
**Tracker commit:** 39d5c43

---

## Proposed Changes (Priority Order)

### Tracker changes

| # | Change | Target | Est. Impact | Issues |
|---|--------|--------|-------------|--------|
| T1 | **Apply product-level USMCA shares to 232 auto/MHD** — replace binary exemption (`heading_usmca_exempt → rate=0` for CA/MX) with `rate_232 * (1 - usmca_share)` using Census SPI shares from `usmca_product_shares.csv` | `06_calculate_rates.R` step 4 | **+3-4pp Mexico**, resolves largest single discrepancy | [#7](#issue-7-232-usmca-automhd-exemption--binary-vs-share-based-mexico--3-to--4pp) |
| T2 | **Implement 232 auto deal rates** (Notes 33(h)-(k)) — Japan/Korea/EU autos at 15% floor, UK autos at 7.5% surcharge, UK auto parts at 10% floor, Japan/Korea/EU auto parts at 15% floor | `06_calculate_rates.R` step 4c, `policy_params.yaml` | **-1-2pp Japan/EU/UK** | [#5](#issue-5-232-auto-deal-rates-japan--05pp-eu--05pp-uk--1pp), [#11](#issue-11-japaneu-auto-deal-rates-under-232-japan--11pp-eu-implicit) |
| T3 | **Expand IEEPA product exemptions** — add Brazil EO-specific agricultural/energy exemptions and other country-specific carve-outs to `ieepa_exempt_products.csv` | `resources/ieepa_exempt_products.csv` | **-0.5-1pp overall** | [#3](#issue-3-ieepa-product-exemptions-overall--05-to--1pp-for-etrs) |
| T4 | **Fix Brazil/India country EO stacking** — ensure country-specific EO rates (e.g., Brazil +40% from 9903.01.77, India +25% from 9903.01.84) stack with the universal 10% baseline (9903.01.25) rather than replacing it. **TPC validates**: Brazil TPC mean=43.1% vs tracker 10.0% (-33pp); India TPC mean=44.2% vs tracker 25.0% (-19pp) | `05_parse_policy_params.R`, `06_calculate_rates.R` step 2 | **+30pp Brazil, +19pp India** (country-specific) | [#6](#issue-6-brazilindia-country-eo-classification-minimal-net-impact), [TPC validation](#country-level-tpc-mean-rates-vs-tracker-vs-etrs-nov-2025-unweighted-product-mean) |
| T5 | **Expand IEEPA product exemptions** — add Brazil EO-specific agricultural/energy exemptions and other country-specific carve-outs to `ieepa_exempt_products.csv`. TPC exempts 22% of Japan products vs tracker ~1%; EU similar gap. | `resources/ieepa_exempt_products.csv` | **-0.5-1pp overall** | [#3](#issue-3-ieepa-product-exemptions-overall--05-to--1pp-for-etrs), [TPC validation](#floor-rates-tpc-confirms-floor--product-exemptions) |
| T6 | **Narrow 232 auto/MHD parts prefix matching** — audit `s232_auto_parts.txt` (136 prefixes) and `s232_mhd_parts.txt` (182 prefixes) against proclamation HTS10 lists; remove overly broad prefixes like '8471' | `resources/s232_auto_parts.txt`, `resources/s232_mhd_parts.txt` | **-0.5-1pp scattered** | [#4](#issue-4-section-232-automhd-parts-coverage-japan-05-1pp-others-smaller) |
| T7 | **Add 15 missing S122 exempt products** — reconcile `s122_exempt_products.csv` (1,656) against ETRs list (1,671) | `resources/s122_exempt_products.csv` | **~0.1pp** | [#10](#issue-10-s122-product-exemptions-minimal--01pp) |

### Tariff-ETRs changes

| # | Change | Target | Est. Impact | Issues |
|---|--------|--------|-------------|--------|
| E1 | **Replace GTAP-level USMCA shares with product-level Census SPI data** — current 47-row GTAP file (`usmca_shares.csv`) systematically over-exempts; adopt HTS10-level shares from Census SPI (same source as tracker). **TPC validates**: TPC implied USMCA shares (CA=45.5%, MX=50.7%) match tracker SPI shares closely, not ETRs GTAP shares (~85-90%) | `resources/usmca_shares.csv`, `calculations.R` | **+4-8pp Canada, +2-3pp Mexico** (pre-S122) | [#1](#issue-1-usmca-exemption-granularity--magnitude-canada-87pp-mexico-19pp), [#8](#issue-8-s122-usmca-reduction--product-level-vs-gtap-shares-mexico-1-to-2pp-partially-offsetting-issue-7), [TPC validation](#usmca-tpc-confirms-continuous-product-level-shares) |
| E2 | **Implement 301 generation-based stacking** — currently assigns each product one flat rate; should SUM across Trump/Biden generations (MAX within each) per legal structure. **TPC validates**: China products at 85-95% only possible with generation stacking (25%+50%/100%) | `config/2-21_temp/*/s301.yaml` generation, `config_parsing.R` or manual yaml rebuild | **+2-3pp China** | [#2](#issue-2-section-301-rate-stacking-china-2-3pp), [#9](#issue-9-china-301-stacking-persistent-from-pre-s122-317pp), [TPC validation](#section-301-tpc-confirms-generation-stacking) |

### Joint verification needed

| # | Item | Issues |
|---|------|--------|
| J1 | **301 legal interpretation**: Do Biden 301 modifications (Lists 1-4 modifications, 9903.91.xx) *replace* or *supplement* Trump original rates (9903.88.xx) on overlapping products? Both repos should agree. | [#2](#issue-2-section-301-rate-stacking-china-2-3pp) |
| J2 | **232 auto parts product lists**: Neither repo has a definitive HTS10 list from USITC for auto/MHD parts under Proclamation 10908. Both use approximations (prefix matching vs manual HTS10 lists). | [#4](#issue-4-section-232-automhd-parts-coverage-japan-05-1pp-others-smaller) |

---

## Overall ETR Comparison (Census import-weighted, including MFN)

| Date | Tracker | Tariff-ETRs | Diff (pp) |
|------|---------|-------------|-----------|
| 2026-01-01 (pre-S122) | 18.36% | 14.25% | **+4.11** |
| 2026-02-25 (S122 active) | 9.53% | 10.49% | **-0.96** |

## Country-Level ETR Comparison

### 2026-01-01 (pre-Section 122, all IEEPA active)

| Country | Tracker | Tariff-ETRs | Diff (pp) |
|---------|---------|-------------|-----------|
| China | 39.42% | 32.80% | **+6.62** |
| Canada | 15.87% | 7.21% | **+8.66** |
| Mexico | 13.24% | 11.37% | **+1.87** |
| Japan | 15.37% | 13.60% | **+1.77** |
| UK | 10.05% | 6.29% | **+3.76** |

### 2026-02-25 (S122 active, IEEPA suspended)

| Country | Tracker | Tariff-ETRs | Diff (pp) |
|---------|---------|-------------|-----------|
| China | 25.89% | 22.72% | **+3.17** |
| Canada | 4.89% | 5.04% | **-0.15** |
| Mexico | 4.02% | 9.29% | **-5.27** |
| Japan | 10.75% | 11.85% | **-1.10** |
| UK | 6.15% | 6.72% | **-0.57** |

---

## TPC Product-Level Rate Validation (Pre-S122)

TPC benchmark data (`data/tpc/tariff_by_flow_day.csv`) provides product-level rates at 5 pre-S122 dates for ~240 countries x ~19,800 products. Comparing TPC's product-level rates against both the tracker and Tariff-ETRs clarifies which repo is closer to correct on each issue.

### USMCA: TPC Confirms Continuous Product-Level Shares

TPC uses **continuous product-level USMCA utilization shares**, producing a smooth distribution of rates between 0% and the headline fentanyl rate. This is visible in the Canada rate distribution at rev_32 (Nov 2025): products are spread across every percentage point from 0% to 35%, not clustered at binary 0%/35%.

**Implied TPC USMCA utilization shares (from product-level rates):**

| Country | TPC Implied | Tracker Census SPI | ETRs GTAP Sectors |
|---------|------------|-------------------|-------------------|
| Canada | **45.5%** (mean, 10,667 products) | 41.2% (12,251 pairs) | ~85-90% |
| Mexico | **50.7%** (mean, 8,792 products) | 47.3% (10,423 pairs) | ~75-85% |

**Verdict:** The tracker's Census SPI shares (41-47%) closely match TPC's implied shares (45-51%). The ETRs GTAP sector shares (75-90%) are roughly **double** what TPC uses, confirming ETRs systematically over-exempts CA/MX. This is the strongest validation that the tracker's USMCA approach is correct and ETRs needs to adopt product-level shares (proposed change E1).

### Floor Rates: TPC Confirms Floor + Product Exemptions

TPC rate distributions for floor-rate countries (Nov 2025):

| Country | 0% (exempt) | ~10% (baseline) | ~15% (floor) | ~25% (reciprocal) | ~50% (232) |
|---------|------------|-----------------|-------------|-------------------|------------|
| Japan | 22% | 27% | 30% | 9% | — |
| S. Korea | 20% | 11% | 53% | — | 7% |
| EU avg | 23% | — | 25% | — | 6% |

The tracker also clusters Japan at 15% (73% of products), confirming floor rates ARE implemented. However, TPC exempts 22% of Japan products (rate=0%) vs the tracker's ~1%. These are likely Annex A exempt products and/or duty-free products that TPC excludes from IEEPA. **This product exemption gap — not missing floor logic — is the main Japan/EU discrepancy driver** (see Issue 3).

### Section 301: TPC Confirms Generation Stacking

China product rates in TPC go well above 60%, confirming generation-based stacking:

| TPC Rate | Count | Likely Decomposition |
|----------|-------|---------------------|
| ~35% | 9,290 (64%) | fentanyl(10%) + 301_Trump(25%) |
| ~60% | 3,982 (28%) | 232(25%) + fentanyl(10%) + 301(25%) |
| ~85% | 421 (3%) | fentanyl(10%) + 301_Trump(25%) + 301_Biden(50%) |
| ~95% | 528 (4%) | recip(10%) + fentanyl(10%) + 301_Trump(25%) + 301_Biden(50%) |

The 85% and 95% rates are **only possible with generation stacking** (25% Trump + 50% Biden = 75%, plus fentanyl). This validates the tracker's approach (Issue 2) and confirms ETRs should implement it (proposed change E2).

Note: TPC rates of 95% also confirm TPC stacks IEEPA reciprocal on 232 (no mutual exclusion) — a known methodological difference from both the tracker and ETRs.

### Country-Level TPC Mean Rates vs Tracker vs ETRs (Nov 2025, unweighted product mean)

| Country | TPC Mean | Tracker Mean | Diff (T-TPC) | ETRs Level (Jan 1) | Notes |
|---------|----------|-------------|-------------|-------------------|-------|
| China | 41.5% | 42.0% | **+0.5pp** | 32.8% | Tracker ≈ TPC; ETRs too low (301 stacking) |
| Canada | 22.6% | 25.0% | +2.4pp | 7.2% | Tracker close; ETRs way too low (USMCA) |
| Mexico | 16.8% | 25.0% | +8.2pp | 11.4% | Tracker too high (stale comparison?); ETRs closer |
| Japan | 12.4% | 25.0% | +12.6pp | 13.6% | ETRs ≈ TPC; Tracker too high (product exemptions) |
| Brazil | 43.1% | 10.0% | -33.1pp | N/A | Tracker missing Brazil +40% EO rate |
| India | 44.2% | 25.0% | -19.2pp | N/A | Tracker missing India +25% EO stacking |

*Note: Unweighted product means differ from import-weighted ETRs. The Mexico/Japan tracker means may reflect stale comparison data (pre-fix code).*

---

## Pre-S122 Issues (2026-01-01)

### Issue 1: USMCA Exemption Granularity & Magnitude (Canada +8.7pp, Mexico +1.9pp)

**Tariff-Rate-Tracker:**
- Uses **HTS10 x country** Census SPI utilization shares (22,450 product-country pairs)
- Or binary S/S+ flag fallback (~24% of products eligible)
- Product-level shares capture actual claim rates — many products with 0% utilization despite technical eligibility

**Tariff-ETRs:**
- Uses **GTAP sector-level** utilization shares (47 sectors)
- Shares are extremely high: agriculture ~99.95%, motor vehicles ~91.4% (CA) / 71.4% (MX), chemicals ~97.3% / 95.3%, iron/steel ~48.2% / 83.8%
- Every product in a sector gets the sector-average reduction — even products with zero actual USMCA claims

**Impact:** Single largest driver of the Canada gap. Tariff-ETRs effectively exempts ~90%+ of Canadian imports from fentanyl (35%) and IEEPA rates, while the tracker exempts a smaller share at product level. Rough calculation: Canada fentanyl contribution = 35% x (1 - effective_usmca_rate). If ETRs exempts ~85% of Canadian imports vs tracker exempting ~50%, the gap is 35% x 0.35 = ~12pp on Canada-specific ETR, which accounts for the 8.7pp gap after import weighting.

**Which is more right:** **The tracker is closer to correct.** GTAP-sector shares overstate USMCA utilization by spreading sector averages to products that never claim USMCA. HTS10-level Census SPI data captures actual utilization patterns. The ETRs approach is a useful approximation but systematically over-exempts.

---

### Issue 2: Section 301 Rate Stacking (China +2-3pp)

**Tariff-Rate-Tracker:**
- 12,223 HTS8 products from `s301_product_lists.csv`
- **Generation-based aggregation**: MAX within a generation (Trump or Biden), then SUM across generations
- Products on both Trump List 1 (25%) and Biden List (50%) get 25% + 50% = **75%**
- Products on Trump + Biden 100% get 25% + 100% = **125%**

**Tariff-ETRs:**
- 16,942 HTS10 codes in s301.yaml, pre-assigned to flat rate buckets:
  - 11,760 at 25%, 5,080 at 7.5%, 69 at 50%, 33 at 100%
- **No generation stacking** — each product is assigned one net rate
- Products that appear on both Trump and Biden lists get only the **Biden rate** (max, not sum)

**Impact:** For overlapping products (those on both Trump 25% lists and Biden 50%/100% lists), the tracker computes 75-125% while ETRs computes 50-100%. Given that ~100 products fall in the 50-100% Biden buckets, the import-weighted impact on China is approximately 2-3pp.

**Which is more right:** **Legally, the tracker's generation-based SUM is correct.** Section 301 tariffs from different Presidential actions (Trump Lists 1-4 vs Biden modifications) are separate proclamations that cumulate. The USITC "China Tariffs" reference document shows these as additive layers. However, the ETRs' flat-rate approach may reflect an assumption that Biden modifications *replaced* rather than *added to* Trump rates on overlapping products — this needs legal verification for each specific List/action pair.

---

### Issue 3: IEEPA Product Exemptions (Overall -0.5 to -1pp for ETRs)

**Tariff-Rate-Tracker:**
- Annex A exemptions: `resources/ieepa_exempt_products.csv` (~1,087 HTS8 codes)
- Floor exemptions: `resources/floor_exempt_products.csv`
- `ieepa_duty_free_treatment: 'all'` — IEEPA applies even to zero-MFN products

**Tariff-ETRs:**
- ~2,800 HTS10 codes explicitly set to 0% in the `product_rates` section of `ieepa_reciprocal.yaml`
- These include Annex A products + Brazil EO exemptions + additional country-specific carve-outs
- Products with zero MFN are not separately flagged, but specific product exemptions implicitly handle some

**Impact:** ETRs exempts more products (~2,800 HTS10 vs ~1,087 HTS8), lowering its effective IEEPA rate. Additionally, the tracker's `ieepa_duty_free_treatment: 'all'` applies IEEPA to products with zero MFN base rate, which ETRs may not do for some of those products.

**Which is more right:** **ETRs is more comprehensive on product exemptions.** The additional exemptions in ETRs appear to reflect actual policy carve-outs (Brazil agricultural exemptions, energy products). The tracker's Annex A file may be incomplete. However, the tracker's `ieepa_duty_free_treatment: 'all'` is legally correct — IEEPA tariffs apply regardless of MFN rate.

---

### Issue 4: Section 232 Auto/MHD Parts Coverage (Japan +0.5-1pp, Others smaller)

**Tariff-Rate-Tracker:**
- Auto parts: 136 HTS prefixes (from `resources/s232_auto_parts.txt`)
- MHD parts: 182 HTS prefixes (from `resources/s232_mhd_parts.txt`)
- Includes broad prefixes like '8471', '8707' that match many products

**Tariff-ETRs:**
- Auto parts: explicit HTS10 list in s232.yaml (likely narrower, with deal rates for Japan/Korea/EU/UK)
- MHD parts: explicit HTS10 list in s232.yaml
- Deal rates: Japan/Korea/EU at 15% floor, UK at 10% floor for auto parts

**Impact:** The tracker's broader prefix matching (e.g., '8471' matches ALL computer products) may capture more products under 232 than intended. This would raise 232 contribution and reduce IEEPA contribution (mutual exclusion). Net effect depends on whether 232 rate > IEEPA rate for those products.

**Which is more right:** **ETRs is more right for now.** Explicit HTS10 lists from the proclamation text are more precise than broad prefix matching. The tracker's prefix files may over-match. However, both approaches are approximations until USITC publishes definitive product lists.

---

### Issue 5: 232 Auto Deal Rates (Japan -0.5pp, EU -0.5pp, UK -1pp)

**Tariff-Rate-Tracker:**
- Floor rate mechanism: `effective_232 = max(floor_rate - base_rate, 0)` for EU/Japan/Korea
- UK: 25% steel/aluminum (country override from HTS), but auto deal rates may not be fully implemented
- Auto parts deal rates: unclear if fully implemented for all partners

**Tariff-ETRs:**
- Explicit deal rates via `target_total` mechanism:
  - Japan/Korea/EU autos: 15% floor (effective add-on = max(15% - MFN, 0))
  - UK autos: 7.5% additive surcharge
  - UK auto parts: 10% floor
  - Japan/Korea/EU auto parts: 15% floor

**Impact:** The tracker may apply the full 25% 232 auto rate to Japan/EU/UK instead of the lower deal rates, explaining part of the Japan +1.8pp and UK +3.8pp gaps.

**TPC validation:** TPC rate distributions for Japan show 30% of products at exactly 15% (floor), confirming deal rates are standard practice. The tracker also clusters 73% of Japan products at 15%, suggesting floor rates ARE partially implemented for IEEPA reciprocal. The gap is specifically in 232 auto deal rates, where the tracker uses the default 25% instead of the 15% floor for Japan/Korea/EU.

**Which is more right:** **ETRs is more right.** The auto deals (Notes 33(h)-(k) to Chapter 99) provide specific negotiated rates for these partners that are lower than the default 25%. The tracker should implement these deal rates.

---

### Issue 6: Brazil/India Country EO Stacking (MAJOR — validated by TPC)

**Tariff-Rate-Tracker:**
- Brazil +40% (9903.01.77) classified as **reciprocal** (country_eo range 9903.01.76-89)
- India +25% (9903.01.84) classified as **reciprocal**
- Universal 10% baseline (9903.01.25) classified as **reciprocal**
- Within Phase 1 reciprocal, the tracker picks the MAX entry — so Brazil gets 40% (not 40% + 10% = 50%)

**Tariff-ETRs:**
- Brazil +40% classified as **fentanyl** + reciprocal default 10%
- India +25% in reciprocal with headline 15%
- Both stack because they're in separate IEEPA yaml files (reciprocal + fentanyl)

**TPC validation (Nov 2025):**
- **Brazil**: TPC mean = **43.1%**, Tracker mean = **10.0%** (-33pp gap!)
- **India**: TPC mean = **44.2%**, Tracker mean = **25.0%** (-19pp gap!)
- These are the largest country-level gaps in the entire comparison

**Root cause:** The tracker treats Brazil's +40% as replacing the universal 10% baseline (MAX within Phase 1), giving Brazil only 40%. TPC gives Brazil ~43% (40% country EO + ~3% from other authorities). The tracker also appears to be computing Brazil's rate far below even 40% — the 10% mean suggests the Brazil EO rate isn't being extracted at all, or is being misclassified.

**Impact:** For Brazil with 232: ETRs computes `(10% recip + 40% fent) x nonmetal` while tracker computes `(40% recip + 0% fent) x nonmetal` — i.e. 50% vs 40% on nonmetal. But the TPC data suggests the overall gap is much larger than this classification difference alone.

**Which is more right:** **ETRs is more right, and the tracker has a likely bug.** Brazil's TPC mean of 43.1% vs tracker's 10.0% indicates the tracker is NOT applying the Brazil +40% EO rate at all for most products. This needs urgent investigation — the Brazil EO extraction or application may be broken.

---

### Pre-S122 Gap Attribution Summary

| Issue | Impact on Gap | More Right |
|-------|--------------|------------|
| 1. USMCA granularity | **+5 to +8pp** (Canada, ~1pp overall) | **Tracker** (product-level SPI) |
| 2. 301 generation stacking | **+2-3pp** (China, ~0.3pp overall) | **Tracker** (legally correct sum) |
| 3. IEEPA product exemptions | **-0.5 to -1pp** (overall) | **ETRs** (more complete) |
| 4. 232 auto/MHD parts scope | **+0.5-1pp** (scattered) | **ETRs** (explicit HTS10 lists) |
| 5. Auto deal rates | **+1-2pp** (Japan/EU/UK) | **ETRs** (negotiated deals) |
| 6. Brazil/India EO stacking | **-30pp Brazil, -19pp India** (country-specific); ~0.5pp overall | **ETRs** (likely tracker bug) |

The overall +4.1pp gap is primarily driven by Issues 1 (USMCA) and 2 (301 stacking) pushing the tracker higher, partially offset by Issues 3-5 where ETRs has more complete implementation. Issue 6 (Brazil/India) is the largest country-specific gap but has small overall impact due to low import shares. TPC product-level data strongly validates the tracker on USMCA (Issue 1) and 301 stacking (Issue 2), while flagging Brazil/India as a likely tracker bug.

---

## Post-S122 Issues (2026-02-25)

**Context:** At 2026-02-25, SCOTUS has invalidated IEEPA authority. Both repos zero out IEEPA reciprocal and fentanyl. The active tariffs are: Section 122 (10% blanket), Section 232, Section 301 (China only), and MFN. The overall gap flips direction (tracker is now -0.96pp LOWER), and the country-level pattern changes dramatically — Mexico goes from +1.9pp to **-5.3pp**.

### Issue 7: 232 USMCA Auto/MHD Exemption — Binary vs Share-Based (Mexico -3 to -4pp)

**Tariff-Rate-Tracker:**
- 5 heading-level 232 programs marked `usmca_exempt: true`: autos_passenger, autos_light_trucks, auto_parts, mhd_vehicles, mhd_parts
- **Binary exemption**: if CA/MX, `heading_rate_adj = 0` — full zeroing of 232 rate on these products
- Effect: Mexico/Canada pay **zero** 232 on all auto/MHD products

**Tariff-ETRs:**
- 232 auto programs also marked `usmca_exempt: 1`
- **Share-based exemption**: `s232_rate * (1 - usmca_share)` where `usmca_share` comes from GTAP sector averages
- Mexico motor vehicles (mvh): usmca_share = 71.4% → effective 232 auto rate = 25% x (1 - 0.714) = **7.15%**
- Canada motor vehicles (mvh): usmca_share = 91.4% → effective 232 auto rate = 25% x (1 - 0.914) = **2.15%**

**Impact:** Auto/MHD products are a large share of Mexico's exports to the US (~25-30% of bilateral trade). The tracker zeroing 232 on these products removes ~7% x 0.25 = ~1.8pp from Mexico's ETR. Combined with parts coverage, this likely accounts for 3-4pp of Mexico's -5.3pp gap.

**Which is more right:** **Neither is clearly correct — this is a modeling choice.** USMCA qualification is binary per-shipment (either a shipment qualifies or it doesn't), which supports the tracker's binary approach. However, not all shipments claim USMCA preferences (some lack required documentation, some are non-originating), which supports ETRs' share-based approach. The ideal would be product-level utilization rates applied to 232 (the tracker has these in `usmca_product_shares.csv` but only applies them to IEEPA/S122, not to 232). Applying product-level shares to 232 would be the most accurate approach.

---

### Issue 8: S122 USMCA Reduction — Product-Level vs GTAP Shares (Mexico +1 to +2pp, partially offsetting Issue 7)

**Tariff-Rate-Tracker:**
- S122 rate reduced by product-level Census SPI shares: `rate_s122 * (1 - usmca_share)`
- Mean USMCA share for Mexico: **47.3%** → average effective S122 = 10% x (1 - 0.473) = ~5.3%
- Mean USMCA share for Canada: **41.2%** → average effective S122 = 10% x (1 - 0.412) = ~5.9%

**Tariff-ETRs:**
- S122 rate reduced by GTAP sector shares: `s122_rate * (1 - usmca_share)`
- GTAP shares for Mexico are generally higher: agriculture ~99.97%, chemicals ~95.3%, motor vehicles ~71.4%
- Import-weighted average likely ~70-80% → effective S122 = 10% x (1 - ~0.75) = ~2.5%

**Impact:** The tracker applies MORE S122 to Mexico (5.3% vs ~2.5%), which partially offsets the 232 auto difference. This contributes roughly +1-2pp to the tracker's Mexico rate, narrowing the gap from Issue 7.

**Which is more right:** **The tracker is closer to correct** (same reasoning as Issue 1). Product-level Census SPI data captures actual USMCA claim rates more accurately than GTAP sector averages. The GTAP approach over-exempts by spreading high-utilization products' shares to the entire sector.

---

### Issue 9: China 301 Stacking (Persistent from Pre-S122, +3.17pp)

Same as Issue 2 — the generation-based SUM vs flat rate difference persists because Section 301 is unaffected by the IEEPA invalidation. The gap narrows slightly from +6.6pp to +3.2pp because the pre-S122 China gap also included IEEPA rate differences that are now zeroed.

**Residual gap composition (~3.2pp):**
- 301 generation stacking: ~2pp (same as before)
- S122 for China: 10% blanket in both, but product exemption scope may differ slightly
- 232 for China: should be similar in both repos
- Remaining ~1pp: likely from 232 auto/MHD parts coverage difference (tracker's broader prefix matching assigns more products to 232, which preempts S122 via mutual exclusion)

**Which is more right:** Same as Issue 2 — **tracker is legally correct** on generation-based 301 stacking.

---

### Issue 10: S122 Product Exemptions (Minimal, -0.1pp)

**Tariff-Rate-Tracker:** 1,656 HTS8 codes exempt (Annex II list from `resources/s122_exempt_products.csv`)

**Tariff-ETRs:** 1,671 HTS8 codes exempt (built into `product_rates` section of s122.yaml with rate = 0)

**Impact:** The 15-product difference is negligible. Both repos source from the same Annex II proclamation text. Minor discrepancies likely reflect different parsing/rounding of edge cases.

**Which is more right:** **ETRs has 15 more exempt products** — the tracker should verify its list is complete.

---

### Issue 11: Japan/EU Auto Deal Rates Under 232 (Japan -1.1pp, EU implicit)

Same as Issue 5 — persists through the S122 period because 232 is unaffected by IEEPA invalidation. Japan auto deal rates (15% floor) vs tracker's default 25% rate, plus auto parts deal rates not fully implemented in the tracker.

With IEEPA zeroed, the gap is now net negative for Japan (tracker -1.1pp). Explanation: the tracker's broader auto parts prefix matching (136 prefixes) captures many products under 232 at 25%, displacing S122 (10%) via mutual exclusion. Meanwhile, ETRs applies the 15% floor deal rate and keeps more products under S122. The net effect flips because 232 mutual exclusion reduces the combined rate.

**Which is more right:** **ETRs** — auto deal rates should be implemented in the tracker.

---

### Post-S122 Gap Attribution Summary

| Issue | Impact on Gap | More Right |
|-------|--------------|------------|
| 7. 232 USMCA binary vs shares | **-3 to -4pp** (Mexico) | **Both partial** (product-level shares ideal) |
| 8. S122 USMCA granularity | **+1 to +2pp** (Mexico, partially offsets #7) | **Tracker** (product-level SPI) |
| 9. 301 generation stacking | **+3.2pp** (China) | **Tracker** (legally correct sum) |
| 10. S122 exempt products | **-0.1pp** (all) | **ETRs** (15 more products) |
| 11. Auto deal rates | **-1 to -2pp** (Japan/EU/UK) | **ETRs** (negotiated deals) |

The overall -0.96pp gap is the net result of: China's persistent +3.2pp (301 stacking) offset by Mexico's -5.3pp (232 binary USMCA + S122 share differences) and Japan/EU deal rate differences.

---

## Cross-Cutting Recommendations

1. **USMCA shares for 232**: The tracker should apply product-level Census SPI utilization shares to 232 auto/MHD rates (not binary), matching how it already handles IEEPA/S122. This would resolve the largest post-S122 discrepancy.

2. **Auto deal rates**: The tracker should implement Note 33(h)-(k) deal rates for Japan/Korea/EU/UK autos and auto parts (15% floor for Japan/Korea/EU, 7.5%/10% for UK).

3. **301 generation stacking**: Verify legal interpretation — do Biden 301 modifications replace or supplement Trump rates on overlapping products? Both repos should agree on the treatment.

4. **IEEPA product exemptions**: The tracker's Annex A file (1,087 HTS8) should be expanded to include Brazil EO-specific exemptions and any additional carve-outs.

5. **S122 exempt products**: The tracker should add the 15 missing exempt products to align with ETRs.

6. **Brazil/country EO stacking**: The tracker should ensure country-specific EO rates (e.g., Brazil +40%) stack with the universal 10% baseline rather than replacing it.
