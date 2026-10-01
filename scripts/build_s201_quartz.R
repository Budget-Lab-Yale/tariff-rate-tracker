# =============================================================================
# build_s201_quartz.R — Section 201 quartz surface products (U.S. note 41)
# =============================================================================
# Parses data/s201_quartz/note41_rev17.txt (verbatim legal-note text, extracted
# from the HTS 2026 rev_17 Chapter 99 PDF) into two side-data resources:
#
#   resources/s201_quartz_products.csv         hts10 scope from note 41(a)
#   resources/s201_quartz_exempt_countries.csv census codes from note 41(c)
#
# WHY side-data: U.S. notes are not in the USITC JSON export. Only the two
# heading rows 9903.45.30 (in-quota) and 9903.45.31 (over-quota) reach the JSON,
# and those carry the RATES only — the product scope, the exempt-country roster,
# the quota quantities and the four-year step-down schedule all live in the note.
# The rates are therefore read from the HTS (extract_section201_quartz_rates);
# everything else comes from here. Same split as §338 note 51(b).
#
# Fails loudly on any note-41(c) country name that does not resolve to a census
# code: a silently dropped exemption would over-apply the safeguard.
#
# Usage: Rscript scripts/build_s201_quartz.R
# =============================================================================

suppressPackageStartupMessages({
  library(here); library(tidyverse)
})
source(here('src', 'core', 'helpers.R'))

NOTE_PATH <- here('data', 's201_quartz', 'note41_rev17.txt')
OUT_PRODUCTS <- here('resources', 's201_quartz_products.csv')
OUT_EXEMPT   <- here('resources', 's201_quartz_exempt_countries.csv')

if (!file.exists(NOTE_PATH)) stop('note 41 source text not found: ', NOTE_PATH)
note <- paste(readLines(NOTE_PATH, warn = FALSE, encoding = 'UTF-8'), collapse = '\n')

# --- (a) product scope -------------------------------------------------------
# "The scope covers imported products provided for under HTSUS subheadings
#  6810.99.0020, 6810.99.0040, and 7020.00.6000."
scope_line <- str_match(
  note, 'The scope covers imported products provided for under HTSUS subheadings([^.]*(?:\\.[^.]*){0,6}?)\\.\\s')[, 2]
if (is.na(scope_line)) stop('could not locate the note 41(a) scope sentence')

hts10 <- str_extract_all(scope_line, '[0-9]{4}\\.[0-9]{2}\\.[0-9]{4}')[[1]] %>%
  str_replace_all('[.]', '') %>% unique()
if (length(hts10) != 3) {
  stop('note 41(a): expected 3 HTS10 scope codes, parsed ', length(hts10),
       ' (', paste(hts10, collapse = ', '), ')')
}
message('note 41(a) scope: ', paste(hts10, collapse = ', '))

products <- tibble(hts10 = hts10, note = 'US note 41(a) QSP scope')

# --- (c) exempt countries ----------------------------------------------------
# Subdivisions (i) FTA/USMCA, (ii) FTA partners, (iii) developing countries,
# (iv) CBERA beneficiaries. Take the whole (c) block and split on commas.
c_block <- str_match(note, '(?s)\\(c\\)\\n(.*?)\\n\\(d\\)\\n')[, 2]
if (is.na(c_block)) stop('could not locate the note 41(c) block')
# drop the lead-in sentence and the subdivision lead-ins
c_body <- c_block %>%
  str_remove('(?s)^.*?provided for therein:') %>%
  str_remove_all('\\((i|ii|iii|iv)\\)') %>%
  str_remove_all('The following developing countries:') %>%
  str_remove_all('The following Caribbean Basin Economic Recovery Act beneficiary countries and territories:') %>%
  str_replace_all('\\n', ' ') %>%
  str_replace_all(';', ',')

# Split on commas ONLY, then strip a leading conjunction. Splitting on 'and'
# too would shred the six roster names that contain it (Bosnia and Hercegovina,
# Saint Vincent and the Grenadines, Sao Tome and Principe, Antigua and Barbuda,
# Saint Kitts and Nevis, Trinidad and Tobago).
raw_names <- str_split(c_body, ',')[[1]] %>%
  str_squish() %>%
  str_remove('^and ') %>%
  str_remove('[.]$') %>%
  str_squish() %>%
  discard(~ .x == '')
raw_names <- unique(raw_names)
message('note 41(c): ', length(raw_names), ' distinct country names parsed')

# --- resolve names -> census codes -------------------------------------------
census <- read_csv(here('resources', 'census_codes.csv'),
                   col_types = cols(.default = col_character()))
norm <- function(x) {
  x %>% str_to_lower() %>%
    str_replace_all('’', "'") %>%
    # strip accents so 'Cote d Ivoire' / 'Sao Tome' match regardless of encoding
    iconv(to = 'ASCII//TRANSLIT') %>%
    str_replace_all('[^a-z ]', ' ') %>% str_squish()
}
census_norm <- norm(census$Name)

# Census names carry parenthetical and 'except' qualifiers; match on the
# leading segment as well as the full string.
census_lead <- census_norm %>% str_remove(' *\\(.*$') %>% str_remove(',.*$') %>% str_squish()

# Note-41 name -> census name, where the two schedules differ.
ALIASES <- c(
  'congo brazzaville'   = 'congo republic of the congo',
  'congo kinshasa'      = 'congo democratic republic of the congo',
  'the gambia'          = 'gambia',
  'the bahamas'         = 'bahamas',
  'bosnia and hercegovina' = 'bosnia and herzegovina',  # note spells it Hercegovina
  'cape verde'          = 'cabo verde',               # note uses the pre-2013 name
  'yemen republic of'   = 'yemen',
  'burma'               = 'burma'                     # census: 'Burma (Myanmar)'
)

resolve_one <- function(nm) {
  key <- norm(nm)
  if (key %in% names(ALIASES)) key <- ALIASES[[key]]
  hit <- which(census_norm == key)
  if (length(hit) == 0) hit <- which(census_lead == key)
  if (length(hit) == 0) hit <- which(str_starts(census_norm, fixed(key)))
  if (length(hit) == 0) return(NA_character_)
  census$Code[hit[1]]
}

# A fragment may still hold a terminal conjunction ('Zambia and Zimbabwe') that
# the comma split could not separate. Resolve the whole fragment FIRST — six
# roster names legitimately contain 'and' (Bosnia and Hercegovina, Sao Tome and
# Principe, ...) — and only split on ' and ' when the whole fails to resolve.
resolve_fragment <- function(nm) {
  whole <- resolve_one(nm)
  if (!is.na(whole)) return(stats::setNames(whole, nm))
  if (!str_detect(nm, ' and ')) return(stats::setNames(NA_character_, nm))
  parts <- str_split(nm, ' and ')[[1]] %>% str_squish()
  stats::setNames(map_chr(parts, resolve_one), parts)
}

resolved <- unlist(map(raw_names, resolve_fragment))
codes <- unname(resolved)
raw_names <- names(resolved)
unresolved <- raw_names[is.na(codes)]
if (length(unresolved) > 0) {
  stop('note 41(c): ', length(unresolved), ' country name(s) did not resolve to ',
       'a census code — fix ALIASES rather than dropping them:\n  ',
       paste(unresolved, collapse = '\n  '))
}

exempt <- tibble(country = raw_names, code = codes) %>%
  distinct(code, .keep_all = TRUE) %>%
  arrange(code)
message('note 41(c): ', nrow(exempt), ' distinct census codes exempt')

# --- write -------------------------------------------------------------------
write_csv(products, OUT_PRODUCTS)
write_csv(exempt, OUT_EXEMPT)
message('wrote ', OUT_PRODUCTS, ' (', nrow(products), ' rows)')
message('wrote ', OUT_EXEMPT, ' (', nrow(exempt), ' rows)')
