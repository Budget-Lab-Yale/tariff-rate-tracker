# Restructure Plan — de-sprawl `src/` and `scripts/`

**Goal:** Make the tracker easy to *run* and *understand* for an external audience
(formal modelers), without changing any computed numbers. This is a
cleanup-and-reorganize effort, not a rewrite.

**Status legend:** ☐ todo · ◐ in progress · ☑ done (this branch) · ⏸ deferred

**Branch:** `restructure-codebase` (from `master`).

---

## Findings (the "why")

The rate engine is sound — no logic duplication, helpers defined once, a clean
`authority_spec → authority_adapter → calculator` abstraction, and a strong
parity-test discipline that makes refactors safe. The problem is **surface
area**, not correctness:

- `src/` holds 48 files; ~13 are one-off investigations sourced by nobody,
  interleaved with the pipeline.
- `scripts/` is an 80-file flat dump; ~64 are resolved investigations or
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

Doc fixes + archive dead one-offs + status banners. Nothing that changes a build
output; every moved `src/` file was verified sourced-by-nobody. Test suites green
(daily-series 81, weights 16, annex 25; rate-calc 102 pass + 3 pre-existing
stale-snapshot failures unrelated to the change). All items below completed;
the root-clutter housekeeping (`.Rhistory`, `build.log`, `test_output/`,
`check_revisions.R`, `test_two_revisions.R`) turned out to be already gitignored,
so no repo action was needed there.

### 0a. README correctness
- ☐ Remove `--publish-internal` bullet + the two commands using it
  (`README.md:87,91,93`); keep only `--publish-git`.
- ☐ Delete the `src/08_weighted_etr.R` line from Repository structure
  (`README.md:102`) — file no longer exists.

### 0b. Archive dead one-offs out of `src/`  (sourced by nobody)
Move to `scripts/archive/`:
- ☐ `compare_etrs.R`  ☐ `diagnose_china_gap.R`  ☐ `diagnostics.R`
- ☐ `download_subdivision_r_share.R`  ☐ `export_for_etrs.R`
- ☐ `run_comparisons.R`  (dead-but-shipped: `--etrs` is a stub, `--tpc` depends
  on deleted `data/tpc/`)

Delete (throwaway, references non-existent `output/alternative/` layout):
- ☐ `src/_compare_alternatives.R`

Follow-on edit:
- ☐ Trim the now-vestigial `compare_tpc` / `compare_etrs` readiness modes from
  `preflight.R:298,303–307` (their drivers are archived).

### 0c. Archive `scripts/` one-offs and API payloads
Move resolved investigations + one-off wrappers to `scripts/archive/`; move
checked-in API payloads to `scripts/archive/payloads/`. (Full list in the
commit; ~30 investigation scripts, 3 stale `submit_*.sh` wrappers, 7 `.json`
payloads.) Keep: blessed build/parity entry points + idempotent resource
builders.

### 0d. Status banners on parked modules
Add a one-line `STATUS:` banner so a reader isn't misled:
- ☐ `timeline.R` — header says "NOT yet wired"; it **is** wired on the build
  side (`discover_boundaries`/`build_boundary_mints` in `00`). Correct it.
- ☐ `resolved_programs.R` — PROTOTYPE, default-OFF via `use_resolved_stacking()`.
- ☐ `load_adcvd_layer.R` — SCAFFOLD, not wired; test-only.

### 0e. Verify + ship
- ☐ Run CI smoke tests locally (unweighted) — must pass.
- ☐ Commit, push `restructure-codebase`.

---

## Phase 1 — Structural (follow-up, parity-gated)

### 1a. Name the steps in the rate engine
- ⏸ Extract the 17 numbered steps of `calculate_rates_for_revision()` into named
  functions (`apply_section232_base()`, `apply_301()`, `apply_usmca_exemption()`,
  …) called from a short driver. Prove no-change via the parity harness
  (`parity.R` + `submit_plank*`). File may stay one file.

### 1b. Resolve the dual interval splitter
- ⏸ Either wire `09_daily_series.R` onto the `timeline.R` boundary
  representation, or document in `architecture.md` which is canonical and why
  both exist. Then collapse redundant timeline/zeroing equivalence tests.

### 1c. De-duplicate `09_daily_series.R`
- ⏸ Factor `prepare_interval_data()` to replace the repeated
  `filter → apply_expiry_zeroing → apply_stacking_rules` preamble across the
  three `compute_agg_*` helpers and their `has_weights` twins.

### 1d. Folder layout for `src/`  (path-touching; parity-gated)
- ⏸ `src/{pipeline,model,io,core,experimental}/` per the review; update
  `source(here('src', …))` paths; rerun parity.
- ⏸ Relocate manual tools (`scrape_us_notes`, `calibrate_s301_exclusions`,
  `build_hts_concordance`, `expand_ieepa_exempt`, `revision_changelog`,
  `generate_etrs_config`, `download_usmca_dataweb`, `build_usmca_scenarios`) to a
  `tools/` dir; update test source paths + README.

### 1e. Docs + housekeeping
- ☑ Expand `architecture.md` to a complete one-line-per-file table (3-layer
  model) + the two in-progress-migration notes. **DONE.**
- ⏸ Move internal process docs (`theseus_*`, `codex_*`, `*_plan.md`,
  `bugfix_decisions_*`, `phase6_*`) to `docs/internal/`.
- ⏸ Gitignore/clean repo-root clutter (`.Rhistory`, `build.log`,
  `test_output/`, orphan `data/timeseries_olddates/`); fold `check_revisions.R`
  / `test_two_revisions.R` into `tests/`.
- ⏸ Remove the dangling `apply_scenarios.R` references (deleted file; only an
  archived one-off + a `rate_schema.R` comment point at it).

---

## Proposed target layout (Phase 1d)

```
src/
  pipeline/      00–07, 09
  model/         authority_spec, authority_adapter, stacking, rate_schema,
                 resolved_programs, timeline, policy_params, data_loaders,
                 revisions, scenario_registry
  io/            write_output, output_paths, publish_git, build_import_weights
  core/          helpers (facade), hts_utils, logging, parallel, build_config
  experimental/  load_adcvd_layer
tools/           manual resource/doc generators
scripts/         blessed build/publish/parity entry points ONLY
scripts/archive/ resolved one-offs + payloads/
docs/ , docs/internal/
```
