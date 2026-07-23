# =============================================================================
# Policy Parameters — YAML config loader and country constants
# =============================================================================
# Split from helpers.R. Sourced by helpers.R for backward compatibility.
# Direct consumers can source this file alone.

library(tidyverse)
library(yaml)
library(here)

#' Recursively deep-merge an overlay onto a base (both parsed-YAML lists).
#'
#' The scenario harness (config/scenarios/<name>/overlay.yaml) supplies ONLY the
#' diff vs the baseline config; this merges it in. Merge rules (decision: overlay
#' folders, not full copies):
#'   * two MAPS (named lists) at the same key  -> recurse (deep merge)
#'   * anything else (scalar, sequence/unnamed list, type mismatch, new key)
#'     -> the overlay value REPLACES the base value wholesale.
#' So `scheduled_activations:` or a `tier_10pct:` list in an overlay replaces the
#' baseline's outright (no element-wise list merging), while a nested block like
#' `section_232: {steel: {...}}` merges field-by-field. An empty/NULL overlay is a
#' no-op, so an empty overlay == baseline (the `actual` invariant).
.is_yaml_map <- function(x) is.list(x) && !is.null(names(x)) && all(nzchar(names(x)))
.deep_merge_lists <- function(base, overlay) {
  if (!.is_yaml_map(base) || !.is_yaml_map(overlay)) return(overlay)
  out <- base
  for (k in names(overlay)) {
    if (k %in% names(base) && .is_yaml_map(base[[k]]) && .is_yaml_map(overlay[[k]])) {
      out[[k]] <- .deep_merge_lists(base[[k]], overlay[[k]])
    } else {
      out[[k]] <- overlay[[k]]
    }
  }
  out
}

# Scenario overlays are intentionally small, but two keys are scenario-only and
# therefore do not appear in the baseline policy file. Keep their schema here so
# validation remains fail-closed without mistaking legitimate scenario inputs
# for typos.
.scenario_overlay_extensions <- function() {
  list(
    disabled_authorities = character(),
    section_301_forced_labor = list(
      effective_date = '',
      rate_10 = 0,
      rate_12_5 = 0,
      exempt_products = '',
      tier_10pct = character(),
      tier_12_5pct = character()
    ),
    # Optional fields documented in policy_params.yaml but intentionally absent
    # from the active baseline configuration.
    usmca_shares = list(month = 0L),
    section_301_exclusions = list(line_coverage_file = '')
  )
}

#' Reject unknown keys in a scenario overlay
#'
#' Validation is recursive: a typo in a nested policy field is just as dangerous
#' as a typo at the top level. Sequences/scalars are leaves and are type-checked
#' later by their consumers.
.validate_scenario_overlay <- function(overlay, baseline, scenario = '<unknown>',
                                       path = character()) {
  if (is.null(overlay) || length(overlay) == 0) return(invisible(TRUE))
  if (!.is_yaml_map(overlay)) {
    stop('Scenario "', scenario, '": overlay must be a YAML map.', call. = FALSE)
  }

  schema <- if (length(path) == 0) {
    .deep_merge_lists(baseline, .scenario_overlay_extensions())
  } else baseline
  unknown <- setdiff(names(overlay), names(schema))
  if (length(unknown) > 0) {
    prefix <- if (length(path)) paste0(paste(path, collapse = '.'), '.') else ''
    stop('Scenario "', scenario, '" overlay has unknown key(s): ',
         paste0(prefix, unknown, collapse = ', '), call. = FALSE)
  }

  for (key in names(overlay)) {
    value <- overlay[[key]]
    expected <- schema[[key]]
    if (.is_yaml_map(value)) {
      if (!.is_yaml_map(expected)) {
        stop('Scenario "', scenario, '" overlay key ',
             paste(c(path, key), collapse = '.'),
             ' must not be a YAML map.', call. = FALSE)
      }
      .validate_scenario_overlay(value, expected, scenario, c(path, key))
    }
  }
  invisible(TRUE)
}

.read_scenario_meta <- function(scenario, scenarios_dir) {
  meta_path <- file.path(scenarios_dir, scenario, 'meta.yaml')
  if (!file.exists(meta_path)) {
    stop('Scenario "', scenario, '": metadata not found at ', meta_path,
         call. = FALSE)
  }
  meta <- read_yaml(meta_path)
  known <- c('kind', 'description', 'publish', 'extends')
  unknown <- setdiff(names(meta), known)
  if (length(unknown)) {
    stop('Scenario "', scenario, '" meta.yaml has unknown key(s): ',
         paste(unknown, collapse = ', '), call. = FALSE)
  }
  meta
}

# Resolve parent-first overlay composition. The returned overlay is still only
# a diff against baseline; validation occurs before each layer is merged.
.resolve_scenario_overlay <- function(scenario, baseline, scenarios_dir,
                                      ancestry = character()) {
  if (scenario %in% ancestry) {
    stop('Scenario inheritance cycle: ',
         paste(c(ancestry, scenario), collapse = ' -> '), call. = FALSE)
  }
  meta <- .read_scenario_meta(scenario, scenarios_dir)
  parent <- as.character(meta$extends %||% character())
  if (length(parent) > 1 || (length(parent) == 1 && !nzchar(parent))) {
    stop('Scenario "', scenario, '": meta.yaml extends must be one scenario name.',
         call. = FALSE)
  }
  resolved <- list()
  if (length(parent) == 1) {
    resolved <- .resolve_scenario_overlay(parent, baseline, scenarios_dir,
                                          c(ancestry, scenario))
  }

  overlay_path <- file.path(scenarios_dir, scenario, 'overlay.yaml')
  if (!file.exists(overlay_path)) {
    stop('Scenario "', scenario, '": overlay not found at ', overlay_path,
         call. = FALSE)
  }
  overlay <- read_yaml(overlay_path)
  if (!is.null(overlay) && length(overlay) > 0) {
    .validate_scenario_overlay(overlay, baseline, scenario)
    resolved <- .deep_merge_lists(resolved, overlay)
  }
  resolved
}

#' Load policy parameters from YAML config
#'
#' Returns a list with convenience fields unpacked for direct use.
#'
#' @param yaml_path Path to policy_params.yaml
#' @param use_policy_dates If TRUE (default), swap date-sensitive config fields
#'   (IEEPA invalidation, S122 effective/expiry) to their policy_effective_date
#'   equivalents. Set FALSE when using --use-hts-dates or for utilities that
#'   need raw HTS timing. See docs/policy_timing.md.
#' @param scenario Optional scenario name; its validated, parent-resolved overlay
#'   is merged onto the baseline.
#' @param scenarios_dir Scenario registry root (overridable for tests).
#' @return List with raw params plus convenience fields
load_policy_params <- function(yaml_path = NULL,
                               use_policy_dates = TRUE,
                               scenario = NULL,
                               scenarios_dir = here('config', 'scenarios')) {
  # TARIFF_POLICY_PARAMS overrides the config path so a fixture can build
  # against a config variant — e.g.
  # a populated section_301_content_split_codes — without editing the tracked
  # file. Unset (the production/gate path) => the canonical config => byte-identical.
  if (is.null(yaml_path)) {
    env_path <- Sys.getenv('TARIFF_POLICY_PARAMS', '')
    yaml_path <- if (nzchar(env_path)) env_path else here('config', 'policy_params.yaml')
  }
  if (!file.exists(yaml_path)) {
    stop('Policy params YAML not found: ', yaml_path)
  }

  params <- read_yaml(yaml_path)

  # --- Scenario overlay (the counterfactual harness) -------------------------
  # `scenario` (arg or TARIFF_SCENARIO env) names a folder under config/scenarios/.
  # Its overlay.yaml is deep-merged onto the baseline; the rest of the pipeline
  # then runs unchanged on the merged params. The baseline IS the "actual"
  # scenario: scenario unset / '' / 'actual' => no overlay => byte-identical.
  # See docs (scenario harness) + .deep_merge_lists() above.
  if (is.null(scenario)) scenario <- Sys.getenv('TARIFF_SCENARIO', '')
  scenario <- as.character(scenario)[1] %||% ''
  if (length(scenario) && !is.na(scenario) && nzchar(scenario) && scenario != 'actual') {
    overlay_path <- file.path(scenarios_dir, scenario, 'overlay.yaml')
    overlay <- .resolve_scenario_overlay(scenario, params, scenarios_dir)
    if (!is.null(overlay) && length(overlay) > 0) {
      params <- .deep_merge_lists(params, overlay)
      message('  Scenario "', scenario, '": resolved and merged overlay ', overlay_path)
    } else {
      message('  Scenario "', scenario, '": empty overlay (== baseline)')
    }
  }

  # Unpack convenience fields for country codes
  for (nm in names(params$country_codes)) {
    params[[nm]] <- params$country_codes[[nm]]
  }

  # ISO_TO_CENSUS as named character vector
  params$ISO_TO_CENSUS <- unlist(params$iso_to_census)

  # EU27_CODES as character vector, EU27_NAMES as named vector
  params$EU27_CODES <- names(params$eu27_codes)
  params$EU27_NAMES <- unlist(params$eu27_codes)
  names(params$EU27_NAMES) <- params$EU27_CODES

  # Section 232 chapters as flat vector
  params$SECTION_232_CHAPTERS <- unlist(params$section_232_chapters)

  # Section 301 rates as tibble
  if (!is.null(params$section_301_rates)) {
    params$SECTION_301_RATES <- tibble(
      ch99_pattern = map_chr(params$section_301_rates, 'ch99_pattern'),
      s301_rate = map_dbl(params$section_301_rates, 's301_rate')
    )
  }

  # Floor rates
  params$EU_FLOOR_RATE <- params$floor_rates$eu_floor
  params$FLOOR_RATE <- params$floor_rates$floor_rate
  params$FLOOR_COUNTRIES <- unlist(params$floor_rates$floor_countries)

  # Weighted ETR reporting config
  if (!is.null(params$weighted_etr)) {
    if (!is.null(params$weighted_etr$policy_dates)) {
      params$WEIGHTED_ETR_POLICY_DATES <- tibble(
        date = as.Date(map_chr(params$weighted_etr$policy_dates, 'date')),
        label = map_chr(params$weighted_etr$policy_dates, 'label')
      )
    }
    if (!is.null(params$weighted_etr$tpc_name_fixes)) {
      params$TPC_NAME_FIXES <- unlist(params$weighted_etr$tpc_name_fixes)
    }
  }

  # IEEPA invalidation date (SCOTUS ruling)
  if (!is.null(params$ieepa_invalidation_date)) {
    params$IEEPA_INVALIDATION_DATE <- as.Date(params$ieepa_invalidation_date)
  } else {
    params$IEEPA_INVALIDATION_DATE <- NULL
  }

  # Swiss/Liechtenstein framework (EO 14346)
  if (!is.null(params$swiss_framework)) {
    params$SWISS_FRAMEWORK <- list(
      effective_date = as.Date(params$swiss_framework$effective_date),
      expiry_date = as.Date(params$swiss_framework$expiry_date),
      finalized = isTRUE(params$swiss_framework$finalized),
      countries = unlist(params$swiss_framework$countries)
    )
  }

  # USMCA utilization shares (DataWeb SPI S/S+)
  params$USMCA_SHARES <- list(
    mode = params$usmca_shares$mode %||% 'annual',
    year = params$usmca_shares$year %||% NULL,
    month = params$usmca_shares$month %||% NULL,
    # 'since' mode: fixed left edge of the averaging window (open right edge).
    start_year = params$usmca_shares$start_year %||% NULL,
    start_month = params$usmca_shares$start_month %||% NULL
  )

  # MFN exemption shares (FTA/GSP preference utilization)
  if (!is.null(params$mfn_exemption)) {
    params$MFN_EXEMPTION <- list(
      method = params$mfn_exemption$method %||% 'none',
      exclude_usmca_countries = isTRUE(params$mfn_exemption$exclude_usmca_countries)
    )
  } else {
    params$MFN_EXEMPTION <- list(method = 'none', exclude_usmca_countries = TRUE)
  }

  # Section 232 country exemptions (TRQ/quota agreements)
  if (!is.null(params$section_232_country_exemptions)) {
    params$S232_COUNTRY_EXEMPTIONS <- map(params$section_232_country_exemptions, function(entry) {
      # Expand 'eu' mnemonic to EU27 codes
      raw_countries <- unlist(entry$countries)
      expanded <- if ('eu' %in% raw_countries) {
        c(setdiff(raw_countries, 'eu'), params$EU27_CODES)
      } else {
        raw_countries
      }
      list(
        countries = expanded,
        rate = entry$rate,
        applies_to = unlist(entry$applies_to),
        expiry_date = if (!is.null(entry$expiry_date)) as.Date(entry$expiry_date) else NULL
      )
    })
  } else {
    params$S232_COUNTRY_EXEMPTIONS <- list()
  }

  # Series horizon
  if (!is.null(params$series_horizon$end_date)) {
    params$SERIES_HORIZON_END <- as.Date(params$series_horizon$end_date)
  } else {
    params$SERIES_HORIZON_END <- Sys.Date()
  }

  # Boundary-mint overrides (unified timeline / P2-1): curated extra effective
  # dates fed to discover_boundaries() as a backstop. Empty in baseline.
  params$BOUNDARY_OVERRIDES <- if (!is.null(params$boundary_overrides) &&
                                   length(params$boundary_overrides) > 0) {
    as.Date(unlist(params$boundary_overrides))
  } else {
    as.Date(character())
  }

  # Section 122 (Trade Act §122, 150-day statutory limit)
  if (!is.null(params$section_122)) {
    params$SECTION_122 <- list(
      effective_date = as.Date(params$section_122$effective_date),
      expiry_date = as.Date(params$section_122$expiry_date),
      finalized = isTRUE(params$section_122$finalized)
    )
  }

  # Swap policy dates if requested (SCOTUS ruling + S122 coordination)
  if (use_policy_dates) {
    if (!is.null(params$ieepa_invalidation_policy_date)) {
      params$IEEPA_INVALIDATION_DATE <- as.Date(params$ieepa_invalidation_policy_date)
      message('  Policy dates: IEEPA invalidation -> ', params$IEEPA_INVALIDATION_DATE)
    }
    if (!is.null(params$section_122$policy_effective_date)) {
      params$SECTION_122$effective_date <- as.Date(params$section_122$policy_effective_date)
      message('  Policy dates: S122 effective -> ', params$SECTION_122$effective_date)
    }
    if (!is.null(params$section_122$policy_expiry_date)) {
      params$SECTION_122$expiry_date <- as.Date(params$section_122$policy_expiry_date)
      message('  Policy dates: S122 expiry -> ', params$SECTION_122$expiry_date)
    }
  }

  # Section 232 annexes (April 2026 proclamation)
  if (!is.null(params$section_232_annexes)) {
    params$S232_ANNEXES <- params$section_232_annexes
    params$S232_ANNEXES$effective_date <- as.Date(params$section_232_annexes$effective_date)
  }

  # Section 201 (Trade Act §201 safeguards). Currently models Solar 201:
  # the HTS lists out-of-quota rates that don't reflect annual step-down,
  # so we override with the published current rate.
  if (!is.null(params$section_201)) {
    params$SECTION_201 <- params$section_201
  }

  # Local paths (optional user-specific file locations)
  params$LOCAL_PATHS <- load_local_paths()

  return(params)
}


#' Load optional local paths configuration
#'
#' Reads config/local_paths.yaml if present. Returns a named list of paths,
#' with NULL for any unset entries. Never required for core build.
#'
#' @param yaml_path Path to local_paths.yaml
#' @return Named list with import_weights, split_share_imports, tpc_benchmark,
#'   tariff_etrs_repo, model_data_root, weight_mode, weight_method
get_country_constants <- function(pp = NULL) {
  if (is.null(pp)) pp <- tryCatch(load_policy_params(), error = function(e) NULL)
  list(
    CTY_CHINA  = if (!is.null(pp)) pp$CTY_CHINA  else '5700',
    CTY_CANADA = if (!is.null(pp)) pp$CTY_CANADA else '1220',
    CTY_MEXICO = if (!is.null(pp)) pp$CTY_MEXICO else '2010',
    CTY_JAPAN  = if (!is.null(pp)) pp$CTY_JAPAN  else '5880',
    CTY_UK     = if (!is.null(pp)) pp$CTY_UK     else '4120',
    CTY_HK     = if (!is.null(pp)) pp$CTY_HK     else '5820',
    EU27_CODES = if (!is.null(pp)) pp$EU27_CODES else c(
      '4330', '4231', '4870', '4791', '4910', '4351', '4099', '4470', '4050',
      '4279', '4280', '4840', '4370', '4190', '4759', '4490', '4510', '4239',
      '4730', '4210', '4550', '4710', '4850', '4359', '4792', '4700', '4010'
    ),
    EU27_NAMES = if (!is.null(pp)) pp$EU27_NAMES else c(
      '4330' = 'Austria', '4231' = 'Belgium', '4870' = 'Bulgaria',
      '4791' = 'Croatia', '4910' = 'Cyprus', '4351' = 'Czech Republic',
      '4099' = 'Denmark', '4470' = 'Estonia', '4050' = 'Finland',
      '4279' = 'France', '4280' = 'Germany', '4840' = 'Greece',
      '4370' = 'Hungary', '4190' = 'Ireland', '4759' = 'Italy',
      '4490' = 'Latvia', '4510' = 'Lithuania', '4239' = 'Luxembourg',
      '4730' = 'Malta', '4210' = 'Netherlands', '4550' = 'Poland',
      '4710' = 'Portugal', '4850' = 'Romania', '4359' = 'Slovakia',
      '4792' = 'Slovenia', '4700' = 'Spain', '4010' = 'Sweden'
    ),
    ISO_TO_CENSUS = if (!is.null(pp)) pp$ISO_TO_CENSUS else c(
      'CN' = '5700', 'CA' = '1220', 'MX' = '2010',
      'JP' = '5880', 'UK' = '4120', 'GB' = '4120',
      'AU' = '6021', 'KR' = '5800', 'RU' = '4621',
      'AR' = '3570', 'BR' = '3510', 'UA' = '4623'
    ),
    STEEL_CHAPTERS = if (!is.null(pp)) pp$section_232_chapters$steel else c('72', '73'),
    ALUM_CHAPTERS  = if (!is.null(pp)) pp$section_232_chapters$aluminum else c('76'),
    COPPER_CHAPTERS = if (!is.null(pp)) pp$section_232_chapters$copper else c('74')
  )
}


load_local_paths <- function(yaml_path = here('config', 'local_paths.yaml')) {
  defaults <- list(
    import_weights = NULL,
    # 2025 HS10 x country split-share base (built via build_import_weights.R
    # --year 2025 --no-gtap). Optional: enables the 484(f) mapper's country /
    # all-country 2025 share tiers; absent, splits fall to the even tier.
    split_share_imports = 'data/weights/hs10_by_country_2025_con.rds',
    tpc_benchmark = 'data/tpc/tariff_by_flow_day.csv',
    tariff_etrs_repo = NULL,
    # External model-data interface root: where the build publishes hour-stamped
    # output vintages and where parity references live. Never the repo working tree.
    model_data_root = '/nfs/roberts/project/pi_nrs36/shared/model_data/Tariff-Rate-Tracker',
    # weight_mode controls behavior when import_weights is missing or unset.
    #   'required'   (default) — pipeline errors out loudly
    #   'unweighted' — user has explicitly opted out; weighted outputs are skipped
    weight_mode = 'required',
    # weight_method selects how the daily-series import weights are derived.
    #   '484f'  (default) — re-key the 2024 base onto EACH revision's panel codes
    #                       at that revision's HTS-identity date via the 484(f)
    #                       transfer crosswalk (per-interval weights). Uses
    #                       import_weights as the base + split_share_imports for
    #                       the 2025 share tiers.
    #   'static' — legacy: join the 2024 base directly to every interval (drops
    #              renumbered codes; kept for A/B and regression only).
    weight_method = '484f'
  )

  if (file.exists(yaml_path)) {
    raw <- tryCatch(read_yaml(yaml_path), error = function(e) {
      warning('Failed to parse local_paths.yaml: ', conditionMessage(e))
      return(list())
    })

    # Merge with defaults (YAML nulls become R NULLs)
    for (nm in names(defaults)) {
      if (!is.null(raw[[nm]])) defaults[[nm]] <- raw[[nm]]
    }
  }

  # Auto-detect: if no `import_weights` was set, look for a freshly-built file
  # in data/weights/. This lets a fresh clone + `src/io/build_import_weights.R`
  # work without any manual config edit. Setting import_weights explicitly
  # (or weight_mode: unweighted) always wins.
  if (is.null(defaults$import_weights) || !nzchar(defaults$import_weights)) {
    autodetected <- autodetect_import_weights()
    if (!is.null(autodetected)) {
      defaults$import_weights <- autodetected
    }
  }

  # Validate weight_mode
  valid_modes <- c('required', 'unweighted')
  if (!defaults$weight_mode %in% valid_modes) {
    stop('Invalid weight_mode in ', yaml_path, ': "', defaults$weight_mode,
         '". Must be one of: ', paste(valid_modes, collapse = ', '), '.')
  }
  # Validate weight_method
  valid_methods <- c('484f', 'static')
  if (!defaults$weight_method %in% valid_methods) {
    stop('Invalid weight_method in ', yaml_path, ': "', defaults$weight_method,
         '". Must be one of: ', paste(valid_methods, collapse = ', '), '.')
  }

  return(defaults)
}


#' Build the standard "import weights missing" error message.
#'
#' Used by load_import_weights() (and historically the weighted-ETR step) so the
#' diagnostic stays consistent across strict-mode callers.
#'
#' @param reason Short clause describing why the weight file isn't usable,
#'   e.g. "the configured file does not exist: /foo.rds".
#' @param context Either 'load' (generic weight-loader context) or 'etr'
#'   (weighted-ETR-specific). Only changes the opening sentence.
#' @return Character — multi-line error message ready for stop().
weight_resolution_error <- function(reason, context = c('load', 'etr')) {
  context <- match.arg(context)
  opener <- switch(context,
    load = 'Import weights are required but ',
    etr  = 'Weighted ETR requires import weights but '
  )
  paste0(
    opener, reason, '.\n',
    '  - Configure: set `import_weights:` in config/local_paths.yaml to point\n',
    '    at an HS10 x country x GTAP RDS file.\n',
    '  - Build the file from scratch:\n',
    '      Rscript src/io/build_import_weights.R --year 2024\n',
    '    Output goes to data/weights/ and is auto-detected on the next build.\n',
    '    See docs/weights.md for details and override options.\n',
    '  - Opt out: set `weight_mode: unweighted` in config/local_paths.yaml\n',
    '    (or pass --unweighted to src/pipeline/00_build_timeseries.R) to skip weighted outputs.'
  )
}


#' Look for a build_import_weights.R output in data/weights/.
#'
#' Returns the most-recently-modified file matching the canonical naming pattern,
#' or NULL if none is present. Preserves consumption-import (`_con`) preference
#' over general-import (`_gen`) when both exist.
#'
#' NOTE: src/preflight.R duplicates this logic so it can run without sourcing
#' the full helpers chain. Keep the two in sync if you change the pattern or
#' tie-break rules.
autodetect_import_weights <- function(weights_dir = here('data', 'weights')) {
  if (!dir.exists(weights_dir)) return(NULL)

  matches <- list.files(
    weights_dir,
    pattern = '^hs10_by_country_gtap_\\d{4}_(con|gen)\\.rds$',
    full.names = TRUE
  )
  if (length(matches) == 0) return(NULL)

  # Prefer consumption imports; among those, prefer the most recent year.
  con_matches <- grep('_con\\.rds$', matches, value = TRUE)
  pool <- if (length(con_matches) > 0) con_matches else matches

  info <- file.info(pool)
  pool[order(info$mtime, decreasing = TRUE)][1]
}
