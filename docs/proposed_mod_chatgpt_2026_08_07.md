# Proposed implementation: HTS 2026 Revision 15 and polysilicon Section 232 action

**Plan date:** 2026-08-07
**Target branch:** `master` (the repository's primary branch)
**Status:** Proposed; no implementation performed by this plan

## Objective

Update the tariff-rate tracker for:

1. HTS 2026 Revision 15, including the intervening Revision 13 and Revision 14 snapshots that are not yet on `master`.
2. The August 6, 2026 proclamation, *Adjusting Imports of Polysilicon and its Derivatives into the United States*, effective December 4, 2026.

The work should preserve the repository's revision-by-revision time series, distinguish HTS publication dates from legal policy dates, and avoid converting the new minimum-import-price program into an unsupported flat ad valorem rate.

## Sources reviewed

- [USITC HTS archive](https://www.usitc.gov/harmonized_tariff_information/hts/archive/list?page=0)
- [HTS 2026 Revision 13 JSON](https://www.usitc.gov/sites/default/files/tata/hts/hts_2026_revision_13_json.json)
- [HTS 2026 Revision 14 JSON](https://www.usitc.gov/sites/default/files/tata/hts/hts_2026_revision_14_json.json)
- [HTS 2026 Revision 15 JSON](https://www.usitc.gov/sites/default/files/tata/hts/hts_2026_revision_15_json.json)
- [Commerce notice reducing the UK patented-pharmaceutical tariff](https://www.federalregister.gov/documents/2026/08/04/2026-15799/notice-of-reduction-of-tariffs-on-patented-pharmaceuticals-and-pharmaceutical-ingredients-for)
- [White House polysilicon proclamation](https://www.whitehouse.gov/presidential-actions/2026/08/adjusting-imports-of-polysilicon-and-its-derivatives-into-the-united-states/)
- [Polysilicon proclamation Annex I](https://www.whitehouse.gov/wp-content/uploads/2026/08/ANNEX-I.pdf)
- [Polysilicon proclamation Annex II](https://www.whitehouse.gov/wp-content/uploads/2026/08/Annex-II.pdf)

## Findings

### The repository is three HTS snapshots behind

`master` currently ends at `2026_rev_12`. Revision 15 therefore cannot be ingested as a single isolated snapshot. Revisions 13 and 14 must also be preserved unless a deliberate, documented decision is made to collapse legally distinct HTS intervals.

The USITC release API identifies Revision 15 as the current release with a schedule start date of August 3, 2026. The relevant sequence is:

| Revision | Schedule date | Substantive content |
|---|---:|---|
| `2026_rev_13` | 2026-07-28 | Codifies the already-modeled forced-labor Section 301 action |
| `2026_rev_14` | 2026-07-31 | Adds pharmaceutical Section 232 headings and updates related Brazil and forced-labor exclusions |
| `2026_rev_15` | 2026-08-03 | Reduces the UK patented-pharmaceutical additional tariff from 10 percent to zero |

There is a minor date-display discrepancy for Revision 13 between USITC surfaces: the release API reports a July 28 start date, while the archive display has shown July 29. The existing Revision 13 branch uses July 28. Confirm the desired schedule date against the release API immediately before implementation and record the choice in the review note.

### Exact HTS JSON changes

The official JSON snapshots produce the following diffs:

| Comparison | Total records | Chapter 99 result | Chapters 1-97 |
|---|---:|---|---|
| Rev. 12 -> Rev. 13 | 35,779 in Rev. 13 | 101 headings added; 612 total | No HTS8/HTS10 churn or substantive rate changes |
| Rev. 13 -> Rev. 14 | 35,789 in Rev. 14 | 10 headings added; 3 descriptions changed; 622 total | Byte-identical |
| Rev. 14 -> Rev. 15 | 35,789 in Rev. 15 | No additions/removals; one rate change and one other description change | Byte-identical |

Revision 14 adds pharmaceutical headings `9903.04.60` through `9903.04.69`. It also adds patented pharmaceutical articles to the Section 232-overlap exclusions in:

- `9903.05.07`, for the Brazil Section 301 action.
- `9903.05.90`, for the forced-labor Section 301 action.

Revision 15 changes `9903.04.63`, covering UK patented pharmaceuticals, from MFN plus 10 percent to MFN plus zero percent. Commerce states that the zero rate is legally effective for entries on or after July 31, 2026, even though the HTS snapshot begins August 3.

### Existing Revision 13 work

The remote branch `origin/feat/ingest-2026-rev13` already contains reviewed Revision 13 work. Its relevant commits are:

- `441043a`: Revision 13 archive, revision row, and review.
- `df0a938`: Revision 13 candidate-build configuration.
- `eac9654`: forced-labor follow-up items.

The branch diverged from `master` before the latest `master` commit. It also contains a transient PR-body commit and an unrelated `CLAUDE.md` cleanup. Prefer selectively applying the relevant commits rather than merging the entire branch without review.

### Polysilicon proclamation: operative treatment

The proclamation is effective for entries on or after 12:01 a.m. eastern time on December 4, 2026.

#### Minimum import prices

| Product | HTS scope | Minimum import price |
|---|---|---:|
| Raw polysilicon | `2804.61.0000` | $21/kg |
| Polysilicon ingots and wafers | `3818.00.0020`, `.0040`, `.0045`, `.0050`, `.0091` | $100/kg |
| Solar cells | `8541.42.0010`, `.0080` | $0.22/watt |
| Solar modules | `8541.43.0010`, `.0080` | $0.38/watt |

The corresponding MIP headings are `9903.45.33` through `9903.45.36`.

If qualifying documentation is submitted and entered value is below the applicable MIP, the specific duty equals the gap between entered value and the MIP. If the importer fails to submit the required documentation, the merchandise is subject to a specific tariff equal to the applicable MIP. Pre-August 6 fixed-term contracts receive specified transitional treatment.

#### Additional ad valorem tariff

Raw polysilicon is subject to the MIP but is not included in the additional ad valorem heading. Ingots, wafers, cells, and modules receive:

- A default additional rate of 15 percent under `9903.45.30`.
- A total-duty floor of 15 percent under `9903.45.31` for products of the EU, Japan, South Korea, Taiwan, Switzerland, and Liechtenstein.
- An additional rate of 10 percent under `9903.45.32` for products of the United Kingdom.

The MIP and ad valorem headings can both apply to the same entry. There is no general USMCA exemption for Canada or Mexico.

#### Other mechanics

The proclamation also provides:

- Company-specific tariff relief for approved onshoring plans.
- Potential future modifications for partners adopting substantially equivalent MIPs.
- Manufacturing drawback for qualifying products from designated trade-agreement partners when the polysilicon content is entirely from such partners.
- Privileged-foreign-status treatment in foreign-trade zones.
- Enforcement provisions for inaccurate certifications and stockpiling.

These mechanics cannot all be inferred from HTS10 and country alone. The implementation must distinguish what the rate panel can model from what requires importer-, contract-, use-, or company-level information.

## Proposed implementation

### Phase 1: integrate Revision 13

1. Apply the reviewed Revision 13 ingest work from `origin/feat/ingest-2026-rev13` onto current `master`.
2. Prefer the relevant commits (`441043a`, `df0a938`, and, if still wanted, `eac9654`) over an unreviewed whole-branch merge.
3. Resolve any conflict in `config/revision_dates.csv` without disturbing the current Revision 12 event description.
4. Retain the Revision 13 review finding that the snapshot is rate-neutral because the forced-labor action is already turned on by configuration at the July 24 legal boundary.
5. Confirm the Revision 13 archive has 35,779 records and 612 Chapter 99 entries.

Expected result: one new HTS snapshot partition, no new policy boundary, and no change to any pre-Revision 13 partition.

### Phase 2: ingest Revisions 14 and 15

Add the following archives:

- `data/hts_archives/hts_2026_rev_14.json.gz`
- `data/hts_archives/hts_2026_rev_15.json.gz`

Add corresponding rows to `config/revision_dates.csv`:

- `2026_rev_14` at the HTS schedule date of 2026-07-31.
- `2026_rev_15` at the HTS schedule date of 2026-08-03.

The Revision 15 policy event should explicitly record that the UK rate change is legally effective July 31. Do not move the Revision 15 snapshot itself back to July 31; the July 31 interval belongs to Revision 14. The existing `2026-07-31` boundary can carry policy-specific logic where necessary.

Create a candidate configuration such as:

- `config/build/rev15_ingest.yaml`

The candidate build should publish to a validation directory, require weights, run verification, and not repoint `latest`.

### Phase 3: correct the UK pharmaceutical configuration

`config/policy_params.yaml` currently includes:

```yaml
country_rates:
  CTY_UK: 0.10
```

Change the UK pharmaceutical country rate to zero and update the adjacent comments and provenance. Leaving `target_total.CTY_UK: 0` unchanged is not sufficient: `apply_pharma_232_adjustments()` takes the maximum of the country surcharge and the floor, so the explicit 10 percent surcharge would continue to bind.

The repository already has a July 31 boundary and date-gated patented-pharmaceutical exclusions for the Brazil and forced-labor Section 301 programs. Verify those paths against Revision 14 rather than introducing a duplicate mechanism.

The current model activates the broad pharmaceutical layer on September 29. Any July 31 company-specific pharmaceutical activation that is not represented by the existing aggregate applicability assumptions should remain an explicit statutory deviation unless importer/company data are added.

### Phase 4: add a polysilicon Section 232 program

Create a product resource, preferably with treatment metadata rather than a bare list:

- `resources/s232_polysilicon_products.csv`

Suggested schema:

| Column | Purpose |
|---|---|
| `hts10` | Normalized ten-digit HTS code |
| `product_group` | `raw`, `wafer`, `cell`, or `module` |
| `mip_amount` | 21, 100, 0.22, or 0.38 |
| `mip_unit` | `kg` or `watt` |
| `advalorem_eligible` | Whether `9903.45.30`-.32 applies |
| `source_heading` | Applicable `9903.45.xx` heading(s) |
| `effective_date` | `2026-12-04` |

Add a `polysilicon` entry under `section_232_headings` in `config/policy_params.yaml` with:

- `effective_date: '2026-12-04'`
- Default additional rate of 15 percent for ad valorem-eligible products.
- UK additional rate of 10 percent.
- A 15 percent post-MFN total-duty floor for the EU, Japan, South Korea, Taiwan, Switzerland, and Liechtenstein.
- `usmca_exempt: false`.
- An initially zero onshoring exemption share unless a defensible calibration is added.

Raw polysilicon must not receive the 15 percent ad valorem rate.

### Phase 5: register and activate the new program

Because the proclamation takes effect after Revision 15 and the HTS does not yet contain headings `9903.45.30`-.36, use the same register-then-activate architecture used for pharmaceuticals.

Likely changes include:

- `src/pipeline/05_parse_policy_params.R`
  - Resolve a date-gated polysilicon program rate.
  - Preserve the program as dormant before December 4.
- `src/model/authority_adapter.R`
  - Register a `polysilicon_source` Section 232 program.
  - Expose its rate and product-scope configuration to the calculator.
- `src/pipeline/06_calculate_rates.R`
  - Add a polysilicon activation gate.
  - Accumulate polysilicon product matches separately from other Section 232 headings.
  - Apply the country-specific 15 percent floor and UK rate.
  - Add any computed MIP AVE to, rather than replace or maximize against, the ad valorem component.
- `config/policy_params.yaml`
  - Add `2026-12-04` to `boundary_overrides`.

Prefer generalizing `apply_pharma_232_adjustments()` into a reusable heading-country adjustment helper if this can be done without changing existing pharmaceutical results. Otherwise, add a tightly scoped polysilicon adjustment function and test both paths.

The existing heading aggregation takes the maximum when a product appears in multiple heading programs. That is appropriate for many overlapping Section 232 programs but not for the two cumulative polysilicon components. Apply the MIP AVE in a separate additive step after the ad valorem heading rate has been resolved.

### Phase 6: represent the MIP without inventing a flat rate

The tracker currently publishes ad valorem rates and its canonical import-weight file contains import value but not quantity. A specific duty expressed per kilogram or watt cannot be converted correctly using the current schema alone.

Recommended implementation:

1. Add a builder, for example `scripts/build_s232_polysilicon_mip_aves.R`.
2. Read Census consumption-import value and quantity fields for the covered HTS10 lines.
3. Use kilograms for `2804.61` and `3818.00` lines.
4. Use the watt reporting quantity for `8541.42` and `8541.43` lines; the HTS JSON reports both number and watts for these provisions.
5. Generate a reproducible HTS10-by-country resource containing import value, relevant quantity, unit value, and calculated MIP-equivalent ad valorem rate.
6. Under a documented baseline assumption that qualifying documentation is submitted, compute:

   ```text
   mip_ave = max(mip_amount * quantity - entered_value, 0) / entered_value
   ```

7. Treat failure-to-document as a separate configurable share because its statutory specific duty differs from the documented-entry treatment.
8. Record the data year and whether customs value is being used as a proxy for the first arm's-length U.S. sale price.

The model's existing 2024 import weights suggest using 2024 quantities for internal consistency, unless a later, complete data year is deliberately adopted for both weights and MIP AVEs.

If quantity data cannot be added in the initial implementation, ship the ad valorem component only and record the MIP as a prominent, quantified-when-possible omission in `docs/statutory_deviations.md`. Do not use an arbitrary flat MIP percentage.

### Phase 7: model or document non-HTS mechanics

The following items need explicit decisions:

| Mechanic | Proposed initial treatment |
|---|---|
| Approved onshoring plans | Parameterize an aggregate exemption share; default to zero pending evidence |
| Pre-August 6 contracts | Document as unmodeled unless contract-level shares can be estimated |
| Failure to submit MIP documentation | Parameterize separately; default documented-entry share to 100 percent |
| Partner adoption of equivalent MIPs | No adjustment until Commerce announces a qualifying arrangement |
| Manufacturing drawback | Document; do not reduce gross entry duties without an export-linked drawback model |
| Foreign-trade-zone status | Document as an entry-timing mechanic unless the panel gains FTZ detail |
| Enforcement and stockpiling restrictions | Outside the rate calculation; preserve in provenance notes |

### Phase 8: documentation

Update:

- `DATA_SOURCES.md`
- `docs/revision_changelog.md`
- `docs/statutory_deviations.md`
- `docs/policy_timing.md`, if needed for the July 31/August 3 and December 4 boundaries
- `src/preflight.R`, to require the new polysilicon product and MIP resources

Add a focused review note, for example:

- `docs/s232/polysilicon_update_2026_08.md`

The note should preserve the proclamation and annex URLs, exact HTS scope, legal effective date, country treatments, MIP conversion method, calibration year, and all unmodeled importer-level mechanics.

## Tests and validation

### Snapshot-ingest assertions

Add checks that establish:

- Revision 13 contains 35,779 records and 612 Chapter 99 entries.
- Revision 14 contains 35,789 records and 622 Chapter 99 entries.
- Revision 15 contains 35,789 records and 622 Chapter 99 entries.
- Revision 14 adds exactly `9903.04.60`-.69 relative to Revision 13.
- Chapters 1-97 are byte-identical across Revisions 13, 14, and 15.
- Revision 15 changes the general rate for `9903.04.63` from `+10%` to `+0%` and introduces no other substantive rate change.

### Pharmaceutical assertions

Test that:

- The UK pharmaceutical Section 232 surcharge resolves to zero after the legal change.
- The July 31 Brazil and forced-labor patented-pharmaceutical exclusions remain active.
- Other pharmaceutical country floors and rates are unchanged.
- Pre-July 31 partitions are identical to the current golden vintage.
- The existing September 29 broad pharmaceutical activation still produces the intended rates.

### Polysilicon assertions

Create `tests/test_s232_polysilicon.R` or equivalent fixtures covering:

- No polysilicon effect before December 4, 2026.
- Raw polysilicon receives the MIP component only.
- Ingots, wafers, cells, and modules receive both applicable components.
- A general-country product receives 15 percent plus its MIP AVE.
- A UK product receives 10 percent plus its MIP AVE.
- An EU/Japan/Korea/Taiwan/Switzerland/Liechtenstein product receives `max(15% - base_rate, 0)` plus its MIP AVE.
- Canada and Mexico are not automatically exempted.
- A product with unit value at or above the MIP receives a zero MIP gap under the documented-entry assumption.
- A product below the MIP receives the correct gap AVE.
- MIP and ad valorem components add rather than take their maximum.
- China Section 301 duties continue to stack as required.
- Onshoring relief does nothing at its default zero share.

Extend:

- `tests/test_boundary_discovery.R` for the December 4 boundary.
- `tests/test_authority_adapter.R` for `polysilicon_source` registration and dormancy.
- `tests/test_rate_calculation.R` for integration and stacking behavior.
- Preflight tests for the new resource files.

### Candidate build and parity

1. Run the local CI smoke-test sequence in unweighted mode.
2. Build the weighted Revision 15 candidate in the configured high-memory environment.
3. Compare candidate artifacts against the current golden vintage:
   - snapshots
   - daily overall
   - daily by authority
   - daily by country
   - daily by category
   - daily by HS
4. Require all partitions before the new boundaries to be identical.
5. Inspect deltas at July 28, July 31, August 3, September 29, and December 4 separately.
6. Do not repoint `latest` until the parity comparison and targeted assertions pass.

## Expected implementation order

1. Integrate the reviewed Revision 13 archive and row.
2. Add Revision 14 and Revision 15 archives and metadata.
3. Correct the UK pharmaceutical rate and validate the July 31 exclusions.
4. Run a Revision 15-only candidate build and parity review.
5. Add the polysilicon product resource and dormant authority program.
6. Add the December 4 activation and ad valorem country treatment.
7. Build and integrate the quantity-based MIP AVE resource.
8. Add tests and statutory-deviation documentation.
9. Run the full weighted candidate build and parity suite.
10. Review the resulting ETR deltas, bless the vintage, and repoint `latest` deliberately.

## Completion criteria

The work is complete when:

- `master` contains all HTS snapshots through Revision 15.
- The Revision 15 UK pharmaceutical rate is zero and correctly dated.
- The polysilicon program activates on December 4 with correct product and country scope.
- The MIP is either represented by a reproducible quantity-based AVE or explicitly excluded with a clear statutory deviation; no arbitrary flat proxy is used.
- All new resources have source provenance and preflight coverage.
- Targeted unit tests and the existing smoke suites pass.
- Weighted parity shows no unintended changes before the relevant boundaries.
- The new vintage is reviewed before `latest` is updated.
