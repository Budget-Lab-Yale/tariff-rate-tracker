# =============================================================================
# Install R Dependencies
# =============================================================================
#
# Installs required and optional R packages for the Tariff Rate Tracker.
# Safe to run multiple times — skips already-installed packages.
#
# Usage:
#   Rscript src/install_dependencies.R            # Required packages only
#   Rscript src/install_dependencies.R --all       # Required + optional
#
# =============================================================================

REQUIRED <- c(
  'tidyverse',   # dplyr, tidyr, readr, ggplot2, stringr, purrr, etc.
  'jsonlite',    # HTS JSON parsing
  'yaml',        # Policy params and config loading
  'here'         # Project-relative paths
)

OPTIONAL <- c(
  'pdftools',    # Chapter 99 US Notes PDF parsing (scrape_us_notes.R)
  'digest',      # Chapter 99 PDF change detection (01_scrape_revision_dates.R)
  'arrow',       # Parquet export (09_daily_series.R export_daily_slice)
  'httr'         # HTTP utilities (optional download fallbacks)
)

install_if_missing <- function(packages, label = 'required') {
  installed <- vapply(packages, requireNamespace, logical(1), quietly = TRUE)
  missing <- packages[!installed]

  if (length(missing) == 0) {
    cat(sprintf('All %s packages already installed (%d).\n', label, length(packages)))
    return(invisible(character(0)))
  }

  cat(sprintf('Installing %d %s package(s): %s\n', length(missing), label, paste(missing, collapse = ', ')))
  install.packages(missing, quiet = TRUE)

  # Verify
  still_missing <- missing[!vapply(missing, requireNamespace, logical(1), quietly = TRUE)]
  if (length(still_missing) > 0) {
    warning('Failed to install: ', paste(still_missing, collapse = ', '))
  } else {
    cat(sprintf('Successfully installed: %s\n', paste(missing, collapse = ', ')))
  }
  return(invisible(still_missing))
}


# =============================================================================
# Main
# =============================================================================

if (sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  install_all <- '--all' %in% args

  cat(strrep('=', 60), '\n')
  cat('Tariff Rate Tracker — Install Dependencies\n')
  cat(strrep('=', 60), '\n\n')

  cat('--- Required packages ---\n')
  req_fail <- install_if_missing(REQUIRED, 'required')

  if (install_all) {
    cat('\n--- Optional packages ---\n')
    opt_fail <- install_if_missing(OPTIONAL, 'optional')
  } else {
    cat('\nSkipping optional packages. Run with --all to include them.\n')
    opt_fail <- character(0)
  }

  cat('\n')
  if (length(req_fail) > 0) {
    cat('WARNING: Some required packages failed to install.\n')
    quit(status = 1)
  } else {
    cat('Done. Run `Rscript src/preflight.R` to verify full setup.\n')
    quit(status = 0)
  }
}
