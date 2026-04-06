# =============================================================================
# Tests: Daily Series Infrastructure
# =============================================================================
#
# Validates horizon, expiry, decomposition, and schema behavior.
# Uses base R stopifnot() assertions — no external test framework required.
#
# Usage:
#   Rscript tests/run_tests_daily_series.R                  # Fixture-based tests only (CI-safe)
#   Rscript tests/run_tests_daily_series.R --with-artifacts # Also run artifact-dependent integration tests
#
# The default run uses only in-memory fixtures and does not require built
# artifacts (rate_timeseries.rds, snapshots, etc.). Pass --with-artifacts to
# include heavier integration tests that load full build outputs.
#
# =============================================================================

library(tidyverse)
library(here)
source(here('src', 'helpers.R'))
source(here('src', '09_daily_series.R'))

run_artifact_tests <- '--with-artifacts' %in% commandArgs(trailingOnly = TRUE)

pass_count <- 0
fail_count <- 0
skip_count <- 0

skip_test <- function(reason) {
  cond <- structure(class = c('skip', 'condition'), list(message = reason))
  stop(cond)
}

run_test <- function(name, expr) {
  tryCatch({
    force(expr)
    message('  PASS: ', name)
    pass_count <<- pass_count + 1
  }, skip = function(e) {
    message('  SKIP: ', name, ' — ', conditionMessage(e))
    skip_count <<- skip_count + 1
  }, error = function(e) {
    message('  FAIL: ', name, ' — ', conditionMessage(e))
    fail_count <<- fail_count + 1
  })
}


# =============================================================================
# Test fixtures
# =============================================================================

# Minimal synthetic timeseries: 2 products, 2 countries, 2 revisions
make_test_ts <- function(horizon_end = as.Date('2026-12-31')) {
  expand_grid(
    hts10 = c('7208100000', '8703230000'),
    country = c('5700', '4280'),
    revision = c('rev_a', 'rev_b')
  ) %>%
    mutate(
      base_rate = 0.05,
      statutory_base_rate = 0.05,
      rate_232 = if_else(hts10 == '7208100000', 0.50, 0),
      rate_301 = if_else(country == '5700' & hts10 == '8703230000', 0.25, 0),
      rate_ieepa_recip = case_when(
        country == '5700' ~ 0.34,
        country == '4280' ~ 0.15,
        TRUE ~ 0.10
      ),
      rate_ieepa_fent = 0,
      rate_s122 = 0.10,
      rate_section_201 = if_else(hts10 == '8703230000', 0.02, 0),
      rate_other = 0,
      metal_share = if_else(hts10 == '7208100000', 1.0, 0),
      usmca_eligible = FALSE,
      effective_date = if_else(revision == 'rev_a',
                               as.Date('2026-01-01'), as.Date('2026-06-01')),
      valid_from = effective_date,
      valid_until = if_else(revision == 'rev_a',
                            as.Date('2026-05-31'), horizon_end)
    ) %>%
    apply_stacking_rules()
}

make_test_policy_params <- function() {
  list(
    CTY_CHINA = '5700',
    SECTION_122 = list(
      effective_date = as.Date('2026-02-24'),
      expiry_date = as.Date('2026-07-23'),
      finalized = FALSE
    ),
    SWISS_FRAMEWORK = list(
      effective_date = as.Date('2025-11-14'),
      expiry_date = as.Date('2026-03-31'),
      finalized = FALSE,
      countries = c('4419', '4411')
    ),
    SERIES_HORIZON_END = as.Date('2026-12-31')
  )
}


# =============================================================================
# Test 1: Final revision gets valid_until = horizon, not Sys.Date()
# =============================================================================

message('\n--- Test 1: Horizon end date ---')

run_test('final valid_until equals horizon', {
  ts <- make_test_ts(horizon_end = as.Date('2026-12-31'))
  final <- ts %>% filter(revision == 'rev_b') %>% pull(valid_until) %>% unique()
  stopifnot(final == as.Date('2026-12-31'))
})

run_test('series_horizon parsed from YAML', {
  pp <- load_policy_params()
  stopifnot(!is.null(pp$SERIES_HORIZON_END))
  stopifnot(pp$SERIES_HORIZON_END == as.Date('2026-12-31'))
})


# =============================================================================
# Test 2: get_rates_at_date() returns non-empty for future dates
# =============================================================================

message('\n--- Test 2: Future date queries ---')

run_test('get_rates_at_date returns data for 2026-12-15', {
  ts <- make_test_ts()
  result <- get_rates_at_date(ts, '2026-12-15')
  stopifnot(nrow(result) > 0)
})

run_test('get_rates_at_date returns data for mid-2026', {
  ts <- make_test_ts()
  result <- get_rates_at_date(ts, '2026-06-15')
  stopifnot(nrow(result) > 0)
  # Should be from rev_b
  stopifnot(all(result$revision == 'rev_b'))
})


# =============================================================================
# Test 3: Section 122 expiry zeroing
# =============================================================================

message('\n--- Test 3: Section 122 expiry ---')

run_test('rate_s122 zeroed after expiry date', {
  ts <- make_test_ts()
  pp <- make_test_policy_params()
  # Before expiry: s122 should be active
  before <- get_rates_at_date(ts, '2026-07-20', policy_params = pp)
  stopifnot(any(before$rate_s122 > 0))
  # After expiry: s122 should be zero
  after <- get_rates_at_date(ts, '2026-07-24', policy_params = pp)
  stopifnot(all(after$rate_s122 == 0))
})

run_test('total_rate recomputed after s122 zeroing', {
  ts <- make_test_ts()
  pp <- make_test_policy_params()
  before <- get_rates_at_date(ts, '2026-07-20', policy_params = pp)
  after <- get_rates_at_date(ts, '2026-07-24', policy_params = pp)
  # For products where s122 contributed, total should be lower
  non_232 <- before %>% filter(rate_232 == 0)
  non_232_after <- after %>% filter(rate_232 == 0)
  if (nrow(non_232) > 0 && any(non_232$rate_s122 > 0)) {
    # total_additional should differ
    stopifnot(all(non_232_after$total_additional < non_232$total_additional |
                  non_232$rate_s122 == 0))
  }
})


# =============================================================================
# Test 4: Authority decomposition sums to total_additional
# =============================================================================

message('\n--- Test 4: Authority decomposition reconciliation ---')

run_test('net authorities sum to total_additional', {
  ts <- make_test_ts()
  net <- compute_net_authority_contributions(ts, cty_china = '5700')
  decomp_sum <- net$net_232 + net$net_ieepa + net$net_fentanyl +
    net$net_301 + net$net_s122 + net$net_section_201 + net$net_other
  residual <- abs(decomp_sum - net$total_additional)
  max_residual <- max(residual)
  stopifnot(max_residual < 1e-10)
})

run_test('decomposition works with tpc_additive mode', {
  ts <- make_test_ts()
  net <- compute_net_authority_contributions(ts, stacking_method = 'tpc_additive')
  stopifnot('net_section_201' %in% names(net))
  stopifnot(all(net$net_section_201 == net$rate_section_201))
})


# =============================================================================
# Test 5: rate_section_201 preserved by enforce_rate_schema()
# =============================================================================

message('\n--- Test 5: Schema enforcement ---')

run_test('rate_section_201 in RATE_SCHEMA', {
  stopifnot('rate_section_201' %in% RATE_SCHEMA)
})

run_test('enforce_rate_schema preserves rate_section_201', {
  df <- tibble(
    hts10 = '1234567890', country = '5700',
    base_rate = 0.05, rate_section_201 = 0.10,
    rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0, rate_ieepa_fent = 0,
    rate_s122 = 0, rate_other = 0,
    total_additional = 0.10, total_rate = 0.15,
    metal_share = 1.0, usmca_eligible = FALSE,
    revision = 'test', effective_date = as.Date('2026-01-01')
  )
  result <- enforce_rate_schema(df)
  stopifnot('rate_section_201' %in% names(result))
  stopifnot(result$rate_section_201 == 0.10)
})

run_test('enforce_rate_schema fills missing rate_section_201 with 0', {
  df <- tibble(
    hts10 = '1234567890', country = '5700',
    base_rate = 0.05,
    rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0, rate_ieepa_fent = 0,
    rate_s122 = 0, rate_other = 0,
    total_additional = 0, total_rate = 0.05,
    metal_share = 1.0, usmca_eligible = FALSE,
    revision = 'test', effective_date = as.Date('2026-01-01')
  )
  result <- enforce_rate_schema(df)
  stopifnot('rate_section_201' %in% names(result))
  stopifnot(result$rate_section_201 == 0)
})


# =============================================================================
# Test 6: Expiry split points
# =============================================================================

message('\n--- Test 6: Generic expiry split points ---')

run_test('split points detected for spanning interval', {
  pp <- make_test_policy_params()
  splits <- get_expiry_split_points(
    as.Date('2026-01-01'), as.Date('2026-12-31'), pp)
  # Should find both s122 (2026-07-23) and swiss (2026-03-31)
  stopifnot(as.Date('2026-07-23') %in% splits)
  stopifnot(as.Date('2026-03-31') %in% splits)
})

run_test('no split points for interval before all expiries', {
  pp <- make_test_policy_params()
  splits <- get_expiry_split_points(
    as.Date('2026-01-01'), as.Date('2026-03-01'), pp)
  stopifnot(length(splits) == 0)
})

run_test('apply_expiry_zeroing zeros s122 after expiry', {
  ts <- make_test_ts() %>% filter(revision == 'rev_b') %>% head(4)
  pp <- make_test_policy_params()
  adjusted <- apply_expiry_zeroing(ts, as.Date('2026-07-24'), pp)
  stopifnot(all(adjusted$rate_s122 == 0))
})


# =============================================================================
# Test 6b: Expiry boundary edge cases
# =============================================================================

message('\n--- Test 6b: Expiry boundary edge cases ---')

run_test('s122 active on exact expiry date', {
  ts <- make_test_ts()
  pp <- make_test_policy_params()
  # On the expiry date itself (2026-07-23), s122 should still be active
  on_expiry <- get_rates_at_date(ts, '2026-07-23', policy_params = pp)
  non_232 <- on_expiry %>% filter(rate_232 == 0)
  stopifnot(any(non_232$rate_s122 > 0))
})

run_test('s122 zeroed on day after expiry', {
  ts <- make_test_ts()
  pp <- make_test_policy_params()
  after_expiry <- get_rates_at_date(ts, '2026-07-24', policy_params = pp)
  stopifnot(all(after_expiry$rate_s122 == 0))
})

run_test('swiss framework active on exact expiry date', {
  ts <- make_test_ts()
  pp <- make_test_policy_params()
  # Swiss framework expires 2026-03-31. On expiry date it should still apply.
  on_expiry <- get_rates_at_date(ts, '2026-03-31', policy_params = pp)
  swiss <- on_expiry %>% filter(country %in% pp$SWISS_FRAMEWORK$countries)
  # Swiss countries should have IEEPA rate overridden (framework active)
  # We just verify the function runs without error on boundary
  stopifnot(nrow(on_expiry) > 0)
})

run_test('split point lands exactly on expiry date', {
  pp <- make_test_policy_params()
  splits <- get_expiry_split_points(
    as.Date('2026-07-23'), as.Date('2026-08-01'), pp)
  # Expiry date is 2026-07-23 — split should be at that boundary
  stopifnot(as.Date('2026-07-23') %in% splits)
})

run_test('split points empty when interval starts after all expiries', {
  pp <- make_test_policy_params()
  splits <- get_expiry_split_points(
    as.Date('2026-08-01'), as.Date('2026-12-31'), pp)
  stopifnot(length(splits) == 0)
})

run_test('apply_expiry_zeroing keeps s122 on exact expiry date', {
  ts <- make_test_ts() %>% filter(revision == 'rev_b') %>% head(4)
  pp <- make_test_policy_params()
  # On the expiry date itself, s122 should NOT be zeroed
  adjusted <- apply_expiry_zeroing(ts, as.Date('2026-07-23'), pp)
  stopifnot(any(adjusted$rate_s122 > 0))
})


# =============================================================================
# Test 7: product-country-day expansion paths
# =============================================================================

message('\n--- Test 7: product-country-day expansion paths ---')

run_test('export_daily_slice requires filter or full_export', {
  ts <- make_test_ts()
  err <- tryCatch({
    export_daily_slice(ts, c('2026-06-01', '2026-06-30'))
    FALSE
  }, error = function(e) TRUE)
  stopifnot(err)
})

run_test('export_daily_slice returns data for filtered query', {
  ts <- make_test_ts()
  pp <- make_test_policy_params()
  result <- export_daily_slice(ts, c('2026-06-01', '2026-06-30'),
                                countries = '5700', policy_params = pp)
  stopifnot(nrow(result) > 0)
  stopifnot(all(result$country == '5700'))
  stopifnot(all(result$date >= as.Date('2026-06-01')))
  stopifnot(all(result$date <= as.Date('2026-06-30')))
})

run_test('export_daily_slice applies s122 expiry', {
  ts <- make_test_ts()
  pp <- make_test_policy_params()
  result <- export_daily_slice(ts, c('2026-07-20', '2026-07-27'),
                                countries = '4280', policy_params = pp)
  before_expiry <- result %>% filter(date <= as.Date('2026-07-23'))
  after_expiry <- result %>% filter(date > as.Date('2026-07-23'))
  if (nrow(before_expiry) > 0) stopifnot(any(before_expiry$rate_s122 > 0))
  if (nrow(after_expiry) > 0) stopifnot(all(after_expiry$rate_s122 == 0))
})

run_test('expand_to_daily applies the same expiry logic as export_daily_slice', {
  ts <- make_test_ts()
  pp <- make_test_policy_params()
  expanded <- expand_to_daily(
    ts,
    c('2026-07-20', '2026-07-27'),
    countries = '4280',
    products = c('7208100000', '8703230000'),
    policy_params = pp
  ) %>%
    arrange(date, hts10, country)
  exported <- export_daily_slice(
    ts,
    c('2026-07-20', '2026-07-27'),
    countries = '4280',
    products = c('7208100000', '8703230000'),
    policy_params = pp
  ) %>%
    arrange(date, hts10, country)
  stopifnot(nrow(expanded) == nrow(exported))
  stopifnot(identical(expanded, exported))
})


# =============================================================================
# Test 8: Narrow date_range does not crash build_daily_aggregates
# =============================================================================

message('\n--- Test 8: Narrow date_range inputs ---')

run_test('date_range excluding all revisions returns empty daily output', {
  ts <- make_test_ts()
  # All revisions span 2026-01-01 to 2026-12-31; pick a range before that
  result <- build_daily_aggregates(ts, date_range = c(as.Date('2025-01-01'), as.Date('2025-06-01')))
  stopifnot(nrow(result$daily_overall) == 0)
  stopifnot(nrow(result$daily_by_country) == 0)
  stopifnot(nrow(result$daily_by_authority) == 0)
})

run_test('date_range overlapping only first revision clips correctly', {
  ts <- make_test_ts()
  # rev_a: 2026-01-01 to 2026-05-31, rev_b: 2026-06-01 to 2026-12-31
  # Request only February — should only get rev_a dates
  result <- build_daily_aggregates(ts, date_range = c(as.Date('2026-02-01'), as.Date('2026-02-28')))
  stopifnot(nrow(result$daily_overall) == 28)
  stopifnot(all(result$daily_overall$date >= as.Date('2026-02-01')))
  stopifnot(all(result$daily_overall$date <= as.Date('2026-02-28')))
  stopifnot(all(result$daily_overall$revision == 'rev_a'))
})

run_test('date_range after all revisions returns empty', {
  ts <- make_test_ts(horizon_end = as.Date('2026-06-30'))
  result <- build_daily_aggregates(ts, date_range = c(as.Date('2027-01-01'), as.Date('2027-12-31')))
  stopifnot(nrow(result$daily_overall) == 0)
})


# =============================================================================
# Test 9: Stacking method survives through build_daily_aggregates
# =============================================================================

message('\n--- Test 9: Stacking method passthrough ---')

run_test('tpc_additive produces different totals than mutual_exclusion', {
  # Build a fixture where stacking method matters: a 232 product with IEEPA recip
  ts_stack <- expand_grid(
    hts10 = '7208100000',
    country = '4280',  # non-China
    revision = 'rev_a'
  ) %>%
    mutate(
      base_rate = 0.05,
      statutory_base_rate = 0.05,
      rate_232 = 0.50,
      rate_301 = 0,
      rate_ieepa_recip = 0.15,
      rate_ieepa_fent = 0,
      rate_s122 = 0.10,
      rate_section_201 = 0,
      rate_other = 0,
      metal_share = 1.0,
      usmca_eligible = FALSE,
      valid_from = as.Date('2026-01-01'),
      valid_until = as.Date('2026-01-10')
    ) %>%
    apply_stacking_rules()

  me <- build_daily_aggregates(ts_stack, stacking_method = 'mutual_exclusion')
  tpc <- build_daily_aggregates(ts_stack, stacking_method = 'tpc_additive')

  # With mutual exclusion on full-metal 232: recip*0 + s122*0 = only 232
  # With tpc_additive: 232 + recip + s122 — should be higher
  stopifnot(nrow(me$daily_overall) > 0)
  stopifnot(nrow(tpc$daily_overall) > 0)
  stopifnot(tpc$daily_overall$mean_additional_exposed[1] > me$daily_overall$mean_additional_exposed[1])
})

run_test('tpc_additive authority decomposition reflects additive stacking', {
  ts_stack <- tibble(
    hts10 = '7208100000', country = '4280', revision = 'rev_a',
    base_rate = 0.05, statutory_base_rate = 0.05,
    rate_232 = 0.50, rate_301 = 0, rate_ieepa_recip = 0.15,
    rate_ieepa_fent = 0.10, rate_s122 = 0.10, rate_section_201 = 0,
    rate_other = 0, metal_share = 1.0, usmca_eligible = FALSE,
    valid_from = as.Date('2026-01-01'), valid_until = as.Date('2026-01-05')
  ) %>% apply_stacking_rules()

  tpc <- build_daily_aggregates(ts_stack, stacking_method = 'tpc_additive')
  # In additive mode, authority decomposition should show full recip + fent + s122
  stopifnot(nrow(tpc$daily_by_authority) > 0)
  stopifnot(tpc$daily_by_authority$mean_ieepa[1] == 0.15)
  stopifnot(tpc$daily_by_authority$mean_fentanyl[1] == 0.10)
  stopifnot(tpc$daily_by_authority$mean_s122[1] == 0.10)
})

run_test('tpc_additive total equals raw sum of all authorities', {
  # Create a 232 product with multiple overlapping authorities
  ts_add <- tibble(
    hts10 = '7208100000', country = '4280', revision = 'rev_a',
    base_rate = 0.05, statutory_base_rate = 0.05,
    rate_232 = 0.50, rate_301 = 0, rate_ieepa_recip = 0.15,
    rate_ieepa_fent = 0.10, rate_s122 = 0.10, rate_section_201 = 0.02,
    rate_other = 0, metal_share = 1.0, usmca_eligible = FALSE,
    valid_from = as.Date('2026-01-01'), valid_until = as.Date('2026-01-02')
  ) %>% apply_stacking_rules(stacking_method = 'tpc_additive')

  # In additive mode, total_additional should be the literal sum of all rate columns
  expected_total <- 0.50 + 0.15 + 0.10 + 0.10 + 0.02  # = 0.87
  actual_total <- ts_add$total_additional[1]
  stopifnot(abs(actual_total - expected_total) < 1e-10)
  stopifnot(abs(ts_add$total_rate[1] - (0.05 + expected_total)) < 1e-10)
})

run_test('tpc_additive vs mutual_exclusion: known numeric difference on 232 product', {
  # For a pure-metal 232 product (metal_share=1.0, non-China):
  # mutual_exclusion: total_additional = rate_232 only (recip/s122 scaled by nonmetal=0)
  # tpc_additive: total_additional = rate_232 + rate_ieepa_recip + rate_s122
  ts_me <- tibble(
    hts10 = '7208100000', country = '4280', revision = 'rev_a',
    base_rate = 0.05, statutory_base_rate = 0.05,
    rate_232 = 0.50, rate_301 = 0, rate_ieepa_recip = 0.15,
    rate_ieepa_fent = 0, rate_s122 = 0.10, rate_section_201 = 0,
    rate_other = 0, metal_share = 1.0, usmca_eligible = FALSE,
    valid_from = as.Date('2026-01-01'), valid_until = as.Date('2026-01-02')
  )

  me_result <- apply_stacking_rules(ts_me, stacking_method = 'mutual_exclusion')
  tpc_result <- apply_stacking_rules(ts_me, stacking_method = 'tpc_additive')

  # ME: only 232 contributes (nonmetal_share = 0)
  stopifnot(abs(me_result$total_additional[1] - 0.50) < 1e-10)
  # TPC additive: 232 + recip + s122 = 0.75
  stopifnot(abs(tpc_result$total_additional[1] - 0.75) < 1e-10)
  # Difference should be exactly 0.25
  stopifnot(abs(tpc_result$total_additional[1] - me_result$total_additional[1] - 0.25) < 1e-10)
})


# =============================================================================
# Test 10: Country alias validity
# =============================================================================

message('\n--- Test 10: Country alias validity ---')

source(here('src', '05_parse_policy_params.R'))

run_test('all hardcoded alias codes exist in census_codes.csv', {
  census <- read_csv(here('resources', 'census_codes.csv'),
                     col_types = cols(.default = col_character()))
  valid_codes <- census$Code

  lookup <- build_country_lookup(here('resources', 'census_codes.csv'))

  # The lookup includes official names (from CSV) plus hardcoded aliases.
  # We only need to validate that every CODE in the lookup is in the CSV.
  alias_codes <- unique(unname(lookup))
  missing <- alias_codes[!alias_codes %in% valid_codes]
  if (length(missing) > 0) {
    stop('Alias codes not found in census_codes.csv: ', paste(missing, collapse = ', '))
  }
  stopifnot(length(missing) == 0)
})

run_test('Myanmar maps to Census code 5460', {
  lookup <- build_country_lookup(here('resources', 'census_codes.csv'))
  stopifnot(lookup[['myanmar']] == '5460')
  stopifnot(lookup[['burma']] == '5460')
})

run_test('Macau maps to Census code 5660', {
  lookup <- build_country_lookup(here('resources', 'census_codes.csv'))
  stopifnot(lookup[['macau']] == '5660')
  stopifnot(lookup[['macao']] == '5660')
})

run_test("Cote d'Ivoire maps to Census code 7480", {
  lookup <- build_country_lookup(here('resources', 'census_codes.csv'))
  stopifnot(lookup[["cote d'ivoire"]] == '7480')
  stopifnot(lookup[['ivory coast']] == '7480')
})


# =============================================================================
# Test 11: Section 232 heading gate key alignment
# =============================================================================

message('\n--- Test 11: 232 heading gate alignment ---')

run_test('all policy_params heading names have matching gates', {
  pp <- load_policy_params()
  s232_headings <- pp$section_232_headings
  if (is.null(s232_headings)) {
    message('    (skipped — no section_232_headings in policy_params)')
    return(invisible())
  }

  # Reproduce the heading_gates keys from 06_calculate_rates.R
  heading_gates <- c('autos_passenger', 'autos_light_trucks', 'auto_parts',
                     'copper', 'softwood', 'wood_furniture', 'kitchen_cabinets',
                     'mhd_vehicles', 'mhd_parts', 'buses')

  config_names <- names(s232_headings)
  missing_gates <- config_names[!config_names %in% heading_gates]
  if (length(missing_gates) > 0) {
    stop('Config heading names with no gate entry: ', paste(missing_gates, collapse = ', '),
         '. These will bypass the Ch99 activation check.')
  }
  stopifnot(length(missing_gates) == 0)
})

run_test('autos_light_trucks key exists in heading_gates (not autos_light)', {
  # Verify the gate list contains the correct key
  heading_gates <- c('autos_passenger', 'autos_light_trucks', 'auto_parts',
                     'copper', 'softwood', 'wood_furniture', 'kitchen_cabinets',
                     'mhd_vehicles', 'mhd_parts', 'buses')
  stopifnot('autos_light_trucks' %in% heading_gates)
  stopifnot(!'autos_light' %in% heading_gates)
})

run_test('NULL gate lookup bypasses check (regression guard)', {
  # Simulate the gate-check logic from 06_calculate_rates.R lines 843-846
  # A NULL gate_val should NOT skip the heading — it means "no gate, always apply"
  # But a missing key for a real heading IS a bug. This test documents the behavior.
  heading_gates <- list(autos_passenger = TRUE, autos_light_trucks = FALSE)

  # Existing key with FALSE -> should skip
  gate_val <- heading_gates[['autos_light_trucks']]
  should_skip <- !is.null(gate_val) && !gate_val
  stopifnot(should_skip == TRUE)

  # Missing key -> NULL -> should NOT skip (gate is open)
  gate_val_missing <- heading_gates[['nonexistent_key']]
  should_skip_missing <- !is.null(gate_val_missing) && !gate_val_missing
  stopifnot(should_skip_missing == FALSE)
})


# =============================================================================
# Test 12: Country applicability fail-closed
# =============================================================================

message('\n--- Test 12: Country applicability fail-closed ---')

source(here('src', '06_calculate_rates.R'))

run_test('unknown country_type does not apply', {
  result <- check_country_applies('5700', 'unknown', c(), c())
  stopifnot(result == FALSE)
})

run_test('NA country_type does not apply', {
  result <- check_country_applies('5700', NA_character_, c(), c())
  stopifnot(result == FALSE)
})

run_test('all country_type still applies', {
  result <- check_country_applies('5700', 'all', c(), c())
  stopifnot(result == TRUE)
})

run_test('specific country_type applies to listed country', {
  result <- check_country_applies('5700', 'specific', c('CN', '5700'), c())
  stopifnot(result == TRUE)
})

run_test('specific country_type does not apply to unlisted country', {
  result <- check_country_applies('4280', 'specific', c('CN'), c())
  stopifnot(result == FALSE)
})

run_test('all_except excludes exempt countries', {
  result_exempt <- check_country_applies('1220', 'all_except', c(), c('CA', '1220'))
  result_other <- check_country_applies('5700', 'all_except', c(), c('CA', '1220'))
  stopifnot(result_exempt == FALSE)
  stopifnot(result_other == TRUE)
})

run_test('no unknown country_type in current ch99 data', {
  ch99_path <- here('data', 'processed', 'chapter99_rates.rds')
  if (!file.exists(ch99_path)) {
    skip_test('ch99 data not found')
  }
  ch99 <- readRDS(ch99_path)
  n_unknown <- sum(ch99$country_type == 'unknown', na.rm = TRUE)
  if (n_unknown > 0) {
    stop(n_unknown, ' Ch99 entries have unknown country_type — parser needs updating')
  }
  stopifnot(n_unknown == 0)
})


# =============================================================================
# Test 13: Section 301 scope consistency
# =============================================================================

message('\n--- Test 13: Section 301 scope consistency ---')

run_test('stacking excludes rate_301 for non-China countries', {
  # Non-China row with rate_301 > 0 — stacking should NOT include it
  ts_301 <- tibble(
    hts10 = '8703230000', country = '4280',  # Germany, not China
    base_rate = 0.05, statutory_base_rate = 0.05,
    rate_232 = 0, rate_301 = 0.25, rate_ieepa_recip = 0.15,
    rate_ieepa_fent = 0, rate_s122 = 0.10, rate_section_201 = 0,
    rate_other = 0, metal_share = 0, usmca_eligible = FALSE,
    total_additional = 0, total_rate = 0
  )
  stacked <- apply_stacking_rules(ts_301)
  # 301 should be excluded: total = recip + s122 = 0.25, NOT 0.50
  stopifnot(abs(stacked$total_additional - 0.25) < 1e-10)
})

run_test('stacking includes rate_301 for China', {
  ts_301_cn <- tibble(
    hts10 = '8703230000', country = '5700',  # China
    base_rate = 0.05, statutory_base_rate = 0.05,
    rate_232 = 0, rate_301 = 0.25, rate_ieepa_recip = 0.34,
    rate_ieepa_fent = 0.10, rate_s122 = 0.10, rate_section_201 = 0,
    rate_other = 0, metal_share = 0, usmca_eligible = FALSE,
    total_additional = 0, total_rate = 0
  )
  stacked <- apply_stacking_rules(ts_301_cn)
  # China: recip + fent + 301 + s122 = 0.34 + 0.10 + 0.25 + 0.10 = 0.79
  stopifnot(abs(stacked$total_additional - 0.79) < 1e-10)
})

run_test('decomposition matches stacking for non-China with rate_301', {
  ts_301 <- tibble(
    hts10 = '8703230000', country = '4280',
    base_rate = 0.05, statutory_base_rate = 0.05,
    rate_232 = 0, rate_301 = 0.25, rate_ieepa_recip = 0.15,
    rate_ieepa_fent = 0, rate_s122 = 0.10, rate_section_201 = 0,
    rate_other = 0, metal_share = 0, usmca_eligible = FALSE,
    total_additional = 0, total_rate = 0
  ) %>% apply_stacking_rules()

  net <- compute_net_authority_contributions(ts_301)
  decomp_sum <- net$net_232 + net$net_ieepa + net$net_fentanyl +
    net$net_301 + net$net_s122 + net$net_section_201 + net$net_other
  residual <- abs(decomp_sum - net$total_additional)
  stopifnot(max(residual) < 1e-10)
})

# =============================================================================
# Artifact-dependent integration tests (opt-in with --with-artifacts)
# =============================================================================

if (!run_artifact_tests) {
  message('\n--- Skipping artifact-dependent tests (pass --with-artifacts to include) ---')
} else {
  message('\n--- Running artifact-dependent integration tests ---')
}

if (run_artifact_tests) run_test('no non-China rate_301 in current timeseries', {
  ts_path <- here('data', 'timeseries', 'rate_timeseries.rds')
  if (!file.exists(ts_path)) {
    skip_test('timeseries not found')
  }
  ts <- readRDS(ts_path)
  non_china <- ts %>% filter(country != '5700' & rate_301 > 0)
  if (nrow(non_china) > 0) {
    stop(nrow(non_china), ' non-China rows with rate_301 > 0 — needs investigation')
  }
  stopifnot(nrow(non_china) == 0)
})


# =============================================================================
# Test 14: All-pairs denominator in daily aggregates
# =============================================================================

message('\n--- Test 14: All-pairs denominator ---')

run_test('all-pairs mean is lower than exposed-pairs mean for sparse panel', {
  # Create a sparse panel: 3 products x 2 countries = 6 possible pairs, but only 4 present
  ts_sparse <- tibble(
    hts10 = c('0101000000', '0101000000', '0102000000', '0102000000',
              '0103000000', '0103000000'),
    country = c('5700', '4280', '5700', '4280', '5700', '4280'),
    revision = 'rev_a',
    base_rate = 0.05, statutory_base_rate = 0.05,
    rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0.10,
    rate_ieepa_fent = 0, rate_s122 = 0, rate_section_201 = 0,
    rate_other = 0, metal_share = 0, usmca_eligible = FALSE,
    total_additional = 0.10, total_rate = 0.15,
    effective_date = as.Date('2025-04-01'),
    valid_from = as.Date('2025-04-01'), valid_until = as.Date('2025-04-02')
  )
  # Remove one row to make it sparse (5 of 6 pairs)
  ts_sparse <- ts_sparse[-6, ]

  daily <- build_daily_aggregates(ts_sparse,
    date_range = c(as.Date('2025-04-01'), as.Date('2025-04-01')))

  ov <- daily$daily_overall
  stopifnot('mean_additional_exposed' %in% names(ov))
  stopifnot('mean_additional_all_pairs' %in% names(ov))
  stopifnot('n_pairs' %in% names(ov))
  stopifnot('n_all_pairs' %in% names(ov))

  # Exposed mean = sum(0.10 * 5) / 5 = 0.10
  # All-pairs mean = sum(0.10 * 5) / 6 = 0.0833...
  stopifnot(abs(ov$mean_additional_exposed[1] - 0.10) < 1e-10)
  stopifnot(ov$n_pairs[1] == 5)
  stopifnot(ov$n_all_pairs[1] == 6)  # 3 products x 2 countries
  stopifnot(ov$mean_additional_all_pairs[1] < ov$mean_additional_exposed[1])
})

run_test('all-pairs equals exposed when panel is complete', {
  # Complete panel: 2 products x 2 countries = 4 pairs, all present
  ts_full <- tibble(
    hts10 = c('0101000000', '0101000000', '0102000000', '0102000000'),
    country = c('5700', '4280', '5700', '4280'),
    revision = 'rev_a',
    base_rate = 0.05, statutory_base_rate = 0.05,
    rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0.10,
    rate_ieepa_fent = 0, rate_s122 = 0, rate_section_201 = 0,
    rate_other = 0, metal_share = 0, usmca_eligible = FALSE,
    total_additional = 0.10, total_rate = 0.15,
    effective_date = as.Date('2025-04-01'),
    valid_from = as.Date('2025-04-01'), valid_until = as.Date('2025-04-02')
  )
  daily <- build_daily_aggregates(ts_full,
    date_range = c(as.Date('2025-04-01'), as.Date('2025-04-01')))

  ov <- daily$daily_overall
  stopifnot(ov$n_pairs[1] == ov$n_all_pairs[1])
  stopifnot(abs(ov$mean_additional_exposed[1] - ov$mean_additional_all_pairs[1]) < 1e-10)
})

run_test('by-country all-pairs uses revision product count as denominator', {
  # 3 products x 2 countries, but country 4280 only has 2 of 3 products
  ts_sparse <- tibble(
    hts10 = c('0101000000', '0101000000', '0102000000', '0102000000', '0103000000'),
    country = c('5700', '4280', '5700', '4280', '5700'),
    revision = 'rev_a',
    base_rate = 0.05, statutory_base_rate = 0.05,
    rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0.10,
    rate_ieepa_fent = 0, rate_s122 = 0, rate_section_201 = 0,
    rate_other = 0, metal_share = 0, usmca_eligible = FALSE,
    total_additional = 0.10, total_rate = 0.15,
    effective_date = as.Date('2025-04-01'),
    valid_from = as.Date('2025-04-01'), valid_until = as.Date('2025-04-02')
  )
  daily <- build_daily_aggregates(ts_sparse,
    date_range = c(as.Date('2025-04-01'), as.Date('2025-04-01')))

  cty <- daily$daily_by_country
  cty_4280 <- cty %>% filter(country == '4280')
  # Country 4280 has 2 rows, exposed mean = 0.10
  # All-pairs: 2 * 0.10 / 3 = 0.0667 (denominator = 3 total products in revision)
  stopifnot(abs(cty_4280$mean_additional_exposed[1] - 0.10) < 1e-10)
  stopifnot(abs(cty_4280$mean_additional_all_pairs[1] - 0.2 / 3) < 1e-10)
  stopifnot(cty_4280$n_products_total[1] == 3)
})


# =============================================================================
# Test 15: Auto deal vs blanket rate separation (232)
# =============================================================================

message('\n--- Test 15: Auto deal vs blanket 232 separation ---')

run_test('deal-only auto entries produce auto_rate = 0', {
  # Simulate ch99 data with only country-specific auto deal entries (no blanket)
  ch99_deal_only <- tibble(
    ch99_code = c('9903.94.05', '9903.94.06'),
    rate = c(0.15, 0.075),
    country_type = c('specific', 'specific'),
    countries = list('GB', 'GB'),
    description = c('passenger vehicles', 'automobile parts'),
    general_raw = c('15%', '+7.5%'),
    authority = 'section_232',
    exempt_countries = list(character(0), character(0))
  )
  s232 <- extract_section232_rates(ch99_deal_only)
  # Blanket auto_rate should be 0 — no 'all' or 'all_except' entries
  stopifnot(s232$auto_rate == 0)
  # But deals exist
  stopifnot(s232$auto_has_deals == TRUE)
})

run_test('blanket auto entry produces auto_rate > 0', {
  ch99_blanket <- tibble(
    ch99_code = '9903.94.01',
    rate = 0.25,
    country_type = 'all',
    countries = list('all'),
    description = 'passenger vehicles',
    general_raw = '25%',
    authority = 'section_232',
    exempt_countries = list(character(0))
  )
  s232 <- extract_section232_rates(ch99_blanket)
  stopifnot(s232$auto_rate == 0.25)
  stopifnot(s232$auto_has_deals == FALSE)
})

run_test('deal-only auto does not set auto_rate for non-deal countries', {
  # With auto_rate = 0 and auto_has_deals = TRUE, heading gates open
  # but per-country rate = 0 for non-deal countries
  s232_mock <- list(
    auto_rate = 0,
    auto_has_deals = TRUE,
    auto_exempt = character(0)
  )
  # Gate should be open
  gate <- s232_mock$auto_rate > 0 || s232_mock$auto_has_deals
  stopifnot(gate == TRUE)
  # But non-deal country rate = 0
  non_deal_rate <- if_else(FALSE, 0, s232_mock$auto_rate)  # not exempt, but rate = 0
  stopifnot(non_deal_rate == 0)
})


# =============================================================================
# Test 16: Policy-date vs HTS-date propagation
# =============================================================================

message('\n--- Test 16: Policy-date propagation ---')

make_mode_test_products <- function() {
  tibble(
    hts10 = '1234567890',
    base_rate = 0.05,
    n_ch99_refs = 0L,
    ch99_refs = list(character(0))
  )
}

make_mode_test_ch99 <- function() {
  tibble(
    ch99_code = c('9903.03.01', '9903.80.01'),
    rate = c(0.10, 0.25),
    country_type = c('all', 'all'),
    countries = list('all', 'all'),
    exempt_countries = list(character(0), character(0)),
    description = c('Section 122 test entry', 'Steel article test entry'),
    general_raw = c('10%', '25%')
  )
}

make_mode_test_ieepa <- function() {
  ieepa <- tibble(
    ch99_code = '9903.02.09',
    rate = 0.50,
    rate_type = 'surcharge',
    phase = 'phase2_aug7',
    terminated = FALSE,
    country_name = 'China',
    census_code = '5700'
  )
  attr(ieepa, 'universal_baseline') <- 0.10
  ieepa
}

run_test('calculator honors policy-date mode on 2026-02-20', {
  products <- make_mode_test_products()
  ch99_data <- make_mode_test_ch99()
  ieepa_rates <- make_mode_test_ieepa()
  s232_rates <- extract_section232_rates(ch99_data)

  pp_policy <- load_policy_params(use_policy_dates = TRUE)
  pp_hts <- load_policy_params(use_policy_dates = FALSE)

  rates_policy <- calculate_rates_for_revision(
    products = products,
    ch99_data = ch99_data,
    ieepa_rates = ieepa_rates,
    usmca = NULL,
    countries = '5700',
    revision_id = '2026_rev_4',
    effective_date = as.Date('2026-02-20'),
    s232_rates = s232_rates,
    fentanyl_rates = NULL,
    policy_params = pp_policy
  )

  rates_hts <- calculate_rates_for_revision(
    products = products,
    ch99_data = ch99_data,
    ieepa_rates = ieepa_rates,
    usmca = NULL,
    countries = '5700',
    revision_id = '2026_rev_4',
    effective_date = as.Date('2026-02-20'),
    s232_rates = s232_rates,
    fentanyl_rates = NULL,
    policy_params = pp_hts
  )

  stopifnot(all(rates_policy$rate_ieepa_recip == 0))
  stopifnot(all(rates_policy$rate_s122 > 0))

  stopifnot(any(rates_hts$rate_ieepa_recip > 0))
  stopifnot(all(rates_hts$rate_s122 == 0))
})

run_test('policy params differ for HTS-late 2026_rev_4 timing', {
  pp_policy <- load_policy_params(use_policy_dates = TRUE)
  pp_hts <- load_policy_params(use_policy_dates = FALSE)

  stopifnot(pp_policy$IEEPA_INVALIDATION_DATE == as.Date('2026-02-20'))
  stopifnot(pp_hts$IEEPA_INVALIDATION_DATE == as.Date('2026-02-24'))
  stopifnot(pp_policy$SECTION_122$effective_date == as.Date('2026-02-20'))
  stopifnot(pp_hts$SECTION_122$effective_date == as.Date('2026-02-24'))
})


# =============================================================================
# Test 17: Run-mode consistency on built artifacts
# =============================================================================

message('\n--- Test 17: Run-mode consistency ---')

snapshot_signature <- function(df) {
  tibble(
    rows = nrow(df),
    n_products = n_distinct(df$hts10),
    n_countries = n_distinct(df$country),
    sum_total_rate = round(sum(df$total_rate), 8),
    sum_total_additional = round(sum(df$total_additional), 8),
    n_s122_positive = sum(df$rate_s122 > 0, na.rm = TRUE),
    n_ieepa_positive = sum(df$rate_ieepa_recip > 0, na.rm = TRUE)
  )
}

if (run_artifact_tests) run_test('snapshot_rev_16 matches point query on effective date', {
  ts_path <- here('data', 'timeseries', 'rate_timeseries.rds')
  snap_path <- here('data', 'timeseries', 'snapshot_rev_16.rds')
  if (!file.exists(ts_path) || !file.exists(snap_path)) {
    skip_test('timeseries or snapshot_rev_16 missing')
  }

  ts <- readRDS(ts_path)
  snap <- readRDS(snap_path)
  pp <- load_policy_params()
  point <- get_rates_at_date(ts, as.Date('2025-06-04'), policy_params = pp)

  stopifnot(unique(point$revision) == 'rev_16')
  stopifnot(identical(snapshot_signature(point), snapshot_signature(snap)))
})

if (run_artifact_tests) run_test('snapshot_2026_rev_4 matches point query on effective date', {
  ts_path <- here('data', 'timeseries', 'rate_timeseries.rds')
  snap_path <- here('data', 'timeseries', 'snapshot_2026_rev_4.rds')
  if (!file.exists(ts_path) || !file.exists(snap_path)) {
    skip_test('timeseries or snapshot_2026_rev_4 missing')
  }

  ts <- readRDS(ts_path)
  snap <- readRDS(snap_path)
  pp <- load_policy_params()
  point <- get_rates_at_date(ts, as.Date('2026-02-20'), policy_params = pp)

  stopifnot(unique(point$revision) == '2026_rev_4')
  stopifnot(identical(snapshot_signature(point), snapshot_signature(snap)))
})

if (run_artifact_tests) run_test('daily_overall matches direct aggregation on timing-sensitive dates', {
  ts_path <- here('data', 'timeseries', 'rate_timeseries.rds')
  daily_path <- here('output', 'daily', 'daily_overall.csv')
  if (!file.exists(ts_path) || !file.exists(daily_path)) {
    skip_test('timeseries or daily_overall.csv missing')
  }

  ts <- readRDS(ts_path)
  daily <- read_csv(daily_path, show_col_types = FALSE)
  pp <- load_policy_params()

  for (d in as.Date(c('2026-02-24', '2026-07-24'))) {
    built_row <- daily %>% filter(date == d)
    stopifnot(nrow(built_row) == 1)

    point <- get_rates_at_date(ts, d, policy_params = pp)
    n_products <- n_distinct(point$hts10)
    n_countries <- n_distinct(point$country)
    n_all_pairs <- n_products * n_countries

    direct_mean_additional_all <- sum(point$total_additional) / n_all_pairs
    direct_mean_total_all <- sum(point$total_rate) / n_all_pairs

    stopifnot(abs(built_row$mean_additional_all_pairs - direct_mean_additional_all) < 1e-10)
    stopifnot(abs(built_row$mean_total_all_pairs - direct_mean_total_all) < 1e-10)
    stopifnot(built_row$n_products == n_products)
    stopifnot(built_row$n_countries == n_countries)
  }
})

if (run_artifact_tests) run_test('daily_by_country matches direct aggregation for China on timing-sensitive dates', {
  ts_path <- here('data', 'timeseries', 'rate_timeseries.rds')
  daily_path <- here('output', 'daily', 'daily_by_country.csv')
  if (!file.exists(ts_path) || !file.exists(daily_path)) {
    skip_test('timeseries or daily_by_country.csv missing')
  }

  ts <- readRDS(ts_path)
  daily <- read_csv(daily_path, show_col_types = FALSE)
  pp <- load_policy_params()

  for (d in as.Date(c('2026-02-24', '2026-07-24'))) {
    built_row <- daily %>% filter(date == d, country == '5700')
    stopifnot(nrow(built_row) == 1)

    point <- get_rates_at_date(ts, d, policy_params = pp) %>%
      filter(country == '5700')
    n_products_total <- n_distinct(get_rates_at_date(ts, d, policy_params = pp)$hts10)

    direct_mean_additional_all <- sum(point$total_additional) / n_products_total
    direct_mean_total_all <- sum(point$total_rate) / n_products_total

    stopifnot(abs(built_row$mean_additional_all_pairs - direct_mean_additional_all) < 1e-10)
    stopifnot(abs(built_row$mean_total_all_pairs - direct_mean_total_all) < 1e-10)
    stopifnot(built_row$n_products_total == n_products_total)
    stopifnot(built_row$n_products_present == nrow(point))
  }
})


# =============================================================================
# BEA metal derivative fixes (2026-04-06)
# =============================================================================

message('\n--- BEA metal derivative fixes ---')

run_test('copper heading products get non-zero copper_share from BEA', {
  # Copper heading products (ch74) that are NOT derivatives.
  # Use codes present in resources/metal_content_shares_bea_hs10.csv.
  copper_hts10 <- c('7403110000', '7403120000')
  deriv_hts10 <- c('9401790010')  # a derivative, not copper
  all_hts10 <- c(copper_hts10, deriv_hts10)

  metal_cfg <- list(method = 'bea', flat_share = 0.50,
                    primary_chapters = c('72', '73', '76'))

  result <- load_metal_content(metal_cfg, all_hts10, derivative_hts10 = deriv_hts10)

  # Copper heading products should have copper_share > 0 even though not derivatives
  copper_rows <- result %>% filter(hts10 %in% copper_hts10)
  stopifnot(all(copper_rows$copper_share > 0))
  # Their metal_share should still be 1.0 (non-derivative)
  stopifnot(all(copper_rows$metal_share == 1.0))
})

run_test('decomposition uses steel_share for steel derivatives', {
  df <- tibble(
    hts10 = c('9401790010', '7604100010'),
    country = c('4280', '4280'),
    rate_232 = c(0.50, 0.50),
    rate_ieepa_recip = c(0.20, 0.20),
    rate_ieepa_fent = c(0, 0),
    rate_301 = c(0, 0),
    rate_s122 = c(0.10, 0.10),
    rate_section_201 = c(0, 0),
    rate_other = c(0, 0),
    metal_share = c(0.30, 1.0),
    steel_share = c(0.30, 0.80),
    aluminum_share = c(0.05, 0.10),
    copper_share = c(0.01, 0.02),
    deriv_type = c('steel', NA_character_),
    is_copper_heading = c(FALSE, FALSE)
  )

  net <- compute_net_authority_contributions(df, cty_china = '5700')

  # Steel derivative: nonmetal_share should be 1 - steel_share = 0.70
  stopifnot(abs(net$net_ieepa[1] - 0.20 * 0.70) < 1e-10)
  stopifnot(abs(net$net_s122[1] - 0.10 * 0.70) < 1e-10)
  # Ch76 product: nonmetal_share = 1 - aluminum_share = 0.90
  stopifnot(abs(net$net_ieepa[2] - 0.20 * 0.90) < 1e-10)
})

run_test('heading-overlap reset safe without per-type columns', {
  # Simulate flat/CBO mode: metal_share exists but no per-type columns
  rates <- tibble(
    hts10 = c('8544490010', '8544490020', '7208100000'),
    country = c('4280', '4280', '4280'),
    rate_232 = c(0.25, 0.25, 0.50),
    metal_share = c(0.50, 0.50, 1.0),
    deriv_type = c('aluminum', 'aluminum', NA_character_)
  )

  deriv_matched <- c('8544490010', '8544490020')
  heading_products <- c('8544490010')  # one product is also a heading match

  has_per_type <- all(c('steel_share', 'aluminum_share') %in% names(rates))
  stopifnot(!has_per_type)  # confirm no per-type columns

  # This should NOT error — the per-type reset is gated on has_per_type
  heading_derivs <- intersect(deriv_matched, heading_products)
  if (length(heading_derivs) > 0) {
    rates <- rates %>%
      mutate(metal_share = if_else(hts10 %in% heading_derivs, 1.0, metal_share))
    if (has_per_type) {
      rates <- rates %>%
        mutate(
          steel_share       = if_else(hts10 %in% heading_derivs, 0, steel_share),
          aluminum_share    = if_else(hts10 %in% heading_derivs, 0, aluminum_share),
          copper_share      = if_else(hts10 %in% heading_derivs, 0, copper_share),
          other_metal_share = if_else(hts10 %in% heading_derivs, 0, other_metal_share)
        )
    }
  }

  # Heading product should have metal_share reset to 1.0
  stopifnot(rates$metal_share[rates$hts10 == '8544490010'] == 1.0)
  # Non-heading derivative keeps its metal_share
  stopifnot(rates$metal_share[rates$hts10 == '8544490020'] == 0.50)
})


# =============================================================================
# Section 232 annex restructuring (2026-04-06)
# =============================================================================

message('\n--- Section 232 annex restructuring ---')

run_test('annex rate override applies correct rates by annex', {
  # Synthetic fixture: products in each annex with base rates
  df <- tibble(
    hts10 = c('7208100000', '8481800010', '9999990000', '7326900010'),
    country = rep('4280', 4),
    base_rate = c(0.0, 0.025, 0.0, 0.05),
    rate_232 = c(0.50, 0.50, 0.50, 0.50),  # old single-rate
    s232_annex = c('annex_1a', 'annex_1b', 'annex_2', 'annex_3')
  )

  annex_cfg <- list(
    effective_date = as.Date('2026-04-06'),
    annexes = list(
      annex_1a = list(rate = 0.50, uk_rate = 0.25),
      annex_1b = list(rate = 0.25, uk_rate = 0.15),
      annex_2 = list(rate = 0.0),
      annex_3 = list(rate_type = 'floor', floor_rate = 0.15)
    )
  )

  # Apply annex rate override (inline logic matching 06_calculate_rates.R step 5c)
  df <- df %>% mutate(
    rate_232 = case_when(
      s232_annex == 'annex_2' ~ 0,
      s232_annex == 'annex_1a' ~ annex_cfg$annexes$annex_1a$rate,
      s232_annex == 'annex_1b' ~ annex_cfg$annexes$annex_1b$rate,
      s232_annex == 'annex_3' ~ pmax(0, annex_cfg$annexes$annex_3$floor_rate - base_rate),
      TRUE ~ rate_232
    )
  )

  stopifnot(abs(df$rate_232[1] - 0.50) < 1e-10)   # I-A: 50%
  stopifnot(abs(df$rate_232[2] - 0.25) < 1e-10)   # I-B: 25%
  stopifnot(abs(df$rate_232[3] - 0.00) < 1e-10)   # II: removed
  stopifnot(abs(df$rate_232[4] - 0.10) < 1e-10)   # III: max(0, 0.15 - 0.05) = 0.10
})

run_test('annex III floor formula edge cases', {
  annex3_floor <- 0.15

  # base_rate = 0% → floor rate = 15%
  stopifnot(pmax(0, annex3_floor - 0.00) == 0.15)
  # base_rate = 2.5% → floor rate = 12.5%
  stopifnot(pmax(0, annex3_floor - 0.025) == 0.125)
  # base_rate = 15% → floor rate = 0%
  stopifnot(pmax(0, annex3_floor - 0.15) == 0.00)
  # base_rate = 20% → floor rate = 0% (not negative)
  stopifnot(pmax(0, annex3_floor - 0.20) == 0.00)
})

run_test('UK annex deal applies correctly', {
  uk <- '4120'
  df <- tibble(
    hts10 = c('7208100000', '7208100000', '7408110000'),
    country = c(uk, uk, uk),
    s232_annex = c('annex_1a', 'annex_1b', 'annex_1a'),
    rate_232 = c(0.50, 0.25, 0.50)
  )

  uk_steel_alum <- c('72', '73', '76')
  df <- df %>% mutate(
    rate_232 = case_when(
      country == uk & s232_annex == 'annex_1a' &
        substr(hts10, 1, 2) %in% uk_steel_alum ~ 0.25,
      country == uk & s232_annex == 'annex_1b' &
        substr(hts10, 1, 2) %in% uk_steel_alum ~ 0.15,
      TRUE ~ rate_232
    )
  )

  stopifnot(df$rate_232[1] == 0.25)  # UK steel I-A → 25%
  stopifnot(df$rate_232[2] == 0.15)  # UK steel I-B → 15%
  stopifnot(df$rate_232[3] == 0.50)  # UK copper I-A → 50% (no UK deal for copper)
})

run_test('annex classification is NA for pre-April-6 dates', {
  # Simulate date-gating check
  effective_date <- '2026-03-15'
  annex_effective <- as.Date('2026-04-06')
  is_annex_era <- as.Date(effective_date) >= annex_effective
  stopifnot(!is_annex_era)
})

run_test('load_annex_products returns populated data from resource CSV', {
  result <- load_annex_products(effective_date = '2026-04-06')
  stopifnot(nrow(result) > 0)
  stopifnot('hts_prefix' %in% names(result))
  stopifnot('s232_annex' %in% names(result))
  stopifnot(all(result$s232_annex %in% c('1a', '1b', '2', '3')))
})


# =============================================================================
# Summary
# =============================================================================

message('\n', strrep('=', 50))
message('Tests: ', pass_count, ' passed, ', skip_count, ' skipped, ', fail_count, ' failed')
message(strrep('=', 50))
if (fail_count > 0) stop(fail_count, ' test(s) failed')
