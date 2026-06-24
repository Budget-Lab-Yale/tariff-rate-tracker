suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})
source(here::here("src", "helpers.R"))
source(here::here("src", "09_daily_series.R"))

alt <- here::here("output", "alternative")
eu  <- as.character(get_country_constants()$EU27_CODES)

read_pair <- function(name) {
  bind_rows(
    read_csv(file.path(alt, paste0(name, "_baseline.csv")),     show_col_types = FALSE) %>%
      mutate(variant = "baseline"),
    read_csv(file.path(alt, paste0(name, "_eu_auto_25pct.csv")), show_col_types = FALSE) %>%
      mutate(variant = "eu_auto_25pct")
  )
}

# ---------- Overall daily ETR comparison ----------
ovr <- read_pair("daily_overall")
key_dates <- as.Date(c("2026-05-03", "2026-05-04", "2026-07-23", "2026-07-24"))
cat("=== Overall daily ETR (baseline vs eu_auto_25pct) ===\n")
print(as.data.frame(
  ovr %>% filter(date %in% key_dates) %>%
    select(date, variant, weighted_etr) %>%
    pivot_wider(names_from = variant, values_from = weighted_etr) %>%
    mutate(delta_pp = (eu_auto_25pct - baseline) * 100) %>%
    mutate(across(c(baseline, eu_auto_25pct), ~round(.*100, 4)),
           delta_pp = round(delta_pp, 4)) %>%
    arrange(date)
))

# ---------- EU-aggregate import-weighted ETR ----------
imports <- load_import_weights()
ct_totals <- imports %>%
  group_by(country = as.character(cty_code)) %>%
  summarise(country_imports = sum(imports), .groups = "drop")

ct <- read_pair("by_country") %>%
  mutate(country = as.character(country)) %>%
  left_join(ct_totals, by = "country")

eu_agg <- function(filt, label) {
  ct %>% filter(filt(.)) %>%
    group_by(variant) %>%
    summarise(
      eu_etr_pct  = sum(weighted_etr * country_imports * (country %in% eu), na.rm = TRUE) /
                    sum(country_imports * (country %in% eu)  * !is.na(weighted_etr), na.rm = TRUE) * 100,
      all_etr_pct = sum(weighted_etr * country_imports, na.rm = TRUE) /
                    sum(country_imports * !is.na(weighted_etr), na.rm = TRUE) * 100,
      .groups = "drop"
    ) %>%
    mutate(period = label)
}

covers <- function(d, target) {
  td <- as.Date(target)
  d$valid_from <= td & (is.na(d$valid_until) | d$valid_until >= td)
}
eu_pre  <- eu_agg(\(d) covers(d, "2026-05-03"), "pre 2026-05-04         (S122 active)")
eu_mid  <- eu_agg(\(d) covers(d, "2026-05-04"), "2026-05-04 to 2026-07-23 (S122 active)")
eu_post <- eu_agg(\(d) covers(d, "2026-07-24"), "2026-07-24+              (S122 expired)")

eu_cmp <- bind_rows(eu_pre, eu_mid, eu_post) %>%
  pivot_wider(names_from = variant, values_from = c(eu_etr_pct, all_etr_pct)) %>%
  mutate(
    eu_delta_pp  = eu_etr_pct_eu_auto_25pct  - eu_etr_pct_baseline,
    all_delta_pp = all_etr_pct_eu_auto_25pct - all_etr_pct_baseline
  ) %>%
  mutate(across(where(is.numeric), ~round(., 3)))

cat("\n=== EU-aggregate import-weighted ETR (baseline vs eu_auto_25pct) ===\n")
print(as.data.frame(eu_cmp %>% select(period,
                                      eu_baseline    = eu_etr_pct_baseline,
                                      eu_floor       = eu_etr_pct_eu_auto_25pct,
                                      eu_delta_pp,
                                      all_baseline   = all_etr_pct_baseline,
                                      all_floor      = all_etr_pct_eu_auto_25pct,
                                      all_delta_pp)))

# ---------- MVH (motor vehicles) sector ----------
sect <- read_pair("by_category") %>% filter(gtap_code == "MVH")
pick <- function(target) sect %>% filter(covers(., target)) %>%
  select(variant, weighted_etr) %>%
  mutate(period = paste0("interval covering ", target))
sect_cmp <- bind_rows(pick("2026-05-03"), pick("2026-05-04"), pick("2026-07-24")) %>%
  pivot_wider(names_from = variant, values_from = weighted_etr) %>%
  mutate(delta_pp = (eu_auto_25pct - baseline) * 100,
         across(c(baseline, eu_auto_25pct), ~round(.*100, 3)),
         delta_pp = round(delta_pp, 3))

cat("\n=== MVH (motor vehicles) ETR ===\n")
print(as.data.frame(sect_cmp))
