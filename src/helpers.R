# =============================================================================
# Helper Functions for Tariff Rate Tracker
# =============================================================================

library(tidyverse)
library(jsonlite)
library(yaml)
library(here)

# =============================================================================
# Rate Parsing Functions
# =============================================================================

#' Parse a rate string from HTS into numeric value
#'
#' Handles formats:
#'   - "6.8%" -> 0.068
#'   - "Free" -> 0.0
#'   - "" or NA -> NA
#'   - Compound rates (e.g., "2.4¢/kg + 5%") -> NA with flag
#'   - Specific rates (e.g., "$1.50/doz") -> NA with flag
#'
#' @param rate_string Character string containing rate
#' @return Numeric rate or NA
parse_rate <- function(rate_string) {
  if (is.null(rate_string) || is.na(rate_string) || rate_string == '') {
    return(NA_real_)
  }

  # Trim whitespace
  rate_string <- trimws(rate_string)

  # Handle "Free"
  if (tolower(rate_string) == 'free') {
    return(0.0)
  }

  # Simple percentage: "6.8%" or "25%"
  if (grepl('^[0-9.]+%$', rate_string)) {
    value <- as.numeric(gsub('%', '', rate_string))
    return(value / 100)
  }

  # Percentage with decimals but no % sign (rare, treat as fraction e.g. 0.25 = 25%)
  if (grepl('^[0-9]+\\.[0-9]+$', rate_string) && as.numeric(rate_string) < 1) {
    warning('parse_rate: interpreting "', rate_string, '" as fraction (not percentage). ',
            'Add % suffix to rate strings for clarity.')
    return(as.numeric(rate_string))
  }

  # Compound or specific rates - return NA (need manual handling)
  return(NA_real_)
}

#' Check if a rate string is a simple ad valorem rate
#'
#' @param rate_string Character string
#' @return Logical TRUE if simple ad valorem
is_simple_rate <- function(rate_string) {
  if (is.null(rate_string) || is.na(rate_string) || rate_string == '') {
    return(FALSE)
  }
  rate_string <- trimws(rate_string)
  tolower(rate_string) == 'free' || grepl('^[0-9.]+%$', rate_string)
}


# =============================================================================
# HTS Code Functions
# =============================================================================

#' Normalize HTS code to 10-digit format
#'
#' Removes periods/dots and pads to 10 digits.
#' Returns NA for codes that are too short (<4 digits) or too long (>10 digits).
#'
#' @param hts_code Character HTS code (e.g., "0101.30.00.00")
#' @return Character 10-digit code (e.g., "0101300000")
normalize_hts <- function(hts_code) {
  if (is.null(hts_code) || is.na(hts_code) || hts_code == '') {
    return(NA_character_)
  }
  # Remove periods
  clean <- gsub('\\.', '', hts_code)
  # Guard: must be 4-10 digits

  if (nchar(clean) < 4 || nchar(clean) > 10) {
    return(NA_character_)
  }
  # Pad to 10 digits if needed
  if (nchar(clean) < 10) {
    clean <- str_pad(clean, 10, side = 'right', pad = '0')
  }
  return(clean)
}

#' Extract prefix at specified digit level
#'
#' @param hts10 10-digit HTS code
#' @param digits Number of digits (2, 4, 6, 8, or 10)
#' @return Character prefix
hts_prefix <- function(hts10, digits) {
  substr(hts10, 1, digits)
}


# =============================================================================
# Footnote Parsing Functions
# =============================================================================

#' Extract Chapter 99 references from footnotes
#'
#' Looks for references like "See 9903.88.15" in footnotes
#'
#' @param footnotes List of footnote objects from HTS JSON
#' @return Character vector of Chapter 99 subheadings
extract_chapter99_refs <- function(footnotes) {
  if (is.null(footnotes) || length(footnotes) == 0) {
    return(character(0))
  }

  refs <- character(0)

  for (fn in footnotes) {
    if (!is.null(fn$value)) {
      # Pattern: 9903.XX.XX (Chapter 99 subchapter III only)
      matches <- str_extract_all(fn$value, '9903\\.[0-9]{2}\\.[0-9]{2}')[[1]]
      refs <- c(refs, matches)
    }
  }

  return(unique(refs))
}


# =============================================================================
# Special Program Parsing
# =============================================================================

#' Parse special rate programs from the special column
#'
#' The special column contains text like:
#' "Free (A+,AU,BH,CL,CO,D,E,IL,JO,KR,MA,OM,P,PA,PE,S,SG)"
#'
#' @param special_string Character string from special column
#' @return List with rate and programs
parse_special_programs <- function(special_string) {
  if (is.null(special_string) || is.na(special_string) || special_string == '') {
    return(list(rate = NA_real_, programs = character(0)))
  }

  # Extract rate (before parentheses)
  rate_match <- str_extract(special_string, '^[^(]+')
  rate <- if (!is.na(rate_match)) parse_rate(trimws(rate_match)) else NA_real_

  # Extract program codes from parentheses
  programs_match <- str_extract(special_string, '\\(([^)]+)\\)')
  programs <- if (!is.na(programs_match)) {
    codes <- gsub('[()]', '', programs_match)
    trimws(unlist(strsplit(codes, ',')))
  } else {
    character(0)
  }

  return(list(rate = rate, programs = programs))
}


# =============================================================================
# Country Code Functions
# =============================================================================

#' Load census country codes
#'
#' @return Tibble with Code and Name columns
load_census_codes <- function(path = here('resources', 'census_codes.csv')) {
  read_csv(
    path,
    col_types = cols(Code = col_character(), Name = col_character())
  )
}

#' Load country to partner mapping
#'
#' @return Tibble with cty_code, cty_name, partner columns
load_country_partner_mapping <- function(path = here('resources', 'country_partner_mapping.csv')) {
  read_csv(
    path,
    col_types = cols(.default = col_character())
  )
}

#' Get all country codes from census_codes.csv
#'
#' @return Character vector of all country codes
get_all_country_codes <- function() {
  census <- load_census_codes()
  census$Code
}


# =============================================================================
# File I/O Helpers
# =============================================================================

#' Get the most recent HTS archive file
#'
#' @param year Year to look for (default: current year)
#' @return Path to most recent JSON file
get_latest_hts_archive <- function(year = format(Sys.Date(), '%Y'),
                                   archive_dir = here('data', 'hts_archives')) {
  files <- list.files(
    archive_dir,
    pattern = paste0('hts_', year, '.*\\.json$'),
    full.names = TRUE
  )

  if (length(files) == 0) {
    stop(paste('No HTS archive found for year', year))
  }

  # Return most recently modified
  file_info <- file.info(files)
  files[which.max(file_info$mtime)]
}

#' Ensure output directory exists
#'
#' @param path Directory path
ensure_dir <- function(path) {
  if (!dir.exists(path)) {
    dir.create(path, recursive = TRUE)
  }
  return(path)
}


# =============================================================================
# Policy Parameters (YAML)
# =============================================================================

#' Load policy parameters from YAML config
#'
#' Returns a list with convenience fields unpacked for direct use.
#'
#' @param yaml_path Path to policy_params.yaml
#' @param use_policy_dates If TRUE (default), swap date-sensitive config fields
#'   (IEEPA invalidation, S122 effective/expiry) to their policy_effective_date
#'   equivalents. Set FALSE when using --use-hts-dates or for utilities that
#'   need raw HTS timing. See docs/policy_timing.md.
#' @return List with raw params plus convenience fields
load_policy_params <- function(yaml_path = here('config', 'policy_params.yaml'),
                               use_policy_dates = TRUE) {
  if (!file.exists(yaml_path)) {
    stop('Policy params YAML not found: ', yaml_path)
  }

  params <- read_yaml(yaml_path)

  # Unpack convenience fields for country codes
  for (nm in names(params$country_codes)) {
    params[[nm]] <- params$country_codes[[nm]]
  }

  # ISO_TO_CENSUS as named character vector
  params$ISO_TO_CENSUS <- unlist(params$iso_to_census)

  # EU27_CODES as character vector, EU27_NAMES as named vector
  params$EU27_CODES <- names(params$eu27_codes)
  params$EU27_NAMES <- unlist(params$eu27_codes)
  names(params$EU27_NAMES) <- params$EU27_CODES

  # Section 232 chapters as flat vector
  params$SECTION_232_CHAPTERS <- unlist(params$section_232_chapters)

  # Authority columns as named vector
  params$AUTHORITY_COLUMNS <- unlist(params$authority_columns)

  # Section 301 rates as tibble
  if (!is.null(params$section_301_rates)) {
    params$SECTION_301_RATES <- tibble(
      ch99_pattern = map_chr(params$section_301_rates, 'ch99_pattern'),
      s301_rate = map_dbl(params$section_301_rates, 's301_rate')
    )
  }

  # Floor rates
  params$EU_FLOOR_RATE <- params$floor_rates$eu_floor
  params$FLOOR_RATE <- params$floor_rates$floor_rate
  params$FLOOR_COUNTRIES <- unlist(params$floor_rates$floor_countries)

  # Weighted ETR reporting config
  if (!is.null(params$weighted_etr)) {
    if (!is.null(params$weighted_etr$policy_dates)) {
      params$WEIGHTED_ETR_POLICY_DATES <- tibble(
        date = as.Date(map_chr(params$weighted_etr$policy_dates, 'date')),
        label = map_chr(params$weighted_etr$policy_dates, 'label')
      )
    }
    if (!is.null(params$weighted_etr$tpc_name_fixes)) {
      params$TPC_NAME_FIXES <- unlist(params$weighted_etr$tpc_name_fixes)
    }
  }

  # IEEPA invalidation date (SCOTUS ruling)
  if (!is.null(params$ieepa_invalidation_date)) {
    params$IEEPA_INVALIDATION_DATE <- as.Date(params$ieepa_invalidation_date)
  } else {
    params$IEEPA_INVALIDATION_DATE <- NULL
  }

  # Swiss/Liechtenstein framework (EO 14346)
  if (!is.null(params$swiss_framework)) {
    params$SWISS_FRAMEWORK <- list(
      effective_date = as.Date(params$swiss_framework$effective_date),
      expiry_date = as.Date(params$swiss_framework$expiry_date),
      finalized = isTRUE(params$swiss_framework$finalized),
      countries = unlist(params$swiss_framework$countries)
    )
  }

  # USMCA utilization shares (DataWeb SPI S/S+)
  params$USMCA_SHARES <- list(
    year = params$usmca_shares$year %||% NULL
  )

  # MFN exemption shares (FTA/GSP preference utilization)
  if (!is.null(params$mfn_exemption)) {
    params$MFN_EXEMPTION <- list(
      method = params$mfn_exemption$method %||% 'none',
      exclude_usmca_countries = isTRUE(params$mfn_exemption$exclude_usmca_countries)
    )
  } else {
    params$MFN_EXEMPTION <- list(method = 'none', exclude_usmca_countries = TRUE)
  }

  # Section 232 country exemptions (TRQ/quota agreements)
  if (!is.null(params$section_232_country_exemptions)) {
    params$S232_COUNTRY_EXEMPTIONS <- map(params$section_232_country_exemptions, function(entry) {
      # Expand 'eu' mnemonic to EU27 codes
      raw_countries <- unlist(entry$countries)
      expanded <- if ('eu' %in% raw_countries) {
        c(setdiff(raw_countries, 'eu'), params$EU27_CODES)
      } else {
        raw_countries
      }
      list(
        countries = expanded,
        rate = entry$rate,
        applies_to = unlist(entry$applies_to),
        expiry_date = if (!is.null(entry$expiry_date)) as.Date(entry$expiry_date) else NULL
      )
    })
  } else {
    params$S232_COUNTRY_EXEMPTIONS <- list()
  }

  # Series horizon
  if (!is.null(params$series_horizon$end_date)) {
    params$SERIES_HORIZON_END <- as.Date(params$series_horizon$end_date)
  } else {
    params$SERIES_HORIZON_END <- Sys.Date()
  }

  # Section 122 (Trade Act §122, 150-day statutory limit)
  if (!is.null(params$section_122)) {
    params$SECTION_122 <- list(
      effective_date = as.Date(params$section_122$effective_date),
      expiry_date = as.Date(params$section_122$expiry_date),
      finalized = isTRUE(params$section_122$finalized)
    )
  }

  # Swap policy dates if requested (SCOTUS ruling + S122 coordination)
  if (use_policy_dates) {
    if (!is.null(params$ieepa_invalidation_policy_date)) {
      params$IEEPA_INVALIDATION_DATE <- as.Date(params$ieepa_invalidation_policy_date)
      message('  Policy dates: IEEPA invalidation -> ', params$IEEPA_INVALIDATION_DATE)
    }
    if (!is.null(params$section_122$policy_effective_date)) {
      params$SECTION_122$effective_date <- as.Date(params$section_122$policy_effective_date)
      message('  Policy dates: S122 effective -> ', params$SECTION_122$effective_date)
    }
    if (!is.null(params$section_122$policy_expiry_date)) {
      params$SECTION_122$expiry_date <- as.Date(params$section_122$policy_expiry_date)
      message('  Policy dates: S122 expiry -> ', params$SECTION_122$expiry_date)
    }
  }

  # Local paths (optional user-specific file locations)
  params$LOCAL_PATHS <- load_local_paths()

  return(params)
}


#' Load optional local paths configuration
#'
#' Reads config/local_paths.yaml if present. Returns a named list of paths,
#' with NULL for any unset entries. Never required for core build.
#'
#' @param yaml_path Path to local_paths.yaml
#' @return Named list with import_weights, tpc_benchmark, tariff_etrs_repo
get_country_constants <- function(pp = NULL) {
  if (is.null(pp)) pp <- tryCatch(load_policy_params(), error = function(e) NULL)
  list(
    CTY_CHINA  = if (!is.null(pp)) pp$CTY_CHINA  else '5700',
    CTY_CANADA = if (!is.null(pp)) pp$CTY_CANADA else '1220',
    CTY_MEXICO = if (!is.null(pp)) pp$CTY_MEXICO else '2010',
    CTY_JAPAN  = if (!is.null(pp)) pp$CTY_JAPAN  else '5880',
    CTY_UK     = if (!is.null(pp)) pp$CTY_UK     else '4120',
    CTY_HK     = if (!is.null(pp)) pp$CTY_HK     else '5820',
    EU27_CODES = if (!is.null(pp)) pp$EU27_CODES else c(
      '4330', '4231', '4870', '4791', '4910', '4351', '4099', '4470', '4050',
      '4279', '4280', '4840', '4370', '4190', '4759', '4490', '4510', '4239',
      '4730', '4210', '4550', '4710', '4850', '4359', '4792', '4700', '4010'
    ),
    EU27_NAMES = if (!is.null(pp)) pp$EU27_NAMES else c(
      '4330' = 'Austria', '4231' = 'Belgium', '4870' = 'Bulgaria',
      '4791' = 'Croatia', '4910' = 'Cyprus', '4351' = 'Czech Republic',
      '4099' = 'Denmark', '4470' = 'Estonia', '4050' = 'Finland',
      '4279' = 'France', '4280' = 'Germany', '4840' = 'Greece',
      '4370' = 'Hungary', '4190' = 'Ireland', '4759' = 'Italy',
      '4490' = 'Latvia', '4510' = 'Lithuania', '4239' = 'Luxembourg',
      '4730' = 'Malta', '4210' = 'Netherlands', '4550' = 'Poland',
      '4710' = 'Portugal', '4850' = 'Romania', '4359' = 'Slovakia',
      '4792' = 'Slovenia', '4700' = 'Spain', '4010' = 'Sweden'
    ),
    ISO_TO_CENSUS = if (!is.null(pp)) pp$ISO_TO_CENSUS else c(
      'CN' = '5700', 'CA' = '1220', 'MX' = '2010',
      'JP' = '5880', 'UK' = '4120', 'GB' = '4120',
      'AU' = '6021', 'KR' = '5800', 'RU' = '4621',
      'AR' = '3570', 'BR' = '3510', 'UA' = '4623'
    ),
    STEEL_CHAPTERS = if (!is.null(pp)) pp$section_232_chapters$steel else c('72', '73'),
    ALUM_CHAPTERS  = if (!is.null(pp)) pp$section_232_chapters$aluminum else c('76')
  )
}


load_local_paths <- function(yaml_path = here('config', 'local_paths.yaml')) {
  defaults <- list(
    import_weights = NULL,
    tpc_benchmark = 'data/tpc/tariff_by_flow_day.csv',
    tariff_etrs_repo = NULL
  )

  if (!file.exists(yaml_path)) return(defaults)

  raw <- tryCatch(read_yaml(yaml_path), error = function(e) {
    warning('Failed to parse local_paths.yaml: ', conditionMessage(e))
    return(list())
  })

  # Merge with defaults (YAML nulls become R NULLs)
  for (nm in names(defaults)) {
    if (!is.null(raw[[nm]])) defaults[[nm]] <- raw[[nm]]
  }
  return(defaults)
}


# =============================================================================
# Revision / Archive Helpers
# =============================================================================

#' Parse a revision identifier into year and revision type
#'
#' Handles both year-prefixed and plain formats:
#'   '2026_rev_3'  -> list(year=2026, rev='rev_3')
#'   '2026_basic'  -> list(year=2026, rev='basic')
#'   'rev_32'      -> list(year=2025, rev='rev_32')
#'   'basic'       -> list(year=2025, rev='basic')
#'
#' @param revision Character revision identifier
#' @return List with year (integer) and rev (character) components
parse_revision_id <- function(revision) {
  if (grepl('^[0-9]{4}_', revision)) {
    year <- as.integer(substr(revision, 1, 4))
    rev <- sub('^[0-9]{4}_', '', revision)
    return(list(year = year, rev = rev))
  }
  return(list(year = 2025L, rev = revision))
}


#' Build USITC release name from revision identifier
#'
#' Maps a revision ID to the USITC release name used in API URLs.
#' Returns NA for pre-2025 revisions (no API access).
#'
#' @param revision Character revision identifier (e.g., 'rev_18', '2026_basic')
#' @return Character release name (e.g., '2025HTSRev18') or NA
build_release_name <- function(revision) {
  parsed <- parse_revision_id(revision)
  year <- parsed$year
  rev <- parsed$rev

  if (year < 2025) return(NA_character_)

  if (rev == 'basic') {
    return(paste0(year, 'HTSBasic'))
  }

  # Extract numeric part from rev_N
  rev_num <- as.integer(sub('^rev_', '', rev))
  if (is.na(rev_num)) return(NA_character_)

  return(paste0(year, 'HTSRev', rev_num))
}


#' Build USITC Chapter 99 PDF download URL
#'
#' Uses the USITC reststop file endpoint to construct a URL for downloading
#' the Chapter 99 PDF for a specific HTS release.
#'
#' @param release_name Character release name from build_release_name()
#' @return Character URL string
build_chapter99_url <- function(release_name) {
  paste0('https://hts.usitc.gov/reststop/file?release=',
         URLencode(release_name, reserved = TRUE),
         '&filename=Chapter+99')
}


#' Load revision dates from config CSV
#'
#' @param csv_path Path to revision_dates.csv
#' @param use_policy_dates If TRUE (default), swap policy_effective_date into
#'   effective_date where populated. This uses legal policy dates instead of
#'   HTS revision dates. Set FALSE or pass --use-hts-dates to use raw HTS dates.
#'   See docs/policy_timing.md for details on which revisions are affected.
#' @return Tibble with revision, effective_date, tpc_date
load_revision_dates <- function(csv_path = here('config', 'revision_dates.csv'),
                                use_policy_dates = TRUE) {
  if (!file.exists(csv_path)) {
    stop('Revision dates CSV not found: ', csv_path,
         '\nRun scraper or create manually.')
  }

  dates <- read_csv(csv_path, col_types = cols(
    revision = col_character(),
    effective_date = col_date(),
    policy_effective_date = col_date(),
    tpc_date = col_date(),
    policy_event = col_character(),
    tpc_policy_revision = col_character(),
    needs_review = col_character()
  ))

  # Validate
  stopifnot(all(!is.na(dates$revision)))
  stopifnot(all(!is.na(dates$effective_date)))
  stopifnot(!any(duplicated(dates$revision)))

  # Check for unresolved placeholder dates
  if ('needs_review' %in% names(dates)) {
    unreviewed <- dates %>% filter(!is.na(needs_review) & needs_review == 'TRUE')
    if (nrow(unreviewed) > 0) {
      stop(
        nrow(unreviewed), ' revision(s) have unreviewed placeholder dates:\n',
        paste0('  ', unreviewed$revision, '  effective_date=', unreviewed$effective_date,
               collapse = '\n'),
        '\n\nThe API publication date is NOT the policy effective date.',
        '\nOpen config/revision_dates.csv, set the correct effective_date,',
        '\nand remove or clear the needs_review column for these rows.'
      )
    }
    # Drop the column after validation — downstream code doesn't need it
    dates <- dates %>% select(-needs_review)
  }

  # Optionally swap policy_effective_date into effective_date
  if (use_policy_dates && 'policy_effective_date' %in% names(dates)) {
    n_swapped <- sum(!is.na(dates$policy_effective_date))
    if (n_swapped > 0) {
      dates <- dates %>%
        mutate(effective_date = if_else(!is.na(policy_effective_date),
                                        policy_effective_date,
                                        effective_date))
      message('  Policy dates: swapped ', n_swapped, ' revision effective dates')
    }
  }

  # Sort by effective_date
  dates <- dates %>% arrange(effective_date)

  message('Loaded ', nrow(dates), ' revision dates from ', csv_path)
  message('  Date range: ', min(dates$effective_date), ' to ', max(dates$effective_date))
  message('  TPC validation dates: ', sum(!is.na(dates$tpc_date)))

  return(dates)
}


#' List available HTS JSON archives
#'
#' Scans the archive directory and returns revision identifiers.
#'
#' @param archive_dir Path to HTS JSON archive directory
#' @param year Year prefix (default: 2025)
#' @return Character vector of revision identifiers
list_available_revisions <- function(archive_dir = here('data', 'hts_archives'), year = 2025) {
  files <- list.files(archive_dir, pattern = paste0('hts_', year, '.*\\.json$'))

  # Extract revision from filename: hts_2025_rev_32.json -> rev_32, hts_2025_basic.json -> basic
  revisions <- str_match(files, paste0('hts_', year, '_(.+)\\.json'))[, 2]
  revisions <- revisions[!is.na(revisions)]

  return(revisions)
}


#' Resolve JSON path for a revision
#'
#' @param revision Revision identifier (e.g., 'basic', 'rev_1')
#' @param archive_dir HTS archive directory
#' @param year HTS year (default: 2025)
#' @return Full file path to JSON
resolve_json_path <- function(revision, archive_dir = here('data', 'hts_archives'), year = 2025) {
  parsed <- parse_revision_id(revision)
  path <- file.path(archive_dir, paste0('hts_', parsed$year, '_', parsed$rev, '.json'))

  if (!file.exists(path)) {
    stop('HTS JSON not found: ', path)
  }

  return(path)
}


#' Get available revisions across all years
#'
#' Scans the archive directory for all years present in a revision list
#' and returns full revision identifiers (with year prefix for non-2025).
#'
#' @param all_revisions Character vector of revision IDs from revision_dates.csv
#' @param archive_dir Path to HTS archive directory
#' @return Character vector of available revision identifiers
get_available_revisions_all_years <- function(all_revisions, archive_dir = here('data', 'hts_archives')) {
  years_needed <- unique(map_int(all_revisions, ~ parse_revision_id(.)$year))
  available <- character()
  for (yr in years_needed) {
    yr_revisions <- list_available_revisions(archive_dir, year = yr)
    if (yr != 2025) yr_revisions <- paste0(yr, '_', yr_revisions)
    available <- c(available, yr_revisions)
  }
  return(available)
}


# =============================================================================
# HTS Concordance
# =============================================================================

#' Load and chain HTS product concordance for import remapping
#'
#' Reads the concordance CSV and builds a cumulative old->new mapping between
#' two revisions. Used to remap import product codes (which may reflect an
#' older HTS edition) to match snapshot product codes.
#'
#' @param concordance_path Path to hts_concordance.csv
#' @return Tibble with old_hts10, new_hts10, change_type columns
load_hts_concordance <- function(concordance_path = here('resources', 'hts_concordance.csv')) {
  if (!file.exists(concordance_path)) {
    warning('Concordance file not found: ', concordance_path)
    return(tibble(old_hts10 = character(), new_hts10 = character(), change_type = character()))
  }
  read_csv(concordance_path, col_types = cols(.default = col_character(),
                                               similarity = col_double()))
}


#' Remap import product codes using HTS concordance
#'
#' For imports whose hts10 does not appear in the snapshot, looks up the
#' concordance chain to find the successor code. Handles renames, splits,
#' and many-to-many mappings. When a code splits into multiple successors,
#' import value is divided equally among successors.
#'
#' @param imports Tibble with hts10, country (country_code), value columns
#' @param snapshot_codes Character vector of hts10 codes in the active snapshot
#' @param concordance Tibble from load_hts_concordance()
#' @return imports tibble with remapped hts10 codes and a `remapped` flag
remap_imports_via_concordance <- function(imports, snapshot_codes, concordance) {
  if (nrow(concordance) == 0) return(imports %>% mutate(remapped = FALSE))

  # Build old->new mapping (renames, splits, many_to_many — not 'added'/'dropped')
  mapping <- concordance %>%
    filter(!is.na(old_hts10), !is.na(new_hts10)) %>%
    select(old_hts10, new_hts10) %>%
    distinct()

  # Chain through transitive mappings (old->intermediate->new)
  # Iterate until stable — handles multi-step renames across revisions
  for (iter in 1:10) {
    chained <- mapping %>%
      inner_join(mapping, by = c('new_hts10' = 'old_hts10'), suffix = c('', '.next')) %>%
      filter(new_hts10.next != old_hts10)  # avoid cycles

    if (nrow(chained) == 0) break

    extended <- chained %>%
      select(old_hts10, new_hts10 = new_hts10.next) %>%
      distinct()

    # Replace intermediate mappings with chained ones
    mapping <- mapping %>%
      anti_join(chained %>% select(old_hts10, new_hts10), by = c('old_hts10', 'new_hts10')) %>%
      bind_rows(extended) %>%
      distinct()
  }

  # Only remap codes that are (a) missing from snapshot and (b) have a successor in snapshot
  missing_codes <- setdiff(unique(imports$hts10), snapshot_codes)
  useful_mapping <- mapping %>%
    filter(old_hts10 %in% missing_codes, new_hts10 %in% snapshot_codes)

  if (nrow(useful_mapping) == 0) return(imports %>% mutate(remapped = FALSE))

  # Count successors per old code (for splits, divide value equally)
  successor_counts <- useful_mapping %>% count(old_hts10, name = 'n_successors')
  useful_mapping <- useful_mapping %>% left_join(successor_counts, by = 'old_hts10')

  # Split imports into remappable and not
  imports_remap <- imports %>%
    filter(hts10 %in% useful_mapping$old_hts10) %>%
    inner_join(useful_mapping, by = c('hts10' = 'old_hts10'), relationship = 'many-to-many') %>%
    mutate(
      hts10 = new_hts10,
      value = value / n_successors,
      remapped = TRUE
    ) %>%
    select(-new_hts10, -n_successors)

  imports_keep <- imports %>%
    filter(!hts10 %in% useful_mapping$old_hts10) %>%
    mutate(remapped = FALSE)

  result <- bind_rows(imports_keep, imports_remap)

  n_remapped <- sum(result$remapped)
  if (n_remapped > 0) {
    cat('  Concordance: remapped', n_remapped, 'import rows (',
        length(unique(useful_mapping$old_hts10)), 'codes)\n')
  }

  return(result)
}


# =============================================================================
# Rate Schema
# =============================================================================

#' Canonical column vector for rate output
RATE_SCHEMA <- c(
  'hts10', 'country', 'base_rate', 'statutory_base_rate',
  'rate_232', 'rate_301', 'rate_ieepa_recip', 'rate_ieepa_fent',
  'rate_s122', 'rate_section_201', 'rate_other',
  'metal_share',
  'total_additional', 'total_rate',
  'usmca_eligible', 'revision', 'effective_date',
  'valid_from', 'valid_until'
)

#' Ensure a rates data frame conforms to the canonical schema
#'
#' Adds missing columns with sensible defaults, reorders to canonical order.
#' Extra columns are preserved at the end.
#'
#' @param df Data frame with rate data
#' @return Data frame with all RATE_SCHEMA columns present and ordered first
enforce_rate_schema <- function(df) {
  # Defaults by column
  defaults <- list(
    hts10 = NA_character_, country = NA_character_,
    base_rate = 0, statutory_base_rate = 0, rate_232 = 0, rate_301 = 0,
    rate_ieepa_recip = 0, rate_ieepa_fent = 0, rate_s122 = 0, rate_section_201 = 0, rate_other = 0,
    metal_share = 1.0,
    total_additional = 0, total_rate = 0,
    usmca_eligible = FALSE, revision = NA_character_,
    effective_date = as.Date(NA),
    valid_from = as.Date(NA), valid_until = as.Date(NA)
  )

  for (col in RATE_SCHEMA) {
    if (!col %in% names(df)) {
      df[[col]] <- defaults[[col]]
    }
  }

  # Fill NAs in numeric rate columns (bind_rows can introduce NAs)
  rate_cols <- c('base_rate', 'statutory_base_rate', 'rate_232', 'rate_301', 'rate_ieepa_recip',
                 'rate_ieepa_fent', 'rate_s122', 'rate_section_201', 'rate_other',
                 'total_additional', 'total_rate')
  for (col in rate_cols) {
    if (col %in% names(df)) {
      df[[col]][is.na(df[[col]])] <- 0
    }
  }

  # Reorder: schema columns first, then any extras
  extra_cols <- setdiff(names(df), RATE_SCHEMA)
  df <- df[, c(RATE_SCHEMA, extra_cols)]

  return(df)
}


# =============================================================================
# Stacking Rules
# =============================================================================

#' Apply tariff stacking rules (vectorized)
#'
#' Implements mutual-exclusion stacking (aligned with Tariff-ETRs):
#'
#'   China (232 > 0):  232 + recip*nonmetal + fentanyl + 301 + s122 + other
#'   China (no 232):   reciprocal + fentanyl + 301 + s122 + other
#'   Others (232 > 0): 232 + recip*nonmetal + fentanyl + s122 + other
#'   Others (no 232):  reciprocal + fentanyl + s122 + other
#'
#' Key rules:
#'   - 232 and IEEPA reciprocal are mutually exclusive (232 takes precedence)
#'   - For derivative 232 products (metal_share < 1.0), IEEPA reciprocal applies
#'     to the non-metal portion of customs value
#'   - Fentanyl stacks on 232 for all countries (separate IEEPA authority)
#'   - Section 301 only applies to China
#'   - Section 122 is scaled by nonmetal_share on 232 products (same treatment as
#'     IEEPA reciprocal). For pure-metal products (metal_share = 1.0), nonmetal_share = 0,
#'     so s122 contributes zero — Section 232 already covers these at higher rates.
#'     For derivative 232 products (metal_share < 1.0), s122 applies to the non-metal
#'     portion. For non-232 products, s122 stacks at full value.
#'
#' @param df Data frame with rate_232, rate_301, rate_ieepa_recip,
#'   rate_ieepa_fent, rate_s122, rate_other, metal_share, country columns
#' @param cty_china Census code for China (default: '5700')
#' @param stacking_method 'mutual_exclusion' (default, 232/IEEPA mutual exclusion)
#'   or 'tpc_additive' (all authorities stack additively, matching TPC methodology)
#' @return df with total_additional and total_rate recomputed
apply_stacking_rules <- function(df, cty_china = '5700', stacking_method = 'mutual_exclusion') {
  # Ensure optional columns exist and have no NAs
  if (!'rate_s122' %in% names(df)) {
    df$rate_s122 <- 0
  } else {
    df$rate_s122[is.na(df$rate_s122)] <- 0
  }
  if (!'rate_section_201' %in% names(df)) {
    df$rate_section_201 <- 0
  } else {
    df$rate_section_201[is.na(df$rate_section_201)] <- 0
  }
  if (!'metal_share' %in% names(df)) {
    df$metal_share <- 1.0
  } else {
    df$metal_share[is.na(df$metal_share)] <- 1.0
  }

  # TPC additive: all authorities stack with no mutual exclusion.
  # TPC confirmed (March 2026) they mostly agree with mutual exclusion between
  # 232 and IEEPA, with exceptions for copper (232 + CA/MX fentanyl) and
  # derivatives (IEEPA on non-metal portion). This mode is retained for
  # sensitivity analysis, not as a TPC-matching switch.
  if (stacking_method == 'tpc_additive') {
    return(
      df %>%
        mutate(
          total_additional = rate_232 + rate_ieepa_recip + rate_ieepa_fent +
            rate_301 + rate_s122 + rate_section_201 + rate_other,
          total_rate = base_rate + total_additional
        )
    )
  }

  # Per-metal-type nonmetal_share: only count the metal types that have active
  # 232 programs covering this product. Steel chapters → steel_share, aluminum
  # chapters + derivatives → aluminum_share, copper → copper_share.
  # IEEPA fills everything not claimed by the active 232 program's metal type.
  has_per_type <- all(c('steel_share', 'aluminum_share', 'copper_share') %in% names(df))

  if (has_per_type) {
    # Determine which metal type is active per product based on chapter/product type.
    # Steel chapters: 72/73; aluminum chapters: 76; derivatives: aluminum type.
    # Copper and other heading programs don't have metal-type 232 (they're full-product).
    primary_chapters <- c('72', '73', '76')
    df <- df %>%
      mutate(
        .ch2 = substr(hts10, 1, 2),
        .active_type_share = case_when(
          rate_232 > 0 & .ch2 %in% c('72', '73') ~ steel_share,
          rate_232 > 0 & .ch2 == '76'             ~ aluminum_share,
          rate_232 > 0 & metal_share < 1.0         ~ aluminum_share,  # derivatives
          TRUE ~ 0
        ),
        nonmetal_share = if_else(rate_232 > 0 & .active_type_share > 0,
                                  1 - .active_type_share, 0)
      ) %>%
      select(-.ch2, -.active_type_share)
  } else {
    # Fallback: aggregate metal_share (backward compat for flat/cbo methods)
    df <- df %>%
      mutate(nonmetal_share = if_else(rate_232 > 0 & metal_share < 1.0, 1 - metal_share, 0))
  }

  df <- df %>%
    mutate(
      total_additional = case_when(
        # China with 232: 232 + recip*nonmetal + fentanyl + 301 + s122*nonmetal + s201 + other
        country == cty_china & rate_232 > 0 ~
          rate_232 + rate_ieepa_recip * nonmetal_share + rate_ieepa_fent + rate_301 +
          rate_s122 * nonmetal_share + rate_section_201 + rate_other,

        # China without 232: reciprocal + fentanyl + 301 + s122 + s201 + other
        country == cty_china ~
          rate_ieepa_recip + rate_ieepa_fent + rate_301 + rate_s122 + rate_section_201 + rate_other,

        # Others with 232: 232 + recip*nonmetal + fentanyl + s122*nonmetal + s201 + other
        # Note: rate_301 excluded for non-China (builder only assigns 301 to China;
        # if non-China 301 is needed in the future, add a dedicated authority column)
        rate_232 > 0 ~
          rate_232 + rate_ieepa_recip * nonmetal_share + rate_ieepa_fent +
          rate_s122 * nonmetal_share + rate_section_201 + rate_other,

        # Others without 232: reciprocal + fentanyl + s122 + s201 + other
        TRUE ~ rate_ieepa_recip + rate_ieepa_fent + rate_s122 + rate_section_201 + rate_other
      ),
      total_rate = base_rate + total_additional
    ) %>%
    select(-nonmetal_share)
}


# =============================================================================
# Net Authority Decomposition (used by 08_weighted_etr, 09_daily_series)
# =============================================================================

#' Compute net authority contributions from snapshot rate columns
#'
#' Derives per-authority net contributions from the timeseries rate columns
#' using mutual-exclusion stacking rules. Net contributions sum to total_additional.
#'
#' @param df Data frame with rate_232, rate_301, rate_ieepa_recip,
#'   rate_ieepa_fent, rate_s122, rate_section_201, rate_other, metal_share, country columns
#' @param cty_china Census code for China (default: '5700')
#' @param stacking_method 'mutual_exclusion' (default) or 'tpc_additive'
#' @return df with net_232, net_ieepa, net_fentanyl, net_301, net_s122,
#'   net_section_201, net_other added
compute_net_authority_contributions <- function(df, cty_china = '5700',
                                                stacking_method = 'mutual_exclusion') {
  # Ensure optional columns exist (backwards compat with old snapshots)
  if (!'rate_s122' %in% names(df)) df$rate_s122 <- 0
  if (!'rate_section_201' %in% names(df)) df$rate_section_201 <- 0
  if (!'rate_other' %in% names(df)) df$rate_other <- 0
  if (!'metal_share' %in% names(df)) df$metal_share <- 1.0

  # TPC additive: all authorities contribute their full rate (no mutual exclusion)
  if (stacking_method == 'tpc_additive') {
    return(
      df %>%
        mutate(
          net_232 = rate_232,
          net_ieepa = rate_ieepa_recip,
          net_fentanyl = rate_ieepa_fent,
          net_301 = rate_301,
          net_s122 = rate_s122,
          net_section_201 = rate_section_201,
          net_other = rate_other
        )
    )
  }

  has_per_type <- all(c('steel_share', 'aluminum_share', 'copper_share') %in% names(df))

  if (has_per_type) {
    df <- df %>%
      mutate(
        .ch2 = substr(hts10, 1, 2),
        .active_type_share = case_when(
          rate_232 > 0 & .ch2 %in% c('72', '73') ~ steel_share,
          rate_232 > 0 & .ch2 == '76'             ~ aluminum_share,
          rate_232 > 0 & metal_share < 1.0         ~ aluminum_share,
          TRUE ~ 0
        ),
        nonmetal_share = if_else(rate_232 > 0 & .active_type_share > 0,
                                  1 - .active_type_share, 0)
      ) %>%
      select(-.ch2, -.active_type_share)
  } else {
    df <- df %>%
      mutate(nonmetal_share = if_else(rate_232 > 0 & metal_share < 1.0, 1 - metal_share, 0))
  }

  df %>%
    mutate(
      net_232 = if_else(rate_232 > 0, rate_232, 0),
      net_ieepa = if_else(rate_232 > 0, rate_ieepa_recip * nonmetal_share, rate_ieepa_recip),
      net_fentanyl = rate_ieepa_fent,
      net_301 = if_else(country == cty_china, rate_301, 0),
      net_s122 = if_else(rate_232 > 0, rate_s122 * nonmetal_share, rate_s122),
      net_section_201 = rate_section_201,
      net_other = rate_other
    ) %>%
    select(-nonmetal_share)
}


# =============================================================================
# Consolidated Functions (deduplicated from 03, 04, 06)
# =============================================================================

#' Parse rate from Chapter 99 general field
#'
#' Handles Ch99-specific formats:
#'   "The duty provided in the applicable subheading + 25%"
#'   "The duty provided in the applicable subheading plus 7.5%"
#'   "25%"
#'
#' Distinct from parse_rate() which handles MFN product rates.
#'
#' @param general_text Text from the general field
#' @return Numeric rate (e.g., 0.25) or NA
parse_ch99_rate <- function(general_text) {
  if (is.null(general_text) || is.na(general_text) || general_text == '') {
    return(NA_real_)
  }

  patterns <- c(
    '\\+\\s*([0-9]+\\.?[0-9]*)%',              # + 25% or +25%
    'plus\\s+([0-9]+\\.?[0-9]*)%',             # plus 25%
    'duty of\\s+([0-9]+\\.?[0-9]*)%',          # a duty of 50%
    '^([0-9]+\\.?[0-9]*)%$'                    # just "25%"
  )

  for (pattern in patterns) {
    match <- str_match(general_text, regex(pattern, ignore_case = TRUE))
    if (!is.na(match[1, 2])) {
      return(as.numeric(match[1, 2]) / 100)
    }
  }

  return(NA_real_)
}


#' Classify Chapter 99 code into authority buckets
#'
#' Unified classifier that uses normalized authority names:
#'   section_122, section_232, section_301, ieepa_reciprocal, section_201, other
#'
#' @param ch99_code Chapter 99 subheading (e.g., "9903.88.15")
#' @return Authority bucket name
classify_authority <- function(ch99_code) {
  if (is.na(ch99_code) || ch99_code == '') return('unknown')

  parts <- str_split(ch99_code, '\\.')[[1]]
  if (length(parts) < 2) return('unknown')

  middle <- as.integer(parts[2])

  # Section 122: 9903.03.xx (Phase 3, post-SCOTUS blanket)
  if (middle == 3) {
    return('section_122')
  }

  # Section 232:
  #   9903.74.xx  — MHD vehicles (US Note 38)
  #   9903.76.xx  — Wood products / lumber / furniture (US Note 37)
  #   9903.78.xx  — Copper derivatives (US Note 19)
  #   9903.80-85  — Steel, aluminum, derivatives
  #   9903.94.xx  — Auto tariffs (US Note 25/33)
  if (middle == 74 || middle == 76 || middle == 78 ||
      (middle >= 80 && middle <= 85) || middle == 94) {
    return('section_232')
  }

  # Section 301: 9903.86-89 (China tariffs) + 9903.91 (Biden 301) + 9903.92 (cranes)
  if ((middle >= 86 && middle <= 89) || middle == 91 || middle == 92) {
    return('section_301')
  }

  # IEEPA reciprocal: 9903.90 (China surcharges) + 9903.93/95/96
  if (middle == 90 || (middle >= 93 && middle <= 96 && middle != 94)) {
    return('ieepa_reciprocal')
  }

  # Section 201 (safeguards): 9903.40-45
  if (middle >= 40 && middle <= 45) {
    return('section_201')
  }

  return('other')
}


#' Check if HTS code is a valid 10-digit product code
#'
#' @param hts_code HTS code (with or without dots)
#' @return Logical
is_valid_hts10 <- function(hts_code) {
  if (is.null(hts_code) || is.na(hts_code) || hts_code == '') {
    return(FALSE)
  }

  clean <- gsub('\\.', '', hts_code)
  nchar(clean) == 10 && grepl('^[0-9]+$', clean)
}


# =============================================================================
# Blanket Tariff Expansion Helper
# =============================================================================

#' Add product-country pairs not yet in rates for a blanket tariff
#'
#' Common pattern used by fentanyl, 232 derivatives, and other blanket tariffs:
#' expand covered products x applicable countries, anti-join against existing
#' rows in rates, assign the blanket rate, and bind to rates.
#'
#' @param rates Current rates tibble
#' @param products Product data with hts10, base_rate columns
#' @param covered_hts10 Character vector of HTS10 codes subject to this tariff
#' @param country_rates Tibble with 'country' and 'blanket_rate' columns
#' @param rate_col Name of the rate column to set (e.g., 'rate_ieepa_fent')
#' @param label Description for log message (e.g., 'fentanyl-only duties')
#' @return Updated rates tibble with new pairs added
add_blanket_pairs <- function(rates, products, covered_hts10, country_rates,
                              rate_col, label) {
  applicable <- country_rates %>% filter(blanket_rate > 0) %>% pull(country)
  if (length(applicable) == 0 || length(covered_hts10) == 0) return(rates)

  existing <- rates %>%
    filter(hts10 %in% covered_hts10, country %in% applicable) %>%
    select(hts10, country)

  new_pairs <- products %>%
    filter(hts10 %in% covered_hts10) %>%
    select(hts10, base_rate) %>%
    mutate(base_rate = coalesce(base_rate, 0)) %>%
    tidyr::expand_grid(country = applicable) %>%
    anti_join(existing, by = c('hts10', 'country')) %>%
    left_join(country_rates, by = 'country') %>%
    mutate(
      rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0,
      rate_ieepa_fent = 0, rate_s122 = 0, rate_section_201 = 0, rate_other = 0
    )

  new_pairs[[rate_col]] <- new_pairs$blanket_rate
  new_pairs <- new_pairs %>%
    filter(blanket_rate > 0) %>%
    select(-blanket_rate)

  if (nrow(new_pairs) > 0) {
    message('  Adding ', nrow(new_pairs), ' product-country pairs for ', label)
    rates <- bind_rows(rates, new_pairs)
  }

  return(rates)
}


# =============================================================================
# Section 232 Derivative Products
# =============================================================================

#' Load Section 232 derivative product list
#'
#' Reads the derivative product CSV (aluminum-containing articles outside ch76
#' covered by 9903.85.04/.07/.08). These products are defined by US Note 19
#' subdivisions i/j/k and cannot be extracted from HTS JSON.
#'
#' @param path Path to s232_derivative_products.csv
#' @return Tibble with hts_prefix, ch99_code, derivative_type; or NULL if missing
load_232_derivative_products <- function(path = here('resources', 's232_derivative_products.csv')) {
  if (!file.exists(path)) {
    message('  232 derivative products file not found: ', path)
    return(NULL)
  }

  products <- read_csv(path, col_types = cols(
    hts_prefix = col_character(),
    ch99_code = col_character(),
    derivative_type = col_character()
  ))

  message('  Loaded ', nrow(products), ' Section 232 derivative product prefixes')
  return(products)
}


#' Load floor country product exemptions
#'
#' Products exempt from the 15% tariff floor for EU, Japan, S. Korea,
#' Switzerland/Liechtenstein. Categories: PTAAP (agricultural/natural
#' resources), civil aircraft, non-patented pharmaceuticals. Parsed from
#' US Notes to Chapter 99 by scrape_us_notes.R --floor-exemptions.
#'
#' @param path Path to floor_exempt_products.csv
#' @return Tibble with hts8, category, country_group, ch99_code; or empty tibble if missing
load_floor_exempt_products <- function(path = here('resources', 'floor_exempt_products.csv')) {
  if (!file.exists(path)) {
    message('  Floor exempt products file not found: ', path)
    return(tibble(hts8 = character(), category = character(),
                  country_group = character(), ch99_code = character()))
  }

  products <- read_csv(path, col_types = cols(.default = col_character()))
  message('  Loaded ', nrow(products), ' floor exempt products (',
          n_distinct(products$hts8), ' unique HTS8)')
  return(products)
}


#' Load revision-specific floor country product exemptions
#'
#' Tries per-revision file first (data/us_notes/floor_exempt_{revision}.csv),
#' then falls back to the static resources/floor_exempt_products.csv.
#'
#' @param revision_id Character revision ID (e.g., 'rev_18', '2026_basic')
#' @return Tibble with hts8, category, country_group, ch99_code; or empty tibble
load_revision_floor_exemptions <- function(revision_id) {
  # Try per-revision file first
  revision_path <- here('data', 'us_notes', paste0('floor_exempt_', revision_id, '.csv'))
  if (file.exists(revision_path)) {
    products <- read_csv(revision_path, col_types = cols(.default = col_character()))
    message('  Loaded ', nrow(products), ' floor exempt products for ', revision_id,
            ' (', n_distinct(products$hts8), ' unique HTS8)')
    return(products)
  }

  # Fall back to static file
  message('  No per-revision floor exemptions for ', revision_id,
          '; using static fallback')
  return(load_floor_exempt_products())
}


#' Load product-level USMCA utilization shares from USITC DataWeb SPI data
#'
#' Per-HTS10 x country USMCA shares from DataWeb SPI programs S/S+.
#' Year-specific files: resources/usmca_product_shares_{year}.csv
#' Generated by src/download_usmca_dataweb.R.
#' Returns NULL if file not found (triggers fallback to binary eligibility).
#'
#' @param policy_params Policy params list (uses usmca_shares$year if present)
#' @param path Override path (ignores year selection if provided)
#' @return Tibble with hts10, cty_code, usmca_share; or NULL if missing
load_usmca_product_shares <- function(policy_params = NULL, path = NULL) {
  if (is.null(path)) {
    year <- policy_params$USMCA_SHARES$year %||% NULL
    if (!is.null(year)) {
      path <- here('resources', paste0('usmca_product_shares_', year, '.csv'))
    } else {
      path <- here('resources', 'usmca_product_shares.csv')
    }
  }
  if (!file.exists(path)) {
    message('  USMCA product shares file not found — using binary eligibility')
    return(NULL)
  }
  shares <- read_csv(path, col_types = cols(
    hts10 = col_character(),
    cty_code = col_character(),
    usmca_share = col_double()
  ))
  message('  Loaded USMCA product shares: ', nrow(shares),
          ' product-country pairs from ', basename(path))
  return(shares)
}


#' Load MFN exemption shares (FTA/GSP preference utilization)
#'
#' HS2 x country exemption shares computed from Census calculated duty data.
#' effective_mfn = mfn_rate * (1 - exemption_share).
#' Sourced from Tariff-ETRs project. Returns NULL if file not found.
#'
#' @param path Path to mfn_exemption_shares.csv
#' @return Tibble with hs2, cty_code, exemption_share; or NULL if missing
load_mfn_exemption_shares <- function(path = here('resources', 'mfn_exemption_shares.csv')) {
  if (!file.exists(path)) {
    message('  MFN exemption shares file not found — using statutory base rates')
    return(NULL)
  }
  shares <- read_csv(path, col_types = cols(
    hs2 = col_character(),
    cty_code = col_character(),
    exemption_share = col_double()
  ))
  # Clamp exemption shares to [0, 1]
  shares <- shares %>%
    mutate(exemption_share = pmin(pmax(exemption_share, 0), 1))
  message('  Loaded MFN exemption shares: ', nrow(shares), ' HS2-country pairs')
  return(shares)
}


#' Load fentanyl carve-out product lists
#'
#' Product-specific fentanyl rate carve-outs: energy/critical minerals (CA) and
#' potash (CA/MX) receive a lower fentanyl rate than the general blanket.
#' Product lists sourced from Tariff-ETRs config (US Note 2 subdivisions).
#'
#' @param path Path to fentanyl_carveout_products.csv
#' @return Tibble with hts8, ch99_code, category columns (or NULL if file missing)
load_fentanyl_carveouts <- function(path = here('resources', 'fentanyl_carveout_products.csv')) {
  if (!file.exists(path)) {
    message('  Fentanyl carve-out products file not found: ', path)
    return(NULL)
  }

  carveouts <- read_csv(path, col_types = cols(
    hts8 = col_character(),
    ch99_code = col_character(),
    category = col_character()
  ))

  message('  Loaded ', nrow(carveouts), ' fentanyl carve-out product prefixes (',
          n_distinct(carveouts$category), ' categories)')
  return(carveouts)
}


#' Load metal content shares for Section 232 derivative products
#'
#' For derivative 232 products, the tariff applies only to the metal content
#' portion of customs value. This function returns per-product metal shares.
#'
#' Three methods:
#'   flat: All derivative products get metal_share = flat_share (default 0.50)
#'   cbo:  Product-level buckets from resources/cbo/ files
#'         (high=0.75, low=0.25, copper=0.90)
#'   bea:  HS10-level shares from BEA 2017 Detail I-O table
#'         (resources/metal_content_shares_bea_hs10.csv)
#'
#' Products in primary_chapters (72, 73, 76) always get metal_share = 1.0.
#' Non-derivative products outside primary chapters get metal_share = 1.0
#' (no metal adjustment — they don't have 232 rates).
#'
#' @param metal_cfg Metal content config list from policy_params.yaml
#' @param hts10_codes Character vector of HTS10 codes to compute shares for
#' @param derivative_hts10 Character vector of HTS10 codes identified as 232
#'   derivatives. Only these products receive metal_share < 1.0.
#' @return Tibble with hts10 and metal_share columns
load_metal_content <- function(metal_cfg = NULL, hts10_codes = character(0),
                               derivative_hts10 = character(0)) {
  if (length(hts10_codes) == 0) {
    return(tibble(hts10 = character(), metal_share = numeric(),
                  steel_share = numeric(), aluminum_share = numeric(),
                  copper_share = numeric(), other_metal_share = numeric()))
  }

  method <- if (!is.null(metal_cfg)) metal_cfg$method %||% 'flat' else 'flat'
  flat_share <- if (!is.null(metal_cfg)) metal_cfg$flat_share %||% 0.50 else 0.50
  primary_chapters <- if (!is.null(metal_cfg)) unlist(metal_cfg$primary_chapters) else c('72', '73', '76')

  # Start with all products at metal_share = 1.0 (full metal / no adjustment)
  result <- tibble(hts10 = hts10_codes, metal_share = 1.0)

  # Flag derivative products — only these get metal_share < 1.0
  is_derivative <- result$hts10 %in% derivative_hts10

  if (sum(is_derivative) == 0) {
    result$steel_share <- 0
    result$aluminum_share <- 0
    result$copper_share <- 0
    result$other_metal_share <- 0
    message('  Metal content: no derivative products to adjust')
    return(result)
  }

  if (method == 'flat') {
    result$metal_share[is_derivative] <- flat_share
    result$steel_share <- 0
    result$aluminum_share <- 0
    result$copper_share <- 0
    result$other_metal_share <- 0
    message('  Metal content: flat method (', round(flat_share * 100),
            '% for ', sum(is_derivative), ' derivatives)')

  } else if (method == 'cbo') {
    cbo_high_share <- if (!is.null(metal_cfg)) metal_cfg$cbo_high_share %||% 0.75 else 0.75
    cbo_low_share <- if (!is.null(metal_cfg)) metal_cfg$cbo_low_share %||% 0.25 else 0.25
    cbo_copper_share <- if (!is.null(metal_cfg)) metal_cfg$cbo_copper_share %||% 0.90 else 0.90

    # Load CBO bucket files
    cbo_dir <- here('resources', 'cbo')
    high_path <- file.path(cbo_dir, 'alst_deriv_h.csv')
    low_path <- file.path(cbo_dir, 'alst_deriv_l.csv')
    copper_path <- file.path(cbo_dir, 'copper.csv')

    cbo_shares <- tibble(hts10 = character(), metal_share = numeric())

    if (file.exists(copper_path)) {
      copper <- read_csv(copper_path, col_types = cols(I_COMMODITY = col_character()))
      cbo_shares <- bind_rows(cbo_shares,
        tibble(hts10 = copper$I_COMMODITY, metal_share = cbo_copper_share))
    }
    if (file.exists(high_path)) {
      high <- read_csv(high_path, col_types = cols(I_COMMODITY = col_character()))
      cbo_shares <- bind_rows(cbo_shares,
        tibble(hts10 = high$I_COMMODITY, metal_share = cbo_high_share))
    }
    if (file.exists(low_path)) {
      low <- read_csv(low_path, col_types = cols(I_COMMODITY = col_character()))
      cbo_shares <- bind_rows(cbo_shares,
        tibble(hts10 = low$I_COMMODITY, metal_share = cbo_low_share))
    }

    # Priority: copper > high > low (first match kept)
    cbo_shares <- cbo_shares %>%
      distinct(hts10, .keep_all = TRUE)

    # Only apply CBO shares to derivative products
    result <- result %>%
      left_join(cbo_shares %>% rename(cbo_share = metal_share), by = 'hts10') %>%
      mutate(
        metal_share = case_when(
          !is_derivative ~ 1.0,               # non-derivatives stay at 1.0
          !is.na(cbo_share) ~ cbo_share,      # CBO match for derivatives
          TRUE ~ flat_share                    # fallback to flat for unmatched derivatives
        )
      ) %>%
      select(-cbo_share)

    # CBO doesn't have per-type breakdown — use zeros
    result$steel_share <- 0
    result$aluminum_share <- 0
    result$copper_share <- 0
    result$other_metal_share <- 0

    n_cbo <- sum(!is.na(cbo_shares$hts10[cbo_shares$hts10 %in% derivative_hts10]))
    message('  Metal content: CBO method (', n_cbo, ' of ', sum(is_derivative),
            ' derivatives matched; high=', cbo_high_share, ', low=', cbo_low_share,
            ', copper=', cbo_copper_share, ')')

  } else if (method == 'bea') {
    # BEA I-O table shares at HS10 level (per-metal-type detail).
    # File generated by Tariff-ETRs build_metal_content_shares.R from 2017 BEA
    # Detail Use Table and HS10->NAICS->BEA crosswalk chain.
    bea_path <- here('resources', 'metal_content_shares_bea_hs10.csv')
    if (!file.exists(bea_path)) {
      stop('BEA metal content file not found: ', bea_path,
           '\nCopy from Tariff-ETRs or switch to flat/cbo method.')
    }

    bea_shares <- read_csv(bea_path, col_types = cols(
      hs10 = col_character(),
      .default = col_double()
    )) %>%
      select(hts10 = hs10,
             bea_steel = steel_share, bea_aluminum = aluminum_share,
             bea_copper = copper_share, bea_other = other_metal_share,
             bea_metal = metal_share)

    # Only apply BEA shares to derivative products
    result <- result %>%
      left_join(bea_shares, by = 'hts10') %>%
      mutate(
        metal_share = case_when(
          !is_derivative ~ 1.0,              # non-derivatives stay at 1.0
          !is.na(bea_metal) ~ bea_metal,     # BEA match for derivatives
          TRUE ~ flat_share                   # fallback to flat for unmatched derivatives
        ),
        steel_share       = if_else(is_derivative & !is.na(bea_steel), bea_steel, 0),
        aluminum_share    = if_else(is_derivative & !is.na(bea_aluminum), bea_aluminum, 0),
        copper_share      = if_else(is_derivative & !is.na(bea_copper), bea_copper, 0),
        other_metal_share = if_else(is_derivative & !is.na(bea_other), bea_other, 0)
      ) %>%
      select(-starts_with('bea_'))

    n_bea <- sum(bea_shares$hts10 %in% derivative_hts10)
    message('  Metal content: BEA method (', n_bea, ' of ', sum(is_derivative),
            ' derivatives matched; fallback=', flat_share, ')')

  } else {
    warning('Unknown metal_content method: ', method, '. Using flat fallback.')
    result$metal_share[is_derivative] <- flat_share
    result$steel_share <- 0
    result$aluminum_share <- 0
    result$copper_share <- 0
    result$other_metal_share <- 0
  }

  # Force primary chapters (72, 73, 76) to metal_share = 1.0 regardless of
  # derivative flag. These are base metal products — the tariff applies to
  # their full customs value, not a metal content fraction.
  is_primary <- substr(result$hts10, 1, 2) %in% primary_chapters
  if (any(is_primary)) {
    result$metal_share[is_primary] <- 1.0
    result$steel_share[is_primary] <- 0
    result$aluminum_share[is_primary] <- 0
    result$copper_share[is_primary] <- 0
    result$other_metal_share[is_primary] <- 0
  }

  return(result)
}


# =============================================================================
# Post-Interval Policy Adjustments
# =============================================================================

#' Collect date-bounded policy overrides that require post-interval adjustment
#'
#' Returns a list of adjustments with expiry dates and the zeroing action to apply.
#' Used by both point queries and interval-splitting aggregate paths.
#'
#' @param policy_params Policy params list from load_policy_params()
#' @return List of lists, each with `expiry_date`, `column`, and `label`
collect_expiry_adjustments <- function(policy_params) {
  adjustments <- list()

  # Section 122 expiry
  if (!is.null(policy_params$SECTION_122) &&
      !policy_params$SECTION_122$finalized) {
    adjustments <- c(adjustments, list(list(
      expiry_date = as.Date(policy_params$SECTION_122$expiry_date),
      column = 'rate_s122',
      label = 'Section 122'
    )))
  }

  # Swiss framework expiry (reverts floor override for CH/LI)
  if (!is.null(policy_params$SWISS_FRAMEWORK) &&
      !policy_params$SWISS_FRAMEWORK$finalized) {
    adjustments <- c(adjustments, list(list(
      expiry_date = as.Date(policy_params$SWISS_FRAMEWORK$expiry_date),
      column = 'rate_ieepa_recip',
      countries = policy_params$SWISS_FRAMEWORK$countries,
      label = 'Swiss framework'
    )))
  }

  return(adjustments)
}


#' Apply date-bounded policy expirations to a rate snapshot (point mode)
#'
#' Zeroes expired rate columns and recomputes totals via apply_stacking_rules().
#' For Swiss framework, zeroes the floor IEEPA rate for CH/LI only (conservative:
#' the pre-floor surcharge rate is not stored, so we revert to 0 rather than
#' guessing the original rate).
#'
#' @param snapshot Rate snapshot tibble
#' @param query_date Date for the point query
#' @param policy_params Policy params list from load_policy_params()
#' @return Adjusted snapshot with recomputed totals
apply_post_interval_adjustments_point <- function(snapshot, query_date, policy_params) {
  if (is.null(policy_params) || nrow(snapshot) == 0) return(snapshot)

  adjustments <- collect_expiry_adjustments(policy_params)
  needs_restacking <- FALSE

  for (adj in adjustments) {
    if (query_date > adj$expiry_date && adj$column %in% names(snapshot)) {
      if (!is.null(adj$countries)) {
        # Country-scoped adjustment (Swiss framework)
        snapshot <- snapshot %>%
          mutate(!!adj$column := if_else(country %in% adj$countries, 0, .data[[adj$column]]))
      } else {
        # Global adjustment (Section 122)
        snapshot[[adj$column]] <- 0
      }
      needs_restacking <- TRUE
    }
  }

  if (needs_restacking) {
    cty_china <- policy_params$CTY_CHINA %||% '5700'
    snapshot <- apply_stacking_rules(snapshot, cty_china = cty_china)
  }

  return(snapshot)
}


#' Get expiry split points within a revision interval
#'
#' Returns a sorted vector of dates at which policy adjustments take effect
#' within the given interval. Used by build_daily_aggregates() to split
#' revision intervals into sub-intervals with different policy states.
#'
#' @param valid_from Interval start date
#' @param valid_until Interval end date
#' @param policy_params Policy params list from load_policy_params()
#' @return Sorted Date vector of split points (each is the last active day before zeroing)
get_expiry_split_points <- function(valid_from, valid_until, policy_params) {
  if (is.null(policy_params)) return(as.Date(character()))

  adjustments <- collect_expiry_adjustments(policy_params)
  split_dates <- as.Date(character())

  for (adj in adjustments) {
    exp <- as.Date(adj$expiry_date)
    if (valid_from <= exp && valid_until > exp) {
      split_dates <- c(split_dates, exp)
    }
  }

  return(sort(unique(split_dates)))
}


#' Apply expiry zeroing to a snapshot for a given sub-interval
#'
#' Given a sub-interval start date, zeros any columns whose expiry_date < sub_start.
#'
#' @param rev_data Revision data tibble
#' @param sub_start Start date of the sub-interval
#' @param policy_params Policy params list
#' @return Adjusted rev_data
apply_expiry_zeroing <- function(rev_data, sub_start, policy_params) {
  if (is.null(policy_params)) return(rev_data)

  adjustments <- collect_expiry_adjustments(policy_params)

  for (adj in adjustments) {
    if (sub_start > adj$expiry_date && adj$column %in% names(rev_data)) {
      if (!is.null(adj$countries)) {
        rev_data <- rev_data %>%
          mutate(!!adj$column := if_else(country %in% adj$countries, 0, .data[[adj$column]]))
      } else {
        rev_data[[adj$column]] <- 0
      }
    }
  }

  return(rev_data)
}


# =============================================================================
# Point-in-Time Rate Query
# =============================================================================

#' Get rate snapshot at a specific date
#'
#' Filters the interval-encoded timeseries to rows where
#' valid_from <= query_date <= valid_until. Returns one revision's
#' worth of data (same shape as a single snapshot).
#'
#' Applies post-interval adjustments for any finalized=false policy overrides
#' (Section 122, Swiss framework) past their expiry dates.
#'
#' @param ts Timeseries tibble with valid_from/valid_until columns
#' @param query_date Date (or character coercible to Date)
#' @param policy_params Optional policy params list (from load_policy_params())
#' @return Tibble — one snapshot for the active revision at query_date
get_rates_at_date <- function(ts, query_date, policy_params = NULL) {
  query_date <- as.Date(query_date)

  # Load default policy params if not provided — ensures post-interval

  # adjustments (S122 expiry, Swiss framework) are applied consistently
  if (is.null(policy_params)) {
    policy_params <- tryCatch(load_policy_params(), error = function(e) NULL)
  }

  stopifnot(
    'valid_from' %in% names(ts),
    'valid_until' %in% names(ts)
  )

  snapshot <- ts %>%
    filter(valid_from <= query_date, valid_until >= query_date)

  if (nrow(snapshot) == 0) {
    warning('No rates found for date: ', query_date,
            '. Date range in timeseries: ',
            min(ts$valid_from), ' to ', max(ts$valid_until))
  }

  # Apply all date-bounded policy expirations
  snapshot <- apply_post_interval_adjustments_point(snapshot, query_date, policy_params)

  return(snapshot)
}
