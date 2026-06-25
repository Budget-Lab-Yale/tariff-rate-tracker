# =============================================================================
# Tests: discover_boundaries() / build_boundary_mints() (unified timeline / P2-1)
# =============================================================================
# Pure-logic gate for the mintable-boundary discovery (src/model/timeline.R) and the
# idempotency of the minting wrapper (src/pipeline/00_build_timeseries.R). Uses the live
# policy params + the cached ch99_<rev>.rds parses in data/timeseries; the Ch99
# scan assertions skip_test when those caches are absent (config + §232-exemption
# boundaries still resolve without them).
#
# Verified mintable set on the production policy grid (2026-06-25):
#   2025-03-12  owner rev_4        §232 metal country-exemption expiry  [s232 expiry]
#   2025-06-01  owner rev_13       Ch99 rate-less heading expiry (+1)    [ch99 expiry]
#   2025-09-01  owner rev_20       Ch99 rate-less heading expiry (+1)    [ch99 expiry]
#   2025-11-14  owner rev_29       Swiss/Liechtenstein floor starts      [config]
#   2026-02-20  owner 2026_rev_3   IEEPA invalidation (SCOTUS)           [config]
#   2026-09-29  owner 2026_rev_10  pharma §232 turn-on override          [override]
#   2026-11-10  owner 2026_rev_10  §301 cranes/chassis turn-on           [ch99]
# Edge-coincident boundaries that must NOT mint: 2025-05-03 (auto parts = rev_11
# edge), 2025-04-09 (Phase-1 country rates = rev_8 edge), 2026-04-06 (§232 annex =
# 2026_rev_5 edge). Expiry boundaries that must NOT mint (downstream zeroing owns
# them): 2026-07-24 (S122), 2026-04-01 (Swiss expiry).
#
# Usage: Rscript tests/test_boundary_discovery.R
# =============================================================================

suppressPackageStartupMessages({ library(here); library(dplyr) })
source(here('src', 'core', 'helpers.R'))               # loads tidyverse + timeline.R
source(here('src', 'pipeline', '00_build_timeseries.R'))   # build_boundary_mints

pass <- 0L; skip <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:', msg, '\n')
}
note_skip <- function(msg) { skip <<- skip + 1L; cat('  SKIP:', msg, '\n') }

snapshot_dir <- here('data', 'timeseries')
pp <- load_policy_params(use_policy_dates = TRUE)
rd <- load_revision_dates(use_policy_dates = TRUE)
have_ch99 <- length(list.files(snapshot_dir, pattern = '^ch99_.*\\.rds$')) > 0

b <- discover_boundaries(rd, snapshot_dir, pp,
                         overrides = pp$BOUNDARY_OVERRIDES,
                         horizon = pp$SERIES_HORIZON_END)
cat('\ndiscover_boundaries returned ', nrow(b), ' boundary/ies:\n', sep = '')
if (nrow(b)) print(as.data.frame(b[, c('date', 'owner_rev', 'revision', 'source')]))

emitted   <- as.character(b$date)
owner_of  <- function(d) b$owner_rev[match(as.Date(d), b$date)]
src_of    <- function(d) b$source[match(as.Date(d), b$date)]

# --- Shape -------------------------------------------------------------------
check(all(c('date', 'owner_rev', 'revision', 'source') %in% names(b)),
      'discover_boundaries returns date/owner_rev/revision/source')
check(is.character(b$revision) && all(startsWith(b$revision, 'bnd_')),
      'every boundary id is bnd_-prefixed')
check(!any(duplicated(b$date)), 'one row per date (deduped)')
check(identical(b$date, sort(b$date)), 'boundaries sorted by date')
check(all(b$revision == paste0('bnd_', format(b$date, '%Y-%m-%d'))),
      'id == bnd_<ISO date>')

# --- §232 country-exemption expiry (2025-03-12) — needs only policy params ----
check('2025-03-12' %in% emitted, '2025-03-12 (§232 metal-exemption expiry) is discovered')
check(identical(owner_of('2025-03-12'), 'rev_4'),
      '2025-03-12 owner resolves to rev_4 (interval [03-07..03-13])')
check(grepl('s232_exemption_expiry', src_of('2025-03-12')),
      '2025-03-12 sourced from §232 exemption expiry')

# --- IEEPA invalidation (2026-02-20, policy grid) — config setdiff ------------
check('2026-02-20' %in% emitted, '2026-02-20 (IEEPA invalidation) is discovered')
check(identical(owner_of('2026-02-20'), '2026_rev_3'),
      '2026-02-20 owner resolves to 2026_rev_3 (interval [02-07..02-23])')

# --- Swiss framework effective date (2025-11-14) ------------------------------
check('2025-11-14' %in% emitted, '2025-11-14 (Swiss/Liechtenstein floor start) is discovered')
check(identical(owner_of('2025-11-14'), 'rev_29'),
      '2025-11-14 owner resolves to rev_29')

# --- Expiry boundaries must NOT mint (mutual-exclusion rule) -------------------
check(!('2026-07-24' %in% emitted),
      'S122 expiry boundary (2026-07-24) is NOT minted (downstream zeroing owns it)')
check(!('2026-04-01' %in% emitted),
      'Swiss expiry boundary (2026-04-01) is NOT minted (downstream zeroing owns it)')

# --- Edge-coincident config dates must NOT mint -------------------------------
for (edge in c('2025-04-09', '2026-04-06')) {
  check(!(edge %in% emitted),
        paste0(edge, ' (edge-coincident with a real revision) is NOT minted'))
}

# --- Ch99-offset scan (needs the cached parses) -------------------------------
if (have_ch99) {
  check('2026-11-10' %in% emitted,
        '2026-11-10 (§301 cranes/chassis turn-on) is discovered from the Ch99 scan')
  check(identical(owner_of('2026-11-10'), '2026_rev_10'),
        '2026-11-10 owner resolves to 2026_rev_10 (tip interval)')
  check(grepl('ch99', src_of('2026-11-10')), '2026-11-10 sourced from a Ch99 offset')
  # Ch99 rate-less heading expiries (expiry-mirror scan): state flips on expiry+1.
  check(identical(owner_of('2025-06-01'), 'rev_13') && grepl('ch99_expiry', src_of('2025-06-01')),
        '2025-06-01 (Ch99 heading expiry) discovered, owner rev_13')
  check(identical(owner_of('2025-09-01'), 'rev_20') && grepl('ch99_expiry', src_of('2025-09-01')),
        '2025-09-01 (Ch99 heading expiry) discovered, owner rev_20')
  check(!('2025-05-03' %in% emitted),
        '2025-05-03 (auto parts = rev_11 edge) is NOT minted')
  # On the production grid exactly these seven boundaries are mintable (incl. the
  # two Ch99 rate-less heading expiries 2025-06-01 / 2025-09-01).
  expected <- c('2025-03-12', '2025-06-01', '2025-09-01', '2025-11-14',
                '2026-02-20', '2026-09-29', '2026-11-10')
  check(setequal(emitted, expected),
        paste0('exactly {', paste(expected, collapse = ', '), '} discovered on the live grid'))
  check(all(!is.na(b$owner_rev)),
        'each discovered boundary maps to an owner (no silent missing-mint)')
} else {
  note_skip('Ch99 scan assertions (no ch99_<rev>.rds in data/timeseries)')
}

# --- Owner is always interior to a real interval ------------------------------
real <- rd %>% filter(!grepl('^(sched_|bnd_)', revision)) %>% arrange(effective_date)
iv <- real %>% transmute(revision,
                         vf = as.Date(effective_date),
                         vu = lead(as.Date(effective_date)) - 1) %>%
  mutate(vu = if_else(is.na(vu), pp$SERIES_HORIZON_END, vu))
for (i in seq_len(nrow(b))) {
  row <- iv[iv$revision == b$owner_rev[i], ]
  check(nrow(row) == 1 && row$vf < b$date[i] && b$date[i] <= row$vu,
        paste0(b$revision[i], ' is strictly interior to owner ', b$owner_rev[i],
               ' [', row$vf, '..', row$vu, ']'))
}

# --- Idempotency: build_boundary_mints skips ids already in rev_dates ----------
# Pre-seed rev_dates with the discovered bnd_ rows; minting must then be a no-op
# (no recompute, rev_dates returned unchanged). Exercises the skip path WITHOUT
# triggering an expensive build_revision_snapshot.
if (nrow(b) > 0) {
  rd_seeded <- bind_rows(rd, tibble(revision = b$revision, effective_date = b$date))
  out <- build_boundary_mints(rd_seeded, b, pp, snapshot_dir,
                              country_lookup = NULL, countries = NULL,
                              census_codes = NULL,
                              archive_dir = here('data', 'hts_archives'))
  check(nrow(out) == nrow(rd_seeded) && all(out$revision == rd_seeded$revision),
        'build_boundary_mints is idempotent (all ids present => no-op, no recompute)')
}

# --- Empty/degenerate inputs --------------------------------------------------
empty_b <- discover_boundaries(rd, tempfile(), policy_params = NULL,
                               horizon = as.Date('2026-12-31'))
check(nrow(empty_b) == 0,
      'no policy params + no ch99 caches => empty boundary set')
check(identical(build_boundary_mints(rd, empty_b, pp, snapshot_dir,
                                     country_lookup = NULL, countries = NULL,
                                     census_codes = NULL)$revision, rd$revision),
      'build_boundary_mints on empty boundaries returns rev_dates unchanged')

cat(sprintf('\nALL %d BOUNDARY-DISCOVERY ASSERTIONS PASSED (%d skipped)\n', pass, skip))
