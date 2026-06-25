# =============================================================================
# Output path layout (Phase 5)  —  single source of truth for WHERE outputs go
# =============================================================================
# The build keeps the real ("actual") results separate from named scenario
# ("what-if") results:
#
#   output/
#   |-- actual/      daily/  quality/  etr/  etrs_config/   (+ manifest.json)
#   |-- scenarios/
#   |   `-- <name>/   daily_overall.csv, by_*.csv           (+ manifest.json)
#   `-- logs/        build logs (NOT part of the published layout; unchanged)
#
# Every writer and the publish layer routes through these helpers so the layout
# lives in exactly one place — moving it is a one-file edit, and no consumer can
# silently keep pointing at a stale location.
#
# Override the root via TARIFF_OUTPUT_DIR (used by parity / equivalence harnesses
# that build into a scratch directory). The publish_*.R layer reads from a
# specific repo_root, so every helper also accepts an explicit `root`.

#' Root of the build output tree. Honors TARIFF_OUTPUT_DIR; defaults to output/.
output_root <- function() {
  env <- Sys.getenv('TARIFF_OUTPUT_DIR', unset = '')
  if (nzchar(env)) env else here('output')
}

# ---- the "actual" (real, non-scenario) results tree -------------------------
actual_root            <- function(root = output_root()) file.path(root, 'actual')
actual_daily_dir       <- function(root = output_root()) file.path(actual_root(root), 'daily')
actual_quality_dir     <- function(root = output_root()) file.path(actual_root(root), 'quality')
actual_etr_dir         <- function(root = output_root()) file.path(actual_root(root), 'etr')
actual_etrs_config_dir <- function(root = output_root()) file.path(actual_root(root), 'etrs_config')

#' The sections that live under actual/ (drives the publish copy loop).
ACTUAL_SECTIONS <- c('daily', 'quality', 'etr', 'etrs_config')

# ---- the named-scenario ("what-if") tree ------------------------------------
scenarios_root <- function(root = output_root()) file.path(root, 'scenarios')

#' Directory for a single named scenario (e.g. scenario_dir('no_ieepa')).
scenario_dir <- function(name, root = output_root()) file.path(scenarios_root(root), name)

# ---- series-aware section routing (the downstream writers) ------------------
# A build run produces ONE series at a time: the real "actual" series, or a named
# scenario. TARIFF_SERIES names it ('actual' or a scenario name). The downstream
# writers (daily / quality / etr) route their section dir through here so a
# scenario's outputs land under scenarios/<name>/<section> — exactly where the
# publish layer (write_output.R) sweeps from — without each writer knowing about
# scenarios. NOTE: the publish layer itself uses actual_root()/scenarios_root()
# LITERALLY to walk both trees, so those stay series-agnostic; only the writer-
# facing section dirs are series-aware.
current_series <- function() {
  s <- Sys.getenv('TARIFF_SERIES', unset = '')
  if (nzchar(s)) s else 'actual'
}

#' Root of the CURRENT series' result tree: actual/ for 'actual', else scenarios/<name>/.
series_root <- function(series = current_series(), root = output_root()) {
  if (identical(series, 'actual')) actual_root(root) else scenario_dir(series, root)
}

#' Section dir (daily/quality/etr/...) under the current series' tree.
series_section_dir <- function(section, series = current_series(), root = output_root()) {
  file.path(series_root(series, root), section)
}

# ---- unchanged-by-Phase-5 locations (kept here for one-stop reference) -------
logs_dir <- function(root = output_root()) file.path(root, 'logs')

# ---- published-vintage snapshot layout (per-interval rate panel) ------------
# The output writer (src/io/write_output.R) splits the rate panel by policy
# interval start into Hive-style partitions, so a consumer reads only the dates
# it needs instead of one monolithic rate_timeseries.parquet:
#   <vintage>/actual/snapshots/valid_from=YYYY-MM-DD/rates.parquet
#   <vintage>/scenarios/<name>/snapshots/valid_from=YYYY-MM-DD/rates.parquet
# Keyed off an explicit vintage_dir (the publish destination), NOT output_root().
SNAPSHOTS_SUBDIR <- 'snapshots'
SNAPSHOT_FILE    <- 'rates.parquet'

actual_snapshots_dir   <- function(vintage_dir)       file.path(vintage_dir, 'actual', SNAPSHOTS_SUBDIR)
scenario_snapshots_dir <- function(vintage_dir, name) file.path(vintage_dir, 'scenarios', name, SNAPSHOTS_SUBDIR)

#' Hive-style partition directory for one interval start (valid_from=YYYY-MM-DD).
snapshot_partition_dir <- function(snaps_dir, valid_from) {
  file.path(snaps_dir, paste0('valid_from=', format(as.Date(valid_from), '%Y-%m-%d')))
}

#' Path to the rates parquet for one interval start.
snapshot_parquet_path <- function(snaps_dir, valid_from) {
  file.path(snapshot_partition_dir(snaps_dir, valid_from), SNAPSHOT_FILE)
}
