#!/usr/bin/env Rscript
# =============================================================================
# Build Section 232 semiconductor product list (Note 39 / 9903.79)
# =============================================================================
#
# Input:  data/hts_archives/hts_2026_rev_1.json (first revision with 9903.79)
# Output: resources/s232_semi_products.csv
#         resources/semi_qualifying_shares.csv (scaffold, qualifying_share = 1.0)
#
# Usage:  Rscript scripts/build_semi_products.R
#
# US Note 39(b) scopes "semiconductor articles" to three HTS headings:
#   8471.50, 8471.80, 8473.30
# combined with a per-article TPP/DRAM bandwidth technical gate. The HTS list
# alone overstates coverage; the share of each HTS10 that actually meets the
# tech gate lives in the qualifying_shares scaffold (default 1.0, calibrated
# later — see todo.md Phase 5).

suppressPackageStartupMessages({
  library(tidyverse)
  library(jsonlite)
  library(here)
})

NOTE_39_PREFIXES <- c('847150', '847180', '847330')
CH99_CODE <- '9903.79.01'

hts_path <- here('data', 'hts_archives', 'hts_2026_rev_1.json')
products_out <- here('resources', 's232_semi_products.csv')
shares_out <- here('resources', 'semi_qualifying_shares.csv')

stopifnot(file.exists(hts_path))

message('Reading ', hts_path)
hts_raw <- fromJSON(hts_path, simplifyDataFrame = FALSE)

is_semi_hts10 <- function(item) {
  htsno <- item$htsno %||% ''
  code <- gsub('\\.', '', htsno)
  nchar(code) == 10 &&
    grepl('^[0-9]+$', code) &&
    any(startsWith(code, NOTE_39_PREFIXES))
}

semi_items <- keep(hts_raw, is_semi_hts10)
message('  Matched ', length(semi_items), ' HTS10 codes under ',
        paste(NOTE_39_PREFIXES, collapse = ', '))

semi_products <- tibble(
  hts10       = map_chr(semi_items, ~ gsub('\\.', '', .x$htsno)),
  heading     = substr(map_chr(semi_items, ~ gsub('\\.', '', .x$htsno)), 1, 4),
  description = map_chr(semi_items, ~ .x$description %||% ''),
  ch99_code   = CH99_CODE
)

# Match the column layout used by s232_copper_products.csv (hts10, ch99_code).
# Heading + description are kept as trailing columns for human review; the rate
# calculator only needs hts10.
semi_products <- semi_products %>%
  select(hts10, ch99_code, heading, description) %>%
  arrange(hts10)

message('  Heading breakdown:')
print(semi_products %>% count(heading))

write_csv(semi_products, products_out)
message('Wrote ', products_out)

# -----------------------------------------------------------------------------
# Qualifying-share scaffold
# -----------------------------------------------------------------------------
# Default qualifying_share = 1.0 (upper bound: treat every import under these
# HTS10s as meeting Note 39(b) TPP/DRAM gate). Calibration later — see
# todo.md Phase 5. Per-HTS10 rows so the calibration pass can set shares without
# touching the rate calculator.
qualifying_shares <- semi_products %>%
  transmute(
    hts10,
    qualifying_share = 1.0,
    source_note = 'uncalibrated upper bound; see todo.md Phase 5'
  )

write_csv(qualifying_shares, shares_out)
message('Wrote ', shares_out, ' (', nrow(qualifying_shares),
        ' rows, all shares = 1.0 pending calibration)')
