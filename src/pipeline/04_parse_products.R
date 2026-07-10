# =============================================================================
# Step 04: Parse Product Data from HTS JSON
# =============================================================================
#
# Extracts HTS10 product data:
#   - Base MFN rate (from 'general' field)
#   - Chapter 99 footnote references
#
# Output: products_{revision}.rds with columns:
#   - hts10: 10-digit HTS code
#   - description: Product description
#   - base_rate: MFN rate (numeric)
#   - base_rate_raw: Original rate text
#   - ch99_refs: List of Chapter 99 references from footnotes
#   - has_complex_rate: Flag for non-ad-valorem rates
#   - base_rate_type: Rate-type bucket (ad_valorem/free/specific_or_compound/
#     other) — an EXPOSURE FLAG, not a conversion (scope decision 2026-06-10).
#     Carried via a parallel type_stack (see below); makes visible which cells
#     the numeric base_rate silently treats as 0 (specific/compound duties).
#
# =============================================================================

library(tidyverse)
library(jsonlite)

# NOTE: parse_rate(), is_simple_rate(), normalize_hts(), is_valid_hts10(),
# and extract_chapter99_refs() are all defined in helpers.R.
# This file uses those shared versions.


# =============================================================================
# Main Parsing Function
# =============================================================================

#' Parse all products from HTS JSON
#'
#' @param json_path Path to HTS JSON file
#' @return Tibble with product data
parse_products <- function(json_path) {
  message('Reading HTS JSON from: ', json_path)

  # Read JSON
  hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)
  message('  Total items: ', length(hts_raw))

  # Build a rate inheritance stack: for statistical suffixes (empty general field),
  # inherit the MFN rate from the nearest parent in the indent hierarchy.
  # ~59% of HTS10 products are statistical suffixes with empty general fields.
  #
  # Known edge case (rare): this assumes the JSON preserves parent-before-child
  # order and that indent levels increase monotonically within a heading. If
  # USITC changes the JSON structure (e.g., reorders items or introduces
  # non-standard indent jumps), inherited rates could be wrong. No validation
  # pass currently checks for these anomalies.
  rate_stack <- list()  # indent level -> parsed rate (numeric or NA)
  n_inherited <- 0L

  # Parallel type stack for base_rate_type (exposure flag). Deliberately does
  # NOT reuse rate_stack: rate_stack only pushes when a rate PARSES (simple/
  # free), so a specific/compound parent — whose rate is NA — never pushes and
  # never clears deeper levels, and a suffix can then inherit a STALE numeric
  # from a prior sibling subtree (the known, parity-gated stale-sibling bug,
  # todo.md). type_stack instead resets on ANY legal line (non-empty general),
  # mirroring the more-robust special_stack in extract_usmca_eligibility(), so
  # base_rate_type reflects the TRUE nearest legal parent. Where the two stacks
  # disagree (base_rate_type == 'specific_or_compound' but base_rate is a
  # non-NA inherited number) is exactly where that bug bites — the flag surfaces
  # it without changing any rate number.
  type_stack <- list()  # indent level -> base_rate_type of nearest legal line

  # Process each item
  products <- map_dfr(hts_raw, function(item) {
    htsno <- item$htsno %||% ''
    general <- item$general %||% ''
    indent <- as.integer(item$indent %||% 0)

    # Update rate stack for any item with a rate (parents and products alike)
    parsed <- parse_rate(general)
    if (!is.na(parsed) || (is_simple_rate(general) || tolower(trimws(general)) == 'free')) {
      rate_stack[[as.character(indent)]] <<- parsed
      # Clear deeper indent levels (new parent resets children)
      deeper <- names(rate_stack)[as.integer(names(rate_stack)) > indent]
      for (d in deeper) rate_stack[[d]] <<- NULL
    }

    # Update type stack on ANY legal line (non-empty general), including
    # specific/compound parents that rate_stack skips — see the note above.
    if (trimws(general) != '') {
      type_stack[[as.character(indent)]] <<- classify_rate_type(general)
      deeper_t <- names(type_stack)[as.integer(names(type_stack)) > indent]
      for (d in deeper_t) type_stack[[d]] <<- NULL
    }

    # Keep 10-digit codes and 8-digit candidates. Some tariff lines are leaves
    # at 8 digits (no statistical suffix) — e.g., most of ch91 watches and ch98
    # special provisions (473 lines in 2026_rev_2). Census reports these as
    # HTS10 with a "00" suffix. Non-leaf 8-digit rows (those with 10-digit
    # statistical children) are dropped in the post-pass below.
    clean_code <- gsub('\\.', '', htsno)
    code_digits <- nchar(clean_code)
    is_8digit_line <- code_digits == 8 && grepl('^[0-9]+$', clean_code)
    if (!is_valid_hts10(htsno) && !is_8digit_line) {
      return(NULL)
    }

    # Skip Chapter 99 entries (they're not products)
    if (grepl('^99', htsno)) {
      return(NULL)
    }

    hts10 <- normalize_hts(htsno)  # pads 8-digit codes to 10 with "00"
    description <- item$description %||% ''

    # Parse rate — inherit from parent if empty
    base_rate <- parse_rate(general)
    has_complex <- !is_simple_rate(general) && general != ''

    # Classify rate type for this line (NA when general is empty/whitespace).
    base_rate_type <- classify_rate_type(general)

    if (is.na(base_rate) && trimws(general) == '' && indent > 0) {
      # Statistical suffix: inherit from nearest parent
      for (i in seq(indent - 1, 0, by = -1)) {
        parent_rate <- rate_stack[[as.character(i)]]
        if (!is.null(parent_rate)) {
          base_rate <- parent_rate
          n_inherited <<- n_inherited + 1L
          break
        }
      }
    }

    # Inherit base_rate_type from the nearest legal parent for suffixes with an
    # empty general (parallel to base_rate, but off the robust type_stack).
    if (is.na(base_rate_type) && trimws(general) == '' && indent > 0) {
      for (i in seq(indent - 1, 0, by = -1)) {
        parent_type <- type_stack[[as.character(i)]]
        if (!is.null(parent_type)) {
          base_rate_type <- parent_type
          break
        }
      }
    }

    # Extract Chapter 99 references
    ch99_refs <- extract_chapter99_refs(item$footnotes)

    tibble(
      hts10 = hts10,
      description = description,
      base_rate = base_rate,
      base_rate_raw = general,
      base_rate_type = base_rate_type,
      ch99_refs = list(ch99_refs),
      has_complex_rate = has_complex,
      n_ch99_refs = length(ch99_refs),
      is_8digit_line = is_8digit_line
    )
  })

  # Post-pass: keep 8-digit lines only when they are LEAVES (no 10-digit
  # statistical children in this revision). An 8-digit parent with children
  # is a grouping row, not a product; an 8-digit leaf IS the tariff line.
  ten_digit_prefixes <- unique(substr(products$hts10[!products$is_8digit_line], 1, 8))
  drop_8digit_parent <- products$is_8digit_line &
    substr(products$hts10, 1, 8) %in% ten_digit_prefixes
  n_8digit_leaves <- sum(products$is_8digit_line & !drop_8digit_parent)
  products <- products %>%
    filter(!drop_8digit_parent) %>%
    select(-is_8digit_line)

  message('  Parsed products: ', nrow(products))
  message('  8-digit leaf lines retained (padded to 10): ', n_8digit_leaves)
  message('  With Chapter 99 refs: ', sum(products$n_ch99_refs > 0))
  message('  With complex rates: ', sum(products$has_complex_rate))
  message('  Specific/compound (exposure flag): ',
          sum(products$base_rate_type == 'specific_or_compound', na.rm = TRUE))
  # Diagnostic for the parity-gated stale-sibling bug: cells the robust
  # type_stack marks specific/compound but whose base_rate inherited a non-NA
  # number off rate_stack (a stale sibling rate). Zero today would be ideal.
  n_stale_sibling <- sum(products$base_rate_type == 'specific_or_compound' &
                           !is.na(products$base_rate), na.rm = TRUE)
  message('  Stale-sibling suspects (spec/compound w/ non-NA base_rate): ',
          n_stale_sibling)
  message('  Inherited parent rate: ', n_inherited, ' (',
          round(n_inherited / nrow(products) * 100, 1), '%)')
  message('  With NA base_rate: ', sum(is.na(products$base_rate)))

  return(products)
}


#' Parse products from multiple HTS revisions
#'
#' @param revisions Vector of revision identifiers (e.g., c('basic', 'rev_1', 'rev_32'))
#' @param archive_dir Directory containing HTS JSON files
#' @return Named list of product tibbles
parse_all_revisions <- function(revisions, archive_dir = 'data/hts_archives') {
  results <- list()

  for (rev in revisions) {
    # resolve_json_path prefers the committed .json.gz, falling back to raw .json
    filepath <- tryCatch(resolve_json_path(rev, archive_dir),
                         error = function(e) NA_character_)
    if (is.na(filepath)) {
      warning('File not found for revision: ', rev)
      next
    }

    message('\n=== Processing ', rev, ' ===')
    products <- parse_products(filepath)
    results[[rev]] <- products
  }

  return(results)
}


#' Compare products between two revisions
#'
#' @param old_products Products from older revision
#' @param new_products Products from newer revision
#' @return List with changes
compare_products <- function(old_products, new_products) {
  old_hts <- old_products$hts10

  new_hts <- new_products$hts10

  added_hts <- setdiff(new_hts, old_hts)
  removed_hts <- setdiff(old_hts, new_hts)

  # Check for Chapter 99 ref changes
  common <- intersect(old_hts, new_hts)

  old_refs <- old_products %>%
    filter(hts10 %in% common) %>%
    select(hts10, old_refs = ch99_refs, old_n = n_ch99_refs)

  new_refs <- new_products %>%
    filter(hts10 %in% common) %>%
    select(hts10, new_refs = ch99_refs, new_n = n_ch99_refs)

  ref_changes <- old_refs %>%
    inner_join(new_refs, by = 'hts10') %>%
    filter(old_n != new_n | map2_lgl(old_refs, new_refs, ~!setequal(.x, .y)))

  list(
    added = new_products %>% filter(hts10 %in% added_hts),
    removed = old_products %>% filter(hts10 %in% removed_hts),
    ref_changes = ref_changes,
    n_added = length(added_hts),
    n_removed = length(removed_hts),
    n_ref_changes = nrow(ref_changes)
  )
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)
  source(here('src', 'core', 'helpers.R'))

  # Parse baseline and latest revision
  products_basic <- parse_products('data/hts_archives/hts_2025_basic.json')
  products_rev32 <- parse_products('data/hts_archives/hts_2025_rev_32.json')

  # Compare
  cat('\n=== Changes from Basic to Rev 32 ===\n')
  changes <- compare_products(products_basic, products_rev32)
  cat('Added products:', changes$n_added, '\n')
  cat('Removed products:', changes$n_removed, '\n')
  cat('Chapter 99 ref changes:', changes$n_ref_changes, '\n')

  if (changes$n_ref_changes > 0) {
    cat('\nSample Chapter 99 reference changes:\n')
    print(head(changes$ref_changes %>% select(hts10, old_n, new_n), 20))
  }

  # Save
  ensure_dir('data/processed')
  saveRDS(products_basic, 'data/processed/products_basic.rds')
  saveRDS(products_rev32, 'data/processed/products_rev32.rds')
  message('\nSaved product data')

  # Summary stats
  cat('\n=== Summary ===\n')
  cat('Basic edition: ', nrow(products_basic), ' products, ',
      sum(products_basic$n_ch99_refs > 0), ' with Ch99 refs\n', sep = '')
  cat('Rev 32: ', nrow(products_rev32), ' products, ',
      sum(products_rev32$n_ch99_refs > 0), ' with Ch99 refs\n', sep = '')
}
