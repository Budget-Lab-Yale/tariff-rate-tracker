# =============================================================================
# Build EU auto 25% scenario comparison workbook
# =============================================================================
#
# Reads paired alternative-series CSVs (baseline + eu_auto_25pct) from
# output/alternative/ and writes a single Excel workbook with stacked
# daily/interval data ready to pivot in Excel.
#
# Usage:
#   Rscript scripts/build_eu_auto_compare_xlsx.R
#
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
  library(openxlsx)
})

source(here('src', 'helpers.R'))
source(here('src', '09_daily_series.R'))   # for load_import_weights()

alt_dir <- here('output', 'alternative')
out_path <- file.path(alt_dir, 'eu_auto_25pct_compare.xlsx')

variants <- c('baseline', 'eu_auto_25pct')

read_alt <- function(name, variant) {
  path <- file.path(alt_dir, paste0(name, '_', variant, '.csv'))
  if (!file.exists(path)) {
    stop('Missing input file: ', path,
         '\nRun: Rscript -e "source(\'src/09_daily_series.R\'); ',
         'run_post_build_scenarios_per_revision(c(\'', variant, '\'), ',
         'imports = load_import_weights(), policy_params = load_policy_params())"')
  }
  read_csv(path, show_col_types = FALSE)
}

stack_variants <- function(name) {
  map_dfr(variants, ~ read_alt(name, .x))
}

message('Reading alternative-series CSVs from: ', alt_dir)
daily_overall   <- stack_variants('daily_overall')
by_authority    <- stack_variants('by_authority')
by_country      <- stack_variants('by_country')
by_category     <- stack_variants('by_category')

# Tag EU member flag on by_country for easy filtering.
eu_codes <- get_country_constants()$EU27_CODES
by_country <- by_country %>%
  mutate(is_eu = country %in% eu_codes) %>%
  relocate(is_eu, .after = country_abbr)

# --- Roll up by_country to by_region (partner-level) ---
# Recover per-country numerator (weighted_etr * country_total_imports), sum it
# across countries within a partner group, divide by sum of partner imports.
# Countries not in country_partner_mapping.csv fall into the implicit 'row'
# bucket (rest-of-world). The arithmetic is exact on the snapshot-derived
# weighted_etr (numerator/denominator are recovered without bias).
message('Computing by_region rollup from imports + by_country...')
imports <- load_import_weights()
if (is.null(imports)) {
  stop('Cannot build by_region without import weights — check config/local_paths.yaml')
}
country_total_imports <- imports %>%
  group_by(country = cty_code) %>%
  summarise(country_total_imports = sum(imports), .groups = 'drop') %>%
  mutate(country = as.character(country))

partner_path <- here('resources', 'country_partner_mapping.csv')
partner_map <- read_csv(partner_path, col_types = cols(.default = col_character())) %>%
  select(country = cty_code, region = partner)

by_region <- by_country %>%
  mutate(country = as.character(country)) %>%
  left_join(country_total_imports, by = 'country') %>%
  left_join(partner_map, by = 'country') %>%
  mutate(
    region = coalesce(region, 'row'),
    weighted_numerator = if_else(
      is.na(weighted_etr) | is.na(country_total_imports),
      NA_real_,
      weighted_etr * country_total_imports
    )
  ) %>%
  group_by(region, revision, valid_from, valid_until, variant) %>%
  summarise(
    weighted_etr = sum(weighted_numerator, na.rm = FALSE) /
                   sum(country_total_imports, na.rm = FALSE),
    mean_total_exposed_unwt = mean(mean_total_exposed),
    mean_additional_exposed_unwt = mean(mean_additional_exposed),
    region_total_imports_b = sum(country_total_imports) / 1e9,
    n_countries = n_distinct(country),
    .groups = 'drop'
  ) %>%
  arrange(region, revision, valid_from, variant)

# README content
readme_lines <- c(
  'EU Auto 25% Scenario Comparison',
  '',
  paste0('Generated: ', format(Sys.time())),
  '',
  'Variants:',
  '  baseline       : current policy (EU 232+MFN auto floor = 15%)',
  '  eu_auto_25pct  : EU 232+MFN auto floor raised to 25% effective 2026-05-04',
  '',
  'Sheets:',
  '  daily_overall  : daily ETR + composition; one row per (date, variant)',
  '  by_authority   : interval-encoded; one row per (revision, interval, variant)',
  '  by_country     : interval-encoded; one row per (country, interval, variant);',
  '                   is_eu flag highlights the 27 EU member states',
  '  by_region      : interval-encoded; one row per (region, interval, variant)',
  '                   regions: china, canada, mexico, uk, japan, eu, ftrow, row',
  '                   weighted_etr is import-weighted across countries in region;',
  '                   mean_*_unwt columns are unweighted means of country values',
  '  by_category    : interval-encoded; one row per (gtap_code, interval, variant)',
  '',
  'Sub-interval splits in 2026_rev_6 (eu_auto_25pct only):',
  '  [2026-04-23, 2026-05-03] - patch inactive',
  '  [2026-05-04, 2026-07-23] - patch active, s122 active',
  '  [2026-07-24, 2026-12-31] - patch active, s122 expired',
  '',
  'Patch mechanics:',
  '  rate_232 := max(0.25 - base_rate, 0) for EU members on auto vehicles',
  '  (passenger cars + light trucks, HTS 8703.22-90 / 8704.21-51)',
  '  Stacking is re-applied after the patch (same rules as baseline).',
  '',
  'Tip: use a pivot table on each sheet with `variant` as a column to compare',
  'baseline vs scenario directly. is_eu = TRUE on by_country isolates the',
  'affected partners.'
)

# Build workbook
message('Building workbook...')
wb <- createWorkbook()

addWorksheet(wb, 'README')
writeData(wb, 'README', readme_lines, colNames = FALSE)
setColWidths(wb, 'README', cols = 1, widths = 95)

write_sheet <- function(name, data) {
  addWorksheet(wb, name)
  writeData(wb, name, data, withFilter = TRUE)
  freezePane(wb, name, firstRow = TRUE)
  setColWidths(wb, name, cols = seq_along(data), widths = 'auto')
}

write_sheet('daily_overall', daily_overall)
write_sheet('by_authority', by_authority)
write_sheet('by_region', by_region)
write_sheet('by_country', by_country)
write_sheet('by_category', by_category)

saveWorkbook(wb, out_path, overwrite = TRUE)
message('Wrote: ', out_path)
message('  daily_overall: ', nrow(daily_overall), ' rows')
message('  by_authority:  ', nrow(by_authority), ' rows')
message('  by_region:     ', nrow(by_region), ' rows')
message('  by_country:    ', nrow(by_country), ' rows (is_eu flag added)')
message('  by_category:   ', nrow(by_category), ' rows')
