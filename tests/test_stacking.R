# =============================================================================
# stacking unit tests (Phase 3a — policy-driven stacking)
# =============================================================================
# Pure-logic checks for src/model/stacking.R. Confirms the data-driven stacking policy
# reproduces the historical mutual-exclusion branches, that the fentanyl
# content-split-except-China wrinkle is now DATA (a per-country class override),
# and that tpc_additive is unchanged. No model data.
# Usage: Rscript tests/test_stacking.R
# =============================================================================

suppressPackageStartupMessages(library(tidyverse))
suppressPackageStartupMessages(library(here))
source(here('src', 'model', 'stacking.R'))

pass <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:', msg, '\n')
}
near <- function(a, b, tol = 1e-12) all(abs(a - b) <= tol)

CHINA <- '5700'; CA <- '1220'

# Four-branch panel: {China, CA} x {232, no-232}. metal_share 0.6 -> nonmetal 0.4.
df <- tibble(
  hts10            = c('1', '2', '3', '4'),
  country          = c(CHINA, CHINA, CA, CA),
  rate_232         = c(0.25, 0,    0.25, 0),
  rate_ieepa_recip = c(0.10, 0.10, 0.10, 0.10),
  rate_ieepa_fent  = c(0.20, 0.20, 0.20, 0.20),
  rate_301         = c(0.075, 0.075, 0, 0),   # 301 is China-only in baseline
  rate_s122        = c(0.05, 0.05, 0.05, 0.05),
  rate_section_201 = c(0, 0, 0, 0),
  rate_other       = c(0, 0, 0, 0),
  metal_share      = c(0.6, 1.0, 0.6, 1.0),
  base_rate        = c(0, 0, 0, 0)
)

cat('--- apply_stacking_rules reproduces the historical branch math ---\n')
res <- apply_stacking_rules(df, cty_china = CHINA)
# China+232:   .25 + .10*.4 + .20 + .075 + .05*.4        = 0.585
# China no232: .10 + .20 + .075 + .05                    = 0.425
# CA+232:      .25 + .10*.4 + .20*.4 + .05*.4            = 0.390
# CA no232:    .10 + .20 + .05                            = 0.350
check(near(res$total_additional, c(0.585, 0.425, 0.39, 0.35)), 'total_additional matches all 4 branches')
check(near(res$total_rate, res$total_additional), 'total_rate = base_rate(0) + total_additional')

cat('\n--- net decomposition matches + sums to total_additional ---\n')
net <- compute_net_authority_contributions(df, cty_china = CHINA)
check(near(net$net_232,      c(0.25, 0, 0.25, 0)),       'net_232')
check(near(net$net_ieepa,    c(0.04, 0.10, 0.04, 0.10)), 'net_ieepa = recip*nonmetal when 232 else full')
check(near(net$net_fentanyl, c(0.20, 0.20, 0.08, 0.20)), 'net_fentanyl: China full, CA content-split')
check(near(net$net_301,      c(0.075, 0.075, 0, 0)),     'net_301 keys on the rate')
check(near(net$net_s122,     c(0.02, 0.05, 0.02, 0.05)), 'net_s122 content-split')
netsum <- with(net, net_232 + net_ieepa + net_fentanyl + net_301 + net_s122 + net_section_201 + net_other)
check(near(netsum, res$total_additional), 'net_* sum to total_additional')

cat('\n--- the fentanyl wrinkle is DATA: flip CA to additive ---\n')
pol <- default_stacking_policy(CHINA)
pol$rate_ieepa_fent$additive_countries <- c(CHINA, CA)   # CA fentanyl now additive too
net2 <- compute_net_authority_contributions(df, cty_china = CHINA, stacking_policy = pol)
check(near(net2$net_fentanyl, c(0.20, 0.20, 0.20, 0.20)), 'CA fentanyl now full rate (additive); China unchanged')
check(near(net2$net_ieepa, net$net_ieepa), 'reciprocal unaffected by the fentanyl override')
res2 <- apply_stacking_rules(df, cty_china = CHINA, stacking_policy = pol)
check(near(res2$total_additional, c(0.585, 0.425, 0.51, 0.35)), 'only CA+232 total moves (+0.12)')

cat('\n--- passing the default policy explicitly == not passing one ---\n')
check(identical(apply_stacking_rules(df, cty_china = CHINA),
                apply_stacking_rules(df, cty_china = CHINA, stacking_policy = default_stacking_policy(CHINA))),
      'explicit default policy is a no-op vs implicit')

cat('\n--- tpc_additive unchanged (full additive, no mutual exclusion) ---\n')
tpc <- apply_stacking_rules(df, cty_china = CHINA, stacking_method = 'tpc_additive')
check(near(tpc$total_additional[1], 0.25 + 0.10 + 0.20 + 0.075 + 0.05), 'tpc sums all rates flat')

cat(sprintf('\nALL %d STACKING ASSERTIONS PASSED\n', pass))
