# =============================================================================
# Tests: Import-Weights Resolution
# =============================================================================
#
# Covers the three pieces that gate weighted outputs:
#   1. autodetect_import_weights()  — finds the right file in data/weights/
#   2. load_local_paths()           — weight_mode validation + auto-detect wiring
#   3. load_import_weights()        — strict-vs-unweighted error / NULL behavior
#
# Fixtures are constructed in tempdir(); no real Census data needed.
#
# Usage:
#   Rscript tests/run_tests_weights_resolution.R
#
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
  library(yaml)
})
source(here('src', 'core', 'helpers.R'))
source(here('src', 'pipeline', '09_daily_series.R'))

pass_count <- 0
fail_count <- 0

run_test <- function(name, expr) {
  tryCatch({
    force(expr)
    message('  PASS: ', name)
    pass_count <<- pass_count + 1
  }, error = function(e) {
    message('  FAIL: ', name, ' — ', conditionMessage(e))
    fail_count <<- fail_count + 1
  })
}


# =============================================================================
# Fixtures
# =============================================================================

# Create an isolated weights directory with the given filenames (each gets a
# minimal but valid RDS payload). Returns the directory path.
make_weights_dir <- function(files = character(),
                              mtime_offsets_secs = NULL) {
  d <- file.path(tempfile('weights_'), 'weights')
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  dummy <- tibble::tibble(
    hs10 = '0101210010', cty_code = '1220', imports = 1.0
  )
  for (i in seq_along(files)) {
    p <- file.path(d, files[i])
    saveRDS(dummy, p)
    if (!is.null(mtime_offsets_secs)) {
      Sys.setFileTime(p, Sys.time() + mtime_offsets_secs[i])
    }
  }
  d
}


# Write a temp local_paths.yaml with the supplied entries and return its path.
make_local_paths <- function(...) {
  entries <- list(...)
  p <- tempfile(fileext = '.yaml')
  yaml::write_yaml(entries, p)
  p
}


# =============================================================================
# autodetect_import_weights()
# =============================================================================

message('\n=== autodetect_import_weights() ===')

run_test('returns NULL when dir does not exist', {
  result <- autodetect_import_weights(weights_dir = tempfile('does_not_exist_'))
  stopifnot(is.null(result))
})

run_test('returns NULL when dir is empty', {
  d <- file.path(tempfile('weights_'), 'weights')
  dir.create(d, recursive = TRUE)
  stopifnot(is.null(autodetect_import_weights(weights_dir = d)))
})

run_test('returns NULL when dir has unrelated files', {
  d <- make_weights_dir(c('something_else.rds', 'notes.txt'))
  stopifnot(is.null(autodetect_import_weights(weights_dir = d)))
})

run_test('picks the only matching file', {
  d <- make_weights_dir('hs10_by_country_gtap_2024_con.rds')
  result <- autodetect_import_weights(weights_dir = d)
  stopifnot(basename(result) == 'hs10_by_country_gtap_2024_con.rds')
})

run_test('prefers _con over _gen even if _gen is newer', {
  d <- make_weights_dir(
    c('hs10_by_country_gtap_2024_con.rds',
      'hs10_by_country_gtap_2024_gen.rds'),
    mtime_offsets_secs = c(-10, 0)  # gen is newer
  )
  result <- autodetect_import_weights(weights_dir = d)
  stopifnot(grepl('_con\\.rds$', result))
})

run_test('picks most-recent _con when multiple _con files exist', {
  d <- make_weights_dir(
    c('hs10_by_country_gtap_2024_con.rds',
      'hs10_by_country_gtap_2025_con.rds'),
    mtime_offsets_secs = c(-10, 0)  # 2025 is newer
  )
  result <- autodetect_import_weights(weights_dir = d)
  stopifnot(grepl('2025_con\\.rds$', result))
})

run_test('falls back to _gen when no _con present', {
  d <- make_weights_dir('hs10_by_country_gtap_2024_gen.rds')
  result <- autodetect_import_weights(weights_dir = d)
  stopifnot(grepl('_gen\\.rds$', result))
})


# =============================================================================
# load_local_paths()
# =============================================================================

message('\n=== load_local_paths() ===')

run_test('returns defaults when yaml does not exist', {
  result <- load_local_paths(yaml_path = tempfile())
  stopifnot(
    identical(result$weight_mode, 'required'),
    is.null(result$import_weights) || identical(result$import_weights, NULL) ||
      # if user happens to have a real data/weights/ file, autodetect kicks in
      grepl('hs10_by_country_gtap', result$import_weights)
  )
})

run_test('accepts weight_mode: unweighted', {
  p <- make_local_paths(weight_mode = 'unweighted')
  result <- load_local_paths(yaml_path = p)
  stopifnot(identical(result$weight_mode, 'unweighted'))
})

run_test('rejects unknown weight_mode', {
  p <- make_local_paths(weight_mode = 'bogus')
  err <- tryCatch(load_local_paths(yaml_path = p),
                  error = function(e) conditionMessage(e))
  stopifnot(grepl('Invalid weight_mode', err),
            grepl('bogus', err))
})

run_test('explicit import_weights wins over auto-detect', {
  p <- make_local_paths(
    import_weights = '/some/explicit/path.rds',
    weight_mode = 'required'
  )
  result <- load_local_paths(yaml_path = p)
  stopifnot(identical(result$import_weights, '/some/explicit/path.rds'))
})


# =============================================================================
# load_import_weights()
# =============================================================================

message('\n=== load_import_weights() ===')

run_test('errors on missing file under weight_mode=required', {
  err <- tryCatch(
    load_import_weights(imports_path = '/does/not/exist.rds',
                        weight_mode = 'required'),
    error = function(e) conditionMessage(e)
  )
  stopifnot(grepl('Import weights are required', err))
})

run_test('returns NULL silently on missing file under weight_mode=unweighted', {
  result <- suppressMessages(
    load_import_weights(imports_path = '/does/not/exist.rds',
                        weight_mode = 'unweighted')
  )
  stopifnot(is.null(result))
})

run_test('loads a real RDS when path is valid', {
  d <- make_weights_dir('hs10_by_country_gtap_2024_con.rds')
  p <- file.path(d, 'hs10_by_country_gtap_2024_con.rds')
  result <- suppressMessages(
    load_import_weights(imports_path = p, weight_mode = 'required')
  )
  stopifnot(is.data.frame(result),
            all(c('hs10', 'cty_code', 'imports') %in% names(result)))
})


# =============================================================================
# ensure_import_weights() — pre-build orchestration
# =============================================================================

message('\n=== ensure_import_weights() ===')

# Source the helper (kept in build_import_weights.R so this file doesn't pull
# in the full builder unless needed). load_local_paths()/autodetect already
# came from helpers.R above.
source(here('src', 'io', 'build_import_weights.R'))

run_test('weight_mode = unweighted is a no-op (returns NULL)', {
  result <- suppressMessages(ensure_import_weights(weight_mode = 'unweighted'))
  stopifnot(is.null(result))
})

run_test('returns config-resolved path when file exists', {
  # Stage a fake weight file and point a temp yaml at it via the autodetect path.
  # (Bypasses load_local_paths()'s yaml parsing — ensure_import_weights() falls
  # through to autodetect_import_weights() when the config path is null.)
  d <- make_weights_dir('hs10_by_country_gtap_2024_con.rds')
  # autodetect_import_weights() looks at data/weights/ by default; override
  # via an environment-style indirection. Simpler: shadow it temporarily.
  old <- autodetect_import_weights
  assign('autodetect_import_weights',
         function(weights_dir = NULL) file.path(d, 'hs10_by_country_gtap_2024_con.rds'),
         envir = .GlobalEnv)
  on.exit(assign('autodetect_import_weights', old, envir = .GlobalEnv), add = TRUE)

  result <- suppressMessages(ensure_import_weights(weight_mode = 'required'))
  stopifnot(!is.null(result), file.exists(result))
})


# =============================================================================
# Summary
# =============================================================================

message('\n', strrep('=', 70))
message(sprintf('Weights-resolution tests: %d passed, %d failed',
                pass_count, fail_count))
message(strrep('=', 70))

if (fail_count > 0) quit(status = 1)
