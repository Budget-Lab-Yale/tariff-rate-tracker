#!/usr/bin/env Rscript
# =============================================================================
# Build US Note 33 subdivision (r) eligible product list
# =============================================================================
#
# Output: resources/s232_subdivision_r_products.csv (hts_prefix list)
#
# Usage:  Rscript scripts/build_subdivision_r_products.R
#
# US Note 33(r) defines the certification-based EU/JP/KR auto-parts deal
# (9903.94.44/.45/.54/.55/.64/.65 — 15% floor for parts certified by importer
# as used for US production/repair). Per (r)(i)-(iii), the deal does not
# apply to products in chapters 72/73/76, products in subdivision (g), or
# Note 38(i) MHD parts. Per Note 33(r)(1), certified parts under these
# headings are explicitly EXEMPT from the 232 metals annex tariffs
# (9903.82.02 and 9903.82.04-9903.82.19, i.e. the April 2026 annex_1a/1b/2/3
# regime).
#
# This list is the complement: chapter 87 (auto) HTS prefixes that appear in
# the annex_1b CSV (so currently bear a 25% steel/aluminum-derivative rate)
# but are NOT in subdivision (g) (the standard auto parts list captured in
# `s232_auto_parts.txt`). When importer certifies these for US production,
# the legal rate is 15% floor (9903.94.45/.55/.65) with metals annex
# suppressed.
#
# The model treats this as a calibration share — see policy_params.yaml
# `auto_parts_subdivision_r$certified_share` and the step 5d blend in
# `06_calculate_rates.R`.

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(here)
})

annex_path <- here('resources', 's232_annex_products.csv')
auto_parts_path <- here('resources', 's232_auto_parts.txt')
mhd_parts_path <- here('resources', 's232_mhd_parts.txt')
out_path <- here('resources', 's232_subdivision_r_products.csv')

stopifnot(file.exists(annex_path), file.exists(auto_parts_path), file.exists(mhd_parts_path))

annex <- read_csv(annex_path, col_types = cols(.default = col_character()))
ap <- trimws(readLines(auto_parts_path)); ap <- ap[nchar(ap) > 0 & !grepl('^#', ap)]
mhd <- trimws(readLines(mhd_parts_path)); mhd <- mhd[nchar(mhd) > 0 & !grepl('^#', mhd)]

# Eligible scope per US Note 33(r):
#   - annex_1b (so currently bears 25% — annex_1a is chapters 72/73/74/76 which
#     (r)(i) explicitly excludes; annex_2 has rate=0; annex_3 is already at 15% floor)
#   - HS4 in {8706, 8707, 8708} — chassis / bodies / parts of motor vehicles.
#     Excludes 8701-8705 and 8709 (vehicles, not parts) and 8716 (trailers, not
#     parts of passenger vehicles or light trucks). Subdivision (g) does include
#     8716.90.50 specifically — that's the only 8716 entry treated as a part.
#   - not in subdivision (g) — those go through 9903.94.05/.07 path
#   - not in MHD parts (Note 38(i)) — (r)(iii) explicitly excludes them
auto_part_hs4 <- c('8706', '8707', '8708')

eligible <- annex %>%
  filter(
    annex == '1b',
    substr(hts_prefix, 1, 4) %in% auto_part_hs4
  ) %>%
  rowwise() %>%
  mutate(
    in_subdivision_g = any(startsWith(hts_prefix, ap) | startsWith(ap, hts_prefix)),
    in_mhd_parts     = any(startsWith(hts_prefix, mhd) | startsWith(mhd, hts_prefix))
  ) %>%
  ungroup() %>%
  filter(!in_subdivision_g, !in_mhd_parts) %>%
  select(hts_prefix, source_annex = annex, metal_type, source, effective_date) %>%
  mutate(
    source_note = 'Note 33(r) — auto parts not in subdiv (g) or Note 38(i), eligible for EU/JP/KR 15% floor when certified for US production'
  ) %>%
  arrange(hts_prefix)

write_csv(eligible, out_path)
message('Wrote ', out_path)
message('  ', nrow(eligible), ' prefixes (chapter 87 parts, annex_1b, not in (g) or Note 38(i))')
print(eligible %>% count(metal_type))
