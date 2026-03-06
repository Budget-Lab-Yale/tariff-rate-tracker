## TPC Validation: Full comparison across all 5 TPC dates
library(tidyverse)
library(jsonlite)
library(here)

source(here('src', '00_build_timeseries.R'))

# ---- CLI args ----
args <- commandArgs(trailingOnly = TRUE)
stacking_method <- if ('--tpc-stacking' %in% args) 'tpc_additive' else 'mutual_exclusion'
cat('Stacking method:', stacking_method, '\n')

# ---- Config ----
# Load revision dates to get TPC date mapping
rev_dates <- load_revision_dates(here('config', 'revision_dates.csv'))
tpc_revisions <- rev_dates %>% filter(!is.na(tpc_date)) %>% pull(revision)
tpc_map <- rev_dates %>% filter(!is.na(tpc_date)) %>% select(revision, effective_date, tpc_date)
cat('TPC validation dates:\n')
print(tpc_map)

# Load shared resources
census_codes <- read_csv(here('resources', 'census_codes.csv'), col_types = cols(.default = col_character()))
countries <- census_codes$Code
country_lookup <- build_country_lookup(here('resources', 'census_codes.csv'))
name_to_code <- create_country_name_map(census_codes)

# Load TPC data once
tpc_data <- load_tpc_data(here('data', 'tpc', 'tariff_by_flow_day.csv'), name_to_code)
tpc_dates <- unique(tpc_data$date)
cat('\nTPC dates available:', paste(tpc_dates, collapse = ', '), '\n')

# Load TPC-excluded countries (legitimate IEEPA entries TPC doesn't model)
pp <- load_policy_params()
tpc_excluded <- pp$tpc_excluded_countries %||% character(0)
if (length(tpc_excluded) > 0) {
  cat('\nExcluding', length(tpc_excluded), 'phantom IEEPA countries from TPC comparison\n')
}

# ---- Process each TPC revision ----
all_comparisons <- list()

for (i in seq_len(nrow(tpc_map))) {
  rev_id <- tpc_map$revision[i]
  eff_date <- tpc_map$effective_date[i]
  t_date <- tpc_map$tpc_date[i]

  cat('\n', strrep('=', 70), '\n')
  cat('Revision:', rev_id, '| Effective:', as.character(eff_date),
      '| TPC date:', as.character(t_date), '\n')
  cat(strrep('=', 70), '\n')

  # Parse and calculate
  json_path <- resolve_json_path(rev_id, here('data', 'hts_archives'))
  hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)
  ch99_data <- parse_chapter99(json_path)
  products <- parse_products(json_path)
  ieepa_rates <- extract_ieepa_rates(hts_raw, country_lookup)
  fentanyl_rates <- extract_ieepa_fentanyl_rates(hts_raw, country_lookup)
  s232_rates <- extract_section232_rates(ch99_data)
  usmca <- extract_usmca_eligibility(hts_raw)

  rates <- calculate_rates_for_revision(
    products, ch99_data, ieepa_rates, usmca,
    countries, rev_id, eff_date,
    s232_rates = s232_rates,
    fentanyl_rates = fentanyl_rates,
    stacking_method = stacking_method
  )

  # Compare to TPC
  tpc_at_date <- tpc_data %>%
    filter(date == t_date) %>%
    select(hts10, country = country_code, tpc_rate = tpc_rate_change)

  our_rates <- rates %>%
    select(hts10, country, base_rate, rate_232, rate_301,
           rate_ieepa_recip, rate_ieepa_fent, rate_other,
           total_additional)

  # Exclude phantom IEEPA countries from both sides
  if (length(tpc_excluded) > 0) {
    our_rates <- our_rates %>% filter(!country %in% tpc_excluded)
    tpc_at_date <- tpc_at_date %>% filter(!country %in% tpc_excluded)
  }

  comparison <- tpc_at_date %>%
    inner_join(our_rates, by = c('hts10', 'country')) %>%
    mutate(
      diff = total_additional - tpc_rate,
      abs_diff = abs(diff),
      match_exact = abs_diff < 0.005,
      match_2pp = abs_diff < 0.02,
      match_5pp = abs_diff < 0.05
    )

  all_comparisons[[rev_id]] <- comparison %>% mutate(revision = rev_id, tpc_date = t_date)

  cat('\n  Comparisons: ', nrow(comparison), '\n')
  cat('  Exact match (<0.5pp): ', sum(comparison$match_exact),
      ' (', round(100 * mean(comparison$match_exact), 1), '%)\n')
  cat('  Within 2pp:          ', sum(comparison$match_2pp),
      ' (', round(100 * mean(comparison$match_2pp), 1), '%)\n')
  cat('  Within 5pp:          ', sum(comparison$match_5pp),
      ' (', round(100 * mean(comparison$match_5pp), 1), '%)\n')
  cat('  Mean abs diff:       ', round(mean(comparison$abs_diff) * 100, 2), 'pp\n')
  cat('  Median abs diff:     ', round(median(comparison$abs_diff) * 100, 2), 'pp\n')
}

# ---- Combined analysis ----
combined <- bind_rows(all_comparisons)

# Setup output directory
val_dir <- here('output', 'validation')
if (!dir.exists(val_dir)) dir.create(val_dir, recursive = TRUE)

# Save full comparison data
write_csv(combined, file.path(val_dir, 'tpc_comparison_all.csv'))

cat('\n\n', strrep('=', 70), '\n')
cat('OVERALL TPC COMPARISON SUMMARY\n')
cat(strrep('=', 70), '\n\n')

# Summary table by revision
cat('--- By Revision ---\n\n')
rev_summary <- combined %>%
  group_by(revision, tpc_date) %>%
  summarise(
    n = n(),
    pct_exact = round(mean(match_exact) * 100, 1),
    pct_2pp = round(mean(match_2pp) * 100, 1),
    pct_5pp = round(mean(match_5pp) * 100, 1),
    mean_diff = round(mean(diff) * 100, 2),
    mean_abs_diff = round(mean(abs_diff) * 100, 2),
    median_abs_diff = round(median(abs_diff) * 100, 2),
    .groups = 'drop'
  )
print(rev_summary)
write_csv(rev_summary, file.path(val_dir, 'tpc_summary_by_revision.csv'))

# ---- By country (top 20 countries by product count) ----
cat('\n--- By Country (top 20, latest revision) ---\n\n')
latest <- combined %>% filter(revision == tpc_revisions[length(tpc_revisions)])

# Get country names
cty_names <- setNames(census_codes$Name, census_codes$Code)

country_summary <- latest %>%
  group_by(country) %>%
  summarise(
    n = n(),
    pct_exact = round(mean(match_exact) * 100, 1),
    pct_2pp = round(mean(match_2pp) * 100, 1),
    mean_our = round(mean(total_additional) * 100, 1),
    mean_tpc = round(mean(tpc_rate) * 100, 1),
    mean_diff = round(mean(diff) * 100, 1),
    mean_abs_diff = round(mean(abs_diff) * 100, 1),
    .groups = 'drop'
  ) %>%
  filter(n >= 100) %>%
  mutate(name = cty_names[country]) %>%
  arrange(pct_exact) %>%
  head(20) %>%
  select(country, name, n, mean_our, mean_tpc, mean_diff, pct_exact, pct_2pp)

print(country_summary, n = 20)
write_csv(country_summary, file.path(val_dir, 'tpc_summary_by_country.csv'))

# ---- Best matching countries ----
cat('\n--- Best Matching Countries (latest revision) ---\n\n')
best_countries <- latest %>%
  group_by(country) %>%
  summarise(
    n = n(),
    pct_exact = round(mean(match_exact) * 100, 1),
    pct_2pp = round(mean(match_2pp) * 100, 1),
    mean_abs_diff = round(mean(abs_diff) * 100, 1),
    .groups = 'drop'
  ) %>%
  filter(n >= 100) %>%
  mutate(name = cty_names[country]) %>%
  arrange(desc(pct_exact)) %>%
  head(20) %>%
  select(country, name, n, pct_exact, pct_2pp, mean_abs_diff)

print(best_countries, n = 20)
write_csv(best_countries, file.path(val_dir, 'tpc_best_countries.csv'))

# ---- Discrepancy patterns ----
cat('\n--- Discrepancy Patterns (latest revision) ---\n\n')

# Breakdown: where is the gap?
cat('Products where we are HIGHER than TPC:\n')
higher <- latest %>% filter(diff > 0.02)
cat('  Count:', nrow(higher), '(', round(100 * nrow(higher) / nrow(latest), 1), '%)\n')
if (nrow(higher) > 0) {
  cat('  Mean excess: +', round(mean(higher$diff) * 100, 1), 'pp\n')
  cat('  Breakdown:\n')
  cat('    With IEEPA recip > 0:', sum(higher$rate_ieepa_recip > 0), '\n')
  cat('    With 232 > 0:', sum(higher$rate_232 > 0), '\n')
  cat('    With 301 > 0:', sum(higher$rate_301 > 0), '\n')
  cat('    With fentanyl > 0:', sum(higher$rate_ieepa_fent > 0), '\n')
}

cat('\nProducts where TPC is HIGHER than us:\n')
lower <- latest %>% filter(diff < -0.02)
cat('  Count:', nrow(lower), '(', round(100 * nrow(lower) / nrow(latest), 1), '%)\n')
if (nrow(lower) > 0) {
  cat('  Mean shortfall: ', round(mean(lower$diff) * 100, 1), 'pp\n')
  # Check if shortfall is ~25% (missing 301)
  shortfall_25 <- lower %>% filter(abs(diff + 0.25) < 0.03)
  cat('  Shortfall ~25pp (likely missing 301):', nrow(shortfall_25), '\n')
  # Check China specifically
  china_lower <- lower %>% filter(country == '5700')
  cat('  China products where TPC > us:', nrow(china_lower), '\n')
  if (nrow(china_lower) > 0) {
    cat('    Mean shortfall: ', round(mean(china_lower$diff) * 100, 1), 'pp\n')
    cat('    With our 301 = 0:', sum(china_lower$rate_301 == 0), '\n')
  }
}

# ---- China deep dive ----
cat('\n--- China Deep Dive (across all revisions) ---\n\n')
china_all <- combined %>% filter(country == '5700')
china_summary <- china_all %>%
  group_by(revision, tpc_date) %>%
  summarise(
    n = n(),
    pct_exact = round(mean(match_exact) * 100, 1),
    pct_2pp = round(mean(match_2pp) * 100, 1),
    mean_our = round(mean(total_additional) * 100, 1),
    mean_tpc = round(mean(tpc_rate) * 100, 1),
    mean_diff = round(mean(diff) * 100, 1),
    .groups = 'drop'
  )
print(china_summary)

# ---- Non-China countries: how well do IEEPA rates match? ----
cat('\n--- Non-China IEEPA Match (latest revision) ---\n\n')
non_china_ieepa <- latest %>%
  filter(country != '5700', rate_ieepa_recip > 0)

if (nrow(non_china_ieepa) > 0) {
  ieepa_match <- non_china_ieepa %>%
    group_by(country) %>%
    summarise(
      n = n(),
      our_ieepa = round(first(rate_ieepa_recip) * 100, 1),
      pct_exact = round(mean(match_exact) * 100, 1),
      pct_2pp = round(mean(match_2pp) * 100, 1),
      mean_diff = round(mean(diff) * 100, 1),
      .groups = 'drop'
    ) %>%
    mutate(name = cty_names[country]) %>%
    arrange(desc(pct_exact)) %>%
    head(25) %>%
    select(country, name, n, our_ieepa, pct_exact, pct_2pp, mean_diff)

  print(ieepa_match, n = 25)
}

# ---- Floor countries (EU, Japan, S. Korea) ----
cat('\n--- Floor Countries Detail ---\n\n')
floor_countries <- c('4280', '4279', '4759', '5880', '5800', '4419', '4411')
floor_names <- c('Germany', 'France', 'Italy', 'Japan', 'S. Korea', 'Switzerland', 'Liechtenstein')

for (j in seq_along(floor_countries)) {
  cty <- floor_countries[j]
  cty_data <- latest %>% filter(country == cty)
  if (nrow(cty_data) > 0) {
    cat(floor_names[j], '(', cty, '): ',
        nrow(cty_data), ' products, ',
        round(mean(cty_data$match_exact) * 100, 1), '% exact, ',
        round(mean(cty_data$match_2pp) * 100, 1), '% within 2pp, ',
        'mean diff: ', round(mean(cty_data$diff) * 100, 1), 'pp\n', sep = '')
  }
}

# ---- Duty-free IEEPA breakdown ----
cat('\n--- Duty-Free IEEPA Breakdown (latest revision) ---\n\n')

# Products with 0% MFN base rate where we charge IEEPA reciprocal but TPC doesn't
duty_free_diverge <- latest %>%
  filter(base_rate < 0.001, rate_ieepa_recip > 0, diff > 0.005)

cat('Duty-free products where we > TPC: ', nrow(duty_free_diverge), '\n')
cat('  As % of total comparisons: ', round(100 * nrow(duty_free_diverge) / nrow(latest), 1), '%\n')

if (nrow(duty_free_diverge) > 0) {
  cat('  Top chapters:\n')
  df_chapters <- duty_free_diverge %>%
    mutate(chapter = substr(hts10, 1, 2)) %>%
    count(chapter, name = 'n_products') %>%
    arrange(desc(n_products)) %>%
    head(10)
  print(df_chapters)
}

# Simulated match rate if duty-free excluded
n_current_match <- sum(latest$match_exact)
n_simulated_match <- n_current_match + nrow(duty_free_diverge)
cat('\nSimulated match rate if duty_free_treatment = nonzero_base_only:\n')
cat('  Current:   ', round(100 * n_current_match / nrow(latest), 1), '%\n')
cat('  Simulated: ', round(100 * n_simulated_match / nrow(latest), 1), '%\n')
cat('  Gain:      +', round(100 * nrow(duty_free_diverge) / nrow(latest), 1), 'pp\n')

# ---- Per-country-group summary for floor countries ----
cat('\n--- Floor Country Groups (latest revision) ---\n\n')

floor_group_summary <- latest %>%
  filter(country %in% pp$FLOOR_COUNTRIES) %>%
  mutate(
    country_group = case_when(
      country %in% pp$EU27_CODES ~ 'EU-27',
      country == pp$country_codes$CTY_JAPAN ~ 'Japan',
      country == pp$country_codes$CTY_SKOREA ~ 'S. Korea',
      country %in% c(pp$country_codes$CTY_SWITZERLAND,
                      pp$country_codes$CTY_LIECHTENSTEIN) ~ 'Swiss/Liecht.',
      TRUE ~ 'Other'
    )
  ) %>%
  group_by(country_group) %>%
  summarise(
    n = n(),
    pct_exact = round(mean(match_exact) * 100, 1),
    pct_2pp = round(mean(match_2pp) * 100, 1),
    mean_diff = round(mean(diff) * 100, 2),
    n_duty_free_gap = sum(base_rate < 0.001 & rate_ieepa_recip > 0 & diff > 0.005),
    .groups = 'drop'
  ) %>%
  arrange(desc(n))

print(floor_group_summary)
write_csv(floor_group_summary, file.path(val_dir, 'tpc_floor_group_summary.csv'))

# ---- Save validation metadata ----
validation_metadata <- list(
  run_time = Sys.time(),
  n_revisions = length(tpc_revisions),
  revisions = tpc_revisions,
  total_comparisons = nrow(combined),
  overall_exact_match = mean(combined$match_exact),
  overall_2pp_match = mean(combined$match_2pp),
  overall_5pp_match = mean(combined$match_5pp),
  mean_abs_diff = mean(combined$abs_diff),
  by_revision = rev_summary
)
saveRDS(validation_metadata, file.path(val_dir, 'tpc_validation_metadata.rds'))

cat('\nValidation outputs saved to: ', val_dir, '\n')
cat('\n', strrep('=', 70), '\n')
cat('TPC COMPARISON COMPLETE\n')
cat(strrep('=', 70), '\n')
