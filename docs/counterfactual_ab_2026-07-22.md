# Counterfactual engine A/B — old (column-zeroing) vs new (input-removal)

**Date:** 2026-07-22
**Old side:** merge-base `54b0fb9` (pre-cleanup engine: compute baseline, zero the
disabled authority's rate columns before stacking), built in a clean checkout.
**New side:** `cleanup` @ `3e86da8` (input removal: drop the authority's Ch99
rows/extractor tables/config, recompute the world).
**Builds:** identical inputs, weight_mode required, all 6 counterfactuals + 4 USMCA
alternatives, published to `model_data/.validation/ab-{old,new}-engine/2026-07-22-11`.
**Analysis:** `scripts/ab_delta_report.R` on the published daily series.

## Headline: the semantics change is real but very small, and fully explained

| Series | Days changed (of 730) | Mean abs diff (pp) | Max abs diff (pp) |
|---|---|---|---|
| `pre_2025` | 245 | 0.0043 | 0.0130 |
| `no_ieepa` | 245 | 0.0038 | 0.0129 |
| `no_ieepa_recip` | 245 | 0.0038 | 0.0129 |
| `no_232`, `no_301`, `no_s122` | 0 | — | float noise (≤1e-15) |
| `usmca_2024/annual/monthly/dec2025` | 0 | — | float noise (≤1e-15) |
| `actual` (control) | 0 | 0 | byte-identical |

- The **baseline and seven of ten scenarios are unchanged** (identical or within
  float reassociation). Notably `no_232` — the scenario we most feared cross-
  authority drift in — matches exactly, because the old engine zeroed columns
  *before* stacking, so displacement effects were already recomputed there.
- Only the three **IEEPA-removal** scenarios move, from the same single cause.

## The one real difference: Taiwan zero-metal-content steel derivatives

On the worst day (2026-11-10), the entire overall-ETR difference traces to
**Taiwan (census 5830): +0.36 pp**, all of it in `rate_232`, on **346 chapter-73
steel-derivative lines** (e.g. 7304.31/7304.39 tubes) whose declared **metal
content is zero**.

Baseline law (both engines agree): a zero-metal-content derivative line pays
§232 on its metal content (= nothing) and rides the IEEPA reciprocal on its full
value. The engines diverge on what happens when IEEPA is removed:

- **Old engine:** §232 was computed with IEEPA present (still 0 on these lines),
  then the reciprocal column was erased → the lines end up **fully untaxed**.
- **New engine:** with IEEPA absent from the input world, the content-split
  routing no longer exists, and the lines take their **flat §232 heading/annex
  rate** (0.25/0.50, plus annex tiers).

Which is legally correct in a world where the reciprocal never existed is a
judgment call, not a code question:

1. *§232-on-metal-content-only* reading — the §232 duty attaches to metal
   content by its own terms; a zero-content line stays at 0 and the non-metal
   value is simply untaxed (the old engine's answer, by accident).
2. *Content-split-as-election* reading — the content split exists only because
   the June-2025 proclamation pairs it with the reciprocal ("metal content pays
   §232, remainder pays reciprocal"); with no reciprocal there is no split to
   elect and the line pays the flat derivative rate on full value (the new
   engine's answer).

**Recommendation:** accept the new engine's numbers (reading 2) as the working
treatment — it is at least a deliberate, single-home rule rather than a
side-effect of column zeroing — and record the open legal question here. If
reading 1 is preferred after review of the proclamation text, it is a scoped,
testable change to the §232 content-split gate in the spec adapter.

Either way the stakes are bounded: ≤0.013 pp on any scenario's overall daily
ETR, ≤0.36 pp on Taiwan on the worst day, zero effect on the published baseline
and on `new_301`.

## Provenance

- Old build: `.validation/ab-old-engine/2026-07-22-11` (manifest: `54b0fb9`; tracked files verified clean — the manifest dirty flag reflects only the untracked one-off build config and synced gitignored input data)
- New build: `.validation/ab-new-engine/2026-07-22-11` (manifest: `3e86da8`, clean)
- Both sides: 11 series × 52 snapshots each, 730-day daily series, weighted.
- Reproduce: `Rscript scripts/ab_delta_report.R --old <old-root> --new <new-root>`
