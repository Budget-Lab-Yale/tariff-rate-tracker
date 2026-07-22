# =============================================================================
# resolved_programs unit tests (Phase 3b — resolved-program long table)
# =============================================================================
# Confirms the long-table build/stack/collapse reproduces the wide (3a) stacking
# math on the four-branch synthetic frame, that the table has the expected shape
# (one row per pair x authority, carrying class/program_id/precedence/contrib),
# and that the fentanyl per-country override flows through. No model data.
# Usage: Rscript tests/test_resolved_programs.R
# =============================================================================

suppressPackageStartupMessages({ library(tidyverse); library(here) })
source(here('src', 'model', 'stacking.R'))
source(here('src', 'model', 'resolved_programs.R'))

pass <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:', msg, '\n')
}
near <- function(a, b, tol = 1e-12) all(abs(a - b) <= tol)

CHINA <- '5700'; CA <- '1220'

df <- tibble(
  hts10            = c('1', '2', '3', '4'),
  country          = c(CHINA, CHINA, CA, CA),
  rate_232         = c(0.25, 0,    0.25, 0),
  rate_ieepa_recip = c(0.10, 0.10, 0.10, 0.10),
  rate_ieepa_fent  = c(0.20, 0.20, 0.20, 0.20),
  rate_301         = c(0.075, 0.075, 0, 0),
  rate_s122        = c(0.05, 0.05, 0.05, 0.05),
  rate_section_201 = c(0, 0, 0, 0),
  rate_other       = c(0, 0, 0, 0),
  metal_share      = c(0.6, 1.0, 0.6, 1.0),
  base_rate        = c(0, 0, 0, 0)
)

cat('--- build_resolved_programs: shape + metadata ---\n')
res <- build_resolved_programs(df, default_stacking_policy(CHINA))
# 10 authorities now: rate_301_cs (content-split 301 flavor), rate_s301fl (the
# forced-labor §301 scenario authority), and rate_s301br (Brazil §301) are all
# zero in baseline. They join
# default_stacking_policy() in Phase 3a / Plank 1. build_resolved_programs injects any
# missing policy rate_col as 0 (Plank 5c guard), so a frame without those columns still
# yields the full long table — their zero rate contributes nothing.
check(nrow(res) == 4 * 10, '10 authority rows per pair (4 pairs -> 40 rows)')
check(setequal(unique(res$authority),
               c('section_232','ieepa_reciprocal','ieepa_fentanyl','section_301','section_301_cs',
                 'section_301_forced_labor','section_301_brazil','section_122',
                 'section_201','other')),
      'all 10 authorities present (including the scenario §301 columns)')
check(all(c('program_id','precedence','stacking_class','metal_type','contrib') %in% names(res)),
      'carries program_id / precedence / stacking_class / metal_type / contrib')
check(res$stacking_class[res$authority == 'ieepa_fentanyl'][1] == 'content_split',
      'fentanyl base class is content_split')

cat('\n--- contrib reproduces the wide per-authority math ---\n')
# China+232 (pair 1), nonmetal 0.4: fent additive -> full 0.20; recip/s122 split.
p1 <- res %>% filter(.pair == 1)
check(near(p1$contrib[p1$authority == 'ieepa_fentanyl'], 0.20), 'China fentanyl contrib = full (additive)')
check(near(p1$contrib[p1$authority == 'ieepa_reciprocal'], 0.10 * 0.4), 'China recip contrib = recip*nonmetal')
# CA+232 (pair 3): fent content-split -> 0.20*0.4
p3 <- res %>% filter(.pair == 3)
check(near(p3$contrib[p3$authority == 'ieepa_fentanyl'], 0.20 * 0.4), 'CA fentanyl contrib = fent*nonmetal (content-split)')

cat('\n--- resolve_and_collapse == apply_stacking_rules (within FP floor) ---\n')
wide <- apply_stacking_rules(df, cty_china = CHINA)
coll <- resolve_and_collapse(df, default_stacking_policy(CHINA))
check(near(coll$total_additional, wide$total_additional), 'total_additional matches the wide path')
check(near(coll$total_rate, wide$total_rate), 'total_rate matches the wide path')
check(near(coll$total_additional, c(0.585, 0.425, 0.39, 0.35)), 'totals match the hand-computed 4 branches')
check(all(c('rate_232','rate_301','total_rate') %in% names(coll)) &&
      !any(c('.pair','contrib') %in% names(coll)), 'collapse returns the wide schema, no internals leak')

cat('\n--- the fentanyl override flows through the table ---\n')
pol <- default_stacking_policy(CHINA)
pol$rate_ieepa_fent$additive_countries <- c(CHINA, CA)   # CA fentanyl now additive
coll2 <- resolve_and_collapse(df, pol)
check(near(coll2$total_additional, c(0.585, 0.425, 0.51, 0.35)), 'only CA+232 total moves (+0.12)')

cat(sprintf('\nALL %d RESOLVED_PROGRAMS ASSERTIONS PASSED\n', pass))
