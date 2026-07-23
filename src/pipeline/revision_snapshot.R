# =============================================================================
# Shared per-revision snapshot builder
# =============================================================================
# Baseline, named scenarios, counterfactuals, and synthetic boundary revisions
# all use this unit. Callers own orchestration and cross-revision work.

#' Build a single revision's rate snapshot.
#'
#' Resolves and parses the selected HTS archive, applies scenario changes to the
#' parsed policy inputs, builds AuthoritySpecs, calculates rates, and writes the
#' revision-scoped snapshot and parse caches.
#'
#' @return list(rates, ch99_data, products, snapshot_path, n_rates)
build_revision_snapshot <- function(rev_id, eff_date,
                                    archive_dir = 'data/hts_archives',
                                    output_dir = 'data/timeseries',
                                    country_lookup, countries, census_codes,
                                    pp_build,
                                    archive_rev_id = rev_id) {
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  # `archive_rev_id` decouples the archive being parsed from the id/date stamped
  # on synthetic boundary revisions.
  json_path <- resolve_json_path(archive_rev_id, archive_dir)
  hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)
  ch99_data <- parse_chapter99(json_path)
  products <- parse_products(json_path)

  ieepa_rates <- extract_ieepa_rates(
    hts_raw, country_lookup, effective_date = eff_date
  )
  fentanyl_rates <- extract_ieepa_fentanyl_rates(
    hts_raw, country_lookup, effective_date = eff_date
  )

  # Counterfactual removals happen here, before the spec or any cross-authority
  # calculation exists. Baseline has no disabled_authorities and is a no-op.
  scenario_inputs <- apply_counterfactual_inputs(
    ch99_data, ieepa_rates, fentanyl_rates, pp_build
  )
  ch99_data <- scenario_inputs$ch99_data
  ieepa_rates <- scenario_inputs$ieepa_rates
  fentanyl_rates <- scenario_inputs$fentanyl_rates
  pp_effective <- scenario_inputs$policy_params

  ch99_data_active <- filter_active_ch99(ch99_data, as.Date(eff_date))
  s232_rates <- extract_section232_rates(
    ch99_data_active,
    effective_date = eff_date,
    policy_params = pp_effective
  )
  usmca <- extract_usmca_eligibility(hts_raw)

  specs <- build_authority_specs(
    products, ch99_data, ieepa_rates, usmca,
    countries, rev_id, eff_date,
    s232_rates = s232_rates,
    fentanyl_rates = fentanyl_rates,
    policy_params = pp_effective
  )

  rates <- calculate_rates_for_revision(
    products, ch99_data, usmca,
    countries, rev_id, eff_date,
    specs = specs,
    policy_params = pp_effective
  )

  snapshot_path <- file.path(output_dir, paste0('snapshot_', rev_id, '.rds'))
  saveRDS(rates, snapshot_path)
  saveRDS(ch99_data, file.path(output_dir, paste0('ch99_', rev_id, '.rds')))
  saveRDS(products, file.path(output_dir, paste0('products_', rev_id, '.rds')))

  if (nrow(rates) > 0) {
    ieepa_summary <- rates %>%
      filter(rate_ieepa_recip > 0) %>%
      summarise(
        n_countries = n_distinct(country),
        mean_rate = mean(rate_ieepa_recip)
      )
    message('  IEEPA active in ', ieepa_summary$n_countries, ' countries, ',
            'mean rate: ', round(ieepa_summary$mean_rate * 100, 1), '%')
  }

  list(
    rates = rates,
    ch99_data = ch99_data,
    products = products,
    snapshot_path = snapshot_path,
    n_rates = nrow(rates)
  )
}
