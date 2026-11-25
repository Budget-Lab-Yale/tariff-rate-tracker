#!/usr/bin/env Rscript
# Check the proposed Section 301 "excess capacity" duty (rate_s301ec) and the
# proposed Brazil aircraft change in a built vintage.
#
# Usage: Rscript scripts/verify_s301ec_snapshot.R <vintage_dir>
#   <vintage_dir> holds actual/snapshots/ and scenarios/<name>/snapshots/, each
#   with one valid_from=<date>/rates.parquet per interval (the layout
#   config/build/s301ec.yaml produces).
#
# What it checks:
#   actual      no 2027-04-01 snapshot; rate_s301ec zero; Brazil finished
#               aircraft still at 2.5%.
#   scenarios   a 2027-04-01 snapshot exists; the interval before it equals
#               actual; from 2027-04-01 every covered row carries the duty the
#               rules in config/policy_params.yaml imply, recomputed here from
#               the snapshot's own MFN, forced-labor and Section 232 columns.
# Chapter 98 rows are only checked against the ceiling: their duties are zeroed
# or scaled to the repair value later in the calculator.
# It reads whole snapshots (several GB), so run it in a Slurm job.
suppressPackageStartupMessages({ library(tidyverse); library(here); library(arrow) })
suppressMessages({
  source(here('src', 'core', 'helpers.R'))
  source(here('src', 'model', 'authority_spec.R'))
  source(here('src', 'model', 'policy_params.R'))
  source(here('src', 'model', 'authority_adapter.R'))
  source(here('src', 'pipeline', '05_parse_policy_params.R'))
  source(here('src', 'pipeline', '06_calculate_rates.R'))
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop('Usage: Rscript scripts/verify_s301ec_snapshot.R <vintage_dir>')
VINTAGE <- args[1]
SCENARIOS <- c('ec301_proposed', 'ec301_no_deals', 'ec301_all_deals')
START <- '2027-04-01'
BR <- '3510'
TOL <- 1e-9
fails <- 0L
must <- function(cond, msg) {
  if (isTRUE(cond)) cat('  PASS:', msg, '\n')
  else { fails <<- fails + 1L; cat('  FAIL:', msg, '\n') }
}
same <- function(x, y) length(x) == length(y) && all(abs(x - y) < TOL)

COLS <- c('hts10', 'country', 'base_rate', 'statutory_base_rate', 'rate_232',
          'statutory_rate_232', 's232_annex', 'heading_program',
          'rate_232_nondisplacing', 's232_nondisplacing', 'rate_s301fl',
          'rate_s301br', 'rate_s301ec', 'total_additional')
snap_dir <- function(series) {
  if (series == 'actual') file.path(VINTAGE, 'actual', 'snapshots')
  else file.path(VINTAGE, 'scenarios', series, 'snapshots')
}
intervals <- function(series) {
  sort(sub('^valid_from=', '', list.files(snap_dir(series), pattern = '^valid_from=')))
}
read_snap <- function(series, valid_from) {
  path <- file.path(snap_dir(series), paste0('valid_from=', valid_from), 'rates.parquet')
  read_parquet(path, col_select = any_of(COLS)) %>% arrange(hts10, country)
}

pp <- suppressMessages(load_policy_params())
mod <- pp$section_301_brazil$modification_2026_11
finished_aircraft <- as.character(unlist(mod$aircraft_lines))
OLD_AIRCRAFT_RATE <- 0.25 * (1 - pp$section_301_brazil$aircraft_exempt_share)
brazil_aircraft <- function(d) {
  d %>% filter(country == BR, substr(hts10, 1, 8) %in% finished_aircraft)
}

cat('================ actual ================\n')
iv_actual <- intervals('actual')
must(!START %in% iv_actual, paste('actual has no', START, 'snapshot'))
last_actual <- max(iv_actual)
pre_date <- max(iv_actual[iv_actual < START])
actual_pre  <- read_snap('actual', pre_date)
actual_last <- if (last_actual == pre_date) actual_pre else read_snap('actual', last_actual)
must('rate_s301ec' %in% names(actual_last) && all(actual_last$rate_s301ec == 0) &&
       all(actual_pre$rate_s301ec == 0),
     'actual: rate_s301ec present and zero through the end of the series')
ba <- brazil_aircraft(actual_last)
must(nrow(ba) > 0 && same(ba$rate_s301br, rep(OLD_AIRCRAFT_RATE, nrow(ba))),
     'actual: Brazil finished aircraft still pay 2.5%')

for (s in SCENARIOS) {
  cat('\n================ ', s, ' ================\n', sep = '')
  if (!dir.exists(snap_dir(s))) { must(FALSE, paste(s, 'is in the vintage')); next }
  iv <- intervals(s)
  must(START %in% iv, paste('has a', START, 'snapshot'))
  must(setequal(setdiff(iv, START), iv_actual),
       'the other interval dates are the same as in actual')
  if (!START %in% iv) next

  pre <- read_snap(s, pre_date)
  must(all(pre$rate_s301ec == 0) &&
         identical(pre$total_additional, actual_pre$total_additional) &&
         identical(pre$rate_s301br, actual_pre$rate_s301br),
       paste0('interval from ', pre_date, ' equals actual (no duty before the start date)'))
  rm(pre)

  pp_s <- suppressMessages(load_policy_params(scenario = s))
  cfg <- pp_s$section_301_excess_capacity
  countries <- read_csv(here('resources', 'census_codes.csv'),
                        col_types = cols(.default = col_character()))$Code
  terms <- .resolve_s301ec_terms(cfg, pp_s$eu27_codes, countries)
  lists <- .resolve_s301ec_lists(cfg)

  d <- read_snap(s, START)
  must(all(d$rate_s301ec[!d$country %in% terms$country] == 0),
       'zero outside the 14 economies')
  must(all(d$rate_s301ec >= 0) && all(d$total_additional >= d$rate_s301ec - TOL),
       'never negative, and counted in full in total_additional')

  # Brazil: finished aircraft at 10%, aircraft parts and the rest as in actual.
  bs <- brazil_aircraft(d)
  must(nrow(bs) > 0 && same(bs$rate_s301br, rep(mod$aircraft_rate, nrow(bs))),
       'Brazil finished aircraft pay a flat 10%')
  other_brazil <- function(x) {
    x %>% filter(country == BR, !substr(hts10, 1, 8) %in% finished_aircraft) %>%
      pull(rate_s301br)
  }
  must(identical(other_brazil(d), other_brazil(actual_pre)),
       'every other Brazil line pays what it pays in actual')

  # Recompute the duty for covered countries from the snapshot's own columns.
  e <- d %>% filter(country %in% terms$country) %>%
    left_join(terms, by = 'country') %>%
    mutate(h8 = substr(hts10, 1, 8), ch98 = substr(hts10, 1, 2) == '98')
  rm(d)
  hit <- function(codes) e$h8 %in% codes | e$hts10 %in% codes
  e$common_full <- hit(lists$common_full)
  e$share <- case_when(hit(lists$common_aircraft) ~ lists$aircraft_share,
                       hit(lists$common_pharma) ~ lists$pharma_share, TRUE ~ 0)
  e$country_full <- paste(e$country, e$h8) %in%
    paste(lists$country_full$country, lists$country_full$hts_code)
  e$annex_b <- hit(lists$china_annex_b)
  e$in_232 <- .s232_in_scope(e) | e$hts10 %in% lists$patented_pharma_hts10
  post <- as.character(unlist(cfg$post_preference_cap_countries))
  e <- e %>% mutate(
    # MFN as the forced-labor cap sees it: the rate after claimed preferences
    # for South Korea, the column-1 general rate for the others.
    mfn = if_else(net_of_mfn,
                  if_else(country %in% post, base_rate, statutory_base_rate), 0),
    # The snapshot stores the forced-labor duty after use-share scaling.
    fl_exempt = if_else(rate_s301fl > 0 & share > 0, share, 0),
    fl_full = rate_s301fl / (1 - fl_exempt))

  other <- e %>% filter(!china_rules, !ch98)
  exempt <- other$common_full | other$country_full | other$in_232
  must(all(other$rate_s301ec[exempt] == 0),
       'non-China: zero on the common list, country lists and Section 232 goods')
  cov <- other[!exempt, ]
  must(same(cov$rate_s301ec, (1 - cov$share) * pmax(cov$rate - cov$mfn - cov$fl_full, 0)),
       'non-China covered goods: stated rate less MFN (where all-in) and forced labor')
  must(any(cov$rate_s301ec > 0), 'some non-China goods are charged')
  ore <- other %>% filter(h8 == '26011200', !in_232)
  must(all(ore$rate_s301ec == 0) && all(ore$rate_s301fl > 0),
       'non-China 2601.12.00: no new duty, forced labor still charged')

  china <- e %>% filter(china_rules, !ch98)
  if (all(china$annexes_apply)) {
    # Annex A is read first, so a line printed in both annexes is an Annex A line.
    expect <- case_when(
      china$common_full ~ cfg$china_annex_a_rate,
      china$share > 0 ~ china$share * cfg$china_annex_a_rate +
        (1 - china$share) * pmax(china$rate - china$fl_full, 0),
      china$annex_b ~ 0,
      TRUE ~ pmax(china$rate - china$rate_s301fl, 0))
    must(same(china$rate_s301ec, expect),
         'China: 10% on Annex A, zero on Annex B, 20% less forced labor elsewhere')
    steel <- china %>% filter(in_232, !common_full, share == 0, !annex_b)
    must(nrow(steel) > 0 && same(steel$rate_s301ec, steel$rate),
         'China Section 232 goods pay the full 20% (no Section 232 exemption)')
  } else {
    must(same(china$rate_s301fl + china$rate_s301ec, china$rate),
         'China: forced labor + new duty = 40% on every good')
  }
  must(all(e$rate_s301ec[e$ch98] <= e$rate[e$ch98] + TOL),
       'chapter 98 rows never exceed the stated rate')
  rm(e)
}

cat(sprintf('\n================ DONE: %d failures ================\n', fails))
if (fails > 0) quit(status = 1)
