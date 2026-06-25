# =============================================================================
# Calibrate §301 exclusion claim shares (Phase 2 of the exclusion fix)
# =============================================================================
#
# Replaces the Phase-1 coverage_share = 1.0 full-line upper bound on USTR
# §301 exclusion headings (resources/s301_exclusion_headings.csv, consumed by
# the 6a-excl hook in src/pipeline/06_calculate_rates.R) with claim shares measured
# from realized collections.
#
# WHY REALIZED-RATE INVERSION (verified 2026-06-11; see
# docs/s301_exclusion_calibration.md):
#   * The public Census IMDB detail file carries NO chapter-99 commodity
#     records (only the 9999.95 low-value estimate line) — ch99 filings are
#     reported under the underlying HTS10, so heading-level claim filings
#     cannot be observed directly.
#   * USITC DataWeb likewise returns no import statistics under 9903
#     commodity codes, and its rate-provision filter is a 2-digit aggregate
#     (see src/download_subdivision_r_share.R, 2026-05-02 finding).
#   * What IS observable: IMDB calculated duties and customs value per
#     HTS10 x country x month. On an affected line the exclusion zeroes the
#     §301 component for the claimed slice, so
#
#       realized_rate ≈ stat_other + (1 - claim_share) * full_301
#       claim_share   = (stat_other + full_301 - realized_rate) / full_301
#
#     where stat_other = all non-301 statutory layers (from the tracker's own
#     snapshots) and full_301 = the line's pre-exclusion §301 rate
#     (reconstructed from the chapter-99 parse caches, engine-consistent).
#
# CAVEAT: the inversion attributes the line's ENTIRE statutory-vs-collected
# gap to the exclusion. Other compliance channels (de minimis, valuation,
# misclassification, FTZ timing) load onto the same residual; treat the
# output as a measurement to be curator-reviewed before promotion into the
# registry's coverage_share, not as an automatic write.
#
# Inputs:
#   resources/s301_exclusion_headings.csv  - heading registry (live = coverage>0)
#   resources/s301_exclusion_lines.csv     - heading -> referencing HTS10 lines
#                                            (scripts/build_s301_exclusion_lines.R)
#   data/timeseries/{products,ch99}_<rev>.rds - parse caches (full_301, windows)
#   --snapshots-dir                        - statutory rates: either the local
#                                            rds layout (data/timeseries/
#                                            snapshot_<rev>.rds) or a published
#                                            vintage (actual/snapshots/
#                                            valid_from=*/rates.parquet)
#   IMDB monthly ZIPs                      - con_val_mo / dut_val_mo /
#                                            cal_dut_mo per HTS10 x country
#
# Outputs:
#   resources/s301_exclusion_claim_shares.csv            - per HTS10 (covered months)
#   resources/s301_exclusion_claim_shares_by_heading.csv - per heading summary
#   output/diagnostics/s301_exclusion_claims_monthly.csv - full monthly detail
#
# Usage:
#   Rscript tools/calibrate_s301_exclusions.R \
#       --imdb-dir ../tariff-etr-eval/data/imdb/raw \
#       --snapshots-dir "<vintage>/actual/snapshots" \
#       --start 2025-01 --end 2026-03
#
#   --imdb-dir DIR       IMDB ZIP cache (default data/imdb/raw). Missing months
#                        are downloaded only with --download.
#   --snapshots-dir DIR  Statutory source (default data/timeseries).
#   --start/--end YYYY-MM  Analysis window (default 2025-01 .. latest cached).
#   --download           Opt in to downloading missing IMDB ZIPs from Census.
#   --include-carveouts  Also measure the 9903.88.21-.28 conditional
#                        carve-outs (diagnostic; they are NOT exclusions).
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})
source(here('src', 'model', 'rate_schema.R'))   # classify_authority, window extractors
source(here('src', 'model', 'revisions.R'))     # load_revision_dates

IMDB_URL_TEMPLATE <- 'https://www.census.gov/trade/downloads/%s/Merch/im_m/IMDB%s.ZIP'
CTY_CHINA <- '5700'

# IMDB IMP_DETL.TXT fixed-width positions (matches the rich spec used by the
# eval pipelines; superset of src/io/build_import_weights.R which reads fewer
# columns). dut_val = dutiable value, cal_dut = calculated duty.
IMDB_CALIB_POSITIONS <- function() {
  readr::fwf_positions(
    start     = c(1,  11,  23,  27,  74,   89,   104),
    end       = c(10, 14,  26,  28,  88,   103,  118),
    col_names = c('hts10', 'cty_code', 'year', 'month',
                  'con_val_mo', 'dut_val_mo', 'cal_dut_mo')
  )
}


# =============================================================================
# Pure inversion helper (unit-tested in tests/test_s301_exclusion_calibration.R)
# =============================================================================

#' Invert a realized duty rate into an implied exclusion claim share.
#'
#' @param realized   realized duty rate (cal_dut / con_val) for the cell
#' @param stat_other statutory total of all non-301 layers
#' @param full_301   pre-exclusion statutory §301 rate (> 0 for valid cells)
#' @return list(raw = unclipped share, clipped = share clipped to [0, 1]);
#'   NA when full_301 is not positive or any input is NA.
invert_claim_share <- function(realized, stat_other, full_301) {
  raw <- if_else(!is.na(full_301) & full_301 > 0,
                 (stat_other + full_301 - realized) / full_301,
                 NA_real_)
  list(raw = raw, clipped = pmin(pmax(raw, 0), 1))
}


# =============================================================================
# CLI
# =============================================================================

parse_cli <- function(argv) {
  opts <- list(
    imdb_dir          = here('data', 'imdb', 'raw'),
    snapshots_dir     = here('data', 'timeseries'),
    start             = '2025-01',
    end               = NULL,            # default: latest cached IMDB month
    download          = FALSE,
    include_carveouts = FALSE
  )
  i <- 1
  while (i <= length(argv)) {
    a <- argv[i]
    take <- function() {
      if (i + 1L > length(argv)) stop('Missing value for ', a, call. = FALSE)
      i <<- i + 1L
      argv[i]
    }
    if (a == '--imdb-dir') opts$imdb_dir <- take()
    else if (a == '--snapshots-dir') opts$snapshots_dir <- take()
    else if (a == '--start') opts$start <- take()
    else if (a == '--end') opts$end <- take()
    else if (a == '--download') opts$download <- TRUE
    else if (a == '--include-carveouts') opts$include_carveouts <- TRUE
    else stop('Unknown argument: ', a, call. = FALSE)
    i <- i + 1
  }
  opts
}


# =============================================================================
# IMDB acquisition + parsing
# =============================================================================

imdb_zip_name <- function(year_month) {
  sprintf('IMDB%s%s.ZIP', substr(year_month, 3, 4), substr(year_month, 6, 7))
}

ensure_imdb_month <- function(year_month, imdb_dir, download = FALSE) {
  zip_path <- file.path(imdb_dir, imdb_zip_name(year_month))
  if (file.exists(zip_path) && file.size(zip_path) > 1000) return(zip_path)
  if (!download) return(NA_character_)
  dir.create(imdb_dir, showWarnings = FALSE, recursive = TRUE)
  url <- sprintf(IMDB_URL_TEMPLATE, substr(year_month, 1, 4),
                 paste0(substr(year_month, 3, 4), substr(year_month, 6, 7)))
  message('  downloading ', basename(zip_path))
  ok <- tryCatch({
    utils::download.file(url, zip_path, mode = 'wb', quiet = TRUE)
    file.exists(zip_path) && file.size(zip_path) > 1000
  }, error = function(e) FALSE)
  if (!ok) {
    if (file.exists(zip_path)) file.remove(zip_path)
    return(NA_character_)
  }
  zip_path
}

#' Parse one IMDB monthly ZIP, restricted to the affected HTS10 set x China.
#' Returns year_month, hts10, con_val, dut_val, cal_dut (cell-aggregated).
#' NOTE: read_fwf with latin1 + lazy = FALSE on purpose — byte-sanitizing via
#' readBin peaks ~16 GB on these files; this path is ~30 s/month.
parse_imdb_month <- function(zip_path, affected_hts10) {
  contents <- utils::unzip(zip_path, list = TRUE)
  detl <- contents$Name[grepl('IMP_DETL\\.TXT$', contents$Name, ignore.case = TRUE)]
  if (length(detl) != 1) stop('Expected one IMP_DETL.TXT in ', basename(zip_path))

  tmp_dir <- tempfile('imdb_calib_')
  dir.create(tmp_dir)
  on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)
  utils::unzip(zip_path, files = detl, exdir = tmp_dir)

  records <- readr::read_fwf(
    file.path(tmp_dir, detl),
    col_positions = IMDB_CALIB_POSITIONS(),
    col_types = readr::cols(
      hts10 = readr::col_character(), cty_code = readr::col_character(),
      year = readr::col_integer(), month = readr::col_integer(),
      con_val_mo = readr::col_double(), dut_val_mo = readr::col_double(),
      cal_dut_mo = readr::col_double()
    ),
    locale = readr::locale(encoding = 'latin1'),
    lazy = FALSE, progress = FALSE
  )

  records %>%
    mutate(hts10 = str_pad(trimws(hts10), 10, 'left', '0'),
           cty_code = trimws(cty_code)) %>%
    filter(cty_code == CTY_CHINA, hts10 %in% affected_hts10,
           coalesce(con_val_mo, 0) > 0) %>%
    mutate(year_month = sprintf('%04d-%02d', year, month)) %>%
    group_by(year_month, hts10) %>%
    summarise(con_val = sum(con_val_mo, na.rm = TRUE),
              dut_val = sum(dut_val_mo, na.rm = TRUE),
              cal_dut = sum(cal_dut_mo, na.rm = TRUE),
              .groups = 'drop')
}


# =============================================================================
# Statutory side
# =============================================================================

#' Map each day of the analysis window to the revision whose text is in force.
revision_day_map <- function(window_start, window_end) {
  revs <- load_revision_dates(use_policy_dates = TRUE) %>%
    arrange(effective_date)
  tibble(date = seq(window_start, window_end, by = 'day')) %>%
    mutate(revision = map_chr(date, function(d) {
      in_force <- revs %>% filter(effective_date <= d)
      if (nrow(in_force) == 0) NA_character_ else tail(in_force$revision, 1)
    })) %>%
    filter(!is.na(revision))
}

#' Pre-exclusion §301 rate per affected line, per revision. The engine applies
#' §301 through resources/s301_product_lists.csv (HTS8 prefix -> list heading,
#' max per HTS8 when a code sits on several lists), with each heading's rate
#' taken from that revision's chapter-99 parse — NOT through per-line footnote
#' refs (only a minority of affected lines carry the list heading as a
#' footnote). Mirror that: list-file membership x per-revision heading rates,
#' max per line. Exclusion headings parse to NA rate and never enter the max.
load_full_301 <- function(revisions, affected_hts10, ts_dir) {
  s301_lists <- read_csv(here('resources', 's301_product_lists.csv'),
                         col_types = cols(.default = col_character()))
  affected_map <- tibble(hts10 = affected_hts10,
                         hts8 = substr(affected_hts10, 1, 8)) %>%
    inner_join(s301_lists, by = 'hts8',
               relationship = 'many-to-many') %>%
    select(hts10, ch99_code)
  if (nrow(affected_map) == 0) {
    stop('No affected line matches s301_product_lists.csv — check inputs.')
  }
  uncovered <- setdiff(affected_hts10, unique(affected_map$hts10))
  if (length(uncovered) > 0) {
    message('  NOTE: ', length(uncovered), ' affected lines are on NO §301 ',
            'list (no full_301; they drop from the inversion): ',
            paste(head(uncovered, 5), collapse = ', '),
            if (length(uncovered) > 5) ' ...')
  }

  map_dfr(revisions, function(rev) {
    ch99_path <- file.path(ts_dir, paste0('ch99_', rev, '.rds'))
    if (!file.exists(ch99_path)) {
      stop('Missing ch99 parse cache for revision ', rev, ' in ', ts_dir,
           ' — re-run the parse step for it.')
    }
    s301_rates <- readRDS(ch99_path) %>%
      filter(!is.na(rate),
             map_chr(ch99_code, classify_authority) == 'section_301') %>%
      select(ch99_code, rate)
    affected_map %>%
      inner_join(s301_rates, by = 'ch99_code') %>%
      group_by(hts10) %>%
      summarise(full_301 = max(rate), .groups = 'drop') %>%
      mutate(revision = rev)
  })
}

#' Statutory snapshot rows (China) for the affected lines, date-resolved.
#' Supports two layouts:
#'   * vintage: <dir>/valid_from=YYYY-MM-DD/rates.parquet (published builds;
#'     date-resolved including bnd_* boundary snapshots)
#'   * rds:     <dir>/snapshot_<rev>.rds (local builds; resolved via
#'     revision_day_map)
#' Returns one row per (valid_from, hts10): total_rate, rate_301, rate_301_cs,
#' metal_share — plus the interval [valid_from, valid_until].
load_statutory <- function(snapshots_dir, affected_hts10,
                           window_start, window_end, day_map) {
  vintage_dirs <- list.files(snapshots_dir, pattern = '^valid_from=',
                             full.names = TRUE)
  sel_cols <- c('hts10', 'country', 'total_rate', 'rate_301', 'rate_301_cs',
                'metal_share')

  if (length(vintage_dirs) > 0) {
    message('Statutory source: vintage parquet layout (',
            length(vintage_dirs), ' snapshots)')
    starts <- as.Date(sub('^valid_from=', '', basename(vintage_dirs)))
    ord <- order(starts)
    vintage_dirs <- vintage_dirs[ord]; starts <- starts[ord]
    ends <- c(starts[-1] - 1, as.Date('9999-12-31'))
    keep <- starts <= window_end & ends >= window_start
    map_dfr(which(keep), function(i) {
      arrow::read_parquet(file.path(vintage_dirs[i], 'rates.parquet'),
                          col_select = all_of(sel_cols)) %>%
        filter(country == CTY_CHINA, hts10 %in% affected_hts10) %>%
        mutate(valid_from = starts[i], valid_until = ends[i])
    })
  } else {
    message('Statutory source: local rds layout (snapshot_<rev>.rds)')
    rev_intervals <- day_map %>%
      group_by(revision) %>%
      summarise(valid_from = min(date), valid_until = max(date),
                .groups = 'drop')
    map_dfr(seq_len(nrow(rev_intervals)), function(i) {
      rev <- rev_intervals$revision[i]
      path <- file.path(snapshots_dir, paste0('snapshot_', rev, '.rds'))
      if (!file.exists(path)) {
        stop('Missing snapshot for revision ', rev, ' in ', snapshots_dir)
      }
      readRDS(path) %>%
        select(any_of(c(sel_cols, 'country'))) %>%
        filter(country == CTY_CHINA, hts10 %in% affected_hts10) %>%
        mutate(valid_from = rev_intervals$valid_from[i],
               valid_until = rev_intervals$valid_until[i])
    })
  }
}


# =============================================================================
# Main
# =============================================================================

run_calibration <- function(opts) {
  registry <- read_csv(here('resources', 's301_exclusion_headings.csv'),
                       col_types = cols(ch99_code = col_character(),
                                        coverage_share = col_double(),
                                        .default = col_character()))
  lines <- read_csv(here('resources', 's301_exclusion_lines.csv'),
                    col_types = cols(.default = col_character()))

  live_headings <- registry %>% filter(coverage_share > 0) %>% pull(ch99_code)
  target_headings <- live_headings
  if (opts$include_carveouts) {
    target_headings <- union(target_headings,
                             sprintf('9903.88.%02d', 21:28))
  }
  lines <- lines %>% filter(ch99_code %in% target_headings)
  affected <- sort(unique(lines$hts10))
  message('Calibrating ', length(target_headings), ' headings over ',
          length(affected), ' affected HTS10 lines')

  # --- analysis window ------------------------------------------------------
  cached <- list.files(opts$imdb_dir, pattern = '^IMDB\\d{4}\\.ZIP$',
                       ignore.case = TRUE)
  cached_ym <- sort(sprintf('20%s-%s', substr(cached, 5, 6), substr(cached, 7, 8)))
  end_ym <- opts$end %||% { if (length(cached_ym) == 0)
    stop('No IMDB ZIPs in ', opts$imdb_dir, ' and no --end given.')
    max(cached_ym) }
  months <- format(seq(as.Date(paste0(opts$start, '-01')),
                       as.Date(paste0(end_ym, '-01')), by = 'month'), '%Y-%m')
  window_start <- as.Date(paste0(opts$start, '-01'))
  window_end <- as.Date(paste0(end_ym, '-01'))
  window_end <- seq(window_end, by = 'month', length.out = 2)[2] - 1
  message('Window: ', opts$start, ' .. ', end_ym, ' (', length(months), ' months)')

  # --- statutory side -------------------------------------------------------
  day_map <- revision_day_map(window_start, window_end)
  revisions <- unique(day_map$revision)
  message('Revisions in force: ', length(revisions))

  full_301 <- load_full_301(revisions, affected, here('data', 'timeseries'))
  statutory <- load_statutory(opts$snapshots_dir, affected,
                              window_start, window_end, day_map)

  # Day-level panel: statutory row in force + revision text in force, then
  # month aggregation (uniform-day weighting within the month).
  day_panel <- day_map %>%
    filter(date >= window_start, date <= window_end) %>%
    left_join(full_301, by = 'revision',
              relationship = 'many-to-many') %>%
    filter(!is.na(hts10))

  stat_days <- day_panel %>%
    left_join(statutory,
              join_by(hts10, date >= valid_from, date <= valid_until)) %>%
    mutate(
      stat_other = total_rate - rate_301,
      # modeled-excluded: the engine scaled the line's §301 rate below the
      # full list rate on this day. Written as "below full" (not "== 0") so
      # the tag survives calibrated coverage_share < 1 in post-promotion
      # snapshot vintages (registry moved off 1.0 on 2026-06-11).
      modeled_excluded = full_301 > 0 & coalesce(rate_301, full_301) < full_301 - 1e-9
    )

  stat_monthly <- stat_days %>%
    mutate(year_month = format(date, '%Y-%m')) %>%
    group_by(year_month, hts10) %>%
    summarise(
      full_301 = mean(full_301),
      stat_other = mean(stat_other),
      rate_301_cs = mean(coalesce(rate_301_cs, 0)),
      metal_share = mean(coalesce(metal_share, 0)),
      days_excluded = sum(modeled_excluded),
      days_total = n(),
      .groups = 'drop'
    ) %>%
    mutate(coverage_status = case_when(
      days_excluded == days_total ~ 'covered',
      days_excluded == 0 ~ 'lapsed',
      TRUE ~ 'partial'
    ))

  # --- IMDB side ------------------------------------------------------------
  message('Parsing IMDB months from ', opts$imdb_dir)
  trade <- map_dfr(months, function(ym) {
    zip_path <- ensure_imdb_month(ym, opts$imdb_dir, opts$download)
    if (is.na(zip_path)) {
      message('  ', ym, ': ZIP not cached — skipped',
              if (!opts$download) ' (pass --download to fetch)')
      return(tibble())
    }
    t0 <- Sys.time()
    out <- parse_imdb_month(zip_path, affected)
    message(sprintf('  %s: %d affected China cells, $%.0fM (%.0fs)',
                    ym, nrow(out), sum(out$con_val) / 1e6,
                    as.numeric(difftime(Sys.time(), t0, units = 'secs'))))
    out
  })
  if (nrow(trade) == 0) stop('No IMDB data parsed — nothing to calibrate.')

  # --- inversion ------------------------------------------------------------
  # Eligibility: full_301 > 0 (a §301 list rate exists to invert against) and
  # no content-split §301 pairs (rate_301_cs is applied via separate appended
  # pairs the inversion cannot attribute). NOTE metal_share / 232 stacking is
  # NOT a disqualifier: stat_other = total_rate - rate_301 absorbs every
  # stacking interaction because China §301 enters total_additional additively
  # at full value under all stacking classes.
  panel <- trade %>%
    inner_join(stat_monthly, by = c('year_month', 'hts10')) %>%
    mutate(
      realized = cal_dut / con_val,
      eligible = coalesce(full_301, 0) > 0 & coalesce(rate_301_cs, 0) < 1e-9
    )
  shares <- invert_claim_share(panel$realized, panel$stat_other, panel$full_301)
  panel <- panel %>%
    mutate(claim_share_raw = if_else(eligible, shares$raw, NA_real_),
           claim_share = if_else(eligible, shares$clipped, NA_real_))

  n_inel <- sum(!panel$eligible)
  if (n_inel > 0) {
    message(n_inel, ' line-months ineligible: ',
            sum(coalesce(panel$full_301, 0) <= 0), ' zero/NA full_301, ',
            sum(coalesce(panel$rate_301_cs, 0) >= 1e-9), ' content-split §301',
            ' — excluded from shares.')
  }

  # --- outputs --------------------------------------------------------------
  # Monthly diagnostic detail (all statuses, incl. lapsed/partial months).
  diag_dir <- here('output', 'diagnostics')
  dir.create(diag_dir, showWarnings = FALSE, recursive = TRUE)
  monthly_out <- panel %>%
    left_join(lines %>% distinct(hts10, ch99_code), by = 'hts10',
              relationship = 'many-to-many') %>%
    select(ch99_code, hts10, year_month, coverage_status, con_val, dut_val,
           cal_dut, realized, stat_other, full_301,
           claim_share_raw, claim_share) %>%
    arrange(ch99_code, hts10, year_month)
  write_csv(monthly_out, file.path(diag_dir, 's301_exclusion_claims_monthly.csv'))

  # HTS10-level shares: covered months only, value-weighted.
  hts_out <- panel %>%
    filter(coverage_status == 'covered', eligible) %>%
    group_by(hts10) %>%
    summarise(
      n_months = n(),
      imports_usd = sum(con_val),
      realized_vw = weighted.mean(realized, con_val),
      stat_other_vw = weighted.mean(stat_other, con_val),
      full_301_vw = weighted.mean(full_301, con_val),
      claim_share_raw_vw = weighted.mean(claim_share_raw, con_val),
      claim_share = pmin(pmax(weighted.mean(claim_share_raw, con_val), 0), 1),
      .groups = 'drop'
    ) %>%
    left_join(lines %>% distinct(hts10, ch99_code), by = 'hts10',
              relationship = 'many-to-many') %>%
    relocate(ch99_code) %>%
    arrange(ch99_code, desc(imports_usd))
  write_csv(hts_out, here('resources', 's301_exclusion_claim_shares.csv'))

  # Heading-level summary: candidate registry coverage_share values.
  heading_out <- hts_out %>%
    group_by(ch99_code) %>%
    summarise(
      n_lines = n(),
      # weighted mean BEFORE imports_usd is overwritten by the sum below —
      # summarise() evaluates sequentially and would otherwise hand
      # weighted.mean() a length-1 weight.
      claim_share_vw = weighted.mean(claim_share, imports_usd),
      claim_share_p25 = quantile(claim_share, 0.25),
      claim_share_median = median(claim_share),
      claim_share_p75 = quantile(claim_share, 0.75),
      imports_usd = sum(imports_usd),
      .groups = 'drop'
    )

  # Clean-era sub-window: 2026 months (post-IEEPA-invalidation) have the
  # smallest stat_other, so the inversion is least contaminated by the
  # spring/summer-2025 reciprocal swings (which clip shares at 1).
  h2026 <- panel %>%
    filter(coverage_status == 'covered', eligible, year_month >= '2026-01') %>%
    left_join(lines %>% distinct(hts10, ch99_code), by = 'hts10',
              relationship = 'many-to-many') %>%
    group_by(ch99_code) %>%
    summarise(claim_share_vw_2026 =
                pmin(pmax(weighted.mean(claim_share_raw, con_val), 0), 1),
              n_line_months_2026 = n(), .groups = 'drop')
  heading_out <- heading_out %>% left_join(h2026, by = 'ch99_code')
  write_csv(heading_out,
            here('resources', 's301_exclusion_claim_shares_by_heading.csv'))

  message('\n=== Proposed registry coverage_share (curator review required) ===')
  walk(seq_len(nrow(heading_out)), function(i) {
    message(sprintf(
      '  %s : %.3f full-window / %.3f 2026-only  (current %.2f; %d lines, $%.0fM, IQR %.2f-%.2f)',
      heading_out$ch99_code[i], heading_out$claim_share_vw[i],
      coalesce(heading_out$claim_share_vw_2026[i], NA_real_),
      registry$coverage_share[match(heading_out$ch99_code[i],
                                    registry$ch99_code)],
      heading_out$n_lines[i], heading_out$imports_usd[i] / 1e6,
      heading_out$claim_share_p25[i], heading_out$claim_share_p75[i]))
  })
  message('\nDistribution of raw (unclipped) line-month shares, covered months:')
  cov <- panel %>% filter(coverage_status == 'covered', eligible)
  message(sprintf('  n=%d  <0: %d  in [0,1]: %d  >1: %d',
                  nrow(cov), sum(cov$claim_share_raw < 0),
                  sum(cov$claim_share_raw >= 0 & cov$claim_share_raw <= 1),
                  sum(cov$claim_share_raw > 1)))
  message('Wrote resources/s301_exclusion_claim_shares{,_by_heading}.csv and ',
          'output/diagnostics/s301_exclusion_claims_monthly.csv')

  invisible(list(panel = panel, hts = hts_out, heading = heading_out))
}


if (sys.nframe() == 0) {
  opts <- parse_cli(commandArgs(trailingOnly = TRUE))
  run_calibration(opts)
}
