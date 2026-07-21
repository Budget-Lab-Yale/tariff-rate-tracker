#!/usr/bin/env Rscript
# =============================================================================
# build_s301_brazil_annex.R — extract the Section 301 Brazil exemption lists
# =============================================================================
# SOURCE (FINAL ACTION): USTR "Notice of Action ... Section 301: Brazil",
#   FR Doc 2026-14542 (published 2026-07-20; effective 2026-07-22). Supersedes
#   the June 4, 2026 proposed annex (FR Doc 2026-11158) this script previously
#   parsed — the June XML stays cached alongside for provenance/diffing.
#   Raw XML cached at docs/s301_brazil/FR-2026-14542.xml. Canonical URL
#   (un-blocked full-text path):
#   https://www.federalregister.gov/documents/full_text/xml/2026/07/20/2026-14542.xml
#   Signed-PDF copy: data/s301_brazil/brazil_301_final_action_frn_2026-07-15.pdf
#
# WHAT IS EXTRACTED — the product exemption lists of U.S. note 50(a), Annex I:
#   (a)(ii)  heading 9903.05.03 — flat HTSUS-subheading exclusion list (GPOTABLE)
#   (a)(iii) heading 9903.05.04 — 11 "particular articles" listed in prose
#            ("classifiable in subheading NNNN.NN.NN"); scope-limited (e.g.
#            religious use) but the model is hts8-grained -> flat exemptions
#   (a)(iv)  heading 9903.05.05 — civil-aircraft list (GPOTABLE); exempt ONLY
#            for GN6 civil-aircraft use; hts8-grained model -> flat exemptions
#            (same granularity limit as the FL annex; over-exempts non-aircraft
#            entries under those lines)
#   (a)(v)   heading 9903.05.06 — pharmaceutical-use list (GPOTABLE); use-
#            conditional ("for use in pharmaceutical applications") -> flat
#   NOT here: (a)(vi)/9903.05.07 — the §232 full-article carve-out (steel/alu/
#   copper + derivatives, PV/LT + parts, MHD + parts, wood, semiconductors;
#   patented pharma added by Annex I Part B effective 2026-07-31). That is
#   implemented as a scope MASK in apply_section301_brazil() (06_calculate_
#   rates.R), the s338 note-51(c) pattern — not a product list. Donations /
#   informational materials (9903.05.08-.09) and the one-week in-transit window
#   (9903.05.02, load-before 07-22 + enter-before 07-29) are not modeled.
#
# OUTPUT: resources/s301_brazil_exempt_products.csv (hts8,effective_date_start,
#   effective_date_end) — same schema the FL annex uses, read by
#   .resolve_s301fl_exempt() (src/model/authority_adapter.R) for section_301_brazil.
#
# NOTES / fidelity:
#   - The first GPOTABLE in the notice is the 9903.05.0x heading insert table —
#     excluded by dropping ch-99 codes.
#   - The aircraft list includes six ch-98 provisions (9802.00.40/.50/.60/.80,
#     9818.00.05/.07); kept, matching the June CSV's treatment (ch98 rows are
#     handled separately by the calculator's ch98 logic).
#   - 10-digit provisions (if any) are truncated to their 8-digit subheading,
#     as in the June parse (the calc matches on substr(hts10,1,8)).
#
# USAGE: Rscript scripts/build_s301_brazil_annex.R   (base R only; no pdftools)
# =============================================================================

suppressWarnings({
  here_root <- tryCatch(here::here(), error = function(e) getwd())
})
xml_path <- file.path(here_root, 'docs', 's301_brazil', 'FR-2026-14542.xml')
out_path <- file.path(here_root, 'resources', 's301_brazil_exempt_products.csv')

if (!file.exists(xml_path)) {
  url <- 'https://www.federalregister.gov/documents/full_text/xml/2026/07/20/2026-14542.xml'
  message('Cached XML not found; downloading from ', url)
  dir.create(dirname(xml_path), recursive = TRUE, showWarnings = FALSE)
  utils::download.file(url, xml_path, quiet = TRUE)
}

xml <- paste(readLines(xml_path, warn = FALSE), collapse = '\n')

# --- table lists: every code-shaped ENT inside a GPOTABLE -------------------
# The note-50 lists print as 6-column code grids, so EVERY ENT is a code (the
# June proposed annex used 3-column rows where only ENT I="01" was the code).
tables <- regmatches(xml, gregexpr('<GPOTABLE.*?</GPOTABLE>', xml))[[1]]
table_codes <- unlist(lapply(tables, function(t) {
  ents <- regmatches(t, gregexpr('<ENT[^>]*>\\s*[0-9]{4}\\.[0-9]{2}\\.[0-9]{2,4}\\s*</ENT>', t))[[1]]
  sub('.*<ENT[^>]*>\\s*([0-9.]+)\\s*</ENT>.*', '\\1', ents)
}))

# --- prose lists: the 11 note-50(a)(iii) "particular articles" ---------------
prose <- regmatches(xml, gregexpr('classifiable in subheading\\s+[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}', xml))[[1]]
prose_codes <- sub('.*subheading\\s+', '', prose)

codes <- trimws(c(table_codes, prose_codes))
digits <- gsub('[^0-9]', '', codes)           # strip dots
codes  <- codes[substr(digits, 1, 2) != '99'] # drop the ch-99 heading table
digits <- digits[substr(digits, 1, 2) != '99']

n_total <- length(digits)
n_ten   <- sum(nchar(digits) == 10)
n_eight <- sum(nchar(digits) == 8)
hts8 <- substr(digits, 1, 8)                  # truncate 10-digit stat lines
hts8 <- unique(hts8[nchar(hts8) == 8])

out <- data.frame(hts8 = sort(hts8),
                  effective_date_start = NA_character_,
                  effective_date_end   = NA_character_,
                  stringsAsFactors = FALSE)
dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(out, out_path, row.names = FALSE, na = 'NA', quote = FALSE)

message(sprintf('Brazil §301 FINAL Annex: %d provisions parsed (%d eight-digit, %d ten-digit truncated; %d from prose).',
                n_total, n_eight, n_ten, length(prose_codes)))
message(sprintf('Wrote %d unique hts8 -> %s', nrow(out), out_path))
if (n_ten > 0) {
  ten <- codes[nchar(gsub('[^0-9]', '', codes)) == 10]
  message('  10-digit provisions (truncated to hts8): ', paste(ten, collapse = ', '))
}
