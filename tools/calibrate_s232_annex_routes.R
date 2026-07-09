# =============================================================================
# Calibrate §232 annex-era note-16 exemption-route shares (issue #13)
# =============================================================================
#
# Measures, per HTS10 x country cell, how the realized duty rate on annex-
# classified §232 products (s232_annex in 1a/1b/3) decomposes across the legal
# outcomes the April-2026 note 16 allows. Design + statutory anchors:
# docs/s232/annex_exemption_route_calibration_proposal.md. NO engine changes —
# outputs are reviewable CSVs; nothing is promoted automatically.
#
# WHY REALIZED-RATE INVERSION: identical measurement reality as the §301
# exclusion calibration (tools/calibrate_s301_exclusions.R, whose IMDB reader
# this file adapts — factor into a shared lib when either next changes): the
# public IMDB carries NO chapter-99 commodity records, so route claims
# (9903.82.01/.03/.06/.07/.08/.13) cannot be observed directly. What IS
# observable is cal_dut_mo / con_val_mo per HTS10 x country x month.
#
# THE THREE CANDIDATES (per cell, per snapshot window):
#   T_full  charged the annex rate            = actual snapshot total_rate
#   T_us    >=95% US-origin metal, note 16(e) = T_full - rate_232 + route_addl
#             route_addl: annex_1a/1b cells (9903.82.06)  -> flat +10%
#                         annex_3 cells   (9903.82.07/.08) -> max(0.10 - base, 0)
#                           ("the sum of the column 1 duty rate and the
#                            additional ad valorem rate ... will be 10 percent")
#   T_exit  zero-duty routes 9903.82.01 (no covered metal) / 9903.82.03
#           (covered-metal weight < 15%): the article legally EXITS §232 into
#           the without-232 stacking branch (owing §122 unless ITA-exempt,
#           since headings .01/.03 are NOT in note 2(aa)(v)(1)'s 9903.82.02-.17
#           exclusion range) = the no_232 counterfactual snapshot's total_rate
#           (config/scenarios/no_232 — zeroing rate_232 pre-stacking routes the
#           pair through the without-232 branch by construction).
#
# Routes .01 and .03 both price at T_exit and are JOINTLY identified (z0);
# 9903.82.13 (motorcycle end-use) is below the noise floor and importer-
# conditional — deliberately NOT estimated here (top-down bound only, see
# proposal §5). UK cells (9903.82.04/.05) already carry uk_rate in T_full at
# qualifying_share = 1.0; their miscalibration shows up as 'unexplained' mass
# — reported, not resolved here (registry U5).
#
# ESTIMATORS (per cell-month, value-weighted upward):
#   1. Nearest-signature assignment: classify realized to the closest of
#      {T_full, T_us, T_exit}; 'unexplained' if farther than --resid-tol from
#      all three; 'ambiguous' if the two nearest candidates sit within
#      --sep-tol of each other at the observed point (e.g. a §122-charged
#      non-ITA line where T_us ≈ T_exit — the eta guard: such cells are NEVER
#      force-assigned).
#   2. Per-cell bounds (single-equation algebra, mirrors invert_claim_share):
#      z0_max assuming u = 0:  (T_full - realized) / (T_full - T_exit)
#      u_max  assuming z0 = 0: (T_full - realized) / (T_full - T_us)
#      Raw (unclipped) values are reported so <0 / >1 mass stays visible.
#
# CAVEAT (same class as U3): the inversion attributes the cell's entire
# statutory-vs-collected gap to whichever candidate is nearest. Entry timing
# around 2026-04-06, FTZ/ch98 channels, AD/CVD (in cal_dut but in none of our
# statutory layers), and genuine noncompliance load onto the same residual.
# April 2026 is additionally regime-partial (annex era starts Apr 6; monthly
# IMDB aggregates the whole month) — cells carry regime_days_share and May is
# the primary month. Curator review before anything is promoted.
#
# Inputs:
#   --snapshots-dir   actual statutory snapshots. vintage parquet layout
#                     (<dir>/valid_from=*/rates.parquet, e.g.
#                     <model_data>/2026-07-01-16/actual/snapshots) — REQUIRED
#                     layout for annex mode (needs s232_annex/heading_program).
#   --no232-dir       no_232 counterfactual snapshots, local rds layout
#                     (snapshot_<rev>.rds; scripts/submit_no232_annex_snapshots.sh)
#   --imdb-dir        IMDB monthly ZIPs (the eval cache works); --download to
#                     fetch missing months from Census
#   --start/--end     analysis months, YYYY-MM (default 2026-04..2026-05)
#
# Outputs:
#   output/diagnostics/s232_annex_routes_monthly.csv   cell-month detail
#   resources/s232_annex_route_shares.csv              per-cell shares + bounds
#   (summary decomposition table printed to stdout)
#
# Usage (first measurement):
#   Rscript tools/calibrate_s232_annex_routes.R \
#     --snapshots-dir /nfs/roberts/project/pi_nrs36/shared/model_data/Tariff-Rate-Tracker/latest/actual/snapshots \
#     --no232-dir data/timeseries/no_232 \
#     --imdb-dir ../tariff-etr-eval/data/imdb/raw \
#     --start 2026-04 --end 2026-05 --download
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})
source(here('src', 'model', 'revisions.R'))   # load_revision_dates

IMDB_URL_TEMPLATE <- 'https://www.census.gov/trade/downloads/%s/Merch/im_m/IMDB%s.ZIP'
ANNEX_EFFECTIVE   <- as.Date('2026-04-06')
ANNEX_1C_START    <- as.Date('2026-06-08')   # Proc 11032 reshuffle — months >= June excluded
US_ORIGIN_TARGET  <- 0.10                    # note 16(e) routes

# IMDB IMP_DETL.TXT fixed-width positions (same spec as calibrate_s301_exclusions.R)
IMDB_ROUTE_POSITIONS <- function() {
  readr::fwf_positions(
    start     = c(1,  11,  23,  27,  74,   89,   104),
    end       = c(10, 14,  26,  28,  88,   103,  118),
    col_names = c('hts10', 'cty_code', 'year', 'month',
                  'con_val_mo', 'dut_val_mo', 'cal_dut_mo')
  )
}


# =============================================================================
# Pure helpers (unit-tested in tests/test_s232_route_calibration.R)
# =============================================================================

#' US-origin-metal route additional duty per note 16(e).
#' annex_1a/1b cells route via 9903.82.06 (flat +10%); annex_3 cells via
#' 9903.82.07/.08 (10% TARGET-TOTAL: additional tops base up to 10%, zero if
#' base already >= 10%).
us_origin_route_addl <- function(s232_annex, base_rate) {
  base <- coalesce(base_rate, 0)
  case_when(
    s232_annex %in% c('annex_1a', 'annex_1b') ~ US_ORIGIN_TARGET,
    s232_annex == 'annex_3'                   ~ pmax(US_ORIGIN_TARGET - base, 0),
    TRUE                                      ~ NA_real_
  )
}

#' Build the three candidate totals for one joined cell-window row set.
#' Requires columns: total_rate, rate_232, base_rate, s232_annex (actual side)
#' and total_rate_no232 (counterfactual side).
build_candidates <- function(df) {
  df %>%
    mutate(
      T_full = total_rate,
      T_us   = total_rate - rate_232 + us_origin_route_addl(s232_annex, base_rate),
      T_exit = total_rate_no232
    )
}

#' Nearest-signature assignment with ambiguity + residual guards.
#'
#' @return list(route, ambiguous, dist) — route in
#'   c('full','us_origin','exit','unexplained'); ambiguous = TRUE when the two
#'   nearest candidates sit within sep_tol of EACH OTHER (assignment between
#'   them is not identified; route still reports the nearest but consumers
#'   must respect the flag).
classify_route <- function(realized, T_full, T_us, T_exit,
                           sep_tol = 0.03, resid_tol = 0.05) {
  n <- length(realized)
  # The 16(e) route is OPTIONAL — an importer only claims it when it lowers
  # duty. Where T_us >= T_full (e.g. USMCA-scaled annex_3 floors already
  # below 10%) the candidate is legally inert: mask it so realized mass
  # never assigns to a route nobody would claim.
  T_us <- if_else(T_us >= T_full - 1e-9, NA_real_, T_us)
  cand <- cbind(full = T_full, us_origin = T_us, exit = T_exit)
  dist <- abs(cand - realized)
  dist[is.na(dist)] <- Inf                            # masked candidate: never nearest
  ord1 <- max.col(-dist, ties.method = 'first')       # nearest candidate index
  d_sorted <- t(apply(dist, 1, sort))
  nearest  <- colnames(cand)[ord1]
  # ambiguity: the two nearest CANDIDATE VALUES are close to each other
  cand_inf <- cand; cand_inf[is.na(cand_inf)] <- Inf
  cand_sorted <- t(apply(cand_inf, 1, sort))
  gap12 <- pmin(cand_sorted[, 2] - cand_sorted[, 1],
                cand_sorted[, 3] - cand_sorted[, 2])
  # only ambiguous if realized is actually near the colliding pair: use the
  # second-nearest distance — if both nearest candidates are within sep_tol
  # of realized, they are indistinguishable at this observation.
  ambiguous <- (d_sorted[, 2] - d_sorted[, 1]) < sep_tol & d_sorted[, 2] < resid_tol
  route <- if_else(d_sorted[, 1] > resid_tol, 'unexplained', nearest)
  list(route = route, ambiguous = ambiguous & route != 'unexplained',
       dist = d_sorted[, 1], cand_gap = gap12)
}

#' Single-equation route bounds (unclipped + clipped).
#' z0_max: assume u = 0; u_max: assume z0 = 0. NA where the denominator is
#' not meaningfully positive (candidates coincide — nothing to invert).
route_bounds <- function(realized, T_full, T_us, T_exit, min_denom = 1e-6) {
  z0_raw <- if_else(T_full - T_exit > min_denom,
                    (T_full - realized) / (T_full - T_exit), NA_real_)
  u_raw  <- if_else(T_full - T_us > min_denom,
                    (T_full - realized) / (T_full - T_us), NA_real_)
  list(z0_raw = z0_raw, z0 = pmin(pmax(z0_raw, 0), 1),
       u_raw = u_raw,   u  = pmin(pmax(u_raw, 0), 1))
}

#' Day-weight per-window candidate rates into one expected rate per month.
#' Only annex-era days (>= ANNEX_EFFECTIVE) enter the weights;
#' regime_days_share reports the covered fraction of the calendar month so
#' partial months (April 2026) are visible downstream.
month_weights <- function(valid_from, valid_until, ym) {
  m_start <- as.Date(paste0(ym, '-01'))
  m_end   <- seq(m_start, by = 'month', length.out = 2)[2] - 1
  s <- pmax(pmax(valid_from, m_start), ANNEX_EFFECTIVE)
  e <- pmin(valid_until, m_end)
  days <- as.numeric(e - s) + 1
  days[days < 0] <- 0
  list(days = days, month_days = as.numeric(m_end - m_start) + 1)
}


# =============================================================================
# CLI
# =============================================================================

parse_cli <- function(argv) {
  opts <- list(
    snapshots_dir = NULL,
    no232_dir     = here('data', 'timeseries', 'no_232'),
    imdb_dir      = here('data', 'imdb', 'raw'),
    start         = '2026-04',
    end           = '2026-05',
    download      = FALSE,
    sep_tol       = 0.03,
    resid_tol     = 0.05
  )
  i <- 1
  while (i <= length(argv)) {
    a <- argv[i]
    take <- function() {
      if (i + 1L > length(argv)) stop('Missing value for ', a, call. = FALSE)
      i <<- i + 1L
      argv[i]
    }
    if (a == '--snapshots-dir') opts$snapshots_dir <- take()
    else if (a == '--no232-dir') opts$no232_dir <- take()
    else if (a == '--imdb-dir') opts$imdb_dir <- take()
    else if (a == '--start') opts$start <- take()
    else if (a == '--end') opts$end <- take()
    else if (a == '--download') opts$download <- TRUE
    else if (a == '--sep-tol') opts$sep_tol <- as.numeric(take())
    else if (a == '--resid-tol') opts$resid_tol <- as.numeric(take())
    else stop('Unknown argument: ', a, call. = FALSE)
    i <- i + 1
  }
  if (is.null(opts$snapshots_dir)) {
    stop('--snapshots-dir is required (vintage parquet layout, e.g. ',
         '<model_data>/latest/actual/snapshots)', call. = FALSE)
  }
  opts
}


# =============================================================================
# IMDB acquisition + parsing (all countries; adapted from the U3 module)
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

#' Parse one IMDB monthly ZIP restricted to the affected HTS10 set, ALL
#' countries (unlike U3's China-only filter). Cell-aggregated.
parse_imdb_month <- function(zip_path, affected_hts10) {
  contents <- utils::unzip(zip_path, list = TRUE)
  detl <- contents$Name[grepl('IMP_DETL\\.TXT$', contents$Name, ignore.case = TRUE)]
  if (length(detl) != 1) stop('Expected one IMP_DETL.TXT in ', basename(zip_path))

  tmp_dir <- tempfile('imdb_routes_')
  dir.create(tmp_dir)
  on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)
  utils::unzip(zip_path, files = detl, exdir = tmp_dir)

  records <- readr::read_fwf(
    file.path(tmp_dir, detl),
    col_positions = IMDB_ROUTE_POSITIONS(),
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
    filter(hts10 %in% affected_hts10, coalesce(con_val_mo, 0) > 0) %>%
    mutate(year_month = sprintf('%04d-%02d', year, month)) %>%
    group_by(year_month, hts10, country = cty_code) %>%
    summarise(con_val = sum(con_val_mo, na.rm = TRUE),
              cal_dut = sum(cal_dut_mo, na.rm = TRUE),
              .groups = 'drop')
}


# =============================================================================
# Statutory side
# =============================================================================

#' Actual-series snapshot windows overlapping [win_start, win_end], from the
#' vintage parquet layout. Returns the affected annex universe: annex-tier
#' cells with rate_232 > 0, EXCLUDING heading-program products (auto/MHD/
#' copper/wood/semi carry their own programs — route headings don't apply).
load_actual_annex <- function(snapshots_dir, win_start, win_end) {
  dirs <- list.files(snapshots_dir, pattern = '^valid_from=', full.names = TRUE)
  if (length(dirs) == 0) {
    stop('No valid_from=* snapshot dirs under ', snapshots_dir,
         ' — annex mode requires the vintage parquet layout.')
  }
  starts <- as.Date(sub('^valid_from=', '', basename(dirs)))
  ord <- order(starts); dirs <- dirs[ord]; starts <- starts[ord]
  ends <- c(starts[-1] - 1, as.Date('9999-12-31'))
  keep <- starts <= win_end & ends >= win_start & ends >= ANNEX_EFFECTIVE &
    starts < ANNEX_1C_START
  if (!any(keep)) stop('No snapshot windows overlap the analysis window.')

  sel <- c('hts10', 'country', 'total_rate', 'rate_232', 'statutory_rate_232',
           'base_rate', 's232_annex', 'heading_program')
  map_dfr(which(keep), function(i) {
    d <- arrow::read_parquet(file.path(dirs[i], 'rates.parquet'),
                             col_select = dplyr::any_of(sel))
    if (!all(c('s232_annex', 'heading_program') %in% names(d))) {
      stop('Snapshot ', basename(dirs[i]), ' lacks s232_annex/heading_program ',
           '— use a vintage >= 2026-07-01-16.')
    }
    d %>%
      filter(s232_annex %in% c('annex_1a', 'annex_1b', 'annex_3'),
             !heading_program, rate_232 > 0) %>%
      mutate(valid_from = starts[i], valid_until = pmin(ends[i], as.Date('2027-12-31')))
  })
}

#' no_232 counterfactual totals per cell-window (local rds layout built by
#' scripts/submit_no232_annex_snapshots.sh), filtered to the affected HTS10
#' set at load (each rds is a full ~4.9M-row grid — filtering keeps the run
#' inside the 5 GB interactive cap). Windows are derived from revision policy
#' dates and must cover every actual window in use — fail loud on gaps rather
#' than silently dropping cells.
load_no232 <- function(no232_dir, needed_windows, affected_hts10) {
  files <- list.files(no232_dir, pattern = '^snapshot_.*\\.rds$', full.names = TRUE)
  if (length(files) == 0) {
    stop('No snapshot_<rev>.rds files in ', no232_dir,
         ' — run scripts/submit_no232_annex_snapshots.sh first.')
  }
  revs <- sub('^snapshot_(.*)\\.rds$', '\\1', basename(files))
  rev_dates <- load_revision_dates(use_policy_dates = TRUE) %>%
    arrange(effective_date)
  info <- tibble(rev = revs, path = files) %>%
    left_join(rev_dates %>% select(rev = revision, valid_from = effective_date),
              by = 'rev') %>%
    filter(!is.na(valid_from)) %>%
    arrange(valid_from)

  missing <- setdiff(as.character(needed_windows), as.character(info$valid_from))
  if (length(missing) > 0) {
    stop('no_232 snapshots missing for actual windows: ',
         paste(missing, collapse = ', '),
         '. Build them (scripts/submit_no232_annex_snapshots.sh) first.')
  }

  map_dfr(seq_len(nrow(info)), function(i) {
    readRDS(info$path[i]) %>%
      filter(hts10 %in% affected_hts10) %>%
      select(hts10, country, total_rate_no232 = total_rate) %>%
      mutate(valid_from = info$valid_from[i])
  })
}


# =============================================================================
# Main
# =============================================================================

run_calibration <- function(opts) {
  months <- format(seq(as.Date(paste0(opts$start, '-01')),
                       as.Date(paste0(opts$end, '-01')), by = 'month'), '%Y-%m')
  bad <- months[as.Date(paste0(months, '-01')) >= ANNEX_1C_START]
  if (length(bad) > 0) {
    stop('Months ', paste(bad, collapse = ', '), ' fall in the annex_1c era ',
         '(>= ', format(ANNEX_1C_START), ') — out of scope for this v1.')
  }
  win_start <- as.Date(paste0(months[1], '-01'))
  win_end <- seq(as.Date(paste0(tail(months, 1), '-01')),
                 by = 'month', length.out = 2)[2] - 1

  message('== Statutory side ==')
  actual <- load_actual_annex(opts$snapshots_dir, win_start, win_end)
  message('  actual annex universe: ', n_distinct(actual$hts10), ' hts10 x ',
          n_distinct(actual$country), ' countries across ',
          n_distinct(actual$valid_from), ' windows')
  no232 <- load_no232(opts$no232_dir, unique(actual$valid_from),
                      unique(actual$hts10))

  cells <- actual %>%
    inner_join(no232, by = c('hts10', 'country', 'valid_from'),
               relationship = 'one-to-one') %>%
    build_candidates()
  n_lost <- nrow(actual) - nrow(cells)
  if (n_lost > 0) {
    message('  NOTE: ', n_lost, ' actual cell-windows had no no_232 row ',
            '(grid mismatch) and were dropped.')
  }

  message('== IMDB side ==')
  affected <- sort(unique(cells$hts10))
  imdb <- map_dfr(months, function(ym) {
    zp <- ensure_imdb_month(ym, opts$imdb_dir, opts$download)
    if (is.na(zp)) {
      message('  ', ym, ': IMDB ZIP not available',
              if (!opts$download) ' (rerun with --download)', ' — skipped')
      return(tibble())
    }
    message('  ', ym, ': parsing ', basename(zp))
    parse_imdb_month(zp, affected)
  })
  if (nrow(imdb) == 0) stop('No IMDB data for any requested month.')

  message('== Decomposition ==')
  # Day-weight candidates to cell-months, annex-era days only.
  monthly <- map_dfr(unique(imdb$year_month), function(ym) {
    w <- month_weights(cells$valid_from, cells$valid_until, ym)
    cells %>%
      mutate(.days = w$days, .month_days = w$month_days) %>%
      filter(.days > 0) %>%
      group_by(hts10, country, s232_annex) %>%
      summarise(
        T_full = weighted.mean(T_full, .days),
        T_us   = weighted.mean(T_us,   .days),
        T_exit = weighted.mean(T_exit, .days),
        regime_days_share = sum(.days) / first(.month_days),
        .groups = 'drop'
      ) %>%
      mutate(year_month = ym)
  })

  cellmonth <- imdb %>%
    inner_join(monthly, by = c('year_month', 'hts10', 'country'),
               relationship = 'one-to-one') %>%
    mutate(realized = cal_dut / con_val)

  cls <- classify_route(cellmonth$realized, cellmonth$T_full,
                        cellmonth$T_us, cellmonth$T_exit,
                        sep_tol = opts$sep_tol, resid_tol = opts$resid_tol)
  bnd <- route_bounds(cellmonth$realized, cellmonth$T_full,
                      cellmonth$T_us, cellmonth$T_exit)
  cellmonth <- cellmonth %>%
    mutate(route = cls$route, ambiguous = cls$ambiguous, dist = cls$dist,
           z0_raw = bnd$z0_raw, z0 = bnd$z0, u_raw = bnd$u_raw, u = bnd$u,
           partial_month = regime_days_share < 0.999)

  # ---- outputs -------------------------------------------------------------
  diag_dir <- here('output', 'diagnostics')
  dir.create(diag_dir, showWarnings = FALSE, recursive = TRUE)
  monthly_path <- file.path(diag_dir, 's232_annex_routes_monthly.csv')
  write_csv(cellmonth %>% arrange(year_month, desc(con_val)), monthly_path)
  message('Wrote ', monthly_path, ' (', nrow(cellmonth), ' cell-months)')

  shares <- cellmonth %>%
    group_by(hts10, country, s232_annex) %>%
    summarise(
      # NOTE: assignment order matters — dplyr::summarise makes each result
      # visible to later expressions, so `con_val = sum(con_val)` must come
      # AFTER every expression that uses the row-level con_val vector.
      months        = n(),
      realized_vw   = weighted.mean(realized, con_val),
      T_full_vw     = weighted.mean(T_full, con_val),
      T_us_vw       = weighted.mean(T_us, con_val),
      T_exit_vw     = weighted.mean(T_exit, con_val),
      share_full        = sum(con_val[route == 'full']) / sum(con_val),
      share_us_origin   = sum(con_val[route == 'us_origin']) / sum(con_val),
      share_exit        = sum(con_val[route == 'exit']) / sum(con_val),
      share_unexplained = sum(con_val[route == 'unexplained']) / sum(con_val),
      share_ambiguous   = sum(con_val[ambiguous]) / sum(con_val),
      z0_raw_vw     = weighted.mean(z0_raw, con_val, na.rm = TRUE),
      u_raw_vw      = weighted.mean(u_raw, con_val, na.rm = TRUE),
      any_partial_month = any(partial_month),
      con_val       = sum(con_val),
      .groups = 'drop'
    )
  shares_path <- here('resources', 's232_annex_route_shares.csv')
  write_csv(shares %>% arrange(desc(con_val)), shares_path)
  message('Wrote ', shares_path, ' (', nrow(shares), ' cells)')

  # ---- summary (issue-#13 style, ch84/85 highlighted) ----------------------
  summarise_block <- function(d, label, strong_exit_min = 0.05) {
    tot <- sum(d$con_val)
    cat(sprintf('\n-- %s ($%.1fB, %d cell-months; ambiguous %.1f%%) --\n',
                label, tot / 1e9, nrow(d),
                100 * sum(d$con_val[d$ambiguous]) / tot))
    # 'exit' evidence strength: on a §122-charged line T_exit is materially
    # positive, so realized ≈ T_exit means duty WAS collected on the
    # without-232 branch — positive evidence of a .01/.03 claim. On an
    # ITA/zero-base line T_exit ≈ 0 and realized ≈ 0 cannot be distinguished
    # from non-entry / noncompliance — weak evidence, stays contestable.
    d %>%
      mutate(route = if_else(route == 'exit',
                             if_else(T_exit >= strong_exit_min,
                                     'exit (strong: T_exit>0 paid)',
                                     'exit (weak: T_exit~0, could be eta)'),
                             route)) %>%
      group_by(route) %>%
      summarise(value_share = sum(con_val) / tot, .groups = 'drop') %>%
      arrange(desc(value_share)) %>%
      mutate(value_share = sprintf('%.1f%%', 100 * value_share)) %>%
      as.data.frame() %>% print(row.names = FALSE)
    invisible(NULL)
  }
  primary <- cellmonth %>% filter(!partial_month)
  if (nrow(primary) > 0) {
    summarise_block(primary, 'ALL annex cells, full-regime months')
    ch8485 <- primary %>% filter(substr(hts10, 1, 2) %in% c('84', '85'))
    if (nrow(ch8485) > 0) summarise_block(ch8485, 'ch84/85 only, full-regime months')
  }
  partial <- cellmonth %>% filter(partial_month)
  if (nrow(partial) > 0) {
    summarise_block(partial, 'PARTIAL-regime months (April 2026) — diagnostic only')
  }

  invisible(cellmonth)
}

if (sys.nframe() == 0) {
  opts <- parse_cli(commandArgs(trailingOnly = TRUE))
  run_calibration(opts)
}
