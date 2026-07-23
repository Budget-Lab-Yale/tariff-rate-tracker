# =============================================================================
# Step 06: Calculate Total Tariff Rates
# =============================================================================
#
# Calculates total effective tariff rate for each HTS10 x country combination
# using stacking rules from Tariff-ETRs.
#
# PUBLIC API:
#   calculate_rates_for_revision() — Entry point for per-revision rate calculation.
#     Called by 00_build_timeseries.R.
#
# INTERNAL:
#   calculate_rates_fast() — Footnote-based rate calculation (vectorized)
#   check_country_applies() — Country applicability check
#   apply_232_derivatives() — Section 232 derivative products + metal scaling
#
# Pipeline steps inside calculate_rates_for_revision():
#   1. Build the canonical product-country grid; seed footnote rates
#   1b. IEEPA invalidation check (SCOTUS ruling cutoff)
#   2. IEEPA reciprocal (blanket, country-level)
#   3. IEEPA fentanyl (blanket, CA/MX/CN)
#   4. Section 232 base (blanket, chapter/heading, with config country exemptions)
#   5. Section 232 derivatives (blanket, product list + metal scaling)
#   6. Section 301 (blanket, China product list)
#   6b. Section 122 (blanket, all countries, Annex II exempt)
#   6c. MFN exemption shares (FTA/GSP preference adjustment to base_rate)
#   6d. Floor recomputation (recompute IEEPA floor against post-MFN base_rate)
#   7. USMCA exemptions (CA/MX eligible products)
#   8. Stacking rules (mutual exclusion, nonmetal share)
#   9. Schema enforcement + metadata
#
# Output is returned to the build/publish layer, which writes through model_data.
#
# =============================================================================

library(tidyverse)

# NOTE: classify_authority(), build_rate_grid(), apply_stacking_rules(),
# enforce_rate_schema(), and RATE_SCHEMA are defined in helpers.R.
# No module-level globals — all constants are passed as function parameters
# from calculate_rates_for_revision() or loaded explicitly in standalone mode.


# =============================================================================
# Vectorized Rate Calculation (footnote-based)
# =============================================================================

#' Fast vectorized rate calculation (for large datasets)
#'
#' @param products Product data
#' @param ch99_data Chapter 99 data
#' @param countries Vector of country codes
#' @return Tibble with rates
calculate_rates_fast <- function(products, ch99_data, countries,
                                 iso_to_census = NULL, cty_china = '5700') {
  message('Calculating rates (fast mode)...')

  # Pre-process Chapter 99 data for faster lookup
  ch99_lookup <- ch99_data %>%
    filter(!is.na(rate)) %>%
    mutate(authority = map_chr(ch99_code, classify_authority)) %>%
    select(ch99_code, rate, authority, country_type, countries, exempt_countries)

  # Unnest product Chapter 99 refs
  product_refs <- products %>%
    filter(n_ch99_refs > 0) %>%
    select(hts10, ch99_refs) %>%
    unnest(ch99_refs) %>%
    rename(ch99_code = ch99_refs)

  message('  Product-Ch99 ref pairs: ', nrow(product_refs))

  # Join with Chapter 99 rates
  product_ch99_all <- product_refs %>%
    left_join(ch99_lookup, by = 'ch99_code')
  product_ch99_rates <- product_ch99_all %>% filter(!is.na(rate))

  message('  Product-Ch99 pairs with rates: ', nrow(product_ch99_rates))

  # Surface what the rate filter discards instead of dropping silently. Pairs
  # land here when a product references a ch99 heading that parsed without a
  # rate — mostly §301 exclusion headings (9903.88.xx, "the duty provided in
  # the applicable subheading"), which the engine does not model anywhere else:
  # those products are charged the full §301 rate even while an exclusion is
  # in force. A jump in this count after onboarding a revision means new
  # rate-less headings appeared and should be triaged.
  dropped_pairs <- product_ch99_all %>% filter(is.na(rate))
  if (nrow(dropped_pairs) > 0) {
    top_dropped <- dropped_pairs %>% count(ch99_code, sort = TRUE)
    message('  Product-Ch99 pairs DROPPED (ref has no parsed rate): ',
            nrow(dropped_pairs), ' pairs / ',
            n_distinct(dropped_pairs$hts10), ' products / ',
            nrow(top_dropped), ' ch99 codes; top: ',
            paste0(head(top_dropped$ch99_code, 5),
                   ' (', head(top_dropped$n, 5), ')', collapse = ', '))
  }

  # For each product-country, determine applicable rates.
  # Pre-compute a (ch99_code, country) applicability mapping from the ~100-300
  # ch99 entries, then inner_join against product refs. This replaces the prior
  # expand_grid + rowwise approach that created ~2M rows and called
  # check_country_applies() per row.

  # Build Census <-> ISO bidirectional lookup
  if (is.null(iso_to_census)) {
    iso_to_census <- get_country_constants()$ISO_TO_CENSUS
  }
  census_to_iso <- setNames(names(iso_to_census), iso_to_census)

  # Pre-compute applicable Census country codes per ch99 entry
  ch99_for_map <- ch99_lookup %>%
    select(ch99_code, country_type, countries, exempt_countries) %>%
    distinct(ch99_code, .keep_all = TRUE)

  country_vec <- countries
  applicable_pairs <- map_dfr(seq_len(nrow(ch99_for_map)), function(i) {
    row <- ch99_for_map[i, ]
    applicable <- switch(
      row$country_type,
      'all' = country_vec,
      'all_except' = {
        exempt_iso <- row$exempt_countries[[1]]
        exempt_census <- as.character(iso_to_census[exempt_iso])
        exempt_census <- exempt_census[!is.na(exempt_census)]
        # Exempt entries may also be raw Census codes
        setdiff(country_vec, unique(c(exempt_census, exempt_iso)))
      },
      'specific' = {
        specific_iso <- row$countries[[1]]
        specific_census <- as.character(iso_to_census[specific_iso])
        specific_census <- specific_census[!is.na(specific_census)]
        # Match country_vec against both Census-converted and raw codes
        intersect(country_vec, unique(c(specific_census, specific_iso)))
      },
      character(0)  # 'unknown' and others: fail-closed, no countries
    )
    if (length(applicable) > 0) {
      tibble(ch99_code = row$ch99_code, country = applicable)
    } else {
      tibble(ch99_code = character(), country = character())
    }
  })
  if (nrow(ch99_for_map) == 0) {
    # map_dfr(integer(0), ...) returns a zero-column tibble. Preserve the join
    # contract for counterfactuals that remove every referenced authority.
    applicable_pairs <- tibble(ch99_code = character(), country = character())
  }

  message('  Applicability pairs: ', nrow(applicable_pairs),
          ' (from ', nrow(ch99_for_map), ' ch99 entries x ', length(country_vec), ' countries)')

  # Join: product-ch99 refs × applicable countries (replaces expand_grid + rowwise)
  full_expansion <- product_ch99_rates %>%
    inner_join(applicable_pairs, by = 'ch99_code', relationship = 'many-to-many')

  message('  After country filtering: ', nrow(full_expansion))

  # Aggregate by product x country x authority (take max within authority)
  by_authority <- if (nrow(full_expansion) == 0) {
    tibble(hts10 = character(), country = character(),
           authority = character(), rate = numeric())
  } else {
    full_expansion %>%
      group_by(hts10, country, authority) %>%
      summarise(rate = max(rate), .groups = 'drop')
  }

  # Pivot to wide format
  rates_wide <- by_authority %>%
    pivot_wider(
      names_from = authority,
      values_from = rate,
      values_fill = 0,
      names_prefix = 'rate_'
    )

  # Ensure all columns exist
  for (col in c('rate_section_232', 'rate_section_301', 'rate_ieepa_reciprocal',
                'rate_ieepa_fentanyl', 'rate_section_122', 'rate_section_338',
                'rate_section_201', 'rate_other')) {
    if (!(col %in% names(rates_wide))) {
      rates_wide[[col]] <- 0
    }
  }

  # Rename columns for clarity
  rates_wide <- rates_wide %>%
    rename(
      rate_232 = rate_section_232,
      rate_301 = rate_section_301,
      rate_ieepa_recip = rate_ieepa_reciprocal,
      rate_ieepa_fent = rate_ieepa_fentanyl,
      rate_s122 = rate_section_122,
      rate_s338 = rate_section_338
    )

  # rate_301_cs (content-split 301 flavor) and rate_s301br (Brazil §301) have no
  # producer in this generic Ch99→rates pivot: 9903.05.0x is a country-wide charge
  # heading that no product line footnote-references, so it never attaches here.
  # rate_s301br is applied downstream by apply_section301_brazil() from the
  # section_301_brazil spec, whose rate is read off HTS 9903.05.01 (rev_12+).
  rates_wide$rate_301_cs <- 0
  rates_wide$rate_s301br <- 0

  # Create the complete product x country table exactly once. All policy
  # programs below mutate this table; none is allowed to add rows.
  rates_wide <- build_rate_grid(
    products,
    countries,
    rates_wide %>% select(hts10, country, all_of(AUTHORITY_RATE_COLUMNS))
  )
  message('  Canonical product-country grid: ', nrow(rates_wide))

  # Apply stacking rules (vectorized, from helpers.R)
  rates_final <- apply_stacking_rules(rates_wide, cty_china)

  return(rates_final)
}


#' Compute Section 232 heading-program activation gates for a revision.
#'
#' Each heading program (autos, copper, wood, MHD, semiconductors) is active only
#' when its Ch99 entries exist in this revision. Centralized so the calculator and
#' the AuthoritySpec adapter compute the gates from one source — no drift. Keyed
#' by the `section_232_headings` config names (NOT spec program ids).
#'
#' @param specs the authority_spec_set (REQUIRED). S1b: the per-program RATE inputs
#'   come from the spec (rate$default via resolve_rate / s232_spec_rate) so a scenario
#'   set_rate lands.
#' @param s232_rates adapter input from extract_section232_rates(); used here only
#'   while the adapter resolves revision-specific activation.
#' @return named logical list, one entry per known heading program
compute_heading_gates <- function(specs, s232_rates) {
  # Program rates are structured; parser flags supply activation facts.
  pr <- function(id) s232_spec_rate(specs, id)
  auto   <- pr('autos_source')
  copper <- pr('copper_source')
  wood   <- pr('wood_source')
  mhd    <- pr('mhd_source')
  semi   <- pr('semiconductors_source')
  pharma <- pr('pharmaceuticals_source')
  wood_furn <- s232_rates$wood_furniture_rate
  list(
    autos_passenger    = auto > 0 || s232_rates$auto_has_deals,
    autos_light_trucks = auto > 0 || s232_rates$auto_has_deals,
    auto_parts         = isTRUE(s232_rates$auto_has_parts),
    copper             = copper > 0,
    softwood           = wood > 0 || wood_furn > 0,
    wood_furniture     = wood > 0 || wood_furn > 0,
    kitchen_cabinets   = wood > 0 || wood_furn > 0,
    mhd_vehicles       = mhd > 0,
    mhd_parts          = mhd > 0,
    buses              = mhd > 0,
    semiconductors     = semi > 0,
    # Pharma is a register-then-activate dormant sub-program: pharma_rate is 0 in
    # baseline (gate FALSE => heading skipped => byte-identical). isTRUE() guards
    # the case where an older cached payload predates the pharma_rate field.
    pharmaceuticals    = isTRUE(pharma > 0)
  )
}


#' Read a revision-resolved Section 232 heading rate from AuthoritySpec.
resolve_heading_rate <- function(tariff_name, cfg) {
  rate <- cfg$rate
  if (is.null(rate) || !is.numeric(rate) || length(rate) != 1L ||
      !is.finite(rate) || rate < 0)
    stop('Section 232 heading ', tariff_name, ' has no valid resolved rate')
  rate
}

#' Materialize calculator-facing heading configs from common §232 programs.
s232_heading_configs <- function(specs) {
  programs <- specs[['section_232']]$programs
  programs <- Filter(function(p) isTRUE(p$settings$is_heading), programs)
  out <- lapply(programs, function(p) {
    cfg <- c(p$product_scope, p$settings)
    cfg$is_heading <- NULL
    cfg$rate <- resolve_rate(p$rate)$value
    cfg$enabled <- isTRUE(p$active$enabled)
    cfg
  })
  names(out) <- vapply(programs, function(p) p$id, character(1))
  out
}


#' Read a Section 232 source program's base rate.
#'
#' resolve_rate(programs[[id]]$rate)$value returns the program's compositional
#' rate$default is set by the adapter from the parser scalar, including zero.
s232_spec_rate <- function(specs, program_id) {
  progs <- specs[['section_232']]$programs
  pos <- which(vapply(progs, function(p) identical(p$id, program_id), logical(1)))
  if (length(pos) != 1L)
    stop("Section 232 program '", program_id, "' not found exactly once")
  v <- resolve_rate(progs[[pos]]$rate)$value
  if (is.na(v)) stop("Section 232 program '", program_id, "' has no resolved rate")
  v
}


#' Read a §232 METAL program's per-country blanket rate (Plank 4a / S2 blanket slice).
#'
#' resolve_rate(product=NULL, country) reads the merged by_country overlay (exempt-0 +
#' HTS overrides + config exemptions, baked by the adapter in application order) over
#' rate$default (the base), returning the same scalar the old imperative country_232
#' build produced. A country with no overlay resolves NA -> the program `base`.
#' Vectorized over `countries`; returns a numeric vector in that order. (Plank 7: the
#' specs-less imperative blob build is gone — `specs` is required.)
s232_blanket_metal_rate <- function(specs, countries, program_id) {
  progs <- specs[['section_232']]$programs
  pos <- which(vapply(progs, function(p) identical(p$id, program_id), logical(1)))
  if (length(pos) != 1L) {
    stop(sprintf("s232_blanket_metal_rate: program '%s' not found in spec", program_id))
  }
  prog_rate <- progs[[pos]]$rate
  vapply(countries, function(cty) {
    v <- resolve_rate(prog_rate, product = NULL, country = cty)$value
    if (is.na(v)) stop("Section 232 program '", program_id,
                       "' has no rate for country ", cty)
    v
  }, numeric(1), USE.NAMES = FALSE)
}


#' Read a §232 program's country DEAL records (Plank 4a / S2 deals slice), spec-first.
#'
#' Reconstructs an ordered record list {scope, countries(census), rate, rate_type} from the
#' program's rate$overrides (scope-form -> 'surcharge') + rate$floors ('floor'). The product
#' axis is a scope LABEL the calc expands at run time; the floor/surcharge MATH stays in the
#' calc (decision 8). Countries are pre-census-expanded by the adapter. No (product x country)
#' cell is hit by two deals, so the overrides-then-floors order is bit-exact regardless of
#' order. (Plank 7: the specs-less blob re-pack is gone — `specs` is required.)
s232_deal_records <- function(specs, program_id) {
  progs <- specs[['section_232']]$programs
  pos <- which(vapply(progs, function(p) identical(p$id, program_id), logical(1)))
  if (length(pos) != 1L) return(list())
  rt <- progs[[pos]]$rate; recs <- list()
  ov <- rt$overrides
  if (!is.null(ov) && is.list(ov)) for (o in ov) if (is.list(o) && !is.null(o$scope))
    recs[[length(recs) + 1L]] <- list(scope = as.character(o$scope),
      countries = as.character(unlist(o$countries)), rate = o$rate, rate_type = 'surcharge')
  fl <- rt$floors
  if (!is.null(fl) && is.list(fl)) for (f in fl) if (is.list(f))
    recs[[length(recs) + 1L]] <- list(scope = as.character(f$scope),
      countries = as.character(unlist(f$countries)), rate = f$floor, rate_type = 'floor')
  recs
}

resolve_policy_country_values <- function(config, countries, pp, default = NULL) {
  if (is.null(config) || length(config) == 0) {
    return(stats::setNames(rep(default %||% 0, length(countries)), countries))
  }
  expand_key <- function(k) {
    if (k == 'default') return('default')
    if (k == 'eu') return(pp$EU27_CODES %||% names(pp$eu27_codes) %||% character(0))
    if (k %in% names(pp$country_codes)) return(as.character(pp$country_codes[[k]]))
    if (k %in% names(pp)) {
      v <- pp[[k]]
      if (is.character(v) && length(v) == 1L) return(v)
    }
    as.character(k)
  }

  out <- stats::setNames(rep(default %||% 0, length(countries)), countries)
  vals <- config
  dflt <- vals[['default']]
  vals[['default']] <- NULL
  if (!is.null(dflt)) out[] <- as.numeric(dflt)
  for (k in names(vals)) {
    codes <- intersect(expand_key(k), countries)
    if (length(codes) > 0) out[codes] <- as.numeric(vals[[k]])
  }
  out
}

apply_pharma_232_adjustments <- function(rates, pharma_products, cfg, countries, pp) {
  if (!length(pharma_products) || is.null(cfg)) return(rates)

  country_rate <- resolve_policy_country_values(cfg$country_rates, countries, pp, default = cfg$rate)
  target_total <- resolve_policy_country_values(cfg$target_total, countries, pp, default = NA_real_)
  generic      <- resolve_policy_country_values(cfg$generic_share, countries, pp, default = 0)
  exempt       <- resolve_policy_country_values(cfg$exempt_share, countries, pp, default = 0)

  adj <- tibble(
    country = names(country_rate),
    pharma_country_rate = as.numeric(country_rate),
    pharma_target_total = as.numeric(target_total),
    pharma_generic_share = pmin(pmax(as.numeric(generic), 0), 1),
    pharma_exempt_share = pmin(pmax(as.numeric(exempt), 0), 1)
  )

  rates %>%
    left_join(adj, by = 'country', relationship = 'many-to-one') %>%
    mutate(
      .pharma_hit = hts10 %in% pharma_products & rate_232 > 0,
      .pharma_base = coalesce(pharma_country_rate, 0),
      .pharma_floor = if_else(
        !is.na(pharma_target_total),
        pmax(pharma_target_total - base_rate, 0),
        0
      ),
      rate_232 = if_else(
        .pharma_hit,
        pmax(.pharma_base, .pharma_floor) *
          (1 - coalesce(pharma_generic_share, 0)) *
          (1 - coalesce(pharma_exempt_share, 0)),
        rate_232
      )
    ) %>%
    select(-pharma_country_rate, -pharma_target_total,
           -pharma_generic_share, -pharma_exempt_share,
           -.pharma_hit, -.pharma_base, -.pharma_floor)
}


#' Check if country applies to a Chapter 99 entry
#'
#' @param country Census country code
#' @param country_type Type from Ch99 data
#' @param countries List of applicable countries
#' @param exempt List of exempt countries
#' @return Logical
check_country_applies <- function(country, country_type, countries, exempt,
                                  iso_to_census = NULL) {
  # Defensive checks
  if (length(country) == 0 || is.na(country)) return(FALSE)
  if (length(country_type) == 0 || is.na(country_type)) return(FALSE)

  # Convert Census to ISO for matching
  if (is.null(iso_to_census)) {
    iso_to_census <- get_country_constants()$ISO_TO_CENSUS
  }
  country_iso <- names(iso_to_census)[match(country, iso_to_census)]
  if (length(country_iso) == 0 || is.na(country_iso)) country_iso <- country

  switch(
    country_type,
    'all' = TRUE,
    'all_except' = !(country_iso %in% exempt),
    'specific' = country_iso %in% countries || country %in% countries,
    'unknown' = FALSE,  # Fail-closed: parser miss should not promote to global
    FALSE
  )
}


# =============================================================================
# Section 232 Heading Product Matching
# =============================================================================

#' Match HTS10 products covered by a Section 232 heading config.
#'
#' Each heading has one authoritative product source. `products_file` is used
#' exclusively when configured; otherwise `prefixes_file` and inline `prefixes`
#' form the declared source. Missing configured files are fatal.
#'
#' Previously duplicated verbatim in two separate loops inside
#' `calculate_rates_for_revision()` (step 4 for rate assignment, step 5 for
#' derivative-overlap exclusion). Extracted so the two callers stay in lockstep.
#'
#' @param cfg Named list — a single entry from section_232_headings.
#' @param products Tibble with an `hts10` character column.
#' @param tariff_name Heading name, used only in log/warning text.
#' @param verbose Step 4 calls with verbose = TRUE; step 5 re-reads the same
#'   configs with verbose = FALSE to avoid emitting the same log line twice.
#' @return Character vector of matched HTS10 codes (possibly empty).
match_232_heading_products <- function(cfg, products,
                                        tariff_name = NA_character_,
                                        verbose = TRUE) {
  matched <- character(0)

  if (!is.null(cfg$products_file)) {
    pf_path <- here(cfg$products_file)
    if (!file.exists(pf_path))
      stop('232 heading "', tariff_name, '": products_file not found: ', pf_path)
    pf_data <- read_csv(pf_path,
                        col_types = cols(.default = col_character()),
                        show_col_types = FALSE)
    if (!'hts10' %in% names(pf_data) || !nrow(pf_data))
      stop('232 heading "', tariff_name,
           '": products_file must contain a non-empty hts10 column: ', pf_path)
    pf_codes <- pf_data$hts10
    pf_pattern <- paste0('^(', paste(pf_codes, collapse = '|'), ')')
    matched <- products$hts10[grepl(pf_pattern, products$hts10)]
    if (verbose) {
      message('  232 heading "', tariff_name, '": ', length(matched),
              ' products from ', basename(pf_path),
              ' (', length(pf_codes), ' codes)')
    }
    return(matched)
  }

  prefixes <- unlist(cfg$prefixes %||% character(0))
  if (!is.null(cfg$prefixes_file)) {
    pf_path <- here(cfg$prefixes_file)
    if (!file.exists(pf_path))
      stop('232 heading "', tariff_name, '": prefixes_file not found: ', pf_path)
    prefixes <- c(prefixes, trimws(readLines(pf_path, warn = FALSE)))
  }
  prefixes <- unique(prefixes[nchar(prefixes) > 0])
  if (!length(prefixes))
    stop('232 heading "', tariff_name, '": no product scope configured')
  pattern <- paste0('^(', paste(prefixes, collapse = '|'), ')')
  matched <- products$hts10[grepl(pattern, products$hts10)]
  if (verbose) {
    message('  232 heading "', tariff_name, '": ', length(matched),
            ' products from ', length(prefixes), ' declared prefix(es)')
  }

  matched
}


# =============================================================================
# Section 232 Derivative Products
# =============================================================================

#' Apply Section 232 derivative tariff and metal content scaling
#'
#' Derivative products include both aluminum-containing articles outside
#' chapter 76 (9903.85.04/.07/.08) and steel-containing articles outside
#' chapters 72-73 (9903.81.89-93, added via Section 232 Inclusions Process,
#' FR 2025-15819). The tariff applies only to the metal content portion
#' of customs value. This function:
#'   1. Loads the product list from resources/s232_derivative_products.csv
#'   2. Matches products by prefix, split by derivative_type (steel/aluminum)
#'   3. Applies derivative 232 rates per type on the canonical grid
#'   4. Joins metal content shares and scales rate_232 by per-type share
#'   5. Tags products with deriv_type for use in stacking rules
#'
#' @param rates Current rates tibble
#' @param products Product data from parse_products()
#' @param specs AuthoritySpec set containing the two derivative programs
#' @param countries Vector of Census country codes
#' @param deriv_products Optional pre-loaded output of
#'   `load_232_derivative_products(effective_date)`. If NULL the function loads
#'   it internally — but the typical caller (calculate_rates_for_revision)
#'   passes a pre-loaded value so the same CSV isn't read twice per build
#'   (step 5 and step 5c both need the derivative prefix list).
#' @return List with 'rates' (updated tibble) and 'deriv_matched' (character vector)
apply_232_derivatives <- function(rates, products, specs, countries,
                                  heading_products = character(0),
                                  policy_params = NULL,
                                  effective_date = NULL,
                                  deriv_products = NULL) {
  if (is.null(deriv_products)) {
    deriv_products <- load_232_derivative_products(effective_date = effective_date)
  }
  deriv_matched <- character(0)

  # Initialize deriv_type column (used by stacking rules to select per-type share)
  if (!'deriv_type' %in% names(rates)) {
    rates <- rates %>% mutate(deriv_type = NA_character_)
  }

  s232_programs <- specs[['section_232']]$programs
  names(s232_programs) <- vapply(s232_programs, function(p) p$id, character(1))
  steel_prog <- s232_programs[['steel_derivatives']]
  aluminum_prog <- s232_programs[['aluminum_derivatives']]
  has_steel_deriv <- isTRUE(steel_prog$active$enabled)
  has_alum_deriv <- isTRUE(aluminum_prog$active$enabled)

  if (!is.null(deriv_products) && nrow(deriv_products) > 0 &&
      (has_alum_deriv || has_steel_deriv)) {
    #
    # ANNEX-ERA BEHAVIOR (2026_rev_5+, effective 2026-04-06): the April 2026
    # proclamation removed these pre-annex derivative Ch99 codes from the HTS,
    # so both gates below are FALSE, this whole block is skipped, and every row
    # keeps deriv_type = NA with per-type shares = 0. That is the INTENDED
    # policy outcome, not a silent failure: the annex restructuring replaced
    # metal-content-scaled derivative duties with full-value annex rates,
    # which step 5c assigns via the annex override. In annex-era snapshots,
    # `s232_annex` (annex_1a/_1b/_2/_3) is the column that classifies metal
    # products — downstream readers should use it, not deriv_type, from rev_5
    # on. Do NOT backfill deriv_type with a sentinel here: stacking selects
    # per-type metal shares by gating on !is.na(deriv_type), and annex products
    # are taxed full-value (nonmetal_share = 0), so a non-NA deriv_type would
    # wrongly re-enable metal-content splitting. See
    # docs/s232/rev5_baseline_review.md §§4-5.
    {
      # Split product list by derivative type
      alum_products <- deriv_products %>% filter(derivative_type == 'aluminum')
      steel_products <- deriv_products %>% filter(derivative_type == 'steel')

      # --- Aluminum derivatives ---
      alum_matched <- character(0)
      if (has_alum_deriv && nrow(alum_products) > 0) {
        alum_prefixes <- alum_products$hts_prefix
        alum_pattern <- paste0('^(', paste(alum_prefixes, collapse = '|'), ')')
        alum_matched <- products %>%
          filter(grepl(alum_pattern, hts10)) %>% pull(hts10)

        if (length(alum_matched) > 0) {
          country_alum <- tibble(country = countries) %>%
            mutate(deriv_rate = map_dbl(country, ~{
              value <- resolve_rate(aluminum_prog$rate, country = .x)$value
              if (is.na(value)) 0 else value
            }))
          rates <- rates %>%
            left_join(country_alum %>% select(country, .alum_deriv_rate = deriv_rate), by = 'country', relationship = 'many-to-one') %>%
            mutate(
              .alum_deriv_rate = coalesce(.alum_deriv_rate, 0),
              rate_232 = if_else(hts10 %in% alum_matched & .alum_deriv_rate > 0,
                                 pmax(rate_232, .alum_deriv_rate), rate_232),
              deriv_type = if_else(hts10 %in% alum_matched & .alum_deriv_rate > 0,
                                   'aluminum', deriv_type)
            ) %>% select(-.alum_deriv_rate)
          message('  Aluminum derivative coverage: ', length(alum_matched), ' products')
        }
      }

      # --- Steel derivatives ---
      steel_matched <- character(0)
      if (has_steel_deriv && nrow(steel_products) > 0) {
        steel_prefixes <- steel_products$hts_prefix
        steel_pattern <- paste0('^(', paste(steel_prefixes, collapse = '|'), ')')
        steel_matched <- products %>%
          filter(grepl(steel_pattern, hts10)) %>% pull(hts10)

        if (length(steel_matched) > 0) {
          country_steel <- tibble(country = countries) %>%
            mutate(deriv_rate = map_dbl(country, ~{
              value <- resolve_rate(steel_prog$rate, country = .x)$value
              if (is.na(value)) 0 else value
            }))
          rates <- rates %>%
            left_join(country_steel %>% select(country, .steel_deriv_rate = deriv_rate), by = 'country', relationship = 'many-to-one') %>%
            mutate(
              .steel_deriv_rate = coalesce(.steel_deriv_rate, 0),
              rate_232 = if_else(hts10 %in% steel_matched & .steel_deriv_rate > 0,
                                 pmax(rate_232, .steel_deriv_rate), rate_232),
              # Products in both types: steel takes precedence for deriv_type
              # (stacking uses steel_share, which is correct since steel content
              # is what triggers the steel derivative classification)
              deriv_type = if_else(hts10 %in% steel_matched & .steel_deriv_rate > 0,
                                   'steel', deriv_type)
            ) %>% select(-.steel_deriv_rate)
          message('  Steel derivative coverage: ', length(steel_matched), ' products')
        }
      }

      deriv_matched <- union(alum_matched, steel_matched)
      message('  Section 232 derivative coverage (total): ', length(deriv_matched), ' products')
    }
  }

  # Update statutory_rate_232 for derivative products only (pre-metal-scaling).
  # Non-derivative products already have statutory_rate_232 set after step 4c.
  if (length(deriv_matched) > 0) {
    rates <- rates %>%
      mutate(
        statutory_rate_232 = if_else(
          hts10 %in% deriv_matched,
          pmax(coalesce(statutory_rate_232, 0), rate_232),
          statutory_rate_232
        )
      )
  }

  # Join metal content shares and scale derivative 232 rates.
  # For derivative products, rate_232 was set to the full rate above;
  # now scale by metal_share so that the rate reflects metal-content-only.
  if (is.null(policy_params)) {
    stop('apply_232_derivatives() requires policy_params — cannot use NULL fallback')
  }
  pp_local <- policy_params
  metal_cfg <- if (!is.null(pp_local)) pp_local$metal_content else NULL
  metal_shares <- load_metal_content(metal_cfg, unique(rates$hts10), deriv_matched)
  rates <- rates %>%
    select(-any_of('metal_share')) %>%
    left_join(metal_shares, by = 'hts10', relationship = 'many-to-one') %>%
    mutate(metal_share = coalesce(metal_share, 1.0))
  n_missing_share <- sum(is.na(metal_shares$metal_share[metal_shares$hts10 %in% deriv_matched]))
  if (n_missing_share > 0) {
    warning(n_missing_share, ' derivative products have no metal_share data — defaulting to 1.0 (no scaling)')
  }

  if (length(deriv_matched) > 0) {
    # Scale by per-type share: aluminum derivatives use aluminum_share,
    # steel derivatives use steel_share. The derivative tariff only applies to
    # the relevant metal content; the other metal fractions are covered by IEEPA
    # via nonmetal_share in stacking. This matches ETRs' per-type scaling.
    #
    # Skip scaling for derivatives that also have a heading rate (e.g., auto parts
    # that are also aluminum derivatives). The heading rate dominates and shouldn't
    # be metal-scaled — ETRs handles this via per-program pmax.
    metal_method <- if (!is.null(metal_cfg)) metal_cfg$method %||% 'flat' else 'flat'
    has_per_type <- identical(metal_method, 'bea') &&
      all(c('steel_share', 'aluminum_share') %in% names(rates))

    # Exclude primary chapter products (72/73/76) and heading products from
    # derivative metal scaling. Primary chapters get blanket 232 rates (full product);
    # heading products get heading rates (full product). Only true derivatives
    # (outside primary chapters, not heading-matched) should be metal-scaled.
    p_chapters <- if (!is.null(pp_local)) unlist(pp_local$metal_content$primary_chapters) else c('72', '73', '76')
    primary_hts10 <- rates %>% distinct(hts10) %>%
      filter(substr(hts10, 1, 2) %in% p_chapters) %>% pull(hts10)
    deriv_only <- setdiff(deriv_matched, c(heading_products, primary_hts10))

    if (has_per_type) {
      # Per-type scaling: aluminum derivatives by aluminum_share, steel by steel_share
      rates <- rates %>%
        mutate(
          # A type share of 0/NA on a tagged line is uninformative, not "zero
          # metal": BEA-unmatched derivatives get the flat aggregate fallback
          # with zero-filled type shares (load_metal_content), so scaling by
          # the type share would zero the duty entirely (e.g. 8483.90.50.20).
          # Fall back to the aggregate share instead.
          .scale_share = case_when(
            hts10 %in% deriv_only & deriv_type == 'steel'    & steel_share    > 0 ~ steel_share,
            hts10 %in% deriv_only & deriv_type == 'aluminum' & aluminum_share > 0 ~ aluminum_share,
            hts10 %in% deriv_only                            ~ metal_share,  # fallback
            TRUE ~ 1.0
          ),
          rate_232 = if_else(
            hts10 %in% deriv_only & .scale_share < 1.0,
            rate_232 * .scale_share,
            rate_232
          )
        ) %>% select(-.scale_share)
    } else {
      # Fallback: aggregate metal_share (backward compat for flat/cbo methods)
      rates <- rates %>%
        mutate(rate_232 = if_else(
          hts10 %in% deriv_only & metal_share < 1.0,
          rate_232 * metal_share,
          rate_232
        ))
    }

    # Reset metal_share to 1.0 for heading products excluded from scaling.
    # Their rate_232 applies to the full product value (heading rate dominates),
    # not the metal portion. Without this, stacking incorrectly computes
    # nonmetal_share > 0 and lets IEEPA fill the "non-metal" portion.
    heading_derivs <- intersect(deriv_matched, heading_products)
    if (length(heading_derivs) > 0) {
      rates <- rates %>%
        mutate(metal_share = if_else(hts10 %in% heading_derivs, 1.0, metal_share))
      if (has_per_type) {
        rates <- rates %>%
          mutate(
            steel_share       = if_else(hts10 %in% heading_derivs, 0, steel_share),
            aluminum_share    = if_else(hts10 %in% heading_derivs, 0, aluminum_share),
            copper_share      = if_else(hts10 %in% heading_derivs, 0, copper_share),
            other_metal_share = if_else(hts10 %in% heading_derivs, 0, other_metal_share)
          )
      }
      message('  Reset metal_share=1.0 for ', length(heading_derivs),
              ' heading/derivative overlap products')
    }

    n_deriv_with_232 <- sum(rates$hts10 %in% deriv_matched & rates$rate_232 > 0)
    message('  Derivative 232 after metal scaling: ', n_deriv_with_232,
            ' product-country pairs')
  }

  return(list(rates = rates, deriv_matched = deriv_matched))
}


# =============================================================================
# Grid Densification Helper
# =============================================================================
# Per-Revision Rate Calculator
# =============================================================================

#' Calculate rates for a single HTS revision
#'
#' Wraps calculate_rates_fast() but applies blanket tariffs that are NOT
#' referenced via product footnotes:
#'   - IEEPA reciprocal: blanket on all products for applicable countries
#'   - IEEPA fentanyl: blanket on all products for CA/MX/CN
#'   - Section 232: blanket on steel/aluminum/auto/copper/derivative products
#'   - Section 301: blanket on China products from product list
#'   - USMCA exemptions: eligible products exempt from IEEPA for CA/MX
#'
#' @param products Product data from parse_products()
#' @param ch99_data Chapter 99 data from parse_chapter99()
#' @param usmca USMCA eligibility from extract_usmca_eligibility() (or NULL)
#' @param countries Vector of Census country codes
#' @param revision_id Revision identifier (e.g., 'rev_7')
#' @param effective_date Date the revision took effect
#' @param specs AuthoritySpec set from build_authority_specs() (REQUIRED), the
#'   calculator's sole authority/rate input.
#' @return Tibble with rate columns + revision, effective_date, usmca_eligible
# =============================================================================
# Pipeline step functions for calculate_rates_for_revision()
# -----------------------------------------------------------------------------
# Each function below is one named step of the per-revision rate pipeline,
# extracted verbatim from the former monolithic body so the driver reads as a
# short sequence of named stages. Bodies are unchanged — the refactor is
# behavior-preserving and parity-gated (Phase 1a). Steps that only transform the
# `rates` table take it as the first argument and return it; the §232 cluster
# returns a small bag of locals consumed by the later USMCA step.
# =============================================================================

# --- Step 6b: Section 122 blanket tariff -------------------------------------
apply_section122 <- function(rates, specs, pp, products, effective_date) {
  # 6b. Apply Section 122 blanket tariff (non-discriminatory, all countries)
  #     Section 122 (Trade Act of 1974) is a uniform tariff applied after SCOTUS
  #     invalidated IEEPA. Product exemptions from Annex II list; 232 mutual
  #     exclusion handled by apply_stacking_rules().
  #     Section 122 has a 150-day statutory limit; gate on expiry unless finalized.
  # Plank 3: Section 122 is de-blobbed — the rate lives in the spec's compositional
  # rate$default layer; the calc READS it via resolve_rate() (value > 0 is the
  # has_s122 gate, matching the old blob's has_s122 ≡ rate>0).
  s122_value <- resolve_rate(specs[['section_122']]$programs[[1]]$rate)$value
  s122_rates <- if (isTRUE(s122_value > 0)) list(s122_rate = s122_value, has_s122 = TRUE)
                else                        list(s122_rate = 0,          has_s122 = FALSE)

  s122_in_force <- TRUE
  if (!is.null(pp$SECTION_122) && !pp$SECTION_122$finalized) {
    s122_in_force <- (as.Date(effective_date) >= pp$SECTION_122$effective_date &&
                      as.Date(effective_date) <= pp$SECTION_122$expiry_date)
  }

  if (s122_rates$has_s122 && !s122_in_force) {
    message('  Section 122 expired (', pp$SECTION_122$expiry_date, ') — not applied')
  }

  if (s122_rates$has_s122 && s122_in_force) {
    s122_rate <- s122_rates$s122_rate

    # Product exemptions (note 2(aa)) — read from the spec (Pass-1.5; the adapter
    # bakes section_122$programs[[1]]$exempt_products). Masking stays below.
    #   $hts8     — UNCONDITIONAL (aa)(ii)/(iii) codes: full-line exempt.
    #   $gn6_hts8 — (aa)(iv) civil-aircraft codes: USE-conditional (GN6). The
    #     exemption applies only to GN6-certified entries, so these lines are
    #     scaled by (1 - exempt_share): rate_s122 = s122_rate * (1 - share),
    #     where share is the measured/inferred GN6 utilization per HTS10.
    #     Applying them full-line understated §122 by ~$800M/mo — see
    #     docs/s122_aircraft_exemption_audit.md.
    ep <- specs[['section_122']]$programs[[1]]$exempt_products %||% list()
    s122_exempt_hts8 <- ep$hts8 %||% character(0)
    s122_gn6_hts8    <- ep$gn6_hts8 %||% character(0)
    s122_gn6_util    <- ep$gn6_utilization %||% setNames(numeric(0), character(0))

    if (length(s122_exempt_hts8) + length(s122_gn6_hts8) > 0) {
      message('  Section 122 exempt products: ', length(s122_exempt_hts8),
              ' unconditional + ', length(s122_gn6_hts8),
              ' GN6-conditional HTS8 codes')
    }

    # Per-HTS10 GN6 exempt share: measured -> HS2 mean -> full exemption (1).
    # The HS2-mean fallback keeps an unmeasured aircraft line from silently
    # returning to full exemption (the bias being fixed); the final coalesce
    # to 1 is the explicit legacy behavior when there is no data at all.
    gn6_share_tbl <- NULL
    if (length(s122_gn6_hts8) > 0) {
      gn6_hts10_all <- products %>%
        filter(substr(hts10, 1, 8) %in% s122_gn6_hts8) %>% distinct(hts10)
      hs2_mean <- if (length(s122_gn6_util) > 0) {
        tibble(hts10 = names(s122_gn6_util), share = unname(s122_gn6_util)) %>%
          mutate(hs2 = substr(hts10, 1, 2)) %>%
          group_by(hs2) %>% summarise(hs2_share = mean(share), .groups = 'drop')
      } else tibble(hs2 = character(0), hs2_share = numeric(0))
      meas <- tibble(hts10 = names(s122_gn6_util), meas_share = unname(s122_gn6_util))
      gn6_share_tbl <- gn6_hts10_all %>%
        left_join(meas, by = 'hts10') %>%
        mutate(hs2 = substr(hts10, 1, 2)) %>%
        left_join(hs2_mean, by = 'hs2') %>%
        mutate(gn6_exempt_share = dplyr::coalesce(meas_share, hs2_share, 1),
               gn6_factor = 1 - gn6_exempt_share) %>%
        select(hts10, gn6_factor)
    }

    # Set rate_s122 on existing rows: full rate, 0 on unconditional exempt,
    # scaled by (1 - GN6 exempt share) on the aircraft set.
    rates <- rates %>%
      mutate(.hts8 = substr(hts10, 1, 8))
    if (!is.null(gn6_share_tbl)) {
      rates <- rates %>% left_join(gn6_share_tbl, by = 'hts10',
                                   relationship = 'many-to-one')
    } else {
      rates$gn6_factor <- NA_real_
    }
    rates <- rates %>%
      mutate(
        rate_s122 = dplyr::case_when(
          .hts8 %in% s122_exempt_hts8 ~ 0,
          .hts8 %in% s122_gn6_hts8    ~ s122_rate * coalesce(gn6_factor, 0),
          TRUE                        ~ s122_rate
        )
      ) %>% select(-.hts8, -gn6_factor)

    n_with_s122 <- sum(rates$rate_s122 > 0)
    message('  Section 122: ', round(s122_rate * 100), '% on ',
            n_with_s122, ' product-country pairs (',
            length(s122_exempt_hts8), ' HTS8 full-exempt, ',
            length(s122_gn6_hts8), ' GN6 aircraft utilization-scaled)')
  }

  rates
}

# --- Step 6b-fl: Section 301 forced-labor duties (scenario) ------------------
apply_section301_forced_labor <- function(rates, specs, countries) {
  # 6b-fl. Apply Section 301 forced-labor duties (SCENARIO authority).
  #     Per-country two tiers (10% / 12.5%) on ALL products of the in-scope
  #     economies EXCEPT the Annex A exclusion list (hts8). Stacks like the
  #     reciprocal/§122 — content_split (displaced by §232) + USMCA-eligible
  #     (applied in step 7 + apply_stacking_rules). The authority is built only
  #     when the merged config carries `section_301_forced_labor`
  #     (config/scenarios/forced_labor/) AND is DATE-GATED to >= effective_date,
  #     so by_country is empty in baseline / pre-turn-on revisions and rate_s301fl
  #     stays all-zero; the all-zero column is DROPPED before return (see end of
  #     function), keeping baseline byte-identical with no RATE_SCHEMA change.
  fl_spec <- specs[['section_301_forced_labor']]
  fl_by_country <- if (is.null(fl_spec)) numeric(0) else {
    bc <- .rate_get(fl_spec$programs[[1]]$rate, 'by_country')
    if (is.null(bc)) numeric(0) else bc
  }
  rates$rate_s301fl <- 0   # present for the USMCA step; dropped at end if all-zero
  if (length(fl_by_country) > 0) {
    fl_exempt_hts8 <- fl_spec$programs[[1]]$exempt_products$hts8 %||% character(0)
    fl_scope <- intersect(names(fl_by_country), countries)
    fl_tbl <- tibble(country = names(fl_by_country),
                     .fl_rate = unname(as.numeric(fl_by_country)))
    rates <- rates %>%
      left_join(fl_tbl, by = 'country', relationship = 'many-to-one') %>%
      mutate(rate_s301fl = if_else(
        !is.na(.fl_rate) & !(substr(hts10, 1, 8) %in% fl_exempt_hts8),
        .fl_rate, 0)) %>%
      select(-.fl_rate)
    message('  Section 301 forced labor: 10%/12.5% on ', sum(rates$rate_s301fl > 0),
            ' product-country pairs across ', length(fl_scope), ' economies (',
            length(fl_exempt_hts8), ' Annex A HTS8 exempt)')
  }

  rates
}

# --- Step 6b-br: Section 301 Brazil duties (baseline) -------------------------
apply_section301_brazil <- function(rates, specs, products, countries) {
  # 6b-br. Apply Section 301 Brazil duties: 25% on ALL goods of Brazil (census
  #     3510) via heading 9903.05.01 / U.S. note 50 (FINAL ACTION, FR Doc
  #     2026-14542; published 2026-07-20, effective 2026-07-22). BASELINE
  #     authority — signed law — hand-fed from policy params + side-data list
  #     (no HTS archive carries the 9903.05.0x headings yet; §338 pattern).
  #     Stacks ADDITIVELY (note 50(a): in addition to every other ch-99 duty,
  #     incl. the scenario forced-labor §301 — neither notice carves out the
  #     other) via stacking class 'additive'; usmca 'none' (Brazil isn't USMCA).
  #     Three in-scope reductions:
  #       * the note-50(a)(ii)+(iii) UNCONDITIONAL exclusions (875 hts8,
  #         resources/s301_brazil_exempt_products.csv: flat subheadings +
  #         "particular articles") — fully exempt.
  #       * the note-50(a)(iv)/(v) USE-CONDITIONAL lists (546 aircraft-use +
  #         705 pharma-use hts8, own resource files): exempt only for GN6
  #         civil-aircraft use / pharmaceutical applications, so covered lines
  #         pay rate * (1 - utilization share) (shares in policy_params back
  #         out of GTA's published effective rates: 2.5% aircraft, 12.5%
  #         pharma). Flat exemption would un-do the final action's deliberate
  #         narrowing (364 pharma lines were unconditional in the June
  #         proposal) and contradict the §338 GN6 share-scaling precedent.
  #       * §232 FULL per-article exclusion (note 50(a)(vi) / heading
  #         9903.05.07): any article in §232 SCOPE — statutory_rate_232 > 0,
  #         an IN-SCOPE s232_annex tier (annex_1a/1b/1c/3; annex_2 = removed
  #         from scope and still pays), or heading_program — pays ZERO Brazil
  #         §301 even on its non-metal content. Same deliberate scope MASK as
  #         apply_section338 (note 51(c)); the June-4 PROPOSED annex's
  #         content_split coding is retired with the final action. (a)(vi)
  #         enumerates steel/alu/copper + derivatives, PV/LT + parts, MHD +
  #         parts, wood and semiconductor headings; patented pharma joins via
  #         Annex I Part B effective 2026-07-31 — BEFORE the model's
  #         pharma-§232 turn-on (2026-09-29), so the heading_program arm
  #         (which tags pharma rows only from that date) reproduces the legal
  #         timeline exactly: no pharma-§232 duty is collectible in the
  #         07-22..09-29 window either way.
  #     rate_s301br is a RATE_SCHEMA column: it persists all-zero in pre-07-22
  #     revisions (baseline column, like rate_s338 — unlike the scenario
  #     rate_s301fl). Runs after the §232 PRIMARY steps, next to 6b-338 — the
  #     mask is a statutory-MEMBERSHIP read, and the 6b-338 call-site CAVEAT +
  #     TRIPWIRE (later 6e/6f/7c/7d mutations; currently exact,
  #     verify-guarded) applies verbatim — see the call site.
  br_spec <- specs[['section_301_brazil']]
  br_by_country <- if (is.null(br_spec)) numeric(0) else {
    bc <- .rate_get(br_spec$programs[[1]]$rate, 'by_country')
    if (is.null(bc)) numeric(0) else bc
  }
  rates$rate_s301br <- 0
  if (length(br_by_country) > 0) {
    br_ex <- br_spec$programs[[1]]$exempt_products %||% list()
    br_exempt_hts8   <- br_ex$hts8 %||% character(0)
    br_aircraft_hts8 <- br_ex$aircraft_hts8 %||% character(0)
    br_aircraft_share <- as.numeric(br_ex$aircraft_share %||% 0)
    br_pharma_hts8   <- br_ex$pharma_hts8 %||% character(0)
    br_pharma_share  <- as.numeric(br_ex$pharma_share %||% 0)
    br_scope <- intersect(names(br_by_country), countries)

    # §232 scope mask over EXISTING rows (note 50(a)(vi)); same mask as
    # apply_section338 (note 51(c)) — see that docstring for the annex-tier
    # rationale (annex_2 articles are REMOVED from §232 scope and still pay).
    BR_ANNEX_IN_SCOPE <- c('annex_1a', 'annex_1b', 'annex_1c', 'annex_3')
    stat232  <- if ('statutory_rate_232' %in% names(rates)) {
      coalesce(rates$statutory_rate_232, 0)
    } else coalesce(rates$rate_232, 0)
    annex232 <- if ('s232_annex' %in% names(rates)) {
      rates$s232_annex %in% BR_ANNEX_IN_SCOPE
    } else FALSE
    headprog <- if ('heading_program' %in% names(rates)) {
      coalesce(rates$heading_program, FALSE)
    } else FALSE
    in_232_scope <- stat232 > 0 | annex232 | headprog

    br_tbl <- tibble(country = names(br_by_country),
                     .br_rate = unname(as.numeric(br_by_country)))
    rates <- rates %>%
      left_join(br_tbl, by = 'country', relationship = 'many-to-one') %>%
      mutate(rate_s301br = if_else(
        !is.na(.br_rate) & !(substr(hts10, 1, 8) %in% br_exempt_hts8) &
          !in_232_scope,
        .br_rate, 0)) %>%
      select(-.br_rate)

    # USE-conditional (a)(iv)/(v) scaling on the complete grid (the one-grid
    # build materializes every pair, so the legacy missing-pair seeder is
    # unnecessary: the per-row in_232_scope mask above already covers all rows).
    # Precedence unconditional > aircraft > pharma is moot in practice — the
    # parser asserts the three lists disjoint — but case_when keeps it explicit.
    if (length(br_aircraft_hts8) > 0 || length(br_pharma_hts8) > 0) {
      br_hts8 <- substr(rates$hts10, 1, 8)
      br_cond_factor <- case_when(
        br_hts8 %in% br_aircraft_hts8 ~ 1 - br_aircraft_share,
        br_hts8 %in% br_pharma_hts8   ~ 1 - br_pharma_share,
        TRUE ~ 1)
      rates$rate_s301br <- rates$rate_s301br * br_cond_factor
    }
    message('  Section 301 Brazil: 25% on ', sum(rates$rate_s301br > 0),
            ' product-country pairs across ', length(br_scope), ' economies (',
            length(br_exempt_hts8), ' unconditional HTS8 exempt; ',
            length(br_aircraft_hts8), ' aircraft-use @ ',
            round((1 - br_aircraft_share) * 100, 1), '% of rate; ',
            length(br_pharma_hts8), ' pharma-use @ ',
            round((1 - br_pharma_share) * 100, 1), '% of rate; §232-scope excluded)')
  }

  rates
}

# --- Step 6b-338: Section 338 Canada duties (baseline) ------------------------
apply_section338 <- function(rates, specs, products, countries) {
  # 6b-338. Apply Section 338 duties: +50% on products of Canada over the three
  #     positive HTS-8 lists (U.S. note 51(b), headings 9903.03.12-.14; three
  #     proclamations signed 2026-07-20, effective 2026-08-19). BASELINE
  #     authority — signed law — hand-fed from policy params + side-data lists
  #     (no HTS archive carries the 9903.03.1x headings yet; pharma/Brazil
  #     pattern). Stacks ADDITIVELY (note 51(a): in addition to every other
  #     duty) via stacking class 'additive'; usmca 'none' (the duty applies
  #     regardless of USMCA origin), so rate_s338 is NOT in the step-7 USMCA
  #     reduction sets. Two in-scope reductions:
  #       * §232 FULL per-article exclusion (note 51(c) / heading 9903.03.15):
  #         any article in §232 SCOPE — statutory_rate_232 > 0 (metals +
  #         derivatives incl. deal countries), an IN-SCOPE s232_annex tier
  #         (annex_1a/1b/1c/3; annex_2 = removed from scope and still pays),
  #         or heading_program (autos/MHD/wood/semi/pharma headings, incl.
  #         USMCA-eligible parts paying 0%) —
  #         pays ZERO s338, even on its non-metal content. Deliberately a scope
  #         MASK, not content_split (which would leak s338 onto the non-metal
  #         fraction) and not rate_232 > 0 (which would miss 0%-paying USMCA
  #         parts). Self-updating: when pharma-§232 activates (2026-09-29) its
  #         heading rows drop out here, matching note 51(c)(8)'s 9903.04.60-66
  #         exclusion.
  #       * GN6 civil aircraft (note 51(d) / heading 9903.03.16): the exemption
  #         is USE-conditional, so covered∩GN6 lines are scaled by
  #         (1 - GN6 utilization share), share = measured HTS10 -> 0 (unmeasured).
  #         Unlike §122 there is NO HS2-mean interpolation tier and the fallback
  #         is 0 (vs §122's -> 1): the 28 affected mv-list codes (routers,
  #         furniture, cameras) are overwhelmingly NOT aircraft-certified entries,
  #         so an unmeasured one is treated as fully dutiable, not interpolated
  #         from the aircraft-heavy §122 chapter mean.
  #     rate_s338 is a RATE_SCHEMA column: it persists all-zero in pre-08-19
  #     revisions (baseline column, unlike the scenario s301fl/br columns).
  s338_spec <- specs[['section_338']]
  s338_by_country <- if (is.null(s338_spec)) numeric(0) else {
    bc <- .rate_get(s338_spec$programs[[1]]$rate, 'by_country')
    # .rate_is_hollow is retired with the sentinel payloads (validate_rate now
    # rejects them), so absent == NULL — same adaptation as the Brazil block.
    if (is.null(bc)) numeric(0) else bc
  }
  rates$rate_s338 <- 0
  if (length(s338_by_country) > 0) {
    list_file <- s338_spec$programs[[1]]$product_scope$list_file %||%
      'resources/s338_products.csv'
    s338_path <- here(list_file)
    if (!file.exists(s338_path)) {
      stop('Section 338 product list not found at ', s338_path,
           ' — run scripts/build_s338_annex.R')
    }
    s338_products <- read_csv_cached(s338_path, col_types = cols(
      hts8 = col_character(), program = col_character(),
      ch99_heading = col_character()))
    covered_hts8 <- unique(s338_products$hts8)
    ep <- s338_spec$programs[[1]]$exempt_products %||% list()
    gn6_hts8 <- intersect(ep$gn6_hts8 %||% character(0), covered_hts8)
    gn6_util <- ep$gn6_utilization %||% setNames(numeric(0), character(0))
    s338_scope <- intersect(names(s338_by_country), countries)

    # Per-HTS10 GN6 retention factor on covered∩GN6 lines: 1 - exempt share,
    # share = measured GN6 utilization -> 0 (unmeasured). NOTE the deliberate
    # divergence from §122's measured -> HS2-mean-of-measured -> 1 ladder: §122's
    # exempt set is genuinely civil-aircraft, so an unmeasured sibling is likely
    # aircraft and an HS2-chapter mean is a reasonable interpolation. §338's
    # covered∩GN6 overlap is CONSUMER goods (routers, monitors, furniture) that
    # merely share an HTS8 with the note-51(d) aircraft list; note 51(d)'s own
    # judgment (and docs/statutory_deviations.md S7) is that these unmeasured
    # overlap codes are NOT aircraft entries -> full duty. An HS2 mean over the
    # shared §122 aircraft-utilization table would pool genuine-aircraft shares
    # (~0.17 on chs 84/85) onto them, understating the duty ~9pp and contradicting
    # that judgment — so there is NO HS2-mean tier here: unmeasured -> 0 (full).
    gn6_share_tbl <- NULL
    if (length(gn6_hts8) > 0) {
      gn6_hts10_all <- products %>%
        filter(substr(hts10, 1, 8) %in% gn6_hts8) %>% distinct(hts10)
      meas <- tibble(hts10 = names(gn6_util), meas_share = unname(gn6_util))
      gn6_share_tbl <- gn6_hts10_all %>%
        left_join(meas, by = 'hts10') %>%
        mutate(gn6_exempt_share = pmin(pmax(coalesce(meas_share, 0), 0), 1),
               gn6_factor = 1 - gn6_exempt_share) %>%
        select(hts10, gn6_factor)
    }

    # §232 scope mask over EXISTING rows (note 51(c)); see docstring. The annex
    # arm is TIER-SCOPED: annex_2 = REMOVED from §232 scope (statutory 0, not
    # "provided for" in the 9903.82 headings note 51(c)(1) cites), so those
    # articles still pay s338 — 54 covered Canada lines incl. beer 2203.00.00,
    # which the alcohol proclamation lists explicitly. A bare !is.na(s232_annex)
    # arm wrongly exempted them (caught in the codex cross-check 2026-07-20).
    S338_ANNEX_IN_SCOPE <- c('annex_1a', 'annex_1b', 'annex_1c', 'annex_3')
    stat232  <- if ('statutory_rate_232' %in% names(rates)) {
      coalesce(rates$statutory_rate_232, 0)
    } else coalesce(rates$rate_232, 0)
    annex232 <- if ('s232_annex' %in% names(rates)) {
      rates$s232_annex %in% S338_ANNEX_IN_SCOPE
    } else FALSE
    headprog <- if ('heading_program' %in% names(rates)) {
      coalesce(rates$heading_program, FALSE)
    } else FALSE
    in_232_scope <- stat232 > 0 | annex232 | headprog

    s338_tbl <- tibble(country = names(s338_by_country),
                       .s338_rate = unname(as.numeric(s338_by_country)))
    rates <- rates %>%
      left_join(s338_tbl, by = 'country', relationship = 'many-to-one') %>%
      mutate(rate_s338 = if_else(
        !is.na(.s338_rate) & substr(hts10, 1, 8) %in% covered_hts8 & !in_232_scope,
        .s338_rate, 0)) %>%
      select(-.s338_rate)
    if (!is.null(gn6_share_tbl)) {
      rates <- rates %>%
        left_join(gn6_share_tbl, by = 'hts10', relationship = 'many-to-one') %>%
        mutate(rate_s338 = if_else(!is.na(gn6_factor),
                                   rate_s338 * gn6_factor, rate_s338)) %>%
        select(-gn6_factor)
    }

    # No missing-pair seeding: the one-grid build materializes every
    # (hts10, country) pair up front, so the per-row mask + GN6 scaling above
    # already covered the full universe (the legacy sparse-table seeders are
    # retired with add_blanket_pairs).

    message('  Section 338 (Canada): ',
            round(mean(s338_by_country[s338_scope]) * 100), '% on ',
            sum(rates$rate_s338 > 0), ' product-country pairs (',
            length(covered_hts8), ' HTS8 covered, §232-scope excluded, ',
            length(gn6_hts8), ' GN6 HTS8 utilization-scaled)')
  }

  rates
}

# --- Step 6b1: Section 201 safeguard (solar) ---------------------------------
apply_section201 <- function(rates, specs, countries) {
  # 6b1. Apply Section 201 (Trade Act §201 safeguard) tariffs.
  #      Currently models Solar 201 (Proc 9693 + Proc 10454, 9903.45.21–.25)
  #      on CSPV cells/modules. The 201 rate stacks on top of MFN, separate
  #      from 232/301/IEEPA. Canada is exempt under USMCA. Per-product
  #      coverage is in resources/s201_solar_products.csv.
  prog <- specs[['section_201']]$programs[[1]]
  solar_rate <- resolve_rate(prog$rate)$value
  if (!is.na(solar_rate) && solar_rate > 0) {
    s201_path <- here(prog$product_scope$list_file)
    if (!file.exists(s201_path))
      stop('Section 201 product list not found: ', s201_path)
    s201_products <- read_csv_cached(s201_path,
                                     col_types = cols(hts10 = col_character()))
    s201_country_codes <- resolve_country_scope(prog$country_scope, countries)
    rates <- rates %>%
      mutate(rate_section_201 = if_else(
        hts10 %in% s201_products$hts10 & country %in% s201_country_codes,
        solar_rate, rate_section_201))
    message('  Section 201 (solar): ', round(solar_rate * 100, 1), '% on ',
            sum(rates$rate_section_201 > 0), ' product-country pairs (',
            nrow(s201_products), ' HTS10 covered)')
  }

  rates
}

# --- Step 6: Section 301 blanket + USTR exclusions ---------------------------
apply_section301 <- function(rates, specs, pp, ch99_data, products, countries, effective_date) {
  # 6. Apply Section 301 as blanket tariff for China
  #     301 products are defined by US Note 20/21/31 product lists (Federal Register).
  #     Like 232, these are NOT referenced via product footnotes for most products.
  #     Source: USITC "China Tariffs" reference document (hts.usitc.gov).
  #
  #     Scope note: This blanket step is intentionally limited to the China
  #     Section 301 product lists maintained in resources/s301_product_lists.csv.
  #     It does not use 9903.89.xx, which belongs to the separate large civil
  #     aircraft dispute with the EU/UK and is assumed suspended from 2021 onward
  #     for the current series horizon.
  programs <- specs[['section_301']]$programs
  names(programs) <- vapply(programs, function(p) p$id, character(1))
  apply_tier <- function(x, program_id, output_col, label) {
    prog <- programs[[program_id]]
    tier <- .rate_get(prog$rate, 'by_product_tier')
    if (is.null(tier)) return(x)
    if (!is.numeric(tier) || !length(tier) || is.null(names(tier)))
      stop('Section 301 program ', program_id, ' has an invalid by_product_tier')
    lookup_col <- paste0('.', output_col)
    lookup <- tibble(hts8 = names(tier), !!lookup_col := as.numeric(tier))
    scope <- resolve_country_scope(prog$country_scope, countries)
    x <- x %>%
      mutate(hts8 = substr(hts10, 1, 8)) %>%
      left_join(lookup, by = 'hts8', relationship = 'many-to-one') %>%
      mutate(
        !!output_col := if_else(
          country %in% scope,
          pmax(.data[[output_col]], coalesce(.data[[lookup_col]], 0)),
          0)) %>%
      select(-hts8, -all_of(lookup_col))
    message('  Section 301 ', label, ': ', length(tier), ' HTS8 codes, ',
            sum(x[[output_col]] > 0), ' product-country pairs')
    x
  }
  rates <- apply_tier(rates, 's301', 'rate_301', 'additive')
  rates <- apply_tier(rates, 's301_content_split', 'rate_301_cs', 'content-split')

  # 6a-excl. Section 301 USTR exclusion headings (e.g. 9903.88.69). These
  #     headings carry NO rate ("The duty provided in the applicable
  #     subheading") and EXCLUDE the referencing product from §301 duties
  #     while their window is in force. The NA rate drops them from the
  #     footnote-rate join in calculate_rates_fast(), so without this step
  #     the engine charges full §301 mid-exclusion (todo.md §"§301 exclusion
  #     headings"). The registry CSV names known exclusion headings +
  #     coverage_share; the validity window comes from THIS revision's own
  #     heading text (windows are recomputed from the description right here,
  #     so the step is immune to ch99_<rev>.rds caches that predate the
  #     expiry_date_offset column), with the CSV's validity_start/_end as
  #     curator overrides. Phase 1: coverage_share = 1.0 full-line zeroing,
  #     the flagged UPPER BOUND on the correction (exclusions are product-
  #     description-scoped and usually cover a slice of an HTS10 line);
  #     Phase 2 replaces it with IMDB-realized exclusion claim shares.
  excl_cfg <- pp$section_301_exclusions
  if (!is.null(excl_cfg)) {
    excl_path <- here(excl_cfg$headings_file %||% 'resources/s301_exclusion_headings.csv')
    if (!file.exists(excl_path)) {
      stop('section_301_exclusions configured but headings file not found: ',
           excl_path)
    }
    excl_registry <- suppressMessages(read_csv_cached(excl_path, col_types = cols(
      ch99_code = col_character(), validity_start = col_date(),
      validity_end = col_date(), coverage_share = col_double(),
      .default = col_character()
    )))

    eff_d <- as.Date(effective_date)
    active_excl <- ch99_data %>%
      filter(ch99_code %in% excl_registry$ch99_code) %>%
      mutate(
        win_start = as.Date(vapply(description, function(d)
          as.character(extract_effective_date_offset(d)), character(1),
          USE.NAMES = FALSE)),
        win_end = as.Date(vapply(description, function(d)
          as.character(extract_expiry_date_offset(d)), character(1),
          USE.NAMES = FALSE))
      ) %>%
      distinct(ch99_code, win_start, win_end) %>%
      inner_join(excl_registry, by = 'ch99_code') %>%
      mutate(
        win_start = coalesce(validity_start, win_start),
        win_end   = coalesce(validity_end,   win_end)
      ) %>%
      filter(coverage_share > 0,
             is.na(win_start) | win_start <= eff_d,
             is.na(win_end)   | eff_d <= win_end)

    if (nrow(active_excl) > 0) {
      excl_shares <- products %>%
        select(hts10, ch99_refs) %>%
        unnest(ch99_refs) %>%
        rename(ch99_code = ch99_refs) %>%
        inner_join(active_excl %>% select(ch99_code, coverage_share),
                   by = 'ch99_code') %>%
        group_by(hts10) %>%
        summarise(excl_coverage = max(coverage_share), .groups = 'drop')

      # Optional per-HTS10 refinement (Phase-2 calibration): when
      # section_301_exclusions.line_coverage_file is configured, lines present
      # in the file use their measured coverage_share instead of the heading
      # value; affected lines absent from the file keep the heading value.
      # Scope is unchanged — the file only ever OVERRIDES coverage for lines
      # that already reference an in-window heading, so out-of-window dates
      # are untouched. Absent config key = dormant (heading-level only).
      # Provenance: tools/calibrate_s301_exclusions.R,
      # docs/s301_exclusion_calibration.md.
      if (!is.null(excl_cfg$line_coverage_file)) {
        line_cov_path <- here(excl_cfg$line_coverage_file)
        if (!file.exists(line_cov_path)) {
          stop('section_301_exclusions.line_coverage_file configured but ',
               'not found: ', line_cov_path)
        }
        line_cov <- suppressMessages(read_csv(line_cov_path, col_types = cols(
          hts10 = col_character(), coverage_share = col_double(),
          .default = col_character()
        ))) %>%
          select(hts10, line_coverage = coverage_share)
        if (any(is.na(line_cov$line_coverage)) ||
            any(line_cov$line_coverage < 0) || any(line_cov$line_coverage > 1)) {
          stop('line_coverage_file has coverage_share outside [0, 1] or NA: ',
               line_cov_path)
        }
        if (any(duplicated(line_cov$hts10))) {
          stop('line_coverage_file has duplicated hts10 rows: ', line_cov_path)
        }
        n_overridden <- sum(excl_shares$hts10 %in% line_cov$hts10)
        excl_shares <- excl_shares %>%
          left_join(line_cov, by = 'hts10', relationship = 'one-to-one') %>%
          mutate(excl_coverage = coalesce(line_coverage, excl_coverage)) %>%
          select(-line_coverage)
        message('  Section 301 exclusions: per-line coverage overrides for ',
                n_overridden, ' of ', nrow(excl_shares), ' affected lines (',
                basename(line_cov_path), ')')
      }

      if (nrow(excl_shares) > 0) {
        n_pairs_before <- sum(rates$rate_301 > 0)
        rates <- rates %>%
          left_join(excl_shares, by = 'hts10', relationship = 'many-to-one') %>%
          mutate(
            rate_301 = if_else(!is.na(excl_coverage),
                               rate_301 * (1 - excl_coverage), rate_301),
            rate_301_cs = if_else(!is.na(excl_coverage),
                                  rate_301_cs * (1 - excl_coverage), rate_301_cs)
          ) %>%
          select(-excl_coverage)
        message('  Section 301 exclusions: ', nrow(excl_shares),
                ' products reference ', nrow(active_excl),
                ' active exclusion heading',
                if (nrow(active_excl) == 1) '' else 's', ' (',
                paste(active_excl$ch99_code, collapse = ', '),
                '); pairs with rate_301 > 0: ', n_pairs_before,
                ' -> ', sum(rates$rate_301 > 0))
      }
    }
  }

  rates
}

calculate_rates_for_revision <- function(
  products, ch99_data, usmca,
  countries, revision_id, effective_date,
  specs,
  policy_params = NULL
) {
  message('Calculating rates for revision: ', revision_id, ' (', effective_date, ')')

  # AuthoritySpec is the sole rate input. Parsers are consumed by the adapter;
  # the calculator reads only structured programs.
  recip_rate     <- specs[['ieepa_reciprocal']]$programs[[1]]$rate
  fent_rate      <- specs[['ieepa_fentanyl']]$programs[[1]]$rate

  # Date-gate Ch99 entries: drop rows whose legal effective_date_offset is
  # AFTER this revision's effective_date. The HTS publishes new authorities
  # before they become legally collectible (e.g., 9903.94.01 added at rev_6,
  # 2025-03-12, with description specifying entries on or after 2025-04-03).
  # See tariff-etr-eval/docs/tracker_audits/s232_auto_effective_date_2026-04-28.md.
  ch99_data <- filter_active_ch99(ch99_data, as.Date(effective_date))

  pp <- policy_params %||% load_policy_params()
  assert_counterfactual_inputs_applied(pp)
  cc <- get_country_constants(pp)
  CTY_CHINA  <- cc$CTY_CHINA
  CTY_CANADA <- cc$CTY_CANADA
  CTY_MEXICO <- cc$CTY_MEXICO
  STEEL_CHAPTERS <- cc$STEEL_CHAPTERS
  ALUM_CHAPTERS  <- cc$ALUM_CHAPTERS
  ISO_TO_CENSUS  <- cc$ISO_TO_CENSUS

  swiss_fw <- pp$SWISS_FRAMEWORK
  swiss_countries <- as.character(swiss_fw$countries %||% character(0))
  swiss_effective_date <- as.Date(swiss_fw$effective_date %||% NA)
  swiss_expiry_date <- as.Date(swiss_fw$expiry_date %||% NA)
  swiss_framework_active <- !is.null(swiss_fw) &&
    as.Date(effective_date) >= swiss_effective_date &&
    (isTRUE(swiss_fw$finalized) || as.Date(effective_date) <= swiss_expiry_date)

  # 1. Get footnote-based rates from calculate_rates_fast()
  #    This captures 232, 301, fentanyl, other — but NOT IEEPA reciprocal,
  #    which is a blanket tariff not referenced via product footnotes.
  rates <- calculate_rates_fast(products, ch99_data, countries,
                                iso_to_census = ISO_TO_CENSUS,
                                cty_china = CTY_CHINA)

  # Persist the Swiss framework inputs on the panel. The applied result remains
  # rate_ieepa_recip; these fields make the temporary floor and the underlying
  # surcharge auditable without reconstructing policy state downstream.
  rates$swiss_underlying_rate_ieepa_recip <- 0
  rates$swiss_framework_floor_rate <- 0
  rates$swiss_framework_effective_date <- as.Date(NA)
  rates$swiss_framework_expiry_date <- as.Date(NA)
  swiss_rows <- rates$country %in% swiss_countries
  if (any(swiss_rows)) {
    rates$swiss_framework_floor_rate[swiss_rows] <- pp$FLOOR_RATE %||% 0
    rates$swiss_framework_effective_date[swiss_rows] <- swiss_effective_date
    rates$swiss_framework_expiry_date[swiss_rows] <- swiss_expiry_date
  }

  # 1b. Check IEEPA invalidation (SCOTUS ruling in Learning Resources v. Trump)
  #     If this revision's effective_date is on or after the invalidation date,
  #     IEEPA tariff authority is void — zero out reciprocal and fentanyl.
  # Phase 2d: the invalidation date is the IEEPA specs' active.until (a scenario
  # can move it via set_active). The adapter mirrors pp$IEEPA_INVALIDATION_DATE
  # verbatim, so baseline is identical. Both IEEPA specs share the date (the
  # `ieepa` group), so reciprocal's until governs the joint kill switch below
  # AND the grid densification at the matching site downstream.
  ieepa_invalidation <- specs[['ieepa_reciprocal']]$active$until
  ieepa_invalidated <- !is.null(ieepa_invalidation) &&
                       as.Date(effective_date) >= ieepa_invalidation
  if (ieepa_invalidated) {
    message('  IEEPA invalidated as of ', ieepa_invalidation,
            ' — zeroing reciprocal and fentanyl for ', revision_id)
    # Both reciprocal + fentanyl gated off via ieepa_invalidated below (S1/S2).
  }

  # 2. Apply IEEPA reciprocal (blanket, country-level)
  #    IEEPA reciprocal is a BLANKET tariff — it applies to all products for
  #    applicable countries, not just products with IEEPA footnotes. The country-
  #    specific rates from 9903.01/02.xx define the rate per country.
  #
  #    Product-level exemptions (Annex A / US Note 2 subdivision (v)(iii)):
  #    ~1,087 products are exempt from IEEPA reciprocal. These are defined by
  #    executive order, not by HTS footnotes, so we load from a resource file.
  # Plank 4b / S1: reciprocal is read from the de-blobbed spec layers. by_country
  # holds the collapsed, post-floor-override per-country rate — empty when there is
  # no usable entry (matching the old empty-active_ieepa zero path) or on invalidation.
  recip_by_country <- {
    bc <- .rate_get(recip_rate, 'by_country')
    if (is.null(bc)) numeric(0) else bc
  }
  has_active_ieepa <- !ieepa_invalidated && length(recip_by_country) > 0

  # Duty-free treatment: 'all' (default) applies IEEPA to all products;
  # 'nonzero_base_only' skips products with 0% MFN base rate (matches TPC).
  duty_free_treatment <- pp$ieepa_duty_free_treatment %||% 'all'
  if (duty_free_treatment != 'all') {
    message('  IEEPA duty-free treatment: ', duty_free_treatment)
  }

  # IEEPA Annex II exempt-list scope: 'all' (default, legally correct per
  # EO 14326 §3 + CBP CSMS #65829726) zeros listed products across baseline
  # + Phase 1/2 surcharges + floor; 'baseline_only' is a diagnostic that
  # zeros only the universal 10% baseline. See policy_params.yaml warning.
  ieepa_exempt_scope <- pp$ieepa_exempt_scope %||% 'all'
  if (ieepa_exempt_scope != 'all') {
    message('  IEEPA exempt scope: ', ieepa_exempt_scope,
            ' (DIAGNOSTIC — produces legally-incorrect output)')
  }

  # IEEPA product-exemption SETS — read from the spec (Pass-1.5). The adapter
  # (build_authority_specs) bakes the hand-curated exempt sets onto
  # ieepa_reciprocal$programs[[1]]$exempt_products, date-resolved at the revision
  # date; the calc READS them here and keeps the product-grid MASKING below.
  # Provenance (now in .resolve_* helpers in authority_adapter.R):
  #   universal  — Annex II (US Note 2 subdiv (v)(iii)) hts10 list, date-windowed
  #     by effective_date_start/_end (Annex II amended repeatedly: electronics
  #     Apr 5 2025, EO 14346 metals Sept 8, ag Nov 13; copper/wood REMOVED when
  #     their 232 programs began). Without the window, amendments applied
  #     retroactively (extreme-eta review item 3). The date-windowing that master
  #     did inline (scripts/build_annex_ii_dates.R stamps effective_date_start/_end;
  #     filter at the revision date) is now performed in the adapter's .resolve_*
  #     helpers, so the calc just reads the resolved set.
  #   country_eo — per-EO exempt (ch99_code, hts8_prefix) pairs (Brazil 9903.01.77,
  #     India 9903.01.84, ...), date-windowed; separate from the universal Annex A
  #     so the country-EO surcharge is not wrongly suppressed.
  #   floor      — (hts8, country_group) floor-tariff exemptions (EU/JP/KR/Swiss),
  #     US Note 2 subdiv (v)(xx)-(xxiv) + Note 3; per-revision file or static.
  .ieepa_exempt <- specs[['ieepa_reciprocal']]$programs[[1]]$exempt_products %||% list()
  ieepa_exempt_products <- .ieepa_exempt$universal %||% character(0)
  if (length(ieepa_exempt_products) > 0) {
    message('  IEEPA exempt products loaded: ', length(ieepa_exempt_products))
  }

  country_eo_exempt <- .ieepa_exempt$country_eo %||%
    tibble(ch99_code = character(), hts8_prefix = character())
  if (nrow(country_eo_exempt) > 0) {
    message('  Country-EO exempt products active at ', effective_date, ': ',
            nrow(country_eo_exempt), ' (HS8, ch99) pairs across ',
            n_distinct(country_eo_exempt$ch99_code), ' EOs')
  }

  floor_exempt_products <- .ieepa_exempt$floor %||%
    tibble(hts8 = character(), country_group = character())

  # Load product-level USMCA utilization shares from DataWeb SPI data (S/S+).
  # Year configured in policy_params.yaml (usmca_shares.year). Falls back to binary eligibility.
  usmca_product_shares <- load_usmca_product_shares(policy_params = pp, effective_date = effective_date)

  # Load MFN exemption shares (FTA/GSP preference utilization at HS2 x country level).
  # Adjusts statutory base_rate down before stacking. Sourced from Tariff-ETRs.
  mfn_exemption_shares <- if (pp$MFN_EXEMPTION$method == 'hs2') {
    load_mfn_exemption_shares()
  } else {
    NULL
  }

  if (has_active_ieepa) {
    # Plank 4b / S1: country_ieepa is READ from the de-blobbed reciprocal spec
    # layers. The adapter (.resolve_ieepa_reciprocal) performed the phase-collapse
    # (the active_ieepa group_by/summarise — Phase 2 + country_eo stack across phases,
    # country-specific supersedes within a phase: Brazil 10%+40%=50%, India 25%+25%=50%,
    # Tunisia max(15%,25%)=25%) AND the surcharge->floor override (FLOOR_COUNTRIES,
    # Swiss-window gated) VERBATIM at build time. by_country holds the post-override
    # per-country rate; the parallel by_country_type / _eo_rate / _eo_ch99 maps carry
    # the semantics tag + the country-EO two-term components. The inner gate is kept
    # (always TRUE once has_active_ieepa) so the defensive zero path is preserved.
    if (length(recip_by_country) > 0) {
      .recip_codes <- names(recip_by_country)
      .recip_type  <- .rate_get(recip_rate, 'by_country_type')
      .recip_underlying <- .rate_get(recip_rate, 'by_country_underlying') %||%
        recip_by_country
      .recip_underlying_type <- .rate_get(recip_rate, 'by_country_underlying_type') %||%
        .recip_type
      .recip_eor   <- .rate_get(recip_rate, 'by_country_eo_rate')
      .recip_eoc   <- .rate_get(recip_rate, 'by_country_eo_ch99')
      country_ieepa <- tibble(
        census_code = .recip_codes,
        ieepa_country_rate = unname(recip_by_country[.recip_codes]),
        ieepa_country_rate_underlying = unname(.recip_underlying[.recip_codes]),
        country_eo_rate = unname(.recip_eor[.recip_codes]),
        country_eo_ch99 = unname(.recip_eoc[.recip_codes]),
        ieepa_type = unname(.recip_type[.recip_codes]),
        ieepa_type_underlying = unname(.recip_underlying_type[.recip_codes]),
        is_universal_baseline_country = FALSE
      )

      # Apply universal baseline to countries not in any IEEPA entry.
      # 9903.01.25 (10%) applies to all countries; country-specific entries
      # provide higher rates for listed countries.
      # Exclude CA/MX: they have a separate fentanyl-only IEEPA regime and
      # are explicitly excluded from reciprocal tariffs by executive order.
      universal_baseline <- .rate_get(recip_rate, 'default_unlisted_rate')
      # Build country -> country_group mapping for floor exemption lookup
      has_floor_exempts <- nrow(floor_exempt_products) > 0
      if (has_floor_exempts) {
        floor_country_group_map <- bind_rows(
          tibble(country = pp$EU27_CODES, country_group = 'eu'),
          tibble(country = pp$country_codes$CTY_JAPAN, country_group = 'japan'),
          tibble(country = pp$country_codes$CTY_SKOREA, country_group = 'korea'),
          tibble(country = c(pp$country_codes$CTY_SWITZERLAND,
                             pp$country_codes$CTY_LIECHTENSTEIN), country_group = 'swiss')
          # Taiwan civil aircraft (9903.96.03) is intentionally not added here:
          # it exempts the Section 232 metals annex only (U.S. note 35(c)), NOT the
          # reciprocal tariff — this floor path only zeroes rate_ieepa_recip. The
          # parallel civil-aircraft lists already parsed for floor countries are
          # applied to the metals annex later in the dedicated 232 aircraft
          # carve-out block. (The EU/UK/JP/KR + all-country annex cases remain
          # unmodeled — see todo.)
        )
        message('  Floor country group map: ', nrow(floor_country_group_map), ' countries across ',
                n_distinct(floor_country_group_map$country_group), ' groups')
      }

      # Plank 4b / S1: the surcharge->floor override moved to the adapter
      # (.resolve_ieepa_reciprocal) — by_country / by_country_type already reflect it.
      # CA/MX (the reciprocal carve-out) come off the de-blobbed default_unlisted_exclude.
      recip_exempt <- .rate_get(recip_rate, 'default_unlisted_exclude') %||% character(0)
      if (!is.null(universal_baseline) && universal_baseline > 0) {
        unlisted_countries <- setdiff(countries, c(country_ieepa$census_code, recip_exempt))
        if (length(unlisted_countries) > 0) {
          baseline_entries <- tibble(
            census_code = unlisted_countries,
            ieepa_country_rate = universal_baseline,
            ieepa_country_rate_underlying = universal_baseline,
            country_eo_rate = 0,
            country_eo_ch99 = NA_character_,
            ieepa_type = 'surcharge',
            ieepa_type_underlying = 'surcharge',
            is_universal_baseline_country = TRUE
          )
          country_ieepa <- bind_rows(country_ieepa, baseline_entries)
          message('  Applied universal baseline (', round(universal_baseline * 100),
                  '%) to ', length(unlisted_countries), ' unlisted countries')
        }
      }

      # Apply IEEPA reciprocal to ALL products for applicable countries
      # EXCEPT products on the exemption list (Annex A / US Note 2)
      # and floor country product exemptions (EU/Swiss/Japan/Korea)

      # Build floor exemption lookup: a set of "hts8|country_group" keys
      if (has_floor_exempts) {
        floor_exempt_keys <- floor_exempt_products %>%
          select(hts8, country_group) %>%
          distinct() %>%
          mutate(key = paste0(hts8, '|', country_group)) %>%
          pull(key)
      } else {
        floor_exempt_keys <- character(0)
      }

      rates <- rates %>%
        left_join(
          country_ieepa %>% rename(country = census_code),
          by = 'country',
          relationship = 'many-to-one'
        )

      # Compute floor exemption flag via vectorized lookup
      if (has_floor_exempts) {
        rates <- rates %>%
          left_join(floor_country_group_map, by = 'country', relationship = 'many-to-one') %>%
          mutate(
            floor_exempt = !is.na(country_group) &
              paste0(substr(hts10, 1, 8), '|', country_group) %in% floor_exempt_keys
          ) %>%
          select(-country_group)
      } else {
        rates <- rates %>% mutate(floor_exempt = FALSE)
      }

      # Build a country-EO exempt key set for fast lookup. Each entry pairs
      # (country EO ch99 code) with (HS8 prefix). A product is exempt from
      # the country EO surcharge when both its 8-digit HS prefix and the
      # active EO ch99 code for that country match an entry.
      country_eo_exempt_keys <- if (nrow(country_eo_exempt) > 0) {
        paste(country_eo_exempt$ch99_code, country_eo_exempt$hts8_prefix, sep = '|')
      } else {
        character(0)
      }

      # Country EOs that inherit the universal Annex II list via their own
      # US-note subdivision. India: note 2(z)(ii) routes 9903.01.84 through
      # heading 9903.01.86 to "the provisions of the HTSUS listed in
      # subdivision (v)(iii) of note 2" — i.e. the full Annex II list.
      # Brazil's 9903.01.77 does NOT inherit: it has its own enumerated list
      # (note 2(x)(iii)(a), captured in country_eo_exempt_products.csv).
      annex_ii_inherit_eos <- unlist(pp$country_eo_annex_ii_inherit %||% character(0))

      # Every country-EO note carries the standard chapter 98 paragraph ("the
      # additional duty imposed by this heading shall not apply to goods for
      # which entry is properly claimed under a provision of chapter 98",
      # with value-basis carve-downs for 9802.00.40/.50/.60/.80) — verified
      # in the rev_6 notes for Brazil (x)(i) and India (z)(i). Reuse the ch98
      # scope already encoded on the universal exempt list (same set the
      # fentanyl ch98 exemption uses).
      ch98_eo_exempt <- ieepa_exempt_products[
        substr(ieepa_exempt_products, 1, 2) == '98']

      rates <- rates %>%
        mutate(
          # Universal Annex II applies to baseline + phase1 + phase2 surcharges
          # AND the floor structure; country_eo bypasses it and instead uses
          # (a) its own per-EO exempt list, (b) Annex II inheritance for EOs
          # in country_eo_annex_ii_inherit (India per note 2(z)(ii)), and
          # (c) the standard ch98 claim paragraph present in every EO's note.
          # ieepa_exempt_scope = 'baseline_only' (diagnostic) narrows the
          # universal exempt list to baseline-only countries.
          is_universally_exempt = hts10 %in% ieepa_exempt_products,
          is_country_eo_exempt  = !is.na(country_eo_ch99) & (
            paste(country_eo_ch99, substr(hts10, 1, 8), sep = '|') %in% country_eo_exempt_keys |
            (country_eo_ch99 %in% annex_ii_inherit_eos & is_universally_exempt) |
            hts10 %in% ch98_eo_exempt
          ),
          exempt_active = is_universally_exempt & (
            ieepa_exempt_scope == 'all' |
            (ieepa_exempt_scope == 'baseline_only' &
             coalesce(is_universal_baseline_country, FALSE))
          ),
          is_swiss_framework_country = country %in% swiss_countries,
          # The product carve-outs are part of the temporary country framework.
          # Outside its active window, Swiss/LI revert to the underlying surcharge.
          floor_exempt = floor_exempt &
            (!is_swiss_framework_country | swiss_framework_active),
          swiss_underlying_ieepa_type = if_else(
            is_swiss_framework_country, ieepa_type_underlying, NA_character_),
          swiss_underlying_ieepa_country_rate = if_else(
            is_swiss_framework_country, ieepa_country_rate_underlying, NA_real_),
          swiss_underlying_rate_ieepa_recip = case_when(
            !is_swiss_framework_country ~ 0,
            duty_free_treatment == 'nonzero_base_only' & base_rate < 0.001 ~ 0,
            is.na(ieepa_country_rate_underlying) ~ 0,
            ieepa_type_underlying == 'surcharge' ~
              if_else(exempt_active, 0, ieepa_country_rate_underlying - country_eo_rate) +
              if_else(is_country_eo_exempt, 0, country_eo_rate),
            ieepa_type_underlying == 'floor' & exempt_active ~ 0,
            ieepa_type_underlying == 'floor' ~
              apply_rate_semantics(ieepa_country_rate_underlying, 'floor_post_mfn', base_rate),
            ieepa_type_underlying == 'passthrough' ~ 0,
            TRUE ~ 0
          ),
          rate_ieepa_recip = case_when(
            duty_free_treatment == 'nonzero_base_only' & base_rate < 0.001 ~ 0,
            floor_exempt ~ 0,
            is.na(ieepa_country_rate) ~ 0,
            ieepa_type == 'surcharge' ~
              if_else(exempt_active, 0, ieepa_country_rate - country_eo_rate) +
              if_else(is_country_eo_exempt, 0, country_eo_rate),
            ieepa_type == 'floor' & exempt_active ~ 0,
            ieepa_type == 'floor' ~ apply_rate_semantics(ieepa_country_rate, 'floor_post_mfn', base_rate),
            ieepa_type == 'passthrough' ~ 0,
            TRUE ~ 0
          )
        ) %>%
        select(-ieepa_country_rate, -ieepa_country_rate_underlying,
               -ieepa_type_underlying, -country_eo_rate, -country_eo_ch99,
               -is_universally_exempt, -is_country_eo_exempt, -floor_exempt,
               -is_universal_baseline_country, -exempt_active,
               -is_swiss_framework_country)

    } else {
      # No usable IEEPA entries (all missing rate or census_code)
      rates <- rates %>% mutate(rate_ieepa_recip = 0)
    }
  } else {
    # No IEEPA in this revision — zero out
    rates <- rates %>% mutate(rate_ieepa_recip = 0)
  }

  # 3. Apply IEEPA fentanyl/initial rates with product-level carve-outs
  #    9903.01.01-24: Mexico (+25%), Canada (+35%), China (+10%)
  #    These STACK with reciprocal tariffs for CA/MX.
  #    China/HK included: fentanyl (9903.01.20/24) is NOT captured via
  #    product footnotes for China. The 9903.90.xx entries are Russia only.
  #
  #    Carve-outs: Certain product categories receive a lower fentanyl rate:
  #      - 9903.01.13 (CA): Energy, minerals, critical minerals → +10%
  #      - 9903.01.15 (CA): Potash → +10%
  #      - 9903.01.05 (MX): Potash → +10%
  #    Product lists from resources/fentanyl_carveout_products.csv.
  # Plank 4b / S2: fentanyl is read from the de-blobbed spec layers. by_country holds
  # the per-country general rate (the max-per-census collapse — e.g. China 9903.01.20
  # +10% / .24 +20% -> max — was done in the adapter). carveouts holds the per-ch99 x
  # census carve-out rates; the carve-out PRODUCT lists (hts8 prefixes) stay reference
  # data loaded here and joined to those rates, exactly as before.
  fent_by_country <- {
    bc <- .rate_get(fent_rate, 'by_country')
    if (is.null(bc)) numeric(0) else bc
  }
  fent_carveouts <- .rate_get(fent_rate, 'carveouts')
  has_fentanyl <- !ieepa_invalidated &&
                  (length(fent_by_country) > 0 || !is.null(fent_carveouts))

  if (has_fentanyl) {
    general_fent <- tibble(census_code = names(fent_by_country),
                           fent_rate = unname(fent_by_country))

    carveout_fent <- if (is.null(fent_carveouts)) {
      tibble(ch99_code = character(), census_code = character(), carveout_rate = numeric())
    } else {
      tibble(ch99_code = fent_carveouts$ch99_code,
             census_code = fent_carveouts$census_code,
             carveout_rate = fent_carveouts$rate)
    }

    # Load carve-out product lists and build lookup (once, reused below)
    carveout_products <- load_fentanyl_carveouts()
    has_carveouts <- !is.null(carveout_products) && nrow(carveout_fent) > 0

    carveout_lookup <- NULL
    if (has_carveouts) {
      # HTS8 × country → carve-out rate (join product list to parsed ch99 entries)
      carveout_lookup <- carveout_products %>%
        inner_join(carveout_fent, by = 'ch99_code') %>%
        distinct(hts8, census_code, .keep_all = TRUE) %>%
        select(hts8, census_code, carveout_rate)
    }

    # Apply fentanyl to existing rows: general rate with carve-out overrides
    if (has_carveouts) {
      rates <- rates %>%
        mutate(.hts8 = substr(hts10, 1, 8)) %>%
        left_join(general_fent, by = c('country' = 'census_code'), relationship = 'many-to-one') %>%
        left_join(carveout_lookup,
                  by = c('.hts8' = 'hts8', 'country' = 'census_code'), relationship = 'many-to-one') %>%
        mutate(
          rate_ieepa_fent = coalesce(carveout_rate, fent_rate, 0)
        ) %>%
        select(-fent_rate, -carveout_rate, -.hts8)

      n_carveout <- sum(rates$rate_ieepa_fent > 0 &
                        rates$rate_ieepa_fent < max(general_fent$fent_rate, na.rm = TRUE))
      message('  Fentanyl carve-outs applied: ', n_carveout, ' product-country pairs')
    } else {
      rates <- rates %>%
        left_join(general_fent, by = c('country' = 'census_code'), relationship = 'many-to-one') %>%
        mutate(rate_ieepa_fent = coalesce(fent_rate, 0)) %>%
        select(-fent_rate)
    }

    # Apply Ch98 exemption (US Note 2(v)(i)) to fentanyl rate.
    # Annex II (Note 2(v)(iii)) lists only reciprocal-related ch99 codes
    # and does NOT extend to fentanyl (9903.01.01-.24); the broader Annex II
    # list must therefore not be applied to rate_ieepa_fent. But the Ch98
    # carve-out under (v)(i) IS legally separate and does cover fentanyl.
    # The 4 Ch98 exceptions (9802.00.40/50/60/80) are already excluded
    # from ieepa_exempt_products.csv by expand_ieepa_exempt.R Fix 2.
    ch98_exempt_products <- ieepa_exempt_products[
      substr(ieepa_exempt_products, 1, 2) == '98']
    if (length(ch98_exempt_products) > 0) {
      ch98_mask <- rates$hts10 %in% ch98_exempt_products
      n_zeroed <- sum(ch98_mask & rates$rate_ieepa_fent > 0)
      if (n_zeroed > 0) {
        rates$rate_ieepa_fent[ch98_mask] <- 0
        message('  Ch98 fentanyl exemption: zeroed rate_ieepa_fent for ',
                n_zeroed, ' product-country pairs')
      }
    }

    n_with_fent <- sum(rates$rate_ieepa_fent > 0)
    message('  With IEEPA fentanyl: ', n_with_fent)
  } else {
    rates <- rates %>% mutate(rate_ieepa_fent = coalesce(rate_ieepa_fent, 0))
  }

  # 4. Apply Section 232 base tariff (blanket, chapter/heading)
  #    232 is defined by US Notes, not via product footnotes.
  #    Steel: chapters 72-73 (US Note 16, 9903.80-84)
  #    Aluminum: chapter 76 (US Note 19, 9903.85)
  #    Autos: heading 8703 + specific subheadings (US Note 25, 9903.94)
  #    Copper: specific headings in chapter 74
  # Load heading programs from AuthoritySpec.
  s232_headings <- s232_heading_configs(specs)
  if (!length(s232_headings) && isTRUE(specs[['section_232']]$active$enabled)) {
    stop('Section 232 heading programs are missing from AuthoritySpec. They drive all ',
         'non-chapter 232 programs (autos, copper, MHD, wood, semiconductors). ',
         'See config/policy_params.yaml.')
  }

  # Step 7 (USMCA, ~line 3096/3147) reads this unconditionally; without 232
  # rates no product is a content-scaled 232 vehicle, so the empty set is the
  # correct value — not just a crash guard.
  usmca_vehicle_products <- character(0)
  steel_products <- character(0)
  aluminum_products <- character(0)
  auto_products <- character(0)
  copper_products <- character(0)
  wood_products <- character(0)
  mhd_products <- character(0)
  semi_products <- character(0)
  pharma_products <- character(0)
  metal_program_products <- character(0)
  s232_country_codes <- character(0)
  heading_gates <- lapply(s232_headings, function(cfg) isTRUE(cfg$enabled))
  heading_product_rate <- tibble(
    hts10 = character(), heading_232_rate = numeric(),
    heading_usmca_exempt = logical()
  )

  if (isTRUE(specs[['section_232']]$active$enabled)) {
    # --- Identify covered products by prefix matching ---
    # Steel/aluminum membership within chapters 72/73/76 is ENUMERATED by the
    # chapter-99 US notes, not blanket: pig iron (7201), ferroalloys (7202),
    # scrap (7204/7602), cast-iron tubes (7303) and the 7216.61/.69/.91
    # angle subheadings are on no product list in any revision, and CBP
    # collections show ~0% on them while listed headings collect near the
    # full rate (eval residual deep-dive 2026-06-12 item 2). Membership is
    # date-gated (2018 article lists -> Proc 10895/10896 derivative
    # expansion 2025-03-12 -> BIS inclusions 2025-08-18). Annex-era
    # revisions read the in-chapter scope from the annex classification
    # instead (same source step 5c rates from), restricted to the charging
    # tiers — without this, products the annex never enumerates would keep
    # phantom blanket rates (annex_2 'removed' lines are rated 0 by step 5c
    # so they are excluded here too).
    annex_cfg_scope <- specs[['section_232']]$annex$config
    in_annex_era <- !is.null(annex_cfg_scope)
    if (in_annex_era) {
      annex_res <- annex_cfg_scope$resource_file %||%
        file.path('resources', 's232_annex_products.csv')
      annex_path <- if (grepl('^(/|[A-Za-z]:)', annex_res)) annex_res else here(annex_res)
      annex_scope <- load_annex_products(effective_date, annex_path) %>%
        filter(s232_annex %in% c('annex_1a', 'annex_1b', 'annex_1c', 'annex_3'))
      steel_scope_prefixes <- annex_scope$hts_prefix[
        substr(annex_scope$hts_prefix, 1, 2) %in% STEEL_CHAPTERS]
      alum_scope_prefixes <- annex_scope$hts_prefix[
        substr(annex_scope$hts_prefix, 1, 2) %in% ALUM_CHAPTERS]
    } else {
      metal_scope <- load_232_metal_chapter_products(effective_date = effective_date)
      if (is.null(metal_scope) || nrow(metal_scope) == 0) {
        stop('resources/s232_metal_chapter_products.csv is missing or empty. ',
             'Steel/aluminum 232 product scope is enumerated by the chapter-99 ',
             'US notes; refusing to fall back to blanket chapter coverage ',
             '(it over-applies the metals rate to pig iron/ferroalloys/scrap).')
      }
      steel_scope_prefixes <- metal_scope$hts_prefix[metal_scope$metal_type == 'steel']
      alum_scope_prefixes  <- metal_scope$hts_prefix[metal_scope$metal_type == 'aluminum']
    }
    match_scope <- function(prefixes) {
      if (length(prefixes) == 0) return(character(0))
      pattern <- paste0('^(', paste(prefixes, collapse = '|'), ')')
      products %>% filter(grepl(pattern, hts10)) %>% pull(hts10)
    }
    steel_products <- match_scope(steel_scope_prefixes)
    aluminum_products <- match_scope(alum_scope_prefixes)

    # Heading-level: autos, copper, etc.
    auto_products <- character(0)
    copper_products <- character(0)
    wood_products <- character(0)
    mhd_products <- character(0)
    semi_products <- character(0)
    pharma_products <- character(0)
    # Parts (auto_parts + mhd_parts) tracked separately from whole vehicles.
    # USMCA-qualifying PARTS are fully exempt from 232 (HTS 9903.94.06 for auto
    # parts; Proclamation 10984 for MHD parts) until Commerce stands up a
    # non-US-content process for parts — which did not exist in the data window.
    # Whole VEHICLES are dutied on non-US content only (us_auto_content_share).
    # So parts must NOT be content-scaled; see the USMCA application step below.
    parts_products <- character(0)
    heading_product_lists <- list()
    # Fractional applicability shares accumulated in the heading loop; applied
    # to heading_232_rate after heading_product_rate is built (see below).
    applicability_scale <- tibble(hts10 = character(), applic_share = numeric())
    # Products excluded by applicability_share = 0, with the rate the literal
    # enumeration would have charged. Their EFFECTIVE treatment is non-232
    # (no heading rate; normal IEEPA/fentanyl stacking), but step 7d writes
    # the literal rate into statutory_rate_232 so the statutory-vs-collected
    # wedge on these lines stays measurable downstream (tariff-etr-eval)
    # rather than being baked into the model.
    applicability_excluded <- tibble(hts10 = character(), literal_rate = numeric())

    if (!is.null(s232_headings)) {
      # Gate each heading config on whether its Ch99 program exists in this revision.
      # Programs added progressively: assembled autos at rev_6, parts at rev_11,
      # copper at rev_17, MHD/wood later. Check extracted rates + specific Ch99 codes.
      # Phase 2c: heading activation comes from the spec when it drives the calc
      # (the adapter precomputes it via compute_heading_gates() with the same
      # date-gated ch99 + authoritative s232 value), else compute inline. One
      # source ⇒ byte-identical baseline.
      # A heading configured in policy_params.yaml without a registered gate is
      # rejected in the adapter (build_authority_specs), which is the single
      # point where yaml config becomes spec programs — see the unregistered-
      # heading stop next to its compute_heading_gates() call.

      for (tariff_name in names(s232_headings)) {
        # Check if this heading's Ch99 program is active in this revision
        gate_val <- heading_gates[[tariff_name]]
        if (!gate_val) {
          message('  Skipping 232 heading "', tariff_name, '" — Ch99 entries not in this revision')
          next
        }

        cfg <- s232_headings[[tariff_name]]
        matched <- match_232_heading_products(cfg, products, tariff_name, verbose = TRUE)

        # Optional per-prefix applicability shares. Enumerated lists like Note
        # 33(g) can name dual-use provisions (notably bare heading 8471) whose
        # trade is mostly NOT "parts of passenger vehicles ... and light
        # trucks" — the operative scope of the duty. applicability_share
        # approximates the fraction of each prefix's imports that fall in
        # scope: share = 0 prefixes are excluded from the heading outright;
        # fractional shares scale the product's heading rate after
        # heading_product_rate is built (same blending pattern as the semi
        # qualifying_share).
        if (!is.null(cfg$applicability_shares_file)) {
          ap_path <- here(cfg$applicability_shares_file)
          if (file.exists(ap_path)) {
            ap <- suppressMessages(read_csv(
              ap_path, comment = '#',
              col_types = cols(hts_prefix = col_character(),
                               applicability_share = col_double(),
                               .default = col_character())
            ))
            # Longest-prefix match: each matched product takes the share of
            # the most specific matching prefix; unmatched products keep 1.0.
            share_for <- rep(NA_real_, length(matched))
            for (k in order(nchar(ap$hts_prefix), decreasing = TRUE)) {
              hit <- is.na(share_for) & startsWith(matched, ap$hts_prefix[k])
              share_for[hit] <- ap$applicability_share[k]
            }
            share_for[is.na(share_for)] <- 1
            if (any(share_for == 0)) {
              message('  ', tariff_name, ': excluded ', sum(share_for == 0),
                      ' products with applicability_share = 0',
                      ' (literal rate preserved in statutory_rate_232)')
              applicability_excluded <- bind_rows(
                applicability_excluded,
                tibble(
                  hts10 = matched[share_for == 0],
                  literal_rate = resolve_heading_rate(tariff_name, cfg)
                )
              )
            }
            is_frac <- share_for > 0 & share_for < 1
            if (any(is_frac)) {
              applicability_scale <- bind_rows(
                applicability_scale,
                tibble(hts10 = matched[is_frac], applic_share = share_for[is_frac])
              )
            }
            matched <- matched[share_for > 0]
          } else stop(tariff_name, ' applicability_shares_file not found: ', ap_path)
        }

        heading_product_lists[[tariff_name]] <- list(
          products = matched,
          rate = resolve_heading_rate(tariff_name, cfg),
          usmca_exempt = cfg$usmca_exempt %||% FALSE
        )

        if (grepl('auto|passenger|light_truck|auto_parts', tariff_name, ignore.case = TRUE)) {
          auto_products <- c(auto_products, matched)
        } else if (grepl('copper', tariff_name, ignore.case = TRUE)) {
          copper_products <- c(copper_products, matched)
        } else if (grepl('softwood|furniture|cabinet', tariff_name, ignore.case = TRUE)) {
          wood_products <- c(wood_products, matched)
        } else if (grepl('mhd|bus|mhd_parts', tariff_name, ignore.case = TRUE)) {
          mhd_products <- c(mhd_products, matched)
        } else if (grepl('semi', tariff_name, ignore.case = TRUE)) {
          semi_products <- c(semi_products, matched)
        } else if (grepl('pharma', tariff_name, ignore.case = TRUE)) {
          pharma_products <- c(pharma_products, matched)
        }

        # Parts accumulator (non-exclusive): auto_parts also lands in
        # auto_products and mhd_parts in mhd_products above; we additionally
        # tag them as parts so the USMCA step can exempt them fully rather than
        # content-scale them like whole vehicles.
        if (grepl('parts', tariff_name, ignore.case = TRUE)) {
          parts_products <- c(parts_products, matched)
        }
      }
    }
    auto_products <- unique(auto_products)
    copper_products <- unique(copper_products)
    wood_products <- unique(wood_products)
    mhd_products <- unique(mhd_products)
    semi_products <- unique(semi_products)
    pharma_products <- unique(pharma_products)
    parts_products <- unique(parts_products)

    # Note 39(a)(1)-(9) excludes semi articles from stacking with 232 autos,
    # auto parts, MHD, MHD parts, copper, aluminum, and steel. The auto_parts
    # HTS list (per US Note 33(g)) includes heading 8471 at the 4-digit level,
    # which overlaps with Note 39(b) scope (8471.50, 8471.80, 8473.30). Strip
    # semi products from non-semi heading lists so only the 25% semi rate
    # applies, and so auto_rebate doesn't inappropriately reduce semi rates.
    if (length(semi_products) > 0) {
      auto_products <- setdiff(auto_products, semi_products)
      copper_products <- setdiff(copper_products, semi_products)
      wood_products <- setdiff(wood_products, semi_products)
      mhd_products <- setdiff(mhd_products, semi_products)
      for (nm in setdiff(names(heading_product_lists), 'semiconductors')) {
        heading_product_lists[[nm]]$products <- setdiff(
          heading_product_lists[[nm]]$products,
          semi_products
        )
      }
    }

    # Exclude steel/aluminum-program products from heading lists — a Ch73 steel
    # spring that matches auto_parts prefixes is still a steel product (gets the
    # metals 232 rate, not auto rebate/USMCA auto content share). Membership is
    # the note-derived scope above, NOT chapter membership: a ch72/73/76 line
    # outside the metals scope that matches a heading prefix legitimately takes
    # the heading program.
    metal_program_products <- c(steel_products, aluminum_products)
    n_auto_pre <- length(auto_products)
    auto_products <- auto_products[!auto_products %in% metal_program_products]
    if (length(auto_products) < n_auto_pre) {
      message('  Excluded ', n_auto_pre - length(auto_products),
              ' steel/aluminum-program products from auto_products')
    }
    # Same exclusion for MHD parts: a Ch72/73/76 steel/aluminum line that matches
    # an MHD-parts prefix (e.g. 7320.x automotive springs) is still a metal
    # product and must take the standard steel/aluminum annex rate, not the MHD
    # heading rate. Without this strip such lines survive in
    # heading_program_products and the annex override (below) preserves their
    # prior 232 rate instead of applying the annex_1a/1b rate.
    n_mhd_pre <- length(mhd_products)
    mhd_products <- mhd_products[!mhd_products %in% metal_program_products]
    if (length(mhd_products) < n_mhd_pre) {
      message('  Excluded ', n_mhd_pre - length(mhd_products),
              ' steel/aluminum-program products from mhd_products')
    }

    # Keep parts_products a clean subset of the surviving auto/MHD lines (after
    # the semi-strip and blanket-chapter exclusions above), then split whole
    # vehicles from parts. Only whole vehicles are content-scaled by
    # us_auto_content_share in the USMCA step; parts get the full exemption.
    # NB: distinct from the loop-local `vehicle_products` in the auto-deal block
    # below (passenger/light-truck only) — this set also includes MHD vehicles.
    parts_products <- intersect(parts_products, c(auto_products, mhd_products))
    usmca_vehicle_products <- setdiff(c(auto_products, mhd_products), parts_products)

    n_steel <- length(steel_products)
    n_alum <- length(aluminum_products)
    n_auto <- length(auto_products)
    n_copper <- length(copper_products)
    n_wood <- length(wood_products)
    n_mhd <- length(mhd_products)
    n_semi <- length(semi_products)
    message('  Section 232 coverage: ', n_steel, ' steel + ', n_alum,
            ' aluminum + ', n_auto, ' auto + ', n_copper, ' copper + ',
            n_wood, ' wood + ', n_mhd, ' MHD + ', n_semi, ' semi products')

    # --- Build product-level 232 rate lookup from heading configs ---
    # Each heading config specifies its own rate. Build an hts10 -> rate mapping.
    heading_product_rate <- map_dfr(names(heading_product_lists), function(nm) {
      cfg <- heading_product_lists[[nm]]
      if (length(cfg$products) == 0) return(tibble())
      tibble(
        hts10 = cfg$products,
        heading_232_rate = cfg$rate,
        heading_usmca_exempt = isTRUE(cfg$usmca_exempt)
      )
    })
    # If a product appears in multiple heading tariffs, take the max rate
    if (nrow(heading_product_rate) > 0) {
      heading_product_rate <- heading_product_rate %>%
        group_by(hts10) %>%
        summarise(
          heading_232_rate = max(heading_232_rate),
          heading_usmca_exempt = any(heading_usmca_exempt),
          .groups = 'drop'
        )
    }

    # --- Semi per-HTS10 qualifying_share and end-use blending (Note 39(b), (d)) ---
    # Note 39(b) scopes semi articles via three HTS headings plus a per-article
    # TPP/DRAM tech gate; qualifying_share approximates the fraction of each
    # HTS10's imports meeting the gate. Note 39(d) enumerates end-use carve-outs
    # (9903.79.03-.09) that can't be HTS-scoped; end_use_exemption_share
    # approximates the dutied fraction. Both default to uncalibrated upper
    # bounds (qualifying_share = 1.0, end_use_exemption_share = 0).
    if (length(semi_products) > 0 && nrow(heading_product_rate) > 0 &&
        !is.null(s232_headings) && !is.null(s232_headings$semiconductors)) {
      semi_cfg <- s232_headings$semiconductors
      end_use_share <- semi_cfg$end_use_exemption_share %||% 0

      qs_data <- tibble(hts10 = character(), qualifying_share = numeric())
      qs_path <- semi_cfg$qualifying_shares_file %||% ''
      if (nchar(qs_path) > 0) {
        qs_full <- here(qs_path)
        if (file.exists(qs_full)) {
          qs_data <- suppressMessages(
            read_csv(qs_full, col_types = cols(
              hts10 = col_character(),
              qualifying_share = col_double()
            ))
          ) %>% select(hts10, qualifying_share)
        } else stop('semi qualifying_shares_file not found: ', qs_full)
      }

      heading_product_rate <- heading_product_rate %>%
        left_join(qs_data, by = 'hts10', relationship = 'many-to-one') %>%
        mutate(
          heading_232_rate = if_else(
            hts10 %in% semi_products,
            heading_232_rate * coalesce(qualifying_share, 1.0) * (1 - end_use_share),
            heading_232_rate
          )
        ) %>%
        select(-qualifying_share)

      message('  Semi scaling: ', nrow(qs_data), ' per-HTS10 shares loaded; ',
              'end_use_exemption_share = ', end_use_share)
    }

    # --- Apply fractional applicability shares (collected in heading loop) ---
    # share = 0 products were already excluded at match time; 0 < share < 1
    # products stay in the heading but at a scaled rate.
    if (nrow(applicability_scale) > 0 && nrow(heading_product_rate) > 0) {
      applicability_scale <- distinct(applicability_scale, hts10, .keep_all = TRUE)
      heading_product_rate <- heading_product_rate %>%
        left_join(applicability_scale, by = 'hts10', relationship = 'many-to-one') %>%
        mutate(heading_232_rate = heading_232_rate * coalesce(applic_share, 1.0)) %>%
        select(-applic_share)
      message('  Applicability scaling: ', nrow(applicability_scale),
              ' products at fractional shares')
    }

    # --- Build per-country rate lookup ---
    # Steel/aluminum defaults and per-country overrides are explicit program layers.
    steel_rate_vec    <- s232_blanket_metal_rate(specs, countries, 'steel')
    aluminum_rate_vec <- s232_blanket_metal_rate(specs, countries, 'aluminum')
    country_232 <- tibble(country = countries) %>%
      mutate(
        steel_rate    = steel_rate_vec,
        aluminum_rate = aluminum_rate_vec
      )

    n_steel_countries <- sum(country_232$steel_rate > 0)
    n_alum_countries <- sum(country_232$aluminum_rate > 0)
    message('  Steel: ', n_steel_countries, ' countries, aluminum: ', n_alum_countries)

    # --- Update rate_232 for products already in rates ---
    # Join heading-level rates for auto/copper/etc products
    if (nrow(heading_product_rate) > 0) {
      rates <- rates %>%
        left_join(heading_product_rate, by = 'hts10', relationship = 'many-to-one')
    } else {
      rates$heading_232_rate <- 0
      rates$heading_usmca_exempt <- FALSE
    }

    rates <- rates %>%
      left_join(
        country_232 %>% select(country, steel_rate_232 = steel_rate,
                               alum_rate_232 = aluminum_rate),
        by = 'country',
        relationship = 'many-to-one'
      ) %>%
      mutate(
        # Heading-level 232 rate (auto/MHD/copper/wood). USMCA share-based
        # reduction for CA/MX applied later in step 7, not zeroed here.
        heading_rate_adj = case_when(
          is.na(heading_232_rate) | heading_232_rate == 0 ~ 0,
          TRUE ~ heading_232_rate
        ),
        blanket_232 = case_when(
          hts10 %in% steel_products ~ coalesce(steel_rate_232, 0),
          hts10 %in% aluminum_products ~ coalesce(alum_rate_232, 0),
          heading_rate_adj > 0 ~ heading_rate_adj,
          TRUE ~ 0
        ),
        rate_232 = pmax(rate_232, blanket_232),
        # Track which products have USMCA-eligible 232 headings (for step 7).
        # Only when the heading rate is actually used — steel/aluminum-program
        # products get their rate from the metals program, not the heading,
        # so they should NOT inherit the heading's USMCA eligibility.
        s232_usmca_eligible = coalesce(heading_usmca_exempt, FALSE) & heading_rate_adj > 0 &
          !(hts10 %in% metal_program_products)
      ) %>%
      select(-steel_rate_232, -alum_rate_232, -blanket_232,
             -heading_232_rate, -heading_usmca_exempt, -heading_rate_adj)

    rates <- apply_pharma_232_adjustments(
      rates, pharma_products,
      s232_headings$pharmaceuticals,
      countries, pp
    )
  }

  # statutory_rate_232 is set after step 4c (deal overrides) — see below.

  # 4b. Apply Section 232 auto rebate
  #     Reduces effective 232 rate on auto/vehicle products by a credit reflecting
  #     US assembly content: effective_rate -= rebate_rate * us_assembly_share.
  #     Applied before metal content scaling (step 5) and before USMCA (step 7).
  #     All three keys are required — fail closed rather than silently default to
  #     values that would quietly over- or under-state auto ETRs (a missing
  #     us_auto_content_share previously defaulted to 1.0, producing a ~4.7pp
  #     over-exemption of CA/MX autos relative to Tariff-ETRs).
  auto_rebate_cfg <- pp$auto_rebate
  if (is.null(auto_rebate_cfg)) {
    stop('policy_params$auto_rebate is missing. Required keys: rebate_rate, ',
         'us_assembly_share, us_auto_content_share. See config/policy_params.yaml. ',
         'To disable the rebate entirely set rebate_rate=0 and us_assembly_share=0; ',
         'to disable the USMCA auto-content scaling set us_auto_content_share=1.')
  }
  required_keys <- c('rebate_rate', 'us_assembly_share', 'us_auto_content_share')
  missing_keys <- setdiff(required_keys, names(auto_rebate_cfg))
  if (length(missing_keys) > 0) {
    stop('policy_params$auto_rebate is missing required keys: ',
         paste(missing_keys, collapse = ', '),
         '. See config/policy_params.yaml.')
  }
  rebate_rate <- auto_rebate_cfg$rebate_rate
  assembly_share <- auto_rebate_cfg$us_assembly_share
  us_auto_content_share <- auto_rebate_cfg$us_auto_content_share
  rebate_deduction <- rebate_rate * assembly_share

  if (rebate_deduction > 0 && length(auto_products) > 0) {
    rates <- rates %>%
      mutate(
        rate_232 = if_else(
          hts10 %in% auto_products & rate_232 > 0,
          pmax(rate_232 - rebate_deduction, 0),
          rate_232
        )
      )
    n_rebated <- sum(rates$hts10 %in% auto_products & rates$rate_232 > 0)
    message('  Auto rebate: -', round(rebate_deduction * 100, 2),
            'pp on ', n_rebated, ' auto product-country pairs',
            if (us_auto_content_share < 1) paste0(
              '; USMCA content share: ', us_auto_content_share * 100, '%') else '')
  }

  # 4c. Apply country-specific 232 deal rates (floor/surcharge)
  #     Auto deals: EU/Japan/Korea get 15% floor on vehicles; UK gets +7.5% surcharge.
  #     Wood deals: UK 10% floor on softwood, EU/Japan/Korea 15% floor on furniture/cabinets.
  #     Floor mechanism: effective_232 = max(floor_rate - base_rate, 0)
  #     Surcharge mechanism: effective_232 = surcharge_rate (flat)
  #     These override the blanket 232 rate set in step 4 for deal countries.
  n_deal_overrides <- 0L

  # Apply auto deal rates
  # Plank 4a / S2 (deals): records from the spec (rate$overrides scope-form + rate$floors);
  # countries are PRE-CENSUS-EXPANDED by the adapter.
  auto_deals <- s232_deal_records(specs, 'autos_source')
  if (length(auto_deals) > 0 && length(auto_products) > 0) {
    for (i in seq_along(auto_deals)) {
      deal <- auto_deals[[i]]
      census_codes <- deal$countries          # already census; EU already 27
      if (length(census_codes) == 0) next

      # Determine which products this deal covers (vehicles vs parts).
      # Use heading_product_lists (populated via match_232_heading_products())
      # rather than re-parsing cfg$prefixes. The heading-list path is stable if
      # autos_passenger / autos_light_trucks ever move from inline `prefixes:`
      # to `products_file:` — the old cfg$prefixes path would silently become
      # empty under that migration and the vehicles-branch fallback used to
      # return all auto_products, misapplying a vehicle-only deal to parts.
      vehicle_heading_names <- grep('passenger|light_truck',
                                     names(heading_product_lists),
                                     ignore.case = TRUE, value = TRUE)
      vehicle_products <- unique(unlist(lapply(
        vehicle_heading_names,
        function(nm) heading_product_lists[[nm]]$products
      )))
      deal_products <- if (deal$scope == 'auto_parts') {
        # Parts: auto_products not in the vehicle set. Empty vehicle_products
        # (no autos_passenger/light_truck headings active in this revision)
        # collapses to auto_products, which is the correct parts-only scope.
        setdiff(auto_products, vehicle_products)
      } else {
        # Vehicles: exactly the vehicle headings' products. If vehicle_products
        # is empty the deal is a no-op rather than silently applying to all
        # auto_products.
        vehicle_products
      }

      if (deal$rate_type == 'floor') {
        # Floor deals are MFN-INCLUSIVE totals ("15%", no '+', sets forth the
        # ordinary customs duty treatment): total duty must land on deal$rate.
        # Tag the floor target so step 6f can recompute against the post-FTA
        # base_rate — the MFN-exemption scaling (step 6c) shrinks base_rate
        # AFTER this step (KORUS autos: 2.5% statutory -> ~0.06% effective),
        # and without the recompute the total lands at deal − statutory_base +
        # effective_base (Korea autos 12.56% vs CBP's steady 15.0% collected;
        # eval residual deep-dive 2026-06-12 item 6).
        if (!'s232_deal_floor' %in% names(rates)) {
          rates$s232_deal_floor <- NA_real_
        }
        rates <- rates %>%
          mutate(
            .hit = hts10 %in% deal_products & country %in% census_codes,
            rate_232 = if_else(.hit, pmax(deal$rate - base_rate, 0), rate_232),
            s232_deal_floor = if_else(.hit, deal$rate, s232_deal_floor)
          ) %>%
          select(-.hit)
      } else {
        # surcharge: flat additional rate
        rates <- rates %>%
          mutate(
            rate_232 = if_else(
              hts10 %in% deal_products & country %in% census_codes,
              deal$rate,
              rate_232
            )
          )
      }
      n_affected <- sum(rates$hts10 %in% deal_products & rates$country %in% census_codes)
      n_deal_overrides <- n_deal_overrides + n_affected
    }
  }

  # Apply wood deal rates
  # Identify wood product sets by heading config
  wood_softwood_products <- character(0)
  wood_furn_products <- character(0)
  if (!is.null(s232_headings)) {
    for (nm in names(s232_headings)) {
      cfg <- s232_headings[[nm]]
      prefixes <- unlist(cfg$prefixes)
      if (length(prefixes) == 0) next
      pattern <- paste0('^(', paste(prefixes, collapse = '|'), ')')
      matched <- products %>% filter(grepl(pattern, hts10)) %>% pull(hts10)
      if (grepl('softwood', nm, ignore.case = TRUE)) {
        wood_softwood_products <- c(wood_softwood_products, matched)
      } else if (grepl('furniture|cabinet', nm, ignore.case = TRUE)) {
        wood_furn_products <- c(wood_furn_products, matched)
      }
    }
  }
  all_wood_products <- unique(c(wood_softwood_products, wood_furn_products))

  wood_deals <- s232_deal_records(specs, 'wood_source')
  if (length(wood_deals) > 0 && length(all_wood_products) > 0) {
    for (i in seq_along(wood_deals)) {
      deal <- wood_deals[[i]]
      census_codes <- deal$countries
      if (length(census_codes) == 0) next

      # Wood deals apply to all wood products (softwood + furniture/cabinets)
      if (deal$rate_type == 'floor') {
        # Same MFN-inclusive floor semantics as auto deals: tag for the step-6f
        # recompute against the post-FTA base_rate.
        if (!'s232_deal_floor' %in% names(rates)) {
          rates$s232_deal_floor <- NA_real_
        }
        rates <- rates %>%
          mutate(
            .hit = hts10 %in% all_wood_products & country %in% census_codes,
            rate_232 = if_else(.hit, pmax(deal$rate - base_rate, 0), rate_232),
            s232_deal_floor = if_else(.hit, deal$rate, s232_deal_floor)
          ) %>%
          select(-.hit)
      } else {
        rates <- rates %>%
          mutate(
            rate_232 = if_else(
              hts10 %in% all_wood_products & country %in% census_codes,
              deal$rate,
              rate_232
            )
          )
      }
      n_affected <- sum(rates$hts10 %in% all_wood_products & rates$country %in% census_codes)
      n_deal_overrides <- n_deal_overrides + n_affected
    }
  }

  if (n_deal_overrides > 0) {
    message('  232 deal rates (floor/surcharge): ', n_deal_overrides,
            ' product-country pairs overridden')
  }

  # Save post-deal, post-rebate statutory 232 rates for CSV export.
  # After deal overrides (step 4c), rate_232 reflects the effective rate including
  # floor/surcharge adjustments and auto rebate. The generated other_params.yaml
  # sets auto_rebate_rate = 0 so ETRs does not re-apply the rebate.
  # Derivatives (set in step 5) update this column for their products.
  rates <- rates %>%
    mutate(statutory_rate_232 = rate_232)

  # 5. Apply Section 232 derivative tariff + metal content scaling
  #    Aluminum derivatives (9903.85.04/.07/.08) and steel derivatives (9903.81.89-93)
  #    are metal-containing articles outside primary chapters. Tariff applies to
  #    metal content only; per-type scaling uses steel_share or aluminum_share.
  # Build heading product list from prefixes of ACTIVE headings only.
  # Products matching active heading prefixes are non-metal 232 programs
  # and should NOT be metal-scaled even if they also match derivative prefixes.
  # Inactive headings' products should be treated as pure derivatives.
  all_heading_hts10 <- character(0)
  if (!is.null(s232_headings)) {
    for (nm in names(s232_headings)) {
      # Skip inactive headings — their products are pure derivatives.
      gate_val <- heading_gates[[nm]]
      if (!isTRUE(gate_val)) next
      cfg <- s232_headings[[nm]]
      # verbose = FALSE because step 4 already logged this heading's match count
      matched <- match_232_heading_products(cfg, products, nm, verbose = FALSE)
      all_heading_hts10 <- c(all_heading_hts10, matched)
    }
    all_heading_hts10 <- unique(all_heading_hts10)
  }
  # Load derivative products once — used by apply_232_derivatives (step 5) and
  # again by the annex classification fallback in step 5c. Previously each
  # caller re-read and re-filtered the CSV on its own.
  deriv_products <- load_232_derivative_products(effective_date = effective_date)

  result <- apply_232_derivatives(rates, products, specs, countries,
                                   heading_products = all_heading_hts10,
                                   policy_params = pp,
                                   effective_date = effective_date,
                                   deriv_products = deriv_products)
  rates <- result$rates
  deriv_matched <- result$deriv_matched


  # 5b. Scale copper heading products by copper content share.
  #     The copper proclamation applies the tariff "upon the value of the copper
  #     content," not the full customs value. This parallels ETRs' per-type metal
  #     scaling. After scaling, is_copper_heading flags these products so stacking
  #     rules use copper_share for nonmetal_share.
  if (length(copper_products) > 0 && 'copper_share' %in% names(rates)) {
    rates <- rates %>%
      mutate(
        is_copper_heading = hts10 %in% copper_products,
        rate_232 = if_else(
          is_copper_heading & rate_232 > 0,
          rate_232 * copper_share,
          rate_232
        ),
        statutory_rate_232 = if_else(
          is_copper_heading & statutory_rate_232 > 0,
          statutory_rate_232 * copper_share,
          statutory_rate_232
        )
      )
    n_scaled <- sum(rates$is_copper_heading & rates$rate_232 > 0)
    message('  Copper heading metal scaling: ', n_scaled, ' product-country pairs')
  } else {
    rates$is_copper_heading <- FALSE
  }

  # 5c. Section 232 annex rate override (April 2026 proclamation)
  #     Date-gated: only applies to revisions on/after the annex effective date.
  #     Overrides single-rate 232 with per-annex rates after the old pipeline has
  #     finished assigning rates. Annex classification comes from the static
  #     resource file (resources/s232_annex_products.csv). Annex-era revisions
  #     fail closed if the mapping is missing or empty.
  annex_cfg <- specs[['section_232']]$annex$config
  if (!is.null(annex_cfg)) {
    # Plank 4c (Slice 2a): the §232 annex per-product facts are READ off the spec.
    # The adapter classified the product universe ONCE (classify_s232_annex) and
    # parked a coherent `annex` structure on section_232: $tier (the s232_annex tag),
    # $flat_rate (tiers 1a/1b/2 -> 0.50/0.25/0), $floor_rate (tier-3 floor scalar).
    # No in-calc classification, no config fallback — an annex-era revision REQUIRES
    # its spec annex structure (the inner else stops loudly if it is absent).
    ann <- specs[['section_232']]$annex
    if (!is.null(ann)) {
      # s232_annex tag + per-product flat annex rate (tiers 1a/1b/2): read off the
      # spec. annex_flat is NA where there is no flat rate (tier 3 / unclassified /
      # non-annex) — those fall to the annex_3 floor arm or keep their existing rate.
      rates$s232_annex <- unname(ann$tier[as.character(rates$hts10)])
      annex_flat <- unname(ann$flat_rate[as.character(rates$hts10)])

      # Override rate_232 by annex
      #
      # Important scoping: the April 2026 proclamation governs Section 232
      # *steel / aluminum / copper* tariffs only — Annex II's "removed from
      # scope" language reads "will not be subject to Section 232 aluminum,
      # steel or copper tariffs" (annexes_text.txt:515). The auto-specific
      # Section 232 (9903.94), MHD (9903.74), wood (9903.76), and
      # semiconductor (9903.79) authorities are separate and unaffected.
      #
      # The static annex CSV faithfully lists what the proclamation covers
      # — 8703 / 8704 (passenger cars / light trucks), 8708 (auto parts),
      # 8702 (buses), 8701 (tractors), etc. all appear in Annexes I-B and II
      # because the proclamation does remove them from the *metal-derivative*
      # tariff. But those same products carry separate heading-program rates
      # set in step 4 / 4c (auto blanket + EU/JP/KR floors, MHD blanket,
      # copper deal, etc.). Without this guard the annex override would
      # silently wipe heading-program rates: e.g. EU passenger cars under
      # 9903.94.51 should pay max(0.15 - base, 0) ≈ 12.5pp on top of MFN, but
      # the annex_2 catch-all `8703,2` was setting rate_232 = 0.
      heading_program_products <- unique(c(auto_products, mhd_products,
                                           copper_products, wood_products,
                                           semi_products))
      rates <- rates %>%
        mutate(rate_232 = case_when(
          hts10 %in% heading_program_products ~ rate_232,             # heading rate wins
          !is.na(annex_flat) ~ annex_flat,                            # tiers 1a/1b/2 from the spec
          s232_annex == 'annex_3' ~ apply_rate_semantics(ann$floor_rate, 'floor_post_mfn', base_rate),  # tier-3 floor vs base
          TRUE ~ rate_232
        ))

      # Proclamation 11032 Annex I-C (effective 2026-06-08 through 2027-12-31):
      # mobile industrial equipment defaults to 25%, with lower 15% framework
      # treatment and a dormant aggregate U.S.-metal 10% route. Canada/Mexico
      # USMCA steel treatment is share-blended later in the USMCA step because it
      # needs product-level USMCA utilization shares.
      ann1c_cfg <- annex_cfg$annexes$annex_1c
      if (!is.null(ann1c_cfg) && as.Date(effective_date) >= as.Date(ann1c_cfg$effective_date %||% '9999-12-31')) {
        fw_countries <- as.character(unlist(ann1c_cfg$framework_countries %||% character(0)))
        if ('eu' %in% fw_countries) {
          fw_countries <- unique(c(setdiff(fw_countries, 'eu'), pp$EU27_CODES %||% character(0)))
        }
        fw_floor <- as.numeric(ann1c_cfg$framework_floor_rate %||% 0.15)
        usm_cfg <- annex_cfg$exemptions$us_origin_metal
        usm_share <- as.numeric(usm_cfg$aggregate_share %||% 0)
        usm_floor <- as.numeric(usm_cfg$rate %||% 0.10)
        rates <- rates %>%
          mutate(
            .ann1c_framework_rate = apply_rate_semantics(fw_floor, 'floor_post_mfn', base_rate),
            # NA-safe gate: s232_annex is NA on non-annex products, and a bare
            # `s232_annex == 'annex_1c'` yields NA (not FALSE) there — which, AND-ed
            # with a framework-country match, makes if_else() return NA rate_232 for
            # EVERY non-annex product of a framework country. That NA then poisons
            # stacking (total_additional -> NA) and enforce_rate_schema silently
            # coalesces it to 0, wiping §122/base. Guard with !is.na (mirrors the
            # sibling floor-recompute block below).
            rate_232 = if_else(
              !is.na(s232_annex) & s232_annex == 'annex_1c' & country %in% fw_countries,
              pmin(rate_232, .ann1c_framework_rate),
              rate_232
            ),
            .ann1c_usmetal_rate = apply_rate_semantics(usm_floor, 'floor_post_mfn', base_rate),
            rate_232 = if_else(
              !is.na(s232_annex) & s232_annex == 'annex_1c' & !is.na(usm_share) & usm_share > 0,
              usm_share * pmin(rate_232, .ann1c_usmetal_rate) + (1 - usm_share) * rate_232,
              rate_232
            )
          ) %>%
          select(-.ann1c_framework_rate, -.ann1c_usmetal_rate)
      }

      # Record heading-program membership (the exact set the override above keys
      # on) so downstream consumers and tests can distinguish a legitimately
      # preserved heading-program rate on annex_2 from an actual leak, without
      # re-deriving the auto/MHD/copper/wood/semi product lists. (The annex_1c
      # block above only adjusts rate_232; it does not change set membership.)
      rates$heading_program <- rates$hts10 %in% heading_program_products

      # 9903.82.01 zero-metal-content carve-out (Note 16(a)):
      # Articles classified in subdivision (c) lists that do not contain any
      # aluminum, steel, or copper get "No change" — 0% additional 232 duty.
      # Modeled as an aggregate fraction of imports under each annex product
      # that contain zero metal. Dormant by default (aggregate_share = 0 in
      # policy_params.yaml); a non-zero share scales rate_232 down by
      # (1 - share). Calibration would require per-prefix metal-content
      # trade data (CBP entry summaries, industry surveys); none today.
      zmc_cfg <- annex_cfg$exemptions$zero_metal_content
      zmc_share <- as.numeric(zmc_cfg$aggregate_share %||% 0)
      if (!is.na(zmc_share) && zmc_share > 0) {
        zmc_annexes <- paste0('annex_', unlist(zmc_cfg$applies_to %||% c('1a', '1b', '3')))
        rates <- rates %>%
          mutate(rate_232 = if_else(
            !(hts10 %in% heading_program_products) & s232_annex %in% zmc_annexes,
            rate_232 * (1 - zmc_share),
            rate_232
          ))
        message('  zero_metal_content exemption applied: share=', zmc_share,
                ', annexes=', paste(zmc_annexes, collapse = ','))
      }

      # Other aggregate-share annex exemption routes — all dormant by default
      # (aggregate_share = 0 in policy_params.yaml; the sgept_exemptions
      # scenario carries SGEPT's estimates). Same expected-value approximation
      # as zero_metal_content above: the share of import value on the scoped
      # products that takes the route. Applied before the country overrides,
      # so a replace-mode override (UK deal) takes precedence on its rows —
      # acceptable at these magnitudes (~1-2%). See docs/assumptions.md §18.
      #
      # us_origin_metal — Note 16(e): derivative articles where >=85% of the
      # metal content is US-smelted/cast take the 10% TARGET-TOTAL headings
      # (9903.82.06-.08/.15/.23/.24): "the sum of the column 1 duty rate and
      # the additional ad valorem rate of duty will total 10 percent" —
      # floor_post_mfn semantics, the same shape the annex_1c block above
      # uses for its US-metal route (and the same config entry). Blend:
      # share * pmin(rate, floor-route) + (1-share) * rate. Applied across
      # annex 1a/1b/3 — an approximation; legally it is the derivative
      # (c)-groups only, which the tier map does not distinguish within
      # annex_1a.
      usm_g_cfg <- annex_cfg$exemptions$us_origin_metal
      usm_g_share <- as.numeric(usm_g_cfg$aggregate_share %||% 0)
      if (!is.na(usm_g_share) && usm_g_share > 0) {
        usm_g_rate <- as.numeric(usm_g_cfg$rate %||% 0.10)
        usm_g_annexes <- paste0('annex_', unlist(usm_g_cfg$applies_to %||% c('1a', '1b', '3')))
        rates <- rates %>%
          mutate(
            .usm_g_route = apply_rate_semantics(usm_g_rate, 'floor_post_mfn', base_rate),
            rate_232 = if_else(
              !(hts10 %in% heading_program_products) & s232_annex %in% usm_g_annexes,
              usm_g_share * pmin(rate_232, .usm_g_route) + (1 - usm_g_share) * rate_232,
              rate_232
            )
          ) %>%
          select(-.usm_g_route)
        message('  us_origin_metal route applied: share=', usm_g_share,
                ', target-total=', usm_g_rate,
                ', annexes=', paste(usm_g_annexes, collapse = ','))
      }

      # de_minimis_weight — articles whose covered-metal weight is below the
      # threshold are EXEMPT; scale by (1 - share) on the applies_to annexes,
      # excluding the primary metal chapters (a ch72 coil is never de minimis).
      dmw_cfg <- annex_cfg$exemptions$de_minimis_weight
      dmw_share <- as.numeric(dmw_cfg$aggregate_share %||% 0)
      if (!is.na(dmw_share) && dmw_share > 0) {
        dmw_annexes <- paste0('annex_', unlist(dmw_cfg$applies_to %||% c('1b', '3')))
        dmw_excl <- as.character(unlist(dmw_cfg$excludes_chapters %||% character(0)))
        rates <- rates %>%
          mutate(rate_232 = if_else(
            !(hts10 %in% heading_program_products) & s232_annex %in% dmw_annexes &
              !(substr(hts10, 1, 2) %in% dmw_excl),
            rate_232 * (1 - dmw_share),
            rate_232
          ))
        message('  de_minimis_weight exemption applied: share=', dmw_share,
                ', annexes=', paste(dmw_annexes, collapse = ','))
      }

      # motorcycle_parts — Note 16(g) (9903.82.13): motorcycle articles
      # otherwise meeting the (c)(vi)-(viii)/(xi) criteria are EXEMPT; scale
      # by (1 - share) on the applies_to annexes within the config chapters.
      moto_cfg <- annex_cfg$exemptions$motorcycle_parts
      moto_share <- as.numeric(moto_cfg$aggregate_share %||% 0)
      if (!is.na(moto_share) && moto_share > 0) {
        moto_annexes <- paste0('annex_', unlist(moto_cfg$applies_to %||% c('1b')))
        moto_ch <- as.character(unlist(moto_cfg$chapters %||% c('84', '85', '87')))
        rates <- rates %>%
          mutate(rate_232 = if_else(
            !(hts10 %in% heading_program_products) & s232_annex %in% moto_annexes &
              substr(hts10, 1, 2) %in% moto_ch,
            rate_232 * (1 - moto_share),
            rate_232
          ))
        message('  motorcycle_parts exemption applied: share=', moto_share,
                ', annexes=', paste(moto_annexes, collapse = ','))
      }

      # UK annex deal + country surcharges: READ off the spec
      # (section_232$annex$country_overrides), applied in list order. mode 'replace'
      # = flat set (the UK annex deal: 1a/1b steel/alum -> uk_rate); mode 'max' =
      # pmax surcharge (e.g. Russia aluminum 200% across annex 1a/1b/3). The adapter
      # baked the annex-tier + metal-type + chapter scoping into each rate_map, so
      # the calc just applies them — no config reads, no fallback.
      for (ov in (ann$country_overrides %||% list())) {
        r    <- ov$rate_map[as.character(rates$hts10)]       # NA where product not in map
        hit  <- rates$country %in% ov$countries & !is.na(r)
        # Replace-mode overrides (the UK annex deal) must not wipe heading-
        # program rates — same guard as the annex flat override above. This
        # became reachable 2026-07-08 when the UK gate widened from ch72/73/76
        # to the 16(d) (c)-list metal types: annex_1b spans ch84/85/87 lines
        # that also carry auto/MHD/semi heading rates. Max-mode surcharges
        # (Russia) keep their historical semantics (pmax over whatever rate
        # is present, heading rates included).
        if (identical(ov$mode, 'replace')) {
          hit <- hit & !(rates$hts10 %in% heading_program_products)
        }
        newr <- if (identical(ov$mode, 'max')) pmax(rates$rate_232, unname(r)) else unname(r)
        rates$rate_232 <- if_else(hit, newr, rates$rate_232)
      }

      # Annex III / I-C sunset: after sunset_date, temporary products move to I-B rate
      sunset <- annex_cfg$annexes$annex_3$sunset_date
      if (!is.null(sunset) && as.Date(effective_date) > as.Date(sunset)) {
        rates <- rates %>%
          mutate(
            rate_232 = if_else(s232_annex == 'annex_3',
                                annex_cfg$annexes$annex_1b$rate, rate_232),
            s232_annex = if_else(s232_annex == 'annex_3', 'annex_1b', s232_annex)
          )
        message('  Annex III sunset: reclassified to I-B')
      }
      sunset_1c <- annex_cfg$annexes$annex_1c$sunset_date
      if (!is.null(sunset_1c) && as.Date(effective_date) > as.Date(sunset_1c)) {
        rates <- rates %>%
          mutate(
            rate_232 = if_else(s232_annex == 'annex_1c',
                                annex_cfg$annexes$annex_1b$rate, rate_232),
            s232_annex = if_else(s232_annex == 'annex_1c', 'annex_1b', s232_annex)
          )
        message('  Annex I-C sunset: reclassified to I-B')
      }

      # Update statutory_rate_232 to reflect annex overrides
      rates <- rates %>%
        mutate(statutory_rate_232 = if_else(!is.na(s232_annex), rate_232, statutory_rate_232))

      n_by_annex <- rates %>% filter(!is.na(s232_annex), rate_232 > 0) %>% count(s232_annex)
      if (nrow(n_by_annex) > 0) {
        message('  Annex rate override: ',
                paste(n_by_annex$s232_annex, n_by_annex$n, sep = '=', collapse = ', '))
      }

      # 5d. Subdivision (r) blend for EU/JP/KR certified auto parts.
      # Per US Note 33(r), EU/JP/KR auto parts not in subdivision (g) and not in
      # Note 38(i) MHD parts get a 15% floor (9903.94.45/.55/.65) when the
      # importer certifies them for US production/repair. Note 33(r)(1) carves
      # them out from the metals annex (9903.82.02/.04-.19). Without this blend
      # the post-annex tracker leaves the annex_1b 25% rate on these products
      # for EU/JP/KR (~10pp over the legal cap on the certified share).
      #
      # Three-way mix per import:
      #   1. fta_share  — qualifies under EO 14345 (Japan) or KORUS (Korea); per
      #      Note 33(r) line 35836-37 these are EXEMPT from .44/.45/.54/.55/.64/.65
      #      additional duty AND from the metals annex via the (r)(1) carve-out.
      #      rate_232 = 0; only base_rate (FTA-special) applies.
      #   2. certified_share × (1 - fta_share) — non-FTA but certified for US
      #      production. rate_232 = pmax(floor - base, 0).
      #   3. (1 - certified_share) × (1 - fta_share) — non-FTA, uncertified.
      #      Falls under annex_1b (or whatever rate_232 was set to in step 5c).
      #
      # All shares default to 0 (dormant). IEEPA reciprocal is left at the
      # existing annex-zeroed value, matching subdivision (g) treatment today.
      subdiv_r_cfg <- pp$auto_parts_subdivision_r
      certified_share <- subdiv_r_cfg$certified_share %||% 0
      fta_shares_cfg <- subdiv_r_cfg$fta_exempt_shares %||% list()
      any_fta_share <- any(unlist(fta_shares_cfg) > 0)

      if (!is.null(subdiv_r_cfg) && (certified_share > 0 || any_fta_share)) {
        subdiv_r_path <- here(subdiv_r_cfg$products_file)
        if (!file.exists(subdiv_r_path)) {
          stop('auto_parts_subdivision_r$products_file not found: ', subdiv_r_path)
        }
        subdiv_r <- read_csv_cached(subdiv_r_path, col_types = cols(.default = col_character()))
        prefixes <- unique(subdiv_r$hts_prefix)
        if (length(prefixes) > 0) {
          eligible_pattern <- paste0('^(', paste(prefixes, collapse = '|'), ')')
          applies_iso <- subdiv_r_cfg$applies_to_iso %||% c('EU', 'JP', 'KR')
          floor_rate_r <- subdiv_r_cfg$floor_rate %||% 0.15

          # Build per-country fta_share lookup (census-coded)
          iso_to_census_vec <- function(iso) {
            if (iso == 'EU') {
              if (!is.null(pp)) names(pp$eu27_codes) else EU27_CODES
            } else {
              as.character(pp$ISO_TO_CENSUS[iso])
            }
          }
          fta_share_by_country <- map_dfr(applies_iso, function(iso) {
            cs <- iso_to_census_vec(iso)
            cs <- cs[!is.na(cs) & nchar(cs) > 0]
            tibble(country = cs,
                    fta_share = fta_shares_cfg[[iso]] %||% 0)
          })
          census_codes <- unique(fta_share_by_country$country)

          rates <- rates %>%
            left_join(fta_share_by_country, by = 'country',
                      relationship = 'many-to-one') %>%
            mutate(
              fta_share = coalesce(fta_share, 0),
              .subdiv_r = grepl(eligible_pattern, hts10) & country %in% census_codes,
              .floor_232 = pmax(floor_rate_r - base_rate, 0),
              .non_fta_blend = certified_share * .floor_232 +
                                (1 - certified_share) * rate_232,
              rate_232 = if_else(
                .subdiv_r,
                fta_share * 0 + (1 - fta_share) * .non_fta_blend,
                rate_232
              ),
              statutory_rate_232 = if_else(.subdiv_r, rate_232, statutory_rate_232)
            ) %>%
            select(-.subdiv_r, -.floor_232, -.non_fta_blend, -fta_share)

          n_blended <- sum(grepl(eligible_pattern, rates$hts10) & rates$country %in% census_codes)
          fta_summary <- paste(
            sprintf('%s=%.2f', names(fta_shares_cfg %||% list()),
                    unlist(fta_shares_cfg %||% list())),
            collapse = ', '
          )
          message('  Subdiv (r) blend: certified_share=', certified_share,
                  '; fta_exempt_shares=[', fta_summary,
                  '] applied to ', n_blended, ' product-country pairs (',
                  length(prefixes), ' prefixes × ', length(census_codes), ' countries)')
        }
      }
    } else {
      stop('Section 232: annex-era revision ', revision_id,
           ' has no spec $annex structure — the build must pass specs (Plank 4c).')
    }
  } else {
    rates$s232_annex <- NA_character_
  }

  # 6 + 6a-excl. Section 301 blanket + USTR exclusions (see apply_section301)
  rates <- apply_section301(rates, specs, pp, ch99_data, products, countries, effective_date)

  # 6b. Apply Section 122 blanket tariff (see apply_section122)
  rates <- apply_section122(rates, specs, pp, products, effective_date)

  # 6b-fl. Section 301 forced-labor duties (see apply_section301_forced_labor)
  rates <- apply_section301_forced_labor(rates, specs, countries)

  # 6b-338. Section 338 Canada duties (see apply_section338). Placed after the
  # §232 PRIMARY steps (metals/annex/heading assignment) and before the dense
  # grid / statutory save, like the other blanket authorities. The note-51(c)
  # exclusion mask reads statutory_rate_232 / s232_annex / heading_program here,
  # which is the correct "provided for in a §232 heading" statutory-membership
  # test — NOT the effective rate.
  #
  # CAVEAT (was previously mis-documented as "reads settled values"): a few LATER
  # §232 steps still mutate these mask columns — 6e/6f recompute annex_3/annex_1c
  # framework floors (can raise statutory_rate_232 from 0), 7c note-35 aircraft
  # zeroing sets s232_annex to NA (but leaves statutory_rate_232 > 0), and the 7d
  # applicability shadow raises statutory_rate_232 from 0. This is currently
  # EXACT — no covered-list HTS8 is in the annex_3/annex_1c-framework, semi, or
  # 7d-shadow populations, and 7c leaves statutory_rate_232 positive — so the
  # mask value at 6b-338 equals the final value. scripts/verify_s338_snapshot.R
  # rebuilds the mask from FINAL columns and asserts rate_s338 == 0 on every
  # in-scope row, so any future divergence FAILS the verify. TRIPWIRE: if a
  # future covered-list revision adds a code in those populations, move this call
  # (and the rate_s338 statutory save / ch98 / value-basis handling) after 7d.
  rates <- apply_section338(rates, specs, products, countries)

  # 6b-br. Section 301 Brazil duties (see apply_section301_brazil). Moved from
  # its historical pre-338 slot (the June content_split coding needed no §232
  # ordering) to here: the note-50(a)(vi) full-exclusion scope mask reads the
  # same statutory-membership columns as 6b-338, so the 6b-338 CAVEAT +
  # TRIPWIRE above apply to this call VERBATIM. Currently exact for Brazil
  # rows even though its covered set is all-products-minus-annex (unlike
  # §338's positive lists): 7c leaves statutory_rate_232 positive (statutory
  # arm still masks), the 6e/6f floor recomputes touch annex-tagged rows the
  # annex arm already masks, and the 7d-shadow 8471 lines carry the note-33
  # heading_program tag. scripts/verify_s301_brazil_snapshot.R rebuilds the
  # mask from FINAL columns and asserts rate_s301br == 0 on every in-scope
  # Brazil row, so any future divergence FAILS the verify. If the tripwire
  # ever forces 6b-338 after 7d, move this call with it.
  rates <- apply_section301_brazil(rates, specs, products, countries)

  # 6b1. Section 201 safeguard / solar (see apply_section201)
  rates <- apply_section201(rates, specs, countries)

  # 6b3. Chapter 98 secondary-classification treatment, ALL authorities.
  # Every additional-duty authority's chapter-99 note carries the same ch98
  # paragraph ("The additional duty imposed by this heading shall not apply to
  # goods for which entry is properly claimed under a provision of chapter
  # 98..., except for goods entered under heading 9802.00.80 and subheadings
  # 9802.00.40, 9802.00.50 and 9802.00.60", which attach to the
  # repair/alteration/processing or assembly VALUE only) — verified for §122
  # note 2(aa)(i) (2026_rev_4) and §301 note 20; the fentanyl, reciprocal and
  # country-EO paths already implement it at their own sites via the ch98
  # subset of ieepa_exempt_products. §301/§122/201/other had NO ch98 handling:
  # §122's 10% blanket charged ~115k ch98 pairs from 2026-02-24 — the "Q1-2026
  # ch98 statutory tripling" in the eval residual deep-dive 2026-06-12 item 4.
  # Runs BEFORE the statutory_rate_* save: this is a statutory exemption, not
  # a compliance haircut, so both layers carry it.
  ch98_secondary <- ieepa_exempt_products[
    substr(ieepa_exempt_products, 1, 2) == '98']
  if (length(ch98_secondary) > 0) {
    ch98_m <- rates$hts10 %in% ch98_secondary
    ch98_cols <- c('rate_301', 'rate_301_cs', 'rate_s301fl', 'rate_s301br',
                   'rate_s338', 'rate_s122', 'rate_section_201', 'rate_other')
    ch98_cols <- intersect(ch98_cols, names(rates))
    # coalesce: grid-expanded pairs can carry NA in rate columns at this point
    n_zeroed <- sum(ch98_m & Reduce(`|`, lapply(
      ch98_cols, function(cc) coalesce(rates[[cc]], 0) > 0)))
    if (n_zeroed > 0) {
      for (cc in ch98_cols) rates[[cc]][ch98_m & !is.na(rates[[cc]])] <- 0
      message('  Ch98 exemption (all authorities): zeroed ', n_zeroed,
              ' product-country pairs across ', length(ch98_cols), ' columns')
    }
  }

  # 9802 exception codes: additional duties attach to the repair/alteration/
  # processing value, not the full customs value. Convert to an effective rate
  # on full value via configured dutiable-value shares (statutory basis
  # conversion — the printed rate never legally applied to the full value).
  # 9802.00.80 (assembly value = full less US content) stays at 1.0 until
  # calibrated. rate_232 deliberately excluded (the 232 notes assess
  # 9802.00.60 on FULL value; 232 does not otherwise attach to ch98 lines).
  ch98_vb <- pp$ch98_value_basis$dutiable_value_shares
  if (!is.null(ch98_vb)) {
    vb_cols <- intersect(
      c('rate_301', 'rate_301_cs', 'rate_s301fl', 'rate_s301br', 'rate_s338',
        'rate_s122', 'rate_ieepa_recip', 'swiss_underlying_rate_ieepa_recip',
        'rate_ieepa_fent', 'rate_other'),
      names(rates))
    n_vb <- 0L
    for (code in names(ch98_vb)) {
      share <- as.numeric(ch98_vb[[code]])
      if (share >= 1) next
      vb_m <- startsWith(rates$hts10, code)
      if (!any(vb_m)) next
      n_vb <- n_vb + sum(vb_m & Reduce(`|`, lapply(
        vb_cols, function(cc) coalesce(rates[[cc]], 0) > 0)))
      for (cc in vb_cols) rates[[cc]][vb_m] <- rates[[cc]][vb_m] * share
    }
    if (n_vb > 0) {
      message('  Ch98 value-basis conversion: scaled ', n_vb,
              ' product-country pairs (repair-value share)')
    }
  }

  # Save statutory rates for all non-232 authorities (pre-USMCA, pre-stacking).
  # 232 statutory rates are already saved as statutory_rate_232 in apply_232_derivatives().
  rates <- rates %>%
    mutate(
      statutory_rate_ieepa_recip = rate_ieepa_recip,
      statutory_rate_ieepa_fent  = rate_ieepa_fent,
      statutory_rate_301         = rate_301,
      statutory_rate_301_cs      = rate_301_cs,
      statutory_rate_s301fl      = rate_s301fl,
      statutory_rate_s301br      = rate_s301br,
      statutory_rate_s338        = rate_s338,
      statutory_rate_s122        = rate_s122,
      statutory_rate_section_201 = rate_section_201,
      statutory_rate_other       = rate_other
    )

  # 6c. Apply MFN exemption shares (FTA/GSP preference adjustment)
  # Reduces statutory base_rate using HS2 x country exemption shares from Census
  # calculated duty data. Preserves statutory_base_rate for reference.
  # CA/MX excluded when USMCA product shares handle them at HTS10 level (step 7).
  rates <- rates %>%
    mutate(statutory_base_rate = base_rate)

  if (!is.null(mfn_exemption_shares) && nrow(mfn_exemption_shares) > 0) {
    exclude_usmca <- pp$MFN_EXEMPTION$exclude_usmca_countries
    usmca_countries <- c(CTY_CANADA, CTY_MEXICO)

    rates <- rates %>%
      mutate(hs2 = substr(hts10, 1, 2)) %>%
      left_join(
        mfn_exemption_shares %>% select(hs2, cty_code, exemption_share),
        by = c('hs2', 'country' = 'cty_code'),
        relationship = 'many-to-one'
      ) %>%
      mutate(
        exemption_share = coalesce(exemption_share, 0),
        # Skip CA/MX if configured (USMCA handles them in step 7)
        exemption_share = if_else(
          exclude_usmca & country %in% usmca_countries,
          0, exemption_share
        ),
        base_rate = base_rate * (1 - exemption_share)
      ) %>%
      select(-hs2, -exemption_share)

    n_adjusted <- sum(rates$base_rate < rates$statutory_base_rate)
    message('  MFN exemption shares: adjusted base_rate for ', n_adjusted,
            ' product-country pairs')

    # 6d. Recompute IEEPA floor deduction against post-MFN base_rate.
    # Only for rows originally computed as floor-type (ieepa_type == 'floor').
    # Step 2 computed floor as max(0, floor_rate - statutory_base); now base_rate is
    # lower (after FTA/GSP preference in 6c), so the floor gap is wider.
    # Surcharge rows for floor countries (e.g. Swiss/LI outside framework window)
    # must NOT be recomputed — their rate is a flat surcharge, not a floor deduction.
    floor_rate_val <- pp$FLOOR_RATE
    if (!is.null(floor_rate_val) &&
        'rate_ieepa_recip' %in% names(rates) &&
        'ieepa_type' %in% names(rates)) {
      floor_mask <- rates$ieepa_type == 'floor' &
                    rates$rate_ieepa_recip > 0 &
                    rates$base_rate < rates$statutory_base_rate
      if (any(floor_mask)) {
        old_recip <- rates$rate_ieepa_recip[floor_mask]
        rates$rate_ieepa_recip[floor_mask] <- apply_rate_semantics(floor_rate_val, 'floor_post_mfn', rates$base_rate[floor_mask])
        n_floor_adjusted <- sum(rates$rate_ieepa_recip[floor_mask] != old_recip)
        message('  Floor recomputation: updated rate_ieepa_recip for ', n_floor_adjusted,
                ' floor-type pairs (against post-MFN base_rate)')
      }
    }

    # Normally the Swiss underlying layer is a surcharge. Keep the stored field
    # correct if a future source represents it as a floor against post-MFN base.
    if ('swiss_underlying_ieepa_type' %in% names(rates)) {
      swiss_underlying_floor <- rates$swiss_underlying_ieepa_type == 'floor' &
        !is.na(rates$swiss_underlying_ieepa_country_rate) &
        rates$base_rate < rates$statutory_base_rate
      swiss_underlying_floor[is.na(swiss_underlying_floor)] <- FALSE
      if (any(swiss_underlying_floor)) {
        rates$swiss_underlying_rate_ieepa_recip[swiss_underlying_floor] <-
          apply_rate_semantics(
            rates$swiss_underlying_ieepa_country_rate[swiss_underlying_floor],
            'floor_post_mfn', rates$base_rate[swiss_underlying_floor])
      }
    }

    # 6e. Recompute Annex III floor against post-MFN base_rate (same logic as 6d).
    if (!is.null(annex_cfg) && as.Date(effective_date) >= annex_cfg$effective_date &&
        's232_annex' %in% names(rates)) {
      annex3_mask <- !is.na(rates$s232_annex) & rates$s232_annex == 'annex_3' &
                     rates$base_rate < rates$statutory_base_rate
      if (any(annex3_mask)) {
        floor_val <- annex_cfg$annexes$annex_3$floor_rate
        rates$rate_232[annex3_mask] <- apply_rate_semantics(floor_val, 'floor_post_mfn', rates$base_rate[annex3_mask])
        rates$statutory_rate_232[annex3_mask] <- rates$rate_232[annex3_mask]
        message('  Annex III floor recomputation: updated ', sum(annex3_mask),
                ' pairs (against post-MFN base_rate)')
      }
      ann1c_cfg <- annex_cfg$annexes$annex_1c
      if (!is.null(ann1c_cfg) &&
          as.Date(effective_date) >= as.Date(ann1c_cfg$effective_date %||% '9999-12-31')) {
        fw_countries <- as.character(unlist(ann1c_cfg$framework_countries %||% character(0)))
        if ('eu' %in% fw_countries) {
          fw_countries <- unique(c(setdiff(fw_countries, 'eu'), pp$EU27_CODES %||% character(0)))
        }
        ann1c_mask <- !is.na(rates$s232_annex) & rates$s232_annex == 'annex_1c' &
                      rates$country %in% fw_countries &
                      rates$base_rate < rates$statutory_base_rate
        if (any(ann1c_mask)) {
          floor_val <- ann1c_cfg$framework_floor_rate %||% 0.15
          rates$rate_232[ann1c_mask] <- pmin(
            rates$rate_232[ann1c_mask],
            apply_rate_semantics(floor_val, 'floor_post_mfn', rates$base_rate[ann1c_mask])
          )
          rates$statutory_rate_232[ann1c_mask] <- rates$rate_232[ann1c_mask]
          message('  Annex I-C framework floor recomputation: updated ', sum(ann1c_mask),
                  ' pairs (against post-MFN base_rate)')
        }
      }
    }

    # 6f. Recompute §232 deal floors against post-MFN base_rate (same logic as
    # 6d/6e). Floor-type deals (Korea/Japan/EU autos "15%", wood floors) are
    # MFN-INCLUSIVE totals: note 33(s) headings "set forth the ordinary customs
    # duty treatment", and CBP collects the flat floor (Korea autos steady
    # 15.0%). Step 4c computed pmax(floor - statutory_base, 0); after 6c the
    # FTA-utilization scaling shrinks base_rate (KORUS autos 2.5% -> ~0.06%),
    # so without this the total under-lands by the claimed preference
    # (12.56% vs 15.0% — eval residual deep-dive 2026-06-12 item 6).
    if ('s232_deal_floor' %in% names(rates)) {
      deal_floor_mask <- !is.na(rates$s232_deal_floor) &
                         rates$base_rate < rates$statutory_base_rate
      if (any(deal_floor_mask)) {
        rates$rate_232[deal_floor_mask] <- pmax(
          rates$s232_deal_floor[deal_floor_mask] - rates$base_rate[deal_floor_mask], 0)
        message('  232 deal floor recomputation: updated ', sum(deal_floor_mask),
                ' pairs (against post-MFN base_rate)')
      }
    }

    # Drop transient ieepa_type column — not part of production output
    rates$ieepa_type <- NULL
    rates$swiss_underlying_ieepa_type <- NULL
    rates$swiss_underlying_ieepa_country_rate <- NULL
  }

  # Transient deal-floor tag (set in step 4c, consumed in 6f) — drop
  # unconditionally so it never reaches the output schema.
  rates$s232_deal_floor <- NULL

  # 7. Apply USMCA exemptions
  # TPC methodology: rate * (1 - usmca_share) for each CA/MX product.
  # If DataWeb SPI shares available (from download_usmca_dataweb.R), apply to ALL
  # CA/MX products — the share naturally handles eligibility (products that never
  # enter under USMCA have share ≈ 0, fully-claiming products have share ≈ 1).
  # Also applies to 232 auto/MHD products flagged s232_usmca_eligible (T1 fix).
  # Falls back to binary eligibility (S/S+ → zero rate) if shares not available.
  #
  # Scenario override: USMCA_SHARES$mode == 'none' means "0% utilization — no
  # importer claims USMCA on any product-country pair". Skip the block entirely
  # so CA/MX rates are left at their pre-USMCA values (neither the share path
  # nor the binary S/S+ fallback fires). The data_loader for mode='none' returns
  # an empty tibble; the short-circuit here is what actually implements the
  # scenario semantics.
  # Dense-grid expansion may have supplied the schema default already; replace
  # it with the authoritative HTS-derived value below instead of creating
  # usmca_eligible.x/.y on the join.
  rates$usmca_eligible <- NULL
  if (!'s232_usmca_eligible' %in% names(rates)) {
    rates$s232_usmca_eligible <- FALSE
  }
  usmca_mode <- pp$USMCA_SHARES$mode %||% 'h2_average'
  ann1c_usmca_target <- if (!is.null(annex_cfg)) {
    annex_cfg$annexes$annex_1c$usmca_steel$target_total %||% 0.15
  } else {
    0.15
  }
  ann1c_usmca_target <- as.numeric(ann1c_usmca_target)
  if (length(ann1c_usmca_target) != 1L || is.na(ann1c_usmca_target)) ann1c_usmca_target <- 0.15
  if (identical(usmca_mode, 'none')) {
    # Skip rate application, but still populate usmca_eligible from the HTS
    # "special" field so the diagnostic flag retains its meaning in the
    # snapshot (product has S/S+ in HTS, independent of scenario utilization).
    # This matches the semantics of the prior sentinel-row approach on the
    # previously-built usmca_none snapshots.
    message('  USMCA: mode=none, skipping rate exemptions (usmca_eligible retained from HTS)')
    if (!is.null(usmca) && nrow(usmca) > 0) {
      rates <- rates %>%
        left_join(
          usmca %>% select(hts10, usmca_eligible),
          by = 'hts10',
          relationship = 'many-to-one'
        ) %>%
        mutate(usmca_eligible = coalesce(usmca_eligible, FALSE))
    } else {
      rates <- rates %>% mutate(usmca_eligible = FALSE)
    }
  } else if (!is.null(usmca) && nrow(usmca) > 0) {
    rates <- rates %>%
      left_join(
        usmca %>% select(hts10, usmca_eligible),
        by = 'hts10',
        relationship = 'many-to-one'
      ) %>%
      mutate(usmca_eligible = coalesce(usmca_eligible, FALSE))

    # Refresh s232_usmca_eligible for annex-classified products (April 2026
    # proclamation). Step 4 set this flag from the pre-annex heading configs
    # (autos_passenger, autos_light_trucks, mhd_vehicles, auto_parts,
    # mhd_parts). Step 5c's annex restructuring pulls in additional products
    # outside those headings — without this refresh, an annex_1b product
    # that's S/S+ in the HTS special field but absent from the pre-annex
    # heading lists keeps s232_usmca_eligible = FALSE and gets the full
    # annex rate from CA/MX. Steel/aluminum chapters (72/73/76) are excluded
    # by design — they have no legal USMCA carve-out at any point. annex_2
    # zeros rate_232 entirely so eligibility is moot there.
    if ('s232_annex' %in% names(rates)) {
      rates <- rates %>%
        mutate(s232_usmca_eligible = if_else(
          coalesce(s232_annex %in% c('annex_1a', 'annex_1b', 'annex_3'), FALSE) &
            coalesce(usmca_eligible, FALSE) &
            !(substr(hts10, 1, 2) %in% c(STEEL_CHAPTERS, ALUM_CHAPTERS)),
          TRUE,
          coalesce(s232_usmca_eligible, FALSE)
        ))
    }

    if (!is.null(usmca_product_shares) && nrow(usmca_product_shares) > 0) {
      # Census SPI shares: apply to all CA/MX products.
      # Missing or zero-trade HTS10 pairs fall back to the HS8-level
      # value-weighted share (attr 'hs8_shares' from the h2_average loader)
      # before defaulting to 0 — handles statistical splits/concordance
      # drift like 2709.00.20.10 (extreme-eta review item 6).
      hs8_shares <- attr(usmca_product_shares, 'hs8_shares')
      rates <- rates %>%
        left_join(
          usmca_product_shares,
          by = c('hts10', 'country' = 'cty_code'),
          relationship = 'many-to-one'
        )
      if (!is.null(hs8_shares) && nrow(hs8_shares) > 0) {
        n_na <- sum(is.na(rates$usmca_share) &
                      rates$country %in% c(CTY_CANADA, CTY_MEXICO))
        rates <- rates %>%
          mutate(.hs8 = substr(hts10, 1, 8)) %>%
          left_join(hs8_shares,
                    by = c('.hs8' = 'hts8', 'country' = 'cty_code'),
                    relationship = 'many-to-one') %>%
          mutate(usmca_share = coalesce(usmca_share, usmca_share_hs8)) %>%
          select(-.hs8, -usmca_share_hs8)
        n_filled <- n_na - sum(is.na(rates$usmca_share) &
                                 rates$country %in% c(CTY_CANADA, CTY_MEXICO))
        if (n_filled > 0) {
          message('  USMCA shares: HS8 fallback filled ', n_filled,
                  ' of ', n_na, ' missing CA/MX product shares')
        }
      }
      rates <- rates %>%
        mutate(
          usmca_share = if_else(
            country %in% c(CTY_CANADA, CTY_MEXICO),
            coalesce(usmca_share, 0), 0
          ),
          base_rate = base_rate * (1 - usmca_share),
          rate_ieepa_recip = rate_ieepa_recip * (1 - usmca_share),
          rate_ieepa_fent = rate_ieepa_fent * (1 - usmca_share),
          rate_s122 = rate_s122 * (1 - usmca_share),
          # A3 (Req 2): USMCA applies to BOTH 301 flavors. Zero-effect on baseline —
          # 301 is China-only and China isn't CA/MX, so rate_301 is 0 on CA/MX rows
          # (0 * (1 - share) = 0); rate_301_cs is all-zero until A2 classifies codes
          # in. A re-scope scenario (301 -> CA/MX) then receives USMCA preference.
          rate_301 = rate_301 * (1 - usmca_share),
          rate_301_cs = rate_301_cs * (1 - usmca_share),
          # Forced-labor §301 (scenario, usmca_treatment='eligible'): USMCA-compliant
          # CA/MX goods are exempt. rate_s301fl is 0 on CA/MX in baseline (column all-
          # zero) so this is a no-op there. The FRN exempts USMCA-COMPLIANT goods
          # outright; the share path approximates that via (1 - usmca_share).
          rate_s301fl = rate_s301fl * (1 - usmca_share),
          # Apply USMCA shares to 232 auto/MHD (heading products with usmca_exempt flag)
          # and Annex I-C steel treatment (Proc. 11032 / U.S. note 16(j)).
          # Annex I-C clause (2)(d): the 25% duty applies ONLY to non-U.S. content
          # (the usmca_share is exempt, not taxed), and the total effective duty is
          # floored at 15%. So it's max(rate_232 * non-US-content, 0.15) — NOT a
          # convex blend. importer-level U.S.-content above/below the 40% exempt cap
          # is not observed; (1 - usmca_share) proxies the non-U.S. content fraction.
          # Whole VEHICLES (usmca_vehicle_products) use the adjusted USMCA share:
          # usmca_share * us_auto_content_share (only ~40% of USMCA-eligible vehicle
          # value is US/USMCA-origin content). PARTS (auto_parts 9903.94.06, MHD
          # parts per Proc. 10984) are fully exempt when USMCA-qualifying — Commerce
          # had no non-US-content process for parts in the data window — so they are
          # NOT content-scaled; they fall through to the s232_usmca_eligible arm and
          # get the full (1 - usmca_share) exemption.
          rate_232 = if_else(
            country %in% c(CTY_CANADA, CTY_MEXICO),
            case_when(
              coalesce(s232_annex == 'annex_1c', FALSE) ~
                pmax(rate_232 * (1 - usmca_share), ann1c_usmca_target),
              coalesce(s232_usmca_eligible, FALSE) & hts10 %in% usmca_vehicle_products ~
                rate_232 * (1 - usmca_share * us_auto_content_share),
              coalesce(s232_usmca_eligible, FALSE) ~
                rate_232 * (1 - usmca_share),
              TRUE ~ rate_232
            ),
            rate_232
          )
        ) %>%
        select(-usmca_share)
    } else {
      # Fallback: binary USMCA from HTS special field
      rates <- rates %>%
        mutate(
          rate_ieepa_recip = if_else(
            country %in% c(CTY_CANADA, CTY_MEXICO) & usmca_eligible,
            0, rate_ieepa_recip
          ),
          rate_ieepa_fent = if_else(
            country %in% c(CTY_CANADA, CTY_MEXICO) & usmca_eligible,
            0, rate_ieepa_fent
          ),
          rate_s122 = if_else(
            country %in% c(CTY_CANADA, CTY_MEXICO) & usmca_eligible,
            0, rate_s122
          ),
          # A3 (Req 2): USMCA on BOTH 301 flavors (binary fallback). Zero-effect on
          # baseline (301 is China-only; China isn't CA/MX).
          rate_301 = if_else(
            country %in% c(CTY_CANADA, CTY_MEXICO) & usmca_eligible,
            0, rate_301
          ),
          rate_301_cs = if_else(
            country %in% c(CTY_CANADA, CTY_MEXICO) & usmca_eligible,
            0, rate_301_cs
          ),
          # Forced-labor §301 (scenario): USMCA-compliant CA/MX exempt (binary).
          rate_s301fl = if_else(
            country %in% c(CTY_CANADA, CTY_MEXICO) & usmca_eligible,
            0, rate_s301fl
          ),
          # Binary fallback: 232 for USMCA-eligible CA/MX. Whole VEHICLES
          # (usmca_vehicle_products): scale by (1 - us_auto_content_share). PARTS
          # (auto_parts 9903.94.06, MHD parts per Proc. 10984) and other generic
          # s232_usmca_eligible rows are fully exempt (zero) — parts are not
          # content-scaled. Annex I-C steel gets the 15% minimum.
          rate_232 = if_else(
            country %in% c(CTY_CANADA, CTY_MEXICO) & usmca_eligible,
            case_when(
              coalesce(s232_annex == 'annex_1c', FALSE) ~
                pmin(rate_232, ann1c_usmca_target),
              coalesce(s232_usmca_eligible, FALSE) & hts10 %in% usmca_vehicle_products ~
                rate_232 * (1 - us_auto_content_share),
              coalesce(s232_usmca_eligible, FALSE) ~ 0,
              TRUE ~ rate_232
            ),
            rate_232
          )
        )
    }
  } else {
    rates <- rates %>% mutate(usmca_eligible = FALSE)
  }

  # Clean up intermediate flag
  rates$s232_usmca_eligible <- NULL

  # Note 39(a)(7)-(9): semi articles are not subject to 232 aluminum/steel
  # derivative duties, and the April 2026 annex restructuring doesn't re-scope
  # them. Several upstream steps (apply_232_derivatives, annex overrides,
  # USMCA auto-content, etc.) can mutate rate_232 for semi HTS10s. Restore the
  # semi heading rate as the final step before stacking so the 25% is what
  # actually carries into the ETR.
  if (exists('semi_products') && length(semi_products) > 0 &&
      exists('heading_product_rate') && nrow(heading_product_rate) > 0) {
    semi_override <- heading_product_rate %>%
      filter(hts10 %in% semi_products) %>%
      select(hts10, .semi_heading_rate = heading_232_rate)
    if (nrow(semi_override) > 0) {
      rates <- rates %>%
        left_join(semi_override, by = 'hts10', relationship = 'many-to-one') %>%
        mutate(
          rate_232 = if_else(!is.na(.semi_heading_rate), .semi_heading_rate, rate_232),
          deriv_type = if_else(!is.na(.semi_heading_rate), NA_character_, deriv_type),
          statutory_rate_232 = if_else(!is.na(.semi_heading_rate), .semi_heading_rate,
                                       statutory_rate_232)
        ) %>%
        select(-.semi_heading_rate)
      message('  Semi: restored heading rate on ', nrow(semi_override), ' HTS10s')
    }
  }

  # 7c. Section 232 civil-aircraft exemptions.
  #     Note 35 civil-aircraft headings remove the metals-annex duties
  #     (9903.82.02 and 9903.82.04-9903.82.19). Zeroing rate_232 here drops these
  #     rows into the "without 232" branch of apply_stacking_rules() below, so only
  #     the 232 metals duty is removed. Taiwan is gated on 9903.96.03 (note 35(c),
  #     self-dating to rev_9+); floor-country aircraft lists (note 35(a)/(b),
  #     9903.96.01/.02 + 9903.02.x) are gated on their parsed ch99 codes being
  #     present. The annex_232_mask gate ensures the exemption only removes a
  #     rate_232 that came from the metals annex (9903.82.xx) — never one written
  #     by a non-metals 232 program (wood 9903.76, auto parts 9903.94, MHD 9903.74).
  aircraft_cfg <- pp$section_232_aircraft_exemption
  if (!is.null(aircraft_cfg) && isTRUE(aircraft_cfg$enabled)) {
    annex_232_mask <- if ('s232_annex' %in% names(rates)) !is.na(rates$s232_annex) else FALSE
    aircraft_exemptions <- tibble(country = character(), hts8 = character())
    if ('9903.96.03' %in% ch99_data$ch99_code) {
      aircraft_exemptions <- bind_rows(
        aircraft_exemptions,
        tibble(country = pp$country_codes$CTY_TAIWAN,
               hts8 = load_232_aircraft_exempt_taiwan())
      )
    }
    if (any(ch99_data$ch99_code %in% c('9903.02.76', '9903.02.81', '9903.02.85', '9903.96.02'))) {
      aircraft_exemptions <- bind_rows(
        aircraft_exemptions,
        load_232_aircraft_exempt_floor_groups(policy_params = pp)
      )
    }
    aircraft_exemptions <- aircraft_exemptions %>%
      distinct(country, hts8) %>%
      mutate(.air_key = paste(country, hts8, sep = '|'))
    # Gate on s232_annex so the exemption can only remove a rate_232 that came
    # from the metals annex, never one written by a non-metals 232 program.
    air_key <- paste(rates$country, substr(rates$hts10, 1, 8), sep = '|')
    air_mask <- air_key %in% aircraft_exemptions$.air_key &
      rates$rate_232 > 0 & annex_232_mask
    n_air <- sum(air_mask)
    if (n_air > 0) {
      rates$rate_232[air_mask] <- 0
      if ('s232_annex' %in% names(rates)) rates$s232_annex[air_mask] <- NA_character_
      message('  Civil-aircraft 232 exemption (note 35): zeroed Section 232 on ',
              n_air, ' product-country rows')
    }
  }

  # 7d. Statutory shadow for applicability-excluded heading products.
  # Products dropped from a 232 heading by applicability_share = 0 (currently
  # the bare-8471 Note 33(g) entry — general-purpose computers are not "parts
  # of passenger vehicles") keep their EFFECTIVE non-232 treatment from the
  # exclusion at match time, but statutory_rate_232 records what the literal
  # enumeration would have charged: heading default rate minus the auto
  # rebate (matching the post-rebate convention of the statutory save in
  # step 4c). This preserves the statutory-vs-collected wedge for downstream
  # measurement (tariff-etr-eval) instead of baking the de facto reading into
  # both columns. Country-specific deal floors (e.g. Taiwan 9903.94.67 at
  # rev_9+) are NOT applied to the shadow — documented simplification; the
  # shadow is the blanket literal rate.
  if (exists('applicability_excluded') && nrow(applicability_excluded) > 0) {
    # Products that still carry a REAL 232 heading rate via another program
    # (the 8471 prefix exclusion also sweeps the 5 semi-listed codes, which
    # get their true rate from the semiconductors heading) keep their actual
    # statutory_rate_232 — only genuinely non-232 exclusions get the shadow.
    in_other_heading <- if (exists('heading_product_rate') &&
                            nrow(heading_product_rate) > 0) {
      heading_product_rate$hts10
    } else {
      character(0)
    }
    shadow <- applicability_excluded %>%
      distinct(hts10, .keep_all = TRUE) %>%
      filter(!hts10 %in% in_other_heading) %>%
      mutate(.stat_shadow = pmax(literal_rate - rebate_deduction, 0)) %>%
      select(hts10, .stat_shadow)
    if (nrow(shadow) > 0) {
      rates <- rates %>%
        left_join(shadow, by = 'hts10', relationship = 'many-to-one') %>%
        mutate(
          statutory_rate_232 = if_else(!is.na(.stat_shadow),
                                       .stat_shadow, statutory_rate_232)
        ) %>%
        select(-.stat_shadow)
      message('  Applicability-excluded statutory shadow: statutory_rate_232 = ',
              'literal heading rate (post-rebate) on ', nrow(shadow),
              ' products (effective rate_232 stays 0)')
    }
  }

  # Scenario-only authority columns are initialized outside RATE_SCHEMA; keep
  # their zero invariant explicit before stacking.
  if ('rate_s301fl' %in% names(rates)) {
    rates$rate_s301fl <- coalesce(rates$rate_s301fl, 0)
  }
  if ('statutory_rate_s301fl' %in% names(rates)) {
    rates$statutory_rate_s301fl <- coalesce(rates$statutory_rate_s301fl, 0)
  }
  # Brazil §301 (baseline column since the final action): 0-fill rows added
  # after the 6b-br block (dense-grid MFN-only pairs + late seeders) so it
  # enters stacking clean. Like rate_s338 it is RATE_SCHEMA proper — never
  # dropped when all-zero.
  if ('rate_s301br' %in% names(rates)) {
    rates$rate_s301br <- coalesce(rates$rate_s301br, 0)
  }
  if ('statutory_rate_s301br' %in% names(rates)) {
    rates$statutory_rate_s301br <- coalesce(rates$statutory_rate_s301br, 0)
  }
  # Section 338 (baseline column): 0-fill rows added after the 6b-338 block
  # (e.g. the §201 blanket seeder + dense-grid MFN-only pairs) so it enters
  # stacking clean. Unlike s301fl/br it is NEVER dropped when all-zero —
  # rate_s338 is RATE_SCHEMA proper.
  if ('rate_s338' %in% names(rates)) {
    rates$rate_s338 <- coalesce(rates$rate_s338, 0)
  }
  if ('statutory_rate_s338' %in% names(rates)) {
    rates$statutory_rate_s338 <- coalesce(rates$statutory_rate_s338, 0)
  }

  # 8. Re-apply the single production stacking path with updated policy rates.
  rates <- apply_stacking_rules(
    rates, CTY_CHINA,
    stacking_policy = stacking_policy_from_specs(specs, CTY_CHINA)
  )

  # 9a. Add revision metadata
  rates <- rates %>%
    mutate(
      revision = revision_id,
      effective_date = as.Date(effective_date)
    )

  # 9b. Enforce canonical schema
  rates <- enforce_rate_schema(rates)

  # Forced-labor §301 is a SCENARIO-scoped extra column (not in RATE_SCHEMA). Drop
  # it when it carries no duty — baseline and every pre-turn-on revision — so those
  # panels are byte-identical to the pre-scenario schema (no new all-zero column,
  # no reference re-freeze). Kept (non-zero) only in revisions where forced-labor is live.
  if ('rate_s301fl' %in% names(rates) && all(rates$rate_s301fl == 0)) {
    rates$rate_s301fl <- NULL
    if ('statutory_rate_s301fl' %in% names(rates)) rates$statutory_rate_s301fl <- NULL
  }
  # Brazil §301 is BASELINE (RATE_SCHEMA proper) since the final action: unlike
  # rate_s301fl above it is NEVER dropped — it persists all-zero in pre-07-22
  # revisions, exactly like rate_s338.

  expected_rows <- nrow(products) * length(countries)
  if (nrow(rates) != expected_rows || anyDuplicated(rates[c('hts10', 'country')])) {
    stop('calculate_rates_for_revision: canonical grid identity changed after policy mutation',
         call. = FALSE)
  }

  # Summary
  n_with_ieepa <- sum(rates$rate_ieepa_recip > 0)
  n_with_232 <- sum(rates$rate_232 > 0)
  n_with_301 <- sum(rates$rate_301 > 0)
  n_with_s122 <- sum(rates$rate_s122 > 0)
  n_usmca <- sum(rates$usmca_eligible)
  message('  Products-countries: ', nrow(rates))
  message('  With IEEPA reciprocal: ', n_with_ieepa)
  message('  With Section 232: ', n_with_232)
  message('  With Section 301: ', n_with_301)
  message('  With Section 122: ', n_with_s122)
  message('  USMCA eligible: ', n_usmca)

  return(rates)
}
