# =============================================================================
# Stacking Rules — mutual-exclusion tariff stacking and authority decomposition
# =============================================================================
# Split from helpers.R. Sourced by helpers.R for backward compatibility.
# Direct consumers can source this file alone.

library(tidyverse)

# Stacking Rules
# =============================================================================

#' Apply tariff stacking rules (vectorized)
#'
#' Implements mutual-exclusion stacking (aligned with Tariff-ETRs):
#'
#'   China (232 > 0):  232 + recip*nonmetal + fentanyl + 301 + s122 + other
#'   China (no 232):   reciprocal + fentanyl + 301 + s122 + other
#'   Others (232 > 0): 232 + recip*nonmetal + fentanyl + s122 + other
#'   Others (no 232):  reciprocal + fentanyl + s122 + other
#'
#' Key rules:
#'   - 232 and IEEPA reciprocal are mutually exclusive (232 takes precedence)
#'   - Pre-annex: for derivative 232 products (metal_share < 1.0), IEEPA reciprocal
#'     applies to the non-metal portion of customs value
#'   - Post-annex (>= 2026-04-06): proclamation applies 232 to full customs value;
#'     nonmetal_share is forced to 0 for all annex-classified products (s232_annex != NA),
#'     so IEEPA/S122/fentanyl contribute zero on post-annex 232 products.
#'   - Fentanyl stacks on 232 for all countries (separate IEEPA authority)
#'   - Section 301 only applies to China
#'   - Section 122 is scaled by nonmetal_share on 232 products (same treatment as
#'     IEEPA reciprocal). Pre-annex: for pure-metal products (metal_share = 1.0),
#'     nonmetal_share = 0; for derivatives, s122 applies to non-metal portion.
#'     Post-annex: nonmetal_share = 0 for all annex-classified 232 products.
#'     For non-232 products, s122 stacks at full value.
#'
#' @param df Data frame with rate_232, rate_301, rate_ieepa_recip,
#'   rate_ieepa_fent, rate_s122, rate_other, metal_share, country columns
#' @param cty_china Census code for China (default: '5700')
#' @param stacking_method 'mutual_exclusion' (default, 232/IEEPA mutual exclusion)
#'   or 'tpc_additive' (all authorities stack additively, matching TPC methodology)
#' @return df with total_additional and total_rate recomputed
has_informative_per_type_shares <- function(df) {
  required <- c('steel_share', 'aluminum_share', 'copper_share')
  if (!all(required %in% names(df))) {
    return(FALSE)
  }

  any(
    coalesce(df$steel_share, 0) > 0 |
      coalesce(df$aluminum_share, 0) > 0 |
      coalesce(df$copper_share, 0) > 0
  )
}


#' Compute nonmetal_share column for mutual-exclusion stacking
#'
#' Shared by apply_stacking_rules() and compute_net_authority_contributions().
#' Adds a `nonmetal_share` column: for 232 products, the fraction of customs
#' value NOT covered by the active 232 metal program. IEEPA/S122/fentanyl
#' apply to this fraction. For non-232 products, nonmetal_share = 0.
#'
#' Uses per-metal-type shares (BEA) when available; falls back to aggregate
#' metal_share (flat/CBO). Post-annex products get nonmetal_share = 0.
#'
#' @param df Data frame with rate_232, metal_share, and optionally
#'   steel_share, aluminum_share, copper_share, is_copper_heading,
#'   deriv_type, s232_annex columns
#' @return df with nonmetal_share column added
compute_nonmetal_share <- function(df) {
  has_per_type <- has_informative_per_type_shares(df)

  if (has_per_type) {
    has_copper_flag <- 'is_copper_heading' %in% names(df)
    has_deriv_type <- 'deriv_type' %in% names(df)
    df <- df %>%
      mutate(
        .ch2 = substr(hts10, 1, 2),
        .active_type_share = case_when(
          rate_232 > 0 & .ch2 %in% c('72', '73')              ~ steel_share,
          rate_232 > 0 & .ch2 == '76'                          ~ aluminum_share,
          rate_232 > 0 & has_copper_flag & is_copper_heading   ~ copper_share,
          rate_232 > 0 & has_deriv_type & deriv_type == 'steel'    ~ steel_share,
          rate_232 > 0 & has_deriv_type & deriv_type == 'aluminum' ~ aluminum_share,
          rate_232 > 0 & metal_share < 1.0                     ~ aluminum_share,  # fallback
          TRUE ~ 0
        ),
        nonmetal_share = if_else(rate_232 > 0 & .active_type_share > 0,
                                  1 - .active_type_share, 0)
      ) %>%
      select(-.ch2, -.active_type_share)
  } else {
    # Fallback: aggregate metal_share (backward compat for flat/cbo methods)
    df <- df %>%
      mutate(nonmetal_share = if_else(rate_232 > 0 & metal_share < 1.0, 1 - metal_share, 0))
  }

  # Post-annex override: the April 2026 proclamation applies Section 232 to the
  # full customs value, eliminating metal-content-based mutual exclusion. Products
  # with an annex classification (s232_annex != NA) get nonmetal_share = 0 so that
  # IEEPA/S122/fentanyl do not leak through on a phantom non-metal fraction.
  # Annex II products (rate_232 = 0, removed from scope) are excluded by the
  # rate_232 > 0 guard — they receive full IEEPA/S122 as non-232 products.
  if ('s232_annex' %in% names(df)) {
    df <- df %>%
      mutate(nonmetal_share = if_else(
        !is.na(s232_annex) & rate_232 > 0, 0, nonmetal_share
      ))
  }

  return(df)
}


apply_stacking_rules <- function(df, cty_china = '5700', stacking_method = 'mutual_exclusion') {
  # Ensure optional columns exist and have no NAs
  if (!'rate_s122' %in% names(df)) {
    df$rate_s122 <- 0
  } else {
    df$rate_s122[is.na(df$rate_s122)] <- 0
  }
  if (!'rate_section_201' %in% names(df)) {
    df$rate_section_201 <- 0
  } else {
    df$rate_section_201[is.na(df$rate_section_201)] <- 0
  }
  if (!'metal_share' %in% names(df)) {
    df$metal_share <- 1.0
  } else {
    df$metal_share[is.na(df$metal_share)] <- 1.0
  }

  # TPC additive: all authorities stack with no mutual exclusion.
  # TPC confirmed (March 2026) they mostly agree with mutual exclusion between
  # 232 and IEEPA, with exceptions for copper (232 + CA/MX fentanyl) and
  # derivatives (IEEPA on non-metal portion). This mode is retained for
  # sensitivity analysis, not as a TPC-matching switch.
  if (stacking_method == 'tpc_additive') {
    return(
      df %>%
        mutate(
          total_additional = rate_232 + rate_ieepa_recip + rate_ieepa_fent +
            rate_301 + rate_s122 + rate_section_201 + rate_other,
          total_rate = base_rate + total_additional
        )
    )
  }

  df <- compute_nonmetal_share(df)

  df <- df %>%
    mutate(
      total_additional = case_when(
        # China with 232: 232 + recip*nonmetal + fentanyl + 301 + s122*nonmetal + s201 + other
        country == cty_china & rate_232 > 0 ~
          rate_232 + rate_ieepa_recip * nonmetal_share + rate_ieepa_fent + rate_301 +
          rate_s122 * nonmetal_share + rate_section_201 + rate_other,

        # China without 232: reciprocal + fentanyl + 301 + s122 + s201 + other
        country == cty_china ~
          rate_ieepa_recip + rate_ieepa_fent + rate_301 + rate_s122 + rate_section_201 + rate_other,

        # Others with 232: 232 + recip*nonmetal + fent*nonmetal + s122*nonmetal + s201 + other
        # Fentanyl follows the same content-based split as reciprocal: 232 covers
        # the metal/copper content, fentanyl applies to the non-metal portion only.
        # For heading products (auto_parts, copper, autos), nonmetal_share ≈ 0.
        rate_232 > 0 ~
          rate_232 + rate_ieepa_recip * nonmetal_share + rate_ieepa_fent * nonmetal_share +
          rate_s122 * nonmetal_share + rate_section_201 + rate_other,

        # Others without 232: reciprocal + fentanyl + s122 + s201 + other
        TRUE ~ rate_ieepa_recip + rate_ieepa_fent + rate_s122 + rate_section_201 + rate_other
      ),
      total_rate = base_rate + total_additional
    ) %>%
    select(-nonmetal_share)
}


# =============================================================================
# Net Authority Decomposition (used by 08_weighted_etr, 09_daily_series)
# =============================================================================

#' Compute net authority contributions from snapshot rate columns
#'
#' Derives per-authority net contributions from the timeseries rate columns
#' using mutual-exclusion stacking rules. Net contributions sum to total_additional.
#'
#' @param df Data frame with rate_232, rate_301, rate_ieepa_recip,
#'   rate_ieepa_fent, rate_s122, rate_section_201, rate_other, metal_share, country columns
#' @param cty_china Census code for China (default: '5700')
#' @param stacking_method 'mutual_exclusion' (default) or 'tpc_additive'
#' @return df with net_232, net_ieepa, net_fentanyl, net_301, net_s122,
#'   net_section_201, net_other added
compute_net_authority_contributions <- function(df, cty_china = '5700',
                                                stacking_method = 'mutual_exclusion') {
  # Ensure optional columns exist (backwards compat with old snapshots)
  if (!'rate_s122' %in% names(df)) df$rate_s122 <- 0
  if (!'rate_section_201' %in% names(df)) df$rate_section_201 <- 0
  if (!'rate_other' %in% names(df)) df$rate_other <- 0
  if (!'metal_share' %in% names(df)) df$metal_share <- 1.0

  # TPC additive: all authorities contribute their full rate (no mutual exclusion)
  if (stacking_method == 'tpc_additive') {
    return(
      df %>%
        mutate(
          net_232 = rate_232,
          net_ieepa = rate_ieepa_recip,
          net_fentanyl = rate_ieepa_fent,
          net_301 = rate_301,
          net_s122 = rate_s122,
          net_section_201 = rate_section_201,
          net_other = rate_other
        )
    )
  }

  df <- compute_nonmetal_share(df)

  df %>%
    mutate(
      net_232 = if_else(rate_232 > 0, rate_232, 0),
      net_ieepa = if_else(rate_232 > 0, rate_ieepa_recip * nonmetal_share, rate_ieepa_recip),
      net_fentanyl = case_when(
        country == cty_china ~ rate_ieepa_fent,
        rate_232 > 0 ~ rate_ieepa_fent * nonmetal_share,
        TRUE ~ rate_ieepa_fent
      ),
      net_301 = if_else(country == cty_china, rate_301, 0),
      net_s122 = if_else(rate_232 > 0, rate_s122 * nonmetal_share, rate_s122),
      net_section_201 = rate_section_201,
      net_other = rate_other
    ) %>%
    select(-nonmetal_share)
}

