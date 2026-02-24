# =============================================================================
# Compare HTS Revisions
# =============================================================================
#
# Compares HTS revisions to baseline to identify changes in:
#   - Chapter 99 references (new tariff authorities)
#   - Rate changes
#   - Product additions/removals
#
# =============================================================================

library(here)
source(here('src', 'helpers.R'))
source(here('src', 'v1_ingest_hts.R'))

# =============================================================================
# Comparison Functions
# =============================================================================

#' Compare two HTS datasets
#'
#' @param baseline Baseline HTS data (tibble from ingest_hts_json)
#' @param revision Revision HTS data (tibble from ingest_hts_json)
#' @param revision_name Name for logging
#' @return List with changes
compare_hts <- function(baseline, revision, revision_name = 'revision') {

  # Compare Chapter 99 references
  baseline_ch99 <- baseline %>%
    select(htsno, chapter99_refs) %>%
    unnest(chapter99_refs, keep_empty = TRUE) %>%
    rename(baseline_ch99 = chapter99_refs)

  revision_ch99 <- revision %>%
    select(htsno, chapter99_refs) %>%
    unnest(chapter99_refs, keep_empty = TRUE) %>%
    rename(revision_ch99 = chapter99_refs)

  # Find new Chapter 99 references
  new_ch99 <- revision_ch99 %>%
    anti_join(baseline_ch99, by = c('htsno', 'revision_ch99' = 'baseline_ch99')) %>%
    filter(!is.na(revision_ch99))

  # Find removed Chapter 99 references
  removed_ch99 <- baseline_ch99 %>%
    anti_join(revision_ch99, by = c('htsno', 'baseline_ch99' = 'revision_ch99')) %>%
    filter(!is.na(baseline_ch99))

  # Compare rates
  baseline_rates <- baseline %>%
    select(htsno, general_rate) %>%
    rename(baseline_rate = general_rate)

  revision_rates <- revision %>%
    select(htsno, general_rate) %>%
    rename(revision_rate = general_rate)

  rate_changes <- baseline_rates %>%
    full_join(revision_rates, by = 'htsno') %>%
    filter(
      !is.na(baseline_rate) | !is.na(revision_rate),
      abs(coalesce(baseline_rate, -999) - coalesce(revision_rate, -999)) > 0.0001
    ) %>%
    mutate(
      change_type = case_when(
        is.na(baseline_rate) ~ 'new_product',
        is.na(revision_rate) ~ 'removed_product',
        TRUE ~ 'rate_change'
      )
    )

  # Summary of new Chapter 99 refs
  new_ch99_summary <- new_ch99 %>%
    count(revision_ch99, sort = TRUE) %>%
    rename(ch99_ref = revision_ch99, n_products = n)

  return(list(
    revision_name = revision_name,
    new_ch99 = new_ch99,
    removed_ch99 = removed_ch99,
    rate_changes = rate_changes,
    new_ch99_summary = new_ch99_summary,
    n_new_ch99 = nrow(new_ch99),
    n_removed_ch99 = nrow(removed_ch99),
    n_rate_changes = nrow(rate_changes)
  ))
}


#' Run comparison across all revisions
#'
#' @param baseline_path Path to baseline HTS JSON
#' @param revision_pattern Glob pattern for revision files
#' @return Tibble with all comparisons
compare_all_revisions <- function(baseline_path, revision_pattern) {
  message('Loading baseline: ', baseline_path)
  baseline <- ingest_hts_json(baseline_path)

  # Find all revision files
  revision_files <- sort(Sys.glob(revision_pattern))
  message('Found ', length(revision_files), ' revision files')

  results <- list()

  for (rev_file in revision_files) {
    # Extract revision number from filename
    rev_num <- str_extract(basename(rev_file), 'rev_([0-9]+)', group = 1)
    rev_name <- paste0('Revision ', rev_num)

    message('\nProcessing ', rev_name, '...')

    revision <- ingest_hts_json(rev_file)
    comparison <- compare_hts(baseline, revision, rev_name)

    results[[rev_name]] <- comparison

    # Print summary
    message('  New Ch99 refs: ', comparison$n_new_ch99)
    message('  Removed Ch99 refs: ', comparison$n_removed_ch99)
    message('  Rate changes: ', comparison$n_rate_changes)
  }

  return(results)
}


#' Create summary table of all revisions
#'
#' @param results List from compare_all_revisions
#' @return Tibble summarizing changes by revision
summarize_revisions <- function(results) {
  summary_rows <- map_dfr(names(results), function(rev_name) {
    r <- results[[rev_name]]
    tibble(
      revision = rev_name,
      n_new_ch99 = r$n_new_ch99,
      n_removed_ch99 = r$n_removed_ch99,
      n_rate_changes = r$n_rate_changes,
      top_new_ch99 = if (nrow(r$new_ch99_summary) > 0) {
        paste(head(r$new_ch99_summary$ch99_ref, 3), collapse = ', ')
      } else {
        ''
      }
    )
  })

  return(summary_rows)
}


#' Get all new Chapter 99 references across revisions
#'
#' @param results List from compare_all_revisions
#' @return Tibble with ch99_ref, first_revision, n_products
get_new_ch99_timeline <- function(results) {
  all_new <- map_dfr(names(results), function(rev_name) {
    r <- results[[rev_name]]
    if (nrow(r$new_ch99) > 0) {
      r$new_ch99 %>%
        mutate(revision = rev_name)
    } else {
      tibble()
    }
  })

  if (nrow(all_new) == 0) {
    return(tibble())
  }

  # Find first appearance of each ch99 ref
  first_appearance <- all_new %>%
    group_by(revision_ch99) %>%
    summarise(
      first_revision = first(revision),
      n_products = n(),
      .groups = 'drop'
    ) %>%
    arrange(first_revision, desc(n_products))

  return(first_appearance)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)

  # Run comparisons
  results <- compare_all_revisions(
    baseline_path = here('data', 'hts_archives', 'hts_2025_basic.json'),
    revision_pattern = here('data', 'hts_archives', 'hts_2025_rev_*.json')
  )

  # Create summary
  summary_table <- summarize_revisions(results)

  cat('\n')
  cat('============================================================\n')
  cat('  REVISION COMPARISON SUMMARY\n')
  cat('============================================================\n')
  print(summary_table, n = 50)

  # New Chapter 99 timeline
  ch99_timeline <- get_new_ch99_timeline(results)

  if (nrow(ch99_timeline) > 0) {
    cat('\n')
    cat('============================================================\n')
    cat('  NEW CHAPTER 99 REFERENCES BY REVISION\n')
    cat('============================================================\n')
    print(ch99_timeline, n = 50)
  }

  # Save results
  ensure_dir(here('output', 'revision_comparison'))
  write_csv(summary_table, here('output', 'revision_comparison', 'summary.csv'))
  write_csv(ch99_timeline, here('output', 'revision_comparison', 'new_ch99_timeline.csv'))
  saveRDS(results, here('output', 'revision_comparison', 'full_results.rds'))

  message('\nResults saved to output/revision_comparison/')
}
