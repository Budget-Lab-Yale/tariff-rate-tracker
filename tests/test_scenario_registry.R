# =============================================================================
# Tests: Scenario registry + alternatives unification
# =============================================================================
#
# Covers:
#   1. list_scenarios() — registry completeness, kinds, meta validation
#   2. resolve_alternatives_selector() — selector expansion + fail-loud
#   3. apply_counterfactual_inputs() — pre-calculation authority removal
#   4. Counterfactual overlays — disabled_authorities round-trips through
#      load_policy_params(scenario = ...)
#
# Usage:
#   Rscript tests/test_scenario_registry.R
#
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
  library(yaml)
})
source(here('src', 'core', 'helpers.R'))

pass_count <- 0
fail_count <- 0

run_test <- function(name, expr) {
  tryCatch({
    force(expr)
    message('  PASS: ', name)
    pass_count <<- pass_count + 1
  }, error = function(e) {
    message('  FAIL: ', name, ' — ', conditionMessage(e))
    fail_count <<- fail_count + 1
  })
}

expect_error <- function(expr, pattern = NULL) {
  err <- tryCatch({ force(expr); NULL }, error = function(e) e)
  stopifnot('expected an error but none was thrown' = !is.null(err))
  if (!is.null(pattern)) {
    stopifnot('error message does not match expected pattern' =
                grepl(pattern, conditionMessage(err)))
  }
  invisible(TRUE)
}

ALTERNATIVES <- c('dutyfree_nonzero', 'metal_flat', 'subdivision_r_mid',
                  'usmca_2024', 'usmca_annual', 'usmca_dec2025', 'usmca_monthly')
COUNTERFACTUALS <- c('no_232', 'no_301', 'no_fl_301', 'no_fl_301_keep_s122',
                     'no_ieepa', 'no_ieepa_recip', 'no_s122', 'no_s338', 'pre_2025')

# =============================================================================
# 1. Registry
# =============================================================================
message('\n--- list_scenarios() ---')

registry <- list_scenarios()

run_test('registry contains all 7 alternatives', {
  stopifnot(all(ALTERNATIVES %in% registry$name[registry$kind == 'alternative']))
})

run_test('registry contains all 9 counterfactuals', {
  stopifnot(all(COUNTERFACTUALS %in% registry$name[registry$kind == 'counterfactual']))
})

run_test('forced_labor and new_301 are kind=scenario; actual is baseline', {
  stopifnot(
    registry$kind[registry$name == 'forced_labor'] == 'scenario',
    registry$kind[registry$name == 'new_301'] == 'scenario',
    registry$kind[registry$name == 'actual'] == 'baseline'
  )
})

run_test('every runnable scenario has an overlay', {
  runnable <- registry %>% filter(kind %in% c('alternative', 'counterfactual'))
  stopifnot(all(runnable$has_overlay))
})

run_test('unregistered folder (no meta.yaml) fails loud', {
  d <- tempfile('scenarios_')
  dir.create(file.path(d, 'mystery'), recursive = TRUE)
  expect_error(list_scenarios(d), 'no meta\\.yaml')
})

run_test('invalid kind fails loud', {
  d <- tempfile('scenarios_')
  dir.create(file.path(d, 'badkind'), recursive = TRUE)
  writeLines(c('kind: wat', "description: 'x'", 'publish: false'),
             file.path(d, 'badkind', 'meta.yaml'))
  expect_error(list_scenarios(d), 'kind must be one of')
})

run_test('unknown meta.yaml key fails loud', {
  d <- tempfile('scenarios_')
  dir.create(file.path(d, 'badmeta'), recursive = TRUE)
  writeLines(c('kind: alternative', "description: 'x'", 'publish: false',
               'publsh: true'), file.path(d, 'badmeta', 'meta.yaml'))
  expect_error(list_scenarios(d), 'unknown key.*publsh')
})

run_test('new_301 declares forced_labor inheritance', {
  row <- registry[registry$name == 'new_301', ]
  stopifnot(nrow(row) == 1, row$extends == 'forced_labor')
})

run_test('every tracked scenario overlay resolves against the strict schema', {
  names_to_load <- setdiff(registry$name, 'actual')
  resolved <- lapply(names_to_load, function(nm) {
    suppressMessages(load_policy_params(scenario = nm))
  })
  stopifnot(length(resolved) == length(names_to_load))
})

# =============================================================================
# 2. Selector
# =============================================================================
message('\n--- resolve_alternatives_selector() ---')

run_test("'alternatives' expands to exactly the historical 7-variant set", {
  stopifnot(setequal(resolve_alternatives_selector('alternatives'), ALTERNATIVES))
})

run_test("'counterfactuals' expands to the 9 counterfactuals", {
  stopifnot(setequal(resolve_alternatives_selector('counterfactuals'), COUNTERFACTUALS))
})

run_test("'all' is alternatives + counterfactuals (16)", {
  got <- resolve_alternatives_selector('all')
  stopifnot(setequal(got, c(ALTERNATIVES, COUNTERFACTUALS)))
})

run_test('comma-list selects by name, deduplicated', {
  got <- resolve_alternatives_selector('metal_flat, usmca_2024,metal_flat')
  stopifnot(setequal(got, c('metal_flat', 'usmca_2024')))
})

run_test('NULL resolves to empty', {
  stopifnot(length(resolve_alternatives_selector(NULL)) == 0)
})

run_test('unknown name fails loud', {
  expect_error(resolve_alternatives_selector('not_a_scenario'), 'unknown scenario')
})

run_test('kind=scenario names are rejected with the TARIFF_SCENARIO pointer', {
  expect_error(resolve_alternatives_selector('forced_labor'), 'TARIFF_SCENARIO')
})

pp_base <- load_policy_params()
strip_keys <- function(pp, keys) { pp[setdiff(names(pp), keys)] }

# =============================================================================
# 3. Counterfactuals change parsed inputs before calculation
# =============================================================================
message('\n--- apply_counterfactual_inputs() ---')

ch99_fixture <- tibble(
  ch99_code = c('9903.80.01', '9903.88.15', '9903.03.01',
                '9903.02.09', '9903.01.20', '9903.10.01'),
  authority = c('section_232', 'section_301', 'section_122',
                'ieepa_reciprocal', 'other', 'other'),
  rate = c(.25, .25, .10, .10, .20, .05)
)
ieepa_fixture <- tibble(ch99_code = '9903.02.09', rate = .10)
attr(ieepa_fixture, 'universal_baseline') <- .10
fentanyl_fixture <- tibble(ch99_code = '9903.01.20', rate = .20)

run_test('empty / NULL disabled is a no-op (baseline invariant)', {
  out <- apply_counterfactual_inputs(
    ch99_fixture, ieepa_fixture, fentanyl_fixture, pp_base
  )
  stopifnot(identical(out$ch99_data, ch99_fixture))
  stopifnot(identical(out$ieepa_rates, ieepa_fixture))
  stopifnot(identical(out$fentanyl_rates, fentanyl_fixture))
  stopifnot(length(out$policy_params$SCENARIO_DISABLED_AUTHORITIES_APPLIED) == 0)
})

run_test('no_232 removes §232 inputs but leaves IEEPA and §301 intact', {
  pp <- pp_base; pp$disabled_authorities <- 'section_232'
  out <- apply_counterfactual_inputs(
    ch99_fixture, ieepa_fixture, fentanyl_fixture, pp
  )
  stopifnot(!'9903.80.01' %in% out$ch99_data$ch99_code)
  stopifnot(all(c('9903.88.15', '9903.02.09') %in% out$ch99_data$ch99_code))
  stopifnot(identical(out$ieepa_rates, ieepa_fixture))
  stopifnot(is.null(out$policy_params$S232_ANNEXES))
  stopifnot(identical(out$policy_params$section_232_headings, list()))
})

run_test('no_ieepa removes both extracted inputs and their Ch99 rows', {
  pp <- pp_base
  pp$disabled_authorities <- c('ieepa_reciprocal', 'ieepa_fentanyl')
  out <- apply_counterfactual_inputs(
    ch99_fixture, ieepa_fixture, fentanyl_fixture, pp
  )
  stopifnot(nrow(out$ieepa_rates) == 0, nrow(out$fentanyl_rates) == 0)
  stopifnot(!any(c('9903.02.09', '9903.01.20') %in% out$ch99_data$ch99_code))
  stopifnot('9903.80.01' %in% out$ch99_data$ch99_code)
})

run_test('unknown authority name fails loud', {
  pp <- pp_base; pp$disabled_authorities <- 'section_999'
  expect_error(
    apply_counterfactual_inputs(ch99_fixture, ieepa_fixture, fentanyl_fixture, pp),
    'unsupported authority'
  )
})

run_test('calculator guard rejects a counterfactual that bypasses input removal', {
  pp <- pp_base; pp$disabled_authorities <- 'section_301'
  expect_error(assert_counterfactual_inputs_applied(pp), 'before calculation')
  out <- apply_counterfactual_inputs(
    ch99_fixture, ieepa_fixture, fentanyl_fixture, pp
  )
  stopifnot(isTRUE(assert_counterfactual_inputs_applied(out$policy_params)))
})

# =============================================================================
# 4. Counterfactual overlays round-trip through load_policy_params()
# =============================================================================
message('\n--- counterfactual overlays ---')

expected_disables <- list(
  no_ieepa = c('ieepa_reciprocal', 'ieepa_fentanyl'),
  no_ieepa_recip = 'ieepa_reciprocal',
  # no_301 covers ALL §301 instruments: legacy China + the 2026-07-22 Brazil
  # baseline authority (which would otherwise leak into "remove Section 301").
  no_301 = c('section_301', 'section_301_brazil'),
  no_232 = 'section_232',
  no_s122 = 'section_122',
  # section_338 (2026-08-22 Canada +50%) and section_301_brazil (2026-07-22
  # Brazil 25%, FR 2026-14542) are baseline authorities added after the legacy
  # engine, so a "pre-2025 only" counterfactual must disable them too.
  pre_2025 = c('ieepa_reciprocal', 'ieepa_fentanyl', 'section_122', 'section_338',
               'section_301_brazil')
)

for (nm in names(expected_disables)) {
  run_test(paste0('overlay ', nm, ': disabled_authorities matches its definition'), {
    pp <- load_policy_params(scenario = nm)
    got <- unlist(pp$disabled_authorities)
    stopifnot(
      setequal(got, expected_disables[[nm]]),
      all(got %in% SCENARIO_INPUT_AUTHORITIES)
    )
  })
}

run_test('baseline has no disabled_authorities (input removal is scenario-only)', {
  stopifnot(is.null(pp_base$disabled_authorities))
})

run_test('counterfactual pp differs from baseline ONLY in disabled_authorities', {
  pp_cf <- load_policy_params(scenario = 'no_301')
  stopifnot(identical(strip_keys(pp_cf, 'disabled_authorities'), pp_base))
})

# =============================================================================
# 5. sgept_exemptions scenario (2026-06-10): SGEPT-calibrated §232 annex knobs
# =============================================================================
message('\n--- sgept_exemptions overlay ---')

run_test('sgept_exemptions registered as kind: scenario (not in alternatives selector)', {
  reg <- list_scenarios()
  row <- reg[reg$name == 'sgept_exemptions', ]
  stopifnot(nrow(row) == 1, row$kind == 'scenario')
  stopifnot(!'sgept_exemptions' %in% resolve_alternatives_selector('all'))
})

run_test('sgept_exemptions overlay deep-merges the four SGEPT knobs', {
  pp_sg <- load_policy_params(scenario = 'sgept_exemptions')
  ax <- pp_sg$S232_ANNEXES
  stopifnot(
    isTRUE(all.equal(as.numeric(ax$uk_content_qualifying_share), 0.30)),
    isTRUE(all.equal(as.numeric(ax$exemptions$us_origin_metal$aggregate_share), 0.01)),
    isTRUE(all.equal(as.numeric(ax$exemptions$de_minimis_weight$aggregate_share), 0.02)),
    isTRUE(all.equal(as.numeric(ax$exemptions$motorcycle_parts$aggregate_share), 0.001))
  )
  # Field-wise merge: untouched siblings survive the overlay
  stopifnot(
    isTRUE(all.equal(as.numeric(ax$exemptions$us_origin_metal$rate), 0.10)),
    isTRUE(all.equal(as.numeric(ax$annexes$annex_1a$uk_rate), 0.25))
  )
})

run_test('baseline keeps the new knobs dormant (q = 1.0, shares 0)', {
  ax <- pp_base$S232_ANNEXES
  stopifnot(
    isTRUE(all.equal(as.numeric(ax$uk_content_qualifying_share), 1.0)),
    as.numeric(ax$exemptions$de_minimis_weight$aggregate_share) == 0,
    as.numeric(ax$exemptions$motorcycle_parts$aggregate_share) == 0,
    as.numeric(ax$country_surcharges[[1]]$third_country_content_share) == 0
  )
})

# =============================================================================
# Summary
# =============================================================================
message('\n', strrep('=', 70))
message('Scenario registry tests: ', pass_count, ' passed, ', fail_count, ' failed')
message(strrep('=', 70))
if (fail_count > 0) quit(save = 'no', status = 1)
