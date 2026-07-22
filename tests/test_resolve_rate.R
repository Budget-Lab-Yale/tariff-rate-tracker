# =============================================================================
# resolve_rate / apply_rate_semantics / validate_rate unit tests (Plank 0)
# =============================================================================
# Pure-logic checks for the compositional rate schema in src/model/authority_spec.R:
# the layer-precedence reader (resolve_rate), the rate_type semantics
# (apply_rate_semantics, incl. both floor modes), and rate validation. No model
# data, no calculator, no parity recompute — Plank 0 is parity-trivial by
# construction (the calculator still reads rate$resolved).
#
# Usage (via Slurm): Rscript tests/test_resolve_rate.R
# =============================================================================

suppressPackageStartupMessages(library(here))
source(here('src', 'model', 'authority_spec.R'))

pass <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:', msg, '\n')
}
expect_error <- function(expr, msg) {
  err <- tryCatch({ force(expr); NULL }, error = function(e) conditionMessage(e))
  if (is.null(err)) stop('FAILED (expected error): ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok (errored):', msg, '\n')
}

# ---------------------------------------------------------------------------
cat('--- resolve_rate: precedence (most-specific wins) ---\n')

# A rate carrying every layer at once, so each test isolates one tier by
# choosing a (product, country) that the more-specific layers miss.
full <- list(
  overrides = list(
    list(products = 'P_OV',   countries = '5700', rate = 0.99),  # entry: product×country
    list(products = 'P_OVALL',                    rate = 0.88),  # entry: product, any country
    list(products = 'P_TIER', countries = '5700', rate = 0.95),  # entry: also in tier -> precedence
    P_NAMED = 0.77                                               # named-scalar form
  ),
  by_product_tier = c(P_TIER = 0.25, P_TIER2 = 0.075),
  by_country      = c(`5700` = 0.50, `5520` = 0.30),
  default_unlisted_rate = 0.10,
  default       = 0.02,
  target_total  = 0.01
)

check(resolve_rate(full, 'P_OV', '5700')$matched == 'overrides',
      'overrides (product×country) wins over everything')
check(resolve_rate(full, 'P_OV', '5700')$value == 0.99, 'overrides returns its rate')
check(resolve_rate(full, 'P_OVALL', '9999')$matched == 'overrides',
      'override with no countries applies to any country')
check(resolve_rate(full, 'P_NAMED', '9999')$matched == 'overrides',
      'named-scalar override form resolves (any country)')
check(resolve_rate(full, 'P_NAMED', '9999')$value == 0.77, 'named-scalar override returns its rate')
check(resolve_rate(full, 'P_TIER', '5700')$matched == 'overrides',
      'product×country override still beats a by_product_tier hit')
check(resolve_rate(full, 'P_TIER', '5700')$value == 0.95, 'the winning override (not the tier) rate is returned')
check(resolve_rate(full, 'P_TIER', '9999')$matched == 'by_product_tier',
      'by_product_tier wins when the override country misses')
check(resolve_rate(full, 'P_TIER', '9999')$value == 0.25, 'by_product_tier returns tier rate')
check(resolve_rate(full, 'P_NONE', '5700')$matched == 'by_country',
      'by_country wins when product not in tier/overrides')
check(resolve_rate(full, 'P_NONE', '5700')$value == 0.50, 'by_country returns country rate')
check(resolve_rate(full, 'P_NONE', '9999')$matched == 'default_unlisted',
      'default_unlisted is the by_country complement (unlisted country)')
check(resolve_rate(full, 'P_NONE', '9999')$value == 0.10, 'default_unlisted returns its rate')

# default beats target_total; both are flat fallbacks
d_only <- list(default = 0.02, target_total = 0.01)
check(resolve_rate(d_only, 'X', 'Y')$matched == 'default', 'default beats target_total')
tt_only <- list(target_total = 0.50, rate_type = 'floor_post_mfn')
check(resolve_rate(tt_only, 'X', 'Y')$matched == 'target_total',
      'target_total is the final fallback (Annex-3 floor shape)')
check(resolve_rate(tt_only, 'X', 'Y')$value == 0.50, 'target_total returns its value')

# default_unlisted requires by_country to be present (it is its complement).
# REGRESSION: R's `$`/`[[` partial-match, so rate$default would silently pick up
# `default_unlisted_rate` when no `default` exists. Must resolve to 'none', not
# 'default'. Keep this — it guards the exact-access (.rate_get) fix.
du_no_bc <- list(default_unlisted_rate = 0.10)
check(resolve_rate(du_no_bc, 'X', 'Y')$matched == 'none',
      'default_unlisted alone (no by_country, no default) -> none, NOT a partial-match to default')

check(resolve_rate(list(), 'X', 'Y')$matched == 'none', 'empty rate -> none')
check(is.na(resolve_rate(list(), 'X', 'Y')$value), 'none -> NA value')
check(resolve_rate(NULL, 'X', 'Y')$matched == 'none', 'NULL rate -> none')

# default_unlisted alias
alias <- list(by_country = c(`5700` = 0.5), default_unlisted = 0.10)
check(resolve_rate(alias, 'P', '9999')$value == 0.10,
      'default_unlisted (alias of default_unlisted_rate) resolves')

# ---------------------------------------------------------------------------
cat('--- resolve_rate: rate_type + floor_base in the descriptor ---\n')

check(resolve_rate(list(default = 0.1))$rate_type == 'surcharge',
      'rate_type defaults to surcharge')
check(is.na(resolve_rate(list(default = 0.1))$floor_base),
      'surcharge has no floor_base')
check(resolve_rate(list(default = 0.1, rate_type = 'floor_static'))$floor_base == 'original',
      'floor_static -> floor_base original')
check(resolve_rate(list(default = 0.1, rate_type = 'floor_post_mfn'))$floor_base == 'post_mfn',
      'floor_post_mfn -> floor_base post_mfn')
check(is.na(resolve_rate(list(default = 0.1, rate_type = 'passthrough'))$floor_base),
      'passthrough has no floor_base')
expect_error(resolve_rate(list(default = 0.1, rate_type = 'bogus')),
             'resolve_rate rejects unknown rate_type')

# ---------------------------------------------------------------------------
cat('--- apply_rate_semantics: the four modes ---\n')

check(apply_rate_semantics(0.25, 'surcharge') == 0.25, 'surcharge returns the value')
check(apply_rate_semantics(0.25, 'passthrough') == 0, 'passthrough returns 0')
check(apply_rate_semantics(NA_real_, 'surcharge') == 0, 'NA value -> 0 (nothing in scope)')

# floor: pmax(0, value - base); same math both modes, differ only by the base
check(apply_rate_semantics(0.50, 'floor_static', base = 0.10) == 0.40,
      'floor_static = pmax(0, value - base) (deal floor vs original base)')
check(apply_rate_semantics(0.50, 'floor_post_mfn', base = 0.10) == 0.40,
      'floor_post_mfn = pmax(0, value - base) (recip floor vs post-MFN base)')
check(apply_rate_semantics(0.10, 'floor_static', base = 0.30) == 0,
      'floor clamps at 0 when base exceeds value')
check(apply_rate_semantics(NA_real_, 'floor_static', base = 0.10) == 0,
      'NA value under a floor -> 0')
expect_error(apply_rate_semantics(0.50, 'floor_post_mfn'),
             'floor mode without a base errors')
expect_error(apply_rate_semantics(0.50, 'bogus'),
             'apply_rate_semantics rejects unknown rate_type')

# vectorized
check(identical(apply_rate_semantics(c(0.5, 0.2), 'floor_static', base = c(0.1, 0.3)),
                c(0.4, 0.0)),
      'apply_rate_semantics is vectorized over value/base')

# round-trip resolve -> apply for a deal-floor override
dealr <- list(overrides = list(list(products = 'AUTO', countries = '4120', rate = 0.15)),
              rate_type = 'floor_static')
rr <- resolve_rate(dealr, 'AUTO', '4120')
check(rr$floor_base == 'original', 'deal floor descriptor says original base')
check(apply_rate_semantics(rr$value, rr$rate_type, base = 0.025) == 0.125,
      'resolve->apply: 15% deal floor vs 2.5% original base -> 12.5% additional')

# ---------------------------------------------------------------------------
cat('--- validate_rate: structured shapes ---\n')

check(isTRUE(validate_rate(list(), 'x/y')), 'empty rate validates')
check(isTRUE(validate_rate(NULL, 'x/y')), 'NULL rate validates')
check(isTRUE(validate_rate(full, 'test/full')), 'fully-populated real rate validates')

# product_overrides_file (a path string) is allowed and not numeric-checked
check(isTRUE(validate_rate(list(product_overrides_file = 'resources/x.csv'), 'a/b')),
      'product_overrides_file path validates')
# the existing test_authority_spec.R happy-path shape: overrides as a named map
check(isTRUE(validate_rate(list(default = 0.50, overrides = list('4120' = 0.25)), 's232/steel')),
      'named-scalar overrides map validates (the existing spec-test shape)')

# Plank 4a/S2 deals: scope-form overrides (a product scope LABEL, no enumerated products) +
# the floors layer validate; both are reader-invisible (the calc reads them, not resolve_rate).
check(isTRUE(validate_rate(list(default = 0.25,
        overrides = list(list(scope = 'vehicles', countries = c('4120'), rate = 0.075))), 's232/autos')),
      'scope-form override {scope, countries, rate} validates (S2 deals)')
check(isTRUE(validate_rate(list(default = 0.25,
        floors = list(list(scope = 'vehicles', countries = c('4280'), floor = 0.15))), 's232/autos')),
      'floors layer {scope, countries, floor} validates (S2 deals)')
check(identical(resolve_rate(list(default = 0.25,
        overrides = list(list(scope = 'vehicles', countries = '4120', rate = 0.075))),
        product = '8703', country = '4120')$value, 0.25),
      'scope-form override is reader-invisible: resolve_rate returns default(0.25), not the deal rate')

cat('--- validate_rate: fail-loud on malformed real layers ---\n')

expect_error(validate_rate(list(rate_type = 'bogus'), 'a/b'),
             'invalid rate_type rejected')
expect_error(validate_rate(list(wat = 1), 'a/b'),
             'unknown rate field rejected (catches typos)')
expect_error(validate_rate(list(resolved = list(a = 1)), 'a/b'),
             'legacy resolved payload rejected')
expect_error(validate_rate(list(default = 'from_raw'), 'a/b'),
             'legacy sentinel rate rejected')
expect_error(validate_rate(list(default = 'oops'), 'a/b'),
             'non-sentinel string in a numeric field rejected')
expect_error(validate_rate(list(default = c(0.1, 0.2)), 'a/b'),
             'non-scalar default rejected')
expect_error(validate_rate(list(default = -0.1), 'a/b'),
             'negative rate rejected')
expect_error(validate_rate(list(by_country = c(0.1, 0.2)), 'a/b'),
             'unnamed by_country rejected')
expect_error(validate_rate(list(by_country = c(`5700` = NA_real_)), 'a/b'),
             'NA by_country value rejected')
expect_error(validate_rate(list(overrides = list(list(products = 'P'))), 'a/b'),
             'override entry missing rate rejected')
expect_error(validate_rate(list(overrides = list(list(rate = 0.1))), 'a/b'),
             'override entry missing products rejected')
expect_error(validate_rate(list(overrides = list(0.25)), 'a/b'),
             'unnamed scalar override rejected (needs a product-code name)')
expect_error(validate_rate(list(overrides = list(list(rate = 0.1))), 'a/b'),
             'override entry with neither products nor scope rejected (S2)')
expect_error(validate_rate(list(floors = list(list(scope = 'v', countries = '1', floor = -0.1))), 'a/b'),
             'floors entry with negative floor rejected (S2)')
expect_error(validate_rate(list(floors = list(list(countries = '1', floor = 0.15))), 'a/b'),
             'floors entry with no scope rejected (S2)')
expect_error(validate_rate(list(floors = list(list(scope = 'v', countries = '1'))), 'a/b'),
             'floors entry with no floor rejected (S2)')
expect_error(validate_rate('not a list', 'a/b'),
             'non-list rate rejected')

# ---------------------------------------------------------------------------
cat('--- validate_authority_spec wires in validate_rate ---\n')

good_spec <- authority_spec(
  authority = 'section_301', stacking = list(class = 'additive'),
  programs = list(authority_program(id = 's301',
                  rate = list(by_product_tier = c(P = 0.25), rate_type = 'surcharge'))))
check(isTRUE(validate_authority_spec(good_spec)), 'spec with a real rate validates')

bad_spec <- authority_spec(
  authority = 'section_301', stacking = list(class = 'additive'),
  programs = list(authority_program(id = 's301',
                  rate = list(rate_type = 'not_a_type'))))
expect_error(validate_authority_spec(bad_spec),
             'validate_authority_spec rejects a bad rate via validate_rate')

cat(sprintf('\nALL %d RESOLVE_RATE ASSERTIONS PASSED\n', pass))
