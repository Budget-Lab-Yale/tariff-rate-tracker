# =============================================================================
# resolved_programs.R — the resolved-program intermediate table (Phase 3b)
# =============================================================================
# STATUS: PROTOTYPE, DEFAULT-OFF. Gated by use_resolved_stacking() (see the
# call site at src/pipeline/06_calculate_rates.R). Baseline production uses the fast wide
# stacking path (stacking.R); this long-table path is bit-identical but ~7x the
# rows, kept for the scenario-mutation model. Not on the production hot path.
#
# A LONG representation of a resolved rate panel: one row per
# (hts10, country, authority) carrying the per-authority rate plus the metadata
# stacking needs. This is the substrate the scenario layer manipulates and the
# generic stacking reads; collapsing it back reproduces the wide rate_* + total_*
# snapshot (the persisted contract — INTERNAL-ONLY, downstream is unchanged).
#
# WHERE IT RUNS: at RESOLUTION time, once per revision (calculate_rates_for_
# revision step 8). NOT in the per-interval 09 aggregation loop — there the wide
# vectorized apply_stacking_rules() (stacking.R, Phase 3a) stays the fast path.
# Building the long table is ~7x the rows (~22s on a 4.7M-row revision vs ~1.5s
# wide), fine once-per-revision on the parallel array but catastrophic in a hot
# loop.
#
# DEFAULT OFF: use_resolved_stacking() gates it. Baseline production keeps the
# fast wide path (bit-identical). With the flag ON the resolved path reproduces
# the wide path within the floating-point floor (proto 2026_rev_1: max|diff|
# 1.11e-16 on 319/4.74M rows — the group-by sum reorders a few multi-authority
# stacks, so it is tolerance-equal, not bit-identical, by design).
#
# DEPENDS ON src/model/stacking.R (default_stacking_policy, compute_nonmetal_share).
# =============================================================================

library(tidyverse)

# Wide rate_* column <-> authority + stable program id. program_id is authority-level
# — 232's sub-programs (steel/alum/...) are NOT split out of the already-resolved wide
# rate_232 (that needs the Phase-4 resolution-step rewrite); one row per (hts10, country,
# authority) here.
# Plank 5c: `precedence` is no longer a hand-maintained column — it is DERIVED from the
# policy order in build_resolved_programs() (seq_along(names(policy))), so it can never
# drift from default_stacking_policy() / stacking_policy_from_specs() the way a duplicated
# literal would. ORDER STILL MATTERS for the per-pair contribution sum's FP floor, but the
# order now has a single source (the policy), not two.
RESOLVED_AUTHORITIES <- tibble::tribble(
  ~rate_col,          ~authority,          ~program_id,
  'rate_232',         'section_232',       's232',
  'rate_ieepa_recip', 'ieepa_reciprocal',  'recip',
  'rate_ieepa_fent',  'ieepa_fentanyl',    'fentanyl',
  'rate_301',         'section_301',       's301',
  'rate_301_cs',      'section_301_cs',    's301cs',
  'rate_s301fl',      'section_301_forced_labor', 's301fl',
  'rate_s301br',      'section_301_brazil', 's301br',
  'rate_s338',        'section_338',       's338',
  'rate_s122',        'section_122',       's122',
  'rate_section_201', 'section_201',       's201',
  'rate_other',       'other',             'other'
)

#' Is resolution-time stacking via the resolved-program table enabled?
#' (TARIFF_RESOLVED_STACKING=1|true|yes|on). Default OFF.
use_resolved_stacking <- function() {
  v <- tolower(trimws(Sys.getenv('TARIFF_RESOLVED_STACKING', '')))
  v %in% c('1', 'true', 'yes', 'on')
}

#' Build the resolved-program long table from a wide rate panel.
#'
#' @param df wide panel (hts10, country, base_rate, rate_*, metal_share, and
#'   optionally per-type shares / s232_annex / deriv_type).
#' @param policy stacking policy (default_stacking_policy()): per-authority class
#'   + per-country additive overrides.
#' @return long tibble, one row per (.pair, authority): authority, program_id,
#'   precedence, rate, stacking_class, metal_type, nonmetal_share, base_rate,
#'   s232_annex, and contrib (rate x stacking multiplier).
build_resolved_programs <- function(df, policy = default_stacking_policy()) {
  rate_cols <- names(policy)

  # Guards mirror apply_stacking_rules()'s top-of-function so both paths agree.
  df <- ensure_cols(df, list(rate_s122 = 0, rate_section_201 = 0, metal_share = 1),
                    fill_na = TRUE)
  if (!'deriv_type' %in% names(df)) df$deriv_type <- NA_character_
  # Plank 5c: every policy rate_col must exist before the pivot (mirrors the wide path's
  # compute_stacking_contributions, stacking.R:168, and the 06 fast path which seeds
  # rate_301_cs = 0 at compute_rates_wide). Inject 0 for any column absent from the frame
  # (e.g. rate_301_cs on an older/synthetic panel) so pivot_longer(all_of(rate_cols)) is
  # total. Fixes a latent crash: rate_301_cs entered default_stacking_policy() but this
  # guard set never covered it.
  for (col in rate_cols) if (!col %in% names(df)) df[[col]] <- 0
  df <- compute_nonmetal_share(df)            # pair-level nonmetal_share
  df$.pair    <- seq_len(nrow(df))
  df$.has_232 <- df$rate_232 > 0              # pair-level (rate_232 is pivoted away)

  # precedence is DERIVED from the policy order (Plank 5c) — single source of truth,
  # no hand-maintained column to drift. seq_along(rate_cols) reproduces the old 1L..8L.
  cls <- tibble(rate_col = rate_cols,
                stacking_class = map_chr(policy, 'class'),
                precedence = seq_along(rate_cols)) %>%
    left_join(RESOLVED_AUTHORITIES, by = 'rate_col')

  # Per-country class overrides (content_split -> additive) for scenario re-scoping.
  add_rows <- lapply(rate_cols, function(col) {
    ac <- policy[[col]]$additive_countries %||% character(0)
    if (length(ac)) tibble(rate_col = col, country = ac, .additive_override = TRUE) else NULL
  })
  add_lookup <- bind_rows(add_rows)
  if (!nrow(add_lookup)) add_lookup <- tibble(rate_col = character(),
                                              country = character(),
                                              .additive_override = logical())

  meta <- intersect(c('.pair', 'hts10', 'country', 'base_rate', '.has_232',
                      'nonmetal_share', 's232_annex', 'deriv_type'), names(df))
  df %>%
    select(all_of(meta), all_of(rate_cols)) %>%
    pivot_longer(all_of(rate_cols), names_to = 'rate_col', values_to = 'rate') %>%
    left_join(cls, by = 'rate_col') %>%
    left_join(add_lookup, by = c('rate_col', 'country')) %>%
    mutate(
      .additive_override = coalesce(.additive_override, FALSE),
      # metal_type: the derivative metal classification for the 232 row (NA for
      # primary-metal-by-chapter, which is captured via nonmetal_share, and for
      # non-232 authorities). Substrate metadata; not used by the sum.
      metal_type = if_else(authority == 'section_232', deriv_type, NA_character_),
      .is_split  = stacking_class == 'content_split' & .has_232 & !.additive_override,
      contrib    = rate * if_else(.is_split, nonmetal_share, 1)
    )
}

#' Stack the resolved table to per-pair total_additional (the generic stacking).
#' One group-by sum replaces the wide case_when. Summed in authority order
#' (= policy order), so it stays within the FP floor of the wide path.
stack_resolved <- function(resolved) {
  resolved %>%
    group_by(.pair) %>%
    summarise(total_additional = sum(contrib), .groups = 'drop')
}

#' Resolve a wide panel and collapse back to the wide rate_* + total_* schema.
#'
#' rate_* are unchanged (the long `rate` IS the wide value); only total_additional
#' / total_rate are (re)derived from the generic stack — so the persisted contract
#' matches apply_stacking_rules() within the FP floor. Overwrites any existing
#' total_* (the fast path may have set them upstream), mirroring the wide path.
resolve_and_collapse <- function(df, policy = default_stacking_policy()) {
  totals <- stack_resolved(build_resolved_programs(df, policy))
  df$.pair <- seq_len(nrow(df))
  df %>%
    select(-any_of(c('total_additional', 'total_rate'))) %>%
    left_join(totals, by = '.pair') %>%
    mutate(total_rate = base_rate + total_additional) %>%
    select(-.pair)
}
