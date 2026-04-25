# =============================================================================
# DataWeb response parsers (pure functions)
# =============================================================================
#
# Extracted from download_usmca_dataweb.R so the parser is testable without
# hitting the network. Sourced by the downloader; covered by
# tests/test_dataweb_parser.R.
#
# Two entry points:
#   parse_annual_dto(dto)  -> tibble(hts10, country, value)
#   parse_monthly_dto(dto) -> tibble(month, hts10, country, value)
#
# Both accept the parsed body of a DataWeb runReport response (i.e., the
# `$dto` field of `httr::content(resp, as = 'parsed', simplifyVector = FALSE)`).
#
# Requires tidyverse loaded by the caller for tibble(), map_df(), %||%.
# =============================================================================

MONTH_NAMES <- c('January' = 1L, 'February' = 2L, 'March' = 3L, 'April' = 4L,
                 'May' = 5L, 'June' = 6L, 'July' = 7L, 'August' = 8L,
                 'September' = 9L, 'October' = 10L, 'November' = 11L, 'December' = 12L)

EMPTY_ANNUAL <- tibble(hts10 = character(), country = character(),
                       value = numeric())
EMPTY_MONTHLY <- tibble(month = integer(), hts10 = character(),
                        country = character(), value = numeric())

# Locate the "Country" column by value rather than fixed position. DataWeb has
# shifted column ordering at least once (around 2026-04 it inserted a "Year"
# column at position [[2]] for monthly queries, pushing Country to [[3]]).
# Searching for "Canada"/"Mexico" in the header range is robust to further
# reorderings within the header.
find_country_idx <- function(entries, value_start) {
  if (value_start <= 1) return(NA_integer_)
  header <- entries[seq_len(value_start - 1)]
  idx <- which(vapply(header,
                      function(e) (e$value %||% '') %in% c('Canada', 'Mexico'),
                      logical(1)))
  if (length(idx) == 0) NA_integer_ else idx[[1]]
}

month_value_cols <- function(tbl) {
  cg <- tbl$column_groups
  if (length(cg) < 2) return(NULL)
  labels <- vapply(cg[[2]]$columns,
                   function(col) col$label %||% NA_character_,
                   character(1))
  months <- MONTH_NAMES[labels]
  if (!any(!is.na(months))) return(NULL)
  months
}

.header_dump <- function(entries, value_start) {
  if (value_start <= 1) return('<empty>')
  paste(vapply(entries[seq_len(value_start - 1)],
               function(e) e$value %||% '<NA>',
               character(1)),
        collapse = ' | ')
}

.check_dto_errors <- function(dto) {
  errors <- dto$errors
  if (length(errors) > 0) {
    stop('DataWeb API error: ', paste(errors, collapse = '; '))
  }
}

#' Parse an annual DataWeb response payload.
#' @param dto The `$dto` element of a parsed runReport response.
#' @return tibble(hts10, country, value); empty tibble if no rows.
parse_annual_dto <- function(dto) {
  .check_dto_errors(dto)

  tables <- dto$tables
  if (length(tables) == 0) return(EMPTY_ANNUAL)

  rows <- tables[[1]]$row_groups[[1]]$rowsNew
  if (length(rows) == 0) return(EMPTY_ANNUAL)

  first_entries <- rows[[1]]$rowEntries
  n_total <- length(first_entries)
  value_start <- n_total  # value is the trailing column
  cty_idx <- find_country_idx(first_entries, value_start)
  if (is.na(cty_idx)) {
    stop('DataWeb annual response schema unrecognized: no Canada/Mexico ',
         'value in header columns. Header: ',
         .header_dump(first_entries, value_start),
         '\nUpdate find_country_idx() in src/dataweb_parser.R if DataWeb has ',
         'reordered columns again.')
  }

  map_df(rows, function(r) {
    entries <- r$rowEntries
    tibble(
      hts10 = entries[[1]]$value,
      country = entries[[cty_idx]]$value,
      value = as.numeric(gsub(',', '', entries[[length(entries)]]$value))
    )
  })
}

#' Parse a monthly DataWeb response payload.
#'
#' Handles both shapes DataWeb returns:
#'   (a) one table per month, month identified by tableTitle's first word
#'   (b) one table with a value column per month, labels in column_groups[[2]]
#'
#' @param dto The `$dto` element of a parsed runReport response.
#' @return tibble(month, hts10, country, value); empty tibble if no rows.
parse_monthly_dto <- function(dto) {
  .check_dto_errors(dto)

  tables <- dto$tables
  if (length(tables) == 0) return(EMPTY_MONTHLY)

  parse_table <- function(tbl) {
    rows <- tbl$row_groups[[1]]$rowsNew
    if (length(rows) == 0) return(EMPTY_MONTHLY)

    value_months <- month_value_cols(tbl)
    first_entries <- rows[[1]]$rowEntries
    n_total <- length(first_entries)
    value_start <- if (!is.null(value_months)) {
      n_total - length(value_months) + 1
    } else {
      n_total  # value is the trailing column (shape a)
    }

    cty_idx <- find_country_idx(first_entries, value_start)
    if (is.na(cty_idx)) {
      stop('DataWeb monthly response schema unrecognized: no Canada/Mexico ',
           'value in header columns. Header: ',
           .header_dump(first_entries, value_start),
           '\nUpdate find_country_idx() in src/dataweb_parser.R if DataWeb ',
           'has reordered columns again.')
    }

    if (!is.null(value_months)) {
      value_range <- value_start:n_total
      map_df(rows, function(r) {
        entries <- r$rowEntries
        hts10 <- entries[[1]]$value
        country <- entries[[cty_idx]]$value
        value_entries <- entries[value_range]
        map_df(seq_along(value_entries), function(j) {
          month_num <- value_months[[j]]
          if (is.na(month_num)) return(EMPTY_MONTHLY)
          tibble(
            month = unname(month_num),
            hts10 = hts10,
            country = country,
            value = as.numeric(gsub(',', '', value_entries[[j]]$value %||% '0'))
          )
        })
      })
    } else {
      title <- tbl$tableTitle %||% ''
      month_word <- sub(' .*', '', title)
      month_num <- MONTH_NAMES[month_word]
      if (is.na(month_num)) return(EMPTY_MONTHLY)
      map_df(rows, function(r) {
        entries <- r$rowEntries
        tibble(
          month = unname(month_num),
          hts10 = entries[[1]]$value,
          country = entries[[cty_idx]]$value,
          value = as.numeric(gsub(',', '', entries[[length(entries)]]$value))
        )
      })
    }
  }

  map_df(tables, parse_table)
}
