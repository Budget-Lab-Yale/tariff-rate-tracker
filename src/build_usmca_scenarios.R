# =============================================================================
# Build USMCA Scenario Snapshots (for tariff-etr-eval handoff)
# =============================================================================
#
# Produces per-revision snapshots under data/timeseries/<scenario>/ for four
# USMCA utilization scenarios. Consumed by tariff-etr-eval to construct the
# statutory ETR denominator against alternate USMCA assumptions.
#
# Scenarios:
#   usmca_none    -- 0% utilization (no CA/MX importer claims USMCA)
#   usmca_2024    -- annual 2024 shares (pre-tariff baseline)
#   usmca_monthly -- monthly 2025 shares (time-varying per revision date)
#   usmca_h2avg   -- second-half 2025 average (production default, verified
#                    once then populated by copy from top-level snapshots)
#
# Usage:
#   Rscript src/build_usmca_scenarios.R [--verify-h2avg] [--scenarios <list>]
#
#   --verify-h2avg     Run build_alternative_timeseries for h2avg and diff
#                      against top-level snapshots. Fails loudly on drift.
#                      Skip (default) to use the cheap file-copy path.
#   --scenarios <list> Comma-separated subset of scenarios to run
#                      (default: all except h2avg; h2avg controlled by
#                       --verify-h2avg).
#
# Inputs:  data/hts_archives/*, config/policy_params.yaml, config/revision_dates.csv
# Outputs: data/timeseries/<scenario>/snapshot_<rev_id>.rds
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(dplyr)
  library(purrr)
})

source(here('src', 'helpers.R'))
source(here('src', '09_daily_series.R'))

SCENARIO_SPECS <- list(
  usmca_none    = list(mode = 'none',       year = NULL),
  usmca_2024    = list(mode = 'annual',     year = 2024L),
  usmca_monthly = list(mode = 'monthly',    year = 2025L),
  usmca_h2avg   = list(mode = 'h2_average', year = 2025L)
)

copy_h2avg_from_top_level <- function(output_root) {
  top_level_files <- list.files(output_root, pattern = '^snapshot_.*\\.rds$',
                                 full.names = TRUE)
  if (length(top_level_files) == 0) {
    stop('No top-level snapshots to copy. Run the main build first.')
  }
  dest_dir <- file.path(output_root, 'usmca_h2avg')
  dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
  n_copied <- sum(file.copy(top_level_files, dest_dir, overwrite = TRUE))
  message('  Copied ', n_copied, ' h2avg snapshots from top-level to ', dest_dir)
  invisible(n_copied)
}

diff_h2avg_against_top_level <- function(output_root) {
  top_level_files <- list.files(output_root, pattern = '^snapshot_.*\\.rds$',
                                 full.names = FALSE)
  scenario_dir <- file.path(output_root, 'usmca_h2avg')

  diffs <- map_dfr(top_level_files, function(fname) {
    top <- readRDS(file.path(output_root, fname))
    scn <- readRDS(file.path(scenario_dir, fname))
    eq  <- all.equal(top, scn, check.attributes = FALSE, tolerance = 1e-10)
    tibble(
      file = fname,
      identical = isTRUE(eq),
      detail = if (isTRUE(eq)) sprintf('n=%d', nrow(top))
               else paste(head(eq, 2), collapse = ' | ')
    )
  })
  diffs
}

run_scenario <- function(scenario_name, spec, pp_base, output_root, imports) {
  message('\n', strrep('=', 60))
  message('Scenario: ', scenario_name,
          ' (mode=', spec$mode, ', year=', spec$year %||% 'NA', ')')
  message(strrep('=', 60))

  pp_override <- pp_base
  pp_override$USMCA_SHARES$mode <- spec$mode
  if (!is.null(spec$year)) {
    pp_override$USMCA_SHARES$year <- spec$year
  }

  out_dir <- file.path(output_root, scenario_name)

  t0 <- Sys.time()
  build_alternative_timeseries(
    pp_override       = pp_override,
    variant_name      = scenario_name,
    imports           = imports,
    policy_params     = pp_override,
    snapshot_out_dir  = out_dir
  )
  dt <- round(as.numeric(difftime(Sys.time(), t0, units = 'mins')), 1)
  message('  ', scenario_name, ' complete in ', dt, ' min')

  n_files <- length(list.files(out_dir, pattern = '^snapshot_.*\\.rds$'))
  message('  Snapshots written: ', n_files)
}

main <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  verify_h2avg <- '--verify-h2avg' %in% args
  scenarios_arg <- NULL
  for (i in seq_along(args)) {
    if (args[i] == '--scenarios' && i < length(args)) scenarios_arg <- args[i + 1]
  }

  if (is.null(scenarios_arg)) {
    scenarios_to_run <- c('usmca_none', 'usmca_2024', 'usmca_monthly')
    if (verify_h2avg) scenarios_to_run <- c(scenarios_to_run, 'usmca_h2avg')
  } else {
    scenarios_to_run <- strsplit(scenarios_arg, ',')[[1]]
  }

  pp_base <- load_policy_params()
  imports <- tryCatch(load_import_weights(), error = function(e) {
    message('  load_import_weights() failed — proceeding without (',
            conditionMessage(e), ')')
    NULL
  })

  output_root <- here('data', 'timeseries')

  # Track per-scenario outcome. Silent tryCatch(message) was masking failures
  # and the script exited with a success line regardless of what ran.
  n_ok <- 0L
  n_failed <- 0L
  failed_scenarios <- character(0)
  n_unknown <- 0L

  for (scn in scenarios_to_run) {
    if (!scn %in% names(SCENARIO_SPECS)) {
      message('  SKIP: unknown scenario "', scn, '"')
      n_unknown <- n_unknown + 1L
      next
    }
    ok <- tryCatch({
      run_scenario(scn, SCENARIO_SPECS[[scn]], pp_base, output_root, imports)
      TRUE
    }, error = function(e) {
      message('  FAILED (', scn, '): ', conditionMessage(e))
      FALSE
    })
    if (isTRUE(ok)) n_ok <- n_ok + 1L else {
      n_failed <- n_failed + 1L
      failed_scenarios <- c(failed_scenarios, scn)
    }
  }

  # h2avg: verify once against top-level, then copy for subsequent builds.
  # Do NOT copy when h2avg was explicitly built this run — copying would
  # clobber the just-computed snapshots with a file-copy of the top-level.
  h2avg_built_this_run <- 'usmca_h2avg' %in% scenarios_to_run
  if (verify_h2avg && h2avg_built_this_run) {
    message('\n', strrep('=', 60))
    message('Verifying usmca_h2avg snapshots vs top-level...')
    message(strrep('=', 60))
    diffs <- diff_h2avg_against_top_level(output_root)
    n_ok_diff   <- sum(diffs$identical)
    n_diff <- sum(!diffs$identical)
    message('  Identical: ', n_ok_diff, '/', nrow(diffs))
    if (n_diff > 0) {
      message('  DRIFT DETECTED — resolve before trusting the copy path:')
      print(diffs %>% filter(!identical), n = Inf)
      stop('h2avg verification failed')
    } else {
      message('  PASS: h2avg matches top-level byte-for-byte.')
    }
  } else if (!verify_h2avg && !h2avg_built_this_run) {
    message('\n', strrep('=', 60))
    message('Populating usmca_h2avg/ by copy from top-level snapshots')
    message('(skip --verify-h2avg for the cheap path)')
    message(strrep('=', 60))
    copy_h2avg_from_top_level(output_root)
  }

  # Final summary with non-zero exit on any failure.
  message('\n', strrep('=', 60))
  message('Run summary: ', n_ok, ' ok, ', n_failed, ' failed, ',
          n_unknown, ' unknown (of ', length(scenarios_to_run), ' requested)')
  message(strrep('=', 60))
  if (n_failed > 0) {
    stop('Scenario failures: ', paste(failed_scenarios, collapse = ', '))
  }
  message('All scenarios complete.')
}

if (sys.nframe() == 0) {
  main()
}
