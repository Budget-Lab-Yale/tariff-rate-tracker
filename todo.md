# Tariff Rate Tracker — TODO

> **Repo paused / stable as of 2026-07-09.** The forward-looking organization of
> everything still open lives in **`docs/reopening_proposal_2026-07-09.md`**,
> which sorts these items into two reopening thrusts — (A) improved ETA
> calculation and (B) specific calibrations of statutory claiming behaviors —
> plus an out-of-scope engineering/housekeeping bucket. This file remains the
> detailed backlog; the proposal is the map and states the one prerequisite
> (publish vintage N+1 → eval re-pull → adj recalibration) that gates both.

Slimmed 2026-07-08. Everything completed before that date — the full sections
for the 2026-04→06 correction passes, reviews, and landed plans — is preserved
verbatim in `docs/archive/todo_archive_2026-07-08.md`; this file carries only
open work. Registry of statutory deviations (the B/U/P/S/F items):
`docs/statutory_deviations.md`.

## Active priorities (2026-07-08)

1. **§232 annex exemption-route calibration (issue #13).** Proposal:
   `docs/s232/annex_exemption_route_calibration_proposal.md`. The annex-era
   full-value basis is correct by law; the gap is the dormant note-16 routes.
   Sequencing per the proposal §8: build the measurement module
   (`tools/calibrate_s232_annex_routes.R`, 3-component realized-rate
   inversion) and run the first measurement — CSV outputs only, curator
   review before any engine change. Absorbs: the 8471 annex_1b decision
   (data-gated on the same April+ collections), the zmc/de-minimis/us-origin/
   motorcycle calibration line, and the eta-queue item-2 annex-era half.
2. **Eval re-pull → MANDATORY adj recalibration.** The publish half is DONE
   2026-07-08: verified vintage `2026-07-01-16` (verify_build 11/0, tests
   107/0; carries the promoted §301 .69/.70 coverage shares AND the Phase-1
   fixes) promoted to `latest`. Remaining (cross-repo): the ~35-min eval
   re-pull against it, then recalibrate adj (current negative etas absorb the
   statutory omissions — fixing statutory without recalibrating
   double-counts). adj side must also correct
   `deal_partner_negative_eta_diagnosis.md` / open_questions #6.
3. **Electronics reciprocal-exclusion query — ANSWERED 2026-07-09.** Carve-out
   IS applied correctly: 9903.01.32 codes on `ieepa_exempt_products.csv` zero
   only `rate_ieepa_recip`, universal across partners, dated 2025-04-05 (8541/
   8542 NA=inception). Reply + 133-code line list (with GTAP mapping +
   two crosswalk gaps: 8486/8524 → OME not ele; 25 unmapped parent codes)
   delivered to tariff-etr-adj (`docs/electronics_exclusion_answer_2026-07-09.md`
   + `resources/electronics_reciprocal_exempt_from_tracker.csv`); copy in
   tracker `docs/`. NOT a tracker cause of their electronics diversion miss.
4. **Eta statutory-measurement queue leftovers** (section below): pre-annex
   §232 content-share inversion (item 2), USMCA re-base decision with the eta
   owners (item 3), ASEAN CSMS retro-exemption follow-up (item 4 next steps).
5. **Specific/compound-duty exposure flags** (section below) — scoped, zero
   rate-number changes, ready to implement.
6. **Build/alternatives unification remaining phases** (sections below).

## HTML markup in `general` defeats the base-rate parser — LIVE ERROR (2026-08-10)

**The published series carries `base_rate = 0` on 21 HTS10s that have a real
MFN rate.** USITC's `general` field sometimes trails stray markup; the base-rate
parser does not strip it, so the value fails to match as ad valorem and falls
back to `base_rate_type = 'other'`, `base_rate = 0`:

```
2.5% <u></u>   ->  other,      base_rate 0.000     rev_12, rev_15 (current)
2.5%           ->  ad_valorem, base_rate 0.025     rev_13
```

Scope on rev_15 (the current revision): of 11,414 ch1-97 lines carrying a
general rate, 19 contain markup and **12 are a bare `N%` once tags are
stripped** — i.e. mis-parsed. Those 12 source entries (several are HTS8 parents)
expand to **21 HTS10 x 240 countries = 5,040 rows per partition**, at true rates
of 2.5%, 3.7%, 5%, 6% and 10%. Tags seen: `<u></u>` x12, `<sup>...</sup>` x6,
and one malformed `</il>`. Affected lines are motor-vehicle parts (8708.\*),
bicycles (8712.00.50) and bicycle parts (8714.9\*).

**Rate impact.** Downstream net-of-MFN arms subtract the zeroed base, so they
overstate the additional duty by the MFN amount: `rate_232` charges 15% where
12.5% is correct (15% - 2.5%), `rate_s301fl` charges 10% where 4% is correct
(10% - 6%). For `target_total` programs the *total* roughly survives — the
overstated additional offsets the understated base — which is exactly why this
went unnoticed. For ADDITIVE programs there is no such cancellation, and
`statutory_base_rate` is wrong on these lines regardless of program.

**How it surfaced.** Partition parity of a full candidate build against vintage
`2026-07-24-09` (`scripts/verify_partition_parity.R`, Slurm 21799738) flagged
`base_rate` / `base_rate_type` moving on exactly one partition, 2026-07-31.
That is the only partition owned by rev_13 — the one revision in this window
whose text happens to be clean. Its neighbours (08-19, 09-29, 11-10) are owned
by rev_15, which has the tags back, so they matched the reference and looked
fine. Source text confirmed per-archive (Slurm 21845798): the rate VALUE never
changes across rev_12/13/15, only the markup.

- [ ] **Correct the documented assumption first.** This section and the rev_14/
  rev_15 section below both assert that tags "land in `description`/`units`
  only, so rate parsers are unaffected". That is FALSE — they land in `general`
  and the base-rate parser is affected. The claim came from a cosmetic-diff
  analysis that only inspected description/units.
- [x] **Strip markup before parsing**, not just when diffing. DONE:
  `normalize_schedule_text()` moved from `tools/revision_changelog.R` into
  `src/core/helpers.R` (one definition; the changelog now sources it) and
  applied in `parse_rate()`, `is_simple_rate()` and `classify_rate_type()`.
  Archives stay raw. The tag pattern is `<[^>]*>` rather than a tag-name
  allowlist, which is what handles the malformed `</il>`.
- [ ] **This is rate-moving: own vintage + parity review.** 5,040 rows per
  partition change, across every partition whose owning revision carries the
  tags. Do NOT fold it into an unrelated publish. Re-run
  `scripts/verify_partition_parity.R` afterwards and expect `base_rate`,
  `base_rate_type`, `rate_232`, `rate_s301fl` and the totals to move on those
  lines — and nothing else.
- [x] **Add a parser regression test** over the real archives. DONE:
  `tests/test_rate_parse_markup.R` (20 assertions, 47 archives, ~35s). Asserts
  no ch1-97 line whose `general` normalises to a bare `N%` classifies as
  non-`ad_valorem`, plus that markup does not create FALSE ad valorem (a
  marked-up `$1.50/doz` stays `specific_or_compound`). Verified discriminating:
  against the pre-fix classifier the archive scan finds 12 offenders in rev_12
  and 12 in rev_15, 0 in rev_13. It also fails if fewer than 2 archives are
  scanned, so it cannot pass vacuously.
- [x] **Re-check the `<sup>` cases.** DONE (verification pass 2026-08-10): all
  7 `<sup>`/`<il>` lines in rev_15 are genuinely specific/compound —
  `$1.13/m<sup>3</sup>`, `14.5¢/m<sup>2 </sup>+ 0.4%`, `6.5¢/gross<il></il>` —
  and classify as `specific_or_compound` both before and after the fix (the
  `¢`/`$` detection is unanchored, so markup never defeated it). Not a second
  parse failure. Also confirmed the strip is safe on this corpus: every `<` in
  any `general` field across all 47 archives is one of exactly 6 tag forms
  (`<u>` `</u>` `<sup>` `</sup>` `<il>` `</il>`, matched pairs), and ZERO bare
  `<` remain after stripping — no real less-than sign exists to be eaten.
- [ ] **Latent: two anchored `^N%$` matchers still read UN-normalised text.**
  Both are empirically safe today — ch99 `general`/`other` fields carry ZERO
  markup across all 47 archives (verified 2026-08-10) — but they are the same
  shape that broke on ch1-97, and USITC has demonstrated it will inject tags
  into rate fields:
  - `parse_ch99_rate()` (`rate_schema.R:262`), bare-`N%` arm only (the
    `+ N%` / `plus N%` / `duty of N%` arms are unanchored and safe);
  - the §232 auto floor-vs-surcharge classifier
    (`05_parse_policy_params.R:926,991`), `^N%$` on `general_raw`.
  Fix is one line each (normalise at entry) but 05_parse_policy_params.R has
  uncommitted WIP in it — apply when that lands, and extend
  `tests/test_rate_parse_markup.R` with a ch99-side invariant at the same time.

## MRS replication

Independent research workstream (JI); tracked on the researcher's own
branch, not in this backlog. The only tracker-side footprint is generic,
baseline-neutral engine machinery (origin-keyed us_auto_content_share map,
ieepa_fentanyl_rate_caps) — dormant unless a scenario overlay configures it.

## Eta statutory-measurement queue (2026-07-01) — open items

Origin + investigated items 1 (2716 electricity — statutory correct, entry
coverage) and 4 (ag exemptions — tracker matches printed HTS; ASEAN
EO 14346 Annex III lists are the missing channel): see the archive todo and
`docs/internal/eta_statutory_measurement_queue_2026-07.md` (provenance).

- [ ] **1-follow-up (small):** register HS 2716 in
  `docs/statutory_deviations.md` as divergence-by-entry-coverage so the eval
  can mask it in eta figures.
- [ ] **2. §232 derivative content basis (pre-annex window 2025m5–2026m2).**
  Tracker already scales by BEA shares; the actionable question is
  calibration vs importer-DECLARED content. Route: eval-side realized-rate
  inversion on derivative lines (realized ÷ statutory ⇒ implied content
  share) per HTS10×partner, then recalibrate `metal_content_shares_bea_hs10.csv`.
  The ANNEX-era (2026-04-06+) half of this item is superseded by the
  route-calibration proposal (active priority 1) — full value is the law there.
- [ ] **3. USMCA claim shares in the eta-calibration statutory baseline —
  DECISION NEEDED (with the eta owners).** 2024-H2 claim shares embed the
  pre-surge take-up (Canadian gas statutory 9.3% vs realized 0.1%, η≈0.99
  booked as avoidance). Options: re-base on current shares (tracker already
  exposes `usmca_2024` + current-share scenarios) vs keep the surge in η by
  design. Tracker-side: no change until decided.
- [ ] **4. ASEAN aligned-partner retro exemptions (rice/vegetable oils).**
  (a) eval side — test whether the η≈0.54–0.56 clustering concentrates in
  TH/MY/KH/ID/VN with realized-rate breaks ~Nov 2025; (b) if confirmed, pull
  the per-country CSMS product lists (EO 14346 Annex III) and model as
  date-bounded country-specific exempt overlays (`swiss_framework` pattern).

## Specific/compound-duty EXPOSURE flags (re-scoped 2026-06-10)

**Scope decision (user, 2026-06-10): NO AVE conversion — flag the exposed
cells only.** Full diagnosis, the latent stale-sibling `rate_stack`
inheritance bug, and the zero-rate-number-change acceptance criteria: archive
todo §"Specific/compound-duty EXPOSURE flags". **LANDED 2026-07-09** (assumption
19 in `docs/assumptions.md`; rate numbers byte-identical on rev_9; CI 109/0 incl.
2 new tests). Zero rate-number change verified — rides no vintage requirement.

- [x] **Add `base_rate_type` to the panel** (`ad_valorem`/`free`/
  `specific_or_compound`/`other`): `classify_rate_type()` in helpers.R + a
  parallel `type_stack` in `04_parse_products.R` (resets on ANY legal line, à la
  `special_stack`, NOT `rate_stack`); carried through `calculate_rates_fast()`
  base-rate join + `ensure_dense_grid()` (`EXPLICIT_SET_COLUMNS`) + blanket-pair
  path (`add_blanket_pairs()`). Cache guard `read_products_cache()` fails loud on
  a pre-flag `products_<rev>.rds`; reference caches regenerated.
- [x] **Quality-report surface:** unweighted `pct_pairs_specific_or_compound`
  in `compute_revision_quality()`. Value-weighted share still deferred to
  `src/diagnostics.R` (next cluster build) — the only open sub-item here.
- [x] **Flow to consumers:** `mfn_rate_type` in `export_statutory_rates()`
  CSV + `base_rate_type` in `products_raw.csv`; scope decision documented in
  `docs/assumptions.md` §19.
- [x] **Tests:** classify units + compound-parent suffix inheritance fixture
  (`test_rate_calculation.R`, 109/0). Real-data integration spot-checked on
  rev_9 (0 NA, distribution sane). Golden-snapshot integration rides the next
  full build.
- [ ] **Quantify the stale-sibling rate inheritance bug, then decide the fix**
  (moves numbers — parity-gated, separate from the flag change). **Quantified
  2026-07-09:** ~1,100 pairs on rev_9 (`parse_products()` logs "Stale-sibling
  suspects"; cells where `base_rate_type == 'specific_or_compound'` but
  `base_rate` inherited a non-NA number). Larger than the "latent/rare" framing.
  Fix (make `type_stack`'s robust reset drive `rate_stack` too) still pending —
  parity-gated, needs a full-build golden diff before landing.

## Build unification (2026-06-09) — one build, three destinations

Phases 0 + 2 DONE (hygiene; shared verify gate) — details in archive todo.

- [ ] **Phase 1 — destinations as config:** `destinations:` block (repo mirror
  / vintage+update_latest / release_git); three thin publishers off one
  canonical build tree; verify-then-publish becomes ONE build.
- [ ] **Phase 3 — parallel by default:** array = default backend; serial =
  golden parity baseline. Do NOT finish the in-process revision-parallel stub.
  Fold rebuild-alternatives into the array config as post-gather work units.
- [ ] **Phase 4 —** = alternatives unification remaining, next section.
- [ ] **Gather quality-report collapse-in-node (mirror `daily_part`).** The
  daily series already collapses per-revision in the array tasks
  (`write_daily_part_for_snapshot` → `daily_part_<rev>.rds`; gather only binds;
  204M-row monolith retired). The gather's remaining serial cost is the
  **quality report**: `build_quality_inputs_streaming`
  (`src/io/quality_report.R:401-450`) reads all snapshots one at a time in a
  `for` loop and computes per-snapshot NA scans / row counts / per-revision
  summaries on one core. Apply the exact `daily_part` pattern:
  1. Add `write_quality_part_for_snapshot()` in `quality_report.R`; call it from
     `scripts/build_revision.R` right after the daily part (snapshot already in
     memory, ~line 89-128) → `quality_part_<rev>.rds`.
  2. Add `load_quality_parts_if_complete()` mirroring
     `load_daily_parts_if_complete` (same completeness + fingerprint gate; fail
     loud on missing/stale). `run_quality_report` binds the parts and runs ONLY
     the cross-revision reductions (consecutive-rev deltas `:137`, authority
     coverage `:272-298`, interval/NA-window checks) on the small summaries;
     keep the streaming path as the explicit serial/non-array fallback.
  3. Add `quality_part_` to the scratch-file patterns in
     `submit_build_array.sh` (line 12) and the scenario-reuse symlink loop in
     `build_gather.R` (line 109).
  - Quality needs no weights, so no per-task weight-load cost (unlike daily).
  - (Second lever, measure first) the consecutive-parse **deltas** step is also
     gather-serial but needs adjacent revisions — don't decompose unless quality
     alone doesn't recover most of the wall-clock.
  - Parity-gate via `run_parity_check.R` (array quality outputs == serial within
    tolerance) + confirm `verify_build.R` NA-interval/quality gates still pass.
    Code-only, no data migration. Baseline gather wall-clock to capture: build
    2026-07-24-08 gathers ran ~15 min each (three series concurrent).

## Alternatives unification (2026-06-10) — remaining

Steps 1–4 LANDED (registry, overlays, counterfactuals-as-overlays, one flag
one runner, 35 tests) — details in archive todo and `docs/scenarios.md`.

- [ ] **Step 5 — cluster parity + verification gate:** (a) golden diff of
  `--alternatives alternatives` vs prior outputs, then DELETE deprecated
  `build_rebuild_alt_registry()`; (b) first-ever run of the six
  counterfactuals (sanity: `no_301` ≤ baseline everywhere, `pre_2025` <
  baseline post-Jan-2025) — this also clears the stale Apr-2025
  `output/alternative/*_{no_*,pre_2025}.csv`; (c) fold sanity checks into
  `verify_build.R`; (d) add `test_scenario_registry.R` to the submit_plank
  cluster harnesses (CI already green, a3b88d3).
- [ ] **Migrate `SCENARIO_SPECS` in `build_usmca_scenarios.R`** onto the
  registry, or retire the script if `--alternatives` covers it.
- [ ] **`publish_git`/`publish_vintage` read `meta.publish`.**
- [ ] **Collapse the kind taxonomy** (fold `alternative` into `scenario`, keep
  `counterfactual`): do WITH the Step-5 legacy-alias deletion; pin the blog
  pipeline's 7-variant set as an explicit list BEFORE merging kinds.

## External-tracker comparison database (2026-06-10)

Survey + verified endpoints + design: `docs/external_tracker_comparison.md`.
All four items open: fetchers (`src/fetch_comparison_trackers.R` — Datawrapper
resolver TPC `aO4iG`/`MC81F`/`e1Iok`, Tax Foundation `hn0bW`/`2dFbJ`; Treasury
DTS API; PIIE ZIP HEAD-poll), comparison report
(`src/compare_external_trackers.R`, five overlays), one-time GTA/SGEPT
flow-level cross-validation (their file frozen 2025-12-23), retire the old
TPC match-rate path once overlays 1–3 exist.

## Re-dated rebuild — remaining acceptance checks (from 2026-06-09/10)

- [ ] `compare_etrs.R` re-run; re-run `tools/revision_changelog.R` so the
  changelog table picks up corrected dates; hand snapshots to tariff-etr-eval
  (month-weighting shifts materially Mar–May + Sep–Dec 2025).
- [ ] **GTAP weights HS8 fallback** for padded 8-digit-leaf codes (Swiss
  watches, ch98) — invisible to ALL weighted ETRs today (weights file is
  2024-vintage HTS10). Fix: HS8 fallback in the weights join or a concordance
  pass on the weights file.
- [ ] **Retro-window follow-ups:** EU framework retro to Sep-1-2025, Korea
  floor retro to Nov-14-2025, rev_4 derivative Mar 7–13 window — model via
  date-bounded config overrides (`swiss_framework` pattern) if the eval needs
  them; extend the release-currency gate to cross-check new revisions' dates
  against change records at build time.

## Section 232 — open modeling items

Route calibration is active priority 1. Everything landed through 2026-06-12
(annex scaffolding, UK blend, dormant knobs, Annex IV scoping, prune audit,
Phase-1 1a–1e) is in the archive todo. Still open:

- [ ] **Japan deal annex likely missing:** the 8 "japan civil_aircraft"
  floor-exempt rows were mislabeled rail/steel codes (dropped in Phase-1 1e);
  TPC charges ~3.5% on 1,019 dropped-code Japan pairs at Oct/Nov where we
  charge ~18%. Needs the Japan agreement annex text to adjudicate. Fold into
  the consolidated "what does the Japan agreement exempt" review (with the F3
  §232 offset credits item).
- [x] **UK annex_1b coverage gate — FIXED 2026-07-08** (moves numbers, UK
  only): gate now the annex CSV `metal_type` via the same winning prefix row
  as the tier (`classify_s232_metal_type()`), honoring `uk_applies_to`;
  companion guard stops replace-mode country overrides wiping heading-program
  rates. Slurm 17423834 validation vs published rev_9: exactly 865 changed
  cells, ALL UK, all rate_232 0.25→0.15 ((c)(vi)-(vii) chapters 84/85/30/87/
  82/83/86/94…), copper + heading programs untouched. Affects ~$950M/month
  (85% of UK annex trade, −10pp statutory). RIDES THE NEXT PUBLISHED VINTAGE;
  also update registry U5 wording (scope now statutory-correct; only the
  qualifying-share calibration remains open) and rerun the route calibration
  against the fixed vintage for UK-correct T_full.
- [ ] **Note 16(h)/(i) limited-quantity CA/MX (9903.82.18/.19):** defer until
  the eval shows a CA/MX primary-metals gap; shape = per-country share knob.
- [ ] **Note 16(k) annex_1c parts end-use routes (9903.82.23–.26):** low
  materiality; shape = `applies_to` share knob mirroring us_origin_metal.
- [ ] **Pre-annex 9903.81.92 US-melted steel-derivative exemption**
  (Mar-2025→Apr-2026 window, ~1% of derivative-steel duties):
  document-and-defer; revisit only if 2025 §232 residuals point at it.
- [ ] **Russia clause (8) smelt/cast origin:** dormant
  `third_country_content_share = 0.0` knob is the accepted treatment
  (documented, assumptions.md §18); no origin tracking planned.
- [ ] **Subdivision (r) auto-parts shares** (dormant knobs, all 0): DataWeb
  upper bounds known (KR ≤ 0.86, JP ≈ 0, EU = 0); `certified_share` needs CBP
  entry data / industry estimates. Side gap: should the KORUS FTA exemption
  apply to the 9903.82.x annex independent of (r) certification? Own scoping
  pass.
- [ ] **Annex III sunset (Dec 2027 → I-B rate):** logic in place; needs a
  future HTS revision to test.
- [ ] **Semi `end_use_exemption_share`:** post interim calibration it only
  bites on 8471.80.4000; best path is empirical — eval measures realized ÷
  25% on Taiwan/China Jan-16→Mar-2026 collections = qualifying ×
  (1 − end_use) directly. Don't change baseline until measured.
- [x] **§122 civil-aircraft exemption fix — IMPLEMENTED 2026-07-08**
  (audit found ≈ $800M/month statutory duty understated). Audit +
  implementation: `docs/s122_aircraft_exemption_audit.md`. The 541
  note-2(aa)(iv) aircraft HTS8 codes are USE-conditional (GN6) but were
  applied full-line; now split by a `condition` column on
  `s122_exempt_products.csv` (builder `scripts/build_s122_exempt_conditions.R`)
  and the GN6 set is scaled by `(1 − exempt_share)` in `apply_section122()`
  with measured→HS2-mean→full-exemption fallback (shares
  `resources/s122_aircraft_utilization.csv`, U3 statutory framing).
  Validated Slurm 17428463 (hook-on/off vs pre-fix worktree). Tests:
  `test_s122_aircraft_scaling.R` 9/0 + suites green. **Rides next vintage +
  forces eval/adj recalibration.** Remaining:
  - [ ] **ETRs export still full-exempts aircraft:** `generate_s122_yaml()`
    (`tools/generate_etrs_config.R`) exports the flat `$hts8` (all 1,656) as
    exempt — the GN6 split is tracker-engine-only. Reconcile in the eval/adj
    handoff (the export schema is a flat list; carrying utilization needs a
    schema change there).
  - [ ] **Registry U-item** for the GN6 utilization (family U1/U3); note
    (aa)(iv) was modeled unconditional 2026-02-24→2026-07-08. Add on the next
    `statutory_deviations.md` touch (file in user edit today).
  - [ ] **Re-derive route-calibration T_exit** for India/JP/VN after this
    rides a vintage (their exact-10 "us_origin" mass reclassifies to
    exit-strong; see the route-calibration item).
- [ ] **`data/census_imports_2024.csv` holds only Canada+Mexico** — check
  provenance before anything new consumes it (build weights are complete and
  unaffected).
- [ ] Cosmetic: annex builder truncates printed 10-digit "8505.11.0070" to
  85051100 (over-inclusive, harmless); 22 lines that lost 232 at the annex
  restructure pay zero additional in the §122 era (pre-existing).

## Section 301 exclusions — remaining

Phase 1 (date-windowed zeroing) + Phase 2 module (realized-rate inversion,
promoted .69 = 0.35 / .70 = 0.20) LANDED — archive todo has the full detail;
method doc `docs/s301_exclusion_calibration.md`.

- [ ] **Two RATE-BEARING headings carry stated expiries the tracker ignores:**
  `9903.91.04` ("through December 31, 2025") and vestigial `9903.88.09`.
  Review whether the 9903.91.05+ ladder already carries the post-2025 rate
  via max-per-hts8, then decide on a rate-bearing expiry gate (parity-gated).
- [ ] **Phase-2 remaining:** rev_9 rebuild validation of the promoted values
  (rides with the vintage N+1 publish); eval cross-check of the inversion;
  calibrate or dismiss the .21–.28 permanent carve-outs
  (`--include-carveouts`); rerun the calibration quarterly as IMDB months
  land; promote the per-HTS10 line-coverage extension (built dormant,
  scenario `s301_line_coverage`) after full-build parity review.

## Section 301 forced labor — post-codification follow-ups (2026-07-31)

HTS 2026 rev_13 (published 2026-07-28) codified the final action as
headings 9903.05.20-.84 / U.S. note 52. The action was already modeled as a
BASELINE authority from the Federal Register notice, and the ingest review
reconciled all 64 country charging headings against the config tiers with
ZERO mismatches — so both items below are refinements, not corrections.
Review: `docs/internal/hts_2026_rev13_review.md`.

- [ ] **Re-source the forced-labor rates from the HTS** (the pattern rev_12
  applied to Brazil §301: "the +25% now reads off HTS 9903.05.01 via
  extract_section301_brazil_rates(); config rate demoted to fallback"). The
  tiers currently come from `section_301_forced_labor.{rate_10,rate_12_5,
  tier_*}` in config; rev_13 now carries them per country in the schedule, so
  the schedule can become the rate authority with config as fallback. Should
  be numerically neutral given the zero-mismatch reconciliation — parity-gate
  it. NOTE the net-of-MFN cap needs care: the HTS implements it by BIFURCATING
  headings on the line's own column-1 level (9903.05.38 = EU at-or-above the
  threshold, no additional duty; 9903.05.39 = EU below it, flat 10% replacing
  column 1) rather than by arithmetic, so a naive per-heading rate read would
  see "0%" and "10%" where the model means max(10% - MFN, 0).
- [ ] **Cross-check the 21 `9903.06.01-.21` per-country product carve-outs**
  against `resources/s301fl_final_country_exemptions.csv` (4,921 rows, built
  from the FR annex). The HTS references these lists by note-52 subdivision
  ((j)(4) Malaysia, (j)(5) Cambodia, Guatemala, El Salvador, Argentina,
  Bangladesh, Ecuador, ...), so USITC's enumeration is an INDEPENDENT check on
  ours — a disagreement means one of the two mis-read the annex. Also confirm
  the exemption headings .85-.99 map onto the modeled carve-outs (in-transit,
  note 52(b)/(c), civil aircraft, pharma use, full §232 mask, donations,
  informational, CA 52(g) / MX 52(h) / CAFTA-DR textiles 52(i) / UK / EU / CH
  / MY).

## HTS 2026 rev_14 / rev_15 ingest + §232 pharma (2026-08-07)

rev_14 (published 2026-07-31) codified the §232 pharmaceutical action
(PP 11020) as headings 9903.04.60-.69 / U.S. note 40; rev_15 (2026-08-03,
CURRENT) changed exactly one thing — the rate on the UK heading. The archive
tip was rev_13, so the build was TWO releases behind. rev_15 archive + both
change records are now committed. Product scope reconciled EXACTLY (131 HTS10s
vs note 40(c), 0 mismatches) and the 100%/15% net-of-MFN structure matches the
config's `target_total` semantics. Review:
`docs/internal/hts_2026_rev14_rev15_review.md`. **Consolidated proposal with
proposed diffs + sequencing: `docs/proposed_mod_claude_2026_08_07.md` (M2-M4,
M6).**

- [ ] **Fix the UK pharma rate — CONFIRMED WRONG BY 10 POINTS.** Config has
  `section_232_headings.pharmaceuticals.country_rates.CTY_UK: 0.10` (resolving
  to 2.0% after the generic/exempt shares); heading 9903.04.63 charges "the
  duty provided in the applicable subheading **+ 0%**" and note 40(g) carries
  NO net-of-MFN language, unlike 40(d)/(f). This is the single change rev_15
  made, dated effective 2026-07-31 (retroactive to rev_14), so there is no
  split window — set `CTY_UK: 0.0`. Moves the series from 2026-09-29 onward;
  publish as a deliberate vintage.
- [ ] **Decide the 2026-07-31 → 09-28 window.** Heading 9903.04.61 exempts only
  companies the Secretary IDENTIFIED, and only before 2026-09-29; heading
  .60's 100% is otherwise live from 07-31. The model gates the whole pharma
  layer at 09-29, which is correct only if every patented-pharma importer is
  on that list for the eight-week window. Note-40(c) universe is $160.4B of
  2024 imports (5.1% of panel), so this is not negligible. Either move the
  gate to 07-31 with a `.61` exempt share, or record the assumption in
  `docs/statutory_deviations.md`. Do not leave it implicit.
- [ ] **Ingest rev_14 + rev_15 rows.** Suggested dating per the review: rev_14
  at `effective_date: 2026-07-31` (the operative legal date; owns the pharma
  headings), rev_15 at `2026-08-03` with `policy_effective_date` empty.
  Expect rate-neutrality of rev_15 vs rev_14 in the series.
- [x] **Teach `tools/revision_changelog.R` to strip HTML markup.** DONE
  (`633ac46`): `normalize_schedule_text()` in the comparison layer; markup-only
  edits are counted and excluded (63 at rev_13, 73 at rev_15) rather than
  listed. USITC ran a schedule-wide typographic pass (italic scientific names,
  `<sup>` units, `<br />`, one `<em style=...>`): a raw field diff reports
  3,199 modified entries, ALL cosmetic once tags/whitespace are normalised.
  ~~Tags land in `description`/`units` only, so rate parsers are unaffected~~
  — **THIS WAS WRONG, see the LIVE ERROR section at the top of this file.**
  Tags also land in `general`, and the base-rate parser IS affected: `2.5%
  <u></u>` classifies as `other` with `base_rate = 0`. The original claim came
  from a cosmetic-diff analysis that only inspected description/units. Still
  open: re-check anything matching on description text (the §232 annex parser
  is the candidate).
- [ ] **Optional — make the HTS the pharma rate authority.** Add a
  `classify_authority()` rule for `9903.04.6x` → `section_232` (they currently
  fall through to `other`; inert today since no ch.1-97 line
  footnote-references 9903.04) and read .60/.62/.63/.64 off the schedule with
  config demoted to fallback. Same pattern as Brazil rev_12 and the
  forced-labor tiers in the working tree — and it would have caught the UK
  rate automatically.
- [x] **Notes 50(a)(vi)(8) / 52(f)(8) — ALREADY MODELED, confirmed by rev_14.**
  rev_14 added "patented pharmaceutical articles provided for in headings
  9903.04.60-9903.04.66" as item (8) to the §232-overlap exclusions in both
  §301 notes. The repo already implements this from the FR notice's Annex I
  Part B (`patented_pharma_exempt_date: '2026-07-31'`, config:867,937;
  `06_calculate_rates.R:1085`) and got the subtle part right — §301 relief
  starts 07-31 even though the §232 duty starts 09-29. The parallel
  note 2(aa)(v)(1) §122 exclusion is MOOT (§122 expired 2026-07-23).
  Residual nuance, not currently distinguished: the exclusion spans .60-.66
  only, so generics (.67), US-origin API (.68) and non-pharma articles in the
  list (.69) still owe §301; the flat 131-HTS10 mask cannot tell them apart.

## §232 polysilicon (proclamation 2026-08-06, eff. 2026-12-04)

New §232 action creating U.S. note 42 / headings 9903.45.30-.36. Not in any
HTS revision yet. Ad valorem layer is modelable; the minimum-import-price
layer ($21/kg, $100/kg, $0.22/W, $0.38/W) is a CONDITIONAL specific-duty
backstop and is not representable as-is. Exposure $16.8B of 2024 imports
(0.54% of panel), 88% of it solar modules. Review:
`docs/internal/polysilicon_232_review_2026-08-06.md`. **Consolidated proposal
with proposed diffs + sequencing: `docs/proposed_mod_claude_2026_08_07.md`
(M1, M5, M6c).**

- [ ] **Date-gate Section 201 — LIVE ERROR, do this first.** The CSPV
  safeguard **terminated 2026-02-06** (8-year statutory max; USITC
  TA-201-075 evaluates the relief "which terminated on February 6, 2026"),
  but `apply_section201()` has NO date gate — it applies
  `section_201.solar_rate: 0.145` flat across the whole series
  (`06_calculate_rates.R:1243-1268`). Every snapshot after 2026-02-06 charges
  14.5% on `8541420010`/`8541430010`/`8541430080` ($16.6B of 2024 imports)
  where it should charge zero: ~$2.4B/yr of phantom duty, ~0.08pp of weighted
  ETR. **The archives have carried the evidence since `2026_rev_4`**
  (2026-02-24; absent in rev_3): USITC stamped a compiler's note "This
  subheading and its related note, U.S. note 18 to this subchapter, have
  expired" onto all of 9903.45.21-.29, and as of rev_15 there is NO live CSPV
  provision in ch99. Two mechanisms miss it: `has_s201` keys off mere
  PRESENCE of the (still-shaded) headings, and the compiler's note carries no
  DATE so `extract_expiry_date_offset()` returns NA and `filter_active_ch99()`
  can't drop it (verified). Fix with `expiry_date`/`policy_expiry_date` on the
  `section_122` pattern; prefer gating via the spec's `active$until`
  (`authority_adapter.R:1157`), which mints the 2026-02-07 boundary for free
  via `timeline.R:82-86` — but first verify `active$until` is ENFORCED in the
  calc and not merely read for boundary collection. Also confirm the Year-8
  rate: secondary sources say 14%, config says 14.5%.
- [ ] **Add a `classify_authority()` segment rule** for `9903.45.30-.36` →
  `section_232`. They currently classify as `section_201` because Solar 201
  owns the whole 9903.40-45 range (`rate_schema.R:344`). Latent, not live —
  `extract_section201_rates()` restricts to .21-.29 so no rate is misread,
  and no ch.1-97 line footnote-references 9903.45. Use the `section_338`
  segment-match precedent at `rate_schema.R:298`.
- [ ] **Add the 3818.00.00 484(f) concordance mapping.** Annex I / heading .34
  cite `3818.00.0020/.0040/.0045/.0050/.0091`; the 2024 GTAP weight panel has
  only the retired `3818000090` ($1.39B) and `3818000010` ($0.14B). As written
  the wafer layer — the largest per-unit rate in the action — would attach to
  a base of ZERO. Same failure mode the rev_11 entry flags; the 484(f) weight
  mapper (`15646c6`) is the machinery. Check
  `data/484f/source_manifest.csv` first.
- [ ] **Model the ad valorem layer** as `section_232_headings.polysilicon`,
  hand-fed from the proclamation with a 2026-12-04 date gate (pharma/Brazil/
  s338 pattern — no HTS archive carries the headings). Needs a shape the
  config vocabulary lacks: an ADDITIVE default (.30, +15%, note 42 has no cap
  clause for it) alongside a `target_total` tier (.31, 15% ALL-IN per note
  42(c), for LI/JP/KR/CH/TW/EU) and a second additive tier (.32, UK +10%).
  The pharma block's `max(country_rate, target_total - base_rate)` resolves
  the wrong way for an additive default, so this is NOT a copy of that block.
  `usmca: none`. Scope covers wafers/cells/modules but NOT `2804.61.0000`
  (raw polysilicon appears in no ad valorem heading — MIP only).
- [ ] **Record the MIP as a documented zero** with a named compliance share.
  Note 42(a) makes .33-.36 a backstop that applies only when the importer
  fails to document resale price or CBP adjusts; a compliant importer pays
  nothing. Also `parse_rate()` collapses non-ad-valorem rates to NA
  (`helpers.R:93,118`) and the watt-denominated rates need capacity data the
  panel does not carry. Add a `docs/statutory_deviations.md` entry.
- [ ] **Watch for the codifying HTS revision** and reconcile .30/.31/.32
  against the config the way rev_13 was reconciled. Note 42's enumeration is
  authoritative for scope — Annex I says its descriptions are "provided for
  informational purposes only."
- Also noted: polysilicon is added to NO §232-overlap exclusion list (not note
  2(v), 2(aa)(v), 50(a)(vi) or 52(f)) — unlike every other sectoral §232
  action. No displacement of any other authority, and no USMCA relief (CA/MX
  appear only as drawback-eligible Trade Agreement Partners). Out of scope:
  manufacturing drawback, FTZ privileged-status admission, onshoring tariff
  offsets, substantially-equivalent-MIP arrangements.

## AD/CVD (decided 2026-06-08)

- [ ] **Strip AD/CVD from the collected side before calibrating η — do NOT
  build the statutory `rate_adcvd` layer.** Implementation is
  tariff-etr-adj-side; keep the tracker scaffold dormant, never both.
  Rationale + caveats: `docs/adcvd_layer_design.md` §"Decision (2026-06-08)".

## Preference-share refinement (2026-04-28)

- [ ] **Refresh DataWeb USMCA monthly shares against IMDB-realized claim
  shares** (HS6×country×month drill-down; eval computes the IMDB aggregate,
  tracker ingests refreshed shares).
- [ ] **Expose statutory-vs-claimable rate split for the Annex II claim-rate
  channel** (emit both rate columns side-by-side; the
  `ieepa_exempt_scope: 'baseline_only'` toggle already produces the no-claim
  rate).

## Housekeeping

- [ ] **Dead doc references in code/comments** (docs were deleted in the
  f745eea cleanup or moved): `docs/s232/rev5_baseline_review.md` (cited in
  `06_calculate_rates.R` annex-era comment + archive todo),
  `docs/s232/subdivision_r_fix.md`, `docs/tracker_audits/…`,
  `docs/analysis/generic_pharma_exemption_share_plan_2026-03-24.md` — repoint
  or drop the citations.
- [ ] **`tests/test_publish_snapshots.R:22`** references deleted
  `src/publish_internal.R` (pre-existing, not in CI) — fix or retire the test.
- [ ] **File-pathing unification** (restructure follow-up, scoped 2026-06-25):
  bare `here()` (516) vs `here::here()` (43); `scenario_registry.R` relies on
  transitive `library(here)`; hardcoded relative paths in the
  `sys.nframe()==0` demo blocks of 06/07/rebuild_one_revision. Pick a
  convention and sweep.
- [ ] **`config/local_paths.yaml` currently sits in the tree with
  `weight_mode: unweighted`** (CI-parity leftover) — delete it or commit it
  deliberately; it silently opts local builds out of weighted outputs.
- [ ] **Verify the submit_plank harnesses** still run post-restructure
  (f9ee352 restored the missing parity shims; `tests/test_scenario_ops.R`
  references may remain in plank wrappers).
- [ ] Suggestion-tier perf (2026-04-22): O(N·M) annex prefix matching
  (`06_calculate_rates.R` step 5c) → hash precompute; verify
  `load_metal_content()` isn't re-reading the BEA CSV per build;
  `statutory_rate_232` overloaded semantics (rewritten at 4 points) —
  consider per-stage snapshots.
- [ ] Generic pharma country-specific exemption shares (TPC feedback; low
  priority; original planning note was deleted in the f745eea docs cleanup).

## Low priority

- Concordance builder: tighten with reciprocal-best or capped matching if
  splits/merges ever matter.
- Small-country outliers (Azerbaijan −26pp, Bahrain −22pp, UAE −8pp, Georgia
  +14pp, New Caledonia +22pp): not material to aggregates.

## Resolved

Everything completed before 2026-07-08 — the extreme-eta fixes, 232/Annex-II
corrections pass, Phase-1 statutory corrections (1a–1e), prune audit + TPC
cross-check, §301 exclusion Phases 1–2, semiconductors, USMCA share-loading,
the 2026-04 code reviews, and the restructure/theseus/build-unification landed
phases — lives verbatim in `docs/archive/todo_archive_2026-07-08.md`.
