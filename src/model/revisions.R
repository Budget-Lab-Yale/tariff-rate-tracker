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


#' Resolve the series-window start date from the active policy params
#'
#' Reads series_horizon.start_date from the policy params YAML the current run
#' builds against (TARIFF_POLICY_PARAMS override honored, matching
#' load_policy_params()). Read directly rather than via load_policy_params():
#' this runs on every grid load and needs none of the unpacking, and the build
#' window belongs to an era's baseline config, not to scenario overlays (each
#' pre-2025 era gets its own policy_params_path — see
#' docs/internal/pre2025_expansion_scoping_2026-07-28.md).
#'
#' @return Date, or NULL when the key (or file) is absent => no start bound
series_window_start <- function() {
  yaml_path <- resolve_policy_params_path()
  if (!file.exists(yaml_path)) {
    # A rail that switches itself off is the wrong failure mode: an explicit
    # TARIFF_POLICY_PARAMS pointing nowhere is a misconfiguration, not a
    # fixture. Only the default path may be legitimately absent (fresh clone
    # fixtures). Parse errors propagate for the same reason.
    if (nzchar(Sys.getenv('TARIFF_POLICY_PARAMS', ''))) {
      stop('series_window_start: TARIFF_POLICY_PARAMS points at a missing file: ',
           yaml_path)
    }
    return(NULL)
  }
  sh <- yaml::read_yaml(yaml_path)$series_horizon
  if (is.null(sh$start_date)) return(NULL)
  as.Date(sh$start_date)
}


#' Assert that revisions fall inside the series window
#'
#' Belt-and-braces mirror of the load_revision_dates() window filter, used by
#' assemble_timeseries() so a pre-window snapshot cannot enter the panel even
#' when the grid was loaded unfiltered (apply_window = FALSE) or assembled from
#' a foreign rev_dates. Fails loud and names the offenders.
#'
#' @param rev_dates Tibble from load_revision_dates()
#' @param revision_ids Character revision ids about to enter the panel
#' @param window_start Date lower bound, or NULL to skip the check
assert_within_series_window <- function(rev_dates, revision_ids, window_start) {
  if (is.null(window_start)) return(invisible(TRUE))
  early <- rev_dates %>%
    filter(revision %in% revision_ids, effective_date < window_start)
  if (nrow(early) > 0) {
    stop('assemble_timeseries: ', nrow(early),
         ' revision(s) fall before series_horizon.start_date (', window_start, '): ',
         paste(early$revision, collapse = ', '),
         '. Pre-window revisions must build as their own era/vintage — see ',
         'docs/internal/pre2025_expansion_scoping_2026-07-28.md.')
  }
  invisible(TRUE)
}


#' Load revision dates from config CSV
#'
#' @param csv_path Path to revision_dates.csv
#' @param use_policy_dates If TRUE (default), swap policy_effective_date into
#'   effective_date where populated. This uses legal policy dates instead of
#'   HTS revision dates. Set FALSE or pass --use-hts-dates to use raw HTS dates.
#'   See docs/policy_timing.md for details on which revisions are affected.
#' @param apply_window If TRUE (default), drop revisions dated before the
#'   active config's series_horizon.start_date so a backfilled
#'   revision_dates.csv cannot widen this build's grid. Every consumer that
#'   feeds a BUILD GRID keeps the default. Raw-CSV reconciliation and
#'   archive-INVENTORY consumers opt out (apply_window = FALSE): the scraper,
#'   the archive downloader, the Ch99-PDF/floor-exemption scrapers, the
#'   revision changelog, and the HTS concordance builder — for those, a
#'   windowed grid would make out-of-window rows look absent and mis-report
#'   (or refuse to fetch) inventory the backfill depends on.
#' @param window_start Explicit window start (Date); default NULL resolves it
#'   from the active policy params via series_window_start().
#' @return Tibble with revision, effective_date
load_revision_dates <- function(csv_path = here('config', 'revision_dates.csv'),
                                use_policy_dates = TRUE,
                                apply_window = TRUE,
                                window_start = NULL) {
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
    policy_event = col_character()
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

  # Series-window gate (pre-2025 expansion rails): applied after the policy-date
  # swap so the window keys on the same dates the grid is ordered by. With the
  # shipped config (start 2025-01-01) and the current CSV this drops nothing —
  # the filter only bites once pre-2025 rows are backfilled.
  if (apply_window) {
    if (is.null(window_start)) window_start <- series_window_start()
    if (!is.null(window_start)) {
      n_before <- nrow(dates)
      dates <- dates %>% filter(effective_date >= window_start)
      n_dropped <- n_before - nrow(dates)
      if (n_dropped > 0) {
        message('  Series window: excluded ', n_dropped,
                ' revision(s) before ', window_start)
      }
      if (nrow(dates) == 0) {
        stop('load_revision_dates: no revisions remain after applying the ',
             'series window (start ', window_start, '). Check ',
             'series_horizon.start_date against ', csv_path)
      }
    }
  }

  message('Loaded ', nrow(dates), ' revision dates from ', csv_path)
  message('  Date range: ', min(dates$effective_date), ' to ', max(dates$effective_date))

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
  # Match both raw and gzip-compressed archives. The archives are committed to
  # git gzipped (.json.gz) — ~20:1 compression — since the static download host
  # is blocked for retrospective files (see 02_download_hts.R). fromJSON() reads
  # .json.gz transparently, so only path resolution needs to be gz-aware.
  files <- list.files(archive_dir, pattern = paste0('hts_', year, '.*\\.json(\\.gz)?$'))

  # Extract revision from filename: hts_2025_rev_32.json[.gz] -> rev_32
  revisions <- str_match(files, paste0('hts_', year, '_(.+)\\.json(?:\\.gz)?$'))[, 2]
  revisions <- revisions[!is.na(revisions)]

  # De-dup in case both .json and .json.gz exist for a revision (transition).
  return(unique(revisions))
}


#' Resolve JSON path for a revision
#'
#' @param revision Revision identifier (e.g., 'basic', 'rev_1')
#' @param archive_dir HTS archive directory
#' @param year HTS year (default: 2025)
#' @return Full file path to JSON
resolve_json_path <- function(revision, archive_dir = here('data', 'hts_archives'), year = 2025) {
  parsed <- parse_revision_id(revision)
  base <- file.path(archive_dir, paste0('hts_', parsed$year, '_', parsed$rev))

  # Prefer the committed gzip archive; fall back to a raw .json if present.
  # fromJSON() decompresses .json.gz transparently.
  gz_path <- paste0(base, '.json.gz')
  raw_path <- paste0(base, '.json')
  if (file.exists(gz_path))  return(gz_path)
  if (file.exists(raw_path)) return(raw_path)

  stop('HTS JSON not found: ', raw_path, ' (or .json.gz)')
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
