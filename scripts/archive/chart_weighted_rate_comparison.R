#!/usr/bin/env Rscript
# =============================================================================
# chart_weighted_rate_comparison.R — total import-weighted daily tariff rate,
# before vs after the June-2026 master-fix integration.
# =============================================================================
#
# "After" = current build (output/actual/daily, the fixed + re-dated vintage).
# "Before" = the pre-fix baseline (tests/golden/9f9837d daily, == commit 96f341b
#            numerically; Pass-1 was parity-locked to it). Both use the same 2024
#            Census import weights, so the comparison is apples-to-apples.
#
# The by-date difference is the TOTAL effect (policy fixes + revision re-dating
# combined) a weighted-ETR consumer sees on each historical day.
#
# Usage:
#   Rscript scripts/chart_weighted_rate_comparison.R \
#     [--new output/actual/daily] [--old tests/golden/9f9837d/daily] \
#     [--out output/master_fix_impact/weighted_rate_comparison.png]
# =============================================================================

suppressPackageStartupMessages({ library(tidyverse); library(here) })

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, d=NULL) { i<-which(args==flag); if(length(i)&&i[1]<length(args)) args[i[1]+1] else d }
new_dir <- get_arg('--new', here('output','actual','daily'))
old_dir <- get_arg('--old', here('tests','golden','9f9837d','daily'))
out_png <- get_arg('--out', here('output','master_fix_impact','weighted_rate_comparison.png'))
dir.create(dirname(out_png), recursive = TRUE, showWarnings = FALSE)

rd <- function(d) suppressMessages(read_csv(file.path(d,'daily_overall.csv'), show_col_types=FALSE)) %>%
  transmute(date = as.Date(date), weighted_etr, weighted_etr_additional)
new <- rd(new_dir) %>% mutate(series = 'After (fixed + re-dated)')
old <- rd(old_dir) %>% mutate(series = 'Before (pre-fix baseline)')
df  <- bind_rows(old, new) %>%
  mutate(series = factor(series, levels = c('Before (pre-fix baseline)', 'After (fixed + re-dated)')))

# focus the x-axis on the period with variation (last revision is dated 2026-05-01;
# everything after is the flat carried-forward tail)
xmax <- as.Date('2026-06-30')
df_plot <- df %>% filter(date <= xmax)

avg_old <- mean(old$weighted_etr); avg_new <- mean(new$weighted_etr)
subtitle <- sprintf('Import-weighted effective rate (2024 Census weights). Time-avg: %.2f%% → %.2f%% (%+.2fpp). Combines policy fixes + revision re-dating.',
                    100*avg_old, 100*avg_new, 100*(avg_new-avg_old))

p <- ggplot(df_plot, aes(date, 100*weighted_etr, color = series)) +
  geom_step(linewidth = 0.7, direction = 'hv') +
  scale_color_manual(values = c('Before (pre-fix baseline)' = '#9e9e9e',
                                 'After (fixed + re-dated)'  = '#1565c0')) +
  scale_x_date(date_breaks = '2 months', date_labels = "%b\n%Y") +
  scale_y_continuous(labels = function(x) paste0(x, '%'), limits = c(0, NA)) +
  labs(title = 'U.S. import-weighted average tariff rate: before vs after the June 2026 fixes',
       subtitle = subtitle, x = NULL, y = 'Weighted effective tariff rate',
       color = NULL,
       caption = 'Before = golden 9f9837d (≡ commit 96f341b). After = theseus HEAD. Daily series; flat after 2026-05-01 (last revision).') +
  theme_minimal(base_size = 12) +
  theme(legend.position = 'top', plot.title = element_text(face = 'bold'),
        panel.grid.minor = element_blank())

ggsave(out_png, p, width = 11, height = 6, dpi = 150)
cat('Wrote chart:', out_png, '\n')
cat(sprintf('  Before time-avg: %.3f%%  |  After time-avg: %.3f%%  |  delta %+.3fpp\n',
            100*avg_old, 100*avg_new, 100*(avg_new-avg_old)))
