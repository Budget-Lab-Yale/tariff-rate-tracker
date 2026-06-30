# =============================================================================
# Build resources/s301_exclusion_lines.csv — heading -> referencing HTS10 lines
# =============================================================================
#
# Companion to scripts/build_s301_exclusion_headings.R. For every heading in
# the exclusion registry, lists the HTS10 lines whose footnotes reference it,
# per revision, unioned across all cached revisions (a line that left the
# universe in a later revision still matters for earlier months).
#
# Consumed by tools/calibrate_s301_exclusions.R (the Phase-2 claim-share
# calibration) as the affected-lines set: the denominator universe for
# realized-rate inversion, and the join key from IMDB trade cells back to
# exclusion headings.
#
# Output columns:
#   ch99_code  - registry heading (e.g. 9903.88.69)
#   hts10      - referencing product line
#   n_revisions, first_rev, last_rev - provenance across cached revisions
#                (revision order taken from config/revision_dates.csv)
#
# Usage: Rscript scripts/build_s301_exclusion_lines.R [--ts-dir <dir>]
# Idempotent: output is a pure derivation of the parse caches + registry
# (no curator rows; re-run freely after onboarding revisions).
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})

args <- commandArgs(trailingOnly = TRUE)
ts_dir <- here('data', 'timeseries')
if (length(args) >= 2 && args[1] == '--ts-dir') ts_dir <- args[2]

registry_path <- here('resources', 's301_exclusion_headings.csv')
out_path <- here('resources', 's301_exclusion_lines.csv')

registry <- read_csv(registry_path, show_col_types = FALSE,
                     col_types = cols(.default = col_character()))
target_codes <- registry$ch99_code
message('Registry headings: ', length(target_codes))

# Revision ordering from revision_dates.csv (handles mixed 2025 "rev_N" and
# 2026 "2026_*" naming; falls back to alphabetical for unknown names).
rev_dates <- read_csv(here('config', 'revision_dates.csv'),
                      show_col_types = FALSE) %>%
  mutate(order = row_number()) %>%
  select(revision, order)

caches <- list.files(ts_dir, pattern = '^products_.*\\.rds$', full.names = TRUE)
if (length(caches) == 0) {
  stop('No products_*.rds caches found in ', ts_dir,
       ' — run the parse step (or pass --ts-dir).')
}
message('Scanning ', length(caches), ' products caches in ', ts_dir)

scan <- map_dfr(caches, function(p) {
  rev <- sub('^products_(.*)\\.rds$', '\\1', basename(p))
  products <- readRDS(p)
  products %>%
    select(hts10, ch99_refs) %>%
    unnest(ch99_refs) %>%
    filter(ch99_refs %in% target_codes) %>%
    distinct(hts10, ch99_code = ch99_refs) %>%
    mutate(rev = rev)
})

if (nrow(scan) == 0) {
  stop('No products reference any registry heading in any cached revision — ',
       'check that the caches carry ch99_refs.')
}

lines <- scan %>%
  left_join(rev_dates, by = c('rev' = 'revision')) %>%
  # Unknown revision names (not in revision_dates.csv, e.g. excluded rev_8)
  # sort after known ones, alphabetically among themselves.
  arrange(ch99_code, hts10, coalesce(order, Inf), rev) %>%
  group_by(ch99_code, hts10) %>%
  summarise(
    n_revisions = n(),
    first_rev = first(rev),
    last_rev = last(rev),
    .groups = 'drop'
  ) %>%
  arrange(ch99_code, hts10)

write_csv(lines, out_path)
message('Wrote ', nrow(lines), ' heading x line rows (',
        n_distinct(lines$ch99_code), ' headings, ',
        n_distinct(lines$hts10), ' distinct HTS10) to ', out_path)

# Summary by heading for eyeballing
lines %>%
  count(ch99_code, name = 'n_lines') %>%
  arrange(desc(n_lines)) %>%
  head(15) %>%
  { message('Top headings by line count:');
    walk2(.$ch99_code, .$n_lines,
          ~message(sprintf('  %s : %d lines', .x, .y))) }
