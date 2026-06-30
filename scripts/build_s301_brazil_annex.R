#!/usr/bin/env Rscript
# =============================================================================
# build_s301_brazil_annex.R — extract the Section 301 Brazil exemption Annex
# =============================================================================
# SOURCE: USTR "Notice of Determination ... Section 301: Brazil", FR Doc 2026-11158
#   (published 2026-06-04). The Annex of exempt HTSUS provisions is embedded in the
#   Federal Register full-text XML as a 3-column GPOTABLE (HTSUS / Description /
#   Scope limitations). Raw XML cached at docs/s301_brazil/FR-2026-11158.xml.
#   Canonical URL (un-blocked full-text path):
#   https://www.federalregister.gov/documents/full_text/xml/2026/06/04/2026-11158.xml
#
# OUTPUT: resources/s301_brazil_exempt_products.csv (hts8,effective_date_start,
#   effective_date_end) — same schema the FL annex uses, read by
#   .resolve_s301fl_exempt() (src/model/authority_adapter.R) for section_301_brazil.
#
# NOTES / fidelity:
#   - Each ROW's first <ENT I="01"> is the HTSUS provision; we take it as hts8.
#   - 4 provisions are 10-digit statistical lines (NNNN.NN.NNNN); the calc matches
#     exemptions on substr(hts10,1,8), so we truncate them to their 8-digit
#     subheading (over-exempts 4 sibling stat lines — immaterial; logged below).
#   - The ~546 "Aircraft" rows are exempt ONLY for civil-aircraft use; the model is
#     hts8-grained and can't see end-use, so they are taken as flat exemptions (a
#     model-wide granularity limit, also true of the FL annex). Logged.
#   - The notice ALSO carves out informational materials / donations / accompanied
#     baggage / "all articles and parts of articles subject to section 232 tariffs"
#     — the §232 carve-out is handled by the content_split stacking class (src/
#     stacking.R), NOT this list; the others are not modeled (negligible).
#
# USAGE: Rscript scripts/build_s301_brazil_annex.R   (base R only; no pdftools)
# =============================================================================

suppressWarnings({
  here_root <- tryCatch(here::here(), error = function(e) getwd())
})
xml_path <- file.path(here_root, 'docs', 's301_brazil', 'FR-2026-11158.xml')
out_path <- file.path(here_root, 'resources', 's301_brazil_exempt_products.csv')

if (!file.exists(xml_path)) {
  url <- 'https://www.federalregister.gov/documents/full_text/xml/2026/06/04/2026-11158.xml'
  message('Cached XML not found; downloading from ', url)
  dir.create(dirname(xml_path), recursive = TRUE, showWarnings = FALSE)
  utils::download.file(url, xml_path, quiet = TRUE)
}

lines <- readLines(xml_path, warn = FALSE)

# First <ENT I="01"> of each ROW = the HTSUS provision (8- or 10-digit, dotted).
ent_lines <- grep('<ENT I="01">[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}', lines, value = TRUE)
codes <- sub('.*<ENT I="01">\\s*([0-9.]+)\\s*</ENT>.*', '\\1', ent_lines)
codes <- trimws(codes)

digits <- gsub('[^0-9]', '', codes)           # strip dots
n_total  <- length(digits)
n_ten    <- sum(nchar(digits) == 10)
n_eight  <- sum(nchar(digits) == 8)
hts8 <- substr(digits, 1, 8)                  # truncate 10-digit stat lines to subheading
hts8 <- unique(hts8[nchar(hts8) == 8])

# Aircraft-scope provisions (logged for provenance; taken as flat exemptions).
n_aircraft <- sum(grepl('<ENT>Aircraft\\.</ENT>', lines))

out <- data.frame(hts8 = sort(hts8),
                  effective_date_start = NA_character_,
                  effective_date_end   = NA_character_,
                  stringsAsFactors = FALSE)
dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(out, out_path, row.names = FALSE, na = 'NA', quote = FALSE)

message(sprintf('Brazil §301 Annex: %d provisions parsed (%d eight-digit, %d ten-digit truncated), %d aircraft-scope.',
                n_total, n_eight, n_ten, n_aircraft))
message(sprintf('Wrote %d unique hts8 -> %s', nrow(out), out_path))
if (n_ten > 0) {
  ten <- codes[nchar(gsub('[^0-9]', '', codes)) == 10]
  message('  10-digit provisions (truncated to hts8): ', paste(ten, collapse = ', '))
}
