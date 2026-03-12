# =============================================================================
# Compute Import-Weighted Effective Tariff Rates (ETRs)
# =============================================================================
#
# Calculates tariff rates for ALL importing countries (not just TPC benchmark
# countries) and computes import-weighted average ETRs using 2024 Census data.
# Includes TPC comparison overlays on all plots.
#
# Inputs:
#   - products_raw.csv: Base rates and Ch99 footnote references
#   - ieepa_country_rates.csv: IEEPA surcharge/floor rates by country
#   - usmca_products.csv: USMCA eligibility per HTS10
#   - Import weights: 2024 Census import data (HS10 x country x GTAP) — path from config/local_paths.yaml
#   - country_partner_mapping.csv: Census code -> partner group
#   - TPC tariff_by_flow_day.csv: TPC benchmark rates for comparison
#   - census_codes.csv: Census country code-to-name mapping
#
# Output:
#   - Weighted ETR time series (overall, by partner, by authority, by sector)
#   - All plots include TPC comparison overlay
#   - Plots and CSVs saved to output/etr/
#
# =============================================================================

library(tidyverse)

# =============================================================================
# Configuration
# =============================================================================

# Constants loaded from YAML (via helpers.R)
.pp_10 <- tryCatch(load_policy_params(), error = function(e) NULL)

CTY_CHINA  <- if (!is.null(.pp_10)) .pp_10$CTY_CHINA  else '5700'
CTY_CANADA <- if (!is.null(.pp_10)) .pp_10$CTY_CANADA else '1220'
CTY_MEXICO <- if (!is.null(.pp_10)) .pp_10$CTY_MEXICO else '2010'

# Policy regime snapshot dates (aligned to TPC benchmark dates)
POLICY_DATES <- if (!is.null(.pp_10) && !is.null(.pp_10$WEIGHTED_ETR_POLICY_DATES)) {
  .pp_10$WEIGHTED_ETR_POLICY_DATES
} else {
  tribble(
    ~date,         ~label,
    '2025-03-17',  'Fentanyl',
    '2025-04-17',  'Liberation Day',
    '2025-07-17',  'S232 increase',
    '2025-10-17',  'Phase 2',
    '2025-11-17',  'Nov 2025',
    '2026-02-25',  'Current'
  ) %>% mutate(date = as.Date(date))
}

# tpc_policy_revision overrides are enriched at runtime (after helpers.R is sourced)
# via enrich_policy_dates_with_overrides() — called in compute_weighted_etrs()

# Section 301 + Biden acceleration rates
SECTION_301_RATES <- if (!is.null(.pp_10)) .pp_10$SECTION_301_RATES else tribble(
  ~ch99_pattern, ~s301_rate,
  '9903.88.01', 0.25, '9903.88.02', 0.25, '9903.88.03', 0.25,
  '9903.88.04', 0.25, '9903.88.09', 0.10, '9903.88.15', 0.075,
  '9903.88.16', 0.15, '9903.91.01', 0.25, '9903.91.02', 0.50,
  '9903.91.03', 1.00, '9903.91.04', 0.25, '9903.91.05', 0.50,
  '9903.91.11', 0.25
)

# TPC country name overrides (names that don't exact-match census_codes.csv)
TPC_NAME_FIXES <- if (!is.null(.pp_10) && !is.null(.pp_10$TPC_NAME_FIXES)) {
  .pp_10$TPC_NAME_FIXES
} else {
  c(
    'christmas island' = '6024',
    "cote d'ivoire" = '7480',
    "c\u00f4te d`ivoire" = '7480',
    'cura\u00e7ao' = '2777',
    'curacao' = '2777',
    'czechia (czech republic)' = '4351',
    'democratic republic of the congo' = '7660',
    'eswatini (swaziland)' = '7950',
    'falkland islands' = '3720',
    'gaza strip' = '5082',
    'germany' = '4280',
    'heard and mcdonald islands' = '6029',
    'laos' = '5530',
    'macau' = '5660',
    'moldova' = '4641',
    'myanmar (burma)' = '5460',
    'north korea' = '5790',
    'republic of the congo' = '7630',
    'samoa' = '6150',
    's\u00e3o tom\u00e9 and pr\u00edncipe' = '7644',
    'sao tome and principe' = '7644',
    'south korea' = '5800',
    'syria' = '5020',
    'tanzania' = '7830',
    'vatican city' = '4752',
    'west bank' = '5083',
    'yemen' = '5210'
  )
}


# =============================================================================
# Data Loading
# =============================================================================

load_data <- function(products_path, ieepa_path, usmca_path,
                      imports_path, partner_path) {

  # --- Import weights (2024 Census) ---
  message('Loading 2024 Census import weights...')
  imports <- readRDS(imports_path)
  message('  ', nrow(imports), ' import flows, ',
          length(unique(imports$cty_code)), ' countries, $',
          round(sum(imports$imports) / 1e9, 1), 'B total')

  # Aggregate to HS10 x country (drop GTAP for now, rejoin later)
  imports_gtap <- imports %>%
    select(hs10, cty_code, gtap_code, imports)

  imports_agg <- imports %>%
    group_by(hs10, cty_code) %>%
    summarise(imports = sum(imports), .groups = 'drop') %>%
    filter(imports > 0)

  # --- Products ---
  message('Loading products...')
  products <- read_csv(products_path, col_types = cols(.default = col_character())) %>%
    select(hts10, base_rate, ch99_refs) %>%
    rename(hs10 = hts10) %>%
    mutate(base_rate = as.numeric(base_rate))

  # --- IEEPA country rates ---
  message('Loading IEEPA rates...')
  ieepa_all <- read_csv(ieepa_path, col_types = cols(.default = col_character())) %>%
    filter(terminated == 'FALSE') %>%
    mutate(rate = as.numeric(rate))

  # Phase 2 surcharge/floor (non-China, non-EU)
  ieepa_phase2 <- ieepa_all %>% filter(phase == 'phase2_aug7')

  # Direct code matches for surcharge countries
  floor_codes_direct <- ieepa_phase2 %>%
    filter(rate_type == 'floor') %>%
    pull(census_code) %>%
    unique()

  ieepa_surcharge <- ieepa_phase2 %>%
    filter(rate_type == 'surcharge', !(census_code %in% floor_codes_direct)) %>%
    group_by(census_code) %>%
    summarise(rate = max(rate), .groups = 'drop') %>%
    rename(cty_code = census_code, ieepa_surcharge = rate)

  # China's Phase 1 reciprocal
  china_reciprocal_vec <- ieepa_all %>%
    filter(census_code == CTY_CHINA, rate_type == 'surcharge') %>%
    pull(rate)
  china_ieepa <- if (length(china_reciprocal_vec) > 0) max(china_reciprocal_vec) else 0
  message('  China IEEPA reciprocal: ', china_ieepa * 100, '%')
  message('  Surcharge countries: ', nrow(ieepa_surcharge))

  # --- USMCA ---
  message('Loading USMCA eligibility...')
  usmca <- read_csv(usmca_path, col_types = cols(
    hts10 = col_character(), usmca_eligible = col_logical()
  )) %>%
    rename(hs10 = hts10)

  # --- Section 301 by product ---
  message('Computing Section 301 rates by product...')
  s301_by_product <- products %>%
    filter(!is.na(ch99_refs), ch99_refs != '') %>%
    select(hs10, ch99_refs) %>%
    mutate(refs = str_split(ch99_refs, ';')) %>%
    unnest(refs) %>%
    inner_join(SECTION_301_RATES, by = c('refs' = 'ch99_pattern')) %>%
    group_by(hs10) %>%
    summarise(s301_rate = sum(s301_rate), .groups = 'drop')
  message('  Products with Section 301: ', nrow(s301_by_product))

  # --- Partner mapping ---
  partners <- read_csv(partner_path, col_types = cols(.default = col_character()))

  list(
    imports_agg = imports_agg,
    imports_gtap = imports_gtap,
    products = products,
    ieepa_surcharge = ieepa_surcharge,
    china_ieepa = china_ieepa,
    usmca = usmca,
    s301_by_product = s301_by_product,
    partners = partners
  )
}


# =============================================================================
# TPC Comparison Data
# =============================================================================

load_tpc_data <- function(tpc_path, census_codes_path,
                          imports_agg, imports_gtap, partners) {
  message('\nLoading TPC comparison data...')

  tpc <- read_csv(tpc_path, col_types = cols(.default = col_character()))
  date_cols <- setdiff(names(tpc), c('country', 'hts10'))

  # Build name -> code lookup from census_codes.csv
  census <- read_csv(census_codes_path, col_types = cols(.default = col_character()))
  name_lookup <- setNames(census$Code, tolower(census$Name))

  # Pivot to long format and map country codes
  tpc_long <- tpc %>%
    pivot_longer(cols = all_of(date_cols), names_to = 'date', values_to = 'tpc_rate') %>%
    mutate(
      tpc_rate = as.numeric(tpc_rate),
      date = as.Date(date),
      name_lower = tolower(country),
      cty_code = coalesce(TPC_NAME_FIXES[name_lower], name_lookup[name_lower])
    ) %>%
    filter(!is.na(cty_code)) %>%
    rename(hs10 = hts10) %>%
    select(hs10, cty_code, date, tpc_rate)

  n_mapped <- length(unique(tpc_long$cty_code))
  n_total <- length(unique(tpc$country))
  message('  TPC countries mapped: ', n_mapped, ' of ', n_total)

  # Join with import weights and partner groups
  tpc_weighted <- tpc_long %>%
    inner_join(imports_agg, by = c('hs10', 'cty_code')) %>%
    left_join(partners %>% select(cty_code, partner), by = 'cty_code') %>%
    mutate(partner = coalesce(partner, 'row'))

  coverage <- sum(tpc_weighted$imports[tpc_weighted$date == date_cols[1]]) /
    sum(imports_agg$imports)
  message('  TPC import coverage: ', round(coverage * 100, 1), '%')

  tpc_weighted
}


aggregate_tpc <- function(tpc_weighted, imports_gtap) {

  # Overall TPC ETR by date
  tpc_overall <- tpc_weighted %>%
    group_by(date) %>%
    summarise(etr_tpc = sum(tpc_rate * imports) / sum(imports), .groups = 'drop')

  # By partner
  tpc_by_partner <- tpc_weighted %>%
    group_by(date, partner) %>%
    summarise(etr_tpc = sum(tpc_rate * imports) / sum(imports), .groups = 'drop')

  # By GTAP sector
  tpc_by_gtap <- tpc_weighted %>%
    select(hs10, cty_code, date, tpc_rate) %>%
    inner_join(
      imports_gtap %>% select(hs10, cty_code, gtap_code, imports),
      by = c('hs10', 'cty_code')
    ) %>%
    group_by(date, gtap_code) %>%
    summarise(
      etr_tpc = sum(tpc_rate * imports) / sum(imports),
      .groups = 'drop'
    )

  list(
    overall = tpc_overall,
    by_partner = tpc_by_partner,
    by_gtap = tpc_by_gtap
  )
}


# =============================================================================
# Net Authority Decomposition — delegated to helpers.R:compute_net_authority_contributions()
# =============================================================================


# =============================================================================
# Main Pipeline
# =============================================================================

enrich_policy_dates_with_overrides <- function(pd) {
  # Add tpc_policy_revision from revision_dates.csv where available
  rd <- tryCatch(load_revision_dates(), error = function(e) NULL)
  if (!is.null(rd) && 'tpc_policy_revision' %in% names(rd)) {
    overrides <- rd %>%
      filter(!is.na(tpc_date), !is.na(tpc_policy_revision)) %>%
      select(tpc_date, tpc_policy_revision)
    if (nrow(overrides) > 0) {
      pd <- pd %>% left_join(overrides, by = c('date' = 'tpc_date'))
      message('  TPC policy-revision overrides: ',
              sum(!is.na(pd$tpc_policy_revision)), ' date(s)')
    }
  }
  if (!'tpc_policy_revision' %in% names(pd)) {
    pd$tpc_policy_revision <- NA_character_
  }
  pd
}

compute_weighted_etrs <- function(data, policy_params = NULL) {
  message('\nLoading rate timeseries...')

  ts_path <- here('data', 'timeseries', 'rate_timeseries.rds')
  if (!file.exists(ts_path)) {
    stop('Timeseries not found: ', ts_path,
         '\nRun: Rscript src/00_build_timeseries.R')
  }
  ts <- readRDS(ts_path)
  message('  Timeseries: ', nrow(ts), ' rows, ', n_distinct(ts$revision), ' revisions')

  if (!'valid_from' %in% names(ts)) {
    stop('Timeseries missing valid_from/valid_until columns.',
         '\nRebuild with: Rscript src/00_build_timeseries.R')
  }

  # Build flows table (imports + partner mapping)
  flows <- data$imports_agg %>%
    left_join(data$partners %>% select(cty_code, partner), by = 'cty_code') %>%
    mutate(partner = coalesce(partner, 'row'))

  # Total imports across ALL flows (denominator for weighted ETR)
  total_imports <- sum(flows$imports)
  partner_totals <- flows %>%
    group_by(partner) %>%
    summarise(total_imports = sum(imports), .groups = 'drop')

  message('  Flow-level rows: ', nrow(flows))
  message('  Total imports: $', round(total_imports / 1e9, 1), 'B')

  # Enrich POLICY_DATES with tpc_policy_revision overrides (needs helpers.R loaded)
  policy_dates <- enrich_policy_dates_with_overrides(POLICY_DATES)

  # Query rates from timeseries for each policy date
  message('\nQuerying rates across ', nrow(policy_dates), ' policy dates...')

  .rate_snapshot <- function(date, label, tpc_policy_revision = NA_character_) {
    snapshot <- get_rates_at_date(ts, date, policy_params = policy_params)

    # Compute net authority contributions from snapshot rate columns
    # Use total_rate (base + additional) for comparability with TPC benchmark
    snapshot_net <- snapshot %>%
      compute_net_authority_contributions(cty_china = CTY_CHINA) %>%
      select(hts10, country, total_rate,
             net_232, net_ieepa, net_fentanyl, net_301, net_s122, net_section_201, net_other)

    # Join snapshot rates with import flows
    rated <- flows %>%
      inner_join(
        snapshot_net,
        by = c('hs10' = 'hts10', 'cty_code' = 'country')
      ) %>%
      mutate(date = date, label = label)

    rated %>% select(hs10, cty_code, partner, imports, date, label,
                      total_rate, net_232, net_ieepa, net_fentanyl, net_301,
                      net_s122, net_section_201)
  }

  results <- policy_dates %>% pmap_dfr(.rate_snapshot)
  message('  Total rated flows: ', nrow(results))

  # Compute policy-aligned results for TPC comparison where tpc_policy_revision overrides exist
  # These use a specific revision's snapshot instead of date-based lookup
  override_dates <- policy_dates %>% filter(!is.na(tpc_policy_revision))
  policy_aligned <- NULL

  if (nrow(override_dates) > 0) {
    message('\nComputing policy-aligned ETRs for ', nrow(override_dates),
            ' TPC date override(s)...')
    policy_aligned <- override_dates %>%
      pmap_dfr(function(date, label, tpc_policy_revision) {
        # Load the specified revision's snapshot from timeseries
        rev_snapshot <- ts %>% filter(revision == tpc_policy_revision)
        if (nrow(rev_snapshot) == 0) {
          warning('Override revision ', tpc_policy_revision, ' not found in timeseries; ',
                  'falling back to date-based lookup for ', label)
          rev_snapshot <- get_rates_at_date(ts, date, policy_params = policy_params)
        }

        snapshot_net <- rev_snapshot %>%
          compute_net_authority_contributions(cty_china = CTY_CHINA) %>%
          select(hts10, country, total_rate,
                 net_232, net_ieepa, net_fentanyl, net_301, net_s122, net_section_201, net_other)

        rated <- flows %>%
          inner_join(snapshot_net, by = c('hs10' = 'hts10', 'cty_code' = 'country')) %>%
          mutate(date = date, label = label)

        rated %>% select(hs10, cty_code, partner, imports, date, label,
                          total_rate, net_232, net_ieepa, net_fentanyl, net_301,
                          net_s122, net_section_201)
      })
    message('  Policy-aligned flows: ', nrow(policy_aligned))
  }

  return(list(
    results = results,
    policy_aligned = policy_aligned,
    total_imports = total_imports,
    partner_totals = partner_totals
  ))
}


# =============================================================================
# Aggregation
# =============================================================================

aggregate_etrs <- function(results, imports_gtap, total_imports, partner_totals,
                           policy_aligned = NULL) {

  # --- Overall ETR by date ---
  # Denominator = total imports (all flows), not just matched
  overall <- results %>%
    group_by(date, label) %>%
    summarise(
      etr = sum(total_rate * imports) / total_imports,
      matched_imports_b = sum(imports) / 1e9,
      total_imports_b = total_imports / 1e9,
      .groups = 'drop'
    ) %>%
    mutate(label = factor(label, levels = POLICY_DATES$label))

  # Policy-aligned ETR for TPC comparison (uses override revision where specified)
  if (!is.null(policy_aligned) && nrow(policy_aligned) > 0) {
    aligned_overall <- policy_aligned %>%
      group_by(date, label) %>%
      summarise(etr_aligned = sum(total_rate * imports) / total_imports, .groups = 'drop')
    overall <- overall %>%
      left_join(aligned_overall, by = c('date', 'label'))
    message('  Policy-aligned ETR overrides: ', sum(!is.na(overall$etr_aligned)))
  }

  message('\n=== Overall Weighted ETR ===')
  overall %>%
    mutate(etr_pct = round(etr * 100, 2)) %>%
    select(date, label, etr_pct, matched_imports_b, total_imports_b) %>%
    print()

  # --- By partner ---
  # Denominator = partner's total imports (all flows for that partner)
  by_partner <- results %>%
    group_by(date, label, partner) %>%
    summarise(
      weighted_numerator = sum(total_rate * imports),
      matched_imports = sum(imports),
      .groups = 'drop'
    ) %>%
    left_join(
      partner_totals %>% rename(partner_total = total_imports),
      by = 'partner'
    ) %>%
    mutate(
      etr = weighted_numerator / partner_total,
      import_share = partner_total / total_imports
    ) %>%
    select(date, label, partner, etr, import_share) %>%
    mutate(label = factor(label, levels = POLICY_DATES$label))

  message('\n=== ETR by Partner (Current) ===')
  by_partner %>%
    filter(date == max(date)) %>%
    mutate(etr_pct = round(etr * 100, 2),
           share_pct = round(import_share * 100, 1)) %>%
    arrange(desc(import_share)) %>%
    select(partner, etr_pct, share_pct) %>%
    print()

  # --- By authority (net decomposition that sums to total) ---
  # Denominator = total imports (consistent with overall)
  by_authority <- results %>%
    group_by(date, label) %>%
    summarise(
      etr_total = sum(total_rate * imports) / total_imports,
      etr_232 = sum(net_232 * imports) / total_imports,
      etr_ieepa = sum(net_ieepa * imports) / total_imports,
      etr_fentanyl = sum(net_fentanyl * imports) / total_imports,
      etr_301 = sum(net_301 * imports) / total_imports,
      etr_s122 = sum(net_s122 * imports) / total_imports,
      etr_section_201 = sum(net_section_201 * imports) / total_imports,
      .groups = 'drop'
    ) %>%
    mutate(label = factor(label, levels = POLICY_DATES$label))

  # --- By GTAP sector ---
  # Denominator = sector's total imports (all flows for that sector)
  sector_totals <- imports_gtap %>%
    group_by(gtap_code) %>%
    summarise(sector_total = sum(imports), .groups = 'drop')

  by_gtap <- results %>%
    inner_join(
      imports_gtap %>% select(hs10, cty_code, gtap_code),
      by = c('hs10', 'cty_code')
    ) %>%
    group_by(date, label, gtap_code) %>%
    summarise(
      weighted_numerator = sum(total_rate * imports),
      matched_imports = sum(imports),
      .groups = 'drop'
    ) %>%
    left_join(sector_totals, by = 'gtap_code') %>%
    mutate(
      etr = weighted_numerator / sector_total,
      total_imports = sector_total
    ) %>%
    select(date, label, gtap_code, etr, total_imports) %>%
    mutate(label = factor(label, levels = POLICY_DATES$label))

  list(
    overall = overall,
    by_partner = by_partner,
    by_authority = by_authority,
    by_gtap = by_gtap
  )
}


# =============================================================================
# Plotting
# =============================================================================

plot_etrs <- function(etrs, tpc_etrs = NULL, output_dir) {
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
  has_tpc <- !is.null(tpc_etrs)

  theme_etr <- theme_minimal(base_size = 12) +
    theme(
      plot.title = element_text(face = 'bold'),
      axis.text.x = element_text(angle = 45, hjust = 1),
      legend.position = 'bottom'
    )

  source_colors <- c('Yale Budget Lab' = '#2c3e50', 'TPC' = '#e74c3c')
  source_linetypes <- c('Yale Budget Lab' = 'solid', 'TPC' = 'dashed')

  # --- Plot 1: Overall ETR time series (ours + TPC if available) ---
  overall_combined <- etrs$overall %>%
    select(date, label, etr) %>%
    mutate(source = 'Yale Budget Lab')
  if (has_tpc) {
    overall_combined <- bind_rows(
      overall_combined,
      tpc_etrs$overall %>%
        left_join(POLICY_DATES, by = 'date') %>%
        mutate(
          label = factor(label, levels = POLICY_DATES$label),
          source = 'TPC'
        ) %>%
        rename(etr = etr_tpc)
    )
  }

  p1 <- ggplot(overall_combined,
               aes(x = label, y = etr * 100, color = source,
                   linetype = source, group = source)) +
    geom_line(linewidth = 1.2) +
    geom_point(size = 3) +
    geom_text(aes(label = paste0(round(etr * 100, 1), '%')),
              vjust = -1, size = 3.2, show.legend = FALSE) +
    labs(
      title = 'Import-Weighted Average Tariff Rate',
      subtitle = 'Weighted by 2024 Census consumption imports',
      x = NULL, y = 'Weighted Average ETR (%)',
      color = NULL, linetype = NULL
    ) +
    scale_color_manual(values = source_colors) +
    scale_linetype_manual(values = source_linetypes) +
    scale_y_continuous(limits = c(0, NA), expand = expansion(mult = c(0, 0.15))) +
    theme_etr

  ggsave(file.path(output_dir, 'etr_overall.png'), p1,
         width = 8, height = 5, dpi = 150)
  message('Saved etr_overall.png')

  # --- Plot 2: ETR by partner (faceted, ours + TPC if available) ---
  partner_combined <- etrs$by_partner %>%
    select(date, label, partner, etr) %>%
    mutate(source = 'Yale Budget Lab')
  if (has_tpc) {
    partner_combined <- bind_rows(
      partner_combined,
      tpc_etrs$by_partner %>%
        left_join(POLICY_DATES, by = 'date') %>%
        mutate(
          label = factor(label, levels = POLICY_DATES$label),
          source = 'TPC'
        ) %>%
        rename(etr = etr_tpc)
    )
  }

  # Nice partner labels
  partner_labels <- c(
    'china' = 'China', 'canada' = 'Canada', 'mexico' = 'Mexico',
    'eu' = 'EU-27', 'uk' = 'UK', 'japan' = 'Japan',
    'ftrow' = 'FTA Partners', 'row' = 'Rest of World'
  )
  partner_combined <- partner_combined %>%
    mutate(partner_label = coalesce(partner_labels[partner], partner))

  # Order facets by current-date ETR (descending)
  partner_order <- partner_combined %>%
    filter(date == max(date), source == 'Yale Budget Lab') %>%
    arrange(desc(etr)) %>%
    pull(partner_label)
  partner_combined <- partner_combined %>%
    mutate(partner_label = factor(partner_label, levels = partner_order))

  p2 <- ggplot(partner_combined,
               aes(x = label, y = etr * 100, color = source,
                   linetype = source, group = source)) +
    geom_line(linewidth = 0.8) +
    geom_point(size = 1.5) +
    facet_wrap(~partner_label, scales = 'free_y', ncol = 4) +
    labs(
      title = 'Import-Weighted ETR by Partner Group',
      subtitle = 'Weighted by 2024 Census consumption imports',
      x = NULL, y = 'Weighted Average ETR (%)',
      color = NULL, linetype = NULL
    ) +
    scale_color_manual(values = source_colors) +
    scale_linetype_manual(values = source_linetypes) +
    scale_y_continuous(limits = c(0, NA), expand = expansion(mult = c(0, 0.1))) +
    theme_etr +
    theme(strip.text = element_text(face = 'bold'))

  ggsave(file.path(output_dir, 'etr_by_partner.png'), p2,
         width = 12, height = 6, dpi = 150)
  message('Saved etr_by_partner.png')

  # --- Plot 3: Authority decomposition (stacked bars) + TPC total line ---
  auth_long <- etrs$by_authority %>%
    select(date, label, etr_232, etr_ieepa, etr_fentanyl, etr_301, etr_s122,
           etr_section_201) %>%
    pivot_longer(cols = starts_with('etr_'),
                 names_to = 'authority', values_to = 'etr') %>%
    mutate(
      authority = case_when(
        authority == 'etr_232' ~ 'Section 232',
        authority == 'etr_ieepa' ~ 'IEEPA Reciprocal',
        authority == 'etr_fentanyl' ~ 'IEEPA Fentanyl',
        authority == 'etr_301' ~ 'Section 301',
        authority == 'etr_s122' ~ 'Section 122',
        authority == 'etr_section_201' ~ 'Section 201'
      ),
      authority = factor(authority, levels = c(
        'IEEPA Reciprocal', 'IEEPA Fentanyl', 'Section 301',
        'Section 232', 'Section 122', 'Section 201'
      ))
    ) %>%
    filter(etr > 1e-6)  # hide authorities with negligible contribution

  p3 <- ggplot() +
    geom_col(data = auth_long,
             aes(x = label, y = etr * 100, fill = authority),
             position = 'stack')
  if (has_tpc) {
    tpc_total_overlay <- tpc_etrs$overall %>%
      left_join(POLICY_DATES, by = 'date') %>%
      mutate(label = factor(label, levels = POLICY_DATES$label))
    p3 <- p3 +
      geom_line(data = tpc_total_overlay,
                aes(x = label, y = etr_tpc * 100, group = 1),
                linewidth = 1.2, linetype = 'dashed', color = '#e74c3c') +
      geom_point(data = tpc_total_overlay,
                 aes(x = label, y = etr_tpc * 100),
                 size = 3, shape = 4, stroke = 1.5, color = '#e74c3c')
  }
  p3 <- p3 +
    labs(
      title = 'Import-Weighted ETR by Authority',
      subtitle = if (has_tpc) 'Stacked bars = Yale Budget Lab decomposition; dashed line = TPC total'
                 else 'Stacked bars = Yale Budget Lab decomposition',
      x = NULL, y = 'Weighted Average ETR (%)',
      fill = 'Authority'
    ) +
    scale_fill_manual(values = c(
      'IEEPA Reciprocal' = '#e67e22',
      'IEEPA Fentanyl' = '#f1c40f',
      'Section 301' = '#3498db',
      'Section 232' = '#2ecc71',
      'Section 122' = '#9b59b6',
      'Section 201' = '#1abc9c'
    )) +
    scale_y_continuous(expand = expansion(mult = c(0, 0.05))) +
    theme_etr

  ggsave(file.path(output_dir, 'etr_by_authority.png'), p3,
         width = 8, height = 5, dpi = 150)
  message('Saved etr_by_authority.png')

  # --- Plot 4: Top GTAP sectors (current date, ours vs TPC dodged) ---
  top_sectors <- etrs$by_gtap %>%
    filter(date == max(date)) %>%
    slice_max(order_by = total_imports, n = 15) %>%
    pull(gtap_code)

  sector_combined <- etrs$by_gtap %>%
    filter(date == max(date), gtap_code %in% top_sectors) %>%
    select(gtap_code, etr) %>%
    mutate(source = 'Yale Budget Lab')
  if (has_tpc) {
    sector_combined <- bind_rows(
      sector_combined,
      tpc_etrs$by_gtap %>%
        filter(date == max(date), gtap_code %in% top_sectors) %>%
        select(gtap_code, etr = etr_tpc) %>%
        mutate(source = 'TPC')
    )
  }
  sector_combined <- sector_combined %>%
    mutate(gtap_code = fct_reorder(gtap_code, etr, .fun = max))

  p4 <- ggplot(sector_combined,
               aes(x = gtap_code, y = etr * 100, fill = source)) +
    geom_col(position = position_dodge(width = 0.8), width = 0.7) +
    coord_flip() +
    labs(
      title = 'ETR by GTAP Sector (Top 15 by Import Value)',
      subtitle = paste0('As of ', max(etrs$by_gtap$date)),
      x = NULL, y = 'Weighted Average ETR (%)',
      fill = NULL
    ) +
    scale_fill_manual(values = source_colors) +
    theme_etr +
    theme(legend.position = 'right')

  ggsave(file.path(output_dir, 'etr_by_sector.png'), p4,
         width = 9, height = 6, dpi = 150)
  message('Saved etr_by_sector.png')

  list(p1 = p1, p2 = p2, p3 = p3, p4 = p4)
}


# =============================================================================
# Main
# =============================================================================

# =============================================================================
# Reusable Wrapper (called by 00_build_timeseries.R post-build)
# =============================================================================

#' Run full weighted ETR pipeline
#'
#' Loads data, computes weighted ETRs, generates TPC comparison, saves outputs.
#' Called by 00_build_timeseries.R post-build and usable standalone.
#'
#' @param ts Timeseries tibble (unused currently — compute_weighted_etrs loads its own)
#' @param policy_params Optional policy params list (from load_policy_params())
#' @return ETR results (invisible)
run_weighted_etr <- function(ts = NULL, policy_params = NULL) {
  # Resolve import weights path from local_paths config
  local_paths <- if (!is.null(policy_params)) policy_params$LOCAL_PATHS else load_local_paths()
  imports_path <- local_paths$import_weights
  if (is.null(imports_path)) {
    message('Import weights not configured in config/local_paths.yaml — skipping weighted ETR.')
    return(invisible(NULL))
  }
  if (!file.exists(imports_path)) {
    message('Import weights file not found: ', imports_path, ' — skipping weighted ETR.')
    return(invisible(NULL))
  }

  data <- load_data(
    products_path = here('data', 'processed', 'products_raw.csv'),
    ieepa_path    = here('data', 'processed', 'ieepa_country_rates.csv'),
    usmca_path    = here('data', 'processed', 'usmca_products.csv'),
    imports_path  = imports_path,
    partner_path  = here('resources', 'country_partner_mapping.csv')
  )

  etr_data <- compute_weighted_etrs(data, policy_params = policy_params)
  etrs <- aggregate_etrs(
    etr_data$results, data$imports_gtap,
    etr_data$total_imports, etr_data$partner_totals,
    policy_aligned = etr_data$policy_aligned
  )

  # Load TPC comparison (optional — skipped if TPC file missing)
  tpc_path <- local_paths$tpc_benchmark
  tpc_etrs <- NULL

  if (!is.null(tpc_path) && file.exists(tpc_path)) {
    tryCatch({
      tpc_weighted <- load_tpc_data(
        tpc_path         = tpc_path,
        census_codes_path = here('resources', 'census_codes.csv'),
        imports_agg      = data$imports_agg,
        imports_gtap     = data$imports_gtap,
        partners         = data$partners
      )
      tpc_etrs <- aggregate_tpc(tpc_weighted, data$imports_gtap)

      message('\n=== TPC Overall Weighted ETR ===')
      tpc_etrs$overall %>%
        left_join(POLICY_DATES %>% select(date, label), by = 'date') %>%
        mutate(etr_pct = round(etr_tpc * 100, 2)) %>%
        select(date, label, etr_pct) %>%
        print()

      # Show policy-aligned comparison where overrides exist
      if ('etr_aligned' %in% names(etrs$overall) && any(!is.na(etrs$overall$etr_aligned))) {
        message('\n=== TPC Comparison (Policy-Aligned) ===')
        etrs$overall %>%
          left_join(tpc_etrs$overall, by = 'date') %>%
          filter(!is.na(etr_tpc)) %>%
          mutate(
            tracker_pct = round(ifelse(!is.na(etr_aligned), etr_aligned, etr) * 100, 2),
            tpc_pct = round(etr_tpc * 100, 2),
            diff_pp = round(tracker_pct - tpc_pct, 2),
            aligned = ifelse(!is.na(etr_aligned), '*', '')
          ) %>%
          select(date, label, tracker_pct, tpc_pct, diff_pp, aligned) %>%
          print()
        message('  * = policy-aligned (uses tpc_policy_revision override from revision_dates.csv)')
      }
    }, error = function(e) {
      message('TPC comparison failed: ', conditionMessage(e))
    })
  } else {
    message('TPC benchmark file not found — ETR outputs will omit TPC comparison columns.')
  }

  # Plot (with or without TPC overlay)
  plots <- plot_etrs(etrs, tpc_etrs, here('output', 'etr'))

  # Save CSVs (with TPC columns if available)
  if (!is.null(tpc_etrs)) {
    write_csv(
      etrs$overall %>% left_join(tpc_etrs$overall, by = 'date'),
      here('output', 'etr', 'etr_overall.csv')
    )
    write_csv(
      etrs$by_partner %>% left_join(tpc_etrs$by_partner, by = c('date', 'partner')),
      here('output', 'etr', 'etr_by_partner.csv')
    )
    write_csv(
      etrs$by_authority %>% left_join(tpc_etrs$overall, by = 'date'),
      here('output', 'etr', 'etr_by_authority.csv')
    )
    write_csv(
      etrs$by_gtap %>% left_join(tpc_etrs$by_gtap, by = c('date', 'gtap_code')),
      here('output', 'etr', 'etr_by_gtap.csv')
    )
  } else {
    write_csv(etrs$overall, here('output', 'etr', 'etr_overall.csv'))
    write_csv(etrs$by_partner, here('output', 'etr', 'etr_by_partner.csv'))
    write_csv(etrs$by_authority, here('output', 'etr', 'etr_by_authority.csv'))
    write_csv(etrs$by_gtap, here('output', 'etr', 'etr_by_gtap.csv'))
  }
  message('\nAll ETR outputs saved to output/etr/')

  return(invisible(etrs))
}


# =============================================================================
# Main
# =============================================================================

if (sys.nframe() == 0) {
  library(here)
  source(here('src', 'helpers.R'))

  pp <- load_policy_params()
  run_weighted_etr(policy_params = pp)
}
