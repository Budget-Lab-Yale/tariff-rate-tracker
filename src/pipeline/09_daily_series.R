# =============================================================================
# Step 09: Daily Rate Series
# =============================================================================
#
# Provides pre-computed daily aggregates and on-demand expansion.
# Leverages the interval-encoded timeseries (valid_from / valid_until) built
# by 00_build_timeseries.R -- rates only change at revision boundaries, so
# we compute one aggregate per revision and broadcast across calendar days.
#
# Note: get_rates_at_date() is defined in helpers.R.
#
# Core functions:
#   build_daily_aggregates(ts, date_range, imports, policy_params) - daily ETRs
#   expand_to_daily(ts, date_range, countries, products) - on-demand expansion
#   run_daily_series(ts, imports, policy_params) - full pipeline wrapper
#   run_alternative_series(imports, pp, rebuild) - alternative daily series
#   build_alternative_timeseries(pp_override, variant, imports) - rebuild variant
#
# Usage:
#   # As library (source into other scripts):
#   source('src/pipeline/09_daily_series.R')
#   source('src/core/helpers.R')
#   ts <- readRDS('data/timeseries/rate_timeseries.rds')
#   snapshot <- get_rates_at_date(ts, as.Date('2025-06-15'))
#
#   # Standalone:
#   Rscript src/pipeline/09_daily_series.R
#
# =============================================================================

library(tidyverse)
library(jsonlite)


# =============================================================================
# Daily Aggregates
# =============================================================================

#' Shared per-revision preamble for the compute_agg_* helpers.
#'
#' Clips an already-filtered revision slice to its active sub-interval
#' (expiry zeroing), then applies stacking. The stacking policy is NOT uniform
#' across the aggregates, so it is selected explicitly — a single shared rule
#' here would silently change behavior:
#'   "conditional" — stack only if rate_s122/rate_ieepa_recip present (overall)
#'   "always"      — stack unconditionally (country, category)
#'   "none"        — caller applies stacking itself: inside an nrow(>0) guard
#'                   (weighted overall) or via compute_net_authority_contributions
#'                   (authority)
#'
#' @param rev_data Revision slice (already filtered, and joined where needed)
#' @param sub_start Sub-interval start passed to apply_expiry_zeroing
#' @param policy_params Policy params list
#' @param stacking_method Stacking method passed through to apply_stacking_rules
#' @param stacking One of "always", "conditional", "none"
#' @return rev_data after expiry zeroing and (mode-dependent) stacking
prepare_interval_data <- function(rev_data, sub_start, policy_params,
                                  stacking_method,
                                  stacking = c('always', 'conditional', 'none')) {
  stacking <- match.arg(stacking)
  rev_data <- apply_expiry_zeroing(rev_data, sub_start, policy_params)
  if (stacking == 'always' ||
      (stacking == 'conditional' &&
       any(c('rate_s122', 'rate_ieepa_recip') %in% names(rev_data)))) {
    rev_data <- apply_stacking_rules(rev_data, stacking_method = stacking_method)
  }
  rev_data
}

#' Interval slice with the AUTHORITATIVE effective rate (for rate aggregation).
#'
#' The snapshot's stored `total_rate` / `total_additional` are the effective rates
#' — they already reflect trade-preference and MFN-exemption reductions (USMCA/FTA
#' duty-free, GSP, per-country MFN exemption shares) and minted expiries (s122).
#' Re-deriving them from `base_rate + Σ rate_*` (as prepare_interval_data(stacking=
#' 'always') does) discards those reductions and re-charges the full statutory duty
#' on goods that actually enter duty-free — overstating the rate. So rate
#' aggregation must use the STORED total_rate, NOT a re-derivation.
#'
#' The ONE exception is a LIVE mid-interval expiry zeroing (the Swiss framework for
#' CH/LI after its expiry — s122 moved to boundary minting, so only Swiss remains):
#' there the stored total_rate is stale, so re-derive ONLY the rows the expiry
#' actually changes, leaving every other row on its authoritative stored rate.
#'
#' @return rev_data with stored total_rate/total_additional, except expiry-affected
#'   rows re-derived. NB: the authority decomposition uses prepare_interval_data +
#'   compute_net_authority_contributions for the per-authority split, then scales
#'   those contributions to this stored total_additional (see compute_agg_authority)
#'   so its parts stay on the same effective basis as weighted_etr — otherwise the
#'   etr_base residual mixes bases and goes negative on FTA/USMCA duty-free goods.
prepare_interval_data_effective <- function(rev_data, sub_start, policy_params,
                                            stacking_method) {
  if (is.null(rev_data) || nrow(rev_data) == 0) return(rev_data)
  # The stored total_rate/total_additional reflect the CANONICAL build stacking
  # (mutual_exclusion) AND the effective, exemption-reduced rates. They are the
  # authoritative rates for that method. For an ALTERNATIVE stacking method the
  # caller explicitly wants a re-derivation (a different combination of the same
  # components), so fall back to the full re-stack. (That alternative view re-uses
  # base_rate and so cannot reproduce the stored exemption reductions — an accepted
  # limitation of the non-canonical stacking, which the daily default never uses.)
  if (!identical(stacking_method, 'mutual_exclusion')) {
    return(prepare_interval_data(rev_data, sub_start, policy_params, stacking_method,
                                 stacking = 'always'))
  }
  if (is.null(policy_params)) return(rev_data)
  zeroed <- apply_expiry_zeroing(rev_data, sub_start, policy_params)
  comp <- intersect(c('rate_232', 'rate_301', 'rate_301_cs', 'rate_ieepa_recip',
                      'rate_ieepa_fent', 'rate_s122', 'rate_s338',
                      'rate_section_201', 'rate_other'),
                    names(rev_data))
  changed <- rep(FALSE, nrow(rev_data))
  for (cc in comp) changed <- changed | (abs(zeroed[[cc]] - rev_data[[cc]]) > 1e-12)
  if (any(changed)) {
    rr <- apply_stacking_rules(zeroed[changed, , drop = FALSE],
                               stacking_method = stacking_method)
    rev_data$total_rate[changed] <- rr$total_rate
    rev_data$total_additional[changed] <- rr$total_additional
  }
  rev_data
}

# =============================================================================
# Budget Lab Tariff HS Aggregation
# =============================================================================
# An aggregated-HS product classification for the daily by_hs rollup (see
# docs request tariff_rate_tracker_hs_breakdown_request.md). It maps every
# product to one of 22 policy-salient categories plus an explicit
# `unclassified` residual, mutually exclusive and exhaustive over HS chapters
# 01-97. Unlike the GTAP by_category rollup, it needs NO external crosswalk:
# category_code is a pure function of the product hts10 (2-digit chapter, with
# a single HS4 carve-out), so it stays trivially consistent between `actual`
# and every scenario.
#
# Rules (see docs):
#   1. Most-specific prefix wins: the 8541/8542 HS4 carve-out (semiconductors)
#      is applied AFTER the chapter rule so it overrides chapter-85 electronics.
#   2. Classify on the underlying PRODUCT hts10 (chapters 01-97), not the
#      Chapter 99 modification heading. The rate panel is keyed on the product
#      hts10 (the same base used to assign gtap_code), so chapters 98-99 appear
#      only for genuinely unresolvable lines.
#   3. Residual is explicit: no chapter match -> 'unclassified', never dropped.

hs_category_labels <- tibble::tribble(
  ~category_code,               ~category_label,
  'ag_live_animals',            'Agriculture & live animals',
  'processed_foods',            'Processed foods, beverages & tobacco',
  'minerals_ores',              'Minerals & ores',
  'energy',                     'Energy (mineral fuels)',
  'pharmaceuticals',            'Pharmaceuticals',
  'chemicals',                  'Chemicals (ex-pharma)',
  'plastics_rubber',            'Plastics & rubber',
  'leather',                    'Leather & furskins',
  'wood_paper',                 'Wood, paper & printing',
  'textiles_apparel_footwear',  'Textiles, apparel & footwear',
  'stone_glass',                'Stone, cement, ceramics & glass',
  'precious_metals',            'Precious metals & stones',
  'iron_steel',                 'Iron & steel',
  'aluminum',                   'Aluminum',
  'other_base_metals',          'Other base metals',
  'semiconductors',             'Semiconductors & electronic components',
  'electronics',                'Electronics & electrical equipment',
  'machinery',                  'Industrial machinery & computers',
  'motor_vehicles',             'Motor vehicles & parts',
  'other_transport',            'Other transport equipment',
  'instruments',                'Precision instruments & optical',
  'misc_manufactures',          'Miscellaneous manufactures',
  'unclassified',               'Special / unclassified'
)

# Named lookup: 2-digit HS chapter -> category_code. Chapters with no entry
# (e.g. 77, reserved; 98-99, special) fall through to 'unclassified'.
hs_chapter_to_category <- local({
  m <- character(0)
  put <- function(m, lo, hi, code) {
    for (ch in lo:hi) m[[sprintf('%02d', ch)]] <- code
    m
  }
  m <- put(m,  1, 15, 'ag_live_animals')
  m <- put(m, 16, 24, 'processed_foods')
  m <- put(m, 25, 26, 'minerals_ores')
  m[['27']] <- 'energy'
  m <- put(m, 28, 29, 'chemicals')
  m[['30']] <- 'pharmaceuticals'
  m <- put(m, 31, 38, 'chemicals')
  m <- put(m, 39, 40, 'plastics_rubber')
  m <- put(m, 41, 43, 'leather')
  m <- put(m, 44, 49, 'wood_paper')
  m <- put(m, 50, 67, 'textiles_apparel_footwear')
  m <- put(m, 68, 70, 'stone_glass')
  m[['71']] <- 'precious_metals'
  m <- put(m, 72, 73, 'iron_steel')
  m <- put(m, 74, 75, 'other_base_metals')
  m[['76']] <- 'aluminum'
  m <- put(m, 78, 83, 'other_base_metals')
  m[['84']] <- 'machinery'
  m[['85']] <- 'electronics'
  m[['86']] <- 'other_transport'
  m[['87']] <- 'motor_vehicles'
  m <- put(m, 88, 89, 'other_transport')
  m <- put(m, 90, 92, 'instruments')
  m <- put(m, 93, 97, 'misc_manufactures')
  m
})

#' Classify a vector of product hts10 codes into Budget Lab HS categories.
#'
#' Pure function of the 10-digit product code (character, leading zeros
#' preserved). Vectorized; returns a character vector of category_code.
#'
#' @param hs10 Character vector of hts10 codes.
#' @return Character vector of category_code (never NA; unmatched -> 'unclassified').
classify_hs10 <- function(hs10) {
  hs10 <- as.character(hs10)
  chapter <- substr(hs10, 1, 2)
  hs4     <- substr(hs10, 1, 4)
  code <- unname(hs_chapter_to_category[chapter])
  code[is.na(code)] <- 'unclassified'          # rule 3: explicit residual
  code[hs4 %in% c('8541', '8542')] <- 'semiconductors'  # rule 1: HS4 carve-out wins
  code
}

#' Build daily aggregate statistics
#'
#' Since rates only change at revision boundaries, computes one aggregate per
#' revision and broadcasts to all calendar days in that revision's interval.
#' Import weights are optional -- if NULL, computes simple (unweighted) means.
#'
#' If policy_params contains SECTION_122 with finalized=FALSE, any revision
#' interval that spans the s122 expiry date is split into two sub-intervals:
#' one with s122 active and one with s122 zeroed.
#'
#' @param ts Timeseries tibble with valid_from/valid_until
#' @param date_range Length-2 Date vector (start, end). Default: full timeseries range
#' @param imports Optional static tibble with hs10, cty_code, imports columns:
#'   one weight context for the whole series. Mutually exclusive with imports_fn.
#' @param imports_fn Optional provider function for PER-INTERVAL weights.
#'   Called once per revision with interval_context =
#'   list(revision, hts_as_of_date, policy_valid_from, panel_codes); must return
#'   list(weights = tibble(hs10, cty_code, imports), stats, fingerprint).
#'   Requires hts_as_of_dates. Mutually exclusive with imports.
#' @param policy_params Optional policy params list (from load_policy_params())
#' @param hts_as_of_dates Named lookup (revision -> raw HTS-identity Date, from
#'   revision_dates$effective_date, NEVER policy valid_from). Required with
#'   imports_fn; supplies each interval_context's hts_as_of_date.
#' @return List with daily_overall, daily_by_country, daily_by_authority tibbles
#'   (plus agg_* interval tables and, in imports_fn mode, weight_stats).
build_daily_aggregates <- function(ts, date_range = NULL, imports = NULL,
                                   imports_fn = NULL,
                                   policy_params = NULL,
                                   stacking_method = 'mutual_exclusion',
                                   hts_as_of_dates = NULL) {

  stopifnot(
    'valid_from' %in% names(ts),
    'valid_until' %in% names(ts)
  )

  # Default date range: full timeseries span

  if (is.null(date_range)) {
    date_range <- c(min(ts$valid_from), max(ts$valid_until))
  }
  date_range <- as.Date(date_range)

  # Get unique revision intervals
  rev_intervals <- ts %>%
    distinct(revision, valid_from, valid_until) %>%
    arrange(valid_from)

  message('Building daily aggregates for ', date_range[1], ' to ', date_range[2])
  message('  Revisions: ', nrow(rev_intervals))

  # Provider contract: EITHER a static `imports` tibble (one weight context for
  # the whole series) OR an `imports_fn(interval_context)` that yields
  # per-interval weights — never both. `has_weights` is true in either case;
  # the interval-local weight context (denominators) is built by
  # make_weight_context() below, once for the static tibble or once per
  # revision for imports_fn.
  if (!is.null(imports) && !is.null(imports_fn)) {
    stop('build_daily_aggregates: pass at most one of `imports` / `imports_fn`.',
         call. = FALSE)
  }
  use_imports_fn <- !is.null(imports_fn)
  has_weights    <- !is.null(imports) || use_imports_fn
  if (use_imports_fn && is.null(hts_as_of_dates)) {
    stop('build_daily_aggregates: imports_fn requires hts_as_of_dates ',
         '(a named revision -> raw HTS-identity date lookup).', call. = FALSE)
  }

  # --- GTAP category crosswalk (HS10 → GTAP sector) ---
  # Used by compute_agg_category to produce by_category aggregates. If the file
  # is missing the by-category aggregation is skipped silently — keeps the
  # aggregator backwards-compatible. Crosswalk schema: hs10, hs6_code,
  # gtap_code, description (note: 'hs10' here is the same 10-digit code the
  # rate snapshot stores under 'hts10').
  gtap_crosswalk_path <- here('resources', 'hs10_gtap_crosswalk.csv')
  has_categories <- file.exists(gtap_crosswalk_path)
  if (has_categories) {
    # GTAP sector is keyed on the 6-digit HS heading, NOT the full 10-digit code.
    # Statistical HS10 suffixes never change the GTAP sector, and HS6 -> GTAP is
    # a stable 1:1 map, so joining on the HS6 prefix makes the category rollup
    # suffix-vintage-insensitive: a renumbered HS10 whose HS6 is known still maps
    # to its sector instead of collapsing to 'unmapped' on an exact-HS10 miss.
    gtap_xwalk <- suppressMessages(
      read_csv(gtap_crosswalk_path, col_types = cols(.default = col_character()))
    ) %>% transmute(hs6 = hs6_code, gtap_code) %>% distinct()
    if (anyDuplicated(gtap_xwalk$hs6) > 0) {
      stop('hs10_gtap_crosswalk.csv maps some HS6 headings to multiple GTAP ',
           'sectors — the HS6 category join needs a 1:1 HS6 -> GTAP map.', call. = FALSE)
    }
    # Note: ts/ts_weighted are NOT joined to gtap_xwalk upfront — at full
    # build size (~195M rows) the materialized join OOMs at the coalesce
    # step. compute_agg_category does the join per revision instead.
  }

  # --- Interval-local weight context ----------------------------------------
  # Build the weighted-ETR denominators from an imports tibble
  # (hs10, cty_code, imports). This closes over gtap_xwalk / has_categories
  # (constants shared by every interval), NOT over the denominators themselves:
  # every compute_agg_* helper reads the denominators only from the `wctx` it is
  # passed, so the identical helpers serve both the static (`imports`) and the
  # per-interval (`imports_fn`) paths. sector_total_imports is NULL when no GTAP
  # crosswalk is present.
  make_weight_context <- function(imp) {
    total_imports <- sum(imp$imports)
    country_total_imp <- imp %>%
      group_by(cty_code) %>%
      summarise(country_total_imports = sum(imports), .groups = 'drop') %>%
      rename(country = cty_code)
    sector_total_imports <- NULL
    if (has_categories) {
      # Per-sector total imports (denominator for sector-weighted ETR).
      sector_total_imports <- imp %>%
        mutate(hs6 = substr(hs10, 1, 6)) %>%
        left_join(gtap_xwalk, by = 'hs6') %>%
        mutate(gtap_code = coalesce(gtap_code, 'unmapped')) %>%
        group_by(gtap_code) %>%
        summarise(sector_total_imports = sum(imports), .groups = 'drop')
      # No positive-weight flow may land 'unmapped' when its HS6 IS known.
      leaked <- imp %>% filter(imports > 0) %>%
        mutate(hs6 = substr(hs10, 1, 6)) %>%
        filter(hs6 %in% gtap_xwalk$hs6) %>%
        left_join(gtap_xwalk, by = 'hs6') %>%
        filter(is.na(gtap_code))
      if (nrow(leaked) > 0) {
        stop(sprintf('%d positive-weight flow(s) with a known HS6 landed unmapped — bug.',
                     nrow(leaked)), call. = FALSE)
      }
    }
    # Per-category total imports (denominator for by_hs weighted ETR).
    # Independent of the GTAP crosswalk: category_code is derived from the
    # product hs10 directly, so by_hs is always produced.
    category_total_imports <- imp %>%
      mutate(category_code = classify_hs10(hs10)) %>%
      group_by(category_code) %>%
      summarise(category_total_imports = sum(imports), .groups = 'drop')
    list(
      imports = imp,
      total_imports = total_imports,
      country_total_imp = country_total_imp,
      sector_total_imports = sector_total_imports,
      category_total_imports = category_total_imports
    )
  }

  # Static mode: one weight context + one weighted join, reused for every
  # interval (byte-identical to the pre-refactor behavior). imports_fn mode
  # builds the context per revision inside the loop below.
  wctx_static <- NULL
  ts_weighted <- NULL
  if (has_weights && !use_imports_fn) {
    message('  Using import weights (', nrow(imports), ' flows)')
    wctx_static <- make_weight_context(imports)
    message('  Total imports: $', round(wctx_static$total_imports / 1e9, 1), 'B')
    # Products not in the timeseries (no additional tariffs) implicitly have
    # rate = 0 and contribute only to the denominator.
    ts_weighted <- ts %>%
      inner_join(
        imports %>% select(hs10, cty_code, imports),
        by = c('hts10' = 'hs10', 'country' = 'cty_code')
      )
  }
  # Per-revision weight fingerprint + mapper stats (imports_fn mode only).
  weight_stats <- list()

  # China code for net authority decomposition
  CTY_CHINA <- if (!is.null(policy_params)) policy_params$CTY_CHINA %||% '5700' else '5700'

  # --- Policy expiry split points (Section 122, Swiss framework, etc.) ---
  # Uses shared helpers from helpers.R to detect all finalized=false overrides

  # Helper: compute aggregates for one revision interval (or sub-interval)
  compute_agg_overall <- function(rev_ts, rev_ts_w, wctx, revision, valid_from, valid_until, sub_start = valid_from) {
    rev_data <- prepare_interval_data_effective(rev_ts,
                                                sub_start, policy_params, stacking_method)
    n_products <- n_distinct(rev_data$hts10)
    n_countries <- n_distinct(rev_data$country)
    n_pairs <- nrow(rev_data)
    n_all_pairs <- n_products * n_countries

    row <- tibble(
      revision = revision,
      valid_from = valid_from,
      valid_until = valid_until,
      mean_additional_exposed = mean(rev_data$total_additional),
      mean_total_exposed = mean(rev_data$total_rate),
      mean_additional_all_pairs = sum(rev_data$total_additional) / n_all_pairs,
      mean_total_all_pairs = sum(rev_data$total_rate) / n_all_pairs,
      n_products = n_products,
      n_countries = n_countries,
      n_pairs = n_pairs,
      n_all_pairs = n_all_pairs
    )
    if (has_weights) {
      wt_data <- prepare_interval_data_effective(rev_ts_w,
                                                 sub_start, policy_params, stacking_method)
      if (nrow(wt_data) > 0) {
        row$weighted_etr <- sum(wt_data$total_rate * wt_data$imports) / wctx$total_imports
        row$weighted_etr_additional <- sum(wt_data$total_additional * wt_data$imports) / wctx$total_imports
        row$matched_imports_b <- sum(wt_data$imports) / 1e9
        row$total_imports_b <- wctx$total_imports / 1e9
      } else {
        row$weighted_etr <- 0
        row$weighted_etr_additional <- 0
        row$matched_imports_b <- 0
        row$total_imports_b <- wctx$total_imports / 1e9
      }
    }
    return(row)
  }

  compute_agg_country <- function(rev_ts, rev_ts_w, wctx, revision, valid_from, valid_until, sub_start = valid_from) {
    rev_data <- prepare_interval_data_effective(rev_ts,
                                                sub_start, policy_params, stacking_method)
    n_products_rev <- n_distinct(rev_data$hts10)
    row <- rev_data %>%
      group_by(country) %>%
      summarise(
        mean_additional_exposed = mean(total_additional),
        mean_total_exposed = mean(total_rate),
        mean_additional_all_pairs = sum(total_additional) / n_products_rev,
        mean_total_all_pairs = sum(total_rate) / n_products_rev,
        n_products_present = n(),
        .groups = 'drop'
      ) %>%
      mutate(
        revision = revision, valid_from = valid_from, valid_until = valid_until,
        n_products_total = n_products_rev
      )
    if (has_weights) {
      wt_data <- prepare_interval_data_effective(rev_ts_w,
                                                 sub_start, policy_params, stacking_method)
      wt_country <- wt_data %>%
        group_by(country) %>%
        summarise(
          tariffed_imports = sum(imports),
          weighted_numerator = sum(total_rate * imports),
          .groups = 'drop'
        ) %>%
        left_join(wctx$country_total_imp, by = 'country') %>%
        mutate(
          country_total_imports = coalesce(country_total_imports, tariffed_imports),
          weighted_etr = weighted_numerator / country_total_imports
        ) %>%
        select(country, weighted_etr)
      row <- row %>% left_join(wt_country, by = 'country')
    }
    return(row)
  }

  # Scale the re-derived per-authority contributions to the STORED effective
  # additional per cell, so the authority decomposition reflects trade-preference
  # / MFN-exemption reductions the same way weighted_etr (agg_overall) does. The
  # net_* are the mutual-exclusion split of the UN-reduced statutory additional;
  # their per-cell sum is the re-derived additional, while total_additional (stored)
  # is the effective, exemption-reduced additional. Scaling by their ratio makes
  # Σ authorities == weighted effective additional, so etr_base (= weighted_etr −
  # Σ authorities) collapses to the weighted effective BASE (>= 0) instead of a
  # mixed-basis residual that goes negative on FTA/USMCA duty-free goods. Canonical
  # (mutual_exclusion) stacking only; the tpc_additive view re-derives weighted_etr
  # too, so it stays self-consistent without scaling.
  auth_net_cols <- c('net_232', 'net_301', 'net_301_cs', 'net_ieepa',
                     'net_fentanyl', 'net_s122', 'net_s338', 'net_section_201',
                     'net_other')
  scale_net_to_effective <- function(net_df, eff_additional) {
    if (!identical(stacking_method, 'mutual_exclusion')) return(net_df)
    cols <- intersect(auth_net_cols, names(net_df))
    rederived <- Reduce(`+`, net_df[cols])
    f <- ifelse(rederived > 1e-12, pmax(eff_additional, 0) / rederived, 0)
    for (cc in cols) net_df[[cc]] <- net_df[[cc]] * f
    net_df
  }

  compute_agg_authority <- function(rev_ts, rev_ts_w, wctx, revision, valid_from, valid_until, sub_start = valid_from) {
    rev_data <- prepare_interval_data(rev_ts,
                                      sub_start, policy_params, stacking_method,
                                      stacking = 'none')

    # Use shared net authority decomposition from helpers.R
    net_data <- compute_net_authority_contributions(rev_data, cty_china = CTY_CHINA,
                                                     stacking_method = stacking_method)
    # A2: content-split 301 (net_301_cs) is reported UNDER Section 301 here, so the
    # daily decomposition needs no new column — byte-identical in baseline, where
    # net_301_cs = 0. Guard the tpc_additive path, which omits net_301_cs.
    if (!'net_301_cs' %in% names(net_data)) net_data$net_301_cs <- 0
    # net_s338 is guarded the same way (the tpc_additive path of older snapshots
    # may omit it; the canonical policy path always carries it).
    if (!'net_s338' %in% names(net_data)) net_data$net_s338 <- 0
    # Reduce to the effective additional (same authoritative basis as weighted_etr).
    # prepare_interval_data_effective preserves rev_ts row order, so total_additional
    # aligns positionally with net_data.
    eff_data <- prepare_interval_data_effective(rev_ts, sub_start, policy_params,
                                                stacking_method)
    net_data <- scale_net_to_effective(net_data, eff_data$total_additional)

    row <- tibble(
      revision = revision,
      valid_from = valid_from,
      valid_until = valid_until,
      mean_232 = mean(net_data$net_232),
      mean_301 = mean(net_data$net_301 + net_data$net_301_cs),
      mean_ieepa = mean(net_data$net_ieepa),
      mean_fentanyl = mean(net_data$net_fentanyl),
      mean_s122 = mean(net_data$net_s122),
      mean_s338 = mean(net_data$net_s338),
      mean_section_201 = mean(net_data$net_section_201),
      mean_other = mean(net_data$net_other)
    )
    if (has_weights) {
      wt_data <- prepare_interval_data(rev_ts_w,
                                       sub_start, policy_params, stacking_method,
                                       stacking = 'none')
      if (nrow(wt_data) > 0) {
        wt_net <- compute_net_authority_contributions(wt_data, cty_china = CTY_CHINA,
                                                      stacking_method = stacking_method)
        if (!'net_301_cs' %in% names(wt_net)) wt_net$net_301_cs <- 0
        if (!'net_s338' %in% names(wt_net)) wt_net$net_s338 <- 0
        eff_wt <- prepare_interval_data_effective(rev_ts_w, sub_start, policy_params,
                                                  stacking_method)
        wt_net <- scale_net_to_effective(wt_net, eff_wt$total_additional)
        row$etr_232 <- sum(wt_net$net_232 * wt_net$imports) / wctx$total_imports
        row$etr_301 <- sum((wt_net$net_301 + wt_net$net_301_cs) * wt_net$imports) / wctx$total_imports
        row$etr_ieepa <- sum(wt_net$net_ieepa * wt_net$imports) / wctx$total_imports
        row$etr_fentanyl <- sum(wt_net$net_fentanyl * wt_net$imports) / wctx$total_imports
        row$etr_s122 <- sum(wt_net$net_s122 * wt_net$imports) / wctx$total_imports
        row$etr_s338 <- sum(wt_net$net_s338 * wt_net$imports) / wctx$total_imports
        row$etr_section_201 <- sum(wt_net$net_section_201 * wt_net$imports) / wctx$total_imports
        row$etr_other <- sum(wt_net$net_other * wt_net$imports) / wctx$total_imports
      } else {
        row$etr_232 <- row$etr_301 <- row$etr_ieepa <- row$etr_fentanyl <- 0
        row$etr_s122 <- row$etr_s338 <- row$etr_section_201 <- row$etr_other <- 0
      }
    }
    return(row)
  }

  compute_agg_category <- function(rev_ts, rev_ts_w, wctx, revision, valid_from, valid_until, sub_start = valid_from) {
    rev_data <- prepare_interval_data_effective(
      rev_ts %>%
        mutate(hs6 = substr(hts10, 1, 6)) %>%
        left_join(gtap_xwalk, by = 'hs6') %>%
        mutate(gtap_code = coalesce(gtap_code, 'unmapped')),
      sub_start, policy_params, stacking_method)
    n_products_rev <- n_distinct(rev_data$hts10)
    row <- rev_data %>%
      group_by(gtap_code) %>%
      summarise(
        mean_additional_exposed = mean(total_additional),
        mean_total_exposed = mean(total_rate),
        mean_additional_all_pairs = sum(total_additional) / n_products_rev,
        mean_total_all_pairs = sum(total_rate) / n_products_rev,
        n_products_present = n_distinct(hts10),
        n_pairs_present = n(),
        .groups = 'drop'
      ) %>%
      mutate(
        revision = revision, valid_from = valid_from, valid_until = valid_until,
        n_products_total = n_products_rev
      )
    if (has_weights) {
      wt_data <- prepare_interval_data_effective(
        rev_ts_w %>%
          mutate(hs6 = substr(hts10, 1, 6)) %>%
          left_join(gtap_xwalk, by = 'hs6') %>%
          mutate(gtap_code = coalesce(gtap_code, 'unmapped')),
        sub_start, policy_params, stacking_method)
      wt_sector <- wt_data %>%
        group_by(gtap_code) %>%
        summarise(
          tariffed_imports = sum(imports),
          weighted_numerator = sum(total_rate * imports),
          .groups = 'drop'
        ) %>%
        left_join(wctx$sector_total_imports, by = 'gtap_code') %>%
        mutate(
          sector_total_imports = coalesce(sector_total_imports, tariffed_imports),
          weighted_etr = weighted_numerator / sector_total_imports
        ) %>%
        select(gtap_code, weighted_etr)
      row <- row %>% left_join(wt_sector, by = 'gtap_code')
    }
    return(row)
  }

  # by_hs mirrors compute_agg_category exactly, but the grouping key is the
  # Budget Lab HS category_code derived from the product hts10 (no crosswalk
  # join) and the weighted-ETR denominator is category_total_imports. Same
  # import-weight base and weighting method as by_category / overall.
  compute_agg_hs <- function(rev_ts, rev_ts_w, wctx, revision, valid_from, valid_until, sub_start = valid_from) {
    rev_data <- prepare_interval_data_effective(
      rev_ts %>% mutate(category_code = classify_hs10(hts10)),
      sub_start, policy_params, stacking_method)
    n_products_rev <- n_distinct(rev_data$hts10)
    row <- rev_data %>%
      group_by(category_code) %>%
      summarise(
        mean_additional_exposed = mean(total_additional),
        mean_total_exposed = mean(total_rate),
        mean_additional_all_pairs = sum(total_additional) / n_products_rev,
        mean_total_all_pairs = sum(total_rate) / n_products_rev,
        n_products_present = n_distinct(hts10),
        n_pairs_present = n(),
        .groups = 'drop'
      ) %>%
      mutate(
        revision = revision, valid_from = valid_from, valid_until = valid_until,
        n_products_total = n_products_rev
      )
    if (has_weights) {
      wt_data <- prepare_interval_data_effective(
        rev_ts_w %>% mutate(category_code = classify_hs10(hts10)),
        sub_start, policy_params, stacking_method)
      wt_cat <- wt_data %>%
        group_by(category_code) %>%
        summarise(
          tariffed_imports = sum(imports),
          weighted_numerator = sum(total_rate * imports),
          .groups = 'drop'
        ) %>%
        left_join(wctx$category_total_imports, by = 'category_code') %>%
        mutate(
          category_total_imports = coalesce(category_total_imports, tariffed_imports),
          weighted_etr = weighted_numerator / category_total_imports
        ) %>%
        select(category_code, weighted_etr)
      row <- row %>% left_join(wt_cat, by = 'category_code')
    }
    return(row)
  }

  # --- Per-revision aggregates (with generic expiry splitting) ---
  # Phase 3c: the unified splitter (src/model/timeline.R) owns interval splitting, fed the
  # EXPIRY boundaries (SECTION_122 / SWISS) — the schedule boundaries that fall
  # strictly INSIDE a revision interval on the baseline grid (intervals are
  # gapless/exclusive, valid_until = next_rev - 1, so every revision-dated policy
  # event sits on an edge, not inside). This is the sole interval splitter here —
  # the old get_expiry_split_points path was retired in Phase 1b after its splits
  # were verified identical on the REAL grid (tests/test_timeline_realdata.R).
  #
  # collect_schedule_boundaries() is the comprehensive collector (invalidation +
  # expiries + spec active windows). It is NOT fed here because the real-data test
  # surfaced that IEEPA invalidation (policy_params) precedes its revision row
  # (2026_rev_4) by 4 days, i.e. it lands mid-interval in 2026_rev_3 — feeding it
  # would add a split AND, to be correct, needs invalidation zeroing wired. That is
  # a behavior/model change (and a modeling question: 02-20 vs 02-24), deliberately
  # OUT of this parity refactor and flagged for a follow-up. The collector is
  # validated and ready for that fix + for scenario effective_from dates.
  exp_bounds <- expiry_boundaries(policy_params)
  # Single pass over revision intervals: `ts` (and `ts_weighted`) is filtered to
  # each revision ONCE and reused by all four aggregators across every
  # sub-interval — previously each aggregator re-scanned the full ~195M-row table
  # per revision (and per sub-interval). One revision subset is alive at a time,
  # so peak memory is unchanged; only the redundant scans are removed. Segments
  # reproduce the old two branches exactly: with no inner split points the sole
  # segment is [valid_from, valid_until] with sub_start = valid_from; otherwise
  # [valid_from, s1-1], [s1, s2-1], ..., [sN, valid_until] each with sub_start = s.
  ov <- list(); ct <- list(); au <- list(); ca <- list(); hs <- list()
  seg_i <- 0L
  for (ri in seq_len(nrow(rev_intervals))) {
    rev_id      <- rev_intervals$revision[ri]
    valid_from  <- rev_intervals$valid_from[ri]
    valid_until <- rev_intervals$valid_until[ri]
    rev_ts   <- ts %>% filter(revision == rev_id)

    # Resolve this revision's weight context + weighted slice ONCE (reused by
    # every aggregator across every sub-interval; sub-intervals differ only by
    # expiry zeroing of rates, never by HTS identity, so the panel codes and
    # denominators are constant within a revision).
    wctx <- NULL
    rev_ts_w <- NULL
    if (has_weights) {
      if (use_imports_fn) {
        rev_as_of <- hts_as_of_dates[[as.character(rev_id)]]
        if (is.null(rev_as_of) || is.na(rev_as_of)) {
          stop('build_daily_aggregates: no hts_as_of_date for revision "', rev_id,
               '" in hts_as_of_dates.', call. = FALSE)
        }
        ictx <- list(revision = rev_id,
                     hts_as_of_date = as.Date(rev_as_of),
                     policy_valid_from = valid_from,
                     panel_codes = unique(as.character(rev_ts$hts10)))
        iw <- imports_fn(ictx)
        stopifnot(is.list(iw), !is.null(iw$weights))
        iw_w <- iw$weights %>% select(hs10, cty_code, imports)
        wctx <- make_weight_context(iw_w)
        rev_ts_w <- rev_ts %>%
          inner_join(iw_w, by = c('hts10' = 'hs10', 'country' = 'cty_code'))
        weight_stats[[as.character(rev_id)]] <-
          list(fingerprint = iw$fingerprint, stats = iw$stats)
      } else {
        wctx <- wctx_static
        rev_ts_w <- ts_weighted %>% filter(revision == rev_id)
      }
    }

    starts_inner <- timeline_split_points(valid_from, valid_until, exp_bounds)
    if (length(starts_inner) == 0) {
      starts <- valid_from; ends <- valid_until
    } else {
      starts <- c(valid_from, starts_inner)
      ends   <- c(starts_inner - 1, valid_until)
    }
    for (k in seq_along(starts)) {
      s <- starts[k]; e <- ends[k]
      seg_i <- seg_i + 1L
      ov[[seg_i]] <- compute_agg_overall(rev_ts, rev_ts_w, wctx, rev_id, s, e, sub_start = s)
      ct[[seg_i]] <- compute_agg_country(rev_ts, rev_ts_w, wctx, rev_id, s, e, sub_start = s)
      au[[seg_i]] <- compute_agg_authority(rev_ts, rev_ts_w, wctx, rev_id, s, e, sub_start = s)
      if (has_categories) {
        ca[[seg_i]] <- compute_agg_category(rev_ts, rev_ts_w, wctx, rev_id, s, e, sub_start = s)
      }
      hs[[seg_i]] <- compute_agg_hs(rev_ts, rev_ts_w, wctx, rev_id, s, e, sub_start = s)
    }
  }
  agg_overall <- bind_rows(ov)
  agg_by_country <- bind_rows(ct)
  agg_by_authority <- bind_rows(au)
  agg_by_category <- if (has_categories) bind_rows(ca) else tibble()
  # Attach the human label and order columns (date is prepended by expand).
  agg_by_hs <- bind_rows(hs) %>%
    left_join(hs_category_labels, by = 'category_code') %>%
    relocate(category_label, .after = category_code)

  # Add etr_base to authority decomposition so parts sum to weighted_etr.
  # Computed as residual: weighted_etr - sum(authority ETRs). This guarantees
  # exact additivity regardless of matched/unmatched product handling.
  if (has_weights && 'weighted_etr' %in% names(agg_overall)) {
    overall_etr <- agg_overall %>%
      select(revision, valid_from, valid_until, weighted_etr)
    agg_by_authority <- agg_by_authority %>%
      left_join(overall_etr, by = c('revision', 'valid_from', 'valid_until')) %>%
      mutate(
        etr_base = weighted_etr - (etr_232 + etr_301 + etr_ieepa + etr_fentanyl +
                                    etr_s122 + etr_s338 + etr_section_201 + etr_other)
      ) %>%
      select(-weighted_etr)
  }

  # Log any expiry splits that occurred
  if (!is.null(policy_params)) {
    adjustments <- collect_expiry_adjustments(policy_params)
    for (adj in adjustments) {
      message('  ', adj$label, ' expiry split at ', adj$expiry_date)
    }
  }

  # --- Expand revision-level aggregates to daily ---
  # Iterate over revision intervals and replicate to each day (no fuzzyjoin needed)

  expand_intervals <- function(agg_df) {
    agg_df %>%
      pmap_dfr(function(...) {
        row <- tibble(...)
        start <- max(row$valid_from, date_range[1])
        end   <- min(row$valid_until, date_range[2])
        if (start > end) return(tibble())
        dates <- seq(start, end, by = 'day')
        tibble(date = dates) %>%
          bind_cols(row %>% select(-valid_from, -valid_until) %>% slice(rep(1, length(dates))))
      })
  }

  daily_overall <- expand_intervals(agg_overall)
  daily_by_country <- expand_intervals(agg_by_country)
  daily_by_authority <- expand_intervals(agg_by_authority)
  daily_by_category <- if (nrow(agg_by_category) > 0) expand_intervals(agg_by_category) else tibble()
  daily_by_hs <- if (nrow(agg_by_hs) > 0) expand_intervals(agg_by_hs) else tibble()

  message('  Daily overall rows: ', nrow(daily_overall))
  message('  Daily by-country rows: ', nrow(daily_by_country))
  message('  Daily by-authority rows: ', nrow(daily_by_authority))
  if (has_categories) {
    message('  Daily by-category rows: ', nrow(daily_by_category))
  }
  message('  Daily by-hs rows: ', nrow(daily_by_hs))

  return(list(
    daily_overall = daily_overall,
    daily_by_country = daily_by_country,
    daily_by_authority = daily_by_authority,
    daily_by_category = daily_by_category,
    daily_by_hs = daily_by_hs,
    agg_overall = agg_overall,
    agg_by_country = agg_by_country,
    agg_by_authority = agg_by_authority,
    agg_by_category = agg_by_category,
    agg_by_hs = agg_by_hs,
    weight_stats = weight_stats
  ))
}


# =============================================================================
# On-Demand Expansion
# =============================================================================

#' Expand interval rows to one-per-date for a subset
#'
#' For ad-hoc analysis. Forces caller to specify a subset to prevent
#' accidental full expansion (366 days x ~12M rows = ~4B rows).
#'
#' @param ts Timeseries tibble with valid_from/valid_until
#' @param date_range Length-2 Date vector (start, end)
#' @param countries Character vector of country codes to include
#' @param products Character vector of HTS10 codes to include
#' @param policy_params Optional policy params list. If supplied, applies the
#'   same post-interval expiry adjustments used by export_daily_slice().
#' @return Tibble with one row per date x product x country
expand_to_daily <- function(ts, date_range, countries, products, policy_params = NULL) {
  date_range <- as.Date(date_range)

  stopifnot(
    length(countries) > 0,
    length(products) > 0,
    length(date_range) == 2
  )

  expanded <- export_daily_slice(
    ts = ts,
    date_range = date_range,
    countries = countries,
    products = products,
    policy_params = policy_params,
    full_export = FALSE,
    output_path = NULL,
    columns = NULL
  )

  subset <- ts %>%
    filter(
      country %in% countries,
      hts10 %in% products,
      valid_until >= date_range[1],
      valid_from <= date_range[2]
    )

  message('Expanded ', nrow(subset), ' interval rows to ', nrow(expanded), ' daily rows')
  message('  Countries: ', n_distinct(expanded$country),
          ', Products: ', n_distinct(expanded$hts10),
          ', Days: ', n_distinct(expanded$date))

  return(expanded)
}


# =============================================================================
# Daily Slice Export
# =============================================================================

#' Export a filtered slice of the daily timeseries
#'
#' Extracts product-country-date level data from the interval-encoded timeseries
#' for a specified date range, with optional country/product filters.
#' Applies post-interval adjustments (Section 122 expiry, Swiss framework expiry).
#'
#' Safety: requires either explicit filters OR full_export = TRUE to prevent
#' accidental full expansion (~4.5M rows/revision x 730 days).
#'
#' @param ts Interval-encoded timeseries tibble
#' @param date_range Length-2 Date vector (start, end)
#' @param countries Optional character vector of country codes
#' @param products Optional character vector of HTS10 codes (or prefixes)
#' @param policy_params Policy params list (for post-interval adjustments)
#' @param output_path Output file path (.csv or .parquet). NULL = return only.
#' @param full_export Set TRUE to export without filters (safety override)
#' @param columns Optional character vector of columns to include in output.
#'   Default: narrow schema (date, hts10, country, rate columns, revision).
#' @return Exported tibble (invisibly if output_path is given)
export_daily_slice <- function(ts, date_range, countries = NULL, products = NULL,
                                policy_params = NULL, output_path = NULL,
                                full_export = FALSE, columns = NULL) {
  date_range <- as.Date(date_range)
  stopifnot(length(date_range) == 2, date_range[1] <= date_range[2])

  # Safety check
  if (is.null(countries) && is.null(products) && !full_export) {
    stop('export_daily_slice: must provide countries, products, or set full_export = TRUE.\n',
         'A full export produces billions of rows. Pass full_export = TRUE if intended.')
  }

  # Filter timeseries
  subset <- ts
  if (!is.null(countries)) subset <- subset %>% filter(country %in% countries)
  if (!is.null(products)) {
    # Support both exact codes and prefix matching
    if (any(nchar(products) < 10)) {
      prefix_pattern <- paste0('^(', paste(products, collapse = '|'), ')')
      subset <- subset %>% filter(grepl(prefix_pattern, hts10))
    } else {
      subset <- subset %>% filter(hts10 %in% products)
    }
  }

  if (nrow(subset) == 0) {
    warning('No matching rows for the requested filters')
    return(tibble())
  }

  # Clip intervals to requested date range
  subset <- subset %>%
    filter(valid_until >= date_range[1], valid_from <= date_range[2])

  # Collect expiry split points across the full date range
  split_dates <- if (!is.null(policy_params)) {
    adjustments <- collect_expiry_adjustments(policy_params)
    exp_dates <- map(adjustments, ~ as.Date(.$expiry_date))
    exp_dates <- exp_dates[exp_dates >= date_range[1] & exp_dates <= date_range[2]]
    sort(unique(as.Date(unlist(exp_dates), origin = '1970-01-01')))
  } else {
    as.Date(character())
  }

  # Expand intervals to daily, applying expiry adjustments per sub-interval
  calendar <- tibble(date = seq(date_range[1], date_range[2], by = 'day'))

  expanded <- subset %>%
    cross_join(calendar) %>%
    filter(date >= valid_from, date <= valid_until)

  # Apply post-interval adjustments (bulk by date partitions)
  if (length(split_dates) > 0 && nrow(expanded) > 0) {
    # Partition rows and apply zeroing to rows past each expiry
    for (adj in collect_expiry_adjustments(policy_params)) {
      exp <- as.Date(adj$expiry_date)
      if (adj$column %in% names(expanded)) {
        if (!is.null(adj$countries)) {
          expanded <- expanded %>%
            mutate(!!adj$column := if_else(
              date > exp & country %in% adj$countries, 0, .data[[adj$column]]))
        } else {
          expanded <- expanded %>%
            mutate(!!adj$column := if_else(date > exp, 0, .data[[adj$column]]))
        }
      }
    }
    # Recompute totals (pass cty_china from policy_params for correct stacking)
    cty_china <- if (!is.null(policy_params)) policy_params$CTY_CHINA %||% '5700' else '5700'
    expanded <- apply_stacking_rules(expanded, cty_china = cty_china)
  }

  # Select output columns
  default_columns <- c('date', 'hts10', 'country', 'base_rate',
                        'rate_232', 'rate_301', 'rate_ieepa_recip', 'rate_ieepa_fent',
                        'rate_s122', 'rate_s338', 'rate_section_201', 'rate_other',
                        'total_additional', 'total_rate', 'revision')
  out_cols <- if (!is.null(columns)) columns else default_columns
  out_cols <- intersect(out_cols, names(expanded))
  result <- expanded %>% select(all_of(out_cols))

  n_rows <- nrow(result)
  message('Exported ', n_rows, ' daily rows (',
          n_distinct(result$country), ' countries, ',
          n_distinct(result$hts10), ' products, ',
          n_distinct(result$date), ' days)')

  # Write output
  if (!is.null(output_path)) {
    ext <- tools::file_ext(output_path)
    dir_path <- dirname(output_path)
    ensure_dir(dir_path)

    if (ext == 'parquet' && requireNamespace('arrow', quietly = TRUE)) {
      arrow::write_parquet(result, output_path)
      message('Wrote ', output_path, ' (Parquet, ', round(file.size(output_path) / 1e6, 1), ' MB)')
    } else {
      if (ext == 'parquet') message('arrow package not available, falling back to CSV')
      csv_path <- if (ext == 'parquet') sub('\\.parquet$', '.csv', output_path) else output_path
      write_csv(result, csv_path)
      message('Wrote ', csv_path, ' (CSV, ', round(file.size(csv_path) / 1e6, 1), ' MB)')
    }
    return(invisible(result))
  }

  return(result)
}


# =============================================================================
# Reusable Wrappers (called by 00_build_timeseries.R post-build)
# =============================================================================

#' Load import weights for daily series weighting
#'
#' Behavior when the weight file is missing or unconfigured is controlled by
#' `weight_mode` in `config/local_paths.yaml`:
#'   - 'required' (default): error out — weighted outputs are mandatory unless
#'     the user has explicitly opted into an unweighted run.
#'   - 'unweighted': return NULL silently so callers skip weighted outputs.
#'
#' @param imports_path Path to hs10_by_country_gtap RDS (default: from local_paths config)
#' @param weight_mode Override `weight_mode` from local_paths.yaml. One of
#'   'required' (default behavior — hard error if file missing) or
#'   'unweighted' (return NULL, callers skip weighted outputs).
#' @return Tibble with hs10, cty_code, imports; or NULL if `weight_mode == 'unweighted'`
#'   and no weight file is available.
load_import_weights <- function(imports_path = NULL, weight_mode = NULL) {
  if (is.null(imports_path) || is.null(weight_mode)) {
    local_paths <- load_local_paths()
    if (is.null(imports_path)) imports_path <- local_paths$import_weights
    if (is.null(weight_mode)) weight_mode <- local_paths$weight_mode %||% 'required'
  }

  weight_mode <- match.arg(weight_mode, c('required', 'unweighted'))

  if (is.null(imports_path) || !nzchar(imports_path)) {
    if (weight_mode == 'unweighted') {
      message('weight_mode = "unweighted" and no import_weights path set — skipping weighted outputs.')
      return(NULL)
    }
    stop(weight_resolution_error(
      'config/local_paths.yaml has no `import_weights:` path set',
      context = 'load'
    ))
  }
  if (!file.exists(imports_path)) {
    if (weight_mode == 'unweighted') {
      message('weight_mode = "unweighted" — import weights file not found at ',
              imports_path, '; skipping weighted outputs.')
      return(NULL)
    }
    stop(weight_resolution_error(
      paste0('the configured file does not exist: ', imports_path),
      context = 'load'
    ))
  }
  message('Loading import weights from: ', imports_path)
  imports_raw <- readRDS(imports_path)
  imports <- imports_raw %>%
    group_by(hs10, cty_code) %>%
    summarise(imports = sum(imports), .groups = 'drop') %>%
    filter(imports > 0)
  message('  ', nrow(imports), ' import flows loaded')
  return(imports)
}


#' Save daily series to an Excel workbook
#'
#' Writes daily_overall, daily_by_country, and daily_by_authority as separate
#' sheets. Overwrites individual sheets without touching the rest of the
#' workbook. Creates the workbook with a README sheet if it does not exist.
#'
#' @param daily List from build_daily_aggregates()
#' @param xlsx_path Path to the Excel workbook
save_daily_workbook <- function(daily, xlsx_path) {
  library(openxlsx)

  data_sheets <- list(
    daily_overall     = daily$daily_overall,
    daily_by_country  = daily$daily_by_country,
    daily_by_authority = daily$daily_by_authority
  )

  # Load existing workbook or create a new one
  if (file.exists(xlsx_path)) {
    wb <- loadWorkbook(xlsx_path)
  } else {
    wb <- createWorkbook()
  }

  # Overwrite each data sheet (remove then re-add to clear old data)
  for (sheet_name in names(data_sheets)) {
    if (sheet_name %in% names(wb)) removeWorksheet(wb, sheet_name)
    addWorksheet(wb, sheet_name)
    writeData(wb, sheet_name, data_sheets[[sheet_name]])
  }

  # Write README sheet (only if it doesn't exist yet)
  if (!'README' %in% names(wb)) {
    addWorksheet(wb, 'README')
    readme <- build_daily_workbook_readme()
    writeData(wb, 'README', readme, headerStyle = createStyle(textDecoration = 'bold'))
  }

  # Ensure README is the first sheet
  sheet_order <- c('README', setdiff(names(wb), 'README'))
  worksheetOrder(wb) <- match(sheet_order, names(wb))

  saveWorkbook(wb, xlsx_path, overwrite = TRUE)
}


#' Build README content for the daily workbook
#'
#' @return Data frame describing each sheet and its variables
build_daily_workbook_readme <- function() {
  rows <- list(
    # --- Header ---
    c('Tariff Rate Tracker — Daily Aggregates Workbook', ''),
    c('', ''),
    c('Generated by src/pipeline/09_daily_series.R. Sheets are overwritten on each build.', ''),
    c(paste0('Last updated: ', Sys.Date()), ''),
    c('', ''),

    # --- daily_overall ---
    c('=== Sheet: daily_overall ===', ''),
    c('Daily aggregate tariff rates across all products and countries.', ''),
    c('Variable', 'Description'),
    c('date', 'Calendar date'),
    c('revision', 'HTS revision identifier (e.g., rev_7, 2026_rev_4)'),
    c('mean_additional_exposed', 'Mean additional tariff rate across tariffed product-country pairs only'),
    c('mean_total_exposed', 'Mean total tariff rate (base + additional) across tariffed pairs only'),
    c('mean_additional_all_pairs', 'Mean additional tariff rate across full Cartesian panel (missing pairs = 0)'),
    c('mean_total_all_pairs', 'Mean total tariff rate across full Cartesian panel (missing pairs = 0)'),
    c('n_products', 'Number of distinct HTS-10 products in the revision'),
    c('n_countries', 'Number of distinct countries in the revision'),
    c('n_pairs', 'Number of tariffed product-country pairs (sparse panel)'),
    c('n_all_pairs', 'Total product-country pairs in full Cartesian panel (n_products x n_countries)'),
    c('weighted_etr', 'Import-weighted effective tariff rate (total rate); NA if no import weights'),
    c('weighted_etr_new', 'Import-weighted total ETR in excess of the Jan-1-2025 baseline (weighted_etr minus its 2025-01-01 value); the increase attributable to 2025+ tariff actions'),
    c('weighted_etr_additional', 'Import-weighted effective tariff rate (additional duties only)'),
    c('matched_imports_b', 'Total imports ($B) matched to tariff data'),
    c('total_imports_b', 'Total imports ($B) in the weight file'),
    c('', ''),

    # --- daily_by_country ---
    c('=== Sheet: daily_by_country ===', ''),
    c('Daily aggregate tariff rates by country.', ''),
    c('Variable', 'Description'),
    c('date', 'Calendar date'),
    c('country', 'Census country code (4-digit)'),
    c('country_name', 'Country name (from census_codes.csv)'),
    c('country_abbr', 'Partner group abbreviation (e.g., china, eu, canada, row)'),
    c('mean_additional_exposed', 'Mean additional tariff rate across tariffed products for this country'),
    c('mean_total_exposed', 'Mean total tariff rate across tariffed products for this country'),
    c('mean_additional_all_pairs', 'Mean additional tariff rate using all products as denominator'),
    c('mean_total_all_pairs', 'Mean total tariff rate using all products as denominator'),
    c('n_products_present', 'Number of products with nonzero tariffs for this country'),
    c('revision', 'HTS revision identifier'),
    c('n_products_total', 'Total products in the revision (denominator for all_pairs means)'),
    c('weighted_etr', 'Import-weighted ETR for this country; NA if no import weights'),
    c('weighted_etr_new', 'Import-weighted ETR for this country in excess of its Jan-1-2025 baseline (weighted_etr minus its own 2025-01-01 value)'),
    c('', ''),

    # --- daily_by_authority ---
    c('=== Sheet: daily_by_authority ===', ''),
    c('Daily tariff rate decomposition by tariff authority.', ''),
    c('Variable', 'Description'),
    c('date', 'Calendar date'),
    c('revision', 'HTS revision identifier'),
    c('mean_232', 'Mean net Section 232 contribution (steel, aluminum, autos, copper, derivatives)'),
    c('mean_301', 'Mean net Section 301 contribution (China only)'),
    c('mean_ieepa', 'Mean net IEEPA reciprocal contribution (mutual exclusion with 232)'),
    c('mean_fentanyl', 'Mean net IEEPA fentanyl contribution (CA, MX, CN)'),
    c('mean_s122', 'Mean net Section 122 contribution (post-IEEPA invalidation, 150-day limit)'),
    c('mean_s338', 'Mean net Section 338 contribution (Canada +50%, effective 2026-08-19)'),
    c('mean_section_201', 'Mean net Section 201 contribution (safeguard duties, very small)'),
    c('mean_other', 'Mean net other tariff contribution'),
    c('etr_232', 'Import-weighted ETR contribution from Section 232'),
    c('etr_301', 'Import-weighted ETR contribution from Section 301'),
    c('etr_ieepa', 'Import-weighted ETR contribution from IEEPA reciprocal'),
    c('etr_fentanyl', 'Import-weighted ETR contribution from IEEPA fentanyl'),
    c('etr_s122', 'Import-weighted ETR contribution from Section 122'),
    c('etr_s338', 'Import-weighted ETR contribution from Section 338 (Canada)'),
    c('etr_section_201', 'Import-weighted ETR contribution from Section 201'),
    c('etr_other', 'Import-weighted ETR contribution from other authorities'),
    c('etr_base', 'Import-weighted base rate contribution (residual: weighted_etr minus all authority ETRs)'),
    c('', ''),
    c('Note: etr_base + etr_232 + etr_301 + etr_ieepa + etr_fentanyl + etr_s122 + etr_s338 + etr_section_201 + etr_other = weighted_etr (from daily_overall)', ''),
    c('', ''),

    # --- Notes ---
    c('=== Notes ===', ''),
    c('Exposed means: denominator is only product-country pairs with nonzero tariffs.', ''),
    c('All-pairs means: denominator is the full Cartesian panel (products x countries); untariffed pairs contribute 0.', ''),
    c('Weighted ETR: uses 2024 Census import values as weights; total imports denominator includes all flows.', ''),
    c('Net authority contributions sum to total_additional (after stacking and mutual exclusion rules).', ''),
    c('Source: Yale Budget Lab Tariff Rate Tracker, built from USITC HTS archives.', '')
  )

  df <- do.call(rbind, lapply(rows, function(r) data.frame(Column = r[1], Description = r[2], stringsAsFactors = FALSE)))
  return(df)
}


# The Jan-1-2025 baseline date for weighted_etr_new. This is the tracker's
# pre-2025-actions starting point (revision 'basic', the first snapshot). Kept a
# named constant so the "new" reference point is defined in exactly one place.
WEIGHTED_ETR_NEW_BASELINE_DATE <- as.Date('2025-01-01')

#' Add weighted_etr_new: the import-weighted total ETR IN EXCESS of Jan 1 2025.
#'
#' weighted_etr_new(t) = weighted_etr(t) - weighted_etr(2025-01-01), i.e. the
#' increase in the import-weighted total effective rate relative to the
#' pre-2025-actions baseline (what the 2025+ tariff actions added on top of what
#' was already in place). It is DISTINCT from weighted_etr_additional, which
#' remains the import-weighted sum of all additional-duty layers (base-excluded)
#' and includes legacy pre-2025 232/301.
#'
#' This is inherently CROSS-REVISION (it references the 2025-01-01 row), so it
#' cannot be computed inside a per-snapshot build_daily_aggregates() call. It is
#' applied here, on the fully-assembled daily series, keyed on each series' own
#' 2025-01-01 value: overall against the single baseline, by_country against each
#' country's baseline, by_category against each GTAP sector's baseline. Series
#' without weighted_etr (unweighted builds) and by_authority (a net_* authority
#' decomposition with no total) are left untouched.
#'
#' @param daily List with expanded daily_* frames (each has a `date` column)
#' @return `daily` with weighted_etr_new added where applicable
add_weighted_etr_new <- function(daily,
                                 baseline_date = WEIGHTED_ETR_NEW_BASELINE_DATE) {
  add_one <- function(df, group_keys = character(0)) {
    if (is.null(df) || nrow(df) == 0 || !'weighted_etr' %in% names(df)) return(df)
    bl_date <- if (any(df$date == baseline_date)) {
      baseline_date
    } else {
      m <- min(df$date)
      message('  weighted_etr_new: no ', baseline_date,
              ' baseline row present; using earliest date ', m, ' instead')
      m
    }
    if (length(group_keys) == 0) {
      bl <- df$weighted_etr[df$date == bl_date][1]
      df$weighted_etr_new <- df$weighted_etr - bl
    } else {
      base_tbl <- df %>%
        filter(date == bl_date) %>%
        select(all_of(group_keys), .etr_base_2025 = weighted_etr) %>%
        distinct()
      df <- df %>%
        left_join(base_tbl, by = group_keys) %>%
        mutate(weighted_etr_new = weighted_etr - coalesce(.etr_base_2025, 0)) %>%
        select(-.etr_base_2025)
    }
    df %>% relocate(weighted_etr_new, .after = weighted_etr)
  }

  daily$daily_overall  <- add_one(daily$daily_overall)
  daily$daily_by_country <- add_one(daily$daily_by_country, 'country')
  if (!is.null(daily$daily_by_category)) {
    daily$daily_by_category <- add_one(daily$daily_by_category, 'gtap_code')
  }
  daily
}


#' Save daily series outputs to disk
#'
#' @param daily List from build_daily_aggregates()
#' @param out_dir Output directory
save_daily_outputs <- function(daily, out_dir = series_section_dir('daily')) {
  ensure_dir(out_dir)

  # Attach weighted_etr_new (excess over the Jan-1-2025 baseline) here, the single
  # choke point every fully-assembled series passes through (legacy combined,
  # array-part bind, and streaming all route here). Per-snapshot part builders
  # save their own RDS directly and never reach this, which is correct — the
  # column is cross-revision and undefined for a single-snapshot frame.
  daily <- add_weighted_etr_new(daily)

  write_csv(daily$daily_overall, file.path(out_dir, 'daily_overall.csv'))

  # Add country names to by-country output
  census_codes_path <- here('resources', 'census_codes.csv')
  if (file.exists(census_codes_path)) {
    census_codes <- read_csv(census_codes_path, col_types = cols(.default = col_character())) %>%
      rename(country = Code, country_name = Name)
    partner_path <- here('resources', 'country_partner_mapping.csv')
    if (file.exists(partner_path)) {
      partners <- read_csv(partner_path, col_types = cols(.default = col_character())) %>%
        select(cty_code, partner) %>%
        rename(country = cty_code, country_abbr = partner)
      census_codes <- census_codes %>% left_join(partners, by = 'country')
    }
    daily$daily_by_country <- daily$daily_by_country %>%
      left_join(census_codes, by = 'country') %>%
      relocate(country_name, .after = country) %>%
      relocate(any_of('country_abbr'), .after = country_name)
  }
  write_csv(daily$daily_by_country, file.path(out_dir, 'daily_by_country.csv'))
  write_csv(daily$daily_by_authority, file.path(out_dir, 'daily_by_authority.csv'))
  has_category <- !is.null(daily$daily_by_category) && nrow(daily$daily_by_category) > 0
  if (has_category) {
    write_csv(daily$daily_by_category, file.path(out_dir, 'daily_by_category.csv'))
  }
  has_hs <- !is.null(daily$daily_by_hs) && nrow(daily$daily_by_hs) > 0
  if (has_hs) {
    write_csv(daily$daily_by_hs, file.path(out_dir, 'daily_by_hs.csv'))
  }
  saveRDS(daily, file.path(out_dir, 'daily_aggregates.rds'))

  # Parquet siblings for cross-language consumers (skipped silently when
  # arrow isn't installed). See helpers.R::write_parquet_if_arrow.
  write_parquet_if_arrow(daily$daily_overall,    file.path(out_dir, 'daily_overall.csv'))
  write_parquet_if_arrow(daily$daily_by_country, file.path(out_dir, 'daily_by_country.csv'))
  write_parquet_if_arrow(daily$daily_by_authority, file.path(out_dir, 'daily_by_authority.csv'))
  if (has_category) {
    write_parquet_if_arrow(daily$daily_by_category, file.path(out_dir, 'daily_by_category.csv'))
  }
  if (has_hs) {
    write_parquet_if_arrow(daily$daily_by_hs, file.path(out_dir, 'daily_by_hs.csv'))
  }

  # --- Excel workbook (overwrite individual sheets, preserve workbook) ---
  xlsx_path <- file.path(out_dir, 'daily_workbook.xlsx')
  if (requireNamespace('openxlsx', quietly = TRUE)) {
    save_daily_workbook(daily, xlsx_path)
  }

  message('Outputs saved to: ', out_dir)
  message('  daily_overall.csv: ', nrow(daily$daily_overall), ' rows')
  message('  daily_by_country.csv: ', nrow(daily$daily_by_country), ' rows')
  message('  daily_by_authority.csv: ', nrow(daily$daily_by_authority), ' rows')
  if (has_category) {
    message('  daily_by_category.csv: ', nrow(daily$daily_by_category), ' rows')
  }
  if (has_hs) {
    message('  daily_by_hs.csv: ', nrow(daily$daily_by_hs), ' rows')
  }
  message('  daily_aggregates.rds')
  if (requireNamespace('openxlsx', quietly = TRUE)) message('  daily_workbook.xlsx')
}


#' Build authoritative snapshot intervals without loading snapshot contents.
#'
#' Shared by the streaming path and the array-task part cache so both validate
#' against the same final interval table.
build_snapshot_intervals_for_daily <- function(snapshot_dir, rev_dates,
                                               policy_params = NULL) {
  horizon_end <- as.Date(
    if (!is.null(policy_params)) policy_params$SERIES_HORIZON_END %||% Sys.Date() else Sys.Date()
  )
  snaps <- list.files(snapshot_dir, pattern = '^snapshot_.*\\.rds$')
  revs_built <- sub('^snapshot_(.*)\\.rds$', '\\1', snaps)
  rev_intervals <- rev_dates %>%
    filter(revision %in% revs_built) %>%
    arrange(effective_date) %>%
    mutate(valid_from = effective_date,
           valid_until = lead(effective_date) - 1) %>%
    mutate(valid_until = if_else(is.na(valid_until), horizon_end, valid_until)) %>%
    select(revision, valid_from, valid_until)
  if (nrow(rev_intervals) == 0) stop('No snapshots found in ', snapshot_dir)
  rev_intervals
}


daily_part_path <- function(snapshot_dir, revision) {
  file.path(snapshot_dir, paste0('daily_part_', revision, '.rds'))
}


#' Build and save one array-task daily aggregate part from an in-memory snapshot.
#'
#' The output is intentionally small compared with the snapshot and is safe to
#' bind in gather. It is valid only for the stored interval and weight mode; the
#' gather path verifies both before using it.
# The daily-part schema. v2 adds the per-interval weight fingerprint
# (metadata$weight_metadata) and interval-local weights via imports_fn; v1 parts
# are rejected by load_daily_parts_if_complete() and must be rebuilt.
# v3 adds the Section 338 authority decomposition (mean_s338 / etr_s338) and
# folds etr_s338 into the etr_base residual; v2 parts lack those columns and
# carry a stale etr_base, so a mixed gather would produce NA s338 columns and a
# broken etr_base identity — rejecting v2 forces a rebuild.
DAILY_PART_SCHEMA_VERSION <- 3L

write_daily_part_for_snapshot <- function(snapshot, revision, valid_from, valid_until,
                                          output_dir, imports = NULL,
                                          imports_fn = NULL, hts_as_of_date = NULL,
                                          policy_params = NULL,
                                          stacking_method = 'mutual_exclusion') {
  if (!is.null(imports) && !is.null(imports_fn)) {
    stop('write_daily_part_for_snapshot: pass at most one of imports / imports_fn.',
         call. = FALSE)
  }
  weight_mode <- if (is.null(imports) && is.null(imports_fn)) 'unweighted' else 'weighted'

  snapshot <- enforce_rate_schema(snapshot)
  snapshot$revision <- revision
  snapshot$valid_from <- as.Date(valid_from)
  snapshot$valid_until <- as.Date(valid_until)

  hts_as_of_dates <- NULL
  if (!is.null(imports_fn)) {
    if (is.null(hts_as_of_date)) {
      stop('write_daily_part_for_snapshot: imports_fn requires hts_as_of_date ',
           '(the revision\'s RAW HTS-identity date).', call. = FALSE)
    }
    hts_as_of_dates <- setNames(list(as.Date(hts_as_of_date)), as.character(revision))
  }

  daily <- suppressMessages(
    build_daily_aggregates(snapshot, imports = imports, imports_fn = imports_fn,
                           policy_params = policy_params,
                           stacking_method = stacking_method,
                           hts_as_of_dates = hts_as_of_dates)
  )

  # Weight fingerprint — recorded only for the imports_fn (per-interval) path.
  # A static `imports` tibble has no dated provenance to fingerprint, and an
  # unweighted part has no weights, so both carry weight_metadata = NULL and the
  # loader validates them without weight hashes.
  weight_metadata <- NULL
  if (!is.null(imports_fn)) {
    ws <- daily$weight_stats[[as.character(revision)]]
    if (is.null(ws) || is.null(ws$fingerprint)) {
      stop('write_daily_part_for_snapshot: imports_fn produced no weight ',
           'fingerprint for revision ', revision, '.', call. = FALSE)
    }
    weight_metadata <- ws$fingerprint
  }

  part <- list(
    schema_version = DAILY_PART_SCHEMA_VERSION,
    metadata = list(
      revision = revision,
      valid_from = as.Date(valid_from),
      valid_until = as.Date(valid_until),
      weight_mode = weight_mode,
      weight_metadata = weight_metadata,
      n_snapshot_rows = nrow(snapshot),
      created_at = Sys.time()
    ),
    daily_overall = daily$daily_overall,
    daily_by_country = daily$daily_by_country,
    daily_by_authority = daily$daily_by_authority,
    daily_by_category = daily$daily_by_category,
    daily_by_hs = daily$daily_by_hs
  )
  path <- daily_part_path(output_dir, revision)
  saveRDS(part, path)
  message('  Wrote daily aggregate part: ', path, ' (', weight_mode, ')')
  invisible(path)
}


#' Do a stored part's weight hashes match the expected weight context?
#'
#' `expected` is list(shared = <shared fingerprint from make_interval_weights_fn>,
#' hts_as_of_dates = named revision -> Date). Returns TRUE/FALSE. The
#' target_code_hash is NOT re-checked here (that would require re-reading the
#' snapshot, defeating the cache); the caller's part-vs-snapshot mtime check
#' catches a changed code universe.
daily_weight_fingerprint_matches <- function(stored, expected, revision) {
  if (is.null(stored)) return(FALSE)
  sh <- expected$shared
  keys <- c('method', 'mapper_schema_version', 'base_sha256', 'shares_sha256',
            'crosswalk_sha256', 'overrides_sha256')
  for (k in keys) {
    if (!identical(as.character(stored[[k]]), as.character(sh[[k]]))) return(FALSE)
  }
  exp_asof <- expected$hts_as_of_dates[[as.character(revision)]]
  if (is.null(exp_asof)) return(FALSE)
  identical(as.character(stored$hts_as_of_date), as.character(as.Date(exp_asof)))
}

#' Bind precomputed array-task daily parts if they exactly match final intervals.
#'
#' Returns NULL when the cache is incomplete, stale, the wrong weight mode, an old
#' schema version, or (for weighted parts with a `weight_context`) a mismatched
#' weight fingerprint. Callers then fall back to the snapshot-streaming path.
#'
#' @param weight_context Optional list(shared, hts_as_of_dates) from a
#'   make_interval_weights_fn() provider (`attr(fn, 'shared_fingerprint')` +
#'   the per-revision raw HTS-identity dates). When supplied and
#'   weight_mode == 'weighted', each part's recorded weight fingerprint must
#'   match it. NULL skips fingerprint validation (static / unweighted paths).
load_daily_parts_if_complete <- function(snapshot_dir, rev_dates,
                                         policy_params = NULL,
                                         weight_mode = c('weighted', 'unweighted'),
                                         weight_context = NULL) {
  weight_mode <- match.arg(weight_mode)
  rev_intervals <- build_snapshot_intervals_for_daily(snapshot_dir, rev_dates, policy_params)

  parts <- vector('list', nrow(rev_intervals))
  for (i in seq_len(nrow(rev_intervals))) {
    row <- rev_intervals[i, ]
    path <- daily_part_path(snapshot_dir, row$revision)
    snapshot_path <- file.path(snapshot_dir, paste0('snapshot_', row$revision, '.rds'))
    if (!file.exists(path)) {
      message('Daily part cache incomplete: missing ', basename(path))
      return(NULL)
    }
    if (!file.exists(snapshot_path) || file.info(path)$mtime < file.info(snapshot_path)$mtime) {
      message('Daily part cache stale for ', row$revision,
              ' (part older than snapshot)')
      return(NULL)
    }
    part <- tryCatch(readRDS(path), error = function(e) {
      message('Daily part cache unreadable: ', basename(path), ': ', conditionMessage(e))
      NULL
    })
    if (is.null(part) || !is.list(part) || is.null(part$metadata)) return(NULL)

    # Reject stale schema versions (v1 has no weight fingerprint) — rebuild.
    if (!identical(as.integer(part$schema_version %||% 1L), DAILY_PART_SCHEMA_VERSION)) {
      message('Daily part cache stale for ', row$revision, ' (schema v',
              part$schema_version %||% 1L, ' != v', DAILY_PART_SCHEMA_VERSION, ')')
      return(NULL)
    }

    meta <- part$metadata
    valid <- identical(as.character(meta$revision), as.character(row$revision)) &&
      identical(as.Date(meta$valid_from), as.Date(row$valid_from)) &&
      identical(as.Date(meta$valid_until), as.Date(row$valid_until)) &&
      identical(as.character(meta$weight_mode), weight_mode)
    if (!valid) {
      message('Daily part cache stale for ', row$revision,
              ' (expected ', row$valid_from, '..', row$valid_until,
              ', ', weight_mode, ')')
      return(NULL)
    }

    # Weight-fingerprint validation for the weighted per-interval path.
    if (weight_mode == 'weighted' && !is.null(weight_context)) {
      if (!daily_weight_fingerprint_matches(meta$weight_metadata, weight_context,
                                            row$revision)) {
        message('Daily part cache stale for ', row$revision,
                ' (weight fingerprint mismatch — inputs or hts_as_of_date changed)')
        return(NULL)
      }
    }
    parts[[i]] <- part
  }

  message('Using ', length(parts), ' precomputed daily aggregate part(s) from ', snapshot_dir)
  list(
    daily_overall      = bind_rows(lapply(parts, `[[`, 'daily_overall')),
    daily_by_country   = bind_rows(lapply(parts, `[[`, 'daily_by_country')),
    daily_by_authority = bind_rows(lapply(parts, `[[`, 'daily_by_authority')),
    daily_by_category  = bind_rows(lapply(parts, `[[`, 'daily_by_category')),
    daily_by_hs        = bind_rows(lapply(parts, `[[`, 'daily_by_hs'))
  )
}


#' Run full daily series pipeline
#'
#' Loads import weights (if not provided), builds daily aggregates, saves outputs.
#' Called by 00_build_timeseries.R post-build and usable standalone.
#'
#' @param ts Timeseries tibble with valid_from/valid_until
#' @param imports Optional pre-loaded import weights; loaded if NULL
#' @param policy_params Optional policy params list (from load_policy_params())
#' @return Daily aggregates (invisible)
#' Build the full daily aggregates WITHOUT materializing the combined timeseries.
#'
#' Codex/perf Phase 1: the giant ~194.5M-row rate_timeseries.rds (~48 GB in RAM)
#' is never needed for the daily math — each revision's aggregate depends only on
#' that revision's own snapshot. This reads ONE snapshot at a time, runs the exact
#' same build_daily_aggregates() on it, and binds the per-revision daily outputs.
#' Output is identical to build_daily_aggregates(combined_ts) (same function, same
#' splits/expansion/etr_base, just grouped by revision) but peak memory is one
#' snapshot (~1.2 GB) instead of the whole stack.
#'
#' @param snapshot_dir Directory of snapshot_<rev>.rds files
#' @param rev_dates Revision-date table (from load_revision_dates())
#' @param imports Static import weights tibble (or NULL). Mutually exclusive with
#'   imports_fn.
#' @param imports_fn Per-interval weight provider (see build_daily_aggregates).
#'   Requires hts_as_of_dates.
#' @param hts_as_of_dates Named revision -> raw HTS-identity Date (imports_fn mode).
#' @param policy_params Policy params list (SERIES_HORIZON_END drives the tip interval)
build_daily_aggregates_streaming <- function(snapshot_dir, rev_dates,
                                              imports = NULL, imports_fn = NULL,
                                              hts_as_of_dates = NULL,
                                              policy_params = NULL,
                                              cores = NULL) {
  # Same interval logic assemble_timeseries() uses (00_build_timeseries.R) so the
  # tip extends to the horizon and boundaries match the combined-ts path exactly.
  rev_intervals <- build_snapshot_intervals_for_daily(snapshot_dir, rev_dates, policy_params)

  # Revisions are independent — fan the per-snapshot work across cores. Default
  # from TARIFF_DAILY_CORES, else the Slurm allocation, else serial. Each worker
  # holds one snapshot (~1.2 GB), so cores are bounded by node memory, not CPU.
  if (is.null(cores)) {
    cores <- suppressWarnings(as.integer(Sys.getenv('TARIFF_DAILY_CORES', unset = NA)))
    if (is.na(cores)) cores <- suppressWarnings(as.integer(Sys.getenv('SLURM_CPUS_PER_TASK', unset = NA)))
    if (is.na(cores) || cores < 1L) cores <- 1L
  }
  n <- nrow(rev_intervals)
  message('Streaming daily aggregates over ', n,
          ' revisions (per-snapshot; no combined timeseries; cores=', cores, ')')

  process_one <- function(i) {
    rev_id <- rev_intervals$revision[i]
    snap <- readRDS(file.path(snapshot_dir, paste0('snapshot_', rev_id, '.rds'))) %>%
      enforce_rate_schema()
    # Attach the AUTHORITATIVE interval (recomputed from rev_dates, exactly as
    # assemble_timeseries does — do NOT trust the snapshot's stored valid_*).
    snap$revision    <- rev_id
    snap$valid_from  <- rev_intervals$valid_from[i]
    snap$valid_until <- rev_intervals$valid_until[i]
    suppressMessages(
      build_daily_aggregates(snap, imports = imports, imports_fn = imports_fn,
                             policy_params = policy_params,
                             hts_as_of_dates = hts_as_of_dates))
  }

  results <- if (cores > 1L) {
    # mc.preschedule = FALSE: dynamic dispatch, since the ANNEX revisions are far
    # heavier than the rest — keeps all cores busy instead of one straggler.
    parallel::mclapply(seq_len(n), process_one, mc.cores = cores, mc.preschedule = FALSE)
  } else {
    lapply(seq_len(n), process_one)
  }
  # mclapply does NOT stop on worker failure: a CRASHED worker returns a
  # try-error, and a worker KILLED by the OS (OOM / signal) returns NULL. Either
  # way the revision would silently vanish from the bind_rows below and shorten
  # the daily series. Guard against BOTH so a dropped revision fails LOUDLY —
  # never a silently-truncated daily series.
  if (length(results) != n) {
    stop('streaming daily: expected ', n, ' results, got ', length(results),
         ' — a worker was lost. Lower TARIFF_DAILY_CORES or raise job memory.')
  }
  bad <- !vapply(results, function(r) is.list(r) && !is.null(r[['daily_overall']]),
                 logical(1))
  if (any(bad)) {
    why <- vapply(results[bad], function(r)
      if (inherits(r, 'try-error')) as.character(r) else '<killed: NULL result (OOM/signal)>',
      character(1))
    stop('streaming daily LOST ', sum(bad), ' of ', n, ' revision(s): ',
         paste(rev_intervals$revision[bad], collapse = ', '), '\n',
         paste(why, collapse = '\n'),
         '\nLower TARIFF_DAILY_CORES or raise job memory.')
  }

  list(
    daily_overall      = bind_rows(lapply(results, `[[`, 'daily_overall')),
    daily_by_country   = bind_rows(lapply(results, `[[`, 'daily_by_country')),
    daily_by_authority = bind_rows(lapply(results, `[[`, 'daily_by_authority')),
    daily_by_category  = bind_rows(lapply(results, `[[`, 'daily_by_category')),
    daily_by_hs        = bind_rows(lapply(results, `[[`, 'daily_by_hs'))
  )
}

#' Run the daily series and write outputs.
#'
#' Two input modes:
#'   - legacy:    pass `ts` (the combined timeseries) — filters it per revision.
#'   - streaming: pass `snapshot_dir` (+ `rev_dates`) — reads one snapshot at a
#'     time, never building the 48 GB combined panel. Identical outputs, far less
#'     memory/time. This is the preferred path for builds and the parity gate.
run_daily_series <- function(ts = NULL, imports = NULL, imports_fn = NULL,
                             hts_as_of_dates = NULL, weight_context = NULL,
                             policy_params = NULL,
                             snapshot_dir = NULL, rev_dates = NULL,
                             weight_mode = NULL) {
  # Back-compat: when a caller supplies neither a static tibble nor a provider
  # and hasn't opted out, load the legacy static weights (weight_method=static).
  if (is.null(imports) && is.null(imports_fn) && !identical(weight_mode, 'unweighted')) {
    imports <- load_import_weights(weight_mode = weight_mode)
  }
  has_weights <- !is.null(imports) || !is.null(imports_fn)
  if (!is.null(snapshot_dir)) {
    if (is.null(rev_dates)) rev_dates <- load_revision_dates()
    weight_mode <- if (has_weights) 'weighted' else 'unweighted'
    daily <- load_daily_parts_if_complete(snapshot_dir, rev_dates,
                                          policy_params = policy_params,
                                          weight_mode = weight_mode,
                                          weight_context = weight_context)
    if (is.null(daily)) {
      stop('Daily aggregate parts are missing or stale for ', snapshot_dir,
           '. Re-run the array build so every timeline row writes a current ',
           weight_mode, ' daily_part_<revision>.rds.')
    }
  } else {
    daily <- build_daily_aggregates(ts, imports = imports, imports_fn = imports_fn,
                                    hts_as_of_dates = hts_as_of_dates,
                                    policy_params = policy_params)
  }
  save_daily_outputs(daily)
  return(invisible(daily))
}


# =============================================================================
# Alternative Daily Series
# =============================================================================

#' Save a single alternative daily output to output/alternative/
#'
#' @param daily_overall Daily overall tibble (from build_daily_aggregates)
#' @param variant Character variant name (e.g., 'no_ieepa')
#' @param out_dir Output directory
save_alternative_output <- function(daily_overall, variant,
                                     agg_by_authority = NULL,
                                     agg_by_country = NULL,
                                     agg_by_category = NULL,
                                     out_dir = scenario_dir(variant)) {
  ensure_dir(out_dir)
  daily_overall <- daily_overall %>% mutate(variant = variant)
  fname <- 'daily_overall.csv'
  write_csv(daily_overall, file.path(out_dir, fname))
  message('  Saved: ', fname, ' (', nrow(daily_overall), ' rows)')

  # By-authority: interval-encoded (no daily expansion needed — small)
  if (!is.null(agg_by_authority) && nrow(agg_by_authority) > 0) {
    agg_by_authority <- agg_by_authority %>% mutate(variant = variant)
    fname_auth <- 'by_authority.csv'
    write_csv(agg_by_authority, file.path(out_dir, fname_auth))
    message('  Saved: ', fname_auth, ' (', nrow(agg_by_authority), ' rows)')
  }

  # By-country: interval-encoded, trimmed columns (keeps size manageable)
  if (!is.null(agg_by_country) && nrow(agg_by_country) > 0) {
    # Add country names if not already present
    if (!'country_name' %in% names(agg_by_country)) {
      census_path <- here('resources', 'census_codes.csv')
      if (file.exists(census_path)) {
        cnames <- read_csv(census_path, col_types = cols(.default = col_character())) %>%
          select(country = Code, country_name = Name)
        partner_path <- here('resources', 'country_partner_mapping.csv')
        if (file.exists(partner_path)) {
          partners <- read_csv(partner_path, col_types = cols(.default = col_character())) %>%
            select(country = cty_code, country_abbr = partner)
          cnames <- cnames %>% left_join(partners, by = 'country')
        }
        agg_by_country <- agg_by_country %>%
          left_join(cnames, by = 'country', relationship = 'many-to-one')
      }
    }
    trimmed <- agg_by_country %>%
      select(any_of(c('country', 'country_name', 'country_abbr',
                       'revision', 'valid_from', 'valid_until',
                       'mean_additional_exposed', 'mean_total_exposed',
                       'weighted_etr'))) %>%
      mutate(variant = variant)
    fname_cty <- 'by_country.csv'
    write_csv(trimmed, file.path(out_dir, fname_cty))
    message('  Saved: ', fname_cty, ' (', nrow(trimmed), ' rows)')
  }

  # By-category (GTAP sector): interval-encoded
  if (!is.null(agg_by_category) && nrow(agg_by_category) > 0) {
    trimmed_cat <- agg_by_category %>%
      select(any_of(c('gtap_code', 'revision', 'valid_from', 'valid_until',
                       'mean_additional_exposed', 'mean_total_exposed',
                       'weighted_etr', 'n_products_present'))) %>%
      mutate(variant = variant)
    fname_cat <- 'by_category.csv'
    write_csv(trimmed_cat, file.path(out_dir, fname_cat))
    message('  Saved: ', fname_cat, ' (', nrow(trimmed_cat), ' rows)')
  }
}


# build_rev_intervals() now lives in src/model/rate_schema.R (sourced transitively via
# helpers.R) so the publish layer can reuse the authoritative interval encoding
# without sourcing this daily-series / calculator module.


#' Aggregate a set of per-revision snapshots into daily + interval parts
#'
#' Loads one snapshot at a time, attaches interval columns, optionally applies
#' a transform (e.g., a scenario that zeros authority columns), builds daily
#' aggregates, and stores the parts for later bind_rows. Avoids materializing
#' the full combined timeseries (~185M rows), which is the source of OOM in
#' the post-build scenario path.
#'
#' @param snapshot_dir Directory containing snapshot_<rev>.rds files
#' @param rev_intervals Tibble with revision, valid_from, valid_until
#' @param imports Import weights tibble (or NULL)
#' @param policy_params Policy params list passed to build_daily_aggregates
#' @param transform Optional function(snapshot) -> snapshot applied before
#'   aggregation. Use to zero authorities / re-stack for a scenario.
#' @param progress_every Log progress every N revisions (default 10)
#' @return List with daily_overall, agg_by_authority, agg_by_country (each
#'   is bind_rows of the per-revision parts)
aggregate_snapshots_per_revision <- function(snapshot_dir, rev_intervals,
                                              imports = NULL,
                                              policy_params = NULL,
                                              transform = NULL,
                                              progress_every = 10L) {
  # rev_intervals may carry multiple sub-rows per revision (e.g. when a caller
  # splits an interval at a schedule boundary); each sub-row is processed
  # independently with its own valid_from passed to the transform. Snapshots are
  # loaded at most once per revision.
  n_subs <- nrow(rev_intervals)
  daily_parts <- vector('list', n_subs)
  auth_parts <- vector('list', n_subs)
  country_parts <- vector('list', n_subs)
  category_parts <- vector('list', n_subs)

  # Detect whether transform expects a `valid_from` argument (new patch-aware
  # signature) vs the legacy 1-arg form. Lets both coexist during rollout.
  transform_takes_valid_from <- FALSE
  if (!is.null(transform)) {
    transform_takes_valid_from <- 'valid_from' %in% names(formals(transform))
  }

  cached_snapshot <- NULL
  cached_rev <- NULL

  for (i in seq_len(n_subs)) {
    rev_id <- rev_intervals$revision[i]
    sub_from <- rev_intervals$valid_from[i]
    sub_until <- rev_intervals$valid_until[i]

    snap_path <- file.path(snapshot_dir, paste0('snapshot_', rev_id, '.rds'))
    if (!file.exists(snap_path)) {
      message('    SKIP ', rev_id, ': snapshot not found')
      next
    }

    if (is.null(cached_rev) || cached_rev != rev_id) {
      cached_snapshot <- readRDS(snap_path) %>% enforce_rate_schema()
      cached_rev <- rev_id
    }

    snapshot <- cached_snapshot
    snapshot$valid_from <- sub_from
    snapshot$valid_until <- sub_until
    snapshot$revision <- rev_id

    if (!is.null(transform)) {
      snapshot <- if (transform_takes_valid_from) {
        transform(snapshot, valid_from = sub_from)
      } else {
        transform(snapshot)
      }
    }

    daily <- suppressMessages(
      build_daily_aggregates(snapshot, imports = imports, policy_params = policy_params)
    )
    daily_parts[[i]] <- daily$daily_overall
    auth_parts[[i]] <- daily$agg_by_authority
    country_parts[[i]] <- daily$agg_by_country
    category_parts[[i]] <- daily$agg_by_category
    rm(snapshot, daily)
    gc()

    if (i %% progress_every == 0 || i == n_subs) {
      message('    ', i, '/', n_subs, ' sub-intervals aggregated')
    }
  }

  list(
    daily_overall = bind_rows(daily_parts),
    agg_by_authority = bind_rows(auth_parts),
    agg_by_country = bind_rows(country_parts),
    agg_by_category = bind_rows(category_parts)
  )
}


#' Build alternative timeseries with modified policy params (rebuild variant)
#'
#' Re-runs the full rate calculation loop (all revisions) with a modified
#' policy_params list, then builds daily aggregates. This is slow — only
#' called when --with-alternatives is passed.
#'
#' Temporarily overrides the module-level .pp in 06_calculate_rates.R's
#' environment, then restores it.
#'
#' @param pp_override Modified policy_params list
#' @param variant_name Character variant name
#' @param imports Import weights tibble (or NULL)
#' @param archive_dir HTS archive directory
#' @param revision_dates_path Path to revision_dates.csv
#' @param census_codes_path Path to census_codes.csv
#' @return Daily overall tibble (invisibly)
build_alternative_timeseries <- function(pp_override, variant_name, imports = NULL,
                                          archive_dir = here('data', 'hts_archives'),
                                          revision_dates_path = here('config', 'revision_dates.csv'),
                                          census_codes_path = here('resources', 'census_codes.csv'),
                                          policy_params = NULL,
                                          snapshot_out_dir = NULL,
                                          allow_partial = FALSE) {

  message('\n  Building alternative timeseries: ', variant_name)

  # Ensure pipeline components are sourced (needed for standalone use)
  if (!exists('calculate_rates_for_revision', mode = 'function')) {
    source(here('src', 'pipeline', '03_parse_chapter99.R'))
    source(here('src', 'pipeline', '04_parse_products.R'))
    source(here('src', 'pipeline', '05_parse_policy_params.R'))
    source(here('src', 'pipeline', '06_calculate_rates.R'))
    source(here('src', 'model', 'authority_spec.R'))
    source(here('src', 'model', 'authority_adapter.R'))
  }
  # Ensure the AuthoritySpec adapter is present even when the pipeline above was
  # already sourced by the caller (the `if` block only fires for standalone use).
  if (!exists('build_authority_specs', mode = 'function')) {
    source(here('src', 'model', 'authority_spec.R'))
    source(here('src', 'model', 'authority_adapter.R'))
  }

  # Save original .pp and swap in override
  calc_env <- environment(calculate_rates_for_revision)
  original_pp <- calc_env$.pp
  calc_env$.pp <- pp_override
  on.exit(calc_env$.pp <- original_pp, add = TRUE)

  # Load revision dates and country codes
  rev_dates <- load_revision_dates(revision_dates_path)
  census_codes <- read_csv(census_codes_path, col_types = cols(.default = col_character()))
  countries <- census_codes$Code
  country_lookup <- build_country_lookup(census_codes_path)

  all_revisions <- rev_dates$revision
  available <- get_available_revisions_all_years(all_revisions, archive_dir)
  revisions_to_process <- all_revisions[all_revisions %in% available]

  # Per-revision snapshots: spill to tempdir (default) or persist to a caller-
  # specified directory (when snapshot_out_dir is non-null — used by the scenario
  # harness to write to data/timeseries/<scenario>/).
  if (is.null(snapshot_out_dir)) {
    tmp_dir <- tempfile(paste0('alt_snapshots_', variant_name, '_'))
    dir.create(tmp_dir)
    on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)
  } else {
    tmp_dir <- snapshot_out_dir
    dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
    message('  Persisting per-revision snapshots to: ', tmp_dir)
  }

  n_saved <- 0L
  for (rev_id in revisions_to_process) {
    rev_info <- rev_dates %>% filter(revision == rev_id)
    eff_date <- rev_info$effective_date

    tryCatch({
      json_path <- resolve_json_path(rev_id, archive_dir)
      hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)
      ch99_data <- parse_chapter99(json_path)
      products <- parse_products(json_path)
      ieepa_rates <- extract_ieepa_rates(hts_raw, country_lookup, effective_date = eff_date)
      fentanyl_rates <- extract_ieepa_fentanyl_rates(hts_raw, country_lookup, effective_date = eff_date)
      s232_rates <- extract_section232_rates(filter_active_ch99(ch99_data, as.Date(eff_date)),
                                             effective_date = eff_date, policy_params = pp_override)
      usmca <- extract_usmca_eligibility(hts_raw)

      # Phase 6f: AuthoritySpec path always on (specs = authoritative input).
      specs <- build_authority_specs(
        products, ch99_data, ieepa_rates, usmca,
        countries, rev_id, eff_date,
        s232_rates = s232_rates, fentanyl_rates = fentanyl_rates,
        policy_params = policy_params %||% pp_override
      )

      rates <- calculate_rates_for_revision(
        products, ch99_data, usmca,
        countries, rev_id, eff_date,
        specs = specs,
        policy_params = policy_params %||% pp_override
      )
      saveRDS(rates, file.path(tmp_dir, paste0('snapshot_', rev_id, '.rds')))
      n_saved <- n_saved + 1L
      rm(rates, hts_raw, ch99_data, products, ieepa_rates,
         fentanyl_rates, s232_rates, usmca, specs)
      gc()
    }, error = function(e) {
      message('    SKIP ', rev_id, ': ', conditionMessage(e))
    })
  }

  if (n_saved == 0L) {
    warning('No snapshots built for variant: ', variant_name)
    return(invisible(tibble()))
  }

  # Build revision intervals from saved snapshots (without loading data)
  snap_files <- list.files(tmp_dir, pattern = '^snapshot_.*\\.rds$', full.names = TRUE)
  revs_built <- sub('^snapshot_', '', tools::file_path_sans_ext(basename(snap_files)))

  # Completeness gate (Finding 3): a dropped *middle* revision is invisible
  # downstream — build_rev_intervals stretches the prior revision's window over
  # the gap, so a partial panel reads as policy stability. Fail loud unless the
  # caller explicitly opts into a partial build. When every expected revision
  # built (the normal case), `missing_revs` is empty and this is a no-op — no
  # stop(), no behavior change, byte-identical output.
  missing_revs <- setdiff(revisions_to_process, revs_built)
  if (length(missing_revs) > 0 && !allow_partial) {
    stop('build_alternative_timeseries(', variant_name, '): ',
         length(missing_revs), ' of ', length(revisions_to_process),
         ' expected revision(s) did not build (snapshot missing): ',
         paste(missing_revs, collapse = ', '),
         '. The published panel would silently stretch a neighbouring ',
         'revision over the gap. Pass allow_partial = TRUE to publish anyway.')
  }
  if (length(missing_revs) > 0) {
    warning('build_alternative_timeseries(', variant_name,
            '): publishing PARTIAL panel (allow_partial = TRUE) — ',
            length(missing_revs), ' revision(s) skipped: ',
            paste(missing_revs, collapse = ', '))
  }

  rev_intervals <- build_rev_intervals(
    revs_built, rev_dates,
    horizon_end = pp_override$SERIES_HORIZON_END %||% Sys.Date()
  )

  # Aggregate per-revision: load one snapshot at a time, aggregate, release.
  # Avoids holding the full combined timeseries (~185M rows) in memory.
  message('  Aggregating ', nrow(rev_intervals), ' revisions (per-revision mode)...')
  parts <- aggregate_snapshots_per_revision(
    snapshot_dir = tmp_dir,
    rev_intervals = rev_intervals,
    imports = imports,
    policy_params = pp_override
  )

  save_alternative_output(parts$daily_overall, variant_name,
                           agg_by_authority = parts$agg_by_authority,
                           agg_by_country = parts$agg_by_country,
                           agg_by_category = parts$agg_by_category)

  message('  Done: ', variant_name)
  return(invisible(parts$daily_overall))
}


#' Build the rebuild-alternatives registry — DEPRECATED
#'
#' Superseded by the declarative config/scenarios registry
#' (src/model/scenario_registry.R + per-scenario overlay.yaml); no production caller
#' remains. Kept ONLY so tests/test_scenario_registry.R can assert that each
#' migrated overlay produces the same policy_params as the historical closure.
#' DELETE this function (and that test's parity section) once the cluster
#' golden-diff gate confirms the migrated alternatives reproduce
#' output/alternative/*.csv (alternatives-unification Step 5, todo.md).
#'
#' @param pp Base policy_params (typically load_policy_params())
#' @return List of spec records: list(variant, pp_override)
build_rebuild_alt_registry <- function(pp) {
  list(
    # USMCA 2025 annual average (time-invariant counterfactual)
    list(variant = 'usmca_annual', pp_override = local({
      x <- pp
      x$USMCA_SHARES$year <- 2025
      x$USMCA_SHARES$mode <- 'annual'
      x
    })),
    # USMCA raw monthly shares (time-varying; tracks effective_date month,
    # falls back to most recent available monthly file when newer files
    # haven't been published yet).
    list(variant = 'usmca_monthly', pp_override = local({
      x <- pp
      x$USMCA_SHARES$mode <- 'monthly'
      x$USMCA_SHARES$year <- NULL
      x
    })),
    # USMCA 2024 shares (pre-tariff steady-state)
    list(variant = 'usmca_2024', pp_override = local({
      x <- pp
      x$USMCA_SHARES$year <- 2024
      x$USMCA_SHARES$mode <- 'annual'
      x
    })),
    # USMCA fixed latest month (Dec 2025 — post-behavioral-shift equilibrium)
    list(variant = 'usmca_dec2025', pp_override = local({
      x <- pp
      x$USMCA_SHARES$mode <- 'fixed_month'
      x$USMCA_SHARES$year <- 2025
      x$USMCA_SHARES$month <- 12
      x
    })),
    # Flat 100% metal content (upper bound: all derivative value is metal)
    list(variant = 'metal_flat', pp_override = local({
      x <- pp
      x$metal_content$method <- 'flat'
      x$metal_content$flat_share <- 1.0
      x
    })),
    # Nonzero duty-free treatment (sensitivity: exclude 0% MFN from IEEPA)
    list(variant = 'dutyfree_nonzero', pp_override = local({
      x <- pp
      x$ieepa_duty_free_treatment <- 'nonzero_base_only'
      x
    })),
    # Subdivision (r) calibration mid-point — sensitivity scenario for the
    # auto-parts certification + FTA-exempt fix. 0.5 / 0.5 mid-point: half of
    # EU/JP/KR subdiv-r imports filed under 9903.94.45/.55/.65 (15% floor),
    # half of KR subdiv-r imports FTA-qualifying under KORUS (rate_232 = 0).
    # See docs/s232/subdivision_r_calibration.md.
    list(variant = 'subdivision_r_mid', pp_override = local({
      x <- pp
      x$auto_parts_subdivision_r$certified_share <- 0.5
      x$auto_parts_subdivision_r$fta_exempt_shares$KR <- 0.5
      x
    }))
  )
}


#' Run all alternative daily series
#'
#' Alternatives unification (todo.md Phase 4): every runnable variant is a
#' named folder under config/scenarios/<name>/ (kind: alternative or
#' counterfactual; see src/model/scenario_registry.R). Each requested name becomes
#' one alt_runner() spec whose pp_override is load_policy_params(scenario =
#' name) — the same overlay merge the main build applies under TARIFF_SCENARIO
#' — and runs a full per-revision recalc + daily aggregation to
#' output/scenarios/<name>/.
#'
#' Selection: `alternatives` is the canonical selector ('all', 'alternatives',
#' 'counterfactuals', or a comma-list of names; see
#' resolve_alternatives_selector()). The legacy rebuild/rebuild_alts arguments
#' (--with-alternatives / --rebuild-alts) map onto it — rebuild = TRUE alone
#' means the 'alternatives' kind, matching the historical 7-variant set — so
#' existing wrappers (incl. the blog pipeline) keep working unchanged. Unknown
#' names now FAIL LOUD (Phase-0 policy) instead of being silently dropped.
#'
#' When alt_workers > 1, variants are dispatched concurrently via alt_runner()
#' in src/core/parallel.R. Default alt_workers = 1 preserves serial behavior.
#'
#' @param imports Import weights tibble (or NULL)
#' @param policy_params Baseline policy params (kept for API compatibility;
#'   per-variant params load from the registry)
#' @param rebuild Legacy flag (--with-alternatives); TRUE = kind 'alternative'
#' @param rebuild_alts Legacy character vector (--rebuild-alts) of names
#' @param alternatives Canonical selector (--alternatives); overrides legacy
#' @param alt_workers Concurrent workers for alternatives (>= 1)
#' @param use_policy_dates Date mode passed into each variant's
#'   load_policy_params(); MUST match the main build
#' @return Invisible NULL
run_alternative_series <- function(imports = NULL, policy_params = NULL,
                                    rebuild = FALSE,
                                    rebuild_alts = NULL,
                                    alternatives = NULL,
                                    alt_workers = 1L,
                                    use_policy_dates = TRUE) {

  message('\n', strrep('=', 70))
  message('ALTERNATIVE DAILY SERIES')
  message(strrep('=', 70))

  # --- Resolve which scenarios to run ---
  if (is.null(alternatives) && rebuild) {
    alternatives <- if (!is.null(rebuild_alts)) {
      paste(rebuild_alts, collapse = ',')
    } else {
      'alternatives'
    }
  }
  alt_names <- resolve_alternatives_selector(alternatives)

  if (length(alt_names) == 0L) {
    message('No alternatives requested (pass --alternatives <names|all|',
            'alternatives|counterfactuals>).')
    message(strrep('=', 70), '\n')
    return(invisible(NULL))
  }

  if (is.null(imports)) imports <- load_import_weights()

  alt_specs <- build_scenario_alt_specs(alt_names,
                                        use_policy_dates = use_policy_dates)

  if (!exists('alt_runner', mode = 'function')) {
    source(here('src', 'core', 'parallel.R'))
  }

  alt_workers <- max(1L, as.integer(alt_workers))
  message(sprintf(
    '\n  Running %d alternatives [%s] %s...',
    length(alt_specs),
    paste(alt_names, collapse = ', '),
    if (alt_workers > 1L) sprintf('(%d concurrent)', alt_workers) else '(sequential)'
  ))

  alt_log_dir <- here('output', 'logs', 'alternatives')
  results <- alt_runner(
    alt_specs,
    alt_workers = alt_workers,
    log_dir = alt_log_dir,
    imports = imports
  )

  statuses <- vapply(results, function(r) r$status %||% 'unknown', character(1))
  n_ok <- sum(statuses == 'ok')
  failed <- vapply(results[statuses != 'ok'], function(r) r$variant, character(1))
  message(sprintf('\n  Alternatives: %d/%d succeeded', n_ok, length(results)))
  if (length(failed) > 0L) {
    message('  Failed: ', paste(failed, collapse = ', '))
  }
  if (alt_workers > 1L) {
    message('  Per-alt logs: ', alt_log_dir)
  }

  message('\n', strrep('=', 70))
  message('ALTERNATIVE SERIES COMPLETE')
  message(strrep('=', 70), '\n')

  return(invisible(NULL))
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)
  source(here('src', 'core', 'helpers.R'))

  ts_path <- here('data', 'timeseries', 'rate_timeseries.rds')
  if (!file.exists(ts_path)) {
    stop('Timeseries not found: ', ts_path,
         '\nRun: Rscript src/pipeline/00_build_timeseries.R')
  }

  message('\n', strrep('=', 70))
  message('DAILY RATE SERIES BUILDER')
  message(strrep('=', 70))

  ts <- readRDS(ts_path)
  message('Loaded timeseries: ', nrow(ts), ' rows, ',
          n_distinct(ts$revision), ' revisions')

  if (!'valid_from' %in% names(ts)) {
    stop('Timeseries missing valid_from/valid_until columns.',
         '\nRebuild with: Rscript src/pipeline/00_build_timeseries.R')
  }

  pp <- load_policy_params()
  run_daily_series(ts, policy_params = pp)

  message('\n', strrep('=', 70))
  message('DAILY SERIES COMPLETE')
  message(strrep('=', 70), '\n')
}
