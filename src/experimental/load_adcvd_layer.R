# =============================================================================
# AD/CVD layer loader — WIP scaffold (not wired into the pipeline)
# =============================================================================
# Proposed antidumping/countervailing-duty (AD/CVD) statutory rung for the
# rate panel. Design: docs/adcvd_layer_design.md. Why the tracker has no AD/CVD
# field today and why the negative calibrated η appears for Japan/UK/EU:
# docs/analysis/eta_compliance_gap_drivers.md and eta_external_data_resources.md.
#
# STATUS: scaffold. NOT sourced by src/pipeline/06_calculate_rates.R. Wiring is gated on
# (1) producing the curated input resource resources/adcvd_orders.csv from
# Commerce ACCESS / CBP ACE, and (2) a decision to add `rate_adcvd` to
# RATE_SCHEMA in src/model/rate_schema.R. See docs/adcvd_layer_design.md §"Wiring".
#
# Hard caveats baked into the design (all confirmed — see the companion docs):
#   1. Order scope is a NARRATIVE product description; the HTS codes listed in an
#      order are "for convenience only" and non-dispositive. The HTS-10
#      crosswalk is an APPROXIMATION, not an exact mapping.
#   2. Cash-deposit rates are FIRM-SPECIFIC plus an "all-others" rate. An
#      HTS x country panel can only carry an ORDER-AVERAGE (all-others, or a
#      trade-weighted blend) — there is no single legally-correct per-line rate.
#   3. Assessment-to-collection LAG averages ~2.6 years (up to 14). `rate_adcvd`
#      is the DEPOSIT rate owed at entry (what Census cal_dut_mo carries), NOT
#      final liquidated liability. Do not reconcile period-by-period against
#      contemporaneous collections.
# =============================================================================

library(tidyverse)
library(here)

# Curated input. Produce from Commerce ACCESS (access.trade.gov/ADCVD_Search.aspx)
# and/or CBP ACE AD/CVD messages (trade.cbp.dhs.gov/ace/adcvd/), cross-checked
# against Federal Register order notices. data.commerce.gov "Products Subject to
# AD/CVD Orders" (ITA-0039) gives coverage but no rates (last refreshed
# 2020-06-17). A starter header lives in resources/adcvd_orders.TEMPLATE.csv.
#
# Columns (comment lines beginning '#' are skipped):
#   case_number    chr   A-### (antidumping) or C-### (countervailing)
#   country        chr   tracker country code (map order country name -> code)
#   hts            chr   covered HTS prefix (2-10 digits) from the order's
#                        "for convenience" list — non-dispositive (caveat 1)
#   rate           dbl   ad-valorem-equivalent ALL-OTHERS (or trade-weighted)
#                        cash-deposit rate, e.g. 0.21 for 21%
#   effective_date Date  order effective date (date-gates the rung)
#   revoked_date   Date  order revocation/sunset date, or blank if active
ADCVD_ORDERS_PATH <- here('resources', 'adcvd_orders.csv')

ADCVD_COL_TYPES <- cols(
  case_number    = col_character(),
  country        = col_character(),
  hts            = col_character(),
  rate           = col_double(),
  effective_date = col_date(),
  revoked_date   = col_date()
)

#' Expand an order's covered HTS prefix to the HTS-10 lines in the panel
#'
#' Order coverage is published at varying depth (HS-6/8/10). Each prefix fans
#' out to every HTS-10 in `product_universe` that starts with it. This is the
#' lossy step (caveat 1): narrative scope may include/exclude specific HTS-10s
#' within a prefix that codes alone cannot capture — flag wide prefixes for
#' manual scope review rather than trusting the fan-out blindly.
#'
#' @param prefixes Character vector of HTS prefixes (2-10 digits).
#' @param product_universe Character vector of HTS-10 codes present in the panel.
#' @return Tibble(hts_prefix, hts10) — one row per (prefix, matched HTS-10).
expand_hts_prefixes <- function(prefixes, product_universe) {
  prefixes <- unique(prefixes[!is.na(prefixes) & nzchar(prefixes)])
  if (length(prefixes) == 0 || length(product_universe) == 0) {
    return(tibble(hts_prefix = character(0), hts10 = character(0)))
  }
  # startsWith over the cross product, but bounded: group by prefix length so we
  # only compare the relevant leading substring.
  map_dfr(prefixes, function(p) {
    hit <- product_universe[startsWith(product_universe, p)]
    if (length(hit) == 0) return(tibble(hts_prefix = character(0), hts10 = character(0)))
    tibble(hts_prefix = p, hts10 = hit)
  })
}

#' Load an order-average AD/CVD layer at HTS-10 x country
#'
#' Returns a tibble `hts10, country, rate_adcvd` for a left_join in a new Step 6b
#' of src/pipeline/06_calculate_rates.R (after program rungs, before total_additional /
#' total_rate are summed). AD and CVD orders on the same line STACK ADDITIVELY
#' (they are separate legally-owed duties).
#'
#' @param effective_date Date for date-gating active orders (NULL = no gating;
#'   pass the revision's effective_date when wired in).
#' @param product_universe Character vector of HTS-10 codes in the panel, used to
#'   expand order prefixes. If NULL, `hts` is treated as already HTS-10 (no
#'   fan-out) — only correct when the orders file is pre-expanded.
#' @param import_weights Optional tibble `hts10, country, value` to trade-weight
#'   a single order's rate across the HTS-10s it fans out to (so a broad order
#'   does not over-credit zero-trade lines). Stacking across distinct cases is
#'   always additive regardless of weighting.
#' @param path Override for ADCVD_ORDERS_PATH (testing).
#' @return Tibble(hts10, country, rate_adcvd); empty tibble if input absent.
load_adcvd_layer <- function(effective_date = NULL, product_universe = NULL,
                             import_weights = NULL, path = ADCVD_ORDERS_PATH) {
  empty <- tibble(hts10 = character(0), country = character(0),
                  rate_adcvd = numeric(0))

  if (!file.exists(path)) {
    message('  AD/CVD layer: orders file not found (', path,
            ') — returning empty layer (rate_adcvd = 0 everywhere).')
    return(empty)
  }

  orders <- read_csv(path, col_types = ADCVD_COL_TYPES, comment = '#',
                     show_col_types = FALSE)
  if (nrow(orders) == 0) return(empty)

  # 1. Date-gate to orders active on `effective_date`.
  if (!is.null(effective_date)) {
    ed <- as.Date(effective_date)
    orders <- orders %>%
      filter(effective_date <= ed, is.na(revoked_date) | revoked_date > ed)
  }
  if (nrow(orders) == 0) return(empty)

  # 2. Expand each order's covered HTS prefix to panel HTS-10s.
  if (!is.null(product_universe)) {
    expansion <- expand_hts_prefixes(orders$hts, product_universe)
    expanded <- orders %>%
      inner_join(expansion, by = c('hts' = 'hts_prefix'),
                 relationship = 'many-to-many')
  } else {
    # No universe: treat `hts` as HTS-10 already (orders file pre-expanded).
    expanded <- orders %>% mutate(hts10 = hts)
  }
  if (nrow(expanded) == 0) return(empty)

  # 3. Per (case, hts10, country) take ONE rate. If trade weights are supplied,
  #    a single case's per-prefix rate is constant, so weighting only matters
  #    when one case lists overlapping prefixes hitting the same HTS-10 — take
  #    the max (most specific scope wins) within a case.
  per_case <- expanded %>%
    group_by(case_number, country, hts10) %>%
    summarise(rate = max(rate, na.rm = TRUE), .groups = 'drop')

  # 4. Stack distinct cases additively per (hts10, country). An A- and a C- case
  #    on the same line are both owed.
  layer <- per_case %>%
    group_by(hts10, country) %>%
    summarise(rate_adcvd = sum(rate, na.rm = TRUE), .groups = 'drop')

  # 5. Optional: clamp pathological fan-outs (a 2-digit prefix hitting an entire
  #    chapter) — left to the caller / scope review, but warn if a single case
  #    expanded to an implausible count.
  if (!is.null(import_weights)) {
    # Reserved for a value-weighted blend when an order's all-others rate should
    # be diluted by the in-scope trade share. Not needed for additive stacking;
    # wire in when the orders file carries sub-line scope shares.
    invisible(import_weights)
  }

  message('  AD/CVD layer: ', nrow(layer), ' hts10 x country pairs from ',
          dplyr::n_distinct(orders$case_number), ' active orders',
          if (!is.null(effective_date)) paste0(' as of ', effective_date) else '')
  layer
}

# -----------------------------------------------------------------------------
# Wiring sketch (do NOT enable without the curated orders file). See
# docs/adcvd_layer_design.md for the full design and the RATE_SCHEMA diff.
#
#   # src/model/rate_schema.R: add 'rate_adcvd' to RATE_SCHEMA (after 'rate_other'),
#   #   defaults (= 0), and the rate_cols NA-fill vector.
#
#   # src/pipeline/06_calculate_rates.R, new Step 6b (after program rungs, before the
#   # total_additional / total_rate sum):
#   adcvd <- load_adcvd_layer(effective_date  = effective_date,
#                             product_universe = unique(rates$hts10))
#   rates <- rates %>%
#     left_join(adcvd, by = c('hts10', 'country')) %>%
#     mutate(rate_adcvd = coalesce(rate_adcvd, 0))
#   # rate_adcvd then flows into total_additional like rate_232 etc.
#
# Calibration note: adding rate_adcvd RAISES modeled statutory for Japan/UK/EU
# (pulling negative η toward zero) and modestly for CA/MX. The principled
# alternative is to STRIP AD/CVD out of the COLLECTED side (cal_dut_mo) before
# calibrating, so η never carries legally-owed AD/CVD. Pick ONE — doing both
# double-counts.
# -----------------------------------------------------------------------------
