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

## Section 232 semiconductor tariffs (Note 39 / 9903.79) — 2026-04-20

Flagged Apr 20, 2026: ETR shows **zero change** at 2026-01-16 (2026_rev_1 semiconductor tariff boundary). 9903.79 is parsed into ch99_data (rate=25%) but never reaches any product — no footnote on any HTS10 references 9903.79 because Note 39 scopes "semiconductor articles" in legal text rather than per-product footnotes. `snapshot_2026_rev_1.rds` has 0 of 4.74M rows with rate_other > 0; daily ETR is identical to the last digit across the rev_1 boundary (14.4333%).

The existing note in `docs/revision_changelog.md:21` — "handled through the normal Chapter 99 parsing path and do not require a separate override layer" — is wrong. The rate lands in ch99_data, but nothing links it to products. Same structural issue as Section 232 auto parts (required `resources/s232_auto_parts.txt` against US Note 33(g)).

### Note 39 legal scope (from `data/us_notes/chapter99_2026_rev_1.pdf` pp. 533–535)

- **Subdivision (b) product scope**: HTS headings **8471.50, 8471.80, 8473.30** (three headings only), AND a per-article technical gate requiring "logic integrated circuit" meeting TPP/DRAM bandwidth thresholds that target advanced AI accelerators (H100-class GPUs). Scope cannot be expressed purely in HTS codes — needs a `qualifying_share` blending parameter.
- **Subdivision (a) rate**: heading 9903.79.01 = 25% on "semiconductor articles of all countries" (country_type = `all`, parser currently emits `unknown`).
- **Subheadings 9903.79.02–09 end-use carve-outs**: USMCA (.02, via subdivision (c)), U.S. data centers >100 MW (.03), repairs/replacement (.04), R&D (.05), startups/emerging-growth-co's (.06), non-data-center consumer electronics (.07), non-data-center civil industrial (.08), U.S. public sector (.09). These are end-use, not HTS-scoped — need a separate `end_use_exemption_share` blending parameter.
- **Stacking exclusions in Note 39(a)**: semi articles are NOT subject to 9903.94.xx autos/auto parts, 9903.74.xx MHD/MHD parts, 9903.78.01 copper, 9903.85.02/.12 aluminum, or aluminum derivatives. Subchapter IV ch99 additional duties (IEEPA country-EOs) DO stack. IEEPA 9903.01.77 (Brazil) and 9903.01.84 (India) explicitly exempt semi articles per Note 2(v)(xv) and (v)(xiii). Universal IEEPA (9903.01.25) interaction still needs PDF verification.

### Landed (2026-04-21)

- [x] `resources/s232_semi_products.csv` (10 HTS10s under 8471.50 / 8471.80 / 8473.30) + `scripts/build_semi_products.R`
- [x] `resources/semi_qualifying_shares.csv` scaffold (all 1.0, uncalibrated upper bound)
- [x] `config/policy_params.yaml` `section_232_headings.semiconductors` entry (no USMCA carve-out per Note 39(a); `end_use_exemption_share` parameter)
- [x] `classify_authority()` routes `middle == 79` to `section_232`
- [x] `extract_section232_rates()` extracts `semi_rate` from 9903.79.01
- [x] `06_calculate_rates.R` heading loop: gate + router + setdiff semi products out of non-semi heading lists (auto_parts 8471 overlap)
- [x] `06_calculate_rates.R` per-HTS10 `qualifying_share` × `(1 - end_use_exemption_share)` scaling
- [x] `06_calculate_rates.R` post-stacking override: restores semi heading rate after derivatives + annex (handles 8473.30.20/.51 alum-derivative overlap, rev_5+ post-annex zeroing)
- [x] 10 new tests in `tests/test_rate_calculation.R` (60/60 passing): classify_authority, extract_section232_rates, 7 integration fixtures covering Note 39(a)(7)-(9), Note 2(v)(xvi), MX/CA fent exclusion, China 60% stack
- [x] `docs/revision_changelog.md` corrected (no longer claims "normal Ch99 parsing")
- [x] `docs/assumptions.md` new §16 documenting `qualifying_share` and `end_use_exemption_share` uncalibrated-upper-bound defaults
- [x] **Aggregate ETR impact measured: +0.57pp at Jan 15→16** (14.433% → 15.003% weighted). Uncalibrated upper bound — realistic ~0.05-0.20pp after Phase 5 calibration.

### Deferred (Phase 5, calibration)

- [ ] **Calibrate `qualifying_share` per HTS10** — target Nvidia H200, AMD MI325X class accelerators only meet Note 39(b) TPP/DRAM gate. Primary source: 8471.80.4000 (discrete GPU/AI cards); most other 8471/8473 HTS10s should calibrate to ~0. Source: CBP trade data or SIA/SEMI industry estimates.
- [ ] **Calibrate `end_use_exemption_share`** — fraction of qualifying imports routed through 9903.79.03–.09 carve-outs (data centers, R&D, startups, consumer, industrial, public sector). Probably 0.3–0.5 based on AI/datacenter capex share.
### Section 122 × semi stacking (investigated 2026-04-21, no fix needed)

Note 39(a)'s exclusion list doesn't cover 9903.03 (Section 122 Phase 3), so strictly per the legal text, s122 should stack on semi products. The tracker's `nonmetal_share = 0` mechanism for 232 products zeros s122 in stacking — conceptually wrong for semi, but the output is correct anyway because **all 8 semi HTS8 prefixes are already on `resources/s122_exempt_products.csv`** (1,656 HTS8 codes from the ITA exempt list). Verified: `rate_s122 = 0` across all 2,400 semi pairs in both rev_4 and rev_5 snapshots.

Net: tracker gives the right answer (0 s122 on semi) for two independent reasons. If a future policy change removed semi products from the s122 exempt list, the stacking mechanism would still zero s122 — which would then be a bug. Defer unless that happens.

### Effective date note

Legal effective date is **Jan 15, 2026 (12:01 am EST)** per the Jan 14 proclamation. `config/revision_dates.csv` has `2026_rev_1 = 2026-01-16` (HTS JSON publication date). Pre-existing tracker convention — same as Budget Lab Yale's Tariff-ETRs historical config. Not fixed here; would be a separate revision_dates cleanup.

## USMCA scenario and share-loading (2026-04-20)

Investigation of `usmca_2024` / `usmca_monthly` alternatives and their behavior in the post-SCOTUS / post-annex regime. Fix applied for the monthly scenario; two follow-ups remain.

### Findings

- **`usmca_monthly` was frozen at Dec 2025 for every 2026 revision.** `SCENARIO_SPECS` in `src/build_usmca_scenarios.R` hardcoded `year = 2025L`, and the monthly branch of `load_usmca_product_shares()` clamped `month_num = 12` whenever `effective_date > 2025-12-31`. `resources/usmca_product_shares_2026_01.csv` existed but was never loaded. In `output/alternative/daily_overall_usmca_monthly.csv` the post-Jan-2026 line tracked `usmca_h2avg` within 0.01pp as a direct consequence.
- **`usmca_2024` alternative is firing correctly.** Direct snapshot comparison at `2026_rev_5` (2026-04-06): CA `total_rate` 13.27% (main) vs 14.44% (2024), MX 13.82% vs 14.30%. s122 is the dominant channel (CA 4.80% vs 6.37%; MX 5.55% vs 6.42%). The small ~0.5pp overall-ETR gap in figure 5 is the correct weighted combination given CA/MX import shares and the fact that fentanyl (the big USMCA lever historically) is zeroed post-2026-02-24.
- **Section 122 does receive USMCA reductions for CA/MX** (contra an earlier claim I made). s122 is a universal blanket applied to every non-exempt product-country pair; step 7 of `06_calculate_rates.R` does `rate_s122 = rate_s122 * (1 - usmca_share)`. Verified at `2026_rev_4`: CA mean s122 8.54% (statutory) → 4.80% (effective); MX 8.54% → 5.55%. With IEEPA reciprocal + fentanyl zeroed post-SCOTUS, s122 is now the single biggest place USMCA bites.
- **Annex override does not refresh `s232_usmca_eligible`.** Step 4 sets `s232_usmca_eligible` from pre-annex heading configs (`usmca_exempt:` flag). Step 5c's annex rate override reclassifies products into annex_1a/_1b/_2/_3 but does not touch `s232_usmca_eligible`. A product newly swept into annex_1b that was not in any pre-annex heading list keeps `s232_usmca_eligible = FALSE`, so step 7 will not reduce its rate_232 for CA/MX even if the product is S/S+ in the HTS special field. Potential gap vs ETRs in the post-April regime.

### Completed

- [x] Rewrote monthly branch of `load_usmca_product_shares()` (`src/data_loaders.R:240-267`) to derive target year/month from `effective_date` and walk backward one calendar month at a time until a file is found. Caps at 120 steps; falls through to annual if nothing matches. Verified across 11 test dates from 2024 through 2026-10.
- [x] Removed hardcoded `year = 2025L` from `usmca_monthly` scenario spec (`src/build_usmca_scenarios.R:42`) and from the legacy `--with-alternatives` block in `src/09_daily_series.R:1005-1013`.

### Open work

- [ ] **Rebuild `usmca_monthly` snapshots under the new logic.** `data/timeseries/usmca_monthly/` and `output/alternative/*usmca_monthly*` were produced under the old clamp. Run `Rscript src/build_usmca_scenarios.R --scenarios usmca_monthly` (or the full `--with-alternatives` pass) to regenerate. Expected: Jan–Apr 2025 line at ~40–45% utilization (close to `usmca_2024`), step-up mid-2025 to ~85%, then flat at the 2026-01 level for all of 2026 until new monthly files land.
- [ ] **Check annex-era `s232_usmca_eligible` coverage.** Diff the set of products with `s232_usmca_eligible = TRUE` against products classified as annex_1b with USMCA `special = S/S+` at `2026_rev_5`. If there are annex_1b products that should be eligible but are not, either (a) refresh the flag from `usmca` after the annex override in step 5c, or (b) add annex-level `usmca_exempt` config to `section_232_annexes.annexes.annex_1b` and apply it in step 5c alongside the rate override.
- [ ] **Refresh 2026 monthly USMCA files.** DataWeb API has returned HTTP 503 on 2026-04-20 and again on 2026-04-21 (4 attempts across both days). Outage is outside the documented Wed 5:30-8:30 PM ET maintenance window. Retry: `Rscript src/download_usmca_dataweb.R --year 2026 --monthly`. This replaces the "Update 2026 monthly USMCA shares" item in the Pipeline section below.

## Code review findings (2026-04-15)

Critical and structural issues identified via full-repo code review.

### Critical

- [x] **Silent row multiplication from unchecked left_join** (`06_calculate_rates.R`): ~15 `left_join` operations on `rates` with no before/after row-count assertions. A duplicate key in any join table silently multiplies rows, producing incorrect rates. Add `relationship = 'many-to-one'` or post-join nrow checks.
- [x] **rowwise() on large expansion** (`06_calculate_rates.R:122-128`): `check_country_applies()` called row-by-row via `rowwise() %>% mutate()` on potentially millions of rows. Should be vectorized.

### Structural

- [x] **Module-level side effects** (`06_calculate_rates.R:43-61`): policy params loaded at source time into globals; tryCatch swallows config errors. Globals only serve `calculate_rates_fast()` and `check_country_applies()`. Fix: pass `ISO_TO_CENSUS` and `CTY_CHINA` as parameters, remove module-level globals, fail loudly at call time. ~20 line change.
- [x] **No integration tests for extract_* functions**: `extract_ieepa_rates()`, `extract_section232_rates()`, `extract_section122_rates()`, `extract_ieepa_fentanyl_rates()`, `extract_usmca_eligibility()` all have zero unit test coverage. These parse raw HTS JSON at the system boundary. Highest-value test: fixture-based assertions on a known revision's JSON.
- [x] **`helpers.R` is a 1,950-line junk drawer**: 46 functions across 12+ categories. Split into `policy_params.R`, `stacking.R`, `rate_schema.R`, `data_loaders.R`, `revisions.R`. helpers.R sources them for backward compatibility.
- [ ] **`calculate_rates_for_revision()` is 1,500+ lines** (`06_calculate_rates.R`): 19 numbered steps, clearly commented. Cross-step variable dependencies (auto_products, mhd_products, heading_gates flow from step 4 into steps 4b/4c/5/7) make extraction produce worse code than inline. Correctness risks already addressed (relationship guards, nonmetal dedup, tests). **Deferred — revisit if function grows past 2,000 lines or a step needs independent testing.**

### Minor

- [x] **Unreachable guard after stop()** (`06_calculate_rates.R`): redundant `if (file.exists(...))` after `stop()` on `!file.exists(...)`. Removed dead branch.

### Completed

- [x] Fix Annex III over-broad HTS prefixes for 3 headings (fee2769, closes #5) (2026-04-15)
- [x] Extract `compute_nonmetal_share()` to deduplicate stacking logic (f83f1b6) (2026-04-15)
- [x] Add `relationship = 'many-to-one'` to 21 lookup joins in `06_calculate_rates.R` (2026-04-15)
- [x] Replace `rowwise()` expansion with pre-computed applicability mapping in `calculate_rates_fast()` (2026-04-15)
- [x] Remove module-level side effects from `06_calculate_rates.R` — pass constants as parameters (2026-04-15)
- [x] Add `tests/test_rate_calculation.R`: 50 fixture-based tests for extract_*, invariants, stacking, parsing, schema (2026-04-15)
- [x] Wire `test_rate_calculation.R` into CI (2026-04-15)
- [x] Split `helpers.R` into 5 focused modules + architecture doc + CONTRIBUTING update (2026-04-15)

## Pipeline

- [ ] Generic pharma country-specific exemption shares (per TPC feedback; low priority)
  - Planning note: `docs/analysis/generic_pharma_exemption_share_plan_2026-03-24.md`
- [ ] USMCA 2026 monthly refresh — see "USMCA scenario and share-loading (2026-04-20)" above.

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
