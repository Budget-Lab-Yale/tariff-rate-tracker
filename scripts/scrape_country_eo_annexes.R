#!/usr/bin/env Rscript
# =============================================================================
# scrape_country_eo_annexes.R
# =============================================================================
#
# Build resources/country_eo_exempt_products.csv from official EO annex PDFs.
#
# Country-specific reciprocal EOs (Brazil EO 14323 = 9903.01.77,
# India EO 14361 = 9903.01.84, etc.) carry their OWN exempt-product lists,
# distinct from the universal EO 14257 Annex II / Annex A list captured in
# resources/ieepa_exempt_products.csv. Treating them as if they shared the
# same exempt list causes the tracker to under-apply country-EO surcharges
# for products like Brazilian coffee — see docs/country_eo_annex_overshoot.md.
#
# Currently parses:
#   - Brazil EO 14323 modifying scope (Nov 20, 2025) ANNEXES PDF
#       Annex I  = revised exempt list (effective 2025-11-13)
#       Annex II = the 238 ag products newly exempted (effective 2025-11-13)
#       Local cache: docs/federal-register/brazil_eo/brazil_eo_nov2025_annexes.pdf
#       Source URL: https://www.whitehouse.gov/wp-content/uploads/2025/11/2025NovemberBrazilTariff.ANNEXES.pdf
#
# To extend to other country EOs (India 14361, etc.), add a new entry to the
# `eo_sources` list at the top of main() with PDF URL and ch99 code.
#
# Usage:
#   Rscript scripts/scrape_country_eo_annexes.R
#
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
  library(pdftools)
})

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

#' Extract HTSUS codes from a block of text, returning normalized 8-digit codes.
#'
#' Recognizes both dotted ("0901.11.00") and undotted ("09011100") forms.
#' Returns 8-digit prefixes since EO Annex I/II descriptions are at 8-digit
#' subheading granularity per the PDF's introductory note.
extract_hts8_codes <- function(text) {
  # Dotted 4-, 6-, 8-, 10-digit forms, then strip dots
  dotted <- str_extract_all(text, '\\b\\d{4}\\.\\d{2}(?:\\.\\d{2}(?:\\.\\d{2})?)?\\b')[[1]]
  dotted_clean <- gsub('\\.', '', dotted)

  # Undotted 8-digit (sometimes 10) appearing standalone
  undotted <- str_extract_all(text, '(?<![\\d.])(\\d{8}|\\d{10})(?![\\d.])')[[1]]

  all_codes <- c(dotted_clean, undotted)
  # Truncate to 8 digits (Annex I/II are 8-digit subheading lists)
  all_codes <- substr(all_codes, 1, 8)
  # Keep only well-formed 8-digit codes
  all_codes <- all_codes[nchar(all_codes) == 8]
  # Filter to plausible HTS chapters
  chapters <- as.integer(substr(all_codes, 1, 2))
  all_codes <- all_codes[chapters >= 1L & chapters <= 99L]
  unique(all_codes)
}

#' Format an 8-digit HTS code as 'NNNN.NN.NN'
fmt_hts8 <- function(code) {
  paste0(substr(code, 1, 4), '.', substr(code, 5, 6), '.', substr(code, 7, 8))
}

#' Locate annex section boundaries in a vector of page texts.
#'
#' Looks for headers like "ANNEX I", "ANNEX II". Returns a list with
#' `annex_i_pages` and `annex_ii_pages` integer vectors. Empty vector if
#' the annex is not found.
find_annex_pages <- function(pages_txt) {
  hdr_i  <- grepl('^\\s*ANNEX\\s+I\\b(?!\\s*[VI])', pages_txt, perl = TRUE) |
            grepl('ANNEX\\s+I[\\r\\n]', pages_txt, perl = TRUE)
  hdr_ii <- grepl('^\\s*ANNEX\\s+II\\b', pages_txt, perl = TRUE) |
            grepl('ANNEX\\s+II[\\r\\n]', pages_txt, perl = TRUE)

  start_i  <- which(hdr_i)[1]
  start_ii <- which(hdr_ii)[1]

  if (is.na(start_i)) start_i <- 1L  # fallback: assume Annex I starts at page 1

  annex_i_pages  <- if (!is.na(start_ii)) seq(start_i, start_ii - 1L) else seq(start_i, length(pages_txt))
  annex_ii_pages <- if (!is.na(start_ii)) seq(start_ii, length(pages_txt)) else integer(0)

  list(annex_i_pages = annex_i_pages, annex_ii_pages = annex_ii_pages)
}

# -----------------------------------------------------------------------------
# Brazil parser
# -----------------------------------------------------------------------------

#' Parse the Brazil Nov 20 modifying EO ANNEXES PDF into the canonical schema.
#'
#' Annex I: revised exempt list (effective 2025-11-13). All HTS8 codes here are
#'   exempt from 9903.01.77 from 2025-11-13 onward.
#' Annex II: the 238 newly added agricultural HTS8 codes (effective 2025-11-13).
#'   These overlap conceptually with Annex I's revised total — Annex II is the
#'   delta added by the Nov 20 EO. We tag them with source = 'EO modifying scope
#'   (Nov 20 2025) Annex II' so downstream consumers can reconstruct the
#'   pre/post Nov-13 lists.
#'
#' For pre-Nov-13 history we'd need the *original* EO 14323 Annex I PDF
#' (separate file). That parsing is left for a follow-up; without it, the
#' tracker conservatively treats coffee, tropical fruit, etc. as NOT exempt
#' before Nov-13, which matches CBP CSMS 65807735.
parse_brazil_annexes <- function(pdf_path) {
  if (!file.exists(pdf_path)) {
    stop('PDF not found: ', pdf_path)
  }
  pages <- pdf_text(pdf_path)
  message('Brazil annexes: ', length(pages), ' pages loaded')

  bounds <- find_annex_pages(pages)
  message('  Annex I  pages: ', paste(range(bounds$annex_i_pages), collapse = '-'))
  if (length(bounds$annex_ii_pages) > 0) {
    message('  Annex II pages: ', paste(range(bounds$annex_ii_pages), collapse = '-'))
  }

  annex_i_text  <- paste(pages[bounds$annex_i_pages],  collapse = '\n')
  annex_ii_text <- if (length(bounds$annex_ii_pages) > 0) {
    paste(pages[bounds$annex_ii_pages], collapse = '\n')
  } else {
    ''
  }

  codes_i  <- extract_hts8_codes(annex_i_text)
  codes_ii <- extract_hts8_codes(annex_ii_text)
  # Annex II is a subset newly added; mark separately for traceability.
  # Annex I (revised) includes codes_ii too — partition by membership.
  codes_i_only <- setdiff(codes_i, codes_ii)

  message('  Annex I codes (revised total): ', length(codes_i))
  message('  Annex II codes (newly added):  ', length(codes_ii))
  message('  Annex I-only (pre-existing):   ', length(codes_i_only))

  bind_rows(
    tibble(
      ch99_code = '9903.01.77',
      hts10 = fmt_hts8(codes_i_only),
      effective_date_start = '2025-08-06',
      effective_date_end   = '',
      source = 'EO 14323 Annex I (original, pre-Nov-13)',
      note = 'HTS8 subheading; all 10-digit children covered'
    ),
    tibble(
      ch99_code = '9903.01.77',
      hts10 = fmt_hts8(codes_ii),
      effective_date_start = '2025-11-13',
      effective_date_end   = '',
      source = 'EO modifying scope (Nov 20 2025) Annex II',
      note = 'Added Nov 13 2025; HTS8 subheading; all 10-digit children covered'
    )
  ) %>%
    distinct(ch99_code, hts10, effective_date_start, .keep_all = TRUE) %>%
    arrange(ch99_code, effective_date_start, hts10)
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main <- function() {
  brazil_pdf <- here('docs', 'federal-register', 'brazil_eo',
                     'brazil_eo_nov2025_annexes.pdf')

  brazil <- parse_brazil_annexes(brazil_pdf)

  # Future country EOs (India, etc.) would append rows here.
  combined <- brazil

  out_path <- here('resources', 'country_eo_exempt_products.csv')

  header <- c(
    '# =============================================================================',
    '# Country-specific IEEPA EO exempt products',
    '# =============================================================================',
    '#',
    '# Generated by scripts/scrape_country_eo_annexes.R',
    sprintf('# Last updated: %s', Sys.Date()),
    '#',
    '# Schema:',
    '#   ch99_code:             country EO heading (e.g., 9903.01.77 = Brazil)',
    '#   hts10:                 HTS code exempt from this EO (8-digit prefix; all 10-digit children covered)',
    '#   effective_date_start:  ISO date the exemption began',
    '#   effective_date_end:    ISO date the exemption ended (empty = still active)',
    '#   source:                EO/proclamation/CBP CSMS reference',
    '#   note:                  short description',
    '#',
    '# To regenerate: Rscript scripts/scrape_country_eo_annexes.R',
    '# =============================================================================',
    'ch99_code,hts10,effective_date_start,effective_date_end,source,note'
  )

  writeLines(header, out_path)
  write_csv(combined, out_path, append = TRUE,
            col_names = FALSE, na = '')

  message(sprintf('\nWrote %d rows to %s', nrow(combined), out_path))
  message(sprintf('  By ch99_code: %s',
                  paste(combined %>% count(ch99_code) %>% mutate(s = paste0(ch99_code, '=', n)) %>%
                        pull(s), collapse = ', ')))
  message(sprintf('  By source:'))
  combined %>% count(source) %>%
    walk2(.x = .$source, .y = .$n, .f = ~ message('    ', .x, ': ', .y))
}

if (!interactive()) {
  main()
}
