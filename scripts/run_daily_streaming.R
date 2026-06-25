#!/usr/bin/env Rscript
# =============================================================================
# run_daily_streaming.R — build the daily series WITHOUT the giant timeseries
# =============================================================================
# Reads per-revision snapshots ONE AT A TIME (peak ~1.2 GB) and writes the daily
# CSVs, skipping the ~194.5M-row / ~48 GB combined panel that assemble + the
# legacy daily path materialize. Identical outputs to the combined-ts path.
#
#   TARIFF_TS_DIR      snapshot dir to read   (default data/timeseries)
#   TARIFF_OUTPUT_DIR  output root            (daily -> <root>/actual/daily)
# =============================================================================
suppressPackageStartupMessages({ library(here); library(tidyverse) })
suppressMessages({
  source(here('src', 'pipeline', '00_build_timeseries.R'))
  source(here('src', 'model', 'revisions.R'))
  source(here('src', 'model', 'policy_params.R'))
  source(here('src', 'pipeline', '09_daily_series.R'))
  source(here('src', 'io', 'build_import_weights.R'))
})

ts_dir <- Sys.getenv('TARIFF_TS_DIR', unset = here('data', 'timeseries'))
pp <- load_policy_params()
rev_dates <- load_revision_dates()
ensure_import_weights()
imports <- load_import_weights()

t0 <- proc.time()[['elapsed']]
run_daily_series(snapshot_dir = ts_dir, rev_dates = rev_dates,
                 imports = imports, policy_params = pp)
cat(sprintf('Streaming daily complete in %.1f min (snapshots: %s)\n',
            (proc.time()[['elapsed']] - t0) / 60, ts_dir))
