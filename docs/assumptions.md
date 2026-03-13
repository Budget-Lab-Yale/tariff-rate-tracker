# Non-Official Assumptions

This document is an appendix to [methodology.md](methodology.md). It catalogs methodological assumptions derived from non-official sources — i.e., choices and data inputs that are **not** directly from HTS JSON, Federal Register text, or statutory language. Each entry notes the assumption, its source, and where it is implemented.

---

## 1. Tariff Stacking: Mutual Exclusion vs. Additive

**Assumption:** Section 232 and IEEPA reciprocal tariffs are mutually exclusive — 232 takes precedence, and IEEPA reciprocal applies only to the non-metal portion of derivative 232 products. TPC instead stacks all authorities additively (no mutual exclusion), which accounts for a ~25pp gap on ~25,800 products.

**Source:** Tariff-ETRs legal interpretation. Confirmed by reverse-engineering TPC methodology through rate comparison.

**Evidence:** Running `tests/test_tpc_comparison.R --tpc-stacking` (additive mode) isolates data discrepancies from this methodological difference.

**Implementation:** `src/helpers.R:apply_stacking_rules()`, `stacking_method` parameter (default `'mutual_exclusion'`).

---

## 2. Metal Content Shares for 232 Derivatives

**Assumption:** The tariff on derivative 232 products (aluminum-containing articles outside ch76) applies only to the metal content portion of customs value. Three methods are available:

| Method | Share | Source |
|--------|-------|--------|
| Flat | 50% for all derivatives | Matches TPC methodology |
| CBO | 75% (high aluminum), 25% (low aluminum), 90% (copper) | CBO budget analysis files |
| BEA (default) | HS10-level shares from BEA Detail I-O table | `resources/metal_content_shares_bea_hs10.csv` |

**Source:** Flat 50% reverse-engineered from TPC. CBO buckets from Congressional Budget Office tariff analysis (`resources/cbo/`). BEA shares computed from BEA Detail I-O table, matching Tariff-ETRs `bea_granularity: 'detail'`. No official HTS or Federal Register guidance specifies metal content calculation methodology.

**Implementation:** `config/policy_params.yaml` (`metal_content` block, `method: 'bea'`), `resources/metal_content_shares_bea_hs10.csv`, `src/helpers.R:load_metal_content()`.

---

## 3. USMCA Utilization Shares

**Assumption:** USMCA preference utilization is measured at the product-country level using USITC DataWeb Special Program Indicator (SPI) codes "S" and "S+". Year-specific shares are available for 2024 and 2025; default is 2025, configurable via `usmca_shares.year` in `policy_params.yaml`. Tariff rates are scaled by `(1 - usmca_share)` for Canadian and Mexican products. Applied to IEEPA reciprocal, IEEPA fentanyl, Section 122, and Section 232 auto/MHD programs.

For Section 232 auto/MHD products, the USMCA share is further scaled by `us_auto_content_share` (0.40) to reflect that USMCA-eligible vehicles contain ~60% non-originating content under rules of origin. This means only 40% of a qualifying vehicle's value receives the USMCA exemption from 232 tariffs. This scaling matches Tariff-ETRs methodology and applies only to the 232 USMCA exemption — IEEPA/fentanyl/S122 exemptions use the full product-level USMCA share.

**Source:** USITC DataWeb API (`datawebws.usitc.gov`), querying imports for consumption by HTS10 × country with SPI program filter (S/S+). DataWeb captures ALL USMCA-claimed trade regardless of duty treatment, unlike Census API's RP=18 field which misses USMCA claims on already-duty-free products (~50% undercount). Validated against Brookings/USITC aggregate shares (CA: 38.4% vs 35.5%, MX: 49.9% vs 49.5%). The `us_auto_content_share` parameter matches Tariff-ETRs' `us_auto_content_share` in `other_params.yaml`.

**Year selection:** Two years are available. 2024 (CA: 38%, MX: 50%) represents pre-tariff steady-state utilization. 2025 (CA: 67%, MX: 68%) reflects tariff-induced behavioral changes — firms rushed to claim USMCA preferences to avoid new tariffs, nearly doubling utilization rates. Default is 2025.

**Why non-official:** SPI coding is administrative, not statutory. Product-level utilization is an empirical estimate, not a legal determination. The auto content share (0.40) is an economic estimate of US/USMCA-origin content in qualifying vehicles, not a statutory rate. Falls back to binary HTS `special` field eligibility (S/S+) when shares are unavailable.

**Implementation:** `src/download_usmca_dataweb.R` (optional, requires USITC DataWeb account and API token in `.env`). Year-specific files: `resources/usmca_product_shares_2024.csv` (40,088 pairs) and `resources/usmca_product_shares_2025.csv` (40,258 pairs). Year selected via `usmca_shares.year` in `config/policy_params.yaml` (default: 2025). Applied in `src/06_calculate_rates.R` steps 2 (fentanyl), 4 (232 auto/MHD), and 7 (IEEPA/S122). Auto content share configured in `config/policy_params.yaml` under `auto_rebate.us_auto_content_share`.

---

## 4. Section 232 Derivative Product List

**Assumption:** ~130 aluminum-containing articles outside Chapter 76 are covered by 9903.85.04/.07/.08 (232 derivatives). The product list is maintained externally because HTS JSON does not provide US Note 19 subdivision text.

**Source:** Tariff-ETRs project, reverse-engineered from US Note 19 to Chapter 99 PDF. Should be re-derived directly when USITC API provides US Notes data.

**Implementation:** `resources/s232_derivative_products.csv`, loaded by `src/helpers.R:load_232_derivative_products()`.

---

## 4a. Section 232 Auto Parts Product List *(now official)*

**Assumption:** 130 HTS codes define automobile parts subject to Section 232 tariffs under headings 9903.94.05 (dutiable) and 9903.94.06 (USMCA-content exempt).

**Source:** CBP "Automobile Parts HTS List" (Attachment 2), published May 1, 2025 via GovDelivery. References U.S. Note 33 to subchapter III of Chapter 99, subdivisions (g) and (h). PDF: `data/cbp/Attachment 2_Auto Parts HTS List.pdf`.

**Why this section remains:** While both product lists are now verified against official sources, the files are still maintained externally because the HTS JSON API does not provide US Notes text (zero product-level footnotes reference 9903.94.05). The MHD parts list (`s232_mhd_parts.txt`, 182 codes) was verified against live HTSUS US Note 34, subdivision (i), heading 9903.74.08 — exact match confirmed.

**Implementation:** `resources/s232_auto_parts.txt`, loaded via `prefixes_file` in `config/policy_params.yaml` (`section_232_headings.auto_parts`).

---

## 5. Fentanyl Carve-Out Product Lists

**Assumption:** 308 HTS8 products receive lower fentanyl tariff rates under three carve-out categories:

- MX potash (9903.01.05): +10% vs +25% general
- CA potash (9903.01.15): +10% vs +35% general
- CA energy/minerals (9903.01.13): +10% vs +35% general

**Source:** Tariff-ETRs project, reverse-engineered from US Note 2 subdivisions in Chapter 99 PDF. Not parseable from HTS JSON.

**Implementation:** `resources/fentanyl_carveout_products.csv`, loaded by `src/helpers.R:load_fentanyl_carveouts()`.

---

## 6. IEEPA Product Exemptions (Annex A)

**Assumption:** ~4,325 HTS10 products are exempt from IEEPA reciprocal tariffs. Three sources:

1. **Annex A / US Note 2 subdivision (v)(iii)**: ~2,172 HTS8 codes expanded to ~4,106 HTS10 (including ITA prefix entries for headings 8471, 8473.30, 8486, 8523, 8524, 8541, 8542)
2. **Chapter 98 statutory exemption**: US Note 2 subdivision (v)(i) explicitly exempts Chapter 98 articles from IEEPA reciprocal, except 9802.00.40/.50/.60/.80. Adds ~101 HTS10 codes.
3. **Country-specific carve-outs**: Merged from Tariff-ETRs `ieepa_reciprocal.yaml` product_rates (rate=0).

**Source:** Executive orders (official policy), but the product list is maintained as an external resource file because the HTS JSON API does not provide US Notes text. List history: initial 1,087 codes → +1,085 from ETRs merge (March 2026) → +1,993 from HTS8→HTS10 expansion + 101 Ch98 + 59 ITA prefix expansion (March 9, 2026).

**Why non-official:** While the exemptions themselves are statutory (defined in US Notes), the compiled product list requires manual extraction from Chapter 99 PDF text since the HTS JSON API does not provide US Notes subdivisions. The HTS8→HTS10 expansion uses the HTS JSON product hierarchy to enumerate all statistical suffixes.

**Implementation:** `resources/ieepa_exempt_products.csv`, applied in `src/06_calculate_rates.R`. Expansion script: `src/expand_ieepa_exempt.R`.

---

## 7. Floor Country Product Exemptions

**Assumption:** ~1,697 products are exempt from the 15% tariff floor for EU, Japan, South Korea, and Switzerland/Liechtenstein. Categories: PTAAP, civil aircraft, non-patented pharmaceuticals, particular articles.

**Source:** Scraped from Chapter 99 PDF via `src/scrape_us_notes.R --floor-exemptions`. Defined in US Note 2 subdivisions (v)(xx)-(xxiv) and Note 3, which are not machine-readable via HTS API.

**Implementation:** `resources/floor_exempt_products.csv`, loaded by `src/helpers.R:load_floor_exempt_products()`.

---

## 8. Section 301 Product Lists and Rate Aggregation

**Assumption:** ~12,200 product entries (covering ~11,000 unique HTS8 codes) are subject to Section 301 tariffs on China. Rate aggregation takes MAX across all active Ch99 entries per HTS-8 code. For the 8 products that appear on both Trump-era and Biden-era lists, Biden rates are always ≥ the corresponding Trump rate, so MAX achieves the correct supersession. This matches Tariff-ETRs, which partitions products into exclusive rate buckets (one rate per HS-10 × country).

**Source:** Two non-HTS-JSON sources:
1. USITC "China Tariffs" reference document (~10,400 codes)
2. Chapter 99 PDF US Notes 20/31, scraped via `src/scrape_us_notes.R`

**Scope note:** `9903.89.xx` is not used in the China Section 301 blanket-product logic. Those provisions belong to the separate large civil aircraft dispute with the EU/UK and are assumed suspended from 2021 onward for the current series horizon. If the repo is extended backward to cover the live aircraft-dispute period, those lines should be modeled as a separate Section 301 branch rather than as China-list exclusions.

**Implementation:** `resources/s301_product_lists.csv`, `config/policy_params.yaml` (SECTION_301_RATES), `src/06_calculate_rates.R`.

---

## 9. IEEPA Rate Type Classification

**Assumption:** IEEPA Ch99 entries are classified into three rate types by parsing the HTS `general` field text:

| Type | Pattern | Example |
|------|---------|---------|
| Surcharge | "+X%" or "plus X%" | "The duty ... + 25%" |
| Floor | "X%" (no "+") | "25%" (replaces base rate) |
| Passthrough | "The duty provided..." or "Free" | No additional tariff |

Within a phase, priority is floor > surcharge > highest rate. Across phases (Phase 2 + country_eo), rates sum.

**Source:** Reverse-engineered from HTS JSON text conventions. Rate type distinctions and priority rules are not official HTS terminology — they are implementation choices for handling different Ch99 encoding patterns.

**Implementation:** `src/05_parse_policy_params.R:extract_ieepa_rates()`.

---

## 10. IEEPA Phase Classification

**Assumption:** Ch99 code ranges map to policy phases:

| Range | Phase | Policy Event |
|-------|-------|-------------|
| 9903.01.25 | Universal baseline | 10% for all non-exempt countries |
| 9903.01.43-75 | Phase 1 (Liberation Day) | Apr 9, 2025 |
| 9903.01.76-89 | Country-specific EOs | Stack with Phase 2 |
| 9903.02.02-91 | Phase 2 (Swiss framework) | Aug 7, 2025 |

Phase classification determines stacking behavior — country_eo rates stack additively with Phase 2 (e.g., Brazil +40% country_eo + 10% Phase 2 = 50%).

**Source:** Reverse-engineered from Ch99 code ranges and Federal Register executive order numbering. Range boundaries (especially the .91 extension for Swiss framework) are implementation assumptions.

**Implementation:** `src/05_parse_policy_params.R`, `config/policy_params.yaml` (authority ranges).

---

## 11. Swiss/Liechtenstein Framework Override

**Assumption:** The Swiss framework (EO 14346) converts surcharge rates to floor rates for Switzerland and Liechtenstein. The override is date-bounded: effective Nov 14, 2025, expiring March 31, 2026 unless `finalized: true` is set.

**Source:** Federal Register (90 FR 59281) and Executive Order 14346. The conditional expiry logic and finalization flag are implementation assumptions for handling a potentially lapsing agreement — not encoded in HTS JSON.

**Implementation:** `config/policy_params.yaml` (`swiss_framework` block), `src/06_calculate_rates.R`.

---

## 12. IEEPA Duty-Free Product Treatment

**Assumption:** TPC does not apply IEEPA reciprocal tariffs to products with 0% MFN base rate. Our default (`'all'`) applies IEEPA to all products regardless of MFN rate, which is the legally strict interpretation (EO text does not carve out duty-free products). Setting `ieepa_duty_free_treatment: 'nonzero_base_only'` matches TPC methodology.

**Impact:** ~26K product-country pairs at rev_32 (14,930 in floor countries + 11,288 in non-floor). Top affected chapters: 61-62 (apparel, ~7K), 84-85 (ITA machinery/electronics, ~1.7K), 98 (special provisions, ~3.5K), 97 (artworks), 29-30 (pharma), 49 (printed matter). Toggling to `'nonzero_base_only'` improves TPC match rate by ~8.5pp (65.9% → ~74.4% at rev_32).

**Source:** Reverse-engineered from TPC validation data. The executive order text applies reciprocal tariffs to "articles imported into the United States" with no explicit carve-out for duty-free products, supporting the `'all'` interpretation. However, TPC's exclusion of duty-free products is a reasonable economic interpretation since the tariff base is zero.

**Implementation:** `config/policy_params.yaml` (`ieepa_duty_free_treatment`), applied in `src/06_calculate_rates.R` step 2 (existing products and new IEEPA-only pair expansion).
