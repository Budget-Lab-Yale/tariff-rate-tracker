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
build_panel_import_weights <- function(panel_codes, base_path, out_dir,
                                       year = 2024L, hts_vintage = NA_character_,
                                       write_csv = TRUE, write_crosswalk = TRUE,
                                       dry_run = FALSE) {
  if (!requireNamespace('arrow', quietly = TRUE)) {
    stop('build_panel_import_weights requires the arrow package (parquet write).',
         call. = FALSE)
  }

  base <- load_weight_base(base_path)
  mapped <- forward_map_imports(base, panel_codes)
  st <- mapped$stats

  # --- hard validation: the two acceptance criteria that must always hold ---
  if (!isTRUE(st$all_on_panel)) {
    stop('forward-map produced codes outside the panel universe — bug.', call. = FALSE)
  }
  # Value conservation: total out == total in (allow float rounding only).
  rel_err <- abs(st$total_out - st$total_in) / max(st$total_in, 1)
  if (rel_err > 1e-9) {
    stop(sprintf('forward-map lost value: in $%.4fB vs out $%.4fB (rel err %.2e).',
                 st$total_in / 1e9, st$total_out / 1e9, rel_err), call. = FALSE)
  }
  if (anyDuplicated(mapped$weights[c('hts10', 'cty_code')]) > 0) {
    stop('forward-map produced duplicate (hts10, country) keys — bug.', call. = FALSE)
  }

  weights_out <- mapped$weights %>%
    rename(country = cty_code) %>%
    mutate(import_value_year = as.integer(year),
           hts_vintage       = as.character(hts_vintage)) %>%
    select(hts10, country, imports, import_value_year, hts_vintage)

  # --- report ---------------------------------------------------------------
  message(sprintf('  panel codes        : %s', format(st$n_panel_codes, big.mark = ',')))
  message(sprintf('  base pairs         : %s  (%s codes, %s exact-match)',
                  format(st$n_base_pairs, big.mark = ','),
                  format(st$n_matched_codes + st$n_orphan_codes, big.mark = ','),
                  format(st$n_matched_codes, big.mark = ',')))
  message(sprintf('  exact 10-digit     : %.2f%% of value', st$matched_value_pct))
  message(sprintf('  orphan codes       : %s  ($%.1fB) redistributed by prefix:',
                  format(st$n_orphan_codes, big.mark = ','), st$orphan_value / 1e9))
  if (nrow(st$per_level) > 0) {
    lvl_name <- c('0' = 'whole-panel', '2' = 'HS2 chapter', '4' = 'HS4 heading',
                  '6' = 'HS6 subheading', '8' = 'HS8 heading')
    for (i in order(-st$per_level$level)) {
      L <- as.character(st$per_level$level[i])
      message(sprintf('      %-15s: %4d codes  $%.2fB',
                      lvl_name[[L]] %||% paste0('L', L),
                      st$per_level$n_codes[i], st$per_level$value[i] / 1e9))
    }
  }
  if (st$n_global_fallback > 0) {
    message(sprintf('  NOTE: %d code(s) shared no HTS prefix with the panel — split whole-panel.',
                    st$n_global_fallback))
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
      message('  wrote ', xw, ' (', nrow(mapped$crosswalk), ' remapped suffix rows)')
    }
  }

  invisible(list(files = files, weights = weights_out,
                 crosswalk = mapped$crosswalk, stats = st))
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
  cat('  --no-csv             Skip the .csv.gz sibling (parquet only).\n')
  cat('  --no-crosswalk       Skip the hts10_revision_crosswalk.csv audit file.\n')
  cat('  --dry-run            Compute + validate, write nothing.\n')
  cat('  -h, --help           Show this message.\n')
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

  build_panel_import_weights(
    panel_codes     = panel_codes,
    base_path       = base_path,
    out_dir         = out_dir,
    year            = year,
    hts_vintage     = hts_vintage,
    write_csv       = !no_csv,
    write_crosswalk = !no_xwalk,
    dry_run         = dry_run
  )
  message('done.')
}
