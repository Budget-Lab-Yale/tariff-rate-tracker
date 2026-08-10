# =============================================================================
# Tests: Rate Calculation & Extraction
# =============================================================================
#
# Validates the extract_* functions (system boundary: HTS JSON → structured
# data) and calculate_rates_for_revision() (core rate engine). Uses synthetic
# in-memory fixtures — no external data files required.
#
# Usage:
#   Rscript tests/test_rate_calculation.R
#
# =============================================================================

library(tidyverse)
library(jsonlite)
library(here)

source(here('src', 'core', 'helpers.R'))
source(here('src', 'pipeline', '03_parse_chapter99.R'))
source(here('src', 'pipeline', '04_parse_products.R'))
source(here('src', 'pipeline', '05_parse_policy_params.R'))
source(here('src', 'model', 'authority_spec.R'))
source(here('src', 'pipeline', '06_calculate_rates.R'))

pass_count <- 0
fail_count <- 0
skip_count <- 0

skip_test <- function(reason) {
  cond <- structure(class = c('skip', 'condition'), list(message = reason))
  stop(cond)
}

run_test <- function(name, expr) {
  tryCatch({
    force(expr)
    message('  PASS: ', name)
    pass_count <<- pass_count + 1
  }, skip = function(e) {
    message('  SKIP: ', name, ' — ', conditionMessage(e))
    skip_count <<- skip_count + 1
  }, error = function(e) {
    message('  FAIL: ', name, ' — ', conditionMessage(e))
    fail_count <<- fail_count + 1
  })
}


# =============================================================================
# Shared fixtures
# =============================================================================

# Minimal country lookup for tests
test_country_lookup <- c(
  'china' = '5700', 'canada' = '1220', 'mexico' = '2010',
  'japan' = '5880', 'germany' = '4280', 'south korea' = '5800',
  'united kingdom' = '4120', 'australia' = '6021',
  'european union' = 'EU', 'india' = '5330',
  'brazil' = '3510', 'switzerland' = '4419'
)

# Helper: create a minimal HTS JSON item (list, as fromJSON produces)
make_hts_item <- function(htsno, description = '', general = '',
                          special = '', other = '', indent = 0,
                          footnotes = list()) {
  list(
    htsno = htsno,
    indent = indent,
    description = description,
    general = general,
    special = special,
    other = other,
    footnotes = footnotes
  )
}


# =============================================================================
# Test 0: canonical product-country grid
# =============================================================================

message('\n--- Test 0: build_rate_grid ---')

run_test('builds one complete grid and seeds sparse rates', {
  products <- tibble(
    hts10 = c('0101000000', '0202000000'),
    base_rate = c(0.05, NA_real_),
    base_rate_type = c('ad_valorem', NA_character_)
  )
  seed <- tibble(hts10 = '0101000000', country = '5700', rate_301 = 0.25)
  grid <- build_rate_grid(products, c('5700', '1220'), seed)
  stopifnot(nrow(grid) == 4)
  stopifnot(!anyDuplicated(grid[c('hts10', 'country')]))
  stopifnot(grid$rate_301[grid$hts10 == '0101000000' & grid$country == '5700'] == 0.25)
  stopifnot(all(grid$rate_232 == 0))
  stopifnot(grid$base_rate[grid$hts10 == '0202000000' & grid$country == '1220'] == 0)
  stopifnot(grid$base_rate_type[grid$hts10 == '0202000000' & grid$country == '1220'] == 'free')
})

run_test('rejects duplicate product identity', {
  products <- tibble(hts10 = c('0101000000', '0101000000'), base_rate = 0)
  err <- tryCatch({ build_rate_grid(products, '5700'); NULL }, error = identity)
  stopifnot(inherits(err, 'error'))
})

run_test('rejects seed rates keyed outside the grid', {
  products <- tibble(hts10 = '0101000000', base_rate = 0.05)
  seed <- tibble(hts10 = c('0101000000', '9999999999'), country = '5700', rate_301 = 0.25)
  err <- tryCatch({ build_rate_grid(products, '5700', seed); NULL }, error = identity)
  stopifnot(inherits(err, 'error'))
  stopifnot(grepl('outside the product x country grid', conditionMessage(err)))
})


# =============================================================================
# Test 1: extract_ieepa_rates()
# =============================================================================

message('\n--- Test 1: extract_ieepa_rates ---')

make_ieepa_fixture <- function() {
  list(
    # Phase 1 surcharge: China +34%
    make_hts_item('9903.01.63',
                  description = 'Articles the product of China, as provided for in subdivision (v)(iii)',
                  general = '+34%'),
    # Phase 2 surcharge: India +25%
    make_hts_item('9903.02.26',
                  description = 'Articles the product of India, as provided for in subdivision (v)(v)',
                  general = '+25%'),
    # Floor rate: Japan 15%
    make_hts_item('9903.02.44',
                  description = 'Articles the product of Japan, as provided for in subdivision (v)(v)',
                  general = '15%'),
    # Passthrough entry
    make_hts_item('9903.02.45',
                  description = 'Articles the product of Japan, as provided for in subdivision (v)(v)',
                  general = 'The duty provided in the applicable subheading'),
    # Terminated entry — description must have country before the suspension note
    make_hts_item('9903.01.50',
                  description = 'Articles the product of Germany, as provided for in subdivision (v)(iii) of U.S. note 2 to this subchapter [Compiler\'s note: provision suspended.]',
                  general = '+46%'),
    # Universal baseline: 9903.01.25 (+10%)
    make_hts_item('9903.01.25',
                  description = 'Articles the product of any country, as provided for in subdivision (v)',
                  general = '+10%'),
    # Non-IEEPA item (should be ignored)
    make_hts_item('0101.30.00.00',
                  description = 'Asses',
                  general = 'Free',
                  special = 'Free (A,AU,BH,CL)')
  )
}

run_test('extracts surcharge rate', {
  result <- extract_ieepa_rates(make_ieepa_fixture(), test_country_lookup)
  india <- result %>% filter(census_code == '5330')
  stopifnot(nrow(india) > 0)
  stopifnot(abs(india$rate[1] - 0.25) < 1e-10)
  stopifnot(india$rate_type[1] == 'surcharge')
})

run_test('extracts floor rate', {
  result <- extract_ieepa_rates(make_ieepa_fixture(), test_country_lookup)
  japan <- result %>% filter(census_code == '5880', rate_type == 'floor')
  stopifnot(nrow(japan) > 0)
  stopifnot(abs(japan$rate[1] - 0.15) < 1e-10)
})

run_test('detects terminated entry', {
  result <- extract_ieepa_rates(make_ieepa_fixture(), test_country_lookup)
  germany <- result %>% filter(census_code == '4280')
  stopifnot(nrow(germany) > 0)
  stopifnot(germany$terminated[1] == TRUE)
})

run_test('assigns correct phase', {
  result <- extract_ieepa_rates(make_ieepa_fixture(), test_country_lookup)
  india <- result %>% filter(census_code == '5330')
  stopifnot(india$phase[1] == 'phase2_aug7')
})

run_test('returns empty tibble for no IEEPA entries', {
  fixture <- list(
    make_hts_item('0101.30.00.00', general = 'Free')
  )
  result <- extract_ieepa_rates(fixture, test_country_lookup)
  stopifnot(nrow(result) == 0)
  stopifnot('rate' %in% names(result))
  stopifnot('census_code' %in% names(result))
})


# =============================================================================
# Test 2: extract_ieepa_fentanyl_rates()
# =============================================================================

message('\n--- Test 2: extract_ieepa_fentanyl_rates ---')

make_fentanyl_fixture <- function() {
  list(
    # Mexico general: +25%
    make_hts_item('9903.01.01',
                  description = 'Except for products described in headings 9903.01.03-05, articles the product of Mexico',
                  general = '+25%'),
    # Canada general: +25%
    make_hts_item('9903.01.10',
                  description = 'Except for products described in headings 9903.01.13-15, articles the product of Canada',
                  general = '+25%'),
    # Canada carveout: energy +10%
    make_hts_item('9903.01.13',
                  description = 'Energy and mineral products of Canada described in US note 2(a)',
                  general = '+10%'),
    # China general: +20% (must have "Except for products" to be classified as general)
    make_hts_item('9903.01.20',
                  description = 'Except for products described in headings 9903.01.22 through 9903.01.24, articles the product of China, as provided for in subdivision (v)(i)',
                  general = '+20%'),
    # Exclusion entry (no rate — donations)
    make_hts_item('9903.01.02',
                  description = 'Donations for relief of victims of natural disaster',
                  general = 'Free'),
    # Transshipment-evasion penalty (real rev_17+ heading; conditional on a
    # CBP determination, must NOT become a competing Canada general rate)
    make_hts_item('9903.01.16',
                  description = paste('Except for products described in 9903.01.11, 9903.01.12, and',
                                      '9903.01.14, articles the product of Canada as provided for in',
                                      'subdivision (m) to note 2 to this subchapter and determined by',
                                      'CBP to have been transshipped to evade applicable duties'),
                  general = '+40%'),
    # Non-fentanyl item (should be ignored)
    make_hts_item('9903.01.50',
                  description = 'Something else',
                  general = '+34%')
  )
}

run_test('extracts general fentanyl rates by country', {
  result <- extract_ieepa_fentanyl_rates(make_fentanyl_fixture(), test_country_lookup)
  mx <- result %>% filter(census_code == '2010', entry_type == 'general')
  ca <- result %>% filter(census_code == '1220', entry_type == 'general')
  cn <- result %>% filter(census_code == '5700', entry_type == 'general')
  stopifnot(nrow(mx) > 0)
  stopifnot(nrow(ca) > 0)
  stopifnot(nrow(cn) > 0)
  stopifnot(abs(mx$rate[1] - 0.25) < 1e-10)
  stopifnot(abs(cn$rate[1] - 0.20) < 1e-10)
})

run_test('skips transshipment-evasion penalty headings (9903.01.16)', {
  result <- extract_ieepa_fentanyl_rates(make_fentanyl_fixture(), test_country_lookup)
  # The +40% conditional penalty must not appear at all...
  stopifnot(!any(result$ch99_code == '9903.01.16'))
  # ...and in particular must not outrank the true Canada general (+25% here);
  # the adapter max-per-census collapse would otherwise take the 40%.
  ca <- result %>% filter(census_code == '1220', entry_type == 'general')
  stopifnot(all(abs(ca$rate - 0.25) < 1e-10))
})

run_test('extracts carveout entries', {
  result <- extract_ieepa_fentanyl_rates(make_fentanyl_fixture(), test_country_lookup)
  carveout <- result %>% filter(entry_type == 'carveout')
  stopifnot(nrow(carveout) > 0)
  stopifnot(abs(carveout$rate[1] - 0.10) < 1e-10)
})

run_test('skips exclusion entries without rate', {
  result <- extract_ieepa_fentanyl_rates(make_fentanyl_fixture(), test_country_lookup)
  # 9903.01.02 has general = 'Free', should be skipped
  stopifnot(!any(result$ch99_code == '9903.01.02'))
})

run_test('ignores non-fentanyl range items', {
  result <- extract_ieepa_fentanyl_rates(make_fentanyl_fixture(), test_country_lookup)
  stopifnot(!any(result$ch99_code == '9903.01.50'))
})

run_test('returns empty tibble for no fentanyl entries', {
  fixture <- list(make_hts_item('9903.01.50', general = '+34%'))
  result <- extract_ieepa_fentanyl_rates(fixture, test_country_lookup)
  stopifnot(nrow(result) == 0)
  stopifnot('rate' %in% names(result))
})


# =============================================================================
# Test 3: extract_section232_rates()
# =============================================================================

message('\n--- Test 3: extract_section232_rates ---')

make_ch99_232_fixture <- function(steel_rate = 0.25, has_aluminum = TRUE) {
  rows <- list(
    tibble(
      ch99_code = '9903.80.01', rate = steel_rate, authority = 'section_232',
      country_type = 'all', countries = list(character(0)),
      exempt_countries = list(character(0)),
      general_raw = paste0('+', steel_rate * 100, '%'),
      other_raw = '', description = 'Steel articles, all countries'
    )
  )
  if (has_aluminum) {
    rows <- c(rows, list(tibble(
      ch99_code = '9903.85.01', rate = 0.10, authority = 'section_232',
      country_type = 'all_except', countries = list(character(0)),
      exempt_countries = list(c('AU', 'CA', 'MX')),
      general_raw = '+10%', other_raw = '',
      description = 'Aluminum articles, except products of Australia, Canada, Mexico'
    )))
  }
  bind_rows(rows)
}

run_test('extracts steel 232 rate', {
  ch99 <- make_ch99_232_fixture(steel_rate = 0.50)
  result <- extract_section232_rates(ch99)
  stopifnot(result$has_232 == TRUE)
  stopifnot(abs(result$steel_rate - 0.50) < 1e-10)
})

run_test('extracts aluminum 232 with exempt countries', {
  ch99 <- make_ch99_232_fixture()
  result <- extract_section232_rates(ch99)
  stopifnot(abs(result$aluminum_rate - 0.10) < 1e-10)
  stopifnot('AU' %in% result$aluminum_exempt)
})

run_test('has_232 is FALSE when no 232 entries', {
  ch99 <- tibble(
    ch99_code = '9903.88.15', rate = 0.25, authority = 'section_301',
    country_type = 'specific', countries = list('CN'),
    exempt_countries = list(character(0)),
    general_raw = '+25%', other_raw = '',
    description = 'Articles the product of China'
  )
  result <- extract_section232_rates(ch99)
  stopifnot(result$has_232 == FALSE)
})

run_test('extracts semiconductor 232 rate from 9903.79.01', {
  ch99 <- tibble(
    ch99_code = '9903.79.01', rate = 0.25, authority = 'section_232',
    country_type = 'unknown',
    countries = list(character(0)),
    exempt_countries = list(character(0)),
    general_raw = 'The duty provided in the applicable subheading +25%',
    other_raw = 'The duty provided in the applicable subheading +25%',
    description = 'Semiconductor articles as provided for in subdivisions (a) and (b) of U.S. note 39 to this subchapter.'
  )
  result <- extract_section232_rates(ch99)
  stopifnot(result$has_232 == TRUE)
  stopifnot(abs(result$semi_rate - 0.25) < 1e-10)
})

run_test('semi_rate defaults to 0 when 9903.79 absent', {
  ch99 <- make_ch99_232_fixture()
  result <- extract_section232_rates(ch99)
  stopifnot(result$semi_rate == 0)
})


# =============================================================================
# Test 4: extract_section122_rates()
# =============================================================================

message('\n--- Test 4: extract_section122_rates ---')

run_test('extracts s122 rate from 9903.03.01', {
  ch99 <- tibble(
    ch99_code = '9903.03.01', rate = 0.10, authority = 'section_122',
    country_type = 'all', countries = list(character(0)),
    exempt_countries = list(character(0)),
    general_raw = '+10%', other_raw = '',
    description = 'Section 122 base duty'
  )
  result <- extract_section122_rates(ch99)
  stopifnot(result$has_s122 == TRUE)
  stopifnot(abs(result$s122_rate - 0.10) < 1e-10)
})

run_test('has_s122 is FALSE when no 9903.03 entries', {
  ch99 <- tibble(
    ch99_code = '9903.80.01', rate = 0.25, authority = 'section_232',
    country_type = 'all', countries = list(character(0)),
    exempt_countries = list(character(0)),
    general_raw = '+25%', other_raw = '',
    description = 'Steel articles'
  )
  result <- extract_section122_rates(ch99)
  stopifnot(result$has_s122 == FALSE)
  stopifnot(result$s122_rate == 0)
})


# =============================================================================
# Test 5: extract_usmca_eligibility()
# =============================================================================

message('\n--- Test 5: extract_usmca_eligibility ---')

make_usmca_fixture <- function() {
  list(
    # Product with S+ (USMCA eligible)
    make_hts_item('0201.10.00.10',
                  description = 'Beef, fresh',
                  general = '4%',
                  special = 'Free (A+,AU,BH,CL,CO,D,E,IL,JO,KR,MA,OM,P,PA,PE,S,SG)'),
    # Product with S in secondary group
    make_hts_item('0202.20.00.90',
                  description = 'Beef, frozen',
                  general = '4%',
                  special = 'Free (A,BH,CL) See 9823.xx.xx (S+)'),
    # Product without USMCA
    make_hts_item('2204.10.00.00',
                  description = 'Sparkling wine',
                  general = '19.8c/liter',
                  special = 'Free (A+,AU,BH,CL,CO,D,E,IL,JO,KR,MA,OM,P,PA,PE,SG)'),
    # Chapter 99 item (should be skipped)
    make_hts_item('9903.88.15',
                  description = 'Section 301 tariff',
                  general = '+25%'),
    # Non-10-digit item (should be skipped)
    make_hts_item('0201.10',
                  description = 'Heading',
                  general = '4%')
  )
}

run_test('identifies S-program USMCA eligibility', {
  result <- extract_usmca_eligibility(make_usmca_fixture())
  beef_fresh <- result %>% filter(hts10 == '0201100010')
  stopifnot(nrow(beef_fresh) == 1)
  stopifnot(beef_fresh$usmca_eligible == TRUE)
})

run_test('identifies S+ in secondary parenthesized group', {
  result <- extract_usmca_eligibility(make_usmca_fixture())
  beef_frozen <- result %>% filter(hts10 == '0202200090')
  stopifnot(nrow(beef_frozen) == 1)
  stopifnot(beef_frozen$usmca_eligible == TRUE)
})

run_test('products without S/S+ are not USMCA eligible', {
  result <- extract_usmca_eligibility(make_usmca_fixture())
  wine <- result %>% filter(hts10 == '2204100000')
  stopifnot(nrow(wine) == 1)
  stopifnot(wine$usmca_eligible == FALSE)
})

run_test('skips Chapter 99 items', {
  result <- extract_usmca_eligibility(make_usmca_fixture())
  stopifnot(!any(grepl('^9903', result$hts10)))
})

run_test('skips non-10-digit codes', {
  result <- extract_usmca_eligibility(make_usmca_fixture())
  stopifnot(!any(result$hts10 == '020110'))
})


# =============================================================================
# Test 6: Rate invariants
# =============================================================================

message('\n--- Test 6: Rate invariants ---')

# Build a minimal but realistic rate output using the stacking/schema machinery
make_test_rates <- function() {
  tibble(
    hts10 = rep(c('7208100000', '8703230000', '0201100010'), each = 3),
    country = rep(c('5700', '4280', '1220'), 3),
    base_rate = c(0, 0, 0, 0.025, 0.025, 0.025, 0.04, 0.04, 0.04),
    statutory_base_rate = c(0, 0, 0, 0.025, 0.025, 0.025, 0.04, 0.04, 0.04),
    rate_232 = c(0.50, 0.50, 0.50, 0, 0, 0, 0, 0, 0),
    rate_301 = c(0.25, 0, 0, 0.25, 0, 0, 0, 0, 0),
    rate_ieepa_recip = c(0, 0.20, 0.10, 0.34, 0.20, 0, 0.34, 0.20, 0),
    rate_ieepa_fent = c(0.20, 0, 0.25, 0.20, 0, 0.25, 0.20, 0, 0.25),
    rate_s122 = c(0, 0, 0, 0.10, 0.10, 0.10, 0.10, 0.10, 0.10),
    rate_section_201 = 0,
    rate_other = 0,
    metal_share = c(1, 1, 1, 0, 0, 0, 0, 0, 0),
    usmca_eligible = FALSE,
    revision = 'test', effective_date = as.Date('2025-06-01'),
    valid_from = as.Date('2025-06-01'), valid_until = as.Date('2025-12-31')
  ) %>%
    apply_stacking_rules(cty_china = '5700')
}

run_test('total_rate = base_rate + total_additional', {
  rates <- make_test_rates()
  residual <- abs(rates$total_rate - (rates$base_rate + rates$total_additional))
  stopifnot(max(residual) < 1e-10)
})

run_test('no negative rates', {
  rates <- make_test_rates()
  rate_cols <- c('base_rate', 'rate_232', 'rate_301', 'rate_ieepa_recip',
                 'rate_ieepa_fent', 'rate_s122', 'total_additional', 'total_rate')
  for (col in rate_cols) {
    if (any(rates[[col]] < 0)) {
      stop('negative values in ', col)
    }
  }
})

run_test('net authority decomposition sums to total_additional', {
  rates <- make_test_rates()
  net <- compute_net_authority_contributions(rates, cty_china = '5700')
  decomp_sum <- net$net_232 + net$net_ieepa + net$net_fentanyl +
    net$net_301 + net$net_s122 + net$net_section_201 + net$net_other
  residual <- abs(decomp_sum - net$total_additional)
  stopifnot(max(residual) < 1e-10)
})

run_test('232/IEEPA mutual exclusion: China with 232 gets full fentanyl', {
  rates <- make_test_rates()
  china_steel <- rates %>% filter(country == '5700', rate_232 > 0)
  # China with 232: fentanyl stacks at full value (not scaled by nonmetal_share)
  stopifnot(nrow(china_steel) > 0)
  net <- compute_net_authority_contributions(china_steel, cty_china = '5700')
  stopifnot(all(abs(net$net_fentanyl - china_steel$rate_ieepa_fent) < 1e-10))
})

run_test('232/IEEPA mutual exclusion: non-China with 232 has scaled IEEPA', {
  rates <- make_test_rates()
  de_steel <- rates %>% filter(country == '4280', rate_232 > 0)
  # Germany with 232 + metal_share=1: nonmetal_share=0, IEEPA should be 0
  stopifnot(nrow(de_steel) > 0)
  net <- compute_net_authority_contributions(de_steel, cty_china = '5700')
  stopifnot(all(net$net_ieepa == 0))
})

run_test('net_301 faithfully passes through rate_301 (China-only is upstream)', {
  rates <- make_test_rates()
  net <- compute_net_authority_contributions(rates, cty_china = '5700')
  # net_301 is a straight passthrough of rate_301 — the China-only restriction is an
  # UPSTREAM property (06 only ever populates rate_301 for China), NOT enforced by the
  # decomposition. The old assertion (`all(non_china$net_301 == 0)`) was vacuous: it
  # passed only because the fixture sets no non-China 301. Assert the passthrough
  # exactly, with a positive control so it can't pass on all-zeros.
  stopifnot(all(abs(net$net_301 - rates$rate_301) < 1e-10))
  stopifnot(any(net$net_301[net$country == '5700'] > 0))   # positive control
  non_china <- net %>% filter(country != '5700')
  stopifnot(all(non_china$net_301 == 0))                   # holds: fixture has no non-China 301
})


# =============================================================================
# Test 7: classify_authority edge cases
# =============================================================================

message('\n--- Test 7: classify_authority ---')

run_test('section_122 from 9903.03.xx', {
  stopifnot(classify_authority('9903.03.01') == 'section_122')
})

run_test('section_232 from 9903.80-85', {
  stopifnot(classify_authority('9903.80.01') == 'section_232')
  stopifnot(classify_authority('9903.85.04') == 'section_232')
})

run_test('section_232 from 9903.94 (autos)', {
  stopifnot(classify_authority('9903.94.01') == 'section_232')
})

run_test('section_232 from 9903.74 (MHD)', {
  stopifnot(classify_authority('9903.74.01') == 'section_232')
})

run_test('section_232 from 9903.78 (copper)', {
  stopifnot(classify_authority('9903.78.01') == 'section_232')
})

run_test('section_232 from 9903.79 (semiconductors, Note 39)', {
  stopifnot(classify_authority('9903.79.01') == 'section_232')
  stopifnot(classify_authority('9903.79.09') == 'section_232')
})

run_test('section_301 from 9903.86-89', {
  stopifnot(classify_authority('9903.88.15') == 'section_301')
})

run_test('section_301 from 9903.91 (Biden 301)', {
  stopifnot(classify_authority('9903.91.01') == 'section_301')
})

run_test('ieepa_reciprocal from 9903.93/95/96', {
  stopifnot(classify_authority('9903.93.01') == 'ieepa_reciprocal')
  stopifnot(classify_authority('9903.95.01') == 'ieepa_reciprocal')
})

run_test('section_201 safeguards from 9903.40-45', {
  stopifnot(classify_authority('9903.40.01') == 'section_201')
  stopifnot(classify_authority('9903.45.99') == 'section_201')
})

run_test('unknown for empty or malformed code', {
  stopifnot(classify_authority('') == 'unknown')
  stopifnot(classify_authority(NA) == 'unknown')
})


# =============================================================================
# Test 8: parse_rate and parse_ch99_rate
# =============================================================================

message('\n--- Test 8: Rate parsing ---')

run_test('parse_rate: simple percentage', {
  stopifnot(abs(parse_rate('6.8%') - 0.068) < 1e-10)
  stopifnot(abs(parse_rate('25%') - 0.25) < 1e-10)
})

run_test('parse_rate: Free', {
  stopifnot(parse_rate('Free') == 0)
  stopifnot(parse_rate('free') == 0)
})

run_test('parse_rate: empty and NA', {
  stopifnot(is.na(parse_rate('')))
  stopifnot(is.na(parse_rate(NA)))
  stopifnot(is.na(parse_rate(NULL)))
})

run_test('parse_rate: compound rates return NA', {
  stopifnot(is.na(parse_rate('2.4c/kg + 5%')))
  stopifnot(is.na(parse_rate('$1.50/doz')))
})

run_test('classify_rate_type: buckets', {
  stopifnot(classify_rate_type('Free') == 'free')
  stopifnot(classify_rate_type('free') == 'free')
  stopifnot(classify_rate_type('6.8%') == 'ad_valorem')
  stopifnot(classify_rate_type('25%') == 'ad_valorem')
  stopifnot(classify_rate_type('0.25') == 'ad_valorem')          # bare fraction < 1
  stopifnot(classify_rate_type('$1.50/doz') == 'specific_or_compound')
  stopifnot(classify_rate_type('2.4c/kg') == 'specific_or_compound')  # ascii cent variant
  stopifnot(classify_rate_type('0.16¢ each + 2.2%') == 'specific_or_compound')  # ¢ compound
  stopifnot(classify_rate_type('$1.035/kg + 17%') == 'specific_or_compound')
  # Percentage-on-partial-base / legal text is NOT a clean ad valorem.
  stopifnot(classify_rate_type('2.6% on the movement + 3.5% on the battery') == 'other')
  # Empty / whitespace / NA -> NA (inherits parent downstream).
  stopifnot(is.na(classify_rate_type('')))
  stopifnot(is.na(classify_rate_type(' ')))
  stopifnot(is.na(classify_rate_type('\n')))
  stopifnot(is.na(classify_rate_type(NA)))
  # Vectorized.
  v <- classify_rate_type(c('Free', '5%', '$1/kg', ''))
  stopifnot(identical(v, c('free', 'ad_valorem', 'specific_or_compound', NA_character_)))
})

run_test('parse_products: base_rate_type inheritance + stale-sibling flag', {
  # Fixture hierarchy (parents drop out; only 10-digit suffixes + 8-digit leaves
  # survive). '1806.20' is a 6-digit heading: it seeds the stacks but is not a
  # product row.
  fixture <- list(
    make_hts_item('1806.20',       general = '5%',              indent = 0),  # ad valorem heading
    make_hts_item('1806.20.10',    general = '',                indent = 1),  # empty sub-line
    make_hts_item('1806.20.10.00', general = '',                indent = 2),  # CONTROL suffix
    make_hts_item('1806.20.20',    general = '$1.035/kg + 17%', indent = 1),  # compound sub-line
    make_hts_item('1806.20.20.10', general = '',                indent = 2),  # STALE-SIBLING suffix
    make_hts_item('1806.90.00',    general = '$2/kg',           indent = 0)   # compound LEAF (8-digit)
  )
  tmp <- tempfile(fileext = '.json')
  jsonlite::write_json(fixture, tmp, auto_unbox = TRUE)
  on.exit(unlink(tmp), add = TRUE)
  p <- parse_products(tmp)
  bt <- setNames(p$base_rate_type, p$hts10)
  br <- setNames(p$base_rate, p$hts10)

  # Control: suffix under an ad valorem heading inherits ad_valorem; both stacks agree.
  stopifnot(bt[['1806201000']] == 'ad_valorem')
  stopifnot(abs(br[['1806201000']] - 0.05) < 1e-10)

  # Compound leaf: classified specific_or_compound, numeric base_rate is NA.
  stopifnot(bt[['1806900000']] == 'specific_or_compound')
  stopifnot(is.na(br[['1806900000']]))

  # Stale-sibling case: the robust type_stack correctly marks the suffix under
  # the compound parent as specific_or_compound, while the numeric base_rate
  # inherited a STALE 5% from the ad valorem heading (rate_stack skipped the
  # compound parent). This divergence is the parity-gated bug the flag surfaces.
  stopifnot(bt[['1806202010']] == 'specific_or_compound')
  stopifnot(abs(br[['1806202010']] - 0.05) < 1e-10)  # stale numeric — documented, not fixed here
})

run_test('parse_products: column 2 parsed from `other` with S2 typing', {
  # Same shape as the base_rate fixture above, but exercising the `other`
  # (column 2) field. Note the column-2 hierarchy is deliberately NOT parallel
  # to the column-1 one: 1806.20.20 is clean ad valorem in column 2 while being
  # compound in column 1, and vice versa for 1806.20.10 — so a col2 value that
  # accidentally came from the `general` field would be caught.
  fixture <- list(
    make_hts_item('1806.20',       general = '5%',   other = '35%',       indent = 0),
    make_hts_item('1806.20.10',    general = '',     other = '$4/kg',     indent = 1),
    make_hts_item('1806.20.10.00', general = '',     other = '',          indent = 2),
    make_hts_item('1806.20.20',    general = '$1/kg', other = '20%',      indent = 1),
    make_hts_item('1806.20.20.10', general = '',     other = '',          indent = 2),
    make_hts_item('1806.30.00',    general = 'Free', other = 'Free',      indent = 0),
    make_hts_item('1806.90.00',    general = '2%',   other = '',          indent = 0)
  )
  tmp <- tempfile(fileext = '.json')
  jsonlite::write_json(fixture, tmp, auto_unbox = TRUE)
  on.exit(unlink(tmp), add = TRUE)
  p <- parse_products(tmp)
  stopifnot(all(c('col2_rate', 'col2_rate_raw', 'col2_rate_type') %in% names(p)))
  c2 <- setNames(p$col2_rate, p$hts10)
  ct <- setNames(p$col2_rate_type, p$hts10)
  raw <- setNames(p$col2_rate_raw, p$hts10)

  # Specific column-2 parent shadows the ad-valorem heading: NA numeric (S2 ->
  # 0 downstream) but an honest type. The single col2 stack pushes on ANY legal
  # column-2 line, so unlike base_rate there is no stale-sibling inheritance.
  stopifnot(is.na(c2[['1806201000']]))
  stopifnot(ct[['1806201000']] == 'specific_or_compound')

  # Ad-valorem column 2 under a compound column 1 — proves the two fields are
  # read independently.
  stopifnot(abs(c2[['1806202010']] - 0.20) < 1e-10)
  stopifnot(ct[['1806202010']] == 'ad_valorem')

  # Free in both columns; and a line with no column-2 text at all stays NA.
  stopifnot(abs(c2[['1806300000']]) < 1e-10, ct[['1806300000']] == 'free')
  stopifnot(is.na(c2[['1806900000']]), is.na(ct[['1806900000']]))

  # Raw text is preserved verbatim for audit.
  stopifnot(raw[['1806202010']] == '')
  stopifnot(raw[['1806300000']] == 'Free')
})

run_test('parse_ch99_rate: surcharge format', {
  stopifnot(abs(parse_ch99_rate('The duty provided in the applicable subheading + 25%') - 0.25) < 1e-10)
  stopifnot(abs(parse_ch99_rate('The duty provided in the applicable subheading plus 7.5%') - 0.075) < 1e-10)
})

run_test('parse_ch99_rate: bare percentage', {
  stopifnot(abs(parse_ch99_rate('25%') - 0.25) < 1e-10)
})

run_test('parse_ch99_rate: empty returns NA', {
  stopifnot(is.na(parse_ch99_rate('')))
  stopifnot(is.na(parse_ch99_rate(NA)))
})


# =============================================================================
# Test 9: enforce_rate_schema
# =============================================================================

message('\n--- Test 9: Schema enforcement ---')

run_test('adds missing columns with defaults', {
  df <- tibble(hts10 = '0101300000', country = '5700')
  result <- enforce_rate_schema(df)
  stopifnot(all(RATE_SCHEMA %in% names(result)))
  stopifnot(result$rate_232 == 0)
  stopifnot(result$rate_301 == 0)
  stopifnot(result$total_rate == 0)
})

run_test('fills NAs in per-authority rate columns with 0', {
  # A bind_rows MFN-only grid pair legitimately leaves an absent authority column
  # NA — that IS a 0 rate. (total_additional/total_rate are NOT filled here — see
  # the fail-loud test below.)
  df <- tibble(
    hts10 = '0101300000', country = '5700',
    base_rate = NA_real_, rate_232 = NA_real_
  )
  result <- enforce_rate_schema(df)
  stopifnot(result$base_rate == 0)
  stopifnot(result$rate_232 == 0)
})

run_test('fails loud on NA total (never silently coalesces to 0)', {
  # A NA total after stacking means an upstream rate was NA entering
  # apply_stacking_rules (NA poisons the arithmetic). enforce_rate_schema must
  # STOP, not coalesce to 0 — coalescing is how the annex_1c framework NA-condition
  # bug wiped §122 on framework-country goods and shipped silently.
  df <- tibble(
    hts10 = '0101300000', country = '5700',
    rate_s122 = 0.1, total_additional = NA_real_, total_rate = NA_real_
  )
  err <- tryCatch({ enforce_rate_schema(df); NA_character_ },
                  error = function(e) conditionMessage(e))
  stopifnot(!is.na(err))
  stopifnot(grepl('NA total_additional', err))
})

run_test('preserves extra columns', {
  df <- tibble(hts10 = '0101300000', country = '5700', custom_col = 'hello')
  result <- enforce_rate_schema(df)
  stopifnot('custom_col' %in% names(result))
  stopifnot(result$custom_col == 'hello')
})

run_test('schema columns appear first', {
  df <- tibble(hts10 = '0101300000', country = '5700', zzz_extra = 1)
  result <- enforce_rate_schema(df)
  schema_positions <- match(RATE_SCHEMA, names(result))
  extra_position <- match('zzz_extra', names(result))
  stopifnot(all(schema_positions < extra_position))
})


# =============================================================================
# Test 10: Stacking rules edge cases
# =============================================================================

message('\n--- Test 10: Stacking rules ---')

run_test('mutual exclusion: 232 product with metal_share=1 gets no IEEPA', {
  df <- tibble(
    hts10 = '7208100000', country = '4280',
    base_rate = 0, rate_232 = 0.50, rate_301 = 0,
    rate_ieepa_recip = 0.20, rate_ieepa_fent = 0,
    rate_s122 = 0.10, rate_section_201 = 0, rate_other = 0,
    metal_share = 1.0
  )
  result <- apply_stacking_rules(df, cty_china = '5700')
  # With metal_share=1, nonmetal_share=0, so IEEPA and s122 contribute 0
  stopifnot(abs(result$total_additional - 0.50) < 1e-10)
})

run_test('non-232 product stacks IEEPA + fentanyl + s122 fully', {
  df <- tibble(
    hts10 = '0201100010', country = '4280',
    base_rate = 0.04, rate_232 = 0, rate_301 = 0,
    rate_ieepa_recip = 0.15, rate_ieepa_fent = 0,
    rate_s122 = 0.10, rate_section_201 = 0, rate_other = 0,
    metal_share = 0
  )
  result <- apply_stacking_rules(df, cty_china = '5700')
  expected <- 0.15 + 0.10
  stopifnot(abs(result$total_additional - expected) < 1e-10)
  stopifnot(abs(result$total_rate - (0.04 + expected)) < 1e-10)
})

run_test('section_232 pharmaceuticals from 9903.04.60-.69', {
  stopifnot(classify_authority('9903.04.60') == 'section_232')
  stopifnot(classify_authority('9903.04.63') == 'section_232')
  stopifnot(classify_authority('9903.04.69') == 'section_232')
  stopifnot(classify_authority('9903.04.59') == 'other')
})

run_test('polysilicon 9903.45.30-.36 routes to section_232 before section_201', {
  stopifnot(classify_authority('9903.45.29') == 'section_201')
  stopifnot(classify_authority('9903.45.30') == 'section_232')
  stopifnot(classify_authority('9903.45.36') == 'section_232')
  stopifnot(classify_authority('9903.45.37') == 'section_201')
})

run_test('Solar Section 201 is live through 2026-02-06 and dead on 2026-02-07', {
  specs <- list(section_201 = list(
    active = list(from = NA, until = as.Date('2026-02-07')),
    programs = list(list(
      rate = list(default = 0.145, rate_type = 'surcharge'),
      product_scope = list(list_file = 'resources/s201_solar_products.csv'),
      country_scope = list(include = 'all', exclude = '1220')
    ))
  ))
  rates <- tibble(
    hts10 = c('8541430010', '8541430010'),
    country = c('5700', '1220'),
    rate_section_201 = 0
  )

  last_live <- suppressMessages(apply_section201(
    rates, specs, c('5700', '1220'), as.Date('2026-02-06')))
  first_dead <- suppressMessages(apply_section201(
    rates, specs, c('5700', '1220'), as.Date('2026-02-07')))

  stopifnot(abs(last_live$rate_section_201[last_live$country == '5700'] - 0.145) < 1e-12,
            last_live$rate_section_201[last_live$country == '1220'] == 0,
            all(first_dead$rate_section_201 == 0))
})


# =============================================================================
# Test 11: Note 39 semiconductor integration (snapshot-based)
# =============================================================================
#
# These tests read the built 2026_basic and 2026_rev_1 snapshots and assert on
# them. If the snapshots are missing (e.g., CI env without a full build),
# they skip gracefully.

message('\n--- Test 11: Note 39 semiconductor integration ---')

semi_snapshot_path <- here('data', 'timeseries', 'snapshot_2026_rev_1.rds')
semi_basic_path    <- here('data', 'timeseries', 'snapshot_2026_basic.rds')
semi_products_path <- here('resources', 's232_semi_products.csv')

run_test('semi product list exists with expected headings', {
  if (!file.exists(semi_products_path)) skip_test('resource file missing')
  semi <- read_csv(semi_products_path,
                   col_types = cols(hts10 = col_character()),
                   show_col_types = FALSE)
  stopifnot(nrow(semi) >= 5)
  # Note 39(b) scope: 8471.50, 8471.80, 8473.30
  heads <- unique(substr(semi$hts10, 1, 6))
  stopifnot(all(heads %in% c('847150', '847180', '847330')))
})

semi_qualifying_path <- here('resources', 'semi_qualifying_shares.csv')

# Helper: subset of semi HTS10s with qualifying_share == 1 (the calibration-
# active set). The interim binary calibration (2026-04-28) zeros out 9 of 10
# semi HTS10s so the §232 semi rate only lands on AI-accelerator products
# (currently only 8471.80.4000). Tests must scope to this set so changes to
# the calibration CSV don't masquerade as stacking-rule regressions.
semi_active_hts10s <- function() {
  if (!file.exists(semi_qualifying_path)) return(character(0))
  q <- read_csv(semi_qualifying_path,
                col_types = cols(hts10 = col_character(),
                                 qualifying_share = col_double(),
                                 .default = col_character()),
                show_col_types = FALSE)
  q$hts10[q$qualifying_share == 1.0]
}

run_test('rev_1 applies 25% rate_232 to qualifying-share=1 semi HTS10s', {
  if (!file.exists(semi_snapshot_path)) skip_test('snapshot_2026_rev_1.rds missing')
  if (!file.exists(semi_products_path)) skip_test('resource file missing')
  active <- semi_active_hts10s()
  if (length(active) == 0) skip_test('no semi HTS10s with qualifying_share = 1')
  s <- readRDS(semi_snapshot_path)
  rows <- s %>% filter(hts10 %in% active)
  # Every active semi HTS10 × every country should carry exactly 0.25
  # (qualifying_share=1, end_use_exemption_share=0 defaults).
  stopifnot(nrow(rows) > 0)
  stopifnot(all(abs(rows$rate_232 - 0.25) < 1e-10))
})

run_test('rev_1 zeros rate_232 on calibrated-out semi HTS10s (qualifying_share=0)', {
  if (!file.exists(semi_snapshot_path)) skip_test('snapshot_2026_rev_1.rds missing')
  if (!file.exists(semi_qualifying_path)) skip_test('qualifying shares CSV missing')
  q <- read_csv(semi_qualifying_path,
                col_types = cols(hts10 = col_character(),
                                 qualifying_share = col_double(),
                                 .default = col_character()),
                show_col_types = FALSE)
  zeroed <- q$hts10[q$qualifying_share == 0]
  if (length(zeroed) == 0) skip_test('no semi HTS10s with qualifying_share = 0')
  s <- readRDS(semi_snapshot_path)
  rows <- s %>% filter(hts10 %in% zeroed)
  if (nrow(rows) == 0) skip_test('no rows for calibrated-out semi HTS10s')
  # Calibrated-out semi HTS10s should NOT carry the 25% rate. Other 232
  # paths (derivative overlap on 8473.30.20) might still produce non-zero,
  # but the semi-driven 25% must be absent.
  stopifnot(sum(abs(rows$rate_232 - 0.25) < 1e-10) == 0)
})

run_test('2026_basic has no 25% rate_232 on semi HTS10s (pre-tariff baseline)', {
  if (!file.exists(semi_basic_path)) skip_test('snapshot_2026_basic.rds missing')
  if (!file.exists(semi_products_path)) skip_test('resource file missing')
  s <- readRDS(semi_basic_path)
  semi <- read_csv(semi_products_path,
                   col_types = cols(hts10 = col_character()),
                   show_col_types = FALSE)$hts10
  rows <- s %>% filter(hts10 %in% semi)
  stopifnot(nrow(rows) > 0)
  # Baseline has various pre-existing rate_232 values (auto rebate, alum deriv);
  # none should be exactly 0.25 since semi tariff isn't active yet
  stopifnot(sum(abs(rows$rate_232 - 0.25) < 1e-10) == 0)
})

run_test('Note 39(a)(7)-(9) override: active 8471.80.4000 (calibrated semi) carries 25%', {
  # The original Note 39(a) test asserted that 8473.30.20 (in both
  # derivative and semi product lists) would resolve to 25% rather than
  # the derivative 50%. After interim calibration that HTS10 is qualifying_share=0,
  # so the override no longer fires. Exercise the same code path on the one
  # active semi HTS10 (8471.80.4000): must carry 0.25 with deriv_type = NA.
  if (!file.exists(semi_snapshot_path)) skip_test('snapshot_2026_rev_1.rds missing')
  active <- semi_active_hts10s()
  if (length(active) == 0) skip_test('no semi HTS10s with qualifying_share = 1')
  s <- readRDS(semi_snapshot_path)
  semi_rows <- s %>% filter(hts10 %in% active, country %in% c('4419', '5800', '5700'))
  stopifnot(nrow(semi_rows) > 0)
  stopifnot(all(abs(semi_rows$rate_232 - 0.25) < 1e-10))
  stopifnot(all(is.na(semi_rows$deriv_type)))
})

run_test('Note 2(v)(xvi): EU × active semi carries total=0.25 (no Phase 2 stack)', {
  if (!file.exists(semi_snapshot_path)) skip_test('snapshot_2026_rev_1.rds missing')
  active <- semi_active_hts10s()
  if (length(active) == 0) skip_test('no semi HTS10s with qualifying_share = 1')
  s <- readRDS(semi_snapshot_path)
  # EU (4120): Phase 2 reciprocal 15% floor (9903.02.73) would otherwise stack;
  # Note 2(v)(xvi) excludes semi articles from 9903.02.01-.73.
  eu_semi <- s %>% filter(country == '4120', hts10 %in% active)
  stopifnot(nrow(eu_semi) > 0)
  stopifnot(all(abs(eu_semi$total_additional - 0.25) < 1e-10))
})

run_test('Note 39(a)(10)(11): MX/CA × active semi — fentanyl does not contribute', {
  if (!file.exists(semi_snapshot_path)) skip_test('snapshot_2026_rev_1.rds missing')
  active <- semi_active_hts10s()
  if (length(active) == 0) skip_test('no semi HTS10s with qualifying_share = 1')
  s <- readRDS(semi_snapshot_path)
  mx_ca_semi <- s %>%
    filter(country %in% c('1220', '2010'), hts10 %in% active)
  stopifnot(nrow(mx_ca_semi) > 0)
  stopifnot(all(abs(mx_ca_semi$total_additional - 0.25) < 1e-10))
})

run_test('China × active semi: 232 + fentanyl + 301 all stack to 60%', {
  if (!file.exists(semi_snapshot_path)) skip_test('snapshot_2026_rev_1.rds missing')
  active <- semi_active_hts10s()
  if (length(active) == 0) skip_test('no semi HTS10s with qualifying_share = 1')
  s <- readRDS(semi_snapshot_path)
  # China fentanyl 9903.01.20 (10%, below Note 39(a)(12) .24 floor) stacks;
  # Section 301 not in exclusion list, stacks. Expect 25 + 10 + 25 = 60%.
  cn_semi <- s %>% filter(country == '5700', hts10 %in% active)
  stopifnot(nrow(cn_semi) > 0)
  stopifnot(all(abs(cn_semi$total_additional - 0.60) < 1e-10))
})


# =============================================================================
# Test 12: Annex-era country surcharges (rev_5 snapshot)
# =============================================================================
#
# Validates that country-specific S232 surcharges preserved under the April
# 2026 annex regime (configured in section_232_annexes$country_surcharges)
# override the annex tier rate via pmax(). Also guards the semi × annex_2
# interaction (Fix 2 regression test).

message('\n--- Test 12: Annex-era country surcharges (rev_5) ---')

rev5_snapshot_path  <- here('data', 'timeseries', 'snapshot_2026_rev_5.rds')
deriv_products_path <- here('resources', 's232_derivative_products.csv')

run_test('Russia aluminum 200% surcharge applies in ch 76 (Annex I-A primary aluminum)', {
  if (!file.exists(rev5_snapshot_path)) skip_test('snapshot_2026_rev_5.rds missing')
  s <- readRDS(rev5_snapshot_path)
  ru_alum <- s %>% filter(country == '4621', substr(hts10, 1, 2) == '76')
  stopifnot(nrow(ru_alum) > 0)
  # Per Proc 10522 (retained by April 2026 proclamation), Russian aluminum
  # primary products must carry rate_232 >= 2.0 across Annex I-A/I-B/III.
  scoped <- ru_alum %>% filter(s232_annex %in% c('annex_1a', 'annex_1b', 'annex_3'))
  stopifnot(nrow(scoped) > 0)
  stopifnot(all(scoped$rate_232 >= 2.0 - 1e-10))
})

run_test('Russia aluminum derivative surcharge applies in Annex I-B', {
  if (!file.exists(rev5_snapshot_path)) skip_test('snapshot_2026_rev_5.rds missing')
  if (!file.exists(deriv_products_path)) skip_test('derivative products file missing')
  s <- readRDS(rev5_snapshot_path)
  deriv <- read_csv(deriv_products_path,
                    col_types = cols(hts_prefix = col_character()),
                    show_col_types = FALSE) %>%
    filter(derivative_type == 'aluminum')
  if (nrow(deriv) == 0) skip_test('no aluminum derivatives in product list')

  deriv_pattern <- paste0('^(', paste(deriv$hts_prefix, collapse = '|'), ')')
  ru_deriv <- s %>%
    filter(country == '4621',
           grepl(deriv_pattern, hts10),
           s232_annex %in% c('annex_1a', 'annex_1b', 'annex_3'))
  if (nrow(ru_deriv) == 0) skip_test('no Russia × aluminum-derivative rows in rev_5')
  stopifnot(all(ru_deriv$rate_232 >= 2.0 - 1e-10))
})

run_test('Russia annex_2 products are NOT surcharged (annex II out of scope)', {
  if (!file.exists(rev5_snapshot_path)) skip_test('snapshot_2026_rev_5.rds missing')
  s <- readRDS(rev5_snapshot_path)
  if (!'heading_program' %in% names(s)) {
    skip_test('snapshot predates heading_program column — rebuild snapshot_2026_rev_5.rds')
  }
  ru_a2 <- s %>% filter(country == '4621', s232_annex == 'annex_2')
  if (nrow(ru_a2) == 0) skip_test('no Russia × annex_2 rows')
  # Annex II removes products from the steel/aluminum/copper 232 tariff only.
  # The separate heading-program authorities (auto 9903.94, MHD 9903.74, wood
  # 9903.76, semi 9903.79) are unaffected, so heading-program products keep
  # their non-zero rate_232 on annex_2 by design (06_calculate_rates.R override).
  # Everything that is NOT a heading-program product must be surcharge-free.
  non_hp_a2 <- ru_a2 %>% filter(!heading_program)
  stopifnot(all(non_hp_a2$rate_232 == 0))
})

run_test('Russia steel (ch 72/73) does NOT get the aluminum-only surcharge', {
  if (!file.exists(rev5_snapshot_path)) skip_test('snapshot_2026_rev_5.rds missing')
  s <- readRDS(rev5_snapshot_path)
  # Exclude HS8 prefixes classified as aluminum derivatives — those are
  # iron/steel-chapter products legitimately covered by the aluminum
  # surcharge via the derivative pathway (e.g., 7308.20 towers/masts under
  # 9903.85.08). Including them would conflate "ch 72/73" with "steel".
  alum_deriv_prefixes <- if (file.exists(deriv_products_path)) {
    read_csv(deriv_products_path,
             col_types = cols(hts_prefix = col_character()),
             show_col_types = FALSE) %>%
      filter(derivative_type == 'aluminum') %>%
      pull(hts_prefix)
  } else character(0)
  ru_steel <- s %>% filter(country == '4621', substr(hts10, 1, 2) %in% c('72', '73'),
                           s232_annex %in% c('annex_1a', 'annex_1b', 'annex_3'),
                           !(substr(hts10, 1, 8) %in% alum_deriv_prefixes))
  if (nrow(ru_steel) == 0) skip_test('no Russia × steel rows')
  # Surcharge is scoped to metal_types: ['aluminum']; steel must see the
  # standard annex rate (0.50 for I-A, 0.25 for I-B, floor-based for III),
  # never 2.0.
  stopifnot(all(ru_steel$rate_232 < 1.0))
})

run_test('Non-Russia countries in ch 76 do NOT get the Russia surcharge', {
  if (!file.exists(rev5_snapshot_path)) skip_test('snapshot_2026_rev_5.rds missing')
  s <- readRDS(rev5_snapshot_path)
  # Sanity: other countries' aluminum should carry the standard annex rate.
  other_alum <- s %>%
    filter(country != '4621', substr(hts10, 1, 2) == '76',
           s232_annex == 'annex_1a')
  if (nrow(other_alum) == 0) skip_test('no non-Russia × ch76 × annex_1a rows')
  stopifnot(all(other_alum$rate_232 <= 0.5 + 1e-10))
  stopifnot(!any(other_alum$rate_232 >= 2.0 - 1e-10))
})

run_test('Annex II × rate_232>0 is heading-program-only (Note 39a invariant)', {
  if (!file.exists(rev5_snapshot_path)) skip_test('snapshot_2026_rev_5.rds missing')
  s <- readRDS(rev5_snapshot_path)
  if (!'heading_program' %in% names(s)) {
    skip_test('snapshot predates heading_program column — rebuild snapshot_2026_rev_5.rds')
  }
  # Annex II strips only the steel/aluminum/copper 232 tariff. Auto/MHD/wood/semi
  # heading-program rates are separate authorities and survive on annex_2 by
  # design; any NON-heading-program product with a non-zero rate_232 is a leak.
  leak <- s %>%
    filter(s232_annex == 'annex_2', rate_232 > 0, !heading_program)
  stopifnot(nrow(leak) == 0)
})


# =============================================================================
# Test: Ch99 effective-date offset extraction & filter
# =============================================================================
#
# §232 auto (9903.94.01) was added to the HTS at rev_6 (effective 2025-03-12)
# but its description specifies "effective with respect to entries on or after
# April 3, 2025." Treating the rate as live in rev_6 produces ~$7B of chapter
# 87 trackerover in March 2025. See tariff-etr-eval audit memo
# s232_auto_effective_date_2026-04-28.md for the source bug report.

run_test('extract_effective_date_offset returns NA for empty/no-pattern text', {
  stopifnot(is.na(extract_effective_date_offset('')))
  stopifnot(is.na(extract_effective_date_offset(NA_character_)))
  stopifnot(is.na(extract_effective_date_offset('Standard description text')))
  stopifnot(is.na(extract_effective_date_offset('except for products of Canada')))
})

run_test('extract_effective_date_offset parses §232 auto wording', {
  desc <- paste0('Except for 9903.94.02, 9903.94.03, and 9903.94.04, ',
                 'effective with respect to entries on or after April 3, 2025, ',
                 'passenger vehicles')
  d <- extract_effective_date_offset(desc)
  stopifnot(!is.na(d))
  stopifnot(d == as.Date('2025-04-03'))
})

run_test('extract_effective_date_offset is case-insensitive', {
  desc <- 'Effective ON OR AFTER May 3, 2025, certain articles'
  d <- extract_effective_date_offset(desc)
  stopifnot(d == as.Date('2025-05-03'))
})

run_test('extract_effective_date_offset returns earliest date when multiple appear', {
  # Earliest-first ordering: result should equal the leftmost-and-earliest.
  desc <- paste0('on or after April 3, 2025, articles, then on or after ',
                 'May 3, 2025 the rate doubles')
  stopifnot(extract_effective_date_offset(desc) == as.Date('2025-04-03'))

  # Later-date-first ordering: result must still be the EARLIEST, not the
  # leftmost. Regression for the original `regexpr` bug that returned the
  # first regex match instead of min(date).
  desc2 <- paste0('phase-in on or after May 3, 2025, then full rate ',
                  'on or after April 3, 2025')
  stopifnot(extract_effective_date_offset(desc2) == as.Date('2025-04-03'))
})

run_test('extract_effective_date_offset stops on unparseable matched phrase', {
  # Pattern matches but as.Date fails (e.g. invalid day). Must error, not
  # silently NA — silent NA leaves filter_active_ch99 keeping the row,
  # re-introducing the pre-activation collection bug the gate prevents.
  desc <- 'effective on or after Aprilis 99, 2025, certain articles'
  err <- tryCatch(extract_effective_date_offset(desc),
                  error = function(e) e)
  stopifnot(inherits(err, 'error'))
  stopifnot(grepl('failed to parse', err$message))
})

run_test('filter_active_ch99 drops not-yet-active rows', {
  ch99 <- tibble::tibble(
    ch99_code = c('9903.94.01', '9903.94.05', '9903.99.99'),
    rate = c(0.25, 0.25, 0.50),
    effective_date_offset = as.Date(c('2025-04-03', '2025-05-03', NA))
  )
  # rev_6 effective 2025-03-12: BOTH dated entries must drop, NA stays.
  out <- filter_active_ch99(ch99, as.Date('2025-03-12'))
  stopifnot(nrow(out) == 1)
  stopifnot(out$ch99_code == '9903.99.99')
})

run_test('filter_active_ch99 keeps rows where revision date >= offset', {
  ch99 <- tibble::tibble(
    ch99_code = c('9903.94.01', '9903.94.05', '9903.99.99'),
    rate = c(0.25, 0.25, 0.50),
    effective_date_offset = as.Date(c('2025-04-03', '2025-05-03', NA))
  )
  # rev_8 effective 2025-04-03: auto-vehicle row keeps (== offset),
  # auto-parts row drops (< offset), NA always keeps.
  out <- filter_active_ch99(ch99, as.Date('2025-04-03'))
  stopifnot(nrow(out) == 2)
  stopifnot(setequal(out$ch99_code, c('9903.94.01', '9903.99.99')))
})

run_test('filter_active_ch99 is a no-op when column is missing', {
  # Backwards compatibility for cached ch99_<rev>.rds produced before
  # extract_effective_date_offset() existed.
  ch99 <- tibble::tibble(
    ch99_code = c('9903.94.01'),
    rate = c(0.25)
  )
  out <- filter_active_ch99(ch99, as.Date('2025-03-12'))
  stopifnot(nrow(out) == 1)
  stopifnot(out$ch99_code == '9903.94.01')
})

# --- Expiry-date machinery (§301 exclusion windows; 2026-06-10) -------------

run_test('extract_expiry_date_offset returns NA for empty/no-pattern text', {
  stopifnot(is.na(extract_expiry_date_offset('')))
  stopifnot(is.na(extract_expiry_date_offset(NA_character_)))
  stopifnot(is.na(extract_expiry_date_offset(
    'Articles the product of China, as provided for in U.S. note 20(z)')))
  # A start-only window has no expiry.
  stopifnot(is.na(extract_expiry_date_offset(
    'effective with respect to entries on or after April 3, 2025, passenger vehicles')))
})

run_test('extract_expiry_date_offset: "through" is inclusive (9903.88.69 wording)', {
  desc <- paste0('Effective with respect to entries on or after June 15, 2024 ',
                 'and through November 9, 2026, articles the product of China, ',
                 'each covered by an exclusion granted by the U.S. Trade Representative')
  stopifnot(extract_expiry_date_offset(desc) == as.Date('2026-11-09'))
  # The same description's START offset must be untouched by the expiry parse.
  stopifnot(extract_effective_date_offset(desc) == as.Date('2024-06-15'))
})

run_test('extract_expiry_date_offset: "before" is exclusive (9903.88.68 wording)', {
  desc <- paste0('Effective with respect to entries on or after June 1, 2023, ',
                 'and before June 15, 2024, articles the product of China')
  stopifnot(extract_expiry_date_offset(desc) == as.Date('2024-06-14'))
})

run_test('extract_expiry_date_offset: "on or before" is inclusive, multiple -> latest', {
  stopifnot(extract_expiry_date_offset('entered on or before March 1, 2025, goods') ==
              as.Date('2025-03-01'))
  desc <- 'goods through May 31, 2025, extended through November 9, 2026'
  stopifnot(extract_expiry_date_offset(desc) == as.Date('2026-11-09'))
})

run_test('extract_expiry_date_offset stops on unparseable matched phrase', {
  err <- tryCatch(extract_expiry_date_offset('valid through Maybruary 99, 2025, goods'),
                  error = function(e) e)
  stopifnot(inherits(err, 'error'))
  stopifnot(grepl('failed to parse', err$message))
})

run_test('filter_active_ch99 expiry gate drops EXPIRED rate-less rows only', {
  ch99 <- tibble::tibble(
    ch99_code = c('9903.88.67', '9903.88.69', '9903.91.04', '9903.99.99'),
    rate = c(NA, NA, 0.25, 0.50),
    effective_date_offset = as.Date(c('2021-10-12', '2024-06-15', NA, NA)),
    expiry_date_offset = as.Date(c('2024-06-14', '2026-11-09', '2025-12-31', NA))
  )
  # 2026-01-15: .67 (rate-less, expired) drops; .69 in-window keeps;
  # 9903.91.04 (RATE-BEARING, past stated expiry) is RETAINED by design —
  # dropping it would move numbers without its own review (see todo.md);
  # NA-window row always keeps.
  out <- suppressMessages(filter_active_ch99(ch99, as.Date('2026-01-15')))
  stopifnot(setequal(out$ch99_code, c('9903.88.69', '9903.91.04', '9903.99.99')))
})

run_test('filter_active_ch99 keeps rate-less rows on their last active day', {
  ch99 <- tibble::tibble(
    ch99_code = c('9903.88.69'),
    rate = NA_real_,
    effective_date_offset = as.Date('2024-06-15'),
    expiry_date_offset = as.Date('2026-11-09')
  )
  # On the expiry date itself the heading is still active (last active day);
  # one day later it is gone.
  stopifnot(nrow(filter_active_ch99(ch99, as.Date('2026-11-09'))) == 1)
  stopifnot(nrow(suppressMessages(
    filter_active_ch99(ch99, as.Date('2026-11-10')))) == 0)
})

run_test('filter_active_ch99 skips expiry gate when column is missing', {
  # Caches built before expiry_date_offset existed: start gate still applies,
  # expiry gate silently skipped.
  ch99 <- tibble::tibble(
    ch99_code = c('9903.88.67', '9903.94.01'),
    rate = c(NA, 0.25),
    effective_date_offset = as.Date(c('2021-10-12', '2025-04-03'))
  )
  out <- suppressMessages(filter_active_ch99(ch99, as.Date('2025-03-12')))
  stopifnot(setequal(out$ch99_code, '9903.88.67'))
})

run_test('s301 exclusion registry: schema + safety invariants', {
  reg_path <- here('resources', 's301_exclusion_headings.csv')
  if (!file.exists(reg_path)) skip_test('registry CSV missing')
  reg <- read_csv(reg_path, col_types = cols(
    ch99_code = col_character(), validity_start = col_date(),
    validity_end = col_date(), coverage_share = col_double(),
    .default = col_character()
  ), show_col_types = FALSE)
  stopifnot(all(c('ch99_code', 'validity_start', 'validity_end',
                  'coverage_share', 'source', 'source_note') %in% names(reg)))
  stopifnot(!any(duplicated(reg$ch99_code)))
  stopifnot(all(reg$coverage_share >= 0 & reg$coverage_share <= 1))
  # 9903.88.21-.28 are note 20(z)-(gg) CONDITIONAL derived-rate carve-outs,
  # not USTR product exclusions — they must never be full-line zeroed.
  zgg <- reg %>% filter(ch99_code %in% sprintf('9903.88.%02d', 21:28))
  stopifnot(nrow(zgg) == 8, all(zgg$coverage_share == 0))
  # The live exclusion rounds carry the Phase-2 calibrated coverage
  # (2026-06-11, realized-rate inversion, stable window 2025Q3-2026Q1 —
  # docs/s301_exclusion_calibration.md; was 1.0 Phase-1 upper bound).
  stopifnot(reg$coverage_share[reg$ch99_code == '9903.88.69'] == 0.35)
  stopifnot(reg$coverage_share[reg$ch99_code == '9903.88.70'] == 0.20)
  stopifnot(all(reg$source[reg$ch99_code %in%
                             c('9903.88.69', '9903.88.70')] == 'curator'))
})

run_test('s301 exclusion scope survives missing current-snapshot footnotes', {
  # 2026_rev_13 dropped almost all columns:[general] cross-reference endnotes
  # from the JSON export. The durable mapping must keep the known haddock line
  # in the .69 exclusion scope even when products$ch99_refs is empty.
  products <- tibble(
    hts10 = '0304725000',
    ch99_refs = list(character())
  )
  active <- tibble(ch99_code = '9903.88.69', coverage_share = 0.35)
  cfg <- list(lines_file = 'resources/s301_exclusion_lines.csv')

  out <- suppressMessages(resolve_s301_exclusion_scope(products, active, cfg))
  haddock <- out %>% filter(hts10 == '0304725000')
  stopifnot(nrow(haddock) == 1,
            abs(haddock$excl_coverage - 0.35) < 1e-12)
})

run_test('s301 exclusion scope rejects a missing durable mapping file', {
  products <- tibble(hts10 = '0304725000', ch99_refs = list(character()))
  active <- tibble(ch99_code = '9903.88.69', coverage_share = 0.35)
  err <- tryCatch({
    resolve_s301_exclusion_scope(
      products, active,
      list(lines_file = 'resources/does_not_exist_s301_exclusions.csv'))
    NULL
  }, error = identity)
  stopifnot(inherits(err, 'error'), grepl('lines_file not found', err$message))
})

run_test('rev_9 snapshot: §301 exclusion scales China rate_301 on 9903.88.69 scope', {
  # Worked example from the bug report: 0304725000 (frozen haddock) refs both
  # 9903.88.03 (25%, kept) and 9903.88.69 (exclusion, in force through
  # 2026-11-09). Pre-fix snapshots model 25% China §301 mid-exclusion-window;
  # Phase-1 zeroed it; Phase-2 calibration (coverage 0.35) scales it to
  # 0.25 x 0.65 = 0.1625. Snapshot-based: skips when missing; FAILS against
  # a stale artifact (same lifecycle as Test 12 — rebuild rev_9 to re-sync).
  snap_path <- here('data', 'timeseries', 'snapshot_2026_rev_9.rds')
  if (!file.exists(snap_path)) skip_test('snapshot_2026_rev_9.rds missing')
  s <- readRDS(snap_path)
  haddock <- s %>% filter(hts10 == '0304725000', country == '5700')
  if (nrow(haddock) == 0) skip_test('0304725000 x China not in snapshot')
  stopifnot(abs(haddock$rate_301 - 0.25 * (1 - 0.35)) < 1e-10)
})

run_test('parse_chapter99 populates effective_date_offset from JSON', {
  # Synthetic rev_6-style JSON: 9903.94.01 with the auto effective-date
  # description; 9903.99.99 with no date pattern.
  tmp <- tempfile(fileext = '.json')
  on.exit(unlink(tmp), add = TRUE)
  hts <- list(
    list(htsno = '9903.94.01', indent = 0,
         description = paste0('Except for 9903.94.02, effective with respect ',
                              'to entries on or after April 3, 2025, passenger ',
                              'vehicles, as provided for in subdivision (b)...'),
         general = '25%', special = '', other = '', footnotes = list()),
    list(htsno = '9903.99.99', indent = 0,
         description = 'Standard description with no date',
         general = '50%', special = '', other = '', footnotes = list())
  )
  write_json(hts, tmp, auto_unbox = TRUE)
  parsed <- parse_chapter99(tmp)
  stopifnot('effective_date_offset' %in% names(parsed))
  auto <- parsed[parsed$ch99_code == '9903.94.01', ]
  other <- parsed[parsed$ch99_code == '9903.99.99', ]
  stopifnot(auto$effective_date_offset == as.Date('2025-04-03'))
  stopifnot(is.na(other$effective_date_offset))
})

run_test('extract_ieepa_rates gates entries by description-stated effective date', {
  # Synthetic IEEPA items. Country extraction expects "...product of X, as
  # provided..." or "...product of X (that are|with|...)" phrasing.
  hts_raw <- list(
    list(htsno = '9903.01.43', indent = 0,
         description = paste0('Articles the product of South Korea, as provided ',
                              'for in U.S. note 2, effective with respect to ',
                              'entries on or after April 9, 2025.'),
         general = '+ 25%', special = '', other = '', footnotes = list()),
    list(htsno = '9903.01.44', indent = 0,
         description = 'Articles the product of Japan, as provided for in U.S. note 2.',
         general = '+ 20%', special = '', other = '', footnotes = list())
  )
  pre <- extract_ieepa_rates(hts_raw, test_country_lookup,
                             effective_date = as.Date('2025-04-02'))
  post <- extract_ieepa_rates(hts_raw, test_country_lookup,
                              effective_date = as.Date('2025-04-09'))
  # Pre-Apr-9: only Japan (no date phrase) should remain.
  stopifnot(!any(pre$ch99_code == '9903.01.43'))
  stopifnot(any(pre$ch99_code == '9903.01.44'))
  # Apr-9 onward: both should be present.
  stopifnot(any(post$ch99_code == '9903.01.43'))
  stopifnot(any(post$ch99_code == '9903.01.44'))
})

run_test('extract_ieepa_fentanyl_rates respects the effective-date gate too', {
  hts_raw <- list(
    list(htsno = '9903.01.20', indent = 0,
         description = paste0('Articles the product of China, as provided for ',
                              'in U.S. note 2, effective with respect to entries ',
                              'on or after February 4, 2025.'),
         general = '+ 10%', special = '', other = '', footnotes = list())
  )
  pre <- extract_ieepa_fentanyl_rates(hts_raw, test_country_lookup,
                                      effective_date = as.Date('2025-02-01'))
  post <- extract_ieepa_fentanyl_rates(hts_raw, test_country_lookup,
                                       effective_date = as.Date('2025-02-04'))
  stopifnot(nrow(pre) == 0)
  stopifnot(nrow(post) >= 1)
})

run_test('Annex-era s232_usmca_eligible refresh: CA/MX rate_232 reduced vs non-USMCA partner', {
  # Per scripts/audit_s232_usmca_eligibility.R: annex 1a/1b/3 products that
  # are S/S+ per HTS but were not on the pre-annex heading product lists
  # used to keep s232_usmca_eligible = FALSE through step 5c, leaving CA/MX
  # rate_232 unscaled. The refresh in step 7 sets eligibility for annex
  # 1a/1b/3 products with usmca_eligible = TRUE, excluding steel/alum
  # chapters (72/73/76). Asserts the resulting rate_232 reduction.
  snap_path <- here('data', 'timeseries', 'snapshot_2026_rev_6.rds')
  if (!file.exists(snap_path)) skip_test('snapshot_2026_rev_6.rds missing')
  s <- readRDS(snap_path)
  if (!('s232_annex' %in% names(s))) skip_test('rev_6 snapshot predates s232_annex')

  # Brazil (3510) is non-USMCA so always carries the full annex rate.
  # Pivot CA/MX/BR rate_232 wide on the qualifying product set and assert
  # CA or MX (or both) is strictly below Brazil for at least some rows.
  qual <- s %>%
    filter(country %in% c('1220', '2010', '3510'),
           s232_annex %in% c('annex_1a', 'annex_1b', 'annex_3'),
           usmca_eligible == TRUE,
           !(substr(hts10, 1, 2) %in% c('72', '73', '76'))) %>%
    select(hts10, country, rate_232) %>%
    tidyr::pivot_wider(names_from = country, values_from = rate_232,
                       names_prefix = 'r_')
  if (nrow(qual) == 0) skip_test('no annex × USMCA-eligible non-steel/alum rows')

  # Brazil column must exist and carry the unreduced annex rate (>0 floor).
  stopifnot('r_3510' %in% names(qual))
  br_full <- qual$r_3510 > 0
  stopifnot(any(br_full))

  # On rows where Brazil pays the full rate, CA or MX must show strict
  # reduction on at least some products — that's the refresh firing.
  br_pos <- qual[br_full, , drop = FALSE]
  reduced <- (!is.na(br_pos$r_1220) & br_pos$r_1220 < br_pos$r_3510) |
             (!is.na(br_pos$r_2010) & br_pos$r_2010 < br_pos$r_3510)
  stopifnot(sum(reduced) >= 50)  # audit measured 281 distinct HTS10s; tolerate noise
})

run_test('load_usmca_product_shares monthly fallback augments sparse early-year files', {
  # Early-year 2026 monthly DataWeb files have a narrower universe than full-
  # year 2025 (YTD query covers fewer months → fewer trade-active pairs).
  # ~9k tail HTS10s with $3.5B of 2024 import value at ~90% historical USMCA
  # share would otherwise revert to usmca_share = 0 in the usmca_monthly
  # scenario. The fallback should walk back through prior months to fill them.
  jan26_path <- here('resources', 'usmca_product_shares_2026_01.csv')
  dec25_path <- here('resources', 'usmca_product_shares_2025_12.csv')
  if (!file.exists(jan26_path)) skip_test('2026_01 monthly file missing')
  if (!file.exists(dec25_path)) skip_test('2025_12 monthly file missing')

  pp <- list(USMCA_SHARES = list(mode = 'monthly', year = NULL))
  jan26_alone <- read_csv(jan26_path,
                          col_types = cols(hts10 = col_character(),
                                            cty_code = col_character(),
                                            .default = col_guess()),
                          show_col_types = FALSE)
  augmented <- suppressMessages(
    load_usmca_product_shares(policy_params = pp,
                              effective_date = '2026-01-15')
  )
  # Augmentation should add rows; not subtract.
  stopifnot(nrow(augmented) >= nrow(jan26_alone))
  # No duplicate (hts10, cty_code) pairs.
  stopifnot(n_distinct(paste(augmented$hts10, augmented$cty_code)) == nrow(augmented))
  # Primary rows preserved exactly (Jan share wins over Dec share for the same pair).
  primary_keys <- paste(jan26_alone$hts10, jan26_alone$cty_code)
  aug_primary <- augmented[paste(augmented$hts10, augmented$cty_code) %in% primary_keys, ]
  jan_lookup <- setNames(jan26_alone$usmca_share, primary_keys)
  aug_keys <- paste(aug_primary$hts10, aug_primary$cty_code)
  stopifnot(all(abs(aug_primary$usmca_share - jan_lookup[aug_keys]) < 1e-12))
})

run_test('load_usmca_product_shares monthly is unchanged for full-universe months', {
  # 2025-08-15: an Aug 2025 query already has the broad universe (~20k HTS10s
  # x 2 countries) — the fallback should add zero rows.
  aug25_path <- here('resources', 'usmca_product_shares_2025_08.csv')
  if (!file.exists(aug25_path)) skip_test('2025_08 monthly file missing')
  pp <- list(USMCA_SHARES = list(mode = 'monthly', year = NULL))
  loaded <- suppressMessages(
    load_usmca_product_shares(policy_params = pp,
                              effective_date = '2025-08-15')
  )
  raw <- read_csv(aug25_path,
                  col_types = cols(hts10 = col_character(),
                                    cty_code = col_character(),
                                    .default = col_guess()),
                  show_col_types = FALSE)
  stopifnot(nrow(loaded) == nrow(raw))
})


run_test('rev_6 9903.94.01 is gated off (regression for §232 auto fix)', {
  # Production rev_6 ch99 cache should reflect the gate via
  # filter_active_ch99(): no 9903.94 entries remain after gating
  # because rev_6 (2025-03-12) precedes their 2025-04-03 effective date.
  ch99_path <- here('data', 'timeseries', 'ch99_rev_6.rds')
  if (!file.exists(ch99_path)) skip_test('ch99_rev_6.rds missing')
  ch99 <- readRDS(ch99_path)
  if (!'effective_date_offset' %in% names(ch99)) {
    skip_test('ch99_rev_6.rds predates effective_date_offset column — rebuild required')
  }
  auto_entries <- ch99[grepl('^9903\\.94\\.0', ch99$ch99_code), ]
  if (nrow(auto_entries) == 0) skip_test('no 9903.94 entries in rev_6')
  filtered <- filter_active_ch99(ch99, as.Date('2025-03-12'))
  remaining_auto <- filtered[grepl('^9903\\.94\\.0', filtered$ch99_code), ]
  stopifnot(nrow(remaining_auto) == 0)
})

# =============================================================================
# Test: subdivision (r) certified-share blend (US Note 33(r))
# =============================================================================

message('\n--- Test 13: Subdivision (r) certified-share blend ---')

run_test('subdivision (r) products file exists and is non-empty', {
  p <- here('resources', 's232_subdivision_r_products.csv')
  if (!file.exists(p)) skip_test('s232_subdivision_r_products.csv missing')
  d <- read_csv(p, col_types = cols(.default = col_character()),
                show_col_types = FALSE)
  stopifnot(nrow(d) > 0)
  stopifnot('hts_prefix' %in% names(d))
  # Scope guards: chapter 87 only, not in chapters 72/73/76 (impossible by ch87
  # filter) and only annex_1b classifications
  stopifnot(all(substr(d$hts_prefix, 1, 2) == '87'))
  stopifnot(all(d$source_annex == '1b'))
})

run_test('subdivision (r) defaults to no-op (certified_share = 0)', {
  pp <- load_policy_params()
  cfg <- pp$auto_parts_subdivision_r
  stopifnot(!is.null(cfg))
  stopifnot(cfg$certified_share == 0)  # Disabled by default until calibrated
})

run_test('rev_6 snapshot matches pre-fix expectation at subdivision (r) HTS10s', {
  # With certified_share = 0 (default), rev_6 should still show 25% rate_232 on
  # subdivision (r) HTS10s for EU/JP/KR. This is the regression baseline:
  # post-fix runs at certified_share > 0 must be regenerated; until then the
  # saved snapshot reflects the over-tax. See docs/s232/subdivision_r_fix.md.
  snap_path <- here('data', 'timeseries', 'snapshot_2026_rev_6.rds')
  list_path <- here('resources', 's232_subdivision_r_products.csv')
  if (!file.exists(snap_path)) skip_test('rev_6 snapshot missing')
  if (!file.exists(list_path)) skip_test('subdivision (r) list missing')
  s <- readRDS(snap_path)
  d <- read_csv(list_path, col_types = cols(.default = col_character()),
                show_col_types = FALSE)
  pat <- paste0('^(', paste(unique(d$hts_prefix), collapse = '|'), ')')
  EU_codes <- c('4280','4279','4759','4700','4210','4231','4239','4870','4791',
                '4910','4351','4099','4470','4050','4840','4370','4190','4490',
                '4510','4730','4550','4710','4850','4359','4792','4010','4330')
  eu_jpkr <- s %>%
    filter(grepl(pat, hts10), country %in% c(EU_codes, '5880', '5800'))
  if (nrow(eu_jpkr) == 0) skip_test('no EU/JP/KR rows for subdivision (r) HTS10s in rev_6')
  # All should currently be at 0.25 (annex_1b) since the fix is dormant.
  stopifnot(all(abs(eu_jpkr$rate_232 - 0.25) < 1e-9))
})

run_test('subdivision (r) blend math: certified_share applied correctly', {
  # Synthetic test of the blend formula. Mirrors the case_when in step 5d.
  certified_share <- 0.5
  floor_rate <- 0.15
  base_rate <- 0  # 8708.92 codes typically have no MFN
  # Pre-blend rate_232 was 0.25 (annex_1b)
  pre <- 0.25
  expected <- certified_share * pmax(floor_rate - base_rate, 0) +
              (1 - certified_share) * pre
  # 0.5 * 0.15 + 0.5 * 0.25 = 0.20
  stopifnot(abs(expected - 0.20) < 1e-12)

  # With base_rate = 2.5%, floor portion = 0.125, expected = 0.5*0.125 + 0.5*0.25 = 0.1875
  base_rate_25 <- 0.025
  expected_25 <- certified_share * pmax(floor_rate - base_rate_25, 0) +
                 (1 - certified_share) * pre
  stopifnot(abs(expected_25 - 0.1875) < 1e-12)

  # certified_share = 1.0: rate_232 collapses to floor
  expected_full <- 1.0 * pmax(floor_rate - 0, 0) + 0 * pre
  stopifnot(abs(expected_full - 0.15) < 1e-12)
})

run_test('subdivision (r) FTA-exempt config defaults to no-op', {
  pp <- load_policy_params()
  fta <- pp$auto_parts_subdivision_r$fta_exempt_shares
  stopifnot(!is.null(fta))
  # All three default to 0 — fix is dormant until calibrated
  stopifnot(fta$EU == 0, fta$JP == 0, fta$KR == 0)
  # EU never gets an FTA carve-out (no EU-specific FTA covers subdivision (r))
  # — the EU value is "structurally 0," not just uncalibrated. Document via
  # comment in YAML; assert here.
})

run_test('subdivision (r) three-way blend: FTA + certified + non-certified', {
  # Three-way mix formula:
  #   rate_232 = fta_share * 0
  #            + (1 - fta_share) * [certified * pmax(floor - base, 0)
  #                                  + (1 - certified) * pre_annex_rate]
  pre <- 0.25  # annex_1b
  floor_rate <- 0.15
  blend <- function(fta, cert, base) {
    fta * 0 + (1 - fta) * (cert * pmax(floor_rate - base, 0) + (1 - cert) * pre)
  }

  # fta=0, cert=0.5, base=0: 0.5*0.15 + 0.5*0.25 = 0.20 (matches earlier test)
  stopifnot(abs(blend(0, 0.5, 0) - 0.20) < 1e-12)

  # fta=1, cert=anything, base=anything: rate_232 = 0
  stopifnot(blend(1.0, 0.5, 0) == 0)
  stopifnot(blend(1.0, 0.0, 0.025) == 0)

  # fta=0.86 (KR DataWeb signal), cert=0.5, base=0:
  # rate = 0.14 * 0.20 = 0.028
  stopifnot(abs(blend(0.86, 0.5, 0) - 0.028) < 1e-9)

  # fta=0, cert=1.0, base=2.5%: collapses to certified floor
  # 1.0 * 0.125 = 0.125
  stopifnot(abs(blend(0, 1.0, 0.025) - 0.125) < 1e-12)

  # fta=0.5, cert=1.0, base=2.5%: half exempt, half certified
  # 0.5 * 0 + 0.5 * 0.125 = 0.0625
  stopifnot(abs(blend(0.5, 1.0, 0.025) - 0.0625) < 1e-12)
})

run_test('rev_6 snapshot baseline still pre-fix at subdivision (r) HTS10s with default config', {
  # Sanity that adding fta_exempt_shares (all zero) doesn't change saved
  # snapshot expectations: the dormant fix is gated on certified_share > 0
  # OR any fta_exempt_share > 0. With all defaults at 0 the gate is FALSE
  # and step 5d is skipped entirely. Re-uses the regression assertion from
  # the original certified-share landing.
  snap_path <- here('data', 'timeseries', 'snapshot_2026_rev_6.rds')
  list_path <- here('resources', 's232_subdivision_r_products.csv')
  if (!file.exists(snap_path)) skip_test('rev_6 snapshot missing')
  if (!file.exists(list_path)) skip_test('subdivision (r) list missing')
  s <- readRDS(snap_path)
  d <- read_csv(list_path, col_types = cols(.default = col_character()),
                show_col_types = FALSE)
  pat <- paste0('^(', paste(unique(d$hts_prefix), collapse = '|'), ')')
  EU_codes <- c('4280','4279','4759','4700','4210','4231','4239','4870','4791',
                '4910','4351','4099','4470','4050','4840','4370','4190','4490',
                '4510','4730','4550','4710','4850','4359','4792','4010','4330')
  kr <- s %>% filter(grepl(pat, hts10), country == '5800')
  if (nrow(kr) == 0) skip_test('no Korea rows for subdivision (r) in rev_6')
  # Dormant default → all KR subdiv-r should still show 0.25 (annex_1b)
  stopifnot(all(abs(kr$rate_232 - 0.25) < 1e-9))
})

run_test('pharma 232 target-total and share scaling matches Tariff-ETRs treatment', {
  countries <- c('4280', '5880', '4120', '5700')
  cfg <- list(
    default_rate = 0.0001,
    country_rates = list(CTY_UK = 0.10),
    target_total = list(default = 1.00, CTY_JAPAN = 0.15, eu = 0.15, CTY_UK = 0),
    generic_share = list(CTY_CHINA = 0.95, default = 0.20),
    exempt_share = list(eu = 0.75, CTY_UK = 0.75, CTY_JAPAN = 0.75, default = 0.40)
  )
  pp <- list(
    country_codes = list(CTY_UK = '4120', CTY_JAPAN = '5880', CTY_CHINA = '5700'),
    EU27_CODES = c('4280')
  )
  rates <- tibble(
    hts10 = '3004901000',
    country = countries,
    base_rate = c(0.02, 0.02, 0.02, 0.02),
    rate_232 = 0.0001
  )
  out <- apply_pharma_232_adjustments(rates, '3004901000', cfg, countries, pp)
  got <- setNames(out$rate_232, out$country)

  # EU/Japan: 15% total-duty floor less MFN, then patented/exempt scaling.
  stopifnot(abs(got['4280'] - ((0.15 - 0.02) * 0.80 * 0.25)) < 1e-12)
  stopifnot(abs(got['5880'] - ((0.15 - 0.02) * 0.80 * 0.25)) < 1e-12)
  # UK: additive 10%, no target-total floor, then UK exempt share.
  stopifnot(abs(got['4120'] - (0.10 * 0.80 * 0.25)) < 1e-12)
  # China/default target: 100% total-duty floor, high generic share.
  stopifnot(abs(got['5700'] - ((1.00 - 0.02) * 0.05 * 0.60)) < 1e-12)
})

run_test('current-law UK pharmaceutical Section 232 additional rate is zero', {
  pp <- load_policy_params()
  cfg <- pp$section_232_headings$pharmaceuticals
  rates <- tibble(
    hts10 = '3004901000', country = '4120', base_rate = 0.02,
    rate_232 = cfg$default_rate
  )
  out <- apply_pharma_232_adjustments(
    rates, '3004901000', cfg, '4120', pp)
  stopifnot(cfg$country_rates$CTY_UK == 0,
            cfg$target_total$CTY_UK == 0,
            out$rate_232 == 0)
})

run_test('polysilicon product resources separate ad valorem and MIP-only scope', {
  adval <- read_csv(
    here('resources', 's232_polysilicon_adval_products.csv'),
    col_types = cols(.default = col_character()), show_col_types = FALSE)
  mip <- read_csv(
    here('resources', 's232_polysilicon_mip_products.csv'),
    col_types = cols(hts10 = col_character(), mip_amount = col_double(),
                     .default = col_character()), show_col_types = FALSE)
  stopifnot(nrow(adval) == 9, nrow(mip) == 10,
            !'2804610000' %in% adval$hts10,
            '2804610000' %in% mip$hts10,
            setequal(adval$hts10, setdiff(mip$hts10, '2804610000')))
})

run_test('July 2026 484(f) crosswalk reaches every polysilicon wafer suffix', {
  xwalk <- read_csv(
    here('resources', 'hts10_484f_transfers.csv'),
    col_types = cols(.default = col_character()), show_col_types = FALSE)
  successors <- xwalk %>%
    filter(old_hts10 == '3818000095', effective_date == '2026-07-01') %>%
    pull(new_hts10)
  stopifnot(setequal(successors,
    c('3818000040', '3818000045', '3818000050', '3818000091')),
    any(xwalk$old_hts10 == '3818000090' &
        xwalk$new_hts10 == '3818000020'))
})

run_test('polysilicon country tiers are additive except framework total floor', {
  countries <- c('5700', '4120', '4280', '5880', '5800', '5830',
                 '4419', '4411', '1220', '2010')
  cfg <- list(
    default_rate = 0.15,
    country_rates = list(CTY_UK = 0.10),
    target_total = list(
      eu = 0.15, CTY_JAPAN = 0.15, CTY_SKOREA = 0.15,
      CTY_TAIWAN = 0.15, CTY_SWITZERLAND = 0.15,
      CTY_LIECHTENSTEIN = 0.15)
  )
  pp <- list(
    country_codes = list(
      CTY_UK = '4120', CTY_JAPAN = '5880', CTY_SKOREA = '5800',
      CTY_TAIWAN = '5830', CTY_SWITZERLAND = '4419',
      CTY_LIECHTENSTEIN = '4411'),
    EU27_CODES = '4280'
  )
  rates <- tibble(
    hts10 = '8541430010', country = countries,
    base_rate = 0.03, rate_232 = 0.05
  )
  out <- apply_polysilicon_232_adjustments(
    rates, '8541430010', cfg, countries, pp)
  got <- setNames(out$rate_232, out$country)

  stopifnot(abs(got['5700'] - 0.20) < 1e-12,
            abs(got['1220'] - 0.20) < 1e-12,
            abs(got['2010'] - 0.20) < 1e-12,
            abs(got['4120'] - 0.15) < 1e-12,
            all(abs(got[c('4280', '5880', '5800', '5830', '4419', '4411')] -
                    0.17) < 1e-12))
})

run_test('polysilicon activation gate turns on at 2026-12-04', {
  cfg <- list(polysilicon = list(effective_date = '2026-12-04'))
  specs <- list(section_232 = list(programs = list(
    list(id = 'autos_source', rate = list(default = 0)),
    list(id = 'copper_source', rate = list(default = 0)),
    list(id = 'wood_source', rate = list(default = 0)),
    list(id = 'mhd_source', rate = list(default = 0)),
    list(id = 'semiconductors_source', rate = list(default = 0)),
    list(id = 'pharmaceuticals_source', rate = list(default = 0))
  )))
  s232 <- list(auto_has_deals = FALSE, auto_has_parts = FALSE,
               wood_furniture_rate = 0)
  before <- compute_heading_gates(specs, s232, as.Date('2026-12-03'), cfg)
  on_date <- compute_heading_gates(specs, s232, as.Date('2026-12-04'), cfg)
  stopifnot(!before$polysilicon, on_date$polysilicon)
})


# =============================================================================
# Test 14: Applicability-excluded statutory shadow (snapshot-based)
# =============================================================================
#
# Note 33(g) lists bare heading 8471; applicability_share = 0 excludes
# general-purpose computers from the EFFECTIVE auto-parts rates while step 7d
# of 06_calculate_rates.R preserves the literal-enumeration rate in
# statutory_rate_232 (heading rate minus auto rebate) so the
# statutory-vs-collected wedge stays measurable. Skips without built snapshots.

message('\n--- Test 14: Applicability-excluded statutory shadow ---')

run_test('excluded 8471 lines: rate_232 = 0, statutory_rate_232 = literal post-rebate', {
  snap_path <- here('data', 'timeseries', 'snapshot_2026_rev_1.rds')
  if (!file.exists(snap_path)) skip_test('snapshot_2026_rev_1.rds missing')
  ap_path <- here('resources', 's232_auto_parts_applicability.csv')
  if (!file.exists(ap_path)) skip_test('applicability CSV missing')
  ap <- read_csv(ap_path, comment = '#',
                 col_types = cols(hts_prefix = col_character(),
                                  applicability_share = col_double(),
                                  .default = col_character()),
                 show_col_types = FALSE)
  if (!any(ap$applicability_share == 0)) skip_test('no share-0 prefixes configured')

  pp <- load_policy_params()
  rebate <- pp$auto_rebate$rebate_rate * pp$auto_rebate$us_assembly_share
  literal <- pp$section_232_headings$auto_parts$default_rate - rebate

  semi <- read_csv(here('resources', 's232_semi_products.csv'),
                   col_types = cols(hts10 = col_character()),
                   show_col_types = FALSE)$hts10

  s <- readRDS(snap_path)
  zero_prefixes <- ap$hts_prefix[ap$applicability_share == 0]
  pat <- paste0('^(', paste(zero_prefixes, collapse = '|'), ')')
  excluded <- s %>%
    filter(grepl(pat, hts10), !hts10 %in% semi, country == '5830')
  if (nrow(excluded) == 0) skip_test('no excluded-product rows in snapshot')

  # Effective: no auto-parts 232 on the excluded lines
  stopifnot(all(excluded$rate_232 == 0))
  # Statutory: the literal post-rebate heading rate is preserved
  stopifnot(all(abs(excluded$statutory_rate_232 - literal) < 1e-9))
})

run_test('semi-listed 8471 codes keep their true semi statutory (no shadow clobber)', {
  snap_path <- here('data', 'timeseries', 'snapshot_2026_rev_1.rds')
  if (!file.exists(snap_path)) skip_test('snapshot_2026_rev_1.rds missing')
  active <- semi_active_hts10s()
  if (length(active) == 0) skip_test('no semi HTS10s with qualifying_share = 1')
  s <- readRDS(snap_path)
  rows <- s %>% filter(hts10 %in% active, country == '5830')
  if (nrow(rows) == 0) skip_test('no active-semi rows')
  # The semiconductors heading governs these: 0.25, not the auto-parts shadow
  stopifnot(all(abs(rows$rate_232 - 0.25) < 1e-10))
  stopifnot(all(abs(rows$statutory_rate_232 - 0.25) < 1e-10))
})


# =============================================================================
# Test 15: Section 232 steel/aluminum product scope (note-derived, not blanket)
# =============================================================================
#
# The metals 232 programs cover the chapter-99 note 16/19 enumerations, not
# blanket chapters 72/73/76. Pig iron (7201), ferroalloys (7202), scrap
# (7204/7602) and cast-iron tubes (7303) are on no list in any revision;
# the Proc 10895/10896 within-chapter derivative expansion activates
# 2025-03-12; refined copper cathodes (7402/7403) are outside the copper
# scope and must not be inferred annex_1a in the annex era.

message('\n--- Test 15: 232 steel/aluminum product scope ---')

run_test('metal-chapter scope loader date-gates the Proc 10896 expansion', {
  scope_jan <- load_232_metal_chapter_products(effective_date = as.Date('2025-01-01'))
  scope_jun <- load_232_metal_chapter_products(effective_date = as.Date('2025-06-04'))
  if (is.null(scope_jan)) skip_test('s232_metal_chapter_products.csv missing')
  # never-listed upstream/scrap headings absent at every date
  for (bad in c('7201', '7202', '7203', '7204', '7205', '7303', '7602', '7603')) {
    stopifnot(!any(startsWith(scope_jan$hts_prefix, bad)),
              !any(startsWith(scope_jun$hts_prefix, bad)))
  }
  # mill list constant; fasteners (7318) only from 2025-03-12
  stopifnot('7208' %in% scope_jan$hts_prefix,
            !any(startsWith(scope_jan$hts_prefix, '7318')),
            any(startsWith(scope_jun$hts_prefix, '7318')))
})

run_test('classify_s232_annex does NOT chapter-infer scrap/cathodes into annex_1a', {
  annex_path <- here('resources', 's232_annex_products.csv')
  if (!file.exists(annex_path)) skip_test('s232_annex_products.csv missing')
  annex_map <- load_annex_products(as.Date('2026-04-06'), annex_path)
  tiers <- classify_s232_annex(
    c('7204410000', '7403110000', '7201100000', '7602000010',  # out of scope
      '7208100000', '7601103000', '7406100000'),               # in scope (1a)
    annex_map, deriv_products = NULL)
  stopifnot(all(is.na(tiers[1:4])))
  stopifnot(all(tiers[5:7] == 'annex_1a'))
})

run_test('pre-annex snapshot: scrap/pig-iron/ferroalloys carry no 232 rate (rev_14)', {
  snap_path <- here('data', 'timeseries', 'snapshot_rev_14.rds')
  if (!file.exists(snap_path)) skip_test('snapshot_rev_14.rds missing')
  s <- readRDS(snap_path)
  out_rows <- s %>% filter(substr(hts10, 1, 4) %in% c('7201', '7202', '7204', '7303', '7602'))
  if (nrow(out_rows) == 0) skip_test('no out-of-scope metal rows in rev_14')
  if (any(out_rows$rate_232 > 0)) {
    stop('out-of-scope upstream/scrap lines carry 232: snapshot predates the ',
         'scope fix — rebuild snapshot_rev_14.rds')
  }
  # mill products keep the 50% rate (Proc 10947, eff 2025-06-04)
  mill <- s %>% filter(substr(hts10, 1, 4) == '7208', country == '1220')
  stopifnot(nrow(mill) > 0, all(abs(mill$rate_232 - 0.50) < 1e-10))
})

run_test('annex-era snapshot: scrap and copper cathodes are unclassified, 0 rate (2026_rev_5)', {
  snap_path <- here('data', 'timeseries', 'snapshot_2026_rev_5.rds')
  if (!file.exists(snap_path)) skip_test('snapshot_2026_rev_5.rds missing')
  s <- readRDS(snap_path)
  out_rows <- s %>%
    filter(substr(hts10, 1, 4) %in% c('7201', '7202', '7204', '7403', '7602'))
  if (nrow(out_rows) == 0) skip_test('no out-of-scope metal rows in 2026_rev_5')
  if (any(!is.na(out_rows$s232_annex)) || any(out_rows$rate_232 > 0)) {
    stop('out-of-scope upstream/scrap/cathode lines annex-classified or rated: ',
         'snapshot predates the chapter-inference fix — rebuild snapshot_2026_rev_5.rds')
  }
  mill <- s %>% filter(substr(hts10, 1, 4) == '7208')
  stopifnot(nrow(mill) > 0, all(mill$s232_annex == 'annex_1a', na.rm = TRUE))
})


# =============================================================================
# Test 16: Column 2 base rates for non-NTR origins (GN 3(b))
# =============================================================================

message('\n--- Test 16: Column 2 base rates (non-NTR origins) ---')

# Census codes: Russia 4621, Belarus 4622, Cuba 2390, North Korea 5790,
# China 5700 (control, NTR). Verified against resources/census_codes.csv.
COL2_TEST_CONFIG <- tibble(
  country = c('2390', '5790', '4621', '4622'),
  name = c('Cuba', 'North Korea', 'Russia', 'Belarus'),
  effective_date = as.Date(c(NA, NA, '2022-04-09', '2022-04-09'))
)

# Grid of one product across a column-2 origin, a not-yet-column-2 origin and an
# NTR control. col2_rate/col2_rate_type are what build_rate_grid() hands over.
make_col2_grid <- function() {
  tibble(
    hts10 = rep(c('7208100000', '0403200000'), each = 3),
    country = rep(c('4621', '5700', '2390'), 2),
    base_rate = rep(c(0.02, 0.02, 0.02, 0.174, 0.174, 0.174), 1),
    base_rate_type = 'ad_valorem',
    # 7208.10: clean ad valorem in both columns. 0403.20: specific column 2.
    col2_rate = rep(c(0.35, NA_real_), each = 3),
    col2_rate_type = rep(c('ad_valorem', 'specific_or_compound'), each = 3)
  )
}

run_test('column-2 origin gets the column-2 rate, not column 1', {
  g <- apply_column_2_rates(make_col2_grid(), COL2_TEST_CONFIG,
                            effective_date = as.Date('2026-01-15'))
  ru <- g %>% filter(country == '4621', hts10 == '7208100000')
  cu <- g %>% filter(country == '2390', hts10 == '7208100000')
  stopifnot(nrow(ru) == 1, nrow(cu) == 1)
  stopifnot(abs(ru$base_rate - 0.35) < 1e-10)   # column 2, not the 2% column 1
  stopifnot(abs(cu$base_rate - 0.35) < 1e-10)
  stopifnot(ru$base_rate_source == 'col2_other')
  stopifnot(cu$base_rate_source == 'col2_other')
  # Transient product-attribute columns must not survive onto the panel.
  stopifnot(!any(c('col2_rate', 'col2_rate_type') %in% names(g)))
})

run_test('non-column-2 origin is unchanged apart from the provenance flag', {
  before <- make_col2_grid()
  after <- apply_column_2_rates(before, COL2_TEST_CONFIG,
                                effective_date = as.Date('2026-01-15'))
  cn_before <- before %>% filter(country == '5700') %>%
    select(hts10, country, base_rate, base_rate_type) %>% arrange(hts10)
  cn_after <- after %>% filter(country == '5700') %>%
    select(hts10, country, base_rate, base_rate_type) %>% arrange(hts10)
  stopifnot(identical(cn_before, cn_after))
  stopifnot(all((after %>% filter(country == '5700'))$base_rate_source ==
                  'col1_general'))
})

run_test('column 2 is date-gated: PL 117-110 origins do not fire before 2022-04-09', {
  # Same config, a revision predating the Act. Cuba/North Korea (NA date) still
  # fire; Russia must not.
  g <- apply_column_2_rates(make_col2_grid(), COL2_TEST_CONFIG,
                            effective_date = as.Date('2022-04-08'))
  ru <- g %>% filter(country == '4621', hts10 == '7208100000')
  cu <- g %>% filter(country == '2390', hts10 == '7208100000')
  stopifnot(abs(ru$base_rate - 0.02) < 1e-10, ru$base_rate_source == 'col1_general')
  stopifnot(abs(cu$base_rate - 0.35) < 1e-10, cu$base_rate_source == 'col2_other')
  # The boundary day itself IS active (gate is >=).
  g2 <- apply_column_2_rates(make_col2_grid(), COL2_TEST_CONFIG,
                             effective_date = as.Date('2022-04-09'))
  stopifnot((g2 %>% filter(country == '4621', hts10 == '7208100000'))$base_rate_source ==
              'col2_other')
})

run_test('specific/compound column 2 lands at 0 with the type preserved (S2)', {
  g <- apply_column_2_rates(make_col2_grid(), COL2_TEST_CONFIG,
                            effective_date = as.Date('2026-01-15'))
  ru <- g %>% filter(country == '4621', hts10 == '0403200000')
  stopifnot(nrow(ru) == 1)
  # NA numeric -> 0 per S2, NOT a fallback to the 17.4% column-1 rate: a
  # column-2 specific duty is unmodeled, and silently charging column 1 would
  # be a different (wrong) number rather than a visible understatement.
  stopifnot(abs(ru$base_rate) < 1e-10)
  stopifnot(ru$base_rate_type == 'specific_or_compound')
  stopifnot(ru$base_rate_source == 'col2_other')
})

run_test('no column-2 origin active: every row keeps column 1', {
  empty <- COL2_TEST_CONFIG[0, ]
  g <- apply_column_2_rates(make_col2_grid(), empty,
                            effective_date = as.Date('2026-01-15'))
  stopifnot(all(g$base_rate_source == 'col1_general'))
  stopifnot(all(abs(g$base_rate - make_col2_grid()$base_rate) < 1e-10))
})

run_test('column-2 config overlapping the USMCA codes fails loud', {
  bad <- tibble(country = '1220', name = 'Canada (bogus)',
                effective_date = as.Date(NA))
  grid <- make_col2_grid() %>% mutate(country = '1220')
  err <- tryCatch({
    apply_column_2_rates(grid, bad, effective_date = as.Date('2026-01-15'),
                         usmca_countries = c('1220', '2010'))
    NULL
  }, error = function(e) conditionMessage(e))
  stopifnot(!is.null(err), grepl('USMCA', err))
})

run_test('active column-2 origin without parsed col2 columns fails loud', {
  # A stale product cache (pre-col2 parser) must not silently ship column 1.
  grid <- make_col2_grid() %>% select(-col2_rate, -col2_rate_type)
  err <- tryCatch({
    apply_column_2_rates(grid, COL2_TEST_CONFIG,
                         effective_date = as.Date('2026-01-15'))
    NULL
  }, error = function(e) conditionMessage(e))
  stopifnot(!is.null(err), grepl('col2_rate', err))
})

run_test('MFN exemption preference scaling is skipped on column-2 rows', {
  # Step 6c's single withholding point. A column-2 origin has no preference
  # program, so its share must be forced to 0 while NTR rows keep theirs.
  src <- c('col2_other', 'col1_general', 'col2_other', 'col1_general')
  share <- c(0.8, 0.8, 0.25, 0.25)
  out <- zero_exemption_share_for_column_2(share, src)
  stopifnot(identical(out, c(0, 0.8, 0, 0.25)))
  # Consequence that matters: base_rate survives unscaled on column-2 rows, so
  # base_rate == statutory_base_rate and the 6d-6f floor recomputations (gated
  # on base_rate < statutory_base_rate) are no-ops there.
  base <- c(0.35, 0.10, 0.35, 0.10)
  scaled <- base * (1 - out)
  stopifnot(max(abs(scaled - c(0.35, 0.02, 0.35, 0.075))) < 1e-12)
})

run_test('policy_params resolves the four column-2 origins with verified codes', {
  pp <- load_policy_params()
  c2 <- pp$COLUMN_2_COUNTRIES
  stopifnot(is.data.frame(c2), nrow(c2) == 4)
  stopifnot(setequal(c2$country, c('2390', '4621', '4622', '5790')))
  # Cuba / North Korea are always column 2; Russia / Belarus from PL 117-110.
  always <- c2$country[is.na(c2$effective_date)]
  stopifnot(setequal(always, c('2390', '5790')))
  dated <- c2 %>% filter(!is.na(effective_date))
  stopifnot(setequal(dated$country, c('4621', '4622')))
  stopifnot(all(dated$effective_date == as.Date('2022-04-09')))
  # Every code must exist in the Census universe — a typo'd code would silently
  # never match a panel row.
  codes_path <- here('resources', 'census_codes.csv')
  if (file.exists(codes_path)) {
    census <- read_csv(codes_path, show_col_types = FALSE,
                       col_types = cols(.default = col_character()))
    stopifnot(all(c2$country %in% census[[1]]))
  }
  # And none may collide with CA/MX (asserted at runtime too).
  stopifnot(length(intersect(c2$country, c('1220', '2010'))) == 0)
})


# --- GN 3(b) IEEPA reciprocal exemption (heading 9903.01.29) -----------------

.gn3b_frame <- function() {
  tibble(
    country = c('4621', '2390', '5700', '4280'),   # Russia, Cuba, China, Germany
    rate_ieepa_recip = c(0.10, 0.10, 0.34, 0.15)
  )
}
.gn3b_cfg <- function() {
  tibble(country = c('2390', '5790', '4621', '4622'),
         name = c('Cuba', 'North Korea', 'Russia', 'Belarus'),
         effective_date = as.Date(c(NA, NA, '2022-04-09', '2022-04-09')))
}

run_test('GN 3(b) origins lose the IEEPA reciprocal duty; others keep it', {
  out <- apply_gn3b_ieepa_exemption(.gn3b_frame(), .gn3b_cfg(),
                                    as.Date('2025-09-01'))
  stopifnot(out$rate_ieepa_recip[out$country == '4621'] == 0)   # Russia
  stopifnot(out$rate_ieepa_recip[out$country == '2390'] == 0)   # Cuba
  # Non-GN-3(b) origins untouched
  stopifnot(abs(out$rate_ieepa_recip[out$country == '5700'] - 0.34) < 1e-12)
  stopifnot(abs(out$rate_ieepa_recip[out$country == '4280'] - 0.15) < 1e-12)
})

run_test('GN 3(b) exemption respects the PL 117-110 effective date', {
  # Before 2022-04-09 Russia was an NTR partner: reciprocal duty stands (the
  # program does not exist that early, but the gate must still be date-driven).
  out <- apply_gn3b_ieepa_exemption(.gn3b_frame(), .gn3b_cfg(),
                                    as.Date('2022-01-01'))
  stopifnot(abs(out$rate_ieepa_recip[out$country == '4621'] - 0.10) < 1e-12)
  stopifnot(out$rate_ieepa_recip[out$country == '2390'] == 0)   # Cuba: always
})

run_test('GN 3(b) exemption is inert without the column, config, or matches', {
  # No rate_ieepa_recip column (pre-IEEPA fixture) => unchanged frame
  f <- tibble(country = c('4621', '5700'))
  stopifnot(identical(apply_gn3b_ieepa_exemption(f, .gn3b_cfg(),
                                                 as.Date('2025-09-01')), f))
  # Empty config => unchanged
  empty <- tibble(country = character(), name = character(),
                  effective_date = as.Date(character()))
  g <- .gn3b_frame()
  stopifnot(identical(apply_gn3b_ieepa_exemption(g, empty,
                                                 as.Date('2025-09-01')), g))
  # No GN 3(b) origin present in the country set => unchanged
  h <- tibble(country = c('5700', '4280'), rate_ieepa_recip = c(0.34, 0.15))
  stopifnot(identical(apply_gn3b_ieepa_exemption(h, .gn3b_cfg(),
                                                 as.Date('2025-09-01')), h))
})


# =============================================================================
# Summary
# =============================================================================

cat('\n', strrep('=', 50), '\n')
cat('Tests: ', pass_count, ' passed, ', skip_count, ' skipped, ', fail_count, ' failed\n')
cat(strrep('=', 50), '\n')

if (fail_count > 0) quit(status = 1)
