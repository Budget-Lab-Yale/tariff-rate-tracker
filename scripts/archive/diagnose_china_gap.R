## Diagnose the ~6.5pp China gap vs Tariff-ETRs
## Focused on 2026-07-24 (post-IEEPA, post-S122 — simplest tariff regime)
##
## Four analyses:
##   1. Chapter-level rate comparison (tracker vs ETRs)
##   2. Authority decomposition for gap-driving chapters
##   3. Section 301 product-list coverage comparison
##   4. Import-weighted gap attribution

library(tidyverse)
library(here)

source(here('src', 'helpers.R'))

QUERY_DATE <- as.Date('2026-07-24')
CTY_CHINA  <- '5700'

# ===========================================================================
# Load data
# ===========================================================================

# ---- Tariff-ETRs paths ----
local_cfg <- tryCatch(yaml::read_yaml(here('config', 'local_paths.yaml')), error = function(e) list())
etrs_repo <- local_cfg$tariff_etrs_repo %||% file.path('..', 'Tariff-ETRs')

# ---- ETRs chapter-level rates ----
etrs_hts2_path <- file.path(etrs_repo, 'output', '2-21_temp', 'levels_by_census_country_hts2.csv')
stopifnot(file.exists(etrs_hts2_path))
etrs_hts2_raw <- read_csv(etrs_hts2_path, col_types = cols(
  date = col_date(), cty_code = col_character(), country_name = col_character(),
  .default = col_double()
))

# ---- ETRs country-level rates (for overall comparison) ----
etrs_country_path <- file.path(etrs_repo, 'output', '2-21_temp', 'levels_by_census_country.csv')
etrs_country <- read_csv(etrs_country_path, col_types = cols(
  date = col_date(), cty_code = col_character(), country_name = col_character(),
  level = col_double()
))

# ---- Import weights ----
imports_raw <- readRDS(file.path(etrs_repo, 'cache', 'hs10_by_country_gtap_2024_con.rds'))
imports <- imports_raw %>%
  group_by(hs10, cty_code) %>%
  summarise(value = sum(imports), .groups = 'drop') %>%
  filter(value > 0) %>%
  rename(hts10 = hs10, country_code = cty_code)

china_imports <- imports %>% filter(country_code == CTY_CHINA)
china_total_imports <- sum(china_imports$value)
cat('China total imports:', round(china_total_imports / 1e9, 1), 'B\n')

# ---- Tracker snapshot ----
pp <- load_policy_params()
ts <- readRDS(here('data', 'timeseries', 'rate_timeseries.rds'))
snap <- get_rates_at_date(ts, QUERY_DATE, policy_params = pp)
china_snap <- snap %>% filter(country == CTY_CHINA)
cat('China snapshot:', nrow(china_snap), 'product-country pairs\n')

# ---- HTS concordance for import remapping ----
concordance <- load_hts_concordance()

# ===========================================================================
# Step 1: Chapter-level rate comparison
# ===========================================================================

cat('\n========================================\n')
cat('STEP 1: Chapter-Level Rate Comparison\n')
cat('========================================\n\n')

# ETRs China chapter rates (already import-weighted ETRs per chapter)
etrs_china_chapters <- etrs_hts2_raw %>%
  filter(date == QUERY_DATE, cty_code == CTY_CHINA) %>%
  select(-date, -cty_code, -country_name) %>%
  pivot_longer(everything(), names_to = 'chapter', values_to = 'etrs_rate_pct')

# Tracker: merge China snapshot with imports, compute chapter-level weighted rates
# Remap imports via concordance (same pattern as compare_etrs.R)
china_imports_remapped <- china_imports
if (nrow(concordance) > 0) {
  china_imports_remapped <- remap_imports_via_concordance(
    china_imports, unique(china_snap$hts10), concordance
  )
}

china_merged <- china_snap %>%
  inner_join(china_imports_remapped, by = c('hts10', 'country' = 'country_code'))

china_chapter_tracker <- china_merged %>%
  mutate(chapter = substr(hts10, 1, 2)) %>%
  group_by(chapter) %>%
  summarise(
    tracker_tariff_rev = sum(total_rate * value),
    chapter_imports = sum(value),
    n_products = n_distinct(hts10),
    .groups = 'drop'
  ) %>%
  mutate(tracker_rate_pct = tracker_tariff_rev / chapter_imports * 100)

# Join and compute gaps
chapter_comparison <- china_chapter_tracker %>%
  left_join(etrs_china_chapters, by = 'chapter') %>%
  mutate(
    etrs_rate_pct = coalesce(etrs_rate_pct, 0),
    gap_pp = tracker_rate_pct - etrs_rate_pct,
    import_share = chapter_imports / china_total_imports,
    gap_contribution_pp = gap_pp * import_share
  ) %>%
  arrange(desc(abs(gap_contribution_pp)))

cat('Top 15 chapters by gap contribution (pp):\n\n')
chapter_comparison %>%
  head(15) %>%
  mutate(across(c(tracker_rate_pct, etrs_rate_pct, gap_pp, gap_contribution_pp, import_share),
                ~round(., 2))) %>%
  print(n = 15, width = 120)

cat('\nOverall China gap (sum of contributions):',
    round(sum(chapter_comparison$gap_contribution_pp), 2), 'pp\n')

# ===========================================================================
# Step 2: Authority decomposition for gap chapters
# ===========================================================================

cat('\n========================================\n')
cat('STEP 2: Authority Decomposition\n')
cat('========================================\n\n')

rate_cols <- c('base_rate', 'rate_232', 'rate_301', 'rate_ieepa_recip',
               'rate_ieepa_fent', 'rate_s122', 'rate_section_201', 'rate_other')
# Use only columns that exist in the snapshot
rate_cols <- intersect(rate_cols, names(china_merged))

top_gap_chapters <- chapter_comparison %>%
  slice_max(abs(gap_contribution_pp), n = 10) %>%
  pull(chapter)

authority_decomp <- china_merged %>%
  mutate(chapter = substr(hts10, 1, 2)) %>%
  filter(chapter %in% top_gap_chapters) %>%
  group_by(chapter) %>%
  summarise(
    across(all_of(rate_cols), ~sum(. * value) / sum(value) * 100),
    total_rate_pct = sum(total_rate * value) / sum(value) * 100,
    chapter_imports_B = sum(value) / 1e9,
    .groups = 'drop'
  ) %>%
  arrange(desc(chapter_imports_B))

cat('Import-weighted authority decomposition for top gap chapters (%):\n\n')
print(authority_decomp, n = 10, width = 140)

# ===========================================================================
# Step 3: Section 301 product-list coverage comparison
# ===========================================================================

cat('\n========================================\n')
cat('STEP 3: Section 301 Product-List Comparison\n')
cat('========================================\n\n')

# ---- Parse ETRs s301.yaml ----
# The YAML has named groups with rate + hts list. Parse with simple line logic.
etrs_s301_path <- file.path(etrs_repo, 'config', '2-21_temp', '2026-07-24', 's301.yaml')
if (!file.exists(etrs_s301_path)) {
  # Try the perm scenario
  etrs_s301_path <- file.path(etrs_repo, 'config', '2-21_perm', '2026-07-24', 's301.yaml')
}
stopifnot(file.exists(etrs_s301_path))

lines <- readLines(etrs_s301_path)
etrs_s301 <- tibble(hts10 = character(), etrs_rate = numeric())
current_rate <- NA_real_
for (line in lines) {
  # Detect rate line
  rate_match <- regmatches(line, regexpr('rate:\\s*([0-9.]+)', line))
  if (length(rate_match) > 0 && nchar(rate_match) > 0) {
    current_rate <- as.numeric(sub('rate:\\s*', '', rate_match))
  }
  # Detect HTS10 entry
  hts_match <- regmatches(line, regexpr("'([0-9]+)'", line))
  if (length(hts_match) > 0 && nchar(hts_match) > 0 && !is.na(current_rate)) {
    hts_code <- gsub("'", '', hts_match)
    etrs_s301 <- bind_rows(etrs_s301, tibble(hts10 = hts_code, etrs_rate = current_rate))
  }
}

cat('ETRs s301 products parsed:', nrow(etrs_s301), '\n')
cat('ETRs rate distribution:\n')
print(table(etrs_s301$etrs_rate))

# ---- Expand tracker HTS8 to HTS10 ----
tracker_s301_raw <- read_csv(here('resources', 's301_product_lists.csv'), show_col_types = FALSE)

# Load the policy params 301 rate config to get rates per ch99
s301_rate_lookup <- pp$SECTION_301_RATES
tracker_s301_rates <- tracker_s301_raw %>%
  inner_join(s301_rate_lookup, by = c('ch99_code' = 'ch99_pattern')) %>%
  group_by(hts8) %>%
  summarise(tracker_rate = max(s301_rate), .groups = 'drop')

# Expand to HTS10 using the product universe from the snapshot
all_hts10 <- unique(snap$hts10)
tracker_s301_expanded <- tibble(hts10 = all_hts10) %>%
  mutate(hts8 = substr(hts10, 1, 8)) %>%
  inner_join(tracker_s301_rates, by = 'hts8') %>%
  select(hts10, tracker_rate)

cat('Tracker s301 expanded to HTS10:', nrow(tracker_s301_expanded), 'products\n')

# ---- Compare coverage ----
comparison_301 <- full_join(
  tracker_s301_expanded,
  etrs_s301,
  by = 'hts10'
) %>%
  mutate(
    category = case_when(
      !is.na(tracker_rate) & !is.na(etrs_rate) & abs(tracker_rate - etrs_rate) < 0.001 ~ 'both_same_rate',
      !is.na(tracker_rate) & !is.na(etrs_rate) ~ 'both_diff_rate',
      !is.na(tracker_rate) & is.na(etrs_rate) ~ 'tracker_only',
      is.na(tracker_rate) & !is.na(etrs_rate) ~ 'etrs_only'
    )
  )

cat('\nCoverage comparison:\n')
print(table(comparison_301$category))

# ---- Weight by China imports ----
comparison_301_weighted <- comparison_301 %>%
  left_join(china_imports %>% select(hts10, value), by = 'hts10') %>%
  mutate(
    value = coalesce(value, 0),
    chapter = substr(hts10, 1, 2),
    # The gap contribution from this product:
    #   tracker_only: we assign tracker_rate, ETRs assigns 0 => gap = +tracker_rate
    #   etrs_only: we assign 0, ETRs assigns etrs_rate => gap = -etrs_rate
    #   both_diff_rate: gap = tracker_rate - etrs_rate
    #   both_same_rate: gap = 0
    rate_gap = case_when(
      category == 'tracker_only' ~ tracker_rate,
      category == 'etrs_only' ~ -etrs_rate,
      category == 'both_diff_rate' ~ tracker_rate - etrs_rate,
      TRUE ~ 0
    ),
    tariff_rev_gap = rate_gap * value
  )

cat('\nImport-weighted 301 gap by category:\n')
cat301_summary <- comparison_301_weighted %>%
  group_by(category) %>%
  summarise(
    n_products = n(),
    n_with_imports = sum(value > 0),
    total_imports_B = sum(value) / 1e9,
    gap_contribution_pp = sum(tariff_rev_gap) / china_total_imports * 100,
    .groups = 'drop'
  )
print(cat301_summary, width = 120)

cat('\nTotal 301-attributable gap:',
    round(sum(cat301_summary$gap_contribution_pp), 2), 'pp\n')

# ---- Chapter-level breakdown for tracker-only products ----
cat('\nTracker-only products by chapter (top 10 by gap contribution):\n')
comparison_301_weighted %>%
  filter(category == 'tracker_only') %>%
  group_by(chapter) %>%
  summarise(
    n_products = n(),
    imports_B = sum(value) / 1e9,
    gap_pp = sum(tariff_rev_gap) / china_total_imports * 100,
    avg_rate_pct = mean(tracker_rate) * 100,
    .groups = 'drop'
  ) %>%
  arrange(desc(gap_pp)) %>%
  head(10) %>%
  print(width = 120)

# ---- Chapter-level breakdown for ETRs-only products ----
cat('\nETRs-only products by chapter (top 10 by |gap| contribution):\n')
comparison_301_weighted %>%
  filter(category == 'etrs_only') %>%
  group_by(chapter) %>%
  summarise(
    n_products = n(),
    imports_B = sum(value) / 1e9,
    gap_pp = sum(tariff_rev_gap) / china_total_imports * 100,
    avg_rate_pct = mean(etrs_rate) * 100,
    .groups = 'drop'
  ) %>%
  arrange(gap_pp) %>%
  head(10) %>%
  print(width = 120)

# ---- Rate mismatches ----
cat('\nRate mismatches (both covered, different rate):\n')
comparison_301_weighted %>%
  filter(category == 'both_diff_rate') %>%
  group_by(tracker_rate_pct = tracker_rate * 100, etrs_rate_pct = etrs_rate * 100) %>%
  summarise(
    n_products = n(),
    imports_B = sum(value) / 1e9,
    gap_pp = sum(tariff_rev_gap) / china_total_imports * 100,
    .groups = 'drop'
  ) %>%
  arrange(desc(abs(gap_pp))) %>%
  print(width = 120)

# ===========================================================================
# Step 4: Tracker-only root cause — prefix expansion vs list difference
# ===========================================================================

cat('\n========================================\n')
cat('STEP 4: Tracker-Only Root Cause Analysis\n')
cat('========================================\n\n')

# For each tracker-only HTS10, check whether its parent HTS8 has ANY sibling
# HTS10 codes in the ETRs list. If yes, this is a prefix over-expansion
# (tracker assigns 301 to all HTS10 under the HTS8, but ETRs only lists some).
# If no sibling is in ETRs, then the entire HTS8 is absent from ETRs.

etrs_hts8_set <- unique(substr(etrs_s301$hts10, 1, 8))

tracker_only_analysis <- comparison_301_weighted %>%
  filter(category == 'tracker_only') %>%
  mutate(
    hts8 = substr(hts10, 1, 8),
    hts8_in_etrs = hts8 %in% etrs_hts8_set,
    root_cause = if_else(hts8_in_etrs, 'prefix_overexpansion', 'hts8_absent_from_etrs')
  )

cat('Tracker-only products by root cause:\n')
tracker_only_analysis %>%
  group_by(root_cause) %>%
  summarise(
    n_products = n(),
    n_with_imports = sum(value > 0),
    imports_B = sum(value) / 1e9,
    gap_pp = sum(tariff_rev_gap) / china_total_imports * 100,
    .groups = 'drop'
  ) %>%
  print(width = 120)

# ---- Deep dive: HTS8-absent products ----
# These are entire HTS8 codes the tracker has on a 301 list but ETRs doesn't
# This is a genuine list difference, not a prefix artifact
absent_hts8_detail <- tracker_only_analysis %>%
  filter(root_cause == 'hts8_absent_from_etrs') %>%
  group_by(chapter) %>%
  summarise(
    n_products = n(),
    n_hts8 = n_distinct(hts8),
    imports_B = sum(value) / 1e9,
    gap_pp = sum(tariff_rev_gap) / china_total_imports * 100,
    avg_rate_pct = mean(tracker_rate) * 100,
    .groups = 'drop'
  ) %>%
  arrange(desc(gap_pp))

cat('\nHTS8-absent from ETRs by chapter (top 10):\n')
print(head(absent_hts8_detail, 10), width = 120)

# ---- Deep dive: Prefix over-expansion products ----
# These are HTS10 codes where ETRs has SOME siblings under the same HTS8
# but not this specific HTS10 — the tracker's prefix match is too broad
overexp_hts8_detail <- tracker_only_analysis %>%
  filter(root_cause == 'prefix_overexpansion') %>%
  group_by(chapter) %>%
  summarise(
    n_products = n(),
    n_hts8 = n_distinct(hts8),
    imports_B = sum(value) / 1e9,
    gap_pp = sum(tariff_rev_gap) / china_total_imports * 100,
    avg_rate_pct = mean(tracker_rate) * 100,
    .groups = 'drop'
  ) %>%
  arrange(desc(gap_pp))

cat('\nPrefix over-expansion by chapter (top 10):\n')
print(head(overexp_hts8_detail, 10), width = 120)

# ---- Show specific high-import tracker-only HTS8 codes absent from ETRs ----
cat('\nTop 20 HTS8 codes absent from ETRs by import value:\n')
tracker_only_analysis %>%
  filter(root_cause == 'hts8_absent_from_etrs') %>%
  group_by(hts8, chapter, tracker_rate) %>%
  summarise(
    n_hts10 = n(),
    imports_B = sum(value) / 1e9,
    gap_pp = sum(tariff_rev_gap) / china_total_imports * 100,
    .groups = 'drop'
  ) %>%
  arrange(desc(imports_B)) %>%
  head(20) %>%
  mutate(tracker_rate_pct = tracker_rate * 100) %>%
  select(hts8, chapter, n_hts10, imports_B, gap_pp, tracker_rate_pct) %>%
  print(n = 20, width = 120)

# ---- Show specific high-import prefix over-expansion HTS10 codes ----
cat('\nTop 20 prefix over-expansion HTS10 by import value:\n')
tracker_only_analysis %>%
  filter(root_cause == 'prefix_overexpansion') %>%
  arrange(desc(value)) %>%
  head(20) %>%
  mutate(tracker_rate_pct = tracker_rate * 100) %>%
  select(hts10, hts8, chapter, value, tracker_rate_pct) %>%
  mutate(imports_M = round(value / 1e6, 1)) %>%
  select(hts10, hts8, chapter, imports_M, tracker_rate_pct) %>%
  print(n = 20, width = 120)

# ---- For the absent HTS8 codes, check which ch99/list they came from ----
cat('\nTracker-only HTS8 absent from ETRs — source list breakdown:\n')
absent_hts8_codes <- tracker_only_analysis %>%
  filter(root_cause == 'hts8_absent_from_etrs') %>%
  distinct(hts8) %>%
  pull(hts8)

tracker_s301_raw %>%
  filter(hts8 %in% absent_hts8_codes) %>%
  group_by(ch99_code, list) %>%
  summarise(n_hts8 = n_distinct(hts8), .groups = 'drop') %>%
  arrange(desc(n_hts8)) %>%
  print(n = 20, width = 120)


# ===========================================================================
# Step 5: Overall gap attribution
# ===========================================================================

# ===========================================================================
# Step 5: Simulate the fix — remove List 4B (9903.88.16) suspended products
# ===========================================================================

cat('\n========================================\n')
cat('STEP 5: Simulated Fix — Remove Suspended 9903.88.16\n')
cat('========================================\n\n')

# Identify List 4B HTS8 codes
list4b_hts8 <- tracker_s301_raw %>%
  filter(ch99_code == '9903.88.16') %>%
  pull(hts8) %>%
  unique()
cat('List 4B HTS8 codes to remove:', length(list4b_hts8), '\n')

# Which of these are tracker-only (not in ETRs)?
list4b_expanded <- tibble(hts10 = all_hts10) %>%
  mutate(hts8 = substr(hts10, 1, 8)) %>%
  filter(hts8 %in% list4b_hts8) %>%
  pull(hts10)
cat('List 4B expanded to HTS10:', length(list4b_expanded), '\n')

# Products that also appear on other 301 lists (and would keep their rate)
other_301_hts8 <- tracker_s301_raw %>%
  filter(ch99_code != '9903.88.16') %>%
  pull(hts8) %>% unique()

list4b_only <- setdiff(list4b_hts8, other_301_hts8)
cat('List 4B-only HTS8 (no other 301 list):', length(list4b_only), '\n')

# Also check List 4A at 7.5% — some of these map to ETRs 7.5% correctly
# but 471 products have tracker=15% vs ETRs=7.5% (rate mismatch bucket)
# Those are products on BOTH 4A (7.5%) and 4B (15%) — with 4B suspended,
# they'd revert to 4A's 7.5%, which matches ETRs
list4a_hts8 <- tracker_s301_raw %>%
  filter(ch99_code == '9903.88.15') %>% pull(hts8) %>% unique()
list4b_also_4a <- intersect(list4b_hts8, list4a_hts8)
cat('List 4B products also on 4A:', length(list4b_also_4a),
    '(would revert from 15% to 7.5%)\n')

# Simulate corrected rates for China
# For tracker-only products from 4B-only: rate goes to 0
# For products on both 4B+4A: rate drops from 15% to 7.5%
# For products on 4B + higher list (e.g. List 3 at 25%): no change (MAX still picks the higher rate)
simulated <- comparison_301_weighted %>%
  mutate(
    hts8 = substr(hts10, 1, 8),
    on_4b = hts8 %in% list4b_hts8,
    on_4b_only = hts8 %in% list4b_only,
    on_4b_and_4a = hts8 %in% list4b_also_4a,
    # Corrected tracker rate: remove 4B contribution
    corrected_tracker_rate = case_when(
      # Products only on 4B: lose 301 entirely
      on_4b_only & category == 'tracker_only' ~ 0,
      # Products on 4B+4A: revert to 7.5% (4A rate)
      on_4b_and_4a & !is.na(tracker_rate) & tracker_rate == 0.15 ~ 0.075,
      # Everything else: unchanged
      TRUE ~ coalesce(tracker_rate, 0)
    ),
    corrected_gap = corrected_tracker_rate - coalesce(etrs_rate, 0),
    corrected_tariff_rev_gap = corrected_gap * value
  )

corrected_gap_pp <- sum(simulated$corrected_tariff_rev_gap) / china_total_imports * 100
original_gap_pp <- sum(cat301_summary$gap_contribution_pp)

cat('\nOriginal 301 gap:', round(original_gap_pp, 2), 'pp\n')
cat('Corrected 301 gap:', round(corrected_gap_pp, 2), 'pp\n')
cat('Reduction:', round(original_gap_pp - corrected_gap_pp, 2), 'pp\n')

# Breakdown of the fix
cat('\nFix decomposition:\n')
simulated %>%
  filter(on_4b) %>%
  mutate(fix_type = case_when(
    on_4b_only & category == 'tracker_only' ~ '4B-only removed (was tracker-only)',
    on_4b_only & category != 'tracker_only' ~ '4B-only removed (was in both)',
    on_4b_and_4a ~ '4B+4A revert to 7.5%',
    TRUE ~ '4B+higher list (no change)'
  )) %>%
  group_by(fix_type) %>%
  summarise(
    n_products = n(),
    imports_B = sum(value) / 1e9,
    gap_reduction_pp = sum(tariff_rev_gap - corrected_tariff_rev_gap) / china_total_imports * 100,
    .groups = 'drop'
  ) %>%
  print(width = 120)


# ===========================================================================
# Step 6: Gap Attribution Summary
# ===========================================================================

cat('\n========================================\n')
cat('STEP 6: Gap Attribution Summary\n')
cat('========================================\n\n')

# Overall China ETR from tracker (weighted by imports)
tracker_china_etr <- sum(china_merged$total_rate * china_merged$value) / china_total_imports * 100
etrs_china_etr <- etrs_country %>%
  filter(date == QUERY_DATE, cty_code == CTY_CHINA) %>%
  pull(level)

cat('Tracker China ETR:', round(tracker_china_etr, 2), '%\n')
cat('ETRs China ETR:   ', round(etrs_china_etr, 2), '%\n')
cat('Overall gap:      ', round(tracker_china_etr - etrs_china_etr, 2), 'pp\n\n')

# Section 301 gap components (from step 3)
s301_total_gap <- sum(cat301_summary$gap_contribution_pp)
s301_tracker_only_gap <- cat301_summary %>%
  filter(category == 'tracker_only') %>% pull(gap_contribution_pp)
s301_etrs_only_gap <- cat301_summary %>%
  filter(category == 'etrs_only') %>% pull(gap_contribution_pp)
s301_rate_diff_gap <- cat301_summary %>%
  filter(category == 'both_diff_rate') %>% pull(gap_contribution_pp)

# Non-301 gap: total gap minus 301 gap
non_301_gap <- (tracker_china_etr - etrs_china_etr) - s301_total_gap

cat('Gap Attribution:\n')
cat(sprintf('  301 coverage: tracker-only products   %+.2f pp\n', s301_tracker_only_gap))
cat(sprintf('  301 coverage: ETRs-only products      %+.2f pp\n', s301_etrs_only_gap))
cat(sprintf('  301 rate differences                  %+.2f pp\n', s301_rate_diff_gap))
cat(sprintf('  301 subtotal                          %+.2f pp\n', s301_total_gap))
cat(sprintf('  Non-301 residual                      %+.2f pp\n', non_301_gap))
cat(sprintf('  ---\n'))
cat(sprintf('  Total                                 %+.2f pp\n', tracker_china_etr - etrs_china_etr))

# Post-fix projection
corrected_301_gap <- corrected_gap_pp
corrected_total_gap <- corrected_301_gap + non_301_gap
cat('\nAfter removing suspended 9903.88.16:\n')
cat(sprintf('  301 subtotal (corrected)              %+.2f pp\n', corrected_301_gap))
cat(sprintf('  Non-301 residual                      %+.2f pp\n', non_301_gap))
cat(sprintf('  Projected total gap                   %+.2f pp\n', corrected_total_gap))

# ===========================================================================
# Save outputs
# ===========================================================================

output_dir <- here('output', 'validation')
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

write_csv(chapter_comparison,
          file.path(output_dir, 'china_gap_by_chapter.csv'))
write_csv(authority_decomp,
          file.path(output_dir, 'china_gap_authority_decomp.csv'))
write_csv(comparison_301_weighted %>% select(-tariff_rev_gap),
          file.path(output_dir, 'china_s301_product_comparison.csv'))

cat('\nOutputs saved to', output_dir, '\n')
cat('Done.\n')
