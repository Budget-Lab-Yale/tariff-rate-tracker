# =============================================================================
# M0 step 2: China Section 301 parity across the rev_12 -> rev_13 ingest
# =============================================================================
#
# HTS 2026 rev_13 dropped the "See 9903.88.15."-style Chapter 99 cross-reference
# endnotes (9903.88.* fell 10,319 -> 5 across ch1-97 footnotes). M0 step 3
# established the deletion is a REAL upstream removal, not an export defect
# (per-release chapter PDFs agree with the JSON code-for-code; see
# config/footnote_waivers.csv). Step 2 is the remaining question: does it move
# any computed rate?
#
# The code trace says it should not. build_s301_tiers() reads
# resources/s301_product_lists.csv, and apply_section301() takes exclusion scope
# from resources/s301_exclusion_lines.csv (06_calculate_rates.R:1299-1315) —
# both durable inputs, neither dependent on snapshot footnotes. This script
# proves it on built snapshots rather than by reading the code.
#
# Compares the two revisions on the columns the footnote path could plausibly
# move, restricted to China, and reports any HTS10 whose rate differs.
#
# Expected: base tiers and exclusion-adjusted rates identical. The forced-labor
# action (U.S. note 52, effective 2026-07-24) is a SEPARATE authority that
# rev_13 codifies; it lands in rate_301_forced_labor, not the China 301 columns,
# and rev_13's own snapshot date (2026-07-28) is after its turn-on. Any movement
# there is documented policy, not footnote loss.
#
# Usage: Rscript scripts/verify_m0_s301_parity.R [scratch_dir]
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})

args <- commandArgs(trailingOnly = TRUE)
scratch_dir <- if (length(args) >= 1) args[1] else here('data', 'timeseries', 'scratch')

FROM_REV <- '2026_rev_12'
TO_REV   <- '2026_rev_13'
CHINA    <- '5700'   # country code used across the rate columns

# Named explicitly rather than pattern-matched. A regex over names() looks
# tidier and silently missed rate_s301fl / rate_s301br on the first run, which
# turned the forced-labor report into an empty block that read like "nothing
# moved" when it actually meant "nothing was looked at".
CHINA_301_COLS <- c('rate_301', 'rate_301_cs',
                    'statutory_rate_301', 'statutory_rate_301_cs')
FL_COLS        <- c('rate_s301fl', 'statutory_rate_s301fl')
BRAZIL_COLS    <- c('rate_s301br', 'statutory_rate_s301br')

pass <- 0L; fail <- 0L
check <- function(cond, msg) {
  if (isTRUE(cond)) {
    pass <<- pass + 1L; cat('  ok:  ', msg, '\n', sep = '')
  } else {
    fail <<- fail + 1L; cat('  FAIL:', msg, '\n', sep = '')
  }
}

read_snapshot <- function(rev) {
  path <- file.path(scratch_dir, paste0('snapshot_', rev, '.rds'))
  if (!file.exists(path)) {
    stop('Missing snapshot: ', path,
         '\n  Build it first: Rscript scripts/rebuild_one_revision.R ', rev)
  }
  readRDS(path)
}

a <- read_snapshot(FROM_REV)
b <- read_snapshot(TO_REV)

cat('\n=== M0 step 2: Section 301 parity, ', FROM_REV, ' -> ', TO_REV, ' ===\n', sep = '')
cat('  ', FROM_REV, ': ', nrow(a), ' rows | ', TO_REV, ': ', nrow(b), ' rows\n', sep = '')

# --- Columns must be present, not merely matched ------------------------------
missing <- setdiff(c(CHINA_301_COLS, FL_COLS), intersect(names(a), names(b)))
check(length(missing) == 0,
      paste0('all audited rate columns present in both snapshots',
             if (length(missing)) paste0(' (MISSING: ', paste(missing, collapse = ', '), ')') else ''))
if (length(missing) > 0) {
  stop('Cannot verify: absent column(s) ', paste(missing, collapse = ', '),
       '. A renamed column would otherwise make this script pass by comparing nothing.')
}

china_cols <- CHINA_301_COLS
cat('  China §301 columns compared: ', paste(china_cols, collapse = ', '), '\n', sep = '')

key <- c('hts10', 'country')
stopifnot(all(key %in% names(a)), all(key %in% names(b)))

china_a <- a %>% filter(country == CHINA) %>% select(all_of(c(key, china_cols)))
china_b <- b %>% filter(country == CHINA) %>% select(all_of(c(key, china_cols)))
cat('  China rows: ', nrow(china_a), ' -> ', nrow(china_b), '\n', sep = '')

check(nrow(china_a) > 0, 'China rows present in both snapshots')
check(setequal(china_a$hts10, china_b$hts10),
      'China HTS10 coverage is identical (no lines gained or dropped)')

joined <- inner_join(china_a, china_b, by = key, suffix = c('_from', '_to'))

# --- Per-column parity -------------------------------------------------------
for (col in china_cols) {
  from <- joined[[paste0(col, '_from')]]
  to   <- joined[[paste0(col, '_to')]]
  # NA must match NA: a footnote-driven scope loss would surface as a value
  # becoming NA, which a naive numeric comparison would silently skip.
  differs <- xor(is.na(from), is.na(to)) |
    (!is.na(from) & !is.na(to) & abs(from - to) > 1e-9)
  n_diff <- sum(differs)
  if (n_diff > 0) {
    cat('    ', col, ': ', n_diff, ' differing China rows\n', sep = '')
    print(joined[differs, c(key, paste0(col, c('_from', '_to')))] %>% head(15))
  }
  check(n_diff == 0, sprintf('%s unchanged across the ingest (China)', col))
}

# --- Aggregate, the check §3 test 13 calls out specifically -------------------
for (col in china_cols) {
  s_from <- sum(joined[[paste0(col, '_from')]], na.rm = TRUE)
  s_to   <- sum(joined[[paste0(col, '_to')]], na.rm = TRUE)
  cat(sprintf('  aggregate %-28s %.6f -> %.6f  (delta %+.6f)\n',
              col, s_from, s_to, s_to - s_from))
  check(abs(s_to - s_from) < 1e-6,
        sprintf('%s China aggregate unchanged', col))
}

# --- POSITIVE CONTROL --------------------------------------------------------
# "Nothing changed" is only meaningful if this comparison could have detected a
# change. rev_13 codifies the §301 forced-labor action (U.S. note 52, effective
# 2026-07-24); rev_12 is dated 07-21 and rev_13 07-28, so the layer must switch
# on across exactly this boundary. If it does not, the two snapshots are more
# alike than the ingest warrants and the China result above proves nothing.
#
# Counted per snapshot rather than through the join: a full 4.9M-row join on
# every column is the one step that would need real memory.
cat('\n  Positive control — the ingest must move SOMETHING:\n')
for (col in c(FL_COLS, BRAZIL_COLS)) {
  if (!col %in% names(a) || !col %in% names(b)) next
  nz_from <- sum(a[[col]] > 0, na.rm = TRUE)
  nz_to   <- sum(b[[col]] > 0, na.rm = TRUE)
  cat(sprintf('    %-26s nonzero rows (all countries): %d -> %d\n', col, nz_from, nz_to))
}

fl_from <- sum(a[['rate_s301fl']] > 0, na.rm = TRUE)
fl_to   <- sum(b[['rate_s301fl']] > 0, na.rm = TRUE)
check(fl_to > fl_from,
      sprintf('forced-labor layer turns ON across the ingest (%d -> %d nonzero rows) — confirms this comparison detects movement',
              fl_from, fl_to))

cat('\n', strrep('=', 60), '\n', sep = '')
cat('M0 step 2: ', pass, ' passed, ', fail, ' failed\n', sep = '')
cat(strrep('=', 60), '\n')
if (fail > 0) {
  quit(status = 1L)
}
