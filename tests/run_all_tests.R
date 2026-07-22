#!/usr/bin/env Rscript

# =============================================================================
# Discover and run every repository test in an isolated R process.
# =============================================================================
# Usage:
#   Rscript tests/run_all_tests.R
#   Rscript tests/run_all_tests.R --list

suppressPackageStartupMessages(library(here))

args <- commandArgs(trailingOnly = TRUE)
tests_dir <- here('tests')
files <- c(
  list.files(tests_dir, pattern = '^test_.*[.]R$', full.names = TRUE),
  list.files(tests_dir, pattern = '^run_tests_.*[.]R$', full.names = TRUE)
)
files <- sort(unique(files))

if ('--list' %in% args) {
  cat(paste(basename(files), collapse = '\n'), '\n')
  quit(status = 0L)
}

# Optional dependencies used by only a small subset of tests. The runner still
# discovers these files and names the missing package rather than omitting them.
requirements <- list(
  test_panel_import_weights.R = 'arrow',
  test_publish_snapshots.R = 'arrow'
)

rscript <- file.path(R.home('bin'), 'Rscript')
passed <- character()
passed_with_skips <- character()
failed <- character()
skipped <- character()
started <- Sys.time()

cat('Discovered ', length(files), ' test files.\n\n', sep = '')

for (file in files) {
  name <- basename(file)
  needed <- requirements[[name]]
  missing <- needed[!vapply(needed, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing) > 0) {
    cat('SKIP  ', name, ' (missing optional package: ',
        paste(missing, collapse = ', '), ')\n', sep = '')
    skipped <- c(skipped, name)
    next
  }

  log_path <- tempfile(pattern = paste0(name, '-'), fileext = '.log')
  status <- system2(rscript, file, stdout = log_path, stderr = log_path)
  output <- readLines(log_path, warn = FALSE)
  unlink(log_path)

  if (identical(status, 0L)) {
    skip_output <- unique(output[
      grepl('\\bSKIP(?::|\\s*\\()', output, perl = TRUE) |
        grepl('\\b[1-9][0-9]* skipped\\b', output, perl = TRUE) |
        grepl('Skipping artifact-dependent tests', output, fixed = TRUE)
    ])
    if (length(skip_output)) {
      cat('PASS* ', name, ' (contains skipped checks)\n', sep = '')
      cat(paste0('      ', utils::head(skip_output, 3L)), sep = '\n')
      cat('\n')
      passed_with_skips <- c(passed_with_skips, name)
    } else {
      cat('PASS  ', name, '\n', sep = '')
    }
    passed <- c(passed, name)
  } else {
    cat('FAIL  ', name, '\n', sep = '')
    if (length(output) > 0) {
      cat(paste(utils::tail(output, 60L), collapse = '\n'), '\n')
    }
    failed <- c(failed, name)
  }
}

elapsed <- round(as.numeric(difftime(Sys.time(), started, units = 'mins')), 1)
cat('\n', strrep('=', 68), '\n', sep = '')
cat('Test files: ', length(passed), ' passed (', length(passed_with_skips),
    ' with skipped checks), ', length(skipped), ' skipped entirely, ',
    length(failed), ' failed (', elapsed, ' minutes)\n', sep = '')
if (length(passed_with_skips)) {
  cat('Passed with skips: ', paste(passed_with_skips, collapse = ', '), '\n', sep = '')
}
if (length(skipped)) cat('Skipped: ', paste(skipped, collapse = ', '), '\n', sep = '')
if (length(failed)) cat('Failed:  ', paste(failed, collapse = ', '), '\n', sep = '')
cat(strrep('=', 68), '\n', sep = '')

quit(status = if (length(failed)) 1L else 0L)
