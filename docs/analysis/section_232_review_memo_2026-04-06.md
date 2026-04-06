# Section 232 Review Memo (2026-04-06)

## Summary

The current Section 232 implementation looks materially better on heading-versus-derivative matching than it did before, and the old broad heading-overmatch problem no longer looks like the main issue. The remaining problems are more targeted and mostly center on the BEA metal-content path, steel-derivative consistency, and tracker-to-ETRs export alignment.

The most important issue is the BEA metals derivative approach for copper. In the current code, copper heading products can either skip content scaling entirely or be scaled all the way to zero depending on whether unrelated derivative products are present in the same revision. That behavior is not economically plausible and is the highest-priority Section 232 problem in the repo right now.

## Current Issues

### 1. BEA copper scaling is unstable and can zero out valid heading rates

- `load_metal_content()` only creates `steel_share`, `aluminum_share`, `copper_share`, and `other_metal_share` when derivative products are present.
- In the BEA branch, those per-type shares are only populated for derivative rows; non-derivative rows get zeros.
- Later, the copper heading logic scales `rate_232` and `statutory_rate_232` by `copper_share`.

Net result:
- revisions with no derivatives skip copper scaling because `copper_share` is absent
- revisions with any derivatives can drive real copper heading rates to zero because non-derivative copper products carry `copper_share = 0`

This is the clearest explanation for the concern that something is off in the BEA metals derivative approach.

### 2. Net authority decomposition does not match stacking for steel derivatives

- `apply_stacking_rules()` uses `deriv_type` to decide whether a derivative product should use `steel_share` or `aluminum_share`
- `compute_net_authority_contributions()` does not carry that same logic through and still falls back to `aluminum_share` for non-chapter derivatives

This means the tracker can apply one mutual-exclusion split in the actual rate calculation and a different split in `daily_by_authority` or other decomposition outputs. The problem is especially visible for steel derivatives, where `net_ieepa`, `net_s122`, and the implied net 232 contribution can be misstated.

### 3. The steel-derivative US-melted exemption is documented but not modeled

The parser comments correctly note that `9903.81.92` is the US-melted steel exemption, but that entry is not part of the modeled steel-derivative handling path. Downstream derivative application also only supports country-based exemptions, not product-condition exemptions of this kind.

As a result, qualifying steel-derivative imports still appear to inherit the derivative 232 rate in the tracker even when the exemption should apply.

### 4. Exported ETR configs still miss steel-derivative metal metadata

The tracker export path classifies `steel_derivatives` as a Section 232 program, but `generate_other_params_yaml()` does not include that program in `metal_programs` or `program_metal_types`.

That means the internal tracker logic and exported Tariff-ETRs config can disagree on how steel derivatives should be metal-scaled, even if the tracker-side logic is corrected.

## Why This Matters

- The copper issue can materially understate or eliminate valid Section 232 rates.
- The decomposition issue can make authority-level outputs disagree with the actual rate logic.
- The steel exemption gap can overstate Section 232 on a real policy carveout.
- The export mismatch can make tracker and ETR builds diverge even after tracker-side fixes.

## Suggested Fix Order

1. Fix the BEA copper scaling path first.
2. Make `compute_net_authority_contributions()` mirror `apply_stacking_rules()` for derivative metal types.
3. Add explicit modeling for the `9903.81.92` steel-derivative exemption.
4. Add `steel_derivatives` to exported metal-program metadata.
5. Add regression tests for BEA per-type shares, copper heading scaling, and steel-derivative decomposition.

## Testing Note

`Rscript tests/run_tests_daily_series.R` currently passes, but the existing tests mostly cover full-metal chapter cases. They do not directly exercise the BEA per-type derivative path, copper heading content scaling, or steel-derivative decomposition, so they would not catch the issues summarized here.

## Status

All five issues confirmed against code on 2026-04-06.

### Fixed (2026-04-06)

1. **BEA copper scaling**: `load_metal_content()` (`helpers.R`) now populates per-type shares (steel, aluminum, copper, other) for all BEA-matched products, not just derivatives. Removed the `is_derivative &` guard on lines 1640–1643. Copper heading products (ch74) now get their `copper_share` from BEA regardless of derivative status.

2. **Authority decomposition**: `compute_net_authority_contributions()` (`helpers.R`) now includes `deriv_type` branches in its `case_when`, matching `apply_stacking_rules()`. Steel derivatives correctly use `steel_share` for nonmetal split in decomposition output.

4. **ETR export metadata**: Added `steel_derivatives = 'steel'` to `metal_type_map` in `generate_etrs_config.R`. Exported YAML now includes steel derivatives in `metal_programs` and `program_metal_types`.

5. **Flat/CBO column guard**: Heading-overlap per-type column reset in `apply_232_derivatives()` (`06_calculate_rates.R`) now gated on `has_per_type`, preventing runtime errors in flat/CBO mode.

### Deferred

3. **US-melted steel exemption** (`9903.81.92`): Requires product-condition exemption framework. TODO comment added at `05_parse_policy_params.R:690`.

### Tests added

Three regression tests in `tests/run_tests_daily_series.R`:
- Copper heading products get non-zero `copper_share` from BEA
- Decomposition uses `steel_share` (not `aluminum_share`) for steel derivatives
- Heading-overlap reset safe without per-type columns (flat/CBO mode)
