# =============================================================================
# authority_spec datatype unit tests
# =============================================================================
# Pure-logic checks for src/model/authority_spec.R — constructors, validation
# (fail-loud rules), set bundling, serialization round-trip. No model data.
#
# Usage (via Slurm): Rscript tests/test_authority_spec.R
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

cat('--- constructors ---\n')
steel <- authority_program(
  id = 'steel',
  product_scope = list(chapters = c('72', '73')),
  country_scope = list(include = 'all', exclude = list()),
  rate = list(default = 0.50, overrides = list('4120' = 0.25)),
  metal = list(type = 'steel', content = 'full'),
  active = list(from = as.Date('2025-03-12'), until = NA)
)
s232 <- authority_spec(
  authority = 'section_232',
  stacking = list(class = 'primary_metal', exceptions = list()),
  usmca_treatment = 'per_program',
  active = list(from = as.Date('2025-03-12'), until = NA),
  programs = list(steel)
)
check(is_authority_spec(s232), 'authority_spec constructs')
check(is_authority_program(steel), 'authority_program constructs')
check(length(s232$programs) == 1, 'program attached')

s301 <- authority_spec(
  authority = 'section_301',
  stacking = list(class = 'additive'),
  usmca_treatment = 'none',
  programs = list(authority_program(
    id = 's301',
    product_scope = list(list_file = 'resources/s301_product_lists.csv'),
    country_scope = list(include = c('5700')),
    rate = list(by_product_tier = 'from_list')))
)

cat('\n--- spec set bundling ---\n')
specs <- authority_spec_set(s232, s301)
check(is_authority_spec_set(specs), 'spec set constructs')
check(identical(sort(names(specs)), c('section_232', 'section_301')), 'set keyed by authority')

cat('\n--- validation: happy path ---\n')
check(isTRUE(validate_spec_set(specs)), 'valid set passes')

cat('\n--- validation: fail-loud rules ---\n')
expect_error(
  validate_authority_spec(authority_spec('section_232',
    stacking = list(class = 'primary_metal'),
    programs = list(authority_program('bad', metal = list(type = 'none'))))),
  'primary_metal without a real metal.type is rejected')

expect_error(
  validate_authority_spec(authority_spec('x', stacking = list(class = 'nonsense'))),
  'invalid stacking.class is rejected')

expect_error(
  validate_authority_spec(authority_spec('x', usmca_treatment = 'maybe')),
  'invalid usmca_treatment is rejected')

expect_error(
  validate_spec_set(authority_spec_set(authority_spec('section_301',
    stacking = list(class = 'additive'),
    programs = list(authority_program('dup'), authority_program('dup'))))),
  'duplicate program ids are rejected')

cat('\n--- per-program stacking override is honoured by validation ---\n')
mixed <- authority_spec('section_232',
  stacking = list(class = 'primary_metal'),
  programs = list(authority_program('autos',
    stacking = list(class = 'primary_full'),   # override; needs no metal.type
    metal = list(type = 'none'),
    rate = list(default = 0.25))))
check(isTRUE(validate_authority_spec(mixed)), 'primary_full program with metal.type=none is valid')

cat('\n--- resolve_country_scope ---\n')
all_c <- c('5700', '1220', '2010', '5520')
check(identical(resolve_country_scope(list(include = '5700'), all_c), '5700'),
      'include single code')
check(identical(resolve_country_scope(list(include = c('5700', '5520')), all_c), c('5700', '5520')),
      'include code list')
check(setequal(resolve_country_scope(list(include = 'all'), all_c), all_c),
      'include all = full universe')
check(setequal(resolve_country_scope(list(include = 'all', exclude = '1220'), all_c),
               c('5700', '2010', '5520')),
      'all except exclude (the Section 201 / Canada shape)')
check(identical(resolve_country_scope(list(include = '5700', exclude = list()), all_c), '5700'),
      'empty exclude is a no-op')

cat('\n--- serialization round-trip (must survive RDS / future workers) ---\n')
tmp <- tempfile(fileext = '.rds')
saveRDS(specs, tmp)
specs2 <- readRDS(tmp)
check(is_authority_spec_set(specs2), 'spec set survives saveRDS/readRDS')
check(identical(names(specs), names(specs2)), 'authority names preserved')
check(isTRUE(validate_spec_set(specs2)), 'round-tripped set still validates')

cat(sprintf('\nALL %d AUTHORITY_SPEC ASSERTIONS PASSED\n', pass))
