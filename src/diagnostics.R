# =============================================================================
# Step 10: Diagnostics
# =============================================================================
#
# Diagnostic reports for the tariff rate time series:
#   1. Section 301 coverage gap analysis
#   2. China IEEPA rate tracking across revisions
#   3. Per-revision summary statistics
#
# =============================================================================

library(tidyverse)

# Country code constants (loaded from YAML via helpers.R)
.pp_09 <- tryCatch(load_policy_params(), error = function(e) NULL)
CTY_CHINA <- if (!is.null(.pp_09)) .pp_09$CTY_CHINA else '5700'


# =============================================================================
# Section 301 Coverage Gap
# =============================================================================

#' Report Section 301 coverage gap vs TPC
#'
#' For China, identifies products where TPC_rate - our_rate ≈ 0.25 (consistent
#' with missing Section 301 coverage). Does NOT fix the gap — the HTS footnotes
#' are our source of truth.
#'
#' @param our_rates Our calculated rates (single revision or timeseries)
#' @param tpc_path Path to TPC data
#' @param census_codes Census codes data frame
#' @param target_date TPC date to compare against (optional; uses latest if NULL)
#' @return List with gap_products, summary, and n_affected
report_301_coverage_gap <- function(our_rates, tpc_path, census_codes, target_date = NULL) {
  message('\n=== Section 301 Coverage Gap Analysis ===\n')

  source('src/08_validate_tpc.R', local = TRUE)

  name_to_code <- create_country_name_map(census_codes)
  tpc_data <- load_tpc_data(tpc_path, name_to_code)

  # Use latest TPC date if not specified
  if (is.null(target_date)) {
    target_date <- max(tpc_data$date)
  }
  target_date <- as.Date(target_date)

  # Filter to China only
  china_rates <- our_rates %>%
    filter(country == CTY_CHINA)

  tpc_china <- tpc_data %>%
    filter(country_code == CTY_CHINA, date == target_date) %>%
    select(hts10, tpc_rate = tpc_rate_change)

  comparison <- china_rates %>%
    select(hts10, our_rate = total_additional, rate_301) %>%
    inner_join(tpc_china, by = 'hts10') %>%
    mutate(
      gap = tpc_rate - our_rate,
      abs_gap = abs(gap),
      # Flag products where gap is ~25% (consistent with missing 301)
      likely_301_gap = abs(gap - 0.25) < 0.03 & rate_301 == 0,
      chapter = substr(hts10, 1, 2)
    )

  # Products with likely 301 gap
  gap_products <- comparison %>%
    filter(likely_301_gap) %>%
    arrange(chapter, hts10)

  # Summary by chapter
  gap_by_chapter <- gap_products %>%
    count(chapter, name = 'n_products') %>%
    arrange(desc(n_products))

  # Report
  cat('Target TPC date: ', as.character(target_date), '\n')
  cat('China products compared: ', nrow(comparison), '\n')
  cat('Products with ~25% gap (likely missing 301): ', nrow(gap_products), '\n')
  cat('  (', round(100 * nrow(gap_products) / nrow(comparison), 1), '% of China products)\n')

  if (nrow(gap_by_chapter) > 0) {
    cat('\nAffected chapters:\n')
    print(gap_by_chapter, n = 20)
  }

  return(list(
    gap_products = gap_products,
    by_chapter = gap_by_chapter,
    n_affected = nrow(gap_products),
    n_compared = nrow(comparison)
  ))
}


# =============================================================================
# China IEEPA Tracking
# =============================================================================

#' Report China IEEPA rate history across revisions
#'
#' Reads all snapshots and extracts China's IEEPA reciprocal rate at each
#' revision point. Validates against the known policy timeline.
#'
#' @param timeseries_dir Directory containing snapshot RDS files
#' @return Tibble with revision, effective_date, china_ieepa_rate, n_products
report_china_ieepa_history <- function(timeseries_dir = 'data/timeseries') {
  message('\n=== China IEEPA Rate History ===\n')

  snapshot_files <- list.files(timeseries_dir, pattern = '^snapshot_.*\\.rds$', full.names = TRUE)

  if (length(snapshot_files) == 0) {
    message('No snapshot files found in ', timeseries_dir)
    return(tibble())
  }

  history <- map_dfr(snapshot_files, function(f) {
    snapshot <- tryCatch(readRDS(f), error = function(e) NULL)
    if (is.null(snapshot) || nrow(snapshot) == 0) return(NULL)

    china <- snapshot %>% filter(country == CTY_CHINA)
    if (nrow(china) == 0) return(NULL)

    tibble(
      revision = china$revision[1],
      effective_date = china$effective_date[1],
      china_ieepa_recip = mean(china$rate_ieepa_recip),
      china_ieepa_fent = mean(china$rate_ieepa_fent),
      china_total_additional = mean(china$total_additional),
      n_products = nrow(china),
      n_with_ieepa = sum(china$rate_ieepa_recip > 0)
    )
  })

  if (nrow(history) == 0) {
    message('No China data found in snapshots.')
    return(tibble())
  }

  history <- history %>% arrange(effective_date)

  # Print
  cat('Revision history of China tariff rates:\n\n')
  print(history, n = Inf)

  # Validate against known timeline
  cat('\n--- Policy Timeline Validation ---\n')

  # Pre-IEEPA revisions should have 0 reciprocal
  pre_ieepa <- history %>% filter(china_ieepa_recip == 0)
  post_ieepa <- history %>% filter(china_ieepa_recip > 0)

  cat('Revisions with zero China IEEPA: ', nrow(pre_ieepa), '\n')
  cat('Revisions with nonzero China IEEPA: ', nrow(post_ieepa), '\n')

  if (nrow(post_ieepa) > 0) {
    cat('First nonzero: ', post_ieepa$revision[1],
        ' (', as.character(post_ieepa$effective_date[1]), ')\n')
    cat('Rate range: ', round(min(post_ieepa$china_ieepa_recip) * 100, 1), '% - ',
        round(max(post_ieepa$china_ieepa_recip) * 100, 1), '%\n')
  }

  return(history)
}


# =============================================================================
# Per-Revision Summary
# =============================================================================

#' Report summary statistics for each revision
#'
#' For each revision: number of Ch99 entries, products with duties, mean
#' additional rate by top countries. Highlights revisions with large changes.
#'
#' @param timeseries_dir Directory containing snapshot and delta RDS files
#' @return Tibble with per-revision summary
report_revision_summary <- function(timeseries_dir = 'data/timeseries') {
  message('\n=== Per-Revision Summary ===\n')

  snapshot_files <- list.files(timeseries_dir, pattern = '^snapshot_.*\\.rds$', full.names = TRUE)

  if (length(snapshot_files) == 0) {
    message('No snapshot files found in ', timeseries_dir)
    return(tibble())
  }

  summary <- map_dfr(snapshot_files, function(f) {
    snapshot <- tryCatch(readRDS(f), error = function(e) NULL)
    if (is.null(snapshot) || nrow(snapshot) == 0) return(NULL)

    rev_id <- snapshot$revision[1]
    eff_date <- snapshot$effective_date[1]

    # Overall stats
    overall <- tibble(
      revision = rev_id,
      effective_date = eff_date,
      n_product_country = nrow(snapshot),
      n_products = n_distinct(snapshot$hts10),
      n_countries_with_duties = n_distinct(snapshot$country),
      mean_additional = mean(snapshot$total_additional),
      max_additional = max(snapshot$total_additional),
      n_with_232 = sum(snapshot$rate_232 > 0),
      n_with_301 = sum(snapshot$rate_301 > 0),
      n_with_ieepa_recip = sum(snapshot$rate_ieepa_recip > 0),
      n_with_ieepa_fent = sum(snapshot$rate_ieepa_fent > 0)
    )

    # Load delta if available
    delta_file <- file.path(timeseries_dir, paste0('delta_', rev_id, '.rds'))
    if (file.exists(delta_file)) {
      delta <- readRDS(delta_file)
      overall$ch99_added <- delta$ch99$n_added
      overall$ch99_removed <- delta$ch99$n_removed
      overall$ch99_rate_changes <- delta$ch99$n_rate_changes
      overall$products_added <- delta$products$n_added
      overall$products_removed <- delta$products$n_removed
    } else {
      overall$ch99_added <- NA_integer_
      overall$ch99_removed <- NA_integer_
      overall$ch99_rate_changes <- NA_integer_
      overall$products_added <- NA_integer_
      overall$products_removed <- NA_integer_
    }

    return(overall)
  })

  summary <- summary %>% arrange(effective_date)

  cat('Per-revision summary:\n\n')
  print(summary %>% select(
    revision, effective_date, n_products, mean_additional,
    n_with_ieepa_recip, ch99_added, ch99_rate_changes
  ), n = Inf)

  # Highlight large changes
  if (any(!is.na(summary$ch99_added))) {
    large_changes <- summary %>%
      filter(!is.na(ch99_added)) %>%
      filter(ch99_added > 10 | ch99_rate_changes > 5)

    if (nrow(large_changes) > 0) {
      cat('\n--- Revisions with large changes ---\n')
      print(large_changes %>% select(
        revision, effective_date, ch99_added, ch99_removed, ch99_rate_changes
      ))
    }
  }

  return(summary)
}


#' Run all diagnostics
#'
#' @param timeseries_dir Directory with time series data
#' @param tpc_path Path to TPC data
#' @param census_codes_path Path to census codes
#' @param output_dir Directory for diagnostic reports
run_all_diagnostics <- function(
  timeseries_dir = 'data/timeseries',
  tpc_path = 'data/tpc/tariff_by_flow_day.csv',
  census_codes_path = 'resources/census_codes.csv',
  output_dir = 'output/diagnostics'
) {
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

  # 1. Per-revision summary
  rev_summary <- report_revision_summary(timeseries_dir)
  if (nrow(rev_summary) > 0) {
    write_csv(rev_summary, file.path(output_dir, 'revision_summary.csv'))
  }

  # 2. China IEEPA history
  china_history <- report_china_ieepa_history(timeseries_dir)
  if (nrow(china_history) > 0) {
    write_csv(china_history, file.path(output_dir, 'china_ieepa_history.csv'))
  }

  # 3. 301 coverage gap (use latest snapshot)
  if (file.exists(tpc_path)) {
    census_codes <- read_csv(census_codes_path, col_types = cols(.default = col_character()))

    # Use latest revision snapshot
    snapshot_files <- list.files(timeseries_dir, pattern = '^snapshot_.*\\.rds$', full.names = TRUE)
    if (length(snapshot_files) > 0) {
      latest <- snapshot_files[length(snapshot_files)]
      latest_rates <- readRDS(latest)

      gap_report <- report_301_coverage_gap(latest_rates, tpc_path, census_codes)
      if (gap_report$n_affected > 0) {
        write_csv(gap_report$gap_products, file.path(output_dir, '301_coverage_gap.csv'))
      }
    }
  }

  # 4. TPC discrepancy decomposition (if comparison file exists)
  decomp_path <- file.path('output', 'validation', 'tpc_comparison_all.csv')
  if (file.exists(decomp_path)) {
    decomp <- decompose_tpc_discrepancies(decomp_path)
    if (nrow(decomp$detail) > 0) {
      write_csv(decomp$detail, file.path(output_dir, 'tpc_discrepancy_decomposition.csv'))
      write_csv(decomp$summary, file.path(output_dir, 'tpc_discrepancy_summary.csv'))
    }
  }

  message('\nDiagnostics saved to ', output_dir)
}


# =============================================================================
# TPC Discrepancy Decomposition
# =============================================================================

#' Decompose TPC comparison mismatches into diagnostic categories
#'
#' Takes the combined TPC comparison CSV (from test_tpc_comparison.R) and
#' classifies each mismatch into one of:
#'   1. duty_free_ieepa: base=0, our recip>0, TPC=0 (we apply IEEPA to duty-free)
#'   2. s232_mutual_exclusion: 232>0, our recip=0, TPC higher (~25pp gap)
#'   3. floor_gap: floor country, we higher, non-duty-free
#'   4. usmca_diff: CA/MX, rate difference
#'   5. s301_gap: China, TPC higher, likely missing 301
#'   6. base_rate_parsing: compound rate shows as 0
#'   7. unclassified: everything else
#'
#' @param comparison_path Path to tpc_comparison_all.csv
#' @param revision_filter Optional revision to filter to (default: latest)
#' @return List with 'detail' (per-row classification) and 'summary' (counts)
decompose_tpc_discrepancies <- function(comparison_path, revision_filter = NULL) {
  message('\n=== TPC Discrepancy Decomposition ===\n')

  comp <- read_csv(comparison_path, col_types = cols(
    hts10 = col_character(), country = col_character(),
    .default = col_guess()
  ))

  # Filter to specific revision if requested, else use latest

  if (!is.null(revision_filter)) {
    comp <- comp %>% filter(revision == revision_filter)
  } else {
    latest_rev <- comp %>%
      distinct(revision) %>%
      pull(revision) %>%
      tail(1)
    comp <- comp %>% filter(revision == latest_rev)
    message('  Using revision: ', latest_rev)
  }

  # Load policy params for country classifications
  pp <- load_policy_params()
  floor_countries <- pp$FLOOR_COUNTRIES
  eu_codes <- pp$EU27_CODES

  # Classify each row
  comp <- comp %>%
    mutate(
      chapter = substr(hts10, 1, 2),
      is_floor_country = country %in% floor_countries,
      is_eu = country %in% eu_codes,
      is_japan = country == pp$country_codes$CTY_JAPAN,
      is_korea = country == pp$country_codes$CTY_SKOREA,
      is_swiss = country %in% c(pp$country_codes$CTY_SWITZERLAND,
                                 pp$country_codes$CTY_LIECHTENSTEIN),
      is_china = country == pp$CTY_CHINA,
      is_ca_mx = country %in% c(pp$CTY_CANADA, pp$CTY_MEXICO),
      # Mismatch direction
      we_higher = diff > 0.005,
      tpc_higher = diff < -0.005,
      is_match = abs(diff) < 0.005
    )

  # Classify mismatches into categories
  comp <- comp %>%
    mutate(
      category = case_when(
        is_match ~ 'match',
        # 1. Duty-free IEEPA: base=0, we charge IEEPA recip, TPC doesn't
        base_rate < 0.001 & rate_ieepa_recip > 0 & we_higher ~ 'duty_free_ieepa',
        # 2. 232 mutual exclusion: we have 232, TPC adds recip on top
        rate_232 > 0 & rate_ieepa_recip == 0 & tpc_higher &
          abs(diff + 0.25) < 0.06 ~ 's232_mutual_exclusion',
        rate_232 > 0 & rate_ieepa_recip == 0 & tpc_higher ~ 's232_mutual_exclusion_other',
        # 3. Floor gaps: floor country, non-duty-free, we higher
        is_floor_country & we_higher & base_rate >= 0.001 ~ 'floor_gap',
        # 4. USMCA differences
        is_ca_mx & !is_match ~ 'usmca_diff',
        # 5. 301 coverage gaps: China, TPC higher, our 301=0
        is_china & tpc_higher & rate_301 == 0 ~ 's301_gap',
        # 6. China other gaps
        is_china & !is_match ~ 'china_other',
        # 7. Floor country, TPC higher
        is_floor_country & tpc_higher ~ 'floor_tpc_higher',
        # 8. Everything else
        TRUE ~ 'unclassified'
      )
    )

  # Summary by category
  cat_summary <- comp %>%
    group_by(category) %>%
    summarise(
      n_pairs = n(),
      pct_of_total = round(n() / nrow(comp) * 100, 1),
      mean_diff_pp = round(mean(diff) * 100, 2),
      mean_abs_diff_pp = round(mean(abs_diff) * 100, 2),
      .groups = 'drop'
    ) %>%
    arrange(desc(n_pairs))

  cat('Discrepancy decomposition:\n\n')
  print(cat_summary, n = 20)

  # Duty-free breakdown by chapter
  df_products <- comp %>% filter(category == 'duty_free_ieepa')
  if (nrow(df_products) > 0) {
    cat('\n--- Duty-Free IEEPA by Chapter (top 10) ---\n')
    df_by_chapter <- df_products %>%
      count(chapter, name = 'n_pairs') %>%
      arrange(desc(n_pairs)) %>%
      head(10)
    print(df_by_chapter)

    cat('\nDuty-free IEEPA by country group:\n')
    df_by_group <- df_products %>%
      mutate(
        country_group = case_when(
          is_eu ~ 'EU-27',
          is_japan ~ 'Japan',
          is_korea ~ 'S. Korea',
          is_swiss ~ 'Swiss/Liecht.',
          is_china ~ 'China',
          TRUE ~ 'Other'
        )
      ) %>%
      count(country_group, name = 'n_pairs') %>%
      arrange(desc(n_pairs))
    print(df_by_group)
  }

  # 232 mutual exclusion breakdown
  s232_me <- comp %>% filter(grepl('s232_mutual_exclusion', category))
  if (nrow(s232_me) > 0) {
    cat('\n--- 232 Mutual Exclusion ---\n')
    cat('  Product-country pairs: ', nrow(s232_me), '\n')
    cat('  Mean gap: ', round(mean(s232_me$diff) * 100, 1), 'pp\n')
    cat('  Unique products: ', n_distinct(s232_me$hts10), '\n')
  }

  # Impact simulation
  n_total <- nrow(comp)
  n_match_current <- sum(comp$is_match)
  n_df_fixed <- nrow(df_products)
  simulated_match <- n_match_current + n_df_fixed
  cat('\n--- Impact Simulation ---\n')
  cat('  Current match rate: ', round(n_match_current / n_total * 100, 1), '%\n')
  cat('  If duty-free excluded: ', round(simulated_match / n_total * 100, 1), '%\n')
  cat('  Improvement: +', round(n_df_fixed / n_total * 100, 1), 'pp\n')

  detail <- comp %>%
    select(hts10, country, base_rate, rate_232, rate_301, rate_ieepa_recip,
           rate_ieepa_fent, rate_other, total_additional, tpc_rate, diff,
           abs_diff, category, chapter, revision)

  return(list(
    detail = detail,
    summary = cat_summary,
    n_total = n_total,
    n_match = n_match_current,
    n_duty_free = n_df_fixed,
    simulated_match_rate = simulated_match / n_total
  ))
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)
  source(here('src', 'helpers.R'))
  run_all_diagnostics()
}
