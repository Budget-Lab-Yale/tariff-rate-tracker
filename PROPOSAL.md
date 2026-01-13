# Tariff Rate Tracker: System Proposal

## Executive Summary

This document proposes a system to track daily U.S. tariff rates by product, country, and tariff authority. The system will use HTS (Harmonized Tariff Schedule) archives as the primary data source, with Federal Register documents for attribution and verification.

## Objectives

1. Create a comprehensive daily snapshot of U.S. tariff rates
2. Track rate changes over time with attribution to specific authorities
3. Output data in YAML format compatible with the Tariff-Model pipeline
4. Enable delta extraction for scenario modeling

## Data Sources

### Primary: HTS JSON Archives

**Source:** USITC HTS Online Reference Tool
**URL Pattern:** `https://hts.usitc.gov/export?format=json&revision={edition}`
**Update Frequency:** Revisions published as tariff changes occur

**Structure Analysis (from 2025 Basic Edition):**
- 35,859 tariff line items
- Fields per item:
  - `htsno`: 10-digit HTS code (e.g., "0101.30.00.00")
  - `description`: Product description
  - `general`: MFN (Column 1) rate - applies to most countries
  - `special`: Preferential rates with program codes (A+, AU, BH, CL, etc.)
  - `other`: Column 2 rate - applies to non-NTR countries
  - `footnotes`: References to additional duties (e.g., "See 9903.88.15")
  - `indent`: Hierarchy level for descriptions

**Key Insight:** The `footnotes` field contains references to Chapter 99 subheadings (9903.xx.xx) which encode additional tariff authorities (Section 232, 301, IEEPA, etc.).

### Secondary: Federal Register API

**URL:** `https://api.federalregister.gov/v1/documents.json`
**Purpose:** Attribution and effective dates for tariff changes
**Challenge:** API access issues observed (redirects/blocking). May need alternative approach.

**Alternative Approaches:**
1. Manual curation of proclamations/executive orders
2. Web scraping with appropriate rate limiting
3. Use of cached Federal Register data

### Reference Data

| File | Source | Purpose |
|------|--------|---------|
| `census_codes.csv` | Tariff-ETRs | 240 country codes |
| `hs10_gtap_crosswalk.csv` | Tariff-ETRs | Product-to-GTAP mapping |
| `country_partner_mapping.csv` | Tariff-ETRs | Country-to-partner aggregation |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      Data Collection Layer                       │
├─────────────────┬─────────────────────┬─────────────────────────┤
│   HTS Archives  │  Federal Register   │   Manual Authority      │
│   (JSON)        │  (API/Scraped)      │   Definitions           │
└────────┬────────┴──────────┬──────────┴────────────┬────────────┘
         │                   │                       │
         ▼                   ▼                       ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Processing Layer                            │
├─────────────────────────────────────────────────────────────────┤
│  1. Parse HTS JSON → Extract rates + footnote references         │
│  2. Map footnotes → Chapter 99 authorities                       │
│  3. Expand to country dimension using authority rules            │
│  4. Calculate effective rates (base + additional duties)         │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Output Layer                                │
├─────────────────┬─────────────────────┬─────────────────────────┤
│  Daily YAML     │  Change Log         │  Tariff-Model           │
│  Snapshots      │  (Deltas)           │  Config Export          │
└─────────────────┴─────────────────────┴─────────────────────────┘
```

## Tariff Authority Mapping

### Chapter 99 Subheading → Authority Mapping

The HTS footnotes reference Chapter 99 subheadings that encode specific tariff authorities:

| Chapter 99 Range | Authority | Description |
|------------------|-----------|-------------|
| 9903.80.xx | Section 201 | Safeguard duties |
| 9903.81.xx | Section 232 (Steel) | National security - steel |
| 9903.82.xx | Section 232 (Aluminum) | National security - aluminum |
| 9903.83.xx | Section 232 (Derivatives) | Steel/aluminum derivatives |
| 9903.84.xx | Section 232 (Autos) | Autos and parts |
| 9903.85.xx | Section 301 (List 1) | China tech transfer |
| 9903.86.xx | Section 301 (List 2) | China trade practices |
| 9903.87.xx | Section 301 (List 3) | China additional |
| 9903.88.xx | Section 301 (List 4) | China additional |
| 9903.89.xx | IEEPA | International emergency powers |
| 9903.90.xx | Section 122 | Balance of payments |

**Note:** Exact ranges need verification against current HTS Chapter 99 notes.

### Authority → Country Applicability

| Authority | Countries Affected | Stacking Rule |
|-----------|-------------------|---------------|
| Section 232 (Steel/Alum) | Product-specific, country exemptions | Base authority |
| Section 301 | China (5700) | Stacks on 232 |
| IEEPA Reciprocal | Country-specific rates | Mutually exclusive with 232 |
| IEEPA Fentanyl | China stacks, others exclusive | Complex stacking |
| Section 122 | All countries | Stacks on everything |

## Data Model

### Core Schema: `tariff_rates.yaml`

```yaml
# Snapshot metadata
snapshot_date: '2025-01-15'
hts_revision: '2025-basic-rev-12'
authorities_as_of: '2025-01-15'

# Rate data by authority
section_232:
  steel:
    base:
      - '7206'  # Iron and steel products
      - '7207'
      # ... full list
    rates:
      default: 0.25
      canada: 0.0  # USMCA exempt
      mexico: 0.0
      australia: 0.0
    effective_date: '2018-03-23'
    proclamation: '9705'

  aluminum:
    base:
      - '7601'
      - '7602'
    rates:
      default: 0.10
      canada: 0.0
      mexico: 0.0
    effective_date: '2018-03-23'
    proclamation: '9704'

section_301:
  list_1:
    base:
      - '8471300100'  # Computers
      # ... full list
    rates:
      china: 0.25
      default: 0.0
    effective_date: '2018-07-06'

ieepa_reciprocal:
  headline_rates:
    default: 0.10
    china: 0.145
    canada: 0.25
    mexico: 0.25
    eu: 0.20
  product_rates:
    '8703': 0.25  # Autos
  effective_date: '2025-04-09'

ieepa_fentanyl:
  headline_rates:
    china: 0.20
    canada: 0.25
    mexico: 0.25
  effective_date: '2025-03-04'
```

### Change Log Schema: `changes/{date}.yaml`

```yaml
date: '2025-01-15'
changes:
  - authority: section_232
    sub_authority: steel
    type: rate_change
    countries:
      - uk
    old_rate: 0.25
    new_rate: 0.0
    effective_date: '2025-01-15'
    source: 'Federal Register 90 FR 12345'

  - authority: ieepa_reciprocal
    type: new_products
    products_added:
      - '9403'  # Furniture
    rate: 0.10
    effective_date: '2025-01-15'
```

## Processing Pipeline

### Step 1: HTS Ingestion (`src/01_ingest_hts.R`)

```
Input:  HTS JSON archive
Output: Parsed tibble with columns:
        - htsno (character, 10-digit)
        - description (character)
        - general_rate (numeric, parsed from percentage)
        - special_programs (list of program codes)
        - col2_rate (numeric)
        - chapter99_refs (list of 9903.xx.xx codes)
```

**Rate Parsing Logic:**
- "6.8%" → 0.068
- "Free" → 0.0
- "2.4¢/kg + 5%" → compound rate (flag for manual review)
- "$1.50/doz" → specific rate (flag for manual review)

### Step 2: Authority Extraction (`src/02_extract_authorities.R`)

```
Input:  Parsed HTS tibble + Chapter 99 mapping
Output: Authority-product tibble:
        - htsno
        - authority (section_232, section_301, ieepa, etc.)
        - sub_authority (steel, list_1, reciprocal, etc.)
        - additional_rate (from Chapter 99 notes)
```

**Logic:**
1. Parse Chapter 99 references from footnotes
2. Look up rate from Chapter 99 notes
3. Determine authority from subheading range

### Step 3: Country Expansion (`src/03_expand_countries.R`)

```
Input:  Authority-product tibble + Country rules
Output: Full product × country × authority tibble:
        - htsno
        - cty_code (Census country code)
        - authority
        - rate
```

**Logic:**
1. Load country applicability rules per authority
2. Expand each authority to applicable countries
3. Handle exemptions (USMCA, FTA partners, etc.)

### Step 4: Rate Calculation (`src/04_calculate_rates.R`)

```
Input:  Expanded tibble
Output: Final effective rates:
        - htsno
        - cty_code
        - base_rate (MFN or preferential)
        - additional_duties (by authority)
        - total_rate (with stacking rules)
```

**Stacking Rules (from Tariff-ETRs):**
- China: `max(232, reciprocal) + fentanyl + 301 + s122`
- Others: `(232 > 0 ? 232 : reciprocal + fentanyl) + s122`

### Step 5: Output Generation (`src/05_write_outputs.R`)

1. **Daily Snapshot:** `snapshots/{date}/tariff_rates.yaml`
2. **Change Detection:** Compare to previous snapshot
3. **Change Log:** `changes/{date}.yaml`
4. **Tariff-Model Export:** `exports/{date}/` with 232.yaml, ieepa_*.yaml

## Directory Structure

```
tariff_rate_tracker/
├── src/
│   ├── 01_ingest_hts.R
│   ├── 02_extract_authorities.R
│   ├── 03_expand_countries.R
│   ├── 04_calculate_rates.R
│   ├── 05_write_outputs.R
│   ├── helpers.R
│   └── run_daily.R           # Main orchestrator
├── config/
│   ├── authority_mapping.yaml # Chapter 99 → authority mapping
│   ├── country_rules.yaml     # Country applicability per authority
│   └── stacking_rules.yaml    # How authorities combine
├── data/
│   ├── hts_archives/          # Downloaded HTS JSON files
│   │   ├── hts_2025_basic.json
│   │   └── hts_2025_rev_*.json
│   └── federal_register/      # Cached proclamations
├── resources/
│   ├── census_codes.csv       # Copy from Tariff-ETRs
│   ├── hs10_gtap_crosswalk.csv
│   └── country_partner_mapping.csv
├── snapshots/                 # Daily rate snapshots
│   └── {YYYY-MM-DD}/
│       └── tariff_rates.yaml
├── changes/                   # Change logs
│   └── {YYYY-MM-DD}.yaml
├── exports/                   # Tariff-Model compatible exports
│   └── {YYYY-MM-DD}/
│       ├── 232.yaml
│       ├── ieepa_reciprocal.yaml
│       ├── ieepa_fentanyl.yaml
│       └── other_params.yaml
└── README.md
```

## Implementation Phases

### Phase 1: Core Infrastructure (Week 1-2)
- [ ] Set up directory structure
- [ ] Implement HTS JSON parser
- [ ] Create rate parsing utilities (handle %, specific, compound)
- [ ] Build Chapter 99 reference extractor
- [ ] Create basic output writers

### Phase 2: Authority Mapping (Week 3-4)
- [ ] Research and document current Chapter 99 structure
- [ ] Create authority_mapping.yaml with all current authorities
- [ ] Implement country expansion logic
- [ ] Implement stacking rules from Tariff-ETRs

### Phase 3: Change Detection (Week 5)
- [ ] Implement snapshot comparison
- [ ] Build change log generator
- [ ] Create delta extraction for Tariff-Model format

### Phase 4: Automation (Week 6)
- [ ] Set up scheduled HTS archive downloads
- [ ] Implement Federal Register integration (or manual workflow)
- [ ] Create daily run script with logging
- [ ] Add validation and error handling

### Phase 5: Testing & Documentation (Week 7-8)
- [ ] Validate against known Tariff-Model scenarios
- [ ] Compare output to manual ETR calculations
- [ ] Complete documentation
- [ ] Create user guide for manual authority updates

## Key Challenges & Mitigations

### Challenge 1: Complex Rate Formats
HTS rates can be ad valorem (%), specific ($X/unit), or compound.

**Mitigation:**
- Parse ad valorem rates automatically
- Flag specific/compound rates for manual review
- Store raw rate string alongside parsed value

### Challenge 2: Chapter 99 Complexity
Chapter 99 notes are complex legal text, not machine-readable.

**Mitigation:**
- Manually curate authority_mapping.yaml
- Update mappings when new proclamations issued
- Use footnote references as triggers for authority lookup

### Challenge 3: Federal Register Access
API access issues observed during exploration.

**Mitigation:**
- Manual curation of key proclamations
- Cache proclamation data locally
- Use effective dates from proclamation text

### Challenge 4: Country Exemptions
Exemptions change (USMCA negotiations, bilateral deals).

**Mitigation:**
- Separate exemption rules from base authority rules
- Date-stamp exemption changes
- Support per-country overrides

## Validation Strategy

1. **Unit Tests:** Rate parsing, authority mapping, stacking rules
2. **Integration Tests:** Compare output to Tariff-ETRs scenarios
3. **Regression Tests:** Ensure consistent output across code changes
4. **Manual Validation:** Spot-check rates against official HTS

## Success Criteria

1. Daily snapshots capture all current tariff rates by product × country
2. Changes are correctly attributed to authorities
3. Export format is 100% compatible with Tariff-Model config
4. System handles new HTS revisions without code changes
5. Manual authority updates take < 30 minutes

## Next Steps

1. **Approve this proposal** or request modifications
2. **Curate Chapter 99 mapping** - This is the critical manual input
3. **Begin Phase 1 implementation** - HTS parser and core infrastructure
4. **Test with 2025 baseline** - Validate against current Tariff-Model scenarios
