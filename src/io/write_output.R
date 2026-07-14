# =============================================================================
# Write Build Output to the Model-Data Interface
# =============================================================================
#
# Writes the build's output — the per-interval rate panel (Parquet, the format
# tariff-model reads) plus daily/quality/etr — to the configured model-data
# interface folder (config: model_data_root) as an hour-stamped immutable
# vintage, and repoints `latest`. This is simply WHERE the build's output goes,
# not a separate "publish" step — the gather calls write_build_output() at the
# end of every baseline build.
#
# Layout (under <shared_root>):
#
#   Tariff-Rate-Tracker/
#     2026-05-08/
#       actual/
#         snapshots/
#           valid_from=2025-01-01/rates.parquet
#           valid_from=2025-01-27/rates.parquet
#           ...
#           metadata.rds
#         daily/         <- output/actual/daily/*.csv
#         quality/       <- output/actual/quality/*
#         etr/           <- output/actual/etr/*     (if built)
#         etrs_config/   <- output/actual/etrs_config/*  (if built)
#       scenarios/
#         <name>/        <- output/scenarios/<name>/*   (per named what-if)
#       manifest.json
#
# The rate panel lives under actual/snapshots/ as per-interval parquet
# partitions. tariff-model reads the snapshot layout directly; the former
# single rate_timeseries.rds/parquet monolith is no longer published.
#     2026-05-09/
#       ...
#     latest -> 2026-05-09
#
# Vintages are immutable. Re-running within the same hour appends `_2`,
# `_3`, ... . An alternatives-only build produces a new vintage with the panel
# re-copied (cheap immutability over hardlink dedup).
#
# Usage (programmatic):
#
#   source(here('src', 'io', 'write_output.R'))
#   write_build_output(
#     build_flags = list(full = TRUE, core_only = TRUE, with_alternatives = FALSE),
#     build_started_at = Sys.time()
#   )
#
# =============================================================================

library(jsonlite)
library(here)

source(here('src', 'io', 'output_paths.R'))   # Phase 5 layout helpers (actual/ + scenarios/)
source(here('src', 'model', 'rate_schema.R'))    # enforce_rate_schema + build_rev_intervals (loads tidyverse)
source(here('src', 'model', 'revisions.R'))      # load_revision_dates
source(here('src', 'model', 'policy_params.R'))  # load_policy_params -> SERIES_HORIZON_END + load_local_paths
source(here('src', 'io', 'build_panel_import_weights.R'))  # forward-mapped HS10 x country import weights


# Model-data interface root — read from config (config/local_paths.yaml:
# model_data_root), NOT hardcoded. Single external location the build publishes
# hour-stamped output vintages to and where parity references live; never the repo.
SHARED_ROOT_DEFAULT <- tryCatch(load_local_paths()$model_data_root, error = function(e) NULL)


#' Publish a curated subset of build outputs to the shared model-data tree
#'
#' @param shared_root Root directory under which dated vintages are written.
#' @param vintage Vintage identifier; defaults to the hour-aligned id
#'   (YYYY-MM-DD-HH). Pass an explicit string to override.
#' @param repo_root Repo root from which outputs are read.
#' @param build_flags Named list of CLI flags actually used (recorded in manifest).
#' @param build_started_at POSIXct; recorded in manifest. Defaults to now.
#' @param dry_run If TRUE, plan only — log the copy list and manifest without
#'   touching the shared tree.
#' @param update_latest If TRUE (default), repoint <shared_root>/latest at this
#'   vintage. Set FALSE to publish an additive vintage without changing the
#'   shared default (e.g. publishing into a tree another owner maintains).
#' @param include_scenarios If TRUE (default), publish every dir under
#'   output/scenarios/. Set FALSE to publish only the actual/ (current-law)
#'   tree — e.g. when scenario outputs are stale or intentionally withheld.
#' @param snapshot_src_root Dir holding the actual `snapshot_<rev>.rds` (+ a
#'   `<name>/` subdir per scenario) to split into parquet. Defaults to
#'   `<repo_root>/data/timeseries`. The finalize step points this at the run's
#'   external scratch.
#' @param output_src_root Dir holding the daily/quality/etr sections to publish.
#'   Defaults to `<repo_root>/output`. The finalize step points this at the
#'   vintage itself (the gather wrote the sections there directly), so they are
#'   inventoried in place rather than copied.
#' @param wipe_vintage If TRUE (default) the vintage dir is cleared before
#'   writing (standalone publish owns the whole dir). FALSE when the gather
#'   already populated it — only the snapshots/ subdir is rebuilt.
#' @return Invisibly, a list with `vintage`, `vintage_dir`, `manifest`, and
#'   `n_files` on success; NULL on dry-run.
write_build_output <- function(shared_root = SHARED_ROOT_DEFAULT,
                             vintage = NULL,
                             repo_root = here(),
                             build_flags = list(),
                             build_started_at = Sys.time(),
                             dry_run = FALSE,
                             update_latest = TRUE,
                             include_scenarios = TRUE,
                             snapshot_src_root = NULL,
                             output_src_root = NULL,
                             wipe_vintage = TRUE,
                             weight_mode = NULL,
                             weight_method = NULL) {

  # Snapshots (the per-revision snapshot_<rev>.rds the finalize splits into
  # parquet) and the already-written daily/quality sections can come from
  # different roots. The finalize step (scripts/publish_vintage.R) reads
  # snapshots from the run's external scratch but the daily/quality already live
  # in the vintage itself (the gather wrote them there directly) — so it passes
  # output_src_root = vintage_dir and wipe_vintage = FALSE, and publish_dir
  # inventories those in place instead of copying. Both default to the repo-
  # layout under repo_root for the standalone CLI / legacy callers.
  if (is.null(snapshot_src_root)) snapshot_src_root <- file.path(repo_root, 'data', 'timeseries')
  if (is.null(output_src_root))   output_src_root   <- file.path(repo_root, 'output')

  if (!requireNamespace('arrow', quietly = TRUE)) {
    stop('write_build_output requires the arrow package (parquet conversion). ',
         'Install with: Rscript tools/install_dependencies.R --all')
  }
  if (!requireNamespace('digest', quietly = TRUE)) {
    stop('write_build_output requires the digest package (manifest sha256). ',
         'Install with: Rscript tools/install_dependencies.R --all')
  }

  metadata_path <- file.path(snapshot_src_root, 'metadata.rds')
  # Staleness guard: when called from a build run, refuse to publish a snapshot
  # panel that was not finalized by this build. Individual snapshots may be
  # older on legitimate incremental builds, so metadata.rds is the freshness
  # marker. Skipped for standalone publish and alternatives-only publishes.
  if (!is.null(build_started_at) && !isTRUE(build_flags$alternatives_only)) {
    if (!file.exists(metadata_path)) {
      stop('Cannot publish: metadata.rds not found at ', metadata_path,
           '. Run the build/gather first.')
    }
    meta_mtime <- file.info(metadata_path)$mtime
    if (!is.na(meta_mtime) && meta_mtime < build_started_at) {
      stop('Cannot publish: metadata.rds (mtime ', meta_mtime,
           ') is older than the current build start (', build_started_at, '). ',
           'The current build did not finalize the snapshot panel — refusing to publish stale snapshots.')
    }
  }

  if (is.null(shared_root) || !nzchar(shared_root)) {
    stop('model_data_root is not set in config/local_paths.yaml. The build writes ',
         'its output there — there is no in-repo output mode and no hardcoded fallback.')
  }

  if (!dir.exists(shared_root)) {
    if (!dry_run) dir.create(shared_root, recursive = TRUE)
    message('publish: created shared root ', shared_root)
  }

  if (is.null(vintage)) vintage <- resolve_vintage()
  vintage_dir <- file.path(shared_root, vintage)
  # Hour-aligned: the vintage IS this build's output for the hour. A rebuild in
  # the same hour replaces it wholesale (no stale files linger from a prior run).
  # When wipe_vintage is FALSE the gather has already written daily/quality into
  # the vintage; we must NOT clear it — only the snapshots/ subdir is rebuilt
  # fresh (publish_series_snapshots unlinks its own dest).
  if (!dry_run && wipe_vintage && dir.exists(vintage_dir)) unlink(vintage_dir, recursive = TRUE)

  message('\n', strrep('=', 70))
  message('PUBLISHING TO SHARED MODEL DATA')
  message(strrep('=', 70))
  message('Shared root: ', shared_root)
  message('Vintage:     ', vintage)
  message('Repo root:   ', repo_root)
  if (dry_run) message('DRY RUN — no files will be written')
  message(strrep('=', 70))

  if (!dry_run) dir.create(vintage_dir, recursive = TRUE, showWarnings = FALSE)

  # Interval encoding is recomputed from the policy revision calendar — the
  # authoritative source build_rev_intervals() uses everywhere — not read from a
  # snapshot's stored valid_* (which assemble_timeseries strips and rebuilds).
  # Defaults match the production build: policy dates + SERIES_HORIZON_END from
  # policy_params.yaml. The round-trip verification (per-interval row counts vs
  # the combined rds) would catch any convention drift.
  rev_dates   <- load_revision_dates()
  horizon_end <- load_policy_params()$SERIES_HORIZON_END %||% Sys.Date()
  actual_ts_dir <- snapshot_src_root
  rev_dates_actual <- load_augmented_revision_dates(actual_ts_dir, rev_dates)

  copied <- list()
  out_root <- output_src_root

  copied$timeseries <- publish_timeseries(snapshot_src_root, vintage_dir,
                                          rev_dates = rev_dates_actual,
                                          horizon_end = horizon_end,
                                          dry_run = dry_run)

  # Per-series snapshot records for the manifest `series` block. `actual` is
  # always present; in addition, every data/timeseries/<name>/ directory holding
  # snapshot_*.rds is published as scenarios/<name> via the same splitter. None
  # exist today — a clean no-op until the build writes per-scenario snapshots.
  series_snapshots <- list(actual = copied$timeseries$snapshots)
  if (include_scenarios) {
    ts_src_root <- snapshot_src_root
    for (sub in list.dirs(ts_src_root, recursive = FALSE)) {
      if (length(list.files(sub, pattern = '^snapshot_.*\\.rds$')) == 0) next
      name <- basename(sub)
      sub_rev_dates <- load_augmented_revision_dates(sub, rev_dates)
      recs <- publish_series_snapshots(sub, scenario_snapshots_dir(vintage_dir, name),
                                       rev_dates = sub_rev_dates, horizon_end = horizon_end,
                                       dry_run = dry_run)
      if (isTRUE(recs$present)) {
        series_snapshots[[paste0('scenarios/', name)]] <- recs$snapshots
        message('publish: scenario snapshots [', name, '] -> ',
                length(recs$snapshots), ' interval(s)')
      }
    }
  }

  # Per-vintage import-weight base, keyed to THIS panel's HS10 universe so a
  # downstream model can roll the rate panel up by import value with an exact
  # (hts10, country) join — no statistical-suffix vintage mismatch. 2024 Census
  # customs-value flows are mapped forward onto the panel codes (orphan value on
  # retired suffixes is redistributed within the stable 8-digit heading; see
  # src/io/build_panel_import_weights.R). Keyed to the actual panel; scenarios share
  # that same HS10 universe, so one base serves every series. Best-effort: a
  # weights failure warns and continues — it must never block the panel publish.
  # --- Weights (weight-mode plumbing; never inferred from a missing file) -----
  # weight_mode: 'required' (default) makes a weights-build failure ABORT the
  # finalize — no best-effort warn-and-drop. 'unweighted' publishes the rate
  # panel with weights.present = false and an explicit reason.
  # weight_method: '484f' (default) maps the 2024 base onto the tip panel at the
  # tip's HTS-identity date via the committed transfers crosswalk; 'static' is
  # the legacy direct forward-map.
  lp_w <- tryCatch(load_local_paths(), error = function(e) list())
  wmode   <- weight_mode   %||% (lp_w$weight_mode   %||% 'required')
  wmethod <- weight_method %||% (lp_w$weight_method %||% '484f')
  wmode   <- match.arg(wmode,   c('required', 'unweighted'))
  wmethod <- match.arg(wmethod, c('484f', 'static'))
  copied$weights <- list(present = FALSE, files = character(),
                         weight_mode = wmode, reason = NA_character_)
  weights_prov <- NULL
  if (!dry_run) {
    if (identical(wmode, 'unweighted')) {
      copied$weights$reason <-
        'weight_mode=unweighted — weighted artifact intentionally skipped'
      message('publish: weight_mode=unweighted — no weights/ published.')
    } else {
      weights_dir <- file.path(vintage_dir, 'weights')
      snaps <- copied$timeseries$snapshots
      tip <- if (length(snaps)) snaps[[which.max(vapply(snaps,
               function(s) as.numeric(as.Date(s$valid_from)), numeric(1)))]] else NULL
      base_path      <- lp_w$import_weights %||% NULL
      xwalk_path     <- here('resources', 'hts10_484f_transfers.csv')
      overrides_path <- here('resources', 'hts10_484f_overrides.csv')
      shares_path    <- lp_w$split_share_imports %||% NULL
      if (!is.null(shares_path) && !file.exists(shares_path)) shares_path <- NULL
      if (!file.exists(overrides_path)) overrides_path <- NULL
      # Tip HTS-identity date (RAW effective_date), resolved through the tip's
      # archive_rev_id so a synthetic bnd_/sched_ tip inherits its owner's
      # identity. Only needed for the 484f method.
      hts_as_of <- if (identical(wmethod, '484f')) {
        resolve_tip_hts_as_of(actual_snapshots_dir(vintage_dir), snapshot_src_root)
      } else NULL
      # weight_mode=required: NO tryCatch — a failure aborts the finalize.
      res <- build_panel_import_weights(
        panel_codes    = current_panel_codes(actual_snapshots_dir(vintage_dir)),
        base_path      = base_path,
        out_dir        = weights_dir,
        year           = 2024L,
        hts_vintage    = if (!is.null(tip)) tip$revision else NA_character_,
        method         = wmethod,
        crosswalk_path = if (identical(wmethod, '484f')) xwalk_path else NULL,
        shares_path    = shares_path,
        overrides_path = overrides_path,
        hts_as_of_date = hts_as_of)
      copied$weights <- list(present = TRUE, files = res$files,
                             weight_mode = wmode, reason = NA_character_)
      weights_prov <- build_weights_provenance(
        res = res, weight_mode = wmode, weight_method = wmethod,
        base_path = base_path, shares_path = shares_path,
        crosswalk_path = xwalk_path, overrides_path = overrides_path,
        hts_as_of = hts_as_of,
        hts_vintage = if (!is.null(tip)) tip$revision else NA_character_,
        repo_root = repo_root)
      message('publish: weights -> ', weights_dir, ' (', wmethod, '; ',
              length(res$files), ' file', if (length(res$files) != 1) 's' else '', ')')
    }
  }

  # Phase 5: real ("actual") results publish into <vintage>/actual/<section>;
  # named what-ifs publish into <vintage>/scenarios/<name>. Section + root names
  # come from src/io/output_paths.R so the writers and publish can't drift apart.
  for (section in ACTUAL_SECTIONS) {
    copied[[section]] <- publish_dir(
      file.path(actual_root(out_root), section),
      file.path(vintage_dir, 'actual', section),
      min_mtime = build_started_at,
      dry_run = dry_run)
  }

  scen_root <- scenarios_root(out_root)
  if (include_scenarios && dir.exists(scen_root)) {
    for (scen_path in list.dirs(scen_root, recursive = FALSE)) {
      copied[[paste0('scenario.', basename(scen_path))]] <- publish_dir(
        scen_path,
        file.path(vintage_dir, 'scenarios', basename(scen_path)),
        min_mtime = build_started_at,
        dry_run = dry_run)
    }
  }

  manifest <- build_manifest(vintage = vintage,
                             vintage_dir = vintage_dir,
                             repo_root = repo_root,
                             build_flags = build_flags,
                             build_started_at = build_started_at,
                             copied = copied,
                             series_snapshots = series_snapshots,
                             weights_prov = weights_prov)

  if (!dry_run) {
    write(jsonlite::toJSON(manifest, pretty = TRUE, auto_unbox = TRUE, na = 'string'),
          file.path(vintage_dir, 'manifest.json'))
    if (update_latest) update_latest_symlink(shared_root, vintage)
  }

  n_snapshots <- sum(vapply(series_snapshots, length, integer(1)))
  n_files <- sum(vapply(copied, function(x) length(x$files), integer(1))) + n_snapshots
  message('\nPublished ', n_files, ' file(s) to ', vintage_dir,
          ' (', n_snapshots, ' interval snapshot', if (n_snapshots != 1) 's' else '', ')')
  if (update_latest) {
    message('Updated symlink: ', file.path(shared_root, 'latest'), ' -> ', vintage)
  } else {
    message('Left ', file.path(shared_root, 'latest'),
            ' unchanged (additive publish; update_latest = FALSE)')
  }
  message(strrep('=', 70), '\n')

  invisible(list(vintage = vintage,
                 vintage_dir = vintage_dir,
                 manifest = manifest,
                 n_files = n_files))
}

load_augmented_revision_dates <- function(snapshot_dir, rev_dates) {
  synth_path <- file.path(snapshot_dir, 'synthetic_revisions.rds')
  if (!file.exists(synth_path)) return(rev_dates)
  synth <- readRDS(synth_path)
  if (is.null(synth) || nrow(synth) == 0) return(rev_dates)
  synth <- synth %>%
    mutate(effective_date = as.Date(effective_date)) %>%
    select(any_of(names(rev_dates)))
  bind_rows(
    rev_dates %>% filter(!revision %in% synth$revision),
    synth
  )
}


#' Resolve the hour-aligned vintage identifier (YYYY-MM-DD-HH).
#'
#' The interface is keyed to the hour: a rebuild within the same hour overwrites
#' that hour's vintage (write_build_output clears the dir first). No collision
#' suffix — the vintage IS the hour.
#'
#' @keywords internal
resolve_vintage <- function() {
  format(Sys.time(), '%Y-%m-%d-%H')
}


#' Resolve worker count for the per-interval snapshot writers.
#'
#' Each worker holds one snapshot (~1.2 GB at production scale) plus a parquet
#' write buffer, so the cap is node memory, not CPU. TARIFF_PUBLISH_CORES first
#' (tune independently of the daily build), then the Slurm allocation, else 1.
#'
#' @keywords internal
resolve_publish_cores <- function() {
  cores <- suppressWarnings(as.integer(Sys.getenv('TARIFF_PUBLISH_CORES', unset = NA)))
  if (is.na(cores)) cores <- suppressWarnings(as.integer(Sys.getenv('SLURM_CPUS_PER_TASK', unset = NA)))
  if (is.na(cores) || cores < 1L) 1L else cores
}


#' Split a directory of per-revision snapshots into per-interval parquet files.
#'
#' Streams one snapshot_<rev>.rds at a time (never the full combined panel) into
#' Hive-style partitions:
#'   <dest_snaps_dir>/valid_from=YYYY-MM-DD/rates.parquet
#' attaching the AUTHORITATIVE interval (recomputed from rev_dates via
#' build_rev_intervals — the snapshot's own valid_* are not trusted, mirroring
#' build_daily_aggregates_streaming()). Each parquet carries the full rate schema
#' plus valid_from / valid_until (inclusive) as real columns, so a reader that
#' ignores Hive partitioning still gets the intervals.
#'
#' Revisions are independent, so the per-snapshot writes fan out across cores.
#' FAILS LOUD if any worker is lost: a dropped interval would silently omit a
#' policy window from the published panel.
#'
#' @param snapshot_dir Source dir of snapshot_<rev>.rds files
#' @param dest_snaps_dir Destination snapshots/ dir (rebuilt fresh)
#' @param rev_dates Revision-date table (load_revision_dates())
#' @param horizon_end Series horizon end (tip interval extends to it)
#' @param cores Worker count; resolve_publish_cores() when NULL
#' @param dry_run Plan only — compute intervals/records, write nothing
#' @return list(present, snapshots = list of {valid_from, valid_until, revision,
#'   path, n_rows}); present = FALSE when the dir has no snapshots
#' @keywords internal
publish_series_snapshots <- function(snapshot_dir, dest_snaps_dir,
                                     rev_dates, horizon_end,
                                     cores = NULL, dry_run = FALSE) {
  snaps <- list.files(snapshot_dir, pattern = '^snapshot_.*\\.rds$')
  if (length(snaps) == 0) {
    return(list(present = FALSE, snapshots = list()))
  }
  revs <- sub('^snapshot_(.*)\\.rds$', '\\1', snaps)
  ints <- build_rev_intervals(revs, rev_dates, as.Date(horizon_end))
  ints <- ints[order(ints$valid_from), , drop = FALSE]
  n <- nrow(ints)

  if (!dry_run) {
    unlink(dest_snaps_dir, recursive = TRUE)   # rebuild fresh: no stale partitions on a retried publish
    dir.create(dest_snaps_dir, recursive = TRUE, showWarnings = FALSE)
  }
  if (is.null(cores)) cores <- resolve_publish_cores()

  message('publish: ', n, ' interval snapshot(s) -> ', dest_snaps_dir,
          ' (cores=', cores, ')')

  write_one <- function(i) {
    rev_id <- ints$revision[i]
    vf <- ints$valid_from[i]
    vu <- ints$valid_until[i]
    snap <- enforce_rate_schema(
      readRDS(file.path(snapshot_dir, paste0('snapshot_', rev_id, '.rds'))))
    # Attach the authoritative interval (not the snapshot's stored valid_*).
    snap$revision    <- rev_id
    snap$valid_from  <- vf
    snap$valid_until <- vu
    dest <- snapshot_parquet_path(dest_snaps_dir, vf)
    if (!dry_run) {
      dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
      arrow::write_parquet(snap, dest, compression = 'snappy')
    }
    list(valid_from = format(vf, '%Y-%m-%d'),
         valid_until = format(vu, '%Y-%m-%d'),
         revision = rev_id, path = dest, n_rows = nrow(snap))
  }

  results <- if (cores > 1L && !dry_run) {
    parallel::mclapply(seq_len(n), write_one, mc.cores = cores, mc.preschedule = FALSE)
  } else {
    lapply(seq_len(n), write_one)
  }

  # FAIL LOUD — mirror build_daily_aggregates_streaming(): mclapply does NOT stop
  # on worker loss. A crashed worker returns a try-error; an OOM/signal-killed one
  # returns NULL. Either silently drops an interval, shortening the published
  # panel. Guard both.
  if (length(results) != n) {
    stop('publish snapshots: expected ', n, ' results, got ', length(results),
         ' — a worker was lost. Lower TARIFF_PUBLISH_CORES or raise job memory.')
  }
  bad <- !vapply(results, function(r) is.list(r) && !is.null(r[['path']]), logical(1))
  if (any(bad)) {
    why <- vapply(results[bad], function(r)
      if (inherits(r, 'try-error')) as.character(r) else '<killed: NULL result (OOM/signal)>',
      character(1))
    stop('publish snapshots LOST ', sum(bad), ' of ', n, ' interval(s): ',
         paste(ints$revision[bad], collapse = ', '), '\n',
         paste(why, collapse = '\n'),
         '\nLower TARIFF_PUBLISH_CORES or raise job memory.')
  }

  list(present = TRUE, snapshots = results)
}


#' Publish the baseline ("actual") rate panel as per-interval snapshots.
#'
#' Replaces the former single rate_timeseries.parquet/.rds: streams the
#' per-revision snapshots into <vintage>/actual/snapshots/valid_from=*/rates.parquet
#' and copies metadata.rds alongside. The combined panel is no longer published;
#' tariff-model's read_rate_panel.R reads the snapshot layout (John's switch).
#'
#' @keywords internal
publish_timeseries <- function(src_dir, vintage_dir, rev_dates, horizon_end,
                               cores = NULL, dry_run = FALSE) {
  dest_snaps <- actual_snapshots_dir(vintage_dir)

  res <- publish_series_snapshots(src_dir, dest_snaps,
                                  rev_dates = rev_dates, horizon_end = horizon_end,
                                  cores = cores, dry_run = dry_run)
  if (!isTRUE(res$present)) {
    stop('publish: no snapshot_*.rds in ', src_dir,
         ' — run the build before publishing.')
  }

  files <- character()
  src_meta <- file.path(src_dir, 'metadata.rds')
  if (file.exists(src_meta)) {
    dest_meta <- file.path(dest_snaps, 'metadata.rds')
    if (!dry_run) {
      dir.create(dest_snaps, recursive = TRUE, showWarnings = FALSE)
      file.copy(src_meta, dest_meta, overwrite = TRUE)
    }
    files <- c(files, dest_meta)
    message('  copied:    metadata.rds')
  }

  list(present = TRUE, files = files, snapshots = res$snapshots)
}


#' Copy a build output directory if it exists, recursively.
#'
#' When `min_mtime` is non-NULL, files older than that timestamp are skipped.
#' This prevents stale outputs from a previous build leaking into a new vintage
#' (e.g. a --build-only run should not bundle daily/ from an earlier run).
#'
#' @keywords internal
publish_dir <- function(src_dir, dest_dir, min_mtime = NULL, dry_run = FALSE) {
  if (!dir.exists(src_dir)) {
    message('publish: skipping (not present) ', src_dir)
    return(list(present = FALSE, files = character()))
  }

  # In-place section: the gather wrote this section straight into the vintage, so
  # src == dest. Nothing to copy — just inventory what is there for the manifest.
  in_place <- dir.exists(dest_dir) &&
    normalizePath(src_dir, mustWork = FALSE) == normalizePath(dest_dir, mustWork = FALSE)
  if (in_place) {
    files <- list.files(dest_dir, recursive = TRUE, full.names = TRUE,
                        all.files = FALSE, no.. = TRUE)
    files <- files[!file.info(files)$isdir]
    message('publish: ', basename(dest_dir), ' already in place (', length(files),
            ' file', if (length(files) != 1) 's' else '', ') — inventory only')
    return(list(present = TRUE, files = files))
  }

  src_files <- list.files(src_dir, recursive = TRUE, full.names = TRUE,
                          all.files = FALSE, no.. = TRUE)
  if (length(src_files) > 0) {
    info <- file.info(src_files)
    keep <- !info$isdir
    if (!is.null(min_mtime)) {
      stale <- info$mtime < min_mtime
      stale[is.na(stale)] <- FALSE
      n_stale <- sum(stale & keep)
      if (n_stale > 0) {
        message('publish: skipping ', n_stale, ' stale file(s) under ', src_dir,
                ' (older than build start)')
      }
      keep <- keep & !stale
    }
    src_files <- src_files[keep]
  }

  if (length(src_files) == 0) {
    message('publish: skipping (empty)       ', src_dir)
    return(list(present = TRUE, files = character()))
  }

  message('publish: ', basename(dest_dir), ' -> ', dest_dir,
          ' (', length(src_files), ' file', if (length(src_files) != 1) 's' else '', ')')

  if (!dry_run) dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)

  copied <- character()
  for (sf in src_files) {
    rel <- substring(sf, nchar(src_dir) + 2L)
    df <- file.path(dest_dir, rel)
    if (!dry_run) {
      dir.create(dirname(df), recursive = TRUE, showWarnings = FALSE)
      file.copy(sf, df, overwrite = TRUE)
    }
    copied <- c(copied, df)
  }

  list(present = TRUE, files = copied)
}


#' Tip revision's RAW HTS-identity date, resolving a synthetic bnd_/sched_ tip
#' through its archive_rev_id (from the scratch's synthetic_revisions.rds).
#'
#' @param snaps_dir published actual snapshots dir (for the tip revision id).
#' @param scratch_dir dir holding synthetic_revisions.rds (the build scratch).
#' @return a Date (NA if unresolvable).
#' @keywords internal
resolve_tip_hts_as_of <- function(snaps_dir, scratch_dir = NULL) {
  tip_rev <- tryCatch(tip_revision_from_snapshots(snaps_dir),
                      error = function(e) NA_character_)
  if (is.na(tip_rev)) return(as.Date(NA))
  arch <- tip_rev
  synth_path <- if (!is.null(scratch_dir)) file.path(scratch_dir, 'synthetic_revisions.rds') else NULL
  if (!is.null(synth_path) && file.exists(synth_path)) {
    synth <- tryCatch(readRDS(synth_path), error = function(e) NULL)
    if (!is.null(synth) && 'archive_rev_id' %in% names(synth)) {
      hit <- synth$archive_rev_id[synth$revision == tip_rev]
      if (length(hit) >= 1 && !is.na(hit[1]) && nzchar(hit[1])) arch <- hit[1]
    }
  }
  as.Date(.hts_identity_date(arch))
}


#' Assemble the manifest weights provenance block from a build_panel_import_weights
#' result + the resource files it consumed. Pure (only reads file hashes/sizes).
#'
#' @keywords internal
build_weights_provenance <- function(res, weight_mode, weight_method,
                                     base_path, shares_path, crosswalk_path,
                                     overrides_path, hts_as_of, hts_vintage,
                                     repo_root = here()) {
  file_sha <- function(f) if (!is.null(f) && file.exists(f))
    digest::digest(file = f, algo = 'sha256') else NA_character_
  file_rows <- function(f) if (!is.null(f) && file.exists(f)) {
    tryCatch(nrow(readRDS(f)), error = function(e) NA_integer_)
  } else NA_integer_
  st <- res$stats

  # Source 484(f) PDF hashes from the committed manifest (provenance only).
  src_manifest <- file.path(repo_root, 'data', '484f', 'source_manifest.csv')
  source_pdfs <- if (identical(weight_method, '484f') && file.exists(src_manifest)) {
    mf <- tryCatch(suppressMessages(readr::read_csv(src_manifest,
                    col_types = readr::cols(.default = readr::col_character()))),
                   error = function(e) NULL)
    if (!is.null(mf) && all(c('source_doc', 'sha256') %in% names(mf))) {
      lapply(seq_len(nrow(mf)), function(i)
        list(source_doc = mf$source_doc[i], sha256 = mf$sha256[i]))
    } else list()
  } else list()

  per_source <- if (!is.null(st$per_source)) {
    lapply(seq_len(nrow(st$per_source)), function(i)
      list(share_source = st$per_source$share_source[i],
           value_usd = st$per_source$value[i]))
  } else list()

  prov <- list(
    method                = weight_method,
    weight_mode           = weight_mode,
    mapper_schema_version = st$mapper_schema_version %||% NA,
    hts_as_of_date        = if (!is.null(hts_as_of)) as.character(hts_as_of) else NA_character_,
    hts_vintage           = as.character(hts_vintage),
    base = list(
      source_year        = 2024L,
      value_type         = 'customs_value',
      source_description = '2024 U.S. Census customs-value imports (HS10 x country)',
      path               = base_path %||% NA_character_,
      sha256             = file_sha(base_path),
      total_usd          = st$total_in %||% NA_real_,
      row_count          = file_rows(base_path)
    ),
    split_shares = if (!is.null(shares_path)) list(
      present            = TRUE,
      source_year        = 2025L,
      value_type         = 'customs_value',
      source_description = '2025 U.S. Census customs-value imports (HS10 x country) split-share base',
      path               = shares_path,
      sha256             = file_sha(shares_path),
      row_count          = file_rows(shares_path)
    ) else list(present = FALSE),
    crosswalk = list(
      path   = if (identical(weight_method, '484f')) crosswalk_path else NA_character_,
      sha256 = if (identical(weight_method, '484f')) file_sha(crosswalk_path) else NA_character_,
      n_transfer_dates = st$n_transfer_dates %||% NA_integer_
    ),
    overrides = list(
      path   = overrides_path %||% NA_character_,
      sha256 = file_sha(overrides_path)
    ),
    totals = list(
      total_in_usd  = st$total_in %||% NA_real_,
      total_out_usd = st$total_out %||% NA_real_,
      n_weight_rows = st$n_weight_rows %||% NA_integer_,
      n_global_fallback = st$n_global_fallback %||% NA_integer_
    ),
    value_by_share_source = per_source,
    source_pdfs = source_pdfs
  )
  list(weight_mode = weight_mode, method = weight_method, provenance = prov)
}


#' Build the per-vintage manifest.
#'
#' @param series_snapshots Named list keyed by series ("actual",
#'   "scenarios/<name>"), each a list of per-interval records
#'   {valid_from, valid_until, revision, path, n_rows}. Rendered into the
#'   manifest `series` block with sha256 + size_bytes. These panel parquets are
#'   listed ONLY there — not in the flat `files` inventory — to avoid hashing
#'   every interval twice.
#' @keywords internal
build_manifest <- function(vintage, vintage_dir, repo_root,
                           build_flags, build_started_at, copied,
                           series_snapshots = list(),
                           weights_prov = NULL) {
  relativize      <- function(f) sub(paste0('^', vintage_dir, '/?'), '', f)
  file_sha256     <- function(f) if (file.exists(f)) digest::digest(file = f, algo = 'sha256') else NA_character_
  file_size_bytes <- function(f) if (file.exists(f)) as.integer(file.info(f)$size) else NA_integer_

  all_files <- unlist(lapply(copied, function(x) x$files), use.names = FALSE)
  inventory <- lapply(all_files, function(f) {
    list(path = relativize(f), size_bytes = file_size_bytes(f), sha256 = file_sha256(f))
  })

  # Per-series interval snapshots = the rate panel partitioned by valid_from
  # (same logical rows as the former single rate_timeseries.parquet).
  series <- lapply(series_snapshots, function(snaps) {
    list(snapshots = lapply(snaps, function(s) list(
      revision    = s$revision,
      valid_from  = s$valid_from,
      valid_until = s$valid_until,
      path        = relativize(s$path),
      sha256      = file_sha256(s$path),
      size_bytes  = file_size_bytes(s$path),
      n_rows      = s$n_rows
    )))
  })

  # Self-describing pointer to the import-weight base (if it was emitted), so a
  # consumer locates it deterministically instead of grepping the flat inventory.
  weights_files <- if (!is.null(copied$weights)) copied$weights$files else character()
  weights_pq <- weights_files[grepl('import_weights_hs10_country\\.parquet$', weights_files)]
  weights_block <- if (length(weights_pq) > 0) {
    blk <- list(
      present      = TRUE,
      weight_mode  = if (!is.null(weights_prov)) weights_prov$weight_mode else NA_character_,
      method       = if (!is.null(weights_prov)) weights_prov$method else NA_character_,
      path         = relativize(weights_pq[1]),
      keys         = c('hts10', 'country'),
      columns      = c('hts10', 'country', 'imports', 'import_value_year', 'hts_vintage'),
      imports_unit = 'USD',
      note = paste0('2024 Census customs-value imports mapped onto this ',
                    'vintage\'s panel HS10 universe; country = Census cty_code. ',
                    'Joins the rate panel exactly on (hts10, country); zero-import ',
                    'panel pairs are omitted.')
    )
    # Merge the full 484f provenance (base/shares hashes+totals, crosswalk +
    # overrides paths+hashes, mapper version, per-share-source $, source PDFs).
    if (!is.null(weights_prov)) blk$provenance <- weights_prov$provenance
    blk
  } else {
    # weights_mode=unweighted, or no weighted artifact was produced. Never infer
    # from a missing file — carry the explicit reason forward.
    list(present = FALSE,
         weight_mode = if (!is.null(copied$weights)) copied$weights$weight_mode else NA_character_,
         reason = if (!is.null(copied$weights)) (copied$weights$reason %||% NA_character_) else NA_character_)
  }

  git_info <- capture_git_info(repo_root)

  pkgs <- c('tidyverse', 'jsonlite', 'yaml', 'here', 'arrow', 'digest', 'pdftools')
  pkg_versions <- vapply(pkgs, function(p) {
    if (requireNamespace(p, quietly = TRUE)) as.character(utils::packageVersion(p)) else NA_character_
  }, character(1))

  list(
    schema_version = '2.0',                 # 2.0 = per-interval snapshot layout (1.x = single rate_timeseries.parquet)
    rate_unit = 'fraction',
    interval_end = 'inclusive',             # valid_until = next effective_date - 1 (last active day)
    country_code_vocabulary = 'U.S. Census Bureau country codes, see resources/census_codes.csv (column: country)',
    vintage = vintage,
    build_started_at = if (is.null(build_started_at)) NA_character_ else format(build_started_at, '%Y-%m-%dT%H:%M:%S%z'),
    published_at = format(Sys.time(), '%Y-%m-%dT%H:%M:%S%z'),
    repo_root = repo_root,
    git = git_info,
    build_flags = build_flags,
    sections = vapply(names(copied), function(k) copied[[k]]$present, logical(1)),
    r_version = paste(R.version$major, R.version$minor, sep = '.'),
    package_versions = as.list(pkg_versions),
    series = series,
    weights = weights_block,
    files = inventory
  )
}


#' Best-effort capture of git commit, branch, and dirty bit. NA if not a repo.
#'
#' @keywords internal
capture_git_info <- function(repo_root) {
  is_repo <- system2('git', c('-C', repo_root, 'rev-parse', '--is-inside-work-tree'),
                     stdout = TRUE, stderr = FALSE)
  if (length(is_repo) == 0 || !identical(trimws(is_repo[1]), 'true')) {
    return(list(commit = NA_character_, branch = NA_character_,
                dirty = NA, remote = NA_character_))
  }
  commit <- tryCatch(trimws(system2('git', c('-C', repo_root, 'rev-parse', 'HEAD'),
                                    stdout = TRUE, stderr = FALSE))[1],
                     error = function(e) NA_character_)
  branch <- tryCatch(trimws(system2('git', c('-C', repo_root, 'rev-parse', '--abbrev-ref', 'HEAD'),
                                    stdout = TRUE, stderr = FALSE))[1],
                     error = function(e) NA_character_)
  dirty_lines <- tryCatch(system2('git', c('-C', repo_root, 'status', '--porcelain'),
                                  stdout = TRUE, stderr = FALSE),
                          error = function(e) character())
  remote <- tryCatch(trimws(system2('git', c('-C', repo_root, 'config', '--get', 'remote.origin.url'),
                                    stdout = TRUE, stderr = FALSE))[1],
                     error = function(e) NA_character_)
  list(commit = commit,
       branch = branch,
       dirty = length(dirty_lines) > 0,
       remote = remote)
}


#' Atomically point <shared_root>/latest at the new vintage.
#'
#' Writes a temp symlink and renames over the existing one so a partial publish
#' never leaves `latest` pointing at a half-written vintage.
#'
#' @keywords internal
update_latest_symlink <- function(shared_root, vintage) {
  link_path <- file.path(shared_root, 'latest')
  tmp_path <- file.path(shared_root, paste0('.latest.tmp.', Sys.getpid()))
  unlink(tmp_path, force = TRUE)  # clear stale symlink/file from a prior failed publish
  ok <- file.symlink(vintage, tmp_path)
  if (!ok) {
    warning('Failed to create symlink ', tmp_path, ' -> ', vintage,
            '. Skipping latest update.')
    return(invisible(FALSE))
  }
  file.rename(tmp_path, link_path)
  invisible(TRUE)
}


# =============================================================================
# CLI Entry Point
# =============================================================================
#
# Standalone re-write of the output for an existing build (rarely needed — a
# normal build writes its output automatically via the gather):
#   Rscript src/io/write_output.R
#   Rscript src/io/write_output.R --dry-run
#   Rscript src/io/write_output.R --vintage 2026-05-08_manual
#
# This mode does NOT know which build flags produced the outputs; it records
# `manual = TRUE` in the manifest.

if (sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  dry_run <- '--dry-run' %in% args
  vintage <- NULL
  for (i in seq_along(args)) {
    if (args[i] == '--vintage' && i < length(args)) vintage <- args[i + 1]
  }

  write_build_output(
    vintage = vintage,
    build_flags = list(manual = TRUE),
    build_started_at = NULL,  # skip staleness guard for standalone runs
    dry_run = dry_run
  )
}
