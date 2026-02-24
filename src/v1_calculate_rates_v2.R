# =============================================================================
# Calculate Tariff Rates v2 - Handling Universal Tariffs
# =============================================================================
#
# Key insight: Some tariffs (IEEPA reciprocal) apply UNIVERSALLY based on
# country, not via product footnotes. We need two types of rate application:
#
# 1. FOOTNOTE-BASED (Section 301, Section 232):
#    - Products have footnotes referencing Chapter 99 subheadings
#    - Rate applies if product has the footnote AND country matches
#
# 2. UNIVERSAL (IEEPA reciprocal/fentanyl):
#    - Applies to ALL products from specified countries
#    - Not referenced in individual product footnotes
#    - Has exemption lists (specific subheadings/products exempt)
#
# =============================================================================

library(tidyverse)
library(here)

source(here('src', 'helpers.R'))

# =============================================================================
# Constants
# =============================================================================

.pp_v1 <- tryCatch(load_policy_params(), error = function(e) NULL)
CTY_CHINA  <- if (!is.null(.pp_v1)) .pp_v1$CTY_CHINA  else '5700'
CTY_CANADA <- if (!is.null(.pp_v1)) .pp_v1$CTY_CANADA else '1220'
CTY_MEXICO <- if (!is.null(.pp_v1)) .pp_v1$CTY_MEXICO else '2010'
CTY_RUSSIA <- '4621'

# Country name to Census code mapping
COUNTRY_NAME_TO_CODE <- c(
  'China' = '5700', 'Canada' = '1220', 'Mexico' = '2010',
  'Japan' = '5880', 'United Kingdom' = '4120', 'Germany' = '4280',
  'France' = '4279', 'Italy' = '4759', 'South Korea' = '5800',
  'Korea, South' = '5800', 'Taiwan' = '5830', 'Australia' = '6021',
  'Brazil' = '3510', 'India' = '5330', 'Vietnam' = '5520',
  'Thailand' = '5490', 'Indonesia' = '5600', 'Malaysia' = '5570',
  'Singapore' = '5590', 'Russia' = '4621', 'Russian Federation' = '4621',
  'Afghanistan' = '5310', 'Argentina' = '3570', 'Austria' = '4330',
  'Belgium' = '4211', 'Netherlands' = '4210', 'Spain' = '4699',
  'Poland' = '4550', 'Sweden' = '4010', 'Switzerland' = '4419',
  'Ireland' = '4190', 'Norway' = '4030', 'Denmark' = '4099',
  'Finland' = '4011', 'New Zealand' = '6141', 'Chile' = '3370',
  'Colombia' = '3010', 'Peru' = '3330', 'Philippines' = '5650',
  'Bangladesh' = '5380', 'Pakistan' = '5350', 'Sri Lanka' = '5460',
  'Turkey' = '4890', 'Israel' = '5081', 'Saudi Arabia' = '5170',
  'United Arab Emirates' = '5200', 'South Africa' = '7910'
)

# IEEPA rates by country (from TPC and HTS analysis)
# These are UNIVERSAL rates applied based on country
IEEPA_RECIPROCAL_RATES <- list(
  # Default 10% for most countries
  default = 0.10,
  # Exempt countries (0% reciprocal)
  exempt = c('1220', '2010', '6021'),  # Canada, Mexico, Australia (FTA)
  # Higher rates for specific countries
  elevated = list(
    '5700' = 0.145,  # China
    '5880' = 0.15,   # Japan - based on TPC data
    '4280' = 0.15,   # Germany - based on TPC data (EU)
    '4279' = 0.15    # France - based on TPC data (EU)
  )
)

# IEEPA fentanyl rates
IEEPA_FENTANYL_RATES <- list(
  '5700' = 0.20,  # China
  '1220' = 0.25,  # Canada
  '2010' = 0.25   # Mexico
)


# =============================================================================
# Universal Rate Functions
# =============================================================================

#' Get IEEPA reciprocal rate for a country
#'
#' @param country Census country code
#' @return Rate (numeric)
get_ieepa_reciprocal_rate <- function(country) {
  # Check exemptions
  if (country %in% IEEPA_RECIPROCAL_RATES$exempt) {
    return(0)
  }

  # Check elevated rates
  if (country %in% names(IEEPA_RECIPROCAL_RATES$elevated)) {
    return(IEEPA_RECIPROCAL_RATES$elevated[[country]])
  }

  # Default rate
  return(IEEPA_RECIPROCAL_RATES$default)
}


#' Get IEEPA fentanyl rate for a country
#'
#' @param country Census country code
#' @return Rate (numeric)
get_ieepa_fentanyl_rate <- function(country) {
  if (country %in% names(IEEPA_FENTANYL_RATES)) {
    return(IEEPA_FENTANYL_RATES[[country]])
  }
  return(0)
}


# =============================================================================
# Main Calculation
# =============================================================================

#' Calculate rates with universal tariff support
#'
#' @param products Product data with ch99_refs
#' @param ch99 Chapter 99 data
#' @param countries Vector of country codes
#' @param apply_universal Whether to apply IEEPA universal rates
#' @return Rates tibble
calculate_rates_v2 <- function(products, ch99, countries, apply_universal = TRUE) {
  message('Calculating rates (v2 with universal tariffs)...')

  # Part 1: Footnote-based rates (Section 301, Section 232)
  message('  Processing footnote-based rates...')

  products_with_refs <- products %>%
    filter(n_ch99_refs > 0)

  # Expand and join with Ch99
  product_refs <- products_with_refs %>%
    select(hts10, base_rate, ch99_refs) %>%
    mutate(ch99_refs = str_split(ch99_refs, ';')) %>%
    unnest(ch99_refs) %>%
    rename(ch99_code = ch99_refs) %>%
    filter(ch99_code != '')

  # Filter to Section 301 and Section 232 only (footnote-based)
  footnote_based_ch99 <- ch99 %>%
    filter(
      str_detect(ch99_code, '^9903\\.8') |  # Section 301/232
      str_detect(ch99_code, '^9903\\.4')    # Section 201
    ) %>%
    filter(!is.na(rate))

  message('  Footnote-based Ch99 entries: ', nrow(footnote_based_ch99))

  product_footnote_rates <- product_refs %>%
    inner_join(
      footnote_based_ch99 %>% select(ch99_code, rate, country_type, countries),
      by = 'ch99_code'
    )

  message('  Product-footnote pairs: ', nrow(product_footnote_rates))

  # Part 2: Calculate rates for each country
  message('  Processing countries...')

  results <- list()
  pb <- txtProgressBar(min = 0, max = length(countries), style = 3)

  for (i in seq_along(countries)) {
    setTxtProgressBar(pb, i)
    cty <- countries[i]

    # Get universal IEEPA rates for this country
    ieepa_recip <- if (apply_universal) get_ieepa_reciprocal_rate(cty) else 0
    ieepa_fent <- if (apply_universal) get_ieepa_fentanyl_rate(cty) else 0

    # Get footnote-based rates for this country
    # Filter to Ch99 entries that apply (mainly China for 301)
    cty_footnote_rates <- product_footnote_rates %>%
      filter(
        country_type == 'all' |
        (country_type == 'specific' & (
          (str_detect(countries, 'CN') & cty == CTY_CHINA) |
          (str_detect(countries, 'CA') & cty == CTY_CANADA) |
          (str_detect(countries, 'MX') & cty == CTY_MEXICO) |
          (str_detect(countries, 'RU') & cty == CTY_RUSSIA)
        )) |
        country_type == 'all_except'  # TODO: check exemptions
      )

    if (nrow(cty_footnote_rates) == 0 && ieepa_recip == 0 && ieepa_fent == 0) {
      next
    }

    # Aggregate footnote rates by product
    footnote_by_product <- cty_footnote_rates %>%
      group_by(hts10, base_rate) %>%
      summarise(
        rate_232 = max(rate[str_detect(ch99_code, '^9903\\.8[0-4]')], 0, na.rm = TRUE),
        rate_301 = sum(rate[str_detect(ch99_code, '^9903\\.8[5-9]')], na.rm = TRUE),
        rate_201 = sum(rate[str_detect(ch99_code, '^9903\\.4')], na.rm = TRUE),
        .groups = 'drop'
      )

    # Get all products (for universal tariffs)
    if (ieepa_recip > 0 || ieepa_fent > 0) {
      all_products <- products %>%
        select(hts10, base_rate)
    } else {
      all_products <- footnote_by_product %>% select(hts10, base_rate)
    }

    # Combine with footnote rates
    combined <- all_products %>%
      left_join(footnote_by_product %>% select(-base_rate), by = 'hts10') %>%
      mutate(
        rate_232 = coalesce(rate_232, 0),
        rate_301 = coalesce(rate_301, 0),
        rate_201 = coalesce(rate_201, 0),
        ieepa_recip = ieepa_recip,
        ieepa_fent = ieepa_fent,
        base_rate = coalesce(base_rate, 0)
      )

    # Apply stacking rules
    combined <- combined %>%
      mutate(
        country = cty,
        total_additional = case_when(
          # China: max(232, reciprocal) + fentanyl + 301 + 201
          country == CTY_CHINA ~
            pmax(rate_232, ieepa_recip) + ieepa_fent + rate_301 + rate_201,

          # Others with 232: 232 takes precedence over reciprocal
          rate_232 > 0 ~ rate_232 + rate_201,

          # Others: reciprocal + fentanyl + 201
          TRUE ~ ieepa_recip + ieepa_fent + rate_201
        ),
        total_rate = base_rate + total_additional
      )

    # Only keep products with duties
    combined <- combined %>%
      filter(total_additional > 0)

    if (nrow(combined) > 0) {
      results[[cty]] <- combined
    }
  }

  close(pb)

  rates <- bind_rows(results)
  message('\n  Total product-country rates: ', nrow(rates))

  return(rates)
}


# =============================================================================
# TPC Comparison
# =============================================================================

compare_to_tpc <- function(rates, tpc_path) {
  message('\nComparing to TPC data...')

  tpc <- read_csv(tpc_path, col_types = cols(.default = col_character()))

  date_cols <- setdiff(names(tpc), c('country', 'hts10'))

  tpc_long <- tpc %>%
    pivot_longer(
      cols = all_of(date_cols),
      names_to = 'date',
      values_to = 'tpc_rate'
    ) %>%
    mutate(tpc_rate = as.numeric(tpc_rate))

  # Map country names
  tpc_long <- tpc_long %>%
    mutate(country_code = COUNTRY_NAME_TO_CODE[country]) %>%
    filter(!is.na(country_code))

  message('  TPC rows: ', nrow(tpc_long))

  # Join
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
      match = abs_diff < 0.02
    )

  # Summary by date
  message('\n=== TPC Comparison (v2) ===')
  for (d in unique(comparison$date)) {
    comp_d <- comparison %>% filter(date == d)
    n_match <- sum(comp_d$match)
    n_total <- nrow(comp_d)
    pct_match <- round(100 * n_match / n_total, 1)
    mean_diff <- round(mean(comp_d$abs_diff) * 100, 2)
    message(d, ': ', pct_match, '% match (within 2pp), mean diff = ', mean_diff, ' pp')
  }

  # Summary by country
  message('\n=== By Country (Nov 17) ===')
  comparison %>%
    filter(date == '2025-11-17') %>%
    group_by(country) %>%
    summarise(
      n = n(),
      pct_match = round(mean(match) * 100, 1),
      mean_diff = round(mean(diff) * 100, 2),
      .groups = 'drop'
    ) %>%
    arrange(pct_match) %>%
    head(15) %>%
    print()

  return(comparison)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)

  # Load data
  ch99 <- read_csv(here('data', 'processed', 'chapter99_raw.csv'),
                   col_types = cols(.default = col_character())) %>%
    mutate(rate = as.numeric(rate))

  products <- read_csv(here('data', 'processed', 'products_raw.csv'),
                       col_types = cols(.default = col_character())) %>%
    mutate(
      base_rate = as.numeric(base_rate),
      n_ch99_refs = as.integer(n_ch99_refs)
    )

  census <- read_csv(here('resources', 'census_codes.csv'),
                     col_types = cols(.default = col_character()))
  countries <- census$Code

  message('Loaded ', nrow(products), ' products, ', nrow(ch99), ' Ch99 entries')

  # Calculate with universal tariffs
  rates <- calculate_rates_v2(products, ch99, countries, apply_universal = TRUE)

  # Save
  write_csv(rates, here('data', 'processed', 'rates_v2.csv'))

  # Summary
  cat('\n=== Rate Summary ===\n')
  rates %>%
    group_by(country) %>%
    summarise(
      n = n(),
      mean_add = round(mean(total_additional) * 100, 1),
      .groups = 'drop'
    ) %>%
    filter(n > 100) %>%
    arrange(desc(mean_add)) %>%
    head(10) %>%
    left_join(census, by = c('country' = 'Code')) %>%
    select(Name, n, mean_add) %>%
    print()

  # Compare to TPC
  comparison <- compare_to_tpc(rates, here('data', 'tpc', 'tariff_by_flow_day.csv'))
  write_csv(comparison, here('output', 'tpc_comparison_v2.csv'))
}
