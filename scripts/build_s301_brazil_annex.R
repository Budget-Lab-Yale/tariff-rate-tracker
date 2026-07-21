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
# WHAT IS EXTRACTED — the product exemption lists of U.S. note 50(a), Annex I,
# kept as THREE separate lists because their legal force differs:
#   (a)(ii)  heading 9903.05.03 — flat HTSUS-subheading exclusion list (GPOTABLE)
#   (a)(iii) heading 9903.05.04 — 11 "particular articles" listed in prose
#            ("classifiable in subheading NNNN.NN.NN"); scope-limited (e.g.
#            religious use) but the model is hts8-grained -> flat exemptions
#            -> (a)(ii)+(a)(iii) together are the UNCONDITIONAL exemption file
#   (a)(iv)  heading 9903.05.05 — civil-aircraft list (GPOTABLE); exempt ONLY
#            for GN6 civil-aircraft use -> OWN file; the calculator scales
#            these lines by a utilization share (policy_params
#            aircraft_exempt_share) instead of exempting them flat
#   (a)(v)   heading 9903.05.06 — pharmaceutical-use list (GPOTABLE); exempt
#            only "for use in pharmaceutical applications" -> OWN file, scaled
#            by pharma_exempt_share (364 of these lines were UNCONDITIONAL in
#            the June proposal — the final action deliberately narrowed them,
#            so flat treatment would un-do the final action's change)
#   NOT here: (a)(vi)/9903.05.07 — the §232 full-article carve-out (steel/alu/
#   copper + derivatives, PV/LT + parts, MHD + parts, wood, semiconductors;
#   patented pharma added by Annex I Part B effective 2026-07-31). That is
#   implemented as a scope MASK in apply_section301_brazil() (06_calculate_
#   rates.R), the s338 note-51(c) pattern — not a product list. Donations /
#   informational materials (9903.05.08-.09) and the one-week in-transit window
#   (9903.05.02, load-before 07-22 + enter-before 07-29) are not modeled.
#
# OUTPUT (hts8,effective_date_start,effective_date_end — the FL-annex schema
# read by .resolve_s301fl_exempt() in src/model/authority_adapter.R):
#   resources/s301_brazil_exempt_products.csv   — 875 unconditional (864+11)
#   resources/s301_brazil_aircraft_products.csv — 546 civil-aircraft-use
#   resources/s301_brazil_pharma_products.csv   — 705 pharmaceutical-use
#
# NOTES / fidelity:
#   - The first GPOTABLE in the notice is the 9903.05.0x heading insert table —
#     excluded both by position (before the (a)(ii) marker) and by dropping
#     ch-99 codes.
#   - The aircraft list includes six ch-98 provisions (9802.00.40/.50/.60/.80,
#     9818.00.05/.07); kept, matching the June CSV's treatment (ch98 rows are
#     handled separately by the calculator's ch98 logic).
#   - 10-digit provisions (if any) are truncated to their 8-digit subheading,
#     as in the June parse (the calc matches on substr(hts10,1,8)).
#   - The three lists are asserted DISJOINT (they are in the notice; the calc's
#     precedence unconditional > aircraft > pharma would hide any overlap).
#
# USAGE: Rscript scripts/build_s301_brazil_annex.R   (base R only; no pdftools)
# =============================================================================

suppressWarnings({
  here_root <- tryCatch(here::here(), error = function(e) getwd())
})
xml_path <- file.path(here_root, 'docs', 's301_brazil', 'FR-2026-14542.xml')
out_paths <- c(
  exempt   = file.path(here_root, 'resources', 's301_brazil_exempt_products.csv'),
  aircraft = file.path(here_root, 'resources', 's301_brazil_aircraft_products.csv'),
  pharma   = file.path(here_root, 'resources', 's301_brazil_pharma_products.csv'))

if (!file.exists(xml_path)) {
  url <- 'https://www.federalregister.gov/documents/full_text/xml/2026/07/20/2026-14542.xml'
  message('Cached XML not found; downloading from ', url)
  dir.create(dirname(xml_path), recursive = TRUE, showWarnings = FALSE)
  utils::download.file(url, xml_path, quiet = TRUE)
}

xml <- paste(readLines(xml_path, warn = FALSE), collapse = '\n')

# --- segment the note-50(a) text by subdivision marker -----------------------
# Subdivisions print in order (ii) < (iii) < (iv) < (v) < (vi); each list's
# GPOTABLE(s) sit between its marker and the next.
markers <- c(ii = '(ii) As provided in heading 9903.05.03',
             iii = '(iii) As provided in heading 9903.05.04',
             iv = '(iv) As provided in heading 9903.05.05',
             v = '(v) As provided in heading 9903.05.06',
             vi = '(vi) As provided in heading 9903.05.07')
pos <- vapply(markers, function(m) {
  p <- regexpr(m, xml, fixed = TRUE)[1]
  if (p < 0) stop('Subdivision marker not found in XML: ', m)
  p
}, numeric(1))
if (is.unsorted(pos, strictly = TRUE)) stop('Subdivision markers out of order')
segment <- function(a, b) substr(xml, pos[[a]], pos[[b]] - 1L)

# --- table lists: every code-shaped ENT inside a GPOTABLE -------------------
# The note-50 lists print as 6-column code grids, so EVERY ENT is a code (the
# June proposed annex used 3-column rows where only ENT I="01" was the code).
table_codes <- function(txt) {
  tables <- regmatches(txt, gregexpr('<GPOTABLE.*?</GPOTABLE>', txt))[[1]]
  unlist(lapply(tables, function(t) {
    ents <- regmatches(t, gregexpr('<ENT[^>]*>\\s*[0-9]{4}\\.[0-9]{2}\\.[0-9]{2,4}\\s*</ENT>', t))[[1]]
    sub('.*<ENT[^>]*>\\s*([0-9.]+)\\s*</ENT>.*', '\\1', ents)
  }))
}

# --- prose lists: the 11 note-50(a)(iii) "particular articles" ---------------
seg_iii <- segment('iii', 'iv')
prose <- regmatches(seg_iii,
                    gregexpr('classifiable in subheading\\s+[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}', seg_iii))[[1]]
prose_codes <- sub('.*subheading\\s+', '', prose)

to_hts8 <- function(codes, label) {
  codes  <- trimws(codes)
  digits <- gsub('[^0-9]', '', codes)           # strip dots
  keep   <- substr(digits, 1, 2) != '99'        # drop any ch-99 heading rows
  codes  <- codes[keep]; digits <- digits[keep]
  n_ten  <- sum(nchar(digits) == 10)
  if (n_ten > 0) {
    ten <- codes[nchar(digits) == 10]
    message('  ', label, ': 10-digit provisions (truncated to hts8): ',
            paste(ten, collapse = ', '))
  }
  hts8 <- unique(substr(digits, 1, 8))
  sort(hts8[nchar(hts8) == 8])
}

lists <- list(
  exempt   = to_hts8(c(table_codes(segment('ii', 'iii')), prose_codes), 'exempt'),
  aircraft = to_hts8(table_codes(segment('iv', 'v')), 'aircraft'),
  pharma   = to_hts8(table_codes(segment('v', 'vi')), 'pharma'))

# The notice's three lists are disjoint; any overlap means a parse bug.
stopifnot(length(intersect(lists$exempt, lists$aircraft)) == 0,
          length(intersect(lists$exempt, lists$pharma)) == 0,
          length(intersect(lists$aircraft, lists$pharma)) == 0)

for (nm in names(lists)) {
  out <- data.frame(hts8 = lists[[nm]],
                    effective_date_start = NA_character_,
                    effective_date_end   = NA_character_,
                    stringsAsFactors = FALSE)
  dir.create(dirname(out_paths[[nm]]), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(out, out_paths[[nm]], row.names = FALSE, na = 'NA', quote = FALSE)
  message(sprintf('Wrote %d unique hts8 -> %s', nrow(out), out_paths[[nm]]))
}
message(sprintf('Brazil §301 FINAL Annex: %d unconditional (%d prose) + %d aircraft-use + %d pharma-use = %d total.',
                length(lists$exempt), length(prose_codes),
                length(lists$aircraft), length(lists$pharma),
                length(unique(unlist(lists)))))
