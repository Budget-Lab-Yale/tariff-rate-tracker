# =============================================================================
# test_hts_2026_rev20_rev21_ingest.R — HTS 2026 rev_20 / rev_21 ingest
# =============================================================================
# rev_20 (policy-dated 2026-09-29) revises pharma §232 note 40 for its turn-on
# and adds 9903.04.70; its JSON is reconstructed from rev_21. rev_21 is note
# text only (ch 38 errata; note 20(vvv)(i)(20) moves a §301 exclusion to
# 8479.90.9591).
#
# Asserted:
#   * both archives exist; rev_20 == rev_21 record for record, and the only
#     difference from rev_19 is the 9903.04.70 heading;
#   * 9903.04.70 classifies as section_232 and parses at +0%;
#   * revision_dates: rev_20 policy-dated 09-29, rev_21 at 10-09;
#   * every code in resources/s232_pharma_products.csv exists in rev_21
#     (the rev_19 list carried nine retired statistical numbers);
#   * the curated 8479909591 exclusion line is in the lines file.
#
# Usage: Rscript tests/test_hts_2026_rev20_rev21_ingest.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse); library(here); library(jsonlite)
})
suppressMessages({
  source(here('src', 'core', 'helpers.R'))
  source(here('src', 'core', 'logging.R'))
  source(here('src', 'model', 'revisions.R'))
  source(here('src', 'pipeline', '03_parse_chapter99.R'))
  source(here('src', 'model', 'rate_schema.R'))
})

pass <- 0L; fail <- 0L
ok <- function(cond, msg) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat('  PASS: ', msg, '\n') }
  else { fail <<- fail + 1L; cat('  FAIL: ', msg, '\n') }
}

archive <- function(rev) here('data', 'hts_archives', sprintf('hts_2026_rev_%d.json.gz', rev))
read_archive <- function(rev) fromJSON(archive(rev), simplifyVector = FALSE)
codes_of <- function(rows) vapply(rows, function(r) r$htsno %||% '', character(1))

cat('\n== archives ==\n')
ok(all(file.exists(archive(19:21))), 'rev_19, rev_20, rev_21 archives present')
ok(file.exists(here('data', 'hts_archives', 'hts_2026_rev_20.PROVENANCE.txt')),
   'rev_20 PROVENANCE sidecar present')
r19 <- read_archive(19); r20 <- read_archive(20); r21 <- read_archive(21)
ok(identical(r20, r21), 'reconstructed rev_20 == rev_21 record for record')
c19 <- codes_of(r19); c20 <- codes_of(r20)
ok(identical(setdiff(c20, c19), '9903.04.70') && !length(setdiff(c19, c20)),
   'rev_19 -> rev_20 adds only 9903.04.70')

cat('\n== 9903.04.70 ==\n')
ok(classify_authority('9903.04.70') == 'section_232', '9903.04.70 -> section_232')
ch20 <- suppressMessages(parse_chapter99(archive(20)))
r70 <- ch20$rate[ch20$ch99_code == '9903.04.70']
ok(length(r70) == 1 && isTRUE(all.equal(r70, 0)), '9903.04.70 parses at +0%')

cat('\n== revision_dates ==\n')
rd <- suppressMessages(load_revision_dates())
row20 <- rd[rd$revision == '2026_rev_20', ]
row21 <- rd[rd$revision == '2026_rev_21', ]
ok(nrow(row20) == 1 && row20$effective_date == as.Date('2026-09-29'),
   'rev_20 policy-dated 2026-09-29 (owns the pharma turn-on)')
ok(nrow(row21) == 1 && row21$effective_date == as.Date('2026-10-09'),
   'rev_21 effective 2026-10-09')

cat('\n== pharma note 40(c) list ==\n')
pharma <- read_csv(here('resources', 's232_pharma_products.csv'),
                   col_types = cols(.default = col_character()))$hts10
hts10_21 <- gsub('.', '', c20[nchar(gsub('.', '', c20, fixed = TRUE)) == 10], fixed = TRUE)
ok(length(pharma) == 149 && !anyDuplicated(pharma), '149 distinct HTS-10 lines')
missing <- setdiff(pharma, hts10_21)
ok(!length(missing),
   paste0('every listed line exists in rev_21',
          if (length(missing)) paste0(' (missing: ', paste(missing, collapse = ', '), ')') else ''))

cat('\n== §301 exclusion lines ==\n')
lines <- read_csv(here('resources', 's301_exclusion_lines.csv'),
                  col_types = cols(.default = col_character()))
ok(any(lines$ch99_code == '9903.88.69' & lines$hts10 == '8479909591'),
   '9903.88.69 covers 8479909591 (note 20(vvv)(i)(20), rev_21)')

cat(sprintf('\n== SUMMARY: %d passed, %d failed ==\n', pass, fail))
if (fail > 0) quit(status = 1)
