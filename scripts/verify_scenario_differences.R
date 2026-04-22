# Sanity-check the three scenario snapshot sets against h2avg (production default).
#
# Expectations:
#   usmca_none    -- CA/MX total_rate should be >= h2avg (no USMCA preference)
#   usmca_2024    -- post-2025 revisions should differ from h2avg (pre-tariff shares
#                    are lower than H2 2025 shares)
#   usmca_monthly -- per-revision shares vary; overall CA/MX mean should be close
#                    to h2avg, but per-revision differences expected
#
# For each scenario, compare one mid-2025 revision (rev_17, 2025-07-01) as
# a representative sample.

suppressPackageStartupMessages({
  library(here)
  library(dplyr)
  library(purrr)
})

REPRESENTATIVE_REV <- 'rev_17'  # July 2025, mid-year, full USMCA context
CTY_CANADA <- '1220'
CTY_MEXICO <- '2010'

TOP_SNAP <- here('data', 'timeseries', paste0('snapshot_', REPRESENTATIVE_REV, '.rds'))
if (!file.exists(TOP_SNAP)) {
  stop('Top-level snapshot missing: ', TOP_SNAP)
}

top <- readRDS(TOP_SNAP)
camx <- top %>% filter(country %in% c(CTY_CANADA, CTY_MEXICO))
cat(sprintf('Baseline (h2avg, %s): %d CA/MX rows, mean total_rate=%.4f\n',
            REPRESENTATIVE_REV, nrow(camx), mean(camx$total_rate)))

results <- map_dfr(c('usmca_none', 'usmca_2024', 'usmca_monthly'), function(scn) {
  snap_path <- here('data', 'timeseries', scn, paste0('snapshot_', REPRESENTATIVE_REV, '.rds'))
  if (!file.exists(snap_path)) {
    return(tibble(scenario = scn, status = 'MISSING', detail = snap_path))
  }
  scn_data <- readRDS(snap_path)
  camx_scn <- scn_data %>% filter(country %in% c(CTY_CANADA, CTY_MEXICO))

  cmp <- inner_join(
    camx %>% select(hts10, country, total_rate_h2avg = total_rate,
                    base_rate_h2avg = base_rate),
    camx_scn %>% select(hts10, country, total_rate_scn = total_rate,
                         base_rate_scn = base_rate),
    by = c('hts10', 'country')
  )
  diff <- cmp$total_rate_scn - cmp$total_rate_h2avg
  tibble(
    scenario = scn,
    status = 'OK',
    n_cmp = nrow(cmp),
    mean_total_rate_scn = round(mean(cmp$total_rate_scn), 4),
    mean_total_rate_h2avg = round(mean(cmp$total_rate_h2avg), 4),
    mean_diff = round(mean(diff), 4),
    n_scn_higher = sum(diff > 1e-10),
    n_scn_lower = sum(diff < -1e-10),
    n_equal = sum(abs(diff) <= 1e-10)
  )
})

cat('\nScenario diffs vs h2avg (CA/MX only, ', REPRESENTATIVE_REV, '):\n', sep = '')
print(results, n = Inf, width = 200)

cat('\nInterpretation:\n')
cat('  usmca_none: expect mean_diff > 0 (no preference = higher rates),\n')
cat('              n_scn_higher >> n_scn_lower.\n')
cat('  usmca_2024: expect small mean_diff, sign depends on rate direction.\n')
cat('  usmca_monthly: expect some differences, magnitude varies.\n')
