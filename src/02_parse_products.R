# =============================================================================
# Step 02: Parse Product Data from HTS JSON
# =============================================================================
#
# Extracts HTS10 product data:
#   - Base MFN rate (from 'general' field)
#   - Chapter 99 footnote references
#
# Output: products_{revision}.rds with columns:
#   - hts10: 10-digit HTS code
#   - description: Product description
#   - base_rate: MFN rate (numeric)
#   - base_rate_raw: Original rate text
#   - ch99_refs: List of Chapter 99 references from footnotes
#   - has_complex_rate: Flag for non-ad-valorem rates
#
# =============================================================================

library(tidyverse)
library(jsonlite)

# =============================================================================
# Rate Parsing Functions
# =============================================================================

#' Parse a simple rate string into numeric
#'
#' Handles: "6.8%", "Free", "25%"
#' Returns NA for compound/specific rates
#'
#' @param rate_string Rate text from HTS
#' @return Numeric rate or NA
parse_simple_rate <- function(rate_string) {
  if (is.null(rate_string) || is.na(rate_string) || rate_string == '') {
    return(NA_real_)
  }

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

  # Not a simple rate
  return(NA_real_)
}


#' Check if rate string is simple ad valorem
#'
#' @param rate_string Rate text
#' @return Logical
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
#' @param hts_code HTS code with dots (e.g., "0101.30.00.00")
#' @return 10-digit code without dots (e.g., "0101300000")
normalize_hts10 <- function(hts_code) {
  if (is.null(hts_code) || is.na(hts_code) || hts_code == '') {
    return(NA_character_)
  }

  # Remove dots
  clean <- gsub('\\.', '', hts_code)

  # Must be at least 4 digits and at most 10
  if (nchar(clean) < 4 || nchar(clean) > 10) {
    return(NA_character_)
  }

  # Pad to 10 digits
  if (nchar(clean) < 10) {
    clean <- str_pad(clean, 10, side = 'right', pad = '0')
  }

  return(clean)
}


#' Check if HTS code is a valid 10-digit product code
#'
#' @param hts_code HTS code
#' @return Logical
is_valid_hts10 <- function(hts_code) {
  if (is.null(hts_code) || is.na(hts_code) || hts_code == '') {
    return(FALSE)
  }

  clean <- gsub('\\.', '', hts_code)

  # Must be exactly 10 digits
  nchar(clean) == 10 && grepl('^[0-9]+$', clean)
}


# =============================================================================
# Footnote Parsing Functions
# =============================================================================

#' Extract Chapter 99 references from footnotes
#'
#' @param footnotes List of footnote objects
#' @return Character vector of Chapter 99 codes
extract_ch99_refs <- function(footnotes) {
  if (is.null(footnotes) || length(footnotes) == 0) {
    return(character(0))
  }

  refs <- character(0)

  for (fn in footnotes) {
    value <- fn$value %||% ''

    # Pattern: "See 9903.XX.XX" or just "9903.XX.XX"
    matches <- str_extract_all(value, '9903\\.[0-9]{2}\\.[0-9]{2}')[[1]]
    refs <- c(refs, matches)
  }

  unique(refs)
}


# =============================================================================
# Main Parsing Function
# =============================================================================

#' Parse all products from HTS JSON
#'
#' @param json_path Path to HTS JSON file
#' @return Tibble with product data
parse_products <- function(json_path) {
  message('Reading HTS JSON from: ', json_path)

  # Read JSON
  hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)
  message('  Total items: ', length(hts_raw))

  # Process each item
  products <- map_dfr(hts_raw, function(item) {
    htsno <- item$htsno %||% ''

    # Skip if not a valid 10-digit HTS code
    if (!is_valid_hts10(htsno)) {
      return(NULL)
    }

    # Skip Chapter 99 entries (they're not products)
    if (grepl('^99', htsno)) {
      return(NULL)
    }

    hts10 <- normalize_hts10(htsno)
    general <- item$general %||% ''
    description <- item$description %||% ''

    # Parse rate
    base_rate <- parse_simple_rate(general)
    has_complex <- !is_simple_rate(general) && general != ''

    # Extract Chapter 99 references
    ch99_refs <- extract_ch99_refs(item$footnotes)

    tibble(
      hts10 = hts10,
      description = description,
      base_rate = base_rate,
      base_rate_raw = general,
      ch99_refs = list(ch99_refs),
      has_complex_rate = has_complex,
      n_ch99_refs = length(ch99_refs)
    )
  })

  message('  Parsed products: ', nrow(products))
  message('  With Chapter 99 refs: ', sum(products$n_ch99_refs > 0))
  message('  With complex rates: ', sum(products$has_complex_rate))

  return(products)
}


#' Parse products from multiple HTS revisions
#'
#' @param revisions Vector of revision identifiers (e.g., c('basic', 'rev_1', 'rev_32'))
#' @param archive_dir Directory containing HTS JSON files
#' @return Named list of product tibbles
parse_all_revisions <- function(revisions, archive_dir = 'data/hts_archives') {
  results <- list()

  for (rev in revisions) {
    filename <- paste0('hts_2025_', rev, '.json')
    filepath <- file.path(archive_dir, filename)

    if (!file.exists(filepath)) {
      warning('File not found: ', filepath)
      next
    }

    message('\n=== Processing ', rev, ' ===')
    products <- parse_products(filepath)
    results[[rev]] <- products
  }

  return(results)
}


#' Compare products between two revisions
#'
#' @param old_products Products from older revision
#' @param new_products Products from newer revision
#' @return List with changes
compare_products <- function(old_products, new_products) {
  old_hts <- old_products$hts10

  new_hts <- new_products$hts10

  added_hts <- setdiff(new_hts, old_hts)
  removed_hts <- setdiff(old_hts, new_hts)

  # Check for Chapter 99 ref changes
  common <- intersect(old_hts, new_hts)

  old_refs <- old_products %>%
    filter(hts10 %in% common) %>%
    select(hts10, old_refs = ch99_refs, old_n = n_ch99_refs)

  new_refs <- new_products %>%
    filter(hts10 %in% common) %>%
    select(hts10, new_refs = ch99_refs, new_n = n_ch99_refs)

  ref_changes <- old_refs %>%
    inner_join(new_refs, by = 'hts10') %>%
    filter(old_n != new_n | map2_lgl(old_refs, new_refs, ~!setequal(.x, .y)))

  list(
    added = new_products %>% filter(hts10 %in% added_hts),
    removed = old_products %>% filter(hts10 %in% removed_hts),
    ref_changes = ref_changes,
    n_added = length(added_hts),
    n_removed = length(removed_hts),
    n_ref_changes = nrow(ref_changes)
  )
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  setwd('C:/Users/ji252/Documents/GitHub/tariff_rate_tracker')

  # Parse baseline and latest revision
  products_basic <- parse_products('data/hts_archives/hts_2025_basic.json')
  products_rev32 <- parse_products('data/hts_archives/hts_2025_rev_32.json')

  # Compare
  cat('\n=== Changes from Basic to Rev 32 ===\n')
  changes <- compare_products(products_basic, products_rev32)
  cat('Added products:', changes$n_added, '\n')
  cat('Removed products:', changes$n_removed, '\n')
  cat('Chapter 99 ref changes:', changes$n_ref_changes, '\n')

  if (changes$n_ref_changes > 0) {
    cat('\nSample Chapter 99 reference changes:\n')
    print(head(changes$ref_changes %>% select(hts10, old_n, new_n), 20))
  }

  # Save
  if (!dir.exists('data/processed')) dir.create('data/processed', recursive = TRUE)
  saveRDS(products_basic, 'data/processed/products_basic.rds')
  saveRDS(products_rev32, 'data/processed/products_rev32.rds')
  message('\nSaved product data')

  # Summary stats
  cat('\n=== Summary ===\n')
  cat('Basic edition: ', nrow(products_basic), ' products, ',
      sum(products_basic$n_ch99_refs > 0), ' with Ch99 refs\n', sep = '')
  cat('Rev 32: ', nrow(products_rev32), ' products, ',
      sum(products_rev32$n_ch99_refs > 0), ' with Ch99 refs\n', sep = '')
}
