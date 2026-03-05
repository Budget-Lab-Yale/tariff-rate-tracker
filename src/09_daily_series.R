# =============================================================================
# Step 12: Daily Rate Series
# =============================================================================
#
# Provides pre-computed daily aggregates and on-demand expansion.
# Leverages the interval-encoded timeseries (valid_from / valid_until) built
# by 00_build_timeseries.R -- rates only change at revision boundaries, so
# we compute one aggregate per revision and broadcast across calendar days.
#
# Note: get_rates_at_date() is defined in helpers.R (shared with 11_weighted_etr.R).
#
# Core functions:
#   build_daily_aggregates(ts, date_range, imports, policy_params) - daily ETRs
#   expand_to_daily(ts, date_range, countries, products) - on-demand expansion
#   run_daily_series(ts, imports, policy_params) - full pipeline wrapper
#
# Usage:
#   # As library (source into other scripts):
#   source('src/12_daily_series.R')
#   source('src/helpers.R')
#   ts <- readRDS('data/timeseries/rate_timeseries.rds')
#   snapshot <- get_rates_at_date(ts, as.Date('2025-06-15'))
#
#   # Standalone:
#   Rscript src/12_daily_series.R
#
# =============================================================================

library(tidyverse)


# =============================================================================
# Daily Aggregates
# =============================================================================

#' Build daily aggregate statistics
#'
#' Since rates only change at revision boundaries, computes one aggregate per
#' revision and broadcasts to all calendar days in that revision's interval.
#' Import weights are optional -- if NULL, computes simple (unweighted) means.
#'
#' If policy_params contains SECTION_122 with finalized=FALSE, any revision
#' interval that spans the s122 expiry date is split into two sub-intervals:
#' one with s122 active and one with s122 zeroed.
#'
#' @param ts Timeseries tibble with valid_from/valid_until
#' @param date_range Length-2 Date vector (start, end). Default: full timeseries range
#' @param imports Optional tibble with hs10, cty_code, imports columns for weighting
#' @param policy_params Optional policy params list (from load_policy_params())
#' @return List with daily_overall, daily_by_country, daily_by_authority tibbles
build_daily_aggregates <- function(ts, date_range = NULL, imports = NULL,
                                   policy_params = NULL) {

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
  total_imports <- NA_real_
  if (has_weights) {
    message('  Using import weights (', nrow(imports), ' flows)')
    # Total imports across ALL flows — denominator for weighted ETR.
    # Products not in the timeseries (no additional tariffs) implicitly
    # have rate = 0 and contribute only to the denominator.
    total_imports <- sum(imports$imports)
    message('  Total imports: $', round(total_imports / 1e9, 1), 'B')
    ts_weighted <- ts %>%
      inner_join(
        imports %>% select(hs10, cty_code, imports),
        by = c('hts10' = 'hs10', 'country' = 'cty_code')
      )
  }

  # --- Section 122 expiry: split intervals if needed ---
  s122_expiry <- NULL
  if (!is.null(policy_params$SECTION_122) &&
      !policy_params$SECTION_122$finalized &&
      'rate_s122' %in% names(ts)) {
    s122_expiry <- policy_params$SECTION_122$expiry_date
  }

  # Helper: compute aggregates for one revision interval (or sub-interval)
  compute_agg_overall <- function(revision, valid_from, valid_until, zero_s122 = FALSE) {
    rev_data <- ts %>% filter(revision == !!revision)
    if (zero_s122 && 'rate_s122' %in% names(rev_data)) {
      rev_data <- rev_data %>%
        mutate(
          total_additional = total_additional - rate_s122,
          total_rate = total_rate - rate_s122,
          rate_s122 = 0
        )
    }
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
      if (zero_s122 && 'rate_s122' %in% names(wt_data)) {
        wt_data <- wt_data %>%
          mutate(
            total_additional = total_additional - rate_s122,
            total_rate = total_rate - rate_s122,
            rate_s122 = 0
          )
      }
      if (nrow(wt_data) > 0) {
        row$weighted_etr <- sum(wt_data$total_rate * wt_data$imports) / total_imports
        row$weighted_etr_additional <- sum(wt_data$total_additional * wt_data$imports) / total_imports
        row$matched_imports_b <- sum(wt_data$imports) / 1e9
        row$total_imports_b <- total_imports / 1e9
      } else {
        row$weighted_etr <- 0
        row$weighted_etr_additional <- 0
        row$matched_imports_b <- 0
        row$total_imports_b <- total_imports / 1e9
      }
    }
    return(row)
  }

  compute_agg_country <- function(revision, valid_from, valid_until, zero_s122 = FALSE) {
    rev_data <- ts %>% filter(revision == !!revision)
    if (zero_s122 && 'rate_s122' %in% names(rev_data)) {
      rev_data <- rev_data %>%
        mutate(
          total_additional = total_additional - rate_s122,
          total_rate = total_rate - rate_s122,
          rate_s122 = 0
        )
    }
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
      if (zero_s122 && 'rate_s122' %in% names(wt_data)) {
        wt_data <- wt_data %>%
          mutate(
            total_additional = total_additional - rate_s122,
            total_rate = total_rate - rate_s122,
            rate_s122 = 0
          )
      }
      country_total_imp <- imports %>%
        group_by(cty_code) %>%
        summarise(country_total_imports = sum(imports), .groups = 'drop') %>%
        rename(country = cty_code)
      wt_country <- wt_data %>%
        group_by(country) %>%
        summarise(
          tariffed_imports = sum(imports),
          weighted_numerator = sum(total_rate * imports),
          .groups = 'drop'
        ) %>%
        left_join(country_total_imp, by = 'country') %>%
        mutate(
          country_total_imports = coalesce(country_total_imports, tariffed_imports),
          weighted_etr = weighted_numerator / country_total_imports
        ) %>%
        select(country, weighted_etr)
      row <- row %>% left_join(wt_country, by = 'country')
    }
    return(row)
  }

  compute_agg_authority <- function(revision, valid_from, valid_until, zero_s122 = FALSE) {
    rev_data <- ts %>% filter(revision == !!revision)
    if (zero_s122 && 'rate_s122' %in% names(rev_data)) {
      rev_data <- rev_data %>% mutate(rate_s122 = 0)
    }
    row <- tibble(
      revision = revision,
      valid_from = valid_from,
      valid_until = valid_until,
      mean_232 = mean(rev_data$rate_232),
      mean_301 = mean(rev_data$rate_301),
      mean_ieepa = mean(rev_data$rate_ieepa_recip),
      mean_fentanyl = mean(rev_data$rate_ieepa_fent),
      mean_s122 = if ('rate_s122' %in% names(rev_data)) mean(rev_data$rate_s122) else 0,
      mean_other = if ('rate_other' %in% names(rev_data)) mean(rev_data$rate_other) else 0
    )
    if (has_weights) {
      wt_data <- ts_weighted %>% filter(revision == !!revision)
      if (zero_s122 && 'rate_s122' %in% names(wt_data)) {
        wt_data <- wt_data %>% mutate(rate_s122 = 0)
      }
      if (nrow(wt_data) > 0) {
        row$etr_232 <- sum(wt_data$rate_232 * wt_data$imports) / total_imports
        row$etr_301 <- sum(wt_data$rate_301 * wt_data$imports) / total_imports
        row$etr_ieepa <- sum(wt_data$rate_ieepa_recip * wt_data$imports) / total_imports
        row$etr_fentanyl <- sum(wt_data$rate_ieepa_fent * wt_data$imports) / total_imports
        row$etr_s122 <- if ('rate_s122' %in% names(wt_data)) {
          sum(wt_data$rate_s122 * wt_data$imports) / total_imports
        } else 0
        row$etr_other <- if ('rate_other' %in% names(wt_data)) {
          sum(wt_data$rate_other * wt_data$imports) / total_imports
        } else 0
      } else {
        row$etr_232 <- row$etr_301 <- row$etr_ieepa <- row$etr_fentanyl <- row$etr_s122 <- row$etr_other <- 0
      }
    }
    return(row)
  }

  # --- Per-revision aggregates (with s122 expiry splitting) ---
  agg_overall <- rev_intervals %>%
    pmap_dfr(function(revision, valid_from, valid_until) {
      if (!is.null(s122_expiry) && valid_from <= s122_expiry && valid_until > s122_expiry) {
        # Split: [valid_from, expiry] with s122 active, [expiry+1, valid_until] with s122 zeroed
        bind_rows(
          compute_agg_overall(revision, valid_from, s122_expiry, zero_s122 = FALSE),
          compute_agg_overall(revision, s122_expiry + 1, valid_until, zero_s122 = TRUE)
        )
      } else if (!is.null(s122_expiry) && valid_from > s122_expiry) {
        compute_agg_overall(revision, valid_from, valid_until, zero_s122 = TRUE)
      } else {
        compute_agg_overall(revision, valid_from, valid_until)
      }
    })

  agg_by_country <- rev_intervals %>%
    pmap_dfr(function(revision, valid_from, valid_until) {
      if (!is.null(s122_expiry) && valid_from <= s122_expiry && valid_until > s122_expiry) {
        bind_rows(
          compute_agg_country(revision, valid_from, s122_expiry, zero_s122 = FALSE),
          compute_agg_country(revision, s122_expiry + 1, valid_until, zero_s122 = TRUE)
        )
      } else if (!is.null(s122_expiry) && valid_from > s122_expiry) {
        compute_agg_country(revision, valid_from, valid_until, zero_s122 = TRUE)
      } else {
        compute_agg_country(revision, valid_from, valid_until)
      }
    })

  agg_by_authority <- rev_intervals %>%
    pmap_dfr(function(revision, valid_from, valid_until) {
      if (!is.null(s122_expiry) && valid_from <= s122_expiry && valid_until > s122_expiry) {
        bind_rows(
          compute_agg_authority(revision, valid_from, s122_expiry, zero_s122 = FALSE),
          compute_agg_authority(revision, s122_expiry + 1, valid_until, zero_s122 = TRUE)
        )
      } else if (!is.null(s122_expiry) && valid_from > s122_expiry) {
        compute_agg_authority(revision, valid_from, valid_until, zero_s122 = TRUE)
      } else {
        compute_agg_authority(revision, valid_from, valid_until)
      }
    })

  if (!is.null(s122_expiry)) {
    message('  Section 122 expiry split at ', s122_expiry)
  }

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
# Reusable Wrappers (called by 00_build_timeseries.R post-build)
# =============================================================================

#' Load import weights from Tariff-ETRs cache
#'
#' @param imports_path Path to hs10_by_country_gtap RDS
#' @return Tibble with hs10, cty_code, imports; or NULL if unavailable
load_import_weights <- function(
  imports_path = here('..', 'Tariff-ETRs', 'cache', 'hs10_by_country_gtap_2024_con.rds')
) {
  if (!file.exists(imports_path)) {
    message('Import weights not found — computing unweighted means only')
    return(NULL)
  }
  message('Loading import weights...')
  imports_raw <- readRDS(imports_path)
  imports <- imports_raw %>%
    group_by(hs10, cty_code) %>%
    summarise(imports = sum(imports), .groups = 'drop') %>%
    filter(imports > 0)
  message('  ', nrow(imports), ' import flows loaded')
  return(imports)
}


#' Save daily series outputs to disk
#'
#' @param daily List from build_daily_aggregates()
#' @param out_dir Output directory
save_daily_outputs <- function(daily, out_dir = here('output', 'daily')) {
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

  write_csv(daily$daily_overall, file.path(out_dir, 'daily_overall.csv'))
  write_csv(daily$daily_by_country, file.path(out_dir, 'daily_by_country.csv'))
  write_csv(daily$daily_by_authority, file.path(out_dir, 'daily_by_authority.csv'))
  saveRDS(daily, file.path(out_dir, 'daily_aggregates.rds'))

  message('Outputs saved to: ', out_dir)
  message('  daily_overall.csv: ', nrow(daily$daily_overall), ' rows')
  message('  daily_by_country.csv: ', nrow(daily$daily_by_country), ' rows')
  message('  daily_by_authority.csv: ', nrow(daily$daily_by_authority), ' rows')
  message('  daily_aggregates.rds')
}


#' Run full daily series pipeline
#'
#' Loads import weights (if not provided), builds daily aggregates, saves outputs.
#' Called by 00_build_timeseries.R post-build and usable standalone.
#'
#' @param ts Timeseries tibble with valid_from/valid_until
#' @param imports Optional pre-loaded import weights; loaded if NULL
#' @param policy_params Optional policy params list (from load_policy_params())
#' @return Daily aggregates (invisible)
run_daily_series <- function(ts, imports = NULL, policy_params = NULL) {
  if (is.null(imports)) imports <- load_import_weights()
  daily <- build_daily_aggregates(ts, imports = imports, policy_params = policy_params)
  save_daily_outputs(daily)
  return(invisible(daily))
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

  if (!'valid_from' %in% names(ts)) {
    stop('Timeseries missing valid_from/valid_until columns.',
         '\nRebuild with: Rscript src/00_build_timeseries.R')
  }

  pp <- load_policy_params()
  run_daily_series(ts, policy_params = pp)

  message('\n', strrep('=', 70))
  message('DAILY SERIES COMPLETE')
  message(strrep('=', 70), '\n')
}
