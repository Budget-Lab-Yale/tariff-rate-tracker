# =============================================================================
# Calculate Tariff Rates v3 - Time-Series with Section 301 (Vectorized)
# =============================================================================

library(tidyverse)
library(here)

source(here('src', 'helpers.R'))

# =============================================================================
# Configuration
# =============================================================================

.pp_v1 <- tryCatch(load_policy_params(), error = function(e) NULL)
CTY_CHINA  <- if (!is.null(.pp_v1)) .pp_v1$CTY_CHINA  else '5700'
CTY_CANADA <- if (!is.null(.pp_v1)) .pp_v1$CTY_CANADA else '1220'
CTY_MEXICO <- if (!is.null(.pp_v1)) .pp_v1$CTY_MEXICO else '2010'

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

# Fentanyl rates
FENTANYL_RATES <- tibble(
  country_code = c('5700', '1220', '2010'),
  fentanyl_rate = c(0.20, 0.25, 0.25)
)

# Section 301 mapping — includes original lists (9903.88.xx) and Biden
# acceleration (9903.91.xx). Products reference these via footnotes.
# No product has both 9903.88.xx and 9903.91.xx refs (separate product sets).
SECTION_301_RATES <- tribble(
  ~ch99_pattern, ~s301_rate,
  # Original Section 301 (Lists 1-4, 2018-2019)
  '9903.88.01', 0.25,
  '9903.88.02', 0.25,
  '9903.88.03', 0.25,
  '9903.88.04', 0.25,
  '9903.88.09', 0.10,
  '9903.88.15', 0.075,
  '9903.88.16', 0.15,
  # Biden Section 301 acceleration (U.S. note 31, effective 2024-2025)
  '9903.91.01', 0.25,   # Note 31(b): critical minerals, steel/aluminum inputs
  '9903.91.02', 0.50,   # Note 31(c)
  '9903.91.03', 1.00,   # Note 31(d): EVs, EV batteries, medical
  '9903.91.04', 0.25,   # Note 31(e): transitional (Jan-Dec 2025)
  '9903.91.05', 0.50,   # Note 31(f): semiconductors, solar cells
  '9903.91.11', 0.25    # Note 31(j): tungsten
)

# Section 232 product identification
# Steel: HTS chapters 72-73; Aluminum: HTS chapter 76
# Products in these chapters are subject to Section 232 duties.
# The 232 Ch99 entries (9903.80.xx for steel, 9903.85.01-02 for aluminum)
# describe which products they cover via "note 16" references, rather than
# products having footnotes pointing to them — so we identify by chapter.
SECTION_232_CHAPTERS <- c('72', '73', '76')


# =============================================================================
# Main Calculation
# =============================================================================

calculate_rates_v3 <- function(products, tpc_path, ieepa_path, usmca_path) {
  message('Loading TPC data...')

  tpc <- read_csv(tpc_path, col_types = cols(.default = col_character()))
  date_cols <- setdiff(names(tpc), c('country', 'hts10'))

  tpc_long <- tpc %>%
    pivot_longer(cols = all_of(date_cols), names_to = 'date', values_to = 'tpc_rate') %>%
    mutate(
      tpc_rate = as.numeric(tpc_rate),
      country_code = COUNTRY_NAME_TO_CODE[country]
    ) %>%
    filter(!is.na(country_code))

  message('  TPC rows: ', nrow(tpc_long))

  # ---------------------------------------------------------------------------
  # Load HTS-derived IEEPA country rates (from 05_parse_policy_params.R)
  # ---------------------------------------------------------------------------
  message('Loading HTS-derived IEEPA rates...')

  ieepa_all <- read_csv(ieepa_path, col_types = cols(.default = col_character())) %>%
    filter(terminated == 'FALSE') %>%
    mutate(rate = as.numeric(rate))

  # Phase 2 entries for non-China countries (surcharge/floor)
  ieepa_phase2 <- ieepa_all %>% filter(phase == 'phase2_aug7')

  # Floor countries: "X%" total duty (EU, Japan, South Korea)
  # These pay max(base_rate, floor) instead of base_rate + surcharge
  ieepa_floor <- ieepa_phase2 %>%
    filter(rate_type == 'floor') %>%
    distinct(census_code, rate) %>%
    rename(country_code = census_code, ieepa_floor = rate)

  floor_codes <- ieepa_floor$country_code

  # Surcharge countries: "+X%" additional duty (most countries)
  # Exclude countries with floor entries to avoid double-counting.
  # Take max rate per country to handle duplicate census codes.
  ieepa_surcharge <- ieepa_phase2 %>%
    filter(rate_type == 'surcharge', !(census_code %in% floor_codes)) %>%
    group_by(census_code) %>%
    summarise(rate = max(rate), .groups = 'drop') %>%
    rename(country_code = census_code, ieepa_surcharge = rate)

  message('  Surcharge countries: ', nrow(ieepa_surcharge))
  message('  Floor countries: ', nrow(ieepa_floor))

  # China's IEEPA reciprocal: Phase 1 entry 9903.01.63 (+34%), not in Phase 2.
  # China was not suspended during the Phase 1 → Phase 2 transition.
  china_reciprocal <- ieepa_all %>%
    filter(census_code == CTY_CHINA, rate_type == 'surcharge') %>%
    pull(rate) %>%
    max()

  CHINA_IEEPA_RECIPROCAL <- if (is.finite(china_reciprocal)) china_reciprocal else 0
  message('  China IEEPA reciprocal: ', CHINA_IEEPA_RECIPROCAL * 100, '%')

  # ---------------------------------------------------------------------------
  # Load HTS-derived USMCA eligibility (from 05_parse_policy_params.R)
  # ---------------------------------------------------------------------------
  message('Loading HTS-derived USMCA eligibility...')

  usmca <- read_csv(usmca_path, col_types = cols(
    hts10 = col_character(), usmca_eligible = col_logical()
  ))

  message('  USMCA eligible products: ', sum(usmca$usmca_eligible),
          ' (', round(100 * mean(usmca$usmca_eligible), 1), '%)')

  # ---------------------------------------------------------------------------
  # Section 301 rates by product (for China only)
  # ---------------------------------------------------------------------------
  message('Calculating Section 301 rates by product...')

  products_s301 <- products %>%
    filter(!is.na(ch99_refs), ch99_refs != '') %>%
    select(hts10, ch99_refs)

  s301_by_product <- products_s301 %>%
    mutate(refs = str_split(ch99_refs, ';')) %>%
    unnest(refs) %>%
    inner_join(SECTION_301_RATES, by = c('refs' = 'ch99_pattern')) %>%
    group_by(hts10) %>%
    summarise(s301_rate = sum(s301_rate), .groups = 'drop')

  message('  Products with Section 301: ', nrow(s301_by_product))

  # ---------------------------------------------------------------------------
  # Join all data
  # ---------------------------------------------------------------------------
  message('Joining data...')

  results <- tpc_long %>%
    left_join(products %>% select(hts10, base_rate), by = 'hts10') %>%
    left_join(s301_by_product, by = 'hts10') %>%
    left_join(ieepa_surcharge, by = 'country_code') %>%
    left_join(ieepa_floor, by = 'country_code') %>%
    left_join(FENTANYL_RATES, by = 'country_code') %>%
    left_join(usmca, by = 'hts10') %>%
    mutate(
      base_rate = as.numeric(base_rate),
      s301_rate = coalesce(s301_rate, 0),
      fentanyl_rate = coalesce(fentanyl_rate, 0),
      usmca_eligible = coalesce(usmca_eligible, FALSE)
    )

  # ---------------------------------------------------------------------------
  # Calculate rates by date
  # ---------------------------------------------------------------------------
  message('Calculating rates by date...')

  results <- results %>%
    mutate(
      # Policy flags by date
      ieepa_active = date >= '2025-04-17',
      rate_increase = date >= '2025-10-17',

      # Section 232 identification and rates
      is_232 = substr(hts10, 1, 2) %in% SECTION_232_CHAPTERS,
      s232_rate = case_when(
        !is_232 ~ 0,
        date >= '2025-07-17' ~ 0.50,
        TRUE ~ 0.25
      ),

      # IEEPA reciprocal rate (depends on date, country, and rate structure)
      # China: Phase 1 entry 9903.01.63 (not in Phase 2 range)
      # Floor countries (EU, Japan, S. Korea): additional = max(0, floor - base_rate)
      # Surcharge countries: additional = surcharge rate
      # Default: 10% baseline (Apr-Jul) or 10% for unlisted countries
      ieepa_rate = case_when(
        !ieepa_active ~ 0,
        # China: separate IEEPA reciprocal rate
        country_code == CTY_CHINA ~ CHINA_IEEPA_RECIPROCAL,
        # After rate increase: use HTS-parsed country-specific rates
        rate_increase & !is.na(ieepa_floor) ~
          pmax(0, ieepa_floor - coalesce(base_rate, 0)),
        rate_increase & !is.na(ieepa_surcharge) ~ ieepa_surcharge,
        rate_increase ~ 0.10,  # Default for unlisted countries
        TRUE ~ 0.10  # April-July baseline
      ),

      # Canada/Mexico IEEPA reciprocal (separate from other countries)
      # Canada faces reciprocal tariffs starting Oct 2025
      ieepa_rate_camx = case_when(
        country_code == CTY_CANADA & date >= '2025-10-17' ~ 0.10,
        TRUE ~ 0
      ),

      # USMCA exemption factor: eligible products from CA/MX pay no IEEPA
      usmca_factor = ifelse(
        usmca_eligible & country_code %in% c(CTY_CANADA, CTY_MEXICO), 0, 1
      ),

      # Total rate with stacking rules (from Tariff-ETRs):
      #   China: max(232, reciprocal) + fentanyl + 301
      #   Canada/Mexico: s232 + (reciprocal + fentanyl) * usmca_factor
      #     USMCA-eligible products exempt from all IEEPA tariffs
      #     Section 232 applies regardless of USMCA status
      #   Others with 232: 232 takes precedence over reciprocal + fentanyl
      #   Others without 232: reciprocal + fentanyl
      our_rate = case_when(
        country_code == CTY_CHINA ~
          pmax(s232_rate, ieepa_rate) + fentanyl_rate + s301_rate,
        country_code %in% c(CTY_CANADA, CTY_MEXICO) ~
          s232_rate + (ieepa_rate_camx + fentanyl_rate) * usmca_factor,
        s232_rate > 0 ~ s232_rate,
        TRUE ~ ieepa_rate + fentanyl_rate
      ),

      # Comparison
      diff = our_rate - tpc_rate,
      abs_diff = abs(diff),
      match_exact = abs_diff < 0.005,
      match_2pp = abs_diff < 0.02
    )

  # Summary
  message('\n=== Comparison Summary ===')
  for (d in date_cols) {
    comp_d <- results %>% filter(date == d)
    pct_exact <- round(100 * mean(comp_d$match_exact), 1)
    pct_2pp <- round(100 * mean(comp_d$match_2pp), 1)
    mean_diff <- round(mean(comp_d$abs_diff) * 100, 2)
    message(d, ': ', pct_exact, '% exact, ', pct_2pp, '% within 2pp, mean diff = ', mean_diff, ' pp')
  }

  # By country for Nov
  message('\n=== Worst Countries (Nov 17) ===')
  results %>%
    filter(date == '2025-11-17') %>%
    group_by(country) %>%
    summarise(
      n = n(),
      pct_exact = round(mean(match_exact) * 100, 1),
      mean_diff = round(mean(diff) * 100, 2),
      .groups = 'drop'
    ) %>%
    arrange(pct_exact) %>%
    head(10) %>%
    print()

  return(results)
}


# =============================================================================
# Main
# =============================================================================

if (sys.nframe() == 0) {
  library(here)

  products <- read_csv(here('data', 'processed', 'products_raw.csv'),
                       col_types = cols(.default = col_character()))

  message('Loaded ', nrow(products), ' products')

  results <- calculate_rates_v3(
    products,
    tpc_path = here('data', 'tpc', 'tariff_by_flow_day.csv'),
    ieepa_path = here('data', 'processed', 'ieepa_country_rates.csv'),
    usmca_path = here('data', 'processed', 'usmca_products.csv')
  )

  write_csv(results %>% select(country, hts10, date, tpc_rate, our_rate, diff, match_2pp),
            here('output', 'tpc_comparison_v3.csv'))
  message('\nSaved to output/tpc_comparison_v3.csv')

  # China breakdown
  message('\n=== China Rate Distribution (Nov 17) ===')
  results %>%
    filter(date == '2025-11-17', country == 'China') %>%
    mutate(our_pct = round(our_rate * 100, 1), tpc_pct = round(tpc_rate * 100, 1)) %>%
    count(our_pct, tpc_pct) %>%
    arrange(desc(n)) %>%
    head(10) %>%
    print()
}
