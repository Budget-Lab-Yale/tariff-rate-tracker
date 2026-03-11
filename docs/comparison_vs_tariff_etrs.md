# Tariff-Rate-Tracker vs Tariff-ETRs Comparison

**Date:** 2026-03-10 (updated after full pipeline rebuild + IEEPA invalidation fix)
**Tariff-ETRs scenario:** 2-21_temp (3 dates: 2026-01-01, 2026-02-24, 2026-07-24)
**Tracker commit:** post T1-T3 + T6a/T6b + IEEPA invalidation fix in compare_etrs.R

---

## Current Validation Status (Post-Fix)

### TPC Product-Level Match Rates

| Revision | TPC Date | Comparisons | Exact (<0.5pp) | Within 2pp | Mean Abs Diff |
|----------|----------|-------------|----------------|------------|---------------|
| rev_6 | 2025-03-17 | 72,563 | 47.4% | 48.2% | 7.97pp |
| rev_10 | 2025-04-17 | 271,037 | 84.4% | **84.8%** | 2.94pp |
| rev_17 | 2025-07-17 | 270,099 | 81.8% | **85.4%** | 2.11pp |
| rev_18 | 2025-10-17 | 269,268 | 65.1% | **67.8%** | 4.59pp |
| rev_32 | 2025-11-17 | 269,249 | 72.8% | **75.7%** | 3.22pp |

Rev_6 is pre-IEEPA (differences dominated by 232 auto/USMCA treatment). Rev_10/17 are peak accuracy. Rev_18/32 are lower due to floor country rate distribution divergence and Phase 2 complexity.

**Duty-free sensitivity**: Switching `ieepa_duty_free_treatment` to `'nonzero_base_only'` would boost rev_32 exact match from 72.8% → 87.9% (+15.1pp). This is the single largest remaining lever — 40,558 products (15.1%) where we apply IEEPA to duty-free products but TPC does not (concentrated in apparel ch61-62, machinery ch84-85).

### Changes Since Initial Comparison (March 2-9, 2026)

| Fix | Impact | New TPC Match |
|-----|--------|---------------|
| T1: USMCA shares applied to 232 auto/MHD | Share-based instead of binary exemption for CA/MX | Resolves Mexico 232 gap |
| T2: 232 auto deal rates (UK/JP/EU/KR) | 12 deal entries now extracted and applied | -1-2pp Japan/EU/UK |
| T3: IEEPA exempt products expanded | 1,087 → 2,172 → 4,325 HTS10 codes (HTS8→10 expansion, Ch98, ITA prefixes) | +2.4pp rev_10, +2.5pp rev_17, +1.9pp rev_18, +3.6pp rev_32 |
| T4: Brazil/India country EO (confirmed correct) | No change — stacking already correct | N/A |
| T7: S122 exempt products (confirmed identical) | No change — both repos have 1,656 codes | N/A |

---

## Changes Completed and Remaining

### Tracker changes

| # | Change | Status | Files |
|---|--------|--------|-------|
| ~~T1~~ | **Apply product-level USMCA shares to 232 auto/MHD** — replaced binary exemption with `rate_232 * (1 - usmca_share)` using Census SPI shares | **DONE** | `06_calculate_rates.R` step 4 + step 7 |
| ~~T2~~ | **Implement 232 auto deal rates** — fixed ch99 parser, program classification, vehicle/parts separation. Extracts 12 entries: UK surcharge/floor, JP/EU/KR 15% floor | **DONE** | `03_parse_chapter99.R`, `05_parse_policy_params.R`, `06_calculate_rates.R` |
| ~~T3~~ | **Expand IEEPA product exemptions** — (a) merged ETRs exempt products (1,087 → 2,172), (b) expanded HTS8→HTS10 (+1,993), (c) added Ch98 statutory exemption per US Notes (v)(i) (+101), (d) expanded ITA prefixes (+59). Total: 4,325 HTS10 codes | **DONE** | `resources/ieepa_exempt_products.csv`, `src/expand_ieepa_exempt.R` |
| ~~T4~~ | **Brazil/India country EO stacking** — confirmed already correct (country_eo + Phase 2 = 50%) | **RESOLVED** | N/A |
| ~~T6a~~ | **Replace auto parts list with CBP official source** — CBP "Automobile Parts HTS List" (US Note 33(g)/(h), 9903.94.05/.06). Removed 7 MHD-only codes, added 8483.10.30. 136 → 130 prefixes | **DONE** | `resources/s232_auto_parts.txt` |
| ~~T6b~~ | **Verify MHD parts list** — confirmed 182 codes match live HTSUS US Note 34, subdivision (i), heading 9903.74.08 exactly | **RESOLVED** | `resources/s232_mhd_parts.txt` |
| ~~T7~~ | **S122 exempt products** — confirmed identical (1,656 HTS8 codes) | **RESOLVED** | N/A |

### Tariff-ETRs changes

| # | Change | Status | Est. Impact |
|---|--------|--------|-------------|
| E1 | **Replace GTAP-level USMCA shares with product-level Census SPI data** — ETRs' 47-row GTAP file (~85-90% shares) systematically over-exempts; TPC validates tracker's approach (45-51% shares) | **Open** | +4-8pp Canada, +2-3pp Mexico |
| E2 | **Implement 301 generation-based stacking** — assign SUM across Trump/Biden generations instead of flat rate. TPC validates: 85-95% rates only possible with stacking | **Open** | +2-3pp China |

### Joint verification

| # | Item |
|---|------|
| J1 | **301 legal interpretation**: Do Biden 301 modifications *replace* or *supplement* Trump original rates on overlapping products? |
| ~~J2~~ | **232 auto parts product lists**: Resolved — CBP published "Automobile Parts HTS List" (Attachment 2) referencing US Note 33(g)/(h), heading 9903.94.05/.06. 130 HTS codes. Updated `s232_auto_parts.txt`: removed 7 MHD-only codes (8708.99.xx), added 1 missing prefix (8483.10.30). MHD parts list (s232_mhd_parts.txt) unchanged — no equivalent CBP source yet. |

---

## Overall ETR Comparison (Census import-weighted, including MFN)

| Date | Tracker | Tariff-ETRs | Diff (pp) | Notes |
|------|---------|-------------|-----------|-------|
| 2026-01-01 | 21.21% | 15.59% | **+5.61** | Pre-S122; all IEEPA active |
| 2026-02-24 | 10.54% | 10.50% | **+0.04** | S122 active, IEEPA zeroed — near-perfect match |
| 2026-07-24 | 5.91% | 7.34% | **-1.43** | S122 expired; 232 + 301 only |

After aligning S122 timing with ETRs (effective 2026-02-24, expiry 2026-07-23), the 2026-02-24 gap dropped from -5.57pp to +0.04pp. The `2026_rev_4` effective_date was also moved to 2026-02-24 so the S122 snapshot is loaded for that date.

Note: ETRs scenario `2-21_temp` uses `2026-02-24` and `2026-07-24` dates; tracker maps to `2026_rev_4` for both.

## Country-Level ETR Comparison

### 2026-01-01 (pre-Section 122, all IEEPA active)

| Country | Tracker | Tariff-ETRs | Diff (pp) |
|---------|---------|-------------|-----------|
| China | 38.27% | 32.80% | **+5.48** |
| Canada | 16.99% | 7.21% | **+9.78** |
| Mexico | 13.00% | 11.37% | **+1.62** |
| Japan | 16.03% | 13.60% | **+2.42** |
| UK | 10.45% | 6.29% | **+4.16** |
| EU | 16.78% | 11.78% | **+5.00** |

### 2026-02-24 (S122 active, IEEPA zeroed)

| Country | Tracker | Tariff-ETRs | Diff (pp) |
|---------|---------|-------------|-----------|
| China | 27.50% | 22.72% | **+4.78** |
| Canada | 4.93% | 5.04% | **-0.11** |
| Mexico | 7.33% | 9.29% | **-1.96** |
| Japan | 11.20% | 11.85% | **-0.65** |
| UK | 6.43% | 6.72% | **-0.28** |
| EU | 8.10% | 8.15% | **-0.05** |

Near-perfect alignment for most countries. China gap (+4.78pp) is 301 generation stacking (tracker sums Trump+Biden; ETRs uses flat rate). Canada/Mexico small negatives reflect USMCA share differences. EU near-zero.

### 2026-07-24 (S122 expired; 232 + 301 only)

| Country | Tracker | Tariff-ETRs | Diff (pp) |
|---------|---------|-------------|-----------|
| China | 21.42% | 17.60% | **+3.81** |
| Canada | 2.81% | 4.62% | **-1.82** |
| Mexico | 4.80% | 8.43% | **-3.63** |
| Japan | 3.80% | 8.23% | **-4.42** |
| UK | 0.74% | 3.35% | **-2.61** |
| EU | 2.55% | 4.19% | **-1.64** |

With S122 expired and IEEPA zeroed, only 232 + 301 + MFN remain. Tracker is lower than ETRs for most countries, suggesting ETRs retains some tariff authority the tracker does not apply in this period (possibly residual S122 or different 232/301 scope). China gap (+3.81pp) is 301 stacking.

---

## TPC Product-Level Validation

TPC benchmark data (`data/tpc/tariff_by_flow_day.csv`) provides product-level rates at 5 pre-S122 dates for ~240 countries x ~19,800 products.

### USMCA: TPC Confirms Continuous Product-Level Shares

TPC uses continuous product-level USMCA utilization shares, producing a smooth distribution of rates between 0% and the headline rate.

| Country | TPC Implied | Tracker Census SPI | ETRs GTAP Sectors |
|---------|------------|-------------------|-------------------|
| Canada | **45.5%** | 41.2% | ~85-90% |
| Mexico | **50.7%** | 47.3% | ~75-85% |

**Verdict:** The tracker's Census SPI shares closely match TPC. ETRs GTAP shares are roughly double what TPC uses, confirming ETRs systematically over-exempts CA/MX (proposed change E1).

### Floor Rates: TPC Confirms Floor + Product Exemptions

| Country | 0% (exempt) | ~10% (baseline) | ~15% (floor) | ~25% (reciprocal) |
|---------|------------|-----------------|-------------|-------------------|
| Japan | 22% | 27% | 30% | 9% |
| S. Korea | 20% | 11% | 53% | — |
| EU avg | 23% | — | 25% | — |

TPC exempts ~22% of Japan products (rate=0%) vs tracker's ~1-2%. This product exemption gap — not missing floor logic — is the main Japan/EU discrepancy driver. The T3 fix (expanding IEEPA exempt products to 2,172) partially addresses this.

### Section 301: TPC Confirms Generation Stacking

| TPC Rate | Count | Likely Decomposition |
|----------|-------|---------------------|
| ~35% | 9,290 (64%) | fentanyl(10%) + 301_Trump(25%) |
| ~60% | 3,982 (28%) | 232(25%) + fentanyl(10%) + 301(25%) |
| ~85% | 421 (3%) | fentanyl(10%) + 301_Trump(25%) + 301_Biden(50%) |
| ~95% | 528 (4%) | recip(10%) + fentanyl(10%) + 301_Trump(25%) + 301_Biden(50%) |

The 85%+ rates are only possible with generation stacking. Validates tracker approach (E2 for ETRs).

---

## Remaining Discrepancy Sources

### 1. Floor Country Product Exemptions (largest remaining gap)

~48,000 EU mismatches (~47% of all). For duty-free products, TPC gives a continuous distribution of rates (0-14.9%) rather than the binary 0% or 15% our floor applies. This suggests TPC uses trade-weighted or partial-credit methodology, or has a much larger exempt product list. The T3 fix (expanding IEEPA exempt products to 4,325 HTS10 — including HTS8→HTS10 expansion, Ch98 statutory exemption, and ITA prefix expansion) narrowed this gap but didn't resolve the continuous-rate pattern. Note: ~513 products where TPC shows 0% have no identified legal basis for exemption — likely a TPC analytical choice to exclude duty-free products from floor application.

### 2. 232 + IEEPA Stacking (methodological difference)

~25,800 products across all groups. TPC stacks IEEPA reciprocal on top of 232 (no mutual exclusion). Our approach follows the Tariff-ETRs legal authority structure. **Documented analytical choice, not a bug.** Accounts for ~25% of all mismatches.

### ~~3. 232 Auto/MHD Parts Prefix Matching (T6a/T6b resolved)~~

Both lists verified against live HTSUS US Notes (Chapter 99, 2026_rev_4 PDF). Auto parts (130 codes) match Note 33 subdivision (g) exactly; MHD parts (182 codes) match Note 34 subdivision (i) exactly. Note: '8471' confirmed as official auto parts prefix. The 7 codes removed from auto parts (8708.99.03/.06/.23/.27/.31/.41, 8708.99.4850) correctly appear only in the MHD list.

### 4. Gulf State / Middle East IEEPA Rates (minor)

Several Middle East countries show TPC systematically 2-3pp higher (Oman, Qatar, UAE). Small overall impact (~0.5pp).

### 5. China Non-301 Product Coverage (negligible)

~170 China products where TPC shows ~20% but we show ~10-17%. Likely 10-digit specificity not captured by 8-digit matching.

---

## Gap Attribution Summary

### ETRs 2-21_temp Scenario Structure

| Period | Date | Authorities Active | Notes |
|--------|------|--------------------|-------|
| 1 | 2026-01-01 | IEEPA + fentanyl + 232 + 301 | Pre-S122; all tariffs active |
| 2 | 2026-02-24 | S122 (10%) + 232 + 301 | IEEPA/fentanyl zeroed; S122 replaces IEEPA |
| 3 | 2026-07-24 | 232 + 301 only | S122 expired; no IEEPA |

### 2026-01-01: Tracker +5.61pp vs ETRs

| Issue | Impact on Gap | More Right |
|-------|--------------|------------|
| USMCA granularity | **+9.8pp** (Canada), **+1.6pp** (Mexico) | **Tracker** (product-level SPI; TPC validates) |
| 301 generation stacking | **+5.5pp** (China) | **Tracker** (legally correct sum; TPC validates) |
| IEEPA duty-free treatment | **+3-5pp** (EU/Japan/floor countries) | **Ambiguous** (tracker follows legal text; TPC excludes duty-free) |

### 2026-02-24: Tracker +0.04pp vs ETRs (near-perfect)

S122 timing now aligned (both effective Feb 24). Residual gap is ~0pp overall. China +4.78pp (301 stacking) offset by small negatives elsewhere.

### 2026-07-24: Tracker -1.43pp vs ETRs

| Issue | Impact on Gap | More Right |
|-------|--------------|------------|
| 301 generation stacking | **+3.8pp** (China) | **Tracker** (legally correct sum; TPC validates) |
| Canada | **-1.82pp** | ETRs higher (USMCA share differences at GTAP level) |
| Mexico | **-3.63pp** | ETRs higher (USMCA granularity; E1 pending) |
| Japan/EU/UK | **-2.6 to -4.4pp** | ETRs higher — likely residual IEEPA or broader 232 scope in ETRs |

---

## Resolved Issues Log

| Issue | Resolution | Date |
|-------|-----------|------|
| T1: 232 USMCA binary exemption | Replaced with `rate_232 * (1 - usmca_share)` using Census SPI | 2026-03-09 |
| T2: 232 auto deal rates missing | Fixed ch99 parser + rate extractor + calculator; 12 deal entries | 2026-03-09 |
| T3: IEEPA exempt products incomplete | Three-part fix: (a) ETRs merge 1,087→2,172, (b) HTS8→HTS10 expansion +1,993, (c) Ch98 statutory +101, (d) ITA prefix +59. Total: 4,325 HTS10 | 2026-03-09 |
| T4: Brazil/India EO stacking | Confirmed correct — country_eo + Phase 2 sums properly | 2026-03-09 |
| T6a: 232 auto parts list | Replaced with CBP official source (Note 33(g), 130 codes); verified against live HTSUS | 2026-03-10 |
| T6b: 232 MHD parts list | Verified 182 codes match live HTSUS Note 34 subdivision (i) exactly | 2026-03-10 |
| J2: 232 auto parts product lists | Both auto (130) and MHD (182) verified against live HTSUS US Notes PDF | 2026-03-10 |
| T7: S122 exempt products | Confirmed identical — both repos have 1,656 HTS8 codes | 2026-03-09 |
| IEEPA invalidation in compare_etrs.R | Added calendar-date-based zeroing of IEEPA reciprocal + fentanyl when `d >= ieepa_invalidation_date`; snapshot may predate invalidation | 2026-03-10 |
| S122 timing alignment | Moved S122 effective from Feb 25 → Feb 24, expiry from Jul 25 → Jul 23; moved 2026_rev_4 effective_date to Feb 24. Matches ETRs; 2026-02-24 gap: -5.57pp → +0.04pp | 2026-03-10 |
| Switzerland IEEPA over-application | Fixed via Swiss framework (EO 14346, 15% floor) | 2026-02 |
| CA/MX fentanyl carve-outs | Implemented via `fentanyl_carveout_products.csv` (308 prefixes) | 2026-02 |
| USMCA utilization rates | Census SPI product-level shares; CA 79.4%, MX 83.9% match | 2026-02 |
| 301 product lists + generation stacking | List 4B added; generation-based SUM implemented | 2026-02 |
| China IEEPA reciprocal (34% → 10%) | Post-Geneva suspension detection fixed | 2026-02 |
| Universal IEEPA baseline | ~143 unlisted countries now get 10% default | 2026-02 |
| 232 derivative products | ~130 aluminum articles with BEA metal content scaling | 2026-02 |
