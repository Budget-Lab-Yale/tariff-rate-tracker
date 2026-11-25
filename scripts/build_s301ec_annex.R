#!/usr/bin/env Rscript

# Build the product lists the Section 301 "excess capacity" calculator reads
# from the agreed annex extraction of the 14 USTR notices of 2026-11-25.
#
# Usage:
#   Rscript scripts/build_s301ec_annex.R
#
# Input:  data/s301_excess_capacity/consensus_exemptions.csv
#         (economy, annex, hts_code, digits, scope_limitation, page; the script
#         that parsed the notices sits beside it).
# Output: resources/s301ec_common_exemptions.csv   hts_code, condition
#           The 2,121 lines printed in all 14 notices. For the 13 economies
#           other than China they are exempt; for China they are Annex A, the
#           lines that pay 10% instead of the general rate.
#         resources/s301ec_country_exemptions.csv  countries, hts_code, condition
#           The extra lines seven economies exempt for their own goods.
#           `countries` holds Census codes joined by ';' (the EU is 27 codes).
#         resources/s301ec_china_annex_b.csv       hts_code, condition
#           China's Annex B, the 77 exempt consumer-goods lines.
#
# `condition` follows the forced-labor files: full (the whole line), ex (part
# of the line; modeled as the whole line), aircraft or pharma (exempt only for
# that use).

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(here)
  library(yaml)
})

check <- function(ok, msg) if (!isTRUE(ok)) stop('build_s301ec_annex: ', msg, call. = FALSE)

src <- read_csv(here('data', 's301_excess_capacity', 'consensus_exemptions.csv'),
                col_types = cols(.default = col_character()))
condition_of <- c(none = 'full', Ex = 'ex', Aircraft = 'aircraft', Pharma = 'pharma')
check(all(src$scope_limitation %in% names(condition_of)), 'unknown scope limitation')
check(all(nchar(src$hts_code) == as.integer(src$digits)) &&
        all(nchar(src$hts_code) %in% c(8L, 10L)), 'HTS codes must have 8 or 10 digits')
src <- src %>% mutate(condition = unname(condition_of[scope_limitation]))

# Counts stated in the decision record.
check(nrow(src) == 30564, 'expected 30,564 annex rows')
check(nrow(distinct(src, economy, hts_code)) == 30555,
      'expected 30,555 distinct economy-line pairs')
check(n_distinct(src$economy) == 14, 'expected 14 economies')

# The common list is China's Annex A. Every other notice must print the same
# lines with the same use flags.
common <- src %>% filter(economy == 'china', annex == 'A') %>% select(hts_code, condition)
check(nrow(common) == 2121 && !anyDuplicated(common$hts_code), 'expected 2,121 common lines')
for (e in unique(src$economy)) {
  missing <- anti_join(common, filter(src, economy == e), by = c('hts_code', 'condition'))
  check(nrow(missing) == 0, paste0(e, ' does not carry the full common list'))
}
check(sum(common$condition %in% c('aircraft', 'pharma')) == 1241,
      'expected 1,241 use-conditional common lines')

# The common list is the forced-labor common list plus agglomerated iron ore.
fl_common <- read_csv(here('resources', 's301fl_final_common_exemptions.csv'),
                      col_types = cols(.default = col_character()))
extra <- anti_join(common, fl_common, by = c('hts_code', 'condition'))
check(identical(extra$hts_code, '26011200') &&
        nrow(anti_join(fl_common, common, by = c('hts_code', 'condition'))) == 0,
      'common list should equal the forced-labor common list plus 2601.12.00')

annex_b <- src %>% filter(economy == 'china', annex == 'B') %>% select(hts_code, condition)
check(nrow(annex_b) == 77, 'expected 77 China Annex B lines')

# Country lists: whatever an economy prints beyond the common list.
own <- src %>%
  filter(economy != 'china') %>%
  anti_join(common, by = c('hts_code', 'condition')) %>%
  select(economy, hts_code, condition)
expected_own <- c(bangladesh = 87, cambodia = 157, eu = 45, indonesia = 148,
                  malaysia = 104, switzerland = 134, taiwan = 118)
got_own <- table(own$economy)
check(identical(sort(names(got_own)), sort(names(expected_own))) &&
        all(got_own[names(expected_own)] == expected_own),
      'country-list row counts differ from the decision record')
check(all(own$condition %in% c('full', 'ex')), 'country lists should carry no use flags')
# 4504.90.00 (cork) is aircraft-only in the common list and unflagged in each
# country list, so those seven economies exempt it in full.
check(all(table(own$economy[own$hts_code == '45049000']) == 1) &&
        sum(own$hts_code == '45049000') == 7, '4504.90.00 should be on all seven country lists')

# Census codes come from the policy file, so the lists and the rates agree.
pp <- read_yaml(here('config', 'policy_params.yaml'))
economies <- pp$section_301_excess_capacity$economies
codes_of <- function(e) {
  codes <- unlist(economies[[e]]$countries)
  if (identical(codes, 'eu27')) codes <- names(pp$eu27_codes)
  paste(sort(as.character(codes)), collapse = ';')
}
check(all(unique(src$economy) %in% names(economies)), 'an economy is missing from policy_params')
country <- own %>%
  mutate(countries = vapply(economy, codes_of, character(1))) %>%
  select(countries, hts_code, condition)

write_csv(common, here('resources', 's301ec_common_exemptions.csv'))
write_csv(country, here('resources', 's301ec_country_exemptions.csv'))
write_csv(annex_b, here('resources', 's301ec_china_annex_b.csv'))
message('Wrote ', nrow(common), ' common lines, ', nrow(country),
        ' country-list lines and ', nrow(annex_b), ' China Annex B lines.')
