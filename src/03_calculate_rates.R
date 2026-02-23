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

  # Section 301 Biden-era: 9903.91.xx (US Note 31), 9903.92.xx (crane duties)
  if (middle == 91 || middle == 92) {
    return('section_301')
  }

  # Section 232 auto: 9903.94.xx (US Note 33)
  if (middle == 94) {
    return('section_232')
  }

  # IEEPA: 9903.90.xx (China surcharges), 9903.93/95/96
  if (middle == 90 || (middle >= 93 && middle <= 96 && middle != 94)) {
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
#' Implements stacking logic:
#'   - China: max(232, reciprocal) + fentanyl + 301 + other
#'   - All others: max(232, reciprocal) + fentanyl + other
#'
#' @param rate_232 Section 232 rate
#' @param rate_301 Section 301 rate
#' @param rate_ieepa_recip IEEPA reciprocal rate
#' @param rate_ieepa_fent IEEPA fentanyl rate
#' @param rate_other Other additional duties
#' @param country Census country code
#' @return Total additional duty
apply_stacking <- function(rate_232, rate_301, rate_ieepa_recip, rate_ieepa_fent, rate_other, country) {
  # China: max(232, reciprocal) + fentanyl + 301 + other
  if (country == CTY_CHINA) {
    base <- max(rate_232, rate_ieepa_recip, na.rm = TRUE)
    return(base + rate_ieepa_fent + rate_301 + rate_other)
  }

  # All others: max(232, reciprocal) + fentanyl + other
  base <- max(rate_232, rate_ieepa_recip, na.rm = TRUE)
  return(base + rate_ieepa_fent + rate_other)
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

  # Rename list columns to avoid name collision with the 'countries' argument
  product_ch99_rates <- product_ch99_rates %>%
    rename(ch99_countries = countries, ch99_exempt = exempt_countries)

  # Create full expansion: product × ch99 × country
  country_vec <- countries  # local copy to avoid any ambiguity
  full_expansion <- product_ch99_rates %>%
    tidyr::expand_grid(country = country_vec)

  message('  Full expansion: ', nrow(full_expansion))

  # Check country applicability (vectorized where possible)
  full_expansion <- full_expansion %>%
    rowwise() %>%
    mutate(
      applies = check_country_applies(country, country_type, ch99_countries, ch99_exempt)
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

        # All others: max(232, reciprocal) + fentanyl + other
        TRUE ~ pmax(rate_232, rate_ieepa_recip) + rate_ieepa_fent + rate_other
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
  # Defensive checks
  if (length(country) == 0 || is.na(country)) return(FALSE)
  if (length(country_type) == 0 || is.na(country_type)) return(TRUE)

  # Convert Census to ISO for matching
  country_iso <- names(ISO_TO_CENSUS)[match(country, ISO_TO_CENSUS)]
  if (length(country_iso) == 0 || is.na(country_iso)) country_iso <- country

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
# Per-Revision Rate Calculator
# =============================================================================

#' Calculate rates for a single HTS revision
#'
#' Wraps calculate_rates_fast() but applies blanket tariffs that are NOT
#' referenced via product footnotes:
#'   - IEEPA reciprocal: blanket on all products for applicable countries
#'   - Section 232: blanket on steel (ch72-73) and aluminum (ch76) products
#'   - USMCA exemptions: eligible products exempt from IEEPA for CA/MX
#'
#' @param products Product data from parse_products()
#' @param ch99_data Chapter 99 data from parse_chapter99()
#' @param ieepa_rates IEEPA rates from extract_ieepa_rates() (or NULL)
#' @param usmca USMCA eligibility from extract_usmca_eligibility() (or NULL)
#' @param countries Vector of Census country codes
#' @param revision_id Revision identifier (e.g., 'rev_7')
#' @param effective_date Date the revision took effect
#' @param s232_rates Section 232 rates from extract_section232_rates() (or NULL)
#' @param fentanyl_rates Fentanyl rates from extract_ieepa_fentanyl_rates() (or NULL)
#' @return Tibble with rate columns + revision, effective_date, usmca_eligible
calculate_rates_for_revision <- function(
  products, ch99_data, ieepa_rates, usmca,
  countries, revision_id, effective_date,
  s232_rates = NULL,
  fentanyl_rates = NULL
) {
  message('Calculating rates for revision: ', revision_id, ' (', effective_date, ')')

  # 1. Get footnote-based rates from calculate_rates_fast()
  #    This captures 232, 301, fentanyl, other — but NOT IEEPA reciprocal,
  #    which is a blanket tariff not referenced via product footnotes.
  rates <- calculate_rates_fast(products, ch99_data, countries)

  if (nrow(rates) == 0) {
    message('  No rates calculated for ', revision_id)
    return(tibble(
      hts10 = character(), country = character(),
      base_rate = numeric(), rate_232 = numeric(), rate_301 = numeric(),
      rate_ieepa_recip = numeric(), rate_ieepa_fent = numeric(), rate_other = numeric(),
      total_additional = numeric(), total_rate = numeric(),
      usmca_eligible = logical(), revision = character(), effective_date = as.Date(character())
    ))
  }

  # 2. Build per-country IEEPA reciprocal lookup from ieepa_rates
  #    IEEPA reciprocal is a BLANKET tariff — it applies to all products for
  #    applicable countries, not just products with IEEPA footnotes. The country-
  #    specific rates from 9903.01/02.xx define the rate per country.
  has_active_ieepa <- !is.null(ieepa_rates) && nrow(ieepa_rates) > 0

  if (has_active_ieepa) {
    # Do NOT filter on 'terminated' — for a given revision, all IEEPA entries
    # present in the JSON were effective as of that revision. The "provision
    # terminated" text was added in later revisions.
    active_ieepa <- ieepa_rates %>%
      filter(!is.na(census_code), !is.na(rate))

    if (nrow(active_ieepa) > 0) {
      # Prefer Phase 2 over Phase 1 when both exist for a country
      # (Phase 2 supersedes Phase 1 with updated rates)
      country_ieepa <- active_ieepa %>%
        mutate(phase_priority = if_else(phase == 'phase2_aug7', 1L, 2L)) %>%
        group_by(census_code) %>%
        arrange(phase_priority, desc(rate)) %>%
        summarise(
          ieepa_country_rate = first(rate),
          ieepa_type = first(rate_type),
          .groups = 'drop'
        )

      # Apply IEEPA reciprocal to ALL products for applicable countries
      rates <- rates %>%
        left_join(
          country_ieepa %>% rename(country = census_code),
          by = 'country'
        ) %>%
        mutate(
          rate_ieepa_recip = case_when(
            is.na(ieepa_country_rate) ~ 0,              # country not in IEEPA list
            ieepa_type == 'surcharge' ~ ieepa_country_rate,
            ieepa_type == 'floor' ~ pmax(0, ieepa_country_rate - base_rate),
            ieepa_type == 'passthrough' ~ 0,
            TRUE ~ 0
          )
        ) %>%
        select(-ieepa_country_rate, -ieepa_type)

      # Also add IEEPA rows for products NOT currently in rates
      # (products with no other Ch99 duties but still subject to IEEPA)
      ieepa_country_codes <- country_ieepa$census_code
      ieepa_countries_in_scope <- intersect(ieepa_country_codes, countries)

      existing_pairs <- rates %>%
        filter(country %in% ieepa_countries_in_scope) %>%
        select(hts10, country)

      all_products_base <- products %>%
        select(hts10, base_rate) %>%
        mutate(base_rate = coalesce(base_rate, 0))

      new_pairs <- all_products_base %>%
        tidyr::expand_grid(country = ieepa_countries_in_scope) %>%
        anti_join(existing_pairs, by = c('hts10', 'country')) %>%
        left_join(
          country_ieepa %>% rename(country = census_code),
          by = 'country'
        ) %>%
        mutate(
          rate_232 = 0, rate_301 = 0, rate_ieepa_fent = 0, rate_other = 0,
          rate_ieepa_recip = case_when(
            ieepa_type == 'surcharge' ~ ieepa_country_rate,
            ieepa_type == 'floor' ~ pmax(0, ieepa_country_rate - base_rate),
            TRUE ~ 0
          )
        ) %>%
        filter(rate_ieepa_recip > 0) %>%
        select(-ieepa_country_rate, -ieepa_type)

      if (nrow(new_pairs) > 0) {
        message('  Adding ', nrow(new_pairs), ' product-country pairs for IEEPA-only duties')
        rates <- bind_rows(rates, new_pairs)
      }
    } else {
      # No usable IEEPA entries (all missing rate or census_code)
      rates <- rates %>% mutate(rate_ieepa_recip = 0)
    }
  } else {
    # No IEEPA in this revision — zero out
    rates <- rates %>% mutate(rate_ieepa_recip = 0)
  }

  # 2b. Apply IEEPA fentanyl/initial rates as blanket tariff
  #     9903.01.01-24: Mexico (+25%), Canada (+35%), China (+10%)
  #     These STACK with reciprocal tariffs for CA/MX.
  #     China/HK are EXCLUDED: their 9903.90.xx footnote rates already
  #     incorporate fentanyl (adding it would double-count ~10pp).
  CTY_HK <- '5820'
  has_fentanyl <- !is.null(fentanyl_rates) && nrow(fentanyl_rates) > 0

  if (has_fentanyl) {
    fent_lookup <- fentanyl_rates %>%
      filter(!(census_code %in% c(CTY_CHINA, CTY_HK))) %>%
      select(census_code, fent_rate = rate)

    # Apply fentanyl to existing rows
    rates <- rates %>%
      left_join(fent_lookup, by = c('country' = 'census_code')) %>%
      mutate(rate_ieepa_fent = coalesce(fent_rate, 0)) %>%
      select(-fent_rate)

    # Add fentanyl-only rows for products not yet in rates
    fent_country_codes <- intersect(fentanyl_rates$census_code, countries)
    if (length(fent_country_codes) > 0) {
      existing_fent <- rates %>%
        filter(country %in% fent_country_codes) %>%
        select(hts10, country)

      new_fent_pairs <- products %>%
        select(hts10, base_rate) %>%
        mutate(base_rate = coalesce(base_rate, 0)) %>%
        tidyr::expand_grid(country = fent_country_codes) %>%
        anti_join(existing_fent, by = c('hts10', 'country')) %>%
        left_join(fent_lookup, by = c('country' = 'census_code')) %>%
        mutate(
          rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0,
          rate_ieepa_fent = coalesce(fent_rate, 0), rate_other = 0
        ) %>%
        filter(rate_ieepa_fent > 0) %>%
        select(-fent_rate)

      if (nrow(new_fent_pairs) > 0) {
        message('  Adding ', nrow(new_fent_pairs),
                ' product-country pairs for fentanyl-only duties')
        rates <- bind_rows(rates, new_fent_pairs)
      }
    }

    n_with_fent <- sum(rates$rate_ieepa_fent > 0)
    message('  With IEEPA fentanyl: ', n_with_fent)
  } else {
    rates <- rates %>% mutate(rate_ieepa_fent = coalesce(rate_ieepa_fent, 0))
  }

  # 3. Apply Section 232 as blanket tariff
  #    232 is defined by US Notes 16 (steel) and 19 (aluminum), not via product
  #    footnotes. Apply to products in covered HTS chapters.
  if (is.null(s232_rates)) {
    s232_rates <- extract_section232_rates(ch99_data)
  }

  if (s232_rates$has_232) {
    # Identify covered products by HTS chapter
    steel_products <- products %>%
      filter(substr(hts10, 1, 2) %in% c('72', '73')) %>%
      pull(hts10)
    aluminum_products <- products %>%
      filter(substr(hts10, 1, 2) == '76') %>%
      pull(hts10)

    n_steel <- length(steel_products)
    n_alum <- length(aluminum_products)
    message('  Section 232 coverage: ', n_steel, ' steel + ', n_alum, ' aluminum products')

    # Build per-country 232 rate: check exemptions for each country
    country_232 <- tibble(country = countries) %>%
      mutate(
        steel_exempt = map_lgl(country, ~is_232_exempt(.x, s232_rates$steel_exempt)),
        alum_exempt = map_lgl(country, ~is_232_exempt(.x, s232_rates$aluminum_exempt)),
        steel_rate = if_else(steel_exempt, 0, s232_rates$steel_rate),
        aluminum_rate = if_else(alum_exempt, 0, s232_rates$aluminum_rate)
      )

    n_steel_countries <- sum(country_232$steel_rate > 0)
    n_alum_countries <- sum(country_232$aluminum_rate > 0)
    message('  Steel applies to ', n_steel_countries, ' countries, aluminum to ', n_alum_countries)

    # Update rate_232 for products already in rates
    rates <- rates %>%
      left_join(
        country_232 %>% select(country, steel_rate_232 = steel_rate, alum_rate_232 = aluminum_rate),
        by = 'country'
      ) %>%
      mutate(
        chapter = substr(hts10, 1, 2),
        blanket_232 = case_when(
          chapter %in% c('72', '73') ~ coalesce(steel_rate_232, 0),
          chapter == '76' ~ coalesce(alum_rate_232, 0),
          TRUE ~ 0
        ),
        # Take max of footnote-based 232 and blanket 232
        rate_232 = pmax(rate_232, blanket_232)
      ) %>%
      select(-steel_rate_232, -alum_rate_232, -chapter, -blanket_232)

    # Also add rows for 232-covered products NOT yet in rates
    # (products with no other Ch99 duties and not covered by IEEPA)
    s232_country_codes <- country_232 %>%
      filter(steel_rate > 0 | aluminum_rate > 0) %>%
      pull(country)

    all_232_products <- c(steel_products, aluminum_products)
    existing_pairs_232 <- rates %>%
      filter(hts10 %in% all_232_products, country %in% s232_country_codes) %>%
      select(hts10, country)

    new_232_pairs <- products %>%
      filter(hts10 %in% all_232_products) %>%
      select(hts10, base_rate) %>%
      mutate(base_rate = coalesce(base_rate, 0)) %>%
      tidyr::expand_grid(country = s232_country_codes) %>%
      anti_join(existing_pairs_232, by = c('hts10', 'country')) %>%
      left_join(
        country_232 %>% select(country, steel_rate_232 = steel_rate, alum_rate_232 = aluminum_rate),
        by = 'country'
      ) %>%
      mutate(
        chapter = substr(hts10, 1, 2),
        rate_232 = case_when(
          chapter %in% c('72', '73') ~ coalesce(steel_rate_232, 0),
          chapter == '76' ~ coalesce(alum_rate_232, 0),
          TRUE ~ 0
        ),
        rate_301 = 0, rate_ieepa_recip = 0, rate_ieepa_fent = 0, rate_other = 0
      ) %>%
      filter(rate_232 > 0) %>%
      select(-steel_rate_232, -alum_rate_232, -chapter)

    if (nrow(new_232_pairs) > 0) {
      message('  Adding ', nrow(new_232_pairs), ' product-country pairs for 232-only duties')
      rates <- bind_rows(rates, new_232_pairs)
    }
  }

  # 4. Apply USMCA exemptions
  if (!is.null(usmca) && nrow(usmca) > 0) {
    rates <- rates %>%
      left_join(
        usmca %>% select(hts10, usmca_eligible),
        by = 'hts10'
      ) %>%
      mutate(
        usmca_eligible = coalesce(usmca_eligible, FALSE),
        # USMCA-eligible products exempt from IEEPA for Canada/Mexico
        # (9903.01.14 explicitly exempts USMCA articles)
        rate_ieepa_recip = if_else(
          country %in% c(CTY_CANADA, CTY_MEXICO) & usmca_eligible,
          0, rate_ieepa_recip
        ),
        rate_ieepa_fent = if_else(
          country %in% c(CTY_CANADA, CTY_MEXICO) & usmca_eligible,
          0, rate_ieepa_fent
        )
      )
  } else {
    rates <- rates %>% mutate(usmca_eligible = FALSE)
  }

  # 5. Re-apply stacking rules with updated IEEPA and 232 rates
  rates <- rates %>%
    mutate(
      total_additional = case_when(
        # China: max(232, reciprocal) + fentanyl + 301 + other
        country == CTY_CHINA ~
          pmax(rate_232, rate_ieepa_recip) + rate_ieepa_fent + rate_301 + rate_other,
        # All others: max(232, reciprocal) + fentanyl + other
        TRUE ~ pmax(rate_232, rate_ieepa_recip) + rate_ieepa_fent + rate_other
      ),
      total_rate = base_rate + total_additional
    )

  # 6. Add revision metadata
  rates <- rates %>%
    mutate(
      revision = revision_id,
      effective_date = as.Date(effective_date)
    )

  # Summary
  n_with_ieepa <- sum(rates$rate_ieepa_recip > 0)
  n_with_232 <- sum(rates$rate_232 > 0)
  n_usmca <- sum(rates$usmca_eligible)
  message('  Products-countries: ', nrow(rates))
  message('  With IEEPA reciprocal: ', n_with_ieepa)
  message('  With Section 232: ', n_with_232)
  message('  USMCA eligible: ', n_usmca)

  return(rates)
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
