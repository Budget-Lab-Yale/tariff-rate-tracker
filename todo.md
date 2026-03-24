# Tariff Rate Tracker — TODO

## Pipeline rebuild

- [x] Full rebuild with copper + MHD fixes — completed 2026-03-24
- [x] Regenerate blog figures — completed 2026-03-24
- [ ] Re-run `compare_etrs.R` after rebuild to confirm gap closure
- [ ] Add generic pharma country-specific exemption shares (per TPC feedback; low priority)

## Open investigations

### rev_16 shows -0.06pp 232 change (expected ~+1pp for 50% increase)

9903.81.87 exists in earlier revisions with a 25% rate (matching the old fallback), so the rate doesn't change at rev_16. The 50% rate may only appear in the HTS JSON at a later revision. Low priority — the rate is correctly 50% by rev_32.

## Code review follow-up

### ~~1. Policy-date default inconsistent~~ — FIXED (f2bdfc3)
`build_full_timeseries()` default changed to `use_policy_dates = TRUE`.

### 2. `--use-hts-dates` propagation — PARTIALLY FIXED (1eb7200)
`detect_incremental_start()` and post-build `load_policy_params()` now receive `use_policy_dates` from the CLI. However, the main rate calculator still relies on a top-level `.pp <- load_policy_params()` in `src/06_calculate_rates.R`, and `calculate_rates_for_revision()` is not yet parameterized on the selected date regime. That means `--use-hts-dates` is still not fully propagated through the actual rate-construction path.

Remaining fix:
- Thread `use_policy_dates` into `06_calculate_rates.R` explicitly, either by:
  - passing a policy params object into `calculate_rates_for_revision()`, or
  - reinitializing the date-sensitive config used by that module at build time.
- Add a targeted test that compares HTS-date mode vs default mode on `2026_rev_4` and confirms both the revision boundary and IEEPA/S122 timing move together.

Concrete implementation plan:
1. Replace the implicit module-global date config in `src/06_calculate_rates.R`.
   - Stop depending on the top-level `.pp <- load_policy_params()` for date-sensitive behavior.
   - Keep static helpers/constants if useful, but make the policy object used by the calculator explicit.

2. Add an explicit `policy_params` argument to `calculate_rates_for_revision()`.
   - Pass it from `src/00_build_timeseries.R`, using the same `load_policy_params(use_policy_dates = use_policy_dates)` object already created for the build.
   - Inside the calculator, use this passed object for:
     - `IEEPA_INVALIDATION_DATE`
     - `SECTION_122`
     - `FLOOR_RATE`
     - `MFN_EXEMPTION`
     - `S232_COUNTRY_EXEMPTIONS`
     - `SECTION_301_RATES`
     - any other date-sensitive or policy-sensitive lookups now reading from `.pp`

3. Remove or isolate fallback behavior.
   - If a fallback is still needed when `calculate_rates_for_revision()` is sourced interactively, make it an explicit `policy_params %||% load_policy_params()` inside the function.
   - Avoid hidden top-level state that is initialized before the CLI date mode is known.

4. Audit helper calls inside `src/06_calculate_rates.R`.
   - Replace any internal `load_policy_params()` calls with the passed `policy_params`.
   - In particular, remove the local reload around the IEEPA/floor-country block so one revision cannot mix two date regimes.

5. Keep the downstream date regime aligned.
   - Confirm that all post-build consumers (`run_daily_series()`, weighted ETR, quality report, comparison/export helpers when invoked from the build path) receive the same policy params object or the same `use_policy_dates` setting.

6. Add targeted regression tests.
   - Test A: build/compute under default policy-date mode for `2026_rev_4`; verify IEEPA is invalidated and Section 122 is active on `2026-02-20`.
   - Test B: build/compute under `--use-hts-dates`; verify `2026_rev_4` still uses HTS timing on `2026-02-20` and only switches on `2026-02-24`.
   - Test C: compare point queries / daily outputs across the two modes on `2026-02-20` and `2026-02-24` to ensure the whole path moves together.

7. Rebuild and validate artifacts.
   - Run a fresh build in default mode after the patch.
   - Optionally run a small HTS-date-mode build or spot-check fixture to confirm the alternate path is real.
   - Re-check `compare_etrs.R` and any timing-sensitive diagnostics after the rebuild.

Suggested code edits:
- `src/00_build_timeseries.R`
  - extend the `calculate_rates_for_revision(...)` call to pass `policy_params = pp_build` (or similarly named object loaded once with `use_policy_dates = use_policy_dates`)
  - keep one canonical build-time policy object and reuse it for interval construction plus downstream post-build steps
- `src/06_calculate_rates.R`
  - change `calculate_rates_for_revision(...)` signature to accept `policy_params = NULL`
  - inside the function, define a local `pp <- policy_params %||% load_policy_params()`
  - replace references to module-global `.pp` with the local `pp` anywhere behavior depends on dates or selected policy mode
  - remove the internal `pp <- load_policy_params()` reload in the IEEPA / floor-country block and use the same local `pp`
  - leave truly static constants only if they are not mode-sensitive; otherwise derive them from `pp` inside the function
- `src/helpers.R`
  - if helpful, add a small helper for "default policy params for current mode" only if it reduces repeated boilerplate; avoid reintroducing hidden global state
- `tests/`
  - add a new test file or extend the existing suite with explicit policy-date vs HTS-date assertions for `2026_rev_4`
  - add a fixture-level check that the calculator, point query, and daily aggregation all move together when the mode changes

### ~~3. Concordance/utility reordering~~ — FIXED (1eb7200)
HTS-order utilities (`build_hts_concordance.R`, `02_download_hts.R`, `01_scrape_revision_dates.R`, `scrape_us_notes.R`, `revision_changelog.R`) explicitly pass `use_policy_dates = FALSE`.

### 4. Docs inconsistency — PARTIALLY FIXED (f2bdfc3)
`policy_timing.md` now correctly documents the HTS-late-only override approach in its later sections, but the opening paragraphs still say the tracker uses HTS revision dates by default and suggest manual swapping as the main mechanism. The document is directionally much better, but not yet internally consistent end-to-end.

Remaining fix:
- Rewrite the opening section of `docs/policy_timing.md` so it matches the current implementation:
  - default = legal policy dates only for HTS-late revisions;
  - opt-out = `--use-hts-dates`;
  - early HTS revisions are intentionally not shifted because they create timeline collisions.

### 5. Tied policy dates — CODE FIXED, REBUILD STILL NEEDED (f2bdfc3)
`policy_effective_date` is now restricted to HTS-late revisions only (`rev_16`, `2026_rev_4`), so the source schedule no longer creates the earlier tied-date collisions.

Important note:
- The current built artifacts in `data/timeseries/` still contain stale invalid intervals from the pre-fix schedule (for example `rev_6` / `rev_7` around April 2025).
- So this item is fixed in config/code, but not yet fully reflected in repo outputs until a fresh rebuild lands.

Remaining fix:
- Rebuild the timeseries and downstream outputs from the updated schedule.
- Re-check that no revision interval has `valid_until < valid_from`.

### ~~6. Point query defaults~~ — FIXED (1eb7200)
`get_rates_at_date()` now loads `load_policy_params()` when `policy_params = NULL`. Spot checks after Section 122 expiry now match between the default call and the explicit-policy-params call. This also fixes the default behavior of `export_for_etrs.R`.

### ~~7. Auto-incremental mode~~ — FIXED (1eb7200)
`detect_incremental_start()` accepts and forwards `use_policy_dates`.

### 8. Run-mode consistency tests

Not yet implemented. Add a dedicated test file exercising main execution paths (snapshots vs point queries vs daily exports, policy-date vs HTS-date mode). Good engineering practice but not blocking publication.

## Blog publication (`blog_april2/`)

- [ ] Regenerate docx from final `.md` before publication

## Low priority

- **Concordance builder**: Matching may overstate splits/merges. Tighten with reciprocal-best or capped matching if needed.
- **Small-country outliers**: Persistent large gaps on low-import countries (Azerbaijan -26pp, Bahrain -22pp, UAE -8pp, Georgia +14pp, New Caledonia +22pp). Not material to aggregates.
