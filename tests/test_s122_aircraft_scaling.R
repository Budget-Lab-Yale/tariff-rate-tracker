# =============================================================================
# Tests: §122 civil-aircraft (note 2(aa)(iv)) utilization scaling
# =============================================================================
# Drives apply_section122() directly to verify the 2026-07-08 fix
# (docs/s122_aircraft_exemption_audit.md): unconditional (aa)(ii)/(iii) codes
# stay full-line exempt; (aa)(iv) civil-aircraft codes are scaled by
# (1 - GN6 exempt share) with measured -> HS2-mean -> full-exemption fallback.
#
# Run: Rscript tests/test_s122_aircraft_scaling.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})
source(here('src', 'core', 'logging.R'))
source(here('src', 'core', 'helpers.R'))
source(here('src', 'model', 'authority_spec.R'))
source(here('src', 'pipeline', '06_calculate_rates.R'))

n_pass <- 0; n_fail <- 0
check <- function(desc, expr) {
  ok <- tryCatch(isTRUE(expr), error = function(e) { message('  ERROR: ', conditionMessage(e)); FALSE })
  if (ok) { n_pass <<- n_pass + 1; message('PASS: ', desc) }
  else    { n_fail <<- n_fail + 1; message('FAIL: ', desc) }
}
near <- function(a, b, tol = 1e-9) length(a) == 1 && !is.na(a) && abs(a - b) < tol

# ---- fixture ----------------------------------------------------------------
# Five HTS8 families:
#   11111111 unconditional exempt (aa)(ii)      -> rate_s122 = 0
#   22222222 GN6 aircraft, measured share 0.90  -> 0.10 * (1-0.90) = 0.010
#   33333333 GN6 aircraft, measured share 0.20  -> 0.10 * (1-0.20) = 0.080
#   44444444 GN6 aircraft, NO measurement but a same-HS2 sibling exists (33..)
#            -> HS2(=44? no) ... use hs2 fallback via a 33-sibling: see below
#   55555555 plain dutiable (not on any list)   -> rate_s122 = 0.10
# HS2-mean fallback: 34xxxxxx GN6 with no measured row, HS2 '34' mean = 0.20
#   (only sibling 34111111 measured at 0.20) -> factor 0.80 -> 0.080
countries <- c('5700', '4120')
products <- tibble(
  hts10 = c('1111111100', '2222222200', '3333333300',
            '3411111100', '3499999900', '5555555500'),
  base_rate = 0)

util <- setNames(c(0.90, 0.20, 0.20),
                 c('2222222200', '3333333300', '3411111100'))

specs <- list(section_122 = list(programs = list(list(
  rate = list(default = 0.10, rate_type = 'surcharge'),
  exempt_products = list(
    hts8     = '11111111',
    gn6_hts8 = c('22222222', '33333333', '34111111', '34999999'),
    gn6_utilization = util)))))

pp <- list(SECTION_122 = list(finalized = FALSE,
                              effective_date = as.Date('2026-02-24'),
                              expiry_date = as.Date('2026-07-23')))

# empty starting rates grid — everything materializes via add_blanket_pairs
rates0 <- tibble(
  hts10 = character(), country = character(),
  rate_232 = numeric(), rate_301 = numeric(), rate_301_cs = numeric(),
  rate_ieepa_recip = numeric(), rate_ieepa_fent = numeric(),
  rate_s122 = numeric(), rate_section_201 = numeric(), rate_other = numeric(),
  base_rate = numeric())

out <- apply_section122(rates0, specs, pp, products, countries,
                        effective_date = as.Date('2026-05-01'))

r <- function(h) out$rate_s122[out$hts10 == h & out$country == '5700']

cat('--- condition-based scaling ---\n')
check('unconditional (aa)(ii) exempt -> 0 (or dropped)',
      length(r('1111111100')) == 0 || near(r('1111111100'), 0))
check('GN6 measured 0.90 -> 0.010', near(r('2222222200'), 0.010))
check('GN6 measured 0.20 -> 0.080', near(r('3333333300'), 0.080))
check('GN6 HS2-mean fallback (34, mean 0.20) -> 0.080', near(r('3499999900'), 0.080))
check('plain dutiable line -> full 0.10', near(r('5555555500'), 0.10))

cat('\n--- the unconditional exempt line pays 0 either way ---\n')
u <- out %>% filter(hts10 == '1111111100')
check('unconditional line has no positive s122', all(coalesce(u$rate_s122, 0) == 0))

cat('\n--- legacy fallback: no condition split -> full-line exempt (old behavior) ---\n')
specs_legacy <- specs
specs_legacy$section_122$programs[[1]]$exempt_products <-
  list(hts8 = c('11111111', '22222222', '33333333'))  # bare, no gn6 split
out_l <- apply_section122(rates0, specs_legacy, pp, products, countries,
                          effective_date = as.Date('2026-05-01'))
rl <- function(h) out_l$rate_s122[out_l$hts10 == h & out_l$country == '5700']
check('legacy: 22222222 fully exempt (0 or dropped)',
      length(rl('2222222200')) == 0 || near(rl('2222222200'), 0))
check('legacy: plain line still full 0.10', near(rl('5555555500'), 0.10))

cat('\n--- pre-force gate: expired -> no s122 applied ---\n')
out_exp <- apply_section122(rates0, specs, pp, products, countries,
                            effective_date = as.Date('2026-08-01'))  # past expiry
check('expired window -> no rows / no rate', nrow(out_exp) == 0 || all(coalesce(out_exp$rate_s122, 0) == 0))

message('\n==================================================')
message('Tests: ', n_pass, ' passed, ', n_fail, ' failed')
message('==================================================')
if (n_fail > 0) quit(status = 1)
