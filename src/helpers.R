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

#' Parse a revision identifier into year and revision type
#'
#' Handles both year-prefixed and plain formats:
#'   '2026_rev_3'  -> list(year=2026, rev='rev_3')
#'   '2026_basic'  -> list(year=2026, rev='basic')
#'   'rev_32'      -> list(year=2025, rev='rev_32')
#'   'basic'       -> list(year=2025, rev='basic')
#'
#' @param revision Character revision identifier
#' @return List with year (integer) and rev (character) components
parse_revision_id <- function(revision) {
  if (grepl('^[0-9]{4}_', revision)) {
    year <- as.integer(substr(revision, 1, 4))
    rev <- sub('^[0-9]{4}_', '', revision)
    return(list(year = year, rev = rev))
  }
  return(list(year = 2025L, rev = revision))
}


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
    tpc_date = col_date(),
    policy_event = col_character()
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
  parsed <- parse_revision_id(revision)
  path <- file.path(archive_dir, paste0('hts_', parsed$year, '_', parsed$rev, '.json'))

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
  'rate_232', 'rate_301', 'rate_ieepa_recip', 'rate_ieepa_fent', 'rate_s122', 'rate_other',
  'metal_share',
  'total_additional', 'total_rate',
  'usmca_eligible', 'revision', 'effective_date',
  'valid_from', 'valid_until'
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
    rate_ieepa_recip = 0, rate_ieepa_fent = 0, rate_s122 = 0, rate_other = 0,
    metal_share = 1.0,
    total_additional = 0, total_rate = 0,
    usmca_eligible = FALSE, revision = NA_character_,
    effective_date = as.Date(NA),
    valid_from = as.Date(NA), valid_until = as.Date(NA)
  )

  for (col in RATE_SCHEMA) {
    if (!col %in% names(df)) {
      df[[col]] <- defaults[[col]]
    }
  }

  # Fill NAs in numeric rate columns (bind_rows can introduce NAs)
  rate_cols <- c('base_rate', 'rate_232', 'rate_301', 'rate_ieepa_recip',
                 'rate_ieepa_fent', 'rate_s122', 'rate_other',
                 'total_additional', 'total_rate')
  for (col in rate_cols) {
    if (col %in% names(df)) {
      df[[col]][is.na(df[[col]])] <- 0
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
#' Implements mutual-exclusion stacking (aligned with Tariff-ETRs):
#'
#'   China (232 > 0):  232 + recip*nonmetal + fentanyl + 301 + s122 + other
#'   China (no 232):   reciprocal + fentanyl + 301 + s122 + other
#'   Others (232 > 0): 232 + recip*nonmetal + fentanyl + s122 + other
#'   Others (no 232):  reciprocal + fentanyl + s122 + other
#'
#' Key rules:
#'   - 232 and IEEPA reciprocal are mutually exclusive (232 takes precedence)
#'   - For derivative 232 products (metal_share < 1.0), IEEPA reciprocal applies
#'     to the non-metal portion of customs value
#'   - Fentanyl stacks on 232 for all countries (separate IEEPA authority)
#'   - Section 301 only applies to China
#'   - Section 122 stacks on everything
#'
#' @param df Data frame with rate_232, rate_301, rate_ieepa_recip,
#'   rate_ieepa_fent, rate_s122, rate_other, metal_share, country columns
#' @param cty_china Census code for China (default: '5700')
#' @return df with total_additional and total_rate recomputed
apply_stacking_rules <- function(df, cty_china = '5700') {
  # Ensure rate_s122 exists and has no NAs
  # (bind_rows can introduce NAs when combining dataframes with/without this column)
  if (!'rate_s122' %in% names(df)) {
    df$rate_s122 <- 0
  } else {
    df$rate_s122[is.na(df$rate_s122)] <- 0
  }

  # Ensure metal_share exists (default 1.0 = full metal, no nonmetal portion)
  if (!'metal_share' %in% names(df)) {
    df$metal_share <- 1.0
  }

  df %>%
    mutate(
      # For derivative 232 products (metal_share < 1.0), non-232 IEEPA authorities
      # apply to the non-metal portion. For base 232 products (metal_share = 1.0),
      # nonmetal_share = 0 so behavior is unchanged (full mutual exclusion).
      nonmetal_share = if_else(rate_232 > 0 & metal_share < 1.0, 1 - metal_share, 0),
      total_additional = case_when(
        # China with 232: 232 + recip*nonmetal + fentanyl + 301 + s122*nonmetal + other
        # Fentanyl stacks at full value (separate IEEPA authority for China).
        # Reciprocal and S122 apply only to non-metal portion.
        country == cty_china & rate_232 > 0 ~
          rate_232 + rate_ieepa_recip * nonmetal_share + rate_ieepa_fent + rate_301 + rate_s122 * nonmetal_share + rate_other,

        # China without 232: reciprocal + fentanyl + 301 + s122 + other
        country == cty_china ~
          rate_ieepa_recip + rate_ieepa_fent + rate_301 + rate_s122 + rate_other,

        # Others with 232: 232 + (recip + fentanyl + s122)*nonmetal + other
        # All non-232 IEEPA authorities apply to non-metal portion only.
        rate_232 > 0 ~
          rate_232 + (rate_ieepa_recip + rate_ieepa_fent + rate_s122) * nonmetal_share + rate_other,

        # Others without 232: reciprocal + fentanyl + s122 + other
        TRUE ~ rate_ieepa_recip + rate_ieepa_fent + rate_s122 + rate_other
      ),
      total_rate = base_rate + total_additional
    ) %>%
    select(-nonmetal_share)
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


# =============================================================================
# Blanket Tariff Expansion Helper
# =============================================================================

#' Add product-country pairs not yet in rates for a blanket tariff
#'
#' Common pattern used by fentanyl, 232 derivatives, and other blanket tariffs:
#' expand covered products x applicable countries, anti-join against existing
#' rows in rates, assign the blanket rate, and bind to rates.
#'
#' @param rates Current rates tibble
#' @param products Product data with hts10, base_rate columns
#' @param covered_hts10 Character vector of HTS10 codes subject to this tariff
#' @param country_rates Tibble with 'country' and 'blanket_rate' columns
#' @param rate_col Name of the rate column to set (e.g., 'rate_ieepa_fent')
#' @param label Description for log message (e.g., 'fentanyl-only duties')
#' @return Updated rates tibble with new pairs added
add_blanket_pairs <- function(rates, products, covered_hts10, country_rates,
                              rate_col, label) {
  applicable <- country_rates %>% filter(blanket_rate > 0) %>% pull(country)
  if (length(applicable) == 0 || length(covered_hts10) == 0) return(rates)

  existing <- rates %>%
    filter(hts10 %in% covered_hts10, country %in% applicable) %>%
    select(hts10, country)

  new_pairs <- products %>%
    filter(hts10 %in% covered_hts10) %>%
    select(hts10, base_rate) %>%
    mutate(base_rate = coalesce(base_rate, 0)) %>%
    tidyr::expand_grid(country = applicable) %>%
    anti_join(existing, by = c('hts10', 'country')) %>%
    left_join(country_rates, by = 'country') %>%
    mutate(
      rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0,
      rate_ieepa_fent = 0, rate_other = 0
    )

  new_pairs[[rate_col]] <- new_pairs$blanket_rate
  new_pairs <- new_pairs %>%
    filter(blanket_rate > 0) %>%
    select(-blanket_rate)

  if (nrow(new_pairs) > 0) {
    message('  Adding ', nrow(new_pairs), ' product-country pairs for ', label)
    rates <- bind_rows(rates, new_pairs)
  }

  return(rates)
}


# =============================================================================
# Section 232 Derivative Products
# =============================================================================

#' Load Section 232 derivative product list
#'
#' Reads the derivative product CSV (aluminum-containing articles outside ch76
#' covered by 9903.85.04/.07/.08). These products are defined by US Note 19
#' subdivisions i/j/k and cannot be extracted from HTS JSON.
#'
#' @param path Path to s232_derivative_products.csv
#' @return Tibble with hts_prefix, ch99_code, derivative_type; or NULL if missing
load_232_derivative_products <- function(path = here('resources', 's232_derivative_products.csv')) {
  if (!file.exists(path)) {
    message('  232 derivative products file not found: ', path)
    return(NULL)
  }

  products <- read_csv(path, col_types = cols(
    hts_prefix = col_character(),
    ch99_code = col_character(),
    derivative_type = col_character()
  ))

  message('  Loaded ', nrow(products), ' Section 232 derivative product prefixes')
  return(products)
}


#' Load floor country product exemptions
#'
#' Products exempt from the 15% tariff floor for EU, Japan, S. Korea,
#' Switzerland/Liechtenstein. Categories: PTAAP (agricultural/natural
#' resources), civil aircraft, non-patented pharmaceuticals. Parsed from
#' US Notes to Chapter 99 by 12_scrape_us_notes.R --floor-exemptions.
#'
#' @param path Path to floor_exempt_products.csv
#' @return Tibble with hts8, category, country_group, ch99_code; or empty tibble if missing
load_floor_exempt_products <- function(path = here('resources', 'floor_exempt_products.csv')) {
  if (!file.exists(path)) {
    message('  Floor exempt products file not found: ', path)
    return(tibble(hts8 = character(), category = character(),
                  country_group = character(), ch99_code = character()))
  }

  products <- read_csv(path, col_types = cols(.default = col_character()))
  message('  Loaded ', nrow(products), ' floor exempt products (',
          n_distinct(products$hts8), ' unique HTS8)')
  return(products)
}


#' Load product-level USMCA utilization shares from Census SPI data
#'
#' Per-HTS10 x country USMCA shares computed from Census IMP_DETL.TXT
#' RATE_PROV field (code 18 = USMCA). For each product-country pair:
#' usmca_share = value_under_USMCA / total_value (annual 2024).
#' Generated by src/compute_usmca_shares.R.
#' Returns NULL if file not found (triggers fallback to binary eligibility).
#'
#' @param path Path to usmca_product_shares.csv
#' @return Tibble with hts10, cty_code, usmca_share; or NULL if missing
load_usmca_product_shares <- function(path = here('resources', 'usmca_product_shares.csv')) {
  if (!file.exists(path)) {
    message('  USMCA product shares file not found — using binary eligibility')
    return(NULL)
  }
  shares <- read_csv(path, col_types = cols(
    hts10 = col_character(),
    cty_code = col_character(),
    usmca_share = col_double()
  ))
  message('  Loaded USMCA product shares: ', nrow(shares), ' product-country pairs')
  return(shares)
}


#' Load fentanyl carve-out product lists
#'
#' Product-specific fentanyl rate carve-outs: energy/critical minerals (CA) and
#' potash (CA/MX) receive a lower fentanyl rate than the general blanket.
#' Product lists sourced from Tariff-ETRs config (US Note 2 subdivisions).
#'
#' @param path Path to fentanyl_carveout_products.csv
#' @return Tibble with hts8, ch99_code, category columns (or NULL if file missing)
load_fentanyl_carveouts <- function(path = here('resources', 'fentanyl_carveout_products.csv')) {
  if (!file.exists(path)) {
    message('  Fentanyl carve-out products file not found: ', path)
    return(NULL)
  }

  carveouts <- read_csv(path, col_types = cols(
    hts8 = col_character(),
    ch99_code = col_character(),
    category = col_character()
  ))

  message('  Loaded ', nrow(carveouts), ' fentanyl carve-out product prefixes (',
          n_distinct(carveouts$category), ' categories)')
  return(carveouts)
}


#' Load metal content shares for Section 232 derivative products
#'
#' For derivative 232 products, the tariff applies only to the metal content
#' portion of customs value. This function returns per-product metal shares.
#'
#' Three methods:
#'   flat: All derivative products get metal_share = flat_share (default 0.50)
#'   cbo:  Product-level buckets from resources/cbo/ files
#'         (high=0.75, low=0.25, copper=0.90)
#'   bea:  Sector-level shares from BEA I-O tables (future)
#'
#' Products in primary_chapters (72, 73, 76) always get metal_share = 1.0.
#' Non-derivative products outside primary chapters get metal_share = 1.0
#' (no metal adjustment — they don't have 232 rates).
#'
#' @param metal_cfg Metal content config list from policy_params.yaml
#' @param hts10_codes Character vector of HTS10 codes to compute shares for
#' @param derivative_hts10 Character vector of HTS10 codes identified as 232
#'   derivatives. Only these products receive metal_share < 1.0.
#' @return Tibble with hts10 and metal_share columns
load_metal_content <- function(metal_cfg = NULL, hts10_codes = character(0),
                               derivative_hts10 = character(0)) {
  if (length(hts10_codes) == 0) {
    return(tibble(hts10 = character(), metal_share = numeric()))
  }

  method <- if (!is.null(metal_cfg)) metal_cfg$method %||% 'flat' else 'flat'
  flat_share <- if (!is.null(metal_cfg)) metal_cfg$flat_share %||% 0.50 else 0.50
  primary_chapters <- if (!is.null(metal_cfg)) unlist(metal_cfg$primary_chapters) else c('72', '73', '76')

  # Start with all products at metal_share = 1.0 (full metal / no adjustment)
  result <- tibble(hts10 = hts10_codes, metal_share = 1.0)

  # Flag derivative products — only these get metal_share < 1.0
  is_derivative <- result$hts10 %in% derivative_hts10

  if (sum(is_derivative) == 0) {
    message('  Metal content: no derivative products to adjust')
    return(result)
  }

  if (method == 'flat') {
    result$metal_share[is_derivative] <- flat_share
    message('  Metal content: flat method (', round(flat_share * 100),
            '% for ', sum(is_derivative), ' derivatives)')

  } else if (method == 'cbo') {
    cbo_high_share <- if (!is.null(metal_cfg)) metal_cfg$cbo_high_share %||% 0.75 else 0.75
    cbo_low_share <- if (!is.null(metal_cfg)) metal_cfg$cbo_low_share %||% 0.25 else 0.25
    cbo_copper_share <- if (!is.null(metal_cfg)) metal_cfg$cbo_copper_share %||% 0.90 else 0.90

    # Load CBO bucket files
    cbo_dir <- here('resources', 'cbo')
    high_path <- file.path(cbo_dir, 'alst_deriv_h.csv')
    low_path <- file.path(cbo_dir, 'alst_deriv_l.csv')
    copper_path <- file.path(cbo_dir, 'copper.csv')

    cbo_shares <- tibble(hts10 = character(), metal_share = numeric())

    if (file.exists(copper_path)) {
      copper <- read_csv(copper_path, col_types = cols(I_COMMODITY = col_character()))
      cbo_shares <- bind_rows(cbo_shares,
        tibble(hts10 = copper$I_COMMODITY, metal_share = cbo_copper_share))
    }
    if (file.exists(high_path)) {
      high <- read_csv(high_path, col_types = cols(I_COMMODITY = col_character()))
      cbo_shares <- bind_rows(cbo_shares,
        tibble(hts10 = high$I_COMMODITY, metal_share = cbo_high_share))
    }
    if (file.exists(low_path)) {
      low <- read_csv(low_path, col_types = cols(I_COMMODITY = col_character()))
      cbo_shares <- bind_rows(cbo_shares,
        tibble(hts10 = low$I_COMMODITY, metal_share = cbo_low_share))
    }

    # Priority: copper > high > low (first match kept)
    cbo_shares <- cbo_shares %>%
      distinct(hts10, .keep_all = TRUE)

    # Only apply CBO shares to derivative products
    result <- result %>%
      left_join(cbo_shares %>% rename(cbo_share = metal_share), by = 'hts10') %>%
      mutate(
        metal_share = case_when(
          !is_derivative ~ 1.0,               # non-derivatives stay at 1.0
          !is.na(cbo_share) ~ cbo_share,      # CBO match for derivatives
          TRUE ~ flat_share                    # fallback to flat for unmatched derivatives
        )
      ) %>%
      select(-cbo_share)

    n_cbo <- sum(!is.na(cbo_shares$hts10[cbo_shares$hts10 %in% derivative_hts10]))
    message('  Metal content: CBO method (', n_cbo, ' of ', sum(is_derivative),
            ' derivatives matched; high=', cbo_high_share, ', low=', cbo_low_share,
            ', copper=', cbo_copper_share, ')')

  } else if (method == 'bea') {
    message('  Metal content: BEA method not yet implemented, using flat fallback')
    result$metal_share[is_derivative] <- flat_share

  } else {
    warning('Unknown metal_content method: ', method, '. Using flat fallback.')
    result$metal_share[is_derivative] <- flat_share
  }

  return(result)
}
