# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

Tariff Rate Tracker - An R-based system for tracking daily U.S. tariff rates by product, country, and tariff authority. Parses HTS (Harmonized Tariff Schedule) JSON archives, maps Chapter 99 footnote references to authorities, and generates outputs compatible with the Yale Budget Lab Tariff-Model.

## Key Commands

```bash
# Run full pipeline
Rscript src/run_daily.R

# Run with specific year/date
Rscript src/run_daily.R --year 2026 --date 2026-01-15

# Run individual steps
Rscript src/01_ingest_hts.R
Rscript src/02_extract_authorities.R
Rscript src/03_expand_countries.R
Rscript src/04_calculate_rates.R
Rscript src/05_write_outputs.R
```

## Architecture

```
HTS JSON → Parse → Extract Authorities → Expand Countries → Calculate Rates → Output
```

**Data Flow:**
1. `01_ingest_hts.R`: Parse HTS JSON → `hts_parsed.rds`
2. `02_extract_authorities.R`: Map Chapter 99 → `authority_data.rds`
3. `03_expand_countries.R`: Expand to countries → `expanded_data.rds`
4. `04_calculate_rates.R`: Apply stacking → `rate_data.rds`
5. `05_write_outputs.R`: Generate snapshots/exports

## Key Configuration Files

**config/authority_mapping.yaml** - Maps Chapter 99 subheadings (e.g., 9903.88.03) to:
- `authority`: section_301, section_232, ieepa, section_201, section_122
- `sub_authority`: list_1, steel, reciprocal_baseline, etc.
- `rate`: Additional duty rate (decimal)
- `countries`: List of Census codes or 'all'

**config/country_rules.yaml** - Defines:
- `country_groups`: Mnemonics (china, usmca, eu) → Census codes
- `section_232_exemptions`: Country exemptions by product type
- `stacking_rules`: How authorities combine

## Stacking Rules

From Tariff-ETRs methodology:

```r
# China (5700)
total = max(232, reciprocal) + fentanyl + 301 + s122

# Canada/Mexico (1220, 2010)
total = max(232, reciprocal) + fentanyl + s122

# All Others
total = (232 > 0 ? 232 : reciprocal + fentanyl) + s122
```

## Census Country Codes

Key codes used throughout:
- `5700` - China
- `1220` - Canada
- `2010` - Mexico
- `4120` - United Kingdom
- `5880` - Japan

Full list: `resources/census_codes.csv`

## Adding New Authority Mappings

When unmapped Chapter 99 subheadings appear:

1. Check pipeline output for unmapped references
2. Research subheading in HTS Chapter 99 notes
3. Add to `config/authority_mapping.yaml`:
```yaml
'9903.XX.XX':
  authority: <authority_name>
  sub_authority: <program>
  rate: 0.XX
  countries: ['5700']  # or 'all'
```

## Style Guidelines

- Single quotes for strings
- Tidyverse-first (dplyr/tidyr over base R)
- Never use `na.rm = TRUE` - missing values indicate bugs
- Use `%>%` pipes
- Explicit `return()` at function end
- 2-space indentation

## Related Repositories

- [Tariff-Model](../Tariff-Model) - Economic impact modeling
- [Tariff-ETRs](../Tariff-ETRs) - ETR calculations
