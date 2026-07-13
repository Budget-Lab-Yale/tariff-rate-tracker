# Statutory Deviations Registry

A single place to see every point where the tracker's published rates deviate
from a *pure statutory* reading of the tariff schedule — deliberately or as a
known gap — plus the deviations that have been proposed but not yet built.
Long-form rationale for many entries lives in
[assumptions.md](assumptions.md) (cross-referenced as **A§n**); this registry
is the scannable index and the place new deviations MUST be logged.

**Why this exists** (user request, 2026-06-12): the statutory-vs-collected
residual work (tariff-etr-eval `residual_gap_deep_dive_2026-06-12.md`) keeps
finding places where the right fix is *not* "match the statute harder" but a
modeled share, a value-basis conversion, or a timing convention. Those choices
must be visible in one place, with their calibration status, or they silently
accumulate into an unauditable model.

## Taxonomy

| Type | Meaning | Statutory layer treatment |
|------|---------|---------------------------|
| **basis** | The statute taxes a different value base than full customs value (metal content, repair value). The printed rate never legally applied to full value. | `statutory_rate_*` may carry the converted rate (it is the legal rate on full-value equivalent) |
| **utilization** | A legal preference/exemption exists; a share models how much trade actually claims it (USMCA, FTA/GSP, §301 exclusions). | `statutory_rate_*` keeps the unclaimed (full) rate |
| **applicability** | A list provision sweeps in dual-use/out-of-scope trade; a share scopes the duty to the in-scope fraction (8471 auto parts, semi tech gate). | `statutory_rate_*` keeps the literal-enumeration rate |
| **timing** | Publication-date vs legal-retroactivity conventions. | both layers follow the convention |
| **gap** | Known unmodeled statute (not a choice — a TODO). | neither layer carries it |

---

## 1. Implemented deviations

### Value-basis conversions (basis)

| # | Deviation | Share / source | Where | Status |
|---|-----------|----------------|-------|--------|
| B1 | 232 derivative duties on **metal content** value (pre-annex era): BEA per-type shares scale the printed rate. | BEA Detail I-O (`metal_content_shares_bea_hs10.csv`); flat/CBO alternatives | `metal_content:` config; `apply_232_derivatives()`; A§2 | calibrated (BEA), TPC uses flat 50% |
| B2 | **Ch98 9802 exception codes**: additional duties (IEEPA/301/122) attach to repair/alteration/processing value only. Effective rate = printed × `dutiable_value_share` (0.10 for 9802.00.40/.50/.60). | eval deep-dive item 4 (China 9802.00.50.60: 25% statutory vs 2.9% collected) | `ch98_value_basis:` config; 06 step 6b3 (added 2026-06-12) | rough (0.10); refine from collections |
| B3 | **9802.00.80** assembly value (full less US content): share held at 1.0 — i.e. NOT yet converted. | — | same config | **uncalibrated gap** — US-content share TBD (matters for MX maquila in fentanyl window) |
| B4 | Korea/Japan/EU 232 auto **floor deals are MFN-inclusive totals**; floor recomputed against post-FTA effective base so total lands on the deal rate (Korea autos = 15.0% flat, matching CBP). | note 33(s); CBP collections | 06 step 4c tag + 6f recompute (added 2026-06-12) | statutory reading, collections-pinned |

### Utilization / claim shares (utilization)

| # | Deviation | Share / source | Where | Status |
|---|-----------|----------------|-------|--------|
| U1 | **USMCA** utilization: CA/MX rates × (1 − SPI share). | DataWeb SPI S/S+ per HTS10×country, HS8 fallback | A§3; 06 step 7 | calibrated annually |
| U2 | **MFN exemption (FTA/GSP)**: base_rate × (1 − exemption share), HS2×country. | Census calculated-duty | 06 step 6c | calibrated |
| U3 | **§301 exclusion claim shares** (9903.88.69/.70): exclusion zeroing scaled by realized claim share. | IMDB ch99 claim data (calibration 2a1763c) | `s301_exclusion_calibration.md`; A§17 | Phase-2 calibrated; full-line zeroing was the Phase-1 upper bound |
| U4 | **Auto rebate / US assembly**: 232 auto rate reduced by rebate × `us_assembly_share`; USMCA vehicles content-scaled by `us_auto_content_share` 0.40. | proclamation mechanism, share estimated | `auto_rebate:` config | rough |
| U5 | **UK 232 content test**: `uk_content_qualifying_share` = 1.0 (everyone passes the ≥95% melted-and-poured test). | none | `section_232_annexes:` | uncalibrated upper bound (SGEPT: 0.30) |
| U6 | **Subdivision (r) auto-parts certification** (`certified_share`) and KORUS/Japan `fta_exempt_shares`. | DataWeb SPI signal noted in config | `auto_parts_subdivision_r:` | dormant (0.0) — known under-exemption |

### Applicability scoping (applicability)

| # | Deviation | Share / source | Where | Status |
|---|-----------|----------------|-------|--------|
| P1 | **Auto-parts 8471 dual-use**: note 33(g) names bare 8471; applicability share scopes to vehicle-parts fraction (share=0 lines keep literal rate in `statutory_rate_232` only). | trade-composition judgment | `s232_auto_parts_applicability.csv` | rough |
| P2 | **Semiconductor note 39 tech gate**: `qualifying_share` per HTS10 + `end_use_exemption_share`. | A§16 | `s232_semi_products.csv` + shares file | partially calibrated |
| P3 | **Annex-era conditioned routes** (zero-metal-content carve-out 9903.82.01, Russia smelt expected-value share): aggregate-share knobs, dormant at 0. | A§18, A§4b | `section_232_annexes:` | dormant |

### Scope and source-of-truth choices

| # | Deviation | Rationale | Where | Status |
|---|-----------|-----------|-------|--------|
| S1 | **AD/CVD excluded from statutory layers** — stripped from the *collected* side instead (level factor in tariff-etr-adj). | order set churns; static layer would be perpetually stale | `docs/adcvd_layer_design.md` §Decision 2026-06-08 | strip scaffold inert until `adcvd_collected.csv` exists |
| S2 | **Specific/compound MFN duties modeled as 0** (`parse_rate()` → NA → 0). SCOPE DECISION 2026-06-10: the tracker will NOT convert them (no AVE, no ad-valorem salvage); the deliverable is per-cell EXPOSURE flags so downstream consumers see which lines carry an unmodeled duty. | documented modeling boundary | `helpers.R:parse_rate`; todo.md §exposure-flags | boundary, flags pending |
| S3 | **Annex-era `annex_1b` derivative inference**: pre-annex derivative codes not present in the April-2026 annex CSV are inferred annex_1b 25%. The proclamation annexes are arguably exhaustive, so this may over-apply. | conservative continuity choice (kept when the annex_1a *chapter* inference was removed 2026-06-12) | `classify_s232_annex()` step 2 | flag for next collections audit |
| S4 | **2018-era out-of-chapter steel/aluminum derivatives** (9903.80.03/9903.85.03: 8708.10.30, 8708.29.21 stampings) not modeled before 2025-03-12 — `apply_232_derivatives()` gates on the 2025-era ch99 codes only. | tiny trade; pre-expansion window | found in the 2026-06-12 scope audit | **gap** (small) |
| S5 | **Canadian electricity (2716.00)** charged the *general* Canada fentanyl rate, not the 10% energy rate: the 9903.01.13 product list is the EO 14156 §8(a) enumeration, which does not include electricity. Collections are ~$0 regardless (no customs entries — see Proposed E1). | strict statutory reading | `fentanyl_carveout_products.csv` (2716 deliberately absent) | documented choice |
| S6 | **Transshipment-evasion penalty headings skipped** (9903.01.16 Canada +40%; reciprocal analog 9903.02.01): conditional enforcement rates, not statutory rates on any product class. | CBP-determination-contingent | `extract_ieepa_fentanyl_rates()` guard (2026-06-12); `ieepa_phase1_range` starts at .02 | statutory reading |

### Timing conventions (timing)

| # | Convention | Examples | Where |
|---|-----------|----------|-------|
| T1 | **Retroactive windows not modeled**: rates activate at the revision (policy-swapped) date of the text that prints them, not the legally retroactive date. | EU exemptions (retro Sep-1, modeled from rev_24 2025-09-25); Korea floor (retro Nov-14, modeled from rev_32 2025-12-05); exception: Taiwan rev_9 dated to its retro May-1 | `config/revision_dates.csv` notes |
| T2 | **Floor-exempt carve-outs date-gated by deal publication** (eu 2025-09-25, japan 2025-09-16, korea 2025-12-05, swiss 2026-01-01). Without this the static list exempted EU/Swiss/Korea back to April 2025 (~0.12pp ETR Apr–Sep 2025). | added 2026-06-12 | `floor_exempt_products.csv` `effective_date_start`; loader filter |
| T3 | **Stated-date gates**: ch99 entries published before their in-text legal date are suppressed until it (e.g. Proc 10896 items in rev_4 held to 2025-03-12). | `filter_active_ch99()` | `extract_effective_date_offset()` |

---

## 2. Proposed / pending deviations (not yet built)

| # | Proposal | Type | Trigger | Notes |
|---|----------|------|---------|-------|
| F1 | **Pharma §232 applicability share** — company US-manufacturing-commitment carve-outs + agreement ceilings on the ch30 layer (~$5.2B LATE, growing). | applicability | eval item 1 | Phase 2a; calibrate per-origin (IE/CH/IN map to firms) AFTER the Phase-1 vintage re-baselines the residual |
| F2 | **Nairobi Protocol claim share** on 9018–9022 — duty-free secondary classification 9817.00.96, invisible at primary HS10 (~$2.0B). | utilization | eval item 3 | Phase 2b; request IMDB `rate_prov` duty-free shares per HS10×country as the calibration input |
| F3 | **Japan §232 offset credits** — applicability haircut on Japan autos from 2026-02 (collected 12.5%→9.6% vs 15% deal rate). | utilization | eval item 6b | Phase 2c; fold into the consolidated "what does the Japan agreement exempt" review (incl. the missing Japan aircraft annex, see T2/`floor_exempt` Japan rows dropped 2026-06-12) |
| F4 | **9802.00.80 US-content share** (see B3). | basis | this registry | needs Census 9802 value detail |
| F5 | **Entry-coverage flag** for 2716/2711/2709 — flows that structurally never generate customs entries; eval comparisons should skip them rather than book residual. | metadata | eval item 5b | Phase 3a; sidecar, no rate change |
| F6 | **Annex II / ch99 claim shares** (IMDB) beyond §301 — generalize U3 to other exemption families. | utilization | etr_adj handoff item 1 | |
| F7 | **Watch-only**: 0202 TRQ mix (Feb–Mar 2026), China 84/85 stacking. | — | eval item 7 | documented, no action |
| F8 | **Energy lines on the §232 derivative annexes** — 2710.19.30 (lubricating oil) and 2711.12 (propane) are genuinely enumerated as steel derivatives (note 16(n), heading 9903.81.91, eff. 2025-08-18) and aluminum derivatives (note 19(k), heading 9903.85.08), re-affirmed in the April-2026 annex 2; classification is CORRECT (mirrors beer 2203.00.00 on the aluminum list), not a scraper artifact. `statutory_rate_232 = 0.50`; effective `rate_232 ≈ 0.50 × steel_share ≈ 0.8–1.1%`. Caveat: these are overwhelmingly BULK imports (pipeline/tanker/bulk rail) with ~0 declared container metal, so realized 232 ≈ 0 — the BEA I/O sector metal_share modestly over-states them and feeds energy η. | basis | this review (C) | no classification action; folds into the metal-share calibration, eta queue item 2 |

---

## 3. Rules of the road

1. **Every new share/knob lands here** with: type, statutory-layer treatment,
   calibration status, and where it lives. PR checklist item.
2. **Statutory vs realized layers**: utilization/applicability deviations keep
   the statutory layer intact (`statutory_rate_*`); basis conversions may
   change both (the printed rate never applied to full value). When in doubt,
   preserve the wedge — the eval side measures it.
3. **Dormant knobs default to the statutory upper bound** (share = 1.0 or
   0.0 as appropriate) so an uncalibrated knob never silently moves rates.
4. **Publish coupling**: changing any of these forces the eval re-pull and the
   tariff-etr-adj recalibration (negative etas absorb statutory omissions —
   fixing statutory without recalibrating double-counts).
