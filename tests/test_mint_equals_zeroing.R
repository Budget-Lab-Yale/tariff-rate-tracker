# =============================================================================
# Calendar-owned expiry tests
# =============================================================================

suppressPackageStartupMessages({ library(here); library(dplyr) })
source(here('src', 'core', 'helpers.R'))
source(here('src', 'model', 'authority_spec.R'))
source(here('src', 'model', 'authority_adapter.R'))

pass <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:', msg, '\n')
}

pp <- load_policy_params(use_policy_dates = TRUE)
swiss_exp <- as.Date(pp$SWISS_FRAMEWORK$expiry_date)
swiss_boundary <- swiss_exp + 1L

# A live underlying surcharge demonstrates why expiry must recompute, not zero.
ieepa <- tibble(
  census_code = pp$SWISS_FRAMEWORK$countries[1],
  rate = 0.31,
  phase = 'phase2_aug7',
  rate_type = 'surcharge',
  ch99_code = '9903.02.82'
)
pp_unit <- list(
  FLOOR_COUNTRIES = pp$SWISS_FRAMEWORK$countries,
  FLOOR_RATE = 0.15,
  SWISS_FRAMEWORK = pp$SWISS_FRAMEWORK
)
cc <- list(CTY_CANADA = '1220', CTY_MEXICO = '2010')
on_expiry <- .resolve_ieepa_reciprocal(ieepa, pp_unit, cc, swiss_exp)
after_expiry <- .resolve_ieepa_reciprocal(ieepa, pp_unit, cc, swiss_boundary)
ch <- pp$SWISS_FRAMEWORK$countries[1]

check(on_expiry$by_country[[ch]] == 0.15 && on_expiry$by_country_type[[ch]] == 'floor',
      'Swiss floor remains active on its last live day')
check(after_expiry$by_country[[ch]] == 0.31 &&
        after_expiry$by_country_type[[ch]] == 'surcharge',
      'first post-expiry day restores the underlying surcharge')
check(on_expiry$by_country_underlying[[ch]] == 0.31,
      'active-floor state preserves the underlying rate')

rd <- load_revision_dates(use_policy_dates = TRUE)
b <- discover_boundaries(rd, here('data', 'timeseries'), pp,
                         overrides = pp$BOUNDARY_OVERRIDES,
                         horizon = pp$SERIES_HORIZON_END)
check(swiss_boundary %in% b$date, 'Swiss first-dead-day boundary is minted')
check(as.Date('2026-07-24') %in% b$date, 'Section 122 first-dead-day boundary is minted')
check(!exists('apply_expiry_zeroing', mode = 'function'),
      'no downstream expiry-zeroing function remains')

cat(sprintf('\nALL %d CALENDAR-OWNED EXPIRY ASSERTIONS PASSED\n', pass))
