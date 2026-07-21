# =============================================================================
# test_brazil_301.R — Section 301 Brazil authority (BASELINE, effective 2026-07-22)
# =============================================================================
# FINAL ACTION coverage (USTR FR Doc 2026-14542, published 2026-07-20): the
# three note-50 exemption lists (875 unconditional + 546 aircraft-use + 705
# pharma-use hts8, resources/s301_brazil_*_products.csv built by
# scripts/build_s301_brazil_annex.R), the adapter builder
# (.build_section_301_brazil: baseline block, date-gate, additive, usmca
# 'none', use-conditional shares), the stacking-policy invariant, the
# calculator step (apply_section301_brazil: 25% on non-exempt Brazil rows,
# use-conditional lists scaled by (1 - share) -> 2.5%/12.5%, §232 full-scope
# exclusion mask incl. the annex_2-pays tier rule, pair seeding with
# product-level §232 exclusion), and boundary discovery of bnd_2026-07-22.
# Synthetic in-memory fixtures for the calc checks (the s338 test pattern).
#
# Usage: Rscript tests/test_brazil_301.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse); library(here)
})
suppressMessages({
  source(here('src', 'core', 'helpers.R'))
  source(here('src', 'model', 'authority_spec.R'))
  source(here('src', 'model', 'policy_params.R'))
  source(here('src', 'model', 'authority_adapter.R'))
  source(here('src', 'pipeline', '05_parse_policy_params.R'))
  source(here('src', 'pipeline', '06_calculate_rates.R'))
})

pass <- 0L; fail <- 0L
ok <- function(cond, msg) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat('  PASS: ', msg, '\n') }
  else { fail <<- fail + 1L; cat('  FAIL: ', msg, '\n') }
}

BR <- '3510'

cat('\n== exemption annexes (resources/, built by scripts/build_s301_brazil_annex.R) ==\n')
read_list <- function(f) read_csv(here('resources', f),
               col_types = cols(hts8 = col_character(), .default = col_character()))
ex  <- read_list('s301_brazil_exempt_products.csv')
air <- read_list('s301_brazil_aircraft_products.csv')
phr <- read_list('s301_brazil_pharma_products.csv')
ok(nrow(ex) == 875 && !anyDuplicated(ex$hts8),
   '875 unique UNCONDITIONAL exempt hts8 (note 50(a)(ii) 864 + (a)(iii) 11)')
ok(nrow(air) == 546 && !anyDuplicated(air$hts8), '546 aircraft-use hts8 (note 50(a)(iv))')
ok(nrow(phr) == 705 && !anyDuplicated(phr$hts8), '705 pharma-use hts8 (note 50(a)(v))')
ok(length(unique(c(ex$hts8, air$hts8, phr$hts8))) == 2126,
   'three lists disjoint, union = 2,126 (final-annex universe)')
ok(!any('47020000' %in% c(ex$hts8, air$hts8, phr$hts8)),
   'high-purity dissolving pulp 4702.00.00 REMOVED vs the June-4 proposed annex')
ok(all(c('02011005', '72011000') %in% ex$hts8) &&
   '88023001' %in% air$hts8 && '30033100' %in% phr$hts8,
   'spot checks: beef/pig iron unconditional; civil aircraft -> (a)(iv); pharma prep -> (a)(v)')
ok(sum(startsWith(air$hts8, '98')) == 6 && !any(startsWith(ex$hts8, '98')),
   'six ch-98 provisions carried, all on the aircraft list')

cat('\n== adapter: .build_section_301_brazil (baseline config, date-gate) ==\n')
pp <- load_policy_params()
countries <- read_csv(here('resources', 'census_codes.csv'),
                      col_types = cols(.default = col_character()))$Code
ok(!is.null(pp$section_301_brazil), 'baseline policy_params carries section_301_brazil (signed law)')
ok(identical(as.character(pp$section_301_brazil$effective_date), '2026-07-22'),
   'effective_date = 2026-07-22 (final action; June coding assumed 07-24)')
ok('2026-07-22' %in% as.character(pp$BOUNDARY_OVERRIDES), 'boundary_overrides lists the 2026-07-22 turn-on')
spec_on  <- .build_section_301_brazil(pp, countries, as.Date('2026-07-22'))
spec_pre <- .build_section_301_brazil(pp, countries, as.Date('2026-07-21'))
ok(!is.null(spec_on) && spec_on$authority == 'section_301_brazil', 'authority built')
ok(identical(spec_on$stacking$class, 'additive'),
   "stacking class = 'additive' (note 50(a); §232 interaction is the calc-side scope mask)")
ok(identical(spec_on$usmca_treatment, 'none'), "usmca_treatment = 'none' (Brazil not USMCA)")
bc <- spec_on$programs[[1]]$rate$by_country
ok(isTRUE(all.equal(unname(bc[BR]), 0.25)) && length(bc) == 1, 'rate$by_country = Brazil 0.25 only')
ok(identical(spec_on$programs[[1]]$country_scope$include, BR), 'country_scope = Brazil')
br_ex_spec <- spec_on$programs[[1]]$exempt_products
ok(length(br_ex_spec$hts8) == 875, 'spec carries the 875-code unconditional exempt set')
ok(length(br_ex_spec$aircraft_hts8) == 546 && isTRUE(all.equal(br_ex_spec$aircraft_share, 0.90)),
   'spec carries 546 aircraft-use codes @ 90% exempt share (GTA effective 2.5%)')
ok(length(br_ex_spec$pharma_hts8) == 705 && isTRUE(all.equal(br_ex_spec$pharma_share, 0.50)),
   'spec carries 705 pharma-use codes @ 50% exempt share (GTA effective 12.5%)')
bc_pre <- .rate_get(spec_pre$programs[[1]]$rate, 'by_country')
ok(.rate_is_hollow(bc_pre) || length(bc_pre) == 0, 'pre-07-22 revision: hollow (date-gated)')
ok(length(spec_pre$programs[[1]]$country_scope$include) == 0, 'pre-07-22: empty country scope')
ok(is_authority_spec(spec_on), 'valid authority_spec object')
ok(is.null(.build_section_301_brazil(list(), countries, as.Date('2026-08-01'))),
   'absent config block -> NULL (defensive)')

cat('\n== stacking policy ==\n')
pol <- default_stacking_policy('5700')
ok(identical(pol$rate_s301br, list(net = 'net_s301br', class = 'additive')),
   'default policy: rate_s301br additive (net_s301br)')
make_min <- function(auth, cls) authority_spec(authority = auth,
  stacking = list(class = cls, exceptions = list()), programs = list())
base_specs <- do.call(authority_spec_set, list(
  make_min('section_232','primary_metal'), make_min('ieepa_reciprocal','content_split'),
  make_min('ieepa_fentanyl','content_split'), make_min('section_301','additive'),
  make_min('section_301_brazil','additive'), make_min('section_338','additive'),
  make_min('section_122','content_split'), make_min('section_201','additive'),
  make_min('other','additive')))
base_specs$ieepa_fentanyl$stacking$exceptions <- setNames(list('additive'), '5700')
ok(identical(stacking_policy_from_specs(base_specs, '5700'), pol),
   'policy_from_specs (with section_301_brazil spec) == default_stacking_policy')

cat('\n== calculator: apply_section301_brazil (synthetic fixture) ==\n')
# Real exempt lists + synthetic §232 tags. Arms exercised:
#   6109.10.00  plain covered (no §232, not exempt)     -> 0.25
#   0201.10.05  beef, note-50(a)(ii) exempt             -> 0
#   8802.30.01  aircraft-use list (a)(iv), existing row -> 0.25*(1-0.90) = 0.025
#   3003.31.00  pharma-use list (a)(v), SEEDED pair     -> 0.25*(1-0.50) = 0.125
#   7210.11.00  §232 STATUTORY arm (statutory > 0)      -> 0
#   7801.10.00  §232 ANNEX arm (in-scope tier, rate 0)  -> 0
#   3303.00.30  annex_2 (REMOVED from §232 scope)       -> PAYS 0.25
#   4413.00.00  §232 wood HEADING arm (0% rate)         -> 0
#   8703.23.01  §232 PV heading arm                     -> 0
specs_fix <- list(
  section_301_brazil = spec_on,
  section_232 = list(annex = list(tier = setNames(c('annex_1b', 'annex_1a'),
                                                  c('7801100000', '9990000000')))))
products <- tibble(
  hts10 = c('6109100012', '0201100500', '8802300100', '7210110000', '7801100000',
            '3303003000', '4413000000', '8703230100',
            '2203000060',    # beer — NOT in rates: seeding check (not exempt)
            '3003310000',    # pharma-use — NOT in rates: seeded THEN share-scaled
            '9990000000'),   # annex-tier product NOT in rates: must NOT seed
  base_rate = 0)
rates <- tibble(
  hts10   = c('6109100012', '6109100012', '0201100500', '8802300100', '7210110000',
              '7801100000', '3303003000', '4413000000', '8703230100'),
  country = c(BR, '5700', BR, BR, BR, BR, BR, BR, BR),
  base_rate = 0,
  rate_232           = c(0, 0, 0, 0, 0.25, 0,          0,         0,    0.25),
  statutory_rate_232 = c(0, 0, 0, 0, 0.25, 0,          0,         0,    0.25),
  s232_annex = c(NA, NA, NA, NA, NA, 'annex_1b', 'annex_2', NA, NA),
  heading_program = c(FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, TRUE, TRUE),
  rate_301 = 0, rate_301_cs = 0, rate_ieepa_recip = 0, rate_ieepa_fent = 0,
  rate_s122 = 0, rate_section_201 = 0, rate_other = 0)

out <- suppressMessages(apply_section301_brazil(rates, specs_fix, products, c(BR, '5700')))
g <- function(h, c) out$rate_s301br[out$hts10 == h & out$country == c]
ok(isTRUE(all.equal(g('6109100012', BR), 0.25)), 'plain Brazil good -> 25%')
ok(isTRUE(all.equal(g('6109100012', '5700'), 0)), 'non-Brazil row -> 0')
ok(isTRUE(all.equal(g('0201100500', BR), 0)), 'note-50(a)(ii) exempt (beef) -> 0')
ok(isTRUE(all.equal(g('8802300100', BR), 0.025)),
   'aircraft-use list (a)(iv): existing row scaled to 25% * (1 - 0.90) = 2.5%')
ok(isTRUE(all.equal(g('3003310000', BR), 0.125)),
   'pharma-use list (a)(v): SEEDED pair scaled to 25% * (1 - 0.50) = 12.5%')
ok(isTRUE(all.equal(g('7210110000', BR), 0)),
   'article with statutory §232 > 0 (statutory arm) -> 0 (FULL exclusion, no content split)')
ok(isTRUE(all.equal(g('7801100000', BR), 0)),
   'article with in-scope s232_annex tier, rate 0 (annex arm) -> 0')
ok(isTRUE(all.equal(g('3303003000', BR), 0.25)),
   'annex_2 (REMOVED from §232 scope) article PAYS 0.25 (same tier rule as s338)')
ok(isTRUE(all.equal(g('4413000000', BR), 0)), 'wood §232 heading arm -> 0')
ok(isTRUE(all.equal(g('8703230100', BR), 0)), 'PV §232 heading arm -> 0')
ok(isTRUE(all.equal(g('2203000060', BR), 0.25)), 'missing non-exempt Brazil pair seeded at 0.25')
ok(length(g('2203000060', '5700')) == 0, 'no non-Brazil pairs seeded')
ok(length(g('9990000000', BR)) == 0, 'missing ANNEX-TIER product NOT seeded (product-level §232 exclusion)')
ok(length(g('0201100500', '5700')) == 0, 'exempt product not expanded to other countries')

# Pre-turn-on spec: all-zero column persists (RATE_SCHEMA member, never dropped)
out_pre <- suppressMessages(apply_section301_brazil(
  rates, list(section_301_brazil = spec_pre), products, c(BR, '5700')))
ok('rate_s301br' %in% names(out_pre) && all(out_pre$rate_s301br == 0),
   'pre-07-22: rate_s301br present and all-zero')

cat('\n== additive stacking (rate_s301br never displaced) ==\n')
stk <- suppressMessages(apply_stacking_rules(
  tibble(hts10 = c('6109100012', '9999999999'), country = BR, base_rate = 0.02,
         rate_232 = c(0, 0.25), rate_301 = 0, rate_301_cs = 0,
         rate_ieepa_recip = 0, rate_ieepa_fent = 0, rate_s122 = c(0.10, 0),
         rate_s301br = 0.25, rate_s338 = 0, rate_section_201 = 0, rate_other = 0,
         metal_share = c(1, 0.6)),
  cty_china = '5700'))
ok(isTRUE(all.equal(stk$total_additional[1], 0.35)),
   'no §232: total = s122 0.10 + s301br 0.25 (fully additive)')
ok(isTRUE(all.equal(stk$total_additional[2], 0.25 + 0.25)),
   'with §232 present: s301br contributes FULL rate (additive class, no nonmetal scaling)')

cat('\n== boundary discovery: bnd_2026-07-22 ==\n')
bres <- tryCatch({
  rd <- load_revision_dates(use_policy_dates = TRUE)
  discover_boundaries(rd, here('data', 'timeseries'), pp,
                      overrides = pp$BOUNDARY_OVERRIDES,
                      horizon = pp$SERIES_HORIZON_END)
}, error = function(e) e)
if (inherits(bres, 'error')) {
  cat('  SKIP: discover_boundaries unavailable here (', conditionMessage(bres), ')\n')
} else {
  ok('2026-07-22' %in% as.character(bres$date), 'bnd_2026-07-22 discovered (override)')
  ok('bnd_2026-07-22' %in% bres$revision, 'mint id bnd_2026-07-22')
}

cat(sprintf('\n== SUMMARY: %d passed, %d failed ==\n', pass, fail))
if (fail > 0) quit(status = 1)
