# Follow-Up Memo on Remaining Unresolved Comparison Issues

## Purpose

This memo reviews the issues still described as unresolved in:

- [README.md](README.md)
- [docs/comparison_vs_tariff_etrs.md](docs/comparison_vs_tariff_etrs.md)

The goal is to distinguish between:

1. true implementation gaps in this repository,
2. methodological differences versus TPC or Tariff-ETRs, and
3. documentation claims that no longer match the current code.

## Executive Summary

Three follow-up actions stand out:

1. Reconcile the Section 301 comparison write-up with the live code. The code appears to apply a single maximum 301 rate per HTS8, not the multi-generation Trump-plus-Biden logic described in the docs.
2. Reframe the EU/Japan/Korea floor residual. A substantial part of that residual still appears tied to the configurable IEEPA duty-free treatment, and the repo default remains set away from the TPC-aligned option.
3. Keep the 301 exclusion issue on the open list. It is a genuine missing feature, though likely low impact.

Two other items should be treated differently:

- China plus Section 232 reciprocal stacking looks like an intentional methodological choice, not a bug.
- The post-Geneva China reciprocal rate discrepancy looks like a source-timing interpretation issue, not an obvious parser failure.

## Recommendations by Issue

### 1. Section 301 rate treatment: re-audit and correct the memo

The comparison memo currently states that the tracker applies per-list Section 301 logic and that Biden-era 301 rates can coexist with Trump-era 301 rates in ways that match TPC high-rate clusters.

Relevant documentation:

- [docs/comparison_vs_tariff_etrs.md](docs/comparison_vs_tariff_etrs.md)
- [README.md](README.md)

However, the implementation in [src/06_calculate_rates.R](src/06_calculate_rates.R) appears to do something simpler:

- it filters to active 301 Chapter 99 codes,
- joins those to `resources/s301_product_lists.csv`,
- groups by `hts8`,
- and reduces to `max(s301_rate)`.

That logic is implemented at:

- [src/06_calculate_rates.R:1287](src/06_calculate_rates.R:1287)
- [src/06_calculate_rates.R:1299](src/06_calculate_rates.R:1299)

The applied rate is then pushed into `rate_301` here:

- [src/06_calculate_rates.R:1308](src/06_calculate_rates.R:1308)

Why this matters:

- `resources/s301_product_lists.csv` includes HTS8s that appear in both Trump-generation and Biden-generation lists.
- If the code takes only a single max rate, it cannot reproduce additive Trump-plus-Biden outcomes.
- That means the current comparison memo may be overstating confidence that this divergence is fully on the Tariff-ETRs side.

Suggested action:

1. Recompute 301 rates with explicit generation logic:
   - max within Trump generation,
   - max within Biden generation,
   - sum across generations where both apply,
   - unless a documented supersession rule applies for a specific overlap set.
2. Re-run the China comparison against both TPC and Tariff-ETRs.
3. Update [docs/comparison_vs_tariff_etrs.md](docs/comparison_vs_tariff_etrs.md) so it reflects verified implementation, not intended behavior.

Priority: High

This is the most important follow-up because it affects a major substantive conclusion in the comparison note.

### 2. EU floor residual: do not treat it as fully unexplained yet

The README currently presents the EU floor residual as mostly unexplained.

Relevant section:

- [README.md:455](README.md:455)

But the repo still defaults to:

- `ieepa_duty_free_treatment: 'all'`

in:

- [config/policy_params.yaml:373](config/policy_params.yaml:373)

The README already notes that the TPC-aligned alternative:

- `nonzero_base_only`

improves exact match materially:

- [README.md:358](README.md:358)
- [README.md:360](README.md:360)

The validation script explicitly measures this effect:

- [test_tpc_comparison.R:281](test_tpc_comparison.R:281)
- [test_tpc_comparison.R:304](test_tpc_comparison.R:304)

And the saved floor-country summary shows a large duty-free component:

- [output/validation/tpc_floor_group_summary.csv](output/validation/tpc_floor_group_summary.csv)

In that file, EU-27 has:

- `84,054` compared rows,
- `2.34pp` mean diff,
- `31,824` rows flagged as duty-free-gap.

Suggested action:

1. Re-run the full TPC comparison with `ieepa_duty_free_treatment: 'nonzero_base_only'`.
2. Recompute the floor-country residual after removing the duty-free treatment effect.
3. Split the write-up into:
   - residual explained by duty-free treatment choice,
   - residual remaining after the TPC-aligned setting is applied.

Recommended documentation change:

- soften the current “floor formula is correct but discrepancy remains unexplained” language until this rerun is done.

Priority: High

This likely changes the interpretation of one of the main “remaining issues.”

### 3. Section 301 exclusions remain a real missing feature

This issue is documented in the README:

- [README.md:451](README.md:451)

The code confirms it directly:

- [src/06_calculate_rates.R:1262](src/06_calculate_rates.R:1262)
- [src/06_calculate_rates.R:1266](src/06_calculate_rates.R:1266)

Current behavior:

- products on the blanket 301 lists receive the base 301 rate,
- later 9903.89.xx exclusion lists are not parsed,
- excluded products may therefore still be charged.

Suggested action:

1. Add a small parser for 9903.89.xx exclusion entries.
2. Build an exclusion resource keyed at least by `hts8`, ideally by the exact US Note list structure if available.
3. Subtract excluded products from the blanket `s301_lookup` before applying `rate_301`.

Priority: Medium

This appears to be low volume, but it is a clean, genuine feature gap and should stay on the unresolved list until fixed.

### 4. China plus Section 232 reciprocal stacking: classify as methodological, not unresolved

The README describes the China plus Section 232 discrepancy as a current issue:

- [README.md:447](README.md:447)

The actual stacking logic is explicit:

- [src/helpers.R:612](src/helpers.R:612)
- [src/helpers.R:627](src/helpers.R:627)

Current behavior:

- when `rate_232 > 0` and `metal_share = 1.0`, reciprocal contributes zero,
- this is consistent with the repo’s mutual-exclusion methodology,
- it is inconsistent with the additive approach apparently used by TPC for these products.

Suggested action:

- Move this issue out of the “unresolved implementation issue” bucket.
- Document it as a deliberate methodological divergence from TPC.
- Optionally expose a parallel diagnostic mode using `stacking_method = 'tpc_additive'` for comparison output only.

Priority: Low for code, high for documentation clarity

### 5. China post-Geneva reciprocal discrepancy: treat as timing/source interpretation

The methodology doc still lists China’s reciprocal rate as a remaining gap versus TPC.

The parser already contains explicit logic for handling:

- the universal baseline,
- the paused Phase 1 entries,
- the special China `9903.01.63` treatment,
- the post-suspension fallback.

Relevant code:

- [src/05_parse_policy_params.R:404](src/05_parse_policy_params.R:404)
- [src/05_parse_policy_params.R:419](src/05_parse_policy_params.R:419)

Suggested action:

- Leave this as a documented timing/source disagreement unless new evidence shows the HTS suspension markers are being misread.
- Do not prioritize code changes here ahead of the 301 and duty-free-treatment follow-ups.

Priority: Low

### 6. Ch87 auto gap versus Tariff-ETRs: keep investigating, but do not declare a cause yet

The comparison memo still lists a large chapter 87 gap and suggests it may reflect broader parts coverage or USMCA differences.

Relevant section:

- [docs/comparison_vs_tariff_etrs.md:67](docs/comparison_vs_tariff_etrs.md:67)

The codebase does include:

- explicit auto vehicle prefixes,
- a 130-code auto parts list,
- USMCA product shares for CA and MX,
- deal-rate overrides for auto programs.

Relevant implementation:

- [config/policy_params.yaml:91](config/policy_params.yaml:91)
- [config/policy_params.yaml:128](config/policy_params.yaml:128)
- [src/06_calculate_rates.R:1140](src/06_calculate_rates.R:1140)
- [src/06_calculate_rates.R:1194](src/06_calculate_rates.R:1194)

There is not yet a single clear code defect explaining the whole gap.

Two plausible remaining drivers:

1. different parts coverage between repos,
2. differences in how USMCA shares affect auto products and auto parts.

Suggested action:

1. Build a focused `ch87` reconciliation table for one comparison date.
2. Break it out by:
   - passenger vehicles,
   - light trucks,
   - auto parts,
   - Canada,
   - Mexico,
   - non-USMCA partners.
3. Compare:
   - product coverage,
   - applied `rate_232`,
   - applied `usmca_share`,
   - import weights.

Priority: Medium

This still looks unresolved, but it needs narrower diagnostics before any code change is justified.

## Suggested Edits to the Issue List

### Move or relabel

Move these out of “current unresolved issues” and into “methodological differences” or “comparison notes”:

- China plus 232 reciprocal stacking
- China post-Geneva reciprocal residual

### Keep open

Keep these open as real repo-side follow-ups:

- Section 301 exclusions
- Section 301 generation logic audit
- duty-free-treatment rerun for floor countries
- chapter 87 auto reconciliation

## Recommended Work Plan

### Phase 1: fix the interpretation layer

1. Audit and, if needed, correct 301 generation logic.
2. Re-run TPC validation with `ieepa_duty_free_treatment = 'nonzero_base_only'`.
3. Update README and comparison docs to reflect what remains unexplained after those reruns.

### Phase 2: targeted feature work

1. Implement 301 exclusions from 9903.89.xx.
2. Build a chapter 87 reconciliation diagnostic.

### Phase 3: doc cleanup

1. Separate “implementation gaps” from “methodological differences.”
2. Remove statements that imply confidence where the code path has not yet been verified.

## Bottom Line

The remaining issue list should be tightened.

The strongest repo-side follow-ups are:

- verify Section 301 generation logic,
- rerun floor-country validation under the TPC-aligned duty-free setting,
- implement 301 exclusions,
- investigate chapter 87 autos with a dedicated reconciliation table.

By contrast, China plus 232 reciprocal stacking should be presented as a deliberate methodological divergence, not as an unresolved defect in the tracker.
