# =============================================================================
# Backfill daily_by_hs into an existing published vintage (post-processing)
# =============================================================================
#
# daily_by_hs is a pure post-process of the rate panel + import weights (same
# inputs as daily_by_category) — no rebuild needed. This reads an existing
# vintage's per-interval snapshots (actual/ + each scenario), reruns the daily
# aggregation to produce daily_by_hs.{csv,parquet}, and writes it next to the
# existing daily files.
#
# Self-validating: it also recomputes daily_overall and daily_by_category and
# checks them against the published files. If those match to rounding, the
# weight base / policy params / stacking / intervals all match the build, so
# the daily_by_hs from the same run is trustworthy.
#
# Usage:
#   Rscript scripts/backfill_daily_by_hs.R <vintage_dir> [--write]
#     (omit --write for a dry run: validate + report, do not touch files)
# =============================================================================

suppressMessages({
  library(tidyverse); library(here); library(arrow)
  source(here('src', 'core', 'helpers.R'))
  source(here('src', 'model', 'rate_schema.R'))
  source(here('src', 'model', 'stacking.R'))
  source(here('src', 'model', 'policy_params.R'))
  source(here('src', 'model', 'revisions.R'))
  source(here('src', 'pipeline', '09_daily_series.R'))
  source(here('src', 'io', 'build_import_weights.R'))
  source(here('src', 'io', 'build_panel_import_weights.R'))
})

args <- commandArgs(trailingOnly = TRUE)
pos <- args[!grepl('^--', args)]
vintage <- pos[1]
do_write <- '--write' %in% args
# Optional: --out-root <dir> writes daily_by_hs into <dir>/<series-rel>/daily/
# instead of into the (possibly read-only) vintage. Validation still reads the
# published files in the vintage.
out_root <- if (length(pos) >= 2) pos[2] else NA
if (is.na(vintage) || !dir.exists(vintage)) stop('Pass an existing vintage dir')

pp <- load_policy_params()

# Reproduce the SAME weights the daily build used. Under weight_method=484f that
# means the per-interval provider, so the recompute must key each interval's
# weights to that revision's HTS identity — same as the array build. The
# per-revision HTS-identity dates come from the array timeline (archive_rev_id,
# so synthetic bnd_/sched_ rows inherit their owner); it is REQUIRED for the 484f
# method here. The self-check below confirms the recompute matches the published
# daily.
timeline_path <- Sys.getenv('REV_TIMELINE', 'output/build_array_timeline.rds')
timeline <- if (file.exists(timeline_path)) {
  readRDS(timeline_path) %>% mutate(effective_date = as.Date(effective_date))
} else NULL
hts_as_of_dates <- if (!is.null(timeline)) hts_as_of_dates_from_timeline(timeline) else NULL
weight_plan <- resolve_daily_weight_plan(hts_as_of_dates = hts_as_of_dates)
if (identical(weight_plan$weight_method, '484f') && is.null(hts_as_of_dates)) {
  stop('backfill_daily_by_hs: weight_method=484f needs per-revision HTS-identity ',
       'dates. Set REV_TIMELINE to the vintage\'s build_array_timeline.rds, or set ',
       'weight_method: static in config/local_paths.yaml for a legacy recompute.',
       call. = FALSE)
}

# Recompute one series (actual or a scenario) from its published parquet
# partitions, mirroring build_daily_aggregates_streaming (per-snapshot -> bind).
process_series <- function(series_dir) {
  snap_dir <- file.path(series_dir, 'snapshots')
  parts <- list.files(snap_dir, pattern = '^valid_from=', full.names = TRUE)
  parts <- parts[dir.exists(parts)]
  message('  ', basename(dirname(series_dir)), '/', basename(series_dir),
          ': ', length(parts), ' interval(s)')
  res <- lapply(parts, function(pd) {
    snap <- read_parquet(file.path(pd, 'rates.parquet')) %>% enforce_rate_schema()
    suppressMessages(build_daily_aggregates(
      snap, imports = weight_plan$imports, imports_fn = weight_plan$imports_fn,
      hts_as_of_dates = weight_plan$hts_as_of_dates, policy_params = pp))
  })
  list(
    daily_overall     = bind_rows(lapply(res, `[[`, 'daily_overall')),
    daily_by_category = bind_rows(lapply(res, `[[`, 'daily_by_category')),
    daily_by_hs       = bind_rows(lapply(res, `[[`, 'daily_by_hs'))
  )
}

# Compare recomputed vs published weighted_etr on the shared key; report max |Δ|.
check_against_published <- function(recomp, published_csv, key) {
  if (!file.exists(published_csv)) { message('    (no published ', basename(published_csv), ' to check)'); return(invisible()) }
  pub <- suppressMessages(read_csv(published_csv, show_col_types = FALSE))
  j <- inner_join(
    recomp %>% select(all_of(c(key, 'weighted_etr'))) %>% rename(recomp = weighted_etr),
    pub    %>% select(all_of(c(key, 'weighted_etr'))) %>% rename(pub = weighted_etr),
    by = key)
  md <- max(abs(j$recomp - j$pub), na.rm = TRUE)
  message(sprintf('    check %-18s rows=%d  max|Δ weighted_etr|=%.3e  %s',
                  basename(published_csv), nrow(j), md,
                  if (md < 1e-6) 'OK' else '*** MISMATCH ***'))
  md
}

series_dirs <- c(file.path(vintage, 'actual'),
                 list.files(file.path(vintage, 'scenarios'), full.names = TRUE))
series_dirs <- series_dirs[dir.exists(file.path(series_dirs, 'snapshots'))]

for (sd in series_dirs) {
  out <- process_series(sd)
  daily_dir <- file.path(sd, 'daily')
  # Validate the recompute reproduces the shipped numbers before writing.
  d_ov  <- check_against_published(out$daily_overall,     file.path(daily_dir, 'daily_overall.csv'),     'date')
  d_cat <- check_against_published(out$daily_by_category, file.path(daily_dir, 'daily_by_category.csv'),  c('date', 'gtap_code'))
  consistent <- all(c(d_ov, d_cat) < 1e-6, na.rm = TRUE)

  byhs <- out$daily_by_hs
  message('    daily_by_hs: ', nrow(byhs), ' rows, ',
          n_distinct(byhs$category_code), ' categories, dates ',
          as.character(min(byhs$date)), '..', as.character(max(byhs$date)))
  if (do_write) {
    if (!consistent) stop('Recompute does not match published daily for ', sd,
                          ' — refusing to write daily_by_hs (inputs differ from the build).')
    dest_daily <- if (is.na(out_root)) daily_dir else {
      rel <- substring(normalizePath(sd), nchar(normalizePath(vintage)) + 2L)
      d <- file.path(out_root, rel, 'daily'); dir.create(d, recursive = TRUE, showWarnings = FALSE); d
    }
    write_csv(byhs, file.path(dest_daily, 'daily_by_hs.csv'))
    write_parquet_if_arrow(byhs, file.path(dest_daily, 'daily_by_hs.csv'))
    message('    WROTE ', file.path(dest_daily, 'daily_by_hs.{csv,parquet}'))
  } else {
    message('    (dry run — pass --write to emit files)')
  }
}
message('Done.')
