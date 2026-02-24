# =============================================================================
# Helper Functions for Tariff Rate Tracker
# =============================================================================

library(tidyverse)
library(jsonlite)
library(yaml)
library(here)

# =============================================================================
# Rate Parsing Functions
# =============================================================================

#' Parse a rate string from HTS into numeric value
#'
#' Handles formats:
#'   - "6.8%" -> 0.068
#'   - "Free" -> 0.0
#'   - "" or NA -> NA
#'   - Compound rates (e.g., "2.4¢/kg + 5%") -> NA with flag
#'   - Specific rates (e.g., "$1.50/doz") -> NA with flag
#'
#' @param rate_string Character string containing rate
#' @return Numeric rate or NA
parse_rate <- function(rate_string) {
  if (is.null(rate_string) || is.na(rate_string) || rate_string == '') {
    return(NA_real_)
  }

  # Trim whitespace
  rate_string <- trimws(rate_string)

  # Handle "Free"
  if (tolower(rate_string) == 'free') {
    return(0.0)
  }

  # Simple percentage: "6.8%" or "25%"
  if (grepl('^[0-9.]+%$', rate_string)) {
    value <- as.numeric(gsub('%', '', rate_string))
    return(value / 100)
  }

  # Percentage with decimals but no % sign (rare)
  if (grepl('^[0-9]+\\.[0-9]+$', rate_string) && as.numeric(rate_string) < 1) {
    return(as.numeric(rate_string))
  }

  # Compound or specific rates - return NA (need manual handling)
  return(NA_real_)
}

#' Check if a rate string is a simple ad valorem rate
#'
#' @param rate_string Character string
#' @return Logical TRUE if simple ad valorem
is_simple_rate <- function(rate_string) {
  if (is.null(rate_string) || is.na(rate_string) || rate_string == '') {
    return(FALSE)
  }
  rate_string <- trimws(rate_string)
  tolower(rate_string) == 'free' || grepl('^[0-9.]+%$', rate_string)
}


# =============================================================================
# HTS Code Functions
# =============================================================================

#' Normalize HTS code to 10-digit format
#'
#' Removes periods/dots and pads to 10 digits.
#' Returns NA for codes that are too short (<4 digits) or too long (>10 digits).
#'
#' @param hts_code Character HTS code (e.g., "0101.30.00.00")
#' @return Character 10-digit code (e.g., "0101300000")
normalize_hts <- function(hts_code) {
  if (is.null(hts_code) || is.na(hts_code) || hts_code == '') {
    return(NA_character_)
  }
  # Remove periods
  clean <- gsub('\\.', '', hts_code)
  # Guard: must be 4-10 digits

  if (nchar(clean) < 4 || nchar(clean) > 10) {
    return(NA_character_)
  }
  # Pad to 10 digits if needed
  if (nchar(clean) < 10) {
    clean <- str_pad(clean, 10, side = 'right', pad = '0')
  }
  return(clean)
}

#' Extract prefix at specified digit level
#'
#' @param hts10 10-digit HTS code
#' @param digits Number of digits (2, 4, 6, 8, or 10)
#' @return Character prefix
hts_prefix <- function(hts10, digits) {
  substr(hts10, 1, digits)
}


# =============================================================================
# Footnote Parsing Functions
# =============================================================================

#' Extract Chapter 99 references from footnotes
#'
#' Looks for references like "See 9903.88.15" in footnotes
#'
#' @param footnotes List of footnote objects from HTS JSON
#' @return Character vector of Chapter 99 subheadings
extract_chapter99_refs <- function(footnotes) {
  if (is.null(footnotes) || length(footnotes) == 0) {
    return(character(0))
  }

  refs <- character(0)

  for (fn in footnotes) {
    if (!is.null(fn$value)) {
      # Pattern: 9903.XX.XX (Chapter 99 subchapter III only)
      matches <- str_extract_all(fn$value, '9903\\.[0-9]{2}\\.[0-9]{2}')[[1]]
      refs <- c(refs, matches)
    }
  }

  return(unique(refs))
}


# =============================================================================
# Special Program Parsing
# =============================================================================

#' Parse special rate programs from the special column
#'
#' The special column contains text like:
#' "Free (A+,AU,BH,CL,CO,D,E,IL,JO,KR,MA,OM,P,PA,PE,S,SG)"
#'
#' @param special_string Character string from special column
#' @return List with rate and programs
parse_special_programs <- function(special_string) {
  if (is.null(special_string) || is.na(special_string) || special_string == '') {
    return(list(rate = NA_real_, programs = character(0)))
  }

  # Extract rate (before parentheses)
  rate_match <- str_extract(special_string, '^[^(]+')
  rate <- if (!is.na(rate_match)) parse_rate(trimws(rate_match)) else NA_real_

  # Extract program codes from parentheses
  programs_match <- str_extract(special_string, '\\(([^)]+)\\)')
  programs <- if (!is.na(programs_match)) {
    codes <- gsub('[()]', '', programs_match)
    trimws(unlist(strsplit(codes, ',')))
  } else {
    character(0)
  }

  return(list(rate = rate, programs = programs))
}


# =============================================================================
# Country Code Functions
# =============================================================================

#' Load census country codes
#'
#' @return Tibble with Code and Name columns
load_census_codes <- function(path = here('resources', 'census_codes.csv')) {
  read_csv(
    path,
    col_types = cols(Code = col_character(), Name = col_character())
  )
}

#' Load country to partner mapping
#'
#' @return Tibble with cty_code, cty_name, partner columns
load_country_partner_mapping <- function(path = here('resources', 'country_partner_mapping.csv')) {
  read_csv(
    path,
    col_types = cols(.default = col_character())
  )
}

#' Get all country codes from census_codes.csv
#'
#' @return Character vector of all country codes
get_all_country_codes <- function() {
  census <- load_census_codes()
  census$Code
}


# =============================================================================
# File I/O Helpers
# =============================================================================

#' Get the most recent HTS archive file
#'
#' @param year Year to look for (default: current year)
#' @return Path to most recent JSON file
get_latest_hts_archive <- function(year = format(Sys.Date(), '%Y'),
                                   archive_dir = here('data', 'hts_archives')) {
  files <- list.files(
    archive_dir,
    pattern = paste0('hts_', year, '.*\\.json$'),
    full.names = TRUE
  )

  if (length(files) == 0) {
    stop(paste('No HTS archive found for year', year))
  }

  # Return most recently modified
  file_info <- file.info(files)
  files[which.max(file_info$mtime)]
}

#' Ensure output directory exists
#'
#' @param path Directory path
ensure_dir <- function(path) {
  if (!dir.exists(path)) {
    dir.create(path, recursive = TRUE)
  }
  return(path)
}


# =============================================================================
# Policy Parameters (YAML)
# =============================================================================

#' Load policy parameters from YAML config
#'
#' Returns a list with convenience fields unpacked for direct use.
#'
#' @param yaml_path Path to policy_params.yaml
#' @return List with raw params plus convenience fields
load_policy_params <- function(yaml_path = here('config', 'policy_params.yaml')) {
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

  return(params)
}


# =============================================================================
# Revision / Archive Helpers
# =============================================================================

#' Load revision dates from config CSV
#'
#' @param csv_path Path to revision_dates.csv
#' @return Tibble with revision, effective_date, tpc_date
load_revision_dates <- function(csv_path = here('config', 'revision_dates.csv')) {
  if (!file.exists(csv_path)) {
    stop('Revision dates CSV not found: ', csv_path,
         '\nRun scraper or create manually.')
  }

  dates <- read_csv(csv_path, col_types = cols(
    revision = col_character(),
    effective_date = col_date(),
    tpc_date = col_date()
  ))

  # Validate
  stopifnot(all(!is.na(dates$revision)))
  stopifnot(all(!is.na(dates$effective_date)))
  stopifnot(!any(duplicated(dates$revision)))

  # Sort by effective_date
  dates <- dates %>% arrange(effective_date)

  message('Loaded ', nrow(dates), ' revision dates from ', csv_path)
  message('  Date range: ', min(dates$effective_date), ' to ', max(dates$effective_date))
  message('  TPC validation dates: ', sum(!is.na(dates$tpc_date)))

  return(dates)
}


#' List available HTS JSON archives
#'
#' Scans the archive directory and returns revision identifiers.
#'
#' @param archive_dir Path to HTS JSON archive directory
#' @param year Year prefix (default: 2025)
#' @return Character vector of revision identifiers
list_available_revisions <- function(archive_dir = here('data', 'hts_archives'), year = 2025) {
  files <- list.files(archive_dir, pattern = paste0('hts_', year, '.*\\.json$'))

  # Extract revision from filename: hts_2025_rev_32.json -> rev_32, hts_2025_basic.json -> basic
  revisions <- str_match(files, paste0('hts_', year, '_(.+)\\.json'))[, 2]
  revisions <- revisions[!is.na(revisions)]

  return(revisions)
}


#' Resolve JSON path for a revision
#'
#' @param revision Revision identifier (e.g., 'basic', 'rev_1')
#' @param archive_dir HTS archive directory
#' @param year HTS year (default: 2025)
#' @return Full file path to JSON
resolve_json_path <- function(revision, archive_dir = here('data', 'hts_archives'), year = 2025) {
  # Handle 2026_basic special case
  if (grepl('^2026', revision)) {
    path <- file.path(archive_dir, paste0('hts_', revision, '.json'))
  } else {
    path <- file.path(archive_dir, paste0('hts_', year, '_', revision, '.json'))
  }

  if (!file.exists(path)) {
    stop('HTS JSON not found: ', path)
  }

  return(path)
}


# =============================================================================
# Rate Schema
# =============================================================================

#' Canonical column vector for rate output
RATE_SCHEMA <- c(
  'hts10', 'country', 'base_rate',
  'rate_232', 'rate_301', 'rate_ieepa_recip', 'rate_ieepa_fent', 'rate_other',
  'total_additional', 'total_rate',
  'usmca_eligible', 'revision', 'effective_date'
)

#' Ensure a rates data frame conforms to the canonical schema
#'
#' Adds missing columns with sensible defaults, reorders to canonical order.
#' Extra columns are preserved at the end.
#'
#' @param df Data frame with rate data
#' @return Data frame with all RATE_SCHEMA columns present and ordered first
enforce_rate_schema <- function(df) {
  # Defaults by column
  defaults <- list(
    hts10 = NA_character_, country = NA_character_,
    base_rate = 0, rate_232 = 0, rate_301 = 0,
    rate_ieepa_recip = 0, rate_ieepa_fent = 0, rate_other = 0,
    total_additional = 0, total_rate = 0,
    usmca_eligible = FALSE, revision = NA_character_,
    effective_date = as.Date(NA)
  )

  for (col in RATE_SCHEMA) {
    if (!col %in% names(df)) {
      df[[col]] <- defaults[[col]]
    }
  }

  # Reorder: schema columns first, then any extras
  extra_cols <- setdiff(names(df), RATE_SCHEMA)
  df <- df[, c(RATE_SCHEMA, extra_cols)]

  return(df)
}


# =============================================================================
# Stacking Rules
# =============================================================================

#' Apply tariff stacking rules (vectorized)
#'
#' Implements the canonical stacking logic:
#'   - China: max(232, reciprocal) + fentanyl + 301 + other
#'   - All others: max(232, reciprocal) + fentanyl + other
#'
#' Operates on a data frame with rate columns and a country column.
#'
#' @param df Data frame with rate_232, rate_301, rate_ieepa_recip,
#'   rate_ieepa_fent, rate_other, country columns
#' @param cty_china Census code for China (default: '5700')
#' @return df with total_additional and total_rate recomputed
apply_stacking_rules <- function(df, cty_china = '5700') {
  df %>%
    mutate(
      total_additional = case_when(
        country == cty_china ~
          pmax(rate_232, rate_ieepa_recip) + rate_ieepa_fent + rate_301 + rate_other,
        TRUE ~
          pmax(rate_232, rate_ieepa_recip) + rate_ieepa_fent + rate_other
      ),
      total_rate = base_rate + total_additional
    )
}


# =============================================================================
# Consolidated Functions (deduplicated from 03, 04, 06)
# =============================================================================

#' Parse rate from Chapter 99 general field
#'
#' Handles Ch99-specific formats:
#'   "The duty provided in the applicable subheading + 25%"
#'   "The duty provided in the applicable subheading plus 7.5%"
#'   "25%"
#'
#' Distinct from parse_rate() which handles MFN product rates.
#'
#' @param general_text Text from the general field
#' @return Numeric rate (e.g., 0.25) or NA
parse_ch99_rate <- function(general_text) {
  if (is.null(general_text) || is.na(general_text) || general_text == '') {
    return(NA_real_)
  }

  patterns <- c(
    '\\+\\s*([0-9]+\\.?[0-9]*)%',      # + 25% or +25%
    'plus\\s+([0-9]+\\.?[0-9]*)%',     # plus 25%
    '^([0-9]+\\.?[0-9]*)%$'            # just "25%"
  )

  for (pattern in patterns) {
    match <- str_match(general_text, regex(pattern, ignore_case = TRUE))
    if (!is.na(match[1, 2])) {
      return(as.numeric(match[1, 2]) / 100)
    }
  }

  return(NA_real_)
}


#' Classify Chapter 99 code into authority buckets
#'
#' Unified classifier that uses normalized authority names:
#'   section_232, section_301, ieepa_reciprocal, section_201, other
#'
#' @param ch99_code Chapter 99 subheading (e.g., "9903.88.15")
#' @return Authority bucket name
classify_authority <- function(ch99_code) {
  if (is.na(ch99_code) || ch99_code == '') return('unknown')

  parts <- str_split(ch99_code, '\\.')[[1]]
  if (length(parts) < 2) return('unknown')

  middle <- as.integer(parts[2])

  # Section 232: 9903.80-85 (steel, aluminum, autos) + 9903.94 (auto tariffs)
  if ((middle >= 80 && middle <= 85) || middle == 94) {
    return('section_232')
  }

  # Section 301: 9903.86-89 (China tariffs) + 9903.91 (Biden 301) + 9903.92 (cranes)
  if ((middle >= 86 && middle <= 89) || middle == 91 || middle == 92) {
    return('section_301')
  }

  # IEEPA reciprocal: 9903.90 (China surcharges) + 9903.93/95/96
  if (middle == 90 || (middle >= 93 && middle <= 96 && middle != 94)) {
    return('ieepa_reciprocal')
  }

  # Section 201 (safeguards): 9903.40-45
  if (middle >= 40 && middle <= 45) {
    return('section_201')
  }

  return('other')
}


#' Check if HTS code is a valid 10-digit product code
#'
#' @param hts_code HTS code (with or without dots)
#' @return Logical
is_valid_hts10 <- function(hts_code) {
  if (is.null(hts_code) || is.na(hts_code) || hts_code == '') {
    return(FALSE)
  }

  clean <- gsub('\\.', '', hts_code)
  nchar(clean) == 10 && grepl('^[0-9]+$', clean)
}
