# =============================================================================
# Pass-1.5 — product-exemption SETS -> spec: adapter-vs-calc equivalence
# =============================================================================
# The hand-curated product-exemption SETS (universal IEEPA Annex II, country-EO,
# floor, §122) used to be loaded inline by 06_calculate_rates.R from resource
# CSVs. They are now relocated into the adapter (.resolve_ieepa_exempt_products /
# .resolve_country_eo_exempt / .resolve_s122_exempt, src/model/authority_adapter.R) and
# baked onto the spec as program-level `$exempt_products`; the calc READS them and
# keeps the product-grid masking. This test runs the ORIGINAL calc load+date-gate
# code (copied verbatim below as the ORACLE) against the real resource CSVs and
# asserts the adapter helpers reproduce it bit-for-bit — the relocation is
# bit-exact by construction, so any divergence is a transcription error caught
# before the 43-rev parity gate.
#
# Usage: module load R/4.4.2-gfbf-2024a && Rscript tests/test_exempt_sets_in_spec.R
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(dplyr)
  library(tibble)
  library(readr)
})
source(here('src', 'model', 'authority_spec.R'))

# stubs so authority_adapter.R's end-to-end build runs without the parser
# pipeline (mirrors tests/test_authority_adapter.R + test_ieepa_deblob.R).
load_policy_params    <- function() list()
get_country_constants <- function(pp) list(
  CTY_CHINA = '5700', CTY_CANADA = '1220', CTY_MEXICO = '2010',
  ISO_TO_CENSUS = c('UK' = '4120', 'JP' = '5880', 'KR' = '5800', 'CN' = '5700'),
  EU27_CODES = c('4279', '4280', '4330'))
filter_active_ch99       <- function(ch99_data, effective_date) ch99_data
compute_heading_gates    <- function(specs, s232_rates) list()
extract_section122_rates <- function(ch99_data) list(s122_rate = 0.10, has_s122 = TRUE)
is_232_exempt            <- function(census_code, exempt_list) isTRUE(census_code %in% exempt_list)
# A recognizable sentinel: the floor relocation is a straight passthrough of
# load_revision_floor_exemptions() (data_loaders.R), so we assert the baking
# wires THIS object onto the spec rather than re-testing the loader.
FLOOR_SENTINEL <- tibble(hts8 = c('72081000', '76069100'),
                         country_group = c('eu', 'japan'))
load_revision_floor_exemptions <- function(revision_id, effective_date = NULL) FLOOR_SENTINEL
source(here('src', 'model', 'authority_adapter.R'))

pass <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:', msg, '\n')
}

# --- ORACLES: the EXACT pre-relocation calc load + date-gate code ------------
oracle_ieepa_exempt <- function(effective_date) {
  ieepa_exempt_path <- here('resources', 'ieepa_exempt_products.csv')
  if (file.exists(ieepa_exempt_path)) {
    ie_raw <- read_csv(ieepa_exempt_path,
                       col_types = cols(hts10 = col_character(),
                                        .default = col_character()))
    rd_exempt <- as.Date(effective_date)
    if ('effective_date_start' %in% names(ie_raw)) {
      ie_raw <- ie_raw %>%
        filter(is.na(effective_date_start) |
                 as.Date(effective_date_start) <= rd_exempt)
    }
    if ('effective_date_end' %in% names(ie_raw)) {
      ie_raw <- ie_raw %>%
        filter(is.na(effective_date_end) |
                 as.Date(effective_date_end) >= rd_exempt)
    }
    ie_raw$hts10
  } else character(0)
}

oracle_country_eo <- function(effective_date) {
  country_eo_exempt_path <- here('resources', 'country_eo_exempt_products.csv')
  if (file.exists(country_eo_exempt_path)) {
    raw <- read_csv(country_eo_exempt_path, comment = '#',
                    col_types = cols(.default = col_character()))
    rev_date_chr <- as.character(effective_date)
    raw %>%
      mutate(
        effective_date_start = if_else(is.na(effective_date_start) | effective_date_start == '',
                                        '1900-01-01', effective_date_start),
        effective_date_end   = if_else(is.na(effective_date_end)   | effective_date_end == '',
                                        '2099-12-31', effective_date_end)
      ) %>%
      filter(rev_date_chr >= effective_date_start, rev_date_chr <= effective_date_end) %>%
      mutate(hts8_prefix = substr(gsub('\\.', '', hts10), 1, 8)) %>%
      distinct(ch99_code, hts8_prefix)
  } else tibble(ch99_code = character(), hts8_prefix = character())
}

# The §122 exempt set is split by condition (2026-07-08): the calc's full-line
# exempt set is the UNCONDITIONAL (aa)(ii)/(iii) codes; the (aa)(iv)
# civil-aircraft codes are utilization-scaled, not full-exempt. The oracle
# mirrors that split so the helper's $hts8 (full-exempt subset) is checked.
oracle_s122 <- function() {
  s122_exempt_path <- here('resources', 's122_exempt_products.csv')
  if (!file.exists(s122_exempt_path)) return(list(hts8 = character(0), gn6_hts8 = character(0)))
  ex <- read_csv(s122_exempt_path,
                 col_types = cols(hts8 = col_character(), .default = col_character()))
  if (!'condition' %in% names(ex)) return(list(hts8 = ex$hts8, gn6_hts8 = character(0)))
  list(hts8     = ex$hts8[ex$condition != 'gn6_civil_aircraft'],
       gn6_hts8 = ex$hts8[ex$condition == 'gn6_civil_aircraft'])
}

# --- helper == oracle, across the live date windows --------------------------
cat('--- universal IEEPA Annex II exempt: helper == oracle (date-windowed) ---\n')
for (d in c('2025-01-01', '2025-08-15', '2025-10-01', '2025-12-01', '2026-06-06')) {
  check(identical(.resolve_ieepa_exempt_products(d), oracle_ieepa_exempt(d)),
        paste0('universal exempt @ ', d, ' == oracle'))
}
# the date window is LIVE (not a silent no-op): early vs late differ in membership
u_early <- .resolve_ieepa_exempt_products('2025-01-01')
u_late  <- .resolve_ieepa_exempt_products('2025-12-01')
check(length(u_early) != length(u_late) && !setequal(u_early, u_late),
      'universal exempt date window is live (2025-01-01 != 2025-12-01)')

cat('\n--- country-EO exempt: helper == oracle (date-windowed) ---\n')
for (d in c('2025-01-01', '2025-09-01', '2025-12-01', '2026-06-06')) {
  check(identical(.resolve_country_eo_exempt(d), oracle_country_eo(d)),
        paste0('country-EO exempt @ ', d, ' == oracle'))
}
ceo_early <- .resolve_country_eo_exempt('2025-01-01')
ceo_late  <- .resolve_country_eo_exempt('2025-12-01')
check(nrow(ceo_early) == 0 && nrow(ceo_late) > 0,
      'country-EO date window is live (none active 2025-01-01; active 2025-12-01)')
check(all(c('ch99_code', 'hts8_prefix') %in% names(ceo_late)) && ncol(ceo_late) == 2,
      'country-EO shape = distinct(ch99_code, hts8_prefix)')

cat('\n--- §122 exempt: helper == oracle (condition split) ---\n')
s122_h <- .resolve_s122_exempt()
s122_o <- oracle_s122()
check(identical(s122_h$hts8, s122_o$hts8), 's122 unconditional hts8 == oracle')
check(identical(s122_h$gn6_hts8, s122_o$gn6_hts8), 's122 GN6 aircraft hts8 == oracle')
check(is.character(s122_h$hts8) && length(s122_h$hts8) > 0,
      's122 unconditional exempt is a non-empty hts8 vector')
check(is.character(s122_h$gn6_hts8) && length(s122_h$gn6_hts8) > 0,
      's122 GN6 aircraft set is non-empty (condition column present)')

# --- end-to-end: build_authority_specs bakes the sets onto the spec ----------
cat('\n--- end-to-end: build_authority_specs bakes $exempt_products ---\n')
d_e2e <- as.Date('2025-12-01')
specs <- build_authority_specs(
  products = data.frame(), ch99_data = data.frame(),
  ieepa_rates = NULL, usmca = data.frame(),
  countries = c('5700', '1220', '2010'),
  revision_id = 'rev_test', effective_date = d_e2e,
  s232_rates = NULL, fentanyl_rates = NULL, policy_params = list()
)
ep <- specs[['ieepa_reciprocal']]$programs[[1]]$exempt_products
check(identical(ep$universal, .resolve_ieepa_exempt_products(d_e2e)),
      'ieepa_reciprocal$exempt_products$universal baked == helper')
check(identical(ep$country_eo, .resolve_country_eo_exempt(d_e2e)),
      'ieepa_reciprocal$exempt_products$country_eo baked == helper')
check(identical(ep$floor, FLOOR_SENTINEL),
      'ieepa_reciprocal$exempt_products$floor baked == load_revision_floor_exemptions()')
check(identical(specs[['section_122']]$programs[[1]]$exempt_products$hts8, .resolve_s122_exempt()$hts8),
      'section_122$exempt_products$hts8 baked == helper (unconditional)')
check(identical(specs[['section_122']]$programs[[1]]$exempt_products$gn6_hts8, .resolve_s122_exempt()$gn6_hts8),
      'section_122$exempt_products$gn6_hts8 baked == helper (aircraft)')
# baking is UNCONDITIONAL (universal also feeds the fentanyl Ch98 carve-out, which
# runs on its own gate) — present even when reciprocal has no rate (ieepa_rates NULL)
check(length(ep$universal) > 0 && length(specs[['ieepa_reciprocal']]$programs[[1]]$rate) == 0,
      'exempt sets baked even when reciprocal rate is empty (independent of rate gate)')
check(isTRUE(validate_spec_set(specs)),
      'new $exempt_products field does not break validate_spec_set (invisible to validator)')

cat('\n', pass, ' assertions passed (test_exempt_sets_in_spec.R)\n', sep = '')
