# =============================================================================
# Step 08: Validate Against TPC Data
# =============================================================================
#
# Compares calculated tariff rates against TPC (Tax Policy Center) estimates.
#
# TPC data format:
#   - country: Country name (text)
#   - hts10: 10-digit HTS code
#   - 2025-03-17, 2025-04-17, etc.: Rate changes from Jan 1 baseline
#
# Output:
#   - validation_report.csv: Comparison of calculated vs TPC rates
#   - discrepancy analysis by country, product, and date
#
# =============================================================================

library(tidyverse)

# =============================================================================
# Country Name Mapping
# =============================================================================

#' Create mapping from TPC country names to Census codes
#'
#' @param census_codes Census codes data frame
#' @return Named vector: name -> code
create_country_name_map <- function(census_codes) {
  # Start with Census file mapping
  name_to_code <- setNames(census_codes$Code, census_codes$Name)

  # Add common variations
  name_to_code['China'] <- '5700'
  name_to_code['Canada'] <- '1220'
  name_to_code['Mexico'] <- '2010'
  name_to_code['Japan'] <- '5880'
  name_to_code['United Kingdom'] <- '4120'
  name_to_code['UK'] <- '4120'
  name_to_code['South Korea'] <- '5800'
  name_to_code['Korea, South'] <- '5800'
  name_to_code['Korea'] <- '5800'
  name_to_code['Taiwan'] <- '5830'
  name_to_code['Germany'] <- '4280'
  name_to_code['France'] <- '4279'
  name_to_code['Italy'] <- '4759'
  name_to_code['Russia'] <- '4621'
  name_to_code['Russian Federation'] <- '4621'
  name_to_code['Australia'] <- '6021'
  name_to_code['Brazil'] <- '3510'
  name_to_code['India'] <- '5330'
  name_to_code['Vietnam'] <- '5520'
  name_to_code['Viet Nam'] <- '5520'
  name_to_code['Thailand'] <- '5490'
  name_to_code['Indonesia'] <- '5600'
  name_to_code['Malaysia'] <- '5570'
  name_to_code['Philippines'] <- '5650'
  name_to_code['Singapore'] <- '5590'

  return(name_to_code)
}


# =============================================================================
# TPC Data Loading
# =============================================================================

#' Load and clean TPC validation data
#'
#' @param tpc_path Path to TPC CSV file
#' @param name_to_code Country name to code mapping
#' @return Tibble with cleaned TPC data
load_tpc_data <- function(tpc_path, name_to_code) {
  message('Loading TPC data from: ', tpc_path)

  tpc <- read_csv(tpc_path, col_types = cols(.default = col_character()))

  # Get date columns (all columns except country and hts10)
  date_cols <- setdiff(names(tpc), c('country', 'hts10'))

  message('  Rows: ', nrow(tpc))
  message('  Date columns: ', paste(date_cols, collapse = ', '))

  # Pivot to long format
  tpc_long <- tpc %>%
    pivot_longer(
      cols = all_of(date_cols),
      names_to = 'date',
      values_to = 'tpc_rate_change'
    ) %>%
    mutate(
      tpc_rate_change = as.numeric(tpc_rate_change),
      date = as.Date(date)
    )

  # Map country names to codes
  tpc_long <- tpc_long %>%
    mutate(
      country_code = name_to_code[country]
    ) %>%
    filter(!is.na(country_code))

  message('  After country mapping: ', nrow(tpc_long), ' rows')
  message('  Unique countries: ', n_distinct(tpc_long$country_code))
  message('  Unique HTS10: ', n_distinct(tpc_long$hts10))

  return(tpc_long)
}


# =============================================================================
# Validation Functions
# =============================================================================

#' Compare calculated rates to TPC for a specific date
#'
#' @param our_rates Our calculated rates
#' @param tpc_data TPC data
#' @param target_date Date to compare
#' @param baseline_rates Baseline rates (for calculating change)
#' @return Validation comparison tibble
compare_to_tpc <- function(our_rates, tpc_data, target_date, baseline_rates = NULL) {
  message('Comparing to TPC for date: ', target_date)

  # Exclude phantom IEEPA countries from comparison
  pp <- tryCatch(load_policy_params(), error = function(e) NULL)
  tpc_excluded <- if (!is.null(pp)) pp$tpc_excluded_countries %||% character(0) else character(0)

  # Filter TPC to target date
  tpc_date <- tpc_data %>%
    filter(date == target_date) %>%
    select(hts10, country = country_code, tpc_rate_change)

  if (length(tpc_excluded) > 0) {
    tpc_date <- tpc_date %>% filter(!country %in% tpc_excluded)
  }

  # Calculate our rate change from baseline
  if (!is.null(baseline_rates)) {
    our_changes <- our_rates %>%
      select(hts10, country, total_additional_current = total_additional) %>%
      left_join(
        baseline_rates %>%
          select(hts10, country, total_additional_baseline = total_additional),
        by = c('hts10', 'country')
      ) %>%
      mutate(
        total_additional_baseline = coalesce(total_additional_baseline, 0),
        our_rate_change = total_additional_current - total_additional_baseline
      )
  } else {
    # Assume baseline is zero
    our_changes <- our_rates %>%
      select(hts10, country, our_rate_change = total_additional)
  }

  # Exclude phantom IEEPA countries from our side as well (full_join)
  if (length(tpc_excluded) > 0) {
    our_changes <- our_changes %>% filter(!country %in% tpc_excluded)
  }

  # Join and compare
  comparison <- tpc_date %>%
    full_join(our_changes, by = c('hts10', 'country')) %>%
    mutate(
      our_rate_change = coalesce(our_rate_change, 0),
      tpc_rate_change = coalesce(tpc_rate_change, 0),
      diff = our_rate_change - tpc_rate_change,
      abs_diff = abs(diff),
      match = abs_diff < 0.01  # Within 1 percentage point
    )

  # Summary stats
  n_total <- nrow(comparison)
  n_match <- sum(comparison$match)
  n_tpc_only <- sum(comparison$tpc_rate_change > 0 & comparison$our_rate_change == 0)
  n_our_only <- sum(comparison$tpc_rate_change == 0 & comparison$our_rate_change > 0)

  message('  Total comparisons: ', n_total)
  message('  Matching (<1pp diff): ', n_match, ' (', round(100 * n_match / n_total, 1), '%)')
  message('  TPC has rate, we don\'t: ', n_tpc_only)
  message('  We have rate, TPC doesn\'t: ', n_our_only)

  return(comparison)
}


#' Generate validation summary by country
#'
#' @param comparison Comparison data from compare_to_tpc
#' @return Summary tibble
summarize_by_country <- function(comparison) {
  comparison %>%
    group_by(country) %>%
    summarise(
      n_products = n(),
      n_match = sum(match),
      pct_match = mean(match) * 100,
      mean_diff = mean(diff),
      mean_abs_diff = mean(abs_diff),
      max_abs_diff = max(abs_diff),
      .groups = 'drop'
    ) %>%
    arrange(pct_match)
}


#' Generate validation summary by HTS chapter
#'
#' @param comparison Comparison data
#' @return Summary tibble
summarize_by_chapter <- function(comparison) {
  comparison %>%
    mutate(chapter = substr(hts10, 1, 2)) %>%
    group_by(chapter) %>%
    summarise(
      n_products = n(),
      n_match = sum(match),
      pct_match = mean(match) * 100,
      mean_diff = mean(diff),
      mean_abs_diff = mean(abs_diff),
      .groups = 'drop'
    ) %>%
    arrange(pct_match)
}


#' Identify systematic discrepancies
#'
#' @param comparison Comparison data
#' @return List of discrepancy patterns
identify_discrepancies <- function(comparison) {
  # Large discrepancies
  large_diff <- comparison %>%
    filter(abs_diff > 0.05) %>%  # >5 percentage points
    arrange(desc(abs_diff))

  # Cases where TPC has rate but we don't
  missing_in_ours <- comparison %>%
    filter(tpc_rate_change > 0.01 & our_rate_change < 0.01) %>%
    arrange(desc(tpc_rate_change))

  # Cases where we have rate but TPC doesn't
  extra_in_ours <- comparison %>%
    filter(our_rate_change > 0.01 & tpc_rate_change < 0.01) %>%
    arrange(desc(our_rate_change))

  list(
    large_diff = large_diff,
    missing_in_ours = missing_in_ours,
    extra_in_ours = extra_in_ours
  )
}


# =============================================================================
# Per-Revision Validation
# =============================================================================

#' Validate a single revision's rates against TPC for a specific date
#'
#' Called from 00_build_timeseries.R for revisions that have a tpc_date.
#' Compares our calculated rates to TPC and returns summary metrics.
#'
#' @param revision_rates Our calculated rates for one revision
#' @param tpc_path Path to TPC CSV file
#' @param tpc_date The TPC date to compare against (Date or character)
#' @param census_codes Census codes data frame
#' @return List with match_rate, mean_abs_diff, by_country, by_authority, comparison
validate_revision_against_tpc <- function(revision_rates, tpc_path, tpc_date, census_codes) {
  tpc_date <- as.Date(tpc_date)

  # Create country mapping and load TPC data
  name_to_code <- create_country_name_map(census_codes)
  tpc_data <- load_tpc_data(tpc_path, name_to_code)

  # Filter TPC to the target date
  tpc_date_data <- tpc_data %>%
    filter(date == tpc_date) %>%
    select(hts10, country = country_code, tpc_rate_change)

  if (nrow(tpc_date_data) == 0) {
    message('  No TPC data for date: ', tpc_date)
    return(list(
      match_rate = NA_real_,
      mean_abs_diff = NA_real_,
      by_country = tibble(),
      by_authority = tibble(),
      comparison = tibble()
    ))
  }

  # Exclude phantom IEEPA countries from comparison
  pp <- tryCatch(load_policy_params(), error = function(e) NULL)
  tpc_excluded <- if (!is.null(pp)) pp$tpc_excluded_countries %||% character(0) else character(0)

  # Our rates: use total_additional as the rate change from zero baseline
  our_rates <- revision_rates %>%
    select(hts10, country, total_additional,
           rate_232, rate_301, rate_ieepa_recip, rate_ieepa_fent, rate_other)

  if (length(tpc_excluded) > 0) {
    our_rates <- our_rates %>% filter(!country %in% tpc_excluded)
    tpc_date_data <- tpc_date_data %>% filter(!country %in% tpc_excluded)
  }

  # Join and compare
  comparison <- tpc_date_data %>%
    inner_join(our_rates, by = c('hts10', 'country')) %>%
    mutate(
      diff = total_additional - tpc_rate_change,
      abs_diff = abs(diff),
      match_2pp = abs_diff < 0.02  # within 2 percentage points
    )

  # Summary metrics
  match_rate <- if (nrow(comparison) > 0) mean(comparison$match_2pp) else NA_real_
  mean_abs_diff <- if (nrow(comparison) > 0) mean(comparison$abs_diff) else NA_real_

  # By country
  by_country <- comparison %>%
    group_by(country) %>%
    summarise(
      n = n(),
      n_match = sum(match_2pp),
      pct_match = round(mean(match_2pp) * 100, 1),
      mean_abs_diff = round(mean(abs_diff) * 100, 2),
      .groups = 'drop'
    ) %>%
    arrange(pct_match)

  # By authority gap: where does the discrepancy come from?
  by_authority <- comparison %>%
    filter(!match_2pp) %>%
    mutate(
      gap_from_301 = rate_301 > 0 & tpc_rate_change > total_additional,
      gap_from_ieepa = rate_ieepa_recip > 0
    ) %>%
    summarise(
      n_mismatches = n(),
      n_with_301 = sum(gap_from_301),
      n_with_ieepa = sum(gap_from_ieepa),
      mean_gap = round(mean(abs_diff) * 100, 2)
    )

  message('  Validation: ', nrow(comparison), ' comparisons, ',
          round(match_rate * 100, 1), '% match (±2pp), ',
          'mean diff: ', round(mean_abs_diff * 100, 2), 'pp')

  return(list(
    match_rate = match_rate,
    mean_abs_diff = mean_abs_diff,
    n_comparisons = nrow(comparison),
    by_country = by_country,
    by_authority = by_authority,
    comparison = comparison
  ))
}


# =============================================================================
# Main Validation Pipeline
# =============================================================================

#' Run full validation against TPC
#'
#' @param our_rates Our calculated rates
#' @param tpc_path Path to TPC data
#' @param census_codes Census codes data
#' @param output_dir Output directory
run_validation <- function(our_rates, tpc_path, census_codes, output_dir = 'output/validation') {
  message('\n=== Running TPC Validation ===\n')

  # Create output directory
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

  # Create country mapping
  name_to_code <- create_country_name_map(census_codes)

  # Load TPC data
  tpc_data <- load_tpc_data(tpc_path, name_to_code)

  # Get unique dates
  dates <- unique(tpc_data$date)
  message('\nValidating against ', length(dates), ' dates: ', paste(dates, collapse = ', '))

  # Run comparison for each date
  all_comparisons <- list()

  for (d in dates) {
    cat('\n--- Date:', as.character(d), '---\n')
    comparison <- compare_to_tpc(our_rates, tpc_data, d)
    all_comparisons[[as.character(d)]] <- comparison

    # Country summary
    cat('\nBy country (worst matching):\n')
    country_summary <- summarize_by_country(comparison)
    print(head(country_summary, 10))

    # Save detailed comparison
    write_csv(comparison, file.path(output_dir, paste0('comparison_', d, '.csv')))
  }

  # Overall summary
  cat('\n\n=== OVERALL VALIDATION SUMMARY ===\n')

  overall <- bind_rows(all_comparisons, .id = 'date') %>%
    filter(!is.na(tpc_rate_change) | !is.na(our_rate_change))

  cat('Total comparisons: ', nrow(overall), '\n')
  cat('Matching (<1pp): ', sum(overall$match), ' (', round(100 * mean(overall$match), 1), '%)\n')
  cat('Mean absolute diff: ', round(mean(overall$abs_diff) * 100, 2), ' pp\n')

  # Identify discrepancies
  discrepancies <- identify_discrepancies(overall)

  cat('\nLarge discrepancies (>5pp): ', nrow(discrepancies$large_diff), '\n')
  cat('Missing in our calc: ', nrow(discrepancies$missing_in_ours), '\n')
  cat('Extra in our calc: ', nrow(discrepancies$extra_in_ours), '\n')

  # Save discrepancies
  if (nrow(discrepancies$large_diff) > 0) {
    write_csv(discrepancies$large_diff, file.path(output_dir, 'large_discrepancies.csv'))
  }
  if (nrow(discrepancies$missing_in_ours) > 0) {
    write_csv(discrepancies$missing_in_ours, file.path(output_dir, 'missing_in_ours.csv'))
  }
  if (nrow(discrepancies$extra_in_ours) > 0) {
    write_csv(discrepancies$extra_in_ours, file.path(output_dir, 'extra_in_ours.csv'))
  }

  # Save overall summary
  overall_summary <- overall %>%
    group_by(date) %>%
    summarise(
      n_total = n(),
      n_match = sum(match),
      pct_match = mean(match) * 100,
      mean_diff = mean(diff) * 100,
      mean_abs_diff = mean(abs_diff) * 100,
      .groups = 'drop'
    )

  write_csv(overall_summary, file.path(output_dir, 'validation_summary.csv'))

  message('\nValidation complete. Results saved to ', output_dir)

  return(list(
    comparisons = all_comparisons,
    discrepancies = discrepancies,
    summary = overall_summary
  ))
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)
  source(here('src', 'helpers.R'))

  # Load our calculated rates
  rates <- readRDS('data/processed/rates_rev32.rds')

  # Load census codes
  census_codes <- read_csv('resources/census_codes.csv', col_types = cols(.default = col_character()))

  # Run validation
  validation <- run_validation(
    our_rates = rates,
    tpc_path = 'data/tpc/tariff_by_flow_day.csv',
    census_codes = census_codes
  )

  # Print key findings
  cat('\n\n=== KEY FINDINGS ===\n')

  cat('\nCountries with largest discrepancies:\n')
  bind_rows(validation$comparisons) %>%
    group_by(country) %>%
    summarise(mean_abs_diff = mean(abs_diff)) %>%
    arrange(desc(mean_abs_diff)) %>%
    head(10) %>%
    left_join(census_codes, by = c('country' = 'Code')) %>%
    print()
}
