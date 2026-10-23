# =============================================================================
# test_s338.R — Section 338 Canada authority (baseline, effective 2026-08-22)
# =============================================================================
# Covers: annex list integrity (63/52/439 + GN6 554 + 28 mv overlap), the
# adapter builder (.build_section_338: date-gate, additive, usmca 'none'),
# the stacking-policy invariant, the calculator step (apply_section338: +50%
# on covered Canada rows, §232 full-scope exclusion mask, GN6 utilization
# scaling with the measured -> HS2 mean -> 0 fallback; grid rows fixed), and
# boundary discovery of the bnd_2026-08-22 mint. Synthetic in-memory fixtures
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
prod_all <- read_csv(here('resources', 's338_products.csv'),
                     col_types = cols(.default = col_character()))
gn6  <- read_csv(here('resources', 's338_gn6_exempt_products.csv'),
                 col_types = cols(hts8 = col_character()))
ok(identical(sort(unique(prod_all$valid_from)), c('2026-08-22', '2026-09-15')),
   'two list versions: original (from 08-22) and rev_19 (from 09-15)')
# Original lists (PP 11046/11047/11048, valid 2026-08-22..2026-09-14)
prod <- prod_all %>% filter(valid_from == '2026-08-22') %>% rename(hts8 = hts_code)
ok(all(prod$valid_until == '2026-09-14'), 'original lists end 2026-09-14')
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
ok('22083030' %in% prod$hts8[prod$program == 'alcohol'], 'Irish/Scotch whisky 2208.30.30 on alcohol list')
ok('22083060' %in% prod$hts8[prod$program == 'alcohol'], 'Canadian whisky 2208.30.60 on alcohol list (proclamation target)')
ok('44130000' %in% prod$hts8[prod$program == 'alcohol'], 'densified wood 4413.00.00 on alcohol list (wood §232 test article)')

# rev_19 lists (PP 11064/11065, HTS 2026 rev_19 note 51(b), open-ended from 09-15)
r19 <- prod_all %>% filter(valid_from == '2026-09-15')
ok(all(is.na(r19$valid_until)), 'rev_19 lists are open-ended')
cnt19 <- table(r19$program)
ok(identical(unname(cnt19[['alcohol']]), 101L), 'rev_19 alcohol list = 101 codes')
ok(identical(unname(cnt19[['motor_vehicles']]), 513L), 'rev_19 motor_vehicles list = 513 codes')
ok(setequal(r19$hts_code[r19$program == 'dairy'], prod$hts8[prod$program == 'dairy']),
   'rev_19 dairy list unchanged (note 51(b)(2) not amended)')
ok(all(nchar(r19$hts_code) %in% c(8L, 10L)) && sum(nchar(r19$hts_code) == 10) == 12,
   'rev_19 lists name 12 HTS-10 statistical lines')
ok(!'22083060' %in% r19$hts_code && '2208306020' %in% r19$hts_code,
   'Canadian whisky 2208.30.60 narrowed to named HTS-10 lines')
ok(!'78011000' %in% r19$hts_code, 'refined lead 7801.10.00 dropped from the mv list')
ok('04061064' %in% r19$hts_code[r19$program == 'alcohol'], 'cheese 0406.10.64 added under 9903.03.12')

cat('\n== adapter: .build_section_338 (baseline config, date-gate) ==\n')
pp <- load_policy_params()
countries <- read_csv(here('resources', 'census_codes.csv'),
                      col_types = cols(.default = col_character()))$Code
ok(!is.null(pp$section_338), 'baseline policy_params carries section_338 (signed law)')
ok('2026-08-22' %in% as.character(pp$BOUNDARY_OVERRIDES), 'boundary_overrides lists the 2026-08-22 turn-on')
spec_on  <- .build_section_338(pp, countries, as.Date('2026-08-22'))
spec_pre <- .build_section_338(pp, countries, as.Date('2026-08-21'))
spec_914 <- .build_section_338(pp, countries, as.Date('2026-09-14'))
spec_915 <- .build_section_338(pp, countries, as.Date('2026-09-15'))
ok(identical(spec_on$programs[[1]]$product_scope$as_of, as.Date('2026-08-22')),
   'product_scope$as_of carries the snapshot date')
ok(identical(spec_914$programs[[1]]$settings$s232_excluded_headings,
             c('9903.03.12', '9903.03.13', '9903.03.14')),
   'through 09-14: §232 carve-out covers all three headings')
ok(identical(spec_915$programs[[1]]$settings$s232_excluded_headings, '9903.03.13'),
   'from 09-15: §232 carve-out covers dairy 9903.03.13 only (PP 11064/11065)')
ok(!is.null(spec_on) && spec_on$authority == 'section_338', 'authority built')
ok(identical(spec_on$stacking$class, 'additive'), "stacking class = 'additive' (note 51(a))")
ok(identical(spec_on$usmca_treatment, 'none'), "usmca_treatment = 'none' (applies regardless of origin)")
bc <- spec_on$programs[[1]]$rate$by_country
ok(isTRUE(all.equal(unname(bc[CA]), 0.50)) && length(bc) == 1, 'rate$by_country = Canada 0.50 only')
ok(identical(spec_on$programs[[1]]$country_scope$include, CA), 'country_scope = Canada')
bc_pre <- .rate_get(spec_pre$programs[[1]]$rate, 'by_country')
ok(is.null(bc_pre) || length(bc_pre) == 0, 'pre-08-22 revision: hollow (date-gated)')
ok(length(spec_pre$programs[[1]]$country_scope$include) == 0, 'pre-08-22: empty country scope')
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
  hts10 = c('2208303000',    # Irish/Scotch whisky (alcohol list)
            '0402100500',    # dairy list
            '4413000000',    # alcohol list, wood §232 HEADING arm (0% rate)
            '7203100000',    # mv list, §232 STATUTORY arm (statutory > 0)
            '7801100000',    # mv list, §232 ANNEX arm (in-scope tier, rate 0)
            '3303003000',    # mv list, annex_2 (REMOVED from §232 scope) — PAYS
            '7326200000',    # NOT covered (mask-free control)
            '8529901620',    # mv list, GN6 measured
            '8517620000',    # mv list, GN6 unmeasured (HS2-85 mean)
            '9403200011',    # mv list, GN6 unmeasured (no HS2-94 measurement)
            '2203000060'),   # beer (alcohol list) — on the grid, zero rates: coverage check
  base_rate = 0)

# The one-grid build materializes every pair before authority steps run, so
# the beer row (2203000060 x CA) is PRESENT with zero rates — the retired
# sparse-table seeder is not needed and apply_section338 never adds rows.
rates <- tibble(
  hts10   = c('2208303000', '2208303000', '0402100500', '4413000000',
              '7203100000', '7801100000', '3303003000', '7326200000',
              '8529901620', '8517620000', '9403200011', '2203000060'),
  country = c(CA, '5700', CA, CA, CA, CA, CA, CA, CA, CA, CA, CA),
  base_rate = 0,
  rate_232           = c(0, 0, 0, 0,    0.25, 0,          0, 0.25, 0, 0, 0, 0),
  statutory_rate_232 = c(0, 0, 0, 0,    0.25, 0,          0, 0.25, 0, 0, 0, 0),
  s232_annex = c(NA, NA, NA, NA, NA, 'annex_1b', 'annex_2', NA, NA, NA, NA, NA),
  heading_program = c(FALSE, FALSE, FALSE, TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE),
  rate_301 = 0, rate_301_cs = 0, rate_ieepa_recip = 0, rate_ieepa_fent = 0,
  rate_s122 = 0, rate_section_201 = 0, rate_other = 0)

out <- suppressMessages(apply_section338(rates, specs_fix, products, c(CA, '5700')))
g <- function(h, c) out$rate_s338[out$hts10 == h & out$country == c]
ok(isTRUE(all.equal(g('2208303000', CA), 0.50)), 'Irish/Scotch whisky 2208.30.30 -> +50pp')
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
ok(isTRUE(all.equal(g('2203000060', CA), 0.50)), 'covered beer pair on the complete grid charged 0.50')
ok(length(g('2203000060', '5700')) == 0, 'no rows added for non-Canada pairs (grid is fixed)')

# Pre-turn-on spec: all-zero column persists (RATE_SCHEMA member, never dropped)
out_pre <- suppressMessages(apply_section338(rates, list(section_338 = spec_pre),
                                             products, c(CA, '5700')))
ok('rate_s338' %in% names(out_pre) && all(out_pre$rate_s338 == 0),
   'pre-08-22: rate_s338 present and all-zero')

cat('\n== calculator: rev_19 lists + narrowed §232 carve-out (from 2026-09-15) ==\n')
fix_915 <- spec_915
fix_915$programs[[1]]$exempt_products$gn6_utilization <- setNames(0.40, '8529901620')
products_915 <- tibble(
  hts10 = c('2208306020',    # Canadian whisky, named HTS-10 line -> covered
            '2208306010',    # sibling line NOT named -> uncovered
            '0406106400',    # cheese, added to the alcohol heading
            '7801100000',    # refined lead, dropped from the mv list
            '4413000000',    # alcohol list, wood §232 heading arm -> now stacks
            '7203100000',    # mv list, statutory §232 > 0 -> now stacks
            '0402100500'),   # dairy, forced into §232 scope -> carve-out holds
  base_rate = 0)
rates_915 <- tibble(
  hts10   = products_915$hts10,
  country = CA,
  base_rate = 0,
  rate_232           = c(0, 0, 0, 0, 0, 0.25, 0.25),
  statutory_rate_232 = c(0, 0, 0, 0, 0, 0.25, 0.25),
  s232_annex = NA_character_,
  heading_program = c(FALSE, FALSE, FALSE, FALSE, TRUE, FALSE, FALSE),
  rate_301 = 0, rate_301_cs = 0, rate_ieepa_recip = 0, rate_ieepa_fent = 0,
  rate_s122 = 0, rate_section_201 = 0, rate_other = 0)
out_915 <- suppressMessages(apply_section338(rates_915, list(section_338 = fix_915),
                                             products_915, CA))
g9 <- function(h) out_915$rate_s338[out_915$hts10 == h]
ok(isTRUE(all.equal(g9('2208306020'), 0.50)), 'named HTS-10 whisky line 2208.30.60.20 -> 0.50')
ok(isTRUE(all.equal(g9('2208306010'), 0)), 'unnamed sibling 2208.30.60.10 -> 0 (narrowed entry)')
ok(isTRUE(all.equal(g9('0406106400'), 0.50)), 'added cheese 0406.10.64 -> 0.50')
ok(isTRUE(all.equal(g9('7801100000'), 0)), 'dropped refined lead 7801.10.00 -> 0')
ok(isTRUE(all.equal(g9('4413000000'), 0.50)), 'alcohol-list article in §232 heading scope now stacks -> 0.50')
ok(isTRUE(all.equal(g9('7203100000'), 0.50)), 'mv-list article with statutory §232 now stacks -> 0.50')
ok(isTRUE(all.equal(g9('0402100500'), 0)), 'dairy article in §232 scope keeps the carve-out -> 0')
ok(nrow(out_915) == nrow(rates_915) && identical(out_915$hts10, rates_915$hts10),
   'joins preserve row count and order')

# Same fixture on 09-14: original lists and the full carve-out
out_914 <- suppressMessages(apply_section338(rates_915, list(section_338 = spec_914),
                                             products_915, CA))
g8 <- function(h) out_914$rate_s338[out_914$hts10 == h]
ok(isTRUE(all.equal(g8('2208306010'), 0.50)), '09-14: whole 2208.30.60 covered -> 0.50')
ok(isTRUE(all.equal(g8('0406106400'), 0)), '09-14: cheese not yet covered -> 0')
ok(isTRUE(all.equal(g8('7801100000'), 0.50)), '09-14: refined lead still covered -> 0.50')
ok(isTRUE(all.equal(g8('7203100000'), 0)), '09-14: §232-scope mv article excluded -> 0')

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

cat('\n== boundary discovery: 2026-08-22 is a rev_17 EDGE, not a mint ==\n')
# Until rev_17 was ingested, the §338 turn-on needed a synthetic mint. rev_17 is
# policy-dated 2026-08-22 (PP 11056's moved effective date), which makes that
# date a real revision edge — so discover_boundaries drops the override
# (owner_of returns NA on edges) and rev_17's own snapshot owns the turn-on.
# Exactly the rev_13 / 2026-07-24 pattern. The date stays listed in
# boundary_overrides, which is harmless and is the established convention.
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
  ok(!('bnd_2026-08-22' %in% bres$revision),
     'no bnd_2026-08-22 mint (edge-coincident with rev_17)')
  rd_chk <- load_revision_dates(use_policy_dates = TRUE)
  ok(as.Date('2026-08-22') %in%
       as.Date(rd_chk$effective_date[rd_chk$revision == '2026_rev_17']),
     'rev_17 resolves to 2026-08-22 under policy dating')
}

cat(sprintf('\n== SUMMARY: %d passed, %d failed ==\n', pass, fail))
if (fail > 0) quit(status = 1)
