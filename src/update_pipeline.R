# DEPRECATED: Use src/00_build_timeseries.R instead.
# This script is retained for backward compatibility.
# See CLAUDE.md for updated usage.
#
# =============================================================================
# Update Pipeline
# =============================================================================
#
# Automates incremental updates to the tariff rate time series:
#   1. Load metadata from last build
#   2. Check for new JSON files
#   3. Identify revisions after the last processed revision
#   4. Run incremental build
#
# Usage:
#   Rscript src/update_pipeline.R
#
# =============================================================================

library(tidyverse)
library(jsonlite)
library(here)

# Source pipeline components
source(here('src', 'logging.R'))
source(here('src', 'helpers.R'))
source(here('src', '00_build_timeseries.R'))


#' Run incremental pipeline update
#'
#' Checks for new HTS revisions since the last build and processes them.
#' If no previous build exists, falls back to full backfill.
#'
#' @param archive_dir Directory containing HTS JSON files
#' @param output_dir Directory for time series outputs
#' @param revision_dates_path Path to revision_dates.csv
#' @param download_new Logical; attempt to download new revisions first
#' @return Result from build_full_timeseries(), or NULL if nothing to do
run_update <- function(
  archive_dir = here('data', 'hts_archives'),
  output_dir = here('data', 'timeseries'),
  revision_dates_path = here('config', 'revision_dates.csv'),
  download_new = TRUE
) {
  start_time <- Sys.time()

  message('\n', strrep('=', 70))
  message('TARIFF RATE TRACKER — INCREMENTAL UPDATE')
  message(strrep('=', 70))
  message('Started: ', start_time)

  # ---- Initialize logging ----
  log_dir <- here('output', 'logs')
  if (!dir.exists(log_dir)) dir.create(log_dir, recursive = TRUE)
  init_logging(
    log_file = file.path(log_dir, paste0('update_', format(start_time, '%Y%m%d_%H%M%S'), '.log')),
    level = 'info'
  )

  # ---- Load metadata from last build ----
  metadata_path <- file.path(output_dir, 'metadata.rds')

  if (!file.exists(metadata_path)) {
    message('No previous build found. Running full backfill...')
    log_info('No metadata found — full backfill')
    result <- build_full_timeseries()
    return(result)
  }

  metadata <- readRDS(metadata_path)
  last_rev <- metadata$last_revision
  last_time <- metadata$last_build_time

  message('Last build: ', last_time)
  message('Last revision: ', last_rev)
  message('Revisions in last build: ', metadata$n_revisions)
  message('Rows in last build: ', metadata$n_rows)

  # ---- Optionally download new revisions ----
  if (download_new) {
    message('\nChecking for new HTS revisions to download...')
    tryCatch({
      source(here('src', '02_download_hts.R'))
      download_missing_revisions(archive_dir = archive_dir)
    }, error = function(e) {
      message('Download check failed: ', conditionMessage(e))
      log_warn('Download check failed: ', conditionMessage(e))
    })
  }

  # ---- Determine if there are new revisions ----
  rev_dates <- load_revision_dates(revision_dates_path)
  all_revisions <- rev_dates$revision

  years_needed <- unique(map_int(all_revisions, ~ parse_revision_id(.)$year))

  available <- character()
  for (yr in years_needed) {
    yr_revisions <- list_available_revisions(archive_dir, year = yr)
    if (yr != 2025) {
      yr_revisions <- paste0(yr, '_', yr_revisions)
    }
    available <- c(available, yr_revisions)
  }

  revisions_available <- all_revisions[all_revisions %in% available]

  # Find revisions after last_rev
  last_idx <- which(revisions_available == last_rev)
  if (length(last_idx) == 0) {
    message('WARNING: Last revision ', last_rev, ' not found in available list.')
    message('Running full backfill as safety measure...')
    log_warn('Last revision not in available list — full backfill')
    result <- build_full_timeseries()
    return(result)
  }

  if (last_idx >= length(revisions_available)) {
    message('\nNo new revisions after ', last_rev, '. Pipeline is up to date.')
    log_info('No new revisions — up to date')
    message(strrep('=', 70))
    return(invisible(NULL))
  }

  new_revisions <- revisions_available[(last_idx + 1):length(revisions_available)]
  message('\nNew revisions to process: ', length(new_revisions))
  message('  ', paste(new_revisions, collapse = ', '))
  log_info('Found ', length(new_revisions), ' new revisions: ',
           paste(new_revisions, collapse = ', '))

  # ---- Run incremental build ----
  result <- build_full_timeseries(start_from = last_rev)

  # ---- Summary ----
  elapsed <- round(difftime(Sys.time(), start_time, units = 'mins'), 1)
  message('\n', strrep('=', 70))
  message('UPDATE COMPLETE')
  message('Elapsed: ', elapsed, ' minutes')
  message('New revisions processed: ', length(new_revisions))
  message(strrep('=', 70))

  return(result)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  result <- run_update()

  if (!is.null(result)) {
    print_timeseries_summary(result$timeseries_path)
  }
}
