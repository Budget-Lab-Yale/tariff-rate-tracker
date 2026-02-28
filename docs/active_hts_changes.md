# Active HTS Changes

Changes from Federal Register notices that override or supplement HTS JSON data. These entries track policy changes that have been enacted but may not yet be reflected in the HTS JSON archives downloaded from USITC.

When USITC publishes an HTS revision incorporating a change listed here, the override becomes redundant and the entry can be moved to the "Resolved" section.

---

## 1. US-Switzerland-Liechtenstein Framework (15% floor)

**Source**: [90 FR 59281](https://www.federalregister.gov/documents/2025/12/18/2025-23316), FR Doc. 2025-23316, December 18, 2025

**Authority**: Executive Order 14346 (September 5, 2025), implementing the Framework for a United States-Switzerland-Liechtenstein Agreement on Fair, Balanced, and Reciprocal Trade

**Effective**: November 14, 2025 (retroactive)

**Summary**: Replaces the +39% surcharge (Switzerland) and +15% surcharge (Liechtenstein) with a 15% floor structure, matching the EU/Japan/South Korea pattern. Products with base rate >= 15% pay no additional duty; products with base rate < 15% are raised to 15%. Three categories of products are fully exempt: PTAAP agricultural/natural resources, civil aircraft, and non-patented pharmaceuticals.

**HTS modifications**:

| Action | Code | Description |
|--------|------|-------------|
| Terminate | 9903.02.36 | Liechtenstein +15% surcharge |
| Terminate | 9903.02.58 | Switzerland +39% surcharge |
| New | 9903.02.82 | Switzerland passthrough (base >= 15%) |
| New | 9903.02.83 | Switzerland 15% floor (base < 15%) |
| New | 9903.02.84 | Switzerland PTAAP exempt (agricultural/natural resources) |
| New | 9903.02.85 | Switzerland civil aircraft exempt |
| New | 9903.02.86 | Switzerland non-patented pharma exempt |
| New | 9903.02.87 | Liechtenstein passthrough (base >= 15%) |
| New | 9903.02.88 | Liechtenstein 15% floor (base < 15%) |
| New | 9903.02.89 | Liechtenstein PTAAP exempt |
| New | 9903.02.90 | Liechtenstein civil aircraft exempt |
| New | 9903.02.91 | Liechtenstein non-patented pharma exempt |
| Modify | 9903.01.25 | Universal baseline range updated: 9903.02.81 -> 9903.02.91 |

**Pipeline handling** (updated Feb 2026):

1. **Extraction range expanded**: `extract_ieepa_rates()` range extended from 9903.02.02-81 to 9903.02.02-91, so native Swiss floor entries (9903.02.82-91) are parsed when present in HTS JSON. Confirmed present in `2026_basic`.

2. **Surcharge-to-floor override**: Switzerland (4419) and Liechtenstein (4411) in `floor_countries` config. Override in `06_calculate_rates.R` converts surcharge → floor for revisions where the HTS JSON only has the old surcharge entries (.02.36/.58). When native floor entries exist (and win rate selection over surcharges), the override is a no-op.

3. **Date-bounded**: Override governed by `swiss_framework` config in `policy_params.yaml`. Only applies when revision effective_date is within the framework window (Nov 14, 2025 → March 31, 2026). If `finalized: true`, no expiry constraint. If framework lapses, override automatically stops — surcharge rates resume.

4. **Product exemptions**: 1,681 exempt products (PTAAP, civil aircraft, pharma) in `resources/floor_exempt_products.csv`, applied in step 2 of rate calculation.

**Conditional expiry**: The Framework agreement must be finalized by March 31, 2026. If not, rates revert to +39% (Switzerland) / +15% (Liechtenstein) surcharges. When confirmed, set `swiss_framework.finalized: true` in `config/policy_params.yaml` to make the floor treatment permanent.

---

## Resolved

_(None yet)_
