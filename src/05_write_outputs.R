# =============================================================================
# Step 05: Write Outputs
# =============================================================================
#
# This script generates output files:
#   1. Daily snapshot YAML (snapshots/{date}/tariff_rates.yaml)
#   2. Change log (changes/{date}.yaml) - comparing to previous snapshot
#   3. Tariff-Model compatible exports (exports/{date}/)
#
# =============================================================================

source('src/helpers.R')

# =============================================================================
# Snapshot Generation
# =============================================================================

#' Generate daily snapshot YAML
#'
#' Creates a YAML file with tariff rates organized by authority
#'
#' @param rate_data Tibble from calculate_effective_rates
#' @param hts_data Original HTS data for metadata
#' @param snapshot_date Date for snapshot (default: today)
#' @param hts_revision HTS revision name for metadata
write_snapshot <- function(rate_data, hts_data, snapshot_date = Sys.Date(),
                           hts_revision = 'unknown') {
  message('Generating snapshot for ', snapshot_date, '...')

  # Create output directory
  snapshot_dir <- ensure_dir(paste0('snapshots/', snapshot_date))

  # Build snapshot structure
  snapshot <- list(
    metadata = list(
      snapshot_date = as.character(snapshot_date),
      hts_revision = hts_revision,
      generated_at = as.character(Sys.time()),
      n_products = length(unique(rate_data$htsno)),
      n_countries = length(unique(rate_data$cty_code))
    ),

    summary = list(
      by_country = rate_data %>%
        group_by(cty_code) %>%
        summarise(
          n_products = n(),
          mean_total_rate = round(mean(total_rate, na.rm = TRUE), 4),
          mean_additional = round(mean(total_additional, na.rm = TRUE), 4),
          n_with_duties = sum(total_additional > 0),
          .groups = 'drop'
        ) %>%
        filter(n_with_duties > 0) %>%
        arrange(desc(mean_additional)) %>%
        head(20) %>%
        as.list()
    )
  )

  # Write YAML
  yaml_path <- file.path(snapshot_dir, 'tariff_rates.yaml')
  write_yaml(snapshot, yaml_path)
  message('  Wrote snapshot to ', yaml_path)

  # Also write detailed CSV for analysis
  csv_path <- file.path(snapshot_dir, 'tariff_rates.csv')
  write_csv(rate_data, csv_path)
  message('  Wrote detailed CSV to ', csv_path)

  return(snapshot_dir)
}


# =============================================================================
# Change Detection
# =============================================================================

#' Compare two snapshots and generate change log
#'
#' @param current_data Current rate data
#' @param previous_data Previous rate data (or NULL if first run)
#' @param current_date Date of current snapshot
#' @return List of changes
detect_changes <- function(current_data, previous_data, current_date) {
  if (is.null(previous_data)) {
    message('No previous snapshot - skipping change detection')
    return(NULL)
  }

  message('Detecting changes from previous snapshot...')

  # Join current and previous
  comparison <- current_data %>%
    select(htsno, cty_code, total_rate, total_additional) %>%
    rename(
      current_total = total_rate,
      current_additional = total_additional
    ) %>%
    full_join(
      previous_data %>%
        select(htsno, cty_code, total_rate, total_additional) %>%
        rename(
          previous_total = total_rate,
          previous_additional = total_additional
        ),
      by = c('htsno', 'cty_code')
    )

  # Find changes
  changes <- comparison %>%
    filter(
      # Rate changed
      abs(coalesce(current_total, 0) - coalesce(previous_total, 0)) > 0.0001 |
      # New product-country
      is.na(previous_total) |
      # Removed product-country
      is.na(current_total)
    ) %>%
    mutate(
      change_type = case_when(
        is.na(previous_total) ~ 'added',
        is.na(current_total) ~ 'removed',
        TRUE ~ 'rate_change'
      ),
      rate_delta = coalesce(current_total, 0) - coalesce(previous_total, 0)
    )

  n_changes <- nrow(changes)
  message('  Found ', n_changes, ' changes')

  if (n_changes > 0) {
    change_summary <- changes %>%
      count(change_type)
    message('  Change types:')
    for (i in 1:nrow(change_summary)) {
      message('    ', change_summary$change_type[i], ': ', change_summary$n[i])
    }
  }

  return(changes)
}

#' Write change log YAML
#'
#' @param changes Tibble from detect_changes
#' @param change_date Date of changes
write_change_log <- function(changes, change_date) {
  if (is.null(changes) || nrow(changes) == 0) {
    message('No changes to write')
    return(NULL)
  }

  ensure_dir('changes')

  change_log <- list(
    date = as.character(change_date),
    n_changes = nrow(changes),
    summary = list(
      added = sum(changes$change_type == 'added'),
      removed = sum(changes$change_type == 'removed'),
      rate_changes = sum(changes$change_type == 'rate_change')
    ),
    changes = changes %>%
      head(1000) %>%  # Limit for readability
      as.list()
  )

  yaml_path <- paste0('changes/', change_date, '.yaml')
  write_yaml(change_log, yaml_path)
  message('  Wrote change log to ', yaml_path)

  return(yaml_path)
}


# =============================================================================
# Tariff-Model Export
# =============================================================================

#' Export rates in Tariff-Model YAML format
#'
#' Creates YAML files compatible with Tariff-Model config structure
#'
#' @param rate_data Rate data tibble
#' @param authority_data Authority data with product lists
#' @param export_date Export date
write_tariff_model_export <- function(rate_data, authority_data, export_date = Sys.Date()) {
  message('Generating Tariff-Model compatible export...')

  export_dir <- ensure_dir(paste0('exports/', export_date))

  # Load country rules for reference
  country_rules <- yaml::read_yaml('config/country_rules.yaml')

  # --------------------------------------------------------------------------
  # Section 232 YAML
  # --------------------------------------------------------------------------

  # Get 232 products
  s232_products <- authority_data %>%
    filter(authority == 'section_232') %>%
    select(htsno, sub_authority, rate) %>%
    distinct()

  if (nrow(s232_products) > 0) {
    s232_yaml <- list()

    for (sub_auth in unique(s232_products$sub_authority)) {
      products <- s232_products %>%
        filter(sub_authority == sub_auth) %>%
        pull(htsno) %>%
        unique()

      rate <- s232_products %>%
        filter(sub_authority == sub_auth) %>%
        pull(rate) %>%
        max()

      s232_yaml[[sub_auth]] <- list(
        base = as.list(products),
        rates = list(default = rate),
        usmca_exempt = 1
      )
    }

    write_yaml(s232_yaml, file.path(export_dir, '232.yaml'))
    message('  Wrote 232.yaml')
  }

  # --------------------------------------------------------------------------
  # Section 301 YAML (China-specific)
  # --------------------------------------------------------------------------

  s301_products <- authority_data %>%
    filter(authority == 'section_301') %>%
    select(htsno, sub_authority, rate) %>%
    distinct()

  if (nrow(s301_products) > 0) {
    s301_yaml <- list()

    for (sub_auth in unique(s301_products$sub_authority)) {
      if (grepl('exclusion', sub_auth)) next  # Skip exclusions

      products <- s301_products %>%
        filter(sub_authority == sub_auth) %>%
        pull(htsno) %>%
        unique()

      rate <- s301_products %>%
        filter(sub_authority == sub_auth) %>%
        pull(rate) %>%
        max()

      s301_yaml[[sub_auth]] <- list(
        base = as.list(products),
        rates = list(
          default = 0,
          china = rate
        )
      )
    }

    write_yaml(s301_yaml, file.path(export_dir, '301.yaml'))
    message('  Wrote 301.yaml')
  }

  # --------------------------------------------------------------------------
  # IEEPA Reciprocal YAML
  # --------------------------------------------------------------------------

  ieepa_recip <- authority_data %>%
    filter(authority == 'ieepa', grepl('reciprocal', sub_authority)) %>%
    select(htsno, rate, countries) %>%
    distinct()

  if (nrow(ieepa_recip) > 0) {
    # Get baseline rate
    baseline_rate <- authority_data %>%
      filter(authority == 'ieepa', sub_authority == 'reciprocal_baseline') %>%
      pull(rate) %>%
      unique() %>%
      first()

    # Get China-specific rate
    china_rate <- authority_data %>%
      filter(authority == 'ieepa', sub_authority == 'reciprocal_china') %>%
      pull(rate) %>%
      unique() %>%
      first()

    ieepa_recip_yaml <- list(
      headline_rates = list(
        default = coalesce(baseline_rate, 0.10),
        china = coalesce(china_rate, 0.145)
      ),
      product_rates = list()  # Could add product-specific overrides
    )

    write_yaml(ieepa_recip_yaml, file.path(export_dir, 'ieepa_reciprocal.yaml'))
    message('  Wrote ieepa_reciprocal.yaml')
  }

  # --------------------------------------------------------------------------
  # IEEPA Fentanyl YAML
  # --------------------------------------------------------------------------

  ieepa_fent <- authority_data %>%
    filter(authority == 'ieepa', grepl('fentanyl', sub_authority)) %>%
    select(sub_authority, rate, countries) %>%
    distinct()

  if (nrow(ieepa_fent) > 0) {
    fent_rates <- list(default = 0)

    # China rate
    china_fent <- ieepa_fent %>%
      filter(sub_authority == 'fentanyl_china') %>%
      pull(rate) %>%
      first()
    if (!is.na(china_fent)) fent_rates$china <- china_fent

    # Canada/Mexico rate
    cm_fent <- ieepa_fent %>%
      filter(sub_authority == 'fentanyl_canada_mexico') %>%
      pull(rate) %>%
      first()
    if (!is.na(cm_fent)) {
      fent_rates$canada <- cm_fent
      fent_rates$mexico <- cm_fent
    }

    ieepa_fent_yaml <- list(
      headline_rates = fent_rates,
      product_rates = list()
    )

    write_yaml(ieepa_fent_yaml, file.path(export_dir, 'ieepa_fentanyl.yaml'))
    message('  Wrote ieepa_fentanyl.yaml')
  }

  # --------------------------------------------------------------------------
  # Other params YAML
  # --------------------------------------------------------------------------

  other_params_yaml <- list(
    usmca_auto_rebate = 0.025,
    notes = paste('Auto-generated from tariff_rate_tracker on', export_date)
  )

  write_yaml(other_params_yaml, file.path(export_dir, 'other_params.yaml'))
  message('  Wrote other_params.yaml')

  message('Export complete: ', export_dir)
  return(export_dir)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  setwd('C:/Users/ji252/Documents/GitHub/tariff_rate_tracker')

  # Load data
  rate_data <- readRDS('data/processed/rate_data.rds')
  authority_data <- readRDS('data/processed/authority_data.rds')
  hts_data <- readRDS('data/processed/hts_parsed.rds')

  snapshot_date <- Sys.Date()

  # Write snapshot
  snapshot_dir <- write_snapshot(
    rate_data,
    hts_data,
    snapshot_date = snapshot_date,
    hts_revision = 'HTS 2026 Basic Edition'
  )

  # Check for previous snapshot
  previous_snapshots <- list.dirs('snapshots', recursive = FALSE)
  previous_snapshots <- previous_snapshots[previous_snapshots != snapshot_dir]

  if (length(previous_snapshots) > 0) {
    # Load most recent previous
    prev_dir <- sort(previous_snapshots, decreasing = TRUE)[1]
    prev_csv <- file.path(prev_dir, 'tariff_rates.csv')
    if (file.exists(prev_csv)) {
      previous_data <- read_csv(prev_csv, col_types = cols(.default = col_guess()))
      changes <- detect_changes(rate_data, previous_data, snapshot_date)
      write_change_log(changes, snapshot_date)
    }
  }

  # Write Tariff-Model export
  export_dir <- write_tariff_model_export(rate_data, authority_data, snapshot_date)

  message('\n=== Output Complete ===')
  message('Snapshot: ', snapshot_dir)
  message('Export: ', export_dir)
}
