# ETRs Comparison TODO

## 1. Slovakia Feb 24 spike (+7.8pp) — FIXED

**Root cause:** Bug in `compare_etrs.R` reconstruction logic. When IEEPA invalidation triggered `needs_reconstruct`, naive `rowSums()` added `rate_s122` at full value to 232 products instead of scaling by `nonmetal_share`. Replaced with `apply_stacking_rules()`. Pipeline rates were always correct.

**Result:** Feb 24 overall gap went from +0.45pp to -0.43pp.

## 2. South Korea / Taiwan / Malaysia negative gaps — INVESTIGATED

**South Korea (-4.6pp):** Floor formula order-of-operations. Step 2 computed `rate_ieepa_recip = max(0, 0.15 - statutory_base)` before Step 6c applied KORUS FTA exemption. ETRs computes floor against effective (post-FTA) base. Fix: added Step 6d to recompute floor deduction after MFN exemption. KR has 79.5% mean KORUS exemption share — simulated delta = +3.2pp, closing most of the gap. Also affects Japan (+0.32pp), EU (+0.01 to +0.22pp).

**Taiwan (-6.9pp) and Malaysia (-5.9pp):** Extra IEEPA-exempt products in tracker. The `expand_ieepa_exempt.R` ITA prefix expansion added ~125 more HTS8 codes (Ch84/85 electronics/semiconductors) than ETRs. These dominate TW (TSMC) and MY (electronics assembly) exports. **Tracker is correct per US Note 2 subdivision (v)(iii).** No code change needed.

## 3. Cayman Islands post-invalidation drop — INVESTIGATED

**Root cause:** Product concordance mismatch, not a rate bug. Product `8507600020` (lithium-ion battery cells, 47% of Cayman Islands' $36.5M imports) was renumbered to `8507600030`/`8507600090` in `2026_rev_4`. The `inner_join` in `compare_etrs.R` drops unmatched imports from the numerator while the denominator stays fixed, collapsing the ETR.

**Fix needed:** HTS product concordance mapping for renumbered codes. Building `src/build_hts_concordance.R` to diff consecutive revision JSONs and track splits/merges/renames. 65 products ($36.5B) affected between `2026_basic` and `2026_rev_4`.

## 4. Systematic small-country outliers

Persistent large gaps on low-import countries suggest systematic differences in preference/FTA handling:
- Azerbaijan: -26pp
- Bahrain: -22pp (has BFTA)
- UAE: -8pp (0.19% share — largest of this group)
- Uzbekistan: -12pp
- Georgia: +14pp
- Albania: +12pp
- New Caledonia: +22pp (French territory — classification mismatch?)

Doesn't affect aggregates but indicates the tracker may be missing some preference utilization data.

## Remaining actions

- [ ] Full pipeline rebuild to propagate floor fix (Step 6d) to snapshots
- [ ] Re-run `compare_etrs.R` after rebuild to confirm KR/JP/EU gap closure
- [ ] Complete HTS concordance builder and integrate into `compare_etrs.R`
- [ ] Document TW/MY exempt product difference as known methodological choice
