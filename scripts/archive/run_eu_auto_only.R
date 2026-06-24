suppressPackageStartupMessages({
  library(here)
  source(here::here("src", "helpers.R"))
  source(here::here("src", "09_daily_series.R"))
})
pp <- load_policy_params()
run_post_build_scenarios_per_revision(
  scenario_names = c("baseline"),
  policy_params  = pp
)
