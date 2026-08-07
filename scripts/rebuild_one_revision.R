# =============================================================================
# Rebuild a single revision's snapshot to a scratch path (validation harness)
# =============================================================================
#
# Mirrors steps a-g of build_full_timeseries() in src/pipeline/00_build_timeseries.R
# for ONE revision, writing the snapshot to data/timeseries/scratch/ so the
# published snapshots are untouched. Used to validate rate-engine changes
# without a full rebuild.
#
# Usage: Rscript scripts/rebuild_one_revision.R <revision_id> [out_dir]
#   e.g. Rscript scripts/rebuild_one_revision.R 2026_rev_2
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(jsonlite)
  library(here)
})

source(here('src', 'core', 'logging.R'))
source(here('src', 'core', 'helpers.R'))
source(here('src', 'pipeline', '03_parse_chapter99.R'))
source(here('src', 'pipeline', '04_parse_products.R'))
source(here('src', 'pipeline', '05_parse_policy_params.R'))
source(here('src', 'pipeline', '06_calculate_rates.R'))
source(here('src', 'model', 'authority_spec.R'))      # AuthoritySpec datatype
source(here('src', 'model', 'authority_adapter.R'))   # build_authority_specs()

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop('Usage: Rscript scripts/rebuild_one_revision.R <revision_id> [out_dir]')
rev_id <- args[1]
out_dir <- if (length(args) >= 2) args[2] else here('data', 'timeseries', 'scratch')
ensure_dir(out_dir)

rev_dates <- load_revision_dates('config/revision_dates.csv', use_policy_dates = TRUE)
pp_build <- load_policy_params(use_policy_dates = TRUE)
census_codes <- read_csv('resources/census_codes.csv', col_types = cols(.default = col_character()))
countries <- census_codes$Code
country_lookup <- build_country_lookup('resources/census_codes.csv')

rev_info <- rev_dates %>% filter(revision == rev_id)
if (nrow(rev_info) == 0) stop('Revision not in config/revision_dates.csv: ', rev_id)
eff_date <- rev_info$effective_date

message('=== Rebuilding ', rev_id, ' (effective ', eff_date, ') ===')

json_path <- resolve_json_path(rev_id, 'data/hts_archives')
hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)
ch99_data <- parse_chapter99(json_path)
products <- parse_products(json_path)

ieepa_rates <- extract_ieepa_rates(hts_raw, country_lookup, effective_date = eff_date)
fentanyl_rates <- extract_ieepa_fentanyl_rates(hts_raw, country_lookup, effective_date = eff_date)
ch99_data_active <- filter_active_ch99(ch99_data, as.Date(eff_date))
s232_rates <- extract_section232_rates(ch99_data_active)
usmca <- extract_usmca_eligibility(hts_raw)

# AuthoritySpec path (mirrors 00_build_timeseries.R steps f-g; Plank 7 retired
# the specs-less calculate_rates_for_revision() signature).
specs <- build_authority_specs(
  products, ch99_data, ieepa_rates, usmca,
  countries, rev_id, eff_date,
  s232_rates = s232_rates, fentanyl_rates = fentanyl_rates,
  policy_params = pp_build
)

rates <- calculate_rates_for_revision(
  products, ch99_data, usmca,
  countries, rev_id, eff_date,
  specs = specs,
  policy_params = pp_build
)

snapshot_path <- file.path(out_dir, paste0('snapshot_', rev_id, '.rds'))
saveRDS(rates, snapshot_path)
message('Saved: ', snapshot_path, '  (', nrow(rates), ' rows)')
