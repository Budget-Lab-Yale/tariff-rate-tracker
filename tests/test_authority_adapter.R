# =============================================================================
# authority_adapter unit tests
# =============================================================================
# Pure-logic checks for src/model/authority_adapter.R — the lossless re-packaging.
# The crux of parity (Phase 6b): the residual BLOB objects (s232_rates [decision-8
# §232 residual], fentanyl_rates) are parked VERBATIM in their owning program's
# rate$resolved slot and read back via *_from_specs() UNCHANGED. section_122 was
# DE-BLOBBED in Plank 3 (rate$default); ieepa_reciprocal was DE-BLOBBED in Plank 4b/S1
# — the adapter resolves the per-country table (phase-collapse + floor override) into
# structured rate layers (by_country + companions + default_unlisted_rate), no
# rate$resolved blob. No model data.
#
# get_country_constants() / load_policy_params() (normally from
# 05_parse_policy_params.R) are stubbed so this runs without the parser
# pipeline. Usage: Rscript tests/test_authority_adapter.R
# =============================================================================

suppressPackageStartupMessages(library(here))
source(here('src', 'model', 'authority_spec.R'))

# --- stubs (stand in for 05_parse_policy_params.R / rate_schema.R / 06; resolved
#     at call time in the global env) ----------------------------------------
load_policy_params    <- function() list()
get_country_constants <- function(pp) list(
  CTY_CHINA = '5700', CTY_CANADA = '1220', CTY_MEXICO = '2010',
  # S2 deals slice: the adapter census-expands deal ISO/EU via cc$ISO_TO_CENSUS / cc$EU27_CODES.
  ISO_TO_CENSUS = c('UK' = '4120', 'GB' = '4120', 'JP' = '5880', 'KR' = '5800',
                    'CN' = '5700', 'CA' = '1220', 'MX' = '2010'),
  EU27_CODES = c('4330','4231','4870','4791','4910','4351','4099','4470','4050','4279',
                 '4280','4840','4370','4190','4759','4490','4510','4239','4730','4210',
                 '4550','4710','4850','4359','4792','4700','4010'))
filter_active_ch99    <- function(ch99_data, effective_date) ch99_data
HEADING_GATES_SENTINEL <- list(autos_passenger = TRUE, copper = FALSE)
compute_heading_gates <- function(specs, s232_rates) HEADING_GATES_SENTINEL  # S1b: (specs, s232_rates)
S122_SENTINEL <- list(s122_rate = 0.10, has_s122 = TRUE)   # Phase 6a
extract_section122_rates <- function(ch99_data) S122_SENTINEL
# S2 (blanket slice): the adapter calls is_232_exempt over `countries` to build the
# steel/aluminum by_country overlay. Census-only stub (the test data uses census codes).
is_232_exempt <- function(census_code, exempt_list) isTRUE(census_code %in% exempt_list)
# Pass-1.5: build_authority_specs now bakes the IEEPA floor exempt set onto the
# spec via load_revision_floor_exemptions (data_loaders.R, not sourced here).
load_revision_floor_exemptions <- function(revision_id, effective_date = NULL)
  tibble::tibble(hts8 = character(), country_group = character())

source(here('src', 'model', 'authority_adapter.R'))

pass <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:', msg, '\n')
}

# --- synthetic raw objects (contents opaque to the adapter; only identity matters)
# Plank 4b/S1: ieepa_reciprocal is de-blobbed, so the fixture carries the real
# parsed columns the adapter's phase-collapse consumes (census_code/phase/rate_type).
ieepa <- data.frame(
  ch99_code = c('9903.02.09', '9903.02.12'), rate = c(0.20, 0.10),
  rate_type = c('surcharge', 'surcharge'), phase = c('phase2_aug7', 'phase2_aug7'),
  terminated = FALSE, country_name = NA_character_,
  census_code = c('5700', '4280'), stringsAsFactors = FALSE)
attr(ieepa, 'universal_baseline') <- 0.10        # -> rate$default_unlisted_rate
s232  <- list(has_232 = TRUE, steel_rate = 0.50, aluminum_rate = 0.50,
              steel_exempt = c('1220'),
              # S2 deals slice: auto (UK surcharge vehicles + EU floor vehicles) + wood (UK surcharge)
              auto_deal_rates = data.frame(
                country = c('UK', 'EU'), rate = c(0.075, 0.15),
                rate_type = c('surcharge', 'floor'),
                program = c('auto_vehicles', 'auto_vehicles'),
                ch99_code = c('9903.94.31', '9903.94.32'), stringsAsFactors = FALSE),
              wood_deal_rates = data.frame(
                country = 'UK', rate = 0.10, rate_type = 'surcharge',
                program = 'softwood', ch99_code = '9903.76.01', stringsAsFactors = FALSE))
# Plank 4b/S2: ieepa_fentanyl is de-blobbed too — fixture carries the real parsed
# columns (entry_type/census_code). China .20+10% / .24+20% -> max-per-census 0.20.
fent  <- data.frame(
  ch99_code = c('9903.01.20', '9903.01.24', '9903.01.10', '9903.01.01', '9903.01.13'),
  rate = c(0.10, 0.20, 0.35, 0.25, 0.10),
  country_name = NA_character_,
  census_code = c('5700', '5700', '1220', '2010', '1220'),
  entry_type = c('general', 'general', 'general', 'general', 'carveout'),
  stringsAsFactors = FALSE)

cat('--- build_authority_specs (no IEEPA invalidation) ---\n')
specs <- build_authority_specs(
  products = data.frame(), ch99_data = data.frame(),
  ieepa_rates = ieepa, usmca = data.frame(),
  countries = c('5700', '1220', '2010'),
  revision_id = 'rev_test', effective_date = as.Date('2025-06-01'),
  s232_rates = s232, fentanyl_rates = fent, policy_params = list()
)

check(is_authority_spec_set(specs), 'returns an authority_spec_set')
check(setequal(names(specs),
               c('section_232', 'section_301', 'ieepa_reciprocal', 'ieepa_fentanyl',
                 'section_122', 'section_201', 'mfn', 'other')),
      'all eight authorities present')
check(isTRUE(validate_spec_set(specs)), 'validates (fail-loud passed inside)')

cat('\n--- lossless relocation: identical R objects in programs[[1]]$rate$resolved ---\n')
check(identical(s232_rates_from_specs(specs), s232),
      's232 21-field list reachable via s232_rates_from_specs (parked on programs[[1]])')
check(is.null(specs[['ieepa_reciprocal']]$programs[[1]]$rate$resolved),
      'ieepa_reciprocal carries NO resolved blob (Plank 4b/S1 de-blobbed)')
check(isTRUE(all.equal(unname(specs[['ieepa_reciprocal']]$programs[[1]]$rate$by_country['5700']), 0.20)),
      'ieepa reciprocal rate$by_country resolved from spec (China 0.20)')
check(is.null(specs[['ieepa_fentanyl']]$programs[[1]]$rate$resolved),
      'ieepa_fentanyl carries NO resolved blob (Plank 4b/S2 de-blobbed)')
check(isTRUE(all.equal(unname(specs[['ieepa_fentanyl']]$programs[[1]]$rate$by_country['5700']), 0.20)),
      'fentanyl rate$by_country = max-per-census general (China 0.10/0.20 -> 0.20)')
check(identical(specs[['ieepa_fentanyl']]$programs[[1]]$rate$carveouts$ch99_code, '9903.01.13'),
      'fentanyl rate$carveouts carries the carve-out entry (9903.01.13)')
check(identical(specs[['section_122']]$programs[[1]]$rate$default, S122_SENTINEL$s122_rate),
      's122 blanket rate structured into rate$default (Plank 3, de-blobbed)')
check(identical(specs[['section_122']]$programs[[1]]$rate$rate_type, 'surcharge'),
      's122 rate_type = surcharge (additive blanket duty)')
check(is.null(specs[['section_122']]$programs[[1]]$rate$resolved),
      's122 carries NO resolved blob (de-blobbed in Plank 3)')
check(isTRUE(all.equal(specs[['ieepa_reciprocal']]$programs[[1]]$rate$default_unlisted_rate, 0.10)),
      'universal_baseline -> ieepa_reciprocal rate$default_unlisted_rate (de-blobbed)')
check(is.null(attr(specs[['section_232']], 'raw_s232', exact = TRUE)),
      'no out-of-band raw_s232 attr remains (Phase 6b cleanup)')

cat('\n--- Plank 4a / S1a: blanket metal + auto base rates de-blobbed to rate$default ---\n')
s232_progs <- specs[['section_232']]$programs
.prog <- function(id) s232_progs[[which(vapply(s232_progs, function(p) identical(p$id, id), logical(1)))]]
check(identical(.prog('steel')$rate$default, 0.50),
      'steel base rate structured into rate$default (S1a, = s232$steel_rate)')
check(identical(.prog('aluminum')$rate$default, 0.50),
      'aluminum base rate structured into rate$default (S1a)')
check(identical(.prog('autos')$rate$default, 0),
      'autos base rate -> rate$default = 0 when s232$auto_rate absent (verbatim, incl. 0)')
check(identical(.prog('steel')$rate$rate_type, 'surcharge'),
      '232 program rate_type = surcharge (additive)')
check(identical(resolve_rate(.prog('steel')$rate)$value, 0.50),
      'calc-side read: resolve_rate(steel program) = 0.50 (the de-blobbed base)')
check(identical(resolve_rate(.prog('autos')$rate)$value, 0),
      'calc-side read: resolve_rate(autos program) = 0 (not NA) — baseline-safe')
check(identical(s232_rates_from_specs(specs), s232),
      'S1a coexistence: the residual resolved blob is still parked on programs[[1]] verbatim')

cat('\n--- Plank 4a / S2: steel/aluminum exempt + overrides + config -> rate$by_country ---\n')
check(identical(.prog('steel')$rate$by_country, stats::setNames(0, '1220')),
      'steel exempt list ({Canada}) de-blobbed to rate$by_country = {1220: 0} (S2)')
check(is.null(.prog('aluminum')$rate$by_country),
      'aluminum (no exempt/override/config) -> no by_country overlay (NULL)')
check(identical(resolve_rate(.prog('steel')$rate, product = NULL, country = '1220')$value, 0),
      'calc read: resolve_rate(steel, country=Canada) = 0 (exempt via by_country)')
check(identical(resolve_rate(.prog('steel')$rate, product = NULL, country = '5700')$value, 0.50),
      'calc read: resolve_rate(steel, country=China) = 0.50 (base; not in by_country)')

cat('\n--- Plank 4a / S2 deals: auto/wood deals -> rate$overrides (surcharge) + rate$floors ---\n')
.autos <- .prog('autos')
check(length(.autos$rate$overrides) == 1L &&
      identical(.autos$rate$overrides[[1]]$rate, 0.075) &&
      identical(.autos$rate$overrides[[1]]$scope, 'auto_vehicles'),
      'autos surcharge deal -> rate$overrides scope-form {scope, rate} (S2 deals)')
check(identical(.autos$rate$overrides[[1]]$countries, '4120'),
      'autos override UK ISO->census (4120) at build time')
check(length(.autos$rate$floors) == 1L &&
      identical(.autos$rate$floors[[1]]$floor, 0.15) &&
      length(.autos$rate$floors[[1]]$countries) == 27L,
      'autos floor deal (EU) -> rate$floors, EU expanded to 27 census codes')
check(identical(resolve_rate(.autos$rate, product = NULL, country = '4120')$value, 0),
      'scope-form overrides/floors invisible to resolve_rate: returns default(0), not the deal rate')
check(length(.prog('wood')$rate$overrides) == 1L &&
      identical(.prog('wood')$rate$overrides[[1]]$rate, 0.10) &&
      identical(.prog('wood')$rate$overrides[[1]]$scope, 'softwood'),
      'wood surcharge deal -> wood program rate$overrides (S2 deals)')
check(isTRUE(validate_spec_set(specs)),
      'spec set with scope-form overrides + floors still validates (Plank-0 additive change)')

cat('\n--- Plank 4a / S1b: heading programs de-blobbed + dormant pharmaceuticals program ---\n')
prog_ids <- vapply(s232_progs, function(p) p$id, character(1))
check(length(s232_progs) == 8L && 'pharmaceuticals' %in% prog_ids,
      'section_232 has 8 programs incl. the dormant pharmaceuticals (S1b)')
check(identical(.prog('copper')$rate$default, 0) &&
      identical(.prog('mhd')$rate$default, 0) &&
      identical(.prog('wood')$rate$default, 0) &&
      identical(.prog('semiconductors')$rate$default, 0) &&
      identical(.prog('pharmaceuticals')$rate$default, 0),
      'copper/mhd/wood/semi/pharma base rates -> rate$default = 0 (absent in stub)')
check(identical(resolve_rate(.prog('pharmaceuticals')$rate)$value, 0),
      'calc-side read: resolve_rate(pharmaceuticals) = 0 (dormant, baseline-safe)')

cat('\n--- normalized scaffold (not read in Phase 1, but should be faithful) ---\n')
check(identical(specs[['section_301']]$programs[[1]]$country_scope$include, '5700'),
      '301 China gate captured as country_scope data')
check(identical(specs[['section_201']]$programs[[1]]$country_scope$exclude, '1220'),
      '201 Canada exemption captured as country_scope exclude')
check(identical(specs[['section_232']]$stacking$class, 'primary_metal'),
      '232 authority stacking.class = primary_metal')
check(identical(attr(specs[['section_232']], 'heading_gates', exact = TRUE),
                HEADING_GATES_SENTINEL),
      '232 heading_gates precomputed onto the spec (Phase 2c)')

cat('\n--- serialization round-trip preserves relocated payloads + nested attrs ---\n')
tmp <- tempfile(fileext = '.rds')
saveRDS(specs, tmp)
specs2 <- readRDS(tmp)
check(identical(s232_rates_from_specs(specs2), s232),
      's232 program rate$resolved survives saveRDS/readRDS')
check(identical(specs2[['section_122']]$programs[[1]]$rate$default, S122_SENTINEL$s122_rate),
      's122 program rate$default survives saveRDS/readRDS')
check(isTRUE(all.equal(specs2[['ieepa_reciprocal']]$programs[[1]]$rate$default_unlisted_rate, 0.10)),
      'ieepa_reciprocal default_unlisted_rate survives saveRDS/readRDS')
check(isTRUE(validate_spec_set(specs2)), 'round-tripped set still validates')

cat('\n--- IEEPA invalidation maps to active.until on both ieepa specs ---\n')
specs_inv <- build_authority_specs(
  products = data.frame(), ch99_data = data.frame(),
  ieepa_rates = ieepa, usmca = data.frame(),
  countries = '5700', revision_id = 'rev_inv', effective_date = as.Date('2026-03-01'),
  s232_rates = s232, fentanyl_rates = fent,
  policy_params = list(IEEPA_INVALIDATION_DATE = as.Date('2026-02-24'))
)
check(identical(specs_inv[['ieepa_reciprocal']]$active$until, as.Date('2026-02-24')),
      'reciprocal active.until = invalidation date')
check(identical(specs_inv[['ieepa_fentanyl']]$active$until, as.Date('2026-02-24')),
      'fentanyl active.until = invalidation date')

cat('\n--- Annex era: UK qualifying-content blend + third-country surcharge share ---\n')
# Stubs for the annex branch (data_loaders not sourced here). Fixture products:
#   7208100000 -> annex_1a steel (flat 0.50, uk_rate 0.25)
#   7326908688 -> annex_1b steel (flat 0.25, uk_rate 0.15)
#   7601103000 -> annex_1a aluminum (Russia surcharge product set)
load_annex_products <- function(effective_date, path) tibble::tibble(hts_prefix = '72')
load_232_derivative_products <- function(effective_date = NULL) NULL
classify_s232_annex <- function(hts, annex_map, deriv, a1a_ch) {
  c('7208100000' = 'annex_1a', '7326908688' = 'annex_1b',
    '7601103000' = 'annex_1a')[hts]
}
get_country_constants <- function(pp) list(
  CTY_CHINA = '5700', CTY_CANADA = '1220', CTY_MEXICO = '2010', CTY_UK = '4120',
  STEEL_CHAPTERS = c('72', '73'), ALUM_CHAPTERS = '76', COPPER_CHAPTERS = '74',
  ISO_TO_CENSUS = c('UK' = '4120', 'GB' = '4120', 'JP' = '5880', 'KR' = '5800',
                    'CN' = '5700', 'CA' = '1220', 'MX' = '2010'),
  EU27_CODES = character(0))

pp_annex <- list(S232_ANNEXES = list(   # the parsed/derived key (policy_params.R:233)
  effective_date = '2026-04-06',
  uk_content_qualifying_share = 0.30,
  annexes = list(
    annex_1a = list(rate = 0.50, uk_rate = 0.25, chapters = list('72', '73', '76', '74')),
    annex_1b = list(rate = 0.25, uk_rate = 0.15),
    annex_1c = list(rate = 0.25),
    annex_2  = list(rate = 0.0),
    annex_3  = list(floor_rate = 0.15)),
  country_surcharges = list(list(
    countries = list('4621'), rate = 2.0,
    applies_to = list('annex_1a', 'annex_1b', 'annex_3'),
    metal_types = list('aluminum'),
    third_country_content_share = 0.05))
))

annex_products <- data.frame(hts10 = c('7208100000', '7326908688', '7601103000'))
specs_annex <- build_authority_specs(
  products = annex_products, ch99_data = data.frame(),
  ieepa_rates = ieepa, usmca = data.frame(),
  countries = c('4120', '4621', '5700'),
  revision_id = 'rev_annex', effective_date = as.Date('2026-05-01'),
  s232_rates = s232, fentanyl_rates = fent, policy_params = pp_annex
)
ovs <- specs_annex[['section_232']]$annex$country_overrides
check(length(ovs) == 3,
      'three overrides: UK blend + Russia listed + Russia third-country')

uk_ov <- ovs[[1]]
check(identical(uk_ov$countries, '4120') && identical(uk_ov$mode, 'replace'),
      'override 1 is the UK replace deal')
check(isTRUE(all.equal(unname(uk_ov$rate_map['7208100000']), 0.30 * 0.25 + 0.70 * 0.50)),
      'UK annex_1a blend: 0.3*0.25 + 0.7*0.50 = 0.425')
check(isTRUE(all.equal(unname(uk_ov$rate_map['7326908688']), 0.30 * 0.15 + 0.70 * 0.25)),
      'UK annex_1b blend: 0.3*0.15 + 0.7*0.25 = 0.22')

ru_ov <- ovs[[2]]
check(identical(ru_ov$countries, '4621') && identical(ru_ov$mode, 'max') &&
        isTRUE(all.equal(unname(ru_ov$rate_map['7601103000']), 2.0)),
      'Russia listed-country surcharge unchanged (2.0 on the aluminum product)')

tc_ov <- ovs[[3]]
check(setequal(tc_ov$countries, c('4120', '5700')) && identical(tc_ov$mode, 'max'),
      'third-country override covers all non-listed countries, mode max')
check(isTRUE(all.equal(unname(tc_ov$rate_map['7601103000']), 2.0 * 0.05)),
      'third-country surcharge = rate * content share (0.10)')

# Defaults: q omitted -> 1.0 (byte-identical legacy UK deal); share omitted -> no override
pp_annex_default <- pp_annex
pp_annex_default$S232_ANNEXES$uk_content_qualifying_share <- NULL
pp_annex_default$S232_ANNEXES$country_surcharges[[1]]$third_country_content_share <- NULL
specs_def <- build_authority_specs(
  products = annex_products, ch99_data = data.frame(),
  ieepa_rates = ieepa, usmca = data.frame(),
  countries = c('4120', '4621', '5700'),
  revision_id = 'rev_annex_def', effective_date = as.Date('2026-05-01'),
  s232_rates = s232, fentanyl_rates = fent, policy_params = pp_annex_default
)
ovs_def <- specs_def[['section_232']]$annex$country_overrides
check(length(ovs_def) == 2,
      'defaults: no third-country override (share 0 dormant)')
check(isTRUE(all.equal(unname(ovs_def[[1]]$rate_map['7208100000']), 0.25)) &&
        isTRUE(all.equal(unname(ovs_def[[1]]$rate_map['7326908688']), 0.15)),
      'defaults: UK rate_map = unconditional uk_rate (q = 1.0, legacy-identical)')

cat(sprintf('\nALL %d AUTHORITY_ADAPTER ASSERTIONS PASSED\n', pass))
