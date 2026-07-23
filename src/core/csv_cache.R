# =============================================================================
# Static CSV cache
# =============================================================================
# Small standalone dependency for model modules that repeatedly read committed
# reference tables. Keeping it outside helpers.R makes those modules sourceable
# and testable without relying on the helpers facade's source order.

.static_csv_cache <- new.env(parent = emptyenv())

#' Read a static reference CSV once per R process.
#'
#' The cache is keyed by normalized path. Callers must use equivalent col_types
#' for repeated reads of the same file and treat the returned frame as read-only.
#'
#' @param path Existing CSV path.
#' @param ... Passed to readr::read_csv() on a cache miss.
#' @return Parsed data frame.
read_csv_cached <- function(path, ...) {
  key <- normalizePath(path, mustWork = FALSE)
  cached <- .static_csv_cache[[key]]
  if (!is.null(cached)) return(cached)
  df <- readr::read_csv(path, ...)
  .static_csv_cache[[key]] <- df
  df
}
