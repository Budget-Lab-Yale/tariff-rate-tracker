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

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, default = NULL) {
  i <- which(args == flag)
  if (length(i) && i[1] < length(args)) args[i[1] + 1] else default
}

reference_root <- get_arg('--reference')
candidate_root <- get_arg('--candidate')
artifacts_arg  <- get_arg('--artifacts', 'snapshot,daily_overall,daily_by_authority,daily_by_country,daily_by_category,daily_by_hs')
manifest_path  <- get_arg('--manifest')

if (is.null(reference_root)) stop('--reference <model_data vintage-or-series> is required', call. = FALSE)
if (is.null(candidate_root)) stop('--candidate <model_data vintage-or-series> is required', call. = FALSE)
if (is.null(manifest_path)) stop('--manifest <external-work-path> is required', call. = FALSE)

kinds <- strsplit(artifacts_arg, ',')[[1]]
reference_root <- resolve_model_data_series(reference_root)
candidate_root <- resolve_model_data_series(candidate_root)

rows <- list()
for (kind in kinds) {
  spec <- PARITY_ARTIFACTS[[kind]]
  if (is.null(spec)) next
  gfiles <- list_parity_artifacts(reference_root, kind)
  cfiles <- list_parity_artifacts(candidate_root, kind)
  shared <- intersect(names(gfiles), names(cfiles))
  for (f in shared) {
    rows[[length(rows) + 1]] <- tibble(
      kind = kind,
      file = f,
      label = paste0(kind, ':', f),
      reference_path = unname(gfiles[[f]]),
      candidate_path = unname(cfiles[[f]])
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
