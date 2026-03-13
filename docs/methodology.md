# Methodology

This document is the canonical description of the tariff regime, the repo's modeling choices, the production outputs, the benchmark comparisons, and the main open questions.

## Scope

The tracker constructs statutory U.S. tariff rates at the `HTS-10 x country` level by processing USITC HTS revisions. The current repo covers 39 revisions from January 1, 2025 through February 25, 2026, and extends the final interval through December 31, 2026 using the configured series horizon.

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
- For derivative 232 products, IEEPA can still apply to the non-metal portion.
- Fentanyl, Section 301, Section 122, Section 201, and other provisions then contribute according to the modeled authority rules.

An alternative `tpc_additive` mode exists for diagnostic comparison only.

## Key modeling choices

### Section 232

Section 232 is modeled through a mix of:

- blanket chapter coverage
- heading or prefix coverage
- explicit product lists for derivatives, copper, auto parts, and MHD products

Derivative products use a configurable metal-share estimate. The default is the BEA-based HS10 metal-share file.

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

### USMCA utilization

The production model uses product-level USMCA utilization shares from USITC DataWeb resources committed in `resources/`.

This is now a core modeling input, not a Tariff-ETRs benchmark input.

### Section 122

Section 122 is treated as a temporary post-IEEPA blanket authority with a configurable expiry date and `finalized` flag.

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

## Outputs and interpretation

### Revision-level panel

The revision panel is the legal-in-effect dataset. It answers:

- what statutory tariff rate applied to a given product-country pair
- under which revision and date interval
- which component authorities contributed to that rate

### Daily aggregates

Daily outputs are derived by broadcasting piecewise-constant revision intervals across calendar days, with explicit handling for date-bounded overrides such as Section 122 expiry.

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

The main current takeaways from the tracked comparison work are:

- product-level USMCA shares are a meaningful tracker-side improvement
- copper and several auto-related gaps were resolved
- some remaining differences appear methodological rather than parser bugs

## Open modeling questions

### Legacy non-China Section 301 lines

The repo's China Section 301 logic is intentionally built from the China product lists and active China-oriented Chapter 99 codes. It does not use `9903.89.xx`, which belongs to the separate large civil aircraft dispute with the EU/UK. For the current series horizon, those tariffs are treated as suspended from 2021 onward, so they are not part of the active 2025-2026 China Section 301 modeling path. If the repo is extended to cover the live aircraft-dispute period, that branch should be modeled separately rather than folded into the China blanket logic.

### Floor-country residuals

Even after accounting for duty-free treatment choices, some floor-country differences versus TPC remain unexplained. This may reflect a different product-level methodology on the benchmark side or an unmodeled exemption path on the tracker side.

### Liberation Day timing

The repo is intentionally tied to published HTS revisions. That means very short-lived announced policies that never become fully encoded in the HTS will remain only partially represented.

### Comparison-runner completeness

The repo has a comparison runner, but the Tariff-ETRs cross-repo path is not yet fully implemented inside `run_comparisons.R`.

## What this methodology does not claim

The repo does not estimate incidence, effective collection rates, or behavioral responses. It models statutory tariff rates as encoded in the HTS and related documented assumptions.
