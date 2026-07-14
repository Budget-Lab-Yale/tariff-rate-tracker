# =============================================================================
# Tests: 484(f) crosswalk archive-coverage validation
# =============================================================================
#
# Pins validate_484f_coverage() and its helpers in tools/build_484f_crosswalk.R:
#   - discover_hts_archives()  (json + json.gz discovery, dedup)
#   - archive_ordinary_hts10() (10-digit ordinary-merchandise universe, ch98/99 out)
#   - has_directed_cycle()     (same-date cycle detection)
#   - validate_484f_coverage() (disappearance/establishment coverage both ways,
#                               documented exceptions, pre-panel HS8 classing)
#
# Fixtures are synthesized into a tempdir at runtime (tiny HTS archive JSONs,
# a revision_dates CSV, a weight-base .rds) so no binary blobs are committed and
# json-vs-json.gz discovery is exercised directly.
#
# CI-safe: needs jsonlite + tidyverse; no pdftools, no network, no build data.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})

source(here('tools', 'build_484f_crosswalk.R'))

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

expect_error_matching <- function(expr, pattern) {
  msg <- tryCatch({ force(expr); NULL }, error = function(e) conditionMessage(e))
  if (is.null(msg)) stop('expected an error, none raised')
  if (!grepl(pattern, msg, ignore.case = TRUE)) {
    stop(sprintf('error did not match /%s/: %s', pattern, msg))
  }
}

# --- fixture construction ----------------------------------------------------

# Write one HTS archive file (list of {htsno} records) for `codes` (dotted
# 10-digit) plus optional 8-digit-only lines and a chapter-99 line (to prove
# exclusion). `formats` chooses .json, .json.gz, or both.
write_archive <- function(dir, year, rev, codes, eight = character(),
                          formats = 'json') {
  recs <- c(lapply(c(codes, eight), function(h) list(htsno = h)),
            list(list(htsno = '9903.01.01.00')))   # ch99 — must be excluded
  json <- jsonlite::toJSON(recs, auto_unbox = TRUE)
  base <- file.path(dir, sprintf('hts_%d_%s', year, rev))
  if ('json' %in% formats) writeLines(json, paste0(base, '.json'))
  if ('gz'   %in% formats) {
    con <- gzfile(paste0(base, '.json.gz'), 'w'); writeLines(json, con); close(con)
  }
}

td <- file.path(tempdir(), paste0('cov484f_', Sys.getpid()))
dir.create(td, showWarnings = FALSE, recursive = TRUE)

# Universe (ordinary 10-digit dotted). A renamed at rev_1; B split at rev_2.
A  <- '0101.21.00.10'; A2 <- '0101.21.00.30'
B  <- '0101.21.00.20'; B1 <- '0101.21.00.40'; B2 <- '0101.21.00.50'
C  <- '0202.10.00.10'
strip <- function(x) gsub('.', '', x, fixed = TRUE)

write_archive(td, 2025L, 'basic', c(A, B, C),        formats = 'json')
write_archive(td, 2025L, 'rev_1', c(A2, B, C),       formats = c('json', 'gz'))  # dedup
write_archive(td, 2025L, 'rev_2', c(A2, B1, B2, C),  formats = 'gz')             # gz only

rd_path <- file.path(td, 'revision_dates.csv')
readr::write_csv(tibble(
  revision = c('basic', 'rev_1', 'rev_2'),
  effective_date = c('2025-01-01', '2025-02-01', '2025-03-01')), rd_path)

# Full, correct crosswalk covering every observed transition.
mk_transfers <- function(rows) {
  # rows: list of c(old, new, date, change_type)
  tibble(
    old_hts10 = map_chr(rows, 1), new_hts10 = map_chr(rows, 2),
    effective_date = map_chr(rows, 3), change_type = map_chr(rows, 4),
    same_date_reuse = FALSE)
}
transfers_ok <- mk_transfers(list(
  c(strip(A), strip(A2), '2025-02-01', 'rename'),
  c(strip(B), strip(B1), '2025-03-01', 'split'),
  c(strip(B), strip(B2), '2025-03-01', 'split')))

empty_exceptions <- file.path(td, 'no_exceptions.csv')
readr::write_csv(tibble(hts10 = character(), direction = character(),
                        transition_to = character(), reason = character(),
                        evidence = character(), approved_by = character()),
                 empty_exceptions)

# =============================================================================
message('\n=== archive discovery (json + json.gz, dedup) ===')

run_test('discover_hts_archives dedups rev_1 (both formats) to one row', {
  d <- discover_hts_archives(td)
  stopifnot(nrow(d) == 3, setequal(d$revision, c('basic', 'rev_1', 'rev_2')))
})
run_test('archive_ordinary_hts10 excludes chapter 99 and reads gz', {
  u_basic <- archive_ordinary_hts10(resolve_archive_path(td, 2025L, 'basic'))
  u_rev2  <- archive_ordinary_hts10(resolve_archive_path(td, 2025L, 'rev_2'))
  stopifnot(setequal(u_basic, strip(c(A, B, C))),   # no 9903...
            setequal(u_rev2, strip(c(A2, B1, B2, C))))
})

# =============================================================================
message('\n=== coverage both directions ===')

run_test('full crosswalk covers every disappearance and establishment', {
  cov <- validate_484f_coverage(transfers_ok, archive_dir = td,
    revision_dates_path = rd_path, exceptions_path = empty_exceptions,
    weight_base_path = NULL, strict = TRUE)
  stopifnot(nrow(cov$uncovered_disappeared) == 0,
            nrow(cov$uncovered_established) == 0,
            nrow(cov$transitions) == 2)
})

run_test('missing rename edge -> uncovered disappearance AND establishment fail', {
  transfers_gap <- transfers_ok %>% filter(!(old_hts10 == strip(A)))
  expect_error_matching(
    validate_484f_coverage(transfers_gap, archive_dir = td,
      revision_dates_path = rd_path, exceptions_path = empty_exceptions,
      weight_base_path = NULL, strict = TRUE),
    'uncovered (disappearance|establishment)')
})

run_test('non-strict reports uncovered without aborting', {
  transfers_gap <- transfers_ok %>% filter(!(old_hts10 == strip(A)))
  cov <- validate_484f_coverage(transfers_gap, archive_dir = td,
    revision_dates_path = rd_path, exceptions_path = empty_exceptions,
    weight_base_path = NULL, strict = FALSE)
  stopifnot(strip(A) %in% cov$uncovered_disappeared$hts10,
            strip(A2) %in% cov$uncovered_established$hts10)
})

# =============================================================================
message('\n=== documented exceptions (used / stale) ===')

exc_path <- file.path(td, 'exceptions.csv')
readr::write_csv(tibble(
  hts10 = c(strip(A), strip(A2)),
  direction = c('disappeared', 'established'),
  transition_to = c('rev_1', 'rev_1'),
  reason = 'snapshot_artifact', evidence = 'test', approved_by = 'test'),
  exc_path)

run_test('documented exceptions absorb the uncovered churn', {
  transfers_gap <- transfers_ok %>% filter(!(old_hts10 == strip(A)))
  cov <- validate_484f_coverage(transfers_gap, archive_dir = td,
    revision_dates_path = rd_path, exceptions_path = exc_path,
    weight_base_path = NULL, strict = TRUE)
  stopifnot(all(cov$exceptions_used$used))
})

run_test('stale exception (nothing uncovered) fails', {
  # transfers_ok leaves NOTHING uncovered, so both exceptions are stale.
  expect_error_matching(
    validate_484f_coverage(transfers_ok, archive_dir = td,
      revision_dates_path = rd_path, exceptions_path = exc_path,
      weight_base_path = NULL, strict = TRUE),
    'stale coverage exception')
})

# =============================================================================
message('\n=== same-date cycle detection ===')

run_test('has_directed_cycle: A->B->A is a cycle; a chain is not', {
  stopifnot(has_directed_cycle(c('a', 'b'), c('b', 'a')),          # 2-cycle
            !has_directed_cycle(c('a', 'b'), c('b', 'c')),         # chain
            !has_directed_cycle(c('a', 'a2', 'a3'), c('a2','a3','a4')))
})

run_test('validate flags a same-date directed cycle', {
  transfers_cycle <- bind_rows(transfers_ok, mk_transfers(list(
    c(strip(A2), strip(B), '2025-03-01', 'rename'),
    c(strip(B),  strip(A2), '2025-03-01', 'rename'))))
  expect_error_matching(
    validate_484f_coverage(transfers_cycle, archive_dir = td,
      revision_dates_path = rd_path, exceptions_path = empty_exceptions,
      weight_base_path = NULL, strict = TRUE),
    'cycle')
})

# =============================================================================
message('\n=== pre-panel HS8 classification (cascade vs vanished) ===')

# Weight base: A,B,C present; D (vanished HS8 0303.11.00) + E (cascade — shares
# HS8 0202.10.00 with C, which survives in basic) both absent from basic.
D <- '0303.11.00.10'; E <- '0202.10.00.20'
base_path <- file.path(td, 'weight_base_2024.rds')
saveRDS(tibble(
  hs10 = strip(c(A, B, C, D, E)),
  gtap_code = 'x', cty_code = '1220',
  imports = c(10, 10, 10, 5e7, 3e7)), base_path)

run_test('cascade-eligible (HS8 persists) is non-fatal; vanished-HS8 is fatal', {
  expect_error_matching(
    validate_484f_coverage(transfers_ok, archive_dir = td,
      revision_dates_path = rd_path, exceptions_path = empty_exceptions,
      weight_base_path = base_path, basic_revision = 'basic', strict = TRUE),
    'vanished HS8')
})

run_test('documenting the vanished-HS8 code passes; E stays cascade-classed', {
  van_exc <- file.path(td, 'exceptions_prepanel.csv')
  readr::write_csv(tibble(
    hts10 = strip(D), direction = 'disappeared', transition_to = 'basic',
    reason = 'base_data_artifact', evidence = 'test', approved_by = 'test'),
    van_exc)
  cov <- validate_484f_coverage(transfers_ok, archive_dir = td,
    revision_dates_path = rd_path, exceptions_path = van_exc,
    weight_base_path = base_path, basic_revision = 'basic', strict = TRUE)
  stopifnot(nrow(cov$prepanel_missing) == 0)
  cascade_n <- cov$prepanel_summary %>% filter(klass == 'cascade') %>% pull(n)
  stopifnot(length(cascade_n) == 1, cascade_n == 1)   # E only
})

# =============================================================================
message('\n', strrep('=', 70))
message(sprintf('484(f) coverage tests: %d passed, %d failed', pass_count, fail_count))
message(strrep('=', 70))

unlink(td, recursive = TRUE)
if (fail_count > 0) quit(status = 1)
