# =============================================================================
# Rate Schema — canonical columns, schema enforcement, authority classification
# =============================================================================
# Split from helpers.R. Sourced by helpers.R for backward compatibility.
# Direct consumers can source this file alone.

library(tidyverse)

# =============================================================================

#' Canonical column vector for rate output
RATE_SCHEMA <- c(
  'hts10', 'country', 'base_rate', 'statutory_base_rate',
  'rate_232', 'rate_301', 'rate_ieepa_recip', 'rate_ieepa_fent',
  'rate_s122', 'rate_section_201', 'rate_other',
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
    base_rate = 0, statutory_base_rate = 0, rate_232 = 0, rate_301 = 0,
    rate_ieepa_recip = 0, rate_ieepa_fent = 0, rate_s122 = 0, rate_section_201 = 0, rate_other = 0,
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
  rate_cols <- c('base_rate', 'statutory_base_rate', 'rate_232', 'rate_301', 'rate_ieepa_recip',
                 'rate_ieepa_fent', 'rate_s122', 'rate_section_201', 'rate_other',
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
    '\\+\\s*([0-9]+\\.?[0-9]*)%',              # + 25% or +25%
    'plus\\s+([0-9]+\\.?[0-9]*)%',             # plus 25%
    'duty of\\s+([0-9]+\\.?[0-9]*)%',          # a duty of 50%
    '^([0-9]+\\.?[0-9]*)%$'                    # just "25%"
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
#'   section_122, section_232, section_301, ieepa_reciprocal, section_201, other
#'
#' @param ch99_code Chapter 99 subheading (e.g., "9903.88.15")
#' @return Authority bucket name
classify_authority <- function(ch99_code) {
  if (is.na(ch99_code) || ch99_code == '') return('unknown')

  parts <- str_split(ch99_code, '\\.')[[1]]
  if (length(parts) < 2) return('unknown')

  middle <- as.integer(parts[2])

  # Section 122: 9903.03.xx (Phase 3, post-SCOTUS blanket)
  if (middle == 3) {
    return('section_122')
  }

  # Section 232:
  #   9903.74.xx  — MHD vehicles (US Note 38)
  #   9903.76.xx  — Wood products / lumber / furniture (US Note 37)
  #   9903.78.xx  — Copper derivatives (US Note 19)
  #   9903.79.xx  — Semiconductors (US Note 39, effective 2026-01-16)
  #   9903.80-85  — Steel, aluminum, derivatives
  #   9903.94.xx  — Auto tariffs (US Note 25/33)
  if (middle == 74 || middle == 76 || middle == 78 || middle == 79 ||
      (middle >= 80 && middle <= 85) || middle == 94) {
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


#' Extract a legal effective-date offset from a Ch99 description
#'
#' HTS revisions sometimes publish new Ch99 entries with descriptions that
#' specify a future legal effective date — e.g. 9903.94.01 was added at rev_6
#' (HTS effective 2025-03-12) with description text starting "Except for
#' 9903.94.02..., effective with respect to entries on or after April 3, 2025,
#' passenger vehicles..." The HTS metadata says rev_6 is active, but the
#' rate is not legally collectible until 2025-04-03. Treating the rate as
#' active on the HTS effective_date over-states ~$7B of chapter 87
#' duty in March 2025 (per tariff-etr-eval/docs/tracker_audits/
#' s232_auto_effective_date_2026-04-28.md).
#'
#' Pattern is stable across revisions: "on or after [Month] [Day], [Year]"
#' with full English month names. Returns the EARLIEST date across all matches
#' in the description; that's the conservative gate (rate becomes legally
#' collectible at the first stated activation date). Errors via stop() if a
#' matched phrase fails to parse — silent NA would re-introduce the
#' pre-activation collection bug this gate is meant to prevent.
#'
#' @param description Ch99 description text (scalar character)
#' @return Date object, NA if no pattern matches or text is empty
extract_effective_date_offset <- function(description) {
  if (is.null(description) || length(description) == 0 ||
      is.na(description) || description == '') {
    return(as.Date(NA))
  }
  matches <- regmatches(
    description,
    gregexpr('on or after [A-Za-z]+ [0-9]{1,2}, [0-9]{4}',
             description, ignore.case = TRUE)
  )[[1]]
  if (length(matches) == 0) return(as.Date(NA))
  date_strs <- sub('^on or after ', '', matches, ignore.case = TRUE)
  # %B in as.Date expects title-case month names ("April"); normalize.
  date_strs <- vapply(date_strs, function(s) {
    parts <- strsplit(s, ' ', fixed = TRUE)[[1]]
    parts[1] <- paste0(toupper(substr(parts[1], 1, 1)),
                       tolower(substring(parts[1], 2)))
    paste(parts, collapse = ' ')
  }, character(1), USE.NAMES = FALSE)
  parsed <- as.Date(date_strs, format = '%B %d, %Y')
  if (any(is.na(parsed))) {
    bad <- date_strs[is.na(parsed)]
    stop('extract_effective_date_offset: failed to parse ',
         paste(shQuote(bad), collapse = ', '),
         ' from description: ', shQuote(description))
  }
  min(parsed)
}


#' Drop Ch99 entries that are not yet legally active for a given revision
#'
#' Filters `ch99_data` to remove rows whose `effective_date_offset` (extracted
#' by `extract_effective_date_offset()` during `parse_chapter99()`) is strictly
#' AFTER the revision's `effective_date`. Rows with NA offset (no future-date
#' phrase in the description) are always retained — those are active as of
#' their HTS publication.
#'
#' Centralized here so both call sites of `calculate_rates_for_revision()`
#' (`build_full_timeseries` in 00_build_timeseries.R and
#' `build_alternative_timeseries` in 09_daily_series.R) get the same gate.
#'
#' @param ch99_data Tibble from `parse_chapter99()` with `effective_date_offset`
#' @param revision_effective_date Date (or coercible) of the revision's HTS effective date
#' @return Filtered tibble; row count reported via message() when rows are dropped
filter_active_ch99 <- function(ch99_data, revision_effective_date) {
  if (is.null(ch99_data) || nrow(ch99_data) == 0) return(ch99_data)
  if (!'effective_date_offset' %in% names(ch99_data)) {
    # Backwards-compatible no-op for any cached ch99_<revision>.rds file
    # produced before this column existed.
    return(ch99_data)
  }
  rev_date <- as.Date(revision_effective_date)
  not_yet_active <- !is.na(ch99_data$effective_date_offset) &
                    ch99_data$effective_date_offset > rev_date
  if (any(not_yet_active)) {
    n_drop <- sum(not_yet_active)
    earliest <- min(ch99_data$effective_date_offset[not_yet_active])
    message('  Dropping ', n_drop, ' Ch99 entr', if (n_drop == 1) 'y' else 'ies',
            ' not yet legally active at ', rev_date,
            ' (earliest activation: ', earliest, ')')
    ch99_data <- ch99_data[!not_yet_active, , drop = FALSE]
  }
  ch99_data
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
      rate_ieepa_fent = 0, rate_s122 = 0, rate_section_201 = 0, rate_other = 0
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
#' Reads the derivative product CSV containing both aluminum derivatives
#' (outside ch76, covered by 9903.85.04/.07/.08, US Note 19) and steel
#' derivatives (outside ch72-73, covered by 9903.81.89-93, US Note 16).
#' Steel derivatives added via Section 232 Inclusions Process (FR 2025-15819).
#' Cannot be extracted from HTS JSON.
#'
#' @param path Path to s232_derivative_products.csv
#' @param effective_date Optional date to filter entries by effective_date column.
#'   Only entries with effective_date <= this date (or blank) are returned.
