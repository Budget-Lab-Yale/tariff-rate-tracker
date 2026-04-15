# Tariff Rate Tracker — TODO

## Active priorities (updated 2026-04-14)

1. **Dynamic Ch99 parsing**: replace static annex CSV with parsed Ch99 entries so annex classifications track future HTS revisions automatically.
2. **Modeling gaps**: conditioned post-annex branches (UK 95% content, Annex IV exception buckets, product-condition exemptions) are approximated, not modeled.
3. **Deferred calibration**: UK content share blending, annex exemptions, generic pharma shares, concordance tightening, small-country outliers.

## Section 232 annex restructuring (April 2026 proclamation)

Presidential proclamation of 2 April 2026 replaces single-rate 232 with four product annexes (effective 2026-04-06). See `docs/s232/s232_metals_update_note.pdf` (SGEPT analysis).

### Annex transition result

- Pre-annex ETR: 11.12% (Apr 5, rev_4)
- Post-annex ETR: 11.79% (Apr 6, rev_5)
- Change: **+0.67pp** (vs SGEPT -0.53pp)
- The +1.2pp gap vs SGEPT is a known BEA vs calibrated-flat metal content divergence: our BEA shares produce low pre-annex effective rates for derivatives, making the move to 25% full-value a net increase. SGEPT's higher flat shares (steel 40%, aluminum 35%) make the pre-annex rates higher, so 25% is more often a reduction for them.

### Open work

- [ ] **Dynamic Ch99 parsing** in `load_annex_products()` / `extract_section232_rates()` — currently using static CSV
- [ ] **Modeling gap: conditioned post-annex branches**
  - UK reduced rates with 95% qualifying-content condition
  - Annex IV exception buckets / conditioned 10% and 0% paths
  - `9903.81.92` and other product-condition exemptions that don't fit the current country/product binary framework

### Lower priority

- [ ] UK content share blending (`uk_content_qualifying_share`, default 30% per SGEPT)
- [ ] Exemption calibration (US-origin 1%, de minimis 2%, motorcycle 0.1% per SGEPT)
- [ ] Annex III sunset (Dec 2027 → I-B rate): logic in place, needs future HTS revision to test

### Completed

- [x] Config, resource CSV, helper, rate logic, 5 unit tests — scaffolding (2026-04-06)
- [x] Prefix-matching order: longest-first (2026-04-09)
- [x] `2026_rev_5` added (effective 2026-04-06) (2026-04-13)
- [x] Full-value stacking fix: `nonmetal_share=0` for annex products (2026-04-13)
- [x] Double-`resources/` path fix + fail-closed guard + quality invariant (2026-04-13)
- [x] Primary chapter coverage: removed `rate_232 > 0` guard, derivative fallback to annex_1b (2026-04-14)
- [x] ETR export: annex-aware program classification in `generate_etrs_config.R` (2026-04-14)
- [x] Integration tests: config-driven path, fail-closed, primary chapter, export parity, quality invariant — 79 tests total (2026-04-14)

## Code review findings (2026-04-15)

Critical and structural issues identified via full-repo code review.

### Critical

- [x] **Silent row multiplication from unchecked left_join** (`06_calculate_rates.R`): ~15 `left_join` operations on `rates` with no before/after row-count assertions. A duplicate key in any join table silently multiplies rows, producing incorrect rates. Add `relationship = 'many-to-one'` or post-join nrow checks.
- [ ] **rowwise() on large expansion** (`06_calculate_rates.R:122-128`): `check_country_applies()` called row-by-row via `rowwise() %>% mutate()` on potentially millions of rows. Should be vectorized.

### Structural

- [ ] **`calculate_rates_for_revision()` is 1,500+ lines** (`06_calculate_rates.R:463-1979`): 17 policy steps in one function, untestable in isolation. Break into composable step functions.
- [ ] **`helpers.R` is a 1,950-line junk drawer**: 20+ unrelated responsibilities. Split into focused modules (rate_schema.R, policy_params.R, stacking.R, concordance.R, etc.).
- [ ] **Module-level side effects** (`06_calculate_rates.R:43-61`): policy params loaded at source time into globals; tryCatch swallows config errors. `calculate_rates_for_revision()` then shadows these with local copies.
- [ ] **No integration tests for rate calculation engine**: `run_tests_daily_series.R` tests downstream consumers but nothing tests `calculate_rates_for_revision()` itself.

### Minor

- [ ] **Unreachable guard after stop()** (`06_calculate_rates.R:1613-1617`): redundant `if (file.exists(...))` after `stop()` on `!file.exists(...)`.
- [ ] **`load_usmca_product_shares()` 150-line mode switch** (`helpers.R:1339-1503`): 5 modes in nested if/else; each should be a separate helper.
- [ ] **`.gitignore` excludes test files by pattern** (`.gitignore:36`): `test_*.R` glob may exclude `tests/test_tpc_comparison.R` from version control.
- [ ] **`get_country_constants()` hardcoded fallbacks** (`helpers.R:412-446`): ~50 hardcoded codes that go stale if YAML changes; tryCatch hides the real failure.
- [ ] **CI runs only smoke tests** (`ci.yml`): no rate-calculation regression test.

### Completed

- [x] Fix Annex III over-broad HTS prefixes for 3 headings (fee2769, closes #5) (2026-04-15)
- [x] Extract `compute_nonmetal_share()` to deduplicate stacking logic (f83f1b6) (2026-04-15)
- [x] Add `relationship = 'many-to-one'` to 21 lookup joins in `06_calculate_rates.R` (2026-04-15)

## Pipeline

- [ ] Generic pharma country-specific exemption shares (per TPC feedback; low priority)
  - Planning note: `docs/analysis/generic_pharma_exemption_share_plan_2026-03-24.md`

## Low priority

- **Concordance builder**: matching may overstate splits/merges. Tighten with reciprocal-best or capped matching if needed.
- **Small-country outliers**: persistent large gaps on low-import countries (Azerbaijan -26pp, Bahrain -22pp, UAE -8pp, Georgia +14pp, New Caledonia +22pp). Not material to aggregates.

---

## Resolved

<details>
<summary>BEA metal derivatives review (2026-04-06)</summary>

Five issues confirmed via code review (see `docs/analysis/section_232_review_memo_2026-04-06.md`):
- [x] BEA copper scaling zeros out valid heading rates
- [x] Authority decomposition misses `deriv_type` for steel derivatives
- [x] Exported ETR configs miss `steel_derivatives` metal metadata
- [x] Flat/CBO pipeline for 232 heading/derivative overlaps
- [ ] Steel-derivative US-melted exemption (`9903.81.92`) — DEFERRED (requires product-condition exemption support)

</details>

<details>
<summary>NA propagation bugs (2026-04-08)</summary>

- [x] Daily output NA for basic–rev_3
- [x] Flat metal-content alternative zeroed derivative 232 rates

</details>

<details>
<summary>Earlier resolved items (2026-03 / 2026-04)</summary>

- [x] Pipeline rebuild with copper + MHD fixes (2026-03-25)
- [x] 301 List 4B suspension fix (2026-03-25)
- [x] Full repo review: USMCA, derivatives, policy dates, stacking (2026-04-02)
- [x] Public release code review (2026-04-02)
- [x] Policy-date propagation fixtures (2026-04-08)
- [x] OOM fix: per-revision streaming for rebuild alternatives (2026-04-13)

</details>
