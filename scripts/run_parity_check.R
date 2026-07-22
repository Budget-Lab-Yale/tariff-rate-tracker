#!/usr/bin/env Rscript
# =============================================================================
# run_parity_check.R — compare a candidate build against the reference build
# =============================================================================
#
# The parity gate. Compares every published snapshot and daily artifact of a
# candidate model_data series against a reference series and exits non-zero on
# any drift.
#
# Both paths must be model_data vintages or published series directories. No
# repository-local, flat-file, or legacy golden layouts are supported.
#
# Usage:
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

source(here('src', 'core', 'parity.R'))

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, default = NULL) {
  i <- which(args == flag)
  if (length(i) && i[1] < length(args)) args[i[1] + 1] else default
}

reference_root <- get_arg('--reference')
candidate_root <- get_arg('--candidate')
artifacts_arg  <- get_arg('--artifacts', 'snapshot,daily_overall,daily_by_authority,daily_by_country,daily_by_category')

if (is.null(reference_root)) stop('--reference <model_data vintage-or-series> is required', call. = FALSE)
if (is.null(candidate_root)) stop('--candidate <model_data vintage-or-series> is required', call. = FALSE)
kinds <- strsplit(artifacts_arg, ',')[[1]]
reference_root <- resolve_model_data_series(reference_root)
candidate_root <- resolve_model_data_series(candidate_root)

cat('=== Parity check ===\n')
cat('Reference: ', reference_root, '\n')
cat('Candidate: ', candidate_root, '\n')
cat('Artifacts: ', paste(kinds, collapse = ', '), '\n\n')

# ---- pair files per artifact kind and compare ----
results <- list()
pair_and_compare <- function(kind, gfiles, cfiles) {
  shared <- intersect(names(gfiles), names(cfiles))
  only_g <- setdiff(names(gfiles), names(cfiles)); only_c <- setdiff(names(cfiles), names(gfiles))
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
  gfiles <- list_parity_artifacts(reference_root, kind)
  cfiles <- list_parity_artifacts(candidate_root, kind)
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
