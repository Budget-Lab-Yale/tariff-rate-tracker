# =============================================================================
# timeline real-data gate (Phase 3c + Pass-2 P2-1; updated Phase 1b)
# =============================================================================
# On the REAL policy params + REAL revision grid:
#   (1) LIVE SPLITTER INVARIANT: the live 09 splitter (timeline_split_points fed
#       expiry_boundaries) partitions every revision interval into a gapless,
#       contiguous, in-range cover of [valid_from .. valid_until] — no spurious,
#       overlapping, or out-of-range split. The S122/Swiss expiries stay on
#       downstream zeroing (see tests/test_mint_equals_zeroing.R), and the
#       boundary convention math is unit-tested in tests/test_timeline.R. (The
#       legacy get_expiry_split_points oracle this once cross-checked against was
#       retired in Phase 1b; its behaviour is subsumed by the +1 mapping.)
#   (2) POSITIVE CONTROL (replaces the old "FINDING" block): discover_boundaries()
#       must emit a mint for EVERY schedule boundary that falls strictly inside a
#       real interval and that the calc re-resolves — and NONE for edge-coincident
#       boundaries. This catches a silently-missing mint (risk R6) and a spurious
#       split on a revision edge (risk R1).
# Usage: Rscript tests/test_timeline_realdata.R
# =============================================================================

suppressPackageStartupMessages({ library(here); library(dplyr); library(tidyr) })
source(here('src', 'helpers.R'))

pass <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:', msg, '\n')
}

pp <- load_policy_params()
rd <- load_revision_dates()
horizon <- as.Date('2026-12-31')

intervals <- rd %>%
  arrange(effective_date) %>%
  transmute(revision,
            valid_from  = as.Date(effective_date),
            valid_until = lead(as.Date(effective_date)) - 1) %>%
  mutate(valid_until = if_else(is.na(valid_until), horizon, valid_until))

exp_bounds  <- expiry_boundaries(pp)               # what the LIVE 09 splitter is fed
full_bounds <- collect_schedule_boundaries(pp)     # the comprehensive collector

# Live (timeline-based) 09 sub-intervals.
live_sub <- function(vf, vu) {
  si <- timeline_split_points(vf, vu, exp_bounds)
  if (!length(si)) list(starts = vf, ends = vu) else list(starts = c(vf, si), ends = c(si - 1, vu))
}

cat(sprintf('expiry boundaries (fed to live splitter): %s\n',
            if (length(exp_bounds)) paste(format(exp_bounds), collapse = ', ') else '(none)'))
cat(sprintf('checking %d real revision intervals...\n', nrow(intervals)))

bad <- 0L
for (i in seq_len(nrow(intervals))) {
  vf <- intervals$valid_from[i]; vu <- intervals$valid_until[i]
  N <- live_sub(vf, vu)
  ok <- identical(N$starts[1], vf) &&                          # opens at valid_from
        identical(N$ends[length(N$ends)], vu) &&               # closes at valid_until
        all(N$ends >= N$starts) &&                             # every piece non-empty
        (length(N$starts) == 1 ||                              # gapless & contiguous
         all(N$starts[-1] == N$ends[-length(N$ends)] + 1)) &&
        all(N$starts >= vf & N$ends <= vu)                     # never escapes the window
  if (!isTRUE(ok)) {
    bad <- bad + 1L
    cat(sprintf('  BAD PARTITION %-12s [%s .. %s]\n', intervals$revision[i], vf, vu))
  }
}
check(bad == 0L, sprintf('live splitter yields a gapless, in-range partition across all %d real intervals',
                         nrow(intervals)))

# --- POSITIVE CONTROL: discover_boundaries mints every interior boundary -------
# (replaces the old "FINDING" diagnostic — those mid-interval boundaries are now
# actually minted, not just reported). discover_boundaries unions the Ch99-offset
# scan + IEEPA invalidation + §232 exemption expiries; here we assert it agrees
# with the real-grid interior/edge geometry. The Ch99 scan needs the cached
# parses, so the offset-derived assertions skip when data/timeseries is empty.
snapshot_dir <- here('data', 'timeseries')
have_ch99 <- length(list.files(snapshot_dir, pattern = '^ch99_.*\\.rds$')) > 0
b <- discover_boundaries(rd, snapshot_dir, pp,
                         overrides = pp$BOUNDARY_OVERRIDES,
                         horizon = horizon)
cat(sprintf('\ndiscover_boundaries emits %d mint(s): %s\n', nrow(b),
            if (nrow(b)) paste(format(b$date), collapse = ', ') else '(none)'))

# R1: every emitted boundary is STRICTLY interior to its owner's real interval
# (no mint sits on a revision edge).
ok_interior <- TRUE
for (i in seq_len(nrow(b))) {
  row <- intervals %>% filter(revision == b$owner_rev[i])
  if (nrow(row) != 1 || !(row$valid_from < b$date[i] && b$date[i] <= row$valid_until)) {
    ok_interior <- FALSE
    cat(sprintf('  !! %s NOT interior to owner %s\n', format(b$date[i]), b$owner_rev[i]))
  }
}
check(ok_interior, 'every discovered mint is strictly interior to its owner interval (R1)')

# R6: no interior, calc-resolvable boundary is silently missed. The §232 metal
# country-exemption expiry (2025-03-12) is the canonical in-window case — it falls
# strictly inside rev_4 and must be minted.
exemption_expiries <- unique(na.omit(as.Date(vapply(
  pp$S232_COUNTRY_EXEMPTIONS,
  function(ex) if (is.null(ex$expiry_date)) NA_character_ else as.character(as.Date(ex$expiry_date)),
  character(1)))))
for (E in exemption_expiries) {
  inside <- intervals %>% filter(valid_from < E, E <= valid_until)
  if (nrow(inside) > 0) {
    check(as.Date(E) %in% b$date,
          sprintf('interior §232-exemption expiry %s is minted (R6: no missing mint)', format(as.Date(E))))
  } else {
    check(!(as.Date(E) %in% b$date),
          sprintf('edge §232-exemption expiry %s is NOT minted', format(as.Date(E))))
  }
}

if (have_ch99) {
  expected <- c('2025-03-12', '2025-06-01', '2025-09-01', '2025-11-14',
                '2026-02-20', '2026-09-29', '2026-11-10')
  check(setequal(as.character(b$date), expected),
        paste0('discovered mint set == {', paste(expected, collapse = ', '), '} on the real grid'))
} else {
  cat('  SKIP: full mint-set assertion (no ch99 caches present)\n')
}

cat(sprintf('\nALL %d REAL-DATA TIMELINE ASSERTIONS PASSED\n', pass))
