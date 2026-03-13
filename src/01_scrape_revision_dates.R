# =============================================================================
# Step 01: Scrape Revision Effective Dates from USITC API
# =============================================================================
#
# Fetches HTS revision release dates from the USITC REST API and updates
# config/revision_dates.csv. Manually-curated columns (tpc_date,
# policy_event, tpc_policy_revision) are preserved on merge.
#
# API: https://hts.usitc.gov/reststop/releaseList
#
# Output: config/revision_dates.csv with columns:
#   - revision: Revision identifier (e.g., 'basic', 'rev_1', '2026_basic')
#   - effective_date: Date the revision took effect (from releaseStartDate)
#   - tpc_date: Matching TPC validation date (manually curated)
#   - policy_event: Description of the policy change (manually curated)
#   - tpc_policy_revision: TPC policy revision mapping (manually curated)
#
# Usage:
#   Rscript src/01_scrape_revision_dates.R           # update CSV
#   Rscript src/01_scrape_revision_dates.R --dry-run  # preview without writing
#
# =============================================================================

library(tidyverse)
library(jsonlite)


# =============================================================================
# API Functions
# =============================================================================

#' Convert USITC release name to tracker revision identifier
#'
#' Maps API names like "2025HTSBasic" -> "basic", "2025HTSRev1" -> "rev_1",
#' "2026HTSBasic" -> "2026_basic", "2026HTSRev4" -> "2026_rev_4".
#'
#' The 2025 year prefix is dropped (2025 is the default year in the tracker).
#' All other years are kept as a prefix.
#'
#' @param api_name Character: release name from USITC API (e.g., "2026HTSRev4")
#' @return Character: tracker revision ID (e.g., "2026_rev_4"), or NA if unparseable
api_name_to_revision <- function(api_name) {
  # Pattern: {year}HTS{Basic|Rev{N}}
  m <- str_match(api_name, '^(\\d{4})HTS(Basic|Rev(\\d+))$')
  if (is.na(m[1, 1])) return(NA_character_)

  year <- as.integer(m[1, 2])
  is_basic <- m[1, 3] == 'Basic'
  rev_num <- m[1, 4]  # NA for basic

  rev_id <- if (is_basic) 'basic' else paste0('rev_', rev_num)

  # 2025 is the default year — no prefix needed

  if (year == 2025L) return(rev_id)
  paste0(year, '_', rev_id)
}


#' Fetch revision dates from USITC REST API
#'
#' Calls hts.usitc.gov/reststop/releaseList and parses release metadata.
#' Filters to years >= min_year and returns a tibble with revision IDs
#' and effective dates (releaseStartDate).
#'
#' @param api_url USITC release list API endpoint
#' @param min_year Minimum year to include (default: 2025)
#' @return Tibble with revision, effective_date; or NULL on failure
fetch_usitc_releases <- function(
  api_url = 'https://hts.usitc.gov/reststop/releaseList',
  min_year = 2025L
) {
  message('Fetching release list from USITC API...')

  # Fetch and parse — network errors are caught; code errors propagate
  raw <- tryCatch(
    fromJSON(api_url, simplifyDataFrame = TRUE),
    error = function(e) {
      message('  API fetch failed (network/HTTP): ', conditionMessage(e))
      return(NULL)
    }
  )

  if (is.null(raw) || length(raw) == 0) {
    message('  API returned empty or null response.')
    return(NULL)
  }

  # Parse releases — errors here are code bugs, not API issues, so let them propagate
  releases <- as_tibble(raw) %>%
    filter(!is.na(name), !is.na(releaseStartDate)) %>%
    mutate(
      revision = map_chr(name, api_name_to_revision),
      effective_date = as.Date(releaseStartDate, format = '%m/%d/%Y'),
      release_end = as.Date(releaseEndDate, format = '%m/%d/%Y'),
      api_status = status
    ) %>%
    filter(
      !is.na(revision),
      !is.na(effective_date),
      as.integer(format(effective_date, '%Y')) >= min_year |
        grepl(paste0('^', min_year), revision)
    ) %>%
    select(revision, effective_date, api_status, name) %>%
    arrange(effective_date)

  message('  Fetched ', nrow(releases), ' releases (', min_year, '+)')
  return(releases)
}


#' Update revision_dates.csv with API data
#'
#' Merges API-fetched releases into the existing CSV. Rules:
#'   - Existing revisions: keep curated effective_date (policy date, not API
#'     publication date — these differ, often by weeks)
#'   - New revisions: append with API publication date as a placeholder;
#'     the user should manually set the correct policy effective_date
#'   - Revisions only in CSV (not in API): keep as-is
#'
#' @param csv_path Path to revision_dates.csv
#' @param api_releases Tibble from fetch_usitc_releases()
#' @param dry_run If TRUE, print changes but don't write
#' @return Updated tibble (invisibly)
update_revision_dates <- function(csv_path, api_releases, dry_run = FALSE) {
  # Read existing CSV
  existing <- suppressWarnings(
    read_csv(csv_path, col_types = cols(.default = col_character()))
  ) %>%
    mutate(effective_date = as.Date(effective_date))

  # Identify new revisions not yet in CSV
  new_revs <- api_releases %>%
    filter(!revision %in% existing$revision)

  if (nrow(new_revs) == 0) {
    message('\nNo new revisions found — CSV is up to date.')
    return(invisible(existing))
  }

  message('\n', strrep('!', 70))
  message('ACTION REQUIRED: ', nrow(new_revs), ' new revision(s) detected')
  message(strrep('!', 70))
  message('')
  message('The USITC API returns publication dates, NOT policy effective dates.')
  message('These often differ by weeks (e.g., a Feb 4 tariff may not appear in')
  message('the HTS until Mar 6). Until you manually correct the effective_date,')
  message('the pipeline will use the publication date for timeseries intervals,')
  message('which will misplace the policy change in time.')
  message('')
  message('New revisions (publication date shown):')
  for (i in seq_len(nrow(new_revs))) {
    message('  + ', new_revs$revision[i], '  published ', new_revs$effective_date[i])
  }
  message('')
  message('After this script finishes:')
  message('  1. Open config/revision_dates.csv')
  message('  2. Set the correct policy effective_date for each new revision')
  message('  3. Add a policy_event description')
  message('  4. Run Rscript src/02_download_hts.R to fetch the new JSON')
  message(strrep('!', 70))

  # Append new revisions with API publication date as placeholder.
  # needs_review = TRUE prevents the build from running until the user
  # manually sets the correct policy effective_date and clears the flag.
  new_rows <- new_revs %>%
    select(revision, effective_date) %>%
    mutate(
      tpc_date = NA_character_,
      policy_event = paste0('[REVIEW] added ', Sys.Date(), ' — effective_date is publication date, not policy date'),
      tpc_policy_revision = NA_character_,
      needs_review = 'TRUE'
    )
  updated <- bind_rows(existing, new_rows) %>%
    arrange(effective_date)

  if (dry_run) {
    message('\n[DRY RUN] Would write ', nrow(updated), ' revisions to ', csv_path)
    cat('\n')
    print(updated, n = Inf)
  } else {
    write_csv(updated, csv_path)
    message('\nWrote ', nrow(updated), ' revisions to ', csv_path)
  }

  return(invisible(updated))
}


# =============================================================================
# Chapter 99 PDF Change Detection
# =============================================================================

#' Check whether the Chapter 99 PDF has changed since last check
#'
#' Downloads the current Chapter 99 PDF from USITC, computes its SHA-256 hash,
#' and compares against a stored hash file. A change in the PDF — even without
#' a new revision in the release API — may signal an amendment or pending
#' revision that has not yet been published as a separate release.
#'
#' Design:
#'   - The probe download is kept separate from the shared parser cache
#'     (data/us_notes/chapter99.pdf) used by scrape_us_notes.R.
#'   - When a change is detected, a pending marker is written instead of
#'     immediately advancing the stored hash. The hash is only updated when
#'     the user explicitly acknowledges by running with --accept-pdf-hash.
#'   - The download is validated (PDF signature check, minimum size).
#'
#' @param hash_path Path to the last-known hash file
#' @param pending_path Path to the pending-change marker file
#' @return List with changed (logical), current_hash, previous_hash
check_chapter99_pdf_changed <- function(
  hash_path = here('config', '.chapter99_hash'),
  pending_path = here('config', '.chapter99_pending')
) {
  pdf_url <- 'https://hts.usitc.gov/reststop/file?release=currentRelease&filename=Chapter+99'
  probe_dir <- tempdir()
  probe_path <- file.path(probe_dir, 'chapter99_probe.pdf')

  # Download into temp directory — never touch the shared parser cache
  tryCatch({
    message('Downloading Chapter 99 PDF for hash check...')
    suppressWarnings(download.file(pdf_url, probe_path, mode = 'wb', quiet = TRUE))
  }, error = function(e) {
    message('  PDF download failed: ', conditionMessage(e))
    return(list(changed = NA, current_hash = NA, previous_hash = NA))
  })

  if (!file.exists(probe_path) || file.size(probe_path) < 1024) {
    message('  PDF download produced empty or missing file — skipping.')
    if (file.exists(probe_path)) file.remove(probe_path)
    return(list(changed = NA, current_hash = NA, previous_hash = NA))
  }

  # Validate PDF signature (%PDF magic bytes)
  sig <- readBin(probe_path, 'raw', n = 4)
  if (!identical(sig, charToRaw('%PDF'))) {
    message('  Downloaded file is not a valid PDF (bad signature) — skipping.')
    file.remove(probe_path)
    return(list(changed = NA, current_hash = NA, previous_hash = NA))
  }

  current_hash <- digest::digest(file = probe_path, algo = 'sha256')
  file_size_mb <- round(file.size(probe_path) / 1e6, 1)
  message('  PDF size: ', file_size_mb, ' MB, SHA-256: ', substr(current_hash, 1, 16), '...')
  file.remove(probe_path)

  # Compare with stored hash
  previous_hash <- NA_character_
  if (file.exists(hash_path)) {
    previous_hash <- trimws(readLines(hash_path, n = 1))
  }

  changed <- is.na(previous_hash) || current_hash != previous_hash

  # Check for existing pending marker
  has_pending <- file.exists(pending_path)

  if (is.na(previous_hash)) {
    message('  No previous hash stored — recording current hash.')
    # First run: safe to store hash directly (no change to detect)
    writeLines(current_hash, hash_path)
  } else if (changed) {
    message('  ', strrep('!', 50))
    message('  CHAPTER 99 PDF HAS CHANGED')
    message('  ', strrep('!', 50))
    message('  Previous: ', substr(previous_hash, 1, 16), '...')
    message('  Current:  ', substr(current_hash, 1, 16), '...')
    message('  This may indicate a new revision or amendment.')
    message('')
    message('  Next steps:')
    message('    1. Run: Rscript src/scrape_us_notes.R --all')
    message('    2. Review regenerated resource files for changes')
    message('    3. Run: Rscript src/01_scrape_revision_dates.R --accept-pdf-hash')
    message('       to clear this alert')
    # Write pending marker — hash is NOT advanced until acknowledged
    writeLines(current_hash, pending_path)
  } else if (has_pending) {
    message('  PDF unchanged, but a previous change is still pending acknowledgment.')
    message('  Run with --accept-pdf-hash to clear the pending alert.')
  } else {
    message('  PDF unchanged since last check.')
  }

  return(list(changed = changed, current_hash = current_hash, previous_hash = previous_hash))
}


#' Accept pending PDF hash (clear the alert)
#'
#' Advances the stored hash to the pending value and removes the marker.
#'
#' @param hash_path Path to the hash file
#' @param pending_path Path to the pending-change marker file
accept_chapter99_hash <- function(
  hash_path = here('config', '.chapter99_hash'),
  pending_path = here('config', '.chapter99_pending')
) {
  if (!file.exists(pending_path)) {
    message('  No pending PDF change to accept.')
    return(invisible(FALSE))
  }
  pending_hash <- trimws(readLines(pending_path, n = 1))
  writeLines(pending_hash, hash_path)
  file.remove(pending_path)
  message('  Accepted PDF hash: ', substr(pending_hash, 1, 16), '...')
  message('  Alert cleared.')
  return(invisible(TRUE))
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)
  source(here('src', 'helpers.R'))

  args <- commandArgs(trailingOnly = TRUE)
  dry_run <- '--dry-run' %in% args

  csv_path <- here('config', 'revision_dates.csv')

  # Fetch from API
  api_releases <- fetch_usitc_releases()

  if (!is.null(api_releases)) {
    update_revision_dates(csv_path, api_releases, dry_run = dry_run)
  } else {
    message('API unavailable — no changes made.')
  }

  # Cross-reference with available JSON files
  dates <- load_revision_dates(csv_path)
  all_revisions <- dates$revision
  archive_dir <- here('data', 'hts_archives')

  available <- character()
  for (rev_id in all_revisions) {
    parsed <- parse_revision_id(rev_id)
    json_name <- paste0('hts_', parsed$year, '_', parsed$rev, '.json')
    if (file.exists(file.path(archive_dir, json_name))) {
      available <- c(available, rev_id)
    }
  }

  missing_json <- setdiff(all_revisions, available)
  missing_csv <- character()

  # Check for JSON files not in CSV
  json_files <- list.files(archive_dir, pattern = 'hts_\\d{4}_.*\\.json$')
  for (f in json_files) {
    m <- str_match(f, 'hts_(\\d{4})_(.*)\\.json$')
    if (is.na(m[1, 1])) next
    year <- as.integer(m[1, 2])
    rev <- m[1, 3]
    rev_id <- if (year == 2025L) rev else paste0(year, '_', rev)
    if (!rev_id %in% all_revisions) missing_csv <- c(missing_csv, rev_id)
  }

  if (length(missing_json) > 0) {
    message('\nRevisions in CSV but no JSON: ', paste(missing_json, collapse = ', '))
  }
  if (length(missing_csv) > 0) {
    message('\nJSON files without CSV entry: ', paste(missing_csv, collapse = ', '))
  }

  # --- Chapter 99 PDF change detection ---
  accept_hash <- '--accept-pdf-hash' %in% args
  if (accept_hash) {
    accept_chapter99_hash()
  } else if (requireNamespace('digest', quietly = TRUE)) {
    check_chapter99_pdf_changed()
  } else {
    message('\nSkipping PDF hash check (install digest package: install.packages("digest"))')
  }

  message('\n=== Revision Date Summary ===')
  message('Total revisions: ', nrow(dates))
  message('With JSON: ', length(available))
  message('With TPC date: ', sum(!is.na(dates$tpc_date)))

  if (dry_run) message('\n[DRY RUN mode — no files were modified]')
}
