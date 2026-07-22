#!/usr/bin/env Rscript
# Spot-check the Section 301 Brazil BASELINE authority (final action, FR Doc
# 2026-14542) on the actual computed snapshots (pre-gather). Turn-on revision =
# bnd_2026-07-22; every earlier revision must carry rate_s301br all-zero (the
# column is RATE_SCHEMA proper, so it is PRESENT but inert pre-turn-on).
#
# Usage: Rscript scripts/verify_s301_brazil_snapshot.R [timeseries_dir]
#   default timeseries_dir = data/timeseries  (pass e.g. data/timeseries/new_301
#   to check a scenario variant — the Brazil layer is baseline law and must be
#   IDENTICAL there; in data/timeseries/no_s338 it must also be identical, since
#   no_s338 only zeroes s338).
suppressPackageStartupMessages({ library(tidyverse); library(here) })

args <- commandArgs(trailingOnly = TRUE)
TS <- if (length(args) >= 1) args[1] else 'data/timeseries'
BR <- '3510'
fails <- 0L
must <- function(cond, msg) {
  if (isTRUE(cond)) cat('  PASS:', msg, '\n')
  else { fails <<- fails + 1L; cat('  FAIL:', msg, '\n') }
}

read_list <- function(f) read_csv(here('resources', f),
               col_types = cols(hts8 = col_character(), .default = col_character()))
ex  <- read_list('s301_brazil_exempt_products.csv')    # note 50(a)(ii)+(iii): fully exempt
air <- read_list('s301_brazil_aircraft_products.csv')  # (a)(iv): pays 25% * (1-0.90) = 2.5%
phr <- read_list('s301_brazil_pharma_products.csv')    # (a)(v):  pays 25% * (1-0.50) = 12.5%
AIR_RATE <- 0.25 * (1 - 0.90)
PHR_RATE <- 0.25 * (1 - 0.50)

cat('================ PRE-turn-on: snapshot_bnd_2026-06-08 ================\n')
pre_path <- file.path(TS, 'snapshot_bnd_2026-06-08.rds')
if (file.exists(pre_path)) {
  pre <- readRDS(pre_path)
  must('rate_s301br' %in% names(pre), 'rate_s301br column present (RATE_SCHEMA)')
  must(all(pre$rate_s301br == 0), 'rate_s301br all-zero pre-turn-on')
} else cat('  SKIP: ', pre_path, ' not found\n', sep = '')

cat('\n================ TURN-ON: snapshot_bnd_2026-07-22 ================\n')
s <- readRDS(file.path(TS, 'snapshot_bnd_2026-07-22.rds'))
br <- s %>% filter(country == BR) %>% mutate(hts8 = substr(hts10, 1, 8))
non_br <- s %>% filter(country != BR)
cat('Brazil rows: ', nrow(br), ' | rows with rate_s301br > 0: ',
    sum(br$rate_s301br > 0), '\n', sep = '')

must(all(non_br$rate_s301br == 0), 'rate_s301br = 0 on every non-Brazil row')
must(sum(br$rate_s301br > 0) > 0, 'some Brazil rows carry the 25%')
must(all(abs(br$rate_s301br[br$rate_s301br > 0] - 0.25) < 1e-9 |
           br$rate_s301br[br$rate_s301br > 0] < 0.25),
     'positive rate_s301br = 0.25 (or ch98 value-basis scaled below)')
must(all(br$rate_s301br <= 0.25 + 1e-12), 'rate_s301br never exceeds 0.25')

# Unconditional exemptions (note 50(a)(ii)+(iii)): exempt hts8 pay zero.
must(all(br$rate_s301br[br$hts8 %in% ex$hts8] == 0),
     'rate_s301br = 0 on every unconditional-exempt hts8')
# Use-conditional lists (note 50(a)(iv)/(v)): scaled by (1 - utilization share),
# so covered lines pay 2.5% / 12.5% (or less: §232 mask -> 0, ch98 value-basis
# scales below the statutory level).
air_r <- br$rate_s301br[br$hts8 %in% air$hts8]
must(all(abs(air_r - AIR_RATE) < 1e-9 | air_r < AIR_RATE) && any(air_r > 0),
     'aircraft-use lines pay at most 2.5% (share-scaled), some charged')
phr_r <- br$rate_s301br[br$hts8 %in% phr$hts8]
must(all(abs(phr_r - PHR_RATE) < 1e-9 | phr_r < PHR_RATE) && any(phr_r > 0),
     'pharma-use lines pay at most 12.5% (share-scaled), some charged')
# Spot the two headline diffs vs the June annex:
must(all(br$rate_s301br[br$hts8 == '72011000'] == 0),
     'pig iron 7201.10.00 exempt (final-annex addition)')
pulp <- br %>% filter(hts8 == '47020000', rate_232 == 0, !heading_program)
if (nrow(pulp) > 0) {
  must(all(pulp$rate_s301br > 0),
       'dissolving pulp 4702.00.00 PAYS (removed from the June annex; non-§232 rows)')
} else cat('  SKIP: no non-§232 4702.00.00 Brazil rows to check\n')

# §232 FULL-article carve-out (note 50(a)(vi)) — scope mask, not content split:
must(all(br$rate_s301br[coalesce(br$statutory_rate_232, br$rate_232) > 0] == 0),
     'rate_s301br = 0 wherever statutory §232 > 0 (full-article exclusion)')
if ('s232_annex' %in% names(br)) {
  in_scope <- br$s232_annex %in% c('annex_1a', 'annex_1b', 'annex_1c', 'annex_3')
  must(all(br$rate_s301br[in_scope] == 0),
       'rate_s301br = 0 on in-scope s232_annex tiers')
  a2 <- br %>% filter(s232_annex == 'annex_2',
                      coalesce(statutory_rate_232, 0) == 0, !heading_program,
                      !hts8 %in% ex$hts8)
  if (nrow(a2) > 0) {
    must(all(a2$rate_s301br > 0),
         'annex_2 (REMOVED from §232 scope) non-exempt articles PAY the 25%')
  } else cat('  SKIP: no annex_2 non-exempt Brazil rows to check\n')
}
if ('heading_program' %in% names(br)) {
  must(all(br$rate_s301br[coalesce(br$heading_program, FALSE)] == 0),
       'rate_s301br = 0 on §232 heading-program rows (autos/MHD/wood/semi)')
}

# Additive stacking: on rows carrying the 25%, total_additional includes it fully.
pos <- br %>% filter(rate_s301br > 0)
must(all(pos$total_additional >= pos$rate_s301br - 1e-9),
     'total_additional >= rate_s301br on charged rows (additive, never displaced)')

cat('\n================ LAST PRE-BOUNDARY: rate stays on later revisions =====\n')
post_path <- file.path(TS, 'snapshot_bnd_2026-08-19.rds')
if (file.exists(post_path)) {
  post <- readRDS(post_path)
  must(sum(post$rate_s301br[post$country == BR] > 0) > 0,
       'Brazil 25% persists on the bnd_2026-08-19 snapshot (date-gate, not one-off)')
} else cat('  SKIP: ', post_path, ' not found\n', sep = '')

cat(sprintf('\n================ DONE: %d failures ================\n', fails))
if (fails > 0) quit(status = 1)
