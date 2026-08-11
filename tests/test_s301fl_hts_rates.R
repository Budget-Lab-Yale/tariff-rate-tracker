# =============================================================================
# Tests: Section 301 forced-labor rates read off the HTS charging headings
# =============================================================================
# From 2026 rev_13 (policy-dated 2026-07-24, the duty's legal turn-on), the
# forced-labor rates are extracted from headings 9903.05.20-.84 by
# extract_section301_fl_rates() — the Brazil §301 / §122 pattern — with the
# config tier lists demoted to a fallback for pre-codification archives.
#
# The load-bearing assertion is the FULL reconciliation: the HTS-extracted
# roster, rates, and tier types must equal what the config tiers produce,
# economy for economy (86 of them: 55 additive, 31 net-of-MFN floor counting
# the EU-27 individually). A drift on either side — a config edit or a future
# revision changing a heading — fails here first.
#
# Also asserted: pre-codification archives (rev_12) yield has_s301fl = FALSE,
# so the config fallback path still exists and engages exactly there.
#
# Usage: Rscript tests/test_s301fl_hts_rates.R
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
census <- readr::read_csv(here('resources', 'census_codes.csv'),
                          col_types = readr::cols(.default = readr::col_character()))
cfg <- pp$section_301_forced_labor

cat('\n--- rev_13: extraction vs config tiers ---\n')
ch13 <- parse_chapter99(here('data', 'hts_archives', 'hts_2026_rev_13.json.gz'))
hts <- extract_section301_fl_rates(
  filter_active_ch99(ch13, as.Date('2026-07-24')), eu27_codes = pp$eu27_codes)
check(isTRUE(hts$has_s301fl), 'rev_13 archive yields has_s301fl = TRUE')

bc_cfg <- .resolve_s301fl_by_country(cfg, census$Code)
bt_cfg <- .resolve_s301fl_by_country_type(cfg, census$Code)
bc_hts <- hts$by_country[intersect(names(hts$by_country), census$Code)]
bt_hts <- hts$by_country_type[intersect(names(hts$by_country_type), census$Code)]

check(length(bc_cfg) == 86, 'config tiers cover 86 economies (55 additive + EU-27 + Taiwan + JP/KR/CH)')
check(setequal(names(bc_hts), names(bc_cfg)),
      'HTS roster == config roster (same census codes, both directions)')
common <- names(bc_cfg)
check(all(bc_hts[common] == bc_cfg[common]),
      'every economy: HTS rate == config rate')
check(all(bt_hts[common] == bt_cfg[common]),
      "every economy: HTS tier type (surcharge/floor) == config tier type")
check(sum(bt_hts == 'surcharge') == 55 && sum(bt_hts == 'floor') == 31,
      'tier composition: 55 additive, 31 net-of-MFN floor')
check(all(sort(unique(unname(bc_hts))) == c(0.10, 0.125)),
      'only the two statutory rates (10%, 12.5%) appear')

cat('\n--- spot rates straight off the schedule ---\n')
check(bc_hts[['5520']] == 0.125 && bt_hts[['5520']] == 'surcharge',
      'Vietnam: additive 12.5% (9903.05.83)')
check(bc_hts[['4890']] == 0.125 && bt_hts[['4890']] == 'surcharge',
      'Türkiye: additive 12.5% (9903.05.79; census spells it Turkey)')
check(bc_hts[['4280']] == 0.10 && bt_hts[['4280']] == 'floor',
      'Germany: EU collective net-of-MFN 10% floor (9903.05.38/.39)')
check(bc_hts[['5880']] == 0.125 && bt_hts[['5880']] == 'floor',
      'Japan: net-of-MFN 12.5% floor (9903.05.48/.49)')

cat('\n--- pre-codification fallback path ---\n')
ch12 <- parse_chapter99(here('data', 'hts_archives', 'hts_2026_rev_12.json.gz'))
hts12 <- extract_section301_fl_rates(
  filter_active_ch99(ch12, as.Date('2026-07-22')), eu27_codes = pp$eu27_codes)
check(!isTRUE(hts12$has_s301fl),
      'rev_12 archive (pre-codification) yields has_s301fl = FALSE -> config fallback')

cat('\n--- adapter wiring: spec carries the HTS rates ---\n')
spec <- .build_section_301_forced_labor(pp, census$Code, '2026-07-24', ch13)
rl <- spec$programs[[1]]$rate
check(length(rl$by_country) == 86 && all(rl$by_country[common] == bc_cfg[common]),
      'spec built WITH ch99_data carries the 86 HTS-read rates')
spec_fb <- .build_section_301_forced_labor(pp, census$Code, '2026-07-24', ch12)
rl_fb <- spec_fb$programs[[1]]$rate
check(length(rl_fb$by_country) > 0 && all(rl_fb$by_country[common] == bc_cfg[common]),
      'spec built with a pre-codification archive falls back to identical config rates')

cat('\nALL ', pass, ' S301FL HTS-RATE ASSERTIONS PASSED\n', sep = '')
