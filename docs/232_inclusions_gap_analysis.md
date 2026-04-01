# Section 232 Inclusions Process — Gap Analysis

> **Status: RESOLVED.** Implemented in commit addressing issue #1. See Remediation Steps below for what was done.

## Background

Federal Register notice 2025-15819 (August 19, 2025) documents the first cycle of the **Section 232 Steel and Aluminum Tariff Inclusions Process**, adding **407 new HTS codes** as steel or aluminum derivative products, effective August 18, 2025.

The inclusions process was established under Proclamations 10895 and 10896 (February 10, 2025), which directed the Secretary of Commerce to create a mechanism for adding derivative articles to Section 232 coverage. BIS implemented this via an Interim Final Rule (effective April 30, 2025), with the first submission window opening May 1, 2025.

Source: `docs/federal-register/2025-15819.pdf`

## Current Tracker Coverage

`resources/s232_derivative_products.csv` contains **129 aluminum-only derivative prefixes** across 11 chapters (66, 76, 83-85, 87-88, 90, 94-96), mapped to ch99 codes `9903.85.04/.07/.08`.

These were reverse-engineered from the pre-inclusions US Note 19 to Chapter 99.

The parser (`src/05_parse_policy_params.R`) checks only `9903.85.04/.07/.08` for aluminum derivatives. There is no steel derivative parsing.

## Gap 1: Steel Derivatives (Entirely Missing)

The inclusions process creates a new category of **steel derivative products** mapped to ch99 entries `9903.81.89-93`. The tracker has no mechanism for steel derivatives outside chapters 72-73.

Steel derivative products added span chapters far outside traditional steel coverage:

| Chapter | Products | Examples |
|---------|----------|---------|
| 04 | Dairy in steel cans | 0402.99.68, 0402.99.70, 0402.99.90 |
| 21 | Food preparations | 2106.90.9998 |
| 27 | Petroleum/LPG | 2710.19.3050, 2711.12.0020 |
| 28-29 | Chemicals | 2804.29, 2901.22, 2903.xx |
| 30 | Pharmaceuticals | 3004.90.9244 |
| 32-39 | Paints, cosmetics, soaps, adhesives, plastics | ~80+ codes |
| 82 | Tools, cutlery, knives | 8202-8215, ~40+ codes |
| 84 | Machinery, engines, bearings | ~100+ codes |
| 86 | Railway equipment | 8601-8609 |
| 87 | Tractors, vehicles, parts | 8701-8716 |
| 94-95 | Furniture, sporting goods | 9401, 9403, 9506 |

These products are subject to the 232 tariff on the **declared value of the steel content only**. IEEPA/reciprocal tariffs apply to the non-steel content (per Annex II amendments to US Note 2, subdivisions (v)(vi) and (v)(vii)).

## Gap 2: New Aluminum Derivative Products

The inclusions also expand aluminum derivative coverage (Note 19 amendments) with additional products in:

- Electrical cable (8544)
- Transformers (8504)
- Washing machines (8450)
- Power tools (8467)
- Various machinery parts

Many of these are in chapters already partially covered by the existing CSV but with different specific HTS codes.

## Gap 3: New Ch99 Code `9903.85.09`

Annex II amends US Note 19, subdivision (v)(ix) to reference `9903.85.04, 9903.85.07, 9903.85.08 and 9903.85.09`. The new `.09` entry is not parsed by `extract_section232_rates()`, which only checks `.04/.07/.08`.

## Stacking Rules (from Annex II)

The notice clarifies stacking for derivative products:

- **Steel derivatives** (9903.81.89-93): IEEPA duties (9903.01.25, .35, .39, .63, 9903.02.01-71) do NOT apply to steel content; they DO apply to non-steel content
- **Aluminum derivatives** (9903.85.04/.07/.08/.09): Same mutual-exclusion rule for aluminum content

This is consistent with the tracker's existing per-type metal scaling logic — the gap is only in product coverage, not methodology.

## Timing

- Effective date: August 18, 2025
- First HTS revision after effective date: `rev_20` (August 20, 2025)
- The HTS JSON for rev_20+ may contain footnote references to these new derivative entries, but the tracker's product list and parser would not pick them up

## Impact Assessment

The trade-weighted impact is likely **modest** for aggregate ETR estimates — many inclusions products have low metal content shares (cosmetics in aluminum tubes, dairy in steel cans, etc.), so the effective 232 rate after metal scaling would be small. However:

- The product count expansion is substantial (~3x)
- Steel derivatives are conceptually new to the tracker
- For product-level accuracy on affected codes, the gap matters

## Remediation Steps

1. **Add `9903.85.09`** to the parser in `extract_section232_rates()` alongside `.04/.07/.08`
2. **Add steel derivative parsing** for `9903.81.89-93` (new function or extension of existing logic)
3. **Expand `s232_derivative_products.csv`** (or create a separate inclusions file) with the 407 new HTS codes from the Federal Register notice, tagged by derivative type (steel vs aluminum)
4. **Add steel metal content shares** — the BEA per-type method already provides `steel_share`; need to apply it to steel derivatives the same way `aluminum_share` is applied to aluminum derivatives
5. **Verify HTS JSON footnotes** — check whether rev_20+ already has footnote references linking these products to the new ch99 entries (which would make the CSV partially redundant for post-inclusions revisions)
