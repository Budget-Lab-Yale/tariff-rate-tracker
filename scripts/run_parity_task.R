#!/usr/bin/env Rscript
# =============================================================================
# run_parity_task.R — compare one parity file pair
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(readr)
  library(tibble)
})

source(here('src', 'core', 'parity.R'))

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, default = NULL) {
  i <- which(args == flag)
  if (length(i) && i[1] < length(args)) args[i[1] + 1] else default
}

manifest_path <- get_arg('--manifest')
task_index    <- suppressWarnings(as.integer(get_arg('--index')))
results_dir   <- get_arg('--results-dir', file.path('output', 'parity_results'))

if (is.null(manifest_path)) stop('--manifest <path> is required', call. = FALSE)
if (is.na(task_index) || task_index < 0) stop('--index <0-based task index> is required', call. = FALSE)

manifest <- readr::read_tsv(manifest_path, show_col_types = FALSE, progress = FALSE)
row_idx <- task_index + 1L
if (row_idx < 1L || row_idx > nrow(manifest)) {
  stop('task index out of range: ', task_index, ' (manifest rows=', nrow(manifest), ')', call. = FALSE)
}

task <- manifest[row_idx, ]
result <- tryCatch(
  compare_parity_files(task$candidate_path[[1]], task$reference_path[[1]], task$kind[[1]], label = task$label[[1]]),
  error = function(e) list(
    label = task$label[[1]], pass = FALSE, n_violations = NA_integer_,
    n_rows_common = NA_integer_, violations = NULL, error = conditionMessage(e)
  )
)

line <- if (isTRUE(result$pass)) {
  sprintf('[OK]   %-28s %d rows\n', result$label, result$n_rows_common)
} else if (!is.null(result$error)) {
  sprintf('[ERR]  %-28s %s\n', result$label, result$error)
} else {
  sprintf('[FAIL] %-28s %d violation(s)\n', result$label, result$n_violations)
}
cat(line)

dir.create(results_dir, recursive = TRUE, showWarnings = FALSE)
out <- tibble(
  index = task_index,
  kind = task$kind[[1]],
  file = task$file[[1]],
  label = task$label[[1]],
  pass = isTRUE(result$pass),
  n_violations = if (is.null(result$n_violations)) NA_integer_ else as.integer(result$n_violations),
  n_rows_common = if (is.null(result$n_rows_common)) NA_integer_ else as.integer(result$n_rows_common),
  error = if (is.null(result$error)) '' else as.character(result$error)
)
write_tsv(out, file.path(results_dir, sprintf('task_%04d.tsv', task_index)))

quit(status = if (isTRUE(result$pass)) 0 else 1)
