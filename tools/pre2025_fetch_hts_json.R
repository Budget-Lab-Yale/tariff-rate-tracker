#!/usr/bin/env Rscript
# =============================================================================
# Phase 1 acquisition: HTS JSON editions 2016-2024, via the Wayback Machine
# =============================================================================
#
# www.usitc.gov (which hosts the static hts_<year>_<edition>_*.json archives)
# Akamai-403s this cluster, and hts.usitc.gov/reststop/exportList only ever
# serves the CURRENT release. The only route to historical machine-readable
# editions is therefore the Wayback Machine.
#
# For each year the script:
#   1. enumerates every archived capture under
#      usitc.gov/sites/default/files/tata/hts/hts_<year>* from the CDX index;
#   2. groups captures by filename and normalises each filename to a
#      (year, kind, number, subnumber) key;
#   3. joins that key to the reststop/releaseList editions to get the release
#      name, in-force window and tracker revision id;
#   4. downloads candidate captures largest-first (Wayback truncates big
#      captures at exactly 1 MiB, so the small ones are junk), validating each
#      until one passes;
#   5. gzips the winner into the shared store and records it in manifest.csv.
#
# Already-verified artifacts are skipped (manifest md5 + validation gate), so
# the script is safely re-runnable.
#
# Usage:
#   Rscript tools/pre2025_fetch_hts_json.R                     # 2016-2024
#   Rscript tools/pre2025_fetch_hts_json.R --years 2018,2019
#   Rscript tools/pre2025_fetch_hts_json.R --dry-run           # enumerate only
#   Rscript tools/pre2025_fetch_hts_json.R --max-candidates 6
#
# Env: HTS_ARCHIVE_STORE_DIR overrides the shared store location.
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
years <- as.integer(strsplit(arg_val('--years', '2016,2017,2018,2019,2020,2021,2022,2023,2024'),
                             ',')[[1]])
dry_run        <- '--dry-run' %in% args
max_candidates <- as.integer(arg_val('--max-candidates', '6'))
store          <- arg_val('--store', hts_store_dir())

json_dir <- file.path(store, 'json')
dir.create(json_dir, recursive = TRUE, showWarnings = FALSE)

banner('HTS JSON acquisition (Wayback)  years: ', paste(years, collapse = ', '),
       '\nstore: ', store)

releases <- fetch_release_list()
message('Release list: ', nrow(releases), ' editions, ',
        min(releases$release_start, na.rm = TRUE), ' .. ',
        max(releases$release_start, na.rm = TRUE))

# --- Enumerate captures ------------------------------------------------------

all_caps <- map_dfr(years, function(y) {
  message('CDX: ', y)
  caps <- cdx_query(paste0(HTS_JSON_PREFIX, 'hts_', y, '*'))
  if (nrow(caps) == 0) {
    message('  no captures'); return(tibble())
  }
  caps %>% filter(grepl('\\.json$', filename)) %>% mutate(cdx_year = y)
})

if (nrow(all_caps) == 0) stop('CDX returned no JSON captures for any requested year')

# A year that comes back empty is far more likely to be a Wayback 503 that
# exhausted its retries than a genuine absence — never let it pass silently.
empty_years <- setdiff(years, unique(all_caps$cdx_year))
if (length(empty_years) > 0 && !('--allow-empty-years' %in% args)) {
  stop('CDX returned no JSON captures for year(s): ', paste(empty_years, collapse = ', '),
       '\nThis is usually a transient Wayback failure. Re-run, or pass ',
       '--allow-empty-years if the absence is genuine (e.g. 2015).')
}

files <- all_caps %>%
  count(filename, name = 'n_captures') %>%
  mutate(parsed = map(filename, parse_json_filename)) %>%
  filter(map_lgl(parsed, ~ !is.null(.x))) %>%
  mutate(
    year        = map_int(parsed, ~ as.integer(.x$year)),
    kind        = map_chr(parsed, ~ .x$kind),
    number      = map_int(parsed, ~ as.integer(.x$number)),
    subnumber   = map_int(parsed, ~ as.integer(.x$subnumber)),
    revision_id = map_chr(parsed, ~ .x$revision_id)
  ) %>%
  select(-parsed) %>%
  filter(year %in% years)

# --- Join filenames to releases ---------------------------------------------
#
# Exact (year, kind, number, subnumber) first; then (year, kind, number) when
# that is unique on the release side — this is what maps the 2018
# `hts_2018_revision_11_data.json` capture onto release `2018HTSARevision11_1`
# (USITC re-issued rev 11 but kept the file name). The looser matches are
# flagged so the inventory stays honest.

rel <- releases %>% filter(year %in% years)

rel_keyed <- rel %>%
  mutate(k_exact  = paste(year, kind, number, subnumber, sep = '|'),
         k_number = paste(year, kind, number, sep = '|'),
         k_kind   = paste(year, kind, sep = '|'))

uniq_number <- rel_keyed %>% count(k_number) %>% filter(n == 1) %>% pull(k_number)
uniq_kind   <- rel_keyed %>% count(k_kind)   %>% filter(n == 1) %>% pull(k_kind)

files <- files %>%
  mutate(k_exact  = paste(year, kind, number, subnumber, sep = '|'),
         k_number = paste(year, kind, number, sep = '|'),
         k_kind   = paste(year, kind, sep = '|'))

match_release <- function(ke, kn, kk) {
  hit <- rel_keyed %>% filter(k_exact == ke)
  if (nrow(hit) == 1) return(list(name = hit$release_name, how = 'exact'))
  if (kn %in% uniq_number) {
    hit <- rel_keyed %>% filter(k_number == kn)
    return(list(name = hit$release_name[1], how = 'number_only'))
  }
  if (kk %in% uniq_kind) {
    hit <- rel_keyed %>% filter(k_kind == kk)
    return(list(name = hit$release_name[1], how = 'kind_only'))
  }
  list(name = NA_character_, how = 'unmatched')
}

matches <- pmap(list(files$k_exact, files$k_number, files$k_kind), match_release)
files <- files %>%
  mutate(release_name = map_chr(matches, ~ .x$name),
         match_type   = map_chr(matches, ~ .x$how)) %>%
  left_join(rel %>% select(release_name, release_start, release_end, api_date,
                           rel_revision_id = revision_id),
            by = 'release_name') %>%
  # Prefer the release's revision id (authoritative); fall back to the
  # filename-derived one for JSONs with no matching release (2016/2017).
  mutate(revision_id = coalesce(rel_revision_id, revision_id)) %>%
  arrange(year, number, subnumber, filename)

message('\nDistinct JSON editions found: ', nrow(files))
print(files %>% select(year, filename, revision_id, release_name, match_type,
                       n_captures, release_start), n = 200)

if (dry_run) {
  message('\n--dry-run: stopping before downloads')
  quit(save = 'no', status = 0)
}

# --- Download + validate -----------------------------------------------------

man <- read_manifest(store)
results <- list()

for (i in seq_len(nrow(files))) {
  f <- files[i, ]
  rev_id <- f$revision_id
  if (is.na(rev_id)) {
    message('!! no revision id for ', f$filename, ' — skipping')
    next
  }
  rel_path <- file.path('json', paste0('hts_', rev_id, '.json.gz'))
  message('\n[', i, '/', nrow(files), '] ', f$filename, '  ->  ', rel_path)

  if (manifest_is_good(rel_path, store, man)) {
    message('  already stored and verified — skipping')
    next
  }

  cands <- all_caps %>%
    filter(filename == f$filename) %>%
    arrange(desc(length)) %>%
    head(max_candidates)
  message('  ', nrow(cands), ' candidate capture(s); lengths: ',
          paste(cands$length, collapse = ', '))

  stored <- NULL
  for (j in seq_len(nrow(cands))) {
    cap <- cands[j, ]
    url <- wayback_url(cap$original, cap$timestamp)
    tmp <- file.path(json_dir, paste0('.tmp_', rev_id, '.json'))
    message('  try ', j, ': ', cap$timestamp, ' (cdx len ', cap$length, ')')
    res <- polite_download(url, tmp)
    if (!res$ok) { message('    download failed'); next }
    v <- validate_hts_json(tmp, release_start = f$release_start,
                           expected_year = f$year)
    message('    ', res$bytes, ' bytes; ', v$status,
            if (!is.na(v$n_records)) paste0('; ', v$n_records, ' records') else '',
            if (length(v$warnings)) paste0('; warn: ', paste(v$warnings, collapse = ',')) else '')
    if (grepl('^reject', v$status)) {
      unlink(tmp)
      results[[length(results) + 1]] <- tibble(
        revision_id = rev_id, filename = f$filename, timestamp = cap$timestamp,
        outcome = v$status, bytes = res$bytes)
      next
    }
    gz <- gzip_and_verify(tmp)
    if (is.na(gz)) { message('    gzip verify FAILED'); unlink(tmp); next }
    final <- file.path(json_dir, basename(rel_path))
    if (!identical(normalizePath(gz), normalizePath(final, mustWork = FALSE))) {
      file.rename(gz, final)
    }
    stored <- tibble(
      path = rel_path,
      url = url,
      key = rev_id,
      kind = 'hts_json',
      bytes = file.size(final),
      md5 = md5_of(final),
      retrieved = as.character(Sys.Date()),
      origin_url = cap$original,
      wayback_timestamp = cap$timestamp,
      release_name = f$release_name %||% NA_character_,
      revision_id = rev_id,
      validation = v$status,
      n_records = v$n_records,
      notes = paste0('src_file=', f$filename,
                     '; match=', f$match_type,
                     '; n_9903=', v$n_9903,
                     '; n_9903_88=', v$n_9903_88,
                     '; n_9903_80=', v$n_9903_80,
                     '; n_9903_01=', v$n_9903_01,
                     '; list3_rate=', v$list3_rate,
                     '; s_plus=', v$has_s_plus,
                     if (length(v$warnings)) paste0('; warn=', paste(v$warnings, collapse = '/')) else '')
    )
    upsert_manifest(stored, store)
    man <- read_manifest(store)
    results[[length(results) + 1]] <- tibble(
      revision_id = rev_id, filename = f$filename, timestamp = cap$timestamp,
      outcome = v$status, bytes = stored$bytes)
    message('    STORED (', round(stored$bytes / 1e6, 2), ' MB gz)')
    break
  }
  if (is.null(stored)) message('  !! no usable capture for ', f$filename)
}

banner('HTS JSON acquisition complete')
res_tbl <- if (length(results)) bind_rows(results) else tibble()
if (nrow(res_tbl)) print(res_tbl, n = 300)
man <- read_manifest(store)
message('Manifest rows (hts_json): ', sum(man$kind == 'hts_json', na.rm = TRUE))
