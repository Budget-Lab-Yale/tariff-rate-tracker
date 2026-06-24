#!/usr/bin/env Rscript
# =============================================================================
# plot_timeline_split_compare.R — daily-rate chart: OLD golden vs NEW (unified
# timeline boundary mints). Pass-2 / P2-1.
# =============================================================================
# Two-panel figure on the headline daily metric mean_total_all_pairs (the
# unweighted average total ad-valorem rate across all product-country pairs —
# the one column present in BOTH a weighted golden and an --unweighted new build):
#   (top)    both series overlaid, with the 3 boundary dates marked.
#   (bottom) delta (new - golden), so the boundary-window changes are visible.
# Also prints a terminal summary so the deltas are legible without opening the PNG.
#
# Usage:
#   Rscript scripts/plot_timeline_split_compare.R \
#     [--golden tests/golden/70b6b97] [--new <daily-dir>] [--out output/timeline_split_impact]
# =============================================================================

suppressPackageStartupMessages({ library(tidyverse); library(here) })

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, d = NULL) { i <- which(args == flag); if (length(i) && i[1] < length(args)) args[i[1]+1] else d }
golden_dir <- get_arg('--golden', here('tests', 'golden', '70b6b97'))
if (dir.exists(file.path(golden_dir, 'daily'))) golden_dir <- file.path(golden_dir, 'daily')
new_dir <- get_arg('--new', NULL)
# output/actual/daily is the live build output (actual_daily_dir); prefer it over a
# possibly-stale output/daily hand-run leftover.
if (is.null(new_dir)) for (c0 in c(here('output','actual','daily'), here('output','daily'), here('data','timeseries','daily')))
  if (file.exists(file.path(c0,'daily_overall.csv'))) { new_dir <- c0; break }
out_dir <- get_arg('--out', here('output', 'timeline_split_impact'))
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
stopifnot(!is.null(new_dir), dir.exists(golden_dir))
cat('GOLDEN:', golden_dir, '\n   NEW:', new_dir, '\n')

# Prefer the import-weighted ETR (the headline number — where IEEPA dominates)
# when BOTH series carry it; else fall back to the unweighted all-pairs mean.
go_raw <- suppressMessages(read_csv(file.path(golden_dir, 'daily_overall.csv'), show_col_types = FALSE))
no_raw <- suppressMessages(read_csv(file.path(new_dir,    'daily_overall.csv'), show_col_types = FALSE))
use_weighted <- all(c('weighted_etr') %in% names(go_raw)) && all(c('weighted_etr') %in% names(no_raw))
metric <- if (use_weighted) 'weighted_etr' else 'mean_total_all_pairs'
metric_label <- if (use_weighted) 'Import-weighted ETR (pp)' else 'Daily avg total rate, unweighted (pp)'
cat('Plotting metric:', metric, '\n')
rd <- function(raw) raw %>% transmute(date = as.Date(date), rate = .data[[metric]])
g <- rd(go_raw) %>% rename(golden = rate)
n <- rd(no_raw) %>% rename(new = rate)
cmp <- full_join(g, n, by = 'date') %>% arrange(date) %>% mutate(delta = new - golden)

bounds <- tibble(
  date  = as.Date(c('2025-03-12', '2026-02-20', '2026-11-10')),
  label = c('2025-03-12\n§232 exemption', '2026-02-20\nIEEPA invalid.', '2026-11-10\n§301 cranes'))

# ---- terminal summary -------------------------------------------------------
moved <- cmp %>% filter(abs(coalesce(delta, 0)) > 1e-6)
cat('\nDate span: ', format(min(cmp$date)), ' .. ', format(max(cmp$date)),
    ' | days where new != golden: ', nrow(moved), '\n', sep = '')
windows <- list(c('2025-03-08','2025-03-18'), c('2026-02-16','2026-02-28'), c('2026-11-06','2026-11-14'))
in_win <- function(d) Reduce(`|`, lapply(windows, function(w) d >= as.Date(w[1]) & d <= as.Date(w[2])))
cat('Moved days OUTSIDE the 3 boundary windows (regression guard, want 0): ',
    sum(!in_win(moved$date)), '\n', sep = '')
if (nrow(moved)) {
  cat('\n  date         golden(pp)   new(pp)   delta(pp)\n')
  moved %>% arrange(date) %>% slice_head(n = 30) %>% pmap(function(date, golden, new, delta)
    cat(sprintf('  %s   %7.3f   %7.3f   %+7.3f\n', format(date), 100*golden, 100*new, 100*delta)))
}

# ---- figure -----------------------------------------------------------------
lvl <- bind_rows(
  cmp %>% transmute(date, value = 100*golden, series = 'old golden (70b6b97)'),
  cmp %>% transmute(date, value = 100*new,    series = 'new (timeline mints)')) %>%
  mutate(panel = metric_label)
dlt <- cmp %>% transmute(date, value = 100*delta, series = 'new - golden') %>%
  mutate(panel = 'New - golden (pp)')
plot_df <- bind_rows(lvl, dlt) %>%
  mutate(panel = factor(panel, levels = c(metric_label, 'New - golden (pp)')))

p <- ggplot(plot_df, aes(date, value, color = series)) +
  geom_vline(data = bounds, aes(xintercept = date), linetype = 'dashed',
             color = 'grey55', linewidth = 0.3) +
  geom_line(linewidth = 0.5, na.rm = TRUE) +
  geom_hline(data = tibble(panel = factor('New - golden (pp)',
             levels = levels(plot_df$panel)), y = 0), aes(yintercept = y),
             color = 'grey70', linewidth = 0.3) +
  facet_wrap(~panel, ncol = 1, scales = 'free_y') +
  scale_color_manual(values = c('old golden (70b6b97)' = '#1b9e77',
                                'new (timeline mints)' = '#d95f02',
                                'new - golden' = '#7570b3')) +
  scale_x_date(date_breaks = '2 months', date_labels = '%b %y') +
  labs(title = 'Daily tariff rate: old golden vs unified-timeline mints',
       subtitle = paste0(if (use_weighted) 'import-weighted effective tariff rate' else
                         'unweighted mean total ad-valorem across all product-country pairs',
                         '; dashed = minted boundaries'),
       x = NULL, y = NULL, color = NULL) +
  theme_minimal(base_size = 11) +
  theme(legend.position = 'top', panel.grid.minor = element_blank(),
        axis.text.x = element_text(angle = 45, hjust = 1))

png_path <- file.path(out_dir, 'daily_rate_old_vs_new.png')
ggsave(png_path, p, width = 11, height = 7, dpi = 130)
cat('\nWrote chart: ', png_path, '\n', sep = '')
write_csv(cmp, file.path(out_dir, 'daily_overall_old_vs_new.csv'))
