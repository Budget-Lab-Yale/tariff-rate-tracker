# =============================================================================
# Step 01: Scrape Revision Effective Dates from USITC
# =============================================================================
#
# Scrapes https://hts.usitc.gov for HTS revision effective dates.
# Falls back to manual curation via config/revision_dates.csv.
#
# Output: config/revision_dates.csv with columns:
#   - revision: Revision identifier (e.g., 'basic', 'rev_1', ...)
#   - effective_date: Date the revision took effect
#   - tpc_date: Matching TPC validation date (NA for most)
#
# =============================================================================

library(tidyverse)

# =============================================================================
# Scraping Functions
# =============================================================================

#' Scrape revision dates from USITC website
#'
#' Attempts to parse the HTS revision history page for effective dates.
#' Returns a tibble with revision and effective_date columns.
#'
#' @param base_url USITC HTS base URL
#' @param year HTS year (default: 2025)
#' @return Tibble with revision, effective_date
scrape_usitc_revision_dates <- function(
  base_url = 'https://hts.usitc.gov',
  year = 2025
) {
  message('Attempting to scrape revision dates from USITC...')

  # Try to fetch revision history page
  url <- paste0(base_url, '/current')

  tryCatch({
    if (!requireNamespace('rvest', quietly = TRUE)) {
      stop('rvest package required for scraping. Install with: install.packages("rvest")')
    }

    page <- rvest::read_html(url)

    # Look for revision links with dates
    # USITC typically lists revisions with effective dates in tables or lists
    links <- page %>%
      rvest::html_elements('a') %>%
      rvest::html_text2()

    # Try to extract revision + date patterns
    # Pattern: "Revision X (effective Month DD, YYYY)"
    rev_pattern <- regex(
      'Revision\\s+(\\d+).*?(?:effective|eff\\.?)\\s+(\\w+\\s+\\d+,?\\s+\\d{4})',
      ignore_case = TRUE
    )

    matches <- str_match_all(paste(links, collapse = '\n'), rev_pattern)[[1]]

    if (nrow(matches) == 0) {
      message('  No revision dates found via scraping. Using manual CSV.')
      return(NULL)
    }

    scraped <- tibble(
      revision = paste0('rev_', matches[, 2]),
      effective_date = as.Date(matches[, 3], format = '%B %d, %Y')
    )

    message('  Scraped ', nrow(scraped), ' revision dates')
    return(scraped)

  }, error = function(e) {
    message('  Scraping failed: ', conditionMessage(e))
    message('  Falling back to manual CSV.')
    return(NULL)
  })
}


#' Update revision_dates.csv with scraped data
#'
#' Merges scraped dates into existing CSV, preserving manual entries
#' (especially tpc_date which is always manually curated).
#'
#' @param csv_path Path to revision_dates.csv
#' @param scraped Scraped tibble from scrape_usitc_revision_dates()
#' @return Updated tibble
update_revision_dates <- function(csv_path, scraped) {
  existing <- load_revision_dates(csv_path)

  # Only update effective_date for existing revisions; add new ones
  updated <- existing %>%
    left_join(
      scraped %>% rename(scraped_date = effective_date),
      by = 'revision'
    ) %>%
    mutate(
      effective_date = coalesce(scraped_date, effective_date)
    ) %>%
    select(-scraped_date)

  # Add any new revisions from scraping
  new_revs <- scraped %>%
    filter(!revision %in% existing$revision) %>%
    mutate(tpc_date = NA_Date_)

  updated <- bind_rows(updated, new_revs) %>%
    arrange(effective_date)

  write_csv(updated, csv_path)
  message('Updated ', csv_path, ' (', nrow(updated), ' revisions)')

  return(updated)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)
  source(here('src', 'helpers.R'))

  # Try scraping first
  scraped <- scrape_usitc_revision_dates()

  if (!is.null(scraped)) {
    # Merge with existing CSV
    dates <- update_revision_dates('config/revision_dates.csv', scraped)
  } else {
    # Load existing CSV
    dates <- load_revision_dates('config/revision_dates.csv')
  }

  # Cross-reference with available JSON files
  available <- list_available_revisions()
  in_csv <- dates$revision

  missing_json <- setdiff(in_csv, c(available, '2026_basic'))
  missing_csv <- setdiff(available, in_csv)

  if (length(missing_json) > 0) {
    message('\nRevisions in CSV but no JSON: ', paste(missing_json, collapse = ', '))
  }
  if (length(missing_csv) > 0) {
    message('\nJSON files without CSV entry: ', paste(missing_csv, collapse = ', '))
  }

  cat('\n=== Revision Date Summary ===\n')
  print(dates, n = Inf)
}
