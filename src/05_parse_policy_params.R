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
# Constants
# =============================================================================

# EU-27 member state Census codes (for expanding "European Union" entries)
EU27_CODES <- c(
  '4330',  # Austria
  '4211',  # Belgium
  '4840',  # Bulgaria
  '4760',  # Croatia
  '5010',  # Cyprus
  '4351',  # Czech Republic
  '4099',  # Denmark
  '4723',  # Estonia
  '4011',  # Finland
  '4279',  # France
  '4280',  # Germany
  '4430',  # Greece
  '4370',  # Hungary
  '4190',  # Ireland
  '4759',  # Italy
  '4724',  # Latvia
  '4725',  # Lithuania
  '4420',  # Luxembourg
  '4810',  # Malta
  '4210',  # Netherlands
  '4550',  # Poland
  '4710',  # Portugal
  '4580',  # Romania
  '4740',  # Slovakia
  '4781',  # Slovenia
  '4699',  # Spain
  '4010'   # Sweden
)

EU27_NAMES <- c(
  '4330' = 'Austria', '4211' = 'Belgium', '4840' = 'Bulgaria',
  '4760' = 'Croatia', '5010' = 'Cyprus', '4351' = 'Czech Republic',
  '4099' = 'Denmark', '4723' = 'Estonia', '4011' = 'Finland',
  '4279' = 'France', '4280' = 'Germany', '4430' = 'Greece',
  '4370' = 'Hungary', '4190' = 'Ireland', '4759' = 'Italy',
  '4724' = 'Latvia', '4725' = 'Lithuania', '4420' = 'Luxembourg',
  '4810' = 'Malta', '4210' = 'Netherlands', '4550' = 'Poland',
  '4710' = 'Portugal', '4580' = 'Romania', '4740' = 'Slovakia',
  '4781' = 'Slovenia', '4699' = 'Spain', '4010' = 'Sweden'
)

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
    "cote d'ivoire" = '7230', "c\u00f4te d'ivoire" = '7230', 'ivory coast' = '7230',
    'burma' = '5560', 'myanmar' = '5560',
    'laos' = '5530',
    'taiwan' = '5830',
    'vietnam' = '5520', 'viet nam' = '5520',
    'hong kong' = '5820', 'macau' = '5850', 'macao' = '5850',
    'brunei' = '5610',
    'east timor' = '5630', 'timor-leste' = '5630',
    'eswatini' = '7990', 'swaziland' = '7990',
    'cabo verde' = '7210', 'cape verde' = '7210',
    'gambia' = '7420',
    'bosnia' = '4507', 'bosnia and herzegovina' = '4507',
    'trinidad' = '2740', 'trinidad and tobago' = '2740',
    'antigua' = '2417', 'antigua and barbuda' = '2417',
    'saint kitts' = '2490', 'st. kitts' = '2490', 'saint kitts and nevis' = '2490',
    'saint lucia' = '2530', 'st. lucia' = '2530',
    'saint vincent' = '2550', 'st. vincent' = '2550',
    'equatorial guinea' = '7450',
    'papua new guinea' = '6220',
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
    # Phase 2: 9903.02.02-81 (August 7 reinstatement)
    grepl('^9903\\.01\\.(4[3-9]|[5-7][0-9])$', htsno) ||
      grepl('^9903\\.02\\.([0-7][0-9]|8[01])$', htsno)
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

    # Determine phase
    phase <- if (grepl('^9903\\.01\\.', ch99_code)) 'phase1_apr9' else 'phase2_aug7'

    # Check if terminated
    terminated <- grepl('provision terminated', description, ignore.case = TRUE)

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
  # 9903.01.63 (China/HK/Macau) was NOT paused — its rate was modified
  # (125% → 34%) rather than suspended. We exempt it from capping.
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
      # 9903.01.63 is China/HK/Macau — exempt from the 90-day pause
      china_entry <- '9903.01.63'
      phase1_cappable <- results$phase == 'phase1_apr9' &
        results$ch99_code != china_entry &
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
#' @return Tibble with ch99_code, rate, country_name, census_code
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
      country_name = character(), census_code = character()
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
      return(NULL)  # Skip exclusion entries
    }

    rate <- as.numeric(surcharge_match[1, 2]) / 100

    # Extract country from description
    country_names <- extract_countries_from_description(description)
    if (length(country_names) == 0) return(NULL)

    matched <- match_countries(country_names, country_lookup)

    tibble(
      ch99_code = ch99_code,
      rate = rate,
      country_name = matched$country_name,
      census_code = matched$census_code
    )
  })

  if (nrow(results) == 0) {
    message('  No fentanyl entries with rates parsed')
    return(tibble(
      ch99_code = character(), rate = numeric(),
      country_name = character(), census_code = character()
    ))
  }

  # Drop unmatched countries
  results <- results %>% filter(!is.na(census_code))

  # For countries with multiple entries, take the FIRST entry (by ch99_code).
  # The first entry in each country block is the general rate (applies to most
  # products), with subsequent entries being exceptions (product-specific lower
  # rates or anti-transshipment penalties). For blanket application, the general
  # entry is appropriate.
  country_fent <- results %>%
    group_by(census_code) %>%
    arrange(ch99_code) %>%
    summarise(
      rate = first(rate),
      ch99_code = first(ch99_code),
      country_name = first(country_name),
      .groups = 'drop'
    )

  message('  Fentanyl rates by country:')
  for (i in seq_len(nrow(country_fent))) {
    message('    ', country_fent$country_name[i], ' (',
            country_fent$census_code[i], '): ',
            round(country_fent$rate[i] * 100), '%')
  }

  return(country_fent)
}


# =============================================================================
# Section 232 Rate Extraction
# =============================================================================

#' Extract Section 232 blanket rates from Chapter 99 data
#'
#' Section 232 tariffs (steel/aluminum) are NOT linked via product footnotes.
#' Coverage is defined by US Notes 16 (steel) and 19 (aluminum) referencing
#' HTS chapters 72-73 (steel) and 76 (aluminum).
#'
#' Parses 9903.80-84 (steel) and 9903.85 (aluminum) entries to build a
#' per-country rate lookup, handling country exemptions.
#'
#' @param ch99_data Parsed Chapter 99 data from parse_chapter99()
#' @return List with:
#'   - steel_rates: tibble(country_code, rate) for steel
#'   - aluminum_rates: tibble(country_code, rate) for aluminum
#'   - steel_entries: filtered ch99_data for steel
#'   - aluminum_entries: filtered ch99_data for aluminum
extract_section232_rates <- function(ch99_data) {
  message('Extracting Section 232 blanket rates...')

  # Get all 232 entries with parsed rates
  s232 <- ch99_data %>%
    filter(grepl('^9903\\.8[0-5]', ch99_code), !is.na(rate)) %>%
    mutate(
      s232_type = case_when(
        grepl('^9903\\.8[0-4]', ch99_code) ~ 'steel',
        grepl('^9903\\.85', ch99_code) ~ 'aluminum'
      )
    )

  if (nrow(s232) == 0) {
    message('  No Section 232 entries with rates found')
    return(list(
      steel_rate = 0, aluminum_rate = 0,
      steel_exempt = character(0), aluminum_exempt = character(0),
      has_232 = FALSE
    ))
  }

  # Separate steel vs aluminum entries
  steel_entries <- s232 %>% filter(s232_type == 'steel')
  aluminum_entries <- s232 %>% filter(s232_type == 'aluminum')

  # For steel: use PARENT entries only (9903.80.01, 9903.80.03, 9903.80.61)
  # NOT the product-specific entries (9903.81.xx) which may have higher rates
  # (50%) for specific derivative products we can't identify by chapter alone.
  steel_parent <- steel_entries %>%
    filter(grepl('^9903\\.80\\.', ch99_code))
  steel_deriv <- steel_entries %>%
    filter(!grepl('^9903\\.80\\.', ch99_code))

  # Prefer 'all' entry (9903.80.61, exemptions revoked) over 'all_except' (9903.80.01)
  steel_all <- steel_parent %>% filter(country_type == 'all')
  steel_except <- steel_parent %>% filter(country_type == 'all_except')

  if (nrow(steel_all) > 0) {
    steel_rate <- max(steel_all$rate)
    steel_exempt <- character(0)
    message('  Steel 232: ', round(steel_rate * 100), '% (all countries)')
  } else if (nrow(steel_except) > 0) {
    steel_rate <- max(steel_except$rate)
    steel_exempt <- unique(unlist(steel_except$exempt_countries))
    message('  Steel 232: ', round(steel_rate * 100), '% (all except ',
            length(steel_exempt), ' countries/groups)')
  } else {
    steel_rate <- 0
    steel_exempt <- character(0)
  }

  # Aluminum: use PARENT entries only (9903.85.01, 9903.85.03)
  # NOT product-specific entries (9903.85.02 = 50%, 9903.85.67 = 200%, etc.)
  alum_parent <- aluminum_entries %>%
    filter(ch99_code %in% c('9903.85.01', '9903.85.03'))
  alum_increase <- aluminum_entries %>%
    filter(ch99_code == '9903.85.12')  # General increase entry (25%)

  alum_except <- alum_parent %>% filter(country_type == 'all_except')

  # If the 25% general increase entry exists (9903.85.12, all countries),
  # use that rate for all countries
  if (nrow(alum_increase) > 0 && alum_increase$country_type[1] == 'all') {
    aluminum_rate <- alum_increase$rate[1]
    aluminum_exempt <- character(0)
    message('  Aluminum 232: ', round(aluminum_rate * 100), '% (all countries, increased)')
  } else if (nrow(alum_except) > 0) {
    aluminum_rate <- max(alum_except$rate)
    aluminum_exempt <- unique(unlist(alum_except$exempt_countries))
    message('  Aluminum 232: ', round(aluminum_rate * 100), '% (all except ',
            length(aluminum_exempt), ' countries/groups)')
  } else {
    aluminum_rate <- 0
    aluminum_exempt <- character(0)
  }

  return(list(
    steel_rate = steel_rate,
    aluminum_rate = aluminum_rate,
    steel_exempt = steel_exempt,
    aluminum_exempt = aluminum_exempt,
    has_232 = (steel_rate > 0 || aluminum_rate > 0)
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

    # Extract program codes from parentheses
    programs <- character(0)
    programs_match <- str_extract(special, '\\(([^)]+)\\)')
    if (!is.na(programs_match)) {
      codes_text <- gsub('[()]', '', programs_match)
      programs <- trimws(unlist(strsplit(codes_text, ',')))
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
  setwd('C:/Users/ji252/Documents/GitHub/tariff_rate_tracker')

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
