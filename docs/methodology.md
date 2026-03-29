# Methodology

This document is the canonical description of the tariff regime, the repo's modeling choices, the production outputs, the benchmark comparisons, and the main open questions.

## Scope

The tracker constructs statutory U.S. tariff rates at the `HTS-10 x country` level by processing USITC HTS revisions. The current repo covers 38 revisions from January 1, 2025 through February 24, 2026, and extends the final interval through December 31, 2026 using the configured series horizon.

The production series is built from:

- HTS JSON archives
- committed repo resources
- documented policy parameters in `config/policy_params.yaml`
- optional product-share and weighting inputs that are not benchmark outputs

TPC and Tariff-ETRs are used for validation and comparison only.

## Tariff-regime history

### Pre-2025 baseline

At the start of 2025, the modeled baseline already included:

- statutory MFN base rates
- Section 232 tariffs on steel and aluminum
- Section 301 tariffs on China, including pre-2025 Biden-era accelerations
- Section 201 safeguard duties

### 2025-2026 sequence modeled by the repo

- January 2025: China and Hong Kong fentanyl tariffs begin.
- February 2025: Canada and Mexico fentanyl tariffs begin.
- March 2025: Section 232 autos and derivative expansions arrive; legacy 232 country exemptions end.
- April 2025: Phase 1 reciprocal tariffs and the China escalation sequence appear in HTS revisions.
- April 2025: The Geneva de-escalation sequence returns China to the universal baseline and suspends the China-specific reciprocal entry.
- May to July 2025: 232 steel and aluminum rates increase; auto parts and copper programs expand; Canada's fentanyl rate increases.
- August to November 2025: Phase 2 reciprocal rates, negotiated floor structures, and 301 crane provisions are added.
- January 2026: Swiss and Liechtenstein floor treatment and 2026-era 301 accelerations enter the schedule.
- February 2026: IEEPA is invalidated, and Section 122 becomes the post-IEEPA blanket authority.

The revision-by-revision chronology lives in [revision_changelog.md](revision_changelog.md).

## Production outputs

### Core production dataset

The canonical output is the interval-encoded timeseries in `data/timeseries/rate_timeseries.rds`.

Each row is a product-country observation with:

- component rates by authority
- total additional duty
- total rate
- the HTS revision in force
- `valid_from` and `valid_until`

Daily outputs are derived from this interval representation rather than stored as a full product-country-day panel by default.

### Derived outputs

- Daily aggregate series by overall, country, and authority
- Filtered daily product-country extracts on demand
- Weighted ETR outputs when local import weights are configured
- Sensitivity variants and diagnostic outputs

## Revision discovery and dating

New HTS revisions are discovered automatically via the USITC REST API (`hts.usitc.gov/reststop/releaseList`). The scraper (`src/01_scrape_revision_dates.R`) also checks whether the Chapter 99 PDF has changed by comparing SHA-256 hashes, which can detect amendments that have not yet been published as a separate API release.

**Important:** The API returns *publication dates* (when USITC posted the revision), not *policy effective dates* (when the tariff took effect). These regularly differ by weeks. When the scraper adds a new revision, it uses the publication date as a placeholder and marks the `policy_event` column with `[REVIEW]`. The pipeline treats this date as the policy date for timeseries intervals until manually corrected. The correct policy effective date should be set in `config/revision_dates.csv` before running a production build.

## HTS product concordance

Product codes can change between HTS revisions — codes are renamed, split, merged, or dropped. The concordance builder (`src/build_hts_concordance.R`) tracks these changes by comparing consecutive revision JSONs using Jaccard word-overlap similarity within same 4-digit headings (inspired by Pierce & Schott 2012). The output is `resources/hts_concordance.csv`.

The concordance is used in `compare_etrs.R` to remap Census import codes (which reflect the 2024 HTS edition) to match snapshot codes from later revisions. Without this remapping, products that were renumbered between the import data vintage and the snapshot revision would drop out of the import-weighted ETR numerator, artificially depressing the ETR for countries concentrated in affected products.

## Operational model

### Step 1: parse revision inputs

For each HTS revision, the pipeline parses:

- Chapter 99 entries and additional-duty rates
- product lines and footnote references
- special program fields
- IEEPA country-rate entries
- Section 232 program entries
- USMCA eligibility signals

### Step 2: construct product-country rates

The main rate builder combines several linking mechanisms:

1. Footnote references for product-specific Chapter 99 provisions.
2. Blanket chapter or heading coverage for authorities like Section 232.
3. Product lists maintained outside the JSON when US Notes are not machine-readable.
4. Country-wide blanket programs such as IEEPA reciprocal, fentanyl, and Section 122.

### Step 3: adjust base rates and exemptions

The repo tracks both:

- `statutory_base_rate`
- `base_rate`, after MFN exemption-share adjustment

Canada and Mexico are handled separately through product-level USMCA utilization shares rather than the general MFN exemption-share adjustment.

### Step 4: apply authority-specific logic

The production code tracks these authorities:

- Section 232
- Section 301
- IEEPA reciprocal
- IEEPA fentanyl
- Section 122
- Section 201
- other residual Chapter 99 provisions

### Step 5: stack component rates into totals

The default production rule is `mutual_exclusion`, implemented in `helpers.R::apply_stacking_rules()`.

In words:

- Section 232 takes precedence over IEEPA reciprocal on the metal-covered portion.
- For derivative 232 products, IEEPA reciprocal and Section 122 apply only to the non-metal portion. The non-metal share is computed per metal type: steel chapters (72/73) use `1 - steel_share`, aluminum chapters (76) and derivatives use `1 - aluminum_share`, and copper headings use `1 - copper_share`. This ensures IEEPA fills only the portion not claimed by the active 232 program's specific metal type, rather than the aggregate metal content.
- Fentanyl always stacks in full on 232 products (not scaled by metal share), matching the China treatment.
- Section 301 contributes only for China (the builder assigns `rate_301` exclusively to China-origin products). Non-China 301 is excluded from stacking to match the decomposition. If non-China Section 301 tariffs emerge in the future, they should use a dedicated authority column.
- Section 201 and other provisions contribute at their full rates.

An alternative `tpc_additive` mode exists for diagnostic comparison only.

## Key modeling choices

### Section 232

Section 232 is modeled through a mix of:

- blanket chapter coverage
- heading or prefix coverage
- explicit product lists for derivatives, copper, auto parts, and MHD products

Derivative products use a configurable metal-share estimate. The default is the BEA-based HS10 metal-share file, which provides per-type breakdowns (`steel_share`, `aluminum_share`, `copper_share`, `other_metal_share`). Aluminum derivatives are scaled by `aluminum_share` specifically — the derivative tariff applies only to the aluminum content, not steel or copper fractions that may be present. Products that overlap between heading programs (e.g., auto parts that are also aluminum derivatives) use the heading rate at full product value rather than being metal-scaled.

### Section 301

Section 301 coverage is driven by `resources/s301_product_lists.csv` plus rate mappings in `policy_params.yaml`.

For products that map to multiple active 301 Ch99 entries, the current production rule is:

- take the maximum active 301 rate for the product's HTS8 code

This treats overlapping generations as supersession rather than additive stacking.

### IEEPA reciprocal and floor treatment

IEEPA reciprocal rates are parsed from HTS Chapter 99 entries and classified into surcharge, floor, or passthrough behavior.

The repo currently defaults to:

- applying reciprocal tariffs to all products, including duty-free products

This is configurable through `ieepa_duty_free_treatment`. Benchmark comparisons show that changing to `nonzero_base_only` improves TPC agreement for some floor-country cases.

For floor countries (EU-27, Japan, South Korea, Switzerland, Liechtenstein), the IEEPA reciprocal rate is computed as `max(0, floor_rate - base_rate)`. The floor deduction is computed against the effective (post-MFN-exemption) base rate, not the statutory MFN rate. This means FTA preferences (e.g., KORUS for South Korea) widen the floor gap — if the statutory MFN is 5% but KORUS reduces the effective base to 0.5%, the IEEPA floor component is `max(0, 0.15 - 0.005) = 14.5%`, not `max(0, 0.15 - 0.05) = 10%`. This aligns with the Tariff-ETRs methodology and reflects the policy intent that the floor rate represents the intended total tariff level.

The recomputation is implemented as Step 6d in `06_calculate_rates.R`, after MFN exemption shares are applied in Step 6c. Step 6d uses the `ieepa_type` flag (preserved from Step 2) to identify rows that were originally computed as floor-type deductions. This ensures that surcharge rows for floor countries — such as Switzerland and Liechtenstein outside their framework window — are not incorrectly converted into floor deductions.

### IEEPA exempt products and ITA prefix expansion

The repo identifies ~4,325 HTS10 products as exempt from IEEPA reciprocal tariffs, based on US Note 2 subdivision (v)(iii) (Annex A), Chapter 98 statutory exemptions, and country-specific carve-outs. The expansion pipeline (`src/expand_ieepa_exempt.R`) includes ITA (Information Technology Agreement) prefix entries for headings such as 8471, 8473.30, 8486, 8523, 8524, 8541, and 8542, adding ~125 more HTS8 codes than the Tariff-ETRs project lists.

This difference primarily affects Taiwan and Malaysia in weighted ETR comparisons (−6.9pp and −5.9pp respectively versus Tariff-ETRs at January 1, 2026), because both are major electronics and semiconductor exporters concentrated in Chapters 84–85. The gap vanishes after IEEPA invalidation (February 24, 2026) since these products are no longer subject to IEEPA reciprocal tariffs under either methodology.

The tracker's broader interpretation follows the legal text of the subdivision, which defines exempt products by ITA heading prefixes rather than enumerating individual HTS10 codes. This is a known methodological difference, not a data error on either side. See [assumptions.md, Assumption 15](assumptions.md) for details.

### USMCA utilization

The production model uses product-level USMCA utilization shares from USITC DataWeb resources committed in `resources/`.

This is now a core modeling input, not a Tariff-ETRs benchmark input.

### Section 122

Section 122 is treated as a temporary post-IEEPA blanket authority with a configurable expiry date and `finalized` flag.

Section 122 follows the same mutual-exclusion rule as IEEPA reciprocal with respect to Section 232. On products with `rate_232 > 0`, the Section 122 rate is scaled by `nonmetal_share` (= `1 - metal_share`). For pure 232 products (`metal_share = 1.0`), Section 122 contributes zero because Section 232 already covers them at higher rates (50% steel/aluminum vs. 15% maximum under Section 122). For derivative 232 products, Section 122 applies only to the non-metal portion. For non-232 products, Section 122 stacks at its full rate.

USMCA-eligible imports are exempt from Section 122 tariffs, parallel to the IEEPA USMCA exception. The exemption is applied via product-level USMCA utilization shares (same mechanism as IEEPA/fentanyl). This is reflected in the ETRs export config as `s122_usmca_exception = 1`.

The repo enforces Section 122 timing in three places:

- build-time per-revision rate construction
- daily aggregate splitting and zeroing
- point-in-time and filtered daily queries

## Assumptions and parameter choices

All major policy and modeling parameters live in `config/policy_params.yaml`.

The main non-official assumptions are cataloged in [assumptions.md](assumptions.md), including:

- mutual exclusion versus additive stacking
- derivative metal-share estimation
- product-level USMCA utilization
- resource-file-based exemption and product lists
- duty-free treatment choices
- floor deduction order-of-operations (post-FTA base rate)
- IEEPA exempt product scope (ITA prefix expansion)

## Outputs and interpretation

### Revision-level panel

The revision panel is the legal-in-effect dataset. It answers:

- what statutory tariff rate applied to a given product-country pair
- under which revision and date interval
- which component authorities contributed to that rate

### Daily aggregates

Daily outputs are derived by broadcasting piecewise-constant revision intervals across calendar days, with explicit handling for date-bounded overrides such as Section 122 expiry.

Unweighted daily means are reported with two denominators:

- `*_exposed`: mean across product-country pairs present in the sparse tariff panel (pairs with non-zero tariff activity).
- `*_all_pairs`: mean across the full Cartesian product of all products and all countries in the revision. Missing pairs are treated as having zero additional tariff. This is the default reporting statistic.

The all-pairs denominator is `n_products * n_countries` for overall aggregates and `n_products_total` for per-country aggregates. Products with zero additional tariff across all countries are generally still present in the panel through blanket IEEPA coverage, so the two denominators converge for revisions with broad blanket programs.

### Weighted ETRs

Weighted ETRs are reporting outputs, not separate production logic. They use local import weights when available and summarize the product-country panel by:

- overall
- partner
- authority
- GTAP sector

## Validation and external comparison

### TPC

TPC is used for point-in-time product-country validation and for contextual comparison of weighted aggregates.

The repo's strongest agreement with TPC tends to occur in relatively stable periods. The largest recurring residuals are:

- Liberation Day timing and encoding differences
- floor-country residuals
- Section 232 plus reciprocal stacking differences

### Tariff-ETRs

Tariff-ETRs comparison is useful for cross-repo reconciliation, especially around:

- USMCA treatment
- Section 232 coverage
- denominator choices in ETR reporting
- IEEPA exempt product scope

The main current takeaways from the tracked comparison work are:

- product-level USMCA shares are a meaningful tracker-side improvement
- copper and several auto-related gaps were resolved
- the floor deduction order-of-operations was aligned (Step 6d recomputes against post-FTA base rate, closing the South Korea gap)
- Taiwan and Malaysia gaps are explained by broader ITA prefix expansion in the tracker's IEEPA exempt list (see [assumptions.md, Assumption 15](assumptions.md))
- HTS product concordance remapping in `compare_etrs.R` addresses spurious ETR drops from code renumbering (e.g., Cayman Islands lithium battery codes)
- some remaining differences appear methodological rather than parser bugs

## Open modeling questions

### Legacy non-China Section 301 lines

The repo's China Section 301 logic is intentionally built from the China product lists and active China-oriented Chapter 99 codes. It does not use `9903.89.xx`, which belongs to the separate large civil aircraft dispute with the EU/UK. For the current series horizon, those tariffs are treated as suspended from 2021 onward, so they are not part of the active 2025-2026 China Section 301 modeling path. If the repo is extended to cover the live aircraft-dispute period, that branch should be modeled separately rather than folded into the China blanket logic.

### Floor-country residuals

The Step 6d floor recomputation (against post-FTA base rates) closed the largest floor-country gap versus Tariff-ETRs (South Korea: −4.6pp → approximately closed). Some residual floor-country differences versus TPC remain, which may reflect a different product-level methodology on the benchmark side or an unmodeled exemption path on the tracker side.

### Liberation Day timing

The repo is intentionally tied to published HTS revisions. That means very short-lived announced policies that never become fully encoded in the HTS will remain only partially represented.

### Comparison-runner completeness

The repo has a comparison runner, but the Tariff-ETRs cross-repo path is not yet fully implemented inside `run_comparisons.R`.

## What this methodology does not claim

The repo does not estimate incidence, effective collection rates, or behavioral responses. It models statutory tariff rates as encoded in the HTS and related documented assumptions.
