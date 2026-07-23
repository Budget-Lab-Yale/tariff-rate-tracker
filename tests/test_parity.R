# =============================================================================
# parity comparator unit tests
# =============================================================================
#
# Pure-logic checks for src/core/parity.R on synthetic fixtures — no model data,
# runs in seconds. Covers: exact match, within/beyond tolerance per column
# class (rate vs etr), NA handling, row missing/extra, schema diffs.
#
# Usage (via Slurm, per project convention — not on the login node):
#   bash -lc 'module load R/4.4.2-gfbf-2024a; Rscript tests/test_parity.R'
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(tibble)
})

source(here('src', 'core', 'parity.R'))

pass_count <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass_count <<- pass_count + 1L
  cat('  ok:', msg, '\n')
}

# Base fixture: a tiny rate panel keyed (hts10, country, revision).
key <- c('hts10', 'country', 'revision')
reference <- tibble(
  hts10    = c('7208100000', '8703230000', '0101210000'),
  country  = c('5700', '5700', '1220'),
  revision = c('rev_10', 'rev_10', 'rev_10'),
  rate_232 = c(0.50, 0.00, 0.00),
  rate_301 = c(0.25, 0.075, 0.00),
  metal_share = c(1.0, 0.0, 0.0),
  total_rate  = c(0.75, 0.075, 0.00),
  weighted_etr = c(0.0123456, 0.0001000, 0.0000000),
  usmca_eligible = c(FALSE, FALSE, TRUE),
  effective_date = as.Date(c('2025-03-12', '2025-03-12', '2025-03-12'))
)

cat('--- identical tables ---\n')
r <- compare_parity(reference, reference, key, 'identical')
check(r$pass, 'identical tables pass')
check(r$n_violations == 0, 'zero violations on identical')
check(r$n_rows_common == 3, 'all rows common')

cat('\n--- row-order independence ---\n')
actual <- reference[c(3, 1, 2), ]
r <- compare_parity(actual, reference, key, 'reordered_generic')
check(r$pass, 'generic natural keys align reordered rows')
snapshot_reference <- reference[c('hts10', 'country', 'rate_232')]
snapshot_actual <- snapshot_reference[c(2, 3, 1), ]
r <- compare_parity(snapshot_actual, snapshot_reference,
                    c('hts10', 'country'), 'reordered_snapshot')
check(r$pass, 'compact snapshot keys align reordered rows')
meta_reference <- snapshot_reference
meta_reference$metadata_only <- 'old-grid'
actual <- meta_reference
actual$metadata_only <- 'new-grid'
r <- compare_parity(actual, meta_reference, c('hts10', 'country'),
                    'approved_metadata_drift', ignore_cols = 'metadata_only')
check(r$pass, 'explicitly ignored metadata VALUES are outside the economic gate')
actual$metadata_only <- NULL
r <- compare_parity(actual, meta_reference, c('hts10', 'country'),
                    'ignored_column_dropped', ignore_cols = 'metadata_only')
check(!r$pass, 'dropping an ignored column entirely is still schema drift')

cat('\n--- within tolerance (rate: abs 1e-9; etr: rel 1e-7) ---\n')
actual <- reference
actual$rate_232[1]     <- reference$rate_232[1] + 5e-10        # rate: within abs 1e-9
actual$total_rate[1]   <- reference$total_rate[1] - 9e-10      # rate: within abs 1e-9
actual$weighted_etr[1] <- reference$weighted_etr[1] * (1 + 5e-8)  # etr: within rel 1e-7
r <- compare_parity(actual, reference, key, 'within_tol')
check(r$pass, 'sub-tolerance float drift passes')

cat('\n--- beyond tolerance ---\n')
actual <- reference
actual$rate_232[1] <- reference$rate_232[1] + 1e-3            # rate: way beyond 1e-9
r <- compare_parity(actual, reference, key, 'beyond_tol')
check(!r$pass, 'rate drift 1e-3 fails')
check(any(r$violations$kind == 'value_mismatch' & r$violations$column == 'rate_232'),
      'reports the offending column (rate_232)')

actual <- reference
actual$weighted_etr[1] <- reference$weighted_etr[1] * (1 + 1e-4)  # etr: beyond rel 1e-7
r <- compare_parity(actual, reference, key, 'etr_beyond')
check(!r$pass, 'etr relative drift 1e-4 fails')

cat('\n--- near-zero etr handled by absolute floor ---\n')
actual <- reference
actual$weighted_etr[3] <- 1e-13                            # reference is 0; |diff| < 1e-12 floor
r <- compare_parity(actual, reference, key, 'etr_nearzero')
check(r$pass, 'near-zero etr within abs floor passes')

cat('\n--- NA handling ---\n')
actual <- reference
actual$rate_301[2] <- NA_real_                            # value -> NA is a violation
r <- compare_parity(actual, reference, key, 'na_vs_value')
check(!r$pass, 'NA-vs-value is a violation')
g2 <- reference; g2$rate_301[2] <- NA_real_
a2 <- reference; a2$rate_301[2] <- NA_real_
r <- compare_parity(a2, g2, key, 'na_vs_na')
check(r$pass, 'NA-vs-NA passes')

cat('\n--- row missing / extra ---\n')
actual <- reference[1:2, ]                                   # dropped a reference row
r <- compare_parity(actual, reference, key, 'row_missing')
check(!r$pass, 'dropped row fails')
check(any(r$violations$kind == 'row_missing'), 'reports row_missing')

actual <- dplyr::bind_rows(reference, tibble(
  hts10 = '9999999999', country = '5700', revision = 'rev_10',
  rate_232 = 0.1, rate_301 = 0, metal_share = 0, total_rate = 0.1,
  weighted_etr = 0, usmca_eligible = FALSE,
  effective_date = as.Date('2025-03-12')))
r <- compare_parity(actual, reference, key, 'row_extra')
check(!r$pass, 'extra row fails')
check(any(r$violations$kind == 'row_extra'), 'reports row_extra')

cat('\n--- schema diff ---\n')
actual <- reference; actual$new_col <- 1
r <- compare_parity(actual, reference, key, 'schema_extra')
check(any(r$violations$kind == 'schema_extra_column' & r$violations$column == 'new_col'),
      'reports extra column')
r <- compare_parity(actual, reference, key, 'allowed_schema_extra',
                    allow_extra_cols = 'new_col')
check(r$pass, 'explicitly allowed candidate-only column passes a migration gate')
actual <- reference; actual$rate_301 <- NULL
r <- compare_parity(actual, reference, key, 'schema_missing')
check(any(r$violations$kind == 'schema_missing_column' & r$violations$column == 'rate_301'),
      'reports missing column')

cat('\n--- exact (non-numeric) columns ---\n')
actual <- reference; actual$usmca_eligible[1] <- TRUE        # was FALSE
r <- compare_parity(actual, reference, key, 'logical_mismatch')
check(!r$pass, 'logical flip is a violation')
actual <- reference; actual$effective_date[1] <- as.Date('2025-04-03')
r <- compare_parity(actual, reference, key, 'date_mismatch')
check(!r$pass, 'date change is a violation')

cat('\n--- column classification ---\n')
check(classify_parity_column('rate_232') == 'rate', 'rate_232 -> rate')
check(classify_parity_column('metal_share') == 'share', 'metal_share -> share')
check(classify_parity_column('weighted_etr') == 'etr', 'weighted_etr -> etr')
check(classify_parity_column('mean_total_rate') == 'etr', 'mean_total_rate -> etr')

cat(sprintf('\nALL %d PARITY ASSERTIONS PASSED\n', pass_count))
