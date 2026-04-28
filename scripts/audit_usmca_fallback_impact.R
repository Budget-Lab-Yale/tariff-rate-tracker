#!/usr/bin/env Rscript
# Quantify the ETR impact of the monthly-USMCA fallback fix
# (commit ab6066a) under different USMCA-scenario × trade-weighting
# combinations.
#
# Scope: the ~1,300 (HTS10, country) pairs that traded in Dec 2025 with
# positive value but are absent from the Jan 2026 monthly file. Under the
# strict monthly loader they revert to usmca_share = 0 in 2026 revisions;
# under the fallback they inherit their Dec 2025 share (~90% value-weighted
# on this subset).
#
# Uses statutory_rate_* columns from rev_2026_rev_4 (latest in-window
# post-SCOTUS revision) so we apply USMCA scenarios analytically rather
# than rebuilding.

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tidyr)
  library(here)
})

# --- Identify affected pairs ----------------------------------------------
d12 <- read_csv(here("resources", "usmca_product_shares_2025_12.csv"),
                col_types = cols(hts10 = col_character(),
                                 cty_code = col_character(),
                                 .default = col_guess()),
                show_col_types = FALSE)
d01 <- read_csv(here("resources", "usmca_product_shares_2026_01.csv"),
                col_types = cols(hts10 = col_character(),
                                 cty_code = col_character(),
                                 .default = col_guess()),
                show_col_types = FALSE)

affected <- d12 %>%
  filter(!paste(hts10, cty_code) %in% paste(d01$hts10, d01$cty_code),
         total_value > 0) %>%
  select(hts10, cty_code, dec25_share = usmca_share)

cat("Affected pairs (in Dec 2025, absent from Jan 2026 with positive Dec trade):",
    nrow(affected), "\n")

# --- Pull statutory rates from rev_2026_rev_4 (latest in-window) ----------
snap <- readRDS(here("data", "timeseries", "snapshot_2026_rev_4.rds"))

# Use statutory_* columns (pre-USMCA, pre-stacking). The post-USMCA `rate_*`
# columns in this snapshot have already been scaled by the production
# h2_average shares (~88%) for CA/MX in step 7 of 06_calculate_rates.R, so
# applying scenario shares on top of them would double-scale. statutory_*
# fields are saved BEFORE the USMCA reduction at 06_calculate_rates.R
# step 6e and represent the legal rate the importer would owe absent any
# USMCA claim.
affected_rates <- snap %>%
  inner_join(affected, by = c("hts10", "country" = "cty_code")) %>%
  transmute(
    hts10, country,
    base_rate         = statutory_base_rate,
    rate_232          = statutory_rate_232,
    rate_301          = statutory_rate_301,
    rate_s122         = statutory_rate_s122,
    rate_ieepa_recip  = statutory_rate_ieepa_recip,
    rate_ieepa_fent   = statutory_rate_ieepa_fent,
    rate_section_201  = statutory_rate_section_201,
    rate_other        = statutory_rate_other,
    dec25_share, usmca_eligible
  )

cat("\nStatutory rate composition on the affected pairs (rev_2026_rev_4):\n")
rate_stack <- affected_rates %>%
  summarise(
    n_rows            = n(),
    base_rate_avg     = mean(base_rate, na.rm = TRUE),
    rate_232_avg      = mean(rate_232, na.rm = TRUE),
    rate_301_avg      = mean(rate_301, na.rm = TRUE),
    rate_s122_avg     = mean(rate_s122, na.rm = TRUE),
    rate_ieepa_avg    = mean(rate_ieepa_recip, na.rm = TRUE),
    rate_fent_avg     = mean(rate_ieepa_fent, na.rm = TRUE),
    rate_s201_avg     = mean(rate_section_201, na.rm = TRUE)
  )
print(rate_stack)

# --- Pull 2024 and Jan/Feb 2026 import weights ----------------------------
imp <- read_csv(here("data", "census_imports_2024.csv"),
                col_types = cols(hs10 = col_character(),
                                 cty_code = col_character(),
                                 con_val_mo = col_double(),
                                 year = col_integer(),
                                 month = col_integer(),
                                 .default = col_guess()),
                show_col_types = FALSE) %>%
  filter(cty_code %in% c("1220", "2010"))

w_2024 <- imp %>%
  group_by(hts10 = hs10, cty_code) %>%
  summarise(value_2024 = sum(con_val_mo, na.rm = TRUE), .groups = "drop")

imp25 <- read_csv(here("data", "census_imports_2025.csv"),
                  col_types = cols(hs10 = col_character(),
                                   cty_code = col_character(),
                                   con_val_mo = col_double(),
                                   year = col_integer(),
                                   month = col_integer(),
                                   .default = col_guess()),
                  show_col_types = FALSE) %>%
  filter(cty_code %in% c("1220", "2010"))

# Dec 2025: latest monthly data available in this repo (no 2026 census file
# yet — eval pulls 2026 IMDB from a sibling repo). Used as the post-tariff-
# steady-state monthly weight proxy.
w_dec25 <- imp25 %>%
  filter(year == 2025, month == 12) %>%
  group_by(hts10 = hs10, cty_code) %>%
  summarise(value_dec25 = sum(con_val_mo, na.rm = TRUE), .groups = "drop")

# Full 2025 annual: smoothed monthly weight.
w_2025 <- imp25 %>%
  filter(year == 2025) %>%
  group_by(hts10 = hs10, cty_code) %>%
  summarise(value_2025 = sum(con_val_mo, na.rm = TRUE), .groups = "drop")

# --- Build the comparison frame -------------------------------------------
ar <- affected_rates %>%
  left_join(w_2024,  by = c("hts10", "country" = "cty_code")) %>%
  left_join(w_dec25, by = c("hts10", "country" = "cty_code")) %>%
  left_join(w_2025,  by = c("hts10", "country" = "cty_code")) %>%
  mutate(
    value_2024  = coalesce(value_2024, 0),
    value_dec25 = coalesce(value_dec25, 0),
    value_2025  = coalesce(value_2025, 0)
  )

# Scalable rate (rates that USMCA reduces): base + s122 + ieepa + fent + 232 (when eligible)
ar <- ar %>%
  mutate(scalable_rate = base_rate + rate_s122 + rate_ieepa_recip +
                          rate_ieepa_fent + rate_232,
         non_scalable_rate = rate_301 + rate_section_201 + rate_other,
         total_statutory_rate = scalable_rate + non_scalable_rate)

# --- Scenario rates (per-pair effective rate under each scenario) ---------
# usmca_none: 0% utilization → no scaling
# usmca_monthly_strict (pre-fix): for these pairs, share = 0 → no scaling
# usmca_monthly_fallback (post-fix): use Dec 2025 share
# usmca_h2avg: ~88% steady-state (use 0.88 for the subset)
# usmca_2024: pre-tariff baseline (~30-40% for CA/MX) — use 0.40
ar <- ar %>%
  mutate(
    rate_none           = scalable_rate + non_scalable_rate,
    rate_monthly_strict = scalable_rate * (1 - 0)            + non_scalable_rate,
    rate_monthly_fb     = scalable_rate * (1 - dec25_share)  + non_scalable_rate,
    rate_h2avg          = scalable_rate * (1 - 0.88)         + non_scalable_rate,
    rate_2024           = scalable_rate * (1 - 0.40)         + non_scalable_rate
  )

scenarios <- c("rate_none", "rate_monthly_strict", "rate_monthly_fb",
               "rate_h2avg", "rate_2024")

# --- ETR aggregation under three weightings -------------------------------
# subset_etr: aggregate ETR over JUST the 1,022 affected pairs.
# This isolates the scenario-driven movement on those pairs.
agg_subset <- function(weight_col) {
  total_value <- sum(ar[[weight_col]], na.rm = TRUE)
  if (total_value == 0) return(setNames(rep(NA, length(scenarios)), scenarios))
  vapply(scenarios, function(s) {
    sum(ar[[s]] * ar[[weight_col]], na.rm = TRUE) / total_value
  }, numeric(1))
}

etr_subset_2024  <- agg_subset("value_2024")
etr_subset_dec25 <- agg_subset("value_dec25")
etr_subset_2025  <- agg_subset("value_2025")

cat("\n=== ETR on the affected subset only (subset ETR) ===\n")
cat("Shows how each scenario rates these specific pairs;\n")
cat("aggregation denominator is the subset's own trade value.\n\n")
print(round(rbind(
  weights_2024    = etr_subset_2024,
  weights_dec2025 = etr_subset_dec25,
  weights_2025_full = etr_subset_2025
) * 100, 2))

# --- All-imports denominator: how much aggregate ETR moves ---------------
# This is the question that matters for the eval Tier 1 / Tier 2 numbers:
# what fraction of total CA+MX imports do these pairs represent, and how
# much does the scenario delta on them shift the headline ETR?
total_2024  <- sum(w_2024$value_2024, na.rm = TRUE)
total_dec25 <- sum(w_dec25$value_dec25, na.rm = TRUE)
total_2025  <- sum(w_2025$value_2025, na.rm = TRUE)

cat("\n=== ETR contribution to TOTAL CA+MX imports (headline ETR delta) ===\n")
cat("Subset trade value as fraction of total CA+MX trade:\n")
cat(sprintf("  2024 weights:      $%6.1fB / $%6.1fB = %.4f%%\n",
            sum(ar$value_2024) / 1e9, total_2024 / 1e9,
            100 * sum(ar$value_2024) / total_2024))
cat(sprintf("  Dec 2025 weights:  $%6.1fB / $%6.1fB = %.4f%%\n",
            sum(ar$value_dec25) / 1e9, total_dec25 / 1e9,
            100 * sum(ar$value_dec25) / total_dec25))
cat(sprintf("  2025 full weights: $%6.1fB / $%6.1fB = %.4f%%\n",
            sum(ar$value_2025) / 1e9, total_2025 / 1e9,
            100 * sum(ar$value_2025) / total_2025))

agg_headline_delta <- function(weight_col, total_w) {
  if (total_w == 0) return(setNames(rep(NA, length(scenarios)), scenarios))
  vapply(scenarios, function(s) {
    sum(ar[[s]] * ar[[weight_col]], na.rm = TRUE) / total_w
  }, numeric(1))
}

headline_2024  <- agg_headline_delta("value_2024",  total_2024)
headline_dec25 <- agg_headline_delta("value_dec25", total_dec25)
headline_2025  <- agg_headline_delta("value_2025",  total_2025)

cat("\nAdditive ETR contribution from the affected subset (pp of CA+MX ETR):\n\n")
print(round(rbind(
  weights_2024    = headline_2024,
  weights_dec2025 = headline_dec25,
  weights_2025_full = headline_2025
) * 100, 4))

cat("\n=== Bias from strict monthly mode (pre-fix) vs fallback (post-fix) ===\n")
delta_pp_2024  <- (headline_2024["rate_monthly_strict"]  - headline_2024["rate_monthly_fb"])  * 100
delta_pp_dec25 <- (headline_dec25["rate_monthly_strict"] - headline_dec25["rate_monthly_fb"]) * 100
delta_pp_2025  <- (headline_2025["rate_monthly_strict"]  - headline_2025["rate_monthly_fb"])  * 100

cat(sprintf("  2024 weights:      +%.4f pp (overstated CA+MX ETR pre-fix)\n", delta_pp_2024))
cat(sprintf("  Dec 2025 weights:  +%.4f pp\n", delta_pp_dec25))
cat(sprintf("  2025 full weights: +%.4f pp\n", delta_pp_2025))

cat("\n=== Dollar impact (CA+MX 2024 base, ~$1.83T) ===\n")
dollars_2024  <- sum(ar$value_2024) * mean(ar$dec25_share) * mean(ar$scalable_rate)
cat(sprintf("  Approx misallocated tariff (pre-fix): $%.0f M\n",
            sum(ar$value_2024 * (ar$rate_monthly_strict - ar$rate_monthly_fb)) / 1e6))
