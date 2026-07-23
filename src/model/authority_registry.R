# =============================================================================
# Authority Registry — shared structural metadata for tariff rate columns
# =============================================================================
# This is R code, not user configuration. Policy-specific calculations remain in
# the authority adapters/calculator; this registry only gives shared plumbing one
# authoritative description of each rate layer.

AUTHORITY_REGISTRY <- data.frame(
  rate_col = c(
    'rate_232', 'rate_ieepa_recip', 'rate_ieepa_fent', 'rate_301',
    'rate_301_cs', 'rate_s301fl', 'rate_s301br', 'rate_s338', 'rate_s122',
    'rate_section_201', 'rate_other'
  ),
  net_col = c(
    'net_232', 'net_ieepa', 'net_fentanyl', 'net_301', 'net_301_cs',
    'net_s301fl', 'net_s301br', 'net_s338', 'net_s122',
    'net_section_201', 'net_other'
  ),
  spec_authority = c(
    'section_232', 'ieepa_reciprocal', 'ieepa_fentanyl', 'section_301',
    NA, 'section_301_forced_labor', 'section_301_brazil', 'section_338',
    'section_122', 'section_201', 'other'
  ),
  default_stacking_class = c(
    'primary', 'content_split', 'content_split', 'additive',
    'content_split', 'content_split', 'additive', 'additive',
    'content_split', 'additive', 'additive'
  ),
  additive_country_rule = c(
    'none', 'none', 'china', 'none', 'none', 'none', 'none', 'none',
    'none', 'none', 'none'
  ),
  report_bucket = c(
    '232', 'ieepa', 'fentanyl', '301', '301', '301', 's301br', 's338',
    's122', 'section_201', 'other'
  ),
  report_sum_order = c(1L, 6L, 7L, 2L, 3L, 5L, 4L, 9L, 8L, 10L, 11L),
  # NA means scenario-only: carried by stacking when present, but not persisted
  # as a baseline column in the canonical rate panel.
  panel_order = c(1L, 5L, 6L, 2L, 3L, NA, 4L, 8L, 7L, 9L, 10L),
  schema_group = c(
    'pre_swiss', 'pre_swiss', 'pre_swiss', 'pre_swiss', 'pre_swiss',
    NA, 'pre_swiss', 'post_swiss', 'post_swiss', 'post_swiss', 'post_swiss'
  ),
  stringsAsFactors = FALSE
)


validate_authority_registry <- function(registry = AUTHORITY_REGISTRY) {
  required <- c(
    'rate_col', 'net_col', 'spec_authority', 'default_stacking_class',
    'additive_country_rule', 'report_bucket', 'report_sum_order', 'panel_order',
    'schema_group'
  )
  missing <- setdiff(required, names(registry))
  if (length(missing)) {
    stop('Authority registry is missing fields: ', paste(missing, collapse = ', '),
         call. = FALSE)
  }
  if (!nrow(registry) || anyNA(registry$rate_col) || anyNA(registry$net_col) ||
      anyDuplicated(registry$rate_col) || anyDuplicated(registry$net_col)) {
    stop('Authority registry rate_col/net_col values must be non-missing and unique',
         call. = FALSE)
  }
  bad_class <- setdiff(unique(registry$default_stacking_class),
                       c('primary', 'content_split', 'additive'))
  if (length(bad_class)) {
    stop('Authority registry has unsupported stacking classes: ',
         paste(bad_class, collapse = ', '), call. = FALSE)
  }
  bad_country_rule <- setdiff(unique(registry$additive_country_rule), c('none', 'china'))
  if (length(bad_country_rule)) {
    stop('Authority registry has unsupported additive-country rules: ',
         paste(bad_country_rule, collapse = ', '), call. = FALSE)
  }
  panel_order <- registry$panel_order[!is.na(registry$panel_order)]
  if (any(panel_order <= 0) || anyDuplicated(panel_order) ||
      !identical(sort(panel_order), seq_along(panel_order))) {
    stop('Authority registry panel_order must be a contiguous unique sequence',
         call. = FALSE)
  }
  if (anyDuplicated(registry$report_sum_order) ||
      !identical(sort(registry$report_sum_order), seq_len(nrow(registry)))) {
    stop('Authority registry report_sum_order must be a contiguous unique sequence',
         call. = FALSE)
  }
  panel_groups <- registry$schema_group[!is.na(registry$panel_order)]
  if (anyNA(panel_groups) ||
      length(setdiff(unique(panel_groups), c('pre_swiss', 'post_swiss')))) {
    stop('Every panel authority needs a supported schema_group', call. = FALSE)
  }
  if (any(!is.na(registry$schema_group[is.na(registry$panel_order)]))) {
    stop('Scenario-only authorities cannot have a baseline schema_group', call. = FALSE)
  }
  invisible(registry)
}


authority_panel_registry <- function(registry = AUTHORITY_REGISTRY) {
  validate_authority_registry(registry)
  panel <- registry[!is.na(registry$panel_order), , drop = FALSE]
  panel[order(panel$panel_order), , drop = FALSE]
}


authority_rate_columns <- function(registry = AUTHORITY_REGISTRY) {
  authority_panel_registry(registry)$rate_col
}


authority_report_net_columns <- function(registry = AUTHORITY_REGISTRY) {
  validate_authority_registry(registry)
  registry$net_col[order(registry$report_sum_order)]
}


validate_authority_registry()
