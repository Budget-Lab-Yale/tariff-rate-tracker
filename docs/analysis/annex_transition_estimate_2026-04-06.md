# Section 232 Annex Transition Estimate (2026-04-06)

## Summary

Estimated the ETR impact of the April 2, 2026 Section 232 annex restructuring using the tracker's BEA metal content methodology. The estimate produces an opposite-sign result from SGEPT (+0.54pp vs -0.53pp), driven by differences in pre-transition metal content scaling assumptions.

## Method

- **Pre-annex snapshot**: `2026_rev_4` (effective 2026-02-24), the latest built revision
- **Post-annex counterfactual**: Same snapshot with annex rate overrides applied (I-A 50%, I-B 25%, II removed, III 15% floor)
- **Import weights**: 2024 Census data ($3,124B total)
- **Annex classification**: 803 HTS codes parsed from proclamation PDF

## Weighted ETR Comparison

|                                | Pre-annex | Post-annex | Change |
|--------------------------------|-----------|------------|--------|
| Total rate (base + additional) | 11.04%    | 11.58%     | +0.54pp |
| Additional tariffs             | 9.86%     | 10.40%     | +0.54pp |
| Section 232                    | 5.61%     | 5.73%      | +0.12pp |
| IEEPA reciprocal               | 0.00%     | 0.00%      | +0.00pp |
| Section 301                    | 1.39%     | 1.39%      | +0.00pp |
| Section 122                    | 3.91%     | 3.91%      | +0.00pp |

Note: IEEPA reciprocal is zero because `2026_rev_4` is post-IEEPA-invalidation. Section 122 is active in this snapshot (Feb 24, 2026 onward), but the annex counterfactual leaves its contribution unchanged.

## Decomposition by Channel

| Channel | Impact |
|---------|--------|
| Annex II removals (232 lost) | -1.28pp |
| Annex I-B rate cuts (50%→25%) | +0.82pp |
| Annex III floor (50%→floor) | +0.09pp |
| Annex I-A changes (incl. UK) | -0.00pp |
| IEEPA reciprocal stacking offset | +0.00pp |
| **Direct 232 change** | **-0.37pp** |
| **Net additional tariff change** | **+0.54pp** |
| Residual (stacking + rounding) | +0.92pp |

## Product Scope

| Annex | Products | Countries | Imports | Avg 232 pre | Avg 232 post |
|-------|----------|-----------|---------|-------------|--------------|
| I-A   | 1,251    | 179       | $99.5B  | 45.9%       | 49.7%        |
| I-B   | 959      | 210       | $380.6B | 16.1%       | 25.0%        |
| II    | 330      | 194       | $357.6B | 11.2%       | 0.0%         |
| III   | 141      | 172       | $55.7B  | 4.1%        | 14.5%        |
| None  | 15,537   | 231       | $2,066B | 1.3%        | 1.3%         |

327 products with pre-annex rate_232 > 0 were unclassified (13.0% weighted avg) — likely heading products (autos, MHD, wood) governed by separate Ch99 codes not in the annex PDF.

## SGEPT Comparison

|                          | Our estimate | SGEPT |
|--------------------------|-------------|-------|
| Pre-annex weighted rate  | 11.04%      | 11.44% |
| Post-annex weighted rate | 11.58%      | 10.91% |
| Change                   | +0.54pp     | -0.53pp |

## Why the Opposite Sign

The I-B rate "cut" (50%→25%) is actually a rate *increase* for many derivative products because:

1. **BEA metal scaling**: Under the old regime, derivative products have effective rates well below 50%. A steel derivative with `steel_share = 0.30` pays 50% × 0.30 = 15% effective. The new I-B rate of 25% on full value is higher.

2. **SGEPT uses higher flat shares**: Their calibrated content shares (steel derivatives 40%, aluminum derivatives 35%) produce higher pre-transition effective rates, making the 25% I-B rate more often a reduction.

3. **Content share discontinuity**: SGEPT drops content shares to 100% at the transition (since annexes define scope precisely). We keep BEA shares for stacking purposes, but the annex rate override implicitly applies to full value (no metal scaling), creating a different discontinuity.

The fundamental question: does the proclamation's "25% on full value" for I-B products mean those products pay more or less than under "50% on metal content"? The answer depends entirely on the metal content share assumption.

## Caveats

1. Pre-annex snapshot is `2026_rev_4` (Feb 20), not April 5 — IEEPA is already invalidated, so no IEEPA/232 stacking interaction
2. 327 unclassified 232 products (heading programs) not reclassified
3. UK deal applied but UK content qualifying share not modeled (all UK steel/aluminum gets preferential rate)
4. Exemptions (US-origin metal, de minimis, motorcycle) disabled (aggregate_share = 0)
5. No sensitivity analysis with SGEPT's flat content shares yet

## BEA Fix Impact Assessment

Separately evaluated whether the morning's BEA derivative fixes (copper scaling, decomposition parity, flat/CBO guard) affect the current build's ETR or 232 rates. Script: `scripts/evaluate_bea_fix_impact.R`.

**Finding: Zero effective impact on current rates.**

- **Copper headings**: 0 products with `rate_232 > 0` across all TPC revisions (rev_6 through rev_32). The copper 232 Ch99 codes (9903.78.xx) don't appear in any HTS JSON revision. The copper heading gate (`Skipping 232 heading "copper"`) fires every time. The fix to `load_metal_content()` is correct but has no effect until copper headings become active in a future HTS revision.
- **Primary chapter per-type shares**: Ch72-73 `steel_share = 0.000`, Ch76 `aluminum_share = 0.000` (primary chapter zeroing still active at `helpers.R:1662-1665`). Stacking `nonmetal_share` for primary chapters remains 0 — no change in behavior.
- **TPC regression**: The within-2pp drops observed in the post-fix TPC comparison (e.g., rev_6 67.5% vs prior 82.3%) are **not caused by the BEA fixes**. Root cause TBD — may stem from other rebuild differences.

## Scripts

- `scripts/estimate_annex_transition.R` — annex transition ETR estimate
- `scripts/evaluate_bea_fix_impact.R` — BEA fix impact assessment
