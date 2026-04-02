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
  sub('^DATAWEB_API_TOKEN=', '', token_line[1])
}

token <- load_token(env_file)
message('USITC DataWeb USMCA share download')
message('  Year: ', year)
message('  Mode: ', if (run_monthly) 'monthly' else 'annual')
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
      componentSettings = list(
        dataToReport = list(MEASURE),
        scale = '1',
        timeframeSelectType = 'fullYears',
        years = list(as.character(year)),
        startDate = jsonlite::unbox(NA),
        endDate = jsonlite::unbox(NA),
        startMonth = jsonlite::unbox(NA),
        endMonth = jsonlite::unbox(NA),
        yearsTimeline = if (monthly) 'Monthly' else 'Annual'
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

#' Execute a DataWeb API query and parse results
#' @return tibble with hts10, country, value columns
run_query <- function(query, token) {
  resp <- POST(
    url = paste0(DATAWEB_BASE, '/api/v2/report2/runReport'),
    add_headers(
      'Content-Type' = 'application/json; charset=utf-8',
      'Authorization' = paste('Bearer', token)
    ),
    body = toJSON(query, auto_unbox = FALSE, null = 'null'),
    encode = 'raw'
  )

  if (status_code(resp) != 200) {
    warning('API returned status ', status_code(resp))
    return(tibble())
  }

  result <- content(resp, as = 'parsed', simplifyVector = FALSE)

  # Check for errors
  errors <- result$dto$errors
  if (length(errors) > 0) {
    warning('API error: ', paste(errors, collapse = '; '))
    return(tibble())
  }

  tables <- result$dto$tables
  if (length(tables) == 0) return(tibble())

  # Parse rows: each row has [hts, country, description, value]
  rows <- tables[[1]]$row_groups[[1]]$rowsNew
  if (length(rows) == 0) return(tibble())

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
  resp <- POST(
    url = paste0(DATAWEB_BASE, '/api/v2/report2/runReport'),
    add_headers(
      'Content-Type' = 'application/json; charset=utf-8',
      'Authorization' = paste('Bearer', token)
    ),
    body = toJSON(query, auto_unbox = FALSE, null = 'null'),
    encode = 'raw'
  )

  if (status_code(resp) != 200) {
    warning('API returned status ', status_code(resp))
    return(tibble())
  }

  result <- content(resp, as = 'parsed', simplifyVector = FALSE)
  errors <- result$dto$errors
  if (length(errors) > 0) {
    warning('API error: ', paste(errors, collapse = '; '))
    return(tibble())
  }

  tables <- result$dto$tables
  if (length(tables) == 0) return(tibble())

  # Each table is one month; parse month from tableTitle (e.g., "January 2025")
  month_names <- c('January' = 1L, 'February' = 2L, 'March' = 3L, 'April' = 4L,
                    'May' = 5L, 'June' = 6L, 'July' = 7L, 'August' = 8L,
                    'September' = 9L, 'October' = 10L, 'November' = 11L, 'December' = 12L)

  map_df(tables, function(tbl) {
    title <- tbl$tableTitle %||% ''
    month_word <- sub(' .*', '', title)
    month_num <- month_names[month_word]
    if (is.na(month_num)) return(tibble())

    rows <- tbl$row_groups[[1]]$rowsNew
    if (length(rows) == 0) return(tibble())

    map_df(rows, function(r) {
      entries <- r$rowEntries
      tibble(
        month = month_num,
        hts10 = entries[[1]]$value,
        country = entries[[2]]$value,
        value = as.numeric(gsub(',', '', entries[[length(entries)]]$value))
      )
    })
  })
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
rate_limit_sec <- if (run_monthly) 1.0 else 0.5

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
  # Save per-month files (same schema as annual: hts10, cty_code, usmca_share)
  months_available <- sort(unique(product_shares$month))
  for (m in months_available) {
    month_data <- product_shares %>%
      filter(month == m) %>%
      select(hts10, cty_code, usmca_share) %>%
      arrange(hts10, cty_code)

    stopifnot(!anyNA(month_data$usmca_share))
    stopifnot(all(month_data$usmca_share >= 0 & month_data$usmca_share <= 1))

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
