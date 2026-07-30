#!/usr/bin/env Rscript
# =============================================================================
# Phase 1 acquisition: Chapter 99 PDFs + Change Records from hts.usitc.gov
# =============================================================================
#
# `hts.usitc.gov/reststop/file?release=<name>&filename=Chapter+99` serves the
# Chapter 99 PDF for EVERY release back to 2015 — including the ~11 2018
# editions that have no machine-readable JSON anywhere. That makes it the
# documented gap-filler: where JSON acquisition fails, Phase 2 builds the
# Chapter 99 layer from the PDF plus the Annual Tariff Database.
#
# Unlike www.usitc.gov, hts.usitc.gov is reachable from this cluster, so these
# are fetched directly (no Wayback hop).
#
# What it fetches:
#   Chapter 99 PDF  — for 2016-2024 releases with NO usable JSON in the store
#                     (or every release with --all-ch99)
#   Change Record   — for EVERY 2016-2024 release. These are small (~100 KB)
#                     and are the primary evidence for Phase 2's
#                     revision_dates.csv curation, so completeness is cheap.
#
# Usage:
#   Rscript tools/pre2025_fetch_chapter99.R
#   Rscript tools/pre2025_fetch_chapter99.R --years 2018 --all-ch99
#   Rscript tools/pre2025_fetch_chapter99.R --dry-run
#   Rscript tools/pre2025_fetch_chapter99.R --no-change-record
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})
source(here('tools', 'pre2025_archive_lib.R'))

args <- commandArgs(trailingOnly = TRUE)
arg_val <- function(flag, default) {
  if (flag %in% args) args[which(args == flag) + 1] else default
}
years    <- as.integer(strsplit(arg_val('--years', paste(2016:2024, collapse = ',')), ',')[[1]])
dry_run  <- '--dry-run' %in% args
all_ch99 <- '--all-ch99' %in% args
do_cr    <- !('--no-change-record' %in% args)
store    <- arg_val('--store', hts_store_dir())

pdf_dir <- file.path(store, 'pdf')
dir.create(pdf_dir, recursive = TRUE, showWarnings = FALSE)

FILE_ENDPOINT <- 'https://hts.usitc.gov/reststop/file'

file_url <- function(release_name, filename) {
  paste0(FILE_ENDPOINT, '?release=', URLencode(release_name, reserved = TRUE),
         '&filename=', URLencode(filename, reserved = TRUE))
}

#' A served PDF must actually start with %PDF- (the endpoint 200s on junk too)
is_pdf <- function(path) {
  if (!file.exists(path) || file.size(path) < 1024) return(FALSE)
  con <- file(path, 'rb'); on.exit(close(con), add = TRUE)
  identical(rawToChar(readBin(con, 'raw', 5)), '%PDF-')
}

banner('Chapter 99 / Change Record acquisition  years: ',
       paste(range(years), collapse = '-'), '\nstore: ', store)

releases <- fetch_release_list() %>% filter(year %in% years)
man <- read_manifest(store)

have_json <- man %>%
  filter(kind == 'hts_json', !is.na(release_name),
         !grepl('^reject', coalesce(validation, ''))) %>%
  pull(release_name)

releases <- releases %>%
  mutate(json_in_store = release_name %in% have_json,
         want_ch99 = all_ch99 | !json_in_store)

message('Releases in scope: ', nrow(releases),
        '  (with JSON: ', sum(releases$json_in_store),
        ', Chapter 99 targets: ', sum(releases$want_ch99), ')')
print(releases %>% select(year, release_name, revision_id, release_start,
                          json_in_store, want_ch99), n = 200)

if (dry_run) {
  message('\n--dry-run: stopping before downloads')
  quit(save = 'no', status = 0)
}

fetch_one <- function(release_name, revision_id, remote_name, prefix, kind) {
  rel_path <- file.path('pdf', paste0(prefix, revision_id, '.pdf'))
  if (manifest_is_good(rel_path, store, man)) {
    message('  ', prefix, revision_id, ': already stored — skipping')
    return(NULL)
  }
  url <- file_url(release_name, remote_name)
  dest <- file.path(pdf_dir, basename(rel_path))
  res <- polite_download(url, dest, throttle = 1.5)
  if (!res$ok) {
    message('  ', prefix, revision_id, ': FAILED (', res$status, ')')
    return(NULL)
  }
  if (!is_pdf(dest)) {
    message('  ', prefix, revision_id, ': not a PDF — rejected (', res$bytes, ' bytes)')
    unlink(dest)
    return(NULL)
  }
  message('  ', prefix, revision_id, ': ', round(res$bytes / 1e6, 2), ' MB')
  tibble(
    path = rel_path, url = url, key = revision_id, kind = kind,
    bytes = res$bytes, md5 = md5_of(dest), retrieved = as.character(Sys.Date()),
    origin_url = url, wayback_timestamp = NA_character_,
    release_name = release_name, revision_id = revision_id,
    validation = 'ok', n_records = NA_real_,
    notes = paste0('reststop_filename=', remote_name)
  )
}

for (i in seq_len(nrow(releases))) {
  r <- releases[i, ]
  if (is.na(r$revision_id)) {
    message('!! no revision id for release ', r$release_name, ' — skipping')
    next
  }
  message('\n[', i, '/', nrow(releases), '] ', r$release_name, ' (', r$revision_id, ')')
  rows <- list()
  if (r$want_ch99) {
    rows[[length(rows) + 1]] <- fetch_one(r$release_name, r$revision_id,
                                          'Chapter 99', 'ch99_', 'chapter99_pdf')
  }
  if (do_cr) {
    rows[[length(rows) + 1]] <- fetch_one(r$release_name, r$revision_id,
                                          'Change Record', 'change_record_',
                                          'change_record_pdf')
  }
  rows <- compact(rows)
  if (length(rows)) {
    upsert_manifest(bind_rows(rows), store)
    man <- read_manifest(store)
  }
}

banner('Chapter 99 / Change Record acquisition complete')
man <- read_manifest(store)
message('chapter99_pdf rows:     ', sum(man$kind == 'chapter99_pdf', na.rm = TRUE))
message('change_record_pdf rows: ', sum(man$kind == 'change_record_pdf', na.rm = TRUE))
