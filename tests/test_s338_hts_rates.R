# =============================================================================
# Tests: Section 338 Canada rate read off the HTS charging headings
# =============================================================================
# From 2026 rev_17 (published 2026-08-24, policy-dated 2026-08-22, the duty's
# legal turn-on), the §338 rate is extracted from headings 9903.03.12-.14 by
# extract_section338_rates() — the Brazil §301 / §122 pattern — with the config
# `rate` demoted to a fallback for pre-codification archives.
#
# The load-bearing assertion is that the HTS-extracted rate equals the config
# rate. A drift on either side — a config edit, or a future revision restating
# the headings — fails here first.
#
# Also asserted:
#   * pre-codification archives (rev_15) yield has_s338 = FALSE, so the config
#     fallback path still exists and engages exactly there;
#   * the two companion exemption headings .15/.16 are present and rate-less in
#     rev_17, and are NOT mistaken for charging headings;
#   * the products stay side-data: note 51(b) is not in the JSON export, so the
#     554-code list must not shrink to whatever the ch99 parse can see.
#
# Usage: Rscript tests/test_s338_hts_rates.R
# =============================================================================

suppressPackageStartupMessages({
  library(here); library(tidyverse); library(jsonlite)
})
source(here('src', 'core', 'helpers.R'))
source(here('src', 'core', 'logging.R'))
source(here('src', 'pipeline', '03_parse_chapter99.R'))
source(here('src', 'pipeline', '05_parse_policy_params.R'))
source(here('src', 'model', 'policy_params.R'))
source(here('src', 'model', 'authority_spec.R'))
source(here('src', 'model', 'authority_adapter.R'))

pass <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:  ', msg, '\n', sep = '')
}

pp <- load_policy_params(use_policy_dates = TRUE)
cfg <- pp$section_338
TURN_ON <- as.Date('2026-08-22')

cat('\n--- config block ---\n')
check(identical(as.character(cfg$effective_date), '2026-08-22'),
      'config effective_date is 2026-08-22 (PP 11056 moved it from 08-19)')
check(isTRUE(all.equal(as.numeric(cfg$rate), 0.50)), 'config rate is 0.50')

cat('\n--- rev_17: extraction vs config rate ---\n')
ch17 <- suppressMessages(
  parse_chapter99(here('data', 'hts_archives', 'hts_2026_rev_17.json.gz')))
hts <- suppressMessages(
  extract_section338_rates(filter_active_ch99(ch17, TURN_ON)))
check(isTRUE(hts$has_s338), 'rev_17 archive yields has_s338 = TRUE')
check(isTRUE(all.equal(hts$s338_rate, as.numeric(cfg$rate))),
      'HTS rate (9903.03.12-.14) == config rate')

charging <- ch17[grepl('^9903[.]03[.]1[2-4]$', ch17$ch99_code), ]
check(nrow(charging) == 3, 'exactly three charging headings .12/.13/.14')
check(all(charging$authority == 'section_338'),
      'ch99 classifier routes the charging headings to section_338')
check(length(unique(charging$rate)) == 1,
      'all three charging headings carry one rate (extractor would stop otherwise)')

cat('\n--- companion exemption headings .15/.16 ---\n')
comp <- ch17[grepl('^9903[.]03[.]1[56]$', ch17$ch99_code), ]
check(nrow(comp) == 2, 'both exemption headings .15 (§232) and .16 (GN6) present')
check(all(is.na(comp$rate)), "exemption headings are rate-less ('No change')")

cat('\n--- rev_15: pre-codification fallback ---\n')
ch15 <- suppressMessages(
  parse_chapter99(here('data', 'hts_archives', 'hts_2026_rev_15.json.gz')))
pre <- suppressMessages(
  extract_section338_rates(filter_active_ch99(ch15, TURN_ON)))
check(isTRUE(!pre$has_s338), 'rev_15 archive yields has_s338 = FALSE (config fallback)')
check(nrow(ch15[grepl('^9903[.]03[.]1[2-6]$', ch15$ch99_code), ]) == 0,
      'rev_15 carries none of 9903.03.12-.16')

cat('\n--- adapter: HTS rate wins, config is the fallback ---\n')
countries <- readr::read_csv(here('resources', 'census_codes.csv'),
                             col_types = readr::cols(.default = readr::col_character()))$Code
spec_hts <- suppressMessages(.build_section_338(pp, countries, TURN_ON, ch17))
spec_cfg <- .build_section_338(pp, countries, TURN_ON, NULL)
r_hts <- spec_hts$programs[[1]]$rate$by_country
r_cfg <- spec_cfg$programs[[1]]$rate$by_country
check(isTRUE(all.equal(unname(r_hts), unname(r_cfg))),
      'adapter: ch99-fed rate == config-fed rate (numerically neutral promotion)')
check(identical(names(r_hts), names(r_cfg)) && length(r_hts) == 1,
      'adapter: Canada only, both paths')

cat('\n--- products stay side-data (note 51(b) is not in the JSON) ---\n')
prods <- readr::read_csv(here('resources', 's338_products.csv'),
                         col_types = readr::cols(.default = readr::col_character()))
check(nrow(prods) == 554, 'side-data product list is the full 554 HTS-8 codes')
check(setequal(unique(prods$ch99_heading),
               c('9903.03.12', '9903.03.13', '9903.03.14')),
      'side-data lists key to the three charging headings')

cat(sprintf('\n== SUMMARY: %d passed ==\n', pass))
