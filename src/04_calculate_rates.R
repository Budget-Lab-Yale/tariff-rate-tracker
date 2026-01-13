# =============================================================================
# Step 04: Calculate Effective Tariff Rates
# =============================================================================
#
# This script combines base HTS rates with additional duties from Chapter 99
# authorities, applying proper stacking rules.
#
# Stacking Rules (from Tariff-ETRs):
#   - China (5700): max(232, reciprocal) + fentanyl + 301 + s122
#   - Canada/Mexico: max(232, reciprocal) + fentanyl + s122
#   - Others: (232 > 0 ? 232 : reciprocal + fentanyl) + s122
#
# Output: Tibble with:
#   - htsno: 10-digit HTS code
#   - cty_code: Census country code
#   - base_rate: MFN or preferential rate
#   - rate_232: Section 232 additional duty
#   - rate_301: Section 301 additional duty
#   - rate_ieepa_reciprocal: IEEPA reciprocal tariff
#   - rate_ieepa_fentanyl: IEEPA fentanyl tariff
#   - rate_201: Section 201 safeguard
#   - total_additional: Combined additional duties (with stacking)
#   - total_rate: base_rate + total_additional
#
# =============================================================================

source('src/helpers.R')

# =============================================================================
# Rate Aggregation Functions
# =============================================================================

#' Aggregate authority rates by type for a product-country
#'
#' Combines multiple sub-authorities into authority-level rates
#' (e.g., list_1 + list_2 + list_3 -> section_301 total)
#'
#' @param expanded_data Tibble from expand_to_countries
#' @return Tibble with authority-level rates per product-country
aggregate_authority_rates <- function(expanded_data) {
  message('Aggregating authority rates...')

  # Group by product-country-authority and take max rate within authority
  authority_rates <- expanded_data %>%
    group_by(htsno, cty_code, authority) %>%
    summarise(
      rate = max(rate, na.rm = TRUE),
      .groups = 'drop'
    )

  # Pivot to wide format
  wide_rates <- authority_rates %>%
    pivot_wider(
      names_from = authority,
      values_from = rate,
      names_prefix = 'rate_',
      values_fill = 0
    )

  # Ensure all rate columns exist
  required_cols <- c('rate_section_232', 'rate_section_301', 'rate_ieepa',
                     'rate_section_201', 'rate_section_122')

  for (col in required_cols) {
    if (!(col %in% names(wide_rates))) {
      wide_rates[[col]] <- 0
    }
  }

  message('  Created ', nrow(wide_rates), ' product-country rate rows')

  return(wide_rates)
}


# =============================================================================
# Stacking Rule Functions
# =============================================================================

#' Apply stacking rules to calculate total additional duty
#'
#' @param rate_232 Section 232 rate
#' @param rate_301 Section 301 rate
#' @param rate_ieepa IEEPA rate (combined reciprocal + fentanyl)
#' @param rate_201 Section 201 rate
#' @param rate_122 Section 122 rate
#' @param cty_code Country code
#' @return Total additional duty rate
apply_stacking_rules <- function(rate_232, rate_301, rate_ieepa, rate_201, rate_122, cty_code) {
  # China (5700): All authorities stack
  if (cty_code == '5700') {
    base <- max(rate_232, rate_ieepa)
    stacking <- rate_301 + rate_201 + rate_122
    return(base + stacking)
  }

  # Canada (1220) and Mexico (2010): USMCA countries
  if (cty_code %in% c('1220', '2010')) {
    base <- max(rate_232, rate_ieepa)
    stacking <- rate_201 + rate_122
    return(base + stacking)
  }

  # All others: 232 is mutually exclusive with IEEPA
  if (rate_232 > 0) {
    base <- rate_232
    stacking <- rate_201 + rate_122
  } else {
    base <- rate_ieepa
    stacking <- rate_201 + rate_122
  }

  return(base + stacking)
}


# =============================================================================
# Main Calculation Function
# =============================================================================

#' Calculate effective tariff rates for all product-country combinations
#'
#' @param hts_data Tibble from ingest_hts_json (base rates)
#' @param expanded_data Tibble from expand_to_countries (additional duties)
#' @return Tibble with complete rate breakdown
calculate_effective_rates <- function(hts_data, expanded_data) {
  message('Calculating effective tariff rates...')

  # Get base rates from HTS data
  base_rates <- hts_data %>%
    select(htsno, general_rate, description) %>%
    rename(base_rate = general_rate)

  # Aggregate authority rates
  authority_rates <- aggregate_authority_rates(expanded_data)

  # Get all unique product-country combinations from authority data
  # plus all products with no additional duties
  all_products <- unique(hts_data$htsno)
  all_countries <- get_all_country_codes()

  # Start with products that have additional duties
  result <- authority_rates

  # Join base rates
  result <- result %>%
    left_join(base_rates, by = 'htsno')

  # Replace any NA base rates with 0 (shouldn't happen but safety)
  result <- result %>%
    mutate(base_rate = coalesce(base_rate, 0))

  # Split IEEPA into reciprocal and fentanyl components if needed
  # (For now, treat combined since mapping doesn't distinguish cleanly)

  # Apply stacking rules (vectorized)
  message('Applying stacking rules...')
  result <- result %>%
    rowwise() %>%
    mutate(
      total_additional = apply_stacking_rules(
        rate_232 = rate_section_232,
        rate_301 = rate_section_301,
        rate_ieepa = rate_ieepa,
        rate_201 = rate_section_201,
        rate_122 = if ('rate_section_122' %in% names(.)) rate_section_122 else 0,
        cty_code = cty_code
      )
    ) %>%
    ungroup()

  # Calculate total rate
  result <- result %>%
    mutate(total_rate = base_rate + total_additional)

  # Reorder columns
  result <- result %>%
    select(
      htsno,
      description,
      cty_code,
      base_rate,
      rate_section_232,
      rate_section_301,
      rate_ieepa,
      rate_section_201,
      everything(),
      total_additional,
      total_rate
    )

  # Summary statistics
  message('\n=== Rate Summary by Country ===')
  country_summary <- result %>%
    group_by(cty_code) %>%
    summarise(
      n_products = n(),
      mean_total = mean(total_rate, na.rm = TRUE),
      max_total = max(total_rate, na.rm = TRUE),
      n_with_additional = sum(total_additional > 0),
      .groups = 'drop'
    ) %>%
    arrange(desc(mean_total)) %>%
    head(10)

  print(country_summary)

  return(result)
}


# =============================================================================
# Full Product-Country Matrix
# =============================================================================

#' Create full product-country matrix with all rates
#'
#' Includes products with no additional duties (just base rate)
#'
#' @param hts_data Base HTS data
#' @param rate_data Calculated rates for products with additional duties
#' @param countries Optional: specific countries (default: all)
#' @return Full matrix
create_full_rate_matrix <- function(hts_data, rate_data, countries = NULL) {
  if (is.null(countries)) {
    countries <- get_all_country_codes()
  }

  # Products with additional duties already have rows
  products_with_duties <- unique(rate_data$htsno)

  # Products without additional duties
  products_no_duties <- hts_data %>%
    filter(!(htsno %in% products_with_duties)) %>%
    select(htsno, description, general_rate) %>%
    rename(base_rate = general_rate)

  # Expand to all countries
  no_duty_expanded <- products_no_duties %>%
    crossing(cty_code = countries) %>%
    mutate(
      rate_section_232 = 0,
      rate_section_301 = 0,
      rate_ieepa = 0,
      rate_section_201 = 0,
      total_additional = 0,
      total_rate = base_rate
    )

  # Combine
  full_matrix <- bind_rows(rate_data, no_duty_expanded)

  return(full_matrix)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  setwd('C:/Users/ji252/Documents/GitHub/tariff_rate_tracker')

  # Load data
  hts_data <- readRDS('data/processed/hts_parsed.rds')
  expanded_data <- readRDS('data/processed/expanded_data.rds')

  # Calculate rates
  rate_data <- calculate_effective_rates(hts_data, expanded_data)

  # Preview China rates
  cat('\n=== Sample China Rates ===\n')
  rate_data %>%
    filter(cty_code == '5700') %>%
    arrange(desc(total_rate)) %>%
    head(20) %>%
    select(htsno, base_rate, rate_section_232, rate_section_301, rate_ieepa, total_rate) %>%
    print()

  # Save
  ensure_dir('data/processed')
  saveRDS(rate_data, 'data/processed/rate_data.rds')
  message('\nSaved rate data to data/processed/rate_data.rds')
}
