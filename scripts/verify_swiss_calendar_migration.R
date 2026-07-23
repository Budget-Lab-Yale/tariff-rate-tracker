#!/usr/bin/env Rscript
# Validate the intentional Swiss-calendar schema/timeline migration against the
# last sealed pre-migration vintage. The node-parallel parity harness compares
# all shared values; this script gates the new schema and boundary semantics.

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
  library(here)
})

source(here('src', 'core', 'parity.R'))

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag) {
  i <- which(args == flag)
  if (length(i) && i[1] < length(args)) args[i[1] + 1L] else NULL
}
reference_vintage <- get_arg('--reference')
candidate_vintage <- get_arg('--candidate')
if (is.null(reference_vintage) || is.null(candidate_vintage)) {
  stop('usage: verify_swiss_calendar_migration.R --reference <vintage> --candidate <vintage>',
       call. = FALSE)
}

NEW_COLS <- c(
  'swiss_underlying_rate_ieepa_recip',
  'swiss_framework_floor_rate',
  'swiss_framework_effective_date',
  'swiss_framework_expiry_date'
)
STATE_COLS <- c('revision', 'effective_date', 'valid_from', 'valid_until')
NEW_BOUNDARY <- 'valid_from=2026-04-01/rates.parquet'
PRE_BOUNDARY_OWNER <- 'valid_from=2026-02-24/rates.parquet'
SWISS_COUNTRIES <- c('4419', '4411')

passes <- 0L
must <- function(cond, msg) {
  if (!isTRUE(cond)) stop('FAIL: ', msg, call. = FALSE)
  passes <<- passes + 1L
  message('PASS: ', msg)
}

series_paths <- function(vintage, series) {
  if (series == 'actual') file.path(vintage, 'actual')
  else file.path(vintage, 'scenarios', series)
}

compare_tables <- function(candidate, reference, key_cols, label,
                           drop_cols = character()) {
  keep <- setdiff(names(reference), drop_cols)
  missing <- setdiff(keep, names(candidate))
  must(length(missing) == 0L,
       paste0(label, ': no pre-existing columns disappeared'))
  result <- compare_parity(
    candidate[, keep, drop = FALSE],
    reference[, keep, drop = FALSE],
    key_cols = key_cols,
    label = label
  )
  if (!result$pass) stop(format_parity_report(result), call. = FALSE)
  passes <<- passes + 1L
  message('PASS: ', label, ' values match')
}

verify_series <- function(series) {
  message('\n=== ', series, ' ===')
  ref_root <- resolve_model_data_series(series_paths(reference_vintage, series))
  cand_root <- resolve_model_data_series(series_paths(candidate_vintage, series))
  ref_snaps <- list_parity_artifacts(ref_root, 'snapshot')
  cand_snaps <- list_parity_artifacts(cand_root, 'snapshot')

  must(setequal(setdiff(names(cand_snaps), names(ref_snaps)), NEW_BOUNDARY),
       paste0(series, ': exactly the 2026-04-01 snapshot was added'))
  must(length(setdiff(names(ref_snaps), names(cand_snaps))) == 0L,
       paste0(series, ': no existing snapshot was removed'))

  for (rel in names(ref_snaps)) {
    reference_cols <- open_dataset(ref_snaps[[rel]])$schema$names
    candidate_cols <- open_dataset(cand_snaps[[rel]])$schema$names
    must(setequal(setdiff(candidate_cols, reference_cols), NEW_COLS) &&
           length(setdiff(reference_cols, candidate_cols)) == 0L,
         paste0(series, ': ', rel, ' has exactly four new columns'))
  }

  boundary <- read_parity_artifact(cand_snaps[[NEW_BOUNDARY]])
  owner <- read_parity_artifact(ref_snaps[[PRE_BOUNDARY_OWNER]])
  must(setequal(setdiff(names(boundary), names(owner)), NEW_COLS) &&
         length(setdiff(names(owner), names(boundary))) == 0L,
       paste0(series, ': boundary schema delta is exactly four columns'))
  compare_tables(boundary, owner, c('hts10', 'country'),
                 paste0(series, ':new-boundary-state'), STATE_COLS)
  must(all(as.Date(boundary$valid_from) == as.Date('2026-04-01')) &&
         all(boundary$revision == 'bnd_2026-04-01'),
       paste0(series, ': new snapshot owns 2026-04-01'))

  swiss <- boundary$country %in% SWISS_COUNTRIES
  must(any(swiss), paste0(series, ': boundary contains Swiss/Liechtenstein rows'))
  must(all(abs(boundary$swiss_framework_floor_rate[swiss] - 0.15) <= 1e-12) &&
         all(as.Date(boundary$swiss_framework_effective_date[swiss]) ==
               as.Date('2025-11-14')) &&
         all(as.Date(boundary$swiss_framework_expiry_date[swiss]) ==
               as.Date('2026-03-31')),
       paste0(series, ': framework floor and dates are retained'))
  must(all(boundary$swiss_framework_floor_rate[!swiss] == 0) &&
         all(is.na(boundary$swiss_framework_effective_date[!swiss])) &&
         all(is.na(boundary$swiss_framework_expiry_date[!swiss])),
       paste0(series, ': framework metadata is country-scoped'))
  must(all(abs(boundary$rate_ieepa_recip[swiss] -
                 boundary$swiss_underlying_rate_ieepa_recip[swiss]) <= 1e-12),
       paste0(series, ': post-expiry applied rate equals stored underlying rate'))

  active_rel <- 'valid_from=2025-11-14/rates.parquet'
  must(active_rel %in% names(cand_snaps),
       paste0(series, ': framework effective-date snapshot exists'))
  active <- read_parity_artifact(cand_snaps[[active_rel]])
  active_swiss <- active$country %in% SWISS_COUNTRIES
  must(any(abs(active$rate_ieepa_recip[active_swiss] -
               active$swiss_underlying_rate_ieepa_recip[active_swiss]) > 1e-12),
       paste0(series, ': active framework distinguishes floor from underlying rate'))
  rm(boundary, owner, active)
  gc(FALSE)

}

for (series in c('actual', 'new_301')) verify_series(series)
message('\nSwiss calendar migration accepted: ', passes, ' checks passed.')
