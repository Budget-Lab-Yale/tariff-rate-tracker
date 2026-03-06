#!/usr/bin/env Rscript
# =============================================================================
# Compute product-level USMCA utilization shares from Census SPI data
# =============================================================================
#
# Reads Census IMP_DETL.TXT fixed-width files (from monthly IMDByymm.ZIP archives)
# and computes per-HTS10 x country USMCA utilization shares based on the
# RATE_PROV (rate provision) field:
#
#   RATE_PROV = 18 → entered under USMCA preference
#
# For each HTS10 x country (Canada/Mexico):
#   usmca_share = sum(con_val where rate_prov = 18) / sum(con_val all provisions)
#
# This directly replicates TPC's methodology: "Canadian- and Mexican-origin
# goods face a rate that is multiplied by the complement of the USMCA share
# for each product."
#
# Output: resources/usmca_product_shares.csv
#   Columns: hts10, cty_code, usmca_share
#   All CA/MX products with positive imports (share = 0 if no USMCA claiming)
#
# Usage: Rscript src/compute_usmca_shares.R
#        Rscript src/compute_usmca_shares.R --import-path /path/to/census/zips
# =============================================================================

library(tidyverse)
library(here)

# --- Parse arguments ---
args <- commandArgs(trailingOnly = TRUE)
import_data_path <- if ('--import-path' %in% args) {
  args[which(args == '--import-path') + 1]
} else {
  here('data', 'raw')
}
year <- 2024

message('Computing product-level USMCA shares from Census SPI data...')
message('  Import data path: ', import_data_path)
message('  Year: ', year)

# --- Find Census ZIP files ---
yy <- substr(as.character(year), 3, 4)
file_pattern <- sprintf('IMDB%s\\d{2}\\.ZIP', yy)
zip_files <- list.files(
  path = import_data_path,
  pattern = file_pattern,
  full.names = TRUE,
  ignore.case = TRUE
)

if (length(zip_files) == 0) {
  stop('No Census import files found at ', import_data_path,
       ' matching pattern ', file_pattern)
}
message('  Found ', length(zip_files), ' ZIP file(s)')

# --- Column positions for IMP_DETL.TXT ---
# From DOCUMENTATION/IMP_DETL.STR:
#   COMMODITY C 10  (pos 1-10)   = HTS10 code
#   CTY_CODE  C  4  (pos 11-14)  = Census country code
#   CTY_SUBCO C  2  (pos 15-16)
#   DIST_ENTRY C 2  (pos 17-18)
#   DIST_UNLAD C 2  (pos 19-20)
#   RATE_PROV C  2  (pos 21-22)  = Rate provision / SPI code
#   YEAR      C  4  (pos 23-26)
#   MONTH     C  2  (pos 27-28)
#   CARDS_MO  N 15  (pos 29-43)
#   CON_QY1_MO N 15 (pos 44-58)
#   CON_QY2_MO N 15 (pos 59-73)
#   CON_VAL_MO N 15 (pos 74-88)  = Consumption import value
col_positions <- readr::fwf_positions(
  start     = c(1,  11,  21,  23,  27,  74),
  end       = c(10, 14,  22,  26,  28,  88),
  col_names = c('hs10', 'cty_code', 'rate_prov', 'year', 'month', 'con_val_mo')
)

# --- USMCA rate provision code ---
# RATE_PROV = 18: USMCA (U.S.-Mexico-Canada Agreement) preferential entry
USMCA_RATE_PROV <- '18'
CTY_CANADA <- '1220'
CTY_MEXICO <- '2010'

# --- Process each ZIP file ---
all_records <- map_df(zip_files, function(zip_path) {

  message('  Processing: ', basename(zip_path))

  zip_contents <- unzip(zip_path, list = TRUE)
  detl_file <- zip_contents$Name[grepl('IMP_DETL\\.TXT$', zip_contents$Name,
                                        ignore.case = TRUE)]

  if (length(detl_file) == 0) {
    warning('No IMP_DETL.TXT found in ', basename(zip_path), ', skipping')
    return(tibble())
  }
  if (length(detl_file) > 1) detl_file <- detl_file[1]

  temp_dir <- tempdir()
  extracted_path <- unzip(zip_path, files = detl_file, exdir = temp_dir, overwrite = TRUE)

  records <- read_fwf(
    file = extracted_path,
    col_positions = col_positions,
    col_types = cols(
      hs10       = col_character(),
      cty_code   = col_character(),
      rate_prov  = col_character(),
      year       = col_integer(),
      month      = col_integer(),
      con_val_mo = col_double()
    ),
    progress = FALSE
  )

  file.remove(extracted_path)

  # Filter to CA/MX only (saves memory during accumulation)
  records %>%
    filter(year == !!year, cty_code %in% c(CTY_CANADA, CTY_MEXICO))
})

message('  Total CA/MX records: ', nrow(all_records))

# --- Aggregate by HTS10 x country: total value and USMCA value ---
product_shares <- all_records %>%
  group_by(hs10, cty_code) %>%
  summarise(
    total_value = sum(con_val_mo),
    usmca_value = sum(con_val_mo[rate_prov == USMCA_RATE_PROV]),
    .groups = 'drop'
  ) %>%
  filter(total_value > 0) %>%
  mutate(usmca_share = usmca_value / total_value) %>%
  # Pad and rename to hts10 for consistency with rate schema
  mutate(hts10 = str_pad(hs10, 10, pad = '0')) %>%
  select(-hs10)

message('\nProduct-level USMCA shares (Census RATE_PROV = 18):')
message('  Total product-country pairs: ', nrow(product_shares))
message('  CA products: ', sum(product_shares$cty_code == CTY_CANADA))
message('  MX products: ', sum(product_shares$cty_code == CTY_MEXICO))

# --- Summary statistics ---
message('\n  Overall value shares:')
summary_by_country <- product_shares %>%
  group_by(cty_code) %>%
  summarise(
    total_value = sum(total_value),
    usmca_value = sum(usmca_value),
    overall_share = usmca_value / total_value,
    n_products = n(),
    n_with_usmca = sum(usmca_share > 0),
    n_full_usmca = sum(usmca_share > 0.99),
    n_zero_usmca = sum(usmca_share == 0),
    .groups = 'drop'
  )
print(summary_by_country)

message('\n  Share distribution (CA):')
print(summary(product_shares$usmca_share[product_shares$cty_code == CTY_CANADA]))
message('  Share distribution (MX):')
print(summary(product_shares$usmca_share[product_shares$cty_code == CTY_MEXICO]))

# Shares by decile
message('\n  Share deciles (CA):')
ca_shares <- product_shares$usmca_share[product_shares$cty_code == CTY_CANADA]
print(quantile(ca_shares, probs = seq(0, 1, 0.1)))
message('  Share deciles (MX):')
mx_shares <- product_shares$usmca_share[product_shares$cty_code == CTY_MEXICO]
print(quantile(mx_shares, probs = seq(0, 1, 0.1)))

# --- Save ---
out <- product_shares %>%
  select(hts10, cty_code, usmca_share) %>%
  arrange(hts10, cty_code)

# Verify no NAs
stopifnot(!anyNA(out$usmca_share))
stopifnot(all(out$usmca_share >= 0 & out$usmca_share <= 1))

out_path <- here('resources', 'usmca_product_shares.csv')
write_csv(out, out_path)
message('\nSaved ', nrow(out), ' product-country pairs to: ', out_path)
