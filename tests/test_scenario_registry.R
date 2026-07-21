# =============================================================================
# Tests: Scenario registry + alternatives unification
# =============================================================================
#
# Covers:
#   1. list_scenarios() — registry completeness, kinds, meta validation
#   2. resolve_alternatives_selector() — selector expansion + fail-loud
#   3. Migration parity — each config/scenarios/<name>/overlay.yaml produces
#      the same effective policy_params as the historical pp_override closure
#      in build_rebuild_alt_registry() (delete that function + section 3 here
#      once the cluster golden diff passes; see todo.md Phase 4 Step 5)
#   4. apply_authority_disables() — the counterfactual kill-switch
#   5. Counterfactual overlays — disabled_authorities round-trips through
#      load_policy_params(scenario = ...) and validates against authority_columns
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
source(here('src', 'pipeline', '09_daily_series.R'))

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
COUNTERFACTUALS <- c('no_232', 'no_301', 'no_ieepa', 'no_ieepa_recip',
                     'no_s122', 'no_s338', 'pre_2025')

# =============================================================================
# 1. Registry
# =============================================================================
message('\n--- list_scenarios() ---')

registry <- list_scenarios()

run_test('registry contains all 7 alternatives', {
  stopifnot(all(ALTERNATIVES %in% registry$name[registry$kind == 'alternative']))
})

run_test('registry contains all 6 counterfactuals', {
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

# =============================================================================
# 2. Selector
# =============================================================================
message('\n--- resolve_alternatives_selector() ---')

run_test("'alternatives' expands to exactly the historical 7-variant set", {
  stopifnot(setequal(resolve_alternatives_selector('alternatives'), ALTERNATIVES))
})

run_test("'rebuild' is an alias for 'alternatives'", {
  stopifnot(setequal(resolve_alternatives_selector('rebuild'), ALTERNATIVES))
})

run_test("'counterfactuals' expands to the 7 counterfactuals", {
  stopifnot(setequal(resolve_alternatives_selector('counterfactuals'), COUNTERFACTUALS))
})

run_test("'all' is alternatives + counterfactuals (14)", {
  got <- resolve_alternatives_selector('all')
  stopifnot(setequal(got, c(ALTERNATIVES, COUNTERFACTUALS)))
})

run_test('comma-list selects by name, deduplicated', {
  got <- resolve_alternatives_selector('metal_flat, usmca_2024,metal_flat')
  stopifnot(setequal(got, c('metal_flat', 'usmca_2024')))
})

run_test('NULL / none resolve to empty', {
  stopifnot(
    length(resolve_alternatives_selector(NULL)) == 0,
    length(resolve_alternatives_selector('none')) == 0
  )
})

run_test('unknown name fails loud', {
  expect_error(resolve_alternatives_selector('not_a_scenario'), 'unknown scenario')
})

run_test('kind=scenario names are rejected with the TARIFF_SCENARIO pointer', {
  expect_error(resolve_alternatives_selector('forced_labor'), 'TARIFF_SCENARIO')
})

# =============================================================================
# 3. Migration parity: overlay-built pp == historical closure pp
# =============================================================================
message('\n--- migration parity (overlay vs build_rebuild_alt_registry) ---')

pp_base <- load_policy_params()
legacy <- build_rebuild_alt_registry(pp_base)
legacy_by_name <- setNames(legacy, vapply(legacy, `[[`, character(1), 'variant'))

# Raw config keys the overlays legitimately rewrite but the legacy closures
# left at baseline (closures edited the unpacked convenience fields instead).
# Effective behavior flows through the unpacked fields, compared separately.
RAW_KEYS_REWRITTEN <- c('usmca_shares')

strip_keys <- function(pp, keys) { pp[setdiff(names(pp), keys)] }

# Compare two lists field-by-field over the union of their names. Treats an
# ABSENT field and a present-but-NULL field as equal (both read as NULL via $
# and %||%, which is how every consumer accesses them), and integer/double
# scalars of equal value as equal (yaml parses `year: 2025` as 2025L where the
# legacy closures assigned the double 2025; consumers paste/derive from it, and
# the integer is the safer typing for the loader's sprintf('%d', ...)).
fields_equivalent <- function(a, b) {
  for (f in union(names(a), names(b))) {
    av <- a[[f]]; bv <- b[[f]]
    same <- identical(av, bv) ||
      (is.numeric(av) && is.numeric(bv) &&
         identical(as.numeric(av), as.numeric(bv)))
    if (!same) {
      stop('field mismatch: ', f,
           ' (legacy: ', paste(deparse(av), collapse = ' '),
           ' vs overlay: ', paste(deparse(bv), collapse = ' '), ')')
    }
  }
  invisible(TRUE)
}

for (variant in names(legacy_by_name)) {
  run_test(paste0('parity: ', variant), {
    pp_old <- legacy_by_name[[variant]]$pp_override
    pp_new <- load_policy_params(scenario = variant)

    # Effective USMCA settings must match field-by-field
    fields_equivalent(pp_old$USMCA_SHARES, pp_new$USMCA_SHARES)

    # Everything else must be identical apart from the rewritten raw keys
    rest_old <- strip_keys(pp_old, c(RAW_KEYS_REWRITTEN, 'USMCA_SHARES'))
    rest_new <- strip_keys(pp_new, c(RAW_KEYS_REWRITTEN, 'USMCA_SHARES'))
    stopifnot('non-USMCA params differ' = identical(rest_old, rest_new))
  })
}

run_test('parity: registry covers every legacy variant (none orphaned)', {
  stopifnot(setequal(names(legacy_by_name), ALTERNATIVES))
})

# =============================================================================
# 4. apply_authority_disables()
# =============================================================================
message('\n--- apply_authority_disables() ---')

auth_cols <- pp_base$AUTHORITY_COLUMNS

fixture <- tibble(
  hts10 = c('0101210010', '8471500100'),
  country = c('5700', '1220'),
  rate_232 = c(0.25, 0.50),
  rate_301 = c(0.25, 0),
  rate_301_cs = c(0, 0),
  rate_ieepa_recip = c(0.10, 0.10),
  rate_ieepa_fent = c(0.20, 0),
  rate_s122 = c(0.10, 0.10),
  rate_other = c(0, 0)
)

run_test('empty / NULL disabled is a no-op (baseline invariant)', {
  stopifnot(
    identical(apply_authority_disables(fixture, NULL, auth_cols), fixture),
    identical(apply_authority_disables(fixture, character(0), auth_cols), fixture)
  )
})

run_test('single authority zeroes exactly its column', {
  out <- apply_authority_disables(fixture, 'section_301', auth_cols)
  stopifnot(
    all(out$rate_301 == 0),
    identical(out$rate_232, fixture$rate_232),
    identical(out$rate_ieepa_recip, fixture$rate_ieepa_recip),
    identical(out$rate_s122, fixture$rate_s122)
  )
})

run_test('multi-authority (pre_2025 set) zeroes all three columns', {
  out <- apply_authority_disables(
    fixture, c('ieepa_reciprocal', 'ieepa_fentanyl', 'section_122'), auth_cols)
  stopifnot(
    all(out$rate_ieepa_recip == 0),
    all(out$rate_ieepa_fent == 0),
    all(out$rate_s122 == 0),
    identical(out$rate_232, fixture$rate_232),
    identical(out$rate_301, fixture$rate_301)
  )
})

run_test('unknown authority name fails loud', {
  expect_error(apply_authority_disables(fixture, 'section_999', auth_cols),
               'unknown authority')
})

run_test('mapped column missing from rates fails loud', {
  expect_error(
    apply_authority_disables(fixture %>% select(-rate_s122), 'section_122', auth_cols),
    'missing from rates')
})

# =============================================================================
# 5. Counterfactual overlays round-trip through load_policy_params()
# =============================================================================
message('\n--- counterfactual overlays ---')

expected_disables <- list(
  no_ieepa = c('ieepa_reciprocal', 'ieepa_fentanyl'),
  no_ieepa_recip = 'ieepa_reciprocal',
  no_301 = 'section_301',
  no_232 = 'section_232',
  no_s122 = 'section_122',
  # section_338 (2026-08-19 Canada +50%) and section_301_brazil (2026-07-22
  # Brazil 25%, FR 2026-14542) are baseline authorities added after the legacy
  # engine, so a "pre-2025 only" counterfactual must disable them too.
  pre_2025 = c('ieepa_reciprocal', 'ieepa_fentanyl', 'section_122', 'section_338',
               'section_301_brazil')
)

for (nm in names(expected_disables)) {
  run_test(paste0('overlay ', nm, ': disabled_authorities matches the legacy definition'), {
    pp <- load_policy_params(scenario = nm)
    got <- unlist(pp$disabled_authorities)
    stopifnot(
      setequal(got, expected_disables[[nm]]),
      all(got %in% names(pp$AUTHORITY_COLUMNS))
    )
  })
}

run_test('baseline has no disabled_authorities (kill-switch is overlay-only)', {
  stopifnot(is.null(pp_base$disabled_authorities))
})

run_test('counterfactual pp differs from baseline ONLY in disabled_authorities', {
  pp_cf <- load_policy_params(scenario = 'no_301')
  stopifnot(identical(strip_keys(pp_cf, 'disabled_authorities'), pp_base))
})

# =============================================================================
# 6. sgept_exemptions scenario (2026-06-10): SGEPT-calibrated §232 annex knobs
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
