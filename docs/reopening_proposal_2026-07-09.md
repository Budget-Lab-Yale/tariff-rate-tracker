# Reopening Proposal — where the tracker goes next (2026-07-09)

**Status: the repo is paused/stable as of 2026-07-09.** The statutory rate build
is correct and internally consistent; the recent correction passes (§122
aircraft, UK annex_1b, §301 exclusion Phases 1–2, Phase-1 statutory fixes, the
232/Annex-II pass) have landed, and the base-rate specific/compound exposure
flag is in. Nothing below is *broken*; this document organizes the **deferred
work** into the two coherent directions a future maintainer could pick up.

This is a proposal, not a plan of record. It sorts every open item from
`todo.md` into one of two thrusts —

- **Workstream A — Improved ETA calculation** (how the statutory-vs-collected
  gap η is *measured* and how the tracker feeds the Budget Lab Tariff Model's
  eta/α calibration), and
- **Workstream B — Specific calibrations of statutory claiming behaviors** (the
  utilization/applicability *share knobs* — how much trade actually claims each
  legal exemption/preference) —

plus a residual bucket of engineering/housekeeping that belongs to neither.
Registry families (`B/U/P/S/F`) reference `docs/statutory_deviations.md`;
rationale cross-refs are `A§n` in `docs/assumptions.md`. Detailed, still-live
task text stays in `todo.md` — this document is the map, not a replacement.

---

## 0. The one prerequisite that gates both workstreams

Neither thrust can start cleanly until the pending publish/recalibration cycle
completes. Several landed statutory fixes (§122 GN6 aircraft split, UK
annex_1b −10pp, §301 .69/.70 promoted shares, Phase-1 fixes) are **staged but
not yet published**, and by registry Rule 4 any statutory change forces:

> **publish vintage N+1 → eval re-pull (~35 min) → tariff-etr-adj recalibration.**

The current negative etas *absorb* the pre-fix statutory omissions; fixing
statutory without recalibrating adj **double-counts**. This is cross-repo
(tariff-etr-eval + tariff-etr-adj) and is the true critical path. It also
clears `deal_partner_negative_eta_diagnosis.md` / adj `open_questions.md #6`.

**Recommendation:** run this cycle *first*, regardless of which workstream is
chosen. A full build + verify is a ready-made Slurm job
(`sbatch scripts/submit_build_verify.sh`, 192 GB); it also refreshes the
`data/timeseries/*` product caches to the current parser schema (they are still
pre-flag; the new `read_products_cache()` guard fails loud if an incremental
build hits a stale one).

---

## Workstream A — Improved ETA calculation

**Thesis.** η = (statutory − collected) / statutory is only as good as (1) what
the statutory layer includes, (2) what the collected side is compared against,
and (3) which cells are structurally uncomparable. This workstream sharpens the
*measurement*, not the rate build. It is mostly cross-repo (eval/adj own η); the
tracker's role is to expose the right wedges and mask the uncomparable ones.

### A1. Decisions the eta owners must make (blocking, no code)
- **USMCA claim-share baseline (eta queue item 3).** 2024-H2 claim shares embed
  pre-surge take-up (Canadian gas: statutory 9.3% vs realized 0.1% → η≈0.99
  booked as "avoidance"). **Decision:** re-base on current shares (the tracker
  already exposes `usmca_2024` + current-share scenarios) vs. keep the surge in
  η by design. Tracker makes no change until decided. *(Intersects Workstream B
  U1 — the re-base is also a claiming-behavior refresh.)*

### A2. Mask / metadata so η isn't polluted by uncomparable cells
- **Entry-coverage flags (F5).** Register HS 2716 (and 2711/2709) as
  divergence-by-entry-coverage in `statutory_deviations.md` so the eval *skips*
  them rather than booking residual — flows that structurally never generate
  customs entries. Sidecar, no rate change. (2716 already documented as S5; F8
  energy lines feed the same theme.)
- **Value-weighted specific/compound exposure share (`src/diagnostics.R`).** The
  base-rate exposure flag (`base_rate_type`) now exists unweighted; the
  value-weighted share tells the eval which η cells are contaminated by
  duties the tracker treats as 0 (specific/compound). Next cluster build.

### A3. Collected-side hygiene
- **AD/CVD (S1, decided 2026-06-08).** Strip AD/CVD from the *collected* side
  before calibrating η; do **not** build a statutory `rate_adcvd` layer (order
  churn would leave it perpetually stale). Implementation is adj-side; the
  tracker scaffold stays inert. `docs/adcvd_layer_design.md`.

### A4. Aggregate validation
- **External-tracker comparison database.** Fetchers + a five-overlay
  comparison report against TPC / Tax Foundation / Treasury DTS / PIIE, so the
  tracker's headline ETR is validated against the field. Design in
  `docs/external_tracker_comparison.md`; all four sub-items open.
- **GTAP weights HS8 fallback.** Padded 8-digit-leaf codes (Swiss watches, ch98)
  are invisible to *all* weighted ETRs today (weights file is 2024-vintage
  HTS10). Fix the weights join / add a concordance pass — a silent
  weighting gap that biases every weighted aggregate the eval consumes.
- **Electronics α follow-up (adj-side, delivered 2026-07-09).** The electronics
  reciprocal exclusion is correctly applied; the remaining question is the two
  GTAP-crosswalk gaps handed to adj (8486/8524 → `OME` not `ele`; 25 unmapped
  parent codes). If the electronics-diversion miss survives that reconciliation,
  it is a GTAP Armington/α question, not a tracker input.
- **F7 watch-only.** 0202 TRQ mix (Feb–Mar 2026), China 84/85 stacking —
  monitor, no action.

### A5. Diagnostic that spans into B
- **ASEAN η-clustering (eta queue item 4a).** Test whether the η≈0.54–0.56
  cluster concentrates in TH/MY/KH/ID/VN with realized-rate breaks ~Nov 2025.
  This is a *measurement* question; if confirmed it hands off to Workstream B
  (item 4b) as a modeling task.

**Suggested first move for A:** finish A1 (the USMCA decision) and A2 (entry-
coverage masks + value-weighted exposure), because both directly de-bias the η
the model already consumes, and neither needs new external data.

---

## Workstream B — Specific calibrations of statutory claiming behaviors

**Thesis.** The statute grants dozens of exemptions/preferences whose *take-up*
is not observable in Census trade data. The tracker models each as a share knob;
most sit at the dormant statutory upper bound (share = 1.0 / 0.0). This
workstream replaces dormant knobs with *measured* shares — overwhelmingly via
**realized-rate inversion** (realized ÷ statutory ⇒ implied claim/qualifying
share per HTS10×partner) as IMDB months land. Each lands as a registry `U`/`P`
entry with an explicit calibration status.

### B1. Flagship: §232 annex exemption-route calibration (issue #13)
The single highest-leverage item. The annex-era full-value basis is correct by
law; the gap is the dormant note-16 routes. Proposal:
`docs/s232/annex_exemption_route_calibration_proposal.md`. Sequencing (proposal
§8): build `tools/calibrate_s232_annex_routes.R` (3-component realized-rate
inversion), run the first measurement → **CSV only, curator review before any
engine change**. This absorbs several smaller items:
- the 8471 annex_1b decision (P1, data-gated on April+ collections),
- the zero-metal-content / de-minimis / us-origin-metal / motorcycle knobs (P3),
- the annex-era half of the §232 derivative content-basis item, and
- re-deriving route-calibration `T_exit` for India/JP/VN after the §122 fix
  rides a vintage (their exact-10 "us_origin" mass reclassifies to exit-strong),
  and re-running against the UK-fixed vintage for a correct `T_full`.

### B2. §232 content & qualifying shares (realized-rate inversion)
- **Derivative content basis, pre-annex window 2025m5–2026m2 (eta queue item 2,
  B1).** Realized ÷ statutory per HTS10×partner ⇒ implied metal-content share;
  recalibrate `metal_content_shares_bea_hs10.csv`. (Annex-era half → B1 above.)
- **Semiconductor `end_use_exemption_share` (P2).** Post interim calibration it
  only bites on 8471.80.4000; measure realized ÷ 25% on Taiwan/China
  Jan-16→Mar-2026 collections = qualifying × (1 − end_use) directly. Don't move
  baseline until measured.
- **UK content qualifying share (U5).** Scope is now statutory-correct after the
  annex_1b fix; only the `uk_content_qualifying_share` calibration remains open
  (dormant 1.0; SGEPT estimate 0.30).

### B3. §232 deal-partner & limited-quantity routes (needs legal text)
- **Japan agreement exemptions** — consolidated review: the missing Japan
  aircraft annex (1,019 dropped-code pairs charged ~18% where TPC charges
  ~3.5%) + the F3 §232 offset credits (collected 12.5%→9.6% vs 15% deal). Needs
  the Japan agreement annex text to adjudicate.
- **Note 16(h)/(i) limited-quantity CA/MX (9903.82.18/.19)** — per-country share
  knob; defer until the eval shows a CA/MX primary-metals gap.
- **Note 16(k) annex_1c parts end-use (9903.82.23–.26)** — low materiality;
  `applies_to` share knob mirroring us_origin_metal.
- **Subdivision (r) auto-parts (U6)** — `certified_share` + KORUS/Japan
  `fta_exempt_shares`, all dormant at 0 (known under-exemption). DataWeb upper
  bounds known (KR ≤ 0.86, JP ≈ 0, EU = 0); needs CBP entry data / industry
  estimates. Side question: should KORUS apply to the 9903.82.x annex
  independent of (r) certification?

### B4. §301 exclusion claim shares (U3, Phase-2 continuation)
Phases 1–2 landed (`docs/s301_exclusion_calibration.md`). Remaining:
- eval cross-check of the realized-rate inversion (promoted .69 = 0.35 /
  .70 = 0.20) against the rev_9 vintage;
- calibrate or dismiss the .21–.28 permanent carve-outs (`--include-carveouts`);
- rerun the calibration **quarterly** as IMDB months land;
- promote the per-HTS10 line-coverage extension (built dormant, scenario
  `s301_line_coverage`) after full-build parity review;
- the two rate-bearing headings with ignored stated expiries (`9903.91.04`
  "through Dec 31 2025", vestigial `9903.88.09`) — decide on a rate-bearing
  expiry gate (parity-gated).

### B5. Preference / claim-share channels
- **USMCA monthly-share refresh (U1).** Refresh DataWeb shares against
  IMDB-realized claim shares (HS6×country×month; eval computes the aggregate,
  tracker ingests). *(Couples to A1's re-base decision.)*
- **Expose statutory-vs-claimable split** for the Annex II claim-rate channel
  (emit both columns; the `ieepa_exempt_scope: 'baseline_only'` toggle already
  produces the no-claim rate).
- **Generalize claim shares beyond §301 (F6).** Extend U3's IMDB method to other
  exemption families (Annex II / ch99).

### B6. Pharma & other applicability shares (registry proposals)
- **F1 Pharma §232 applicability share** — company US-manufacturing-commitment
  carve-outs + agreement ceilings on the ch30 layer (~$5.2B, growing). Calibrate
  per-origin AFTER the Phase-1 vintage re-baselines the residual.
- **F2 Nairobi Protocol claim share** on 9018–9022 (duty-free 9817.00.96,
  invisible at primary HS10, ~$2.0B) — request IMDB `rate_prov` duty-free shares.
- **Generic pharma country-specific exemption shares** (TPC feedback, low pri).

### B7. Value-basis refinements (registry `basis`)
- **F4 / B3-registry: 9802.00.80 US-content share** (currently held at 1.0 —
  uncalibrated; matters for MX maquila in the fentanyl window). Needs Census
  9802 value detail.
- **B2-registry: 9802 exception codes** (9802.00.40/.50/.60) — refine the rough
  0.10 dutiable-value share from collections.

### B8. Model-once-diagnosed
- **ASEAN retro exemptions (eta queue item 4b).** If A5 confirms the clustering,
  pull per-country CSMS product lists (EO 14346 Annex III) and model as
  date-bounded country-specific exempt overlays (`swiss_framework` pattern).
- **§122 aircraft GN6 utilization export reconcile.** `generate_s122_yaml()`
  still exports the flat all-1,656 aircraft list as exempt; the GN6 split is
  tracker-engine-only. Reconcile in the eval/adj handoff (export schema is a
  flat list; carrying utilization needs a schema change there). Add the
  companion registry U-item (family U1/U3; modeled unconditional 2026-02-24→07-08).
- **Pre-annex 9903.81.92 US-melted steel-derivative exemption** — document-and-
  defer; revisit only if 2025 §232 residuals point at it.
- **Annex III sunset (Dec 2027 → I-B rate)** — logic in place; needs a future
  HTS revision to test.

**Suggested first move for B:** the §232 annex route-calibration measurement
module (B1). It is already specced, produces CSVs for curator review before any
engine change, and subsumes the most dormant-knob items at once.

---

## Crosswalk — every deferred item → workstream

| Item (todo.md) | Workstream | Registry | Blocker / gate |
|---|---|---|---|
| Eval re-pull → adj recalibration | **Prereq** | Rule 4 | cross-repo; run first |
| USMCA claim-share re-base decision | A1 (∩ B5) | U1 | eta owners' decision |
| Entry-coverage flags 2716/2711/2709 | A2 | F5/S5/F8 | none (sidecar) |
| Value-weighted specific/compound share | A2 | S2 | next cluster build |
| AD/CVD strip from collected | A3 | S1 | adj-side |
| External-tracker comparison DB | A4 | — | none |
| GTAP weights HS8 fallback | A4 | — | none |
| Electronics crosswalk follow-up | A4 | — | adj-side (delivered) |
| ASEAN η-clustering diagnosis | A5 → B8 | — | eval measurement |
| §232 annex route calibration (#13) | **B1** | P1/P3 | Apr+ IMDB collections |
| §232 derivative content basis (pre-annex) | B2 | B1 | IMDB inversion |
| Semi end_use_exemption_share | B2 | P2 | Taiwan/China collections |
| UK content qualifying share | B2 | U5 | data / SGEPT |
| Japan annex + F3 offset credits | B3 | F3 | Japan agreement text |
| Note 16(h)/(i) CA/MX | B3 | P3 | eval CA/MX gap signal |
| Note 16(k) annex_1c parts | B3 | — | low materiality |
| Subdivision (r) auto-parts shares | B3 | U6 | CBP entry data |
| §301 Phase-2 remaining | B4 | U3 | vintage + quarterly IMDB |
| §301 rate-bearing expiry gate | B4 | — | parity-gated |
| USMCA monthly-share refresh | B5 | U1 | IMDB drill-down |
| Statutory-vs-claimable split | B5 | F6 | none (toggle exists) |
| Pharma §232 share (F1) | B6 | F1 | post Phase-1 re-baseline |
| Nairobi Protocol (F2) | B6 | F2 | IMDB rate_prov shares |
| Generic pharma shares | B6 | — | TPC feedback (low) |
| 9802.00.80 US-content (F4) | B7 | B3/F4 | Census 9802 detail |
| 9802 exception codes refine | B7 | B2 | collections |
| §122 aircraft export reconcile | B8 | U1/U3 | eval/adj schema change |
| Pre-annex 9903.81.92 | B8 | — | document-and-defer |
| Annex III sunset test | B8 | — | future HTS revision |

---

## Out of scope of either thrust (preserved, not lost)

These are engineering, housekeeping, or decided-dormant — real backlog, but they
don't advance either the η measurement or the claiming-behavior calibration.

**Infrastructure / engineering**
- Build unification Phases 1/3/4 (destinations-as-config; array-by-default;
  fold alternatives).
- Scenario publication metadata (`publish_git`/`publish_vintage` reading
  `meta.publish`) and possible kind-taxonomy consolidation.
- Stale-sibling numeric rate-inheritance fix (~1,100 pairs on rev_9; parity-
  gated — make `type_stack`'s robust reset drive `rate_stack` too; needs a
  full-build golden diff). *The exposure flag already surfaces these cells.*
- Re-dated rebuild acceptance checks (`compare_etrs.R`, `revision_changelog.R`,
  hand snapshots to eval); retro-window follow-ups (EU Sep-1, Korea Nov-14,
  rev_4 Mar 7–13) via date-bounded overrides if the eval needs them.
- Suggestion-tier perf: O(N·M) annex prefix matching → hash precompute;
  `load_metal_content()` re-read check; `statutory_rate_232` overloaded
  semantics.

**Housekeeping**
- Dead doc references in code/comments (f745eea cleanup fallout).
- `tests/test_publish_snapshots.R:22` stale `src/publish_internal.R` ref.
- File-pathing unification (`here()` vs `here::here()` sweep).
- `config/local_paths.yaml` CI-parity leftover — *removed 2026-07-09.*
- Verify `submit_plank` harnesses post-restructure.
- `data/census_imports_2024.csv` holds only CA+MX — provenance check before reuse.
- Cosmetic annex-builder 10→8-digit truncation.
- Concordance builder tightening; small-country outliers (not material).

**Decided / dormant (no action by design)**
- Russia clause (8) smelt/cast origin — `third_country_content_share = 0.0` is
  the accepted treatment (A§18); no origin tracking planned.
- Registry source-of-truth choices S3–S6 (annex_1b inference, 2018-era
  out-of-chapter derivatives, Canadian electricity, transshipment penalties).

---

## Recommendation in one paragraph

Do the **prerequisite** publish/recalibration cycle first — it unblocks
everything and is already a one-command Slurm job. Then pick the thrust by what
the model needs most: **Workstream A** if the priority is trusting the headline
η/ETR (de-bias the USMCA baseline, mask entry-coverage cells, validate against
external trackers); **Workstream B** if the priority is squeezing the last
mismodeled claiming behavior out of the residual (start with the §232 annex
route-calibration module, which is specced and subsumes the most items). A and B
are complementary, not exclusive — but each is a self-contained reopening.
