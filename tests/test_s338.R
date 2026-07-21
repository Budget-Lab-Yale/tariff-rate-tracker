# =============================================================================
# test_s338.R — Section 338 Canada authority (baseline, effective 2026-08-19)
# =============================================================================
# Covers: annex list integrity (63/52/439 + GN6 554 + 28 mv overlap), the
# adapter builder (.build_section_338: date-gate, additive, usmca 'none'),
# the stacking-policy invariant, the calculator step (apply_section338: +50%
# on covered Canada rows, §232 full-scope exclusion mask, GN6 utilization
# scaling with the measured -> HS2 mean -> 0 fallback, pair seeding), and
# boundary discovery of the bnd_2026-08-19 mint. Synthetic in-memory fixtures
# for the calc checks; repo resource files for list integrity.
#
# Usage: Rscript tests/test_s338.R
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

CA <- '1220'

cat('\n== annex product lists (resources/, built by scripts/build_s338_annex.R) ==\n')
prod <- read_csv(here('resources', 's338_products.csv'),
                 col_types = cols(.default = col_character()))
gn6  <- read_csv(here('resources', 's338_gn6_exempt_products.csv'),
                 col_types = cols(hts8 = col_character()))
cnt <- table(prod$program)
ok(identical(unname(cnt[['alcohol']]), 63L), 'alcohol list = 63 hts8 (annex count)')
ok(identical(unname(cnt[['dairy']]), 52L), 'dairy list = 52 hts8 (annex count)')
ok(identical(unname(cnt[['motor_vehicles']]), 439L), 'motor_vehicles list = 439 hts8 (annex count)')
ok(nrow(prod) == 554 && !anyDuplicated(prod$hts8), '554 unique covered hts8, no cross-program dup')
ok(identical(sort(unique(prod$ch99_heading)),
             c('9903.03.12', '9903.03.13', '9903.03.14')), 'ch99 headings 9903.03.12/.13/.14')
ok(nrow(gn6) == 554, 'GN6 note-51(d) list = 554 hts8')
ov <- prod %>% filter(hts8 %in% gn6$hts8) %>% count(program)
ok(!'alcohol' %in% ov$program && !'dairy' %in% ov$program,
   'GN6 overlap: alcohol/dairy = 0')
ok(identical(ov$n[ov$program == 'motor_vehicles'], 28L), 'GN6 overlap: motor_vehicles = 28')
ok('22083030' %in% prod$hts8[prod$program == 'alcohol'], 'Canadian whisky 2208.30.30 on alcohol list')
ok('44130000' %in% prod$hts8[prod$program == 'alcohol'], 'densified wood 4413.00.00 on alcohol list (wood §232 test article)')

cat('\n== adapter: .build_section_338 (baseline config, date-gate) ==\n')
pp <- load_policy_params()
countries <- read_csv(here('resources', 'census_codes.csv'),
                      col_types = cols(.default = col_character()))$Code
ok(!is.null(pp$section_338), 'baseline policy_params carries section_338 (signed law)')
ok('2026-08-19' %in% as.character(pp$BOUNDARY_OVERRIDES), 'boundary_overrides lists the 2026-08-19 turn-on')
spec_on  <- .build_section_338(pp, countries, as.Date('2026-08-19'))
spec_pre <- .build_section_338(pp, countries, as.Date('2026-08-18'))
ok(!is.null(spec_on) && spec_on$authority == 'section_338', 'authority built')
ok(identical(spec_on$stacking$class, 'additive'), "stacking class = 'additive' (note 51(a))")
ok(identical(spec_on$usmca_treatment, 'none'), "usmca_treatment = 'none' (applies regardless of origin)")
bc <- spec_on$programs[[1]]$rate$by_country
ok(isTRUE(all.equal(unname(bc[CA]), 0.50)) && length(bc) == 1, 'rate$by_country = Canada 0.50 only')
ok(identical(spec_on$programs[[1]]$country_scope$include, CA), 'country_scope = Canada')
bc_pre <- .rate_get(spec_pre$programs[[1]]$rate, 'by_country')
ok(.rate_is_hollow(bc_pre) || length(bc_pre) == 0, 'pre-08-19 revision: hollow (date-gated)')
ok(length(spec_pre$programs[[1]]$country_scope$include) == 0, 'pre-08-19: empty country scope')
ep <- spec_on$programs[[1]]$exempt_products
ok(length(ep$gn6_hts8) == 554, 'spec carries the 554-code GN6 set')
ok(length(ep$gn6_utilization) > 100, 'spec carries measured GN6 utilization shares')
ok(is_authority_spec(spec_on), 'valid authority_spec object')
ok(is.null(.build_section_338(list(), countries, as.Date('2026-09-01'))),
   'absent config block -> NULL (defensive)')

cat('\n== stacking policy ==\n')
pol <- default_stacking_policy('5700')
ok(identical(pol$rate_s338, list(net = 'net_s338', class = 'additive')),
   'default policy: rate_s338 additive (net_s338)')
make_min <- function(auth, cls) authority_spec(authority = auth,
  stacking = list(class = cls, exceptions = list()), programs = list())
base_specs <- do.call(authority_spec_set, list(
  make_min('section_232','primary_metal'), make_min('ieepa_reciprocal','content_split'),
  make_min('ieepa_fentanyl','content_split'), make_min('section_301','additive'),
  make_min('section_338','additive'),
  make_min('section_122','content_split'), make_min('section_201','additive'),
  make_min('other','additive')))
base_specs$ieepa_fentanyl$stacking$exceptions <- setNames(list('additive'), '5700')
ok(identical(stacking_policy_from_specs(base_specs, '5700'), pol),
   'policy_from_specs (with section_338 spec) == default_stacking_policy')

cat('\n== calculator: apply_section338 (synthetic fixture) ==\n')
# Synthetic spec: Canada 0.50, covered list from the real CSV, GN6 utilization
# CONTROLLED so both fallback tiers are deterministic (no HS2-mean tier for §338):
#   8529.90.16xx measured 0.40   -> factor 0.60
#   8517.62.00xx unmeasured (same ch85 as the measured code) -> share 0 ->
#                factor 1.00 — proves §338 does NOT pool the sibling's share via
#                an HS2 mean the way §122 does
#   9403.20.00xx unmeasured, no ch94 measurement -> share 0 -> factor 1.00
fix_spec <- spec_on
fix_spec$programs[[1]]$exempt_products$gn6_utilization <-
  setNames(0.40, '8529901620')
specs_fix <- list(section_338 = fix_spec)

products <- tibble(
  hts10 = c('2208303000',    # whisky (alcohol list)
            '0402100500',    # dairy list
            '4413000000',    # alcohol list, wood §232 HEADING arm (0% rate)
            '7203100000',    # mv list, §232 STATUTORY arm (statutory > 0)
            '7801100000',    # mv list, §232 ANNEX arm (in-scope tier, rate 0)
            '3303003000',    # mv list, annex_2 (REMOVED from §232 scope) — PAYS
            '7326200000',    # NOT covered (mask-free control)
            '8529901620',    # mv list, GN6 measured
            '8517620000',    # mv list, GN6 unmeasured (HS2-85 mean)
            '9403200011',    # mv list, GN6 unmeasured (no HS2-94 measurement)
            '2203000060'),   # beer (alcohol list) — NOT in rates: seeding check
  base_rate = 0)

rates <- tibble(
  hts10   = c('2208303000', '2208303000', '0402100500', '4413000000',
              '7203100000', '7801100000', '3303003000', '7326200000',
              '8529901620', '8517620000', '9403200011'),
  country = c(CA, '5700', CA, CA, CA, CA, CA, CA, CA, CA, CA),
  base_rate = 0,
  rate_232           = c(0, 0, 0, 0,    0.25, 0,          0, 0.25, 0, 0, 0),
  statutory_rate_232 = c(0, 0, 0, 0,    0.25, 0,          0, 0.25, 0, 0, 0),
  s232_annex = c(NA, NA, NA, NA, NA, 'annex_1b', 'annex_2', NA, NA, NA, NA),
  heading_program = c(FALSE, FALSE, FALSE, TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE),
  rate_301 = 0, rate_301_cs = 0, rate_ieepa_recip = 0, rate_ieepa_fent = 0,
  rate_s122 = 0, rate_section_201 = 0, rate_other = 0)

out <- suppressMessages(apply_section338(rates, specs_fix, products, c(CA, '5700')))
g <- function(h, c) out$rate_s338[out$hts10 == h & out$country == c]
ok(isTRUE(all.equal(g('2208303000', CA), 0.50)), 'Canada whisky 2208.30.30 -> +50pp')
ok(isTRUE(all.equal(g('2208303000', '5700'), 0)), 'non-Canada row -> 0')
ok(isTRUE(all.equal(g('0402100500', CA), 0.50)), 'Canada dairy 0402.10.05 -> +50pp')
ok(isTRUE(all.equal(g('4413000000', CA), 0)),
   'covered wood article paying 0% §232 (heading_program arm / USMCA-parts case) -> 0')
ok(isTRUE(all.equal(g('7203100000', CA), 0)),
   'covered article with statutory §232 > 0 (statutory arm) -> 0')
ok(isTRUE(all.equal(g('7801100000', CA), 0)),
   'covered article with in-scope s232_annex tier, rate 0 (annex arm) -> 0')
ok(isTRUE(all.equal(g('3303003000', CA), 0.50)),
   'annex_2 (REMOVED from §232 scope) covered article PAYS 0.50 (beer-class fix)')
ok(isTRUE(all.equal(g('7326200000', CA), 0)), 'uncovered product -> 0 (positive lists only)')
ok(isTRUE(all.equal(g('8529901620', CA), 0.50 * 0.60)), 'GN6 measured (8529.90.16, share .40) -> 0.30')
ok(isTRUE(all.equal(g('8517620000', CA), 0.50)), 'GN6 unmeasured (8517.62.00) -> share 0 -> full 0.50 (no HS2-mean pooling from ch85 sibling)')
ok(isTRUE(all.equal(g('9403200011', CA), 0.50)), 'GN6 unmeasured, no measurement -> share 0 -> full 0.50 (NOT §122\'s full exemption)')
ok(isTRUE(all.equal(g('2203000060', CA), 0.50)), 'missing covered Canada pair seeded at 0.50')
ok(length(g('2203000060', '5700')) == 0, 'no non-Canada pairs seeded')

# Pre-turn-on spec: all-zero column persists (RATE_SCHEMA member, never dropped)
out_pre <- suppressMessages(apply_section338(rates, list(section_338 = spec_pre),
                                             products, c(CA, '5700')))
ok('rate_s338' %in% names(out_pre) && all(out_pre$rate_s338 == 0),
   'pre-08-19: rate_s338 present and all-zero')

cat('\n== additive stacking (rate_s338 never displaced) ==\n')
stk <- suppressMessages(apply_stacking_rules(
  tibble(hts10 = c('2208303000', '9999999999'), country = CA, base_rate = 0.02,
         rate_232 = c(0, 0.25), rate_301 = 0, rate_301_cs = 0,
         rate_ieepa_recip = 0, rate_ieepa_fent = 0, rate_s122 = c(0.10, 0),
         rate_s338 = 0.50, rate_section_201 = 0, rate_other = 0,
         metal_share = c(1, 0.6)),
  cty_china = '5700'))
ok(isTRUE(all.equal(stk$total_additional[1], 0.60)),
   'no §232: total = s122 0.10 + s338 0.50 (fully additive)')
ok(isTRUE(all.equal(stk$total_additional[2], 0.25 + 0.50)),
   'with §232: s338 contributes FULL rate (additive class, no nonmetal scaling)')

cat('\n== boundary discovery: bnd_2026-08-19 ==\n')
bres <- tryCatch({
  rd <- load_revision_dates(use_policy_dates = TRUE)
  b <- discover_boundaries(rd, here('data', 'timeseries'), pp,
                           overrides = pp$BOUNDARY_OVERRIDES,
                           horizon = pp$SERIES_HORIZON_END)
  b
}, error = function(e) e)
if (inherits(bres, 'error')) {
  cat('  SKIP: discover_boundaries unavailable here (', conditionMessage(bres), ')\n')
} else {
  ok('2026-08-19' %in% as.character(bres$date), 'bnd_2026-08-19 discovered (override)')
  ok('bnd_2026-08-19' %in% bres$revision, 'mint id bnd_2026-08-19')
}

cat(sprintf('\n== SUMMARY: %d passed, %d failed ==\n', pass, fail))
if (fail > 0) quit(status = 1)
