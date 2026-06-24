suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
  library(jsonlite)
})
source(here('src', 'helpers.R'))
source(here('src', 'rate_schema.R'))

pp <- load_policy_params()
ch99 <- readRDS(here('data', 'timeseries', 'ch99_2026_rev_6.rds'))

cat('--- All 9903.94.xx entries in 2026_rev_6 ---\n')
auto_all <- ch99 %>% filter(grepl('^9903\\.94', ch99_code))
print(auto_all %>%
        mutate(desc_short = substr(description, 1, 60),
               general_short = substr(general_raw, 1, 35)) %>%
        select(ch99_code, country_type, rate, general_short, desc_short))

cat('\n--- 9903.94.5x specifically (EU range per parser memory) ---\n')
eu_autos <- ch99 %>% filter(grepl('^9903\\.94\\.5', ch99_code))
print(eu_autos %>%
        select(ch99_code, country_type, countries, rate, general_raw, description))

cat('\n--- Description full text for first EU auto entry ---\n')
if (nrow(eu_autos) > 0) {
  for (i in seq_len(nrow(eu_autos))) {
    cat('\n', eu_autos$ch99_code[i], ':\n', sep = '')
    cat('  general_raw:', eu_autos$general_raw[i], '\n')
    cat('  description:', eu_autos$description[i], '\n')
    cat('  rate:', eu_autos$rate[i], '\n')
    cat('  countries:', paste(unlist(eu_autos$countries[i]), collapse=','), '\n')
  }
}

cat('\n--- Check parsing classification ---\n')
source(here('src', '05_parse_policy_params.R'))
s232_rates <- extract_section232_rates(ch99)
cat('auto_deal_rates (from extract_section232_rates):\n')
print(s232_rates$auto_deal_rates)

cat('\n--- Inspect Germany 8703.22.01.10 directly in snapshot vs deal ---\n')
snap <- readRDS(here('data', 'timeseries', 'snapshot_2026_rev_6.rds'))
sample_de <- snap %>% filter(country == '4280', hts10 == '8703220110')
print(sample_de %>% select(hts10, country, base_rate, rate_232, rate_s122,
                            metal_share, total_rate, usmca_eligible))

cat('\n--- All Germany 8703.22 prefixes with base_rate < 0.15 ---\n')
print(snap %>% filter(country == '4280', substr(hts10, 1, 6) == '870322') %>%
        select(hts10, base_rate, rate_232, total_rate) %>%
        arrange(hts10))

cat('\n--- Trace: what does 06_calculate_rates produce for Germany on 870322? ---\n')
source(here('src', '03_parse_chapter99.R'))
source(here('src', '04_parse_products.R'))
source(here('src', '06_calculate_rates.R'))

json_path <- normalizePath(here('data', 'hts_archives', 'hts_2026_rev_6.json'),
                            winslash = '/', mustWork = TRUE)
cat('JSON path:', json_path, '\n')
hts_raw <- fromJSON(txt = readr::read_file(json_path), simplifyDataFrame = FALSE)
products <- parse_products(json_path)
ieepa_rates <- extract_ieepa_rates(hts_raw,
                                    build_country_lookup(here('resources', 'census_codes.csv')),
                                    effective_date = as.Date('2026-04-23'))
fent_rates <- extract_ieepa_fentanyl_rates(hts_raw,
                                            build_country_lookup(here('resources', 'census_codes.csv')),
                                            effective_date = as.Date('2026-04-23'))
usmca <- extract_usmca_eligibility(hts_raw)
ch99_active <- filter_active_ch99(ch99, as.Date('2026-04-23'))

census <- read_csv(here('resources', 'census_codes.csv'),
                   col_types = cols(.default = col_character()))

calc <- calculate_rates_for_revision(
  products, ch99_active, ieepa_rates, usmca,
  countries = census$Code, revision_id = '2026_rev_6',
  effective_date = as.Date('2026-04-23'),
  s232_rates = s232_rates,
  fentanyl_rates = fent_rates
)

cat('Germany 870322 rows in fresh calculation:\n')
print(calc %>% filter(country == '4280', substr(hts10, 1, 6) == '870322') %>%
        select(hts10, base_rate, rate_232, statutory_rate_232, total_rate))

# What's the rate_232 distribution across EU autos in the fresh calc vs snapshot?
cat('\n--- All EU auto rates for 870322-870390 + light trucks ---\n')
auto_prefixes <- c('870322','870323','870324','870331','870332','870333','870334',
                   '870340','870350','870360','870370','870380','870390',
                   '87042101','87043101','87044100','87045100')
prefix_re <- paste0('^(', paste(auto_prefixes, collapse = '|'), ')')
eu_calc <- calc %>%
  filter(country %in% pp$EU27_CODES, grepl(prefix_re, hts10))
cat(nrow(eu_calc), ' EU auto rows; rate_232 distribution:\n')
print(eu_calc %>% count(rate_232 = round(rate_232, 3)))

# Also check Japan and Korea (same floor mechanism) — do their rates land?
jp_calc <- calc %>%
  filter(country == pp$CTY_JAPAN, grepl(prefix_re, hts10))
cat('\nJapan auto rows (', nrow(jp_calc), '); rate_232 distribution:\n')
print(jp_calc %>% count(rate_232 = round(rate_232, 3)))

# Check whether section_232_country_exemptions is doing this
cat('\nsection_232_country_exemptions config:\n')
print(pp$section_232_country_exemptions)

cat('\n--- Sanity: Russia ch72 (steel) should still get 200% ---\n')
print(calc %>% filter(country == '4621', substr(hts10, 1, 2) == '72') %>%
        count(rate_232 = round(rate_232, 3)) %>% arrange(desc(rate_232)) %>% head(5))

cat('\n--- Sanity: chapter 72/73 (true steel) for Germany should still get annex_1a 50% ---\n')
print(calc %>% filter(country == '4280', substr(hts10, 1, 2) %in% c('72','73')) %>%
        count(rate_232 = round(rate_232, 3)) %>% arrange(desc(n)) %>% head(5))
