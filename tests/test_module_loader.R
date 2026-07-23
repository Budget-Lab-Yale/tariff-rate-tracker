# =============================================================================
# Internal module loader contract
# =============================================================================

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

cat('\n== manifest ==\n')
all_dependencies <- unique(unlist(lapply(TARIFF_MODULES, `[[`, 'depends')))
ok(all(all_dependencies %in% names(TARIFF_MODULES)),
   'every dependency names a registered module')
all_files <- vapply(TARIFF_MODULES, `[[`, character(1), 'file')
ok(all(file.exists(here(all_files))), 'every registered module file exists')
ok(!anyDuplicated(all_files), 'each production file has one module identity')
production_files <- list.files(here('src'), pattern = '[.]R$', recursive = TRUE,
                               full.names = FALSE)
production_files <- file.path('src', production_files)
entrypoints <- c('src/core/module_loader.R', 'src/pipeline/00_build_timeseries.R',
                 'src/preflight.R', 'src/experimental/load_adcvd_layer.R')
unregistered <- setdiff(production_files, c(all_files, entrypoints))
ok(length(unregistered) == 0,
   paste('every reusable src file is registered',
         if (length(unregistered)) paste(':', paste(unregistered, collapse = ', ')) else ''))

cat('\n== clean-environment load ==\n')
target <- new.env(parent = globalenv())
tariff_load_bundle('daily', target)
required <- c('load_policy_params', 'build_authority_specs',
              'calculate_rates_for_revision', 'build_revision_snapshot',
              'build_alternative_timeseries')
ok(all(vapply(required, exists, logical(1), envir = target,
              mode = 'function', inherits = FALSE)),
   'daily bundle resolves all required functions in a clean environment')
loaded_once <- tariff_loaded_modules(target)
tariff_load_bundle('daily', target)
ok(identical(loaded_once, tariff_loaded_modules(target)),
   'loading a bundle twice is idempotent')

publish_target <- new.env(parent = globalenv())
tariff_load_bundle('publishing', publish_target)
ok(all(vapply(c('check_schema', 'write_build_output', 'publish_git'), exists,
              logical(1), envir = publish_target, mode = 'function',
              inherits = FALSE)),
   'publishing bundle resolves reporting and publication functions')

cat('\n== fail loud ==\n')
unknown <- tryCatch({ tariff_load_module('not_a_module', target); NULL },
                    error = identity)
ok(!is.null(unknown) && grepl('Unknown tariff module', conditionMessage(unknown)),
   'unknown module name fails loud')

cat('\n== SUMMARY: ', pass, ' passed, ', fail, ' failed ==\n', sep = '')
if (fail > 0) quit(status = 1L)
