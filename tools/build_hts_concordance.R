#!/usr/bin/env Rscript
# =============================================================================
# build_hts_concordance.R
#
# DEPRECATED (2026-07-14): superseded by the authoritative 484(f) transfer
# crosswalk in tools/build_484f_crosswalk.R -> resources/hts10_484f_transfers.csv.
# The Jaccard word-overlap heuristic below is retained only for archived
# import-remapping scripts that still reference resources/hts_concordance.csv;
# it must not be used for import-weight revision mapping. New code should
# consume the dated, explicit 484(f) transfers instead. No behavior change.
#
# Builds an HTS10 product concordance mapping that tracks how product codes
# change across HTS revisions. Inspired by Pierce & Schott (2012) algorithm.
#
# For each consecutive revision pair, identifies changes only:
#   - Added: codes only in new revision
#   - Dropped: codes only in old revision
#   - Splits (1 old -> N new), Merges (N old -> 1 new), Renames
#   - Many-to-many: multiple old <-> multiple new within same heading
#
# NOTE: This is a heuristic concordance. Matching uses Jaccard word-overlap
# similarity within same 4-digit heading. Because every above-threshold pair
# within a heading is recorded (greedy matching without row/column exclusion),
# splits and many-to-many counts may be overstated. The output is suitable
# for import-code remapping in compare_etrs.R but should not be treated as
# an authoritative concordance without manual review.
#
# Usage:
#   Rscript tools/build_hts_concordance.R            # full build
#   Rscript tools/build_hts_concordance.R --dry-run   # stats only, no CSV
#
# Output: resources/hts_concordance.csv (changes only)
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(jsonlite)
  library(dplyr)
  library(readr)
  library(stringr)
  library(purrr)
})

source(here('src', 'core', 'helpers.R'))

# =============================================================================
# Core functions
# =============================================================================

#' Extract HTS10 products from a JSON file
#'
#' @param json_path Path to HTS JSON file
#' @return Tibble with htsno (cleaned), description, heading4, heading6
extract_hts10 <- function(json_path) {
  j <- fromJSON(json_path, simplifyDataFrame = TRUE)

  # Filter to 10-digit codes only
  digits_only <- gsub('[^0-9]', '', j$htsno)
  is_hts10 <- nchar(digits_only) == 10

  out <- tibble(
    htsno       = digits_only[is_hts10],
    description = tolower(trimws(j$description[is_hts10]))
  ) %>%
    mutate(
      heading4 = substr(htsno, 1, 4),
      heading6 = substr(htsno, 1, 6)
    )

  # Remove duplicates (some revisions have dupes)
  out <- out %>% distinct(htsno, .keep_all = TRUE)

  return(out)
}


#' Compute Jaccard word-overlap similarity between two descriptions
#'
#' @param a Character string
#' @param b Character string
#' @return Numeric similarity score [0, 1]
jaccard_similarity <- function(a, b) {
  words_a <- unique(str_split(a, '\\W+')[[1]])
  words_b <- unique(str_split(b, '\\W+')[[1]])
  words_a <- words_a[words_a != '']
  words_b <- words_b[words_b != '']

  if (length(words_a) == 0 && length(words_b) == 0) return(1.0)
  if (length(words_a) == 0 || length(words_b) == 0) return(0.0)

  intersection <- length(intersect(words_a, words_b))
  union_size   <- length(union(words_a, words_b))

  return(intersection / union_size)
}


#' Match dropped codes to added codes within same heading
#'
#' For each heading with both dropped and added codes, compute pairwise
#' description similarity and match above threshold.
#'
#' @param dropped Tibble of dropped codes (htsno, description, heading4)
#' @param added Tibble of added codes (htsno, description, heading4)
#' @param sim_threshold Minimum Jaccard similarity for a match
#' @return Tibble of matched pairs with similarity scores
match_codes <- function(dropped, added, sim_threshold = 0.7) {
  # Find headings with both dropped and added codes
  headings_dropped <- unique(dropped$heading4)
  headings_added   <- unique(added$heading4)
  shared_headings  <- intersect(headings_dropped, headings_added)

  if (length(shared_headings) == 0) return(tibble())

  matches <- list()

  for (h in shared_headings) {
    d <- dropped %>% filter(heading4 == h)
    a <- added   %>% filter(heading4 == h)

    # Compute pairwise similarity matrix
    sim_matrix <- matrix(0, nrow = nrow(d), ncol = nrow(a))
    for (i in seq_len(nrow(d))) {
      for (j in seq_len(nrow(a))) {
        sim_matrix[i, j] <- jaccard_similarity(d$description[i], a$description[j])
      }
    }

    # Greedy matching: for each cell above threshold, match best first
    # This handles splits (1 dropped -> N added) and merges (N dropped -> 1 added)
    while (any(sim_matrix >= sim_threshold)) {
      best <- which(sim_matrix == max(sim_matrix), arr.ind = TRUE)[1, , drop = FALSE]
      bi <- best[1, 1]
      bj <- best[1, 2]

      matches[[length(matches) + 1]] <- tibble(
        old_hts10       = d$htsno[bi],
        new_hts10       = a$htsno[bj],
        description_old = d$description[bi],
        description_new = a$description[bj],
        similarity      = sim_matrix[bi, bj]
      )

      # Zero out this cell so we can find additional matches
      # (Don't zero out entire row/column — allow splits and merges)
      sim_matrix[bi, bj] <- 0
    }
  }

  if (length(matches) == 0) return(tibble())
  bind_rows(matches)
}


#' Classify change type based on match cardinality
#'
#' @param matches Tibble with old_hts10, new_hts10 columns
#' @return Character vector of change types
classify_changes <- function(matches) {
  if (nrow(matches) == 0) return(character())

  old_counts <- matches %>% count(old_hts10, name = 'n_new')
  new_counts <- matches %>% count(new_hts10, name = 'n_old')

  matches %>%
    left_join(old_counts, by = 'old_hts10') %>%
    left_join(new_counts, by = 'new_hts10') %>%
    mutate(
      change_type = case_when(
        n_new == 1 & n_old == 1 ~ 'rename',
        n_new > 1  & n_old == 1 ~ 'split',
        n_new == 1 & n_old > 1  ~ 'merge',
        TRUE                    ~ 'many_to_many'
      )
    ) %>%
    pull(change_type)
}


#' Compare two consecutive revisions and build concordance entries
#'
#' @param rev_from Revision identifier (old)
#' @param rev_to Revision identifier (new)
#' @param archive_dir Path to HTS archive directory
#' @param sim_threshold Jaccard similarity threshold
#' @return Tibble of concordance entries
compare_revisions <- function(rev_from, rev_to, archive_dir, sim_threshold = 0.7) {
  path_from <- resolve_json_path(rev_from, archive_dir)
  path_to   <- resolve_json_path(rev_to, archive_dir)

  message('  Loading ', rev_from, '...')
  hts_from <- extract_hts10(path_from)

  message('  Loading ', rev_to, '...')
  hts_to <- extract_hts10(path_to)

  # Identify code status
  codes_from <- hts_from$htsno
  codes_to   <- hts_to$htsno

  unchanged_codes <- intersect(codes_from, codes_to)
  dropped_codes   <- setdiff(codes_from, codes_to)
  added_codes     <- setdiff(codes_to, codes_from)

  message('    Unchanged: ', length(unchanged_codes),
          '  Dropped: ', length(dropped_codes),
          '  Added: ', length(added_codes))

  # If no changes, return empty

  if (length(dropped_codes) == 0 && length(added_codes) == 0) {
    return(tibble())
  }

  # Match dropped to added codes
  dropped <- hts_from %>% filter(htsno %in% dropped_codes)
  added   <- hts_to   %>% filter(htsno %in% added_codes)

  matched <- match_codes(dropped, added, sim_threshold)

  if (nrow(matched) > 0) {
    matched$change_type <- classify_changes(matched)

    # Codes that were dropped/added but NOT matched
    unmatched_dropped <- setdiff(dropped_codes, matched$old_hts10)
    unmatched_added   <- setdiff(added_codes, matched$new_hts10)
  } else {
    unmatched_dropped <- dropped_codes
    unmatched_added   <- added_codes
  }

  # Unmatched drops = discontinued
  discontinued <- tibble()
  if (length(unmatched_dropped) > 0) {
    disc_data <- hts_from %>% filter(htsno %in% unmatched_dropped)
    discontinued <- tibble(
      old_hts10       = disc_data$htsno,
      new_hts10       = NA_character_,
      description_old = disc_data$description,
      description_new = NA_character_,
      similarity      = NA_real_,
      change_type     = 'dropped'
    )
  }

  # Unmatched adds = new products
  new_products <- tibble()
  if (length(unmatched_added) > 0) {
    new_data <- hts_to %>% filter(htsno %in% unmatched_added)
    new_products <- tibble(
      old_hts10       = NA_character_,
      new_hts10       = new_data$htsno,
      description_old = NA_character_,
      description_new = new_data$description,
      similarity      = NA_real_,
      change_type     = 'added'
    )
  }

  # Combine all
  result <- bind_rows(matched, discontinued, new_products) %>%
    mutate(
      revision_from = rev_from,
      revision_to   = rev_to
    ) %>%
    select(old_hts10, new_hts10, revision_from, revision_to, change_type,
           description_old, description_new, similarity)

  # Free memory
  rm(hts_from, hts_to)
  gc(verbose = FALSE)

  return(result)
}


# =============================================================================
# Main concordance builder
# =============================================================================

#' Build full HTS10 concordance across all revisions
#'
#' @param archive_dir Path to HTS archive directory
#' @param output_path Path for output CSV
#' @param sim_threshold Jaccard similarity threshold (default 0.7)
#' @param dry_run If TRUE, print stats but don't write CSV
#' @return Tibble of concordance entries (changes only, invisibly)
build_concordance <- function(archive_dir = here('data', 'hts_archives'),
                              output_path = here('resources', 'hts_concordance.csv'),
                              sim_threshold = 0.7,
                              dry_run = FALSE) {
  # Load revision order — use HTS release order, not policy dates. The
  # code-identity concordance must span every archive on disk (window-blind):
  # era backfills need edges ACROSS the window boundary.
  rev_dates <- load_revision_dates(use_policy_dates = FALSE, apply_window = FALSE)
  all_revisions <- rev_dates$revision

  # Filter to revisions we actually have JSON for
  available <- get_available_revisions_all_years(all_revisions, archive_dir)
  revisions <- all_revisions[all_revisions %in% available]

  if (length(revisions) < 2) {
    message('Need at least 2 revisions with JSON files to build concordance (found ',
            length(revisions), ')')
    return(invisible(tibble()))
  }

  message('\nFound ', length(revisions), ' revisions with JSON files')
  message('Processing ', length(revisions) - 1, ' consecutive pairs\n')

  # Process consecutive pairs
  all_results <- list()

  for (i in seq_len(length(revisions) - 1)) {
    rev_from <- revisions[i]
    rev_to   <- revisions[i + 1]

    message('Pair ', i, '/', length(revisions) - 1, ': ', rev_from, ' -> ', rev_to)

    result <- tryCatch(
      compare_revisions(rev_from, rev_to, archive_dir, sim_threshold),
      error = function(e) {
        warning('Failed to compare ', rev_from, ' -> ', rev_to, ': ', e$message)
        tibble()
      }
    )

    if (nrow(result) > 0) {
      all_results[[length(all_results) + 1]] <- result
    }

    gc(verbose = FALSE)
  }

  concordance <- bind_rows(all_results)

  # Summary stats
  message('\n', strrep('=', 60))
  message('CONCORDANCE SUMMARY')
  message(strrep('=', 60))
  message('Total entries: ', format(nrow(concordance), big.mark = ','))

  if (nrow(concordance) > 0) {
    type_counts <- concordance %>% count(change_type) %>% arrange(desc(n))
    for (i in seq_len(nrow(type_counts))) {
      message('  ', type_counts$change_type[i], ': ',
              format(type_counts$n[i], big.mark = ','))
    }

    pairs_with_changes <- concordance %>%
      distinct(revision_from, revision_to) %>% nrow()
    message('Revision pairs with changes: ', pairs_with_changes)
  }

  # Write output

  if (!dry_run && nrow(concordance) > 0) {
    write_csv(concordance, output_path)
    message('Wrote concordance to: ', output_path)
  } else if (dry_run) {
    message('\n[DRY RUN] Would write ', format(nrow(concordance), big.mark = ','),
            ' rows to ', output_path)
  }

  invisible(concordance)
}


# =============================================================================
# CLI entry point
# =============================================================================

if (sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  dry_run <- '--dry-run' %in% args

  if (dry_run) message('=== DRY RUN MODE ===\n')

  build_concordance(dry_run = dry_run)
}
