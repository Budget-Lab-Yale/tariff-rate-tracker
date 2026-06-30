# =============================================================================
# Data Loaders — resource file loaders for tariff programs
# =============================================================================
# Loads USMCA shares, MFN exemption shares, metal content, 232 derivatives,
# 232 annex products, fentanyl carveouts, and floor exemptions.
#
# Split from helpers.R. Sourced by helpers.R for backward compatibility.
# Direct consumers can source this file alone (requires policy_params.R).

library(tidyverse)
library(here)

load_232_derivative_products <- function(path = here('resources', 's232_derivative_products.csv'),
                                         effective_date = NULL) {
  if (!file.exists(path)) {
    message('  232 derivative products file not found: ', path)
    return(NULL)
  }

  products <- read_csv(path, col_types = cols(
    hts_prefix = col_character(),
    ch99_code = col_character(),
    derivative_type = col_character(),
    effective_date = col_date(format = '')
  ))

  # Filter by effective_date if provided
  if (!is.null(effective_date) && 'effective_date' %in% names(products)) {
    n_before <- nrow(products)
    products <- products %>%
      filter(is.na(effective_date) | effective_date <= !!effective_date)
    n_filtered <- n_before - nrow(products)
    if (n_filtered > 0) {
      message('  Filtered out ', n_filtered, ' derivative entries not yet effective at ', effective_date)
    }
  }

  message('  Loaded ', nrow(products), ' Section 232 derivative product prefixes')
  return(products)
}


#' Load the Section 232 steel/aluminum within-chapter product scope
#'
#' The chapter-99 US notes enumerate which chapter-72/73/76 provisions the
#' steel and aluminum 232 programs actually cover (note 16(b)/(m) steel,
#' note 19(b)/(j) aluminum in the 2025 editions). Pig iron (7201),
#' ferroalloys (7202), scrap (7204, 7602), cast-iron tubes (7303) etc. are
#' on NO list in any revision — treating chapters 72/73/76 as blanket
#' coverage over-applies the metals rate to them (eval residual deep-dive
#' 2026-06-12 item 2). Membership is date-gated: the 2018 article lists plus
#' Proc 9980 derivatives are always active; the Proc 10895/10896 derivative
#' expansions activate 2025-03-12; the BIS inclusions 2025-08-18.
#'
#' Annex-era revisions (April 2026 restructure) do NOT use this file — the
#' in-chapter scope there comes from s232_annex_products.csv (note 16(c)).
#'
#' @param path Path to s232_metal_chapter_products.csv
#' @param effective_date Revision (policy-swapped) date; rows with
#'   effective_date > this date are dropped, blank rows always kept
#' @return Tibble with hts_prefix, metal_type, kind columns, or NULL if the
#'   file is missing (caller decides whether that is fatal)
load_232_metal_chapter_products <- function(
  path = here('resources', 's232_metal_chapter_products.csv'),
  effective_date = NULL
) {
  if (!file.exists(path)) {
    message('  232 metal-chapter scope file not found: ', path)
    return(NULL)
  }

  scope <- read_csv(path, comment = '#', col_types = cols(
    hts_prefix = col_character(),
    metal_type = col_character(),
    kind = col_character(),
    effective_date = col_date(format = ''),
    source = col_character()
  ))

  if (!is.null(effective_date)) {
    n_before <- nrow(scope)
    scope <- scope %>%
      filter(is.na(effective_date) | effective_date <= !!effective_date)
    n_filtered <- n_before - nrow(scope)
    if (n_filtered > 0) {
      message('  Filtered out ', n_filtered,
              ' metal-chapter scope entries not yet effective at ', effective_date)
    }
  }

  message('  Loaded ', nrow(scope), ' Section 232 steel/aluminum scope prefixes')
  scope %>% select(hts_prefix, metal_type, kind)
}


#' Load the Taiwan civil-aircraft Section 232 exemption product list
#'
#' Products exempt from the Section 232 metals annex under U.S. note 35(c) /
#' heading 9903.96.03 (Taiwan civil-aircraft components), effective 2026 rev_9.
#' Extracted from the rev_9 Chapter 99 PDF (note 35(c) subdivision list).
#'
#' @param path Path to s232_aircraft_exempt_taiwan.csv
#' @return Character vector of HTS8 codes (empty if file missing)
load_232_aircraft_exempt_taiwan <- function(
  path = here('resources', 's232_aircraft_exempt_taiwan.csv')
) {
  if (!file.exists(path)) {
    warning('Taiwan aircraft 232 exemption file not found: ', path)
    return(character(0))
  }
  df <- read_csv(path, col_types = cols(.default = col_character()))
  unique(df$hts8)
}


#' Load civil-aircraft product lists that also exempt the Section 232 metals annex
#'
#' Some note-35 aircraft carve-outs were parsed into the floor-exemption resource.
#' Reuse those lists to remove only the metals-annex 232 rate; the reciprocal/floor
#' exemption path continues to handle the IEEPA side.
#'
#' @return Tibble with country and hts8 columns.
load_232_aircraft_exempt_floor_groups <- function(
  path = here('resources', 'floor_exempt_products.csv'),
  policy_params = NULL
) {
  if (!file.exists(path)) {
    warning('Aircraft floor-exemption source file not found: ', path)
    return(tibble(country = character(), hts8 = character()))
  }
  pp <- policy_params %||% load_policy_params()
  floor <- read_csv(path, col_types = cols(.default = col_character())) %>%
    filter(category == 'civil_aircraft')
  if (nrow(floor) == 0) return(tibble(country = character(), hts8 = character()))

  group_map <- bind_rows(
    tibble(country_group = 'eu', country = pp$EU27_CODES),
    tibble(country_group = 'korea', country = pp$country_codes$CTY_SKOREA),
    tibble(country_group = 'swiss', country = c(pp$country_codes$CTY_SWITZERLAND,
                                                pp$country_codes$CTY_LIECHTENSTEIN)),
    tibble(country_group = 'japan', country = pp$country_codes$CTY_JAPAN)
  )

  floor %>%
    inner_join(group_map, by = 'country_group', relationship = 'many-to-many') %>%
    transmute(country = as.character(country), hts8 = as.character(hts8)) %>%
    distinct()
}


#' Load floor country product exemptions
#'
#' Products exempt from the 15% tariff floor for EU, Japan, S. Korea,
#' Switzerland/Liechtenstein. Categories: PTAAP (agricultural/natural
#' resources), civil aircraft, non-patented pharmaceuticals. Parsed from
#' US Notes to Chapter 99 by scrape_us_notes.R --floor-exemptions.
#'
#' @param path Path to floor_exempt_products.csv
#' @param effective_date Optional revision (policy-swapped) date. The static
#'   file reflects the LATE-2025/2026 state of the deal carve-outs; rows carry
#'   effective_date_start = the text-publication date of each country group's
#'   floor structure (eu rev_24 2025-09-25, japan rev_23 2025-09-16, korea
#'   rev_32 2025-12-05, swiss 2026_basic 2026-01-01; retro windows not
#'   modeled, matching revision_dates.csv convention). Without this filter the
#'   static fallback exempted EU/Swiss/Korea carve-out products from the
#'   reciprocal tariff back to April 2025, months before any deal existed
#'   (~0.12pp overall ETR Apr-Sep 2025, TPC-corroborated).
#' @return Tibble with hts8, category, country_group, ch99_code; or empty tibble if missing
load_floor_exempt_products <- function(path = here('resources', 'floor_exempt_products.csv'),
                                       effective_date = NULL) {
  if (!file.exists(path)) {
    message('  Floor exempt products file not found: ', path)
    return(tibble(hts8 = character(), category = character(),
                  country_group = character(), ch99_code = character()))
  }

  products <- read_csv(path, col_types = cols(.default = col_character()))

  if (!is.null(effective_date) && 'effective_date_start' %in% names(products)) {
    n_before <- nrow(products)
    products <- products %>%
      filter(is.na(effective_date_start) |
               as.Date(effective_date_start) <= as.Date(effective_date))
    n_filtered <- n_before - nrow(products)
    if (n_filtered > 0) {
      message('  Filtered out ', n_filtered,
              ' floor exemptions not yet effective at ', effective_date)
    }
  }

  message('  Loaded ', nrow(products), ' floor exempt products (',
          n_distinct(products$hts8), ' unique HTS8)')
  return(products)
}


#' Load revision-specific floor country product exemptions
#'
#' Tries per-revision file first (data/us_notes/floor_exempt_{revision}.csv),
#' then falls back to the static resources/floor_exempt_products.csv
#' (date-filtered when effective_date is supplied — see
#' load_floor_exempt_products()).
#'
#' @param revision_id Character revision ID (e.g., 'rev_18', '2026_basic')
#' @param effective_date Optional revision (policy-swapped) date for the
#'   static-fallback date filter. Per-revision files are already
#'   revision-correct and are not filtered.
#' @return Tibble with hts8, category, country_group, ch99_code; or empty tibble
load_revision_floor_exemptions <- function(revision_id, effective_date = NULL) {
  # Try per-revision file first
  revision_path <- here('data', 'us_notes', paste0('floor_exempt_', revision_id, '.csv'))
  if (file.exists(revision_path)) {
    products <- read_csv(revision_path, col_types = cols(.default = col_character()))
    message('  Loaded ', nrow(products), ' floor exempt products for ', revision_id,
            ' (', n_distinct(products$hts8), ' unique HTS8)')
    return(products)
  }

  # Fall back to static file
  message('  No per-revision floor exemptions for ', revision_id,
          '; using static fallback')
  return(load_floor_exempt_products(effective_date = effective_date))
}


#' Load product-level USMCA utilization shares from USITC DataWeb SPI data
#'
#' Per-HTS10 x country USMCA shares from DataWeb SPI programs S/S+.
#' Generated by tools/download_usmca_dataweb.R.
#' Returns NULL if file not found (triggers fallback to binary eligibility).
#'
#' Modes (from policy_params$USMCA_SHARES$mode):
#'   'h2_average' (default): averages months 7-12 of the configured year. Reflects post-tariff
#'      steady-state USMCA utilization (CA ~85-88%, MX ~85-88%) without monthly noise.
#'   'annual': loads resources/usmca_product_shares_{year}.csv
#'   'monthly': loads resources/usmca_product_shares_{year}_{MM}.csv based on effective_date
#'   'fixed_month': loads resources/usmca_product_shares_{year}_{MM}.csv using configured month
#'   'hybrid_rolling': Q1 average for Jan-Mar, 3-month rolling average (m, m-1, m-2) from April.
#'      Smooths the mid-2025 USMCA utilization jump while capturing the behavioral shift.
#'      Rolling uses available months only; falls back to annual if no monthly files found.
#'
#' @param policy_params Policy params list (uses usmca_shares mode/year)
#' @param path Override path (ignores mode/year selection if provided)

load_usmca_product_shares <- function(policy_params = NULL, path = NULL, effective_date = NULL) {
  if (is.null(path)) {
    mode <- policy_params$USMCA_SHARES$mode %||% 'annual'
    year <- policy_params$USMCA_SHARES$year %||% NULL

    if (mode == 'none') {
      # Scenario: assume 0% USMCA utilization for every CA/MX product-country pair.
      # Return an empty tibble with the correct schema. The caller in
      # src/pipeline/06_calculate_rates.R reads `pp$USMCA_SHARES$mode` directly and
      # short-circuits the USMCA application block entirely when mode == 'none',
      # so this tibble is never joined against real rates.
      message('  USMCA mode = none: treating all CA/MX pairs as 0% utilization')
      return(tibble(
        hts10 = character(0),
        cty_code = character(0),
        usmca_share = numeric(0)
      ))
    }

    if (mode == 'h2_average') {
      # Average months 7-12: post-tariff steady-state USMCA utilization
      year <- year %||% 2025L
      monthly_shares <- list()
      for (m in 7L:12L) {
        m_path <- here('resources', sprintf('usmca_product_shares_%d_%02d.csv', year, m))
        if (file.exists(m_path)) {
          monthly_shares[[length(monthly_shares) + 1L]] <- read_csv(
            m_path, col_types = cols(.default = col_guess(),
                                     hts10 = col_character(), cty_code = col_character(),
                                     usmca_share = col_double()), show_col_types = FALSE
          )
        }
      }
      if (length(monthly_shares) > 0) {
        combined <- bind_rows(monthly_shares)
        has_values <- all(c('total_value', 'usmca_value') %in% names(combined))
        if (has_values) {
          # Value-weighted aggregation: sum(usmca_value) / sum(total_value).
          # Zero-trade pairs get NA (not 0): a code with no H2 trade carries
          # no claim signal — e.g. statistical splits introduced after 2025
          # (2709.00.20.10) defaulted to share 0 -> full CA/MX rate
          # (extreme-eta review item 6). The application step in
          # 06_calculate_rates.R falls back to the HS8-level share (attached
          # below as attr 'hs8_shares') before defaulting to 0.
          combined <- combined %>%
            group_by(hts10, cty_code) %>%
            summarise(
              total_value = sum(total_value, na.rm = TRUE),
              usmca_value = sum(usmca_value, na.rm = TRUE),
              .groups = 'drop'
            ) %>%
            mutate(
              usmca_share = if_else(total_value > 0,
                                    usmca_value / total_value,
                                    NA_real_)
            )
          hs8_shares <- combined %>%
            group_by(hts8 = substr(hts10, 1, 8), cty_code) %>%
            summarise(
              usmca_share_hs8 = if_else(sum(total_value) > 0,
                                        sum(usmca_value) / sum(total_value),
                                        NA_real_),
              .groups = 'drop'
            ) %>%
            filter(!is.na(usmca_share_hs8))
          combined <- combined %>% select(hts10, cty_code, usmca_share)
          attr(combined, 'hs8_shares') <- hs8_shares
          message('  Loaded USMCA H2 average (value-weighted): ', nrow(combined),
                  ' product-country pairs (', length(monthly_shares), ' months, Jul-Dec ', year,
                  '); HS8 fallback table: ', nrow(hs8_shares), ' pairs')
        } else {
          # Fallback: simple average of ratios (legacy monthly CSVs without value columns)
          combined <- combined %>%
            group_by(hts10, cty_code) %>%
            summarise(usmca_share = mean(usmca_share, na.rm = TRUE), .groups = 'drop')
          message('  Loaded USMCA H2 average (ratio-averaged, no value cols): ', nrow(combined),
                  ' product-country pairs (', length(monthly_shares), ' months, Jul-Dec ', year, ')')
        }
        return(combined)
      } else {
        message('  No H2 monthly USMCA files found for ', year, ' — falling back to annual')
        path <- here('resources', paste0('usmca_product_shares_', year, '.csv'))
      }

    } else if (mode == 'since') {
      # Average every monthly file from a FIXED START (start_year/start_month)
      # through the most recent month present on disk, value-weighted. Like
      # h2_average (time-invariant across revisions, value-weighted, with the
      # HS8 fallback) but the window has a fixed left edge and an OPEN right edge
      # that auto-extends as new months land. Baseline: start 2025-07 (same July
      # left edge as h2_average) through the latest available (2025-07 .. 2026-02
      # as of this writing; 2026-03+ fold in automatically with no config change).
      # Spans the year boundary, so it keeps the 2025 sample size while folding in
      # the freshest 2026 claiming behavior. Falls back to the start year's annual
      # file if no monthly files are present in the window.
      start_year  <- policy_params$USMCA_SHARES$start_year  %||% 2025L
      start_month <- policy_params$USMCA_SHARES$start_month %||% 7L
      # Enumerate candidate months from the start through a generous horizon and
      # keep only those with a file — the newest present file is the de-facto end.
      end_year <- as.integer(start_year) + 5L
      monthly_shares <- list()
      used_labels <- character(0)
      for (yy in as.integer(start_year):end_year) {
        for (mm in 1L:12L) {
          if (yy == as.integer(start_year) && mm < as.integer(start_month)) next
          m_path <- here('resources', sprintf('usmca_product_shares_%d_%02d.csv', yy, mm))
          if (file.exists(m_path)) {
            monthly_shares[[length(monthly_shares) + 1L]] <- read_csv(
              m_path, col_types = cols(.default = col_guess(),
                                       hts10 = col_character(), cty_code = col_character(),
                                       usmca_share = col_double()), show_col_types = FALSE
            )
            used_labels <- c(used_labels, sprintf('%d-%02d', yy, mm))
          }
        }
      }
      if (length(monthly_shares) > 0) {
        combined <- bind_rows(monthly_shares)
        has_values <- all(c('total_value', 'usmca_value') %in% names(combined))
        win_label <- paste0(used_labels[1], '..', used_labels[length(used_labels)])
        if (has_values) {
          # Value-weighted aggregation, identical to h2_average: sum over the
          # window so a thin month doesn't get equal weight to a heavy-trade
          # month. Zero-trade pairs -> NA (no claim signal), so the
          # 06_calculate_rates.R application falls back to the HS8 share then 0.
          combined <- combined %>%
            group_by(hts10, cty_code) %>%
            summarise(
              total_value = sum(total_value, na.rm = TRUE),
              usmca_value = sum(usmca_value, na.rm = TRUE),
              .groups = 'drop'
            ) %>%
            mutate(
              usmca_share = if_else(total_value > 0,
                                    usmca_value / total_value,
                                    NA_real_)
            )
          hs8_shares <- combined %>%
            group_by(hts8 = substr(hts10, 1, 8), cty_code) %>%
            summarise(
              usmca_share_hs8 = if_else(sum(total_value) > 0,
                                        sum(usmca_value) / sum(total_value),
                                        NA_real_),
              .groups = 'drop'
            ) %>%
            filter(!is.na(usmca_share_hs8))
          combined <- combined %>% select(hts10, cty_code, usmca_share)
          attr(combined, 'hs8_shares') <- hs8_shares
          message('  Loaded USMCA since-window (value-weighted): ', nrow(combined),
                  ' product-country pairs (', length(monthly_shares), ' months, ',
                  win_label, '); HS8 fallback table: ', nrow(hs8_shares), ' pairs')
        } else {
          # Legacy monthly CSVs without value columns: simple ratio average.
          combined <- combined %>%
            group_by(hts10, cty_code) %>%
            summarise(usmca_share = mean(usmca_share, na.rm = TRUE), .groups = 'drop')
          message('  Loaded USMCA since-window (ratio-averaged, no value cols): ', nrow(combined),
                  ' product-country pairs (', length(monthly_shares), ' months, ', win_label, ')')
        }
        return(combined)
      } else {
        message('  No monthly USMCA files found since ', start_year, '-',
                sprintf('%02d', as.integer(start_month)), ' (since) — falling back to annual')
        path <- here('resources', paste0('usmca_product_shares_', start_year, '.csv'))
      }

    } else if (mode == 'fixed_month') {
      fixed_month <- policy_params$USMCA_SHARES$month %||% 12L
      year <- year %||% 2025L
      monthly_path <- here('resources', sprintf('usmca_product_shares_%d_%02d.csv', year, as.integer(fixed_month)))
      if (file.exists(monthly_path)) {
        path <- monthly_path
      } else {
        message('  Fixed-month USMCA file not found for ', year, '-', sprintf('%02d', fixed_month),
                ' — falling back to annual')
        path <- here('resources', paste0('usmca_product_shares_', year, '.csv'))
      }
    } else if (mode == 'hybrid_rolling' && !is.null(effective_date)) {
      # Q1 average for Jan-Mar; 3-month rolling (m, m-1, m-2) from April onward
      eff <- as.Date(effective_date)
      year <- year %||% as.integer(format(eff, '%Y'))
      month_num <- as.integer(format(eff, '%m'))
      if (eff < as.Date(paste0(year, '-01-01'))) month_num <- 1L
      if (eff > as.Date(paste0(year, '-12-31'))) month_num <- 12L

      if (month_num <= 3L) {
        # Q1: average all available months 1-3
        window <- 1L:3L
      } else {
        # Rolling: months m, m-1, m-2
        window <- (month_num - 2L):month_num
      }

      # Load available monthly files in the window
      monthly_shares <- list()
      for (m in window) {
        m_path <- here('resources', sprintf('usmca_product_shares_%d_%02d.csv', year, m))
        if (file.exists(m_path)) {
          monthly_shares[[length(monthly_shares) + 1L]] <- read_csv(
            m_path, col_types = cols(hts10 = col_character(), cty_code = col_character(),
                                     usmca_share = col_double()), show_col_types = FALSE
          )
        }
      }

      if (length(monthly_shares) > 0) {
        combined <- bind_rows(monthly_shares)
        has_values <- all(c('total_value', 'usmca_value') %in% names(combined))
        window_label <- paste0(sprintf('%02d', window[1]), '-', sprintf('%02d', window[length(window)]))
        if (has_values) {
          combined <- combined %>%
            group_by(hts10, cty_code) %>%
            summarise(
              usmca_share = if_else(sum(total_value, na.rm = TRUE) > 0,
                                    sum(usmca_value, na.rm = TRUE) / sum(total_value, na.rm = TRUE),
                                    0),
              .groups = 'drop'
            )
          message('  Loaded USMCA hybrid rolling (value-weighted): ', nrow(combined),
                  ' product-country pairs (', length(monthly_shares), ' months in window ',
                  window_label, ')')
        } else {
          combined <- combined %>%
            group_by(hts10, cty_code) %>%
            summarise(usmca_share = mean(usmca_share, na.rm = TRUE), .groups = 'drop')
          message('  Loaded USMCA hybrid rolling (ratio-averaged): ', nrow(combined),
                  ' product-country pairs (', length(monthly_shares), ' months in window ',
                  window_label, ')')
        }
        return(combined)
      } else {
        message('  No monthly USMCA files found for hybrid rolling — falling back to annual')
        path <- here('resources', paste0('usmca_product_shares_', year, '.csv'))
      }

    } else if (mode == 'monthly' && !is.null(effective_date)) {
      eff <- as.Date(effective_date)
      target_year  <- as.integer(format(eff, '%Y'))
      target_month <- as.integer(format(eff, '%m'))

      # Walk backward to collect available monthly files. The first file found
      # is the primary share source for trade-active pairs; subsequent files
      # are fallback for pairs missing from the primary (typical for early-
      # year YTD queries where DataWeb's universe is narrower than the prior
      # year's any-month universe — ~9k tail HTS10s drop out of 2026_01 vs
      # 2025_12 for example, ~$3.5B of 2024 import value at ~90% historical
      # USMCA share). Cap at 6 monthly files of fallback to avoid using
      # very stale shares; cap walkback at 120 steps (10 years) to find the
      # primary even if there's a publication gap.
      files_to_load <- character(0)
      primary_y <- NA_integer_; primary_m <- NA_integer_
      y <- target_year; m <- target_month
      for (step in seq_len(120L)) {
        candidate <- here('resources', sprintf('usmca_product_shares_%d_%02d.csv', y, m))
        if (file.exists(candidate)) {
          files_to_load <- c(files_to_load, candidate)
          if (length(files_to_load) == 1L) {
            primary_y <- y; primary_m <- m
          }
          if (length(files_to_load) >= 6L) break
        }
        m <- m - 1L
        if (m < 1L) { m <- 12L; y <- y - 1L }
      }

      if (length(files_to_load) > 0L) {
        if (primary_y != target_year || primary_m != target_month) {
          message(sprintf('  Monthly USMCA file not found for %d-%02d — using most recent available: %d-%02d',
                          target_year, target_month, primary_y, primary_m))
        }
        primary <- read_csv(files_to_load[1L], col_types = cols(
          hts10 = col_character(), cty_code = col_character(),
          usmca_share = col_double(), .default = col_guess()
        ), show_col_types = FALSE)
        if (length(files_to_load) > 1L) {
          augmented <- primary
          for (extra in files_to_load[-1L]) {
            prior <- read_csv(extra, col_types = cols(
              hts10 = col_character(), cty_code = col_character(),
              usmca_share = col_double(), .default = col_guess()
            ), show_col_types = FALSE)
            new_rows <- prior %>% anti_join(augmented, by = c('hts10', 'cty_code'))
            if (nrow(new_rows) > 0L) augmented <- bind_rows(augmented, new_rows)
          }
          n_fill <- nrow(augmented) - nrow(primary)
          if (n_fill > 0L) {
            message(sprintf('  USMCA monthly: augmented primary %s with %d fallback rows from %d prior month(s)',
                            basename(files_to_load[1L]), n_fill, length(files_to_load) - 1L))
          }
          message('  Loaded USMCA product shares (with fallback): ', nrow(augmented),
                  ' product-country pairs')
          return(augmented)
        }
        message('  Loaded USMCA product shares: ', nrow(primary),
                ' product-country pairs from ', basename(files_to_load[1L]))
        return(primary)
      } else {
        message('  No monthly USMCA files found — falling back to annual')
        path <- here('resources', paste0('usmca_product_shares_',
                                          year %||% target_year, '.csv'))
      }
    } else {
      if (!is.null(year)) {
        path <- here('resources', paste0('usmca_product_shares_', year, '.csv'))
      } else {
        path <- here('resources', 'usmca_product_shares.csv')
      }
    }
  }
  if (!file.exists(path)) {
    message('  USMCA product shares file not found — using binary eligibility')
    return(NULL)
  }
  shares <- read_csv(path, col_types = cols(
    hts10 = col_character(),
    cty_code = col_character(),
    usmca_share = col_double()
  ))
  message('  Loaded USMCA product shares: ', nrow(shares),
          ' product-country pairs from ', basename(path))
  return(shares)
}


#' Load MFN exemption shares (FTA/GSP preference utilization)
#'
#' HS2 x country exemption shares computed from Census calculated duty data.
#' effective_mfn = mfn_rate * (1 - exemption_share).
#' Sourced from Tariff-ETRs project. Returns NULL if file not found.
#'
#' @param path Path to mfn_exemption_shares.csv

load_mfn_exemption_shares <- function(path = here('resources', 'mfn_exemption_shares.csv')) {
  if (!file.exists(path)) {
    message('  MFN exemption shares file not found — using statutory base rates')
    return(NULL)
  }
  shares <- read_csv(path, col_types = cols(
    hs2 = col_character(),
    cty_code = col_character(),
    exemption_share = col_double()
  ))
  # Clamp exemption shares to [0, 1]
  shares <- shares %>%
    mutate(exemption_share = pmin(pmax(exemption_share, 0), 1))
  message('  Loaded MFN exemption shares: ', nrow(shares), ' HS2-country pairs')
  return(shares)
}


#' Load fentanyl carve-out product lists
#'
#' Product-specific fentanyl rate carve-outs: energy/critical minerals (CA) and
#' potash (CA/MX) receive a lower fentanyl rate than the general blanket.
#' Product lists sourced from Tariff-ETRs config (US Note 2 subdivisions).
#'
#' @param path Path to fentanyl_carveout_products.csv

load_fentanyl_carveouts <- function(path = here('resources', 'fentanyl_carveout_products.csv')) {
  if (!file.exists(path)) {
    message('  Fentanyl carve-out products file not found: ', path)
    return(NULL)
  }

  carveouts <- read_csv(path, col_types = cols(
    hts8 = col_character(),
    ch99_code = col_character(),
    category = col_character()
  ))

  message('  Loaded ', nrow(carveouts), ' fentanyl carve-out product prefixes (',
          n_distinct(carveouts$category), ' categories)')
  return(carveouts)
}


#' Load metal content shares for Section 232 derivative products
#'
#' For derivative 232 products, the tariff applies only to the metal content
#' portion of customs value. This function returns per-product metal shares.
#'
#' Three methods:
#'   flat: All derivative products get metal_share = flat_share (default 0.50)
#'   cbo:  Product-level buckets from resources/cbo/ files
#' Load Section 232 annex product classification
#'
#' Reads the annex product mapping from the static resource file. Returns a
#' tibble with hts_prefix and s232_annex columns for prefix-matching in
#' 06_calculate_rates.R. When the resource file is empty (header only), returns
#' an empty tibble — the annex rate override step becomes a no-op.
#'
#' @param effective_date Date to filter entries by effective_date column
#' @param resource_path Path to s232_annex_products.csv

load_annex_products <- function(effective_date = NULL,
                                resource_path = here('resources', 's232_annex_products.csv')) {
  if (!file.exists(resource_path)) {
    return(tibble(hts_prefix = character(), s232_annex = character()))
  }

  annex_map <- read_csv(resource_path, col_types = cols(.default = col_character()))

  if (nrow(annex_map) == 0) {
    message('  Annex products: resource file empty (pending HTS JSON)')
    return(tibble(hts_prefix = character(), s232_annex = character()))
  }

  # Filter by effective_date if column is present
  if ('effective_date' %in% names(annex_map) && !is.null(effective_date)) {
    annex_map <- annex_map %>%
      filter(is.na(effective_date) | effective_date <= as.character(!!effective_date))
  }

  annex_map %>%
    mutate(
      .effective_date = suppressWarnings(as.Date(effective_date)),
      .effective_date = coalesce(.effective_date, as.Date('1900-01-01'))
    ) %>%
    arrange(hts_prefix, desc(.effective_date)) %>%
    select(hts_prefix, s232_annex = annex) %>%
    mutate(s232_annex = paste0('annex_', s232_annex)) %>%
    distinct(hts_prefix, .keep_all = TRUE)
}


#' Classify HTS10 codes into §232 annex tiers (annex_1a / annex_1b / annex_2 /
#' annex_3, or NA for unclassified).
#'
#' SINGLE SOURCE OF TRUTH for the §232 annex classification. Called by the
#' calculator (06_calculate_rates.R, step 5c) and — once the annex rates are
#' relocated into the spec — by the adapter (authority_adapter.R). Keeping ONE
#' implementation guarantees the calc and the spec can never drift on this logic.
#'
#' Two arms:
#'   1. longest-prefix-first, first-match-wins against the (already date-gated)
#'      annex prefix map, then
#'   2. inference for products the CSV did not match: pre-annex §232
#'      derivatives -> annex_1b.
#'
#' There is deliberately NO chapter-based inference. The annex CSV is complete
#' for the metal chapters (every note-16(c) article/derivative heading is in
#' it, source us_note_16), so a chapter-72/73/74/76 product the CSV does not
#' match is OUT of §232 scope — pig iron (7201), ferroalloys (7202), scrap
#' (7204/7602), refined copper cathodes (7402/7403). The former
#' `annex_1a_chapters` inference arm charged all of those 50% (verified in
#' vintage 2026-06-11-17: 7204 and 7403 annex_1a at 0.499 mean rate), the
#' annex-era continuation of the pre-annex blanket-chapter over-application
#' (eval residual deep-dive 2026-06-12 item 2).
#'
#' The longest-prefix-first sort + is.na() guard implement first-match-wins;
#' do not reorder.
#'
#' @param hts10            HTS10 codes to classify (any order; deduped internally)
#' @param annex_map        load_annex_products() output (hts_prefix, s232_annex)
#' @param deriv_products   §232 derivative products tibble (hts_prefix col) or NULL
#' @return character vector of annex tiers aligned to `hts10` (NA = unclassified)
classify_s232_annex <- function(hts10, annex_map, deriv_products = NULL) {
  keys <- unique(as.character(hts10))
  tier <- rep(NA_character_, length(keys))

  # 1. longest-prefix-first, first-match-wins (the is.na() guard keeps the first
  #    assignment, which respects the longest-first sort).
  if (!is.null(annex_map) && nrow(annex_map) > 0) {
    pat <- annex_map %>%
      mutate(pattern = paste0('^', hts_prefix)) %>%
      arrange(desc(nchar(hts_prefix)))
    for (i in seq_len(nrow(pat))) {
      mask <- grepl(pat$pattern[i], keys)
      tier[mask & is.na(tier)] <- pat$s232_annex[i]
    }
  }

  # 2. inference for unmatched pre-annex derivatives.
  deriv_prefixes <- tryCatch(
    if (!is.null(deriv_products)) deriv_products$hts_prefix else character(0),
    error = function(e) character(0)
  )
  deriv_hit <- if (length(deriv_prefixes) > 0) {
    grepl(paste0('^(', paste(deriv_prefixes, collapse = '|'), ')'), keys)
  } else rep(FALSE, length(keys))

  tier <- dplyr::case_when(
    !is.na(tier) ~ tier,
    deriv_hit    ~ 'annex_1b',
    TRUE         ~ tier
  )

  tier[match(as.character(hts10), keys)]
}


#'         (high=0.75, low=0.25, copper=0.90)
#'   bea:  HS10-level shares from BEA 2017 Detail I-O table
#'         (resources/metal_content_shares_bea_hs10.csv)
#'
#' Products in primary_chapters (72, 73, 76) always get metal_share = 1.0.
#' Non-derivative products outside primary chapters get metal_share = 1.0
#' (no metal adjustment — they don't have 232 rates).
#'
#' @param metal_cfg Metal content config list from policy_params.yaml
#' @param hts10_codes Character vector of HTS10 codes to compute shares for
#' @param derivative_hts10 Character vector of HTS10 codes identified as 232
#'   derivatives. Only these products receive metal_share < 1.0.
#' @return Tibble with hts10 and metal_share columns
load_metal_content <- function(metal_cfg = NULL, hts10_codes = character(0),
                               derivative_hts10 = character(0)) {
  if (length(hts10_codes) == 0) {
    return(tibble(hts10 = character(), metal_share = numeric(),

                  steel_share = numeric(), aluminum_share = numeric(),
                  copper_share = numeric(), other_metal_share = numeric()))
  }

  method <- if (!is.null(metal_cfg)) metal_cfg$method %||% 'flat' else 'flat'
  flat_share <- if (!is.null(metal_cfg)) metal_cfg$flat_share %||% 0.50 else 0.50
  primary_chapters <- if (!is.null(metal_cfg)) unlist(metal_cfg$primary_chapters) else c('72', '73', '76')

  # Start with all products at metal_share = 1.0 (full metal / no adjustment)
  # and zero-filled per-type columns. The zero-filled schema keeps bind_rows()
  # stable across revisions; downstream logic decides whether these per-type
  # shares are informative enough to use.
  result <- tibble(
    hts10 = hts10_codes,
    metal_share = 1.0,
    steel_share = 0,
    aluminum_share = 0,
    copper_share = 0,
    other_metal_share = 0
  )

  # Flag derivative products — only these get metal_share < 1.0
  is_derivative <- result$hts10 %in% derivative_hts10

  if (sum(is_derivative) == 0) {
    message('  Metal content: no derivative products to adjust')
    return(result)
  }

  if (method == 'flat') {
    result$metal_share[is_derivative] <- flat_share
    message('  Metal content: flat method (', round(flat_share * 100),
            '% for ', sum(is_derivative), ' derivatives)')

  } else if (method == 'cbo') {
    cbo_high_share <- if (!is.null(metal_cfg)) metal_cfg$cbo_high_share %||% 0.75 else 0.75
    cbo_low_share <- if (!is.null(metal_cfg)) metal_cfg$cbo_low_share %||% 0.25 else 0.25
    cbo_copper_share <- if (!is.null(metal_cfg)) metal_cfg$cbo_copper_share %||% 0.90 else 0.90

    # Load CBO bucket files
    cbo_dir <- here('resources', 'cbo')
    high_path <- file.path(cbo_dir, 'alst_deriv_h.csv')
    low_path <- file.path(cbo_dir, 'alst_deriv_l.csv')
    copper_path <- file.path(cbo_dir, 'copper.csv')

    cbo_shares <- tibble(hts10 = character(), metal_share = numeric())

    if (file.exists(copper_path)) {
      copper <- read_csv(copper_path, col_types = cols(I_COMMODITY = col_character()))
      cbo_shares <- bind_rows(cbo_shares,
        tibble(hts10 = copper$I_COMMODITY, metal_share = cbo_copper_share))
    }
    if (file.exists(high_path)) {
      high <- read_csv(high_path, col_types = cols(I_COMMODITY = col_character()))
      cbo_shares <- bind_rows(cbo_shares,
        tibble(hts10 = high$I_COMMODITY, metal_share = cbo_high_share))
    }
    if (file.exists(low_path)) {
      low <- read_csv(low_path, col_types = cols(I_COMMODITY = col_character()))
      cbo_shares <- bind_rows(cbo_shares,
        tibble(hts10 = low$I_COMMODITY, metal_share = cbo_low_share))
    }

    # Priority: copper > high > low (first match kept)
    cbo_shares <- cbo_shares %>%
      distinct(hts10, .keep_all = TRUE)

    # Only apply CBO shares to derivative products
    result <- result %>%
      left_join(cbo_shares %>% rename(cbo_share = metal_share), by = 'hts10') %>%
      mutate(
        metal_share = case_when(
          !is_derivative ~ 1.0,               # non-derivatives stay at 1.0
          !is.na(cbo_share) ~ cbo_share,      # CBO match for derivatives
          TRUE ~ flat_share                    # fallback to flat for unmatched derivatives
        )
      ) %>%
      select(-cbo_share)

    n_cbo <- sum(!is.na(cbo_shares$hts10[cbo_shares$hts10 %in% derivative_hts10]))
    message('  Metal content: CBO method (', n_cbo, ' of ', sum(is_derivative),
            ' derivatives matched; high=', cbo_high_share, ', low=', cbo_low_share,
            ', copper=', cbo_copper_share, ')')

  } else if (method == 'bea') {
    # BEA I-O table shares at HS10 level (per-metal-type detail).
    # File generated by Tariff-ETRs build_metal_content_shares.R from 2017 BEA
    # Detail Use Table and HS10->NAICS->BEA crosswalk chain.
    bea_path <- here('resources', 'metal_content_shares_bea_hs10.csv')
    if (!file.exists(bea_path)) {
      stop('BEA metal content file not found: ', bea_path,
           '\nCopy from Tariff-ETRs or switch to flat/cbo method.')
    }

    bea_shares <- read_csv(bea_path, col_types = cols(
      hs10 = col_character(),
      .default = col_double()
    )) %>%
      select(hts10 = hs10,
             bea_steel = steel_share, bea_aluminum = aluminum_share,
             bea_copper = copper_share, bea_other = other_metal_share,
             bea_metal = metal_share)

    # metal_share gated on is_derivative (only derivatives get < 1.0).
    # Per-type shares populated for ALL BEA-matched products: copper heading
    # scaling needs copper_share on non-derivative ch74 products; stacking
    # guards on rate_232 > 0 so non-232 products are unaffected.
    result <- result %>%
      left_join(bea_shares, by = 'hts10') %>%
      mutate(
        metal_share = case_when(
          !is_derivative ~ 1.0,              # non-derivatives stay at 1.0
          !is.na(bea_metal) ~ bea_metal,     # BEA match for derivatives
          TRUE ~ flat_share                   # fallback to flat for unmatched derivatives
        ),
        steel_share       = pmin(if_else(!is.na(bea_steel), bea_steel, 0), 1.0),
        aluminum_share    = pmin(if_else(!is.na(bea_aluminum), bea_aluminum, 0), 1.0),
        copper_share      = pmin(if_else(!is.na(bea_copper), bea_copper, 0), 1.0),
        other_metal_share = pmin(if_else(!is.na(bea_other), bea_other, 0), 1.0)
      ) %>%
      select(-starts_with('bea_'))

    n_bea <- sum(bea_shares$hts10 %in% derivative_hts10)
    message('  Metal content: BEA method (', n_bea, ' of ', sum(is_derivative),
            ' derivatives matched; fallback=', flat_share, ')')

  } else {
    warning('Unknown metal_content method: ', method, '. Using flat fallback.')
    result$metal_share[is_derivative] <- flat_share
  }

  # Force primary chapters (72, 73, 76) to metal_share = 1.0 regardless of
  # derivative flag. These are base metal products — the tariff applies to
  # their full customs value, not a metal content fraction.
  #
  is_primary <- substr(result$hts10, 1, 2) %in% primary_chapters
  if (any(is_primary)) {
    result$metal_share[is_primary] <- 1.0
    result$steel_share[is_primary] <- 0
    result$aluminum_share[is_primary] <- 0
    result$copper_share[is_primary] <- 0
    result$other_metal_share[is_primary] <- 0
  }

  return(result)
}
