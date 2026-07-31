# Tariff Rate Tracker — working notes

## Running R on this cluster

R is **not on `PATH` by default**. Load the system module first:

```bash
module load R/4.4.2-gfbf-2024a
```

- The module env only persists **within a single shell invocation**. If a tool
  runs each command in a fresh shell, load the module in the *same* command that
  calls `Rscript` (e.g. `module load R/4.4.2-gfbf-2024a; Rscript ...`).
- Use the **system module**, not a hand-built tree. Do **not** point
  `R_LIBS_USER` at `~/r_libs_4.4`: the hand-built Arrow 24.0.0 there lacks zstd
  and breaks builds. The system module's Arrow (17.0.0.1) has zstd.
- BLAS/OpenMP threads are pinned in batch jobs via `OPENBLAS_NUM_THREADS` etc.;
  the build is single-threaded R, so CPUs mainly cover BLAS/Arrow/OS overhead.

## Where to run: local (interactive) vs. Slurm batch

**Interactive sessions default to 5 GB RAM** (`devel` partition,
`DefMemPerCPU=5120`) — they OOM on a full build, and a Claude Code session
plus one or two R test processes can crest 5 GB on its own (three sessions
were OOM-killed at exactly 5.24 GB on 2026-07-28). It's only a default, not a
partition cap: start Claude sessions with more headroom, e.g.

```bash
salloc -p devel --mem=16G -t 4:00:00
```

The 4 h `TIME_LIMIT` is also just the default request (`MaxTime=UNLIMITED`);
ask for more with `-t` if the session must outlive it. Pick the venue by
memory footprint:

| Task | Where | Notes |
|------|-------|-------|
| Smoke / unit tests, unweighted runs | **Local** (interactive) | Light; the four CI test scripts run fine |
| Single-snapshot inspection, parsing, config edits | **Local** | |
| Full rebuild `src/pipeline/00_build_timeseries.R --full` | **Slurm** | OOMs locally |
| Weighted-output build | **Slurm** | Needs the ~1.5 GB Census ZIP build + memory |

Full rebuild + verify is a ready-made batch job (4 h walltime, **192 GB**, 4 CPUs):

```bash
sbatch scripts/submit_build_verify.sh
```

- 192 GB is deliberate: `combine-snapshots` has OOM'd at 96 GB.
- The script rebuilds all snapshots, runs `tests/test_rate_calculation.R`, and
  does inline Russia rev_5 sanity checks. Logs land in `~/slurm-logs/`.

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
