# Tariff Rate Tracker

An R-based system for tracking daily U.S. tariff rates by product, country, and tariff authority. Uses HTS (Harmonized Tariff Schedule) archives as the primary data source and generates outputs compatible with the Yale Budget Lab Tariff-Model.

## Overview

The tracker:
- Parses HTS JSON archives to extract base tariff rates
- Maps Chapter 99 footnote references to tariff authorities (Section 301, 232, IEEPA, etc.)
- Expands rates to the full product × country dimension
- Applies proper stacking rules for overlapping authorities
- Generates daily snapshots and change logs
- Exports YAML files compatible with Tariff-Model config format

```
HTS JSON Archive
       │
       ▼
┌──────────────────┐
│ 01_ingest_hts.R  │  Parse JSON, extract rates & footnotes
└────────┬─────────┘
         │
         ▼
┌────────────────────────┐
│ 02_extract_authorities │  Map Chapter 99 refs → authorities
└────────┬───────────────┘
         │
         ▼
┌──────────────────────┐
│ 03_expand_countries  │  Expand to all 240 countries
└────────┬─────────────┘
         │
         ▼
┌──────────────────────┐
│ 04_calculate_rates   │  Apply stacking rules
└────────┬─────────────┘
         │
         ▼
┌──────────────────────┐
│ 05_write_outputs     │  Generate snapshots & exports
└──────────────────────┘
```

## Quick Start

```bash
# Clone the repository
git clone https://github.com/Budget-Lab-Yale/tariff_rate_tracker.git
cd tariff_rate_tracker

# Install R packages
Rscript -e "install.packages(c('tidyverse', 'jsonlite', 'yaml'))"

# Download HTS data (place in data/hts_archives/)
# Get from: https://hts.usitc.gov/export?format=json

# Run the daily pipeline
Rscript src/run_daily.R
```

## Directory Structure

```
tariff_rate_tracker/
├── src/
│   ├── run_daily.R              # Main orchestrator
│   ├── 01_ingest_hts.R          # HTS JSON parser
│   ├── 02_extract_authorities.R # Chapter 99 → authority mapping
│   ├── 03_expand_countries.R    # Country expansion
│   ├── 04_calculate_rates.R     # Rate calculation + stacking
│   ├── 05_write_outputs.R       # Output generation
│   └── helpers.R                # Shared utilities
├── config/
│   ├── authority_mapping.yaml   # Chapter 99 → authority definitions
│   └── country_rules.yaml       # Country groups, exemptions, stacking
├── data/
│   ├── hts_archives/            # HTS JSON files
│   └── processed/               # Intermediate RDS files
├── resources/
│   ├── census_codes.csv         # 240 country codes
│   ├── hs10_gtap_crosswalk.csv  # Product-to-GTAP mapping
│   └── country_partner_mapping.csv
├── snapshots/                   # Daily rate snapshots
│   └── {YYYY-MM-DD}/
│       ├── tariff_rates.yaml
│       └── tariff_rates.csv
├── changes/                     # Change logs
│   └── {YYYY-MM-DD}.yaml
├── exports/                     # Tariff-Model compatible exports
│   └── {YYYY-MM-DD}/
│       ├── 232.yaml
│       ├── 301.yaml
│       ├── ieepa_reciprocal.yaml
│       ├── ieepa_fentanyl.yaml
│       └── other_params.yaml
├── PROPOSAL.md                  # System design document
└── README.md
```

## Tariff Authorities Tracked

| Authority | Description | Affected Countries |
|-----------|-------------|-------------------|
| Section 301 | China trade practices | China only |
| Section 232 | National security (steel/aluminum) | All countries (with exemptions) |
| IEEPA Reciprocal | Reciprocal tariffs | All countries (country-specific rates) |
| IEEPA Fentanyl | Fentanyl-related duties | China, Canada, Mexico |
| Section 201 | Safeguard measures | All countries |
| Section 122 | Balance of payments | All countries (stacks on top) |

## Stacking Rules

Tariff authorities can overlap. The tracker applies these stacking rules (from Tariff-ETRs):

**China:**
```
total = max(232, reciprocal) + fentanyl + 301 + s122
```

**Canada/Mexico:**
```
total = max(232, reciprocal) + fentanyl + s122
```

**All Others:**
```
total = (232 > 0 ? 232 : reciprocal + fentanyl) + s122
```

## Configuration

### authority_mapping.yaml

Maps Chapter 99 subheadings to tariff authorities:

```yaml
'9903.88.03':
  authority: section_301
  sub_authority: list_3
  description: 'Section 301 List 3'
  rate: 0.25
  countries:
    - '5700'  # China
  effective_date: '2018-09-24'
```

### country_rules.yaml

Defines country groups and exemptions:

```yaml
country_groups:
  usmca:
    - '1220'  # Canada
    - '2010'  # Mexico

section_232_exemptions:
  steel:
    - '1220'  # Canada
    - '2010'  # Mexico
    - '6021'  # Australia
```

## Outputs

### Daily Snapshot (snapshots/{date}/)

- `tariff_rates.yaml` - Summary statistics
- `tariff_rates.csv` - Complete product × country rate matrix

### Change Log (changes/{date}.yaml)

Records rate changes from previous snapshot:

```yaml
date: '2025-01-15'
n_changes: 42
summary:
  added: 10
  removed: 2
  rate_changes: 30
```

### Tariff-Model Export (exports/{date}/)

YAML files compatible with Tariff-Model config:

- `232.yaml` - Section 232 tariffs
- `301.yaml` - Section 301 tariffs
- `ieepa_reciprocal.yaml` - IEEPA reciprocal tariffs
- `ieepa_fentanyl.yaml` - IEEPA fentanyl tariffs
- `other_params.yaml` - Additional parameters

## Adding New Authority Mappings

When new Chapter 99 subheadings appear in the HTS:

1. Run the pipeline - unmapped subheadings will be reported
2. Research the subheading in Chapter 99 notes
3. Add entry to `config/authority_mapping.yaml`:

```yaml
'9903.XX.XX':
  authority: <authority_name>
  sub_authority: <specific_program>
  description: 'Description'
  rate: 0.XX
  countries:
    - '<census_code>'  # Or 'all'
  effective_date: 'YYYY-MM-DD'
```

4. Re-run the pipeline

## Data Sources

- **HTS Archives**: [USITC HTS Online](https://hts.usitc.gov/)
- **Census Country Codes**: [Census Bureau](https://www.census.gov/foreign-trade/schedules/b/countrycodes.html)
- **Federal Register**: Proclamations and executive orders (manual curation)

## Related Projects

- [Tariff-Model](https://github.com/Budget-Lab-Yale/Tariff-Model) - Economic impact modeling
- [Tariff-ETRs](https://github.com/Budget-Lab-Yale/Tariff-ETRs) - ETR calculations

## Key Statistics (2026 HTS)

```
Products:               10,537
Countries:              240
Product-Country pairs:  160,646
Mean base rate:         2.31%
Mean additional duty:   11.75%
Mean total rate:        14.06%

Top Countries by Additional Duties:
  China:   20.56% avg (10,519 products)
  Canada:  11.52% avg (645 products)
  Mexico:  11.52% avg (645 products)
```
