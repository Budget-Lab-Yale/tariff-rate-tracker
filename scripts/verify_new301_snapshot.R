#!/usr/bin/env Rscript
# Spot-check the new_301 Brazil §301 on the actual computed snapshots (pre-gather).
# Turn-on revision = bnd_2026-07-24 (both §301s live); a pre-turn-on revision should
# carry NEITHER scenario column (dropped when all-zero => baseline-safe).
suppressPackageStartupMessages(library(tidyverse))
TS <- 'data/timeseries/new_301'
BR <- '3510'

cat('================ PRE-turn-on: snapshot_bnd_2026-06-08 ================\n')
pre <- readRDS(file.path(TS, 'snapshot_bnd_2026-06-08.rds'))
cat('rate_s301br present? ', 'rate_s301br' %in% names(pre),
    ' | rate_s301fl present? ', 'rate_s301fl' %in% names(pre),
    '   (both should be FALSE — dormant/dropped)\n', sep = '')

cat('\n================ TURN-ON: snapshot_bnd_2026-07-24 ================\n')
s <- readRDS(file.path(TS, 'snapshot_bnd_2026-07-24.rds'))
cat('columns present: rate_s301br=', 'rate_s301br' %in% names(s),
    '  rate_s301fl=', 'rate_s301fl' %in% names(s),
    '  rate_232=', 'rate_232' %in% names(s),
    '  total_rate=', 'total_rate' %in% names(s), '\n', sep = '')

br <- s %>% filter(country == BR)
cat('\nBrazil (3510) rows: ', nrow(br), '\n', sep = '')

# 1. Brazil §301 rate distribution
cat('\n-- rate_s301br distribution on Brazil rows --\n')
print(br %>% count(rate_s301br) %>% arrange(desc(n)))

# 2. forced-labor §301 still applies to Brazil at 12.5% (additive) --
cat('\n-- rate_s301fl distribution on Brazil rows (expect 0.125 where in scope) --\n')
print(br %>% count(rate_s301fl) %>% arrange(desc(n)))

# 3. §232 carve-out: Brazil rows with rate_232 > 0 must have rate_s301br == 0
viol <- br %>% filter(rate_232 > 0 & rate_s301br > 0)
cat('\n-- §232 carve-out check: Brazil rows with rate_232>0 AND rate_s301br>0 = ',
    nrow(viol), ' (must be 0) --\n', sep = '')
cat('   Brazil §232 rows (rate_232>0): ', sum(br$rate_232 > 0),
    ' | of those, rate_s301br==0: ', sum(br$rate_232 > 0 & br$rate_s301br == 0), '\n', sep = '')

# 4. additive stack: a non-232, non-exempt Brazil good should show BOTH 0.25 and 0.125
both <- br %>% filter(rate_232 == 0 & rate_s301br > 0 & rate_s301fl > 0)
cat('\n-- additive stack: non-232 Brazil rows carrying BOTH §301s = ', nrow(both), ' --\n', sep = '')
if (nrow(both) > 0) {
  ex <- both %>% slice(1)
  cat(sprintf('   example hts10=%s: base=%.3f s301br=%.3f s301fl=%.3f total=%.3f\n',
              ex$hts10, ex$base_rate %||% NA, ex$rate_s301br, ex$rate_s301fl, ex$total_rate))
}

# 5. exempt annex: Brazil rows where rate_s301br==0 but not §232 (annex-exempted)
annex_exempt <- br %>% filter(rate_232 == 0 & rate_s301br == 0)
cat('\n-- Brazil non-232 rows with rate_s301br==0 (annex-exempt or out-of-scope): ',
    nrow(annex_exempt), ' --\n', sep = '')

cat('\n================ DONE ================\n')
