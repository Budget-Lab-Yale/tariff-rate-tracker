# =============================================================================
# Tests: HTML markup must not defeat the base-rate parser
# =============================================================================
# USITC's exported `general` field intermittently trails stray markup. The rate
# VALUE is unaffected — `2.5% <u></u>` in 2026 revisions 12 and 15 is a clean
# `2.5%` in revision 13 — but every rate matcher anchors on `^[0-9.]+%$`, so an
# unstripped tag demoted 21 HTS10s (motor-vehicle parts, bicycles, bicycle
# parts) to base_rate_type 'other' with base_rate 0. The net-of-MFN arms then
# subtracted that zero, overstating rate_232 by the MFN amount (15% charged
# where 12.5% is correct) while the total roughly survived — which is why it
# went unnoticed until a partition-parity run.
#
# The archive scan is the point of this file. Fixtures are clean, so a
# fixture-only test passes while the bug is live; the invariant has to be
# asserted against the schedule as USITC actually ships it.
#
# Usage: Rscript tests/test_rate_parse_markup.R
# =============================================================================

suppressPackageStartupMessages({
  library(here); library(dplyr); library(jsonlite); library(stringr)
})
source(here('src', 'core', 'helpers.R'))

pass <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:  ', msg, '\n', sep = '')
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# --- 1. The exact strings observed in the schedule ----------------------------
cat('\n--- observed markup forms ---\n')
observed <- list(
  list(s = '2.5% <u></u>', rate = 0.025, type = 'ad_valorem'),
  list(s = '2.5%<u></u>',  rate = 0.025, type = 'ad_valorem'),  # no space
  list(s = '2.5%',         rate = 0.025, type = 'ad_valorem'),  # rev_13 form
  list(s = '3.7% <u></u>', rate = 0.037, type = 'ad_valorem'),
  list(s = '10% <u></u>',  rate = 0.100, type = 'ad_valorem'),
  list(s = '6% </il>',     rate = 0.060, type = 'ad_valorem')   # malformed tag
)
for (o in observed) {
  check(isTRUE(all.equal(parse_rate(o$s), o$rate)),
        sprintf('parse_rate("%s") == %s', o$s, format(o$rate)))
  check(identical(classify_rate_type(o$s), o$type),
        sprintf('classify_rate_type("%s") == %s', o$s, o$type))
}
check(is_simple_rate('2.5% <u></u>'), 'is_simple_rate() sees through markup')
check(identical(classify_rate_type('Free <u></u>'), 'free'),
      'a marked-up "Free" still classifies as free')

# --- 2. Markup must not create false ad valorem -------------------------------
cat('\n--- non-ad-valorem rates keep their classification ---\n')
check(identical(classify_rate_type('$1.50/doz <u></u>'), 'specific_or_compound'),
      'a marked-up specific rate stays specific_or_compound')
check(identical(classify_rate_type('2.4¢/kg + 5% <u></u>'), 'specific_or_compound'),
      'a marked-up compound rate stays specific_or_compound')
check(is.na(classify_rate_type('<u></u>')),
      'a string that is ONLY markup is empty, not a rate')
check(is.na(parse_rate('<u></u>')),
      'parse_rate() returns NA for markup-only text')

# --- 3. The invariant, over the real archives ---------------------------------
# Any ch1-97 line whose general text normalises to a bare percentage MUST
# classify as ad_valorem. This is what was silently false.
cat('\n--- archive scan ---\n')
archive_dir <- here('data', 'hts_archives')
revisions <- load_revision_dates(here('config', 'revision_dates.csv'),
                                 use_policy_dates = FALSE)$revision
scanned <- 0L
offenders_total <- 0L

for (rev in revisions) {
  path <- tryCatch(resolve_json_path(rev, archive_dir), error = function(e) NULL)
  if (is.null(path)) next

  recs <- fromJSON(path, simplifyVector = FALSE)
  hts <- vapply(recs, function(r) gsub('[^0-9]', '', as.character(r$htsno %||% '')),
                character(1))
  gen <- vapply(recs, function(r) as.character(r$general %||% ''), character(1))
  chapter <- suppressWarnings(as.integer(substr(hts, 1, 2)))

  keep <- nzchar(hts) & !is.na(chapter) & chapter >= 1 & chapter <= 97 &
    nzchar(trimws(gen))
  if (!any(keep)) next

  g <- gen[keep]
  looks_adval <- str_detect(normalize_schedule_text(g), '^[0-9.]+%$')
  offenders <- looks_adval & classify_rate_type(g) != 'ad_valorem'
  offenders_total <- offenders_total + sum(offenders)

  if (any(offenders)) {
    cat('   ', rev, ': ', sum(offenders), ' offending line(s), e.g. "',
        g[offenders][1], '"\n', sep = '')
  }
  scanned <- scanned + 1L
  rm(recs, hts, gen, g); invisible(gc(verbose = FALSE))
}

check(scanned >= 2,
      sprintf('scanned at least 2 archives (scanned %d) — a zero-archive run would pass vacuously',
              scanned))
check(offenders_total == 0,
      sprintf('no ch1-97 line normalising to a bare N%% classifies as non-ad_valorem (across %d archives)',
              scanned))

cat(sprintf('\nALL %d MARKUP-PARSE ASSERTIONS PASSED\n', pass))
