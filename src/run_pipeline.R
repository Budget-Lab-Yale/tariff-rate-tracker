# =============================================================================
# Tariff Rate Tracker v2 - Main Pipeline
# =============================================================================
#
# Orchestrates the full tariff rate calculation and validation pipeline:
#   1. Parse Chapter 99 entries (rates and country applicability)
#   2. Parse products (base rates and Ch99 footnote references)
#   3. Calculate total rates by HTS10 × country
#   4. Validate against TPC data
#
# Usage:
#   Rscript src/run_pipeline.R [options]
#
# Options:
#   --revision REV   HTS revision to process (default: rev_32)
#   --skip-parse     Skip parsing steps, use cached data
#   --skip-validate  Skip TPC validation
#
# =============================================================================

library(tidyverse)

# =============================================================================
# Pipeline Configuration
# =============================================================================

CONFIG <- list(
  # Directories
  hts_archive_dir = 'data/hts_archives',
  processed_dir = 'data/processed',
  output_dir = 'output',

  # Files
  census_codes_file = 'resources/census_codes.csv',
  tpc_data_file = 'data/tpc/tariff_by_flow_day.csv',

  # Default revision
  default_revision = 'rev_32',
  baseline_revision = 'basic'
)


# =============================================================================
# Pipeline Steps
# =============================================================================

#' Run Step 1: Parse Chapter 99
run_step1_parse_chapter99 <- function(revision, config) {
  message('\n' , strrep('=', 60))
  message('STEP 1: Parse Chapter 99 Entries')
  message(strrep('=', 60), '\n')

  source('src/01_parse_chapter99.R', local = TRUE)

  json_path <- file.path(config$hts_archive_dir, paste0('hts_2025_', revision, '.json'))

  ch99_data <- parse_chapter99(json_path)

  # Save
  output_path <- file.path(config$processed_dir, 'chapter99_rates.rds')
  saveRDS(ch99_data, output_path)
  message('\nSaved: ', output_path)

  # Also parse baseline for comparison
  baseline_path <- file.path(config$hts_archive_dir, paste0('hts_2025_', config$baseline_revision, '.json'))
  if (file.exists(baseline_path)) {
    ch99_baseline <- parse_chapter99(baseline_path)
    saveRDS(ch99_baseline, file.path(config$processed_dir, 'chapter99_rates_baseline.rds'))

    # Report changes
    changes <- compare_chapter99(ch99_baseline, ch99_data)
    message('\nChanges from baseline:')
    message('  Added entries: ', changes$n_added)
    message('  Removed entries: ', changes$n_removed)
    message('  Rate changes: ', changes$n_rate_changes)
  }

  return(ch99_data)
}


#' Run Step 2: Parse Products
run_step2_parse_products <- function(revision, config) {
  message('\n', strrep('=', 60))
  message('STEP 2: Parse Product Data')
  message(strrep('=', 60), '\n')

  source('src/02_parse_products.R', local = TRUE)

  json_path <- file.path(config$hts_archive_dir, paste0('hts_2025_', revision, '.json'))
  products <- parse_products(json_path)

  # Save
  output_path <- file.path(config$processed_dir, paste0('products_', revision, '.rds'))
  saveRDS(products, output_path)
  message('\nSaved: ', output_path)

  # Also parse baseline
  baseline_path <- file.path(config$hts_archive_dir, paste0('hts_2025_', config$baseline_revision, '.json'))
  if (file.exists(baseline_path)) {
    products_baseline <- parse_products(baseline_path)
    saveRDS(products_baseline, file.path(config$processed_dir, 'products_baseline.rds'))

    # Report changes
    changes <- compare_products(products_baseline, products)
    message('\nChanges from baseline:')
    message('  Added products: ', changes$n_added)
    message('  Removed products: ', changes$n_removed)
    message('  Ch99 ref changes: ', changes$n_ref_changes)
  }

  return(products)
}


#' Run Step 3: Calculate Rates
run_step3_calculate_rates <- function(products, ch99_data, config) {
  message('\n', strrep('=', 60))
  message('STEP 3: Calculate Tariff Rates')
  message(strrep('=', 60), '\n')

  source('src/03_calculate_rates.R', local = TRUE)

  # Load country codes
  census_codes <- read_csv(config$census_codes_file, col_types = cols(.default = col_character()))
  countries <- census_codes$Code

  message('Calculating rates for ', length(countries), ' countries...')

  rates <- calculate_rates_fast(products, ch99_data, countries)

  # Save
  output_path <- file.path(config$processed_dir, 'rates_current.rds')
  saveRDS(rates, output_path)
  message('\nSaved: ', output_path)

  # Also save CSV
  write_csv(rates, file.path(config$processed_dir, 'rates_current.csv'))

  # Summary
  message('\n=== Rate Summary ===')
  message('Product-country pairs with duties: ', nrow(rates))

  rates %>%
    group_by(country) %>%
    summarise(
      n = n(),
      mean_additional = round(mean(total_additional) * 100, 1),
      .groups = 'drop'
    ) %>%
    filter(n > 100) %>%
    arrange(desc(mean_additional)) %>%
    head(10) %>%
    print()

  return(rates)
}


#' Run Step 4: Validate Against TPC
run_step4_validate <- function(rates, config) {
  message('\n', strrep('=', 60))
  message('STEP 4: Validate Against TPC')
  message(strrep('=', 60), '\n')

  source('src/04_validate_tpc.R', local = TRUE)

  census_codes <- read_csv(config$census_codes_file, col_types = cols(.default = col_character()))

  validation <- run_validation(
    our_rates = rates,
    tpc_path = config$tpc_data_file,
    census_codes = census_codes,
    output_dir = file.path(config$output_dir, 'validation')
  )

  return(validation)
}


# =============================================================================
# Main Pipeline
# =============================================================================

run_full_pipeline <- function(revision = NULL, skip_parse = FALSE, skip_validate = FALSE) {
  start_time <- Sys.time()

  message('\n', strrep('=', 60))
  message('TARIFF RATE TRACKER v2 - Pipeline')
  message(strrep('=', 60))
  message('Started: ', start_time)
  message(strrep('=', 60), '\n')

  config <- CONFIG

  # Default revision
  if (is.null(revision)) revision <- config$default_revision

  # Ensure directories exist
  if (!dir.exists(config$processed_dir)) dir.create(config$processed_dir, recursive = TRUE)
  if (!dir.exists(config$output_dir)) dir.create(config$output_dir, recursive = TRUE)

  # Step 1 & 2: Parse data (or load cached)
  if (skip_parse) {
    message('Skipping parse steps, loading cached data...')
    ch99_data <- readRDS(file.path(config$processed_dir, 'chapter99_rates.rds'))
    products <- readRDS(file.path(config$processed_dir, paste0('products_', revision, '.rds')))
  } else {
    ch99_data <- run_step1_parse_chapter99(revision, config)
    products <- run_step2_parse_products(revision, config)
  }

  # Step 3: Calculate rates
  rates <- run_step3_calculate_rates(products, ch99_data, config)

  # Step 4: Validate (optional)
  validation <- NULL
  if (!skip_validate && file.exists(config$tpc_data_file)) {
    validation <- run_step4_validate(rates, config)
  }

  # Summary
  end_time <- Sys.time()
  elapsed <- round(difftime(end_time, start_time, units = 'mins'), 1)

  message('\n', strrep('=', 60))
  message('PIPELINE COMPLETE')
  message(strrep('=', 60))
  message('Elapsed time: ', elapsed, ' minutes')
  message('Products parsed: ', nrow(products))
  message('Product-country rates: ', nrow(rates))
  message(strrep('=', 60), '\n')

  return(list(
    ch99_data = ch99_data,
    products = products,
    rates = rates,
    validation = validation
  ))
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  setwd('C:/Users/ji252/Documents/GitHub/tariff_rate_tracker')

  # Parse command line arguments
  args <- commandArgs(trailingOnly = TRUE)

  revision <- NULL
  skip_parse <- FALSE
  skip_validate <- FALSE

  for (i in seq_along(args)) {
    if (args[i] == '--revision' && i < length(args)) {
      revision <- args[i + 1]
    } else if (args[i] == '--skip-parse') {
      skip_parse <- TRUE
    } else if (args[i] == '--skip-validate') {
      skip_validate <- TRUE
    }
  }

  # Run pipeline
  result <- run_full_pipeline(
    revision = revision,
    skip_parse = skip_parse,
    skip_validate = skip_validate
  )
}
