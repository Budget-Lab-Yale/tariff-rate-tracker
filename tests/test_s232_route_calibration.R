# =============================================================================
# Tests: §232 annex route-share calibration (tools/calibrate_s232_annex_routes.R)
# =============================================================================
# Pure-function units only — the IMDB/statutory IO paths are exercised by
# running the script itself (see
# docs/s232/annex_exemption_route_calibration_proposal.md §8).
#
# Run: Rscript tests/test_s232_route_calibration.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})
source(here('tools', 'calibrate_s232_annex_routes.R'))

n_pass <- 0; n_fail <- 0
check <- function(desc, expr) {
  ok <- tryCatch(isTRUE(expr), error = function(e) { message('  ERROR: ', conditionMessage(e)); FALSE })
  if (ok) { n_pass <<- n_pass + 1; message('PASS: ', desc) }
  else    { n_fail <<- n_fail + 1; message('FAIL: ', desc) }
}

near <- function(a, b, tol = 1e-9) all(abs(a - b) < tol)

# --- us_origin_route_addl (note 16(e) semantics) -----------------------------

# annex_1b: flat +10% via 9903.82.06, regardless of base.
check('16(e) annex_1b flat +10%',
      near(us_origin_route_addl('annex_1b', 0.025), 0.10))
check('16(e) annex_1a flat +10%',
      near(us_origin_route_addl('annex_1a', 0.15), 0.10))
# annex_3: 10% TARGET-TOTAL via 9903.82.07/.08 — additional tops base to 10%.
check('16(e) annex_3 base 2.5% -> +7.5%',
      near(us_origin_route_addl('annex_3', 0.025), 0.075))
check('16(e) annex_3 base 12% -> +0 (9903.82.08 "No change")',
      near(us_origin_route_addl('annex_3', 0.12), 0))
check('16(e) NA base treated as 0',
      near(us_origin_route_addl('annex_3', NA_real_), 0.10))
check('16(e) non-annex tier -> NA',
      is.na(us_origin_route_addl('annex_2', 0.02)))

# --- build_candidates --------------------------------------------------------

# Typical annex_1b ch84 line: MFN 1.5%, no other layers. total = 1.5 + 25 = 26.5%.
# no_232 branch: MFN + s122 10% = 11.5% (non-ITA line).
df <- tibble(total_rate = 0.265, rate_232 = 0.25, base_rate = 0.015,
             s232_annex = 'annex_1b', total_rate_no232 = 0.115) %>%
  build_candidates()
check('candidates: T_full = published total', near(df$T_full, 0.265))
check('candidates: T_us = total - 232 + 10% = 11.5%', near(df$T_us, 0.115))
check('candidates: T_exit = no_232 total', near(df$T_exit, 0.115))
# NOTE: this line is exactly the §122-charged ambiguity case — T_us == T_exit.

# ITA line (§122-exempt): no_232 total = MFN only.
df2 <- tibble(total_rate = 0.265, rate_232 = 0.25, base_rate = 0.015,
              s232_annex = 'annex_1b', total_rate_no232 = 0.015) %>%
  build_candidates()
check('ITA candidates separate: full 26.5 / us 11.5 / exit 1.5',
      near(df2$T_full, 0.265) && near(df2$T_us, 0.115) && near(df2$T_exit, 0.015))

# --- classify_route ----------------------------------------------------------

# Clean separations (the ITA line above): each signature recovered exactly.
cl <- classify_route(realized = c(0.265, 0.115, 0.015, 0.60),
                     T_full = rep(0.265, 4), T_us = rep(0.115, 4),
                     T_exit = rep(0.015, 4))
check('assign full',        cl$route[1] == 'full')
check('assign us_origin',   cl$route[2] == 'us_origin')
check('assign exit',        cl$route[3] == 'exit')
check('far from all -> unexplained', cl$route[4] == 'unexplained')
check('clean separations not ambiguous', !any(cl$ambiguous[1:3]))

# §122-charged non-ITA line: T_us == T_exit — realized at that level MUST be
# flagged ambiguous (the eta guard), never force-assigned silently.
cl2 <- classify_route(realized = 0.115, T_full = 0.265,
                      T_us = 0.115, T_exit = 0.115)
check('T_us == T_exit at realized -> ambiguous flag', isTRUE(cl2$ambiguous))
check('...but still classified to a nearest route',
      cl2$route %in% c('us_origin', 'exit'))

# realized near T_full while T_us/T_exit collide far away: NOT ambiguous.
cl3 <- classify_route(realized = 0.26, T_full = 0.265,
                      T_us = 0.115, T_exit = 0.115)
check('collision far from realized -> not ambiguous', !cl3$ambiguous)
check('...assigned full', cl3$route == 'full')

# unexplained never carries the ambiguous flag
cl4 <- classify_route(realized = 0.60, T_full = 0.265,
                      T_us = 0.115, T_exit = 0.115)
check('unexplained -> ambiguous FALSE', !cl4$ambiguous)

# 16(e) route is optional: where T_us >= T_full the candidate is masked —
# realized at that level must NOT assign to us_origin (USMCA-scaled annex_3
# floor case, e.g. T_full 5.1% < T_us 10.3%).
cl5 <- classify_route(realized = 0.103, T_full = 0.051,
                      T_us = 0.103, T_exit = 0.003)
check('T_us >= T_full masked: not assigned us_origin', cl5$route != 'us_origin')
check('...falls to unexplained (far from full and exit)',
      cl5$route == 'unexplained')
# and a masked candidate never blocks a legitimate assignment
cl6 <- classify_route(realized = 0.05, T_full = 0.051,
                      T_us = 0.103, T_exit = 0.003)
check('masked T_us: realized at T_full still assigns full', cl6$route == 'full')

# --- route_bounds ------------------------------------------------------------

# ITA line, realized exactly T_exit: z0 bound = 1; u bound > 1 raw (clipped 1).
b <- route_bounds(realized = 0.015, T_full = 0.265, T_us = 0.115, T_exit = 0.015)
check('z0 bound = 1 at T_exit', near(b$z0_raw, 1) && near(b$z0, 1))
check('u raw > 1 at T_exit (visible), clipped to 1',
      b$u_raw > 1 && near(b$u, 1))

# realized = T_full: both bounds 0.
b2 <- route_bounds(realized = 0.265, T_full = 0.265, T_us = 0.115, T_exit = 0.015)
check('bounds 0 at T_full', near(b2$z0_raw, 0) && near(b2$u_raw, 0))

# halfway between full and exit: z0 = 0.5.
b3 <- route_bounds(realized = 0.14, T_full = 0.265, T_us = 0.115, T_exit = 0.015)
check('z0 bound halfway = 0.5', near(b3$z0_raw, 0.5))

# degenerate denominator (T_full == T_exit): NA, not Inf.
b4 <- route_bounds(realized = 0.10, T_full = 0.115, T_us = 0.10, T_exit = 0.115)
check('degenerate z0 denominator -> NA', is.na(b4$z0_raw))

# realized above T_full (under-modeled layers, AD/CVD): raw < 0 visible.
b5 <- route_bounds(realized = 0.30, T_full = 0.265, T_us = 0.115, T_exit = 0.015)
check('realized above T_full -> raw < 0, clipped 0',
      b5$z0_raw < 0 && near(b5$z0, 0))

# --- month_weights -----------------------------------------------------------

# May 2026, rev_9 window (2026-05-01 .. 2026-06-07): full regime month.
w <- month_weights(as.Date('2026-05-01'), as.Date('2026-06-07'), '2026-05')
check('May full coverage: 31 of 31 days',
      near(w$days, 31) && near(w$month_days, 31))

# April 2026, rev_5 window (2026-04-06 .. 2026-04-22): annex-era days only.
w2 <- month_weights(as.Date('2026-04-06'), as.Date('2026-04-22'), '2026-04')
check('April rev_5 window: 17 days', near(w2$days, 17))

# a window that PRECEDES the annex era contributes zero days even if it
# overlaps the month (Apr 1-5, rev_4).
w3 <- month_weights(as.Date('2026-02-24'), as.Date('2026-04-05'), '2026-04')
check('pre-annex window contributes 0 days', near(w3$days, 0))

# April total across the three annex windows = 25 of 30 days (partial regime).
w_all <- month_weights(as.Date(c('2026-04-06', '2026-04-23', '2026-04-29')),
                       as.Date(c('2026-04-22', '2026-04-28', '2026-04-30')),
                       '2026-04')
check('April regime coverage 25/30',
      near(sum(w_all$days), 25) && near(w_all$month_days, 30))

# --- summary -----------------------------------------------------------------
message('\n==================================================')
message('Tests: ', n_pass, ' passed, ', n_fail, ' failed')
message('==================================================')
if (n_fail > 0) quit(status = 1)
