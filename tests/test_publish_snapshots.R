# =============================================================================
# per-interval snapshot publish — unit tests
# =============================================================================
#
# Pure-logic checks for the snapshot splitter in src/io/write_output.R on a
# tiny synthetic fixture — no model data, runs in seconds. Covers: interval
# encoding (inclusive valid_until, tip-to-horizon), dry-run record/path shape,
# live parquet write + round-trip (row counts, authoritative intervals overwrite
# the snapshot's stored valid_*, schema survives), manifest top-level fields +
# series.actual.snapshots (keys + sha256), and fail-loud on an unreadable snapshot.
#
# Usage (via Slurm, per project convention — not on the login node):
#   bash -lc 'module load R/4.4.2-gfbf-2024a; Rscript tests/test_publish_snapshots.R'
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(tibble)
  library(arrow)
})

source(here('src', 'io', 'write_output.R'))   # publish_series_snapshots + build_manifest
                                              # + build_weights_provenance (pulls
                                              # output_paths.R + rate_schema.R)

pass_count <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass_count <<- pass_count + 1L
  cat('  ok:', msg, '\n')
}

# --- synthetic fixture: 3 per-revision snapshots + a rev_dates calendar --------
# Each snapshot carries DELIBERATELY WRONG stored valid_* (1999) to prove the
# splitter overwrites them with the authoritative interval from rev_dates.
tmp <- tempfile('snaptest_'); dir.create(tmp)
on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
snap_dir <- file.path(tmp, 'src_snaps'); dir.create(snap_dir)

mk_snap <- function(rev, n) {
  tib <- tibble(
    hts10      = sprintf('990300%04d', seq_len(n)),
    country    = rep(c('CHN', 'MEX'), length.out = n),
    total_rate = seq_len(n) / 100,
    rate_301   = seq_len(n) / 200,
    valid_from = as.Date('1999-01-01'),   # bogus on purpose
    valid_until = as.Date('1999-12-31')   # bogus on purpose
  )
  saveRDS(tib, file.path(snap_dir, paste0('snapshot_', rev, '.rds')))
}
src_rows <- c(basic = 2L, rev_1 = 3L, rev_2 = 2L)
for (r in names(src_rows)) mk_snap(r, src_rows[[r]])

rev_dates <- tibble(
  revision       = c('basic', 'rev_1', 'rev_2'),
  effective_date = as.Date(c('2025-01-01', '2025-01-27', '2025-03-04'))
)
horizon <- as.Date('2026-12-31')

# --- 1. build_rev_intervals: inclusive valid_until, tip extends to horizon -----
cat('--- build_rev_intervals ---\n')
iv <- build_rev_intervals(names(src_rows), rev_dates, horizon)
check(nrow(iv) == 3, 'three intervals')
check(iv$valid_until[iv$revision == 'basic'] == as.Date('2025-01-26'),
      'basic valid_until is INCLUSIVE (day before rev_1 effective)')
check(iv$valid_until[iv$revision == 'rev_2'] == horizon, 'tip interval extends to horizon')

err_missing <- tryCatch({
  build_rev_intervals(c(names(src_rows), 'sched_pharma_2026_09_29'), rev_dates, horizon)
  NA_character_
}, error = function(e) conditionMessage(e))
check(!is.na(err_missing) && grepl('no effective_date metadata', err_missing),
      'built sched_* revision without metadata fails loud')

synth_dir <- file.path(tmp, 'synthetic_meta'); dir.create(synth_dir)
saveRDS(
  tibble(revision = 'sched_pharma_2026_09_29',
         effective_date = as.Date('2026-09-29')),
  file.path(synth_dir, 'synthetic_revisions.rds')
)
rev_dates_aug <- load_augmented_revision_dates(synth_dir, rev_dates)
iv_aug <- build_rev_intervals(c(names(src_rows), 'sched_pharma_2026_09_29'),
                              rev_dates_aug, horizon)
check(iv_aug$valid_until[iv_aug$revision == 'rev_2'] == as.Date('2026-09-28'),
      'synthetic revision shortens prior tip interval')
check(iv_aug$valid_until[iv_aug$revision == 'sched_pharma_2026_09_29'] == horizon,
      'synthetic revision extends to horizon')

# --- 2. dry-run: records + Hive paths, writes nothing --------------------------
cat('\n--- publish_series_snapshots(dry_run = TRUE) ---\n')
vintage_dir <- file.path(tmp, 'vintage')
dest <- actual_snapshots_dir(vintage_dir)            # <vintage>/actual/snapshots
recs <- publish_series_snapshots(snap_dir, dest, rev_dates, horizon, cores = 1, dry_run = TRUE)
check(isTRUE(recs$present), 'dry-run present = TRUE')
check(length(recs$snapshots) == 3, 'dry-run returns 3 records')
check(!dir.exists(dest), 'dry-run wrote no files')
vfroms <- vapply(recs$snapshots, `[[`, character(1), 'valid_from')
check(identical(sort(vfroms), c('2025-01-01', '2025-01-27', '2025-03-04')),
      'dry-run valid_from strings are the interval starts')
p1 <- recs$snapshots[[which(vfroms == '2025-01-01')]]$path
check(grepl('valid_from=2025-01-01/rates\\.parquet$', p1), 'Hive partition path shape')

# --- 3. live write: one parquet per interval, round-trips, intervals overwritten
cat('\n--- publish_series_snapshots(dry_run = FALSE) ---\n')
recs <- publish_series_snapshots(snap_dir, dest, rev_dates, horizon, cores = 1, dry_run = FALSE)
parts <- list.files(dest, pattern = 'rates\\.parquet$', recursive = TRUE, full.names = TRUE)
check(length(parts) == 3, 'three rates.parquet partitions written')

ok_rows <- TRUE; ok_iv <- TRUE
for (r in recs$snapshots) {
  pq <- arrow::read_parquet(r$path)
  if (nrow(pq) != src_rows[[r$revision]]) ok_rows <- FALSE
  vf <- unique(as.character(pq$valid_from))
  if (length(vf) != 1 || vf != r$valid_from || vf == '1999-01-01') ok_iv <- FALSE
}
check(ok_rows, 'per-interval row counts match source snapshots')
check(ok_iv, 'authoritative interval written (bogus stored valid_* overwritten)')
one <- arrow::read_parquet(parts[[1]])
check(all(c('hts10', 'country', 'total_rate', 'valid_from', 'valid_until') %in% names(one)),
      'rate schema columns survive the parquet round-trip')

# --- 4. manifest: top-level fields + series.actual.snapshots -------------------
cat('\n--- build_manifest ---\n')
man <- build_manifest('verify', vintage_dir, tmp,
                      build_flags = list(test = TRUE), build_started_at = NULL,
                      copied = list(timeseries = list(present = TRUE, files = character())),
                      series_snapshots = list(actual = recs$snapshots))
check(identical(man$schema_version, '2.0'), 'schema_version = 2.0')
check(identical(man$rate_unit, 'fraction'), 'rate_unit = fraction')
check(identical(man$interval_end, 'inclusive'), 'interval_end = inclusive')
check(is.character(man$country_code_vocabulary) && nzchar(man$country_code_vocabulary),
      'country_code_vocabulary present')
sa <- man$series$actual$snapshots
check(length(sa) == 3, 'series.actual has 3 snapshots')
keys <- c('revision', 'valid_from', 'valid_until', 'path', 'sha256', 'size_bytes', 'n_rows')
check(all(keys %in% names(sa[[1]])), 'snapshot record carries all required keys')
check(all(nzchar(vapply(sa, `[[`, character(1), 'revision'))),
      'every snapshot record carries a revision (Phase 5)')
check(identical(sort(vapply(sa, `[[`, character(1), 'revision')),
                sort(c('basic', 'rev_1', 'rev_2'))),
      'snapshot revisions match the fixture')
check(all(grepl('^actual/snapshots/valid_from=', vapply(sa, `[[`, character(1), 'path'))),
      'manifest paths are vintage-relative Hive paths')
check(identical(sa[[1]]$sha256, digest::digest(file = recs$snapshots[[1]]$path, algo = 'sha256')),
      'manifest sha256 matches a recomputed digest')
# weights block absent from this fixture -> present=false, no silent inference
check(isFALSE(man$weights$present), 'no weights_prov -> weights.present = false')

# --- 4b. build_weights_provenance (Phase 5): pure provenance assembly ----------
cat('\n--- build_weights_provenance ---\n')
prov_base <- file.path(tmp, 'wbase.rds')
saveRDS(tibble(hs10 = c('0101010000', '0202020000'), cty_code = c('1111', '1111'),
               imports = c(100, 50)), prov_base)
fake_res <- list(stats = list(
  mapper_schema_version = 1L, method = '484f', hts_as_of_date = '2026-07-01',
  total_in = 150, total_out = 150, n_weight_rows = 2L, n_transfer_dates = 3L,
  n_global_fallback = 0L,
  per_source = tibble(share_source = c('identity', 'even_fallback'),
                      value = c(120, 30))))
prov <- build_weights_provenance(
  res = fake_res, weight_mode = 'required', weight_method = '484f',
  base_path = prov_base, shares_path = NULL,
  crosswalk_path = here('resources', 'hts10_484f_transfers.csv'),
  overrides_path = NULL, hts_as_of = as.Date('2026-07-01'),
  hts_vintage = '2026_rev_11', repo_root = here())
check(identical(prov$method, '484f'), 'provenance method = 484f')
check(identical(prov$weight_mode, 'required'), 'provenance weight_mode = required')
p <- prov$provenance
check(identical(p$hts_as_of_date, '2026-07-01'), 'provenance hts_as_of_date')
check(identical(p$hts_vintage, '2026_rev_11'), 'provenance hts_vintage')
check(!is.na(p$base$sha256) && p$base$total_usd == 150, 'base sha256 + total recorded')
check(isFALSE(p$split_shares$present), 'absent shares -> split_shares.present = false')
check(!is.na(p$crosswalk$sha256) && p$crosswalk$n_transfer_dates == 3,
      'crosswalk sha256 + transfer dates recorded')
check(length(p$value_by_share_source) == 2 &&
      p$value_by_share_source[[1]]$share_source == 'identity',
      'value_by_share_source carried through')
check(is.list(p$source_pdfs) && length(p$source_pdfs) >= 1,
      'source PDF hashes read from source_manifest.csv')

# --- 5. fail-loud: an unreadable snapshot must stop(), never silently truncate --
cat('\n--- fail-loud on unreadable snapshot ---\n')
bad_dir <- file.path(tmp, 'bad'); dir.create(bad_dir)
file.copy(file.path(snap_dir, 'snapshot_basic.rds'), file.path(bad_dir, 'snapshot_basic.rds'))
writeLines('not an rds', file.path(bad_dir, 'snapshot_corrupt.rds'))
rev_dates_bad <- tibble(revision = c('basic', 'corrupt'),
                        effective_date = as.Date(c('2025-01-01', '2025-02-01')))
err <- tryCatch({
  publish_series_snapshots(bad_dir, file.path(tmp, 'baddest'), rev_dates_bad, horizon,
                           cores = 1, dry_run = FALSE)
  NA_character_
}, error = function(e) conditionMessage(e))
check(!is.na(err), 'corrupt snapshot triggers a loud error (no silent short panel)')

cat('\n=============================================\n')
cat('ALL', pass_count, 'CHECKS PASSED\n')
cat('=============================================\n')
