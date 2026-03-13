# HTS Revision Changelog

Verified timeline of Chapter 99 policy changes across all 39 HTS revision points (2025 basic through 2026_rev_4). Generated from `src/revision_changelog.R`, which diffs Ch99 entries between consecutive revisions to identify additions, removals, rate changes, and suspensions. Full diff data in `output/changelog/revision_diffs.csv`.

---

## Operational Notes

These are the main policy items that still matter operationally when interpreting the later revisions and the forward extension through the end of 2026.

### Swiss and Liechtenstein framework

The Swiss and Liechtenstein floor framework is represented both by native HTS entries in later revisions and by a date-bounded override for earlier revisions inside the framework window. The governing parameters live in `config/policy_params.yaml` under `swiss_framework`.

### Section 122

Section 122 becomes the post-IEEPA blanket authority in the February 25, 2026 revision sequence. The repo treats it as temporary unless `section_122.finalized` is set to `true`, and enforces expiry in the build, daily outputs, and point-in-time queries.

### Semiconductor tariffs

Semiconductor tariff entries are handled through the normal Chapter 99 parsing path and do not require a separate override layer in the code.

---

## Summary Table

| Revision | Effective | Ch99 | Added | Rate Chg | Suspensions | Policy Event |
|----------|-----------|------|-------|----------|-------------|--------------|
| basic | 2025-01-01 | 447 | — | — | — | Baseline (pre-Trump 2.0) |
| rev_1 | 2025-01-27 | 451 | 4 | 0 | 0 | China IEEPA fentanyl (+10%) |
| rev_2 | 2025-02-01 | 451 | 0 | 0 | 0 | (no Ch99 changes) |
| rev_3 | 2025-02-04 | 459 | 8 | 0 | 0 | CA/MX fentanyl (+25% each), China fentanyl increase (+20%) |
| rev_4 | 2025-03-04 | 475 | 16 | 0 | 1 | USMCA carve-outs, 232 derivatives (steel/aluminum), 301 suspension |
| rev_5 | 2025-03-05 | 475 | 0 | 0 | 1 | (description changes only) |
| rev_6 | 2025-03-12 | 479 | 4 | 0 | 1 | **232 Autos** (9903.94.01-04, 25%) |
| rev_7 | 2025-04-02 | 523 | 44 | 0 | 1 | **IEEPA Phase 1 reciprocal** (9903.01.25-76, country-specific rates) |
| rev_8 | 2025-04-03 | 523 | 0 | 1 | 0 | China IEEPA reciprocal: 34% → 84% |
| rev_9 | 2025-04-05 | 523 | 0 | 1 | 33 | China IEEPA reciprocal: 84% → 125%; **Phase 1 suspended** (90-day pause) |
| rev_10 | 2025-04-09 | 523 | 0 | 0 | 34 | Phase 1 suspension continues (description updates) |
| rev_11 | 2025-04-11 | 525 | 2 | 0 | 34 | 232 Auto parts (9903.94.05-06) |
| rev_12 | 2025-04-14 | 525 | 0 | 1 | 1 | China IEEPA: 125% → 34% (Geneva agreement); **9903.01.63 suspended** |
| rev_13 | 2025-04-22 | 525 | 0 | 0 | 0 | (no Ch99 changes) |
| rev_14 | 2025-05-02 | 535 | 10 | 8 | 35 | **232 rate increase** (steel/aluminum derivatives 25% → 50%) |
| rev_15 | 2025-05-14 | 535 | 0 | 0 | 35 | (Phase 1 suspension continues) |
| rev_16 | 2025-06-06 | 538 | 3 | 0 | 0 | 232 auto parts rates, IEEPA reciprocal entry (9903.96.01) |
| rev_17 | 2025-07-01 | 541 | 3 | 1 | 0 | **CA fentanyl: 25% → 35%**; copper 232 (9903.78.xx); transshipment |
| rev_18 | 2025-08-07 | 619 | 78 | 0 | 0 | **IEEPA Phase 2 reciprocal** (9903.02.01-71); Brazil EO (+40%); Phase 1 unsuspended |
| rev_19 | 2025-08-12 | 619 | 0 | 0 | 0 | (no Ch99 changes) |
| rev_20 | 2025-08-20 | 625 | 6 | 0 | 0 | **India EO** (+25%, 9903.01.84); additional country-specific entries |
| rev_21 | 2025-08-28 | 625 | 0 | 0 | 0 | (no Ch99 changes) |
| rev_22 | 2025-09-03 | 625 | 0 | 0 | 0 | (no Ch99 changes) |
| rev_23 | 2025-09-12 | 632 | 7 | 0 | 0 | **Japan floor** (9903.02.72-73, 15%); 232 auto Japan entries |
| rev_24 | 2025-09-19 | 640 | 8 | 0 | 0 | EU exemption entries (9903.02.74-77); 232 auto EU entries |
| rev_25 | 2025-09-26 | 647 | 7 | 0 | 0 | **Section 122** entries (9903.76.xx) |
| rev_26 | 2025-10-06 | 663 | 16 | 0 | 0 | Copper 232 entries (9903.74.xx); 232 auto additional entries |
| rev_27 | 2025-10-15 | 668 | 5 | 1 | 0 | **301 cranes** (9903.91.12-16, 100%); China fentanyl: 20% → 10% (post-Geneva) |
| rev_28 | 2025-10-22 | 668 | 0 | 0 | 0 | (no Ch99 changes) |
| rev_29 | 2025-10-31 | 669 | 1 | 0 | 0 | Phase 2 exemption entry (9903.02.78) |
| rev_30 | 2025-11-05 | 670 | 1 | 0 | 0 | Additional entry (9903.01.90) |
| rev_31 | 2025-11-12 | 670 | 0 | 0 | 0 | (no Ch99 changes) |
| rev_32 | 2025-11-15 | 680 | 10 | 0 | 0 | **S. Korea floor** (9903.02.79-80, 15%); 232 auto S. Korea entries; Section 122 |
| 2026_basic | 2026-01-01 | 691 | 11 | 0 | 1 | **Switzerland/Liechtenstein floor** (9903.02.82-91, 15%); legacy aircraft-dispute 301 code; China 34% re-suspended |

---

## Detailed Changelog

### `basic` — 2025-01-01 (Baseline)
447 Chapter 99 entries. Pre-Trump 2.0 tariff regime:
- Section 232 steel (ch72-73), aluminum (ch76): 25% since 2018/2020
- Section 301 China (Lists 1-4A, Biden accelerations): 7.5%-100%
- Section 201 safeguards (solar, washers): various rates
- No IEEPA entries

### `rev_1` — 2025-01-27: China IEEPA Fentanyl
**EO 14195** (Feb 1, 2025): IEEPA fentanyl surcharges on China/Hong Kong.
- Added: 9903.01.20 (+10% China/HK), 9903.01.21-23 (exemptions: humanitarian, informational, in-transit)

### `rev_2` — 2025-02-01
No Chapter 99 changes. Product-level updates only.

### `rev_3` — 2025-02-04: CA/MX Fentanyl
**EO 14193/14194**: IEEPA fentanyl surcharges on Canada (+25%) and Mexico (+25%).
- Added: 9903.01.01 (MX +25%), 9903.01.10 (CA +25%), 9903.01.13 (CA energy/minerals +10%)
- Added: 9903.01.24 (China/HK +20%, cumulative with rev_1's +10%)
- Exemptions: humanitarian, informational materials

### `rev_4` — 2025-03-04: USMCA Carve-outs, 232 Derivatives
- Added: 9903.01.04/14 (USMCA duty-free entries for MX/CA)
- Added: 9903.01.05/15 (potash carve-outs at +10% for MX/CA)
- Added: 9903.81.87-93 (steel derivative 232 at 25%)
- Added: 9903.85.02-09 (aluminum derivative 232 at 25%)
- Suspended: 9903.88.16 (301 List 4A provision)

### `rev_5` — 2025-03-05
Description updates only (301 suspension text reformatting).

### `rev_6` — 2025-03-12: 232 Autos
**Proclamation 10908**: Section 232 tariffs on automobiles.
- Added: 9903.94.01 (autos/light trucks 25%, effective Apr 3)
- Added: 9903.94.02-04 (exemptions: USMCA, US content, in-transit)
- *TPC validation date: 2025-03-17*

### `rev_7` — 2025-04-02: IEEPA Phase 1 Reciprocal
**EO 14257** (Liberation Day): Country-specific IEEPA reciprocal tariffs.
- Added: 9903.01.25 (universal 10% baseline)
- Added: 9903.01.26-34 (exemptions: CA, MX, in-transit, insular, humanitarian, etc.)
- Added: 9903.01.43-76 (country-specific rates, 11%-50%)
  - 9903.01.63: China +34%
  - Rates: Cameroon/DRC 11%, Chad/Eq. Guinea 13%, Nigeria 14%, Norway/Venezuela 15%, ...up to 50%

### `rev_8` — 2025-04-03: China Escalation (Round 1)
- Rate change: 9903.01.63 (China): 34% → 84%

### `rev_9` — 2025-04-05: China Escalation (Round 2) + Phase 1 Pause
- Rate change: 9903.01.63 (China): 84% → 125%
- **Suspended: 9903.01.43-76** (all Phase 1 country-specific rates except China's 9903.01.63)
- 90-day pause on non-China reciprocal tariffs; universal 10% baseline (9903.01.25) remains active
- *TPC validation date: 2025-04-17 (rev_10)*

### `rev_10` — 2025-04-09: Phase 1 Pause Continues
- Phase 1 suspension confirmed in updated descriptions (34 entries)
- No new entries or rate changes

### `rev_11` — 2025-04-11: 232 Auto Parts
- Added: 9903.94.05 (auto parts 25%, effective May 3)
- Added: 9903.94.06 (USMCA-content auto parts exempt)

### `rev_12` — 2025-04-14: Geneva Agreement (China De-escalation)
**US-China Geneva Joint Statement**: Mutual tariff reduction.
- Rate change: 9903.01.63 (China): 125% → 34%
- **Suspended: 9903.01.63** (China 34% entry now also suspended)
- Net effect: China falls back to universal 10% baseline (9903.01.25)

### `rev_13` — 2025-04-22
No Chapter 99 changes.

### `rev_14` — 2025-05-02: 232 Rate Increase
**Proclamation 10945**: Section 232 rates doubled for steel/aluminum derivatives.
- Rate changes (8 entries): 9903.81.87-93, 9903.85.02-07: 25% → 50%
- Added: 9903.81.94-99 (new steel 232 entries at 25%)
- Added: 9903.85.12-15 (new aluminum 232 entries)
- Phase 1 suspension continues (35 entries)

### `rev_15` — 2025-05-14
Phase 1 suspension continues. No new entries.

### `rev_16` — 2025-06-06: 232 Auto Parts Rates + UK Deal
- Added: 9903.94.31 (auto parts 7.5% — UK parts floor)
- Added: 9903.94.32 (auto parts 10% — UK vehicles surcharge)
- Added: 9903.96.01 (IEEPA reciprocal entry)
- UK auto deal: vehicles +7.5% surcharge, parts 10% floor (per US-UK trade framework)

### `rev_17` — 2025-07-01: CA Fentanyl Increase + Copper 232
- Rate change: 9903.01.10 (CA fentanyl): 25% → **35%**
- Added: 9903.01.16 (CA transshipment evasion +40%)
- Added: 9903.78.01-02 (copper 232 entries)
- *TPC validation date: 2025-07-17*

### `rev_18` — 2025-08-07: IEEPA Phase 2 Reciprocal
**EO 14323** (Phase 2): Country-specific reciprocal tariffs resume with individual negotiated rates.
- Added: 9903.02.01-71 (71 entries, country-specific Phase 2 rates)
  - Key rates: Brazil +10%, UK +10%, EU +15% (floor), India +25%, Switzerland +39%, China +40% (via 9903.01.77)
  - Floor countries (base < 15% → 15%): EU (9903.02.20), Japan (9903.02.30), S. Korea (9903.02.56), and others at 15%
  - High-rate countries: Laos/Myanmar +40%, Syria +41%, Iraq +35%, Serbia +35%
- Added: 9903.01.77-83 (Brazil EO at +40%, per EO 14323)
- **Unsuspended: Phase 1 entries** (9903.01.43-76 descriptions updated, suspension removed)
- Net: Phase 1 + Phase 2 stack for most countries; China's Phase 1 (9903.01.63) remains suspended
- *TPC validation date: 2025-10-17*

### `rev_19` — 2025-08-12
No Chapter 99 changes.

### `rev_20` — 2025-08-20: India EO
- Added: 9903.01.84 (India +25%, per country-specific EO)
- Added: 9903.01.85-89 (India exemptions and additional entries)
- India total: Phase 1 (suspended) + Phase 2 (+25%, 9903.02.26) + EO (+25%, 9903.01.84) = +50%

### `rev_21-22` — 2025-08-28 to 2025-09-03
No Chapter 99 changes.

### `rev_23` — 2025-09-12: Japan Floor + 232 Auto Deal
**Japan trade framework**: Floor structure replaces surcharge.
- Added: 9903.02.72 (Japan passthrough, base >= 15%)
- Added: 9903.02.73 (Japan 15% floor, base < 15%)
- Added: 9903.94.40-43 (232 auto Japan entries: vehicles 15% floor, parts 15% floor)
- Added: 9903.96.02 (IEEPA reciprocal entry)

### `rev_24` — 2025-09-19: EU Floor Entries + 232 Auto Deal
- Added: 9903.02.74-77 (EU exemption/passthrough entries)
- Added: 9903.94.50-53 (232 auto EU entries: vehicles 15% floor, parts 15% floor)

### `rev_25` — 2025-09-26: Section 122 Entries
- Added: 9903.76.01-04 (Section 122 entries, 10%-25%)
- Added: 9903.76.20-22 (Section 122 entries, 10%-15%)

### `rev_26` — 2025-10-06: Copper 232, More Autos
- Added: 9903.74.01-11 (copper Section 232 entries)
- Added: 9903.94.07 (auto 232), 9903.94.33 (auto 10%)
- Added: 9903.94.44-45, 9903.94.54-55 (232 auto floor entries)

### `rev_27` — 2025-10-15: 301 Cranes + China Fentanyl Reduction
- Added: 9903.91.12 (intermodal chassis 100%), 9903.91.14 (ship-to-shore cranes 100%)
- Added: 9903.91.13/15/16 (crane exemptions)
- Rate change: 9903.01.24 (China/HK fentanyl): 20% → **10%** (post-Geneva reduction)

### `rev_28` — 2025-10-22
No Chapter 99 changes.

### `rev_29` — 2025-10-31
- Added: 9903.02.78 (Phase 2 exemption entry)

### `rev_30` — 2025-11-05
- Added: 9903.01.90 (additional IEEPA entry)

### `rev_31` — 2025-11-12
No Chapter 99 changes.

### `rev_32` — 2025-11-15: S. Korea Floor + 232 Auto Deal
**S. Korea trade framework**: Floor structure.
- Added: 9903.02.79 (S. Korea passthrough, base >= 15%)
- Added: 9903.02.80 (S. Korea 15% floor, base < 15%)
- Added: 9903.02.81 (general exemption entry)
- Added: 9903.76.23 (Section 122 entry)
- Added: 9903.94.60-65 (232 auto S. Korea entries: vehicles 15% floor, parts 15% floor)
- *TPC validation date: 2025-11-17*

### `2026_basic` — 2026-01-01: Switzerland/Liechtenstein Floor
**EO 14346** (per 90 FR 59281): US-Switzerland-Liechtenstein trade framework.
- Added: 9903.02.82-83 (Switzerland passthrough + 15% floor)
- Added: 9903.02.84-86 (Switzerland exemptions: PTAAP, aircraft, pharma)
- Added: 9903.02.87-88 (Liechtenstein passthrough + 15% floor)
- Added: 9903.02.89-91 (Liechtenstein exemptions)
- Added: 9903.89.01 (legacy aircraft-dispute Section 301 code, rate = 0%)
- Suspended: 9903.01.63 (China +34%, re-confirmed suspended)

### `2026_rev_1` — 2026-01-16: Semiconductor Tariffs
**Semiconductor tariffs (US Note 39)**: New subchapter for semiconductor articles.
- Added: 9903.79.01 (semiconductor articles, 25%)
- Added: 9903.79.02-09 (exemptions: transit, USMCA, country-specific)
- 19 description changes

### `2026_rev_2` — 2026-01-30
No Chapter 99 changes. +153 product line additions.

### `2026_rev_3` — 2026-02-12: Argentina Beef Quota
- Added: 9903.54.01 (Argentina beef quota, no rate change)
- 6 description changes
- Phase 1 entries grew from 85 to 90 (5 unsuspensions)

### `2026_rev_4` — 2026-02-25: Section 122 Phase 3
**Section 122 Phase 3** (US Note 2 subdivision (aa)): 10% blanket on all countries.
- Added: 9903.03.01 (10% blanket on all countries)
- Added: 9903.03.02-11 (exemptions: transit, IEEPA exempt, civil aircraft, 232, CA/MX, CAFTA-DR, donations, informational materials)
- 14 description changes

---

## Key Policy Milestones

| Date | Event | Revisions |
|------|-------|-----------|
| 2025-01-27 | China IEEPA fentanyl (+10%) | rev_1 |
| 2025-02-04 | CA/MX fentanyl (+25% each) | rev_3 |
| 2025-03-04 | USMCA carve-outs, 232 derivatives | rev_4 |
| 2025-03-12 | 232 Autos (25%) | rev_6 |
| 2025-04-02 | **Liberation Day**: IEEPA Phase 1 reciprocal (10%-50%) | rev_7 |
| 2025-04-05 | Phase 1 suspended (90-day pause); China escalated to 125% | rev_9 |
| 2025-04-14 | **Geneva Agreement**: China de-escalated to 10% baseline | rev_12 |
| 2025-05-02 | 232 derivatives doubled (25% → 50%) | rev_14 |
| 2025-07-01 | CA fentanyl increased to 35% | rev_17 |
| 2025-08-07 | **Phase 2 reciprocal** (country-specific, 71 entries) | rev_18 |
| 2025-08-20 | India EO (+25%) | rev_20 |
| 2025-09-12 | Japan floor (15%) + 232 auto deal | rev_23 |
| 2025-09-19 | EU floor entries + 232 auto deal | rev_24 |
| 2025-10-06 | Copper 232 | rev_26 |
| 2025-10-15 | 301 cranes (100%); China fentanyl reduced to 10% | rev_27 |
| 2025-11-15 | S. Korea floor (15%) | rev_32 |
| 2026-01-01 | Switzerland/Liechtenstein floor (15%) | 2026_basic |
| 2026-01-16 | Semiconductor tariffs (25%; 9903.79) | 2026_rev_1 |
| 2026-02-12 | Argentina beef quota | 2026_rev_3 |
| 2026-02-25 | **Section 122 Phase 3** (10% blanket; 9903.03) | 2026_rev_4 |

## Authority Count Evolution

| Revision | 232 | 301 | IEEPA | 201 | Other | Total |
|----------|-----|-----|-------|-----|-------|-------|
| basic | 220 | 103 | 2 | 20 | 102 | 447 |
| rev_7 | 236 | 103 | 2 | 20 | 162 | 523 |
| rev_14 | 248 | 103 | 2 | 20 | 162 | 535 |
| rev_18 | 250 | 103 | 3 | 20 | 243 | 619 |
| rev_32 | 270 | 108 | 4 | 20 | 278 | 680 |
| 2026_basic | 270 | 109 | 4 | 20 | 288 | 691 |
| 2026_rev_1 | 270 | 109 | 4 | 20 | 297 | 700 |
| 2026_rev_4 | 270 | 109 | 4 | 20 | 309 | 712 |

---

## Notes

1. **Phase 1 suspension (rev_9-17)**: All country-specific Phase 1 entries (9903.01.43-76) were suspended during the 90-day pause. The universal 10% baseline (9903.01.25) remained active throughout.

2. **China IEEPA trajectory**: +10% (rev_1) → +34% (rev_7) → +84% (rev_8) → +125% (rev_9) → +34% (rev_12, Geneva) → suspended/10% baseline (rev_12+). China's Phase 2 rate is via 9903.01.77 at +40% (EO 14323 / Brazil EO section).

3. **Floor country pattern**: EU (rev_18/24), Japan (rev_23), S. Korea (rev_32), Switzerland/Liechtenstein (2026_basic). Each gets passthrough (base >= 15%) + floor (base < 15% → 15%) + exemption entries.

4. **"Other" authority**: The `classify_authority()` function classifies IEEPA Phase 1 (9903.01.xx) and Phase 2 (9903.02.xx) entries as "other" rather than "ieepa_reciprocal". The IEEPA reciprocal count reflects only 9903.90/93/95/96 entries, not the full IEEPA range. The extraction pipeline (`05_parse_policy_params.R`) correctly handles the full ranges.

5. **TPC date gaps**: rev_18 (effective 2025-08-07) is validated against TPC date 2025-10-17 — a 2+ month gap. Policy changes between these dates (revisions 19-27) may cause discrepancies. See `config/revision_dates.csv` for the full date mapping. The `tpc_policy_revision` column maps each validation row to the correct policy snapshot (e.g., rev_10 validates against rev_7's rates).

6. **Bug fixes (2026-03-13)**: Three high-priority fixes applied to the stacking and rate-assignment logic:
   - **Fentanyl stacking on 232 products**: `apply_stacking_rules()` and `compute_net_authority_contributions()` in `helpers.R` were incorrectly scaling fentanyl by `nonmetal_share` for non-China 232 products (zeroing fentanyl on full-metal items). Fixed to stack fentanyl in full, matching the China path.
   - **Country alias codes**: Myanmar (5560→5460), Macau (5850→5660), Cote d'Ivoire (7230→7480) were mapped to wrong Census codes in `05_parse_policy_params.R`.
   - **232 light-truck gate**: `06_calculate_rates.R` used `autos_light` instead of `autos_light_trucks` in its heading gates, causing light-truck prefixes to bypass the Ch99-activation check.

7. **Additional fixes (2026-03-13)**:
   - **Country applicability fail-closed**: `check_country_applies()` now returns `FALSE` for unknown/NA `country_type` values, preventing unmatched Ch99 descriptions from applying to all countries.
   - **Empty revision early return**: Removed the `nrow(rates) == 0` early return in `calculate_rates_for_revision()`. Blanket-authority steps (IEEPA, 232, 301, S122) now populate rows even when the footnote seed is empty.
   - **Section 301 scope**: Excluded `rate_301` from non-China branches in `apply_stacking_rules()` so stacking matches the decomposition.
   - **Auto deal vs blanket 232**: `extract_section232_rates()` no longer falls back to `max(deal_rate)` as a global auto tariff when only country-specific deal entries exist. Non-deal countries correctly stay at zero.
   - **All-pairs denominator**: Daily aggregates now report both `*_exposed` (sparse panel) and `*_all_pairs` (full Cartesian product) means. Reporting default is `*_all_pairs`.
   - **Revision date automation**: `01_scrape_revision_dates.R` rewritten to use the USITC REST API (`releaseList`) for discovering new revisions. Includes Chapter 99 PDF change detection via SHA-256 hash comparison.
   - **Assumption #12 removed**: TPC additive stacking methodology moved from `assumptions.md` to a code comment in `helpers.R` — it describes TPC's approach, not our own assumption.
