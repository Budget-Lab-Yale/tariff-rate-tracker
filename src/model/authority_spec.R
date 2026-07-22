# =============================================================================
# authority_spec.R — the AuthoritySpec datatype
# =============================================================================
#
# One uniform per-authority parameter structure (docs/authority_spec.md). The
# baseline parser/adapter PRODUCES these; the scenario layer MUTATES them; the
# calculator READS them. "Baseline = the empty scenario" — same structure, no
# operations applied.
#
# Representation: a plain named list with an S3 class tag (NOT S4/R6). The whole
# pipeline is base-list + tidyverse, policy_params is a nested list, and specs
# must serialize cleanly to per-revision RDS and across future workers — an S3
# list does all of that; S4/R6 would be foreign and serialize poorly.
#
# This file defines ONLY the datatype + validation. Operations (the scenario
# delta) and the JSON->spec adapter live elsewhere (Phase 2 / Phase 1 adapter).
#
# Shape (one authority):
#   authority_spec(
#     authority       = 'section_232',
#     stacking        = list(class = 'primary_metal', exceptions = list()),
#     usmca_treatment = 'per_program' | 'exempt' | 'eligible' | 'none',
#     active          = list(from = as.Date('2025-03-12'), until = NA),
#     programs        = list(authority_program(...), ...)
#   )
# A "spec set" is a named list of authority_spec objects, one per authority,
# class 'authority_spec_set'.
# =============================================================================

# Allowed vocabularies (normalized labels introduced by the schema; NOT live
# code symbols — the calculator's case_when branches are mapped onto these).
STACKING_CLASSES   <- c('primary_metal', 'primary_full', 'content_split', 'additive')
USMCA_TREATMENTS    <- c('exempt', 'eligible', 'none', 'per_program')
METAL_TYPES         <- c('steel', 'aluminum', 'copper', 'other', 'none')

`%||%` <- function(x, y) if (is.null(x)) y else x

# ---- constructors -----------------------------------------------------------

#' Construct one program within an authority.
#'
#' @param id            character — unique within the authority
#' @param product_scope list — one of {chapters, products_file, prefixes_file,
#'   prefixes, list_file} (a precedence, resolved by the adapter), plus optional
#'   exclude_file. Stored as-is.
#' @param country_scope list — {include: 'all' | <census codes>, exclude: <codes/file>}
#' @param rate          list — compositional layers {default, by_country,
#'   default_unlisted_rate, overrides, by_product_tier, target_total} + a
#'   `rate_type` semantics tag. Read by resolve_rate()/apply_rate_semantics()
#'   (see the "rate" section below).
#' @param metal         list|NULL — 232 only: {type, content}. Omit for non-metal.
#' @param active        list|NULL — {from, until}; NULL inherits the authority's.
#' @param stacking      list|NULL — per-program override of the authority stacking.
#' @param settings      list — authority-specific behavioral parameters that are
#'   not product, country, rate, metal, activation, or stacking fields.
authority_program <- function(id, product_scope = list(), country_scope = list(include = 'all'),
                              rate = list(), metal = NULL, active = NULL, stacking = NULL,
                              settings = list()) {
  structure(
    list(id = id, product_scope = product_scope, country_scope = country_scope,
         rate = rate, metal = metal, active = active, stacking = stacking,
         settings = settings),
    class = 'authority_program'
  )
}

#' Construct one authority's spec.
#'
#' @param authority       character — e.g. 'section_232', 'section_301',
#'   'ieepa_reciprocal', 'ieepa_fentanyl', 'section_122', 'section_201',
#'   'mfn', 'other'
#' @param stacking        list — {class, exceptions}; default class for programs
#' @param usmca_treatment character — see USMCA_TREATMENTS
#' @param active          list — {from, until}; until = first inactive day (exclusive)
#' @param programs        list of authority_program objects
authority_spec <- function(authority,
                           stacking = list(class = 'additive', exceptions = list()),
                           usmca_treatment = 'none',
                           active = list(from = NA, until = NA),
                           programs = list()) {
  structure(
    list(authority = authority, stacking = stacking,
         usmca_treatment = usmca_treatment, active = active, programs = programs),
    class = 'authority_spec'
  )
}

#' Bundle per-authority specs into a set (named by authority).
authority_spec_set <- function(...) {
  specs <- list(...)
  if (length(specs) == 1L && is.null(names(specs)) && is.list(specs[[1]]) &&
      !inherits(specs[[1]], 'authority_spec')) {
    specs <- specs[[1]]   # allow passing a pre-built named list
  }
  nm <- vapply(specs, function(s) s$authority %||% NA_character_, character(1))
  existing <- names(specs)
  if (is.null(existing)) existing <- rep('', length(specs))
  names(specs) <- ifelse(is.na(existing) | existing == '', nm, existing)
  structure(specs, class = 'authority_spec_set')
}

# ---- accessors --------------------------------------------------------------

#' Resolve a program's country_scope to an explicit vector of census codes.
#'
#' @param scope list `{include: 'all' | <codes>, exclude: <codes>/<file>}`. A NULL
#'   or 'all' include means every country; exclude is removed afterwards.
#' @param all_countries full census-code universe (used when include is 'all')
#' @return character vector of census codes
resolve_country_scope <- function(scope, all_countries) {
  inc <- scope$include
  base <- if (is.null(inc) || identical(inc, 'all')) {
    as.character(all_countries)
  } else {
    as.character(unlist(inc))
  }
  exc <- scope$exclude
  if (!is.null(exc) && length(exc) > 0) base <- setdiff(base, as.character(unlist(exc)))
  base
}

# ---- rate: compositional schema, reader, semantics (Plank 0 — keystone) -----
#
# The `rate` field on an authority_program is the COMPOSITIONAL rate schema: a
# set of value-layers + a semantics tag. resolve_rate() applies the layer
# precedence (a pure reader, returns a DESCRIPTOR); apply_rate_semantics() turns
# the resolved value into an additional-duty number under its rate_type. The
# split (decision 5/6) keeps the floor base where the caller has it.
#
# NOTE: distinct from src/model/rate_schema.R, which is the OUTPUT PANEL column schema
# (rate_232, rate_301, ...). This is the per-authority spec rate FIELD.
#
# Value-layers (any subset; resolved most-specific-first):
#   overrides              product(×country)-specific set-rates (232 deals, UK
#                          deal). First match in list order wins. Two element
#                          forms, mixable: a named scalar `'4120' = 0.25`
#                          (product->rate, any country), or an entry list
#                          `list(products=, countries=(opt), rate=)` (the rich
#                          product×country deal form, for Plank 4a).
#   by_product_tier        named numeric, names = product codes -> rate (301 lists).
#   by_country             named numeric, names = census codes -> rate (IEEPA recip).
#   default_unlisted_rate  scalar — rate for countries NOT in by_country (the
#                          complement; IEEPA universal baseline). Alias: default_unlisted.
#   default                scalar — flat in-scope rate (232 metal default, MFN base).
#   target_total           scalar — an all-in floor target (Annex-3 floor_rate).
#
# Precedence (most-specific -> least): overrides > by_product_tier > by_country
#   > default_unlisted_rate (only when by_country present) > default > target_total.
#
# Semantics tag (rate_type, orthogonal to value):
#   surcharge       additive +value on top                        (default)
#   floor_static    pmax(0, value - base) vs the ORIGINAL base     (232 deals)
#   floor_post_mfn  pmax(0, value - base) vs the POST-MFN base     (IEEPA recip, Annex-3)
#   passthrough     no additional duty (0); base stands alone      (IEEPA high-duty floor ctys)
# The two floor modes share the same math; they differ only in WHICH base the
# caller supplies — encoded as floor_base ('original' | 'post_mfn') in the
# resolve_rate() descriptor so the calculator fetches the right base.
#
RATE_TYPES <- c('surcharge', 'floor_static', 'floor_post_mfn', 'passthrough')

# Exact-name field access. R's `$` and `[[` do PARTIAL prefix matching by
# default, so rate$default would silently pick up `default_unlisted_rate` when
# no exact `default` exists — a correctness footgun. Always read rate layers
# through this so `default` never collides with `default_unlisted_rate`.
.rate_get <- function(rate, key) {
  if (!is.null(names(rate)) && key %in% names(rate)) rate[[key]] else NULL
}

#' Resolve a program's rate layers to a single value for a (product, country).
#'
#' Pure reader: applies the layer precedence and returns a DESCRIPTOR. The actual
#' surcharge/floor/passthrough math is apply_rate_semantics() (descriptor+helper
#' split, decision 5/6).
#'
#' @param rate    a program$rate list (compositional layers + rate_type)
#' @param product scalar product key (HTS code at the granularity the layers use)
#' @param country scalar census code
#' @return list(value, rate_type, floor_base, matched). `value` is NA when no
#'   layer matches (nothing in scope here → additional duty 0). `matched` names
#'   the winning layer (or 'none').
#'
#' COVERAGE NOTE: every live caller in the pipeline passes `product = NULL`, so the
#' product-keyed precedence half (overrides scalar-form + by_country_tier, steps 1-2)
#' is exercised ONLY by tests/test_resolve_rate.R, never by a parity build. The live
#' 301 tier is read directly at 06_calculate_rates.R, and 232 deals via
#' s232_deal_records(). Treat test_resolve_rate.R as the gate for that half — the
#' parity harness does not cover it.
resolve_rate <- function(rate, product = NULL, country = NULL) {
  rate <- rate %||% list()
  rt <- .rate_get(rate, 'rate_type') %||% 'surcharge'
  if (!rt %in% RATE_TYPES) stop('resolve_rate: unknown rate_type: ', rt)
  floor_base <- switch(rt,
                       floor_static   = 'original',
                       floor_post_mfn = 'post_mfn',
                       NA_character_)
  desc <- function(value, matched) {
    list(value = as.numeric(value)[1], rate_type = rt,
         floor_base = floor_base, matched = matched)
  }

  # 1. overrides — product (×country) specific; first match in list order wins.
  # Two element forms (may be mixed in one list):
  #   named scalar    `'4120' = 0.25`        product code -> rate, any country
  #   entry list      `list(products=, countries=(opt), rate=)`  product×country deal
  ov <- .rate_get(rate, 'overrides')
  if (!is.null(ov) && is.list(ov) && length(ov)) {
    onames <- names(ov)
    for (i in seq_along(ov)) {
      o  <- ov[[i]]
      nm <- if (!is.null(onames)) onames[i] else ''
      if (is.list(o)) {                              # entry form: product×country
        prods <- o$products %||% o$product
        ctys  <- o$countries %||% o$country          # NULL => applies to all countries
        hit_p <- !is.null(product) && !is.null(prods) &&
                 as.character(product) %in% as.character(unlist(prods))
        hit_c <- is.null(ctys) || (!is.null(country) &&
                 as.character(country) %in% as.character(unlist(ctys)))
        if (hit_p && hit_c) return(desc(o$rate, 'overrides'))
      } else if (is.numeric(o) && nzchar(nm)) {      # named-scalar form: product -> rate
        if (!is.null(product) && as.character(product) == nm) return(desc(o, 'overrides'))
      }
    }
  }
  # 2. by_product_tier — product -> rate
  bpt <- .rate_get(rate, 'by_product_tier')
  if (!is.null(bpt) && !is.null(product) && !is.null(names(bpt))) {
    key <- as.character(product)
    if (key %in% names(bpt)) return(desc(bpt[[key]], 'by_product_tier'))
  }
  # 3. by_country — country -> rate
  bc <- .rate_get(rate, 'by_country')
  bc_present <- !is.null(bc)
  if (bc_present && !is.null(country) && !is.null(names(bc))) {
    key <- as.character(country)
    if (key %in% names(bc)) return(desc(bc[[key]], 'by_country'))
  }
  # 4. default_unlisted_rate — only meaningful as the by_country complement
  du <- .rate_get(rate, 'default_unlisted_rate') %||% .rate_get(rate, 'default_unlisted')
  if (bc_present && !is.null(du)) return(desc(du, 'default_unlisted'))
  # 5. default — flat in-scope fallback
  d <- .rate_get(rate, 'default')
  if (!is.null(d)) return(desc(d, 'default'))
  # 6. target_total — all-in floor target fallback
  tt <- .rate_get(rate, 'target_total')
  if (!is.null(tt)) return(desc(tt, 'target_total'))
  desc(NA_real_, 'none')
}

#' Turn a resolved rate value into an ADDITIONAL-duty number under its semantics.
#'
#' @param value      resolved gross rate (NA => nothing in scope => 0). Vectorized.
#' @param rate_type  one of RATE_TYPES (default 'surcharge')
#' @param base       MFN base the floor subtracts; REQUIRED for floor modes. Pass
#'   the ORIGINAL base for floor_static, the POST-MFN base for floor_post_mfn
#'   (resolve_rate()'s floor_base says which). Vectorized.
#' @return numeric additional duty.
apply_rate_semantics <- function(value, rate_type = 'surcharge', base = NA_real_) {
  rate_type <- rate_type %||% 'surcharge'
  if (!rate_type %in% RATE_TYPES) stop('apply_rate_semantics: unknown rate_type: ', rate_type)
  v <- as.numeric(value)
  if (rate_type %in% c('floor_static', 'floor_post_mfn')) {
    # A missing base where the value is in-scope means the floor delta is
    # uncomputable — fail loud rather than letting pmax(NA) coalesce to 0 (a silent
    # "no extra duty"). Shape-aware: a scalar base recycles over v; a vectorized
    # base must be non-NA at every position where v is non-NA.
    base_missing <- if (length(base) == 1L) rep(is.na(base), length(v)) else is.na(base)
    if (any(base_missing & !is.na(v)))
      stop('apply_rate_semantics: rate_type=', rate_type, ' requires a numeric base')
    out <- pmax(0, v - base)
  } else if (rate_type == 'passthrough') {
    out <- numeric(length(v))
  } else {                 # surcharge
    out <- v
  }
  out[is.na(out)] <- 0
  out
}

#' Validate a program's compositional rate field.
#' Fail-loud, in the spirit of validate_authority_spec.
validate_rate <- function(rate, ctx) {
  if (is.null(rate)) return(invisible(TRUE))
  if (!is.list(rate)) stop(sprintf('[%s] rate must be a list', ctx))

  allowed <- c('default', 'by_country', 'default_unlisted_rate', 'default_unlisted',
               'overrides', 'by_product_tier', 'target_total', 'rate_type',
               'flat', 'product_overrides_file', 'floors',
               # Plank 4b (IEEPA de-blob): per-country reciprocal companions to
               # by_country. by_country_type promotes the per-country rate-semantics
               # tag to the schema (decision 2; surcharge|floor|passthrough — the
               # calc's ieepa_type, NOT a RATE_TYPES label). by_country_eo_rate /
               # by_country_eo_ch99 carry the country-EO two-term components
               # (decision 1) so the calc can bypass the universal exempt for the
               # EO contribution while applying the EO's own exempt list.
               # default_unlisted_exclude removes census codes from the
               # default_unlisted complement (decision 3; IEEPA CA/MX carve-out).
               # carveouts is the fentanyl product×country lower-rate layer.
               'by_country_type', 'by_country_eo_rate', 'by_country_eo_ch99',
               'default_unlisted_exclude', 'carveouts')
  unknown <- setdiff(names(rate), allowed)
  unknown <- unknown[nzchar(unknown)]
  if (length(unknown)) stop(sprintf('[%s] unknown rate field(s): %s', ctx,
                                    paste(unknown, collapse = ', ')))

  rt <- .rate_get(rate, 'rate_type')
  if (!is.null(rt) && !(length(rt) == 1L && rt %in% RATE_TYPES))
    stop(sprintf('[%s] invalid rate_type: %s (allowed: %s)', ctx,
                 paste(rt, collapse = '/'), paste(RATE_TYPES, collapse = ', ')))

  chk_scalar <- function(x, nm) {
    if (is.null(x)) return(invisible())
    if (is.character(x)) stop(sprintf('[%s] rate$%s must be numeric', ctx, nm))
    if (!is.numeric(x) || length(x) != 1L || !is.finite(x) || x < 0)
      stop(sprintf('[%s] rate$%s must be a single finite non-negative number', ctx, nm))
  }
  chk_named_num <- function(x, nm) {
    if (is.null(x)) return(invisible())
    if (is.character(x)) stop(sprintf('[%s] rate$%s must be numeric', ctx, nm))
    if (is.null(names(x)) || any(!nzchar(names(x))))
      stop(sprintf('[%s] rate$%s must be a NAMED numeric (names = lookup keys)', ctx, nm))
    dups <- unique(names(x)[duplicated(names(x))])
    if (length(dups))
      stop(sprintf('[%s] rate$%s has duplicate key(s): %s (resolve_rate would silently first-win)',
                   ctx, nm, paste(dups, collapse = ', ')))
    vals <- suppressWarnings(as.numeric(unlist(x)))
    if (!length(vals) || any(is.na(vals)) || any(!is.finite(vals)) || any(vals < 0))
      stop(sprintf('[%s] rate$%s values must be finite non-negative numbers', ctx, nm))
  }
  chk_scalar(.rate_get(rate, 'default'),               'default')
  chk_scalar(.rate_get(rate, 'default_unlisted_rate'), 'default_unlisted_rate')
  chk_scalar(.rate_get(rate, 'default_unlisted'),      'default_unlisted')
  chk_scalar(.rate_get(rate, 'target_total'),          'target_total')
  chk_scalar(.rate_get(rate, 'flat'),                  'flat')  # add_program new-coverage rate
  chk_named_num(.rate_get(rate, 'by_country'),         'by_country')
  chk_named_num(.rate_get(rate, 'by_product_tier'),    'by_product_tier')

  ov <- .rate_get(rate, 'overrides')
  if (!is.null(ov)) {
    if (!is.list(ov)) stop(sprintf('[%s] rate$overrides must be a list', ctx))
    onames <- names(ov)
    for (i in seq_along(ov)) {
      o  <- ov[[i]]
      nm <- if (!is.null(onames)) onames[i] else ''
      if (is.list(o)) {                              # entry form: {products|scope, [countries], rate}
        r <- o$rate
        if (is.null(r) || !is.numeric(r) || length(r) != 1L || !is.finite(r) || r < 0)
          stop(sprintf('[%s] rate$overrides[[%d]]$rate must be a single finite non-negative number', ctx, i))
        prods <- o$products %||% o$product
        if (is.null(prods) || !length(unlist(prods))) {
          # scope-form (Plank 4a/S2 deals): a product SCOPE LABEL the calc expands at run
          # time (no enumerated products). resolve_rate auto-skips it (no products -> hit_p
          # FALSE), so it is reader-invisible; the calc reads it via s232_deal_records().
          if (is.null(o$scope) || !is.character(o$scope) || !nzchar(as.character(o$scope)[1]))
            stop(sprintf('[%s] rate$overrides[[%d]] needs non-empty products OR a scope label', ctx, i))
        }
      } else if (is.numeric(o) && length(o) == 1L) { # named-scalar form: product -> rate
        if (!nzchar(nm))
          stop(sprintf('[%s] rate$overrides[[%d]] scalar form needs a product-code name', ctx, i))
        if (!is.finite(o) || o < 0)
          stop(sprintf('[%s] rate$overrides[%s] must be a finite non-negative number', ctx, nm))
      } else {
        stop(sprintf('[%s] rate$overrides[[%d]] must be a {products,rate} list or a named numeric scalar', ctx, i))
      }
    }
  }

  # floors (Plank 4a/S2 deals): a list of {scope, countries, floor} entries the calc applies
  # as pmax(floor - base, 0) vs the ORIGINAL base. Reader-invisible (resolve_rate never reads
  # rate$floors); read by the calc via s232_deal_records().
  fl <- .rate_get(rate, 'floors')
  if (!is.null(fl)) {
    if (!is.list(fl)) stop(sprintf('[%s] rate$floors must be a list', ctx))
    for (i in seq_along(fl)) {
      f <- fl[[i]]
      if (!is.list(f))
        stop(sprintf('[%s] rate$floors[[%d]] must be a {scope, countries, floor} list', ctx, i))
      fr <- f$floor
      if (is.null(fr) || !is.numeric(fr) || length(fr) != 1L || !is.finite(fr) || fr < 0)
        stop(sprintf('[%s] rate$floors[[%d]]$floor must be a single finite non-negative number', ctx, i))
      if (is.null(f$scope) || !is.character(f$scope) || !nzchar(as.character(f$scope)[1]))
        stop(sprintf('[%s] rate$floors[[%d]] needs a non-empty scope label', ctx, i))
    }
  }

  # Plank 4b (IEEPA reciprocal de-blob). These ride alongside by_country (same
  # census-code names) but are read by the calc, not resolve_rate.
  IEEPA_TYPES <- c('surcharge', 'floor', 'passthrough')
  bct <- .rate_get(rate, 'by_country_type')
  if (!is.null(bct)) {
    if (!is.character(bct) || is.null(names(bct)) || any(!nzchar(names(bct))))
      stop(sprintf('[%s] rate$by_country_type must be a NAMED character (names = census codes)', ctx))
    if (any(!bct %in% IEEPA_TYPES))
      stop(sprintf('[%s] rate$by_country_type values must be one of: %s', ctx,
                   paste(IEEPA_TYPES, collapse = ', ')))
  }
  chk_named_num(.rate_get(rate, 'by_country_eo_rate'), 'by_country_eo_rate')
  beoc <- .rate_get(rate, 'by_country_eo_ch99')
  if (!is.null(beoc)) {
    if (!is.character(beoc) || is.null(names(beoc)) || any(!nzchar(names(beoc))))
      stop(sprintf('[%s] rate$by_country_eo_ch99 must be a NAMED character (NA allowed)', ctx))
  }
  due <- .rate_get(rate, 'default_unlisted_exclude')
  if (!is.null(due) && !is.character(due))
    stop(sprintf('[%s] rate$default_unlisted_exclude must be a character vector of census codes', ctx))

  # carveouts (Plank 4b/S2 fentanyl): per-ch99 x census carve-out rates as three
  # equal-length parallel vectors {ch99_code, census_code, rate}. The calc joins
  # ch99_code to the hts8 carve-out product CSV. Reader-invisible to resolve_rate.
  cvo <- .rate_get(rate, 'carveouts')
  if (!is.null(cvo)) {
    if (!is.list(cvo) || is.null(cvo$ch99_code) || is.null(cvo$census_code) || is.null(cvo$rate))
      stop(sprintf('[%s] rate$carveouts must be a list with ch99_code/census_code/rate', ctx))
    n <- length(cvo$ch99_code)
    if (length(cvo$census_code) != n || length(cvo$rate) != n)
      stop(sprintf('[%s] rate$carveouts vectors must be equal length', ctx))
    if (!is.character(cvo$ch99_code) || !is.character(cvo$census_code))
      stop(sprintf('[%s] rate$carveouts ch99_code/census_code must be character', ctx))
    if (!is.numeric(cvo$rate) || any(!is.finite(cvo$rate)) || any(cvo$rate < 0))
      stop(sprintf('[%s] rate$carveouts$rate must be finite non-negative numbers', ctx))
  }

  invisible(TRUE)
}

# ---- predicates -------------------------------------------------------------

is_authority_spec      <- function(x) inherits(x, 'authority_spec')
is_authority_program   <- function(x) inherits(x, 'authority_program')
is_authority_spec_set  <- function(x) inherits(x, 'authority_spec_set')

# ---- validation (fail loud; decision 5 / doc operations rules) --------------

#' Validate a single authority spec. Stops on the first structural violation.
validate_authority_spec <- function(spec) {
  if (!is_authority_spec(spec)) stop('not an authority_spec: ', spec$authority %||% '<?>')
  a <- spec$authority

  sc <- spec$stacking$class %||% NA_character_
  if (!is.na(sc) && !sc %in% STACKING_CLASSES) {
    stop(sprintf('[%s] invalid stacking.class: %s (allowed: %s)',
                 a, sc, paste(STACKING_CLASSES, collapse = ', ')))
  }
  if (!is.null(spec$usmca_treatment) && !spec$usmca_treatment %in% USMCA_TREATMENTS) {
    stop(sprintf('[%s] invalid usmca_treatment: %s', a, spec$usmca_treatment))
  }

  for (p in spec$programs) {
    if (!is_authority_program(p)) stop(sprintf('[%s] program is not an authority_program', a))
    # Resolve the program's effective stacking class (own override or authority default)
    pcls <- (p$stacking$class %||% spec$stacking$class) %||% NA_character_
    if (!is.na(pcls) && !pcls %in% STACKING_CLASSES) {
      stop(sprintf('[%s/%s] invalid stacking.class: %s', a, p$id, pcls))
    }
    # primary_metal REQUIRES a real metal.type (doc decision: hard error otherwise)
    if (identical(pcls, 'primary_metal')) {
      mt <- p$metal$type %||% NA_character_
      if (is.na(mt) || identical(mt, 'none')) {
        stop(sprintf('[%s/%s] stacking.class=primary_metal requires metal.type (got %s)',
                     a, p$id, mt))
      }
    }
    if (!is.null(p$metal) && !is.null(p$metal$type) && !p$metal$type %in% METAL_TYPES) {
      stop(sprintf('[%s/%s] invalid metal.type: %s', a, p$id, p$metal$type))
    }
    if (!is.list(p$settings))
      stop(sprintf('[%s/%s] settings must be a list', a, p$id))
    validate_rate(p$rate, sprintf('%s/%s', a, p$id %||% '?'))
  }
  invisible(TRUE)
}

#' Validate a whole spec set. Also checks program-id uniqueness within authority.
validate_spec_set <- function(specs) {
  if (!is_authority_spec_set(specs) && !is.list(specs)) stop('not a spec set')
  for (spec in specs) {
    validate_authority_spec(spec)
    ids <- vapply(spec$programs, function(p) p$id %||% NA_character_, character(1))
    dup <- ids[duplicated(ids)]
    if (length(dup)) stop(sprintf('[%s] duplicate program id(s): %s',
                                  spec$authority, paste(unique(dup), collapse = ', ')))
  }
  invisible(TRUE)
}

# ---- printing ---------------------------------------------------------------

print.authority_spec <- function(x, ...) {
  cat(sprintf('<authority_spec> %s | stacking=%s | usmca=%s | %d program(s)\n',
              x$authority, x$stacking$class %||% '?', x$usmca_treatment %||% '?',
              length(x$programs)))
  for (p in x$programs) {
    cls <- (p$stacking$class %||% x$stacking$class) %||% '?'
    cat(sprintf('   - %-18s scope=%s rate=%s stacking=%s%s\n',
                p$id,
                if (identical(p$country_scope$include, 'all')) 'all-countries'
                  else paste0(length(p$country_scope$include %||% list()), ' countries'),
                paste(names(p$rate), collapse = ','),
                cls,
                if (!is.null(p$metal$type)) paste0(' metal=', p$metal$type) else ''))
  }
  invisible(x)
}

print.authority_spec_set <- function(x, ...) {
  cat(sprintf('<authority_spec_set> %d authorities: %s\n',
              length(x), paste(names(x), collapse = ', ')))
  for (s in x) print(s)
  invisible(x)
}
