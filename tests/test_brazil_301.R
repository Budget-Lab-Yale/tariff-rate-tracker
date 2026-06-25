# =============================================================================
# Brazil §301 unit checks — .build_section_301_brazil (src/model/authority_adapter.R)
# =============================================================================
# Pure-logic: exercises the new scenario authority builder in isolation (no build
# data, no full adapter scaffold). Mirrors the date-gating + content_split + usmca
# 'none' contract documented on the builder. Usage: Rscript tests/test_brazil_301.R
# See plan + memory [[brazil-301-new301-scenario]].
# =============================================================================

suppressPackageStartupMessages(library(here))
source(here('src', 'model', 'authority_spec.R'))
source(here('src', 'model', 'authority_adapter.R'))

pass <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:', msg, '\n')
}

countries <- c('5700', '1220', '2010', '3510')   # incl. Brazil (3510)
cfg <- list(effective_date = '2026-07-24', rate = 0.25, country = '3510',
            # deliberately-missing file -> .resolve_s301fl_exempt returns character(0)
            exempt_products = 'resources/__nonexistent_brazil_annex__.csv')
pp_on <- list(section_301_brazil = cfg)

cat('--- baseline: no config block -> NULL (authority absent) ---\n')
check(is.null(.build_section_301_brazil(list(), countries, as.Date('2026-08-01'))),
      'absent section_301_brazil block -> NULL (baseline untouched)')

cat('--- post-turn-on (2026-08-01 >= 2026-07-24): live ---\n')
spec_on <- .build_section_301_brazil(pp_on, countries, as.Date('2026-08-01'))
check(!is.null(spec_on), 'post-07-24: spec built')
check(identical(spec_on$authority, 'section_301_brazil'), "authority = 'section_301_brazil'")
check(identical(spec_on$stacking$class, 'content_split'), 'stacking class = content_split')
check(identical(spec_on$usmca_treatment, 'none'), "usmca_treatment = 'none' (Brazil not USMCA)")
bc <- spec_on$programs[[1]]$rate$by_country
check(isTRUE(all.equal(unname(bc['3510']), 0.25)), 'rate$by_country[3510] = 0.25')
check(length(bc) == 1, 'exactly one in-scope country (Brazil)')
check(identical(spec_on$programs[[1]]$country_scope$include, '3510'), 'country_scope include = 3510')
check(is_authority_spec(spec_on), 'is a valid authority_spec object')

cat('--- pre-turn-on (2026-07-01 < 2026-07-24): date-gated HOLLOW, not NULL ---\n')
spec_pre <- .build_section_301_brazil(pp_on, countries, as.Date('2026-07-01'))
check(!is.null(spec_pre), 'pre-07-24: spec still built (hollow, not NULL)')
bc_pre <- spec_pre$programs[[1]]$rate$by_country
check(is.null(bc_pre) || length(bc_pre) == 0, 'pre-07-24: rate$by_country hollow')
check(length(spec_pre$programs[[1]]$country_scope$include) == 0, 'pre-07-24: empty country_scope')

cat(sprintf('\n>>> Brazil §301 builder: PASS %d checks\n', pass))
