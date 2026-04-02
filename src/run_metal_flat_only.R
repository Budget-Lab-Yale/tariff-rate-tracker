# =============================================================================
# Run Metal Flat 100 Alternative Only
# =============================================================================
# Rebuilds the timeseries with flat 100% metal content shares, then
# pre-splits by revision before aggregation to reduce peak memory.
#
# Usage: Rscript src/run_metal_flat_only.R
# =============================================================================

library(here)
library(tidyverse)
library(jsonlite)
library(yaml)

source(here('src', 'helpers.R'))
source(here('src', '03_parse_chapter99.R'))
source(here('src', '04_parse_products.R'))
source(here('src', '05_parse_policy_params.R'))
source(here('src', '06_calculate_rates.R'))
source(here('src', '09_daily_series.R'))

pp <- load_policy_params()
imports <- load_import_weights()

message('\n', strrep('=', 70))
message('ALTERNATIVE: Flat 100% metal content shares')
message(strrep('=', 70))

pp_metal <- pp
pp_metal$metal_content$method <- 'flat'
pp_metal$metal_content$flat_share <- 1.0

# --- Rebuild timeseries (same as build_alternative_timeseries but without
#     calling build_daily_aggregates at the end) ---

calc_env <- environment(calculate_rates_for_revision)
original_pp <- calc_env$.pp
calc_env$.pp <- pp_metal
on.exit(calc_env$.pp <- original_pp, add = TRUE)

rev_dates <- load_revision_dates(here('config', 'revision_dates.csv'))
census_codes <- read_csv(here('resources', 'census_codes.csv'),
                         col_types = cols(.default = col_character()))
countries <- census_codes$Code
country_lookup <- build_country_lookup(here('resources', 'census_codes.csv'))

all_revisions <- rev_dates$revision
available <- get_available_revisions_all_years(all_revisions,
                                                here('data', 'hts_archives'))
revisions_to_process <- all_revisions[all_revisions %in% available]

snapshots <- list()
for (rev_id in revisions_to_process) {
  rev_info <- rev_dates %>% filter(revision == rev_id)
  eff_date <- rev_info$effective_date

  tryCatch({
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
      policy_params = pp_metal
    )
    snapshots[[rev_id]] <- rates
    gc()
  }, error = function(e) {
    message('    SKIP ', rev_id, ': ', conditionMessage(e))
  })
}

if (length(snapshots) == 0) {
  stop('No snapshots built')
}

# Combine into timeseries
timeseries <- bind_rows(snapshots)
rm(snapshots); gc()

timeseries <- enforce_rate_schema(timeseries)
timeseries <- timeseries %>% arrange(effective_date, revision, country, hts10)

horizon_end <- pp_metal$SERIES_HORIZON_END %||% Sys.Date()
last_eff <- max(rev_dates$effective_date[rev_dates$revision %in%
                                          unique(timeseries$revision)])
if (horizon_end < last_eff) horizon_end <- last_eff

rev_intervals <- rev_dates %>%
  filter(revision %in% unique(timeseries$revision)) %>%
  arrange(effective_date) %>%
  mutate(
    valid_from = effective_date,
    valid_until = lead(effective_date) - 1
  ) %>%
  mutate(valid_until = if_else(is.na(valid_until), horizon_end, valid_until)) %>%
  select(revision, valid_from, valid_until)

timeseries <- timeseries %>%
  select(-any_of(c('valid_from', 'valid_until'))) %>%
  left_join(rev_intervals, by = 'revision')

message('\nTimeseries built: ', nrow(timeseries), ' rows, ',
        n_distinct(timeseries$revision), ' revisions')
message('Peak object size: ', round(object.size(timeseries) / 1e9, 2), ' GB')

# --- Pre-split by revision to reduce peak memory in aggregation ---
message('\nPre-splitting timeseries by revision to reduce memory...')
ts_split <- split(timeseries, timeseries$revision)
rm(timeseries); gc()

# Build daily aggregates revision-by-revision
message('Building daily aggregates revision-by-revision...')

total_imports <- sum(imports$imports)
imports_lookup <- imports %>% select(hs10, cty_code, imports)

agg_rows <- list()
for (rev_id in names(ts_split)) {
  rev_data <- ts_split[[rev_id]]
  rev_interval <- rev_intervals %>% filter(revision == rev_id)
  if (nrow(rev_interval) == 0) next

  valid_from <- rev_interval$valid_from
  valid_until <- rev_interval$valid_until

  rev_data <- apply_expiry_zeroing(rev_data, valid_from, pp_metal)
  if (any(c('rate_s122', 'rate_ieepa_recip') %in% names(rev_data))) {
    rev_data <- apply_stacking_rules(rev_data)
  }

  n_products <- n_distinct(rev_data$hts10)
  n_countries <- n_distinct(rev_data$country)
  n_pairs <- nrow(rev_data)
  n_all_pairs <- n_products * n_countries

  row <- tibble(
    revision = rev_id,
    valid_from = valid_from,
    valid_until = valid_until,
    mean_additional_exposed = mean(rev_data$total_additional),
    mean_total_exposed = mean(rev_data$total_rate),
    mean_additional_all_pairs = sum(rev_data$total_additional) / n_all_pairs,
    mean_total_all_pairs = sum(rev_data$total_rate) / n_all_pairs,
    n_products = n_products,
    n_countries = n_countries,
    n_pairs = n_pairs,
    n_all_pairs = n_all_pairs
  )

  # Weighted ETR
  wt_data <- rev_data %>%
    inner_join(imports_lookup, by = c('hts10' = 'hs10', 'country' = 'cty_code'))
  if (nrow(wt_data) > 0) {
    row$weighted_etr <- sum(wt_data$total_rate * wt_data$imports) / total_imports
    row$weighted_etr_additional <- sum(wt_data$total_additional * wt_data$imports) / total_imports
    row$matched_imports_b <- sum(wt_data$imports) / 1e9
    row$total_imports_b <- total_imports / 1e9
  } else {
    row$weighted_etr <- 0
    row$weighted_etr_additional <- 0
    row$matched_imports_b <- 0
    row$total_imports_b <- total_imports / 1e9
  }

  agg_rows[[rev_id]] <- row
  message('  ', rev_id, ': ETR=', round(row$weighted_etr * 100, 2), '%')
}

agg_overall <- bind_rows(agg_rows)

# Expand to daily
expand_intervals <- function(df) {
  df %>%
    rowwise() %>%
    mutate(date = list(seq.Date(valid_from, valid_until, by = 'day'))) %>%
    unnest(date) %>%
    ungroup()
}

daily_overall <- expand_intervals(agg_overall)
daily_overall <- daily_overall %>% mutate(variant = 'metal_flat_100')

# Save
out_dir <- here('output', 'alternative')
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
write_csv(daily_overall, file.path(out_dir, 'daily_overall_metal_flat_100.csv'))
message('\nSaved: daily_overall_metal_flat_100.csv (', nrow(daily_overall), ' rows)')

message('\n', strrep('=', 70))
message('DONE')
message(strrep('=', 70))
