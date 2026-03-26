# =============================================================================
# generate_etrs_config.R
# =============================================================================
#
# Generates Tariff-ETRs-compatible YAML config files from tariff-rate-tracker
# parsed data. This is the bridge between the tracker (source of truth for
# statutory tariff parameters) and ETRs (single calculation engine for
# weighted effective tariff rates).
#
# The tracker parses HTS JSON to extract per-authority rates and product
# coverage. This script translates that into the YAML format ETRs expects:
#   - s232.yaml: Section 232 tariffs by program (steel, aluminum, autos, etc.)
#   - ieepa_reciprocal.yaml: IEEPA reciprocal tariffs with exempt products
#   - ieepa_fentanyl.yaml: IEEPA fentanyl tariffs with carve-outs
#   - s301.yaml: Section 301 product-specific tariffs (China only)
#   - s122.yaml: Section 122 blanket tariffs with exempt products
#   - other_params.yaml: MFN rates, USMCA, metal content, auto rebate config
#
# Usage:
#   source('src/helpers.R')
#   source('src/generate_etrs_config.R')
#   ts <- readRDS('data/timeseries/rate_timeseries.rds')
#   generate_etrs_config(ts, '2026-04-01', '../Tariff-ETRs/config/baseline/2026-04-01')
#
# =============================================================================

library(tidyverse)
library(yaml)


# =============================================================================
# Main Entry Point
# =============================================================================

#' Generate a complete ETRs config directory for a given date
#'
#' Exports a dense statutory_rates.csv.gz (the lossless interface) plus
#' other_params.yaml with adjustment parameters. Replaces the old YAML-per-
#' authority approach which was lossy (modal rates, reverse-USMCA, etc.).
#'
#' @param ts Rate timeseries (from rate_timeseries.rds)
#' @param date Character or Date: the policy date to snapshot
#' @param output_dir Directory to write config files into (created if needed)
#' @param policy_params Optional: pre-loaded policy params (calls load_policy_params() if NULL)
#' @param etrs_resources_dir Path to ETRs resources/ directory
generate_etrs_config <- function(ts, date, output_dir,
                                  policy_params = NULL,
                                  etrs_resources_dir = NULL) {

  date <- as.Date(date)
  if (is.null(policy_params)) {
    policy_params <- load_policy_params()
  }

  message(sprintf('\n=== Generating ETRs config for %s ===', date))
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  # Snapshot rates at this date
  has_valid_dates <- 'valid_from' %in% names(ts) && !all(is.na(ts$valid_from))
  if (has_valid_dates) {
    snapshot <- get_rates_at_date(ts, date, policy_params)
  } else {
    snapshot <- ts
  }
  message(sprintf('  Snapshot: %s product-country pairs', format(nrow(snapshot), big.mark = ',')))

  # Load Ch99 data for s232 deal target_total extraction
  ch99_path <- here::here('data', 'processed', 'chapter99_rates.rds')
  ch99_data <- if (file.exists(ch99_path)) readRDS(ch99_path) else NULL

  # Export dense statutory rates CSV (replaces all per-authority YAMLs)
  active_s232_programs <- export_statutory_rates(snapshot, policy_params, output_dir,
                                                  ch99_data = ch99_data)

  # Write other_params.yaml (adjustment parameters only — no MFN path needed)
  generate_other_params_yaml(date, policy_params, output_dir, etrs_resources_dir,
                             active_s232_programs = active_s232_programs)

  message(sprintf('  Config written to %s', output_dir))
  invisible(output_dir)
}


#' Generate ETRs configs for all revision dates (for daily series)
#'
#' @param ts Rate timeseries
#' @param output_base Base directory (configs written to {output_base}/{date}/)
#' @param policy_params Optional: pre-loaded policy params
#' @param etrs_resources_dir Path to ETRs resources/ directory
#'
#' @return Tibble of revision intervals (date, valid_from, valid_until)
generate_etrs_configs_all_revisions <- function(ts, output_base,
                                                 policy_params = NULL,
                                                 etrs_resources_dir = NULL) {

  if (is.null(policy_params)) {
    policy_params <- load_policy_params()
  }

  # Get unique revision intervals
  rev_intervals <- ts %>%
    distinct(revision, valid_from, valid_until) %>%
    arrange(valid_from)

  message(sprintf('Generating ETRs configs for %d revisions...', nrow(rev_intervals)))

  for (i in seq_len(nrow(rev_intervals))) {
    rev <- rev_intervals[i, ]
    date_str <- as.character(rev$valid_from)
    output_dir <- file.path(output_base, date_str)

    generate_etrs_config(
      ts                = ts,
      date              = rev$valid_from,
      output_dir        = output_dir,
      policy_params     = policy_params,
      etrs_resources_dir = etrs_resources_dir
    )
  }

  message(sprintf('\nDone. Generated %d config folders in %s', nrow(rev_intervals), output_base))
  invisible(rev_intervals)
}


# =============================================================================
# Dense CSV Export (primary interface)
# =============================================================================

#' Export statutory rates as dense CSV for ETRs consumption
#'
#' Writes statutory_rates.csv.gz containing pre-USMCA, pre-metal-content,
#' pre-stacking statutory rates per authority per HTS10×country. ETRs reads
#' this directly and applies all adjustments.
#'
#' Section 232 programs are split into per-program columns using product
#' membership from policy_params (chapters, headings, derivatives).
#'
#' @param snapshot Rate snapshot tibble (must contain statutory_rate_* columns)
#' @param policy_params Loaded policy parameters
#' @param output_dir Directory to write statutory_rates.csv.gz
#' @param ch99_data Ch99 data for extracting s232 deal rates (optional; NULL = no deal target_totals)
#'
#' @return Character vector of active s232 program names (for metal_programs)
export_statutory_rates <- function(snapshot, policy_params, output_dir, ch99_data = NULL) {

  # Verify statutory columns exist
  required <- c('statutory_rate_232', 'statutory_base_rate',
                'statutory_rate_ieepa_recip', 'statutory_rate_ieepa_fent',
                'statutory_rate_301', 'statutory_rate_s122',
                'statutory_rate_section_201', 'statutory_rate_other')
  missing <- setdiff(required, names(snapshot))
  if (length(missing) > 0) {
    stop('Snapshot missing statutory columns: ', paste(missing, collapse = ', '),
         '\n  Ensure calculate_rates_for_revision() saves statutory_rate_* columns')
  }

  # ---------------------------------------------------------------------------
  # Classify products into s232 programs
  # ---------------------------------------------------------------------------

  # Build product → program mapping
  program_map <- tibble(hts10 = character(), s232_program = character())

  # Steel chapters (72/73)
  steel_chapters <- policy_params$section_232_chapters$steel %||% c('72', '73')
  steel_pattern <- paste0('^(', paste(steel_chapters, collapse = '|'), ')')

  # Aluminum chapter (76)
  alum_chapters <- policy_params$section_232_chapters$aluminum %||% '76'
  alum_pattern <- paste0('^(', paste(alum_chapters, collapse = '|'), ')')

  # Derivative products
  deriv_file <- here::here(policy_params$section_232_derivatives$resource_file %||%
                            'resources/s232_derivative_products.csv')
  deriv_prefixes <- character(0)
  if (file.exists(deriv_file)) {
    derivs <- read_csv(deriv_file, show_col_types = FALSE)
    deriv_prefixes <- unique(derivs$hts_prefix)
  }
  deriv_pattern <- if (length(deriv_prefixes) > 0) {
    paste0('^(', paste(deriv_prefixes, collapse = '|'), ')')
  } else NULL

  # Heading programs (autos, copper, softwood, etc.)
  # Only include headings that are ACTIVE in this revision (Ch99 entries present).
  # Inactive headings' products fall through to derivative classification.
  headings <- policy_params$section_232_headings %||% list()
  heading_patterns <- list()

  # Build heading gates (same logic as calculate_rates_for_revision step 4)
  heading_gates <- list()
  if (!is.null(ch99_data)) {
    s232_rates_check <- tryCatch(extract_section232_rates(ch99_data), error = function(e) NULL)
    if (!is.null(s232_rates_check)) {
      has_auto_parts_ch99 <- any(grepl('^9903\\.94\\.0[5-9]', ch99_data$ch99_code))
      heading_gates <- list(
        autos_passenger  = s232_rates_check$auto_rate > 0 || s232_rates_check$auto_has_deals,
        autos_light_trucks = s232_rates_check$auto_rate > 0 || s232_rates_check$auto_has_deals,
        auto_parts       = has_auto_parts_ch99,
        copper           = s232_rates_check$copper_rate > 0,
        softwood         = s232_rates_check$wood_rate > 0 || s232_rates_check$wood_furniture_rate > 0,
        wood_furniture   = s232_rates_check$wood_rate > 0 || s232_rates_check$wood_furniture_rate > 0,
        kitchen_cabinets = s232_rates_check$wood_rate > 0 || s232_rates_check$wood_furniture_rate > 0,
        mhd_vehicles     = s232_rates_check$mhd_rate > 0,
        mhd_parts        = s232_rates_check$mhd_rate > 0,
        buses            = s232_rates_check$mhd_rate > 0
      )
    }
  }

  for (prog_name in names(headings)) {
    # Skip inactive headings
    gate_val <- heading_gates[[prog_name]]
    if (!is.null(gate_val) && !gate_val) {
      message(sprintf('  Skipping heading "%s" — not active in this revision', prog_name))
      next
    }
    prog <- headings[[prog_name]]
    prefixes <- prog$prefixes %||% character(0)
    if (!is.null(prog$prefixes_file)) {
      pf <- here::here(prog$prefixes_file)
      if (file.exists(pf)) {
        prefixes <- c(prefixes, trimws(readLines(pf, warn = FALSE)))
        prefixes <- prefixes[nchar(prefixes) > 0]
      }
    }
    if (!is.null(prog$products_file)) {
      pf <- here::here(prog$products_file)
      if (file.exists(pf)) {
        prods <- read_csv(pf, show_col_types = FALSE,
                          col_types = cols(.default = col_character()))
        prefixes <- c(prefixes, prods$hts10)
      }
    }
    prefixes <- unique(prefixes)
    if (length(prefixes) > 0) {
      heading_patterns[[prog_name]] <- paste0('^(', paste(prefixes, collapse = '|'), ')')
    }
  }

  # All unique HTS10 with statutory 232 rate > 0
  all_hts10 <- unique(snapshot$hts10[snapshot$statutory_rate_232 > 0])

  # Classify each product.
  # Priority: blanket steel/aluminum → heading programs → derivatives.
  # Blanket chapters (72/73/76) are primary metal — their tariff applies to
  # full customs value. Even if they also appear in the derivative prefix list,
  # the blanket program is the correct classification.
  classify_s232_program <- function(hts10) {
    # Blanket steel/aluminum first (primary chapters)
    if (grepl(steel_pattern, hts10)) return('steel')
    if (grepl(alum_pattern, hts10)) return('aluminum')
    # Heading programs (autos, copper, etc.)
    for (prog_name in names(heading_patterns)) {
      if (grepl(heading_patterns[[prog_name]], hts10)) return(prog_name)
    }
    # Derivatives (outside primary chapters)
    if (!is.null(deriv_pattern) && grepl(deriv_pattern, hts10)) return('aluminum_derivatives')
    # Fallback: unclassified (shouldn't happen)
    return('unclassified')
  }

  product_programs <- tibble(
    hts10 = all_hts10,
    s232_program = vapply(all_hts10, classify_s232_program, character(1))
  )

  active_programs <- sort(unique(product_programs$s232_program))
  active_programs <- active_programs[active_programs != 'unclassified']
  message(sprintf('  s232 programs: %s', paste(active_programs, collapse = ', ')))

  n_unclassified <- sum(product_programs$s232_program == 'unclassified')
  if (n_unclassified > 0) {
    warning(sprintf('%d products with statutory_rate_232 > 0 could not be classified into a program',
                    n_unclassified))
  }

  # ---------------------------------------------------------------------------
  # Build CSV columns
  # ---------------------------------------------------------------------------

  # Build per-program s232 columns via pivot_wider
  s232_wide <- snapshot %>%
    select(hts10, cty_code = country, statutory_rate_232) %>%
    inner_join(product_programs, by = 'hts10') %>%
    filter(statutory_rate_232 > 0) %>%
    mutate(s232_program = paste0('s232_', s232_program)) %>%
    pivot_wider(
      id_cols = c(hts10, cty_code),
      names_from = s232_program,
      values_from = statutory_rate_232,
      values_fill = 0
    )

  # Build the full CSV from snapshot (all columns at once to avoid row-order issues)
  csv <- snapshot %>%
    transmute(
      hts10,
      cty_code         = country,
      mfn_rate         = statutory_base_rate,
      ieepa_reciprocal = statutory_rate_ieepa_recip,
      ieepa_fentanyl   = statutory_rate_ieepa_fent,
      s301             = statutory_rate_301,
      s122             = statutory_rate_s122,
      s201             = statutory_rate_section_201,
      other            = statutory_rate_other
    ) %>%
    left_join(s232_wide, by = c('hts10', 'cty_code'))

  # Replace NAs in s232 columns with 0
  s232_cols <- names(csv)[grepl('^s232_', names(csv))]
  for (col in s232_cols) {
    csv[[col]][is.na(csv[[col]])] <- 0
  }

  # ---------------------------------------------------------------------------
  # Add target_total columns
  # ---------------------------------------------------------------------------

  # IEEPA reciprocal floor (target_total).
  # Only emit for countries where the floor is binding — i.e., their IEEPA
  # rate exceeds the floor (surcharge being capped). Countries at or below
  # the floor (e.g., at universal baseline 10% when floor is 15%) don't get
  # target_total because the floor deal caps surcharges, it doesn't raise baselines.
  floor_countries <- as.character(policy_params$FLOOR_COUNTRIES %||%
    policy_params$floor_rates$floor_countries)
  floor_rate <- policy_params$FLOOR_RATE %||% policy_params$floor_rates$floor_rate %||% 0.15

  if (length(floor_countries) > 0) {
    # Find which floor countries actually have IEEPA rates above the floor
    # (use modal rate per country from the snapshot's statutory IEEPA rate)
    binding_countries <- snapshot %>%
      filter(country %in% floor_countries, statutory_rate_ieepa_recip > 0) %>%
      group_by(country) %>%
      summarise(modal_rate = as.numeric(names(sort(table(statutory_rate_ieepa_recip), decreasing = TRUE))[1]),
                .groups = 'drop') %>%
      filter(modal_rate > floor_rate + 0.001) %>%
      pull(country)

    if (length(binding_countries) > 0) {
      csv <- csv %>%
        mutate(target_total_ieepa_reciprocal = if_else(
          cty_code %in% binding_countries, floor_rate, NA_real_
        ))
      message(sprintf('  target_total_ieepa_reciprocal: %d of %d floor countries binding',
                      length(binding_countries), length(floor_countries)))
    } else {
      message('  target_total_ieepa_reciprocal: no floor countries binding (all at/below floor)')
    }
  }

  # s232 auto deal rates (target_total for floor-type deals)
  s232_rates_data <- if (!is.null(ch99_data)) {
    tryCatch(extract_section232_rates(ch99_data), error = function(e) NULL)
  } else {
    NULL
  }

  if (!is.null(s232_rates_data) && nrow(s232_rates_data$auto_deal_rates) > 0) {
    iso_to_census_vec <- function(iso_code) {
      if (iso_code == 'EU') {
        return(if (!is.null(policy_params)) names(policy_params$eu27_codes) else character(0))
      }
      census <- ISO_TO_CENSUS[iso_code]
      if (is.na(census)) return(character(0))
      as.character(census)
    }

    for (i in seq_len(nrow(s232_rates_data$auto_deal_rates))) {
      deal <- s232_rates_data$auto_deal_rates[i, ]
      if (deal$rate_type != 'floor') next
      census_codes <- iso_to_census_vec(deal$country)
      if (length(census_codes) == 0) next

      tt_col <- paste0('target_total_s232_', deal$program)
      if (!(tt_col %in% names(csv))) csv[[tt_col]] <- NA_real_
      csv[[tt_col]] <- if_else(
        csv$cty_code %in% census_codes,
        deal$rate, csv[[tt_col]]
      )
    }
  }

  # ---------------------------------------------------------------------------
  # Filter to sparse (at least one non-zero rate) and write
  # ---------------------------------------------------------------------------

  rate_cols <- c(s232_cols, 'ieepa_reciprocal', 'ieepa_fentanyl',
                 's301', 's122', 's201', 'other', 'mfn_rate')
  csv <- csv %>%
    filter(if_any(all_of(rate_cols), ~ . > 0))

  output_path <- file.path(output_dir, 'statutory_rates.csv.gz')
  write_csv(csv, output_path)
  message(sprintf('  Exported statutory_rates.csv.gz: %s rows × %d columns',
                  format(nrow(csv), big.mark = ','), ncol(csv)))

  invisible(active_programs)
}


# =============================================================================
# Section 232 YAML Generator (kept for backward compatibility)
# =============================================================================

#' Generate s232.yaml from policy parameters
#'
#' Maps tracker's section_232_chapters and section_232_headings config to ETRs'
#' per-program YAML format with product lists, country rates, and USMCA flags.
generate_s232_yaml <- function(snapshot, date, policy_params, output_dir) {

  date <- as.Date(date)
  s232_config <- list()

  # Build s232 product lists from the SNAPSHOT, not from policy_params prefixes.
  # Only HTS10 codes that actually have rate_232 > 0 in the snapshot are included.
  # This ensures ETRs' 232 coverage exactly matches the tracker's.
  has_232 <- 'rate_232' %in% names(snapshot) &&
    any(snapshot$rate_232 > 0, na.rm = TRUE)

  if (has_232) {
    # Get all unique HTS10 codes with rate_232 > 0 (across any country)
    active_232_products <- snapshot %>%
      filter(rate_232 > 0) %>%
      distinct(hts10) %>%
      pull(hts10)

    # Helper: filter prefixes/codes to only those matching active 232 products
    filter_active_codes <- function(prefixes) {
      pattern <- paste0('^(', paste(prefixes, collapse = '|'), ')')
      unique(active_232_products[str_detect(active_232_products, pattern)])
    }
  }

  # --- Steel ---
  steel_chapters <- policy_params$section_232_chapters$steel
  if (!is.null(steel_chapters) && has_232) {
    active_steel <- filter_active_codes(steel_chapters)
    if (length(active_steel) > 0) {
      steel <- list(
        base = as.list(active_steel),
        rates = build_232_country_rates('steel', steel_chapters, snapshot, date, policy_params),
        usmca_exempt = 0
      )
      s232_config[['steel']] <- steel
      message(sprintf('  s232 steel: %d active HTS10 codes', length(active_steel)))
    }
  }

  # --- Aluminum (base articles, chapter 76) ---
  aluminum_chapters <- policy_params$section_232_chapters$aluminum
  if (!is.null(aluminum_chapters) && has_232) {
    active_aluminum <- filter_active_codes(aluminum_chapters)
    if (length(active_aluminum) > 0) {
      aluminum <- list(
        base = as.list(active_aluminum),
        rates = build_232_country_rates('aluminum', aluminum_chapters, snapshot, date, policy_params),
        usmca_exempt = 0
      )
      s232_config[['aluminum']] <- aluminum
      message(sprintf('  s232 aluminum: %d active HTS10 codes', length(active_aluminum)))
    }
  }

  # --- Aluminum derivatives ---
  deriv_file <- here::here(policy_params$section_232_derivatives$resource_file)
  if (file.exists(deriv_file) && has_232) {
    derivs <- read_csv(deriv_file, show_col_types = FALSE)
    deriv_prefixes <- unique(derivs$hts_prefix)
    active_derivs <- filter_active_codes(deriv_prefixes)

    if (length(active_derivs) > 0) {
      deriv_rate <- policy_params$section_232_derivatives$default_rate %||% 0.50
      s232_config[['aluminum_derivatives']] <- list(
        base = as.list(as.character(active_derivs)),
        rates = list(default = deriv_rate),
        usmca_exempt = 0
      )
      message(sprintf('  s232 aluminum_derivatives: %d active HTS10 codes', length(active_derivs)))
    }
  }

  # --- Heading-based programs (autos, copper, softwood, etc.) ---
  headings <- policy_params$section_232_headings
  if (!is.null(headings) && has_232) {
    for (prog_name in names(headings)) {
      prog <- headings[[prog_name]]
      prefixes <- prog$prefixes %||% character(0)

      # Load prefixes from file if specified
      if (!is.null(prog$prefixes_file)) {
        pf <- here::here(prog$prefixes_file)
        if (file.exists(pf)) {
          prefixes <- c(prefixes, readLines(pf, warn = FALSE))
          prefixes <- trimws(prefixes)
          prefixes <- prefixes[nchar(prefixes) > 0]
        }
      }

      # Load products from CSV file if specified (e.g., copper)
      if (!is.null(prog$products_file)) {
        pf <- here::here(prog$products_file)
        if (file.exists(pf)) {
          prods <- read_csv(pf, show_col_types = FALSE,
                            col_types = cols(.default = col_character()))
          prefixes <- c(prefixes, prods$hts10)
        }
      }

      prefixes <- unique(prefixes)
      if (length(prefixes) == 0) next

      # Only include HTS10 codes that have rate_232 > 0 in the snapshot
      active_codes <- filter_active_codes(prefixes)
      if (length(active_codes) == 0) {
        message(sprintf('  Skipping s232 program %s (no active products in snapshot)', prog_name))
        next
      }

      usmca_exempt_flag <- if (isTRUE(prog$usmca_exempt)) 1 else 0

      # Build per-country rates from the snapshot.
      # Default = 0 (absence in snapshot = no tariff). Only countries with
      # rate_232 > 0 for products in this program get listed.
      prog_pattern <- paste0('^(', paste(active_codes, collapse = '|'), ')')
      prog_snapshot <- snapshot %>% filter(str_detect(hts10, prog_pattern), rate_232 > 0)

      # USMCA countries: snapshot rates are post-USMCA. Skip them and emit
      # the program default rate instead — ETRs applies USMCA reduction itself.
      usmca_codes <- c(policy_params$CTY_CANADA %||% '1220',
                        policy_params$CTY_MEXICO %||% '2010')
      skip_usmca <- usmca_exempt_flag == 1

      prog_rates <- list(default = 0)

      # For usmca_exempt programs, CA/MX get the program default (ETRs handles USMCA)
      if (skip_usmca) {
        prog_rates[['canada']] <- prog$default_rate
        prog_rates[['mexico']] <- prog$default_rate
      }

      if (nrow(prog_snapshot) > 0) {
        rate_data <- prog_snapshot
        if (skip_usmca) {
          rate_data <- rate_data %>% filter(!country %in% usmca_codes)
        }
        country_modal <- rate_data %>%
          group_by(country) %>%
          summarise(modal_rate = as.numeric(names(sort(table(rate_232), decreasing = TRUE))[1]),
                    .groups = 'drop')
        for (i in seq_len(nrow(country_modal))) {
          mnemonic <- census_to_mnemonic(country_modal$country[i], policy_params)
          prog_rates[[mnemonic]] <- country_modal$modal_rate[i]
        }
      }

      prog_config <- list(
        base = as.list(as.character(active_codes)),
        rates = prog_rates
      )

      # Add country-specific deal rates as target_total
      deal_rates <- get_232_deal_rates(prog_name, prefixes, prog$default_rate,
                                        snapshot, policy_params)
      if (!is.null(deal_rates) && nrow(deal_rates) > 0) {
        target_total <- list()
        for (j in seq_len(nrow(deal_rates))) {
          country_mnemonic <- census_to_mnemonic(deal_rates$country[j], policy_params)
          target_total[[country_mnemonic]] <- deal_rates$rate[j]
        }
        prog_config$target_total <- target_total
      }

      prog_config$usmca_exempt <- usmca_exempt_flag
      s232_config[[prog_name]] <- prog_config
      message(sprintf('  s232 %s: %d active HTS10 codes', prog_name, length(active_codes)))
    }
  }

  if (length(s232_config) > 0) {
    write_yaml(s232_config, file.path(output_dir, 's232.yaml'))
    message(sprintf('  Wrote s232.yaml (%d programs)', length(s232_config)))
  }

  # Return active program names so other_params can reference them for metal_programs
  invisible(names(s232_config))
}


#' Build country rates dict for a 232 program, extracting rates from snapshot.
#' Uses per-country modal rates from the snapshot (lossless for countries in snapshot).
build_232_country_rates <- function(program, chapter_prefixes, snapshot, date, policy_params) {

  date <- as.Date(date)

  # Extract the default 232 rate from the snapshot for this program's products.
  # Filter to products in these chapters and find the modal rate_232 value.
  if ('rate_232' %in% names(snapshot) && 'hts10' %in% names(snapshot)) {
    chapter_pattern <- paste0('^(', paste(chapter_prefixes, collapse = '|'), ')')
    program_rates <- snapshot %>%
      filter(str_detect(hts10, chapter_pattern), rate_232 > 0)

    if (nrow(program_rates) > 0) {
      rate_freq <- sort(table(program_rates$rate_232), decreasing = TRUE)
      rate <- as.numeric(names(rate_freq)[1])
    } else {
      rate <- 0.25
    }
  } else {
    rate <- 0.25
  }

  # Default = 0 (absence in snapshot = no tariff).
  # Only list countries that have rate_232 > 0 for this program's products.
  rates <- list(default = 0)

  if (nrow(program_rates) > 0) {
    country_modal <- program_rates %>%
      group_by(country) %>%
      summarise(
        modal_rate = as.numeric(names(sort(table(rate_232), decreasing = TRUE))[1]),
        .groups = 'drop'
      )

    for (i in seq_len(nrow(country_modal))) {
      mnemonic <- census_to_mnemonic(country_modal$country[i], policy_params)
      rates[[mnemonic]] <- country_modal$modal_rate[i]
    }
  }

  rates
}


# =============================================================================
# IEEPA Reciprocal YAML Generator
# =============================================================================

#' Generate ieepa_reciprocal.yaml from snapshot + policy params
#'
#' The IEEPA reciprocal authority applies to ALL products for applicable countries,
#' minus ~1,087 exempt products (Annex A). Floor countries (EU, Japan, Korea, Swiss)
#' get floor treatment via target_total_rules.
generate_ieepa_reciprocal_yaml <- function(snapshot, date, policy_params, output_dir) {

  date <- as.Date(date)

  # Check if IEEPA has been invalidated by this date
  invalidation_date <- policy_params$IEEPA_INVALIDATION_DATE
  if (!is.null(invalidation_date) && date >= invalidation_date) {
    message('  IEEPA invalidated as of this date, skipping ieepa_reciprocal.yaml')
    return(invisible(NULL))
  }

  # Extract country-level modal rates from the snapshot.
  country_rates <- snapshot %>%
    filter(rate_ieepa_recip > 0) %>%
    group_by(country) %>%
    summarise(
      rate = as.numeric(names(sort(table(rate_ieepa_recip), decreasing = TRUE))[1]),
      .groups = 'drop'
    )

  if (nrow(country_rates) == 0) {
    message('  No IEEPA reciprocal rates active, skipping')
    return(invisible(NULL))
  }

  # Build headline_rates (modal rate per country; most common rate as default)
  headline_rates <- list()
  rate_freq <- sort(table(country_rates$rate), decreasing = TRUE)
  default_rate <- as.numeric(names(rate_freq)[1])
  headline_rates[['default']] <- default_rate

  # Country-specific overrides for countries whose modal rate differs from default
  floor_countries <- as.character(policy_params$FLOOR_COUNTRIES %||%
    policy_params$floor_rates$floor_countries)
  floor_rate <- policy_params$FLOOR_RATE %||% policy_params$floor_rates$floor_rate %||% 0.15
  target_total_rules <- list()

  for (i in seq_len(nrow(country_rates))) {
    code <- country_rates$country[i]
    rate <- country_rates$rate[i]
    if (rate == default_rate) next
    mnemonic <- census_to_mnemonic(code, policy_params)
    headline_rates[[mnemonic]] <- rate
    if (code %in% floor_countries) {
      target_total_rules[[mnemonic]] <- floor_rate
    }
  }

  for (code in floor_countries) {
    mnemonic <- census_to_mnemonic(code, policy_params)
    if (is.null(target_total_rules[[mnemonic]])) {
      target_total_rules[[mnemonic]] <- floor_rate
    }
  }

  config <- list(headline_rates = headline_rates)

  # Exempt products (Annex A)
  exempt_file <- here::here('resources', 'ieepa_exempt_products.csv')
  if (file.exists(exempt_file)) {
    exempt <- read_csv(exempt_file, show_col_types = FALSE,
                        col_types = cols(.default = col_character()))
    config$exempt_products <- as.list(exempt$hts10)
    message(sprintf('  IEEPA exempt products: %d', length(config$exempt_products)))
  }

  if (length(target_total_rules) > 0) {
    config$target_total_rules <- target_total_rules
  }

  # =========================================================================
  # Lossless product_country_rates: emit overrides for every product×country
  # pair where the snapshot's rate_ieepa_recip differs from the headline rate.
  # This ensures ETRs produces the exact same rates as the tracker.
  # =========================================================================

  # Build headline lookup: country → headline rate
  headline_lookup <- country_rates %>%
    rename(headline_rate = rate)

  # For CA/MX, snapshot rates are post-USMCA. Reverse the adjustment before
  # comparing against headline. Only emit overrides for genuine rate deviations.
  usmca_codes <- c(
    policy_params$CTY_CANADA %||% '1220',
    policy_params$CTY_MEXICO %||% '2010'
  )

  # Load USMCA shares for reversing the adjustment on CA/MX
  usmca_year <- policy_params$USMCA_SHARES$year %||% '2025'
  usmca_file <- here::here(sprintf('resources/usmca_product_shares_%s.csv', usmca_year))
  usmca_shares_recip <- if (file.exists(usmca_file)) {
    read_csv(usmca_file, show_col_types = FALSE,
             col_types = cols(hts10 = col_character(), cty_code = col_character()))
  } else {
    tibble(hts10 = character(), cty_code = character(), usmca_share = numeric())
  }

  recip_data <- snapshot %>%
    filter(rate_ieepa_recip >= 0) %>%
    select(hts10, country, rate_ieepa_recip) %>%
    inner_join(headline_lookup, by = 'country')

  # Reverse USMCA for CA/MX to get pre-USMCA rate
  recip_data <- recip_data %>%
    left_join(usmca_shares_recip %>% select(hts10, cty_code, usmca_share),
              by = c('hts10', 'country' = 'cty_code')) %>%
    mutate(
      usmca_share = if_else(is.na(usmca_share), 0, usmca_share),
      pre_usmca_rate = if_else(
        country %in% usmca_codes & usmca_share < 1 - 1e-6,
        rate_ieepa_recip / (1 - usmca_share),
        rate_ieepa_recip
      )
    )

  deviations <- recip_data %>%
    filter(abs(pre_usmca_rate - headline_rate) > 0.005) %>%
    mutate(rate = round(pre_usmca_rate, 6)) %>%
    select(hts10, country, rate)

  # Group deviations by (country, rate) to create compact entries
  pcr <- list()

  if (nrow(deviations) > 0) {
    deviation_groups <- deviations %>%
      group_by(country, rate) %>%
      summarise(hts_codes = list(unique(hts10)), .groups = 'drop')

    for (i in seq_len(nrow(deviation_groups))) {
      grp <- deviation_groups[i, ]
      mnemonic <- census_to_mnemonic(grp$country, policy_params)
      pcr[[length(pcr) + 1]] <- list(
        hts = grp$hts_codes[[1]],
        country = mnemonic,
        rate = grp$rate
      )
    }

    message(sprintf('  IEEPA product_country_rates: %d override entries (%d product×country pairs)',
                    length(pcr), nrow(deviations)))
  }

  if (length(pcr) > 0) {
    config$product_country_rates <- pcr
  }

  write_yaml(config, file.path(output_dir, 'ieepa_reciprocal.yaml'))
  message(sprintf('  Wrote ieepa_reciprocal.yaml (%d countries, %d product overrides)',
                  length(headline_rates) - 1, nrow(deviations)))
}


# =============================================================================
# IEEPA Fentanyl YAML Generator
# =============================================================================

#' Generate ieepa_fentanyl.yaml, extracting rates from snapshot
generate_ieepa_fentanyl_yaml <- function(snapshot, date, policy_params, output_dir) {

  date <- as.Date(date)

  # Check IEEPA invalidation
  invalidation_date <- policy_params$IEEPA_INVALIDATION_DATE
  if (!is.null(invalidation_date) && date >= invalidation_date) {
    message('  IEEPA invalidated, skipping ieepa_fentanyl.yaml')
    return(invisible(NULL))
  }

  # Extract headline fentanyl rates from snapshot per country
  cty_china  <- policy_params$CTY_CHINA %||% '5700'
  cty_canada <- policy_params$CTY_CANADA %||% '1220'
  cty_mexico <- policy_params$CTY_MEXICO %||% '2010'

  extract_modal_fent <- function(cty) {
    if (!('rate_ieepa_fent' %in% names(snapshot))) return(0)
    rates <- snapshot %>% filter(country == cty, rate_ieepa_fent > 0) %>% pull(rate_ieepa_fent)
    if (length(rates) == 0) return(0)
    as.numeric(names(sort(table(rates), decreasing = TRUE))[1])
  }

  headline_rates <- list(
    default = 0,
    china   = extract_modal_fent(cty_china),
    canada  = extract_modal_fent(cty_canada),
    mexico  = extract_modal_fent(cty_mexico)
  )

  config <- list(headline_rates = headline_rates)

  # =========================================================================
  # Lossless product_country_rates: emit overrides for every product×country
  # pair where snapshot's rate_ieepa_fent differs from the headline rate.
  # =========================================================================

  # For CA/MX, snapshot rates are post-USMCA. Reverse the USMCA adjustment
  # to recover pre-USMCA rates, then compare against headline. Only emit
  # overrides for genuine rate deviations (e.g., fentanyl carve-outs at 10%).
  fent_countries <- c(cty_china, cty_canada, cty_mexico)
  usmca_codes <- c(cty_canada, cty_mexico)
  headline_lookup <- tibble(
    country = fent_countries,
    headline_rate = c(
      headline_rates$china %||% 0,
      headline_rates$canada %||% 0,
      headline_rates$mexico %||% 0
    )
  )

  # Load USMCA shares for reversing the adjustment
  usmca_year <- policy_params$USMCA_SHARES$year %||% '2025'
  usmca_file <- here::here(sprintf('resources/usmca_product_shares_%s.csv', usmca_year))
  usmca_shares <- if (file.exists(usmca_file)) {
    read_csv(usmca_file, show_col_types = FALSE,
             col_types = cols(hts10 = col_character(), cty_code = col_character()))
  } else {
    tibble(hts10 = character(), cty_code = character(), usmca_share = numeric())
  }

  if ('rate_ieepa_fent' %in% names(snapshot)) {
    fent_data <- snapshot %>%
      filter(country %in% fent_countries, rate_ieepa_fent >= 0) %>%
      select(hts10, country, rate_ieepa_fent) %>%
      inner_join(headline_lookup, by = 'country')

    # For USMCA countries, reverse the USMCA adjustment to get pre-USMCA rate
    fent_data <- fent_data %>%
      left_join(usmca_shares %>% select(hts10, cty_code, usmca_share),
                by = c('hts10', 'country' = 'cty_code')) %>%
      mutate(
        usmca_share = if_else(is.na(usmca_share), 0, usmca_share),
        pre_usmca_rate = if_else(
          country %in% usmca_codes & usmca_share < 1 - 1e-6,
          rate_ieepa_fent / (1 - usmca_share),
          rate_ieepa_fent
        )
      )

    # Deviation = pre-USMCA rate differs from headline (genuine rate difference)
    deviations <- fent_data %>%
      filter(abs(pre_usmca_rate - headline_rate) > 0.005) %>%
      mutate(rate = round(pre_usmca_rate, 6)) %>%
      select(hts10, country, rate)

    pcr <- list()
    if (nrow(deviations) > 0) {
      deviation_groups <- deviations %>%
        group_by(country, rate) %>%
        summarise(hts_codes = list(unique(hts10)), .groups = 'drop')

      for (i in seq_len(nrow(deviation_groups))) {
        grp <- deviation_groups[i, ]
        mnemonic <- census_to_mnemonic(grp$country, policy_params)
        pcr[[length(pcr) + 1]] <- list(
          hts = grp$hts_codes[[1]],
          country = mnemonic,
          rate = grp$rate
        )
      }
      message(sprintf('  Fentanyl product_country_rates: %d override entries (%d pairs)',
                      length(pcr), nrow(deviations)))
    }

    if (length(pcr) > 0) {
      config$product_country_rates <- pcr
    }
  }

  write_yaml(config, file.path(output_dir, 'ieepa_fentanyl.yaml'))
  message('  Wrote ieepa_fentanyl.yaml')
}


# =============================================================================
# Section 301 YAML Generator
# =============================================================================

#' Generate s301.yaml (China-only product-specific tariffs)
generate_s301_yaml <- function(date, policy_params, output_dir) {

  # Section 301 rates from policy_params
  s301_rates <- policy_params$SECTION_301_RATES %||% {
    rates_raw <- policy_params$section_301_rates
    if (is.null(rates_raw)) return(invisible(NULL))
    tibble(
      ch99_pattern = map_chr(rates_raw, ~ .x$ch99_pattern),
      s301_rate    = map_dbl(rates_raw, ~ .x$s301_rate)
    )
  }

  if (is.null(s301_rates) || nrow(s301_rates) == 0) {
    message('  No Section 301 rates configured, skipping')
    return(invisible(NULL))
  }

  # Load product lists
  s301_products_file <- here::here(
    policy_params$section_301_products$resource_file %||% 'resources/s301_product_lists.csv'
  )
  if (!file.exists(s301_products_file)) {
    message('  Section 301 product list not found, skipping')
    return(invisible(NULL))
  }

  s301_products <- read_csv(s301_products_file, show_col_types = FALSE,
                             col_types = cols(.default = col_character()))

  # Join products with rates (CSV has 'ch99_code', rates tibble has 'ch99_pattern')
  products_with_rates <- s301_products %>%
    left_join(s301_rates, by = c('ch99_code' = 'ch99_pattern')) %>%
    filter(!is.na(s301_rate))

  # For products with multiple ch99 codes, take max rate (Biden supersedes Trump)
  products_max <- products_with_rates %>%
    group_by(hts8) %>%
    summarise(rate = max(s301_rate), .groups = 'drop')

  # Group by rate level and create product_country_rates entries
  config <- list(
    headline_rates = list(default = 0)
  )

  pcr <- list()
  for (rate_val in sort(unique(products_max$rate))) {
    hts_codes <- products_max %>%
      filter(rate == rate_val) %>%
      pull(hts8)

    pcr[[length(pcr) + 1]] <- list(
      hts = as.list(hts_codes),
      country = 'china',
      rate = rate_val
    )
  }

  if (length(pcr) > 0) {
    config$product_country_rates <- pcr
  }

  write_yaml(config, file.path(output_dir, 's301.yaml'))
  message(sprintf('  Wrote s301.yaml (%d products across %d rate levels)',
                  nrow(products_max), length(unique(products_max$rate))))
}


# =============================================================================
# Section 122 YAML Generator
# =============================================================================

#' Generate s122.yaml (non-discriminatory blanket tariff with exemptions)
generate_s122_yaml <- function(date, policy_params, output_dir) {

  date <- as.Date(date)

  s122 <- policy_params$SECTION_122 %||% policy_params$section_122
  if (is.null(s122)) {
    message('  No Section 122 config, skipping')
    return(invisible(NULL))
  }

  effective <- as.Date(s122$effective_date)
  expiry <- as.Date(s122$expiry_date)
  finalized <- isTRUE(s122$finalized)

  # Check if S122 is in force at this date
  if (date < effective || (!finalized && date > expiry)) {
    message(sprintf('  Section 122 not in force on %s (effective %s, expiry %s)', date, effective, expiry))
    return(invisible(NULL))
  }

  # S122 rate: extract from snapshot or use a known default
  # The tracker extracts this from Ch99 entries (9903.03.xx)
  # For Phase 1, we don't have the HTS data here, so use a configurable rate.
  # TODO: Accept s122_rate as a parameter or add it to policy_params.yaml
  s122_rate <- s122$rate %||% 0.10

  config <- list(
    headline_rates = list(default = s122_rate)
  )

  # Exempt products (Annex II)
  exempt_file <- here::here(s122$exempt_products %||% 'resources/s122_exempt_products.csv')
  if (file.exists(exempt_file)) {
    exempt <- read_csv(exempt_file, show_col_types = FALSE,
                        col_types = cols(.default = col_character()))
    config$exempt_products <- as.list(exempt$hts8)
    message(sprintf('  S122 exempt products: %d', length(config$exempt_products)))
  }

  write_yaml(config, file.path(output_dir, 's122.yaml'))
  message(sprintf('  Wrote s122.yaml (rate=%.0f%%, %d exempt products)',
                  s122_rate * 100, length(config$exempt_products %||% list())))
}


# =============================================================================
# other_params.yaml Generator
# =============================================================================

#' Generate other_params.yaml with ETRs-compatible parameter pointers
generate_other_params_yaml <- function(date, policy_params, output_dir,
                                        etrs_resources_dir = NULL,
                                        active_s232_programs = NULL) {

  # Auto rebate params

  auto_rebate <- policy_params$auto_rebate %||% list()

  # MFN is now in the CSV (statutory_rates.csv.gz), but YAML-only configs
  # still need mfn_rates path. Include it as fallback.
  mfn_rates_abs <- file.path(output_dir, 'mfn_rates.csv')
  mfn_rates_path <- if (file.exists(mfn_rates_abs)) 'mfn_rates.csv' else 'resources/mfn_rates_2025.csv'

  # Build metal_programs and program_metal_types.
  # Only include programs that are actually active (present in s232.yaml).
  # Metal type mapping: steel chapters → steel, aluminum chapters → aluminum,
  # aluminum_derivatives → aluminum, copper → copper.
  metal_type_map <- list(
    steel = 'steel',
    aluminum = 'aluminum',
    aluminum_derivatives = 'aluminum',
    copper = 'copper'
  )

  metal_programs <- character(0)
  program_metal_types <- list()

  for (prog_name in names(metal_type_map)) {
    if (prog_name %in% (active_s232_programs %||% character(0))) {
      metal_programs <- c(metal_programs, prog_name)
      program_metal_types[[prog_name]] <- metal_type_map[[prog_name]]
    }
  }

  # Build usmca_exempt flags per s232 program (for CSV mode).
  # Steel/aluminum/derivatives are not USMCA-exempt; heading programs check config.
  usmca_exempt <- list()
  headings <- policy_params$section_232_headings %||% list()
  for (prog_name in (active_s232_programs %||% character(0))) {
    if (prog_name %in% c('steel', 'aluminum', 'aluminum_derivatives')) {
      usmca_exempt[[prog_name]] <- 0
    } else if (prog_name %in% names(headings)) {
      usmca_exempt[[prog_name]] <- if (isTRUE(headings[[prog_name]]$usmca_exempt)) 1 else 0
    } else {
      usmca_exempt[[prog_name]] <- 0
    }
  }

  config <- list(
    mfn_rates = mfn_rates_path,
    mfn_exemption_shares = 'resources/mfn_exemption_shares.csv',
    us_auto_content_share = auto_rebate$us_auto_content_share %||% 0.40,
    us_auto_assembly_share = auto_rebate$us_assembly_share %||% 0.33,
    auto_rebate_rate = auto_rebate$rebate_rate %||% 0.0375,
    ieepa_usmca_exception = 1,
    s122_usmca_exception = 0,
    s301_usmca_exception = 0,
    usmca_exempt = usmca_exempt,
    metal_content = list(
      method = 'bea',
      bea_table = 'total',
      bea_granularity = 'detail',
      primary_chapters = as.list(
        policy_params$metal_content$primary_chapters %||% c('72', '73', '76', '74')
      ),
      metal_programs = as.list(metal_programs),
      program_metal_types = program_metal_types
    )
  )

  # Shared resource paths — always written as ETRs-relative (resources/...) since
  # the generated config is consumed by ETRs, not by the tracker.
  usmca_year <- policy_params$USMCA_SHARES$year %||% '2025'
  usmca_shares_file <- here::here(sprintf('resources/usmca_product_shares_%s.csv', usmca_year))
  if (file.exists(usmca_shares_file)) {
    config$usmca_product_shares <- sprintf('resources/usmca_product_shares_%s.csv', usmca_year)
  }

  write_yaml(config, file.path(output_dir, 'other_params.yaml'))
  message('  Wrote other_params.yaml')
}


#' Export MFN rates from snapshot at HS8 level
#'
#' Extracts statutory_base_rate from the tracker snapshot and aggregates to
#' HS8 (matching ETRs' mfn_rates format). Uses the modal rate per HS8.
#'
#' @param snapshot Rate snapshot tibble
#' @param output_dir Directory to write mfn_rates.csv
export_mfn_rates <- function(snapshot, output_dir) {

  if (!('statutory_base_rate' %in% names(snapshot))) {
    message('  No statutory_base_rate in snapshot, skipping MFN export')
    return(invisible(NULL))
  }

  mfn <- snapshot %>%
    mutate(hs8 = substr(hts10, 1, 8)) %>%
    group_by(hs8) %>%
    summarise(
      mfn_rate = as.numeric(names(sort(table(statutory_base_rate), decreasing = TRUE))[1]),
      .groups = 'drop'
    ) %>%
    arrange(hs8)

  output_path <- file.path(output_dir, 'mfn_rates.csv')
  write_csv(mfn, output_path)
  message(sprintf('  Exported MFN rates: %d HS8 codes to %s', nrow(mfn), output_path))
  invisible(output_path)
}


# =============================================================================
# Helper Functions
# =============================================================================

#' Convert a Census country code to an ETRs mnemonic where possible
#'
#' Returns the mnemonic name (china, canada, mexico, eu, uk, japan, ftrow)
#' if the code belongs to a known group, otherwise returns the Census code.
census_to_mnemonic <- function(code, policy_params) {
  code <- as.character(code)

  # Direct single-country mappings
  if (code == policy_params$CTY_CHINA %||% '5700') return('china')
  if (code == policy_params$CTY_CANADA %||% '1220') return('canada')
  if (code == policy_params$CTY_MEXICO %||% '2010') return('mexico')
  if (code == policy_params$CTY_UK %||% '4120') return('uk')
  if (code == policy_params$CTY_JAPAN %||% '5880') return('japan')

  # EU-27: return the individual Census code (ETRs' 'eu' mnemonic expands to all 27)
  # We can't use 'eu' for individual members since it maps to ALL EU codes.
  # Return the code as-is for EU members.
  eu_codes <- as.character(policy_params$EU27_CODES %||% character(0))
  if (code %in% eu_codes) return(code)

  code
}


#' Resolve exemption country references to Census codes
resolve_exemption_countries <- function(countries, policy_params) {
  if (is.character(countries) && length(countries) == 1 && countries == 'eu') {
    return(as.character(policy_params$EU27_CODES))
  }
  as.character(unlist(countries))
}


#' Get floor country Census codes for a given country group
get_floor_country_codes <- function(group, policy_params) {
  eu_codes <- as.character(policy_params$EU27_CODES)

  switch(group,
    'eu'    = eu_codes,
    'japan' = as.character(policy_params$CTY_JAPAN %||% '5880'),
    'korea' = as.character(policy_params$CTY_SKOREA %||% '5800'),
    'swiss' = c(
      as.character(policy_params$CTY_SWITZERLAND %||% '4419'),
      as.character(policy_params$CTY_LIECHTENSTEIN %||% '4411')
    ),
    character(0)
  )
}


#' Get 232 deal rates for a specific program by examining the snapshot
#'
#' Identifies countries with deal rates (floor rates) by finding countries
#' where rate_232 on this program's products is consistently lower than
#' the program default. Returns a tibble with (country, rate) or NULL.
#'
#' @param prog_name Program name from section_232_headings
#' @param prog_prefixes Character vector of HTS prefixes for this program
#' @param default_rate The program's default rate
#' @param snapshot Rate snapshot tibble
#' @param policy_params Policy parameters
get_232_deal_rates <- function(prog_name, prog_prefixes, default_rate,
                                snapshot, policy_params) {

  if (is.null(snapshot) || !('rate_232' %in% names(snapshot)) || nrow(snapshot) == 0) {
    return(NULL)
  }

  # Filter snapshot to this program's products with active 232 rates
  prog_pattern <- paste0('^(', paste(prog_prefixes, collapse = '|'), ')')
  prog_data <- snapshot %>%
    filter(str_detect(hts10, prog_pattern), rate_232 > 0)

  if (nrow(prog_data) == 0) return(NULL)

  # Find the modal rate per country
  country_modal_rates <- prog_data %>%
    group_by(country) %>%
    summarise(
      modal_rate = as.numeric(names(sort(table(rate_232), decreasing = TRUE))[1]),
      .groups = 'drop'
    )

  # Countries with a rate lower than default have a deal (floor rate)
  deal_countries <- country_modal_rates %>%
    filter(modal_rate > 0, modal_rate < default_rate - 0.001)

  if (nrow(deal_countries) == 0) return(NULL)

  deal_countries %>%
    rename(rate = modal_rate)
}


# =============================================================================
# Main Execution (when sourced directly)
# =============================================================================

if (sys.nframe() == 0) {
  library(here)
  source(here('src', 'helpers.R'))

  # Parse command line args
  args <- commandArgs(trailingOnly = TRUE)

  if (length(args) < 2) {
    message('Usage: Rscript src/generate_etrs_config.R <date> <output_dir>')
    message('  date:       Policy date (YYYY-MM-DD)')
    message('  output_dir: Directory to write ETRs config files')
    message('')
    message('Example:')
    message('  Rscript src/generate_etrs_config.R 2026-04-01 ../Tariff-ETRs/config/baseline/2026-04-01')
    quit(status = 1)
  }

  date <- args[1]
  output_dir <- args[2]

  ts_path <- here('data', 'timeseries', 'rate_timeseries.rds')
  if (!file.exists(ts_path)) {
    stop('Timeseries not found at ', ts_path, '\nRun 00_build_timeseries.R first.')
  }

  ts <- readRDS(ts_path)
  generate_etrs_config(ts, date, output_dir)
}
