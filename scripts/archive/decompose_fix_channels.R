# =============================================================================
# Per-fix decomposition of the policy effect (Model B vs Model A)
# =============================================================================
#
# Splits B - A (current code vs pre-fix code, SAME old dates) into the six
# extreme-eta fixes by diffing matched-revision snapshots cell-by-cell and
# allocating the trade-weighted change in total_rate to rule-based channels.
# The fixes touch nearly disjoint cell sets, so allocation is clean; whatever
# the rules cannot attribute lands in `residual` and is reported honestly.
#
# Channels (first matching rule wins, in this order):
#   fix1_universe   hts10 present in B but not in A (8-digit leaf lines)
#   fix2_8471_auto  ch 8471 (non-semi) where rate_232 fell (auto-parts un-sweep)
#   fix3_country_eo India (5330) / Brazil (3510) reciprocal changes
#   fix4_berman     ch97 / ch49 reciprocal changes
#   fix5_windows    reciprocal changes on the Annex-II windowed chapters
#                   (ag 02-22 group, ch06 flowers, ch44 wood, ch74 copper)
#   fix6_usmca      CA (1220) / MX (2010) changes in fent/s122/232 channels
#   residual        everything else (incl. interactions)
#
# Run AFTER models A and B are built. Defaults to three matched revisions
# spanning the regimes; pass alternatives as CLI args.
#
# Usage: Rscript scripts/decompose_fix_channels.R [rev ...]
#        (default: rev_18 rev_25 2026_rev_2)
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})

args <- commandArgs(trailingOnly = TRUE)
REVS <- if (length(args) > 0) args else c('rev_18', 'rev_25', '2026_rev_2')

A_DIR <- file.path(dirname(here()), 'tariff-rate-tracker-modelA', 'data', 'timeseries')
B_DIR <- here('data', 'timeseries_olddates')

weights <- readRDS(here('data', 'weights', 'hs10_by_country_gtap_2024_con.rds')) %>%
  select(hts10 = hs10, country = cty_code, imports)
total_imports <- sum(weights$imports)

semi <- read_csv(here('resources', 's232_semi_products.csv'),
                 col_types = cols(hts10 = col_character()),
                 show_col_types = FALSE)$hts10

AG_CH <- sprintf('%02d', c(2, 6, 7, 8, 9, 10, 11, 12, 15, 16, 18, 19, 20, 21, 22))

decompose_rev <- function(rev) {
  fa <- file.path(A_DIR, paste0('snapshot_', rev, '.rds'))
  fb <- file.path(B_DIR, paste0('snapshot_', rev, '.rds'))
  if (!file.exists(fa) || !file.exists(fb)) {
    warning(rev, ': snapshot missing (A: ', file.exists(fa),
            ', B: ', file.exists(fb), ') — skipped')
    return(NULL)
  }
  message('\n=== ', rev, ' ===')

  cols_keep <- c('hts10', 'country', 'total_rate', 'rate_232',
                 'rate_ieepa_recip', 'rate_ieepa_fent', 'rate_s122')
  a <- readRDS(fa) %>% select(any_of(cols_keep))
  a_hts <- unique(a$hts10)
  b <- readRDS(fb) %>% select(any_of(cols_keep))

  d <- b %>%
    full_join(a, by = c('hts10', 'country'), suffix = c('_b', '_a')) %>%
    mutate(across(ends_with('_a') | ends_with('_b'), ~coalesce(.x, 0))) %>%
    mutate(d_total = total_rate_b - total_rate_a) %>%
    filter(abs(d_total) > 1e-12) %>%
    inner_join(weights, by = c('hts10', 'country'))
  rm(a, b); gc(verbose = FALSE)

  new_in_b <- !d$hts10 %in% a_hts
  # (full_join already coalesced A-side rates to 0 for these rows)

  d <- d %>%
    mutate(
      ch2 = substr(hts10, 1, 2),
      hts4 = substr(hts10, 1, 4),
      channel = case_when(
        new_in_b ~ 'fix1_universe',
        hts4 == '8471' & !hts10 %in% semi &
          abs(rate_232_b - rate_232_a) > 1e-12 ~ 'fix2_8471_auto',
        country %in% c('5330', '3510') &
          abs(rate_ieepa_recip_b - rate_ieepa_recip_a) > 1e-12 ~ 'fix3_country_eo',
        ch2 %in% c('97', '49') &
          abs(rate_ieepa_recip_b - rate_ieepa_recip_a) > 1e-12 ~ 'fix4_berman',
        (ch2 %in% AG_CH | ch2 %in% c('44', '74')) &
          abs(rate_ieepa_recip_b - rate_ieepa_recip_a) > 1e-12 ~ 'fix5_windows',
        country %in% c('1220', '2010') ~ 'fix6_usmca',
        TRUE ~ 'residual'
      ),
      contrib_pp = 100 * imports * d_total / total_imports
    )

  out <- d %>%
    group_by(channel) %>%
    summarise(
      etr_contribution_pp = sum(contrib_pp),
      n_cells = n(),
      imports_b = sum(imports) / 1e9,
      .groups = 'drop'
    ) %>%
    arrange(etr_contribution_pp) %>%
    mutate(revision = rev, .before = 1)

  total_row <- tibble(
    revision = rev, channel = 'TOTAL (B - A)',
    etr_contribution_pp = sum(d$contrib_pp),
    n_cells = nrow(d), imports_b = sum(d$imports) / 1e9
  )
  rm(d); gc(verbose = FALSE)
  bind_rows(out, total_row)
}

results <- map_dfr(REVS, decompose_rev)

out_dir <- here('output', 'model_compare')
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
write_csv(results, file.path(out_dir, 'fix_channel_decomposition.csv'))

message('\n=== Per-fix contributions to the weighted ETR (pp), B - A ===')
print(as.data.frame(results %>%
        mutate(etr_contribution_pp = round(etr_contribution_pp, 3),
               imports_b = round(imports_b, 1))),
      row.names = FALSE)
message('\nSaved: ', file.path(out_dir, 'fix_channel_decomposition.csv'))
