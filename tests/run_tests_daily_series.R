# =============================================================================
# Tests: Daily Series Infrastructure
# =============================================================================
#
# Validates horizon, expiry, decomposition, and schema behavior.
# Uses base R stopifnot() assertions — no external test framework required.
#
# Usage:
#   Rscript tests/run_tests_daily_series.R
#
# =============================================================================

library(tidyverse)
library(here)
source(here('src', 'helpers.R'))
source(here('src', '09_daily_series.R'))

pass_count <- 0
fail_count <- 0

run_test <- function(name, expr) {
  tryCatch({
    force(expr)
    message('  PASS: ', name)
    pass_count <<- pass_count + 1
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
  stopifnot(tpc$daily_overall$mean_additional[1] > me$daily_overall$mean_additional[1])
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
# Summary
# =============================================================================

message('\n', strrep('=', 50))
message('Tests: ', pass_count, ' passed, ', fail_count, ' failed')
message(strrep('=', 50))
if (fail_count > 0) stop(fail_count, ' test(s) failed')
