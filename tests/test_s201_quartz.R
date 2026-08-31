# =============================================================================
# Tests: Section 201 quartz surface products (U.S. note 41)
# =============================================================================
# Proclamation 11051 of 2026-07-31, codified by HTS 2026 rev_16 effective
# 2026-08-15, four-year safeguard to 2030-08-14. Headings 9903.45.30 (in-quota,
# 25%) and 9903.45.31 (over-quota, 50%), stepping down each August 15.
#
# What this pins:
#   * the rate is read from the HTS, and equals the note 41(e) Year-1 schedule;
#   * solar and quartz gate INDEPENDENTLY — the pre-existing bug shape here is
#     an authority-level window killing quartz along with expired solar;
#   * the note 41(c) roster resolves to census codes and excludes Canada/Mexico
#     while NOT excluding the actual target origins;
#   * the 9903.45.30/.31 classifier collision with the announced polysilicon
#     §232 range resolves to section_201 on the codified headings.
#
# Usage: Rscript tests/test_s201_quartz.R
# =============================================================================

suppressPackageStartupMessages({
  library(here); library(tidyverse); library(jsonlite)
})
source(here('src', 'core', 'helpers.R'))
source(here('src', 'core', 'logging.R'))
source(here('src', 'model', 'rate_schema.R'))
source(here('src', 'pipeline', '03_parse_chapter99.R'))
source(here('src', 'pipeline', '05_parse_policy_params.R'))
source(here('src', 'model', 'policy_params.R'))
source(here('src', 'model', 'authority_spec.R'))
source(here('src', 'model', 'timeline.R'))
source(here('src', 'model', 'authority_adapter.R'))

pass <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:  ', msg, '\n', sep = '')
}

pp <- load_policy_params(use_policy_dates = TRUE)
qz <- pp$SECTION_201$quartz
TURN_ON <- as.Date('2026-08-15')

cat('\n--- config block ---\n')
check(!is.null(qz), 'section_201.quartz exists')
check(identical(as.Date(qz$effective_date), TURN_ON), 'effective 2026-08-15')
check(identical(as.Date(qz$expiry_date), as.Date('2030-08-14')), 'expires 2030-08-14')
check(identical(qz$basis, 'in_quota'), 'basis = in_quota (TRQ modelling choice)')

cat('\n--- rev_17: rates read off 9903.45.30/.31 ---\n')
ch17 <- suppressMessages(
  parse_chapter99(here('data', 'hts_archives', 'hts_2026_rev_17.json.gz')))
hts <- suppressMessages(extract_section201_quartz_rates(filter_active_ch99(ch17, TURN_ON)))
check(isTRUE(hts$has_quartz), 'rev_17 yields has_quartz = TRUE')
check(isTRUE(all.equal(hts$in_quota_rate, 0.25)), 'in-quota rate 25% (9903.45.30)')
check(isTRUE(all.equal(hts$over_quota_rate, 0.50)), 'over-quota rate 50% (9903.45.31)')

sched1 <- qz$rate_schedule[['2026-08-15']]
check(isTRUE(all.equal(as.numeric(sched1$in_quota), hts$in_quota_rate)),
      'HTS in-quota rate == note 41(e) Year-1 schedule')
check(isTRUE(all.equal(as.numeric(sched1$over_quota), hts$over_quota_rate)),
      'HTS over-quota rate == note 41(e) Year-1 schedule')

cat('\n--- rev_15: pre-codification ---\n')
ch15 <- suppressMessages(
  parse_chapter99(here('data', 'hts_archives', 'hts_2026_rev_15.json.gz')))
pre <- suppressMessages(extract_section201_quartz_rates(filter_active_ch99(ch15, TURN_ON)))
check(isTRUE(!pre$has_quartz), 'rev_15 yields has_quartz = FALSE')

cat('\n--- ch99 classifier: the polysilicon range collision ---\n')
check(identical(classify_authority('9903.45.30'), 'section_201'),
      '9903.45.30 -> section_201 (quartz, note 41 — codified)')
check(identical(classify_authority('9903.45.31'), 'section_201'),
      '9903.45.31 -> section_201 (quartz, note 41 — codified)')
check(identical(classify_authority('9903.45.33'), 'section_232'),
      '9903.45.33 -> section_232 (polysilicon residue, note 42)')
check(identical(classify_authority('9903.45.21'), 'section_201'),
      '9903.45.21 -> section_201 (solar, unchanged)')

cat('\n--- note 41(c) exempt roster ---\n')
ex <- readr::read_csv(here('resources', 's201_quartz_exempt_countries.csv'),
                      col_types = readr::cols(.default = readr::col_character()))
check(nrow(ex) == 124, 'roster resolves to 124 census codes')
check(all(c('1220', '2010') %in% ex$code), 'Canada + Mexico exempt (note 41(c)(i))')
check('5800' %in% ex$code && !('5790' %in% ex$code),
      'South Korea exempt, North Korea not (no false prefix match)')
check(!any(c('5700', '5330', '4890') %in% ex$code),
      'China / India / Turkey NOT exempt (they are the safeguard targets)')
check(all(c('7460', '7642') %in% ex$code) && all(c('7510', '7530') %in% ex$code),
      'Guinea vs Guinea-Bissau and Niger vs Nigeria resolved distinctly')
check(length(unique(ex$code)) == nrow(ex), 'no duplicate census codes')

cat('\n--- adapter: solar and quartz gate independently ---\n')
countries <- readr::read_csv(here('resources', 'census_codes.csv'),
                             col_types = readr::cols(.default = readr::col_character()))$Code
mk <- function(d) suppressMessages(
  .build_s201_quartz_program(qz, filter_active_ch99(ch17, as.Date(d)), as.Date(d)))

p_on   <- mk('2026-08-15')
p_pre  <- mk('2026-08-14')
p_post <- mk('2030-08-15')
check(isTRUE(all.equal(resolve_rate(p_on$rate)$value, 0.25)),
      'on 2026-08-15: quartz program carries 25%')
check(length(p_pre$rate) == 0, 'on 2026-08-14: quartz program is hollow (date-gated)')
check(length(p_post$rate) == 0, 'on 2030-08-15: quartz program is hollow (expired)')
check(identical(as.Date(p_on$active$until), as.Date('2030-08-15')),
      'program until = expiry + 1 (first dead day, exclusive)')
check(all(c('1220', '2010') %in% p_on$country_scope$exclude),
      'program country_scope excludes the note 41(c) roster')

cat('\n--- boundaries: the quartz turn-on mints from the program window ---\n')
spec <- authority_spec(
  authority = 'section_201', active = list(from = NA, until = NA),
  programs = list(
    authority_program(id = 's201_solar', active = list(from = NA, until = as.Date('2026-02-07'))),
    p_on))
b <- collect_schedule_boundaries(policy_params = NULL, specs = list(spec))
check(TURN_ON %in% b, 'quartz turn-on 2026-08-15 is minted')
check(as.Date('2026-02-07') %in% b, 'solar expiry boundary still minted (not lost)')
check(as.Date('2030-08-15') %in% b, 'quartz expiry boundary minted')

cat(sprintf('\n== SUMMARY: %d passed ==\n', pass))
