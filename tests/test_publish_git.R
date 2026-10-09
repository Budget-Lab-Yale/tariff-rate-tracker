# =============================================================================
# publish_git (release/) failure-safety — unit tests
# =============================================================================
#
# Fixture-based checks for src/io/publish_git.R: a failed publication must leave
# the previous release/ (data files + MANIFEST.json) byte-for-byte intact, and a
# successful one must replace data and manifest consistently. Uses tiny synthetic
# CSVs in temp dirs — no model data, no build, runs in seconds.
#
# Failures are injected by replacing the module's internal helpers
# (write_release_file, write_release_manifest, capture_pkg_versions,
# move_release_file) for the duration of one call.
#
# Usage:
#   Rscript tests/test_publish_git.R
#
# To run the same suite against another implementation (e.g. the pre-fix
# publisher, to see the failure reproduce):
#   git show <rev>:src/io/publish_git.R > /tmp/old_publish_git.R
#   PUBLISH_GIT_SOURCE=/tmp/old_publish_git.R Rscript tests/test_publish_git.R
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(digest)
  library(jsonlite)
})

source(Sys.getenv('PUBLISH_GIT_SOURCE', unset = here('src', 'io', 'publish_git.R')))

fail_count <- 0L
pass_count <- 0L
check <- function(cond, msg) {
  if (isTRUE(cond)) {
    pass_count <<- pass_count + 1L
    cat('  ok:', msg, '\n')
  } else {
    fail_count <<- fail_count + 1L
    cat('  FAIL:', msg, '\n')
  }
}

# --- fixtures ----------------------------------------------------------------

PUB_DATE <- as.Date('2026-05-21')
src_files <- vapply(RELEASE_OUTPUTS, function(o) o$src, character(1))
out_names <- vapply(RELEASE_OUTPUTS, function(o) o$name, character(1))
new_data_names <- paste0(out_names, '_2026-05-21.csv')

make_repo_root <- function(tag) {
  root <- file.path(tempfile('publish_git_root_'))
  for (src in src_files) {
    p <- file.path(root, src)
    dir.create(dirname(p), recursive = TRUE, showWarnings = FALSE)
    writeLines(c('date,value', paste0('2026-01-01,', tag), paste0('2026-01-02,', tag)), p)
  }
  root
}

make_release_dir <- function() {
  rel <- file.path(tempfile('publish_git_release_'))
  dir.create(file.path(rel, 'data'), recursive = TRUE)
  writeLines('keep me', file.path(rel, 'README.md'))
  file.create(file.path(rel, 'data', '.gitkeep'))
  writeLines('old,1', file.path(rel, 'data', 'daily_overall_2026-05-01.csv'))
  writeLines('old,2', file.path(rel, 'data', 'daily_by_country_2026-05-01.csv'))
  writeLines('{"publication_date": "2026-05-01", "files": []}', file.path(rel, 'MANIFEST.json'))
  rel
}

# Relative path -> sha256 ('<dir>' for directories) for everything under dir,
# including dotfiles and any leftover staging/backup directories.
tree_state <- function(dir) {
  paths <- list.files(dir, recursive = TRUE, all.files = TRUE, include.dirs = TRUE, no.. = TRUE)
  vals <- vapply(paths, function(p) {
    full <- file.path(dir, p)
    if (dir.exists(full)) '<dir>' else digest(file = full, algo = 'sha256')
  }, character(1))
  vals[order(names(vals))]
}

# Replace a module-level function for the duration of expr.
with_override <- function(name, fn, expr) {
  had <- exists(name, envir = globalenv(), inherits = FALSE)
  orig <- if (had) get(name, envir = globalenv()) else NULL
  assign(name, fn, envir = globalenv())
  on.exit(if (had) assign(name, orig, envir = globalenv())
          else rm(list = name, envir = globalenv()), add = TRUE)
  force(expr)
}

run_publish <- function(rel, root, ...) {
  tryCatch({
    suppressMessages(publish_git(release_dir = rel, repo_root = root,
                                 publication_date = PUB_DATE,
                                 build_started_at = NULL, ...))
    NULL
  }, error = function(e) e)
}

# write_release_file that succeeds on call 1 and errors on call 2.
orig_write_release_file <- write_release_file
fail_second_write <- local({
  n <- 0L
  function(src_path, dest_path, format) {
    n <<- n + 1L
    if (n == 2L) stop('injected write failure on file 2')
    orig_write_release_file(src_path, dest_path, format)
  }
})
reset_second_write <- function() {
  environment(fail_second_write)$n <- 0L
}

orig_move <- if (exists('move_release_file')) move_release_file else NULL

cat('\n=== A/B: failure while writing the 2nd release file ===\n')
root <- make_repo_root('new'); rel <- make_release_dir()
before <- tree_state(rel)
reset_second_write()
err <- with_override('write_release_file', fail_second_write, run_publish(rel, root))
after <- tree_state(rel)
check(inherits(err, 'error'), 'publish_git errors when a release file write fails')
check(identical(before, after),
      'release/ (data, MANIFEST.json, README, .gitkeep, no leftovers) is byte-for-byte unchanged')
check(file.exists(file.path(rel, 'data', 'daily_overall_2026-05-01.csv')),
      'previous data files survive the failure')

cat('\n=== B2: staged bytes change after checksumming (partial/corrupt write) ===\n')
root <- make_repo_root('new'); rel <- make_release_dir()
before <- tree_state(rel)
orig_manifest_writer <- if (exists('write_release_manifest')) write_release_manifest else function(manifest, path) NULL
err <- with_override('write_release_manifest', function(manifest, path) {
  orig_manifest_writer(manifest, path)
  victim <- list.files(file.path(dirname(path), 'data'), full.names = TRUE)[1]
  cat('corrupt', file = victim, append = TRUE)
}, run_publish(rel, root))
check(inherits(err, 'error') && grepl('mismatch', conditionMessage(err)),
      'staged file that no longer matches the candidate manifest fails validation')
check(identical(before, tree_state(rel)),
      'release/ unchanged after a staged-content validation failure')

cat('\n=== B3: a failed copy is an error, not a silent success ===\n')
dest_missing_dir <- file.path(tempfile('no_such_dir_'), 'out.csv')
src_csv <- file.path(make_repo_root('x'), src_files[1])
err <- tryCatch({ suppressWarnings(write_release_file(src_csv, dest_missing_dir, 'csv')); NULL },
                error = function(e) e)
check(inherits(err, 'error'), 'write_release_file errors when the destination cannot be written')

cat('\n=== C: failure while building the candidate manifest ===\n')
root <- make_repo_root('new'); rel <- make_release_dir()
before <- tree_state(rel)
err <- with_override('capture_pkg_versions', function() stop('injected manifest-build failure'),
                     run_publish(rel, root))
check(inherits(err, 'error'), 'publish_git errors when manifest construction fails')
check(identical(before, tree_state(rel)), 'release/ unchanged after manifest-build failure')

root <- make_repo_root('new'); rel <- make_release_dir()
before <- tree_state(rel)
err <- with_override('write_release_manifest', function(manifest, path) stop('injected manifest-write failure'),
                     run_publish(rel, root))
check(inherits(err, 'error'), 'publish_git errors when the manifest write fails')
check(identical(before, tree_state(rel)), 'release/ unchanged after manifest-write failure')

cat('\n=== D: failure during promotion (rollback) ===\n')
if (is.null(orig_move)) {
  cat('  SKIP: no move_release_file in this implementation\n')
} else {
  # D1: the final step (staged manifest -> live) fails after the data
  # directory has already been swapped.
  root <- make_repo_root('new'); rel <- make_release_dir()
  before <- tree_state(rel)
  err <- with_override('move_release_file', function(from, to) {
    if (basename(to) == 'MANIFEST.json' && grepl('[.]publish-stage-', from) && dirname(to) == rel) {
      stop('injected promotion failure at manifest')
    }
    orig_move(from, to)
  }, run_publish(rel, root))
  check(inherits(err, 'error'), 'publish_git errors when promotion fails')
  check(identical(before, tree_state(rel)),
        'previous publication (data + manifest) fully restored; staging/backup removed')

  # D2: failure while promoting a data file.
  root <- make_repo_root('new'); rel <- make_release_dir()
  before <- tree_state(rel)
  err <- with_override('move_release_file', function(from, to) {
    if (grepl('daily_by_authority_2026-05-21', to, fixed = TRUE)) stop('injected promotion failure at data file')
    orig_move(from, to)
  }, run_publish(rel, root))
  check(inherits(err, 'error'), 'publish_git errors when a data file cannot be promoted')
  check(identical(before, tree_state(rel)), 'previous publication restored after data-file promotion failure')

  # D3: promotion fails AND rollback fails -> explicit error, backup preserved.
  root <- make_repo_root('new'); rel <- make_release_dir()
  err <- with_override('move_release_file', function(from, to) {
    if (basename(to) == 'MANIFEST.json' && grepl('[.]publish-stage-', from) && dirname(to) == rel) {
      stop('injected promotion failure at manifest')
    }
    # Rollback restores the old data files out of the backup dir; fail those.
    if (dirname(to) == file.path(rel, 'data') && grepl('daily_overall_2026-05-01', to, fixed = TRUE)) {
      stop('injected rollback failure')
    }
    orig_move(from, to)
  }, run_publish(rel, root))
  check(inherits(err, 'error') && grepl('rollback', conditionMessage(err), ignore.case = TRUE),
        'rollback failure is surfaced as an explicit error')
  leftovers <- list.files(rel, pattern = '^[.]publish-', all.files = TRUE, full.names = TRUE)
  check(length(leftovers) > 0, 'backup/staging directories are preserved for manual recovery')
  check(any(grepl('daily_overall_2026-05-01.csv$',
                  list.files(rel, recursive = TRUE, all.files = TRUE))),
        'the previous file that could not be restored is still on disk in the backup')
}

cat('\n=== E: successful publication ===\n')
root <- make_repo_root('new'); rel <- make_release_dir()
res <- suppressMessages(publish_git(release_dir = rel, repo_root = root,
                                    publication_date = PUB_DATE, build_started_at = NULL,
                                    build_flags = list(manual = TRUE)))
data_now <- sort(list.files(file.path(rel, 'data'), all.files = TRUE, no.. = TRUE))
check(identical(data_now, sort(c('.gitkeep', new_data_names))),
      'data/ holds exactly the new publication (+ .gitkeep); old files are gone')
mani <- fromJSON(file.path(rel, 'MANIFEST.json'), simplifyVector = FALSE)
check(identical(mani$publication_date, '2026-05-21'), 'manifest is the new one')
check(length(mani$files) == length(RELEASE_OUTPUTS), 'manifest lists every release output')
sha_ok <- vapply(mani$files, function(f) {
  p <- file.path(rel, f$path)
  file.exists(p) && identical(digest(file = p, algo = 'sha256'), f$sha256) &&
    identical(as.integer(file.info(p)$size), as.integer(f$size_bytes))
}, logical(1))
check(all(sha_ok), 'every manifest sha256 and size_bytes matches the published file')
check(identical(sort(basename(vapply(mani$files, function(f) f$path, character(1)))),
                sort(new_data_names)),
      'manifest paths match published filenames')
check(identical(unname(readLines(file.path(rel, 'README.md'))), 'keep me'), 'README.md preserved')
check(file.exists(file.path(rel, 'data', '.gitkeep')), '.gitkeep preserved')
check(length(list.files(rel, pattern = '^[.]publish-', all.files = TRUE)) == 0,
      'no staging/backup directories left behind')
check(identical(res$n_files, length(RELEASE_OUTPUTS)), 'return value unchanged (n_files)')

cat('\n=== E2: re-publish over a prior new-style publication ===\n')
root2 <- make_repo_root('newer')
res2 <- suppressMessages(publish_git(release_dir = rel, repo_root = root2,
                                     publication_date = as.Date('2026-05-22'),
                                     build_started_at = NULL))
data_now <- sort(list.files(file.path(rel, 'data'), all.files = TRUE, no.. = TRUE))
check(identical(data_now, sort(c('.gitkeep', sub('2026-05-21', '2026-05-22', new_data_names)))),
      'second publication replaces the first')

cat('\n=== F: dry run ===\n')
root <- make_repo_root('new'); rel <- make_release_dir()
before <- tree_state(rel)
res <- suppressMessages(publish_git(release_dir = rel, repo_root = root,
                                    publication_date = PUB_DATE, build_started_at = NULL,
                                    dry_run = TRUE))
check(identical(before, tree_state(rel)), 'dry run leaves release/ untouched')

cat('\n=== G: input validation ===\n')
root <- make_repo_root('new'); rel <- make_release_dir()
invisible(file.remove(file.path(root, src_files[3])))
before <- tree_state(rel)
err <- run_publish(rel, root)
check(inherits(err, 'error') && grepl('missing', conditionMessage(err)), 'missing source -> error')
check(identical(before, tree_state(rel)), 'release/ unchanged after missing-source error')

root <- make_repo_root('new'); rel <- make_release_dir()
before <- tree_state(rel)
err <- tryCatch({
  suppressMessages(publish_git(release_dir = rel, repo_root = root,
                               publication_date = PUB_DATE,
                               build_started_at = Sys.time() + 3600))
  NULL
}, error = function(e) e)
check(inherits(err, 'error') && grepl('stale', conditionMessage(err)), 'stale source -> error')
check(identical(before, tree_state(rel)), 'release/ unchanged after stale-source error')

cat('\n=== H: first publication into an empty release dir ===\n')
root <- make_repo_root('new')
rel <- file.path(tempfile('publish_git_empty_'))
res <- suppressMessages(publish_git(release_dir = rel, repo_root = root,
                                    publication_date = PUB_DATE, build_started_at = NULL))
check(file.exists(file.path(rel, 'MANIFEST.json')) &&
        all(file.exists(file.path(rel, 'data', new_data_names))),
      'publishes into a release dir that does not exist yet')

cat('\n', pass_count, ' passed, ', fail_count, ' failed\n', sep = '')
if (fail_count > 0L) quit(status = 1L)
cat('All publish_git tests passed.\n')
