# =============================================================================
# Revision / Archive Helpers — revision lifecycle, dates, JSON paths
# =============================================================================
# Split from helpers.R. Sourced by helpers.R for backward compatibility.
# Direct consumers can source this file alone (requires policy_params.R).

library(tidyverse)
library(here)

#' Parse a revision identifier into year and revision type
#'
#' Handles both year-prefixed and plain formats:
#'   '2026_rev_3'  -> list(year=2026, rev='rev_3')
#'   '2026_basic'  -> list(year=2026, rev='basic')
#'   'rev_32'      -> list(year=2025, rev='rev_32')
#'   'basic'       -> list(year=2025, rev='basic')
#'
#' @param revision Character revision identifier
#' @return List with year (integer) and rev (character) components
parse_revision_id <- function(revision) {
  if (grepl('^[0-9]{4}_', revision)) {
    year <- as.integer(substr(revision, 1, 4))
    rev <- sub('^[0-9]{4}_', '', revision)
    return(list(year = year, rev = rev))
  }
  return(list(year = 2025L, rev = revision))
}


#' Build USITC release name from revision identifier
#'
#' Maps a revision ID to the USITC release name used in API URLs.
#' Returns NA for pre-2025 revisions (no API access).
#'
#' @param revision Character revision identifier (e.g., 'rev_18', '2026_basic')
#' @return Character release name (e.g., '2025HTSRev18') or NA
build_release_name <- function(revision) {
  parsed <- parse_revision_id(revision)
  year <- parsed$year
  rev <- parsed$rev

  if (year < 2025) return(NA_character_)

  if (rev == 'basic') {
    return(paste0(year, 'HTSBasic'))
  }

  # Extract numeric part from rev_N
  rev_num <- as.integer(sub('^rev_', '', rev))
  if (is.na(rev_num)) return(NA_character_)

  return(paste0(year, 'HTSRev', rev_num))
}


#' Build USITC Chapter 99 PDF download URL
#'
#' Uses the USITC reststop file endpoint to construct a URL for downloading
#' the Chapter 99 PDF for a specific HTS release.
#'
#' @param release_name Character release name from build_release_name()
#' @return Character URL string
build_chapter99_url <- function(release_name) {
  paste0('https://hts.usitc.gov/reststop/file?release=',
         URLencode(release_name, reserved = TRUE),
         '&filename=Chapter+99')
}


#' Load revision dates from config CSV
#'
#' @param csv_path Path to revision_dates.csv
#' @param use_policy_dates If TRUE (default), swap policy_effective_date into
#'   effective_date where populated. This uses legal policy dates instead of
#'   HTS revision dates. Set FALSE or pass --use-hts-dates to use raw HTS dates.
#'   See docs/policy_timing.md for details on which revisions are affected.
#' @return Tibble with revision, effective_date, tpc_date
load_revision_dates <- function(csv_path = here('config', 'revision_dates.csv'),
                                use_policy_dates = TRUE) {
  if (!file.exists(csv_path)) {
    stop('Revision dates CSV not found: ', csv_path,
         '\nRun scraper or create manually.')
  }

  # Read with known columns; any extra columns (e.g., needs_review) are
  # auto-typed so the spec doesn't warn when they're absent from the CSV.
  dates <- read_csv(csv_path, col_types = cols(
    revision = col_character(),
    effective_date = col_date(),
    policy_effective_date = col_date(),
    tpc_date = col_date(),
    policy_event = col_character(),
    tpc_policy_revision = col_character()
  ))

  # Validate
  stopifnot(all(!is.na(dates$revision)))
  stopifnot(all(!is.na(dates$effective_date)))
  stopifnot(!any(duplicated(dates$revision)))

  # Check for unresolved placeholder dates
  if ('needs_review' %in% names(dates)) {
    unreviewed <- dates %>% filter(!is.na(needs_review) & needs_review == 'TRUE')
    if (nrow(unreviewed) > 0) {
      stop(
        nrow(unreviewed), ' revision(s) have unreviewed placeholder dates:\n',
        paste0('  ', unreviewed$revision, '  effective_date=', unreviewed$effective_date,
               collapse = '\n'),
        '\n\nThe API publication date is NOT the policy effective date.',
        '\nOpen config/revision_dates.csv, set the correct effective_date,',
        '\nand remove or clear the needs_review column for these rows.'
      )
    }
    # Drop the column after validation — downstream code doesn't need it
    dates <- dates %>% select(-needs_review)
  }

  # Optionally swap policy_effective_date into effective_date
  if (use_policy_dates && 'policy_effective_date' %in% names(dates)) {
    n_swapped <- sum(!is.na(dates$policy_effective_date))
    if (n_swapped > 0) {
      dates <- dates %>%
        mutate(effective_date = if_else(!is.na(policy_effective_date),
                                        policy_effective_date,
                                        effective_date))
      message('  Policy dates: swapped ', n_swapped, ' revision effective dates')
    }
  }

  # Sort by effective_date
  dates <- dates %>% arrange(effective_date)

  message('Loaded ', nrow(dates), ' revision dates from ', csv_path)
  message('  Date range: ', min(dates$effective_date), ' to ', max(dates$effective_date))
  message('  TPC validation dates: ', sum(!is.na(dates$tpc_date)))

  return(dates)
}


#' List available HTS JSON archives
#'
#' Scans the archive directory and returns revision identifiers.
#'
#' @param archive_dir Path to HTS JSON archive directory
#' @param year Year prefix (default: 2025)
#' @return Character vector of revision identifiers
list_available_revisions <- function(archive_dir = here('data', 'hts_archives'), year = 2025) {
  files <- list.files(archive_dir, pattern = paste0('hts_', year, '.*\\.json$'))

  # Extract revision from filename: hts_2025_rev_32.json -> rev_32, hts_2025_basic.json -> basic
  revisions <- str_match(files, paste0('hts_', year, '_(.+)\\.json'))[, 2]
  revisions <- revisions[!is.na(revisions)]

  return(revisions)
}


#' Resolve JSON path for a revision
#'
#' @param revision Revision identifier (e.g., 'basic', 'rev_1')
#' @param archive_dir HTS archive directory
#' @param year HTS year (default: 2025)
#' @return Full file path to JSON
resolve_json_path <- function(revision, archive_dir = here('data', 'hts_archives'), year = 2025) {
  parsed <- parse_revision_id(revision)
  path <- file.path(archive_dir, paste0('hts_', parsed$year, '_', parsed$rev, '.json'))

  if (!file.exists(path)) {
    stop('HTS JSON not found: ', path)
  }

  return(path)
}


#' Get available revisions across all years
#'
#' Scans the archive directory for all years present in a revision list
#' and returns full revision identifiers (with year prefix for non-2025).
#'
#' @param all_revisions Character vector of revision IDs from revision_dates.csv
#' @param archive_dir Path to HTS archive directory
#' @return Character vector of available revision identifiers
get_available_revisions_all_years <- function(all_revisions, archive_dir = here('data', 'hts_archives')) {
  years_needed <- unique(map_int(all_revisions, ~ parse_revision_id(.)$year))
  available <- character()
  for (yr in years_needed) {
    yr_revisions <- list_available_revisions(archive_dir, year = yr)
    if (yr != 2025) yr_revisions <- paste0(yr, '_', yr_revisions)
    available <- c(available, yr_revisions)
  }
  return(available)
}
