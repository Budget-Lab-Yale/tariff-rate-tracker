#!/usr/bin/env Rscript
# =============================================================================
# Probe USITC DataWeb for subdivision (r) certified_share calibration signal
# =============================================================================
#
# Investigates how much directional information DataWeb can give us about the
# share of EU/JP/KR auto-parts imports that are filed under 9903.94.45/.55/.65
# (Note 33(r) certified-for-US-production deal at 15% floor) vs the metals
# annex 9903.82.02/.04-.19 (25% under annex_1b).
#
# **Key finding (2026-05-02):** DataWeb does NOT support filtering by chapter 99
# line. Its `rateProvisionCodes` field accepts 2-digit RP categories (Free
# bonded warehouse, Free Chapter 99, Dutiable Chapter 99, etc.) — not the
# 9903.xx.xx specific entries. Direct calibration of certified_share from
# DataWeb is not possible.
#
# **What DataWeb DOES expose:** Special Program Indicator (SPI) codes via
# `extImportPrograms`. Notable codes for our target countries:
#   - SPI=KR  (KORUS FTA)
#   - SPI=JP  (US-Japan Trade Agreement, EO 14345)
#   - No SPI specifically for the EU auto-parts deal
#
# Per Note 33(r), goods qualifying under EO 14345 or KORUS FTA are EXEMPT from
# the 9903.94.44/.45/.54/.55/.64/.65 additional duty (line 35836-35837 of the
# rev_6 chapter 99 text). So SPI=KR/JP utilization is upstream of the
# subdivision (r) certification question — it tells us how much trade is
# exempt entirely, not how much of the remainder is certified vs annex.
#
# This script outputs SPI utilization rates on the subdivision (r) target HTS10s
# as a directional signal. It does NOT compute certified_share. For
# calibration, see `docs/s232/subdivision_r_calibration.md` for proposed
# alternative sources (industry estimates, CBP CSMS, sensitivity range).
#
# Usage:
#   Rscript src/download_subdivision_r_share.R                   # 2025 + 2026
#   Rscript src/download_subdivision_r_share.R --year 2025
#   Rscript src/download_subdivision_r_share.R --env-file PATH
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
  library(httr)
  library(jsonlite)
})

source(here('src', 'dataweb_parser.R'))

DATAWEB_BASE <- 'https://datawebws.usitc.gov/dataweb'

# Subdivision (r) target list comes from build_subdivision_r_products.R.
# Currently 8 prefixes in chapter 87 auto parts (8706 / 8708).
SUBDIV_R_PATH <- here('resources', 's232_subdivision_r_products.csv')

EU_CODES <- c('4280','4279','4759','4700','4210','4231','4239','4870','4791',
              '4910','4351','4099','4470','4050','4840','4370','4190','4490',
              '4510','4730','4550','4710','4850','4359','4792','4010','4330')
JP_CODE <- '5880'
KR_CODE <- '5800'

# --- CLI args ---
args <- commandArgs(trailingOnly = TRUE)
years <- if ('--year' %in% args) {
  as.integer(args[which(args == '--year') + 1])
} else {
  c(2025L, 2026L)
}
env_file <- if ('--env-file' %in% args) {
  args[which(args == '--env-file') + 1]
} else {
  here('.env')
}

# --- Auth ---
load_token <- function(env_file) {
  if (!file.exists(env_file)) {
    stop('Token file not found: ', env_file)
  }
  lines <- readLines(env_file, warn = FALSE)
  token_line <- grep('^DATAWEB_API_TOKEN=', lines, value = TRUE)
  if (length(token_line) == 0) stop('DATAWEB_API_TOKEN not found in ', env_file)
  trimws(sub('^DATAWEB_API_TOKEN=', '', token_line[1]))
}
token <- load_token(env_file)

# --- Build query ---
build_q <- function(programs, year, country) {
  ext_progs <- if (is.null(programs)) {
    list(aggregation = 'Aggregate CSC',
         extImportPrograms = list(),
         extImportProgramsExpanded = list(),
         programsSelectType = 'all')
  } else {
    list(aggregation = 'Aggregate CSC',
         extImportPrograms = as.list(programs),
         extImportProgramsExpanded = lapply(programs,
           function(p) list(name = p, value = p)),
         programsSelectType = 'list')
  }
  list(savedQueryName = '', savedQueryDesc = '', isOwner = TRUE,
       runMonthly = FALSE,
       reportOptions = list(tradeType = 'Import', classificationSystem = 'HTS'),
       searchOptions = list(
         MiscGroup = list(
           districts = list(aggregation = 'Aggregate District',
             districtGroups = list(userGroups = list()),
             districts = list(),
             districtsExpanded = list(list(name = 'All Districts', value = 'all')),
             districtsSelectType = 'all'),
           importPrograms = list(aggregation = jsonlite::unbox(NA),
             importPrograms = list(), programsSelectType = 'all'),
           extImportPrograms = ext_progs,
           provisionCodes = list(aggregation = 'Aggregate RPCODE',
             provisionCodesSelectType = 'all',
             rateProvisionCodes = list(),
             rateProvisionCodesExpanded = list())),
         commodities = list(aggregation = 'Break Out Commodities',
           codeDisplayFormat = 'YES',
           commodities = list('87'),
           commoditiesExpanded = list(),
           commoditiesManual = '',
           commodityGroups = list(systemGroups = list(), userGroups = list()),
           commoditySelectType = 'list', granularity = '10',
           groupGranularity = jsonlite::unbox(NA),
           searchGranularity = jsonlite::unbox(NA)),
         componentSettings = list(dataToReport = list('CONS_CUSTOMS_VALUE'),
           scale = '1', timeframeSelectType = 'fullYears',
           years = list(as.character(year)),
           startDate = jsonlite::unbox(NA), endDate = jsonlite::unbox(NA),
           startMonth = jsonlite::unbox(NA), endMonth = jsonlite::unbox(NA),
           yearsTimeline = 'Annual'),
         countries = list(aggregation = 'Break Out Countries',
           countries = list(country),
           countriesExpanded = list(list(name = country, value = country)),
           countriesSelectType = 'list',
           countryGroups = list(systemGroups = list(), userGroups = list()))),
       sortingAndDataFormat = list(
         DataSort = list(columnOrder = list(),
           fullColumnOrder = list(), sortOrder = list()),
         reportCustomizations = list(exportCombineTables = FALSE,
           showAllSubtotal = TRUE, subtotalRecords = '',
           totalRecords = '20000', exportRawData = FALSE)))
}

run_q <- function(q) {
  body <- toJSON(q, auto_unbox = TRUE, null = 'null', na = 'null')
  resp <- POST(paste0(DATAWEB_BASE, '/api/v2/report2/runReport'),
    add_headers('Content-Type' = 'application/json; charset=utf-8',
      'Authorization' = paste('Bearer', token)),
    timeout(60), body = body, encode = 'raw')
  if (status_code(resp) != 200) {
    warning('HTTP ', status_code(resp), ' for query')
    return(tibble(hts10 = character(), country = character(), value = numeric()))
  }
  parsed <- content(resp, as = 'parsed', simplifyVector = FALSE)
  if (is.null(parsed$dto) || length(parsed$dto$tables) == 0) {
    return(tibble(hts10 = character(), country = character(), value = numeric()))
  }
  rows <- parsed$dto$tables[[1]]$row_groups[[1]]$rowsNew
  if (length(rows) == 0) {
    return(tibble(hts10 = character(), country = character(), value = numeric()))
  }
  map_df(rows, function(r) {
    e <- r$rowEntries; n <- length(e)
    tibble(hts10 = e[[1]]$value,
           country = e[[2]]$value,
           value = as.numeric(gsub(',', '', e[[n]]$value)))
  })
}

# --- Probe ---
subdiv_r <- read_csv(SUBDIV_R_PATH, col_types = cols(.default = col_character()))
subdiv_r_pat <- paste0('^(', paste(unique(subdiv_r$hts_prefix), collapse = '|'), ')')

probe <- function(country_code, country_label, year,
                  spi_codes = NULL, spi_label = 'no SPI filter') {
  q <- build_q(spi_codes, year, country_code)
  res <- run_q(q)
  total_all <- sum(res$value, na.rm = TRUE)
  total_r <- if (nrow(res) > 0) {
    sum(res %>% filter(grepl(subdiv_r_pat, hts10)) %>% pull(value), na.rm = TRUE)
  } else 0
  Sys.sleep(2)
  tibble(country = country_label, year = year, spi = spi_label,
         total_ch87_M = total_all / 1e6,
         subdiv_r_M   = total_r / 1e6)
}

records <- list()
for (yr in years) {
  message('Probing year ', yr, '...')
  records[[paste0('JP_total_', yr)]] <- probe(JP_CODE, 'Japan', yr, NULL, 'all')
  records[[paste0('JP_spi_', yr)]]   <- probe(JP_CODE, 'Japan', yr, c('JP'), 'SPI=JP')
  records[[paste0('KR_total_', yr)]] <- probe(KR_CODE, 'Korea', yr, NULL, 'all')
  records[[paste0('KR_spi_', yr)]]   <- probe(KR_CODE, 'Korea', yr, c('KR'), 'SPI=KR')
  # EU: probe Germany + Italy as the two largest auto-parts exporters
  records[[paste0('DE_total_', yr)]] <- probe('4280', 'Germany', yr, NULL, 'all')
  records[[paste0('IT_total_', yr)]] <- probe('4759', 'Italy',   yr, NULL, 'all')
}

result <- bind_rows(records) %>%
  group_by(country, year) %>%
  mutate(
    spi_share_subdiv_r = if_else(spi == 'all', NA_real_,
      subdiv_r_M / max(subdiv_r_M[spi == 'all'], 1e-9)),
    spi_share_ch87 = if_else(spi == 'all', NA_real_,
      total_ch87_M / max(total_ch87_M[spi == 'all'], 1e-9))
  ) %>%
  ungroup()

out_path <- here('resources', 'subdivision_r_dataweb_signal.csv')
write_csv(result, out_path)
message('\nWrote ', out_path)

cat('\n== SPI utilization on subdivision (r) products ==\n')
result %>%
  select(country, year, spi, total_ch87_M, subdiv_r_M,
         spi_share_subdiv_r, spi_share_ch87) %>%
  mutate(across(c(total_ch87_M, subdiv_r_M),
                ~ format(round(.), big.mark = ','))) %>%
  print(n = Inf)

cat('\n--\n')
cat('IMPORTANT: SPI=JP / SPI=KR captures *FTA-qualifying trade*. Note 33(r)\n')
cat('exempts FTA-qualifying goods from the 9903.94.44/.45/.54/.55/.64/.65\n')
cat('additional duty entirely. So SPI utilization is upstream of certified_share:\n')
cat('  - SPI-claimed share -> exempt from deal additional duty (rate ~ MFN base)\n')
cat('  - non-SPI share     -> may file under 9903.94.45 (15% floor, certified)\n')
cat('                          or fall under 9903.82.x annex_1b (25% metals)\n')
cat('DataWeb cannot disambiguate the non-SPI slice. Use industry estimates or\n')
cat('CBP CSMS bulletins for certified_share calibration.\n')
