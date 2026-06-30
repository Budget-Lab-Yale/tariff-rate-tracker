#!/usr/bin/env Rscript
# =============================================================================
# list_revisions.R — print the revision ids the build would process, in order
# =============================================================================
#
# Full build timeline: real revisions from revision_dates.csv that have a JSON
# archive, plus synthetic boundary/scheduled revisions, in effective-date order.
# Used to size and index the Slurm array build. Writes the revision-id text file
# and the full timeline RDS for build_revision.R.
#
# Usage:
#   Rscript scripts/list_revisions.R [--use-hts-dates]
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(tidyverse)
})
suppressMessages({
  source(here('src', 'pipeline', '00_build_timeseries.R'))
  source(here('src', 'model', 'revisions.R'))
  source(here('src', 'model', 'policy_params.R'))
})

args <- commandArgs(trailingOnly = TRUE)
use_policy_dates <- !('--use-hts-dates' %in% args)
timeline_path <- Sys.getenv('REV_TIMELINE', 'output/build_array_timeline.rds')
revlist_path <- Sys.getenv('REVLIST', 'output/build_array_revisions.txt')

rev_dates <- load_revision_dates(use_policy_dates = use_policy_dates)
pp <- load_policy_params(use_policy_dates = use_policy_dates)
timeline <- build_array_revision_timeline(rev_dates, pp, here('data', 'hts_archives'))

dir.create(dirname(timeline_path), recursive = TRUE, showWarnings = FALSE)
dir.create(dirname(revlist_path), recursive = TRUE, showWarnings = FALSE)
saveRDS(timeline, timeline_path)
writeLines(timeline$revision, revlist_path)
message('Wrote ', nrow(timeline), ' build timeline row(s): ', revlist_path,
        ' and ', timeline_path)
