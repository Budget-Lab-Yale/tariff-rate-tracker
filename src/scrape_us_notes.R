# =============================================================================
# Step 03: Parse US Note Product Lists from Chapter 99 PDF
# =============================================================================
#
# Extracts product lists from US Notes in the USITC Chapter 99 PDF:
#
#   1. Section 301 product lists (US Notes 20/31):
#      HTS subheadings covered by 9903.88.xx and 9903.91.xx entries.
#
#   2. Floor country product exemptions (US Note 2):
#      Products exempt from the 15% tariff floor for EU, Japan, S. Korea,
#      Switzerland/Liechtenstein. Categories: PTAAP (agricultural/natural
#      resources), civil aircraft, non-patented pharmaceuticals.
#
# Downloads the Chapter 99 PDF from USITC, parses the text with pdftools,
# and outputs updated resources/s301_product_lists.csv and
# resources/floor_exempt_products.csv.
#
# Usage:
#   Rscript src/03_scrape_us_notes.R                    # Section 301 only
#   Rscript src/03_scrape_us_notes.R --floor-exemptions # Floor exemptions only
#   Rscript src/03_scrape_us_notes.R --all              # Both 301 + floor
#   Rscript src/03_scrape_us_notes.R --dry-run          # Report without writing
#   Rscript src/03_scrape_us_notes.R --download-pdfs [--dry-run]  # Download all revision PDFs
#   Rscript src/03_scrape_us_notes.R --revision rev_18            # Parse single revision
#   Rscript src/03_scrape_us_notes.R --all-revisions [--dry-run]  # Parse all revisions
#
# Dependencies: pdftools
#
# =============================================================================

library(tidyverse)


# =============================================================================
# Configuration: ch99 code -> list label mapping
# =============================================================================
#
# Product lists in the PDF are identified by "Heading 9903.XX.XX applies to"
# anchor text. This mapping assigns list labels for the output CSV.
#
# Note 20 (Original Section 301, Lists 1-4B):
#   Subdivisions (b), (d), (f) enumerate HTS8 codes for Lists 1-3.
#   Subdivision (s) enumerates HTS8 codes for List 4A.
#   Subdivision (u) enumerates HTS8 codes for List 4B (9903.88.16).
#   9903.88.04 (List 3 reduced 7.5%) has no separate product enumeration
#   — its products are a subset of 9903.88.03 with specific exclusions.
#
# Note 31 (Biden 301 acceleration):
#   Subdivisions (b)-(j) enumerate products for 9903.91.xx headings.
#
CH99_TO_LIST <- tribble(
  ~ch99_code,    ~list,              ~note,
  '9903.88.01',  '1',               20,     # List 1 (25%)
  '9903.88.02',  '2',               20,     # List 2 (25%)
  '9903.88.03',  '3',               20,     # List 3 (25%)
  '9903.88.15',  '4A',              20,     # List 4A (7.5%)
  '9903.88.16',  '4B',              20,     # List 4B (15%)
  '9903.91.01',  'biden_25',        31,     # Biden 25%
  '9903.91.02',  'biden_50',        31,     # Biden 50%
  '9903.91.03',  'biden_100',       31,     # Biden 100%
  '9903.91.05',  'biden_50_jan25',  31,     # Biden 50% (Jan 2025)
  '9903.91.06',  'biden_jan26',     31,     # Biden (Jan 2026)
  '9903.91.07',  'biden_jan26',     31,     # Biden (Jan 2026)
  '9903.91.08',  'biden_jan26',     31,     # Biden (Jan 2026)
  '9903.91.11',  'biden_25_jan25',  31,     # Biden 25% (Jan 2025)
)


# =============================================================================
# Configuration: Floor country product exemptions
# =============================================================================
#
# US Note 2 subdivisions (v)(xx)-(xxiv) define products exempt from the 15%
# tariff floor for floor countries (EU, Japan, S. Korea, Switzerland,
# Liechtenstein). These use a different anchor pattern than Section 301:
#   "As provided in heading 9903.XX.XX" followed by product lists.
#
# Categories:
#   ptaap        — Agricultural/natural resource products (PTAAP)
#   particular   — Particular articles (incl. religious items)
#   civil_aircraft — Civil aircraft and parts
#   pharma       — Non-patented pharmaceuticals
#
# Country groups:
#   eu    — EU-27 member states
#   korea — South Korea
#   swiss — Switzerland + Liechtenstein
#   japan — Japan (civil aircraft only, via Note 3)
#
FLOOR_EXEMPTIONS <- tribble(
  ~ch99_code,    ~category,         ~country_group,
  '9903.02.74',  'ptaap',           'eu',
  '9903.02.75',  'particular',      'eu',
  '9903.02.76',  'civil_aircraft',  'eu',
  '9903.02.77',  'pharma',          'eu',
  '9903.02.81',  'civil_aircraft',  'korea',
  '9903.02.84',  'ptaap',           'swiss',
  '9903.02.85',  'civil_aircraft',  'swiss',
  '9903.02.86',  'pharma',          'swiss',
  '9903.96.02',  'civil_aircraft',  'japan',
)

# Japan/UK civil aircraft lists use inline format (semicolons) rather than
# tabular format. These ch99 codes use Note 3 anchors rather than Note 2.
INLINE_FLOOR_CODES <- c('9903.96.01', '9903.96.02')


# =============================================================================
# PDF Download
# =============================================================================

#' Download Chapter 99 PDF from USITC
#'
#' @param dest_dir Directory to save PDF
#' @param force Re-download even if file exists
#' @return Path to downloaded PDF
download_chapter99_pdf <- function(dest_dir = 'data/us_notes', force = FALSE) {
  dest_path <- file.path(dest_dir, 'chapter99.pdf')

  if (file.exists(dest_path) && !force) {
    file_age_days <- as.numeric(difftime(Sys.time(), file.info(dest_path)$mtime, units = 'days'))
    if (file_age_days < 30) {
      message('Using cached PDF (', round(file_age_days, 1), ' days old): ', dest_path)
      return(dest_path)
    }
    message('PDF is ', round(file_age_days, 1), ' days old, re-downloading...')
  }

  dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)

  url <- 'https://hts.usitc.gov/reststop/file?release=currentRelease&filename=Chapter+99'
  message('Downloading Chapter 99 PDF from USITC...')
  message('  URL: ', url)

  tryCatch({
    download.file(url, dest_path, mode = 'wb', quiet = FALSE)
    file_size_mb <- file.info(dest_path)$size / (1024 * 1024)
    message('  Downloaded: ', round(file_size_mb, 1), ' MB')

    if (file_size_mb < 0.5) {
      warning('PDF is suspiciously small (', round(file_size_mb, 2), ' MB). May be an error page.')
    }

    return(dest_path)
  }, error = function(e) {
    stop('Failed to download Chapter 99 PDF: ', conditionMessage(e))
  })
}


# =============================================================================
# PDF Text Extraction
# =============================================================================

#' Extract text from Chapter 99 PDF
#'
#' @param pdf_path Path to chapter99.pdf
#' @return Character vector (one element per page)
extract_pdf_text <- function(pdf_path) {
  if (!requireNamespace('pdftools', quietly = TRUE)) {
    stop('pdftools package required. Install with: install.packages("pdftools")')
  }

  message('Extracting text from PDF...')
  pages <- pdftools::pdf_text(pdf_path)
  message('  Pages extracted: ', length(pages))

  return(pages)
}


# =============================================================================
# Anchor-based Product List Extraction
# =============================================================================

#' Find all product list anchors in the PDF
#'
#' Scans for "Heading 9903.XX.XX applies to" patterns, which mark the start
#' of an HTS code enumeration. Returns a table of anchors with page numbers.
#'
#' @param pages Character vector of page texts
#' @return Tibble with ch99_code, page, char_pos columns
find_product_list_anchors <- function(pages) {
  anchors <- tibble(ch99_code = character(), page = integer(), char_pos = integer())

  for (i in seq_along(pages)) {
    # Match "Heading 9903.XX.XX applies to" — the definitive product list start
    matches <- gregexpr('Heading\\s+(9903\\.[0-9]{2}\\.[0-9]{2})\\s+applies\\s+to', pages[i])
    if (matches[[1]][1] != -1) {
      # Extract the ch99 codes from each match
      match_text <- regmatches(pages[i], matches)[[1]]
      codes <- str_extract(match_text, '9903\\.[0-9]{2}\\.[0-9]{2}')
      positions <- as.integer(matches[[1]])

      for (j in seq_along(codes)) {
        anchors <- bind_rows(anchors, tibble(
          ch99_code = codes[j],
          page = i,
          char_pos = positions[j]
        ))
      }
    }
  }

  return(anchors)
}


#' Extract HTS codes from text between two positions
#'
#' Extracts all HTS-format codes (4.2 or 4.2.2-4 digits) from a text span.
#' Filters out Chapter 99 self-references and date-like patterns.
#'
#' @param text Character string to search
#' @return Character vector of HTS codes
extract_hts_codes <- function(text) {
  codes <- str_extract_all(text, '[0-9]{4}\\.[0-9]{2}(?:\\.[0-9]{2,4})?')[[1]]
  codes <- unique(codes)

  # Filter out ch99 self-references
  codes <- codes[!grepl('^99(01|02|03|04)\\.', codes)]
  # Filter out date-like patterns (year.month)
  codes <- codes[!grepl('^(19|20)[0-9]{2}\\.', codes)]
  # Filter out page/section numbers that look like codes
  codes <- codes[nchar(gsub('\\.', '', codes)) >= 6]

  return(codes)
}


#' Extract product list for a specific ch99 heading
#'
#' Given a starting anchor (page + position), extracts HTS codes until the
#' next anchor or note boundary is reached.
#'
#' @param pages Character vector of page texts
#' @param start_page Page where anchor is
#' @param start_pos Character position within start_page
#' @param end_page Page of next anchor (or last page to scan)
#' @param end_pos Character position of next anchor on end_page
#' @return Character vector of HTS codes
extract_product_list <- function(pages, start_page, start_pos, end_page, end_pos) {
  all_codes <- character()

  for (p in start_page:end_page) {
    text <- pages[p]

    if (p == start_page && p == end_page) {
      text <- substring(text, start_pos, end_pos - 1)
    } else if (p == start_page) {
      text <- substring(text, start_pos)
    } else if (p == end_page) {
      text <- substring(text, 1, end_pos - 1)
    }

    codes <- extract_hts_codes(text)
    all_codes <- c(all_codes, codes)
  }

  return(unique(all_codes))
}


# =============================================================================
# HTS Code Normalization
# =============================================================================

#' Normalize parsed HTS codes to 8-digit format
#'
#' Codes from PDF may be 6-digit (heading level) or 8-10 digit (subheading).
#' For consistency with s301_product_lists.csv, normalize to 8 digits.
#'
#' @param codes Character vector of HTS codes with dots
#' @return Character vector of 8-digit HTS codes (no dots)
normalize_to_hts8 <- function(codes) {
  clean <- gsub('\\.', '', codes)
  clean <- str_pad(clean, 8, side = 'right', pad = '0')
  clean <- substr(clean, 1, 8)
  return(clean)
}


# =============================================================================
# Main Pipeline
# =============================================================================

#' Parse US Notes and extract Section 301 product lists
#'
#' @param pdf_path Path to Chapter 99 PDF (or NULL to download)
#' @param existing_csv Path to current s301_product_lists.csv
#' @param output_csv Path to write updated CSV (NULL = same as existing)
#' @param dry_run Report without writing
#' @return Tibble of all products (existing + new)
parse_us_note_products <- function(
  pdf_path = NULL,
  existing_csv = 'resources/s301_product_lists.csv',
  output_csv = NULL,
  dry_run = FALSE
) {
  if (is.null(output_csv)) output_csv <- existing_csv

  message('\n', strrep('=', 70))
  message('US NOTE 301 PRODUCT LIST PARSER')
  message(strrep('=', 70))

  # ---- Download PDF if needed ----
  if (is.null(pdf_path)) {
    pdf_path <- download_chapter99_pdf()
  }
  stopifnot(file.exists(pdf_path))

  # ---- Extract text ----
  pages <- extract_pdf_text(pdf_path)

  # ---- Find all product list anchors ----
  message('\nScanning for product list anchors...')
  anchors <- find_product_list_anchors(pages)
  message('  Found ', nrow(anchors), ' anchor(s)')

  if (nrow(anchors) > 0) {
    message('  Anchors: ', paste(anchors$ch99_code, collapse = ', '))
  }

  # ---- Filter to Section 301 ch99 codes we care about ----
  target_codes <- CH99_TO_LIST$ch99_code
  s301_anchors <- anchors %>%
    filter(ch99_code %in% target_codes) %>%
    arrange(page, char_pos)

  message('  Section 301 anchors: ', nrow(s301_anchors))

  if (nrow(s301_anchors) == 0) {
    message('WARNING: No Section 301 product list anchors found.')
    message('The PDF format may have changed. Check anchor detection.')
    return(invisible(NULL))
  }

  # ---- Extract product lists between consecutive anchors ----
  message('\nExtracting product lists...')
  all_parsed <- tibble(hts_code = character(), ch99_code = character())

  # Sort all anchors (including non-301) for boundary detection
  all_anchors_sorted <- anchors %>% arrange(page, char_pos)

  for (i in seq_len(nrow(s301_anchors))) {
    row <- s301_anchors[i, ]

    # Find the next anchor AFTER this one (from all anchors, not just 301)
    later <- all_anchors_sorted %>%
      filter(page > row$page | (page == row$page & char_pos > row$char_pos))

    if (nrow(later) > 0) {
      next_anchor <- later[1, ]
      end_page <- next_anchor$page
      end_pos <- next_anchor$char_pos
    } else {
      # Last anchor — scan to end of Note area (limit to ~50 pages ahead)
      end_page <- min(row$page + 50, length(pages))
      end_pos <- nchar(pages[end_page])
    }

    codes <- extract_product_list(pages, row$page, row$char_pos, end_page, end_pos)

    if (length(codes) > 0) {
      list_label <- CH99_TO_LIST %>%
        filter(ch99_code == row$ch99_code) %>%
        pull(list) %>%
        first()
      message('  ', row$ch99_code, ' [', list_label, ']: ', length(codes),
              ' HTS codes (pages ', row$page, '-', end_page, ')')
      all_parsed <- bind_rows(all_parsed, tibble(
        hts_code = codes,
        ch99_code = row$ch99_code
      ))
    } else {
      message('  ', row$ch99_code, ': no HTS codes found')
    }
  }

  message('\nTotal HTS codes parsed from US Notes: ', nrow(all_parsed))
  message('  Unique HTS codes: ', n_distinct(all_parsed$hts_code))

  if (nrow(all_parsed) == 0) {
    message('WARNING: No HTS codes parsed. PDF format may have changed.')
    return(invisible(NULL))
  }

  # ---- Normalize to 8-digit format and add list labels ----
  all_parsed <- all_parsed %>%
    left_join(CH99_TO_LIST %>% select(ch99_code, list), by = 'ch99_code') %>%
    mutate(hts8 = normalize_to_hts8(hts_code)) %>%
    select(hts8, list, ch99_code) %>%
    distinct()

  message('After normalization to HTS8: ', nrow(all_parsed), ' unique entries')

  # ---- Cross-reference with existing CSV ----
  message('\nCross-referencing with existing s301_product_lists.csv...')

  if (file.exists(existing_csv)) {
    existing <- read_csv(existing_csv, col_types = cols(
      hts8 = col_character(),
      list = col_character(),
      ch99_code = col_character()
    ))
    message('  Existing entries: ', nrow(existing))

    # Find new entries (not already in existing by hts8 + ch99_code)
    new_entries <- all_parsed %>%
      anti_join(existing, by = c('hts8', 'ch99_code'))

    message('  New entries from US Notes: ', nrow(new_entries))

    if (nrow(new_entries) > 0) {
      message('  Breakdown by list:')
      new_summary <- new_entries %>% count(list, ch99_code) %>% arrange(list)
      for (j in seq_len(nrow(new_summary))) {
        message('    ', new_summary$list[j], ' (', new_summary$ch99_code[j], '): ',
                new_summary$n[j], ' new codes')
      }

      message('  Sample new HTS8 codes:')
      sample_codes <- head(new_entries$hts8, 10)
      message('    ', paste(sample_codes, collapse = ', '))
    }

    # Count overlap (already present)
    overlap <- all_parsed %>%
      semi_join(existing, by = c('hts8', 'ch99_code'))
    message('  Already in existing CSV: ', nrow(overlap))

    # Merge: existing + new
    combined <- bind_rows(existing, new_entries) %>%
      distinct(hts8, ch99_code, .keep_all = TRUE) %>%
      arrange(hts8, ch99_code)

  } else {
    message('  No existing CSV found. Writing all parsed entries.')
    combined <- all_parsed %>%
      arrange(hts8, ch99_code)
    new_entries <- combined
  }

  message('\nFinal product list: ', nrow(combined), ' entries')
  message('  Unique HTS8 codes: ', n_distinct(combined$hts8))
  message('  Lists represented: ', paste(sort(unique(combined$list)), collapse = ', '))

  # ---- Write output ----
  if (!dry_run && nrow(new_entries) > 0) {
    write_csv(combined, output_csv)
    message('\nWrote updated CSV: ', output_csv)
  } else if (dry_run) {
    message('\n[DRY RUN] Would write ', nrow(combined), ' entries to ', output_csv)
  } else {
    message('\nNo new entries found. CSV unchanged.')
  }

  return(invisible(combined))
}


# =============================================================================
# Floor Exemption Anchor Detection
# =============================================================================

#' Find floor exemption anchors in the PDF
#'
#' Floor exemption sections use "As provided in heading(s) 9903.XX.XX" anchors
#' (different from Section 301's "Heading ... applies to" pattern).
#' Swiss sections use plural: "As provided in headings 9903.02.84 and 9903.02.89"
#' — both codes are extracted as separate anchors at the same position.
#'
#' @param pages Character vector of page texts
#' @return Tibble with ch99_code, page, char_pos columns
find_floor_exempt_anchors <- function(pages) {
  anchors <- tibble(ch99_code = character(), page = integer(), char_pos = integer())

  for (i in seq_along(pages)) {
    # Pattern: "As provided in heading(s) 9903.XX.XX [and 9903.XX.XX]"
    # Handles both singular "heading" and plural "headings" with optional second code
    matches <- gregexpr(
      '[Aa]s\\s+provided\\s+in\\s+headings?\\s+9903\\.[0-9]{2}\\.[0-9]{2}(?:\\s+and\\s+9903\\.[0-9]{2}\\.[0-9]{2})?',
      pages[i]
    )
    if (matches[[1]][1] != -1) {
      match_text <- regmatches(pages[i], matches)[[1]]
      positions <- as.integer(matches[[1]])

      for (j in seq_along(match_text)) {
        # Extract ALL ch99 codes from this match (may be 1 or 2)
        codes <- str_extract_all(match_text[j], '9903\\.[0-9]{2}\\.[0-9]{2}')[[1]]
        for (code in codes) {
          anchors <- bind_rows(anchors, tibble(
            ch99_code = code,
            page = i,
            char_pos = positions[j]
          ))
        }
      }
    }
  }

  return(anchors)
}


#' Extract inline HTS codes (semicolon-separated) from note text
#'
#' Japan/UK civil aircraft lists use inline format:
#'   "classifiable in subheadings 3917.21; 3917.22; ..."
#' rather than tabular format.
#'
#' @param text Character string containing inline codes
#' @return Character vector of HTS codes
extract_inline_hts_codes <- function(text) {
  # Split on semicolons and extract HTS patterns from each segment
  segments <- str_split(text, ';')[[1]]
  codes <- character()
  for (seg in segments) {
    seg_codes <- str_extract_all(seg, '[0-9]{4}\\.[0-9]{2}(?:\\.[0-9]{2,4})?')[[1]]
    codes <- c(codes, seg_codes)
  }
  codes <- unique(codes)
  # Apply same filters as extract_hts_codes
  codes <- codes[!grepl('^99(01|02|03|04)\\.', codes)]
  codes <- codes[!grepl('^(19|20)[0-9]{2}\\.', codes)]
  codes <- codes[nchar(gsub('\\.', '', codes)) >= 6]
  return(codes)
}


# =============================================================================
# Floor Exemption Main Pipeline
# =============================================================================

#' Parse floor country product exemptions from US Note 2
#'
#' Extracts product lists that are exempt from the 15% tariff floor for
#' EU, Japan, S. Korea, and Switzerland/Liechtenstein. These exemptions
#' are defined in US Note 2, subdivisions (v)(xx)-(xxiv) and Note 3.
#'
#' @param pdf_path Path to Chapter 99 PDF (or NULL to download)
#' @param output_csv Path to write floor_exempt_products.csv
#' @param dry_run Report without writing
#' @return Tibble of exempt products
parse_floor_exempt_products <- function(
  pdf_path = NULL,
  output_csv = 'resources/floor_exempt_products.csv',
  dry_run = FALSE
) {
  message('\n', strrep('=', 70))
  message('FLOOR COUNTRY PRODUCT EXEMPTION PARSER')
  message(strrep('=', 70))

  # ---- Download PDF if needed ----
  if (is.null(pdf_path)) {
    pdf_path <- download_chapter99_pdf()
  }
  stopifnot(file.exists(pdf_path))

  # ---- Extract text ----
  pages <- extract_pdf_text(pdf_path)

  # ---- Find floor exemption anchors ----
  message('\nScanning for floor exemption anchors...')
  floor_anchors <- find_floor_exempt_anchors(pages)
  message('  Found ', nrow(floor_anchors), ' "As provided in heading" anchor(s)')

  if (nrow(floor_anchors) > 0) {
    message('  Anchors: ', paste(unique(floor_anchors$ch99_code), collapse = ', '))
  }

  # Also find "Heading ... applies to" anchors for boundary detection
  std_anchors <- find_product_list_anchors(pages)

  # Merge all anchors for boundary detection
  all_anchors <- bind_rows(
    floor_anchors %>% mutate(anchor_type = 'floor'),
    std_anchors %>% mutate(anchor_type = 'standard')
  ) %>%
    arrange(page, char_pos)

  # ---- Filter to target ch99 codes ----
  target_codes <- FLOOR_EXEMPTIONS$ch99_code
  matched_anchors <- floor_anchors %>%
    filter(ch99_code %in% target_codes) %>%
    # Take first occurrence of each code (avoid duplicates from repeated mentions)
    group_by(ch99_code) %>%
    arrange(page, char_pos) %>%
    slice(1) %>%
    ungroup() %>%
    arrange(page, char_pos)

  message('  Target anchors matched: ', nrow(matched_anchors), ' of ', length(target_codes))

  if (nrow(matched_anchors) == 0) {
    message('WARNING: No floor exemption anchors found.')
    message('The PDF format may have changed. Check anchor patterns.')
    return(invisible(NULL))
  }

  # Report missing codes
  missing_codes <- setdiff(target_codes, matched_anchors$ch99_code)
  if (length(missing_codes) > 0) {
    message('  Missing anchors: ', paste(missing_codes, collapse = ', '))
  }

  # ---- Extract product lists ----
  message('\nExtracting floor exemption product lists...')
  all_parsed <- tibble(hts_code = character(), ch99_code = character())

  for (i in seq_len(nrow(matched_anchors))) {
    row <- matched_anchors[i, ]
    is_inline <- row$ch99_code %in% INLINE_FLOOR_CODES

    # Find the next anchor AFTER this one (from all anchors)
    later <- all_anchors %>%
      filter(page > row$page | (page == row$page & char_pos > row$char_pos))

    if (nrow(later) > 0) {
      next_anchor <- later[1, ]
      end_page <- next_anchor$page
      end_pos <- next_anchor$char_pos
    } else {
      # Last anchor — scan to end of Note area (limit to ~20 pages ahead)
      end_page <- min(row$page + 20, length(pages))
      end_pos <- nchar(pages[end_page])
    }

    # Extract codes using appropriate method
    if (is_inline) {
      # Inline format: concatenate text span and extract semicolon-separated codes
      text_span <- ''
      for (p in row$page:end_page) {
        page_text <- pages[p]
        if (p == row$page && p == end_page) {
          page_text <- substring(page_text, row$char_pos, end_pos - 1)
        } else if (p == row$page) {
          page_text <- substring(page_text, row$char_pos)
        } else if (p == end_page) {
          page_text <- substring(page_text, 1, end_pos - 1)
        }
        text_span <- paste0(text_span, ' ', page_text)
      }
      codes <- extract_inline_hts_codes(text_span)
    } else {
      # Tabular format: reuse existing extraction
      codes <- extract_product_list(pages, row$page, row$char_pos, end_page, end_pos)
    }

    # Look up category
    exemption_info <- FLOOR_EXEMPTIONS %>%
      filter(ch99_code == row$ch99_code)

    if (length(codes) > 0) {
      message('  ', row$ch99_code, ' [', exemption_info$category, '/',
              exemption_info$country_group, ']: ', length(codes),
              ' HTS codes (pages ', row$page, '-', end_page, ')',
              if (is_inline) ' [inline]' else '')
      all_parsed <- bind_rows(all_parsed, tibble(
        hts_code = codes,
        ch99_code = row$ch99_code
      ))
    } else {
      message('  ', row$ch99_code, ' [', exemption_info$category, '/',
              exemption_info$country_group, ']: no HTS codes found')
    }
  }

  message('\nTotal HTS codes parsed: ', nrow(all_parsed))
  message('  Unique HTS codes: ', n_distinct(all_parsed$hts_code))

  if (nrow(all_parsed) == 0) {
    message('WARNING: No HTS codes parsed. PDF format may have changed.')
    return(invisible(NULL))
  }

  # ---- Normalize to 8-digit format and add metadata ----
  result <- all_parsed %>%
    left_join(
      FLOOR_EXEMPTIONS %>% select(ch99_code, category, country_group),
      by = 'ch99_code'
    ) %>%
    mutate(hts8 = normalize_to_hts8(hts_code)) %>%
    select(hts8, category, country_group, ch99_code) %>%
    distinct()

  message('After normalization to HTS8: ', nrow(result), ' unique entries')

  # ---- Summary by category and country group ----
  message('\nBreakdown:')
  summary_tbl <- result %>% count(country_group, category) %>% arrange(country_group, category)
  for (j in seq_len(nrow(summary_tbl))) {
    message('  ', summary_tbl$country_group[j], ' / ', summary_tbl$category[j],
            ': ', summary_tbl$n[j], ' codes')
  }

  # ---- Write output ----
  if (!dry_run) {
    result <- result %>% arrange(hts8, country_group, ch99_code)
    write_csv(result, output_csv)
    message('\nWrote ', nrow(result), ' entries to ', output_csv)
  } else {
    message('\n[DRY RUN] Would write ', nrow(result), ' entries to ', output_csv)
  }

  return(invisible(result))
}


# =============================================================================
# Per-Revision PDF Download
# =============================================================================

#' Download Chapter 99 PDF for a specific HTS revision
#'
#' Downloads the Chapter 99 PDF from USITC for a given revision using the
#' reststop file API. Files are cached locally by revision ID.
#'
#' @param revision Character revision ID (e.g., 'rev_18', '2026_basic')
#' @param dest_dir Directory to store per-revision PDFs
#' @param force Re-download even if file exists
#' @return Path to downloaded PDF, or NULL on failure
download_revision_chapter99_pdf <- function(revision, dest_dir = 'data/us_notes',
                                            force = FALSE) {
  dest_path <- file.path(dest_dir, paste0('chapter99_', revision, '.pdf'))

  if (file.exists(dest_path) && !force) {
    message('  Using cached PDF: ', dest_path)
    return(dest_path)
  }

  release_name <- build_release_name(revision)
  if (is.na(release_name)) {
    message('  SKIP: no USITC API mapping for ', revision)
    return(NULL)
  }

  url <- build_chapter99_url(release_name)
  dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)

  tryCatch({
    message('  Downloading Chapter 99 PDF for ', revision, '...')
    message('    URL: ', url)
    download.file(url, dest_path, mode = 'wb', quiet = TRUE)

    file_size_mb <- file.info(dest_path)$size / (1024 * 1024)
    if (file_size_mb < 0.5) {
      warning('PDF for ', revision, ' is suspiciously small (',
              round(file_size_mb, 2), ' MB). May be an error page.')
      unlink(dest_path)
      return(NULL)
    }

    message('    Downloaded: ', round(file_size_mb, 1), ' MB')
    return(dest_path)
  }, error = function(e) {
    message('    FAILED: ', conditionMessage(e))
    if (file.exists(dest_path)) unlink(dest_path)
    return(NULL)
  })
}


#' Download Chapter 99 PDFs for all revisions
#'
#' Checks local inventory and downloads missing PDFs with rate limiting.
#'
#' @param revisions Character vector of revision IDs
#' @param dest_dir Directory to store PDFs
#' @param dry_run Report without downloading
#' @return Tibble with revision, status, path columns
download_all_revision_pdfs <- function(revisions, dest_dir = 'data/us_notes',
                                       dry_run = FALSE) {
  message('\n', strrep('=', 70))
  message('PER-REVISION CHAPTER 99 PDF DOWNLOAD')
  message(strrep('=', 70))

  results <- tibble(revision = character(), status = character(), path = character())

  for (rev in revisions) {
    dest_path <- file.path(dest_dir, paste0('chapter99_', rev, '.pdf'))

    if (file.exists(dest_path)) {
      results <- bind_rows(results, tibble(
        revision = rev, status = 'cached', path = dest_path
      ))
      next
    }

    release_name <- build_release_name(rev)
    if (is.na(release_name)) {
      results <- bind_rows(results, tibble(
        revision = rev, status = 'skipped_no_mapping', path = NA_character_
      ))
      next
    }

    if (dry_run) {
      url <- build_chapter99_url(release_name)
      message('  [DRY RUN] Would download: ', rev, ' -> ', url)
      results <- bind_rows(results, tibble(
        revision = rev, status = 'would_download', path = NA_character_
      ))
      next
    }

    path <- download_revision_chapter99_pdf(rev, dest_dir)
    results <- bind_rows(results, tibble(
      revision = rev,
      status = if (!is.null(path)) 'downloaded' else 'failed',
      path = if (!is.null(path)) path else NA_character_
    ))

    # Rate limiting: 2 seconds between downloads
    if (rev != revisions[length(revisions)]) {
      Sys.sleep(2)
    }
  }

  # Summary
  message('\nDownload summary:')
  summary_tbl <- results %>% count(status)
  for (j in seq_len(nrow(summary_tbl))) {
    message('  ', summary_tbl$status[j], ': ', summary_tbl$n[j])
  }

  return(results)
}


# =============================================================================
# Per-Revision Floor Exemption Parsing
# =============================================================================

#' Parse floor exemptions from a specific revision's Chapter 99 PDF
#'
#' Downloads the revision PDF if needed, then runs the floor exemption parser.
#' Output is cached as a per-revision CSV.
#'
#' @param revision Character revision ID
#' @param dest_dir Directory for PDFs
#' @param output_dir Directory for per-revision exemption CSVs
#' @param dry_run Report without writing
#' @return Tibble of exempt products, or NULL if no anchors found
parse_revision_floor_exemptions <- function(revision, dest_dir = 'data/us_notes',
                                            output_dir = 'data/us_notes',
                                            dry_run = FALSE) {
  output_path <- file.path(output_dir, paste0('floor_exempt_', revision, '.csv'))

  # Check cache
  if (file.exists(output_path) && !dry_run) {
    message('  Using cached exemptions: ', output_path)
    return(read_csv(output_path, col_types = cols(.default = col_character())))
  }

  # Download PDF if needed
  pdf_path <- download_revision_chapter99_pdf(revision, dest_dir)
  if (is.null(pdf_path)) {
    message('  SKIP: no PDF available for ', revision)
    return(NULL)
  }

  # Parse floor exemptions using existing function
  result <- parse_floor_exempt_products(
    pdf_path = pdf_path,
    output_csv = output_path,
    dry_run = dry_run
  )

  return(result)
}


#' Parse floor exemptions for all revisions from start_from onward
#'
#' @param revisions Character vector of all revision IDs (in order)
#' @param start_from First revision to parse (default: 'rev_18', Phase 2 intro)
#' @param dry_run Report without writing
#' @return Tibble with revision, n_products, status columns
parse_all_revision_floor_exemptions <- function(revisions,
                                                start_from = 'rev_18',
                                                dry_run = FALSE) {
  message('\n', strrep('=', 70))
  message('PER-REVISION FLOOR EXEMPTION PARSING')
  message(strrep('=', 70))

  # Filter to revisions at or after start_from
  start_idx <- match(start_from, revisions)
  if (is.na(start_idx)) {
    message('WARNING: start_from revision "', start_from, '" not found in revision list')
    start_idx <- 1
  }
  target_revisions <- revisions[start_idx:length(revisions)]
  message('Processing ', length(target_revisions), ' revisions from ', start_from)

  results <- tibble(revision = character(), n_products = integer(), status = character())

  for (rev in target_revisions) {
    message('\n--- ', rev, ' ---')
    tryCatch({
      result <- parse_revision_floor_exemptions(rev, dry_run = dry_run)
      n <- if (!is.null(result)) nrow(result) else 0L
      results <- bind_rows(results, tibble(
        revision = rev,
        n_products = n,
        status = if (n > 0) 'parsed' else 'no_anchors'
      ))
    }, error = function(e) {
      message('  ERROR: ', conditionMessage(e))
      results <<- bind_rows(results, tibble(
        revision = rev,
        n_products = 0L,
        status = 'error'
      ))
    })
  }

  # Summary
  message('\n\nParsing summary:')
  for (j in seq_len(nrow(results))) {
    message('  ', results$revision[j], ': ', results$n_products[j],
            ' products (', results$status[j], ')')
  }

  return(results)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)
  source(here('src', 'helpers.R'))

  # Parse command line arguments
  args <- commandArgs(trailingOnly = TRUE)
  dry_run <- '--dry-run' %in% args
  do_floor <- '--floor-exemptions' %in% args
  do_all_modes <- '--all' %in% args
  do_download_pdfs <- '--download-pdfs' %in% args
  do_revision <- '--revision' %in% args
  do_all_revisions <- '--all-revisions' %in% args

  # Extract --revision value
  revision_value <- NULL
  if (do_revision) {
    rev_idx <- which(args == '--revision')
    if (rev_idx < length(args)) {
      revision_value <- args[rev_idx + 1]
    } else {
      stop('--revision requires a value (e.g., --revision rev_18)')
    }
  }

  # --- Per-revision PDF download ---
  if (do_download_pdfs) {
    rev_dates <- load_revision_dates(here('config', 'revision_dates.csv'))
    download_all_revision_pdfs(rev_dates$revision, dry_run = dry_run)

  # --- Single revision floor exemption parsing ---
  } else if (do_revision) {
    parse_revision_floor_exemptions(revision_value, dry_run = dry_run)

  # --- All revisions floor exemption parsing ---
  } else if (do_all_revisions) {
    rev_dates <- load_revision_dates(here('config', 'revision_dates.csv'))
    parse_all_revision_floor_exemptions(rev_dates$revision, dry_run = dry_run)

  # --- Original modes ---
  } else {
    if (do_floor || do_all_modes) {
      floor_result <- parse_floor_exempt_products(dry_run = dry_run)
    }

    if (!do_floor || do_all_modes) {
      result <- parse_us_note_products(dry_run = dry_run)
    }
  }
}
