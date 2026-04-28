# Parallel Full Pipeline - Implementation Plan

**Date:** 2026-04-24

## Purpose

This document lays out a conservative plan for adding an **optional parallel full-pipeline mode** to the tariff-rate-tracker build.

The goal is to let users with multiple CPU cores complete the build more efficiently without weakening correctness, reproducibility, or recoverability. The key word is **optional**: the current serial path should remain the default and the reference implementation until the parallel path is proven stable.

## Current State

The core pipeline is orchestrated in [src/00_build_timeseries.R](../src/00_build_timeseries.R). It currently:

1. Orders revisions from `config/revision_dates.csv`
2. Loops over revisions sequentially
3. Parses each revision's HTS JSON and computes a per-revision snapshot
4. Saves `snapshot_<revision>.rds` plus some cached parse outputs
5. Binds all snapshots into `data/timeseries/rate_timeseries.rds`
6. Runs downstream outputs:
   - [src/09_daily_series.R](../src/09_daily_series.R)
   - [src/08_weighted_etr.R](../src/08_weighted_etr.R)
   - [src/quality_report.R](../src/quality_report.R)
   - optional alternatives in [src/09_daily_series.R](../src/09_daily_series.R)

Several observations matter for parallelization:

- The per-revision calculation in [src/06_calculate_rates.R](../src/06_calculate_rates.R) is largely independent across revisions.
- The current build loop uses `prev_ch99` and `prev_products` only for delta reporting, not because later revisions require earlier rate outputs.
- The combined timeseries is very large. Recent quality output reported **184,978,080 rows across 39 revisions**.
- A single revision can already expand to roughly **4.7 million HTS10 x country pairs** during rate construction.
- Recent post-build scenario runs failed with `cannot allocate vector of size 705.6 Mb` while filtering the combined timeseries, which is strong evidence that **memory is the first constraint**, not raw CPU.
- The daily-series code already contains a snapshot-first aggregation seam in `aggregate_snapshots_per_revision()` in [src/09_daily_series.R](../src/09_daily_series.R), which is a better foundation for multi-core work than repeatedly loading or filtering the full combined timeseries.

## Recommendation Summary

The recommended design is:

- Parallelize at the **revision boundary** first.
- Use **process-based workers**, not in-process or fork-only parallelism.
- Keep all shared-artifact writes serial.
- Keep the serial path as the default.
- Treat worker count as a **memory-tuned** setting, not "all available cores".
- Push downstream steps toward **snapshot-first** processing before parallelizing them.

In short: **one worker builds one revision snapshot**, then a single coordinator assembles shared outputs.

## Why Revision-Level Parallelism First

Revision-level parallelism is the safest first step because it matches the actual structure of the codebase.

### Good fit

- `calculate_rates_for_revision()` in [src/06_calculate_rates.R](../src/06_calculate_rates.R) already accepts the revision-specific inputs it needs.
- Each revision already produces its own durable artifact: `snapshot_<revision>.rds`.
- Optional TPC validation is also revision-scoped and can be written to `validation_<revision>.rds`.

### Low-risk compared with inner-loop parallelism

Parallelizing inside the rate engine would require careful auditing of:

- intermediate joins and grid expansions
- helper functions with implicit file reads
- memory amplification inside already-large tibbles
- reproducibility of row ordering and diagnostics

That work may be worthwhile later, but it is a much riskier place to start.

## Non-Goals for the First Implementation

The first parallel implementation should **not** try to do all of the following at once:

- parallelize the internals of `calculate_rates_for_revision()`
- parallelize every downstream step immediately
- use every available core by default
- change the semantics of the existing serial build
- remove the combined `rate_timeseries.rds` artifact

Those are possible future directions, but they should not be bundled into the initial rollout.

## Main Constraints and Notes of Caution

### 1. Memory is likely to dominate before CPU

This repository already documents 32 GB RAM as the recommended footprint for the full build. The recent OOM failures in post-build scenarios reinforce that a naive "more workers = faster" rule will not hold here.

Practical caution:

- On a 32 GB machine, start with **2 workers**, not 8 or 16.
- On a 64 GB machine, **3-4 workers** may be reasonable after benchmarking.
- Do not default to `availableCores()` until the memory profile is measured under real workloads.

### 2. Windows compatibility matters

The repo is expected to run on Windows, macOS, and Linux. That rules out relying on Unix-only fork behavior as the primary backend.

Recommendation:

- prefer `future.apply` with `future::plan(multisession)`
- or use PSOCK clusters from base `parallel`

Do **not** build the design around `mclapply()`.

### 3. Shared writes must stay single-writer

Workers should not concurrently write to:

- `data/timeseries/rate_timeseries.rds`
- `data/timeseries/metadata.rds`
- shared log files
- common CSV outputs under `output/daily`, `output/etr`, or `output/quality`

Workers may safely write revision-scoped files such as:

- `snapshot_<revision>.rds`
- `ch99_<revision>.rds`
- `products_<revision>.rds`
- `validation_<revision>.rds`

### 4. The current logger is not worker-safe

[src/logging.R](../src/logging.R) maintains a single active log target and appends to one file. That is fine in serial mode but will produce interleaved and potentially unreadable output if multiple workers share it.

Recommendation:

- coordinator log for top-level orchestration
- one log file per worker or per revision

### 5. Combined-timeseries downstream work is a parallelism trap

The current weighted ETR and quality-report paths load the combined timeseries. If each parallel worker also loads the full 185M-row object, memory use will explode.

Recommendation:

- keep downstream parallel work snapshot-first where possible
- delay any "parallel downstream" work until it no longer requires each worker to materialize the full combined timeseries

### 6. CPU oversubscription is a real risk

If the local R installation uses multi-threaded BLAS or any threaded native library, then `workers x BLAS threads` can oversubscribe the machine badly.

Recommendation:

- cap BLAS threads to 1 per worker when the parallel mode is enabled
- document this explicitly

### 7. Incremental mode is trickier than full rebuild mode

The current incremental logic reuses cached parse outputs and computes deltas from the prior revision. That is compatible with parallelism, but it is more stateful and therefore a riskier place to start.

Recommendation:

- first support `--parallel` only for **full rebuilds**
- leave incremental mode serial in phase 1
- add incremental parallel support only after the full rebuild path is stable

## Proposed User Interface

Add optional CLI flags to [src/00_build_timeseries.R](../src/00_build_timeseries.R):

- `--parallel`
- `--workers N`

Suggested behavior:

- default: serial build, identical to today
- `--parallel` with no worker count: choose a conservative auto value
- `--workers N`: explicit override, still validated against safe bounds

Suggested help-text semantics:

- `--parallel`: enable multisession revision-level parallelism for full rebuilds
- `--workers N`: number of revision workers to launch; use cautiously because memory, not CPU, is usually the limiting resource

Suggested first-version restriction:

- if `--parallel` is passed together with `--start-from`, emit a clear message and fall back to serial mode

That keeps the first release simple and honest.

## Proposed Architecture

### A. Add a small parallel helper module

Create a new file, for example:

- `src/parallel.R`

Responsibilities:

- detect whether parallel mode is enabled
- resolve worker count
- set up the backend
- provide a wrapper like `parallel_lapply_revisions()`
- centralize backend-specific logic so the rest of the pipeline does not care whether execution is serial or parallel

This keeps `00_build_timeseries.R` from accumulating backend-specific branching everywhere.

### B. Extract a pure revision worker

Refactor the current loop body in [src/00_build_timeseries.R](../src/00_build_timeseries.R) into a function such as:

```r
build_revision_snapshot <- function(rev_id, rev_dates, archive_dir, output_dir,
                                    census_codes_path, tpc_path, stacking_method,
                                    use_policy_dates, log_path = NULL) {
  # parse inputs
  # calculate rates
  # write revision-scoped artifacts
  # return metadata
}
```

Return value should be a compact summary, not the full rates object, for example:

- revision id
- effective date
- snapshot path
- ch99 cache path
- products cache path
- validation path if produced
- row counts
- status / error message

The coordinator can then collect results without holding all large tibbles in memory.

### C. Keep delta generation serial

The current `delta_<revision>.rds` logic compares adjacent revisions via `prev_ch99` and `prev_products`. That is logically ordered work.

Recommendation for phase 1:

- build all snapshots in parallel
- once all successful per-revision caches exist, compute deltas in revision order in a serial post-pass

This preserves current semantics while keeping the worker model simple.

### D. Keep final assembly serial

The final bind into `rate_timeseries.rds` should remain single-coordinator in the first implementation.

This includes:

- ordering revisions
- reading snapshot files
- enforcing schema
- adding `valid_from` / `valid_until`
- writing `rate_timeseries.rds`
- writing `metadata.rds`

This is not because the bind could never be parallelized, but because it is a shared-output step and should remain deterministic while the rest of the design settles.

## Phased Implementation Plan

### Phase 0 - Instrumentation and Safety Rails

Goal: add the scaffolding needed to implement parallelism without changing build results.

Tasks:

1. Add `src/parallel.R`
2. Add optional package support in [src/install_dependencies.R](../src/install_dependencies.R):
   - `future`
   - `future.apply`
   - `parallelly`
3. Add a worker-resolution helper with conservative defaults
4. Add backend notes to `docs/build.md`
5. Add explicit log messages showing:
   - parallel mode on/off
   - resolved worker count
   - warning if worker count is high relative to expected RAM

Acceptance criteria:

- serial mode remains byte-for-byte equivalent where practical
- no build behavior changes unless `--parallel` is used

### Phase 1 - Parallel Snapshot Build for Full Rebuilds

Goal: parallelize the expensive per-revision snapshot computation while leaving the rest of the pipeline mostly unchanged.

Tasks:

1. Extract `build_revision_snapshot()`
2. Launch one worker per revision chunk using the parallel helper
3. Write only revision-scoped artifacts from workers
4. Collect worker summaries in the coordinator
5. Run delta generation serially after workers finish
6. Bind snapshots serially into `rate_timeseries.rds`

Files likely touched:

- [src/00_build_timeseries.R](../src/00_build_timeseries.R)
- `src/parallel.R`
- [src/logging.R](../src/logging.R)
- [src/install_dependencies.R](../src/install_dependencies.R)

Acceptance criteria:

- parallel full rebuild produces the same snapshot counts and revision ordering as serial mode
- `rate_timeseries.rds` matches serial output within expected row ordering / floating-point tolerance
- failed revisions remain isolated and clearly reported

### Phase 2 - Snapshot-First Baseline Daily Outputs

Goal: reduce downstream reliance on the huge combined timeseries before introducing downstream parallelism.

The repo already has the core mechanism in `aggregate_snapshots_per_revision()` in [src/09_daily_series.R](../src/09_daily_series.R).

Tasks:

1. Add a baseline snapshot-first path for daily aggregation
2. Ensure it produces the same outputs as `run_daily_series(ts, ...)`
3. Prefer the snapshot-first path when parallel mode is enabled

Why this matters:

- it avoids repeatedly filtering a 185M-row combined object
- it aligns the daily series with the same per-revision seam used by the build
- it prepares the codebase for safe downstream parallelism

Acceptance criteria:

- `output/daily/*.csv` matches the current implementation within tolerance
- memory peak is lower or at least not worse than the current path

### Phase 3 - Parallel Daily Aggregation Across Revisions

Goal: parallelize daily aggregation once the baseline daily path is snapshot-first.

Tasks:

1. Add an optional parallel branch inside `aggregate_snapshots_per_revision()`
2. Parallelize over revision files, not over days and not over authorities
3. Keep final `bind_rows()` serial in the coordinator

Important caution:

Parallelize along **one dimension only**. Do not simultaneously parallelize:

- revisions
- scenarios
- and by-authority / by-country subtasks

That kind of nested fanout is the fastest way to turn a memory-bound pipeline into a crash-prone one.

### Phase 4 - Weighted ETR Refactor, Then Optional Parallelism

Goal: make weighted ETR compatible with parallel execution without loading the full timeseries in every worker.

Current issue:

[src/08_weighted_etr.R](../src/08_weighted_etr.R) currently loads `rate_timeseries.rds` internally and queries it by date. That is workable in serial mode but a poor foundation for parallel downstream work.

Recommended refactor:

1. Map each policy date to its active revision using `valid_from` / `valid_until`
2. Load only the relevant snapshot for that date
3. Compute date-level results from snapshots rather than from the full combined object

Once that refactor is done, optional parallelism across policy dates becomes much safer.

Acceptance criteria:

- weighted ETR outputs remain numerically consistent with the current implementation
- memory peak is controlled

### Phase 5 - Alternatives and Scenario Runs

Goal: improve the scenario path without repeating the mistakes that caused recent OOM failures.

The recent failures are a warning sign: scenarios that repeatedly touch giant shared objects should not be the first place to add more concurrency.

Recommended approach:

1. keep scenario processing snapshot-first
2. if parallelized, parallelize **across scenarios** or **across revisions**, but not both at once
3. give each scenario its own output directory and log
4. consider one fresh R process per scenario as a valid design choice

Fresh-process isolation is slower than keeping one long-lived session, but it may be the more reliable option for memory-heavy scenario work.

## Worker Count Guidance

Until the memory footprint is benchmarked carefully, use a conservative rule of thumb:

- 16 GB RAM: serial only
- 32 GB RAM: 2 workers
- 64 GB RAM: 3-4 workers
- more than 64 GB RAM: benchmark before going wider

In the first implementation, do **not** auto-select more than 4 workers.

This is intentionally conservative. The point of the first rollout is to make multi-core runs safer and faster, not to chase maximal throughput at the cost of instability.

## Logging and Failure Handling

Recommended logging design:

- top-level coordinator log:
  - worker count
  - revision scheduling
  - summary of successes / failures
- per-worker or per-revision logs:
  - parse summaries
  - warnings
  - validation messages
  - error trace if the worker fails

Recommended failure behavior:

- one failed revision should not automatically kill all others unless the user requests fail-fast behavior
- the coordinator should produce a clean summary of:
  - successful revisions
  - failed revisions
  - skipped downstream work if shared artifacts cannot be assembled

## Testing Plan

Add tests in layers.

### 1. Output equivalence tests

For a small revision subset:

- run serial build
- run parallel build with 2 workers
- compare:
  - snapshot row counts
  - revision ids
  - key numeric summaries
  - presence of validation artifacts

### 2. Recovery tests

Simulate one failing revision and verify:

- other revision outputs are preserved
- failure is reported clearly
- shared artifacts are either not written or are written only from successful revisions in a documented way

### 3. Downstream equivalence tests

For daily outputs and weighted ETR:

- compare serial and parallel mode outputs within floating-point tolerance

### 4. Performance and memory benchmarks

Benchmark at least:

- serial
- parallel with 2 workers
- parallel with 4 workers on a suitably large machine

Capture:

- wall-clock time
- peak memory
- per-stage runtime

## Acceptance Criteria for Shipping

The new parallel mode should be considered ready only if all of the following are true:

1. Serial mode remains the reference and is unchanged by default.
2. Parallel full rebuilds produce equivalent outputs to serial full rebuilds.
3. Worker-safe logs are in place.
4. The mode is documented as memory-sensitive.
5. Auto worker selection is conservative.
6. At least one real benchmark shows a meaningful wall-clock gain without destabilizing memory use.

## Suggested File-Level Worklist

Core implementation:

- `src/parallel.R` - new helper module
- [src/00_build_timeseries.R](../src/00_build_timeseries.R) - CLI flags, worker orchestration, revision worker extraction
- [src/logging.R](../src/logging.R) - worker-safe logging adjustments
- [src/install_dependencies.R](../src/install_dependencies.R) - optional backend packages

Downstream refactor:

- [src/09_daily_series.R](../src/09_daily_series.R) - baseline snapshot-first path and optional revision parallelism
- [src/08_weighted_etr.R](../src/08_weighted_etr.R) - snapshot-based lookup for policy dates

Documentation:

- [docs/build.md](build.md) - new flags and operational guidance
- [README.md](../README.md) - short note that parallel builds are available once implemented

## Open Questions

1. Should the first release support only `--full --parallel`, or should `--build-only --parallel` also be treated as the primary tested mode?
2. Should failed revisions prevent writing `rate_timeseries.rds`, or should the coordinator write a partial artifact with explicit metadata?
3. Is the current combined-timeseries artifact still required for every downstream consumer, or could some future modes rely entirely on snapshots plus interval metadata?

## Bottom Line

The best path forward is **not** "make every step parallel." It is:

1. parallelize **per-revision snapshot building**
2. keep shared outputs single-writer
3. move downstream work toward **snapshot-first** processing
4. treat worker count as a **memory** decision
5. keep the serial path intact as the safety baseline

That approach fits the current architecture, respects the repo's Windows support, and addresses the real bottleneck patterns already visible in the build and scenario logs.
