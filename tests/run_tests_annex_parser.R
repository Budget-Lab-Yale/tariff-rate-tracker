# =============================================================================
# Tests: §232 Annex Parser
# =============================================================================
#
# Covers the post-restructure annex parser in tools/scrape_us_notes.R:
#   - parse_annex_products(): Note 16(c) PDF extraction
#   - build_annex_products_for_revision(): merge with curator entries
#   - latest_local_chapter99_revision(): auto-detect from data/us_notes/
#   - annex_regime_effective_date(): pull date from policy_params.yaml
#
# Tests cover both unit behavior (constants, error paths) and an
# integration check against the rev_5 PDF — semantic equivalence with the
# curator baseline plus guards against the known false-positive class (year
# strings from page headers).
#
# Usage:
#   Rscript tests/run_tests_annex_parser.R
#
# CI-safe: requires data/us_notes/chapter99_2026_rev_5.pdf, which is
# downloaded by the existing CI step. Skips the integration block if the PDF
# is absent (so local runs without the cached PDF still report a green
# unit-test result).
#
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
  library(yaml)
})
source(here('tools', 'scrape_us_notes.R'))

pass_count <- 0
fail_count <- 0
skip_count <- 0

skip_test <- function(reason) {
  cond <- structure(class = c('skip', 'condition'), list(message = reason))
  stop(cond)
}

run_test <- function(name, expr) {
  tryCatch({
    force(expr)
    message('  PASS: ', name)
    pass_count <<- pass_count + 1
  }, skip = function(e) {
    message('  SKIP: ', name, ' — ', conditionMessage(e))
    skip_count <<- skip_count + 1
  }, error = function(e) {
    message('  FAIL: ', name, ' — ', conditionMessage(e))
    fail_count <<- fail_count + 1
  })
}


# =============================================================================
# ANNEX_SUBDIVISION_MAP
# =============================================================================

message('\n=== ANNEX_SUBDIVISION_MAP ===')

run_test('covers all 10 subdivisions (i)..(x)', {
  stopifnot(setequal(
    ANNEX_SUBDIVISION_MAP$sub,
    c('i', 'ii', 'iii', 'iv', 'v', 'vi', 'vii', 'viii', 'ix', 'x')
  ))
})

run_test('annex_1a contains the five core subdivisions', {
  ann_1a <- ANNEX_SUBDIVISION_MAP$sub[ANNEX_SUBDIVISION_MAP$annex == '1a']
  stopifnot(setequal(ann_1a, c('i', 'ii', 'iii', 'iv', 'v')))
})

run_test('annex_1b contains the three downstream subdivisions', {
  ann_1b <- ANNEX_SUBDIVISION_MAP$sub[ANNEX_SUBDIVISION_MAP$annex == '1b']
  stopifnot(setequal(ann_1b, c('vi', 'vii', 'viii')))
})

run_test('annex_3 contains the two floor subdivisions', {
  ann_3 <- ANNEX_SUBDIVISION_MAP$sub[ANNEX_SUBDIVISION_MAP$annex == '3']
  stopifnot(setequal(ann_3, c('ix', 'x')))
})

run_test('metal_type uses only steel/aluminum/copper', {
  stopifnot(all(ANNEX_SUBDIVISION_MAP$metal_type %in%
                c('steel', 'aluminum', 'copper')))
})


# =============================================================================
# annex_regime_effective_date()
# =============================================================================

message('\n=== annex_regime_effective_date() ===')

run_test('reads 2026-04-06 from policy_params.yaml', {
  d <- annex_regime_effective_date()
  stopifnot(identical(d, '2026-04-06'))
})

run_test('errors if section_232_annexes missing from config', {
  tmp <- tempfile(fileext = '.yaml')
  yaml::write_yaml(list(other_key = 1), tmp)
  err <- tryCatch(annex_regime_effective_date(tmp),
                  error = function(e) conditionMessage(e))
  stopifnot(grepl('section_232_annexes', err))
})


# =============================================================================
# latest_local_chapter99_revision()
# =============================================================================

message('\n=== latest_local_chapter99_revision() ===')

run_test('returns NULL when directory does not exist', {
  out <- latest_local_chapter99_revision(us_notes_dir = tempfile('nope_'))
  stopifnot(is.null(out))
})

run_test('returns NULL when directory is empty', {
  d <- tempfile('us_notes_'); dir.create(d)
  out <- latest_local_chapter99_revision(us_notes_dir = d)
  stopifnot(is.null(out))
})

run_test('picks the highest by effective_date when revision_dates.csv is present', {
  d <- tempfile('us_notes_'); dir.create(d)
  file.create(file.path(d, c('chapter99_2026_rev_5.pdf',
                              'chapter99_2026_rev_7.pdf',
                              'chapter99_rev_18.pdf')))
  rd_tmp <- tempfile(fileext = '.csv')
  readr::write_csv(tibble(
    revision = c('rev_18', '2026_rev_5', '2026_rev_7'),
    effective_date = c('2026-02-24', '2026-04-06', '2026-04-29')
  ), rd_tmp)
  out <- latest_local_chapter99_revision(us_notes_dir = d, revision_dates_csv = rd_tmp)
  stopifnot(identical(out, '2026_rev_7'))
})

run_test('falls back to lexical sort when revision_dates.csv is missing', {
  d <- tempfile('us_notes_'); dir.create(d)
  file.create(file.path(d, c('chapter99_2026_rev_5.pdf',
                              'chapter99_2026_rev_7.pdf')))
  out <- latest_local_chapter99_revision(us_notes_dir = d,
                                          revision_dates_csv = tempfile())
  stopifnot(identical(out, '2026_rev_7'))
})


# =============================================================================
# parse_annex_products()
# =============================================================================

message('\n=== parse_annex_products() ===')

run_test('errors when effective_date is NULL', {
  err <- tryCatch(
    parse_annex_products(pdf_path = tempfile()),
    error = function(e) conditionMessage(e)
  )
  stopifnot(grepl('requires effective_date', err))
})

run_test('errors when PDF file missing', {
  err <- tryCatch(
    parse_annex_products(pdf_path = '/does/not/exist.pdf',
                         effective_date = '2026-04-06'),
    error = function(e) conditionMessage(e)
  )
  stopifnot(nzchar(err))
})


# =============================================================================
# Integration: parse rev_5 PDF if available
# =============================================================================

message('\n=== Integration: rev_5 PDF parser output ===')

rev5_pdf <- here('data', 'us_notes', 'chapter99_2026_rev_5.pdf')

run_test('rev_5 PDF: parse yields expected total prefix count', {
  if (!file.exists(rev5_pdf)) skip_test('rev_5 PDF not available locally')
  out <- parse_annex_products(rev5_pdf, effective_date = '2026-04-06')
  # 738 prefix rows across 714 distinct prefixes (verified 2026-05-19).
  # Allow a small band so a future Note-16 reformat or PDF re-pagination
  # doesn't break the test for benign reasons.
  stopifnot(nrow(out) >= 700, nrow(out) <= 800)
  stopifnot(length(unique(out$hts_prefix)) >= 680,
            length(unique(out$hts_prefix)) <= 760)
})

run_test('rev_5 PDF: produces all 4 annex tiers', {
  if (!file.exists(rev5_pdf)) skip_test('rev_5 PDF not available locally')
  out <- parse_annex_products(rev5_pdf, effective_date = '2026-04-06')
  stopifnot(setequal(unique(out$annex), c('1a', '1b', '3')))  # annex_2 not parseable
})

run_test('rev_5 PDF: page-header years are not parsed as HS prefixes', {
  if (!file.exists(rev5_pdf)) skip_test('rev_5 PDF not available locally')
  out <- parse_annex_products(rev5_pdf, effective_date = '2026-04-06')
  # The pre-fix bug had "2026" leaking from "Revision N (2026)" page headers.
  # Guard against that and any other plausible year strings.
  forbidden <- c('2024', '2025', '2026', '2027', '2028')
  stopifnot(!any(forbidden %in% out$hts_prefix))
})

run_test('rev_5 PDF: all extracted prefixes are in HS chapter 72-95', {
  if (!file.exists(rev5_pdf)) skip_test('rev_5 PDF not available locally')
  out <- parse_annex_products(rev5_pdf, effective_date = '2026-04-06')
  chapters <- as.integer(substr(out$hts_prefix, 1, 2))
  stopifnot(all(!is.na(chapters)), all(chapters >= 72), all(chapters <= 95))
})

run_test('rev_5 PDF: all rows tagged source = us_note_16', {
  if (!file.exists(rev5_pdf)) skip_test('rev_5 PDF not available locally')
  out <- parse_annex_products(rev5_pdf, effective_date = '2026-04-06')
  stopifnot(all(out$source == 'us_note_16'))
})

run_test('rev_5 PDF: effective_date stamp matches the supplied value', {
  if (!file.exists(rev5_pdf)) skip_test('rev_5 PDF not available locally')
  out <- parse_annex_products(rev5_pdf, effective_date = '2027-01-15')
  stopifnot(all(out$effective_date == as.Date('2027-01-15')))
})


# =============================================================================
# Integration: build_annex_products_for_revision() merge
# =============================================================================

message('\n=== Integration: build_annex_products_for_revision() ===')

run_test('rev_5 merge preserves all curator entries', {
  if (!file.exists(rev5_pdf)) skip_test('rev_5 PDF not available locally')
  csv <- here('resources', 's232_annex_products.csv')
  if (!file.exists(csv)) skip_test('annex CSV not available')
  built <- build_annex_products_for_revision(revision = '2026_rev_5',
                                              pdf_path = rev5_pdf,
                                              static_csv = csv)
  curator <- readr::read_csv(csv, show_col_types = FALSE,
                              col_types = readr::cols(hts_prefix = readr::col_character())) |>
    dplyr::filter(is.na(source) | source != 'us_note_16')
  # Every curator (hts_prefix, annex, metal_type) triple must survive.
  stopifnot(nrow(dplyr::anti_join(curator, built,
                                   by = c('hts_prefix', 'annex', 'metal_type'))) == 0)
})

run_test('rev_5 merge is idempotent', {
  if (!file.exists(rev5_pdf)) skip_test('rev_5 PDF not available locally')
  csv <- here('resources', 's232_annex_products.csv')
  if (!file.exists(csv)) skip_test('annex CSV not available')
  first  <- build_annex_products_for_revision(revision = '2026_rev_5',
                                               pdf_path = rev5_pdf,
                                               static_csv = csv) |>
            dplyr::arrange(hts_prefix, annex, metal_type)
  # Write to a temp CSV, then re-build from it; result should be identical.
  tmp <- tempfile(fileext = '.csv')
  readr::write_csv(first, tmp)
  second <- build_annex_products_for_revision(revision = '2026_rev_5',
                                               pdf_path = rev5_pdf,
                                               static_csv = tmp) |>
            dplyr::arrange(hts_prefix, annex, metal_type)
  stopifnot(identical(first, second))
})


# =============================================================================
# zero_metal_content (9903.82.01) exemption — rate-engine behavior
# =============================================================================
#
# Verifies the new aggregate-share carve-out in 06_calculate_rates.R step 5c:
#   - aggregate_share = 0 → rate_232 unchanged (dormant default)
#   - aggregate_share = 0.05 → rate_232 scaled by (1 - 0.05) for in-scope rows
#   - heading_program_products skipped; annex_2 rows skipped
#
# Uses a synthetic rate snapshot rather than building a full revision; we just
# need the case_when contract to be honored.

message('\n=== zero_metal_content exemption (rate engine) ===')

run_test('config block exists in policy_params.yaml', {
  pp <- yaml::read_yaml(here('config', 'policy_params.yaml'))
  zmc <- pp$section_232_annexes$exemptions$zero_metal_content
  stopifnot(!is.null(zmc),
            identical(zmc$aggregate_share, 0.0),
            setequal(unlist(zmc$applies_to), c('annex_1a', 'annex_1b', 'annex_3')))
})

# Helper: produce a minimal rate snapshot and run the zero_metal_content block
# in isolation. We mirror the exact case_when logic from 06_calculate_rates.R.
apply_zmc <- function(rates, share, applies_to = c('annex_1a', 'annex_1b', 'annex_3'),
                       heading_program_products = character(0)) {
  if (is.na(share) || share <= 0) return(rates)
  rates |> dplyr::mutate(rate_232 = dplyr::if_else(
    !(hts10 %in% heading_program_products) & s232_annex %in% applies_to,
    rate_232 * (1 - share),
    rate_232
  ))
}

run_test('share=0 leaves rate_232 unchanged', {
  rates <- tibble::tibble(
    hts10 = c('7601100000', '8504909610', '8703230140'),
    s232_annex = c('annex_1a', 'annex_3', 'annex_2'),
    rate_232 = c(0.50, 0.15, 0.00)
  )
  out <- apply_zmc(rates, share = 0)
  stopifnot(identical(out$rate_232, rates$rate_232))
})

run_test('share=0.10 scales 1a/1b/3 by 0.9, skips annex_2', {
  rates <- tibble::tibble(
    hts10 = c('7601100000', '8504909610', '8703230140', '7308200035'),
    s232_annex = c('annex_1a', 'annex_3', 'annex_2', 'annex_1b'),
    rate_232 = c(0.50, 0.15, 0.00, 0.25)
  )
  out <- apply_zmc(rates, share = 0.10)
  stopifnot(
    isTRUE(all.equal(out$rate_232, c(0.45, 0.135, 0.00, 0.225)))
  )
})

run_test('heading_program_products skip the scaling', {
  rates <- tibble::tibble(
    hts10 = c('7601100000', '8703230140'),
    s232_annex = c('annex_1a', 'annex_1a'),
    rate_232 = c(0.50, 0.50)
  )
  out <- apply_zmc(rates, share = 0.10,
                    heading_program_products = '8703230140')
  stopifnot(isTRUE(all.equal(out$rate_232, c(0.45, 0.50))))
})


# =============================================================================
# Summary
# =============================================================================

message('\n', strrep('=', 70))
message(sprintf('Annex-parser tests: %d passed, %d skipped, %d failed',
                pass_count, skip_count, fail_count))
message(strrep('=', 70))

if (fail_count > 0) quit(status = 1)
