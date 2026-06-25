# =============================================================================
# Publish (Git): Build Outputs to release/ in the Repo
# =============================================================================
#
# Public-release counterpart to src/io/write_output.R. This module writes a curated
# subset of build outputs into release/ within the repo, with publication-date
# suffixes on every filename, so that each --publish-git run produces a new
# commit-ready set of artifacts.
#
# Layout:
#
#   release/
#     README.md                                       # tracked, hand-written
#     MANIFEST.json                                   # overwritten each run
#     data/
#       daily_overall_2026-05-21.csv                  # csv for small files
#       daily_by_country_2026-05-21.csv
#       daily_by_authority_2026-05-21.csv
#       daily_by_category_2026-05-21.csv
#
# Only the latest publication's files live on disk at any time — `publish_git`
# deletes the prior data/* before writing the new set. Historical publications
# are recoverable via `git log -- release/`.
#
# CSV vs parquet: explicit per-output (see RELEASE_OUTPUTS below). The public
# git release currently publishes the daily aggregate views; the full rate panel
# is written by write_build_output as per-interval snapshot parquets.
#
# Usage (programmatic):
#
#   source(here('src', 'io', 'publish_git.R'))
#   publish_git(
#     build_flags = list(full = TRUE, core_only = TRUE),
#     build_started_at = Sys.time()
#   )
#
# =============================================================================

library(jsonlite)
library(here)


RELEASE_DIR_DEFAULT <- here('release')


# Curated subset of outputs to publish. Each entry:
#   name   — base name for the output file (no extension, no date)
#   src    — path relative to repo_root
#   format — 'parquet' or 'csv'; the format the released file is written in
RELEASE_OUTPUTS <- list(
  list(name = 'daily_overall',       src = 'output/actual/daily/daily_overall.csv',       format = 'csv'),
  list(name = 'daily_by_country',    src = 'output/actual/daily/daily_by_country.csv',    format = 'csv'),
  list(name = 'daily_by_authority',  src = 'output/actual/daily/daily_by_authority.csv',  format = 'csv'),
  list(name = 'daily_by_category',   src = 'output/actual/daily/daily_by_category.csv',   format = 'csv')
)


#' Publish a dated, curated subset of build outputs to release/ in the repo.
#'
#' @param release_dir Root directory under which release/data/ is written.
#' @param repo_root Repo root from which outputs are read.
#' @param publication_date Date object used in filenames. Defaults to today.
#' @param build_flags Named list of CLI flags actually used (recorded in manifest).
#' @param build_started_at POSIXct; staleness guard skips outputs older than this.
#'   Pass NULL to skip the guard (for standalone runs operating on existing outputs).
#' @param dry_run If TRUE, plan only — log the write list and manifest without
#'   touching disk.
#' @return Invisibly, a list with `release_dir`, `publication_date`, `manifest`,
#'   and `n_files`. NULL on dry-run.
publish_git <- function(release_dir = RELEASE_DIR_DEFAULT,
                        repo_root = here(),
                        publication_date = Sys.Date(),
                        build_flags = list(),
                        build_started_at = Sys.time(),
                        dry_run = FALSE) {

  needs_arrow <- any(vapply(RELEASE_OUTPUTS, function(x) identical(x$format, 'parquet'), logical(1)))
  if (needs_arrow && !requireNamespace('arrow', quietly = TRUE)) {
    stop('publish_git requires the arrow package (parquet conversion). ',
         'Install with: Rscript tools/install_dependencies.R --all')
  }
  if (!requireNamespace('digest', quietly = TRUE)) {
    stop('publish_git requires the digest package (manifest sha256). ',
         'Install with: Rscript tools/install_dependencies.R --all')
  }

  date_str <- format(publication_date, '%Y-%m-%d')
  data_dir <- file.path(release_dir, 'data')

  message('\n', strrep('=', 70))
  message('PUBLISHING TO REPO (release/)')
  message(strrep('=', 70))
  message('Release dir:        ', release_dir)
  message('Publication date:   ', date_str)
  message('Repo root:          ', repo_root)
  if (dry_run) message('DRY RUN — no files will be written')
  message(strrep('=', 70))

  # Validate EVERY source before touching the prior publication. Publishing is
  # all-or-nothing: a missing or stale source aborts with nothing deleted and
  # nothing written. (The old behavior deleted release/data/* first and skipped
  # bad sources with a message — a path typo or a failed daily-series step
  # could silently wipe the prior publication and "publish" zero files.)
  problems <- character(0)
  for (out in RELEASE_OUTPUTS) {
    src_path <- file.path(repo_root, out$src)
    if (!file.exists(src_path)) {
      problems <- c(problems, paste0('missing: ', out$src))
      next
    }
    info <- file.info(src_path)
    if (!is.null(build_started_at) && !is.na(info$mtime) &&
        info$mtime < build_started_at) {
      problems <- c(problems, paste0('stale: ', out$src, ' (mtime ', info$mtime,
                                     ' < build start ', build_started_at, ')'))
    }
  }
  if (length(problems) > 0) {
    stop('publish-git: refusing to publish — ', length(problems), ' of ',
         length(RELEASE_OUTPUTS), ' source(s) failed validation:\n  ',
         paste(problems, collapse = '\n  '),
         '\nNothing was deleted or written. Rebuild the missing/stale outputs ',
         '(daily series writes to output/actual/daily/), then re-run.')
  }

  # Clear prior data files (sources validated above). README.md and
  # MANIFEST.json at the top of release/ are preserved; .gitkeep is kept so
  # the directory stays tracked between publications.
  if (!dry_run) {
    if (dir.exists(data_dir)) {
      old <- setdiff(list.files(data_dir, full.names = TRUE, all.files = TRUE, no.. = TRUE),
                     file.path(data_dir, '.gitkeep'))
      if (length(old) > 0) {
        message('publish-git: removing ', length(old), ' file(s) from prior publication')
        file.remove(old)
      }
    } else {
      dir.create(data_dir, recursive = TRUE, showWarnings = FALSE)
    }
  }

  written <- list()
  for (out in RELEASE_OUTPUTS) {
    src_path <- file.path(repo_root, out$src)

    dest_name <- paste0(out$name, '_', date_str, '.', out$format)
    dest_path <- file.path(data_dir, dest_name)

    message('publish-git: ', out$src, ' -> ', file.path('release', 'data', dest_name))
    if (!dry_run) {
      n_rows <- write_release_file(src_path, dest_path, out$format)
    } else {
      n_rows <- NA_integer_
    }

    written[[length(written) + 1L]] <- list(
      name = out$name,
      source = out$src,
      path = file.path('data', dest_name),
      format = out$format,
      n_rows = n_rows,
      size_bytes = if (dry_run) NA_integer_ else as.integer(file.info(dest_path)$size),
      sha256 = if (dry_run) NA_character_ else digest::digest(file = dest_path, algo = 'sha256')
    )
  }

  data_as_of <- read_data_as_of(repo_root)

  manifest <- list(
    publication_date = date_str,
    published_at = format(Sys.time(), '%Y-%m-%dT%H:%M:%S%z'),
    data_as_of = data_as_of,
    build_started_at = if (is.null(build_started_at)) NA_character_
                       else format(build_started_at, '%Y-%m-%dT%H:%M:%S%z'),
    repo_root = repo_root,
    git = capture_git_info_release(repo_root),
    build_flags = build_flags,
    r_version = paste(R.version$major, R.version$minor, sep = '.'),
    package_versions = capture_pkg_versions(),
    files = written
  )

  if (!dry_run) {
    write(jsonlite::toJSON(manifest, pretty = TRUE, auto_unbox = TRUE, na = 'string'),
          file.path(release_dir, 'MANIFEST.json'))
  }

  message('\nPublished ', length(written), ' file(s) to ', data_dir)
  message('Manifest:   ', file.path(release_dir, 'MANIFEST.json'))
  message('Next step:  review with `git status release/`, then commit.')
  message(strrep('=', 70), '\n')

  invisible(list(release_dir = release_dir,
                 publication_date = date_str,
                 manifest = manifest,
                 n_files = length(written)))
}


#' Write a single release output, converting format if needed. Returns row count.
#'
#' @keywords internal
write_release_file <- function(src_path, dest_path, format) {
  src_ext <- tools::file_ext(src_path)

  if (identical(format, 'parquet')) {
    df <- if (tolower(src_ext) == 'rds') readRDS(src_path) else readr::read_csv(src_path, show_col_types = FALSE)
    arrow::write_parquet(df, dest_path, compression = 'zstd', compression_level = 5L)
    n_rows <- nrow(df)
    rm(df); gc()
    return(as.integer(n_rows))
  }

  if (identical(format, 'csv')) {
    if (tolower(src_ext) == 'csv') {
      file.copy(src_path, dest_path, overwrite = TRUE)
      # Cheap row count: lines minus header.
      n_lines <- length(readLines(dest_path, warn = FALSE))
      return(as.integer(max(0L, n_lines - 1L)))
    }
    df <- if (tolower(src_ext) == 'rds') readRDS(src_path) else readr::read_csv(src_path, show_col_types = FALSE)
    readr::write_csv(df, dest_path)
    n_rows <- nrow(df)
    rm(df); gc()
    return(as.integer(n_rows))
  }

  stop('Unknown release format: ', format)
}


#' Read the data-as-of date from timeseries metadata if available.
#'
#' @keywords internal
read_data_as_of <- function(repo_root) {
  meta_path <- file.path(repo_root, 'data', 'timeseries', 'metadata.rds')
  if (!file.exists(meta_path)) return(list())
  meta <- tryCatch(readRDS(meta_path), error = function(e) NULL)
  if (is.null(meta)) return(list())
  list(
    last_revision = if (!is.null(meta$last_revision)) meta$last_revision else NA_character_,
    last_build_time = if (!is.null(meta$last_build_time))
                        format(meta$last_build_time, '%Y-%m-%dT%H:%M:%S%z')
                      else NA_character_
  )
}


#' Best-effort capture of git commit, branch, dirty bit. NA if not a repo.
#' Duplicated lightly from write_output.R to avoid cross-source coupling.
#'
#' @keywords internal
capture_git_info_release <- function(repo_root) {
  is_repo <- suppressWarnings(
    system2('git', c('-C', repo_root, 'rev-parse', '--is-inside-work-tree'),
            stdout = TRUE, stderr = FALSE)
  )
  if (length(is_repo) == 0 || !identical(trimws(is_repo[1]), 'true')) {
    return(list(commit = NA_character_, branch = NA_character_,
                dirty = NA, remote = NA_character_))
  }
  commit <- tryCatch(trimws(system2('git', c('-C', repo_root, 'rev-parse', 'HEAD'),
                                    stdout = TRUE, stderr = FALSE))[1],
                     error = function(e) NA_character_)
  branch <- tryCatch(trimws(system2('git', c('-C', repo_root, 'rev-parse', '--abbrev-ref', 'HEAD'),
                                    stdout = TRUE, stderr = FALSE))[1],
                     error = function(e) NA_character_)
  dirty_lines <- tryCatch(system2('git', c('-C', repo_root, 'status', '--porcelain'),
                                  stdout = TRUE, stderr = FALSE),
                          error = function(e) character())
  remote <- tryCatch(trimws(system2('git', c('-C', repo_root, 'config', '--get', 'remote.origin.url'),
                                    stdout = TRUE, stderr = FALSE))[1],
                     error = function(e) NA_character_)
  list(commit = commit, branch = branch,
       dirty = length(dirty_lines) > 0, remote = remote)
}


#' @keywords internal
capture_pkg_versions <- function() {
  pkgs <- c('tidyverse', 'jsonlite', 'yaml', 'here', 'arrow', 'digest', 'readr')
  v <- vapply(pkgs, function(p) {
    if (requireNamespace(p, quietly = TRUE)) as.character(utils::packageVersion(p))
    else NA_character_
  }, character(1))
  as.list(v)
}


# =============================================================================
# CLI Entry Point
# =============================================================================
#
# Standalone publish-git (after a build has already been run):
#   Rscript src/io/publish_git.R
#   Rscript src/io/publish_git.R --dry-run
#   Rscript src/io/publish_git.R --date 2026-05-21
#
# This mode does NOT know which build flags produced the outputs; it records
# `manual = TRUE` in the manifest. For full provenance, prefer publishing via
# `--publish-git` on src/pipeline/00_build_timeseries.R.

if (sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  dry_run <- '--dry-run' %in% args
  publication_date <- Sys.Date()
  for (i in seq_along(args)) {
    if (args[i] == '--date' && i < length(args)) {
      publication_date <- as.Date(args[i + 1])
    }
  }

  publish_git(
    publication_date = publication_date,
    build_flags = list(manual = TRUE),
    build_started_at = NULL,  # skip staleness guard for standalone runs
    dry_run = dry_run
  )
}
