# =============================================================================
# Step 06: Calculate Total Tariff Rates
# =============================================================================
#
# Calculates total effective tariff rate for each HTS10 x country combination
# using stacking rules from Tariff-ETRs.
#
# PUBLIC API:
#   calculate_rates_for_revision() — Entry point for per-revision rate calculation.
#     Called by 00_build_timeseries.R and run_pipeline.R.
#
# INTERNAL:
#   calculate_rates_fast() — Footnote-based rate calculation (vectorized)
#   check_country_applies() — Country applicability check
#   apply_232_derivatives() — Section 232 derivative products + metal scaling
#
# Pipeline steps inside calculate_rates_for_revision():
#   1. Footnote-based rates (301, fentanyl, other via Ch99 refs)
#   2. IEEPA reciprocal (blanket, country-level)
#   3. IEEPA fentanyl (blanket, CA/MX/CN)
#   4. Section 232 base (blanket, chapter/heading)
#   5. Section 232 derivatives (blanket, product list + metal scaling)
#   6. Section 301 (blanket, China product list)
#   7. USMCA exemptions (CA/MX eligible products)
#   8. Stacking rules (mutual exclusion, nonmetal share)
#   9. Schema enforcement + metadata
#
# Output: rates_{revision}.rds with columns per RATE_SCHEMA (see helpers.R)
#
# =============================================================================

library(tidyverse)

# NOTE: classify_authority(), apply_stacking_rules(), enforce_rate_schema(),
# and RATE_SCHEMA are defined in helpers.R.

# Load policy parameters from YAML (country codes, ISO mapping)
.pp <- tryCatch(
  load_policy_params(),
  error = function(e) {
    # Graceful fallback when sourced before helpers.R sets working dir
    NULL
  }
)

# Country code constants — loaded from YAML, with fallback for standalone use
CTY_CHINA  <- if (!is.null(.pp)) .pp$CTY_CHINA  else '5700'
CTY_CANADA <- if (!is.null(.pp)) .pp$CTY_CANADA else '1220'
CTY_MEXICO <- if (!is.null(.pp)) .pp$CTY_MEXICO else '2010'
CTY_JAPAN  <- if (!is.null(.pp)) .pp$CTY_JAPAN  else '5880'
CTY_UK     <- if (!is.null(.pp)) .pp$CTY_UK     else '4120'
CTY_HK     <- if (!is.null(.pp)) .pp$CTY_HK     else '5820'

STEEL_CHAPTERS <- if (!is.null(.pp)) .pp$section_232_chapters$steel else c('72', '73')
ALUM_CHAPTERS  <- if (!is.null(.pp)) .pp$section_232_chapters$aluminum else c('76')

ISO_TO_CENSUS <- if (!is.null(.pp)) .pp$ISO_TO_CENSUS else c(
  'CN' = '5700', 'CA' = '1220', 'MX' = '2010',
  'JP' = '5880', 'UK' = '4120', 'GB' = '4120',
  'AU' = '6021', 'KR' = '5800', 'RU' = '4621',
  'AR' = '3570', 'BR' = '3510', 'UA' = '4622'
)


# =============================================================================
# Vectorized Rate Calculation (footnote-based)
# =============================================================================

#' Fast vectorized rate calculation (for large datasets)
#'
#' @param products Product data
#' @param ch99_data Chapter 99 data
#' @param countries Vector of country codes
#' @return Tibble with rates
calculate_rates_fast <- function(products, ch99_data, countries) {
  message('Calculating rates (fast mode)...')

  # Expand products to product x country
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

  # Create full expansion: product x ch99 x country
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

  # Aggregate by product x country x authority (take max within authority)
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

  # Apply stacking rules (vectorized, from helpers.R)
  rates_final <- apply_stacking_rules(rates_wide, CTY_CHINA)

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
# Section 232 Derivative Products
# =============================================================================

#' Apply Section 232 derivative tariff and metal content scaling
#'
#' Derivative products (9903.85.04/.07/.08) are aluminum-containing articles
#' outside chapter 76. The tariff applies only to the metal content portion
#' of customs value. This function:
#'   1. Loads the product list from resources/s232_derivative_products.csv
#'   2. Matches products by prefix
#'   3. Applies derivative 232 rates (update existing + add new pairs)
#'   4. Joins metal content shares and scales rate_232 by metal_share
#'
#' @param rates Current rates tibble
#' @param products Product data from parse_products()
#' @param ch99_data Chapter 99 data (to check for derivative Ch99 entries)
#' @param s232_rates Section 232 rates from extract_section232_rates()
#' @param countries Vector of Census country codes
#' @return List with 'rates' (updated tibble) and 'deriv_matched' (character vector)
apply_232_derivatives <- function(rates, products, ch99_data, s232_rates, countries) {
  deriv_products <- load_232_derivative_products()
  deriv_matched <- character(0)

  if (!is.null(deriv_products) && nrow(deriv_products) > 0 && s232_rates$has_232) {
    # Check if derivative Ch99 entries exist in this revision
    deriv_ch99_codes <- c('9903.85.04', '9903.85.07', '9903.85.08')
    has_deriv_entries <- any(ch99_data$ch99_code %in% deriv_ch99_codes)

    if (has_deriv_entries) {
      derivative_rate <- s232_rates$derivative_rate
      derivative_exempt <- s232_rates$derivative_exempt

      # Match products by prefix
      deriv_prefixes <- deriv_products$hts_prefix
      deriv_pattern <- paste0('^(', paste(deriv_prefixes, collapse = '|'), ')')
      deriv_matched <- products %>%
        filter(grepl(deriv_pattern, hts10)) %>%
        pull(hts10)

      message('  Section 232 derivative coverage: ', length(deriv_matched), ' products')

      if (length(deriv_matched) > 0) {
        # Build per-country rate lookup
        country_deriv_rate <- tibble(country = countries) %>%
          mutate(
            deriv_exempt = map_lgl(country, ~is_232_exempt(.x, derivative_exempt)),
            deriv_rate = if_else(deriv_exempt, 0, derivative_rate)
          )

        n_deriv_countries <- sum(country_deriv_rate$deriv_rate > 0)
        message('  Derivative 232: ', round(derivative_rate * 100), '% for ',
                n_deriv_countries, ' countries')

        # Update rate_232 for derivative products already in rates
        rates <- rates %>%
          left_join(
            country_deriv_rate %>% select(country, deriv_rate),
            by = 'country'
          ) %>%
          mutate(
            deriv_rate = coalesce(deriv_rate, 0),
            rate_232 = if_else(
              hts10 %in% deriv_matched & deriv_rate > 0,
              pmax(rate_232, deriv_rate),
              rate_232
            )
          ) %>%
          select(-deriv_rate)

        # Add new pairs using blanket helper
        blanket_rates <- country_deriv_rate %>%
          select(country, blanket_rate = deriv_rate)
        rates <- add_blanket_pairs(rates, products, deriv_matched, blanket_rates,
                                   'rate_232', '232 derivative duties')
      }
    }
  }

  # Join metal content shares and scale derivative 232 rates.
  # For derivative products, rate_232 was set to the full rate above;
  # now scale by metal_share so that the rate reflects metal-content-only.
  metal_cfg <- if (!is.null(.pp)) .pp$metal_content else NULL
  metal_shares <- load_metal_content(metal_cfg, unique(rates$hts10), deriv_matched)
  if ('metal_share' %in% names(rates)) {
    rates <- rates %>% select(-metal_share)
  }
  rates <- rates %>%
    left_join(metal_shares, by = 'hts10') %>%
    mutate(metal_share = coalesce(metal_share, 1.0))

  if (length(deriv_matched) > 0) {
    rates <- rates %>%
      mutate(rate_232 = if_else(
        hts10 %in% deriv_matched & metal_share < 1.0,
        rate_232 * metal_share,
        rate_232
      ))

    n_deriv_with_232 <- sum(rates$hts10 %in% deriv_matched & rates$rate_232 > 0)
    message('  Derivative 232 after metal scaling: ', n_deriv_with_232,
            ' product-country pairs')
  }

  return(list(rates = rates, deriv_matched = deriv_matched))
}


# =============================================================================
# Per-Revision Rate Calculator
# =============================================================================

#' Calculate rates for a single HTS revision
#'
#' Wraps calculate_rates_fast() but applies blanket tariffs that are NOT
#' referenced via product footnotes:
#'   - IEEPA reciprocal: blanket on all products for applicable countries
#'   - IEEPA fentanyl: blanket on all products for CA/MX/CN
#'   - Section 232: blanket on steel/aluminum/auto/copper/derivative products
#'   - Section 301: blanket on China products from product list
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
    return(enforce_rate_schema(tibble()))
  }

  # 2. Apply IEEPA reciprocal (blanket, country-level)
  #    IEEPA reciprocal is a BLANKET tariff — it applies to all products for
  #    applicable countries, not just products with IEEPA footnotes. The country-
  #    specific rates from 9903.01/02.xx define the rate per country.
  #
  #    Product-level exemptions (Annex A / US Note 2 subdivision (v)(iii)):
  #    ~1,087 products are exempt from IEEPA reciprocal. These are defined by
  #    executive order, not by HTS footnotes, so we load from a resource file.
  has_active_ieepa <- !is.null(ieepa_rates) && nrow(ieepa_rates) > 0

  # Load IEEPA product exemptions
  ieepa_exempt_path <- here('resources', 'ieepa_exempt_products.csv')
  ieepa_exempt_products <- if (file.exists(ieepa_exempt_path)) {
    read_csv(ieepa_exempt_path, col_types = cols(hts10 = col_character()))$hts10
  } else {
    character(0)
  }
  if (length(ieepa_exempt_products) > 0) {
    message('  IEEPA exempt products loaded: ', length(ieepa_exempt_products))
  }

  if (has_active_ieepa) {
    # Do NOT filter on 'terminated' — for a given revision, all IEEPA entries
    # present in the JSON were effective as of that revision. The "provision
    # terminated" text was added in later revisions.
    active_ieepa <- ieepa_rates %>%
      filter(!is.na(census_code), !is.na(rate))

    if (nrow(active_ieepa) > 0) {
      # Phase 2 and country_eo entries stack ACROSS phases but NOT within a phase.
      # Within a phase, the country-specific entry supersedes group entries.
      # E.g., Brazil: +10% (Phase 2, 9903.02.09) + 40% (country_eo, 9903.01.77) = 50%
      #       India:  +25% (Phase 2, 9903.02.26) + 25% (country_eo, 9903.01.84) = 50%
      #       Tunisia: max(+15%, +25%) = 25% (both Phase 2, take highest)
      country_ieepa <- active_ieepa %>%
        mutate(
          active_rank = if_else(phase %in% c('phase2_aug7', 'country_eo'), 1L, 2L),
          type_priority = case_when(
            rate_type == 'floor' ~ 1L,
            rate_type == 'surcharge' ~ 2L,
            rate_type == 'passthrough' ~ 3L,
            TRUE ~ 4L
          )
        ) %>%
        group_by(census_code) %>%
        filter(active_rank == min(active_rank)) %>%
        ungroup() %>%
        # Within each phase: pick the best entry (prefer floor, then highest rate)
        group_by(census_code, phase) %>%
        arrange(type_priority, desc(rate)) %>%
        summarise(
          phase_rate = first(rate),
          ieepa_type = first(rate_type),
          .groups = 'drop'
        ) %>%
        # Across phases: sum (Phase 2 + country_eo stack)
        group_by(census_code) %>%
        summarise(
          ieepa_country_rate = sum(phase_rate),
          ieepa_type = first(ieepa_type),
          .groups = 'drop'
        )

      # Apply universal baseline to countries not in any IEEPA entry.
      # 9903.01.25 (10%) applies to all countries; country-specific entries
      # provide higher rates for listed countries.
      # Exclude CA/MX: they have a separate fentanyl-only IEEPA regime and
      # are explicitly excluded from reciprocal tariffs by executive order.
      universal_baseline <- attr(ieepa_rates, 'universal_baseline')
      pp <- load_policy_params()

      # Override surcharge -> floor for countries in floor_countries config.
      # Handles cases where HTS JSON hasn't yet been updated with floor entries
      # (e.g., Switzerland/Liechtenstein per FR 2025-23316, effective Nov 14, 2025).
      floor_country_codes <- pp$FLOOR_COUNTRIES
      if (length(floor_country_codes) > 0) {
        override_mask <- country_ieepa$census_code %in% floor_country_codes &
                         country_ieepa$ieepa_type == 'surcharge'
        if (any(override_mask)) {
          country_ieepa$ieepa_country_rate[override_mask] <- pp$FLOOR_RATE
          country_ieepa$ieepa_type[override_mask] <- 'floor'
          message('  Floor override applied to ', sum(override_mask),
                  ' countries: ', paste(country_ieepa$census_code[override_mask], collapse = ', '))
        }
      }
      recip_exempt <- c(pp$country_codes$CTY_CANADA, pp$country_codes$CTY_MEXICO)
      if (!is.null(universal_baseline) && universal_baseline > 0) {
        unlisted_countries <- setdiff(countries, c(country_ieepa$census_code, recip_exempt))
        if (length(unlisted_countries) > 0) {
          baseline_entries <- tibble(
            census_code = unlisted_countries,
            ieepa_country_rate = universal_baseline,
            ieepa_type = 'surcharge'
          )
          country_ieepa <- bind_rows(country_ieepa, baseline_entries)
          message('  Applied universal baseline (', round(universal_baseline * 100),
                  '%) to ', length(unlisted_countries), ' unlisted countries')
        }
      }

      # Apply IEEPA reciprocal to ALL products for applicable countries
      # EXCEPT products on the exemption list (Annex A / US Note 2)
      rates <- rates %>%
        left_join(
          country_ieepa %>% rename(country = census_code),
          by = 'country'
        ) %>%
        mutate(
          rate_ieepa_recip = case_when(
            hts10 %in% ieepa_exempt_products ~ 0,       # product-level exemption
            is.na(ieepa_country_rate) ~ 0,               # country not in IEEPA list
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
        filter(!hts10 %in% ieepa_exempt_products) %>%   # exclude exempt products
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

  # 3. Apply IEEPA fentanyl/initial rates with product-level carve-outs
  #    9903.01.01-24: Mexico (+25%), Canada (+35%), China (+10%)
  #    These STACK with reciprocal tariffs for CA/MX.
  #    China/HK included: fentanyl (9903.01.20/24) is NOT captured via
  #    product footnotes for China. The 9903.90.xx entries are Russia only.
  #
  #    Carve-outs: Certain product categories receive a lower fentanyl rate:
  #      - 9903.01.13 (CA): Energy, minerals, critical minerals → +10%
  #      - 9903.01.15 (CA): Potash → +10%
  #      - 9903.01.05 (MX): Potash → +10%
  #    Product lists from resources/fentanyl_carveout_products.csv.
  has_fentanyl <- !is.null(fentanyl_rates) && nrow(fentanyl_rates) > 0

  if (has_fentanyl) {
    # Separate general (blanket) and carve-out entries.
    # Some countries have multiple general entries (e.g., China 9903.01.20 and
    # 9903.01.24) — take first per country to avoid row multiplication in joins.
    general_fent <- fentanyl_rates %>%
      filter(entry_type == 'general') %>%
      arrange(ch99_code) %>%
      distinct(census_code, .keep_all = TRUE) %>%
      select(census_code, fent_rate = rate)

    carveout_fent <- fentanyl_rates %>%
      filter(entry_type == 'carveout') %>%
      select(ch99_code, census_code, carveout_rate = rate)

    # Load carve-out product lists and build lookup (once, reused below)
    carveout_products <- load_fentanyl_carveouts()
    has_carveouts <- !is.null(carveout_products) && nrow(carveout_fent) > 0

    carveout_lookup <- NULL
    if (has_carveouts) {
      # HTS8 × country → carve-out rate (join product list to parsed ch99 entries)
      carveout_lookup <- carveout_products %>%
        inner_join(carveout_fent, by = 'ch99_code') %>%
        distinct(hts8, census_code, .keep_all = TRUE) %>%
        select(hts8, census_code, carveout_rate)
    }

    # Apply fentanyl to existing rows: general rate with carve-out overrides
    if (has_carveouts) {
      rates <- rates %>%
        mutate(.hts8 = substr(hts10, 1, 8)) %>%
        left_join(general_fent, by = c('country' = 'census_code')) %>%
        left_join(carveout_lookup,
                  by = c('.hts8' = 'hts8', 'country' = 'census_code')) %>%
        mutate(
          rate_ieepa_fent = coalesce(carveout_rate, fent_rate, 0)
        ) %>%
        select(-fent_rate, -carveout_rate, -.hts8)

      n_carveout <- sum(rates$rate_ieepa_fent > 0 &
                        rates$rate_ieepa_fent < max(general_fent$fent_rate, na.rm = TRUE))
      message('  Fentanyl carve-outs applied: ', n_carveout, ' product-country pairs')
    } else {
      rates <- rates %>%
        left_join(general_fent, by = c('country' = 'census_code')) %>%
        mutate(rate_ieepa_fent = coalesce(fent_rate, 0)) %>%
        select(-fent_rate)
    }

    # Add fentanyl-only rows for products not yet in rates
    # (uses general rate; carve-outs applied in the next block)
    fent_country_rates <- general_fent %>%
      rename(country = census_code, blanket_rate = fent_rate) %>%
      filter(country %in% countries)
    all_product_hts10 <- products$hts10
    rates <- add_blanket_pairs(rates, products, all_product_hts10, fent_country_rates,
                               'rate_ieepa_fent', 'fentanyl-only duties')

    # Apply carve-outs to newly added rows (blanket_pairs got the general rate)
    if (has_carveouts) {
      rates <- rates %>%
        mutate(.hts8 = substr(hts10, 1, 8)) %>%
        left_join(carveout_lookup,
                  by = c('.hts8' = 'hts8', 'country' = 'census_code')) %>%
        mutate(
          rate_ieepa_fent = if_else(!is.na(carveout_rate), carveout_rate, rate_ieepa_fent)
        ) %>%
        select(-carveout_rate, -.hts8)
    }

    n_with_fent <- sum(rates$rate_ieepa_fent > 0)
    message('  With IEEPA fentanyl: ', n_with_fent)
  } else {
    rates <- rates %>% mutate(rate_ieepa_fent = coalesce(rate_ieepa_fent, 0))
  }

  # 4. Apply Section 232 base tariff (blanket, chapter/heading)
  #    232 is defined by US Notes, not via product footnotes.
  #    Steel: chapters 72-73 (US Note 16, 9903.80-84)
  #    Aluminum: chapter 76 (US Note 19, 9903.85)
  #    Autos: heading 8703 + specific subheadings (US Note 25, 9903.94)
  #    Copper: specific headings in chapter 74
  if (is.null(s232_rates)) {
    s232_rates <- extract_section232_rates(ch99_data)
  }

  # Load heading-level 232 config from policy params
  s232_headings <- if (!is.null(.pp)) .pp$section_232_headings else NULL

  if (s232_rates$has_232) {
    # --- Identify covered products by prefix matching ---
    # Chapter-level: steel (72-73), aluminum (76)
    steel_products <- products %>%
      filter(substr(hts10, 1, 2) %in% STEEL_CHAPTERS) %>%
      pull(hts10)
    aluminum_products <- products %>%
      filter(substr(hts10, 1, 2) %in% ALUM_CHAPTERS) %>%
      pull(hts10)

    # Heading-level: autos, copper, etc.
    auto_products <- character(0)
    copper_products <- character(0)
    heading_product_lists <- list()

    if (!is.null(s232_headings)) {
      for (tariff_name in names(s232_headings)) {
        cfg <- s232_headings[[tariff_name]]
        prefixes <- unlist(cfg$prefixes)
        if (length(prefixes) == 0) next

        # Match products by prefix
        pattern <- paste0('^(', paste(prefixes, collapse = '|'), ')')
        matched <- products %>%
          filter(grepl(pattern, hts10)) %>%
          pull(hts10)

        heading_product_lists[[tariff_name]] <- list(
          products = matched,
          rate = cfg$default_rate %||% s232_rates$auto_rate,
          usmca_exempt = cfg$usmca_exempt %||% FALSE
        )

        if (grepl('auto|vehicle', tariff_name, ignore.case = TRUE)) {
          auto_products <- c(auto_products, matched)
        } else if (grepl('copper', tariff_name, ignore.case = TRUE)) {
          copper_products <- c(copper_products, matched)
        }
      }
    }
    auto_products <- unique(auto_products)
    copper_products <- unique(copper_products)

    n_steel <- length(steel_products)
    n_alum <- length(aluminum_products)
    n_auto <- length(auto_products)
    n_copper <- length(copper_products)
    message('  Section 232 coverage: ', n_steel, ' steel + ', n_alum,
            ' aluminum + ', n_auto, ' auto + ', n_copper, ' copper products')

    # --- Build product-level 232 rate lookup from heading configs ---
    # Each heading config specifies its own rate. Build an hts10 -> rate mapping.
    heading_product_rate <- map_dfr(names(heading_product_lists), function(nm) {
      cfg <- heading_product_lists[[nm]]
      if (length(cfg$products) == 0) return(tibble())
      tibble(
        hts10 = cfg$products,
        heading_232_rate = cfg$rate,
        heading_usmca_exempt = isTRUE(cfg$usmca_exempt)
      )
    })
    # If a product appears in multiple heading tariffs, take the max rate
    if (nrow(heading_product_rate) > 0) {
      heading_product_rate <- heading_product_rate %>%
        group_by(hts10) %>%
        summarise(
          heading_232_rate = max(heading_232_rate),
          heading_usmca_exempt = any(heading_usmca_exempt),
          .groups = 'drop'
        )
    }

    # --- Build per-country rate lookup ---
    country_232 <- tibble(country = countries) %>%
      mutate(
        steel_exempt = map_lgl(country, ~is_232_exempt(.x, s232_rates$steel_exempt)),
        alum_exempt = map_lgl(country, ~is_232_exempt(.x, s232_rates$aluminum_exempt)),
        auto_exempt = map_lgl(country, ~is_232_exempt(.x, s232_rates$auto_exempt)),
        steel_rate = if_else(steel_exempt, 0, s232_rates$steel_rate),
        aluminum_rate = if_else(alum_exempt, 0, s232_rates$aluminum_rate),
        auto_rate = if_else(auto_exempt, 0, s232_rates$auto_rate)
      )

    n_steel_countries <- sum(country_232$steel_rate > 0)
    n_alum_countries <- sum(country_232$aluminum_rate > 0)
    n_auto_countries <- sum(country_232$auto_rate > 0)
    message('  Steel: ', n_steel_countries, ' countries, aluminum: ',
            n_alum_countries, ', auto: ', n_auto_countries)

    # --- Update rate_232 for products already in rates ---
    # Join heading-level rates for auto/copper/etc products
    if (nrow(heading_product_rate) > 0) {
      rates <- rates %>%
        left_join(heading_product_rate, by = 'hts10')
    } else {
      rates$heading_232_rate <- 0
      rates$heading_usmca_exempt <- FALSE
    }

    rates <- rates %>%
      left_join(
        country_232 %>% select(country, steel_rate_232 = steel_rate,
                               alum_rate_232 = aluminum_rate),
        by = 'country'
      ) %>%
      mutate(
        chapter = substr(hts10, 1, 2),
        # For heading-level products, zero out rate for USMCA-exempt CA/MX
        heading_rate_adj = case_when(
          is.na(heading_232_rate) | heading_232_rate == 0 ~ 0,
          heading_usmca_exempt & country %in% c(CTY_CANADA, CTY_MEXICO) ~ 0,
          TRUE ~ heading_232_rate
        ),
        blanket_232 = case_when(
          chapter %in% STEEL_CHAPTERS ~ coalesce(steel_rate_232, 0),
          chapter %in% ALUM_CHAPTERS ~ coalesce(alum_rate_232, 0),
          heading_rate_adj > 0 ~ heading_rate_adj,
          TRUE ~ 0
        ),
        rate_232 = pmax(rate_232, blanket_232)
      ) %>%
      select(-steel_rate_232, -alum_rate_232, -chapter, -blanket_232,
             -heading_232_rate, -heading_usmca_exempt, -heading_rate_adj)

    # --- Add rows for 232-covered products NOT yet in rates ---
    s232_country_codes <- country_232 %>%
      filter(steel_rate > 0 | aluminum_rate > 0 | auto_rate > 0) %>%
      pull(country)

    all_heading_products <- if (nrow(heading_product_rate) > 0) heading_product_rate$hts10 else character(0)
    all_232_products <- unique(c(steel_products, aluminum_products, all_heading_products))
    existing_pairs_232 <- rates %>%
      filter(hts10 %in% all_232_products, country %in% s232_country_codes) %>%
      select(hts10, country)

    new_232_base <- products %>%
      filter(hts10 %in% all_232_products) %>%
      select(hts10, base_rate) %>%
      mutate(base_rate = coalesce(base_rate, 0))

    if (nrow(heading_product_rate) > 0) {
      new_232_base <- new_232_base %>%
        left_join(heading_product_rate, by = 'hts10')
    } else {
      new_232_base$heading_232_rate <- 0
      new_232_base$heading_usmca_exempt <- FALSE
    }

    new_232_pairs <- new_232_base %>%
      tidyr::expand_grid(country = s232_country_codes) %>%
      anti_join(existing_pairs_232, by = c('hts10', 'country')) %>%
      left_join(
        country_232 %>% select(country, steel_rate_232 = steel_rate,
                               alum_rate_232 = aluminum_rate),
        by = 'country'
      ) %>%
      mutate(
        chapter = substr(hts10, 1, 2),
        heading_rate_adj = case_when(
          is.na(heading_232_rate) | heading_232_rate == 0 ~ 0,
          heading_usmca_exempt & country %in% c(CTY_CANADA, CTY_MEXICO) ~ 0,
          TRUE ~ heading_232_rate
        ),
        rate_232 = case_when(
          chapter %in% STEEL_CHAPTERS ~ coalesce(steel_rate_232, 0),
          chapter %in% ALUM_CHAPTERS ~ coalesce(alum_rate_232, 0),
          heading_rate_adj > 0 ~ heading_rate_adj,
          TRUE ~ 0
        ),
        rate_301 = 0, rate_ieepa_recip = 0, rate_ieepa_fent = 0, rate_other = 0
      ) %>%
      filter(rate_232 > 0) %>%
      select(-steel_rate_232, -alum_rate_232, -chapter,
             -heading_232_rate, -heading_usmca_exempt, -heading_rate_adj)

    if (nrow(new_232_pairs) > 0) {
      message('  Adding ', nrow(new_232_pairs), ' product-country pairs for 232-only duties')
      rates <- bind_rows(rates, new_232_pairs)
    }
  }

  # 5. Apply Section 232 derivative tariff + metal content scaling
  #    Derivative products (9903.85.04/.07/.08) are aluminum-containing articles
  #    outside chapter 76. The tariff applies only to the metal content portion.
  result <- apply_232_derivatives(rates, products, ch99_data, s232_rates, countries)
  rates <- result$rates
  deriv_matched <- result$deriv_matched

  # 6. Apply Section 301 as blanket tariff for China
  #     301 products are defined by US Note 20/21/31 product lists (Federal Register).
  #     Like 232, these are NOT referenced via product footnotes for most products.
  #     Source: USITC "China Tariffs" reference document (hts.usitc.gov).
  #
  #     Known limitation: Some products on Lists 1-4A were later excluded via
  #     9903.89.xx entries referencing US Note exclusion lists. Those exclusions
  #     are not captured here — excluded products will incorrectly receive the
  #     base 301 rate. The impact is minor relative to the ~5,000 product gap
  #     this step closes.
  s301_products_path <- here('resources', 's301_product_lists.csv')
  if (file.exists(s301_products_path)) {
    s301_products <- read_csv(s301_products_path, col_types = cols(
      hts8 = col_character(), list = col_character(), ch99_code = col_character()
    ))

    # Get active 301 ch99 codes from this revision's Ch99 data
    # Use SECTION_301_RATES config for reliable rate values
    s301_rate_lookup <- if (!is.null(.pp)) {
      .pp$SECTION_301_RATES
    } else {
      tibble(ch99_pattern = character(), s301_rate = numeric())
    }

    active_301_codes <- ch99_data %>%
      filter(ch99_code %in% s301_rate_lookup$ch99_pattern) %>%
      pull(ch99_code) %>%
      unique()

    if (length(active_301_codes) > 0) {
      # Build HTS8 -> max 301 rate lookup (products may appear on multiple lists)
      s301_lookup <- s301_products %>%
        filter(ch99_code %in% active_301_codes) %>%
        inner_join(
          s301_rate_lookup,
          by = c('ch99_code' = 'ch99_pattern')
        ) %>%
        group_by(hts8) %>%
        summarise(blanket_301 = max(s301_rate), .groups = 'drop')

      if (nrow(s301_lookup) > 0) {
        # Update rate_301 for existing China product-country pairs
        rates <- rates %>%
          mutate(hts8 = substr(hts10, 1, 8)) %>%
          left_join(s301_lookup, by = 'hts8') %>%
          mutate(
            blanket_301 = coalesce(blanket_301, 0),
            rate_301 = if_else(
              country == CTY_CHINA,
              pmax(rate_301, blanket_301),
              rate_301
            )
          ) %>%
          select(-hts8, -blanket_301)

        # Add 301-only rows for China products NOT yet in rates
        # (products with no other Ch99 duties but subject to 301)
        s301_hts8_codes <- s301_lookup$hts8
        s301_hts10 <- products %>%
          mutate(hts8 = substr(hts10, 1, 8)) %>%
          filter(hts8 %in% s301_hts8_codes) %>%
          pull(hts10)

        existing_china <- rates %>%
          filter(country == CTY_CHINA) %>%
          pull(hts10)

        new_301_products <- setdiff(s301_hts10, existing_china)

        if (length(new_301_products) > 0) {
          new_301_pairs <- products %>%
            filter(hts10 %in% new_301_products) %>%
            select(hts10, base_rate) %>%
            mutate(
              base_rate = coalesce(base_rate, 0),
              hts8 = substr(hts10, 1, 8),
              country = CTY_CHINA
            ) %>%
            left_join(s301_lookup, by = 'hts8') %>%
            mutate(
              rate_232 = 0, rate_ieepa_recip = 0,
              rate_ieepa_fent = 0, rate_other = 0,
              rate_301 = coalesce(blanket_301, 0)
            ) %>%
            filter(rate_301 > 0) %>%
            select(-hts8, -blanket_301)

          if (nrow(new_301_pairs) > 0) {
            message('  Adding ', nrow(new_301_pairs),
                    ' product-country pairs for 301-only duties')
            rates <- bind_rows(rates, new_301_pairs)
          }
        }

        n_301_total <- sum(rates$country == CTY_CHINA & rates$rate_301 > 0)
        message('  Section 301 blanket: ', nrow(s301_lookup), ' HTS8 codes, ',
                n_301_total, ' China product-country pairs with 301 rate')
      }
    }
  }

  # 7. Apply USMCA exemptions
  if (!is.null(usmca) && nrow(usmca) > 0) {
    rates <- rates %>%
      left_join(
        usmca %>% select(hts10, usmca_eligible),
        by = 'hts10'
      ) %>%
      mutate(
        usmca_eligible = coalesce(usmca_eligible, FALSE),
        # USMCA-eligible products exempt from IEEPA for Canada/Mexico
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

  # 8. Re-apply stacking rules with updated IEEPA and 232 rates
  rates <- apply_stacking_rules(rates, CTY_CHINA)

  # 9a. Add revision metadata
  rates <- rates %>%
    mutate(
      revision = revision_id,
      effective_date = as.Date(effective_date)
    )

  # 9b. Enforce canonical schema
  rates <- enforce_rate_schema(rates)

  # Summary
  n_with_ieepa <- sum(rates$rate_ieepa_recip > 0)
  n_with_232 <- sum(rates$rate_232 > 0)
  n_with_301 <- sum(rates$rate_301 > 0)
  n_usmca <- sum(rates$usmca_eligible)
  message('  Products-countries: ', nrow(rates))
  message('  With IEEPA reciprocal: ', n_with_ieepa)
  message('  With Section 232: ', n_with_232)
  message('  With Section 301: ', n_with_301)
  message('  USMCA eligible: ', n_usmca)

  return(rates)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)
  source(here('src', 'helpers.R'))

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
