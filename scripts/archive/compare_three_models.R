# =============================================================================
# Three-model daily ETR comparison: policy fixes vs revision re-dating
# =============================================================================
#
# Decomposes the June 2026 changes into the six extreme-eta policy fixes vs
# the revision re-dating, via three model runs:
#   A = pre-fix code  x old dates  (worktree ../tariff-rate-tracker-modelA,
#                                   built at commit 5f4c8ac)
#   B = current code  x old dates  (data/timeseries_olddates, from
#                                   scripts/build_model_b_olddates.R)
#   D = current code  x new dates  (data/timeseries, production)
#
#   timing effect = D - B   (boundary shifts + the date-gated content they drive)
#   policy effect = B - A   (the six fixes, holding dates fixed)
#
# Daily ETR here = per-snapshot GTAP-trade-weighted mean total_rate, stepped
# over each model's revision intervals. Methodology notes (applied IDENTICALLY
# to all three models, so the deltas are clean):
#   - denominator = TOTAL imports (unmatched flows contribute 0), matching
#     the compare_etrs.R convention;
#   - the date-bounded expiry zeroings 09_daily_series applies (Swiss
#     framework expiry 2026-03-31, s122 expiry 2026-07-23) are NOT re-applied,
#     so levels after 2026-03-31 differ slightly from output/daily/
#     daily_overall.csv; cross-model DIFFERENCES remain interpretable.
#
# Outputs in output/model_compare/:
#   three_model_daily_etr.csv / .png, decomposition_monthly.csv
#
# Usage: Rscript scripts/compare_three_models.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})

PLOT_END <- as.Date('2026-06-05')

MODELS <- list(
  A = list(
    label = 'A: original (pre-fix code, old dates)',
    snap_dir = file.path(dirname(here()), 'tariff-rate-tracker-modelA', 'data', 'timeseries'),
    rev_csv = file.path(dirname(here()), 'tariff-rate-tracker-modelA', 'config', 'revision_dates.csv'),
    use_policy_dates = TRUE   # original convention: rev_16 Jun-4 override only
  ),
  B = list(
    label = 'B: new policy, old dates',
    snap_dir = here('data', 'timeseries_olddates'),
    rev_csv = here('config', 'revision_dates.csv'),
    use_policy_dates = FALSE  # raw effective_date = pre-redating dates
  ),
  D = list(
    label = 'D: new policy, new dates',
    snap_dir = here('data', 'timeseries'),
    rev_csv = here('config', 'revision_dates.csv'),
    use_policy_dates = TRUE
  )
)

# --- Weights (loaded once) ---
weights <- readRDS(here('data', 'weights', 'hs10_by_country_gtap_2024_con.rds')) %>%
  select(hts10 = hs10, country = cty_code, imports)
total_imports <- sum(weights$imports)
message('Weights: ', nrow(weights), ' flows, $',
        round(total_imports / 1e9, 1), 'B total')

# --- Per-model revision dates (replicates load_revision_dates swap) ---
read_rev_dates <- function(csv_path, use_policy_dates) {
  d <- read_csv(csv_path, col_types = cols(.default = col_character())) %>%
    mutate(
      effective_date = as.Date(effective_date),
      policy_effective_date = suppressWarnings(as.Date(policy_effective_date))
    )
  if (use_policy_dates) {
    d <- d %>%
      mutate(effective_date = if_else(!is.na(policy_effective_date),
                                      policy_effective_date, effective_date))
  }
  d %>% arrange(effective_date) %>% select(revision, effective_date)
}

# --- Per-snapshot weighted ETR ---
snapshot_etr <- function(snap_dir, revision) {
  f <- file.path(snap_dir, paste0('snapshot_', revision, '.rds'))
  if (!file.exists(f)) return(NA_real_)
  s <- readRDS(f)
  j <- s %>%
    select(hts10, country, total_rate) %>%
    inner_join(weights, by = c('hts10', 'country'))
  etr <- sum(j$imports * j$total_rate) / total_imports
  rm(s, j); gc(verbose = FALSE)
  etr
}

# --- Build each model's step series ---
series <- imap_dfr(MODELS, function(m, model_id) {
  message('\n=== Model ', model_id, ': ', m$label, ' ===')
  rd <- read_rev_dates(m$rev_csv, m$use_policy_dates)
  rd <- rd %>%
    mutate(
      valid_from = effective_date,
      valid_until = coalesce(lead(effective_date) - 1, PLOT_END)
    ) %>%
    filter(valid_from <= PLOT_END)

  rd$etr <- map_dbl(rd$revision, ~{
    e <- snapshot_etr(m$snap_dir, .x)
    message('  ', .x, ': ', ifelse(is.na(e), 'MISSING SNAPSHOT', sprintf('%.3f%%', 100 * e)))
    e
  })

  missing <- rd$revision[is.na(rd$etr)]
  if (length(missing) > 0) {
    warning('Model ', model_id, ' missing snapshots: ', paste(missing, collapse = ', '))
  }

  rd %>%
    filter(!is.na(etr)) %>%
    rowwise() %>%
    mutate(date = list(seq(valid_from, min(valid_until, PLOT_END), by = 'day'))) %>%
    unnest(date) %>%
    transmute(model = model_id, model_label = m$label, date, etr)
})

out_dir <- here('output', 'model_compare')
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

wide <- series %>%
  select(model, date, etr) %>%
  pivot_wider(names_from = model, values_from = etr) %>%
  arrange(date) %>%
  mutate(
    policy_effect_pp = 100 * (B - A),   # six fixes, dates held at old
    timing_effect_pp = 100 * (D - B),   # re-dating, policy held at new
    total_change_pp  = 100 * (D - A)
  )
write_csv(wide, file.path(out_dir, 'three_model_daily_etr.csv'))

# Month-end decomposition table
monthly <- wide %>%
  group_by(month = floor_date(date, 'month')) %>%
  slice_max(date, n = 1) %>%
  ungroup() %>%
  transmute(date, A_pct = 100 * A, B_pct = 100 * B, D_pct = 100 * D,
            policy_effect_pp, timing_effect_pp, total_change_pp)
write_csv(monthly, file.path(out_dir, 'decomposition_monthly.csv'))
message('\n=== Month-end decomposition (pp of overall ETR) ===')
print(as.data.frame(monthly %>% mutate(across(where(is.numeric), ~round(.x, 2)))),
      row.names = FALSE)

# --- Plot ---
shade <- tibble(
  xmin = as.Date(c('2025-04-01', '2025-09-15')),
  xmax = as.Date(c('2025-05-31', '2025-12-15')),
  window = c('Apr-May 2025: Geneva / auto-parts timing',
             'Sep-Dec 2025: wood / MHD / ag timing')
)

p <- ggplot(series, aes(date, 100 * etr, color = model_label)) +
  geom_rect(data = shade,
            aes(xmin = xmin, xmax = xmax, ymin = -Inf, ymax = Inf),
            inherit.aes = FALSE, fill = 'grey85', alpha = 0.45) +
  geom_step(linewidth = 0.7) +
  scale_color_manual(values = c('grey45', '#2166ac', '#b2182b')) +
  labs(
    title = 'Daily weighted ETR under three model configurations',
    subtitle = paste0('A→B vertical gap = six extreme-eta policy fixes; ',
                      'B→D gap = revision re-dating (change-record policy dates).\n',
                      'GTAP-2024 trade weights, total-imports denominator; ',
                      'expiry zeroings not re-applied (see script header).'),
    x = NULL, y = 'Weighted ETR (%)', color = NULL,
    caption = paste0('Models: A = commit 5f4c8ac x old revision_dates; ',
                     'B = current code x old dates (use_policy_dates = FALSE); ',
                     'D = current code x corrected dates. Generated ',
                     format(Sys.Date()), '.')
  ) +
  theme_minimal(base_size = 11) +
  theme(legend.position = 'bottom')

ggsave(file.path(out_dir, 'three_model_daily_etr.png'), p,
       width = 11, height = 6.5, dpi = 200)
message('Saved: ', file.path(out_dir, 'three_model_daily_etr.png'))
