# =============================================================================
# Diagnostic: how much information does the A->B parser drop?
# =============================================================================
# Purpose: quantify parser information loss across all revisions, so we can
# decide whether "correctness" (the A->B parse leak) is a fire or a smolder
# before committing the refactor order. Runs ONLY the parsers (03/04/05) +
# coverage tallies; does NOT run the calculator. Light enough for a small alloc.
#
# Metrics, per revision:
#   ch99 coverage     -- entries we recognized as Ch99 but could not fully
#                        resolve: authority=='other', country_type=='unknown',
#                        rate is NA (rate text unparsed).
#   product rates     -- base_rate NA / has_complex_rate (non-ad-valorem duties
#                        the parser can't represent).
#   dangling refs     -- THE key leak: products whose footnotes reference a
#                        9903.* program that never appears in parsed ch99_data
#                        (product is subject to a tariff program we failed to
#                        parse). all_dangling = none of a product's refs parsed.
#   annex pointers    -- ch99 entries whose description points at a U.S. note /
#                        annex / subdivision whose CONTENT we never structurally
#                        parse (proxy for "annex substance lives in CSVs").
#
# Optional import-weighting (if weights RDS loads): share of 2024 import VALUE
# on products with a complex rate or an all-dangling ref set -- tells us whether
# the leak is material to revenue, not just line-count.
#
# Output: output/diagnostics/parse_loss_by_revision.csv (+ printed summary).
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(jsonlite)
  library(here)
})

source(here('src', 'logging.R'))
source(here('src', 'helpers.R'))          # pulls policy_params, revisions, rate_schema, ...
source(here('src', '03_parse_chapter99.R'))
source(here('src', '04_parse_products.R'))
source(here('src', '05_parse_policy_params.R'))

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# ---- setup (mirrors build_full_timeseries) ----------------------------------
census_path  <- 'resources/census_codes.csv'
rev_dates    <- read_csv('config/revision_dates.csv',
                         col_types = cols(.default = col_character()))
archive_dir  <- 'data/hts_archives'

out_dir <- 'output/diagnostics'
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# ---- optional import weights, aggregated to hts10 total value ---------------
hts10_value <- NULL
weights_path <- 'data/weights/hs10_by_country_gtap_2024_con.rds'
if (file.exists(weights_path)) {
  tryCatch({
    w <- readRDS(weights_path)
    if (is.data.frame(w)) {
      hts_col <- intersect(c('hts10','hs10','HTS10','HS10'), names(w))[1]
      # pick the most plausible value column
      val_candidates <- names(w)[map_lgl(w, is.numeric)]
      val_col <- val_candidates[str_detect(tolower(val_candidates),
                                            'val|value|con|import|cif|customs')][1]
      val_col <- val_col %||% val_candidates[1]
      if (!is.na(hts_col) && !is.na(val_col)) {
        hts10_value <- w %>%
          transmute(hts10 = .data[[hts_col]], v = .data[[val_col]]) %>%
          group_by(hts10) %>% summarise(value = sum(v, na.rm = TRUE), .groups = 'drop')
        message('Loaded import weights: value col = "', val_col,
                '", ', nrow(hts10_value), ' hts10 lines, total = ',
                format(sum(hts10_value$value), big.mark = ','))
      } else message('Weights present but could not identify hts10/value cols; skipping weighting.')
    }
    rm(w); gc()
  }, error = function(e) message('Weight load failed (', conditionMessage(e), '); skipping weighting.'))
} else message('No weights file at ', weights_path, '; line-count metrics only.')

wshare <- function(prods, mask) {
  if (is.null(hts10_value)) return(NA_real_)
  j <- prods %>% select(hts10) %>% mutate(.m = mask) %>%
    left_join(hts10_value, by = 'hts10')
  tot <- sum(j$value, na.rm = TRUE)
  if (tot == 0) return(NA_real_)
  sum(j$value[j$.m], na.rm = TRUE) / tot
}

# ---- per-revision tally -----------------------------------------------------
rows <- list()
for (i in seq_len(nrow(rev_dates))) {
  rev_id <- rev_dates$revision[i]
  json_path <- tryCatch(resolve_json_path(rev_id, archive_dir), error = function(e) NA)
  if (is.na(json_path) || !file.exists(json_path)) {
    message('  [skip] ', rev_id, ' (no archive)'); next
  }
  message('Parsing ', rev_id, ' ...')

  ch99 <- parse_chapter99(json_path)
  prods <- parse_products(json_path)

  parsed_codes <- unique(ch99$ch99_code)
  prods <- prods %>%
    mutate(n_parsed = map_int(ch99_refs, ~ sum(.x %in% parsed_codes)),
           all_dangling = n_ch99_refs > 0 & n_parsed == 0)

  all_refs <- unlist(prods$ch99_refs)
  dangling_codes <- setdiff(unique(all_refs), parsed_codes)

  annex_re <- 'note|annex|subdivision'
  rows[[rev_id]] <- tibble(
    revision               = rev_id,
    eff_date               = rev_dates$effective_date[i],
    ch99_n                 = nrow(ch99),
    ch99_authority_other   = sum(ch99$authority == 'other', na.rm = TRUE),
    ch99_country_unknown   = sum(ch99$country_type == 'unknown', na.rm = TRUE),
    ch99_rate_na           = sum(is.na(ch99$rate)),
    ch99_annex_pointer      = sum(grepl(annex_re, ch99$description, ignore.case = TRUE)),
    prod_n                 = nrow(prods),
    prod_base_rate_na      = sum(is.na(prods$base_rate)),
    prod_complex_rate      = sum(prods$has_complex_rate, na.rm = TRUE),
    prod_with_refs         = sum(prods$n_ch99_refs > 0),
    prod_all_dangling      = sum(prods$all_dangling, na.rm = TRUE),
    n_dangling_codes       = length(dangling_codes),
    # import-weighted shares (NA if no weights)
    wshare_complex_rate    = wshare(prods, prods$has_complex_rate %in% TRUE),
    wshare_all_dangling    = wshare(prods, prods$all_dangling %in% TRUE)
  )

  # stash the dangling code lists per revision for inspection
  attr(rows[[rev_id]], 'dangling_codes') <- dangling_codes
}

res <- bind_rows(rows)

# derived rate columns
res <- res %>%
  mutate(pct_ch99_other     = ch99_authority_other / ch99_n,
         pct_ch99_unknown   = ch99_country_unknown / ch99_n,
         pct_prod_dangling  = prod_all_dangling / pmax(prod_with_refs, 1))

write_csv(res, file.path(out_dir, 'parse_loss_by_revision.csv'))

# union of dangling codes across all revisions (what programs we keep missing)
all_dangling <- sort(unique(unlist(lapply(rows, function(r) attr(r, 'dangling_codes')))))
writeLines(all_dangling, file.path(out_dir, 'dangling_ch99_codes.txt'))

# ---- summary ----------------------------------------------------------------
cat('\n================= PARSE-LOSS SUMMARY =================\n')
cat('Revisions parsed:', nrow(res), '\n\n')

latest <- tail(res, 1)
cat('--- LATEST revision (', latest$revision, ') ---\n', sep = '')
cat(sprintf('  Ch99 entries: %d | authority=other: %d (%.1f%%) | country=unknown: %d (%.1f%%) | rate NA: %d\n',
            latest$ch99_n, latest$ch99_authority_other, 100*latest$pct_ch99_other,
            latest$ch99_country_unknown, 100*latest$pct_ch99_unknown, latest$ch99_rate_na))
cat(sprintf('  Ch99 annex/note pointers: %d (description references content we do not structurally parse)\n',
            latest$ch99_annex_pointer))
cat(sprintf('  Products: %d | complex(non-ad-val) rate: %d | base_rate NA: %d\n',
            latest$prod_n, latest$prod_complex_rate, latest$prod_base_rate_na))
cat(sprintf('  Products with Ch99 refs: %d | ALL refs dangling (subject to an UNPARSED program): %d (%.1f%% of ref-bearing)\n',
            latest$prod_with_refs, latest$prod_all_dangling, 100*latest$pct_prod_dangling))
cat(sprintf('  Distinct dangling Ch99 codes: %d\n', latest$n_dangling_codes))
if (!is.null(hts10_value)) {
  cat(sprintf('  IMPORT-WEIGHTED -> complex-rate value share: %.2f%% | all-dangling value share: %.2f%%\n',
              100*latest$wshare_complex_rate, 100*latest$wshare_all_dangling))
}

cat('\n--- WORST revision per metric ---\n')
show <- function(col, label) {
  k <- which.max(res[[col]]); r <- res[k, ]
  cat(sprintf('  %-22s max=%s at %s\n', label, format(r[[col]]), r$revision))
}
show('prod_all_dangling',   'products all-dangling')
show('ch99_authority_other','ch99 authority=other')
show('ch99_country_unknown','ch99 country=unknown')
show('prod_complex_rate',   'products complex-rate')

cat('\nUnion of dangling Ch99 codes across all revisions:', length(all_dangling), '\n')
cat('  (full list -> output/diagnostics/dangling_ch99_codes.txt)\n')
cat('  first 40:', paste(head(all_dangling, 40), collapse = ', '), '\n')

cat('\nWrote: output/diagnostics/parse_loss_by_revision.csv\n')
cat('=====================================================\n')
