# =============================================================================
# Internal module loader — explicit dependency graph for repository R code
# =============================================================================
#
# This repository is an executable analysis project rather than an installable R
# package. This manifest provides the package-like property we need internally:
# callers request a module or bundle, dependencies are resolved deterministically,
# and each file is sourced at most once into the target environment.

TARIFF_MODULES <- list(
  csv_cache = list(
    file = 'src/core/csv_cache.R',
    depends = character()
  ),
  policy_params = list(
    file = 'src/model/policy_params.R',
    depends = character()
  ),
  revisions = list(
    file = 'src/model/revisions.R',
    depends = character()
  ),
  authority_registry = list(
    file = 'src/model/authority_registry.R',
    depends = character()
  ),
  stacking = list(
    file = 'src/model/stacking.R',
    depends = 'authority_registry'
  ),
  timeline = list(
    file = 'src/model/timeline.R',
    depends = character()
  ),
  rate_schema = list(
    file = 'src/model/rate_schema.R',
    depends = 'authority_registry'
  ),
  scenario_inputs = list(
    file = 'src/model/scenario_inputs.R',
    depends = 'rate_schema'
  ),
  data_loaders = list(
    file = 'src/model/data_loaders.R',
    depends = 'policy_params'
  ),
  output_paths = list(
    file = 'src/io/output_paths.R',
    depends = character()
  ),
  scenario_registry = list(
    file = 'src/model/scenario_registry.R',
    depends = 'policy_params'
  ),
  helpers = list(
    file = 'src/core/helpers.R',
    depends = c('csv_cache', 'policy_params', 'revisions', 'authority_registry',
                'stacking', 'timeline', 'rate_schema', 'scenario_inputs',
                'data_loaders', 'output_paths', 'scenario_registry')
  ),
  logging = list(
    file = 'src/core/logging.R',
    depends = character()
  ),
  parallel = list(
    file = 'src/core/parallel.R',
    depends = c('logging', 'helpers')
  ),
  build_config = list(
    file = 'src/core/build_config.R',
    depends = character()
  ),
  parity = list(
    file = 'src/core/parity.R',
    depends = character()
  ),
  scrape_revision_dates = list(
    file = 'src/pipeline/01_scrape_revision_dates.R',
    depends = 'helpers'
  ),
  download_hts = list(
    file = 'src/pipeline/02_download_hts.R',
    depends = 'helpers'
  ),
  parse_chapter99 = list(
    file = 'src/pipeline/03_parse_chapter99.R',
    depends = 'helpers'
  ),
  parse_products = list(
    file = 'src/pipeline/04_parse_products.R',
    depends = 'helpers'
  ),
  parse_policy_params = list(
    file = 'src/pipeline/05_parse_policy_params.R',
    depends = c('helpers', 'parse_products')
  ),
  authority_spec = list(
    file = 'src/model/authority_spec.R',
    depends = character()
  ),
  authority_adapter = list(
    file = 'src/model/authority_adapter.R',
    depends = c('authority_spec', 'csv_cache', 'policy_params',
                'parse_chapter99', 'parse_policy_params')
  ),
  calculate_rates = list(
    file = 'src/pipeline/06_calculate_rates.R',
    depends = c('helpers', 'authority_spec', 'stacking')
  ),
  revision_snapshot = list(
    file = 'src/pipeline/revision_snapshot.R',
    depends = c('parse_chapter99', 'parse_products', 'parse_policy_params',
                'authority_adapter', 'calculate_rates')
  ),
  daily_series = list(
    file = 'src/pipeline/09_daily_series.R',
    depends = c('revision_snapshot', 'parallel')
  ),
  dataweb_parser = list(
    file = 'src/io/dataweb_parser.R',
    depends = 'helpers'
  ),
  build_import_weights = list(
    file = 'src/io/build_import_weights.R',
    depends = character()
  ),
  build_panel_import_weights = list(
    file = 'src/io/build_panel_import_weights.R',
    depends = c('output_paths', 'policy_params')
  ),
  publish_git = list(
    file = 'src/io/publish_git.R',
    depends = 'output_paths'
  ),
  quality_report = list(
    file = 'src/io/quality_report.R',
    depends = 'helpers'
  ),
  write_output = list(
    file = 'src/io/write_output.R',
    depends = c('output_paths', 'rate_schema', 'revisions', 'policy_params',
                'build_panel_import_weights')
  )
)

TARIFF_MODULE_BUNDLES <- list(
  core = 'helpers',
  calculation = 'revision_snapshot',
  daily = 'daily_series',
  publishing = c('quality_report', 'write_output', 'publish_git'),
  build = c('logging', 'parallel', 'scrape_revision_dates', 'download_hts',
            'revision_snapshot')
)

.tariff_module_state <- function(envir) {
  key <- '.tariff_module_load_state'
  if (!exists(key, envir = envir, inherits = FALSE)) {
    assign(key, new.env(parent = emptyenv()), envir = envir)
  }
  get(key, envir = envir, inherits = FALSE)
}

tariff_module_dependencies <- function(module) {
  spec <- TARIFF_MODULES[[module]]
  if (is.null(spec)) stop('Unknown tariff module: ', module, call. = FALSE)
  spec$depends
}

tariff_load_module <- function(module, envir = parent.frame()) {
  if (length(module) != 1 || is.na(module) || !nzchar(module)) {
    stop('tariff_load_module() requires one non-empty module name.', call. = FALSE)
  }
  spec <- TARIFF_MODULES[[module]]
  if (is.null(spec)) stop('Unknown tariff module: ', module, call. = FALSE)
  state <- .tariff_module_state(envir)
  status <- if (exists(module, envir = state, inherits = FALSE)) {
    get(module, envir = state, inherits = FALSE)
  } else NULL
  if (identical(status, 'loaded')) return(invisible(FALSE))
  if (identical(status, 'loading')) {
    stop('Internal module dependency cycle while loading: ', module,
         call. = FALSE)
  }

  assign(module, 'loading', envir = state)
  tryCatch({
    for (dependency in spec$depends) tariff_load_module(dependency, envir)
    sys.source(here::here(spec$file), envir = envir)
    assign(module, 'loaded', envir = state)
  }, error = function(e) {
    if (exists(module, envir = state, inherits = FALSE)) {
      rm(list = module, envir = state)
    }
    stop(e)
  })
  invisible(TRUE)
}

tariff_load_dependencies <- function(module, envir = parent.frame()) {
  for (dependency in tariff_module_dependencies(module)) {
    tariff_load_module(dependency, envir)
  }
  invisible(TRUE)
}

tariff_mark_module_loaded <- function(module, envir = parent.frame()) {
  if (is.null(TARIFF_MODULES[[module]])) {
    stop('Unknown tariff module: ', module, call. = FALSE)
  }
  assign(module, 'loaded', envir = .tariff_module_state(envir))
  invisible(TRUE)
}

tariff_load_bundle <- function(bundle, envir = parent.frame()) {
  modules <- TARIFF_MODULE_BUNDLES[[bundle]]
  if (is.null(modules)) stop('Unknown tariff module bundle: ', bundle, call. = FALSE)
  for (module in modules) tariff_load_module(module, envir)
  invisible(TRUE)
}

tariff_loaded_modules <- function(envir = parent.frame()) {
  state <- .tariff_module_state(envir)
  loaded <- ls(state, all.names = TRUE)
  sort(loaded[vapply(loaded, function(x) identical(get(x, state), 'loaded'), logical(1))])
}
