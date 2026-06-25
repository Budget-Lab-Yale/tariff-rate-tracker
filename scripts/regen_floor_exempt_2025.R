# =============================================================================
# Regenerate floor_exempt files for 2025 rev_29-32 (Swiss framework window)
# =============================================================================
#
# The Nov 13, 2025 EO created the Swiss/Liechtenstein product exemptions as a
# SINGLE combined list under note 2(v)(iii)(b) ("As provided for in headings
# 9903.02.84 and 9903.02.89 ..."), unlike the 2026 notes which split them
# into per-category subdivisions (.84 ptaap / .85 civil aircraft / .86
# pharma). The original floor-exemption runs for rev_29-32 missed the list
# entirely (singular-"heading" anchor regex + missing .85/.86 anchors pushed
# coverage below the 80% guard), so Swiss products were charged the 15%
# reciprocal for Nov-Dec 2025 (extreme-eta review item 3 follow-on).
#
# This script re-runs parse_floor_exempt_products() with per-vintage targets:
#   - EU .74-.77 + Japan 9903.96.02 (all four revisions)
#   - Swiss combined list under .84 (category 'framework_annex')
#   - Korea .81 only at rev_32 (Korea floor begins there)
#
# Usage: Rscript scripts/regen_floor_exempt_2025.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})
source(here('tools', 'scrape_us_notes.R'))

base_targets <- tribble(
  ~ch99_code,    ~category,          ~country_group,
  '9903.02.74',  'ptaap',            'eu',
  '9903.02.75',  'particular',       'eu',
  '9903.02.76',  'civil_aircraft',   'eu',
  '9903.02.77',  'pharma',           'eu',
  '9903.02.84',  'framework_annex',  'swiss',
  '9903.96.02',  'civil_aircraft',   'japan',
)
korea_target <- tribble(
  ~ch99_code,    ~category,          ~country_group,
  '9903.02.81',  'civil_aircraft',   'korea',
)

for (rev in c('rev_29', 'rev_30', 'rev_31', 'rev_32')) {
  pdf <- here('data', 'us_notes', paste0('chapter99_', rev, '.pdf'))
  out <- here('data', 'us_notes', paste0('floor_exempt_', rev, '.csv'))
  targets <- if (rev == 'rev_32') bind_rows(base_targets, korea_target) else base_targets
  cat('\n=====', rev, '=====\n')
  res <- parse_floor_exempt_products(pdf_path = pdf, output_csv = out,
                                     dry_run = FALSE, targets = targets)
  if (!is.null(res)) print(res %>% count(country_group, category))
}
