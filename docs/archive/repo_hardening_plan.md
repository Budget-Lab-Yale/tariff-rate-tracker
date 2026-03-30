# Repo Hardening Plan

## Purpose

This plan covers five goals:

1. Centralize documentation.
2. Make the repository runnable on initial download.
3. Move all Tariff-ETRs references into optional comparison-only workflows.
4. Standardize R package and side-file installation and checking.
5. Centralize magic numbers and policy parameters in `config/policy_params.yaml` and document them.

The intent is to make the repo self-contained for producing the tariff series itself, while keeping TPC and Tariff-ETRs strictly as external comparison benchmarks.

## Guiding Principle

The tariff series should be buildable from:

- HTS JSON / Chapter 99 PDF inputs,
- versioned repo resources,
- documented optional external datasets,
- explicit configuration in `config/policy_params.yaml`.

It should not depend on the Tariff-ETRs repo for production outputs.

## A. Centralize Documentation

## Problem

Documentation is currently split across:

- [README.md](README.md)
- [docs/methodology.md](docs/methodology.md)
- [docs/assumptions.md](docs/assumptions.md)
- [docs/active_hts_changes.md](docs/active_hts_changes.md)
- comparison memos and issue memos under `docs/`

This makes it hard for a new user to answer basic questions:

- what is required to run,
- which inputs are official versus derived,
- which steps are optional,
- which settings govern the build.

## Plan

### A1. Reorganize documentation into a clear hierarchy

Create a simple structure:

1. `README.md`
   - project overview
   - quick start
   - required inputs
   - optional comparison workflows
   - links to deeper docs
2. `docs/build.md`
   - full build instructions
   - first-run checklist
   - environment setup
   - expected outputs
3. `docs/data_inputs.md`
   - every input file or source
   - whether it is committed, downloaded, scraped, private, or optional
   - regeneration path
4. `docs/methodology.md`
   - tariff construction methodology only
5. `docs/assumptions.md`
   - non-official assumptions only
6. `docs/comparisons.md`
   - comparison workflows with TPC and Tariff-ETRs only

### A2. Trim README to only high-value entry-point content

Keep in README:

- what the repo does,
- how to run it from scratch,
- what is required versus optional,
- where to find methodology and comparison docs.

Move out of README:

- long comparison sections,
- extensive validation detail,
- issue deep-dives,
- implementation notes that belong in methodology or assumptions docs.

### A3. Add a single “Input Inventory” table

In `docs/data_inputs.md`, include columns:

- `input`
- `path`
- `role`
- `status`
  - `committed`
  - `auto-download`
  - `auto-scrape`
  - `manual-download`
  - `private optional`
- `required_for_core_build`
- `required_for_comparison_only`
- `regeneration_step`

### A4. Add a “What Runs Without What” matrix

Document these modes explicitly:

- core tariff build
- core build plus daily aggregates
- core build plus weighted ETR
- TPC comparison
- Tariff-ETRs comparison

This should state which outputs degrade or skip when certain files are absent.

## B. Make the Repo Runnable on Initial Download

## Problem

A first-time user currently faces several hidden dependencies:

- missing R packages,
- missing HTS JSON files,
- optional but externally referenced side files,
- optional private files,
- implicit fallback behavior.

## Plan

### B1. Add a preflight environment checker — DONE

Created `src/preflight.R` that verifies:

- required R packages
- required directories
- required config files
- presence of committed resources
- presence of optional comparison files
- presence of optional weighting files
- network availability for download/scrape steps when needed

Output should classify each item:

- `required and present`
- `required and missing`
- `optional and present`
- `optional and missing`

### B2. Define run modes explicitly — DONE

Support these modes:

1. `core`
   - builds tariff snapshots and timeseries from repo and USITC sources only
2. `core_plus_weights`
   - adds weighted outputs if local import weights are available
3. `compare_tpc`
   - runs TPC validation only if the private TPC file is present
4. `compare_etrs`
   - runs Tariff-ETRs comparison only if comparison artifacts are configured

The main build should report which mode it actually ran.

### B3. Ensure first-run defaults do not point outside the repo for core outputs — DONE

Current defaults in weighted and daily scripts reference a sibling Tariff-ETRs cache path.

For core repo behavior:

- remove any default external path from production code paths,
- require explicit opt-in for weighting inputs not shipped in the repo,
- skip weighted outputs cleanly if weights are not configured.

### B4. Add a reproducible first-run command sequence — DONE

Document and support a clean sequence such as:

1. `Rscript src/preflight.R`
2. `Rscript src/02_download_hts.R`
3. `Rscript src/scrape_us_notes.R --all`
4. `Rscript src/00_build_timeseries.R --core-only`

If weighted outputs or comparisons are wanted, those should be separate commands.

### B5. Add explicit error messages for degraded runs — DONE

Examples:

- “TPC file missing; validation skipped.”
- “Import weights missing; weighted outputs skipped.”
- “Tariff-ETRs path not configured; comparison skipped.”

## C. Move Tariff-ETRs References to Optional Comparison-Only Workflows

## Problem

The repo still uses Tariff-ETRs-derived resources and paths in ways that blur the line between:

- core series construction,
- benchmarking or cross-validation.

The target state is:

- Tariff-ETRs and TPC are comparison-only.

## Plan

### C1. Audit every Tariff-ETRs reference — DONE

Classify each reference into one of three buckets:

1. comparison-only
2. borrowed input that must be re-derived or internalized
3. methodology note only

Likely candidates for cleanup include:

- external cache paths in weighted and daily scripts
- README and methodology language
- resources that currently cite Tariff-ETRs as source

### C2. Remove Tariff-ETRs repo paths from production defaults — DONE

Core build code should not default to:

- `here('..', 'Tariff-ETRs', ...)`

If a user wants cross-repo comparison, that should live in a dedicated comparison config or CLI flag.

### C3. Separate core resources from benchmark-derived resources — DONE (no action needed)

For each currently benchmark-derived resource, choose one path:

1. re-derive from official or directly documented sources,
2. commit it as a maintained repo resource with internal provenance notes,
3. mark it clearly as temporary until re-derived.

The series build should use only:

- repo-owned resources,
- official downloads,
- explicit internal assumptions.

### C4. Create a dedicated comparison program — DONE

Add a `src/run_comparisons.R` orchestrator that:

- checks for TPC and Tariff-ETRs availability,
- runs only comparison scripts,
- writes comparison outputs under `output/comparisons/`.

It should not be called by the core build unless explicitly requested.

### C5. Update docs to enforce the separation — DONE

In documentation, use this rule:

- TPC and Tariff-ETRs validate the series.
- They do not define the production series.

## D. Standardize R Package / Side File Installation and Checking

## Problem

Dependencies are currently implicit and distributed across scripts.

## Plan

### D1. Add an R dependency manifest — DEFERRED

Choose one standard approach:

1. `renv`
2. a simple `DESCRIPTION`
3. a plain `requirements.R` installer script

Preferred option:

- `renv` for reproducible environments

Minimum package set should include:

- `tidyverse`
- `jsonlite`
- `yaml`
- `here`
- `rvest`
- `pdftools`
- `arrow` as optional

### D2. Add an installation helper — DONE

Create `src/install_dependencies.R` that:

- installs required packages,
- optionally installs comparison-only packages,
- prints which packages are required versus optional.

### D3. Add a side-file checker — DONE (integrated into preflight.R)

The environment check should also verify side files such as:

- HTS JSON archives
- Chapter 99 PDFs
- `resources/*` lookup tables
- optional TPC file
- optional import-weight files

### D4. Introduce a simple local config for optional external files — DONE

Add an optional local config file, for example:

- `config/local_paths.yaml`

This should hold user-specific paths for:

- private TPC data
- optional weighting data
- optional comparison repo locations

It should not be required for the core build.

### D5. Add a final environment summary at runtime — PARTIAL

Every major entry point should print:

- required packages status
- optional package status
- required file status
- optional file status
- active run mode

## E. Centralize Magic Numbers and Policy Parameters

## Problem

The core policy layer is already mostly centralized in `config/policy_params.yaml`, but some important values still live in scripts:

- comparison date labels
- fallback rates
- partner/reporting constants
- hardcoded path defaults
- ad hoc thresholds in diagnostics or exports

## Plan

### E1. Define what belongs in `policy_params.yaml` — MOSTLY DONE

Move into `policy_params.yaml` anything that affects the meaning of the tariff series:

- rates
- effective dates
- expiry dates
- country codes
- authority ranges
- coverage prefixes
- list-to-rate mappings
- metal share methods and defaults
- duty-free treatment choices
- projection horizon

Do not move into `policy_params.yaml`:

- pure reporting cosmetics
- package names
- output file extensions
- transient CLI options

### E2. Add a second config for non-policy runtime settings

Create something like:

- `config/runtime_params.yaml`

Use it for:

- optional external file paths
- output toggles
- default export formats
- comparison dates and labels
- quality-check thresholds

This keeps `policy_params.yaml` focused on actual tariff logic.

### E3. Replace scattered fallback constants in scripts

Audit and migrate:

- country code fallbacks in scripts
- hardcoded policy date labels in `08_weighted_etr.R`
- hardcoded comparison date sets
- fixed file-size thresholds if they are meaningful and reused
- magic thresholds in diagnostics that should be named and documented

### E4. Document every config block

For each block in `policy_params.yaml`, document:

- purpose
- source
- whether official or assumed
- scripts that consume it

This can live in:

- comments inside YAML
- `docs/data_inputs.md`
- `docs/assumptions.md`

### E5. Add a config audit step

Create a small script that reports:

- YAML keys unused by code
- hardcoded policy-like literals still present in scripts
- required config fields missing

This should be run during development and before releases.

## Execution Status

### Phase 1: make first-run behavior predictable — DONE (f1c5f39)

1. ~~Add dependency manifest.~~ → `src/install_dependencies.R` (required + `--all` optional)
2. ~~Add `install_dependencies.R`.~~ → Done.
3. ~~Add `check_environment.R`.~~ → `src/preflight.R` (renamed to avoid `.gitignore` `check_*.R` pattern). Checks packages, dirs, configs, 11 required + 5 optional resources, HTS JSON, external files. Reports run-mode readiness (core / core_plus_weights / compare_tpc / compare_etrs).
4. ~~Remove production defaults that point to Tariff-ETRs paths.~~ → Both hardcoded `here('..', 'Tariff-ETRs', ...)` paths removed from `08_weighted_etr.R` and `09_daily_series.R`. Replaced with `config/local_paths.yaml` (gitignored, template at `local_paths.yaml.example`). `load_local_paths()` added to `helpers.R`, auto-loaded by `load_policy_params()`.
5. ~~Add run-mode reporting.~~ → `--core-only` flag added to `00_build_timeseries.R` (build + unweighted daily + quality, skip ETR). Preflight reports which modes are available.

### Phase 2: separate core build from comparisons — DONE (90d216e)

1. ~~Create `run_comparisons.R`.~~ → `src/run_comparisons.R` with `--tpc`, `--etr`, `--etrs` flags. Checks data availability via `local_paths.yaml`, runs TPC validation and/or weighted ETR overlay. Outputs to `output/comparisons/`.
2. ~~Move TPC and Tariff-ETRs workflows behind explicit commands.~~ → `08_weighted_etr.R` now skips gracefully when import weights or TPC file missing. `plot_etrs()` handles `tpc_etrs = NULL`. TPC overlay in ETR is optional — core build produces ETR without TPC columns.
3. ~~Update README to reflect core versus comparison modes.~~ → README updated with "First-Time Setup" section, `--core-only` flag, "Comparison Workflows" section, `local_paths.yaml` in config table, new scripts in Code Guide.

### Phase 3: centralize documentation — IN PROGRESS

1. ~~Create `docs/build.md`.~~ → Added and now serves as the first-run/build guide.
2. ~~Create `docs/data_inputs.md`.~~ → Added with input inventory and run-mode matrix.
3. Create `docs/comparisons.md` — consolidated comparison documentation (TPC, Tariff-ETRs).
4. Continue trimming README — it now points to `docs/build.md`, `docs/data_inputs.md`, and `docs/assumptions.md`, but still contains substantial methodology and validation detail.

### Phase 4: finish parameter centralization — IN PROGRESS

1. ~~Audit remaining hardcoded policy values in scripts (main candidate: `POLICY_DATES` tribble in `08_weighted_etr.R`).~~
2. ~~Move policy/reporting values needed by `08_weighted_etr.R` to `policy_params.yaml`.~~ → Added `weighted_etr.policy_dates` and `weighted_etr.tpc_name_fixes`.
3. Evaluate whether `runtime_params.yaml` is needed (currently `policy_params.yaml` is still manageable without splitting).
4. Add `source` and `consumed_by` annotations to YAML config blocks where they would clarify provenance and ownership.

## Deliverables

The end state should include:

- ~~a repo that can be cloned and checked with one command,~~ ✓ `preflight.R`
- ~~a core build that does not depend on Tariff-ETRs,~~ ✓ all external paths removed
- ~~explicit optional comparison workflows,~~ ✓ `run_comparisons.R`
- ~~reproducible package setup,~~ ✓ `install_dependencies.R`
- centralized config with clear ownership of every parameter, (mostly done — provenance annotations and runtime-config decision remain)
- documentation that tells a new user exactly what is required and what is optional. (build and input docs added; comparison doc and further README trimming remain)

## Bottom Line

The most important architectural cleanup — separating core tariff-series construction from optional weighting, validation, and cross-repo comparison — is complete. The repo can now be cloned, checked, and built in core mode without external comparison dependencies. Remaining work is documentation consolidation, finishing the Tariff-ETRs comparison runner, and polishing config provenance.
