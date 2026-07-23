# =============================================================================
# test_forced_labor_scenario.R — scenario harness + forced-labor §301 authority
# =============================================================================
# Lightweight unit tests (no full build): the deep-merge overlay loader, the
# scenario-overlay resolution, the section_301_forced_labor adapter helpers
# (date-gate + two-tier + Annex A), and the stacking-policy invariant. Run:
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

cat('\n== scenario overlay load ==\n')
pp_base <- load_policy_params()
pp_fl   <- load_policy_params(scenario = 'forced_labor')
pp_new  <- load_policy_params(scenario = 'new_301')
ok(is.null(pp_base$section_301_forced_labor), 'baseline: NO section_301_forced_labor block')
ok(!is.null(pp_fl$section_301_forced_labor), 'forced_labor: block present after overlay merge')
ok(identical(as.character(pp_fl$section_301_forced_labor$effective_date), '2026-07-24'),
   'forced_labor: effective_date 2026-07-24')
ok('2026-07-24' %in% as.character(pp_fl$BOUNDARY_OVERRIDES), 'forced_labor: boundary_overrides has the forced-labor turn-on')
# The overlay no longer copies baseline boundaries; it inherits the canonical list.
ok(identical(pp_fl$boundary_overrides, pp_base$boundary_overrides),
   'forced_labor: inherits canonical baseline boundaries without copying them')
ok('2026-09-29' %in% as.character(pp_fl$BOUNDARY_OVERRIDES), 'forced_labor: inherits baseline pharma turn-on (2026-09-29)')
ok('2026-09-29' %in% as.character(pp_base$BOUNDARY_OVERRIDES), 'baseline: pharma turn-on is a boundary_override')
ok(length(pp_base$scheduled_activations) == 0, 'baseline: no scheduled_activations (pharma date-gated, not op-activated)')
ok(identical(pp_new, pp_fl), 'new_301 inherits the forced_labor overlay exactly')

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

cat('\n== two-tier by_country ==\n')
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
ok(length(bc) == 86, 'exactly 86 covered census codes (40 + 46)')
ok(!('9999' %in% names(bc)), 'unknown census code excluded')

cat('\n== adapter: build + date-gate ==\n')
spec_on  <- .build_section_301_forced_labor(pp_fl, countries, as.Date('2026-08-01'))
spec_off <- .build_section_301_forced_labor(pp_fl, countries, as.Date('2026-06-01'))
spec_base <- .build_section_301_forced_labor(pp_base, countries, as.Date('2026-08-01'))
ok(is.null(spec_base), 'baseline pp (no block) -> NULL authority')
ok(!is.null(spec_on) && spec_on$authority == 'section_301_forced_labor', 'scenario -> authority built')
ok(identical(spec_on$stacking$class, 'content_split'), 'stacking class = content_split')
ok(identical(spec_on$usmca_treatment, 'eligible'), 'usmca_treatment = eligible')
bc_on <- spec_on$programs[[1]]$rate$by_country
ok(!is.null(bc_on) && length(bc_on) == 86, 'on-date: by_country populated (86)')
bc_off <- .rate_get(spec_off$programs[[1]]$rate, 'by_country')
ok(is.null(bc_off) || length(bc_off) == 0, 'pre-turn-on date: by_country empty (date-gate)')
ex <- spec_on$programs[[1]]$exempt_products$hts8
ok(length(ex) > 1000, paste0('Annex A loaded (', length(ex), ' hts8)'))
ok(validate_spec_set(do.call(authority_spec_set, list(spec_on))) %||% TRUE, 'spec validates')

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
ok(identical(pol$rate_s301fl, list(net = 'net_s301fl', class = 'content_split')),
   'rate_s301fl entry = content_split (matches default)')
ok(identical(pol, default_stacking_policy('5700')), 'baseline policy_from_specs == default_stacking_policy')

cat('\n== SUMMARY:', pass, 'passed,', fail, 'failed ==\n')
if (fail > 0) quit(status = 1)
