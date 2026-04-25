# =============================================================================
# Tests: DataWeb response parser
# =============================================================================
#
# Pins parse_annual_dto() and parse_monthly_dto() against synthetic DataWeb
# response fixtures. Regression coverage for the 2026-04 incident where a
# new "Year" column at position [[2]] silently dropped every monthly record
# (483K rows in -> 0 rows out, no error). Synthetic-only — no network calls.
#
# Usage:
#   Rscript tests/test_dataweb_parser.R
#
# =============================================================================

library(tidyverse)
library(here)

source(here('src', 'dataweb_parser.R'))

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
# Fixture builders
# =============================================================================

# Build a single rowEntries entry as DataWeb returns them: list(label, value).
make_entry <- function(value, label = NULL) list(label = label, value = value)

# Build a row from a character vector of cell values.
make_row <- function(values) list(rowEntries = lapply(values, make_entry))

# Build a parsed dto envelope.
#   rows         : list of make_row() outputs
#   value_labels : NULL for annual / shape (a) monthly tables;
#                  c('January',...,'December') for shape (b) tables
#   table_title  : 'January 2025' etc. for shape (a); NULL otherwise
make_dto <- function(rows, value_labels = NULL, table_title = NULL,
                     errors = list()) {
  column_groups <- list(list())  # placeholder for header columns
  if (!is.null(value_labels)) {
    column_groups <- c(
      column_groups,
      list(list(columns = lapply(value_labels, function(l) list(label = l))))
    )
  }
  list(
    errors = errors,
    tables = list(list(
      tableTitle = table_title,
      column_groups = column_groups,
      row_groups = list(list(rowsNew = rows))
    ))
  )
}


# =============================================================================
# Test 1: Monthly parser — current (2026-04) schema with Year column
# =============================================================================

message('\n--- Test 1: parse_monthly_dto, current schema ---')

run_test('handles [hts, year, country, description, jan..dec] schema', {
  rows <- list(
    make_row(c('0101210010', '2025', 'Canada', 'Live horses',
               '100', '200', '300', '0', '0', '0', '0', '0', '0', '0', '0', '0')),
    make_row(c('0101210010', '2025', 'Mexico', 'Live horses',
               '50', '60', '70', '0', '0', '0', '0', '0', '0', '0', '0', '0'))
  )
  dto <- make_dto(rows, value_labels = month.name)
  out <- parse_monthly_dto(dto)
  stopifnot(nrow(out) == 24)  # 2 rows * 12 months
  stopifnot(setequal(unique(out$country), c('Canada', 'Mexico')))
  stopifnot(out$value[out$month == 1 & out$country == 'Canada'] == 100)
  stopifnot(out$value[out$month == 3 & out$country == 'Mexico'] == 70)
})

run_test('parses comma-separated values', {
  rows <- list(
    make_row(c('0101210010', '2025', 'Canada', 'Live horses',
               '1,234,567', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0'))
  )
  dto <- make_dto(rows, value_labels = month.name)
  out <- parse_monthly_dto(dto)
  stopifnot(out$value[out$month == 1] == 1234567)
})

run_test('treats missing value entries as zero', {
  rows <- list(
    list(rowEntries = list(
      make_entry('0101210010'), make_entry('2025'),
      make_entry('Canada'), make_entry('Live horses'),
      make_entry(NULL),  # NULL Jan value -> should coerce to 0
      make_entry('100'),
      make_entry('0'), make_entry('0'), make_entry('0'), make_entry('0'),
      make_entry('0'), make_entry('0'), make_entry('0'), make_entry('0'),
      make_entry('0'), make_entry('0')
    ))
  )
  dto <- make_dto(rows, value_labels = month.name)
  out <- parse_monthly_dto(dto)
  stopifnot(out$value[out$month == 1] == 0)
  stopifnot(out$value[out$month == 2] == 100)
})


# =============================================================================
# Test 2: Monthly parser — legacy schema (no Year column)
# =============================================================================

message('\n--- Test 2: parse_monthly_dto, legacy schema (no Year) ---')

run_test('handles [hts, country, description, jan..dec] schema', {
  rows <- list(
    make_row(c('0101210010', 'Canada', 'Live horses',
               '100', '200', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0'))
  )
  dto <- make_dto(rows, value_labels = month.name)
  out <- parse_monthly_dto(dto)
  stopifnot(nrow(out) == 12)
  stopifnot(unique(out$country) == 'Canada')
  stopifnot(out$value[out$month == 1] == 100)
})


# =============================================================================
# Test 3: Monthly parser — shape (a), one table per month
# =============================================================================

message('\n--- Test 3: parse_monthly_dto, shape (a) per-month tables ---')

run_test('uses tableTitle to identify the month', {
  rows <- list(
    make_row(c('0101210010', '2025', 'Canada', 'Live horses', '500'))
  )
  dto <- make_dto(rows, value_labels = NULL, table_title = 'July 2025 Customs Value')
  out <- parse_monthly_dto(dto)
  stopifnot(nrow(out) == 1)
  stopifnot(out$month == 7)
  stopifnot(out$country == 'Canada')
  stopifnot(out$value == 500)
})

run_test('skips tables whose title does not start with a month name', {
  rows <- list(
    make_row(c('0101210010', '2025', 'Canada', 'Live horses', '500'))
  )
  dto <- make_dto(rows, value_labels = NULL, table_title = 'Summary 2025')
  out <- parse_monthly_dto(dto)
  stopifnot(nrow(out) == 0)
})


# =============================================================================
# Test 4: Fail-loud on schema regression
# =============================================================================

message('\n--- Test 4: fail-loud when Country is not in header range ---')

run_test('parse_monthly_dto stops if no Canada/Mexico in header', {
  # Hypothetical future schema: Country pushed beyond the header range.
  rows <- list(
    make_row(c('0101210010', '2025', 'Live horses', 'Other',
               '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0'))
  )
  dto <- make_dto(rows, value_labels = month.name)
  err <- tryCatch(parse_monthly_dto(dto), error = function(e) conditionMessage(e))
  stopifnot(grepl('no Canada/Mexico', err, fixed = TRUE))
})

run_test('parse_annual_dto stops if no Canada/Mexico in header', {
  rows <- list(
    make_row(c('0101210010', 'Live horses', 'Other', '1,234'))
  )
  dto <- make_dto(rows)
  err <- tryCatch(parse_annual_dto(dto), error = function(e) conditionMessage(e))
  stopifnot(grepl('no Canada/Mexico', err, fixed = TRUE))
})

run_test('error message includes the observed header values for debugging', {
  rows <- list(
    make_row(c('0101210010', 'Live horses', 'Other', '1,234'))
  )
  dto <- make_dto(rows)
  err <- tryCatch(parse_annual_dto(dto), error = function(e) conditionMessage(e))
  stopifnot(grepl('Live horses', err, fixed = TRUE))
})


# =============================================================================
# Test 5: Annual parser
# =============================================================================

message('\n--- Test 5: parse_annual_dto, current schema ---')

run_test('handles [hts, country, description, value] schema', {
  rows <- list(
    make_row(c('0101210010', 'Canada', 'Live horses', '1,234,567')),
    make_row(c('0101210010', 'Mexico', 'Live horses', '987,654'))
  )
  dto <- make_dto(rows)
  out <- parse_annual_dto(dto)
  stopifnot(nrow(out) == 2)
  stopifnot(out$value[out$country == 'Canada'] == 1234567)
  stopifnot(out$value[out$country == 'Mexico'] == 987654)
})


# =============================================================================
# Test 6: Empty/error response handling
# =============================================================================

message('\n--- Test 6: empty and error responses ---')

run_test('parse_monthly_dto returns empty tibble when no tables', {
  out <- parse_monthly_dto(list(errors = list(), tables = list()))
  stopifnot(nrow(out) == 0)
  stopifnot(setequal(names(out), c('month', 'hts10', 'country', 'value')))
})

run_test('parse_annual_dto returns empty tibble when no tables', {
  out <- parse_annual_dto(list(errors = list(), tables = list()))
  stopifnot(nrow(out) == 0)
  stopifnot(setequal(names(out), c('hts10', 'country', 'value')))
})

run_test('parse_monthly_dto stops when dto contains errors', {
  dto <- list(errors = list('Quota exceeded'), tables = list())
  err <- tryCatch(parse_monthly_dto(dto), error = function(e) conditionMessage(e))
  stopifnot(grepl('Quota exceeded', err, fixed = TRUE))
})


# =============================================================================
# Summary
# =============================================================================

cat('\n')
cat('Tests: ', pass_count, ' passed, ', skip_count, ' skipped, ', fail_count, ' failed\n')

if (fail_count > 0) quit(status = 1)
