# scripts/ — entry points and what's blessed

## Blessed build entry points (use these)

| Script | What it does | Destination |
|---|---|---|
| `submit_build_verify.sh` | Serial full rebuild + verification gate (`verify_build.R`), one reviewable Slurm job (192G/4h) | Repo-local (`data/timeseries/`, `output/actual/`) |
| `submit_build_array.sh --config config/build/<name>.yaml` | Config-driven parallel build: Slurm array per revision, scenarios concurrent, gather + verified finalize | Shared model_data vintage (repo never written) |

Everything else under `scripts/` is supporting infrastructure (array task /
gather / finalize components, parity and equivalence harnesses) or one-off
diagnostics. See `todo.md` "Build unification plan" for where this is headed:
one build product, destinations chosen by config, not by which wrapper you ran.

## Shared verification gate (`verify_build.R`, unification Phase 2)

`scripts/verify_build.R [--output-root <dir>] [--skip-tests]` runs the
rate-calculation test suite plus the Russia rev_5, rev_10/Annex I-C, and
panel NA-interval sanity checks. Layout-aware: an rds dir (repo
`data/timeseries/` — the default — or an array scratch) or a published
vintage (`<root>/actual/snapshots/valid_from=*/rates.parquet`). Every check
is a gate: any failure exits 1. Both blessed entry points run it —
`submit_build_verify.sh` after the serial build, and the array finalize when
`verify: true` (the config default): publish without moving `latest`, verify
the vintage, then `publish_vintage.R --latest-only` repoints `latest` and the
scratch is removed. A verify failure keeps the vintage on disk, `latest` on
the previous good vintage, and the scratch intact.

## Alternatives / counterfactuals (2026-06-10 unification)

Every non-baseline variant is a folder under `config/scenarios/<name>/`
(`meta.yaml` + `overlay.yaml`; registry in `src/model/scenario_registry.R`). Request
them on the main entrypoint with the canonical selector:

```bash
Rscript src/pipeline/00_build_timeseries.R --alternatives all                  # every alternative + counterfactual
Rscript src/pipeline/00_build_timeseries.R --alternatives no_301,metal_flat    # by name
Rscript src/pipeline/00_build_timeseries.R --alternatives counterfactuals     # all kind=counterfactual
```

Legacy spellings `--with-alternatives` (== `--alternatives alternatives`) and
`--rebuild-alts <list>` still work — the blog pipeline passes them — but new
scripts should use `--alternatives`. Outputs land in `output/scenarios/<name>/`.
Full named series (`forced_labor`, `new_301`, kind=scenario) still build via
`TARIFF_SCENARIO=<name>`, not through `--alternatives`.

## Components of the array flow (not run directly)

- `list_revisions.R`, `build_array_task.sh` / `build_revision.R`,
  `submit_build_gather.sh` / `build_gather.R`, `publish_vintage.R`,
  `print_build_config.R`

## Parity / equivalence harnesses

- `submit_build_full.sh` — serial "golden" reference build the array flow is
  validated against (BUILD_ARGS overridable).
- `submit_plank*.sh`, `submit_alt_equivalence.sh`, `run_parity_check.R`,
  `summarize_parity_results.R`

## Removed (2026-06-09)

`submit_build.sh`, `submit_build_core.sh`, `submit_build_full_nopublish.sh` —
stale untracked wrappers that passed `--publish-internal`, a flag
`00_build_timeseries.R` no longer parses (it was silently ignored; the
entrypoint now errors on unknown flags). The shared-filer route is the array
flow; the repo-local route is `submit_build_verify.sh`.

## Conventions

- All Slurm scripts log to `~/slurm-logs/<job-name>-<jobid>.{out,err}`.
- No script hardcodes a repo path: standalone sbatch scripts run from the
  submission directory (`sbatch` from the repo root); the array orchestrator
  derives the repo from its own location and passes `--chdir` explicitly
  (override with `TARIFF_REPO=...`).
- R on this cluster: `module load R/4.4.2-gfbf-2024a` (see CLAUDE.md).
