#!/usr/bin/env Rscript
# =============================================================================
# report_timeline_split_impact.R — quantify how the unified-timeline boundary
# mints change the daily rate series vs the frozen golden (Pass-2 / P2-1).
# =============================================================================
#
# Compares the NEW daily series (theseus + the bnd_ boundary mints) against the
# GOLDEN daily series BY CALENDAR DATE. The mints split three revision intervals
# and recompute the owner archive as-of the boundary date, so the daily series
# changes ONLY inside the affected windows:
#   * 2025-03-12 cluster  — §232 metal country-exemption expiry (in-window): CA/MX
#     /EU/UK/JP/KR/AU/BR/AR/UA steel+aluminum jump 0->25% on 03-12..03-13 (was held
#     to 03-14 at rev_5).
#   * 2026-02-20..02-23   — IEEPA invalidation pulled forward from 02-24; opens the
#     4-day window where IEEPA reciprocal+fentanyl AND S122 are all 0.
#   * 2026-11-10 onward   — §301 cranes/chassis (9903.91.12-.16, China) turn on.
# Everything ELSE must be byte-identical (a built-in regression guard).
#
# Usage:
#   Rscript scripts/report_timeline_split_impact.R \
#     [--golden tests/golden/70b6b97] [--new <daily-dir>] [--out output/timeline_split_impact]
# =============================================================================

suppressPackageStartupMessages({ library(tidyverse); library(here) })

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, default = NULL) {
  i <- which(args == flag); if (length(i) && i[1] < length(args)) args[i[1] + 1] else default
}
golden_dir <- get_arg('--golden', here('tests', 'golden', '70b6b97'))
if (dir.exists(file.path(golden_dir, 'daily'))) golden_dir <- file.path(golden_dir, 'daily')
new_dir <- get_arg('--new', NULL)
if (is.null(new_dir)) {
  # output/actual/daily is where save_daily_outputs() (actual_daily_dir()) writes
  # the live build — check it FIRST. output/daily can be a stale hand-run leftover.
  for (cand in c(here('output', 'actual', 'daily'), here('output', 'daily'),
                 here('data', 'timeseries', 'daily'))) {
    if (file.exists(file.path(cand, 'daily_overall.csv'))) { new_dir <- cand; break }
  }
}
out_dir <- get_arg('--out', here('output', 'timeline_split_impact'))
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
stopifnot(!is.null(new_dir), dir.exists(golden_dir))
cat('GOLDEN daily:', golden_dir, '\n   NEW daily:', new_dir, '\n   out:', out_dir, '\n\n')

rd  <- function(d, f) suppressMessages(read_csv(file.path(d, f), show_col_types = FALSE))
ppf <- function(x) sprintf('%+.4fpp', 100 * x)

# Boundary windows (a couple of days either side, for context).
# 2026-11-10 extends to the horizon: the §301 cranes/chassis mint is the new tip,
# so its priced interval [2026-11-10, horizon] all moves vs golden (expected).
windows <- list(
  `2025-03-12 §232 exemption (in-window)`  = as.Date(c('2025-03-08', '2025-03-18')),
  `2026-02-20 IEEPA invalidation + gap`     = as.Date(c('2026-02-16', '2026-02-28')),
  `2026-11-10 §301 cranes/chassis turn-on`  = as.Date(c('2026-11-06', '2026-12-31'))
)
in_window <- function(d) Reduce(`|`, lapply(windows, function(w) d >= w[1] & d <= w[2]))

# ---- 1. Overall by date ------------------------------------------------------
go <- rd(golden_dir, 'daily_overall.csv'); no <- rd(new_dir, 'daily_overall.csv')
ov <- inner_join(
  go %>% transmute(date, g_total = mean_total_all_pairs, g_add = mean_additional_all_pairs, g_rev = revision),
  no %>% transmute(date, n_total = mean_total_all_pairs, n_add = mean_additional_all_pairs, n_rev = revision),
  by = 'date') %>%
  mutate(d_total = n_total - g_total, d_add = n_add - g_add)
new_only <- anti_join(no, go, by = 'date')   # dates the new series adds (e.g. shifted tip)
gold_only <- anti_join(go, no, by = 'date')

cat('================= OVERALL (mean_total_all_pairs, by date) =================\n')
cat('Common dates:', nrow(ov), '| new-only dates:', nrow(new_only),
    '| golden-only dates:', nrow(gold_only), '\n')
moved <- ov %>% filter(abs(d_total) > 1e-6)
cat('Dates that MOVED (|delta total| > 1e-6):', nrow(moved), 'of', nrow(ov), '\n')
cat('  of which OUTSIDE the three boundary windows:',
    sum(!in_window(moved$date)), ' <-- MUST be 0 (regression guard)\n\n')
if (nrow(moved)) {
  cat('--- all moved dates ---\n')
  print(moved %>% arrange(date) %>%
          transmute(date, g_rev, n_rev, golden = ppf(g_total), new = ppf(n_total),
                    delta = ppf(d_total), window = in_window(date)) %>% as.data.frame())
}
write_csv(ov, file.path(out_dir, 'overall_by_date.csv'))

# ---- 2. By authority, within each boundary window ----------------------------
ga <- rd(golden_dir, 'daily_by_authority.csv'); na_ <- rd(new_dir, 'daily_by_authority.csv')
auth_cols <- intersect(grep('^etr_|^mean_', names(ga), value = TRUE), names(na_))
auth <- inner_join(ga %>% select(date, all_of(auth_cols)),
                   na_ %>% select(date, all_of(auth_cols)),
                   by = 'date', suffix = c('_g', '_n'))
cat('\n================= BY AUTHORITY (deltas inside boundary windows) =================\n')
for (nm in names(windows)) {
  w <- windows[[nm]]
  seg <- auth %>% filter(date >= w[1], date <= w[2])
  if (!nrow(seg)) { cat('\n[', nm, '] no daily rows in window\n'); next }
  cat('\n[', nm, ']  ', format(w[1]), '..', format(w[2]), '\n', sep = '')
  for (c0 in auth_cols) {
    dd <- seg[[paste0(c0, '_n')]] - seg[[paste0(c0, '_g')]]
    if (any(abs(dd) > 1e-6, na.rm = TRUE)) {
      cat(sprintf('   %-16s mean delta %s  (max |delta| %s on %s)\n', c0,
                  ppf(mean(dd, na.rm = TRUE)), ppf(max(abs(dd), na.rm = TRUE)),
                  format(seg$date[which.max(abs(dd))])))
    }
  }
}
write_csv(auth, file.path(out_dir, 'by_authority.csv'))

# ---- 3. By country, the 03-12 §232 window (the headline in-window movers) ----
gc <- rd(golden_dir, 'daily_by_country.csv'); nc <- rd(new_dir, 'daily_by_country.csv')
metric <- intersect('mean_total_exposed', names(gc))
if (length(metric) && 'country' %in% names(gc)) {
  w <- windows[[1]]
  cty <- inner_join(
    gc %>% filter(date >= w[1], date <= w[2]) %>% transmute(date, country, g = .data[[metric]]),
    nc %>% filter(date >= w[1], date <= w[2]) %>% transmute(date, country, n = .data[[metric]]),
    by = c('date', 'country')) %>%
    mutate(d = n - g) %>% filter(abs(d) > 1e-6)
  cat('\n================= BY COUNTRY (03-12 window, mean_total_exposed movers) =================\n')
  top <- cty %>% group_by(country) %>%
    summarise(max_delta = max(abs(d)), first_date = min(date), .groups = 'drop') %>%
    arrange(desc(max_delta)) %>% head(15)
  print(top %>% mutate(max_delta = ppf(max_delta)) %>% as.data.frame())
  write_csv(cty, file.path(out_dir, 'by_country_0312.csv'))
}

cat('\nWrote impact CSVs to ', out_dir, '\n', sep = '')
cat('Regression guard: OVERALL moved dates outside the 3 windows must be 0.\n')
