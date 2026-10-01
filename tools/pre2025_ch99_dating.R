#!/usr/bin/env Rscript
# =============================================================================
# Phase 2b: Chapter 99 onset worksheet for dating the pre-2025 revisions
# =============================================================================
#
# The pre-2025 rows of config/revision_dates.csv are dated at the USITC release
# start, but a measure's LEGAL start often differs — by days usually, by months
# where JSON editions are missing (2018: §232 metals took effect 2018-03-23 and
# first appear in the 2018-08-07 edition). This tool produces the evidence for
# curating those dates:
#
#   1. Diff the 9903.* headings between consecutive pre-2025 editions (in
#      revision_dates.csv order): which headings each revision ADDS, and which
#      change their general-rate text.
#   2. Join each to its legal begin date from the USITC Annual Tariff Database,
#      which carries begin_effect_date per Chapter 99 line. Where a heading has
#      several begin dates across years, the one nearest the release is taken.
#   3. Flag ONSET headings — those carrying an added or flat duty, or whose rate
#      changed. Exclusion headings (no added duty) are not onsets: they were
#      granted retroactively, the tracker does not model retroactivity, so they
#      stay on their publication date. Quota headings ("Free") are dated to the
#      quota year (1 Jan), not the measure, so they are not onsets either.
#
# The output is a WORKSHEET, not configuration. The curated results live in
# config/revision_dates.csv (policy_effective_date) and
# resources/pre2025_ch99_activation_dates.csv; this tool never writes either.
#
# Annual-database quirks handled here: per-year schema and delimiter drift (the
# dates are located by VALUE, the first two date fields on a row being
# begin/end), and the 2019 zip, whose .txt is a stale 2018-11 file — the real
# 2019 database is its .xlsx.
#
# Usage:
#   Rscript tools/pre2025_ch99_dating.R
#   Rscript tools/pre2025_ch99_dating.R --out /path/to/worksheet.csv
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
  library(jsonlite)
})
source(here('tools', 'pre2025_archive_lib.R'))

args <- commandArgs(trailingOnly = TRUE)
arg_val <- function(flag, default) {
  if (flag %in% args) args[which(args == flag) + 1] else default
}
out_path    <- arg_val('--out', here('resources', 'pre2025_ch99_onset_worksheet.csv'))
store       <- arg_val('--store', hts_store_dir())
archive_dir <- here('data', 'hts_archives')

ERA_LAST_YEAR <- 2024L
DATE_RE <- '^\\s*(\\d{1,2}/\\d{1,2}/\\d{4}|\\d{4}-\\d{2}-\\d{2})'

banner('Pre-2025 Chapter 99 onset worksheet\nstore: ', store, '\nout:   ', out_path)


# --- 1. Heading diffs between consecutive editions ---------------------------

era_revisions <- read_csv(here('config', 'revision_dates.csv'),
                          col_types = cols(.default = col_character())) %>%
  mutate(year = as.integer(str_extract(revision, '^\\d{4}(?=_)'))) %>%
  filter(!is.na(year), year <= ERA_LAST_YEAR) %>%
  mutate(release_date = as.Date(effective_date)) %>%
  arrange(release_date)

read_ch99_headings <- function(rev_id) {
  recs <- fromJSON(file.path(archive_dir, paste0('hts_', rev_id, '.json.gz')),
                   simplifyDataFrame = TRUE)
  tibble(htsno = str_trim(recs$htsno), general = str_trim(coalesce(recs$general, ''))) %>%
    filter(str_starts(htsno, '9903')) %>%
    distinct(htsno, .keep_all = TRUE)
}

changes <- list()
prev <- NULL
for (i in seq_len(nrow(era_revisions))) {
  rev_id <- era_revisions$revision[i]
  cur <- read_ch99_headings(rev_id)
  if (!is.null(prev)) {
    joined <- full_join(prev, cur, by = 'htsno', suffix = c('_prev', ''))
    changes[[rev_id]] <- joined %>%
      mutate(change = case_when(
        is.na(general_prev) ~ 'added',
        is.na(general)      ~ 'removed',
        general != general_prev ~ 'rate_changed',
        TRUE ~ NA_character_
      )) %>%
      filter(!is.na(change)) %>%
      mutate(revision = rev_id, release_date = era_revisions$release_date[i],
             prev_revision = era_revisions$revision[i - 1])
  }
  prev <- cur
}
changes <- bind_rows(changes)
message('  ', nrow(era_revisions), ' editions, ', nrow(changes), ' heading changes')


# --- 2. Legal begin dates from the Annual Tariff Database ---------------------

first_two_dates <- function(row) {
  hits <- row[str_detect(row, DATE_RE) %in% TRUE]
  if (length(hits) < 2) return(c(NA_character_, NA_character_))
  s <- str_match(hits[1:2], DATE_RE)[, 2]
  format(if_else(str_detect(s, '/'), as.Date(s, '%m/%d/%Y'), as.Date(s, '%Y-%m-%d')))
}

ch99_rows_from_table <- function(tbl, source) {
  tbl <- as.data.frame(tbl, stringsAsFactors = FALSE)
  code <- str_remove_all(tbl[[1]], '\\D')
  tbl <- tbl[str_starts(code, '9903') %in% TRUE, , drop = FALSE]
  if (nrow(tbl) == 0) return(tibble())
  dates <- t(apply(as.matrix(tbl), 1, first_two_dates))
  code <- str_remove_all(tbl[[1]], '\\D')
  tibble(source = source,
         htsno = paste0(str_sub(code, 1, 4), '.', str_sub(code, 5, 6), '.', str_sub(code, 7, 8)),
         begin = as.Date(dates[, 1]), end = as.Date(dates[, 2])) %>%
    filter(!is.na(begin))
}

read_annual_db <- function(zip_path) {
  tmp <- tempfile('annual_db_'); dir.create(tmp)
  on.exit(unlink(tmp, recursive = TRUE))
  members <- unzip(zip_path, list = TRUE)$Name
  is_2019 <- str_detect(basename(zip_path), '2019')
  # The 2019 zip's .txt is a stale 2018-11 file; its .xlsx is the 2019 database.
  member <- if (is_2019) members[str_ends(members, '.xlsx')][1] else members[str_ends(members, '.txt')][1]
  unzip(zip_path, files = member, exdir = tmp)
  path <- file.path(tmp, member)
  tbl <- if (str_ends(member, '.xlsx')) {
    x <- readxl::read_excel(path, col_types = 'text')
    for (col in str_subset(names(x), 'date')) {
      serial <- suppressWarnings(as.numeric(x[[col]]))
      x[[col]] <- if_else(is.na(serial), x[[col]],
                          format(as.Date(serial, origin = '1899-12-30'), '%m/%d/%Y'))
    }
    x
  } else {
    first <- readLines(path, n = 1, warn = FALSE)
    delim <- c(',', '|', '\t')[which.max(str_count(first, fixed(c(',', '|', '\t'))))]
    read_delim(path, delim = delim, col_names = FALSE, col_types = cols(.default = col_character()),
               locale = locale(encoding = 'latin1'), progress = FALSE, show_col_types = FALSE)
  }
  ch99_rows_from_table(tbl, paste0(basename(zip_path), ':', member))
}

zips <- sort(list.files(file.path(store, 'zips'), pattern = '^tariff_data_\\d{4}\\.zip$', full.names = TRUE))
if (length(zips) == 0) stop('no annual tariff database zips under ', file.path(store, 'zips'))
annual_db <- map_dfr(zips, read_annual_db)
message('  annual database: ', nrow(annual_db), ' Chapter 99 rows from ', length(zips), ' files')


# --- 3. Join, flag onsets, write ----------------------------------------------

begin_dates <- annual_db %>% distinct(htsno, begin)

nearest_begin <- changes %>%
  select(revision, release_date, htsno) %>%
  inner_join(begin_dates, by = 'htsno', relationship = 'many-to-many') %>%
  group_by(revision, htsno) %>%
  slice_min(abs(as.numeric(begin - release_date)), n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  select(revision, htsno, legal_begin = begin)

worksheet <- changes %>%
  left_join(nearest_begin, by = c('revision', 'htsno')) %>%
  mutate(
    carries_duty = str_detect(str_to_lower(general), '\\+\\s*\\d|plus\\s*\\d|^\\d+(\\.\\d+)?%$'),
    onset = change == 'rate_changed' | (change == 'added' & carries_duty),
    lag_days = as.integer(release_date - legal_begin)
  ) %>%
  select(revision, release_date, prev_revision, htsno, change, onset,
         legal_begin, lag_days, general_prev, general) %>%
  arrange(release_date, htsno)

write_csv(worksheet, out_path, na = '')
message('  onset headings: ', sum(worksheet$onset), ' (', sum(worksheet$onset & is.na(worksheet$legal_begin)),
        ' with no annual-database date)')
message('Wrote ', out_path)
