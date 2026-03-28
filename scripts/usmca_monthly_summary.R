#!/usr/bin/env Rscript
# Quick script: compute aggregate USMCA share by month for 2025
# Uses DataWeb API with monthly breakdown (not product-level, just totals)

library(tidyverse)
library(here)
library(jsonlite)
library(httr)

DATAWEB_BASE <- 'https://datawebws.usitc.gov/dataweb'
CTY_CANADA <- '1220'
CTY_MEXICO <- '2010'
USMCA_PROGRAMS <- c('S', 'S+')
MEASURE <- 'CONS_CUSTOMS_VALUE'

# Load token
env_file <- here('.env')
lines <- readLines(env_file, warn = FALSE)
token <- sub('^DATAWEB_API_TOKEN=', '', grep('^DATAWEB_API_TOKEN=', lines, value = TRUE)[1])

countries <- c(CTY_CANADA, CTY_MEXICO)
year <- 2025L

# Build query with monthly breakdown (aggregate all commodities)
build_monthly_query <- function(countries, programs = NULL, year) {
  ext_programs <- if (!is.null(programs)) {
    list(aggregation = 'Aggregate CSC', extImportPrograms = as.list(programs),
         extImportProgramsExpanded = list(), programsSelectType = 'list')
  } else {
    list(aggregation = 'Aggregate CSC', extImportPrograms = list(),
         extImportProgramsExpanded = list(), programsSelectType = 'all')
  }

  list(
    savedQueryName = '', savedQueryDesc = '', isOwner = TRUE,
    runMonthly = TRUE,
    reportOptions = list(tradeType = 'Import', classificationSystem = 'HTS'),
    searchOptions = list(
      MiscGroup = list(
        districts = list(aggregation = 'Aggregate District', districtGroups = list(userGroups = list()),
                         districts = list(), districtsExpanded = list(list(name = 'All Districts', value = 'all')),
                         districtsSelectType = 'all'),
        importPrograms = list(aggregation = jsonlite::unbox(NA), importPrograms = list(), programsSelectType = 'all'),
        extImportPrograms = ext_programs,
        provisionCodes = list(aggregation = 'Aggregate RPCODE', provisionCodesSelectType = 'all',
                              rateProvisionCodes = list(), rateProvisionCodesExpanded = list())
      ),
      commodities = list(
        aggregation = 'Aggregate Commodities',
        codeDisplayFormat = 'YES', commodities = list(),
        commoditiesExpanded = list(), commoditiesManual = '',
        commodityGroups = list(systemGroups = list(), userGroups = list()),
        commoditySelectType = 'all', granularity = '2',
        groupGranularity = jsonlite::unbox(NA), searchGranularity = jsonlite::unbox(NA)
      ),
      componentSettings = list(
        dataToReport = list(MEASURE), scale = '1',
        timeframeSelectType = 'fullYears',
        years = list(as.character(year)),
        startDate = jsonlite::unbox(NA), endDate = jsonlite::unbox(NA),
        startMonth = jsonlite::unbox(NA), endMonth = jsonlite::unbox(NA),
        yearsTimeline = 'Monthly'
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
      DataSort = list(columnOrder = list(), fullColumnOrder = list(), sortOrder = list()),
      reportCustomizations = list(exportCombineTables = FALSE, showAllSubtotal = TRUE,
                                  subtotalRecords = '', totalRecords = '20000', exportRawData = FALSE)
    )
  )
}

run_query <- function(query, token) {
  resp <- POST(
    url = paste0(DATAWEB_BASE, '/api/v2/report2/runReport'),
    add_headers('Content-Type' = 'application/json; charset=utf-8',
                'Authorization' = paste('Bearer', token)),
    body = toJSON(query, auto_unbox = FALSE, null = 'null'),
    encode = 'raw'
  )
  if (status_code(resp) != 200) {
    warning('API returned status ', status_code(resp))
    return(tibble())
  }
  result <- content(resp, as = 'parsed', simplifyVector = FALSE)
  tables <- result$dto$tables
  if (length(tables) == 0) return(tibble())

  # Monthly data: each table is a month, rows are countries
  map_df(seq_along(tables), function(ti) {
    tbl <- tables[[ti]]
    month_label <- tbl$tableTitle  # e.g., "January 2025"
    rows <- tbl$row_groups[[1]]$rowsNew
    map_df(rows, function(r) {
      entries <- r$rowEntries
      tibble(
        month = month_label,
        country = entries[[1]]$value,
        value = as.numeric(gsub(',', '', entries[[length(entries)]]$value))
      )
    })
  })
}

message('Querying USMCA imports (S/S+) monthly...')
usmca <- run_query(build_monthly_query(countries, USMCA_PROGRAMS, year), token)
Sys.sleep(1)

message('Querying total imports monthly...')
total <- run_query(build_monthly_query(countries, NULL, year), token)

if (nrow(usmca) == 0 || nrow(total) == 0) {
  stop('No data returned from API')
}

# Join and compute shares
combined <- total %>%
  rename(total_value = value) %>%
  left_join(usmca %>% rename(usmca_value = value), by = c('month', 'country')) %>%
  mutate(
    usmca_value = replace_na(usmca_value, 0),
    share = usmca_value / total_value
  )

cat('\n=== Monthly USMCA Shares, 2025 ===\n\n')

# Overall by month
overall <- combined %>%
  group_by(month) %>%
  summarise(total = sum(total_value), usmca = sum(usmca_value), .groups = 'drop') %>%
  mutate(share = usmca / total)

for (i in seq_len(nrow(overall))) {
  r <- overall[i,]
  cat(sprintf('%-20s  Overall: %5.1f%%  ($%5.1fB / $%5.1fB)\n',
              r$month, r$share * 100, r$usmca / 1e6, r$total / 1e6))
}

cat('\n--- By country ---\n')
for (i in seq_len(nrow(combined))) {
  r <- combined[i,]
  cat(sprintf('%-20s  %-8s  %5.1f%%\n', r$month, r$country, r$share * 100))
}
