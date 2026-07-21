#!/usr/bin/env Rscript
# =============================================================================
# build_s338_annex.R — extract the Section 338 Canada product lists (Annex II)
# =============================================================================
# SOURCE: three Section 338 proclamations signed 2026-07-20 (effective
#   2026-08-19), imposing an additional 50% ad-valorem duty on products of
#   Canada over three positive HTS-8 lists, via new ch99 headings under U.S.
#   note 51 to subchapter III:
#     alcohol        -> 9903.03.12   (note 51(b)(1))
#     dairy          -> 9903.03.13   (note 51(b)(2))
#     motor_vehicles -> 9903.03.14   (note 51(b)(3) — despite the proclamation
#                       title, actual vehicles are §232-covered and excluded by
#                       note 51(c); the list is ~439 misc consumer-goods codes)
#   Text extracted from the proclamation PDFs at data/s338/ (see data/s338/text/).
#
# OUTPUTS:
#   resources/s338_products.csv          — hts8,program,ch99_heading (the merged
#     positive coverage list; one row per hts8 x program)
#   resources/s338_gn6_exempt_products.csv — hts8 (the note 51(d) civil-aircraft
#     GN6 list from heading 9903.03.16; USE-conditional, so the calc scales
#     covered∩GN6 lines by measured GN6 utilization rather than exempting
#     full-line — see apply_section338 in src/pipeline/06_calculate_rates.R)
#
# NOTES / fidelity:
#   - The note 51(d) list is stated once (in the alcohol proclamation's Annex II)
#     and extended to 9903.03.13/.14 by the dairy/autos proclamations' textual
#     amendments, so it is parsed from s338_alcohol_annex2.txt only.
#   - The 51(d) list includes ch98 provisions (9802.00.40-.80, 9818.00.05/.07);
#     they are kept in the CSV verbatim (they never intersect the covered lists).
#   - The §232 full exclusion (note 51(c) / heading 9903.03.15) is NOT a product
#     list — it is heading-defined ("articles provided for in 9903.82.x/94.x/...")
#     and is implemented as a per-row scope mask in the calculator.
#
# USAGE: Rscript scripts/build_s338_annex.R   (base R only)
# =============================================================================

here_root <- tryCatch(here::here(), error = function(e) getwd())
txt_dir  <- file.path(here_root, 'data', 's338', 'text')
out_prod <- file.path(here_root, 'resources', 's338_products.csv')
out_gn6  <- file.path(here_root, 'resources', 's338_gn6_exempt_products.csv')

CODE_RE <- '[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}'

# A "code line" consists solely of NNNN.NN.NN tokens, whitespace, and an
# optional closing typographic quote on the last list line.
is_code_line <- function(line) {
  stripped <- gsub(CODE_RE, '', line)
  stripped <- gsub('[”"’]', '', stripped)   # closing quotes
  grepl(CODE_RE, line) && trimws(stripped) == ''
}

# Collect the code block that follows `anchor_re`: skip to the first code line
# after the anchor, then read code lines (blank lines allowed only BEFORE the
# block starts) until the first non-code line.
extract_block <- function(lines, anchor_re) {
  a <- grep(anchor_re, lines)
  if (length(a) != 1) {
    stop('anchor ', shQuote(anchor_re), ' matched ', length(a), ' lines (want 1)')
  }
  codes <- character(0); started <- FALSE
  for (i in seq(a + 1, length(lines))) {
    if (is_code_line(lines[i])) {
      started <- TRUE
      codes <- c(codes, regmatches(lines[i], gregexpr(CODE_RE, lines[i]))[[1]])
    } else if (started || trimws(lines[i]) != '') {
      if (started) break
      # non-blank prose before the block starts: keep scanning (the anchor
      # sentence can wrap onto a continuation line)
    }
  }
  if (!started) stop('no code block found after anchor ', shQuote(anchor_re))
  gsub('\\.', '', codes)
}

# Normalize pdftotext artifacts: form-feed page breaks and non-breaking spaces
# would otherwise make a mid-list page boundary look like a non-code line.
read_annex <- function(file) {
  lines <- readLines(file.path(txt_dir, file), warn = FALSE)
  gsub('[\f ]', ' ', lines)
}

alcohol_txt <- read_annex('s338_alcohol_annex2.txt')
dairy_txt   <- read_annex('s338_dairy_annex2.txt')
autos_txt   <- read_annex('s338_autos_annex2.txt')

# Covered lists — note 51(b)(1)/(2)/(3)
programs <- list(
  alcohol        = list(txt = alcohol_txt, heading = '9903.03.12',
                        anchor = 'Heading 9903\\.03\\.12 applies to articles classifiable'),
  dairy          = list(txt = dairy_txt,   heading = '9903.03.13',
                        anchor = 'Heading 9903\\.03\\.13 applies to articles classifiable'),
  motor_vehicles = list(txt = autos_txt,   heading = '9903.03.14',
                        anchor = 'Heading 9903\\.03\\.14 applies to articles classifiable')
)

prod <- do.call(rbind, lapply(names(programs), function(p) {
  codes <- extract_block(programs[[p]]$txt, programs[[p]]$anchor)
  if (anyDuplicated(codes)) {
    stop('program ', p, ': duplicate hts8 within its annex list: ',
         paste(unique(codes[duplicated(codes)]), collapse = ', '))
  }
  data.frame(hts8 = codes, program = p,
             ch99_heading = programs[[p]]$heading, stringsAsFactors = FALSE)
}))

# Expected row counts from the proclamation annexes (hand-verified 2026-07-20).
expected <- c(alcohol = 63L, dairy = 52L, motor_vehicles = 439L)
got <- table(prod$program)[names(expected)]
if (!identical(as.integer(got), unname(expected))) {
  stop('annex row-count mismatch: expected ',
       paste(sprintf('%s=%d', names(expected), expected), collapse = ', '),
       '; got ', paste(sprintf('%s=%s', names(expected), got), collapse = ', '))
}
dups <- prod$hts8[duplicated(prod$hts8)]
if (length(dups) > 0) {
  stop('hts8 present in more than one program list: ', paste(unique(dups), collapse = ', '))
}

# GN6 civil-aircraft list — note 51(d) (stated once, in the alcohol annex)
gn6 <- extract_block(alcohol_txt, 'appears in the .Special. subcolumn')
gn6 <- sort(unique(gn6))

# Guard the GN6 count like the covered lists above: extract_block breaks at the
# first blank/non-code line once started, so a re-extraction under a different
# pdftotext/poppler could silently truncate the 554-code block at a page break.
# Without this stop() the short list writes cleanly and covered∩GN6 lines then
# lose their utilization scaling (pay the full 0.50). Hand-verified 2026-07-20.
expected_gn6 <- 554L
if (length(gn6) != expected_gn6) {
  stop('GN6 note-51(d) row-count mismatch: expected ', expected_gn6,
       ', got ', length(gn6),
       ' — likely a pdftotext page-break truncation in extract_block')
}

# Sort covered list within program for a stable diff-able CSV
prod <- prod[order(match(prod$program, names(programs)), prod$hts8), ]

dir.create(dirname(out_prod), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(prod, out_prod, row.names = FALSE, quote = FALSE)
utils::write.csv(data.frame(hts8 = gn6, stringsAsFactors = FALSE),
                 out_gn6, row.names = FALSE, quote = FALSE)

overlap <- lapply(names(programs), function(p) intersect(prod$hts8[prod$program == p], gn6))
names(overlap) <- names(programs)
message(sprintf('S338 covered lists: %s (total %d unique hts8)',
                paste(sprintf('%s=%d', names(expected), expected), collapse = ', '),
                length(unique(prod$hts8))))
message(sprintf('GN6 note-51(d) list: %d hts8 -> %s', length(gn6), out_gn6))
message(sprintf('covered ∩ GN6 overlap: %s',
                paste(sprintf('%s=%d', names(overlap), lengths(overlap)), collapse = ', ')))
if (length(overlap$motor_vehicles))
  message('  mv∩GN6: ', paste(overlap$motor_vehicles, collapse = ', '))
message(sprintf('Wrote %d rows -> %s', nrow(prod), out_prod))
