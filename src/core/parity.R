# =============================================================================
# parity.R — tolerance comparator for parity-gated refactors
# =============================================================================
#
# The AuthoritySpec migration (docs/authority_spec.md) re-plumbs the calculator
# and parallelizes the build. None of it is allowed to change the NUMBERS the
# pipeline produces (until scenarios are deliberately applied). This module is
# the safety net: it compares two series published through the model_data
# interface and reports any number that drifted beyond tolerance.
#
# Why tolerance, not byte-identity: refactors and parallelism reorder
# floating-point operations, which perturbs the last few bits even when the
# logic is identical. `cmp`/`diff` fail on that (and on column/row reorder);
# this comparator keys on natural keys and compares per column class.
#
# Design:
#   - Compare by KEY, not row position. A compact key index surfaces rows
#     missing from the candidate AND extra rows in the candidate without
#     materializing a second copy of a multi-million-row table.
#   - Tolerance per COLUMN CLASS (rates vs shares vs import-weighted ETRs differ
#     by orders of magnitude); see PARITY_TOL / classify_parity_column().
#   - NA-vs-NA is a pass; NA-vs-value is a violation (catches a column silently
#     dropping to NA, e.g. a pivot losing an authority column).
#
# Public API:
#   compare_parity(actual, reference, key_cols, label)   -> result list
#   assert_parity(result)                             -> invisible / stop()
#   format_parity_report(result, max_show)            -> character
#   compare_parity_files(actual_path, reference_path, kind)
#   resolve_model_data_series(root)                   -> strict published-series root
#   list_parity_artifacts(root, kind)                 -> relative-path keyed files
#   PARITY_ARTIFACTS                                  -> per-artifact key registry
#
# Dependencies: dplyr + tibble (tidyverse). No model data required — unit
# testable on synthetic fixtures (see tests/test_parity.R).
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tibble)
})

# Tolerance by column class.
#   abs: pass iff |a - g| <= tol
#   rel: pass iff |a - g| <= floor  OR  |a - g| / max(|g|, floor) <= tol
PARITY_TOL <- list(
  rate  = list(kind = 'abs', tol = 1e-9),
  share = list(kind = 'abs', tol = 1e-9),
  etr   = list(kind = 'rel', tol = 1e-7, floor = 1e-12)
)

#' Classify a numeric column name into a tolerance class.
#'
#' Default is `rate` (tight absolute) — rate columns are sums/max/if_else of
#' literal fractions, so float reassociation only touches the last bits.
#' Import-weighted means / ETRs are tiny and get a relative tolerance.
classify_parity_column <- function(col) {
  c <- tolower(col)
  if (grepl('etr|weighted_numerator|partner_total|sector_total|^mean_|_mean$|imports', c)) {
    return('etr')
  }
  if (grepl('share', c)) return('share')
  'rate'
}

# ---- per-column comparison primitives ---------------------------------------

.parity_within_tol_numeric <- function(a, g, cls) {
  spec <- PARITY_TOL[[cls]]
  if (is.null(spec)) spec <- PARITY_TOL$rate
  both_na <- is.na(a) & is.na(g)
  one_na  <- xor(is.na(a), is.na(g))
  abs_err <- abs(a - g)
  if (spec$kind == 'abs') {
    ok <- abs_err <= spec$tol
  } else {
    floor_v <- spec$floor
    denom <- pmax(abs(g), floor_v)
    ok <- (abs_err <= floor_v) | (abs_err / denom <= spec$tol)
  }
  ok[both_na] <- TRUE
  ok[one_na]  <- FALSE
  # NA arithmetic (from one_na rows) may have left NA in ok; force to FALSE.
  ok[is.na(ok)] <- FALSE
  ok
}

.parity_exact_equal <- function(a, g) {
  both_na <- is.na(a) & is.na(g)
  # Compare as character to be robust across Date / factor / logical / numeric.
  eq <- as.character(a) == as.character(g)
  eq[is.na(eq)] <- FALSE
  eq[both_na] <- TRUE
  eq
}

# Build one exact, compact value per natural key. Published snapshots use two
# fixed-width digit fields, so their pair fits exactly in an IEEE double
# (< 2^53). This avoids allocating millions of pasted strings. Other artifact
# keys are small and use a separator that cannot occur in the published fields.
.parity_key_vector <- function(x, key_cols) {
  if (identical(key_cols, c('hts10', 'country'))) {
    hts <- suppressWarnings(as.double(x[['hts10']]))
    country <- suppressWarnings(as.double(x[['country']]))
    if (!anyNA(hts) && !anyNA(country)) return(hts * 10000 + country)
  }
  do.call(paste, c(lapply(key_cols, function(k) as.character(x[[k]])),
                   sep = '\x1f'))
}

# ---- core comparator --------------------------------------------------------

#' Compare a candidate table against a reference table, keyed by `key_cols`.
#'
#' @param actual  data.frame/tibble — candidate output
#' @param reference  data.frame/tibble — frozen reference
#' @param key_cols character — the natural key (must be present in both)
#' @param label   character — artifact name for the report
#' @param ignore_cols character — explicitly approved metadata columns to omit
#' @return list(label, pass, n_rows_actual, n_rows_reference, n_rows_common,
#'              n_violations, violations = tibble)
compare_parity <- function(actual, reference, key_cols, label = 'artifact',
                           ignore_cols = character(),
                           allow_extra_cols = character()) {
  stopifnot(is.data.frame(actual), is.data.frame(reference))
  missing_a <- setdiff(key_cols, names(actual))
  missing_g <- setdiff(key_cols, names(reference))
  if (length(missing_a) || length(missing_g)) {
    stop(sprintf("[%s] key column(s) missing — actual: {%s}, reference: {%s}",
                 label, paste(missing_a, collapse = ', '),
                 paste(missing_g, collapse = ', ')))
  }

  violations <- list()
  violation_groups <- list()
  n_violations_total <- 0L
  n_violation_details <- 0L
  max_violation_details <- 100L
  record_violation_group <- function(kind, column, n) {
    violation_groups[[length(violation_groups) + 1L]] <<- tibble(
      kind = kind, column = column, n = as.double(n))
  }
  add_v <- function(kind, column, key, actual_val, reference_val, abs_err = NA_real_, rel_err = NA_real_) {
    n_violations_total <<- n_violations_total + 1L
    record_violation_group(kind, column, 1L)
    if (n_violation_details >= max_violation_details) return(invisible(NULL))
    violations[[length(violations) + 1]] <<- tibble(
      label = label, kind = kind, column = column, key = key,
      actual = as.character(actual_val), reference = as.character(reference_val),
      abs_err = abs_err, rel_err = rel_err
    )
    n_violation_details <<- n_violation_details + 1L
    invisible(NULL)
  }
  add_v_batch <- function(kind, column, key, actual_val = NA, reference_val = NA,
                          abs_err = NA_real_, rel_err = NA_real_) {
    n <- max(length(key), length(actual_val), length(reference_val),
             length(abs_err), length(rel_err))
    if (n == 0L) return(invisible(NULL))
    n_violations_total <<- n_violations_total + n
    record_violation_group(kind, column, n)
    keep_n <- min(n, max_violation_details - n_violation_details)
    if (keep_n <= 0L) return(invisible(NULL))
    take <- seq_len(keep_n)
    recycle <- function(x) rep_len(x, n)[take]
    violations[[length(violations) + 1L]] <<- tibble(
      label = rep(label, keep_n), kind = rep(kind, keep_n),
      column = rep(column, keep_n), key = as.character(recycle(key)),
      actual = as.character(recycle(actual_val)),
      reference = as.character(recycle(reference_val)),
      abs_err = as.double(recycle(abs_err)), rel_err = as.double(recycle(rel_err))
    )
    n_violation_details <<- n_violation_details + keep_n
    invisible(NULL)
  }

  # ---- schema diff (value columns present in only one side) ----
  # ignore_cols opts a column out of VALUE comparison only. Candidate-only
  # columns remain schema drift unless a migration gate names them explicitly.
  val_cols_a <- setdiff(names(actual), key_cols)
  val_cols_g <- setdiff(names(reference), key_cols)
  only_actual <- setdiff(setdiff(val_cols_a, val_cols_g), allow_extra_cols)
  only_reference <- setdiff(val_cols_g, val_cols_a)
  for (col in only_reference) add_v('schema_missing_column', col, NA_character_, NA, NA)
  for (col in only_actual) add_v('schema_extra_column', col, NA_character_, NA, NA)
  shared_cols <- setdiff(intersect(val_cols_a, val_cols_g), ignore_cols)

  # ---- row presence + alignment by natural key -----------------------------
  # Matching one compact key vector is dramatically cheaper than full_join()
  # on every value column. It also handles the intentional row-order change
  # made by the one-grid refactor.
  actual_key <- .parity_key_vector(actual, key_cols)
  reference_key <- .parity_key_vector(reference, key_cols)
  if (anyDuplicated(actual_key)) stop('[', label, '] duplicate key in actual')
  if (anyDuplicated(reference_key)) stop('[', label, '] duplicate key in reference')

  reference_idx <- if (identical(actual_key, reference_key)) {
    seq_along(actual_key)
  } else {
    match(actual_key, reference_key)
  }
  actual_idx <- match(reference_key, actual_key)
  common_actual <- which(!is.na(reference_idx))
  common_reference <- reference_idx[common_actual]

  key_str <- function(x, rows) {
    do.call(paste, c(lapply(key_cols, function(k) as.character(x[[k]][rows])),
                     sep = ' | '))
  }
  extra <- which(is.na(reference_idx))
  missing <- which(is.na(actual_idx))
  if (length(extra)) {
    add_v_batch('row_extra', NA_character_, key_str(actual, extra))
  }
  if (length(missing)) {
    add_v_batch('row_missing', NA_character_, key_str(reference, missing))
  }

  # ---- value comparison on common rows ----
  if (length(common_actual) > 0) {
    actual_is_complete <- length(common_actual) == nrow(actual)
    reference_is_identity <- actual_is_complete &&
      length(common_reference) == nrow(reference) &&
      identical(common_reference, seq_len(nrow(reference)))
    for (col in shared_cols) {
      av <- if (actual_is_complete) actual[[col]] else actual[[col]][common_actual]
      gv <- if (reference_is_identity) reference[[col]] else reference[[col]][common_reference]
      if (is.list(av) || is.list(gv)) next          # skip list-columns (none expected in panels)
      # Refactors normally preserve values exactly. Let C's vector equality
      # take that fast path before allocating tolerance/error vectors.
      if (identical(av, gv)) next
      numeric_col <- is.numeric(av) && is.numeric(gv)
      if (numeric_col) {
        cls <- classify_parity_column(col)
        ok <- .parity_within_tol_numeric(av, gv, cls)
        bad <- which(!ok)
        if (length(bad)) {
          ck <- key_str(actual, common_actual[bad])
          abs_err <- abs(av[bad] - gv[bad])
          rel_err <- abs_err / pmax(abs(gv[bad]), 1e-300)
          add_v_batch('value_mismatch', col, ck, av[bad], gv[bad], abs_err, rel_err)
        }
      } else {
        ok <- .parity_exact_equal(av, gv)
        bad <- which(!ok)
        if (length(bad)) {
          ck <- key_str(actual, common_actual[bad])
          add_v_batch('value_mismatch', col, ck, av[bad], gv[bad])
        }
      }
    }
  }

  viol_tbl <- if (length(violations)) dplyr::bind_rows(violations) else
    tibble(label = character(), kind = character(), column = character(),
           key = character(), actual = character(), reference = character(),
           abs_err = double(), rel_err = double())
  violation_summary <- if (length(violation_groups)) {
    dplyr::bind_rows(violation_groups) %>%
      group_by(kind, column) %>%
      summarise(n = sum(n), .groups = 'drop') %>%
      arrange(desc(n), kind, column)
  } else {
    tibble(kind = character(), column = character(), n = double())
  }

  list(
    label = label,
    pass = n_violations_total == 0L,
    n_rows_actual = nrow(actual),
    n_rows_reference = nrow(reference),
    n_rows_common = length(common_actual),
    n_violations = n_violations_total,
    violations = viol_tbl,
    violation_summary = violation_summary
  )
}

#' Stop with a formatted report if a parity result has any violation.
assert_parity <- function(result, max_show = 40) {
  if (isTRUE(result$pass)) {
    message(sprintf('[parity OK] %s — %d rows match (within tolerance)',
                    result$label, result$n_rows_common))
    return(invisible(result))
  }
  stop(format_parity_report(result, max_show = max_show), call. = FALSE)
}

#' Human-readable parity report.
format_parity_report <- function(result, max_show = 40) {
  v <- result$violations
  hdr <- sprintf(
    '[parity FAIL] %s — %d violation(s) | rows: actual=%d reference=%d common=%d',
    result$label, result$n_violations,
    result$n_rows_actual, result$n_rows_reference, result$n_rows_common)
  if (nrow(v) == 0) return(hdr)
  by_kind <- v %>% count(kind, name = 'n') %>% arrange(desc(n))
  summary <- paste(sprintf('  %-22s %d', by_kind$kind, by_kind$n), collapse = '\n')
  shown <- utils::head(v, max_show)
  detail <- apply(shown, 1, function(r) {
    sprintf('  [%s] col=%s key={%s} actual=%s reference=%s%s',
            r[['kind']], r[['column']], r[['key']], r[['actual']], r[['reference']],
            if (!is.na(r[['abs_err']]) && nzchar(r[['abs_err']]))
              sprintf(' (abs_err=%s rel_err=%s)', r[['abs_err']], r[['rel_err']]) else '')
  })
  more <- if (nrow(v) > max_show) sprintf('\n  ... and %d more', nrow(v) - max_show) else ''
  paste0(hdr, '\nViolations by kind:\n', summary, '\nDetail:\n',
         paste(detail, collapse = '\n'), more)
}

# ---- artifact registry + file dispatch --------------------------------------

# A published series is exactly <series>/{snapshots,daily}. A caller may pass
# either that directory directly or a vintage root containing <root>/actual.
# No working-repository, flat-file, or legacy "golden" layouts are accepted.
resolve_model_data_series <- function(root) {
  if (is.null(root) || length(root) != 1L || !nzchar(root)) {
    stop('model_data series root must be one non-empty path', call. = FALSE)
  }
  root <- normalizePath(root, mustWork = TRUE)
  direct <- dir.exists(file.path(root, 'snapshots')) &&
    dir.exists(file.path(root, 'daily'))
  actual <- dir.exists(file.path(root, 'actual', 'snapshots')) &&
    dir.exists(file.path(root, 'actual', 'daily'))
  if (direct) return(root)
  if (actual) return(file.path(root, 'actual'))
  stop(
    'not a published model_data series or vintage: ', root,
    '\nExpected <root>/{snapshots,daily} or <root>/actual/{snapshots,daily}.',
    call. = FALSE
  )
}

# Maps an artifact kind to its published section, exact filename, and natural
# key. Snapshots are paired by their hive-partition relative path, so every
# valid_from=.../rates.parquet remains distinct.
PARITY_ARTIFACTS <- list(
  snapshot    = list(section = 'snapshots', filename = 'rates.parquet',
                     recursive = TRUE, key_cols = c('hts10', 'country')),
  # daily_overall and daily_by_authority are WIDE (one row per date; authorities
  # live in columns), so both key on `date` alone.
  daily_overall      = list(section = 'daily', filename = 'daily_overall.csv',
                            recursive = FALSE, key_cols = c('date')),
  daily_by_authority = list(section = 'daily', filename = 'daily_by_authority.csv',
                            recursive = FALSE, key_cols = c('date')),
  daily_by_country   = list(section = 'daily', filename = 'daily_by_country.csv',
                            recursive = FALSE, key_cols = c('date', 'country')),
  daily_by_category  = list(section = 'daily', filename = 'daily_by_category.csv',
                            recursive = FALSE, key_cols = c('date', 'gtap_code')),
  daily_by_hs        = list(section = 'daily', filename = 'daily_by_hs.csv',
                            recursive = FALSE, key_cols = c('date', 'category_code'))
)

#' List one kind of artifact, named by path relative to its published section.
list_parity_artifacts <- function(series_root, kind) {
  spec <- PARITY_ARTIFACTS[[kind]]
  if (is.null(spec)) stop('Unknown parity artifact kind: ', kind, call. = FALSE)
  series_root <- resolve_model_data_series(series_root)
  section_dir <- file.path(series_root, spec$section)
  files <- list.files(section_dir, recursive = isTRUE(spec$recursive),
                      full.names = TRUE, include.dirs = FALSE)
  files <- files[basename(files) == spec$filename]
  prefix <- paste0(normalizePath(section_dir, mustWork = TRUE), .Platform$file.sep)
  rel <- substring(normalizePath(files, mustWork = TRUE), nchar(prefix) + 1L)
  if (anyDuplicated(rel)) stop('duplicate artifact relative path(s) for ', kind, call. = FALSE)
  stats::setNames(files, rel)
}

#' Read a published parity artifact (.parquet or .csv) into a tibble.
read_parity_artifact <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (ext == 'parquet') {
    if (!requireNamespace('arrow', quietly = TRUE)) {
      stop('arrow is required to compare published parquet snapshots', call. = FALSE)
    }
    return(tibble::as_tibble(arrow::read_parquet(path)))
  }
  if (ext == 'csv') return(suppressMessages(readr::read_csv(path, show_col_types = FALSE)))
  stop('Unsupported parity artifact extension: ', path)
}

#' Compare two artifact files of a known kind. Keys are taken from
#' PARITY_ARTIFACTS[[kind]] and intersected with present columns.
compare_parity_files <- function(actual_path, reference_path, kind, label = NULL,
                                 ignore_cols = character(),
                                 allow_extra_cols = character()) {
  spec <- PARITY_ARTIFACTS[[kind]]
  if (is.null(spec)) stop('Unknown parity artifact kind: ', kind)
  actual <- read_parity_artifact(actual_path)
  reference <- read_parity_artifact(reference_path)
  key_cols <- intersect(spec$key_cols, intersect(names(actual), names(reference)))
  if (length(key_cols) == 0) {
    stop(sprintf('[%s] no usable key columns from {%s} present in both files',
                 kind, paste(spec$key_cols, collapse = ', ')))
  }
  compare_parity(actual, reference, key_cols,
                 label = label %||% paste0(kind, ':', basename(actual_path)),
                 ignore_cols = ignore_cols,
                 allow_extra_cols = allow_extra_cols)
}

# Local null-coalesce so this module is standalone (helpers.R may not be sourced).
`%||%` <- function(x, y) if (is.null(x)) y else x
