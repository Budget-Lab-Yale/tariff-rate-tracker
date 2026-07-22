# =============================================================================
# Plank 4b / S1 — IEEPA reciprocal de-blob: adapter-vs-calc equivalence
# =============================================================================
# .resolve_ieepa_reciprocal() (src/model/authority_adapter.R) relocates the calculator's
# reciprocal phase-collapse + surcharge->floor override out of 06_calculate_rates.R
# and into the adapter, emitting structured per-country rate layers. This test runs
# the ORIGINAL calc code (copied verbatim below as the ORACLE) on a realistic
# ieepa_rates fixture and asserts the adapter helper reconstructs the SAME
# country_ieepa table bit-for-bit — the relocation is bit-exact by construction, so
# any divergence here is a transcription error caught before the 43-rev parity gate.
#
# Usage: module load R/4.4.2-gfbf-2024a && Rscript tests/test_ieepa_deblob.R
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(dplyr)
  library(tibble)
})
source(here('src', 'model', 'authority_spec.R'))

# stubs so authority_adapter.R sources + the end-to-end build run without the
# parser pipeline (mirrors tests/test_authority_adapter.R).
load_policy_params    <- function() list()
get_country_constants <- function(pp) list(
  CTY_CHINA = '5700', CTY_CANADA = '1220', CTY_MEXICO = '2010',
  ISO_TO_CENSUS = c('UK' = '4120', 'JP' = '5880', 'KR' = '5800', 'CN' = '5700'),
  EU27_CODES = c('4279', '4280', '4330'))
filter_active_ch99       <- function(ch99_data, effective_date) ch99_data
compute_heading_gates    <- function(specs, s232_rates) list()
extract_section122_rates <- function(ch99_data) list(s122_rate = 0.10, has_s122 = TRUE)
is_232_exempt            <- function(census_code, exempt_list) isTRUE(census_code %in% exempt_list)
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

# --- the ORACLE: the EXACT pre-S1 calc code (phase-collapse + floor override) -----
# Returns the post-override country_ieepa table (listed countries) the calc built.
oracle_country_ieepa <- function(ieepa_rates, pp, effective_date) {
  active_ieepa <- ieepa_rates %>% filter(!is.na(census_code), !is.na(rate))
  if (nrow(active_ieepa) == 0) return(NULL)
  country_ieepa <- active_ieepa %>%
    mutate(
      active_rank = if_else(phase %in% c('phase2_aug7', 'country_eo'), 1L, 2L),
      type_priority = case_when(
        rate_type == 'floor' ~ 1L,
        rate_type == 'surcharge' ~ 2L,
        rate_type == 'passthrough' ~ 3L,
        TRUE ~ 4L
      )
    ) %>%
    group_by(census_code) %>%
    filter(active_rank == min(active_rank)) %>%
    ungroup() %>%
    group_by(census_code, phase) %>%
    arrange(type_priority, desc(rate)) %>%
    summarise(phase_rate = first(rate), phase_type = first(rate_type),
              phase_ch99_code = first(ch99_code), .groups = 'drop') %>%
    group_by(census_code) %>%
    summarise(
      ieepa_country_rate = sum(phase_rate),
      country_eo_rate = sum(phase_rate[phase == 'country_eo']),
      country_eo_ch99 = {
        ce <- phase_ch99_code[phase == 'country_eo']
        if (length(ce) > 0) ce[1] else NA_character_
      },
      ieepa_type = first(phase_type),
      is_universal_baseline_country = FALSE,
      .groups = 'drop'
    )
  floor_country_codes <- pp$FLOOR_COUNTRIES
  floor_rate <- pp$FLOOR_RATE
  swiss_fw <- pp$SWISS_FRAMEWORK
  rev_date <- as.Date(effective_date)
  swiss_override_active <- FALSE
  if (!is.null(swiss_fw)) {
    swiss_override_active <- rev_date >= swiss_fw$effective_date &&
      (swiss_fw$finalized || rev_date <= swiss_fw$expiry_date)
  }
  if (length(floor_country_codes) > 0 && !is.null(floor_rate)) {
    eligible_floor_codes <- if (swiss_override_active) floor_country_codes else
      setdiff(floor_country_codes, swiss_fw$countries)
    override_mask <- country_ieepa$census_code %in% eligible_floor_codes &
                     country_ieepa$ieepa_type == 'surcharge' &
                     country_ieepa$ieepa_country_rate >= floor_rate
    if (any(override_mask)) {
      country_ieepa$ieepa_country_rate[override_mask] <- floor_rate
      country_ieepa$ieepa_type[override_mask] <- 'floor'
    }
  }
  country_ieepa
}

# Reconstruct the calc-side country_ieepa from the adapter's de-blobbed layers
# (mirrors 06_calculate_rates.R step 2 under Plank 4b/S1).
reconstruct_from_spec <- function(recip) {
  if (is.null(recip)) return(NULL)
  codes <- names(recip$by_country)
  tibble(
    census_code = codes,
    ieepa_country_rate = unname(recip$by_country[codes]),
    country_eo_rate = unname(recip$by_country_eo_rate[codes]),
    country_eo_ch99 = unname(recip$by_country_eo_ch99[codes]),
    ieepa_type = unname(recip$by_country_type[codes]),
    is_universal_baseline_country = FALSE
  )
}

same_table <- function(a, b) {
  a <- a %>% arrange(census_code); b <- b %>% arrange(census_code)
  identical(as.character(a$census_code), as.character(b$census_code)) &&
    isTRUE(all.equal(a$ieepa_country_rate, b$ieepa_country_rate)) &&
    isTRUE(all.equal(a$country_eo_rate, b$country_eo_rate)) &&
    identical(a$country_eo_ch99, b$country_eo_ch99) &&
    identical(a$ieepa_type, b$ieepa_type) &&
    identical(a$is_universal_baseline_country, b$is_universal_baseline_country)
}

# --- realistic fixture: covers every collapse + override branch -------------------
mkrow <- function(ch99, rate, rt, phase, cc) data.frame(
  ch99_code = ch99, rate = rate, rate_type = rt, phase = phase,
  terminated = FALSE, country_name = NA_character_, census_code = cc,
  stringsAsFactors = FALSE)
ieepa <- do.call(rbind, list(
  mkrow('9903.02.09', 0.10, 'surcharge',  'phase2_aug7', '3510'),  # Brazil  phase2
  mkrow('9903.01.77', 0.40, 'surcharge',  'country_eo',  '3510'),  # Brazil  EO  -> 0.50
  mkrow('9903.02.26', 0.25, 'surcharge',  'phase2_aug7', '5330'),  # India   phase2
  mkrow('9903.01.84', 0.25, 'surcharge',  'country_eo',  '5330'),  # India   EO  -> 0.50
  mkrow('9903.02.40', 0.15, 'surcharge',  'phase2_aug7', '7600'),  # Tunisia phase2 a
  mkrow('9903.02.41', 0.25, 'surcharge',  'phase2_aug7', '7600'),  # Tunisia phase2 b -> max 0.25
  mkrow('9903.02.11', 0.20, 'surcharge',  'phase2_aug7', '4279'),  # France  (floor ctry) 0.20 -> 0.15 floor
  mkrow('9903.02.12', 0.10, 'surcharge',  'phase2_aug7', '4280'),  # Germany (floor ctry) 0.10 < floor -> stays
  mkrow('9903.02.09', 0.10, 'surcharge',  'phase2_aug7', '5700'),  # China  0.10
  mkrow('9903.02.84', 0.39, 'surcharge',  'phase2_aug7', '4419'),  # Switzerland (floor ctry, framework)
  mkrow('9903.01.43', 0.10, 'passthrough','phase1_apr9', '9999'),  # passthrough phase1
  mkrow('9903.01.50', 0.10, 'surcharge',  'phase1_apr9', '8888'),  # phase1-only
  mkrow('9903.01.51', 0.10, 'surcharge',  'phase1_apr9', '7777'),  # phase1 (rank 2)...
  mkrow('9903.02.30', 0.30, 'surcharge',  'phase2_aug7', '7777')   # ...+ phase2 (rank 1) supersedes -> 0.30
))
attr(ieepa, 'universal_baseline') <- 0.10

pp <- list(
  FLOOR_COUNTRIES = c('4279', '4280', '4419', '4411', '5880', '5800'),
  FLOOR_RATE = 0.15,
  SWISS_FRAMEWORK = list(effective_date = as.Date('2025-11-14'),
                         expiry_date = as.Date('2026-03-31'),
                         finalized = FALSE, countries = c('4419', '4411'))
)
cc <- list(CTY_CANADA = '1220', CTY_MEXICO = '2010')

cat('--- adapter helper reproduces the calc phase-collapse + floor override ---\n')

# (1) Swiss IN window (override applies to Switzerland)
d_in  <- as.Date('2026-01-15')
recip_in  <- .resolve_ieepa_reciprocal(ieepa, pp, cc, d_in)
orac_in   <- oracle_country_ieepa(ieepa, pp, d_in)
check(same_table(reconstruct_from_spec(recip_in), orac_in),
      'Swiss in-window: adapter == oracle country_ieepa (all branches)')

# (2) Swiss OUT of window (Switzerland NOT overridden)
d_out <- as.Date('2026-05-01')
recip_out <- .resolve_ieepa_reciprocal(ieepa, pp, cc, d_out)
orac_out  <- oracle_country_ieepa(ieepa, pp, d_out)
check(same_table(reconstruct_from_spec(recip_out), orac_out),
      'Swiss out-of-window: adapter == oracle country_ieepa')

cat('\n--- hand-checked per-country values (in-window) ---\n')
bc  <- recip_in$by_country; bt <- recip_in$by_country_type
beo <- recip_in$by_country_eo_rate; beoc <- recip_in$by_country_eo_ch99
check(isTRUE(all.equal(unname(bc['3510']), 0.50)) && bt['3510'] == 'surcharge',
      'Brazil = 0.50 surcharge (phase2 0.10 + EO 0.40)')
check(isTRUE(all.equal(unname(beo['3510']), 0.40)) && beoc['3510'] == '9903.01.77',
      'Brazil EO component = 0.40 @ 9903.01.77')
check(isTRUE(all.equal(unname(bc['5330']), 0.50)) && unname(beoc['5330']) == '9903.01.84',
      'India = 0.50, EO ch99 9903.01.84')
check(isTRUE(all.equal(unname(bc['7600']), 0.25)) && bt['7600'] == 'surcharge',
      'Tunisia = max(0.15, 0.25) = 0.25 (within-phase highest)')
check(isTRUE(all.equal(unname(bc['4279']), 0.15)) && bt['4279'] == 'floor',
      'France floor override: 0.20 surcharge -> 0.15 floor')
check(isTRUE(all.equal(unname(bc['4280']), 0.10)) && bt['4280'] == 'surcharge',
      'Germany below floor: 0.10 stays surcharge (NOT overridden)')
check(isTRUE(all.equal(unname(bc['4419']), 0.15)) && bt['4419'] == 'floor',
      'Switzerland in-window: 0.39 -> 0.15 floor')
check(isTRUE(all.equal(unname(bc['7777']), 0.30)) && bt['7777'] == 'surcharge',
      'phase2 supersedes phase1: 7777 = 0.30 (phase1 0.10 dropped)')
check(is.na(unname(beoc['7600'])) && isTRUE(all.equal(unname(beo['7600']), 0)),
      'no-EO country: eo_rate 0, eo_ch99 NA')

cat('\n--- Switzerland out-of-window is NOT overridden ---\n')
check(isTRUE(all.equal(unname(recip_out$by_country['4419']), 0.39)) &&
        recip_out$by_country_type['4419'] == 'surcharge',
      'Switzerland out-of-window: 0.39 surcharge (no floor override)')

cat('\n--- carve-out + baseline metadata ---\n')
check(identical(recip_in$exclude, c('1220', '2010')),
      'default_unlisted_exclude = c(CA, MX)')
check(isTRUE(all.equal(recip_in$universal_baseline, 0.10)),
      'universal_baseline passed through = 0.10')

cat('\n--- empty / NULL inputs ---\n')
check(is.null(.resolve_ieepa_reciprocal(NULL, pp, cc, d_in)),
      'NULL ieepa_rates -> NULL')
empty <- ieepa[0, ]; attr(empty, 'universal_baseline') <- 0.10
check(is.null(.resolve_ieepa_reciprocal(empty, pp, cc, d_in)),
      '0-row ieepa_rates -> NULL')
no_census <- mkrow('9903.02.09', 0.10, 'surcharge', 'phase2_aug7', NA_character_)
check(is.null(.resolve_ieepa_reciprocal(no_census, pp, cc, d_in)),
      'all-NA census_code -> NULL (matches old empty-active_ieepa zero path)')

cat('\n--- end-to-end: build_authority_specs emits structured layers, no blob ---\n')
specs <- build_authority_specs(
  products = data.frame(), ch99_data = data.frame(),
  ieepa_rates = ieepa, usmca = data.frame(),
  countries = c('3510', '5330', '5700'),
  revision_id = 'rev_test', effective_date = d_in,
  s232_rates = NULL, fentanyl_rates = NULL, policy_params = pp
)
rrate <- specs[['ieepa_reciprocal']]$programs[[1]]$rate
check(is.null(rrate$resolved), 'ieepa_reciprocal carries NO resolved blob (de-blobbed)')
check(isTRUE(all.equal(unname(rrate$by_country['3510']), 0.50)),
      'spec rate$by_country populated (Brazil 0.50)')
check(rrate$by_country_type['4279'] == 'floor',
      'spec rate$by_country_type carries floor override (France)')
check(isTRUE(all.equal(rrate$default_unlisted_rate, 0.10)),
      'spec rate$default_unlisted_rate = universal_baseline')
check(identical(rrate$default_unlisted_exclude, c('1220', '2010')),
      'spec rate$default_unlisted_exclude = c(CA, MX)')
check(isTRUE(validate_spec_set(specs)), 'full spec set validates (new fields pass validate_rate)')

cat('\n--- S2: fentanyl de-blob (general max-per-census + carve-out rates) ---\n')
# ORACLE = the exact pre-S2 calc extraction.
fent_fix <- data.frame(
  ch99_code = c('9903.01.20', '9903.01.24', '9903.01.10', '9903.01.01',
                '9903.01.13', '9903.01.05'),
  rate = c(0.10, 0.20, 0.35, 0.25, 0.10, 0.10),
  country_name = NA_character_,
  census_code = c('5700', '5700', '1220', '2010', '1220', '2010'),
  entry_type = c('general', 'general', 'general', 'general', 'carveout', 'carveout'),
  stringsAsFactors = FALSE)
orac_general <- fent_fix %>% filter(entry_type == 'general') %>%
  group_by(census_code) %>% summarise(fent_rate = max(rate), .groups = 'drop')
orac_carveout <- fent_fix %>% filter(entry_type == 'carveout') %>%
  select(ch99_code, census_code, carveout_rate = rate)

fres <- .resolve_ieepa_fentanyl(fent_fix)
exp_bc <- setNames(orac_general$fent_rate, as.character(orac_general$census_code))
check(identical(names(fres$by_country)[order(names(fres$by_country))],
                names(exp_bc)[order(names(exp_bc))]) &&
        isTRUE(all.equal(fres$by_country[names(exp_bc)], exp_bc[names(exp_bc)],
                         check.attributes = FALSE)),
      'fentanyl by_country == oracle general max-per-census (China .10/.20 -> .20)')
check(isTRUE(all.equal(unname(fres$by_country['5700']), 0.20)) &&
        isTRUE(all.equal(unname(fres$by_country['1220']), 0.35)) &&
        isTRUE(all.equal(unname(fres$by_country['2010']), 0.25)),
      'fentanyl by_country hand-check: CN 0.20, CA 0.35, MX 0.25')
check(identical(fres$carveouts$ch99_code, orac_carveout$ch99_code) &&
        identical(fres$carveouts$census_code, as.character(orac_carveout$census_code)) &&
        isTRUE(all.equal(fres$carveouts$rate, orac_carveout$carveout_rate)),
      'fentanyl carveouts == oracle carveout_fent {ch99, census, rate}')
check(is.null(.resolve_ieepa_fentanyl(NULL)), 'NULL fentanyl_rates -> NULL')
fent_nocarve <- fent_fix[fent_fix$entry_type == 'general', ]
check(is.null(.resolve_ieepa_fentanyl(fent_nocarve)$carveouts),
      'no carve-out entries -> carveouts NULL')

cat('\n--- S2 end-to-end: ieepa_fentanyl emits structured layers, no blob ---\n')
specs_f <- build_authority_specs(
  products = data.frame(), ch99_data = data.frame(),
  ieepa_rates = ieepa, usmca = data.frame(),
  countries = c('5700', '1220', '2010'),
  revision_id = 'rev_test', effective_date = d_in,
  s232_rates = NULL, fentanyl_rates = fent_fix, policy_params = pp
)
frate <- specs_f[['ieepa_fentanyl']]$programs[[1]]$rate
check(is.null(frate$resolved), 'ieepa_fentanyl carries NO resolved blob (de-blobbed)')
check(isTRUE(all.equal(unname(frate$by_country['1220']), 0.35)),
      'fentanyl spec rate$by_country populated (Canada 0.35)')
check(identical(frate$carveouts$ch99_code, c('9903.01.13', '9903.01.05')),
      'fentanyl spec rate$carveouts carries both carve-out entries')
check(isTRUE(validate_spec_set(specs_f)), 'spec set with fentanyl carveouts validates')

cat('\nAll', pass, 'IEEPA reciprocal+fentanyl de-blob checks passed.\n')
