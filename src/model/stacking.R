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
#'   China (232 > 0):  232 + recip*nonmetal + fentanyl + 301 + s122*nonmetal + other
#'   China (no 232):   reciprocal + fentanyl + 301 + s122 + other
#'   Others (232 > 0): 232 + (recip + fentanyl + s122)*nonmetal + other
#'   Others (no 232):  reciprocal + fentanyl + s122 + other
#'
#' Key rules:
#'   - 232 and IEEPA reciprocal are mutually exclusive (232 takes precedence)
#'   - Pre-annex: for derivative 232 products (metal_share < 1.0), IEEPA reciprocal
#'     applies to the non-metal portion of customs value
#'   - Post-annex (>= 2026-04-06): proclamation applies 232 to full customs value;
#'     nonmetal_share is forced to 0 for all annex-classified products (s232_annex != NA),
#'     so content-split IEEPA reciprocal/S122/fentanyl do not leak through on
#'     post-annex 232 products.
#'   - Fentanyl on 232 products: for China, passes through at full rate. For
#'     CA/MX, fentanyl is scaled by nonmetal_share, matching Tariff-ETRs.
#'   - Section 301 only applies to China
#'   - Section 122 is scaled by nonmetal_share on 232 products for ALL countries.
#'     Pre-annex: for pure-metal products (metal_share = 1.0), nonmetal_share = 0;
#'     for derivatives, s122 applies to non-metal portion. Post-annex: nonmetal_share
#'     = 0 for all annex-classified 232 products. For non-232 products, s122 stacks
#'     at full value.
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
#' value NOT covered by the active 232 metal program. Content-split authorities
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
          rate_232 > 0 & has_deriv_type & deriv_type == 'steel'    & steel_share    > 0 ~ steel_share,
          rate_232 > 0 & has_deriv_type & deriv_type == 'aluminum' & aluminum_share > 0 ~ aluminum_share,
          # Tagged derivative with an uninformative (0/NA) type share: use the
          # aggregate share, mirroring the rate-scaling fallback in
          # apply_232_derivatives() (BEA-unmatched lines carry flat metal_share
          # with zero-filled type shares).
          rate_232 > 0 & has_deriv_type & !is.na(deriv_type)   ~ metal_share,
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
  # content-split authorities do not leak through on a phantom non-metal fraction.
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


# =============================================================================
# Stacking taxonomy as DATA (Phase 3a) — replaces the hand-written country/232
# case_when with a per-authority policy the engine reads.
# =============================================================================
#
# Each additional-tariff authority (one wide `rate_*` column) maps to:
#   net   — its net_* decomposition column.
#   class — 'primary'       : the 232 metal layer. Contributes its full rate and,
#                             via nonmetal_share, defines the fraction the
#                             content-split authorities apply to.
#           'content_split' : applies only to the non-metal fraction when a 232
#                             metal rate is present (IEEPA reciprocal, S122, and
#                             fentanyl for CA/MX, and scenario content-split
#                             authorities); full rate when no 232.
#           'additive'      : stacks at full rate regardless (301, 201, other,
#                             and fentanyl for China).
#   additive_countries — per-country overrides flipping a content_split authority
#           to additive. Used for the China fentanyl pass-through and retained
#           for scenarios that need country-specific re-scoping.
#
# Authority ORDER is load-bearing: it reproduces the historical case_when term
# order (301 fourth). 301 is zero off-China and IEEE 0-additions don't change
# association, so this single order reproduces every historical branch bit-for-bit.
default_stacking_policy <- function(cty_china = '5700') {
  list(
    rate_232         = list(net = 'net_232',         class = 'primary'),
    rate_ieepa_recip = list(net = 'net_ieepa',       class = 'content_split'),
    rate_ieepa_fent  = list(net = 'net_fentanyl',    class = 'content_split',
                            additive_countries = cty_china),
    rate_301         = list(net = 'net_301',         class = 'additive'),
    # Section 301, content-split flavor: yields to a 232 like the reciprocal/122
    # (scaled by nonmetal_share when rate_232 > 0), vs the legacy additive rate_301.
    # All-zero in baseline until codes are classified into it (A2), so adding it
    # here contributes 0 to total_additional regardless of position (FP-safe).
    rate_301_cs      = list(net = 'net_301_cs',      class = 'content_split'),
    # Section 301 forced-labor (scenario authority): content_split like the
    # reciprocal/122 (displaced by 232, USMCA-eligible). All-zero / absent in
    # baseline, so it contributes 0 here regardless of position (0 + x == x is
    # bit-exact for doubles) — FP-safe, like rate_301_cs above.
    rate_s301fl      = list(net = 'net_s301fl',      class = 'content_split'),
    # Section 301 Brazil (scenario authority): content_split like the FL §301
    # (displaced by 232). All-zero / absent in baseline, so it contributes 0 here
    # regardless of position (0 + x == x is bit-exact for doubles) — FP-safe.
    rate_s301br      = list(net = 'net_s301br',      class = 'content_split'),
    rate_s122        = list(net = 'net_s122',        class = 'content_split'),
    rate_section_201 = list(net = 'net_section_201', class = 'additive'),
    rate_other       = list(net = 'net_other',       class = 'additive')
  )
}


#' Build the stacking policy FROM the AuthoritySpec set (Plank 5b).
#'
#' This is the spec-driven twin of default_stacking_policy(): it reproduces that
#' policy BYTE-FOR-BYTE at baseline, but reads each authority's stacking `class`
#' and per-country `exceptions` FROM THE SPEC instead of hardcoding them. That makes
#' stacking.class/exceptions load-bearing — a scenario that mutates them (set_stacking)
#' now flows into compute_stacking_contributions().
#'
#' Design = skeleton-override (NOT pure-from-spec). The load-bearing ORDER, the
#' rate_col<->net_* mapping, and the spec-less rate_301_cs entry are calculator
#' INFRASTRUCTURE the spec does not carry, so a fixed skeleton supplies them; only
#' `class` + `additive_countries` are read from the spec. Notes:
#'   - The spec's finer taxonomy collapses to the engine's: primary_metal / primary_full
#'     -> 'primary' (the engine treats every non-content_split class as full-rate, so
#'     the collapse is a no-op numerically; we emit the literal 'primary' so the policy
#'     OBJECT stays identical to default_stacking_policy()).
#'   - `exceptions` is a named list census_code -> label; additive_countries = the codes
#'     flagged 'additive'. Emitted only when non-empty, so the list SHAPE matches
#'     default.
#'   - rate_301_cs has NO spec authority (policy/resolved-only, all-zero in baseline) ->
#'     skeleton-injected with the fixed default class.
#'   - mfn IS a spec authority but has NO rate_col (base layer) -> excluded by the skeleton.
#' Invariant (pinned in tests/test_policy_from_specs.R):
#'   identical(stacking_policy_from_specs(baseline_specs, cty), default_stacking_policy(cty)).
stacking_policy_from_specs <- function(specs, cty_china = '5700') {
  # (rate_col, net_*, spec authority, fixed-default class, fixed-default additive_countries)
  # in the load-bearing order of default_stacking_policy(). auth = NA marks a spec-less
  # column; dflt_add carries default_stacking_policy()'s built-in additive_countries.
  skel <- list(
    list(col = 'rate_232',         net = 'net_232',         auth = 'section_232',      dflt = 'primary',       dflt_add = character(0)),
    list(col = 'rate_ieepa_recip', net = 'net_ieepa',       auth = 'ieepa_reciprocal', dflt = 'content_split', dflt_add = character(0)),
    list(col = 'rate_ieepa_fent',  net = 'net_fentanyl',    auth = 'ieepa_fentanyl',   dflt = 'content_split', dflt_add = cty_china),
    list(col = 'rate_301',         net = 'net_301',         auth = 'section_301',      dflt = 'additive',      dflt_add = character(0)),
    list(col = 'rate_301_cs',      net = 'net_301_cs',      auth = NA_character_,      dflt = 'content_split', dflt_add = character(0)),
    list(col = 'rate_s301fl',      net = 'net_s301fl',      auth = 'section_301_forced_labor', dflt = 'content_split', dflt_add = character(0)),
    list(col = 'rate_s301br',      net = 'net_s301br',      auth = 'section_301_brazil', dflt = 'content_split', dflt_add = character(0)),
    list(col = 'rate_s122',        net = 'net_s122',        auth = 'section_122',      dflt = 'content_split', dflt_add = character(0)),
    list(col = 'rate_section_201', net = 'net_section_201', auth = 'section_201',      dflt = 'additive',      dflt_add = character(0)),
    list(col = 'rate_other',       net = 'net_other',       auth = 'other',            dflt = 'additive',      dflt_add = character(0))
  )

  map_class <- function(sc) {
    if (length(sc) != 1 || is.na(sc)) return(NA_character_)
    if (sc %in% c('primary_metal', 'primary_full', 'primary')) return('primary')
    sc  # 'content_split' / 'additive' pass through unchanged
  }

  policy <- list()
  for (e in skel) {
    spec <- if (is.na(e$auth)) NULL else specs[[e$auth]]
    if (is.null(spec)) {
      # spec-less column (rate_301_cs) or an absent authority -> the fixed default
      cls      <- e$dflt
      add_ctry <- e$dflt_add
    } else {
      cls <- map_class(spec$stacking$class %||% NA_character_)
      if (is.na(cls)) cls <- e$dflt
      exc <- spec$stacking$exceptions
      add_ctry <- if (length(exc)) {
        as.character(names(exc)[vapply(exc, function(v) identical(as.character(v), 'additive'),
                                       logical(1))])
      } else character(0)
    }
    entry <- list(net = e$net, class = cls)
    if (length(add_ctry)) entry$additive_countries <- add_ctry
    policy[[e$col]] <- entry
  }
  policy
}


#' Compute per-authority net contributions on a wide rate panel from a stacking
#' policy. Adds one `.contrib_<net>` column per authority. Assumes nonmetal_share
#' is already present (call compute_nonmetal_share() first) and that `country` and
#' `rate_232` exist. Shared by apply_stacking_rules() (sums them into
#' total_additional) and compute_net_authority_contributions() (keeps them as net_*).
compute_stacking_contributions <- function(df, policy) {
  for (col in names(policy)) {
    p <- policy[[col]]
    if (!col %in% names(df)) df[[col]] <- 0
    contrib <- paste0('.contrib_', p$net)
    if (identical(p$class, 'content_split')) {
      add_ctry <- p$additive_countries %||% character(0)
      split_active <- df$rate_232 > 0 & !(df$country %in% add_ctry)
      df[[contrib]] <- df[[col]] * if_else(split_active, df$nonmetal_share, 1)
    } else {
      # primary + additive contribute their full rate
      df[[contrib]] <- df[[col]]
    }
  }
  df
}


apply_stacking_rules <- function(df, cty_china = '5700', stacking_method = 'mutual_exclusion',
                                 stacking_policy = NULL) {
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
  # 232 and IEEPA. Retained for sensitivity analysis, not as a TPC match. Note
  # that in the default 'mutual_exclusion' branch below, the content-based split
  # applies uniformly: copper and derivatives both get the 232 rate on metal
  # content and IEEPA/fent/s122 on the complement — there is no copper-specific
  # carve-out for full-rate fentanyl. CA/MX fentanyl on pure-copper heading
  # products ends up at roughly fent * (1 - copper_share).
  if (stacking_method == 'tpc_additive') {
    # Sum EVERY rate authority the policy skeleton carries (stacking_policy_from_specs),
    # not a hand-listed subset — rate_301_cs and rate_s301fl were previously omitted,
    # making the additive total asymmetric with the mutual_exclusion branch. Coalesce
    # any absent column to 0 (matching compute_stacking_contributions' guard).
    rate_cols <- c('rate_232', 'rate_ieepa_recip', 'rate_ieepa_fent', 'rate_301',
                   'rate_301_cs', 'rate_s301fl', 'rate_s301br', 'rate_s122',
                   'rate_section_201', 'rate_other')
    for (rc in rate_cols) if (!rc %in% names(df)) df[[rc]] <- 0
    return(
      df %>%
        mutate(
          total_additional = rate_232 + rate_ieepa_recip + rate_ieepa_fent +
            rate_301 + rate_301_cs + rate_s301fl + rate_s301br + rate_s122 +
            rate_section_201 + rate_other,
          total_rate = base_rate + total_additional
        )
    )
  }

  policy <- stacking_policy %||% default_stacking_policy(cty_china)
  df <- compute_nonmetal_share(df)
  df <- compute_stacking_contributions(df, policy)

  contrib_cols <- unname(vapply(policy, function(p) paste0('.contrib_', p$net), character(1)))
  # Sum in policy order (Reduce is strictly left-to-right) so the baseline total
  # is bit-for-bit identical to the historical branch arithmetic.
  df$total_additional <- Reduce(`+`, lapply(contrib_cols, function(cc) df[[cc]]))
  df$total_rate <- df$base_rate + df$total_additional

  df %>% select(-all_of(contrib_cols), -nonmetal_share)
}


# =============================================================================
# Net Authority Decomposition (used by 09_daily_series)
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
                                                stacking_method = 'mutual_exclusion',
                                                stacking_policy = NULL) {
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

  policy <- stacking_policy %||% default_stacking_policy(cty_china)
  df <- compute_nonmetal_share(df)
  df <- compute_stacking_contributions(df, policy)

  # Surface each authority's contribution as its net_* column (same values the
  # historical mutual-exclusion case_when produced).
  for (col in names(policy)) {
    df[[policy[[col]]$net]] <- df[[paste0('.contrib_', policy[[col]]$net)]]
  }
  contrib_cols <- unname(vapply(policy, function(p) paste0('.contrib_', p$net), character(1)))

  df %>% select(-all_of(contrib_cols), -nonmetal_share)
}
