suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})
source(here('src', 'helpers.R'))
source(here('src', 'apply_scenarios.R'))
source(here('src', '09_daily_series.R'))

snap <- readRDS(here('data', 'timeseries', 'snapshot_2026_rev_6.rds'))
pp <- load_policy_params()
spec <- yaml::read_yaml(here('config', 'scenarios.yaml'))[['eu_auto_25pct']]

eu <- pp$EU27_CODES
auto_prefixes <- c('870322','870323','870324','870331','870332','870333','870334',
                   '870340','870350','870360','870370','870380','870390',
                   '87042101','87043101','87044100','87045100')
prefix_re <- paste0('^(', paste(auto_prefixes, collapse = '|'), ')')

build_state <- function(s122_active, patch_active, label) {
  s <- snap
  s$valid_from <- as.Date('2026-05-04')
  if (!s122_active) {
    s$rate_s122 <- 0
  }
  if (patch_active) {
    s <- apply_scenario_spec(s, spec, 'eu_auto_25pct',
                              valid_from = as.Date('2026-05-04'), pp = pp)
  } else {
    s <- apply_stacking_rules(s, pp$CTY_CHINA)
  }
  list(label = label, df = s)
}

states <- list(
  build_state(TRUE,  FALSE, 'baseline_s122_on'),
  build_state(TRUE,  TRUE,  'scenario_s122_on'),
  build_state(FALSE, FALSE, 'baseline_s122_off'),
  build_state(FALSE, TRUE,  'scenario_s122_off')
)

# --- Per-row summary on EU autos (cars + light trucks) ---
cat('\n=== EU autos (cars + light trucks) — per-row averages ===\n')
for (st in states) {
  rows <- st$df %>% filter(country %in% eu, grepl(prefix_re, hts10))
  cat(sprintf('%-22s n=%d  mean rate_232=%.4f  mean rate_s122=%.4f  mean metal_share=%.3f  mean total_rate=%.4f\n',
              st$label, nrow(rows),
              mean(rows$rate_232), mean(rows$rate_s122),
              mean(rows$metal_share), mean(rows$total_rate)))
}

# --- Region weighted ETR for EU under each state ---
imports <- load_import_weights()
country_total_imports <- imports %>%
  group_by(country = cty_code) %>%
  summarise(country_total_imports = sum(imports), .groups = 'drop') %>%
  mutate(country = as.character(country))

eu_denom <- country_total_imports %>%
  filter(country %in% eu) %>%
  pull(country_total_imports) %>%
  sum()

cat('\n=== EU region weighted ETR (computed from snapshot) ===\n')
cat(sprintf('EU total imports: $%.1fB\n', eu_denom / 1e9))
for (st in states) {
  wt <- st$df %>%
    filter(country %in% eu) %>%
    inner_join(imports %>% select(hs10, cty_code, imports),
               by = c('hts10' = 'hs10', 'country' = 'cty_code'))
  wetr <- sum(wt$total_rate * wt$imports) / eu_denom
  cat(sprintf('%-22s weighted_etr = %.4f\n', st$label, wetr))
}

# --- Decompose: for each EU country, how much do autos contribute to weighted_etr? ---
cat('\n=== Per-country auto contribution to EU weighted ETR ===\n')
for (st in states) {
  wt_autos <- st$df %>%
    filter(country %in% eu, grepl(prefix_re, hts10)) %>%
    inner_join(imports %>% select(hs10, cty_code, imports),
               by = c('hts10' = 'hs10', 'country' = 'cty_code'))
  contrib <- sum(wt_autos$total_rate * wt_autos$imports) / eu_denom
  cat(sprintf('%-22s autos contribution to EU weighted ETR = %.4f  (auto imports: $%.1fB)\n',
              st$label, contrib, sum(wt_autos$imports) / 1e9))
}
