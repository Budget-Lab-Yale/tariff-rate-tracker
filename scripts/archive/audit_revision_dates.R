# =============================================================================
# Audit revision_dates.csv against the official USITC change records
# =============================================================================
#
# config/revision_dates.csv's effective_date comes from the releaseList API's
# releaseStartDate, which disagrees with the per-release change records (see
# todo.md active priority 2: rev_12 carries the Geneva suspension but is dated
# 2025-04-14; rev_25-31 are dated 1-3 weeks before their change records).
#
# For every revision with a change record in data/hts_change_record/, this
# script extracts:
#   - publication date (line 2 of the record)
#   - the distinct ITEM effective dates with counts (the legal dates of the
#     changes the revision introduces)
# and diffs them against the CSV's effective_date / policy_effective_date.
#
# Output: output/revision_date_audit.csv + console table. Use it to populate
# policy_effective_date (the existing load_revision_dates() override column).
#
# Usage: Rscript scripts/audit_revision_dates.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})

rev_dates <- read_csv(here('config', 'revision_dates.csv'),
                      col_types = cols(.default = col_character()))

record_for <- function(rev) {
  # revision id -> change record filename
  if (grepl('^2026_', rev)) {
    base <- sub('^2026_', '', rev)
    name <- if (base == 'basic') '2026HTSBasic' else paste0('2026HTSRev', sub('rev_', '', base))
  } else {
    name <- if (rev == 'basic') '2025HTSBasic' else paste0('2025HTSRev', sub('rev_', '', rev))
  }
  here('data', 'hts_change_record', paste0(name, '_change_record.pdf'))
}

MONTHS <- 'January|February|March|April|May|June|July|August|September|October|November|December'
DATE_RE <- paste0('(', MONTHS, ')\\s+\\d{1,2},\\s+\\d{4}')

audit <- map_dfr(seq_len(nrow(rev_dates)), function(i) {
  rev <- rev_dates$revision[i]
  f <- record_for(rev)
  out <- tibble(
    revision = rev,
    csv_effective_date = rev_dates$effective_date[i],
    csv_policy_date = rev_dates$policy_effective_date[i],
    publication_date = NA_character_,
    item_dates = NA_character_,
    modal_item_date = NA_character_
  )
  if (!file.exists(f)) return(out)

  txt <- tryCatch(paste(pdftools::pdf_text(f), collapse = '\n'),
                  error = function(e) NA_character_)
  if (is.na(txt)) return(out)
  lines <- trimws(unlist(strsplit(txt, '\n')))
  lines <- lines[lines != '']

  # Publication date: the standalone date line near the top
  pub_idx <- grep(paste0('^', DATE_RE, '$'), lines[1:6])
  pub <- if (length(pub_idx) > 0) lines[1:6][pub_idx[1]] else NA_character_

  # Item effective dates: all date strings AFTER the header boilerplate,
  # excluding repeats of the publication date line itself
  body <- lines[-seq_len(min(8, length(lines)))]
  dates <- unlist(regmatches(body, gregexpr(DATE_RE, body)))
  parsed <- as.Date(dates, format = '%B %d, %Y')
  parsed <- parsed[!is.na(parsed)]
  tb <- sort(table(format(parsed, '%Y-%m-%d')), decreasing = TRUE)

  out$publication_date <- if (!is.na(pub)) format(as.Date(pub, format = '%B %d, %Y'), '%Y-%m-%d') else NA_character_
  out$item_dates <- paste(names(tb), tb, sep = ' x', collapse = '; ')
  out$modal_item_date <- if (length(tb) > 0) names(tb)[1] else NA_character_
  out
})

audit <- audit %>%
  mutate(
    csv_vs_modal_days = suppressWarnings(
      as.integer(as.Date(modal_item_date) - as.Date(csv_effective_date))),
    flag = case_when(
      is.na(modal_item_date) ~ 'no record / no items',
      abs(csv_vs_modal_days) <= 2 ~ '',
      TRUE ~ 'MISMATCH'
    )
  )

write_csv(audit, here('output', 'revision_date_audit.csv'))
message('Wrote output/revision_date_audit.csv')
print(audit %>%
        select(revision, csv_effective_date, publication_date,
               modal_item_date, csv_vs_modal_days, flag),
      n = 50)
