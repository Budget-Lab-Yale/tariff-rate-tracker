# Tariff Rate Tracker — working notes

> On the Yale HPC, cluster setup (R module load, Slurm, paths) lives in your user-level `~/.claude/CLAUDE.md`.

## How to build anything: the array path, always

**`scripts/submit_build_array.sh --config config/build/<name>.yaml` is the only
build path to use.** It builds `actual` plus one subfolder per scenario listed in
the config, all series through the same code and the same 484(f) per-interval
weight plan, into ONE vintage — so scenario-vs-actual diffs are exact. Example:
`config/build/counterfactuals_fl301_polysilicon.yaml`.

Two older paths still exist and both produce wrong weighted output. Do not use
them:

- **The alternatives / counterfactual runner** (`--alternatives <names>`,
  `run_alternative_series`, `alt_runner`). It predates the 484(f) weight mapper
  and accepts only a single static weights table, so its weighted ETRs carry the
  static-join error below. Any scenario it can run, the array path runs properly
  — `kind:` in `meta.yaml` does not restrict which scenarios the array path
  accepts. **Retired 2026-08-11.**
- **The serial `--full` build** (`scripts/submit_build_verify.sh`). Its rate panel
  is fine, but until 2026-08-11 its daily stage called `load_import_weights()`
  directly — the `static` method, joining the raw 2024 base to the panel on
  (hts10, country). Every code renumbered since 2024 failed to join: **$164B of
  trade (5%) dropped out of the numerator while staying in the denominator**,
  depressing EVERY authority's weighted contribution — about −0.8 pp on the
  overall ETR, and it published silently. Now fixed to resolve the same weight
  plan as the gather, but prefer the array path regardless.

Diagnostic that catches this class of bug instantly: **`matched_imports_b` must
equal `total_imports_b`** in `daily_overall` (100.000%, every day). If it is
~94.7%, the weights were joined statically. A second tell: when *every* authority
column moves in the same direction at once, suspect weights, not policy.

## Where to run: local (interactive) vs. Slurm batch

**Interactive sessions are capped at 5 GB RAM** — they OOM on a full build.
Pick the venue by memory footprint:

| Task | Where | Notes |
|------|-------|-------|
| Smoke / unit tests, unweighted runs | **Local** (interactive) | Light; the four CI test scripts run fine |
| Single-snapshot inspection, parsing, config edits | **Local** | |
| Full rebuild `src/pipeline/00_build_timeseries.R --full` | **Slurm** | OOMs locally |
| Weighted-output build | **Slurm** | Needs the ~1.5 GB Census ZIP build + memory |

Full rebuild + verify is a ready-made batch job (6 h walltime, **384 GB**, 4 CPUs):

```bash
sbatch scripts/submit_build_verify.sh
```

- **384 GB is measured, and the requirement grows with the series.** At 60
  revisions / 292M rows the build peaks at **MaxRSS 234 GB** and takes 3 h 15 m
  (job 21784088, 2026-08-09). The former 192 GB is no longer enough — job
  21739576 that same day was OOM-killed at 201 GB. Re-measure after adding
  revisions rather than assuming the figure holds.
- The binding constraint has moved: the old 192 GB came from a
  `combine-snapshots` OOM at 96 GB, but that step now succeeds and the kill
  happens downstream, in the daily/ETR stage.
- The script rebuilds all snapshots, runs `tests/test_rate_calculation.R`, and
  does inline Russia rev_5 sanity checks. Logs land in `~/slurm-logs/`.
- BLAS/OpenMP threads are pinned in batch jobs via `OPENBLAS_NUM_THREADS` etc.;
  the build is single-threaded R, so CPUs mainly cover BLAS/Arrow/OS overhead.

### Monitoring a batch job
```bash
squeue -u ji252                 # ST=R means running
tail -f ~/slurm-logs/tariff-build-verify-<jobid>.out
```

## Running the CI smoke tests locally (CI parity)

CI (`.github/workflows/ci.yml`, job `smoke`) opts out of weighted outputs, then
runs four test scripts in order. To reproduce:

```bash
printf 'weight_mode: unweighted\n' > config/local_paths.yaml   # CI's opt-out; remove when done
module load R/4.4.2-gfbf-2024a
Rscript src/preflight.R
Rscript tests/run_tests_daily_series.R
Rscript tests/run_tests_weights_resolution.R
Rscript tests/run_tests_annex_parser.R
Rscript tests/test_rate_calculation.R
```

- A failing test step exits non-zero and **halts the job**, so later steps
  don't run — the CI "N failed" count is from the *first* failing step only.
- `config/local_paths.yaml` is not tracked; delete it afterward to keep the
  tree clean, or commit it only if you intend an unweighted local default.
