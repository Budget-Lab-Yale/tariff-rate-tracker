# Non-Official Assumptions

This document is an appendix to [methodology.md](methodology.md). It catalogs methodological assumptions derived from non-official sources — i.e., choices and data inputs that are **not** directly from HTS JSON, Federal Register text, or statutory language. Each entry notes the assumption, its source, and where it is implemented.

---

## 1. Tariff Stacking: Mutual Exclusion vs. Additive

**Assumption:** Section 232 and IEEPA reciprocal tariffs are mutually exclusive — 232 takes precedence, and IEEPA reciprocal applies only to the non-metal portion of derivative 232 products. The non-metal share is now computed per metal type rather than from the aggregate `metal_share`: steel chapters (72/73) use `1 - steel_share`, aluminum chapters (76) and derivatives use `1 - aluminum_share`, and copper headings use `1 - copper_share`. This matches Tariff-ETRs' per-type scaling.

**TPC feedback (March 2026):** TPC confirmed they largely agree with mutual exclusion between 232 and IEEPA. Two exceptions: (1) copper products can stack 232 + CA/MX IEEPA (fentanyl), and (2) 232 derivatives face IEEPA on the non-metal portion (which our methodology already handles). The previously attributed ~25pp gap on ~25,800 products needs re-investigation — it may be driven by duty-free treatment differences or other factors rather than a fundamental stacking disagreement.

**Source:** Tariff-ETRs legal interpretation, confirmed by TPC correspondence. The `tpc_additive` stacking mode is retained for sensitivity analysis.

**Evidence:** Running `tests/test_tpc_comparison.R --tpc-stacking` (additive mode) is a sensitivity analysis toggle, not a TPC-matching switch. Enhanced 232 sub-category diagnostics in `src/diagnostics.R` decompose the gap by product type (pure metal, copper, derivative, auto, other).

**Post-annex update (April 2026):** The annex restructuring proclamation applies Section 232 to the full customs value of all annex-classified products, eliminating the metal-content-based mutual exclusion for derivatives. For post-annex revisions (effective >= 2026-04-06), `nonmetal_share` is forced to 0 for all products with a populated `s232_annex`, meaning IEEPA/S122/fentanyl contribute zero on 232 products. Pre-annex stacking behavior is unchanged. This aligns with SGEPT's approach (dropping content shares to 100% at the transition) and is supported by the AFS Law analysis of the proclamation text.

**Implementation:** `src/helpers.R:apply_stacking_rules()`, `stacking_method` parameter (default `'mutual_exclusion'`). Post-annex override keyed on `s232_annex` column presence.

---

## 2. Metal Content Shares for 232 Derivatives

**Assumption:** For pre-annex revisions (before 2026-04-06), the tariff on derivative 232 products applies only to the metal content portion of customs value. For post-annex revisions, the proclamation applies 232 to full customs value and metal content shares are no longer used for rate scaling or stacking (see Assumption 1 post-annex update). The metal content configuration remains relevant for pre-annex revisions and for the Annex IV de minimis weight threshold. Three methods are available:

| Method | Share | Source |
|--------|-------|--------|
| Flat | 50% for all derivatives | Matches TPC methodology |
| CBO | 75% (high aluminum), 25% (low aluminum), 90% (copper) | CBO budget analysis files |
| BEA (default) | HS10-level per-type shares from BEA Detail I-O table | `resources/metal_content_shares_bea_hs10.csv` |

The BEA method returns per-type columns (`steel_share`, `aluminum_share`, `copper_share`, `other_metal_share`) in addition to the aggregate `metal_share`. Derivative 232 rates are scaled by `aluminum_share` specifically — the derivative tariff applies only to the aluminum content, not steel or copper fractions that may be present. Stacking uses the same per-type share to compute `nonmetal_share` (see Assumption 1). The flat and CBO methods do not have per-type breakdowns; they omit per-type columns entirely, causing `apply_stacking_rules()` to use the aggregate `metal_share` fallback path for nonmetal computation.

Products in primary chapters (72, 73, 76) are forced to `metal_share = 1.0` regardless of derivative flag, since the blanket 232 rate applies to the full customs value of base metal products. Products that overlap between heading programs (e.g., auto parts that are also aluminum derivatives) use the heading rate at full product value and have their `metal_share` reset to 1.0 to prevent IEEPA from filling a phantom non-metal portion.

**Source:** Flat 50% reverse-engineered from TPC. CBO buckets from Congressional Budget Office tariff analysis (`resources/cbo/`). BEA shares computed from BEA Detail I-O table, matching Tariff-ETRs `bea_granularity: 'detail'`. No official HTS or Federal Register guidance specifies metal content calculation methodology.

**Implementation:** `config/policy_params.yaml` (`metal_content` block, `method: 'bea'`), `resources/metal_content_shares_bea_hs10.csv`, `src/helpers.R:load_metal_content()`. Per-type scaling in `src/06_calculate_rates.R:apply_232_derivatives()`. Per-type nonmetal_share in `src/helpers.R:apply_stacking_rules()` and `compute_net_authority_contributions()`.

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

**Assumption:** ~568 metal-containing articles outside primary chapters are covered as Section 232 derivatives (HTS8 prefixes). This includes:
- **Aluminum derivatives** (~211 entries): articles outside chapter 76, covered by 9903.85.04/.07/.08 (US Note 19 subdivisions j/k/r/s). Original ~129 entries reverse-engineered from US Note 19.
- **Steel derivatives** (~357 entries): articles outside chapters 72-73, covered by 9903.81.89-93 (US Note 16 subdivisions m/n/t/u). Added via the Section 232 Inclusions Process (FR 2025-15819, effective August 18, 2025).

Products in both types (e.g., dairy in steel cans with aluminum lids, HTS 0402.99.68) get two rows in the CSV; the rate calculator applies the higher effective rate and tags the dominant type for stacking.

**Source:** Original aluminum list from Tariff-ETRs project (US Note 19 PDF). Steel derivatives and additional aluminum derivatives from Federal Register notice 2025-15819 (Vol. 90, No. 158, August 19, 2025). Source PDF: `docs/federal-register/2025-15819.pdf`.

**Why non-official:** The product lists are maintained externally because HTS JSON does not provide US Note 16/19 subdivision text. The `derivative_type` column (steel/aluminum) determines which per-type metal share is used for scaling. Should be re-derived directly from the Chapter 99 PDF when `scrape_us_notes.R` is extended with Note 16/19 parsers.

**Implementation:** `resources/s232_derivative_products.csv` (568 HTS8 prefix entries with `hts_prefix`, `ch99_code`, `derivative_type`), loaded by `src/helpers.R:load_232_derivative_products()`. Per-type scaling in `src/06_calculate_rates.R:apply_232_derivatives()` uses `steel_share` for steel derivatives and `aluminum_share` for aluminum derivatives. Prefixes are HTS8 (not HTS10) to ensure stability across HTS revision suffix changes.

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

**Assumption:** IEEPA reciprocal tariff exemptions cover products from five sources:

1. **Annex A / US Note 2 subdivision (v)(iii)**: ~2,172 HTS8 codes expanded to ~4,106 HTS10 (including ITA prefix entries for headings 8471, 8473.30, 8486, 8523, 8524, 8541, 8542)
2. **Chapter 98 statutory exemption**: US Note 2 subdivision (v)(i) explicitly exempts Chapter 98 articles from IEEPA reciprocal, except 9802.00.40/.50/.60/.80. Adds ~101 HTS10 codes.
3. **Country-specific carve-outs**: Merged from Tariff-ETRs `ieepa_reciprocal.yaml` product_rates (rate=0).
4. **Chapter 97 (Berman Amendment)**: Artworks, collectors' pieces, antiques — exempt via 19 USC 2505 ("informational materials"). TPC confirms these have their own Ch99 code.
5. **Chapter 49 (Berman Amendment)**: Printed matter — also exempt as "informational materials" under 19 USC 2505.

**Source:** Executive orders (official policy), but the product list is maintained as an external resource file because the HTS JSON API does not provide US Notes text. List history: initial 1,087 codes → +1,085 from ETRs merge (March 2026) → +1,993 from HTS8→HTS10 expansion + 101 Ch98 + 59 ITA prefix expansion (March 9, 2026) → ch97 + ch49 Berman Amendment expansion (March 20, 2026).

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

## 12. Section 122 / Section 232 Mutual Exclusion on Metal Products

**Assumption:** Section 122 follows the same mutual-exclusion treatment as IEEPA reciprocal with respect to Section 232. On products with `rate_232 > 0`, the Section 122 rate is scaled by `nonmetal_share`, which is computed per metal type (see Assumption 1):

| Product type | Active type share | nonmetal_share | Section 122 effective contribution |
|-------------|-------------------|----------------|-------------------------------------|
| Pure 232 steel (ch72/73) | steel_share = 1.0 | 0.0 | Zero |
| Pure 232 aluminum (ch76) | aluminum_share = 1.0 | 0.0 | Zero |
| Derivative 232 (aluminum articles) | aluminum_share = x | 1 - x | rate_s122 * (1 - aluminum_share) |
| Non-232 | n/a | n/a | Full rate_s122 |

**Rationale:** Section 232 already covers metal products at rates well above Section 122's 15% statutory maximum. Applying Section 122 to the metal portion would double-count the tariff on products already subject to 232.

**Source:** Tariff-ETRs stacking logic, which applies the same per-type nonmetal scaling to all non-232 blanket authorities. No explicit Federal Register guidance specifies the interaction between Section 122 and Section 232 on overlapping products.

**Post-annex update (April 2026):** For annex-classified products, `nonmetal_share` is forced to 0 (see Assumption 1 post-annex update), so Section 122 contributes zero on all post-annex 232 products — not just primary chapters. The derivative row in the table above effectively becomes `nonmetal_share = 0` post-annex.

**Implementation:** `src/helpers.R:apply_stacking_rules()` — the `case_when` branches for `rate_232 > 0` multiply `rate_s122` by `nonmetal_share`, which is computed from the active 232 program's type-specific share (0 for pure-metal products, `1 - aluminum_share` for derivatives). Post-annex, the `s232_annex` override forces `nonmetal_share = 0` for all annex-classified products.

---

## 13. IEEPA Duty-Free Product Treatment

**Assumption:** Our default (`'all'`) applies IEEPA reciprocal tariffs to all products regardless of MFN base rate, which is the legally strict interpretation (EO text does not carve out duty-free products). Setting `ieepa_duty_free_treatment: 'nonzero_base_only'` excludes 0% MFN products as a sensitivity analysis.

**TPC feedback (March 2026):** TPC does **not** use a blanket duty-free exclusion. Instead, specific product categories are exempt for specific legal reasons:
- **Berman Amendment** (19 USC 2505): Ch49 (printed matter) and Ch97 (artworks/antiques) — "informational materials"
- **Annex II**: Electronics (ITA products in Ch84/85)
- **Country-specific generic pharma shares**: Partial exemption based on generic drug import shares
- **Ch98 statutory**: Special classification provisions

The `nonzero_base_only` toggle partially overlaps with these product-specific exemptions but is not equivalent. It remains useful as a sensitivity analysis variant but should not be characterized as "matching TPC methodology."

**Impact:** ~26K product-country pairs at rev_32 (14,930 in floor countries + 11,288 in non-floor). Top affected chapters: 61-62 (apparel, ~7K), 84-85 (ITA machinery/electronics, ~1.7K), 98 (special provisions, ~3.5K), 97 (artworks), 29-30 (pharma), 49 (printed matter).

**Implementation:** `config/policy_params.yaml` (`ieepa_duty_free_treatment`), applied in `src/06_calculate_rates.R` step 2. Berman Amendment products (ch49, ch97) added to IEEPA exempt list via `src/expand_ieepa_exempt.R` Fixes 4-5.

---

## 14. IEEPA Floor Deduction Against Effective (Post-FTA) Base Rate

**Assumption:** For floor countries (EU-27, Japan, South Korea, Switzerland, Liechtenstein), the IEEPA floor deduction is computed against the effective base rate (after MFN/FTA preference utilization), not the statutory MFN rate. This means FTA preferences widen the floor gap: a product with 5% statutory MFN and 90% KORUS exemption yields `max(0, 0.15 - 0.005) = 14.5%`, not `max(0, 0.15 - 0.05) = 10%`.

**Rationale:** The floor rate represents the intended minimum total tariff level. Measuring against the effective base (what the importer actually pays in MFN duty) ensures the total rate reaches the floor. Measuring against statutory MFN would undercount the additional tariff needed for FTA-preference-utilizing imports.

**Impact:** South Korea (+3.2pp mean IEEPA increase, from 79.5% KORUS preference utilization), Japan (+0.32pp, 14.9% FTA utilization), EU countries (+0.01 to +0.22pp). Aligns with Tariff-ETRs methodology.

**Source:** Tariff-ETRs order-of-operations confirmed via comparison analysis. No explicit Federal Register guidance on whether floor deduction should use statutory or effective base rate.

**Implementation:** `src/06_calculate_rates.R` step 6d — after MFN exemption shares are applied to `base_rate` (step 6c), rows with `ieepa_type == 'floor'` and `rate_ieepa_recip > 0` are recomputed as `pmax(0, floor_rate - base_rate)`. The `ieepa_type` flag is preserved from Step 2 to distinguish genuine floor rows from surcharge rows for the same countries (e.g., Swiss/Liechtenstein outside the framework window).

---

## 15. IEEPA Exempt Products: ITA Prefix Expansion

**Assumption:** The tracker includes ~125 more IEEPA-exempt HTS8 codes than Tariff-ETRs, primarily in Ch84/85 (computers, semiconductors, integrated circuits) derived from US Note 2 subdivision (v)(iii) ITA product prefixes. These products are exempt from IEEPA reciprocal tariffs in the tracker but subject to the full surcharge in ETRs.

**Impact:** Primarily affects Taiwan (-6.9pp vs ETRs at Jan 1, 2026) and Malaysia (-5.9pp) — both are major electronics/semiconductor exporters. The gap vanishes after IEEPA invalidation (Feb 24).

**Source:** `src/expand_ieepa_exempt.R` Fix 3 (ITA prefix expansion) based on the legal text of US Note 2 subdivision (v)(iii). The tracker's interpretation is broader; Tariff-ETRs uses a narrower product list.

**Implementation:** `resources/ieepa_exempt_products.csv` (4,325 HTS10 codes), expanded from the base Annex A list via `src/expand_ieepa_exempt.R`.
