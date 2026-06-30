# =============================================================================
# build_config.R — the single build-run config (Phase: build output reform)
# =============================================================================
# A build run takes ONE config file as its sole user input. It names the output
# interface, the staging scratch, the policy-params file, the scenarios to build,
# and a few flags. Everything the build needs is resolved from here; the TARIFF_*
# and REVLIST env vars become INTERNAL plumbing the orchestrator sets from this.
#
# A run produces ONE timestamped vintage under model_data_root containing the
# `actual` series plus a subfolder for every listed scenario:
#   <model_data_root>/<vintage>/{actual, scenarios/<name>}/...
# Nothing is written into the repository working tree.
#
# Schema (all keys optional except `scenarios` may be empty):
#   model_data_root:    output interface root (else config/local_paths.yaml)
#   policy_params_path: baseline policy params  (default config/policy_params.yaml)
#   scenarios:          [names] — config/scenarios/<name>/; `actual` is ALWAYS built
#   use_hts_dates:      bool (default false → policy dates)
#   weight_mode:        'required' | 'unweighted' (default 'required')
#   update_latest:      bool (default true → repoint <root>/latest)
#   allow_partial:      bool (default false → fail on a missing revision snapshot)
#   verify:             bool (default true → finalize runs scripts/verify_build.R
#                       against the vintage and repoints `latest` only on pass)
# =============================================================================

suppressPackageStartupMessages(library(yaml))

#' Read model_data_root from config/local_paths.yaml WITHOUT sourcing the heavy
#' policy-params stack (keeps this loader dependency-light for the bash bridge).
.local_model_data_root <- function(repo_root) {
  lp <- file.path(repo_root, 'config', 'local_paths.yaml')
  default <- '/nfs/roberts/project/pi_nrs36/shared/model_data/Tariff-Rate-Tracker'
  if (!file.exists(lp)) return(default)
  raw <- tryCatch(yaml::read_yaml(lp), error = function(e) list())
  if (!is.null(raw$model_data_root) && nzchar(raw$model_data_root)) raw$model_data_root else default
}

#' Load + resolve a build-run config. Returns a list with every field defaulted
#' and `scenarios` as a character vector (never including 'actual').
load_build_config <- function(path, repo_root = here()) {
  if (!file.exists(path)) stop('build config not found: ', path, call. = FALSE)
  cfg <- yaml::read_yaml(path)

  mdr <- if (!is.null(cfg$model_data_root) && nzchar(cfg$model_data_root)) {
    cfg$model_data_root
  } else .local_model_data_root(repo_root)

  scen <- as.character(cfg$scenarios %||% character(0))
  scen <- setdiff(scen, 'actual')   # actual is implicit, always built

  wm <- cfg$weight_mode %||% 'required'
  if (!wm %in% c('required', 'unweighted')) {
    stop("build config weight_mode must be 'required' or 'unweighted', got: ", wm, call. = FALSE)
  }

  list(
    model_data_root    = mdr,
    policy_params_path = cfg$policy_params_path %||% file.path('config', 'policy_params.yaml'),
    scenarios          = scen,
    use_hts_dates      = isTRUE(cfg$use_hts_dates),
    weight_mode        = wm,
    update_latest      = if (is.null(cfg$update_latest)) TRUE else isTRUE(cfg$update_latest),
    allow_partial      = isTRUE(cfg$allow_partial),
    verify             = if (is.null(cfg$verify)) TRUE else isTRUE(cfg$verify)
  )
}

# Local %||% so this file can be sourced standalone (no rlang dependency).
if (!exists('%||%')) `%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
