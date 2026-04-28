# =============================================================================
# Step 05: Parse Policy Parameters from HTS JSON
# =============================================================================
#
# Extracts tariff policy parameters directly from the HTS source data:
#   1. IEEPA country-specific reciprocal rates (from 9903.01.43-75 and 9903.02.xx)
#   2. USMCA eligibility per product (from the 'special' field)
#
# Output:
#   - data/processed/ieepa_country_rates.csv: Country-rate pairs by phase
#   - data/processed/usmca_products.csv: HTS10 x USMCA eligibility
#
# =============================================================================

library(tidyverse)
library(jsonlite)

# =============================================================================
# Constants (loaded from YAML)
# =============================================================================

# Country code constants — centralized in helpers.R, loaded from YAML with fallback
.cc <- get_country_constants()
EU27_CODES   <- .cc$EU27_CODES
EU27_NAMES   <- .cc$EU27_NAMES
ISO_TO_CENSUS <- .cc$ISO_TO_CENSUS

# =============================================================================
# Country Name Matching
# =============================================================================

#' Build a mapping from country names (as used in HTS descriptions) to Census codes
#'
#' Augments the census_codes.csv with common aliases used in HTS text.
#'
#' @param census_path Path to census_codes.csv
#' @return Named vector: name (lowercase) -> Census code
build_country_lookup <- function(census_path) {
  census <- read_csv(census_path, col_types = cols(.default = col_character()))

  # Start with official names (lowercase)
  lookup <- setNames(census$Code, tolower(census$Name))

  # Add common aliases used in HTS descriptions
  aliases <- c(
    'south korea' = '5800', 'korea' = '5800', 'republic of korea' = '5800',
    'north korea' = '5790', 'democratic people\'s republic of korea' = '5790',
    'russia' = '4621', 'russian federation' = '4621',
    'uk' = '4120', 'great britain' = '4120', 'united kingdom' = '4120',
    'uae' = '5200', 'united arab emirates' = '5200',
    'dr congo' = '7660', 'democratic republic of the congo' = '7660',
    'congo (brazzaville)' = '7630', 'republic of the congo' = '7630',
    "cote d'ivoire" = '7480', "c\u00f4te d'ivoire" = '7480', 'ivory coast' = '7480',
    'burma' = '5460', 'myanmar' = '5460',
    'laos' = '5530',
    'taiwan' = '5830',
    'vietnam' = '5520', 'viet nam' = '5520',
    'hong kong' = '5820', 'macau' = '5660', 'macao' = '5660',
    'brunei' = '5610',
    'east timor' = '5601', 'timor-leste' = '5601',
    'eswatini' = '7990', 'swaziland' = '7990',
    'cabo verde' = '7210', 'cape verde' = '7210',
    'gambia' = '7420',
    'bosnia' = '4793', 'bosnia and herzegovina' = '4793',
    'trinidad' = '2740', 'trinidad and tobago' = '2740',
    'antigua' = '2484', 'antigua and barbuda' = '2484',
    'saint kitts' = '2483', 'st. kitts' = '2483', 'saint kitts and nevis' = '2483',
    'saint lucia' = '2487', 'st. lucia' = '2487',
    'saint vincent' = '2488', 'st. vincent' = '2488',
    'equatorial guinea' = '7450',
    'papua new guinea' = '6040',
    'philippines' = '5650',
    'north macedonia' = '4794'
  )

  lookup <- c(lookup, aliases)
  return(lookup)
}


#' Extract country names from an HTS Ch99 description
#'
#' Parses descriptions like:
#'   "...articles the product of South Korea, as provided for..."
#'   "...articles the product of Algeria, Nauru, or South Africa, as provided for..."
#'   "...article the product of the European Union with an ad valorem..."
#'
#' @param description Full description text
#' @return Character vector of country names (as found in text)
extract_countries_from_description <- function(description) {
  if (is.na(description) || description == '') return(character(0))

  countries_text <- NULL

  # Pattern 1: "product of [COUNTRIES], as provided"
  match1 <- str_match(
    description,
    regex('product of\\s+(.+?)\\s*,\\s*as provided', ignore_case = TRUE)
  )

  if (!is.na(match1[1, 1])) {
    candidate <- match1[1, 2]
    # If text contains qualifiers, extract country name before the qualifier
    if (grepl('with an ad valorem|rate of duty|column 1|that are', candidate, ignore.case = TRUE)) {
      qual_match <- str_match(
        candidate,
        regex('^(.+?)\\s+(?:with|that|where|except)', ignore_case = TRUE)
      )
      if (!is.na(qual_match[1, 1])) {
        countries_text <- qual_match[1, 2]
      }
    } else {
      countries_text <- candidate
    }
  }

  # Pattern 2: "product of [COUNTRY] that are|with|where|as specified" (no "as provided")
  if (is.null(countries_text)) {
    match2 <- str_match(
      description,
      regex('product[s]? of\\s+(.+?)\\s+(?:that are|with an|where|except|as specified|as provided|enumerated)',
            ignore_case = TRUE)
    )
    if (!is.na(match2[1, 1])) {
      countries_text <- match2[1, 2]
    }
  }

  if (is.null(countries_text)) return(character(0))

  # Handle "including X and Y" → extract X, Y
  countries_text <- gsub('including\\s+', '', countries_text)

  # Protect compound country names before splitting on "and"
  compound_subs <- c(
    'Bosnia and Herzegovina' = 'Bosnia_AND_Herzegovina',
    'Trinidad and Tobago' = 'Trinidad_AND_Tobago',
    'Antigua and Barbuda' = 'Antigua_AND_Barbuda',
    'Saint Kitts and Nevis' = 'Saint_Kitts_AND_Nevis',
    'Saint Vincent and the Grenadines' = 'Saint_Vincent_AND_the_Grenadines',
    'Sao Tome and Principe' = 'Sao_Tome_AND_Principe'
  )
  for (i in seq_along(compound_subs)) {
    countries_text <- gsub(names(compound_subs)[i], compound_subs[i],
                           countries_text, ignore.case = TRUE)
  }

  # Split on ", " or " or " or ", or " or " and "
  parts <- str_split(countries_text, '\\s*,\\s*(?:or\\s+)?|\\s+or\\s+|\\s+and\\s+')[[1]]

  # Restore compound names
  parts <- gsub('_AND_', ' and ', parts)
  parts <- gsub('_and_', ' and ', parts)

  parts <- trimws(parts)
  parts <- parts[parts != '' & !grepl('^except', parts, ignore.case = TRUE)]

  # Strip leading "the " from country names
  parts <- gsub('^the\\s+', '', parts)

  # Handle parenthetical aliases: "Myanmar (Burma)" → "Myanmar"
  parts <- gsub('\\s*\\([^)]+\\)', '', parts)

  # Normalize special characters
  parts <- gsub('\u2018|\u2019|`', "'", parts)  # smart quotes to apostrophe

  # Filter out catch-all entries and member-country references
  parts <- parts[!grepl('^any country|^member countries', parts, ignore.case = TRUE)]

  return(parts)
}


#' Match country names to Census codes
#'
#' @param country_names Vector of country names from HTS text
#' @param lookup Named vector from build_country_lookup()
#' @return Tibble with name and census_code columns
match_countries <- function(country_names, lookup) {
  tibble(
    country_name = country_names,
    census_code = map_chr(country_names, function(name) {
      code <- lookup[tolower(name)]
      if (is.na(code)) {
        # Try partial matching
        matches <- names(lookup)[str_detect(names(lookup), fixed(tolower(name)))]
        if (length(matches) > 0) {
          code <- lookup[matches[1]]
        }
      }
      as.character(code)
    })
  )
}


# =============================================================================
# IEEPA Reciprocal Rate Extraction
# =============================================================================

#' Extract IEEPA country-specific rates from HTS JSON
#'
#' Parses 9903.01.43-75 (Phase 1, April 9 "Liberation Day" rates)
#' and 9903.02.02-81 (Phase 2, August 7 reinstated rates).
#'
#' Rate types:
#'   - "surcharge": "+X%" additional duty on top of base rate (most countries)
#'   - "floor": "X%" flat rate that replaces base rate when base < X (EU, Japan, S. Korea)
#'   - "passthrough": base rate only, no additional duty (high-duty goods for floor countries)
#'
#' @param hts_raw Parsed HTS JSON (list)
#' @param country_lookup Named vector from build_country_lookup()
#' @return Tibble with ch99_code, rate, rate_type, phase, country_name, census_code
extract_ieepa_rates <- function(hts_raw, country_lookup) {
  message('Extracting IEEPA country-specific rates...')

  # Filter to IEEPA entries
  ieepa_items <- Filter(function(x) {
    htsno <- x$htsno %||% ''
    # Phase 1: 9903.01.43-75 (Liberation Day)
    # Country-specific EOs: 9903.01.76-89 (Brazil EO 14323, India, etc.)
    # Phase 2: 9903.02.02-81 (August 7 reinstatement)
    # Swiss/Liechtenstein framework: 9903.02.82-91 (EO 14346, 15% floor)
    grepl('^9903\\.01\\.(4[3-9]|[5-8][0-9])$', htsno) ||
      grepl('^9903\\.02\\.(0[2-9]|[1-8][0-9]|9[01])$', htsno)
  }, hts_raw)

  message('  IEEPA tier entries found: ', length(ieepa_items))

  # Early return if no IEEPA entries (e.g., basic revision)
  if (length(ieepa_items) == 0) {
    message('  No IEEPA entries — returning empty tibble')
    return(tibble(
      ch99_code = character(), rate = numeric(), rate_type = character(),
      phase = character(), terminated = logical(),
      country_name = character(), census_code = character()
    ))
  }

  # Parse each entry
  results <- map_dfr(ieepa_items, function(item) {
    ch99_code <- item$htsno %||% NA_character_
    general <- item$general %||% ''
    description <- item$description %||% ''

    # Parse rate and rate_type
    # "+X%" = surcharge (additional duty)
    # "X%" without "+" = floor (total duty replaces base if base < X)
    # "The duty provided..." or "Free" = passthrough (no additional duty)
    surcharge_match <- str_match(general, '\\+\\s*([0-9.]+)%')
    floor_match <- str_match(general, '^\\s*([0-9.]+)%\\s*$')

    if (!is.na(surcharge_match[1, 2])) {
      rate <- as.numeric(surcharge_match[1, 2]) / 100
      rate_type <- 'surcharge'
    } else if (!is.na(floor_match[1, 2])) {
      rate <- as.numeric(floor_match[1, 2]) / 100
      rate_type <- 'floor'
    } else {
      rate <- NA_real_
      rate_type <- if (grepl('duty provided|Free', general, ignore.case = TRUE)) {
        'passthrough'
      } else {
        NA_character_
      }
    }

    # Check if terminated/suspended.
    # Normalize whitespace and encoding artifacts before matching to handle
    # non-breaking spaces, smart quotes, and other USITC PDF rendering issues.
    desc_normalized <- gsub('[\\s\\x{00A0}]+', ' ', description, perl = TRUE)
    terminated <- grepl('provision terminated|provision suspended|temporarily suspended',
                        desc_normalized, ignore.case = TRUE)

    # Secondary check: compiler's note format (various punctuation/encoding)
    if (!terminated) {
      terminated <- grepl('\\[Compiler.*suspend', desc_normalized, ignore.case = TRUE)
    }

    # Tertiary check: rate set to "Free" or "$0" (indicates effective suspension)
    if (!terminated && !is.na(rate) && rate == 0) {
      terminated <- grepl('free|\\$0', general, ignore.case = TRUE)
    }

    # Determine phase
    # 9903.01.43-75: Phase 1 (Liberation Day, Apr 9)
    # 9903.01.76-89: Country-specific EOs (e.g., Brazil EO 14323, India) — stack with Phase 2
    # 9903.02.xx: Phase 2 (Aug 7 reinstatement)
    is_country_eo <- grepl('^9903\\.01\\.(7[6-9]|8[0-9])$', ch99_code) & !terminated
    phase <- if (grepl('^9903\\.02\\.', ch99_code)) {
      'phase2_aug7'
    } else if (is_country_eo) {
      'country_eo'
    } else {
      'phase1_apr9'
    }

    # Diagnostic: log China entry's suspension status.
    # 9903.01.63 was suspended starting at rev_17 (Geneva de-escalation).
    # If the entry exists but is not detected as suspended, warn loudly —
    # this likely means the text matching needs updating for a new format.
    if (ch99_code == '9903.01.63') {
      message('  [Diagnostic] 9903.01.63 (China): terminated=', terminated,
              ', description tail: "...', substr(description, max(1, nchar(description) - 60), nchar(description)), '"')
      if (!terminated && !is.na(rate) && rate > 0) {
        warning('9903.01.63 (China +34% reciprocal) has rate=', rate,
                ' but suspension NOT detected — check footnote text for new suspension language.',
                '\nDescription: ', substr(description, 1, 200))
      }
    }

    # Extract countries
    country_names <- extract_countries_from_description(description)

    if (length(country_names) == 0) {
      return(tibble(
        ch99_code = ch99_code, rate = rate, rate_type = rate_type,
        phase = phase, terminated = terminated,
        country_name = NA_character_, census_code = NA_character_
      ))
    }

    # Match to census codes
    matched <- match_countries(country_names, country_lookup)

    tibble(
      ch99_code = ch99_code,
      rate = rate,
      rate_type = rate_type,
      phase = phase,
      terminated = terminated,
      country_name = matched$country_name,
      census_code = matched$census_code
    )
  })

  # Drop rows with no country extracted (catch-all entries, unparseable descriptions)
  n_no_country <- sum(is.na(results$country_name))
  if (n_no_country > 0) {
    message('  Dropping ', n_no_country, ' entries with no country extracted')
    results <- results %>% filter(!is.na(country_name))
  }

  # Expand "European Union" entries into 27 individual country rows
  eu_rows <- results %>% filter(tolower(country_name) == 'european union')
  if (nrow(eu_rows) > 0) {
    message('  Expanding ', nrow(eu_rows), ' EU entries to 27 member states each...')
    eu_expanded <- eu_rows %>%
      select(-country_name, -census_code) %>%
      crossing(tibble(census_code = EU27_CODES)) %>%
      mutate(country_name = EU27_NAMES[census_code])

    results <- results %>%
      filter(tolower(country_name) != 'european union') %>%
      bind_rows(eu_expanded)
  }

  message('  Country-rate pairs extracted: ', nrow(results))
  message('  Phase 1 (Apr 9, terminated): ', sum(results$phase == 'phase1_apr9'))
  message('  Phase 2 (Aug 7, active): ', sum(results$phase == 'phase2_aug7'))

  # Report rate types
  message('  Rate types (Phase 2): ',
          paste(results %>% filter(phase == 'phase2_aug7') %>%
                  count(rate_type) %>%
                  mutate(label = paste0(rate_type, '=', n)) %>%
                  pull(label), collapse = ', '))

  unmatched <- results %>% filter(is.na(census_code)) %>% pull(country_name) %>% unique()
  if (length(unmatched) > 0) {
    message('  Unmatched countries: ', length(unmatched))
    message('  Unmatched names: ', paste(unmatched, collapse = ', '))
  }

  # ---- Detect universal IEEPA baseline (9903.01.25) ----
  # During the 90-day pause (Apr 9 – Jul 8, 2025), the country-specific
  # rates from 9903.01.43-76 were suspended. Only the universal 10% baseline
  # (9903.01.25) remained in effect for non-China countries. The HTS JSON
  # retains the suspended entries at their original rates, so we detect the
  # baseline and cap Phase 1 rates accordingly.
  #
  # 9903.01.63 (China/HK/Macau): In early revisions, was NOT paused — its
  # rate was modified (125% → 34%) rather than suspended, so it's exempt
  # from capping. Post-Geneva (rev_17+), 9903.01.63 is marked as suspended
  # in the HTS JSON ("[Compiler's note: provision suspended.]"). When
  # suspended, China falls back to the universal baseline (10%).
  baseline_item <- Filter(function(x) {
    (x$htsno %||% '') == '9903.01.25'
  }, hts_raw)

  universal_baseline <- NULL
  if (length(baseline_item) > 0) {
    bl_general <- baseline_item[[1]]$general %||% ''
    bl_match <- str_match(bl_general, '\\+\\s*([0-9.]+)%')
    if (!is.na(bl_match[1, 2])) {
      universal_baseline <- as.numeric(bl_match[1, 2]) / 100
      message('  Universal IEEPA baseline (9903.01.25): ',
              round(universal_baseline * 100), '%')

      # Cap Phase 1 country-specific entries at baseline, except China entry
      # 9903.01.63 is China/HK/Macau — exempt from the 90-day pause UNLESS
      # it has been suspended (post-Geneva trade deal, May 2025). When
      # suspended, China falls back to the universal baseline like everyone else.
      china_entry <- '9903.01.63'
      china_suspended <- any(
        results$ch99_code == china_entry & results$terminated
      )
      phase1_cappable <- results$phase == 'phase1_apr9' &
        (results$ch99_code != china_entry | china_suspended) &
        !is.na(results$rate) &
        results$rate > universal_baseline

      n_capped <- sum(phase1_cappable)
      if (n_capped > 0) {
        results$rate[phase1_cappable] <- universal_baseline
        message('  Capped ', n_capped, ' Phase 1 entries to baseline ',
                round(universal_baseline * 100), '%')
      }
    }
  }

  attr(results, 'universal_baseline') <- universal_baseline
  return(results)
}


# =============================================================================
# IEEPA Fentanyl/Initial Rate Extraction
# =============================================================================

#' Extract IEEPA fentanyl/initial country-specific rates from HTS JSON
#'
#' Parses 9903.01.01-24: Initial IEEPA tariffs (fentanyl + early reciprocal).
#' These STACK on top of the reciprocal tariffs from 9903.01.25+/9903.02.xx.
#'
#' Key entries:
#'   - 9903.01.01: Mexico (+25%, fentanyl IEEPA)
#'   - 9903.01.10: Canada (+35%, fentanyl + initial reciprocal)
#'   - 9903.01.20: China/HK (+10%, initial IEEPA)
#'   - 9903.01.24: China/HK (+10%, additional provision)
#'
#' Rate types are all surcharges ("+X%").
#' Exclusion entries (9903.01.02-09, 11-15, 21-23) have no additional rate.
#'
#' @param hts_raw Parsed HTS JSON (list)
#' @param country_lookup Named vector from build_country_lookup()
#' @return Tibble with ch99_code, rate, country_name, census_code, entry_type.
#'   entry_type is 'general' for the blanket rate per country (applies to most
#'   products), or 'carveout' for product-specific lower/higher rates (e.g.,
#'   energy/minerals, potash). The general entry is identified by "Except for
#'   products described in" language in the description.
extract_ieepa_fentanyl_rates <- function(hts_raw, country_lookup) {
  message('Extracting IEEPA fentanyl/initial rates...')

  # Filter to 9903.01.01 through 9903.01.24
  fent_items <- Filter(function(x) {
    htsno <- x$htsno %||% ''
    grepl('^9903\\.01\\.(0[1-9]|1[0-9]|2[0-4])$', htsno)
  }, hts_raw)

  message('  Fentanyl/initial entries found: ', length(fent_items))

  if (length(fent_items) == 0) {
    message('  No fentanyl entries — returning empty tibble')
    return(tibble(
      ch99_code = character(), rate = numeric(),
      country_name = character(), census_code = character(),
      entry_type = character()
    ))
  }

  # Parse each entry — only keep entries with a rate (exclusions have no "+X%")
  results <- map_dfr(fent_items, function(item) {
    ch99_code <- item$htsno %||% NA_character_
    general <- item$general %||% ''
    description <- item$description %||% ''

    # Only surcharge rates ("+X%")
    surcharge_match <- str_match(general, '\\+\\s*([0-9.]+)%')
    if (is.na(surcharge_match[1, 2])) {
      return(NULL)  # Skip exclusion entries (donations, informational materials, USMCA)
    }

    rate <- as.numeric(surcharge_match[1, 2]) / 100

    # Detect general vs carveout: general entries say "Except for products described in"
    is_general <- grepl('Except for products described in', description, ignore.case = TRUE)

    # Extract country from description; fall back to ch99_code range if
    # description doesn't mention a country (e.g., 9903.01.13 lists product
    # categories for CA energy without saying "Canada").
    country_names <- extract_countries_from_description(description)

    if (length(country_names) == 0) {
      # Infer country from ch99_code block structure:
      #   9903.01.01-09 → Mexico
      #   9903.01.10-19 → Canada
      #   9903.01.20-24 → China/Hong Kong
      suffix <- as.integer(sub('^9903\\.01\\.', '', ch99_code))
      inferred_country <- case_when(
        suffix >= 1L  & suffix <= 9L  ~ 'Mexico',
        suffix >= 10L & suffix <= 19L ~ 'Canada',
        suffix >= 20L & suffix <= 24L ~ 'China',
        TRUE ~ NA_character_
      )
      if (is.na(inferred_country)) return(NULL)
      country_names <- inferred_country
      message('    Inferred country for ', ch99_code, ': ', inferred_country)
    }

    matched <- match_countries(country_names, country_lookup)

    tibble(
      ch99_code = ch99_code,
      rate = rate,
      country_name = matched$country_name,
      census_code = matched$census_code,
      entry_type = if_else(is_general, 'general', 'carveout')
    )
  })

  if (nrow(results) == 0) {
    message('  No fentanyl entries with rates parsed')
    return(tibble(
      ch99_code = character(), rate = numeric(),
      country_name = character(), census_code = character(),
      entry_type = character()
    ))
  }

  # Drop unmatched countries
  results <- results %>% filter(!is.na(census_code))

  message('  Fentanyl rates parsed:')
  for (i in seq_len(nrow(results))) {
    message('    ', results$ch99_code[i], ' ',
            results$country_name[i], ' (',
            results$census_code[i], '): ',
            round(results$rate[i] * 100), '% [', results$entry_type[i], ']')
  }

  return(results)
}


# =============================================================================
# Section 232 Rate Extraction
# =============================================================================

#' Max rate from a vector, with a logged note if the vector holds multiple
#' distinct values. Used for parser extraction points where several Ch99
#' entries may co-exist and the pipeline historically just called max() and
#' hoped for the best. If a future subdivision introduces a different rate
#' (e.g. a country-specific copper deal alongside the blanket 9903.78.01),
#' the log line surfaces that variance instead of silently swallowing it.
max_rate_with_variance_log <- function(rates, label) {
  vals <- unique(rates[!is.na(rates)])
  if (length(vals) > 1) {
    message('  ', label, ': ', length(vals),
            ' distinct rates present (',
            paste0(round(sort(vals) * 100, 2), '%', collapse = ', '),
            ') — taking max')
  }
  max(rates, na.rm = TRUE)
}


#' Build a Census-code => rate list from country-specific Ch99 entries.
#'
#' For ranges that carry country-specific deal rates (e.g. 9903.81.94-99 for
#' UK steel, 9903.85.12-15 for UK aluminum), parse each entry's description
#' via parse_countries(), map the resulting ISO codes to Census codes (with
#' EU expansion), and return a named list keyed on Census code. If multiple
#' entries resolve to the same country, keeps the max rate.
#'
#' Entries whose country cannot be identified from the description are
#' rejected with a warning rather than silently attributed to the first
#' hardcoded country in the range. Previously the steel block hardcoded
#' '4120' (UK) for every entry in 9903.81.94-99 without inspecting the
#' description — any future non-UK deal landing in that range would have
#' been silently misattributed.
#'
#' @param entries Tibble of ch99 entries in the target range. Must have
#'   `ch99_code`, `country_type`, `countries`, and `rate` columns.
#' @param label Human-readable label for warning messages (e.g.
#'   "Steel 232 country override (9903.81.94-99)").
#' @return Named list: Census code => rate.
extract_country_specific_overrides <- function(entries, label = 'country override') {
  overrides <- list()
  if (nrow(entries) == 0) return(overrides)

  specific <- entries %>% filter(country_type == 'specific', !is.na(rate))
  unattributed <- entries %>% filter(country_type != 'specific' | is.na(rate))

  if (nrow(unattributed) > 0) {
    warning(label, ': ', nrow(unattributed),
            ' entries could not be attributed to a specific country and were skipped (ch99_code ',
            paste(unattributed$ch99_code, collapse = ', '), ')')
  }

  if (nrow(specific) == 0) return(overrides)

  for (i in seq_len(nrow(specific))) {
    iso_codes <- specific$countries[[i]]
    rate_i <- specific$rate[i]
    if (length(iso_codes) == 0) next

    for (iso in iso_codes) {
      census_codes <- if (identical(iso, 'EU')) EU27_CODES else ISO_TO_CENSUS[iso]
      census_codes <- as.character(census_codes)
      census_codes <- census_codes[!is.na(census_codes) & nzchar(census_codes)]
      if (length(census_codes) == 0) {
        warning(label, ': ch99_code ', specific$ch99_code[i],
                ' references ISO code "', iso,
                '" which has no Census mapping; skipping')
        next
      }
      for (census in census_codes) {
        overrides[[census]] <- max(overrides[[census]] %||% 0, rate_i)
      }
    }
  }
  overrides
}


#' Extract Section 232 blanket rates from Chapter 99 data
#'
#' Section 232 tariffs are NOT linked via product footnotes.
#' Coverage is defined by US Notes:
#'   - US Note 16: Steel (chapters 72-73), via 9903.80-84
#'   - US Note 19: Aluminum (chapter 76), via 9903.85
#'   - US Note 25: Autos/auto parts, via 9903.94
#'
#' Parses applicable Ch99 entries and returns per-tariff rates.
#'
#' @param ch99_data Parsed Chapter 99 data from parse_chapter99()
#' @return List with per-tariff rates, exemptions, and has_232 flag
extract_section232_rates <- function(ch99_data) {
  message('Extracting Section 232 blanket rates...')

  # --- Steel and Aluminum (9903.80-85) ---
  s232_sa <- ch99_data %>%
    filter(grepl('^9903\\.8[0-5]', ch99_code), !is.na(rate)) %>%
    mutate(
      s232_type = case_when(
        grepl('^9903\\.8[0-4]', ch99_code) ~ 'steel',
        grepl('^9903\\.85', ch99_code) ~ 'aluminum'
      )
    )

  steel_entries <- s232_sa %>% filter(s232_type == 'steel')
  aluminum_entries <- s232_sa %>% filter(s232_type == 'aluminum')

  # Steel: check for June 2025 increase entries (9903.81.87+) first, then
  # fall back to original entries (9903.80.xx). The June 2025 proclamation
  # doubled steel from 25% to 50% via new 9903.81.87-93 entries.
  # UK gets 25% via 9903.81.94-99.
  # 9903.81.87 is a statutory blanket rate (all countries); its description
  # references HTS headings in the "except" clause, not countries, so
  # parse_countries() may return country_type='unknown'. Don't filter by type.
  steel_increase <- steel_entries %>%
    filter(ch99_code == '9903.81.87', !is.na(rate))
  steel_parent <- steel_entries %>% filter(grepl('^9903\\.80\\.', ch99_code))
  steel_all <- steel_parent %>% filter(country_type == 'all')
  steel_except <- steel_parent %>% filter(country_type == 'all_except')

  # Country-specific steel deal entries (9903.81.94-99). Currently used for the
  # UK steel deal; symmetric with aluminum and robust to future additions in
  # this range — the country is parsed from each entry's description rather
  # than hardcoded.
  steel_country_entries <- steel_entries %>%
    filter(grepl('^9903\\.81\\.9[4-9]', ch99_code), !is.na(rate))
  steel_country_overrides <- extract_country_specific_overrides(
    steel_country_entries,
    label = 'Steel 232 country override (9903.81.94-99)'
  )

  if (nrow(steel_increase) > 0) {
    steel_rate <- steel_increase$rate[1]
    steel_exempt <- character(0)
    message('  Steel 232: ', round(steel_rate * 100), '% (all countries, June 2025 increase)')
  } else if (nrow(steel_all) > 0) {
    steel_rate <- max_rate_with_variance_log(steel_all$rate, 'Steel 232 (9903.80.xx all-country)')
    steel_exempt <- character(0)
    message('  Steel 232: ', round(steel_rate * 100), '% (all countries)')
  } else if (nrow(steel_except) > 0) {
    steel_rate <- max_rate_with_variance_log(steel_except$rate, 'Steel 232 (9903.80.xx all-except)')
    steel_exempt <- unique(unlist(steel_except$exempt_countries))
    message('  Steel 232: ', round(steel_rate * 100), '% (all except ',
            length(steel_exempt), ' countries/groups)')
  } else {
    steel_rate <- 0
    steel_exempt <- character(0)
  }
  if (length(steel_country_overrides) > 0) {
    message('  Steel 232 country overrides: ',
            paste(names(steel_country_overrides), '=',
                  round(unlist(steel_country_overrides) * 100), '%', collapse = ', '))
  }

  # Aluminum: check for June 2025 increase entry (9903.85.02) first, then
  # fall back to original entries (9903.85.01/.03). UK gets 25% via 9903.85.12-15.
  # 9903.85.02 is a statutory blanket rate (all countries); same issue as steel.
  alum_increase <- aluminum_entries %>%
    filter(ch99_code == '9903.85.02', !is.na(rate))
  alum_parent <- aluminum_entries %>%
    filter(ch99_code %in% c('9903.85.01', '9903.85.03'))
  # Original "increase to 25%" entry (pre-June 2025, Proclamation 10896)
  alum_25_increase <- aluminum_entries %>%
    filter(ch99_code == '9903.85.12', country_type == 'all')

  alum_except <- alum_parent %>% filter(country_type == 'all_except')

  # Country-specific aluminum deal entries (9903.85.12-15). Currently used for
  # the UK aluminum deal; built via parse_countries() so future deals in this
  # range (e.g. Korea, Japan) resolve to the correct country automatically.
  #
  # Note: 9903.85.12 can be either the blanket "increase to 25%" entry OR a
  # country-specific UK entry depending on revision. parse_countries() returns
  # country_type='all' for the former (picked up by alum_25_increase above) and
  # country_type='specific' for the latter (picked up here) — so there is no
  # double-counting.
  alum_country_entries <- aluminum_entries %>%
    filter(grepl('^9903\\.85\\.1[2-5]', ch99_code), !is.na(rate))
  aluminum_country_overrides <- extract_country_specific_overrides(
    alum_country_entries,
    label = 'Aluminum 232 country override (9903.85.12-15)'
  )

  if (nrow(alum_increase) > 0) {
    aluminum_rate <- alum_increase$rate[1]
    aluminum_exempt <- character(0)
    message('  Aluminum 232: ', round(aluminum_rate * 100), '% (all countries, June 2025 increase)')
  } else if (nrow(alum_25_increase) > 0) {
    aluminum_rate <- alum_25_increase$rate[1]
    aluminum_exempt <- character(0)
    message('  Aluminum 232: ', round(aluminum_rate * 100), '% (all countries, increased)')
  } else if (nrow(alum_except) > 0) {
    aluminum_rate <- max_rate_with_variance_log(alum_except$rate, 'Aluminum 232 (9903.85.xx all-except)')
    aluminum_exempt <- unique(unlist(alum_except$exempt_countries))
    message('  Aluminum 232: ', round(aluminum_rate * 100), '% (all except ',
            length(aluminum_exempt), ' countries/groups)')
  } else {
    aluminum_rate <- 0
    aluminum_exempt <- character(0)
  }
  if (length(aluminum_country_overrides) > 0) {
    message('  Aluminum 232 country overrides: ',
            paste(names(aluminum_country_overrides), '=',
                  round(unlist(aluminum_country_overrides) * 100), '%', collapse = ', '))
  }

  # --- Aluminum derivatives (9903.85.04/.07/.08) ---
  # These entries cover aluminum-containing articles outside chapter 76.
  # Extract derivative rate for use in 06_calculate_rates.R step 3a.
  alum_deriv <- aluminum_entries %>%
    filter(ch99_code %in% c('9903.85.04', '9903.85.07', '9903.85.08'))
  aluminum_derivative_rate <- if (nrow(alum_deriv) > 0) {
    max_rate_with_variance_log(alum_deriv$rate, 'Aluminum derivative 232 (9903.85.04/.07/.08)')
  } else aluminum_rate
  aluminum_derivative_exempt <- if (nrow(alum_deriv) > 0) {
    unique(unlist(alum_deriv$exempt_countries))
  } else {
    aluminum_exempt
  }
  if (aluminum_derivative_rate > 0) {
    message('  Aluminum derivative 232: ', round(aluminum_derivative_rate * 100),
            '% (', nrow(alum_deriv), ' Ch99 entries)')
  }

  # --- Steel derivatives (9903.81.89-93) ---
  # Added via Section 232 Inclusions Process (FR 2025-15819, effective Aug 18, 2025).
  # These entries cover steel-containing articles outside chapters 72-73.
  # 9903.81.91 is the content-based tariff (applies to steel content only).
  # 9903.81.89/90 are full-rate entries for products in primary steel chapters.
  # 9903.81.92 is an exemption (US-melted steel, rate=0).
  # TODO(issue-3): Not modeled — requires product-condition exemption support.
  # See docs/analysis/section_232_review_memo_2026-04-06.md, Issue 3.
  # 9903.81.93 is a FTZ transitional entry.
  steel_deriv_codes <- c('9903.81.89', '9903.81.90', '9903.81.91', '9903.81.93')
  steel_deriv <- steel_entries %>%
    filter(ch99_code %in% steel_deriv_codes, !is.na(rate), rate > 0)
  steel_derivative_rate <- if (nrow(steel_deriv) > 0) {
    max_rate_with_variance_log(steel_deriv$rate, 'Steel derivative 232 (9903.81.89-93)')
  } else steel_rate
  steel_derivative_exempt <- if (nrow(steel_deriv) > 0) {
    unique(unlist(steel_deriv$exempt_countries))
  } else {
    steel_exempt
  }
  if (nrow(steel_deriv) > 0 && steel_derivative_rate > 0) {
    message('  Steel derivative 232: ', round(steel_derivative_rate * 100),
            '% (', nrow(steel_deriv), ' Ch99 entries)')
  }

  # --- Autos (9903.94) ---
  s232_auto <- ch99_data %>%
    filter(grepl('^9903\\.94', ch99_code), !is.na(rate))

  auto_has_deals <- FALSE
  if (nrow(s232_auto) > 0) {
    # Auto entries: look for blanket entry applying to all countries.
    # Country-specific deal entries are NOT evidence of a blanket tariff.
    auto_all <- s232_auto %>% filter(country_type == 'all')
    auto_except <- s232_auto %>% filter(country_type == 'all_except')

    if (nrow(auto_all) > 0) {
      auto_rate <- max_rate_with_variance_log(auto_all$rate, 'Auto 232 (9903.94 all-country)')
      auto_exempt <- character(0)
      message('  Auto 232: ', round(auto_rate * 100), '% (all countries)')
    } else if (nrow(auto_except) > 0) {
      auto_rate <- max_rate_with_variance_log(auto_except$rate, 'Auto 232 (9903.94 all-except)')
      auto_exempt <- unique(unlist(auto_except$exempt_countries))
      message('  Auto 232: ', round(auto_rate * 100), '% (all except ',
              length(auto_exempt), ' countries/groups)')
    } else {
      # Only country-specific deal entries — no blanket auto tariff
      auto_rate <- 0
      auto_exempt <- character(0)
      auto_has_deals <- TRUE
      message('  Auto 232: no blanket rate (', nrow(s232_auto),
              ' country-specific deal entries only)')
    }
  } else {
    auto_rate <- 0
    auto_exempt <- character(0)
  }

  # --- Auto deal rates: country-specific floor/additive rates from 9903.94 ---
  # Country entries have country_type = 'specific' (parsed by parse_countries).
  # Two patterns:
  #   Floor: general = "15%" (no "+" prefix) → effective rate = max(floor - base, 0)
  #   Additive: general = "+7.5%" → flat surcharge
  #   Passthrough: general = "The duty provided..." (rate = NA) → no additional duty
  auto_deal_rates <- tibble(
    country = character(), rate = numeric(), rate_type = character(),
    ch99_code = character(), program = character()
  )

  if (nrow(s232_auto) > 0) {
    # Classify program by matching the description for known vehicle / parts
    # phrasing. The ch99 code alone is not enough — country-specific ranges
    # (UK .31-.33, Japan .40-.45, EU .50-.53, Korea .60-.65) each mix vehicles
    # and parts codes. Both branches are explicit; entries matching neither
    # are dropped with a warning rather than silently defaulting to one side
    # (the previous fallback to 'auto_vehicles' would have silently
    # misclassified a future entry with novel phrasing like
    # "motor vehicle parts"). Parts branch comes first so descriptions
    # beginning with "Parts of passenger vehicles..." don't match the
    # vehicles regex on the "passenger vehicles" substring.
    parts_pattern <- paste0('automobile parts',
                            '|auto parts',
                            '|parts of passenger',
                            '|parts of.*(vehicles|light trucks)')
    vehicles_pattern <- 'passenger vehicles|light trucks'

    auto_country <- s232_auto %>%
      filter(country_type == 'specific') %>%
      mutate(
        iso_country = map_chr(countries, ~.x[1]),
        rate_type = case_when(
          is.na(rate) ~ 'passthrough',
          !grepl('\\+', general_raw) & grepl('^[0-9]+\\.?[0-9]*%$', trimws(general_raw)) ~ 'floor',
          TRUE ~ 'surcharge'
        ),
        program = case_when(
          grepl(parts_pattern, description, ignore.case = TRUE) ~ 'auto_parts',
          grepl(vehicles_pattern, description, ignore.case = TRUE) ~ 'auto_vehicles',
          TRUE ~ NA_character_
        )
      ) %>%
      filter(!is.na(rate), rate_type != 'passthrough')

    unclassified <- auto_country %>% filter(is.na(program))
    if (nrow(unclassified) > 0) {
      warning('Auto deal classification: ', nrow(unclassified),
              ' 9903.94.xx country-specific entries could not be classified ',
              'as vehicles or parts from their description; these entries ',
              'were dropped from auto_deal_rates. ch99_code: ',
              paste(unclassified$ch99_code, collapse = ', '),
              '. Extend parts_pattern / vehicles_pattern in ',
              '05_parse_policy_params.R::extract_section232_rates() to cover them.')
      auto_country <- auto_country %>% filter(!is.na(program))
    }

    if (nrow(auto_country) > 0) {
      auto_deal_rates <- auto_country %>%
        select(iso_country, rate, rate_type, ch99_code, program) %>%
        rename(country = iso_country)
      message('  Auto deal rates: ', nrow(auto_deal_rates), ' country-specific entries (',
              paste(unique(auto_deal_rates$country), collapse = ', '), ')')
    }
  }

  # --- Wood products (9903.76) ---
  s232_wood <- ch99_data %>%
    filter(grepl('^9903\\.76', ch99_code))

  wood_rate <- 0
  wood_furniture_rate <- 0
  wood_deal_rates <- tibble(
    country = character(), rate = numeric(), rate_type = character(),
    ch99_code = character()
  )

  if (nrow(s232_wood) > 0) {
    # Universal entries: 9903.76.01 (softwood 10%), 9903.76.02 (furniture 25%), 9903.76.03 (cabinets 25%)
    wood_softwood <- s232_wood %>%
      filter(ch99_code == '9903.76.01', !is.na(rate))
    wood_furn <- s232_wood %>%
      filter(ch99_code %in% c('9903.76.02', '9903.76.03'), !is.na(rate))

    if (nrow(wood_softwood) > 0) {
      wood_rate <- max(wood_softwood$rate)
      message('  Softwood 232: ', round(wood_rate * 100), '%')
    }
    if (nrow(wood_furn) > 0) {
      wood_furniture_rate <- max(wood_furn$rate)
      message('  Wood furniture/cabinets 232: ', round(wood_furniture_rate * 100), '%')
    }

    # Country-specific deal entries: 9903.76.20-23
    wood_country <- s232_wood %>%
      filter(country_type == 'specific', !is.na(rate)) %>%
      mutate(
        iso_country = map_chr(countries, ~.x[1]),
        rate_type = case_when(
          !grepl('\\+', general_raw) & grepl('^[0-9]+\\.?[0-9]*%$', trimws(general_raw)) ~ 'floor',
          TRUE ~ 'surcharge'
        )
      )

    if (nrow(wood_country) > 0) {
      wood_deal_rates <- wood_country %>%
        select(iso_country, rate, rate_type, ch99_code) %>%
        rename(country = iso_country)
      message('  Wood deal rates: ', nrow(wood_deal_rates), ' country-specific entries (',
              paste(unique(wood_deal_rates$country), collapse = ', '), ')')
    }
  }

  # --- MHD vehicles (9903.74) ---
  s232_mhd <- ch99_data %>%
    filter(grepl('^9903\\.74', ch99_code), !is.na(rate))

  mhd_rate <- 0
  if (nrow(s232_mhd) > 0) {
    # 9903.74.xx descriptions reference US Note 38, not countries,
    # so parse_countries() returns 'unknown'. Take max rate directly.
    mhd_rate <- max_rate_with_variance_log(s232_mhd$rate, 'MHD vehicles 232 (9903.74.xx)')
    message('  MHD vehicles 232: ', round(mhd_rate * 100), '%')
  }

  # --- Copper (9903.78) ---
  s232_copper <- ch99_data %>%
    filter(grepl('^9903\\.78', ch99_code), !is.na(rate))

  copper_rate <- 0
  if (nrow(s232_copper) > 0) {
    # 9903.78.01 is a blanket rate; description references US Note 36
    # subdivision, not countries, so parse_countries() returns 'unknown'.
    # Don't filter by country_type — take the max rate from any entry.
    copper_rate <- max_rate_with_variance_log(s232_copper$rate, 'Copper 232 (9903.78.xx)')
    message('  Copper 232: ', round(copper_rate * 100), '%')
  }

  # --- Semiconductors (9903.79, US Note 39) ---
  # 9903.79.01 is the 25% rate on all-country qualifying semiconductor articles.
  # 9903.79.02-.09 are NA-rate carve-outs (sub-b tech-gate miss, end-use
  # exemptions); they're modeled elsewhere via qualifying_share and
  # end_use_exemption_share, so we only extract the .01 rate here.
  s232_semi <- ch99_data %>%
    filter(ch99_code == '9903.79.01', !is.na(rate))

  semi_rate <- 0
  if (nrow(s232_semi) > 0) {
    semi_rate <- max_rate_with_variance_log(s232_semi$rate, 'Semiconductor 232 (9903.79.01)')
    message('  Semiconductor 232: ', round(semi_rate * 100), '%')
  }

  has_232 <- (steel_rate > 0 || aluminum_rate > 0 || auto_rate > 0 || auto_has_deals ||
              wood_rate > 0 || wood_furniture_rate > 0 || mhd_rate > 0 || copper_rate > 0 ||
              semi_rate > 0 ||
              aluminum_derivative_rate > 0 || steel_derivative_rate > 0)

  coverage_parts <- c()
  if (steel_rate > 0 || aluminum_rate > 0) coverage_parts <- c(coverage_parts, 'steel/aluminum')
  if (auto_rate > 0 || auto_has_deals) coverage_parts <- c(coverage_parts, 'autos')
  if (wood_rate > 0 || wood_furniture_rate > 0) coverage_parts <- c(coverage_parts, 'wood')
  if (mhd_rate > 0) coverage_parts <- c(coverage_parts, 'MHD')
  if (copper_rate > 0) coverage_parts <- c(coverage_parts, 'copper')
  if (semi_rate > 0) coverage_parts <- c(coverage_parts, 'semi')
  if (has_232) message('  232 coverage: ', paste(coverage_parts, collapse = ' + '))

  return(list(
    steel_rate = steel_rate,
    aluminum_rate = aluminum_rate,
    auto_rate = auto_rate,
    aluminum_derivative_rate = aluminum_derivative_rate,
    steel_derivative_rate = steel_derivative_rate,
    wood_rate = wood_rate,
    wood_furniture_rate = wood_furniture_rate,
    mhd_rate = mhd_rate,
    copper_rate = copper_rate,
    semi_rate = semi_rate,
    steel_exempt = steel_exempt,
    aluminum_exempt = aluminum_exempt,
    auto_exempt = auto_exempt,
    aluminum_derivative_exempt = aluminum_derivative_exempt,
    steel_derivative_exempt = steel_derivative_exempt,
    auto_has_deals = auto_has_deals,
    auto_deal_rates = auto_deal_rates,
    wood_deal_rates = wood_deal_rates,
    steel_country_overrides = steel_country_overrides,
    aluminum_country_overrides = aluminum_country_overrides,
    has_232 = has_232
  ))
}


# =============================================================================
# Section 122 Rate Extraction
# =============================================================================

#' Extract Section 122 blanket rate from Chapter 99 data
#'
#' Section 122 (Trade Act of 1974) tariffs are non-discriminatory (single rate,
#' all countries). Applied after SCOTUS invalidated IEEPA authority.
#'
#' Parses 9903.03.01 for the base 10% rate. Product exemptions (Annex II)
#' are handled separately via resources/s122_exempt_products.csv.
#'
#' @param ch99_data Parsed Chapter 99 data from parse_chapter99()
#' @return List with s122_rate (numeric) and has_s122 (logical)
extract_section122_rates <- function(ch99_data) {
  message('Extracting Section 122 rates...')

  # Look for 9903.03.01 (base Section 122 duty)
  s122_entries <- ch99_data %>%
    filter(grepl('^9903\\.03\\.01$', ch99_code), !is.na(rate))

  if (nrow(s122_entries) == 0) {
    message('  No Section 122 entries found')
    return(list(s122_rate = 0, has_s122 = FALSE))
  }

  s122_rate <- max(s122_entries$rate)
  message('  Section 122 base rate (9903.03.01): ', round(s122_rate * 100), '%')

  return(list(s122_rate = s122_rate, has_s122 = TRUE))
}


#' Extract Section 201 (safeguard) rates from Chapter 99 data
#'
#' Section 201 is a safeguard tariff under Trade Act of 1974 Section 201.
#' The active program is:
#'   - Solar 201 (CSPV cells/modules): 9903.45.21–.29, originally Proc 9693
#'     (2018), extended through Feb 6 2026 by Proc 10454 (Feb 2022). Solar 201
#'     uses a TRQ structure: in-quota imports (under 12.5 GW for cells) pay no
#'     additional duty; out-of-quota imports pay the safeguard rate (currently
#'     ~14.5% in Year 8 of the extension).
#'
#' Why we don't read the rate directly from HTS: the HTS `general` field for
#' 9903.45.22/.25 (out-of-quota) shows 30% — the original Year 1 (2018) rate
#' that the proclamation steps down over time. The annual step-down is in US
#' Note 18, not in the HTS rate field. We therefore prefer a config-supplied
#' rate (`section_201.solar_rate` in policy_params.yaml) over the HTS value.
#' Without the config, we fall back to the most-recent step-down published by
#' USTR (~14.5% as of 2025-2026).
#'
#' We also blend this over the TRQ — the effective rate is roughly
#' `out-of-quota_rate * out_of_quota_share`, but we currently apply the rate
#' uniformly because we don't model TRQ utilization.
#'
#' Note: Washing-machine 201 (9903.45.01-.06) entries persist in HTS but
#' expired Feb 2023 — we ignore them.
#'
#' Country exemptions (per Proc 10454):
#'   - Canada (Census 1220) is exempt under USMCA. Applied in 06_calculate_rates.R.
#'   - GSP developing-country exemption list is not currently modeled.
#'
#' Returns has_s201 = TRUE if any 9903.45.21-.29 entries are present in the
#' revision (signals the program is active in this snapshot).
#'
#' @param ch99_data Tibble of parsed Chapter 99 entries
#' @param policy_params Optional policy params; reads section_201.solar_rate if set
extract_section_201_rates <- function(ch99_data, policy_params = NULL) {
  message('Extracting Section 201 (safeguard) rates...')

  # Restrict to Solar 201 (9903.45.21-.29). Washing-machine 201 (9903.45.01-.06)
  # expired Feb 2023 — ignore those entries even if still in HTS.
  s201_entries <- ch99_data %>%
    filter(grepl('^9903\\.45\\.(2[1-9])$', ch99_code), !is.na(rate))

  if (nrow(s201_entries) == 0) {
    message('  No Solar 201 entries (9903.45.21-.29) found')
    return(list(s201_rates = NULL, has_s201 = FALSE, solar_rate = 0))
  }

  # Pull the configured rate, falling back to the published Year 8 (2025-26)
  # value if not set. The HTS field is misleading because it shows the original
  # Year 1 rate, not the current step-down.
  s201_cfg <- if (!is.null(policy_params)) policy_params$SECTION_201 else NULL
  solar_rate <- s201_cfg$solar_rate %||% 0.145

  hts_rates <- sort(unique(round(s201_entries$rate, 4)))
  message('  Solar 201 active: ', nrow(s201_entries),
          ' Ch99 entries (HTS rates: ',
          paste(hts_rates * 100, '%', collapse = ', '), ')')
  message('  Applying configured solar_rate: ', round(solar_rate * 100, 1),
          '% (override via section_201.solar_rate in policy_params.yaml)')

  return(list(
    s201_rates = s201_entries %>%
      transmute(ch99_code, rate, rate_type = 'surcharge'),
    has_s201 = TRUE,
    solar_rate = solar_rate
  ))
}


#' Check if a Census country code is exempt from Section 232
#'
#' Handles ISO codes, group codes ('EU'), and Census codes in the exempt list.
#'
#' @param census_code Census country code (e.g., '4280')
#' @param exempt_list Vector of exempt codes (ISO, Census, or groups like 'EU')
#' @return Logical — TRUE if exempt
is_232_exempt <- function(census_code, exempt_list) {
  if (length(exempt_list) == 0) return(FALSE)

  # Direct Census code match
  if (census_code %in% exempt_list) return(TRUE)

  # Check if country is in ISO_TO_CENSUS and its ISO code is exempt
  iso_code <- names(ISO_TO_CENSUS)[match(census_code, ISO_TO_CENSUS)]
  if (!is.na(iso_code) && iso_code %in% exempt_list) return(TRUE)

  # Check EU group membership
  if ('EU' %in% exempt_list && census_code %in% EU27_CODES) return(TRUE)

  return(FALSE)
}


# =============================================================================
# USMCA Eligibility Extraction
# =============================================================================

#' Extract USMCA eligibility from HTS product special field
#'
#' Products with "S" or "S+" in their special field qualify for USMCA
#' preferential rates (typically "Free" for Canada/Mexico).
#'
#' @param hts_raw Parsed HTS JSON (list)
#' @return Tibble with hts10 and usmca_eligible columns
extract_usmca_eligibility <- function(hts_raw) {
  message('Extracting USMCA eligibility from special field...')

  products <- map_dfr(hts_raw, function(item) {
    htsno <- item$htsno %||% ''

    # Only process 10-digit product codes, skip Chapter 99
    clean <- gsub('\\.', '', htsno)
    if (nchar(clean) != 10 || grepl('^99', htsno)) {
      return(NULL)
    }

    special <- item$special %||% ''

    # Extract program codes from ALL parenthesized groups
    # Some products have S/S+ in secondary groups, e.g.:
    #   "Free (BH,CL,...) 5.1¢/liter (PA) See 9823.xx.xx (S+)"
    programs <- character(0)
    all_matches <- str_extract_all(special, '\\(([^)]+)\\)')[[1]]
    for (m in all_matches) {
      codes_text <- gsub('[()]', '', m)
      programs <- c(programs, trimws(unlist(strsplit(codes_text, ','))))
    }

    # Check for USMCA: "S" or "S+" in program codes
    usmca_eligible <- any(programs %in% c('S', 'S+'))

    tibble(
      hts10 = clean,
      special_raw = special,
      usmca_eligible = usmca_eligible
    )
  })

  n_eligible <- sum(products$usmca_eligible)
  message('  Products parsed: ', nrow(products))
  message('  USMCA eligible: ', n_eligible, ' (', round(100 * n_eligible / nrow(products), 1), '%)')

  return(products)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)
  source(here('src', 'helpers.R'))

  # Load country lookup
  country_lookup <- build_country_lookup('resources/census_codes.csv')

  # Read HTS JSON (latest revision)
  message('Reading HTS JSON...')
  hts_raw <- fromJSON('data/hts_archives/hts_2025_rev_32.json', simplifyDataFrame = FALSE)
  message('  Total items: ', length(hts_raw))

  # Extract IEEPA country-specific rates
  ieepa_rates <- extract_ieepa_rates(hts_raw, country_lookup)

  # Extract USMCA eligibility
  usmca <- extract_usmca_eligibility(hts_raw)

  # Save results
  if (!dir.exists('data/processed')) dir.create('data/processed', recursive = TRUE)

  write_csv(ieepa_rates, 'data/processed/ieepa_country_rates.csv')
  message('\nSaved IEEPA rates to data/processed/ieepa_country_rates.csv')

  write_csv(
    usmca %>% select(hts10, usmca_eligible),
    'data/processed/usmca_products.csv'
  )
  message('Saved USMCA eligibility to data/processed/usmca_products.csv')

  # Summary
  message('\n=== IEEPA Rate Summary (Phase 2 - Active) ===')
  ieepa_rates %>%
    filter(phase == 'phase2_aug7', !is.na(census_code)) %>%
    distinct(census_code, rate, rate_type, country_name) %>%
    arrange(rate_type, rate, country_name) %>%
    print(n = 150)

  message('\n=== USMCA Summary ===')
  message('Eligible: ', sum(usmca$usmca_eligible))
  message('Not eligible: ', sum(!usmca$usmca_eligible))
}
