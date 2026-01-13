# =============================================================================
# Tariff Rate Tracker - Daily Run Orchestrator
# =============================================================================
#
# Main entry point for running the tariff rate tracker pipeline.
# Executes all steps in sequence:
#   1. Ingest HTS JSON archive
#   2. Extract authority mappings from Chapter 99 references
#   3. Expand to country dimension
#   4. Calculate effective rates with stacking
#   5. Generate outputs (snapshots, exports)
#
# Usage:
#   Rscript src/run_daily.R [options]
#
# Options:
#   --year YYYY       HTS year to process (default: current year)
#   --date YYYY-MM-DD Snapshot date (default: today)
#   --skip-download   Skip HTS download, use cached file
#
# =============================================================================

# Load helpers
source('src/helpers.R')

# Source processing scripts (functions only, not main execution)
# We'll call their functions directly

# =============================================================================
# Pipeline Functions
# =============================================================================

#' Run the complete tariff rate tracker pipeline
#'
#' @param hts_year Year for HTS data
#' @param snapshot_date Date for snapshot output
#' @param download_hts Whether to attempt HTS download
#' @return List with paths to outputs
run_pipeline <- function(hts_year = format(Sys.Date(), '%Y'),
                         snapshot_date = Sys.Date(),
                         download_hts = FALSE) {

  message('\n')
  message('============================================================')
  message('  TARIFF RATE TRACKER - Daily Pipeline')
  message('============================================================')
  message('  HTS Year:      ', hts_year)
  message('  Snapshot Date: ', snapshot_date)
  message('============================================================')
  message('\n')

  start_time <- Sys.time()

  # --------------------------------------------------------------------------
  # Step 1: Ingest HTS
  # --------------------------------------------------------------------------
  message('=== Step 1: Ingest HTS Data ===')

  # Source the ingest script to get functions
  source('src/01_ingest_hts.R', local = TRUE)

  # Get HTS archive
  hts_file <- tryCatch(
    get_latest_hts_archive(hts_year),
    error = function(e) {
      message('No HTS archive found for ', hts_year, ', trying previous year...')
      get_latest_hts_archive(as.character(as.integer(hts_year) - 1))
    }
  )

  hts_data <- ingest_hts_json(hts_file)
  saveRDS(hts_data, 'data/processed/hts_parsed.rds')

  # --------------------------------------------------------------------------
  # Step 2: Extract Authorities
  # --------------------------------------------------------------------------
  message('\n=== Step 2: Extract Authorities ===')

  source('src/02_extract_authorities.R', local = TRUE)
  authority_data <- extract_authorities(hts_data)
  saveRDS(authority_data, 'data/processed/authority_data.rds')

  # --------------------------------------------------------------------------
  # Step 3: Expand to Countries
  # --------------------------------------------------------------------------
  message('\n=== Step 3: Expand to Countries ===')

  source('src/03_expand_countries.R', local = TRUE)
  expanded_data <- expand_to_countries(authority_data)
  saveRDS(expanded_data, 'data/processed/expanded_data.rds')

  # --------------------------------------------------------------------------
  # Step 4: Calculate Rates
  # --------------------------------------------------------------------------
  message('\n=== Step 4: Calculate Effective Rates ===')

  source('src/04_calculate_rates.R', local = TRUE)
  rate_data <- calculate_effective_rates(hts_data, expanded_data)
  saveRDS(rate_data, 'data/processed/rate_data.rds')

  # --------------------------------------------------------------------------
  # Step 5: Write Outputs
  # --------------------------------------------------------------------------
  message('\n=== Step 5: Write Outputs ===')

  source('src/05_write_outputs.R', local = TRUE)

  hts_revision <- paste('HTS', hts_year, 'Basic Edition')
  snapshot_dir <- write_snapshot(rate_data, hts_data, snapshot_date, hts_revision)

  # Check for previous snapshot and detect changes
  previous_snapshots <- list.dirs('snapshots', recursive = FALSE)
  previous_snapshots <- previous_snapshots[previous_snapshots != paste0('snapshots/', snapshot_date)]

  if (length(previous_snapshots) > 0) {
    prev_dir <- sort(previous_snapshots, decreasing = TRUE)[1]
    prev_csv <- file.path(prev_dir, 'tariff_rates.csv')
    if (file.exists(prev_csv)) {
      previous_data <- read_csv(prev_csv, col_types = cols(.default = col_guess()))
      changes <- detect_changes(rate_data, previous_data, snapshot_date)
      write_change_log(changes, snapshot_date)
    }
  }

  export_dir <- write_tariff_model_export(rate_data, authority_data, snapshot_date)

  # --------------------------------------------------------------------------
  # Summary
  # --------------------------------------------------------------------------
  end_time <- Sys.time()
  elapsed <- round(difftime(end_time, start_time, units = 'secs'), 1)

  message('\n')
  message('============================================================')
  message('  PIPELINE COMPLETE')
  message('============================================================')
  message('  Elapsed time:    ', elapsed, ' seconds')
  message('  Products:        ', length(unique(rate_data$htsno)))
  message('  Countries:       ', length(unique(rate_data$cty_code)))
  message('  Snapshot:        ', snapshot_dir)
  message('  Export:          ', export_dir)
  message('============================================================')
  message('\n')

  return(list(
    snapshot_dir = snapshot_dir,
    export_dir = export_dir,
    n_products = length(unique(rate_data$htsno)),
    elapsed_seconds = as.numeric(elapsed)
  ))
}


# =============================================================================
# Key Statistics
# =============================================================================

#' Print key statistics from the latest snapshot
#'
#' @param rate_data Rate data tibble (optional, loads from file if not provided)
print_key_stats <- function(rate_data = NULL) {
  if (is.null(rate_data)) {
    rate_data <- readRDS('data/processed/rate_data.rds')
  }

  cat('\n')
  cat('============================================================\n')
  cat('  KEY TARIFF STATISTICS\n')
  cat('============================================================\n')

  # Overall stats
  overall <- rate_data %>%
    summarise(
      n_products = n_distinct(htsno),
      n_countries = n_distinct(cty_code),
      n_product_country = n(),
      mean_base = mean(base_rate, na.rm = TRUE),
      mean_additional = mean(total_additional, na.rm = TRUE),
      mean_total = mean(total_rate, na.rm = TRUE)
    )

  cat('\n  Overall:\n')
  cat('    Products:              ', overall$n_products, '\n')
  cat('    Countries:             ', overall$n_countries, '\n')
  cat('    Product-Country pairs: ', overall$n_product_country, '\n')
  cat('    Mean base rate:        ', round(overall$mean_base * 100, 2), '%\n')
  cat('    Mean additional:       ', round(overall$mean_additional * 100, 2), '%\n')
  cat('    Mean total rate:       ', round(overall$mean_total * 100, 2), '%\n')

  # Top countries by additional duties
  cat('\n  Top Countries by Additional Duties:\n')
  top_countries <- rate_data %>%
    group_by(cty_code) %>%
    summarise(
      n_with_duties = sum(total_additional > 0),
      mean_additional = mean(total_additional, na.rm = TRUE),
      .groups = 'drop'
    ) %>%
    filter(n_with_duties > 0) %>%
    arrange(desc(mean_additional)) %>%
    head(10)

  # Get country names
  census <- load_census_codes()

  top_countries <- top_countries %>%
    left_join(census, by = c('cty_code' = 'Code'))

  for (i in 1:nrow(top_countries)) {
    cat('    ', top_countries$Name[i], ' (',
        top_countries$cty_code[i], '): ',
        round(top_countries$mean_additional[i] * 100, 2), '% avg, ',
        top_countries$n_with_duties[i], ' products\n', sep = '')
  }

  cat('\n============================================================\n')
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  # Set working directory
  setwd('C:/Users/ji252/Documents/GitHub/tariff_rate_tracker')

  # Parse command line arguments
  args <- commandArgs(trailingOnly = TRUE)

  hts_year <- format(Sys.Date(), '%Y')
  snapshot_date <- Sys.Date()

  for (i in seq_along(args)) {
    if (args[i] == '--year' && i < length(args)) {
      hts_year <- args[i + 1]
    } else if (args[i] == '--date' && i < length(args)) {
      snapshot_date <- as.Date(args[i + 1])
    }
  }

  # Run pipeline
  result <- run_pipeline(
    hts_year = hts_year,
    snapshot_date = snapshot_date
  )

  # Print statistics
  print_key_stats()
}
