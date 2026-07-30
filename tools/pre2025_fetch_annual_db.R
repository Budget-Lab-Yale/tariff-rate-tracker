#!/usr/bin/env Rscript
# =============================================================================
# Phase 1 acquisition: USITC Annual Tariff Database zips, via the Wayback Machine
# =============================================================================
#
# `https://www.usitc.gov/tariff_affairs/documents/tariff_data/tariff_data_<year>.zip`
# is the recommended pre-2025 rate spine: effective-date-versioned rows (true
# statutory dates, not HTS publication dates), full column 2, and per-program
# preference indicator/rate columns. HTS-8 only.
#
# The year index lives at
# `https://dataweb.usitc.gov/assets/content/lists/tariff_annual.json` (reachable
# from the cluster); the zips themselves live on www.usitc.gov, which Akamai-403s
# us, so they come through Wayback like the JSON editions.
#
# Validation for zips is structural, not semantic: the file must be a readable
# zip whose central directory lists plausible members. (Content validation is
# Phase 2's per-year sniffing loader.)
#
# Usage:
#   Rscript tools/pre2025_fetch_annual_db.R                  # 2015-2026
#   Rscript tools/pre2025_fetch_annual_db.R --years 2015,2016
#   Rscript tools/pre2025_fetch_annual_db.R --dry-run
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
years   <- as.integer(strsplit(arg_val('--years', paste(2015:2026, collapse = ',')), ',')[[1]])
dry_run <- '--dry-run' %in% args
store   <- arg_val('--store', hts_store_dir())

ANNUAL_INDEX_URL <- 'https://dataweb.usitc.gov/assets/content/lists/tariff_annual.json'

zip_dir <- file.path(store, 'zips')
dir.create(zip_dir, recursive = TRUE, showWarnings = FALSE)

banner('USITC Annual Tariff Database acquisition  years: ',
       paste(range(years), collapse = '-'), '\nstore: ', store)

# --- Year index (provenance: which years USITC itself advertises) ------------

idx_txt <- polite_get_text(ANNUAL_INDEX_URL, throttle = 0.5)
advertised <- if (!is.na(idx_txt)) {
  idx <- jsonlite::fromJSON(idx_txt, simplifyDataFrame = TRUE)
  tibble(year = suppressWarnings(as.integer(idx$text)), url = idx$url) %>%
    filter(!is.na(year))
} else {
  message('!! could not read the dataweb year index; falling back to URL pattern')
  tibble(year = years,
         url = paste0('https://www.usitc.gov/tariff_affairs/documents/',
                      'tariff_data/tariff_data_', years, '.zip'))
}
message('Index advertises ', nrow(advertised), ' years: ',
        min(advertised$year), '..', max(advertised$year))

# --- Wayback captures --------------------------------------------------------

caps <- cdx_query(paste0(ANNUAL_DB_PREFIX, 'tariff_data_*')) %>%
  filter(grepl('^tariff_data_[0-9]{4}\\.zip$', filename)) %>%
  mutate(year = as.integer(substr(filename, 13, 16)))

message('Wayback has captures for ', n_distinct(caps$year), ' years: ',
        paste(sort(unique(caps$year)), collapse = ', '))

targets <- tibble(year = years) %>%
  left_join(advertised %>% rename(origin_url = url), by = 'year') %>%
  mutate(has_capture = year %in% caps$year)

print(targets)

missing <- targets %>% filter(!has_capture)
if (nrow(missing) > 0) {
  message('!! no Wayback capture for: ', paste(missing$year, collapse = ', '),
          ' (www.usitc.gov is 403 from here, so these cannot be fetched directly)')
}

if (dry_run) {
  message('\n--dry-run: stopping before downloads')
  quit(save = 'no', status = 0)
}

# --- Download ----------------------------------------------------------------

man <- read_manifest(store)

for (y in targets$year[targets$has_capture]) {
  rel_path <- file.path('zips', paste0('tariff_data_', y, '.zip'))
  message('\n', y, '  ->  ', rel_path)
  if (manifest_is_good(rel_path, store, man)) {
    message('  already stored and verified — skipping')
    next
  }
  cands <- caps %>% filter(year == y) %>% arrange(desc(length)) %>% head(4)
  stored <- NULL
  for (j in seq_len(nrow(cands))) {
    cap <- cands[j, ]
    url <- wayback_url(cap$original, cap$timestamp)
    dest <- file.path(zip_dir, basename(rel_path))
    message('  try ', j, ': ', cap$timestamp, ' (cdx len ', cap$length, ')')
    res <- polite_download(url, dest)
    if (!res$ok) { message('    download failed'); next }
    members <- tryCatch(utils::unzip(dest, list = TRUE), error = function(e) NULL)
    if (is.null(members) || nrow(members) == 0) {
      message('    not a readable zip — rejected'); unlink(dest); next
    }
    message('    ', res$bytes, ' bytes; ', nrow(members), ' member(s): ',
            paste(head(members$Name, 4), collapse = ', '))
    stored <- tibble(
      path = rel_path, url = url, key = as.character(y), kind = 'annual_db_zip',
      bytes = res$bytes, md5 = md5_of(dest), retrieved = as.character(Sys.Date()),
      origin_url = cap$original, wayback_timestamp = cap$timestamp,
      release_name = NA_character_, revision_id = NA_character_,
      validation = 'ok', n_records = nrow(members),
      notes = paste0('members=', paste(members$Name, collapse = '|'))
    )
    upsert_manifest(stored, store)
    man <- read_manifest(store)
    message('    STORED')
    break
  }
  if (is.null(stored)) message('  !! no usable capture for ', y)
}

banner('Annual DB acquisition complete')
man <- read_manifest(store)
print(man %>% filter(kind == 'annual_db_zip') %>%
        select(key, bytes, wayback_timestamp, md5), n = 50)
