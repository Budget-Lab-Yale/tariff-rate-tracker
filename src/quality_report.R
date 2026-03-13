# =============================================================================
# Quality Report
# =============================================================================
#
# Reads rate_timeseries.rds and produces quality checks:
#   1. Schema check — column presence and NA counts
#   2. Revision quality — per-revision stats
#   3. Anomalies — suspicious jumps or values
#
# Usage:
#   Rscript src/quality_report.R
#
# Output:
#   output/quality/schema_check.csv
#   output/quality/revision_quality.csv
#   output/quality/anomalies.csv
#   output/quality/quality_report.rds
#
# =============================================================================

library(tidyverse)
library(here)

source(here('src', 'helpers.R'))


#' Run schema check on time series
#'
#' Verifies all expected columns exist and reports NA counts.
#'
#' @param ts Timeseries tibble
#' @return Tibble with column, present, n_na, pct_na
check_schema <- function(ts) {
  expected <- RATE_SCHEMA

  schema_check <- tibble(column = expected) %>%
    mutate(
      present = column %in% names(ts),
      n_na = map_int(column, function(col) {
        if (col %in% names(ts)) sum(is.na(ts[[col]])) else NA_integer_
      }),
      n_rows = nrow(ts),
      pct_na = round(n_na / n_rows * 100, 2)
    )

  # Check for unexpected columns
  extra <- setdiff(names(ts), expected)
  if (length(extra) > 0) {
    extra_rows <- tibble(
      column = extra,
      present = TRUE,
      n_na = map_int(extra, function(col) sum(is.na(ts[[col]]))),
      n_rows = nrow(ts),
      pct_na = round(n_na / n_rows * 100, 2)
    )
    schema_check <- bind_rows(
      schema_check %>% mutate(status = 'expected'),
      extra_rows %>% mutate(status = 'extra')
    )
  } else {
    schema_check <- schema_check %>% mutate(status = 'expected')
  }

  return(schema_check)
}


#' Compute per-revision quality stats
#'
#' @param ts Timeseries tibble
#' @return Tibble with one row per revision
compute_revision_quality <- function(ts) {
  ts %>%
    group_by(revision, effective_date) %>%
    summarise(
      n_products = n_distinct(hts10),
      n_countries = n_distinct(country),
      n_rows = n(),
      mean_base_rate = round(mean(base_rate, na.rm = TRUE), 4),
      mean_total_additional = round(mean(total_additional, na.rm = TRUE), 4),
      mean_total_rate = round(mean(total_rate, na.rm = TRUE), 4),
      max_total_rate = round(max(total_rate, na.rm = TRUE), 4),
      pct_232 = round(mean(rate_232 > 0) * 100, 1),
      pct_301 = round(mean(rate_301 > 0) * 100, 1),
      pct_ieepa_recip = round(mean(rate_ieepa_recip > 0) * 100, 1),
      pct_ieepa_fent = round(mean(rate_ieepa_fent > 0) * 100, 1),
      pct_usmca = round(mean(usmca_eligible, na.rm = TRUE) * 100, 1),
      n_negative_rates = sum(total_rate < 0, na.rm = TRUE),
      n_na_total = sum(is.na(total_rate)),
      .groups = 'drop'
    ) %>%
    arrange(effective_date)
}


#' Detect anomalies across revisions
#'
#' Flags revisions with suspicious jumps in product counts, rate levels, or
#' negative/missing values.
#'
#' @param rev_quality Output from compute_revision_quality()
#' @return Tibble of anomaly flags
detect_anomalies <- function(rev_quality) {
  anomalies <- tibble(
    revision = character(),
    effective_date = as.Date(character()),
    anomaly_type = character(),
    detail = character()
  )

  if (nrow(rev_quality) < 2) return(anomalies)

  for (i in 2:nrow(rev_quality)) {
    curr <- rev_quality[i, ]
    prev <- rev_quality[i - 1, ]

    # Large product count change (>500)
    prod_diff <- curr$n_products - prev$n_products
    if (abs(prod_diff) > 500) {
      anomalies <- bind_rows(anomalies, tibble(
        revision = curr$revision,
        effective_date = curr$effective_date,
        anomaly_type = 'product_count_jump',
        detail = paste0('Change of ', prod_diff, ' products (', prev$n_products, ' -> ', curr$n_products, ')')
      ))
    }

    # Large rate change (>5pp in mean additional rate)
    rate_diff <- curr$mean_total_additional - prev$mean_total_additional
    if (abs(rate_diff) > 0.05) {
      anomalies <- bind_rows(anomalies, tibble(
        revision = curr$revision,
        effective_date = curr$effective_date,
        anomaly_type = 'rate_level_jump',
        detail = paste0('Mean additional rate changed by ', round(rate_diff * 100, 1), 'pp')
      ))
    }

    # Negative rates
    if (curr$n_negative_rates > 0) {
      anomalies <- bind_rows(anomalies, tibble(
        revision = curr$revision,
        effective_date = curr$effective_date,
        anomaly_type = 'negative_rates',
        detail = paste0(curr$n_negative_rates, ' rows with negative total_rate')
      ))
    }

    # Missing total rates
    if (curr$n_na_total > 0) {
      anomalies <- bind_rows(anomalies, tibble(
        revision = curr$revision,
        effective_date = curr$effective_date,
        anomaly_type = 'missing_rates',
        detail = paste0(curr$n_na_total, ' rows with NA total_rate')
      ))
    }

    # Country count change (>20)
    cty_diff <- curr$n_countries - prev$n_countries
    if (abs(cty_diff) > 20) {
      anomalies <- bind_rows(anomalies, tibble(
        revision = curr$revision,
        effective_date = curr$effective_date,
        anomaly_type = 'country_count_jump',
        detail = paste0('Change of ', cty_diff, ' countries (', prev$n_countries, ' -> ', curr$n_countries, ')')
      ))
    }
  }

  # Also check first revision for negative/missing
  first <- rev_quality[1, ]
  if (first$n_negative_rates > 0) {
    anomalies <- bind_rows(tibble(
      revision = first$revision,
      effective_date = first$effective_date,
      anomaly_type = 'negative_rates',
      detail = paste0(first$n_negative_rates, ' rows with negative total_rate')
    ), anomalies)
  }
  if (first$n_na_total > 0) {
    anomalies <- bind_rows(tibble(
      revision = first$revision,
      effective_date = first$effective_date,
      anomaly_type = 'missing_rates',
      detail = paste0(first$n_na_total, ' rows with NA total_rate')
    ), anomalies)
  }

  return(anomalies)
}


#' Run full quality report
#'
#' @param timeseries_path Path to rate_timeseries.rds
#' @param output_dir Directory for quality report outputs
#' @return List with schema_check, revision_quality, anomalies
run_quality_report <- function(
  timeseries_path = here('data', 'timeseries', 'rate_timeseries.rds'),
  output_dir = here('output', 'quality')
) {
  message('\n', strrep('=', 70))
  message('QUALITY REPORT')
  message(strrep('=', 70))

  if (!file.exists(timeseries_path)) {
    stop('Time series file not found: ', timeseries_path)
  }

  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

  ts <- readRDS(timeseries_path)
  message('Loaded time series: ', nrow(ts), ' rows, ',
          n_distinct(ts$revision), ' revisions')

  # 1. Schema check
  message('\n--- Schema Check ---')
  schema <- check_schema(ts)
  missing_cols <- schema %>% filter(!present)
  if (nrow(missing_cols) > 0) {
    message('WARNING: Missing columns: ', paste(missing_cols$column, collapse = ', '))
  } else {
    message('All expected columns present.')
  }
  extra_cols <- schema %>% filter(status == 'extra')
  if (nrow(extra_cols) > 0) {
    message('Extra columns: ', paste(extra_cols$column, collapse = ', '))
  }
  high_na <- schema %>% filter(pct_na > 1)
  if (nrow(high_na) > 0) {
    message('Columns with >1% NA:')
    for (r in seq_len(nrow(high_na))) {
      message('  ', high_na$column[r], ': ', high_na$pct_na[r], '%')
    }
  }
  write_csv(schema, file.path(output_dir, 'schema_check.csv'))

  # 2. Revision quality
  message('\n--- Revision Quality ---')
  rev_quality <- compute_revision_quality(ts)
  message('Revisions: ', nrow(rev_quality))
  message('Date range: ', min(rev_quality$effective_date), ' to ', max(rev_quality$effective_date))
  message('Product range: ', min(rev_quality$n_products), ' - ', max(rev_quality$n_products))
  message('Mean additional rate range: ',
          round(min(rev_quality$mean_total_additional) * 100, 1), '% - ',
          round(max(rev_quality$mean_total_additional) * 100, 1), '%')
  write_csv(rev_quality, file.path(output_dir, 'revision_quality.csv'))

  # 3. Anomalies
  message('\n--- Anomaly Detection ---')
  anomalies <- detect_anomalies(rev_quality)
  if (nrow(anomalies) == 0) {
    message('No anomalies detected.')
  } else {
    message(nrow(anomalies), ' anomalies detected:')
    for (r in seq_len(nrow(anomalies))) {
      message('  [', anomalies$revision[r], '] ', anomalies$anomaly_type[r],
              ': ', anomalies$detail[r])
    }
  }
  write_csv(anomalies, file.path(output_dir, 'anomalies.csv'))

  # 4. Unknown country applicability check
  message('\n--- Country Applicability Check ---')
  ch99_path <- here('data', 'processed', 'chapter99_rates.rds')
  unknown_country_rows <- tibble()
  if (file.exists(ch99_path)) {
    ch99 <- readRDS(ch99_path)
    if ('country_type' %in% names(ch99)) {
      unknown_country_rows <- ch99 %>% filter(country_type == 'unknown')
      if (nrow(unknown_country_rows) > 0) {
        message('WARNING: ', nrow(unknown_country_rows),
                ' Ch99 entries with unknown country applicability (fail-closed, will not apply):')
        for (r in seq_len(min(nrow(unknown_country_rows), 10))) {
          message('  ', unknown_country_rows$ch99_code[r], ' (',
                  unknown_country_rows$authority[r], '): ',
                  substr(unknown_country_rows$description[r], 1, 80))
        }
        if (nrow(unknown_country_rows) > 10) {
          message('  ... and ', nrow(unknown_country_rows) - 10, ' more')
        }
        write_csv(unknown_country_rows,
                  file.path(output_dir, 'unknown_country_type.csv'))
      } else {
        message('All Ch99 entries have resolved country applicability.')
      }
    }
  } else {
    message('Ch99 data not found at ', ch99_path, ' — skipping check.')
  }

  # 5. Non-China Section 301 check
  message('\n--- Section 301 Scope Check ---')
  non_china_301 <- tibble()
  if ('rate_301' %in% names(ts) && 'country' %in% names(ts)) {
    cty_china <- '5700'
    non_china_301 <- ts %>% filter(country != cty_china & rate_301 > 0)
    if (nrow(non_china_301) > 0) {
      message('WARNING: ', nrow(non_china_301),
              ' non-China rows with rate_301 > 0 (stacking excludes 301 for non-China):')
      summary_301 <- non_china_301 %>%
        group_by(revision, country) %>%
        summarise(n = n(), mean_rate = round(mean(rate_301) * 100, 1), .groups = 'drop')
      for (r in seq_len(min(nrow(summary_301), 10))) {
        message('  ', summary_301$revision[r], ' / ', summary_301$country[r],
                ': ', summary_301$n[r], ' products, mean ', summary_301$mean_rate[r], '%')
      }
      write_csv(non_china_301 %>% select(revision, hts10, country, rate_301),
                file.path(output_dir, 'non_china_301.csv'))
    } else {
      message('All rate_301 values are zero outside China.')
    }
  }

  # 6. Summary metadata
  report <- list(
    run_time = Sys.time(),
    timeseries_path = timeseries_path,
    n_rows = nrow(ts),
    n_revisions = n_distinct(ts$revision),
    n_missing_columns = sum(!schema$present),
    n_anomalies = nrow(anomalies),
    n_unknown_country = nrow(unknown_country_rows),
    n_non_china_301 = nrow(non_china_301),
    schema_check = schema,
    revision_quality = rev_quality,
    anomalies = anomalies,
    unknown_country = unknown_country_rows,
    non_china_301 = non_china_301
  )
  saveRDS(report, file.path(output_dir, 'quality_report.rds'))

  message('\nQuality report saved to: ', output_dir)
  message(strrep('=', 70))

  return(report)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  report <- run_quality_report()
}
