# =============================================================================
# Model B: current policy code x ORIGINAL revision dates
# =============================================================================
#
# Middle leg of the three-model decomposition (see
# scripts/compare_three_models.R):
#   A = pre-eta-fix code x old dates   (worktree ../tariff-rate-tracker-modelA)
#   B = current code     x old dates   (this script)
#   D = current code     x new dates   (the production build)
#
# D - B isolates the timing effect of the 2026-06-05 re-dating (boundary
# shifts PLUS the within-revision date-gate content they drive); B - A
# isolates the six extreme-eta policy fixes.
#
# use_policy_dates = FALSE makes load_revision_dates() return the raw
# effective_date column, which still holds the pre-redating dates by design.
# Two documented nuances vs the true original: rev_16 reverts to its raw
# Jun-6 date (the original's Jun-4 override now lives in
# policy_effective_date), and 2026_rev_8 is absent (editorial-only,
# zero rate impact).
#
# Snapshots + combined series land in data/timeseries_olddates/ (isolated
# from production). Runtime ~100 min.
#
# Usage: Rscript scripts/build_model_b_olddates.R
# =============================================================================

library(here)
source(here('src', '00_build_timeseries.R'))  # defines build_full_timeseries; main is sys.nframe()-guarded

result <- build_full_timeseries(
  output_dir = 'data/timeseries_olddates',
  use_policy_dates = FALSE
)

message('Model B build complete: data/timeseries_olddates/')
