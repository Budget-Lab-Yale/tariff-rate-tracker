# =============================================================================
# Parallel execution helper module
# =============================================================================
#
# Phase 0/1 scaffolding for the parallel pipeline. Provides:
#
#   resolve_parallel_config(args, mem_gb = NULL)
#       Parses --parallel / --workers / --alt-workers / --backend out of an
#       argv-style character vector and resolves them against a memory-aware
#       default table. Returns a list with named slots; fields are always
#       populated (workers/alt_workers are 1 in serial mode).
#
#   log_parallel_config(cfg)
#       Pretty-prints the resolved config to message() and the active log.
#
#   alt_runner(alt_specs, alt_workers, log_dir, runner_fn = NULL)
#       Runs a list of alternative-build specs. When alt_workers <= 1 (or the
#       optional 'future'/'callr' packages aren't available), falls back to a
#       serial loop that matches today's behavior. When alt_workers > 1 and
#       the backend is available, spawns concurrent worker processes via
#       future::plan(multisession). Each spec produces its own log file
#       (alt_<variant>_<jobid>.log) under log_dir.
#
#   parallel_lapply_revisions(...)
#       Phase 3 stub. Currently always falls back to serial lapply with a
#       deprecation-style notice. Keeps the call site stable so Phase 3 can
#       drop in the parallel implementation without touching callers.
#
# Design notes:
#
#   - Cross-platform default: future + multisession (PSOCK). `multicore`
#     (fork) is opt-in via --backend multicore on Linux.
#   - Optional deps: future, future.apply, parallelly, callr. When missing,
#     callers degrade to serial with a clear message — never an error.
#   - Memory detection prefers SLURM_MEM_PER_NODE / SLURM_MEM_PER_CPU (set by
#     the harness) over /proc/meminfo so the resolver respects the cgroup
#     allocation, not the node's physical RAM.
#   - Workers and alt_workers are independent caps. The default resolver
#     returns one or the other, never the product, so we don't fanout.
#
# =============================================================================


# -----------------------------------------------------------------------------
# Memory detection
# -----------------------------------------------------------------------------

#' Detect available memory in GB
#'
#' Prefers Slurm environment variables (SLURM_MEM_PER_NODE in MB,
#' SLURM_MEM_PER_CPU * SLURM_CPUS_PER_TASK in MB), then falls back to
#' /proc/meminfo MemTotal on Linux. Returns NA_real_ if nothing is detectable
#' (Windows / macOS without /proc).
#'
#' @return Numeric memory in GB, or NA_real_
detect_memory_gb <- function() {
  slurm_mem <- Sys.getenv('SLURM_MEM_PER_NODE', unset = '')
  if (nzchar(slurm_mem) && grepl('^[0-9]+$', slurm_mem)) {
    return(as.numeric(slurm_mem) / 1024)
  }

  slurm_per_cpu <- Sys.getenv('SLURM_MEM_PER_CPU', unset = '')
  slurm_cpus <- Sys.getenv('SLURM_CPUS_PER_TASK', unset = '')
  if (nzchar(slurm_per_cpu) && grepl('^[0-9]+$', slurm_per_cpu) &&
      nzchar(slurm_cpus) && grepl('^[0-9]+$', slurm_cpus)) {
    return((as.numeric(slurm_per_cpu) * as.numeric(slurm_cpus)) / 1024)
  }

  if (file.exists('/proc/meminfo')) {
    lines <- readLines('/proc/meminfo', n = 5L, warn = FALSE)
    mt <- grep('^MemTotal:', lines, value = TRUE)
    if (length(mt) == 1L) {
      kb <- as.numeric(sub('^MemTotal:\\s+([0-9]+)\\s+kB.*$', '\\1', mt))
      if (is.finite(kb)) return(kb / 1024 / 1024)
    }
  }

  NA_real_
}


# -----------------------------------------------------------------------------
# Worker-count defaults (memory-aware)
# -----------------------------------------------------------------------------

#' Default revision-worker count for a given memory ceiling
#'
#' Conservative by design — the build is memory-bound, so this caps lower
#' than CPU count would suggest. Returns 1 (serial) when memory is unknown
#' or below 32 GB.
#'
#' @param mem_gb Numeric, available memory in GB (or NA)
#' @return Integer worker count >= 1
default_revision_workers <- function(mem_gb) {
  if (is.null(mem_gb) || !is.finite(mem_gb)) return(1L)
  if (mem_gb < 32)  return(1L)
  if (mem_gb < 64)  return(2L)
  if (mem_gb < 128) return(3L)
  4L
}


#' Default concurrent-alternative count for a given memory ceiling
#'
#' Each rebuild alternative peaks around ~30-40 GB at the largest 2026
#' revisions (4.7M product-country pairs in memory). Cap by memory, not by
#' alt count — caller passes n_alts to clamp.
#'
#' @param mem_gb Numeric, available memory in GB (or NA)
#' @param n_alts Integer, number of alternatives to potentially run
#' @return Integer alt-worker count >= 1
default_alt_workers <- function(mem_gb, n_alts = 6L) {
  if (is.null(mem_gb) || !is.finite(mem_gb)) return(1L)
  by_mem <- if (mem_gb < 32)  1L
            else if (mem_gb < 64)  1L
            else if (mem_gb < 128) 2L
            else if (mem_gb < 192) 3L
            else 4L
  as.integer(min(by_mem, n_alts))
}


# -----------------------------------------------------------------------------
# CLI arg parsing
# -----------------------------------------------------------------------------

#' Resolve parallel configuration from CLI args + environment
#'
#' Parses an argv-style character vector for --parallel, --workers,
#' --alt-workers, --backend. Validates against safe bounds. Falls back to
#' serial when a flag is malformed (with a message), never errors out.
#'
#' Recognized flags:
#'   --parallel             enable parallel mode (otherwise serial)
#'   --workers N            override revision-worker count
#'   --alt-workers M        override concurrent-alternative count
#'   --backend B            'multisession' (default) or 'multicore' (Linux only)
#'
#' Special-case interactions:
#'   --parallel + --start-from
#'     Phase 1 does not support parallel + incremental; resolver clears the
#'     parallel flag and emits a notice. Caller still owns the start_from
#'     value.
#'
#' @param args Character vector (typically commandArgs(trailingOnly = TRUE))
#' @param mem_gb Optional override for testing; otherwise calls detect_memory_gb()
#' @param n_alts Number of alternatives planned (used to cap alt_workers default)
#' @return Named list:
#'   parallel       logical; TRUE iff --parallel was passed and accepted
#'   workers        integer revision-worker count (1 = serial)
#'   alt_workers    integer concurrent-alternative count (1 = serial)
#'   backend        'multisession' or 'multicore'
#'   mem_gb         numeric memory ceiling used for defaults (or NA)
#'   start_from     character or NULL — copied through for the message above
#'   notes          character vector of resolver messages worth surfacing
resolve_parallel_config <- function(args = character(0),
                                     mem_gb = NULL,
                                     n_alts = 6L) {
  notes <- character(0)
  if (is.null(mem_gb)) mem_gb <- detect_memory_gb()

  parallel_on <- '--parallel' %in% args

  start_from <- NULL
  for (i in seq_along(args)) {
    if (args[i] == '--start-from' && i < length(args)) {
      start_from <- args[i + 1]
    }
  }

  workers_arg <- .extract_int_arg(args, '--workers')
  alt_workers_arg <- .extract_int_arg(args, '--alt-workers')

  backend <- 'multisession'
  for (i in seq_along(args)) {
    if (args[i] == '--backend' && i < length(args)) {
      cand <- args[i + 1]
      if (cand %in% c('multisession', 'multicore')) {
        backend <- cand
      } else {
        notes <- c(notes,
                   sprintf("--backend '%s' not recognized; using 'multisession'",
                           cand))
      }
    }
  }

  if (backend == 'multicore' && .Platform$OS.type != 'unix') {
    notes <- c(notes, "--backend multicore is Unix-only; using 'multisession'")
    backend <- 'multisession'
  }

  if (parallel_on && !is.null(start_from)) {
    notes <- c(notes,
      paste('--parallel is not yet supported with --start-from (Phase 1).',
            'Falling back to serial build for this run.'))
    parallel_on <- FALSE
  }

  if (parallel_on) {
    workers <- if (!is.null(workers_arg)) workers_arg
               else default_revision_workers(mem_gb)
    alt_workers <- if (!is.null(alt_workers_arg)) alt_workers_arg
                   else default_alt_workers(mem_gb, n_alts)
  } else {
    workers <- 1L
    alt_workers <- if (!is.null(alt_workers_arg) && alt_workers_arg > 1L) {
      notes <- c(notes,
        '--alt-workers > 1 ignored without --parallel; using serial alternatives')
      1L
    } else {
      1L
    }
  }

  workers <- max(1L, as.integer(workers))
  alt_workers <- max(1L, as.integer(alt_workers))

  list(
    parallel    = parallel_on,
    workers     = workers,
    alt_workers = alt_workers,
    backend     = backend,
    mem_gb      = mem_gb,
    start_from  = start_from,
    notes       = notes
  )
}


.extract_int_arg <- function(args, flag) {
  for (i in seq_along(args)) {
    if (args[i] == flag && i < length(args)) {
      v <- suppressWarnings(as.integer(args[i + 1]))
      if (!is.na(v) && v >= 1L) return(v)
    }
  }
  NULL
}


# -----------------------------------------------------------------------------
# Logging the resolved config
# -----------------------------------------------------------------------------

#' Log the resolved parallel configuration
#'
#' Emits one block to message() and the structured log (via log_info if
#' available). Safe to call before logging is initialized — degrades to
#' message() only.
#'
#' @param cfg List from resolve_parallel_config()
#' @return Invisible cfg
log_parallel_config <- function(cfg) {
  has_log <- exists('log_info', mode = 'function')

  emit <- function(msg) {
    message(msg)
    if (has_log) try(log_info(msg), silent = TRUE)
  }

  emit('--- Parallel configuration ---')
  emit(sprintf('  parallel:    %s', if (isTRUE(cfg$parallel)) 'on' else 'off (serial)'))
  emit(sprintf('  workers:     %d', cfg$workers))
  emit(sprintf('  alt_workers: %d', cfg$alt_workers))
  emit(sprintf('  backend:     %s', cfg$backend))
  emit(sprintf('  memory:      %s GB',
               if (is.finite(cfg$mem_gb)) format(round(cfg$mem_gb, 1)) else 'unknown'))
  for (n in cfg$notes) emit(sprintf('  note: %s', n))
  emit('-----------------------------')
  invisible(cfg)
}


# -----------------------------------------------------------------------------
# Alt runner
# -----------------------------------------------------------------------------

#' Check whether the parallel backend is actually usable
#'
#' Returns TRUE only if 'future' and 'future.apply' are installed.
#'
#' @return Logical
parallel_backend_available <- function() {
  requireNamespace('future', quietly = TRUE) &&
    requireNamespace('future.apply', quietly = TRUE)
}


#' Run a list of alternative-build specs, possibly concurrently
#'
#' Each spec is a list with at least:
#'   variant        character — variant name (e.g., 'usmca_annual')
#'   pp_override    list — full policy_params with the variant's overrides
#'                  applied; passed to build_alternative_timeseries()
#'
#' The runner:
#'   - When alt_workers <= 1, runs sequentially.
#'   - When alt_workers > 1 and the backend is available, sets up
#'     future::plan(multisession, workers = alt_workers) and dispatches
#'     each spec to a worker process. Each worker sources the pipeline,
#'     opens its own log file, and calls build_alternative_timeseries().
#'
#' Worker logs land at:
#'   <log_dir>/alt_<variant>.log
#'
#' @param alt_specs List of spec lists
#' @param alt_workers Integer concurrent worker cap (1 = serial)
#' @param log_dir Directory for per-alt log files (created if missing)
#' @param imports Tibble of import weights (passed to each alt) or NULL
#' @return List of result records: variant, status ('ok'/'failed'), error
alt_runner <- function(alt_specs, alt_workers = 1L, log_dir = NULL,
                        imports = NULL) {
  alt_workers <- max(1L, as.integer(alt_workers))
  if (length(alt_specs) == 0L) return(list())

  if (!is.null(log_dir)) {
    dir.create(log_dir, recursive = TRUE, showWarnings = FALSE)
  }

  serial <- alt_workers <= 1L || !parallel_backend_available()

  if (!serial) {
    message(sprintf('Running %d alternatives across %d concurrent workers...',
                    length(alt_specs), alt_workers))
    return(.alt_runner_parallel(alt_specs, alt_workers, log_dir, imports))
  }

  if (alt_workers > 1L) {
    message('alt_runner: future/future.apply not installed; ',
            'running alternatives sequentially. ',
            'Install with: Rscript tools/install_dependencies.R --all')
  } else {
    message(sprintf('Running %d alternatives sequentially...',
                    length(alt_specs)))
  }
  .alt_runner_serial(alt_specs, log_dir, imports)
}


.alt_runner_serial <- function(alt_specs, log_dir, imports) {
  results <- vector('list', length(alt_specs))
  for (i in seq_along(alt_specs)) {
    spec <- alt_specs[[i]]
    results[[i]] <- .run_one_alt(spec, log_dir, imports, mode = 'inproc')
  }
  results
}


.alt_runner_parallel <- function(alt_specs, alt_workers, log_dir, imports) {
  old_plan <- future::plan(future::multisession, workers = alt_workers)
  on.exit(future::plan(old_plan), add = TRUE)

  here_path <- here()

  future.apply::future_lapply(
    alt_specs,
    function(spec) {
      Sys.setenv(OPENBLAS_NUM_THREADS = '1',
                 OMP_NUM_THREADS = '1',
                 MKL_NUM_THREADS = '1')
      setwd(here_path)
      .run_one_alt(spec, log_dir, imports, mode = 'subprocess')
    },
    future.seed = TRUE,
    future.globals = list(
      .run_one_alt = .run_one_alt,
      .with_alt_log = .with_alt_log,
      log_dir = log_dir,
      imports = imports,
      here_path = here_path
    ),
    future.packages = c('here')
  )
}


#' Execute a single alt spec
#'
#' Used by both serial and parallel paths. In subprocess mode, sources the
#' pipeline files itself (the worker R process is fresh and has nothing
#' loaded). In inproc mode, assumes the caller has already sourced them.
#'
#' Routes the alt's message() output to a per-alt log file when log_dir is
#' provided.
.run_one_alt <- function(spec, log_dir, imports, mode = c('inproc', 'subprocess')) {
  mode <- match.arg(mode)
  variant <- spec$variant

  if (mode == 'subprocess') {
    suppressPackageStartupMessages({
      library(here)
      library(tidyverse)
      library(jsonlite)
    })
    source(here('src', 'core', 'logging.R'))
    source(here('src', 'core', 'helpers.R'))
    source(here('src', 'pipeline', '03_parse_chapter99.R'))
    source(here('src', 'pipeline', '04_parse_products.R'))
    source(here('src', 'pipeline', '05_parse_policy_params.R'))
    source(here('src', 'pipeline', '06_calculate_rates.R'))
    source(here('src', 'model', 'authority_spec.R'))
    source(here('src', 'model', 'authority_adapter.R'))
    source(here('src', 'pipeline', 'revision_snapshot.R'))
    source(here('src', 'pipeline', '09_daily_series.R'))
  }

  log_path <- if (!is.null(log_dir)) {
    file.path(log_dir, paste0('alt_', variant, '.log'))
  } else NULL

  if (!is.null(log_path) && exists('init_logging', mode = 'function')) {
    try(init_logging(log_path, level = 'info'), silent = TRUE)
  }

  tryCatch({
    .with_alt_log(log_path, {
      build_alternative_timeseries(
        spec$pp_override, variant,
        imports = imports
      )
    })
    list(variant = variant, status = 'ok', error = NULL)
  }, error = function(e) {
    msg <- conditionMessage(e)
    if (!is.null(log_path)) {
      try(cat(sprintf('[FAILED] %s\n', msg), file = log_path, append = TRUE),
          silent = TRUE)
    }
    message(sprintf('  FAILED (%s): %s', variant, msg))
    list(variant = variant, status = 'failed', error = msg)
  })
}


#' Send message() output from `expr` to `log_path` (and the console).
#'
#' Subprocess workers don't share the parent's log file. This wrapper
#' captures message()s from build_alternative_timeseries() and friends to
#' the per-alt log so they don't get lost.
.with_alt_log <- function(log_path, expr) {
  if (is.null(log_path)) return(force(expr))
  withCallingHandlers(
    expr,
    message = function(m) {
      try(cat(conditionMessage(m), file = log_path, append = TRUE),
          silent = TRUE)
    }
  )
}


# -----------------------------------------------------------------------------
# Phase 3 stub
# -----------------------------------------------------------------------------

#' Per-revision parallelism for within-node builds.
#'
#' Applies `fn` to each revision id, concurrently when `workers > 1` and a
#' future backend is available, serially otherwise (byte-identical to a plain
#' lapply). Revisions are independent, so this is a clean fan-out.
#'
#' Backend note: on Linux we prefer `multicore` (fork) — forked workers inherit
#' the parent's already-sourced pipeline, so `fn` (e.g. build_revision_snapshot)
#' and all its helpers are available with no globals export. `multisession`
#' (PSOCK) workers do NOT inherit the pipeline and would need to re-source it;
#' for the full cluster build prefer the Slurm **array** path
#' (scripts/submit_build_array.sh), which runs each revision as its own process
#' that sources the pipeline itself and sidesteps the single-node memory ceiling.
#'
#' @param rev_ids character vector of revision ids
#' @param fn function(rev_id, ...) -> result; side-effects (snapshot writes) are fine
#' @param workers integer worker cap (1 = serial)
#' @param backend 'multicore' (Linux fork, default) or 'multisession'
#' @return list of fn() results, one per rev_id (order preserved)
parallel_lapply_revisions <- function(rev_ids, fn, workers = 1L,
                                      backend = 'multicore', ...) {
  workers <- max(1L, as.integer(workers))
  if (workers <= 1L || !parallel_backend_available()) {
    if (workers > 1L) {
      message('parallel_lapply_revisions: future/future.apply not installed; ',
              'running ', length(rev_ids), ' revisions serially.')
    }
    return(lapply(rev_ids, function(r) fn(r, ...)))
  }

  use_fork <- backend == 'multicore' && .Platform$OS.type == 'unix'
  if (!use_fork) {
    message('parallel_lapply_revisions: multisession workers do not inherit the ',
            'sourced pipeline; prefer --backend multicore (Linux) or the Slurm array.')
  }
  plan_fn <- if (use_fork) future::multicore else future::multisession
  old_plan <- future::plan(plan_fn, workers = workers)
  on.exit(future::plan(old_plan), add = TRUE)

  message(sprintf('parallel_lapply_revisions: %d revisions across %d %s worker(s)...',
                  length(rev_ids), workers, if (use_fork) 'fork' else 'PSOCK'))
  future.apply::future_lapply(
    rev_ids,
    function(r) {
      # Keep each worker single-threaded so concurrent workers don't oversubscribe.
      Sys.setenv(OPENBLAS_NUM_THREADS = '1', OMP_NUM_THREADS = '1', MKL_NUM_THREADS = '1')
      fn(r, ...)
    },
    future.seed = TRUE
  )
}
