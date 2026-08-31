# =============================================================================
# Environment Checker — Preflight Validation
# =============================================================================
#
# Verifies that all required and optional dependencies are available before
# running the pipeline. Reports status of R packages, config files, data
# directories, resource files, and optional external files.
#
# Usage:
#   Rscript src/preflight.R
#
# Exit codes:
#   0 = all required items present
#   1 = one or more required items missing
#
# =============================================================================

# --- R packages ---
REQUIRED_PACKAGES <- c('tidyverse', 'jsonlite', 'yaml', 'here')
OPTIONAL_PACKAGES <- c(
  'pdftools',   # scrape_us_notes.R (Chapter 99 PDF parsing)
  'digest',     # 01_scrape_revision_dates.R (Chapter 99 PDF change detection)
  'arrow',      # 09_daily_series.R (Parquet export)
  'openxlsx',   # 09_daily_series.R (Excel workbook export)
  'httr'        # optional HTTP utilities
)

# --- Required config files ---
REQUIRED_CONFIGS <- c(
  'config/policy_params.yaml',
  'config/revision_dates.csv'
)

# --- Optional config files ---
OPTIONAL_CONFIGS <- c(
  'config/local_paths.yaml'
)

# --- Required resource files ---
REQUIRED_RESOURCES <- c(
  'resources/census_codes.csv',
  'resources/country_partner_mapping.csv',
  'resources/ieepa_exempt_products.csv',
  'resources/floor_exempt_products.csv',
  'resources/s301_product_lists.csv',
  'resources/s301_exclusion_lines.csv',
  'resources/s232_derivative_products.csv',
  'resources/s232_auto_parts.txt',
  'resources/s232_mhd_parts.txt',
  'resources/s232_copper_products.csv',
  'resources/s232_polysilicon_adval_products.csv',
  'resources/s232_polysilicon_mip_products.csv',
  'resources/fentanyl_carveout_products.csv',
  'resources/hs10_gtap_crosswalk.csv'
)

# --- Optional resource files ---
OPTIONAL_RESOURCES <- c(
  'resources/usmca_product_shares.csv',
  'resources/usmca_shares.csv',
  'resources/mfn_exemption_shares.csv',
  'resources/metal_content_shares_bea_hs10.csv',
  'resources/s122_exempt_products.csv',
  'resources/s122_aircraft_utilization.csv'
)

# --- Required directories ---
REQUIRED_DIRS <- c(
  'data/hts_archives',
  'src',
  'config',
  'resources'
)

# --- Optional data files (resolved from local_paths.yaml) ---
# These are checked dynamically below


# =============================================================================
# Check Functions
# =============================================================================

check_packages <- function(packages, required = TRUE) {
  label <- if (required) 'REQUIRED' else 'OPTIONAL'
  results <- vapply(packages, function(pkg) {
    installed <- requireNamespace(pkg, quietly = TRUE)
    status <- if (installed) 'present' else 'MISSING'
    list(pkg = pkg, status = status, label = label)
    installed
  }, logical(1))

  for (pkg in packages) {
    status <- if (results[pkg]) 'present' else 'MISSING'
    cat(sprintf('  [%s] %-12s  %s\n',
                if (results[pkg]) 'OK' else if (required) '!!' else '--',
                pkg, paste(label, status)))
  }
  return(results)
}

check_files <- function(files, base_dir, required = TRUE) {
  label <- if (required) 'REQUIRED' else 'OPTIONAL'
  results <- vapply(files, function(f) {
    path <- file.path(base_dir, f)
    file.exists(path)
  }, logical(1))

  for (f in files) {
    status <- if (results[f]) 'present' else 'MISSING'
    cat(sprintf('  [%s] %-50s  %s\n',
                if (results[f]) 'OK' else if (required) '!!' else '--',
                f, paste(label, status)))
  }
  return(results)
}

check_dirs <- function(dirs, base_dir) {
  results <- vapply(dirs, function(d) {
    dir.exists(file.path(base_dir, d))
  }, logical(1))

  for (d in dirs) {
    status <- if (results[d]) 'present' else 'MISSING'
    cat(sprintf('  [%s] %-50s  %s\n',
                if (results[d]) 'OK' else '!!', d, status))
  }
  return(results)
}


# =============================================================================
# Main
# =============================================================================

if (sys.nframe() == 0) {
  # Resolve project root
  if (requireNamespace('here', quietly = TRUE)) {
    base_dir <- here::here()
  } else {
    base_dir <- getwd()
    message('Note: `here` package not installed; using working directory as project root')
  }

  cat(strrep('=', 70), '\n')
  cat('Tariff Rate Tracker — Environment Check\n')
  cat(strrep('=', 70), '\n')
  cat('Project root:', base_dir, '\n')
  cat('R version:', R.version.string, '\n')
  cat('Date:', format(Sys.time(), '%Y-%m-%d %H:%M'), '\n')
  cat(strrep('-', 70), '\n\n')

  any_required_missing <- FALSE

  # --- 1. R Packages ---
  cat('R PACKAGES\n')
  req_pkg <- check_packages(REQUIRED_PACKAGES, required = TRUE)
  opt_pkg <- check_packages(OPTIONAL_PACKAGES, required = FALSE)
  if (any(!req_pkg)) any_required_missing <- TRUE
  cat('\n')

  # --- 2. Directories ---
  cat('DIRECTORIES\n')
  dir_ok <- check_dirs(REQUIRED_DIRS, base_dir)
  if (any(!dir_ok)) any_required_missing <- TRUE
  cat('\n')

  # --- 3. Config Files ---
  cat('CONFIG FILES\n')
  req_cfg <- check_files(REQUIRED_CONFIGS, base_dir, required = TRUE)
  opt_cfg <- check_files(OPTIONAL_CONFIGS, base_dir, required = FALSE)
  if (any(!req_cfg)) any_required_missing <- TRUE
  cat('\n')

  # --- 4. Resource Files ---
  cat('RESOURCE FILES\n')
  req_res <- check_files(REQUIRED_RESOURCES, base_dir, required = TRUE)
  opt_res <- check_files(OPTIONAL_RESOURCES, base_dir, required = FALSE)
  if (any(!req_res)) any_required_missing <- TRUE
  cat('\n')

  # --- 5. HTS JSON Archives ---
  cat('HTS JSON ARCHIVES\n')
  json_dir <- file.path(base_dir, 'data', 'hts_archives')
  if (dir.exists(json_dir)) {
    json_files <- list.files(json_dir, pattern = '\\.json(\\.gz)?$')
    cat(sprintf('  [%s] %d JSON files in data/hts_archives/\n',
                if (length(json_files) > 0) 'OK' else '!!',
                length(json_files)))
    if (length(json_files) == 0) {
      cat('  >> Run: Rscript src/pipeline/02_download_hts.R\n')
      any_required_missing <- TRUE
    }

    # Every real revision configured in revision_dates.csv must have an archive.
    # The build SKIPS a configured revision whose JSON is absent, so a missing
    # archive surfaces as a quietly shorter series rather than an error — the
    # same silent-omission failure mode the footnote audit exists to catch.
    # (Combined plan Phase 2 item 6.)
    #
    # Base R only, and the revision -> filename mapping is inlined rather than
    # sourced: preflight must run before the tidyverse is installed, and
    # src/model/revisions.R calls library(tidyverse) on load. Mirrors
    # parse_revision_id() / resolve_json_path() there — keep in sync.
    rev_csv <- file.path(base_dir, 'config', 'revision_dates.csv')
    if (!file.exists(rev_csv)) {
      cat('  [!!] config/revision_dates.csv missing — cannot check archive coverage\n')
      any_required_missing <- TRUE
    } else {
      configured <- read.csv(rev_csv, stringsAsFactors = FALSE)$revision
      # Synthetic partitions are minted during the build, never archived.
      configured <- configured[!grepl('^(sched_|bnd_)', configured)]

      archive_missing <- character()
      for (rev in configured) {
        if (grepl('^[0-9]{4}_', rev)) {
          yr <- substr(rev, 1, 4)
          rv <- sub('^[0-9]{4}_', '', rev)
        } else {
          yr <- '2025'
          rv <- rev
        }
        stem <- file.path(json_dir, paste0('hts_', yr, '_', rv))
        if (!file.exists(paste0(stem, '.json.gz')) && !file.exists(paste0(stem, '.json'))) {
          archive_missing <- c(archive_missing, rev)
        }
      }

      cat(sprintf('  [%s] %d/%d configured revisions have an archive\n',
                  if (length(archive_missing) == 0) 'OK' else '!!',
                  length(configured) - length(archive_missing), length(configured)))
      if (length(archive_missing) > 0) {
        cat('  >> No archive for: ', paste(archive_missing, collapse = ', '), '\n', sep = '')
        cat('  >> The build skips these silently. Add the archive, or remove the\n')
        cat('  >> row and represent the policy change with a synthetic boundary\n')
        cat('  >> (the 2026_rev_14 treatment).\n')
        any_required_missing <- TRUE
      }
    }
  } else {
    cat('  [!!] data/hts_archives/ directory missing\n')
    any_required_missing <- TRUE
  }
  cat('\n')

  # --- 6. Optional External Files (from local_paths.yaml) ---
  cat('OPTIONAL EXTERNAL FILES (from config/local_paths.yaml)\n')
  local_paths_file <- file.path(base_dir, 'config', 'local_paths.yaml')

  # Helper: find the auto-detect target.
  # NOTE: Mirrors policy_params.R::autodetect_import_weights(). Duplicated here
  # so preflight.R can run without sourcing the full helpers chain (which would
  # require the tidyverse to be installed before we get to report on it).
  # Keep in sync.
  autodetect <- function() {
    wd <- file.path(base_dir, 'data', 'weights')
    if (!dir.exists(wd)) return(NULL)
    matches <- list.files(wd, pattern = '^hs10_by_country_gtap_\\d{4}_(con|gen)\\.rds$',
                          full.names = TRUE)
    if (length(matches) == 0) return(NULL)
    con_matches <- grep('_con\\.rds$', matches, value = TRUE)
    pool <- if (length(con_matches) > 0) con_matches else matches
    info <- file.info(pool)
    pool[order(info$mtime, decreasing = TRUE)][1]
  }
  autodetected <- autodetect()

  if (file.exists(local_paths_file)) {
    lp <- yaml::read_yaml(local_paths_file)
  } else {
    lp <- list()
    cat('  [--] config/local_paths.yaml not found — using defaults (weight_mode=required)\n')
  }

  # weight_mode (controls behavior of missing import weights)
  wm <- lp$weight_mode
  if (is.null(wm)) wm <- 'required'
  cat(sprintf('  [..] weight_mode: %s\n', wm))

  # Import weights: explicit config first, then auto-detect from data/weights/
  iw <- lp$import_weights
  iw_resolved <- iw
  iw_source <- 'config'
  if (is.null(iw_resolved) && !is.null(autodetected)) {
    iw_resolved <- autodetected
    iw_source <- 'auto-detect (data/weights/)'
  }

  if (is.null(iw_resolved)) {
    if (identical(wm, 'unweighted')) {
      cat('  [--] import_weights: not configured (weight_mode=unweighted; weighted outputs will be skipped)\n')
    } else {
      cat('  [!!] import_weights: not configured and no file in data/weights/\n')
      cat('       Build will ERROR. Either:\n')
      cat('         - run: Rscript src/io/build_import_weights.R --year 2024\n')
      cat('         - set import_weights in config/local_paths.yaml, or\n')
      cat('         - set weight_mode: unweighted to opt out.\n')
      any_required_missing <- TRUE
    }
  } else {
    iw_path <- if (startsWith(iw_resolved, '/') || grepl('^[A-Za-z]:', iw_resolved)) iw_resolved else file.path(base_dir, iw_resolved)
    exists <- file.exists(iw_path)
    if (!exists && identical(wm, 'required')) {
      cat(sprintf('  [!!] import_weights: %s (NOT FOUND via %s, weight_mode=required → build will ERROR)\n',
                  iw_resolved, iw_source))
      any_required_missing <- TRUE
    } else {
      cat(sprintf('  [%s] import_weights: %s  (%s)\n',
                  if (exists) 'OK' else '--', iw_resolved, iw_source))
    }
  }

  # Split-share base: the 2025 HS10 x country file the 484(f) mapper uses to
  # decide WHICH successor of a renumbered code a 2024 flow belongs to. The
  # build treats it as optional -- resolve_daily_weight_plan() drops a missing
  # path and every split falls to the even tier -- but that silently moves
  # ~$64B of trade value out of the country_2025 / all_country_2025 identity
  # tiers, shifting weighted authority ETRs across the WHOLE series. Nothing
  # downstream catches it: verify_build passes and matched_imports_b ==
  # total_imports_b still reads 100%. So flag it as required wherever it would
  # actually be consumed (weight_method 484f and not opted out of weights).
  # NOTE: default path and weight_method default mirror
  # policy_params.R::load_local_paths(). Keep in sync.
  wmeth <- lp$weight_method
  if (is.null(wmeth)) wmeth <- '484f'
  ss <- lp$split_share_imports
  if (is.null(ss)) ss <- 'data/weights/hs10_by_country_2025_con.rds'
  ss_path <- if (startsWith(ss, '/') || grepl('^[A-Za-z]:', ss)) ss else file.path(base_dir, ss)

  if (!identical(wmeth, '484f') || identical(wm, 'unweighted')) {
    cat(sprintf('  [--] split_share_imports: not consumed (weight_method=%s, weight_mode=%s)\n',
                wmeth, wm))
  } else if (file.exists(ss_path)) {
    cat(sprintf('  [OK] split_share_imports: %s\n', ss))
  } else {
    cat(sprintf('  [!!] split_share_imports: %s (NOT FOUND, weight_method=484f)\n', ss))
    cat('       The 484(f) mapper would SILENTLY fall back to an even split:\n')
    cat('       ~$64B of value leaves the 2025 identity tiers, moving weighted\n')
    cat('       ETRs across the whole series. The build still reports success --\n')
    cat('       verify_build and the matched/total diagnostic both stay green --\n')
    cat('       so a degraded weight plan is only visible in the manifest\n')
    cat('       (weights.provenance.split_shares.present = false). Either:\n')
    cat('         - run: Rscript src/io/build_import_weights.R --year 2025 --no-gtap\n')
    cat('         - set split_share_imports in config/local_paths.yaml, or\n')
    cat('         - set weight_mode: unweighted to opt out of weighted outputs.\n')
    any_required_missing <- TRUE
  }


  # Tariff-ETRs repo
  etrs <- lp$tariff_etrs_repo
  if (is.null(etrs)) {
    cat('  [--] tariff_etrs_repo: not configured (comparison skipped)\n')
  } else {
    exists <- dir.exists(etrs)
    cat(sprintf('  [%s] tariff_etrs_repo: %s\n', if (exists) 'OK' else '--', etrs))
  }
  cat('\n')

  # --- 7. Run Mode Assessment ---
  cat(strrep('=', 70), '\n')
  cat('RUN MODE ASSESSMENT\n')
  cat(strrep('-', 70), '\n')

  has_json <- dir.exists(json_dir) && length(list.files(json_dir, '\\.json$')) > 0
  has_weights <- {
    explicit <- if (file.exists(local_paths_file)) {
      iw_cfg <- yaml::read_yaml(local_paths_file)$import_weights
      if (!is.null(iw_cfg)) {
        p <- if (startsWith(iw_cfg, '/') || grepl('^[A-Za-z]:', iw_cfg)) iw_cfg else file.path(base_dir, iw_cfg)
        file.exists(p)
      } else FALSE
    } else FALSE
    explicit || !is.null(autodetected)
  }
  modes <- c(
    'core'               = !any_required_missing && has_json,
    'core_plus_weights'  = !any_required_missing && has_json && has_weights
  )

  for (mode in names(modes)) {
    cat(sprintf('  %-25s %s\n', mode,
                if (modes[mode]) 'READY' else 'not available'))
  }

  cat('\n')
  if (any_required_missing) {
    cat('STATUS: REQUIRED ITEMS MISSING — see [!!] items above\n')
    quit(status = 1)
  } else {
    cat('STATUS: All required items present. Ready to build.\n')
    cat('\nQuick start:\n')
    cat('  Rscript src/pipeline/02_download_hts.R          # Download HTS JSON if needed\n')
    cat('  Rscript src/pipeline/00_build_timeseries.R --full  # Full build\n')
    cat('  Rscript src/pipeline/00_build_timeseries.R --core-only  # Build without weighted outputs\n')
    quit(status = 0)
  }
}
