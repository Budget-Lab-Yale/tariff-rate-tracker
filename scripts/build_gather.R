#!/usr/bin/env Rscript
# =============================================================================
# build_gather.R — gather step for the array build
# =============================================================================
#
# Run AFTER all array tasks (scripts/build_revision.R) have written their
# snapshot_<rev>.rds + ch99_/products_ caches. Does the cross-revision work the
# per-revision tasks deliberately skip, then the downstream:
#   1. deltas        — compare consecutive cached parses -> delta_<rev>.rds
#   2. products_raw  — data/processed/products_raw.csv from the latest revision
#                      (matches the serial loop's "last write wins")
#   3. downstream    — daily series from array-written aggregate parts when
#                      complete, otherwise streamed from snapshots; quality report
#                      streams snapshots
#   4. metadata      — metadata.rds freshness marker for publish
#
# Mirrors the serial build's post-loop + downstream so the array build's outputs
# match a serial build within parity tolerance.
#
# Usage:
#   Rscript scripts/build_gather.R [--unweighted] [--use-hts-dates]
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(tidyverse)
  library(jsonlite)
})
suppressMessages({
  source(here('src', 'pipeline', '00_build_timeseries.R'))   # build helpers + scheduled activations
  source(here('src', 'model', 'revisions.R'))
  source(here('src', 'model', 'policy_params.R'))
  source(here('src', 'pipeline', '09_daily_series.R'))
  source(here('src', 'io', 'quality_report.R'))
  source(here('src', 'io', 'build_import_weights.R'))
  source(here('src', 'io', 'build_panel_import_weights.R'))
})

args <- commandArgs(trailingOnly = TRUE)
use_policy_dates <- !('--use-hts-dates' %in% args)
unweighted <- '--unweighted' %in% args
allow_partial <- '--allow-partial' %in% args   # opt out of the completeness gate

# Scenario harness (counterfactual): --scenario <name> (or TARIFF_SCENARIO env).
# A named scenario deep-merges config/scenarios/<name>/overlay.yaml into pp and
# writes an isolated data/timeseries/<name>/ panel, REUSING the baseline real-
# revision snapshots (symlinked below) — only the synthetic future revisions are
# rebuilt with the scenario's pp. 'actual'/'baseline'/unset => the canonical
# baseline, byte-identical. See src/model/policy_params.R (.deep_merge_lists).
scenario <- ''
for (i in seq_along(args)) if (args[i] == '--scenario' && i < length(args)) scenario <- args[i + 1]
if (!nzchar(scenario)) scenario <- Sys.getenv('TARIFF_SCENARIO', '')
is_baseline <- !nzchar(scenario) || scenario %in% c('actual', 'baseline')
# Propagate to any nested load_policy_params().
Sys.setenv(TARIFF_SCENARIO = if (is_baseline) '' else scenario)

# Downstream output placement is series-aware (src/io/output_paths.R): the writers route
# their section dir through series_section_dir(), which reads TARIFF_SERIES — 'actual'
# -> output_root()/actual/<section>, a scenario name -> output_root()/scenarios/<name>/
# <section>. The orchestrator (scripts/submit_build_array.sh) sets TARIFF_SERIES +
# TARIFF_OUTPUT_DIR per series, so this gather no longer routes output itself.

# Where the array tasks wrote their snapshots. Overridable (TARIFF_TS_DIR) so the
# gather can read an isolated candidate build without touching data/timeseries —
# mirrors scripts/build_revision.R. A named scenario derives its own dir.
# The `actual`-series scratch dir a scenario reuses real-revision snapshots from.
# Orchestrator sets TARIFF_BASELINE_TS_DIR to the run's actual scratch dir; falls
# back to the in-repo data/timeseries for legacy invocations.
baseline_dir <- Sys.getenv('TARIFF_BASELINE_TS_DIR', unset = here('data', 'timeseries'))
ts_dir_env <- Sys.getenv('TARIFF_TS_DIR')
output_dir <- if (nzchar(ts_dir_env)) {
  ts_dir_env
} else if (is_baseline) {
  baseline_dir
} else {
  here('data', 'timeseries', scenario)
}

init_logging(
  # Logs go to TARIFF_LOG_DIR (the run's external scratch) when set, so they stay
  # out of the published vintage; otherwise TARIFF_OUTPUT_DIR/logs (or output/logs).
  log_file = file.path(ensure_dir(Sys.getenv('TARIFF_LOG_DIR',
                         unset = file.path(Sys.getenv('TARIFF_OUTPUT_DIR', unset = here('output')), 'logs'))),
                       paste0('gather_', format(Sys.time(), '%Y%m%d_%H%M%S'), '.log')),
  level = 'info'
)

pp <- load_policy_params(use_policy_dates = use_policy_dates,
                         scenario = if (is_baseline) NULL else scenario)
timeline_path <- Sys.getenv('REV_TIMELINE', 'output/build_array_timeline.rds')
if (!file.exists(timeline_path)) {
  stop('revision timeline not found: ', timeline_path,
       ' — run scripts/list_revisions.R before build_gather.R', call. = FALSE)
}
rev_dates <- readRDS(timeline_path) %>%
  mutate(effective_date = as.Date(effective_date))

# --- Scenario reuse: hydrate the isolated output_dir from the baseline build ---
# Symlink the baseline REAL-revision snapshots + parse caches into the scenario
# dir so the gather can reuse real-revision artifacts. Synthetic bnd_/sched_ rows
# are array-built from the timeline. No-op for baseline.
if (!is_baseline &&
    normalizePath(output_dir, mustWork = FALSE) != normalizePath(baseline_dir, mustWork = FALSE)) {
  ensure_dir(output_dir)
  real_revs <- rev_dates$revision[!grepl('^(sched_|bnd_)', rev_dates$revision)]
  linked <- 0L
  for (rev in real_revs) {
    for (pat in c('snapshot_', 'ch99_', 'products_', 'delta_', 'daily_part_', 'quality_part_')) {
      src <- file.path(baseline_dir, paste0(pat, rev, '.rds'))
      dst <- file.path(output_dir, paste0(pat, rev, '.rds'))
      if (file.exists(src) && !file.exists(dst)) {
        file.symlink(normalizePath(src), dst)
        linked <- linked + 1L
      }
    }
  }
  message('Scenario "', scenario, '": hydrated ', output_dir, ' with ',
          linked, ' baseline artifact symlink(s) across ', length(real_revs), ' revisions')
}

# Ordered list of revisions that actually have a snapshot on disk.
all_revs <- rev_dates$revision
have_snap <- file.exists(file.path(output_dir, paste0('snapshot_', all_revs, '.rds')))
ordered <- rev_dates %>%
  filter(revision %in% all_revs[have_snap]) %>%
  arrange(effective_date) %>%
  pull(revision)
if (length(ordered) == 0) stop('No snapshots found in ', output_dir, ' — run the array build first.')
message('Gathering ', length(ordered), ' revisions: ', ordered[1], ' .. ', ordered[length(ordered)])

# Horizon-start gate (mirror of assemble_timeseries' guard on the serial path):
# the array grid is windowed by list_revisions.R, so this is a no-op on the
# happy path — it exists for the bypass cases (foreign timeline rds, stale
# snapshots from a wider earlier run).
assert_within_series_window(rev_dates, ordered, pp$SERIES_HORIZON_START)

# Completeness gate (Finding 3): the array dispatches one task per revision that
# has a JSON archive (the same set list_revisions.R prints to size the array). If
# a task died, its snapshot is simply absent — and because the interval encoding
# stretches the prior revision over the gap, the assembled panel reads as policy
# stability rather than a missing revision. Reconcile the expected (available)
# set against what landed on disk and fail loud unless --allow-partial is set.
# When the array fully succeeded (the normal case), `missing_revs` is empty and
# this is a no-op — no stop(), identical assembly path.
expected_revs <- all_revs
missing_revs <- setdiff(expected_revs, ordered)
if (length(missing_revs) > 0 && !allow_partial) {
  stop('build_gather: ', length(missing_revs), ' of ', length(expected_revs),
       ' expected revision(s) have no snapshot in ', output_dir, ': ',
       paste(missing_revs, collapse = ', '),
       '. An array task likely failed; the assembled panel would silently ',
       'stretch a neighbouring revision over the gap. Re-run the failed ',
       'task(s), or pass --allow-partial to gather anyway.')
}
if (length(missing_revs) > 0) {
  warning('build_gather: gathering PARTIAL panel (--allow-partial) — ',
          length(missing_revs), ' expected revision(s) missing: ',
          paste(missing_revs, collapse = ', '))
}

# ---- 1. Deltas from cached parses (consecutive revisions) ----
message('Computing deltas from cached parses...')
prev_ch99 <- NULL; prev_products <- NULL
for (rev_id in ordered) {
  ch99_p <- file.path(output_dir, paste0('ch99_', rev_id, '.rds'))
  prod_p <- file.path(output_dir, paste0('products_', rev_id, '.rds'))
  if (!file.exists(ch99_p) || !file.exists(prod_p)) {
    warning('missing parse cache for ', rev_id, ' — skipping its delta'); next
  }
  ch99_data <- readRDS(ch99_p); products <- read_products_cache(prod_p)
  if (!is.null(prev_ch99)) {
    delta <- list(
      ch99 = compare_chapter99(prev_ch99, ch99_data),
      products = compare_products(prev_products, products)
    )
    saveRDS(delta, file.path(output_dir, paste0('delta_', rev_id, '.rds')))
  }
  prev_ch99 <- ch99_data; prev_products <- products
}

# ---- 2. products_raw.csv from the latest revision (serial "last write wins") ----
# Written into the scratch (output_dir = TARIFF_TS_DIR), NOT the repo — a transient
# intermediate the finalize discards (not part of the published vintage layout).
last_rev <- ordered[length(ordered)]
products_last <- read_products_cache(file.path(output_dir, paste0('products_', last_rev, '.rds')))
products_raw_path <- file.path(output_dir, 'products_raw.csv')
products_last %>%
  mutate(ch99_refs = vapply(ch99_refs, paste, FUN.VALUE = character(1), collapse = ';')) %>%
  select(hts10, base_rate, base_rate_raw, base_rate_type, ch99_refs, n_ch99_refs, description) %>%
  write_csv(products_raw_path)

# ---- 3. Downstream ----
# Daily binds the small daily_part_<rev>.rds files written by the array tasks
# while their snapshots were still in memory. The loader validates weight mode
# and final intervals first; missing/stale parts fail the gather.
# Quality currently streams snapshots serially.
# Neither needs the 204M-row rate_timeseries.rds. (Weighted-ETR / 08 was removed —
# the daily series already emits the import-weighted ETR columns it duplicated.)
# Weight plan resolved OUTSIDE tryCatch so a missing-weights failure aborts
# loudly. For the 484f method the daily loader validates each cached part's
# fingerprint against this plan's weight_context (built inputs + per-revision
# HTS-identity date via archive_rev_id); a mismatch fails the gather.
if (!unweighted) ensure_import_weights()
weight_plan <- resolve_daily_weight_plan(
  hts_as_of_dates = hts_as_of_dates_from_timeline(rev_dates),
  weight_mode = if (unweighted) 'unweighted' else NULL)
run_daily_series(snapshot_dir = output_dir, rev_dates = rev_dates,
                 imports = weight_plan$imports,
                 imports_fn = weight_plan$imports_fn,
                 hts_as_of_dates = weight_plan$hts_as_of_dates,
                 weight_context = weight_plan$weight_context,
                 policy_params = pp,
                 weight_mode = weight_plan$weight_mode)
quality <- tryCatch(
  run_quality_report(snapshot_dir = output_dir, rev_dates = rev_dates),
  error = function(e) {
    message('Quality report failed: ', conditionMessage(e))
    NULL
  })

# ---- 4. Metadata freshness marker ----
# The combined 204M-row rate_timeseries.rds is no longer a core/publish output.
# Publish reads the per-revision snapshots directly, but it still needs a small
# metadata file as the "this build finalized" marker and for data-as-of info.
present_revs <- rev_dates %>%
  filter(file.exists(file.path(output_dir, paste0('snapshot_', revision, '.rds')))) %>%
  arrange(effective_date) %>%
  pull(revision)
synth <- save_synthetic_revision_dates(rev_dates, output_dir)
metadata <- list(
  last_revision = last_rev,
  last_build_time = Sys.time(),
  n_revisions = length(present_revs),
  n_rows = if (!is.null(quality$n_rows)) quality$n_rows else NA_integer_,
  scenario = if (is_baseline) 'baseline' else scenario,
  expected_revisions = expected_revs,
  skipped_revisions = setdiff(expected_revs, present_revs)
)
if (nrow(synth) > 0) {
  metadata$synthetic_revisions <- synth %>%
    select(revision, effective_date) %>%
    mutate(effective_date = as.character(effective_date))
}
saveRDS(metadata, file.path(output_dir, 'metadata.rds'))
message('Wrote metadata: ', file.path(output_dir, 'metadata.rds'))
message('Gather complete (streaming; combined panel skipped).')

# The gather wrote this series' daily/quality DIRECTLY into the vintage
# (TARIFF_OUTPUT_DIR), and left its snapshot_<rev>.rds + metadata.rds in the
# scratch (TARIFF_TS_DIR). Finalizing — splitting the scratch snapshots into the
# vintage's snapshots/ parquet, writing the manifest, repointing `latest`, and
# removing the scratch — is the orchestrator's single finalize step
# (scripts/submit_build_array.sh -> scripts/publish_vintage.R) once ALL series'
# gathers have completed. Not done here.
