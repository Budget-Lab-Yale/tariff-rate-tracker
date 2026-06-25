# =============================================================================
# Tests: mint-vs-zeroing equivalence (unified timeline / P2-1, Stage 3 gate)
# =============================================================================
# The unified-timeline design splits boundary handling across TWO mechanisms and
# requires them to be MUTUALLY EXCLUSIVE (a boundary is handled by exactly one):
#
#   MINT  (discover_boundaries + build_boundary_mints): recompute the owner archive
#         as-of the boundary date. Correct ONLY for boundaries the calculator's own
#         date gates re-resolve — Ch99 offsets, IEEPA invalidation, §232
#         country-exemption expiries.
#   ZEROING (09_daily_series + helpers.R apply_expiry_zeroing): zero an expired rate
#         column downstream. Owns the SECTION_122 / SWISS expiries.
#
# This test proves WHY the SECTION_122 / SWISS expiries must stay on the zeroing
# path (i.e. why discover_boundaries SUBTRACTS expiry_boundaries()):
#   * SECTION_122 — mint ≡ zeroing. The calc gate (06_calculate_rates.R: s122_in_force
#     <- eff >= effective && eff <= expiry; rate_s122 = 0 otherwise) zeros rate_s122
#     for eff > expiry, exactly as apply_expiry_zeroing does. Equivalent — but moving
#     it would be a pure refactor with no behavior gain, so it stays put.
#   * SWISS — mint != zeroing (NOT a safe swap). apply_expiry_zeroing FORCES CH/LI
#     rate_ieepa_recip to 0 (the pre-floor surcharge is not stored in the snapshot,
#     so it can't be restored downstream). A recompute, by contrast, merely turns OFF
#     the floor override (authority_adapter.R: swiss_override_active gate) and reverts
#     CH/LI to their underlying reciprocal SURCHARGE — which is nonzero whenever IEEPA
#     is live. The two diverge. (They happen to coincide in the current regime only
#     because IEEPA is invalidated 2026-02-20, before the Swiss expiry 2026-03-31 —
#     a fragile, regime-dependent accident, not a structural identity.)
#
# Conclusion: keep both mechanisms; expiries are NOT minted. This test is the guard.
#
# Usage: Rscript tests/test_mint_equals_zeroing.R
# =============================================================================

suppressPackageStartupMessages({ library(here); library(dplyr) })
source(here('src', 'core', 'helpers.R'))   # apply_expiry_zeroing, collect_expiry_adjustments, timeline.R

pass <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:', msg, '\n')
}

pp <- load_policy_params(use_policy_dates = TRUE)
s122_exp  <- as.Date(pp$SECTION_122$expiry_date)        # 2026-07-23 (last live day)
swiss_exp <- as.Date(pp$SWISS_FRAMEWORK$expiry_date)    # 2026-03-31 (last live day)
swiss_eff <- as.Date(pp$SWISS_FRAMEWORK$effective_date) # 2025-11-14
ch <- pp$SWISS_FRAMEWORK$countries[1]                   # Switzerland census code

# ---------------------------------------------------------------------------
# SECTION 122: mint (calc gate) ≡ zeroing
# ---------------------------------------------------------------------------
# Replicate the calc's s122 in-force gate (06_calculate_rates.R) — a recompute
# stamped at D applies rate_s122 iff this is TRUE; rate_s122 = 0 otherwise.
s122_in_force <- function(D) {
  D <- as.Date(D)
  if (isTRUE(pp$SECTION_122$finalized)) return(TRUE)
  D >= as.Date(pp$SECTION_122$effective_date) & D <= s122_exp
}

# Synthetic snapshot carrying an active s122 rate.
snap <- tibble(hts10 = c('7208100000', '8471300100'),
               country = c('1220', '5700'),
               rate_s122 = c(0.10, 0.10),
               rate_ieepa_recip = 0, rate_232 = 0, rate_301 = 0,
               rate_ieepa_fent = 0, rate_section_201 = 0, rate_other = 0,
               base_rate = 0, total_rate = 0.10, total_additional = 0.10)

# Day BEFORE the boundary (= expiry, the last live day): both keep s122.
z_live <- apply_expiry_zeroing(snap, sub_start = s122_exp, pp)
check(all(z_live$rate_s122 == 0.10) && s122_in_force(s122_exp),
      'S122: on the expiry day (last live) both calc-gate and zeroing keep rate_s122')

# Day ON/AFTER the boundary (expiry + 1, the first dead day): both drop s122.
boundary <- s122_exp + 1
z_dead <- apply_expiry_zeroing(snap, sub_start = boundary, pp)
check(all(z_dead$rate_s122 == 0) && !s122_in_force(boundary),
      'S122: on the first dead day both calc-gate (recompute) and zeroing => rate_s122 = 0')

# Equivalence across a window straddling the expiry.
win <- seq(s122_exp - 3, s122_exp + 3, by = 'day')
agree <- vapply(win, function(D) {
  zeroed  <- all(apply_expiry_zeroing(snap, sub_start = D, pp)$rate_s122 == 0)
  recompd <- !s122_in_force(D)             # recompute would zero s122
  identical(zeroed, recompd)
}, logical(1))
check(all(agree), 'S122: mint(recompute) and zeroing agree on every day around the expiry')

# ---------------------------------------------------------------------------
# SWISS: mint != zeroing (NOT a safe swap)
# ---------------------------------------------------------------------------
# Replicate the calc's Swiss floor-override gate (authority_adapter.R). When this
# is FALSE (past expiry), the recompute does NOT zero CH/LI — it merely removes the
# floor override, reverting to the underlying reciprocal surcharge.
swiss_override_active <- function(D) {
  D <- as.Date(D)
  D >= swiss_eff & (isTRUE(pp$SWISS_FRAMEWORK$finalized) | D <= swiss_exp)
}

# Synthetic snapshot: a CH row whose underlying (pre-floor) reciprocal surcharge is
# 0.31 — what a recompute would restore once the floor override switches off.
ch_surcharge <- 0.31
snap_ch <- tibble(hts10 = '7208100000', country = ch,
                  rate_ieepa_recip = ch_surcharge,
                  rate_s122 = 0, rate_232 = 0, rate_301 = 0, rate_ieepa_fent = 0,
                  rate_section_201 = 0, rate_other = 0,
                  base_rate = 0, total_rate = ch_surcharge, total_additional = ch_surcharge)

after <- swiss_exp + 1
zeroed_ch <- apply_expiry_zeroing(snap_ch, sub_start = after, pp)$rate_ieepa_recip
check(zeroed_ch == 0,
      'SWISS: apply_expiry_zeroing forces CH rate_ieepa_recip to 0 past the expiry')
check(!swiss_override_active(after),
      'SWISS: past the expiry the floor override is OFF (recompute reverts to surcharge)')
# The divergence: zeroing => 0, recompute => the live surcharge (0.31 here). Not equal.
check(zeroed_ch != ch_surcharge,
      'SWISS: mint(recompute, => surcharge) != zeroing(=> 0) for a live IEEPA surcharge')

# ---------------------------------------------------------------------------
# GUARD: discover_boundaries must NOT emit the expiry boundaries (mutual exclusion)
# ---------------------------------------------------------------------------
rd <- load_revision_dates(use_policy_dates = TRUE)
b <- discover_boundaries(rd, here('data', 'timeseries'), pp,
                         overrides = pp$BOUNDARY_OVERRIDES,
                         horizon = pp$SERIES_HORIZON_END)
emitted <- as.character(b$date)
check(!(as.character(boundary) %in% emitted),
      paste0('S122 expiry boundary (', boundary, ') is excluded from the mint set'))
check(!(as.character(after) %in% emitted),
      paste0('Swiss expiry boundary (', after, ') is excluded from the mint set'))
check(!any(as.Date(expiry_boundaries(pp)) %in% b$date),
      'no expiry_boundaries() date appears in the discovered mint set')

cat(sprintf('\nALL %d MINT-VS-ZEROING ASSERTIONS PASSED\n', pass))
