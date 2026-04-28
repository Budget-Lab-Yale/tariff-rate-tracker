#!/usr/bin/env Rscript
# =============================================================================
# Expand IEEPA Exempt Products
# =============================================================================
# Five fixes:
#   1. Expand all existing HTS8 prefixes to full HTS10 codes using HTS JSON
#   2. Add Ch98 exempt codes (US Notes (v)(i) exempts Ch98 except 9802.00.40/50/60/80)
#   3. Expand ITA prefix entries (8471, 8473.30, 8486, 8523, 8524, 8541, 8542)
#   4. Add Ch97 (artworks/antiques) — Berman Amendment (19 USC 2505)
#   5. Add Ch49 (printed matter) — Berman Amendment (19 USC 2505, "informational materials")
# =============================================================================

library(tidyverse)
library(here)

cat("=== Expanding IEEPA Exempt Products ===\n\n")

# --- Load current exempt list ---
exempt_file <- here('resources', 'ieepa_exempt_products.csv')
current <- read_csv(exempt_file, col_types = cols(hts10 = col_character()))
cat("Current exempt products:", nrow(current), "\n")

# --- Load all HTS10 codes from parsed products RDS (memory-efficient) ---
# Load one at a time, extract hts10, then discard
rds_files <- c(
  here('data', 'processed', 'products_rev_32.rds'),
  here('data', 'timeseries', 'products_2026_rev_4.rds')
)

all_hts10 <- character()
for (f in rds_files) {
  if (file.exists(f)) {
    prods <- readRDS(f)
    cat("  Loaded", nrow(prods), "products from", basename(f), "\n")
    all_hts10 <- c(all_hts10, prods$hts10)
    rm(prods); gc(verbose = FALSE)
  }
}
all_hts10 <- unique(all_hts10)
cat("Total unique HTS10 codes:", length(all_hts10), "\n\n")

# --- Fix 1: Expand existing HTS8 prefixes to full HTS10 ---
current_hts8 <- unique(substr(current$hts10, 1, 8))
cat("Unique HTS8 prefixes in current list:", length(current_hts8), "\n")

expanded_from_existing <- all_hts10[substr(all_hts10, 1, 8) %in% current_hts8]
new_from_expansion <- setdiff(expanded_from_existing, current$hts10)
cat("Fix 1 - HTS8->HTS10 expansion: +", length(new_from_expansion), "codes\n")

# --- Fix 2: Add Ch98 codes ---
# US Notes subdivision (v)(i) explicitly exempts Ch98 from IEEPA,
# except 9802.00.40, 9802.00.50, 9802.00.60, 9802.00.80
ch98_excluded_hts8 <- c("98020040", "98020050", "98020060", "98020080")
ch98_all <- all_hts10[substr(all_hts10, 1, 2) == "98"]
ch98_exempt <- ch98_all[!substr(ch98_all, 1, 8) %in% ch98_excluded_hts8]
new_ch98 <- setdiff(ch98_exempt, current$hts10)
cat("Fix 2 - Ch98 statutory exemption: +", length(new_ch98), "codes",
    "(of", length(ch98_exempt), "total Ch98 exempt)\n")

# --- Fix 3: Expand ITA prefix entries ---
# US Note 2(v)(iii) (HTSUS Ch99 Subchapter III). Verified against the literal
# subheading enumeration in data/us_notes/chapter99_2026_rev_6.txt:12791-12800.
# Some entries appear in the legal text as bare headings (whole heading
# exempt); others as specific subheadings. Using broad 4-digit prefixes for
# the latter would over-extend — e.g. an "8541" prefix wrongly captures
# 8541.42/.43 PV cells, which are NOT on Annex II. Likewise, only 8523.51
# (solid-state semiconductor storage) is exempt under 8523, not the magnetic
# media, optical media, or smart card subheadings. See
# docs/ieepa_exempt_audit_2026-04-28.md for full audit.
ita_prefixes <- c(
  "8471",        # whole heading: computers
  "847330",      # whole subheading: parts of computers
  "8486",        # whole heading: semiconductor manufacturing equipment
  "852351",      # subheading only: solid-state non-volatile storage
  "8524",        # whole heading: electronic displays
  # 8541 - Annex II enumerates specific subheadings only.
  # PV cells (8541.42, 8541.43) are deliberately excluded.
  "85411000",    # diodes, other than photosensitive
  "85412100",    # transistors, dissipation rating <1W
  "85412900",    # transistors, other
  "85413000",    # thyristors, diacs and triacs
  "85414100",    # LEDs
  "85414910",    # photosensitive (specific subheadings)
  "85414970",
  "85414980",
  "85414995",
  "85415100",    # semiconductor-based transducers
  "85415900",    # other photosensitive
  "85419000",    # parts
  "8542"         # whole heading: integrated circuits
)
ita_matches <- character()
for (prefix in ita_prefixes) {
  matches <- all_hts10[substr(all_hts10, 1, nchar(prefix)) == prefix]
  cat("  ITA prefix", prefix, ":", length(matches), "products\n")
  ita_matches <- c(ita_matches, matches)
}
ita_matches <- unique(ita_matches)
new_ita <- setdiff(ita_matches, c(current$hts10, expanded_from_existing, ch98_exempt))
cat("Fix 3 - ITA prefix expansion: +", length(new_ita), "codes\n")

# --- Fix 4: Add Ch97 (Berman Amendment) ---
# Berman Amendment (19 USC 2505) exempts "informational materials" from trade
# restrictions. Ch97 (works of art, collectors' pieces, antiques) is covered
# by its own Ch99 code. TPC confirms these are exempt.
ch97_all <- all_hts10[substr(all_hts10, 1, 2) == "97"]
new_ch97 <- setdiff(ch97_all, c(current$hts10, expanded_from_existing))
cat("Fix 4 - Ch97 Berman Amendment: +", length(new_ch97), "codes",
    "(of", length(ch97_all), "total Ch97)\n")

# --- Fix 5: Add Ch49 (Berman Amendment) ---
# Berman Amendment also covers "printed matter" (informational materials).
# 19 USC 2505(c) defines informational materials broadly: publications, films,
# artworks, etc. Ch49 headings 4901-4911 are informational materials.
# Calendars (4910) and stamps (4907) may be borderline, but TPC confirms
# broad Berman coverage for ch49. Include all ch49 products.
ch49_all <- all_hts10[substr(all_hts10, 1, 2) == "49"]
ch49_already <- ch49_all[ch49_all %in% c(current$hts10, expanded_from_existing, ita_matches)]
new_ch49 <- setdiff(ch49_all, c(current$hts10, expanded_from_existing, ita_matches))
cat("Fix 5 - Ch49 Berman Amendment: +", length(new_ch49), "codes",
    "(of", length(ch49_all), "total Ch49,", length(ch49_already), "already exempt)\n")

# --- Combine all ---
all_exempt <- sort(unique(c(current$hts10, new_from_expansion, new_ch98, new_ita,
                            new_ch97, new_ch49)))
cat("\nTotal after all fixes:", length(all_exempt),
    "(was", nrow(current), ", +", length(all_exempt) - nrow(current), ")\n")

# --- Write back ---
write_csv(tibble(hts10 = all_exempt), exempt_file)
cat("Written to:", exempt_file, "\n")

cat("\n=== Done ===\n")
