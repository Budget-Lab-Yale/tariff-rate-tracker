# =============================================================================
# Build panel-keyed import weights (HS10 x country)
# =============================================================================
#
# Publishes a per-vintage HS10 x country import-weight base whose `hts10` keys
# are drawn from THIS tracker's rate-panel code universe, so a downstream model
# (tariff-model) can roll the rate panel up to GTAP / BEA with an EXACT
# (hts10, country) join instead of papering over a statistical-suffix vintage
# mismatch.
#
# The problem this solves
# -----------------------
# The import-weight base (data/weights/hs10_by_country_gtap_<year>_con.rds, the
# 2024 Census customs-value extraction) is keyed on the HTS statistical-suffix
# vintage that traded in 2024. The rate panel is enumerated from the CURRENT HTS
# revision. USITC/Census split / merge / renumber 10th-digit suffixes between
# vintages, so a chunk of import value sits on retired 10-digit codes that have
# no exact match in the current panel (~1.5% / ~$46B against the live panel).
# The 8-digit heading is stable, though — ~99.8% of the orphaned value recovers
# at HS8 — so we forward-map the orphan value onto its successor suffix(es)
# under the current vintage, conserving the dollar total exactly.
#
# What it emits (into <vintage>/weights/)
# ---------------------------------------
#   import_weights_hs10_country.parquet   # hts10, country, imports (+year, vintage)
#   import_weights_hs10_country.csv.gz    # optional CSV fallback (same rows)
#   hts10_revision_crosswalk.csv          # the forward map applied to orphan
#                                         # codes: old_hts10, new_hts10,
#                                         # split_weight, level (audit / reuse)
#
# `country` is the same code system as the rate panel's `country` column: the
# 4-digit U.S. Census Bureau country code ("cty_code"). No GTAP / BEA codes are
# added — that bucketing stays on the consumer's side by design.
#
# Which codes? A published vintage is a TIME SERIES of per-interval snapshots
# whose 10-digit code set drifts slightly as USITC renumbers suffixes, so the
# union of all intervals is not a single point in time. The weights are keyed to
# the CURRENT vintage — the latest interval's code universe (current_panel_codes())
# — which is exactly "your current HTS codes": a rollup against the current rate
# panel then joins 100% exactly. Older intervals match a hair less (~96-99% of
# value) since their codes predate later renumbering; that is inherent to one
# frozen 2024 base, not a defect.
#
# Reproducibility: the forward-map is deterministic. publish_internal.R calls it
# automatically for every vintage; the CLI below re-keys an already-published
# vintage against its own snapshots without a rebuild.
#
# Usage (standalone, against a published vintage):
#   module load R/4.4.2-gfbf-2024a
#   Rscript src/io/build_panel_import_weights.R \
#       --vintage-dir /nfs/.../Tariff-Rate-Tracker/latest
#   # options: --base <rds>  --year 2024  --out-dir <dir>  --no-csv
#   #          --no-crosswalk  --dry-run
#
# Documented in: docs/weights.md
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(stringr)
})

if (!exists('%||%')) `%||%` <- function(a, b) if (is.null(a)) b else a

if (requireNamespace('here', quietly = TRUE)) {
  source(here::here('src', 'io', 'output_paths.R'))   # SNAPSHOT_FILE / actual_snapshots_dir
}


# =============================================================================
# Core: forward-map the 2024 import base onto the panel code universe
# =============================================================================

#' Forward-map an HS10 x country import base onto a target code universe.
#'
#' Every base code that already exists in `panel_codes` is kept verbatim. Every
#' base code that does NOT (a retired statistical suffix) has its value
#' redistributed onto the panel codes that share its longest common HTS prefix
#' — HS8 heading first, then HS6 subheading, HS4 heading, HS2 chapter, and a
#' whole-panel fallback as a last resort. Within a prefix group the split is
#' proportional to each target's own directly-matched 2024 import value
#' (the codes that actually absorb the trade); if no target in the group traded
#' in 2024 the value is split evenly. Country is preserved throughout.
#'
#' This conserves the dollar total exactly (orphan value is moved, never
#' dropped) and guarantees every output code is in `panel_codes`.
#'
#' @param base data frame with columns hs10, cty_code, imports (USD).
#' @param panel_codes character vector of valid panel hts10 codes (the target
#'   universe). De-duplicated internally.
#' @param levels Prefix lengths to try, finest first. Default c(8,6,4,2).
#' @return list(weights, crosswalk, stats):
#'   - weights:   tibble(hts10, cty_code, imports) — one row per pair, imports>0,
#'                every hts10 in panel_codes.
#'   - crosswalk: tibble(old_hts10, new_hts10, split_weight, level) for the
#'                REMAPPED (orphan) codes only — split_weight sums to 1 per
#'                old_hts10. Codes absent from this table mapped to themselves.
#'   - stats:     named list of diagnostics (totals, coverage, per-level value).
forward_map_imports <- function(base, panel_codes, levels = c(8L, 6L, 4L, 2L)) {
  panel_set <- unique(as.character(panel_codes))
  if (length(panel_set) == 0) stop('forward_map_imports: panel_codes is empty.')

  base <- base %>%
    transmute(hs10     = str_pad(as.character(hs10), 10, 'left', '0'),
              cty_code = as.character(cty_code),
              imports  = as.numeric(imports)) %>%
    group_by(hs10, cty_code) %>%
    summarise(imports = sum(imports), .groups = 'drop') %>%
    filter(imports > 0)

  total_in <- sum(base$imports)

  matched <- base %>% filter(hs10 %in% panel_set)
  orphan  <- base %>% filter(!hs10 %in% panel_set)

  # Per-panel-code anchor weight = the value that matched the code exactly
  # (summed over countries). Every panel code gets a row (0 if it never traded
  # in 2024) so even a never-traded successor can receive value on an even split.
  matched_by_code <- matched %>%
    group_by(hs10) %>%
    summarise(anchor = sum(imports), .groups = 'drop') %>%
    rename(new_hts10 = hs10)
  anchor <- tibble(new_hts10 = panel_set) %>%
    left_join(matched_by_code, by = 'new_hts10') %>%
    mutate(anchor = coalesce(anchor, 0))

  # ---- resolve each orphan code to a set of panel targets ------------------
  # Walk prefixes finest-first; a code is "resolved" at the first level whose
  # prefix is shared by >=1 panel code.
  orphan_codes <- unique(orphan$hs10)
  remaining <- orphan_codes
  map_parts <- list()

  for (L in levels) {
    if (length(remaining) == 0) break
    targets <- anchor %>% mutate(pfx = substr(new_hts10, 1, L))
    part <- tibble(old_hts10 = remaining, pfx = substr(remaining, 1, L)) %>%
      inner_join(targets, by = 'pfx', relationship = 'many-to-many') %>%
      mutate(level = L) %>%
      select(old_hts10, new_hts10, anchor, level)
    if (nrow(part) > 0) {
      map_parts[[as.character(L)]] <- part
      remaining <- setdiff(remaining, unique(part$old_hts10))
    }
  }

  # Whole-panel fallback for anything that shares no prefix with the panel.
  # Expected to be empty in practice (every HTS chapter is in the panel); kept
  # so value conservation never silently fails.
  if (length(remaining) > 0) {
    map_parts[['0']] <- tidyr::crossing(old_hts10 = remaining,
                                        anchor %>% select(new_hts10, anchor)) %>%
      mutate(level = 0L)
  }

  crosswalk <- bind_rows(map_parts)
  if (nrow(crosswalk) > 0) {
    crosswalk <- crosswalk %>%
      group_by(old_hts10) %>%
      mutate(grp_total = sum(anchor),
             split_weight = if_else(grp_total > 0, anchor / grp_total, 1 / n())) %>%
      ungroup() %>%
      # Drop zero-weight candidates (targets in the prefix group that absorb no
      # value) so the crosswalk shows only where value actually flows.
      filter(split_weight > 0) %>%
      select(old_hts10, new_hts10, split_weight, level)
  } else {
    crosswalk <- tibble(old_hts10 = character(), new_hts10 = character(),
                        split_weight = double(), level = integer())
  }

  # ---- apply the map: matched verbatim + orphan value redistributed --------
  redistributed <- orphan %>%
    rename(old_hts10 = hs10) %>%
    inner_join(crosswalk %>% select(old_hts10, new_hts10, split_weight),
               by = 'old_hts10', relationship = 'many-to-many') %>%
    transmute(hts10 = new_hts10, cty_code, imports = imports * split_weight)

  weights <- bind_rows(matched %>% rename(hts10 = hs10), redistributed) %>%
    group_by(hts10, cty_code) %>%
    summarise(imports = sum(imports), .groups = 'drop') %>%
    filter(imports > 0) %>%
    arrange(hts10, cty_code)

  # ---- diagnostics ---------------------------------------------------------
  per_level <- orphan %>%
    rename(old_hts10 = hs10) %>%
    inner_join(distinct(crosswalk, old_hts10, level), by = 'old_hts10') %>%
    group_by(level) %>%
    summarise(value = sum(imports), n_codes = n_distinct(old_hts10), .groups = 'drop')

  stats <- list(
    total_in          = total_in,
    total_out         = sum(weights$imports),
    n_panel_codes     = length(panel_set),
    n_base_pairs      = nrow(base),
    n_matched_codes   = n_distinct(matched$hs10),
    n_orphan_codes    = length(orphan_codes),
    matched_value     = sum(matched$imports),
    orphan_value      = sum(orphan$imports),
    matched_value_pct = if (total_in > 0) 100 * sum(matched$imports) / total_in else NA_real_,
    per_level         = per_level,
    n_global_fallback = length(remaining),
    all_on_panel      = all(weights$hts10 %in% panel_set),
    n_weight_rows     = nrow(weights)
  )

  list(weights = weights, crosswalk = crosswalk, stats = stats)
}


# =============================================================================
# 484(f) crosswalk mapper: authoritative dated propagation (replaces prefix)
# =============================================================================
#
# forward_map_imports() (above) is the legacy prefix-cascade heuristic. This is
# the principled replacement: it walks the committed 484(f) transfer edges in
# effective-date order, moving each 2024-base code's value onto the successor
# code(s) the USITC committee actually assigned it, and only falls back to the
# prefix cascade for value that no committee edge explains (retired statistical
# suffixes — see validate_484f_coverage()'s "cascade" class).
#
# Design (docs/wondrous_spinning_frost_plan_review.md §2.2-2.4; plan §C):
#
#   - VERSIONED IDENTITIES via base-code provenance. Each state row carries the
#     original 2024 base code it descends from, so the country-specific COMPOSED
#     map (base_hts10 -> final new_hts10, per country) falls out for free and a
#     reused code number never inherits a prior identity's history.
#
#   - TRANSACTIONAL DATED PROPAGATION. For each effective_date <= hts_as_of_date
#     (ascending) we snapshot the pre-date mass of every old code that changes on
#     that date, allocate it across successors FROM THE SNAPSHOT, then remove old
#     + add new simultaneously. Same-date-created mass is therefore never
#     consumed by another same-date edge (pharma chains, same-date reuse).
#
#   - SHARE LADDER WITH SEMANTIC ELIGIBILITY. A split's proportions come from,
#     in order: (i) successors' country-specific 2025 imports; (ii) all-country
#     2025 imports; (iii) successors' 2024 direct anchors; (v) even. Tiers i-iii
#     are ELIGIBLE only for successor identities that genuinely existed under
#     that number in the evidence year: a 2026-established identity (incl.
#     same-date reuse) has no valid 2025/2024 self-history, so it falls to even.
#     The mass always stays in its origin country (the ladder sets proportions
#     only), so per-country conservation is automatic.
#
#   - no_successor deletions are left in place during propagation and swept by
#     the residual prefix cascade (their trade moved to HS8 siblings). The
#     whole-panel global fallback is a HARD FAILURE.

CROSSWALK_MAPPER_SCHEMA_VERSION <- 1L

# Production residual thresholds (set from the tip A/B; see build_panel_import_weights).
# Hard cap on the "unknown-sibling" residual (prefix cascade); the whole-panel
# global fallback is already a hard 0 in validate_mapped_weights().
CROSSWALK_MAX_CASCADE_PCT <- 1.0   # actual 0.22%
CROSSWALK_MAX_EVEN_PCT    <- 12.0  # actual 6.7% (within-HS8, rate-neutral) — soft

SHARE_SOURCES <- c('identity', 'country_2025_identity_valid',
                   'all_country_2025_identity_valid', 'anchor_2024_identity_valid',
                   'family_fallback', 'even_fallback',
                   'prefix_cascade_8', 'prefix_cascade_6', 'prefix_cascade_4',
                   'prefix_cascade_2', 'prefix_cascade_global')

#' Normalize an (hs10/hts10, cty_code, imports) frame: dedup, drop nonpositive.
.normalize_imports_frame <- function(df, code_col) {
  df %>%
    transmute(hts10 = str_pad(as.character(.data[[code_col]]), 10, 'left', '0'),
              cty_code = as.character(cty_code),
              imports = as.numeric(imports)) %>%
    group_by(hts10, cty_code) %>%
    summarise(imports = sum(imports), .groups = 'drop') %>%
    filter(is.finite(imports), imports > 0)
}

#' Map the 2024 base onto the tip panel via the dated 484(f) transfer edges.
#'
#' @param base data frame (hs10, cty_code, imports) — the 2024 customs-value base.
#' @param panel_codes character vector — target tip hts10 universe.
#' @param xwalk the 484(f) transfers (old_hts10, new_hts10, effective_date,
#'   same_date_reuse; new_hts10 NA for no_successor).
#' @param shares optional (hs10, cty_code, imports) 2025 split-share base.
#' @param hts_as_of_date only edges with effective_date <= this apply (ISO date
#'   or Date). Must be supplied explicitly (never defaulted to Sys.Date()).
#' @param levels residual prefix-cascade levels, finest first.
#' @return list(weights, crosswalk, composed, edges_applied, stats) — same
#'   weights/crosswalk contract as forward_map_imports() plus the country
#'   composed map and per-date transition log.
crosswalk_map_imports <- function(base, panel_codes, xwalk, shares = NULL,
                                  hts_as_of_date = NULL, levels = c(8L, 6L, 4L, 2L)) {
  if (is.null(hts_as_of_date)) {
    stop('crosswalk_map_imports: hts_as_of_date is required (never defaulted to ',
         'Sys.Date()); pass the snapshot HTS-identity date.', call. = FALSE)
  }
  as_of <- as.Date(hts_as_of_date)
  panel_set <- unique(as.character(panel_codes))
  if (length(panel_set) == 0) stop('crosswalk_map_imports: panel_codes is empty.')

  base <- .normalize_imports_frame(base, intersect(c('hs10', 'hts10'), names(base))[1])
  total_in <- sum(base$imports)
  country_in <- base %>% group_by(cty_code) %>% summarise(v = sum(imports), .groups = 'drop')

  # Successor 2024 anchor value (all countries) from the base — tier iii.
  anchor_2024 <- base %>% group_by(hts10) %>%
    summarise(anchor = sum(imports), .groups = 'drop')

  # 2025 share lookups (may be absent).
  have_shares <- !is.null(shares) && nrow(shares) > 0
  if (have_shares) {
    shares <- .normalize_imports_frame(shares, intersect(c('hs10', 'hts10'), names(shares))[1])
    shares_cty <- shares %>% transmute(new_hts10 = hts10, cty_code, s_cty = imports)
    shares_all <- shares %>% group_by(hts10) %>%
      summarise(s_all = sum(imports), .groups = 'drop') %>%
      transmute(new_hts10 = hts10, s_all)
  }

  # Edges that apply: within date window, with a successor. Deletions
  # (no_successor) are left for the residual cascade.
  tf <- xwalk %>%
    mutate(effective_date = as.Date(effective_date),
           old_hts10 = str_pad(as.character(old_hts10), 10, 'left', '0'),
           new_hts10 = ifelse(is.na(new_hts10), NA_character_,
                              str_pad(as.character(new_hts10), 10, 'left', '0'))) %>%
    filter(effective_date <= as_of, !is.na(old_hts10), !is.na(new_hts10)) %>%
    distinct(old_hts10, new_hts10, effective_date, same_date_reuse)

  # State carries base_hts10 provenance + the share_source of the last split.
  state <- base %>% transmute(base_hts10 = hts10, hts10, cty_code, imports,
                              share_source = 'identity')
  edges_applied <- list()

  # Index into the Date vector (iterating `for (d in dates)` would strip the
  # Date class, turning d into a numeric and breaking as.character(d)).
  dates <- sort(unique(tf$effective_date))
  for (di in seq_along(dates)) {
    d <- dates[di]
    fam <- tf %>% filter(effective_date == d) %>%
      distinct(old_hts10, new_hts10, same_date_reuse) %>%
      group_by(old_hts10) %>%
      mutate(family_reuse = any(same_date_reuse), n_succ = n_distinct(new_hts10)) %>%
      ungroup()
    old_codes_d <- unique(fam$old_hts10)

    snap <- state %>% filter(hts10 %in% old_codes_d)
    if (nrow(snap) == 0) next   # nothing of this old code carries value here

    elig_year <- d <= as.Date('2025-12-31')

    alloc <- snap %>%
      rename(old_hts10 = hts10, mass = imports) %>%
      inner_join(fam, by = 'old_hts10', relationship = 'many-to-many')
    if (have_shares) {
      alloc <- alloc %>%
        left_join(shares_cty, by = c('new_hts10', 'cty_code')) %>%
        left_join(shares_all, by = 'new_hts10')
    } else {
      alloc$s_cty <- NA_real_; alloc$s_all <- NA_real_
    }
    # Eligibility: a split's successors may use 2025 self-shares only if they
    # genuinely existed under that number in 2025 — i.e. the transition is a
    # 2025 reclassification (successors created that year, so their 2025 imports
    # are their own trade) AND the family is not a same-date reuse. A
    # 2026-established identity (or a reused number) has no valid 2025/2024
    # self-history, so it falls straight to an even split (disclosed as such).
    # The 2024-anchor tier is NOT used for dated splits (successors are
    # period-new with no 2024 self-trade); it lives only in the residual cascade.
    alloc <- alloc %>%
      mutate(eligible = elig_year & !family_reuse,
             .s_cty = if_else(eligible, coalesce(s_cty, 0), 0),
             .s_all = if_else(eligible, coalesce(s_all, 0), 0)) %>%
      group_by(base_hts10, old_hts10, cty_code) %>%
      mutate(sum_cty = sum(.s_cty), sum_all = sum(.s_all),
             weight = case_when(
               sum_cty > 0 ~ .s_cty / sum_cty,
               sum_all > 0 ~ .s_all / sum_all,
               TRUE        ~ 1 / n_succ),
             step_source = case_when(
               sum_cty > 0 ~ 'country_2025_identity_valid',
               sum_all > 0 ~ 'all_country_2025_identity_valid',
               TRUE        ~ 'even_fallback')) %>%
      ungroup()

    moved <- alloc %>%
      transmute(base_hts10, hts10 = new_hts10, cty_code,
                imports = mass * weight, share_source = step_source)

    # Simultaneous remove-old + add-new, then collapse.
    state <- state %>%
      filter(!hts10 %in% old_codes_d) %>%
      bind_rows(moved) %>%
      group_by(base_hts10, hts10, cty_code) %>%
      summarise(imports = sum(imports),
                share_source = dplyr::last(share_source), .groups = 'drop')

    # Per-date conservation (overall + per-country) — mass only moved, not lost.
    rel <- abs(sum(state$imports) - total_in) / max(total_in, 1)
    if (rel > 1e-9) {
      stop(sprintf('crosswalk_map_imports: conservation broke at %s (rel err %.2e).',
                   d, rel), call. = FALSE)
    }
    edges_applied[[as.character(d)]] <- alloc %>%
      summarise(effective_date = d, n_families = n_distinct(old_hts10),
                n_edges = n_distinct(paste(old_hts10, new_hts10)),
                value_moved = sum(mass * weight),
                .by = NULL) %>%
      bind_cols(alloc %>% count(step_source) %>%
                  tidyr::pivot_wider(names_from = step_source, values_from = n,
                                     names_prefix = 'src_'))
  }

  # --- residual prefix cascade for anything still off-panel ------------------
  off <- state %>% filter(!hts10 %in% panel_set)
  on  <- state %>% filter(hts10 %in% panel_set)
  cascade_stats <- tibble(level = integer(), value = double(), n_codes = integer())
  n_global <- 0L
  if (nrow(off) > 0) {
    anchor <- tibble(new_hts10 = panel_set) %>%
      left_join(anchor_2024 %>% rename(new_hts10 = hts10), by = 'new_hts10') %>%
      mutate(anchor = coalesce(anchor, 0))
    off_codes <- unique(off$hts10)
    remaining <- off_codes
    parts <- list()
    for (L in c(levels, 0L)) {
      if (length(remaining) == 0) break
      if (L == 0L) {
        parts[['0']] <- tidyr::crossing(hts10 = remaining,
          anchor %>% select(new_hts10, anchor)) %>% mutate(level = 0L)
        n_global <- length(remaining); remaining <- character(0)
        break
      }
      tgt <- anchor %>% mutate(pfx = substr(new_hts10, 1, L))
      part <- tibble(hts10 = remaining, pfx = substr(remaining, 1, L)) %>%
        inner_join(tgt, by = 'pfx', relationship = 'many-to-many') %>%
        mutate(level = L) %>% select(hts10, new_hts10, anchor, level)
      if (nrow(part) > 0) {
        parts[[as.character(L)]] <- part
        remaining <- setdiff(remaining, unique(part$hts10))
      }
    }
    cascade_map <- bind_rows(parts) %>%
      group_by(hts10) %>%
      mutate(grp = sum(anchor),
             split_weight = if_else(grp > 0, anchor / grp, 1 / n())) %>%
      ungroup() %>% filter(split_weight > 0) %>%
      select(hts10, new_hts10, split_weight, level)
    cascade_stats <- off %>% rename(old = hts10) %>%
      inner_join(distinct(cascade_map, hts10, level), by = c('old' = 'hts10')) %>%
      group_by(level) %>%
      summarise(value = sum(imports), n_codes = n_distinct(old), .groups = 'drop')
    redist <- off %>%
      inner_join(cascade_map, by = 'hts10', relationship = 'many-to-many') %>%
      transmute(base_hts10, hts10 = new_hts10, cty_code,
                imports = imports * split_weight,
                share_source = paste0('prefix_cascade_', level))
    state <- bind_rows(on, redist) %>%
      group_by(base_hts10, hts10, cty_code) %>%
      summarise(imports = sum(imports),
                share_source = dplyr::last(share_source), .groups = 'drop')
  }

  # --- outputs ---------------------------------------------------------------
  weights <- state %>%
    group_by(hts10, cty_code) %>%
    summarise(imports = sum(imports), .groups = 'drop') %>%
    filter(imports > 0) %>% arrange(hts10, cty_code)

  composed <- state %>%
    filter(base_hts10 != hts10 | share_source != 'identity') %>%
    group_by(base_hts10, cty_code) %>%
    mutate(split_weight = imports / sum(imports)) %>%
    ungroup() %>%
    transmute(base_hts10, cty_code, new_hts10 = hts10, split_weight,
              share_source, hts_as_of_date = as.character(as_of))

  # Country-agnostic crosswalk (audit only) — split by TOTAL mass across
  # countries, never by summing per-country weights. The composed map is what
  # actually reproduces the weights; this is a labeled aggregate summary.
  crosswalk <- state %>%
    filter(base_hts10 != hts10 | share_source != 'identity') %>%
    group_by(base_hts10, hts10) %>%
    summarise(v = sum(imports), src = dplyr::last(share_source), .groups = 'drop') %>%
    group_by(base_hts10) %>%
    mutate(split_weight = v / sum(v)) %>% ungroup() %>%
    transmute(old_hts10 = base_hts10, new_hts10 = hts10, split_weight,
              share_source = src)

  per_source <- state %>% group_by(share_source) %>%
    summarise(value = sum(imports), .groups = 'drop') %>% arrange(desc(value))

  stats <- list(
    mapper_schema_version = CROSSWALK_MAPPER_SCHEMA_VERSION,
    method = '484f', hts_as_of_date = as.character(as_of),
    total_in = total_in, total_out = sum(weights$imports),
    n_panel_codes = length(panel_set), n_weight_rows = nrow(weights),
    n_transfer_dates = length(edges_applied),
    n_global_fallback = n_global,
    all_on_panel = all(weights$hts10 %in% panel_set),
    per_source = per_source, cascade_stats = cascade_stats,
    country_in = country_in)

  list(weights = weights, crosswalk = crosswalk, composed = composed,
       edges_applied = bind_rows(edges_applied), stats = stats)
}


#' Shared validation of a mapped weight result (extends the prefix asserts with
#' per-country conservation). Fatal on any violation.
#'
#' @param weights tibble(hts10, cty_code, imports).
#' @param panel_set target universe.
#' @param country_in tibble(cty_code, v) of input per-country totals.
#' @param total_in scalar input total.
#' @param tol relative tolerance (default 1e-9).
validate_mapped_weights <- function(weights, panel_set, country_in, total_in,
                                    n_global_fallback = 0L, tol = 1e-9) {
  if (!all(weights$hts10 %in% panel_set)) {
    stop('mapped weights include codes outside the panel universe — bug.', call. = FALSE)
  }
  if (anyDuplicated(weights[c('hts10', 'cty_code')]) > 0) {
    stop('mapped weights have duplicate (hts10, country) keys — bug.', call. = FALSE)
  }
  if (any(is.na(weights$hts10)) || any(is.na(weights$cty_code)) ||
      any(is.na(weights$imports)) || any(weights$imports <= 0)) {
    stop('mapped weights have NA keys or nonpositive imports — bug.', call. = FALSE)
  }
  rel <- abs(sum(weights$imports) - total_in) / max(total_in, 1)
  if (rel > tol) {
    stop(sprintf('mapped weights lost value: in $%.4fB out $%.4fB (rel err %.2e).',
                 total_in / 1e9, sum(weights$imports) / 1e9, rel), call. = FALSE)
  }
  cty_out <- weights %>% group_by(cty_code) %>% summarise(v = sum(imports), .groups = 'drop')
  chk <- country_in %>% rename(v_in = v) %>%
    full_join(cty_out %>% rename(v_out = v), by = 'cty_code') %>%
    mutate(v_in = coalesce(v_in, 0), v_out = coalesce(v_out, 0),
           rel = abs(v_out - v_in) / pmax(v_in, 1))
  bad <- chk %>% filter(rel > tol)
  if (nrow(bad) > 0) {
    stop(sprintf('mapped weights break per-country conservation for %d countries (e.g. %s).',
                 nrow(bad), paste(head(bad$cty_code, 5), collapse = ', ')), call. = FALSE)
  }
  if (n_global_fallback > 0) {
    stop(sprintf('mapped weights used the whole-panel global fallback for %d code(s) ',
                 n_global_fallback), ' — prohibited in production.', call. = FALSE)
  }
  invisible(TRUE)
}


# =============================================================================
# Helpers: load the base, read the panel universe from published snapshots
# =============================================================================

#' Load the 2024 import-weight base as (hs10, cty_code, imports).
#'
#' Reads the canonical HS10 x country x GTAP RDS (built by
#' src/build_import_weights.R) and collapses the GTAP dimension away — the
#' published panel weights deliberately carry NO GTAP/BEA codes. Any column
#' beyond hs10/cty_code/imports is ignored.
load_weight_base <- function(base_path) {
  if (is.null(base_path) || !nzchar(base_path) || !file.exists(base_path)) {
    stop('Import-weight base not found: ', base_path %||% '<NULL>', '\n',
         '  Build it with: Rscript src/build_import_weights.R --year 2024\n',
         '  or pass --base <path-to-hs10_by_country_gtap_*.rds>.', call. = FALSE)
  }
  raw <- readRDS(base_path)
  need <- c('hs10', 'cty_code', 'imports')
  if (!all(need %in% names(raw))) {
    stop('Import-weight base ', base_path, ' is missing columns: ',
         paste(setdiff(need, names(raw)), collapse = ', '),
         ' (have: ', paste(names(raw), collapse = ', '), ').', call. = FALSE)
  }
  raw %>%
    group_by(hs10, cty_code) %>%
    summarise(imports = sum(imports), .groups = 'drop') %>%
    filter(imports > 0)
}


#' HTS10 codes of the CURRENT rate-panel vintage (latest interval).
#'
#' This is the universe the weights are keyed to: a published vintage is a time
#' series of per-interval snapshots whose 10-digit code set shifts slightly as
#' USITC renumbers suffixes across revisions, so the union is NOT a single point
#' in time — only the latest (tip) interval is "your current HTS codes". Keying
#' the 2024 flows forward onto these gives a downstream rollup against the
#' current rate panel an exact 100% (hts10, country) join. Reads only `hts10`
#' from the single latest-`valid_from` partition (lazy, low-memory).
current_panel_codes <- function(snaps_dir) {
  if (!requireNamespace('arrow', quietly = TRUE)) {
    stop('current_panel_codes requires the arrow package.', call. = FALSE)
  }
  snap_file <- if (exists('SNAPSHOT_FILE')) SNAPSHOT_FILE else 'rates.parquet'
  pq <- list.files(snaps_dir, pattern = paste0(snap_file, '$'),
                   recursive = TRUE, full.names = TRUE)
  if (length(pq) == 0) {
    stop('No ', snap_file, ' under ', snaps_dir,
         ' — point at a published vintage (with actual/snapshots/).', call. = FALSE)
  }
  ds <- arrow::open_dataset(pq)
  tip <- max(as.Date((ds %>% select(valid_from) %>% distinct() %>% collect())$valid_from))
  codes <- ds %>% filter(valid_from == tip) %>% select(hts10) %>% distinct() %>% collect()
  unique(as.character(codes$hts10))
}


#' Distinct hts10 across ALL per-interval snapshots of a vintage (the union).
#'
#' Reads only the `hts10` column (lazy, low-memory) from every rates.parquet
#' under `snaps_dir`, skipping the sibling metadata.rds. Used for diagnostics /
#' coverage reporting; the weights are keyed to current_panel_codes(), not this.
panel_universe_from_snapshots <- function(snaps_dir) {
  if (!requireNamespace('arrow', quietly = TRUE)) {
    stop('panel_universe_from_snapshots requires the arrow package.', call. = FALSE)
  }
  snap_file <- if (exists('SNAPSHOT_FILE')) SNAPSHOT_FILE else 'rates.parquet'
  pq <- list.files(snaps_dir, pattern = paste0(snap_file, '$'),
                   recursive = TRUE, full.names = TRUE)
  if (length(pq) == 0) {
    stop('No ', snap_file, ' under ', snaps_dir,
         ' — point --vintage-dir at a published vintage (with actual/snapshots/).',
         call. = FALSE)
  }
  ds <- arrow::open_dataset(pq)
  codes <- ds %>% select(hts10) %>% distinct() %>% collect()
  unique(as.character(codes$hts10))
}


#' Revision id of the latest (tip) interval among published snapshots.
#'
#' Used to stamp the `hts_vintage` column. Reads the `revision` + `valid_from`
#' columns and returns the revision with the greatest valid_from. NA if absent.
tip_revision_from_snapshots <- function(snaps_dir) {
  snap_file <- if (exists('SNAPSHOT_FILE')) SNAPSHOT_FILE else 'rates.parquet'
  pq <- list.files(snaps_dir, pattern = paste0(snap_file, '$'),
                   recursive = TRUE, full.names = TRUE)
  if (length(pq) == 0 || !requireNamespace('arrow', quietly = TRUE)) return(NA_character_)
  cols <- tryCatch(
    arrow::open_dataset(pq) %>% select(revision, valid_from) %>% distinct() %>% collect(),
    error = function(e) NULL)
  if (is.null(cols) || nrow(cols) == 0 || !('revision' %in% names(cols))) return(NA_character_)
  as.character(cols$revision[which.max(as.Date(cols$valid_from))])
}


# =============================================================================
# Orchestrator
# =============================================================================

#' Build and (optionally) write the panel-keyed import-weight file for a vintage.
#'
#' @param panel_codes character vector — the target hts10 universe.
#' @param base_path path to the HS10 x country x GTAP import-weight RDS.
#' @param out_dir directory to write into (the vintage's weights/ dir).
#' @param year import-value calendar year (stamped into the file). Default 2024.
#' @param hts_vintage HTS revision the panel codes are keyed to (stamped, may be NA).
#' @param write_csv also write a gzipped CSV sibling. Default TRUE.
#' @param write_crosswalk also write the orphan forward-map crosswalk. Default TRUE.
#' @param dry_run compute + validate, write nothing.
#' @return invisibly list(files, weights, crosswalk, stats).
#' Load the committed 484(f) transfer edges (post-override) for the mapper.
load_484f_transfers <- function(path) {
  if (is.null(path) || !file.exists(path)) {
    stop('484(f) transfer crosswalk not found: ', path %||% '<NULL>',
         '\n  Generate it with: Rscript tools/build_484f_crosswalk.R', call. = FALSE)
  }
  tr <- readr::read_csv(path, col_types = readr::cols(.default = readr::col_character()))
  need <- c('old_hts10', 'new_hts10', 'effective_date', 'same_date_reuse')
  miss <- setdiff(need, names(tr))
  if (length(miss)) {
    stop('484(f) transfers ', path, ' missing columns: ',
         paste(miss, collapse = ', '), call. = FALSE)
  }
  tr %>% mutate(same_date_reuse = tolower(same_date_reuse) %in% c('true', 't', '1'))
}

#' Load the 2025 split-share base (hs10, cty_code, imports) — exact schema.
load_split_shares <- function(path) {
  if (is.null(path) || !file.exists(path)) {
    stop('Split-share base not found: ', path %||% '<NULL>',
         '\n  Build it with: Rscript src/io/build_import_weights.R --year 2025 --no-gtap',
         call. = FALSE)
  }
  raw <- readRDS(path)
  need <- c('hs10', 'cty_code', 'imports')
  if (!all(need %in% names(raw))) {
    stop('Split-share base ', path, ' missing columns: ',
         paste(setdiff(need, names(raw)), collapse = ', '),
         ' (have: ', paste(names(raw), collapse = ', '), ').', call. = FALSE)
  }
  raw %>%
    transmute(hs10 = str_pad(as.character(hs10), 10, 'left', '0'),
              cty_code = as.character(cty_code), imports = as.numeric(imports)) %>%
    group_by(hs10, cty_code) %>%
    summarise(imports = sum(imports), .groups = 'drop') %>%
    filter(is.finite(imports), imports > 0)
}

#' Construct a memoized per-interval weight provider for the daily series.
#'
#' Returns a function suitable as `build_daily_aggregates(imports_fn = ...)`. The
#' 2024 base, the 484(f) transfers, and the 2025 shares are loaded ONCE and their
#' sha256s precomputed for the cache fingerprint. Each call maps the base onto the
#' interval's panel codes at the interval's `hts_as_of_date` (RAW HTS-identity
#' date, never policy valid_from) via crosswalk_map_imports(). Results are
#' memoized per revision, because every sub-interval of a revision shares that
#' revision's HTS identity (sub-splits differ only by expiry zeroing of rates).
#'
#' @param base_path 2024 customs-value base RDS (hs10, cty_code, imports [+gtap]).
#' @param crosswalk_path committed 484(f) transfers CSV.
#' @param shares_path 2025 split-share base RDS (optional; enables share tiers i/ii).
#' @param overrides_path committed overrides CSV (provenance / fingerprint only;
#'   already applied to the committed transfers CSV).
#' @return function(interval_context) -> list(weights = tibble(hs10, cty_code,
#'   imports), stats, fingerprint). interval_context must carry `revision`,
#'   `hts_as_of_date`, and `panel_codes`.
make_interval_weights_fn <- function(base_path, crosswalk_path,
                                     shares_path = NULL, overrides_path = NULL) {
  if (!requireNamespace('digest', quietly = TRUE)) {
    stop('make_interval_weights_fn requires the digest package.', call. = FALSE)
  }
  base   <- load_weight_base(base_path)
  xwalk  <- load_484f_transfers(crosswalk_path)
  shares <- if (!is.null(shares_path)) load_split_shares(shares_path) else NULL

  file_sha <- function(p) {
    if (!is.null(p) && file.exists(p)) digest::digest(file = p, algo = 'sha256')
    else NA_character_
  }
  # Shared (vintage-level) fingerprint components: the same for every interval.
  # Exposed as an attribute so the daily-part cache loader can validate a part
  # WITHOUT re-reading snapshots (the per-revision hts_as_of_date / panel-code
  # hash are recorded in each part and validated separately).
  shared_fp <- list(
    method                = '484f',
    mapper_schema_version = CROSSWALK_MAPPER_SCHEMA_VERSION,
    base_sha256           = file_sha(base_path),
    shares_sha256         = file_sha(shares_path),
    crosswalk_sha256      = file_sha(crosswalk_path),
    overrides_sha256      = file_sha(overrides_path)
  )

  # Memoize per revision — the mapper is the expensive step and every
  # sub-interval of a revision would otherwise recompute the same weights.
  cache <- new.env(parent = emptyenv())
  fn <- function(interval_context) {
    ctx <- interval_context
    rev <- as.character(ctx$revision)
    if (!is.null(cache[[rev]])) return(cache[[rev]])
    if (is.null(ctx$panel_codes) || length(ctx$panel_codes) == 0) {
      stop('make_interval_weights_fn: interval_context$panel_codes empty for revision ',
           rev, '.', call. = FALSE)
    }
    if (is.null(ctx$hts_as_of_date) || is.na(ctx$hts_as_of_date)) {
      stop('make_interval_weights_fn: interval_context$hts_as_of_date missing for revision ',
           rev, '.', call. = FALSE)
    }
    as_of <- as.Date(ctx$hts_as_of_date)
    mapped <- crosswalk_map_imports(base, ctx$panel_codes, xwalk, shares, as_of)
    # crosswalk_map_imports yields (hts10, cty_code, imports); the daily provider
    # contract expects (hs10, cty_code, imports).
    weights <- mapped$weights %>% rename(hs10 = hts10)
    fingerprint <- c(shared_fp, list(
      hts_as_of_date   = as.character(as_of),
      target_code_hash = digest::digest(
        sort(unique(as.character(ctx$panel_codes))), algo = 'sha256')
    ))
    res <- list(weights = weights, stats = mapped$stats, fingerprint = fingerprint)
    cache[[rev]] <- res
    res
  }
  attr(fn, 'shared_fingerprint') <- shared_fp
  fn
}


#' Named revision -> RAW HTS-identity Date, resolved through each revision's
#' archive_rev_id.
#'
#' Real revisions map to themselves; synthetic boundary revisions (bnd_/sched_)
#' inherit their owning real revision's HTS identity via `archive_rev_id` (the
#' array timeline records it). Fails loud if any revision has no identity date.
#'
#' @param timeline a data frame with `revision` and (optionally) `archive_rev_id`.
#' @param csv path to revision_dates.csv (RAW effective_date column).
hts_as_of_dates_from_timeline <- function(timeline,
                                          csv = here::here('config', 'revision_dates.csv')) {
  if (!'revision' %in% names(timeline)) {
    stop('hts_as_of_dates_from_timeline: timeline needs a `revision` column.', call. = FALSE)
  }
  revs <- as.character(timeline$revision)
  arch <- if ('archive_rev_id' %in% names(timeline)) as.character(timeline$archive_rev_id) else revs
  arch <- ifelse(is.na(arch) | !nzchar(arch), revs, arch)
  dts <- lapply(arch, function(a) as.Date(.hts_identity_date(a, csv = csv)))
  names(dts) <- revs
  miss <- revs[vapply(dts, function(d) length(d) == 0 || is.na(d), logical(1))]
  if (length(miss)) {
    stop('hts_as_of_dates_from_timeline: no HTS-identity date for revision(s): ',
         paste(miss, collapse = ', '),
         ' (checked archive_rev_id in ', csv, ').', call. = FALSE)
  }
  dts
}


#' Resolve the daily-series weight plan from config (+ an optional revision set).
#'
#' Returns a normalized plan the daily callers consume without re-reading config:
#' `list(weight_mode, weight_method, imports, imports_fn, hts_as_of_dates,
#' weight_context)`. Exactly one of `imports` / `imports_fn` is non-NULL for a
#' weighted plan; both are NULL for `unweighted`.
#'
#' Requires load_local_paths()/load_import_weights()/weight_resolution_error() to
#' be in scope (sourced by the daily caller scripts).
#'
#' @param hts_as_of_dates preferred: a named revision -> Date map (e.g. from
#'   hts_as_of_dates_from_timeline()). Falls back to per-revision resolution from
#'   `revisions` if NULL.
#' @param revisions revision ids to resolve identity dates for when
#'   hts_as_of_dates is NULL (real revisions only).
resolve_daily_weight_plan <- function(hts_as_of_dates = NULL, revisions = NULL,
                                       weight_mode = NULL, weight_method = NULL,
                                       base_path = NULL, shares_path = NULL,
                                       crosswalk_path = NULL, overrides_path = NULL) {
  lp <- load_local_paths()
  weight_mode   <- weight_mode   %||% (lp$weight_mode %||% 'required')
  weight_method <- weight_method %||% (lp$weight_method %||% '484f')

  if (identical(weight_mode, 'unweighted')) {
    return(list(weight_mode = 'unweighted', weight_method = weight_method,
                imports = NULL, imports_fn = NULL,
                hts_as_of_dates = NULL, weight_context = NULL))
  }

  if (identical(weight_method, 'static')) {
    imports <- load_import_weights(weight_mode = 'required')
    return(list(weight_mode = 'weighted', weight_method = 'static',
                imports = imports, imports_fn = NULL,
                hts_as_of_dates = NULL, weight_context = NULL))
  }

  # 484f (default): per-interval mapping.
  base_path      <- base_path      %||% lp$import_weights
  shares_path    <- shares_path    %||% lp$split_share_imports
  crosswalk_path <- crosswalk_path %||% here::here('resources', 'hts10_484f_transfers.csv')
  overrides_path <- overrides_path %||% here::here('resources', 'hts10_484f_overrides.csv')
  if (is.null(base_path) || !nzchar(base_path) || !file.exists(base_path)) {
    stop(weight_resolution_error(
      paste0('weight_method="484f" base file not found: ', base_path %||% '<unset>'),
      context = 'load'))
  }
  if (is.null(crosswalk_path) || !file.exists(crosswalk_path)) {
    stop('weight_method="484f" requires the transfers crosswalk: ',
         crosswalk_path %||% '<unset>',
         '\n  Generate it with: Rscript tools/build_484f_crosswalk.R', call. = FALSE)
  }
  if (!is.null(shares_path) && !file.exists(shares_path)) shares_path <- NULL
  if (!is.null(overrides_path) && !file.exists(overrides_path)) overrides_path <- NULL

  imports_fn <- make_interval_weights_fn(base_path, crosswalk_path,
                                         shares_path, overrides_path)

  if (is.null(hts_as_of_dates) && !is.null(revisions)) {
    hts_as_of_dates <- hts_as_of_dates_from_timeline(
      tibble::tibble(revision = as.character(revisions)))
  }
  weight_context <- if (!is.null(hts_as_of_dates)) {
    list(shared = attr(imports_fn, 'shared_fingerprint'),
         hts_as_of_dates = hts_as_of_dates)
  } else NULL

  list(weight_mode = 'weighted', weight_method = '484f',
       imports = NULL, imports_fn = imports_fn,
       hts_as_of_dates = hts_as_of_dates, weight_context = weight_context)
}


#' Build and (optionally) write the panel-keyed import-weight file for a vintage.
#'
#' @param method '484f' (default; authoritative dated transfers) or 'prefix'
#'   (legacy Jaccard prefix cascade — kept for A/B and regression).
#' @param crosswalk_path committed 484(f) transfers CSV (required for 484f).
#' @param shares_path 2025 split-share base .rds (optional; enables tiers i/ii).
#' @param overrides_path committed override CSV — recorded for provenance only
#'   (already applied to the committed transfers CSV).
#' @param hts_as_of_date HTS-identity date bounding which transfers apply
#'   (required for 484f; NEVER defaulted to Sys.Date()).
build_panel_import_weights <- function(panel_codes, base_path, out_dir,
                                       year = 2024L, hts_vintage = NA_character_,
                                       method = c('484f', 'prefix'),
                                       crosswalk_path = NULL, shares_path = NULL,
                                       overrides_path = NULL, hts_as_of_date = NULL,
                                       write_csv = TRUE, write_crosswalk = TRUE,
                                       dry_run = FALSE) {
  method <- match.arg(method)
  if (!requireNamespace('arrow', quietly = TRUE)) {
    stop('build_panel_import_weights requires the arrow package (parquet write).',
         call. = FALSE)
  }

  base <- load_weight_base(base_path)
  panel_set <- unique(as.character(panel_codes))
  total_in <- sum(base$imports)
  country_in <- base %>% group_by(cty_code) %>%
    summarise(v = sum(imports), .groups = 'drop')

  if (method == '484f') {
    if (is.null(crosswalk_path)) {
      stop('method="484f" requires crosswalk_path.', call. = FALSE)
    }
    if (is.null(hts_as_of_date)) {
      stop('method="484f" requires hts_as_of_date (the snapshot HTS-identity ',
           'date); it is never defaulted to Sys.Date().', call. = FALSE)
    }
    xwalk  <- load_484f_transfers(crosswalk_path)
    shares <- if (!is.null(shares_path)) load_split_shares(shares_path) else NULL
    mapped <- crosswalk_map_imports(base, panel_set, xwalk, shares, hts_as_of_date)
  } else {
    mapped <- forward_map_imports(base, panel_set)
  }
  st <- mapped$stats

  # --- shared hard validation (adds per-country conservation) ----------------
  # The whole-panel global fallback is prohibited only for the authoritative
  # 484f method; the legacy prefix cascade may still use it as a last resort.
  validate_mapped_weights(mapped$weights, panel_set, country_in, total_in,
                          n_global_fallback = if (method == '484f')
                            (st$n_global_fallback %||% 0L) else 0L)

  # --- production residual thresholds (484f) --------------------------------
  # Set from the tip A/B (2024 base -> 2026-07-01 panel, full transfers +
  # 2025 shares): identity 91.0%, even_fallback 6.7%, country_2025 2.05%,
  # prefix cascade 0.22% (all HS4/HS6, 249 codes), 0 global. The "we don't know
  # which sibling" residual (prefix cascade + global) is the tight gate; even
  # splitting is within-HS8 (statistical suffixes share the HS8 duty), so it is
  # rate-neutral and only monitored generously.
  if (method == '484f') {
    src_pct <- st$per_source %>% mutate(pct = 100 * value / max(total_in, 1))
    pct_of <- function(rx) sum(src_pct$pct[grepl(rx, src_pct$share_source)])
    cascade_pct <- pct_of('^prefix_cascade')
    even_pct    <- pct_of('^even_fallback')
    if (cascade_pct > CROSSWALK_MAX_CASCADE_PCT) {
      stop(sprintf('484f residual prefix cascade is %.2f%% of value (> %.2f%% threshold) — investigate coverage.',
                   cascade_pct, CROSSWALK_MAX_CASCADE_PCT), call. = FALSE)
    }
    if (even_pct > CROSSWALK_MAX_EVEN_PCT) {
      warning(sprintf('484f even-split fallback is %.2f%% of value (> %.2f%% soft threshold): %s',
                      even_pct, CROSSWALK_MAX_EVEN_PCT,
                      'within-HS8 and rate-neutral, but review if this jumped.'), call. = FALSE)
    }
  }

  weights_out <- mapped$weights %>%
    rename(country = cty_code) %>%
    mutate(import_value_year = as.integer(year),
           hts_vintage       = as.character(hts_vintage)) %>%
    select(hts10, country, imports, import_value_year, hts_vintage)

  # --- report ---------------------------------------------------------------
  message(sprintf('  method             : %s', method))
  message(sprintf('  panel codes        : %s', format(length(panel_set), big.mark = ',')))
  if (method == '484f') {
    message(sprintf('  hts_as_of_date     : %s  (%d transfer dates applied)',
                    st$hts_as_of_date, st$n_transfer_dates))
    message('  value by share_source:')
    for (i in seq_len(nrow(st$per_source))) {
      message(sprintf('      %-32s $%.2fB', st$per_source$share_source[i],
                      st$per_source$value[i] / 1e9))
    }
    if (nrow(st$cascade_stats) > 0) {
      message('  residual prefix cascade:')
      for (i in order(-st$cascade_stats$level)) {
        message(sprintf('      level %d: %d codes  $%.2fB',
                        st$cascade_stats$level[i], st$cascade_stats$n_codes[i],
                        st$cascade_stats$value[i] / 1e9))
      }
    }
  } else {
    message(sprintf('  exact 10-digit     : %.2f%% of value', st$matched_value_pct))
    message(sprintf('  orphan codes       : %s  ($%.1fB) redistributed by prefix',
                    format(st$n_orphan_codes, big.mark = ','), st$orphan_value / 1e9))
  }
  if ((st$n_global_fallback %||% 0L) > 0) {
    message(sprintf('  NOTE: %d code(s) hit the whole-panel fallback.', st$n_global_fallback))
  }
  message(sprintf('  output rows        : %s  | total $%.1fB (conserved)',
                  format(st$n_weight_rows, big.mark = ','), st$total_out / 1e9))

  files <- character()
  if (!dry_run) {
    dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
    pq <- file.path(out_dir, 'import_weights_hs10_country.parquet')
    arrow::write_parquet(weights_out, pq, compression = 'zstd', compression_level = 5L)
    files <- c(files, pq)
    message('  wrote ', pq)

    if (write_csv) {
      csv <- file.path(out_dir, 'import_weights_hs10_country.csv.gz')
      readr::write_csv(weights_out, csv)   # .gz extension -> gzip-compressed
      files <- c(files, csv)
      message('  wrote ', csv)
    }
    if (write_crosswalk) {
      xw <- file.path(out_dir, 'hts10_revision_crosswalk.csv')
      readr::write_csv(mapped$crosswalk, xw)
      files <- c(files, xw)
      message('  wrote ', xw, ' (', nrow(mapped$crosswalk), ' remapped rows)')
      if (method == '484f') {
        # Country-specific composed map — the artifact that actually reproduces
        # the allocation (the country-agnostic crosswalk above is a summary).
        cbc <- file.path(out_dir, 'crosswalk_composed_by_country.csv.gz')
        readr::write_csv(mapped$composed %>%
                           mutate(method = method, hts_vintage = as.character(hts_vintage)), cbc)
        files <- c(files, cbc)
        ea <- file.path(out_dir, 'crosswalk_edges_applied.csv')
        readr::write_csv(mapped$edges_applied, ea)
        files <- c(files, ea)
        message('  wrote ', cbc, ' + ', ea)
      }
    }
  }

  invisible(list(files = files, weights = weights_out,
                 crosswalk = mapped$crosswalk, composed = mapped$composed,
                 edges_applied = mapped$edges_applied, stats = st))
}


# =============================================================================
# CLI
# =============================================================================

.bpiw_print_help <- function() {
  cat('Usage: Rscript src/io/build_panel_import_weights.R --vintage-dir <DIR> [options]\n\n')
  cat('Re-key the 2024 import-weight base onto a published vintage\'s panel codes.\n\n')
  cat('Options:\n')
  cat('  --vintage-dir <DIR>  Published vintage dir (reads <DIR>/actual/snapshots). Required.\n')
  cat('  --out-dir <DIR>      Where to write. Default: <vintage-dir>/weights\n')
  cat('  --base <PATH>        Import-weight base RDS. Default: auto-detect data/weights/.\n')
  cat('  --year <YYYY>        Import-value calendar year stamp. Default: 2024\n')
  cat('  --method <M>         484f (default, authoritative dated transfers) or prefix (legacy).\n')
  cat('  --crosswalk <PATH>   484(f) transfers CSV. Default: resources/hts10_484f_transfers.csv\n')
  cat('  --shares <PATH>      2025 split-share base RDS. Default: data/weights/hs10_by_country_2025_con.rds\n')
  cat('  --hts-as-of-date <D> HTS-identity date bounding transfers. Default: tip revision date.\n')
  cat('  --no-csv             Skip the .csv.gz sibling (parquet only).\n')
  cat('  --no-crosswalk       Skip the crosswalk / composed / edges-applied audit files.\n')
  cat('  --dry-run            Compute + validate, write nothing.\n')
  cat('  -h, --help           Show this message.\n')
}

#' Resolve a revision id to its RAW HTS-identity date from revision_dates.csv.
.hts_identity_date <- function(revision, csv = here::here('config', 'revision_dates.csv')) {
  if (is.na(revision) || !file.exists(csv)) return(NA_character_)
  d <- readr::read_csv(csv, col_types = readr::cols(revision = readr::col_character(),
                                                    effective_date = readr::col_date(),
                                                    .default = readr::col_guess()))
  hit <- d$effective_date[d$revision == revision]
  if (length(hit) == 0) NA_character_ else as.character(hit[1])
}

if (sys.nframe() == 0) {
  argv <- commandArgs(trailingOnly = TRUE)

  if (any(argv %in% c('-h', '--help'))) { .bpiw_print_help(); quit(status = 0) }

  get_opt <- function(flag, default = NULL) {
    i <- match(flag, argv)
    if (is.na(i)) return(default)
    if (i == length(argv)) stop('Missing value for ', flag, call. = FALSE)
    argv[i + 1L]
  }

  vintage_dir <- get_opt('--vintage-dir')
  if (is.null(vintage_dir)) {
    .bpiw_print_help()
    stop('--vintage-dir is required.', call. = FALSE)
  }
  out_dir  <- get_opt('--out-dir', file.path(vintage_dir, 'weights'))
  year     <- as.integer(get_opt('--year', '2024'))
  method   <- get_opt('--method', '484f')
  xwalk_path  <- get_opt('--crosswalk', here::here('resources', 'hts10_484f_transfers.csv'))
  shares_arg  <- get_opt('--shares', here::here('data', 'weights', 'hs10_by_country_2025_con.rds'))
  shares_path <- if (!is.null(shares_arg) && file.exists(shares_arg)) shares_arg else NULL
  asof_arg <- get_opt('--hts-as-of-date')
  dry_run  <- '--dry-run'      %in% argv
  no_csv   <- '--no-csv'       %in% argv
  no_xwalk <- '--no-crosswalk' %in% argv

  # Resolve the base: explicit --base wins, else the autodetect used by the
  # build (data/weights/hs10_by_country_gtap_*_con.rds), else the canonical path.
  base_path <- get_opt('--base')
  if (is.null(base_path) && requireNamespace('here', quietly = TRUE)) {
    tryCatch(source(here::here('src', 'model', 'policy_params.R')),
             error = function(e) NULL)   # for autodetect_import_weights()
    if (exists('autodetect_import_weights', mode = 'function')) {
      base_path <- tryCatch(autodetect_import_weights(), error = function(e) NULL)
    }
    if (is.null(base_path)) {
      cand <- here::here('data', 'weights',
                         sprintf('hs10_by_country_gtap_%d_con.rds', year))
      if (file.exists(cand)) base_path <- cand
    }
  }

  snaps_dir <- if (exists('actual_snapshots_dir', mode = 'function')) {
    actual_snapshots_dir(vintage_dir)
  } else {
    file.path(vintage_dir, 'actual', 'snapshots')
  }

  message('=== build_panel_import_weights ===')
  message('  vintage-dir : ', vintage_dir)
  message('  snapshots   : ', snaps_dir)
  message('  base        : ', base_path %||% '<unresolved>')
  message('  out-dir     : ', out_dir, if (dry_run) '  (DRY RUN)' else '')

  panel_codes <- current_panel_codes(snaps_dir)
  hts_vintage <- tip_revision_from_snapshots(snaps_dir)
  # For 484f, the transfer window ends at the tip revision's HTS-identity date
  # (raw effective_date), unless overridden explicitly.
  hts_as_of <- if (method == '484f') {
    asof_arg %||% .hts_identity_date(hts_vintage)
  } else NULL
  if (method == '484f') {
    message('  crosswalk   : ', xwalk_path)
    message('  shares      : ', shares_path %||% '<none — tiers i/ii disabled>')
    message('  hts_as_of   : ', hts_as_of %||% '<unresolved>')
  }

  build_panel_import_weights(
    panel_codes     = panel_codes,
    base_path       = base_path,
    out_dir         = out_dir,
    year            = year,
    hts_vintage     = hts_vintage,
    method          = method,
    crosswalk_path  = if (method == '484f') xwalk_path else NULL,
    shares_path     = shares_path,
    hts_as_of_date  = hts_as_of,
    write_csv       = !no_csv,
    write_crosswalk = !no_xwalk,
    dry_run         = dry_run
  )
  message('done.')
}
