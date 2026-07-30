#!/usr/bin/env Rscript
# =============================================================================
# Shared helpers for the pre-2025 raw-archive acquisition (Phase 1)
# =============================================================================
#
# Sourced by the tools/pre2025_fetch_*.R scripts and by
# tools/pre2025_build_inventory.R. Nothing here is used by the build pipeline —
# this is acquisition/provenance tooling only.
#
# The shared store (source of truth, NOT the repo) mirrors the Census-IMDB
# pattern:
#
#   $HTS_ARCHIVE_STORE_DIR (default
#   /nfs/roberts/project/pi_nrs36/shared/raw_data/USITC-HTS-Archive)
#     json/         hts_<revision_id>.json.gz     HTS JSON editions
#     zips/         tariff_data_<year>.zip        USITC Annual Tariff Database
#     pdf/          ch99_<revision_id>.pdf        Chapter 99 (gap-filler)
#                   change_record_<revision_id>.pdf
#     manifest.csv  one row per stored artifact
#
# Routing note (see docs/pre2025_data_provenance.md): www.usitc.gov Akamai-403s
# this cluster, so every www.usitc.gov artifact is fetched through the Wayback
# Machine. hts.usitc.gov (the reststop API) IS reachable and is used directly
# for the release list and the Chapter 99 / Change Record PDFs.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(jsonlite)
  library(httr)
})


# --- Constants ---------------------------------------------------------------

DEFAULT_STORE_DIR <- '/nfs/roberts/project/pi_nrs36/shared/raw_data/USITC-HTS-Archive'

# The reststop host and Wayback both reject the default R/libcurl user agent.
ARCHIVE_USER_AGENT <- paste0(
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ',
  '(KHTML, like Gecko) Chrome/124.0 Safari/537.36'
)

RELEASE_LIST_URL <- 'https://hts.usitc.gov/reststop/releaseList'
CDX_URL          <- 'http://web.archive.org/cdx/search/cdx'
HTS_JSON_PREFIX  <- 'usitc.gov/sites/default/files/tata/hts/'
ANNUAL_DB_PREFIX <- 'usitc.gov/tariff_affairs/documents/tariff_data/'

# Manifest schema. Kept wide enough to describe json / zip / pdf artifacts in
# one table (the extra columns are NA for kinds that don't use them).
MANIFEST_COLS <- c(
  'path', 'url', 'key', 'kind', 'bytes', 'md5', 'retrieved',
  'origin_url', 'wayback_timestamp', 'release_name', 'revision_id',
  'validation', 'n_records', 'notes'
)


#' Resolve the shared store directory
hts_store_dir <- function() {
  Sys.getenv('HTS_ARCHIVE_STORE_DIR', DEFAULT_STORE_DIR)
}


# --- Manifest ----------------------------------------------------------------

manifest_path <- function(store = hts_store_dir()) file.path(store, 'manifest.csv')

#' Read the store manifest (empty tibble with the right schema if absent)
read_manifest <- function(store = hts_store_dir()) {
  p <- manifest_path(store)
  if (!file.exists(p)) {
    empty <- as_tibble(setNames(
      rep(list(character()), length(MANIFEST_COLS)), MANIFEST_COLS
    ))
    return(empty %>% mutate(bytes = numeric(), n_records = numeric()))
  }
  read_csv(p, col_types = cols(.default = col_character())) %>%
    mutate(bytes = suppressWarnings(as.numeric(bytes)),
           n_records = suppressWarnings(as.numeric(n_records)))
}

#' Insert-or-replace manifest rows keyed on `path`, then write atomically
#'
#' @param rows Tibble of new rows (any subset of MANIFEST_COLS)
upsert_manifest <- function(rows, store = hts_store_dir()) {
  if (nrow(rows) == 0) return(invisible(NULL))
  cur <- read_manifest(store)
  for (col in setdiff(MANIFEST_COLS, names(rows))) rows[[col]] <- NA
  rows <- rows[, MANIFEST_COLS]
  if (nrow(cur) > 0) {
    for (col in setdiff(MANIFEST_COLS, names(cur))) cur[[col]] <- NA
    cur <- cur[, MANIFEST_COLS] %>% filter(!(path %in% rows$path))
  }
  out <- bind_rows(cur, rows) %>% arrange(kind, key, path)
  tmp <- paste0(manifest_path(store), '.tmp')
  write_csv(out, tmp, na = '')
  file.rename(tmp, manifest_path(store))
  invisible(out)
}

#' Has this artifact already been stored and verified?
#'
#' Idempotency gate: the file must exist, its md5 must still match the manifest,
#' and (for validated kinds) validation must have passed.
manifest_is_good <- function(rel_path, store = hts_store_dir(), man = NULL) {
  if (is.null(man)) man <- read_manifest(store)
  row <- man %>% filter(path == rel_path)
  if (nrow(row) != 1) return(FALSE)
  abs_path <- file.path(store, rel_path)
  if (!file.exists(abs_path)) return(FALSE)
  if (!identical(unname(tools::md5sum(abs_path)), row$md5[1])) return(FALSE)
  v <- row$validation[1]
  if (!is.na(v) && grepl('^reject', v)) return(FALSE)
  TRUE
}


# --- Polite HTTP -------------------------------------------------------------

#' GET a URL to disk with throttling and exponential backoff
#'
#' A single failure is treated as retryable, never as absence — the Census
#' sweep learned this the hard way (spurious non-200s under throttling).
#'
#' @return list(ok, status, bytes, url)
polite_download <- function(url, dest, throttle = 1.5, max_tries = 4,
                            timeout_s = 900, quiet = FALSE) {
  backoff <- c(5, 20, 60)
  for (attempt in seq_len(max_tries)) {
    Sys.sleep(throttle)
    resp <- tryCatch(
      httr::GET(url,
                httr::user_agent(ARCHIVE_USER_AGENT),
                httr::timeout(timeout_s),
                httr::write_disk(dest, overwrite = TRUE)),
      error = function(e) e
    )
    if (!inherits(resp, 'error')) {
      status <- httr::status_code(resp)
      if (status %in% c(200L, 206L)) {
        return(list(ok = TRUE, status = status,
                    bytes = file.size(dest), url = url))
      }
      msg <- paste0('HTTP ', status)
    } else {
      msg <- paste0('error: ', conditionMessage(resp))
      status <- NA_integer_
    }
    if (!quiet) message('    attempt ', attempt, '/', max_tries, ' failed (', msg, ')')
    if (attempt < max_tries) Sys.sleep(backoff[min(attempt, length(backoff))])
  }
  if (file.exists(dest)) unlink(dest)
  list(ok = FALSE, status = status, bytes = NA_real_, url = url)
}

#' GET a URL and return its body as text (same retry policy)
polite_get_text <- function(url, throttle = 1.5, max_tries = 4, timeout_s = 300) {
  tmp <- tempfile()
  on.exit(unlink(tmp), add = TRUE)
  res <- polite_download(url, tmp, throttle = throttle, max_tries = max_tries,
                         timeout_s = timeout_s)
  if (!res$ok) return(NA_character_)
  paste(readLines(tmp, warn = FALSE), collapse = '\n')
}


# --- Wayback CDX -------------------------------------------------------------

#' Query the Wayback CDX index for captures under a URL prefix
#'
#' No `collapse=` is used: collapsing hides good captures (documented in the
#' scoping memo). `length` is the WARC record length (compressed), so it ranks
#' captures reliably even though it is not the uncompressed byte count.
#'
#' @param url_pattern e.g. 'usitc.gov/sites/default/files/tata/hts/hts_2018*'
#' @return Tibble(original, timestamp, statuscode, length)
cdx_query <- function(url_pattern, throttle = 2) {
  url <- paste0(CDX_URL, '?url=', URLencode(url_pattern, reserved = TRUE),
                '&output=text&fl=original,timestamp,statuscode,length',
                '&filter=statuscode:200')
  txt <- polite_get_text(url, throttle = throttle)
  if (is.na(txt) || !nzchar(trimws(txt))) return(tibble())
  rows <- strsplit(strsplit(txt, '\n')[[1]], ' +')
  rows <- Filter(function(r) length(r) >= 4, rows)
  if (length(rows) == 0) return(tibble())
  tibble(
    original   = vapply(rows, `[`, character(1), 1),
    timestamp  = vapply(rows, `[`, character(1), 2),
    statuscode = vapply(rows, `[`, character(1), 3),
    length     = suppressWarnings(as.numeric(vapply(rows, `[`, character(1), 4)))
  ) %>%
    mutate(filename = sub('.*/', '', original)) %>%
    distinct(filename, timestamp, .keep_all = TRUE)
}

#' Build a raw ("id_") Wayback replay URL — original bytes, no rewriting
wayback_url <- function(original, timestamp) {
  if (!grepl('^https?://', original)) original <- paste0('https://', original)
  paste0('https://web.archive.org/web/', timestamp, 'id_/', original)
}


# --- Release-name / filename normalisation -----------------------------------
#
# USITC release names are wildly inconsistent across years:
#   2018BasicEdition  2018HTSARevision1_1  2019HTSABASICA  2019HTSAREV8b
#   2020HTSABasicB    2021HTSAPrelimRev2   2022HTSABasicRev1B  2023HTSARev4a
#   2024HTSBasic      (and pre-2018: chapter98, Chapter99, basicCorrections2, NTE)
#
# Both release names and archived JSON filenames are normalised to the same
# (year, kind, number, subnumber) key so the two can be joined.

#' Normalise a USITC release name
#'
#' @param name Release name from reststop/releaseList
#' @param year_hint Year to use when the name carries none (pre-2018 releases)
#' @return list(year, kind, number, subnumber, variant, revision_id)
parse_release_name <- function(name, year_hint = NA_integer_) {
  raw <- name
  lower <- tolower(name)
  year <- year_hint
  if (grepl('^[0-9]{4}', lower)) {
    year <- as.integer(substr(lower, 1, 4))
    lower <- substring(lower, 5)
  }
  lower <- sub('^htsa', '', lower)
  lower <- sub('^hts', '', lower)

  kind <- NA_character_; num <- NA_integer_; sub_num <- NA_integer_
  variant <- NA_character_; slug <- NA_character_

  take_rev <- function(s) {
    m <- regmatches(s, regexec('^rev(?:ision)?([0-9]+)(?:_([0-9]+))?([a-z]*)$', s))[[1]]
    if (length(m) == 0) return(NULL)
    list(num = as.integer(m[2]),
         sub = if (nzchar(m[3])) as.integer(m[3]) else NA_integer_,
         variant = if (nzchar(m[4])) m[4] else NA_character_)
  }

  if (grepl('^prelim', lower)) {
    rest <- sub('^prelim(inary)?', '', lower)
    kind <- 'prelim'
    r <- take_rev(rest)
    if (!is.null(r)) {
      kind <- 'prelim_rev'; num <- r$num; sub_num <- r$sub; variant <- r$variant
    } else if (nzchar(rest)) {
      variant <- rest
    }
  } else if (grepl('^basic', lower)) {
    rest <- sub('^basic(edition)?', '', lower)
    r <- take_rev(rest)
    if (!is.null(r)) {
      kind <- 'rev'; num <- r$num; sub_num <- r$sub; variant <- r$variant
    } else if (grepl('^[a-z]*$', rest)) {
      kind <- 'basic'
      if (nzchar(rest)) variant <- rest
    }
  } else {
    r <- take_rev(lower)
    if (!is.null(r)) {
      kind <- 'rev'; num <- r$num; sub_num <- r$sub; variant <- r$variant
    }
  }

  if (is.na(kind)) {
    kind <- 'other'
    slug <- gsub('[^a-z0-9]+', '_', tolower(raw))
    slug <- gsub('^_|_$', '', slug)
  }

  list(year = year, kind = kind, number = num, subnumber = sub_num,
       variant = variant, slug = slug,
       revision_id = make_revision_id(year, kind, num, sub_num, slug))
}


#' Build a tracker revision identifier
#'
#' Follows the existing convention (src/model/revisions.R::parse_revision_id):
#' 2025 is the unprefixed namespace; every other year is `<year>_<rev>`.
#' Sub-revisions (2018's `Revision1_1`) become `<year>_rev_<n>_<sub>`; the 2021
#' preliminary editions become `<year>_prelim[_rev_<n>]`.
make_revision_id <- function(year, kind, number, subnumber, slug = NA_character_) {
  if (is.na(year)) return(NA_character_)
  body <- switch(
    kind,
    basic      = 'basic',
    prelim     = 'prelim',
    prelim_rev = paste0('prelim_rev_', number),
    rev        = paste0('rev_', number, if (!is.na(subnumber)) paste0('_', subnumber) else ''),
    other      = slug,
    NA_character_
  )
  if (is.na(body)) return(NA_character_)
  if (identical(as.integer(year), 2025L)) return(body)
  paste0(year, '_', body)
}


#' Normalise an archived HTS JSON filename to the same key as a release name
#'
#' Handles the observed noise: `_json`, `_data`, `_0` suffixes in any order,
#' the 2020 `revsision` typo, `revision_basic_<n>` (2021), `basic_and_revision_1`
#' (2022) and `basic_edition` (2023/24).
#'
#' @return list(year, kind, number, subnumber, slug) or NULL if not an HTS edition
parse_json_filename <- function(filename) {
  core <- sub('\\.json$', '', filename)
  if (!grepl('^hts_[0-9]{4}_', core)) return(NULL)
  year <- as.integer(substr(core, 5, 8))
  core <- substring(core, 10)

  repeat {
    new <- sub('_(json|data|0)$', '', core)
    if (identical(new, core)) break
    core <- new
  }
  core <- sub('revsision', 'revision', core)          # 2020 rev 3 filename typo
  core <- sub('^revision_basicb$', 'basic', core)     # 2020 basic-B
  core <- sub('^revision_basic$', 'basic', core)      # 2021 basic
  core <- sub('^basic_edition$', 'basic', core)       # 2023/2024 basic

  kind <- NA_character_; num <- NA_integer_; sub_num <- NA_integer_; slug <- NA_character_

  if (identical(core, 'basic')) {
    kind <- 'basic'
  } else if (identical(core, 'preliminary')) {
    kind <- 'prelim'
  } else if (grepl('^preliminary_revision_[0-9]+$', core)) {
    kind <- 'prelim_rev'; num <- as.integer(sub('.*_', '', core))
  } else if (grepl('^revision_basic_[0-9]+$', core) ||
             grepl('^basic_and_revision_[0-9]+$', core)) {
    kind <- 'rev'; num <- as.integer(sub('.*_', '', core))
  } else if (grepl('^(revision|rev)_[0-9]+(_[0-9]+)?$', core)) {
    parts <- strsplit(sub('^(revision|rev)_', '', core), '_')[[1]]
    kind <- 'rev'; num <- as.integer(parts[1])
    if (length(parts) > 1) sub_num <- as.integer(parts[2])
  } else {
    kind <- 'other'; slug <- core
  }

  list(year = year, kind = kind, number = num, subnumber = sub_num, slug = slug,
       revision_id = make_revision_id(year, kind, num, sub_num, slug))
}


# --- Release list ------------------------------------------------------------

#' Fetch and normalise the USITC release list
#'
#' @return Tibble(release_name, api_date, status, release_start, release_end,
#'                year, kind, number, subnumber, revision_id)
fetch_release_list <- function(url = RELEASE_LIST_URL) {
  txt <- polite_get_text(url, throttle = 0.5)
  if (is.na(txt)) stop('Could not fetch releaseList from ', url)
  raw <- jsonlite::fromJSON(txt, simplifyDataFrame = TRUE)

  as_date_us <- function(x) suppressWarnings(as.Date(x, format = '%m/%d/%Y'))

  out <- tibble(
    release_name  = raw$name,
    api_date      = as_date_us(raw$date),
    status        = raw$status,
    release_start = as_date_us(raw$releaseStartDate),
    release_end   = as_date_us(raw$releaseEndDate)
  )

  parsed <- map2(out$release_name, lubridate::year(out$api_date),
                 ~ parse_release_name(.x, .y))
  out %>%
    mutate(
      year        = map_int(parsed, ~ as.integer(.x$year)),
      kind        = map_chr(parsed, ~ .x$kind),
      number      = map_int(parsed, ~ as.integer(.x$number)),
      subnumber   = map_int(parsed, ~ as.integer(.x$subnumber)),
      revision_id = map_chr(parsed, ~ .x$revision_id)
    ) %>%
    arrange(release_start)
}


# --- HTS JSON validation -----------------------------------------------------
#
# Three families of trap this defends against (docs/pre2025_data_provenance.md):
#   1. Wayback truncation at exactly 1 MiB — caught by parse failure / record
#      count, since a truncated JSON array cannot parse.
#   2. Silently getting CURRENT data (the reststop exportList `release=`
#      parameter does not exist; a bad Wayback redirect can do the same) —
#      caught by the 2025-era IEEPA heading assertion.
#   3. Getting the WRONG historical era — caught by the §301 presence/absence
#      assertion keyed on the release's own in-force start date.

IEEPA_2025_CODES <- c('9903.01.25', '9903.01.63')
S301_LIST1_START <- as.Date('2018-07-06')   # first 9903.88.* headings
S232_STEEL_START <- as.Date('2018-03-23')   # first 9903.80.* headings
LIST3_RATE_STEP  <- as.Date('2019-05-10')   # 9903.88.03: +10% -> +25%

REQUIRED_JSON_COLS <- c('htsno', 'indent', 'description', 'general', 'special', 'other')
MIN_PLAUSIBLE_RECORDS <- 20000

#' Validate a downloaded HTS JSON edition
#'
#' @param path Path to the .json (or .json.gz) file
#' @param release_start In-force start date of the edition (NA if unknown)
#' @param expected_year Year the edition belongs to
#' @return list(status, n_records, metrics..., warnings)
validate_hts_json <- function(path, release_start = as.Date(NA), expected_year = NA_integer_) {
  fail <- function(reason, ...) {
    c(list(status = paste0('reject:', reason), n_records = NA_real_,
           n_9903 = NA_real_, n_9903_88 = NA_real_, n_9903_80 = NA_real_,
           n_9903_01 = NA_real_, list3_rate = NA_real_, has_s_plus = NA,
           warnings = character()), list(...))
  }

  x <- tryCatch(jsonlite::fromJSON(path, simplifyDataFrame = TRUE),
                error = function(e) e)
  if (inherits(x, 'error')) return(fail('unparseable'))
  if (!is.data.frame(x)) return(fail('not_a_record_array'))
  missing_cols <- setdiff(REQUIRED_JSON_COLS, names(x))
  if (length(missing_cols) > 0) {
    return(fail(paste0('missing_cols_', paste(missing_cols, collapse = '+'))))
  }
  n <- nrow(x)
  if (n < MIN_PLAUSIBLE_RECORDS) return(fail(paste0('too_few_records_', n)))

  h <- as.character(x$htsno)
  h[is.na(h)] <- ''
  n_9903    <- sum(startsWith(h, '9903'))
  n_9903_88 <- sum(startsWith(h, '9903.88'))
  n_9903_80 <- sum(startsWith(h, '9903.80'))
  n_9903_01 <- sum(startsWith(h, '9903.01'))

  warnings <- character()

  # (2) Current-era assertion — hard reject.
  if (any(h %in% IEEPA_2025_CODES)) {
    return(fail('current_era_ieepa_headings', n_records = n))
  }
  if (n_9903_01 > 0) {
    warnings <- c(warnings, paste0('n_9903_01=', n_9903_01))
  }

  # (3) Era assertions keyed on the edition's own in-force window.
  if (n_9903 == 0) {
    warnings <- c(warnings, 'no_chapter_99_rows')
  } else if (!is.na(release_start)) {
    if (release_start >= S301_LIST1_START && n_9903_88 == 0) {
      return(fail('missing_s301_headings', n_records = n))
    }
    if (release_start < S301_LIST1_START && n_9903_88 > 0) {
      return(fail('unexpected_s301_headings', n_records = n))
    }
    if (release_start >= S232_STEEL_START && n_9903_80 == 0) {
      warnings <- c(warnings, 'no_9903_80_steel_headings')
    }
  }

  # List 3 rate: +10% until 2019-05-09, +25% from 2019-05-10. Recorded, and
  # a mismatch is a warning (the heading text is free-form and drifts).
  list3_rate <- NA_real_
  i3 <- which(h == '9903.88.03')
  if (length(i3) > 0) {
    m <- regmatches(x$general[i3[1]], regexec('\\+ *([0-9.]+) *%', x$general[i3[1]]))[[1]]
    if (length(m) == 2) list3_rate <- as.numeric(m[2])
    if (!is.na(list3_rate) && !is.na(release_start)) {
      expected <- if (release_start >= LIST3_RATE_STEP) 25 else 10
      if (abs(list3_rate - expected) > 1e-9) {
        warnings <- c(warnings, paste0('list3_rate=', list3_rate, '_expected_', expected))
      }
    }
  }

  has_s_plus <- any(grepl('S\\+', as.character(x$special)), na.rm = TRUE)

  list(status = if (length(warnings) == 0) 'ok' else 'ok_with_warnings',
       n_records = n, n_9903 = n_9903, n_9903_88 = n_9903_88,
       n_9903_80 = n_9903_80, n_9903_01 = n_9903_01,
       list3_rate = list3_rate, has_s_plus = has_s_plus,
       warnings = warnings)
}


# --- Misc --------------------------------------------------------------------

#' gzip a file and verify the compressed copy decompresses cleanly
#'
#' Reads the whole stream back so a truncated/corrupt member trips the gzip
#' CRC rather than being discovered months later at build time.
#'
#' @return Path to the .gz file, or NA on failure
gzip_and_verify <- function(path, remove_original = TRUE) {
  gz <- paste0(path, '.gz')
  ok <- tryCatch({
    R.utils::gzip(path, destname = gz, overwrite = TRUE, remove = remove_original)
    con <- gzfile(gz, 'rb')
    on.exit(close(con), add = TRUE)
    total <- 0
    repeat {
      chunk <- readBin(con, 'raw', n = 4L * 1024L * 1024L)
      if (length(chunk) == 0) break
      total <- total + length(chunk)
    }
    total > 0
  }, error = function(e) FALSE)
  if (!ok) {
    if (file.exists(gz)) unlink(gz)
    return(NA_character_)
  }
  gz
}

md5_of <- function(path) unname(tools::md5sum(path))

#' Standard message banner used by the fetch scripts
banner <- function(...) {
  message('\n', strrep('=', 74))
  message(...)
  message(strrep('=', 74))
}
