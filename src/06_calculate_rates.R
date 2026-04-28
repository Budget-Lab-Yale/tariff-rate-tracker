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
#   6b2. Dense grid expansion (surface MFN-only product-country pairs)
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
# No module-level globals — all constants are passed as function parameters
# from calculate_rates_for_revision() or loaded explicitly in standalone mode.


# =============================================================================
# Vectorized Rate Calculation (footnote-based)
# =============================================================================

#' Fast vectorized rate calculation (for large datasets)
#'
#' @param products Product data
#' @param ch99_data Chapter 99 data
#' @param countries Vector of country codes
#' @return Tibble with rates
calculate_rates_fast <- function(products, ch99_data, countries,
                                 stacking_method = 'mutual_exclusion',
                                 iso_to_census = NULL, cty_china = '5700') {
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

  # For each product-country, determine applicable rates.
  # Pre-compute a (ch99_code, country) applicability mapping from the ~100-300
  # ch99 entries, then inner_join against product refs. This replaces the prior
  # expand_grid + rowwise approach that created ~2M rows and called
  # check_country_applies() per row.

  # Build Census <-> ISO bidirectional lookup
  if (is.null(iso_to_census)) {
    iso_to_census <- get_country_constants()$ISO_TO_CENSUS
  }
  census_to_iso <- setNames(names(iso_to_census), iso_to_census)

  # Pre-compute applicable Census country codes per ch99 entry
  ch99_for_map <- ch99_lookup %>%
    select(ch99_code, country_type, countries, exempt_countries) %>%
    distinct(ch99_code, .keep_all = TRUE)

  country_vec <- countries
  applicable_pairs <- map_dfr(seq_len(nrow(ch99_for_map)), function(i) {
    row <- ch99_for_map[i, ]
    applicable <- switch(
      row$country_type,
      'all' = country_vec,
      'all_except' = {
        exempt_iso <- row$exempt_countries[[1]]
        exempt_census <- as.character(iso_to_census[exempt_iso])
        exempt_census <- exempt_census[!is.na(exempt_census)]
        # Exempt entries may also be raw Census codes
        setdiff(country_vec, unique(c(exempt_census, exempt_iso)))
      },
      'specific' = {
        specific_iso <- row$countries[[1]]
        specific_census <- as.character(iso_to_census[specific_iso])
        specific_census <- specific_census[!is.na(specific_census)]
        # Match country_vec against both Census-converted and raw codes
        intersect(country_vec, unique(c(specific_census, specific_iso)))
      },
      character(0)  # 'unknown' and others: fail-closed, no countries
    )
    if (length(applicable) > 0) {
      tibble(ch99_code = row$ch99_code, country = applicable)
    } else {
      tibble(ch99_code = character(), country = character())
    }
  })

  message('  Applicability pairs: ', nrow(applicable_pairs),
          ' (from ', nrow(ch99_for_map), ' ch99 entries x ', length(country_vec), ' countries)')

  # Join: product-ch99 refs × applicable countries (replaces expand_grid + rowwise)
  full_expansion <- product_ch99_rates %>%
    inner_join(applicable_pairs, by = 'ch99_code', relationship = 'many-to-many')

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
      by = 'hts10',
      relationship = 'many-to-one'
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
  rates_final <- apply_stacking_rules(rates_wide, cty_china, stacking_method = stacking_method)

  return(rates_final)
}


#' Check if country applies to a Chapter 99 entry
#'
#' @param country Census country code
#' @param country_type Type from Ch99 data
#' @param countries List of applicable countries
#' @param exempt List of exempt countries
#' @return Logical
check_country_applies <- function(country, country_type, countries, exempt,
                                  iso_to_census = NULL) {
  # Defensive checks
  if (length(country) == 0 || is.na(country)) return(FALSE)
  if (length(country_type) == 0 || is.na(country_type)) return(FALSE)

  # Convert Census to ISO for matching
  if (is.null(iso_to_census)) {
    iso_to_census <- get_country_constants()$ISO_TO_CENSUS
  }
  country_iso <- names(iso_to_census)[match(country, iso_to_census)]
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
# Section 232 Heading Product Matching
# =============================================================================

#' Match HTS10 products covered by a Section 232 heading config.
#'
#' Resolves products via the three-way fallback used by entries in
#' `policy_params$section_232_headings`:
#'   1. `cfg$products_file` — CSV with an `hts10` column, treated as prefixes.
#'      Authoritative when present. Matches are logged at INFO level.
#'   2. `cfg$prefixes_file` — text file, one prefix per line. Appended to (3).
#'   3. `cfg$prefixes` — inline character vector in the yaml.
#' Source 1 takes precedence when it produces any matches. Sources 2+3 combine
#' as fallback; they also combine for headings that have no products_file at all.
#'
#' Previously duplicated verbatim in two separate loops inside
#' `calculate_rates_for_revision()` (step 4 for rate assignment, step 5 for
#' derivative-overlap exclusion). Extracted so the two callers stay in lockstep.
#'
#' @param cfg Named list — a single entry from section_232_headings.
#' @param products Tibble with an `hts10` character column.
#' @param tariff_name Heading name, used only in log/warning text.
#' @param verbose Step 4 calls with verbose = TRUE; step 5 re-reads the same
#'   configs with verbose = FALSE to avoid emitting the same log line twice.
#' @return Character vector of matched HTS10 codes (possibly empty).
match_232_heading_products <- function(cfg, products,
                                        tariff_name = NA_character_,
                                        verbose = TRUE) {
  matched <- character(0)

  if (!is.null(cfg$products_file)) {
    pf_path <- here(cfg$products_file)
    if (file.exists(pf_path)) {
      pf_data <- read_csv(pf_path,
                          col_types = cols(.default = col_character()),
                          show_col_types = FALSE)
      pf_codes <- pf_data$hts10
      pf_pattern <- paste0('^(', paste(pf_codes, collapse = '|'), ')')
      matched <- products$hts10[grepl(pf_pattern, products$hts10)]
      if (verbose) {
        message('  232 heading "', tariff_name, '": ', length(matched),
                ' products from ', basename(pf_path),
                ' (', length(pf_codes), ' codes)')
      }
    } else if (verbose) {
      warning('232 heading "', tariff_name, '": products_file not found: ',
              pf_path, ' — falling back to inline prefixes')
    }
  }

  if (length(matched) == 0) {
    prefixes <- unlist(cfg$prefixes %||% character(0))
    if (!is.null(cfg$prefixes_file)) {
      pf_path <- here(cfg$prefixes_file)
      if (file.exists(pf_path)) {
        prefixes <- c(prefixes, trimws(readLines(pf_path, warn = FALSE)))
      } else if (verbose) {
        warning('232 heading "', tariff_name, '": prefixes_file not found: ', pf_path)
      }
    }
    prefixes <- unique(prefixes[nchar(prefixes) > 0])
    if (length(prefixes) > 0) {
      pattern <- paste0('^(', paste(prefixes, collapse = '|'), ')')
      matched <- products$hts10[grepl(pattern, products$hts10)]
    }
  }

  matched
}


# =============================================================================
# Section 232 Derivative Products
# =============================================================================

#' Apply Section 232 derivative tariff and metal content scaling
#'
#' Derivative products include both aluminum-containing articles outside
#' chapter 76 (9903.85.04/.07/.08) and steel-containing articles outside
#' chapters 72-73 (9903.81.89-93, added via Section 232 Inclusions Process,
#' FR 2025-15819). The tariff applies only to the metal content portion
#' of customs value. This function:
#'   1. Loads the product list from resources/s232_derivative_products.csv
#'   2. Matches products by prefix, split by derivative_type (steel/aluminum)
#'   3. Applies derivative 232 rates per type (update existing + add new pairs)
#'   4. Joins metal content shares and scales rate_232 by per-type share
#'   5. Tags products with deriv_type for use in stacking rules
#'
#' @param rates Current rates tibble
#' @param products Product data from parse_products()
#' @param ch99_data Chapter 99 data (to check for derivative Ch99 entries)
#' @param s232_rates Section 232 rates from extract_section232_rates()
#' @param countries Vector of Census country codes
#' @param deriv_products Optional pre-loaded output of
#'   `load_232_derivative_products(effective_date)`. If NULL the function loads
#'   it internally — but the typical caller (calculate_rates_for_revision)
#'   passes a pre-loaded value so the same CSV isn't read twice per build
#'   (step 5 and step 5c both need the derivative prefix list).
#' @return List with 'rates' (updated tibble) and 'deriv_matched' (character vector)
apply_232_derivatives <- function(rates, products, ch99_data, s232_rates, countries,
                                  heading_products = character(0),
                                  policy_params = NULL,
                                  effective_date = NULL,
                                  deriv_products = NULL) {
  if (is.null(deriv_products)) {
    deriv_products <- load_232_derivative_products(effective_date = effective_date)
  }
  deriv_matched <- character(0)

  # Initialize deriv_type column (used by stacking rules to select per-type share)
  if (!'deriv_type' %in% names(rates)) {
    rates <- rates %>% mutate(deriv_type = NA_character_)
  }

  if (!is.null(deriv_products) && nrow(deriv_products) > 0 && s232_rates$has_232) {
    # Check if derivative Ch99 entries exist in this revision (either type)
    alum_deriv_ch99 <- c('9903.85.04', '9903.85.07', '9903.85.08')
    steel_deriv_ch99 <- c('9903.81.89', '9903.81.90', '9903.81.91', '9903.81.93')
    has_alum_deriv <- any(ch99_data$ch99_code %in% alum_deriv_ch99)
    has_steel_deriv <- any(ch99_data$ch99_code %in% steel_deriv_ch99)

    if (has_alum_deriv || has_steel_deriv) {
      # Split product list by derivative type
      alum_products <- deriv_products %>% filter(derivative_type == 'aluminum')
      steel_products <- deriv_products %>% filter(derivative_type == 'steel')

      # --- Aluminum derivatives ---
      alum_matched <- character(0)
      if (has_alum_deriv && nrow(alum_products) > 0) {
        alum_prefixes <- alum_products$hts_prefix
        alum_pattern <- paste0('^(', paste(alum_prefixes, collapse = '|'), ')')
        alum_matched <- products %>%
          filter(grepl(alum_pattern, hts10)) %>% pull(hts10)

        if (length(alum_matched) > 0) {
          country_alum <- tibble(country = countries) %>%
            mutate(
              deriv_exempt = map_lgl(country, ~is_232_exempt(.x, s232_rates$aluminum_derivative_exempt)),
              deriv_rate = if_else(deriv_exempt, 0, s232_rates$aluminum_derivative_rate)
            )
          rates <- rates %>%
            left_join(country_alum %>% select(country, .alum_deriv_rate = deriv_rate), by = 'country', relationship = 'many-to-one') %>%
            mutate(
              .alum_deriv_rate = coalesce(.alum_deriv_rate, 0),
              rate_232 = if_else(hts10 %in% alum_matched & .alum_deriv_rate > 0,
                                 pmax(rate_232, .alum_deriv_rate), rate_232),
              deriv_type = if_else(hts10 %in% alum_matched & .alum_deriv_rate > 0,
                                   'aluminum', deriv_type)
            ) %>% select(-.alum_deriv_rate)
          blanket_alum <- country_alum %>% select(country, blanket_rate = deriv_rate)
          rates <- add_blanket_pairs(rates, products, alum_matched, blanket_alum,
                                     'rate_232', '232 aluminum derivative duties')
          # Tag newly added pairs
          rates <- rates %>%
            mutate(deriv_type = if_else(hts10 %in% alum_matched & is.na(deriv_type) & rate_232 > 0,
                                         'aluminum', deriv_type))
          message('  Aluminum derivative coverage: ', length(alum_matched), ' products')
        }
      }

      # --- Steel derivatives ---
      steel_matched <- character(0)
      if (has_steel_deriv && nrow(steel_products) > 0) {
        steel_prefixes <- steel_products$hts_prefix
        steel_pattern <- paste0('^(', paste(steel_prefixes, collapse = '|'), ')')
        steel_matched <- products %>%
          filter(grepl(steel_pattern, hts10)) %>% pull(hts10)

        if (length(steel_matched) > 0) {
          country_steel <- tibble(country = countries) %>%
            mutate(
              deriv_exempt = map_lgl(country, ~is_232_exempt(.x, s232_rates$steel_derivative_exempt)),
              deriv_rate = if_else(deriv_exempt, 0, s232_rates$steel_derivative_rate)
            )
          rates <- rates %>%
            left_join(country_steel %>% select(country, .steel_deriv_rate = deriv_rate), by = 'country', relationship = 'many-to-one') %>%
            mutate(
              .steel_deriv_rate = coalesce(.steel_deriv_rate, 0),
              rate_232 = if_else(hts10 %in% steel_matched & .steel_deriv_rate > 0,
                                 pmax(rate_232, .steel_deriv_rate), rate_232),
              # Products in both types: steel takes precedence for deriv_type
              # (stacking uses steel_share, which is correct since steel content
              # is what triggers the steel derivative classification)
              deriv_type = if_else(hts10 %in% steel_matched & .steel_deriv_rate > 0,
                                   'steel', deriv_type)
            ) %>% select(-.steel_deriv_rate)
          blanket_steel <- country_steel %>% select(country, blanket_rate = deriv_rate)
          rates <- add_blanket_pairs(rates, products, steel_matched, blanket_steel,
                                     'rate_232', '232 steel derivative duties')
          rates <- rates %>%
            mutate(deriv_type = if_else(hts10 %in% steel_matched & is.na(deriv_type) & rate_232 > 0,
                                         'steel', deriv_type))
          message('  Steel derivative coverage: ', length(steel_matched), ' products')
        }
      }

      deriv_matched <- union(alum_matched, steel_matched)
      message('  Section 232 derivative coverage (total): ', length(deriv_matched), ' products')
    }
  }

  # Update statutory_rate_232 for derivative products only (pre-metal-scaling).
  # Non-derivative products already have statutory_rate_232 set after step 4c.
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
  if (is.null(policy_params)) {
    stop('apply_232_derivatives() requires policy_params — cannot use NULL fallback')
  }
  pp_local <- policy_params
  metal_cfg <- if (!is.null(pp_local)) pp_local$metal_content else NULL
  metal_shares <- load_metal_content(metal_cfg, unique(rates$hts10), deriv_matched)
  if ('metal_share' %in% names(rates)) {
    rates <- rates %>% select(-metal_share)
  }
  rates <- rates %>%
    left_join(metal_shares, by = 'hts10', relationship = 'many-to-one') %>%
    mutate(metal_share = coalesce(metal_share, 1.0))
  n_missing_share <- sum(is.na(metal_shares$metal_share[metal_shares$hts10 %in% deriv_matched]))
  if (n_missing_share > 0) {
    warning(n_missing_share, ' derivative products have no metal_share data — defaulting to 1.0 (no scaling)')
  }

  if (length(deriv_matched) > 0) {
    # Scale by per-type share: aluminum derivatives use aluminum_share,
    # steel derivatives use steel_share. The derivative tariff only applies to
    # the relevant metal content; the other metal fractions are covered by IEEPA
    # via nonmetal_share in stacking. This matches ETRs' per-type scaling.
    #
    # Skip scaling for derivatives that also have a heading rate (e.g., auto parts
    # that are also aluminum derivatives). The heading rate dominates and shouldn't
    # be metal-scaled — ETRs handles this via per-program pmax.
    metal_method <- if (!is.null(metal_cfg)) metal_cfg$method %||% 'flat' else 'flat'
    has_per_type <- identical(metal_method, 'bea') &&
      all(c('steel_share', 'aluminum_share') %in% names(rates))

    # Exclude primary chapter products (72/73/76) and heading products from
    # derivative metal scaling. Primary chapters get blanket 232 rates (full product);
    # heading products get heading rates (full product). Only true derivatives
    # (outside primary chapters, not heading-matched) should be metal-scaled.
    p_chapters <- if (!is.null(pp_local)) unlist(pp_local$metal_content$primary_chapters) else c('72', '73', '76')
    primary_hts10 <- rates %>% distinct(hts10) %>%
      filter(substr(hts10, 1, 2) %in% p_chapters) %>% pull(hts10)
    deriv_only <- setdiff(deriv_matched, c(heading_products, primary_hts10))

    if (has_per_type) {
      # Per-type scaling: aluminum derivatives by aluminum_share, steel by steel_share
      rates <- rates %>%
        mutate(
          .scale_share = case_when(
            hts10 %in% deriv_only & deriv_type == 'steel'    ~ steel_share,
            hts10 %in% deriv_only & deriv_type == 'aluminum' ~ aluminum_share,
            hts10 %in% deriv_only                            ~ metal_share,  # fallback
            TRUE ~ 1.0
          ),
          rate_232 = if_else(
            hts10 %in% deriv_only & .scale_share < 1.0,
            rate_232 * .scale_share,
            rate_232
          )
        ) %>% select(-.scale_share)
    } else {
      # Fallback: aggregate metal_share (backward compat for flat/cbo methods)
      rates <- rates %>%
        mutate(rate_232 = if_else(
          hts10 %in% deriv_only & metal_share < 1.0,
          rate_232 * metal_share,
          rate_232
        ))
    }

    # Reset metal_share to 1.0 for heading products excluded from scaling.
    # Their rate_232 applies to the full product value (heading rate dominates),
    # not the metal portion. Without this, stacking incorrectly computes
    # nonmetal_share > 0 and lets IEEPA fill the "non-metal" portion.
    heading_derivs <- intersect(deriv_matched, heading_products)
    if (length(heading_derivs) > 0) {
      rates <- rates %>%
        mutate(metal_share = if_else(hts10 %in% heading_derivs, 1.0, metal_share))
      if (has_per_type) {
        rates <- rates %>%
          mutate(
            steel_share       = if_else(hts10 %in% heading_derivs, 0, steel_share),
            aluminum_share    = if_else(hts10 %in% heading_derivs, 0, aluminum_share),
            copper_share      = if_else(hts10 %in% heading_derivs, 0, copper_share),
            other_metal_share = if_else(hts10 %in% heading_derivs, 0, other_metal_share)
          )
      }
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
# Grid Densification Helper
# =============================================================================

#' Ensure rates has a row for every (hts10, country) pair
#'
#' Expands `rates` to cover the full HS10 x country universe. Pairs not already
#' present are added with `base_rate` from the parsed products table and zero
#' for every authority column. Pairs that already exist are left unchanged.
#'
#' Used in two contexts:
#'   1. Unconditionally after the blanket-authority passes (232/301/s122/fent/
#'      IEEPA recip) to surface MFN-only product-country pairs that would
#'      otherwise be dropped by the footnote-based `calculate_rates_fast()` path.
#'   2. Inside the IEEPA-invalidation branch, where reciprocal + fentanyl are
#'      zeroed out and the grid expansion those passes normally perform is
#'      skipped — this helper restores the dense grid so matched_imports
#'      doesn't drop discontinuously.
#'
#' @param rates Current rates tibble (must have hts10, country, and the seven
#'   rate_* columns enumerated in REQUIRED_RATE_COLS below)
#' @param products Product data from parse_products()
#' @param countries Vector of Census country codes
#' @param context Short label used in the log message (e.g., 'MFN-only',
#'   'post-IEEPA'). Purely informational.
#' @return Rates tibble with full grid coverage
ensure_dense_grid <- function(rates, products, countries, context = 'MFN-only') {

  # Required input columns — function silently produces garbage if missing.
  REQUIRED_RATE_COLS <- c(
    'hts10', 'country',
    'rate_232', 'rate_301', 'rate_ieepa_recip', 'rate_ieepa_fent',
    'rate_s122', 'rate_section_201', 'rate_other'
  )
  missing_required <- setdiff(REQUIRED_RATE_COLS, names(rates))
  stopifnot(
    'ensure_dense_grid: rates is missing required columns' = length(missing_required) == 0
  )

  # Columns that may be NA on newly-added MFN-only rows. Each entry is here
  # because an explicit downstream check (NA-guard, coalesce, or AND with a
  # FALSE predicate) makes the NA safe. Adding a new column to `rates` upstream
  # of this helper requires either listing it here or extending `new_pairs`
  # below to set a default.
  #   ieepa_type           — Step 6d floor mask ANDs with rate_ieepa_recip > 0,
  #                          which is 0 for MFN-only rows; NA && FALSE -> FALSE.
  #   s232_annex           — Step 6e annex3 mask uses !is.na() guard.
  #   s232_usmca_eligible  — Step 7 USMCA share path uses coalesce(., FALSE).
  #   deriv_type           — NA matches the line-260 initializer ("not a
  #                          derivative"); stacking checks gate on
  #                          !is.na(deriv_type).
  #   metal_share          — apply_stacking_rules() coalesces NA -> 1.0; also
  #                          only read when rate_232 > 0, which is 0 here.
  #   steel_share,
  #   aluminum_share,
  #   copper_share,
  #   other_metal_share    — compute_nonmetal_share() reads these only under
  #                          rate_232 > 0 branches of case_when(); TRUE branch
  #                          returns 0. MFN-only rows have rate_232 = 0.
  #   is_copper_heading    — Same gating: only read under rate_232 > 0 guard
  #                          in compute_nonmetal_share() line 82.
  #   total_additional,
  #   total_rate           — Stale after bind_rows; recomputed for the entire
  #                          frame by apply_stacking_rules() at step 8
  #                          (line ~2102) before the function returns.
  #   statutory_base_rate  — Reassigned to base_rate for every row at step 6c
  #                          (line ~1922), after this helper runs.
  #   usmca_eligible       — Step 7 USMCA processing sets via
  #                          coalesce(usmca_eligible, FALSE) or overwrites to
  #                          FALSE for all rows when USMCA is disabled.
  #   revision,
  #   effective_date       — Step 9a (line ~2107) mutates these for every row
  #                          using the revision_id / effective_date arguments.
  #   valid_from,
  #   valid_until          — Not set in this function; added in
  #                          00_build_timeseries.R:335-336 after a select()
  #                          that drops any prior values.
  # The last nine columns only appear on rates when the calculate_rates_fast()
  # call upstream returns 0 rows and hits the enforce_rate_schema(tibble())
  # initializer at line 618 (small ch99 fixtures in tests); they are absent
  # in normal production pipelines.
  SAFE_NA_COLUMNS <- c('ieepa_type', 's232_annex', 's232_usmca_eligible',
                       'deriv_type',
                       'metal_share', 'steel_share', 'aluminum_share',
                       'copper_share', 'other_metal_share', 'is_copper_heading',
                       'total_additional', 'total_rate',
                       'statutory_base_rate', 'usmca_eligible',
                       'revision', 'effective_date',
                       'valid_from', 'valid_until')

  # Columns `new_pairs` sets explicitly (must match the mutate() below).
  # `statutory_rate_232` is set to 0 here so MFN-only rows carry a valid
  # statutory rate, not NA, into the remaining statutory_rate_* save in 6b2.
  EXPLICIT_SET_COLUMNS <- c(REQUIRED_RATE_COLS, 'base_rate', 'statutory_rate_232')

  set_cols <- c(EXPLICIT_SET_COLUMNS, SAFE_NA_COLUMNS)
  unaccounted <- setdiff(names(rates), set_cols)
  if (length(unaccounted) > 0) {
    stop(
      'ensure_dense_grid: rates has columns not in EXPLICIT_SET_COLUMNS or ',
      'SAFE_NA_COLUMNS — bind_rows would inject NA for new MFN-only pairs ',
      'on these columns: ', paste(unaccounted, collapse = ', '),
      '. Add a default to new_pairs below or list the column in SAFE_NA_COLUMNS ',
      'with a justification comment.'
    )
  }

  existing_pairs <- rates %>% select(hts10, country)

  all_products_base <- products %>%
    select(hts10, base_rate) %>%
    mutate(base_rate = coalesce(base_rate, 0))

  new_pairs <- all_products_base %>%
    expand_grid(country = countries) %>%
    anti_join(existing_pairs, by = c('hts10', 'country')) %>%
    mutate(
      rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0,
      rate_ieepa_fent = 0, rate_s122 = 0,
      rate_section_201 = 0, rate_other = 0,
      statutory_rate_232 = 0
    )

  # At the post-IEEPA call site `rates` does not yet have statutory_rate_232
  # (it's set in step 4c). Drop the column from new_pairs in that case so
  # bind_rows doesn't introduce it prematurely.
  if (!'statutory_rate_232' %in% names(rates)) {
    new_pairs <- new_pairs %>% select(-statutory_rate_232)
  }

  if (nrow(new_pairs) > 0) {
    message('  Grid expansion (', context, '): adding ', nrow(new_pairs),
            ' product-country pairs (base rate only)')
    rates <- bind_rows(rates, new_pairs)
  }

  rates
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
  rates <- calculate_rates_fast(products, ch99_data, countries,
                                stacking_method = stacking_method,
                                iso_to_census = ISO_TO_CENSUS,
                                cty_china = CTY_CHINA)

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

  # Load country-specific EO product exemptions.
  # See docs/country_eo_annex_overshoot.md. Country EOs (Brazil 9903.01.77,
  # India 9903.01.84, etc.) carry their own exempt lists separate from the
  # universal EO 14257 Annex A above. Without this, the country-EO surcharge
  # is wrongly suppressed by Annex A.
  country_eo_exempt_path <- here('resources', 'country_eo_exempt_products.csv')
  country_eo_exempt <- if (file.exists(country_eo_exempt_path)) {
    raw <- read_csv(country_eo_exempt_path, comment = '#',
                    col_types = cols(.default = col_character()))
    rev_date_chr <- as.character(effective_date)
    raw %>%
      mutate(
        effective_date_start = if_else(is.na(effective_date_start) | effective_date_start == '',
                                        '1900-01-01', effective_date_start),
        effective_date_end   = if_else(is.na(effective_date_end)   | effective_date_end == '',
                                        '2099-12-31', effective_date_end)
      ) %>%
      filter(rev_date_chr >= effective_date_start, rev_date_chr <= effective_date_end) %>%
      mutate(hts8_prefix = substr(gsub('\\.', '', hts10), 1, 8)) %>%
      distinct(ch99_code, hts8_prefix)
  } else {
    tibble(ch99_code = character(), hts8_prefix = character())
  }
  if (nrow(country_eo_exempt) > 0) {
    message('  Country-EO exempt products active at ', effective_date, ': ',
            nrow(country_eo_exempt), ' (HS8, ch99) pairs across ',
            n_distinct(country_eo_exempt$ch99_code), ' EOs')
  }

  # Load floor country product exemptions (EU/Japan/Korea/Swiss)
  # Products exempt from the 15% tariff floor — defined by US Note 2
  # subdivisions (v)(xx)-(xxiv) and Note 3. These are distinct from the
  # general IEEPA Annex A exemptions above.
  # Per-revision file takes priority; falls back to static resource.
  floor_exempt_products <- load_revision_floor_exemptions(revision_id)

  # Load product-level USMCA utilization shares from DataWeb SPI data (S/S+).
  # Year configured in policy_params.yaml (usmca_shares.year). Falls back to binary eligibility.
  usmca_product_shares <- load_usmca_product_shares(policy_params = pp, effective_date = effective_date)

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
          phase_type = first(rate_type),
          phase_ch99_code = first(ch99_code),
          .groups = 'drop'
        ) %>%
        # Across phases: keep both the merged total AND the country-EO
        # contribution separately. The latter lets us bypass the universal
        # Annex A check for country-specific surcharges (Brazil 9903.01.77 etc.)
        # while still applying their own per-EO exempt list.
        group_by(census_code) %>%
        summarise(
          ieepa_country_rate = sum(phase_rate),
          country_eo_rate = sum(phase_rate[phase == 'country_eo']),
          country_eo_ch99 = {
            ce <- phase_ch99_code[phase == 'country_eo']
            if (length(ce) > 0) ce[1] else NA_character_
          },
          ieepa_type = first(phase_type),
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
            country_eo_rate = 0,
            country_eo_ch99 = NA_character_,
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
          by = 'country',
          relationship = 'many-to-one'
        )

      # Compute floor exemption flag via vectorized lookup
      if (has_floor_exempts) {
        rates <- rates %>%
          left_join(floor_country_group_map, by = 'country', relationship = 'many-to-one') %>%
          mutate(
            floor_exempt = !is.na(country_group) &
              paste0(substr(hts10, 1, 8), '|', country_group) %in% floor_exempt_keys
          ) %>%
          select(-country_group)
      } else {
        rates <- rates %>% mutate(floor_exempt = FALSE)
      }

      # Build a country-EO exempt key set for fast lookup. Each entry pairs
      # (country EO ch99 code) with (HS8 prefix). A product is exempt from
      # the country EO surcharge when both its 8-digit HS prefix and the
      # active EO ch99 code for that country match an entry.
      country_eo_exempt_keys <- if (nrow(country_eo_exempt) > 0) {
        paste(country_eo_exempt$ch99_code, country_eo_exempt$hts8_prefix, sep = '|')
      } else {
        character(0)
      }

      rates <- rates %>%
        mutate(
          # Universal Annex A applies to phase1 + phase2 only; country_eo bypasses it
          # but is subject to its own per-EO exempt list.
          is_universally_exempt = hts10 %in% ieepa_exempt_products,
          is_country_eo_exempt  = !is.na(country_eo_ch99) &
            paste(country_eo_ch99, substr(hts10, 1, 8), sep = '|') %in% country_eo_exempt_keys,
          rate_ieepa_recip = case_when(
            duty_free_treatment == 'nonzero_base_only' & base_rate < 0.001 ~ 0,
            floor_exempt ~ 0,
            is.na(ieepa_country_rate) ~ 0,
            ieepa_type == 'surcharge' ~
              if_else(is_universally_exempt, 0, ieepa_country_rate - country_eo_rate) +
              if_else(is_country_eo_exempt, 0, country_eo_rate),
            ieepa_type == 'floor' & is_universally_exempt ~ 0,
            ieepa_type == 'floor' ~ pmax(0, ieepa_country_rate - base_rate),
            ieepa_type == 'passthrough' ~ 0,
            TRUE ~ 0
          )
        ) %>%
        select(-ieepa_country_rate, -country_eo_rate, -country_eo_ch99,
               -is_universally_exempt, -is_country_eo_exempt, -floor_exempt)

      # Also add IEEPA rows for products NOT currently in rates
      # (products with no other Ch99 duties but still subject to IEEPA)
      ieepa_country_codes <- country_ieepa$census_code
      ieepa_countries_in_scope <- intersect(ieepa_country_codes, countries)

      existing_pairs <- rates %>%
        filter(country %in% ieepa_countries_in_scope) %>%
        select(hts10, country)

      # Don't pre-filter Annex-A products: those products may still owe a
      # country-EO surcharge that bypasses the universal Annex A. The
      # case_when below applies the right exemption per phase contribution.
      all_products_base <- products %>%
        { if (duty_free_treatment == 'nonzero_base_only') filter(., base_rate > 0.001) else . } %>%
        select(hts10, base_rate) %>%
        mutate(base_rate = coalesce(base_rate, 0))

      new_pairs <- all_products_base %>%
        tidyr::expand_grid(country = ieepa_countries_in_scope) %>%
        anti_join(existing_pairs, by = c('hts10', 'country')) %>%
        left_join(
          country_ieepa %>% rename(country = census_code),
          by = 'country',
          relationship = 'many-to-one'
        )

      # Apply floor exemption flag to new_pairs
      if (has_floor_exempts) {
        new_pairs <- new_pairs %>%
          left_join(floor_country_group_map, by = 'country', relationship = 'many-to-one') %>%
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
          is_universally_exempt = hts10 %in% ieepa_exempt_products,
          is_country_eo_exempt  = !is.na(country_eo_ch99) &
            paste(country_eo_ch99, substr(hts10, 1, 8), sep = '|') %in% country_eo_exempt_keys,
          rate_ieepa_recip = case_when(
            floor_exempt ~ 0,
            ieepa_type == 'surcharge' ~
              if_else(is_universally_exempt, 0, ieepa_country_rate - country_eo_rate) +
              if_else(is_country_eo_exempt, 0, country_eo_rate),
            ieepa_type == 'floor' & is_universally_exempt ~ 0,
            ieepa_type == 'floor' ~ pmax(0, ieepa_country_rate - base_rate),
            TRUE ~ 0
          )
        ) %>%
        filter(rate_ieepa_recip > 0) %>%
        select(-ieepa_country_rate, -country_eo_rate, -country_eo_ch99,
               -is_universally_exempt, -is_country_eo_exempt, -floor_exempt)

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
        left_join(general_fent, by = c('country' = 'census_code'), relationship = 'many-to-one') %>%
        left_join(carveout_lookup,
                  by = c('.hts8' = 'hts8', 'country' = 'census_code'), relationship = 'many-to-one') %>%
        mutate(
          rate_ieepa_fent = coalesce(carveout_rate, fent_rate, 0)
        ) %>%
        select(-fent_rate, -carveout_rate, -.hts8)

      n_carveout <- sum(rates$rate_ieepa_fent > 0 &
                        rates$rate_ieepa_fent < max(general_fent$fent_rate, na.rm = TRUE))
      message('  Fentanyl carve-outs applied: ', n_carveout, ' product-country pairs')
    } else {
      rates <- rates %>%
        left_join(general_fent, by = c('country' = 'census_code'), relationship = 'many-to-one') %>%
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
                  by = c('.hts8' = 'hts8', 'country' = 'census_code'), relationship = 'many-to-one') %>%
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
  if (!is.null(ieepa_invalidation) && as.Date(effective_date) >= ieepa_invalidation) {
    rates <- ensure_dense_grid(rates, products, countries, context = 'post-IEEPA')
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

  # Load heading-level 232 config from policy params. Required — without it the
  # pipeline silently produces output with zero autos/copper/MHD/semi/wood, since
  # the downstream loop iterates names(s232_headings). pp itself is guaranteed
  # non-null by the earlier `pp <- policy_params %||% load_policy_params()`.
  s232_headings <- pp$section_232_headings
  if (is.null(s232_headings)) {
    stop('policy_params$section_232_headings is missing. This block drives all ',
         'non-chapter 232 programs (autos, copper, MHD, wood, semiconductors). ',
         'See config/policy_params.yaml.')
  }

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
    semi_products <- character(0)
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
        buses            = s232_rates$mhd_rate > 0,
        semiconductors   = s232_rates$semi_rate > 0
      )

      # Adding a heading to policy_params.yaml without registering its gate here
      # would silently activate the heading on every revision (gate_val = NULL →
      # old code fell through the `if (!is.null && !gate_val)` guard). Fail
      # closed: refuse to proceed until the gate is wired up.
      unregistered <- setdiff(names(s232_headings), names(heading_gates))
      if (length(unregistered) > 0) {
        stop('Section 232 heading(s) ', paste(unregistered, collapse = ', '),
             ' are in policy_params$section_232_headings but not registered in ',
             'heading_gates (06_calculate_rates.R). Add a gate entry or remove the ',
             'config key. Silently defaulting to always-active would misapply the ',
             'tariff on revisions where its Ch99 entries do not exist.')
      }

      for (tariff_name in names(s232_headings)) {
        # Check if this heading's Ch99 program is active in this revision
        gate_val <- heading_gates[[tariff_name]]
        if (!gate_val) {
          message('  Skipping 232 heading "', tariff_name, '" — Ch99 entries not in this revision')
          next
        }

        cfg <- s232_headings[[tariff_name]]
        matched <- match_232_heading_products(cfg, products, tariff_name, verbose = TRUE)

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
        } else if (grepl('semi', tariff_name, ignore.case = TRUE)) {
          semi_products <- c(semi_products, matched)
        }
      }
    }
    auto_products <- unique(auto_products)
    copper_products <- unique(copper_products)
    wood_products <- unique(wood_products)
    mhd_products <- unique(mhd_products)
    semi_products <- unique(semi_products)

    # Note 39(a)(1)-(9) excludes semi articles from stacking with 232 autos,
    # auto parts, MHD, MHD parts, copper, aluminum, and steel. The auto_parts
    # HTS list (per US Note 33(g)) includes heading 8471 at the 4-digit level,
    # which overlaps with Note 39(b) scope (8471.50, 8471.80, 8473.30). Strip
    # semi products from non-semi heading lists so only the 25% semi rate
    # applies, and so auto_rebate doesn't inappropriately reduce semi rates.
    if (length(semi_products) > 0) {
      auto_products <- setdiff(auto_products, semi_products)
      copper_products <- setdiff(copper_products, semi_products)
      wood_products <- setdiff(wood_products, semi_products)
      mhd_products <- setdiff(mhd_products, semi_products)
      for (nm in setdiff(names(heading_product_lists), 'semiconductors')) {
        heading_product_lists[[nm]]$products <- setdiff(
          heading_product_lists[[nm]]$products,
          semi_products
        )
      }
    }

    # Exclude blanket chapter products from heading lists — a Ch73 steel spring
    # that matches auto_parts prefixes is still a steel product (gets blanket 232
    # rate, not auto rebate/USMCA auto content share).
    blanket_chapters <- c(STEEL_CHAPTERS, ALUM_CHAPTERS)
    n_auto_pre <- length(auto_products)
    auto_products <- auto_products[!substr(auto_products, 1, 2) %in% blanket_chapters]
    if (length(auto_products) < n_auto_pre) {
      message('  Excluded ', n_auto_pre - length(auto_products),
              ' blanket chapter products from auto_products')
    }

    n_steel <- length(steel_products)
    n_alum <- length(aluminum_products)
    n_auto <- length(auto_products)
    n_copper <- length(copper_products)
    n_wood <- length(wood_products)
    n_mhd <- length(mhd_products)
    n_semi <- length(semi_products)
    message('  Section 232 coverage: ', n_steel, ' steel + ', n_alum,
            ' aluminum + ', n_auto, ' auto + ', n_copper, ' copper + ',
            n_wood, ' wood + ', n_mhd, ' MHD + ', n_semi, ' semi products')

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

    # --- Semi per-HTS10 qualifying_share and end-use blending (Note 39(b), (d)) ---
    # Note 39(b) scopes semi articles via three HTS headings plus a per-article
    # TPP/DRAM tech gate; qualifying_share approximates the fraction of each
    # HTS10's imports meeting the gate. Note 39(d) enumerates end-use carve-outs
    # (9903.79.03-.09) that can't be HTS-scoped; end_use_exemption_share
    # approximates the dutied fraction. Both default to uncalibrated upper
    # bounds (qualifying_share = 1.0, end_use_exemption_share = 0).
    if (length(semi_products) > 0 && nrow(heading_product_rate) > 0 &&
        !is.null(s232_headings) && !is.null(s232_headings$semiconductors)) {
      semi_cfg <- s232_headings$semiconductors
      end_use_share <- semi_cfg$end_use_exemption_share %||% 0

      qs_data <- tibble(hts10 = character(), qualifying_share = numeric())
      qs_path <- semi_cfg$qualifying_shares_file %||% ''
      if (nchar(qs_path) > 0) {
        qs_full <- here(qs_path)
        if (file.exists(qs_full)) {
          qs_data <- suppressMessages(
            read_csv(qs_full, col_types = cols(
              hts10 = col_character(),
              qualifying_share = col_double()
            ))
          ) %>% select(hts10, qualifying_share)
        } else {
          warning('semi qualifying_shares_file not found: ', qs_full,
                  ' — defaulting all shares to 1.0 (uncalibrated upper bound)')
        }
      }

      heading_product_rate <- heading_product_rate %>%
        left_join(qs_data, by = 'hts10', relationship = 'many-to-one') %>%
        mutate(
          heading_232_rate = if_else(
            hts10 %in% semi_products,
            heading_232_rate * coalesce(qualifying_share, 1.0) * (1 - end_use_share),
            heading_232_rate
          )
        ) %>%
        select(-qualifying_share)

      message('  Semi scaling: ', nrow(qs_data), ' per-HTS10 shares loaded; ',
              'end_use_exemption_share = ', end_use_share)
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
        left_join(heading_product_rate, by = 'hts10', relationship = 'many-to-one')
    } else {
      rates$heading_232_rate <- 0
      rates$heading_usmca_exempt <- FALSE
    }

    rates <- rates %>%
      left_join(
        country_232 %>% select(country, steel_rate_232 = steel_rate,
                               alum_rate_232 = aluminum_rate),
        by = 'country',
        relationship = 'many-to-one'
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
        # Track which products have USMCA-eligible 232 headings (for step 7).
        # Only when the heading rate is actually used — blanket chapter products
        # (steel/aluminum) get their rate from the blanket, not the heading,
        # so they should NOT inherit the heading's USMCA eligibility.
        s232_usmca_eligible = coalesce(heading_usmca_exempt, FALSE) & heading_rate_adj > 0 &
          !(chapter %in% c(STEEL_CHAPTERS, ALUM_CHAPTERS))
      ) %>%
      select(-steel_rate_232, -alum_rate_232, -chapter, -blanket_232,
             -heading_232_rate, -heading_usmca_exempt, -heading_rate_adj)

    # --- Add rows for 232-covered products NOT yet in rates ---
    # Include countries with any active 232 program (steel/aluminum/auto + heading
    # programs like copper/wood/MHD that don't have per-country exemptions)
    s232_country_codes <- country_232 %>%
      filter(steel_rate > 0 | aluminum_rate > 0 | auto_rate > 0) %>%
      pull(country)
    if (nrow(heading_product_rate) > 0) {
      s232_country_codes <- unique(c(s232_country_codes, countries))
    }

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
        left_join(heading_product_rate, by = 'hts10', relationship = 'many-to-one')
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
        by = 'country',
        relationship = 'many-to-one'
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
        s232_usmca_eligible = coalesce(heading_usmca_exempt, FALSE) & heading_rate_adj > 0 &
          !(chapter %in% c(STEEL_CHAPTERS, ALUM_CHAPTERS)),
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

  # statutory_rate_232 is set after step 4c (deal overrides) — see below.

  # 4b. Apply Section 232 auto rebate
  #     Reduces effective 232 rate on auto/vehicle products by a credit reflecting
  #     US assembly content: effective_rate -= rebate_rate * us_assembly_share.
  #     Applied before metal content scaling (step 5) and before USMCA (step 7).
  #     All three keys are required — fail closed rather than silently default to
  #     values that would quietly over- or under-state auto ETRs (a missing
  #     us_auto_content_share previously defaulted to 1.0, producing a ~4.7pp
  #     over-exemption of CA/MX autos relative to Tariff-ETRs).
  auto_rebate_cfg <- pp$auto_rebate
  if (is.null(auto_rebate_cfg)) {
    stop('policy_params$auto_rebate is missing. Required keys: rebate_rate, ',
         'us_assembly_share, us_auto_content_share. See config/policy_params.yaml. ',
         'To disable the rebate entirely set rebate_rate=0 and us_assembly_share=0; ',
         'to disable the USMCA auto-content scaling set us_auto_content_share=1.')
  }
  required_keys <- c('rebate_rate', 'us_assembly_share', 'us_auto_content_share')
  missing_keys <- setdiff(required_keys, names(auto_rebate_cfg))
  if (length(missing_keys) > 0) {
    stop('policy_params$auto_rebate is missing required keys: ',
         paste(missing_keys, collapse = ', '),
         '. See config/policy_params.yaml.')
  }
  rebate_rate <- auto_rebate_cfg$rebate_rate
  assembly_share <- auto_rebate_cfg$us_assembly_share
  us_auto_content_share <- auto_rebate_cfg$us_auto_content_share
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

      # Determine which products this deal covers (vehicles vs parts).
      # Use heading_product_lists (populated via match_232_heading_products())
      # rather than re-parsing cfg$prefixes. The heading-list path is stable if
      # autos_passenger / autos_light_trucks ever move from inline `prefixes:`
      # to `products_file:` — the old cfg$prefixes path would silently become
      # empty under that migration and the vehicles-branch fallback used to
      # return all auto_products, misapplying a vehicle-only deal to parts.
      vehicle_heading_names <- grep('passenger|light_truck',
                                     names(heading_product_lists),
                                     ignore.case = TRUE, value = TRUE)
      vehicle_products <- unique(unlist(lapply(
        vehicle_heading_names,
        function(nm) heading_product_lists[[nm]]$products
      )))
      deal_products <- if (deal$program == 'auto_parts') {
        # Parts: auto_products not in the vehicle set. Empty vehicle_products
        # (no autos_passenger/light_truck headings active in this revision)
        # collapses to auto_products, which is the correct parts-only scope.
        setdiff(auto_products, vehicle_products)
      } else {
        # Vehicles: exactly the vehicle headings' products. If vehicle_products
        # is empty the deal is a no-op rather than silently applying to all
        # auto_products.
        vehicle_products
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

  # Save post-deal, post-rebate statutory 232 rates for CSV export.
  # After deal overrides (step 4c), rate_232 reflects the effective rate including
  # floor/surcharge adjustments and auto rebate. The generated other_params.yaml
  # sets auto_rebate_rate = 0 so ETRs does not re-apply the rebate.
  # Derivatives (set in step 5) update this column for their products.
  rates <- rates %>%
    mutate(statutory_rate_232 = rate_232)

  # 5. Apply Section 232 derivative tariff + metal content scaling
  #    Aluminum derivatives (9903.85.04/.07/.08) and steel derivatives (9903.81.89-93)
  #    are metal-containing articles outside primary chapters. Tariff applies to
  #    metal content only; per-type scaling uses steel_share or aluminum_share.
  # Build heading product list from prefixes of ACTIVE headings only.
  # Products matching active heading prefixes are non-metal 232 programs
  # and should NOT be metal-scaled even if they also match derivative prefixes.
  # Inactive headings' products should be treated as pure derivatives.
  all_heading_hts10 <- character(0)
  if (!is.null(s232_headings)) {
    for (nm in names(s232_headings)) {
      # Skip inactive headings — their products are pure derivatives.
      # heading_gates is defined inside `if (s232_rates$has_232)` above; when
      # has_232 is FALSE, s232_headings names are still iterated but no gate
      # lookup applies — coerce a missing gate to TRUE (active) so the product
      # list is still populated for heading/derivative-overlap exclusion.
      gate_val <- if (exists('heading_gates', inherits = FALSE)) heading_gates[[nm]] else NULL
      if (!is.null(gate_val) && !gate_val) next
      cfg <- s232_headings[[nm]]
      # verbose = FALSE because step 4 already logged this heading's match count
      matched <- match_232_heading_products(cfg, products, nm, verbose = FALSE)
      all_heading_hts10 <- c(all_heading_hts10, matched)
    }
    all_heading_hts10 <- unique(all_heading_hts10)
  }
  # Load derivative products once — used by apply_232_derivatives (step 5) and
  # again by the annex classification fallback in step 5c. Previously each
  # caller re-read and re-filtered the CSV on its own.
  deriv_products <- load_232_derivative_products(effective_date = effective_date)

  result <- apply_232_derivatives(rates, products, ch99_data, s232_rates, countries,
                                   heading_products = all_heading_hts10,
                                   policy_params = pp,
                                   effective_date = effective_date,
                                   deriv_products = deriv_products)
  rates <- result$rates
  deriv_matched <- result$deriv_matched


  # 5b. Scale copper heading products by copper content share.
  #     The copper proclamation applies the tariff "upon the value of the copper
  #     content," not the full customs value. This parallels ETRs' per-type metal
  #     scaling. After scaling, is_copper_heading flags these products so stacking
  #     rules use copper_share for nonmetal_share.
  if (length(copper_products) > 0 && 'copper_share' %in% names(rates)) {
    rates <- rates %>%
      mutate(
        is_copper_heading = hts10 %in% copper_products,
        rate_232 = if_else(
          is_copper_heading & rate_232 > 0,
          rate_232 * copper_share,
          rate_232
        ),
        statutory_rate_232 = if_else(
          is_copper_heading & statutory_rate_232 > 0,
          statutory_rate_232 * copper_share,
          statutory_rate_232
        )
      )
    n_scaled <- sum(rates$is_copper_heading & rates$rate_232 > 0)
    message('  Copper heading metal scaling: ', n_scaled, ' product-country pairs')
  } else {
    rates$is_copper_heading <- FALSE
  }

  # 5c. Section 232 annex rate override (April 2026 proclamation)
  #     Date-gated: only applies to revisions on/after the annex effective date.
  #     Overrides single-rate 232 with per-annex rates after the old pipeline has
  #     finished assigning rates. Annex classification comes from the static
  #     resource file (resources/s232_annex_products.csv). Annex-era revisions
  #     fail closed if the mapping is missing or empty.
  annex_cfg <- if (!is.null(pp)) pp$S232_ANNEXES else NULL
  if (!is.null(annex_cfg) && as.Date(effective_date) >= annex_cfg$effective_date) {
    annex_resource_file <- annex_cfg$resource_file %||% file.path('resources', 's232_annex_products.csv')
    annex_resource_path <- if (grepl('^([A-Za-z]:|/|\\\\\\\\)', annex_resource_file)) {
      annex_resource_file
    } else {
      here::here(annex_resource_file)
    }
    annex_map <- load_annex_products(effective_date, annex_resource_path)

    if (nrow(annex_map) == 0) {
      stop(
        'Section 232 annex mapping is empty for annex-era revision ', revision_id,
        ' (effective ', effective_date, '). Expected non-empty mapping at ',
        annex_resource_path
      )
    }

    message('  Annex products loaded: ', nrow(annex_map), ' from ', annex_resource_path)

    if (nrow(annex_map) > 0) {
      # Prefix-match annex classification to HTS10 codes.
      # Sort longest-first so specific prefixes (e.g., 85030045 → annex_2)
      # take priority over shorter catchalls (e.g., 850300 → annex_1b).
      annex_pattern_map <- annex_map %>%
        mutate(pattern = paste0('^', hts_prefix)) %>%
        arrange(desc(nchar(hts_prefix)))
      rates$s232_annex <- NA_character_
      for (i in seq_len(nrow(annex_pattern_map))) {
        mask <- grepl(annex_pattern_map$pattern[i], rates$hts10)
        rates$s232_annex[mask & is.na(rates$s232_annex)] <- annex_pattern_map$s232_annex[i]
      }

      # Infer annex for products not matched by the prefix CSV.
      # Primary chapters (72/73/76/74) → annex_1a unconditionally: the proclamation
      # covers all base metal products regardless of whether old Ch99 entries still
      # assign rate_232 (many were removed in the annex HTS revision).
      # Unmatched derivatives → annex_1b: if a product is in s232_derivative_products
      # but not in the annex CSV prefix list, it belongs in the downstream tier.
      annex_1a_chapters <- annex_cfg$annexes$annex_1a$chapters %||% c('72', '73', '76', '74')
      # Reuse deriv_products loaded in step 5. tryCatch preserved in case the
      # earlier load returned NULL (resource file missing) — treat as empty.
      deriv_prefixes <- tryCatch(
        if (!is.null(deriv_products)) deriv_products$hts_prefix else character(0),
        error = function(e) character(0)
      )
      deriv_pattern <- if (length(deriv_prefixes) > 0) {
        paste0('^(', paste(deriv_prefixes, collapse = '|'), ')')
      } else NULL

      rates <- rates %>%
        mutate(s232_annex = case_when(
          !is.na(s232_annex) ~ s232_annex,
          substr(hts10, 1, 2) %in% annex_1a_chapters ~ 'annex_1a',
          !is.null(deriv_pattern) & grepl(deriv_pattern, hts10) ~ 'annex_1b',
          TRUE ~ s232_annex
        ))

      # Override rate_232 by annex
      rates <- rates %>%
        mutate(rate_232 = case_when(
          s232_annex == 'annex_2' ~ 0,
          s232_annex == 'annex_1a' ~ annex_cfg$annexes$annex_1a$rate,
          s232_annex == 'annex_1b' ~ annex_cfg$annexes$annex_1b$rate,
          s232_annex == 'annex_3' ~ pmax(0, annex_cfg$annexes$annex_3$floor_rate - base_rate),
          TRUE ~ rate_232
        ))

      # UK annex-aware deal (replaces old flat 25% override for post-annex revisions)
      uk_code <- get_country_constants()$CTY_UK %||% '4120'
      uk_1a_chapters <- annex_cfg$annexes$annex_1a$uk_applies_to %||% c('steel', 'aluminum')
      uk_steel_alum <- c('72', '73', '76')  # UK deal for steel/aluminum, not copper
      rates <- rates %>%
        mutate(rate_232 = case_when(
          country == uk_code & s232_annex == 'annex_1a' &
            substr(hts10, 1, 2) %in% uk_steel_alum ~ annex_cfg$annexes$annex_1a$uk_rate,
          country == uk_code & s232_annex == 'annex_1b' &
            substr(hts10, 1, 2) %in% uk_steel_alum ~ annex_cfg$annexes$annex_1b$uk_rate,
          TRUE ~ rate_232
        ))

      # Annex III sunset: after sunset_date, products move to I-B rate
      sunset <- annex_cfg$annexes$annex_3$sunset_date
      if (!is.null(sunset) && as.Date(effective_date) > as.Date(sunset)) {
        rates <- rates %>%
          mutate(
            rate_232 = if_else(s232_annex == 'annex_3',
                                annex_cfg$annexes$annex_1b$rate, rate_232),
            s232_annex = if_else(s232_annex == 'annex_3', 'annex_1b', s232_annex)
          )
        message('  Annex III sunset: reclassified to I-B')
      }

      # Update statutory_rate_232 to reflect annex overrides
      rates <- rates %>%
        mutate(statutory_rate_232 = if_else(!is.na(s232_annex), rate_232, statutory_rate_232))

      n_by_annex <- rates %>% filter(!is.na(s232_annex), rate_232 > 0) %>% count(s232_annex)
      if (nrow(n_by_annex) > 0) {
        message('  Annex rate override: ',
                paste(n_by_annex$s232_annex, n_by_annex$n, sep = '=', collapse = ', '))
      }
    } else {
      rates$s232_annex <- NA_character_
    }
  } else {
    rates$s232_annex <- NA_character_
  }

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
          left_join(s301_lookup, by = 'hts8', relationship = 'many-to-one') %>%
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
            left_join(s301_lookup, by = 'hts8', relationship = 'many-to-one') %>%
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

  # 6b1. Apply Section 201 (Trade Act §201 safeguard) tariffs.
  #      Currently models Solar 201 (Proc 9693 + Proc 10454, 9903.45.21–.25)
  #      on CSPV cells/modules. The 201 rate stacks on top of MFN, separate
  #      from 232/301/IEEPA. Canada is exempt under USMCA. Per-product
  #      coverage is in resources/s201_solar_products.csv.
  s201_results <- extract_section_201_rates(ch99_data, policy_params = pp)
  if (s201_results$has_s201) {
    s201_path <- here('resources', 's201_solar_products.csv')
    if (!file.exists(s201_path)) {
      message('  WARNING: s201_solar_products.csv not found — Section 201 rate not applied')
    } else {
      s201_products <- read_csv(s201_path,
                                 col_types = cols(hts10 = col_character()))
      solar_rate <- s201_results$solar_rate
      s201_country_codes <- setdiff(countries, pp$country_codes$CTY_CANADA)

      # Set rate_section_201 for existing rows
      rates <- rates %>%
        mutate(
          rate_section_201 = if_else(
            hts10 %in% s201_products$hts10 & country %in% s201_country_codes,
            solar_rate, rate_section_201
          )
        )

      # Add 201-only rows for products not yet in rates
      s201_country_rates <- tibble(
        country = s201_country_codes,
        blanket_rate = solar_rate
      )
      rates <- add_blanket_pairs(rates, products, s201_products$hts10, s201_country_rates,
                                  'rate_section_201', 'Section 201 (solar)')

      n_with_s201 <- sum(rates$rate_section_201 > 0)
      message('  Section 201 (solar): ', round(solar_rate * 100, 1), '% on ',
              n_with_s201, ' product-country pairs (',
              nrow(s201_products), ' HTS10 covered, Canada exempt)')
    }
  }

  # 6b2. Dense grid expansion.
  #      All blanket-authority passes (232/301/s122/fent/IEEPA recip) are complete.
  #      Any product-country pair that still isn't in `rates` has no applicable
  #      footnote or blanket authority — it's MFN-only. Surface those pairs so
  #      they receive FTA/GSP adjustment (6c), USMCA treatment (7), and enter
  #      downstream aggregations with their base_rate instead of being silently
  #      dropped. Placed before the statutory_rate_* save so new pairs pick up
  #      statutory_rate_* = 0 naturally from the zero authority columns.
  rates <- ensure_dense_grid(rates, products, countries, context = 'MFN-only')

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
        by = c('hs2', 'country' = 'cty_code'),
        relationship = 'many-to-one'
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

    # 6e. Recompute Annex III floor against post-MFN base_rate (same logic as 6d).
    if (!is.null(annex_cfg) && as.Date(effective_date) >= annex_cfg$effective_date &&
        's232_annex' %in% names(rates)) {
      annex3_mask <- !is.na(rates$s232_annex) & rates$s232_annex == 'annex_3' &
                     rates$base_rate < rates$statutory_base_rate
      if (any(annex3_mask)) {
        floor_val <- annex_cfg$annexes$annex_3$floor_rate
        rates$rate_232[annex3_mask] <- pmax(0, floor_val - rates$base_rate[annex3_mask])
        rates$statutory_rate_232[annex3_mask] <- rates$rate_232[annex3_mask]
        message('  Annex III floor recomputation: updated ', sum(annex3_mask),
                ' pairs (against post-MFN base_rate)')
      }
    }

    # Drop transient ieepa_type column — not part of production output
    rates$ieepa_type <- NULL
  }

  # 7. Apply USMCA exemptions
  # TPC methodology: rate * (1 - usmca_share) for each CA/MX product.
  # If DataWeb SPI shares available (from download_usmca_dataweb.R), apply to ALL
  # CA/MX products — the share naturally handles eligibility (products that never
  # enter under USMCA have share ≈ 0, fully-claiming products have share ≈ 1).
  # Also applies to 232 auto/MHD products flagged s232_usmca_eligible (T1 fix).
  # Falls back to binary eligibility (S/S+ → zero rate) if shares not available.
  #
  # Scenario override: USMCA_SHARES$mode == 'none' means "0% utilization — no
  # importer claims USMCA on any product-country pair". Skip the block entirely
  # so CA/MX rates are left at their pre-USMCA values (neither the share path
  # nor the binary S/S+ fallback fires). The data_loader for mode='none' returns
  # an empty tibble; the short-circuit here is what actually implements the
  # scenario semantics.
  usmca_mode <- pp$USMCA_SHARES$mode %||% 'h2_average'
  if (identical(usmca_mode, 'none')) {
    # Skip rate application, but still populate usmca_eligible from the HTS
    # "special" field so the diagnostic flag retains its meaning in the
    # snapshot (product has S/S+ in HTS, independent of scenario utilization).
    # This matches the semantics of the prior sentinel-row approach on the
    # previously-built usmca_none snapshots.
    message('  USMCA: mode=none, skipping rate exemptions (usmca_eligible retained from HTS)')
    if (!is.null(usmca) && nrow(usmca) > 0) {
      rates <- rates %>%
        left_join(
          usmca %>% select(hts10, usmca_eligible),
          by = 'hts10',
          relationship = 'many-to-one'
        ) %>%
        mutate(usmca_eligible = coalesce(usmca_eligible, FALSE))
    } else {
      rates <- rates %>% mutate(usmca_eligible = FALSE)
    }
  } else if (!is.null(usmca) && nrow(usmca) > 0) {
    rates <- rates %>%
      left_join(
        usmca %>% select(hts10, usmca_eligible),
        by = 'hts10',
        relationship = 'many-to-one'
      ) %>%
      mutate(usmca_eligible = coalesce(usmca_eligible, FALSE))

    if (!is.null(usmca_product_shares) && nrow(usmca_product_shares) > 0) {
      # Census SPI shares: apply to all CA/MX products
      rates <- rates %>%
        left_join(
          usmca_product_shares,
          by = c('hts10', 'country' = 'cty_code'),
          relationship = 'many-to-one'
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

  # Note 39(a)(7)-(9): semi articles are not subject to 232 aluminum/steel
  # derivative duties, and the April 2026 annex restructuring doesn't re-scope
  # them. Several upstream steps (apply_232_derivatives, annex overrides,
  # USMCA auto-content, etc.) can mutate rate_232 for semi HTS10s. Restore the
  # semi heading rate as the final step before stacking so the 25% is what
  # actually carries into the ETR.
  if (exists('semi_products') && length(semi_products) > 0 &&
      exists('heading_product_rate') && nrow(heading_product_rate) > 0) {
    semi_override <- heading_product_rate %>%
      filter(hts10 %in% semi_products) %>%
      select(hts10, .semi_heading_rate = heading_232_rate)
    if (nrow(semi_override) > 0) {
      rates <- rates %>%
        left_join(semi_override, by = 'hts10', relationship = 'many-to-one') %>%
        mutate(
          rate_232 = if_else(!is.na(.semi_heading_rate), .semi_heading_rate, rate_232),
          deriv_type = if_else(!is.na(.semi_heading_rate), NA_character_, deriv_type),
          statutory_rate_232 = if_else(!is.na(.semi_heading_rate), .semi_heading_rate,
                                       statutory_rate_232)
        ) %>%
        select(-.semi_heading_rate)
      message('  Semi: restored heading rate on ', nrow(semi_override), ' HTS10s')
    }
  }

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

  # Load policy params for standalone mode
  pp <- load_policy_params()
  cc <- get_country_constants(pp)

  # Calculate rates (use fast method)
  rates <- calculate_rates_fast(products, ch99_data, countries,
                                iso_to_census = cc$ISO_TO_CENSUS,
                                cty_china = cc$CTY_CHINA)

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
