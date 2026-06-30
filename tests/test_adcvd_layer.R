# =============================================================================
# Tests for the AD/CVD layer loader (src/experimental/load_adcvd_layer.R)
# =============================================================================
# Exercises loader logic on synthetic fixtures — no real AD/CVD data required.
# Run: Rscript tests/test_adcvd_layer.R
# =============================================================================

suppressMessages({
  library(tidyverse)
  library(here)
})
source(here('src', 'experimental', 'load_adcvd_layer.R'))

pass_count <- 0; fail_count <- 0
run_test <- function(name, expr) {
  tryCatch({ force(expr); message('  PASS: ', name); pass_count <<- pass_count + 1 },
           error = function(e) { message('  FAIL: ', name, ' — ', conditionMessage(e))
                                 fail_count <<- fail_count + 1 })
}

# Write a temp orders file from a tibble (with optional comment lines).
write_orders <- function(df, comments = character(0)) {
  p <- tempfile(fileext = '.csv')
  con <- file(p, 'w')
  if (length(comments) > 0) writeLines(paste0('# ', comments), con)
  writeLines('case_number,country,hts,rate,effective_date,revoked_date', con)
  if (nrow(df) > 0) {
    lines <- df %>% mutate(
      revoked_date = ifelse(is.na(revoked_date), '', as.character(revoked_date)),
      row = sprintf('%s,%s,%s,%s,%s,%s', case_number, country, hts, rate,
                    as.character(effective_date), revoked_date)
    ) %>% pull(row)
    writeLines(lines, con)
  }
  close(con); p
}

UNIVERSE <- c('8413810000', '8413820000', '8482101000', '7320103000',
              '7308200030', '8703230000')

message('\n--- AD/CVD loader tests ---')

run_test('missing file -> empty layer', {
  out <- load_adcvd_layer(path = tempfile(fileext = '.csv'))
  stopifnot(is.data.frame(out), nrow(out) == 0,
            identical(names(out), c('hts10', 'country', 'rate_adcvd')))
})

run_test('header-only file -> empty layer', {
  p <- write_orders(tibble(case_number=character(), country=character(),
                           hts=character(), rate=numeric(),
                           effective_date=as.Date(character()),
                           revoked_date=as.Date(character())))
  stopifnot(nrow(load_adcvd_layer(path = p, product_universe = UNIVERSE)) == 0)
})

run_test('prefix expansion fans HS8 to HTS-10 children', {
  p <- write_orders(tibble(case_number='A-570-001', country='5700', hts='84138',
                           rate=0.10, effective_date=as.Date('2020-01-01'),
                           revoked_date=as.Date(NA)))
  out <- load_adcvd_layer(path = p, product_universe = UNIVERSE)
  # 84138 should match 8413810000 and 8413820000, not 8482/7320/etc.
  stopifnot(setequal(out$hts10, c('8413810000', '8413820000')))
  stopifnot(all(out$rate_adcvd == 0.10))
})

run_test('A- and C- cases on same line stack additively', {
  p <- write_orders(tibble(
    case_number = c('A-570-002', 'C-570-003'),
    country     = c('5700', '5700'),
    hts         = c('8482101000', '8482101000'),
    rate        = c(0.20, 0.15),
    effective_date = as.Date(c('2019-01-01', '2019-01-01')),
    revoked_date   = as.Date(c(NA, NA))))
  out <- load_adcvd_layer(path = p, product_universe = UNIVERSE)
  stopifnot(nrow(out) == 1, out$hts10 == '8482101000',
            abs(out$rate_adcvd - 0.35) < 1e-9)
})

run_test('date gate drops not-yet-effective and revoked orders', {
  p <- write_orders(tibble(
    case_number = c('A-1', 'A-2', 'A-3'),
    country     = c('5700', '5700', '5700'),
    hts         = c('8482101000', '8482101000', '8413810000'),
    rate        = c(0.10, 0.20, 0.30),
    effective_date = as.Date(c('2030-01-01', '2018-01-01', '2018-01-01')),  # A-1 future
    revoked_date   = as.Date(c(NA, NA, '2019-01-01'))))                      # A-3 revoked
  out <- load_adcvd_layer(path = p, product_universe = UNIVERSE,
                          effective_date = as.Date('2020-06-01'))
  # Only A-2 active: 8482101000 @ 0.20; A-1 future and A-3 revoked excluded.
  stopifnot(nrow(out) == 1, out$hts10 == '8482101000',
            abs(out$rate_adcvd - 0.20) < 1e-9)
})

run_test('overlapping prefixes within one case collapse to max (specific wins)', {
  p <- write_orders(tibble(
    case_number = c('A-9', 'A-9'),
    country     = c('5700', '5700'),
    hts         = c('8413', '8413810000'),   # broad + specific, both hit 8413810000
    rate        = c(0.05, 0.12),
    effective_date = as.Date(c('2018-01-01', '2018-01-01')),
    revoked_date   = as.Date(c(NA, NA))))
  out <- load_adcvd_layer(path = p, product_universe = UNIVERSE)
  specific <- out %>% filter(hts10 == '8413810000')
  stopifnot(nrow(specific) == 1, abs(specific$rate_adcvd - 0.12) < 1e-9)
})

run_test('comment lines are skipped', {
  p <- write_orders(tibble(case_number='A-7', country='5880', hts='8482101000',
                           rate=0.08, effective_date=as.Date('2010-01-01'),
                           revoked_date=as.Date(NA)),
                    comments = c('this is a comment', 'another'))
  out <- load_adcvd_layer(path = p, product_universe = UNIVERSE)
  stopifnot(nrow(out) == 1, out$country == '5880')
})

message('\n==================================================')
message('AD/CVD loader: ', pass_count, ' passed, ', fail_count, ' failed')
message('==================================================')
if (fail_count > 0) quit(status = 1)
