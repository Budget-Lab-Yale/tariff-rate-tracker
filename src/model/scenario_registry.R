# =============================================================================
# Scenario registry — one declarative home for every non-baseline series
# =============================================================================
#
# Every non-baseline series is a folder under config/scenarios/<name>/ with:
#
#   meta.yaml      kind: alternative | counterfactual | scenario | baseline
#                  description: one line
#                  publish: true|false   (read by the publish layer; default false)
#                  extends: parent_name  (optional; inherit parent's overlay)
#   overlay.yaml   the config diff vs baseline, deep-merged at load time by
#                  load_policy_params(scenario = name) (src/model/policy_params.R).
#                  Counterfactuals typically set ONLY `disabled_authorities:`.
#
# Kind semantics:
#   alternative     methodology/calibration variant (USMCA share modes, flat
#                   metal content, ...). Run by the alternatives runner
#                   (run_alternative_series -> alt_runner): full per-revision
#                   recalc, daily aggregates to output/scenarios/<name>/.
#   counterfactual  policy what-if expressed by removing authority inputs
#                   (disabled_authorities) or other overlay keys. Same runner.
#   scenario        a full named series (forced_labor, new_301) built with the
#                   main build under TARIFF_SCENARIO — persisted
#                   snapshots, quality reports, publishable. NOT dispatched by
#                   the alternatives runner.
#   baseline        config/scenarios/actual — documentation stub, never run.
#
# Sourced via helpers.R. No side effects at source time.

#' List all registered scenarios
#'
#' Reads config/scenarios/*/meta.yaml. A folder without meta.yaml is an error
#' (fail loud — an unregistered scenario is invisible to the runner and would
#' rot).
#'
#' @param scenarios_dir Root directory (default config/scenarios)
#' @return Tibble: name, kind, description, publish, has_overlay
list_scenarios <- function(scenarios_dir = here('config', 'scenarios')) {
  if (!dir.exists(scenarios_dir)) {
    stop('Scenario registry: directory not found: ', scenarios_dir)
  }
  dirs <- list.dirs(scenarios_dir, recursive = FALSE, full.names = TRUE)
  if (length(dirs) == 0) {
    stop('Scenario registry: no scenario folders under ', scenarios_dir)
  }

  rows <- map(dirs, function(d) {
    name <- basename(d)
    meta_path <- file.path(d, 'meta.yaml')
    overlay_path <- file.path(d, 'overlay.yaml')
    if (!file.exists(meta_path)) {
      stop('Scenario "', name, '" has no meta.yaml. Every folder under ',
           'config/scenarios/ must declare kind/description/publish — see ',
           'src/model/scenario_registry.R header.')
    }
    meta <- yaml::read_yaml(meta_path)
    known_meta_keys <- c('kind', 'description', 'publish', 'extends')
    unknown_meta_keys <- setdiff(names(meta), known_meta_keys)
    if (length(unknown_meta_keys)) {
      stop('Scenario "', name, '" meta.yaml has unknown key(s): ',
           paste(unknown_meta_keys, collapse = ', '))
    }
    kind <- meta$kind %||% NA_character_
    valid_kinds <- c('alternative', 'counterfactual', 'scenario', 'baseline')
    if (!kind %in% valid_kinds) {
      stop('Scenario "', name, '": meta.yaml kind must be one of ',
           paste(valid_kinds, collapse = ', '), ' (got: ',
           if (is.na(kind)) '<missing>' else kind, ')')
    }
    tibble(
      name = name,
      kind = kind,
      description = meta$description %||% '',
      publish = isTRUE(meta$publish),
      extends = as.character(meta$extends %||% NA_character_),
      has_overlay = file.exists(overlay_path)
    )
  })
  bind_rows(rows) %>% arrange(kind, name)
}


#' Expand an --alternatives selector into scenario names
#'
#' Selectors:
#'   'all'             every alternative + counterfactual
#'   'alternatives'    kind == alternative
#'   'counterfactuals' kind == counterfactual
#'   comma-list        explicit names (validated; kind must be runnable)
#'   NULL              empty
#'
#' Named 'scenario'-kind series (forced_labor, new_301) are NOT runnable here —
#' they build as full series via TARIFF_SCENARIO. Requesting one by name errors
#' with that pointer.
#'
#' @param selector Character scalar (comma-separated) or vector of names, or NULL
#' @param registry Optional pre-loaded list_scenarios() tibble
#' @return Character vector of scenario names (possibly empty)
resolve_alternatives_selector <- function(selector, registry = NULL) {
  if (is.null(selector) || length(selector) == 0) return(character(0))
  parts <- unlist(strsplit(as.character(selector), ',', fixed = TRUE))
  parts <- trimws(parts)
  parts <- parts[nzchar(parts)]
  if (length(parts) == 0) return(character(0))

  if (is.null(registry)) registry <- list_scenarios()
  runnable <- registry %>% filter(kind %in% c('alternative', 'counterfactual'))

  expand_one <- function(p) {
    switch(p,
      all              = runnable$name,
      alternatives     = registry$name[registry$kind == 'alternative'],
      counterfactuals  = registry$name[registry$kind == 'counterfactual'],
      p
    )
  }
  names <- unique(unlist(map(parts, expand_one)))

  unknown <- setdiff(names, registry$name)
  if (length(unknown) > 0) {
    stop('--alternatives: unknown scenario name(s): ',
         paste(unknown, collapse = ', '),
         '. Registered runnable scenarios: ',
         paste(runnable$name, collapse = ', '))
  }
  not_runnable <- setdiff(names, runnable$name)
  if (length(not_runnable) > 0) {
    stop('--alternatives: ', paste(not_runnable, collapse = ', '),
         ' is kind=scenario/baseline — full named series build via ',
         'TARIFF_SCENARIO=<name>, not the alternatives runner.')
  }
  names
}


#' Build alt-runner specs for a set of scenario names
#'
#' For each name, the pp_override is load_policy_params(scenario = name, ...):
#' the overlay deep-merge plus all convenience-field unpacking, so a spec is
#' EXACTLY the pp the main build would see under TARIFF_SCENARIO=<name>.
#'
#' @param names Character vector of scenario names (from resolve_alternatives_selector)
#' @param use_policy_dates Passed through to load_policy_params(); MUST match
#'   the main build's date mode so alternative panels share its timeline.
#' @return List of specs: list(variant, pp_override, kind, publish)
build_scenario_alt_specs <- function(names, use_policy_dates = TRUE) {
  if (length(names) == 0) return(list())
  registry <- list_scenarios()
  map(names, function(nm) {
    row <- registry %>% filter(name == nm)
    pp_override <- load_policy_params(scenario = nm,
                                      use_policy_dates = use_policy_dates)
    list(
      variant = nm,
      pp_override = pp_override,
      kind = row$kind,
      publish = row$publish
    )
  })
}
