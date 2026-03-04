# DEPRECATED: Use src/00_build_timeseries.R instead.
# This script is retained for backward compatibility.
# See CLAUDE.md for updated usage.
#
# =============================================================================
# Tariff Rate Tracker v2 - Single-Revision Pipeline
# =============================================================================
#
# Orchestrates the full tariff rate calculation for a single HTS revision:
#   0. Download missing HTS JSON (if needed)
#   1. Parse Chapter 99 entries (rates and country applicability)
#   2. Parse products (base rates and Ch99 footnote references)
#   3. Extract policy parameters (IEEPA reciprocal, fentanyl, 232, USMCA)
#   4. Calculate total rates by HTS10 x country (including blanket tariffs)
#   5. Validate against TPC data
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
library(jsonlite)
library(here)

# Source pipeline components
source(here('src', 'helpers.R'))
source(here('src', '01_scrape_revision_dates.R'))
source(here('src', '02_download_hts.R'))
source(here('src', '04_parse_chapter99.R'))
source(here('src', '05_parse_products.R'))
source(here('src', '06_parse_policy_params.R'))
source(here('src', '07_calculate_rates.R'))
source(here('src', '08_validate_tpc.R'))

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
  revision_dates_file = 'config/revision_dates.csv',

  # Default revision
  default_revision = 'rev_32',
  baseline_revision = 'basic'
)


# =============================================================================
# Main Pipeline
# =============================================================================

run_full_pipeline <- function(revision = NULL, skip_parse = FALSE, skip_validate = FALSE,
                              stacking_method = 'mutual_exclusion') {
  start_time <- Sys.time()

  config <- CONFIG

  # Default revision
  if (is.null(revision)) revision <- config$default_revision

  message('\n', strrep('=', 60))
  message('TARIFF RATE TRACKER v2 - Pipeline')
  message(strrep('=', 60))
  message('Revision: ', revision)
  message('Started: ', start_time)
  message(strrep('=', 60), '\n')

  # Ensure directories exist
  ensure_dir(config$processed_dir)
  ensure_dir(config$output_dir)
  ensure_dir(file.path(config$output_dir, 'validation'))

  # ---- Load shared resources ----
  census_codes <- read_csv(config$census_codes_file, col_types = cols(.default = col_character()))
  countries <- census_codes$Code
  country_lookup <- build_country_lookup(config$census_codes_file)
  rev_dates <- load_revision_dates(config$revision_dates_file)

  rev_info <- rev_dates %>% filter(revision == !!revision)
  if (nrow(rev_info) == 0) {
    stop('Revision not found in revision_dates.csv: ', revision)
  }
  eff_date <- rev_info$effective_date
  tpc_date <- rev_info$tpc_date

  message('Effective date: ', eff_date)
  message('Countries: ', length(countries))

  # ---- Step 0: Ensure JSON exists ----
  message('\n', strrep('=', 60))
  message('STEP 0: Check / Download HTS JSON')
  message(strrep('=', 60), '\n')

  download_missing_revisions(
    archive_dir = config$hts_archive_dir,
    revision_dates_path = config$revision_dates_file
  )

  # ---- Resolve JSON path ----
  json_path <- resolve_json_path(revision, config$hts_archive_dir)

  # ---- Step 1: Parse Chapter 99 ----
  if (skip_parse) {
    message('\nSkipping parse steps, loading cached data...')
    ch99_data <- readRDS(file.path(config$processed_dir, 'chapter99_rates.rds'))
    products <- readRDS(file.path(config$processed_dir, paste0('products_', revision, '.rds')))
    hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)
  } else {
    message('\n', strrep('=', 60))
    message('STEP 1: Parse Chapter 99 Entries')
    message(strrep('=', 60), '\n')

    ch99_data <- parse_chapter99(json_path)
    saveRDS(ch99_data, file.path(config$processed_dir, 'chapter99_rates.rds'))

    # Compare to baseline
    baseline_path <- file.path(config$hts_archive_dir,
                               paste0('hts_2025_', config$baseline_revision, '.json'))
    if (file.exists(baseline_path)) {
      ch99_baseline <- parse_chapter99(baseline_path)
      changes <- compare_chapter99(ch99_baseline, ch99_data)
      message('\nChanges from baseline: +', changes$n_added, ' entries, -',
              changes$n_removed, ', ', changes$n_rate_changes, ' rate changes')
    }

    # ---- Step 2: Parse Products ----
    message('\n', strrep('=', 60))
    message('STEP 2: Parse Product Data')
    message(strrep('=', 60), '\n')

    products <- parse_products(json_path)
    saveRDS(products, file.path(config$processed_dir, paste0('products_', revision, '.rds')))

    # Load raw JSON for policy parameter extraction
    message('\nLoading raw JSON for policy parameter extraction...')
    hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)
  }

  # ---- Step 3: Extract Policy Parameters ----
  message('\n', strrep('=', 60))
  message('STEP 3: Extract Policy Parameters')
  message(strrep('=', 60), '\n')

  ieepa_rates <- extract_ieepa_rates(hts_raw, country_lookup)
  fentanyl_rates <- extract_ieepa_fentanyl_rates(hts_raw, country_lookup)
  s232_rates <- extract_section232_rates(ch99_data)
  usmca <- extract_usmca_eligibility(hts_raw)

  # ---- Step 4: Calculate Rates ----
  message('\n', strrep('=', 60))
  message('STEP 4: Calculate Tariff Rates')
  message(strrep('=', 60), '\n')

  message('Calculating rates for ', length(countries), ' countries...')

  rates <- calculate_rates_for_revision(
    products, ch99_data, ieepa_rates, usmca,
    countries, revision, eff_date,
    s232_rates = s232_rates,
    fentanyl_rates = fentanyl_rates,
    stacking_method = stacking_method
  )

  # Save
  saveRDS(rates, file.path(config$processed_dir, 'rates_current.rds'))
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
    head(15) %>%
    print()

  # ---- Step 5: Validate Against TPC ----
  validation <- NULL
  if (!skip_validate && file.exists(config$tpc_data_file)) {
    message('\n', strrep('=', 60))
    message('STEP 5: Validate Against TPC')
    message(strrep('=', 60), '\n')

    validation <- run_validation(
      our_rates = rates,
      tpc_path = config$tpc_data_file,
      census_codes = census_codes,
      output_dir = file.path(config$output_dir, 'validation')
    )
  }

  # ---- Summary ----
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
  library(here)

  # Parse command line arguments
  args <- commandArgs(trailingOnly = TRUE)

  revision <- NULL
  skip_parse <- FALSE
  skip_validate <- FALSE
  stacking_method <- 'mutual_exclusion'

  for (i in seq_along(args)) {
    if (args[i] == '--revision' && i < length(args)) {
      revision <- args[i + 1]
    } else if (args[i] == '--skip-parse') {
      skip_parse <- TRUE
    } else if (args[i] == '--skip-validate') {
      skip_validate <- TRUE
    } else if (args[i] == '--tpc-stacking') {
      stacking_method <- 'tpc_additive'
    }
  }

  # Run pipeline
  result <- run_full_pipeline(
    revision = revision,
    skip_parse = skip_parse,
    skip_validate = skip_validate,
    stacking_method = stacking_method
  )
}
