#!/usr/bin/env Rscript
# Verify the §232 carve-out on the EFFECTIVE Brazil §301 contribution (not the raw
# rate column). content_split scales the contribution by nonmetal_share when rate_232>0,
# so a whole-article §232 good (nonmetal_share=0) contributes ~0 Brazil §301.
suppressPackageStartupMessages(library(tidyverse))
source(here::here('src', 'stacking.R'))   # compute_nonmetal_share
TS <- 'data/timeseries/new_301'; BR <- '3510'

s  <- readRDS(file.path(TS, 'snapshot_bnd_2026-07-24.rds'))
br <- s %>% filter(country == BR)

# Reproduce the content_split contribution exactly as apply_stacking_rules does.
br <- compute_nonmetal_share(br)
br <- br %>% mutate(
  contrib_s301br = if_else(rate_232 > 0, rate_s301br * nonmetal_share, rate_s301br),
  contrib_s301fl = if_else(rate_232 > 0, rate_s301fl * nonmetal_share, rate_s301fl)
)

s232 <- br %>% filter(rate_232 > 0)
cat('Brazil §232 rows (rate_232>0): ', nrow(s232), '\n', sep = '')
cat('\n-- nonmetal_share distribution on Brazil §232 rows --\n')
print(s232 %>% mutate(nm = round(nonmetal_share, 3)) %>% count(nm) %>% arrange(nm))

cat('\n-- EFFECTIVE Brazil §301 contribution on §232 rows (rate_s301br * nonmetal_share) --\n')
print(s232 %>% mutate(c = round(contrib_s301br, 4)) %>% count(c) %>% arrange(c))

cat('\n-- whole-article §232 (nonmetal_share==0): Brazil §301 contribution must be 0 --\n')
whole <- s232 %>% filter(nonmetal_share == 0)
cat('   whole-article §232 rows: ', nrow(whole),
    ' | of those contrib_s301br==0: ', sum(whole$contrib_s301br == 0), '\n', sep = '')

cat('\n-- partial-metal §232 (nonmetal_share>0): §301 on the genuinely non-§232 fraction --\n')
part <- s232 %>% filter(nonmetal_share > 0)
cat('   partial §232 rows: ', nrow(part),
    ' | mean nonmetal_share: ', round(mean(part$nonmetal_share), 3),
    ' | mean Brazil §301 contrib: ', round(mean(part$contrib_s301br), 4), '\n', sep = '')
if (nrow(part) > 0) {
  cat('   sample partial rows:\n')
  print(part %>% select(hts10, rate_232, metal_share, nonmetal_share, rate_s301br, contrib_s301br) %>% head(5))
}

cat('\n-- chapter breakdown of any partial §232 rows (autos=87, steel=72/73, alum=76, copper=74) --\n')
print(part %>% mutate(ch2 = substr(hts10, 1, 2)) %>% count(ch2) %>% arrange(desc(n)) %>% head(12))
cat('\n================ DONE ================\n')
