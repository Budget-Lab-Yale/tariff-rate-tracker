# =============================================================================
# Step 03: Calculate Total Tariff Rates
# =============================================================================
#
# Calculates total effective tariff rate for each HTS10 × country combination
# using stacking rules from Tariff-ETRs.
#
# Stacking Rules (from Tariff-ETRs):
#   - China: max(232, reciprocal) + fentanyl + s122
#   - Others with 232: 232 + s122 (232 takes precedence over reciprocal)
#   - Others without 232: reciprocal + fentanyl + s122
#
# Output: rates_{revision}.rds with columns:
#   - hts10: 10-digit HTS code
#   - country: Country code (Census or ISO)
#   - base_rate: MFN base rate
#   - rate_232: Section 232 additional duty
#   - rate_301: Section 301 additional duty
#   - rate_ieepa_recip: IEEPA reciprocal tariff
#   - rate_ieepa_fent: IEEPA fentanyl tariff
#   - rate_other: Other Chapter 99 duties
#   - total_additional: Combined additional duties (with stacking)
#   - total_rate: base_rate + total_additional
#
# =============================================================================

library(tidyverse)

# =============================================================================
# Country Code Constants
# =============================================================================

# Census codes for key countries
CTY_CHINA <- '5700'
CTY_CANADA <- '1220'
CTY_MEXICO <- '2010'
CTY_JAPAN <- '5880'
CTY_UK <- '4120'

# Map ISO codes to Census codes
ISO_TO_CENSUS <- c(
  'CN' = '5700', 'CA' = '1220', 'MX' = '2010',
  'JP' = '5880', 'UK' = '4120', 'GB' = '4120',
  'AU' = '6021', 'KR' = '5800', 'RU' = '4621',
  'AR' = '3570', 'BR' = '3510', 'UA' = '4622'
)


# =============================================================================
# Authority Classification Functions
# =============================================================================

#' Classify Chapter 99 code into authority buckets
#'
#' @param ch99_code Chapter 99 subheading
#' @return Authority bucket name
classify_authority <- function(ch99_code) {
  if (is.na(ch99_code) || ch99_code == '') return('unknown')

  parts <- str_split(ch99_code, '\\.')[[1]]
  if (length(parts) < 2) return('unknown')

  middle <- as.integer(parts[2])
  last <- if (length(parts) >= 3) as.integer(parts[3]) else 0

  # Section 232: 9903.80.xx - 9903.84.xx (steel, autos)
  if (middle >= 80 && middle <= 84) {
    return('section_232')
  }

  # Section 232 aluminum: 9903.85.xx
  if (middle == 85) {
    return('section_232')
  }

  # Section 301: 9903.86.xx - 9903.89.xx (China tariffs)
  if (middle >= 86 && middle <= 89) {
    return('section_301')
  }

  # IEEPA: 9903.90.xx - 9903.96.xx
  if (middle >= 90 && middle <= 96) {
    # Distinguish fentanyl from reciprocal based on subheading
    # 9903.91.xx appears to be fentanyl-related based on HTS
    if (middle == 91) {
      return('ieepa_fentanyl')
    }
    return('ieepa_reciprocal')
  }

  # Section 201 (safeguards): 9903.40.xx - 9903.45.xx
  if (middle >= 40 && middle <= 45) {
    return('section_201')
  }

  return('other')
}


# =============================================================================
# Rate Lookup Functions
# =============================================================================

#' Get additional duty rate for a Chapter 99 reference and country
#'
#' @param ch99_code Chapter 99 subheading
#' @param country Census country code
#' @param ch99_data Chapter 99 rate data
#' @return Numeric rate or 0
get_ch99_rate_for_country <- function(ch99_code, country, ch99_data) {
  # Find the Chapter 99 entry
  entry <- ch99_data %>%
    filter(ch99_code == !!ch99_code)

  if (nrow(entry) == 0 || is.na(entry$rate[1])) {
    return(0)
  }

  rate <- entry$rate[1]
  country_type <- entry$country_type[1]
  countries <- entry$countries[[1]]
  exempt <- entry$exempt_countries[[1]]

  # Convert ISO to Census if needed
  country_census <- country
  country_iso <- names(ISO_TO_CENSUS)[match(country, ISO_TO_CENSUS)]
  if (is.na(country_iso)) country_iso <- country

  # Check applicability based on country type
  applies <- switch(
    country_type,
    'all' = TRUE,
    'all_except' = !(country_iso %in% exempt),
    'specific' = country_iso %in% countries || country %in% countries,
    FALSE
  )

  if (applies) rate else 0
}


# =============================================================================
# Stacking Rules Implementation
# =============================================================================

#' Apply stacking rules to calculate total additional duty
#'
#' Implements Tariff-ETRs stacking logic:
#'   - China: max(232, reciprocal) + fentanyl + 301 + other
#'   - Others with 232: 232 + other (232 takes precedence)
#'   - Others without 232: reciprocal + fentanyl + other
#'
#' @param rate_232 Section 232 rate
#' @param rate_301 Section 301 rate
#' @param rate_ieepa_recip IEEPA reciprocal rate
#' @param rate_ieepa_fent IEEPA fentanyl rate
#' @param rate_other Other additional duties
#' @param country Census country code
#' @return Total additional duty
apply_stacking <- function(rate_232, rate_301, rate_ieepa_recip, rate_ieepa_fent, rate_other, country) {
  # China: special stacking
  if (country == CTY_CHINA) {
    base <- max(rate_232, rate_ieepa_recip, na.rm = TRUE)
    return(base + rate_ieepa_fent + rate_301 + rate_other)
  }

  # Others with 232: 232 takes precedence over reciprocal
  if (rate_232 > 0) {
    return(rate_232 + rate_other)
  }

  # Others without 232: use IEEPA rates
  return(rate_ieepa_recip + rate_ieepa_fent + rate_other)
}


# =============================================================================
# Main Calculation Function
# =============================================================================
#' Calculate rates for all HTS10 × country combinations
#'
#' @param products Product data from parse_products
#' @param ch99_data Chapter 99 data from parse_chapter99
#' @param countries Vector of country codes to calculate for
#' @return Tibble with rate calculations
calculate_rates <- function(products, ch99_data, countries) {
  message('Calculating rates for ', nrow(products), ' products × ', length(countries), ' countries...')

  # Get products with Chapter 99 references
  products_with_refs <- products %>%
    filter(n_ch99_refs > 0)

  message('  Products with Ch99 refs: ', nrow(products_with_refs))

  # For each product, calculate rates by country
  results <- list()

  pb <- txtProgressBar(min = 0, max = nrow(products_with_refs), style = 3)

  for (i in seq_len(nrow(products_with_refs))) {
    setTxtProgressBar(pb, i)

    row <- products_with_refs[i, ]
    hts10 <- row$hts10
    base_rate <- row$base_rate
    ch99_refs <- row$ch99_refs[[1]]

    # Skip if no base rate (complex rate)
    if (is.na(base_rate)) base_rate <- 0

    # For each country, calculate applicable rates
    for (country in countries) {
      rate_232 <- 0
      rate_301 <- 0
      rate_ieepa_recip <- 0
      rate_ieepa_fent <- 0
      rate_other <- 0

      # Sum applicable Chapter 99 rates by authority
      for (ch99_ref in ch99_refs) {
        ch99_rate <- get_ch99_rate_for_country(ch99_ref, country, ch99_data)

        if (ch99_rate > 0) {
          auth <- classify_authority(ch99_ref)

          switch(
            auth,
            'section_232' = { rate_232 <- max(rate_232, ch99_rate) },
            'section_301' = { rate_301 <- rate_301 + ch99_rate },
            'ieepa_reciprocal' = { rate_ieepa_recip <- max(rate_ieepa_recip, ch99_rate) },
            'ieepa_fentanyl' = { rate_ieepa_fent <- max(rate_ieepa_fent, ch99_rate) },
            { rate_other <- rate_other + ch99_rate }
          )
        }
      }

      # Apply stacking rules
      total_additional <- apply_stacking(
        rate_232, rate_301, rate_ieepa_recip, rate_ieepa_fent, rate_other, country
      )

      # Only store if there are additional duties
      if (total_additional > 0) {
        results[[length(results) + 1]] <- tibble(
          hts10 = hts10,
          country = country,
          base_rate = base_rate,
          rate_232 = rate_232,
          rate_301 = rate_301,
          rate_ieepa_recip = rate_ieepa_recip,
          rate_ieepa_fent = rate_ieepa_fent,
          rate_other = rate_other,
          total_additional = total_additional,
          total_rate = base_rate + total_additional
        )
      }
    }
  }

  close(pb)

  # Combine results
  rates <- bind_rows(results)

  message('\n  Calculated ', nrow(rates), ' product-country rates with additional duties')

  return(rates)
}


#' Fast vectorized rate calculation (for large datasets)
#'
#' @param products Product data
#' @param ch99_data Chapter 99 data
#' @param countries Vector of country codes
#' @return Tibble with rates
calculate_rates_fast <- function(products, ch99_data, countries) {
  message('Calculating rates (fast mode)...')

  # Expand products to product × country
  products_expanded <- products %>%
    filter(n_ch99_refs > 0) %>%
    select(hts10, base_rate, ch99_refs) %>%
    crossing(country = countries)

  message('  Product-country combinations: ', nrow(products_expanded))

  # Pre-process Chapter 99 data for faster lookup
  ch99_lookup <- ch99_data %>%
    filter(!is.na(rate)) %>%
    mutate(authority = map_chr(ch99_code, classify_authority)) %>%
    select(ch99_code, rate, authority, country_type, countries, exempt_countries)

  # Unnest product Chapter 99 refs
  product_refs <- products %>%
    filter(n_ch99_refs > 0) %>%
    select(hts10, ch99_refs) %>%
    unnest(ch99_refs) %>%
    rename(ch99_code = ch99_refs)

  message('  Product-Ch99 ref pairs: ', nrow(product_refs))

  # Join with Chapter 99 rates
  product_ch99_rates <- product_refs %>%
    left_join(ch99_lookup, by = 'ch99_code') %>%
    filter(!is.na(rate))

  message('  Product-Ch99 pairs with rates: ', nrow(product_ch99_rates))

  # For each product-country, determine applicable rates
  # This requires checking country applicability for each Ch99 entry

  # Create full expansion: product × ch99 × country
  full_expansion <- product_ch99_rates %>%
    crossing(country = countries)

  message('  Full expansion: ', nrow(full_expansion))

  # Check country applicability (vectorized where possible)
  full_expansion <- full_expansion %>%
    rowwise() %>%
    mutate(
      applies = check_country_applies(country, country_type, countries, exempt_countries)
    ) %>%
    ungroup() %>%
    filter(applies)

  message('  After country filtering: ', nrow(full_expansion))

  # Aggregate by product × country × authority (take max within authority)
  by_authority <- full_expansion %>%
    group_by(hts10, country, authority) %>%
    summarise(
      rate = max(rate),
      .groups = 'drop'
    )

  # Pivot to wide format
  rates_wide <- by_authority %>%
    pivot_wider(
      names_from = authority,
      values_from = rate,
      values_fill = 0,
      names_prefix = 'rate_'
    )

  # Ensure all columns exist
  for (col in c('rate_section_232', 'rate_section_301', 'rate_ieepa_reciprocal',
                'rate_ieepa_fentanyl', 'rate_other')) {
    if (!(col %in% names(rates_wide))) {
      rates_wide[[col]] <- 0
    }
  }

  # Join base rates
  rates_wide <- rates_wide %>%
    left_join(
      products %>% select(hts10, base_rate),
      by = 'hts10'
    ) %>%
    mutate(base_rate = coalesce(base_rate, 0))

  # Rename columns for clarity
  rates_wide <- rates_wide %>%
    rename(
      rate_232 = rate_section_232,
      rate_301 = rate_section_301,
      rate_ieepa_recip = rate_ieepa_reciprocal,
      rate_ieepa_fent = rate_ieepa_fentanyl
    )

  # Apply stacking rules (vectorized)
  rates_final <- rates_wide %>%
    mutate(
      total_additional = case_when(
        # China: max(232, reciprocal) + fentanyl + 301 + other
        country == CTY_CHINA ~
          pmax(rate_232, rate_ieepa_recip) + rate_ieepa_fent + rate_301 + rate_other,

        # Others with 232: 232 + other
        rate_232 > 0 ~ rate_232 + rate_other,

        # Others: reciprocal + fentanyl + other
        TRUE ~ rate_ieepa_recip + rate_ieepa_fent + rate_other
      ),
      total_rate = base_rate + total_additional
    )

  return(rates_final)
}


#' Check if country applies to a Chapter 99 entry
#'
#' @param country Census country code
#' @param country_type Type from Ch99 data
#' @param countries List of applicable countries
#' @param exempt List of exempt countries
#' @return Logical
check_country_applies <- function(country, country_type, countries, exempt) {
  # Convert Census to ISO for matching
  country_iso <- names(ISO_TO_CENSUS)[match(country, ISO_TO_CENSUS)]
  if (is.na(country_iso)) country_iso <- country

  switch(
    country_type,
    'all' = TRUE,
    'all_except' = !(country_iso %in% exempt),
    'specific' = country_iso %in% countries || country %in% countries,
    'unknown' = TRUE,  # Assume applies if unknown
    FALSE
  )
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  setwd('C:/Users/ji252/Documents/GitHub/tariff_rate_tracker')

  # Load data
  ch99_data <- readRDS('data/processed/chapter99_rates.rds')
  products <- readRDS('data/processed/products_rev32.rds')

  # Load country codes
  census_codes <- read_csv('resources/census_codes.csv', col_types = cols(.default = col_character()))
  countries <- census_codes$Code

  message('Loaded ', length(countries), ' countries')

  # Calculate rates (use fast method)
  rates <- calculate_rates_fast(products, ch99_data, countries)

  # Summary
  cat('\n=== Rate Summary ===\n')
  cat('Total product-country pairs with duties: ', nrow(rates), '\n')

  cat('\nTop countries by mean additional rate:\n')
  rates %>%
    group_by(country) %>%
    summarise(
      n_products = n(),
      mean_additional = mean(total_additional),
      mean_total = mean(total_rate),
      .groups = 'drop'
    ) %>%
    arrange(desc(mean_additional)) %>%
    head(10) %>%
    print()

  # Save
  saveRDS(rates, 'data/processed/rates_rev32.rds')
  message('\nSaved rates to data/processed/rates_rev32.rds')

  # Also save CSV for inspection
  write_csv(rates, 'data/processed/rates_rev32.csv')
  message('Saved rates to data/processed/rates_rev32.csv')
}
