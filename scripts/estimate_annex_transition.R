#!/usr/bin/env Rscript
# =============================================================================
# Estimate ETR Impact of Section 232 Annex Restructuring
# =============================================================================
#
# Takes the latest pre-April-6 snapshot (2026_rev_4), applies annex
# reclassification and rate overrides to produce a counterfactual
# "first day of new regime," then compares import-weighted ETRs.
#
# Usage:  Rscript scripts/estimate_annex_transition.R
#
# Requires:
#   - Built timeseries (data/timeseries/rate_timeseries.rds)
#   - Import weights (Tariff-ETRs cache, via config/local_paths.yaml)
#   - Annex product classification (resources/s232_annex_products.csv)
#
# =============================================================================

library(tidyverse)
library(here)

source(here('src', 'helpers.R'))

pp <- load_policy_params()
annex_cfg <- pp$S232_ANNEXES
CTY_CHINA <- pp$CTY_CHINA %||% '5700'

# =============================================================================
# 1. Load snapshot and imports
# =============================================================================

message('=== Section 232 Annex Transition Estimate ===\n')

ts_path <- here('data', 'timeseries', 'rate_timeseries.rds')
stopifnot(file.exists(ts_path))

ts <- readRDS(ts_path)

# Use 2026_rev_4 as the last pre-annex revision
pre <- ts %>% filter(revision == '2026_rev_4')
message('Pre-annex snapshot (2026_rev_4): ', n_distinct(pre$hts10), ' products, ',
        n_distinct(pre$country), ' countries, ', nrow(pre), ' rows')

# Load import weights
local_cfg <- load_local_paths()
etrs_repo <- local_cfg$tariff_etrs_repo %||% file.path('..', 'Tariff-ETRs')
imports_path <- file.path(etrs_repo, 'cache', 'hs10_by_country_gtap_2024_con.rds')
stopifnot(file.exists(imports_path))

imports <- readRDS(imports_path) %>%
  group_by(hs10, cty_code) %>%
  summarise(value = sum(imports), .groups = 'drop') %>%
  filter(value > 0) %>%
  rename(hts10 = hs10, country = cty_code)

total_imports <- sum(imports$value)
message('Import weights: ', round(total_imports / 1e9, 1), 'B total\n')

# =============================================================================
# 2. Load annex classification
# =============================================================================

annex_map <- load_annex_products(effective_date = '2026-04-06')
message('Annex product map: ', nrow(annex_map), ' entries')
annex_map %>% count(s232_annex) %>%
  mutate(label = paste0('  ', s232_annex, ': ', n, ' prefixes')) %>%
  pull(label) %>% walk(message)

# =============================================================================
# 3. Build pre and post snapshots
# =============================================================================

# --- Pre-annex: as-is from 2026_rev_4 ---
pre_rates <- pre %>%
  select(hts10, country, base_rate, rate_232, rate_ieepa_recip, rate_ieepa_fent,
         rate_301, rate_s122, rate_section_201, rate_other, metal_share,
         total_additional, total_rate,
         any_of(c('steel_share', 'aluminum_share', 'copper_share',
                   'deriv_type', 'is_copper_heading')))

# --- Post-annex: apply annex overrides ---
post_rates <- pre_rates

# Prefix-match annex classification
post_rates$s232_annex <- NA_character_
for (i in seq_len(nrow(annex_map))) {
  mask <- startsWith(post_rates$hts10, annex_map$hts_prefix[i])
  post_rates$s232_annex[mask & is.na(post_rates$s232_annex)] <- annex_map$s232_annex[i]
}

# Infer annex_1a for primary chapter products not in resource file
post_rates <- post_rates %>%
  mutate(s232_annex = case_when(
    !is.na(s232_annex) ~ s232_annex,
    rate_232 > 0 & substr(hts10, 1, 2) %in% c('72', '73', '76', '74') ~ '1a',
    TRUE ~ s232_annex
  ))

# Save pre-override rate for decomposition
post_rates$rate_232_pre <- post_rates$rate_232

# Apply annex rate overrides
post_rates <- post_rates %>%
  mutate(rate_232 = case_when(
    s232_annex == '2'  ~ 0,
    s232_annex == '1a' ~ annex_cfg$annexes$annex_1a$rate,
    s232_annex == '1b' ~ annex_cfg$annexes$annex_1b$rate,
    s232_annex == '3'  ~ pmax(0, annex_cfg$annexes$annex_3$floor_rate - base_rate),
    TRUE ~ rate_232
  ))

# UK deal overrides
uk_code <- '4120'
uk_chapters <- c('72', '73', '76')
post_rates <- post_rates %>%
  mutate(rate_232 = case_when(
    country == uk_code & s232_annex == '1a' &
      substr(hts10, 1, 2) %in% uk_chapters ~ annex_cfg$annexes$annex_1a$uk_rate,
    country == uk_code & s232_annex == '1b' &
      substr(hts10, 1, 2) %in% uk_chapters ~ annex_cfg$annexes$annex_1b$uk_rate,
    TRUE ~ rate_232
  ))

# Re-apply stacking rules
post_rates <- apply_stacking_rules(post_rates, CTY_CHINA)

# =============================================================================
# 4. Join imports and compute weighted ETRs
# =============================================================================

compute_weighted_etr <- function(rates, imports, total_imports, label) {
  matched <- rates %>%
    inner_join(imports, by = c('hts10', 'country')) %>%
    filter(value > 0)

  matched_imports <- sum(matched$value)

  # Weighted contributions
  etr_total      <- sum(matched$total_rate * matched$value) / total_imports
  etr_additional <- sum(matched$total_additional * matched$value) / total_imports
  etr_base       <- sum(matched$base_rate * matched$value) / total_imports
  etr_232        <- sum(matched$rate_232 * matched$value) / total_imports
  etr_ieepa      <- sum(matched$rate_ieepa_recip * matched$value) / total_imports
  etr_fent       <- sum(matched$rate_ieepa_fent * matched$value) / total_imports
  etr_301        <- sum(matched$rate_301 * matched$value) / total_imports
  etr_s122       <- sum(matched$rate_s122 * matched$value) / total_imports

  tibble(
    scenario = label,
    matched_imports_bn = matched_imports / 1e9,
    etr_total_pct = etr_total * 100,
    etr_additional_pct = etr_additional * 100,
    etr_base_pct = etr_base * 100,
    etr_232_pct = etr_232 * 100,
    etr_ieepa_pct = etr_ieepa * 100,
    etr_fent_pct = etr_fent * 100,
    etr_301_pct = etr_301 * 100,
    etr_s122_pct = etr_s122 * 100
  )
}

pre_etr  <- compute_weighted_etr(pre_rates, imports, total_imports, 'Pre-annex (old regime)')
post_etr <- compute_weighted_etr(post_rates, imports, total_imports, 'Post-annex (new regime)')

# =============================================================================
# 5. Summary
# =============================================================================

comparison <- bind_rows(pre_etr, post_etr)

message('\n', strrep('=', 70))
message('WEIGHTED ETR COMPARISON')
message(strrep('=', 70))
message(sprintf('\n%-30s %12s %12s %12s', '', 'Pre-annex', 'Post-annex', 'Change'))
message(strrep('-', 70))

metrics <- c('etr_total_pct', 'etr_additional_pct', 'etr_232_pct',
             'etr_ieepa_pct', 'etr_fent_pct', 'etr_301_pct', 'etr_s122_pct')
labels <- c('Total rate (base + additional)', 'Additional tariffs',
            '  Section 232', '  IEEPA reciprocal', '  IEEPA fentanyl',
            '  Section 301', '  Section 122')

for (i in seq_along(metrics)) {
  pre_val  <- pre_etr[[metrics[i]]]
  post_val <- post_etr[[metrics[i]]]
  diff_val <- post_val - pre_val
  message(sprintf('%-30s %11.2f%% %11.2f%% %+11.2fpp', labels[i],
                  pre_val, post_val, diff_val))
}

message(sprintf('\n%-30s %11.1fB %11.1fB',
               'Matched imports',
               pre_etr$matched_imports_bn, post_etr$matched_imports_bn))

# =============================================================================
# 6. Decomposition by channel
# =============================================================================

message('\n', strrep('=', 70))
message('TRANSITION DECOMPOSITION BY CHANNEL')
message(strrep('=', 70))

# Join post_rates with imports for detailed breakdown
post_matched <- post_rates %>%
  inner_join(imports, by = c('hts10', 'country')) %>%
  filter(value > 0)

# Channel 1: Annex II removals (rate_232 went to 0)
annex2 <- post_matched %>% filter(s232_annex == '2')
annex2_232_lost <- -sum(annex2$rate_232_pre * annex2$value) / total_imports * 100

# Channel 2: I-B rate reductions (50% → 25%)
annex1b <- post_matched %>% filter(s232_annex == '1b', rate_232_pre > 0)
annex1b_232_change <- sum((annex1b$rate_232 - annex1b$rate_232_pre) * annex1b$value) / total_imports * 100

# Channel 3: Annex III floor
annex3 <- post_matched %>% filter(s232_annex == '3', rate_232_pre > 0)
annex3_232_change <- sum((annex3$rate_232 - annex3$rate_232_pre) * annex3$value) / total_imports * 100

# Channel 4: I-A (should be ~0 for non-UK, positive for UK since old override was also 25%)
annex1a <- post_matched %>% filter(s232_annex == '1a', rate_232_pre > 0)
annex1a_232_change <- sum((annex1a$rate_232 - annex1a$rate_232_pre) * annex1a$value) / total_imports * 100

# Stacking effect: IEEPA fills gap left by 232 removals/reductions
pre_matched <- pre_rates %>%
  inner_join(imports, by = c('hts10', 'country')) %>%
  filter(value > 0)
ieepa_change <- (sum(post_matched$rate_ieepa_recip * post_matched$value) -
                  sum(pre_matched$rate_ieepa_recip * pre_matched$value)) / total_imports * 100

message(sprintf('\n%-40s %+8.2fpp', 'Annex II removals (232 lost)',
               annex2_232_lost))
message(sprintf('%-40s %+8.2fpp', 'Annex I-B rate cuts (50%→25%)',
               annex1b_232_change))
message(sprintf('%-40s %+8.2fpp', 'Annex III floor (50%→floor)',
               annex3_232_change))
message(sprintf('%-40s %+8.2fpp', 'Annex I-A changes (incl. UK)',
               annex1a_232_change))
message(sprintf('%-40s %+8.2fpp', 'IEEPA recip stacking offset',
               ieepa_change))

direct_232 <- annex2_232_lost + annex1b_232_change + annex3_232_change + annex1a_232_change
total_change <- post_etr$etr_additional_pct - pre_etr$etr_additional_pct
message(sprintf('\n%-40s %+8.2fpp', 'Direct 232 change (sum above)',
               direct_232))
message(sprintf('%-40s %+8.2fpp', 'Net additional tariff change',
               total_change))
message(sprintf('%-40s %+8.2fpp', 'Residual (stacking + rounding)',
               total_change - direct_232 - ieepa_change))

# =============================================================================
# 7. Product scope summary
# =============================================================================

message('\n', strrep('=', 70))
message('PRODUCT SCOPE CHANGES')
message(strrep('=', 70))

scope <- post_matched %>%
  mutate(had_232 = rate_232_pre > 0, has_232 = rate_232 > 0) %>%
  group_by(s232_annex) %>%
  summarise(
    n_products = n_distinct(hts10),
    n_countries = n_distinct(country),
    imports_bn = sum(value) / 1e9,
    mean_rate_232_pre = weighted.mean(rate_232_pre, value) * 100,
    mean_rate_232_post = weighted.mean(rate_232, value) * 100,
    .groups = 'drop'
  )

message(sprintf('\n%-10s %8s %8s %10s %12s %12s',
               'Annex', 'Products', 'Ctys', 'Imports$B',
               'Avg 232 pre', 'Avg 232 post'))
message(strrep('-', 70))
for (i in seq_len(nrow(scope))) {
  r <- scope[i, ]
  message(sprintf('%-10s %8d %8d %9.1fB %11.1f%% %11.1f%%',
                  r$s232_annex %||% 'none',
                  r$n_products, r$n_countries, r$imports_bn,
                  r$mean_rate_232_pre, r$mean_rate_232_post))
}

# Unclassified 232 products
unclass_232 <- post_matched %>%
  filter(is.na(s232_annex), rate_232_pre > 0)
if (nrow(unclass_232) > 0) {
  message(sprintf('\n%-10s %8d %8d %9.1fB %11.1f%%',
                  'Unclass.',
                  n_distinct(unclass_232$hts10),
                  n_distinct(unclass_232$country),
                  sum(unclass_232$value) / 1e9,
                  weighted.mean(unclass_232$rate_232_pre, unclass_232$value) * 100))
}

# =============================================================================
# 8. SGEPT comparison
# =============================================================================

message('\n', strrep('=', 70))
message('COMPARISON WITH SGEPT ESTIMATE')
message(strrep('=', 70))
message(sprintf('\n%-30s %12s %12s', '', 'Our estimate', 'SGEPT'))
message(strrep('-', 55))
sgept_pre <- 11.44  # HTS schedule MFN rates
sgept_post <- 10.91
message(sprintf('%-30s %11.2f%% %11.2f%%', 'Pre-annex weighted rate',
               pre_etr$etr_total_pct, sgept_pre))
message(sprintf('%-30s %11.2f%% %11.2f%%', 'Post-annex weighted rate',
               post_etr$etr_total_pct, sgept_post))
message(sprintf('%-30s %+10.2fpp %+10.2fpp', 'Change',
               post_etr$etr_total_pct - pre_etr$etr_total_pct,
               sgept_post - sgept_pre))

message('\nNote: Differences from SGEPT stem from:')
message('  1. Metal content method (BEA I-O shares vs calibrated flat shares)')
message('  2. Import weight vintage (2024 Census vs SGEPT source)')
message('  3. Base rate source (HTS MFN vs potential BoE rates)')
message('  4. IEEPA/S122 stacking methodology differences')
message('  5. Pre-annex snapshot date (rev_4 = Feb 20 vs SGEPT Apr 5)')

message('\nDone.')
