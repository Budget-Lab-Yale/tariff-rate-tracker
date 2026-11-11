# =============================================================================
# UTF-8 locale guard (src/core/locale.R)
# =============================================================================
#
# Under LC_ALL=C (common in cron/container/headless environments), base R
# degrades accented string constants at parse time and truncates config reads,
# both with only a warning. The guard switches to a UTF-8 locale at entrypoint
# startup, or fails loud when none is available. Subprocess cases spawn a fresh
# Rscript with LC_ALL=C because the parent test session is already UTF-8.

suppressPackageStartupMessages(library(here))
source(here('src', 'core', 'module_loader.R'))

pass <- 0L
fail <- 0L
ok <- function(condition, message) {
  if (isTRUE(condition)) {
    pass <<- pass + 1L
    cat('  PASS: ', message, '\n', sep = '')
  } else {
    fail <<- fail + 1L
    cat('  FAIL: ', message, '\n', sep = '')
  }
}

rscript_with_c_locale <- function(code) {
  rscript <- file.path(R.home('bin'), 'Rscript')
  out <- tryCatch(
    suppressWarnings(system2(rscript, c('-e', shQuote(code)),
                             stdout = TRUE, stderr = TRUE,
                             env = c('LC_ALL=C', 'LANG=C'))),
    error = function(e) sprintf('SYSTEM2-ERROR: %s', conditionMessage(e))
  )
  paste(out, collapse = '\n')
}

cat('\n== module registration ==\n')
target <- new.env(parent = globalenv())
tariff_load_module('locale', target)
ok(exists('ensure_utf8_locale', envir = target, mode = 'function',
          inherits = FALSE),
   'locale module resolves ensure_utf8_locale()')

cat('\n== no-op in a UTF-8 session ==\n')
if (isTRUE(l10n_info()[['UTF-8']])) {
  before <- Sys.getlocale('LC_CTYPE')
  result <- get('ensure_utf8_locale', envir = target)()
  ok(isTRUE(result), 'returns TRUE when the locale is already UTF-8')
  ok(identical(Sys.getlocale('LC_CTYPE'), before),
     'leaves an already-UTF-8 locale untouched')
} else {
  cat('  SKIP: test session is not UTF-8\n')
}

if (.Platform$OS.type != 'unix') {
  cat('\n== C-locale subprocess cases ==\n')
  cat('  SKIP: subprocess env override is unix-only ',
      '(Windows R >= 4.2 is UTF-8 native)\n', sep = '')
} else {
  cat('\n== C locale reproduces the hazard (harness sanity) ==\n')
  out <- rscript_with_c_locale('cat(isTRUE(l10n_info()[["UTF-8"]]))')
  ok(grepl('FALSE', out, fixed = TRUE),
     'LC_ALL=C subprocess starts in a non-UTF-8 locale')

  probe <- rscript_with_c_locale(paste0(
    'ok <- FALSE;',
    'for (l in c("en_US.UTF-8", "C.UTF-8", "en_US.utf8", "UTF-8")) {',
    '  s <- tryCatch(suppressWarnings(Sys.setlocale("LC_ALL", l)),',
    '                error = function(e) "");',
    '  if (nzchar(s) && isTRUE(l10n_info()[["UTF-8"]])) { ok <- TRUE; break }',
    '};',
    'cat(ok)'))
  host_has_utf8 <- grepl('TRUE', probe, fixed = TRUE)

  if (!host_has_utf8) {
    cat('  SKIP: host offers no UTF-8 locale; ',
        'cannot exercise the switch path\n', sep = '')
  } else {
    cat('\n== guard switches and preserves accented names ==\n')
    guarded <- rscript_with_c_locale(paste0(
      'source(file.path(', shQuote(here()), ', "src", "core", "locale.R"));',
      'suppressMessages(ensure_utf8_locale());',
      'cat(isTRUE(l10n_info()[["UTF-8"]]), nchar("c\\u00f4te d\'ivoire"),',
      '    grepl("UTF-8|utf8", Sys.getenv("LC_ALL")))'))
    ok(grepl('TRUE', guarded, fixed = TRUE),
       'ensure_utf8_locale() reaches a UTF-8 locale from LC_ALL=C')
    ok(grepl('13', guarded, fixed = TRUE),
       "accented country literal survives at 13 characters under the guard")
    ok(grepl('13 TRUE', guarded, fixed = TRUE),
       'switch exports a UTF-8 LC_ALL for child processes to inherit')
  }
}

cat('\n== SUMMARY: ', pass, ' passed, ', fail, ' failed ==\n', sep = '')
if (fail > 0) quit(status = 1L)
