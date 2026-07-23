# =============================================================================
# test_forced_labor_scenario.R — baseline forced-labor §301 final action
# =============================================================================
# Lightweight unit tests (no full build): the deep-merge overlay loader, the
# compatibility aliases, final rate tiers/MFN caps, Annex II inputs, date gate,
# and the stacking-policy invariant. Run:
#   bash -lc 'module load R/4.4.2-gfbf-2024a; Rscript tests/test_forced_labor_scenario.R'
# =============================================================================

suppressPackageStartupMessages({
  library(here); library(tidyverse)
})
suppressMessages({
  source(here('src', 'model', 'authority_spec.R'))
  source(here('src', 'model', 'policy_params.R'))
  source(here('src', 'model', 'authority_adapter.R'))
  source(here('src', 'model', 'stacking.R'))
  source(here('src', 'pipeline', '06_calculate_rates.R'))
})

pass <- 0L; fail <- 0L
ok <- function(cond, msg) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat('  PASS: ', msg, '\n') }
  else { fail <<- fail + 1L; cat('  FAIL: ', msg, '\n') }
}

cat('\n== deep-merge ==\n')
base <- list(a = 1, nest = list(x = 1, y = 2), lst = list(1, 2, 3))
ov   <- list(nest = list(y = 20, z = 30), lst = list(9), new = 'n')
m <- .deep_merge_lists(base, ov)
ok(identical(m$a, 1), 'untouched scalar kept')
ok(identical(m$nest$x, 1) && identical(m$nest$y, 20) && identical(m$nest$z, 30), 'nested map deep-merged')
ok(identical(m$lst, list(9)), 'list-valued key REPLACED wholesale (not element-merged)')
ok(identical(m$new, 'n'), 'new overlay key added')
# Contract: a non-map (incl. empty) overlay REPLACES; the LOADER guards this by
# only merging when length(overlay) > 0, so an empty/`actual` overlay == baseline.
ok(identical(.deep_merge_lists(base, list()), list()), 'non-map/empty overlay replaces (loader guards with length>0)')
ok(identical(.deep_merge_lists(base, list(a = 99))$a, 99) && identical(.deep_merge_lists(base, list(a = 99))$nest, base$nest),
   'single scalar override leaves siblings intact')

cat('\n== baseline + compatibility aliases ==\n')
pp_base <- load_policy_params()
pp_fl   <- load_policy_params(scenario = 'forced_labor')
pp_new  <- load_policy_params(scenario = 'new_301')
ok(!is.null(pp_base$section_301_forced_labor),
   'ACTUAL baseline carries the forced-labor final action')
ok(identical(as.character(pp_base$section_301_forced_labor$effective_date), '2026-07-24'),
   'final action effective_date = 2026-07-24')
ok('2026-07-24' %in% as.character(pp_base$BOUNDARY_OVERRIDES),
   'ACTUAL boundary calendar has the turn-on')
ok('2026-09-29' %in% as.character(pp_fl$BOUNDARY_OVERRIDES), 'forced_labor: inherits baseline pharma turn-on (2026-09-29)')
ok('2026-09-29' %in% as.character(pp_base$BOUNDARY_OVERRIDES), 'baseline: pharma turn-on is a boundary_override')
ok(length(pp_base$scheduled_activations) == 0, 'baseline: no scheduled_activations (pharma date-gated, not op-activated)')
ok(identical(pp_fl, pp_base), 'forced_labor compatibility alias == ACTUAL')
ok(identical(pp_new, pp_base), 'new_301 compatibility alias == ACTUAL')

cat('\n== fail-closed overlay schema ==\n')
scenario_fixture <- function(name, meta, overlay) {
  root <- tempfile('scenarios_')
  dir.create(file.path(root, name), recursive = TRUE)
  writeLines(meta, file.path(root, name, 'meta.yaml'))
  writeLines(overlay, file.path(root, name, 'overlay.yaml'))
  root
}
expect_overlay_error <- function(root, name, pattern) {
  err <- tryCatch({
    load_policy_params(scenario = name, scenarios_dir = root)
    NULL
  }, error = identity)
  !is.null(err) && grepl(pattern, conditionMessage(err))
}

bad_top <- scenario_fixture(
  'bad_top',
  c('kind: counterfactual', "description: 'typo fixture'", 'publish: false'),
  'disabled_authorites: [section_232]'
)
ok(expect_overlay_error(bad_top, 'bad_top', 'unknown key.*disabled_authorites'),
   'unknown top-level overlay key fails loud')

bad_nested <- scenario_fixture(
  'bad_nested',
  c('kind: alternative', "description: 'nested typo fixture'", 'publish: false'),
  c('usmca_shares:', "  mod: 'annual'")
)
ok(expect_overlay_error(bad_nested, 'bad_nested', 'unknown key.*usmca_shares.mod'),
   'unknown nested overlay key fails loud with its full path')

cat('\n== final tiers + MFN-net semantics ==\n')
cfg <- pp_fl$section_301_forced_labor
countries <- read_csv(here('resources', 'census_codes.csv'),
                      col_types = cols(.default = col_character()))$Code
bc <- .resolve_s301fl_by_country(cfg, countries)
ok(identical(unname(bc['5700']), 0.125), 'China (5700) = 12.5%')
ok(identical(unname(bc['5820']), 0.125), 'Hong Kong (5820) = 12.5%')
ok(identical(unname(bc['5520']), 0.125), 'Vietnam (5520) = 12.5%')
ok(identical(unname(bc['5830']), 0.10), 'Taiwan (5830) = 10%')
ok(identical(unname(bc['1220']), 0.10), 'Canada (1220) = 10%')
ok(identical(unname(bc['4280']), 0.10), 'Germany/EU (4280) = 10%')
ok(identical(unname(bc['5330']), 0.10), 'India moved to flat 10%')
ok(identical(unname(bc['5880']), 0.125), 'Japan target total = 12.5%')
ok(length(bc) == 86, 'exactly 86 covered census codes (40 + 46)')
ok(!('9999' %in% names(bc)), 'unknown census code excluded')
bt <- .resolve_s301fl_by_country_type(cfg, countries)
ok(identical(unname(bt['4280']), 'floor'), 'EU is 10% net of MFN')
ok(identical(unname(bt['5830']), 'floor'), 'Taiwan is 10% net of MFN')
ok(identical(unname(bt['5880']), 'floor'), 'Japan is 12.5% net of MFN')
ok(identical(unname(bt['5800']), 'floor'), 'South Korea is 12.5% net of MFN')
ok(identical(unname(bt['5330']), 'surcharge'), 'India is a flat surcharge')

cat('\n== adapter: build + date-gate ==\n')
spec_on  <- .build_section_301_forced_labor(pp_base, countries, as.Date('2026-08-01'))
spec_off <- .build_section_301_forced_labor(pp_fl, countries, as.Date('2026-06-01'))
ok(!is.null(spec_on) && spec_on$authority == 'section_301_forced_labor',
   'ACTUAL -> authority built')
ok(identical(spec_on$stacking$class, 'additive'), 'stacking class = additive')
ok(identical(spec_on$usmca_treatment, 'eligible'), 'usmca_treatment = eligible')
bc_on <- spec_on$programs[[1]]$rate$by_country
ok(!is.null(bc_on) && length(bc_on) == 86, 'on-date: by_country populated (86)')
bc_off <- .rate_get(spec_off$programs[[1]]$rate, 'by_country')
ok(is.null(bc_off) || length(bc_off) == 0, 'pre-turn-on date: by_country empty (date-gate)')
ex <- spec_on$programs[[1]]$exempt_products
ok(length(ex$hts_code) == 879, 'final common full/Ex annex loaded (879 codes)')
ok(length(ex$aircraft_hts_code) == 541, 'final common aircraft-use annex loaded (541 codes)')
ok(length(ex$pharma_hts_code) == 700, 'final common pharma-use annex loaded (700 codes)')
ok(nrow(ex$country_rules) > 10000, 'country-specific + preference rules expanded')
ok(length(ex$patented_pharma_hts10) > 0, 'post-2026-07-31 patented pharma exclusion loaded')
ok(validate_spec_set(do.call(authority_spec_set, list(spec_on))) %||% TRUE, 'spec validates')

cat('\n== calculator output ==\n')
plain <- '9999999999'
common_full <- paste0(ex$hts_code[[1]], ifelse(nchar(ex$hts_code[[1]]) == 8, '00', ''))
air <- paste0(ex$aircraft_hts_code[[1]],
              ifelse(nchar(ex$aircraft_hts_code[[1]]) == 8, '00', ''))
pharma <- paste0(ex$pharma_hts_code[[1]],
                 ifelse(nchar(ex$pharma_hts_code[[1]]) == 8, '00', ''))
uk_rule <- ex$country_rules %>% filter(country == '4120', condition == 'full') %>% slice(1)
uk_code <- paste0(uk_rule$hts_code, ifelse(nchar(uk_rule$hts_code) == 8, '00', ''))
patent <- ex$patented_pharma_hts10[[1]]
fixture <- tibble(
  id = c('china', 'germany_low', 'germany_high', 'india', 'common_full',
         'aircraft', 'pharma', 'uk_specific', 's232', 'patented_pharma'),
  hts10 = c(plain, plain, plain, plain, common_full, air, pharma, uk_code,
            plain, patent),
  country = c('5700', '4280', '4280', '5330', '5700', '5700', '5700',
              '4120', '5700', '5700'),
  base_rate = c(.05, .03, .12, .05, rep(.05, 6)),
  rate_232 = c(rep(0, 8), .50, 0),
  statutory_rate_232 = c(rep(0, 8), .50, 0),
  s232_annex = NA_character_,
  heading_program = FALSE
)
calc <- apply_section301_forced_labor(
  fixture, do.call(authority_spec_set, list(spec_on)), countries)
got <- setNames(calc$rate_s301fl, calc$id)
ok(isTRUE(all.equal(unname(got['china']), .125)), 'China flat surcharge = 12.5%')
ok(isTRUE(all.equal(unname(got['germany_low']), .07)), 'EU cap = 10% minus 3% MFN')
ok(isTRUE(all.equal(unname(got['germany_high']), 0)), 'EU cap is zero when MFN >= 10%')
ok(isTRUE(all.equal(unname(got['india']), .10)), 'India flat surcharge = 10%')
ok(got['common_full'] == 0, 'common full exemption zeroes duty')
ok(isTRUE(all.equal(unname(got['aircraft']), .0125)), 'aircraft-use proxy retains 10% of 12.5%')
ok(isTRUE(all.equal(unname(got['pharma']), .0625)), 'pharma-use proxy retains 50% of 12.5%')
ok(got['uk_specific'] == 0, 'country-specific UK exemption zeroes duty')
ok(got['s232'] == 0, 'Section 232 scope is fully excluded')
ok(got['patented_pharma'] == 0, 'patented pharma excluded after 2026-07-31')

cat('\n== stacking policy invariant (baseline still matches default) ==\n')
specs_base <- tryCatch(NULL, error = function(e) NULL)
# Minimal baseline-shaped spec set WITHOUT the forced-labor authority:
make_min <- function(auth, cls) authority_spec(authority = auth,
  stacking = list(class = cls, exceptions = list()), programs = list())
base_specs <- do.call(authority_spec_set, list(
  make_min('section_232','primary_metal'), make_min('ieepa_reciprocal','content_split'),
  make_min('ieepa_fentanyl','content_split'), make_min('section_301','additive'),
  make_min('section_122','content_split'), make_min('section_201','additive'),
  make_min('other','additive')))
# fentanyl China exception to match default's additive_countries
base_specs$ieepa_fentanyl$stacking$exceptions <- setNames(list('additive'), '5700')
pol <- stacking_policy_from_specs(base_specs, '5700')
ok('rate_s301fl' %in% names(pol), 'policy includes rate_s301fl')
ok(identical(pol$rate_s301fl, list(net = 'net_s301fl', class = 'additive')),
   'rate_s301fl entry = additive (explicit §232 mask handles non-stacking carve-out)')
ok(identical(pol, default_stacking_policy('5700')), 'baseline policy_from_specs == default_stacking_policy')

cat('\n== SUMMARY:', pass, 'passed,', fail, 'failed ==\n')
if (fail > 0) quit(status = 1)
