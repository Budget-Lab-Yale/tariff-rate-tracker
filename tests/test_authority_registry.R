# =============================================================================
# Authority registry invariants
# =============================================================================

suppressPackageStartupMessages(library(here))
source(here('src', 'model', 'authority_registry.R'))
source(here('src', 'model', 'stacking.R'))
source(here('src', 'model', 'rate_schema.R'))

passed <- 0L
check <- function(condition, message) {
  if (!isTRUE(condition)) stop('FAILED: ', message, call. = FALSE)
  passed <<- passed + 1L
  cat('  ok:', message, '\n')
}
rejects <- function(expr) {
  tryCatch({ force(expr); FALSE }, error = function(e) TRUE)
}

cat('--- registry identity and downstream coverage ---\n')
check(identical(
  AUTHORITY_REGISTRY$rate_col,
  c('rate_232', 'rate_ieepa_recip', 'rate_ieepa_fent', 'rate_301',
    'rate_301_cs', 'rate_s301fl', 'rate_s301br', 'rate_s338', 'rate_s122',
    'rate_section_201', 'rate_other')
), 'stacking order remains explicit and stable')

check(identical(
  AUTHORITY_RATE_COLUMNS,
  c('rate_232', 'rate_301', 'rate_301_cs', 'rate_s301br', 'rate_s301fl',
    'rate_ieepa_recip', 'rate_ieepa_fent', 'rate_s122', 'rate_s338',
    'rate_section_201', 'rate_other')
), 'canonical panel includes baseline forced-labor authority')

panel <- authority_panel_registry()
check(all(panel$rate_col %in% RATE_SCHEMA),
      'every baseline authority rate appears in RATE_SCHEMA')
check('rate_s301fl' %in% RATE_SCHEMA,
      'forced-labor final-action rate is in the baseline schema')
check(identical(authority_report_net_columns(),
                c('net_232', 'net_301', 'net_301_cs', 'net_s301br',
                  'net_s301fl', 'net_ieepa', 'net_fentanyl', 'net_s122',
                  'net_s338', 'net_section_201', 'net_other')),
      'daily decomposition preserves its historical floating-point sum order')

buckets <- authority_report_buckets()
check(identical(names(buckets),
                c('232', '301', 's301br', 'ieepa', 'fentanyl', 's122',
                  's338', 'section_201', 'other')),
      'report buckets are ordered by report_sum_order')
check(identical(buckets[['301']], c('net_301', 'net_301_cs', 'net_s301fl')),
      'Section 301 bucket folds content-split + forced-labor flavors, in order')
check(setequal(unlist(buckets), authority_report_net_columns()),
      'report buckets partition exactly the reported net-column census')

policy <- default_stacking_policy('5700')
check(identical(names(policy), AUTHORITY_REGISTRY$rate_col),
      'default stacking policy covers registry entries in registry order')
check(identical(unname(vapply(policy, `[[`, character(1), 'net')),
                AUTHORITY_REGISTRY$net_col),
      'stacking net-column mappings come from the registry')
check(identical(policy$rate_ieepa_fent$additive_countries, '5700'),
      'China additive exception is materialized from the registry rule')

cat('\n--- malformed registries fail closed ---\n')
duplicate_rate <- AUTHORITY_REGISTRY
duplicate_rate$rate_col[2] <- duplicate_rate$rate_col[1]
check(rejects(validate_authority_registry(duplicate_rate)),
      'duplicate rate columns are rejected')

bad_class <- AUTHORITY_REGISTRY
bad_class$default_stacking_class[1] <- 'mystery'
check(rejects(validate_authority_registry(bad_class)),
      'unknown stacking classes are rejected')

bad_panel_order <- AUTHORITY_REGISTRY
bad_panel_order$panel_order[1] <- 2L
check(rejects(validate_authority_registry(bad_panel_order)),
      'duplicate panel positions are rejected')

bad_schema_group <- AUTHORITY_REGISTRY
bad_schema_group$schema_group[1] <- NA_character_
check(rejects(validate_authority_registry(bad_schema_group)),
      'baseline authorities without schema placement are rejected')

cat(sprintf('\nALL %d AUTHORITY-REGISTRY ASSERTIONS PASSED\n', passed))
