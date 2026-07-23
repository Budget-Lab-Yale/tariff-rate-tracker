# =============================================================================
# Counterfactual scenario inputs
# =============================================================================
# `disabled_authorities` is an instruction about the policy world to build, not
# an edit to a finished rate panel. This module removes the named authorities
# from the parsed inputs before AuthoritySpecs and rates are calculated.

SCENARIO_INPUT_AUTHORITIES <- c(
  'section_232', 'section_301', 'section_301_content_split',
  'section_301_brazil', 'section_338',
  'ieepa_reciprocal', 'ieepa_fentanyl', 'section_122', 'other'
)

#' Apply counterfactual authority removals to one revision's parsed inputs.
#'
#' Chapter-99 rows are removed for footnote/list-driven authorities; the two
#' IEEPA extractor tables are emptied independently because their current
#' headings are not all classified by classify_authority(). Section 232's
#' config-only annex and heading programs are also removed from the effective
#' policy params. The returned policy list records which removals were applied,
#' allowing the calculator to fail if a caller bypasses this input stage.
#'
#' @return List with ch99_data, ieepa_rates, fentanyl_rates, and policy_params.
apply_counterfactual_inputs <- function(ch99_data, ieepa_rates = NULL,
                                        fentanyl_rates = NULL, policy_params) {
  disabled <- unique(as.character(unlist(
    policy_params$disabled_authorities %||% character(0)
  )))
  if (length(disabled) == 0) {
    policy_params$SCENARIO_DISABLED_AUTHORITIES_APPLIED <- character(0)
    return(list(
      ch99_data = ch99_data,
      ieepa_rates = ieepa_rates,
      fentanyl_rates = fentanyl_rates,
      policy_params = policy_params
    ))
  }

  invalid <- setdiff(disabled, SCENARIO_INPUT_AUTHORITIES)
  if (length(invalid)) {
    stop('apply_counterfactual_inputs: unsupported authority name(s): ',
         paste(invalid, collapse = ', '), '. Supported: ',
         paste(SCENARIO_INPUT_AUTHORITIES, collapse = ', '), call. = FALSE)
  }

  authority <- if ('authority' %in% names(ch99_data)) {
    as.character(ch99_data$authority)
  } else {
    vapply(ch99_data$ch99_code, classify_authority, character(1))
  }

  drop_authorities <- intersect(
    disabled,
    c('section_232', 'section_301', 'section_301_brazil', 'ieepa_reciprocal',
      'section_122', 'section_338', 'other')
  )
  drop_codes <- character(0)
  if ('ieepa_reciprocal' %in% disabled && !is.null(ieepa_rates) &&
      'ch99_code' %in% names(ieepa_rates)) {
    drop_codes <- c(drop_codes, ieepa_rates$ch99_code)
  }
  if ('ieepa_fentanyl' %in% disabled && !is.null(fentanyl_rates) &&
      'ch99_code' %in% names(fentanyl_rates)) {
    drop_codes <- c(drop_codes, fentanyl_rates$ch99_code)
  }
  if ('section_301_content_split' %in% disabled) {
    drop_codes <- c(
      drop_codes,
      as.character(policy_params$section_301_content_split_codes %||% character(0))
    )
  }

  keep <- !(authority %in% drop_authorities |
              ch99_data$ch99_code %in% unique(drop_codes))
  ch99_data <- ch99_data[keep, , drop = FALSE]

  if ('ieepa_reciprocal' %in% disabled && !is.null(ieepa_rates)) {
    ieepa_rates <- ieepa_rates[0, , drop = FALSE]
    attr(ieepa_rates, 'universal_baseline') <- 0
  }
  if ('ieepa_fentanyl' %in% disabled && !is.null(fentanyl_rates)) {
    fentanyl_rates <- fentanyl_rates[0, , drop = FALSE]
  }

  if ('section_232' %in% disabled) {
    # Some §232 programs are configured rather than represented by a live Ch99
    # rate row. Empty those inputs too, while preserving required list shapes.
    policy_params$section_232_headings <- list()
    policy_params$section_232_country_exemptions <- list()
    policy_params$S232_COUNTRY_EXEMPTIONS <- list()
    policy_params$section_232_annexes <- NULL
    policy_params$S232_ANNEXES <- NULL
    policy_params$section_232_derivatives <- NULL
    policy_params$section_232_aircraft_exemption <- NULL
  }
  if ('section_301_content_split' %in% disabled) {
    policy_params$section_301_content_split_codes <- character(0)
  }
  if ('section_338' %in% disabled) {
    # §338 charging/exception headings (9903.03.12-.16) are removed from
    # ch99_data via classify_authority above; the authority itself is built
    # from this config block, so remove it too.
    policy_params$section_338 <- NULL
  }
  if ('section_301_brazil' %in% disabled) {
    # Charging/exemption headings (9903.05.01-.09, codified by 2026 HTS rev_12)
    # are removed from ch99_data via classify_authority above; the authority
    # itself is built from this config block, so remove it too.
    policy_params$section_301_brazil <- NULL
  }

  policy_params$SCENARIO_DISABLED_AUTHORITIES_APPLIED <- disabled
  message('  Counterfactual inputs removed before calculation: ',
          paste(disabled, collapse = ', '))

  list(
    ch99_data = ch99_data,
    ieepa_rates = ieepa_rates,
    fentanyl_rates = fentanyl_rates,
    policy_params = policy_params
  )
}

#' Fail if disabled-authority instructions bypassed the input preparation stage.
assert_counterfactual_inputs_applied <- function(policy_params) {
  disabled <- unique(as.character(unlist(
    policy_params$disabled_authorities %||% character(0)
  )))
  applied <- as.character(
    policy_params$SCENARIO_DISABLED_AUTHORITIES_APPLIED %||% character(0)
  )
  pending <- setdiff(disabled, applied)
  if (length(pending)) {
    stop('Counterfactual authority removals must be applied before calculation: ',
         paste(pending, collapse = ', '),
         '. Use build_revision_snapshot() or apply_counterfactual_inputs().',
         call. = FALSE)
  }
  invisible(TRUE)
}
