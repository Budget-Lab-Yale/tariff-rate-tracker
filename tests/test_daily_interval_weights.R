# =============================================================================
# Tests: Per-interval import weights in the daily series (Phase 4)
# =============================================================================
#
# Exercises the provider contract (build_daily_aggregates imports_fn), the
# interval-local weight context, make_interval_weights_fn's fingerprint, and the
# fingerprinted daily-part cache (schema v2).
#
# Base-R stopifnot() assertions, no external framework. CI-safe: uses only
# in-memory / tempfile fixtures (no built artifacts, no arrow, no pdftools).
#
# Usage: Rscript tests/test_daily_interval_weights.R
# =============================================================================

library(tidyverse)
library(here)
suppressMessages({
  source(here('src', 'core', 'helpers.R'))
  source(here('src', 'model', 'rate_schema.R'))
  source(here('src', 'pipeline', '09_daily_series.R'))
  source(here('src', 'io', 'build_panel_import_weights.R'))
})

pass_count <- 0
fail_count <- 0
run_test <- function(name, expr) {
  tryCatch({
    force(expr)
    message('  PASS: ', name)
    pass_count <<- pass_count + 1
  }, error = function(e) {
    message('  FAIL: ', name, ' — ', conditionMessage(e))
    fail_count <<- fail_count + 1
  })
}

# --- fixtures ----------------------------------------------------------------

# One revision slice: `products` x `cty` with a single IEEPA-recip rate.
mk_rev <- function(rev, products, cty, rate, eff, vfrom, vuntil) {
  expand_grid(hts10 = products, country = cty) %>%
    mutate(
      revision = rev,
      base_rate = 0.05, statutory_base_rate = 0.05,
      rate_232 = 0, rate_301 = 0, rate_ieepa_recip = rate,
      rate_ieepa_fent = 0, rate_s122 = 0, rate_section_201 = 0,
      rate_other = 0, metal_share = 0, usmca_eligible = FALSE,
      total_additional = rate, total_rate = 0.05 + rate,
      effective_date = as.Date(eff),
      valid_from = as.Date(vfrom), valid_until = as.Date(vuntil)
    )
}

# imports tibble (hs10, cty_code, imports)
mk_w <- function(rows) {
  tibble(hs10 = sapply(rows, `[[`, 1),
         cty_code = sapply(rows, `[[`, 2),
         imports = as.numeric(sapply(rows, `[[`, 3)))
}

fake_fp <- function(ctx) {
  list(method = 'test', mapper_schema_version = 1L,
       base_sha256 = 'BASE', shares_sha256 = NA_character_,
       crosswalk_sha256 = 'XW', overrides_sha256 = NA_character_,
       hts_as_of_date = as.character(as.Date(ctx$hts_as_of_date)),
       target_code_hash = digest::digest(sort(unique(as.character(ctx$panel_codes)))))
}

# A provider returning fixed weights per revision.
const_imports_fn <- function(weights_by_rev) {
  function(ctx) {
    rev <- as.character(ctx$revision)
    w <- weights_by_rev[[rev]]
    if (is.null(w)) stop('const_imports_fn: no weights for ', rev)
    list(weights = w, stats = list(), fingerprint = fake_fp(ctx))
  }
}

DR <- c(as.Date('2026-01-01'), as.Date('2026-12-31'))

# =============================================================================
# 1. Provider parity: imports_fn with a constant weight set reproduces the
#    static `imports` path field-for-field.
# =============================================================================
message('\n--- 1: static vs imports_fn parity (same weights) ---')

run_test('imports_fn == static imports, all daily tables', {
  ts <- mk_rev('rev_b', c('0101010000'), c('1111', '2222'), 0.10,
               '2026-06-01', '2026-06-01', '2026-12-31')
  W <- mk_w(list(list('0101010000', '1111', 100),
                 list('0101010000', '2222', 50),
                 list('0909090000', '1111', 25)))  # untariffed: denominator only
  d_static <- suppressMessages(build_daily_aggregates(ts, date_range = DR, imports = W))
  fn <- const_imports_fn(list(rev_b = W))
  d_fn <- suppressMessages(build_daily_aggregates(
    ts, date_range = DR, imports_fn = fn,
    hts_as_of_dates = list(rev_b = as.Date('2026-06-01'))))
  for (tbl in c('daily_overall', 'daily_by_country', 'daily_by_authority',
                'daily_by_category', 'daily_by_hs')) {
    stopifnot(isTRUE(all.equal(d_static[[tbl]], d_fn[[tbl]])))
  }
  # matched < total (untariffed code sits only in the denominator)
  stopifnot(abs(d_fn$daily_overall$total_imports_b[1] - 175 / 1e9) < 1e-15)
  stopifnot(abs(d_fn$daily_overall$matched_imports_b[1] - 150 / 1e9) < 1e-15)
})

# =============================================================================
# 2. Mutual-exclusion / required-arg guards
# =============================================================================
message('\n--- 2: provider-contract guards ---')

run_test('imports + imports_fn together errors', {
  ts <- mk_rev('rev_b', '0101010000', '1111', 0.10, '2026-06-01', '2026-06-01', '2026-12-31')
  W <- mk_w(list(list('0101010000', '1111', 100)))
  err <- tryCatch({
    build_daily_aggregates(ts, imports = W, imports_fn = const_imports_fn(list(rev_b = W)),
                           hts_as_of_dates = list(rev_b = as.Date('2026-06-01')))
    NULL
  }, error = function(e) conditionMessage(e))
  stopifnot(!is.null(err), grepl('at most one', err))
})

run_test('imports_fn without hts_as_of_dates errors', {
  ts <- mk_rev('rev_b', '0101010000', '1111', 0.10, '2026-06-01', '2026-06-01', '2026-12-31')
  W <- mk_w(list(list('0101010000', '1111', 100)))
  err <- tryCatch({
    build_daily_aggregates(ts, imports_fn = const_imports_fn(list(rev_b = W)))
    NULL
  }, error = function(e) conditionMessage(e))
  stopifnot(!is.null(err), grepl('hts_as_of_dates', err))
})

# =============================================================================
# 3. Per-interval weights ARE applied around a renumbering transition.
#    rev_a carries product X, rev_b carries the renumbered product Y. A single
#    static tip weight set (Y only) zeroes rev_a; per-interval weights don't.
# =============================================================================
message('\n--- 3: per-interval weights around a transition ---')

run_test('renumbered code weighted in its own interval (not dropped)', {
  ts_a <- mk_rev('rev_a', '0101010000', c('1111', '2222'), 0.10,
                 '2026-01-01', '2026-01-01', '2026-05-31')
  ts_b <- mk_rev('rev_b', '0202020000', c('1111', '2222'), 0.10,
                 '2026-06-01', '2026-06-01', '2026-12-31')
  ts <- bind_rows(ts_a, ts_b)
  W_a <- mk_w(list(list('0101010000', '1111', 100), list('0101010000', '2222', 50),
                   list('0909090000', '1111', 25)))
  W_b <- mk_w(list(list('0202020000', '1111', 100), list('0202020000', '2222', 50),
                   list('0909090000', '1111', 25)))
  aod <- list(rev_a = as.Date('2026-01-01'), rev_b = as.Date('2026-06-01'))

  d_iv <- suppressMessages(build_daily_aggregates(
    ts, date_range = DR, imports_fn = const_imports_fn(list(rev_a = W_a, rev_b = W_b)),
    hts_as_of_dates = aod))
  ov <- d_iv$agg_overall
  etr_a <- ov$weighted_etr[ov$revision == 'rev_a']
  etr_b <- ov$weighted_etr[ov$revision == 'rev_b']
  # Same rate + same $ on both sides of the renumbering => continuous ETR.
  stopifnot(etr_a > 0, etr_b > 0, abs(etr_a - etr_b) < 1e-12)

  # A single static tip weight set (W_b, product Y only) zeroes rev_a's matched
  # imports — the bug the per-interval mapping fixes.
  d_static <- suppressMessages(build_daily_aggregates(ts, date_range = DR, imports = W_b))
  ovs <- d_static$agg_overall
  stopifnot(ovs$weighted_etr[ovs$revision == 'rev_a'] == 0)
  stopifnot(ovs$weighted_etr[ovs$revision == 'rev_b'] > 0)
})

run_test('differing rates across the transition compute independently', {
  ts_a <- mk_rev('rev_a', '0101010000', c('1111', '2222'), 0.10,
                 '2026-01-01', '2026-01-01', '2026-05-31')
  ts_b <- mk_rev('rev_b', '0202020000', c('1111', '2222'), 0.25,
                 '2026-06-01', '2026-06-01', '2026-12-31')
  ts <- bind_rows(ts_a, ts_b)
  W_a <- mk_w(list(list('0101010000', '1111', 100), list('0101010000', '2222', 50)))
  W_b <- mk_w(list(list('0202020000', '1111', 100), list('0202020000', '2222', 50)))
  d <- suppressMessages(build_daily_aggregates(
    ts, date_range = DR, imports_fn = const_imports_fn(list(rev_a = W_a, rev_b = W_b)),
    hts_as_of_dates = list(rev_a = as.Date('2026-01-01'), rev_b = as.Date('2026-06-01'))))
  ov <- d$agg_overall
  stopifnot(ov$weighted_etr[ov$revision == 'rev_b'] >
            ov$weighted_etr[ov$revision == 'rev_a'] + 0.05)
})

run_test('weight_stats carries the per-revision fingerprint', {
  ts <- mk_rev('rev_b', '0101010000', '1111', 0.10, '2026-06-01', '2026-06-01', '2026-12-31')
  W <- mk_w(list(list('0101010000', '1111', 100)))
  d <- suppressMessages(build_daily_aggregates(
    ts, date_range = DR, imports_fn = const_imports_fn(list(rev_b = W)),
    hts_as_of_dates = list(rev_b = as.Date('2026-06-01'))))
  fp <- d$weight_stats[['rev_b']]$fingerprint
  stopifnot(!is.null(fp), fp$hts_as_of_date == '2026-06-01',
            !is.null(fp$target_code_hash))
})

# =============================================================================
# 3b. Weighted rate uses the STORED (effective) total_rate, NOT a re-derivation
#     from base_rate — so trade-preference (USMCA/FTA) duty-free is respected.
# =============================================================================
message('\n--- 3b: weighted rate respects stored exemptions ---')

run_test('USMCA duty-free row contributes its stored 0 rate, not the statutory base', {
  # Same product, two countries: one USMCA duty-free (base 0.5 but stored
  # total_rate 0), one full statutory (stored total_rate 0.5). No policy_params,
  # so no live expiry — the effective helper must keep the stored total_rate.
  ts <- tibble(
    hts10 = '2401106530', country = c('1220', '5700'),
    revision = 'rev_b',
    base_rate = 0.5, statutory_base_rate = 0.5,
    rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0, rate_ieepa_fent = 0,
    rate_s122 = 0, rate_section_201 = 0, rate_other = 0,
    metal_share = 0, usmca_eligible = c(TRUE, FALSE),
    total_additional = 0, total_rate = c(0, 0.5),      # duty-free vs full statutory
    effective_date = as.Date('2026-06-01'),
    valid_from = as.Date('2026-06-01'), valid_until = as.Date('2026-12-31'))
  W <- mk_w(list(list('2401106530', '1220', 100), list('2401106530', '5700', 100)))
  d <- suppressMessages(build_daily_aggregates(ts, date_range = DR, imports = W))
  etr <- d$agg_overall$weighted_etr
  # Stored basis: (0*100 + 0.5*100) / 200 = 0.25.
  # A re-derivation from base_rate would re-charge the duty-free row -> 0.5 (the bug).
  stopifnot(abs(etr - 0.25) < 1e-9)
})

# =============================================================================
# 4. make_interval_weights_fn (real mapper, tiny inputs)
# =============================================================================
message('\n--- 4: make_interval_weights_fn ---')

run_test('provider maps base -> panel, renames to hs10, exposes shared fingerprint', {
  td <- tempfile('ivw_'); dir.create(td)
  base_path <- file.path(td, 'base.rds')
  saveRDS(tibble(hs10 = c('0101010000', '0909090000'),
                 cty_code = c('1111', '1111'),
                 imports = c(100, 25)), base_path)
  xw_path <- file.path(td, 'xw.csv')
  # One committee edge: 0101010000 -> 0202020000 effective 2026-06-01.
  readr::write_csv(tibble(
    old_hts10 = '0101010000', new_hts10 = '0202020000',
    effective_date = '2026-06-01', same_date_reuse = 'false'), xw_path)

  fn <- make_interval_weights_fn(base_path, xw_path)
  sh <- attr(fn, 'shared_fingerprint')
  stopifnot(!is.null(sh), sh$method == '484f', !is.na(sh$base_sha256),
            !is.na(sh$crosswalk_sha256), is.na(sh$shares_sha256))

  # As-of BEFORE the edge: base code stays.
  r0 <- fn(list(revision = 'rev_a', hts_as_of_date = as.Date('2026-01-01'),
                panel_codes = c('0101010000', '0909090000')))
  stopifnot('hs10' %in% names(r0$weights))
  stopifnot('0101010000' %in% r0$weights$hs10)
  stopifnot(!is.null(r0$fingerprint$target_code_hash))

  # As-of AFTER the edge: mass moves to the successor 0202020000.
  r1 <- fn(list(revision = 'rev_b', hts_as_of_date = as.Date('2026-06-01'),
                panel_codes = c('0202020000', '0909090000')))
  stopifnot('0202020000' %in% r1$weights$hs10, !'0101010000' %in% r1$weights$hs10)
  # Conservation: total mass unchanged.
  stopifnot(abs(sum(r1$weights$imports) - 125) < 1e-9)
})

# =============================================================================
# 5. Fingerprint match helper
# =============================================================================
message('\n--- 5: daily_weight_fingerprint_matches ---')

run_test('fingerprint matches / rejects on hash + hts_as_of divergence', {
  shared <- list(method = '484f', mapper_schema_version = 1L,
                 base_sha256 = 'B', shares_sha256 = 'S',
                 crosswalk_sha256 = 'X', overrides_sha256 = 'O')
  ctxt <- list(shared = shared, hts_as_of_dates = list(rev_b = as.Date('2026-06-01')))
  good <- c(shared, list(hts_as_of_date = '2026-06-01', target_code_hash = 'T'))
  stopifnot(daily_weight_fingerprint_matches(good, ctxt, 'rev_b'))

  bad_hash <- good; bad_hash$base_sha256 <- 'DIFFERENT'
  stopifnot(!daily_weight_fingerprint_matches(bad_hash, ctxt, 'rev_b'))

  bad_date <- good; bad_date$hts_as_of_date <- '2026-01-01'
  stopifnot(!daily_weight_fingerprint_matches(bad_date, ctxt, 'rev_b'))

  stopifnot(!daily_weight_fingerprint_matches(NULL, ctxt, 'rev_b'))
  stopifnot(!daily_weight_fingerprint_matches(good, ctxt, 'unknown_rev'))
})

# =============================================================================
# 6. Fingerprinted daily-part cache: combined-vs-parts parity, schema v2,
#    fingerprint-mismatch rejection.
# =============================================================================
message('\n--- 6: fingerprinted daily-part cache ---')

# Shared setup: two revisions, per-interval weights, a temp snapshot_dir.
setup_cache <- function() {
  td <- tempfile('cache_'); dir.create(td)
  ts_a <- mk_rev('rev_a', '0101010000', c('1111', '2222'), 0.10,
                 '2026-01-01', '2026-01-01', '2026-05-31')
  ts_b <- mk_rev('rev_b', '0202020000', c('1111', '2222'), 0.25,
                 '2026-06-01', '2026-06-01', '2026-12-31')
  W_a <- mk_w(list(list('0101010000', '1111', 100), list('0101010000', '2222', 50),
                   list('0909090000', '1111', 25)))
  W_b <- mk_w(list(list('0202020000', '1111', 100), list('0202020000', '2222', 50),
                   list('0909090000', '1111', 25)))
  fn <- const_imports_fn(list(rev_a = W_a, rev_b = W_b))
  aod <- list(rev_a = as.Date('2026-01-01'), rev_b = as.Date('2026-06-01'))
  rev_dates <- tibble(revision = c('rev_a', 'rev_b'),
                      effective_date = as.Date(c('2026-01-01', '2026-06-01')))
  pp <- list(SERIES_HORIZON_END = as.Date('2026-12-31'))
  # Snapshots must predate the parts (loader's mtime staleness check).
  saveRDS(ts_a, file.path(td, 'snapshot_rev_a.rds'))
  saveRDS(ts_b, file.path(td, 'snapshot_rev_b.rds'))
  Sys.sleep(1.1)
  write_daily_part_for_snapshot(ts_a, 'rev_a', '2026-01-01', '2026-05-31', td,
                                imports_fn = fn, hts_as_of_date = aod$rev_a)
  write_daily_part_for_snapshot(ts_b, 'rev_b', '2026-06-01', '2026-12-31', td,
                                imports_fn = fn, hts_as_of_date = aod$rev_b)
  # Must mirror fake_fp() exactly so the correct context matches.
  shared <- list(method = 'test', mapper_schema_version = 1L,
                 base_sha256 = 'BASE', shares_sha256 = NA_character_,
                 crosswalk_sha256 = 'XW', overrides_sha256 = NA_character_)
  list(td = td, ts = bind_rows(ts_a, ts_b), fn = fn, aod = aod,
       rev_dates = rev_dates, pp = pp,
       wctx = list(shared = shared, hts_as_of_dates = aod))
}

run_test('parts carry the current schema version and weight_metadata', {
  s <- setup_cache()
  p <- readRDS(file.path(s$td, 'daily_part_rev_a.rds'))
  stopifnot(identical(as.integer(p$schema_version), as.integer(DAILY_PART_SCHEMA_VERSION)))
  stopifnot(!is.null(p$metadata$weight_metadata))
  stopifnot(p$metadata$weight_metadata$hts_as_of_date == '2026-01-01')
  stopifnot(identical(p$metadata$weight_mode, 'weighted'))
})

run_test('combined build == bound parts (field-for-field)', {
  s <- setup_cache()
  combined <- suppressMessages(build_daily_aggregates(
    s$ts, imports_fn = s$fn, hts_as_of_dates = s$aod))
  parts <- suppressMessages(load_daily_parts_if_complete(
    s$td, s$rev_dates, policy_params = s$pp,
    weight_mode = 'weighted', weight_context = s$wctx))
  stopifnot(!is.null(parts))
  for (tbl in c('daily_overall', 'daily_by_country', 'daily_by_authority',
                'daily_by_hs')) {
    a <- combined[[tbl]] %>% arrange(across(everything()))
    b <- parts[[tbl]] %>% arrange(across(everything()))
    stopifnot(isTRUE(all.equal(a, b, check.attributes = FALSE)))
  }
})

run_test('fingerprint mismatch (changed input hash) rejects the cache', {
  s <- setup_cache()
  bad <- s$wctx; bad$shared$crosswalk_sha256 <- 'CHANGED'
  parts <- suppressMessages(load_daily_parts_if_complete(
    s$td, s$rev_dates, policy_params = s$pp,
    weight_mode = 'weighted', weight_context = bad))
  stopifnot(is.null(parts))
})

run_test('changed hts_as_of_date rejects the cache', {
  s <- setup_cache()
  bad <- s$wctx; bad$hts_as_of_dates$rev_a <- as.Date('2025-01-01')
  parts <- suppressMessages(load_daily_parts_if_complete(
    s$td, s$rev_dates, policy_params = s$pp,
    weight_mode = 'weighted', weight_context = bad))
  stopifnot(is.null(parts))
})

run_test('schema v1 part is rejected', {
  s <- setup_cache()
  p <- readRDS(file.path(s$td, 'daily_part_rev_a.rds'))
  p$schema_version <- 1L
  saveRDS(p, file.path(s$td, 'daily_part_rev_a.rds'))
  Sys.sleep(0.1)
  parts <- suppressMessages(load_daily_parts_if_complete(
    s$td, s$rev_dates, policy_params = s$pp,
    weight_mode = 'weighted', weight_context = s$wctx))
  stopifnot(is.null(parts))
})

run_test('unweighted part carries no weight_metadata and loads without a context', {
  td <- tempfile('cache_uw_'); dir.create(td)
  ts_a <- mk_rev('rev_a', '0101010000', c('1111', '2222'), 0.10,
                 '2026-01-01', '2026-01-01', '2026-12-31')
  rev_dates <- tibble(revision = 'rev_a', effective_date = as.Date('2026-01-01'))
  pp <- list(SERIES_HORIZON_END = as.Date('2026-12-31'))
  saveRDS(ts_a, file.path(td, 'snapshot_rev_a.rds'))
  Sys.sleep(1.1)
  write_daily_part_for_snapshot(ts_a, 'rev_a', '2026-01-01', '2026-12-31', td)
  p <- readRDS(file.path(td, 'daily_part_rev_a.rds'))
  stopifnot(identical(as.integer(p$schema_version), as.integer(DAILY_PART_SCHEMA_VERSION)))
  stopifnot(is.null(p$metadata$weight_metadata))
  stopifnot(identical(p$metadata$weight_mode, 'unweighted'))
  parts <- suppressMessages(load_daily_parts_if_complete(
    td, rev_dates, policy_params = pp, weight_mode = 'unweighted'))
  stopifnot(!is.null(parts))
})

# =============================================================================
message('\n==================================================')
message('Interval-weight tests: ', pass_count, ' passed, ', fail_count, ' failed')
message('==================================================')
if (fail_count > 0) quit(status = 1)
