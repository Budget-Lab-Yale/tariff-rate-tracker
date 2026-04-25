#!/usr/bin/env Rscript
# =============================================================================
# Download product-level USMCA utilization shares from USITC DataWeb API
# =============================================================================
#
# Uses the DataWeb API to query imports by Special Program Indicator (SPI)
# codes "S" and "S+" which identify USMCA-claimed trade.
#
# Why DataWeb (not Census API): The Census API's Rate Provision (RP) field
# only captures ~50% of USMCA trade. RP=18 identifies imports that received
# preferential duty rates under USMCA, but misses USMCA-claimed products that
# are already MFN duty-free (which show as RP=10). DataWeb's SPI program
# filter captures ALL USMCA-claimed trade regardless of duty treatment.
#
# Validation: Aggregate 2024 shares from DataWeb match Brookings/USITC:
#   Canada: ~38% (Brookings Dec 2024: 35.5%)
#   Mexico: ~50% (Brookings Dec 2024: 49.5%)
#
# Prerequisites:
#   - USITC DataWeb account (free): https://dataweb.usitc.gov/
#   - API token saved in .env file as DATAWEB_API_TOKEN=<your-token>
#
# Output: resources/usmca_product_shares.csv
#   Columns: hts10, cty_code, usmca_share
#
# Usage: Rscript src/download_usmca_dataweb.R
#        Rscript src/download_usmca_dataweb.R --year 2024
#        Rscript src/download_usmca_dataweb.R --env-file /path/to/.env
# =============================================================================

library(tidyverse)
library(here)
library(jsonlite)
library(httr)

# --- Constants ---
DATAWEB_BASE <- 'https://datawebws.usitc.gov/dataweb'
CTY_CANADA <- '1220'
CTY_MEXICO <- '2010'
USMCA_PROGRAMS <- c('S', 'S+')
MEASURE <- 'CONS_CUSTOMS_VALUE'

# HTS chapters (01-98, excluding 77 which is reserved)
ALL_CHAPTERS <- sprintf('%02d', setdiff(1:98, 77))

# --- Parse arguments ---
args <- commandArgs(trailingOnly = TRUE)
year <- if ('--year' %in% args) {
  as.integer(args[which(args == '--year') + 1])
} else {
  2024L
}
run_monthly <- '--monthly' %in% args
env_file <- if ('--env-file' %in% args) {
  args[which(args == '--env-file') + 1]
} else {
  here('.env')
}
end_date_override <- if ('--end-date' %in% args) {
  args[which(args == '--end-date') + 1]
} else {
  NULL
}

parse_month_year <- function(x) {
  if (is.null(x)) return(NULL)
  if (!grepl('^(0[1-9]|1[0-2])/[0-9]{4}$', x)) {
    stop('--end-date must be in MM/YYYY format, got: ', x)
  }
  list(
    month = as.integer(sub('^([0-9]{2})/[0-9]{4}$', '\\1', x)),
    year = as.integer(sub('^[0-9]{2}/([0-9]{4})$', '\\1', x))
  )
}

strip_wrapping_quotes <- function(x) {
  x <- trimws(x)
  if (grepl("^['\"].*['\"]$", x)) {
    x <- substring(x, 2, nchar(x) - 1)
  }
  x
}

is_current_year <- function(year, today = Sys.Date()) {
  as.integer(year) == as.integer(format(as.Date(today), '%Y'))
}

build_component_settings <- function(year, monthly = FALSE, today = Sys.Date(),
                                     end_date_override = NULL) {
  year <- as.integer(year)
  today <- as.Date(today)
  years_timeline <- if (monthly) 'Monthly' else 'Annual'
  end_override <- parse_month_year(end_date_override)

  # DataWeb support advised using Year-to-Date rather than full-year Annual
  # queries for the current calendar year because the year is incomplete.
  if (is_current_year(year, today)) {
    current_month <- if (!is.null(end_override)) end_override$month else as.integer(format(today, '%m'))
    current_year <- if (!is.null(end_override)) end_override$year else as.integer(format(today, '%Y'))
    if (current_year != year) {
      stop('--end-date year must match --year for current-year YTD queries: ',
           current_year, ' != ', year)
    }
    return(list(
      dataToReport = list(MEASURE),
      scale = '1',
      timeframeSelectType = 'specificDateRange',
      years = list(as.character(year)),
      startDate = sprintf('01/%d', year),
      endDate = sprintf('%02d/%d', current_month, year),
      startMonth = jsonlite::unbox(NA),
      endMonth = jsonlite::unbox(NA),
      yearsTimeline = years_timeline
    ))
  }

  list(
    dataToReport = list(MEASURE),
    scale = '1',
    timeframeSelectType = 'fullYears',
    years = list(as.character(year)),
    startDate = jsonlite::unbox(NA),
    endDate = jsonlite::unbox(NA),
    startMonth = jsonlite::unbox(NA),
    endMonth = jsonlite::unbox(NA),
    yearsTimeline = years_timeline
  )
}

describe_timeframe <- function(year, monthly = FALSE, today = Sys.Date(),
                               end_date_override = NULL) {
  if (is_current_year(year, today)) {
    end_override <- parse_month_year(end_date_override)
    end_month <- if (!is.null(end_override)) {
      sprintf('%02d/%d', end_override$month, end_override$year)
    } else {
      format(as.Date(today), '%m/%Y')
    }
    return(sprintf('Year-to-Date (%s through %s, %s)',
                   year, end_month, if (monthly) 'Monthly' else 'Annual'))
  }
  sprintf('Full year (%s, %s)', year, if (monthly) 'Monthly' else 'Annual')
}

# --- Load token ---
load_token <- function(env_file) {
  if (!file.exists(env_file)) {
    stop('Token file not found: ', env_file, '\n',
         'Create a .env file with: DATAWEB_API_TOKEN=<your-token>\n',
         'Get a token from https://dataweb.usitc.gov/ (API tab, requires login)')
  }
  lines <- readLines(env_file, warn = FALSE)
  token_line <- grep('^DATAWEB_API_TOKEN=', lines, value = TRUE)
  if (length(token_line) == 0) {
    stop('DATAWEB_API_TOKEN not found in ', env_file)
  }
  token <- strip_wrapping_quotes(sub('^DATAWEB_API_TOKEN=', '', token_line[1]))
  if (!nzchar(token)) {
    stop('DATAWEB_API_TOKEN is empty in ', env_file)
  }
  token
}

token <- load_token(env_file)
message('USITC DataWeb USMCA share download')
message('  Year: ', year)
message('  Mode: ', if (run_monthly) 'monthly' else 'annual')
message('  DataWeb timeframe: ', describe_timeframe(year, run_monthly, end_date_override = end_date_override))
message('  Token: ', if (nzchar(token)) 'loaded' else 'missing')

# =============================================================================
# DataWeb API query functions
# =============================================================================

#' Build a DataWeb query for HTS10 x country customs value
#' @param chapters Character vector of 2-digit HTS chapter codes
#' @param countries Character vector of country codes
#' @param programs Character vector of SPI program codes (NULL = all)
#' @param year Integer year
#' @param monthly Logical; if TRUE, return monthly breakdown
build_query <- function(chapters, countries, programs = NULL, year, monthly = FALSE) {
  # Program filter
  if (!is.null(programs)) {
    ext_programs <- list(
      aggregation = 'Aggregate CSC',
      extImportPrograms = as.list(programs),
      extImportProgramsExpanded = list(),
      programsSelectType = 'list'
    )
  } else {
    ext_programs <- list(
      aggregation = 'Aggregate CSC',
      extImportPrograms = list(),
      extImportProgramsExpanded = list(),
      programsSelectType = 'all'
    )
  }

  list(
    savedQueryName = '',
    savedQueryDesc = '',
    isOwner = TRUE,
    runMonthly = monthly,
    reportOptions = list(
      tradeType = 'Import',
      classificationSystem = 'HTS'
    ),
    searchOptions = list(
      MiscGroup = list(
        districts = list(
          aggregation = 'Aggregate District',
          districtGroups = list(userGroups = list()),
          districts = list(),
          districtsExpanded = list(list(name = 'All Districts', value = 'all')),
          districtsSelectType = 'all'
        ),
        importPrograms = list(
          aggregation = jsonlite::unbox(NA),
          importPrograms = list(),
          programsSelectType = 'all'
        ),
        extImportPrograms = ext_programs,
        provisionCodes = list(
          aggregation = 'Aggregate RPCODE',
          provisionCodesSelectType = 'all',
          rateProvisionCodes = list(),
          rateProvisionCodesExpanded = list()
        )
      ),
      commodities = list(
        aggregation = 'Break Out Commodities',
        codeDisplayFormat = 'YES',
        commodities = as.list(chapters),
        commoditiesExpanded = list(),
        commoditiesManual = '',
        commodityGroups = list(systemGroups = list(), userGroups = list()),
        commoditySelectType = 'list',
        granularity = '10',
        groupGranularity = jsonlite::unbox(NA),
        searchGranularity = jsonlite::unbox(NA)
      ),
      componentSettings = build_component_settings(
        year,
        monthly = monthly,
        end_date_override = end_date_override
      ),
      countries = list(
        aggregation = 'Break Out Countries',
        countries = as.list(countries),
        countriesExpanded = lapply(countries, function(c) {
          list(name = if (c == CTY_CANADA) 'Canada' else 'Mexico', value = c)
        }),
        countriesSelectType = 'list',
        countryGroups = list(systemGroups = list(), userGroups = list())
      )
    ),
    sortingAndDataFormat = list(
      DataSort = list(
        columnOrder = list(),
        fullColumnOrder = list(),
        sortOrder = list()
      ),
      reportCustomizations = list(
        exportCombineTables = FALSE,
        showAllSubtotal = TRUE,
        subtotalRecords = '',
        totalRecords = '20000',
        exportRawData = FALSE
      )
    )
  )
}

#' Retryable transport-layer failures from the DataWeb API
#' @param msg Error message from httr/curl
#' @return Logical scalar
is_retryable_transport_error <- function(msg) {
  msg <- tolower(msg)
  patterns <- c(
    'timed out',
    'timeout',
    'could not resolve host',
    'couldn\'t resolve host',
    'could not connect',
    'couldn\'t connect',
    'failed to connect',
    'connection reset',
    'connection was reset',
    'connection was aborted',
    'failure when receiving data',
    'recv failure',
    'send failure',
    'empty reply from server',
    'server returned nothing',
    'ssl connect error',
    'schannel',
    'network is unreachable',
    'http/2 stream'
  )
  any(vapply(patterns, function(p) grepl(p, msg, fixed = TRUE), logical(1)))
}

is_retryable_http_status <- function(code) {
  code %in% c(429L, 500L, 502L, 503L, 504L)
}

http_status_hint <- function(code) {
  if (code == 503L) {
    return(' (DataWeb maintenance window? Wednesdays 5:30-8:30 PM ET)')
  }
  if (code %in% c(401L, 403L)) {
    return(' (check DATAWEB_API_TOKEN in .env)')
  }
  if (code == 429L) {
    return(' (rate limited)')
  }
  if (code %in% c(500L, 502L, 504L)) {
    return(' (transient server/network error)')
  }
  ''
}

format_http_error <- function(resp) {
  code <- status_code(resp)
  body_txt <- tryCatch(content(resp, as = 'text', encoding = 'UTF-8'),
                       error = function(e) '')
  paste0(
    'DataWeb API returned HTTP ', code, http_status_hint(code),
    '\nFirst 300 chars of body: ',
    substr(gsub('\\s+', ' ', body_txt), 1, 300)
  )
}

#' POST to DataWeb with retry on 429 / transient 5xx / transport failures
#' @return httr response object
post_runreport <- function(query, token, max_retries = 4, base_wait = 5,
                           request_timeout = 180) {
  url <- paste0(DATAWEB_BASE, '/api/v2/report2/runReport')
  body <- toJSON(query, auto_unbox = TRUE, null = 'null', na = 'null')

  for (attempt in seq_len(max_retries + 1L)) {
    resp <- tryCatch(
      POST(
        url = url,
        add_headers(
          'Content-Type' = 'application/json; charset=utf-8',
          'Authorization' = paste('Bearer', token)
        ),
        timeout(request_timeout),
        user_agent('tariff-rate-tracker-dataweb-downloader'),
        body = body,
        encode = 'raw'
      ),
      error = function(e) e
    )

    if (inherits(resp, 'error')) {
      msg <- conditionMessage(resp)
      if (attempt <= max_retries && is_retryable_transport_error(msg)) {
        wait <- base_wait * 2^(attempt - 1L)
        short_msg <- strsplit(msg, '\n', fixed = TRUE)[[1]][1]
        message('  (transport error; backing off ', wait, 's, attempt ',
                attempt, '/', max_retries, ': ', short_msg, ')')
        Sys.sleep(wait)
        next
      }
      stop(
        'DataWeb request failed before receiving an HTTP response',
        if (attempt > 1L) paste0(' after ', attempt, ' attempts') else '',
        ': ', msg,
        '\nLikely causes: transient network failure, DataWeb outage/maintenance, ',
        'TLS/proxy issues, or a local connectivity problem. Re-run later, or skip ',
        '--refresh-usmca to use the existing committed files.'
      )
    }

    code <- status_code(resp)
    if (!is_retryable_http_status(code) || attempt > max_retries) return(resp)

    wait <- base_wait * 2^(attempt - 1L)
    message('  (HTTP ', code, http_status_hint(code), '; backing off ', wait,
            's, attempt ', attempt, '/', max_retries, ')')
    Sys.sleep(wait)
  }

  stop('Unexpected retry-loop exit in post_runreport()')
}

#' Execute a DataWeb API query and parse results
#' @return tibble with hts10, country, value columns
run_query <- function(query, token) {
  # auto_unbox = TRUE: DataWeb rejects one-element-array scalars with a 503
  # "Site under maintenance" page, so scalars must go on the wire as scalars.
  resp <- post_runreport(query, token)

  if (status_code(resp) != 200) {
    stop(format_http_error(resp))
  }

  result <- content(resp, as = 'parsed', simplifyVector = FALSE)

  # Check for errors
  errors <- result$dto$errors
  if (length(errors) > 0) {
    stop('DataWeb API error: ', paste(errors, collapse = '; '))
  }

  tables <- result$dto$tables
  if (length(tables) == 0) return(tibble(hts10 = character(), country = character(), value = numeric()))

  # Parse rows: each row has [hts, country, description, value]
  rows <- tables[[1]]$row_groups[[1]]$rowsNew
  if (length(rows) == 0) return(tibble(hts10 = character(), country = character(), value = numeric()))

  map_df(rows, function(r) {
    entries <- r$rowEntries
    # Columns: HTS Number, Country, Description, <year>
    tibble(
      hts10 = entries[[1]]$value,
      country = entries[[2]]$value,
      value = as.numeric(gsub(',', '', entries[[length(entries)]]$value))
    )
  })
}

#' Execute a DataWeb API query with monthly breakdown and parse results
#' @return tibble with month, hts10, country, value columns
run_query_monthly <- function(query, token) {
  resp <- post_runreport(query, token)

  if (status_code(resp) != 200) {
    stop(format_http_error(resp))
  }

  result <- content(resp, as = 'parsed', simplifyVector = FALSE)
  errors <- result$dto$errors
  if (length(errors) > 0) {
    stop('DataWeb API error: ', paste(errors, collapse = '; '))
  }

  tables <- result$dto$tables
  empty_monthly <- tibble(month = integer(), hts10 = character(),
                          country = character(), value = numeric())
  if (length(tables) == 0) return(empty_monthly)

  month_names <- c('January' = 1L, 'February' = 2L, 'March' = 3L, 'April' = 4L,
                    'May' = 5L, 'June' = 6L, 'July' = 7L, 'August' = 8L,
                    'September' = 9L, 'October' = 10L, 'November' = 11L, 'December' = 12L)

  # DataWeb returns two different shapes for monthly queries:
  #   (a) fullYears + yearsTimeline=Monthly: one table per month, month in tableTitle
  #   (b) specificDateRange + yearsTimeline=Monthly (YTD): one table with a value
  #       column per month, labels in column_groups[[2]]$columns[*]$label
  month_value_cols <- function(tbl) {
    cg <- tbl$column_groups
    if (length(cg) < 2) return(NULL)
    labels <- vapply(cg[[2]]$columns,
                     function(col) col$label %||% NA_character_,
                     character(1))
    months <- month_names[labels]
    if (!any(!is.na(months))) return(NULL)
    months
  }

  # Locate the "Country" column by value rather than fixed position. Around
  # 2026-04 DataWeb began inserting an extra "Year" column at position [[2]]
  # for monthly queries (pushing Country to [[3]]); column ordering may shift
  # again. Searching for "Canada"/"Mexico" in non-value entries is robust.
  find_country_idx <- function(entries, value_start) {
    header <- entries[seq_len(value_start - 1)]
    idx <- which(vapply(header,
                        function(e) (e$value %||% '') %in% c('Canada', 'Mexico'),
                        logical(1)))
    if (length(idx) == 0) NA_integer_ else idx[[1]]
  }

  parse_table <- function(tbl) {
    rows <- tbl$row_groups[[1]]$rowsNew
    if (length(rows) == 0) return(empty_monthly)

    value_months <- month_value_cols(tbl)
    if (!is.null(value_months)) {
      n_val <- length(value_months)
      map_df(rows, function(r) {
        entries <- r$rowEntries
        n <- length(entries)
        value_start <- n - n_val + 1
        cty_idx <- find_country_idx(entries, value_start)
        if (is.na(cty_idx)) return(empty_monthly)
        hts10 <- entries[[1]]$value
        country <- entries[[cty_idx]]$value
        value_entries <- entries[value_start:n]
        map_df(seq_along(value_entries), function(j) {
          month_num <- value_months[[j]]
          if (is.na(month_num)) return(empty_monthly)
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
      month_num <- month_names[month_word]
      if (is.na(month_num)) return(empty_monthly)
      map_df(rows, function(r) {
        entries <- r$rowEntries
        n <- length(entries)
        cty_idx <- find_country_idx(entries, n)  # value is the last entry
        if (is.na(cty_idx)) return(empty_monthly)
        tibble(
          month = unname(month_num),
          hts10 = entries[[1]]$value,
          country = entries[[cty_idx]]$value,
          value = as.numeric(gsub(',', '', entries[[n]]$value))
        )
      })
    }
  }

  map_df(tables, parse_table)
}

# =============================================================================
# Download data: chapter-by-chapter to stay under 20K row limit
# =============================================================================

# Batch chapters (most chapters have <500 HTS10 products per country)
# Use batches of 5 chapters to be safe
batch_chapters <- function(chapters, batch_size = 5) {
  split(chapters, ceiling(seq_along(chapters) / batch_size))
}

countries <- c(CTY_CANADA, CTY_MEXICO)
chapter_batches <- batch_chapters(ALL_CHAPTERS, batch_size = 5)
rate_limit_sec <- if (run_monthly) 2.0 else 0.5

query_fn <- if (run_monthly) run_query_monthly else run_query

message('\nDownloading USMCA imports (programs S/S+) by HTS10...')
message('  ', length(chapter_batches), ' chapter batches x 2 countries')

usmca_records <- map_df(seq_along(chapter_batches), function(i) {
  chapters <- chapter_batches[[i]]
  ch_label <- paste0('ch', chapters[1], '-', chapters[length(chapters)])

  q <- build_query(chapters, countries, programs = USMCA_PROGRAMS, year = year,
                    monthly = run_monthly)
  result <- query_fn(q, token)

  if (nrow(result) > 0) {
    message('  [', i, '/', length(chapter_batches), '] ', ch_label,
            ': ', nrow(result), ' records')
  } else {
    message('  [', i, '/', length(chapter_batches), '] ', ch_label, ': 0 records')
  }

  Sys.sleep(rate_limit_sec)
  result
})

message('\n  USMCA records: ', nrow(usmca_records))

message('\nDownloading total imports by HTS10...')
total_records <- map_df(seq_along(chapter_batches), function(i) {
  chapters <- chapter_batches[[i]]
  ch_label <- paste0('ch', chapters[1], '-', chapters[length(chapters)])

  q <- build_query(chapters, countries, programs = NULL, year = year,
                    monthly = run_monthly)
  result <- query_fn(q, token)

  if (nrow(result) > 0) {
    message('  [', i, '/', length(chapter_batches), '] ', ch_label,
            ': ', nrow(result), ' records')
  } else {
    message('  [', i, '/', length(chapter_batches), '] ', ch_label, ': 0 records')
  }

  Sys.sleep(rate_limit_sec)
  result
})

message('\n  Total records: ', nrow(total_records))

if (nrow(total_records) == 0) {
  stop('DataWeb returned 0 total-import records across all ', length(chapter_batches),
       ' chapter batches for year ', year, '. Refusing to overwrite USMCA shares ',
       'with an empty dataset. Likely cause: DataWeb maintenance or token expiry. ',
       'Re-run later, or skip --refresh-usmca to use existing files.')
}
if (nrow(usmca_records) == 0) {
  warning('DataWeb returned 0 USMCA-program records — all shares will be 0. ',
          'Verify this is expected for year ', year, ' before overwriting output.')
}

# =============================================================================
# Compute product-level shares
# =============================================================================

# Map country names to codes
country_map <- c('Canada' = CTY_CANADA, 'Mexico' = CTY_MEXICO)

# Group columns depend on mode
group_cols <- if (run_monthly) c('month', 'hts10', 'cty_code') else c('hts10', 'cty_code')

total_clean <- total_records %>%
  mutate(cty_code = country_map[country]) %>%
  filter(!is.na(cty_code)) %>%
  group_by(across(all_of(group_cols))) %>%
  summarise(total_value = sum(value, na.rm = TRUE), .groups = 'drop')

usmca_clean <- usmca_records %>%
  mutate(cty_code = country_map[country]) %>%
  filter(!is.na(cty_code)) %>%
  group_by(across(all_of(group_cols))) %>%
  summarise(usmca_value = sum(value, na.rm = TRUE), .groups = 'drop')

product_shares <- total_clean %>%
  left_join(usmca_clean, by = group_cols) %>%
  mutate(
    usmca_value = replace_na(usmca_value, 0),
    usmca_share = if_else(total_value > 0, usmca_value / total_value, 0)
  )

# --- Summary statistics ---
mode_label <- if (run_monthly) 'monthly' else 'annual'
message('\nProduct-level USMCA shares (DataWeb SPI S/S+, year = ', year, ', ', mode_label, '):')
message('  Total product-country pairs: ', nrow(product_shares))
message('  CA products: ', sum(product_shares$cty_code == CTY_CANADA))
message('  MX products: ', sum(product_shares$cty_code == CTY_MEXICO))

if (run_monthly) {
  # Monthly summary: aggregate shares by month and country
  monthly_summary <- product_shares %>%
    group_by(month, cty_code) %>%
    summarise(
      total_value = sum(total_value),
      usmca_value = sum(usmca_value),
      overall_share = usmca_value / total_value,
      n_products = n(),
      .groups = 'drop'
    ) %>%
    arrange(month, cty_code)
  message('\n  Monthly aggregate shares:')
  print(monthly_summary, n = 30)
} else {
  summary_by_country <- product_shares %>%
    group_by(cty_code) %>%
    summarise(
      total_value = sum(total_value),
      usmca_value = sum(usmca_value),
      overall_share = usmca_value / total_value,
      n_products = n(),
      n_with_usmca = sum(usmca_share > 0),
      n_full_usmca = sum(usmca_share > 0.99),
      n_zero_usmca = sum(usmca_share == 0),
      .groups = 'drop'
    )

  message('\n  Overall value shares:')
  print(summary_by_country)

  message('\n  Share distribution (CA):')
  ca_shares <- product_shares$usmca_share[product_shares$cty_code == CTY_CANADA]
  print(summary(ca_shares))
  message('  Share distribution (MX):')
  mx_shares <- product_shares$usmca_share[product_shares$cty_code == CTY_MEXICO]
  print(summary(mx_shares))

  message('\n  Share deciles (CA):')
  print(quantile(ca_shares, probs = seq(0, 1, 0.1)))
  message('  Share deciles (MX):')
  print(quantile(mx_shares, probs = seq(0, 1, 0.1)))
}

# --- Save ---
if (run_monthly) {
  # Save per-month files with value columns for proper aggregation.
  # Skip months where DataWeb returned no trade data (sum(total_value) == 0):
  # writing such ghost files would let the monthly-mode loader silently zero
  # out USMCA exemptions for any effective_date that falls in the unreleased
  # month.
  months_available <- sort(unique(product_shares$month))
  for (m in months_available) {
    month_data <- product_shares %>%
      filter(month == m) %>%
      select(hts10, cty_code, usmca_share, total_value, usmca_value) %>%
      arrange(hts10, cty_code)

    stopifnot(!anyNA(month_data$usmca_share))
    stopifnot(all(month_data$usmca_share >= 0 & month_data$usmca_share <= 1))

    if (sum(month_data$total_value) == 0) {
      message('  Skipped month ', sprintf('%02d', m),
              ': DataWeb returned no trade data (likely not yet released)')
      next
    }

    month_path <- here('resources', sprintf('usmca_product_shares_%d_%02d.csv', year, m))
    write_csv(month_data, month_path)
    message('  Saved month ', sprintf('%02d', m), ': ', nrow(month_data),
            ' pairs to ', basename(month_path))
  }

  # Save combined diagnostic file (with value columns for noise analysis)
  diag_path <- here('resources', paste0('usmca_product_shares_', year, '_monthly_diagnostic.csv'))
  diag_out <- product_shares %>%
    select(month, hts10, cty_code, usmca_share, total_value, usmca_value) %>%
    arrange(month, hts10, cty_code)
  write_csv(diag_out, diag_path)
  message('\nSaved diagnostic file: ', basename(diag_path), ' (', nrow(diag_out), ' rows)')
  message('Data year: ', year, ' | Source: USITC DataWeb (SPI programs S/S+) | Mode: monthly')

} else {
  out <- product_shares %>%
    select(hts10, cty_code, usmca_share) %>%
    arrange(hts10, cty_code)

  stopifnot(!anyNA(out$usmca_share))
  stopifnot(all(out$usmca_share >= 0 & out$usmca_share <= 1))

  out_path <- here('resources', paste0('usmca_product_shares_', year, '.csv'))
  write_csv(out, out_path)
  message('\nSaved ', nrow(out), ' product-country pairs to: ', out_path)
  message('Data year: ', year, ' | Source: USITC DataWeb (SPI programs S/S+)')

  # Also copy to the default path for backward compatibility
  default_path <- here('resources', 'usmca_product_shares.csv')
  write_csv(out, default_path)
  message('Also saved to: ', default_path)
}
