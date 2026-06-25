# =============================================================================
# Build resources/s301_exclusion_headings.csv — §301 exclusion-heading registry
# =============================================================================
#
# Identifies Chapter 99 headings that EXCLUDE products from §301 duties
# ("The duty provided in the applicable subheading" — rate parses to NA) and
# registers them for the 6a-excl hook in src/pipeline/06_calculate_rates.R, which
# scales rate_301 by (1 - coverage_share) for products referencing an
# in-window exclusion heading.
#
# Validity windows are NOT stored here for auto rows: each revision's own
# heading text carries its then-current window ("on or after June 15, 2024
# and through November 9, 2026"), parsed into effective_date_offset /
# expiry_date_offset by parse_chapter99(). USTR extends these windows over
# time (9903.88.69's stated expiry moved 2025-05-31 -> 2025-08-31 ->
# 2025-11-29 -> 2026-11-09 across 2025 revisions), so per-revision text is
# the only window that is correct for every snapshot. The validity_start /
# validity_end columns are CURATOR OVERRIDES (normally NA).
#
# Inclusion rules:
#   * AUTO (source = 'heading_text'): NA-rate, authority section_301,
#     description contains "covered by an exclusion granted by the
#     U.S. Trade Representative", AND at least one revision's text carries a
#     date window -> coverage_share = 1.0 (Phase-1 full-line upper bound).
#   * AUTO needs_review: same but NO date window in any revision's text ->
#     coverage_share = 0.0 (presence-gating a windowless heading would zero
#     §301 permanently; a curator must supply the window first).
#   * CURATOR (source = 'curator'): preserved verbatim across re-runs (wins
#     on ch99_code conflict). Seeded with 9903.88.21-.28, which are NOT USTR
#     product exclusions — U.S. note 20(z)-(gg) makes them PERMANENT
#     CONDITIONAL carve-outs (apply only when the entry's duty rate derives
#     from another subheading already covered by a §301 list) -> coverage 0.0
#     pending Phase-2 calibration.
#
# Usage: Rscript scripts/build_s301_exclusion_headings.R [--ts-dir <dir>]
# Idempotent. Re-run after onboarding revisions to pick up new headings.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})
source(here('src', 'model', 'rate_schema.R'))

args <- commandArgs(trailingOnly = TRUE)
ts_dir <- here('data', 'timeseries')
if (length(args) >= 2 && args[1] == '--ts-dir') ts_dir <- args[2]

out_path <- here('resources', 's301_exclusion_headings.csv')

EXCLUSION_PHRASE <- 'covered by an exclusion granted by the U\\.?S\\.? Trade Representative'

# Curator seed: only used when the heading is not already in the CSV.
CURATOR_SEED <- tibble(
  ch99_code = sprintf('9903.88.%02d', 21:28),
  validity_start = as.Date(NA),
  validity_end = as.Date(NA),
  coverage_share = 0.0,
  source = 'curator',
  source_note = paste(
    'US note 20(z)-(gg): PERMANENT CONDITIONAL derived-rate carve-out, not a',
    'USTR product exclusion. Applies only when the entry duty rate derives',
    'from another subheading on a 301 list. coverage_share 0 pending Phase-2',
    'calibration (do not full-line zero).')
)

# ---- Scan every cached ch99 revision --------------------------------------
caches <- list.files(ts_dir, pattern = '^ch99_.*\\.rds$', full.names = TRUE)
if (length(caches) == 0) {
  stop('No ch99_*.rds caches found in ', ts_dir,
       ' — run the parse step (or pass --ts-dir).')
}
message('Scanning ', length(caches), ' ch99 caches in ', ts_dir)

scan <- map_dfr(caches, function(p) {
  ch99 <- readRDS(p)
  ch99 %>%
    filter(is.na(rate),
           map_chr(ch99_code, classify_authority) == 'section_301',
           grepl(EXCLUSION_PHRASE, description, ignore.case = TRUE)) %>%
    mutate(
      rev = sub('^ch99_(.*)\\.rds$', '\\1', basename(p)),
      win_start = as.Date(vapply(description, function(d)
        as.character(extract_effective_date_offset(d)), character(1),
        USE.NAMES = FALSE)),
      win_end = as.Date(vapply(description, function(d)
        as.character(extract_expiry_date_offset(d)), character(1),
        USE.NAMES = FALSE))
    ) %>%
    select(rev, ch99_code, win_start, win_end)
})

auto <- scan %>%
  group_by(ch99_code) %>%
  summarise(
    n_revisions = n_distinct(rev),
    any_window = any(!is.na(win_start) | !is.na(win_end)),
    latest_start = if (all(is.na(win_start))) as.Date(NA) else max(win_start, na.rm = TRUE),
    latest_end = if (all(is.na(win_end))) as.Date(NA) else max(win_end, na.rm = TRUE),
    .groups = 'drop'
  ) %>%
  mutate(
    validity_start = as.Date(NA),   # windows read per-revision from heading text
    validity_end = as.Date(NA),
    coverage_share = if_else(any_window, 1.0, 0.0),
    source = 'heading_text',
    source_note = if_else(
      any_window,
      paste0('USTR exclusion; window read per-revision from heading text ',
             '(latest seen: ', coalesce(as.character(latest_start), '?'), ' to ',
             coalesce(as.character(latest_end), 'open'), '; in ',
             n_revisions, ' revisions). Phase-1 full-line upper bound.'),
      paste0('NEEDS_REVIEW: exclusion phrasing but NO window in any ',
             'revision text (', n_revisions, ' revisions); coverage 0 until ',
             'a curator supplies the window.')
    )
  ) %>%
  select(ch99_code, validity_start, validity_end, coverage_share, source, source_note)

# ---- Merge: existing curator rows win, then seed, then auto -----------------
existing_curator <- if (file.exists(out_path)) {
  suppressMessages(read_csv(out_path, col_types = cols(
    ch99_code = col_character(), validity_start = col_date(),
    validity_end = col_date(), coverage_share = col_double(),
    source = col_character(), source_note = col_character()
  ))) %>% filter(source == 'curator')
} else {
  CURATOR_SEED[0, ]
}

curator <- bind_rows(existing_curator,
                     CURATOR_SEED %>% filter(!ch99_code %in% existing_curator$ch99_code))

final <- bind_rows(curator,
                   auto %>% filter(!ch99_code %in% curator$ch99_code)) %>%
  arrange(ch99_code)

write_csv(final, out_path)

message('Wrote ', nrow(final), ' headings to ', out_path)
message('  curator: ', sum(final$source == 'curator'),
        ' | auto windowed (coverage 1.0): ',
        sum(final$source == 'heading_text' & final$coverage_share == 1),
        ' | auto needs_review (coverage 0): ',
        sum(final$source == 'heading_text' & final$coverage_share == 0))

# Surface NA-rate §301 headings that matched NOTHING (triage list)
all_na_301 <- map_dfr(caches, function(p) {
  readRDS(p) %>%
    filter(is.na(rate),
           map_chr(ch99_code, classify_authority) == 'section_301') %>%
    distinct(ch99_code)
}) %>% distinct(ch99_code)
unmatched <- setdiff(all_na_301$ch99_code, final$ch99_code)
if (length(unmatched) > 0) {
  message('  UNREGISTERED NA-rate section_301 headings (refs to these are ',
          'logged by the dropped-pairs instrumentation, never scaled): ',
          paste(sort(unmatched), collapse = ', '))
}
