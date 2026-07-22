# =============================================================================
# Small committed snapshot fixture: baseline and no-§232 counterfactual
# =============================================================================
# Runs the same shared revision builder used in production against a two-record
# HTS archive, then compares selected public rate fields with a committed CSV.

suppressPackageStartupMessages({
  library(tidyverse)
  library(jsonlite)
  library(here)
})

source(here('src', 'core', 'helpers.R'))
source(here('src', 'pipeline', '03_parse_chapter99.R'))
source(here('src', 'pipeline', '04_parse_products.R'))
source(here('src', 'pipeline', '05_parse_policy_params.R'))
source(here('src', 'pipeline', '06_calculate_rates.R'))
source(here('src', 'model', 'authority_spec.R'))
source(here('src', 'model', 'authority_adapter.R'))
source(here('src', 'pipeline', 'revision_snapshot.R'))

local({
  work <- tempfile('scenario_snapshot_fixture_')
  actual_dir <- file.path(work, 'actual')
  no232_dir <- file.path(work, 'no_232')
  dir.create(actual_dir, recursive = TRUE)
  dir.create(no232_dir, recursive = TRUE)
  on.exit(unlink(work, recursive = TRUE), add = TRUE)

  pp <- load_policy_params()
  census <- tibble(Code = '5700', Country = 'China')
  common <- list(
    rev_id = 'fixture',
    eff_date = as.Date('2025-04-15'),
    archive_dir = here('tests', 'fixtures', 'hts_archives'),
    country_lookup = c(china = '5700'),
    countries = '5700',
    census_codes = census
  )

  actual <- do.call(build_revision_snapshot, c(
    common,
    list(output_dir = actual_dir, pp_build = pp)
  ))
  pp_no232 <- pp
  pp_no232$disabled_authorities <- 'section_232'
  no232 <- do.call(build_revision_snapshot, c(
    common,
    list(output_dir = no232_dir, pp_build = pp_no232)
  ))

  columns <- c('revision', 'hts10', 'country', 'base_rate', 'rate_232',
               'total_additional', 'total_rate')
  actual_saved <- readRDS(actual$snapshot_path)
  no232_saved <- readRDS(no232$snapshot_path)
  observed <- bind_rows(
    actual = actual_saved,
    no_232 = no232_saved,
    .id = 'scenario'
  ) %>%
    select(scenario, all_of(columns)) %>%
    arrange(scenario, hts10, country)

  expected <- read_csv(
    here('tests', 'fixtures', 'scenario_snapshot_golden.csv'),
    col_types = cols(.default = col_character(),
                     base_rate = col_double(), rate_232 = col_double(),
                     total_additional = col_double(), total_rate = col_double())
  ) %>% arrange(scenario, hts10, country)

  stopifnot(identical(observed[c('scenario', 'revision', 'hts10', 'country')],
                      expected[c('scenario', 'revision', 'hts10', 'country')]))
  for (column in c('base_rate', 'rate_232', 'total_additional', 'total_rate')) {
    stopifnot(isTRUE(all.equal(observed[[column]], expected[[column]],
                               tolerance = 1e-12)))
  }
  stopifnot(file.exists(file.path(actual_dir, 'snapshot_fixture.rds')))
  stopifnot(file.exists(file.path(no232_dir, 'snapshot_fixture.rds')))
})

cat('Scenario snapshot golden fixture passed (actual + no_232).\n')
