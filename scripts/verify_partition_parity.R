# =============================================================================
# Partition parity: candidate build vs a published vintage (plan §3 test 13)
# =============================================================================
#
# Answers Phase 2 acceptance criterion (b) — "all earlier partitions remain
# identical" — and the broader candidate-build parity gate.
#
# IMPORTANT: differences are EXPECTED, and finding none would itself be
# suspicious. The published reference predates deliberate rate corrections
# (the Solar 201 termination gate, the UK pharmaceutical rate). The question is
# not "did anything change" but "is every change attributable to a documented
# correction, and did the rev_13/rev_15 INGEST change anything on its own".
# The ingest is characterised as rate-neutral; a difference on a pre-rev_13
# partition that is not explained by a known correction would falsify that.
#
# Compares per-partition, one at a time, rather than materialising the whole
# ~292M-row series.
#
# Reference layout: <vintage>/actual/snapshots/valid_from=<date>/rates.parquet
# Candidate layout: <timeseries>/snapshot_<revision>.rds  (carries valid_from)
#
# Usage:
#   Rscript scripts/verify_partition_parity.R \
#     --reference /.../model_data/Tariff-Rate-Tracker/latest \
#     --candidate /.../tariff-rate-tracker-buildclean/data/timeseries \
#     [--out output/parity]
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(arrow)
  library(here)
})

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, default = NULL) {
  i <- which(args == flag)
  if (length(i) == 0) return(default)
  args[i[1] + 1]
}

reference <- get_arg('--reference')
candidate <- get_arg('--candidate')
out_dir   <- get_arg('--out', here('output', 'parity'))

if (is.null(reference) || is.null(candidate)) {
  stop('Both --reference and --candidate are required.')
}

ref_snapshots <- file.path(reference, 'actual', 'snapshots')
if (!dir.exists(ref_snapshots)) stop('No snapshots under reference: ', ref_snapshots)
if (!dir.exists(candidate)) stop('Candidate dir not found: ', candidate)

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

KEY <- c('hts10', 'country')
TOL <- 1e-9

# Not comparable at the snapshot stage: per-revision snapshots carry these as
# all-NA and the streaming combine fills them in later, so the reference (built
# from the combined series) has them populated and the candidate does not. Left
# in, they differ on every row of every partition and drown out real findings.
# Their correctness belongs to a combined-series check, not this one.
NOT_COMPARABLE <- c('valid_from', 'valid_until')

ref_dates <- sort(sub('^valid_from=', '',
                      list.files(ref_snapshots, pattern = '^valid_from=')))
cand_files <- sort(list.files(candidate, pattern = '^snapshot_.*\\.rds$', full.names = TRUE))

cat('Reference: ', reference, '\n  partitions: ', length(ref_dates), '\n', sep = '')
cat('Candidate: ', candidate, '\n  snapshots:  ', length(cand_files), '\n', sep = '')
cat('Excluded from comparison (populated post-combine, not in per-revision ',
    'snapshots): ', paste(NOT_COMPARABLE, collapse = ', '), '\n\n', sep = '')

#' Compare one partition; returns a one-row-per-differing-column tibble
compare_partition <- function(valid_from, ref_path, cand) {
  ref <- as.data.frame(read_parquet(ref_path))
  cand <- as.data.frame(cand)

  shared_cols <- setdiff(intersect(names(ref), names(cand)), c(KEY, NOT_COMPARABLE))
  joined <- inner_join(
    ref[, c(KEY, shared_cols)], cand[, c(KEY, shared_cols)],
    by = KEY, suffix = c('.ref', '.cand')
  )

  rows <- lapply(shared_cols, function(col) {
    a <- joined[[paste0(col, '.ref')]]
    b <- joined[[paste0(col, '.cand')]]
    # NA must match NA; a value becoming NA is a real difference, and a naive
    # comparison would score it as "no difference" by dropping the row.
    differs <- if (is.numeric(a) && is.numeric(b)) {
      xor(is.na(a), is.na(b)) | (!is.na(a) & !is.na(b) & abs(a - b) > TOL)
    } else {
      xor(is.na(a), is.na(b)) |
        (!is.na(a) & !is.na(b) & as.character(a) != as.character(b))
    }
    n <- sum(differs)
    if (n == 0) return(NULL)
    tibble(valid_from = valid_from, column = col, n_differing = n,
           n_rows = nrow(joined),
           mean_ref = if (is.numeric(a)) mean(a[differs], na.rm = TRUE) else NA_real_,
           mean_cand = if (is.numeric(b)) mean(b[differs], na.rm = TRUE) else NA_real_)
  })

  list(
    diffs = bind_rows(rows),
    n_ref = nrow(ref), n_cand = nrow(cand), n_joined = nrow(joined)
  )
}

all_diffs <- list()
coverage <- list()

for (f in cand_files) {
  cand <- readRDS(f)
  # Key on effective_date, NOT valid_from. Per-revision snapshots carry
  # valid_from/valid_until as all-NA — those interval columns are filled in
  # later, by the streaming combine that builds rate_timeseries.rds. Reading
  # valid_from here silently yielded NA for every snapshot, so nothing matched
  # the reference and the run reported "60 new, 57 missing" while exiting 0.
  vf <- unique(as.character(cand$effective_date))
  if (length(vf) != 1 || is.na(vf)) {
    stop('Candidate snapshot ', basename(f), ' has ', length(vf),
         ' distinct effective_date value(s) (', paste(vf, collapse = ', '),
         '); expected exactly one non-NA date.')
  }

  ref_path <- file.path(ref_snapshots, paste0('valid_from=', vf), 'rates.parquet')
  if (!file.exists(ref_path)) {
    cat(sprintf('  %s  NEW partition (absent from reference) — %s\n', vf, basename(f)))
    coverage[[length(coverage) + 1L]] <- tibble(
      valid_from = vf, status = 'new_in_candidate',
      n_ref = NA_integer_, n_cand = nrow(cand))
    next
  }

  res <- compare_partition(vf, ref_path, cand)
  status <- if (nrow(res$diffs) == 0) 'identical' else 'differs'
  cat(sprintf('  %s  %-9s  rows ref=%d cand=%d joined=%d%s\n',
              vf, status, res$n_ref, res$n_cand, res$n_joined,
              if (nrow(res$diffs)) paste0('  [', paste(res$diffs$column, collapse = ', '), ']') else ''))

  coverage[[length(coverage) + 1L]] <- tibble(
    valid_from = vf, status = status, n_ref = res$n_ref, n_cand = res$n_cand)
  if (nrow(res$diffs) > 0) all_diffs[[length(all_diffs) + 1L]] <- res$diffs

  rm(cand); invisible(gc(verbose = FALSE))
}

coverage <- bind_rows(coverage) %>% arrange(valid_from)
diffs <- bind_rows(all_diffs)

# Reference partitions the candidate never produced — a dropped partition is as
# serious as a changed one and would otherwise go unmentioned.
missing_in_cand <- setdiff(ref_dates, coverage$valid_from)
if (length(missing_in_cand) > 0) {
  cat('\n  !! reference partitions ABSENT from candidate: ',
      paste(missing_in_cand, collapse = ', '), '\n', sep = '')
}

write_csv(coverage, file.path(out_dir, 'partition_coverage.csv'))
write_csv(diffs, file.path(out_dir, 'partition_diffs.csv'))

n_compared <- sum(coverage$status %in% c('identical', 'differs'))

cat('\n', strrep('=', 70), '\n', sep = '')
cat('Partitions: ', sum(coverage$status == 'identical'), ' identical, ',
    sum(coverage$status == 'differs'), ' differing, ',
    sum(coverage$status == 'new_in_candidate'), ' new, ',
    length(missing_in_cand), ' missing\n', sep = '')

# A parity run that compared nothing is a FAILURE, not a pass. The first
# version of this script keyed on an all-NA column, matched zero partitions,
# and exited 0 — "no differences found" because nothing was ever looked at.
if (n_compared == 0) {
  stop('Compared 0 partitions: every candidate snapshot failed to match a ',
       'reference partition. The two sides are not being keyed on the same ',
       'value — check the partition key before trusting any "no differences" ',
       'result.')
}
# Likewise, matching only a handful out of ~57 means the key is partly wrong.
if (n_compared < 0.5 * length(ref_dates)) {
  stop('Compared only ', n_compared, ' of ', length(ref_dates),
       ' reference partitions. Too few to call this a parity check — the ',
       'partition key is probably mismatched for the rest.')
}

if (nrow(diffs) > 0) {
  cat('\nDiffering columns, earliest partition each (attribute every one):\n')
  summary_by_col <- diffs %>%
    group_by(column) %>%
    summarise(first_partition = min(valid_from), n_partitions = n(),
              max_rows_differing = max(n_differing), .groups = 'drop') %>%
    arrange(first_partition, column)
  print(as.data.frame(summary_by_col), row.names = FALSE)
}
cat(strrep('=', 70), '\n')
cat('Wrote: ', file.path(out_dir, 'partition_coverage.csv'), '\n',
    '       ', file.path(out_dir, 'partition_diffs.csv'), '\n', sep = '')
