# Restructure Plan — de-sprawl `src/` and `scripts/`

**Goal:** Make the tracker easy to *run* and *understand* for an external audience
(formal modelers), without changing any computed numbers. Cleanup-and-reorganize,
not a rewrite.

**Branch:** `restructure-codebase` (from `master`).

---

## Status at a glance

| Phase | What | State |
|-------|------|-------|
| 0  | Pre-presentation minimum (docs + archiving + banners) | ☑ **DONE** — commit `b1dfdf0` |
| 1e (part) | Complete `architecture.md` map | ☑ **DONE** — commit `d77ce2d` |
| 1a | Name the steps in the 2,800-line rate engine | ⏸ deferred (parity-gated) |
| 1b | Resolve the dual interval splitter | ⏸ deferred (parity-gated) |
| 1c | De-duplicate `09_daily_series.R` | ⏸ deferred (parity-gated) |
| 1d | `src/` folder layout + `tools/` | ⏸ deferred (path-touching + parity) |
| 1e (rest) | `docs/internal/`, dangling-ref cleanup | ⏸ deferred (zero-risk, not yet done) |

**Decision (2026-06-24):** stop after Phase 0 + the architecture map for the
presentation. The remaining Phase 1 items touch rate logic or `source()` paths
and must be validated byte-identical via the Slurm parity harness — to be done
*after* the talk. Local machine is RAM-capped (full build needs 32 GB + Slurm),
so parity can't be run here.

**Legend:** ☑ done · ⏸ deferred · ☐ todo

---

## Findings (the "why")

The rate engine is sound — no logic duplication, helpers defined once, a clean
`authority_spec → authority_adapter → calculator` abstraction, and a strong
parity-test discipline that makes refactors safe. The problem is **surface
area**, not correctness:

- `src/` held 48 files; ~13 were one-off investigations sourced by nobody,
  interleaved with the pipeline.
- `scripts/` was an 80-file flat dump; ~64 were resolved investigations or
  checked-in API payloads.
- The public README Quick Start contained a command that **hard-errors**
  (`--publish-internal`, removed; `00_build_timeseries.R:1005` stops on unknown
  flags), and referenced a deleted file (`src/08_weighted_etr.R`).
- Two live interval-splitting mechanisms with opposite day conventions
  (`timeline.R` minting on the build side; legacy `apply_expiry_zeroing` at 8
  sites in `09_daily_series.R`), reconciled by six test files.
- `calculate_rates_for_revision()` is a single ~2,800-line function
  (`06_calculate_rates.R:983`→EOF).

---

## Phase 0 — Pre-presentation minimum  ☑ DONE (commit `b1dfdf0`, pushed)

Doc fixes + archive dead one-offs + status banners. No change to any build
output; every moved `src/` file was verified sourced-by-nobody.

**Verification:** test suites green — daily-series 81, weights 16, annex 25;
rate-calc 102 pass + 3 pre-existing stale-snapshot failures (require a full
rebuild; unrelated to this change). Root-clutter housekeeping (`.Rhistory`,
`build.log`, `test_output/`, `check_revisions.R`, `test_two_revisions.R`) was
found already gitignored — no repo action needed.

- ☑ **0a. README + `docs/build.md`** — removed the `--publish-internal` bullet +
  commands (re-pointed internal publish at the array flow); removed the dead
  `src/08_weighted_etr.R` and `src/publish_internal.R` references.
- ☑ **0b. Archive dead `src/` one-offs** (see manifest) + delete untracked
  `src/_compare_alternatives.R` + trim the vestigial `compare_tpc`/`compare_etrs`
  readiness modes from `preflight.R`.
- ☑ **0c. Archive `scripts/` one-offs + API payloads** (see manifest).
- ☑ **0d. Status banners** — corrected `timeline.R` (PARTIALLY WIRED, not "NOT
  wired") and `resolved_programs.R` (PROTOTYPE, default-off).
  `load_adcvd_layer.R` already had an accurate scaffold banner.
- ☑ **0e. Verify + ship** — CI smoke tests run locally; committed + pushed;
  `data/timeseries_olddates/` gitignored (orphan build residue).

---

## Phase 1 — Structural (follow-up, parity-gated)

### 1a. Name the steps in the rate engine  ⏸
Extract the 17 numbered steps of `calculate_rates_for_revision()` into named
functions (`apply_section232_base()`, `apply_301()`, `apply_usmca_exemption()`,
…) called from a short driver. File may stay one file. Prove no-change via the
parity harness (`parity.R` + `scripts/submit_plank1_build_gate.sh`).

### 1b. Resolve the dual interval splitter  ⏸
Either wire `09_daily_series.R` onto the `timeline.R` boundary representation, or
formally bless one as canonical. Then collapse the redundant timeline/zeroing
equivalence tests. (Documented in `architecture.md` "Two in-progress migrations"
in the meantime.)

### 1c. De-duplicate `09_daily_series.R`  ⏸
Factor a `prepare_interval_data()` helper for the repeated
`filter → apply_expiry_zeroing → apply_stacking_rules` preamble across the three
`compute_agg_*` helpers and their `has_weights` twins.
**⚠ Gotcha (verified):** the preambles are *not* identical — `compute_agg_overall`
applies stacking conditionally (`if (any(c('rate_s122','rate_ieepa_recip') %in%
names))`) while `compute_agg_country`/`_authority` apply it unconditionally. A
naive shared helper would change behavior; the helper must preserve this. Parity
run required.

### 1d. Folder layout for `src/`  (path-touching; parity-gated)  ⏸
`src/{pipeline,model,io,core,experimental}/` per the target layout below; update
every `source(here('src', …))` path + test source paths. Relocate manual tools
(`scrape_us_notes`, `calibrate_s301_exclusions`, `build_hts_concordance`,
`expand_ieepa_exempt`, `revision_changelog`, `generate_etrs_config`,
`download_usmca_dataweb`, `build_usmca_scenarios`) to a `tools/` dir; update
README. Rerun parity.

### 1e. Docs + housekeeping
- ☑ Expand `architecture.md` to a complete one-line-per-file map (3-layer model)
  + the two in-progress-migration notes. **DONE (commit `d77ce2d`).**
- ⏸ Move internal process docs (`theseus_*`, `codex_*`, `*_plan.md`,
  `bugfix_decisions_*`, `phase6_*`) to `docs/internal/` so `docs/` shows only
  durable material. (Zero numeric risk — can be done anytime.)
- ⏸ Remove the dangling `apply_scenarios.R` references (deleted file; see Known
  issues).

---

## Known issues discovered (NOT yet addressed)

Found during the review; left for a follow-up because they are out of scope for
the presentation-readiness pass. None are regressions from this branch.

1. **Broken references inside *kept* plank scripts** (the parity harness):
   - `scripts/submit_plank3_parity.sh` invokes `submit_parity_summary.sh` and
     `submit_parity_task.sh` — **both missing** from `scripts/`.
   - `scripts/submit_plank1_units.sh`, `submit_plank2_tests.sh`,
     `submit_plank3_units.sh` invoke `tests/test_scenario_ops.R` — **missing**.
   These plank gates would fail if run as-is. Either restore the missing files
   or update the wrappers.
2. **Dangling `apply_scenarios.R`** (deleted file) still referenced by
   `src/rate_schema.R` (comment) and docs (`authority_spec.md`, `scenarios.md`,
   `phase6_embed_seed_plan.md`, `theseus_review_findings_detail.md`). Scenario
   application now lives in the config-overlay + `scenario_registry.R` path.
3. **No `src/scenario_ops.R`** — earlier notes/memory referred to a
   `scenario_ops.R` "verbs" module; it does not exist. The live mechanism is
   `scenario_registry.R` + `config/scenarios/<name>/overlay.yaml` deep-merge in
   `policy_params.R`.
4. **Stale `08_weighted_etr.R` mentions** remain in historical review docs
   (`docs/codex_review_assessment.md`, `docs/spec_driven_calculator_plan.md`,
   `docs/theseus_review_findings_detail.md`) — left as historical record; will
   be swept if those move to `docs/internal/`.

---

## Archive manifest (Phase 0 — for reversibility)

Everything below is recoverable via `git log --follow` or by moving it back.

**`src/` → `scripts/archive/`** (dead one-offs, sourced by nobody):
`compare_etrs.R`, `diagnose_china_gap.R`, `diagnostics.R`,
`download_subdivision_r_share.R`, `export_for_etrs.R`, `run_comparisons.R`

**Deleted** (untracked throwaway, referenced defunct `output/alternative/`):
`src/_compare_alternatives.R`

**`scripts/` → `scripts/archive/`** (30 resolved investigations):
`investigate_eu_auto_deal.R`, `diagnose_eu_auto_diff.R`, `summarize_eu_auto.R`,
`build_eu_auto_compare_xlsx.R`, `run_eu_auto_only.R`, `compare_prefix_postfix.R`,
`estimate_annex_transition.R`, `evaluate_bea_fix_impact.R`,
`usmca_monthly_noise_diagnostic.R`, `usmca_monthly_summary.R`,
`dump_usmca_payload.R`, `dump_usmca_payload_unboxed.R`, `decompose_fix_channels.R`,
`compare_three_models.R`, `build_model_b_olddates.R`, `report_master_fix_impact.R`,
`report_timeline_split_impact.R`, `plot_timeline_split_compare.R`,
`validate_phase3_fix.R`, `check_auto_floor_annex.R`, `verify_scenario_differences.R`,
`verify_new301_carveout.R`, `validate_derivative_classification.R`,
`audit_smoke_test.R`, `audit_revision_dates.R`, `audit_s232_usmca_eligibility.R`,
`audit_usmca_fallback_impact.R`, `beef_tariffs_by_authority.R`,
`write_eu_tweet_update.R`, `chart_weighted_rate_comparison.R`

**`scripts/` → `scripts/archive/`** (3 stale wrappers + 1 chain runner):
`submit_reprice_301.sh`, `submit_timeline_validate.sh`,
`submit_weighted_daily_chart.sh`, `run_three_model_chain.ps1`

**`scripts/` → `scripts/archive/payloads/`** (4 checked-in API payloads):
`payload_2025_full_annual.json`, `payload_2026_full_annual.json`,
`payload_2026_ytd_feb_monthly.json`, `payload_2026_ytd_feb_monthly_unboxed.json`

**`scripts/curl_out/` → `scripts/archive/curl_out/`** (3 raw API responses):
`resp_arrays_2025.json`, `resp_arrays_2026.json`, `resp_unboxed_2026.json`

**Kept in `scripts/`:** blessed build/publish/parity entry points
(`submit_build_verify.sh`, `submit_build_array.sh`, the array-flow components,
plank gates) + idempotent resource builders (`build_annex_ii_dates.R`,
`build_s301_*`, `parse_annex_products.R`, `scrape_country_eo_annexes.R`,
`refresh_product_caches.R`, `prune_ieepa_exempt_untraceable.R`,
`regen_floor_exempt_2025.R`, `list_alt_variants.R`) + ambiguous utilities left in
place (`rebuild_one_revision.R`, `run_daily_streaming.R`).

---

## Proposed target layout (Phase 1d)

```
src/
  pipeline/      00–07, 09
  model/         authority_spec, authority_adapter, stacking, rate_schema,
                 resolved_programs, timeline, policy_params, data_loaders,
                 revisions, scenario_registry
  io/            write_output, output_paths, publish_git, build_import_weights
  core/          helpers (facade), hts_utils, logging, parallel, build_config, parity
  experimental/  load_adcvd_layer
tools/           manual resource/doc generators
scripts/         blessed build/publish/parity entry points ONLY
scripts/archive/ resolved one-offs + payloads/ + curl_out/
docs/ , docs/internal/
```
