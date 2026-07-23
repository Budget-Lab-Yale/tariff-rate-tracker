#!/usr/bin/env Rscript
# =============================================================================
# build_revision.R — build ONE revision's snapshot (the array-parallel unit)
# =============================================================================
#
# Wraps build_revision_snapshot() (src/pipeline/revision_snapshot.R) with the same
# setup build_full_timeseries() does, for exactly one revision. Writes only
# that revision's scoped artifacts (snapshot_<rev>.rds + ch99_/products_ caches
# + validation_<rev>.rds). It also writes the revision-local daily aggregate part
# while the snapshot is in memory. Cross-revision work (deltas, products_raw.csv,
# interval validation, final output writes) is done by the gather step.
#
# Usage:
#   Rscript scripts/build_revision.R <rev_id> [--use-hts-dates] [--unweighted]
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(tidyverse)
  library(jsonlite)
})

# Sourcing 00 pulls in the full pipeline chain (logging/helpers/parallel/01-07)
# including the shared build_revision_snapshot(). revisions.R + policy_params.R hold the
# setup helpers (load_revision_dates / load_policy_params / load_local_paths);
# source explicitly so we don't depend on transitive sourcing.
suppressMessages({
  source(here('src', 'pipeline', '00_build_timeseries.R'))
  source(here('src', 'model', 'revisions.R'))
  source(here('src', 'model', 'policy_params.R'))
  source(here('src', 'pipeline', '09_daily_series.R'))
  source(here('src', 'io', 'build_import_weights.R'))
  source(here('src', 'io', 'build_panel_import_weights.R'))
})

args <- commandArgs(trailingOnly = TRUE)
rev_id <- args[!grepl('^--', args)][1]
use_policy_dates <- !('--use-hts-dates' %in% args)
unweighted <- '--unweighted' %in% args
if (is.na(rev_id) || !nzchar(rev_id)) {
  stop('usage: Rscript scripts/build_revision.R <rev_id> [--use-hts-dates] [--unweighted]', call. = FALSE)
}

archive_dir <- here('data', 'hts_archives')
# Output dir is overridable (TARIFF_TS_DIR) so a parallel build can write to an
# isolated directory and run concurrently with a serial build in data/timeseries.
ts_dir_env <- Sys.getenv('TARIFF_TS_DIR')
output_dir <- if (nzchar(ts_dir_env)) ts_dir_env else here('data', 'timeseries')
ensure_dir(output_dir)

timeline_path <- Sys.getenv('REV_TIMELINE', 'output/build_array_timeline.rds')
if (!file.exists(timeline_path)) {
  stop('revision timeline not found: ', timeline_path,
       ' — run scripts/list_revisions.R before build_revision.R', call. = FALSE)
}

init_logging(
  # Logs go to TARIFF_LOG_DIR (the run's external scratch) when set, so they stay
  # out of the published vintage and never touch the repo working tree; otherwise
  # they fall back to TARIFF_OUTPUT_DIR/logs (or output/logs for a dev run).
  log_file = file.path(ensure_dir(Sys.getenv('TARIFF_LOG_DIR',
                         unset = file.path(Sys.getenv('TARIFF_OUTPUT_DIR', unset = here('output')), 'logs'))),
                       paste0('build_rev_', rev_id, '.log')),
  level = 'info'
)

rev_dates <- load_revision_dates(use_policy_dates = use_policy_dates)
timeline <- readRDS(timeline_path) %>%
  mutate(effective_date = as.Date(effective_date))
ri <- timeline %>% filter(revision == rev_id)
if (nrow(ri) == 0) stop('unknown revision id: ', rev_id, call. = FALSE)

pp_build       <- load_policy_params(use_policy_dates = use_policy_dates)
census_codes   <- read_csv(here('resources', 'census_codes.csv'),
                           col_types = cols(.default = col_character()))
countries      <- census_codes$Code
country_lookup <- build_country_lookup(here('resources', 'census_codes.csv'))

message('Building revision ', rev_id, ' (effective ', ri$effective_date, ') on ', Sys.info()[['nodename']])
res <- build_revision_snapshot(
  rev_id = rev_id, eff_date = ri$effective_date,
  archive_rev_id = ri$archive_rev_id,
  archive_dir = archive_dir, output_dir = output_dir,
  country_lookup = country_lookup, countries = countries,
  census_codes = census_codes, pp_build = pp_build
)
message('OK: ', rev_id, ' -> ', res$snapshot_path, ' (', res$n_rates, ' rows)')

# Precompute the per-revision daily aggregate part while the snapshot is still
# live in memory. Gather validates the part's mode + interval before using it.
if (!nzchar(Sys.getenv('TARIFF_SKIP_DAILY_PARTS'))) {
  timeline_ordered <- timeline %>% arrange(effective_date, revision)
  idx <- match(rev_id, timeline_ordered$revision)
  horizon_end <- as.Date(pp_build$SERIES_HORIZON_END %||% Sys.Date())
  valid_from <- as.Date(ri$effective_date)
  valid_until <- if (!is.na(idx) && idx < nrow(timeline_ordered)) {
    as.Date(timeline_ordered$effective_date[idx + 1L]) - 1
  } else {
    horizon_end
  }

  # Resolve this revision's weight plan (weight_mode / weight_method from config;
  # --unweighted forces the opt-out). For the 484f method the interval's weights
  # are mapped from the 2024 base onto THIS revision's panel at its RAW
  # HTS-identity date (resolved through archive_rev_id, so synthetic bnd_ rows
  # inherit their owner's identity).
  plan <- tryCatch(
    resolve_daily_weight_plan(
      hts_as_of_dates = hts_as_of_dates_from_timeline(ri),
      weight_mode = if (unweighted) 'unweighted' else NULL
    ),
    error = function(e) {
      message('  Daily part precompute skipped (weights unavailable): ',
              conditionMessage(e))
      NULL
    }
  )

  if (!is.null(plan)) {
    common <- list(snapshot = res$rates, revision = rev_id,
                   valid_from = valid_from, valid_until = valid_until,
                   output_dir = output_dir, policy_params = pp_build)
    if (identical(plan$weight_mode, 'unweighted')) {
      do.call(write_daily_part_for_snapshot, common)
    } else if (identical(plan$weight_method, 'static')) {
      do.call(write_daily_part_for_snapshot, c(common, list(imports = plan$imports)))
    } else {
      do.call(write_daily_part_for_snapshot,
              c(common, list(imports_fn = plan$imports_fn,
                             hts_as_of_date = plan$hts_as_of_dates[[rev_id]])))
    }
  }
}
