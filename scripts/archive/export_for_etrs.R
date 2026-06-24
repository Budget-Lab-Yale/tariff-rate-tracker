# =============================================================================
# Export Tariff Snapshot for Tariff-ETRs
# =============================================================================
#
# Creates flat-file tariff snapshots from tariff-rate-tracker that can be
# consumed directly by Tariff-ETRs, bypassing its YAML config parsing.
#
# Workflow:
#   1. Specify a date → get_rates_at_date() produces hts10 × country snapshot
#   2. Optionally adjust rates (zero out authorities, scale rates, etc.)
#   3. Export as CSV in the format Tariff-ETRs expects
#
# Output: A single CSV per date with columns matching the tracker's rate schema,
# placed in a Tariff-ETRs config directory structure.
#
# =============================================================================

library(tidyverse)

# Source helpers if not already loaded
if (!exists('get_rates_at_date')) {
  source(here::here('src', 'helpers.R'))
}
if (!exists('apply_stacking_rules')) {
  source(here::here('src', 'helpers.R'))
}


# =============================================================================
# Snapshot Export
# =============================================================================

#' Export a tariff snapshot for Tariff-ETRs consumption
#'
#' Takes the full timeseries (or a pre-filtered snapshot), queries rates at a
#' given date, and writes a flat CSV that Tariff-ETRs can load directly.
#'
#' @param ts Rate timeseries (from readRDS('data/timeseries/rate_timeseries.rds'))
#' @param query_date Date to snapshot (character or Date)
#' @param output_dir Directory to write the snapshot CSV. If following Tariff-ETRs
#'   convention, this should be the date subfolder, e.g.,
#'   'config/scenarios/tracker_apr1/tariff_etrs/2026-04-01/'
#' @param policy_params Optional policy_params for post-interval adjustments
#'   (Section 122 expiry, Swiss framework, etc.)
#' @param filename Output filename (default: 'rates_snapshot.csv')
#'
#' @return The snapshot tibble (invisibly), also writes CSV to disk
export_snapshot_for_etrs <- function(ts,
                                     query_date,
                                     output_dir,
                                     policy_params = NULL,
                                     filename = 'rates_snapshot.csv') {

  query_date <- as.Date(query_date)
  message(sprintf('Creating ETRs snapshot for %s...', query_date))

  # Get point-in-time snapshot

  snapshot <- get_rates_at_date(ts, query_date, policy_params)
  message(sprintf('  %s hts10 x country pairs', format(nrow(snapshot), big.mark = ',')))

  # Select columns needed by Tariff-ETRs
  export_cols <- c(
    'hts10', 'country',
    'base_rate', 'rate_232', 'rate_301',
    'rate_ieepa_recip', 'rate_ieepa_fent',
    'rate_s122', 'rate_section_201', 'rate_other',
    'metal_share', 'usmca_eligible',
    'total_additional', 'total_rate'
  )

  # Verify all columns exist
  missing <- setdiff(export_cols, names(snapshot))
  if (length(missing) > 0) {
    stop('Snapshot missing required columns: ', paste(missing, collapse = ', '))
  }

  # any_of('rate_s301fl'): the forced-labor §301 column is scenario-scoped (present
  # only when that authority is live), so surface it when there, omit it otherwise.
  # total_rate already includes its contribution either way.
  export <- snapshot %>%
    select(all_of(export_cols), any_of('rate_s301fl'), any_of('rate_s301br'))

  # Write
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  out_path <- file.path(output_dir, filename)
  write_csv(export, out_path)
  message(sprintf('  Written to %s (%s rows)',
                  out_path, format(nrow(export), big.mark = ',')))

  invisible(export)
}


# =============================================================================
# Scenario Adjustments
# =============================================================================

#' Adjust a snapshot by modifying authority rates
#'
#' Takes a snapshot tibble and applies modifications, then re-applies stacking
#' rules. Modifications are specified as a named list where names are authority
#' columns and values are either:
#'   - A single number: set that authority to this rate for all rows
#'   - 0: zero out that authority entirely
#'   - A function: applied to the existing rate column (e.g., \(x) x * 1.5)
#'   - A tibble with (hts10, country, rate) for product×country-specific overrides
#'
#' @param snapshot Tibble from export_snapshot_for_etrs() or get_rates_at_date()
#' @param adjustments Named list of adjustments (see details)
#' @return Adjusted snapshot with stacking rules re-applied
#'
#' @examples
#' # Drop all IEEPA reciprocal
#' adjust_snapshot(snap, list(rate_ieepa_recip = 0))
#'
#' # Increase Section 122 by 5pp
#' adjust_snapshot(snap, list(rate_s122 = \(x) x + 0.05))
#'
#' # Set 232 to flat 25% where it's currently nonzero
#' adjust_snapshot(snap, list(rate_232 = \(x) if_else(x > 0, 0.25, 0)))
adjust_snapshot <- function(snapshot, adjustments) {

  valid_cols <- c('rate_232', 'rate_301', 'rate_ieepa_recip', 'rate_ieepa_fent',
                  'rate_s122', 'rate_section_201', 'rate_other')

  for (col_name in names(adjustments)) {
    if (!col_name %in% valid_cols) {
      stop('Unknown authority column: ', col_name,
           '\nValid: ', paste(valid_cols, collapse = ', '))
    }

    adj <- adjustments[[col_name]]

    if (is.function(adj)) {
      snapshot[[col_name]] <- adj(snapshot[[col_name]])
    } else if (is.data.frame(adj)) {
      # Product×country specific overrides
      override <- adj %>%
        select(hts10, country, .override_rate = rate)
      snapshot <- snapshot %>%
        left_join(override, by = c('hts10', 'country')) %>%
        mutate(
          !!col_name := if_else(!is.na(.override_rate), .override_rate, !!sym(col_name))
        ) %>%
        select(-.override_rate)
    } else if (is.numeric(adj) && length(adj) == 1) {
      snapshot[[col_name]] <- adj
    } else {
      stop('Adjustment for ', col_name, ' must be a number, function, or tibble')
    }
  }

  # Re-apply stacking rules
  snapshot <- apply_stacking_rules(snapshot)

  return(snapshot)
}


# =============================================================================
# Convenience: Full Export Pipeline
# =============================================================================

#' Create a complete Tariff-ETRs scenario from a tracker snapshot
#'
#' Generates the config directory structure that Tariff-ETRs/Tariff-Model
#' expects, with a flat rates CSV and a minimal other_params.yaml.
#'
#' @param ts Rate timeseries
#' @param query_date Date to snapshot
#' @param scenario_dir Top-level scenario directory (e.g.,
#'   '../Tariff-Model/config/scenarios/tracker_apr1')
#' @param adjustments Optional named list of rate adjustments (passed to adjust_snapshot)
#' @param policy_params Optional policy_params for post-interval adjustments
#' @param mfn_rates_path Path to MFN rates CSV (relative to Tariff-ETRs root)
#' @param mfn_exemption_shares_path Optional path to MFN exemption shares CSV
#'
#' @return The (possibly adjusted) snapshot tibble (invisibly)
create_etrs_scenario <- function(ts,
                                 query_date,
                                 scenario_dir,
                                 adjustments = NULL,
                                 policy_params = NULL,
                                 mfn_rates_path = 'resources/mfn_rates_2025.csv',
                                 mfn_exemption_shares_path = NULL) {

  query_date <- as.Date(query_date)
  date_str <- format(query_date, '%Y-%m-%d')

  # Build output path: scenario_dir/tariff_etrs/{date}/
  etrs_dir <- file.path(scenario_dir, 'tariff_etrs', date_str)

  # Get snapshot
  snapshot <- get_rates_at_date(ts, query_date, policy_params)

  # Apply adjustments if any
  if (!is.null(adjustments)) {
    message('Applying adjustments...')
    snapshot <- adjust_snapshot(snapshot, adjustments)
  }

  # Write snapshot CSV
  export_cols <- c(
    'hts10', 'country',
    'base_rate', 'rate_232', 'rate_301',
    'rate_ieepa_recip', 'rate_ieepa_fent',
    'rate_s122', 'rate_section_201', 'rate_other',
    'metal_share', 'usmca_eligible',
    'total_additional', 'total_rate'
  )
  dir.create(etrs_dir, recursive = TRUE, showWarnings = FALSE)
  out_path <- file.path(etrs_dir, 'rates_snapshot.csv')
  write_csv(snapshot %>% select(all_of(export_cols)), out_path)
  message(sprintf('  Snapshot: %s (%s rows)',
                  out_path, format(nrow(snapshot), big.mark = ',')))

  # Write minimal other_params.yaml
  other_params <- list(mfn_rates = mfn_rates_path)
  if (!is.null(mfn_exemption_shares_path)) {
    other_params$mfn_exemption_shares <- mfn_exemption_shares_path
  }
  yaml::write_yaml(other_params, file.path(etrs_dir, 'other_params.yaml'))

  message(sprintf('Scenario created at %s', etrs_dir))
  invisible(snapshot)
}
