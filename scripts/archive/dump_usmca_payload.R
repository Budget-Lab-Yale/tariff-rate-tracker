#!/usr/bin/env Rscript
# Builds the exact JSON payload the failing USMCA DataWeb call sends
# and writes it to a file so curl can replay the identical bytes.

suppressPackageStartupMessages({
  library(here)
  library(jsonlite)
})

# Source the builder functions (but skip the script-body execution).
# We just re-inline the pieces we need to stay self-contained.

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
    startMonth = jsonlite::unbox(NA),
    endMonth = jsonlite::unbox(NA),
    yearsTimeline = if (monthly) 'Monthly' else 'Annual'
  )
}

build_component_settings_full <- function(year, monthly) {
  list(
    dataToReport = list(MEASURE),
    scale = '1',
    timeframeSelectType = 'fullYears',
    years = list(as.character(year)),
    startDate = jsonlite::unbox(NA),
    endDate = jsonlite::unbox(NA),
    startMonth = jsonlite::unbox(NA),
    endMonth = jsonlite::unbox(NA),
    yearsTimeline = if (monthly) 'Monthly' else 'Annual'
  )
}

build_query <- function(chapters, countries, programs, component_settings, monthly) {
  ext_programs <- if (!is.null(programs)) {
    list(
      aggregation = 'Aggregate CSC',
      extImportPrograms = as.list(programs),
      extImportProgramsExpanded = list(),
      programsSelectType = 'list'
    )
  } else {
    list(
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

# Case A: 2026 YTD Monthly, end 02/2026 (the failing case)
qA <- build_query(
  chapters, countries, USMCA_PROGRAMS,
  build_component_settings_ytd(2026, 2, monthly = TRUE),
  monthly = TRUE
)
writeLines(
  toJSON(qA, auto_unbox = FALSE, null = 'null'),
  here::here('scripts', 'payload_2026_ytd_feb_monthly.json')
)

# Case B: 2025 full-year Annual (the known-working control)
qB <- build_query(
  chapters, countries, USMCA_PROGRAMS,
  build_component_settings_full(2025, monthly = FALSE),
  monthly = FALSE
)
writeLines(
  toJSON(qB, auto_unbox = FALSE, null = 'null'),
  here::here('scripts', 'payload_2025_full_annual.json')
)

# Case C: 2026 full-year Annual (the originally-failing case)
qC <- build_query(
  chapters, countries, USMCA_PROGRAMS,
  build_component_settings_full(2026, monthly = FALSE),
  monthly = FALSE
)
writeLines(
  toJSON(qC, auto_unbox = FALSE, null = 'null'),
  here::here('scripts', 'payload_2026_full_annual.json')
)

cat('Wrote payloads.\n')
