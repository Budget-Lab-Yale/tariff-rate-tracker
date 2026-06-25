# =============================================================================
# Step 02: Download HTS JSON Archives
# =============================================================================
#
# Downloads missing HTS JSON archives from USITC.
# Compares local inventory (list_available_revisions()) against
# revision_dates.csv and downloads any missing files.
#
# IMPORTANT — retrospective (archived) revisions cannot be auto-downloaded:
#   The static archive host (www.usitc.gov/.../hts_*_json.json) began returning
#   Akamai 403 for ALL revisions in June 2026. The only working JSON source is
#   the reststop export endpoint (hts.usitc.gov/reststop/exportList), which
#   serves ONLY the current release. So this script can fetch the CURRENT
#   revision (via the export fallback) but NOT older/superseded ones.
#
#   Archived revisions are instead preserved IN THIS REPO, committed gzipped as
#   data/hts_archives/hts_<year>_<rev>.json.gz (~0.7 MB each vs ~13 MB raw).
#   fromJSON() reads .json.gz transparently; path resolution is gz-aware
#   (resolve_json_path / list_available_revisions). New downloads are gzipped
#   on success. If a genuinely-missing archived revision is reported below,
#   obtain its JSON manually from hts.usitc.gov and place it (raw or .gz) in
#   data/hts_archives/.
#
# Usage:
#   Rscript src/pipeline/02_download_hts.R                # Download missing for 2025
#   Rscript src/pipeline/02_download_hts.R --year 2026    # Download missing for 2026
#   Rscript src/pipeline/02_download_hts.R --dry-run      # Report only, no downloads
#
# =============================================================================

library(tidyverse)
library(jsonlite)


# =============================================================================
# Download Functions
# =============================================================================

# --- Export-endpoint fallback (for when the static archive host is blocked) ---
#
# The primary source (www.usitc.gov/sites/default/files/tata/hts/hts_*_json.json)
# began returning Akamai "Access Denied" (HTTP 403) for all revisions in
# June 2026, including ones that downloaded fine weeks earlier — i.e. a blanket
# bot block, not a missing-file issue. The reststop export host (hts.usitc.gov)
# is still reachable and returns the same JSON schema.
#
# IMPORTANT LIMITATION: exportList only ever serves the CURRENT release. It
# cannot fetch archived/superseded revisions. The caller must confirm the
# requested revision IS the current release before using this path, otherwise
# it would save current-revision data under an older revision's filename.
#
# Endpoint quirks: from/to must be real dotted leaf HTS numbers and styles=true
# is required, or the endpoint returns HTTP 400. from=0101.21.00 / to=9999.00.00
# spans the full schedule including all of Chapter 99 (~13 MB, ~35.5k records).

EXPORT_FULL_URL <- paste0(
  'https://hts.usitc.gov/reststop/exportList',
  '?from=0101.21.00&to=9999.00.00&format=JSON&styles=true'
)

# The reststop host rejects the default R/libcurl user agent.
EXPORT_USER_AGENT <- paste0(
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ',
  '(KHTML, like Gecko) Chrome/124.0 Safari/537.36'
)

#' Get the name of the current USITC HTS release (status == "current")
#'
#' @param api_url releaseList endpoint
#' @return Character release name (e.g., "2026HTSRev9") or NA on failure
get_current_release_name <- function(
  api_url = 'https://hts.usitc.gov/reststop/releaseList'
) {
  tryCatch({
    old_ua <- getOption('HTTPUserAgent')
    options(HTTPUserAgent = EXPORT_USER_AGENT)
    on.exit(options(HTTPUserAgent = old_ua), add = TRUE)
    releases <- jsonlite::fromJSON(api_url, simplifyDataFrame = TRUE)
    current <- releases$name[releases$status == 'current']
    if (length(current) == 0) return(NA_character_)
    current[1]
  }, error = function(e) {
    message('  Could not fetch current release name: ', conditionMessage(e))
    NA_character_
  })
}

#' Download the current-revision full HTS via the reststop export endpoint
#'
#' @param dest_path Destination file path
#' @param min_size_mb Minimum valid size (default 5; full HTS is ~13 MB)
#' @return TRUE on success, FALSE otherwise
download_hts_via_export <- function(dest_path, min_size_mb = 5) {
  message('  Export fallback: ', EXPORT_FULL_URL)
  message('  Destination: ', dest_path)
  dir.create(dirname(dest_path), recursive = TRUE, showWarnings = FALSE)

  old_ua <- getOption('HTTPUserAgent')
  options(HTTPUserAgent = EXPORT_USER_AGENT)
  on.exit(options(HTTPUserAgent = old_ua), add = TRUE)

  tryCatch({
    download.file(EXPORT_FULL_URL, dest_path, mode = 'wb', quiet = FALSE)

    file_size_mb <- file.info(dest_path)$size / (1024 * 1024)
    message('  File size: ', round(file_size_mb, 1), ' MB')
    if (file_size_mb < min_size_mb) {
      warning('Export download suspiciously small (', round(file_size_mb, 2),
              ' MB < ', min_size_mb, ' MB). May be an error page.')
      return(FALSE)
    }

    con <- file(dest_path, 'r')
    first_char <- readChar(con, 1)
    close(con)
    if (!first_char %in% c('{', '[')) {
      warning('Export file does not start with JSON: ', first_char)
      return(FALSE)
    }

    message('  Success (export endpoint)!')
    TRUE
  }, error = function(e) {
    message('  Export download failed: ', conditionMessage(e))
    if (file.exists(dest_path)) file.remove(dest_path)
    FALSE
  })
}

#' Gzip a file in place: src -> src.gz (removing the original on success)
#'
#' Archives are committed to git gzipped (~20:1). Uses base-R connections so
#' there is no R.utils dependency. Reads the whole file into memory (~13 MB,
#' fine for HTS JSON).
#'
#' @param src Path to the raw file
#' @param remove If TRUE, delete the raw file after compressing
#' @return Path to the .gz file
gzip_file <- function(src, remove = TRUE) {
  dst <- paste0(src, '.gz')
  con_in <- file(src, 'rb')
  raw_bytes <- readBin(con_in, what = 'raw', n = file.info(src)$size)
  close(con_in)
  con_out <- gzfile(dst, 'wb')
  writeBin(raw_bytes, con_out)
  close(con_out)
  if (remove && file.exists(dst)) file.remove(src)
  dst
}


# =============================================================================
# Release-currency gate
# =============================================================================

#' Map a USITC release name to a repo revision id
#'
#' "2026HTSRev9" -> "2026_rev_9"; "2026HTSBasic" -> "2026_basic";
#' "2025HTSRev32" -> "rev_32"; "2025HTSBasic" -> "basic" (2025 has no year prefix).
#'
#' @param name Release name from releaseList (e.g., "2026HTSRev9")
#' @return Revision id, or NA_character_ if unparseable
release_name_to_revision <- function(name) {
  m <- regmatches(name, regexec('^([0-9]{4})HTS(Basic|Rev([0-9]+))$', name))[[1]]
  if (length(m) == 0) return(NA_character_)
  year <- m[2]
  rev <- if (m[3] == 'Basic') 'basic' else paste0('rev_', m[4])
  if (year == '2025') rev else paste0(year, '_', rev)
}

#' Is a revision's archive present locally (raw .json or gzipped .json.gz)?
#'
#' @param revision Revision id (e.g., '2026_rev_9')
#' @param archive_dir HTS archive directory
#' @return TRUE if an archive file exists
revision_archive_present <- function(revision, archive_dir = 'data/hts_archives') {
  parsed <- parse_revision_id(revision)
  base <- file.path(archive_dir, paste0('hts_', parsed$year, '_', parsed$rev))
  file.exists(paste0(base, '.json.gz')) || file.exists(paste0(base, '.json'))
}

#' Check whether local archives are current with the USITC HTS release list
#'
#' Counts how many of the most-recent USITC releases are missing locally, walking
#' newest-first until the first present archive. Because the reststop export
#' endpoint can only fetch the CURRENT release (the static archive host is blocked
#' for retrospective files — see download_missing_revisions), the gate is:
#'   - 0 missing             -> 'up_to_date'    (proceed)
#'   - 1 missing (= current) -> 'one_ahead'     (proceed; download step auto-fetches it)
#'   - >=2 missing           -> 'behind_manual' (STOP; the non-current missing revisions
#'                                               cannot be auto-downloaded)
#' A network failure yields 'unknown' (proceed with a warning — never block on a
#' transient error).
#'
#' @param archive_dir HTS archive directory
#' @param api_url releaseList endpoint
#' @return list(status, n_ahead, missing, current_release, message)
check_release_currency <- function(archive_dir = 'data/hts_archives',
                                   api_url = 'https://hts.usitc.gov/reststop/releaseList') {
  releases <- tryCatch({
    old_ua <- getOption('HTTPUserAgent')
    options(HTTPUserAgent = EXPORT_USER_AGENT)
    on.exit(options(HTTPUserAgent = old_ua), add = TRUE)
    jsonlite::fromJSON(api_url, simplifyDataFrame = TRUE)
  }, error = function(e) NULL)

  if (is.null(releases) || !is.data.frame(releases) || nrow(releases) == 0) {
    return(list(status = 'unknown', n_ahead = NA_integer_, missing = character(),
                current_release = NA_character_,
                message = paste0('  HTS release check: could not reach ', api_url,
                                 ' — skipping currency check, proceeding.')))
  }

  # Order newest-first by release start date (fall back to the target date).
  start_d <- as.Date(releases$releaseStartDate, format = '%m/%d/%Y')
  if ('target' %in% names(releases)) {
    start_d[is.na(start_d)] <- as.Date(releases$target[is.na(start_d)], format = '%m/%d/%Y')
  }
  releases <- releases[order(start_d, decreasing = TRUE), ]
  current_release <- releases$name[1]

  # Walk newest-first; count consecutive missing archives until the first present one.
  n_ahead <- 0L
  missing <- character()
  for (i in seq_len(nrow(releases))) {
    rid <- release_name_to_revision(releases$name[i])
    if (is.na(rid)) next
    if (revision_archive_present(rid, archive_dir)) break
    n_ahead <- n_ahead + 1L
    missing <- c(missing, releases$name[i])
  }

  if (n_ahead == 0L) {
    status <- 'up_to_date'
    msg <- paste0('  HTS release check: up to date (current release ', current_release, ').')
  } else if (n_ahead == 1L) {
    status <- 'one_ahead'
    msg <- paste0('  HTS release check: 1 new release (', missing[1], ', the current ',
                  'release) — the download step will fetch it via the export endpoint.')
  } else {
    status <- 'behind_manual'
    msg <- paste0(
      'HTS release check FAILED: the repo is ', n_ahead, ' releases behind USITC.\n',
      '  Missing (newest first): ', paste(missing, collapse = ', '), '\n',
      '  Only the current release (', missing[1], ') can be auto-downloaded; the static ',
      'archive host is blocked for older revisions.\n',
      '  Manually download the older missing revision(s) from hts.usitc.gov and place them ',
      'in ', archive_dir, '/ as hts_<year>_<rev>.json[.gz], then re-run.\n',
      '  (Pass --skip-release-check to bypass this gate.)'
    )
  }
  list(status = status, n_ahead = n_ahead, missing = missing,
       current_release = current_release, message = msg)
}

#' Build USITC download URL for an HTS revision
#'
#' Uses the static file hosting at www.usitc.gov/sites/default/files/tata/hts/
#' (the old hts.usitc.gov/reststop/getJSON endpoint was deprecated in early 2026).
#'
#' @param revision Revision identifier (e.g., 'basic', 'rev_1', '2026_rev_3')
#' @param year HTS year (default: 2025, ignored if revision includes year prefix)
#' @return Character URL
build_download_url <- function(revision, year = 2025) {
  base_url <- 'https://www.usitc.gov/sites/default/files/tata/hts'
  parsed <- parse_revision_id(revision)
  yr <- parsed$year
  rev <- parsed$rev

  if (rev == 'basic') {
    url <- paste0(base_url, '/hts_', yr, '_basic_edition_json.json')
  } else if (grepl('^rev_', rev)) {
    rev_num <- gsub('rev_', '', rev)
    url <- paste0(base_url, '/hts_', yr, '_revision_', rev_num, '_json.json')
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
      on.exit(close(con), add = TRUE)
      first_char <- readChar(con, 1)
      close(con)
      on.exit(NULL)
      if (!first_char %in% c('{', '[')) {
        warning('File does not start with JSON: ', first_char)
        return(FALSE)
      }
    }, error = function(e) {
      warning('Could not validate JSON: ', conditionMessage(e))
      return(FALSE)
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
  # Load expected revisions — use HTS release order for download inventory
  rev_dates <- load_revision_dates(revision_dates_path, use_policy_dates = FALSE)
  expected <- rev_dates$revision

  # Check local inventory across all years present in expected revisions
  years_needed <- unique(map_int(expected, ~ parse_revision_id(.)$year))

  available <- character()
  for (yr in years_needed) {
    yr_revisions <- list_available_revisions(archive_dir, year = yr)
    if (yr != 2025) {
      yr_revisions <- paste0(yr, '_', yr_revisions)
    }
    available <- c(available, yr_revisions)
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

  # Resolved lazily on first static failure (one releaseList call per run).
  current_release <- NA_character_
  current_checked <- FALSE

  for (i in seq_along(missing)) {
    rev <- missing[i]
    message('\n[', i, '/', length(missing), '] Downloading ', rev, '...')

    url <- build_download_url(rev)

    parsed <- parse_revision_id(rev)
    dest <- file.path(archive_dir, paste0('hts_', parsed$year, '_', parsed$rev, '.json'))

    success <- download_hts_json(url, dest)

    # Fallback: the static archive host (www.usitc.gov) is intermittently
    # Akamai-blocked (403). The reststop export endpoint still works but ONLY
    # serves the current release, so use it only when this revision IS current.
    if (!success) {
      if (!current_checked) {
        current_release <- get_current_release_name()
        current_checked <- TRUE
      }
      this_release <- build_release_name(rev)
      if (!is.na(current_release) && identical(this_release, current_release)) {
        message('  Static download failed; ', rev, ' is the current release (',
                current_release, ') — trying reststop export endpoint.')
        success <- download_hts_via_export(dest)
      } else {
        cur_label <- if (is.na(current_release)) 'unknown' else current_release
        message('  Static download failed and ', rev, ' is not the current ',
                'release (current: ', cur_label, '). The export endpoint cannot ',
                'serve archived revisions — download this file manually from ',
                'hts.usitc.gov and place it at ', dest, '.')
      }
    }

    # Store gzipped to match the committed archive format. fromJSON() reads
    # .json.gz transparently, so keeping only the .gz keeps the repo lean.
    if (success && file.exists(dest)) {
      gz <- tryCatch(gzip_file(dest), error = function(e) {
        message('  (kept raw .json; gzip failed: ', conditionMessage(e), ')'); dest
      })
      message('  Stored: ', gz)
    }

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
  source(here('src', 'core', 'helpers.R'))

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
