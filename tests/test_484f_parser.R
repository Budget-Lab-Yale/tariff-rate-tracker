# =============================================================================
# Tests: 484(f) HTS crosswalk parser (pure grammar)
# =============================================================================
#
# Pins the pure, PDF-toolchain-free grammar in tools/build_484f_crosswalk.R:
#   - normalize_hts10()
#   - parse_484f_lines()        (nomenclature section state, wrapped rows,
#                                all five verbs, (pt.), supplement table)
#   - apply_484f_overrides()    (documented source-typo corrections)
#   - reconcile_484f_edges()    (two-sided consistency + canonical edges)
#
# Fixtures live in tests/fixtures/484f/*.txt and mirror the real document
# layouts (verified against the committed data/484f PDFs on 2026-07-14).
#
# Usage:
#   Rscript tests/test_484f_parser.R
#
# CI-safe: no pdftools, no network, no build data.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})

source(here('tools', 'build_484f_crosswalk.R'))

pass_count <- 0
fail_count <- 0
skip_count <- 0

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

fixture <- function(name) {
  readLines(here('tests', 'fixtures', '484f', name), warn = FALSE)
}

# Parse then reconcile a fixture in one shot; returns the reconcile list.
parse_reconcile <- function(name, overrides = NULL, strict = TRUE) {
  a <- parse_484f_lines(fixture(name), source_doc = name, strict = strict)
  if (!is.null(overrides)) a <- apply_484f_overrides(a, overrides)
  reconcile_484f_edges(a, strict = strict)
}

expect_error_matching <- function(expr, pattern) {
  msg <- tryCatch({ force(expr); NULL }, error = function(e) conditionMessage(e))
  if (is.null(msg)) stop('expected an error, none raised')
  if (!grepl(pattern, msg, ignore.case = TRUE)) {
    stop(sprintf('error did not match /%s/: %s', pattern, msg))
  }
}

has_edge <- function(transfers, old, new) {
  any(transfers$old_hts10 == old &
        (if (is.na(new)) is.na(transfers$new_hts10) else transfers$new_hts10 %in% new),
      na.rm = TRUE)
}

# =============================================================================
message('\n=== normalize_hts10() ===')

run_test('dotted code -> 10 digits', {
  stopifnot(identical(normalize_hts10('0603.19.0137'), '0603190137'))
})
run_test('internal whitespace stripped', {
  stopifnot(identical(normalize_hts10('2930.90 .4330'), '2930904330'))
})
run_test('wrong digit count -> NA', {
  stopifnot(is.na(normalize_hts10('12345')),
            is.na(normalize_hts10('0603.19.013')))
})
run_test('non-numeric -> NA', {
  stopifnot(is.na(normalize_hts10('nope')))
})

# =============================================================================
message('\n=== flowers: split, (pt.), comma/and wrapped successor list ===')

flowers <- parse_reconcile('flowers_hts.txt')

run_test('flowers: three split edges from 0603190195', {
  t <- flowers$transfers
  stopifnot(has_edge(t, '0603190195', '0603190137'),
            has_edge(t, '0603190195', '0603190155'),
            has_edge(t, '0603190195', '0603190197'))
})
run_test('flowers: change_type is split and partial is TRUE', {
  t <- flowers$transfers %>% filter(old_hts10 == '0603190195')
  stopifnot(all(t$change_type == 'split'), all(t$partial))
})
run_test('flowers: wrapped "and 0603.19.0197)." continuation captured', {
  # The third successor only appears on the wrapped continuation line.
  stopifnot(has_edge(flowers$transfers, '0603190195', '0603190197'))
})
run_test('flowers: two-sided status is both_sides', {
  a <- parse_484f_lines(fixture('flowers_hts.txt'), 'flowers_hts.txt')
  rec <- reconcile_484f_edges(a)
  # 0195 appears on old side (Discontinued) and new side (Established rows).
  stopifnot('both_sides' %in% rec$status_summary$status)
})

# =============================================================================
message('\n=== terbufos: HTS vs Schedule B section state + shared successor ===')

terb <- parse_reconcile('terbufos_hts_scheduleb.txt')

run_test('terbufos: HTS edges use HTS predecessor 2930.90.4395', {
  t <- terb$transfers
  stopifnot(has_edge(t, '2930904395', '2930904330'),
            has_edge(t, '2930904395', '2930904390'))
})
run_test('terbufos: shared successor 4330 does NOT map from Schedule B 4398 in HTS', {
  t <- terb$transfers
  stopifnot(!has_edge(t, '2930904398', '2930904330'))
  # And the only HTS predecessor of 4330 is the HTS predecessor 4395.
  preds <- t$old_hts10[t$new_hts10 == '2930904330']
  stopifnot(setequal(preds, '2930904395'))
})
run_test('terbufos: all production transfers are nomenclature HTS', {
  stopifnot(all(terb$transfers$nomenclature == 'HTS'))
})
run_test('terbufos: Schedule B rows classified for audit and excluded', {
  sb <- terb$schedule_b
  stopifnot(nrow(sb) > 0,
            all(sb$nomenclature == 'SCHEDULE_B'),
            any(sb$old_hts10 == '2930904398' | sb$new_hts10 == '2930904398'))
})
run_test('terbufos: page-number/footer noise ("6") is not parsed as a code', {
  stopifnot(!has_edge(terb$transfers, '6', '6'))
  stopifnot(all(nchar(terb$transfers$old_hts10) == 10))
})

# =============================================================================
message('\n=== supplement: Renumbered-As table + same-date reuse ===')

supp <- parse_reconcile('supplement_pharma.txt')

run_test('supplement: renumber edges parsed with inherited 2026-02-01 date', {
  t <- supp$transfers
  stopifnot(has_edge(t, '3004909206', '3004909208'),
            has_edge(t, '3004909208', '3004909209'),
            has_edge(t, '3004909212', '3004909210'))
  ren <- t %>% filter(old_hts10 == '3004909206')
  stopifnot(all(ren$effective_date == '2026-02-01'))
})
run_test('supplement: reused code 3004909208 flagged same_date_reuse', {
  t <- supp$transfers
  reuse_edge <- t %>% filter(new_hts10 == '3004909208')
  stopifnot(nrow(reuse_edge) == 1, all(reuse_edge$same_date_reuse))
  # The onward edge whose successor (9209) is NOT reused must be FALSE.
  onward <- t %>% filter(old_hts10 == '3004909208', new_hts10 == '3004909209')
  stopifnot(nrow(onward) == 1, !onward$same_date_reuse)
})
run_test('supplement: standard row 9202->9203 coexists with supplement rows', {
  stopifnot(has_edge(supp$transfers, '3004909202', '3004909203'))
})
run_test('supplement: Schedule B Changes heading clears supplement (9208 not re-parsed)', {
  # The lone-code Schedule B Changes line must not add an edge.
  t <- supp$transfers
  stopifnot(sum(t$old_hts10 == '3004909208') == 1)  # only the 9208->9209 edge
})

# =============================================================================
message('\n=== all five verbs, leading whitespace, paren-spacing ===')

verbs <- parse_reconcile('verb_variants_hts.txt')

run_test('verb variants: leading-whitespace Established row parsed', {
  stopifnot(has_edge(verbs$transfers, '1111111000', '1111111111'))
})
run_test('verb variants: "( transferred from" paren-spacing tolerated', {
  # 1111.11.1111 is Established with "( transferred from 1111.11.1000".
  stopifnot(has_edge(verbs$transfers, '1111111000', '1111111111'))
})
run_test('verb variants: Deleted verb (old side) captured with and-list', {
  t <- verbs$transfers
  stopifnot(has_edge(t, '1111111000', '1111111111'),
            has_edge(t, '1111111000', '1111112222'))
  del <- t %>% filter(old_hts10 == '1111111000')
  stopifnot(all(del$action_old == 'Deleted'))
})
run_test('verb variants: Renumbered verb (old side rename) captured', {
  t <- verbs$transfers %>% filter(old_hts10 == '3333330001')
  stopifnot(has_edge(verbs$transfers, '3333330001', '3333330002'),
            all(t$action_old == 'Renumbered'),
            all(t$change_type == 'rename'))
})
run_test('all five verbs exercised across fixtures', {
  seen <- c(flowers$transfers$action_old, flowers$transfers$action_new,
            terb$transfers$action_old, terb$transfers$action_new,
            verbs$transfers$action_old, verbs$transfers$action_new,
            parse_reconcile('no_successor_hts.txt')$transfers$action_old)
  stopifnot(all(c('Established', 'Discontinued', 'Deleted', 'Renumbered',
                  'Annotated') %in%
                c(seen, parse_reconcile('avocado_typo_hts.txt', strict = FALSE)$
                          transfers$action_old)))
})

# =============================================================================
message('\n=== no_successor: genuine deletion ===')

nosucc <- parse_reconcile('no_successor_hts.txt')

run_test('no_successor: edge has NA successor and change_type no_successor', {
  t <- nosucc$transfers
  stopifnot(has_edge(t, '1234567890', NA),
            all(t$change_type[t$old_hts10 == '1234567890'] == 'no_successor'))
})

# =============================================================================
message('\n=== two-sided mismatch (avocado typo) + override workflow ===')

run_test('avocado: unresolved two-sided mismatch fails the build', {
  expect_error_matching(parse_reconcile('avocado_typo_hts.txt'),
                        'two-sided|inconsist')
})
run_test('avocado: mismatch surfaced (non-strict) with correct code deltas', {
  rec <- parse_reconcile('avocado_typo_hts.txt', strict = FALSE)
  inc <- rec$inconsistencies
  stopifnot(nrow(inc) == 1,
            inc$old_hts10 == '2008991000',
            grepl('2008191090', inc$old_side_only),
            grepl('2008991090', inc$new_side_only))
})

avocado_override <- tibble(
  override_id = 'ovr_test_avocado',
  source_doc = 'avocado_typo_hts.txt',
  side = 'old_action',
  source_row_id = NA_character_,
  old_hts10_as_printed = '2008.99.1000',
  new_hts10_as_printed = '2008.19.1090',
  corrected_old_hts10 = '2008.99.1000',
  corrected_new_hts10 = '2008.99.1090',
  reason = 'source_typo', evidence = 'established side', approved_by = 'test'
)

run_test('avocado: exact override resolves the mismatch and stamps override_id', {
  rec <- parse_reconcile('avocado_typo_hts.txt', overrides = avocado_override)
  t <- rec$transfers
  stopifnot(has_edge(t, '2008991000', '2008991010'),
            has_edge(t, '2008991000', '2008991090'),
            !has_edge(t, '2008991000', '2008191090'))
  stamped <- t %>% filter(old_hts10 == '2008991000', new_hts10 == '2008991090')
  stopifnot(nrow(stamped) == 1, stamped$override_id == 'ovr_test_avocado')
})

run_test('unused/stale override fails the build', {
  bogus <- avocado_override
  bogus$new_hts10_as_printed <- '9999.99.9999'   # matches nothing
  expect_error_matching(
    apply_484f_overrides(parse_484f_lines(fixture('avocado_typo_hts.txt'),
                                          'avocado_typo_hts.txt', strict = FALSE),
                         bogus),
    'unused|stale')
})

# =============================================================================
message('\n=== misplaced-dot source typo recovered by normalization ===')

run_test('misplaced dot "39.21.19.0090" normalizes to the correct successor', {
  stopifnot(identical(extract_code_tokens('and 39.21.19.0090).'), '39.21.19.0090'),
            identical(normalize_hts10('39.21.19.0090'), '3921190090'))
})
run_test('misplaced-dot fixture: successor recovered, no override, consistent', {
  rec <- parse_reconcile('misplaced_dot_hts.txt')   # strict = TRUE, no override
  stopifnot(has_edge(rec$transfers, '3921190000', '3921190010'),
            has_edge(rec$transfers, '3921190000', '3921190090'))
  # No inconsistency remained, so strict reconcile did not error.
  stopifnot(nrow(rec$inconsistencies) == 0)
})

# =============================================================================
message('\n=== self-edge typo: two-sided catch + override + guard ===')

run_test('self-edge fixture fails without override', {
  expect_error_matching(parse_reconcile('self_edge_typo_hts.txt'),
                        'two-sided|inconsist|self-edge')
})

self_edge_override <- tibble(
  override_id = 'ovr_test_9401', source_doc = 'self_edge_typo_hts.txt',
  side = 'old_action', source_row_id = NA_character_,
  old_hts10_as_printed = '9401.99.9070', new_hts10_as_printed = '9401.99.9070',
  corrected_old_hts10 = '9401.99.9070', corrected_new_hts10 = '9401.99.9085',
  reason = 'source_typo', evidence = 'established side', approved_by = 'test'
)
run_test('self-edge fixture resolves with override; no self-edge survives', {
  rec <- parse_reconcile('self_edge_typo_hts.txt', overrides = self_edge_override)
  t <- rec$transfers
  stopifnot(has_edge(t, '9401999070', '9401999040'),
            has_edge(t, '9401999070', '9401999085'),
            !any(t$old_hts10 == t$new_hts10, na.rm = TRUE))
})
run_test('self-edge guard fires when X->X has no Established-from-self row', {
  # Only an old-side self-reference (no re-establishment). Two-sided consistency
  # does not flag it (X is not on the new side), so the dedicated guard must.
  a <- tibble(
    source_doc = 'synthetic', source_row_id = 'r1', record_index = 1L,
    source_page = NA_integer_, nomenclature = 'HTS', table = 'standard',
    side = 'old_action', verb = 'Deleted',
    old_as_printed = '5555.55.5555', new_as_printed = '5555.55.5555',
    effective_date = '2026-07-01', partial = FALSE, no_successor = FALSE,
    old_hts10 = '5555555555', new_hts10 = '5555555555', override_id = NA_character_
  )
  expect_error_matching(reconcile_484f_edges(a), 'self-edge')
})

run_test('legitimate same-date reuse self-edge (X re-established from X) is kept', {
  # Old X deleted AND X re-established from X on the same date, plus X -> Y.
  # X->X must survive with same_date_reuse = TRUE (versioned reuse, not a typo).
  # Mirrors the real Jul-2026 3004.90.9211 case.
  a <- tibble(
    source_doc = 'synthetic', source_row_id = c('r1', 'r1', 'r2', 'r3'),
    record_index = c(1L, 1L, 2L, 3L), source_page = NA_integer_,
    nomenclature = 'HTS', table = 'standard',
    side = c('old_action', 'old_action', 'new_action', 'new_action'),
    verb = c('Deleted', 'Deleted', 'Established', 'Established'),
    old_as_printed = c('3004.90.9211', '3004.90.9211', '3004.90.9211', '3004.90.9211'),
    new_as_printed = c('3004.90.9211', '3004.90.9212', '3004.90.9211', '3004.90.9212'),
    effective_date = '2026-07-01', partial = c(FALSE, FALSE, TRUE, TRUE),
    no_successor = FALSE, old_hts10 = '3004909211',
    new_hts10 = c('3004909211', '3004909212', '3004909211', '3004909212'),
    override_id = NA_character_
  )
  rec <- reconcile_484f_edges(a)          # must NOT error
  self <- rec$transfers %>% filter(old_hts10 == '3004909211', new_hts10 == '3004909211')
  stopifnot(nrow(self) == 1, self$same_date_reuse)
})

# =============================================================================
message('\n=== unknown nomenclature fails loudly ===')

run_test('action row before any HTS/Schedule B heading fails (strict)', {
  expect_error_matching(
    parse_484f_lines(fixture('unknown_nomenclature.txt'),
                     'unknown_nomenclature.txt', strict = TRUE),
    'UNKNOWN nomenclature')
})
run_test('same row parses without error when strict = FALSE', {
  a <- parse_484f_lines(fixture('unknown_nomenclature.txt'),
                        'unknown_nomenclature.txt', strict = FALSE)
  stopifnot(nrow(a) >= 1, all(a$nomenclature == 'UNKNOWN'))
})

# =============================================================================
message('\n=== committed overrides + manifest load ===')

run_test('committed hts10_484f_overrides.csv loads with the seeded Jan-2026 typos', {
  ov <- load_484f_overrides()
  stopifnot(nrow(ov) == 3,
            all(c('ovr_2026-01_0710809724_to_0709809725',
                  'ovr_2026-01_2008991000_to_2008191090',
                  'ovr_2026-01_9401999070_self_to_9401999085') %in% ov$override_id),
            all(ov$source_doc == '484f_2026-01.pdf'))
})
run_test('committed source_manifest.csv is readable with all five docs present', {
  m <- readr::read_csv(here('data', '484f', 'source_manifest.csv'),
                       col_types = readr::cols(.default = readr::col_character()))
  stopifnot(nrow(m) == 5,
            sum(m$status == 'present') == 5,
            all(nchar(m$sha256) == 64))
})

# =============================================================================
message('\n', strrep('=', 70))
message(sprintf('484(f) parser tests: %d passed, %d skipped, %d failed',
                pass_count, skip_count, fail_count))
message(strrep('=', 70))

if (fail_count > 0) quit(status = 1)
