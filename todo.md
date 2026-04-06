# Tariff Rate Tracker — TODO

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
- [x] Resource: `resources/s232_annex_products.csv` (header-only, pending HTS JSON)
- [x] Helper: `load_annex_products()` in `helpers.R`
- [x] Rate logic: step 5c annex override + step 6e Annex III floor recomputation in `06_calculate_rates.R`
- [x] Tests: 5 unit tests (annex rates, floor formula, UK deal, date gating, empty resource)

**Blocked on HTS JSON (2026_rev_5):**
- [ ] Populate `resources/s232_annex_products.csv` from new Ch99 codes
- [ ] Dynamic Ch99 parsing in `load_annex_products()` / `extract_section232_rates()`
- [ ] Integration test: full rebuild + verify ~0.5pp ETR drop at April 6 transition
- [ ] ETR export: annex-aware program classification in `generate_etrs_config.R`

**Lower priority:**
- [ ] UK content share blending (`uk_content_qualifying_share`, default 30% per SGEPT)
- [ ] Exemption calibration (US-origin 1%, de minimis 2%, motorcycle 0.1% per SGEPT)
- [ ] Annex III sunset (Dec 2027 → I-B rate): logic in place, needs future HTS revision to test

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
