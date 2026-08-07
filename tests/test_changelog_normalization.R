# =============================================================================
# Tests: changelog text normalization (§3 test 2)
# =============================================================================
# USITC ran a schedule-wide typographic pass across 2026 revisions 13-15
# (italic scientific names, <sup> unit exponents, <br />, one <em style=...>).
# Those edits change no rate, but a raw field diff reports thousands of
# "modified" entries and buries the substantive changes.
#
# Gates normalize_schedule_text() and compare_ch99_full()'s use of it: markup-
# only edits must be classed cosmetic and excluded, while real description and
# rate changes must still come through. Over-normalizing is the failure mode
# that matters most here — it would silently hide a suspension.
#
# Usage: Rscript tests/test_changelog_normalization.R
# =============================================================================

suppressPackageStartupMessages({ library(here); library(dplyr) })
source(here('tools', 'revision_changelog.R'))

pass <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:', msg, '\n')
}

# --- normalize_schedule_text --------------------------------------------------
check(normalize_schedule_text('<i>Prunus persica</i>') == 'Prunus persica',
      'italic tags are stripped')
check(normalize_schedule_text('kg<sup>2</sup>') == 'kg2',
      'a <sup> exponent normalizes to the pre-pass form (kg2)')
check(normalize_schedule_text('first<br />second') == 'first second',
      '<br /> becomes a space, not a word join')
check(normalize_schedule_text('first<br>second') == 'first second',
      'an unclosed <br> also becomes a space')
check(normalize_schedule_text('<em style="color:red">note</em>') == 'note',
      'a tag with attributes is stripped whole')
check(normalize_schedule_text('cotton  &amp;   wool') == 'cotton & wool',
      'entities decode and whitespace squishes')
check(normalize_schedule_text('  padded   text  ') == 'padded text',
      'leading, trailing, and repeated whitespace collapse')
check(normalize_schedule_text('a &lt;b&gt; c') == 'a <b> c',
      'encoded angle brackets survive rather than being re-stripped as a tag')

# Substantive text must NOT normalize away.
check(normalize_schedule_text('Suspended through 2026') !=
        normalize_schedule_text('Effective through 2026'),
      'a real wording change survives normalization')
check(normalize_schedule_text('The duty provided + 10%') !=
        normalize_schedule_text('The duty provided + 15%'),
      'a rate-text change survives normalization')

# --- compare_ch99_full classification -----------------------------------------
ch99_row <- function(code, desc, general) {
  tibble(ch99_code = code, rate = 0.25, authority = 'section_301',
         country_type = 'china', general_raw = general, description = desc)
}

old_ch99 <- bind_rows(
  ch99_row('9903.88.01', 'Articles of <i>Gossypium</i>', 'The duty provided + 25%'),
  ch99_row('9903.88.02', 'Live plants',                  'The duty provided + 25%'),
  ch99_row('9903.88.03', 'Effective through 2026',       'The duty provided + 25%')
)
new_ch99 <- bind_rows(
  # markup-only: italics dropped by the typographic pass
  ch99_row('9903.88.01', 'Articles of Gossypium',        'The duty provided + 25%'),
  # whitespace-only
  ch99_row('9903.88.02', 'Live   plants ',               'The duty provided + 25%'),
  # substantive
  ch99_row('9903.88.03', 'Suspended through 2026',       'The duty provided + 25%')
)

diff <- compare_ch99_full(old_ch99, new_ch99)

check(diff$n_desc_cosmetic == 2,
      'markup-only and whitespace-only description edits are counted as cosmetic')
check(diff$n_desc_changes == 1,
      'only the substantive description edit is reported as a change')
check(identical(diff$desc_changes$ch99_code, '9903.88.03'),
      'the reported change is the suspension, not the typography')
check(isTRUE(diff$desc_changes$was_suspended),
      'the suspension is still flagged after normalization')
check(diff$n_general_changes == 0 && diff$n_general_cosmetic == 0,
      'untouched general text produces neither a change nor a cosmetic count')

# A markup-only edit to general text is cosmetic, and a rate-text edit is not.
general_old <- ch99_row('9903.88.10', 'Widgets', 'The duty provided + 25<sup>%</sup>')
general_new <- ch99_row('9903.88.10', 'Widgets', 'The duty provided + 25%')
general_diff <- compare_ch99_full(general_old, general_new)
check(general_diff$n_general_cosmetic == 1 && general_diff$n_general_changes == 0,
      'a markup-only general-text edit is cosmetic')

rate_text_new <- ch99_row('9903.88.10', 'Widgets', 'The duty provided + 30%')
rate_text_diff <- compare_ch99_full(general_old, rate_text_new)
check(rate_text_diff$n_general_changes == 1 && rate_text_diff$n_general_cosmetic == 0,
      'a general-text rate change is substantive, not cosmetic')

cat(sprintf('\nALL %d CHANGELOG-NORMALIZATION ASSERTIONS PASSED\n', pass))
