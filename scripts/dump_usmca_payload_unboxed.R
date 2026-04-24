#!/usr/bin/env Rscript
# Same payloads as dump_usmca_payload.R but with auto_unbox = TRUE so scalar
# strings/numbers/logicals go on the wire as scalars, like a typical python
# requests.post(..., json=...) call produces.

suppressPackageStartupMessages({
  library(here)
  library(jsonlite)
})

DATAWEB_BASE <- 'https://datawebws.usitc.gov/dataweb'
CTY_CANADA <- '1220'
CTY_MEXICO <- '2010'
USMCA_PROGRAMS <- c('S', 'S+')
MEASURE <- 'CONS_CUSTOMS_VALUE'

build_component_settings_ytd <- function(year, end_month, monthly) {
  list(
    dataToReport = list(MEASURE),
    scale = '1',
    timeframeSelectType = 'specificDateRange',
    years = list(as.character(year)),
    startDate = sprintf('01/%d', year),
    endDate = sprintf('%02d/%d', end_month, year),
    startMonth = NA,
    endMonth = NA,
    yearsTimeline = if (monthly) 'Monthly' else 'Annual'
  )
}

build_query <- function(chapters, countries, programs, component_settings, monthly) {
  ext_programs <- list(
    aggregation = 'Aggregate CSC',
    extImportPrograms = as.list(programs),
    extImportProgramsExpanded = list(),
    programsSelectType = 'list'
  )
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
          aggregation = NA,
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
        groupGranularity = NA,
        searchGranularity = NA
      ),
      componentSettings = component_settings,
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

chapters <- c('01','02','03','04','05')
countries <- c(CTY_CANADA, CTY_MEXICO)

qA <- build_query(chapters, countries, USMCA_PROGRAMS,
                  build_component_settings_ytd(2026, 2, monthly = TRUE),
                  monthly = TRUE)
writeLines(
  toJSON(qA, auto_unbox = TRUE, null = 'null', na = 'null'),
  here::here('scripts', 'payload_2026_ytd_feb_monthly_unboxed.json')
)
cat('Wrote unboxed payload.\n')
