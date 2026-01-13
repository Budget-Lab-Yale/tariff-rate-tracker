# =============================================================================
# Step 03: Expand Authority Data to Country Dimension
# =============================================================================
#
# This script expands product-authority mappings to the full country dimension.
# For each product with additional duties, creates rows for each affected country.
#
# Output: Tibble with:
#   - htsno: 10-digit HTS code
#   - cty_code: Census country code
#   - authority: Authority name
#   - sub_authority: Specific program
#   - rate: Additional duty rate for this product-country
#
# =============================================================================

source('src/helpers.R')

# =============================================================================
# Country Expansion Functions
# =============================================================================

#' Load country rules from YAML config
#'
#' @return List with country groups, exemptions, stacking rules
load_country_rules <- function() {
  rules_path <- 'config/country_rules.yaml'

  if (!file.exists(rules_path)) {
    stop('Country rules not found: ', rules_path)
  }

  yaml::read_yaml(rules_path)
}


#' Get all country codes from census_codes.csv
#'
#' @return Character vector of all country codes
get_all_country_codes <- function() {
  census <- load_census_codes()
  census$Code
}


#' Expand country specification to individual codes
#'
#' Handles:
#'   - "all" -> all country codes
#'   - List of codes -> those codes
#'   - NULL/NA -> empty
#'
#' @param countries Country specification from authority mapping
#' @param all_codes Vector of all country codes
#' @param country_groups Named list of country group definitions
#' @return Character vector of country codes
expand_countries <- function(countries, all_codes, country_groups) {
  if (is.null(countries) || length(countries) == 0) {
    return(character(0))
  }

  # Handle "all"
  if (identical(countries, 'all')) {
    return(all_codes)
  }

  # Handle "unknown" or other special values
  if (identical(countries, 'unknown') || identical(countries, 'varies')) {
    return(character(0))
  }

  # If it's a list/vector of codes, return as-is
  if (is.character(countries) || is.list(countries)) {
    codes <- unlist(countries)

    # Check if any are group names and expand
    expanded <- character(0)
    for (code in codes) {
      if (code %in% names(country_groups)) {
        expanded <- c(expanded, country_groups[[code]])
      } else {
        expanded <- c(expanded, code)
      }
    }
    return(unique(expanded))
  }

  return(character(0))
}


# =============================================================================
# Main Expansion Function
# =============================================================================

#' Expand authority data to full product × country dimension
#'
#' @param authority_data Tibble from extract_authorities
#' @return Tibble with product-country-authority rows
expand_to_countries <- function(authority_data) {
  message('Loading country rules...')
  country_rules <- load_country_rules()
  country_groups <- country_rules$country_groups

  all_codes <- get_all_country_codes()
  message('  Found ', length(all_codes), ' country codes')

  # Filter to mappings with valid rates
  valid_authorities <- authority_data %>%
    filter(
      authority != 'unmapped',
      authority != 'ad_cvd',  # Skip AD/CVD - rates vary
      !is.na(rate)
    )

  message('Expanding ', nrow(valid_authorities), ' product-authority rows to countries...')

  # Process each row
  expanded_list <- valid_authorities %>%
    rowwise() %>%
    do({
      row <- .
      country_codes <- expand_countries(row$countries, all_codes, country_groups)

      if (length(country_codes) == 0) {
        tibble()  # Skip if no countries
      } else {
        tibble(
          htsno = row$htsno,
          cty_code = country_codes,
          authority = row$authority,
          sub_authority = row$sub_authority,
          rate = row$rate,
          effective_date = row$effective_date
        )
      }
    }) %>%
    ungroup()

  message('Created ', nrow(expanded_list), ' product-country-authority rows')

  # Summarize
  auth_country_summary <- expanded_list %>%
    group_by(authority, sub_authority) %>%
    summarise(
      n_products = n_distinct(htsno),
      n_countries = n_distinct(cty_code),
      n_rows = n(),
      .groups = 'drop'
    )

  message('\n=== Expansion Summary ===')
  print(auth_country_summary, n = 30)

  return(expanded_list)
}


# =============================================================================
# Aggregation Functions
# =============================================================================

#' Aggregate expanded data by product-country (combine authorities)
#'
#' For products with multiple authorities, this creates one row per
#' product-country with all applicable rates.
#'
#' @param expanded_data Tibble from expand_to_countries
#' @return Tibble with one row per product-country, wide format by authority
aggregate_by_product_country <- function(expanded_data) {
  # Pivot to wide format - one column per authority
  wide <- expanded_data %>%
    select(htsno, cty_code, authority, sub_authority, rate) %>%
    # Create authority key for pivoting
    mutate(auth_key = paste(authority, sub_authority, sep = '_')) %>%
    select(-authority, -sub_authority) %>%
    pivot_wider(
      names_from = auth_key,
      values_from = rate,
      values_fn = max  # If duplicates, take max
    )

  return(wide)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  setwd('C:/Users/ji252/Documents/GitHub/tariff_rate_tracker')

  # Load authority data
  authority_data <- readRDS('data/processed/authority_data.rds')

  # Expand to countries
  expanded_data <- expand_to_countries(authority_data)

  # Preview
  cat('\n=== Sample Expanded Data ===\n')
  expanded_data %>%
    filter(cty_code == '5700') %>%  # China
    head(20) %>%
    print()

  # Save
  ensure_dir('data/processed')
  saveRDS(expanded_data, 'data/processed/expanded_data.rds')
  message('\nSaved expanded data to data/processed/expanded_data.rds')

  # Also save aggregated version
  aggregated <- aggregate_by_product_country(expanded_data)
  saveRDS(aggregated, 'data/processed/aggregated_data.rds')
  message('Saved aggregated data to data/processed/aggregated_data.rds')
}
