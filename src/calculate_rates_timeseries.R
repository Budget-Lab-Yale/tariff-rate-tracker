# =============================================================================
# Calculate Tariff Rates - Time-Series Version
# =============================================================================
#
# For each TPC date, uses the appropriate HTS revision to calculate rates.
# This handles the fact that tariff policy changed over 2025:
#   - March 17: No IEEPA reciprocal (only fentanyl for CN/CA/MX)
#   - April 17: IEEPA reciprocal at 10%
#   - July 17: Still 10%
#   - Oct/Nov 17: Rates increased to 15%+ (via 9903.02.xx)
#
# =============================================================================

library(tidyverse)

# =============================================================================
# Configuration
# =============================================================================

# Map TPC dates to HTS revisions and policy states
TPC_DATE_CONFIG <- list(
  '2025-03-17' = list(
    revision = 'rev_6',
    ieepa_reciprocal = FALSE,  # Not yet in effect
    rate_increase = FALSE
  ),
  '2025-04-17' = list(
    revision = 'rev_10',
    ieepa_reciprocal = TRUE,   # 10% since April 9
    rate_increase = FALSE
  ),
  '2025-07-17' = list(
    revision = 'rev_17',
    ieepa_reciprocal = TRUE,   # Still 10%
    rate_increase = FALSE
  ),
  '2025-10-17' = list(
    revision = 'rev_18',
    ieepa_reciprocal = TRUE,
    rate_increase = TRUE       # 15%+ since August 7
  ),
  '2025-11-17' = list(
    revision = 'rev_32',
    ieepa_reciprocal = TRUE,
    rate_increase = TRUE
  )
)

# Census country codes
CTY_CHINA <- '5700'
CTY_CANADA <- '1220'
CTY_MEXICO <- '2010'

# Country name to Census code mapping
COUNTRY_NAME_TO_CODE <- c(
  'Afghanistan' = '5310', 'Argentina' = '3570', 'Australia' = '6021',
  'Austria' = '4330', 'Bangladesh' = '5380', 'Belgium' = '4211',
  'Brazil' = '3510', 'Canada' = '1220', 'Chile' = '3370',
  'China' = '5700', 'Colombia' = '3010', 'Denmark' = '4099',
  'Finland' = '4011', 'France' = '4279', 'Germany' = '4280',
  'India' = '5330', 'Indonesia' = '5600', 'Ireland' = '4190',
  'Israel' = '5081', 'Italy' = '4759', 'Japan' = '5880',
  'Korea, South' = '5800', 'South Korea' = '5800',
  'Malaysia' = '5570', 'Mexico' = '2010', 'Netherlands' = '4210',
  'New Zealand' = '6141', 'Norway' = '4030', 'Pakistan' = '5350',
  'Peru' = '3330', 'Philippines' = '5650', 'Poland' = '4550',
  'Russia' = '4621', 'Russian Federation' = '4621',
  'Saudi Arabia' = '5170', 'Singapore' = '5590', 'South Africa' = '7910',
  'Spain' = '4699', 'Sri Lanka' = '5460', 'Sweden' = '4010',
  'Switzerland' = '4419', 'Taiwan' = '5830', 'Thailand' = '5490',
  'Turkey' = '4890', 'United Arab Emirates' = '5200',
  'United Kingdom' = '4120', 'Vietnam' = '5520'
)

# Country-specific IEEPA rates when rate_increase = TRUE (from 9903.02.xx)
# These are the rates effective August 7, 2025+
IEEPA_RATES_INCREASED <- list(
  '5310' = 0.15,  # Afghanistan
  '3570' = 0.10,  # Argentina
  '6021' = 0.10,  # Australia
  '4330' = 0.20,  # Austria (EU)
  '5380' = 0.35,  # Bangladesh
  '4211' = 0.20,  # Belgium (EU)
  '3510' = 0.10,  # Brazil
  '1220' = 0.25,  # Canada (fentanyl only, no reciprocal)
  '3370' = 0.10,  # Chile
  '5700' = 0.145, # China (reciprocal, stacks with fentanyl)
  '3010' = 0.10,  # Colombia
  '4099' = 0.15,  # Denmark (EU)
  '4011' = 0.15,  # Finland (EU)
  '4279' = 0.20,  # France (EU)
  '4280' = 0.20,  # Germany (EU)
  '5330' = 0.25,  # India
  '5600' = 0.30,  # Indonesia
  '4190' = 0.20,  # Ireland (EU)
  '5081' = 0.15,  # Israel
  '4759' = 0.20,  # Italy (EU)
  '5880' = 0.25,  # Japan
  '5800' = 0.25,  # South Korea
  '5570' = 0.25,  # Malaysia
  '2010' = 0.25,  # Mexico (fentanyl only, no reciprocal)
  '4210' = 0.20,  # Netherlands (EU)
  '6141' = 0.10,  # New Zealand
  '4030' = 0.15,  # Norway
  '5350' = 0.30,  # Pakistan
  '3330' = 0.10,  # Peru
  '5650' = 0.15,  # Philippines
  '4550' = 0.20,  # Poland (EU)
  '4621' = 0.00,  # Russia (has Section 232 instead)
  '5170' = 0.10,  # Saudi Arabia
  '5590' = 0.10,  # Singapore
  '7910' = 0.30,  # South Africa
  '4699' = 0.20,  # Spain (EU)
  '5460' = 0.41,  # Sri Lanka
  '4010' = 0.20,  # Sweden (EU)
  '4419' = 0.30,  # Switzerland
  '5830' = 0.30,  # Taiwan
  '5490' = 0.35,  # Thailand
  '4890' = 0.10,  # Turkey
  '5200' = 0.10,  # UAE
  '4120' = 0.10,  # UK
  '5520' = 0.45   # Vietnam
)

# IEEPA rates when rate_increase = FALSE (before August 7, 2025)
# 10% baseline for most countries, with exemptions
IEEPA_RATES_BASELINE <- list(
  default = 0.10,
  exempt = c('1220', '2010')  # Canada, Mexico exempt from reciprocal
)

# Fentanyl rates (apply to CN/CA/MX only)
FENTANYL_RATES <- list(
  '5700' = 0.20,  # China
  '1220' = 0.25,  # Canada
  '2010' = 0.25   # Mexico
)


# =============================================================================
# Helper Functions
# =============================================================================

#' Get IEEPA reciprocal rate for a country given policy state
get_ieepa_rate <- function(country, rate_increase, ieepa_active) {
  if (!ieepa_active) {
    return(0)
  }

  if (rate_increase) {
    # Use country-specific rates from 9903.02.xx
    if (country %in% names(IEEPA_RATES_INCREASED)) {
      return(IEEPA_RATES_INCREASED[[country]])
    }
    return(0.15)  # Default increased rate
  } else {
    # Use baseline 10% rates
    if (country %in% IEEPA_RATES_BASELINE$exempt) {
      return(0)  # Canada/Mexico exempt from reciprocal
    }
    return(IEEPA_RATES_BASELINE$default)
  }
}

#' Get fentanyl rate for a country
get_fentanyl_rate <- function(country) {
  if (country %in% names(FENTANYL_RATES)) {
    return(FENTANYL_RATES[[country]])
  }
  return(0)
}


# =============================================================================
# Main Calculation
# =============================================================================

#' Calculate rates for all products/countries for a specific TPC date
calculate_rates_for_date <- function(date_str, products, tpc_countries) {
  config <- TPC_DATE_CONFIG[[date_str]]
  if (is.null(config)) {
    stop('Unknown TPC date: ', date_str)
  }

  message('Processing date: ', date_str)
  message('  Revision: ', config$revision)
  message('  IEEPA reciprocal: ', config$ieepa_reciprocal)
  message('  Rate increase: ', config$rate_increase)

  results <- list()

  for (cty in tpc_countries) {
    # Get IEEPA rate for this country
    ieepa_rate <- get_ieepa_rate(cty, config$rate_increase, config$ieepa_reciprocal)
    fentanyl_rate <- get_fentanyl_rate(cty)

    # Calculate total additional rate
    # Stacking: IEEPA reciprocal + fentanyl (for CN/CA/MX)
    # Note: For Canada/Mexico before rate_increase, reciprocal is 0, only fentanyl applies
    total_additional <- ieepa_rate + fentanyl_rate

    if (total_additional > 0) {
      results[[cty]] <- tibble(
        country = cty,
        date = date_str,
        ieepa_rate = ieepa_rate,
        fentanyl_rate = fentanyl_rate,
        total_additional = total_additional
      )
    }
  }

  return(bind_rows(results))
}


#' Calculate rates for all TPC dates and compare
calculate_and_compare <- function(tpc_path) {
  message('Loading TPC data...')

  tpc <- read_csv(tpc_path, col_types = cols(.default = col_character()))

  # Get unique countries in TPC
  tpc_countries <- unique(tpc$country)
  tpc_countries_codes <- COUNTRY_NAME_TO_CODE[tpc_countries]
  tpc_countries_codes <- tpc_countries_codes[!is.na(tpc_countries_codes)]

  message('  TPC countries: ', length(tpc_countries_codes))

  # Get date columns
  date_cols <- setdiff(names(tpc), c('country', 'hts10'))
  message('  TPC dates: ', paste(date_cols, collapse = ', '))

  # Pivot TPC to long format
  tpc_long <- tpc %>%
    pivot_longer(
      cols = all_of(date_cols),
      names_to = 'date',
      values_to = 'tpc_rate'
    ) %>%
    mutate(
      tpc_rate = as.numeric(tpc_rate),
      country_code = COUNTRY_NAME_TO_CODE[country]
    ) %>%
    filter(!is.na(country_code))

  message('  TPC rows: ', nrow(tpc_long))

  # Calculate our rates for each date
  all_rates <- list()

  for (date_str in date_cols) {
    rates <- calculate_rates_for_date(date_str, NULL, unique(tpc_countries_codes))
    all_rates[[date_str]] <- rates
  }

  all_rates_df <- bind_rows(all_rates)

  # Join with TPC
  comparison <- tpc_long %>%
    left_join(
      all_rates_df %>% select(country, date, our_rate = total_additional),
      by = c('country_code' = 'country', 'date')
    ) %>%
    mutate(
      our_rate = coalesce(our_rate, 0),
      tpc_rate = coalesce(tpc_rate, 0),
      diff = our_rate - tpc_rate,
      abs_diff = abs(diff),
      match_exact = abs_diff < 0.001,
      match_2pp = abs_diff < 0.02
    )

  # Summary by date
  message('\n=== Comparison Summary ===')
  for (d in date_cols) {
    comp_d <- comparison %>% filter(date == d)
    n_exact <- sum(comp_d$match_exact)
    n_2pp <- sum(comp_d$match_2pp)
    n_total <- nrow(comp_d)
    pct_exact <- round(100 * n_exact / n_total, 1)
    pct_2pp <- round(100 * n_2pp / n_total, 1)
    mean_diff <- round(mean(comp_d$abs_diff) * 100, 2)

    message(d, ': ', pct_exact, '% exact, ', pct_2pp, '% within 2pp, mean diff = ', mean_diff, ' pp')
  }

  # Show mismatches by country for latest date
  message('\n=== Mismatches by Country (Nov 17) ===')
  comparison %>%
    filter(date == '2025-11-17', !match_2pp) %>%
    group_by(country) %>%
    summarise(
      n_mismatch = n(),
      mean_diff = round(mean(diff) * 100, 2),
      our_rate_sample = first(our_rate),
      tpc_rate_sample = first(tpc_rate),
      .groups = 'drop'
    ) %>%
    arrange(desc(n_mismatch)) %>%
    head(10) %>%
    print()

  return(comparison)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  setwd('C:/Users/ji252/Documents/GitHub/tariff_rate_tracker')

  comparison <- calculate_and_compare('data/tpc/tariff_by_flow_day.csv')

  write_csv(comparison, 'output/tpc_comparison_timeseries.csv')
  message('\nSaved comparison to output/tpc_comparison_timeseries.csv')

  # Detailed analysis
  message('\n=== Rate Distribution by Date ===')
  comparison %>%
    group_by(date) %>%
    summarise(
      mean_tpc = round(mean(tpc_rate) * 100, 2),
      mean_our = round(mean(our_rate) * 100, 2),
      .groups = 'drop'
    ) %>%
    print()
}
