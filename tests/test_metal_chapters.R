# =============================================================================
# metal-chapter map dedup unit test (Plank 5a)
# =============================================================================
# Plank 5a folds the scattered metal-chapter -> type literals into the single
# config source `section_232_chapters` (steel/aluminum/copper), surfaced as the
# cc$*_CHAPTERS constants. This test PROVES every repoint is value-identical to
# the literal it replaced, so the 43-rev parity gate is byte-identical by
# construction (the build only needs to CONFIRM it).
# Usage: Rscript tests/test_metal_chapters.R
# =============================================================================

suppressPackageStartupMessages(library(here))
source(here('src', 'model', 'policy_params.R'))

pass <- 0L
check <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAILED: ', msg, call. = FALSE)
  pass <<- pass + 1L; cat('  ok:', msg, '\n')
}

pp <- load_policy_params()
cc <- get_country_constants(pp)

cat('--- config section_232_chapters surfaces as cc$*_CHAPTERS ---\n')
check(identical(as.character(cc$STEEL_CHAPTERS),  c('72', '73')), "cc$STEEL_CHAPTERS == c('72','73')")
check(identical(as.character(cc$ALUM_CHAPTERS),   c('76')),       "cc$ALUM_CHAPTERS == c('76')")
check(identical(as.character(cc$COPPER_CHAPTERS), c('74')),       "cc$COPPER_CHAPTERS == c('74') (new in 5a)")

cat('\n--- each repointed call site equals the literal it replaced ---\n')
# authority_adapter.R:459 uk_chap (steel+aluminum, NOT copper)
check(identical(as.character(c(cc$STEEL_CHAPTERS, cc$ALUM_CHAPTERS)), c('72', '73', '76')),
      "uk_chap repoint == c('72','73','76')")
# authority_adapter.R:471 prim_by_type
check(identical(as.character(cc$STEEL_CHAPTERS),  c('72', '73')) &&
        identical(as.character(cc$ALUM_CHAPTERS), c('76')) &&
        identical(as.character(cc$COPPER_CHAPTERS), c('74')),
      "prim_by_type repoint == list(steel=c('72','73'),aluminum='76',copper='74')")
# authority_adapter.R:441 a1a_ch fallback
check(identical(as.character(c(cc$STEEL_CHAPTERS, cc$ALUM_CHAPTERS, cc$COPPER_CHAPTERS)),
                c('72', '73', '76', '74')),
      "a1a_ch fallback repoint == c('72','73','76','74')")

cat('\n--- the DISTINCT metal_content.primary_chapters set is untouched (copper still excluded) ---\n')
check(identical(as.character(unlist(pp$metal_content$primary_chapters)), c('72', '73', '76')),
      "metal_content.primary_chapters still c('72','73','76') — 74 stays excluded (copper_share scaling)")

cat(sprintf('\nALL %d METAL-CHAPTER DEDUP ASSERTIONS PASSED\n', pass))
