# TODO

## High priority

- [x] Fix stacking so `rate_ieepa_fent` and `rate_s122` actually stack on top of `rate_232` where intended. The current logic in `src/helpers.R` says they should stack, but the implementation zeroes them out on full-metal 232 products. *(Fixed 2026-03-13: fentanyl now stacks in full; s122 correctly scaled by nonmetal_share)*
- [x] Fix incorrect country alias mappings in `src/05_parse_policy_params.R`. At minimum, correct Myanmar, Macau/Macao, and Cote d'Ivoire to the Census codes in `resources/census_codes.csv`, then re-run IEEPA extraction and rebuild affected snapshots. *(Fixed 2026-03-13: Myanmar→5460, Macau→5660, Cote d'Ivoire→7480)*
- [x] Fix the Section 232 light-truck gate mismatch between `config/policy_params.yaml` (`autos_light_trucks`) and `src/06_calculate_rates.R` (`autos_light`). Current committed snapshots show those light-truck prefixes getting 232 tariffs before the auto program starts. *(Fixed 2026-03-13: renamed gate key to autos_light_trucks)*

## Medium priority

- [x] Fix `build_daily_aggregates()` in `src/09_daily_series.R` so partial `date_range` requests do not crash when a revision interval falls completely outside the requested window. *(Fixed 2026-03-13: early-return guard before seq())*
- [x] Fix the `tpc_stacking` alternative in `src/09_daily_series.R`. The daily aggregation path currently recomputes totals with default mutual-exclusion logic, so additive stacking does not survive into the output. *(Fixed 2026-03-13: stacking_method threaded through build_daily_aggregates)*
- [x] Fix `src/run_comparisons.R` to honor `tpc_policy_revision` from `config/revision_dates.csv` when running TPC validation. The current runner always validates `rev_id` directly, even when the calendar specifies a different snapshot. *(Fixed 2026-03-13: now checks tpc_policy_revision column)*

## Tests to add

- [x] Add coverage for narrow `date_range` inputs in `tests/run_tests_daily_series.R`. *(Added 2026-03-13: Test 8)*
- [x] Add coverage for non-default stacking paths so additive inputs are not silently converted back to mutual exclusion. *(Added 2026-03-13: Test 9)*
- [x] Add coverage for country alias validity by checking that all hard-coded alias codes exist in `resources/census_codes.csv`. *(Added 2026-03-13: Test 10 — also caught 7 more bad codes)*
- [x] Add coverage for pre-policy Section 232 gating, especially the light-truck prefixes. *(Added 2026-03-13: Test 11)*

## Notes

- Existing `tests/run_tests_daily_series.R` passed during review, but it does not cover the failures above.
- The highest-risk findings were validated locally against the committed snapshots in `data/timeseries/`.
