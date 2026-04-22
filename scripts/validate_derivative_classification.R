#!/usr/bin/env Rscript
# =============================================================================
# Validate Derivative Classification Against TPC Rate Patterns
# =============================================================================
#
# Cross-references our derivative/heading/primary 232 product classification
# against TPC's implied classification based on their tariff rates.
#
# Logic: For each product-country pair, TPC's rate minus the IEEPA component
# reveals the implied 232 component. We can infer:
#   - rate_tpc ≈ ieepa_rate → no 232 (TPC doesn't classify as 232)
#   - rate_tpc ≈ ieepa_rate + full_232 → primary/heading (full-value 232)
#   - rate_tpc between those → derivative (partial/metal-scaled 232)
#   - rate_tpc < ieepa_rate → TPC has exemption we don't
#
# Usage:  Rscript scripts/validate_derivative_classification.R
# =============================================================================

library(tidyverse)
library(here)

source(here('src', 'helpers.R'))
source(here('src', '07_validate_tpc.R'))

pp <- load_policy_params()
CTY_CHINA <- pp$CTY_CHINA %||% '5700'

message('=== Derivative Classification Validation ===\n')

# =============================================================================
# 1. Load TPC data and our snapshot for rev_32
# =============================================================================

census_codes <- read_csv(here('resources', 'census_codes.csv'), show_col_types = FALSE)
name_to_code <- create_country_name_map(census_codes)
tpc_path <- here('data', 'tpc', 'tariff_by_flow_day.csv')
tpc_raw <- load_tpc_data(tpc_path, name_to_code)
tpc <- tpc_raw %>%
  filter(date == as.Date('2025-11-17')) %>%
  select(hts10, country = country_code, tpc_rate = tpc_rate_change)

message('TPC data (2025-11-17): ', nrow(tpc), ' rows')

ts <- readRDS(here('data', 'timeseries', 'rate_timeseries.rds'))
snap <- ts %>% filter(revision == 'rev_32')
message('Tracker snapshot (rev_32): ', nrow(snap), ' rows')

# =============================================================================
# 2. Classify our products
# =============================================================================

# Our classification of each product's 232 status
our_class <- snap %>%
  select(hts10, country, rate_232, rate_ieepa_recip, rate_ieepa_fent,
         rate_301, rate_s122, total_additional, metal_share, base_rate,
         any_of(c('deriv_type', 'is_copper_heading', 'steel_share',
                   'aluminum_share', 'copper_share'))) %>%
  mutate(
    ch2 = substr(hts10, 1, 2),
    our_232_class = case_when(
      rate_232 == 0 ~ 'no_232',
      ch2 %in% c('72', '73') ~ 'primary_steel',
      ch2 == '76' ~ 'primary_aluminum',
      ch2 == '74' ~ 'copper_heading',
      metal_share == 1.0 & rate_232 > 0 ~ 'heading_full_value',
      metal_share < 1.0 & rate_232 > 0 ~ 'derivative_scaled',
      rate_232 > 0 ~ '232_other',
      TRUE ~ 'no_232'
    )
  )

message('\nOur 232 classification (rev_32):')
our_class %>%
  filter(rate_232 > 0) %>%
  distinct(hts10, .keep_all = TRUE) %>%
  count(our_232_class) %>%
  mutate(label = paste0('  ', our_232_class, ': ', n, ' products')) %>%
  pull(label) %>% walk(message)

# =============================================================================
# 3. Join with TPC and infer their 232 classification
# =============================================================================

comp <- our_class %>%
  inner_join(tpc, by = c('hts10', 'country')) %>%
  mutate(
    # TPC's implied 232 component = TPC rate - what we think is the non-232 portion
    # For non-China: non-232 = ieepa_recip + fent + s122
    # For China: non-232 = ieepa_recip + fent + 301 + s122
    non_232_rate = if_else(
      country == CTY_CHINA,
      rate_ieepa_recip + rate_ieepa_fent + rate_301 + rate_s122,
      rate_ieepa_recip + rate_ieepa_fent + rate_s122
    ),
    tpc_implied_232 = pmax(0, tpc_rate - non_232_rate),

    # Classify TPC's implied 232 behavior
    # Known steel rate = 0.50, aluminum = 0.50 for rev_32
    tpc_232_class = case_when(
      tpc_implied_232 < 0.005 ~ 'tpc_no_232',
      tpc_implied_232 > 0.45 ~ 'tpc_full_232',          # ~50%
      tpc_implied_232 > 0.20 & tpc_implied_232 < 0.30 ~ 'tpc_heading_25',  # ~25% (auto/MHD)
      tpc_implied_232 > 0.005 & tpc_implied_232 < 0.45 ~ 'tpc_partial_232', # derivative-like
      TRUE ~ 'tpc_other'
    )
  )

message('\nMatched product-country pairs: ', nrow(comp))

# =============================================================================
# 4. Cross-tabulation: our class vs TPC implied class
# =============================================================================

message('\n', strrep('=', 70))
message('CROSS-TABULATION: Our Classification vs TPC Implied')
message(strrep('=', 70))

xtab <- comp %>%
  count(our_232_class, tpc_232_class) %>%
  pivot_wider(names_from = tpc_232_class, values_from = n, values_fill = 0)

# Print
cols <- setdiff(names(xtab), 'our_232_class')
header <- sprintf('\n%-25s', 'Our class \\ TPC')
for (col in cols) header <- paste0(header, sprintf(' %12s', col))
message(header)
message(strrep('-', 25 + 13 * length(cols)))
for (i in seq_len(nrow(xtab))) {
  row <- sprintf('%-25s', xtab$our_232_class[i])
  for (col in cols) row <- paste0(row, sprintf(' %12d', xtab[[col]][i]))
  message(row)
}

# =============================================================================
# 5. Disagreement analysis
# =============================================================================

message('\n', strrep('=', 70))
message('DISAGREEMENT ANALYSIS')
message(strrep('=', 70))

# Products where we say derivative but TPC says no_232
we_deriv_tpc_no <- comp %>%
  filter(our_232_class == 'derivative_scaled', tpc_232_class == 'tpc_no_232')
message(sprintf('\nWe say derivative, TPC says no_232: %d pairs (%d products)',
               nrow(we_deriv_tpc_no), n_distinct(we_deriv_tpc_no$hts10)))
if (n_distinct(we_deriv_tpc_no$hts10) > 0) {
  we_deriv_tpc_no %>%
    distinct(hts10, .keep_all = TRUE) %>%
    mutate(ch4 = substr(hts10, 1, 4)) %>%
    count(ch4, sort = TRUE) %>%
    head(10) %>%
    mutate(label = paste0('  ', ch4, ': ', n, ' products')) %>%
    pull(label) %>% walk(message)
}

# Products where we say no_232 but TPC implies 232
we_no_tpc_232 <- comp %>%
  filter(our_232_class == 'no_232', tpc_232_class %in% c('tpc_full_232', 'tpc_partial_232', 'tpc_heading_25'))
message(sprintf('\nWe say no_232, TPC implies 232: %d pairs (%d products)',
               nrow(we_no_tpc_232), n_distinct(we_no_tpc_232$hts10)))
if (n_distinct(we_no_tpc_232$hts10) > 0) {
  we_no_tpc_232 %>%
    distinct(hts10, .keep_all = TRUE) %>%
    mutate(ch4 = substr(hts10, 1, 4)) %>%
    count(ch4, sort = TRUE) %>%
    head(10) %>%
    mutate(label = paste0('  ', ch4, ': ', n, ' products')) %>%
    pull(label) %>% walk(message)
}

# Products where we say primary (full 50%) but TPC says partial
we_primary_tpc_partial <- comp %>%
  filter(our_232_class %in% c('primary_steel', 'primary_aluminum'),
         tpc_232_class == 'tpc_partial_232')
message(sprintf('\nWe say primary (50%%), TPC says partial: %d pairs (%d products)',
               nrow(we_primary_tpc_partial), n_distinct(we_primary_tpc_partial$hts10)))

# Products where we say heading (full value) but TPC says partial
we_heading_tpc_partial <- comp %>%
  filter(our_232_class == 'heading_full_value',
         tpc_232_class %in% c('tpc_partial_232', 'tpc_no_232'))
message(sprintf('\nWe say heading (full value), TPC says partial/no: %d pairs (%d products)',
               nrow(we_heading_tpc_partial), n_distinct(we_heading_tpc_partial$hts10)))
if (n_distinct(we_heading_tpc_partial$hts10) > 0) {
  we_heading_tpc_partial %>%
    distinct(hts10, .keep_all = TRUE) %>%
    mutate(ch4 = substr(hts10, 1, 4)) %>%
    count(ch4, sort = TRUE) %>%
    head(10) %>%
    mutate(label = paste0('  ', ch4, ': ', n, ' products')) %>%
    pull(label) %>% walk(message)
}

# =============================================================================
# 6. Derivative-specific deep dive
# =============================================================================

message('\n', strrep('=', 70))
message('DERIVATIVE DEEP DIVE')
message(strrep('=', 70))

derivs <- comp %>% filter(our_232_class == 'derivative_scaled')

if (nrow(derivs) > 0) {
  message(sprintf('\nDerivative products: %d pairs, %d unique HTS10',
                 nrow(derivs), n_distinct(derivs$hts10)))

  # How well does our scaled rate match TPC?
  derivs <- derivs %>%
    mutate(
      diff = total_additional - tpc_rate,
      abs_diff = abs(diff),
      match_2pp = abs_diff < 0.02
    )

  message(sprintf('Match rate (within 2pp): %.1f%%', mean(derivs$match_2pp) * 100))
  message(sprintf('Mean absolute diff: %.2fpp', mean(derivs$abs_diff) * 100))

  # By deriv_type
  if ('deriv_type' %in% names(derivs)) {
    derivs %>%
      group_by(deriv_type) %>%
      summarise(
        n = n(),
        pct_match = mean(match_2pp) * 100,
        mean_our_232 = mean(rate_232) * 100,
        mean_tpc_implied_232 = mean(tpc_implied_232) * 100,
        .groups = 'drop'
      ) %>%
      mutate(label = sprintf('  %s: %d pairs, %.1f%% match, our_232=%.1f%%, tpc_impl=%.1f%%',
                             coalesce(deriv_type, 'NA'), n, pct_match,
                             mean_our_232, mean_tpc_implied_232)) %>%
      pull(label) %>% walk(message)
  }

  # Distribution of TPC's implied 232 for our derivatives
  message('\nTPC implied 232 distribution for our derivatives:')
  breaks <- c(0, 0.005, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.40, 0.50, 1.0)
  derivs %>%
    mutate(bucket = cut(tpc_implied_232, breaks, right = FALSE,
                        labels = paste0(breaks[-length(breaks)] * 100, '-',
                                       breaks[-1] * 100, '%'))) %>%
    count(bucket) %>%
    mutate(label = sprintf('  %s: %d', bucket, n)) %>%
    pull(label) %>% walk(message)
}

# =============================================================================
# 7. Heading exclusion check (fix #1 from ed20dbc)
# =============================================================================

message('\n', strrep('=', 70))
message('HEADING EXCLUSION CHECK')
message(strrep('=', 70))

# Products that are heading_full_value — are any suspiciously in derivative chapters?
headings <- comp %>%
  filter(our_232_class == 'heading_full_value') %>%
  distinct(hts10, .keep_all = TRUE)

message(sprintf('\nHeading products (full-value 232, metal_share=1.0): %d', nrow(headings)))

# Check chapters — headings should be in ch84/85/87 (auto/MHD) or ch44 (wood) etc.
heading_ch <- headings %>%
  count(ch2, sort = TRUE)
message('\nBy chapter:')
for (i in seq_len(min(15, nrow(heading_ch)))) {
  r <- heading_ch[i, ]
  message(sprintf('  Ch%s: %d products', r$ch2, r$n))
}

# Any heading products in ch73 (steel articles) that look like they should be derivatives?
sus_headings <- headings %>%
  filter(!ch2 %in% c('72', '73', '76', '74', '84', '85', '87', '44', '94'))
if (nrow(sus_headings) > 0) {
  message(sprintf('\nSuspicious heading products (unexpected chapters): %d', nrow(sus_headings)))
  sus_headings %>%
    head(20) %>%
    mutate(label = sprintf('  %s (ch%s) rate_232=%.2f metal=%.2f tpc_impl_232=%.2f',
                           hts10, ch2, rate_232, metal_share, tpc_implied_232)) %>%
    pull(label) %>% walk(message)
} else {
  message('\nNo suspicious heading products found — heading exclusion looks clean.')
}

message('\nDone.')
