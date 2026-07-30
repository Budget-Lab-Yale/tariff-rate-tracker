#!/usr/bin/env Rscript
# =============================================================================
# Phase 1: build resources/pre2025_hts_inventory.csv from the shared store
# =============================================================================
#
# One row per 2016-2024 USITC HTS release (from reststop/releaseList), joined to
# what the shared archive store actually holds. This is the artifact Phase 2
# uses to curate config/revision_dates.csv, and the honest record of where the
# gaps are — a release with json_obtained=FALSE has to be built from its
# Chapter 99 PDF plus the Annual Tariff Database instead.
#
# Rows whose release_name is empty are archived JSON editions that could NOT be
# matched to any release in the API list (the 2016/2017 editions: USITC's
# release list has no basic edition for those years).
#
# Usage:
#   Rscript tools/pre2025_build_inventory.R
#   Rscript tools/pre2025_build_inventory.R --out /path/to/inventory.csv
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
out_path <- arg_val('--out', here('resources', 'pre2025_hts_inventory.csv'))
store    <- arg_val('--store', hts_store_dir())
years    <- as.integer(strsplit(arg_val('--years', paste(2016:2024, collapse = ',')), ',')[[1]])

banner('Building pre-2025 HTS inventory\nstore: ', store, '\nout:   ', out_path)

releases <- fetch_release_list() %>% filter(year %in% years)
man <- read_manifest(store)

pull_note <- function(notes, field) {
  m <- regmatches(notes, regexec(paste0(field, '=([^;]*)'), notes))
  map_chr(m, ~ if (length(.x) == 2) trimws(.x[2]) else NA_character_)
}

json <- man %>%
  filter(kind == 'hts_json') %>%
  transmute(revision_id,
            release_name,
            json_obtained = TRUE,
            json_path = path,
            json_capture_timestamp = wayback_timestamp,
            json_bytes_gz = bytes,
            json_md5 = md5,
            json_records = n_records,
            json_validation = validation,
            json_source_file = pull_note(notes, 'src_file'),
            json_release_match = pull_note(notes, 'match'),
            json_n_9903_88 = pull_note(notes, 'n_9903_88'),
            json_list3_rate = pull_note(notes, 'list3_rate'),
            json_retrieved = retrieved)

ch99 <- man %>%
  filter(kind == 'chapter99_pdf') %>%
  transmute(revision_id, ch99_obtained = TRUE, ch99_bytes = bytes, ch99_md5 = md5)

crec <- man %>%
  filter(kind == 'change_record_pdf') %>%
  transmute(revision_id, change_record_obtained = TRUE, change_record_bytes = bytes)

inv <- releases %>%
  transmute(year, release_name, revision_id,
            api_published_date = api_date,
            release_start, release_end, api_status = status) %>%
  left_join(json %>% select(-release_name), by = 'revision_id') %>%
  left_join(ch99, by = 'revision_id') %>%
  left_join(crec, by = 'revision_id')

# Archived JSON editions with no matching release row (2016/2017).
orphan_json <- json %>%
  filter(!(revision_id %in% inv$revision_id)) %>%
  mutate(year = suppressWarnings(as.integer(substr(revision_id, 1, 4))),
         release_name = NA_character_,
         api_published_date = as.Date(NA), release_start = as.Date(NA),
         release_end = as.Date(NA), api_status = NA_character_)

inv <- bind_rows(inv, orphan_json %>% select(-release_name) %>%
                        mutate(release_name = NA_character_)) %>%
  mutate(
    json_obtained          = coalesce(json_obtained, FALSE),
    ch99_obtained          = coalesce(ch99_obtained, FALSE),
    change_record_obtained = coalesce(change_record_obtained, FALSE),
    source_for_phase2 = case_when(
      json_obtained ~ 'hts_json',
      ch99_obtained ~ 'chapter99_pdf+annual_db',
      TRUE          ~ 'NONE'
    )
  ) %>%
  arrange(year, release_start, revision_id) %>%
  select(year, release_name, revision_id, api_published_date, release_start,
         release_end, api_status, json_obtained, json_validation, json_records,
         json_capture_timestamp, json_bytes_gz, json_md5, json_source_file,
         json_release_match, json_n_9903_88, json_list3_rate, json_retrieved,
         json_path, ch99_obtained, ch99_bytes, ch99_md5,
         change_record_obtained, change_record_bytes, source_for_phase2)

dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
write_csv(inv, out_path, na = '')

banner('Inventory written: ', nrow(inv), ' rows -> ', out_path)

summary_tbl <- inv %>%
  group_by(year) %>%
  summarise(releases = sum(!is.na(release_name)),
            json_obtained = sum(json_obtained),
            json_missing = sum(!json_obtained & !is.na(release_name)),
            ch99_pdf = sum(ch99_obtained),
            change_records = sum(change_record_obtained),
            .groups = 'drop')
print(summary_tbl, n = 30)

gaps <- inv %>% filter(!json_obtained, !is.na(release_name))
if (nrow(gaps) > 0) {
  message('\nReleases with NO usable JSON (Phase 2 must use Chapter 99 PDF + annual DB):')
  print(gaps %>% select(year, release_name, revision_id, release_start,
                        release_end, ch99_obtained), n = 100)
}
