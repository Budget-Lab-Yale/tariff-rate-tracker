# =============================================================================
# Step 07: Apply Tariff Scenarios
# =============================================================================
#
# Zeros out disabled authorities and re-applies stacking rules to produce
# counterfactual rate estimates.
#
# Scenarios are defined in config/scenarios.yaml. Each scenario specifies
# which authorities to disable (e.g., no_ieepa removes IEEPA reciprocal
# and fentanyl).
#
# Works on any tibble with the standard rate schema — a single revision
# snapshot or the full time series.
#
# =============================================================================

library(tidyverse)
library(yaml)

# Country code constants (same as 03_calculate_rates.R)
CTY_CHINA <- '5700'

# Authority name to column mapping
AUTHORITY_COLUMNS <- c(
  'section_232'      = 'rate_232',
  'section_301'      = 'rate_301',
  'ieepa_reciprocal' = 'rate_ieepa_recip',
  'ieepa_fentanyl'   = 'rate_ieepa_fent',
  'other'            = 'rate_other'
)


# =============================================================================
# Scenario Functions
# =============================================================================

#' Load scenario definitions from YAML
#'
#' @param scenarios_path Path to scenarios.yaml
#' @return Named list of scenario definitions
load_scenarios <- function(scenarios_path = 'config/scenarios.yaml') {
  if (!file.exists(scenarios_path)) {
    stop('Scenarios config not found: ', scenarios_path)
  }

  scenarios <- read_yaml(scenarios_path)
  message('Loaded ', length(scenarios), ' scenarios from ', scenarios_path)

  return(scenarios)
}


#' Apply a scenario to a rates tibble
#'
#' Zeros out columns for disabled authorities, then re-applies stacking rules
#' to recompute total_additional and total_rate.
#'
#' @param rates Tibble with standard rate columns
#' @param scenario_name Name of scenario (must exist in scenarios YAML)
#' @param scenarios_path Path to scenarios.yaml
#' @return Rates tibble with scenario applied and 'scenario' column added
apply_scenario <- function(rates, scenario_name, scenarios_path = 'config/scenarios.yaml') {
  scenarios <- load_scenarios(scenarios_path)

  if (!scenario_name %in% names(scenarios)) {
    stop('Unknown scenario: ', scenario_name,
         '. Available: ', paste(names(scenarios), collapse = ', '))
  }

  scenario <- scenarios[[scenario_name]]
  disable <- scenario$disable %||% character(0)

  message('Applying scenario "', scenario_name, '": ', scenario$description)
  if (length(disable) > 0) {
    message('  Disabling: ', paste(disable, collapse = ', '))
  }

  # Validate authority names
  invalid <- setdiff(disable, names(AUTHORITY_COLUMNS))
  if (length(invalid) > 0) {
    stop('Unknown authorities in scenario: ', paste(invalid, collapse = ', '),
         '\nValid: ', paste(names(AUTHORITY_COLUMNS), collapse = ', '))
  }

  # Zero out disabled columns
  result <- rates
  for (auth in disable) {
    col <- AUTHORITY_COLUMNS[auth]
    if (col %in% names(result)) {
      result[[col]] <- 0
    }
  }

  # Re-apply stacking rules
  result <- result %>%
    mutate(
      total_additional = case_when(
        # China: max(232, reciprocal) + fentanyl + 301 + other
        country == CTY_CHINA ~
          pmax(rate_232, rate_ieepa_recip) + rate_ieepa_fent + rate_301 + rate_other,
        # Others with 232: 232 + other
        rate_232 > 0 ~ rate_232 + rate_other,
        # Others: reciprocal + fentanyl + other
        TRUE ~ rate_ieepa_recip + rate_ieepa_fent + rate_other
      ),
      total_rate = base_rate + total_additional,
      scenario = scenario_name
    )

  # Summary
  message('  Mean total rate: ', round(mean(result$total_rate) * 100, 2), '%')

  return(result)
}


#' Apply multiple scenarios and stack results
#'
#' @param rates Base rates tibble
#' @param scenario_names Vector of scenario names (or 'all' for all scenarios)
#' @param scenarios_path Path to scenarios.yaml
#' @return Combined tibble with all scenarios
apply_all_scenarios <- function(rates, scenario_names = 'all', scenarios_path = 'config/scenarios.yaml') {
  scenarios <- load_scenarios(scenarios_path)

  if (identical(scenario_names, 'all')) {
    scenario_names <- names(scenarios)
  }

  results <- map_dfr(scenario_names, function(name) {
    apply_scenario(rates, name, scenarios_path)
  })

  message('\nApplied ', length(scenario_names), ' scenarios')
  message('Total rows: ', nrow(results))

  return(results)
}


#' Compare two scenarios side by side
#'
#' @param rates Base rates tibble
#' @param scenario_a First scenario name
#' @param scenario_b Second scenario name
#' @param scenarios_path Path to scenarios.yaml
#' @return Tibble with difference metrics
compare_scenarios <- function(rates, scenario_a, scenario_b, scenarios_path = 'config/scenarios.yaml') {
  a <- apply_scenario(rates, scenario_a, scenarios_path)
  b <- apply_scenario(rates, scenario_b, scenarios_path)

  comparison <- a %>%
    select(hts10, country, revision, total_rate_a = total_rate) %>%
    inner_join(
      b %>% select(hts10, country, revision, total_rate_b = total_rate),
      by = c('hts10', 'country', 'revision')
    ) %>%
    mutate(
      diff = total_rate_a - total_rate_b,
      abs_diff = abs(diff)
    )

  message('\n=== Scenario Comparison: ', scenario_a, ' vs ', scenario_b, ' ===')
  message('Mean rate (', scenario_a, '): ', round(mean(comparison$total_rate_a) * 100, 2), '%')
  message('Mean rate (', scenario_b, '): ', round(mean(comparison$total_rate_b) * 100, 2), '%')
  message('Mean difference: ', round(mean(comparison$diff) * 100, 2), 'pp')
  message('Products affected: ', sum(comparison$abs_diff > 0.001))

  return(comparison)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  setwd('C:/Users/ji252/Documents/GitHub/tariff_rate_tracker')

  # Load latest snapshot or time series
  ts_path <- 'data/timeseries/rate_timeseries.rds'
  if (!file.exists(ts_path)) {
    # Fall back to single snapshot
    ts_path <- 'data/processed/rates_rev32.rds'
  }

  rates <- readRDS(ts_path)
  message('Loaded rates: ', nrow(rates), ' rows')

  # Apply all scenarios
  all_scenarios <- apply_all_scenarios(rates)

  # Summary by scenario
  cat('\n=== Scenario Summary ===\n')
  all_scenarios %>%
    group_by(scenario) %>%
    summarise(
      mean_total_rate = round(mean(total_rate) * 100, 2),
      mean_additional = round(mean(total_additional) * 100, 2),
      n_with_duties = sum(total_additional > 0),
      .groups = 'drop'
    ) %>%
    print()
}
