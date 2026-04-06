#!/usr/bin/env Rscript
# Compare rev_32 snapshots: pre-fix vs post-fix code
library(tidyverse)
library(here)

source(here('src', 'helpers.R'))

pre_path  <- here('snapshot_rev32_prefix.rds')
post_path <- here('data', 'timeseries', 'snapshot_rev_32.rds')

pre  <- readRDS(pre_path)
post <- readRDS(post_path)

message('Pre-fix:  ', nrow(pre), ' rows, ', n_distinct(pre$hts10), ' products')
message('Post-fix: ', nrow(post), ' rows, ', n_distinct(post$hts10), ' products')

# --- Row-level comparison ---
# Join on hts10 + country
comp <- inner_join(
  pre  %>% select(hts10, country, base_rate, rate_232, rate_ieepa_recip, rate_ieepa_fent,
                  rate_301, rate_s122, rate_other, metal_share, total_additional, total_rate),
  post %>% select(hts10, country, base_rate, rate_232, rate_ieepa_recip, rate_ieepa_fent,
                  rate_301, rate_s122, rate_other, metal_share, total_additional, total_rate,
                  any_of(c('s232_annex'))),
  by = c('hts10', 'country'),
  suffix = c('_pre', '_post')
)

message('\nMatched rows: ', nrow(comp))

# Check for any differences
comp <- comp %>%
  mutate(
    diff_232 = rate_232_post - rate_232_pre,
    diff_ieepa = rate_ieepa_recip_post - rate_ieepa_recip_pre,
    diff_fent = rate_ieepa_fent_post - rate_ieepa_fent_pre,
    diff_301 = rate_301_post - rate_301_pre,
    diff_s122 = rate_s122_post - rate_s122_pre,
    diff_base = base_rate_post - base_rate_pre,
    diff_metal = metal_share_post - metal_share_pre,
    diff_total = total_rate_post - total_rate_pre,
    diff_additional = total_additional_post - total_additional_pre
  )

# Summary of differences
message('\n=== RATE DIFFERENCES (post - pre) ===\n')
cols <- c('diff_base', 'diff_232', 'diff_ieepa', 'diff_fent', 'diff_301',
          'diff_s122', 'diff_metal', 'diff_additional', 'diff_total')
labels <- c('base_rate', 'rate_232', 'rate_ieepa_recip', 'rate_ieepa_fent',
            'rate_301', 'rate_s122', 'metal_share', 'total_additional', 'total_rate')

message(sprintf('%-20s %10s %10s %10s %10s', '', 'N differ', 'Mean diff', 'Min diff', 'Max diff'))
message(strrep('-', 65))
for (i in seq_along(cols)) {
  diffs <- comp[[cols[i]]]
  n_diff <- sum(abs(diffs) > 1e-10)
  message(sprintf('%-20s %10d %+10.6f %+10.6f %+10.6f',
                  labels[i], n_diff,
                  mean(diffs), min(diffs), max(diffs)))
}

# Rows that differ at all
any_diff <- comp %>% filter(abs(diff_total) > 1e-10)
message(sprintf('\nRows with any total_rate difference: %d (%.2f%%)',
               nrow(any_diff), nrow(any_diff) / nrow(comp) * 100))

if (nrow(any_diff) > 0) {
  message('\n--- Breakdown of differing rows ---')

  # By chapter
  any_diff_ch <- any_diff %>%
    mutate(ch = substr(hts10, 1, 2)) %>%
    group_by(ch) %>%
    summarise(
      n = n(),
      mean_diff_232 = mean(diff_232),
      mean_diff_total = mean(diff_total),
      .groups = 'drop'
    ) %>%
    arrange(desc(n))

  message(sprintf('\n%-5s %8s %12s %12s', 'Ch', 'N rows', 'Avg Δ232', 'Avg Δtotal'))
  message(strrep('-', 40))
  for (j in seq_len(min(20, nrow(any_diff_ch)))) {
    r <- any_diff_ch[j, ]
    message(sprintf('%-5s %8d %+11.4f %+11.4f',
                    r$ch, r$n, r$mean_diff_232, r$mean_diff_total))
  }

  # By 232 direction
  message('\n--- Direction of 232 changes ---')
  message(sprintf('  232 increased: %d', sum(any_diff$diff_232 > 1e-10)))
  message(sprintf('  232 decreased: %d', sum(any_diff$diff_232 < -1e-10)))
  message(sprintf('  232 unchanged (other rate changed): %d',
                  sum(abs(any_diff$diff_232) <= 1e-10)))

  # Sample
  message('\n--- Sample of differing rows (first 10) ---')
  sample_rows <- any_diff %>% head(10)
  for (j in seq_len(nrow(sample_rows))) {
    r <- sample_rows[j, ]
    message(sprintf('  %s | cty=%s | 232: %.4f→%.4f | ieepa: %.4f→%.4f | total: %.4f→%.4f | metal: %.3f→%.3f',
                    r$hts10, r$country,
                    r$rate_232_pre, r$rate_232_post,
                    r$rate_ieepa_recip_pre, r$rate_ieepa_recip_post,
                    r$total_rate_pre, r$total_rate_post,
                    r$metal_share_pre, r$metal_share_post))
  }
}

# --- Weighted ETR comparison ---
message('\n=== WEIGHTED ETR COMPARISON ===\n')

local_cfg <- load_local_paths()
etrs_repo <- local_cfg$tariff_etrs_repo %||% file.path('..', 'Tariff-ETRs')
imports <- readRDS(file.path(etrs_repo, 'cache', 'hs10_by_country_gtap_2024_con.rds')) %>%
  group_by(hs10, cty_code) %>%
  summarise(value = sum(imports), .groups = 'drop') %>%
  filter(value > 0) %>%
  rename(hts10 = hs10, country = cty_code)
total_imports <- sum(imports$value)

for (label in c('pre', 'post')) {
  snap <- if (label == 'pre') pre else post
  matched <- snap %>%
    inner_join(imports, by = c('hts10', 'country')) %>%
    filter(value > 0)
  etr_total <- sum(matched$total_rate * matched$value) / total_imports * 100
  etr_232   <- sum(matched$rate_232 * matched$value) / total_imports * 100
  etr_ieepa <- sum(matched$rate_ieepa_recip * matched$value) / total_imports * 100
  message(sprintf('%-6s  total=%.3f%%  232=%.3f%%  ieepa=%.3f%%',
                  label, etr_total, etr_232, etr_ieepa))
}

# Check for rows only in one snapshot
pre_keys  <- paste(pre$hts10, pre$country)
post_keys <- paste(post$hts10, post$country)
only_pre  <- sum(!pre_keys %in% post_keys)
only_post <- sum(!post_keys %in% pre_keys)
message(sprintf('\nRows only in pre-fix:  %d', only_pre))
message(sprintf('Rows only in post-fix: %d', only_post))

# New columns in post
new_cols <- setdiff(names(post), names(pre))
if (length(new_cols) > 0) message('\nNew columns in post-fix: ', paste(new_cols, collapse = ', '))

# Cleanup
message('\nDone.')
