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

## 2. Country-specific auto deals can become a global auto tariff

**Priority: Medium-Low (latent logic risk; partially masked in current revisions)**

### Issue

In [src/05_parse_policy_params.R](/C:/Users/ji252/Documents/GitHub/tariff-rate-tracker/src/05_parse_policy_params.R), `extract_section232_rates()` falls back to `max(s232_auto$rate)` when there is no blanket auto row and only country-specific deal rows exist. That value is then reused downstream as if it were the default auto tariff.

### Investigation findings (2026-03-13)

The fallback appears to trigger broadly because the blanket auto entry `9903.94.01` does not provide a parseable numeric rate through the raw Chapter 99 parser path used by the live build.

Important clarification:
1. The production build parses Chapter 99 directly inside [src/00_build_timeseries.R](/C:/Users/ji252/Documents/GitHub/tariff-rate-tracker/src/00_build_timeseries.R); it does **not** depend on `data/processed/chapter99_rates.rds` as a rescue path.
2. `config/policy_params.yaml` defines `default_rate: 0.25` for `autos_passenger` and `autos_light_trucks`.
3. In [src/06_calculate_rates.R](/C:/Users/ji252/Documents/GitHub/tariff-rate-tracker/src/06_calculate_rates.R), the rate assignment uses `cfg$default_rate %||% s232_rates$auto_rate`, so the config default takes precedence over the parsed fallback.

That means the current repo is somewhat protected from the bad parsed `auto_rate`, but **not fully**:
- the same heading config still applies a blanket 25% default once the auto gate is active,
- and the gate itself is currently driven by `s232_rates$auto_rate > 0`.

So if a future revision contains only country-specific auto deal rows and no true blanket auto row, the repo could still over-apply a global 25% auto tariff even with the config defaults left in place.

Conclusion:
- this is likely not driving a large error in the current tracked revisions,
- but it remains a real logic defect, not just harmless cleanup.

### Proposed solution

- Split auto logic into `auto_blanket_rate` (from true blanket entry, default 0) and `auto_deal_rates` (country-specific overrides).
- Update heading gate to check for deal rows OR blanket rate.
- Treat the config default as a reporting/config convenience, not as evidence of blanket legal coverage.
- Keep this below the highest-priority bugs, but do not mark it resolved.

### Files to update

- [src/05_parse_policy_params.R](/C:/Users/ji252/Documents/GitHub/tariff-rate-tracker/src/05_parse_policy_params.R)
- [src/06_calculate_rates.R](/C:/Users/ji252/Documents/GitHub/tariff-rate-tracker/src/06_calculate_rates.R)

### Tests to add

- A fixture where the auto block contains only country-specific deal entries and no blanket auto row
- A regression test that confirms non-deal countries stay at zero auto 232 in that case

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

## Suggested order

1. ~~Fix fail-open country applicability.~~ (DONE)
2. ~~Remove the empty-revision early return.~~ (DONE)
3. ~~Harmonize Section 301 scope across stacking and decomposition.~~ (DONE)
4. Fix country-specific auto deals versus blanket auto rates. (medium-low priority, still a real logic defect)
5. ~~Redefine and document the unweighted daily mean denominator.~~ (DONE)
6. If non-China 301 tariffs emerge, add a dedicated authority column (see item 4 notes).
