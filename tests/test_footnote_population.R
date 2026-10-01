# =============================================================================
# Tests: Chapter 99 cross-reference footnote population (§3 test 3 / M0)
# =============================================================================
# Gate for tools/footnote_audit.R. HTS 2026 rev_13 dropped 98.8% of the
# columns:['general'] endnote class — the "See 9903.88.15."-style references
# that seed ch99_refs (04_parse_products.R:146) and the footnote-rate join in
# calculate_rates_fast(). No change record mentioned it, and no record-count or
# general-rate diff can see it, so it passed as a rate-neutral ingest and was
# only caught two revisions later by an unrelated file-size check.
#
# Asserts three things:
#   1. every consecutive-revision move beyond tolerance is either absent or
#      carries a documented waiver (the live gate);
#   2. the audit still DETECTS such a move — a guard that silently stops
#      firing is worse than no guard;
#   3. a waiver cannot be filed without a reason.
#
# The archive-backed assertions skip when fewer than two archives are on disk
# (CI downloads only the archives a build needs).
#
# Usage: Rscript tests/test_footnote_population.R
# =============================================================================

suppressPackageStartupMessages({ library(here); library(dplyr) })
source(here('tools', 'footnote_audit.R'))

pass <- 0L; skip <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:', msg, '\n')
}
note_skip <- function(msg) { skip <<- skip + 1L; cat('  SKIP:', msg, '\n') }

# --- 1. Live gate: no unwaived moves on the archives present ------------------
deltas <- audit_footnote_population()

if (nrow(deltas) == 0) {
  note_skip('footnote-population audit (fewer than two archives on disk)')
} else {
  unwaived <- deltas %>% filter(breached, !waived)
  if (nrow(unwaived) > 0) {
    cat('  unwaived moves:\n')
    unwaived %>%
      mutate(move = sprintf('%+d (%.1f%%)', delta, move_share * 100)) %>%
      select(from_revision, to_revision, footnote_class, n_from, n_to, move) %>%
      as.data.frame() %>% print(row.names = FALSE)
  }
  check(nrow(unwaived) == 0,
        sprintf('no unwaived footnote-population move across %d revision pair(s)',
                length(unique(paste(deltas$from_revision, deltas$to_revision)))))

  # The rev_13 collapse must stay visible as a waived breach. If this stops
  # matching, either the archives changed or the audit stopped measuring the
  # thing it was built for.
  collapse <- deltas %>%
    filter(from_revision == '2026_rev_12', to_revision == '2026_rev_13',
           footnote_class == '[general] endnote')
  if (nrow(collapse) == 1) {
    check(collapse$breached && collapse$waived && collapse$n_from > 10000 &&
            collapse$n_to < 200,
          'the rev_13 [general] endnote collapse is still detected and waived')
  } else {
    note_skip('rev_13 collapse assertion (2026_rev_12/2026_rev_13 not both present)')
  }
}

# --- 2. The guard fires on a synthetic collapse -------------------------------
# Independent of what is on disk: hand-built profiles, so this runs in CI too.
no_waivers <- load_footnote_waivers(tempfile())

intact <- list(classes = tibble(
  footnote_class = c('[general] endnote', '[stat,units] footnote'),
  n = c(10411L, 3035L)))
collapsed <- list(classes = tibble(
  footnote_class = c('[general] endnote', '[stat,units] footnote'),
  n = c(127L, 3134L)))

synthetic <- compare_footnote_profiles('rev_a', 'rev_b', intact, collapsed, no_waivers)

check(synthetic %>% filter(footnote_class == '[general] endnote') %>% pull(breached),
      'a 98.8% endnote collapse is flagged as a breach')
check(!(synthetic %>% filter(footnote_class == '[stat,units] footnote') %>% pull(breached)),
      'a +3.3% move on a stable class is not flagged (tolerance holds)')
check(!any(synthetic$waived),
      'nothing is waived when the registry is empty')

# A class that vanishes entirely must breach rather than disappear from the diff.
vanished <- compare_footnote_profiles(
  'rev_a', 'rev_b', intact,
  list(classes = tibble(footnote_class = '[stat,units] footnote', n = 3035L)),
  no_waivers)
check(vanished %>% filter(footnote_class == '[general] endnote') %>% pull(n_to) == 0,
      'a class absent from the newer revision counts as zero, not missing')
check(vanished %>% filter(footnote_class == '[general] endnote') %>% pull(breached),
      'a class that vanishes entirely is flagged as a breach')

# Small classes stay below the noise floor.
small <- compare_footnote_profiles(
  'rev_a', 'rev_b',
  list(classes = tibble(footnote_class = '[other] endnote', n = 8L)),
  list(classes = tibble(footnote_class = '[other] endnote', n = 4L)),
  no_waivers)
check(!small$breached,
      'a 4-entry move on a sub-threshold class is not flagged')

# --- 3. A waiver needs a reason -----------------------------------------------
reasonless <- tempfile(fileext = '.csv')
writeLines(c('from_revision,to_revision,footnote_class,reason',
             'rev_a,rev_b,[general] endnote,'), reasonless)
check(inherits(try(load_footnote_waivers(reasonless), silent = TRUE), 'try-error'),
      'a waiver with an empty reason is rejected')

malformed <- tempfile(fileext = '.csv')
writeLines(c('from_revision,to_revision,reason', 'rev_a,rev_b,because'), malformed)
check(inherits(try(load_footnote_waivers(malformed), silent = TRUE), 'try-error'),
      'a waiver registry missing footnote_class is rejected')

cat(sprintf('\nALL %d FOOTNOTE-POPULATION ASSERTIONS PASSED (%d skipped)\n', pass, skip))
