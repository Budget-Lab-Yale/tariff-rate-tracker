#!/usr/bin/env Rscript
# Diagnose 2025 monthly USMCA empty result.
# Pulls one chapter batch (ch01-05) for Canada+Mexico, monthly, and dumps:
#   - response shape (a vs b)
#   - unique country values seen in entries[[2]]
#   - first 3 rowEntries from the first table for inspection

suppressMessages({
  library(tidyverse)
  library(here)
  library(jsonlite)
  library(httr)
})

# Source the script as functions only — we need build_query, post_runreport, token loader
src_file <- here('src', 'download_usmca_dataweb.R')
script_lines <- readLines(src_file)

# Trim everything from the line that starts the main pipeline (the
# "rate_limit_sec <- ..." line is stable; everything before is helpers).
end_idx <- grep('^# +Download data:', script_lines)[1]
helper_lines <- script_lines[seq_len(end_idx - 1)]

# Replace commandArgs handling — set fixed args
helper_lines <- sub("^args <- commandArgs.*", "args <- c('--monthly','--year','2025')", helper_lines)

eval(parse(text = paste(helper_lines, collapse = '\n')))

# Now we have build_query, run_query_monthly, post_runreport, token
chapters <- sprintf('%02d', 1:5)
countries <- c(CTY_CANADA, CTY_MEXICO)
q <- build_query(chapters, countries, programs = USMCA_PROGRAMS, year = 2025L,
                 monthly = TRUE)

resp <- post_runreport(q, token)
cat('HTTP status:', status_code(resp), '\n')

result <- content(resp, as = 'parsed', simplifyVector = FALSE)
tables <- result$dto$tables
cat('n tables:', length(tables), '\n')

if (length(tables) > 0) {
  tbl1 <- tables[[1]]
  cat('table[[1]] tableTitle:', tbl1$tableTitle %||% '<none>', '\n')
  cat('table[[1]] n column_groups:', length(tbl1$column_groups), '\n')
  if (length(tbl1$column_groups) >= 2) {
    cg2 <- tbl1$column_groups[[2]]
    cat('column_group[[2]] labels:',
        paste(vapply(cg2$columns, function(c) c$label %||% NA_character_, character(1)),
              collapse = ' | '), '\n')
  }
  rows <- tbl1$row_groups[[1]]$rowsNew
  cat('table[[1]] n rows:', length(rows), '\n')
  if (length(rows) > 0) {
    r1 <- rows[[1]]$rowEntries
    cat('rowEntries n:', length(r1), '\n')
    for (i in seq_along(r1)) {
      cat('  entry[[', i, ']]: label=', r1[[i]]$label %||% '<none>',
          ' value=', r1[[i]]$value %||% '<none>', '\n', sep = '')
    }
  }
}

# Now run the parser and check
parsed <- run_query_monthly(q, token)
cat('\nparsed nrow:', nrow(parsed), '\n')
if (nrow(parsed) > 0) {
  cat('unique country values:\n')
  print(table(parsed$country))
  cat('unique month values:\n')
  print(table(parsed$month))
}
