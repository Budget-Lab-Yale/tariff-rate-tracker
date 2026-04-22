# Data Sources and Provenance

This note summarizes the main external inputs used by the Tariff Rate Tracker and how they enter the repository.

It is intended as a practical provenance guide, not legal advice. The repository's [MIT license](LICENSE) applies to the code and original documentation in this repo. External source materials, downloaded archives, and comparison inputs remain subject to their own terms, attribution requirements, and access conditions.

## Core production sources

| Source | Used for | How it appears in this repo |
|---|---|---|
| USITC Harmonized Tariff Schedule JSON archives | Revision-by-revision tariff schedule, product tree, Chapter 99 lines | Downloaded by `src/02_download_hts.R` into `data/hts_archives/`; treated as the core machine-readable tariff source |
| Chapter 99 PDF / related official policy text | Regenerating product lists and exemptions that are not fully exposed in HTS JSON | Used by scraper and maintenance workflows such as `src/scrape_us_notes.R`; some derived resource files are committed |
| `config/policy_params.yaml` plus legal/policy review | Effective dates, authority ranges, and implementation logic where machine-readable sources are incomplete | Maintained in-repo and documented in `docs/methodology.md` and `docs/assumptions.md` |

## Derived or maintained resource files

These files are committed because the tracker depends on them directly, but many are derived from public upstream sources plus repo-specific parsing or curation:

| Resource family | Typical path | Primary role |
|---|---|---|
| Country and concordance tables | `resources/census_codes.csv`, `resources/country_partner_mapping.csv`, `resources/hs10_gtap_crosswalk.csv` | Country dimension, reporting groups, optional weighting links |
| Product exemption and product-list resources | `resources/ieepa_exempt_products.csv`, `resources/floor_exempt_products.csv`, `resources/s301_product_lists.csv`, `resources/s232_derivative_products.csv`, `resources/s232_copper_products.csv`, `resources/s122_exempt_products.csv` | Encode product scope that is not fully recoverable from HTS JSON alone |
| USMCA utilization shares | `resources/usmca_product_shares_*.csv`, `resources/usmca_shares.csv` | Empirical scaling of USMCA exemptions |
| Metal content shares | `resources/metal_content_shares_bea_hs10.csv` | Derivative Section 232 scaling inputs |

When these files are updated, the preferred standard is to document:

- the upstream source
- the extraction or refresh method
- the date or revision context
- any judgment calls or manual cleanups

## External empirical inputs

| Source | Used for | Notes |
|---|---|---|
| USITC DataWeb API | USMCA utilization shares | Optional refresh path through `src/download_usmca_dataweb.R`; requires a user-managed API token in `.env` |
| BEA input-output tables | Metal content estimation | Used to build the committed BEA-based metal-share resource |
| Congressional Budget Office tariff analysis files | Alternative metal-share buckets | Used for optional sensitivity methods documented in `docs/assumptions.md` |

## Comparison and validation inputs

These are not production dependencies for the core series:

| Source | Used for | Repo status |
|---|---|---|
| The Budget Lab Tariff-ETRs repository | Cross-repo validation and config export compatibility | Optional local input via `config/local_paths.yaml`; not required for core builds |
| Tax Policy Center benchmark snapshots | Validation and benchmarking only | Not used to construct production tariff rates; local/private handling may apply |

## Redistribution notes

- The repo is designed so the core logic can run without redistributing every upstream raw file.
- Some large downloaded artifacts are intentionally left out of Git and are recreated locally or in CI.
- Optional comparison inputs should be obtained from their original owners or repositories rather than copied into this repo by default.
- If you reuse or publish derived outputs, cite both this repository and the relevant upstream source institutions where appropriate.

## Where to look next

- Build and setup: [docs/build.md](docs/build.md)
- Methodology: [docs/methodology.md](docs/methodology.md)
- Non-official assumptions: [docs/assumptions.md](docs/assumptions.md)
