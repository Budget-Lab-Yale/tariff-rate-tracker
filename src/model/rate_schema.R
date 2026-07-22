# =============================================================================
# Rate Schema — canonical columns, schema enforcement, authority classification
# =============================================================================
# Split from helpers.R. Sourced by helpers.R for backward compatibility.
# Direct consumers can source this file alone.

library(tidyverse)

# =============================================================================

#' Canonical column vector for rate output
RATE_SCHEMA <- c(
  'hts10', 'country', 'base_rate', 'statutory_base_rate',
  'rate_232', 'rate_301', 'rate_301_cs', 'rate_s301br',
  'rate_ieepa_recip', 'rate_ieepa_fent',
  'rate_s122', 'rate_s338', 'rate_section_201', 'rate_other',
  'metal_share', 'heading_program',
  'total_additional', 'total_rate',
  'usmca_eligible', 'revision', 'effective_date',
  'valid_from', 'valid_until'
)

# Per-authority columns carried by the one canonical product-country table.
AUTHORITY_RATE_COLUMNS <- c(
  'rate_232', 'rate_301', 'rate_301_cs', 'rate_s301br', 'rate_ieepa_recip',
  'rate_ieepa_fent', 'rate_s122', 'rate_s338', 'rate_section_201', 'rate_other'
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
    base_rate = 0, statutory_base_rate = 0, rate_232 = 0, rate_301 = 0, rate_301_cs = 0,
    rate_s301br = 0,
    rate_ieepa_recip = 0, rate_ieepa_fent = 0, rate_s122 = 0, rate_s338 = 0,
    rate_section_201 = 0, rate_other = 0,
    metal_share = 1.0, heading_program = FALSE,
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

  # Fail loud on a NA effective total. total_additional/total_rate are computed by
  # apply_stacking_rules() from the (already-filled) per-authority rate columns, so
  # a NA here means a rate column was NA when it ENTERED stacking — NA then poisons
  # the arithmetic (`NA > 0` is NA, `x * NA` is NA). Silently coalescing it to 0 (as
  # this function did until 2026-07-15) masks a real bug: that is exactly how the
  # annex_1c framework if_else NA-condition (06:3005) wiped §122 on framework-country
  # non-annex goods and shipped a spurious ~1.4pp 06-08 drop to the panel + model.
  # Surface it here instead of hiding it. Fix the upstream source; never coalesce.
  for (col in c('total_additional', 'total_rate')) {
    na_idx <- which(is.na(df[[col]]))
    if (length(na_idx) > 0) {
      ex <- utils::head(df[na_idx, c('hts10', 'country'), drop = FALSE], 5)
      stop('enforce_rate_schema: ', length(na_idx), ' row(s) have NA ', col,
           ' after stacking — an upstream rate column was NA entering ',
           'apply_stacking_rules() (NA poisons the total). Fix the source; do NOT ',
           'coalesce to 0. Sample (hts10/country): ',
           paste(sprintf('%s/%s', ex$hts10, ex$country), collapse = ', '))
    }
  }

  # Fill NAs in the per-authority rate columns + base (bind_rows for MFN-only grid
  # pairs legitimately leaves an absent authority column NA — that IS a 0 rate).
  # NB: total_additional/total_rate are deliberately NOT in this list — they are
  # guarded above (a NA total is a bug, not a fill-to-0 case).
  rate_cols <- c('base_rate', 'statutory_base_rate', 'rate_232', 'rate_301', 'rate_301_cs',
                 'rate_s301br', 'rate_ieepa_recip', 'rate_ieepa_fent', 'rate_s122',
                 'rate_s338', 'rate_section_201', 'rate_other')
  # Every rate_cols entry is in RATE_SCHEMA and the loop above guarantees each
  # RATE_SCHEMA column exists, so all are present here — no membership guard needed.
  for (col in rate_cols) {
    df[[col]][is.na(df[[col]])] <- 0
  }

  # Reorder: schema columns first, then any extras
  extra_cols <- setdiff(names(df), RATE_SCHEMA)
  df <- df[, c(RATE_SCHEMA, extra_cols)]

  return(df)
}


#' Apply the canonical defaults for the base MFN columns
#'
#' `base_rate` coalesces to 0 (a missing / non-ad-valorem MFN rate is treated as
#' duty-free by the model), and the `base_rate_type` exposure flag — when the
#' frame carries it — coalesces to 'free' to match. This is the single default
#' that the canonical grid builder applies to freshly product-joined rows.
#' Centralizing it keeps the two columns defaulting together (0 / 'free').
#'
#' @param df A frame carrying `base_rate` (and optionally `base_rate_type`)
#' @return `df` with `base_rate` NA->0 and (if present) `base_rate_type` NA->'free'
default_base_cols <- function(df) {
  df <- df %>% mutate(base_rate = coalesce(base_rate, 0))
  if ('base_rate_type' %in% names(df)) {
    df <- df %>% mutate(base_rate_type = coalesce(base_rate_type, 'free'))
  }
  df
}


#' Build the model's single product-country rate table
#'
#' The calculator creates this complete grid once. Every policy program then
#' mutates columns on existing rows; programs never create rows or carry their
#' own alternate table-building route.
#'
#' @param products Parsed product table with unique hts10 and base_rate.
#' @param countries Unique Census country codes.
#' @param seed_rates Optional sparse footnote rates keyed by hts10,country.
#' @return Complete product x country tibble with every authority column.
build_rate_grid <- function(products, countries, seed_rates = NULL) {
  required_products <- c('hts10', 'base_rate')
  missing_products <- setdiff(required_products, names(products))
  if (length(missing_products) > 0) {
    stop('build_rate_grid: products is missing: ',
         paste(missing_products, collapse = ', '), call. = FALSE)
  }
  if (anyNA(products$hts10) || any(products$hts10 == '') || anyDuplicated(products$hts10)) {
    stop('build_rate_grid: products$hts10 must be non-empty and unique', call. = FALSE)
  }
  countries <- as.character(countries)
  if (length(countries) == 0 || anyNA(countries) || any(countries == '') || anyDuplicated(countries)) {
    stop('build_rate_grid: countries must be non-empty, non-missing, and unique', call. = FALSE)
  }

  grid <- products %>%
    select(hts10, base_rate, any_of('base_rate_type')) %>%
    default_base_cols() %>%
    tidyr::expand_grid(country = countries)

  if (!is.null(seed_rates) && nrow(seed_rates) > 0) {
    required_seed <- c('hts10', 'country')
    missing_seed <- setdiff(required_seed, names(seed_rates))
    if (length(missing_seed) > 0) {
      stop('build_rate_grid: seed_rates is missing: ',
           paste(missing_seed, collapse = ', '), call. = FALSE)
    }
    if (anyDuplicated(seed_rates[required_seed])) {
      stop('build_rate_grid: seed_rates has duplicate (hts10, country) keys', call. = FALSE)
    }
    unexpected <- setdiff(names(seed_rates), c(required_seed, AUTHORITY_RATE_COLUMNS))
    if (length(unexpected) > 0) {
      stop('build_rate_grid: unexpected seed rate columns: ',
           paste(unexpected, collapse = ', '), call. = FALSE)
    }
    # A seed keyed outside products x countries would vanish in the left_join
    # below while both row-count invariants still pass — a silent duty drop.
    orphaned <- seed_rates %>% anti_join(grid, by = required_seed)
    if (nrow(orphaned) > 0) {
      stop('build_rate_grid: ', nrow(orphaned), ' seed rate row(s) have (hts10, country) ',
           'keys outside the product x country grid, e.g. ',
           paste(utils::head(paste0(orphaned$hts10, '/', orphaned$country), 3), collapse = ', '),
           call. = FALSE)
    }
    grid <- grid %>%
      left_join(seed_rates, by = required_seed, relationship = 'one-to-one')
  }

  for (col in AUTHORITY_RATE_COLUMNS) {
    if (!col %in% names(grid)) grid[[col]] <- 0
    grid[[col]] <- dplyr::coalesce(grid[[col]], 0)
  }

  expected_rows <- nrow(products) * length(countries)
  if (nrow(grid) != expected_rows || anyDuplicated(grid[c('hts10', 'country')])) {
    stop('build_rate_grid: canonical grid identity invariant failed', call. = FALSE)
  }
  grid
}


#' Build rev_intervals from revision_dates.csv, restricted to a set of revisions
#'
#' Extracts the standard (revision, valid_from, valid_until) interval encoding
#' for the given revisions. Used by snapshot-based paths (daily aggregation,
#' per-interval publish) that need to attach intervals without loading the full
#' combined timeseries. valid_until is INCLUSIVE (last active day): the next
#' revision's effective_date minus one; the tip extends to horizon_end.
#'
#' Lives here (not in 09_daily_series.R) so the publish layer can reuse it
#' without sourcing the daily-series / calculator module.
#'
#' @param revs_built Character vector of revision IDs that have snapshots available
#' @param rev_dates Tibble from load_revision_dates()
#' @param horizon_end Series horizon end date (defaults to Sys.Date())
#' @return Tibble with columns revision, valid_from, valid_until
build_rev_intervals <- function(revs_built, rev_dates, horizon_end = Sys.Date()) {
  if (length(revs_built) == 0) {
    stop('build_rev_intervals: revs_built is empty — no revisions to build intervals for')
  }
  matched <- rev_dates$effective_date[rev_dates$revision %in% revs_built]
  if (length(matched) == 0) {
    stop('build_rev_intervals: none of revs_built match revision_dates.csv')
  }
  missing_dates <- setdiff(revs_built, rev_dates$revision)
  if (length(missing_dates) > 0) {
    stop('build_rev_intervals: ', length(missing_dates),
         ' built revision(s) have no effective_date metadata: ',
         paste(missing_dates, collapse = ', '),
         '. Synthetic bnd_/sched_ revisions must be supplied via augmented ',
         'rev_dates before publishing.')
  }
  last_eff <- max(matched)
  if (horizon_end < last_eff) horizon_end <- last_eff

  rev_dates %>%
    filter(revision %in% revs_built) %>%
    arrange(effective_date) %>%
    mutate(
      valid_from = effective_date,
      valid_until = lead(effective_date) - 1
    ) %>%
    mutate(valid_until = if_else(is.na(valid_until), horizon_end, valid_until)) %>%
    select(revision, valid_from, valid_until)
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

  # Section 338 Canada (proclamations of 2026-07-20): charging headings
  # 9903.03.12-.14 plus the companion §232 / civil-aircraft exception headings
  # .15-.16. Match on the heading SEGMENTS (parts[2]==3 & parts[3] in 12:16),
  # not the 8-digit string, BEFORE the broader 9903.03.xx Section 122 bucket:
  # a future HTS archive that prints these with a statistical suffix (e.g.
  # 9903.03.12.10) must still route here, otherwise it falls through to
  # section_122 and the +50% rides rate_s122. The params-fed apply_section338()
  # stays the single rate source regardless.
  third <- if (length(parts) >= 3) suppressWarnings(as.integer(parts[3])) else NA_integer_
  if (isTRUE(middle == 3 && !is.na(third) && third %in% 12:16)) {
    return('section_338')
  }

  # Section 122: 9903.03.xx (Phase 3, post-SCOTUS blanket)
  if (middle == 3) {
    return('section_122')
  }

  # Section 232:
  #   9903.74.xx  — MHD vehicles (US Note 38)
  #   9903.76.xx  — Wood products / lumber / furniture (US Note 37)
  #   9903.78.xx  — Copper derivatives (US Note 19)
  #   9903.79.xx  — Semiconductors (US Note 39, effective 2026-01-16)
  #   9903.80-85  — Steel, aluminum, derivatives
  #   9903.94.xx  — Auto tariffs (US Note 25/33)
  if (middle == 74 || middle == 76 || middle == 78 || middle == 79 ||
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


#' Extract a legal effective-date offset from a Ch99 description
#'
#' HTS revisions sometimes publish new Ch99 entries with descriptions that
#' specify a future legal effective date — e.g. 9903.94.01 was added at rev_6
#' (HTS effective 2025-03-12) with description text starting "Except for
#' 9903.94.02..., effective with respect to entries on or after April 3, 2025,
#' passenger vehicles..." The HTS metadata says rev_6 is active, but the
#' rate is not legally collectible until 2025-04-03. Treating the rate as
#' active on the HTS effective_date over-states ~$7B of chapter 87
#' duty in March 2025 (per tariff-etr-eval/docs/tracker_audits/
#' s232_auto_effective_date_2026-04-28.md).
#'
#' Pattern is stable across revisions: "on or after [Month] [Day], [Year]"
#' with full English month names. Returns the EARLIEST date across all matches
#' in the description; that's the conservative gate (rate becomes legally
#' collectible at the first stated activation date). Errors via stop() if a
#' matched phrase fails to parse — silent NA would re-introduce the
#' pre-activation collection bug this gate is meant to prevent.
#'
#' @param description Ch99 description text (scalar character)
#' @return Date object, NA if no pattern matches or text is empty
extract_effective_date_offset <- function(description) {
  if (is.null(description) || length(description) == 0 ||
      is.na(description) || description == '') {
    return(as.Date(NA))
  }
  matches <- regmatches(
    description,
    gregexpr('on or after [A-Za-z]+ [0-9]{1,2}, [0-9]{4}',
             description, ignore.case = TRUE)
  )[[1]]
  if (length(matches) == 0) return(as.Date(NA))
  date_strs <- sub('^on or after ', '', matches, ignore.case = TRUE)
  # %B in as.Date expects title-case month names ("April"); normalize.
  date_strs <- vapply(date_strs, function(s) {
    parts <- strsplit(s, ' ', fixed = TRUE)[[1]]
    parts[1] <- paste0(toupper(substr(parts[1], 1, 1)),
                       tolower(substring(parts[1], 2)))
    paste(parts, collapse = ' ')
  }, character(1), USE.NAMES = FALSE)
  parsed <- as.Date(date_strs, format = '%B %d, %Y')
  if (any(is.na(parsed))) {
    bad <- date_strs[is.na(parsed)]
    stop('extract_effective_date_offset: failed to parse ',
         paste(shQuote(bad), collapse = ', '),
         ' from description: ', shQuote(description))
  }
  min(parsed)
}


#' Extract a legal expiry date from a Ch99 description
#'
#' Counterpart to extract_effective_date_offset() for window END dates. Time-
#' bounded Ch99 headings state their window in the description — e.g. the §301
#' exclusion heading 9903.88.69: "Effective with respect to entries on or after
#' June 15, 2024 and through November 9, 2026, articles the product of
#' China...". Two phrasings occur, with different inclusivity:
#'   "through [Month D, YYYY]"      -> that date IS the last active day
#'   "on or before [Month D, YYYY]" -> that date IS the last active day
#'   "before [Month D, YYYY]"       -> last active day is the PRIOR day
#'     (e.g. 9903.88.68: "on or after June 1, 2023, and before June 15, 2024")
#'
#' Returns the LAST ACTIVE DAY, normalized across phrasings. Multiple matches
#' return the LATEST date (conservative: keeps the entry active through the
#' longest stated window; the mirror of the start extractor's min()). Errors
#' via stop() if a matched phrase fails to parse — silent NA would let an
#' expired heading appear perpetually active.
#'
#' @param description Ch99 description text (scalar character)
#' @return Date (last active day), NA if no expiry phrase or text is empty
extract_expiry_date_offset <- function(description) {
  if (is.null(description) || length(description) == 0 ||
      is.na(description) || description == '') {
    return(as.Date(NA))
  }
  matches <- regmatches(
    description,
    gregexpr('(through|on or before|before) [A-Za-z]+ [0-9]{1,2}, [0-9]{4}',
             description, ignore.case = TRUE)
  )[[1]]
  # "on or after" contains no expiry keyword so it never matches; "on or
  # before" is matched in full (the alternation is ordered longest-first so
  # the bare-"before" branch cannot shave it down to exclusive semantics).
  if (length(matches) == 0) return(as.Date(NA))
  exclusive <- grepl('^before ', matches, ignore.case = TRUE)
  date_strs <- sub('^(through|on or before|before) ', '', matches,
                   ignore.case = TRUE)
  # %B in as.Date expects title-case month names ("April"); normalize.
  date_strs <- vapply(date_strs, function(s) {
    parts <- strsplit(s, ' ', fixed = TRUE)[[1]]
    parts[1] <- paste0(toupper(substr(parts[1], 1, 1)),
                       tolower(substring(parts[1], 2)))
    paste(parts, collapse = ' ')
  }, character(1), USE.NAMES = FALSE)
  parsed <- as.Date(date_strs, format = '%B %d, %Y')
  if (any(is.na(parsed))) {
    bad <- date_strs[is.na(parsed)]
    stop('extract_expiry_date_offset: failed to parse ',
         paste(shQuote(bad), collapse = ', '),
         ' from description: ', shQuote(description))
  }
  last_active <- parsed - ifelse(exclusive, 1L, 0L)
  max(last_active)
}


#' Drop Ch99 entries that are not legally active for a given revision
#'
#' Filters `ch99_data` two ways:
#'   * START gate: removes rows whose `effective_date_offset` (extracted by
#'     `extract_effective_date_offset()` during `parse_chapter99()`) is
#'     strictly AFTER the revision's `effective_date` — published but not yet
#'     legally collectible.
#'   * EXPIRY gate (NA-RATE ROWS ONLY): removes rate-less rows whose
#'     `expiry_date_offset` (last active day, extracted by
#'     `extract_expiry_date_offset()`) is strictly BEFORE the revision's
#'     `effective_date` — window over, text persists in the HTS. NA-rate rows
#'     never enter the rate join (`calculate_rates_fast()` filters
#'     `!is.na(rate)`), so dropping them is numerically a no-op by
#'     construction; what it buys is correct date-gating for the §301
#'     exclusion hook, which reads these headings out of ch99_data.
#'     RATE-BEARING rows past their stated expiry are RETAINED and loudly
#'     flagged: as of 2026-06-10 exactly two exist (9903.88.09, vestigial
#'     2019 §301 transition line; 9903.91.04, Biden §301 with stated expiry
#'     2025-12-31 — see todo.md). Dropping them would move numbers and needs
#'     its own parity-gated review.
#' Rows with NA offsets (no window phrase in the description) are always
#' retained.
#'
#' Centralized here so both call sites of `calculate_rates_for_revision()`
#' (`build_full_timeseries` in 00_build_timeseries.R and
#' `build_alternative_timeseries` in 09_daily_series.R) get the same gate.
#'
#' @param ch99_data Tibble from `parse_chapter99()` with `effective_date_offset`
#' @param revision_effective_date Date (or coercible) of the revision's HTS effective date
#' @return Filtered tibble; row count reported via message() when rows are dropped
filter_active_ch99 <- function(ch99_data, revision_effective_date) {
  if (is.null(ch99_data) || nrow(ch99_data) == 0) return(ch99_data)
  if (!'effective_date_offset' %in% names(ch99_data)) {
    # Backwards-compatible no-op for any cached ch99_<revision>.rds file
    # produced before this column existed.
    return(ch99_data)
  }
  rev_date <- as.Date(revision_effective_date)
  not_yet_active <- !is.na(ch99_data$effective_date_offset) &
                    ch99_data$effective_date_offset > rev_date
  if (any(not_yet_active)) {
    n_drop <- sum(not_yet_active)
    earliest <- min(ch99_data$effective_date_offset[not_yet_active])
    message('  Dropping ', n_drop, ' Ch99 entr', if (n_drop == 1) 'y' else 'ies',
            ' not yet legally active at ', rev_date,
            ' (earliest activation: ', earliest, ')')
    ch99_data <- ch99_data[!not_yet_active, , drop = FALSE]
  }
  if ('expiry_date_offset' %in% names(ch99_data)) {
    # Same backwards-compatibility contract as the start gate: caches built
    # before the expiry column existed skip this gate.
    expired <- !is.na(ch99_data$expiry_date_offset) &
               ch99_data$expiry_date_offset < rev_date
    expired_na_rate <- expired & is.na(ch99_data$rate)
    expired_rated   <- expired & !is.na(ch99_data$rate)
    if (any(expired_na_rate)) {
      n_drop <- sum(expired_na_rate)
      message('  Dropping ', n_drop, ' EXPIRED rate-less Ch99 entr',
              if (n_drop == 1) 'y' else 'ies', ' at ', rev_date, ': ',
              paste(head(ch99_data$ch99_code[expired_na_rate], 8), collapse = ', '),
              if (n_drop > 8) ', ...' else '')
      ch99_data <- ch99_data[!expired_na_rate, , drop = FALSE]
      expired_rated <- expired_rated[!expired_na_rate]
    }
    if (any(expired_rated)) {
      # Retained on purpose (dropping would move numbers); see docstring.
      message('  NOTE: ', sum(expired_rated), ' RATE-BEARING Ch99 entr',
              if (sum(expired_rated) == 1) 'y is' else 'ies are',
              ' past stated expiry at ', rev_date, ' but RETAINED: ',
              paste(ch99_data$ch99_code[expired_rated], collapse = ', '),
              ' — review before enabling a rate-bearing expiry gate (todo.md)')
    }
  }
  ch99_data
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
# Section 232 Derivative Products
# =============================================================================

#' Load Section 232 derivative product list
#'
#' Reads the derivative product CSV containing both aluminum derivatives
#' (outside ch76, covered by 9903.85.04/.07/.08, US Note 19) and steel
#' derivatives (outside ch72-73, covered by 9903.81.89-93, US Note 16).
#' Steel derivatives added via Section 232 Inclusions Process (FR 2025-15819).
#' Cannot be extracted from HTS JSON.
#'
#' @param path Path to s232_derivative_products.csv
#' @param effective_date Optional date to filter entries by effective_date column.
#'   Only entries with effective_date <= this date (or blank) are returned.
