#!/usr/bin/env Rscript
# =============================================================================
# Parse Section 232 annex product lists from the proclamation PDF (curator layer)
# =============================================================================
#
# Input:  docs/s232/annexes_layout.txt — column-preserving text of
#         docs/s232/Metals-ANNEXES-I-A-I-B-II-III-IV.pdf, produced with
#           pdftotext -layout docs/s232/Metals-ANNEXES-I-A-I-B-II-III-IV.pdf \
#                             docs/s232/annexes_layout.txt
#         (on the Yale cluster: module load poppler/25.07.0-GCC-13.3.0).
# Output: resources/s232_annex_products.csv — the rows with source =
#         'proclamation' are replaced wholesale; every other source
#         (us_note_16, proclamation_11032_*) is preserved as-is. Re-run
#           Rscript tools/scrape_us_notes.R --annex --annex-revision 2026_rev_5
#         afterwards so the Note 16(c) layer is re-merged against the new
#         curator layer (docs/s232/annex_parser.md, "Curator <-> parser merge").
#
# Usage:  Rscript scripts/parse_annex_products.R
#
# Each annex is a table whose FIRST column is the HTS code and whose second
# column is the description; descriptions wrap onto code-less lines. Only the
# code column is read. The previous version of this script scanned whole lines
# for anything HTS-shaped and so promoted headings named inside descriptions
# ("parts and accessories of the machines of heading 8471", "parts of
# subheading 8516.50", "parts of dies ... 8207.20.0070" -> 8207.20) to annex
# entries: computers were charged the 25% Annex I-B rate from 2026-04-06 on a
# heading the proclamation never lists (found 2026-11-08).
# =============================================================================

library(tidyverse)
library(here)

input_path  <- here('docs', 's232', 'annexes_layout.txt')
output_path <- here('resources', 's232_annex_products.csv')

ANNEX_EFFECTIVE_DATE <- '2026-04-06'
CURATOR_SOURCE       <- 'proclamation'
# A table row starts with the HTS code: NNNN, NNNN.NN, NNNN.NN.NN,
# NNNN.NN.NNNN (Annex III statistical suffix style) or NNNN.NN.NN.NN, followed
# by whitespace or end of line. A trailing period ("2027. If a product ...")
# is prose, not a code.
CODE_AT_LINE_START <- '^\\s*(\\d{4}(?:\\.\\d{2}(?:\\.\\d{2}(?:\\.\\d{2})?|\\.\\d{4})?)?)(?=\\s|$)'
# Metal sub-section headers: the metal name alone in the code column, with the
# "Description" column label optionally on the same line. "Derivatives" /
# "Articles" follows on its own line and is irrelevant to the metal type.
METAL_HEADER <- '^\\s*(Steel|Aluminum|Copper)\\s*(Description)?\\s*$'

stopifnot(file.exists(input_path))
lines <- readLines(input_path, warn = FALSE, encoding = 'UTF-8')
lines <- iconv(lines, from = 'UTF-8', to = 'UTF-8', sub = ' ')
lines <- gsub('\f', '', lines)

# =============================================================================
# Section boundaries
# =============================================================================

annex_1a_start <- which(grepl('Annex I-A:', lines))[1]
annex_1b_start <- which(grepl('Annex I-B:', lines))[1]
annex_2_start  <- which(grepl('Annex II:', lines))[1]
annex_3_start  <- which(grepl('Annex III:', lines))[1]
annex_4_start  <- which(grepl('^\\s*Annex IV\\s*$', lines))[1]
bounds <- c(annex_1a_start, annex_1b_start, annex_2_start, annex_3_start, annex_4_start)
if (any(is.na(bounds)) || any(diff(bounds) <= 0)) {
  stop('Annex section markers not found in order: ', paste(bounds, collapse = ', '))
}
message('Section boundaries: I-A ', annex_1a_start, ', I-B ', annex_1b_start,
        ', II ', annex_2_start, ', III ', annex_3_start, ', IV ', annex_4_start)

# =============================================================================
# Code-column extraction
# =============================================================================

parse_annex_section <- function(section_lines, annex_id) {
  metal <- NA_character_
  out <- vector('list', length(section_lines))
  for (i in seq_along(section_lines)) {
    line <- section_lines[i]
    header <- str_match(line, METAL_HEADER)[, 2]
    if (!is.na(header)) {
      metal <- tolower(header)
      next
    }
    code <- str_match(line, CODE_AT_LINE_START)[, 2]
    if (is.na(code)) next
    if (is.na(metal)) {
      stop('Annex ', annex_id, ': code ', code, ' appears before any metal header: ', trimws(line))
    }
    out[[i]] <- tibble(hts_prefix = str_remove_all(code, '\\.'), annex = annex_id, metal_type = metal)
  }
  bind_rows(out) %>% distinct()
}

sections <- list(
  '1a' = lines[annex_1a_start:(annex_1b_start - 1)],
  '1b' = lines[annex_1b_start:(annex_2_start - 1)],
  '2'  = lines[annex_2_start:(annex_3_start - 1)],
  '3'  = lines[annex_3_start:(annex_4_start - 1)]
)
parsed <- imap(sections, function(sec, id) {
  res <- parse_annex_section(sec, id)
  message('Annex ', id, ': ', nrow(res), ' codes (',
          paste(sprintf('%s=%d', names(table(res$metal_type)), table(res$metal_type)), collapse = ', '), ')')
  res
}) %>% bind_rows()

chapters <- as.integer(substr(parsed$hts_prefix, 1, 2))
if (any(is.na(chapters) | chapters < 1 | chapters > 97)) {
  stop('Non-HTS code extracted: ', paste(parsed$hts_prefix[is.na(chapters) | chapters < 1 | chapters > 97], collapse = ', '))
}

dups <- parsed %>% group_by(hts_prefix) %>% filter(n() > 1) %>% ungroup()
if (nrow(dups) > 0) {
  message('NOTE: ', n_distinct(dups$hts_prefix), ' codes listed in more than one annex; first annex kept: ',
          paste(unique(dups$hts_prefix), collapse = ', '))
}

curator <- parsed %>%
  distinct(hts_prefix, .keep_all = TRUE) %>%
  mutate(source = CURATOR_SOURCE, effective_date = ANNEX_EFFECTIVE_DATE)

# =============================================================================
# Merge: replace the curator layer, keep every other source
# =============================================================================

existing <- read_csv(output_path, col_types = cols(.default = col_character()), show_col_types = FALSE)
old_curator <- existing %>% filter(!is.na(source), source == CURATOR_SOURCE)
# Same rule as build_annex_products_for_revision(): a Note 16(c) parser row is
# suppressed where a curator prefix exists (curator wins); other curated
# sources (proclamation_11032_*) are kept unconditionally.
kept <- existing %>%
  filter(is.na(source) | source != CURATOR_SOURCE) %>%
  filter(!(source %in% 'us_note_16' & hts_prefix %in% curator$hts_prefix))

all_annex <- bind_rows(curator, kept) %>%
  arrange(annex, metal_type, hts_prefix)

removed <- anti_join(old_curator, curator, by = 'hts_prefix')
added   <- anti_join(curator, old_curator, by = 'hts_prefix')
changed <- inner_join(old_curator, curator, by = 'hts_prefix', suffix = c('_old', '_new')) %>%
  filter(annex_old != annex_new | metal_type_old != metal_type_new)
message('\nCurator layer: ', nrow(old_curator), ' -> ', nrow(curator), ' rows; ',
        nrow(removed), ' removed, ', nrow(added), ' added, ', nrow(changed), ' reclassified; ',
        nrow(kept), ' rows from other sources kept')
if (nrow(removed) > 0) message('  removed: ', paste(removed$hts_prefix, collapse = ' '))
if (nrow(added) > 0)   message('  added:   ', paste(added$hts_prefix, collapse = ' '))
if (nrow(changed) > 0) message('  reclassified: ', paste(changed$hts_prefix, collapse = ' '))

# A prefix may legitimately recur across sources with different effective
# dates (Proclamation 11032 moved lines between tiers from 2026-06-08;
# load_annex_products() picks the row in force). Within one date it may not.
if (any(duplicated(all_annex[, c('hts_prefix', 'effective_date')]))) {
  stop('Duplicate (hts_prefix, effective_date) after merge: ',
       paste(all_annex$hts_prefix[duplicated(all_annex[, c('hts_prefix', 'effective_date')])], collapse = ', '))
}
write_csv(all_annex, output_path)
message('\nWritten: ', output_path, ' (', nrow(all_annex), ' rows)')
