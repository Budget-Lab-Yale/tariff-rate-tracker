# =============================================================================
# Helper Functions for Tariff Rate Tracker
# =============================================================================

library(tidyverse)
library(jsonlite)
library(yaml)
library(here)

# Backward-compatible entry point. Dependencies are declared in one manifest and
# resolved recursively, so adding/reordering sources cannot change which symbols
# exist. New callers should request the `core` bundle from module_loader.R.
if (!exists('tariff_load_dependencies', mode = 'function')) {
  source(here('src', 'core', 'module_loader.R'))
}
tariff_load_dependencies('helpers', environment())

# =============================================================================
# Output helpers
# =============================================================================

#' Write a parquet sibling next to a CSV / RDS output if `arrow` is installed.
#'
#' Cross-language-friendly companion to write_csv() / saveRDS(). Cheap no-op
#' if the `arrow` package isn't available — this lets downstream consumers
#' (Python, DuckDB, JS) read tracker outputs without R, while keeping `arrow`
#' an optional dependency for tracker maintainers.
#'
#' The output path is derived from the input by swapping `.csv` or `.rds` for
#' `.parquet`. Compression: zstd level 5 (good size/speed trade-off — ~3x
#' smaller than CSV for the daily outputs, ~5x smaller than RDS for the full
#' rate panel).
#'
#' @param df Data frame to write
#' @param path Path to the companion CSV / RDS (the parquet path is derived)
#' @return Invisible character path to the written parquet file, or NULL if
#'   arrow isn't installed.
write_parquet_if_arrow <- function(df, path) {
  if (!requireNamespace('arrow', quietly = TRUE)) return(invisible(NULL))
  parquet_path <- sub('\\.(csv|rds)$', '.parquet', path, ignore.case = TRUE)
  if (identical(parquet_path, path)) {
    # Path didn't have a recognized extension — fall back to appending.
    parquet_path <- paste0(path, '.parquet')
  }
  arrow::write_parquet(df, parquet_path,
                       compression       = 'zstd',
                       compression_level = 5L)
  invisible(parquet_path)
}


# =============================================================================
# Rate Parsing Functions
# =============================================================================

#' Strip HTML markup and normalize whitespace in schedule text
#'
#' USITC's exported `general` / `description` / `units` fields intermittently
#' carry stray markup, and it is NOT confined to prose: rate strings appear as
#' `2.5% <u></u>` in 2026 revisions 12 and 15, and as a clean `2.5%` in 13. The
#' rate VALUE never changes — only the markup — but every rate matcher below
#' anchors on `^[0-9.]+%$`, so an unstripped tag silently demoted 21 HTS10s
#' (motor-vehicle parts, bicycles, bicycle parts) to base_rate_type 'other'
#' with base_rate 0, and the net-of-MFN arms then subtracted that zero. See the
#' LIVE ERROR section in todo.md.
#'
#' Applied in the PARSE path, so the archives stay raw and every consumer sees
#' normalised text. `<br>` becomes a space because it separates words; all
#' other tags are removed outright so `kg<sup>2</sup>` reads as `kg2`. Entities
#' decode after tag removal so an encoded `&lt;b&gt;` is not then re-stripped.
#' The tag pattern is deliberately `<[^>]*>` rather than a tag-name allowlist —
#' the real data contains a malformed `</il>`.
#'
#' @param x Character vector of schedule text
#' @return Character vector, markup-free and whitespace-squished
normalize_schedule_text <- function(x) {
  x %>%
    str_replace_all('(?i)<br\\s*/?>', ' ') %>%
    str_replace_all('<[^>]*>', '') %>%
    str_replace_all('&nbsp;', ' ') %>%
    str_replace_all('&amp;', '&') %>%
    str_replace_all('&lt;', '<') %>%
    str_replace_all('&gt;', '>') %>%
    str_replace_all('&quot;', '"') %>%
    str_replace_all('&#39;', "'") %>%
    str_squish()
}

#' Parse a rate string from HTS into numeric value
#'
#' Handles formats:
#'   - "6.8%" -> 0.068
#'   - "Free" -> 0.0
#'   - "" or NA -> NA
#'   - Compound rates (e.g., "2.4¢/kg + 5%") -> NA with flag
#'   - Specific rates (e.g., "$1.50/doz") -> NA with flag
#'
#' Markup is stripped first — see normalize_schedule_text().
#'
#' @param rate_string Character string containing rate
#' @return Numeric rate or NA
parse_rate <- function(rate_string) {
  if (is.null(rate_string) || is.na(rate_string) || rate_string == '') {
    return(NA_real_)
  }

  # Strip markup, then trim. normalize_schedule_text() squishes whitespace, so
  # this subsumes the former trimws().
  rate_string <- normalize_schedule_text(rate_string)
  if (rate_string == '') return(NA_real_)

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
  rate_string <- normalize_schedule_text(rate_string)
  tolower(rate_string) == 'free' || grepl('^[0-9.]+%$', rate_string)
}

#' Classify a base MFN rate string into a rate-type bucket
#'
#' Exposure flag, NOT a conversion (scope decision 2026-06-10: no AVE
#' conversion — flag the exposed cells only). Companion to parse_rate(): where
#' parse_rate() collapses everything non-ad-valorem to NA, this preserves WHY
#' the numeric rate is missing so consumers can see which cells are effectively
#' treated as zero. Buckets:
#'   - "Free"                    -> 'free'
#'   - "6.8%" / "0.25" (<1)      -> 'ad_valorem'   (parse_rate returns a number)
#'   - "$1.50/doz", "2.4c/kg",
#'     "$1.035/kg + 17%"         -> 'specific_or_compound' (per-unit money;
#'                                   parse_rate returns NA -> understated as 0)
#'   - "" / NA / whitespace      -> NA_character_  (empty; inherits parent type)
#'   - anything else non-empty
#'     (e.g. "2.6% on the movement + 3.5% on the battery", legal-text duties)
#'                               -> 'other'
#'
#' Vectorized. A rate is 'specific_or_compound' iff it carries a monetary
#' per-unit component (cent sign or dollar sign) — this is the signature the
#' model cannot represent as a single ad valorem number.
#'
#' @param rate_string Character vector of rate strings
#' @return Character vector of buckets (NA for empty/NA input)
classify_rate_type <- function(rate_string) {
  # Markup first — an unstripped tag drops a plain "2.5%" into 'other'.
  s <- normalize_schedule_text(as.character(rate_string))
  empty <- is.na(rate_string) | is.na(s) | s == ''
  # Default non-empty strings to 'other'; refine below.
  out <- ifelse(empty, NA_character_, 'other')
  # Specific/compound: any monetary per-unit component. Real HTS text uses the
  # cent sign (¢) or dollar sign ($); the ASCII "Nc/unit" / "N cents/unit"
  # variant is caught defensively (OCR/test fixtures) but never bare-% strings.
  is_spec <- !empty & (grepl('¢|\\$', s) |
                       grepl('[0-9]\\s*c(ents?)?\\s*/', s, ignore.case = TRUE))
  out[is_spec] <- 'specific_or_compound'
  # Ad valorem: whole string is "N%" or a bare fraction < 1 (mirrors parse_rate).
  is_pct  <- !empty & grepl('^[0-9.]+%$', s)
  is_frac <- !empty & grepl('^[0-9]+\\.[0-9]+$', s) &
    suppressWarnings(as.numeric(s)) < 1
  out[is_pct | is_frac] <- 'ad_valorem'
  # Free (highest precedence; mutually exclusive with the above anyway).
  out[!empty & tolower(s) == 'free'] <- 'free'
  out
}

#' Read a cached products_<rev>.rds, failing loud if the parser schema is stale
#'
#' The base_rate_type exposure flag was added to parse_products() (2026-07-09).
#' A pre-flag cache silently omits it, which would poison the incremental build
#' and any base_rate_type consumer downstream. Rather than degrade quietly, stop
#' with instructions to regenerate via scripts/refresh_product_caches.R.
#'
#' @param path Path to a products_<rev>.rds cache
#' @return The products tibble
read_products_cache <- function(path) {
  products <- readRDS(path)
  if (!'base_rate_type' %in% names(products)) {
    stop('Stale product cache (missing base_rate_type): ', path,
         '\n  Regenerate with: Rscript scripts/refresh_product_caches.R',
         '\n  (or run a --full build, which re-parses products fresh).')
  }
  products
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
    pattern = paste0('hts_', year, '.*\\.json(\\.gz)?$'),
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
#
# DEPRECATED (2026-07-14): the Jaccard-heuristic concordance
# (resources/hts_concordance.csv) is superseded by the authoritative dated
# 484(f) transfer crosswalk (resources/hts10_484f_transfers.csv, built by
# tools/build_484f_crosswalk.R). These loaders remain only for archived
# import-remapping consumers; do not use them for import-weight revision
# mapping. No behavior change.

#' Load and chain HTS product concordance for import remapping
#'
#' @section Deprecated:
#' Heuristic — superseded by the 484(f) transfer crosswalk. See note above.
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
# Point-in-Time Rate Query
# =============================================================================

#' Get rate snapshot at a specific date
#'
#' Filters the interval-encoded timeseries to rows where
#' valid_from <= query_date <= valid_until. Returns one revision's
#' worth of data (same shape as a single snapshot).
#'
#' Policy boundaries are already represented by minted snapshots, so this
#' function only selects the interval active on the requested date.
#'
#' @param ts Timeseries tibble with valid_from/valid_until columns
#' @param query_date Date (or character coercible to Date)
#' @param policy_params Deprecated compatibility argument; ignored.
#' @return Tibble — one snapshot for the active revision at query_date
get_rates_at_date <- function(ts, query_date, policy_params = NULL) {
  query_date <- as.Date(query_date)

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

  return(snapshot)
}
