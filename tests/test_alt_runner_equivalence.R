# =============================================================================
# alt_runner mechanism smoke test
# =============================================================================
#
# Cheap, in-process checks that don't require real HTS data. Covers:
#   - resolve_parallel_config flag parsing + memory-aware defaults
#   - --parallel + --start-from incompatibility fallback
#   - alt_runner serial path: dispatches each spec, isolates failures,
#     writes per-alt log files, returns matching result records.
#   - .alt_runner_parallel future.globals shape: every name referenced
#     inside .run_one_alt is exported to the worker.
#
# Output-level equivalence between serial and the subprocess parallel path
# requires real snapshots and runs ~hours, so it is exercised by a Slurm
# job rather than this script.
#
# Usage:
#   bash -lc 'module load R/4.4.2-gfbf-2024a; Rscript tests/test_alt_runner_equivalence.R'
# =============================================================================

suppressPackageStartupMessages({
  library(here)
})

source(here('src', 'core', 'parallel.R'))

# -----------------------------------------------------------------------------
# Configuration resolution
# -----------------------------------------------------------------------------

cat('--- resolve_parallel_config ---\n')

cfg_off <- resolve_parallel_config(c())
stopifnot(isFALSE(cfg_off$parallel))
stopifnot(cfg_off$workers == 1L, cfg_off$alt_workers == 1L)

cfg_on <- resolve_parallel_config(c('--parallel', '--alt-workers', '2'),
                                  mem_gb = 192)
stopifnot(isTRUE(cfg_on$parallel))
stopifnot(cfg_on$alt_workers == 2L, cfg_on$backend == 'multisession')

cfg_incompat <- resolve_parallel_config(
  c('--parallel', '--start-from', 'rev_5'), mem_gb = 192)
stopifnot(isFALSE(cfg_incompat$parallel))
stopifnot(any(grepl('--start-from', cfg_incompat$notes)))

cfg_192 <- resolve_parallel_config(c('--parallel'), mem_gb = 192)
stopifnot(cfg_192$workers == 4L, cfg_192$alt_workers == 4L)

cfg_32 <- resolve_parallel_config(c('--parallel'), mem_gb = 32)
stopifnot(cfg_32$workers == 2L, cfg_32$alt_workers == 1L)

cat('  ok\n')

# -----------------------------------------------------------------------------
# alt_runner serial path
# -----------------------------------------------------------------------------

cat('\n--- alt_runner serial path ---\n')

# Override build_alternative_timeseries in this process. The serial path
# calls .run_one_alt with mode='inproc', which does NOT source any pipeline
# files, so this stub wins.
build_alternative_timeseries <- function(pp_override, variant, imports = NULL,
                                         policy_params = NULL) {
  message('Building alt: ', variant)
  if (identical(variant, 'fail_me')) stop('synthetic failure for ', variant)
  invisible(list(variant = variant, ok = TRUE))
}

specs <- list(
  list(variant = 'a_ok',    pp_override = list(tag = 'a')),
  list(variant = 'b_ok',    pp_override = list(tag = 'b')),
  list(variant = 'fail_me', pp_override = list(tag = 'c'))
)

log_dir <- tempfile(pattern = 'altrun_logs_')
dir.create(log_dir, recursive = TRUE)

res <- alt_runner(specs, alt_workers = 1L, log_dir = log_dir, imports = NULL)

stopifnot(length(res) == 3L)
variants <- vapply(res, function(r) r$variant, character(1))
statuses <- vapply(res, function(r) r$status,  character(1))
stopifnot(identical(variants, c('a_ok', 'b_ok', 'fail_me')))
stopifnot(identical(statuses, c('ok', 'ok', 'failed')))
stopifnot(file.exists(file.path(log_dir, 'alt_a_ok.log')))
stopifnot(file.exists(file.path(log_dir, 'alt_b_ok.log')))

cat('  ok: 3 specs, one isolated failure, per-alt logs written\n')

# -----------------------------------------------------------------------------
# .alt_runner_parallel future.globals shape
# -----------------------------------------------------------------------------
#
# The parallel path runs each spec in a fresh R process. Anything referenced
# inside .run_one_alt that is NOT defined by the worker's source() block must
# be exported via future.globals. Audit the call site by static inspection.

cat('\n--- alt_runner parallel path globals shape ---\n')

if (!parallel_backend_available()) {
  cat('  SKIP: future / future.apply not installed\n')
} else {
  body_text <- paste(deparse(body(.alt_runner_parallel)), collapse = '\n')
  globals_block <- regmatches(body_text,
                              regexpr('future\\.globals = list\\([^)]*\\)',
                                      body_text))
  stopifnot(length(globals_block) == 1L)

  # Names referenced inside .run_one_alt that are defined in parallel.R
  # (not in the pipeline source files the worker re-loads).
  required_globals <- c('.run_one_alt', '.with_alt_log',
                        'log_dir', 'imports', 'here_path')
  missing_globals <- required_globals[
    !vapply(required_globals,
            function(g) grepl(g, globals_block, fixed = TRUE),
            logical(1))
  ]
  if (length(missing_globals) > 0L) {
    stop('Missing names in future.globals: ',
         paste(missing_globals, collapse = ', '))
  }
  cat('  ok: all required names exported in future.globals\n')
}

cat('\nALL SMOKE-TEST ASSERTIONS PASSED\n')
cat('\nNote: end-to-end output equivalence between serial and\n')
cat('--parallel --alt-workers 2 requires real HTS snapshots and is\n')
cat('exercised by scripts/submit_alt_equivalence.sh, not this script.\n')
