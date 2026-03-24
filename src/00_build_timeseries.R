# =============================================================================
# Step 00: Build Tariff Rate Time Series
# =============================================================================
#
# Main orchestrator: iteratively processes HTS revisions to build a time series
# of tariff rates. Supports full backfill, incremental updates, and auto-update.
# After building, runs downstream scripts (daily series, ETR, quality report).
#
# Usage:
#   Rscript src/00_build_timeseries.R              # Auto-update (default)
#   Rscript src/00_build_timeseries.R --full        # Full rebuild from scratch
#   Rscript src/00_build_timeseries.R --start-from rev_25  # Explicit incremental
#   Rscript src/00_build_timeseries.R --build-only  # Skip downstream (daily/ETR/quality)
#   Rscript src/00_build_timeseries.R --core-only  # Build + downstream, but skip weighted outputs
#   Rscript src/00_build_timeseries.R --with-alternatives  # Also run rebuild alternatives
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
source(here('src', 'logging.R'))
source(here('src', 'helpers.R'))
source(here('src', '01_scrape_revision_dates.R'))
source(here('src', '02_download_hts.R'))
source(here('src', '03_parse_chapter99.R'))
source(here('src', '04_parse_products.R'))
source(here('src', '05_parse_policy_params.R'))
source(here('src', '06_calculate_rates.R'))
source(here('src', '07_validate_tpc.R'))


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
  use_policy_dates = FALSE
) {
  start_time <- Sys.time()

  message('\n', strrep('=', 70))
  message('TARIFF RATE TIME SERIES BUILDER')
  message(strrep('=', 70))
  message('Started: ', start_time)
  message('Mode: ', if (is.null(start_from)) 'Full backfill' else paste('Incremental from', start_from))
  message(strrep('=', 70), '\n')

  # ---- Initialize logging ----
  log_dir <- here('output', 'logs')
  init_logging(
    log_file = file.path(ensure_dir(log_dir),
                         paste0('build_', format(start_time, '%Y%m%d_%H%M%S'), '.log')),
    level = 'info'
  )
  log_info('Build started: ', if (is.null(start_from)) 'full backfill' else paste('from', start_from))

  # ---- Setup ----
  ensure_dir(output_dir)
  if (is.null(tpc_path)) {
    tpc_path <- load_local_paths()$tpc_benchmark
  }

  # Load revision dates
  rev_dates <- load_revision_dates(revision_dates_path,
                                    use_policy_dates = use_policy_dates)

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
    prev_products <- readRDS(prod_cache)

    # Start from the revision AFTER start_from
    start_idx <- which(revisions_to_process == start_from) + 1

    if (start_idx > length(revisions_to_process)) {
      message('No new revisions after ', start_from, '. Nothing to process.')
      return(invisible(NULL))
    }

    revisions_to_process <- revisions_to_process[start_idx:length(revisions_to_process)]
    message('Incremental: processing ', length(revisions_to_process),
            ' revisions after ', start_from)
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
      # a. Resolve JSON path
      json_path <- resolve_json_path(rev_id, archive_dir)

      # b. Read raw JSON (needed for IEEPA/USMCA extraction)
      hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)

      # c. Parse Chapter 99 entries
      ch99_data <- parse_chapter99(json_path)

      # d. Parse products
      products <- parse_products(json_path)

      # e. Extract IEEPA rates, fentanyl rates, Section 232 rates, and USMCA eligibility
      ieepa_rates <- extract_ieepa_rates(hts_raw, country_lookup)
      fentanyl_rates <- extract_ieepa_fentanyl_rates(hts_raw, country_lookup)
      s232_rates <- extract_section232_rates(ch99_data)
      usmca <- extract_usmca_eligibility(hts_raw)

      # f. Compute delta from previous revision
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

      # g. Calculate rates for this revision
      rates <- calculate_rates_for_revision(
        products, ch99_data, ieepa_rates, usmca,
        countries, rev_id, eff_date,
        s232_rates = s232_rates,
        fentanyl_rates = fentanyl_rates,
        stacking_method = stacking_method
      )

      # h. Save snapshot
      snapshot_path <- file.path(output_dir, paste0('snapshot_', rev_id, '.rds'))
      saveRDS(rates, snapshot_path)
      snapshot_paths <- c(snapshot_paths, snapshot_path)

      # i. Cache parse results (for incremental)
      saveRDS(ch99_data, file.path(output_dir, paste0('ch99_', rev_id, '.rds')))
      saveRDS(products, file.path(output_dir, paste0('products_', rev_id, '.rds')))

      # j. TPC validation if this revision has a tpc_date
      if (!is.na(tpc_date) && file.exists(tpc_path)) {
        message('  Running TPC validation for date: ', tpc_date)
        tryCatch({
          validation <- validate_revision_against_tpc(
            revision_rates = rates,
            tpc_path = tpc_path,
            tpc_date = tpc_date,
            census_codes = census_codes
          )
          val_path <- file.path(output_dir, paste0('validation_', rev_id, '.rds'))
          saveRDS(validation, val_path)
          message('  TPC match rate: ', round(validation$match_rate * 100, 1), '%')
        }, error = function(e) {
          message('  TPC validation failed: ', conditionMessage(e))
        })
      }

      # k. Log summary
      if (nrow(rates) > 0) {
        ieepa_summary <- rates %>%
          filter(rate_ieepa_recip > 0) %>%
          summarise(
            n_countries = n_distinct(country),
            mean_rate = mean(rate_ieepa_recip)
          )
        message('  IEEPA active in ', ieepa_summary$n_countries, ' countries, ',
                'mean rate: ', round(ieepa_summary$mean_rate * 100, 1), '%')
      }

      # l. Update previous state
      prev_ch99 <- ch99_data
      prev_products <- products

      last_successful_rev <<- rev_id
      log_info('  OK: ', nrow(rates), ' product-country rates')

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

  # ---- Bind all snapshots ----
  message('\n', strrep('=', 60))
  message('Combining snapshots into time series...')

  # Load all snapshot files (including pre-existing from incremental)
  all_snapshot_files <- list.files(output_dir, pattern = '^snapshot_.*\\.rds$', full.names = TRUE)

  timeseries <- map_dfr(all_snapshot_files, function(f) {
    tryCatch(readRDS(f), error = function(e) {
      warning('Failed to read snapshot: ', f, ' -- ', e$message)
      NULL
    })
  })

  # Enforce schema consistency (old snapshots may lack newer columns)
  timeseries <- enforce_rate_schema(timeseries)

  # Sort by effective_date, then revision
  timeseries <- timeseries %>%
    arrange(effective_date, revision, country, hts10)

  # Add temporal intervals (valid_from / valid_until) from revision ordering
  # Final revision extends to configurable horizon (default: 2026-12-31), not Sys.Date()
  policy_params <- load_policy_params(use_policy_dates = use_policy_dates)
  horizon_end <- policy_params$SERIES_HORIZON_END %||% Sys.Date()
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

  timeseries <- timeseries %>%
    select(-any_of(c('valid_from', 'valid_until'))) %>%
    left_join(rev_intervals, by = 'revision')

  message('  Added interval columns: valid_from / valid_until')

  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
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

  # ---- Save metadata ----
  metadata <- list(
    last_revision = last_successful_rev,
    last_build_time = Sys.time(),
    n_revisions = n_distinct(timeseries$revision),
    n_rows = nrow(timeseries),
    scenario = scenario
  )
  saveRDS(metadata, file.path(output_dir, 'metadata.rds'))

  # ---- Summary ----
  end_time <- Sys.time()
  elapsed <- round(difftime(end_time, start_time, units = 'mins'), 1)

  message('\n', strrep('=', 70))
  message('TIME SERIES BUILD COMPLETE')
  message(strrep('=', 70))
  message('Elapsed: ', elapsed, ' minutes')
  message('Revisions processed: ', length(revisions_to_process))
  message('Output: ', ts_path)
  message(strrep('=', 70), '\n')

  return(list(
    metadata = metadata,
    timeseries_path = ts_path,
    output_dir = output_dir
  ))
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
  revision_dates_path = 'config/revision_dates.csv'
) {
  metadata_path <- file.path(output_dir, 'metadata.rds')
  if (!file.exists(metadata_path)) {
    message('No previous build found — full backfill')
    return(NULL)
  }

  metadata <- readRDS(metadata_path)
  last_rev <- metadata$last_revision
  message('Last build: ', metadata$last_build_time, ' (', last_rev, ')')

  # Check for new revisions after last_rev
  rev_dates <- load_revision_dates(revision_dates_path)
  all_revisions <- rev_dates$revision

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
  full_rebuild <- '--full' %in% args
  build_only <- '--build-only' %in% args
  core_only <- '--core-only' %in% args
  with_alternatives <- '--with-alternatives' %in% args
  use_policy_dates <- !('--use-hts-dates' %in% args)  # default: policy dates
  start_from <- NULL
  for (i in seq_along(args)) {
    if (args[i] == '--start-from' && i < length(args)) start_from <- args[i + 1]
  }

  # --- Step A: Determine build mode ---
  if (full_rebuild) {
    start_from <- NULL
    message('Mode: Full rebuild (--full)')
  } else if (!is.null(start_from)) {
    message('Mode: Incremental from ', start_from)
  } else {
    start_from <- detect_incremental_start()  # NULL = full backfill
  }

  # --- Step B: Download missing JSON ---
  tryCatch(
    download_missing_revisions(),
    error = function(e) message('Download check failed: ', conditionMessage(e))
  )

  # --- Step C: Build timeseries ---
  if (use_policy_dates) {
    message('Mode: Using policy effective dates (default; pass --use-hts-dates to override)')
  } else {
    message('Mode: Using raw HTS revision dates (--use-hts-dates)')
  }
  result <- build_full_timeseries(start_from = start_from,
                                   use_policy_dates = use_policy_dates)

  # --- Step D: Summary ---
  if (!is.null(result)) {
    print_timeseries_summary(result$timeseries_path)
  }

  # --- Step E: Downstream (unless --build-only) ---
  if (!build_only && !is.null(result)) {
    source(here('src', '09_daily_series.R'))
    source(here('src', '08_weighted_etr.R'))
    source(here('src', 'quality_report.R'))

    ts <- readRDS(result$timeseries_path)
    pp <- load_policy_params()

    if (core_only) {
      message('\n', strrep('=', 70))
      message('POST-BUILD: Core only (--core-only) — unweighted daily series + quality report')
      message(strrep('=', 70))

      tryCatch(
        run_daily_series(ts, imports = NULL, policy_params = pp),
        error = function(e) message('Daily series failed: ', conditionMessage(e))
      )

      tryCatch(
        run_quality_report(result$timeseries_path),
        error = function(e) message('Quality report failed: ', conditionMessage(e))
      )
    } else {
      message('\n', strrep('=', 70))
      message('POST-BUILD: Daily series, ETR, quality report')
      message(strrep('=', 70))

      imports <- load_import_weights()

      tryCatch(
        run_daily_series(ts, imports = imports, policy_params = pp),
        error = function(e) message('Daily series failed: ', conditionMessage(e))
      )

      tryCatch(
        run_weighted_etr(ts, policy_params = pp),
        error = function(e) message('Weighted ETR failed: ', conditionMessage(e))
      )

      tryCatch(
        run_quality_report(result$timeseries_path),
        error = function(e) message('Quality report failed: ', conditionMessage(e))
      )

      # --- Step F: Alternative daily series ---
      # Post-build alternatives always run; rebuild alternatives only with --with-alternatives
      source(here('src', 'apply_scenarios.R'))
      tryCatch(
        run_alternative_series(ts, imports = imports, policy_params = pp,
                                rebuild = with_alternatives),
        error = function(e) message('Alternative series failed: ', conditionMessage(e))
      )
    }
  }
}
