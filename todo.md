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

### ~~2. `--use-hts-dates` not propagated end-to-end~~ — FIXED (1eb7200)
Post-build `load_policy_params()` and `detect_incremental_start()` now receive `use_policy_dates` from CLI.

### ~~3. Concordance/utility reordering~~ — FIXED (1eb7200)
HTS-order utilities (`build_hts_concordance.R`, `02_download_hts.R`, `01_scrape_revision_dates.R`, `scrape_us_notes.R`, `revision_changelog.R`) explicitly pass `use_policy_dates = FALSE`.

### ~~4. Docs inconsistency~~ — FIXED (f2bdfc3)
`policy_timing.md` rewritten to document HTS-late-only approach.

### ~~5. Tied policy dates~~ — RESOLVED (f2bdfc3)
Restricted `policy_effective_date` to HTS-late revisions only (rev_16, 2026_rev_4). No more collisions.

### ~~6. Point query defaults~~ — FIXED (1eb7200)
`get_rates_at_date()` now loads `load_policy_params()` when `policy_params = NULL`.

### ~~7. Auto-incremental mode~~ — FIXED (1eb7200)
`detect_incremental_start()` accepts and forwards `use_policy_dates`.

### 8. Run-mode consistency tests

Not yet implemented. Add a dedicated test file exercising main execution paths (snapshots vs point queries vs daily exports, policy-date vs HTS-date mode). Good engineering practice but not blocking publication.

## Blog publication (`blog_april2/`)

- [ ] Regenerate docx from final `.md` before publication

## Low priority

- **Concordance builder**: Matching may overstate splits/merges. Tighten with reciprocal-best or capped matching if needed.
- **Small-country outliers**: Persistent large gaps on low-import countries (Azerbaijan -26pp, Bahrain -22pp, UAE -8pp, Georgia +14pp, New Caledonia +22pp). Not material to aggregates.
