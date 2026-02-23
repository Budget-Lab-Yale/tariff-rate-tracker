# =============================================================================
# Step 01: Parse Chapter 99 Entries
# =============================================================================
#
# Extracts Chapter 99 subheadings from HTS JSON and parses:
#   - Rate (from 'general' field)
#   - Country applicability (from 'description' field)
#   - Authority type (inferred from subheading range)
#
# Output: chapter99_rates.rds with columns:
#   - ch99_code: Chapter 99 subheading (e.g., "9903.88.15")
#   - rate: Additional duty rate (numeric, e.g., 0.25 for 25%)
#   - authority: Inferred authority (section_232, section_301, ieepa, etc.)
#   - countries: List of country codes or special value ("all", "all_except")
#   - exempt_countries: List of exempt countries (if countries = "all_except")
#   - description: Original description text
#   - general_raw: Original general rate text
#
# =============================================================================

library(tidyverse)
library(jsonlite)

# =============================================================================
# Rate Parsing Functions
# =============================================================================

#' Parse rate from Chapter 99 general field
#'
#' Extracts percentage from strings like:
#'   "The duty provided in the applicable subheading + 25%"
#'   "The duty provided in the applicable subheading plus 7.5%"
#'   "25%"
#'
#' @param general_text Text from the general field
#' @return Numeric rate (e.g., 0.25) or NA
parse_ch99_rate <- function(general_text) {
  if (is.null(general_text) || is.na(general_text) || general_text == '') {
    return(NA_real_)
  }

  # Pattern: "+ X%" or "plus X%" or just "X%"
  # Capture the percentage value
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


#' Infer authority type from Chapter 99 subheading
#'
#' @param ch99_code Chapter 99 code (e.g., "9903.88.15")
#' @return Authority string
infer_authority <- function(ch99_code) {
  # Extract the middle digits (e.g., "88" from "9903.88.15")
  parts <- str_split(ch99_code, '\\.')[[1]]
  if (length(parts) < 2) return('unknown')

  middle <- as.integer(parts[2])

  # Based on HTS Chapter 99 structure
  case_when(
    middle >= 80 && middle <= 82 ~ 'section_232',          # 9903.80-82: Steel 232
    middle >= 83 && middle <= 84 ~ 'section_232_auto',     # 9903.83-84: Autos 232
    middle == 85 ~ 'section_232_aluminum',                  # 9903.85: Aluminum 232
    middle >= 86 && middle <= 89 ~ 'section_301',          # 9903.86-89: China 301 (US Note 20/21)
    middle == 90 ~ 'ieepa',                                # 9903.90: IEEPA (China surcharges)
    middle == 91 ~ 'section_301',                          # 9903.91: Biden 301 (US Note 31, China)
    middle == 92 ~ 'section_301',                          # 9903.92: 301-related crane duties
    middle == 94 ~ 'section_232_auto',                     # 9903.94: Auto tariffs (US Note 33)
    middle >= 40 && middle <= 45 ~ 'section_201',          # 9903.40-45: Safeguards
    TRUE ~ 'other'
  )
}


# =============================================================================
# Country Parsing Functions
# =============================================================================

#' Parse country applicability from description
#'
#' Extracts country information from descriptions like:
#'   "articles the product of China..."
#'   "except products of Australia, of Canada, of Mexico..."
#'
#' @param description Description text
#' @return List with 'type' and 'countries'
parse_countries <- function(description) {
  if (is.null(description) || is.na(description) || description == '') {
    return(list(type = 'unknown', countries = character(0), exempt = character(0)))
  }

  desc_lower <- tolower(description)

  # Check for "product of China" pattern
  if (str_detect(desc_lower, 'product of china')) {
    return(list(type = 'specific', countries = c('CN'), exempt = character(0)))
  }

  # US Note 21 = Biden Section 301 (China-specific)
  if (str_detect(desc_lower, 'u\\.s\\.\\s*note\\s*21')) {
    return(list(type = 'specific', countries = c('CN'), exempt = character(0)))
  }

  # US Note 31 = Biden Section 301 increases (China-specific)
  if (str_detect(desc_lower, 'u\\.s\\.\\s*note\\s*31')) {
    return(list(type = 'specific', countries = c('CN'), exempt = character(0)))
  }

  # Check for "product of Canada" pattern
  if (str_detect(desc_lower, 'product of canada')) {
    countries <- c('CA')
    if (str_detect(desc_lower, 'mexico')) {
      countries <- c(countries, 'MX')
    }
    return(list(type = 'specific', countries = countries, exempt = character(0)))
  }

  # Check for "except products of..." pattern (Section 232 style)
  except_match <- str_match(desc_lower, 'except[^,]*(products? of|of)\\s+([^,]+(?:,\\s*(?:of\\s+)?[^,]+)*)')
  if (!is.na(except_match[1, 1])) {
    # Extract country names from the exception list
    except_text <- except_match[1, 3]
    exempt <- extract_country_names(except_text)
    return(list(type = 'all_except', countries = character(0), exempt = exempt))
  }

  # Check for "product of the Russian Federation"
  if (str_detect(desc_lower, 'russian federation')) {
    return(list(type = 'specific', countries = c('RU'), exempt = character(0)))
  }

  # Default: applies to all countries
  return(list(type = 'all', countries = character(0), exempt = character(0)))
}


#' Extract country names from text
#'
#' @param text Text containing country names
#' @return Vector of ISO country codes
extract_country_names <- function(text) {
  # Map of country names to ISO codes
  country_map <- c(
    'australia' = 'AU', 'argentina' = 'AR', 'brazil' = 'BR',
    'canada' = 'CA', 'mexico' = 'MX', 'china' = 'CN',
    'south korea' = 'KR', 'korea' = 'KR',
    'japan' = 'JP', 'united kingdom' = 'UK', 'uk' = 'UK',
    'european union' = 'EU', 'eu' = 'EU',
    'ukraine' = 'UA', 'russia' = 'RU', 'russian federation' = 'RU'
  )

  text_lower <- tolower(text)
  found <- character(0)

  for (name in names(country_map)) {
    if (str_detect(text_lower, name)) {
      found <- c(found, country_map[name])
    }
  }

  unique(found)
}


# =============================================================================
# Main Parsing Function
# =============================================================================

#' Parse all Chapter 99 entries from HTS JSON
#'
#' @param json_path Path to HTS JSON file
#' @return Tibble with parsed Chapter 99 data
parse_chapter99 <- function(json_path) {
  message('Reading HTS JSON from: ', json_path)

  # Read JSON
  hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)
  message('  Total items: ', length(hts_raw))

  # Filter to Chapter 99 entries (9903.xx.xx)
  ch99_items <- Filter(function(x) {
    htsno <- x$htsno %||% ''
    grepl('^9903\\.', htsno)
  }, hts_raw)

  message('  Chapter 99 entries: ', length(ch99_items))

  # Parse each entry
  parsed <- map_dfr(ch99_items, function(item) {
    ch99_code <- item$htsno %||% NA_character_
    general <- item$general %||% ''
    other <- item$other %||% ''
    description <- item$description %||% ''

    # Parse rate from general or other column
    rate <- parse_ch99_rate(general)
    if (is.na(rate)) {
      rate <- parse_ch99_rate(other)
    }

    # Infer authority
    authority <- infer_authority(ch99_code)

    # Parse countries
    country_info <- parse_countries(description)

    tibble(
      ch99_code = ch99_code,
      rate = rate,
      authority = authority,
      country_type = country_info$type,
      countries = list(country_info$countries),
      exempt_countries = list(country_info$exempt),
      general_raw = general,
      other_raw = other,
      description = description
    )
  })

  # Summary
  message('\n=== Chapter 99 Summary ===')
  message('  Total entries: ', nrow(parsed))
  message('  With parsed rates: ', sum(!is.na(parsed$rate)))
  message('  By authority:')

  auth_summary <- parsed %>%
    count(authority, sort = TRUE)
  print(auth_summary)

  message('\n  By country type:')
  cty_summary <- parsed %>%
    count(country_type, sort = TRUE)
  print(cty_summary)

  return(parsed)
}


#' Compare Chapter 99 entries between two HTS versions
#'
#' @param old_ch99 Parsed Chapter 99 from older version
#' @param new_ch99 Parsed Chapter 99 from newer version
#' @return List with added, removed, and changed entries
compare_chapter99 <- function(old_ch99, new_ch99) {
  old_codes <- old_ch99$ch99_code
  new_codes <- new_ch99$ch99_code

  added <- setdiff(new_codes, old_codes)
  removed <- setdiff(old_codes, new_codes)

  # Check for rate changes in common codes
  common <- intersect(old_codes, new_codes)

  old_rates <- old_ch99 %>%
    filter(ch99_code %in% common) %>%
    select(ch99_code, rate_old = rate)

  new_rates <- new_ch99 %>%
    filter(ch99_code %in% common) %>%
    select(ch99_code, rate_new = rate)

  rate_changes <- old_rates %>%
    inner_join(new_rates, by = 'ch99_code') %>%
    filter(!is.na(rate_old) & !is.na(rate_new)) %>%
    filter(abs(rate_old - rate_new) > 0.0001)

  list(
    added = new_ch99 %>% filter(ch99_code %in% added),
    removed = old_ch99 %>% filter(ch99_code %in% removed),
    rate_changes = rate_changes,
    n_added = length(added),
    n_removed = length(removed),
    n_rate_changes = nrow(rate_changes)
  )
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  setwd('C:/Users/ji252/Documents/GitHub/tariff_rate_tracker')

  # Parse the most recent revision (has all entries)
  ch99_rev32 <- parse_chapter99('data/hts_archives/hts_2025_rev_32.json')

  # Also parse baseline for comparison
  ch99_basic <- parse_chapter99('data/hts_archives/hts_2025_basic.json')

  # Compare
  cat('\n=== Changes from Basic to Rev 32 ===\n')
  changes <- compare_chapter99(ch99_basic, ch99_rev32)
  cat('Added entries:', changes$n_added, '\n')
  cat('Removed entries:', changes$n_removed, '\n')
  cat('Rate changes:', changes$n_rate_changes, '\n')

  if (changes$n_added > 0) {
    cat('\nNewly added Chapter 99 entries:\n')
    print(changes$added %>% select(ch99_code, rate, authority, country_type))
  }

  # Save
  if (!dir.exists('data/processed')) dir.create('data/processed', recursive = TRUE)
  saveRDS(ch99_rev32, 'data/processed/chapter99_rates.rds')
  message('\nSaved Chapter 99 data to data/processed/chapter99_rates.rds')

  # Also save as CSV for review
  ch99_rev32 %>%
    mutate(
      countries_str = map_chr(countries, ~paste(.x, collapse = ';')),
      exempt_str = map_chr(exempt_countries, ~paste(.x, collapse = ';'))
    ) %>%
    select(-countries, -exempt_countries) %>%
    write_csv('data/processed/chapter99_rates.csv')
  message('Saved Chapter 99 data to data/processed/chapter99_rates.csv')
}
