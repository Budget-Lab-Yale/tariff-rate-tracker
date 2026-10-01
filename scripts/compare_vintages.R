#!/usr/bin/env Rscript
# =============================================================================
# compare_vintages.R — diff two published vintages, series by series
# =============================================================================
#
# Answers "what did this code change actually do to the numbers?" by diffing a
# freshly built vintage against a baseline, on the gathered daily outputs:
#
#   Rscript scripts/compare_vintages.R <baseline_vintage_dir> <new_vintage_dir>
#                                      [--series actual,no_s338] [--tol 1e-9]
#
# Both arguments are vintage roots on the model_data interface, e.g.
#   /nfs/.../model_data/Tariff-Rate-Tracker/2026-08-24-11
#
# Reports, per series:
#   * column-set and date-coverage differences between the two vintages
#   * every numeric column that moved, with the first/last date it moves, the
#     largest absolute move and the date it happens, and the end-of-series delta
#   * the weights-join diagnostic (matched_imports_b == total_imports_b, which
#     must read 100% on every day — see CLAUDE.md)
#   * the §338 marginal effect (actual minus no_s338) within EACH vintage, so a
#     scenario contrast can be compared across builds
#
# PREREQUISITE — check this before trusting any diff. Both vintages must have
# consumed the same 484(f) weight inputs. A vintage built without the 2025
# split-share base silently falls back to an even split, which moves ~$64B of
# value between share tiers and shifts weighted ETRs across the WHOLE series,
# including dates the code change never touched. The tell is
#   manifest.json -> weights.provenance.split_shares.present
# This script warns when the two vintages disagree on it.
#
# Deltas are printed in PERCENTAGE POINTS; the underlying columns are fractions.
# =============================================================================
suppressPackageStartupMessages({ library(tidyverse); library(jsonlite) })

DEFAULT_TOL    <- 1e-9   # below this a column counts as unchanged (float noise)
DEFAULT_SERIES <- c('actual', 'no_s338')
PP             <- 100    # fractions -> percentage points for display

# ---- args -------------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
get_opt <- function(flag, default) {
  i <- match(flag, args)
  if (is.na(i) || i == length(args)) return(default)
  args[i + 1]
}
positional <- args[!grepl('^--', args)]
drop_after <- unlist(lapply(c('--series', '--tol'), function(f) {
  i <- match(f, args); if (is.na(i)) NULL else args[i + 1]
}))
positional <- setdiff(positional, drop_after)

if (length(positional) < 2) {
  cat('usage: Rscript scripts/compare_vintages.R <baseline_vintage_dir> <new_vintage_dir>\n')
  cat('                                          [--series actual,no_s338] [--tol 1e-9]\n')
  quit(status = 2)
}
BASE_DIR <- positional[1]
NEW_DIR  <- positional[2]
TOL      <- as.numeric(get_opt('--tol', DEFAULT_TOL))
SERIES   <- strsplit(get_opt('--series', paste(DEFAULT_SERIES, collapse = ',')), ',')[[1]]

for (d in c(BASE_DIR, NEW_DIR)) {
  if (!dir.exists(d)) stop('vintage directory not found: ', d, call. = FALSE)
}

rule <- function(ch = '=', n = 78) cat(strrep(ch, n), '\n', sep = '')
hdr  <- function(txt) { cat('\n'); rule(); cat(txt, '\n'); rule() }

series_dir <- function(vintage_dir, series) {
  if (series == 'actual') file.path(vintage_dir, 'actual')
  else file.path(vintage_dir, 'scenarios', series)
}

read_daily <- function(vintage_dir, series, file) {
  p <- file.path(series_dir(vintage_dir, series), 'daily', file)
  if (!file.exists(p)) return(NULL)
  suppressMessages(read_csv(p, show_col_types = FALSE, progress = FALSE))
}

# ---- weight-input parity (see PREREQUISITE above) ---------------------------
split_shares_present <- function(vintage_dir) {
  mp <- file.path(vintage_dir, 'manifest.json')
  if (!file.exists(mp)) return(NA)
  m <- tryCatch(fromJSON(mp), error = function(e) NULL)
  if (is.null(m)) return(NA)
  isTRUE(m$weights$provenance$split_shares$present)
}

check_weight_inputs <- function() {
  b <- split_shares_present(BASE_DIR); n <- split_shares_present(NEW_DIR)
  cat(sprintf('  baseline split_shares present: %s\n', b))
  cat(sprintf('  new      split_shares present: %s\n', n))
  if (!isTRUE(is.na(b)) && !isTRUE(is.na(n)) && !identical(b, n)) {
    cat('\n  [!!] THE TWO VINTAGES USED DIFFERENT WEIGHT INPUTS.\n')
    cat('       One fell back to an even split for 484(f) code renumberings.\n')
    cat('       Historical ETR deltas below are an ARTIFACT of that, not of any\n')
    cat('       code change. Rebuild the deficient side before reading this diff.\n')
  }
}

# ---- weights-join diagnostic ------------------------------------------------
check_weights_join <- function(overall, label) {
  if (is.null(overall) || !all(c('matched_imports_b', 'total_imports_b') %in% names(overall))) {
    cat('  [--]', label, 'no import columns\n'); return(invisible(NULL))
  }
  pct <- 100 * overall$matched_imports_b / overall$total_imports_b
  ok  <- all(abs(pct - 100) < 1e-6)
  cat(sprintf('  [%s] %-28s matched/total = %.4f%% .. %.4f%%\n',
              if (ok) 'OK' else '!!', label, min(pct), max(pct)))
  if (!ok) cat('       ^ NOT 100% -> weights joined statically; see CLAUDE.md\n')
}

# ---- per-column delta report ------------------------------------------------
compare_frame <- function(base, new, label) {
  if (is.null(base) || is.null(new)) {
    cat('  SKIP', label, '(missing on one side)\n'); return(invisible(NULL))
  }
  cat('\n--', label, '--\n')
  only_new  <- setdiff(names(new),  names(base))
  only_base <- setdiff(names(base), names(new))
  if (length(only_new))  cat('  NEW columns    :', paste(only_new, collapse = ', '), '\n')
  if (length(only_base)) cat('  DROPPED columns:', paste(only_base, collapse = ', '), '\n')

  cat(sprintf('  date range     : baseline %s .. %s (%d days)\n',
              min(base$date), max(base$date), nrow(base)))
  cat(sprintf('                 : new      %s .. %s (%d days)\n',
              min(new$date), max(new$date), nrow(new)))
  extra <- setdiff(as.character(new$date), as.character(base$date))
  if (length(extra)) cat(sprintf('  dates only in new: %d (%s .. %s)\n',
                                 length(extra), min(extra), max(extra)))

  num_cols <- intersect(names(base), names(new))
  num_cols <- num_cols[map_lgl(num_cols, ~ is.numeric(base[[.x]]) && is.numeric(new[[.x]]))]

  # Rename explicitly rather than relying on join suffixes: a suffix can collide
  # with a real column (weighted_etr + "_new" IS weighted_etr_new), which
  # silently pairs the wrong two columns and invents differences.
  b_side <- base |> select(date, all_of(num_cols)) |> rename_with(~ paste0('B..', .x), all_of(num_cols))
  n_side <- new  |> select(date, all_of(num_cols)) |> rename_with(~ paste0('N..', .x), all_of(num_cols))
  shared <- inner_join(b_side, n_side, by = 'date') |> arrange(date)
  stopifnot(!any(duplicated(names(shared))))
  cat(sprintf('  shared dates   : %d\n', nrow(shared)))

  rows <- map_dfr(num_cols, function(cl) {
    b <- shared[[paste0('B..', cl)]]; n <- shared[[paste0('N..', cl)]]
    stopifnot(!is.null(b), !is.null(n), length(b) == nrow(shared))
    d <- n - b
    idx <- which(abs(d) > TOL)
    if (!length(idx)) return(tibble(column = cl, moved = 0L))
    tibble(column      = cl,
           moved       = length(idx),
           first_date  = as.character(shared$date[idx[1]]),
           last_date   = as.character(shared$date[idx[length(idx)]]),
           max_abs     = max(abs(d)),
           at_max      = as.character(shared$date[which.max(abs(d))]),
           signed_max  = d[which.max(abs(d))],
           final_delta = d[nrow(shared)])
  })

  changed <- rows |> filter(moved > 0) |> arrange(desc(max_abs))
  if (!nrow(changed)) {
    cat('  >> IDENTICAL on all ', length(num_cols), ' shared numeric columns\n', sep = '')
    return(invisible(NULL))
  }
  cat(sprintf('  >> %d of %d numeric columns moved:\n\n', nrow(changed), length(num_cols)))
  changed |>
    mutate(across(c(max_abs, signed_max, final_delta), ~ sprintf('%+.4f', .x * PP))) |>
    select(column, days = moved, first_date, last_date,
           `max|d|pp` = max_abs, at = at_max,
           `signed pp` = signed_max, `final pp` = final_delta) |>
    print(n = Inf, width = Inf)
  invisible(changed)
}

# ---- §338 marginal effect ---------------------------------------------------
s338_effect <- function(vintage_dir, label) {
  a <- read_daily(vintage_dir, 'actual',  'daily_overall.csv')
  n <- read_daily(vintage_dir, 'no_s338', 'daily_overall.csv')
  if (is.null(a) || is.null(n)) { cat(sprintf('  %-22s SKIP (no no_s338 series)\n', label)); return(NULL) }
  j <- inner_join(a |> select(date, etr_a = weighted_etr),
                  n |> select(date, etr_n = weighted_etr), by = 'date') |>
       arrange(date) |> mutate(delta_pp = (etr_a - etr_n) * PP)
  on <- j |> filter(abs(delta_pp) > TOL * PP)
  if (!nrow(on)) { cat(sprintf('  %-22s no dates where §338 moves the ETR\n', label)); return(NULL) }
  cat(sprintf('  %-22s turn-on %s .. %s | effect %+.4f pp (max %+.4f pp)\n',
              label, min(on$date), max(on$date),
              on$delta_pp[nrow(on)], on$delta_pp[which.max(abs(on$delta_pp))]))
  invisible(on)
}

# ---- run --------------------------------------------------------------------
hdr(paste0('VINTAGE COMPARISON\n  baseline: ', BASE_DIR, '\n  new     : ', NEW_DIR))

hdr('WEIGHT-INPUT PARITY (both vintages must have consumed the same inputs)')
check_weight_inputs()

hdr('WEIGHTS-JOIN DIAGNOSTIC (matched_imports_b must equal total_imports_b)')
for (s in SERIES) {
  check_weights_join(read_daily(BASE_DIR, s, 'daily_overall.csv'), paste0('baseline/', s))
  check_weights_join(read_daily(NEW_DIR,  s, 'daily_overall.csv'), paste0('new/', s))
}

for (s in SERIES) {
  hdr(paste0('SERIES: ', s))
  compare_frame(read_daily(BASE_DIR, s, 'daily_overall.csv'),
                read_daily(NEW_DIR,  s, 'daily_overall.csv'),
                paste0(s, ' / daily_overall'))
  compare_frame(read_daily(BASE_DIR, s, 'daily_by_authority.csv'),
                read_daily(NEW_DIR,  s, 'daily_by_authority.csv'),
                paste0(s, ' / daily_by_authority'))
}

if (all(c('actual', 'no_s338') %in% SERIES)) {
  hdr('SECTION 338 MARGINAL EFFECT (actual minus no_s338), per vintage')
  s338_effect(BASE_DIR, 'baseline')
  s338_effect(NEW_DIR,  'new')
}

cat('\ndone.\n')
