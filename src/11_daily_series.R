# =============================================================================
# Step 11: Daily Rate Series
# =============================================================================
#
# Provides point-in-time rate queries and pre-computed daily aggregates.
# Leverages the interval-encoded timeseries (valid_from / valid_until) built
# by 00_build_timeseries.R -- rates only change at revision boundaries, so
# we compute one aggregate per revision and broadcast across calendar days.
#
# Core functions:
#   get_rates_at_date(ts, query_date) - point-in-time snapshot
#   build_daily_aggregates(ts, date_range, imports) - pre-computed daily ETRs
#   expand_to_daily(ts, date_range, countries, products) - on-demand expansion
#
# Usage:
#   # As library (source into other scripts):
#   source('src/11_daily_series.R')
#   ts <- readRDS('data/timeseries/rate_timeseries.rds')
#   snapshot <- get_rates_at_date(ts, as.Date('2025-06-15'))
#
#   # Standalone:
#   Rscript src/11_daily_series.R
#
# =============================================================================

library(tidyverse)


# =============================================================================
# Point-in-Time Query
# =============================================================================

#' Get rate snapshot at a specific date
#'
#' Filters the interval-encoded timeseries to rows where
#' valid_from <= query_date <= valid_until. Returns one revision's
#' worth of data (same shape as a single snapshot).
#'
#' @param ts Timeseries tibble with valid_from/valid_until columns
#' @param query_date Date (or character coercible to Date)
#' @return Tibble — one snapshot for the active revision at query_date
get_rates_at_date <- function(ts, query_date) {
  query_date <- as.Date(query_date)

  stopifnot(
    'valid_from' %in% names(ts),
    'valid_until' %in% names(ts)
  )

  snapshot <- ts %>%
    filter(valid_from <= query_date, valid_until >= query_date)

  if (nrow(snapshot) == 0) {
    warning('No rates found for date: ', query_date,
            '. Date range in timeseries: ',
            min(ts$valid_from), ' to ', max(ts$valid_until))
  }

  return(snapshot)
}


# =============================================================================
# Daily Aggregates
# =============================================================================

#' Build daily aggregate statistics
#'
#' Since rates only change at revision boundaries, computes one aggregate per
#' revision and broadcasts to all calendar days in that revision's interval.
#' Import weights are optional -- if NULL, computes simple (unweighted) means.
#'
#' @param ts Timeseries tibble with valid_from/valid_until
#' @param date_range Length-2 Date vector (start, end). Default: full timeseries range
#' @param imports Optional tibble with hs10, cty_code, imports columns for weighting
#' @return List with daily_overall, daily_by_country, daily_by_authority tibbles
build_daily_aggregates <- function(ts, date_range = NULL, imports = NULL) {

  stopifnot(
    'valid_from' %in% names(ts),
    'valid_until' %in% names(ts)
  )

  # Default date range: full timeseries span

  if (is.null(date_range)) {
    date_range <- c(min(ts$valid_from), max(ts$valid_until))
  }
  date_range <- as.Date(date_range)

  # Get unique revision intervals
  rev_intervals <- ts %>%
    distinct(revision, valid_from, valid_until) %>%
    arrange(valid_from)

  message('Building daily aggregates for ', date_range[1], ' to ', date_range[2])
  message('  Revisions: ', nrow(rev_intervals))

  # Optionally join import weights
  has_weights <- !is.null(imports)
  if (has_weights) {
    message('  Using import weights (', nrow(imports), ' flows)')
    ts_weighted <- ts %>%
      inner_join(
        imports %>% select(hs10, cty_code, imports),
        by = c('hts10' = 'hs10', 'country' = 'cty_code')
      )
  }

  # --- Per-revision aggregates ---

  # Overall
  agg_overall <- rev_intervals %>%
    pmap_dfr(function(revision, valid_from, valid_until) {
      rev_data <- ts %>% filter(revision == !!revision)
      row <- tibble(
        revision = revision,
        valid_from = valid_from,
        valid_until = valid_until,
        mean_additional = mean(rev_data$total_additional),
        mean_total = mean(rev_data$total_rate),
        n_products = n_distinct(rev_data$hts10),
        n_countries = n_distinct(rev_data$country)
      )
      if (has_weights) {
        wt_data <- ts_weighted %>% filter(revision == !!revision)
        if (nrow(wt_data) > 0) {
          row$weighted_etr <- sum(wt_data$total_rate * wt_data$imports) / sum(wt_data$imports)
        } else {
          row$weighted_etr <- NA_real_
        }
      }
      return(row)
    })

  # By country
  agg_by_country <- rev_intervals %>%
    pmap_dfr(function(revision, valid_from, valid_until) {
      rev_data <- ts %>% filter(revision == !!revision)
      row <- rev_data %>%
        group_by(country) %>%
        summarise(
          mean_additional = mean(total_additional),
          mean_total = mean(total_rate),
          .groups = 'drop'
        ) %>%
        mutate(revision = revision, valid_from = valid_from, valid_until = valid_until)
      if (has_weights) {
        wt_data <- ts_weighted %>% filter(revision == !!revision)
        wt_country <- wt_data %>%
          group_by(country) %>%
          summarise(
            weighted_etr = sum(total_rate * imports) / sum(imports),
            .groups = 'drop'
          )
        row <- row %>% left_join(wt_country, by = 'country')
      }
      return(row)
    })

  # By authority
  agg_by_authority <- rev_intervals %>%
    pmap_dfr(function(revision, valid_from, valid_until) {
      rev_data <- ts %>% filter(revision == !!revision)
      row <- tibble(
        revision = revision,
        valid_from = valid_from,
        valid_until = valid_until,
        mean_232 = mean(rev_data$rate_232),
        mean_301 = mean(rev_data$rate_301),
        mean_ieepa = mean(rev_data$rate_ieepa_recip),
        mean_fentanyl = mean(rev_data$rate_ieepa_fent),
        mean_s122 = if ('rate_s122' %in% names(rev_data)) mean(rev_data$rate_s122) else 0
      )
      if (has_weights) {
        wt_data <- ts_weighted %>% filter(revision == !!revision)
        if (nrow(wt_data) > 0) {
          total_imp <- sum(wt_data$imports)
          row$etr_232 <- sum(wt_data$rate_232 * wt_data$imports) / total_imp
          row$etr_301 <- sum(wt_data$rate_301 * wt_data$imports) / total_imp
          row$etr_ieepa <- sum(wt_data$rate_ieepa_recip * wt_data$imports) / total_imp
          row$etr_fentanyl <- sum(wt_data$rate_ieepa_fent * wt_data$imports) / total_imp
          row$etr_s122 <- if ('rate_s122' %in% names(wt_data)) {
            sum(wt_data$rate_s122 * wt_data$imports) / total_imp
          } else 0
        } else {
          row$etr_232 <- row$etr_301 <- row$etr_ieepa <- row$etr_fentanyl <- row$etr_s122 <- NA_real_
        }
      }
      return(row)
    })

  # --- Expand revision-level aggregates to daily ---
  # Iterate over revision intervals and replicate to each day (no fuzzyjoin needed)

  expand_intervals <- function(agg_df) {
    agg_df %>%
      pmap_dfr(function(...) {
        row <- tibble(...)
        dates <- seq(
          max(row$valid_from, date_range[1]),
          min(row$valid_until, date_range[2]),
          by = 'day'
        )
        if (length(dates) == 0) return(tibble())
        tibble(date = dates) %>%
          bind_cols(row %>% select(-valid_from, -valid_until) %>% slice(rep(1, length(dates))))
      })
  }

  daily_overall <- expand_intervals(agg_overall)
  daily_by_country <- expand_intervals(agg_by_country)
  daily_by_authority <- expand_intervals(agg_by_authority)

  message('  Daily overall rows: ', nrow(daily_overall))
  message('  Daily by-country rows: ', nrow(daily_by_country))
  message('  Daily by-authority rows: ', nrow(daily_by_authority))

  return(list(
    daily_overall = daily_overall,
    daily_by_country = daily_by_country,
    daily_by_authority = daily_by_authority
  ))
}


# =============================================================================
# On-Demand Expansion
# =============================================================================

#' Expand interval rows to one-per-date for a subset
#'
#' For ad-hoc analysis. Forces caller to specify a subset to prevent
#' accidental full expansion (366 days x ~12M rows = ~4B rows).
#'
#' @param ts Timeseries tibble with valid_from/valid_until
#' @param date_range Length-2 Date vector (start, end)
#' @param countries Character vector of country codes to include
#' @param products Character vector of HTS10 codes to include
#' @return Tibble with one row per date x product x country
expand_to_daily <- function(ts, date_range, countries, products) {
  date_range <- as.Date(date_range)

  stopifnot(
    length(countries) > 0,
    length(products) > 0,
    length(date_range) == 2
  )

  # Filter to requested subset
  subset <- ts %>%
    filter(
      country %in% countries,
      hts10 %in% products
    )

  if (nrow(subset) == 0) {
    warning('No matching rows for the requested countries/products')
    return(tibble())
  }

  # Expand each row across its valid date range, clipped to requested range
  calendar <- tibble(date = seq(date_range[1], date_range[2], by = 'day'))

  expanded <- subset %>%
    inner_join(calendar, by = character(), relationship = 'many-to-many') %>%
    filter(date >= valid_from, date <= valid_until)

  message('Expanded ', nrow(subset), ' interval rows to ', nrow(expanded), ' daily rows')
  message('  Countries: ', n_distinct(expanded$country),
          ', Products: ', n_distinct(expanded$hts10),
          ', Days: ', n_distinct(expanded$date))

  return(expanded)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)
  source(here('src', 'helpers.R'))

  ts_path <- here('data', 'timeseries', 'rate_timeseries.rds')
  if (!file.exists(ts_path)) {
    stop('Timeseries not found: ', ts_path,
         '\nRun: Rscript src/00_build_timeseries.R')
  }

  message('\n', strrep('=', 70))
  message('DAILY RATE SERIES BUILDER')
  message(strrep('=', 70))

  ts <- readRDS(ts_path)
  message('Loaded timeseries: ', nrow(ts), ' rows, ',
          n_distinct(ts$revision), ' revisions')

  # Check for interval columns
  if (!'valid_from' %in% names(ts)) {
    stop('Timeseries missing valid_from/valid_until columns.',
         '\nRebuild with: Rscript src/00_build_timeseries.R')
  }

  # Load import weights if available
  imports_path <- here('..', 'Tariff-ETRs', 'cache', 'hs10_by_country_gtap_2024_con.rds')
  imports <- NULL
  if (file.exists(imports_path)) {
    message('Loading import weights...')
    imports_raw <- readRDS(imports_path)
    imports <- imports_raw %>%
      group_by(hs10, cty_code) %>%
      summarise(imports = sum(imports), .groups = 'drop') %>%
      filter(imports > 0)
    message('  ', nrow(imports), ' import flows loaded')
  } else {
    message('Import weights not found — computing unweighted means only')
  }

  # Build daily aggregates
  daily <- build_daily_aggregates(ts, imports = imports)

  # Save outputs
  out_dir <- here('output', 'daily')
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

  write_csv(daily$daily_overall, file.path(out_dir, 'daily_overall.csv'))
  write_csv(daily$daily_by_country, file.path(out_dir, 'daily_by_country.csv'))
  write_csv(daily$daily_by_authority, file.path(out_dir, 'daily_by_authority.csv'))
  saveRDS(daily, file.path(out_dir, 'daily_aggregates.rds'))

  message('\n', strrep('=', 70))
  message('DAILY SERIES COMPLETE')
  message(strrep('=', 70))
  message('Outputs saved to: ', out_dir)
  message('  daily_overall.csv: ', nrow(daily$daily_overall), ' rows')
  message('  daily_by_country.csv: ', nrow(daily$daily_by_country), ' rows')
  message('  daily_by_authority.csv: ', nrow(daily$daily_by_authority), ' rows')
  message('  daily_aggregates.rds')
  message(strrep('=', 70), '\n')
}
