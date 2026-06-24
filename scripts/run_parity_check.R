#!/usr/bin/env Rscript
# =============================================================================
# run_parity_check.R — compare a candidate build against the reference build
# =============================================================================
#
# The parity gate. Compares every artifact (snapshots, combined timeseries,
# daily CSVs) of a candidate build against a REFERENCE build — by default the
# latest published vintage (<model_data_root>/latest) — using the tolerance
# comparator in src/parity.R, and exits non-zero on any drift.
#
# Layouts (auto-detected per side):
#   vintage — a published vintage: daily CSVs in <root>/actual/daily,
#             snapshots (hive-partitioned parquet) in <root>/actual/snapshots
#             (this is <model_data_root>/latest or any dated vintage)
#   live    — a working repo: snapshots in <root>/data/timeseries,
#             daily CSVs in <root>/output/actual/daily
#   flat    — snapshots + rate_timeseries.rds at <root>, daily CSVs in <root>/daily
#
# Usage:
#   Rscript scripts/run_parity_check.R                       # candidate=cwd vs latest
#   Rscript scripts/run_parity_check.R --reference <dir> --candidate <dir>
#   Rscript scripts/run_parity_check.R --reference <dir> --artifacts daily_overall
#
# Exit code: 0 = all within tolerance; 1 = at least one violation (or setup error).
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(dplyr)
  library(readr)
})

source(here('src', 'parity.R'))
source(here('src', 'policy_params.R'))   # load_local_paths() -> model_data_root

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, default = NULL) {
  i <- which(args == flag)
  if (length(i) && i[1] < length(args)) args[i[1] + 1] else default
}

# Reference = the latest published vintage by default (<model_data_root>/latest).
default_reference <- local({
  r <- tryCatch(load_local_paths()$model_data_root, error = function(e) NULL)
  if (is.null(r) || !nzchar(r)) NULL else file.path(r, 'latest')
})
reference_root <- get_arg('--reference', get_arg('--golden', default_reference))  # --golden is an alias for --reference
candidate_root <- get_arg('--candidate', here())
# Default to the daily series — the consumable a published vintage carries.
# (A vintage stores snapshots as partitioned parquet, not snapshot_*.rds, so
# snapshot/timeseries parity only applies between two rds builds; request it
# explicitly with --artifacts snapshot,timeseries when both sides are rds.)
artifacts_arg  <- get_arg('--artifacts', 'daily_overall,daily_by_authority,daily_by_country,daily_by_category')

if (is.null(reference_root)) stop('--reference <dir> required (model_data_root/latest not resolvable)', call. = FALSE)
if (!dir.exists(reference_root)) stop('reference dir not found: ', reference_root, call. = FALSE)
kinds <- strsplit(artifacts_arg, ',')[[1]]

# Resolve where snapshots and daily CSVs live for a given root (vintage / live / flat).
resolve_build_dirs <- function(root) {
  # Published vintage: <root>/actual/{daily,snapshots}.
  if (dir.exists(file.path(root, 'actual', 'daily'))) {
    return(list(ts_dir = file.path(root, 'actual', 'snapshots'),
                daily_dir = file.path(root, 'actual', 'daily')))
  }
  # Live working repo.
  if (dir.exists(file.path(root, 'data', 'timeseries'))) {
    return(list(ts_dir = file.path(root, 'data', 'timeseries'),
                daily_dir = file.path(root, 'output', 'actual', 'daily')))
  }
  # Flat layout: snapshots + rate_timeseries.rds + daily/ all under <root>.
  list(ts_dir = root, daily_dir = file.path(root, 'daily'))
}

# An artifact kind lives in either the daily tree or the timeseries tree.
artifact_dir_for <- function(dirs, kind) {
  if (grepl('^daily', kind)) dirs$daily_dir else dirs$ts_dir
}

gd <- resolve_build_dirs(reference_root)
cd <- resolve_build_dirs(candidate_root)

cat('=== Parity check ===\n')
cat('Reference: ', reference_root, '  (ts:', gd$ts_dir, ')\n')
cat('Candidate: ', candidate_root, '  (ts:', cd$ts_dir, ')\n')
cat('Artifacts: ', paste(kinds, collapse = ', '), '\n\n')

# ---- pair files per artifact kind and compare ----
results <- list()
pair_and_compare <- function(kind, gfiles, cfiles, ts) {
  gnames <- basename(gfiles); names(gfiles) <- gnames
  cnames <- basename(cfiles); names(cfiles) <- cnames
  shared <- intersect(gnames, cnames)
  only_g <- setdiff(gnames, cnames); only_c <- setdiff(cnames, gnames)
  for (f in only_g) cat(sprintf('  [%s] MISSING from candidate: %s\n', kind, f))
  for (f in only_c) cat(sprintf('  [%s] EXTRA in candidate:    %s\n', kind, f))
  compared <- lapply(shared, function(f) {
    res <- tryCatch(
      compare_parity_files(cfiles[[f]], gfiles[[f]], kind, label = paste0(kind, ':', f)),
      error = function(e) list(label = paste0(kind, ':', f), pass = FALSE,
                               n_violations = NA, n_rows_common = NA,
                               violations = NULL, error = conditionMessage(e)))
    line <- if (isTRUE(res$pass)) {
      sprintf('  [OK]   %-28s %d rows\n', res$label, res$n_rows_common)
    } else if (!is.null(res$error)) {
      sprintf('  [ERR]  %-28s %s\n', res$label, res$error)
    } else {
      sprintf('  [FAIL] %-28s %d violation(s)\n', res$label, res$n_violations)
    }
    list(file = f, result = res, line = line)
  })

  out <- list()
  for (x in compared) {
    cat(x$line)
    out[[x$file]] <- x$result
  }
  # Record a synthetic failure for unmatched files too.
  if (length(only_g) || length(only_c)) {
    out[['__file_set__']] <- list(label = paste0(kind, ':file-set'), pass = FALSE,
                                  n_violations = length(only_g) + length(only_c))
  }
  out
}

for (kind in kinds) {
  spec <- PARITY_ARTIFACTS[[kind]]
  if (is.null(spec)) { cat('  (skip unknown artifact kind: ', kind, ')\n'); next }
  dir_g <- artifact_dir_for(gd, kind)
  dir_c <- artifact_dir_for(cd, kind)
  gfiles <- list.files(dir_g, pattern = utils::glob2rx(spec$glob), full.names = TRUE)
  cfiles <- list.files(dir_c, pattern = utils::glob2rx(spec$glob), full.names = TRUE)
  if (length(gfiles) == 0 && length(cfiles) == 0) next
  cat(sprintf('--- %s (%d reference / %d candidate files) ---\n', kind, length(gfiles), length(cfiles)))
  results[[kind]] <- pair_and_compare(kind, gfiles, cfiles)
}

# ---- summary ----
flat <- unlist(results, recursive = FALSE)
n_total <- length(flat)
n_fail  <- sum(vapply(flat, function(r) !isTRUE(r$pass), logical(1)))
cat('\n=== Summary ===\n')
cat(sprintf('  artifacts compared: %d | passed: %d | failed: %d\n',
            n_total, n_total - n_fail, n_fail))

if (n_fail > 0) {
  cat('\n--- Failure detail (first few per artifact) ---\n')
  for (r in flat) {
    if (!isTRUE(r$pass) && !is.null(r$violations)) {
      cat(format_parity_report(r, max_show = 12), '\n\n')
    }
  }
  quit(status = 1)
}
cat('  ALL ARTIFACTS WITHIN TOLERANCE\n')
quit(status = 0)
