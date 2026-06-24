#!/usr/bin/env Rscript
# =============================================================================
# validate_phase3_fix.R
# =============================================================================
#
# Validates the Phase 3 trackermiss fix (Section 201 + Annex II / country-EO
# split) against representative cells from `tariff-etr-eval`'s diagnostic.
#
# Usage:
#   Rscript scripts/validate_phase3_fix.R [revision_id]
#
# Default revision: rev_26 (effective 2025-10-15 — pre Brazil-coffee Nov-13
# carve-out, so the country EO surcharge should be active).
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})

args <- commandArgs(trailingOnly = TRUE)
revisions <- if (length(args) > 0) args else c('rev_26', 'rev_29', '2026_basic')

# Cells to validate (HTS10, country code, label, expected_post_fix_total)
cells <- tribble(
  ~hts10,        ~country, ~label,                  ~expect,
  '0901110025',  '3510',   'Brazil coffee',         '40% pre-Nov-13, 0% post',
  '0901210020',  '3510',   'Brazil coffee roasted', '40% pre-Nov-13, 0% post',
  '8541430010',  '5600',   'Indonesia PV cells',    '~14.5% (Section 201)',
  '8541430010',  '5530',   'Laos PV cells',         '~14.5% (Section 201) + Phase 2 if any',
  '8541430080',  '5330',   'India PV modules',      '~39.5% (country EO 25% + Section 201 14.5%)',
  '8517130000',  '5330',   'India smartphones',     'small (smartphones on Annex II; India EO not yet exempt-listed)',
  '8518302000',  '5520',   'Vietnam mics',          '0% (no country EO; out of scope)',
  '2601110030',  '3510',   'Brazil iron ore',       '~10% (Brazil exempt; universal baseline)',
  '2204210050',  '4279',   'France wine (control)', 'floor framework rate'
)

load_snapshot <- function(rev_id) {
  path <- here('data', 'timeseries', paste0('snapshot_', rev_id, '.rds'))
  if (!file.exists(path)) {
    message('Snapshot missing: ', path)
    return(NULL)
  }
  readRDS(path)
}

print_revision <- function(rev_id) {
  cat('\n============================================================\n')
  cat('Revision: ', rev_id, '\n', sep = '')
  cat('============================================================\n')
  snap <- load_snapshot(rev_id)
  if (is.null(snap)) return(invisible())

  for (i in seq_len(nrow(cells))) {
    r <- cells[i, ]
    row <- snap %>% filter(hts10 == r$hts10, country == r$country)
    if (nrow(row) == 0) {
      cat(sprintf('  %-26s [%s/%s]: NOT IN SNAPSHOT  (expected: %s)\n',
                  r$label, r$hts10, r$country, r$expect))
      next
    }
    cat(sprintf('  %-26s [%s/%s]: ieepa=%.3f s201=%.3f s232=%.3f total=%.3f  (expected: %s)\n',
                r$label, r$hts10, r$country,
                row$rate_ieepa_recip[1], row$rate_section_201[1],
                row$rate_232[1], row$total_rate[1], r$expect))
  }

  # Summary: Brazil rate distribution
  brazil <- snap %>% filter(country == '3510')
  cat(sprintf('\n  Brazil (3510) cells: %s total, %s with rate_ieepa_recip > 0 (mean=%.3f)\n',
              format(nrow(brazil), big.mark = ','),
              format(sum(brazil$rate_ieepa_recip > 0), big.mark = ','),
              mean(brazil$rate_ieepa_recip)))

  pv_count <- snap %>%
    filter(rate_section_201 > 0) %>%
    nrow()
  cat(sprintf('  Section 201 active rows: %s (countries: %d)\n',
              format(pv_count, big.mark = ','),
              n_distinct(snap$country[snap$rate_section_201 > 0])))
}

cat('========================================================================\n')
cat('Phase 3 fix validation — country-EO bypass + Section 201\n')
cat('========================================================================\n')

for (rev in revisions) {
  print_revision(rev)
}

cat('\nDone.\n')
