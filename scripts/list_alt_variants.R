#!/usr/bin/env Rscript
# =============================================================================
# list_alt_variants.R — print rebuild-alt variant names, one per line
# =============================================================================
#
# Single source of truth for the rebuild-alternative variant list: reads it
# straight from build_rebuild_alt_registry() (src/pipeline/09_daily_series.R) so shell
# scripts can't drift from the registry. The old submit_alt_equivalence.sh
# hardcoded 6 variants while the registry defines 7 (subdivision_r_mid) — this
# script exists to make that drift impossible.
#
# Usage:
#   Rscript scripts/list_alt_variants.R
#   for v in $(Rscript scripts/list_alt_variants.R); do ... ; done
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(tidyverse)
  library(jsonlite)
})

# Mirror the source chain that alt workers load (src/core/parallel.R:.run_one_alt),
# enough to define load_policy_params() (05) and build_rebuild_alt_registry() (09).
suppressMessages({
  source(here('src', 'core', 'logging.R'))
  source(here('src', 'core', 'helpers.R'))
  source(here('src', 'pipeline', '03_parse_chapter99.R'))
  source(here('src', 'pipeline', '04_parse_products.R'))
  source(here('src', 'pipeline', '05_parse_policy_params.R'))
  source(here('src', 'pipeline', '06_calculate_rates.R'))
  source(here('src', 'pipeline', '09_daily_series.R'))
})

pp <- load_policy_params()
registry <- build_rebuild_alt_registry(pp)
variants <- vapply(registry, function(x) x$variant, character(1))
cat(variants, sep = '\n')
cat('\n')
