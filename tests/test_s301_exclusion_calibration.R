# =============================================================================
# Tests: §301 exclusion claim-share calibration (tools/calibrate_s301_exclusions.R)
# =============================================================================
# Pure-function units only — the IMDB/statutory IO paths are exercised by
# running the script itself (see docs/s301_exclusion_calibration.md).
#
# Run: Rscript tests/test_s301_exclusion_calibration.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})
source(here('tools', 'calibrate_s301_exclusions.R'))

n_pass <- 0; n_fail <- 0
check <- function(desc, expr) {
  ok <- tryCatch(isTRUE(expr), error = function(e) { message('  ERROR: ', conditionMessage(e)); FALSE })
  if (ok) { n_pass <<- n_pass + 1; message('PASS: ', desc) }
  else    { n_fail <<- n_fail + 1; message('FAIL: ', desc) }
}

near <- function(a, b, tol = 1e-12) all(abs(a - b) < tol)

# --- invert_claim_share ------------------------------------------------------

# Worked example: frozen haddock 0304725000. stat_other = 0.10 (fentanyl),
# full_301 = 0.25. Importer pays only the 10% -> full exclusion take-up.
s <- invert_claim_share(realized = 0.10, stat_other = 0.10, full_301 = 0.25)
check('haddock full take-up: raw = clipped = 1', near(s$raw, 1) && near(s$clipped, 1))

# Importer pays the full 35% -> no exclusion claims.
s <- invert_claim_share(realized = 0.35, stat_other = 0.10, full_301 = 0.25)
check('no take-up: raw = clipped = 0', near(s$raw, 0) && near(s$clipped, 0))

# Halfway: realized 22.5% -> share 0.5.
s <- invert_claim_share(realized = 0.225, stat_other = 0.10, full_301 = 0.25)
check('half take-up: 0.5', near(s$raw, 0.5) && near(s$clipped, 0.5))

# Realized ABOVE the full statutory total (other under-modeled layers, e.g.
# AD/CVD in collections): raw goes negative, clipped floors at 0.
s <- invert_claim_share(realized = 0.50, stat_other = 0.10, full_301 = 0.25)
check('over-statutory realized: raw < 0, clipped 0', s$raw < 0 && near(s$clipped, 0))

# Realized BELOW stat_other (other compliance gaps): raw > 1, clipped caps at 1.
s <- invert_claim_share(realized = 0.05, stat_other = 0.10, full_301 = 0.25)
check('under-other realized: raw > 1, clipped 1', s$raw > 1 && near(s$clipped, 1))

# full_301 = 0 -> NA (not Inf), both fields.
s <- invert_claim_share(realized = 0.10, stat_other = 0.10, full_301 = 0)
check('zero full_301 -> NA', is.na(s$raw) && is.na(s$clipped))

# NA inputs propagate.
s <- invert_claim_share(realized = NA_real_, stat_other = 0.10, full_301 = 0.25)
check('NA realized -> NA', is.na(s$raw) && is.na(s$clipped))

# Vectorized.
s <- invert_claim_share(realized = c(0.10, 0.35), stat_other = c(0.10, 0.10),
                        full_301 = c(0.25, 0.25))
check('vectorized', near(s$clipped, c(1, 0)))

# --- imdb_zip_name -----------------------------------------------------------

check('imdb_zip_name 2026-02', imdb_zip_name('2026-02') == 'IMDB2602.ZIP')
check('imdb_zip_name 2024-11', imdb_zip_name('2024-11') == 'IMDB2411.ZIP')

# --- registry promotion state (2026-06-11) -----------------------------------
# The calibrated values are curator rows so build_s301_exclusion_headings.R
# re-runs preserve them; coverage must stay within [0, 1].

reg <- read_csv(here('resources', 's301_exclusion_headings.csv'),
                col_types = cols(ch99_code = col_character(),
                                 coverage_share = col_double(),
                                 source = col_character(),
                                 .default = col_character()))
r69 <- reg %>% filter(ch99_code == '9903.88.69')
r70 <- reg %>% filter(ch99_code == '9903.88.70')
check('registry .69 calibrated 0.35, source curator',
      nrow(r69) == 1 && near(r69$coverage_share, 0.35) && r69$source == 'curator')
check('registry .70 calibrated 0.20, source curator',
      nrow(r70) == 1 && near(r70$coverage_share, 0.20) && r70$source == 'curator')
check('registry coverage_share all within [0, 1]',
      all(reg$coverage_share >= 0 & reg$coverage_share <= 1))
check('carve-outs .21-.28 stay coverage 0 (NOT exclusions)',
      all(reg$coverage_share[reg$ch99_code %in%
            sprintf('9903.88.%02d', 21:28)] == 0))

# --- per-line coverage file invariants (line_coverage_file consumer) ---------
# Consumed by the 6a-excl per-line override when
# section_301_exclusions.line_coverage_file is configured (dormant in
# baseline; active in config/scenarios/s301_line_coverage).

lcov_path <- here('resources', 's301_exclusion_line_coverage.csv')
check('line coverage file exists', file.exists(lcov_path))
if (file.exists(lcov_path)) {
  lcov <- read_csv(lcov_path,
                   col_types = cols(hts10 = col_character(),
                                    coverage_share = col_double(),
                                    .default = col_character()))
  check('line coverage shares within [0, 1], no NA',
        all(!is.na(lcov$coverage_share)) &&
        all(lcov$coverage_share >= 0 & lcov$coverage_share <= 1))
  check('line coverage hts10 unique, 10-digit',
        !any(duplicated(lcov$hts10)) && all(nchar(lcov$hts10) == 10))
  lines_csv <- read_csv(here('resources', 's301_exclusion_lines.csv'),
                        col_types = cols(.default = col_character()))
  check('line coverage hts10 all known affected lines',
        all(lcov$hts10 %in% lines_csv$hts10))
}

# --- summary -----------------------------------------------------------------
message(sprintf('\n%d passed, %d failed', n_pass, n_fail))
if (n_fail > 0) quit(status = 1)
