# =============================================================================
# Step 02: Extract Authority Mappings from HTS Data
# =============================================================================
#
# This script maps Chapter 99 references in HTS data to tariff authorities.
# Uses config/authority_mapping.yaml to determine authority, rate, and countries.
#
# Output: Tibble with:
#   - htsno: 10-digit HTS code
#   - chapter99_ref: Chapter 99 subheading (e.g., "9903.88.03")
#   - authority: Authority name (section_301, section_232, ieepa, etc.)
#   - sub_authority: Specific program (list_1, steel, fentanyl_china, etc.)
#   - rate: Additional duty rate
#   - countries: List of affected country codes (or "all")
#   - effective_date: When duty took effect
#
# =============================================================================

source('src/helpers.R')

# =============================================================================
# Authority Mapping Functions
# =============================================================================

#' Load authority mapping from YAML config
#'
#' @return List keyed by Chapter 99 subheading
load_authority_mapping <- function() {
  mapping_path <- 'config/authority_mapping.yaml'

  if (!file.exists(mapping_path)) {
    stop('Authority mapping not found: ', mapping_path)
  }

  yaml::read_yaml(mapping_path)
}


#' Map a single Chapter 99 reference to authority info
#'
#' @param ch99_ref Chapter 99 subheading (e.g., "9903.88.03")
#' @param authority_map List from load_authority_mapping()
#' @return List with authority, sub_authority, rate, countries, etc.
map_chapter99_to_authority <- function(ch99_ref, authority_map) {
  if (ch99_ref %in% names(authority_map)) {
    info <- authority_map[[ch99_ref]]
    return(list(
      chapter99_ref = ch99_ref,
      authority = info$authority,
      sub_authority = info$sub_authority,
      description = info$description %||% '',
      rate = info$rate,
      countries = info$countries,
      effective_date = info$effective_date %||% NA_character_,
      proclamation = info$proclamation %||% NA_character_,
      notes = info$notes %||% NA_character_
    ))
  } else {
    # Unmapped subheading
    return(list(
      chapter99_ref = ch99_ref,
      authority = 'unmapped',
      sub_authority = NA_character_,
      description = 'Unmapped Chapter 99 subheading',
      rate = NA_real_,
      countries = 'unknown',
      effective_date = NA_character_,
      proclamation = NA_character_,
      notes = 'Add mapping to config/authority_mapping.yaml'
    ))
  }
}


# =============================================================================
# Main Extraction Function
# =============================================================================

#' Extract authority mappings for all products with Chapter 99 references
#'
#' @param hts_data Tibble from ingest_hts_json
#' @return Tibble with product-authority mappings
extract_authorities <- function(hts_data) {
  message('Loading authority mapping...')
  authority_map <- load_authority_mapping()
  message('  Found ', length(authority_map), ' mapped Chapter 99 subheadings')

  # Filter to products with Chapter 99 references
  products_with_ch99 <- hts_data %>%
    filter(map_int(chapter99_refs, length) > 0)

  message('Processing ', nrow(products_with_ch99), ' products with Chapter 99 references...')

  # Expand each product's Chapter 99 refs and map to authorities
  authority_data <- products_with_ch99 %>%
    select(htsno, chapter99_refs) %>%
    unnest(chapter99_refs) %>%
    rename(chapter99_ref = chapter99_refs)

  # Map each reference to authority info
  mapped <- authority_data %>%
    rowwise() %>%
    mutate(
      auth_info = list(map_chapter99_to_authority(chapter99_ref, authority_map))
    ) %>%
    ungroup() %>%
    unnest_wider(auth_info, names_sep = '_') %>%
    select(-auth_info_chapter99_ref)  # Duplicate column

  # Rename columns (unnest adds prefix)
  mapped <- mapped %>%
    rename(
      authority = auth_info_authority,
      sub_authority = auth_info_sub_authority,
      description = auth_info_description,
      rate = auth_info_rate,
      countries = auth_info_countries,
      effective_date = auth_info_effective_date,
      proclamation = auth_info_proclamation,
      notes = auth_info_notes
    )

  # Summary
  n_unmapped <- sum(mapped$authority == 'unmapped')
  if (n_unmapped > 0) {
    warning(n_unmapped, ' Chapter 99 references are unmapped')
  }

  auth_summary <- mapped %>%
    count(authority, sub_authority, sort = TRUE)

  message('\n=== Authority Summary ===')
  print(auth_summary, n = 30)

  return(mapped)
}


#' Get list of unmapped Chapter 99 subheadings
#'
#' @param authority_data Tibble from extract_authorities
#' @return Tibble with unmapped subheadings and their product counts
get_unmapped_subheadings <- function(authority_data) {
  authority_data %>%
    filter(authority == 'unmapped') %>%
    count(chapter99_ref, sort = TRUE)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  setwd('C:/Users/ji252/Documents/GitHub/tariff_rate_tracker')

  # Load parsed HTS data
  hts_data <- readRDS('data/processed/hts_parsed.rds')

  # Extract authorities
  authority_data <- extract_authorities(hts_data)

  # Check for unmapped
  unmapped <- get_unmapped_subheadings(authority_data)
  if (nrow(unmapped) > 0) {
    cat('\n=== Unmapped Chapter 99 Subheadings ===\n')
    print(unmapped)
    cat('\nAdd these to config/authority_mapping.yaml\n')
  }

  # Save
  ensure_dir('data/processed')
  saveRDS(authority_data, 'data/processed/authority_data.rds')
  message('\nSaved authority data to data/processed/authority_data.rds')
}
