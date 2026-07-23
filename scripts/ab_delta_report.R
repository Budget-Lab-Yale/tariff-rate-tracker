#!/usr/bin/env Rscript
# =============================================================================
# ab_delta_report.R — quantify old-engine vs new-engine counterfactual drift
# =============================================================================
# The 2026-07 cleanup changed disabled_authorities semantics from post-hoc
# column zeroing to pre-calculation input removal. This script quantifies the
# resulting differences per scenario so they can be reviewed and approved.
#
# Usage:
#   Rscript scripts/ab_delta_report.R --old <old-vintage-root> --new <new-vintage-root>
# where each root is a published vintage dir (containing actual/ + scenarios/).
# Emits a per-scenario summary TSV to stdout and per-scenario country movers.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tidyr)
})

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag) {
  i <- which(args == flag)
  if (length(i) && i[1] < length(args)) args[i[1] + 1] else NULL
}
old_root <- get_arg('--old'); new_root <- get_arg('--new')
if (is.null(old_root) || is.null(new_root)) {
  stop('usage: analyze_ab_deltas.R --old <vintage-root> --new <vintage-root>', call. = FALSE)
}

series_dirs <- function(root) {
  s <- c(actual = file.path(root, 'actual'))
  scen_root <- file.path(root, 'scenarios')
  if (dir.exists(scen_root)) {
    for (nm in list.dirs(scen_root, recursive = FALSE, full.names = FALSE)) {
      s[nm] <- file.path(scen_root, nm)
    }
  }
  s
}

old_series <- series_dirs(old_root)
new_series <- series_dirs(new_root)
common <- intersect(names(old_series), names(new_series))
only_old <- setdiff(names(old_series), common)
only_new <- setdiff(names(new_series), common)
if (length(only_old)) cat('WARNING series only in old build:', paste(only_old, collapse = ', '), '\n')
if (length(only_new)) cat('WARNING series only in new build:', paste(only_new, collapse = ', '), '\n')

pp <- function(x) sprintf('%+.4f', 100 * x)   # fraction -> percentage points

overall_summary <- list()
for (nm in common) {
  fo <- file.path(old_series[[nm]], 'daily', 'daily_overall.csv')
  fn <- file.path(new_series[[nm]], 'daily', 'daily_overall.csv')
  if (!file.exists(fo) || !file.exists(fn)) {
    cat('WARNING missing daily_overall for', nm, '\n'); next
  }
  o <- read_csv(fo, show_col_types = FALSE)
  n <- read_csv(fn, show_col_types = FALSE)
  metric <- if ('weighted_etr' %in% names(o) && 'weighted_etr' %in% names(n)) {
    'weighted_etr'
  } else 'mean_total_all_pairs'
  j <- inner_join(o %>% select(date, old = all_of(metric)),
                  n %>% select(date, new = all_of(metric)), by = 'date') %>%
    mutate(diff = new - old)
  worst <- j %>% slice_max(abs(diff), n = 1, with_ties = FALSE)
  overall_summary[[nm]] <- tibble(
    series = nm, metric = metric,
    n_days = nrow(j),
    n_days_changed = sum(abs(j$diff) > 1e-9),
    mean_abs_diff_pp = 100 * mean(abs(j$diff)),
    max_abs_diff_pp = 100 * max(abs(j$diff)),
    worst_date = as.character(worst$date),
    worst_old_pct = 100 * worst$old,
    worst_new_pct = 100 * worst$new
  )
}

summary_tbl <- bind_rows(overall_summary) %>% arrange(desc(max_abs_diff_pp))
cat('\n=== daily_overall drift by series (old engine -> new engine) ===\n')
write_tsv(summary_tbl, stdout())

# Country-level movers on the worst day of each changed counterfactual.
for (nm in summary_tbl$series[summary_tbl$n_days_changed > 0]) {
  fo <- file.path(old_series[[nm]], 'daily', 'daily_by_country.csv')
  fn <- file.path(new_series[[nm]], 'daily', 'daily_by_country.csv')
  if (!file.exists(fo) || !file.exists(fn)) next
  wd <- summary_tbl$worst_date[summary_tbl$series == nm]
  o <- read_csv(fo, show_col_types = FALSE) %>% filter(as.character(date) == wd)
  n <- read_csv(fn, show_col_types = FALSE) %>% filter(as.character(date) == wd)
  metric <- if ('weighted_etr' %in% names(o) && 'weighted_etr' %in% names(n)) {
    'weighted_etr'
  } else 'mean_total_all_pairs'
  j <- inner_join(o %>% select(date, country, old = all_of(metric)),
                  n %>% select(date, country, new = all_of(metric)),
                  by = c('date', 'country')) %>%
    mutate(diff_pp = 100 * (new - old)) %>%
    filter(abs(diff_pp) > 1e-7) %>%
    arrange(desc(abs(diff_pp)))
  cat(sprintf('\n--- %s: top country movers on %s (%s, pp) ---\n', nm, wd, metric))
  print(as.data.frame(head(j, 12)), row.names = FALSE)
}
