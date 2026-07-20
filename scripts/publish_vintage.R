#!/usr/bin/env Rscript
# =============================================================================
# publish_vintage.R — finalize ONE vintage on the model-data interface
# =============================================================================
# The single finalize step of the build. The gather has already written each
# series' daily/quality DIRECTLY into the vintage (<model_data_root>/<vintage>/
# {actual,scenarios/<name>}/), and the array tasks left their per-revision
# snapshot_<rev>.rds (+ <name>/ subdirs) in the run's external scratch. This
# step hands write_build_output():
#   - snapshot_src_root = the scratch  -> split into <vintage>/.../snapshots/*.parquet
#   - output_src_root   = the vintage  -> daily/quality inventoried IN PLACE (no copy)
# and writes the manifest + (optionally) repoints `latest`. It does NOT wipe the
# vintage (the gather's outputs already live there). The orchestrator removes the
# scratch after this succeeds. The repo working tree is never read or written.
#
# Env (set by scripts/submit_build_array.sh):
#   TARIFF_SCRATCH          scratch holding snapshot_<rev>.rds + <name>/ (REQUIRED
#                           unless --latest-only)
#   TARIFF_VINTAGE          vintage id YYYY-MM-DD-HH (REQUIRED; shared by all series)
#   TARIFF_MODEL_DATA_ROOT  interface root (optional; else local_paths.yaml default)
#   TARIFF_UPDATE_LATEST    '0' to publish additively without moving `latest`
#
# Flags:
#   --latest-only   skip the publish entirely; just repoint <root>/latest at
#                   TARIFF_VINTAGE. Used by the verified finalize: publish with
#                   TARIFF_UPDATE_LATEST=0, run verify_build.R on the vintage,
#                   then repoint latest only after the gate passes.
# =============================================================================

suppressPackageStartupMessages(library(here))
source(here('src', 'io', 'write_output.R'))   # write_build_output + SHARED_ROOT_DEFAULT

latest_only <- '--latest-only' %in% commandArgs(trailingOnly = TRUE)

scratch <- Sys.getenv('TARIFF_SCRATCH', unset = '')
vintage <- Sys.getenv('TARIFF_VINTAGE', unset = '')
if (!nzchar(vintage)) stop('TARIFF_VINTAGE not set', call. = FALSE)
if (!latest_only) {
  if (!nzchar(scratch)) stop('TARIFF_SCRATCH not set', call. = FALSE)
  if (!dir.exists(scratch)) stop('scratch dir does not exist: ', scratch, call. = FALSE)
}

mdr <- Sys.getenv('TARIFF_MODEL_DATA_ROOT', unset = '')
shared_root <- if (nzchar(mdr)) mdr else SHARED_ROOT_DEFAULT
vintage_dir <- file.path(shared_root, vintage)
update_latest <- !identical(Sys.getenv('TARIFF_UPDATE_LATEST', '1'), '0')

# Weight-mode plumbing (never inferred). TARIFF_WEIGHT_MODE / TARIFF_WEIGHT_METHOD
# override config; unset -> NULL -> write_build_output resolves from local_paths.
env_or_null <- function(k) { v <- Sys.getenv(k, unset = ''); if (nzchar(v)) v else NULL }
weight_mode   <- env_or_null('TARIFF_WEIGHT_MODE')
weight_method <- env_or_null('TARIFF_WEIGHT_METHOD')

if (latest_only) {
  if (!dir.exists(vintage_dir)) {
    stop('--latest-only: vintage dir does not exist: ', vintage_dir, call. = FALSE)
  }
  ok <- withCallingHandlers(
    update_latest_symlink(shared_root, vintage),
    warning = function(w) message('WARNING: ', conditionMessage(w))
  )
  if (!isTRUE(ok)) stop('--latest-only: failed to repoint latest', call. = FALSE)
  message('Repointed ', file.path(shared_root, 'latest'), ' -> ', vintage)
  quit(status = 0L)
}

message('Finalizing vintage ', vintage, ' (scratch ', scratch, ') -> ', vintage_dir)
res <- write_build_output(
  shared_root       = shared_root,
  vintage           = vintage,
  snapshot_src_root = scratch,            # split the staged snapshots from the scratch
  output_src_root   = vintage_dir,        # daily/quality already in the vintage -> inventory in place
  wipe_vintage      = FALSE,              # do NOT clear the vintage; the gather populated it
  build_started_at  = NULL,               # scratch metadata just finalized; skip stale guard
  include_scenarios = TRUE,               # sweep every scenarios/<name> built this run
  update_latest     = update_latest,
  weight_mode       = weight_mode,
  weight_method     = weight_method
)
message('Finalized vintage: ', res$vintage_dir,
        if (update_latest) paste0(' (latest -> ', res$vintage, ')') else ' (latest unchanged)')
