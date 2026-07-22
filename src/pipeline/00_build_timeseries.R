# =============================================================================
# Step 00: Build Tariff Rate Time Series
# =============================================================================
#
# Main orchestrator: iteratively processes HTS revisions to build a time series
# of tariff rates. Supports full backfill, incremental updates, and auto-update.
# After building, runs downstream scripts (daily series and quality report).
#
# Usage:
#   Rscript src/pipeline/00_build_timeseries.R              # Auto-update (default)
#   Rscript src/pipeline/00_build_timeseries.R --full        # Full rebuild from scratch
#   Rscript src/pipeline/00_build_timeseries.R --start-from rev_25  # Explicit incremental
#   Rscript src/pipeline/00_build_timeseries.R --build-only  # Skip downstream (daily/quality)
#   Rscript src/pipeline/00_build_timeseries.R --core-only  # Build + downstream, but skip weighted outputs
#   Rscript src/pipeline/00_build_timeseries.R --unweighted  # Opt out of weighted outputs for this run
#                                                   # (alternative to setting weight_mode in config/local_paths.yaml)
#   Rscript src/pipeline/00_build_timeseries.R --alternatives all   # Also run every registered alternative + counterfactual
#   Rscript src/pipeline/00_build_timeseries.R --alternatives no_301,metal_flat  # Run specific scenarios by name
#   Rscript src/pipeline/00_build_timeseries.R --alternatives counterfactuals    # Run all kind=counterfactual scenarios
#   Rscript src/pipeline/00_build_timeseries.R --alternatives counterfactuals --alternatives-only
#   Rscript src/pipeline/00_build_timeseries.R --refresh-usmca     # Re-download USMCA shares from DataWeb API
#   (output is written to the model-data interface automatically by the gather —
#    config: model_data_root; no --publish step. See scripts/build_gather.R.)
#   Rscript src/pipeline/00_build_timeseries.R --publish-git      # After build, write dated public outputs to release/ in the repo
#   Rscript src/pipeline/00_build_timeseries.R --skip-release-check # Bypass the HTS release-currency gate
#
# HTS release-currency gate (Step A2): before building, the run compares local
# archives against USITC's release list. Up to date or exactly one release behind
# (the current release missing) -> proceed (Step B auto-fetches the current release
# via the reststop export endpoint). More than one release behind -> STOP, because
# the older missing revision(s) cannot be auto-downloaded (the static archive host
# is blocked) and must be fetched manually into data/hts_archives/. Bypass with
# --skip-release-check (e.g., offline runs).
#
# Scenario names come from the config/scenarios registry (one folder per
# scenario: meta.yaml + overlay.yaml; see src/model/scenario_registry.R).
#   kind=alternative:    usmca_annual, usmca_monthly, usmca_2024, usmca_dec2025,
#                        metal_flat, dutyfree_nonzero, subdivision_r_mid
#   kind=counterfactual: no_ieepa, no_ieepa_recip, no_301, no_232, no_s122,
#                        pre_2025
#   kind=scenario (forced_labor, new_301) build as full series via
#   TARIFF_SCENARIO=<name>, not through --alternatives.
#
# Parallel mode (Phase 0/1):
#   --parallel             Enable parallel mode (off by default)
#   --workers N            Per-revision worker count (Phase 3, currently no-op)
#   --alt-workers M        Concurrent rebuild alternatives (Phase 1, active)
#   --backend B            'multisession' (default) or 'multicore' (Linux only)
#
# Storage layout:
#   data/timeseries/
#     metadata.rds                # last_revision, last_build_time
#     snapshot_basic.rds          # rates for baseline
#     snapshot_rev_1.rds          # rates for rev_1
#     ...
#     delta_rev_1.rds             # changes from basic -> rev_1
#     ch99_rev_32.rds             # cached parse (for incremental start)
#     products_rev_32.rds
#     rate_timeseries.rds         # final combined long-format
#     validation_rev_6.rds        # TPC comparison at rev_6
#
# =============================================================================

library(tidyverse)
library(jsonlite)
library(here)

# Source pipeline components
source(here('src', 'core', 'logging.R'))
source(here('src', 'core', 'helpers.R'))
source(here('src', 'core', 'parallel.R'))
source(here('src', 'pipeline', '01_scrape_revision_dates.R'))
source(here('src', 'pipeline', '02_download_hts.R'))
source(here('src', 'pipeline', '03_parse_chapter99.R'))
source(here('src', 'pipeline', '04_parse_products.R'))
source(here('src', 'pipeline', '05_parse_policy_params.R'))
source(here('src', 'pipeline', '06_calculate_rates.R'))
source(here('src', 'model', 'authority_spec.R'))      # AuthoritySpec datatype
source(here('src', 'model', 'authority_adapter.R'))   # build_authority_specs() (Phase 1)
source(here('src', 'pipeline', '07_validate_tpc.R'))
source(here('src', 'pipeline', 'revision_snapshot.R'))


#' Mint synthetic boundary snapshots from discovered schedule boundaries.
#'
#' Given the boundary table from discover_boundaries() (src/model/timeline.R), recompute
#' each boundary's OWNING revision archive STAMPED at the boundary date — a pure
#' as-of recompute — writing one synthetic `bnd_<date>` snapshot per boundary and
#' appending a `{revision, effective_date}` row to rev_dates.
#' assemble_timeseries() then derives the new [D, next] interval from rev_dates
#' ordering and auto-shortens the owning interval to D-1 — so the rate switches on
#' the legal effective date D rather than at the next real revision. The calculator
#' needs no change: its own date gates (Ch99 offset / IEEPA invalidation / §232
#' country-exemption expiry) re-resolve as-of D during the recompute.
#'
#' Notes:
#'   - arbitrary `archive_rev_id` (the OWNER of the interval containing D), not the
#'     tip — a boundary can sit anywhere in the timeline.
#'   - the change is the as-of date itself; the recompute applies no mutation.
#'   - `bnd_` prefix — and BASELINE-eligible: boundary mints belong in the baseline
#'     panel/reference, so the re-freeze capture must EXPECT exactly the discovered set.
#'     (R5 safety net: scripts/summarize_parity_results.R fails the parity run on
#'     ANY reference-only OR candidate-only artifact, so a stale reference missing the
#'     `bnd_` snapshots — or an unexpected synthetic snapshot — turns parity RED.)
#'   - re-mints by default (DETERMINISTIC, not skip-if-exists): discover_boundaries
#'     re-derives the set every build and we always recompute, so a code/config
#'     change is always reflected (no stale on-disk bnd_ snapshot). The in-loop
#'     `bid %in% rev_dates$revision` guard only de-dups WITHIN a single rev_dates
#'     (it never fires across builds — rev_dates is reloaded from the CSV, which
#'     carries no `bnd_` rows). Re-minting 3 small snapshots is cheap vs the array.
#'
#' Empty/absent boundaries => writes nothing and returns rev_dates unchanged.
#'
#' @param boundaries discover_boundaries() output (tibble of date/owner_rev/revision/source).
#' @return rev_dates with one row appended per minted boundary (unchanged if none).
build_boundary_mints <- function(rev_dates, boundaries, pp_build, output_dir,
                                 country_lookup, countries, census_codes,
                                 archive_dir = 'data/hts_archives',
                                 stacking_method = 'mutual_exclusion',
                                 tpc_path = NULL) {
  if (is.null(boundaries) || nrow(boundaries) == 0) return(rev_dates)

  message('\n', strrep('=', 60))
  message('Minting ', nrow(boundaries), ' boundary snapshot(s)')

  new_rows <- vector('list', nrow(boundaries))
  for (k in seq_len(nrow(boundaries))) {
    bid   <- boundaries$revision[k]
    D     <- as.Date(boundaries$date[k])
    owner <- boundaries$owner_rev[k]
    src   <- boundaries$source[k] %||% ''
    if (!startsWith(bid, 'bnd_')) {
      stop("build_boundary_mints: id '", bid, "' must start with 'bnd_' ",
           '(provenance: synthetic boundary mints must be distinguishable from ',
           'real HTS revisions).')
    }
    if (length(D) != 1 || is.na(D)) {
      stop("build_boundary_mints '", bid, "': invalid boundary date.")
    }
    if (is.na(owner) || !nzchar(owner)) {
      stop("build_boundary_mints '", bid, "': no owner revision resolved.")
    }
    if (bid %in% rev_dates$revision) {
      # Within-run de-dup only (a colliding id, or a caller that pre-seeded the
      # row). Across builds this never fires — rev_dates is reloaded from the CSV,
      # which has no bnd_ rows — so the normal path always recomputes (intended:
      # the snapshot then reflects current code/config; see fn docstring).
      message('  [bnd] ', bid, ' already in rev_dates — skipping')
      next
    }

    message('  [bnd] ', bid, ' = owner ', owner, ' stamped at ', D,
            ' (', src, ')')
    build_revision_snapshot(
      rev_id = bid, eff_date = D, tpc_date = NA,
      archive_rev_id = owner,
      archive_dir = archive_dir, output_dir = output_dir,
      country_lookup = country_lookup, countries = countries,
      census_codes = census_codes, pp_build = pp_build,
      stacking_method = stacking_method, tpc_path = tpc_path
    )
    new_rows[[k]] <- tibble(revision = bid, effective_date = D)
  }

  bound <- dplyr::bind_rows(new_rows)
  if (nrow(bound) == 0) return(rev_dates)
  dplyr::bind_rows(rev_dates, bound)
}

save_synthetic_revision_dates <- function(rev_dates, output_dir) {
  synth <- rev_dates %>%
    filter(grepl('^(sched_|bnd_)', revision)) %>%
    filter(file.exists(file.path(output_dir, paste0('snapshot_', revision, '.rds')))) %>%
    arrange(effective_date) %>%
    select(revision, effective_date, everything())
  path <- file.path(output_dir, 'synthetic_revisions.rds')
  if (nrow(synth) > 0) {
    saveRDS(synth, path)
  } else if (file.exists(path)) {
    unlink(path)
  }
  synth
}

build_array_revision_timeline <- function(rev_dates, pp_build,
                                          archive_dir = 'data/hts_archives',
                                          horizon = NULL) {
  horizon <- as.Date(horizon %||% pp_build$SERIES_HORIZON_END %||% Sys.Date())
  available <- get_available_revisions_all_years(rev_dates$revision, archive_dir)
  real <- rev_dates %>%
    filter(revision %in% available) %>%
    arrange(effective_date) %>%
    mutate(
      archive_rev_id = revision,
      source = 'real'
    )
  if (nrow(real) == 0) stop('No available real revisions found in ', archive_dir)

  boundaries <- discover_boundaries(
    real,
    snapshot_dir = NULL,
    policy_params = pp_build,
    overrides = pp_build$BOUNDARY_OVERRIDES,
    horizon = horizon,
    archive_dir = archive_dir
  )
  bnd <- if (nrow(boundaries) > 0) {
    boundaries %>%
      transmute(
        revision,
        effective_date = as.Date(date),
        tpc_date = as.Date(NA),
        archive_rev_id = owner_rev,
        source = 'boundary'
      )
  } else {
    tibble(
      revision = character(), effective_date = as.Date(character()),
      tpc_date = as.Date(character()), archive_rev_id = character(),
      source = character()
    )
  }

  out <- bind_rows(
    real %>% select(any_of(c('revision', 'effective_date', 'tpc_date')),
                    archive_rev_id, source),
    bnd
  ) %>%
    mutate(effective_date = as.Date(effective_date),
           tpc_date = as.Date(tpc_date)) %>%
    arrange(effective_date, revision)

  dup <- out$revision[duplicated(out$revision)]
  if (length(dup) > 0) {
    stop('Duplicate revision id(s) in build timeline: ',
         paste(unique(dup), collapse = ', '))
  }
  out
}


#' Assemble per-revision snapshots into the combined timeseries.
#'
#' Binds every snapshot_<rev>.rds in `output_dir`, enforces the schema, adds the
#' valid_from/valid_until intervals from revision ordering, and writes
#' rate_timeseries.rds (+ parquet sibling) and metadata.rds. Shared by the serial
#' build (build_full_timeseries) and the array gather step so both produce a
#' byte-for-byte equivalent timeseries from the same snapshots.
#'
#' @param last_successful_rev metadata's last_revision; if NULL, derived from the
#'   latest revision present in the snapshots (by effective_date).
#' @return list(metadata, timeseries_path, output_dir)
assemble_timeseries <- function(output_dir, rev_dates, pp_build,
                                last_successful_rev = NULL, scenario = 'baseline',
                                expected_revisions = NULL, allow_partial = FALSE) {
  message('\n', strrep('=', 60))
  message('Combining snapshots into time series...')

  # Load all snapshot files (including pre-existing from incremental)
  all_snapshot_files <- list.files(output_dir, pattern = '^snapshot_.*\\.rds$', full.names = TRUE)
  # Revision ids present on disk, derived once from the (immutable) file list and
  # reused by the completeness/orphan gates below.
  revs_on_disk <- sub('^snapshot_', '', tools::file_path_sans_ext(basename(all_snapshot_files)))

  # Completeness gate (Finding 3): if the caller declares which revisions it
  # expected this run, fail loud when any are missing from disk — a dropped
  # *middle* revision is otherwise invisible (the interval encoding stretches
  # the prior revision over the gap, reading as policy stability). The check is
  # opt-in (expected_revisions = NULL => skip), and when every expected revision
  # is present (the normal case) `missing_revs` is empty and this is a no-op —
  # no stop(), no behavior change, byte-identical output. Compare against
  # revision *ids* present on disk, mirroring how the timeseries is assembled.
  if (!is.null(expected_revisions)) {
    missing_revs <- setdiff(expected_revisions, revs_on_disk)
    if (length(missing_revs) > 0 && !allow_partial) {
      stop('assemble_timeseries: ', length(missing_revs), ' of ',
           length(expected_revisions),
           ' expected revision(s) have no snapshot on disk: ',
           paste(missing_revs, collapse = ', '),
           '. The assembled panel would silently stretch a neighbouring ',
           'revision over the gap. Pass allow_partial = TRUE to assemble anyway.')
    }
    if (length(missing_revs) > 0) {
      warning('assemble_timeseries: assembling PARTIAL panel (allow_partial = TRUE) — ',
              length(missing_revs), ' expected revision(s) missing: ',
              paste(missing_revs, collapse = ', '))
    }
  }

  # Orphan gate (mirror of the completeness gate): a snapshot on disk whose
  # revision id has no row in rev_dates would assemble into the panel but get
  # NA valid_from/valid_until from the interval join — poisoning downstream
  # date-range logic (min(valid_from) in the daily series). This happened with
  # a stale snapshot_2026_rev_8.rds left over after rev_8 was excluded from
  # revision_dates.csv (2026-06-08 build carried 4.8M NA-interval rows).
  # rev_dates includes synthetic bnd_/sched_ rows by this point, so any
  # mismatch is a genuinely stale or foreign file: fail loud and name it.
  orphan_revs <- setdiff(revs_on_disk, rev_dates$revision)
  if (length(orphan_revs) > 0) {
    stop('assemble_timeseries: ', length(orphan_revs),
         ' snapshot(s) on disk have no revision_dates row: ',
         paste(orphan_revs, collapse = ', '),
         '. They would enter the panel with NA valid_from/valid_until. ',
         'Delete the stale snapshot_*.rds (and matching ch99_/products_/delta_ ',
         'files) from ', output_dir, ' or add the revision to revision_dates.csv.')
  }

  # Streaming fill instead of rbindlist. The full panel is ~210M rows x 33
  # cols (~50 GB in memory) after the 2026-06-04 universe expansion; rbindlist
  # requires the list of all snapshots AND the bound result to coexist
  # (~2x panel), which OOMs even at high memory. Instead: pass 1 collects row
  # counts and a typed column template (union across snapshots, each enforced to
  # the canonical schema on read); pass 2 pre-allocates the full table ONCE and
  # copies each snapshot into its row block by reference, freeing it
  # immediately. Peak memory = one panel + one snapshot. Columns absent from
  # older snapshots stay NA, matching the previous rbindlist(fill = TRUE)
  # semantics. All subsequent steps (ordering, interval join) are in place / by
  # reference; the handoff back to tibble at the end is zero-copy.
  read_snapshot <- function(f) {
    tryCatch(enforce_rate_schema(readRDS(f)), error = function(e) {
      warning('Failed to read snapshot: ', f, ' -- ', e$message)
      NULL
    })
  }

  # Pass 1: row counts + typed column template
  n_rows <- integer(length(all_snapshot_files))
  col_proto <- list()
  for (i in seq_along(all_snapshot_files)) {
    snap <- read_snapshot(all_snapshot_files[i])
    if (is.null(snap)) next
    n_rows[i] <- nrow(snap)
    for (cn in names(snap)) {
      if (is.null(col_proto[[cn]])) col_proto[[cn]] <- snap[[cn]][0]
    }
    rm(snap); gc(verbose = FALSE)
  }
  total_n <- sum(n_rows)
  message('  Streaming combine: ', length(all_snapshot_files), ' snapshots, ',
          format(total_n, big.mark = ','), ' rows, ',
          length(col_proto), ' columns')

  # Pass 2: pre-allocate and fill by reference
  timeseries <- data.table::setDT(lapply(col_proto, function(p) rep(p[1], total_n)))
  offset <- 0L
  for (i in seq_along(all_snapshot_files)) {
    if (n_rows[i] == 0L) next
    snap <- read_snapshot(all_snapshot_files[i])
    if (is.null(snap)) next
    idx <- (offset + 1L):(offset + n_rows[i])
    for (cn in names(col_proto)) {
      if (cn %in% names(snap)) {
        data.table::set(timeseries, i = idx, j = cn, value = snap[[cn]])
      }
    }
    offset <- offset + n_rows[i]
    rm(snap); gc(verbose = FALSE)
  }

  # Sort by effective_date, then revision (in place)
  data.table::setorder(timeseries, effective_date, revision, country, hts10)

  # Add temporal intervals (valid_from / valid_until) from revision ordering
  # Final revision extends to configurable horizon (default: 2026-12-31), not Sys.Date()
  horizon_end <- pp_build$SERIES_HORIZON_END %||% Sys.Date()
  # Guard: horizon cannot be earlier than the final revision's effective_date
  last_eff <- max(rev_dates$effective_date[rev_dates$revision %in% unique(timeseries$revision)])
  if (horizon_end < last_eff) {
    warning('series_horizon.end_date (', horizon_end,
            ') is earlier than last revision (', last_eff, '). Using last revision date.')
    horizon_end <- last_eff
  }

  rev_intervals <- rev_dates %>%
    filter(revision %in% unique(timeseries$revision)) %>%
    arrange(effective_date) %>%
    mutate(
      valid_from = effective_date,
      valid_until = lead(effective_date) - 1
    ) %>%
    mutate(valid_until = if_else(is.na(valid_until), horizon_end, valid_until)) %>%
    select(revision, valid_from, valid_until)

  # Attach intervals by reference (an update join — replaces the previous
  # select(-...) %>% left_join(), which copied the full panel twice)
  for (iv_col in c('valid_from', 'valid_until')) {
    if (iv_col %in% names(timeseries)) timeseries[, (iv_col) := NULL]
  }
  ri <- data.table::as.data.table(rev_intervals)
  timeseries[ri, on = 'revision',
             `:=`(valid_from = i.valid_from, valid_until = i.valid_until)]

  # Hand downstream a tibble without copying the column vectors
  data.table::setDF(timeseries)
  timeseries <- tibble::as_tibble(timeseries)

  message('  Added interval columns: valid_from / valid_until')

  ensure_dir(output_dir)
  ts_path <- file.path(output_dir, 'rate_timeseries.rds')
  saveRDS(timeseries, ts_path)
  message('Saved time series: ', ts_path)
  message('  Total rows: ', nrow(timeseries))
  message('  Revisions: ', n_distinct(timeseries$revision))
  if (nrow(timeseries) > 0) {
    message('  Date range: ', min(timeseries$effective_date), ' to ', max(timeseries$effective_date))
  } else {
    warning('Timeseries is empty — all revisions may have failed')
  }

  # Parquet sibling for cross-language consumers (skipped silently when
  # arrow isn't installed). The full panel at production scale is ~195M rows
  # in RDS at ~200 MB; zstd-compressed parquet is typically 30-60 MB.
  parquet_path <- write_parquet_if_arrow(timeseries, ts_path)
  if (!is.null(parquet_path)) {
    message('Saved parquet sibling: ', parquet_path)
  }

  # Derive last_revision from the snapshots when the caller doesn't track it
  # (e.g. the array gather step, which has no in-loop last_successful_rev).
  if (is.null(last_successful_rev)) {
    present <- rev_dates %>%
      filter(revision %in% unique(timeseries$revision)) %>%
      arrange(effective_date)
    last_successful_rev <- if (nrow(present) > 0) present$revision[nrow(present)] else NA_character_
  }

  # ---- Save metadata ----
  metadata <- list(
    last_revision = last_successful_rev,
    last_build_time = Sys.time(),
    n_revisions = n_distinct(timeseries$revision),
    n_rows = nrow(timeseries),
    scenario = scenario
  )
  synth <- save_synthetic_revision_dates(rev_dates, output_dir)
  if (nrow(synth) > 0) {
    metadata$synthetic_revisions <- synth %>%
      select(revision, effective_date) %>%
      mutate(effective_date = as.character(effective_date))
  }
  # Record the completeness reconciliation only when the caller declared an
  # expected set — keeps the metadata shape unchanged in the normal path that
  # doesn't pass expected_revisions.
  if (!is.null(expected_revisions)) {
    metadata$expected_revisions <- expected_revisions
    metadata$skipped_revisions  <- setdiff(expected_revisions, revs_on_disk)
  }
  saveRDS(metadata, file.path(output_dir, 'metadata.rds'))

  return(list(
    metadata = metadata,
    timeseries_path = ts_path,
    output_dir = output_dir
  ))
}


# =============================================================================
# Main Orchestrator
# =============================================================================

#' Build full tariff rate time series
#'
#' Processes HTS revisions sequentially, building rate snapshots at each point.
#' Supports both full backfill and incremental updates.
#'
#' @param archive_dir Directory containing HTS JSON files
#' @param output_dir Directory for time series outputs
#' @param revision_dates_path Path to revision_dates.csv
#' @param census_codes_path Path to census_codes.csv
#' @param tpc_path Path to TPC validation data; defaults to local_paths config
#' @param scenario Scenario name (default: 'baseline')
#' @param start_from NULL for full backfill; revision ID for incremental
#' @param allow_partial If TRUE, assemble the panel even when some attempted
#'   revisions failed to build (default FALSE => fail loud on a missing
#'   revision; Finding 3)
#' @return List with metadata and final timeseries path
build_full_timeseries <- function(
  archive_dir = 'data/hts_archives',
  output_dir = 'data/timeseries',
  revision_dates_path = 'config/revision_dates.csv',
  census_codes_path = 'resources/census_codes.csv',
  tpc_path = NULL,
  scenario = 'baseline',
  start_from = NULL,
  stacking_method = 'mutual_exclusion',
  use_policy_dates = TRUE,
  parallel_cfg = NULL,
  allow_partial = FALSE
) {
  start_time <- Sys.time()

  message('\n', strrep('=', 70))
  message('TARIFF RATE TIME SERIES BUILDER')
  message(strrep('=', 70))
  message('Started: ', start_time)
  message('Mode: ', if (is.null(start_from)) 'Full backfill' else paste('Incremental from', start_from))
  message(strrep('=', 70), '\n')

  # ---- Initialize logging ----
  log_dir <- file.path(Sys.getenv('TARIFF_OUTPUT_DIR', unset = here('output')), 'logs')
  init_logging(
    log_file = file.path(ensure_dir(log_dir),
                         paste0('build_', format(start_time, '%Y%m%d_%H%M%S'), '.log')),
    level = 'info'
  )
  log_info('Build started: ', if (is.null(start_from)) 'full backfill' else paste('from', start_from))
  if (!is.null(parallel_cfg)) log_parallel_config(parallel_cfg)

  # ---- Setup ----
  ensure_dir(output_dir)
  if (is.null(tpc_path)) {
    tpc_path <- load_local_paths()$tpc_benchmark
  }

  # Load revision dates
  rev_dates <- load_revision_dates(revision_dates_path,
                                    use_policy_dates = use_policy_dates)

  # Load one canonical policy object for this build so revision ordering,
  # rate construction, interval creation, and downstream steps share a regime.
  pp_build <- load_policy_params(use_policy_dates = use_policy_dates)

  # Load country codes
  census_codes <- read_csv(census_codes_path, col_types = cols(.default = col_character()))
  countries <- census_codes$Code
  message('Countries: ', length(countries))

  # Build country lookup for IEEPA extraction
  country_lookup <- build_country_lookup(census_codes_path)

  # ---- Determine revision sequence ----
  all_revisions <- rev_dates$revision

  # Filter to revisions that have JSON files available
  available <- get_available_revisions_all_years(all_revisions, archive_dir)

  revisions_to_process <- all_revisions[all_revisions %in% available]
  missing <- all_revisions[!all_revisions %in% available]
  if (length(missing) > 0) {
    message('Skipping revisions without JSON: ', paste(missing, collapse = ', '))
  }

  message('Revisions to process: ', length(revisions_to_process))

  # ---- Handle incremental mode ----
  prev_ch99 <- NULL
  prev_products <- NULL
  start_idx <- 1

  if (!is.null(start_from)) {
    if (!start_from %in% revisions_to_process) {
      stop('start_from revision not found: ', start_from)
    }

    # Load cached state from the start_from revision
    ch99_cache <- file.path(output_dir, paste0('ch99_', start_from, '.rds'))
    prod_cache <- file.path(output_dir, paste0('products_', start_from, '.rds'))

    if (!file.exists(ch99_cache) || !file.exists(prod_cache)) {
      stop('Cached state not found for ', start_from,
           '. Run full backfill first or ensure cache files exist.')
    }

    prev_ch99 <- readRDS(ch99_cache)
    prev_products <- read_products_cache(prod_cache)  # fail loud if pre-flag schema

    # Start from the revision AFTER start_from
    start_idx <- which(revisions_to_process == start_from) + 1

    if (start_idx > length(revisions_to_process)) {
      # No new revisions to iterate, but still rebuild rate_timeseries.rds
      # from existing snapshots and let the caller run downstream — otherwise
      # incremental mode silently skips daily series + alternatives refreshes
      # whenever the tracker is up-to-date.
      message('No new revisions after ', start_from,
              '. Skipping iteration; will rebuild from existing snapshots.')
      revisions_to_process <- character(0)
    } else {
      revisions_to_process <- revisions_to_process[start_idx:length(revisions_to_process)]
      message('Incremental: processing ', length(revisions_to_process),
              ' revisions after ', start_from)
    }
  }

  # ---- Main processing loop ----
  snapshot_paths <- character()
  failed_revisions <- character()
  last_successful_rev <- if (!is.null(start_from)) start_from else NULL
  n_revisions <- length(revisions_to_process)

  cli::cli_progress_bar(
    format = "Processing {cli::pb_current}/{cli::pb_total} [{cli::pb_bar}] {cli::pb_eta} | {rev_id} ({eff_date})",
    total = n_revisions,
    clear = FALSE
  )

  for (i in seq_along(revisions_to_process)) {
    rev_id <- revisions_to_process[i]
    rev_info <- rev_dates %>% filter(revision == rev_id)
    eff_date <- rev_info$effective_date
    tpc_date <- rev_info$tpc_date

    cli::cli_progress_update()

    message('\n', strrep('-', 60))
    message('[', i, '/', n_revisions, '] Processing: ',
            rev_id, ' (effective ', eff_date, ')')
    message(strrep('-', 60))
    log_info('[', i, '/', length(revisions_to_process), '] ', rev_id,
             ' (', eff_date, ')')

    tryCatch({
      # Build this revision's snapshot (parse -> extract -> calc -> save).
      res <- build_revision_snapshot(
        rev_id = rev_id, eff_date = eff_date, tpc_date = tpc_date,
        archive_dir = archive_dir, output_dir = output_dir,
        country_lookup = country_lookup, countries = countries,
        census_codes = census_codes, pp_build = pp_build,
        stacking_method = stacking_method, tpc_path = tpc_path
      )
      ch99_data <- res$ch99_data
      products  <- res$products

      # f. Compute delta from previous revision (serial-only: needs the prior
      #    revision's parse in memory; the array path computes deltas in gather).
      if (!is.null(prev_ch99)) {
        delta <- list(
          ch99 = compare_chapter99(prev_ch99, ch99_data),
          products = compare_products(prev_products, products)
        )
        delta_path <- file.path(output_dir, paste0('delta_', rev_id, '.rds'))
        saveRDS(delta, delta_path)

        message('  Delta: +', delta$ch99$n_added, ' ch99 entries, ',
                '+', delta$products$n_added, ' products, ',
                delta$ch99$n_rate_changes, ' rate changes')
      }

      snapshot_paths <- c(snapshot_paths, res$snapshot_path)

      # Flat CSV consumed by the tariff-rate-tracker-blog repo. Loop iterates
      # oldest -> newest, so the last write lands on the latest processed
      # revision (correct for both --full and incremental modes). ch99_refs is
      # a list-column; flatten to a ';'-joined string for CSV consumers.
      dir.create('data/processed', recursive = TRUE, showWarnings = FALSE)
      products %>%
        mutate(ch99_refs = vapply(ch99_refs, paste,
                                  FUN.VALUE = character(1), collapse = ';')) %>%
        select(hts10, base_rate, base_rate_raw, base_rate_type, ch99_refs,
               n_ch99_refs, description) %>%
        write_csv('data/processed/products_raw.csv')

      # l. Update previous state
      prev_ch99 <- ch99_data
      prev_products <- products

      last_successful_rev <- rev_id
      log_info('  OK: ', res$n_rates, ' product-country rates')

    }, error = function(e) {
      log_error('FAILED: ', rev_id, ' — ', conditionMessage(e))
      message('  ERROR: ', conditionMessage(e))
      message('  Skipping ', rev_id, ' and continuing...')
      failed_revisions <<- c(failed_revisions, rev_id)
    })
  }
  cli::cli_progress_done()

  # Report failures
  if (length(failed_revisions) > 0) {
    log_warn('Failed revisions (', length(failed_revisions), '): ',
             paste(failed_revisions, collapse = ', '))
    message('\nWARNING: ', length(failed_revisions), ' revision(s) failed: ',
            paste(failed_revisions, collapse = ', '))
  }

  # ---- Synthetic boundary mints (unified timeline / P2-1) ----
  # After the real-revision snapshots + their ch99_<rev>.rds caches exist, discover
  # every schedule boundary that falls strictly inside a real interval and that the
  # calc re-resolves on recompute (Ch99 offsets / IEEPA invalidation / §232
  # country-exemption expiries), and mint one `bnd_<date>` snapshot per boundary.
  # assemble_timeseries derives the new interval from rev_dates ordering. Empty
  # discovery => no-op. NOTE: these are NOT fed to the 09 expiry splitter — the
  # mint already creates the interval; feeding it would duplicate the owner.
  boundaries <- discover_boundaries(rev_dates, output_dir, pp_build,
                                    overrides = pp_build$BOUNDARY_OVERRIDES,
                                    horizon = pp_build$SERIES_HORIZON_END)
  rev_dates <- build_boundary_mints(
    rev_dates, boundaries, pp_build, output_dir,
    country_lookup = country_lookup, countries = countries,
    census_codes = census_codes, archive_dir = archive_dir,
    stacking_method = stacking_method, tpc_path = tpc_path)

  # ---- Bind snapshots -> timeseries (+ intervals, parquet, metadata) ----
  # Reconcile the revisions this run attempted (revisions_to_process — already
  # trimmed for incremental mode) against the snapshots on disk, so a revision
  # that errored mid-loop fails the assembly loud rather than silently
  # publishing a panel with a stretched-over gap (Finding 3). Synthetic
  # snapshots are *extra* on disk — the gate only flags MISSING expected revs.
  # NB: assemble_timeseries() performs the memory-streaming snapshot combine
  # (pass-1 row counts + pass-2 fill-by-reference) ported from master — see its
  # definition above. rbindlist OOMs on the ~210M-row post-expansion panel.
  result <- assemble_timeseries(output_dir, rev_dates, pp_build,
                                last_successful_rev = last_successful_rev,
                                scenario = scenario,
                                expected_revisions = revisions_to_process,
                                allow_partial = allow_partial)

  # ---- Write weighted-ETR policy inputs (self-contained build) ----
  # 08_weighted_etr.R loads ieepa_country_rates.csv + usmca_products.csv from
  # data/processed/. These were historically produced only by running 05
  # standalone, so a build without them silently skipped weighted ETR (the
  # downstream call is wrapped in tryCatch). Regenerate them here from the
  # latest processed revision so a --full build is self-contained.
  if (length(revisions_to_process) > 0) {
    latest_rev <- tail(revisions_to_process, 1)
    tryCatch({
      json_path <- resolve_json_path(latest_rev, archive_dir)
      message('\nWriting weighted-ETR policy inputs from ', latest_rev, '...')
      write_policy_inputs(json_path, country_lookup)
    }, error = function(e) {
      message('WARNING: failed to write policy inputs from ', latest_rev, ': ',
              conditionMessage(e))
    })
  }

  # ---- Summary ----
  end_time <- Sys.time()
  elapsed <- round(difftime(end_time, start_time, units = 'mins'), 1)

  message('\n', strrep('=', 70))
  message('TIME SERIES BUILD COMPLETE')
  message(strrep('=', 70))
  message('Elapsed: ', elapsed, ' minutes')
  message('Revisions processed: ', length(revisions_to_process))
  message('Output: ', result$timeseries_path)
  message(strrep('=', 70), '\n')

  return(result)
}


#' Print time series summary by revision
#'
#' @param timeseries_path Path to rate_timeseries.rds
print_timeseries_summary <- function(timeseries_path = 'data/timeseries/rate_timeseries.rds') {
  ts <- readRDS(timeseries_path)

  summary <- ts %>%
    group_by(revision, effective_date) %>%
    summarise(
      n_products = n_distinct(hts10),
      n_countries = n_distinct(country),
      n_rows = n(),
      mean_total_rate = round(mean(total_rate) * 100, 2),
      n_with_ieepa = sum(rate_ieepa_recip > 0),
      n_with_232 = sum(rate_232 > 0),
      n_with_301 = sum(rate_301 > 0),
      .groups = 'drop'
    ) %>%
    arrange(effective_date)

  cat('\n=== Time Series Summary ===\n\n')
  print(summary, n = Inf)

  return(invisible(summary))
}


# =============================================================================
# Auto-Update Detection
# =============================================================================

#' Detect incremental start revision from previous build metadata
#'
#' Reads metadata from last build, checks for new revisions available.
#' Returns the last processed revision (for incremental start), or NULL
#' if no previous build exists (triggers full backfill).
#'
#' @param output_dir Directory containing metadata.rds
#' @param archive_dir Directory containing HTS JSON files
#' @param revision_dates_path Path to revision_dates.csv
#' @return Character revision ID to start from, or NULL for full backfill
detect_incremental_start <- function(
  output_dir = 'data/timeseries',
  archive_dir = 'data/hts_archives',
  revision_dates_path = 'config/revision_dates.csv',
  use_policy_dates = TRUE
) {
  metadata_path <- file.path(output_dir, 'metadata.rds')
  if (!file.exists(metadata_path)) {
    message('No previous build found — full backfill')
    return(NULL)
  }

  metadata <- readRDS(metadata_path)
  last_rev <- metadata$last_revision
  snap_files <- character()
  if (is.null(last_rev) || !nzchar(last_rev)) {
    message('Last build: ', metadata$last_build_time,
            ' (missing last_revision in metadata)')
    snap_files <- list.files(output_dir, pattern = '^snapshot_.*\\.rds$',
                             full.names = FALSE)
  } else {
    message('Last build: ', metadata$last_build_time, ' (', last_rev, ')')
  }

  # Check for new revisions after last_rev
  rev_dates <- load_revision_dates(revision_dates_path,
                                    use_policy_dates = use_policy_dates)
  all_revisions <- rev_dates$revision

  if (is.null(last_rev) || !nzchar(last_rev)) {
    if (length(snap_files) == 0) {
      message('No snapshot files found — full backfill')
      return(NULL)
    }

    built_revs <- sub('^snapshot_', '', tools::file_path_sans_ext(snap_files))
    built_ordered <- rev_dates %>%
      filter(revision %in% built_revs) %>%
      arrange(effective_date)

    if (nrow(built_ordered) == 0) {
      message('Snapshot files did not match revision_dates.csv — full backfill')
      return(NULL)
    }

    last_rev <- built_ordered$revision[nrow(built_ordered)]
    message('Inferred last revision from snapshots: ', last_rev)
  }

  available <- get_available_revisions_all_years(all_revisions, archive_dir)

  revisions_available <- all_revisions[all_revisions %in% available]
  last_idx <- which(revisions_available == last_rev)

  if (length(last_idx) == 0) {
    message('Last revision ', last_rev, ' not found — full backfill')
    return(NULL)
  }

  if (last_idx >= length(revisions_available)) {
    message('No new revisions — rebuilding from ', last_rev)
    return(last_rev)
  }

  new_revs <- revisions_available[(last_idx + 1):length(revisions_available)]
  message('New revisions: ', paste(new_revs, collapse = ', '))
  return(last_rev)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)

  # Parse CLI args
  args <- commandArgs(trailingOnly = TRUE)

  # Fail loud on unrecognized flags. A removed flag that is silently ignored
  # rots invisibly in wrapper scripts: --publish-internal was dropped from this
  # CLI but stale wrappers kept passing it, running builds that silently never
  # published. Value-taking flags consume the following token.
  KNOWN_FLAGS <- c('--full', '--build-only', '--core-only',
                   '--alternatives-only', '--refresh-usmca', '--publish-git',
                   '--allow-partial', '--use-hts-dates', '--unweighted',
                   '--skip-release-check', '--parallel')
  VALUE_FLAGS <- c('--start-from', '--workers', '--alt-workers',
                   '--backend', '--alternatives')
  i <- 1L
  while (i <= length(args)) {
    a <- args[i]
    if (a %in% VALUE_FLAGS) {
      i <- i + 2L
    } else if (a %in% KNOWN_FLAGS) {
      i <- i + 1L
    } else if (startsWith(a, '--')) {
      stop('Unrecognized flag: ', a,
           '. Known flags: ', paste(c(KNOWN_FLAGS, VALUE_FLAGS), collapse = ' '),
           '. (Flags are never silently ignored — see todo.md build unification plan.)')
    } else {
      i <- i + 1L
    }
  }

  full_rebuild <- '--full' %in% args
  build_only <- '--build-only' %in% args
  core_only <- '--core-only' %in% args
  alternatives_only <- '--alternatives-only' %in% args
  refresh_usmca <- '--refresh-usmca' %in% args
  do_publish_git      <- '--publish-git' %in% args
  allow_partial    <- '--allow-partial' %in% args     # opt out of the completeness gate
  use_policy_dates <- !('--use-hts-dates' %in% args)  # default: policy dates
  unweighted <- '--unweighted' %in% args
  skip_release_check <- '--skip-release-check' %in% args
  start_from <- NULL
  alternatives_arg <- NULL
  for (i in seq_along(args)) {
    if (args[i] == '--start-from' && i < length(args)) start_from <- args[i + 1]
    if (args[i] == '--alternatives' && i < length(args))
      alternatives_arg <- args[i + 1]
  }

  if (alternatives_only && is.null(alternatives_arg)) {
    stop('--alternatives-only requires --alternatives ',
         '<names|all|alternatives|counterfactuals>.')
  }

  # --unweighted overrides config to opt into an unweighted run for this invocation.
  cli_weight_mode <- if (unweighted) 'unweighted' else NULL

  # Resolve --parallel / --workers / --alt-workers / --backend up-front so both
  # branches below see the same config. Off-by-default; serial behavior is
  # identical to pre-flag builds.
  parallel_cfg <- resolve_parallel_config(args)

  # Echo to stdout immediately. The structured log isn't open yet — both
  # branches re-log via log_parallel_config() once init_logging() has run.
  log_parallel_config(parallel_cfg)

  # Capture overall build start so publish modes can detect stale outputs from
  # an earlier run and refuse to ship them.
  build_started_at <- Sys.time()
  build_flags <- list(
    full = full_rebuild,
    build_only = build_only,
    core_only = core_only,
    alternatives_only = alternatives_only,
    alternatives = alternatives_arg,
    refresh_usmca = refresh_usmca,
    use_policy_dates = use_policy_dates,
    start_from = start_from,
    parallel = parallel_cfg
  )

  # --- Alternatives-only mode: skip build, iterate existing snapshots ---
  if (alternatives_only) {
    snapshot_dir <- here('data', 'timeseries')
    snap_files <- list.files(snapshot_dir, pattern = '^snapshot_.*\\.rds$')
    if (length(snap_files) == 0) {
      stop('No snapshots found in ', snapshot_dir,
           '. Run a full build first before using --alternatives-only.')
    }

    # Initialize log for alternatives-only runs
    log_dir <- file.path(Sys.getenv('TARIFF_OUTPUT_DIR', unset = here('output')), 'logs')
    init_logging(
      log_file = file.path(ensure_dir(log_dir),
                           paste0('alternatives_', format(Sys.time(), '%Y%m%d_%H%M%S'), '.log')),
      level = 'info'
    )
    log_info('Mode: alternatives-only')
    log_parallel_config(parallel_cfg)

    message('Using existing snapshots in: ', snapshot_dir,
            ' (', length(snap_files), ' revisions)')

    source(here('src', 'pipeline', '09_daily_series.R'))
    source(here('src', 'io', 'build_import_weights.R'))

    # Pre-flight: auto-build weights if missing (alternatives need them).
    if (!unweighted) {
      tryCatch(
        ensure_import_weights(weight_mode = cli_weight_mode),
        error = function(e) stop(
          'Pre-build: import-weights ensure step failed: ', conditionMessage(e),
          '\nPass --unweighted to skip.', call. = FALSE
        )
      )
    }
    imports <- load_import_weights(weight_mode = cli_weight_mode)

    capture_messages({
      run_alternative_series(alternatives = alternatives_arg,
                              imports = imports,
                              alt_workers = parallel_cfg$alt_workers,
                              use_policy_dates = use_policy_dates)
    })

    if (do_publish_git) {
      tryCatch({
        source(here('src', 'io', 'publish_git.R'))
        publish_git(build_flags = build_flags,
                    build_started_at = build_started_at)
      }, error = function(e) {
        log_warn('publish-git failed: ', conditionMessage(e))
        message('WARNING: --publish-git failed: ', conditionMessage(e))
      })
    }

  } else {
  # --- Main build path (not --alternatives-only) ---

  # --- Step A: Determine build mode ---
  if (full_rebuild) {
    start_from <- NULL
    message('Mode: Full rebuild (--full)')
  } else if (!is.null(start_from)) {
    message('Mode: Incremental from ', start_from)
  } else {
    start_from <- detect_incremental_start(use_policy_dates = use_policy_dates)
  }

  # --- Step A2: HTS release-currency gate ---
  # Stop early if the repo is more than one release behind USITC: only the current
  # release can be auto-downloaded (the static archive host is blocked for older
  # revisions — see check_release_currency() in 02_download_hts.R). One release
  # behind (the current one missing) is fine — Step B fetches it via the export
  # endpoint. Bypass with --skip-release-check (e.g., offline runs).
  if (!skip_release_check) {
    rc <- check_release_currency()
    if (identical(rc$status, 'behind_manual')) {
      log_error(rc$message)
      stop(rc$message, call. = FALSE)
    }
    message(rc$message)
  } else {
    message('  HTS release check: skipped (--skip-release-check)')
  }

  # --- Step B: Download missing JSON ---
  tryCatch(
    download_missing_revisions(),
    error = function(e) message('Download check failed: ', conditionMessage(e))
  )

  # --- Step B1: Ensure import weights are present (auto-build if missing) ---
  # Skipped when --build-only / --core-only / --unweighted (no downstream
  # consumer) or when weight_mode = 'unweighted'. Auto-build runs once on a
  # fresh clone; subsequent builds find the cached file via auto-detect.
  if (!build_only && !core_only && !unweighted) {
    source(here('src', 'io', 'build_import_weights.R'))
    tryCatch(
      ensure_import_weights(weight_mode = cli_weight_mode),
      error = function(e) stop(
        'Pre-build: import-weights ensure step failed: ', conditionMessage(e),
        '\nPass --unweighted to skip, or set weight_mode: unweighted in ',
        'config/local_paths.yaml.', call. = FALSE
      )
    )
  }

  # --- Step B2: Refresh USMCA shares from DataWeb API (if requested) ---
  if (refresh_usmca) {
    message('\n', strrep('=', 70))
    message('Refreshing USMCA utilization shares from USITC DataWeb API')
    message(strrep('=', 70))
    pp_temp <- load_policy_params(use_policy_dates = use_policy_dates)
    usmca_year <- pp_temp$USMCA_SHARES$year %||% 2025L
    refresh_failures <- character()
    # Download monthly data (produces per-month CSVs + diagnostic)
    monthly_rc <- system2('Rscript', c(here('tools', 'download_usmca_dataweb.R'),
                                        '--monthly', '--year', usmca_year),
                           stdout = TRUE, stderr = TRUE)
    if (!is.null(attr(monthly_rc, 'status')) && attr(monthly_rc, 'status') != 0) {
      message('  USMCA monthly refresh FAILED (exit ', attr(monthly_rc, 'status'), '):')
      message(paste(tail(monthly_rc, 20), collapse = '\n'))
      refresh_failures <- c(refresh_failures, 'monthly')
    } else {
      message('  Monthly shares refreshed for ', usmca_year)
    }
    # Download annual for the same year
    annual_rc <- system2('Rscript', c(here('tools', 'download_usmca_dataweb.R'),
                                       '--year', usmca_year),
                          stdout = TRUE, stderr = TRUE)
    if (!is.null(attr(annual_rc, 'status')) && attr(annual_rc, 'status') != 0) {
      message('  USMCA annual refresh FAILED (exit ', attr(annual_rc, 'status'), '):')
      message(paste(tail(annual_rc, 20), collapse = '\n'))
      refresh_failures <- c(refresh_failures, 'annual')
    } else {
      message('  Annual shares refreshed for ', usmca_year)
    }
    if (length(refresh_failures) > 0) {
      stop('USMCA refresh failed for: ', paste(refresh_failures, collapse = ', '),
           '. Fix the issue or remove --refresh-usmca to use existing files.')
    }
  }

  # --- Step C: Build timeseries ---
  if (use_policy_dates) {
    message('Mode: Using policy effective dates (default; pass --use-hts-dates to override)')
  } else {
    message('Mode: Using raw HTS revision dates (--use-hts-dates)')
  }
  result <- build_full_timeseries(start_from = start_from,
                                   use_policy_dates = use_policy_dates,
                                   parallel_cfg = parallel_cfg,
                                   allow_partial = allow_partial)

  # --- Step D: Summary ---
  if (!is.null(result)) {
    print_timeseries_summary(result$timeseries_path)
  }

  # --- Step E: Downstream (unless --build-only) ---
  if (!build_only && !is.null(result)) {
    source(here('src', 'pipeline', '09_daily_series.R'))
    source(here('src', 'io', 'quality_report.R'))

    ts <- readRDS(result$timeseries_path)
    pp <- load_policy_params(use_policy_dates = use_policy_dates)

    # Wrap downstream in capture_messages() so all message() output from
    # daily series, ETR, quality, and alternatives is written to the build log.
    capture_messages({

    if (core_only || unweighted) {
      label <- if (core_only && unweighted) '--core-only --unweighted'
               else if (core_only) '--core-only'
               else '--unweighted'
      message('\n', strrep('=', 70))
      message('POST-BUILD: Core only (', label,
              ') — unweighted daily series + quality report')
      message(strrep('=', 70))

      tryCatch(
        run_daily_series(ts, imports = NULL, policy_params = pp,
                         weight_mode = 'unweighted'),
        error = function(e) message('Daily series failed: ', conditionMessage(e))
      )

      tryCatch(
        run_quality_report(ts = ts, timeseries_path = result$timeseries_path),
        error = function(e) message('Quality report failed: ', conditionMessage(e))
      )
    } else {
      message('\n', strrep('=', 70))
      message('POST-BUILD: Daily series and quality report')
      message(strrep('=', 70))

      # Load weights OUTSIDE tryCatch so a missing-weights failure aborts the
      # build instead of being silently absorbed. Use --unweighted (CLI) or
      # set weight_mode: unweighted in config/local_paths.yaml to opt out.
      imports <- load_import_weights(weight_mode = cli_weight_mode)

      tryCatch(
        run_daily_series(ts, imports = imports, policy_params = pp),
        error = function(e) message('Daily series failed: ', conditionMessage(e))
      )

      tryCatch(
        run_quality_report(ts = ts, timeseries_path = result$timeseries_path),
        error = function(e) message('Quality report failed: ', conditionMessage(e))
      )

      # --- Step F: Requested alternative daily series ---
      # Release the full timeseries — alternatives iterate per-revision snapshots
      # and holding ts alongside them was the source of prior OOMs.
      rm(ts)
      gc()
      if (!is.null(alternatives_arg)) {
        tryCatch({
          run_alternative_series(alternatives = alternatives_arg,
                                  imports = imports,
                                  alt_workers = parallel_cfg$alt_workers,
                                  use_policy_dates = use_policy_dates)
        }, error = function(e) message('Alternative series failed: ', conditionMessage(e)))
      }
    }

    }) # end capture_messages
  }

  if (do_publish_git && !is.null(result)) {
    tryCatch({
      source(here('src', 'io', 'publish_git.R'))
      publish_git(build_flags = build_flags,
                  build_started_at = build_started_at)
    }, error = function(e) {
      log_warn('publish-git failed: ', conditionMessage(e))
      message('WARNING: --publish-git failed: ', conditionMessage(e))
    })
  } else if (do_publish_git && is.null(result)) {
    message('WARNING: --publish-git skipped (build did not produce a result).')
  }
  } # end else (main build path)
}
