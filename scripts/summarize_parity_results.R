#!/usr/bin/env Rscript
# =============================================================================
# summarize_parity_results.R — reduce node-parallel parity task outputs
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(dplyr)
  library(readr)
  library(tibble)
})

source(here('src', 'core', 'parity.R'))

`%||%` <- function(x, y) if (is.null(x)) y else x

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, default = NULL) {
  i <- which(args == flag)
  if (length(i) && i[1] < length(args)) args[i[1] + 1] else default
}

reference_root <- get_arg('--reference')
candidate_root <- get_arg('--candidate')
artifacts_arg  <- get_arg('--artifacts', 'snapshot,daily_overall,daily_by_authority,daily_by_country,daily_by_category')
manifest_path  <- get_arg('--manifest')
results_dir    <- get_arg('--results-dir')

if (is.null(reference_root)) stop('--reference <model_data vintage-or-series> is required', call. = FALSE)
if (is.null(candidate_root)) stop('--candidate <model_data vintage-or-series> is required', call. = FALSE)
if (is.null(manifest_path)) stop('--manifest <external-work-path> is required', call. = FALSE)
if (is.null(results_dir)) stop('--results-dir <external-work-dir> is required', call. = FALSE)

kinds <- strsplit(artifacts_arg, ',')[[1]]
reference_root <- resolve_model_data_series(reference_root)
candidate_root <- resolve_model_data_series(candidate_root)

cat('=== Parity summary ===\n')
cat("Reference: ", reference_root, "\n", sep = "")
cat('Candidate: ', candidate_root, '\n', sep = '')
cat('Results:   ', results_dir, '\n\n', sep = '')

manifest <- readr::read_tsv(manifest_path, show_col_types = FALSE, progress = FALSE)
result_files <- sort(list.files(results_dir, pattern = '^task_[0-9]{4}\\.tsv$', full.names = TRUE))
task_results <- if (length(result_files)) bind_rows(lapply(result_files, function(p) read_tsv(p, show_col_types = FALSE, progress = FALSE))) else tibble()

missing_tasks <- setdiff(seq_len(nrow(manifest)) - 1L, task_results$index %||% integer())
if (length(missing_tasks)) {
  cat('  [ERR] Missing task result(s): ', paste(missing_tasks, collapse = ', '), '\n', sep = '')
}

overall_fail <- length(missing_tasks) > 0

for (kind in kinds) {
  spec <- PARITY_ARTIFACTS[[kind]]
  if (is.null(spec)) next
  gfiles <- list_parity_artifacts(reference_root, kind)
  cfiles <- list_parity_artifacts(candidate_root, kind)
  only_g <- setdiff(names(gfiles), names(cfiles))
  only_c <- setdiff(names(cfiles), names(gfiles))
  if (length(only_g)) {
    overall_fail <- TRUE
    for (f in only_g) cat(sprintf('  [%s] MISSING from candidate: %s\n', kind, f))
  }
  if (length(only_c)) {
    overall_fail <- TRUE
    for (f in only_c) cat(sprintf('  [%s] EXTRA in candidate:    %s\n', kind, f))
  }
}

if (nrow(task_results)) {
  for (i in seq_len(nrow(task_results))) {
    r <- task_results[i, ]
    if (isTRUE(r$pass)) {
      cat(sprintf('  [OK]   %-28s %d rows\n', r$label, r$n_rows_common))
    } else {
      overall_fail <- TRUE
      if (nzchar(r$error[[1]])) {
        cat(sprintf('  [ERR]  %-28s %s\n', r$label, r$error[[1]]))
      } else {
        cat(sprintf('  [FAIL] %-28s %d violation(s)\n', r$label, r$n_violations))
      }
    }
  }
}

expected_tasks <- nrow(manifest)
actual_tasks <- nrow(task_results)
passed_tasks <- sum(task_results$pass %in% TRUE, na.rm = TRUE)
failed_tasks <- sum(task_results$pass %in% FALSE, na.rm = TRUE) + length(missing_tasks)

cat('\n=== Summary ===\n')
cat(sprintf('  artifact tasks: %d | passed: %d | failed: %d\n',
            expected_tasks, passed_tasks, failed_tasks))
ignored <- unique(setdiff(task_results$ignored_cols %||% character(), ''))
if (length(ignored)) {
  cat('  NOTE: value comparison ignored column(s): ', paste(ignored, collapse = ' | '),
      ' — this is NOT a clean pass; the exclusions must be justified in the run notes.\n', sep = '')
}

if (overall_fail || passed_tasks != expected_tasks) {
  quit(status = 1)
}
cat('  ALL ARTIFACTS WITHIN TOLERANCE\n')
quit(status = 0)
