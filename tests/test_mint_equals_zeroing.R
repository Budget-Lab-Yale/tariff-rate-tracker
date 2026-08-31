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

# --- Regime guard (fail-closed) ----------------------------------------------
# The calendar recompute reproduces the model's HISTORICAL post-expiry number
# for CH/LI (0) only because IEEPA is ALREADY invalidated by the Swiss expiry:
# with IEEPA void, the recomputed underlying surcharge is 0, matching the old
# downstream zeroing. If a future edit moves the invalidation date PAST the
# Swiss expiry, the recompute would instead restore a live surcharge (the 0.31
# above) where the model previously published 0 — a real, silent number change.
# Pin the ordering so that divergence cannot land without tripping this test.
check(!is.null(pp$IEEPA_INVALIDATION_DATE) &&
        as.Date(pp$IEEPA_INVALIDATION_DATE) <= swiss_boundary,
      'IEEPA invalidation precedes the Swiss expiry mint (recompute stays == historical zeroing)')

rd <- load_revision_dates(use_policy_dates = TRUE)
b <- discover_boundaries(rd, here('data', 'timeseries'), pp,
                         overrides = pp$BOUNDARY_OVERRIDES,
                         horizon = pp$SERIES_HORIZON_END)
check(swiss_boundary %in% b$date, 'Swiss first-dead-day boundary is minted')

# The §122 sunset (expiry 2026-07-23, first dead day 2026-07-24) must START an
# interval, so the calendar recompute sees rate_s122 = 0 from that day. It does
# NOT have to be a synthetic mint: policy-dating rev_13 to the forced-labor
# turn-on made 2026-07-24 a real revision edge, and discover_boundaries drops a
# mint that lands on an edge (owner_of returns NA there) because the revision's
# own snapshot already owns the date. Asserting specifically "is minted" made
# this test contradict test_boundary_discovery.R, which asserts the opposite.
# Assert the invariant that actually matters — the day is an interval start,
# by either route — so a future re-dating cannot silently drop the sunset.
s122_dead_day <- as.Date(pp$SECTION_122$expiry_date) + 1
rev_edges <- as.Date(rd$effective_date)
check(s122_dead_day %in% c(as.Date(b$date), rev_edges),
      'Section 122 first-dead-day starts an interval (mint or revision edge)')
check(s122_dead_day %in% rev_edges,
      'and today that route is the rev_13 edge, not a mint')
check(!exists('apply_expiry_zeroing', mode = 'function'),
      'no downstream expiry-zeroing function remains')

cat(sprintf('\nALL %d CALENDAR-OWNED EXPIRY ASSERTIONS PASSED\n', pass))
