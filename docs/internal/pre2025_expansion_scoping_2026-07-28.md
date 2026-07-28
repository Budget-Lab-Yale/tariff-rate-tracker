# Pre-2025 expansion scoping — extending statutory coverage back to 2015

**Date:** 2026-07-28. **Status:** scoping only; no implementation. Compiled from three
parallel investigations: (1) external data availability (web-verified), (2) repo
structure audit, (3) methodology/assumptions register. Nothing in the 2025–2026
product changes as a result of this document.

---

## 1. Verdict

Expansion back to **2016** is feasible on the current HTS-10 architecture; **2015**
has no machine-readable HTS edition at all (PDF only) and would require either an
HTS-8 spine or manual PDF work. The repo is structurally closer to year-generic
than expected — revision IDs are already year-namespaced and all ordering is by
effective date — so the hard work is (a) sourcing ~100+ historical archives,
(b) adding a time dimension to three undated config structures, (c) the base-layer
methodology (preferences/NAFTA/col-2), and (d) build memory at ~150 revisions.
Output invariance for 2025–2026 is provably achievable: snapshots are independent,
and the parity harness already fails closed on any new artifact.

## 2. Data availability (all VERIFIED by download unless noted)

### 2.1 The three cliffs in USITC HTS JSON archives

`hts.usitc.gov/reststop/releaseList` lists every edition back to 2015, but archived
editions serve **PDF only** from USITC; full JSON is recoverable **only via the
Wayback Machine** (www.usitc.gov is Akamai-403 to all automated access).

| Year | Editions | JSON recoverable (Wayback) |
|---|---|---|
| 2015 | 2 | **0** — hard cliff |
| 2016 | 2 | 1 |
| 2017 | 2 | 1 |
| 2018 | 19 | **8 of 19** — worst gap (§232 eff. 2018-03-23 in a ~4.5-month JSON blind spot) |
| 2019 | 21 | 18 of 21 |
| 2020–2024 | 29/17/14/12/11 | complete |

Verified example: `https://web.archive.org/web/20250410141706id_/https://www.usitc.gov/sites/default/files/tata/hts/hts_2018_revision_13_data.json`
(8.3 MB, 33,978 records; shows List 3 at +10% — genuine historical state).

**Highest-severity trap:** `reststop/exportList?release=<historical>` returns
**HTTP 200 with CURRENT-release data** — the release parameter does not exist in
the API (confirmed from the Angular bundle). Any backfill fetch must assert
content (e.g. absence of `9903.01.*` for pre-2025). Also: Wayback truncates
large captures at exactly 1 MiB — filter by size and validate parse; avoid
`collapse=urlkey` (hides good captures).

**Gap-filler:** `reststop/file?release=<name>&filename=Chapter%2099` returns the
Chapter 99 PDF for **every** release back to 2015, including all 11 missing 2018
revisions. `Change%20Record` and `finalCopy` also work per release.

### 2.2 USITC Annual Tariff Database — recommended pre-2025 spine

`https://www.usitc.gov/tariff_affairs/documents/tariff_data/tariff_data_YYYY.zip`,
**1997–2026** (manifest: `dataweb.usitc.gov/assets/content/lists/tariff_annual.json`;
Wayback-mirrored). Two premises about it were refuted by inspection:

- **It is effective-date-versioned, not an annual snapshot**: multiple rows per
  line keyed to true statutory dates (e.g. 9903.88.03 at +10% 2018-09-24→2019-05-09,
  +25% from 2019-05-10). This dissolves the HTS publication-lag problem and most
  of the revision-date curation burden for pre-2025.
- **It includes Chapter 99 rows** (plus 9902 MTB, 9904 etc.), though Ch.99 numeric
  rate columns are sentinel-filled and there is no heading→HTS8 product mapping —
  product scope still comes from HTS archives / note text.

It carries MFN ad-val/specific/other, full **column 2**, and per-program
indicator+rate columns for every preference program (GSP incl. country
exclusions, NAFTA CA/MX, USMCA from 2020, AGOA, KORUS, CAFTA-DR, …) — directly
solving the NAFTA-keying and preference-eligibility gaps. Limits: **HTS-8 only**;
`mfn_ave` officially "Not used" (no AVEs anywhere); schema/delimiter drift by year
(1997 pipe/37 cols, 2018 quoted-CSV/112–113, 2022+ unquoted/118–122; unstable inner
filenames; embedded NULs) — needs a per-year sniffing loader; later files drop
superseded spans, so union all year files. Caveat: the 2022 annual DB still lists
`CA,MX` in `col1_special_text` where the 2022 JSON does not — the two sources are
not interchangeable on program codes.

### 2.3 Census IMDB weights — fully available

`https://www.census.gov/trade/downloads/{YYYY}/Merch/im_m/IMDB{yy}{mm}.ZIP` —
**zero gaps 2010-01 → 2026-05** (exhaustive sweep with retries; census.gov
throttling produces spurious non-200s on naive sweeps). Fixed-width 688-byte
records, field offsets byte-identical 2015–2024, including `dut_val_mo` /
`cal_dut_mo` (the fields needed for preference-share measurement and AVE
construction). Hazards: filename case flips (`IMP_DETL.TXT` vs `.txt`) — extract
case-insensitively; ~15–17 GB for a 2015–2024 backfill → Slurm. Annual
`IMDB{YYYY}.ZIP` exists in the same directories. Census API has the same fields
(`CAL_DUT_MO` etc.) but is key-gated; ZIPs dominate for bulk.

### 2.4 Suggested source layering

Annual DB (rates + effective dates + preferences + col-2, HTS-8) → HTS JSON
2016–2024 via Wayback (HTS-10 structure, Ch.99 note text) → Chapter 99 PDFs via
`reststop/file` (2018 gaps, 2015) → Census IMDB (weights, shares, AVEs,
validation). Mirror everything into the repo (Akamai/Wayback are single points
of failure).

## 3. Repo structure (audit summary; file:line in the full agent report)

**Already generic (no change):** `parse_revision_id` handles `2015_basic`/`2015_rev_N`
today (bare IDs = the 2025 namespace); all ordering is `effective_date`-primary;
`basic` is not semantically special — just the earliest CSV row; year rollover has
no dedicated logic; download URL construction is year-parameterized;
`classify_authority` is heading-**range** based and already covers 9903.88 (§301),
9903.80/85 (§232 2018), 9903.45 (§201).

**Load-bearing 2025 assumptions to generalize:**

| Item | Where | Difficulty |
|---|---|---|
| `section_301_rates` static map (Feb-2020 values; wrong before 2020-02-14) | `config/policy_params.yaml:450` → `authority_adapter.R:37-66` | HARD — needs `effective_from/until` fields |
| `section_232_country_exemptions` expiry-only (open left edge: CA/MX/EU wrongly exempt 2018-19) | `policy_params.yaml:230` → `authority_adapter.R:100` | HARD — add `effective_date`, two-sided gate |
| `section_201.solar_rate` single scalar (Year-8 value) | `policy_params.yaml:77` | HARD → dated schedule; washers §201 currently ignored entirely |
| Weights: single 2024 anchor; 484(f) crosswalk starts 2024-07; `elig_year` gate at `build_panel_import_weights.R:348` | multiple | HARD |
| USMCA share year defaults 2025; time-invariant claiming | `data_loaders.R:266,340,413` | HARD (methodological) |
| `weighted_etr_new` baseline `2025-01-01` | `09_daily_series.R:1127` | MODERATE |
| `expected_authorities.csv` carry-forward from `basic` (would assert §232≥50% in 2015) | `quality_report.R:274-290` | MODERATE — do first; it's the regression net |
| `build_release_name` year<2025 floor; manifest provenance year literals | `revisions.R:42`, `write_output.R:658-672` | EASY |

**Invariance mechanism (recommended):** add `series_horizon.start_date` (shipped as
`2025-01-01`) resolved next to the existing end-date, applied as one filter in
`load_revision_dates()` (`revisions.R:78-135`) — the single funnel used by build,
download, boundary discovery, and array sizing. Run pre-2025 as a **separate
vintage** with its own `revision_dates` window, its own `policy_params_pre2025.yaml`
(via the existing `policy_params_path` build key), and separate output dirs. The
parity harness (`summarize_parity_results.R:63-72`) already fails on any
artifact-set change; the orphan gate (`00:281-289`) hard-stops on stray snapshots.
Existing `config/scenarios/pre_2025/` overlay is the starting shape for disabling
2025-only authorities. Gap to close: nothing asserts the combined series' date
range — add a `SERIES_HORIZON_START` assertion beside `00:348-355`.

**Scale:** panel memory is linear in revision count; ~150 revisions ⇒ ~400–600M
rows ⇒ the 192 GB gather OOMs. 2018-2021 §301 exclusion windows could multiply
boundary-minted snapshots (today: 2; pre-2025: potentially dozens/year). Do NOT
build one monolithic 2015–2026 panel: build per-era vintages and union at the
Hive-partitioned parquet layer (partitioned by `valid_from` already). Cap/inspect
`discover_boundaries` on 2019–2021 archives before committing.

## 4. Assumptions register (decision items)

Top three by headline-ETR impact:

1. **Preference programs / NAFTA (jointly).** The base layer's only preference
   mechanism is one time-invariant HS2×country `mfn_exemption_shares.csv` (no
   in-repo builder, no assumptions.md entry), and `usmca_eligible` keys on `S`/`S+`
   — silently all-FALSE on pre-2020-07 archives (NAFTA used `CA`/`MX`), so CA/MX
   (~26% of imports) would carry full column-1 MFN. The wedge is 40–60% of the
   2015-2017 ETR level. Fix: program-code→country map (annual DB provides it
   per line per year) + rebuild exemption shares **annually at HS6** from IMDB
   `cal_dut/dut_val`; hard keying switch at 2020-07-01.
2. **Weights vintage + HS nomenclature churn (jointly).** No backward code map
   below 2024-07; HS2017 and HS2022 revisions (~3-4k HTS-10 identity changes
   in-window) would produce spurious level breaks at exactly 2017-01-01 and
   2022-01-01. Fix: extend 484(f) edges back (~20 notices;
   `tools/build_484f_crosswalk.R` pattern; schema already has a `nomenclature`
   column) + WCO correlation tables; add a join-rate coverage gate.
   Weights decision: publish **both** contemporaneous-weights (headline
   historical) and fixed-2024-weights (policy-only) series.
3. **§301 exclusion timeline 2018–2021.** Architecture generalizes well (lists
   already span 1–4B; rates read off archives; the 58-heading exclusion registry
   auto-populates from historical archives). The burden is claim-share
   calibration: 2025-calibrated shares vs full-line zeroing is worth several pp
   of China ETR in 2019-20. v1 default: full-line zeroing (documented Phase-1
   upper bound) + sensitivity; IMDB re-calibration in Phase 2 (de-minimis
   contamination differs pre-2021).

Other register items: **column 2 is unmodeled entirely** (Russia/Belarus from
2022-04-09; also a live defect in the 2025-26 series — Russia priced at col-1
today; annual DB has col-2 rates, but country status needs an exogenous overlay
since GN 3(b) is text-only); **quota/TRQ statutory ambiguity** (KR/BR/AR absolute
quotas, EU/JP/UK TRQs 2022; recommend `quota_fill_share` knob registered in
`statutory_deviations.md`, default = statutory bound); **no-AVE scope decision**
(hold for v1, publish value-weighted exposure; year-specific AVEs from IMDB unit
values as v2 — prerequisite for col-2 to be meaningful); **GSP lapse 2021-01-01**
= charge col-1 (statutory-at-entry, consistent with T1; annual DB still flags
GSP eligibility post-lapse, so the window must be exogenous config); **MTB**:
only ONE in-window cycle (P.L. 115-239, 2018-10-13 → 2020-12-31, never renewed)
— honor `end_effective_date`, don't do membership tests; **washing-machine §201**
(2018-02→2023-02) must be added; **§301 aircraft 9903.89** (2019-10→2021-07)
needs a non-China 301 branch (`rate_301_cs` scaffold is the hook); **entry
coverage / de minimis** — build the F5 year-varying sidecar so η is comparable
across the boundary; **`revision_dates.csv` curation** (~180 rows) is the largest
hidden labor cost, but the annual DB's effective dates reduce it materially.

## 5. Phasing (updated per §6 decision record)

- **Phase 0 — invariance rails (small):** `series_horizon.start_date` + window
  filter in `load_revision_dates()` + horizon-start assertion + re-keyed
  `expected_authorities.csv`; prove 2025-26 parity green. Nothing else lands
  before this.
- **Phase 0b — column-2 standalone PR (current series):** parse `other` field,
  dated `column_2_countries` config, rebuild + parity delta + blessed vintage.
  Independent of the backfill; lands schema the backfill reuses.
- **Phase 1 — data acquisition:** mirror Wayback JSONs (size-validated,
  content-asserted), annual DB 2016–2026, Chapter 99 PDFs for gaps, IMDB
  2016–2024 (Slurm). Deliverable: committed archives + provenance doc.
- **Phase 2 — 2018–2024 statutory build (HTS-10):** dated §301/§232/§201 config
  (incl. washers §201, 9903.89 aircraft branch, MTB end-dates); quota/TRQ split
  treatment with `over_quota_share` knob (default in-quota); program-eligibility
  layer with GSP window ending 2020-12-31; per-era vintage; boundary-mint audit.
- **Phase 3 — 2016–2017 statutory build + weights & shares:** backward
  484(f)+nomenclature spine (HS2017/HS2022); annual weights; annual HS6
  exemption shares; fixed-2024-weight headline extension + contemporaneous
  ancillary series.
- **Phase 4 — calibrations & refinements:** IMDB-based §301 exclusion claim
  shares (2018-21), TRQ over-quota shares, AVEs from unit values (unlocks
  meaningful col-2 magnitudes), entry-coverage sidecar. **2015** revisited here
  (HTS-8 spine decision).

## 6. Decision record (owner: John Iselin, 2026-07-28)

1. **Coverage start: 2016.** 2015 deferred with an explicit note (no machine-readable
   HTS exists; would need an HTS-8 spine or PDF work).
2. **Dual weights; fixed-2024 is primary.** The fixed-2024-weight backfill extends
   the existing headline series into one continuous 2016-2026 policy-only line;
   the contemporaneous-weight series is published as the ancillary historical view.
3. **Quota/TRQ: split treatment.** Absolute quotas (KR/BR/AR steel) = 0% with a
   "quantity restriction, not a tariff" scope note; TRQs (EU/JP/UK 2022+, §201
   solar cells, washers) get an `over_quota_share` utilization knob registered in
   `statutory_deviations.md`, defaulting to the in-quota rate until calibrated
   from IMDB Chapter 99 entry lines.
4. **§301 exclusions v1: full-line zeroing** (documented upper bound on relief)
   with the no-exclusion bound published as sensitivity; IMDB `cal_dut`
   calibration deferred to Phase 4.
5. **GSP 2021-24: column-1 general from 2021-01-01** (statutory-at-entry, per T1;
   lapse never cured). Program eligibility windows are exogenous config — never
   inferred from line data (annual DB still flags GSP post-lapse).
6. **Per-era vintages, unioned at the parquet layer.** No monolithic panel. Add a
   query helper so `get_rates_at_date()` spans eras transparently.
7. **Column 2: fix NOW as a standalone PR** on the current 2025-26 series (parse
   the HTS `other` field + dated `column_2_countries` config: RU/BY from
   2022-04-09, CU/KP always). Requires rebuild + parity delta + blessed vintage.
   Rates read low on specific-duty lines until AVEs exist (Phase 4) — note in the
   PR.
