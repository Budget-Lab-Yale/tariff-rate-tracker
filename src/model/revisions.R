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


#' Build a USITC reststop file-endpoint URL
#'
#' Unlike the exportList endpoint — which silently IGNORES a `release`
#' parameter and always returns the current release with HTTP 200 — the file
#' endpoint serves ARCHIVED releases. It is therefore the only route to
#' per-revision attribution once a release has been missed, and the fallback
#' whenever a revision's JSON is gone (2026_rev_14 has no JSON at all; its
#' Chapter 99 PDF is the primary source for that revision).
#'
#' Verified for 2026 revisions 13-15 with filename 'Change Record' and
#' 'Chapter 99'; the chapter route generalizes to any chapter number.
#'
#' @param release_name Character release name from build_release_name()
#' @param filename USITC file name, e.g. 'Chapter 99', 'Change Record', 'Chapter 1'
#' @return Character URL string
build_reststop_file_url <- function(release_name, filename) {
  paste0('https://hts.usitc.gov/reststop/file?release=',
         URLencode(release_name, reserved = TRUE),
         '&filename=', URLencode(filename, reserved = TRUE))
}


#' Build USITC Chapter 99 PDF download URL
#'
#' @param release_name Character release name from build_release_name()
#' @return Character URL string
build_chapter99_url <- function(release_name) {
  build_reststop_file_url(release_name, 'Chapter 99')
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
series_window_start <- function() .series_window_edge('start_date', 'series_window_start')


#' Resolve the series-window END date from the active policy params
#'
#' The mirror of series_window_start(). Phase 0 shipped the window as a LOWER
#' bound only, which is sufficient while there is exactly one era: the shipped
#' baseline's end_date (2026-12-31) is later than every revision, so the grid is
#' bounded in practice by the CSV itself.
#'
#' It stops being sufficient the moment a second era exists. Reading the
#' backfilled CSV through the pre-2025 baseline (start 2016-01-01) returns all
#' 155 rows — the 110 historical revisions AND the 45 shipped 2025-26 ones — so
#' the "pre-2025 era" would in fact rebuild the current series on top of itself,
#' with 2025-26 rates computed against an era config that disables IEEPA. Eras
#' must TILE, which needs both edges. Applied by load_revision_dates() next to
#' the start gate.
#'
#' Inert for the shipped 2025-26 build: end_date 2026-12-31 > the last revision
#' (2026-07-21), so the filter drops nothing.
#'
#' @return Date, or NULL when the key (or file) is absent => no end bound
series_window_end <- function() .series_window_edge('end_date', 'series_window_end')


#' Shared reader for both series-window edges (so they cannot drift on the path
#' contract, the fail-closed missing-file rule, or the `extends:` resolution).
#'
#' Resolved through .read_baseline_params() (not a bare read_yaml) so an era
#' baseline that inherits its window via `extends:` resolves the SAME value
#' load_policy_params() sees. A bare read would return NULL for an inherited
#' series_horizon — i.e. silently no window at all, the one failure mode this
#' rail exists to prevent.
.series_window_edge <- function(key, caller) {
  yaml_path <- resolve_policy_params_path()
  if (!file.exists(yaml_path)) {
    # A rail that switches itself off is the wrong failure mode: an explicit
    # TARIFF_POLICY_PARAMS pointing nowhere is a misconfiguration, not a
    # fixture. Only the default path may be legitimately absent (fresh clone
    # fixtures). Parse errors propagate for the same reason.
    if (nzchar(Sys.getenv('TARIFF_POLICY_PARAMS', ''))) {
      stop(caller, ': TARIFF_POLICY_PARAMS points at a missing file: ', yaml_path)
    }
    return(NULL)
  }
  sh <- .read_baseline_params(yaml_path)$series_horizon
  if (is.null(sh[[key]])) return(NULL)
  as.Date(sh[[key]])
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
#' @param window_start Date lower bound, or NULL to skip the lower check
#' @param window_end Date upper bound, or NULL to skip the upper check. Boundary
#'   mints are exempt: discover_boundaries already caps them at the horizon, and
#'   a `bnd_` id has no rev_dates row of its own to validate against an era edge.
assert_within_series_window <- function(rev_dates, revision_ids, window_start,
                                        window_end = NULL) {
  offenders <- function(pred, edge_name, edge_val, direction) {
    bad <- rev_dates %>% filter(revision %in% revision_ids, pred(effective_date))
    if (nrow(bad) == 0) return(invisible(TRUE))
    stop('assemble_timeseries: ', nrow(bad),
         ' revision(s) fall ', direction, ' series_horizon.', edge_name,
         ' (', edge_val, '): ', paste(bad$revision, collapse = ', '),
         '. Out-of-window revisions must build as their own era/vintage — see ',
         'docs/internal/pre2025_expansion_scoping_2026-07-28.md.')
  }
  if (!is.null(window_start)) {
    offenders(function(d) d < window_start, 'start_date', window_start, 'before')
  }
  if (!is.null(window_end)) {
    real_ids <- setdiff(revision_ids, grep('^(sched_|bnd_)', revision_ids, value = TRUE))
    bad <- rev_dates %>% filter(revision %in% real_ids, effective_date > window_end)
    if (nrow(bad) > 0) {
      stop('assemble_timeseries: ', nrow(bad),
           ' revision(s) fall after series_horizon.end_date (', window_end, '): ',
           paste(bad$revision, collapse = ', '),
           '. Out-of-window revisions must build as their own era/vintage — see ',
           'docs/internal/pre2025_expansion_scoping_2026-07-28.md.')
    }
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
#' @param window_end Explicit window end (Date); default NULL resolves it from
#'   the active policy params via series_window_end(). Both edges are needed for
#'   eras to TILE — see series_window_end().
#' @return Tibble with revision, effective_date
load_revision_dates <- function(csv_path = here('config', 'revision_dates.csv'),
                                use_policy_dates = TRUE,
                                apply_window = TRUE,
                                window_start = NULL,
                                window_end = NULL) {
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
    if (is.null(window_end)) window_end <- series_window_end()
    if (!is.null(window_start)) {
      n_before <- nrow(dates)
      dates <- dates %>% filter(effective_date >= window_start)
      n_dropped <- n_before - nrow(dates)
      if (n_dropped > 0) {
        message('  Series window: excluded ', n_dropped,
                ' revision(s) before ', window_start)
      }
    }
    # End gate: the mirror of the start gate, and what makes eras TILE rather
    # than overlap. Inert for the shipped 2025-26 baseline (end_date 2026-12-31
    # is later than every revision in the CSV); load-bearing for a pre-2025 era,
    # whose start-only window would otherwise pull the 45 current-series
    # revisions into the historical vintage. See series_window_end().
    if (!is.null(window_end)) {
      n_before <- nrow(dates)
      dates <- dates %>% filter(effective_date <= window_end)
      n_dropped <- n_before - nrow(dates)
      if (n_dropped > 0) {
        message('  Series window: excluded ', n_dropped,
                ' revision(s) after ', window_end)
      }
    }
    if (!is.null(window_start) || !is.null(window_end)) {
      if (nrow(dates) == 0) {
        stop('load_revision_dates: no revisions remain after applying the ',
             'series window (start ', window_start %||% '-inf',
             ', end ', window_end %||% '+inf', '). Check ',
             'series_horizon.start_date / end_date against ', csv_path)
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


#' Backfill archive_rev_id for synthetic (bnd_/sched_) revisions that lack it
#'
#' A synthetic interval's product-code universe is the one in force on its date —
#' i.e. the newest REAL revision at or before it — not its own calendar date.
#' build_boundary_mints() records that owner as `archive_rev_id`, but rows written
#' before that was carried (or by a path that never wrote one) arrive without it,
#' and hts_as_of_dates_from_timeline() then errors. Rather than let a caller
#' silently fall back to unmapped weights, fill the pointer with the same owner
#' rule the mint uses.
#'
#' @param timeline data frame with `revision` and `effective_date`.
#' @return the timeline with `archive_rev_id` present for every row.
backfill_archive_rev_id <- function(timeline) {
  if (!('revision' %in% names(timeline))) return(timeline)
  if (!('archive_rev_id' %in% names(timeline))) timeline$archive_rev_id <- NA_character_
  synth <- grepl('^(sched_|bnd_)', timeline$revision)
  need <- synth & (is.na(timeline$archive_rev_id) | !nzchar(timeline$archive_rev_id))
  if (!any(need)) return(timeline)
  real <- timeline[!synth, , drop = FALSE]
  real <- real[order(as.Date(real$effective_date)), , drop = FALSE]
  timeline$archive_rev_id[!synth] <- timeline$revision[!synth]
  for (i in which(need)) {
    d <- as.Date(timeline$effective_date[i])
    owners <- real$revision[as.Date(real$effective_date) <= d]
    if (length(owners)) timeline$archive_rev_id[i] <- tail(owners, 1)
  }
  still <- need & (is.na(timeline$archive_rev_id) | !nzchar(timeline$archive_rev_id))
  if (any(still)) {
    stop('backfill_archive_rev_id: no real revision at or before ',
         paste(timeline$revision[still], collapse = ', '), call. = FALSE)
  }
  timeline
}
