# Tariff Rate Tracker — TODO

## Active priorities (updated 2026-04-23)

1. **Sync published rev_5 artifacts with current code**: rebuild `2026_rev_5`, `rate_timeseries.rds`, and `metadata.rds` so the saved release outputs reflect the landed Russia fix and `tests/test_rate_calculation.R` stops failing against stale artifacts.
2. **Close the live USMCA annex gap**: check annex-era `s232_usmca_eligible` coverage, then refresh 2026 monthly USMCA files once DataWeb stops returning HTTP 503, and rebuild `usmca_monthly` snapshots from the refreshed monthly inputs.
3. **Replace static annex scaffolding with dynamic parsing**: move `load_annex_products()` / `extract_section232_rates()` off the static CSV path so annex classifications track future HTS revisions automatically.
4. **Finish the biggest post-annex modeling gaps**: Russia clause (8), UK 95% qualifying-content treatment, Annex IV exception buckets, and product-condition exemptions are still approximated or unmodeled.
5. **Then clear secondary rebuild/calibration debt**: rerun the OOM-failed post-build alternatives, calibrate semi/annex assumptions, and tackle the remaining low-priority performance and cleanup items.

## Section 232 annex restructuring (April 2026 proclamation)

Presidential proclamation of 2 April 2026 replaces single-rate 232 with four product annexes (effective 2026-04-06). See `docs/s232/s232_metals_update_note.pdf` (SGEPT analysis).

### Annex transition result

- Pre-annex ETR: 11.12% (Apr 5, rev_4)
- Post-annex ETR: 11.79% (Apr 6, rev_5)
- Change: **+0.67pp** (vs SGEPT -0.53pp)
- The +1.2pp gap vs SGEPT is a known BEA vs calibrated-flat metal content divergence: our BEA shares produce low pre-annex effective rates for derivatives, making the move to 25% full-value a net increase. SGEPT's higher flat shares (steel 40%, aluminum 35%) make the pre-annex rates higher, so 25% is more often a reduction for them.

### Open work

Recommended order here: rebuild release artifacts, confirm the Russia sync in saved outputs, replace the static Ch99 path, then finish the remaining post-annex modeling/documentation items.

- [ ] **Russia rev_5 release sync:** the source fix has landed (`section_232_annexes.country_surcharges` plus the post-annex `pmax()` path in step 5c), and a fresh `calculate_rates_for_revision()` run now restores the 200% rate for `country == '4621'` on Annex I-A/I-B/III aluminum and aluminum derivatives. But the checked-in `snapshot_2026_rev_5.rds` and `rate_timeseries.rds` still predate that fix, so `tests/test_rate_calculation.R` fails against the saved rev_5 artifact.
- [ ] **Russia clause (8) is still only partially modeled.** The April 2, 2026 proclamation covers Annex I-A/I-B/III aluminum articles or derivatives that are the product of Russia **or** where any primary aluminum was smelted in Russia **or** the article was cast in Russia. Current logic only keys on exporter country (`country == '4621'`). See `docs/s232/russia_rev5_fix_plan.md`.
- [ ] **Document (or assign) `deriv_type` in annex-era revisions.** In rev_5 all rows have `deriv_type = NA` and per-type shares = 0 because `apply_232_derivatives()` gates on pre-annex Ch99 codes (9903.81.89-93, 9903.85.04/07/08, 9903.78.01) that are absent from the rev_5 HTS. This is correct-by-policy (full-value taxation replaces metal-content scaling) but arrived at accidentally through a failing gate. Either add a comment documenting the intent, or have step 5c assign a sentinel value (e.g., `deriv_type = 'annex_1a'`) so downstream readers can distinguish "no derivative classification" from "annex-era full-value regime." See `docs/s232/rev5_baseline_review.md` §§4-5.
- [ ] **Rebuild release artifacts from HEAD.** Re-run `2026_rev_5`, then recombine `rate_timeseries.rds` and `metadata.rds`, so published outputs match the current tree and the new Russia snapshot tests pass on saved artifacts.
- [ ] **Dynamic Ch99 parsing** in `load_annex_products()` / `extract_section232_rates()` — currently using static CSV
- [ ] **Modeling gap: conditioned post-annex branches**
  - UK reduced rates with 95% qualifying-content condition
  - Annex IV exception buckets / conditioned 10% and 0% paths
  - `9903.81.92` and other product-condition exemptions that don't fit the current country/product binary framework

### Lower priority

- [ ] UK content share blending (`uk_content_qualifying_share`, default 30% per SGEPT)
- [ ] Exemption calibration (US-origin 1%, de minimis 2%, motorcycle 0.1% per SGEPT)
- [ ] Annex III sunset (Dec 2027 → I-B rate): logic in place, needs future HTS revision to test
- [ ] **Calibrate `auto_parts_subdivision_r` shares** — landed as dormant config knobs (all default 0). When set, step 5d in `06_calculate_rates.R` applies a three-way mix per Note 33(r): `rate_232 = fta × 0 + (1-fta) × [cert × floor + (1-cert) × annex_1b]`. The FTA exemption follows lines 35836-35837 (KORUS / EO 14345 imports exempt from 9903.94.44/.45/.54/.55/.64/.65 additional duty AND from 9903.82.x metals annex via the (r)(1) carve-out). Resource list is 8 prefixes (87060030, 87089210/.50/.60/.75, 87089315/.30, 87089981) at rev_6; rebuild via `scripts/build_subdivision_r_products.R` after annex updates.
  - **DataWeb does not provide direct chapter-99 granularity** (investigated 2026-05-02 via `src/download_subdivision_r_share.R`). `rateProvisionCodes` is a 2-digit aggregate, not 9903.xx-line specific.
  - **Upper-bound signals from DataWeb 2025**: `fta_exempt_shares.KR` ≤ 0.86 (SPI=KR utilization on subdiv-r ch87, $577M/$672M); `fta_exempt_shares.JP` ≈ 0 (US-Japan deal is not auto-scoped); `fta_exempt_shares.EU` = 0 structurally (no EU FTA in scope). `certified_share` (within the non-FTA slice) is undifferentiated.
  - Calibration source for certified_share: CBP entry-summary line counts (likely FOIA), industry estimates from MEMA / Auto Care Association / SAFE, or sensitivity-range defaults (e.g., set 0.5 with ±0.25 alternatives). See `tariff_tracker_investigated_issues.md`.
  - **Side gap still open:** the FTA-exempt branch only fires inside the subdiv-r blend. If a KORUS-qualifying KR import does NOT also claim subdivision (r) certification, the tracker still applies 25% annex_1b. Open question: should the FTA exemption apply to the 9903.82.x metals annex independent of subdivision (r) certification? Needs its own scoping pass.

### Ruled out (investigated 2026-04-22)

- [x] **Annex_2 × rate_232 = 0.25 is not a leak**: 480 rows at 25% in rev_5 snapshot, all semi products. Intentional per semi post-stacking override at `src/06_calculate_rates.R:2275-2298` (Note 39(a) — semi articles aren't re-scoped by the April 2026 annex restructuring). Zero non-semi annex_2 rows carry non-zero rates.
- [x] **IEEPA zeroing in rev_4+ is not a regression**: `rate_ieepa_recip = rate_ieepa_fent = 0` for all rev_4/rev_5 rows is the intended effect of `ieepa_invalidation_date: '2026-02-24'` (SCOTUS *Learning Resources v. Trump*). Section 122 replaces the blanket within the 150-day window.

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

Priority order within this section: check annex-era `s232_usmca_eligible` first, refresh the 2026 monthly files once DataWeb is available, then rebuild `usmca_monthly` outputs from the refreshed monthly inputs.

### Findings

- **`usmca_monthly` was frozen at Dec 2025 for every 2026 revision.** `SCENARIO_SPECS` in `src/build_usmca_scenarios.R` hardcoded `year = 2025L`, and the monthly branch of `load_usmca_product_shares()` clamped `month_num = 12` whenever `effective_date > 2025-12-31`. `resources/usmca_product_shares_2026_01.csv` existed but was never loaded. In `output/alternative/daily_overall_usmca_monthly.csv` the post-Jan-2026 line tracked `usmca_h2avg` within 0.01pp as a direct consequence.
- **`usmca_2024` alternative is firing correctly.** Direct snapshot comparison at `2026_rev_5` (2026-04-06): CA `total_rate` 13.27% (main) vs 14.44% (2024), MX 13.82% vs 14.30%. s122 is the dominant channel (CA 4.80% vs 6.37%; MX 5.55% vs 6.42%). The small ~0.5pp overall-ETR gap in figure 5 is the correct weighted combination given CA/MX import shares and the fact that fentanyl (the big USMCA lever historically) is zeroed post-2026-02-24.
- **Section 122 does receive USMCA reductions for CA/MX** (contra an earlier claim I made). s122 is a universal blanket applied to every non-exempt product-country pair; step 7 of `06_calculate_rates.R` does `rate_s122 = rate_s122 * (1 - usmca_share)`. Verified at `2026_rev_4`: CA mean s122 8.54% (statutory) → 4.80% (effective); MX 8.54% → 5.55%. With IEEPA reciprocal + fentanyl zeroed post-SCOTUS, s122 is now the single biggest place USMCA bites.
- **Annex override does not refresh `s232_usmca_eligible`.** Step 4 sets `s232_usmca_eligible` from pre-annex heading configs (`usmca_exempt:` flag). Step 5c's annex rate override reclassifies products into annex_1a/_1b/_2/_3 but does not touch `s232_usmca_eligible`. A product newly swept into annex_1b that was not in any pre-annex heading list keeps `s232_usmca_eligible = FALSE`, so step 7 will not reduce its rate_232 for CA/MX even if the product is S/S+ in the HTS special field. Potential gap vs ETRs in the post-April regime.

### Completed

- [x] Rewrote monthly branch of `load_usmca_product_shares()` (`src/data_loaders.R:240-267`) to derive target year/month from `effective_date` and walk backward one calendar month at a time until a file is found. Caps at 120 steps; falls through to annual if nothing matches. Verified across 11 test dates from 2024 through 2026-10.
- [x] Removed hardcoded `year = 2025L` from `usmca_monthly` scenario spec (`src/build_usmca_scenarios.R:42`) and from the legacy `--with-alternatives` block in `src/09_daily_series.R:1005-1013`.
- [x] Patched `src/download_usmca_dataweb.R` so current-year queries use a Year-to-Date date range (`timeframeSelectType = 'specificDateRange'`, Jan-through-current-month) instead of `fullYears`, matching DataWeb support guidance for incomplete years.

### Open work

- [ ] **Rebuild `usmca_monthly` snapshots under the new logic.** `data/timeseries/usmca_monthly/` and `output/alternative/*usmca_monthly*` were produced under the old clamp. Run `Rscript src/build_usmca_scenarios.R --scenarios usmca_monthly` (or the full `--with-alternatives` pass) to regenerate. Expected: Jan–Apr 2025 line at ~40–45% utilization (close to `usmca_2024`), step-up mid-2025 to ~85%, then flat at the latest available 2026 monthly file level. Per DataWeb support email on 2026-04-23, the latest published 2026 monthly data is February, so the refreshed 2026 line should freeze at the 2026-02 level until newer monthly files land.
- [ ] **Check annex-era `s232_usmca_eligible` coverage.** Diff the set of products with `s232_usmca_eligible = TRUE` against products classified as annex_1b with USMCA `special = S/S+` at `2026_rev_5`. If there are annex_1b products that should be eligible but are not, either (a) refresh the flag from `usmca` after the annex override in step 5c, or (b) add annex-level `usmca_exempt` config to `section_232_annexes.annexes.annex_1b` and apply it in step 5c alongside the rate override.
- [ ] **Refresh 2026 monthly USMCA files.** DataWeb support (Hugh, 2026-04-23) says current-year queries should use **Year-to-Date** rather than **Annual**, because full-year annual data does not populate for an incomplete year; he also confirmed that the latest available 2026 monthly data is **February**, so April 2026 should return no results until that data is published. That downloader fix is now in place, but both a current-month retry and a February-capped retry (`--end-date 02/2026`) still returned **HTTP 503** on **2026-04-23** at the first chapter batch. Retry once DataWeb is available: `Rscript src/download_usmca_dataweb.R --year 2026 --monthly`. Expected post-refresh state: `resources/usmca_product_shares_2026_01.csv` and `resources/usmca_product_shares_2026_02.csv` present, with the monthly scenario freezing at February 2026 until newer files land.

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

## Code review follow-ups (2026-04-22)

Second critical-code-reviewer pass over the Section 232 pipeline. Three commits
landed: `42c0cab` (blocking + required-changes), `0338405` (Phase C hardening).

### Blocking fixes

- [x] **Fentanyl stacking docstring/code divergence** (`src/stacking.R`): docstring claimed non-China fentanyl passes through at full rate on 232 products; code scales by `nonmetal_share`. Verified against Tariff-ETRs `calculations.R:1571-1575` — code is correct, docstring + misleading "copper exception" comment updated. Memory note corrected.
- [x] **Silent fail-open on `us_auto_content_share`** (`src/06_calculate_rates.R` step 4b, `src/generate_etrs_config.R`): missing config key previously defaulted to `1.0` (full USMCA exemption — ~4.7pp CA/MX auto over-exemption). Now fail closed with actionable error.
- [x] **Hardcoded UK `'4120'` for country overrides** (`src/05_parse_policy_params.R`): 9903.81.94-99 and 9903.85.12-15 previously attributed every entry to UK. New `extract_country_specific_overrides()` helper uses `parse_countries()` + ISO→Census map with EU expansion; warns on unparseable entries.

### Required changes

- [x] **`heading_gates` fail closed**: unregistered heading names now `stop()` with list of orphans rather than silently activating on every revision.
- [x] **`section_232_headings` required**: NULL block now errors rather than silently skipping non-chapter 232 programs.
- [x] **`message('WARNING: ...')` → `warning()`**: three sites (products_file, prefixes_file, semi qualifying_shares_file) — missing resources now surface in CI.
- [x] **`max_rate_with_variance_log()` helper** (parser): 8 `max(rate)` call sites log rate divergence if a ch99 range ever introduces a different rate instead of silently picking max.
- [x] **`match_232_heading_products()` helper** (`src/06_calculate_rates.R`): extracted the ~40-line prefix-matching logic duplicated in step 4 (rate assignment) and step 5 (derivative-overlap exclusion).
- [x] **`load_232_derivative_products()` cached**: loaded once per build and passed into both `apply_232_derivatives()` and the step 5c annex fallback.
- [x] **`aluminum_derivative_{rate,exempt}`**: renamed for symmetry with `steel_derivative_{rate,exempt}` (parser return, 06_calculate_rates.R consumer, test fixture).
- [x] **`vehicle_prefixes` fragile fallback** (step 4c auto deals): vehicle/parts split now sourced from `heading_product_lists` — stable if `autos_passenger`/`autos_light_trucks` ever migrate from inline `prefixes:` to `products_file:`.
- [x] **Auto-deal classification fail-loud** (`src/05_parse_policy_params.R`): parts regex extended (`auto parts`, `light trucks` variants); unclassifiable entries warn + drop rather than silently bucketing as `auto_vehicles`.

### Repo housekeeping

- [x] Repo metadata: `CITATION.cff`, `DATA_SOURCES.md`, `SECURITY.md` (`c4a4985`).
- [x] S232 reference PDFs + `annexes_text.txt` retained in `docs/s232/`; saved-page HTM bundle removed (`5bf88c3`).
- [x] `scripts/validate_derivative_classification.R` + `scripts/verify_scenario_differences.R` committed as durable validation tooling.
- [x] `.gitignore` additions: `test_output/`, `resources/USITC - USMCA - *.xlsx`, `resources/*_diagnostic.csv`.
- [x] Deleted 4 one-off migration scripts (`patch_and_test.R`, `scripts/diff_step1_refactor.R`, `scripts/verify_step2_dense.R`, `scripts/diagnose_tpc_match_shift.R`).

### Suggestion-tier follow-ups (deferred; low priority)

- [ ] O(N·M) annex prefix-matching at `src/06_calculate_rates.R:1797` — precompute into a hash for 10-15× speedup on large-annex revisions.
- [ ] Verify `load_metal_content()` isn't re-reading the BEA CSV per build.
- [ ] `statutory_rate_232` overloaded semantics — rewritten at 4 pipeline points (pre/post deal, post-annex, post-floor-recompute); consider renaming or explicit per-stage snapshots.

## Pipeline

Recommended order here: finish the USMCA refresh path, then rerun the OOM-failed post-build alternatives, and leave generic pharma shares for later.

- [ ] Generic pharma country-specific exemption shares (per TPC feedback; low priority)
  - Planning note: `docs/analysis/generic_pharma_exemption_share_plan_2026-03-24.md`
- [ ] USMCA 2026 monthly refresh — see "USMCA scenario and share-loading (2026-04-20)" above.
- [ ] **Rerun 6 OOM-failed post-build alternatives (2026-04-22).** Full rebuild via `--full --with-alternatives` completed the main timeseries (58.5 min) and the 6 rebuild alternatives (usmca_annual/monthly/2024/dec2025, metal_flat, dutyfree_nonzero) successfully, but the 6 post-build scenarios `no_ieepa`, `no_ieepa_recip`, `no_301`, `no_232`, `no_s122`, `pre_2025` all failed with `cannot allocate vector of size 705.6 Mb` on `filter(revision == 'rev_X')` — R ran out of memory after accumulating state across the ~5-hour run. The corresponding `output/alternative/*_{no_*,pre_2025}.csv` files are stale (dated Apr 15-20, pre-dating the semi tariff work). Rerun option: a fresh R process per scenario. Either restart the machine and re-run `--full --with-alternatives`, or run each failed scenario in its own Rscript invocation (prototype: `apply_scenario(ts, name, scenarios_path) |> build_daily_aggregates(...) |> save_alternative_output(...)`). Each should take a few minutes with fresh memory.

## More-granular preference share construction (2026-04-28)

Two share-refinement items surfaced by the eval `tracker_over_report.md` and `tracker_miss_report.md` Round 3. Both are about replacing or augmenting current preference-utilization inputs with finer, IMDB-empirical signals. Neither is a rate-parsing bug; they're calibration / new-channel work.

- [ ] **Refresh DataWeb USMCA monthly shares against IMDB-realized claim shares.** `tracker_over_report.md` Action 5: ~$43.3 B of LEGIT-channel over-statement on USMCA-claimed CA/MX entries indicates the tracker's monthly DataWeb shares are systematically lower than realized claim shares for some HS10×country pairs. Drill-down by HS6×country×month comparing `resources/usmca_product_shares_*.csv` to IMDB-derived (count or value of `cty_subco = 'S'/'S+'` divided by all entries in the same HS10×country×month) will identify which pairs need refresh. Same calibration pattern as the §232 semi `qualifying_share` interim fix. Eval-side handoff is the natural place to compute the IMDB-side aggregate; tracker-side change would be ingesting the refreshed shares.
- [ ] **Expose a statutory-vs-claimable rate split for the Annex II claim-rate channel.** `tracker_miss_report.md` Round 3 concluded the bulk of the $5–7 B Pattern 1 residual is importer non-claim of 9903.01.32 (eligible-but-unclaimed Annex II exemptions). Adding this as a behavioral channel parallel to USMCA shares requires the tracker to expose, per (HS10, country, revision), both (a) the statutory rate assuming 100% Annex II claim and (b) the rate if no Annex II is claimed. The diff is the upper-bound of the non-claim channel; the eval side then ingests an IMDB-derived claim share (count or value of `9903.01.32` filings vs. `9903.01.25/.43–.75/02.xx` filings by HS6×country×month) and decomposes via that share. The `ieepa_exempt_scope: 'baseline_only'` diagnostic toggle (committed 2026-04-28) already produces the no-claim rate; making this a first-class output requires emitting both rate columns side-by-side rather than rebuilding twice.

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
