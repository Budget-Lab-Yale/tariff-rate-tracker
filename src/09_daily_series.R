# =============================================================================
# Step 09: Daily Rate Series
# =============================================================================
#
# Provides pre-computed daily aggregates and on-demand expansion.
# Leverages the interval-encoded timeseries (valid_from / valid_until) built
# by 00_build_timeseries.R -- rates only change at revision boundaries, so
# we compute one aggregate per revision and broadcast across calendar days.
#
# Note: get_rates_at_date() is defined in helpers.R (shared with 08_weighted_etr.R).
#
# Core functions:
#   build_daily_aggregates(ts, date_range, imports, policy_params) - daily ETRs
#   expand_to_daily(ts, date_range, countries, products) - on-demand expansion
#   run_daily_series(ts, imports, policy_params) - full pipeline wrapper
#   run_alternative_series(ts, imports, pp, rebuild) - alternative daily series
#   build_alternative_timeseries(pp_override, variant, imports) - rebuild variant
#
# Usage:
#   # As library (source into other scripts):
#   source('src/09_daily_series.R')
#   source('src/helpers.R')
#   ts <- readRDS('data/timeseries/rate_timeseries.rds')
#   snapshot <- get_rates_at_date(ts, as.Date('2025-06-15'))
#
#   # Standalone:
#   Rscript src/09_daily_series.R
#
# =============================================================================

library(tidyverse)
library(jsonlite)


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
                                   policy_params = NULL,
                                   stacking_method = 'mutual_exclusion') {

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

  # China code for net authority decomposition
  CTY_CHINA <- if (!is.null(policy_params)) policy_params$CTY_CHINA %||% '5700' else '5700'

  # --- Policy expiry split points (Section 122, Swiss framework, etc.) ---
  # Uses shared helpers from helpers.R to detect all finalized=false overrides

  # Helper: compute aggregates for one revision interval (or sub-interval)
  compute_agg_overall <- function(revision, valid_from, valid_until, sub_start = valid_from) {
    rev_data <- ts %>% filter(revision == !!revision)
    rev_data <- apply_expiry_zeroing(rev_data, sub_start, policy_params)
    if (any(c('rate_s122', 'rate_ieepa_recip') %in% names(rev_data))) {
      rev_data <- apply_stacking_rules(rev_data, stacking_method = stacking_method)
    }
    n_products <- n_distinct(rev_data$hts10)
    n_countries <- n_distinct(rev_data$country)
    n_pairs <- nrow(rev_data)
    n_all_pairs <- n_products * n_countries

    row <- tibble(
      revision = revision,
      valid_from = valid_from,
      valid_until = valid_until,
      mean_additional_exposed = mean(rev_data$total_additional),
      mean_total_exposed = mean(rev_data$total_rate),
      mean_additional_all_pairs = sum(rev_data$total_additional) / n_all_pairs,
      mean_total_all_pairs = sum(rev_data$total_rate) / n_all_pairs,
      n_products = n_products,
      n_countries = n_countries,
      n_pairs = n_pairs,
      n_all_pairs = n_all_pairs
    )
    if (has_weights) {
      wt_data <- ts_weighted %>% filter(revision == !!revision)
      wt_data <- apply_expiry_zeroing(wt_data, sub_start, policy_params)
      if (nrow(wt_data) > 0) {
        wt_data <- apply_stacking_rules(wt_data, stacking_method = stacking_method)
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

  compute_agg_country <- function(revision, valid_from, valid_until, sub_start = valid_from) {
    rev_data <- ts %>% filter(revision == !!revision)
    rev_data <- apply_expiry_zeroing(rev_data, sub_start, policy_params)
    rev_data <- apply_stacking_rules(rev_data, stacking_method = stacking_method)
    n_products_rev <- n_distinct(rev_data$hts10)
    row <- rev_data %>%
      group_by(country) %>%
      summarise(
        mean_additional_exposed = mean(total_additional),
        mean_total_exposed = mean(total_rate),
        mean_additional_all_pairs = sum(total_additional) / n_products_rev,
        mean_total_all_pairs = sum(total_rate) / n_products_rev,
        n_products_present = n(),
        .groups = 'drop'
      ) %>%
      mutate(
        revision = revision, valid_from = valid_from, valid_until = valid_until,
        n_products_total = n_products_rev
      )
    if (has_weights) {
      wt_data <- ts_weighted %>% filter(revision == !!revision)
      wt_data <- apply_expiry_zeroing(wt_data, sub_start, policy_params)
      wt_data <- apply_stacking_rules(wt_data, stacking_method = stacking_method)
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

  compute_agg_authority <- function(revision, valid_from, valid_until, sub_start = valid_from) {
    rev_data <- ts %>% filter(revision == !!revision)
    rev_data <- apply_expiry_zeroing(rev_data, sub_start, policy_params)

    # Use shared net authority decomposition from helpers.R
    net_data <- compute_net_authority_contributions(rev_data, cty_china = CTY_CHINA,
                                                     stacking_method = stacking_method)

    row <- tibble(
      revision = revision,
      valid_from = valid_from,
      valid_until = valid_until,
      mean_232 = mean(net_data$net_232),
      mean_301 = mean(net_data$net_301),
      mean_ieepa = mean(net_data$net_ieepa),
      mean_fentanyl = mean(net_data$net_fentanyl),
      mean_s122 = mean(net_data$net_s122),
      mean_section_201 = mean(net_data$net_section_201),
      mean_other = mean(net_data$net_other)
    )
    if (has_weights) {
      wt_data <- ts_weighted %>% filter(revision == !!revision)
      wt_data <- apply_expiry_zeroing(wt_data, sub_start, policy_params)
      if (nrow(wt_data) > 0) {
        wt_net <- compute_net_authority_contributions(wt_data, cty_china = CTY_CHINA,
                                                      stacking_method = stacking_method)
        row$etr_232 <- sum(wt_net$net_232 * wt_net$imports) / total_imports
        row$etr_301 <- sum(wt_net$net_301 * wt_net$imports) / total_imports
        row$etr_ieepa <- sum(wt_net$net_ieepa * wt_net$imports) / total_imports
        row$etr_fentanyl <- sum(wt_net$net_fentanyl * wt_net$imports) / total_imports
        row$etr_s122 <- sum(wt_net$net_s122 * wt_net$imports) / total_imports
        row$etr_section_201 <- sum(wt_net$net_section_201 * wt_net$imports) / total_imports
        row$etr_other <- sum(wt_net$net_other * wt_net$imports) / total_imports
      } else {
        row$etr_232 <- row$etr_301 <- row$etr_ieepa <- row$etr_fentanyl <- 0
        row$etr_s122 <- row$etr_section_201 <- row$etr_other <- 0
      }
    }
    return(row)
  }

  # --- Per-revision aggregates (with generic expiry splitting) ---
  # Generic interval splitter: splits a revision interval at all expiry dates
  # and calls the aggregation function for each sub-interval
  split_and_aggregate <- function(agg_fn) {
    rev_intervals %>%
      pmap_dfr(function(revision, valid_from, valid_until) {
        splits <- get_expiry_split_points(valid_from, valid_until, policy_params)
        if (length(splits) == 0) {
          return(agg_fn(revision, valid_from, valid_until))
        }
        # Build sub-intervals: [valid_from, split1], [split1+1, split2], ..., [splitN+1, valid_until]
        boundaries <- c(valid_from, splits + 1)
        ends <- c(splits, valid_until)
        pmap_dfr(list(boundaries, ends), function(s, e) {
          agg_fn(revision, s, e, sub_start = s)
        })
      })
  }

  agg_overall <- split_and_aggregate(compute_agg_overall)
  agg_by_country <- split_and_aggregate(compute_agg_country)
  agg_by_authority <- split_and_aggregate(compute_agg_authority)

  # Log any expiry splits that occurred
  if (!is.null(policy_params)) {
    adjustments <- collect_expiry_adjustments(policy_params)
    for (adj in adjustments) {
      message('  ', adj$label, ' expiry split at ', adj$expiry_date)
    }
  }

  # --- Expand revision-level aggregates to daily ---
  # Iterate over revision intervals and replicate to each day (no fuzzyjoin needed)

  expand_intervals <- function(agg_df) {
    agg_df %>%
      pmap_dfr(function(...) {
        row <- tibble(...)
        start <- max(row$valid_from, date_range[1])
        end   <- min(row$valid_until, date_range[2])
        if (start > end) return(tibble())
        dates <- seq(start, end, by = 'day')
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
#' @param policy_params Optional policy params list. If supplied, applies the
#'   same post-interval expiry adjustments used by export_daily_slice().
#' @return Tibble with one row per date x product x country
expand_to_daily <- function(ts, date_range, countries, products, policy_params = NULL) {
  date_range <- as.Date(date_range)

  stopifnot(
    length(countries) > 0,
    length(products) > 0,
    length(date_range) == 2
  )

  expanded <- export_daily_slice(
    ts = ts,
    date_range = date_range,
    countries = countries,
    products = products,
    policy_params = policy_params,
    full_export = FALSE,
    output_path = NULL,
    columns = NULL
  )

  subset <- ts %>%
    filter(
      country %in% countries,
      hts10 %in% products,
      valid_until >= date_range[1],
      valid_from <= date_range[2]
    )

  message('Expanded ', nrow(subset), ' interval rows to ', nrow(expanded), ' daily rows')
  message('  Countries: ', n_distinct(expanded$country),
          ', Products: ', n_distinct(expanded$hts10),
          ', Days: ', n_distinct(expanded$date))

  return(expanded)
}


# =============================================================================
# Daily Slice Export
# =============================================================================

#' Export a filtered slice of the daily timeseries
#'
#' Extracts product-country-date level data from the interval-encoded timeseries
#' for a specified date range, with optional country/product filters.
#' Applies post-interval adjustments (Section 122 expiry, Swiss framework expiry).
#'
#' Safety: requires either explicit filters OR full_export = TRUE to prevent
#' accidental full expansion (~4.5M rows/revision x 730 days).
#'
#' @param ts Interval-encoded timeseries tibble
#' @param date_range Length-2 Date vector (start, end)
#' @param countries Optional character vector of country codes
#' @param products Optional character vector of HTS10 codes (or prefixes)
#' @param policy_params Policy params list (for post-interval adjustments)
#' @param output_path Output file path (.csv or .parquet). NULL = return only.
#' @param full_export Set TRUE to export without filters (safety override)
#' @param columns Optional character vector of columns to include in output.
#'   Default: narrow schema (date, hts10, country, rate columns, revision).
#' @return Exported tibble (invisibly if output_path is given)
export_daily_slice <- function(ts, date_range, countries = NULL, products = NULL,
                                policy_params = NULL, output_path = NULL,
                                full_export = FALSE, columns = NULL) {
  date_range <- as.Date(date_range)
  stopifnot(length(date_range) == 2, date_range[1] <= date_range[2])

  # Safety check
  if (is.null(countries) && is.null(products) && !full_export) {
    stop('export_daily_slice: must provide countries, products, or set full_export = TRUE.\n',
         'A full export produces billions of rows. Pass full_export = TRUE if intended.')
  }

  # Filter timeseries
  subset <- ts
  if (!is.null(countries)) subset <- subset %>% filter(country %in% countries)
  if (!is.null(products)) {
    # Support both exact codes and prefix matching
    if (any(nchar(products) < 10)) {
      prefix_pattern <- paste0('^(', paste(products, collapse = '|'), ')')
      subset <- subset %>% filter(grepl(prefix_pattern, hts10))
    } else {
      subset <- subset %>% filter(hts10 %in% products)
    }
  }

  if (nrow(subset) == 0) {
    warning('No matching rows for the requested filters')
    return(tibble())
  }

  # Clip intervals to requested date range
  subset <- subset %>%
    filter(valid_until >= date_range[1], valid_from <= date_range[2])

  # Collect expiry split points across the full date range
  split_dates <- if (!is.null(policy_params)) {
    adjustments <- collect_expiry_adjustments(policy_params)
    exp_dates <- map(adjustments, ~ as.Date(.$expiry_date))
    exp_dates <- exp_dates[exp_dates >= date_range[1] & exp_dates <= date_range[2]]
    sort(unique(as.Date(unlist(exp_dates), origin = '1970-01-01')))
  } else {
    as.Date(character())
  }

  # Expand intervals to daily, applying expiry adjustments per sub-interval
  calendar <- tibble(date = seq(date_range[1], date_range[2], by = 'day'))

  expanded <- subset %>%
    cross_join(calendar) %>%
    filter(date >= valid_from, date <= valid_until)

  # Apply post-interval adjustments (bulk by date partitions)
  if (length(split_dates) > 0 && nrow(expanded) > 0) {
    # Partition rows and apply zeroing to rows past each expiry
    for (adj in collect_expiry_adjustments(policy_params)) {
      exp <- as.Date(adj$expiry_date)
      if (adj$column %in% names(expanded)) {
        if (!is.null(adj$countries)) {
          expanded <- expanded %>%
            mutate(!!adj$column := if_else(
              date > exp & country %in% adj$countries, 0, .data[[adj$column]]))
        } else {
          expanded <- expanded %>%
            mutate(!!adj$column := if_else(date > exp, 0, .data[[adj$column]]))
        }
      }
    }
    # Recompute totals (pass cty_china from policy_params for correct stacking)
    cty_china <- if (!is.null(policy_params)) policy_params$CTY_CHINA %||% '5700' else '5700'
    expanded <- apply_stacking_rules(expanded, cty_china = cty_china)
  }

  # Select output columns
  default_columns <- c('date', 'hts10', 'country', 'base_rate',
                        'rate_232', 'rate_301', 'rate_ieepa_recip', 'rate_ieepa_fent',
                        'rate_s122', 'rate_section_201', 'rate_other',
                        'total_additional', 'total_rate', 'revision')
  out_cols <- if (!is.null(columns)) columns else default_columns
  out_cols <- intersect(out_cols, names(expanded))
  result <- expanded %>% select(all_of(out_cols))

  n_rows <- nrow(result)
  message('Exported ', n_rows, ' daily rows (',
          n_distinct(result$country), ' countries, ',
          n_distinct(result$hts10), ' products, ',
          n_distinct(result$date), ' days)')

  # Write output
  if (!is.null(output_path)) {
    ext <- tools::file_ext(output_path)
    dir_path <- dirname(output_path)
    if (!dir.exists(dir_path)) dir.create(dir_path, recursive = TRUE)

    if (ext == 'parquet' && requireNamespace('arrow', quietly = TRUE)) {
      arrow::write_parquet(result, output_path)
      message('Wrote ', output_path, ' (Parquet, ', round(file.size(output_path) / 1e6, 1), ' MB)')
    } else {
      if (ext == 'parquet') message('arrow package not available, falling back to CSV')
      csv_path <- if (ext == 'parquet') sub('\\.parquet$', '.csv', output_path) else output_path
      write_csv(result, csv_path)
      message('Wrote ', csv_path, ' (CSV, ', round(file.size(csv_path) / 1e6, 1), ' MB)')
    }
    return(invisible(result))
  }

  return(result)
}


# =============================================================================
# Reusable Wrappers (called by 00_build_timeseries.R post-build)
# =============================================================================

#' Load import weights for daily series weighting
#'
#' @param imports_path Path to hs10_by_country_gtap RDS (default: from local_paths config)
#' @return Tibble with hs10, cty_code, imports; or NULL if unavailable
load_import_weights <- function(imports_path = NULL) {
  if (is.null(imports_path)) {
    local_paths <- load_local_paths()
    imports_path <- local_paths$import_weights
  }
  if (is.null(imports_path)) {
    message('Import weights not configured in config/local_paths.yaml — computing unweighted means only')
    return(NULL)
  }
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


#' Save daily series to an Excel workbook
#'
#' Writes daily_overall, daily_by_country, and daily_by_authority as separate
#' sheets. Overwrites individual sheets without touching the rest of the
#' workbook. Creates the workbook with a README sheet if it does not exist.
#'
#' @param daily List from build_daily_aggregates()
#' @param xlsx_path Path to the Excel workbook
save_daily_workbook <- function(daily, xlsx_path) {
  library(openxlsx)

  data_sheets <- list(
    daily_overall     = daily$daily_overall,
    daily_by_country  = daily$daily_by_country,
    daily_by_authority = daily$daily_by_authority
  )

  # Load existing workbook or create a new one
  if (file.exists(xlsx_path)) {
    wb <- loadWorkbook(xlsx_path)
  } else {
    wb <- createWorkbook()
  }

  # Overwrite each data sheet (remove then re-add to clear old data)
  for (sheet_name in names(data_sheets)) {
    if (sheet_name %in% names(wb)) removeWorksheet(wb, sheet_name)
    addWorksheet(wb, sheet_name)
    writeData(wb, sheet_name, data_sheets[[sheet_name]])
  }

  # Write README sheet (only if it doesn't exist yet)
  if (!'README' %in% names(wb)) {
    addWorksheet(wb, 'README')
    readme <- build_daily_workbook_readme()
    writeData(wb, 'README', readme, headerStyle = createStyle(textDecoration = 'bold'))
  }

  # Ensure README is the first sheet
  sheet_order <- c('README', setdiff(names(wb), 'README'))
  worksheetOrder(wb) <- match(sheet_order, names(wb))

  saveWorkbook(wb, xlsx_path, overwrite = TRUE)
}


#' Build README content for the daily workbook
#'
#' @return Data frame describing each sheet and its variables
build_daily_workbook_readme <- function() {
  rows <- list(
    # --- Header ---
    c('Tariff Rate Tracker — Daily Aggregates Workbook', ''),
    c('', ''),
    c('Generated by src/09_daily_series.R. Sheets are overwritten on each build.', ''),
    c(paste0('Last updated: ', Sys.Date()), ''),
    c('', ''),

    # --- daily_overall ---
    c('=== Sheet: daily_overall ===', ''),
    c('Daily aggregate tariff rates across all products and countries.', ''),
    c('Variable', 'Description'),
    c('date', 'Calendar date'),
    c('revision', 'HTS revision identifier (e.g., rev_7, 2026_rev_4)'),
    c('mean_additional_exposed', 'Mean additional tariff rate across tariffed product-country pairs only'),
    c('mean_total_exposed', 'Mean total tariff rate (base + additional) across tariffed pairs only'),
    c('mean_additional_all_pairs', 'Mean additional tariff rate across full Cartesian panel (missing pairs = 0)'),
    c('mean_total_all_pairs', 'Mean total tariff rate across full Cartesian panel (missing pairs = 0)'),
    c('n_products', 'Number of distinct HTS-10 products in the revision'),
    c('n_countries', 'Number of distinct countries in the revision'),
    c('n_pairs', 'Number of tariffed product-country pairs (sparse panel)'),
    c('n_all_pairs', 'Total product-country pairs in full Cartesian panel (n_products x n_countries)'),
    c('weighted_etr', 'Import-weighted effective tariff rate (total rate); NA if no import weights'),
    c('weighted_etr_additional', 'Import-weighted effective tariff rate (additional duties only)'),
    c('matched_imports_b', 'Total imports ($B) matched to tariff data'),
    c('total_imports_b', 'Total imports ($B) in the weight file'),
    c('', ''),

    # --- daily_by_country ---
    c('=== Sheet: daily_by_country ===', ''),
    c('Daily aggregate tariff rates by country.', ''),
    c('Variable', 'Description'),
    c('date', 'Calendar date'),
    c('country', 'Census country code (4-digit)'),
    c('country_name', 'Country name (from census_codes.csv)'),
    c('country_abbr', 'Partner group abbreviation (e.g., china, eu, canada, row)'),
    c('mean_additional_exposed', 'Mean additional tariff rate across tariffed products for this country'),
    c('mean_total_exposed', 'Mean total tariff rate across tariffed products for this country'),
    c('mean_additional_all_pairs', 'Mean additional tariff rate using all products as denominator'),
    c('mean_total_all_pairs', 'Mean total tariff rate using all products as denominator'),
    c('n_products_present', 'Number of products with nonzero tariffs for this country'),
    c('revision', 'HTS revision identifier'),
    c('n_products_total', 'Total products in the revision (denominator for all_pairs means)'),
    c('weighted_etr', 'Import-weighted ETR for this country; NA if no import weights'),
    c('', ''),

    # --- daily_by_authority ---
    c('=== Sheet: daily_by_authority ===', ''),
    c('Daily tariff rate decomposition by tariff authority.', ''),
    c('Variable', 'Description'),
    c('date', 'Calendar date'),
    c('revision', 'HTS revision identifier'),
    c('mean_232', 'Mean net Section 232 contribution (steel, aluminum, autos, copper, derivatives)'),
    c('mean_301', 'Mean net Section 301 contribution (China only)'),
    c('mean_ieepa', 'Mean net IEEPA reciprocal contribution (mutual exclusion with 232)'),
    c('mean_fentanyl', 'Mean net IEEPA fentanyl contribution (CA, MX, CN)'),
    c('mean_s122', 'Mean net Section 122 contribution (post-IEEPA invalidation, 150-day limit)'),
    c('mean_section_201', 'Mean net Section 201 contribution (safeguard duties, very small)'),
    c('mean_other', 'Mean net other tariff contribution'),
    c('etr_232', 'Import-weighted ETR contribution from Section 232'),
    c('etr_301', 'Import-weighted ETR contribution from Section 301'),
    c('etr_ieepa', 'Import-weighted ETR contribution from IEEPA reciprocal'),
    c('etr_fentanyl', 'Import-weighted ETR contribution from IEEPA fentanyl'),
    c('etr_s122', 'Import-weighted ETR contribution from Section 122'),
    c('etr_section_201', 'Import-weighted ETR contribution from Section 201'),
    c('etr_other', 'Import-weighted ETR contribution from other authorities'),
    c('', ''),

    # --- Notes ---
    c('=== Notes ===', ''),
    c('Exposed means: denominator is only product-country pairs with nonzero tariffs.', ''),
    c('All-pairs means: denominator is the full Cartesian panel (products x countries); untariffed pairs contribute 0.', ''),
    c('Weighted ETR: uses 2024 Census import values as weights; total imports denominator includes all flows.', ''),
    c('Net authority contributions sum to total_additional (after stacking and mutual exclusion rules).', ''),
    c('Source: Yale Budget Lab Tariff Rate Tracker, built from USITC HTS archives.', '')
  )

  df <- do.call(rbind, lapply(rows, function(r) data.frame(Column = r[1], Description = r[2], stringsAsFactors = FALSE)))
  return(df)
}


#' Save daily series outputs to disk
#'
#' @param daily List from build_daily_aggregates()
#' @param out_dir Output directory
save_daily_outputs <- function(daily, out_dir = here('output', 'daily')) {
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

  write_csv(daily$daily_overall, file.path(out_dir, 'daily_overall.csv'))

  # Add country names to by-country output
  census_codes_path <- here('resources', 'census_codes.csv')
  if (file.exists(census_codes_path)) {
    census_codes <- read_csv(census_codes_path, col_types = cols(.default = col_character())) %>%
      rename(country = Code, country_name = Name)
    partner_path <- here('resources', 'country_partner_mapping.csv')
    if (file.exists(partner_path)) {
      partners <- read_csv(partner_path, col_types = cols(.default = col_character())) %>%
        select(cty_code, partner) %>%
        rename(country = cty_code, country_abbr = partner)
      census_codes <- census_codes %>% left_join(partners, by = 'country')
    }
    daily$daily_by_country <- daily$daily_by_country %>%
      left_join(census_codes, by = 'country') %>%
      relocate(country_name, .after = country) %>%
      relocate(any_of('country_abbr'), .after = country_name)
  }
  write_csv(daily$daily_by_country, file.path(out_dir, 'daily_by_country.csv'))
  write_csv(daily$daily_by_authority, file.path(out_dir, 'daily_by_authority.csv'))
  saveRDS(daily, file.path(out_dir, 'daily_aggregates.rds'))

  # --- Excel workbook (overwrite individual sheets, preserve workbook) ---
  xlsx_path <- file.path(out_dir, 'daily_workbook.xlsx')
  if (requireNamespace('openxlsx', quietly = TRUE)) {
    save_daily_workbook(daily, xlsx_path)
  }

  message('Outputs saved to: ', out_dir)
  message('  daily_overall.csv: ', nrow(daily$daily_overall), ' rows')
  message('  daily_by_country.csv: ', nrow(daily$daily_by_country), ' rows')
  message('  daily_by_authority.csv: ', nrow(daily$daily_by_authority), ' rows')
  message('  daily_aggregates.rds')
  if (requireNamespace('openxlsx', quietly = TRUE)) message('  daily_workbook.xlsx')
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
# Alternative Daily Series
# =============================================================================

#' Save a single alternative daily output to output/alternative/
#'
#' @param daily_overall Daily overall tibble (from build_daily_aggregates)
#' @param variant Character variant name (e.g., 'no_ieepa')
#' @param out_dir Output directory
save_alternative_output <- function(daily_overall, variant,
                                     out_dir = here('output', 'alternative')) {
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
  daily_overall <- daily_overall %>% mutate(variant = variant)
  fname <- paste0('daily_overall_', variant, '.csv')
  write_csv(daily_overall, file.path(out_dir, fname))
  message('  Saved: ', fname, ' (', nrow(daily_overall), ' rows)')
}


#' Build alternative timeseries with modified policy params (rebuild variant)
#'
#' Re-runs the full rate calculation loop (all revisions) with a modified
#' policy_params list, then builds daily aggregates. This is slow — only
#' called when --with-alternatives is passed.
#'
#' Temporarily overrides the module-level .pp in 06_calculate_rates.R's
#' environment, then restores it.
#'
#' @param pp_override Modified policy_params list
#' @param variant_name Character variant name
#' @param imports Import weights tibble (or NULL)
#' @param archive_dir HTS archive directory
#' @param revision_dates_path Path to revision_dates.csv
#' @param census_codes_path Path to census_codes.csv
#' @return Daily overall tibble (invisibly)
build_alternative_timeseries <- function(pp_override, variant_name, imports = NULL,
                                          archive_dir = here('data', 'hts_archives'),
                                          revision_dates_path = here('config', 'revision_dates.csv'),
                                          census_codes_path = here('resources', 'census_codes.csv')) {

  message('\n  Building alternative timeseries: ', variant_name)

  # Ensure pipeline components are sourced (needed for standalone use)
  if (!exists('calculate_rates_for_revision', mode = 'function')) {
    source(here('src', '03_parse_chapter99.R'))
    source(here('src', '04_parse_products.R'))
    source(here('src', '05_parse_policy_params.R'))
    source(here('src', '06_calculate_rates.R'))
  }

  # Save original .pp and swap in override
  calc_env <- environment(calculate_rates_for_revision)
  original_pp <- calc_env$.pp
  calc_env$.pp <- pp_override
  on.exit(calc_env$.pp <- original_pp, add = TRUE)

  # Load revision dates and country codes
  rev_dates <- load_revision_dates(revision_dates_path)
  census_codes <- read_csv(census_codes_path, col_types = cols(.default = col_character()))
  countries <- census_codes$Code
  country_lookup <- build_country_lookup(census_codes_path)

  all_revisions <- rev_dates$revision
  available <- get_available_revisions_all_years(all_revisions, archive_dir)
  revisions_to_process <- all_revisions[all_revisions %in% available]

  # Process each revision
  snapshots <- list()
  for (rev_id in revisions_to_process) {
    rev_info <- rev_dates %>% filter(revision == rev_id)
    eff_date <- rev_info$effective_date

    tryCatch({
      json_path <- resolve_json_path(rev_id, archive_dir)
      hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)
      ch99_data <- parse_chapter99(json_path)
      products <- parse_products(json_path)
      ieepa_rates <- extract_ieepa_rates(hts_raw, country_lookup)
      fentanyl_rates <- extract_ieepa_fentanyl_rates(hts_raw, country_lookup)
      s232_rates <- extract_section232_rates(ch99_data)
      usmca <- extract_usmca_eligibility(hts_raw)

      rates <- calculate_rates_for_revision(
        products, ch99_data, ieepa_rates, usmca,
        countries, rev_id, eff_date,
        s232_rates = s232_rates,
        fentanyl_rates = fentanyl_rates
      )
      snapshots[[rev_id]] <- rates
    }, error = function(e) {
      message('    SKIP ', rev_id, ': ', conditionMessage(e))
    })
  }

  if (length(snapshots) == 0) {
    warning('No snapshots built for variant: ', variant_name)
    return(invisible(tibble()))
  }

  # Combine into timeseries with valid_from/valid_until
  timeseries <- bind_rows(snapshots)
  timeseries <- enforce_rate_schema(timeseries)
  timeseries <- timeseries %>% arrange(effective_date, revision, country, hts10)

  horizon_end <- pp_override$SERIES_HORIZON_END %||% Sys.Date()
  last_eff <- max(rev_dates$effective_date[rev_dates$revision %in% unique(timeseries$revision)])
  if (horizon_end < last_eff) horizon_end <- last_eff

  rev_intervals <- rev_dates %>%
    filter(revision %in% unique(timeseries$revision)) %>%
    arrange(effective_date) %>%
    mutate(
      valid_from = effective_date,
      valid_until = lead(effective_date) - 1
    ) %>%
    mutate(valid_until = if_else(is.na(valid_until), horizon_end, valid_until)) %>%
    select(revision, valid_from, valid_until)

  timeseries <- timeseries %>%
    select(-any_of(c('valid_from', 'valid_until'))) %>%
    left_join(rev_intervals, by = 'revision')

  # Build daily aggregates
  daily <- build_daily_aggregates(timeseries, imports = imports, policy_params = pp_override)
  save_alternative_output(daily$daily_overall, variant_name)

  message('  Done: ', variant_name)
  return(invisible(daily$daily_overall))
}


#' Run all alternative daily series
#'
#' Post-build alternatives (fast): apply scenarios to existing timeseries,
#' then build daily aggregates. Always runs.
#'
#' TPC stacking alternative: re-applies stacking with 'tpc_additive' method.
#'
#' Rebuild alternatives (slow): re-run full calculation with modified policy
#' params. Only runs when rebuild = TRUE.
#'
#' @param ts Timeseries tibble with valid_from/valid_until
#' @param imports Import weights tibble (or NULL)
#' @param policy_params Policy params list
#' @param rebuild Logical; if TRUE, also run rebuild alternatives
#' @return Invisible NULL
run_alternative_series <- function(ts, imports = NULL, policy_params = NULL,
                                    rebuild = FALSE) {

  message('\n', strrep('=', 70))
  message('ALTERNATIVE DAILY SERIES')
  message(strrep('=', 70))

  if (is.null(imports)) imports <- load_import_weights()

  # Ensure apply_scenario is available
  if (!exists('apply_scenario', mode = 'function')) {
    source(here('src', 'apply_scenarios.R'))
  }
  scenarios_path <- here('config', 'scenarios.yaml')

  # --- Post-build alternatives (scenario-based) ---
  # These zero out authorities on the existing timeseries and re-aggregate.
  post_build_scenarios <- c('no_ieepa', 'no_ieepa_recip', 'no_301',
                             'no_232', 'no_s122', 'pre_2025')

  for (scenario_name in post_build_scenarios) {
    tryCatch({
      message('\n  Scenario: ', scenario_name)
      ts_scenario <- apply_scenario(ts, scenario_name, scenarios_path)
      daily <- build_daily_aggregates(ts_scenario, imports = imports,
                                       policy_params = policy_params)
      save_alternative_output(daily$daily_overall, scenario_name)
    }, error = function(e) {
      message('  FAILED (', scenario_name, '): ', conditionMessage(e))
    })
  }

  # --- TPC stacking alternative ---
  tryCatch({
    message('\n  Alternative: tpc_stacking')
    ts_tpc <- apply_stacking_rules(ts, stacking_method = 'tpc_additive')
    ts_tpc <- enforce_rate_schema(ts_tpc)
    daily <- build_daily_aggregates(ts_tpc, imports = imports,
                                     policy_params = policy_params,
                                     stacking_method = 'tpc_additive')
    save_alternative_output(daily$daily_overall, 'tpc_stacking')
  }, error = function(e) {
    message('  FAILED (tpc_stacking): ', conditionMessage(e))
  })

  # --- Rebuild alternatives (only with --with-alternatives) ---
  if (rebuild) {
    message('\n  Running rebuild alternatives (this will take a while)...')
    pp <- policy_params %||% load_policy_params()

    # 1a. USMCA 2024 shares (pre-tariff steady-state)
    tryCatch({
      pp_usmca <- pp
      pp_usmca$USMCA_SHARES$year <- 2024
      pp_usmca$USMCA_SHARES$mode <- 'annual'
      pp_usmca$usmca_shares$year <- 2024
      pp_usmca$usmca_shares$mode <- 'annual'
      build_alternative_timeseries(pp_usmca, 'usmca_2024', imports = imports)
    }, error = function(e) {
      message('  FAILED (usmca_2024): ', conditionMessage(e))
    })

    # 1b. USMCA monthly 2025 shares (per-revision month)
    tryCatch({
      pp_usmca_m <- pp
      pp_usmca_m$USMCA_SHARES$mode <- 'monthly'
      pp_usmca_m$USMCA_SHARES$year <- 2025
      pp_usmca_m$usmca_shares$mode <- 'monthly'
      pp_usmca_m$usmca_shares$year <- 2025
      build_alternative_timeseries(pp_usmca_m, 'usmca_monthly', imports = imports)
    }, error = function(e) {
      message('  FAILED (usmca_monthly): ', conditionMessage(e))
    })

    # 2. Flat metal content
    tryCatch({
      pp_metal <- pp
      pp_metal$metal_content$method <- 'flat'
      build_alternative_timeseries(pp_metal, 'metal_flat', imports = imports)
    }, error = function(e) {
      message('  FAILED (metal_flat): ', conditionMessage(e))
    })

    # 3. Nonzero duty-free treatment (sensitivity analysis: exclude 0% MFN from IEEPA)
    tryCatch({
      pp_dutyfree <- pp
      pp_dutyfree$ieepa_duty_free_treatment <- 'nonzero_base_only'
      build_alternative_timeseries(pp_dutyfree, 'dutyfree_nonzero', imports = imports)
    }, error = function(e) {
      message('  FAILED (dutyfree_nonzero): ', conditionMessage(e))
    })
  }

  message('\n', strrep('=', 70))
  message('ALTERNATIVE SERIES COMPLETE')
  message(strrep('=', 70), '\n')

  return(invisible(NULL))
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
