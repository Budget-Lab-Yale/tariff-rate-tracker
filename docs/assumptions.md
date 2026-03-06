# Non-Official Assumptions

This document catalogs methodological assumptions derived from non-official sources — i.e., choices and data inputs that are **not** directly from HTS JSON, Federal Register text, or statutory language. Each entry notes the assumption, its source, and where it is implemented.

---

## 1. Tariff Stacking: Mutual Exclusion vs. Additive

**Assumption:** Section 232 and IEEPA reciprocal tariffs are mutually exclusive — 232 takes precedence, and IEEPA reciprocal applies only to the non-metal portion of derivative 232 products. TPC instead stacks all authorities additively (no mutual exclusion), which accounts for a ~25pp gap on ~25,800 products.

**Source:** Tariff-ETRs legal interpretation. Confirmed by reverse-engineering TPC methodology through rate comparison.

**Evidence:** Running `test_tpc_comparison.R --tpc-stacking` (additive mode) isolates data discrepancies from this methodological difference.

**Implementation:** `src/helpers.R:apply_stacking_rules()`, `stacking_method` parameter (default `'mutual_exclusion'`).

---

## 2. Metal Content Shares for 232 Derivatives

**Assumption:** The tariff on derivative 232 products (aluminum-containing articles outside ch76) applies only to the metal content portion of customs value. Three methods are available:

| Method | Share | Source |
|--------|-------|--------|
| Flat (default) | 50% for all derivatives | Matches TPC methodology |
| CBO | 75% (high aluminum), 25% (low aluminum), 90% (copper) | CBO budget analysis files |
| BEA | Product-level (future) | Not yet implemented |

**Source:** Flat 50% reverse-engineered from TPC. CBO buckets from Congressional Budget Office tariff analysis (`resources/cbo/`). No official HTS or Federal Register guidance specifies metal content calculation methodology.

**Implementation:** `config/policy_params.yaml` (`metal_content` block), `src/helpers.R:load_metal_content()`.

---

## 3. USMCA Utilization Shares

**Assumption:** USMCA preference utilization is measured at the product-country level using Census Bureau RATE_PROV field code 18, computed from calendar year 2024 monthly import data. Tariff rates are scaled by `(1 - usmca_share)` for Canadian and Mexican products.

**Source:** Census Bureau Import Detail (IMP_DETL.TXT) files. Methodology replicates TPC's approach ("multiplied by the complement of the USMCA share for each product").

**Why non-official:** Census RATE_PROV coding is administrative, not statutory. Product-level utilization is an empirical estimate, not a legal determination. Falls back to binary HTS `special` field eligibility (S/S+) when shares are unavailable.

**Implementation:** `src/compute_usmca_shares.R`, `resources/usmca_product_shares.csv`, applied in `src/06_calculate_rates.R`.

---

## 4. Section 232 Derivative Product List

**Assumption:** ~130 aluminum-containing articles outside Chapter 76 are covered by 9903.85.04/.07/.08 (232 derivatives). The product list is maintained externally because HTS JSON does not provide US Note 19 subdivision text.

**Source:** Tariff-ETRs project, reverse-engineered from US Note 19 to Chapter 99 PDF. Should be re-derived directly when USITC API provides US Notes data.

**Implementation:** `resources/s232_derivative_products.csv`, loaded by `src/helpers.R:load_232_derivative_products()`.

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

**Assumption:** ~1,087 HTS10 products are exempt from IEEPA reciprocal tariffs, as defined by executive order Annex A / US Note 2 subdivision (v)(iii).

**Source:** Executive orders (official policy), but the product list is maintained as an external resource file because the HTS JSON API does not provide US Notes text.

**Implementation:** `resources/ieepa_exempt_products.csv`, applied in `src/06_calculate_rates.R`.

---

## 7. Floor Country Product Exemptions

**Assumption:** ~1,697 products are exempt from the 15% tariff floor for EU, Japan, South Korea, and Switzerland/Liechtenstein. Categories: PTAAP, civil aircraft, non-patented pharmaceuticals, particular articles.

**Source:** Scraped from Chapter 99 PDF via `src/scrape_us_notes.R --floor-exemptions`. Defined in US Note 2 subdivisions (v)(xx)-(xxiv) and Note 3, which are not machine-readable via HTS API.

**Implementation:** `resources/floor_exempt_products.csv`, loaded by `src/helpers.R:load_floor_exempt_products()`.

---

## 8. Section 301 Product Lists and Generation-Based Stacking

**Assumption:** ~12,200 product entries (covering ~11,000 unique HTS8 codes) are subject to Section 301 tariffs on China. Rate aggregation uses generation-based stacking: MAX within a generation (Trump 9903.88.xx / Biden 9903.91-92.xx), SUM across generations. Products on both Trump List 3 (25%) and Biden (25%) get 50% total.

**Source:** Two non-HTS-JSON sources:
1. USITC "China Tariffs" reference document (~10,400 codes)
2. Chapter 99 PDF US Notes 20/31, scraped via `src/scrape_us_notes.R`

Generation-based stacking logic comes from Tariff-ETRs methodology, not explicit Federal Register language.

**Known gap:** 9903.89.xx US Note exclusions not captured (excluded products may incorrectly receive 301 rate).

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

## 12. TPC Additive Stacking Methodology

**Assumption:** TPC stacks IEEPA reciprocal tariffs on top of Section 232 tariffs with no mutual exclusion. This was confirmed by comparing our mutual-exclusion rates against TPC data — the ~25pp systematic gap on 232 products matches the magnitude of the IEEPA reciprocal rate, and disappears when running in `tpc_additive` mode.

**Source:** Reverse-engineered from TPC validation data (`data/tpc/tariff_by_flow_day.csv`). TPC does not publish their stacking methodology. This assumption was confirmed empirically: switching to additive stacking eliminated the systematic 232-product discrepancy.

**Implementation:** `stacking_method = 'tpc_additive'` parameter in `src/helpers.R:apply_stacking_rules()`, toggled via `--tpc-stacking` CLI flag.

---

## 13. IEEPA Duty-Free Product Treatment

**Assumption:** TPC does not apply IEEPA reciprocal tariffs to products with 0% MFN base rate. Our default (`'all'`) applies IEEPA to all products regardless of MFN rate, which is the legally strict interpretation (EO text does not carve out duty-free products). Setting `ieepa_duty_free_treatment: 'nonzero_base_only'` matches TPC methodology.

**Impact:** ~26K product-country pairs at rev_32 (14,930 in floor countries + 11,288 in non-floor). Top affected chapters: 61-62 (apparel, ~7K), 84-85 (ITA machinery/electronics, ~1.7K), 98 (special provisions, ~3.5K), 97 (artworks), 29-30 (pharma), 49 (printed matter). Toggling to `'nonzero_base_only'` improves TPC match rate by ~8.5pp (65.9% → ~74.4% at rev_32).

**Source:** Reverse-engineered from TPC validation data. The executive order text applies reciprocal tariffs to "articles imported into the United States" with no explicit carve-out for duty-free products, supporting the `'all'` interpretation. However, TPC's exclusion of duty-free products is a reasonable economic interpretation since the tariff base is zero.

**Implementation:** `config/policy_params.yaml` (`ieepa_duty_free_treatment`), applied in `src/06_calculate_rates.R` step 2 (existing products and new IEEPA-only pair expansion).
