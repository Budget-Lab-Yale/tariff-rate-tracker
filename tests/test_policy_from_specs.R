# =============================================================================
# stacking_policy_from_specs unit tests (Plank 5b)
# =============================================================================
# The whole parity argument for Plank 5b rests on ONE invariant:
#   identical(stacking_policy_from_specs(baseline_specs, cty), default_stacking_policy(cty))
# i.e. building the stacking policy FROM the spec (class + exceptions) reproduces
# the hardcoded default BYTE-FOR-BYTE at baseline. This test pins that invariant
# (so a structural drift fails here, before the 43-rev array), plus the
# counterfactual behavior that makes the wiring worthwhile (mutating a spec's
# stacking.class/exceptions changes the policy).
#
# The synthetic spec set below mirrors authority_adapter.R's per-authority stacking
# fields EXACTLY (section_232 primary_metal; ieepa_* / s122 content_split; fentanyl
# China->additive exception; 301/201/mfn/other additive). The builder reads ONLY
# $stacking$class / $stacking$exceptions, so a plain named list is a faithful and
# robust stand-in (no build data needed). test_authority_adapter.R pins the adapter's
# actual fields.
# Usage: Rscript tests/test_policy_from_specs.R
# =============================================================================

suppressPackageStartupMessages(library(tidyverse))
suppressPackageStartupMessages(library(here))
source(here('src', 'model', 'stacking.R'))

pass <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:', msg, '\n')
}

CHINA <- '5700'

# Baseline spec set as the adapter builds the stacking fields (authority_adapter.R
# :338/529/553-554/567/585/598/621/631). Keyed by authority name (the builder indexes
# specs[[auth]]); order is irrelevant.
mk <- function(class, exceptions = list()) list(stacking = list(class = class, exceptions = exceptions))
baseline_specs <- list(
  section_232      = mk('primary_metal'),
  ieepa_reciprocal = mk('content_split'),
  ieepa_fentanyl   = mk('content_split', setNames(list('additive'), CHINA)),
  section_301      = mk('additive'),
  section_122      = mk('content_split'),
  section_201      = mk('additive'),
  mfn              = mk('additive'),   # base layer — must be EXCLUDED (no rate_col)
  other            = mk('additive')
)

cat('--- THE invariant: from-specs reproduces default byte-for-byte ---\n')
from_spec <- stacking_policy_from_specs(baseline_specs, CHINA)
def       <- default_stacking_policy(CHINA)
check(identical(from_spec, def),
      'identical(stacking_policy_from_specs(baseline_specs), default_stacking_policy())')
# Spell out the structural pieces too (so a failure localizes):
check(identical(names(from_spec), names(def)), 'same rate_col keys in the same (load-bearing) order')
check(identical(from_spec$rate_232$class, 'primary'), "section_232 primary_metal collapses to 'primary'")
check(is.null(from_spec$rate_232$additive_countries), 'rate_232 carries NO additive_countries (matches default)')
check(identical(from_spec$rate_ieepa_fent$additive_countries, CHINA),
      "rate_ieepa_fent additive_countries == '5700' (from fentanyl exceptions)")
check(identical(from_spec$rate_301_cs, list(net = 'net_301_cs', class = 'content_split')),
      'rate_301_cs skeleton-injected (no spec authority), content_split')
check(!('rate_mfn' %in% names(from_spec)) && !('mfn' %in% names(from_spec)),
      'mfn excluded — no phantom rate_mfn entry')

cat('\n--- primary_full also collapses to primary (e.g. a 232 full program authority) ---\n')
pf <- baseline_specs; pf$section_232 <- mk('primary_full')
check(identical(stacking_policy_from_specs(pf, CHINA), def),
      "section_232 primary_full also collapses to 'primary' -> still == default")

cat('\n--- counterfactual: mutating a spec class flows into the policy ---\n')
mutated <- baseline_specs; mutated$ieepa_reciprocal <- mk('additive')
pol_m <- stacking_policy_from_specs(mutated, CHINA)
check(identical(pol_m$rate_ieepa_recip$class, 'additive'),
      'set ieepa_reciprocal class=additive -> policy rate_ieepa_recip is additive')
check(!identical(pol_m, def), 'mutated policy diverges from default (the wiring is real)')

cat('\n--- counterfactual: dropping the fentanyl China exception drops additive_countries ---\n')
no_exc <- baseline_specs; no_exc$ieepa_fentanyl <- mk('content_split')   # exceptions=list()
pol_ne <- stacking_policy_from_specs(no_exc, CHINA)
check(is.null(pol_ne$rate_ieepa_fent$additive_countries),
      'empty fentanyl exceptions -> no additive_countries key (China fentanyl would content-split)')

cat('\n--- counterfactual: adding a country to fentanyl exceptions surfaces it ---\n')
CA <- '1220'
two <- baseline_specs
two$ieepa_fentanyl <- mk('content_split', setNames(list('additive', 'additive'), c(CHINA, CA)))
pol_two <- stacking_policy_from_specs(two, CHINA)
check(identical(sort(pol_two$rate_ieepa_fent$additive_countries), sort(c(CHINA, CA))),
      'two additive-flagged fentanyl countries both surface in additive_countries')

cat('\n--- the from-specs policy drives the engine identically at baseline ---\n')
df <- tibble(
  hts10 = c('1','2','3','4'), country = c(CHINA, CHINA, CA, CA),
  rate_232 = c(0.25, 0, 0.25, 0), rate_ieepa_recip = rep(0.10, 4),
  rate_ieepa_fent = rep(0.20, 4), rate_301 = c(0.075, 0.075, 0, 0),
  rate_s122 = rep(0.05, 4), rate_section_201 = rep(0, 4), rate_other = rep(0, 4),
  metal_share = c(0.6, 1.0, 0.6, 1.0), base_rate = rep(0, 4))
r_def  <- apply_stacking_rules(df, cty_china = CHINA)
r_spec <- apply_stacking_rules(df, cty_china = CHINA, stacking_policy = from_spec)
check(identical(r_def$total_additional, r_spec$total_additional),
      'total_additional identical under default vs from-specs policy')

cat(sprintf('\nALL %d POLICY-FROM-SPECS ASSERTIONS PASSED\n', pass))
