# =============================================================================
# Policy Parameters — YAML config loader and country constants
# =============================================================================
# Split from helpers.R. Sourced by helpers.R for backward compatibility.
# Direct consumers can source this file alone.

library(tidyverse)
library(yaml)
library(here)

#' Load policy parameters from YAML config
#'
#' Returns a list with convenience fields unpacked for direct use.
#'
#' @param yaml_path Path to policy_params.yaml
#' @param use_policy_dates If TRUE (default), swap date-sensitive config fields
#'   (IEEPA invalidation, S122 effective/expiry) to their policy_effective_date
#'   equivalents. Set FALSE when using --use-hts-dates or for utilities that
#'   need raw HTS timing. See docs/policy_timing.md.
#' @return List with raw params plus convenience fields
load_policy_params <- function(yaml_path = here('config', 'policy_params.yaml'),
                               use_policy_dates = TRUE) {
  if (!file.exists(yaml_path)) {
    stop('Policy params YAML not found: ', yaml_path)
  }

  params <- read_yaml(yaml_path)

  # Unpack convenience fields for country codes
  for (nm in names(params$country_codes)) {
    params[[nm]] <- params$country_codes[[nm]]
  }

  # ISO_TO_CENSUS as named character vector
  params$ISO_TO_CENSUS <- unlist(params$iso_to_census)

  # EU27_CODES as character vector, EU27_NAMES as named vector
  params$EU27_CODES <- names(params$eu27_codes)
  params$EU27_NAMES <- unlist(params$eu27_codes)
  names(params$EU27_NAMES) <- params$EU27_CODES

  # Section 232 chapters as flat vector
  params$SECTION_232_CHAPTERS <- unlist(params$section_232_chapters)

  # Authority columns as named vector
  params$AUTHORITY_COLUMNS <- unlist(params$authority_columns)

  # Section 301 rates as tibble
  if (!is.null(params$section_301_rates)) {
    params$SECTION_301_RATES <- tibble(
      ch99_pattern = map_chr(params$section_301_rates, 'ch99_pattern'),
      s301_rate = map_dbl(params$section_301_rates, 's301_rate')
    )
  }

  # Floor rates
  params$EU_FLOOR_RATE <- params$floor_rates$eu_floor
  params$FLOOR_RATE <- params$floor_rates$floor_rate
  params$FLOOR_COUNTRIES <- unlist(params$floor_rates$floor_countries)

  # Weighted ETR reporting config
  if (!is.null(params$weighted_etr)) {
    if (!is.null(params$weighted_etr$policy_dates)) {
      params$WEIGHTED_ETR_POLICY_DATES <- tibble(
        date = as.Date(map_chr(params$weighted_etr$policy_dates, 'date')),
        label = map_chr(params$weighted_etr$policy_dates, 'label')
      )
    }
    if (!is.null(params$weighted_etr$tpc_name_fixes)) {
      params$TPC_NAME_FIXES <- unlist(params$weighted_etr$tpc_name_fixes)
    }
  }

  # IEEPA invalidation date (SCOTUS ruling)
  if (!is.null(params$ieepa_invalidation_date)) {
    params$IEEPA_INVALIDATION_DATE <- as.Date(params$ieepa_invalidation_date)
  } else {
    params$IEEPA_INVALIDATION_DATE <- NULL
  }

  # Swiss/Liechtenstein framework (EO 14346)
  if (!is.null(params$swiss_framework)) {
    params$SWISS_FRAMEWORK <- list(
      effective_date = as.Date(params$swiss_framework$effective_date),
      expiry_date = as.Date(params$swiss_framework$expiry_date),
      finalized = isTRUE(params$swiss_framework$finalized),
      countries = unlist(params$swiss_framework$countries)
    )
  }

  # USMCA utilization shares (DataWeb SPI S/S+)
  params$USMCA_SHARES <- list(
    mode = params$usmca_shares$mode %||% 'annual',
    year = params$usmca_shares$year %||% NULL,
    month = params$usmca_shares$month %||% NULL
  )

  # MFN exemption shares (FTA/GSP preference utilization)
  if (!is.null(params$mfn_exemption)) {
    params$MFN_EXEMPTION <- list(
      method = params$mfn_exemption$method %||% 'none',
      exclude_usmca_countries = isTRUE(params$mfn_exemption$exclude_usmca_countries)
    )
  } else {
    params$MFN_EXEMPTION <- list(method = 'none', exclude_usmca_countries = TRUE)
  }

  # Section 232 country exemptions (TRQ/quota agreements)
  if (!is.null(params$section_232_country_exemptions)) {
    params$S232_COUNTRY_EXEMPTIONS <- map(params$section_232_country_exemptions, function(entry) {
      # Expand 'eu' mnemonic to EU27 codes
      raw_countries <- unlist(entry$countries)
      expanded <- if ('eu' %in% raw_countries) {
        c(setdiff(raw_countries, 'eu'), params$EU27_CODES)
      } else {
        raw_countries
      }
      list(
        countries = expanded,
        rate = entry$rate,
        applies_to = unlist(entry$applies_to),
        expiry_date = if (!is.null(entry$expiry_date)) as.Date(entry$expiry_date) else NULL
      )
    })
  } else {
    params$S232_COUNTRY_EXEMPTIONS <- list()
  }

  # Series horizon
  if (!is.null(params$series_horizon$end_date)) {
    params$SERIES_HORIZON_END <- as.Date(params$series_horizon$end_date)
  } else {
    params$SERIES_HORIZON_END <- Sys.Date()
  }

  # Section 122 (Trade Act §122, 150-day statutory limit)
  if (!is.null(params$section_122)) {
    params$SECTION_122 <- list(
      effective_date = as.Date(params$section_122$effective_date),
      expiry_date = as.Date(params$section_122$expiry_date),
      finalized = isTRUE(params$section_122$finalized)
    )
  }

  # Swap policy dates if requested (SCOTUS ruling + S122 coordination)
  if (use_policy_dates) {
    if (!is.null(params$ieepa_invalidation_policy_date)) {
      params$IEEPA_INVALIDATION_DATE <- as.Date(params$ieepa_invalidation_policy_date)
      message('  Policy dates: IEEPA invalidation -> ', params$IEEPA_INVALIDATION_DATE)
    }
    if (!is.null(params$section_122$policy_effective_date)) {
      params$SECTION_122$effective_date <- as.Date(params$section_122$policy_effective_date)
      message('  Policy dates: S122 effective -> ', params$SECTION_122$effective_date)
    }
    if (!is.null(params$section_122$policy_expiry_date)) {
      params$SECTION_122$expiry_date <- as.Date(params$section_122$policy_expiry_date)
      message('  Policy dates: S122 expiry -> ', params$SECTION_122$expiry_date)
    }
  }

  # Section 232 annexes (April 2026 proclamation)
  if (!is.null(params$section_232_annexes)) {
    params$S232_ANNEXES <- params$section_232_annexes
    params$S232_ANNEXES$effective_date <- as.Date(params$section_232_annexes$effective_date)
  }

  # Section 201 (Trade Act §201 safeguards). Currently models Solar 201:
  # the HTS lists out-of-quota rates that don't reflect annual step-down,
  # so we override with the published current rate.
  if (!is.null(params$section_201)) {
    params$SECTION_201 <- params$section_201
  }

  # Local paths (optional user-specific file locations)
  params$LOCAL_PATHS <- load_local_paths()

  return(params)
}


#' Load optional local paths configuration
#'
#' Reads config/local_paths.yaml if present. Returns a named list of paths,
#' with NULL for any unset entries. Never required for core build.
#'
#' @param yaml_path Path to local_paths.yaml
#' @return Named list with import_weights, tpc_benchmark, tariff_etrs_repo
get_country_constants <- function(pp = NULL) {
  if (is.null(pp)) pp <- tryCatch(load_policy_params(), error = function(e) NULL)
  list(
    CTY_CHINA  = if (!is.null(pp)) pp$CTY_CHINA  else '5700',
    CTY_CANADA = if (!is.null(pp)) pp$CTY_CANADA else '1220',
    CTY_MEXICO = if (!is.null(pp)) pp$CTY_MEXICO else '2010',
    CTY_JAPAN  = if (!is.null(pp)) pp$CTY_JAPAN  else '5880',
    CTY_UK     = if (!is.null(pp)) pp$CTY_UK     else '4120',
    CTY_HK     = if (!is.null(pp)) pp$CTY_HK     else '5820',
    EU27_CODES = if (!is.null(pp)) pp$EU27_CODES else c(
      '4330', '4231', '4870', '4791', '4910', '4351', '4099', '4470', '4050',
      '4279', '4280', '4840', '4370', '4190', '4759', '4490', '4510', '4239',
      '4730', '4210', '4550', '4710', '4850', '4359', '4792', '4700', '4010'
    ),
    EU27_NAMES = if (!is.null(pp)) pp$EU27_NAMES else c(
      '4330' = 'Austria', '4231' = 'Belgium', '4870' = 'Bulgaria',
      '4791' = 'Croatia', '4910' = 'Cyprus', '4351' = 'Czech Republic',
      '4099' = 'Denmark', '4470' = 'Estonia', '4050' = 'Finland',
      '4279' = 'France', '4280' = 'Germany', '4840' = 'Greece',
      '4370' = 'Hungary', '4190' = 'Ireland', '4759' = 'Italy',
      '4490' = 'Latvia', '4510' = 'Lithuania', '4239' = 'Luxembourg',
      '4730' = 'Malta', '4210' = 'Netherlands', '4550' = 'Poland',
      '4710' = 'Portugal', '4850' = 'Romania', '4359' = 'Slovakia',
      '4792' = 'Slovenia', '4700' = 'Spain', '4010' = 'Sweden'
    ),
    ISO_TO_CENSUS = if (!is.null(pp)) pp$ISO_TO_CENSUS else c(
      'CN' = '5700', 'CA' = '1220', 'MX' = '2010',
      'JP' = '5880', 'UK' = '4120', 'GB' = '4120',
      'AU' = '6021', 'KR' = '5800', 'RU' = '4621',
      'AR' = '3570', 'BR' = '3510', 'UA' = '4623'
    ),
    STEEL_CHAPTERS = if (!is.null(pp)) pp$section_232_chapters$steel else c('72', '73'),
    ALUM_CHAPTERS  = if (!is.null(pp)) pp$section_232_chapters$aluminum else c('76')
  )
}


load_local_paths <- function(yaml_path = here('config', 'local_paths.yaml')) {
  defaults <- list(
    import_weights = NULL,
    tpc_benchmark = 'data/tpc/tariff_by_flow_day.csv',
    tariff_etrs_repo = NULL
  )

  if (!file.exists(yaml_path)) return(defaults)

  raw <- tryCatch(read_yaml(yaml_path), error = function(e) {
    warning('Failed to parse local_paths.yaml: ', conditionMessage(e))
    return(list())
  })

  # Merge with defaults (YAML nulls become R NULLs)
  for (nm in names(defaults)) {
    if (!is.null(raw[[nm]])) defaults[[nm]] <- raw[[nm]]
  }
  return(defaults)
}
