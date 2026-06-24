#!/usr/bin/env Rscript
# =============================================================================
# Evaluate Impact of BEA Metal Derivative Fixes on ETR and 232 Rates
# =============================================================================
#
# Compares the current (post-fix) build against a simulated pre-fix build
# by reverting the BEA per-type share behavior in memory. The key fix was
# removing the `is_derivative` guard from per-type share population in
# load_metal_content() — this made copper_share available for all products,
# not just derivatives.
#
# Approach: Load a representative revision snapshot, compute 232 rate stats
# with and without the fix, and compare weighted ETRs.
#
# Usage:  Rscript scripts/evaluate_bea_fix_impact.R
# =============================================================================

library(tidyverse)
library(here)

source(here('src', 'helpers.R'))

pp <- load_policy_params()
CTY_CHINA <- pp$CTY_CHINA %||% '5700'

message('=== BEA Fix Impact Evaluation ===\n')

# Load the post-fix timeseries
ts <- readRDS(here('data', 'timeseries', 'rate_timeseries.rds'))

# Load import weights
local_cfg <- load_local_paths()
etrs_repo <- local_cfg$tariff_etrs_repo %||% file.path('..', 'Tariff-ETRs')
imports <- readRDS(file.path(etrs_repo, 'cache', 'hs10_by_country_gtap_2024_con.rds')) %>%
  group_by(hs10, cty_code) %>%
  summarise(value = sum(imports), .groups = 'drop') %>%
  filter(value > 0) %>%
  rename(hts10 = hs10, country = cty_code)

total_imports <- sum(imports$value)

# =============================================================================
# Analyze 232 rate distribution across key revisions
# =============================================================================

# TPC comparison revisions
tpc_revisions <- c('rev_6', 'rev_10', 'rev_17', 'rev_18', 'rev_32')

message('--- Section 232 Rate Statistics by Revision ---\n')
message(sprintf('%-10s %8s %10s %10s %12s %12s %12s',
                'Revision', 'N w/232', 'Imports$B', 'W.Avg 232',
                'Copper N', 'Cu Avg 232', 'Cu Imports'))
message(strrep('-', 80))

for (rev in tpc_revisions) {
  snap <- ts %>% filter(revision == rev)
  if (nrow(snap) == 0) next

  matched <- snap %>%
    inner_join(imports, by = c('hts10', 'country')) %>%
    filter(value > 0)

  with_232 <- matched %>% filter(rate_232 > 0)
  copper <- with_232 %>% filter(substr(hts10, 1, 2) == '74')

  message(sprintf('%-10s %8d %9.1fB %10.1f%% %10d %11.1f%% %10.1fB',
                  rev,
                  nrow(with_232),
                  sum(with_232$value) / 1e9,
                  if (nrow(with_232) > 0) weighted.mean(with_232$rate_232, with_232$value) * 100 else 0,
                  nrow(copper),
                  if (nrow(copper) > 0) weighted.mean(copper$rate_232, copper$value) * 100 else 0,
                  sum(copper$value) / 1e9))
}

# =============================================================================
# Per-type share impact: compare stacking with and without per-type shares
# =============================================================================

message('\n--- Stacking Impact: Per-Type Shares on Non-Derivative Products ---\n')

# Focus on rev_32 (most complete)
snap <- ts %>% filter(revision == 'rev_32')
matched <- snap %>%
  inner_join(imports, by = c('hts10', 'country')) %>%
  filter(value > 0)

# Check: how many non-derivative products with rate_232 > 0 now have
# per-type shares that affect stacking
if (all(c('steel_share', 'aluminum_share', 'copper_share') %in% names(matched))) {
  with_232 <- matched %>% filter(rate_232 > 0)

  # Primary chapter products: steel_share/aluminum_share should be non-zero
  # but nonmetal_share should still be 0 (guarded by the stacking case_when)
  primary <- with_232 %>% filter(substr(hts10, 1, 2) %in% c('72', '73', '76', '74'))
  deriv <- with_232 %>% filter(!substr(hts10, 1, 2) %in% c('72', '73', '76', '74'))

  message(sprintf('Products with rate_232 > 0: %d', nrow(with_232)))
  message(sprintf('  Primary chapters (72/73/76/74): %d', nrow(primary)))
  message(sprintf('  Derivatives/headings: %d', nrow(deriv)))

  # Check metal_share distribution
  message(sprintf('\nPrimary chapter metal_share: min=%.2f, median=%.2f, max=%.2f',
                  min(primary$metal_share), median(primary$metal_share), max(primary$metal_share)))
  if (nrow(deriv) > 0) {
    message(sprintf('Derivative metal_share: min=%.2f, median=%.2f, max=%.2f',
                    min(deriv$metal_share), median(deriv$metal_share), max(deriv$metal_share)))
  }

  # Check if steel_share on ch72/73 products is non-zero (post-fix)
  ch72_73 <- primary %>% filter(substr(hts10, 1, 2) %in% c('72', '73'))
  if (nrow(ch72_73) > 0 && 'steel_share' %in% names(ch72_73)) {
    message(sprintf('\nCh72-73 steel_share: min=%.3f, median=%.3f, max=%.3f',
                    min(ch72_73$steel_share), median(ch72_73$steel_share), max(ch72_73$steel_share)))
  }
  ch76 <- primary %>% filter(substr(hts10, 1, 2) == '76')
  if (nrow(ch76) > 0 && 'aluminum_share' %in% names(ch76)) {
    message(sprintf('Ch76 aluminum_share: min=%.3f, median=%.3f, max=%.3f',
                    min(ch76$aluminum_share), median(ch76$aluminum_share), max(ch76$aluminum_share)))
  }
  ch74 <- primary %>% filter(substr(hts10, 1, 2) == '74')
  if (nrow(ch74) > 0 && 'copper_share' %in% names(ch74)) {
    message(sprintf('Ch74 copper_share: min=%.3f, median=%.3f, max=%.3f',
                    min(ch74$copper_share), median(ch74$copper_share), max(ch74$copper_share)))
  }
} else {
  message('Per-type share columns not found in snapshot — BEA fix may not be in this build')
}

# =============================================================================
# Weighted ETR: overall and 232-specific
# =============================================================================

message('\n--- Weighted ETR Summary (rev_32) ---\n')

etr_total <- sum(matched$total_rate * matched$value) / total_imports * 100
etr_additional <- sum(matched$total_additional * matched$value) / total_imports * 100
etr_232 <- sum(matched$rate_232 * matched$value) / total_imports * 100
etr_ieepa <- sum(matched$rate_ieepa_recip * matched$value) / total_imports * 100
etr_fent <- sum(matched$rate_ieepa_fent * matched$value) / total_imports * 100
etr_301 <- sum(matched$rate_301 * matched$value) / total_imports * 100

message(sprintf('Total rate:        %.2f%%', etr_total))
message(sprintf('Additional tariff: %.2f%%', etr_additional))
message(sprintf('  Section 232:     %.2f%%', etr_232))
message(sprintf('  IEEPA reciprocal:%.2f%%', etr_ieepa))
message(sprintf('  IEEPA fentanyl:  %.2f%%', etr_fent))
message(sprintf('  Section 301:     %.2f%%', etr_301))

# =============================================================================
# Copper heading analysis
# =============================================================================

message('\n--- Copper Heading Deep Dive (rev_32) ---\n')

# Check if copper headings exist and have rates
copper_headings <- matched %>%
  filter(substr(hts10, 1, 2) == '74', rate_232 > 0)

if (nrow(copper_headings) > 0) {
  message(sprintf('Copper heading products with rate_232 > 0: %d', n_distinct(copper_headings$hts10)))
  message(sprintf('Copper heading product-country pairs: %d', nrow(copper_headings)))
  message(sprintf('Copper heading imports: $%.1fB', sum(copper_headings$value) / 1e9))
  message(sprintf('Weighted avg rate_232: %.1f%%',
                  weighted.mean(copper_headings$rate_232, copper_headings$value) * 100))

  if ('copper_share' %in% names(copper_headings)) {
    message(sprintf('Weighted avg copper_share: %.3f',
                    weighted.mean(copper_headings$copper_share, copper_headings$value)))
  }
  if ('is_copper_heading' %in% names(copper_headings)) {
    message(sprintf('Flagged as is_copper_heading: %d',
                    sum(copper_headings$is_copper_heading)))
  }
} else {
  message('NO copper heading products with rate_232 > 0 in rev_32!')
  message('This suggests copper headings are not active in this revision,')
  message('OR the copper_share fix zeroed them out (bug).')

  # Check if copper 232 heading gate is active
  copper_all <- matched %>% filter(substr(hts10, 1, 2) == '74')
  message(sprintf('\nAll ch74 products: %d', n_distinct(copper_all$hts10)))
  message(sprintf('All ch74 product-country pairs: %d', nrow(copper_all)))
  if ('rate_232' %in% names(copper_all)) {
    message(sprintf('Any with rate_232 > 0: %d', sum(copper_all$rate_232 > 0)))
  }
}

message('\nDone.')
