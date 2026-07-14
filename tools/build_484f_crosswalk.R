# =============================================================================
# 484(f) HTS Crosswalk Builder
# =============================================================================
#
# One-shot builder that extracts explicit old->new HTS10 transfer edges from the
# USITC 484(f) Committee change documents (`data/484f/*.pdf`) and writes the
# committed production resource `resources/hts10_484f_transfers.csv`.
#
# PRODUCTION PIPELINES READ ONLY THE COMMITTED CSV. They never re-parse the
# PDFs: `pdftools` is not installed on the cluster R and the PDF layout must not
# be a build dependency. This file exists to (re)generate the committed CSV when
# a source document is added or corrected, and to hold the pure, CI-testable
# grammar that `tests/test_484f_parser.R` pins.
#
# Design (see docs/wondrous_spinning_frost_plan_review.md §2.1, §2.5, §4.3):
#
#   1. PDF text extraction (`extract_484f_pages()`, needs pdftools) is SEPARATED
#      from a pure line grammar `parse_484f_lines()`. The grammar takes a
#      character vector of lines and is testable without any PDF toolchain.
#
#   2. The grammar carries NOMENCLATURE SECTION STATE (HTS / SCHEDULE_B /
#      UNKNOWN). 484(f) documents interleave `HTS History` and `Schedule B
#      History` tables that share code grammar and action vocabulary. Only HTS
#      rows enter the import crosswalk; Schedule B rows are classified (for
#      audit) and EXCLUDED. An action row seen under UNKNOWN nomenclature fails
#      loudly. (Verified: Jul-2025 Terbufos has successor 2930.90.4330 with a
#      *different* HTS predecessor 2930.90.4395 vs Schedule B predecessor
#      2930.90.4398 — a row-level regex without section state would fabricate a
#      false import transfer.)
#
#   3. BOTH SIDES of every transfer are emitted as raw `edge_assertion` rows:
#      the old-side verbs (Discontinued / Deleted / Annotated / Renumbered ...
#      "transferred to") and the new-side verb (Established ... "transferred
#      from"). They are reconciled to canonical edges with a status
#      (both_sides / old_only / new_only / overridden). An unresolved two-sided
#      inconsistency fails the build.
#
#   4. Document source typos are corrected ONLY through the committed
#      `resources/hts10_484f_overrides.csv` (data, never parser conditionals).
#      An override that matches nothing (stale/unused) fails the build; a used
#      override stamps its `override_id` into the resulting transfer row.
#
# Archive-coverage validation (does every disappearing/established ordinary-
# merchandise code in the cached HTS universes have an edge here, both
# directions?) lives in `validate_484f_coverage()` and runs by default.
#
# Text extraction prefers pdftools on the committed PDF, but falls back to the
# committed poppler text sidecar (`data/484f/text/<doc>.txt`, hash-verified)
# when pdftools is absent — so the crosswalk regenerates on the cluster R
# (which has no PDF toolchain) without changing the auditable PDF source.
#
# Usage (one-shot):
#   Rscript tools/build_484f_crosswalk.R              # extract + reconcile + coverage + write
#   Rscript tools/build_484f_crosswalk.R --dry-run    # all validation, no write
#   Rscript tools/build_484f_crosswalk.R --no-coverage  # parser only
#
# CI runs the pure grammar via tests/test_484f_parser.R; it does NOT run this
# builder end-to-end (no pdftools, no committed PDFs on the runner beyond the
# small source set).
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})

# -----------------------------------------------------------------------------
# Constants / grammar vocabulary
# -----------------------------------------------------------------------------

# Dotted 10-digit HTS code as printed, e.g. 0603.19.0137 (4 . 2 . 4).
HTS_CODE_RE <- '[0-9]{4}\\.[0-9]{2}\\.[0-9]{4}'

# Effective date as printed, e.g. 2025/01/01.
EFF_DATE_RE <- '(20[0-9]{2})/([0-9]{2})/([0-9]{2})'

# Action verbs. Established is the NEW side (successor "transferred from" the
# old code). The remainder are OLD side (old code "transferred to" successors).
NEW_SIDE_VERBS <- c('Established')
OLD_SIDE_VERBS <- c('Discontinued', 'Deleted', 'Annotated', 'Renumbered')
ALL_VERBS      <- c(NEW_SIDE_VERBS, OLD_SIDE_VERBS)

# A record-start line: leading dotted code followed by one of the action verbs.
RECORD_START_RE <- sprintf('^\\s*(%s)\\s+(%s)\\b',
                           HTS_CODE_RE, paste(ALL_VERBS, collapse = '|'))

# Nomenclature-heading detectors. Order matters only in that we test both and a
# line cannot be both. `HTS Changes` / `Schedule B Changes` are the supplement
# sub-table headings (Jan-2026 pharmaceutical supplement).
HTS_HEADING_RE <- '^\\s*HTS\\s+(History|Code|Changes)\\b'
SCHED_B_HEADING_RE <-
  '(Schedule\\W*B\\W*(History|Code|Changes))|(^\\s*Schedule B\\s*$)'

# Supplement "Renumbered As:" table header (three columns: <old-code-column>,
# Article Description, Renumbered As:). The old-code column is labeled
# "Discontinued Number" in the Jan-2026 pharmaceutical supplement and "Deleted
# Number" in the Jul-2026 one — both introduce the same old->new renumbering grid.
SUPPLEMENT_HEADER_RE <- '(Discontinued|Deleted) Number.*Renumbered As'

# A numbered product-section header, e.g. "10.    HTS 3004.90.92  Supplement ...".
# Clears supplement state.
SECTION_HEADER_RE <- '^\\s*[0-9]+\\.\\s+(HTS|Sch\\.?\\s*B)\\b'

# -----------------------------------------------------------------------------
# Normalization helpers
# -----------------------------------------------------------------------------

#' Normalize a dotted HTS code to a 10-digit string.
#'
#' Returns NA_character_ for anything that is not exactly 10 digits after
#' stripping dots and internal whitespace. Callers decide whether NA is fatal.
normalize_hts10 <- function(code_as_printed) {
  stripped <- gsub('[.[:space:]]', '', code_as_printed)
  ifelse(grepl('^[0-9]{10}$', stripped), stripped, NA_character_)
}

#' First non-NA element of a vector, or NA (typed to the input) if none.
first_non_na <- function(x) {
  x <- x[!is.na(x)]
  if (length(x)) x[[1]] else x[NA_integer_]
}

#' Minimum finite value of a numeric vector as integer, or NA if none finite.
min_finite_int <- function(x) {
  x <- x[is.finite(x)]
  if (length(x)) as.integer(min(x)) else NA_integer_
}

#' Extract HTS code tokens (as printed) from a line/record, tolerant of
#' misplaced dots.
#'
#' Returns every maximal run of digits-and-dots that normalizes to exactly 10
#' digits, preserving the literal printed form. This deliberately catches
#' source dot-placement typos such as "39.21.19.0090" (a printing error for
#' "3921.19.0090") — both normalize to 3921190090, so the transfer is recovered
#' without a manual override. Runs that do not normalize to 10 digits (dates,
#' 6-digit subheadings, "(pt.)", concatenation errors) are dropped. Codes with a
#' genuinely different digit sequence are NOT silently repaired — those still
#' fail two-sided validation and require a committed override.
extract_code_tokens <- function(text) {
  runs <- regmatches(text, gregexpr('[0-9][0-9.]*[0-9]', text))[[1]]
  if (length(runs) == 0) return(character(0))
  norm <- gsub('[.[:space:]]', '', runs)
  runs[grepl('^[0-9]{10}$', norm)]
}

#' Convert a printed 2025/01/01 date to ISO 2025-01-01. NA if not present.
iso_effective_date <- function(record_text) {
  m <- regmatches(record_text, regexpr(EFF_DATE_RE, record_text))
  if (length(m) == 0 || !nzchar(m)) return(NA_character_)
  gsub('/', '-', m)
}

# -----------------------------------------------------------------------------
# Line stitching: join wrapped continuation lines onto their record-start line.
# -----------------------------------------------------------------------------

#' Group physical lines into logical records.
#'
#' A record begins at a RECORD_START_RE line and absorbs following non-blank
#' lines that are NOT themselves record starts, headings, section headers, or
#' bare page numbers — these are wrapped continuations of the "transferred to"
#' / "transferred from" clause (e.g. "and 0603.19.0197).").
#'
#' Returns a tibble: start_index (1-based line index of the record start),
#' text (space-joined record), and n_lines.
stitch_records <- function(lines) {
  is_blank    <- !nzchar(trimws(lines))
  is_start    <- grepl(RECORD_START_RE, lines)
  is_pagenum  <- grepl('^\\s*[0-9]{1,4}\\s*$', lines)
  is_hts_head <- grepl(HTS_HEADING_RE, lines)
  is_sb_head  <- grepl(SCHED_B_HEADING_RE, lines)
  is_section  <- grepl(SECTION_HEADER_RE, lines)
  # A line that terminates a continuation run (cannot be absorbed).
  breaks <- is_blank | is_start | is_pagenum | is_hts_head | is_sb_head | is_section

  starts <- which(is_start)
  if (length(starts) == 0) {
    return(tibble(start_index = integer(), text = character(), n_lines = integer()))
  }

  map_dfr(starts, function(i) {
    j <- i
    repeat {
      nxt <- j + 1
      if (nxt > length(lines) || breaks[nxt]) break
      j <- nxt
    }
    tibble(start_index = i,
           text = paste(trimws(lines[i:j]), collapse = ' '),
           n_lines = j - i + 1)
  })
}

# -----------------------------------------------------------------------------
# Pure grammar: parse lines -> edge assertions
# -----------------------------------------------------------------------------

#' Parse 484(f) document lines into raw edge assertions (pure; no PDF toolchain).
#'
#' Emits one row per asserted (old, new) relationship, from BOTH the old-action
#' rows ("transferred to" successors) and the new-action rows ("transferred
#' from" predecessors), plus supplement "Renumbered As:" rows. Reconciliation
#' and override application happen downstream in `reconcile_484f_edges()`.
#'
#' @param lines character vector of extracted PDF lines (reading order).
#' @param source_doc basename of the source PDF (stamped into every row).
#' @param page_of_line optional integer vector, same length as `lines`, giving
#'   the 1-based PDF page of each line (stamped as source_page). NA when absent.
#' @param strict if TRUE (default), an action row under UNKNOWN nomenclature and
#'   a supplement row with no resolvable effective date are errors.
#' @return tibble of edge assertions (see columns below).
parse_484f_lines <- function(lines, source_doc, page_of_line = NULL, strict = TRUE) {
  stopifnot(is.character(lines), length(source_doc) == 1L)
  if (is.null(page_of_line)) page_of_line <- rep(NA_integer_, length(lines))
  stopifnot(length(page_of_line) == length(lines))

  # --- Pass 1: derive nomenclature + supplement state per line index ---------
  nomenclature <- rep(NA_character_, length(lines))
  supplement   <- rep(FALSE, length(lines))
  last_eff_iso <- rep(NA_character_, length(lines))

  state_nom <- 'UNKNOWN'
  state_sup <- FALSE
  state_eff <- NA_character_
  for (k in seq_along(lines)) {
    ln <- lines[k]
    # Section header clears supplement mode (new product section).
    if (grepl(SECTION_HEADER_RE, ln)) state_sup <- FALSE
    # Nomenclature headings. HTS Changes / Schedule B Changes also switch here.
    if (grepl(HTS_HEADING_RE, ln)) {
      state_nom <- 'HTS'
      state_sup <- FALSE
    } else if (grepl(SCHED_B_HEADING_RE, ln)) {
      state_nom <- 'SCHEDULE_B'
      state_sup <- FALSE
    }
    # Supplement table header turns on supplement mode within current section.
    if (grepl(SUPPLEMENT_HEADER_RE, ln)) state_sup <- TRUE
    # Track the most recent effective date seen (supplement rows inherit it).
    eff_here <- iso_effective_date(ln)
    if (!is.na(eff_here)) state_eff <- eff_here

    nomenclature[k] <- state_nom
    supplement[k]   <- state_sup
    last_eff_iso[k] <- state_eff
  }

  assertions <- list()
  emit <- function(...) assertions[[length(assertions) + 1L]] <<- tibble(...)

  # --- Pass 2a: standard action-row records ----------------------------------
  records <- stitch_records(lines)
  record_index <- 0L
  for (r in seq_len(nrow(records))) {
    i    <- records$start_index[r]
    text <- records$text[r]
    nom  <- nomenclature[i]
    page <- page_of_line[i]
    record_index <- record_index + 1L
    row_id <- sprintf('%s#r%04d', source_doc, record_index)

    # Leading code + verb. Code tokens are extracted tolerantly (see
    # extract_code_tokens): the first token is the row's subject code.
    all_codes <- extract_code_tokens(text)
    lead_code <- if (length(all_codes)) all_codes[1] else NA_character_
    verb <- regmatches(text, regexpr(paste(ALL_VERBS, collapse = '|'), text))
    eff  <- iso_effective_date(text)

    if (identical(nom, 'UNKNOWN') || is.na(nom)) {
      if (strict) {
        stop(sprintf('parse_484f_lines: action row under UNKNOWN nomenclature in %s: "%s"',
                     source_doc, trimws(text)), call. = FALSE)
      }
    }

    # Codes other than the leading one, in order (successors or predecessors).
    other_codes <- if (length(all_codes) > 1) all_codes[-1] else character(0)

    is_new_side <- verb %in% NEW_SIDE_VERBS
    has_transfer <- grepl('transferred', text, ignore.case = TRUE)
    # partial: the clause carries "(pt.)".
    partial <- grepl('\\(\\s*pt\\.?\\s*\\)', text)

    if (is_new_side) {
      # Established: this code is NEW; predecessors are the "from" codes.
      if (length(other_codes) == 0) {
        emit(source_doc = source_doc, source_row_id = row_id,
             record_index = record_index, source_page = page,
             nomenclature = nom, table = 'standard', side = 'new_action',
             verb = verb, old_as_printed = NA_character_,
             new_as_printed = lead_code, effective_date = eff,
             partial = partial, no_successor = FALSE)
      } else {
        for (oc in other_codes) {
          emit(source_doc = source_doc, source_row_id = row_id,
               record_index = record_index, source_page = page,
               nomenclature = nom, table = 'standard', side = 'new_action',
               verb = verb, old_as_printed = oc,
               new_as_printed = lead_code, effective_date = eff,
               partial = partial, no_successor = FALSE)
        }
      }
    } else {
      # Old-side verb: this code is OLD; successors are the "to" codes.
      if (!has_transfer || length(other_codes) == 0) {
        # Genuine deletion without a successor.
        emit(source_doc = source_doc, source_row_id = row_id,
             record_index = record_index, source_page = page,
             nomenclature = nom, table = 'standard', side = 'old_action',
             verb = verb, old_as_printed = lead_code,
             new_as_printed = NA_character_, effective_date = eff,
             partial = partial, no_successor = TRUE)
      } else {
        for (sc in other_codes) {
          emit(source_doc = source_doc, source_row_id = row_id,
               record_index = record_index, source_page = page,
               nomenclature = nom, table = 'standard', side = 'old_action',
               verb = verb, old_as_printed = lead_code,
               new_as_printed = sc, effective_date = eff,
               partial = partial, no_successor = FALSE)
        }
      }
    }
  }

  # --- Pass 2b: supplement "Renumbered As:" rows -----------------------------
  # A supplement transfer row has exactly two dotted codes on one physical line:
  # <old_code> <article description...> <new_code>. Continuation (description)
  # lines carry no codes and are skipped. Effective date is inherited from the
  # most recent standard action-row date in the section (last_eff_iso).
  supp_idx <- which(supplement & !grepl(RECORD_START_RE, lines))
  for (k in supp_idx) {
    ln <- lines[k]
    codes <- extract_code_tokens(ln)
    if (length(codes) < 2) next            # header / description continuation
    old_c <- codes[1]
    new_c <- codes[length(codes)]
    eff   <- last_eff_iso[k]
    if (is.na(eff)) {
      if (strict) {
        stop(sprintf('parse_484f_lines: supplement row with no resolvable effective date in %s: "%s"',
                     source_doc, trimws(ln)), call. = FALSE)
      }
    }
    record_index <- record_index + 1L
    emit(source_doc = source_doc,
         source_row_id = sprintf('%s#s%04d', source_doc, record_index),
         record_index = record_index, source_page = page_of_line[k],
         nomenclature = nomenclature[k], table = 'supplement',
         side = 'supplement', verb = 'Renumbered',
         old_as_printed = old_c, new_as_printed = new_c,
         effective_date = eff, partial = FALSE, no_successor = FALSE)
  }

  out <- if (length(assertions)) bind_rows(assertions) else
    tibble(source_doc = character(), source_row_id = character(),
           record_index = integer(), source_page = integer(),
           nomenclature = character(), table = character(), side = character(),
           verb = character(), old_as_printed = character(),
           new_as_printed = character(), effective_date = character(),
           partial = logical(), no_successor = logical())

  # Normalized codes alongside the literal printed values.
  out %>%
    mutate(
      old_hts10 = normalize_hts10(old_as_printed),
      new_hts10 = normalize_hts10(new_as_printed),
      override_id = NA_character_
    )
}

# -----------------------------------------------------------------------------
# Overrides: correct documented source typos (data, not parser conditionals)
# -----------------------------------------------------------------------------

OVERRIDES_SCHEMA <- c('override_id', 'source_doc', 'side', 'source_row_id',
                      'old_hts10_as_printed', 'new_hts10_as_printed',
                      'corrected_old_hts10', 'corrected_new_hts10',
                      'reason', 'evidence', 'approved_by')

#' Load and validate the committed overrides table.
load_484f_overrides <- function(path = here('resources', 'hts10_484f_overrides.csv')) {
  if (!file.exists(path)) {
    return(tibble(!!!setNames(rep(list(character()), length(OVERRIDES_SCHEMA)),
                              OVERRIDES_SCHEMA)))
  }
  ov <- readr::read_csv(path, col_types = readr::cols(.default = readr::col_character()))
  missing <- setdiff(OVERRIDES_SCHEMA, names(ov))
  if (length(missing)) {
    stop('hts10_484f_overrides.csv missing columns: ',
         paste(missing, collapse = ', '), call. = FALSE)
  }
  if (any(duplicated(ov$override_id))) {
    stop('hts10_484f_overrides.csv has duplicate override_id values.', call. = FALSE)
  }
  ov
}

#' Apply overrides to raw assertions, matching on the literal printed edge.
#'
#' Match key: (source_doc, side, old_as_printed, new_as_printed). On match the
#' corrected codes replace the printed/normalized values and `override_id` is
#' stamped. Every override MUST match at least one assertion or the build fails
#' (stale/unused override). Returns the updated assertions.
apply_484f_overrides <- function(assertions, overrides) {
  if (nrow(overrides) == 0) return(assertions)
  assertions$.__ovr_used <- NA_character_
  used <- rep(FALSE, nrow(overrides))

  for (o in seq_len(nrow(overrides))) {
    ov <- overrides[o, ]
    hit <- assertions$source_doc == ov$source_doc &
      assertions$side == ov$side &
      assertions$old_as_printed == ov$old_hts10_as_printed &
      assertions$new_as_printed == ov$new_hts10_as_printed
    hit[is.na(hit)] <- FALSE
    if (!any(hit)) next
    used[o] <- TRUE
    assertions$old_as_printed[hit] <- ov$corrected_old_hts10
    assertions$new_as_printed[hit] <- ov$corrected_new_hts10
    assertions$old_hts10[hit]      <- normalize_hts10(ov$corrected_old_hts10)
    assertions$new_hts10[hit]      <- normalize_hts10(ov$corrected_new_hts10)
    assertions$override_id[hit]    <- ov$override_id
  }

  if (any(!used)) {
    stop('Unused/stale 484(f) overrides (matched no source assertion): ',
         paste(overrides$override_id[!used], collapse = ', '),
         '. Overrides must match the literal printed edge exactly.',
         call. = FALSE)
  }
  assertions$.__ovr_used <- NULL
  assertions
}

# -----------------------------------------------------------------------------
# Reconciliation: assertions -> canonical edges (+ two-sided consistency)
# -----------------------------------------------------------------------------

TRANSFERS_SCHEMA <- c('old_hts10', 'new_hts10', 'effective_date', 'change_type',
                      'partial', 'action_old', 'action_new', 'nomenclature',
                      'same_date_reuse', 'source_doc', 'source_doc_sha256',
                      'source_page', 'source_row_id', 'override_id')

#' Reconcile raw assertions (post-override) into canonical HTS transfer edges.
#'
#' - Splits out Schedule B assertions (excluded from the production resource but
#'   returned for audit).
#' - Runs the two-sided consistency check on HTS standard edges: for an old code
#'   C at a given effective date, if both an old-action "transferred to" row and
#'   at least one Established-"transferred from"-C row exist, the successor sets
#'   must be identical. A surviving mismatch is fatal (must be fixed by an
#'   override).
#' - Emits canonical edges with change_type, same_date_reuse, and both actions.
#'
#' @return list(transfers, schedule_b, inconsistencies, status_summary).
reconcile_484f_edges <- function(assertions, source_hashes = NULL, strict = TRUE) {
  sched_b <- assertions %>% filter(nomenclature == 'SCHEDULE_B')
  hts     <- assertions %>% filter(nomenclature == 'HTS')

  # --- Two-sided consistency (HTS standard edges only) ----------------------
  std <- hts %>% filter(table == 'standard')
  old_sets <- std %>%
    filter(side == 'old_action', !no_successor, !is.na(new_hts10)) %>%
    distinct(old_hts10, effective_date, new_hts10)
  new_sets <- std %>%
    filter(side == 'new_action', !is.na(old_hts10)) %>%
    distinct(old_hts10, effective_date, new_hts10)

  # Old codes that appear on BOTH sides at a date -> successor sets must match.
  keys_both <- inner_join(
    old_sets %>% distinct(old_hts10, effective_date),
    new_sets %>% distinct(old_hts10, effective_date),
    by = c('old_hts10', 'effective_date')
  )
  inconsistencies <- keys_both %>%
    pmap_dfr(function(old_hts10, effective_date) {
      s_old <- old_sets %>%
        filter(old_hts10 == !!old_hts10, effective_date == !!effective_date) %>%
        pull(new_hts10)
      s_new <- new_sets %>%
        filter(old_hts10 == !!old_hts10, effective_date == !!effective_date) %>%
        pull(new_hts10)
      if (setequal(s_old, s_new)) return(tibble())
      tibble(old_hts10 = old_hts10, effective_date = effective_date,
             old_side_only = paste(sort(setdiff(s_old, s_new)), collapse = ';'),
             new_side_only = paste(sort(setdiff(s_new, s_old)), collapse = ';'))
    })

  if (nrow(inconsistencies) > 0 && strict) {
    msg <- inconsistencies %>%
      mutate(line = sprintf('  %s @ %s: old-side-only={%s} new-side-only={%s}',
                            old_hts10, effective_date, old_side_only, new_side_only)) %>%
      pull(line) %>% paste(collapse = '\n')
    stop('Unresolved two-sided 484(f) inconsistencies (add a committed ',
         'override for each after confirming against the rendered PDF):\n', msg,
         call. = FALSE)
  }

  # --- Canonical edges -------------------------------------------------------
  # Effective (old, new) pairs come from either side plus supplement rows.
  edge_rows <- hts %>%
    filter(!(side == 'old_action' & no_successor)) %>%
    filter(!is.na(old_hts10), !is.na(new_hts10))

  no_succ_rows <- hts %>% filter(side == 'old_action', no_successor)

  # Per-(old,new,date) reduction, carrying provenance and both action verbs.
  canonical <- edge_rows %>%
    group_by(old_hts10, new_hts10, effective_date, nomenclature) %>%
    summarise(
      partial      = any(partial),
      action_old   = first_non_na(verb[side == 'old_action']),
      action_new   = first_non_na(verb[side == 'new_action']),
      source_doc   = first(source_doc),
      source_page  = min_finite_int(source_page),
      source_row_id = paste(sort(unique(source_row_id)), collapse = ';'),
      override_id  = first_non_na(override_id),
      has_old_side = any(side == 'old_action'),
      has_new_side = any(side %in% c('new_action')),
      has_supp     = any(side == 'supplement'),
      .groups = 'drop'
    )

  # Append explicit no_successor edges (new_hts10 = NA).
  no_succ_edges <- no_succ_rows %>%
    distinct(old_hts10, effective_date, nomenclature, verb, source_doc,
             source_page, source_row_id, override_id) %>%
    transmute(old_hts10, new_hts10 = NA_character_, effective_date, nomenclature,
              partial = FALSE, action_old = verb, action_new = NA_character_,
              source_doc, source_page, source_row_id, override_id,
              has_old_side = TRUE, has_new_side = FALSE, has_supp = FALSE)

  canonical <- bind_rows(canonical, no_succ_edges)

  # change_type from degrees within (effective_date, nomenclature).
  deg <- canonical %>%
    filter(!is.na(new_hts10)) %>%
    group_by(effective_date, nomenclature)
  out_deg <- deg %>% distinct(old_hts10, new_hts10) %>% count(old_hts10, name = 'outdeg')
  in_deg  <- deg %>% distinct(old_hts10, new_hts10) %>% count(new_hts10, name = 'indeg')

  # same_date_reuse: a new_hts10 that is also an old_hts10 on the same date.
  reuse <- canonical %>%
    filter(!is.na(new_hts10)) %>%
    group_by(effective_date) %>%
    summarise(reused = list(intersect(new_hts10, old_hts10)), .groups = 'drop')

  canonical <- canonical %>%
    left_join(out_deg, by = c('effective_date', 'nomenclature', 'old_hts10')) %>%
    left_join(in_deg,  by = c('effective_date', 'nomenclature', 'new_hts10')) %>%
    left_join(reuse, by = 'effective_date') %>%
    mutate(
      change_type = case_when(
        is.na(new_hts10)            ~ 'no_successor',
        outdeg == 1 & indeg == 1    ~ 'rename',
        outdeg  > 1 & indeg == 1    ~ 'split',
        outdeg == 1 & indeg  > 1    ~ 'merge',
        TRUE                        ~ 'many_to_many'
      ),
      same_date_reuse = map2_lgl(new_hts10, reused,
                                 ~ !is.na(.x) && (.x %in% .y)),
      status = case_when(
        !is.na(override_id)          ~ 'overridden',
        has_old_side & has_new_side  ~ 'both_sides',
        has_supp                     ~ 'supplement',
        has_old_side                 ~ 'old_only',
        TRUE                         ~ 'new_only'
      )
    )

  # Self-edge guard. A code X mapping to itself on one effective date is only
  # legitimate as SAME-DATE REUSE: the old-X identity is discontinued/deleted
  # AND a new-X identity is Established "transferred from X" on the same date
  # (X keeps its number for a redefined commodity). That case is confirmed by a
  # new-side (Established) assertion — has_new_side == TRUE — and is kept, with
  # same_date_reuse = TRUE (the versioned-identity mapper distinguishes the two
  # identities). A self-reference that appears WITHOUT re-establishment
  # (has_new_side == FALSE, e.g. an old-side "transferred to X" typo where X is
  # not actually re-established) is a source error and must be fixed by a
  # committed override.
  bad_self_edges <- canonical %>%
    filter(!is.na(new_hts10), old_hts10 == new_hts10, !has_new_side)
  if (nrow(bad_self_edges) > 0 && strict) {
    msg <- bad_self_edges %>%
      mutate(line = sprintf('  %s -> itself @ %s (no Established-from-self row)',
                            old_hts10, effective_date)) %>%
      pull(line) %>% paste(collapse = '\n')
    stop('Illegitimate self-edge(s) in 484(f) transfers — a code transfers to ',
         'itself but is not re-established (add a committed override after ',
         'confirming against the rendered PDF):\n', msg, call. = FALSE)
  }

  # Attach source hashes if provided (source_doc -> sha256).
  if (!is.null(source_hashes)) {
    canonical <- canonical %>%
      left_join(source_hashes, by = 'source_doc')
  } else {
    canonical <- canonical %>% mutate(source_doc_sha256 = NA_character_)
  }

  transfers <- canonical %>%
    transmute(old_hts10, new_hts10, effective_date, change_type, partial,
              action_old, action_new, nomenclature, same_date_reuse,
              source_doc, source_doc_sha256, source_page, source_row_id,
              override_id) %>%
    arrange(effective_date, old_hts10, new_hts10)

  status_summary <- canonical %>% count(status, name = 'n_edges')

  list(transfers = transfers, schedule_b = sched_b,
       inconsistencies = inconsistencies, status_summary = status_summary)
}

# -----------------------------------------------------------------------------
# Text extraction (pdftools when available; committed poppler sidecar otherwise)
# -----------------------------------------------------------------------------
#
# The source of truth is the committed PDF (`data/484f/<doc>.pdf`, hash-verified
# in source_manifest.csv). `pdftools` (poppler) is the canonical extractor but is
# NOT installed on the cluster R, so we also commit the exact poppler text
# extraction as a form-feed-delimited sidecar (`data/484f/text/<doc>.txt`, its
# own hash in source_manifest.csv `text_sha256`). This keeps CROSSWALK
# REGENERATION reproducible on the cluster without a PDF toolchain, while the PDF
# remains the auditable primary. When pdftools IS present the sidecar is bypassed
# and text comes straight from the PDF (a mismatch would then surface as a
# two-sided / coverage failure).

#' Sidecar text path for a source doc basename (484f_2025-01.pdf -> .../text/484f_2025-01.txt).
sidecar_text_path <- function(source_doc, dir_484f = here('data', '484f')) {
  file.path(dir_484f, 'text', sub('\\.pdf$', '.txt', source_doc))
}

#' Split a poppler text dump into per-page vectors of lines.
#'
#' pdftools::pdf_text() and `pdftotext` both separate pages with a form feed
#' (\f). We split on \f into pages, then each page on newlines. Trailing empty
#' page fragments (a final \f) are dropped.
split_text_to_pages <- function(text) {
  pages <- strsplit(text, '\f', fixed = TRUE)[[1]]
  pages <- pages[nzchar(pages) | seq_along(pages) < length(pages)]
  lapply(pages, function(p) strsplit(p, '\n', fixed = TRUE)[[1]])
}

#' Extract source text as a list of per-page character vectors of lines.
#'
#' Prefers pdftools on the raw PDF; falls back to the committed, hash-verified
#' text sidecar. `expected_text_sha256` (from the manifest) is enforced against
#' the sidecar when the fallback path is taken.
extract_484f_pages <- function(pdf_path, source_doc = basename(pdf_path),
                               dir_484f = dirname(pdf_path),
                               expected_text_sha256 = NA_character_) {
  if (requireNamespace('pdftools', quietly = TRUE) && file.exists(pdf_path)) {
    pages <- pdftools::pdf_text(pdf_path)
    return(lapply(pages, function(p) strsplit(p, '\n', fixed = TRUE)[[1]]))
  }
  txt_path <- sidecar_text_path(source_doc, dir_484f)
  if (!file.exists(txt_path)) {
    stop('extract_484f_pages: pdftools unavailable and no committed text ',
         'sidecar for ', source_doc, ' at ', txt_path,
         '. Regenerate the sidecar on a machine with pdftools/poppler.',
         call. = FALSE)
  }
  if (!is.na(expected_text_sha256) && nzchar(expected_text_sha256)) {
    actual <- digest::digest(file = txt_path, algo = 'sha256')
    if (!identical(actual, expected_text_sha256)) {
      stop(sprintf('484(f) text sidecar hash mismatch for %s:\n  manifest: %s\n  actual:   %s',
                   source_doc, expected_text_sha256, actual), call. = FALSE)
    }
  }
  raw <- paste(readLines(txt_path, warn = FALSE), collapse = '\n')
  split_text_to_pages(raw)
}

#' Flatten per-page lines into a (lines, page_of_line) pair for the parser.
flatten_pages <- function(pages) {
  lines <- unlist(pages, use.names = FALSE)
  page_of_line <- rep(seq_along(pages), lengths(pages))
  list(lines = lines, page_of_line = page_of_line)
}

# -----------------------------------------------------------------------------
# Source manifest + hash verification
# -----------------------------------------------------------------------------

#' Read data/484f/source_manifest.csv and verify hashes for present docs.
#'
#' Returns the manifest tibble augmented with `path` and `actual_sha256`.
#' Hard-fails if a `present` doc is missing or its hash differs. `pending_
#' acquisition` docs are reported but not required.
verify_484f_sources <- function(dir_484f = here('data', '484f')) {
  manifest <- readr::read_csv(file.path(dir_484f, 'source_manifest.csv'),
                              col_types = readr::cols(.default = readr::col_character()))
  manifest$path <- file.path(dir_484f, manifest$source_doc)
  manifest$actual_sha256 <- NA_character_

  present <- manifest$status == 'present'
  for (i in which(present)) {
    p <- manifest$path[i]
    if (!file.exists(p)) {
      stop('484(f) source declared present but missing: ', p, call. = FALSE)
    }
    manifest$actual_sha256[i] <- digest::digest(file = p, algo = 'sha256')
    if (!identical(manifest$actual_sha256[i], manifest$sha256[i])) {
      stop(sprintf('484(f) source hash mismatch for %s:\n  manifest: %s\n  actual:   %s',
                   manifest$source_doc[i], manifest$sha256[i],
                   manifest$actual_sha256[i]), call. = FALSE)
    }
  }
  pending <- manifest$source_doc[manifest$status == 'pending_acquisition']
  if (length(pending)) {
    message('NOTE: 484(f) sources pending acquisition (coverage gap): ',
            paste(pending, collapse = ', '))
  }
  manifest
}

# -----------------------------------------------------------------------------
# Coverage validation (Phase 2)
# -----------------------------------------------------------------------------
#
# Does every ordinary-merchandise 10-digit code that DISAPPEARS or is
# ESTABLISHED across the cached HTS archive universes have an explaining edge in
# the 484(f) crosswalk (both directions)? And does every pre-panel 2024-base
# code that is absent from the 2025 basic universe have an old-side edge?
#
# Scoping matches the weight base exactly: 10-digit codes (dotted
# dddd.dd.dd.dd), chapters 98-99 excluded (see build_import_weights.R:452-455).
# Archive ordering uses the RAW HTS-identity effective_date (never the policy
# retimed date) because a code's identity changes when USITC publishes the
# revision, not when a tariff policy takes legal effect.
#
# Genuinely non-484(f) churn (mid-cycle Census corrections that no committee
# document explains) is allowed ONLY through the committed exceptions resource
# `resources/hts10_484f_coverage_exceptions.csv`; an exception that matches no
# actual uncovered churn (stale) fails the build, mirroring the overrides
# contract.

COVERAGE_EXCEPTIONS_SCHEMA <- c('hts10', 'direction', 'transition_to',
                                'reason', 'evidence', 'approved_by')

# Dotted 10-digit leaf as it appears in an HTS archive: dddd.dd.dd.dd.
ARCHIVE_HTS10_RE <- '^[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}\\.[0-9]{2}$'

#' Discover HTS archive snapshots (both .json and .json.gz), deduped.
#'
#' @return tibble(revision, year, rev) — one row per revision, gz/raw collapsed.
discover_hts_archives <- function(archive_dir) {
  files <- list.files(archive_dir, pattern = '^hts_[0-9]{4}_.+\\.json(\\.gz)?$')
  if (length(files) == 0) {
    return(tibble(revision = character(), year = integer(), rev = character()))
  }
  m <- str_match(files, '^hts_([0-9]{4})_(.+)\\.json(?:\\.gz)?$')
  tibble(file = files, year = as.integer(m[, 2]), rev = m[, 3]) %>%
    mutate(revision = if_else(year == 2025L, rev, paste0(year, '_', rev))) %>%
    distinct(revision, year, rev) %>%
    arrange(year, rev)
}

#' Resolve an archive path, preferring the committed gzip.
resolve_archive_path <- function(archive_dir, year, rev) {
  base <- file.path(archive_dir, sprintf('hts_%d_%s', year, rev))
  gz <- paste0(base, '.json.gz'); raw <- paste0(base, '.json')
  if (file.exists(gz))  return(gz)
  if (file.exists(raw)) return(raw)
  stop('HTS archive not found: ', base, '.json[.gz]', call. = FALSE)
}

#' Ordinary-merchandise 10-digit code universe from one archive file.
archive_ordinary_hts10 <- function(path) {
  if (!requireNamespace('jsonlite', quietly = TRUE)) {
    stop('archive_ordinary_hts10 requires the jsonlite package.', call. = FALSE)
  }
  con <- if (grepl('\\.gz$', path)) gzfile(path) else path
  txt <- paste(readLines(con, warn = FALSE), collapse = '\n')
  recs <- jsonlite::fromJSON(txt, simplifyDataFrame = TRUE)
  h <- recs$htsno
  h <- h[!is.na(h) & grepl(ARCHIVE_HTS10_RE, h)]
  codes <- gsub('.', '', h, fixed = TRUE)
  unique(codes[!grepl('^(98|99)', codes)])
}

#' HS8 headings present in an archive: every 8-digit tariff line AND every HS8
#' prefix of a 10-digit code. Used to tell a dropped statistical suffix (HS8
#' persists -> prefix cascade recovers it) from a vanished heading (genuine gap).
archive_hs8_present <- function(path) {
  if (!requireNamespace('jsonlite', quietly = TRUE)) {
    stop('archive_hs8_present requires the jsonlite package.', call. = FALSE)
  }
  con <- if (grepl('\\.gz$', path)) gzfile(path) else path
  txt <- paste(readLines(con, warn = FALSE), collapse = '\n')
  recs <- jsonlite::fromJSON(txt, simplifyDataFrame = TRUE)
  h <- recs$htsno; h <- h[!is.na(h)]
  eight <- gsub('.', '', h[grepl('^[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}$', h)], fixed = TRUE)
  ten   <- gsub('.', '', h[grepl(ARCHIVE_HTS10_RE, h)], fixed = TRUE)
  unique(c(eight, substr(ten, 1, 8)))
}

#' Load HTS-identity dates (RAW effective_date, never policy) for archive order.
load_hts_identity_dates <- function(path) {
  d <- readr::read_csv(path, col_types = readr::cols(
    revision = readr::col_character(),
    effective_date = readr::col_date(),
    .default = readr::col_guess()))
  d %>% transmute(revision, effective_date) %>%
    filter(!is.na(effective_date)) %>% arrange(effective_date)
}

#' Load + validate the committed coverage-exceptions resource.
load_484f_coverage_exceptions <- function(path) {
  if (is.null(path) || !file.exists(path)) {
    return(tibble(!!!setNames(rep(list(character()), length(COVERAGE_EXCEPTIONS_SCHEMA)),
                              COVERAGE_EXCEPTIONS_SCHEMA)))
  }
  ex <- readr::read_csv(path, col_types = readr::cols(.default = readr::col_character()))
  missing <- setdiff(COVERAGE_EXCEPTIONS_SCHEMA, names(ex))
  if (length(missing)) {
    stop('hts10_484f_coverage_exceptions.csv missing columns: ',
         paste(missing, collapse = ', '), call. = FALSE)
  }
  bad_dir <- setdiff(unique(ex$direction), c('disappeared', 'established'))
  if (length(bad_dir)) {
    stop('hts10_484f_coverage_exceptions.csv bad direction(s): ',
         paste(bad_dir, collapse = ', '), call. = FALSE)
  }
  ex
}

#' Detect a directed cycle (length >= 2) among same-date edges via Kahn peeling.
#'
#' Self-edges (old == new, legitimate same-date reuse) are excluded upstream.
has_directed_cycle <- function(old_codes, new_codes) {
  nodes <- unique(c(old_codes, new_codes))
  edges <- tibble(from = old_codes, to = new_codes)
  repeat {
    outdeg <- setdiff(edges$from, edges$to)   # nodes with no incoming edge
    sinks  <- setdiff(edges$to, edges$from)   # nodes with no outgoing edge
    removable <- union(outdeg, sinks)
    keep <- !(edges$from %in% removable | edges$to %in% removable)
    if (all(keep) || sum(keep) == nrow(edges)) break
    edges <- edges[keep, , drop = FALSE]
    if (nrow(edges) == 0) break
  }
  nrow(edges) > 0
}

#' Scoped archive-coverage validation over cached HTS universes.
#'
#' @param transfers the reconciled HTS transfer edges (reconcile_484f_edges()$transfers).
#' @param archive_dir directory of hts_<year>_<rev>.json[.gz] archives.
#' @param revision_dates_path config/revision_dates.csv (HTS-identity dates).
#' @param weight_base_path optional 2024 import weight base .rds for the
#'   pre-panel completeness check; NULL skips it.
#' @param basic_revision the revision whose universe is the 2025 basic panel.
#' @param exceptions_path committed coverage-exceptions CSV (documented non-484f churn).
#' @param strict if TRUE, any uncovered churn / stale exception / same-date cycle fails.
#' @return list(inspected, transitions, uncovered_disappeared, uncovered_established,
#'   prepanel_missing, source_edges_unobserved, cycles, exceptions_used).
validate_484f_coverage <- function(transfers,
                                   archive_dir = here('data', 'hts_archives'),
                                   revision_dates_path = here('config', 'revision_dates.csv'),
                                   weight_base_path = NULL,
                                   basic_revision = 'basic',
                                   exceptions_path = here('resources', 'hts10_484f_coverage_exceptions.csv'),
                                   strict = TRUE) {
  stopifnot(all(c('old_hts10', 'new_hts10', 'effective_date') %in% names(transfers)))

  disc  <- discover_hts_archives(archive_dir)
  dates <- load_hts_identity_dates(revision_dates_path)
  snaps <- dates %>% inner_join(disc, by = 'revision') %>% arrange(effective_date)
  if (nrow(snaps) < 2) {
    stop('validate_484f_coverage: need >= 2 archive snapshots, found ',
         nrow(snaps), ' in ', archive_dir, call. = FALSE)
  }
  exceptions <- load_484f_coverage_exceptions(exceptions_path)

  message(sprintf('Coverage: inspecting %d ordered archive snapshots (%s .. %s)',
                  nrow(snaps), min(snaps$effective_date), max(snaps$effective_date)))

  universes <- setNames(
    lapply(seq_len(nrow(snaps)),
           function(i) archive_ordinary_hts10(
             resolve_archive_path(archive_dir, snaps$year[i], snaps$rev[i]))),
    snaps$revision)

  # --- Per-transition disappeared / established ------------------------------
  transitions <- map_dfr(2:nrow(snaps), function(i) {
    u0 <- universes[[i - 1]]; u1 <- universes[[i]]
    tibble(
      transition_from = snaps$revision[i - 1],
      transition_to   = snaps$revision[i],
      date_from = snaps$effective_date[i - 1],
      date_to   = snaps$effective_date[i],
      n_disappeared = length(setdiff(u0, u1)),
      n_established = length(setdiff(u1, u0)),
      disappeared = list(setdiff(u0, u1)),
      established = list(setdiff(u1, u0)))
  })

  old_set <- unique(transfers$old_hts10[!is.na(transfers$old_hts10)])
  new_set <- unique(transfers$new_hts10[!is.na(transfers$new_hts10)])

  ex_dis <- exceptions %>% filter(direction == 'disappeared')
  ex_est <- exceptions %>% filter(direction == 'established')
  ex_used <- rep(FALSE, nrow(exceptions))

  # Uncovered = churn code not explained by any edge AND not excepted.
  churn_long <- transitions %>%
    transmute(transition_to,
              disappeared = disappeared, established = established) %>%
    { bind_rows(
        tibble(direction = 'disappeared',
               transition_to = rep(.$transition_to, lengths(.$disappeared)),
               hts10 = unlist(.$disappeared)),
        tibble(direction = 'established',
               transition_to = rep(.$transition_to, lengths(.$established)),
               hts10 = unlist(.$established))) }

  mark_ex_used <- function(direction, hts10, transition_to) {
    hit <- exceptions$direction == direction & exceptions$hts10 == hts10 &
      (is.na(exceptions$transition_to) | exceptions$transition_to == transition_to |
         exceptions$transition_to == '')
    ex_used[hit] <<- TRUE
    any(hit)
  }

  # An exception is only "used" if it absorbs an ACTUALLY-uncovered code — a
  # documented exception for a code that a 484(f) edge already covers is stale.
  churn_long <- churn_long %>%
    mutate(covered = if_else(direction == 'disappeared',
                             hts10 %in% old_set, hts10 %in% new_set),
           excepted = pmap_lgl(list(direction, hts10, transition_to, covered),
             function(dir, h, tr, cov) if (isTRUE(cov)) FALSE else mark_ex_used(dir, h, tr)))

  uncovered <- churn_long %>% filter(!covered, !excepted)
  uncovered_dis <- uncovered %>% filter(direction == 'disappeared')
  uncovered_est <- uncovered %>% filter(direction == 'established')

  # --- Pre-panel completeness (2024 base absent from 2025 basic) -------------
  #
  # A 2024-base code missing from the 2025 basic universe is classified:
  #   covered   - explained by a 484(f) old-side edge (a real committee change);
  #   cascade   - its HS8 heading still exists, so it is a retired statistical
  #               suffix the weight mapper's prefix cascade recovers exactly at
  #               HS8 (Census suffix churn, much of it predating the Jul-2024
  #               doc; NOT a missing committee edge) — reported, not fatal;
  #   vanished  - even the HS8 heading is gone, so the value cannot be recovered
  #               by prefix and needs a real remap; fatal unless documented.
  prepanel_missing <- tibble(hts10 = character())
  prepanel_summary <- tibble()
  if (!is.null(weight_base_path) && file.exists(weight_base_path)) {
    if (!basic_revision %in% names(universes)) {
      stop('validate_484f_coverage: basic_revision "', basic_revision,
           '" has no archive universe.', call. = FALSE)
    }
    base <- readRDS(weight_base_path)
    base_col <- intersect(c('hs10', 'hts10'), names(base))[1]
    imp_col  <- intersect(c('imports', 'value', 'customs_value'), names(base))[1]
    base_tot <- base %>%
      transmute(hts10 = as.character(.data[[base_col]]),
                imports = if (!is.na(imp_col)) .data[[imp_col]] else NA_real_) %>%
      filter(grepl('^[0-9]{10}$', hts10), !grepl('^(98|99)', hts10)) %>%
      group_by(hts10) %>% summarise(imports = sum(imports, na.rm = TRUE), .groups = 'drop')

    hs8_present <- archive_hs8_present(
      resolve_archive_path(archive_dir, snaps$year[match(basic_revision, snaps$revision)],
                           snaps$rev[match(basic_revision, snaps$revision)]))

    pre <- base_tot %>%
      filter(!hts10 %in% universes[[basic_revision]]) %>%
      mutate(klass = case_when(
        hts10 %in% old_set              ~ 'covered',
        substr(hts10, 1, 8) %in% hs8_present ~ 'cascade',
        TRUE                            ~ 'vanished'))
    prepanel_summary <- pre %>% group_by(klass) %>%
      summarise(n = n(), usd_bn = sum(imports) / 1e9, .groups = 'drop')

    vanished <- pre %>% filter(klass == 'vanished')
    van_excepted <- vapply(vanished$hts10,
      function(c) mark_ex_used('disappeared', c, basic_revision), logical(1))
    prepanel_missing <- vanished[!van_excepted, c('hts10', 'imports')]
    message(sprintf('Pre-panel: %d 2024-base codes absent from %s ($%.1fB); classes:',
                    nrow(pre), basic_revision, sum(pre$imports) / 1e9))
    for (i in seq_len(nrow(prepanel_summary))) {
      message(sprintf('  %-8s n=%-4d $%.2fB', prepanel_summary$klass[i],
                      prepanel_summary$n[i], prepanel_summary$usd_bn[i]))
    }
    message(sprintf('  vanished-HS8 uncovered+undocumented (fatal): %d',
                    nrow(prepanel_missing)))
  }

  # --- Source edges never observed in an archive transition ------------------
  observed_dis <- churn_long %>% filter(direction == 'disappeared') %>% pull(hts10)
  observed_est <- churn_long %>% filter(direction == 'established') %>% pull(hts10)
  source_edges_unobserved <- transfers %>%
    filter(!is.na(new_hts10)) %>%
    mutate(old_seen = old_hts10 %in% observed_dis,
           new_seen = new_hts10 %in% observed_est) %>%
    filter(!old_seen & !new_seen) %>%
    select(any_of(c('old_hts10', 'new_hts10', 'effective_date',
                    'change_type', 'source_doc')))

  # --- Same-date cycle validation --------------------------------------------
  cycles <- transfers %>%
    filter(!is.na(new_hts10), old_hts10 != new_hts10) %>%
    group_by(effective_date) %>%
    summarise(cycle = has_directed_cycle(old_hts10, new_hts10), .groups = 'drop') %>%
    filter(cycle)

  # --- Report ----------------------------------------------------------------
  message(sprintf('Coverage: %d transitions; %d/%d disappeared covered, %d/%d established covered',
                  nrow(transitions),
                  sum(churn_long$direction == 'disappeared' & (churn_long$covered | churn_long$excepted)),
                  sum(churn_long$direction == 'disappeared'),
                  sum(churn_long$direction == 'established' & (churn_long$covered | churn_long$excepted)),
                  sum(churn_long$direction == 'established')))
  message(sprintf('  documented exceptions used: %d/%d; source edges unobserved: %d; same-date cycles: %d',
                  sum(ex_used), nrow(exceptions), nrow(source_edges_unobserved), nrow(cycles)))

  problems <- character()
  if (nrow(uncovered_dis))
    problems <- c(problems, sprintf('%d uncovered disappearances (e.g. %s)',
      nrow(uncovered_dis), paste(head(uncovered_dis$hts10, 8), collapse = ', ')))
  if (nrow(uncovered_est))
    problems <- c(problems, sprintf('%d uncovered establishments (e.g. %s)',
      nrow(uncovered_est), paste(head(uncovered_est$hts10, 8), collapse = ', ')))
  if (nrow(prepanel_missing))
    problems <- c(problems, sprintf('%d pre-panel 2024-base codes with vanished HS8 heading uncovered (e.g. %s)',
      nrow(prepanel_missing), paste(head(prepanel_missing$hts10, 8), collapse = ', ')))
  if (nrow(cycles))
    problems <- c(problems, sprintf('same-date directed cycle(s) at: %s',
      paste(cycles$effective_date, collapse = ', ')))
  if (any(!ex_used))
    problems <- c(problems, sprintf('stale coverage exception(s): %s',
      paste(exceptions$hts10[!ex_used], collapse = ', ')))

  if (length(problems) && strict) {
    stop('484(f) coverage validation failed:\n  - ',
         paste(problems, collapse = '\n  - '),
         '\nAdd a committed edge (source doc) or a documented coverage exception.',
         call. = FALSE)
  }

  list(inspected = snaps %>% select(revision, effective_date, year, rev),
       transitions = transitions %>% select(-disappeared, -established),
       uncovered_disappeared = uncovered_dis,
       uncovered_established = uncovered_est,
       prepanel_missing = prepanel_missing,
       prepanel_summary = prepanel_summary,
       source_edges_unobserved = source_edges_unobserved,
       cycles = cycles,
       exceptions_used = tibble(exceptions, used = ex_used))
}

# -----------------------------------------------------------------------------
# Orchestrator (one-shot)
# -----------------------------------------------------------------------------

build_484f_crosswalk <- function(dir_484f = here('data', '484f'),
                                 overrides_path = here('resources', 'hts10_484f_overrides.csv'),
                                 out_path = here('resources', 'hts10_484f_transfers.csv'),
                                 run_coverage = TRUE,
                                 archive_dir = here('data', 'hts_archives'),
                                 weight_base_path = here('data', 'weights', 'hs10_by_country_gtap_2024_con.rds'),
                                 coverage_report_path = here('resources', 'hts10_484f_coverage_report.csv'),
                                 dry_run = FALSE) {
  manifest <- verify_484f_sources(dir_484f)
  overrides <- load_484f_overrides(overrides_path)

  present <- manifest %>% filter(status == 'present')
  text_sha <- if ('text_sha256' %in% names(present)) present$text_sha256
              else rep(NA_character_, nrow(present))
  all_assertions <- map_dfr(seq_len(nrow(present)), function(i) {
    doc <- present$source_doc[i]
    message('Parsing ', doc, ' ...')
    pages <- extract_484f_pages(present$path[i], source_doc = doc,
                                dir_484f = dir_484f,
                                expected_text_sha256 = text_sha[i])
    fl <- flatten_pages(pages)
    parse_484f_lines(fl$lines, source_doc = doc, page_of_line = fl$page_of_line)
  })

  all_assertions <- apply_484f_overrides(all_assertions, overrides)

  source_hashes <- present %>% transmute(source_doc, source_doc_sha256 = sha256)
  rec <- reconcile_484f_edges(all_assertions, source_hashes = source_hashes)

  message('\nEdge status summary:')
  print(rec$status_summary)
  message(sprintf('Schedule B assertions excluded from HTS resource: %d',
                  nrow(rec$schedule_b)))
  message(sprintf('HTS transfer edges: %d', nrow(rec$transfers)))

  cov <- NULL
  if (run_coverage) {
    message('\nRunning archive-coverage validation ...')
    cov <- validate_484f_coverage(
      rec$transfers, archive_dir = archive_dir,
      weight_base_path = if (!is.null(weight_base_path) &&
                             file.exists(weight_base_path)) weight_base_path else NULL)
    if (!dry_run && !is.null(coverage_report_path)) {
      readr::write_csv(cov$transitions, coverage_report_path)
      message('Wrote coverage report ', coverage_report_path)
    }
  }

  if (!dry_run) {
    readr::write_csv(rec$transfers, out_path)
    message('Wrote ', out_path)
  }
  invisible(c(rec, list(coverage = cov)))
}

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

if (sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) && any(args %in% c('-h', '--help'))) {
    cat('Usage: Rscript tools/build_484f_crosswalk.R [--dry-run] [--no-coverage]\n',
        '  --dry-run      parse + reconcile + validate, do not write CSVs\n',
        '  --no-coverage  skip archive-coverage validation (parser only)\n', sep = '')
    quit(status = 0)
  }
  build_484f_crosswalk(dry_run = any(args == '--dry-run'),
                       run_coverage = !any(args == '--no-coverage'))
}
