#!/usr/bin/env Rscript
# =============================================================================
# build_parity_manifest.R — enumerate per-file parity comparisons
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(dplyr)
  library(readr)
  library(tibble)
})

source(here('src', 'core', 'parity.R'))
source(here('src', 'model', 'policy_params.R'))   # load_local_paths() -> model_data_root

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, default = NULL) {
  i <- which(args == flag)
  if (length(i) && i[1] < length(args)) args[i[1] + 1] else default
}

# Reference = the latest published vintage by default (<model_data_root>/latest).
default_reference <- local({
  r <- tryCatch(load_local_paths()$model_data_root, error = function(e) NULL)
  if (is.null(r) || !nzchar(r)) NULL else file.path(r, 'latest')
})
reference_root <- get_arg('--reference', default_reference)
candidate_root <- get_arg('--candidate', here())
artifacts_arg  <- get_arg('--artifacts', 'snapshot,daily_overall,daily_by_authority,daily_by_country,daily_by_category')
manifest_path  <- get_arg('--manifest', file.path('output', 'parity_manifest.tsv'))

if (is.null(reference_root)) stop('--reference <dir> required (model_data_root/latest not resolvable)', call. = FALSE)
if (!dir.exists(reference_root)) stop('reference dir not found: ', reference_root, call. = FALSE)

kinds <- strsplit(artifacts_arg, ',')[[1]]

resolve_build_dirs <- function(root) {
  if (dir.exists(file.path(root, 'actual', 'daily'))) {
    return(list(ts_dir = file.path(root, 'actual', 'snapshots'),
                daily_dir = file.path(root, 'actual', 'daily')))
  }
  if (dir.exists(file.path(root, 'data', 'timeseries'))) {
    return(list(ts_dir = file.path(root, 'data', 'timeseries'),
                daily_dir = file.path(root, 'output', 'actual', 'daily')))
  }
  list(ts_dir = root, daily_dir = file.path(root, 'daily'))
}

artifact_dir_for <- function(dirs, kind) {
  if (grepl('^daily', kind)) dirs$daily_dir else dirs$ts_dir
}

gd <- resolve_build_dirs(reference_root)
cd <- resolve_build_dirs(candidate_root)

rows <- list()
for (kind in kinds) {
  spec <- PARITY_ARTIFACTS[[kind]]
  if (is.null(spec)) next
  dir_g <- artifact_dir_for(gd, kind)
  dir_c <- artifact_dir_for(cd, kind)
  gfiles <- list.files(dir_g, pattern = utils::glob2rx(spec$glob), full.names = TRUE)
  cfiles <- list.files(dir_c, pattern = utils::glob2rx(spec$glob), full.names = TRUE)
  shared <- intersect(basename(gfiles), basename(cfiles))
  for (f in shared) {
    rows[[length(rows) + 1]] <- tibble(
      kind = kind,
      file = f,
      label = paste0(kind, ':', f),
      reference_path = file.path(dir_g, f),
      candidate_path = file.path(dir_c, f)
    )
  }
}

manifest <- if (length(rows)) bind_rows(rows) else tibble(
  kind = character(),
  file = character(),
  label = character(),
  reference_path = character(),
  candidate_path = character()
)

dir.create(dirname(manifest_path), recursive = TRUE, showWarnings = FALSE)
write_tsv(manifest, manifest_path)
cat('Wrote manifest: ', manifest_path, ' (', nrow(manifest), ' rows)\n', sep = '')
