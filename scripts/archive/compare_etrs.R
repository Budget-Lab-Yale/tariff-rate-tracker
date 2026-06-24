## Compare Tracker ETRs vs Tariff-ETRs at 3 dates
## Uses daily series output (already aggregated) + per-date snapshot computation

library(tidyverse)
library(here)

source(here('src', 'helpers.R'))

# ---- Tariff-ETRs benchmark data (from 2-21_temp scenario) ----
# Load path from config/local_paths.yaml; fall back to relative path
local_cfg <- tryCatch(yaml::read_yaml(here('config', 'local_paths.yaml')), error = function(e) list())
etrs_repo <- local_cfg$tariff_etrs_repo %||% file.path('..', 'Tariff-ETRs')
etrs_path <- file.path(etrs_repo, 'output', '2-21_temp', 'levels_by_census_country.csv')
if (!file.exists(etrs_path)) stop('Tariff-ETRs benchmark not found: ', etrs_path,
  '\nSet tariff_etrs_repo in config/local_paths.yaml')
etrs <- read_csv(etrs_path, col_types = cols(
  date = col_date(),
  cty_code = col_character(),
  country_name = col_character(),
  level = col_double()
))

cat('Tariff-ETRs data loaded:', nrow(etrs), 'rows\n')
cat('Dates:', paste(unique(etrs$date), collapse = ', '), '\n')

# ---- Load our imports for weighting ----
# Uses the same Census import data vintage as the daily weighted series.
imports_raw <- readRDS(file.path(etrs_repo, 'cache', 'hs10_by_country_gtap_2024_con.rds'))
imports <- imports_raw %>%
  group_by(hs10, cty_code) %>%
  summarise(value = sum(imports), .groups = 'drop') %>%
  filter(value > 0) %>%
  rename(hts10 = hs10, country_code = cty_code)

# Total imports across all products (denominator for ETR)
# Snapshot only has products with Ch99 exposure; unmatched products have 0% additional tariff
total_imports_all <- sum(imports$value)
cat('Total imports (all products):', round(total_imports_all / 1e9, 1), 'B\n')

# Country-level total imports (for country ETR denominator)
country_total_imports <- imports %>%
  group_by(country_code) %>%
  summarise(total_value = sum(value), .groups = 'drop')

# ---- Policy params for partner groupings ----
pp <- load_policy_params()

eu27 <- pp$EU27_CODES
partner_labels <- c('China' = '5700', 'Canada' = '1220', 'Mexico' = '2010',
                     'Japan' = '5880', 'UK' = '4120')

# ---- HTS concordance for import code remapping ----
concordance <- load_hts_concordance()
cat('HTS concordance:', nrow(concordance), 'entries\n')

# ---- Process each date by loading the appropriate snapshot ----
# Map dates to revisions
rev_dates <- load_revision_dates(here('config', 'revision_dates.csv'))

# For each ETRs date, find the active revision
comparison_dates <- unique(etrs$date)

results <- list()

for (d in comparison_dates) {
  d <- as.Date(d, origin = '1970-01-01')
  cat('\n', strrep('=', 60), '\n')
  cat('Date:', as.character(d), '\n')
  cat(strrep('=', 60), '\n')

  # Find active revision for this date
  active_rev <- rev_dates %>%
    filter(effective_date <= d) %>%
    slice_max(effective_date, n = 1) %>%
    pull(revision)

  cat('Active revision:', active_rev, '\n')

  # Load snapshot for this revision
  snap_path <- here('data', 'timeseries', paste0('snapshot_', active_rev, '.rds'))
  if (!file.exists(snap_path)) {
    cat('  Snapshot not found:', snap_path, '\n')
    next
  }

  rates <- readRDS(snap_path)
  cat('  Snapshot rows:', nrow(rates), '\n')

  # Apply S122 expiry and IEEPA invalidation.
  # After zeroing, reconstruct total_additional from non-stacking components
  # (rate_232, rate_301, rate_section_201 are already effective/scaled in the snapshot).
  # Cannot subtract raw rate_s122/rate_ieepa from total_additional because stacking
  # rules (metal_share) mean effective contribution differs from raw rate.
  needs_reconstruct <- FALSE

  s122_cfg <- pp$SECTION_122
  if (!is.null(s122_cfg)) {
    s122_expiry <- as.Date(s122_cfg$expiry_date)
    s122_effective <- as.Date(s122_cfg$effective_date)

    if (d >= s122_effective && d <= s122_expiry) {
      cat('  S122 active (', as.character(s122_effective), ' to ', as.character(s122_expiry), ')\n')
    } else if (d > s122_expiry) {
      cat('  S122 expired — zeroing rate_s122\n')
      if ('rate_s122' %in% names(rates)) {
        rates$rate_s122 <- 0
        needs_reconstruct <- TRUE
      }
    } else {
      cat('  S122 not yet active\n')
    }
  }

  ieepa_inv <- pp$IEEPA_INVALIDATION_DATE
  if (!is.null(ieepa_inv)) {
    ieepa_inv <- as.Date(ieepa_inv)
    if (d >= ieepa_inv) {
      cat('  IEEPA invalidated as of', as.character(ieepa_inv), '— zeroing reciprocal + fentanyl\n')
      if ('rate_ieepa_recip' %in% names(rates)) {
        rates$rate_ieepa_recip <- 0
        rates$rate_ieepa_fent <- 0
        needs_reconstruct <- TRUE
      }
    } else {
      cat('  IEEPA active (invalidation:', as.character(ieepa_inv), ')\n')
    }
  }

  if (needs_reconstruct) {
    # Re-apply stacking rules after zeroing. Cannot use naive rowSums because
    # mutual exclusion scales rate_s122/rate_ieepa_recip by nonmetal_share
    # on 232 products — rowSums would overcount s122 on steel/aluminum.
    cty_china <- if (!is.null(pp)) pp$CTY_CHINA %||% '5700' else '5700'
    rates <- apply_stacking_rules(rates, cty_china = cty_china)
    cat('  Reconstructed total_rate via apply_stacking_rules()\n')
  }

  # Remap import codes via concordance (handles renumbered products across revisions)
  snapshot_codes <- unique(rates$hts10)
  imports_remapped <- remap_imports_via_concordance(
    imports %>% select(hts10, country_code, value),
    snapshot_codes, concordance
  )

  # Join with imports
  merged <- rates %>%
    inner_join(imports_remapped %>% select(hts10, country = country_code, value),
               by = c('hts10', 'country'))

  matched_imports <- sum(merged$value)
  cat('  Matched imports:', round(matched_imports / 1e9, 1), 'B of',
      round(total_imports_all / 1e9, 1), 'B (',
      round(matched_imports / total_imports_all * 100, 1), '%)\n')

  # Overall weighted ETR — use total imports as denominator
  # Unmatched products have 0% additional tariff (no Ch99 exposure)
  tariff_revenue <- sum(merged$total_rate * merged$value)
  overall_etr <- tariff_revenue / total_imports_all
  cat('  Overall ETR:', round(overall_etr * 100, 2), '%\n')

  # By country — use total country imports as denominator
  country_etrs <- merged %>%
    group_by(country) %>%
    summarise(
      matched_imports = sum(value),
      tariff_rev = sum(total_rate * value),
      .groups = 'drop'
    ) %>%
    left_join(country_total_imports, by = c('country' = 'country_code')) %>%
    mutate(
      imports = total_value,
      etr = tariff_rev / total_value
    ) %>%
    select(country, imports, etr) %>%
    arrange(desc(etr))

  # Compare with Tariff-ETRs
  etrs_at_date <- etrs %>%
    filter(date == d) %>%
    select(country = cty_code, etrs_level = level) %>%
    mutate(etrs_level = etrs_level / 100)  # Convert from pct to decimal

  comparison <- country_etrs %>%
    inner_join(etrs_at_date, by = 'country') %>%
    mutate(
      diff_pp = (etr - etrs_level) * 100,
      import_share = imports / total_imports_all
    )

  # Print key partners
  cat('\n  Country-Level Comparison (Census-weighted ETR):\n')
  cat(sprintf('  %-15s %8s %8s %8s\n', 'Country', 'Tracker', 'ETRs', 'Diff(pp)'))
  cat('  ', strrep('-', 45), '\n')

  for (pname in names(partner_labels)) {
    cty <- partner_labels[pname]
    row <- comparison %>% filter(country == cty)
    if (nrow(row) > 0) {
      cat(sprintf('  %-15s %7.2f%% %7.2f%% %+7.2f\n',
                  pname, row$etr * 100, row$etrs_level * 100, row$diff_pp))
    }
  }

  # EU aggregate — use total EU imports as denominator
  eu_data <- merged %>% filter(country %in% eu27)
  eu_total_imp <- country_total_imports %>% filter(country_code %in% eu27) %>% pull(total_value) %>% sum()
  if (nrow(eu_data) > 0 && eu_total_imp > 0) {
    eu_etr <- sum(eu_data$total_rate * eu_data$value) / eu_total_imp
    # ETRs EU aggregate
    eu_etrs <- etrs_at_date %>%
      filter(country %in% eu27) %>%
      inner_join(country_etrs %>% select(country, imports), by = 'country')
    if (nrow(eu_etrs) > 0) {
      eu_etrs_agg <- sum(eu_etrs$etrs_level * eu_etrs$imports) / sum(eu_etrs$imports)
      cat(sprintf('  %-15s %7.2f%% %7.2f%% %+7.2f\n',
                  'EU', eu_etr * 100, eu_etrs_agg * 100, (eu_etr - eu_etrs_agg) * 100))
    }
  }

  # Overall — weight ETRs country levels by total country imports
  etrs_overall <- sum(comparison$etrs_level * comparison$imports) / sum(comparison$imports)
  cat(sprintf('  %-15s %7.2f%% %7.2f%% %+7.2f\n',
              'OVERALL', overall_etr * 100, etrs_overall * 100, (overall_etr - etrs_overall) * 100))

  results[[as.character(d)]] <- list(
    date = d,
    revision = active_rev,
    overall_tracker = overall_etr,
    overall_etrs = etrs_overall,
    comparison = comparison
  )

  rm(rates, merged)
  gc()
}

# ---- Summary table ----
cat('\n\n', strrep('=', 60), '\n')
cat('SUMMARY: Tracker vs Tariff-ETRs\n')
cat(strrep('=', 60), '\n\n')

cat(sprintf('%-12s %10s %10s %10s\n', 'Date', 'Tracker', 'ETRs', 'Diff(pp)'))
cat(strrep('-', 45), '\n')
for (r in results) {
  cat(sprintf('%-12s %9.2f%% %9.2f%% %+9.2f\n',
              as.character(r$date),
              r$overall_tracker * 100, r$overall_etrs * 100,
              (r$overall_tracker - r$overall_etrs) * 100))
}

# Save comparison data
val_dir <- here('output', 'validation')
if (!dir.exists(val_dir)) dir.create(val_dir, recursive = TRUE)

all_comparisons <- map_dfr(results, function(r) {
  r$comparison %>% mutate(date = r$date, revision = r$revision)
})
write_csv(all_comparisons, file.path(val_dir, 'etrs_comparison_by_country.csv'))

cat('\nSaved to:', file.path(val_dir, 'etrs_comparison_by_country.csv'), '\n')
