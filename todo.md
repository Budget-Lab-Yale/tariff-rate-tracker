# Tariff Rate Tracker — TODO

## Active priorities (verified 2026-04-08)

1. Finish post-`2026_rev_4` Section 232 annex integration: next HTS revision/date plumbing, dynamic Ch99 parsing, annex-aware ETR export, and April 6 transition validation.
2. Keep deferred modeling/calibration items (`9903.81.92`, UK-content blending, annex exemptions, generic pharma shares, concordance tightening, small-country outliers) behind the correctness work above.

## Section 232 / BEA metal derivatives

Five issues confirmed via code review on 2026-04-06 (see `docs/analysis/section_232_review_memo_2026-04-06.md`).

- [x] BEA copper scaling zeros out valid heading rates — FIXED (2026-04-06)
  - `load_metal_content()` now populates per-type shares for all BEA-matched products, not just derivatives
  - copper heading products (ch74) get `copper_share` from BEA regardless of derivative status
- [x] Authority decomposition misses `deriv_type` for steel derivatives — FIXED (2026-04-06)
  - `compute_net_authority_contributions()` now has `deriv_type` branches matching `apply_stacking_rules()`
- [ ] Steel-derivative US-melted exemption (`9903.81.92`) not modeled — DEFERRED
  - requires product-condition exemption support; TODO comment added at `05_parse_policy_params.R:690`
- [x] Exported ETR configs miss `steel_derivatives` metal metadata — FIXED (2026-04-06)
  - added `steel_derivatives = 'steel'` to `metal_type_map` in `generate_etrs_config.R`
- [x] Flat/CBO alternative pipeline for 232 heading/derivative overlaps — FIXED (2026-04-06)
  - heading-overlap per-type column reset now gated on `has_per_type` in `06_calculate_rates.R`

## Section 232 annex restructuring (April 2026 proclamation)

Presidential proclamation of 2 April 2026 replaces single-rate 232 with four product annexes (effective 2026-04-06). See `docs/s232/s232_metals_update_note.pdf` (SGEPT analysis).

**Scaffolding complete (2026-04-06):**
- [x] Config: `section_232_annexes` block in `policy_params.yaml` (rates, UK deal, floor, sunset, exemptions)
- [x] Resource: `resources/s232_annex_products.csv` populated from proclamation annex lists
- [x] Helper: `load_annex_products()` in `helpers.R`
- [x] Rate logic: step 5c annex override + step 6e Annex III floor recomputation in `06_calculate_rates.R`
- [x] Tests: 5 unit tests (annex rates, floor formula, UK deal, date gating, empty resource)

**Active follow-up (blocked on revisions after `2026_rev_4` and export parity):**
- [x] Fix prefix-matching order: sort longest-first so specific annex classifications (e.g., `85030045` → annex 2) are not shadowed by shorter catchalls (`850300` → annex 1b) — FIXED (2026-04-09)
- [ ] Add the next HTS revision(s) to `config/revision_dates.csv` once post-`2026_rev_4` JSON is available
- [ ] Dynamic Ch99 parsing in `load_annex_products()` / `extract_section232_rates()`
- [ ] Integration test: full rebuild + verify ~0.5pp ETR drop at April 6 transition
- [ ] ETR export: annex-aware program classification in `generate_etrs_config.R`

**Lower priority:**
- [ ] UK content share blending (`uk_content_qualifying_share`, default 30% per SGEPT)
- [ ] Exemption calibration (US-origin 1%, de minimis 2%, motorcycle 0.1% per SGEPT)
- [ ] Annex III sunset (Dec 2027 → I-B rate): logic in place, needs future HTS revision to test

## NA propagation in daily output (basic–rev_3)

- [x] Verified resolved in checked-in code and artifacts (2026-04-08)
  - `load_metal_content()` now returns zero-filled per-type columns on the no-derivative early-return path
  - `output/daily/daily_overall.csv` and `output/daily/daily_by_authority.csv` contain no blank values for `basic` through `rev_3`
  - keep this note only as context for the related flat-method bug below

## Flat metal-content alternative: NA propagation zeroes derivative 232 rates

- [x] Fixed and rebuilt (2026-04-08)
  - `load_metal_content()` now returns stable zero-filled per-type columns for all paths
  - `apply_232_derivatives()` only uses per-type scaling in BEA mode; flat/CBO methods stay on aggregate `metal_share`
  - `apply_stacking_rules()` and `compute_net_authority_contributions()` now use per-type logic only when shares are informative (`> 0`)
  - added regression tests for no-derivative zero-filled shares, mixed flat snapshots, and flat-100 derivative scaling/stacking
  - rebuilt `output/alternative/daily_overall_metal_flat_100.csv`: `weighted_etr` on 2025-12-31 is now 18.92% vs baseline 14.29% (`+4.64pp`), matching the expected direction

**Original issue (for context):** The `metal_flat_100` alternative (flat_share=1.0) lowered the overall ETR by ~0.40pp vs baseline at 2025-12-31 (13.89% vs 14.29%). This was the **wrong direction** — flat 100% should raise rates on derivatives (full 50% 232, no IEEPA on nonmetal) but instead effectively zeroed their 232 contribution.

**Root cause:** `load_metal_content()` with `method='flat'` sets only `metal_share` for derivatives (line 1607). It does NOT populate per-type columns (`steel_share`, `aluminum_share`, `copper_share`). However, the primary-chapters force at lines 1712–1717 creates these columns via partial assignment:

```r
result$steel_share[is_primary] <- 0      # creates column: 0 for ch72/73/76, NA everywhere else
result$aluminum_share[is_primary] <- 0   # same
result$copper_share[is_primary] <- 0     # same
```

Since the columns now exist, `has_per_type = TRUE` in both `apply_232_derivatives()` (line 370) and `apply_stacking_rules()` (line 893), routing through the per-type code paths designed for BEA data — but with NAs.

**Propagation (two affected product classes):**

1. **Aluminum/steel derivatives** (e.g., HTS 8407 engine from EU):
   - Per-type scaling: `case_when(deriv_type == 'aluminum' ~ aluminum_share)` → NA
   - `if_else(deriv & NA < 1.0, rate_232 * NA, rate_232)` → rate_232 = NA
   - Stacking: `rate_232 > 0` → NA → treated as FALSE → falls to no-232 branch
   - **Result:** derivative loses 232 entirely, gets only IEEPA (15% vs BEA's 16.5%)

2. **Copper heading products** (e.g., HTS 7403 refined copper from Chile):
   - Stacking: `is_copper_heading ~ copper_share` → NA → active_type_share = 0
   - nonmetal_share = 0 (vs BEA's 1 − copper_share ≈ 0.15)
   - **Result:** loses IEEPA on nonmetal portion (50.0% vs BEA's 51.5%)

**Expected behavior (flat 100%):** Derivatives should get full statutory 232 rate (50%), nonmetal_share = 0, total = 232 + fent only. This would RAISE the overall ETR above baseline.

**Implemented fix path:** stable per-type schema plus smarter routing. Flat/CBO methods now keep zero-filled share columns without entering BEA-only per-type scaling/stacking, while BEA revisions still use the richer per-type logic.

**Related:** This is a sibling of the "NA propagation in daily output (basic–rev_3)" bug above — same mechanism (partial per-type columns), different trigger (flat method vs missing derivatives).

**Note:** `output/alternative/daily_overall_metal_flat_100.csv` was rebuilt on 2026-04-08 after the helper/scaling/stacking fixes.

## Validation / test debt

- [x] Policy-date propagation fixtures updated to current intended timing split (2026-04-08)
  - `2026_rev_4` remains HTS-dated at 2026-02-24
  - IEEPA invalidation still shifts to the SCOTUS ruling date (2026-02-20) in policy-date mode
  - Section 122 remains aligned to HTS/CBP implementation (2026-02-24)
  - `Rscript tests/run_tests_daily_series.R`: 67 passed, 0 failed

## Pipeline

- [ ] Add generic pharma country-specific exemption shares (per TPC feedback; low priority)
  - planning note: `docs/analysis/generic_pharma_exemption_share_plan_2026-03-24.md`

## Low priority

- **Concordance builder**: Matching may overstate splits/merges. Tighten with reciprocal-best or capped matching if needed.
- **Small-country outliers**: Persistent large gaps on low-import countries (Azerbaijan -26pp, Bahrain -22pp, UAE -8pp, Georgia +14pp, New Caledonia +22pp). Not material to aggregates.

---

## Resolved

<details>
<summary>Pipeline rebuild (completed 2026-03-25)</summary>

- [x] Full rebuild with copper + MHD fixes — 2026-03-24
- [x] Regenerate blog figures — 2026-03-24
- [x] Re-run `compare_etrs.R` after rebuild — 2026-03-25
  - 301 List 4B suspension fix: calculator now filters `[provision suspended.]` entries
  - post-fix gaps: `+1.51pp` (2026-01-01), `+0.71pp` (2026-02-24), `+0.74pp` (2026-07-24)
- [x] Fix alternative series: pass `policy_params` through — FIXED (1d34148, 2026-04-02)

</details>

<details>
<summary>HTS status (completed 2026-03-24)</summary>

- [x] `config/revision_dates.csv` cleaned: policy overrides only for rev_16 and 2026_rev_4
- [x] Built artifacts reflect cleaned schedule (no tied-date intervals)
- [x] Repo-vs-USITC archive reconciliation documented (`docs/analysis/hts_archive_reconciliation_2026-03-24.md`)

</details>

<details>
<summary>China gap investigation — RESOLVED (9c4c316, 2026-03-25)</summary>

Root cause: 301 List 4B (9903.88.16) suspended since rev_4 but calculator treated as active. Fix: `grepl('provision suspended', description)` filter. Gap decomposition in `src/diagnose_china_gap.R`.

</details>

<details>
<summary>rev_16 232 rate investigation</summary>

9903.81.87 exists in earlier revisions at 25% (matching old fallback), so rate doesn't change at rev_16. 50% rate appears in later HTS JSON. Low priority — correct by rev_32.

</details>

<details>
<summary>Public release code review (completed 2026-04-02)</summary>

- [x] Stop logging DataWeb token previews
- [x] Make `--refresh-usmca` fail loudly on child script failure
- [x] Split heavy daily-series regression checks from smoke-test path
- [x] Scrub absolute filesystem links from tracked docs
- [x] Remove `needs_review` parser warning from revision-date loader

</details>

<details>
<summary>Full repo review — Section 232 / alternatives / USMCA (completed 2026-04-02)</summary>

- [x] Fix H2 USMCA baseline aggregation (value-weighted shares) — 2026-04-02
- [x] Fix heading exclusion over-match in `apply_232_derivatives()` — 2026-04-02
- [x] Section 232 derivative temporal accuracy — already implemented
- [x] Section 232 derivative scraper (`--derivatives`) — 2026-04-02
- [x] Policy-date default inconsistent — FIXED (f2bdfc3)
- [x] Residual `.pp` global leak in derivatives — FIXED (72ba170)
- [x] Flat/CBO stacking fallback — FIXED (72ba170)
- [x] `--use-hts-dates` propagation — FIXED + TESTED
- [x] Concordance/utility reordering — FIXED (1eb7200)
- [x] Docs inconsistency — FIXED (2026-03-24)
- [x] Tied policy dates — FIXED + REBUILT (f2bdfc3)
- [x] Point query defaults — FIXED (1eb7200)
- [x] Auto-incremental mode — FIXED (1eb7200)
- [x] Run-mode consistency tests — FIXED (2026-03-24)

</details>

<details>
<summary>Authority ETR decomposition gap — FIXED</summary>

Root cause: decomposition only included `total_additional`, not base rate. Fix: added `etr_base` residual column to `daily_by_authority.csv` for exact additivity.

</details>

<details>
<summary>Blog publication (completed 2026-03-25)</summary>

- [x] Regenerate docx from final `.md`
- [x] Regenerate blog figures after 301 List 4B fix

</details>
