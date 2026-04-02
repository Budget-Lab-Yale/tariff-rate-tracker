# =============================================================================
# Run Two Targeted Rebuild Alternatives
# =============================================================================
# 1. usmca_2024: USMCA with 2024 utilization rates (pre-tariff steady-state)
# 2. metal_flat_100: Flat 100% metal content shares for 232 derivatives
#
# Usage: Rscript src/run_two_alternatives.R
# =============================================================================

library(here)
library(tidyverse)
library(jsonlite)
library(yaml)

source(here('src', 'helpers.R'))
source(here('src', '03_parse_chapter99.R'))
source(here('src', '04_parse_products.R'))
source(here('src', '05_parse_policy_params.R'))
source(here('src', '06_calculate_rates.R'))
source(here('src', '09_daily_series.R'))

pp <- load_policy_params()
imports <- load_import_weights()

# --- 1. USMCA 2024 utilization rates ---
message('\n', strrep('=', 70))
message('ALTERNATIVE 1: USMCA 2024 utilization rates')
message(strrep('=', 70))

pp_usmca_24 <- pp
pp_usmca_24$USMCA_SHARES$year <- 2024
pp_usmca_24$USMCA_SHARES$mode <- 'annual'
pp_usmca_24$usmca_shares$year <- 2024
pp_usmca_24$usmca_shares$mode <- 'annual'
build_alternative_timeseries(pp_usmca_24, 'usmca_2024', imports = imports, policy_params = pp_usmca_24)

# --- 2. Flat 100% metal content shares ---
message('\n', strrep('=', 70))
message('ALTERNATIVE 2: Flat 100% metal content shares')
message(strrep('=', 70))

pp_metal <- pp
pp_metal$metal_content$method <- 'flat'
pp_metal$metal_content$flat_share <- 1.0
build_alternative_timeseries(pp_metal, 'metal_flat_100', imports = imports, policy_params = pp_metal)

message('\n', strrep('=', 70))
message('BOTH ALTERNATIVES COMPLETE')
message(strrep('=', 70))
