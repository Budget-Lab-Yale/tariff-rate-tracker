# =============================================================================
# Tests: HTS 2026 rev_13 / rev_15 ingest acceptance (combined plan Phase 2 §7)
# =============================================================================
# Guards the shape of the July-August 2026 ingest, whose defining feature is a
# GAP: revision 14 (published 2026-07-31) codified the §232 pharmaceutical
# action, but its JSON is permanently unobtainable. The decision was to add NO
# 2026_rev_14 build row — the archive-driven pipeline silently SKIPS a
# configured revision with no archive, so a real row would quietly shorten the
# series — and to represent the July 31 policy state with the synthetic
# bnd_2026-07-31 boundary owned by rev_13.
#
# That arrangement is easy to "tidy" into a bug later by adding the missing row
# back, so each acceptance criterion is asserted here rather than confirmed once
# by hand:
#   (a) real partitions at 07-28 and 08-03, synthetic 07-31 owned by rev_13,
#       and NO rev_14 row;
#   (c) both surviving rev_14 sources (its Chapter 99 PDF) and the rev_15
#       archive carry the pharmaceutical headings 9903.04.60-.69;
#   (d) rev_15 is rate-neutral against rev_14 apart from the UK correction —
#       its change record lists exactly one modified item, and the resulting
#       UK rate is zero in both the schedule and the config.
#
# Criterion (b), "all earlier partitions remain identical", is a build-parity
# question and is NOT covered here — it needs a candidate build compared against
# the published vintage (plan §3 test 13).
#
# PDF-backed checks skip when pdftools cannot load. On the cluster that means
# the poppler module is missing, NOT that the package needs installing:
#   module load R/4.4.2-gfbf-2024a poppler/25.07.0-GCC-13.3.0
#
# Usage: Rscript tests/test_hts_2026_rev13_rev15_ingest.R
# =============================================================================

suppressPackageStartupMessages({
  library(here); library(dplyr); library(jsonlite)
})
source(here('src', 'core', 'helpers.R'))

pass <- 0L; skip <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:  ', msg, '\n', sep = '')
}
note_skip <- function(msg) { skip <<- skip + 1L; cat('  SKIP: ', msg, '\n', sep = '') }

PHARMA_HEADINGS <- sprintf('9903.04.%d', 60:69)
UK_HEADING      <- '9903.04.63'

rd <- load_revision_dates()
pp <- load_policy_params()

# --- (a) Partition structure --------------------------------------------------
cat('\n--- (a) partition structure ---\n')

check(!'2026_rev_14' %in% rd$revision,
      'no 2026_rev_14 row in revision_dates.csv (its JSON is unobtainable; a row would be silently skipped)')

for (spec in list(c('2026_rev_13', '2026-07-28'), c('2026_rev_15', '2026-08-03'))) {
  row <- rd %>% filter(revision == spec[1])
  check(nrow(row) == 1 && as.Date(row$effective_date[1]) == as.Date(spec[2]),
        sprintf('%s is a real revision dated %s', spec[1], spec[2]))
}

boundaries <- discover_boundaries(rd, here('data', 'timeseries'), pp,
                                  overrides = pp$BOUNDARY_OVERRIDES,
                                  horizon = as.Date('2026-12-31'))
jul31 <- boundaries %>% filter(date == as.Date('2026-07-31'))
check(nrow(jul31) == 1, 'the 2026-07-31 policy boundary is minted')
check(nrow(jul31) == 1 && jul31$owner_rev[1] == '2026_rev_13',
      'bnd_2026-07-31 is owned by 2026_rev_13 (it stands in for the missing rev_14 partition)')

# --- (c) Pharmaceutical headings in both surviving sources --------------------
cat('\n--- (c) pharmaceutical headings present in both sources ---\n')

rev15 <- fromJSON(resolve_json_path('2026_rev_15', here('data', 'hts_archives')),
                  simplifyVector = FALSE)
rev15_hts <- vapply(rev15, function(r) as.character(r$htsno %||% ''), character(1))
check(all(PHARMA_HEADINGS %in% rev15_hts),
      sprintf('all 10 headings %s-.69 are in the rev_15 archive', PHARMA_HEADINGS[1]))

uk_row <- rev15[[which(rev15_hts == UK_HEADING)[1]]]
uk_general <- gsub('[[:space:]]+', ' ', as.character(uk_row$general %||% ''))

have_pdftools <- requireNamespace('pdftools', quietly = TRUE)
rev14_ch99 <- here('data', 'hts_change_record', 'Chapter 99_2026HTSRev14.pdf')

if (!have_pdftools) {
  note_skip('rev_14 Chapter 99 PDF checks (pdftools cannot load — load the poppler module)')
} else if (!file.exists(rev14_ch99)) {
  note_skip('rev_14 Chapter 99 PDF checks (PDF not present)')
} else {
  rev14_text <- paste(pdftools::pdf_text(rev14_ch99), collapse = ' ')
  rev14_flat <- gsub('[[:space:]]+', ' ', rev14_text)
  missing14 <- PHARMA_HEADINGS[!vapply(PHARMA_HEADINGS,
                                       function(h) grepl(h, rev14_flat, fixed = TRUE),
                                       logical(1))]
  check(length(missing14) == 0,
        sprintf('all 10 headings appear in the rev_14 Chapter 99 PDF%s',
                if (length(missing14)) paste0(' (MISSING: ', paste(missing14, collapse = ', '), ')') else ''))
}

# --- (d) rev_15 rate-neutral except the UK correction -------------------------
cat('\n--- (d) rev_15 rate-neutrality and the UK correction ---\n')

# Config side: the UK pharma rate must be zero. Note 40(g) carries no
# net-of-MFN arm, so a nonzero country_rate here overstates UK pharma duty by
# that amount — the error rev_15 corrected.
uk_cfg <- pp$section_232_headings$pharmaceuticals$country_rates$CTY_UK
check(!is.null(uk_cfg) && is.numeric(uk_cfg) && uk_cfg == 0,
      sprintf('config pharmaceuticals country_rates CTY_UK is 0 (found: %s)',
              if (is.null(uk_cfg)) 'NULL' else format(uk_cfg)))

# Schedule side: heading 9903.04.63 charges the applicable subheading + 0%.
check(grepl('\\+\\s*0\\s*%', uk_general),
      sprintf('rev_15 %s charges +0%% (found: "%s")', UK_HEADING, uk_general))

change_record <- here('data', 'hts_change_record', 'Change Record_2026HTSRev15.pdf')
if (!have_pdftools) {
  note_skip('rev_15 change-record checks (pdftools cannot load — load the poppler module)')
} else if (!file.exists(change_record)) {
  note_skip('rev_15 change-record checks (PDF not present)')
} else {
  cr_flat <- gsub('[[:space:]]+', ' ', paste(pdftools::pdf_text(change_record), collapse = ' '))
  # The change record's own table is the primary evidence for rate-neutrality:
  # one item changed, and it is the UK heading.
  changed <- unique(regmatches(cr_flat, gregexpr('9903\\.[0-9]{2}\\.[0-9]{2}', cr_flat))[[1]])
  check(identical(changed, UK_HEADING),
        sprintf('rev_15 change record lists exactly one changed item, %s (found: %s)',
                UK_HEADING, paste(changed, collapse = ', ')))
  check(grepl('Modified \\(rates of duty\\)', cr_flat),
        'the change is recorded as "Modified (rates of duty)"')
}

cat(sprintf('\nALL %d rev_13/rev_15 INGEST ASSERTIONS PASSED (%d skipped)\n', pass, skip))
