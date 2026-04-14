# Tariff Rate Tracker — TODO

## Active priorities (updated 2026-04-14)

1. **P0 annex correctness**: fix primary-chapter coverage gap, verify annex path fix, re-run transition comparison.
2. **ETR export parity**: make `generate_etrs_config.R` annex-aware so post-`2026-04-06` products use annex program buckets.
3. **Deferred modeling/calibration**: `9903.81.92`, UK 95% qualifying content, Annex IV exception buckets, generic pharma shares, concordance tightening, small-country outliers.

## Section 232 annex restructuring (April 2026 proclamation)

Presidential proclamation of 2 April 2026 replaces single-rate 232 with four product annexes (effective 2026-04-06). See `docs/s232/s232_metals_update_note.pdf` (SGEPT analysis).

### P0 bugs

- [ ] **Primary chapter products (ch72/73/76) lose 232 coverage post-annex**
  - 801 products in primary chapters lose `rate_232` at rev_4→rev_5 (-0.624pp ETR impact)
  - Root cause: old product-specific Ch99 entries (9903.80/81) removed in rev_5; Ch99 parser no longer assigns `rate_232`. The annex I-A inference at `06_calculate_rates.R:1514-1518` is gated on `rate_232 > 0`, so it skips these products.
  - **Not a policy change** — ch72/73/76 are unambiguously Annex I-A at 50%.
  - Also affects 49 derivative products in s232_derivative_products.csv not in the annex CSV — should be annex I-B.
  - **Fix**: Remove `rate_232 > 0` guard from primary chapter inference. Add fallback for unmatched derivatives.
  - **ETR impact**: should recover ~0.56pp, bringing transition to ~-0.04pp (closer to SGEPT's -0.53pp).
  - [ ] Remove `rate_232 > 0` guard from primary chapter annex inference
  - [ ] Add fallback: unmatched s232_derivative_products get `annex_1b` if not already classified
  - [ ] Add test: ch72 product with rate_232=0 still gets annex_1a post-annex
  - [ ] Re-run annex transition comparison after fix

- [x] **`s232_annex` entirely NA due to double-`resources/` path** — FIXED (2026-04-13, pending commit)
  - `policy_params.yaml` stores `resource_file: 'resources/s232_annex_products.csv'` but code wrapped it in `here('resources', ...)`, producing `resources/resources/...`
  - Fix: path resolution now uses config value directly; fail-closed `stop()` on empty annex map; quality report invariant added.

### Completed

- [x] Config, resource CSV, helper, rate logic, 5 unit tests — scaffolding (2026-04-06)
- [x] Prefix-matching order: longest-first (2026-04-09)
- [x] `2026_rev_5` added (effective 2026-04-06) — (2026-04-13)
- [x] Full-value stacking fix: `nonmetal_share=0` for annex products (2026-04-13)
- [x] Integration tests: config-driven path, fail-closed, quality invariant, export parity (2026-04-13)

### Open work

- [ ] **Test gap**: annex unit tests don't exercise the production config-driven path through `calculate_rates_for_revision()`. Add regression test for config resource resolution.
- [ ] **ETR export**: annex-aware program classification in `generate_etrs_config.R` (code written, pending annex coverage fix to validate)
- [ ] **Dynamic Ch99 parsing** in `load_annex_products()` / `extract_section232_rates()`
- [ ] **Modeling gap: conditioned post-annex branches**
  - UK reduced rates with 95% qualifying-content condition
  - Annex IV exception buckets / conditioned 10% and 0% paths
  - `9903.81.92` and other product-condition exemptions

### Lower priority

- [ ] UK content share blending (`uk_content_qualifying_share`, default 30% per SGEPT)
- [ ] Exemption calibration (US-origin 1%, de minimis 2%, motorcycle 0.1% per SGEPT)
- [ ] Annex III sunset (Dec 2027 → I-B rate): logic in place, needs future HTS revision to test

## Section 232 / BEA metal derivatives

- [ ] Steel-derivative US-melted exemption (`9903.81.92`) — DEFERRED
  - Requires product-condition exemption support; TODO at `05_parse_policy_params.R:690`

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

</details>

<details>
<summary>NA propagation bugs (2026-04-08)</summary>

- [x] Daily output NA for basic–rev_3: `load_metal_content()` early-return path now zero-fills per-type columns
- [x] Flat metal-content alternative zeroed derivative 232 rates: stable per-type schema + smarter routing for flat/CBO methods. Root cause: partial per-type column assignment created NAs that propagated through BEA-only code paths.

</details>

<details>
<summary>Pipeline rebuild (2026-03-25)</summary>

- [x] Full rebuild with copper + MHD fixes
- [x] 301 List 4B suspension fix
- [x] Fix alternative series: pass `policy_params` through

</details>

<details>
<summary>Full repo review — Section 232 / alternatives / USMCA (2026-04-02)</summary>

- [x] H2 USMCA aggregation, heading exclusion, derivative scraper, policy-date defaults, .pp global leak, flat/CBO fallback, --use-hts-dates, concordance, tied dates, auto-incremental, run-mode tests

</details>

<details>
<summary>Other resolved items</summary>

- [x] HTS archive reconciliation (2026-03-24)
- [x] China gap / 301 List 4B suspension (2026-03-25)
- [x] Authority ETR decomposition gap
- [x] Blog publication (2026-03-25)
- [x] Public release code review (2026-04-02)
- [x] Policy-date propagation fixtures (2026-04-08)
- [x] rev_16 232 rate investigation (correct by rev_32)

</details>
