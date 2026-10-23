#!/usr/bin/env Rscript
# =============================================================================
# build_s338_annex.R — extract the Section 338 Canada product lists (Annex II)
# =============================================================================
# SOURCE: three Section 338 proclamations signed 2026-07-20 (effective
#   2026-08-22), imposing an additional 50% ad-valorem duty on products of
#   Canada over three positive HTS-8 lists, via new ch99 headings under U.S.
#   note 51 to subchapter III:
#     alcohol        -> 9903.03.12   (note 51(b)(1))
#     dairy          -> 9903.03.13   (note 51(b)(2))
#     motor_vehicles -> 9903.03.14   (note 51(b)(3) — despite the proclamation
#                       title, actual vehicles are §232-covered and excluded by
#                       note 51(c); the list is ~439 misc consumer-goods codes)
#   Text extracted from the proclamation PDFs at data/s338/ (see data/s338/text/).
#
#   SCOPE CHANGE 2026-09-15: Proclamations 11064 (alcohol) and 11065 (motor
#   vehicles) of 2026-09-08 add and drop products from lists (b)(1) and (b)(3)
#   and narrow some HTS-8 entries to 10-digit statistical lines. The dairy list
#   (b)(2) is unchanged. Their annexes are images in the Federal Register, so
#   the post-change lists are parsed from the HTS codification instead:
#   data/s338/text/note51_rev19.txt (HTS 2026 rev_19, Chapter 99 note 51).
#
# OUTPUTS:
#   resources/s338_products.csv — hts_code,program,ch99_heading,valid_from,
#     valid_until. One row per code x program x list version: the original
#     lists (valid 2026-08-22..2026-09-14) and the rev_19 lists (valid from
#     2026-09-15, valid_until blank = open-ended). hts_code is HTS-8, or HTS-10
#     where the note names a statistical line.
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
#     and is implemented as a per-row scope mask in the calculator. From
#     2026-09-15 it covers 9903.03.13 (dairy) only; see section_338 in
#     config/policy_params.yaml.
#
# USAGE: Rscript scripts/build_s338_annex.R   (base R only)
# =============================================================================

here_root <- tryCatch(here::here(), error = function(e) getwd())
txt_dir  <- file.path(here_root, 'data', 's338', 'text')
note51_rev19 <- 'note51_rev19.txt'
out_prod <- file.path(here_root, 'resources', 's338_products.csv')
out_gn6  <- file.path(here_root, 'resources', 's338_gn6_exempt_products.csv')

CODE_RE <- '[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}'
# HTS-8 or HTS-10 (the rev_19 note names some 10-digit statistical lines)
CODE_RE_10 <- '[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}([0-9]{2})?'

# List validity windows. The original lists run from the §338 turn-on to the
# day before PP 11064/11065; the rev_19 lists are open-ended.
ORIGINAL_VALID_FROM  <- '2026-08-22'
ORIGINAL_VALID_UNTIL <- '2026-09-14'
REV19_VALID_FROM     <- '2026-09-15'

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

# Collect every HTS-8/10 code strictly between two anchors. Used for the HTS
# Chapter 99 note text, whose lists run across page breaks (blank lines inside
# the block), which extract_block's stop-at-first-non-code-line rule would
# truncate. The anchor lines themselves are skipped: their prose cites heading
# numbers (9903.03.1x) that are not list members.
extract_between <- function(lines, start_re, end_re) {
  a <- grep(start_re, lines)
  b <- grep(end_re, lines)
  if (length(a) != 1 || length(b) != 1 || b <= a) {
    stop('anchors ', shQuote(start_re), ' / ', shQuote(end_re),
         ' matched ', length(a), ' / ', length(b), ' lines (want 1 / 1, in order)')
  }
  block <- lines[seq(a + 1, b - 1)]
  codes <- unlist(regmatches(block, gregexpr(CODE_RE_10, block)))
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

# Stop on a code named twice within one list, or on the same HTS-8 in two
# programs' lists of one version (the calculator would double-count it).
check_version <- function(prod, expected, label) {
  for (p in unique(prod$program)) {
    codes <- prod$hts_code[prod$program == p]
    if (anyDuplicated(codes)) {
      stop(label, ' program ', p, ': duplicate code within its list: ',
           paste(unique(codes[duplicated(codes)]), collapse = ', '))
    }
  }
  got <- table(prod$program)[names(expected)]
  if (!identical(as.integer(got), unname(expected))) {
    stop(label, ' row-count mismatch: expected ',
         paste(sprintf('%s=%d', names(expected), expected), collapse = ', '),
         '; got ', paste(sprintf('%s=%s', names(expected), got), collapse = ', '))
  }
  hts8_by_program <- unique(data.frame(hts8 = substr(prod$hts_code, 1, 8),
                                       program = prod$program))
  dups <- hts8_by_program$hts8[duplicated(hts8_by_program$hts8)]
  if (length(dups) > 0) {
    stop(label, ': hts8 present in more than one program list: ',
         paste(unique(dups), collapse = ', '))
  }
  # An HTS-8 listed whole AND through one of its HTS-10 lines is ambiguous
  # (is the whole heading covered, or only the named line?).
  hts8_whole <- prod$hts_code[nchar(prod$hts_code) == 8]
  hts8_of_10 <- substr(prod$hts_code[nchar(prod$hts_code) == 10], 1, 8)
  both <- intersect(hts8_whole, hts8_of_10)
  if (length(both) > 0) {
    stop(label, ': hts8 listed both whole and via an HTS-10 line: ',
         paste(both, collapse = ', '))
  }
}

# --- original lists (PP 11046/11047/11048 Annex II) --------------------------
original <- do.call(rbind, lapply(names(programs), function(p) {
  data.frame(hts_code = extract_block(programs[[p]]$txt, programs[[p]]$anchor),
             program = p, ch99_heading = programs[[p]]$heading,
             stringsAsFactors = FALSE)
}))
# Expected row counts from the proclamation annexes (hand-verified 2026-07-20).
expected_original <- c(alcohol = 63L, dairy = 52L, motor_vehicles = 439L)
check_version(original, expected_original, 'original')

# --- rev_19 lists (HTS 2026 rev_19 note 51(b), after PP 11064/11065) ---------
note51_txt <- read_annex(note51_rev19)
rev19_anchors <- c(
  alcohol        = 'Heading 9903\\.03\\.12 applies to articles classifiable',
  dairy          = 'Heading 9903\\.03\\.13 applies to articles classifiable',
  motor_vehicles = 'Heading 9903\\.03\\.14 applies to articles classifiable',
  end            = 'As provided in heading 9903\\.03\\.15')
rev19 <- do.call(rbind, lapply(seq_along(programs), function(k) {
  p <- names(programs)[k]
  data.frame(hts_code = extract_between(note51_txt, rev19_anchors[[k]],
                                        rev19_anchors[[k + 1]]),
             program = p, ch99_heading = programs[[p]]$heading,
             stringsAsFactors = FALSE)
}))
# Expected row counts from HTS 2026 rev_19 note 51(b) (hand-verified
# 2026-09-26 against an independent parse of the rev_19 Chapter 99 PDF; the
# same parse of rev_17 reproduces the original lists exactly).
expected_rev19 <- c(alcohol = 101L, dairy = 52L, motor_vehicles = 513L)
check_version(rev19, expected_rev19, 'rev_19')
if (!setequal(rev19$hts_code[rev19$program == 'dairy'],
              original$hts_code[original$program == 'dairy'])) {
  stop('rev_19 dairy list differs from the original — PP 11064/11065 do not ',
       'touch note 51(b)(2); re-check the extraction')
}

original$valid_from  <- ORIGINAL_VALID_FROM
original$valid_until <- ORIGINAL_VALID_UNTIL
rev19$valid_from     <- REV19_VALID_FROM
rev19$valid_until    <- ''
prod <- rbind(original, rev19)

# GN6 civil-aircraft list — note 51(d) (stated once, in the alcohol annex;
# unchanged by rev_19)
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

# Sort by version, then program, then code for a stable diff-able CSV
prod <- prod[order(prod$valid_from, match(prod$program, names(programs)),
                   prod$hts_code), ]

dir.create(dirname(out_prod), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(prod, out_prod, row.names = FALSE, quote = FALSE)
utils::write.csv(data.frame(hts8 = gn6, stringsAsFactors = FALSE),
                 out_gn6, row.names = FALSE, quote = FALSE)

for (v in list(list(label = 'original', rows = original, expected = expected_original),
               list(label = 'rev_19',   rows = rev19,    expected = expected_rev19))) {
  overlap <- lapply(names(programs), function(p)
    intersect(substr(v$rows$hts_code[v$rows$program == p], 1, 8), gn6))
  names(overlap) <- names(programs)
  message(sprintf('S338 %s lists (valid from %s): %s', v$label, v$rows$valid_from[1],
                  paste(sprintf('%s=%d', names(v$expected), v$expected), collapse = ', ')))
  message(sprintf('  covered ∩ GN6 overlap: %s',
                  paste(sprintf('%s=%d', names(overlap), lengths(overlap)), collapse = ', ')))
}
message(sprintf('GN6 note-51(d) list: %d hts8 -> %s', length(gn6), out_gn6))
message(sprintf('Wrote %d rows -> %s', nrow(prod), out_prod))
