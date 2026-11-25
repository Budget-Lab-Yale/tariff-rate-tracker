# =============================================================================
# test_s301_excess_capacity.R - proposed Section 301 "excess capacity" duties
# =============================================================================
# The duty (rate_s301ec) is off in baseline and switched on from 2027-04-01 by
# the scenarios ec301_proposed, ec301_no_deals and ec301_all_deals, which also
# switch on the proposed Brazil change (finished aircraft pay a flat 10%).
#
# Covers the product lists, the scenario overlays, the adapter, the calculator
# step on a small made-up table of products and countries, stacking, the
# boundary calendar, and one pass through the whole calculator on the
# committed two-record HTS fixture.
#
# Usage: Rscript tests/test_s301_excess_capacity.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse); library(here)
})
suppressMessages({
  source(here('src', 'core', 'helpers.R'))
  source(here('src', 'pipeline', '03_parse_chapter99.R'))
  source(here('src', 'pipeline', '04_parse_products.R'))
  source(here('src', 'model', 'authority_spec.R'))
  source(here('src', 'model', 'policy_params.R'))
  source(here('src', 'model', 'authority_adapter.R'))
  source(here('src', 'pipeline', '05_parse_policy_params.R'))
  source(here('src', 'pipeline', '06_calculate_rates.R'))
  source(here('src', 'pipeline', 'revision_snapshot.R'))
})

pass <- 0L; fail <- 0L
ok <- function(cond, msg) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat('  PASS: ', msg, '\n') }
  else { fail <<- fail + 1L; cat('  FAIL: ', msg, '\n') }
}
near <- function(x, y) length(x) == 1 && isTRUE(all.equal(x, y, tolerance = 1e-12))

SCENARIOS <- c('ec301_proposed', 'ec301_no_deals', 'ec301_all_deals')
START <- as.Date('2027-04-01')
DE <- '4280'; JP <- '5880'; CH <- '4419'; KR <- '5800'; TW <- '5830'
BD <- '5380'; KH <- '5550'; ID <- '5600'; MY <- '5570'; TH <- '5490'
IN <- '5330'; VN <- '5520'; SG <- '5590'; CN <- '5700'; BR <- '3510'; CA <- '1220'

countries <- read_csv(here('resources', 'census_codes.csv'),
                      col_types = cols(.default = col_character()))$Code
pp <- suppressMessages(load_policy_params())
pps <- lapply(setNames(SCENARIOS, SCENARIOS),
              function(s) suppressMessages(load_policy_params(scenario = s)))

# -----------------------------------------------------------------------------
cat('\n== product lists (resources/, built by scripts/build_s301ec_annex.R) ==\n')
read_list <- function(f) read_csv(here('resources', f),
                                  col_types = cols(.default = col_character()))
common  <- read_list('s301ec_common_exemptions.csv')
country <- read_list('s301ec_country_exemptions.csv')
annex_b <- read_list('s301ec_china_annex_b.csv')
fl_common <- read_list('s301fl_final_common_exemptions.csv')
ok(nrow(common) == 2121 && !anyDuplicated(common$hts_code), '2,121 common lines')
ok(identical(setdiff(common$hts_code, fl_common$hts_code), '26011200') &&
     length(setdiff(fl_common$hts_code, common$hts_code)) == 0,
   'common list = forced-labor common list + 2601.12.00')
ok(sum(common$condition %in% c('aircraft', 'pharma')) == 1241,
   '1,241 common lines are exempt only for aircraft or pharma use')
ok(nrow(annex_b) == 77, '77 China Annex B lines')
ok(nrow(country) == 793 && n_distinct(country$countries) == 7,
   '793 country-list lines across seven economies')
ok(all(country$condition %in% c('full', 'ex')), 'country lists carry no use flags')
eu_own <- country$hts_code[grepl(DE, country$countries)]
ok(all(c('22041000', '22083030', '45049000') %in% eu_own),
   'EU list has Champagne, whisky and the unflagged cork line')

# -----------------------------------------------------------------------------
cat('\n== config: off in baseline, scenarios select an outcome ==\n')
cfg <- pp$section_301_excess_capacity
ok(isFALSE(cfg$enabled), 'baseline: section_301_excess_capacity is disabled')
ok(is.null(.build_section_301_excess_capacity(pp, countries, START)),
   'baseline: no authority is built, even on the start date')
ok(length(cfg$economies) == 14 && setequal(names(cfg$economies), names(cfg$outcome)),
   '14 economies, each with an outcome')
fl_cfg <- pp$section_301_forced_labor
ok(setequal(names(pp$eu27_codes), setdiff(fl_cfg$tier_10pct_net_mfn, TW)) &&
     all(c(JP, CH, KR) %in% fl_cfg$tier_12_5pct_net_mfn) &&
     all(c(BD, KH, ID, MY, IN) %in% fl_cfg$tier_10pct) &&
     all(c(TH, VN, SG, CN) %in% fl_cfg$tier_12_5pct),
   'country codes agree with the forced-labor tiers (EU = its 27 codes)')
ok(isFALSE(pp$section_301_brazil$modification_2026_11$enabled),
   'baseline: Brazil modification is disabled')
ok(identical(as.character(pp$SERIES_HORIZON_END), '2027-06-30'), 'horizon 2027-06-30')

baseline_mints <- as.character(pp$BOUNDARY_OVERRIDES)
ok(!'2027-04-01' %in% baseline_mints, 'actual: no 2027-04-01 boundary')
for (s in SCENARIOS) {
  ok(isTRUE(pps[[s]]$section_301_excess_capacity$enabled) &&
       identical(as.character(pps[[s]]$section_301_excess_capacity$effective_date),
                 '2027-04-01'),
     paste0(s, ': enabled from 2027-04-01'))
  ok(identical(as.character(pps[[s]]$BOUNDARY_OVERRIDES),
               c(baseline_mints, '2027-04-01')),
     paste0(s, ': boundary list = baseline list + 2027-04-01'))
  mod <- pps[[s]]$section_301_brazil$modification_2026_11
  ok(isTRUE(mod$enabled) && identical(as.character(mod$effective_date), '2027-04-01'),
     paste0(s, ': Brazil modification on from 2027-04-01'))
  # A scenario changes only the switches, never the rate table.
  ok(identical(pps[[s]]$section_301_excess_capacity$economies, cfg$economies),
     paste0(s, ': rate table is the baseline table'))
}

# Rate per economy that each scenario should resolve to (first country shown).
deal    <- c(eu = .15, japan = .15, switzerland = .15, korea = .15, taiwan = .15,
             bangladesh = .18, cambodia = .18, indonesia = .18, malaysia = .18,
             thailand = .18, india = .17, vietnam = .20, singapore = .10, china = .20)
no_deal <- c(eu = .20, japan = .20, switzerland = .20, korea = .25, taiwan = .25,
             bangladesh = .20, cambodia = .25, indonesia = .25, malaysia = .25,
             thailand = .25, india = .25, vietnam = .35, singapore = .20, china = .40)
proposed <- deal
proposed[c('india', 'vietnam', 'singapore')] <- no_deal[c('india', 'vietnam', 'singapore')]
expected <- list(ec301_proposed = proposed, ec301_no_deals = no_deal, ec301_all_deals = deal)
code_of <- c(eu = DE, japan = JP, switzerland = CH, korea = KR, taiwan = TW,
             bangladesh = BD, cambodia = KH, indonesia = ID, malaysia = MY,
             thailand = TH, india = IN, vietnam = VN, singapore = SG, china = CN)

specs_ec <- lapply(pps, function(p) .build_section_301_excess_capacity(p, countries, START))
for (s in SCENARIOS) {
  bc <- specs_ec[[s]]$programs[[1]]$rate$by_country
  ok(isTRUE(all.equal(unname(bc[code_of]), unname(expected[[s]][names(code_of)]))),
     paste0(s, ': each economy resolves to its intended rate'))
}
st <- specs_ec$ec301_proposed$programs[[1]]$settings
ok(length(specs_ec$ec301_proposed$programs[[1]]$rate$by_country) == 27 + 13,
   'covers the 27 EU members and 13 other countries')
ok(all(st$net_of_mfn[c(DE, JP, CH, KR, TW)]) && !any(st$net_of_mfn[c(BD, IN, VN, SG, CN)]),
   'deal rates: EU, Japan, Switzerland, Korea and Taiwan are net of MFN; the rest are not')
st_nd <- specs_ec$ec301_no_deals$programs[[1]]$settings
ok(!st_nd$net_of_mfn[[TW]] && st_nd$net_of_mfn[[KR]],
   'no-deal: Taiwan nets Section 301 only; Korea still nets MFN')
ok(st$annexes_apply[[CN]] && !st_nd$annexes_apply[[CN]],
   'China: annexes apply with a deal and fall away without one')
ok(identical(specs_ec$ec301_proposed$stacking$class, 'additive') &&
     identical(specs_ec$ec301_proposed$usmca_treatment, 'none') &&
     is_authority_spec(specs_ec$ec301_proposed),
   'authority is additive, with no USMCA treatment')
spec_before <- .build_section_301_excess_capacity(pps$ec301_proposed, countries, START - 1)
ok(length(spec_before$programs[[1]]$rate) == 0, 'day before the start date: charges nothing')
bad <- pps$ec301_proposed
bad$section_301_excess_capacity$outcome$india <- 'maybe'
ok(inherits(try(.build_section_301_excess_capacity(bad, countries, START), silent = TRUE),
            'try-error'), "an outcome other than 'deal' or 'no_deal' stops the build")

# -----------------------------------------------------------------------------
cat('\n== calculator on a made-up table ==\n')
# Products: a plain covered good at three MFN rates, steel (Section 232), iron
# ore 2601.12.00, an aircraft-use line, a pharma-use line, cork 4504.90.00,
# Champagne, a China Annex B line, and plastic furniture 9403.70.40.
P <- c(plain = '6109100012', dutyfree = '6109100020', high = '6109100030',
       steel = '7210110000', ore = '2601120030', air = '8805290000',
       pharma = '3004430000', cork = '4504900000', wine = '2204100030',
       annex_b = '3604109000', furn = '9403704001', fin_air = '8802300100',
       air_part = '8807300000')
mfn <- c(plain = 0.05, dutyfree = 0, high = 0.30, steel = 0, ore = 0, air = 0.04,
         pharma = 0, cork = 0, wine = 0.02, annex_b = 0.05, furn = 0, fin_air = 0,
         air_part = 0)
ok(!any(substr(P[c('plain', 'steel')], 1, 8) %in% c(common$hts_code, annex_b$hts_code)),
   'the plain good and the steel line are on no list')
grid <- expand_grid(hts10 = unname(P), country = c(code_of, brazil = BR, canada = CA)) %>%
  mutate(base_rate = unname(mfn[match(hts10, P)]),
         statutory_rate_232 = if_else(hts10 == P['steel'], 0.50, 0),
         rate_232 = statutory_rate_232,
         s232_annex = NA_character_, heading_program = FALSE)

fl_spec <- .build_section_301_forced_labor(pp, countries, START)
run <- function(p, date = START, post_pref_korea = NULL) {
  specs <- list(section_301_forced_labor = fl_spec,
                section_301_brazil = .build_section_301_brazil(p, countries, date),
                section_301_excess_capacity =
                  .build_section_301_excess_capacity(p, countries, date))
  r <- suppressMessages(apply_section301_forced_labor(grid, specs, countries))
  r <- suppressMessages(apply_section301_brazil(r, specs, NULL, countries))
  r <- suppressMessages(apply_section301_excess_capacity(r, specs))
  if (!is.null(post_pref_korea)) {
    # What step 6c does for South Korea: preferences lower base_rate, the
    # forced-labor cap is recomputed against it, then this duty follows.
    k <- r$s301fl_post_cap > 0 & r$s301fl_cap_eligible
    r$base_rate[r$country == KR] <- r$base_rate[r$country == KR] * post_pref_korea
    r$s301fl_full[k] <- pmax(r$s301fl_post_cap[k] - r$base_rate[k], 0)
    r$rate_s301fl[k] <- r$s301fl_full[k] * r$s301fl_exempt_factor[k]
    r <- recompute_s301ec_post_preference(r, specs)
  }
  r
}
out <- lapply(pps, run)
base <- run(pp)
get <- function(r, col, p, c) r[[col]][r$hts10 == P[[p]] & r$country == c]
ec <- function(s, p, c) get(out[[s]], 'rate_s301ec', p, c)
fl <- function(s, p, c) get(out[[s]], 'rate_s301fl', p, c)

ok('rate_s301ec' %in% names(base) && all(base$rate_s301ec == 0),
   'baseline: rate_s301ec is zero on every row')
ok(identical(base$rate_s301fl, out$ec301_proposed$rate_s301fl) &&
     identical(base$rate_s301fl, out$ec301_no_deals$rate_s301fl),
   'the forced-labor duty is the same with and without the new duty')
ok(all(out$ec301_no_deals$rate_s301ec[out$ec301_no_deals$country %in% c(BR, CA)] == 0),
   'no duty on countries outside the 14 economies')

# All-in economies: MFN + forced labor + new duty = max(MFN, stated rate).
all_in_ok <- function(s, econs) all(vapply(econs, function(e) {
  all(vapply(c('plain', 'dutyfree', 'high'), function(p) {
    c0 <- code_of[[e]]
    near(mfn[[p]] + fl(s, p, c0) + ec(s, p, c0), max(mfn[[p]], expected[[s]][[e]]))
  }, logical(1)))
}, logical(1)))
all_in <- c('eu', 'japan', 'switzerland', 'korea', 'taiwan')
ok(all_in_ok('ec301_proposed', all_in),
   'deal: all-in economies pay max(MFN, 15%) in total, at MFN of 0, 5% and 30%')
ok(all_in_ok('ec301_no_deals', setdiff(all_in, 'taiwan')),
   'no-deal: EU, Japan, Switzerland (20%) and Korea (25%) pay max(MFN, rate) in total')
ok(near(ec('ec301_proposed', 'plain', DE), 0.05) && near(ec('ec301_proposed', 'plain', JP), 0.025),
   'deal adds 5 points for the EU and 2.5 for Japan on a 5% MFN good')
# Taiwan without a deal: 25% less forced labor only, whatever the MFN rate.
ok(near(fl('ec301_no_deals', 'plain', TW) + ec('ec301_no_deals', 'plain', TW), 0.25) &&
     near(fl('ec301_no_deals', 'high', TW) + ec('ec301_no_deals', 'high', TW), 0.25),
   'Taiwan no-deal ignores MFN: forced labor + new duty = 25% at MFN of 5% and 30%')

# Net-of-301 economies: forced labor + new duty = stated rate.
net301 <- c('bangladesh', 'cambodia', 'indonesia', 'malaysia', 'thailand',
            'india', 'vietnam')
net301_ok <- function(s) all(vapply(net301, function(e) {
  near(fl(s, 'plain', code_of[[e]]) + ec(s, 'plain', code_of[[e]]), expected[[s]][[e]])
}, logical(1)))
ok(net301_ok('ec301_proposed') && net301_ok('ec301_no_deals') && net301_ok('ec301_all_deals'),
   'net-of-301 economies: forced labor + new duty = stated rate, in all three scenarios')
ok(near(ec('ec301_proposed', 'plain', VN), 0.225) && near(ec('ec301_proposed', 'plain', IN), 0.15) &&
     near(ec('ec301_proposed', 'plain', TH), 0.055) && near(ec('ec301_proposed', 'plain', BD), 0.08),
   'proposed adds 22.5 points for Vietnam, 15 for India, 5.5 for Thailand, 8 for Bangladesh')
ok(all(out$ec301_all_deals$rate_s301ec[out$ec301_all_deals$country == SG] == 0),
   'Singapore deal rate (10%) adds nothing over its 12.5% forced-labor duty')
ok(near(ec('ec301_proposed', 'plain', SG), 0.075), 'Singapore no-deal rate (20%) adds 7.5 points')

# Section 232 goods: exempt for the 13, charged in full for China.
ok(all(vapply(setdiff(names(code_of), 'china'),
              function(e) ec('ec301_no_deals', 'steel', code_of[[e]]) == 0, logical(1))),
   'non-China steel pays no new duty (Section 232 exemption)')
ok(near(ec('ec301_proposed', 'steel', CN), 0.20) && near(ec('ec301_no_deals', 'steel', CN), 0.40) &&
     fl('ec301_proposed', 'steel', CN) == 0,
   'China steel pays 20% (deal) or 40% (no deal): no Section 232 exemption')

# China annexes.
ok(near(ec('ec301_proposed', 'plain', CN), 0.075) && near(fl('ec301_proposed', 'plain', CN), 0.125),
   'China, neither annex: 20% less the 12.5% forced-labor duty')
ok(near(ec('ec301_proposed', 'cork', CN) , 0.9 * 0.10 + 0.1 * 0.075),
   'China Annex A aircraft line: share x 10% + (1 - share) x (20% - forced labor)')
ok(near(ec('ec301_proposed', 'pharma', CN), 0.5 * 0.10 + 0.5 * 0.075),
   'China Annex A pharma line: the same with the 50% share')
ok(near(ec('ec301_proposed', 'ore', CN), 0.10) && near(fl('ec301_proposed', 'ore', CN), 0.125),
   'China 2601.12.00: forced labor 12.5% + flat 10%')
ok(ec('ec301_proposed', 'annex_b', CN) == 0, 'China Annex B line is exempt')
ok(near(ec('ec301_proposed', 'furn', CN), 0.9 * 0.10 + 0.1 * 0.075),
   'China 9403.70.40 is treated as an Annex A aircraft line, not Annex B')
china_nd <- out$ec301_no_deals %>% filter(country == CN)
ok(isTRUE(all.equal(china_nd$rate_s301fl + china_nd$rate_s301ec, rep(0.40, nrow(china_nd)))),
   'China no-deal: forced labor + new duty = 40% on every good, annexes included')

# Lines that differ from the forced-labor lists.
ok(all(vapply(setdiff(names(code_of), 'china'), function(e) {
     c0 <- code_of[[e]]
     ec('ec301_no_deals', 'ore', c0) == 0 &&
       identical(fl('ec301_no_deals', 'ore', c0), get(base, 'rate_s301fl', 'ore', c0)) &&
       fl('ec301_no_deals', 'ore', c0) > 0
   }, logical(1))),
   'non-China 2601.12.00: no new duty, forced-labor duty unchanged and still charged')
ok(ec('ec301_no_deals', 'wine', DE) == 0 && fl('ec301_no_deals', 'wine', DE) > 0 &&
     ec('ec301_no_deals', 'wine', JP) > 0,
   'EU Champagne 2204.10.00: exempt from the new duty only, and only for the EU')
ok(ec('ec301_no_deals', 'cork', BD) == 0 && ec('ec301_no_deals', 'cork', DE) == 0,
   '4504.90.00 is fully exempt where the country list prints it unflagged')

# Use-conditional lines net the FULL forced-labor rate.
ok(near(ec('ec301_no_deals', 'cork', VN), 0.1 * (0.35 - 0.125)) &&
     near(fl('ec301_no_deals', 'cork', VN), 0.1 * 0.125),
   'aircraft-use line (Vietnam): (1 - 0.90) x (35% - full 12.5% forced labor)')
ok(near(ec('ec301_no_deals', 'pharma', IN), 0.5 * (0.25 - 0.10)),
   'pharma-use line (India): (1 - 0.50) x (25% - full 10% forced labor)')
ok(near(ec('ec301_proposed', 'air', JP), 0.1 * (0.15 - 0.04 - (0.125 - 0.04))),
   'aircraft-use line, all-in economy (Japan, 4% MFN): (1 - 0.90) x 2.5 points')

# South Korea after claimed KORUS preferences halve the MFN rate.
kr <- run(pps$ec301_proposed, post_pref_korea = 0.5)
kr_row <- kr %>% filter(country == KR, hts10 == P[['plain']])
ok(near(kr_row$base_rate, 0.025) && near(kr_row$rate_s301fl, 0.10) && near(kr_row$rate_s301ec, 0.025) &&
     near(kr_row$base_rate + kr_row$rate_s301fl + kr_row$rate_s301ec, 0.15),
   'Korea: netted against the MFN rate actually paid; total stays 15%')
ok(identical(kr$rate_s301ec[kr$country != KR], out$ec301_proposed$rate_s301ec[kr$country != KR]),
   'the Korea recompute leaves other countries alone')

# -----------------------------------------------------------------------------
cat('\n== Brazil modification: finished aircraft at a flat 10% ==\n')
br <- function(r, p) get(r, 'rate_s301br', p, BR)
ok(near(br(base, 'fin_air'), 0.025) && near(br(base, 'air_part'), 0.025),
   'actual: finished aircraft and aircraft parts both pay 25% x 10% = 2.5%')
for (s in SCENARIOS) {
  ok(near(br(out[[s]], 'fin_air'), 0.10),
     paste0(s, ': Brazil finished aircraft 8802.30.01 pays 10% from 2027-04-01'))
  ok(near(br(out[[s]], 'air_part'), 0.025) && near(br(out[[s]], 'plain'), 0.25),
     paste0(s, ': aircraft parts (2.5%) and other goods (25%) are unchanged'))
  before <- run(pps[[s]], date = START - 1)
  ok(near(br(before, 'fin_air'), 0.025) && all(before$rate_s301ec == 0),
     paste0(s, ': on 2027-03-31 the aircraft line pays its old rate and there is no new duty'))
}
sugar <- unlist(pp$section_301_brazil$modification_2026_11$sugar_lines)
ok(length(sugar) == 7 && length(pp$section_301_brazil$modification_2026_11$aircraft_lines) == 6,
   'config records six aircraft lines and seven sugar lines (sugar not modeled)')

# -----------------------------------------------------------------------------
cat('\n== stacking: additive, and a zero column changes nothing ==\n')
pol <- default_stacking_policy(CN)
ok(identical(pol$rate_s301ec, list(net = 'net_s301ec', class = 'additive')),
   'rate_s301ec stacks additively')
stk_in <- tibble(hts10 = c('7210110000', '6109100012'), country = CN, base_rate = 0.02,
                 rate_232 = c(0.50, 0), rate_301 = 0.25, rate_301_cs = 0,
                 rate_ieepa_recip = 0, rate_ieepa_fent = 0.10, rate_s122 = 0,
                 rate_s301fl = c(0, 0.125), rate_s301br = 0, rate_s338 = 0,
                 rate_section_201 = 0, rate_other = 0, metal_share = c(0.7, 1))
with_ec <- suppressMessages(apply_stacking_rules(
  mutate(stk_in, rate_s301ec = c(0.40, 0.275)), cty_china = CN))
ok(near(with_ec$total_additional[1], 0.50 + 0.25 + 0.10 + 0.40),
   'China steel: 40% is added in full on top of Section 232, the 2018-19 duty and fentanyl')
zero_ec <- suppressMessages(apply_stacking_rules(mutate(stk_in, rate_s301ec = 0), cty_china = CN))
old_policy <- pol[setdiff(names(pol), 'rate_s301ec')]
no_col <- suppressMessages(apply_stacking_rules(stk_in, cty_china = CN, stacking_policy = old_policy))
ok(identical(zero_ec$total_additional, no_col$total_additional) &&
     identical(zero_ec$total_rate, no_col$total_rate),
   'totals with an all-zero rate_s301ec are bit-identical to totals without the column')
net <- suppressMessages(compute_net_authority_contributions(
  mutate(stk_in, rate_s301ec = c(0.40, 0.275)), cty_china = CN))
ok(isTRUE(all.equal(net$net_s301ec, c(0.40, 0.275))), 'net_s301ec carries the full duty')
ok('s301ec' %in% names(authority_report_buckets()) &&
     identical(authority_report_buckets()[['s301ec']], 'net_s301ec') &&
     !'net_s301ec' %in% authority_report_buckets()[['301']],
   'daily_by_authority reports it as its own column, not inside etr_301')
ok('rate_s301ec' %in% RATE_SCHEMA, 'rate_s301ec is a panel column')

# The daily by-authority table (unweighted means; the weighted columns use the
# same grouping).
if (!exists('build_daily_aggregates')) {
  suppressMessages(source(here('src', 'pipeline', '09_daily_series.R')))
}
day <- as.Date('2027-04-01')
ts <- with_ec %>%
  mutate(statutory_base_rate = base_rate, usmca_eligible = FALSE, revision = 'bnd_2027-04-01',
         effective_date = day, valid_from = day, valid_until = day)
daily <- suppressMessages(build_daily_aggregates(ts, date_range = c(day, day)))$daily_by_authority
ok(near(daily$mean_s301ec, mean(c(0.40, 0.275))) &&
     near(daily$mean_301, mean(c(0.25, 0.25 + 0.125))),
   'daily_by_authority: mean_s301ec holds the new duty; mean_301 does not include it')
parts <- daily %>% select(starts_with('mean_')) %>% unlist()
ok(near(sum(parts), mean(with_ec$total_additional)),
   'daily_by_authority: the authority columns add up to the total additional rate')

# -----------------------------------------------------------------------------
cat('\n== boundary calendar: one extra snapshot in each scenario, none in actual ==\n')
mints <- function(p) {
  rd <- load_revision_dates(use_policy_dates = TRUE)
  as.character(discover_boundaries(rd, here('data', 'timeseries'), p,
                                   overrides = p$BOUNDARY_OVERRIDES,
                                   horizon = p$SERIES_HORIZON_END)$date)
}
m_actual <- tryCatch(suppressMessages(mints(pp)), error = function(e) e)
if (inherits(m_actual, 'error')) {
  cat('  SKIP: discover_boundaries unavailable here (', conditionMessage(m_actual), ')\n')
} else {
  ok(!'2027-04-01' %in% m_actual, 'actual: no bnd_2027-04-01')
  for (s in SCENARIOS) {
    m <- suppressMessages(mints(pps[[s]]))
    ok(sum(m == '2027-04-01') == 1 && setequal(setdiff(m, '2027-04-01'), m_actual),
       paste0(s, ': exactly one extra mint, bnd_2027-04-01'))
  }
}

# -----------------------------------------------------------------------------
cat('\n== whole calculator on the committed HTS fixture (Chinese and Korean steel) ==\n')
build <- function(p, date) {
  work <- tempfile('s301ec_fixture_')
  dir.create(work, recursive = TRUE)
  on.exit(unlink(work, recursive = TRUE), add = TRUE)
  # capture.output: the parsers print summary tables.
  invisible(capture.output(res <- suppressMessages(suppressWarnings(build_revision_snapshot(
    rev_id = 'fixture', eff_date = date,
    archive_dir = here('tests', 'fixtures', 'hts_archives'),
    country_lookup = c(china = CN, korea = KR), countries = c(CN, KR),
    census_codes = tibble(Code = c(CN, KR), Country = c('China', 'South Korea')),
    output_dir = work, pp_build = p)))))
  readRDS(res$snapshot_path) %>% arrange(country)
}
e2e <- tryCatch(list(actual = build(pp, START),
                     deal = build(pps$ec301_proposed, START),
                     no_deal = build(pps$ec301_no_deals, START),
                     before = build(pps$ec301_no_deals, START - 1)),
                error = function(e) e)
if (inherits(e2e, 'error')) {
  fail <- fail + 1L
  cat('  FAIL: fixture build stopped: ', conditionMessage(e2e), '\n')
} else {
  ok(all(e2e$actual$rate_s301ec == 0) && all(e2e$actual$statutory_rate_s301ec == 0),
     'actual: rate_s301ec present and zero')
  cn <- function(d, col) d[[col]][d$country == CN]
  ok(near(cn(e2e$deal, 'rate_s301ec'), 0.20) && near(cn(e2e$no_deal, 'rate_s301ec'), 0.40),
     'scenario: Chinese steel pays 20% (deal) / 40% (no deal)')
  ok(near(cn(e2e$no_deal, 'total_additional') - cn(e2e$actual, 'total_additional'), 0.40) &&
       identical(e2e$no_deal$rate_232, e2e$actual$rate_232),
     'the 40% is added to the total in full; Section 232 is unchanged')
  ok(all(e2e$no_deal$rate_s301ec[e2e$no_deal$country == KR] == 0) &&
       identical(e2e$no_deal$total_additional[e2e$no_deal$country == KR],
                 e2e$actual$total_additional[e2e$actual$country == KR]),
     'Korean steel pays no new duty (Section 232 exemption), through the Korea recompute')
  ok(all(e2e$before$rate_s301ec == 0) &&
       identical(e2e$before$total_additional,
                 build(pp, START - 1)$total_additional),
     'the day before the start date the scenario equals actual')
  ok(identical(names(e2e$actual), names(e2e$deal)) &&
       !any(grepl('^s301(fl|ec)_', names(e2e$actual))),
     'actual and scenario snapshots have the same columns; no working columns leak')
}

cat(sprintf('\n== SUMMARY: %d passed, %d failed ==\n', pass, fail))
if (fail > 0) quit(status = 1)
