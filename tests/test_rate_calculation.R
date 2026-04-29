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

source(here('src', 'helpers.R'))
source(here('src', '03_parse_chapter99.R'))
source(here('src', '04_parse_products.R'))
source(here('src', '05_parse_policy_params.R'))
source(here('src', '06_calculate_rates.R'))

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

run_test('rate_301 only contributes for China in decomposition', {
  rates <- make_test_rates()
  net <- compute_net_authority_contributions(rates, cty_china = '5700')
  non_china <- net %>% filter(country != '5700')
  stopifnot(all(non_china$net_301 == 0))
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

run_test('fills NAs in rate columns with 0', {
  df <- tibble(
    hts10 = '0101300000', country = '5700',
    base_rate = NA_real_, rate_232 = NA_real_,
    total_rate = NA_real_
  )
  result <- enforce_rate_schema(df)
  stopifnot(result$base_rate == 0)
  stopifnot(result$rate_232 == 0)
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

run_test('tpc_additive stacks all authorities', {
  df <- tibble(
    hts10 = '7208100000', country = '5700',
    base_rate = 0, rate_232 = 0.25, rate_301 = 0.25,
    rate_ieepa_recip = 0.34, rate_ieepa_fent = 0.20,
    rate_s122 = 0.10, rate_section_201 = 0, rate_other = 0,
    metal_share = 1.0
  )
  result <- apply_stacking_rules(df, cty_china = '5700', stacking_method = 'tpc_additive')
  expected <- 0.25 + 0.25 + 0.34 + 0.20 + 0.10
  stopifnot(abs(result$total_additional - expected) < 1e-10)
})

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
  ru_a2 <- s %>% filter(country == '4621', s232_annex == 'annex_2')
  if (nrow(ru_a2) == 0) skip_test('no Russia × annex_2 rows')
  # Annex II removes products from S232 entirely; surcharge does not apply.
  # The only non-zero rate_232 allowed here is the semi override (25%).
  semi <- if (file.exists(here('resources', 's232_semi_products.csv'))) {
    read_csv(here('resources', 's232_semi_products.csv'),
             col_types = cols(hts10 = col_character()),
             show_col_types = FALSE)$hts10
  } else character(0)
  non_semi_a2 <- ru_a2 %>% filter(!(hts10 %in% semi))
  stopifnot(all(non_semi_a2$rate_232 == 0))
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

run_test('Annex II × rate_232>0 is semi-products-only (Note 39a invariant)', {
  if (!file.exists(rev5_snapshot_path)) skip_test('snapshot_2026_rev_5.rds missing')
  semi_path <- here('resources', 's232_semi_products.csv')
  if (!file.exists(semi_path)) skip_test('s232_semi_products.csv missing')
  s <- readRDS(rev5_snapshot_path)
  semi <- read_csv(semi_path,
                   col_types = cols(hts10 = col_character()),
                   show_col_types = FALSE)$hts10
  leak <- s %>%
    filter(s232_annex == 'annex_2', rate_232 > 0) %>%
    filter(!(hts10 %in% semi))
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
# Summary
# =============================================================================

cat('\n', strrep('=', 50), '\n')
cat('Tests: ', pass_count, ' passed, ', skip_count, ' skipped, ', fail_count, ' failed\n')
cat(strrep('=', 50), '\n')

if (fail_count > 0) quit(status = 1)
