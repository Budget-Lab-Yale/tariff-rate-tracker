# Policy Timing: Announcement vs. HTS Effective Dates

The tracker uses USITC Harmonized Tariff Schedule (HTS) revision dates as the effective date for each tariff change. In most cases this aligns with the legal effective date of the policy. However, several policies have gaps between announcement, legal effective date, and HTS publication. This document catalogs those gaps for transparency and to support users who want to adjust dates.

## How to use this document

The `config/revision_dates.csv` file maps each HTS revision to its `effective_date` (HTS publication) and `policy_effective_date` (legal effective date of the underlying proclamation/EO, when different). To model a policy as effective on its legal date rather than its HTS date, users can swap these columns or use the `policy_effective_date` column in the daily series builder.

## Legal sources

| Revision | Policy | Legal Authority | Source |
|---|---|---|---|
| rev_3 | Fentanyl surcharges (CA/MX/CN) | EOs 14193, 14194, 14195 (Feb 1, 2025) | [White House Fact Sheet](https://www.whitehouse.gov/fact-sheets/2025/02/fact-sheet-president-donald-j-trump-imposes-tariffs-on-imports-from-canada-mexico-and-china/) |
| rev_6 | 232 Autos (25%) | Proclamation 10908 (Mar 26, 2025) | [Federal Register 90 FR 14705](https://www.federalregister.gov/documents/2025/04/03/2025-05930/adjusting-imports-of-automobiles-and-automobile-parts-into-the-united-states) |
| rev_7 | IEEPA Phase 1 reciprocal | EO 14257 (Apr 2, 2025) | [Federal Register 90 FR 15269](https://www.federalregister.gov/documents/2025/04/07/2025-06063/regulating-imports-with-a-reciprocal-tariff-to-rectify-trade-practices-that-contribute-to-large-and) |
| rev_16 | 232 steel/aluminum 50% | Proclamation 10947 (Jun 3, 2025) | [Federal Register 90 FR 24199](https://www.federalregister.gov/documents/2025/06/09/2025-10524/adjusting-imports-of-aluminum-and-steel-into-the-united-states) |
| rev_17 | 232 Copper (50%) | Proclamation (Jul 30, 2025) | [Federal Register](https://www.federalregister.gov/documents/2025/08/05/2025-14893/adjusting-imports-of-copper-into-the-united-states) |
| rev_18 | IEEPA Phase 2 reciprocal | EO 14326 (Jul 31, 2025) | [Federal Register 90 FR 37963](https://www.federalregister.gov/documents/2025/08/06/2025-15010/further-modifying-the-reciprocal-tariff-rates) |
| rev_26 | MHD vehicles/buses 232 | Proclamation 10984 (Oct 17, 2025) | [Federal Register 90 FR 48451](https://www.federalregister.gov/documents/2025/10/22/2025-19639/adjusting-imports-of-medium--and-heavy-duty-vehicles-medium--and-heavy-duty-vehicle-parts-and-buses) |
| 2026_rev_4 | SCOTUS invalidation of IEEPA | *Learning Resources, Inc. v. Trump*, 607 U.S. ___ (2026), Nos. 24-1287 & 25-250 (Feb 20, 2026) | [Supreme Court Opinion](https://supreme.justia.com/cases/federal/us/607/24-1287/) |
| 2026_rev_4 | Section 122 (10% blanket) | EO "Ending Certain Tariff Actions" (Feb 20, 2026); Proclamation (Feb 20, 2026) | [White House](https://www.whitehouse.gov/presidential-actions/2026/02/ending-certain-tariff-actions/); [Federal Register](https://www.federalregister.gov/documents/2026/02/25/2026-03832/ending-certain-tariff-actions) |

## Timing discrepancy log

| Policy | Announced / Signed | Legal Effective Date | HTS Revision Date | Gap | Notes |
|---|---|---|---|---|---|
| **Fentanyl surcharges (CA/MX/CN)** | Feb 1, 2025 (EOs signed) | Feb 4, 2025 (12:01am ET) | Feb 4, 2025 (rev_3) | **None** | CA/MX initially suspended Feb 3; reimposed Feb 4. HTS aligned. |
| **232 Autos (25%)** | Mar 26, 2025 (Proclamation 10908) | Apr 3, 2025 (vehicles); May 3 (parts) | Mar 12, 2025 (rev_6) | **HTS early by 22 days** | HTS revision published before the proclamation effective date. Tracker assigns rate from rev_6 effective date (Mar 12), but the legal tariff didn't apply until Apr 3. |
| **Liberation Day (IEEPA Phase 1)** | Apr 2, 2025 (EO 14257) | Apr 5, 2025 (12:01am ET for most) | Apr 2, 2025 (rev_7) | **HTS 3 days early** | EO signed Apr 2; 10% baseline effective Apr 5; country-specific rates effective Apr 9. HTS published the full rate schedule at rev_7 (Apr 2). |
| **China escalation (84%, 125%)** | Apr 3-5, 2025 | Same day | Apr 3 (rev_8), Apr 5 (rev_9) | **None** | Rapid escalation; HTS revised within hours. |
| **Geneva pause** | Apr 12, 2025 (announced) | Apr 14, 2025 | Apr 14, 2025 (rev_12) | **None** | HTS aligned with effective date. |
| **232 steel/aluminum 50%** | Jun 3, 2025 (Proclamation 10947) | Jun 4, 2025 (12:01am ET) | Jun 6, 2025 (rev_16) | **HTS 2 days late** | 9903.81.87 (steel 50%) and 9903.85.02 (aluminum 50%) first appear in rev_16. Tariff legally effective Jun 4 but tracker assigns from Jun 6. |
| **CA fentanyl increase (25%→35%)** | ~Late Jun 2025 | Jul 1, 2025 | Jul 1, 2025 (rev_17) | **None** | HTS aligned. |
| **232 Copper (50%)** | Jul 30, 2025 (Proclamation) | Aug 1, 2025 (12:01am ET) | Jul 1, 2025 (rev_17) | **HTS early by 31 days** | Copper 232 entries (9903.78.xx) appear in rev_17 (Jul 1) but the legal effective date is Aug 1. Tracker overstates copper 232 for Jul 1-31. |
| **EU-US deal (15% floor)** | Jul 27, 2025 (Turnberry) | Implemented via Phase 2 (Aug 7) | Aug 7, 2025 (rev_18) | **11-day announcement lag** | Deal announced Jul 27; HTS implements via Phase 2 entries Aug 7. |
| **IEEPA Phase 2 reciprocal** | Jul 31, 2025 (EO 14326 signed) | Aug 7, 2025 (12:01am ET) | Aug 7, 2025 (rev_18) | **None** | HTS aligned with legal effective date. 7-day gap from signing. |
| **India EO (+25%)** | ~Aug 18, 2025 | Aug 20, 2025 | Aug 20, 2025 (rev_20) | **None** | HTS aligned. |
| **Japan floor (15%)** | ~Sep 2025 (deal announced) | Sep 12, 2025 | Sep 12, 2025 (rev_23) | **None** | HTS aligned. |
| **MHD vehicles/buses 232 (25%)** | Oct 17, 2025 (Proclamation 10984) | Nov 1, 2025 (12:01am ET) | Oct 6, 2025 (rev_26) | **HTS early by 26 days** | 9903.74.xx entries appear in rev_26 (Oct 6) but legal effective date is Nov 1. Tracker overstates MHD 232 for Oct 6-31. |
| **S. Korea floor (15%)** | ~Nov 2025 | Nov 15, 2025 | Nov 15, 2025 (rev_32) | **None** | HTS aligned. |
| **Semiconductor tariffs (25%)** | ~Jan 2026 | Jan 16, 2026 | Jan 16, 2026 (2026_rev_1) | **None** | HTS aligned. |
| **SCOTUS invalidation of IEEPA** | Feb 20, 2026 (*Learning Resources v. Trump*, 6-3) | Feb 20, 2026 (immediate) | Feb 24, 2026 (2026_rev_4) | **HTS 4 days late** | Court ruled Feb 20; IEEPA tariffs legally void immediately. CBP implemented termination at 12:00am ET Feb 24. Tracker shows IEEPA rates active Feb 20-23. |
| **Section 122 (10% blanket)** | Feb 20, 2026 (EO signed same day as ruling) | Feb 24, 2026 (12:01am ET) | Feb 24, 2026 (2026_rev_4) | **None** | S122 HTS aligned with CBP implementation. |

## Summary of material timing gaps

Three categories of discrepancy:

### 1. HTS published before legal effective date (tracker overstates)
- **232 Autos** (Proclamation 10908): HTS Mar 12 vs. effective Apr 3 (22 days early)
- **232 Copper**: HTS Jul 1 vs. effective Aug 1 (31 days early)
- **MHD 232** (Proclamation 10984): HTS Oct 6 vs. effective Nov 1 (26 days early)

These cause the tracker to apply tariffs before they legally took effect. The ETR impact is modest (232 autos ~0.5pp, copper ~0.2pp, MHD ~0.1pp) because these products are a small share of total imports.

### 2. HTS published after legal effective date (tracker understates)
- **232 steel/aluminum 50%** (Proclamation 10947): Effective Jun 4 vs. HTS Jun 6 (2 days late)
- **SCOTUS ruling** (*Learning Resources v. Trump*): Ruling Feb 20 vs. HTS Feb 24 (4 days late)

The SCOTUS gap is the most material: the tracker shows ~15% ETR for Feb 20-23 when the legal rate was ~11% (IEEPA already void).

### 3. Announcement-to-enactment gaps (tracker correct, but different from SOT reports)
- **Liberation Day** (EO 14257): Announced Apr 2, most rates effective Apr 5-9
- **Phase 2** (EO 14326): Signed Jul 31, effective Aug 7
- **EU deal**: Announced Jul 27, enacted Aug 7

These are not tracker errors — the tracker correctly follows legal effective dates. But comparison publications (e.g., Budget Lab State of Tariffs) often model announced policy immediately, creating apparent gaps.

## Infrastructure for date adjustment

The `config/revision_dates.csv` now includes a `policy_effective_date` column alongside the existing `effective_date` (HTS publication date). This column is populated for the 7 revisions where the legal effective date differs from the HTS date.

To create an alternative series using legal effective dates:

1. Copy `config/revision_dates.csv` to a new file (e.g., `config/revision_dates_policy.csv`)
2. For rows with a `policy_effective_date`, overwrite `effective_date` with that value
3. Run the pipeline with the alternative config: modify `00_build_timeseries.R` to load your custom dates file

A future enhancement could add a `--use-policy-dates` flag to the build orchestrator to automate this swap.
