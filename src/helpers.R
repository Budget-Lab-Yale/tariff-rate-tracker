# =============================================================================
# Helper Functions for Tariff Rate Tracker
# =============================================================================

library(tidyverse)
library(jsonlite)
library(yaml)
library(here)

# Source extracted modules (backward compatible — all consumers that
# source helpers.R get the full function set)
source(here('src', 'policy_params.R'))
source(here('src', 'revisions.R'))
source(here('src', 'stacking.R'))
source(here('src', 'rate_schema.R'))
source(here('src', 'data_loaders.R'))

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
