# =============================================================================
# Step 02: Download HTS JSON Archives
# =============================================================================
#
# Downloads missing HTS JSON archives from USITC.
# Compares local inventory (list_available_revisions()) against
# revision_dates.csv and downloads any missing files.
#
# Usage:
#   Rscript src/02_download_hts.R                # Download missing for 2025
#   Rscript src/02_download_hts.R --year 2026    # Download missing for 2026
#   Rscript src/02_download_hts.R --dry-run      # Report only, no downloads
#
# =============================================================================

library(tidyverse)


# =============================================================================
# Download Functions
# =============================================================================

#' Build USITC download URL for an HTS revision
#'
#' @param revision Revision identifier (e.g., 'basic', 'rev_1')
#' @param year HTS year (default: 2025)
#' @return Character URL
build_download_url <- function(revision, year = 2025) {
  base_url <- 'https://hts.usitc.gov/reststop/getJSON'

  if (revision == 'basic') {
    # Basic edition: no revision suffix
    url <- paste0(base_url, '?year=', year)
  } else if (grepl('^rev_', revision)) {
    # Numbered revision: extract number
    rev_num <- gsub('rev_', '', revision)
    url <- paste0(base_url, '?year=', year, '&revision=', rev_num)
  } else if (grepl('^2026', revision)) {
    # 2026 edition
    url <- paste0(base_url, '?year=2026')
  } else {
    stop('Unknown revision format: ', revision)
  }

  return(url)
}


#' Download a single HTS JSON file
#'
#' @param url USITC download URL
#' @param dest_path Destination file path
#' @param min_size_mb Minimum file size in MB to consider valid (default: 1)
#' @return TRUE on success, FALSE on failure
download_hts_json <- function(url, dest_path, min_size_mb = 1) {
  message('  Downloading: ', url)
  message('  Destination: ', dest_path)

  # Ensure directory exists
  dir.create(dirname(dest_path), recursive = TRUE, showWarnings = FALSE)

  # Download with binary mode
  tryCatch({
    download.file(url, dest_path, mode = 'wb', quiet = FALSE)

    # Validate file size
    file_size_mb <- file.info(dest_path)$size / (1024 * 1024)
    message('  File size: ', round(file_size_mb, 1), ' MB')

    if (file_size_mb < min_size_mb) {
      warning('Downloaded file is suspiciously small (', round(file_size_mb, 2),
              ' MB < ', min_size_mb, ' MB). May be an error page.')
      return(FALSE)
    }

    # Quick JSON validation: try to parse first few bytes
    tryCatch({
      con <- file(dest_path, 'r')
      first_char <- readChar(con, 1)
      close(con)
      if (!first_char %in% c('{', '[')) {
        warning('File does not start with JSON: ', first_char)
        return(FALSE)
      }
    }, error = function(e) {
      warning('Could not validate JSON: ', conditionMessage(e))
    })

    message('  Success!')
    return(TRUE)

  }, error = function(e) {
    message('  Download failed: ', conditionMessage(e))
    # Clean up partial download
    if (file.exists(dest_path)) file.remove(dest_path)
    return(FALSE)
  })
}


#' Download missing HTS revisions
#'
#' Compares local inventory against revision_dates.csv and downloads
#' any revisions that are in the CSV but not on disk.
#'
#' @param archive_dir Path to HTS archive directory
#' @param year HTS year (default: 2025)
#' @param dry_run If TRUE, report missing files without downloading
#' @param revision_dates_path Path to revision_dates.csv
#' @return Tibble with revision, status columns
download_missing_revisions <- function(
  archive_dir = 'data/hts_archives',
  year = 2025,
  dry_run = FALSE,
  revision_dates_path = 'config/revision_dates.csv'
) {
  # Load expected revisions
  rev_dates <- load_revision_dates(revision_dates_path)
  expected <- rev_dates$revision

  # Check local inventory
  available <- list_available_revisions(archive_dir, year)

  # Also check 2026 if any expected revisions start with 2026
  expected_2026 <- expected[grepl('^2026', expected)]
  if (length(expected_2026) > 0) {
    available_2026 <- list_available_revisions(archive_dir, year = 2026)
    available <- c(available, paste0('2026_', available_2026))
  }

  missing <- setdiff(expected, available)

  message('\n=== HTS Archive Inventory ===')
  message('Expected revisions: ', length(expected))
  message('Available locally:  ', length(available))
  message('Missing:            ', length(missing))

  if (length(missing) == 0) {
    message('All revisions present. Nothing to download.')
    return(tibble(revision = character(), status = character()))
  }

  message('\nMissing revisions: ', paste(missing, collapse = ', '))

  if (dry_run) {
    message('\n[DRY RUN] Would download ', length(missing), ' files.')
    return(tibble(revision = missing, status = 'missing'))
  }

  # Download each missing revision
  results <- tibble(revision = missing, status = NA_character_)

  for (i in seq_along(missing)) {
    rev <- missing[i]
    message('\n[', i, '/', length(missing), '] Downloading ', rev, '...')

    url <- build_download_url(rev, year)

    if (grepl('^2026', rev)) {
      dest <- file.path(archive_dir, paste0('hts_', rev, '.json'))
    } else {
      dest <- file.path(archive_dir, paste0('hts_', year, '_', rev, '.json'))
    }

    success <- download_hts_json(url, dest)
    results$status[i] <- if (success) 'downloaded' else 'failed'

    # Rate-limit: 2-second pause between downloads
    if (i < length(missing)) Sys.sleep(2)
  }

  # Summary
  n_ok <- sum(results$status == 'downloaded')
  n_fail <- sum(results$status == 'failed')
  message('\n=== Download Summary ===')
  message('Downloaded: ', n_ok, '  Failed: ', n_fail)

  return(results)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)
  source(here('src', 'helpers.R'))

  # Parse command line arguments
  args <- commandArgs(trailingOnly = TRUE)

  year <- 2025
  dry_run <- FALSE

  for (i in seq_along(args)) {
    if (args[i] == '--year' && i < length(args)) {
      year <- as.integer(args[i + 1])
    } else if (args[i] == '--dry-run') {
      dry_run <- TRUE
    }
  }

  results <- download_missing_revisions(year = year, dry_run = dry_run)
}
