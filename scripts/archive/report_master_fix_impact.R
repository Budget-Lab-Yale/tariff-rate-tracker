#!/usr/bin/env Rscript
# =============================================================================
# report_master_fix_impact.R — quantify how the ported master fixes + revision
# re-dating change the historical daily rate series vs the frozen reference.
# =============================================================================
#
# Compares the NEW daily series (current theseus = pmax-wiring + the 6 extreme-eta
# fixes + revision re-dating) against the REFERENCE daily series (9f9837d, pre-fix)
# BY CALENDAR DATE. A by-date comparison captures the TOTAL effect a downstream
# consumer sees on each historical day — both the policy-fix channel (rates move
# within a revision) and the timing channel (revision boundaries shift from the
# re-dating). It does NOT separate the two; that needs John's three-model run.
#
# Headline metric: mean_total_all_pairs (mean total ad-valorem rate across all
# product-country pairs that day). Also reports mean_additional_all_pairs.
#
# Usage:
#   Rscript scripts/report_master_fix_impact.R \
#     [--reference <daily-dir>] [--new <daily-dir>] [--out output/master_fix_impact]
#   (--reference defaults to <model_data_root>/latest/actual/daily)
# =============================================================================

suppressPackageStartupMessages({ library(tidyverse); library(here) })
source(here('src', 'policy_params.R'))   # load_local_paths() -> model_data_root

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, default = NULL) {
  i <- which(args == flag); if (length(i) && i[1] < length(args)) args[i[1] + 1] else default
}
# Reference = the latest published vintage's daily series (<model_data_root>/latest).
default_reference <- local({
  r <- tryCatch(load_local_paths()$model_data_root, error = function(e) NULL)
  if (is.null(r) || !nzchar(r)) NULL else file.path(r, 'latest', 'actual', 'daily')
})
reference_dir <- get_arg('--reference', default_reference)
if (is.null(reference_dir)) stop('--reference <dir> required (model_data_root/latest not resolvable)', call. = FALSE)
if (!dir.exists(reference_dir) && dir.exists(file.path(reference_dir, 'daily')))
  reference_dir <- file.path(reference_dir, 'daily')
# New daily location: try the common spots
new_dir <- get_arg('--new', NULL)
if (is.null(new_dir)) {
  for (cand in c(here('data', 'timeseries', 'daily'),
                 here('output', 'actual', 'daily'),
                 here('data', 'timeseries'))) {
    if (file.exists(file.path(cand, 'daily_overall.csv'))) { new_dir <- cand; break }
  }
}
out_dir <- get_arg('--out', here('output', 'master_fix_impact'))
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
stopifnot(!is.null(new_dir))
cat('REFERENCE daily:', reference_dir, '\n   NEW daily:', new_dir, '\n\n')

rd <- function(d, f) suppressMessages(read_csv(file.path(d, f), show_col_types = FALSE))
pp <- function(x) sprintf('%+.3fpp', 100 * x)

# ---- 1. Overall -----------------------------------------------------------
go <- rd(reference_dir, 'daily_overall.csv'); no <- rd(new_dir, 'daily_overall.csv')
ov <- inner_join(
  go %>% select(date, g_total = mean_total_all_pairs, g_add = mean_additional_all_pairs, g_rev = revision),
  no %>% select(date, n_total = mean_total_all_pairs, n_add = mean_additional_all_pairs, n_rev = revision),
  by = 'date') %>%
  mutate(d_total = n_total - g_total, d_add = n_add - g_add)

cat('================= OVERALL (mean_total_all_pairs, by calendar date) =================\n')
cat('Common dates:', nrow(ov),
    '| reference-only dates:', nrow(anti_join(go, no, by='date')),
    '| new-only dates:', nrow(anti_join(no, go, by='date')), '\n')
cat('Time-avg mean total rate  REFERENCE:', pp(mean(ov$g_total)),
    ' NEW:', pp(mean(ov$n_total)),
    ' delta:', pp(mean(ov$d_total)), '\n')
cat('Dates with |delta| > 0.01pp:', sum(abs(ov$d_total) > 1e-4), 'of', nrow(ov), '\n\n')
cat('--- 15 biggest-moving dates (|delta total rate|) ---\n')
print(ov %>% mutate(absd = abs(d_total)) %>% arrange(desc(absd)) %>% head(15) %>%
        transmute(date, g_rev, n_rev, reference = pp(g_total), new = pp(n_total), delta = pp(d_total)) %>%
        as.data.frame())
write_csv(ov, file.path(out_dir, 'overall_by_date.csv'))

# ---- 2. By authority ------------------------------------------------------
cat('\n================= BY AUTHORITY (time-avg mean rate) =================\n')
ga <- rd(reference_dir, 'daily_by_authority.csv'); na <- rd(new_dir, 'daily_by_authority.csv')
auth_cols <- intersect(grep('^mean_', names(ga), value = TRUE), names(na))
ja <- inner_join(ga %>% select(date, all_of(auth_cols)) %>% rename_with(~paste0('g_', .), all_of(auth_cols)),
                 na %>% select(date, all_of(auth_cols)) %>% rename_with(~paste0('n_', .), all_of(auth_cols)),
                 by = 'date')
auth_tab <- map_dfr(auth_cols, function(c) {
  tibble(authority = sub('^mean_', '', c),
         reference = mean(ja[[paste0('g_', c)]], na.rm = TRUE),
         new    = mean(ja[[paste0('n_', c)]], na.rm = TRUE)) %>%
    mutate(delta = new - reference)
}) %>% arrange(desc(abs(delta)))
print(auth_tab %>% transmute(authority, reference = pp(reference), new = pp(new), delta = pp(delta)) %>% as.data.frame())
write_csv(auth_tab, file.path(out_dir, 'by_authority.csv'))

# ---- 3. By country --------------------------------------------------------
cat('\n================= BY COUNTRY (time-avg mean_total_all_pairs) =================\n')
gc <- rd(reference_dir, 'daily_by_country.csv'); nc <- rd(new_dir, 'daily_by_country.csv')
jc <- inner_join(
  gc %>% group_by(country, country_name) %>% summarise(reference = mean(mean_total_all_pairs, na.rm=TRUE), .groups='drop'),
  nc %>% group_by(country) %>% summarise(new = mean(mean_total_all_pairs, na.rm=TRUE), .groups='drop'),
  by = 'country') %>%
  mutate(delta = new - reference)
cat('--- Canada / Mexico (the documented movers) ---\n')
print(jc %>% filter(country %in% c('1220','2010')) %>%
        transmute(country, country_name, reference=pp(reference), new=pp(new), delta=pp(delta)) %>% as.data.frame())
cat('\n--- 20 biggest country movers (|delta|) ---\n')
print(jc %>% arrange(desc(abs(delta))) %>% head(20) %>%
        transmute(country, country_name, reference=pp(reference), new=pp(new), delta=pp(delta)) %>% as.data.frame())
write_csv(jc %>% arrange(desc(abs(delta))), file.path(out_dir, 'by_country.csv'))

cat('\nWrote: ', file.path(out_dir, c('overall_by_date.csv','by_authority.csv','by_country.csv')), sep='\n  ')
cat('\n')
