# =============================================================================
# Build import weights file (HS10 x country x GTAP)
# =============================================================================
#
# Reproduces the import_weights RDS used for weighted daily series / scenarios.
# Pulls monthly Census Bureau merchandise-trade IMDByymm.ZIP files (or reads a
# user-supplied local cache), parses IMP_DETL.TXT, aggregates HS10 x country
# consumption imports, joins the in-repo HS10 -> GTAP crosswalk, and writes RDS.
#
# Usage:
#   Rscript src/io/build_import_weights.R --year 2024 \
#       --out resources/hs10_by_country_gtap_2024_con.rds
#
#   # If you have the IMDByymm.ZIPs already on disk and want to skip downloads:
#   Rscript src/io/build_import_weights.R --year 2024 \
#       --raw-dir /path/to/zip/cache \
#       --out resources/hs10_by_country_gtap_2024_con.rds
#
#   # General imports instead of consumption (default is 'con'):
#   Rscript src/io/build_import_weights.R --year 2024 --type gen \
#       --out resources/hs10_by_country_gtap_2024_gen.rds
#
# Output schema consumed by 09_daily_series.R:
#   hs10 (chr, 10-digit zero-padded), gtap_code (chr, lowercase),
#   cty_code (chr, 4-digit Census code), imports (dbl, $ for the year)
#
# Documented in: docs/weights.md
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})

# =============================================================================
# Census source URL pattern (publicly downloadable, no auth)
# =============================================================================
# Pattern: https://www.census.gov/trade/downloads/{YEAR}/Merch/im_m/IMDB{YY}{MM}.ZIP
# Confirmed working for 2024 (see docs/weights.md). If Census moves these files,
# override with --url-template using {year}, {yy}, {mm} placeholders.
DEFAULT_URL_TEMPLATE <- 'https://www.census.gov/trade/downloads/{year}/Merch/im_m/IMDB{yy}{mm}.ZIP'


# =============================================================================
# CLI parsing
# =============================================================================

parse_args <- function(argv) {
  defaults <- list(
    year         = 2024L,
    raw_dir      = NULL,
    out          = NULL,
    type         = 'con',
    url_template = DEFAULT_URL_TEMPLATE,
    crosswalk    = here('resources', 'hs10_gtap_crosswalk.csv'),
    keep_zips    = FALSE,
    force        = FALSE,
    no_gtap      = FALSE,
    help         = FALSE
  )

  i <- 1
  while (i <= length(argv)) {
    a <- argv[i]
    # Consume the next argv slot and return it. Errors clearly if the user
    # forgot the value (e.g. `--year` at end of args) instead of silently
    # propagating NA into URL construction.
    take <- function() {
      if (i + 1L > length(argv)) {
        stop('Missing value for argument: ', a,
             ' (use --help for usage).', call. = FALSE)
      }
      i <<- i + 1L
      argv[i]
    }
    if (a %in% c('-h', '--help')) {
      defaults$help <- TRUE
    } else if (a == '--year') {
      raw_year <- take()
      defaults$year <- suppressWarnings(as.integer(raw_year))
      if (is.na(defaults$year)) {
        stop('--year must be an integer year (got: "', raw_year, '").',
             call. = FALSE)
      }
    } else if (a == '--raw-dir') {
      defaults$raw_dir <- take()
    } else if (a == '--out') {
      defaults$out <- take()
    } else if (a == '--type') {
      defaults$type <- take()
    } else if (a == '--url-template') {
      defaults$url_template <- take()
    } else if (a == '--crosswalk') {
      defaults$crosswalk <- take()
    } else if (a == '--keep-zips') {
      defaults$keep_zips <- TRUE
    } else if (a == '--force') {
      defaults$force <- TRUE
    } else if (a == '--no-gtap') {
      defaults$no_gtap <- TRUE
    } else {
      stop('Unknown argument: ', a, ' (use --help)', call. = FALSE)
    }
    i <- i + 1L
  }

  if (!defaults$type %in% c('con', 'gen')) {
    stop('--type must be either "con" (consumption) or "gen" (general); got: "',
         defaults$type, '"', call. = FALSE)
  }

  if (is.null(defaults$out)) {
    # --no-gtap drops the GTAP dimension entirely, so the filename drops the
    # "gtap" token: hs10_by_country_<year>_<type>.rds (the split-share base the
    # 484(f) weight mapper consumes) vs hs10_by_country_gtap_<year>_<type>.rds.
    stem <- if (defaults$no_gtap) 'hs10_by_country_%d_%s.rds'
            else 'hs10_by_country_gtap_%d_%s.rds'
    defaults$out <- here('data', 'weights',
                         sprintf(stem, defaults$year, defaults$type))
  }

  if (is.null(defaults$raw_dir)) {
    defaults$raw_dir <- here('data', 'weights', 'raw',
                             as.character(defaults$year))
  }

  defaults
}


print_help <- function() {
  cat('Usage: Rscript src/io/build_import_weights.R [options]\n\n')
  cat('Options:\n')
  cat('  --year <YYYY>          Calendar year to build (default: 2024)\n')
  cat('  --raw-dir <DIR>        Directory holding IMDByymm.ZIP files. If ZIPs are\n')
  cat('                         missing they are downloaded into this directory.\n')
  cat('                         Default: data/weights/raw/<year>/\n')
  cat('  --out <PATH>           Output RDS path.\n')
  cat('                         Default: data/weights/hs10_by_country_gtap_<year>_<type>.rds\n')
  cat('  --type {con|gen}       con = consumption imports (default), gen = general imports\n')
  cat('  --url-template <STR>   Override download URL. Use {year}, {yy}, {mm} placeholders.\n')
  cat('                         Default: ', DEFAULT_URL_TEMPLATE, '\n', sep = '')
  cat('  --crosswalk <PATH>     HS10 -> GTAP crosswalk CSV. Default: resources/hs10_gtap_crosswalk.csv\n')
  cat('  --no-gtap              Skip the GTAP crosswalk join entirely. Emits\n')
  cat('                         (hs10, cty_code, imports) with NO gtap_code column\n')
  cat('                         to hs10_by_country_<year>_<type>.rds — the split-share\n')
  cat('                         base for the 484(f) weight mapper. No code is dropped\n')
  cat('                         for being unmapped (there is no crosswalk to miss).\n')
  cat('  --keep-zips            Do not delete downloaded ZIPs after building.\n')
  cat('  --force                Re-download even if the ZIP exists locally.\n')
  cat('  -h, --help             Show this message.\n')
}


# =============================================================================
# Download helpers
# =============================================================================

#' Resolve the URL for a (year, month) pair from a template.
build_url <- function(template, year, month) {
  yy <- sprintf('%02d', year %% 100)
  mm <- sprintf('%02d', month)
  template |>
    str_replace_all('\\{year\\}', as.character(year)) |>
    str_replace_all('\\{yy\\}', yy) |>
    str_replace_all('\\{mm\\}', mm)
}


#' Format a file size (in bytes) as a human-readable MB/GB string.
format_size <- function(bytes) {
  if (is.na(bytes) || bytes < 0) return('?')
  if (bytes >= 1e9) sprintf('%.1f GB', bytes / 1e9)
  else if (bytes >= 1e6) sprintf('%.1f MB', bytes / 1e6)
  else if (bytes >= 1e3) sprintf('%.1f KB', bytes / 1e3)
  else sprintf('%d B', as.integer(bytes))
}


#' Format an elapsed-time duration as a short string.
format_elapsed <- function(seconds) {
  if (seconds >= 60) sprintf('%dm%02ds', as.integer(seconds %/% 60),
                              as.integer(seconds %% 60))
  else sprintf('%.1fs', seconds)
}


#' Validate that a path is a parseable ZIP containing IMP_DETL.TXT.
#'
#' Catches the common failure modes that the previous size-only check missed:
#'   - HTML returned for a 404 (large, "looks like a file", but not a ZIP)
#'   - Truncated/partial downloads
#'   - 200 OK that returned an unrelated archive
#' Returns TRUE only if the archive opens AND contains IMP_DETL.TXT.
zip_is_valid_imp_detl <- function(path) {
  if (!file.exists(path)) return(FALSE)
  contents <- tryCatch(
    utils::unzip(path, list = TRUE),
    error   = function(e) NULL,
    warning = function(w) NULL
  )
  if (is.null(contents) || !is.data.frame(contents) || nrow(contents) == 0) {
    return(FALSE)
  }
  any(grepl('IMP_DETL\\.TXT$', contents$Name, ignore.case = TRUE))
}


#' Ensure all 12 monthly ZIPs for `year` are present in `raw_dir`. Downloads
#' anything missing from `url_template`.
ensure_zips_present <- function(raw_dir, year, url_template, force = FALSE) {
  dir.create(raw_dir, showWarnings = FALSE, recursive = TRUE)
  yy <- sprintf('%02d', year %% 100)
  failed_downloads <- character()

  for (mm in sprintf('%02d', 1:12)) {
    local_name <- sprintf('IMDB%s%s.ZIP', yy, mm)
    local_path <- file.path(raw_dir, local_name)
    if (force || !file.exists(local_path)) {
      url <- build_url(url_template, year, as.integer(mm))
      message('Downloading ', basename(local_path), ' from ', url)
      # mode='wb' so the binary ZIP is not mangled on Windows.
      t0 <- Sys.time()
      status <- tryCatch(
        utils::download.file(url, local_path, mode = 'wb', quiet = TRUE),
        error = function(e) { message('  FAILED: ', conditionMessage(e)); -1L }
      )
      elapsed <- as.numeric(difftime(Sys.time(), t0, units = 'secs'))
      ok <- identical(as.integer(status), 0L) &&
            file.exists(local_path) &&
            zip_is_valid_imp_detl(local_path)
      if (!ok) {
        if (file.exists(local_path)) {
          message('  rejected: not a valid IMP_DETL ZIP (likely a 404 page or partial download)')
          file.remove(local_path)
        }
        failed_downloads <- c(failed_downloads, local_name)
      } else {
        message(sprintf('  done: %s in %s',
                        format_size(file.info(local_path)$size),
                        format_elapsed(elapsed)))
      }
    } else {
      message('Already present: ', basename(local_path), ' (',
              format_size(file.info(local_path)$size), ')')
    }
  }

  if (length(failed_downloads) > 0) {
    stop(
      'Could not obtain the following Census ZIP files: ',
      paste(failed_downloads, collapse = ', '), '\n',
      'Options:\n',
      '  - Re-run with --url-template if Census moved the files.\n',
      '  - Manually place the ZIPs in ', raw_dir,
      ' and re-run (downloads are skipped when files exist).\n',
      'See docs/weights.md for manual-download instructions.'
    )
  }

  invisible(raw_dir)
}


# =============================================================================
# Fixed-width parsing of IMP_DETL.TXT
# =============================================================================

# Positions match Tariff-ETRs/src/data_processing.R::load_imports_hs10_country()
# and the Census Bureau import detail file structure.
IMP_DETL_POSITIONS <- function() {
  readr::fwf_positions(
    start     = c(1,  11,  23,  27,  74,   179),
    end       = c(10, 14,  26,  28,  88,   193),
    col_names = c('hs10', 'cty_code', 'year', 'month', 'con_val_mo', 'gen_val_mo')
  )
}


#' Read and aggregate one monthly ZIP. Returns annual-so-far HS10 x country
#' rows (single month). Caller binds rows and aggregates over months.
read_imdb_zip <- function(zip_path, target_year, type = c('con', 'gen')) {
  type <- match.arg(type)
  t0 <- Sys.time()

  contents <- utils::unzip(zip_path, list = TRUE)
  detl <- contents$Name[grepl('IMP_DETL\\.TXT$', contents$Name, ignore.case = TRUE)]

  if (length(detl) == 0) {
    stop('No IMP_DETL.TXT in ', basename(zip_path))
  }
  if (length(detl) > 1) {
    stop('Multiple IMP_DETL.TXT files in ', basename(zip_path))
  }

  tmp <- utils::unzip(zip_path, files = detl, exdir = tempdir(), overwrite = TRUE)
  on.exit(if (file.exists(tmp)) file.remove(tmp), add = TRUE)

  records <- readr::read_fwf(
    file = tmp,
    col_positions = IMP_DETL_POSITIONS(),
    col_types = readr::cols(
      hs10        = readr::col_character(),
      cty_code    = readr::col_character(),
      year        = readr::col_integer(),
      month       = readr::col_integer(),
      con_val_mo  = readr::col_double(),
      gen_val_mo  = readr::col_double()
    ),
    progress = FALSE
  )

  value_col <- if (type == 'con') 'con_val_mo' else 'gen_val_mo'

  result <- records |>
    filter(.data$year == target_year) |>
    mutate(
      hs10  = stringr::str_pad(.data$hs10, width = 10, side = 'left', pad = '0'),
      value = .data[[value_col]]
    ) |>
    select(year, month, hs10, cty_code, value)

  elapsed <- as.numeric(difftime(Sys.time(), t0, units = 'secs'))
  message(sprintf('Processed %s — %s rows in %s',
                  basename(zip_path),
                  format(nrow(result), big.mark = ','),
                  format_elapsed(elapsed)))

  result
}


# =============================================================================
# Shared Census-IMDB store (parsed detail parquet, managed by the Census-IMDB
# repo). When all 12 monthly parquets for the target year are present, the build
# reads them instead of downloading + fixed-width-parsing 12 ZIPs (~15-20 min).
# The store carries both con_val_mo and gen_val_mo, so con and gen builds are
# both supported. Rows are filtered to the target calendar year exactly as
# read_imdb_zip does (dropping prior-period corrections embedded in a monthly
# file), so sum(value) by HS10 x country is identical to the ZIP path. Set
# IMDB_USE_STORE=0 to force the ZIP path.
# =============================================================================
IMDB_STORE_DIR <- Sys.getenv('IMDB_STORE_DIR',
  '/nfs/roberts/project/pi_nrs36/shared/raw_data/Census-IMDB')
IMDB_USE_STORE <- !identical(Sys.getenv('IMDB_USE_STORE', '1'), '0')

#' Read one calendar year from the shared store, in read_imdb_zip's shape.
#' Returns NULL (caller falls back to ZIPs) if disabled or any month missing.
read_imdb_store_year <- function(yr, type = c('con', 'gen')) {
  type <- match.arg(type)
  if (!IMDB_USE_STORE) return(NULL)
  yms   <- sprintf('%d-%02d', yr, 1:12)
  paths <- file.path(IMDB_STORE_DIR, 'detail',
                     paste0('imdb_detail_', yms, '.parquet'))
  if (!all(file.exists(paths))) return(NULL)
  value_col <- if (type == 'con') 'con_val_mo' else 'gen_val_mo'
  purrr::map_dfr(paths, function(p) {
    arrow::read_parquet(p, col_select = c('hs10', 'cty_code',
                                          'year_month', value_col)) |>
      filter(substr(year_month, 1, 4) == as.character(yr)) |>
      transmute(year  = as.integer(substr(year_month, 1, 4)),
                month = as.integer(substr(year_month, 6, 7)),
                hs10  = stringr::str_pad(hs10, 10, side = 'left', pad = '0'),
                cty_code,
                value = .data[[value_col]])
  })
}

# =============================================================================
# Pre-build orchestration helper
# =============================================================================

#' Ensure import weights are present before a downstream build needs them.
#'
#' Called from `src/pipeline/00_build_timeseries.R` as a pre-build step. Resolves the
#' weight file via the same path that `load_import_weights()` uses
#' (explicit `config/local_paths.yaml::import_weights`, then auto-detect of
#' `data/weights/hs10_by_country_gtap_<year>_con.rds`). If the file is found,
#' returns its path silently. If it's missing and the user hasn't opted out,
#' invokes `build_import_weights()` to fetch + parse Census imports
#' (15-20 min one-time download). Honors `weight_mode = 'unweighted'` as an
#' opt-out (returns NULL).
#'
#' @param weight_mode Optional override; defaults to `local_paths.yaml::weight_mode`.
#' @param year Target year for the build (default 2024).
#' @return Character path to the resolved weight file, or NULL if opted out.
ensure_import_weights <- function(weight_mode = NULL, year = 2024L) {
  local_paths <- tryCatch(load_local_paths(), error = function(e) NULL)
  if (is.null(local_paths)) {
    # load_local_paths() should never error since it returns defaults on a
    # missing yaml. If something exotic happened, default to safe behavior.
    local_paths <- list(import_weights = NULL, weight_mode = 'required')
  }

  if (is.null(weight_mode)) {
    weight_mode <- local_paths$weight_mode %||% 'required'
  }

  if (identical(weight_mode, 'unweighted')) {
    message('Pre-build: weight_mode = "unweighted" — skipping import-weights check.')
    return(invisible(NULL))
  }

  # Explicit config path wins. Otherwise rely on the same auto-detect that
  # load_local_paths() uses.
  resolved <- local_paths$import_weights
  if (!is.null(resolved) && nzchar(resolved) && file.exists(resolved)) {
    message('Pre-build: import weights present at ', resolved)
    return(invisible(resolved))
  }

  autodetected <- tryCatch(autodetect_import_weights(),
                           error = function(e) NULL)
  if (!is.null(autodetected) && file.exists(autodetected)) {
    message('Pre-build: import weights auto-detected at ', autodetected)
    return(invisible(autodetected))
  }

  # No file found — build it. This is the fresh-clone path. Document loudly:
  # the download + parse takes ~15-20 min, and the user can opt out via
  # --unweighted or weight_mode: unweighted.
  default_out <- here('data', 'weights',
                            sprintf('hs10_by_country_gtap_%d_con.rds', year))
  default_raw <- here('data', 'weights', 'raw', as.character(year))

  message('\n', strrep('=', 70))
  message('PRE-BUILD: import weights file not found.')
  message('Auto-building from Census Bureau monthly imports — ~15-20 min one-time.')
  message('  Target: ', default_out)
  message('To skip (and run unweighted): pass --unweighted to 00_build_timeseries.R')
  message('or set weight_mode: unweighted in config/local_paths.yaml.')
  message(strrep('=', 70), '\n')

  build_import_weights(
    year         = year,
    raw_dir      = default_raw,
    out_path     = default_out
  )

  invisible(default_out)
}


# =============================================================================
# Main
# =============================================================================

build_import_weights <- function(year,
                                  raw_dir,
                                  out_path,
                                  type          = 'con',
                                  url_template  = DEFAULT_URL_TEMPLATE,
                                  crosswalk     = here('resources',
                                                       'hs10_gtap_crosswalk.csv'),
                                  keep_zips     = FALSE,
                                  force_download = FALSE,
                                  no_gtap       = FALSE) {

  if (!no_gtap && !file.exists(crosswalk)) {
    stop('HS10 -> GTAP crosswalk not found at ', crosswalk,
         '. Set --crosswalk or check the install.')
  }

  message('\n', strrep('=', 70))
  message('BUILD IMPORT WEIGHTS — year=', year, ' type=', type,
          if (no_gtap) '  (no-gtap: split-share base)' else '')
  message(strrep('=', 70))
  message('Raw directory: ', raw_dir)
  message('Output file:   ', out_path)
  if (!no_gtap) message('Crosswalk:     ', crosswalk)
  message('URL template:  ', url_template)
  message('')

  # 1. Source monthly rows: shared Census-IMDB store first (all 12 months
  #    present), else download + parse the 12 ZIPs.
  t_parse <- Sys.time()
  monthly <- read_imdb_store_year(year, type)
  if (!is.null(monthly)) {
    message(sprintf('\nUsing shared Census-IMDB store: loaded %s monthly records in %s',
                    format(nrow(monthly), big.mark = ','),
                    format_elapsed(as.numeric(difftime(Sys.time(), t_parse, units = 'secs')))))
  } else {
    ensure_zips_present(raw_dir, year, url_template, force = force_download)

    yy <- sprintf('%02d', year %% 100)
    zip_pattern <- sprintf('^IMDB%s\\d{2}\\.ZIP$', yy)
    zip_files <- list.files(raw_dir, pattern = zip_pattern,
                            full.names = TRUE, ignore.case = TRUE)
    zip_files <- sort(zip_files)

    if (length(zip_files) != 12) {
      stop('Expected 12 monthly ZIPs for year ', year, ', found ', length(zip_files),
           ' in ', raw_dir)
    }

    # 2. Parse and aggregate
    message('\nReading ', length(zip_files), ' monthly ZIP files...')
    monthly <- purrr::map_dfr(zip_files, read_imdb_zip,
                              target_year = year, type = type)
    message(sprintf('Loaded %s monthly records in %s',
                    format(nrow(monthly), big.mark = ','),
                    format_elapsed(as.numeric(difftime(Sys.time(), t_parse, units = 'secs')))))
  }

  message('Aggregating to HS10 x country...')
  t_agg <- Sys.time()
  hs10_by_country <- monthly |>
    group_by(hs10, cty_code) |>
    summarise(imports = sum(value), .groups = 'drop') |>
    # Drop chapters 98-99 (special provisions / re-imports / Chapter 99 lines):
    # the tariff calculation uses 9903 series internally and 98-series do not
    # represent ordinary import flows. Matches Tariff-ETRs upstream behavior.
    filter(!str_detect(hs10, '^(98|99)'))
  message(sprintf('  %s aggregated rows in %s',
                  format(nrow(hs10_by_country), big.mark = ','),
                  format_elapsed(as.numeric(difftime(Sys.time(), t_agg, units = 'secs')))))

  # 3. Join GTAP crosswalk (skipped entirely under --no-gtap)
  if (no_gtap) {
    message('Skipping GTAP crosswalk join (--no-gtap): emitting hs10 x country only.')
    result <- hs10_by_country |>
      select(hs10, cty_code, imports) |>
      arrange(hs10, cty_code)
  } else {
  message('Joining HS10 -> GTAP crosswalk...')
  xwalk <- read_csv(crosswalk, show_col_types = FALSE,
                    col_types = cols(hs10 = col_character(),
                                     gtap_code = col_character())) |>
    select(hs10, gtap_code) |>
    distinct()

  result <- hs10_by_country |>
    left_join(xwalk, by = 'hs10') |>
    mutate(gtap_code = stringr::str_to_lower(gtap_code)) |>
    relocate(gtap_code, .after = hs10)

  unmapped <- result |> filter(is.na(gtap_code))
  n_unmapped <- nrow(unmapped)
  if (n_unmapped > 0) {
    unmapped_value <- sum(unmapped$imports)
    message(sprintf('  %s HS10 codes did not match the GTAP crosswalk ($%.1fM of imports) — dropping.',
                    format(n_unmapped, big.mark = ','),
                    unmapped_value / 1e6))

    # Write the dropped codes to a CSV next to the output for audit.
    audit_path <- file.path(dirname(out_path),
                            sprintf('unmapped_hs10_%s_%s.csv', year, type))
    dir.create(dirname(audit_path), showWarnings = FALSE, recursive = TRUE)
    unmapped |>
      select(hs10, cty_code, imports) |>
      arrange(desc(imports)) |>
      readr::write_csv(audit_path)
    message('  audit written to: ', audit_path)

    # Show the top 5 by import value so the user can judge whether the drop is material.
    message('  top 5 by value:')
    top5 <- unmapped |>
      group_by(hs10) |>
      summarise(imports = sum(imports), .groups = 'drop') |>
      arrange(desc(imports)) |>
      head(5)
    for (i in seq_len(nrow(top5))) {
      message(sprintf('    %s : $%.1fM',
                      top5$hs10[i], top5$imports[i] / 1e6))
    }
    message('  Extend resources/hs10_gtap_crosswalk.csv (or run scripts/update_crosswalk.R in Tariff-ETRs) to cover them.')

    result <- result |> filter(!is.na(gtap_code))
  }
  }  # end !no_gtap

  # 4. Sanity checks
  message('\nResult summary:')
  message(sprintf('  rows         : %s', format(nrow(result), big.mark = ',')))
  message(sprintf('  hs10         : %s', format(dplyr::n_distinct(result$hs10), big.mark = ',')))
  message(sprintf('  countries    : %s', format(dplyr::n_distinct(result$cty_code), big.mark = ',')))
  if (!no_gtap) {
    message(sprintf('  gtap_code    : %s', format(dplyr::n_distinct(result$gtap_code), big.mark = ',')))
  }
  message(sprintf('  total $      : $%.1fB', sum(result$imports) / 1e9))

  if (sum(result$imports) < 1e12) {
    warning('Total imports look too low ($', round(sum(result$imports) / 1e9, 1),
            'B) — please sanity-check the source ZIPs.')
  }

  # 5. Write
  out_dir <- dirname(out_path)
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  saveRDS(result, out_path)
  message('\nWrote ', out_path)

  # 6. Optional cleanup
  if (!keep_zips) {
    message('Cleaning up downloaded ZIPs in ', raw_dir,
            ' (pass --keep-zips to retain).')
    unlink(list.files(raw_dir, pattern = zip_pattern,
                      full.names = TRUE, ignore.case = TRUE))
    # Remove the raw dir if it's empty.
    if (length(list.files(raw_dir, all.files = TRUE, no.. = TRUE)) == 0) {
      unlink(raw_dir, recursive = TRUE)
    }
  }

  invisible(result)
}


if (sys.nframe() == 0) {
  argv <- commandArgs(trailingOnly = TRUE)
  opts <- parse_args(argv)

  if (opts$help) {
    print_help()
    quit(status = 0)
  }

  build_import_weights(
    year           = opts$year,
    raw_dir        = opts$raw_dir,
    out_path       = opts$out,
    type           = opts$type,
    url_template   = opts$url_template,
    crosswalk      = opts$crosswalk,
    keep_zips      = opts$keep_zips,
    force_download = opts$force,
    no_gtap        = opts$no_gtap
  )
}
