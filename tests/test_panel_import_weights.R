# =============================================================================
# panel-keyed import weights — unit tests
# =============================================================================
#
# Pure-logic checks for src/build_panel_import_weights.R on tiny synthetic
# fixtures — no model data, runs in seconds. Covers the two acceptance criteria
# that must always hold (value conservation; every output code on the panel),
# the HS8 -> HS6 -> HS4 -> HS2 -> whole-panel redistribution cascade, the
# country-preserving split, the crosswalk shape (split_weight sums to 1 per
# old code), and the orchestrator's parquet round-trip + output schema.
#
# Usage (via Slurm / module load, per project convention — not on the login node):
#   bash -lc 'module load R/4.4.2-gfbf-2024a; Rscript tests/test_panel_import_weights.R'
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(dplyr)
  library(arrow)
})

source(here('src', 'build_panel_import_weights.R'))   # functions; CLI block is sys.nframe()-guarded

pass_count <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass_count <<- pass_count + 1L
  cat('  ok:', msg, '\n')
}
approx <- function(a, b, tol = 1e-9) abs(a - b) <= tol * max(1, abs(b))

# =============================================================================
# Fixture: a panel with two headings + one extra chapter, and a base that
# exercises every mapping path.
# =============================================================================
# Panel headings: 12345600 (suffixes 0030, 0090) and 65432100 (one code).
# Plus an unrelated chapter-77 code so the whole-panel fallback has somewhere
# to land.
panel <- c('1234560030', '1234560090', '6543210000', '7777880011')

base <- tibble::tibble(
  hs10 = c('1234560020',  # RETIRED suffix; heading 12345600 (HS8) -> 0030/0090
           '1234560030',  # exact match (anchors the HS8 split toward 0030)
           '6543210000',  # exact match, different country
           '1234569999',  # orphan, heading 12345699 absent -> recovers at HS6 123456
           '8888880000'), # orphan, chapter 88 absent -> whole-panel fallback
  cty_code = c('5700', '5700', '1220', '5700', '2010'),
  imports  = c(100,    50,     400,    30,     7)
)

res <- forward_map_imports(base, panel)
w  <- res$weights
st <- res$stats
xw <- res$crosswalk

# --- AC2: value conservation -------------------------------------------------
check(approx(st$total_in, sum(base$imports)),  'total_in equals base total')
check(approx(st$total_out, st$total_in),       'AC2: total imports conserved through the forward-map')

# --- AC1 / AC4: every output code on the panel, one row per (hts10,country) --
check(all(w$hts10 %in% panel),                 'AC1: every output hts10 is in the panel universe')
check(anyDuplicated(w[c('hts10','cty_code')]) == 0, 'AC4: no duplicate (hts10, country) keys')
check(all(w$imports > 0),                      'no zero/negative import rows emitted')

# --- HS8 redistribution: retired 0020 -> the successor with matched value ----
# 1234560020 ($100, 5700) goes to 12345600; only 0030 has matched value (50),
# so all $100 lands on 0030. Plus its own $50 + the HS6 orphan $30 = $180.
v_0030_5700 <- w %>% filter(hts10 == '1234560030', cty_code == '5700') %>% pull(imports)
check(approx(v_0030_5700, 180),                'HS8/HS6 value routes to the matched successor suffix (0030)')
check(!('1234560090' %in% w$hts10),            'never-traded successor (0090) gets no value when a traded sibling exists')

# --- country is preserved (Canada value stays on Canada) ---------------------
v_654_1220 <- w %>% filter(hts10 == '6543210000', cty_code == '1220') %>% pull(imports)
check(approx(v_654_1220, 400),                 'matched value preserved on its own country (1220)')

# --- whole-panel fallback: chapter-88 orphan split by anchor, stays on 2010 --
mex <- w %>% filter(cty_code == '2010')
check(approx(sum(mex$imports), 7),             'whole-panel fallback conserves the orphan value on its country')
check(st$n_global_fallback == 1,               'exactly one code hit the whole-panel fallback')
check(all(c(0L, 6L, 8L) %in% st$per_level$level), 'per-level diagnostics record HS8, HS6, and whole-panel')

# --- crosswalk shape: split_weight sums to 1 per old code, all targets > 0 ---
sums <- xw %>% group_by(old_hts10) %>% summarise(s = sum(split_weight), .groups = 'drop')
check(all(approx(sums$s, 1)),                  'crosswalk split_weight sums to 1 per old_hts10')
check(all(xw$split_weight > 0),                'crosswalk drops zero-weight candidates')
check(all(xw$new_hts10 %in% panel),            'crosswalk targets are all panel codes')

# =============================================================================
# Orchestrator: parquet round-trip + output schema + stamped columns
# =============================================================================
tmp <- tempfile('piw_'); dir.create(tmp)
on.exit(unlink(tmp, recursive = TRUE), add = TRUE)

# write the base as the canonical RDS the loader expects (with a GTAP col to
# prove it is collapsed away)
base_rds <- file.path(tmp, 'base.rds')
saveRDS(base %>% mutate(gtap_code = 'xxx'), base_rds)

out <- build_panel_import_weights(
  panel_codes = panel, base_path = base_rds, out_dir = file.path(tmp, 'weights'),
  year = 2024L, hts_vintage = '2026_rev_9')

pq <- file.path(tmp, 'weights', 'import_weights_hs10_country.parquet')
check(file.exists(pq),                                       'parquet written')
check(file.exists(file.path(tmp, 'weights', 'import_weights_hs10_country.csv.gz')),
                                                             'csv.gz sibling written')
check(file.exists(file.path(tmp, 'weights', 'hts10_revision_crosswalk.csv')),
                                                             'crosswalk csv written')
rt <- as.data.frame(read_parquet(pq))
check(identical(names(rt), c('hts10','country','imports','import_value_year','hts_vintage')),
                                                             'output schema is exactly the documented columns')
check(approx(sum(rt$imports), sum(base$imports)),            'round-tripped parquet conserves total value')
check(all(rt$import_value_year == 2024L),                    'import_value_year stamped')
check(all(rt$hts_vintage == '2026_rev_9'),                   'hts_vintage stamped')
check(!('gtap_code' %in% names(rt)),                         'no GTAP/BEA columns in the published file')

# =============================================================================
# panel_universe_from_snapshots: reads hts10 union, ignores metadata.rds
# =============================================================================
snaps <- file.path(tmp, 'vintage', 'actual', 'snapshots')
d1 <- file.path(snaps, 'valid_from=2025-01-01'); dir.create(d1, recursive = TRUE)
d2 <- file.path(snaps, 'valid_from=2025-02-01'); dir.create(d2, recursive = TRUE)
write_parquet(tibble::tibble(hts10 = c('1234560030','6543210000'), revision = 'r1',
                             valid_from = as.Date('2025-01-01')),
              file.path(d1, 'rates.parquet'))
write_parquet(tibble::tibble(hts10 = c('6543210000','7777880011'), revision = 'r2',
                             valid_from = as.Date('2025-02-01')),
              file.path(d2, 'rates.parquet'))
saveRDS(list(x = 1), file.path(snaps, 'metadata.rds'))   # must be ignored, not parsed as parquet

uni <- panel_universe_from_snapshots(snaps)
check(setequal(uni, c('1234560030','6543210000','7777880011')),
                                                             'panel universe (union) = all hts10 across snapshots')
cur <- current_panel_codes(snaps)
check(setequal(cur, c('6543210000','7777880011')),
                                                             'current_panel_codes = ONLY the latest interval (tip) codes')
check(identical(tip_revision_from_snapshots(snaps), 'r2'),   'tip revision = latest valid_from interval')

cat('\nAll', pass_count, 'checks passed.\n')
