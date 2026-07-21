#!/usr/bin/env Rscript
# Spot-check the Section 338 Canada authority on the actual computed snapshots
# (pre-gather). Turn-on revision = bnd_2026-08-19; every earlier revision must
# carry rate_s338 all-zero (the column is RATE_SCHEMA proper, so it is PRESENT
# but inert pre-turn-on — unlike the scenario s301fl/br columns).
#
# Usage: Rscript scripts/verify_s338_snapshot.R [timeseries_dir]
#   default timeseries_dir = data/timeseries  (pass e.g. data/timeseries/new_301
#   to check the scenario variant, or a vintage's snapshot dir)
suppressPackageStartupMessages({ library(tidyverse); library(here) })

args <- commandArgs(trailingOnly = TRUE)
TS <- if (length(args) >= 1) args[1] else 'data/timeseries'
CA <- '1220'
fails <- 0L
must <- function(cond, msg) {
  if (isTRUE(cond)) cat('  PASS:', msg, '\n')
  else { fails <<- fails + 1L; cat('  FAIL:', msg, '\n') }
}

covered <- read_csv(here('resources', 's338_products.csv'),
                    col_types = cols(.default = col_character()))
gn6 <- read_csv(here('resources', 's338_gn6_exempt_products.csv'),
                col_types = cols(hts8 = col_character()))
gn6_overlap <- intersect(covered$hts8, gn6$hts8)

cat('================ PRE-turn-on: snapshot_bnd_2026-07-24 ================\n')
pre_path <- file.path(TS, 'snapshot_bnd_2026-07-24.rds')
if (file.exists(pre_path)) {
  pre <- readRDS(pre_path)
  must('rate_s338' %in% names(pre), 'rate_s338 column present (RATE_SCHEMA)')
  must(all(pre$rate_s338 == 0), 'rate_s338 all-zero pre-turn-on')
} else cat('  SKIP: ', pre_path, ' not found\n', sep = '')

cat('\n================ TURN-ON: snapshot_bnd_2026-08-19 ================\n')
s <- readRDS(file.path(TS, 'snapshot_bnd_2026-08-19.rds'))
ca <- s %>% filter(country == CA) %>% mutate(hts8 = substr(hts10, 1, 8))
non_ca <- s %>% filter(country != CA)
cat('Canada rows: ', nrow(ca), ' | rows with rate_s338 > 0: ',
    sum(ca$rate_s338 > 0), '\n', sep = '')

must(all(non_ca$rate_s338 == 0), 'rate_s338 = 0 on every non-Canada row')
must(sum(ca$rate_s338 > 0) > 0, 'some Canada rows carry s338')
must(all(ca$rate_s338[!ca$hts8 %in% covered$hts8] == 0),
     'rate_s338 = 0 off the covered lists (positive lists only)')
must(all(ca$rate_s338 <= 0.50 + 1e-12), 'rate_s338 never exceeds 0.50')

# annex_2 = REMOVED from §232 scope — those articles still pay (note 51(c)
# cites the 9903.82 rate headings, which no longer provide for them).
ANNEX_IN_SCOPE <- c('annex_1a', 'annex_1b', 'annex_1c', 'annex_3')

# full 0.50 on covered, non-232, non-GN6-overlap rows
plain <- ca %>% filter(hts8 %in% covered$hts8, !hts8 %in% gn6_overlap,
                       coalesce(statutory_rate_232, 0) == 0,
                       !s232_annex %in% ANNEX_IN_SCOPE,
                       !coalesce(heading_program, FALSE))
must(nrow(plain) > 0 && all(abs(plain$rate_s338 - 0.50) < 1e-12),
     sprintf('full 0.50 on the %d plain covered Canada rows', nrow(plain)))

# whisky spot checks. 2208.30.30 is Irish/Scotch whisky; Canadian whisky (the
# proclamation's actual high-trade target) classifies under 2208.30.60. Both are
# on the alcohol list — check each so a regression isolated to the Canadian line
# is caught.
wh_is <- ca %>% filter(hts8 == '22083030')
must(nrow(wh_is) > 0 && all(abs(wh_is$rate_s338 - 0.50) < 1e-12),
     'Irish/Scotch whisky 2208.30.30 -> 0.50')
wh_ca <- ca %>% filter(hts8 == '22083060')
must(nrow(wh_ca) > 0 && all(abs(wh_ca$rate_s338 - 0.50) < 1e-12),
     'Canadian whisky 2208.30.60 -> 0.50')

# beer 2203.00.00: on the alcohol list AND annex_2-tagged (removed from the
# aluminum-derivative scope by the April 2026 annex) — must PAY the 0.50.
beer <- ca %>% filter(hts8 == '22030000')
must(nrow(beer) > 0 && all(abs(beer$rate_s338 - 0.50) < 1e-12),
     'Canadian beer 2203.00.00 (annex_2) -> 0.50 (removed-from-232-scope still pays)')

# §232 full-exclusion mask (tier-scoped)
mask232 <- ca %>% filter(coalesce(statutory_rate_232, 0) > 0 |
                           s232_annex %in% ANNEX_IN_SCOPE |
                           coalesce(heading_program, FALSE))
must(all(mask232$rate_s338 == 0),
     sprintf('§232-scope exclusion: 0 on all %d in-scope Canada rows', nrow(mask232)))
a2 <- ca %>% filter(s232_annex == 'annex_2', coalesce(statutory_rate_232, 0) == 0,
                    !coalesce(heading_program, FALSE), hts8 %in% covered$hts8,
                    !hts8 %in% gn6_overlap)
must(nrow(a2) == 0 || all(a2$rate_s338 > 0),
     sprintf('annex_2 covered rows all PAY (%d rows)', nrow(a2)))
# 4413.00.00 (densified wood, alcohol list) is NOT in the §232 wood-program
# product lists (9903.76 covers 4403/4406/4407 logs+lumber and furniture), so
# note 51(c)(4) does NOT exclude it — it pays the full 0.50. (Verified against
# the bnd_2026-08-19 probe snapshot 2026-07-20: heading_program FALSE.)
w44 <- ca %>% filter(hts8 == '44130000', !coalesce(heading_program, FALSE),
                     is.na(s232_annex), coalesce(statutory_rate_232, 0) == 0)
must(nrow(w44) > 0 && all(abs(w44$rate_s338 - 0.50) < 1e-12),
     '4413.00.00 (outside the 9903.76 wood lists) pays the full 0.50')

# GN6 utilization scaling: overlap rows in (0, 0.50], measured ones strictly < .50
gn6_rows <- ca %>% filter(hts8 %in% gn6_overlap,
                          coalesce(statutory_rate_232, 0) == 0,
                          !s232_annex %in% ANNEX_IN_SCOPE,
                          !coalesce(heading_program, FALSE))
util <- read_csv(here('resources', 's122_aircraft_utilization.csv'),
                 col_types = cols(hts10 = col_character(),
                                  exempt_share = col_double(),
                                  .default = col_guess()))
meas <- gn6_rows %>% inner_join(util %>% select(hts10, exempt_share), by = 'hts10') %>%
  filter(exempt_share > 1e-6)
must(nrow(meas) > 0 && all(abs(meas$rate_s338 - 0.50 * (1 - pmin(pmax(meas$exempt_share, 0), 1))) < 1e-9),
     sprintf('GN6 measured rows scaled by 1 - measured share (%d rows)', nrow(meas)))
# (a handful of measured lines have share ~= 1, e.g. 4823.90.86.20 -> 0 is correct)
must(mean(gn6_rows$rate_s338 > 0) > 0.8,
     'GN6 overlap rows overwhelmingly NOT fully exempted (the ->0 fallback, not §122\'s ->1)')

# additive stacking: totals include the full s338 on its rows
chk <- ca %>% filter(rate_s338 > 0)
must(all(chk$total_additional >= chk$rate_s338 - 1e-9),
     'total_additional >= rate_s338 (additive; never displaced)')

# statutory twin
if ('statutory_rate_s338' %in% names(s)) {
  must(all(abs(ca$statutory_rate_s338 - ca$rate_s338) < 1e-12),
       'statutory_rate_s338 == rate_s338 (no post-statutory reductions apply)')
}

cat('\n================ ', ifelse(fails == 0, 'ALL PASS', paste(fails, 'FAILURES')),
    ' ================\n', sep = '')
if (fails > 0) quit(status = 1)
