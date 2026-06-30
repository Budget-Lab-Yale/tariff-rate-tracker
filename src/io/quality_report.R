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
#   Rscript src/io/quality_report.R
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

source(here('src', 'core', 'helpers.R'))


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
      pct_s122 = round(mean(rate_s122 > 0) * 100, 1),
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


#' Check authority timeline against expectations
#'
#' Loads config/expected_authorities.csv and verifies that each revision has
#' the expected authorities active (nonzero pct) or inactive (zero pct).
#' Expectations carry forward: an entry for revision X holds for all subsequent
#' revisions until overridden.
#'
#' Maintenance: when a new revision is added to the timeseries, update the CSV
#' if any authority activates, deactivates, or expires (e.g., S122 expiry at
#' 2026-07-23 means the first post-expiry revision needs s122,inactive).
#'
#' @param rev_quality Output from compute_revision_quality()
#' @return Tibble of authority timeline anomalies
check_authority_timeline <- function(rev_quality) {
  expectations_path <- here('config', 'expected_authorities.csv')
  if (!file.exists(expectations_path)) {
    message('  No expected_authorities.csv found — skipping authority timeline check.')
    return(tibble(revision = character(), effective_date = as.Date(character()),
                  anomaly_type = character(), detail = character()))
  }

  expectations <- read_csv(expectations_path, col_types = cols(
    revision = col_character(), authority = col_character(),
    expected = col_character(), min_pct = col_double(), note = col_character()
  ))

  # Map authority short names to pct_* columns in rev_quality
  authority_map <- c(
    s232 = 'pct_232', s301 = 'pct_301',
    ieepa_recip = 'pct_ieepa_recip', ieepa_fent = 'pct_ieepa_fent',
    s122 = 'pct_s122'
  )

  all_revisions <- rev_quality$revision
  all_authorities <- unique(expectations$authority)

  # Warn on revision names in CSV that don't appear in the timeseries
  unknown_revs <- setdiff(expectations$revision, all_revisions)
  if (length(unknown_revs) > 0) {
    message('  WARNING: expected_authorities.csv references unknown revisions: ',
            paste(unknown_revs, collapse = ', '),
            ' — check for typos')
  }

  # Warn on authority names in CSV that don't appear in authority_map
  unknown_auths <- setdiff(all_authorities, names(authority_map))
  if (length(unknown_auths) > 0) {
    message('  WARNING: expected_authorities.csv references unknown authorities: ',
            paste(unknown_auths, collapse = ', '),
            ' — add to authority_map in check_authority_timeline()')
  }

  # Build full expectation matrix by carrying forward
  full_expectations <- list()
  for (auth in all_authorities) {
    auth_exp <- expectations %>% filter(authority == auth)
    current_expected <- NA_character_
    current_min_pct <- NA_real_
    current_note <- NA_character_
    for (rev in all_revisions) {
      override <- auth_exp %>% filter(revision == rev)
      if (nrow(override) > 0) {
        current_expected <- override$expected[1]
        current_min_pct <- override$min_pct[1]
        current_note <- override$note[1]
      }
      if (!is.na(current_expected)) {
        full_expectations[[length(full_expectations) + 1]] <- tibble(
          revision = rev, authority = auth, expected = current_expected,
          min_pct = current_min_pct, note = current_note
        )
      }
    }
  }
  full_exp <- bind_rows(full_expectations)

  # Check each expectation against actual pct values
  anomalies <- tibble(revision = character(), effective_date = as.Date(character()),
                      anomaly_type = character(), detail = character())

  for (i in seq_len(nrow(full_exp))) {
    row <- full_exp[i, ]
    col_name <- authority_map[row$authority]
    if (is.na(col_name) || !col_name %in% names(rev_quality)) next

    rev_row <- rev_quality %>% filter(revision == row$revision)
    if (nrow(rev_row) == 0) next
    actual_pct <- rev_row[[col_name]]

    if (row$expected == 'active' && actual_pct == 0) {
      anomalies <- bind_rows(anomalies, tibble(
        revision = row$revision, effective_date = rev_row$effective_date,
        anomaly_type = 'authority_missing',
        detail = paste0(row$authority, ' expected active but pct = 0% (',
                        row$note, ')')
      ))
    } else if (row$expected == 'active' && !is.na(row$min_pct) && actual_pct < row$min_pct) {
      anomalies <- bind_rows(anomalies, tibble(
        revision = row$revision, effective_date = rev_row$effective_date,
        anomaly_type = 'authority_low',
        detail = paste0(row$authority, ' expected >= ', row$min_pct,
                        '% but pct = ', actual_pct, '% (', row$note, ')')
      ))
    } else if (row$expected == 'inactive' && actual_pct > 0) {
      anomalies <- bind_rows(anomalies, tibble(
        revision = row$revision, effective_date = rev_row$effective_date,
        anomaly_type = 'authority_unexpected',
        detail = paste0(row$authority, ' expected inactive but pct = ',
                        actual_pct, '% (', row$note, ')')
      ))
    }
  }

  return(anomalies)
}


#' Check post-annex revisions for populated s232_annex classification
#'
#' Fails closed on revisions on or after the Section 232 annex effective date:
#' those revisions should contain at least some non-missing `s232_annex` values.
#'
#' @param ts Full rate timeseries
#' @param policy_params Optional loaded policy params
#' @return Tibble of annex classification anomalies
check_annex_classification <- function(ts, policy_params = NULL) {
  empty <- tibble(
    revision = character(),
    effective_date = as.Date(character()),
    anomaly_type = character(),
    detail = character()
  )

  required <- c('revision', 'effective_date', 's232_annex')
  if (!all(required %in% names(ts))) {
    return(empty)
  }

  if (is.null(policy_params)) {
    policy_params <- tryCatch(load_policy_params(), error = function(e) NULL)
  }

  annex_cfg <- policy_params$S232_ANNEXES %||% NULL
  annex_effective <- annex_cfg$effective_date %||% NULL
  if (is.null(annex_effective)) {
    return(empty)
  }

  ts %>%
    filter(effective_date >= as.Date(annex_effective)) %>%
    group_by(revision, effective_date) %>%
    summarise(
      n_rows = n(),
      n_nonmissing_annex = sum(!is.na(s232_annex)),
      .groups = 'drop'
    ) %>%
    filter(n_rows > 0, n_nonmissing_annex == 0) %>%
    transmute(
      revision,
      effective_date,
      anomaly_type = 'annex_missing',
      detail = 'post-annex revision has 0 non-missing s232_annex values'
    )
}


#' Build the quality-report inputs by STREAMING the per-revision snapshots,
#' without ever materializing the combined 204M-row panel.
#'
#' Mirrors build_daily_aggregates_streaming(): reads ONE snapshot at a time and
#' enforce_rate_schema()'s it (assemble_timeseries does the same post-bind at
#' 00_build_timeseries.R:339, filling rate-column NAs -> 0), then accumulates the
#' exact intermediates run_quality_report() reports on. Returns the same objects
#' the monolith path computes: {schema, rev_quality, annex_anomalies,
#' non_china_301, n_rows, n_revisions}.
#'
#' Schema NA counts use UNION accounting -- a column absent from a snapshot
#' contributes nrow(snap) NAs, exactly as bind_rows() would fill it -- so the
#' streamed schema matches check_schema() on the bound monolith.
#'
#' @param snapshot_dir Directory of snapshot_<rev>.rds files
#' @param rev_dates Revision-date table (orders snapshots by effective_date)
#' @param pp Optional loaded policy params (for CTY_CHINA + annex date)
build_quality_inputs_streaming <- function(snapshot_dir, rev_dates, pp = NULL) {
  snaps <- list.files(snapshot_dir, pattern = '^snapshot_.*\\.rds$')
  if (length(snaps) == 0) stop('No snapshots found in ', snapshot_dir)
  rev_ids <- sub('^snapshot_(.*)\\.rds$', '\\1', snaps)
  # Process in effective-date order so bound rows match the monolith's row order.
  ordered <- rev_dates %>%
    filter(revision %in% rev_ids) %>%
    arrange(effective_date) %>%
    pull(revision)
  ordered <- c(ordered, setdiff(rev_ids, ordered))
  cty_china <- if (!is.null(pp)) pp$CTY_CHINA %||% '5700' else '5700'

  # Recompute the authoritative intervals from rev_dates exactly as
  # assemble_timeseries / the daily streaming path do, and stamp them onto each
  # snapshot. Raw snapshots carry NA valid_from/valid_until (intervals are an
  # assemble-time product), so without this the schema check would report those
  # two columns as 100% NA, diverging from the monolith's populated values.
  horizon_end <- as.Date(pp$SERIES_HORIZON_END %||% Sys.Date())
  rev_intervals <- rev_dates %>%
    filter(revision %in% ordered) %>%
    arrange(effective_date) %>%
    mutate(valid_from  = effective_date,
           valid_until = lead(effective_date) - 1,
           valid_until = if_else(is.na(valid_until), horizon_end, valid_until)) %>%
    select(revision, valid_from, valid_until)

  n <- length(ordered)
  rq <- vector('list', n); annex <- vector('list', n); nonchina <- vector('list', n)
  na_by_snap <- vector('list', n); nrow_by_snap <- integer(n)

  for (i in seq_len(n)) {
    snap <- enforce_rate_schema(
      readRDS(file.path(snapshot_dir, paste0('snapshot_', ordered[i], '.rds'))))
    iv <- rev_intervals[match(ordered[i], rev_intervals$revision), ]
    snap$valid_from  <- iv$valid_from
    snap$valid_until <- iv$valid_until
    nrow_by_snap[i] <- nrow(snap)
    na_by_snap[[i]] <- vapply(names(snap), function(col) sum(is.na(snap[[col]])), numeric(1))
    rq[[i]]    <- compute_revision_quality(snap)
    annex[[i]] <- check_annex_classification(snap, pp)
    if (all(c('rate_301', 'country') %in% names(snap))) {
      nc <- snap %>% filter(country != cty_china & rate_301 > 0)
      if (nrow(nc) > 0) nonchina[[i]] <- nc
    }
  }

  total_rows <- sum(nrow_by_snap)
  all_cols <- unique(unlist(lapply(na_by_snap, names)))
  n_na <- setNames(numeric(length(all_cols)), all_cols)
  for (i in seq_len(n)) {
    present <- names(na_by_snap[[i]])
    n_na[present] <- n_na[present] + na_by_snap[[i]][present]
    absent <- setdiff(all_cols, present)
    if (length(absent)) n_na[absent] <- n_na[absent] + nrow_by_snap[i]
  }

  # Reconstruct the check_schema() tibble from the accumulated counts.
  expected <- RATE_SCHEMA
  schema_expected <- tibble(
    column  = expected,
    present = expected %in% all_cols,
    n_na    = vapply(expected, function(c) if (c %in% all_cols) as.integer(n_na[[c]]) else NA_integer_, integer(1)),
    n_rows  = total_rows
  ) %>% mutate(pct_na = round(n_na / n_rows * 100, 2), status = 'expected')
  extra_cols <- setdiff(all_cols, expected)
  schema <- if (length(extra_cols)) {
    bind_rows(schema_expected, tibble(
      column  = extra_cols, present = TRUE,
      n_na    = vapply(extra_cols, function(c) as.integer(n_na[[c]]), integer(1)),
      n_rows  = total_rows
    ) %>% mutate(pct_na = round(n_na / n_rows * 100, 2), status = 'extra'))
  } else schema_expected

  list(
    schema          = schema,
    rev_quality     = bind_rows(rq) %>% arrange(effective_date),
    annex_anomalies = bind_rows(annex),
    non_china_301   = bind_rows(nonchina),
    n_rows          = total_rows,
    n_revisions     = n
  )
}


#' Run full quality report
#'
#' @param ts Optional in-memory timeseries tibble. If supplied, skips the
#'   ~1.26 GB readRDS — preferred from the orchestrator to avoid two
#'   simultaneous copies in memory.
#' @param timeseries_path Path to rate_timeseries.rds (used when ts is NULL)
#' @param output_dir Directory for quality report outputs
#' @return List with schema_check, revision_quality, anomalies
run_quality_report <- function(
  ts = NULL,
  timeseries_path = here('data', 'timeseries', 'rate_timeseries.rds'),
  output_dir = series_section_dir('quality'),
  snapshot_dir = NULL,
  rev_dates = NULL
) {
  message('\n', strrep('=', 70))
  message('QUALITY REPORT')
  message(strrep('=', 70))

  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

  pp <- tryCatch(load_policy_params(), error = function(e) NULL)

  # Inputs come either from the combined panel (ts / timeseries_path) or — the
  # preferred path — by STREAMING the per-revision snapshots (no 204M-row panel).
  # Both produce the same {schema, rev_quality, annex_anomalies, non_china_301}.
  if (!is.null(snapshot_dir)) {
    if (is.null(rev_dates)) rev_dates <- load_revision_dates()
    inputs <- build_quality_inputs_streaming(snapshot_dir, rev_dates, pp)
    message('Loaded ', inputs$n_revisions, ' revision snapshots (streaming; no combined panel), ',
            inputs$n_rows, ' rows total')
  } else {
    if (is.null(ts)) {
      if (!file.exists(timeseries_path)) {
        stop('Time series file not found: ', timeseries_path)
      }
      ts <- readRDS(timeseries_path)
    }
    message('Loaded time series: ', nrow(ts), ' rows, ',
            n_distinct(ts$revision), ' revisions')
    cty_china <- if (!is.null(pp)) pp$CTY_CHINA %||% '5700' else '5700'
    inputs <- list(
      schema          = check_schema(ts),
      rev_quality     = compute_revision_quality(ts),
      annex_anomalies = check_annex_classification(ts, pp),
      non_china_301   = if (all(c('rate_301', 'country') %in% names(ts))) {
                          ts %>% filter(country != cty_china & rate_301 > 0)
                        } else tibble(),
      n_rows          = nrow(ts),
      n_revisions     = n_distinct(ts$revision)
    )
  }

  # 1. Schema check
  message('\n--- Schema Check ---')
  schema <- inputs$schema
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
  rev_quality <- inputs$rev_quality
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

  # 4. Authority timeline check
  message('\n--- Authority Timeline Check ---')
  auth_anomalies <- check_authority_timeline(rev_quality)
  if (nrow(auth_anomalies) == 0) {
    message('All authority activations match expected timeline.')
  } else {
    message(nrow(auth_anomalies), ' authority timeline mismatches:')
    for (r in seq_len(nrow(auth_anomalies))) {
      message('  [', auth_anomalies$revision[r], '] ', auth_anomalies$anomaly_type[r],
              ': ', auth_anomalies$detail[r])
    }
  }
  anomalies <- bind_rows(anomalies, auth_anomalies)

  # 4b. Post-annex classification integrity
  message('\n--- Section 232 Annex Check ---')
  annex_anomalies <- inputs$annex_anomalies
  if (nrow(annex_anomalies) == 0) {
    message('All annex-era revisions have populated s232_annex values.')
  } else {
    message(nrow(annex_anomalies), ' annex classification failures detected:')
    for (r in seq_len(nrow(annex_anomalies))) {
      message('  [', annex_anomalies$revision[r], '] ', annex_anomalies$anomaly_type[r],
              ': ', annex_anomalies$detail[r])
    }
  }
  anomalies <- bind_rows(anomalies, annex_anomalies)
  write_csv(anomalies, file.path(output_dir, 'anomalies.csv'))

  # 5. Unknown country applicability check
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

  # 6. Non-China Section 301 check
  message('\n--- Section 301 Scope Check ---')
  non_china_301 <- inputs$non_china_301
  {
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

  # 7. Summary metadata
  report <- list(
    run_time = Sys.time(),
    timeseries_path = if (!is.null(snapshot_dir)) snapshot_dir else timeseries_path,
    n_rows = inputs$n_rows,
    n_revisions = inputs$n_revisions,
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

  if (nrow(annex_anomalies) > 0) {
    stop(
      'Critical quality failure: post-annex revisions are missing s232_annex classification. ',
      'See ', file.path(output_dir, 'anomalies.csv')
    )
  }

  return(report)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  report <- run_quality_report()
}
