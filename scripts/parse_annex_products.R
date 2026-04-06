#!/usr/bin/env Rscript
# =============================================================================
# Parse Section 232 annex product lists from proclamation PDF text
# =============================================================================
#
# Input:  docs/s232/annexes_text.txt (pdftotext output of Metals-ANNEXES-I-A-I-B-II-III-IV.pdf)
# Output: resources/s232_annex_products.csv
#
# Usage:  Rscript scripts/parse_annex_products.R
#
# The PDF contains four annexes with explicit HTS codes. This script extracts
# them by section, classifies by annex and metal type, and writes the resource CSV.

library(tidyverse)
library(here)

input_path <- here('docs', 's232', 'annexes_text.txt')
output_path <- here('resources', 's232_annex_products.csv')

stopifnot(file.exists(input_path))

lines <- readLines(input_path, warn = FALSE, encoding = 'UTF-8')
# Sanitize: strip form feeds (page breaks) and invalid UTF-8 bytes
lines <- iconv(lines, from = 'UTF-8', to = 'UTF-8', sub = ' ')
lines <- gsub('\f', '', lines)  # remove form feed characters

# =============================================================================
# Section boundary detection
# =============================================================================

# Find annex headers and sub-section headers
annex_1a_start <- which(grepl('Annex I-A:', lines))[1]
annex_1b_start <- which(grepl('Annex I-B:', lines))[1]
annex_2_start  <- which(grepl('Annex II:', lines))[1]
annex_3_start  <- which(grepl('Annex III:', lines))[1]
annex_4_start  <- which(grepl('Annex IV$|Annex IV\\b', lines))[1]

message('Section boundaries:')
message('  Annex I-A: line ', annex_1a_start)
message('  Annex I-B: line ', annex_1b_start)
message('  Annex II:  line ', annex_2_start)
message('  Annex III: line ', annex_3_start)
message('  Annex IV:  line ', annex_4_start)

# =============================================================================
# HTS code extraction helper
# =============================================================================

extract_hts_codes <- function(text_lines) {
  # Match HTS codes: 4-digit headings (7206) and full codes (7208.10.00, 7216.91.00.10)
  # HTS patterns: NNNN, NNNN.NN, NNNN.NN.NN, NNNN.NN.NN.NN (with dots)
  # Also match plain codes without dots: 04029968, 27101930 etc (Annex II style)
  all_codes <- character()
  for (line in text_lines) {
    # Dotted codes: 7206.10.00 or 7216.91.00.10
    dotted <- str_extract_all(line, '\\b\\d{4}\\.\\d{2}(?:\\.\\d{2}(?:\\.\\d{2})?)?\\b')[[1]]
    # Plain 4-digit headings that appear alone (e.g., "7206 7207 7208")
    # Only match if they look like HTS headings (start of a heading, 4 digits, space-separated)
    plain4 <- str_extract_all(line, '(?<=^|\\s)\\d{4}(?=\\s|$)')[[1]]
    # Filter plain4 to plausible HTS chapters (70-99 or 01-49 for Annex II)
    plain4 <- plain4[as.numeric(substr(plain4, 1, 2)) %in% c(0:49, 70:99)]
    # Plain 8/10 digit codes without dots (Annex II format): 04029968
    plain8 <- str_extract_all(line, '(?<=^|\\s)\\d{8,10}(?=\\s|$)')[[1]]
    all_codes <- c(all_codes, dotted, plain4, plain8)
  }
  # Deduplicate
  unique(all_codes)
}

# Normalize code format: ensure dots for codes >= 6 digits
normalize_code <- function(code) {
  code <- trimws(code)
  # Already dotted
  if (grepl('\\.', code)) return(code)
  # 4-digit heading
  if (nchar(code) == 4) return(code)
  # 8-digit: NNNN.NN.NN
  if (nchar(code) == 8) return(paste0(substr(code,1,4), '.', substr(code,5,6), '.', substr(code,7,8)))
  # 10-digit: NNNN.NN.NN.NN
  if (nchar(code) == 10) return(paste0(substr(code,1,4), '.', substr(code,5,6), '.', substr(code,7,8), '.', substr(code,9,10)))
  # 6-digit: NNNN.NN
  if (nchar(code) == 6) return(paste0(substr(code,1,4), '.', substr(code,5,6)))
  code
}

# =============================================================================
# Detect metal type sub-sections within an annex
# =============================================================================

parse_annex_section <- function(lines, start_line, end_line, annex_id) {
  section_lines <- lines[start_line:end_line]

  # Find sub-section headers within this annex
  trimmed <- trimws(section_lines)
  steel_main_idx     <- which(trimmed == 'Steel')[1]
  steel_deriv_idx    <- which(grepl('^Steel Derivative', trimmed))
  alum_main_idx      <- which(trimmed == 'Aluminum')[1]
  alum_deriv_idx     <- which(grepl('^Aluminum Derivative', trimmed))
  copper_idx         <- which(grepl('^Copper Articles', trimmed))

  # For Annex IV-based lists (vi/vii/viii patterns)
  deriv_alum_vi_idx  <- which(grepl('Derivative aluminum articles', section_lines, ignore.case = TRUE))
  deriv_steel_vii_idx <- which(grepl('Derivative steel articles', section_lines, ignore.case = TRUE))
  copper_v_idx       <- which(grepl('Articles of copper', section_lines, ignore.case = TRUE))

  results <- tibble(hts_prefix = character(), annex = character(), metal_type = character())

  # Build ordered sub-sections: (label, start_offset, metal_type)
  subsections <- list()

  # Steel main
  if (!is.na(steel_main_idx)) {
    # Find next sub-section
    next_idx <- min(c(steel_deriv_idx, alum_main_idx, alum_deriv_idx, copper_idx,
                      length(section_lines)), na.rm = TRUE)
    subsections <- c(subsections, list(list(
      start = steel_main_idx, end = next_idx - 1, metal_type = 'steel'
    )))
  }

  # Steel derivatives (can appear multiple times)
  for (sd_idx in steel_deriv_idx) {
    # Find next sub-section after this one
    all_headers <- sort(unique(c(steel_main_idx, steel_deriv_idx, alum_main_idx,
                                  alum_deriv_idx, copper_idx, deriv_alum_vi_idx,
                                  deriv_steel_vii_idx, copper_v_idx)))
    next_headers <- all_headers[all_headers > sd_idx]
    next_idx <- if (length(next_headers) > 0) min(next_headers) - 1 else length(section_lines)
    subsections <- c(subsections, list(list(
      start = sd_idx, end = next_idx, metal_type = 'steel'
    )))
  }

  # Aluminum main
  if (!is.na(alum_main_idx)) {
    all_headers <- sort(unique(c(steel_main_idx, steel_deriv_idx, alum_main_idx,
                                  alum_deriv_idx, copper_idx)))
    next_headers <- all_headers[all_headers > alum_main_idx]
    next_idx <- if (length(next_headers) > 0) min(next_headers) - 1 else length(section_lines)
    subsections <- c(subsections, list(list(
      start = alum_main_idx, end = next_idx, metal_type = 'aluminum'
    )))
  }

  # Aluminum derivatives
  for (ad_idx in alum_deriv_idx) {
    all_headers <- sort(unique(c(steel_main_idx, steel_deriv_idx, alum_main_idx,
                                  alum_deriv_idx, copper_idx, deriv_alum_vi_idx,
                                  deriv_steel_vii_idx, copper_v_idx)))
    next_headers <- all_headers[all_headers > ad_idx]
    next_idx <- if (length(next_headers) > 0) min(next_headers) - 1 else length(section_lines)
    subsections <- c(subsections, list(list(
      start = ad_idx, end = next_idx, metal_type = 'aluminum'
    )))
  }

  # Copper articles
  for (cu_idx in copper_idx) {
    all_headers <- sort(unique(c(steel_main_idx, steel_deriv_idx, alum_main_idx,
                                  alum_deriv_idx, copper_idx, deriv_alum_vi_idx,
                                  deriv_steel_vii_idx, copper_v_idx)))
    next_headers <- all_headers[all_headers > cu_idx]
    next_idx <- if (length(next_headers) > 0) min(next_headers) - 1 else length(section_lines)
    subsections <- c(subsections, list(list(
      start = cu_idx, end = next_idx, metal_type = 'copper'
    )))
  }

  # Extract codes from each sub-section
  for (ss in subsections) {
    codes <- extract_hts_codes(section_lines[ss$start:ss$end])
    if (length(codes) > 0) {
      results <- bind_rows(results, tibble(
        hts_prefix = sapply(codes, normalize_code, USE.NAMES = FALSE),
        annex = annex_id,
        metal_type = ss$metal_type
      ))
    }
  }

  # If no sub-sections detected, extract all codes with NA metal_type
  if (nrow(results) == 0) {
    codes <- extract_hts_codes(section_lines)
    if (length(codes) > 0) {
      # Infer metal type from chapter
      results <- tibble(
        hts_prefix = sapply(codes, normalize_code, USE.NAMES = FALSE),
        annex = annex_id,
        metal_type = NA_character_
      ) %>%
        mutate(metal_type = case_when(
          substr(hts_prefix, 1, 2) %in% c('72', '73') ~ 'steel',
          substr(hts_prefix, 1, 2) == '76' ~ 'aluminum',
          substr(hts_prefix, 1, 2) == '74' ~ 'copper',
          TRUE ~ NA_character_
        ))
    }
  }

  results %>% distinct()
}

# =============================================================================
# Parse each annex
# =============================================================================

message('\nParsing Annex I-A...')
annex_1a <- parse_annex_section(lines, annex_1a_start, annex_1b_start - 1, '1a')
message('  Codes: ', nrow(annex_1a),
        ' (steel=', sum(annex_1a$metal_type == 'steel', na.rm = TRUE),
        ', aluminum=', sum(annex_1a$metal_type == 'aluminum', na.rm = TRUE),
        ', copper=', sum(annex_1a$metal_type == 'copper', na.rm = TRUE), ')')

message('\nParsing Annex I-B...')
annex_1b <- parse_annex_section(lines, annex_1b_start, annex_2_start - 1, '1b')
message('  Codes: ', nrow(annex_1b),
        ' (steel=', sum(annex_1b$metal_type == 'steel', na.rm = TRUE),
        ', aluminum=', sum(annex_1b$metal_type == 'aluminum', na.rm = TRUE),
        ', copper=', sum(annex_1b$metal_type == 'copper', na.rm = TRUE), ')')

message('\nParsing Annex II...')
annex_2 <- parse_annex_section(lines, annex_2_start, annex_3_start - 1, '2')
message('  Codes: ', nrow(annex_2))

message('\nParsing Annex III...')
annex_3 <- parse_annex_section(lines, annex_3_start, annex_4_start - 1, '3')
message('  Codes: ', nrow(annex_3),
        ' (steel=', sum(annex_3$metal_type == 'steel', na.rm = TRUE),
        ', aluminum=', sum(annex_3$metal_type == 'aluminum', na.rm = TRUE), ')')

# =============================================================================
# Combine and write
# =============================================================================

all_annex <- bind_rows(annex_1a, annex_1b, annex_2, annex_3) %>%
  mutate(
    source = 'proclamation',
    effective_date = '2026-04-06'
  ) %>%
  # Remove dots from hts_prefix for consistent prefix matching (match tracker convention)
  mutate(hts_prefix = str_remove_all(hts_prefix, '\\.')) %>%
  distinct(hts_prefix, .keep_all = TRUE) %>%
  arrange(annex, metal_type, hts_prefix)

message('\n--- Summary ---')
message('Total unique codes: ', nrow(all_annex))
all_annex %>% count(annex, metal_type) %>%
  mutate(label = paste0('  ', annex, ' / ', coalesce(metal_type, 'unknown'), ': ', n)) %>%
  pull(label) %>% walk(message)

# Check for duplicates across annexes (should be resolved by distinct)
dups <- all_annex %>% group_by(hts_prefix) %>% filter(n() > 1)
if (nrow(dups) > 0) {
  message('\nWARNING: ', n_distinct(dups$hts_prefix), ' codes appear in multiple annexes (first annex kept)')
}

write_csv(all_annex, output_path)
message('\nWritten to: ', output_path)
message('Rows: ', nrow(all_annex))
