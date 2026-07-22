#!/usr/bin/env Rscript
# =============================================================================
# list_alt_variants.R — print registered alternative names, one per line
# =============================================================================
#
# Reads the declarative config/scenarios registry so shell scripts cannot carry
# a second, hand-maintained variant list.
#
# Usage:
#   Rscript scripts/list_alt_variants.R
#   for v in $(Rscript scripts/list_alt_variants.R); do ... ; done
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(tidyverse)
  library(yaml)
})

source(here('src', 'core', 'helpers.R'))

variants <- list_scenarios() %>%
  filter(kind == 'alternative') %>%
  pull(name)
cat(variants, sep = '\n')
cat('\n')
