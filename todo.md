# Tracker Logic TODO

## 1. Empty revisions can collapse to zero rows

### Issue

In [src/06_calculate_rates.R](/C:/Users/ji252/Documents/GitHub/tariff-rate-tracker/src/06_calculate_rates.R), `calculate_rates_for_revision()` returns immediately when the initial footnote-based pass is empty. That happens before the blanket-authority logic for IEEPA, Section 232, Section 301, Section 122, and post-IEEPA grid expansion runs.

### Why it matters

A footnote parse miss, or a revision that relies mainly on blanket authorities, can produce a fully empty revision even though the repo has enough information to build most of the rates.

### Proposed solution

- Remove the early return on `nrow(rates) == 0`.
- Initialize `rates` as an empty schema-conforming tibble instead.
- Let the blanket-authority steps populate rows even when the footnote seed is empty.
- At the end of the function, decide explicitly whether a truly empty revision means:
  - no tariffed pairs, or
  - a zero-duty base grid should be emitted.

### Files to update

- [src/06_calculate_rates.R](/C:/Users/ji252/Documents/GitHub/tariff-rate-tracker/src/06_calculate_rates.R)
- possibly [src/helpers.R](/C:/Users/ji252/Documents/GitHub/tariff-rate-tracker/src/helpers.R) for a small helper like `empty_rates_schema()`

### Tests to add

- A revision fixture with no footnote-linked pairs but active blanket Section 122 or IEEPA
- A revision fixture with no active authorities at all

---

## 2. ~~Country-specific auto deals can become a global auto tariff~~ (DONE 2026-03-13)

Status:
- [src/05_parse_policy_params.R](/C:/Users/ji252/Documents/GitHub/tariff-rate-tracker/src/05_parse_policy_params.R): `extract_section232_rates()` now sets `auto_rate = 0` when only country-specific deal entries exist (no blanket `all`/`all_except` row). Returns `auto_has_deals` flag so the heading gate can still open for deal application.
- [src/06_calculate_rates.R](/C:/Users/ji252/Documents/GitHub/tariff-rate-tracker/src/06_calculate_rates.R): heading gates for `autos_passenger`/`autos_light_trucks` now check `auto_rate > 0 || auto_has_deals`. Non-deal countries get `auto_rate = 0` from the per-country lookup; deal countries are overridden later by the deal application loop.
- Test 15 in [tests/run_tests_daily_series.R](/C:/Users/ji252/Documents/GitHub/tariff-rate-tracker/tests/run_tests_daily_series.R) covers deal-only vs blanket ch99 data and confirms non-deal countries stay at zero.

Clarification:
- The `default_rate: 0.25` in `policy_params.yaml` is still used as the heading-level rate via `cfg$default_rate %||% s232_rates$auto_rate`. With `auto_rate = 0`, the config default always wins. This is correct: the config records the legal blanket rate even when the parser can't extract it from `9903.94.01`.
- The fix prevents a future deal-only revision from incorrectly applying a global 25% auto tariff to non-deal countries.

---

## 3. ~~Country applicability is fail-open~~ (DONE 2026-03-13)

Status:
- [src/03_parse_chapter99.R](/C:/Users/ji252/Documents/GitHub/tariff-rate-tracker/src/03_parse_chapter99.R) now defaults unmatched country descriptions to `'unknown'`, not `'all'`.
- [src/06_calculate_rates.R](/C:/Users/ji252/Documents/GitHub/tariff-rate-tracker/src/06_calculate_rates.R) now makes `check_country_applies()` return `FALSE` for `'unknown'` and `NA` country_type values.
- [src/quality_report.R](/C:/Users/ji252/Documents/GitHub/tariff-rate-tracker/src/quality_report.R) now flags unknown-country rows.
- Test 12 in [tests/run_tests_daily_series.R](/C:/Users/ji252/Documents/GitHub/tariff-rate-tracker/tests/run_tests_daily_series.R) covers all `country_type` branches.

Clarification:
- The fail-open bug itself is fixed.
- If standalone parser diagnostics or alternative artifacts still show `'unknown'` country rows, that should now be interpreted as parser debt to monitor, not as a silent over-application bug.
- Any statement about "zero impact on current outputs" should be tied to the current tested build data specifically, because it can otherwise conflict with raw parser diagnostics that still surface unknown rows.

---

## 4. ~~Section 301 scope is inconsistent across stacking and decomposition~~ (DONE 2026-03-13)

Fixed: removed `rate_301` from non-China branches in `apply_stacking_rules()` so stacking matches the decomposition (which already zeroed `net_301` outside China). Quality report now flags any non-China `rate_301 > 0`. Test 13 covers stacking exclusion, China inclusion, decomposition reconciliation, and a data integrity check.

**Future work:** If non-China Section 301 tariffs emerge (e.g., EU aircraft dispute revival, or new Section 301 investigations targeting other countries), they should use a dedicated authority column (e.g., `rate_301_other`) rather than reusing `rate_301`, which is hardcoded to China scope in both stacking and decomposition. This would require updates to `RATE_SCHEMA`, `apply_stacking_rules()`, `compute_net_authority_contributions()`, and the quality report.

---

## 5. ~~Unweighted daily means use a sparse denominator~~ (DONE 2026-03-13)

Status:
- [src/09_daily_series.R](/C:/Users/ji252/Documents/GitHub/tariff-rate-tracker/src/09_daily_series.R) now produces both `*_exposed` (sparse panel) and `*_all_pairs` (full Cartesian) means for overall and by-country aggregates.
- `mean_additional_all_pairs` and `mean_total_all_pairs` use `n_products * n_countries` as the denominator (overall) or `n_products_total` (by-country). Missing pairs contribute zero.
- Reporting default is `*_all_pairs`.
- [docs/methodology.md](/C:/Users/ji252/Documents/GitHub/tariff-rate-tracker/docs/methodology.md) documents both denominators.
- Test 14 in [tests/run_tests_daily_series.R](/C:/Users/ji252/Documents/GitHub/tariff-rate-tracker/tests/run_tests_daily_series.R) covers sparse vs complete panels and by-country denominator logic.

---

## 6. ~~Revision-date API automation can fail silently~~ (DONE 2026-03-13)

Status:
- Replaced `year(effective_date)` with `as.integer(format(effective_date, '%Y'))` — no lubridate dependency needed.
- Narrowed `tryCatch` to network/HTTP errors only; code/config errors now propagate with real stack traces instead of masquerading as "API unavailable."

---

## 7. ~~Chapter 99 PDF change detection clears its own alert and mutates shared cache~~ (DONE 2026-03-13)

Status:
- Probe download now goes to `tempdir()`, never touches `data/us_notes/chapter99.pdf`.
- When a change is detected, a pending marker (`.chapter99_pending`) is written instead of advancing the stored hash. The alert persists across runs until acknowledged with `--accept-pdf-hash`.
- Download is validated with PDF magic-byte signature check (`%PDF`) plus minimum size threshold. Bad downloads are discarded, not cached.

---

## 8. ~~Placeholder publication dates can enter the canonical revision schedule without a hard guard~~ (DONE 2026-03-13)

Status:
- New revisions get `needs_review = TRUE` column in `revision_dates.csv`.
- `load_revision_dates()` in `helpers.R` now halts with a clear error listing all unreviewed rows if any `needs_review = TRUE` entries exist.
- The build cannot proceed until the user sets the correct `effective_date` and clears the flag.

---

## 9. ~~Setup and build docs are stale relative to the new automation~~ (DONE 2026-03-13)

Status:
- `preflight.R` and `install_dependencies.R`: replaced `rvest` with `digest` in optional packages.
- `docs/methodology.md`: added "Revision discovery and dating" section describing the API-assisted workflow, publication-vs-policy date distinction, and PDF change detection.
- No `docs/build.md` exists in the repo — methodology.md is the canonical build/operational doc.

---

## Suggested order

1. ~~Fix the `year()` dependency bug in revision-date automation.~~ (DONE)
2. ~~Add a hard build/preflight guard for placeholder publication dates.~~ (DONE)
3. ~~Rework Chapter 99 PDF change detection so it does not clear its own alert or overwrite the shared parser cache.~~ (DONE)
4. ~~Update setup/build docs and optional package checks to match the new automation.~~ (DONE)
5. ~~Fix fail-open country applicability.~~ (DONE)
6. ~~Remove the empty-revision early return.~~ (DONE)
7. ~~Harmonize Section 301 scope across stacking and decomposition.~~ (DONE)
8. ~~Fix country-specific auto deals versus blanket auto rates.~~ (DONE)
9. ~~Redefine and document the unweighted daily mean denominator.~~ (DONE)
10. If non-China 301 tariffs emerge, add a dedicated authority column (see item 4 notes).
