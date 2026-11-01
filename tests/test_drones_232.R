# =============================================================================
# test_drones_232.R — Section 232 drones (U.S. note 43, PP 11055)
# =============================================================================
# The drone program is config-fed (section_232_headings.drones) and date-gated
# to 2026-09-03. HTS 2026 rev_18 codifies its headings 9903.08.20-.26, so the
# load-bearing check is that the config rates equal the codified ones: a config
# edit or a later revision restating the headings fails here first.
#
# Also asserted:
#   * the classifier routes exactly 9903.08.20-.26 to section_232;
#   * the heading gate turns on 2026-09-03, not before;
#   * apply_additive_232_program(): thermal/non-thermal split, UK and partner
#     rates, basket-line scaling, additive stacking, non-displacing bookkeeping
#     that accumulates across polysilicon + drones;
#   * a drone-only row stays visible to the overlays (.s232_in_scope FALSE).
#
# Usage: Rscript tests/test_drones_232.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse); library(here); library(jsonlite)
})
suppressMessages({
  source(here('src', 'core', 'helpers.R'))
  source(here('src', 'core', 'logging.R'))
  source(here('src', 'pipeline', '03_parse_chapter99.R'))
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

pp <- load_policy_params(use_policy_dates = TRUE)
cfg <- pp$section_232_headings$drones
TURN_ON <- as.Date('2026-09-03')

cat('\n== config block ==\n')
ok(!is.null(cfg), 'section_232_headings carries drones')
ok(identical(as.character(cfg$effective_date), '2026-09-03'), 'effective 2026-09-03 (PP 11055 cl. 1)')
ok(identical(cfg$displaces_overlays, FALSE), 'displaces_overlays: false (no overlay note amended)')
ok(identical(cfg$usmca_exempt, FALSE), 'no USMCA exemption (note 43(b))')

cat('\n== rev_18: config rates vs codified headings ==\n')
ch18 <- suppressMessages(
  parse_chapter99(here('data', 'hts_archives', 'hts_2026_rev_18.json.gz')))
rate_of <- function(code) ch18$rate[ch18$ch99_code == code]
ok(all(paste0('9903.08.', 20:26) %in% ch18$ch99_code), 'rev_18 carries 9903.08.20-.26')
ok(all(ch18$authority[ch18$ch99_code %in% paste0('9903.08.', 20:26)] == 'section_232'),
   'parsed headings carry authority section_232')
ok(isTRUE(all.equal(rate_of('9903.08.21'), as.numeric(cfg$default_rate))),
   '9903.08.21 (+100%) == default_rate')
ok(isTRUE(all.equal(rate_of('9903.08.22'), as.numeric(cfg$rate_split$rate))),
   '9903.08.22 (+25%) == rate_split$rate')
ok(isTRUE(all.equal(rate_of('9903.08.23'), as.numeric(cfg$country_rates$CTY_UK))),
   '9903.08.23 (+10%) == UK country rate')
ok(isTRUE(all.equal(rate_of('9903.08.24'), 0.15)) && all(unlist(cfg$target_total) == 0.15),
   '9903.08.24 (15% total) == every partner target_total')

cat('\n== classifier ==\n')
auth <- vapply(paste0('9903.08.', 19:27), classify_authority, character(1))
ok(all(auth[as.character(paste0('9903.08.', 20:26))] == 'section_232'),
   '9903.08.20-.26 -> section_232')
ok(auth[['9903.08.19']] != 'section_232' && auth[['9903.08.27']] != 'section_232',
   'neighbouring 9903.08.19 / .27 not routed to section_232')

cat('\n== heading gate ==\n')
# Minimal §232 stub: every source program at rate 0, so only the date-gated
# programs (polysilicon, drones) can switch on.
stub_specs <- list(section_232 = list(programs = lapply(
  c('autos_source', 'copper_source', 'wood_source', 'mhd_source',
    'semiconductors_source', 'pharmaceuticals_source'),
  function(id) authority_program(id = id, rate = list(default = 0)))))
stub_rates <- list(wood_furniture_rate = 0, auto_has_deals = FALSE, auto_has_parts = FALSE)
g_before <- compute_heading_gates(stub_specs, stub_rates, effective_date = TURN_ON - 1,
                                  heading_configs = pp$section_232_headings)
g_on <- compute_heading_gates(stub_specs, stub_rates, effective_date = TURN_ON,
                              heading_configs = pp$section_232_headings)
ok(identical(g_before$drones, FALSE), 'gate off on 2026-09-02')
ok(identical(g_on$drones, TRUE), 'gate on from 2026-09-03')

cat('\n== apply_additive_232_program (drones) ==\n')
CN <- '5700'; UK <- '4120'; DE <- '4280'; JP <- '5880'
rates <- tibble(
  hts10   = c('8806210000', '8806240000', '8806210000', '8806210000',
              '8806210000', '8807100015', '8537109170', '8806210000',
              '0101210010'),
  country = c(CN, CN, UK, DE, JP, CN, CN, CN, CN),
  base_rate = c(0, 0, 0, 0, 0.05, 0, 0, 0, 0),
  rate_232  = c(0, 0, 0, 0, 0, 0, 0.25, 0, 0))
drone_products <- c('8806210000', '8806240000', '8807100015', '8537109170')
out <- apply_additive_232_program(rates, drone_products, cfg,
                                  countries = c(CN, UK, DE, JP), pp = pp)
split <- cfg$rate_split$share * cfg$default_rate +
  (1 - cfg$rate_split$share) * cfg$rate_split$rate
ok(isTRUE(all.equal(out$rate_232[1], split)),
   sprintf('China thermal/non-thermal line 8806.21 -> blended %.4f', split))
ok(isTRUE(all.equal(out$rate_232[2], 1.00)), 'China 8806.24 (thermal-only list) -> 1.00')
ok(isTRUE(all.equal(out$rate_232[3], 0.10)), 'UK -> +0.10 on both legs of the split')
ok(isTRUE(all.equal(out$rate_232[4], 0.15)), 'EU (Germany), MFN 0 -> 15% total')
ok(isTRUE(all.equal(out$rate_232[5], 0.10)), 'Japan, MFN 5% -> +0.10 to reach 15% total')
ok(isTRUE(all.equal(out$rate_232[6], 1.00 * cfg$basket_lines$applicability_share)),
   'China 8807 part -> 1.00 x basket applicability share')
ok(isTRUE(all.equal(out$rate_232[7], 0.25 + 1.00 * cfg$basket_lines$applicability_share)),
   '8537.10.9170 adds the scaled drone component on top of an existing §232 rate')
ok(out$rate_232[9] == 0, 'uncovered product untouched')
ok(isTRUE(all.equal(out$rate_232_nondisplacing, out$rate_232 - rates$rate_232)),
   'rate_232_nondisplacing == the drone component on every row')

cat('\n== non-displacing bookkeeping accumulates across programs ==\n')
poly_cfg <- list(default_rate = 0.15, displaces_overlays = FALSE)
both <- rates[1, ] %>% mutate(hts10 = '8806240000')
both <- apply_additive_232_program(both, '8806240000', poly_cfg, countries = CN, pp = list())
both <- apply_additive_232_program(both, '8806240000', cfg, countries = CN, pp = pp)
ok(isTRUE(all.equal(both$rate_232, 1.15)) &&
     isTRUE(all.equal(both$rate_232_nondisplacing, 1.15)),
   'second additive program adds to, not overwrites, rate_232_nondisplacing')

cat('\n== overlay mask ==\n')
mask_in <- out %>% mutate(statutory_rate_232 = rate_232, s232_annex = NA_character_,
                          heading_program = hts10 %in% drone_products,
                          s232_nondisplacing = hts10 %in% setdiff(drone_products, '8537109170'))
in_scope <- .s232_in_scope(mask_in)
ok(!any(in_scope[1:6]), 'drone-only rows stay visible to FL-301 / Brazil-§301 / §338')
ok(isTRUE(in_scope[7]), '8537.10.9170 keeps its displacing (auto-parts) claim')

cat(sprintf('\n== SUMMARY: %d passed, %d failed ==\n', pass, fail))
if (fail > 0) quit(status = 1)
