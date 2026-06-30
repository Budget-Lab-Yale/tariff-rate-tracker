# =============================================================================
# Refresh data/processed product caches with the current parser
# =============================================================================
#
# Re-parses the product universe for the reference revisions consumed by
# tools/expand_ieepa_exempt.R (and any other resource-generation script that
# needs a current HTS10 universe). Run after parser changes — e.g. the
# 2026-06-04 8-digit-leaf fix added 473 lines older caches lack.
#
# Usage: Rscript scripts/refresh_product_caches.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(jsonlite)
  library(here)
})

source(here('src', 'core', 'helpers.R'))
source(here('src', 'pipeline', '04_parse_products.R'))

ensure_dir(here('data', 'processed'))

targets <- c('rev_32', '2026_rev_9')
for (rev in targets) {
  json_path <- resolve_json_path(rev, 'data/hts_archives')
  products <- parse_products(json_path)
  out <- here('data', 'processed', paste0('products_', rev, '.rds'))
  saveRDS(products, out)
  message('Saved: ', out, ' (', nrow(products), ' products)')
}
