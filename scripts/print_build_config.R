#!/usr/bin/env Rscript
# =============================================================================
# print_build_config.R — bash bridge for the build-run config
# =============================================================================
# Reads a build-config YAML (arg 1) via src/core/build_config.R and prints shell-
# eval'able KEY='value' lines so the bash orchestrator and the R steps parse the
# SAME config exactly once. Usage (in submit_build_array.sh):
#   eval "$(Rscript scripts/print_build_config.R config/build/production.yaml)"
# Emits: MODEL_DATA_ROOT, POLICY_PARAMS_PATH, SCENARIOS (space-
# separated, may be empty), USE_HTS_DATES/UPDATE_LATEST/ALLOW_PARTIAL/VERIFY (0|1),
# WEIGHT_MODE. Errors (bad path / bad weight_mode) go to stderr and exit non-zero.
# =============================================================================

suppressPackageStartupMessages(library(here))
source(here('src', 'core', 'build_config.R'))

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) { message('usage: print_build_config.R <config.yaml>'); quit(status = 2) }

cfg <- load_build_config(args[1])

# Single-quote scalar values; escape any embedded single quotes for bash safety.
shq <- function(x) paste0("'", gsub("'", "'\\\\''", as.character(x)), "'")
b01 <- function(x) if (isTRUE(x)) '1' else '0'

cat(
  'MODEL_DATA_ROOT=',    shq(cfg$model_data_root),    '\n',
  'POLICY_PARAMS_PATH=', shq(cfg$policy_params_path), '\n',
  'SCENARIOS=',          shq(paste(cfg$scenarios, collapse = ' ')), '\n',
  'WEIGHT_MODE=',        shq(cfg$weight_mode),        '\n',
  'USE_HTS_DATES=',      b01(cfg$use_hts_dates),      '\n',
  'UPDATE_LATEST=',      b01(cfg$update_latest),      '\n',
  'ALLOW_PARTIAL=',      b01(cfg$allow_partial),      '\n',
  'VERIFY=',             b01(cfg$verify),             '\n',
  sep = ''
)
