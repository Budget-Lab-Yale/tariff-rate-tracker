# =============================================================================
# Step 06: Calculate Total Tariff Rates
# =============================================================================
#
# Calculates total effective tariff rate for each HTS10 x country combination
# using stacking rules from Tariff-ETRs.
#
# PUBLIC API:
#   calculate_rates_for_revision() — Entry point for per-revision rate calculation.
#     Called by 00_build_timeseries.R.
#
# INTERNAL:
#   calculate_rates_fast() — Footnote-based rate calculation (vectorized)
#   check_country_applies() — Country applicability check
#   apply_232_derivatives() — Section 232 derivative products + metal scaling
#
# Pipeline steps inside calculate_rates_for_revision():
#   1. Footnote-based rates (301, fentanyl, other via Ch99 refs)
#   1b. IEEPA invalidation check (SCOTUS ruling cutoff)
#   2. IEEPA reciprocal (blanket, country-level)
#   2b. Post-IEEPA grid expansion (stabilize product-country grid when invalidated)
#   3. IEEPA fentanyl (blanket, CA/MX/CN)
#   4. Section 232 base (blanket, chapter/heading, with config country exemptions)
#   5. Section 232 derivatives (blanket, product list + metal scaling)
#   6. Section 301 (blanket, China product list)
#   6b. Section 122 (blanket, all countries, Annex II exempt)
#   6c. MFN exemption shares (FTA/GSP preference adjustment to base_rate)
#   6d. Floor recomputation (recompute IEEPA floor against post-MFN base_rate)
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

# Policy params — needed throughout for IEEPA, 232, floor, MFN, etc.
.pp <- tryCatch(
  load_policy_params(),
  error = function(e) {
    # Graceful fallback when sourced before helpers.R sets working dir
    NULL
  }
)

# Country code constants — centralized in helpers.R, loaded from YAML with fallback
.cc <- get_country_constants(.pp)
CTY_CHINA  <- .cc$CTY_CHINA
CTY_CANADA <- .cc$CTY_CANADA
CTY_MEXICO <- .cc$CTY_MEXICO
CTY_JAPAN  <- .cc$CTY_JAPAN
CTY_UK     <- .cc$CTY_UK
CTY_HK     <- .cc$CTY_HK
STEEL_CHAPTERS <- .cc$STEEL_CHAPTERS
ALUM_CHAPTERS  <- .cc$ALUM_CHAPTERS
ISO_TO_CENSUS  <- .cc$ISO_TO_CENSUS


# =============================================================================
# Vectorized Rate Calculation (footnote-based)
# =============================================================================

#' Fast vectorized rate calculation (for large datasets)
#'
#' @param products Product data
#' @param ch99_data Chapter 99 data
#' @param countries Vector of country codes
#' @return Tibble with rates
calculate_rates_fast <- function(products, ch99_data, countries, stacking_method = 'mutual_exclusion') {
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
                'rate_ieepa_fentanyl', 'rate_section_122', 'rate_section_201', 'rate_other')) {
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
      rate_ieepa_fent = rate_ieepa_fentanyl,
      rate_s122 = rate_section_122
    )

  # Apply stacking rules (vectorized, from helpers.R)
  rates_final <- apply_stacking_rules(rates_wide, CTY_CHINA, stacking_method = stacking_method)

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
  if (length(country_type) == 0 || is.na(country_type)) return(FALSE)

  # Convert Census to ISO for matching
  country_iso <- names(ISO_TO_CENSUS)[match(country, ISO_TO_CENSUS)]
  if (length(country_iso) == 0 || is.na(country_iso)) country_iso <- country

  switch(
    country_type,
    'all' = TRUE,
    'all_except' = !(country_iso %in% exempt),
    'specific' = country_iso %in% countries || country %in% countries,
    'unknown' = FALSE,  # Fail-closed: parser miss should not promote to global
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
apply_232_derivatives <- function(rates, products, ch99_data, s232_rates, countries,
                                  heading_products = character(0),
                                  policy_params = NULL) {
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

  # Update statutory_rate_232 for derivative products only (pre-metal-scaling).
  # Non-derivative products already have statutory_rate_232 set before step 4b.
  if (length(deriv_matched) > 0) {
    rates <- rates %>%
      mutate(
        statutory_rate_232 = if_else(
          hts10 %in% deriv_matched,
          pmax(coalesce(statutory_rate_232, 0), rate_232),
          statutory_rate_232
        )
      )
  }

  # Join metal content shares and scale derivative 232 rates.
  # For derivative products, rate_232 was set to the full rate above;
  # now scale by metal_share so that the rate reflects metal-content-only.
  pp_local <- policy_params %||% .pp
  metal_cfg <- if (!is.null(pp_local)) pp_local$metal_content else NULL
  metal_shares <- load_metal_content(metal_cfg, unique(rates$hts10), deriv_matched)
  if ('metal_share' %in% names(rates)) {
    rates <- rates %>% select(-metal_share)
  }
  rates <- rates %>%
    left_join(metal_shares, by = 'hts10') %>%
    mutate(metal_share = coalesce(metal_share, 1.0))
  n_missing_share <- sum(is.na(metal_shares$metal_share[metal_shares$hts10 %in% deriv_matched]))
  if (n_missing_share > 0) {
    warning(n_missing_share, ' derivative products have no metal_share data — defaulting to 1.0 (no scaling)')
  }

  if (length(deriv_matched) > 0) {
    # Scale by per-type share (aluminum_share for aluminum derivatives) rather
    # than aggregate metal_share. The derivative tariff only applies to the
    # aluminum content; steel/copper fractions are covered by IEEPA via
    # nonmetal_share in stacking. This matches ETRs' per-type scaling.
    #
    # Skip scaling for derivatives that also have a heading rate (e.g., auto parts
    # that are also aluminum derivatives). The heading rate dominates and shouldn't
    # be metal-scaled — ETRs handles this via per-program pmax.
    scale_col <- if ('aluminum_share' %in% names(rates)) 'aluminum_share' else 'metal_share'
    # Exclude primary chapter products (72/73/76) and heading products from
    # derivative metal scaling. Primary chapters get blanket 232 rates (full product);
    # heading products get heading rates (full product). Only true derivatives
    # (outside primary chapters, not heading-matched) should be metal-scaled.
    p_chapters <- if (!is.null(.pp)) unlist(.pp$metal_content$primary_chapters) else c('72', '73', '76')
    primary_hts10 <- rates %>% distinct(hts10) %>%
      filter(substr(hts10, 1, 2) %in% p_chapters) %>% pull(hts10)
    deriv_only <- setdiff(deriv_matched, c(heading_products, primary_hts10))
    rates <- rates %>%
      mutate(rate_232 = if_else(
        hts10 %in% deriv_only & !!sym(scale_col) < 1.0,
        rate_232 * !!sym(scale_col),
        rate_232
      ))

    # Reset metal_share to 1.0 for heading products excluded from scaling.
    # Their rate_232 applies to the full product value (heading rate dominates),
    # not the metal portion. Without this, stacking incorrectly computes
    # nonmetal_share > 0 and lets IEEPA fill the "non-metal" portion.
    heading_derivs <- intersect(deriv_matched, heading_products)
    if (length(heading_derivs) > 0) {
      rates <- rates %>%
        mutate(
          metal_share       = if_else(hts10 %in% heading_derivs, 1.0, metal_share),
          steel_share       = if_else(hts10 %in% heading_derivs, 0, steel_share),
          aluminum_share    = if_else(hts10 %in% heading_derivs, 0, aluminum_share),
          copper_share      = if_else(hts10 %in% heading_derivs, 0, copper_share),
          other_metal_share = if_else(hts10 %in% heading_derivs, 0, other_metal_share)
        )
      message('  Reset metal_share=1.0 for ', length(heading_derivs),
              ' heading/derivative overlap products')
    }

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
  fentanyl_rates = NULL,
  stacking_method = 'mutual_exclusion',
  policy_params = NULL
) {
  message('Calculating rates for revision: ', revision_id, ' (', effective_date, ')')

  pp <- policy_params %||% load_policy_params()
  cc <- get_country_constants(pp)
  CTY_CHINA  <- cc$CTY_CHINA
  CTY_CANADA <- cc$CTY_CANADA
  CTY_MEXICO <- cc$CTY_MEXICO
  STEEL_CHAPTERS <- cc$STEEL_CHAPTERS
  ALUM_CHAPTERS  <- cc$ALUM_CHAPTERS
  ISO_TO_CENSUS  <- cc$ISO_TO_CENSUS

  # 1. Get footnote-based rates from calculate_rates_fast()
  #    This captures 232, 301, fentanyl, other — but NOT IEEPA reciprocal,
  #    which is a blanket tariff not referenced via product footnotes.
  rates <- calculate_rates_fast(products, ch99_data, countries, stacking_method = stacking_method)

  if (nrow(rates) == 0) {
    message('  No footnote-linked rates for ', revision_id, ' — blanket authorities will seed rows')
    rates <- enforce_rate_schema(tibble())
  }

  # 1b. Check IEEPA invalidation (SCOTUS ruling in Learning Resources v. Trump)
  #     If this revision's effective_date is on or after the invalidation date,
  #     IEEPA tariff authority is void — zero out reciprocal and fentanyl.
  ieepa_invalidation <- pp$IEEPA_INVALIDATION_DATE
  if (!is.null(ieepa_invalidation) && as.Date(effective_date) >= ieepa_invalidation) {
    message('  IEEPA invalidated as of ', ieepa_invalidation,
            ' — zeroing reciprocal and fentanyl for ', revision_id)
    ieepa_rates <- NULL
    fentanyl_rates <- NULL
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

  # Duty-free treatment: 'all' (default) applies IEEPA to all products;
  # 'nonzero_base_only' skips products with 0% MFN base rate (matches TPC).
  duty_free_treatment <- pp$ieepa_duty_free_treatment %||% 'all'
  if (duty_free_treatment != 'all') {
    message('  IEEPA duty-free treatment: ', duty_free_treatment)
  }

  # Load IEEPA product exemptions
  ieepa_exempt_path <- here('resources', 'ieepa_exempt_products.csv')
  ieepa_exempt_products <- if (file.exists(ieepa_exempt_path)) {
    read_csv(ieepa_exempt_path, col_types = cols(hts10 = col_character()))$hts10
  } else {
    warning('ieepa_exempt_products.csv not found — all products subject to IEEPA')
    character(0)
  }
  if (length(ieepa_exempt_products) > 0) {
    message('  IEEPA exempt products loaded: ', length(ieepa_exempt_products))
  }

  # Load floor country product exemptions (EU/Japan/Korea/Swiss)
  # Products exempt from the 15% tariff floor — defined by US Note 2
  # subdivisions (v)(xx)-(xxiv) and Note 3. These are distinct from the
  # general IEEPA Annex A exemptions above.
  # Per-revision file takes priority; falls back to static resource.
  floor_exempt_products <- load_revision_floor_exemptions(revision_id)

  # Load product-level USMCA utilization shares from DataWeb SPI data (S/S+).
  # Year configured in policy_params.yaml (usmca_shares.year). Falls back to binary eligibility.
  usmca_product_shares <- load_usmca_product_shares(policy_params = pp)

  # Load MFN exemption shares (FTA/GSP preference utilization at HS2 x country level).
  # Adjusts statutory base_rate down before stacking. Sourced from Tariff-ETRs.
  mfn_exemption_shares <- if (pp$MFN_EXEMPTION$method == 'hs2') {
    load_mfn_exemption_shares()
  } else {
    NULL
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
      # Build country -> country_group mapping for floor exemption lookup
      has_floor_exempts <- nrow(floor_exempt_products) > 0
      if (has_floor_exempts) {
        floor_country_group_map <- bind_rows(
          tibble(country = pp$EU27_CODES, country_group = 'eu'),
          tibble(country = pp$country_codes$CTY_JAPAN, country_group = 'japan'),
          tibble(country = pp$country_codes$CTY_SKOREA, country_group = 'korea'),
          tibble(country = c(pp$country_codes$CTY_SWITZERLAND,
                             pp$country_codes$CTY_LIECHTENSTEIN), country_group = 'swiss')
        )
        message('  Floor country group map: ', nrow(floor_country_group_map), ' countries across ',
                n_distinct(floor_country_group_map$country_group), ' groups')
      }

      # Override surcharge -> floor for countries in floor_countries config,
      # but ONLY when the surcharge rate exceeds the floor rate. This avoids
      # overriding countries at baseline (10%) in pre-Phase-2 revisions.
      #
      # For Switzerland/Liechtenstein (EO 14346): the override is date-bounded
      # to the framework window. If the extraction already found native floor
      # entries (from expanded 9903.02.82-91 range), those win rate selection
      # and the override is a no-op (checks ieepa_type == 'surcharge').
      #
      # Date logic for Swiss framework:
      #   - Before effective_date (Nov 14, 2025): no override (surcharge applies)
      #   - Between effective and expiry: override applies (surcharge -> floor)
      #   - After expiry (March 31, 2026): no override UNLESS finalized = true
      #   - If finalized: override always applies (no expiry constraint)
      floor_country_codes <- pp$FLOOR_COUNTRIES
      floor_rate <- pp$FLOOR_RATE
      swiss_fw <- pp$SWISS_FRAMEWORK
      rev_date <- as.Date(effective_date)

      # Determine which floor countries are eligible for override at this date.
      # Non-Swiss floor countries (EU, Japan, Korea) always get the override.
      # Swiss countries are date-bounded by the framework agreement.
      swiss_override_active <- FALSE
      if (!is.null(swiss_fw)) {
        # Note: <= for expiry_date is intentional — override is active through
        # the expiry date inclusive ("effective through March 31"). Compare with
        # s122 in get_rates_at_date() which uses > (zeroed after expiry day).
        swiss_override_active <- rev_date >= swiss_fw$effective_date &&
          (swiss_fw$finalized || rev_date <= swiss_fw$expiry_date)
        if (!swiss_override_active) {
          message('  Swiss framework override NOT active for ', effective_date,
                  ' (window: ', swiss_fw$effective_date, ' to ',
                  if (swiss_fw$finalized) 'permanent' else swiss_fw$expiry_date, ')')
        }
      }

      if (length(floor_country_codes) > 0 && !is.null(floor_rate)) {
        # Exclude Swiss countries from override if outside framework window
        eligible_floor_codes <- if (swiss_override_active) {
          floor_country_codes
        } else {
          setdiff(floor_country_codes, swiss_fw$countries)
        }

        override_mask <- country_ieepa$census_code %in% eligible_floor_codes &
                         country_ieepa$ieepa_type == 'surcharge' &
                         country_ieepa$ieepa_country_rate >= floor_rate
        if (any(override_mask)) {
          country_ieepa$ieepa_country_rate[override_mask] <- floor_rate
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
      # and floor country product exemptions (EU/Swiss/Japan/Korea)

      # Build floor exemption lookup: a set of "hts8|country_group" keys
      if (has_floor_exempts) {
        floor_exempt_keys <- floor_exempt_products %>%
          select(hts8, country_group) %>%
          distinct() %>%
          mutate(key = paste0(hts8, '|', country_group)) %>%
          pull(key)
      } else {
        floor_exempt_keys <- character(0)
      }

      rates <- rates %>%
        left_join(
          country_ieepa %>% rename(country = census_code),
          by = 'country'
        )

      # Compute floor exemption flag via vectorized lookup
      if (has_floor_exempts) {
        rates <- rates %>%
          left_join(floor_country_group_map, by = 'country') %>%
          mutate(
            floor_exempt = !is.na(country_group) &
              paste0(substr(hts10, 1, 8), '|', country_group) %in% floor_exempt_keys
          ) %>%
          select(-country_group)
      } else {
        rates <- rates %>% mutate(floor_exempt = FALSE)
      }

      rates <- rates %>%
        mutate(
          rate_ieepa_recip = case_when(
            duty_free_treatment == 'nonzero_base_only' & base_rate < 0.001 ~ 0,  # duty-free exemption
            hts10 %in% ieepa_exempt_products ~ 0,       # general IEEPA exemption (Annex A)
            floor_exempt ~ 0,                             # floor country product exemption
            is.na(ieepa_country_rate) ~ 0,               # country not in IEEPA list
            ieepa_type == 'surcharge' ~ ieepa_country_rate,
            ieepa_type == 'floor' ~ pmax(0, ieepa_country_rate - base_rate),
            ieepa_type == 'passthrough' ~ 0,
            TRUE ~ 0
          )
        ) %>%
        select(-ieepa_country_rate, -floor_exempt)

      # Also add IEEPA rows for products NOT currently in rates
      # (products with no other Ch99 duties but still subject to IEEPA)
      ieepa_country_codes <- country_ieepa$census_code
      ieepa_countries_in_scope <- intersect(ieepa_country_codes, countries)

      existing_pairs <- rates %>%
        filter(country %in% ieepa_countries_in_scope) %>%
        select(hts10, country)

      all_products_base <- products %>%
        filter(!hts10 %in% ieepa_exempt_products) %>%   # exclude exempt products
        { if (duty_free_treatment == 'nonzero_base_only') filter(., base_rate > 0.001) else . } %>%
        select(hts10, base_rate) %>%
        mutate(base_rate = coalesce(base_rate, 0))

      new_pairs <- all_products_base %>%
        tidyr::expand_grid(country = ieepa_countries_in_scope) %>%
        anti_join(existing_pairs, by = c('hts10', 'country')) %>%
        left_join(
          country_ieepa %>% rename(country = census_code),
          by = 'country'
        )

      # Apply floor exemption flag to new_pairs
      if (has_floor_exempts) {
        new_pairs <- new_pairs %>%
          left_join(floor_country_group_map, by = 'country') %>%
          mutate(
            floor_exempt = !is.na(country_group) &
              paste0(substr(hts10, 1, 8), '|', country_group) %in% floor_exempt_keys
          ) %>%
          select(-country_group)
      } else {
        new_pairs <- new_pairs %>% mutate(floor_exempt = FALSE)
      }

      new_pairs <- new_pairs %>%
        mutate(
          rate_232 = 0, rate_301 = 0, rate_ieepa_fent = 0, rate_s122 = 0,
          rate_section_201 = 0, rate_other = 0,
          rate_ieepa_recip = case_when(
            floor_exempt ~ 0,                             # floor country product exemption
            ieepa_type == 'surcharge' ~ ieepa_country_rate,
            ieepa_type == 'floor' ~ pmax(0, ieepa_country_rate - base_rate),
            TRUE ~ 0
          )
        ) %>%
        filter(rate_ieepa_recip > 0) %>%
        select(-ieepa_country_rate, -floor_exempt)

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
    # Some countries have multiple general entries (e.g., China 9903.01.20 +10%
    # and 9903.01.24 +20%) — the later entry supersedes. Take max rate per
    # country to get the effective rate (avoids row multiplication in joins).
    general_fent <- fentanyl_rates %>%
      filter(entry_type == 'general') %>%
      group_by(census_code) %>%
      summarise(fent_rate = max(rate), .groups = 'drop')

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

  # 2b. Grid expansion for post-IEEPA invalidation
  #     When IEEPA is invalidated (SCOTUS ruling), both the reciprocal and
  #     fentanyl blocks above are skipped — which also skips the all-products
  #     x all-countries grid expansion that those blocks normally perform.
  #     Without that grid, many product-country pairs lose their base_rate
  #     representation, causing matched_imports to drop discontinuously and
  #     the weighted ETR to undercount base MFN contributions.
  #
  #     Fix: expand the grid to all products x all countries with zero
  #     additional rates. Downstream blanket tariffs (232, 301, s122) then
  #     fill in their rates on this complete grid.
  ieepa_was_invalidated <- !is.null(ieepa_invalidation) &&
    as.Date(effective_date) >= ieepa_invalidation

  if (ieepa_was_invalidated) {
    existing_pairs <- rates %>% select(hts10, country)

    all_products_base <- products %>%
      select(hts10, base_rate) %>%
      mutate(base_rate = coalesce(base_rate, 0))

    new_grid_pairs <- all_products_base %>%
      tidyr::expand_grid(country = countries) %>%
      anti_join(existing_pairs, by = c('hts10', 'country')) %>%
      mutate(
        rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0,
        rate_ieepa_fent = 0, rate_s122 = 0, rate_section_201 = 0, rate_other = 0
      )

    if (nrow(new_grid_pairs) > 0) {
      message('  Post-IEEPA grid expansion: adding ', nrow(new_grid_pairs),
              ' product-country pairs (base rate only)')
      rates <- bind_rows(rates, new_grid_pairs)
    }
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
  s232_headings <- if (!is.null(pp)) pp$section_232_headings else NULL

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
    wood_products <- character(0)
    mhd_products <- character(0)
    heading_product_lists <- list()

    if (!is.null(s232_headings)) {
      # Gate each heading config on whether its Ch99 program exists in this revision.
      # Programs added progressively: assembled autos at rev_6, parts at rev_11,
      # copper at rev_17, MHD/wood later. Check extracted rates + specific Ch99 codes.
      has_auto_parts_ch99 <- any(grepl('^9903\\.94\\.0[5-9]', ch99_data$ch99_code))
      heading_gates <- list(
        autos_passenger  = s232_rates$auto_rate > 0 || s232_rates$auto_has_deals,
        autos_light_trucks = s232_rates$auto_rate > 0 || s232_rates$auto_has_deals,
        auto_parts       = has_auto_parts_ch99,
        copper           = s232_rates$copper_rate > 0,
        softwood         = s232_rates$wood_rate > 0 || s232_rates$wood_furniture_rate > 0,
        wood_furniture   = s232_rates$wood_rate > 0 || s232_rates$wood_furniture_rate > 0,
        kitchen_cabinets = s232_rates$wood_rate > 0 || s232_rates$wood_furniture_rate > 0,
        mhd_vehicles     = s232_rates$mhd_rate > 0,
        mhd_parts        = s232_rates$mhd_rate > 0,
        buses            = s232_rates$mhd_rate > 0
      )

      for (tariff_name in names(s232_headings)) {
        # Check if this heading's Ch99 program is active in this revision
        gate_val <- heading_gates[[tariff_name]]
        if (!is.null(gate_val) && !gate_val) {
          message('  Skipping 232 heading "', tariff_name, '" — Ch99 entries not in this revision')
          next
        }

        cfg <- s232_headings[[tariff_name]]

        # Product matching: prefer products_file (exact HTS10 list, treated as prefixes)
        # over prefixes_file (text file of prefixes) over inline prefixes.
        matched <- character(0)

        if (!is.null(cfg$products_file)) {
          pf_path <- here(cfg$products_file)
          if (file.exists(pf_path)) {
            copper_list <- read_csv(pf_path, col_types = cols(.default = col_character()))
            # Treat HTS10 codes as prefixes (matches statistical suffixes)
            pf_codes <- copper_list$hts10
            pf_pattern <- paste0('^(', paste(pf_codes, collapse = '|'), ')')
            matched <- products %>%
              filter(grepl(pf_pattern, hts10)) %>%
              pull(hts10)
            message('  232 heading "', tariff_name, '": ', length(matched),
                    ' products from ', basename(pf_path), ' (', length(pf_codes), ' codes)')
          } else {
            message('  WARNING: products_file not found: ', pf_path, ' — falling back to prefixes')
          }
        }

        if (length(matched) == 0) {
          # Fallback: inline prefixes + prefixes_file
          prefixes <- unlist(cfg$prefixes)
          if (!is.null(cfg$prefixes_file)) {
            pf_path <- here(cfg$prefixes_file)
            if (file.exists(pf_path)) {
              prefixes <- c(prefixes, trimws(readLines(pf_path)))
              prefixes <- prefixes[nchar(prefixes) > 0]
            } else {
              message('  WARNING: prefixes_file not found: ', pf_path)
            }
          }
          if (length(prefixes) > 0) {
            pattern <- paste0('^(', paste(prefixes, collapse = '|'), ')')
            matched <- products %>%
              filter(grepl(pattern, hts10)) %>%
              pull(hts10)
          }
        }

        heading_product_lists[[tariff_name]] <- list(
          products = matched,
          rate = cfg$default_rate %||% s232_rates$auto_rate,
          usmca_exempt = cfg$usmca_exempt %||% FALSE
        )

        if (grepl('auto|passenger|light_truck|auto_parts', tariff_name, ignore.case = TRUE)) {
          auto_products <- c(auto_products, matched)
        } else if (grepl('copper', tariff_name, ignore.case = TRUE)) {
          copper_products <- c(copper_products, matched)
        } else if (grepl('softwood|furniture|cabinet', tariff_name, ignore.case = TRUE)) {
          wood_products <- c(wood_products, matched)
        } else if (grepl('mhd|bus|mhd_parts', tariff_name, ignore.case = TRUE)) {
          mhd_products <- c(mhd_products, matched)
        }
      }
    }
    auto_products <- unique(auto_products)
    copper_products <- unique(copper_products)
    wood_products <- unique(wood_products)
    mhd_products <- unique(mhd_products)

    n_steel <- length(steel_products)
    n_alum <- length(aluminum_products)
    n_auto <- length(auto_products)
    n_copper <- length(copper_products)
    n_wood <- length(wood_products)
    n_mhd <- length(mhd_products)
    message('  Section 232 coverage: ', n_steel, ' steel + ', n_alum,
            ' aluminum + ', n_auto, ' auto + ', n_copper, ' copper + ',
            n_wood, ' wood + ', n_mhd, ' MHD products')

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

    # --- Apply HTS-extracted 232 country overrides (e.g., UK deal rates) ---
    # These come from country-specific ch99 entries (e.g., 9903.81.94 UK steel 25%)
    for (cty in names(s232_rates$steel_country_overrides)) {
      idx <- country_232$country == cty
      if (any(idx)) {
        country_232$steel_rate[idx] <- s232_rates$steel_country_overrides[[cty]]
      }
    }
    for (cty in names(s232_rates$aluminum_country_overrides)) {
      idx <- country_232$country == cty
      if (any(idx)) {
        country_232$aluminum_rate[idx] <- s232_rates$aluminum_country_overrides[[cty]]
      }
    }

    # --- Apply config-level 232 country exemptions (TRQ/quota agreements) ---
    # These override rates for countries with trade agreements not encoded in HTS JSON.
    # Date-bounded: only apply if this revision's effective_date is before the expiry.
    rev_date <- as.Date(effective_date)
    n_config_overrides <- 0L
    for (exemption in pp$S232_COUNTRY_EXEMPTIONS) {
      # Check if exemption is active for this revision date
      is_active <- is.null(exemption$expiry_date) || rev_date < exemption$expiry_date
      if (!is_active) next

      affected <- country_232$country %in% exemption$countries
      if (!any(affected)) next

      if ('steel' %in% exemption$applies_to) {
        country_232$steel_rate[affected] <- exemption$rate
      }
      if ('aluminum' %in% exemption$applies_to) {
        country_232$aluminum_rate[affected] <- exemption$rate
      }
      n_config_overrides <- n_config_overrides + sum(affected)
    }
    if (n_config_overrides > 0) {
      message('  232 country exemptions (config): ', n_config_overrides,
              ' country overrides applied for ', effective_date)
    }

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
        # Heading-level 232 rate (auto/MHD/copper/wood). USMCA share-based
        # reduction for CA/MX applied later in step 7, not zeroed here.
        heading_rate_adj = case_when(
          is.na(heading_232_rate) | heading_232_rate == 0 ~ 0,
          TRUE ~ heading_232_rate
        ),
        blanket_232 = case_when(
          chapter %in% STEEL_CHAPTERS ~ coalesce(steel_rate_232, 0),
          chapter %in% ALUM_CHAPTERS ~ coalesce(alum_rate_232, 0),
          heading_rate_adj > 0 ~ heading_rate_adj,
          TRUE ~ 0
        ),
        rate_232 = pmax(rate_232, blanket_232),
        # Track which products have USMCA-eligible 232 headings (for step 7)
        s232_usmca_eligible = coalesce(heading_usmca_exempt, FALSE) & heading_rate_adj > 0
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
          TRUE ~ heading_232_rate
        ),
        rate_232 = case_when(
          chapter %in% STEEL_CHAPTERS ~ coalesce(steel_rate_232, 0),
          chapter %in% ALUM_CHAPTERS ~ coalesce(alum_rate_232, 0),
          heading_rate_adj > 0 ~ heading_rate_adj,
          TRUE ~ 0
        ),
        s232_usmca_eligible = coalesce(heading_usmca_exempt, FALSE) & heading_rate_adj > 0,
        rate_301 = 0, rate_ieepa_recip = 0, rate_ieepa_fent = 0, rate_s122 = 0,
        rate_section_201 = 0, rate_other = 0
      ) %>%
      filter(rate_232 > 0) %>%
      select(-steel_rate_232, -alum_rate_232, -chapter,
             -heading_232_rate, -heading_usmca_exempt, -heading_rate_adj)

    if (nrow(new_232_pairs) > 0) {
      message('  Adding ', nrow(new_232_pairs), ' product-country pairs for 232-only duties')
      rates <- bind_rows(rates, new_232_pairs)
    }
  }

  # Save pre-rebate, pre-deal statutory 232 rates for CSV export.
  # This captures the blanket rate before auto rebate (4b) and deal overrides (4c).
  # ETRs applies rebate and target_total floor logic itself.
  # Derivatives (set in step 5) update this column for their products.
  rates <- rates %>%
    mutate(statutory_rate_232 = rate_232)

  # 4b. Apply Section 232 auto rebate
  #     Reduces effective 232 rate on auto/vehicle products by a credit reflecting
  #     US assembly content: effective_rate -= rebate_rate * us_assembly_share.
  #     Applied before metal content scaling (step 5) and before USMCA (step 7).
  auto_rebate_cfg <- if (!is.null(pp)) pp$auto_rebate else NULL
  rebate_rate <- if (!is.null(auto_rebate_cfg)) auto_rebate_cfg$rebate_rate %||% 0 else 0
  assembly_share <- if (!is.null(auto_rebate_cfg)) auto_rebate_cfg$us_assembly_share %||% 0 else 0
  us_auto_content_share <- if (!is.null(auto_rebate_cfg)) auto_rebate_cfg$us_auto_content_share %||% 1 else 1
  rebate_deduction <- rebate_rate * assembly_share

  if (rebate_deduction > 0 && length(auto_products) > 0) {
    rates <- rates %>%
      mutate(
        rate_232 = if_else(
          hts10 %in% auto_products & rate_232 > 0,
          pmax(rate_232 - rebate_deduction, 0),
          rate_232
        )
      )
    n_rebated <- sum(rates$hts10 %in% auto_products & rates$rate_232 > 0)
    message('  Auto rebate: -', round(rebate_deduction * 100, 2),
            'pp on ', n_rebated, ' auto product-country pairs',
            if (us_auto_content_share < 1) paste0(
              '; USMCA content share: ', us_auto_content_share * 100, '%') else '')
  }

  # 4c. Apply country-specific 232 deal rates (floor/surcharge)
  #     Auto deals: EU/Japan/Korea get 15% floor on vehicles; UK gets +7.5% surcharge.
  #     Wood deals: UK 10% floor on softwood, EU/Japan/Korea 15% floor on furniture/cabinets.
  #     Floor mechanism: effective_232 = max(floor_rate - base_rate, 0)
  #     Surcharge mechanism: effective_232 = surcharge_rate (flat)
  #     These override the blanket 232 rate set in step 4 for deal countries.
  n_deal_overrides <- 0L

  # Helper: convert ISO country code to Census code(s), expanding EU to 27 members
  iso_to_census_vec <- function(iso_code) {
    if (iso_code == 'EU') {
      return(if (!is.null(pp)) names(pp$eu27_codes) else EU27_CODES)
    }
    census <- ISO_TO_CENSUS[iso_code]
    if (is.na(census)) return(character(0))
    as.character(census)
  }

  # Apply auto deal rates
  if (nrow(s232_rates$auto_deal_rates) > 0 && length(auto_products) > 0) {
    for (i in seq_len(nrow(s232_rates$auto_deal_rates))) {
      deal <- s232_rates$auto_deal_rates[i, ]
      census_codes <- iso_to_census_vec(deal$country)
      if (length(census_codes) == 0) next

      # Determine which products this deal covers (vehicles vs parts)
      # Split auto_products into vehicles and parts using heading config prefixes
      auto_vehicles_cfg <- s232_headings[grepl('passenger|light_truck', names(s232_headings), ignore.case = TRUE)]
      vehicle_prefixes <- unlist(lapply(auto_vehicles_cfg, function(x) x$prefixes))
      deal_products <- if (deal$program == 'auto_parts') {
        # Parts: products NOT in passenger vehicle/light truck prefixes
        if (length(vehicle_prefixes) > 0) {
          veh_pattern <- paste0('^(', paste(vehicle_prefixes, collapse = '|'), ')')
          auto_products[!grepl(veh_pattern, auto_products)]
        } else {
          auto_products
        }
      } else {
        # Vehicles: only passenger vehicle/light truck prefix products
        if (length(vehicle_prefixes) > 0) {
          veh_pattern <- paste0('^(', paste(vehicle_prefixes, collapse = '|'), ')')
          auto_products[grepl(veh_pattern, auto_products)]
        } else {
          auto_products
        }
      }

      if (deal$rate_type == 'floor') {
        rates <- rates %>%
          mutate(
            rate_232 = if_else(
              hts10 %in% deal_products & country %in% census_codes,
              pmax(deal$rate - base_rate, 0),
              rate_232
            )
          )
      } else {
        # surcharge: flat additional rate
        rates <- rates %>%
          mutate(
            rate_232 = if_else(
              hts10 %in% deal_products & country %in% census_codes,
              deal$rate,
              rate_232
            )
          )
      }
      n_affected <- sum(rates$hts10 %in% deal_products & rates$country %in% census_codes)
      n_deal_overrides <- n_deal_overrides + n_affected
    }
  }

  # Apply wood deal rates
  # Identify wood product sets by heading config
  wood_softwood_products <- character(0)
  wood_furn_products <- character(0)
  if (!is.null(s232_headings)) {
    for (nm in names(s232_headings)) {
      cfg <- s232_headings[[nm]]
      prefixes <- unlist(cfg$prefixes)
      if (length(prefixes) == 0) next
      pattern <- paste0('^(', paste(prefixes, collapse = '|'), ')')
      matched <- products %>% filter(grepl(pattern, hts10)) %>% pull(hts10)
      if (grepl('softwood', nm, ignore.case = TRUE)) {
        wood_softwood_products <- c(wood_softwood_products, matched)
      } else if (grepl('furniture|cabinet', nm, ignore.case = TRUE)) {
        wood_furn_products <- c(wood_furn_products, matched)
      }
    }
  }
  all_wood_products <- unique(c(wood_softwood_products, wood_furn_products))

  if (nrow(s232_rates$wood_deal_rates) > 0 && length(all_wood_products) > 0) {
    for (i in seq_len(nrow(s232_rates$wood_deal_rates))) {
      deal <- s232_rates$wood_deal_rates[i, ]
      census_codes <- iso_to_census_vec(deal$country)
      if (length(census_codes) == 0) next

      # Wood deals apply to all wood products (softwood + furniture/cabinets)
      if (deal$rate_type == 'floor') {
        rates <- rates %>%
          mutate(
            rate_232 = if_else(
              hts10 %in% all_wood_products & country %in% census_codes,
              pmax(deal$rate - base_rate, 0),
              rate_232
            )
          )
      } else {
        rates <- rates %>%
          mutate(
            rate_232 = if_else(
              hts10 %in% all_wood_products & country %in% census_codes,
              deal$rate,
              rate_232
            )
          )
      }
      n_affected <- sum(rates$hts10 %in% all_wood_products & rates$country %in% census_codes)
      n_deal_overrides <- n_deal_overrides + n_affected
    }
  }

  if (n_deal_overrides > 0) {
    message('  232 deal rates (floor/surcharge): ', n_deal_overrides,
            ' product-country pairs overridden')
  }

  # 5. Apply Section 232 derivative tariff + metal content scaling
  #    Derivative products (9903.85.04/.07/.08) are aluminum-containing articles
  #    outside chapter 76. The tariff applies only to the metal content portion.
  # Build heading product list from prefixes of ACTIVE headings only.
  # Products matching active heading prefixes are non-metal 232 programs
  # and should NOT be metal-scaled even if they also match derivative prefixes.
  # Inactive headings' products should be treated as pure derivatives.
  all_heading_hts10 <- character(0)
  if (!is.null(s232_headings)) {
    for (nm in names(s232_headings)) {
      # Skip inactive headings — their products are pure derivatives
      gate_val <- heading_gates[[nm]]
      if (!is.null(gate_val) && !gate_val) next
      cfg <- s232_headings[[nm]]
      prefixes <- cfg$prefixes %||% character(0)
      if (!is.null(cfg$prefixes_file)) {
        pf <- here(cfg$prefixes_file)
        if (file.exists(pf)) prefixes <- c(prefixes, trimws(readLines(pf, warn = FALSE)))
      }
      if (!is.null(cfg$products_file)) {
        pf <- here(cfg$products_file)
        if (file.exists(pf)) {
          prods <- read_csv(pf, show_col_types = FALSE,
                            col_types = cols(.default = col_character()))
          prefixes <- c(prefixes, prods$hts10)
        }
      }
      prefixes <- unique(prefixes[nchar(prefixes) > 0])
      if (length(prefixes) > 0) {
        pattern <- paste0('^(', paste(prefixes, collapse = '|'), ')')
        matched <- products$hts10[grepl(pattern, products$hts10)]
        all_heading_hts10 <- c(all_heading_hts10, matched)
      }
    }
    all_heading_hts10 <- unique(all_heading_hts10)
  }
  result <- apply_232_derivatives(rates, products, ch99_data, s232_rates, countries,
                                   heading_products = all_heading_hts10,
                                   policy_params = .pp)
  rates <- result$rates
  deriv_matched <- result$deriv_matched

  # 6. Apply Section 301 as blanket tariff for China
  #     301 products are defined by US Note 20/21/31 product lists (Federal Register).
  #     Like 232, these are NOT referenced via product footnotes for most products.
  #     Source: USITC "China Tariffs" reference document (hts.usitc.gov).
  #
  #     Scope note: This blanket step is intentionally limited to the China
  #     Section 301 product lists maintained in resources/s301_product_lists.csv.
  #     It does not use 9903.89.xx, which belongs to the separate large civil
  #     aircraft dispute with the EU/UK and is assumed suspended from 2021 onward
  #     for the current series horizon.
  s301_products_path <- here('resources', 's301_product_lists.csv')
  if (!file.exists(s301_products_path)) {
    stop('s301_product_lists.csv not found at ', s301_products_path,
         '\nSection 301 is a major tariff authority — cannot build without product lists.')
  }
  if (file.exists(s301_products_path)) {
    s301_products <- read_csv(s301_products_path, col_types = cols(
      hts8 = col_character(), list = col_character(), ch99_code = col_character()
    ))

    # Get active 301 ch99 codes from this revision's Ch99 data
    # Use SECTION_301_RATES config for reliable rate values
    s301_rate_lookup <- if (!is.null(pp)) {
      pp$SECTION_301_RATES
    } else {
      tibble(ch99_pattern = character(), s301_rate = numeric())
    }

    # Filter to 301 codes present in this revision's Ch99 data, excluding any
    # that are marked as suspended (e.g. 9903.88.16 List 4B since rev_4).
    # The HTS JSON retains suspended entries with their original rate but adds
    # "[Compiler's note: provision suspended.]" to the description.
    active_301_codes <- ch99_data %>%
      filter(ch99_code %in% s301_rate_lookup$ch99_pattern) %>%
      filter(!grepl('provision suspended', description, ignore.case = TRUE)) %>%
      pull(ch99_code) %>%
      unique()

    suspended_301 <- setdiff(
      ch99_data$ch99_code[ch99_data$ch99_code %in% s301_rate_lookup$ch99_pattern],
      active_301_codes
    )
    if (length(suspended_301) > 0) {
      message('  Section 301: excluding suspended codes: ',
              paste(suspended_301, collapse = ', '))
    }

    if (length(active_301_codes) > 0) {
      # Build HTS8 -> 301 rate lookup:
      # Take MAX(s301_rate) across all ch99 codes per HTS8. For the 8 products
      # that appear on both Trump-era (9903.88.xx) and Biden-era (9903.91.xx)
      # lists, Biden rates are always >= the corresponding Trump rate, so MAX
      # achieves the correct supersession. This matches Tariff-ETRs, which
      # partitions products into exclusive rate buckets (one rate per HS10).
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
              rate_ieepa_fent = 0, rate_s122 = 0, rate_section_201 = 0, rate_other = 0,
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

  # 6b. Apply Section 122 blanket tariff (non-discriminatory, all countries)
  #     Section 122 (Trade Act of 1974) is a uniform tariff applied after SCOTUS
  #     invalidated IEEPA. Product exemptions from Annex II list; 232 mutual
  #     exclusion handled by apply_stacking_rules().
  #     Section 122 has a 150-day statutory limit; gate on expiry unless finalized.
  s122_rates <- extract_section122_rates(ch99_data)

  s122_in_force <- TRUE
  if (!is.null(pp$SECTION_122) && !pp$SECTION_122$finalized) {
    s122_in_force <- (as.Date(effective_date) >= pp$SECTION_122$effective_date &&
                      as.Date(effective_date) <= pp$SECTION_122$expiry_date)
  }

  if (s122_rates$has_s122 && !s122_in_force) {
    message('  Section 122 expired (', pp$SECTION_122$expiry_date, ') — not applied')
  }

  if (s122_rates$has_s122 && s122_in_force) {
    s122_rate <- s122_rates$s122_rate

    # Load product exemptions (Annex II)
    s122_exempt_path <- here('resources', 's122_exempt_products.csv')
    s122_exempt_hts8 <- if (file.exists(s122_exempt_path)) {
      read_csv(s122_exempt_path, col_types = cols(hts8 = col_character()))$hts8
    } else {
      message('  WARNING: s122_exempt_products.csv not found — no exemptions applied')
      character(0)
    }
    if (length(s122_exempt_hts8) > 0) {
      message('  Section 122 exempt products: ', length(s122_exempt_hts8), ' HTS8 codes')
    }

    # Set rate_s122 for all existing rows
    rates <- rates %>%
      mutate(
        rate_s122 = if_else(
          substr(hts10, 1, 8) %in% s122_exempt_hts8,
          0, s122_rate
        )
      )

    # Add s122-only rows for products not yet in rates
    s122_country_rates <- tibble(
      country = countries,
      blanket_rate = s122_rate
    )
    # All products are covered (non-exempt)
    non_exempt_hts10 <- products %>%
      filter(!substr(hts10, 1, 8) %in% s122_exempt_hts8) %>%
      pull(hts10)
    rates <- add_blanket_pairs(rates, products, non_exempt_hts10, s122_country_rates,
                               'rate_s122', 'Section 122 duties')

    n_with_s122 <- sum(rates$rate_s122 > 0)
    message('  Section 122: ', round(s122_rate * 100), '% on ',
            n_with_s122, ' product-country pairs (',
            length(s122_exempt_hts8), ' HTS8 exempt)')
  }

  # Save statutory rates for all non-232 authorities (pre-USMCA, pre-stacking).
  # 232 statutory rates are already saved as statutory_rate_232 in apply_232_derivatives().
  rates <- rates %>%
    mutate(
      statutory_rate_ieepa_recip = rate_ieepa_recip,
      statutory_rate_ieepa_fent  = rate_ieepa_fent,
      statutory_rate_301         = rate_301,
      statutory_rate_s122        = rate_s122,
      statutory_rate_section_201 = rate_section_201,
      statutory_rate_other       = rate_other
    )

  # 6c. Apply MFN exemption shares (FTA/GSP preference adjustment)
  # Reduces statutory base_rate using HS2 x country exemption shares from Census
  # calculated duty data. Preserves statutory_base_rate for reference.
  # CA/MX excluded when USMCA product shares handle them at HTS10 level (step 7).
  rates <- rates %>%
    mutate(statutory_base_rate = base_rate)

  if (!is.null(mfn_exemption_shares) && nrow(mfn_exemption_shares) > 0) {
    exclude_usmca <- pp$MFN_EXEMPTION$exclude_usmca_countries
    usmca_countries <- c(CTY_CANADA, CTY_MEXICO)

    rates <- rates %>%
      mutate(hs2 = substr(hts10, 1, 2)) %>%
      left_join(
        mfn_exemption_shares %>% select(hs2, cty_code, exemption_share),
        by = c('hs2', 'country' = 'cty_code')
      ) %>%
      mutate(
        exemption_share = coalesce(exemption_share, 0),
        # Skip CA/MX if configured (USMCA handles them in step 7)
        exemption_share = if_else(
          exclude_usmca & country %in% usmca_countries,
          0, exemption_share
        ),
        base_rate = base_rate * (1 - exemption_share)
      ) %>%
      select(-hs2, -exemption_share)

    n_adjusted <- sum(rates$base_rate < rates$statutory_base_rate)
    message('  MFN exemption shares: adjusted base_rate for ', n_adjusted,
            ' product-country pairs')

    # 6d. Recompute IEEPA floor deduction against post-MFN base_rate.
    # Only for rows originally computed as floor-type (ieepa_type == 'floor').
    # Step 2 computed floor as max(0, floor_rate - statutory_base); now base_rate is
    # lower (after FTA/GSP preference in 6c), so the floor gap is wider.
    # Surcharge rows for floor countries (e.g. Swiss/LI outside framework window)
    # must NOT be recomputed — their rate is a flat surcharge, not a floor deduction.
    floor_rate_val <- pp$FLOOR_RATE
    if (!is.null(floor_rate_val) &&
        'rate_ieepa_recip' %in% names(rates) &&
        'ieepa_type' %in% names(rates)) {
      floor_mask <- rates$ieepa_type == 'floor' &
                    rates$rate_ieepa_recip > 0 &
                    rates$base_rate < rates$statutory_base_rate
      if (any(floor_mask)) {
        old_recip <- rates$rate_ieepa_recip[floor_mask]
        rates$rate_ieepa_recip[floor_mask] <- pmax(0, floor_rate_val - rates$base_rate[floor_mask])
        n_floor_adjusted <- sum(rates$rate_ieepa_recip[floor_mask] != old_recip)
        message('  Floor recomputation: updated rate_ieepa_recip for ', n_floor_adjusted,
                ' floor-type pairs (against post-MFN base_rate)')
      }
    }

    # Drop transient ieepa_type column — not part of production output
    rates$ieepa_type <- NULL
  }

  # 7. Apply USMCA exemptions
  # TPC methodology: rate * (1 - usmca_share) for each CA/MX product.
  # If Census SPI shares available (from compute_usmca_shares.R), apply to ALL
  # CA/MX products — the share naturally handles eligibility (products that never
  # enter under USMCA have share ≈ 0, fully-claiming products have share ≈ 1).
  # Also applies to 232 auto/MHD products flagged s232_usmca_eligible (T1 fix).
  # Falls back to binary eligibility (S/S+ → zero rate) if shares not available.
  if (!is.null(usmca) && nrow(usmca) > 0) {
    rates <- rates %>%
      left_join(
        usmca %>% select(hts10, usmca_eligible),
        by = 'hts10'
      ) %>%
      mutate(usmca_eligible = coalesce(usmca_eligible, FALSE))

    if (!is.null(usmca_product_shares) && nrow(usmca_product_shares) > 0) {
      # Census SPI shares: apply to all CA/MX products
      rates <- rates %>%
        left_join(
          usmca_product_shares,
          by = c('hts10', 'country' = 'cty_code')
        ) %>%
        mutate(
          usmca_share = if_else(
            country %in% c(CTY_CANADA, CTY_MEXICO),
            coalesce(usmca_share, 0), 0
          ),
          base_rate = base_rate * (1 - usmca_share),
          rate_ieepa_recip = rate_ieepa_recip * (1 - usmca_share),
          rate_ieepa_fent = rate_ieepa_fent * (1 - usmca_share),
          rate_s122 = rate_s122 * (1 - usmca_share),
          # Apply USMCA shares to 232 auto/MHD (heading products with usmca_exempt flag)
          # Steel/aluminum 232 are NOT USMCA-eligible — only heading-level tariffs
          # Auto/MHD products use adjusted USMCA share: usmca_share * us_auto_content_share
          # (only ~40% of USMCA-eligible vehicle value is US/USMCA-origin content)
          rate_232 = if_else(
            coalesce(s232_usmca_eligible, FALSE) & country %in% c(CTY_CANADA, CTY_MEXICO),
            if_else(
              hts10 %in% c(auto_products, mhd_products),
              rate_232 * (1 - usmca_share * us_auto_content_share),
              rate_232 * (1 - usmca_share)
            ),
            rate_232
          )
        ) %>%
        select(-usmca_share)
    } else {
      # Fallback: binary USMCA from HTS special field
      rates <- rates %>%
        mutate(
          rate_ieepa_recip = if_else(
            country %in% c(CTY_CANADA, CTY_MEXICO) & usmca_eligible,
            0, rate_ieepa_recip
          ),
          rate_ieepa_fent = if_else(
            country %in% c(CTY_CANADA, CTY_MEXICO) & usmca_eligible,
            0, rate_ieepa_fent
          ),
          rate_s122 = if_else(
            country %in% c(CTY_CANADA, CTY_MEXICO) & usmca_eligible,
            0, rate_s122
          ),
          # Binary fallback: 232 for USMCA-eligible CA/MX auto/MHD
          # Auto/MHD: scale by (1 - us_auto_content_share); others: zero
          rate_232 = if_else(
            coalesce(s232_usmca_eligible, FALSE) &
              country %in% c(CTY_CANADA, CTY_MEXICO) & usmca_eligible,
            if_else(
              hts10 %in% c(auto_products, mhd_products),
              rate_232 * (1 - us_auto_content_share),
              0
            ),
            rate_232
          )
        )
    }
  } else {
    rates <- rates %>% mutate(usmca_eligible = FALSE)
  }

  # Clean up intermediate flag
  rates$s232_usmca_eligible <- NULL

  # 8. Re-apply stacking rules with updated IEEPA and 232 rates
  rates <- apply_stacking_rules(rates, CTY_CHINA, stacking_method = stacking_method)

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
  n_with_s122 <- sum(rates$rate_s122 > 0)
  n_usmca <- sum(rates$usmca_eligible)
  message('  Products-countries: ', nrow(rates))
  message('  With IEEPA reciprocal: ', n_with_ieepa)
  message('  With Section 232: ', n_with_232)
  message('  With Section 301: ', n_with_301)
  message('  With Section 122: ', n_with_s122)
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
