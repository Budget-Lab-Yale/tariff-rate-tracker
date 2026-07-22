# =============================================================================
# authority_adapter.R — JSON/param-object → AuthoritySpec re-packaging
# =============================================================================
#
# `build_authority_specs()` takes the bespoke per-authority Layer-B objects the
# parsers (03/04/05) already produce and re-packages them into a uniform
# `authority_spec_set` (see docs/authority_spec.md, src/model/authority_spec.R).
#
# CONTRACT — rate payloads are spec-native, parity-safe by construction:
#   * Authorities are progressively DE-BLOBBED into structured compositional rate
#     layers (the calc reads them via resolve_rate / dedicated readers): section_122
#     (Plank 3, rate$default), section_232 statutory layers + annex (Plank 4a/4c),
#     ieepa_reciprocal (Plank 4b/S1: by_country + by_country_type/_eo_* +
#     default_unlisted_rate/_exclude), ieepa_fentanyl (Plank 4b/S2: by_country +
#     carveouts). Only `section_232` still carries a RESIDUAL blob in its first
#     program's `rate$resolved` slot — the decision-8 gate inputs + derivative
#     blends — read back via s232_rates_from_specs().
#   * The calculator, handed a spec set, reads those structured layers and runs its
#     body — so flag-on output stays byte-identical to flag-off. The Phase-1
#     out-of-band `raw_*` attrs are gone.
#   * The other normalized fields are a scaffold the calculator reads selectively:
#     `country_scope` for 301/201 (Phase 2e); `active.until` for IEEPA invalidation
#     (Phase 2d); `heading_gates` precomputed for 232 (Phase 2c).
#   * `mfn` / `other` are constructed but inert (no resolved payload; their data
#     still flows through the calculator's internal footnote-seeding / extraction).
#
# Source order: this file depends on src/model/authority_spec.R (constructors,
# validation, `%||%`) being sourced first, and on get_country_constants() from
# src/pipeline/05_parse_policy_params.R for census-code scope population.
# =============================================================================

source(here::here('src', 'core', 'csv_cache.R'))

# ---- read the rate payload back out of the normalized programs (Phase 6b) ----
#
# The thin cut relocates each parser object VERBATIM from its out-of-band
# `raw_*` attr into the owning program's `rate$resolved` slot (a normal spec
# field the ops engine can mutate). Reconstruction is therefore the identity —
# the calc gets back the exact same R object — so the body stays byte-identical.
# (Full per-program normalization — e.g. splitting the 21-field s232 list across
# its 7 programs — is deferred to Phase 8; not needed for the ops capability.)
# 232's payload is authority-wide, parked on programs[[1]] until that split.
.spec_resolved_rate <- function(spec) {
  if (is.null(spec) || !length(spec$programs)) return(NULL)
  spec$programs[[1]]$rate$resolved
}
# Plank 4b/S3: ieepa_rates_from_specs / fentanyl_rates_from_specs removed — IEEPA
# reciprocal (S1) + fentanyl (S2) are de-blobbed, so there is no rate$resolved blob
# to read and no caller remains. Only section_232 still carries a residual blob.
s232_rates_from_specs     <- function(specs) .spec_resolved_rate(specs[['section_232']])
# (section_122 was de-blobbed in Plank 3 — its rate lives in the compositional
#  rate$default layer now, read by the calc via resolve_rate(), so it no longer
#  needs a resolved-blob accessor here.)

# ---- Section 301: resolve the additive rate tier into the spec (Plank 1) ----
#
# The Section 301 ADDITIVE rate (hts8 -> rate) was recomputed inside the
# calculator (06_calculate_rates.R ~2354-2399). Plank 1 moves that resolution
# here, into the spec's `by_product_tier`, so the calculator just READS it
# (resolve_rate's by_product_tier layer). Reproduces the calculator EXACTLY:
#   1. date-gate ch99 via filter_active_ch99 (calc line ~816 — the build passes
#      RAW ch99_data here, so we apply the same gate ourselves), then
#   2. drop suspended provisions, then
#   3. MAX(s301_rate) per hts8 across the active ADDITIVE codes (supersession:
#      Biden 9903.91.xx >= Trump 9903.88.xx, so MAX picks the superseding rate).
# The content-split flavor (rate_301_cs) is left in the calculator for now — it is
# DORMANT in baseline (section_301_content_split_codes empty), so parity is
# unaffected; relocating it cleanly wants a second program/column and is deferred.
# Returns a named numeric (names = hts8) or NULL when no active additive codes.
build_s301_additive_tier <- function(ch99_data, effective_date, pp) {
  rate_lookup <- pp$SECTION_301_RATES
  if (is.null(rate_lookup) || !nrow(rate_lookup)) return(NULL)
  s301_path <- here('resources', 's301_product_lists.csv')
  if (!file.exists(s301_path)) return(NULL)
  s301_products <- read_csv_cached(s301_path, col_types = readr::cols(
    hts8 = readr::col_character(), list = readr::col_character(),
    ch99_code = readr::col_character()))
  ch99_active <- filter_active_ch99(ch99_data, as.Date(effective_date))
  matched <- ch99_active[ch99_active$ch99_code %in% rate_lookup$ch99_pattern, , drop = FALSE]
  if (!nrow(matched)) return(NULL)
  descr <- matched$description %||% rep('', nrow(matched))
  active_codes <- unique(matched$ch99_code[!grepl('provision suspended', descr, ignore.case = TRUE)])
  cs_cfg    <- as.character(pp$section_301_content_split_codes %||% character(0))
  add_codes <- setdiff(active_codes, cs_cfg)
  if (!length(add_codes)) return(NULL)
  lk <- s301_products |>
    dplyr::filter(ch99_code %in% add_codes) |>
    dplyr::inner_join(rate_lookup, by = c('ch99_code' = 'ch99_pattern')) |>
    dplyr::group_by(hts8) |>
    dplyr::summarise(rate = max(s301_rate), .groups = 'drop')
  if (!nrow(lk)) return(NULL)
  stats::setNames(lk$rate, lk$hts8)
}

# ---- Section 232 blanket per-country overlay (Plank 4a / S2 blanket slice) ----
#
# Build the merged per-country rate overlay for a §232 METAL program (steel/aluminum)
# as a `by_country` layer, draining the residual blob's exempt lists + HTS country
# overrides + (config) S232_COUNTRY_EXEMPTIONS into one structured map. Reproduces the
# calculator's imperative country_232 build (06_calculate_rates.R: the exempt mutate +
# the two override loops + the config-exemption loop) in EXACT application order, baked
# per-revision so resolve_rate(product=NULL, country) returns the same scalar:
#   1. exempt -> 0   — call is_232_exempt() over the SAME `countries` the calc uses, so
#                      the ISO/EU census expansion is bit-identical by construction
#                      (no re-derivation; this is why there is no EU27/ISO source-mismatch).
#   2. HTS country overrides — already census-keyed, EU-expanded, max-collapsed by the
#                      parser (extract_country_specific_overrides); copied verbatim.
#   3. config S232_COUNTRY_EXEMPTIONS — date-gated (is.null(expiry) || rev_date < expiry,
#                      strict `<`); applies_to selects the metal; already census + EU27.
# Last write wins (override beats exempt-zero; config beats override) — matching the calc.
# Returns a named numeric (names = census codes) or NULL when the overlay is empty (then
# the program resolves to rate$default = base for every country, exactly as before S2).
.s232_blanket_by_country <- function(s232_rates, pp, countries, effective_date,
                                     exempt_field, override_field, metal) {
  bc <- c()
  exempt_hit <- vapply(countries, function(cty) is_232_exempt(cty, s232_rates[[exempt_field]]),
                       logical(1), USE.NAMES = FALSE)
  if (any(exempt_hit)) {
    bc <- stats::setNames(rep(0, sum(exempt_hit)), as.character(countries[exempt_hit]))
  }
  ov <- s232_rates[[override_field]]
  for (cty in names(ov)) bc[[as.character(cty)]] <- as.numeric(ov[[cty]])
  rev_date <- as.Date(effective_date)
  for (ex in pp$S232_COUNTRY_EXEMPTIONS) {
    if (!(is.null(ex$expiry_date) || rev_date < ex$expiry_date)) next
    if (metal %in% ex$applies_to) {
      for (cty in as.character(ex$countries)) bc[[cty]] <- as.numeric(ex$rate)
    }
  }
  if (!length(bc)) return(NULL)
  bc
}

# ---- Section 232 country deals (Plank 4a / S2 deals slice) -------------------
#
# Re-pack a deal tibble (country=ISO, rate, rate_type 'floor'|'surcharge', program,
# ch99_code) into the program's compositional rate layers, split by CONCEPT:
#   surcharge deals -> rate$overrides scope-form entry {scope, countries, rate}
#   floor deals     -> rate$floors        entry        {scope, countries, floor}
# ISO/EU country is CENSUS-EXPANDED here at build time (mirroring the calc's
# iso_to_census_vec: EU -> the 27 census codes; ISO -> ISO_TO_CENSUS), so the records
# are census-keyed. `scope` is the parser's deal$program verbatim (the calc expands it
# to the product set at run time). The floor/surcharge MATH stays in the calc (decision
# 8); resolve_rate is NOT asked to apply it. Returns list(overrides=, floors=).
.s232_deal_layers <- function(deal_tbl, cc) {
  if (is.null(deal_tbl) || !nrow(deal_tbl)) return(list(overrides = list(), floors = list()))
  iso2c <- function(iso) {
    if (identical(iso, 'EU')) return(as.character(cc$EU27_CODES))
    v <- cc$ISO_TO_CENSUS[iso]
    if (length(v) == 0 || is.na(v)) character(0) else as.character(v)
  }
  ov <- list(); fl <- list()
  for (i in seq_len(nrow(deal_tbl))) {
    d <- deal_tbl[i, ]
    rec_scope <- if ('program' %in% names(d)) as.character(d$program) else NA_character_
    ctys <- iso2c(d$country)
    if (identical(d$rate_type, 'floor')) {
      fl[[length(fl) + 1L]] <- list(scope = rec_scope, countries = ctys, floor = as.numeric(d$rate))
    } else {
      ov[[length(ov) + 1L]] <- list(scope = rec_scope, countries = ctys, rate = as.numeric(d$rate))
    }
  }
  list(overrides = ov, floors = fl)
}

# ---- IEEPA reciprocal per-country resolution (Plank 4b / S1) -----------------
#
# De-blob the reciprocal tibble into structured per-country rate layers. RELOCATES
# the calculator's phase-collapse (06: active_ieepa -> country_ieepa group_by/
# summarise) and surcharge->floor override (the FLOOR_COUNTRIES block, Swiss/LI
# date-bounded to the framework window) VERBATIM — both are pure functions of the
# parsed tibble + floor config + revision date, all available here, so doing them at
# build time and emitting resolved layers is bit-exact by construction. The calc then
# READS these layers to rebuild country_ieepa instead of collapsing the raw blob, and
# keeps the product-grid exempt masking + grid expansion + post-MFN floor recompute
# (which need base_rate / the product grid) as calc steps.
#
# Returns (keyed by census code, the collapsed post-override LISTED countries):
#   by_country          the merged per-country ieepa_country_rate (post floor-override)
#   by_country_type     ieepa_type (surcharge|floor|passthrough, post-override)
#   by_country_eo_rate  the country_eo phase contribution (0 where none)
#   by_country_eo_ch99  the active country-EO ch99 code (NA where none)
#   universal_baseline  the tibble's universal_baseline attribute (NULL if unset)
#   exclude             c(CTY_CANADA, CTY_MEXICO) — the reciprocal carve-out
# NULL when there is no usable entry (no valid census_code/rate), matching the calc's
# empty-active_ieepa zero path.
.resolve_ieepa_reciprocal <- function(ieepa_rates, pp, cc, effective_date) {
  if (is.null(ieepa_rates) || !nrow(ieepa_rates)) return(NULL)
  active_ieepa <- ieepa_rates |>
    dplyr::filter(!is.na(census_code), !is.na(rate))
  if (!nrow(active_ieepa)) return(NULL)

  # Phase 2 + country_eo stack ACROSS phases but NOT within a phase; within a phase
  # the country-specific entry supersedes group entries (prefer floor, then highest
  # rate). VERBATIM from 06_calculate_rates.R step 2.
  country_ieepa <- active_ieepa |>
    dplyr::mutate(
      active_rank = dplyr::if_else(phase %in% c('phase2_aug7', 'country_eo'), 1L, 2L),
      type_priority = dplyr::case_when(
        rate_type == 'floor' ~ 1L,
        rate_type == 'surcharge' ~ 2L,
        rate_type == 'passthrough' ~ 3L,
        TRUE ~ 4L
      )
    ) |>
    dplyr::group_by(census_code) |>
    dplyr::filter(active_rank == min(active_rank)) |>
    dplyr::ungroup() |>
    dplyr::group_by(census_code, phase) |>
    dplyr::arrange(type_priority, dplyr::desc(rate)) |>
    dplyr::summarise(
      phase_rate = dplyr::first(rate),
      phase_type = dplyr::first(rate_type),
      phase_ch99_code = dplyr::first(ch99_code),
      .groups = 'drop'
    ) |>
    dplyr::group_by(census_code) |>
    dplyr::summarise(
      ieepa_country_rate = sum(phase_rate),
      country_eo_rate = sum(phase_rate[phase == 'country_eo']),
      country_eo_ch99 = {
        ce <- phase_ch99_code[phase == 'country_eo']
        if (length(ce) > 0) ce[1] else NA_character_
      },
      ieepa_type = dplyr::first(phase_type),
      .groups = 'drop'
    )

  # surcharge -> floor override for FLOOR_COUNTRIES, only when the surcharge rate
  # exceeds the floor. Swiss/LI are date-bounded to the framework window. VERBATIM.
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
    eligible_floor_codes <- if (swiss_override_active) {
      floor_country_codes
    } else {
      setdiff(floor_country_codes, swiss_fw$countries)
    }
    override_mask <- country_ieepa$census_code %in% eligible_floor_codes &
                     country_ieepa$ieepa_type == 'surcharge' &
                     country_ieepa$ieepa_country_rate >= floor_rate
    if (any(override_mask)) {
      country_ieepa$ieepa_country_rate[override_mask] <- floor_rate
      country_ieepa$ieepa_type[override_mask] <- 'floor'
    }
  }

  codes <- as.character(country_ieepa$census_code)
  list(
    by_country         = stats::setNames(as.numeric(country_ieepa$ieepa_country_rate), codes),
    by_country_type    = stats::setNames(as.character(country_ieepa$ieepa_type), codes),
    by_country_eo_rate = stats::setNames(as.numeric(country_ieepa$country_eo_rate), codes),
    by_country_eo_ch99 = stats::setNames(as.character(country_ieepa$country_eo_ch99), codes),
    universal_baseline = attr(ieepa_rates, 'universal_baseline'),
    exclude            = c(cc$CTY_CANADA, cc$CTY_MEXICO)
  )
}

# ---- IEEPA fentanyl per-country resolution (Plank 4b / S2) --------------------
#
# De-blob the fentanyl tibble into structured rate layers. Relocates the calculator's
# general-rate collapse (max-per-census over the 'general' entries — China's 9903.01.20
# +10% / .24 +20% supersede to the max) into the adapter and emits:
#   by_country  the per-country general (blanket) fentanyl rate
#   carveouts   the per-ch99 x census carve-out rates {ch99_code, census_code, rate}
#               (the 'carveout' entries — CA energy/potash, MX potash). The carve-out
#               PRODUCT lists (hts8 prefixes, resources/fentanyl_carveout_products.csv)
#               stay reference data loaded calc-side (like the IEEPA exempt CSVs) and
#               are joined to these rates there. NULL when there are no carve-out entries.
# Returns NULL when fentanyl_rates is absent/empty.
.resolve_ieepa_fentanyl <- function(fentanyl_rates) {
  if (is.null(fentanyl_rates) || !nrow(fentanyl_rates)) return(NULL)
  general_fent <- fentanyl_rates |>
    dplyr::filter(entry_type == 'general') |>
    dplyr::group_by(census_code) |>
    dplyr::summarise(fent_rate = max(rate), .groups = 'drop')
  carveout_fent <- fentanyl_rates |>
    dplyr::filter(entry_type == 'carveout') |>
    dplyr::select(ch99_code, census_code, carveout_rate = rate)
  carveouts <- NULL
  if (nrow(carveout_fent) > 0) carveouts <- list(
    ch99_code   = as.character(carveout_fent$ch99_code),
    census_code = as.character(carveout_fent$census_code),
    rate        = as.numeric(carveout_fent$carveout_rate))
  list(
    by_country = stats::setNames(as.numeric(general_fent$fent_rate),
                                 as.character(general_fent$census_code)),
    carveouts  = carveouts
  )
}

# ---- product-exemption SETS -> spec (Pass-1.5) -------------------------------
#
# Relocate the hand-curated product-exemption SETS the calculator used to load
# inline from resource CSVs into the spec, so the spec is the single source of
# truth (rate -> spec was done in Planks 1-4b; the exempt SETS were the last
# calc-loaded policy input). Only the SETS move; the MASKING stays calc-side
# (it needs the product grid). Each helper reproduces the calc's old load +
# date-gate VERBATIM, so the relocation is bit-exact (oracle-tested). Baked onto
# the program as `$exempt_products` (a plain attached field, like §232's residual
# `rate$resolved` blob — invisible to validate_authority_spec, no schema change):
#   ieepa_reciprocal$programs[[1]]$exempt_products = {universal, country_eo, floor}
#   section_122$programs[[1]]$exempt_products       = {hts8}
# The fentanyl Ch98 subset rides along — the calc derives it as universal[ch==98].

# Universal IEEPA Annex II exempt list (hts10 vector), date-windowed by the
# effective_date_start/_end columns (blank = always active). VERBATIM from
# 06_calculate_rates.R (the old inline load).
.resolve_ieepa_exempt_products <- function(effective_date) {
  ieepa_exempt_path <- here('resources', 'ieepa_exempt_products.csv')
  if (!file.exists(ieepa_exempt_path)) {
    warning('ieepa_exempt_products.csv not found — all products subject to IEEPA')
    return(character(0))
  }
  ie_raw <- readr::read_csv(ieepa_exempt_path,
                            col_types = readr::cols(hts10 = readr::col_character(),
                                                    .default = readr::col_character()))
  rd_exempt <- as.Date(effective_date)
  if ('effective_date_start' %in% names(ie_raw)) {
    ie_raw <- ie_raw |>
      dplyr::filter(is.na(effective_date_start) |
                      as.Date(effective_date_start) <= rd_exempt)
  }
  if ('effective_date_end' %in% names(ie_raw)) {
    ie_raw <- ie_raw |>
      dplyr::filter(is.na(effective_date_end) |
                      as.Date(effective_date_end) >= rd_exempt)
  }
  ie_raw$hts10
}

# Country-EO exempt list -> distinct (ch99_code, hts8_prefix), date-windowed.
# VERBATIM (modulo qualification + base pipe) from 06_calculate_rates.R.
.resolve_country_eo_exempt <- function(effective_date) {
  country_eo_exempt_path <- here('resources', 'country_eo_exempt_products.csv')
  if (!file.exists(country_eo_exempt_path)) {
    return(tibble::tibble(ch99_code = character(), hts8_prefix = character()))
  }
  raw <- readr::read_csv(country_eo_exempt_path, comment = '#',
                         col_types = readr::cols(.default = readr::col_character()))
  rev_date_chr <- as.character(effective_date)
  raw |>
    dplyr::mutate(
      effective_date_start = dplyr::if_else(is.na(effective_date_start) | effective_date_start == '',
                                            '1900-01-01', effective_date_start),
      effective_date_end   = dplyr::if_else(is.na(effective_date_end)   | effective_date_end == '',
                                            '2099-12-31', effective_date_end)
    ) |>
    dplyr::filter(rev_date_chr >= effective_date_start, rev_date_chr <= effective_date_end) |>
    dplyr::mutate(hts8_prefix = substr(gsub('\\.', '', hts10), 1, 8)) |>
    dplyr::distinct(ch99_code, hts8_prefix)
}

# Section 122 note-2(aa) exempt list, split by condition (2026-07-08 fix,
# docs/s122_aircraft_exemption_audit.md): `hts8` = the UNCONDITIONAL
# (aa)(ii)/(iii) codes (full-line exempt, the historical semantics);
# `gn6_hts8` = the (aa)(iv) civil-aircraft codes, whose exemption is
# USE-conditional (GN6) and is applied as a per-line utilization scaling in
# apply_section122(). A CSV without the condition column (old layout) puts
# everything in `hts8` — legacy full-line behavior.
.resolve_s122_exempt <- function() {
  s122_exempt_path <- here('resources', 's122_exempt_products.csv')
  if (!file.exists(s122_exempt_path)) return(list(hts8 = character(0), gn6_hts8 = character(0)))
  ex <- read_csv_cached(s122_exempt_path,
                        col_types = readr::cols(hts8 = readr::col_character(),
                                                .default = readr::col_character()))
  if (!'condition' %in% names(ex)) {
    return(list(hts8 = ex$hts8, gn6_hts8 = character(0)))
  }
  list(hts8     = ex$hts8[ex$condition != 'gn6_civil_aircraft'],
       gn6_hts8 = ex$hts8[ex$condition == 'gn6_civil_aircraft'])
}

# Per-HTS10 GN6 civil-aircraft exempt share for the (aa)(iv) lines (2026-07-08
# fix). Measured by realized-rate classification (IMDB, ex-USMCA, no 232/301);
# built by scripts/build_s122_exempt_conditions.R from the audit measurement
# (docs/s122_aircraft_exemption_audit.md). Returns a named numeric vector
# (hts10 -> exempt_share); empty if the file is absent (calc then falls back to
# the HS2 mean, and ultimately to full exemption — see apply_section122()).
.resolve_s122_gn6_utilization <- function() {
  path <- here('resources', 's122_aircraft_utilization.csv')
  if (!file.exists(path)) return(setNames(numeric(0), character(0)))
  u <- read_csv_cached(path, col_types = readr::cols(hts10 = readr::col_character(),
                                                     exempt_share = readr::col_double(),
                                                     .default = readr::col_guess()))
  setNames(pmin(pmax(u$exempt_share, 0), 1), u$hts10)
}

# ---- section 301 forced labor (scenario authority) --------------------------
# USTR forced-labor §301 (FRN 91 FR 34272): per-country additional duty (two
# tiers, 10% / 12.5%) on ALL products of ~60 economies EXCEPT an Annex A
# exclusion list. Built ONLY when the (merged) config carries a
# `section_301_forced_labor` block — supplied by config/scenarios/forced_labor/
# overlay.yaml — so the authority is ABSENT in baseline. See [[forced-labor-301-scenario]].

# Two-tier per-country rate map (census code -> 0.10/0.125) from the config tier
# rosters. tier_10pct / tier_12_5pct are census-code lists; 10% wins on overlap.
.resolve_s301fl_by_country <- function(cfg, countries) {
  t10  <- as.character(unlist(cfg$tier_10pct   %||% character(0)))
  t125 <- as.character(unlist(cfg$tier_12_5pct %||% character(0)))
  r10  <- as.numeric(cfg$rate_10   %||% 0.10)
  r125 <- as.numeric(cfg$rate_12_5 %||% 0.125)
  m <- numeric(0)
  for (c in t125) m[c] <- r125
  for (c in t10)  m[c] <- r10   # 10% overrides if a code appears in both (disjoint in practice)
  m <- m[intersect(names(m), as.character(countries))]  # only economies the model knows
  m
}

# Annex A exclusion list (hts8 vector), date-windowed like the s122/IEEPA exempt
# loaders. Empty file / missing => no exclusions.
.resolve_s301fl_exempt <- function(cfg, effective_date) {
  path <- here(cfg$exempt_products %||% 'resources/s301fl_exempt_products.csv')
  if (!file.exists(path)) return(character(0))
  ex <- readr::read_csv(path, col_types = readr::cols(.default = readr::col_character()))
  if (!'hts8' %in% names(ex)) return(character(0))
  rd <- as.Date(effective_date)
  if ('effective_date_start' %in% names(ex)) {
    ex <- dplyr::filter(ex, is.na(effective_date_start) | as.Date(effective_date_start) <= rd)
  }
  if ('effective_date_end' %in% names(ex)) {
    ex <- dplyr::filter(ex, is.na(effective_date_end) | as.Date(effective_date_end) >= rd)
  }
  unique(as.character(ex$hts8))
}

# Build the section_301_forced_labor authority_spec, or NULL if the config block
# is absent (baseline). content_split + USMCA-eligible (stacks like ieepa_reciprocal /
# §122). DATE-GATED: by_country (and country scope) are populated only when the
# revision's effective_date >= the action's effective_date, so the authority is
# hollow before the turn-on AND in every synthetic mint stamped before it. Because
# the gate is by DATE (not a scenario op), every synthetic revision stamped on/after
# the turn-on (the bnd_<date> mint + any later empty-ops boundary mint) carries it.
.build_section_301_forced_labor <- function(pp, countries, effective_date) {
  cfg <- pp$section_301_forced_labor
  if (is.null(cfg)) return(NULL)
  eff <- if (!is.null(cfg$effective_date)) as.Date(cfg$effective_date) else as.Date(NA)
  active_now <- is.na(eff) || as.Date(effective_date) >= eff
  rate_layer <- list()
  if (active_now) {
    bc <- .resolve_s301fl_by_country(cfg, countries)
    if (length(bc) > 0) rate_layer$by_country <- bc
  }
  scope <- if (length(rate_layer$by_country)) names(rate_layer$by_country) else character(0)
  spec <- authority_spec(
    authority = 'section_301_forced_labor',
    stacking  = list(class = 'content_split', exceptions = list()),
    usmca_treatment = 'eligible',
    active = list(from = eff, until = NA),
    programs = list(authority_program(
      id = 's301fl',
      product_scope = list(include = 'all'),
      country_scope = list(include = scope),
      rate = rate_layer))
  )
  spec$programs[[1]]$exempt_products <- list(hts8 = .resolve_s301fl_exempt(cfg, effective_date))
  spec
}

# Build the section_301_brazil authority_spec, or NULL if the config block is
# absent (baseline). USTR FR Doc 2026-11158: a 25% additional duty on ALL goods of
# Brazil (census 3510) EXCEPT an Annex exclusion list (hts8). Built ONLY when the
# merged config carries a `section_301_brazil` block (config/scenarios/new_301/).
# content_split + usmca 'none' (Brazil isn't USMCA): stacks ADDITIVELY with the
# forced-labor §301 (both §301 actions apply — §301 is statutorily "in addition to";
# neither FR notice carves out the other). The content_split class implements the
# notice's hard §232 carve-out via nonmetal_share (see src/model/stacking.R): §232 goods
# — metals AND autos/MHD (nonmetal_share=0 fallback) — receive zero Brazil §301.
# DATE-GATED to >= effective_date exactly like the forced-labor builder, so it is
# hollow in baseline / pre-turn-on revisions and every synthetic pre-date mint.
.build_section_301_brazil <- function(pp, countries, effective_date) {
  cfg <- pp$section_301_brazil
  if (is.null(cfg)) return(NULL)
  eff <- if (!is.null(cfg$effective_date)) as.Date(cfg$effective_date) else as.Date(NA)
  active_now <- is.na(eff) || as.Date(effective_date) >= eff
  rate_layer <- list()
  if (active_now) {
    rate <- as.numeric(cfg$rate %||% 0.25)
    ctry <- as.character(cfg$country %||% '3510')          # Brazil census code
    bc <- stats::setNames(rep(rate, length(ctry)), ctry)
    bc <- bc[intersect(names(bc), as.character(countries))]  # only economies the model knows
    if (length(bc) > 0) rate_layer$by_country <- bc
  }
  scope <- if (length(rate_layer$by_country)) names(rate_layer$by_country) else character(0)
  spec <- authority_spec(
    authority = 'section_301_brazil',
    stacking  = list(class = 'content_split', exceptions = list()),
    usmca_treatment = 'none',
    active = list(from = eff, until = NA),
    programs = list(authority_program(
      id = 's301br',
      product_scope = list(include = 'all'),
      country_scope = list(include = scope),
      rate = rate_layer))
  )
  # exempt-list loader is generic (reads cfg$exempt_products); reused from the FL builder.
  spec$programs[[1]]$exempt_products <- list(hts8 = .resolve_s301fl_exempt(cfg, effective_date))
  spec
}

# ---- the adapter ------------------------------------------------------------

#' Re-package the bespoke per-authority parser outputs into an authority_spec_set.
#'
#' Signature mirrors calculate_rates_for_revision() so the build sites can call
#' it as a drop-in with the identical argument list.
#'
#' @param products,ch99_data,ieepa_rates,usmca parser outputs (Layer-B)
#' @param countries,revision_id,effective_date revision context
#' @param s232_rates,fentanyl_rates extracted rate objects (or NULL)
#' @param policy_params resolved policy params (or NULL → load_policy_params())
#' @return an `authority_spec_set` with raw objects embedded; validated.
build_authority_specs <- function(products, ch99_data, ieepa_rates, usmca,
                                  countries, revision_id, effective_date,
                                  s232_rates = NULL, fentanyl_rates = NULL,
                                  policy_params = NULL) {
  pp <- policy_params %||% load_policy_params()
  cc <- get_country_constants(pp)
  CTY_CHINA  <- cc$CTY_CHINA
  CTY_CANADA <- cc$CTY_CANADA
  CTY_MEXICO <- cc$CTY_MEXICO

  # IEEPA invalidation → ieepa programs' `active.until` (first inactive day,
  # exclusive — matches the calculator's `effective_date >= until` kill switch).
  # Mirror pp$IEEPA_INVALIDATION_DATE VERBATIM (incl. NULL when unset) so the
  # calc's `if (!is.null(until) && ...)` behaves identically — coercing NULL to
  # NA here would make the calc's `if (NA)` error (Phase 2d).
  ieepa_until <- pp$IEEPA_INVALIDATION_DATE

  # --- section_232 — the genuinely multi-program authority ------------------
  # Per-program rates are de-blobbed into each program's rate$default (Plank 4a);
  # the residual 21-field list (exempt lists, deals, overrides, derivatives, flags,
  # has_232) lives on programs[[1]]$rate$resolved until the later stages drain it.
  metal_prog <- function(id, type) authority_program(
    id = id, country_scope = list(include = 'all', exclude = list()),
    stacking = list(class = 'primary_metal'), metal = list(type = type, content = 'full'))
  full_prog <- function(id) authority_program(
    id = id, country_scope = list(include = 'all', exclude = list()),
    stacking = list(class = 'primary_full'), metal = list(type = 'none'))
  section_232 <- authority_spec(
    authority = 'section_232',
    stacking  = list(class = 'primary_metal', exceptions = list()),
    usmca_treatment = 'per_program',
    active = list(from = NA, until = NA),   # per-program heading gates (Phase 2c)
    programs = list(
      metal_prog('steel',    'steel'),
      metal_prog('aluminum', 'aluminum'),
      metal_prog('copper',   'copper'),
      full_prog('autos'),
      full_prog('mhd'),
      full_prog('wood'),
      full_prog('semiconductors'),
      # Plank 4a / S1b: pharmaceuticals is a register-then-activate dormant program
      # (pharma_rate = 0 in baseline → gate FALSE → byte-identical). It existed only
      # as a logical set_rate name (scenario_ops::S232_RATE_FIELD) over the blob;
      # giving it a real program makes the heading-name→program-id read uniform and
      # lets a scenario set_rate(section_232, 'pharmaceuticals', x) land on the spec.
      full_prog('pharmaceuticals')
    )
  )
  # Park the (still-blobbed) 21-field s232 list on programs[[1]]$rate$resolved.
  # Plank 4a de-blobs it stage by stage into structured layers; the residual blob
  # shrinks as each stage lands. Read via s232_rates_from_specs().
  section_232$programs[[1]]$rate$resolved <- s232_rates
  if (!is.null(s232_rates)) {
    # Plank 4a / S1a+S1b: de-blob every program's BASE rate into its compositional
    # rate$default (rate_type='surcharge' — additive). The calc reads these via
    # resolve_rate() — the blanket metals/autos in the country_232 build (S1a) and
    # the heading programs (copper/mhd/wood/semi/pharma) through compute_heading_gates
    # / resolve_heading_rate (S1b). Setting default to the scalar VERBATIM (incl. 0 —
    # a real, non-hollow value) keeps every read byte-identical to the old
    # `s232_rates$<field>` read. The non-rate fields (exempt lists, country overrides,
    # deals, derivatives, auto_has_deals/auto_has_parts, wood_furniture_rate, has_232)
    # stay on the resolved blob until S2/S3.
    .s232_set_default <- function(spec, prog_id, value) {
      pos <- which(vapply(spec$programs,
                          function(p) identical(p$id, prog_id), logical(1)))
      spec$programs[[pos]]$rate$default   <- value
      spec$programs[[pos]]$rate$rate_type <- 'surcharge'
      spec
    }
    section_232 <- .s232_set_default(section_232, 'steel',          s232_rates$steel_rate    %||% 0)
    section_232 <- .s232_set_default(section_232, 'aluminum',       s232_rates$aluminum_rate %||% 0)
    section_232 <- .s232_set_default(section_232, 'autos',          s232_rates$auto_rate     %||% 0)
    section_232 <- .s232_set_default(section_232, 'copper',         s232_rates$copper_rate   %||% 0)
    section_232 <- .s232_set_default(section_232, 'mhd',            s232_rates$mhd_rate      %||% 0)
    section_232 <- .s232_set_default(section_232, 'wood',           s232_rates$wood_rate     %||% 0)
    section_232 <- .s232_set_default(section_232, 'semiconductors', s232_rates$semi_rate     %||% 0)
    section_232 <- .s232_set_default(section_232, 'pharmaceuticals',s232_rates$pharma_rate   %||% 0)
    # Plank 4a / S2 (blanket slice): drain the steel/aluminum exempt lists + HTS country
    # overrides + config exemptions into each metal program's compositional rate$by_country
    # overlay (merged in calc application order, baked per-revision). The calc reads the
    # per-country metal rate via resolve_rate(product=NULL, country) (s232_blanket_metal_rate),
    # falling back to the imperative blob build for the specs-less callers. auto_exempt is
    # left on the blob (auto_rate never sets rate_232 — autos flow through the heading path).
    .s232_set_by_country <- function(spec, prog_id, bc) {
      if (is.null(bc)) return(spec)
      pos <- which(vapply(spec$programs, function(p) identical(p$id, prog_id), logical(1)))
      spec$programs[[pos]]$rate$by_country <- bc
      spec
    }
    section_232 <- .s232_set_by_country(section_232, 'steel',
      .s232_blanket_by_country(s232_rates, pp, countries, effective_date,
                               'steel_exempt', 'steel_country_overrides', 'steel'))
    section_232 <- .s232_set_by_country(section_232, 'aluminum',
      .s232_blanket_by_country(s232_rates, pp, countries, effective_date,
                               'aluminum_exempt', 'aluminum_country_overrides', 'aluminum'))
    # Plank 4a / S2 (deals slice): de-blob the auto + wood country-deal tibbles into the
    # autos / wood programs. Surcharge deals -> rate$overrides (scope-form), floor deals ->
    # rate$floors; ISO/EU census-expanded here (cc). The calc reads them via s232_deal_records()
    # (spec-first, blob-fallback) and keeps the floor/surcharge math (decision 8). auto_has_deals
    # / wood_furniture_rate / derivatives stay on the residual blob (has_232 gate; S3/decision-8).
    .s232_set_deals <- function(spec, prog_id, layers) {
      pos <- which(vapply(spec$programs, function(p) identical(p$id, prog_id), logical(1)))
      if (length(layers$overrides)) spec$programs[[pos]]$rate$overrides <- layers$overrides
      if (length(layers$floors))    spec$programs[[pos]]$rate$floors    <- layers$floors
      spec
    }
    section_232 <- .s232_set_deals(section_232, 'autos', .s232_deal_layers(s232_rates$auto_deal_rates, cc))
    section_232 <- .s232_set_deals(section_232, 'wood',  .s232_deal_layers(s232_rates$wood_deal_rates, cc))

    # ---- Plank 4c (Slice 2a): §232 ANNEX regime de-blob -> spec --------------
    # De-blob the annex per-product FACTS into the spec so the calculator READS
    # them (no in-calc classification, no config fallback). Classify the product
    # universe ONCE with the shared single-source helper (classify_s232_annex —
    # the exact logic the calc used), map tier->flat rate from annex_cfg, and park
    # a coherent `annex` structure on the AUTHORITY: the regime spans the metal
    # programs and the flat rate is metal-agnostic, so it is an authority-level
    # overlay, not one program's rate layer.
    #   $tier       hts10 -> annex_1a/1b/2/3   (the s232_annex tag column)
    #   $flat_rate  hts10 -> 0.50/0.25/0       (tiers 1a/1b/2; tier 3 is a base floor)
    #   $floor_rate annex_3 floor scalar       (calc applies pmax(0, floor - base))
    # Date-gated to the annex era; fail-closed on an empty prefix map (mirrors the
    # calc's old guard). UK/Russia deals + sunset stay calc-side (Slices 2b/2c).
    annex_cfg <- pp$S232_ANNEXES
    if (!is.null(annex_cfg) && !is.null(effective_date) &&
        as.Date(effective_date) >= as.Date(annex_cfg$effective_date)) {
      annex_res  <- annex_cfg$resource_file %||% file.path('resources', 's232_annex_products.csv')
      annex_path <- if (grepl('^(/|[A-Za-z]:)', annex_res)) annex_res else here(annex_res)
      annex_map  <- load_annex_products(effective_date, annex_path)
      if (nrow(annex_map) == 0) {
        stop('Section 232 annex mapping is empty for annex-era revision ', revision_id,
             ' (effective ', effective_date, '). Expected non-empty mapping at ', annex_path)
      }
      # No chapter-based annex_1a inference: the annex CSV enumerates the full
      # note-16(c) metal-chapter scope, so unmatched chapter-72/73/74/76 lines
      # (pig iron, ferroalloys, scrap, copper cathodes) are OUT of scope, not
      # annex_1a. See classify_s232_annex().
      deriv  <- load_232_derivative_products(effective_date = effective_date)
      hts    <- as.character(products$hts10)
      tier   <- classify_s232_annex(hts, annex_map, deriv)
      flat   <- c(annex_1a = as.numeric(annex_cfg$annexes$annex_1a$rate),
                  annex_1b = as.numeric(annex_cfg$annexes$annex_1b$rate),
                  annex_1c = as.numeric(annex_cfg$annexes$annex_1c$rate),
                  annex_2  = as.numeric(annex_cfg$annexes$annex_2$rate %||% 0))
      flat_rate <- unname(flat[tier])                       # NA for annex_3 / unclassified
      keept <- !is.na(tier)      & !duplicated(hts)
      keepf <- !is.na(flat_rate) & !duplicated(hts)

      # Slice 2b/2c: per-(country) per-product overrides the calc applies in order.
      # mode 'replace' = flat set (the UK annex deal); mode 'max' = pmax surcharge
      # (e.g. Russia aluminum 200%). The annex-tier + metal-type + chapter scoping is
      # baked into each rate_map here, so the calc just applies them (no config reads).
      .ovs <- list()
      # UK annex deal: tier 1a/1b on steel/aluminum (c)-list articles, NOT copper.
      # Note 16(d) scopes the reduced rates by SUBDIVISION membership — 9903.82.04
      # (+25%) covers (c)(i)-(iv), 9903.82.05 (+15%) covers (c)(vi)-(vii) — and
      # those lists span chapters well beyond 72/73/76 (8302/8412/8483/85xx/8708
      # derivative articles). The former chapter gate (substr %in% 72/73/76)
      # under-applied the 1b reduced rate on ~85% of UK annex trade (fixed
      # 2026-07-08; scope now = the annex CSV's metal_type via the same winning
      # prefix row as the tier, honoring config uk_applies_to; copper excluded
      # per 16(d)). Note 16(d) also conditions on >=95% of the metal being UK
      # melted-and-poured / smelted-and-cast; uk_content_qualifying_share =
      # fraction of UK imports assumed to meet that test; effective rate =
      # q*uk_rate + (1-q)*annex_rate. Default 1.0 == the unconditional reduced
      # rate; SGEPT's estimate is 0.30 (config/scenarios/sgept_exemptions).
      uk_code <- cc$CTY_UK %||% '4120'
      uk_q <- suppressWarnings(as.numeric(annex_cfg$uk_content_qualifying_share %||% 1.0))
      if (length(uk_q) != 1L || !is.finite(uk_q)) uk_q <- 1.0
      mtype <- classify_s232_metal_type(hts, annex_map, deriv)
      uk_types_1a <- as.character(unlist(annex_cfg$annexes$annex_1a$uk_applies_to %||% c('steel', 'aluminum')))
      uk_types_1b <- as.character(unlist(annex_cfg$annexes$annex_1b$uk_applies_to %||% c('steel', 'aluminum')))
      uk_rate <- ifelse(tier == 'annex_1a' & mtype %in% uk_types_1a, as.numeric(annex_cfg$annexes$annex_1a$uk_rate),
                 ifelse(tier == 'annex_1b' & mtype %in% uk_types_1b, as.numeric(annex_cfg$annexes$annex_1b$uk_rate),
                        NA_real_))
      uk_eff <- uk_q * uk_rate + (1 - uk_q) * flat_rate
      ukk <- !is.na(uk_eff) & !duplicated(hts)
      if (any(ukk)) .ovs[[length(.ovs) + 1L]] <- list(
        countries = uk_code, mode = 'replace',
        rate_map  = setNames(as.numeric(uk_eff[ukk]), hts[ukk]))
      # Country surcharges (general; e.g. Russia aluminum across annex 1a/1b/3). Build
      # the metal-type product set (primary chapters + type-tagged derivative prefixes)
      # exactly as the calc did, then scope to the surcharge's annexes via the tier map.
      deriv_by_type <- if (!is.null(deriv) && nrow(deriv) > 0) split(deriv$hts_prefix, deriv$derivative_type) else list()
      prim_by_type  <- list(steel = cc$STEEL_CHAPTERS, aluminum = cc$ALUM_CHAPTERS, copper = cc$COPPER_CHAPTERS)
      for (sc in (annex_cfg$country_surcharges %||% list())) {
        rate_s <- suppressWarnings(as.numeric(sc$rate))
        if (length(rate_s) != 1L || !is.finite(rate_s) || rate_s <= 0) next
        ann_in <- sc$applies_to  %||% c('annex_1a', 'annex_1b', 'annex_3')
        mtypes <- sc$metal_types %||% c('steel', 'aluminum', 'copper')
        thts <- character(0)
        for (mt in mtypes) {
          prim <- prim_by_type[[mt]] %||% character(0)
          if (length(prim)) thts <- c(thts, hts[substr(hts, 1, 2) %in% prim])
          dp <- deriv_by_type[[mt]] %||% character(0)
          if (length(dp)) thts <- c(thts, hts[grepl(paste0('^(', paste(dp, collapse = '|'), ')'), hts)])
        }
        thts <- unique(thts)
        thts <- thts[tier[match(thts, hts)] %in% ann_in]     # scope to the surcharge's annexes
        if (!length(thts)) next
        .ovs[[length(.ovs) + 1L]] <- list(
          countries = as.character(sc$countries), mode = 'max',
          rate_map  = setNames(rep(rate_s, length(thts)), thts))
        # Clause (8)-style content extension: the April 2026 proclamation applies
        # the Russia aluminum surcharge to articles of ANY country in which the
        # primary aluminum was smelted (or most recently cast) in Russia.
        # Origin-of-metal != exporter country is unobservable in Census trade
        # data, so model it as an expected-value share: surcharge *
        # third_country_content_share, pmax'd onto every NON-listed country on
        # the same product set. Dormant (0.0) by default — which is also the
        # realistic post-2023 value (supply chains avoid Russian metal; CBP
        # smelt-and-cast certs). See docs/assumptions.md.
        tc_share <- suppressWarnings(as.numeric(sc$third_country_content_share %||% 0))
        if (length(tc_share) == 1L && is.finite(tc_share) && tc_share > 0) {
          tc_countries <- setdiff(as.character(countries), as.character(sc$countries))
          if (length(tc_countries)) .ovs[[length(.ovs) + 1L]] <- list(
            countries = tc_countries, mode = 'max',
            rate_map  = setNames(rep(rate_s * tc_share, length(thts)), thts))
        }
      }

      section_232$annex <- list(
        tier              = setNames(tier[keept], hts[keept]),
        flat_rate         = setNames(as.numeric(flat_rate[keepf]), hts[keepf]),
        floor_rate        = as.numeric(annex_cfg$annexes$annex_3$floor_rate),
        country_overrides = .ovs)
    }

    # Phase 2c/6c: precompute the heading-program activation gates. Since S1b
    # compute_heading_gates reads the program rates off the spec (rate$default via
    # s232_spec_rate) + the non-rate flags off the resolved blob, so pass both. At
    # build time the defaults equal the blob scalars, so the baseline cache is
    # unchanged; a scenario set_rate mutates the default and drops this cache so it
    # recomputes from the spec.
    attr(section_232, 'heading_gates') <-
      compute_heading_gates(list(section_232 = section_232), s232_rates)
  }

  # --- ieepa_reciprocal — blanket, country-level ----------------------------
  # Plank 4b / S1: DE-BLOBBED. .resolve_ieepa_reciprocal() does the phase-collapse
  # + surcharge->floor override (relocated VERBATIM from the calculator) and emits
  # structured per-country rate layers; the calc READS them to rebuild country_ieepa
  # and keeps the product-grid masking / grid expansion / post-MFN floor recompute as
  # calc steps. No more rate$resolved blob for reciprocal.
  recip <- .resolve_ieepa_reciprocal(ieepa_rates, pp, cc, effective_date)
  recip_rate <- list()
  if (!is.null(recip)) {
    recip_rate$by_country         <- recip$by_country
    recip_rate$by_country_type    <- recip$by_country_type
    recip_rate$by_country_eo_rate <- recip$by_country_eo_rate
    recip_rate$by_country_eo_ch99 <- recip$by_country_eo_ch99
    if (!is.null(recip$universal_baseline))
      recip_rate$default_unlisted_rate <- recip$universal_baseline
    if (length(recip$exclude))
      recip_rate$default_unlisted_exclude <- as.character(recip$exclude)
  }
  ieepa_reciprocal <- authority_spec(
    authority = 'ieepa_reciprocal',
    stacking  = list(class = 'content_split', exceptions = list()),
    usmca_treatment = 'eligible',
    active = list(from = NA, until = ieepa_until),
    programs = list(authority_program(
      id = 'reciprocal',
      product_scope = list(include = 'all'),
      country_scope = list(include = 'all'),
      rate = recip_rate))
  )
  # Pass-1.5: bake the IEEPA product-exemption SETS onto the program so the spec
  # is the single source of truth. Done UNCONDITIONALLY (not gated on recip rates)
  # because the universal list is also consumed by the fentanyl Ch98 carve-out,
  # which runs on its own gate. The calc reads these via `$exempt_products` and
  # keeps the product-grid masking. floor = the per-revision file (or static
  # fallback) — same call the calc used, so it is bit-identical.
  ieepa_reciprocal$programs[[1]]$exempt_products <- list(
    universal  = .resolve_ieepa_exempt_products(effective_date),
    country_eo = .resolve_country_eo_exempt(effective_date),
    floor      = load_revision_floor_exemptions(revision_id, effective_date)
  )

  # --- ieepa_fentanyl — content_split except China (additive), as data ------
  # Plank 4b / S2: DE-BLOBBED. .resolve_ieepa_fentanyl() collapses the general rates
  # (max-per-census) into rate$by_country and emits the carve-out rates as rate$carveouts;
  # the calc READS them (joining carveouts to the hts8 product CSV calc-side). No blob.
  fentanyl_scope <- c(CTY_CHINA, CTY_CANADA, CTY_MEXICO)
  fentanyl_scope <- fentanyl_scope[!is.na(fentanyl_scope)]
  fent <- .resolve_ieepa_fentanyl(fentanyl_rates)
  fent_rate <- list()
  if (!is.null(fent)) {
    fent_rate$by_country <- fent$by_country
    if (!is.null(fent$carveouts)) fent_rate$carveouts <- fent$carveouts
  }
  ieepa_fentanyl <- authority_spec(
    authority = 'ieepa_fentanyl',
    stacking  = list(class = 'content_split',
                     exceptions = setNames(list('additive'), CTY_CHINA %||% 'china')),
    usmca_treatment = 'exempt',
    active = list(from = NA, until = ieepa_until),
    programs = list(authority_program(
      id = 'fentanyl',
      product_scope = list(include = 'all'),
      country_scope = list(include = fentanyl_scope),
      rate = fent_rate))
  )

  # --- section_301 — China gate as data (no raw embed; footnote-seeded) -----
  section_301 <- authority_spec(
    authority = 'section_301',
    stacking  = list(class = 'additive', exceptions = list()),
    usmca_treatment = 'none',
    active = list(from = NA, until = NA),
    programs = list(authority_program(
      id = 's301',
      product_scope = list(list_file = 'resources/s301_product_lists.csv'),
      country_scope = list(include = CTY_CHINA %||% '5700'),
      rate = list(by_product_tier = 'from_list')))
  )
  # Plank 1: resolve the additive 301 tier (hts8 -> rate) into by_product_tier so
  # the calculator reads it instead of recomputing. NULL (no active codes this
  # revision) leaves the hollow 'from_list' sentinel -> calc skips 301 as before.
  section_301$programs[[1]]$rate$by_product_tier <-
    build_s301_additive_tier(ch99_data, effective_date, pp) %||% 'from_list'

  # --- section_201 — solar, Canada-exempt -----------------------------------
  section_201 <- authority_spec(
    authority = 'section_201',
    stacking  = list(class = 'additive', exceptions = list()),
    usmca_treatment = 'none',
    active = list(from = NA, until = NA),
    programs = list(authority_program(
      id = 's201',
      product_scope = list(list_file = 'resources/s201_solar_products.csv'),
      country_scope = list(include = 'all',
                           exclude = (CTY_CANADA %||% character(0)))))
  )

  # --- section_122 — non-discriminatory blanket -----------------------------
  section_122 <- authority_spec(
    authority = 'section_122',
    stacking  = list(class = 'content_split', exceptions = list()),
    usmca_treatment = 'eligible',
    active = list(from = NA, until = NA),
    programs = list(authority_program(
      id = 's122', product_scope = list(include = 'all'),
      country_scope = list(include = 'all')))
  )
  # Plank 3: structure the Section 122 blanket rate into the compositional
  # rate$default layer (de-blobbed — no more rate$resolved). Extracted from the
  # SAME date-gated ch99 the calc uses (filter_active_ch99 at 06:766). The calc
  # READS it via resolve_rate() and gates on value > 0, so an absent program
  # (has_s122 = FALSE) leaves the rate hollow and the gate stays OFF — exactly
  # the old has_s122 ≡ rate>0 behavior. rate_type = 'surcharge': an additive duty.
  s122_extracted <- extract_section122_rates(
    filter_active_ch99(ch99_data, as.Date(effective_date)))
  if (isTRUE(s122_extracted$has_s122)) {
    section_122$programs[[1]]$rate$default   <- s122_extracted$s122_rate
    section_122$programs[[1]]$rate$rate_type <- 'surcharge'
  }
  # Pass-1.5: bake the §122 product-exemption SET onto the program (read by the
  # calc via `$exempt_products$hts8` inside the in-force block; masking calc-side).
  # 2026-07-08: the set is split by condition — unconditional (aa)(ii)/(iii)
  # in `hts8` (full-line exempt), USE-conditional (aa)(iv) civil-aircraft in
  # `gn6_hts8` (utilization-scaled). The per-line GN6 exempt shares ride
  # alongside so the calc needs no second file read.
  s122_ex <- .resolve_s122_exempt()
  section_122$programs[[1]]$exempt_products <- list(
    hts8            = s122_ex$hts8,
    gn6_hts8        = s122_ex$gn6_hts8,
    gn6_utilization = .resolve_s122_gn6_utilization())

  # --- mfn (base layer) + other (catch-all) — inert in Phase 1 --------------
  mfn <- authority_spec(
    authority = 'mfn',
    stacking  = list(class = 'additive', exceptions = list()),  # base layer; placeholder
    usmca_treatment = 'none',
    active = list(from = NA, until = NA),
    programs = list(authority_program(
      id = 'mfn', product_scope = list(include = 'all'),
      country_scope = list(include = 'all'),
      rate = list(default = 'from_products_base_rate')))
  )
  other <- authority_spec(
    authority = 'other',
    stacking  = list(class = 'additive', exceptions = list()),
    usmca_treatment = 'none',
    active = list(from = NA, until = NA),
    programs = list(authority_program(
      id = 'other', product_scope = list(include = 'all'),
      country_scope = list(include = 'all')))
  )

  # --- section_301_forced_labor — per-country forced-labor §301 (SCENARIO) ---
  # NULL in baseline (the config block ships only in config/scenarios/forced_labor/),
  # so the authority — and its rate_s301fl column — never materialize there.
  # Date-gated, content_split + USMCA-eligible. See .build_section_301_forced_labor.
  section_301_forced_labor <- .build_section_301_forced_labor(pp, countries, effective_date)

  # --- section_301_brazil — Brazil-only 25% §301 (SCENARIO) ------------------
  # NULL in baseline (the config block ships only in config/scenarios/new_301/),
  # so the authority — and its rate_s301br column — never materialize there.
  # Date-gated, content_split + usmca 'none'; stacks additively with the FL §301.
  # See .build_section_301_brazil.
  section_301_brazil <- .build_section_301_brazil(pp, countries, effective_date)

  spec_list <- list(section_232, section_301, ieepa_reciprocal, ieepa_fentanyl,
                    section_122, section_201, mfn, other)
  if (!is.null(section_301_forced_labor)) {
    spec_list <- c(spec_list, list(section_301_forced_labor))
  }
  if (!is.null(section_301_brazil)) {
    spec_list <- c(spec_list, list(section_301_brazil))
  }
  specs <- do.call(authority_spec_set, spec_list)

  # Record revision context as set-level metadata (not read in Phase 1; useful
  # for per-revision persistence in Phase 8 / debugging). Kept off the specs so
  # it never perturbs the embedded-object identity the parity gate relies on.
  attr(specs, 'revision_id')     <- revision_id
  attr(specs, 'effective_date')  <- effective_date

  validate_spec_set(specs)   # fail loud on any structural violation
  specs
}
