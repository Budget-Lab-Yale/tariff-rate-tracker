#!/usr/bin/env Rscript
# Audit annex-era s232_usmca_eligible coverage at rev_5.
# Per todo.md "USMCA scenario and share-loading" open work item.
#
# The annex override in step 5c (06_calculate_rates.R) reclassifies products
# into annex_1a/_1b/_2/_3 but does NOT refresh s232_usmca_eligible. That flag
# was set in step 4 from the pre-annex heading configs (autos_passenger,
# auto_parts, mhd_vehicles, mhd_parts, autos_light_trucks). A product newly
# swept into annex_1b that wasn't in any of those heading lists keeps
# s232_usmca_eligible = FALSE, so step 7 won't reduce its rate_232 for CA/MX
# even if the product is S/S+ in the HTS special field.
#
# This script quantifies the gap.

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(here)
})

snap <- readRDS(here("data", "timeseries", "snapshot_2026_rev_5.rds"))
ca_mx <- c("1220", "2010")

gap <- snap %>%
  filter(s232_annex %in% c("annex_1a", "annex_1b", "annex_2", "annex_3"),
         usmca_eligible == TRUE,
         country %in% ca_mx,
         rate_232 > 0) %>%
  mutate(chapter = substr(hts10, 1, 2))

cat("Total annex x USMCA-eligible x CA/MX rows with rate_232 > 0:", nrow(gap), "\n")
cat("Distinct HTS10s:", n_distinct(gap$hts10), "\n\n")

cat("Distribution by annex tier:\n")
print(table(gap$s232_annex))

cat("\nDistribution by HS2 chapter (top 10):\n")
print(head(sort(table(gap$chapter), decreasing = TRUE), 10))

auto_parts <- if (file.exists(here("resources", "s232_auto_parts.txt"))) {
  readLines(here("resources", "s232_auto_parts.txt"))
} else character(0)
mhd_parts <- if (file.exists(here("resources", "s232_mhd_parts.txt"))) {
  readLines(here("resources", "s232_mhd_parts.txt"))
} else character(0)
covered_prefixes <- unique(c(auto_parts, mhd_parts))

# Vectorized prefix match
prefix_match <- function(hts, prefixes) {
  if (length(prefixes) == 0) return(rep(FALSE, length(hts)))
  pat <- paste0("^(", paste(prefixes, collapse = "|"), ")")
  grepl(pat, hts)
}

matched <- prefix_match(gap$hts10, covered_prefixes)

cat("\nGap split:\n")
cat("  In auto/MHD parts list (heading-covered, expected eligible):  ", sum(matched), "\n")
cat("  NOT in auto/MHD parts list (potentially missed by annex flag):", sum(!matched), "\n")

cat("\nNon-matched HTS10s by chapter (top 10):\n")
print(head(sort(table(gap$chapter[!matched]), decreasing = TRUE), 10))

cat("\nSample non-matched annex_1b USMCA-eligible HTS10s (first 20):\n")
sample_rows <- gap %>%
  mutate(matched = matched) %>%
  filter(!matched, s232_annex == "annex_1b") %>%
  distinct(hts10, chapter) %>%
  head(20)
print(sample_rows, n = Inf)

cat("\nMaterials check: 2024 annual rate_232 dollars at risk if all non-matched\n")
cat("rows had been USMCA-exempt (rough upper bound, assumes 100% USMCA claim):\n")
imports_path <- here("data", "census_imports_2024.csv")
if (file.exists(imports_path)) {
  imp <- read_csv(imports_path, col_types = cols(
    hs10 = col_character(), cty_code = col_character(),
    con_val_mo = col_double(), .default = col_guess()
  ), show_col_types = FALSE) %>%
    group_by(hts10 = hs10, country = cty_code) %>%
    summarise(consumption_value = sum(con_val_mo, na.rm = TRUE), .groups = "drop")

  scope <- gap %>%
    mutate(matched = matched) %>%
    filter(!matched) %>%
    select(hts10, country, rate_232) %>%
    inner_join(imp, by = c("hts10", "country"))
  scope_dollars <- sum(scope$consumption_value * scope$rate_232, na.rm = TRUE)
  cat(sprintf("  ~$%.1f M annual rate_232 collected on non-matched USMCA-eligible rows\n",
              scope_dollars / 1e6))
  cat(sprintf("  (across %d HTS10 x country pairs with positive 2024 imports)\n",
              nrow(scope)))
} else {
  cat("  (census_imports_2024.csv not found; materials check skipped)\n")
}
