# Tariff Rate Tracker — TODO

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
3. **Answer the electronics reciprocal-exclusion query** (inbound from
   tariff-etr-adj, `docs/electronics_exclusion_query_2026-06-20.md`): is the
   April-2025 9903.01.32 electronics carve-out (smartphones/laptops/semis)
   applied in the rate build, for which HS10 × countries × dates? (It should
   be, via the Annex II exempt list — verify and reply with the line list.)
4. **Eta statutory-measurement queue leftovers** (section below): pre-annex
   §232 content-share inversion (item 2), USMCA re-base decision with the eta
   owners (item 3), ASEAN CSMS retro-exemption follow-up (item 4 next steps).
5. **Specific/compound-duty exposure flags** (section below) — scoped, zero
   rate-number changes, ready to implement.
6. **Build/alternatives unification remaining phases** (sections below).

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
todo §"Specific/compound-duty EXPOSURE flags". Implementation plan:

- [ ] **Add `base_rate_type` to the panel** (`ad_valorem`/`free`/
  `specific_or_compound`/`other`): `classify_rate_type()` in helpers.R + a
  parallel `type_stack` in `04_parse_products.R` (do NOT reuse `rate_stack`);
  carry through `calculate_rates_fast()` base-rate join + `ensure_dense_grid()`
  (add to `EXPLICIT_SET_COLUMNS`). Cache guard: fail loud on `products_<rev>.rds`
  lacking the column; regenerate via `scripts/refresh_product_caches.R`.
- [ ] **Quality-report surface:** unweighted `pct_pairs_specific_or_compound`
  in `compute_revision_quality()` + per-revision exposure side table;
  value-weighted share in `src/diagnostics.R` (next cluster build).
- [ ] **Flow to consumers:** add the column to `export_statutory_rates()`
  (`tools/generate_etrs_config.R`); document the scope decision in
  `docs/assumptions.md`.
- [ ] **Tests:** classify units, compound-parent suffix inheritance fixture,
  snapshot integration.
- [ ] **Quantify the stale-sibling rate inheritance bug, then decide the fix**
  (moves numbers — parity-gated, separate from the flag change).

## Build unification (2026-06-09) — one build, three destinations

Phases 0 + 2 DONE (hygiene; shared verify gate) — details in archive todo.

- [ ] **Phase 1 — destinations as config:** `destinations:` block (repo mirror
  / vintage+update_latest / release_git); three thin publishers off one
  canonical build tree; verify-then-publish becomes ONE build.
- [ ] **Phase 3 — parallel by default:** array = default backend; serial =
  golden parity baseline. Do NOT finish the in-process revision-parallel stub.
  Fold rebuild-alternatives into the array config as post-gather work units.
- [ ] **Phase 4 —** = alternatives unification remaining, next section.

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
- [ ] **UK annex_1b coverage gate (side finding, moves numbers):** the UK
  override gates on ch72/73/76 but (c)(vi)–(vii) annex_1b articles span other
  chapters — UK 1b reduced rate likely UNDER-applied outside the metal
  chapters. Gate on the annex CSV metal_type instead; parity-gated.
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
