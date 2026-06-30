# =============================================================================
# parity.R — tolerance comparator for parity-gated refactors
# =============================================================================
#
# The AuthoritySpec migration (docs/authority_spec.md) re-plumbs the calculator
# and parallelizes the build. None of it is allowed to change the NUMBERS the
# pipeline produces (until scenarios are deliberately applied). This module is
# the safety net: it compares a candidate build's outputs against a reference
# build — the latest published vintage (<model_data_root>/latest) — and reports
# any number that drifted beyond tolerance.
#
# Why tolerance, not byte-identity: refactors and parallelism reorder
# floating-point operations, which perturbs the last few bits even when the
# logic is identical. `cmp`/`diff` fail on that (and on column/row reorder);
# this comparator keys on natural keys and compares per column class.
#
# Design:
#   - Compare by KEY, not row position. A full_join surfaces rows missing from
#     the candidate AND extra rows in the candidate as first-class violations.
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
#   PARITY_ARTIFACTS                                  -> per-artifact key/glob registry
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

# Columns the build omits under GATHER_ARGS="--unweighted" — the import-weighted
# ETR / weight aggregates (weighted_etr*, the per-authority etr_* columns,
# *_imports_b). The harness gates the rate panel + the UNWEIGHTED daily
# means/counts; the weighted-ETR engine is intentionally un-gated (see the
# PARITY_ARTIFACTS NOTE). So a reference (built weighted) carrying these columns while
# the candidate (--unweighted) omits them is EXPECTED, not drift — such a
# reference-only column is skipped, not a schema violation. (Any other reference-only
# column is still real drift; and a weighted column PRESENT in both is still
# value-compared, with the etr tolerance.)
.parity_is_ungated_weighted_col <- function(col) {
  grepl('^weighted_etr|^etr_|_imports_b$', col)
}

# ---- core comparator --------------------------------------------------------

#' Compare a candidate table against a reference table, keyed by `key_cols`.
#'
#' @param actual  data.frame/tibble — candidate output
#' @param reference  data.frame/tibble — frozen reference
#' @param key_cols character — the natural key (must be present in both)
#' @param label   character — artifact name for the report
#' @return list(label, pass, n_rows_actual, n_rows_reference, n_rows_common,
#'              n_violations, violations = tibble)
compare_parity <- function(actual, reference, key_cols, label = 'artifact') {
  stopifnot(is.data.frame(actual), is.data.frame(reference))
  missing_a <- setdiff(key_cols, names(actual))
  missing_g <- setdiff(key_cols, names(reference))
  if (length(missing_a) || length(missing_g)) {
    stop(sprintf("[%s] key column(s) missing — actual: {%s}, reference: {%s}",
                 label, paste(missing_a, collapse = ', '),
                 paste(missing_g, collapse = ', ')))
  }

  violations <- list()
  add_v <- function(kind, column, key, actual_val, reference_val, abs_err = NA_real_, rel_err = NA_real_) {
    violations[[length(violations) + 1]] <<- tibble(
      label = label, kind = kind, column = column, key = key,
      actual = as.character(actual_val), reference = as.character(reference_val),
      abs_err = abs_err, rel_err = rel_err
    )
  }

  # ---- schema diff (value columns present in only one side) ----
  val_cols_a <- setdiff(names(actual), key_cols)
  val_cols_g <- setdiff(names(reference), key_cols)
  only_actual <- setdiff(val_cols_a, val_cols_g)
  only_reference <- setdiff(val_cols_g, val_cols_a)
  # Skip the un-gated import-weighted ETR/weight columns the --unweighted candidate
  # legitimately omits (see .parity_is_ungated_weighted_col); flag every OTHER
  # reference-only column as a real schema violation.
  skipped_ungated <- only_reference[.parity_is_ungated_weighted_col(only_reference)]
  only_reference     <- setdiff(only_reference, skipped_ungated)
  for (col in only_reference) add_v('schema_missing_column', col, NA_character_, NA, NA)
  for (col in only_actual) add_v('schema_extra_column', col, NA_character_, NA, NA)
  shared_cols <- intersect(val_cols_a, val_cols_g)

  # ---- row presence (keyed full join) ----
  a <- actual;  a$`.in_actual` <- TRUE
  g <- reference;  g$`.in_reference` <- TRUE
  joined <- dplyr::full_join(a, g, by = key_cols, suffix = c('.actual', '.reference'))
  in_a <- !is.na(joined$`.in_actual`)
  in_g <- !is.na(joined$`.in_reference`)
  common <- in_a & in_g

  key_str <- function(rows) {
    do.call(paste, c(lapply(key_cols, function(k) as.character(joined[[k]][rows])), sep = ' | '))
  }
  if (any(in_a & !in_g)) {
    ks <- key_str(in_a & !in_g)
    for (k in ks) add_v('row_extra', NA_character_, k, NA, NA)
  }
  if (any(in_g & !in_a)) {
    ks <- key_str(in_g & !in_a)
    for (k in ks) add_v('row_missing', NA_character_, k, NA, NA)
  }

  # ---- value comparison on common rows ----
  common_idx <- which(common)
  if (length(common_idx) > 0) {
    ck <- key_str(common)  # one key string per common row, aligned to common_idx
    for (col in shared_cols) {
      ca <- joined[[paste0(col, '.actual')]]
      cg <- joined[[paste0(col, '.reference')]]
      if (is.null(ca) || is.null(cg)) {            # column was a key on one side / absent post-join
        next
      }
      av <- ca[common_idx]; gv <- cg[common_idx]
      if (is.list(av) || is.list(gv)) next          # skip list-columns (none expected in panels)
      numeric_col <- is.numeric(av) && is.numeric(gv)
      if (numeric_col) {
        cls <- classify_parity_column(col)
        ok <- .parity_within_tol_numeric(av, gv, cls)
        bad <- which(!ok)
        if (length(bad)) {
          abs_err <- abs(av[bad] - gv[bad])
          rel_err <- abs_err / pmax(abs(gv[bad]), 1e-300)
          for (j in seq_along(bad)) {
            b <- bad[j]
            add_v('value_mismatch', col, ck[b], av[b], gv[b], abs_err[j], rel_err[j])
          }
        }
      } else {
        ok <- .parity_exact_equal(av, gv)
        bad <- which(!ok)
        for (b in bad) add_v('value_mismatch', col, ck[b], av[b], gv[b])
      }
    }
  }

  viol_tbl <- if (length(violations)) dplyr::bind_rows(violations) else
    tibble(label = character(), kind = character(), column = character(),
           key = character(), actual = character(), reference = character(),
           abs_err = double(), rel_err = double())

  list(
    label = label,
    pass = nrow(viol_tbl) == 0,
    n_rows_actual = nrow(actual),
    n_rows_reference = nrow(reference),
    n_rows_common = length(common_idx),
    n_violations = nrow(viol_tbl),
    skipped_ungated_columns = skipped_ungated,
    violations = viol_tbl
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

# Maps an artifact kind to its file glob and natural key. run_parity_check.R
# uses this to locate and compare each artifact; key_cols are intersected with
# the columns actually present so a schema tweak degrades gracefully.
PARITY_ARTIFACTS <- list(
  timeseries  = list(glob = 'rate_timeseries.rds',     key_cols = c('hts10', 'country', 'revision')),
  snapshot    = list(glob = 'snapshot_*.rds',          key_cols = c('hts10', 'country', 'revision')),
  # daily_overall and daily_by_authority are WIDE (one row per date; authorities
  # live in columns), so both key on `date` alone.
  daily_overall      = list(glob = 'daily_overall*.csv',      key_cols = c('date')),
  daily_by_authority = list(glob = 'daily_by_authority*.csv', key_cols = c('date')),
  daily_by_country   = list(glob = 'daily_by_country*.csv',   key_cols = c('date', 'country')),
  daily_by_category  = list(glob = 'daily_by_category*.csv',  key_cols = c('date', 'gtap_code'))
  # NOTE: the removed legacy weighted-ETR/TPC-overlay engine is intentionally not
  # gated here. The harness gates the consumed artifacts: the rate panel
  # (snapshot/timeseries) + the daily series.
)

#' Read a parity artifact (.rds or .csv) into a tibble.
read_parity_artifact <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (ext == 'rds') return(tibble::as_tibble(readRDS(path)))
  if (ext == 'csv') return(suppressMessages(readr::read_csv(path, show_col_types = FALSE)))
  stop('Unsupported parity artifact extension: ', path)
}

#' Compare two artifact files of a known kind. Keys are taken from
#' PARITY_ARTIFACTS[[kind]] and intersected with present columns.
compare_parity_files <- function(actual_path, reference_path, kind, label = NULL) {
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
                 label = label %||% paste0(kind, ':', basename(actual_path)))
}

# Local null-coalesce so this module is standalone (helpers.R may not be sourced).
`%||%` <- function(x, y) if (is.null(x)) y else x
