#!/usr/bin/env Rscript
# Compute daily beef tariffs by authority, import-weighted.
#
# Beef = HTS10 starting with 0201 (fresh/chilled) or 0202 (frozen) bovine meat.
# Weights = 2024 monthly census imports summed to annual hs10 x cty_code.
#
# Outputs:
#   output/beef/beef_tariffs_by_authority_daily.csv     (date x authority)
#   output/beef/beef_tariffs_by_country_authority_daily.csv (date x country x authority)
#
# Net authority decomposition uses mutual_exclusion stacking (matches Tariff-ETRs):
# under 232, IEEPA/fent/s122 are scaled by nonmetal_share; 301 only on China.

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})

source(here('src', 'helpers.R'))
source(here('src', 'stacking.R'))
source(here('src', 'policy_params.R'))

BEEF_PREFIXES <- c('0201', '0202')
OUT_DIR <- here('output', 'beef')
dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)

message('Loading rate timeseries...')
ts <- readRDS(here('data', 'timeseries', 'rate_timeseries.rds'))

message('Filtering to beef HTS10 (0201*, 0202*)...')
ts_beef <- ts %>%
  filter(substr(hts10, 1, 4) %in% BEEF_PREFIXES)
rm(ts); invisible(gc())

message('  ', nrow(ts_beef), ' rows; ',
        n_distinct(ts_beef$hts10), ' HTS10; ',
        n_distinct(ts_beef$country), ' countries; ',
        n_distinct(ts_beef$revision), ' revisions.')

message('Loading 2024 census imports and aggregating annual...')
imports <- read_csv(here('data', 'census_imports_2024.csv'),
                    col_types = cols(hs10 = 'c', cty_code = 'c',
                                     con_val_mo = 'd', .default = '?')) %>%
  filter(substr(hs10, 1, 4) %in% BEEF_PREFIXES) %>%
  group_by(hs10, cty_code) %>%
  summarise(imports = sum(con_val_mo, na.rm = TRUE), .groups = 'drop')
message('  ', nrow(imports), ' beef hs10 x cty pairs; $',
        round(sum(imports$imports) / 1e6, 1), 'M total 2024 imports.')

message('Loading policy params (for s122 / Swiss expiry handling)...')
policy_params <- tryCatch(load_policy_params(), error = function(e) NULL)
CTY_CHINA <- if (!is.null(policy_params)) policy_params$CTY_CHINA %||% '5700' else '5700'

# --- Revision intervals + expiry sub-splits ---
rev_intervals <- ts_beef %>%
  distinct(revision, valid_from, valid_until) %>%
  arrange(valid_from)

expand_subintervals <- function(rev_intervals, policy_params) {
  map_dfr(seq_len(nrow(rev_intervals)), function(i) {
    r <- rev_intervals[i, ]
    splits <- get_expiry_split_points(r$valid_from, r$valid_until, policy_params)
    if (length(splits) == 0) {
      tibble(revision = r$revision, sub_start = r$valid_from, sub_end = r$valid_until)
    } else {
      bounds <- sort(unique(c(r$valid_from, splits + 1, r$valid_until + 1)))
      tibble(
        revision = r$revision,
        sub_start = head(bounds, -1),
        sub_end   = tail(bounds, -1) - 1
      )
    }
  })
}

sub_intervals <- expand_subintervals(rev_intervals, policy_params)
message('  ', nrow(rev_intervals), ' revisions -> ',
        nrow(sub_intervals), ' sub-intervals after expiry splits.')

# Pre-join imports to the beef timeseries once
ts_beef_w <- ts_beef %>%
  inner_join(imports, by = c('hts10' = 'hs10', 'country' = 'cty_code'))
message('  Weighted (matched) rows: ', nrow(ts_beef_w))

country_totals <- imports %>%
  group_by(cty_code) %>%
  summarise(country_beef_imports = sum(imports), .groups = 'drop') %>%
  rename(country = cty_code)
total_beef_imports <- sum(imports$imports)

# Net authority columns produced by compute_net_authority_contributions
auth_cols <- c('net_232', 'net_301', 'net_ieepa', 'net_fentanyl',
               'net_s122', 'net_section_201', 'net_other')
etr_cols <- sub('net_', 'etr_', auth_cols)

# --- Aggregate per sub-interval ---
compute_overall <- function(rev_id, sub_start) {
  d <- ts_beef_w %>% filter(revision == rev_id)
  d <- apply_expiry_zeroing(d, sub_start, policy_params)
  d <- compute_net_authority_contributions(d, cty_china = CTY_CHINA,
                                           stacking_method = 'mutual_exclusion')
  out <- tibble(!!!setNames(
    lapply(auth_cols, function(c) sum(d[[c]] * d$imports) / total_beef_imports),
    etr_cols
  ))
  out$etr_total <- sum(d$total_rate * d$imports) / total_beef_imports
  out$etr_additional <- sum(d$total_additional * d$imports) / total_beef_imports
  out$matched_imports <- sum(d$imports)
  out$total_beef_imports <- total_beef_imports
  out
}

compute_country <- function(rev_id, sub_start) {
  d <- ts_beef_w %>% filter(revision == rev_id)
  d <- apply_expiry_zeroing(d, sub_start, policy_params)
  d <- compute_net_authority_contributions(d, cty_china = CTY_CHINA,
                                           stacking_method = 'mutual_exclusion')
  d %>%
    group_by(country) %>%
    summarise(
      across(all_of(auth_cols),
             ~ sum(.x * imports) / sum(imports),
             .names = '{.col}'),
      rate_total = sum(total_rate * imports) / sum(imports),
      rate_additional = sum(total_additional * imports) / sum(imports),
      matched_imports = sum(imports),
      .groups = 'drop'
    ) %>%
    rename_with(~ sub('^net_', 'rate_', .x))
}

message('Computing per-interval aggregates...')
agg_overall <- sub_intervals %>%
  mutate(metrics = map2(revision, sub_start, compute_overall)) %>%
  unnest(metrics)

agg_country <- sub_intervals %>%
  mutate(metrics = map2(revision, sub_start, compute_country)) %>%
  unnest(metrics)

# --- Expand to daily panel ---
expand_daily <- function(df) {
  df %>%
    mutate(date = map2(sub_start, sub_end, ~ seq.Date(.x, .y, by = 'day'))) %>%
    unnest(date) %>%
    select(-sub_start, -sub_end) %>%
    relocate(date) %>%
    arrange(date)
}

message('Expanding to daily panel...')
daily_overall <- expand_daily(agg_overall)
daily_country <- expand_daily(agg_country) %>%
  left_join(country_totals, by = 'country') %>%
  arrange(date, country)

# --- Write ---
overall_path <- file.path(OUT_DIR, 'beef_tariffs_by_authority_daily.csv')
country_path <- file.path(OUT_DIR, 'beef_tariffs_by_country_authority_daily.csv')
write_csv(daily_overall, overall_path)
write_csv(daily_country, country_path)

message('Wrote:')
message('  ', overall_path, '  (', nrow(daily_overall), ' rows)')
message('  ', country_path, '  (', nrow(daily_country), ' rows)')

# Sanity print
message('\nSample (~monthly) of overall:')
print(daily_overall %>%
        filter(as.integer(format(date, '%d')) == 1) %>%
        select(date, etr_total, etr_232, etr_ieepa, etr_fentanyl,
               etr_s122, etr_301, etr_other))
