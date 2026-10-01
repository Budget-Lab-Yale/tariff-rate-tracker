## Audit the Chapter 99 cross-reference footnote population across HTS revisions
## Outputs: output/changelog/footnote_profile.csv, output/changelog/footnote_deltas.csv
##
## Usage: Rscript tools/footnote_audit.R [--refresh]
##
## HTS 2026 rev_13 silently dropped 98.8% of the columns:['general'] endnote
## class — the "See 9903.88.15."-style cross-references that seed ch99_refs
## (04_parse_products.R:146) and the footnote-rate join in calculate_rates_fast()
## (06_calculate_rates.R:18,45). No change record mentioned it: rev_15's states
## outright that it excludes "endnotes", and rev_13/rev_14's do not mention
## footnotes at all. Neither a record-count diff nor a Ch1-97 general-rate diff
## can see it, which is how it passed as a rate-neutral ingest and surfaced two
## revisions later during an unrelated file-size check.
##
## This audit profiles footnotes per (columns, type) class rather than on a
## single total — the total is stable enough to hide a swap — and fails on any
## unwaived move beyond tolerance. See docs/proposed_mod_combined_2026_08_07.md
## §0.2 and §3 test 3.

library(tidyverse)
library(jsonlite)
library(here)

source(here('src', 'core', 'helpers.R'))


# --- Thresholds --------------------------------------------------------------
# A class must move by more than FOOTNOTE_MOVE_TOLERANCE (relative to its
# previous count) AND have been at least FOOTNOTE_MIN_CLASS_SIZE entries before
# the audit calls it a breach: small classes churn by a handful of entries on
# almost every revision, and flagging those would bury the signal in waivers.
FOOTNOTE_MOVE_TOLERANCE <- 0.10
FOOTNOTE_MIN_CLASS_SIZE <- 25

# The same pattern extract_chapter99_refs() uses (helpers.R), so the audited
# metric is the one the calculator actually joins on rather than a proxy.
CH99_REF_PATTERN <- '9903\\.[0-9]{2}\\.[0-9]{2}'

# Audited alongside the per-class counts: the Chapter 1-97 line count is what
# directly determines §301 exclusion scope, and it is the number that collapsed.
CH99_REF_LINE_CLASS <- '<ch1-97 lines citing 9903>'

FOOTNOTE_WAIVERS_PATH <- here('config', 'footnote_waivers.csv')
FOOTNOTE_CACHE_DIR <- here('data', 'processed', 'footnote_profiles')


#' Stable identity for one footnote's (columns, type) class
#'
#' @param fn A footnote object from the HTS JSON (columns, value, type)
#' @return Single string, e.g. "[general] endnote"
footnote_class_key <- function(fn) {
  cols <- unlist(fn$columns, use.names = FALSE)
  cols <- if (length(cols) > 0) paste(sort(as.character(cols)), collapse = ',') else '(none)'
  paste0('[', cols, '] ', fn$type %||% '(untyped)')
}


#' Profile the footnote population of one HTS archive
#'
#' @param json_path Path to an hts_<year>_<rev>.json.gz archive
#' @return List with per-class counts and the Ch1-97 cross-reference line count
profile_archive_footnotes <- function(json_path) {
  records <- fromJSON(json_path, simplifyVector = FALSE)

  class_keys <- unlist(lapply(records, function(rec) {
    footnotes <- rec$footnotes
    if (is.null(footnotes) || length(footnotes) == 0) return(NULL)
    vapply(footnotes, footnote_class_key, character(1))
  }), use.names = FALSE)

  htsno <- vapply(records, function(rec) as.character(rec$htsno %||% ''), character(1))
  chapter <- suppressWarnings(as.integer(substr(gsub('[^0-9]', '', htsno), 1, 2)))
  in_ch1_97 <- nzchar(htsno) & !is.na(chapter) & chapter >= 1 & chapter <= 97

  cites_ch99 <- vapply(records, function(rec) {
    footnotes <- rec$footnotes
    if (is.null(footnotes) || length(footnotes) == 0) return(FALSE)
    any(vapply(footnotes, function(fn) {
      value <- fn$value
      if (is.null(value) || length(value) != 1L) return(FALSE)
      str_detect(as.character(value), CH99_REF_PATTERN)
    }, logical(1)))
  }, logical(1))

  classes <- tibble(footnote_class = class_keys) %>%
    count(footnote_class, name = 'n')

  # The Ch1-97 line count rides in the same table so waivers, tolerance, and
  # reporting treat it identically to a footnote class.
  classes <- bind_rows(classes, tibble(
    footnote_class = CH99_REF_LINE_CLASS,
    n = sum(in_ch1_97 & cites_ch99)
  ))

  list(
    classes = classes,
    n_records = length(records),
    n_footnotes = length(class_keys)
  )
}


#' Profile one revision, caching by archive size + mtime
#'
#' @param revision Revision identifier (e.g. '2026_rev_13')
#' @param archive_dir HTS archive directory
#' @param refresh Recompute even when a cache entry matches
#' @return The profile_archive_footnotes() list
revision_footnote_profile <- function(revision,
                                      archive_dir = here('data', 'hts_archives'),
                                      refresh = FALSE) {
  json_path <- resolve_json_path(revision, archive_dir)
  info <- file.info(json_path)
  stamp <- paste0(as.integer(info$size), '-', as.integer(info$mtime))
  cache_path <- file.path(FOOTNOTE_CACHE_DIR, paste0(revision, '-', stamp, '.rds'))

  if (!refresh && file.exists(cache_path)) return(readRDS(cache_path))

  profile <- profile_archive_footnotes(json_path)
  if (!dir.exists(FOOTNOTE_CACHE_DIR)) dir.create(FOOTNOTE_CACHE_DIR, recursive = TRUE)
  saveRDS(profile, cache_path)
  profile
}


#' Load the documented-waiver registry
#'
#' @param path CSV with from_revision, to_revision, footnote_class, reason
#' @return Tibble; empty (with the right columns) when the file is absent
load_footnote_waivers <- function(path = FOOTNOTE_WAIVERS_PATH) {
  empty <- tibble(from_revision = character(), to_revision = character(),
                  footnote_class = character(), reason = character())
  if (!file.exists(path)) return(empty)

  waivers <- read_csv(path, col_types = cols(.default = col_character()),
                      comment = '#')
  required <- names(empty)
  missing <- setdiff(required, names(waivers))
  if (length(missing) > 0) {
    stop('footnote_waivers.csv is missing column(s): ', paste(missing, collapse = ', '))
  }
  # An omitted trailing field reads as NA, and nzchar(NA) is TRUE — test the
  # missing case explicitly or a reasonless waiver passes silently.
  if (any(is.na(waivers$reason) | !nzchar(trimws(waivers$reason)))) {
    stop('footnote_waivers.csv has a waiver with an empty reason; a waiver ',
         'without a documented reason is exactly the silence this audit exists ',
         'to prevent.')
  }
  waivers
}


#' Diff two revisions' footnote profiles
#'
#' @param from_revision,to_revision Revision identifiers
#' @param from_profile,to_profile Profiles from revision_footnote_profile()
#' @param waivers Waiver registry from load_footnote_waivers()
#' @return Tibble, one row per class, with move share, breach and waived flags
compare_footnote_profiles <- function(from_revision, to_revision,
                                      from_profile, to_profile, waivers) {
  waived <- waivers %>%
    filter(from_revision == !!from_revision, to_revision == !!to_revision) %>%
    pull(footnote_class)

  full_join(from_profile$classes, to_profile$classes,
            by = 'footnote_class', suffix = c('_from', '_to')) %>%
    # A class absent on one side is a true zero (set difference), not a missing
    # observation — the join is the only place a count can be NA here.
    mutate(
      n_from = coalesce(n_from, 0L),
      n_to = coalesce(n_to, 0L),
      from_revision = from_revision,
      to_revision = to_revision,
      delta = n_to - n_from,
      move_share = if_else(n_from > 0, abs(delta) / n_from, 0),
      breached = n_from >= FOOTNOTE_MIN_CLASS_SIZE & move_share > FOOTNOTE_MOVE_TOLERANCE,
      waived = footnote_class %in% waived
    ) %>%
    select(from_revision, to_revision, footnote_class,
           n_from, n_to, delta, move_share, breached, waived) %>%
    arrange(desc(breached & !waived), desc(move_share))
}


#' Audit every consecutive pair of revisions that has an archive on disk
#'
#' @param revisions Ordered revision identifiers; defaults to revision_dates.csv
#' @param archive_dir HTS archive directory
#' @param refresh Recompute profiles rather than reading the cache
#' @return Tibble of per-class deltas across all audited pairs
audit_footnote_population <- function(revisions = NULL,
                                      archive_dir = here('data', 'hts_archives'),
                                      refresh = FALSE) {
  if (is.null(revisions)) {
    revisions <- load_revision_dates(here('config', 'revision_dates.csv'),
                                     use_policy_dates = FALSE)$revision
  }

  available <- revisions[vapply(revisions, function(rev) {
    !inherits(try(resolve_json_path(rev, archive_dir), silent = TRUE), 'try-error')
  }, logical(1))]

  if (length(available) < 2) {
    return(compare_footnote_profiles(
      character(0), character(0),
      list(classes = tibble(footnote_class = character(), n = integer())),
      list(classes = tibble(footnote_class = character(), n = integer())),
      load_footnote_waivers()
    ))
  }

  waivers <- load_footnote_waivers()
  profiles <- setNames(
    lapply(available, revision_footnote_profile, archive_dir = archive_dir, refresh = refresh),
    available
  )

  map_dfr(seq.int(2, length(available)), function(i) {
    compare_footnote_profiles(available[i - 1], available[i],
                              profiles[[i - 1]], profiles[[i]], waivers)
  })
}


#' Print the audit and write its CSVs; stop on unwaived breaches
run_footnote_audit <- function(refresh = FALSE) {
  deltas <- audit_footnote_population(refresh = refresh)
  if (nrow(deltas) == 0) {
    cat('Fewer than two archives on disk — nothing to compare.\n')
    return(invisible(deltas))
  }

  out_dir <- here('output', 'changelog')
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
  write_csv(deltas, file.path(out_dir, 'footnote_deltas.csv'))

  profile_wide <- deltas %>%
    select(revision = to_revision, footnote_class, n = n_to) %>%
    distinct() %>%
    pivot_wider(names_from = revision, values_from = n)
  write_csv(profile_wide, file.path(out_dir, 'footnote_profile.csv'))

  waived <- deltas %>% filter(breached, waived)
  if (nrow(waived) > 0) {
    cat('\nWAIVED moves (documented in config/footnote_waivers.csv):\n')
    waived %>%
      mutate(move = sprintf('%+d (%.1f%%)', delta, move_share * 100)) %>%
      select(from_revision, to_revision, footnote_class, n_from, n_to, move) %>%
      as.data.frame() %>% print(row.names = FALSE)
  }

  breaches <- deltas %>% filter(breached, !waived)
  if (nrow(breaches) > 0) {
    cat('\nUNWAIVED footnote-population moves:\n')
    breaches %>%
      mutate(move = sprintf('%+d (%.1f%%)', delta, move_share * 100)) %>%
      select(from_revision, to_revision, footnote_class, n_from, n_to, move) %>%
      as.data.frame() %>% print(row.names = FALSE)
    stop(nrow(breaches), ' unwaived footnote-population move(s) beyond ',
         FOOTNOTE_MOVE_TOLERANCE * 100, '%. Either the ingest dropped ',
         'cross-references the calculator joins on, or the move is real and ',
         'belongs in config/footnote_waivers.csv with a reason.')
  }

  cat('\nNo unwaived footnote-population moves across ',
      length(unique(c(deltas$from_revision, deltas$to_revision))),
      ' revisions.\n', sep = '')
  invisible(deltas)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  run_footnote_audit(refresh = '--refresh' %in% commandArgs(trailingOnly = TRUE))
}
