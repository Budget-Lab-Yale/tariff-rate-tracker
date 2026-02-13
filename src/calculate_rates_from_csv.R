# =============================================================================
# Calculate Tariff Rates from Pre-extracted CSV Data
# =============================================================================
#
# Uses CSV files extracted by PowerShell scripts:
#   - chapter99_raw.csv: Chapter 99 rates and country applicability
#   - products_raw.csv: HTS10 products with Ch99 references
#
# Implements stacking rules from Tariff-ETRs:
#   - China: max(232, reciprocal) + fentanyl + 301 + other
#   - Others with 232: 232 + other (232 takes precedence)
#   - Others without 232: reciprocal + fentanyl + other
#
# =============================================================================

library(tidyverse)

# =============================================================================
# Constants
# =============================================================================

# Key Census country codes
CTY_CHINA <- '5700'
CTY_CANADA <- '1220'
CTY_MEXICO <- '2010'

# Country name to Census code mapping (for TPC comparison)
COUNTRY_NAME_TO_CODE <- c(
  'China' = '5700',
  'Canada' = '1220',
  'Mexico' = '2010',
  'Japan' = '5880',
  'United Kingdom' = '4120',
  'Germany' = '4280',
  'France' = '4279',
  'Italy' = '4759',
  'South Korea' = '5800',
  'Korea, South' = '5800',
  'Taiwan' = '5830',
  'Australia' = '6021',
  'Brazil' = '3510',
  'India' = '5330',
  'Vietnam' = '5520',
  'Thailand' = '5490',
  'Indonesia' = '5600',
  'Malaysia' = '5570',
  'Singapore' = '5590',
  'Russia' = '4621',
  'Russian Federation' = '4621'
)


# =============================================================================
# Authority Classification
# =============================================================================

#' Classify Chapter 99 code into authority buckets
#'
#' @param ch99_code Chapter 99 subheading
#' @return Authority string
classify_authority <- function(ch99_code) {
  # Parse the middle digits
  parts <- str_split(ch99_code, '\\.')[[1]]
  if (length(parts) < 2) return('unknown')

  middle <- as.integer(parts[2])

  # Classification based on HTS Chapter 99 structure
  if (middle == 1) {
    # 9903.01.xx - IEEPA reciprocal tariffs (new in 2025)
    return('ieepa_reciprocal')
  } else if (middle >= 80 && middle <= 84) {
    # 9903.80-84.xx - Section 232 (steel/aluminum/autos)
    return('section_232')
  } else if (middle >= 85 && middle <= 89) {
    # 9903.85-89.xx - Section 301 (China)
    return('section_301')
  } else if (middle == 90) {
    # 9903.90.xx - Various (including Russia tariffs)
    return('other')
  } else if (middle == 91) {
    # 9903.91.xx - IEEPA fentanyl tariffs
    return('ieepa_fentanyl')
  } else if (middle >= 92 && middle <= 96) {
    # 9903.92-96.xx - Other IEEPA provisions
    return('ieepa_reciprocal')
  } else if (middle >= 40 && middle <= 45) {
    # 9903.40-45.xx - Section 201 safeguards
    return('section_201')
  }

  return('other')
}


# =============================================================================
# Country Applicability
# =============================================================================

#' Check if a Chapter 99 entry applies to a country
#'
#' @param ch99_row Row from Chapter 99 data
#' @param country Census country code
#' @return Logical
check_country_applies <- function(country_type, countries, country) {
  switch(
    as.character(country_type),
    'all' = TRUE,
    'all_except' = TRUE,  # For now, assume applies (need to parse exempt list)
    'specific' = {
      # Map Census code to ISO for matching
      iso_to_census <- c(
        'CN' = '5700', 'CA' = '1220', 'MX' = '2010',
        'RU' = '4621', 'JP' = '5880', 'UK' = '4120'
      )
      country_iso <- names(iso_to_census)[match(country, iso_to_census)]
      if (is.na(country_iso)) country_iso <- ''

      # Check if country matches
      countries_list <- unlist(str_split(countries, ';'))
      country %in% countries_list || country_iso %in% countries_list
    },
    FALSE
  )
}


# =============================================================================
# Main Calculation Functions
# =============================================================================

#' Load and prepare Chapter 99 data
#'
#' @param ch99_path Path to Chapter 99 CSV
#' @return Prepared tibble
load_chapter99 <- function(ch99_path) {
  message('Loading Chapter 99 data from: ', ch99_path)

  ch99 <- read_csv(ch99_path, col_types = cols(.default = col_character())) %>%
    mutate(
      rate = as.numeric(rate),
      authority_refined = map_chr(ch99_code, classify_authority)
    )

  message('  Loaded ', nrow(ch99), ' Chapter 99 entries')
  message('  With rates: ', sum(!is.na(ch99$rate)))

  # Summary by refined authority
  ch99 %>%
    count(authority_refined) %>%
    print()

  return(ch99)
}


#' Load and prepare product data
#'
#' @param products_path Path to products CSV
#' @return Prepared tibble
load_products <- function(products_path) {
  message('Loading product data from: ', products_path)

  products <- read_csv(products_path, col_types = cols(.default = col_character())) %>%
    mutate(
      base_rate = as.numeric(base_rate),
      n_ch99_refs = as.integer(n_ch99_refs)
    )

  message('  Loaded ', nrow(products), ' products')
  message('  With Ch99 refs: ', sum(products$n_ch99_refs > 0))

  return(products)
}


#' Calculate rates for products × countries
#'
#' @param products Product data
#' @param ch99 Chapter 99 data
#' @param countries Vector of Census country codes
#' @return Tibble with calculated rates
calculate_rates <- function(products, ch99, countries) {
  message('Calculating rates...')

  # Filter to products with Chapter 99 refs
  products_with_refs <- products %>%
    filter(n_ch99_refs > 0)

  message('  Products with refs: ', nrow(products_with_refs))

  # Expand product Ch99 refs to separate rows
  product_refs <- products_with_refs %>%
    select(hts10, base_rate, ch99_refs) %>%
    mutate(ch99_refs = str_split(ch99_refs, ';')) %>%
    unnest(ch99_refs) %>%
    rename(ch99_code = ch99_refs) %>%
    filter(ch99_code != '')

  message('  Product-Ch99 pairs: ', nrow(product_refs))

  # Join with Chapter 99 rates
  product_ch99 <- product_refs %>%
    left_join(
      ch99 %>% select(ch99_code, rate, authority_refined, country_type, countries),
      by = 'ch99_code'
    ) %>%
    filter(!is.na(rate))

  message('  Product-Ch99 pairs with rates: ', nrow(product_ch99))

  # For each country, calculate applicable rates
  results <- list()

  message('  Processing countries...')
  pb <- txtProgressBar(min = 0, max = length(countries), style = 3)

  for (i in seq_along(countries)) {
    setTxtProgressBar(pb, i)
    cty <- countries[i]

    # Filter to Ch99 entries that apply to this country
    applicable <- product_ch99 %>%
      rowwise() %>%
      mutate(applies = check_country_applies(country_type, countries, cty)) %>%
      ungroup() %>%
      filter(applies)

    if (nrow(applicable) == 0) next

    # Aggregate by product × authority (take max within authority)
    by_authority <- applicable %>%
      group_by(hts10, base_rate, authority_refined) %>%
      summarise(rate = max(rate), .groups = 'drop')

    # Pivot to wide format
    wide <- by_authority %>%
      pivot_wider(
        names_from = authority_refined,
        values_from = rate,
        values_fill = 0
      )

    # Ensure all columns exist
    for (col in c('section_232', 'section_301', 'ieepa_reciprocal', 'ieepa_fentanyl', 'other')) {
      if (!(col %in% names(wide))) wide[[col]] <- 0
    }

    # Apply stacking rules
    wide <- wide %>%
      mutate(
        country = cty,
        base_rate = coalesce(base_rate, 0),
        total_additional = case_when(
          # China: max(232, reciprocal) + fentanyl + 301 + other
          country == CTY_CHINA ~
            pmax(section_232, ieepa_reciprocal) + ieepa_fentanyl + section_301 + other,

          # Others with 232: 232 takes precedence
          section_232 > 0 ~ section_232 + other,

          # Others: reciprocal + fentanyl + other
          TRUE ~ ieepa_reciprocal + ieepa_fentanyl + other
        ),
        total_rate = base_rate + total_additional
      )

    results[[cty]] <- wide
  }

  close(pb)

  # Combine results
  rates <- bind_rows(results)

  message('\n  Total product-country rates: ', nrow(rates))

  return(rates)
}


# =============================================================================
# TPC Comparison
# =============================================================================

#' Compare to TPC data
#'
#' @param rates Our calculated rates
#' @param tpc_path Path to TPC CSV
#' @return Comparison tibble
compare_to_tpc <- function(rates, tpc_path) {
  message('\nLoading TPC data...')

  tpc <- read_csv(tpc_path, col_types = cols(.default = col_character()))

  # Get date columns
  date_cols <- setdiff(names(tpc), c('country', 'hts10'))
  message('  TPC dates: ', paste(date_cols, collapse = ', '))

  # Pivot to long format
  tpc_long <- tpc %>%
    pivot_longer(
      cols = all_of(date_cols),
      names_to = 'date',
      values_to = 'tpc_rate'
    ) %>%
    mutate(tpc_rate = as.numeric(tpc_rate))

  # Map country names to codes
  tpc_long <- tpc_long %>%
    mutate(
      country_code = COUNTRY_NAME_TO_CODE[country]
    ) %>%
    filter(!is.na(country_code))

  message('  TPC rows: ', nrow(tpc_long))

  # Join with our rates
  comparison <- tpc_long %>%
    left_join(
      rates %>% select(hts10, country, our_rate = total_additional),
      by = c('hts10', 'country_code' = 'country')
    ) %>%
    mutate(
      our_rate = coalesce(our_rate, 0),
      tpc_rate = coalesce(tpc_rate, 0),
      diff = our_rate - tpc_rate,
      abs_diff = abs(diff),
      match = abs_diff < 0.01
    )

  # Summary
  message('\n=== TPC Comparison Summary ===')

  for (d in unique(comparison$date)) {
    comp_d <- comparison %>% filter(date == d)
    n_match <- sum(comp_d$match)
    n_total <- nrow(comp_d)
    pct_match <- round(100 * n_match / n_total, 1)
    mean_diff <- round(mean(comp_d$abs_diff) * 100, 2)

    message(d, ': ', pct_match, '% match, mean diff = ', mean_diff, ' pp')
  }

  return(comparison)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  setwd('C:/Users/ji252/Documents/GitHub/tariff_rate_tracker')

  # Load data
  ch99 <- load_chapter99('data/processed/chapter99_raw.csv')
  products <- load_products('data/processed/products_raw.csv')

  # Load country codes
  census_codes <- read_csv('resources/census_codes.csv', col_types = cols(.default = col_character()))
  countries <- census_codes$Code

  message('\nLoaded ', length(countries), ' countries')

  # Calculate rates
  rates <- calculate_rates(products, ch99, countries)

  # Save
  write_csv(rates, 'data/processed/rates_calculated.csv')
  message('\nSaved rates to data/processed/rates_calculated.csv')

  # Summary by country
  cat('\n=== Top Countries by Mean Additional Rate ===\n')
  rates %>%
    group_by(country) %>%
    summarise(
      n_products = n(),
      mean_additional = round(mean(total_additional) * 100, 1),
      max_additional = round(max(total_additional) * 100, 1),
      .groups = 'drop'
    ) %>%
    filter(mean_additional > 0) %>%
    arrange(desc(mean_additional)) %>%
    head(15) %>%
    left_join(census_codes, by = c('country' = 'Code')) %>%
    select(Name, country, n_products, mean_additional, max_additional) %>%
    print()

  # Compare to TPC
  if (file.exists('data/tpc/tariff_by_flow_day.csv')) {
    comparison <- compare_to_tpc(rates, 'data/tpc/tariff_by_flow_day.csv')
    write_csv(comparison, 'output/tpc_comparison.csv')
    message('\nSaved TPC comparison to output/tpc_comparison.csv')
  }
}
