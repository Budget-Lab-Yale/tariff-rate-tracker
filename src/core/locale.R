# =============================================================================
# UTF-8 locale guard
# =============================================================================
#
# Repository code and config carry non-ASCII text (accented country names such
# as Cote d'Ivoire with the accented o, em dashes, section signs). Under a
# non-UTF-8 locale -- LC_ALL=C is the default in many cron, container, and
# headless environments -- base R translates file contents to the native
# encoding as it reads them: string constants degrade to "<U+00F4>" escapes
# (so accented country aliases stop matching) and readLines() truncates config
# lines at the first byte it cannot represent, both with only a warning.
# Rather than continue partially and silently, entrypoints call
# ensure_utf8_locale() before sourcing pipeline code: it switches to a UTF-8
# locale when one is available and stops with instructions when none is.

ensure_utf8_locale <- function(candidates = c('en_US.UTF-8', 'C.UTF-8',
                                              'en_US.utf8', 'UTF-8')) {
  if (isTRUE(l10n_info()[['UTF-8']])) return(invisible(TRUE))
  previous <- Sys.getlocale('LC_CTYPE')
  for (candidate in candidates) {
    switched <- tryCatch(
      suppressWarnings(Sys.setlocale('LC_ALL', candidate)),
      error = function(e) ''
    )
    if (nzchar(switched) && isTRUE(l10n_info()[['UTF-8']])) {
      # Export so child processes inherit the fix: a child parses its own
      # script file before any in-process guard can run, so accented literals
      # in spawned scripts are only safe if the environment is already UTF-8.
      Sys.setenv(LC_ALL = candidate, LANG = candidate)
      message(sprintf(
        'Locale "%s" is not UTF-8; switched to "%s" for this session.',
        previous, candidate))
      return(invisible(TRUE))
    }
  }
  stop(sprintf(paste0(
    'A UTF-8 locale is required, but the current locale ("%s") is not UTF-8 ',
    'and none of the fallbacks (%s) are available. Set one before running, ',
    'e.g.: export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8'),
    previous, paste(candidates, collapse = ', ')), call. = FALSE)
}
