# =============================================================================
# Tests: 484(f) versioned-identity weight mapper (pure; arrow-free, CI-safe)
# =============================================================================
#
# Pins crosswalk_map_imports() + validate_mapped_weights() in
# src/io/build_panel_import_weights.R on tiny synthetic fixtures — no arrow, no
# model data. Covers: identity / rename / split by each share tier / merge /
# two-date chain / same-date reuse / a reused successor whose misleading 2025 +
# 2024 self-history must NOT be used / hts_as_of_date gating / no_successor ->
# residual cascade / each prefix level / global-fallback prohibition / overall +
# per-country conservation / per-country split normalization.
#
# The arrow round-trip + output schema stays in test_panel_import_weights.R.
#
# Usage: module load R/4.4.2-gfbf-2024a; Rscript tests/test_crosswalk_mapper.R
# =============================================================================

suppressPackageStartupMessages({ library(here); library(dplyr); library(tidyr) })
source(here('src', 'io', 'build_panel_import_weights.R'))  # CLI is sys.nframe()-guarded

pass <- 0L; fail <- 0L
check <- function(cond, msg) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat('  ok:', msg, '\n') }
  else { fail <<- fail + 1L; cat('  FAIL:', msg, '\n') }
}
approx <- function(a, b, tol = 1e-9) isTRUE(abs(a - b) <= tol * max(1, abs(b)))
expect_error_matching <- function(expr, pattern) {
  m <- tryCatch({ force(expr); NULL }, error = function(e) conditionMessage(e))
  !is.null(m) && grepl(pattern, m, ignore.case = TRUE)
}

b  <- function(...) tibble(hs10 = c(...))       # convenience
edge <- function(old, new, date, reuse = FALSE)
  tibble(old_hts10 = old, new_hts10 = new, effective_date = date, same_date_reuse = reuse)

# --- fixtures ----------------------------------------------------------------
# Countries A='1111', B='2222'.
base <- tibble::tribble(
  ~hs10,          ~cty_code, ~imports,
  '1111111100',   '1111',    100,        # identity (stays)
  '2222220010',   '1111',    200,        # rename -> 2222220020
  '3333330010',   '1111',    400,        # split by 2025 country shares
  '4444440010',   '1111',     50,        # merge -> 4444440030
  '4444440020',   '1111',     70,        #   "
  '5555550010',   '1111',    300,        # two-date chain -> ...020 -> ...030
  '6666660010',   '1111',    160,        # same-date reuse (2026) -> even
  '7777770010',   '1111',    240,        # 2026 split; successor has misleading 2025+2024
  '7777770030',   '1111',    999,        # <- OLD identity's 2024 value on a reused number
  '8888880010',   '1111',     80,        # no_successor -> residual cascade to HS8 sibling
  '9999990010',   '2222',    120)        # untouched orphan -> prefix cascade (HS8)

panel <- c('1111111100', '2222220020', '3333330020', '3333330030',
           '4444440030', '5555550030', '6666660010', '6666660020',
           '7777770020', '7777770030', '8888880020', '9999990020')

xwalk <- bind_rows(
  edge('2222220010', '2222220020', '2025-01-01'),
  edge('3333330010', '3333330020', '2025-07-01'),
  edge('3333330010', '3333330030', '2025-07-01'),
  edge('4444440010', '4444440030', '2025-07-01'),
  edge('4444440020', '4444440030', '2025-07-01'),
  edge('5555550010', '5555550020', '2024-07-01'),
  edge('5555550020', '5555550030', '2025-07-01'),
  edge('6666660010', '6666660010', '2026-02-01', reuse = TRUE),  # re-established
  edge('6666660010', '6666660020', '2026-02-01'),
  edge('7777770010', '7777770020', '2026-01-01'),
  edge('7777770010', '7777770030', '2026-01-01'),
  edge('8888880010', NA,           '2025-07-01'))                # no_successor

# 2025 shares: 3333330020 : 3333330030 = 300 : 100 (country A). Plus a MISLEADING
# 2025 value on 7777770030 (belongs to the old identity of that reused number).
shares <- tibble::tribble(
  ~hs10,          ~cty_code, ~imports,
  '3333330020',   '1111',    300,
  '3333330030',   '1111',    100,
  '7777770030',   '1111',    5000)   # must be IGNORED (2026-established identity)

run <- function(as_of = '2026-12-31', shr = shares)
  crosswalk_map_imports(base, panel, xwalk, shr, hts_as_of_date = as_of)

# =============================================================================
cat('\n=== conservation + basic contract ===\n')
m <- run()
check(approx(m$stats$total_out, sum(base$imports)), 'overall value conserved')
check(all(m$weights$hts10 %in% panel), 'all output codes on the panel')
check(anyDuplicated(m$weights[c('hts10','cty_code')]) == 0, 'no duplicate keys')
cty_out <- m$weights %>% group_by(cty_code) %>% summarise(v = sum(imports), .groups='drop')
cty_in  <- base %>% group_by(cty_code) %>% summarise(v = sum(imports), .groups='drop')
check(approx(cty_out$v[cty_out$cty_code=='1111'], cty_in$v[cty_in$cty_code=='1111']) &&
      approx(cty_out$v[cty_out$cty_code=='2222'], cty_in$v[cty_in$cty_code=='2222']),
      'per-country value conserved')

w <- function(code, cty='1111') { r <- m$weights %>% filter(hts10==code, cty_code==cty); if(nrow(r)) r$imports else 0 }

cat('\n=== identity / rename / merge ===\n')
check(approx(w('1111111100'), 100), 'identity code unchanged')
check(approx(w('2222220020'), 200), 'rename moved full value to successor')
check(approx(w('4444440030'), 120), 'merge accumulated both predecessors (50+70)')

cat('\n=== split by 2025 country shares (tier i) ===\n')
check(approx(w('3333330020'), 300) && approx(w('3333330030'), 100),
      'split 400 by 2025 country shares 300:100 -> 300/100')
src <- m$composed %>% filter(base_hts10=='3333330010') %>% pull(share_source) %>% unique()
check(all(src == 'country_2025_identity_valid'), 'share_source = country_2025_identity_valid')

cat('\n=== two-date chain (2024-07 then 2025-07) ===\n')
check(approx(w('5555550030'), 300), 'chain moved value across two dates to final code')

cat('\n=== same-date reuse (2026) -> even, no consumption of created mass ===\n')
check(approx(w('6666660010'), 80) && approx(w('6666660020'), 80),
      'same-date reuse split 160 evenly (2026 -> ineligible for 2025/2024)')

cat('\n=== reused successor: misleading 2025 + 2024 self-history NOT used ===\n')
# 7777770010 (240) splits to ...020 and ...030 at 2026-01-01. ...030 carries a
# huge 2025 share (5000) and a 2024 anchor (999) under its OLD identity; a
# 2026-established identity must ignore both -> even 120/120.
check(approx(w('7777770020'), 120) && approx(w('7777770030', '1111') - 999, 120),
      '2026 split ignores reused-number 2025+2024 history -> even 120/120')
s7 <- m$composed %>% filter(base_hts10=='7777770010') %>% pull(share_source) %>% unique()
check(all(s7 == 'even_fallback'), 'reused-successor split labeled even_fallback')

cat('\n=== no_successor + orphan -> residual prefix cascade (HS8) ===\n')
check(approx(w('8888880020'), 80), 'no_successor value cascaded to HS8 sibling')
check(approx(w('9999990020','2222'), 120), 'untouched orphan cascaded to HS8 sibling')
check(any(grepl('prefix_cascade', m$stats$per_source$share_source)), 'cascade share_source recorded')
check((m$stats$n_global_fallback %||% 0) == 0, 'no global fallback used')

cat('\n=== hts_as_of_date gating ===\n')
m_early <- run(as_of = '2025-01-15')   # only the 2025-01-01 rename + 2024-07 chain step apply
# The 2025-07 split is gated out, so 3333330010 is NOT split by transfer; it
# reaches its (still-panel) HS8 siblings via the residual cascade instead.
src_early <- m_early$composed %>% filter(base_hts10 == '3333330010') %>%
  pull(share_source) %>% unique()
check(length(src_early) > 0 && all(grepl('prefix_cascade', src_early)),
      'gated-out 2025-07 split falls to prefix cascade, not country_2025')
check(approx(m_early$stats$total_out, sum(base$imports)), 'gated map still conserves value')

cat('\n=== per-country split normalization ===\n')
norm <- m$composed %>% group_by(base_hts10, cty_code) %>%
  summarise(s = sum(split_weight), .groups='drop')
check(all(approx_vec <- abs(norm$s - 1) < 1e-9), 'composed split_weight sums to 1 per (base, cty)')

cat('\n=== validate_mapped_weights: global fallback prohibited ===\n')
# A base code in a chapter with NO panel code -> global fallback -> must fail.
base_g <- bind_rows(base, tibble(hs10='0101010101', cty_code='1111', imports=10))
cty_in_g <- base_g %>% group_by(cty_code) %>% summarise(v = sum(imports), .groups='drop')
mg <- crosswalk_map_imports(base_g, panel, xwalk, shares, hts_as_of_date='2026-12-31')
check(mg$stats$n_global_fallback == 1, 'unmatched-chapter code counted as global fallback')
check(expect_error_matching(
  validate_mapped_weights(mg$weights, panel, cty_in_g, sum(base_g$imports),
                          n_global_fallback = mg$stats$n_global_fallback),
  'global fallback'), 'global-fallback code triggers validate_mapped_weights failure')

cat('\n=== hts_as_of_date is required (never Sys.Date()) ===\n')
check(expect_error_matching(crosswalk_map_imports(base, panel, xwalk, shares),
                            'hts_as_of_date is required'), 'missing hts_as_of_date errors')

cat('\n=== prefix-method regression (forward_map_imports still valid) ===\n')
fm <- forward_map_imports(base %>% select(hs10, cty_code, imports), panel)
check(approx(sum(fm$weights$imports), sum(base$imports)) && all(fm$weights$hts10 %in% panel),
      'legacy prefix method conserves value and lands on panel')

cat('\n', strrep('=', 60), '\n', sprintf('crosswalk mapper tests: %d passed, %d failed', pass, fail), '\n', sep='')
if (fail > 0) quit(status = 1)
