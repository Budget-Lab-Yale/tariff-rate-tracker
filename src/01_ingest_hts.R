# =============================================================================
# Step 01: Ingest HTS JSON Archive
# =============================================================================
#
# This script reads HTS JSON files and produces a clean tibble with:
#   - htsno: 10-digit HTS code (normalized, no periods)
#   - description: Product description
#   - general_rate: Parsed MFN rate (numeric)
#   - general_rate_raw: Original rate string
#   - special_rate: Parsed special rate (numeric)
#   - special_programs: List of FTA program codes
#   - col2_rate: Column 2 rate (numeric)
#   - chapter99_refs: List of Chapter 99 references from footnotes
#   - indent: Hierarchy level
#   - has_complex_rate: Flag for non-ad-valorem rates
#
# =============================================================================

source('src/helpers.R')

# =============================================================================
# Main Ingestion Function
# =============================================================================

#' Ingest HTS JSON archive into a clean tibble
#'
#' @param json_path Path to HTS JSON file
#' @return Tibble with parsed HTS data
ingest_hts_json <- function(json_path) {
  message('Reading HTS JSON from: ', json_path)

  # Read JSON
  hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)

  message('Found ', length(hts_raw), ' items in HTS archive')

  # Process each item
  hts_list <- map(hts_raw, function(item) {
    # Normalize HTS code
    htsno <- normalize_hts(item$htsno)

    # Skip header rows (no HTS code or just chapter headers)
    if (is.na(htsno) || nchar(gsub('0', '', htsno)) == 0) {
      return(NULL)
    }

    # Parse general rate
    general_raw <- item$general %||% ''
    general_rate <- parse_rate(general_raw)

    # Parse special column
    special_raw <- item$special %||% ''
    special_parsed <- parse_special_programs(special_raw)

    # Parse Column 2 rate
    col2_raw <- item$other %||% ''
    col2_rate <- parse_rate(col2_raw)

    # Extract Chapter 99 references from footnotes
    ch99_refs <- extract_chapter99_refs(item$footnotes)

    # Flag for complex rates
    has_complex <- !is_simple_rate(general_raw) && general_raw != ''

    tibble(
      htsno = htsno,
      description = item$description %||% '',
      general_rate = general_rate,
      general_rate_raw = general_raw,
      special_rate = special_parsed$rate,
      special_programs = list(special_parsed$programs),
      col2_rate = col2_rate,
      chapter99_refs = list(ch99_refs),
      indent = as.integer(item$indent %||% 0),
      has_complex_rate = has_complex
    )
  })

  # Combine into tibble, removing NULLs
  hts_data <- bind_rows(compact(hts_list))

  message('Processed ', nrow(hts_data), ' tariff lines with valid HTS codes')

  # Summary stats
  n_complex <- sum(hts_data$has_complex_rate)
  n_ch99 <- sum(map_int(hts_data$chapter99_refs, length) > 0)

  message('  - ', n_complex, ' lines have complex (non-ad-valorem) rates')
  message('  - ', n_ch99, ' lines have Chapter 99 references')

  return(hts_data)
}


# =============================================================================
# Rate Summary Functions
# =============================================================================

#' Summarize rate distribution
#'
#' @param hts_data Tibble from ingest_hts_json
#' @return Tibble with rate statistics
summarize_rates <- function(hts_data) {
  hts_data %>%
    filter(!is.na(general_rate)) %>%
    summarise(
      n_lines = n(),
      min_rate = min(general_rate),
      max_rate = max(general_rate),
      mean_rate = mean(general_rate),
      median_rate = median(general_rate),
      n_free = sum(general_rate == 0),
      pct_free = mean(general_rate == 0) * 100
    )
}

#' List all Chapter 99 references found
#'
#' @param hts_data Tibble from ingest_hts_json
#' @return Tibble with chapter99_ref and count
list_chapter99_refs <- function(hts_data) {
  hts_data %>%
    unnest(chapter99_refs) %>%
    filter(!is.na(chapter99_refs)) %>%
    count(chapter99_refs, sort = TRUE) %>%
    rename(ch99_subheading = chapter99_refs, n_products = n)
}


# =============================================================================
# Main Execution (when run directly)
# =============================================================================

if (sys.nframe() == 0) {
  # Set working directory to project root
  setwd('C:/Users/ji252/Documents/GitHub/tariff_rate_tracker')

  # Get latest HTS archive
  hts_file <- get_latest_hts_archive('2026')  # Use 2026 since we have that

  # Ingest
  hts_data <- ingest_hts_json(hts_file)

  # Print summary
  cat('\n=== Rate Summary ===\n')
  print(summarize_rates(hts_data))

  cat('\n=== Chapter 99 References ===\n')
  ch99_summary <- list_chapter99_refs(hts_data)
  print(head(ch99_summary, 20))

  # Save processed data
  ensure_dir('data/processed')
  saveRDS(hts_data, 'data/processed/hts_parsed.rds')
  message('\nSaved parsed HTS data to data/processed/hts_parsed.rds')
}
