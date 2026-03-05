## Build a changelog of Ch99 changes across all HTS revisions
## Outputs: docs/revision_changelog.md, output/changelog/revision_diffs.csv
##
## Usage: Rscript src/13_revision_changelog.R

library(tidyverse)
library(jsonlite)
library(here)

source(here('src', 'helpers.R'))
source(here('src', '04_parse_chapter99.R'))

# ---- Load revision dates ----
rev_dates <- load_revision_dates(here('config', 'revision_dates.csv'))
revisions <- rev_dates$revision

cat('Processing', length(revisions), 'revisions\n')

# ---- Parse Ch99 for all revisions ----
all_ch99 <- list()
for (rev in revisions) {
  json_path <- tryCatch(
    resolve_json_path(rev, here('data', 'hts_archives')),
    error = function(e) NULL
  )
  if (is.null(json_path)) {
    cat('  SKIP (no JSON):', rev, '\n')
    next
  }
  suppressMessages({
    all_ch99[[rev]] <- parse_chapter99(json_path)
  })
  cat('  Parsed:', rev, '—', nrow(all_ch99[[rev]]), 'Ch99 entries\n')
}

parsed_revisions <- names(all_ch99)
cat('\nSuccessfully parsed:', length(parsed_revisions), 'revisions\n')

# ---- Enhanced comparison: also detect description changes (suspensions, etc.) ----
compare_ch99_full <- function(old_ch99, new_ch99) {
  old_codes <- old_ch99$ch99_code
  new_codes <- new_ch99$ch99_code

  added_codes <- setdiff(new_codes, old_codes)
  removed_codes <- setdiff(old_codes, new_codes)
  common_codes <- intersect(old_codes, new_codes)

  # Rate changes
  old_common <- old_ch99 %>%
    filter(ch99_code %in% common_codes) %>%
    select(ch99_code, rate_old = rate, desc_old = description, general_old = general_raw)
  new_common <- new_ch99 %>%
    filter(ch99_code %in% common_codes) %>%
    select(ch99_code, rate_new = rate, desc_new = description, general_new = general_raw)

  joined <- old_common %>% inner_join(new_common, by = 'ch99_code')

  rate_changes <- joined %>%
    filter(
      (!is.na(rate_old) & !is.na(rate_new) & abs(rate_old - rate_new) > 0.0001) |
      (is.na(rate_old) != is.na(rate_new))
    ) %>%
    mutate(change_type = 'rate_change')

  # Description changes (catch suspensions, compiler notes, etc.)
  desc_changes <- joined %>%
    filter(desc_old != desc_new) %>%
    # Only keep substantive changes (skip whitespace-only)
    filter(trimws(desc_old) != trimws(desc_new)) %>%
    # Flag suspensions
    mutate(
      was_suspended = str_detect(tolower(desc_new), 'suspend'),
      was_unsuspended = str_detect(tolower(desc_old), 'suspend') & !str_detect(tolower(desc_new), 'suspend'),
      change_type = case_when(
        was_suspended ~ 'suspended',
        was_unsuspended ~ 'unsuspended',
        TRUE ~ 'description_change'
      )
    ) %>%
    select(ch99_code, desc_old, desc_new, change_type, was_suspended, was_unsuspended)

  # General rate text changes (catch rate-text-only changes)
  general_changes <- joined %>%
    filter(general_old != general_new) %>%
    filter(trimws(general_old) != trimws(general_new)) %>%
    mutate(change_type = 'general_text_change') %>%
    select(ch99_code, general_old, general_new, change_type)

  list(
    added = new_ch99 %>% filter(ch99_code %in% added_codes) %>%
      select(ch99_code, rate, authority, country_type, general_raw, description),
    removed = old_ch99 %>% filter(ch99_code %in% removed_codes) %>%
      select(ch99_code, rate, authority, country_type, general_raw, description),
    rate_changes = rate_changes,
    desc_changes = desc_changes,
    general_changes = general_changes,
    n_added = length(added_codes),
    n_removed = length(removed_codes),
    n_rate_changes = nrow(rate_changes),
    n_desc_changes = nrow(desc_changes),
    n_general_changes = nrow(general_changes)
  )
}

# ---- Diff all consecutive revisions ----
changelog <- list()

for (i in 2:length(parsed_revisions)) {
  prev_rev <- parsed_revisions[i - 1]
  curr_rev <- parsed_revisions[i]

  eff_date <- rev_dates %>% filter(revision == curr_rev) %>% pull(effective_date)

  diff <- compare_ch99_full(all_ch99[[prev_rev]], all_ch99[[curr_rev]])

  changelog[[curr_rev]] <- list(
    prev_revision = prev_rev,
    revision = curr_rev,
    effective_date = eff_date,
    diff = diff
  )

  # Print summary
  n_changes <- diff$n_added + diff$n_removed + diff$n_rate_changes +
    diff$n_desc_changes + diff$n_general_changes
  if (n_changes > 0) {
    cat('\n', strrep('-', 60), '\n')
    cat(curr_rev, ' (', as.character(eff_date), ')\n', sep = '')
    if (diff$n_added > 0) {
      cat('  ADDED (', diff$n_added, '):\n')
      for (r in seq_len(nrow(diff$added))) {
        row <- diff$added[r, ]
        rate_str <- if (!is.na(row$rate)) paste0(round(row$rate * 100, 1), '%') else row$general_raw
        cat('    ', row$ch99_code, ' [', row$authority, '] ', rate_str, '\n', sep = '')
        # Show truncated description
        desc_short <- substr(row$description, 1, 100)
        cat('      ', desc_short, if (nchar(row$description) > 100) '...' else '', '\n', sep = '')
      }
    }
    if (diff$n_removed > 0) {
      cat('  REMOVED (', diff$n_removed, '):\n')
      for (r in seq_len(nrow(diff$removed))) {
        row <- diff$removed[r, ]
        cat('    ', row$ch99_code, ' [', row$authority, ']\n', sep = '')
      }
    }
    if (diff$n_rate_changes > 0) {
      cat('  RATE CHANGES (', diff$n_rate_changes, '):\n')
      for (r in seq_len(nrow(diff$rate_changes))) {
        row <- diff$rate_changes[r, ]
        old_str <- if (!is.na(row$rate_old)) paste0(round(row$rate_old * 100, 1), '%') else 'NA'
        new_str <- if (!is.na(row$rate_new)) paste0(round(row$rate_new * 100, 1), '%') else 'NA'
        cat('    ', row$ch99_code, ': ', old_str, ' -> ', new_str, '\n', sep = '')
      }
    }
    if (diff$n_desc_changes > 0) {
      # Only show suspension changes in console (others too verbose)
      suspensions <- diff$desc_changes %>% filter(was_suspended | was_unsuspended)
      if (nrow(suspensions) > 0) {
        cat('  SUSPENSIONS/UNSUSPENSIONS (', nrow(suspensions), '):\n')
        for (r in seq_len(nrow(suspensions))) {
          row <- suspensions[r, ]
          label <- if (row$was_suspended) 'SUSPENDED' else 'UNSUSPENDED'
          cat('    ', row$ch99_code, ': ', label, '\n', sep = '')
        }
      }
      other_desc <- diff$desc_changes %>% filter(!was_suspended & !was_unsuspended)
      if (nrow(other_desc) > 0) {
        cat('  OTHER DESCRIPTION CHANGES: ', nrow(other_desc), '\n')
      }
    }
    if (diff$n_general_changes > 0 && diff$n_rate_changes == 0) {
      cat('  GENERAL TEXT CHANGES: ', diff$n_general_changes, '\n')
    }
  }
}

# ---- Build flat diff CSV ----
diff_rows <- list()
for (rev_name in names(changelog)) {
  entry <- changelog[[rev_name]]
  d <- entry$diff
  eff <- as.character(entry$effective_date)

  if (d$n_added > 0) {
    diff_rows[[length(diff_rows) + 1]] <- d$added %>%
      mutate(revision = rev_name, effective_date = eff, change = 'added',
             rate_pct = round(rate * 100, 1)) %>%
      select(revision, effective_date, change, ch99_code, authority, rate_pct, description)
  }
  if (d$n_removed > 0) {
    diff_rows[[length(diff_rows) + 1]] <- d$removed %>%
      mutate(revision = rev_name, effective_date = eff, change = 'removed',
             rate_pct = round(rate * 100, 1)) %>%
      select(revision, effective_date, change, ch99_code, authority, rate_pct, description)
  }
  if (d$n_rate_changes > 0) {
    diff_rows[[length(diff_rows) + 1]] <- d$rate_changes %>%
      mutate(revision = rev_name, effective_date = eff, change = 'rate_change',
             authority = map_chr(ch99_code, classify_authority),
             rate_pct = round(rate_new * 100, 1),
             description = paste0(round(rate_old * 100, 1), '% -> ', round(rate_new * 100, 1), '%')) %>%
      select(revision, effective_date, change, ch99_code, authority, rate_pct, description)
  }
  suspensions <- d$desc_changes %>% filter(was_suspended)
  if (nrow(suspensions) > 0) {
    diff_rows[[length(diff_rows) + 1]] <- suspensions %>%
      mutate(revision = rev_name, effective_date = eff, change = 'suspended',
             authority = map_chr(ch99_code, classify_authority),
             rate_pct = NA_real_,
             description = substr(desc_new, 1, 200)) %>%
      select(revision, effective_date, change, ch99_code, authority, rate_pct, description)
  }
  unsuspensions <- d$desc_changes %>% filter(was_unsuspended)
  if (nrow(unsuspensions) > 0) {
    diff_rows[[length(diff_rows) + 1]] <- unsuspensions %>%
      mutate(revision = rev_name, effective_date = eff, change = 'unsuspended',
             authority = map_chr(ch99_code, classify_authority),
             rate_pct = NA_real_,
             description = substr(desc_new, 1, 200)) %>%
      select(revision, effective_date, change, ch99_code, authority, rate_pct, description)
  }
}

diff_df <- bind_rows(diff_rows)

# ---- Save outputs ----
out_dir <- here('output', 'changelog')
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
write_csv(diff_df, file.path(out_dir, 'revision_diffs.csv'))
cat('\n\nSaved', nrow(diff_df), 'diff entries to output/changelog/revision_diffs.csv\n')

# ---- Generate summary table ----
summary_table <- tibble(
  revision = parsed_revisions,
  effective_date = rev_dates %>% filter(revision %in% parsed_revisions) %>% pull(effective_date),
  n_ch99 = map_int(all_ch99[parsed_revisions], nrow)
) %>%
  mutate(
    added = map_int(revision, ~ {
      if (. %in% names(changelog)) changelog[[.]]$diff$n_added else NA_integer_
    }),
    removed = map_int(revision, ~ {
      if (. %in% names(changelog)) changelog[[.]]$diff$n_removed else NA_integer_
    }),
    rate_changes = map_int(revision, ~ {
      if (. %in% names(changelog)) changelog[[.]]$diff$n_rate_changes else NA_integer_
    }),
    suspensions = map_int(revision, ~ {
      if (. %in% names(changelog)) {
        sum(changelog[[.]]$diff$desc_changes$was_suspended, na.rm = TRUE)
      } else NA_integer_
    })
  )

write_csv(summary_table, file.path(out_dir, 'revision_summary.csv'))
cat('Saved revision summary to output/changelog/revision_summary.csv\n')

cat('\n--- Revision Summary ---\n')
print(summary_table, n = 40)

# ---- Also print authority breakdown per revision ----
cat('\n--- Authority counts by revision (selected) ---\n')
key_revisions <- c('basic', 'rev_1', 'rev_4', 'rev_6', 'rev_9', 'rev_10',
                    'rev_14', 'rev_17', 'rev_18', 'rev_32', '2026_basic')
for (rev in key_revisions) {
  if (rev %in% names(all_ch99)) {
    auth_counts <- all_ch99[[rev]] %>% count(authority, sort = TRUE)
    cat('\n', rev, ':\n')
    for (r in seq_len(nrow(auth_counts))) {
      cat('  ', auth_counts$authority[r], ': ', auth_counts$n[r], '\n', sep = '')
    }
  }
}

cat('\n\nChangelog complete.\n')
