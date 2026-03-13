# =============================================================================
# Run Comparison Workflows
# =============================================================================
#
# Orchestrator for optional validation/comparison workflows. Checks for
# availability of external data and runs only what's possible.
#
# This is SEPARATE from the core build. The core tariff series does not depend
# on TPC or Tariff-ETRs — those are validation benchmarks only.
#
# Usage:
#   Rscript src/run_comparisons.R              # Run all available comparisons
#   Rscript src/run_comparisons.R --tpc        # TPC validation only
#   Rscript src/run_comparisons.R --etrs       # Reserved for future cross-repo comparison
#
# Outputs:
#   output/comparisons/tpc/       — TPC validation reports
#   output/comparisons/etrs/      — Tariff-ETRs comparison reports
#   output/etr/                   — Weighted ETR with TPC overlay (if weights available)
#
# =============================================================================

library(tidyverse)
library(here)

source(here('src', 'helpers.R'))


# =============================================================================
# TPC Validation
# =============================================================================

#' Run TPC point-in-time validation across all matched revision dates
#'
#' Compares snapshot rates against TPC benchmark at HTS-10 x country level.
#' Requires: TPC benchmark CSV, built timeseries.
#'
#' @param ts Timeseries tibble (or path to rate_timeseries.rds)
#' @param tpc_path Path to TPC benchmark CSV
#' @param output_dir Output directory for comparison files
#' @return Validation results (invisible)
run_tpc_validation <- function(
  ts = NULL,
  tpc_path = NULL,
  output_dir = here('output', 'comparisons', 'tpc')
) {
  message('\n', strrep('=', 70))
  message('TPC VALIDATION')
  message(strrep('=', 70))

  # Resolve TPC path
  if (is.null(tpc_path)) {
    local_paths <- load_local_paths()
    tpc_path <- local_paths$tpc_benchmark
  }
  if (is.null(tpc_path) || !file.exists(tpc_path)) {
    message('TPC benchmark file not found: ', tpc_path %||% '(not configured)')
    message('Skipping TPC validation.')
    return(invisible(NULL))
  }

  # Load timeseries
  if (is.null(ts)) {
    ts_path <- here('data', 'timeseries', 'rate_timeseries.rds')
    if (!file.exists(ts_path)) {
      stop('Timeseries not found. Run the build first: Rscript src/00_build_timeseries.R --full')
    }
    ts <- readRDS(ts_path)
  }

  # Load census codes
  census_codes <- read_csv(
    here('resources', 'census_codes.csv'),
    col_types = cols(.default = col_character())
  )

  # Load revision dates
  rev_dates <- load_revision_dates()
  tpc_revisions <- rev_dates %>% filter(!is.na(tpc_date))

  if (nrow(tpc_revisions) == 0) {
    message('No TPC validation dates found in revision_dates.csv.')
    return(invisible(NULL))
  }

  message('Validating ', nrow(tpc_revisions), ' revision-date pairs against TPC')

  # Source validation functions
  source(here('src', '07_validate_tpc.R'))

  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

  results <- list()

  for (i in seq_len(nrow(tpc_revisions))) {
    rev_id <- tpc_revisions$revision[i]
    tpc_date <- tpc_revisions$tpc_date[i]

    # Use tpc_policy_revision if specified, otherwise fall back to revision
    policy_rev <- if ('tpc_policy_revision' %in% names(tpc_revisions) &&
                      !is.na(tpc_revisions$tpc_policy_revision[i]) &&
                      nchar(tpc_revisions$tpc_policy_revision[i]) > 0) {
      tpc_revisions$tpc_policy_revision[i]
    } else {
      rev_id
    }

    # Get snapshot for the policy revision
    snapshot <- ts %>% filter(revision == policy_rev)
    if (nrow(snapshot) == 0) {
      message('  Skipping ', rev_id, ' (policy rev: ', policy_rev, ') — not in timeseries')
      next
    }

    message('\n--- ', rev_id, ' (TPC date: ', tpc_date,
            if (policy_rev != rev_id) paste0(', policy rev: ', policy_rev),
            ') ---')

    tryCatch({
      validation <- validate_revision_against_tpc(
        revision_rates = snapshot,
        tpc_path = tpc_path,
        tpc_date = tpc_date,
        census_codes = census_codes
      )
      results[[rev_id]] <- validation

      # Save per-revision comparison
      if (!is.null(validation$comparison) && nrow(validation$comparison) > 0) {
        write_csv(
          validation$comparison,
          file.path(output_dir, paste0('comparison_', rev_id, '.csv'))
        )
      }

      message('  Match rate: ', round(validation$match_rate * 100, 1), '%')
    }, error = function(e) {
      message('  Validation failed: ', conditionMessage(e))
    })
  }

  # Summary table
  if (length(results) > 0) {
    summary <- tibble(
      revision = names(results),
      tpc_date = tpc_revisions$tpc_date[match(names(results), tpc_revisions$revision)],
      match_rate = map_dbl(results, 'match_rate'),
      n_comparisons = map_dbl(results, 'n_comparisons'),
      mean_abs_diff = map_dbl(results, 'mean_abs_diff')
    ) %>%
      mutate(
        match_pct = round(match_rate * 100, 1),
        mean_diff_pp = round(mean_abs_diff * 100, 2)
      )

    message('\n=== TPC Validation Summary ===')
    print(summary %>% select(revision, tpc_date, match_pct, n_comparisons, mean_diff_pp))
    write_csv(summary, file.path(output_dir, 'validation_summary.csv'))
  }

  message('\nTPC validation outputs saved to: ', output_dir)
  return(invisible(results))
}


# =============================================================================
# Weighted ETR with TPC Overlay
# =============================================================================

#' Run weighted ETR analysis with TPC comparison overlay
#'
#' Requires import weights (from local_paths.yaml) and TPC benchmark.
#' This is a comparison workflow — the core build does not need it.
#'
#' @param policy_params Optional policy params list
#' @return ETR results (invisible)
run_etr_comparison <- function(policy_params = NULL) {
  message('\n', strrep('=', 70))
  message('WEIGHTED ETR WITH TPC OVERLAY')
  message(strrep('=', 70))

  if (is.null(policy_params)) policy_params <- load_policy_params()

  source(here('src', '08_weighted_etr.R'))

  result <- run_weighted_etr(policy_params = policy_params)
  if (is.null(result)) {
    message('Weighted ETR skipped (import weights not available).')
  }
  return(invisible(result))
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  run_tpc <- '--tpc' %in% args || length(args) == 0
  run_etrs <- '--etrs' %in% args || length(args) == 0
  run_etr <- '--etr' %in% args || length(args) == 0

  pp <- load_policy_params()

  message(strrep('=', 70))
  message('COMPARISON WORKFLOWS')
  message(strrep('=', 70))

  # Report what's available
  local_paths <- pp$LOCAL_PATHS
  tpc_available <- !is.null(local_paths$tpc_benchmark) &&
    file.exists(local_paths$tpc_benchmark)
  weights_available <- !is.null(local_paths$import_weights) &&
    file.exists(local_paths$import_weights)
  etrs_repo_available <- !is.null(local_paths$tariff_etrs_repo) &&
    dir.exists(local_paths$tariff_etrs_repo)

  message('TPC benchmark: ', if (tpc_available) 'available' else 'not available')
  message('Import weights: ', if (weights_available) 'available' else 'not available')
  message('Tariff-ETRs repo: ', if (etrs_repo_available) 'configured' else 'not configured')
  message('')

  if (run_tpc && tpc_available) {
    tryCatch(
      run_tpc_validation(tpc_path = local_paths$tpc_benchmark),
      error = function(e) message('TPC validation failed: ', conditionMessage(e))
    )
  } else if (run_tpc && !tpc_available) {
    message('TPC benchmark not available — skipping TPC validation.')
  }

  if (run_etr && weights_available) {
    tryCatch(
      run_etr_comparison(policy_params = pp),
      error = function(e) message('Weighted ETR failed: ', conditionMessage(e))
    )
  } else if (run_etr && !weights_available) {
    message('Import weights not available — skipping weighted ETR comparison.')
  }

  if (run_etrs) {
    if (etrs_repo_available) {
      message('\nTariff-ETRs cross-repo comparison is not implemented in run_comparisons.R yet.')
      message('The repo path is configured correctly, but this remains a follow-up task.')
    } else {
      message('\nTariff-ETRs repo not configured — skipping ETRs comparison.')
    }
  }

  message('\n', strrep('=', 70))
  message('COMPARISON WORKFLOWS COMPLETE')
  message(strrep('=', 70))
}
