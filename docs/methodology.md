# Tariff Rate Tracker: Methodology Summary

## Overview

The Tariff Rate Tracker constructs statutory U.S. tariff rates at the HTS-10 x country level by parsing Harmonized Tariff Schedule (HTS) JSON archives published by the U.S. International Trade Commission (USITC). It processes all 39 HTS revisions from January 2025 through January 2026 to build a complete time series of tariff rates, then aggregates these into import-weighted effective tariff rates (ETRs) using 2024 Census trade data. Tax Policy Center (TPC) benchmark data is used for validation only — never as a rate input.

The system produces ~4.5 million product-country rate observations per revision snapshot, covering ~19,768 HTS-10 products across 240 countries.

---

## Data Sources

| Source | Description | Coverage |
|--------|-------------|----------|
| **USITC HTS JSON** | Official tariff schedule; base MFN rates, Chapter 99 additional duties, product footnotes, special program codes | 39 revisions (basic through 2026_rev_4), ~35,500 items per revision |
| **USITC Chapter 99 PDF** | US Notes text enumerating product lists for Section 301, floor country exemptions | 767 pages; parsed by `scrape_us_notes.R` |
| **Census 2024 Import Data** | Import values by HTS-10 x country x GTAP sector | ~$2.9 trillion total; used for ETR weighting |
| **Tariff-ETRs USMCA Shares** | GTAP sector-level USMCA utilization fractions for CA/MX | 47 GTAP sectors; used for weighted USMCA exemption |
| **TPC Benchmark** | HTS-10 x country tariff rates at 5 snapshot dates | ~339K rows; validation only |

---

## Rate Calculation Methodology

### Tariff Authorities

The system tracks six distinct tariff authorities that can stack on a single product-country pair:

| Authority | Legal Basis | Scope | Rate Range |
|-----------|------------|-------|------------|
| **Section 232** | Trade Expansion Act | Steel (ch72-73), aluminum (ch76), autos (heading 8703), copper (80 HTS10 codes from US Note 36(b): ch74 + ch8544), aluminum derivatives (~130 products) | 25–50% (steel/aluminum/copper 50% post-June 2025; autos 25%; UK deals 25%) |
| **Section 301** | Trade Act of 1974 | ~11,000 HTS-8 products from China (Lists 1-4B + Biden) | 7.5%-100% by list |
| **IEEPA Reciprocal** | International Emergency Economic Powers Act | All products for ~238 countries (blanket) | 10%-50% (surcharge or 15% floor) |
| **IEEPA Fentanyl** | IEEPA | All products for Canada, Mexico, China/HK | 10%-40% (with product carve-outs) |
| **Section 122** | Trade Act of 1974 | All countries (150-day statutory limit, effective 2026-02-24) | 10–25% |
| **Section 201** | Trade Act of 1974 §201 | Safeguard tariffs (solar panels 9903.45.xx, washing machines 9903.40.xx) | Variable |
| **Other** | Various | Miscellaneous Ch99 entries | Variable |

### Three Mechanisms for Linking Duties to Products

1. **Footnote references** — Product-level footnotes in the HTS JSON reference specific Chapter 99 entries (e.g., "See 9903.88.15"). Used for Section 301 and some fentanyl entries.

2. **Chapter/heading blanket coverage** — Entire HTS chapters or headings are covered regardless of footnotes. Used for Section 232 (steel ch72-73, aluminum ch76, autos heading 8703). Copper uses a specific product list from US Note 36(b) (80 HTS10 codes).

3. **Universal country-level application** — Blanket tariffs applied to all products for listed countries. Used for IEEPA reciprocal (Phase 1 and Phase 2) and IEEPA fentanyl. Country-specific rates parsed from Chapter 99 entry descriptions.

### Product-Level Exemptions (from External Resource Files)

Several categories of products are exempt from otherwise-blanket tariffs. These exemptions are defined in US Notes to Chapter 99 and cannot be extracted from the HTS JSON API, so they are maintained as resource files:

| Exemption | File | Count | Effect |
|-----------|------|-------|--------|
| General IEEPA exempt (Annex A + carve-outs + Ch98 + ITA prefixes) | `ieepa_exempt_products.csv` | ~4,325 HTS-10 | Zero IEEPA reciprocal for all countries |
| Floor country product exemptions | `floor_exempt_products.csv` | ~1,697 HTS-8 across 4 country groups | Zero IEEPA reciprocal for EU/Japan/Korea/Swiss |
| Section 301 product lists | `s301_product_lists.csv` | ~12,200 entries (~11,000 HTS-8) | Defines which products receive 301 duty; generation-based stacking |
| Section 232 derivatives | `s232_derivative_products.csv` | ~130 HTS prefixes | Defines aluminum articles outside ch76 |
| Fentanyl carve-outs | `fentanyl_carveout_products.csv` | 308 HTS-8 | Lower fentanyl rate (10% vs 25-35%) |

### IEEPA Rate Types

Countries subject to IEEPA reciprocal fall into three rate types:

- **Surcharge**: A flat additional duty (e.g., India +50%, Bangladesh +20%). Applied directly.
- **Floor**: A minimum total tariff rate (e.g., EU/Japan/S. Korea/Switzerland at 15%). The additional duty is `max(0, floor_rate - base_rate)`, so products already above the floor receive no additional duty.
- **Passthrough**: No additional duty (e.g., countries at the 10% universal baseline after the Geneva Agreement pause).

### Stacking Rules

Tariff authorities stack according to mutual exclusion rules aligned with the Tariff-ETRs methodology:

```
Section 232 takes precedence over IEEPA reciprocal.

China with 232:     232 + recip*nonmetal + fentanyl + 301 + s122*nonmetal + section_201 + other
China without 232:  reciprocal + fentanyl + 301 + s122 + section_201 + other
Others with 232:    232 + (recip + fentanyl + s122)*nonmetal + 301 + section_201 + other
Others without 232: reciprocal + fentanyl + s122 + 301 + section_201 + other

Total rate = base_rate + total_additional
```

For base Section 232 products (steel, aluminum, autos, copper), `metal_share = 1.0` and `nonmetal_share = 0`, so IEEPA is fully excluded. For derivative 232 products (aluminum-containing articles outside ch76), `metal_share = 0.50` (default), so IEEPA applies to the remaining 50%.

Note: `rate_301` uses generation-based stacking — MAX within each generation (original Trump 9903.88.xx / Biden 9903.91-92.xx), SUM across generations. Products on both Trump and Biden lists receive both duties (e.g., 25% + 25% = 50%).

USMCA exemption: For Canadian and Mexican products, tariff rates are multiplied by `(1 - usmca_share)`, where `usmca_share` is the fraction of 2024 import value that entered under USMCA preference (Census RATE_PROV = 18). Shares are computed per-HTS10 x country from Census IMP_DETL.TXT fixed-width files by `src/compute_usmca_shares.R` and stored in `resources/usmca_product_shares.csv` (22,449 product-country pairs). Products not imported from CA/MX in 2024 retain full tariff (share = 0). Falls back to binary eligibility (S/S+ in HTS `special` field → zero rate) if Census SPI shares are unavailable. Applied to IEEPA reciprocal, IEEPA fentanyl, Section 122, and Section 232 auto/MHD programs.

### Calculation Pipeline

For each of the 39 HTS revisions:

1. Parse Chapter 99 entries (rates, authority classification, country scope)
2. Parse product lines (base MFN rates, Chapter 99 footnote references)
3. Extract policy parameters (IEEPA country rates, fentanyl rates, 232 rates, USMCA eligibility)
4. Calculate rates:
   - a. Footnote-based rates (vectorized join of products x Ch99 entries x countries)
   - b. IEEPA reciprocal (blanket for ~238 countries, minus exempt products and floor country exemptions)
   - c. IEEPA fentanyl (blanket for CA/MX/CN with product carve-outs)
   - d. Section 232 base (chapter/heading blanket)
   - e. Section 232 derivatives (product list + metal content scaling)
   - f. Section 301 (blanket for China from product list)
   - g. USMCA exemptions
5. Apply stacking rules (mutual exclusion, nonmetal share scaling)
6. Enforce rate schema and save snapshot

---

## Effective Tariff Rate (ETR) Methodology

Import-weighted ETRs are computed as:

```
ETR = sum(rate_i * imports_i) / sum(imports_i)
```

where `rate_i` is the total statutory tariff rate for product-country pair `i` and `imports_i` is the 2024 Census import value. ETRs are computed at five dimensions:

- **Overall**: Single weighted average across all products and countries
- **By partner**: Weighted ETR per trading partner (China, Canada, Mexico, EU, Japan, UK, FTA partners, Rest of World)
- **By authority**: Decomposed weighted contribution of each tariff authority (232, 301, IEEPA, fentanyl)
- **By GTAP sector**: Weighted ETR using HTS-10 to GTAP sector crosswalk

Point-in-time rate queries use interval encoding: each rate observation has `valid_from` and `valid_until` dates, and `get_rates_at_date(ts, date)` filters to the active revision for any calendar date.

---

## Validation Against TPC

Rates are compared at the HTS-10 x country level against TPC benchmark data at 5 snapshot dates corresponding to major policy events:

| Revision | Policy Event | TPC Date | Within 2pp | Tracker ETR | TPC ETR | Diff (pp) |
|----------|-------------|----------|------------|-------------|---------|-----------|
| rev_6 | 232 Autos | 2025-03-17 | 82.3% | 10.42% | 7.99% | +2.44 |
| rev_10 | Liberation Day | 2025-04-17 | 93.1% | 15.20% | 23.48% | -8.28 |
| rev_17 | 232 Increase | 2025-07-17 | 90.6% | 16.43% | 15.35% | +1.08 |
| rev_18 | Phase 2 | 2025-10-17 | 79.9% | 16.19% | 18.20% | -2.01 |
| rev_32 | Floor Countries | 2025-11-17 | 84.9% | 15.93% | 16.14% | -0.21 |

The within-2pp match rate improved significantly after the March 2026 base rate inheritance fix (+9.3pp at rev_18, +11.1pp at rev_32). The rev_10 ETR outlier (-8.28pp) reflects the April 9 reciprocal suspension period. The tracker is within ~1pp of TPC at the latest two dates.

---

## Known Gaps and Limitations

### ~~1. USMCA Utilization Rate~~ (Resolved — Census SPI data)

**Impact**: CA 79.4% exact match (was 44.3%), MX 83.9% (was 44.5%)

Resolved by extracting per-product USMCA utilization shares from Census Bureau IMP_DETL.TXT RATE_PROV field (code 18 = USMCA preferential entry). For each HTS10 x country, `usmca_share = sum(value where RATE_PROV=18) / sum(total value)`. Applied to all CA/MX products as `rate * (1 - usmca_share)`. The Census data provides true product-level variation (CA median 0%, mean 41%; MX median 43%, mean 47%) rather than sector averages. Earlier attempts using Tariff-ETRs sector-level shares failed because sector averages don't capture within-sector bimodal distribution.

### 2. Floor Country Residual — Continuous Rates (EU/Japan/Korea/Swiss, ~2,700 products)

**Impact**: Germany 46.8% exact match (up from 41.5% after floor exemption fix)

For products where we apply the full 15% floor, TPC assigns rates spanning 1-14% — a continuous distribution suggesting TPC uses trade-weighted or product-level methodology beyond a simple floor formula. This contributes ~3-4pp of average excess for floor countries. The recently implemented floor country product exemptions (PTAAP, civil aircraft, pharma) addressed ~1,600 previously misclassified products per EU country, but this continuous-rate pattern remains.

### 3. Floor Country Residual — 232 Interaction (~1,200 EU products)

**Impact**: EU 232 products at 3.2% exact match with -12pp mean diff

EU products subject to Section 232 have poor TPC match rates, suggesting EU-specific 232 exemption or exclusion patterns not captured in our methodology. Separate from the floor rate issue.

### 4. China+232 Reciprocal Stacking (~920 products, ~25pp gap)

**Impact**: China metal chapters (72-76) at 1.2% exact match, -24pp mean diff

TPC stacks IEEPA reciprocal on top of Section 232 for China products (e.g., 232(25%) + recip(25%) + fent(10%) + 301(25%) = 85%). Our model applies mutual exclusion per Tariff-ETRs methodology: Section 232 takes precedence over IEEPA reciprocal for base 232 products (`nonmetal_share = 0`), so reciprocal contributes 0pp. This is a fundamental methodological difference — our approach follows the legal authority structure, TPC sums all authorities unconditionally. Confirmed via statistical analysis: adding 25pp reciprocal to our China+232 rates produces near-zero residual vs TPC.

### 5. China IEEPA Reciprocal Rate

**Impact**: China 72.4% exact match at rev_32

The statutory IEEPA reciprocal rate for China is 34% (from 9903.01.63). TPC shows ~25%, likely reflecting the May 2025 US-China bilateral agreement. Our system correctly tracks the suspension marker in the HTS JSON; the remaining discrepancy reflects timing differences in how the bilateral agreement is encoded.

### 6. Pre-Phase 2 Revision Mismatch (rev_6)

**Impact**: 47.3% exact match

The March 2025 TPC snapshot predates IEEPA reciprocal tariffs (Liberation Day was April 2, 2025). The lower match rate reflects different baseline assumptions and limited product overlap at that date.

---

## Figure: Average ETR by Day (2025)

The daily weighted ETR time series can be plotted with TPC benchmark points overlaid using the following R code:

```r
library(tidyverse)

# Load daily series and TPC comparison data
daily <- read_csv('output/daily/daily_overall.csv')
tpc_etr <- read_csv('output/etr/etr_overall.csv')

# Filter to 2025 only
daily_2025 <- daily %>%
  filter(date >= '2025-01-01', date <= '2025-12-31')

tpc_points <- tpc_etr %>%
  transmute(date = as.Date(date), etr_tpc = etr_tpc * 100)

# Plot
ggplot() +
  geom_line(
    data = daily_2025,
    aes(x = as.Date(date), y = weighted_etr * 100),
    color = '#2c5f8a', linewidth = 1
  ) +
  geom_point(
    data = tpc_points,
    aes(x = date, y = etr_tpc),
    color = '#d63333', size = 3, shape = 16
  ) +
  scale_x_date(date_breaks = '1 month', date_labels = '%b') +
  scale_y_continuous(limits = c(0, NA), labels = function(x) paste0(x, '%')) +
  labs(
    title = 'Average Effective Tariff Rate (2025)',
    subtitle = 'Daily weighted ETR (line) with TPC benchmark points (dots)',
    x = NULL,
    y = 'Import-Weighted ETR',
    caption = 'Source: Yale Budget Lab Tariff Rate Tracker (HTS-derived); TPC for validation'
  ) +
  theme_minimal(base_size = 12) +
  theme(
    plot.title = element_text(face = 'bold'),
    panel.grid.minor = element_blank()
  )

ggsave('output/etr/etr_daily_2025.png', width = 10, height = 6, dpi = 150)
```

This produces a line chart of the daily import-weighted ETR through 2025, showing the step-function jumps at each policy change (fentanyl tariffs in January, Liberation Day in April, 232 increase in July, Phase 2 in August, floor country frameworks in November), with TPC's five benchmark estimates plotted as red dots for comparison.
