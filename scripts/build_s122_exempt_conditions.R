# =============================================================================
# Stamp the `condition` column on resources/s122_exempt_products.csv and build
# resources/s122_aircraft_utilization.csv
# =============================================================================
#
# Source of record: U.S. note 2(aa) to subchapter III, chapter 99
# (data/us_notes/chapter99_<rev>.txt). The note's three product exemptions:
#   (aa)(ii)  / 9903.03.03 — unconditional product list      -> condition 'none'
#   (aa)(iii) / 9903.03.04 — particular articles             -> condition 'none'
#   (aa)(iv)  / 9903.03.05 — civil aircraft "that otherwise
#              meet the criteria of general note 6"          -> condition
#              'gn6_civil_aircraft' (USE-conditional: only GN6-certified
#              entries are exempt; see docs/s122_aircraft_exemption_audit.md)
#
# Rows on the (aa)(iv) list get 'gn6_civil_aircraft' UNLESS they are also on
# the unconditional (aa)(ii)/(iii) lists (unconditional wins) or are ch98
# lines (handled by the ch98 value-basis machinery — left unconditional, see
# audit §5). The known-benign residual 9031.49.70 (provenance audit
# 2026-06-15) is aircraft-list-adjacent and gets 'gn6_civil_aircraft'.
#
# The utilization file is the audit's measurement
# (output/diagnostics/s122_aircraft_line_utilization.csv — IMDB Mar–May 2026
# realized-rate classification, ex-USMCA, no 232/301 contamination), filtered
# to non-ch98 lines. exempt_share ≈ the GN6 legal-scope share of the line
# (claiming 9903.03.05 at entry is near-costless — U3 statutory framing).
#
# Idempotent. Usage:
#   Rscript scripts/build_s122_exempt_conditions.R [--notes data/us_notes/chapter99_2026_rev_5.txt]
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})

argv <- commandArgs(trailingOnly = TRUE)
notes_path <- if (length(argv) >= 2 && argv[1] == '--notes') argv[2] else
  here('data', 'us_notes', 'chapter99_2026_rev_5.txt')
if (!file.exists(notes_path)) stop('Notes text not found: ', notes_path)

txt <- readLines(notes_path)
extract_codes <- function(lines) {
  m <- unlist(regmatches(lines, gregexpr('[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}', lines)))
  unique(gsub('\\.', '', m))
}
s2 <- grep('\\(ii\\)\\s+As provided in heading 9903\\.03\\.03', txt)[1]
s3 <- grep('As provided in heading 9903\\.03\\.04', txt)[1]
s4 <- grep('As provided in heading 9903\\.03\\.05', txt)[1]
s5 <- grep('^\\s*\\(v\\)', txt); s5 <- s5[s5 > s4][1]
if (any(is.na(c(s2, s3, s4, s5)))) stop('Could not locate note 2(aa)(ii)-(v) anchors in ', notes_path)

aa_uncond <- union(extract_codes(txt[s2:(s3 - 1)]), extract_codes(txt[s3:(s4 - 1)]))
aa_gn6    <- extract_codes(txt[s4:(s5 - 1)])
message('Parsed note 2(aa): ', length(aa_uncond), ' unconditional + ',
        length(aa_gn6), ' GN6-conditional codes')

# ---- stamp the condition column ---------------------------------------------
csv_path <- here('resources', 's122_exempt_products.csv')
ex <- read_csv(csv_path, col_types = cols(hts8 = col_character(), .default = col_character()))
ex$condition <- case_when(
  ex$hts8 %in% aa_uncond            ~ 'none',            # unconditional wins on overlap
  substr(ex$hts8, 1, 2) == '98'     ~ 'none',            # ch98 machinery governs
  ex$hts8 %in% aa_gn6               ~ 'gn6_civil_aircraft',
  ex$hts8 == '90314970'             ~ 'gn6_civil_aircraft',  # known aircraft-instrument residual
  TRUE                              ~ 'UNTRACEABLE'
)
if (any(ex$condition == 'UNTRACEABLE')) {
  stop('Untraceable rows (fix before writing): ',
       paste(ex$hts8[ex$condition == 'UNTRACEABLE'], collapse = ', '))
}
write_csv(ex, csv_path)
message('Wrote ', csv_path, ': ', sum(ex$condition == 'none'), ' none + ',
        sum(ex$condition == 'gn6_civil_aircraft'), ' gn6_civil_aircraft')

# ---- utilization resource from the audit measurement ------------------------
meas_path <- here('output', 'diagnostics', 's122_aircraft_line_utilization.csv')
if (file.exists(meas_path)) {
  util <- read_csv(meas_path, show_col_types = FALSE) %>%
    filter(substr(hts10, 1, 2) != '98') %>%
    transmute(hts10,
              exempt_share = pmin(pmax(exempt_share, 0), 1),
              con_val, months) %>%
    arrange(desc(con_val))
  out <- here('resources', 's122_aircraft_utilization.csv')
  write_csv(util, out)
  message('Wrote ', out, ': ', nrow(util), ' measured lines (IMDB window per audit doc)')
} else {
  message('Measurement file missing (', meas_path, ') — utilization CSV not rebuilt')
}
