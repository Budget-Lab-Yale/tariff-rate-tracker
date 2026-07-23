# =============================================================================
# timeline unit tests (Phase 3c — unified schedule-boundary splitter)
# =============================================================================
# Pins down the day-convention reconciliation (the off-by-one between the two
# legacy mechanisms) and boundary collection. Pure logic, no model data.
# Usage: Rscript tests/test_timeline.R
# =============================================================================

suppressPackageStartupMessages(library(here))
source(here('src', 'model', 'timeline.R'))

pass <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:', msg, '\n')
}
d <- as.Date

cat('--- convention mapping: last-live-day vs first-dead-day ---\n')
check(boundary_from_expiry(d('2025-08-31')) == d('2025-09-01'),
      'expiry (last live 08-31) -> boundary 09-01 (first dead)')
check(boundary_from_until(d('2025-09-01')) == d('2025-09-01'),
      'until (first dead 09-01) -> boundary 09-01 (unchanged)')

cat('\n--- the off-by-one reconciliation: both mean "state changes 09-01" ---\n')
b_exp <- boundary_from_expiry(d('2025-08-31'))   # an authority expiring 08-31
b_unt <- boundary_from_until(d('2025-09-01'))     # an authority invalidated 09-01
check(identical(b_exp, b_unt), 'expiry-08-31 and until-09-01 collapse to ONE boundary 09-01')

cat('\n--- split points inside a revision window (06-01 .. 12-31) ---\n')
vf <- d('2025-06-01'); vu <- d('2025-12-31')
check(identical(timeline_split_points(vf, vu, boundary_from_expiry(d('2025-07-04'))), d('2025-07-05')),
      'expiry 07-04 -> sub-interval starts 07-05 (old state runs through 07-04)')
check(length(timeline_split_points(vf, vu, boundary_from_expiry(d('2026-01-15')))) == 0,
      'expiry after the window -> no split')
check(length(timeline_split_points(vf, vu, vf)) == 0,
      'boundary exactly at valid_from -> no split (it IS the window start)')
check(identical(timeline_split_points(vf, vu, vu), vu),
      'boundary at valid_until -> splits off the final single day')
check(identical(timeline_split_points(vf, vu, c(d('2025-07-05'), d('2025-09-01'), d('2025-09-01'))),
                c(d('2025-07-05'), d('2025-09-01'))),
      'multiple boundaries de-duplicated and sorted')

cat('\n--- collect_schedule_boundaries: all sources, deduped + sorted ---\n')
pp <- list(
  IEEPA_INVALIDATION_DATE = d('2025-11-01'),                                  # until -> 11-01
  SECTION_122    = list(finalized = FALSE, expiry_date = d('2025-07-04')),    # expiry -> 07-05
  SWISS_FRAMEWORK = list(finalized = TRUE, effective_date = d('2025-04-01'),
                         expiry_date = d('2025-05-01')) # start kept; expiry skipped
)
specs <- list(list(active = list(from = d('2025-03-12'), until = d('2025-11-01'))))  # until dups invalidation
got <- collect_schedule_boundaries(pp, specs = specs, horizon = d('2026-12-31'),
                                   extra = d('2025-09-15'))                          # annex (via extra)
check(identical(got, c(d('2025-03-12'), d('2025-04-01'), d('2025-07-05'), d('2025-09-15'),
                       d('2025-11-01'), d('2026-12-31'))),
      'all starts retained; finalized Swiss expiry skipped; 11-01 deduped')
check(length(collect_schedule_boundaries(NULL)) == 0, 'no inputs -> no boundaries')

cat(sprintf('\nALL %d TIMELINE ASSERTIONS PASSED\n', pass))
