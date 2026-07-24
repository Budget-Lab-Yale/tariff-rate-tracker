#!/usr/bin/env Rscript

# Build the machine-readable final-action exemption inputs from a `pdftotext
# -layout` rendering of USTR's July 23, 2026 pre-publication notice.
#
# Usage:
#   module load poppler/25.07.0-GCC-13.3.0
#   pdftotext -layout FLIP-final-action.pdf /tmp/s301fl-final.txt
#   Rscript scripts/build_s301fl_final_annex.R /tmp/s301fl-final.txt
#
# Source:
# https://ustr.gov/sites/default/files/files/Press/Releases/2026/
# FLIP%20301%20Investigation%20Final%20Action%20FRN%207-23-26%20FINAL.pdf

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L || !file.exists(args[[1]])) {
  stop('Pass the path to a `pdftotext -layout` rendering of the final notice.')
}

lines <- readLines(args[[1]], warn = FALSE, encoding = 'UTF-8')

# Locate the body occurrence of each Annex II part (the first occurrence is the
# table of contents). Repeated page headers remain inside a part and are ignored.
part_title <- c(
  A = 'Part A. Goods of Any Investigated Economy',
  B = 'Part B. Goods of the United Kingdom',
  C = 'Part C. Goods of Any Member State of the European Union',
  D = 'Part D. Goods of Switzerland',
  E = 'Part E. Goods of Malaysia',
  F = 'Part F. Goods of Cambodia',
  G = 'Part G. Goods of Guatemala',
  H = 'Part H. Goods of El Salvador',
  I = 'Part I. Goods of Argentina',
  J = 'Part J. Goods of Bangladesh',
  K = 'Part K. Goods of Taiwan',
  L = 'Part L. Goods of Indonesia',
  M = 'Part M. Goods of Ecuador',
  N = 'Part N. Goods of Jordan',
  O = 'Part O. Textile and Apparel Goods'
)

part_start <- vapply(part_title, function(title) {
  compact_lines <- gsub('\\s+', ' ', trimws(lines))
  hits <- grep(title, compact_lines, fixed = TRUE)
  annex_ii <- grep('^\\s*ANNEX II\\s*$', lines)[1]
  body_hits <- hits[hits > annex_ii]
  if (length(body_hits) < 2L) {
    stop('Could not find body occurrence for ', title)
  }
  body_hits[[2]]
}, integer(1))

extract_part <- function(part) {
  i <- match(part, names(part_start))
  from <- part_start[[part]]
  to <- if (i < length(part_start)) part_start[[i + 1L]] - 1L else length(lines)
  x <- lines[from:to]
  hit <- stringr::str_match(
    x, '^\\s*([0-9]{4}\\.[0-9]{2}\\.[0-9]{2}(?:[0-9]{2})?)\\s+')
  keep <- !is.na(hit[, 2])
  code <- gsub('.', '', hit[keep, 2], fixed = TRUE)
  tail_word <- sub('^.*\\s+(\\S+)\\s*$', '\\1', x[keep])
  condition <- ifelse(tail_word %in% c('Aircraft', 'Pharma', 'Ex'),
                      tolower(tail_word), 'full')
  tibble(part = part, hts_code = code, condition = condition) %>% distinct()
}

annex <- bind_rows(lapply(names(part_start), extract_part))

# Part A applies to every investigated economy. Conditional end-use rows remain
# separate so the calculator can apply utilization shares instead of treating
# the whole HTS provision as exempt. "Ex" rows are necessarily HTS-granular in
# this model and are tagged explicitly for auditability.
common <- annex %>%
  filter(part == 'A') %>%
  select(hts_code, condition) %>%
  arrange(hts_code, condition)

eu <- c('4010', '4050', '4099', '4190', '4210', '4231', '4239', '4279',
        '4280', '4330', '4351', '4359', '4370', '4470', '4490', '4510',
        '4550', '4700', '4710', '4730', '4759', '4791', '4792', '4840',
        '4850', '4870', '4910')

part_countries <- list(
  B = '4120', C = eu, D = '4419', E = '5570', F = '5550',
  G = '2050', H = '2110', I = '3570', J = '5380', K = '5830',
  L = '5600', M = '3310', N = '5110'
)

country_specific <- bind_rows(lapply(names(part_countries), function(p) {
  annex %>%
    filter(.data$part == p) %>%
    transmute(countries = paste(part_countries[[p]], collapse = ';'),
              hts_code, condition)
}))

# Part O is the notice's enumerated textile/apparel universe, with two distinct
# legal conditions:
#   * Jordan: UNCONDITIONAL — note 52(j)(13)(i) / heading 9903.06.20 exempts the
#     full Jordan list outright (Part N + Part O = that one list, 1,889 codes),
#     with no FTA-claim requirement. Emitted as condition 'full'.
#   * The six CAFTA-DR origins (note 52(i) / heading 9903.05.95: Costa Rica,
#     Dominican Republic, El Salvador, Guatemala, Honduras, Nicaragua):
#     preference-conditional — exempt when entered free of duty under CAFTA-DR.
#     El Salvador/Guatemala additionally have the enumerated (j)(6)(iii)/
#     (j)(7)(iii) lists under the same CAFTA-claim condition. The calculator
#     proxies the claim rate with the existing HS2×country MFN-exemption share.
#     (2026-07-23 fix: this list previously carried 4890 = Türkiye — a 12.5%
#     flat economy with no US preference program — instead of 2190 Nicaragua.)
cafta_origins <- c('2050', '2110', '2150', '2190', '2230', '2470')
part_o <- annex %>% filter(part == 'O')
preference <- bind_rows(
  part_o %>% transmute(countries = paste(cafta_origins, collapse = ';'),
                       hts_code, condition = 'fta'),
  part_o %>% transmute(countries = '5110', hts_code, condition = 'full')
) %>%
  distinct()

country_specific <- bind_rows(country_specific, preference) %>%
  mutate(condition = if_else(condition == 'ex', 'full', condition)) %>%
  distinct(countries, hts_code, condition) %>%
  arrange(countries, hts_code, condition)

message('Parsed rows by part: ',
        paste(names(part_start), vapply(names(part_start), function(p) {
          sum(annex$part == p)
        }, integer(1)), collapse = ', '))

stopifnot(
  nrow(common) == 2120L,
  sum(common$condition == 'full') == 863L,
  sum(common$condition == 'ex') == 16L,
  sum(common$condition == 'aircraft') == 541L,
  sum(common$condition == 'pharma') == 700L,
  nrow(country_specific) > 3000L
)

write_csv(common, 'resources/s301fl_final_common_exemptions.csv', na = '')
write_csv(country_specific, 'resources/s301fl_final_country_exemptions.csv', na = '')

message('Wrote ', nrow(common), ' common and ', nrow(country_specific),
        ' country/product exemption rows.')
